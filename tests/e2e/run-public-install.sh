#!/usr/bin/env bash
# Manual E2E against a real VPS using the installer from an explicit Git ref.
#
# Usage:
#   VPS_IP=... VPS_SSH_KEY=... INSTALL_REF=v1.0.0 tests/e2e/run-public-install.sh [--reboot-test] [--client-test]
#
# Required env:
#   VPS_IP        public IP of a fresh VPS with root SSH access
#   VPS_SSH_KEY   identity file for root SSH access
#   INSTALL_REF   git tag or branch to install (e.g. v1.0.0)
# Optional env:
#   VPS_SSH_PORT (default 22), VPS_ROOT_USER (default root),
#   NOOK_* installer inputs (NOOK_ADMIN_SSH_KEY is a controller-only
#   private key path; only its derived public key is provisioned),
#   E2E_SSH_PORT (default 2222), E2E_WG_PORT (default 51820)
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${E2E_DIR}/../.." && pwd)"
cd "${ROOT_DIR}"
INTERNAL_DOMAIN_SUFFIX="${NOOK_INTERNAL_DOMAIN_SUFFIX:-${INTERNAL_DOMAIN_SUFFIX:-internal}}"
WG_INTERNAL_DOMAIN="${WG_INTERNAL_DOMAIN:-wg.${INTERNAL_DOMAIN_SUFFIX}}"
ADGUARD_INTERNAL_DOMAIN="${ADGUARD_INTERNAL_DOMAIN:-adguard.${INTERNAL_DOMAIN_SUFFIX}}"
# shellcheck disable=SC1091
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

: "${VPS_IP:?VPS_IP is required}"
: "${VPS_SSH_KEY:?VPS_SSH_KEY is required}"
: "${INSTALL_REF:?INSTALL_REF is required}"
: "${VPS_KNOWN_HOSTS:?VPS_KNOWN_HOSTS (pinned host-key file) is required}"

VPS_SSH_PORT="${VPS_SSH_PORT:-22}"
VPS_ROOT_USER="${VPS_ROOT_USER:-root}"
E2E_SSH_PORT="${E2E_SSH_PORT:-2222}"
E2E_WG_PORT="${E2E_WG_PORT:-51820}"
DO_REBOOT=false
DO_CLIENT_TEST=false
for arg in "$@"; do
    case "${arg}" in
        --reboot-test) DO_REBOOT=true ;;
        --client-test) DO_CLIENT_TEST=true ;;
        *) fail "Unknown argument: ${arg}" ;;
    esac
done

ROOT_TARGET="${VPS_ROOT_USER}@${VPS_IP}"
command -v ssh-keygen >/dev/null || fail "ssh-keygen not found"
command -v openssl >/dev/null || fail "openssl not found"
command -v nc >/dev/null || fail "nc not found"
command -v timeout >/dev/null || fail "timeout not found"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-vps.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

ssh-keygen -q -t ed25519 -N "" -f "${TMP_DIR}/id_ed25519" -C "e2e-ztvps"
# The operator can hand the admin user their own key pair so that access
# survives the harness (TMP_DIR is destroyed on exit). When unset, the
# ephemeral harness key is used for both the installer and post-install SSH.
ADMIN_SSH_KEY="${NOOK_ADMIN_SSH_KEY:-${TMP_DIR}/id_ed25519}"
[[ -f "${ADMIN_SSH_KEY}" ]] || fail "admin SSH private key is not a regular file"
ADMIN_PUBKEY="$(ssh-keygen -y -f "${ADMIN_SSH_KEY}")"
ADMIN_FINGERPRINT="$(printf '%s\n' "${ADMIN_PUBKEY}" | ssh-keygen -lf - | awk '{print $2}')"
[[ "${ADMIN_FINGERPRINT}" == SHA256:* ]] || fail "could not derive admin public-key fingerprint"

ADMIN_USER="${NOOK_ADMIN_USER:-sysadmin}"
ADMIN_PASS="${NOOK_ADMIN_PASSWORD:-$(openssl rand -hex 12)}"
ADGUARD_PASS="${NOOK_ADGUARD_PASSWORD:-$(openssl rand -hex 12)}"
WG_PASS="${NOOK_WG_PASSWORD:-$(openssl rand -hex 12)}"
SSH_PORT_IN="${NOOK_SSH_PORT:-${E2E_SSH_PORT}}"
WG_PORT_IN="${NOOK_WG_PORT:-${E2E_WG_PORT}}"
INTERNAL_DOMAINS="${NOOK_INTERNAL_DOMAINS:-${WG_INTERNAL_DOMAIN} ${ADGUARD_INTERNAL_DOMAIN}}"
TRAFFIC_MODE="${NOOK_WG_TRAFFIC_MODE:-services}"
INSTALL_DEV_MODE="${NOOK_DEV_MODE:-}"
if [[ -z "${INSTALL_DEV_MODE}" && ! "${INSTALL_REF}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    INSTALL_DEV_MODE=1
fi

KNOWN_HOSTS="${VPS_KNOWN_HOSTS}"
[[ -s "${KNOWN_HOSTS}" ]] || fail "VPS_KNOWN_HOSTS must contain a pinned host key"
chmod 0600 "${KNOWN_HOSTS}"
E2E_KNOWN_HOSTS="${KNOWN_HOSTS}"
export E2E_KNOWN_HOSTS
echo "[E2E] Waiting for root SSH on ${ROOT_TARGET}:${VPS_SSH_PORT}"
require_ssh_ready "${ROOT_TARGET}" "${VPS_SSH_PORT}" "${VPS_SSH_KEY}" 30
run_remote_authenticated "${ROOT_TARGET}" "${VPS_SSH_PORT}" "${VPS_SSH_KEY}" \
    "${KNOWN_HOSTS}" true
require_wrong_host_key_rejected "${ROOT_TARGET}" "${VPS_SSH_PORT}" "${VPS_SSH_KEY}"
require_wrong_scp_host_key_rejected "${ROOT_TARGET}" "${VPS_SSH_PORT}" "${VPS_SSH_KEY}"
SWAP_BEFORE="$(run_remote_authenticated "${ROOT_TARGET}" "${VPS_SSH_PORT}" "${VPS_SSH_KEY}" \
    "${KNOWN_HOSTS}" "awk 'NR > 1 { print \$1, \$2, \$3, \$5 }' /proc/swaps")"

# The harness downloads the installer before privileged execution; minimal
# Debian images ship neither curl nor sudo by default.
echo "[E2E] Ensuring curl and sudo are available on the VPS..."
run_remote_authenticated "${ROOT_TARGET}" "${VPS_SSH_PORT}" "${VPS_SSH_KEY}" \
    "${KNOWN_HOSTS}" \
    '(command -v curl >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1) || (apt-get update -qq >/dev/null && apt-get install -y -qq curl sudo >/dev/null)' \
    || fail "could not install curl/sudo on the VPS"

INSTALL_URL="https://raw.githubusercontent.com/NikitaS2001/vps-nook/${INSTALL_REF}/install.sh"
echo "[E2E] Running the public installer from ${INSTALL_URL}"

REMOTE_INSTALL=$(cat <<INNER_EOF
set -euo pipefail
installer_path=\$(mktemp /tmp/vps-nook-install.XXXXXX)
trap 'rm -f "\${installer_path}"' EXIT
curl -fsSL '${INSTALL_URL}' -o "\${installer_path}"
chmod 0700 "\${installer_path}"
installer_env=(
    NOOK_NONINTERACTIVE=1
    NOOK_DEV_MODE='${INSTALL_DEV_MODE}'
    NOOK_REPO_URL=https://github.com/NikitaS2001/vps-nook.git
    NOOK_RELEASE_REF='${INSTALL_REF}'
)
if ! sudo test -s /etc/vps-nook/installer-vault.yml; then
    installer_env+=(
        NOOK_SSH_PORT='${SSH_PORT_IN}'
        NOOK_WG_PORT='${WG_PORT_IN}'
        NOOK_ADMIN_USER='${ADMIN_USER}'
        NOOK_ADMIN_PASSWORD='${ADMIN_PASS}'
        NOOK_ADGUARD_PASSWORD='${ADGUARD_PASS}'
        NOOK_WG_PASSWORD='${WG_PASS}'
        NOOK_WG_TRAFFIC_MODE='${TRAFFIC_MODE}'
        NOOK_INTERNAL_DOMAIN_SUFFIX='${INTERNAL_DOMAIN_SUFFIX}'
        NOOK_INTERNAL_DOMAINS='${INTERNAL_DOMAINS}'
        NOOK_SSH_PUBKEY='${ADMIN_PUBKEY}'
    )
fi
sudo env "\${installer_env[@]}" bash "\${installer_path}"
INNER_EOF
)
run_remote_authenticated "${ROOT_TARGET}" "${VPS_SSH_PORT}" "${VPS_SSH_KEY}" \
    "${KNOWN_HOSTS}" 'bash -s' <<<"${REMOTE_INSTALL}"

echo "[E2E] Verifying the deployed stack on the hardened SSH port ${SSH_PORT_IN}"
if ! ssh-keygen -F "[${VPS_IP}]:${SSH_PORT_IN}" -f "${KNOWN_HOSTS}" >/dev/null; then
    record_ssh_host_key "${VPS_IP}" "${SSH_PORT_IN}" "${KNOWN_HOSTS}"
fi
run_remote_authenticated "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" \
    "${ADMIN_SSH_KEY}" "${KNOWN_HOSTS}" \
    "grep -Fqx '${ADMIN_PUBKEY}' ~/.ssh/authorized_keys"
require_wrong_host_key_rejected "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${ADMIN_SSH_KEY}"
export E2E_SSH_PORT="${SSH_PORT_IN}" E2E_WG_PORT="${WG_PORT_IN}"
E2E_KNOWN_HOSTS="${KNOWN_HOSTS}" verify_deployment \
    "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${ADMIN_SSH_KEY}"
E2E_KNOWN_HOSTS="${KNOWN_HOSTS}" verify_traffic_mode \
    "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${ADMIN_SSH_KEY}" "${TRAFFIC_MODE}"
VAULT_PAIR_BEFORE="$(run_remote_authenticated "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" \
    "${ADMIN_SSH_KEY}" "${KNOWN_HOSTS}" \
    "sudo sha256sum /etc/vps-nook/installer-vault.pass /etc/vps-nook/installer-vault.yml")"
echo "[E2E] Re-running the installer without any credential inputs..."
REMOTE_RERUN=$(cat <<INNER_RERUN
set -euo pipefail
installer_path=\$(mktemp /tmp/vps-nook-install.XXXXXX)
trap 'rm -f "\${installer_path}"' EXIT
curl -fsSL '${INSTALL_URL}' -o "\${installer_path}"
chmod 0700 "\${installer_path}"
sudo env \\
    NOOK_NONINTERACTIVE=1 \\
    NOOK_DEV_MODE='${INSTALL_DEV_MODE}' \\
    NOOK_REPO_URL=https://github.com/NikitaS2001/vps-nook.git \\
    NOOK_RELEASE_REF='${INSTALL_REF}' \\
    bash "\${installer_path}"
INNER_RERUN
)
run_remote_authenticated "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" \
    "${ADMIN_SSH_KEY}" "${KNOWN_HOSTS}" 'bash -s' <<<"${REMOTE_RERUN}"
VAULT_PAIR_AFTER="$(run_remote_authenticated "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" \
    "${ADMIN_SSH_KEY}" "${KNOWN_HOSTS}" \
    "sudo sha256sum /etc/vps-nook/installer-vault.pass /etc/vps-nook/installer-vault.yml")"
[[ "${VAULT_PAIR_BEFORE}" == "${VAULT_PAIR_AFTER}" ]] || fail "credential-free rerun changed the encrypted installer state"
pass "credential-free installer rerun preserved encrypted secrets"
SWAP_AFTER="$(run_remote_authenticated "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" \
    "${ADMIN_SSH_KEY}" "${KNOWN_HOSTS}" "awk 'NR > 1 { print \$1, \$2, \$3, \$5 }' /proc/swaps")"
[[ "${SWAP_BEFORE}" == "${SWAP_AFTER}" ]] || fail "installer changed provider swap configuration"
pass "provider swap configuration unchanged"
run_remote_authenticated "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" \
    "${ADMIN_SSH_KEY}" "${KNOWN_HOSTS}" \
    "test \"\$(sudo stat -c %a /etc/vps-nook)\" = 700 && test \"\$(sudo stat -c %a /etc/vps-nook/installer-vault.yml)\" = 600 && sudo grep -Fq '\$ANSIBLE_VAULT;' /etc/vps-nook/installer-vault.yml"
pass "installer secrets persisted only in a private encrypted vault"
if timeout 6 nc -z -w 5 "${VPS_IP}" 443 >/dev/null 2>&1; then
    fail "public TCP/443 is reachable"
fi
pass "public TCP/443 is closed"

if [[ "${DO_REBOOT}" == "true" ]]; then
    echo "[E2E] Rebooting ${VPS_IP} and re-verifying..."
    boot_id_before="$(E2E_KNOWN_HOSTS="${KNOWN_HOSTS}" run_remote \
        "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${ADMIN_SSH_KEY}" \
        'cat /proc/sys/kernel/random/boot_id')"
    run_remote_authenticated "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" \
        "${ADMIN_SSH_KEY}" "${KNOWN_HOSTS}" 'sudo systemctl reboot' || true
    E2E_KNOWN_HOSTS="${KNOWN_HOSTS}" require_rebooted \
        "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${ADMIN_SSH_KEY}" \
        "${boot_id_before}" 60
    sleep 20
    E2E_KNOWN_HOSTS="${KNOWN_HOSTS}" verify_deployment \
        "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${ADMIN_SSH_KEY}"
    E2E_KNOWN_HOSTS="${KNOWN_HOSTS}" verify_traffic_mode \
        "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${ADMIN_SSH_KEY}" "${TRAFFIC_MODE}"
    echo "[E2E] Reboot survival verified"
fi

if [[ "${DO_CLIENT_TEST}" == "true" ]]; then
    echo "[E2E] Installing wireguard-tools and jq on the VPS..."
    run_remote "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${ADMIN_SSH_KEY}" \
        'sudo apt-get update -qq >/dev/null && sudo apt-get install -y -qq wireguard-tools jq openssl dnsutils resolvconf >/dev/null'
    echo "[E2E] Running the in-guest WireGuard client handshake test..."
    run_remote_stdin "${ADMIN_USER}@${VPS_IP}" "${SSH_PORT_IN}" "${ADMIN_SSH_KEY}" \
        "sudo WG_PASSWORD='${WG_PASS}' WG_PORT='${WG_PORT_IN}' WG_TRAFFIC_MODE='${TRAFFIC_MODE}' WG_INTERNAL_DOMAIN='${WG_INTERNAL_DOMAIN}' ADGUARD_INTERNAL_DOMAIN='${ADGUARD_INTERNAL_DOMAIN}' bash -s" \
        < "${E2E_DIR}/client-in-guest.sh"
fi

echo "[E2E] PASS: public installer E2E succeeded for ${VPS_IP} (${INSTALL_REF})"
