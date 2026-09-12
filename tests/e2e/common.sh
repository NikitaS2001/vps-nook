#!/usr/bin/env bash
# Shared helpers for tests/e2e/*.sh
set -euo pipefail

# Internal domain names, overridable via the environment for deployments that
# use a custom internal_domain_suffix.
WG_INTERNAL_DOMAIN="${WG_INTERNAL_DOMAIN:-wg.internal}"
ADGUARD_INTERNAL_DOMAIN="${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}"

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[PASS] $*"
}

validate_recent_matching_handshake_epochs() {
    local now="$1" client_epoch="$2" server_epoch="$3"

    [[ "${now}" =~ ^[1-9][0-9]*$ \
        && "${client_epoch}" =~ ^[1-9][0-9]*$ \
        && "${server_epoch}" =~ ^[1-9][0-9]*$ ]] || return 1
    ((client_epoch <= now && server_epoch <= now)) || return 1
    ((now - client_epoch < 180 && now - server_epoch < 180)) || return 1
    [[ "${client_epoch}" == "${server_epoch}" ]]
}

validate_restored_handshake_epochs() {
    local now="$1" boundary="$2" pre_client="$3" pre_server="$4"
    local client_epoch="$5" server_epoch="$6"

    [[ "${boundary}" =~ ^[1-9][0-9]*$ \
        && "${pre_client}" =~ ^[1-9][0-9]*$ \
        && "${pre_server}" =~ ^[1-9][0-9]*$ ]] || return 1
    validate_recent_matching_handshake_epochs \
        "${now}" "${client_epoch}" "${server_epoch}" || return 1
    ((client_epoch > pre_client && server_epoch > pre_server)) || return 1
    ((client_epoch >= boundary && server_epoch >= boundary))
}

run_remote() {
    local target="$1"; shift
    local port="$1"; shift
    local key="$1"; shift
    if [[ -n "${E2E_KNOWN_HOSTS:-}" ]]; then
        run_remote_authenticated "${target}" "${port}" "${key}" \
            "${E2E_KNOWN_HOSTS}" "$@"
        return
    fi
    ssh -p "${port}" -i "${key}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes \
        "${target}" "$@"
}

run_remote_stdin() {
    local target="$1"; shift
    local port="$1"; shift
    local key="$1"; shift
    if [[ -n "${E2E_KNOWN_HOSTS:-}" ]]; then
        run_remote_authenticated "${target}" "${port}" "${key}" \
            "${E2E_KNOWN_HOSTS}" "$@"
        return
    fi
    ssh -p "${port}" -i "${key}" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes \
        "${target}" "$@"
}

record_ssh_host_key() {
    local host="$1" port="$2" known_hosts="$3"
    local scan_file
    scan_file="$(mktemp "${known_hosts}.scan.XXXXXX")"
    chmod 0600 "${scan_file}"
    if ! ssh-keyscan -T 5 -p "${port}" -t ed25519 "${host}" \
        >"${scan_file}" 2>/dev/null; then
        rm -f "${scan_file}"
        fail "could not record SSH host key for ${host}:${port}"
    fi
    if [[ "$(sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' "${scan_file}" | wc -l)" -ne 1 ]]; then
        rm -f "${scan_file}"
        fail "expected exactly one ED25519 host key for ${host}:${port}"
    fi
    cat "${scan_file}" >>"${known_hosts}"
    rm -f "${scan_file}"
    chmod 0600 "${known_hosts}"
}

# Authenticated SSH used by cutover/rollback probes. Keep this option vector in
# lock-step with the production verification contract.
run_remote_authenticated() {
    local target="$1" port="$2" key="$3" known_hosts="$4"
    shift 4
    ssh -F none -i "${key}" -p "${port}" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${known_hosts}" \
        -o GlobalKnownHostsFile=/dev/null \
        "${target}" "$@"
}

copy_remote_authenticated() {
    local host="$1" port="$2" key="$3" known_hosts="$4" source="$5" destination="$6"
    scp -F none -i "${key}" -P "${port}" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${known_hosts}" \
        -o GlobalKnownHostsFile=/dev/null \
        "${source}" "${host}:${destination}"
}

require_wrong_host_key_rejected() {
    local target="$1" port="$2" key="$3"
    local probe_dir bad_hosts host
    probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-hostkey.XXXXXX")"
    bad_hosts="${probe_dir}/known_hosts"
    host="${target#*@}"
    ssh-keygen -q -t ed25519 -N '' -f "${probe_dir}/host" -C host-key-negative
    printf '[%s]:%s %s\n' "${host}" "${port}" \
        "$(cut -d' ' -f1,2 "${probe_dir}/host.pub")" >"${bad_hosts}"
    chmod 0600 "${bad_hosts}"
    if run_remote_authenticated "${target}" "${port}" "${key}" "${bad_hosts}" \
        true >/dev/null 2>&1; then
        rm -rf -- "${probe_dir}"
        fail "SSH accepted a mismatched pinned host key"
    fi
    rm -rf -- "${probe_dir}"
    pass "SSH rejected a mismatched pinned host key"
}

require_wrong_scp_host_key_rejected() {
    local target="$1" port="$2" key="$3"
    local probe_dir bad_hosts host
    probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-scp-hostkey.XXXXXX")"
    bad_hosts="${probe_dir}/known_hosts"
    host="${target#*@}"
    ssh-keygen -q -t ed25519 -N '' -f "${probe_dir}/host" -C scp-host-key-negative
    printf '[%s]:%s %s\n' "${host}" "${port}" \
        "$(cut -d' ' -f1,2 "${probe_dir}/host.pub")" >"${bad_hosts}"
    printf 'host-key-negative\n' >"${probe_dir}/payload"
    chmod 0600 "${bad_hosts}" "${probe_dir}/payload"
    if copy_remote_authenticated "${target}" "${port}" "${key}" "${bad_hosts}" \
        "${probe_dir}/payload" /tmp/ztvps-scp-host-key-negative; then
        rm -rf -- "${probe_dir}"
        fail "SCP accepted a mismatched pinned host key"
    fi
    rm -rf -- "${probe_dir}"
    pass "SCP rejected a mismatched pinned host key"
}

open_authenticated_ssh_control() {
    local target="$1" port="$2" key="$3" known_hosts="$4" control_socket="$5"
    ssh -F none -i "${key}" -p "${port}" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${known_hosts}" \
        -o GlobalKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o ControlMaster=yes -o ControlPath="${control_socket}" \
        -o ControlPersist=600 -fN "${target}"
}

run_remote_over_control() {
    local target="$1" port="$2" key="$3" known_hosts="$4" control_socket="$5"
    shift 5
    ssh -F none -i "${key}" -p "${port}" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${known_hosts}" \
        -o GlobalKnownHostsFile=/dev/null \
        -o ControlPath="${control_socket}" \
        "${target}" "$@"
}

close_authenticated_ssh_control() {
    local target="$1" port="$2" key="$3" known_hosts="$4" control_socket="$5"
    ssh -F none -i "${key}" -p "${port}" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${known_hosts}" \
        -o GlobalKnownHostsFile=/dev/null \
        -o ControlPath="${control_socket}" -O exit "${target}" >/dev/null
}

require_authenticated_ssh_closed() {
    local target="$1" port="$2" key="$3" known_hosts="$4"
    if run_remote_authenticated "${target}" "${port}" "${key}" "${known_hosts}" \
        'true' >/dev/null 2>&1; then
        fail "authenticated SSH unexpectedly remained open on ${target}:${port}"
    fi
}

require_ssh_down() {
    local target="$1"; local port="$2"; local key="$3"; local retries="${4:-30}"
    local i=0
    while if [[ -n "${E2E_KNOWN_HOSTS:-}" ]]; then
        run_remote_authenticated "${target}" "${port}" "${key}" \
            "${E2E_KNOWN_HOSTS}" true >/dev/null 2>&1
    else
        ssh -p "${port}" -i "${key}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=3 -o BatchMode=yes \
            "${target}" true >/dev/null 2>&1
    fi; do
        i=$((i + 1))
        if [[ "${i}" -ge "${retries}" ]]; then
            fail "SSH on ${target}:${port} did not go down (expected after reboot)"
        fi
        sleep 3
    done
}

require_ssh_ready() {
    local target="$1"; local port="$2"; local key="$3"; local retries="${4:-30}"
    local i=0
    while ! if [[ -n "${E2E_KNOWN_HOSTS:-}" ]]; then
        run_remote_authenticated "${target}" "${port}" "${key}" \
            "${E2E_KNOWN_HOSTS}" true >/dev/null 2>&1
    else
        ssh -p "${port}" -i "${key}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 -o BatchMode=yes \
            "${target}" true >/dev/null 2>&1
    fi; do
        i=$((i + 1))
        if [[ "${i}" -ge "${retries}" ]]; then
            fail "SSH did not become ready on ${target}:${port}"
        fi
        sleep 5
    done
}

require_rebooted() {
    local target="$1" port="$2" key="$3" previous_boot_id="$4" retries="${5:-60}"
    local current_boot_id i=0
    while true; do
        current_boot_id="$(run_remote "${target}" "${port}" "${key}" \
            'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
        if [[ "${current_boot_id}" =~ ^[0-9a-f-]{36}$ && \
              "${current_boot_id}" != "${previous_boot_id}" ]]; then
            return 0
        fi
        i=$((i + 1))
        [[ "${i}" -lt "${retries}" ]] || \
            fail "guest did not return with a new boot identity"
        sleep 5
    done
}

# verify_deployment target port key
verify_deployment() {
    local target="$1"; local port="$2"; local key="$3"
    local ssh_port="${E2E_SSH_PORT:-2222}"
    local wg_port="${E2E_WG_PORT:-51820}"
    local out

    echo "[check] SSH on hardened port ${port} works with the admin key"
    run_remote "${target}" "${port}" "${key}" 'echo ssh-ok' >/dev/null
    pass "SSH ${target}:${port}"

    echo "[check] UFW is active"
    out="$(run_remote "${target}" "${port}" "${key}" 'sudo ufw status verbose')"
    grep -q 'Status: active' <<<"${out}" || fail "UFW is not active"

    echo "[check] UFW allows SSH ${ssh_port}/tcp and WireGuard ${wg_port}/udp"
    out="$(run_remote "${target}" "${port}" "${key}" 'sudo ufw status')"
    grep -q "${ssh_port}/tcp" <<<"${out}" || fail "SSH port ${ssh_port}/tcp missing from UFW"
    grep -q "${wg_port}/udp" <<<"${out}" || fail "WireGuard port ${wg_port}/udp missing from UFW"
    pass "UFW rules"

    echo "[check] container running state and optional health are ready"
    out="$(run_remote "${target}" "${port}" "${key}" \
        'sudo docker inspect --format "{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" wg-easy adguard caddy')"
    grep -Eq '^/wg-easy running (none|healthy)$' <<<"${out}" || \
        fail "wg-easy is not running and ready: ${out}"
    for c in adguard caddy; do
        grep -q "^/${c} running healthy$" <<<"${out}" || \
            fail "container ${c} is not running and healthy: ${out}"
    done
    pass "container state and health"

    echo "[check] WireGuard interface is up inside wg-easy"
    run_remote "${target}" "${port}" "${key}" 'sudo docker exec wg-easy wg show' >/dev/null
    pass "WireGuard interface"

    echo "[check] wg-easy admin API enforces authentication (expect 401)"
    out="$(run_remote "${target}" "${port}" "${key}" \
        'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:51821/api/session')"
    [[ "${out}" == "401" ]] || fail "wg-easy /api/session returned ${out}, expected 401"
    pass "wg-easy auth enforced"

    echo "[check] AdGuard admin UI responds (200 or 401)"
    out="$(run_remote "${target}" "${port}" "${key}" \
        'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/control/status')"
    [[ "${out}" == "200" || "${out}" == "401" ]] || fail "AdGuard status returned ${out}"
    pass "AdGuard UI"

    echo "[check] no container publishes a TCP port on 0.0.0.0"
    out="$(run_remote "${target}" "${port}" "${key}" \
        'sudo docker ps --format "{{.Names}} {{.Ports}}"')"
    if grep -qE '0\.0\.0\.0:[0-9]+->[0-9]+/tcp' <<<"${out}"; then
        fail "a container publishes a TCP port on 0.0.0.0: ${out}"
    fi
    pass "no public TCP exposure"

    echo "[check] the deployed Compose file contains no panel password"
    out="$(run_remote "${target}" "${port}" "${key}" \
        'sudo grep -q INIT_PASSWORD /opt/vps-nook/docker-compose.yml 2>/dev/null && echo PRESENT || echo CLEAN')"
    [[ "${out}" == "CLEAN" ]] || fail "docker-compose.yml still contains INIT_PASSWORD"
    pass "compose file is free of the panel password"
}

# verify_traffic_mode target port key expected_mode
verify_traffic_mode() {
    local target="$1" port="$2" key="$3" expected_mode="$4"
    local actual_mode

    [[ "${expected_mode}" == services || "${expected_mode}" == full ]] \
        || fail "invalid expected traffic mode: ${expected_mode}"
    actual_mode="$(run_remote "${target}" "${port}" "${key}" \
        'sudo cat /opt/vps-nook/.wg-traffic-mode')" \
        || fail "could not read deployed traffic mode"
    [[ "${actual_mode}" == "${expected_mode}" ]] \
        || fail "deployed traffic mode does not match ${expected_mode}"

    if [[ "${expected_mode}" == services ]]; then
        # shellcheck disable=SC2016
        run_remote "${target}" "${port}" "${key}" \
            'sudo bash -eu -o pipefail -c '\''
                docker exec wg-easy iptables -C FORWARD -i wg0 -j WG_CLIENTS
                docker exec wg-easy ip6tables -C FORWARD -i wg0 -j WG_CLIENTS
                test "$(docker exec wg-easy iptables -S WG_CLIENTS | tail -n 1)" = "-A WG_CLIENTS -j DROP"
                test "$(docker exec wg-easy ip6tables -S WG_CLIENTS | tail -n 1)" = "-A WG_CLIENTS -j DROP"
            '\''' || fail "services firewall is not active for both address families"
    else
        # shellcheck disable=SC2016
        run_remote "${target}" "${port}" "${key}" \
            'sudo bash -eu -o pipefail -c '\''
                ! docker exec wg-easy iptables -C FORWARD -i wg0 -j WG_CLIENTS 2>/dev/null &&
                ! docker exec wg-easy ip6tables -C FORWARD -i wg0 -j WG_CLIENTS 2>/dev/null
            '\''' || fail "full unexpectedly retained services firewall hooks"
    fi
}

# boot_vm <tmp_dir> <image> <disk_gb> <mem_mb> <smp> <instance_id> <hostname> \
#         [user_data_file] [hostfwd ...]
# Boots a headless qemu/KVM VM with a NoCloud cloud-init seed. Requires an SSH
# keypair at <tmp_dir>/id_ed25519(.pub). When <user_data_file> is empty, a
# default user-data is generated granting that key; otherwise the file is used
# verbatim. Remaining args are hostfwd entries such as
#   hostfwd=tcp:127.0.0.1:2223-:22
# Sets the global QEMU_PID (used by the caller's cleanup trap) and writes the
# serial console to <tmp_dir>/serial.log.
boot_vm() {
    local tmp_dir="$1" image="$2" disk_gb="$3" mem_mb="$4" smp="$5"
    local instance_id="$6" hostname="$7" user_data_file="$8"
    shift 8
    local hostfwd netdev="user,id=n0"
    local runner_pidfile="${tmp_dir}/qemu.pid"

    echo "[E2E] Preparing the cloud image..."
    if [[ "${image}" == http* ]]; then
        curl -fL --retry 3 -o "${tmp_dir}/cloud.img" "${image}"
    else
        cp "${image}" "${tmp_dir}/cloud.img"
    fi
    qemu-img create -f qcow2 -b "${tmp_dir}/cloud.img" -F qcow2 \
        "${tmp_dir}/disk.qcow2" "${disk_gb}G" >/dev/null

    echo "[E2E] Creating the cloud-init NoCloud seed..."
    mkdir -p "${tmp_dir}/seed"
    cat > "${tmp_dir}/seed/meta-data" <<SEEDEOF
instance-id: ${instance_id}
local-hostname: ${hostname}
SEEDEOF
    if [[ -n "${user_data_file}" ]]; then
        cp "${user_data_file}" "${tmp_dir}/seed/user-data"
    else
        cat > "${tmp_dir}/seed/user-data" <<SEEDEOF
#cloud-config
ssh_authorized_keys:
  - $(cat "${tmp_dir}/id_ed25519.pub")
ssh_pwauth: false
SEEDEOF
    fi
    genisoimage -quiet -output "${tmp_dir}/seed.iso" -volid cidata \
        -joliet -rock "${tmp_dir}/seed" >/dev/null

    for hostfwd in "$@"; do
        netdev+=",${hostfwd}"
    done

    echo "[E2E] Booting the VM (KVM)..."
    if [[ -n ${E2E_PROCESS_REGISTRY:-} ]]; then
        runner_pidfile="$(mktemp "${E2E_PROCESS_REGISTRY}/qemu.XXXXXX.pid")"
        python3 - "${runner_pidfile}" "${tmp_dir}" <<'PYINTENT'
import os
from pathlib import Path
import sys
pidfile, directory = map(Path, sys.argv[1:])
started = int(float(Path("/proc/uptime").read_text().split()[0]) * os.sysconf("SC_CLK_TCK"))
intent = pidfile.with_suffix(".intent")
intent.write_text(f"{pidfile}\n{started}\n{directory}\n")
intent.chmod(0o600)
PYINTENT
    fi
    qemu-system-x86_64 -enable-kvm -m "${mem_mb}" -smp "${smp}" \
        -drive file="${tmp_dir}/disk.qcow2",if=virtio,format=qcow2 \
        -drive file="${tmp_dir}/seed.iso",if=virtio,format=raw \
        -netdev "${netdev}" \
        -device virtio-net-pci,netdev=n0 \
        -display none -serial file:"${tmp_dir}/serial.log" \
        -daemonize -pidfile "${runner_pidfile}"
    if [[ ${runner_pidfile} != "${tmp_dir}/qemu.pid" ]]; then
        cp -- "${runner_pidfile}" "${tmp_dir}/qemu.pid"
    fi
    # Publish ownership outside VM state before any delay/cleanup can remove it.
    if [[ -n ${E2E_PROCESS_REGISTRY:-} && -s ${tmp_dir}/qemu.pid ]]; then
        python3 - "${E2E_PROCESS_REGISTRY}" "${tmp_dir}" <<'PYREG'
import os
from pathlib import Path
import sys
registry, directory = map(Path, sys.argv[1:])
pid = int((directory / "qemu.pid").read_text())
started = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
record = registry / f"{pid}.record"
fd = os.open(record, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as stream:
    stream.write(f"{pid}\n{started}\n{directory}\n")
PYREG
    fi
    sleep 2
    if [[ ! -s "${tmp_dir}/qemu.pid" ]]; then
        echo "[FAIL] qemu did not start. Serial log:" >&2
        tail -30 "${tmp_dir}/serial.log" 2>/dev/null || true
        fail "qemu did not start"
    fi
    # shellcheck disable=SC2034  # consumed by the caller's cleanup trap
    QEMU_PID="$(cat "${tmp_dir}/qemu.pid")"
}
