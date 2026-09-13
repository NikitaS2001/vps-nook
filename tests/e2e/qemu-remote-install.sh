#!/usr/bin/env bash
# Remote-mode E2E of the playbook inside a plain qemu/KVM VM.
# The VM plays the role of a fresh VPS; this host plays the Ansible controller
# and deploys with the documented remote mode (inventory + group_vars + vault,
# ansible-playbook over SSH) - not with the public installer.
#
# Usage:
#   tests/e2e/qemu-remote-install.sh [--reboot-test] [--ssh-cutover-test]
#       [--ssh-rollback-test] [--ufw-backend-failure-test]
#
# Env:
#   QEMU_IMAGE          cloud image URL or local path (default Ubuntu 24.04)
#   INSTALL_REF         ignored (uses the working tree); kept for symmetry
#   E2E_SSH_PORT        hardened SSH port configured by the playbook (2222)
#   E2E_WG_PORT         WireGuard UDP port configured by the playbook (51820)
#   QEMU_SSH_PORT       host tcp -> guest:22   (2223)
#   QEMU_ADMIN_PORT     host tcp -> guest:<E2E_SSH_PORT> (2222)
#   QEMU_CLEANUP_PORT   second host tcp -> guest:<E2E_SSH_PORT> (2224)
#   QEMU_WG_PORT        host udp -> guest:<E2E_WG_PORT> (51822)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

DEFAULT_IMAGE="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
QEMU_IMAGE="${QEMU_IMAGE:-${DEFAULT_IMAGE}}"
INSTALL_REF="${INSTALL_REF:-feat/public-installer-v1}"
E2E_SSH_PORT="${E2E_SSH_PORT:-2222}"
E2E_WG_PORT="${E2E_WG_PORT:-51820}"
QEMU_SSH_PORT="${QEMU_SSH_PORT:-2223}"
QEMU_ADMIN_PORT="${QEMU_ADMIN_PORT:-2222}"
QEMU_CLEANUP_PORT="${QEMU_CLEANUP_PORT:-2224}"
QEMU_WG_PORT="${QEMU_WG_PORT:-51822}"
QEMU_ROLLBACK_PROBE_PORT="${QEMU_ROLLBACK_PROBE_PORT:-2299}"

DO_REBOOT=false
DO_SSH_CUTOVER=false
DO_SSH_ROLLBACK=false
DO_UFW_BACKEND_FAILURE=false
for arg in "$@"; do
    case "${arg}" in
        --reboot-test) DO_REBOOT=true ;;
        --ssh-cutover-test) DO_SSH_CUTOVER=true ;;
        --ssh-rollback-test) DO_SSH_ROLLBACK=true ;;
        --ufw-backend-failure-test) DO_UFW_BACKEND_FAILURE=true ;;
        *) fail "Unknown argument: ${arg}" ;;
    esac
done

for tool in qemu-system-x86_64 qemu-img genisoimage curl ssh-keygen openssl ansible-playbook ansible-vault nc ss; do
    command -v "${tool}" >/dev/null || fail "required tool not found: ${tool}"
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-remote.XXXXXX")"
QEMU_PID=""
UFW_GUARD_PID=""
cleanup() {
    local cleanup_ok=true
    if [[ -n "${UFW_GUARD_PID}" ]] && kill -0 "${UFW_GUARD_PID}" >/dev/null 2>&1; then
        run_remote_authenticated "sysadmin@127.0.0.1" "${QEMU_CLEANUP_PORT}" \
            "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" \
            'sudo touch /var/tmp/task-5-ufw-release' >/dev/null 2>&1 || true
        for _ in {1..10}; do
            kill -0 "${UFW_GUARD_PID}" >/dev/null 2>&1 || break
            sleep 1
        done
        if kill -0 "${UFW_GUARD_PID}" >/dev/null 2>&1; then
            kill "${UFW_GUARD_PID}" >/dev/null 2>&1 || true
            cleanup_ok=false
        fi
        wait "${UFW_GUARD_PID}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" >/dev/null 2>&1; then
        kill "${QEMU_PID}" >/dev/null 2>&1 || true
        for _ in {1..10}; do
            kill -0 "${QEMU_PID}" >/dev/null 2>&1 || break
            sleep 1
        done
        if kill -0 "${QEMU_PID}" >/dev/null 2>&1; then
            kill -9 "${QEMU_PID}" >/dev/null 2>&1 || true
            cleanup_ok=false
        fi
    fi
    rm -rf "${TMP_DIR}"
    if [[ "${cleanup_ok}" == "true" && ! -e "${TMP_DIR}" ]]; then
        echo "[CLEANUP] qemu=stopped temp_keys=removed known_hosts=removed state=removed cleanup=complete"
    else
        echo "[CLEANUP] cleanup=incomplete" >&2
        return 1
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Direct Bash invocations get the same isolation as the pytest adapter. Never
# write or delete operator inventory/vaults in the source checkout.
python3 - "${ROOT_DIR}" "${TMP_DIR}/controller" <<'PYSNAPSHOT'
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
sys.path.insert(0, str(source))
from tests.support import snapshot
snapshot(source, destination)
PYSNAPSHOT
ROOT_DIR="${TMP_DIR}/controller"
cd "${ROOT_DIR}"

# --- test fixtures ----------------------------------------------------------
ssh-keygen -q -t ed25519 -N "" -f "${TMP_DIR}/id_ed25519" -C "e2e-ztvps-remote"
PUBKEY="$(cat "${TMP_DIR}/id_ed25519.pub")"
ADGUARD_PASS="$(openssl rand -hex 12)"
ADMIN_PASS="$(openssl rand -hex 12)"
WG_PASS="${NOOK_WG_PASSWORD:-Twelve\$COMPOSE_PROBE}"
ADMIN_HASH="$(openssl passwd -6 -stdin <<<"${ADMIN_PASS}")"
ADGUARD_HASH="$(python3 - <<PY
from passlib.hash import bcrypt
print(bcrypt.using(ident='2y', rounds=10).hash('${ADGUARD_PASS}'))
PY
)"

# --- guest image + seed (root SSH for the controller) -------------------------
# The controller needs passwordless root SSH, so the seed defines a root user
# explicitly instead of relying on the generated default user.
cat > "${TMP_DIR}/user-data" <<SEEDEOF
#cloud-config
disable_root: false
ssh_pwauth: false
users:
  - name: root
    ssh_authorized_keys:
      - ${PUBKEY}
    lock_passwd: true
SEEDEOF
boot_vm "${TMP_DIR}" "${QEMU_IMAGE}" 20 2048 2 ztvps-remote-e2e ztvps-remote "${TMP_DIR}/user-data" \
    "hostfwd=tcp:127.0.0.1:${QEMU_SSH_PORT}-:22" \
    "hostfwd=tcp:127.0.0.1:${QEMU_ADMIN_PORT}-:${E2E_SSH_PORT}" \
    "hostfwd=tcp:127.0.0.1:${QEMU_CLEANUP_PORT}-:${E2E_SSH_PORT}" \
    "hostfwd=udp:127.0.0.1:${QEMU_WG_PORT}-:${E2E_WG_PORT}"

echo "[E2E] Waiting for root SSH on guest:22 (host port ${QEMU_SSH_PORT})..."
require_ssh_ready "root@127.0.0.1" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" 60
touch "${TMP_DIR}/known_hosts"
chmod 0600 "${TMP_DIR}/known_hosts"
record_ssh_host_key "127.0.0.1" "${QEMU_SSH_PORT}" "${TMP_DIR}/known_hosts"
run_remote_authenticated "root@127.0.0.1" "${QEMU_SSH_PORT}" \
    "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" 'true'
E2E_KNOWN_HOSTS="${TMP_DIR}/known_hosts"
export E2E_KNOWN_HOSTS
require_wrong_host_key_rejected "root@127.0.0.1" "${QEMU_SSH_PORT}" \
    "${TMP_DIR}/id_ed25519"
require_wrong_scp_host_key_rejected "root@127.0.0.1" "${QEMU_SSH_PORT}" \
    "${TMP_DIR}/id_ed25519"
pass "pre-cutover authenticated root SSH"

# --- controller side: inventory + group_vars + vault --------------------------
# These paths are gitignored in the repo, exactly like a real remote deploy.
record_authenticated_guest_host_key() {
    local destination_host="$1" destination_port="$2"
    local destination guest_key
    destination="[${destination_host}]:${destination_port}"
    guest_key="$(run_remote_authenticated "root@127.0.0.1" "${QEMU_SSH_PORT}" \
        "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" \
        'cat /etc/ssh/ssh_host_ed25519_key.pub')"
    [[ "${guest_key}" == ssh-ed25519\ * && "${guest_key}" != *$'\n'* ]] || \
        fail "authenticated guest returned a malformed ED25519 host key"
    printf '%s %s\n' "${destination}" "${guest_key}" >>"${TMP_DIR}/known_hosts"
    chmod 0600 "${TMP_DIR}/known_hosts"
}

write_direct_inventory() {
    cat >"${ROOT_DIR}/inventory/hosts.yml" <<EOF
---
all:
  children:
    vps:
      hosts:
        vps01:
          ansible_host: 127.0.0.1
          ansible_port: ${QEMU_SSH_PORT}
          ansible_user: root
          ansible_ssh_private_key_file: ${TMP_DIR}/id_ed25519
          ansible_ssh_common_args: "-F none -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${TMP_DIR}/known_hosts -o GlobalKnownHostsFile=/dev/null"
          ansible_python_interpreter: /usr/bin/python3
EOF
}

write_rollback_inventory() {
    cat >"${ROOT_DIR}/inventory/hosts.yml" <<EOF
---
all:
  children:
    vps:
      hosts:
        vps01:
          ansible_host: 192.0.2.1
          ansible_port: 22
          ansible_user: root
          ansible_ssh_private_key_file: ${TMP_DIR}/id_ed25519
          ansible_ssh_common_args: "-F none -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${TMP_DIR}/known_hosts -o GlobalKnownHostsFile=/dev/null -o HostKeyAlias='[127.0.0.1]:${QEMU_SSH_PORT}' -o ProxyCommand='nc 127.0.0.1 ${QEMU_SSH_PORT}'"
          ansible_python_interpreter: /usr/bin/python3
EOF
}
write_direct_inventory
write_group_vars() {
    local configured_ssh_port="$1"
    cat >"${ROOT_DIR}/group_vars/all/vars.yml" <<EOF
---
# Network
wg_traffic_mode: "${NOOK_WG_TRAFFIC_MODE:-services}"
ssh_port: ${configured_ssh_port}
vps_hardening_controller_ssh_port: ${QEMU_ADMIN_PORT}
wg_port: ${E2E_WG_PORT}
wg_container_port: ${E2E_WG_PORT}
wg_vpn_subnet: "10.8.0.0/24"
wg_server_ip: "10.8.0.1"
wg_client_dns: "10.66.0.2"

# wg-easy initial setup (INIT_*)
wg_easy_admin_user: "admin"
admin_password_hash: "{{ vault_admin_password_hash }}"
wg_easy_bootstrap_secret: "{{ vault_wg_easy_bootstrap_secret }}"
wg_public_host: "127.0.0.1"
wg_allowed_ips:
  - "10.8.0.0/24"
  - "10.66.0.2/32"
  - "10.66.0.3/32"

# Docker network
docker_network_subnet: "10.66.0.0/24"
adguard_container_ip: "10.66.0.2"
caddy_container_ip: "10.66.0.3"
wg_easy_container_ip: "10.66.0.4"

# Internal domains and UI ports
internal_domain_suffix: "${INTERNAL_DOMAIN_SUFFIX:-internal}"
wg_internal_domain: "${WG_INTERNAL_DOMAIN:-wg.internal}"
adguard_internal_domain: "${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}"
wg_easy_bootstrap_ui_port: 51821
adguard_bootstrap_ui_port: 3000

# Remote host paths
project_root: "/opt/vps-nook"

# Admin user
admin_user: "sysadmin"
admin_shell: "/bin/bash"
ssh_service_name: "ssh"
ssh_allow_tcp_forwarding: "yes"
EOF
}
write_group_vars "${E2E_SSH_PORT}"
cat >"${ROOT_DIR}/group_vars/all/vault_ssh.yml" <<EOF
---
vault_admin_ssh_pubkey: "${PUBKEY}"
EOF
cat >"${ROOT_DIR}/group_vars/all/vault_services.yml" <<EOF
---
vault_admin_password_hash: "${ADMIN_HASH}"
vault_adguard_password_hash: "${ADGUARD_HASH}"
vault_wg_easy_bootstrap_secret: "${WG_PASS}"
EOF
echo 'test-vault-password' >"${TMP_DIR}/vault_pass"
chmod 0600 "${TMP_DIR}/vault_pass"
ansible-vault encrypt --vault-password-file "${TMP_DIR}/vault_pass" \
    "${ROOT_DIR}/group_vars/all/vault_ssh.yml" \
    "${ROOT_DIR}/group_vars/all/vault_services.yml"

echo "[E2E] Installing controller collections from requirements.yml..."
ansible-galaxy collection install -r "${ROOT_DIR}/requirements.yml" >/dev/null

run_playbook() {
    local output_file="$1"
    local playbook="$2"
    shift 2
    ANSIBLE_HOST_KEY_CHECKING=True \
        ansible-playbook -i "${ROOT_DIR}/inventory/hosts.yml" \
        --vault-password-file "${TMP_DIR}/vault_pass" "${playbook}" \
        "$@" >"${output_file}" 2>&1
}

run_successful_cutover() {
    local playbook_log="${TMP_DIR}/cutover-ansible.log"
    write_direct_inventory
    write_group_vars "${E2E_SSH_PORT}"
    record_authenticated_guest_host_key "127.0.0.1" "${QEMU_ADMIN_PORT}"
    record_authenticated_guest_host_key "127.0.0.1" "${QEMU_CLEANUP_PORT}"
    echo "[E2E] Running SSH/UFW hardening cutover..."
    if ! run_playbook "${playbook_log}" "${TMP_DIR}/hardening.yml" \
        --tags packages,user,ufw,ssh; then
        sed -n '/SSH | Verify | Wait for sshd on new port/,/SSH | Rescue | Restore previous/p' \
            "${playbook_log}" >&2
        fail "SSH/UFW hardening cutover failed"
    fi
    local sshd_effective
    sshd_effective="$(run_remote_authenticated "sysadmin@127.0.0.1" \
        "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" \
        'sudo sshd -T')"
    grep -qx "port ${E2E_SSH_PORT}" <<<"${sshd_effective}" || \
        fail "sshd -T did not report the hardened port"
    pass "BatchMode admin-key login and sudo sshd -T on hardened port"
    require_authenticated_ssh_closed "root@127.0.0.1" "${QEMU_SSH_PORT}" \
        "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts"
    pass "old SSH port closed after successful cutover"
}

run_rollback_probe() {
    echo "[E2E] Running authenticated SSH rollback probe..."
    local playbook_log="${TMP_DIR}/rollback-ansible.log"
    local control_socket="${TMP_DIR}/rollback-control"
    local before_hash after_hash session_output
    if ss -ltn "sport = :${QEMU_ROLLBACK_PROBE_PORT}" | tail -n +2 | grep -q .; then
        fail "rollback probe port ${QEMU_ROLLBACK_PROBE_PORT} is already in use"
    fi
    write_rollback_inventory
    write_group_vars "${QEMU_ROLLBACK_PROBE_PORT}"
    before_hash="$(run_remote_authenticated "root@127.0.0.1" "${QEMU_SSH_PORT}" \
        "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" \
        'sha256sum /etc/ssh/sshd_config | cut -d" " -f1')"
    open_authenticated_ssh_control "root@127.0.0.1" "${QEMU_SSH_PORT}" \
        "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" "${control_socket}"
    if run_playbook "${playbook_log}" "${TMP_DIR}/hardening.yml" \
        --tags packages,user,ufw,ssh; then
        fail "injected unreachable SSH cutover unexpectedly succeeded"
    fi
    if ! grep -q 'SSH | Rescue | Report failed cutover' \
        "${playbook_log}"; then
        sed -n '/SSH | Verify | Wait for sshd on new port/,$p' "${playbook_log}" >&2
        run_remote_over_control "root@127.0.0.1" "${QEMU_SSH_PORT}" \
            "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" "${control_socket}" \
            'sudo /usr/sbin/sshd -t -f /etc/ssh/sshd_config 2>&1; sudo systemctl status ssh --no-pager -l 2>&1 | tail -12' \
            >&2 || true
        fail "play failed before the intended SSH rollback"
    fi
    session_output="$(run_remote_over_control "root@127.0.0.1" "${QEMU_SSH_PORT}" \
        "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" "${control_socket}" \
        'printf rollback-session-ok')"
    [[ "${session_output}" == "rollback-session-ok" ]] || \
        fail "pre-cutover authenticated SSH session was unusable after rollback"
    close_authenticated_ssh_control "root@127.0.0.1" "${QEMU_SSH_PORT}" \
        "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" "${control_socket}"
    run_remote_authenticated "root@127.0.0.1" "${QEMU_SSH_PORT}" \
        "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" 'true'
    after_hash="$(run_remote_authenticated "root@127.0.0.1" "${QEMU_SSH_PORT}" \
        "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" \
        'sha256sum /etc/ssh/sshd_config | cut -d" " -f1')"
    [[ "${after_hash}" == "${before_hash}" ]] || \
        fail "rollback did not restore the original sshd_config"
    pass "authenticated old SSH session and fresh login survived rollback"
}

write_cleanup_inventory() {
    cat >"${ROOT_DIR}/inventory/hosts.yml" <<EOF
---
all:
  children:
    vps:
      hosts:
        vps01:
          ansible_host: 127.0.0.1
          ansible_port: ${QEMU_CLEANUP_PORT}
          ansible_user: sysadmin
          ansible_ssh_private_key_file: ${TMP_DIR}/id_ed25519
          ansible_ssh_common_args: "-F none -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${TMP_DIR}/known_hosts -o GlobalKnownHostsFile=/dev/null"
          ansible_python_interpreter: /usr/bin/python3
EOF
}

run_tagged_cleanup() {
    local output_file="$1"
    ANSIBLE_HOST_KEY_CHECKING=True \
        ansible-playbook -i "${ROOT_DIR}/inventory/hosts.yml" \
        --vault-password-file "${TMP_DIR}/vault_pass" \
        "${TMP_DIR}/ssh-cleanup.yml" --tags ssh_ufw_cleanup -v \
        >"${output_file}" 2>&1
}

run_ufw_backend_probes() {
    echo "[E2E] Exercising UFW backend failure..."
    local absent_log="${TMP_DIR}/ufw-absent.log"
    local failure_log="${TMP_DIR}/ufw-failure.log"
    local ready=false
    write_cleanup_inventory
    cat >"${TMP_DIR}/ssh-cleanup.yml" <<EOF
---
- name: Test the real SSH UFW cleanup task
  hosts: vps
  gather_facts: false
  become: true
  vars_files:
    - ${ROOT_DIR}/group_vars/all/vars.yml
    - ${ROOT_DIR}/group_vars/all/vault_ssh.yml
    - ${ROOT_DIR}/group_vars/all/vault_services.yml
  tasks:
    - name: Include the production SSH tasks
      include_tasks: ${ROOT_DIR}/roles/vps_hardening/tasks/ssh.yml
      tags: [always]
EOF
    if run_remote_authenticated "sysadmin@127.0.0.1" "${QEMU_CLEANUP_PORT}" \
        "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" \
        "sudo ufw status | grep -Eq '^${QEMU_CLEANUP_PORT}/tcp[[:space:]]'"; then
        fail "cleanup probe rule was not absent before the tagged play"
    fi
    if ! run_tagged_cleanup "${absent_log}"; then
        sed -n '/SSH | Cleanup/,$p' "${absent_log}" >&2
        fail "deleting an absent UFW rule failed"
    fi
    grep -q 'SSH | Cleanup | Remove temporary old-port UFW allow after cutover' \
        "${absent_log}" || fail "dedicated cleanup tag did not execute the production task"
    grep -Eq 'changed=0[[:space:]]+unreachable=0[[:space:]]+failed=0' \
        "${absent_log}" || fail "absent UFW rule was not unchanged rc0"
    pass "absent old-port UFW rule returned rc=0 changed=0"

    run_remote_authenticated "sysadmin@127.0.0.1" "${QEMU_CLEANUP_PORT}" \
        "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" 'sudo bash -s' <<'GUARD' &
set -euo pipefail
backup="$(mktemp /var/tmp/task-5-ufw.XXXXXX)"
restore_ufw() {
    cp -a "${backup}" /usr/sbin/ufw
    rm -f "${backup}" /var/tmp/task-5-ufw-ready /var/tmp/task-5-ufw-release
}
trap restore_ufw EXIT HUP INT TERM
cp -a /usr/sbin/ufw "${backup}"
printf '%s\n' '#!/bin/sh' 'echo "injected UFW backend failure" >&2' 'exit 1' >/usr/sbin/ufw
chmod 0755 /usr/sbin/ufw
touch /var/tmp/task-5-ufw-ready
while [[ ! -e /var/tmp/task-5-ufw-release ]]; do sleep 1; done
GUARD
    UFW_GUARD_PID="$!"
    for _ in {1..30}; do
        if run_remote_authenticated "sysadmin@127.0.0.1" "${QEMU_CLEANUP_PORT}" \
            "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" \
            'sudo test -e /var/tmp/task-5-ufw-ready'; then
            ready=true
            break
        fi
        sleep 1
    done
    [[ "${ready}" == "true" ]] || fail "UFW failure stub did not become ready"
    if run_tagged_cleanup "${failure_log}"; then
        fail "injected UFW backend failure was suppressed"
    fi
    grep -q 'injected UFW backend failure' "${failure_log}" || \
        fail "tagged play failed without surfacing the injected backend error"
    run_remote_authenticated "sysadmin@127.0.0.1" "${QEMU_CLEANUP_PORT}" \
        "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" \
        'sudo touch /var/tmp/task-5-ufw-release'
    wait "${UFW_GUARD_PID}"
    UFW_GUARD_PID=""
    run_remote_authenticated "sysadmin@127.0.0.1" "${QEMU_CLEANUP_PORT}" \
        "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" \
        'sudo ufw version >/dev/null'
    pass "injected UFW backend failure returned nonzero and trap restored ufw"
}

cat >"${TMP_DIR}/hardening.yml" <<EOF
---
- name: Exercise SSH and UFW hardening
  hosts: vps
  gather_facts: true
  become: true
  vars_files:
    - ${ROOT_DIR}/group_vars/all/vars.yml
    - ${ROOT_DIR}/group_vars/all/vault_ssh.yml
    - ${ROOT_DIR}/group_vars/all/vault_services.yml
  roles:
    - role: ${ROOT_DIR}/roles/vps_hardening
EOF

if [[ "${DO_SSH_ROLLBACK}" == "true" ]]; then
    run_rollback_probe
    if [[ "${DO_UFW_BACKEND_FAILURE}" == "true" ]]; then
        rollback_boot_id="$(run_remote_authenticated "root@127.0.0.1" \
            "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
            "${TMP_DIR}/known_hosts" 'cat /proc/sys/kernel/random/boot_id')"
        run_remote_authenticated "root@127.0.0.1" "${QEMU_SSH_PORT}" \
            "${TMP_DIR}/id_ed25519" "${TMP_DIR}/known_hosts" \
            'systemctl reboot' >/dev/null 2>&1 || true
        require_rebooted "root@127.0.0.1" "${QEMU_SSH_PORT}" \
            "${TMP_DIR}/id_ed25519" "${rollback_boot_id}" 60
        pass "rollback state rebooted with original authenticated SSH reachable"
    fi
    write_direct_inventory
    write_group_vars "${E2E_SSH_PORT}"
fi

if [[ "${DO_SSH_CUTOVER}" == "true" || "${DO_UFW_BACKEND_FAILURE}" == "true" ]]; then
    run_successful_cutover
elif [[ "${DO_SSH_ROLLBACK}" != "true" ]]; then
    record_authenticated_guest_host_key "127.0.0.1" "${QEMU_ADMIN_PORT}"
    record_authenticated_guest_host_key "127.0.0.1" "${QEMU_CLEANUP_PORT}"
    echo "[E2E] Running the complete playbook in remote mode..."
    if ! run_playbook "${TMP_DIR}/full-ansible.log" "${ROOT_DIR}/site.yml"; then
        tail -n 80 "${TMP_DIR}/full-ansible.log" >&2
        fail "remote-mode playbook failed"
    fi
fi

if [[ "${DO_SSH_CUTOVER}" == "true" ]]; then
    echo "[E2E] Running full playbook after SSH cutover..."
    write_cleanup_inventory
    if ! run_playbook "${TMP_DIR}/full-after-cutover.log" "${ROOT_DIR}/site.yml"; then
        tail -n 80 "${TMP_DIR}/full-after-cutover.log" >&2
        fail "remote-mode playbook failed after authenticated SSH cutover"
    fi
fi

if [[ "${DO_UFW_BACKEND_FAILURE}" == "true" ]]; then
    run_ufw_backend_probes
fi

if [[ ( "${DO_SSH_ROLLBACK}" != "true" || "${DO_SSH_CUTOVER}" == "true" ) && "${DO_UFW_BACKEND_FAILURE}" != "true" ]]; then
    echo "[E2E] Verifying the deployed stack on the hardened SSH port ${QEMU_ADMIN_PORT}"
    require_wrong_host_key_rejected "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" \
        "${TMP_DIR}/id_ed25519"
    export E2E_SSH_PORT E2E_WG_PORT
    verify_deployment "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
fi

if [[ "${DO_REBOOT}" == "true" ]]; then
    echo "[E2E] Rebooting the VM and re-verifying..."
    boot_id_before="$(run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" \
        "${TMP_DIR}/id_ed25519" 'cat /proc/sys/kernel/random/boot_id')"
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo systemctl reboot' || true
    require_rebooted "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" \
        "${TMP_DIR}/id_ed25519" "${boot_id_before}" 60
    sleep 20
    verify_deployment "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    echo "[E2E] Reboot survival verified"
fi

echo "[E2E] PASS: remote-mode E2E succeeded in qemu/KVM"
