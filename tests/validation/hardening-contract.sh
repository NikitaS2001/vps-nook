#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly ROOT_DIR
ROLE_DIR="${ROOT_DIR}/roles/vps_hardening"
readonly ROLE_DIR
RUNTIME_LOG_DIR=""
SSH_CUTOVER_HTTP_PID=""
SSH_CUTOVER_TCP_OUTCOME=""
SSH_CUTOVER_AUTH_OUTCOME=""

cleanup() {
    [[ -z ${SSH_CUTOVER_HTTP_PID} ]] || kill "${SSH_CUTOVER_HTTP_PID}" 2>/dev/null || true
    [[ -z ${RUNTIME_LOG_DIR} || ! -d ${RUNTIME_LOG_DIR} ]] || find "${RUNTIME_LOG_DIR}" -depth -delete
}

trap cleanup EXIT

fail() {
    printf 'hardening-contract: %s\n' "$*" >&2
    exit 1
}

require_before() {
    local file="$1" first="$2" second="$3" first_line second_line
    first_line="$(grep -n -F -- "${first}" "${file}" | head -n1 | cut -d: -f1 || true)"
    second_line="$(grep -n -F -- "${second}" "${file}" | head -n1 | cut -d: -f1 || true)"
    [[ -n ${first_line} && -n ${second_line} && ${first_line} -lt ${second_line} ]] \
        || fail "expected ${first} before ${second} in ${file}"
}

validate_argument_spec() {
    HARDENING_ROLE_DIR="${ROLE_DIR}" python3 - <<'PY'
from pathlib import Path
import os
import yaml

role_dir = Path(os.environ["HARDENING_ROLE_DIR"])
document = yaml.safe_load((role_dir / "meta/main.yml").read_text(encoding="utf-8"))
if not isinstance(document, dict):
    raise SystemExit("meta/main.yml is not a mapping")
spec = document.get("argument_specs", {}).get("main", {})
options = spec.get("options", {}) if isinstance(spec, dict) else {}
expected = {
    "ssh_port", "wg_port", "admin_user", "admin_group", "admin_shell",
    "admin_password_hash", "vault_admin_ssh_pubkey",
    "vps_hardening_authorized_keys_exclusive", "ssh_service_name", "ssh_socket_name",
    "ssh_allow_tcp_forwarding", "vps_hardening_manage_ssh_socket",
    "wg_easy_bootstrap_ui_port", "adguard_bootstrap_ui_port", "fail2ban_ignore_ips",
    "fail2ban_bantime", "fail2ban_findtime", "fail2ban_maxretry",
    "vps_hardening_apply_package_upgrade", "vps_hardening_package_upgrade_mode",
    "vps_hardening_enable_ufw_on_local_connection",
}
missing = sorted(expected - set(options))
if missing:
    raise SystemExit(f"argument spec misses: {', '.join(missing)}")
if "admin_password" in options:
    raise SystemExit("argument spec must not accept deprecated admin_password")
for name in expected:
    option = options[name]
    if not isinstance(option, dict) or not option.get("type"):
        raise SystemExit(f"argument spec has no type for {name}")
PY
}

validate_fqcn() {
    HARDENING_ROLE_DIR="${ROLE_DIR}" python3 - <<'PY'
from pathlib import Path
import os
import yaml

role_dir = Path(os.environ["HARDENING_ROLE_DIR"])
bare_modules = {
    "apt", "assert", "command", "copy", "debug", "fail", "group",
    "include_tasks", "meta", "service", "set_fact", "stat", "template",
    "user", "wait_for", "wait_for_connection",
}
errors = []

def inspect_tasks(tasks: object, source: Path) -> None:
    if not isinstance(tasks, list):
        return
    for task in tasks:
        if not isinstance(task, dict):
            continue
        for module in sorted(bare_modules.intersection(task)):
            errors.append(f"{source}: bare module {module}")
        for block_name in ("block", "rescue", "always"):
            inspect_tasks(task.get(block_name), source)

for directory in (role_dir / "tasks", role_dir / "handlers"):
    for source in sorted(directory.glob("*.yml")):
        inspect_tasks(yaml.safe_load(source.read_text(encoding="utf-8")), source)

if errors:
    raise SystemExit("\n".join(errors))
PY
}

validate_no_swap_management() {
    local forbidden
    forbidden="$(grep -ERin \
        'vps_swap_mode|zram-tools|(^|[^[:alnum:]_])(swapon|swapoff|mkswap)([^[:alnum:]_]|$)|/swap(file)?([^[:alnum:]_]|$)' "${ROLE_DIR}" || true)"
    [[ -z ${forbidden} ]] || fail "swap or zram management was introduced:\n${forbidden}"
}

validate_plaintext_password_policy() {
    ! grep -Eq '(^|[^[:alnum:]_])admin_password([^[:alnum:]_]|$)' "${ROLE_DIR}/tasks/user.yml" \
        || fail 'user tasks still consume deprecated admin_password'
    ! grep -Eq '(^|[^[:alnum:]_])password_hash[[:space:]]*\(' "${ROLE_DIR}/tasks/user.yml" \
        || fail 'user tasks still derive password hashes'
    ! grep -Fq "lookup('password'" "${ROLE_DIR}/tasks/user.yml" \
        || fail 'user tasks still generate password material'
    grep -Fq 'password: "{{ admin_password_hash | default(omit, true) }}"' "${ROLE_DIR}/tasks/user.yml" \
        || fail 'user task does not omit an empty optional password hash'
}

validate_always_preflight() {
    grep -Fq 'tags: [always, preflight]' "${ROLE_DIR}/tasks/main.yml" \
        || fail 'preflight include is not tagged always'
    [[ "$(grep -Fc 'tags: [always, preflight]' "${ROLE_DIR}/tasks/preflight.yml")" -ge 4 ]] \
        || fail 'platform, memory, and legacy preflights are not tagged always'
}

validate_platform_policy() {
    grep -Fq "== 'Debian'" "${ROLE_DIR}/tasks/preflight.yml" \
        || fail 'role lacks Debian platform validation'
    grep -Fq "== '12'" "${ROLE_DIR}/tasks/preflight.yml" \
        || fail 'role lacks Debian 12 validation'
    grep -Fq "== 'Ubuntu'" "${ROLE_DIR}/tasks/preflight.yml" \
        || fail 'role lacks Ubuntu platform validation'
    grep -Fq "== '24.04'" "${ROLE_DIR}/tasks/preflight.yml" \
        || fail 'role lacks Ubuntu 24.04 validation'
    grep -Fq "== 'x86_64'" "${ROLE_DIR}/tasks/preflight.yml" \
        || fail 'role lacks amd64 architecture validation'
}

validate_authenticated_ssh_cutover() {
    HARDENING_DEFAULTS="${ROLE_DIR}/defaults/main.yml" \
    HARDENING_SSH_TASKS="${ROLE_DIR}/tasks/ssh.yml" \
    REMOTE_HARNESS="${ROOT_DIR}/tests/e2e/qemu-remote-install.sh" python3 - <<'PY'
from pathlib import Path
import os
import yaml

defaults = yaml.safe_load(Path(os.environ["HARDENING_DEFAULTS"]).read_text(encoding="utf-8"))
tasks = yaml.safe_load(Path(os.environ["HARDENING_SSH_TASKS"]).read_text(encoding="utf-8"))
harness = Path(os.environ["REMOTE_HARNESS"]).read_text(encoding="utf-8")
ordered = []

def flatten(items: object) -> None:
    if not isinstance(items, list):
        return
    for task in items:
        if not isinstance(task, dict):
            continue
        ordered.append(task)
        flatten(task.get("block"))
        flatten(task.get("rescue"))

flatten(tasks)
controller_port = defaults.get("vps_hardening_controller_ssh_port")
if controller_port != "{{ ssh_port }}":
    raise SystemExit(
        "controller-facing hardened SSH port must default to the guest ssh_port"
    )
tcp_proof = next(
    task for task in ordered
    if task.get("name") == "SSH | Verify | Wait for sshd on new port"
)
if tcp_proof.get("ansible.builtin.wait_for", {}).get("port") != (
    "{{ vps_hardening_controller_ssh_port }}"
):
    raise SystemExit("delegated TCP proof must use the controller-facing hardened SSH port")
authenticated = [task for task in ordered if "ansible.builtin.wait_for_connection" in task
                 and task.get("name", "").startswith("SSH | Verify |")]
recovery = [task for task in ordered if "ansible.builtin.wait_for_connection" in task
            and task.get("name", "").startswith("SSH | Rescue |")]
if len(recovery) != 1 or recovery[0].get("vars") or recovery[0].get("delegate_to"):
    raise SystemExit("SSH recovery must authenticate over the unchanged original connection, including proxies")
if len(authenticated) != 1:
    raise SystemExit("SSH cutover must require exactly one authenticated wait_for_connection proof")
proof = authenticated[0]
variables = proof.get("vars", {})
if variables.get("ansible_user") != "{{ admin_user }}" or variables.get("ansible_port") != (
    "{{ vps_hardening_controller_ssh_port }}"
):
    raise SystemExit(
        "SSH cutover proof must authenticate as admin_user on the controller-facing hardened SSH port"
    )
cleanup = next(task for task in ordered if task.get("name", "").startswith("SSH | Cleanup |"))
if ordered.index(proof) >= ordered.index(cleanup):
    raise SystemExit("authenticated SSH proof must run before old-port UFW deletion")
update = next(
    task for task in ordered
    if task.get("name") == "SSH | Update | Set ansible connection for remainder"
)
if update.get("ansible.builtin.set_fact", {}).get("ansible_port") != (
    "{{ vps_hardening_controller_ssh_port }}"
):
    raise SystemExit(
        "durable post-cutover connection must retain the controller-facing hardened SSH port"
    )

if "vps_hardening_controller_ssh_port: ${QEMU_ADMIN_PORT}" not in harness:
    raise SystemExit("remote QEMU harness must pass QEMU_ADMIN_PORT to the role controller proof")
cutover_start = harness.index("run_successful_cutover() {")
cutover_end = harness.index("\n}\n\nrun_rollback_probe()", cutover_start)
cutover = harness[cutover_start:cutover_end]
pin = cutover.find(
    'record_authenticated_guest_host_key "127.0.0.1" "${QEMU_ADMIN_PORT}"'
)
playbook = cutover.find('run_playbook "${playbook_log}"')
if pin < 0 or playbook < 0 or pin >= playbook:
    raise SystemExit(
        "strict known_hosts must pin the hardened admin endpoint before ansible-playbook starts"
    )
PY

    local auth_call expected_key expected_known_hosts fixture_dir flow_file helper_file http_log port preplay_count run_log run_rc
    fixture_dir="${RUNTIME_LOG_DIR}/authenticated-host-key"
    mkdir -p "${fixture_dir}"
    helper_file="${fixture_dir}/helper.sh"
    flow_file="${fixture_dir}/flow.sh"
    sed -n '/^record_authenticated_guest_host_key() {$/,/^}$/p' \
        "${ROOT_DIR}/tests/e2e/qemu-remote-install.sh" >"${helper_file}"
    sed -n '/^run_successful_cutover() {$/,/^}$/p' \
        "${ROOT_DIR}/tests/e2e/qemu-remote-install.sh" >"${flow_file}"
    [[ -s ${helper_file} ]] || fail 'remote QEMU harness lacks authenticated guest host-key derivation'
    [[ -s ${flow_file} ]] || fail 'remote QEMU harness lacks the successful cutover flow'
    expected_key="ssh-ed25519 task14-${fixture_dir##*.} authenticated-guest"
    AUTH_CALL_LOG="${fixture_dir}/auth-call.log" \
    FLOW_LOG="${fixture_dir}/flow.log" \
    EXPECTED_KEY="${expected_key}" \
    TMP_DIR="${fixture_dir}" \
    QEMU_SSH_PORT=28223 \
    QEMU_ADMIN_PORT=28222 \
    QEMU_CLEANUP_PORT=28224 \
    E2E_SSH_PORT=2222 \
        bash -Eeuo pipefail -c '
            fail() { printf "fixture failure: %s\n" "$*" >&2; return 1; }
            run_remote_authenticated() {
                if [[ $1 == root@127.0.0.1 ]]; then
                    printf "%s|%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" "$5" >>"${AUTH_CALL_LOG}"
                    printf "%s\n" "${EXPECTED_KEY}"
                    return
                fi
                [[ $1 == sysadmin@127.0.0.1 && $2 == "${QEMU_ADMIN_PORT}" ]] || return 92
                printf "port %s\n" "${E2E_SSH_PORT}"
            }
            ssh-keyscan() { fail "unauthenticated ssh-keyscan was called"; }
            record_ssh_host_key() { fail "unauthenticated host-key scanner was called"; }
            write_direct_inventory() { :; }
            write_group_vars() { :; }
            echo() { :; }
            run_playbook() {
                wc -l <"${TMP_DIR}/known_hosts" >"${FLOW_LOG}"
                return 0
            }
            pass() { :; }
            require_authenticated_ssh_closed() { :; }
            source "$1"
            source "$2"
            run_successful_cutover
        ' fixture "${helper_file}" "${flow_file}"
    preplay_count="$(<"${fixture_dir}/flow.log")"
    [[ ${preplay_count} == 2 ]] \
        || fail 'both hardened forwards must be pinned before the cutover playbook starts'
    auth_call="$(sort "${fixture_dir}/auth-call.log" | uniq -c)"
    [[ ${auth_call} == "      2 root@127.0.0.1|28223|${fixture_dir}/id_ed25519|${fixture_dir}/known_hosts|cat /etc/ssh/ssh_host_ed25519_key.pub" ]] \
        || fail 'hardened endpoint key was not read through the authenticated guest connection'
    expected_known_hosts="[127.0.0.1]:28222 ${expected_key}"$'\n'"[127.0.0.1]:28224 ${expected_key}"
    [[ "$(<"${fixture_dir}/known_hosts")" == "${expected_known_hosts}" ]] \
        || fail 'admin and cleanup forwards must each have exactly one authenticated guest ED25519 key'
    if grep -Eq '^[[:space:]]*record_ssh_host_key .*\$\{QEMU_(ADMIN|CLEANUP)_PORT\}' \
        "${ROOT_DIR}/tests/e2e/qemu-remote-install.sh"; then
        fail 'hardened admin and cleanup forwards must never use unauthenticated host-key scanning'
    fi

    fixture_dir="${RUNTIME_LOG_DIR}/ssh-http-listener"
    fixture_dir="${RUNTIME_LOG_DIR}/ssh-http-listener"
    mkdir -p "${fixture_dir}"
    port="$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)"
    http_log="${fixture_dir}/http.log"
    python3 -m http.server --bind 127.0.0.1 "${port}" >"${http_log}" 2>&1 &
    SSH_CUTOVER_HTTP_PID="$!"
    for _ in {1..20}; do
        if python3 - "${port}" 2>/dev/null <<'PY'
import socket
import sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.2):
    pass
PY
        then
            SSH_CUTOVER_TCP_OUTCOME=0
            break
        fi
        sleep 0.1
    done
    [[ ${SSH_CUTOVER_TCP_OUTCOME} == 0 ]] || fail 'HTTP fixture did not accept a TCP connection'
    cat >"${fixture_dir}/playbook.yml" <<'YAML'
---
- hosts: all
  gather_facts: false
  tasks:
    - name: Require authenticated SSH rather than a TCP listener
      ansible.builtin.wait_for_connection:
        timeout: 3
        connect_timeout: 1
        sleep: 1
YAML
    run_log="${fixture_dir}/authenticated-ssh.log"
    set +e
    timeout 10 ansible-playbook -i 'http-fixture,' "${fixture_dir}/playbook.yml" \
        -e ansible_connection=ssh -e ansible_host=127.0.0.1 -e "ansible_port=${port}" \
        -e ansible_user=admin >"${run_log}" 2>&1
    run_rc=$?
    set -e
    SSH_CUTOVER_AUTH_OUTCOME="${run_rc}"
    kill "${SSH_CUTOVER_HTTP_PID}" 2>/dev/null || true
    wait "${SSH_CUTOVER_HTTP_PID}" 2>/dev/null || true
    SSH_CUTOVER_HTTP_PID=""
    [[ ${run_rc} -ne 0 ]] || fail 'HTTP listener unexpectedly passed authenticated SSH validation'
}

run_rejection_fixture() {
    local architecture artifact_dir case_name distribution distribution_major distribution_version fixture_dir legacy_password memory_mib run_log run_rc selected_tag swap_after swap_before
    case_name="$1"
    memory_mib="$2"
    selected_tag="$3"
    legacy_password="$4"
    distribution="$5"
    distribution_major="$6"
    distribution_version="$7"
    architecture="$8"
    fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/hardening-${case_name}.XXXXXX")"
    run_log="${fixture_dir}/run.log"
    printf '%s\n' \
        '---' \
        'all:' \
        '  hosts:' \
        '    localhost:' \
        '      ansible_connection: local' >"${fixture_dir}/inventory.yml"
    {
        printf '%s\n' \
            '---' \
            '- name: Hardening preflight contract' \
            '  hosts: localhost' \
            '  gather_facts: false' \
            '  become: false'
        if [[ -n ${legacy_password} ]]; then
            printf '%s\n' '  vars:' "    admin_password: ${legacy_password}"
        fi
        printf '%s\n' \
            '  pre_tasks:' \
            '    - name: Supply platform and physical memory facts' \
            '      ansible.builtin.set_fact:' \
            "        ansible_distribution: ${distribution}" \
            "        ansible_distribution_major_version: '${distribution_major}'" \
            "        ansible_distribution_version: '${distribution_version}'" \
            "        ansible_architecture: ${architecture}" \
            "        ansible_memtotal_mb: ${memory_mib}" \
            '      tags: [always]' \
            '  roles:' \
            "    - role: ${ROLE_DIR}"
    } >"${fixture_dir}/site.yml"

    swap_before="$(< /proc/swaps)"
    set +e
    ansible-playbook --tags "${selected_tag}" -i "${fixture_dir}/inventory.yml" "${fixture_dir}/site.yml" >"${run_log}" 2>&1
    run_rc=$?
    set -e
    swap_after="$(< /proc/swaps)"
    [[ ${swap_before} == "${swap_after}" ]] || fail "${case_name} changed host swap state"
    [[ ${run_rc} -ne 0 ]] || fail "${case_name} fixture unexpectedly succeeded"
    ! grep -Fq 'VPS Hardening | Packages |' "${run_log}" \
        || fail "${case_name} fixture reached package mutation tasks"
    ! grep -Fq 'VPS Hardening | User |' "${run_log}" \
        || fail "${case_name} fixture reached user mutation tasks"
    ! grep -Fq 'Check TUN device' "${run_log}" \
        || fail "${case_name} fixture reached TUN checks"
    cp -- "${run_log}" "${RUNTIME_LOG_DIR}/${case_name}.log"
    chmod 0600 "${RUNTIME_LOG_DIR}/${case_name}.log"
    artifact_dir="${HARDENING_CONTRACT_ARTIFACT_DIR:-}"
    if [[ -n ${artifact_dir} ]]; then
        [[ -d ${artifact_dir} ]] || fail "artifact directory does not exist: ${artifact_dir}"
        cp -- "${run_log}" "${artifact_dir}/${case_name}.log"
        chmod 0600 "${artifact_dir}/${case_name}.log"
    fi
    find "${fixture_dir}" -depth -delete
}

validate_memory_preflight() {
    run_rejection_fixture memory-preflight-packages-tag 899 packages '' Debian 12 12 x86_64
    grep -Fq 'requires at least 900 MiB of RAM visible to the OS' \
        "${RUNTIME_LOG_DIR}/memory-preflight-packages-tag.log" \
        || fail 'packages-tag fixture omitted the expected memory diagnostic'
}

validate_plaintext_rejection() {
    run_rejection_fixture plaintext-password-preflight 900 preflight legacy-test-password Debian 12 12 x86_64
    local artifact_path="${RUNTIME_LOG_DIR}/plaintext-password-preflight.log"
    grep -Fq 'admin_password is no longer accepted' "${artifact_path}" \
        || fail 'plaintext rejection fixture omitted the expected diagnostic'
}

validate_platform_rejection() {
    local architecture_path os_path
    run_rejection_fixture unsupported-os-packages-tag 2048 packages '' Debian 11 11 x86_64
    os_path="${RUNTIME_LOG_DIR}/unsupported-os-packages-tag.log"
    grep -Fq 'supports Debian 12 and Ubuntu 24.04 only' "${os_path}" \
        || fail 'unsupported OS fixture omitted the expected diagnostic'

    run_rejection_fixture unsupported-architecture-packages-tag 2048 packages '' Ubuntu 24 24.04 aarch64
    architecture_path="${RUNTIME_LOG_DIR}/unsupported-architecture-packages-tag.log"
    grep -Fq 'supports amd64 (x86_64) only' "${architecture_path}" \
        || fail 'unsupported architecture fixture omitted the expected diagnostic'
}

main() {
    command -v python3 >/dev/null || fail 'python3 is required'
    command -v grep >/dev/null || fail 'grep is required'
    command -v ansible-playbook >/dev/null || fail 'ansible-playbook is required'
    [[ -r /proc/swaps ]] || fail '/proc/swaps is required for swap-state observation'
    [[ -f "${ROLE_DIR}/meta/main.yml" ]] || fail 'role argument spec is missing'
    RUNTIME_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hardening-contract.XXXXXX")"

    validate_argument_spec
    validate_fqcn
    validate_no_swap_management
    validate_plaintext_password_policy
    validate_always_preflight
    validate_platform_policy
    validate_authenticated_ssh_cutover
    require_before "${ROLE_DIR}/tasks/main.yml" 'Include preflight checks' 'Include package setup'
    require_before "${ROLE_DIR}/tasks/main.yml" 'Include package setup' 'Include user setup'
    require_before "${ROLE_DIR}/tasks/preflight.yml" 'Require at least 900 MiB of available RAM' 'Check TUN device'
    grep -Fq -- '- sudo' "${ROLE_DIR}/tasks/packages.yml" || fail 'sudo is not installed before user mutation'
    grep -Fq -- "validate: 'visudo -cf %s'" "${ROLE_DIR}/tasks/user.yml" \
        || fail 'sudoers drop-in is not validated with visudo'
    validate_memory_preflight
    validate_plaintext_rejection
    validate_platform_rejection

    printf '%s\n' "{\"argument_specs\":true,\"fqcn\":true,\"ssh_controller_port_contract\":true,\"ssh_strict_admin_key_preseed\":true,\"ssh_http_tcp_outcome\":${SSH_CUTOVER_TCP_OUTCOME},\"ssh_authenticated_outcome\":${SSH_CUTOVER_AUTH_OUTCOME},\"platform_preflight_always\":true,\"packages_tag_platform_rejection\":true,\"ram_preflight_always\":true,\"packages_tag_memory_rejection\":true,\"plaintext_password_rejected\":true,\"swap_static_guard\":true,\"swap_unchanged_on_rejection\":true,\"sudo_before_user\":true}"
}

main "$@"
