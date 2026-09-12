#!/usr/bin/env bash
# E2E: a real external WireGuard client (fresh qemu/KVM VM) connecting to an
# already-deployed real VPS over the public internet. This is the final piece
# the in-guest test cannot cover: the actual public endpoint, the provider UDP
# port, a real internet handshake, DNS via the VPS AdGuard and the .internal
# HTTPS endpoints served by the VPS Caddy with the private root CA.
#
# The client peer is registered directly through the wg-easy container
# (the wg-easy CLI is broken in some image builds, so we register the peer in
# its SQLite database and apply it at runtime, then remove both afterwards).
#
# Usage:
#   tests/e2e/external-client-qemu.sh [--prepare-only --state-dir DIR]
#   tests/e2e/external-client-qemu.sh --cleanup --state-dir DIR
#
# Env:
#   VPS_HOST         real VPS public IP (required)
#   VPS_SSH_PORT     hardened SSH port on the VPS (default 2222)
#   VPS_SSH_USER     SSH user with passwordless sudo (default sysadmin)
#   VPS_SSH_KEY      SSH private key for the VPS (default $HOME/.ssh/id_ed25519)
#   VPS_WG_PORT      WireGuard UDP port on the VPS (default 51820)
#   QEMU_IMAGE       cloud image for the client VM (default Ubuntu 24.04 noble)
#   QEMU_SSH_PORT    host tcp port -> client VM:22 (default 2224)
#   FULL_TUNNEL      client AllowedIPs 0.0.0.0/0 (default 1)
#   KEEP_PEER        keep the test peer on the VPS after the run (default 0)
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

MODE=run
STATE_DIR=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prepare-only)
            [[ "${MODE}" == run ]] || fail "prepare-only and cleanup modes are mutually exclusive"
            MODE=prepare; shift ;;
        --cleanup)
            [[ "${MODE}" == run ]] || fail "prepare-only and cleanup modes are mutually exclusive"
            MODE=cleanup; shift ;;
        --state-dir)
            [[ $# -ge 2 ]] || fail "--state-dir requires a value"
            [[ -z "${STATE_DIR}" ]] || fail "--state-dir may be specified only once"
            STATE_DIR="$2"; shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
if [[ "${MODE}" != run && -z "${STATE_DIR}" ]]; then
    fail "${MODE} mode requires --state-dir"
fi

VPS_HOST="${VPS_HOST:-89.124.117.175}"
VPS_SSH_PORT="${VPS_SSH_PORT:-2222}"
VPS_SSH_USER="${VPS_SSH_USER:-sysadmin}"
VPS_SSH_KEY="${VPS_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
VPS_KNOWN_HOSTS="${VPS_KNOWN_HOSTS:-}"
VPS_WG_PORT="${VPS_WG_PORT:-51820}"
VPS_WG_ENDPOINT_HOST="${VPS_WG_ENDPOINT_HOST:-${VPS_HOST}}"
DEFAULT_IMAGE="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
QEMU_IMAGE="${QEMU_IMAGE:-${DEFAULT_IMAGE}}"
QEMU_SSH_PORT="${QEMU_SSH_PORT:-2224}"
FULL_TUNNEL="${FULL_TUNNEL:-1}"
KEEP_PEER="${KEEP_PEER:-0}"
F3_LITERAL_DNS="${F3_LITERAL_DNS:-0}"
CLIENT_IP="10.8.0.5"
CLIENT_IPV6="fd42:42:42::5"

[[ -f "${VPS_SSH_KEY}" ]] || fail "VPS_SSH_KEY must name a controller private key"
[[ -f "${VPS_KNOWN_HOSTS}" ]] || fail "VPS_KNOWN_HOSTS is required"
[[ "${VPS_SSH_PORT}" =~ ^[1-9][0-9]{0,4}$ && "${VPS_SSH_PORT}" -le 65535 ]] || fail "VPS_SSH_PORT is invalid"
[[ "${VPS_WG_PORT}" =~ ^[1-9][0-9]{0,4}$ && "${VPS_WG_PORT}" -le 65535 ]] || fail "VPS_WG_PORT is invalid"
[[ "${QEMU_SSH_PORT}" =~ ^[1-9][0-9]{0,4}$ && "${QEMU_SSH_PORT}" -le 65535 ]] || fail "QEMU_SSH_PORT is invalid"
[[ "${F3_LITERAL_DNS}" =~ ^[01]$ ]] || fail "F3_LITERAL_DNS must be 0 or 1"

for tool in qemu-system-x86_64 qemu-img genisoimage curl ssh-keygen openssl ssh tar; do
    command -v "${tool}" >/dev/null || fail "required tool not found: ${tool}"
done

SSH_CMD=(ssh -F none -i "${VPS_SSH_KEY}" -p "${VPS_SSH_PORT}"
    -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="${VPS_KNOWN_HOSTS}"
    -o GlobalKnownHostsFile=/dev/null "${VPS_SSH_USER}@${VPS_HOST}")

if [[ -n "${STATE_DIR}" ]]; then
    if [[ "${MODE}" == cleanup ]]; then
        [[ -d "${STATE_DIR}" ]] || fail "cleanup state directory does not exist"
    else
        mkdir -p -- "${STATE_DIR}"
        chmod 0700 "${STATE_DIR}"
        [[ -z "$(find "${STATE_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]] || \
            fail "state directory must be empty"
    fi
    STATE_DIR="$(cd -- "${STATE_DIR}" && pwd -P)"
    TMP_DIR="${STATE_DIR}"
else
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-extclient.XXXXXX")"
fi
QEMU_PID=""
CLIENT_PUB=""
STATE_SENTINEL="${TMP_DIR}/.external-client-state"
if [[ "${MODE}" != cleanup ]]; then
    printf 'external-client-qemu-v1\n' >"${STATE_SENTINEL}"
fi
cleanup() {
    local remove_state="${1:-yes}"
    local cleanup_ok=true
    if [[ -z "${CLIENT_PUB}" && -f "${TMP_DIR}/peer.env" ]]; then
        CLIENT_PUB="$(sed -n 's/^PEER_PUBLIC_KEY=//p' "${TMP_DIR}/peer.env")"
    fi
    if [[ -z "${QEMU_PID}" && -s "${TMP_DIR}/qemu.pid" ]]; then
        QEMU_PID="$(<"${TMP_DIR}/qemu.pid")"
    fi
    if [[ -f "${TMP_DIR}/f3-dns-injected" ]]; then
        if ! "${SSH_CMD[@]}" "sudo sed -i 's/answer: 10.8.0.1/answer: 10.66.0.3/' /opt/vps-nook/volumes/adguard/conf/AdGuardHome.yaml && sudo docker restart adguard >/dev/null"; then
            cleanup_ok=false
        fi
    fi
    if [[ "${KEEP_PEER}" != "1" && -n "${CLIENT_PUB}" ]]; then
        echo "[cleanup] removing the test peer from the VPS"
        if ! "${SSH_CMD[@]}" sudo env PEER_PUBLIC_KEY="${CLIENT_PUB}" bash -se <<'CLEAN_PEER'
set -euo pipefail
docker stop wg-easy >/dev/null
trap 'docker start wg-easy >/dev/null 2>&1 || true' EXIT
python3 - <<'PY'
import os
import re
import sqlite3

db_path = "/opt/vps-nook/volumes/wg-easy/wg-easy.db"
with sqlite3.connect(db_path) as db:
    db.execute("DELETE FROM clients_table WHERE public_key = ?", (os.environ["PEER_PUBLIC_KEY"],))
config_path = "/opt/vps-nook/volumes/wg-easy/wg0.conf"
data = open(config_path, encoding="utf-8").read()
parts = re.split(r"(?=^\[Peer\]\n)", data, flags=re.M)
data = "".join(part for part in parts if os.environ["PEER_PUBLIC_KEY"] not in part)
open(config_path, "w", encoding="utf-8").write(data)
PY
docker start wg-easy >/dev/null
for attempt in $(seq 1 30); do
    docker exec wg-easy wg show wg0 >/dev/null 2>&1 && break
    sleep 1
done
docker exec wg-easy wg show wg0 >/dev/null
trap - EXIT
CLEAN_PEER
        then
            cleanup_ok=false
        fi
        local runtime_gone=true file_gone=true database_gone=true
        if "${SSH_CMD[@]}" "sudo docker exec wg-easy wg show wg0 | grep -q '${CLIENT_PUB}'" >/dev/null 2>&1; then
            runtime_gone=false
        fi
        if "${SSH_CMD[@]}" "sudo grep -q '${CLIENT_PUB}' /opt/vps-nook/volumes/wg-easy/wg0.conf" >/dev/null 2>&1; then
            file_gone=false
        fi
        if ! "${SSH_CMD[@]}" sudo env PEER_PUBLIC_KEY="${CLIENT_PUB}" bash -se <<'VERIFY_DATABASE'
set -euo pipefail
python3 - <<'PY'
import os
import sqlite3

with sqlite3.connect("/opt/vps-nook/volumes/wg-easy/wg-easy.db") as db:
    if db.execute("SELECT 1 FROM clients_table WHERE public_key = ?", (os.environ["PEER_PUBLIC_KEY"],)).fetchone():
        raise SystemExit(1)
PY
VERIFY_DATABASE
        then
            database_gone=false
        fi
        if [[ "${runtime_gone}" == true && "${file_gone}" == true && "${database_gone}" == true ]]; then
            echo "[cleanup] test peer fully removed (runtime + wg0.conf + database)"
        else
            echo "[cleanup][WARN] test peer residue (runtime_gone=${runtime_gone}, file_gone=${file_gone}, database_gone=${database_gone})" >&2
            cleanup_ok=false
        fi
    fi
    if ! "${SSH_CMD[@]}" 'rm -f -- /tmp/zt-f3-peer-registration; sudo rm -f -- /var/tmp/zt-f3-peer-registration /var/tmp/zt-f3-backup.sh /var/tmp/zt-f3-restore.sh /var/tmp/zt-f3-restore.tar.gz.age /var/tmp/zt-f3-restore.marker && ! sudo test -e /var/tmp/zt-f3-peer-registration && ! sudo test -e /var/tmp/zt-f3-backup.sh && ! sudo test -e /var/tmp/zt-f3-restore.sh && ! sudo test -e /var/tmp/zt-f3-restore.tar.gz.age && ! sudo test -e /var/tmp/zt-f3-restore.marker' \
        >/dev/null 2>&1; then
        cleanup_ok=false
    fi
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" >/dev/null 2>&1; then
        kill "${QEMU_PID}" >/dev/null 2>&1 || true
        sleep 2
    fi
    if [[ "${remove_state}" == yes ]]; then
        [[ -f "${STATE_SENTINEL}" && "$(<"${STATE_SENTINEL}")" == external-client-qemu-v1 ]] || \
            fail "refusing to remove an unrecognized state directory"
        rm -rf -- "${TMP_DIR}"
    fi
    [[ "${cleanup_ok}" == true ]] || return 1
}
trap cleanup EXIT

if [[ "${MODE}" == cleanup ]]; then
    trap - EXIT
    cleanup yes || exit $?
    echo "[E2E] cleanup=complete"
    exit 0
fi

echo "[E2E] external client -> real VPS ${VPS_HOST}:${VPS_WG_PORT}"

# --- register the client peer on the VPS --------------------------------------
echo "[E2E] checking the VPS is reachable and wg-easy is running"
"${SSH_CMD[@]}" 'sudo docker ps --format "{{.Names}} {{.Status}}" | grep -q "^wg-easy " && echo VPS_OK' \
    >/dev/null 2>&1 || fail "VPS ${VPS_HOST} is not reachable or wg-easy is not running"

echo "[E2E] generating a client keypair and registering the peer"
CLIENT_PRIV="$("${SSH_CMD[@]}" 'sudo docker exec wg-easy wg genkey' 2>/dev/null | grep -v setlocale | tr -d '\r')"
[[ -n "${CLIENT_PRIV}" ]] || fail "could not generate a client key inside the wg-easy container"
CLIENT_PUB="$(printf '%s' "${CLIENT_PRIV}" | "${SSH_CMD[@]}" 'sudo docker exec -i wg-easy wg pubkey' 2>/dev/null | grep -v setlocale | tr -d '\r')"
CLIENT_PSK="$("${SSH_CMD[@]}" 'sudo docker exec wg-easy wg genpsk' 2>/dev/null | grep -v setlocale | tr -d '\r')"
SERVER_PUB="$("${SSH_CMD[@]}" 'sudo docker exec wg-easy wg show wg0 public-key' 2>/dev/null | grep -v setlocale | tr -d '\r')"
[[ -n "${CLIENT_PUB}" && -n "${CLIENT_PSK}" && -n "${SERVER_PUB}" ]] || fail "could not derive WireGuard keys"
[[ "${CLIENT_PUB}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "client public key has an invalid shape"
[[ "${CLIENT_PSK}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "client preshared key has an invalid shape"

if [[ "${FULL_TUNNEL}" == 1 ]]; then
    CLIENT_ALLOWED="0.0.0.0/0, ::/0"
    MODE_LABEL="full tunnel"
else
    CLIENT_ALLOWED="10.8.0.0/24, 10.66.0.2/32, 10.66.0.3/32"
    MODE_LABEL="split tunnel"
fi

peer_tmp="$(mktemp "${TMP_DIR}/peer.env.tmp.XXXXXX")"
printf 'PEER_PUBLIC_KEY=%s\nVPS_HOST=%s\nVPS_SSH_PORT=%s\nVPS_SSH_USER=%s\n' \
    "${CLIENT_PUB}" "${VPS_HOST}" "${VPS_SSH_PORT}" "${VPS_SSH_USER}" >"${peer_tmp}"
chmod 0600 "${peer_tmp}"
mv -f -- "${peer_tmp}" "${TMP_DIR}/peer.env"

if [[ "${F3_LITERAL_DNS}" == 1 ]]; then
    "${SSH_CMD[@]}" "sudo grep -Fqx '      answer: 10.66.0.3' /opt/vps-nook/volumes/adguard/conf/AdGuardHome.yaml && sudo sed -i 's/answer: 10.66.0.3/answer: 10.8.0.1/' /opt/vps-nook/volumes/adguard/conf/AdGuardHome.yaml && sudo docker restart adguard >/dev/null"
    printf 'f3-dns-injected-v1\n' >"${TMP_DIR}/f3-dns-injected"
fi

registration_tmp="$(mktemp "${TMP_DIR}/peer-registration.tmp.XXXXXX")"
printf '%s\n%s\n%s\n%s\n' "${CLIENT_PRIV}" "${CLIENT_PUB}" "${CLIENT_PSK}" "${CLIENT_ALLOWED}" >"${registration_tmp}"
chmod 0600 "${registration_tmp}"
copy_remote_authenticated "${VPS_SSH_USER}@${VPS_HOST}" "${VPS_SSH_PORT}" "${VPS_SSH_KEY}" \
    "${VPS_KNOWN_HOSTS}" "${registration_tmp}" /tmp/zt-f3-peer-registration
rm -f -- "${registration_tmp}"
# shellcheck disable=SC2016
"${SSH_CMD[@]}" 'sudo install -o root -g root -m 0600 /tmp/zt-f3-peer-registration /var/tmp/zt-f3-peer-registration && rm -f -- /tmp/zt-f3-peer-registration && sudo docker stop wg-easy >/dev/null && sudo python3 - <<'"'"'PY'"'"'
import json
import sqlite3

path = "/var/tmp/zt-f3-peer-registration"
private_key, public_key, preshared_key, allowed = open(path, encoding="ascii").read().splitlines()
db_path = "/opt/vps-nook/volumes/wg-easy/wg-easy.db"
with sqlite3.connect(db_path) as db:
    conflict = db.execute(
        "SELECT 1 FROM clients_table WHERE name = ? OR ipv4_address = ? OR public_key = ?",
        ("zt-f3-restore", "10.8.0.5", public_key),
    ).fetchone()
    if conflict is not None:
        raise SystemExit("test peer identity or address is already registered")
    db.execute(
        """INSERT INTO clients_table (
        user_id, interface_id, name, ipv4_address, ipv6_address,
        pre_up, post_up, pre_down, post_down, private_key, public_key,
        pre_shared_key, expires_at, allowed_ips, server_allowed_ips,
        persistent_keepalive, mtu, dns, server_endpoint, enabled
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (1, "wg0", "zt-f3-restore", "10.8.0.5", "fd42:42:42::5", "", "", "", "",
         private_key, public_key, preshared_key, None,
         json.dumps([item.strip() for item in allowed.split(",")]),
         json.dumps(["10.8.0.5/32", "fd42:42:42::5/128"]), 25, 1420,
         json.dumps(["10.66.0.2"]), None, 1),
    )
PY
sudo rm -f -- /var/tmp/zt-f3-peer-registration
sudo docker start wg-easy >/dev/null
for attempt in $(seq 1 30); do sudo docker exec wg-easy wg show wg0 >/dev/null 2>&1 && exit 0; sleep 1; done
exit 1'
pass "peer ${CLIENT_IP} registered on the VPS"

echo "[E2E] fetching the private root CA from the VPS"
ROOT_CA="${TMP_DIR}/root.crt"
"${SSH_CMD[@]}" 'sudo cat /opt/vps-nook-installer/repo/fetched_certs/localhost/root.crt' \
    2>/dev/null | grep -v setlocale > "${ROOT_CA}"
chmod 600 "${ROOT_CA}"
grep -q 'BEGIN CERTIFICATE' "${ROOT_CA}" || fail "root CA could not be fetched"

# --- client configuration (mirrors the wg-easy default template) ---------------
cat > "${TMP_DIR}/client.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_IP}/32, ${CLIENT_IPV6}/128
DNS = 10.66.0.2

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${VPS_WG_ENDPOINT_HOST}:${VPS_WG_PORT}
AllowedIPs = ${CLIENT_ALLOWED}
PersistentKeepalive = 25
EOF
echo "[E2E] client mode: ${MODE_LABEL}, injected WireGuard endpoint configured"

# --- boot the client VM ---------------------------------------------------------
ssh-keygen -q -t ed25519 -N "" -f "${TMP_DIR}/id_ed25519" -C "ztvps-ext-client"
boot_vm "${TMP_DIR}" "${QEMU_IMAGE}" 10 1024 1 ztvps-ext-client ztvps-ext-client "" \
    "hostfwd=tcp:127.0.0.1:${QEMU_SSH_PORT}-:22"

GUEST="debian@127.0.0.1"
echo "[E2E] waiting for the client VM SSH..."
require_ssh_ready "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" 60
CLIENT_KNOWN_HOSTS="${TMP_DIR}/known_hosts"
: >"${CLIENT_KNOWN_HOSTS}"
chmod 0600 "${CLIENT_KNOWN_HOSTS}"
record_ssh_host_key 127.0.0.1 "${QEMU_SSH_PORT}" "${CLIENT_KNOWN_HOSTS}"
require_wrong_host_key_rejected "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519"
require_wrong_scp_host_key_rejected "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519"
E2E_KNOWN_HOSTS="${CLIENT_KNOWN_HOSTS}"
export E2E_KNOWN_HOSTS

echo "[E2E] copying the client config and root CA into the VM"
run_remote_stdin "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
    'cat > /tmp/zt-ext.conf && chmod 600 /tmp/zt-ext.conf' < "${TMP_DIR}/client.conf"
run_remote_stdin "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
    'cat > /tmp/root.crt && chmod 600 /tmp/root.crt' < "${ROOT_CA}"

# --- in-VM verification -----------------------------------------------------------
echo "[E2E] installing wireguard-tools and bringing the tunnel up"
run_remote_stdin "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
    "sudo F3_LITERAL_DNS='${F3_LITERAL_DNS}' bash -s" <<'RREMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq >/dev/null
sudo apt-get install -y -qq curl wireguard-tools dnsutils openssl >/dev/null 2>&1
[[ -e /dev/net/tun ]] || { echo "[FAIL] /dev/net/tun is missing" >&2; exit 1; }
sudo wg-quick up /tmp/zt-ext.conf
sleep 4

caddy_target=10.66.0.3
if [[ "${F3_LITERAL_DNS}" == 1 ]]; then
    # The F3 fixture addresses Caddy through the WireGuard server IP. Keep its
    # translation inside the disposable client so traffic traverses the tunnel.
    caddy_target=10.8.0.1
    sudo iptables -t nat -A OUTPUT -d "${caddy_target}/32" -p tcp --dport 443 \
        -j DNAT --to-destination 10.66.0.3
fi

if ! ping -c 2 -W 4 10.66.0.2 >/dev/null 2>&1; then
    echo "[FAIL] AdGuard on the VPS (10.66.0.2) is not reachable over the real internet tunnel" >&2
    exit 1
fi
echo "[PASS] AdGuard reachable over the real internet tunnel"

echo "--- DNS via the VPS AdGuard (10.66.0.2) ---"
for d in "${WG_INTERNAL_DOMAIN:-wg.internal}" "${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}"; do
    echo "  ${d} -> $(dig +short @10.66.0.2 "${d}" | tr '\n' ' ')"
done
[[ "$(dig +short @10.66.0.2 "${WG_INTERNAL_DOMAIN:-wg.internal}" A)" == "${caddy_target}" ]] \
    || { echo "[FAIL] Caddy DNS address is wrong" >&2; exit 1; }

if ! curl -fsS --resolve "${WG_INTERNAL_DOMAIN:-wg.internal}:443:${caddy_target}" --cacert /tmp/root.crt \
    "https://${WG_INTERNAL_DOMAIN:-wg.internal}/" -o /dev/null; then
    echo "[FAIL] https://${WG_INTERNAL_DOMAIN:-wg.internal} not reachable over the real internet tunnel" >&2
    exit 1
fi
echo "[PASS] https://${WG_INTERNAL_DOMAIN:-wg.internal} reachable (trusted VPS private CA)"

for policy_path in /cnf /cnf/ /cnf/probe; do
    headers="$(mktemp)"
    status="$(curl -ksS -D "${headers}" \
        --resolve "${WG_INTERNAL_DOMAIN:-wg.internal}:443:${caddy_target}" \
        "https://${WG_INTERNAL_DOMAIN:-wg.internal}${policy_path}" \
        -o /dev/null -w '%{http_code}')"
    [[ "${status}" == 404 ]] || { echo "[FAIL] ${policy_path} returned ${status}" >&2; exit 1; }
    policy_value="$(awk -F ': *' \
        'tolower($1) == "x-zero-trust-policy" {gsub(/\r$/, "", $2); print $2}' \
        "${headers}")"
    [[ "${policy_value}" == cve-2026-63089 ]] || {
        echo "[FAIL] ${policy_path} lacked the CVE policy header" >&2
        exit 1
    }
    rm -f -- "${headers}"
done
echo "[PASS] CVE route policy rejected all protected paths"

session_status="$(curl -ksS -o /dev/null -w '%{http_code}' \
    --resolve "${WG_INTERNAL_DOMAIN:-wg.internal}:443:${caddy_target}" \
    "https://${WG_INTERNAL_DOMAIN:-wg.internal}/api/session")"
[[ "${session_status}" == 401 ]] || { echo "[FAIL] unauthenticated session returned ${session_status}" >&2; exit 1; }
echo "[PASS] unauthenticated session rejected"

if ! curl -fsS --resolve "${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}:443:10.66.0.3" --cacert /tmp/root.crt \
    "https://${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}/" -o /dev/null; then
    echo "[FAIL] https://${ADGUARD_INTERNAL_DOMAIN:-adguard.internal} not reachable over the real internet tunnel" >&2
    exit 1
fi
echo "[PASS] https://${ADGUARD_INTERNAL_DOMAIN:-adguard.internal} reachable (trusted VPS private CA)"

echo "--- certificate served by the VPS Caddy for ${WG_INTERNAL_DOMAIN:-wg.internal} ---"
echo | openssl s_client -connect 10.66.0.3:443 -servername "${WG_INTERNAL_DOMAIN:-wg.internal}" \
    -CAfile /tmp/root.crt 2>/dev/null \
    | openssl x509 -noout -issuer -dates -ext subjectAltName 2>/dev/null \
    || echo "  cannot inspect the served certificate"

echo "--- WireGuard handshake with the real VPS ---"
wg show | grep -E 'interface:|endpoint:|handshake:|transfer:' || true
latest_handshake="$(wg show all latest-handshakes | awk '{print $NF}' | sort -rn | head -1)"
handshake_now="$(date +%s)"
[[ "${latest_handshake}" =~ ^[0-9]+$ ]] && \
    ((latest_handshake > 0 && latest_handshake <= handshake_now && handshake_now - latest_handshake < 180)) || {
    echo "[FAIL] external client has no recent WireGuard handshake" >&2
    exit 1
}
echo "[PASS] external client has a recent WireGuard handshake"

# egress through the VPS is informational (needs FULL_TUNNEL + VPS masquerade)
if ip route | grep -q '^default.*zt-ext'; then
    echo "--- internet egress through the VPS (full tunnel) ---"
    public_ip="$(curl -fsS --max-time 15 https://ifconfig.me 2>/dev/null || true)"
    echo "  egress IP via the tunnel: ${public_ip:-<unavailable>}"
fi

echo "[PASS] external WireGuard client -> real VPS E2E succeeded"
RREMOTE

if [[ "${MODE}" == prepare ]]; then
    connection_tmp="$(mktemp "${TMP_DIR}/connection.env.tmp.XXXXXX")"
    printf 'CLIENT_SSH_HOST=127.0.0.1\nCLIENT_SSH_PORT=%s\nCLIENT_SSH_USER=debian\nCLIENT_SSH_KEY=%s/id_ed25519\nCLIENT_KNOWN_HOSTS=%s/known_hosts\n' \
        "${QEMU_SSH_PORT}" "${TMP_DIR}" "${TMP_DIR}" >"${connection_tmp}"
    chmod 0600 "${connection_tmp}"
    mv -f -- "${connection_tmp}" "${TMP_DIR}/connection.env"
    trap - EXIT
    echo "[E2E] prepare-only state ready"
    exit 0
fi

# --- final report -----------------------------------------------------------------
echo "[E2E] PASS: real external client to ${VPS_HOST} succeeded"
if [[ "${KEEP_PEER}" == "1" ]]; then
    echo "[E2E] note: the test peer was kept on the VPS (KEEP_PEER=1); config in ${TMP_DIR}/client.conf (removed on exit)"
fi
