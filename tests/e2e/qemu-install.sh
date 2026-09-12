#!/usr/bin/env bash
# End-to-end test of the repository installer inside a plain qemu/KVM VM.
# Needs only qemu, KVM support and genisoimage (no libvirt daemon).
#
# Usage:
#   tests/e2e/qemu-install.sh [--reboot-test] [--client-test]
#       [--idempotency-test] [--bootstrap-timeout-test]
#       [--stopped-container-test] [--invalid-caddy-test]
#
# Env:
#   QEMU_IMAGE       cloud image URL or local .img/.qcow2 path
#                    (default: Ubuntu 24.04 noble server cloud image)
#   QEMU_USER        initial login user created by cloud-init (default ubuntu)
#   E2E_SOURCE_MODE  installer source mode: development or production
#                    (default development)
#   INSTALL_REF      git ref to install (default: current branch)
#   E2E_SSH_PORT     hardened SSH port configured by the installer (default 2222)
#   E2E_WG_PORT      WireGuard UDP port configured by the installer (default 51820)
#   NOOK_WG_TRAFFIC_MODE  services or full (default services)
#   QEMU_SSH_PORT    host tcp port -> guest:22  (default 2223)
#   QEMU_ADMIN_PORT  host tcp port -> guest:<E2E_SSH_PORT> (default 2222)
#   QEMU_WG_PORT     host udp port -> guest:<E2E_WG_PORT> (default 51822)
#   E2E_KEEP_STATE_ON_FAILURE  keep the VM and QEMU_STATE_DIR after failure
#                              for diagnostics (default 0; requires QEMU_STATE_DIR)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERNAL_DOMAIN_SUFFIX="${INTERNAL_DOMAIN_SUFFIX:-internal}"
WG_INTERNAL_DOMAIN="${WG_INTERNAL_DOMAIN:-wg.${INTERNAL_DOMAIN_SUFFIX}}"
ADGUARD_INTERNAL_DOMAIN="${ADGUARD_INTERNAL_DOMAIN:-adguard.${INTERNAL_DOMAIN_SUFFIX}}"
# shellcheck disable=SC1091
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

INSTALLER_RELEASE_REF="$(sed -n 's/^readonly OFFICIAL_RELEASE_REF="\([^"]*\)"$/\1/p' "${ROOT_DIR}/install.sh")"
[[ "${INSTALLER_RELEASE_REF}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "could not derive the production release ref from install.sh"
readonly INSTALLER_RELEASE_REF

list_existing_source_paths() {
    local source_root="$1" path
    while IFS= read -r -d '' path; do
        if [[ -e ${source_root}/${path} || -L ${source_root}/${path} ]]; then
            printf '%s\0' "${path}"
        fi
    done < <(git -C "${source_root}" ls-files -z --cached --others --exclude-standard)
}

snapshot_source() {
    local source_root="$1" destination="$2"
    mkdir -p "${destination}"
    list_existing_source_paths "${source_root}" | \
        tar -C "${source_root}" --null -cf - --files-from - | tar -xf - -C "${destination}"
}

build_installer_credential_env() {
    local state_mode="$1" admin_password="$2" adguard_password="$3"
    local wg_password="$4" public_key="$5"
    local quoted_admin quoted_adguard quoted_wg quoted_key

    case "${state_mode}" in
        fresh)
            printf -v quoted_admin '%q' "${admin_password}"
            printf -v quoted_adguard '%q' "${adguard_password}"
            printf -v quoted_wg '%q' "${wg_password}"
            printf -v quoted_key '%q' "${public_key}"
            printf 'NOOK_ADMIN_PASSWORD=%s NOOK_ADGUARD_PASSWORD=%s NOOK_WG_PASSWORD=%s NOOK_SSH_PUBKEY=%s' \
                "${quoted_admin}" "${quoted_adguard}" "${quoted_wg}" "${quoted_key}"
            ;;
        existing) ;;
        *) fail "unknown installer state mode: ${state_mode}" ;;
    esac
}

if [[ ${1:-} == --self-test-source-list ]]; then
    [[ $# -eq 2 && -d $2 ]] || fail '--self-test-source-list requires one directory'
    list_existing_source_paths "$2"
    exit 0
fi
if [[ ${1:-} == --self-test-source-snapshot ]]; then
    [[ $# -eq 3 && -d $2 ]] || fail '--self-test-source-snapshot requires source and destination'
    snapshot_source "$2" "$3"
    exit 0
fi
if [[ ${1:-} == --self-test-installer-env ]]; then
    [[ $# -eq 2 ]] || fail '--self-test-installer-env requires fresh or existing'
    build_installer_credential_env "$2" "admin'secret" 'adguard secret' "wg\$secret" \
        'ssh-ed25519 AAAA fixture'
    exit 0
fi

DEFAULT_IMAGE="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
QEMU_IMAGE="${QEMU_IMAGE:-${DEFAULT_IMAGE}}"
QEMU_USER="${QEMU_USER:-ubuntu}"
E2E_SOURCE_MODE="${E2E_SOURCE_MODE:-development}"
INSTALL_REF="${INSTALL_REF:-$(git rev-parse --abbrev-ref HEAD)}"
E2E_SSH_PORT="${E2E_SSH_PORT:-2222}"
E2E_WG_PORT="${E2E_WG_PORT:-51820}"
QEMU_SSH_PORT="${QEMU_SSH_PORT:-2223}"
QEMU_ADMIN_PORT="${QEMU_ADMIN_PORT:-2222}"
QEMU_WG_PORT="${QEMU_WG_PORT:-51822}"

case "${E2E_SOURCE_MODE}" in
    development|production) ;;
    *)
        echo "E2E_SOURCE_MODE must be development or production" >&2
        exit 1
        ;;
esac

DO_REBOOT=false
DO_CLIENT_TEST=false
DO_IDEMPOTENCY=false
DO_BOOTSTRAP_TIMEOUT=false
DO_STOPPED_CONTAINER=false
DO_INVALID_CADDY=false
for arg in "$@"; do
    case "${arg}" in
        --reboot-test) DO_REBOOT=true ;;
        --client-test) DO_CLIENT_TEST=true ;;
        --idempotency-test) DO_IDEMPOTENCY=true ;;
        --bootstrap-timeout-test) DO_BOOTSTRAP_TIMEOUT=true ;;
        --stopped-container-test) DO_STOPPED_CONTAINER=true ;;
        --invalid-caddy-test) DO_INVALID_CADDY=true; DO_IDEMPOTENCY=true ;;
        *) fail "Unknown argument: ${arg}" ;;
    esac
done

for tool in qemu-system-x86_64 qemu-img genisoimage curl ssh-keygen openssl; do
    command -v "${tool}" >/dev/null || fail "required tool not found: ${tool}"
done
command -v ssh >/dev/null || fail "required tool not found: ssh"

if [[ -n "${QEMU_STATE_DIR:-}" ]]; then
    mkdir -p -- "${QEMU_STATE_DIR}"
    chmod 0700 "${QEMU_STATE_DIR}"
    TMP_DIR="$(cd -- "${QEMU_STATE_DIR}" && pwd -P)"
    [[ -z "$(find "${TMP_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]] || \
        fail "QEMU_STATE_DIR must be empty"
else
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-qemu.XXXXXX")"
fi
STATE_SENTINEL="${TMP_DIR}/.qemu-install-state"
printf 'qemu-install-v1\n' >"${STATE_SENTINEL}"
QEMU_PID=""
cleanup() {
    local exit_status=$?
    if [[ "${E2E_KEEP_STATE_ON_FAILURE:-0}" == 1 && ${exit_status} -ne 0 ]]; then
        [[ -n "${QEMU_STATE_DIR:-}" ]] || \
            fail "E2E_KEEP_STATE_ON_FAILURE requires QEMU_STATE_DIR"
        echo "[E2E] Failure state preserved at ${TMP_DIR} (qemu pid ${QEMU_PID})" >&2
        return
    fi
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" >/dev/null 2>&1; then
        kill "${QEMU_PID}" >/dev/null 2>&1 || true
        sleep 2
    fi
    [[ -f "${STATE_SENTINEL}" && "$(<"${STATE_SENTINEL}")" == qemu-install-v1 ]] || \
        fail "refusing to remove an unrecognized QEMU state directory"
    rm -rf -- "${TMP_DIR}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Keep the installed tree and later client checks on the same source revision.
SOURCE_DIR="${TMP_DIR}/source"
snapshot_source "${ROOT_DIR}" "${SOURCE_DIR}"

# --- test fixtures ----------------------------------------------------------
ssh-keygen -q -t ed25519 -N "" -f "${TMP_DIR}/id_ed25519" -C "e2e-ztvps"
PUBKEY="$(cat "${TMP_DIR}/id_ed25519.pub")"
ADMIN_PASS="$(openssl rand -hex 12)"
ADGUARD_PASS="$(openssl rand -hex 12)"
WG_PASS="${NOOK_WG_PASSWORD:-Twelve\$COMPOSE_PROBE}"
WG_TRAFFIC_MODE="${NOOK_WG_TRAFFIC_MODE:-services}"

copy_repo_to_guest() {
    local target="$1" port="$2" key="$3"
    run_remote "${target}" "${port}" "${key}" \
        "command -v git >/dev/null || (sudo apt-get update -qq && sudo apt-get install -y -qq git)"
    tar -C "${SOURCE_DIR}" -czf - . | \
        run_remote_stdin "${target}" "${port}" "${key}" \
        "sudo mkdir -p /tmp/ztrepo && sudo find /tmp/ztrepo -mindepth 1 -delete && sudo tar xzf - -C /tmp/ztrepo && sudo chown -R \$(id -u):\$(id -g) /tmp/ztrepo && cd /tmp/ztrepo && git init -q -b '${INSTALL_REF}' && git add -A && git -c user.name=e2e -c user.email=e2e.invalid commit -qm e2e-source"
}

run_repository_installer() {
    local target="$1" port="$2" key="$3"
    local state_mode="${4:-fresh}"
    local credential_env=""
    local source_env=""
    local installer_log="${TMP_DIR}/installer.log"
    local installer_status=0
    credential_env="$(build_installer_credential_env \
        "${state_mode}" "${ADMIN_PASS}" "${ADGUARD_PASS}" "${WG_PASS}" "${PUBKEY}")"
    if [[ "${E2E_SOURCE_MODE}" == "development" ]]; then
        source_env="NOOK_DEV_MODE=1 NOOK_REPO_URL=/tmp/ztrepo NOOK_RELEASE_REF='${INSTALL_REF}'"
    fi
    run_remote "${target}" "${port}" "${key}" \
        "cd /tmp/ztrepo && sudo env \
        PATH='${E2E_DOCKER_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}' \
        NOOK_NONINTERACTIVE=1 \
        ${source_env} \
        NOOK_SSH_PORT='${E2E_SSH_PORT}' \
        NOOK_WG_PORT='${E2E_WG_PORT}' \
        NOOK_ADMIN_USER=sysadmin \
        ${credential_env} \
        NOOK_WG_TRAFFIC_MODE='${WG_TRAFFIC_MODE}' \
        NOOK_INTERNAL_DOMAIN_SUFFIX='${INTERNAL_DOMAIN_SUFFIX}' \
        NOOK_INTERNAL_DOMAINS='${WG_INTERNAL_DOMAIN} ${ADGUARD_INTERNAL_DOMAIN}' \
        NOOK_WG_HOST=127.0.0.1 \
        bash ./install.sh" 2>&1 | tee "${installer_log}" || installer_status=$?
    if [[ "${E2E_SOURCE_MODE}" == "development" ]]; then
        grep -Fq "NON-PRODUCTION DEVELOPMENT MODE" "${installer_log}" || \
            fail "development installer warning was not emitted"
    else
        grep -Eq "Verified signed release tag ${INSTALLER_RELEASE_REF//./\\.} for nikitasmadych2001@gmail\\.com at [0-9a-f]{40}\\." \
            "${installer_log}" || fail "production installer provenance was not emitted"
        ! grep -Fq "NON-PRODUCTION DEVELOPMENT MODE" "${installer_log}" || \
            fail "production installer emitted the development warning"
    fi
    # Callers intentionally use this function in an if/pipeline, disabling
    # errexit within it. Provenance checks must not mask a failed installer.
    return "${installer_status}"
}

verify_wg_login() {
    local target="$1" port="$2" key="$3" response
    # wg-easy 15.4 moved password login from POST /api/session to POST /api/auth/password
    # shellcheck disable=SC2016
    response="$(printf '%s\n' "${WG_PASS}" | \
        run_remote_stdin "${target}" "${port}" "${key}" \
        'IFS= read -r wg_password; curl -fsS -X POST -H "Content-Type: application/json" --data "{\"username\":\"admin\",\"password\":\"${wg_password}\",\"remember\":false}" http://127.0.0.1:51821/api/auth/password')"
    grep -q '"status":"success"' <<<"${response}" || fail "wg-easy login failed"
}

verify_bootstrap_secret_free() {
    local target="$1" port="$2" key="$3"
    # shellcheck disable=SC2016
    run_remote "${target}" "${port}" "${key}" \
        'sudo sh -eu -c '\''
            if grep -Eq "^[[:space:]]+INIT_[A-Z_]+:" /opt/vps-nook/docker-compose.yml; then exit 1; fi
            inspect_env="$(docker inspect wg-easy --format "{{range .Config.Env}}{{println .}}{{end}}")"
            if printf "%s\n" "$inspect_env" | grep -q "^INIT_PASSWORD="; then exit 1; fi
            if printf "%s\n" "$inspect_env" | grep "^INIT_" | grep -qvx "INIT_ENABLED=false"; then exit 1; fi
            if find /opt/vps-nook -maxdepth 1 -type f -name "docker-compose.yml.bak*" -print -quit | grep -q .; then exit 1; fi
        '\''' >/dev/null
}

verify_bootstrap_state() {
    local target="$1" port="$2" key="$3" expected="$4"
    run_remote "${target}" "${port}" "${key}" \
        "sudo EXPECTED_STATE='${expected}' python3 -c \"import os, pathlib, sqlite3; path=pathlib.Path('/opt/vps-nook/volumes/wg-easy/wg-easy.db'); expected=os.environ['EXPECTED_STATE']; rows=[] if not path.exists() else sqlite3.connect(path).execute('SELECT setup_step FROM general_table').fetchall(); complete=(rows == [(0,)]); raise SystemExit(0 if (complete if expected == 'complete' else not complete) else 1)\""
}

verify_bootstrap_auth_tasks_ran() {
    local log_path="$1"
    LOG_PATH="${log_path}" python3 - <<'PY'
import os
from pathlib import Path

lines = Path(os.environ["LOG_PATH"]).read_text(encoding="utf-8").splitlines()
tasks = (
    "Compose | Bootstrap | Authenticate initial wg-easy setup",
    "Compose | Bootstrap | Authenticate re-secured wg-easy setup",
)
for task in tasks:
    starts = [index for index, line in enumerate(lines) if line.startswith("TASK [") and task in line]
    if len(starts) != 1:
        raise SystemExit(1)
    start = starts[0] + 1
    end = next((index for index in range(start, len(lines)) if lines[index].startswith("TASK [")), len(lines))
    outcome = lines[start:end]
    if any("skipping:" in line for line in outcome) or not any(
        line.startswith(("ok:", "changed:")) for line in outcome
    ):
        raise SystemExit(1)
PY
}

verify_task_skipped() {
    local log_path="$1" task_name="$2"
    LOG_PATH="${log_path}" TASK_NAME="${task_name}" python3 - <<'PY'
import os
from pathlib import Path

lines = Path(os.environ["LOG_PATH"]).read_text(encoding="utf-8").splitlines()
task_name = os.environ["TASK_NAME"]
starts = [index for index, line in enumerate(lines) if line.startswith("TASK [") and task_name in line]
if len(starts) != 1:
    raise SystemExit(1)
start = starts[0] + 1
end = next((index for index in range(start, len(lines)) if lines[index].startswith("TASK [")), len(lines))
if not any("skipping:" in line for line in lines[start:end]):
    raise SystemExit(1)
PY
}

run_compose_deployment() {
    local target="$1" port="$2" key="$3"
    local suffix="${4:-${INTERNAL_DOMAIN_SUFFIX:-internal}}"
    local wg_domain="${5:-${WG_INTERNAL_DOMAIN:-wg.internal}}"
    local adguard_domain="${6:-${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}}"
    local docker_path="${7:-${E2E_DOCKER_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}}"
    run_remote "${target}" "${port}" "${key}" \
        "sudo env PATH='${docker_path}' sh -c 'cd /opt/vps-nook-installer/repo && \
        exec /opt/vps-nook-installer/venv/bin/ansible-playbook \
        -i inventory/localhost.yml site.yml --tags compose \
        --vault-password-file /etc/vps-nook/installer-vault.pass \
        --extra-vars @/etc/vps-nook/installer-vault.yml \
        -e internal_domain_suffix=\"\$1\" \
        -e wg_internal_domain=\"\$2\" \
        -e adguard_internal_domain=\"\$3\"' \
        sh '${suffix}' '${wg_domain}' '${adguard_domain}'"
}

install_reload_audit() {
    local target="$1" port="$2" key="$3"
    run_remote "${target}" "${port}" "${key}" \
        "sudo install -d -m 0755 /tmp/e2e-docker-bin && printf '0\\n' | sudo tee /tmp/e2e-caddy-reload-count >/dev/null && printf '%s\\n' '#!/bin/sh' 'if [ \"\$1\" = exec ] && [ \"\$2\" = caddy ] && [ \"\$3\" = caddy ] && [ \"\$4\" = reload ]; then' '    count=\$(cat /tmp/e2e-caddy-reload-count)' '    printf \"%s\\\\n\" \"\$((count + 1))\" > /tmp/e2e-caddy-reload-count' '    if [ -e /tmp/e2e-caddy-fail-next-reload ]; then' '        unlink /tmp/e2e-caddy-fail-next-reload' '        exit 42' '    fi' 'fi' 'exec /usr/bin/docker \"\$@\"' | sudo tee /tmp/e2e-docker-bin/docker >/dev/null && sudo chmod 0755 /tmp/e2e-docker-bin/docker"
}

remote_reload_count() {
    local target="$1" port="$2" key="$3"
    run_remote "${target}" "${port}" "${key}" \
        "sudo cat /tmp/e2e-caddy-reload-count"
}

remote_caddy_admin_hash() {
    local target="$1" port="$2" key="$3"
    run_remote "${target}" "${port}" "${key}" \
        "sudo docker exec caddy wget -qO- http://127.0.0.1:2019/config/ | sha256sum | cut -d' ' -f1"
}

verify_caddy_site() {
    local target="$1" port="$2" key="$3" domain="$4" expected="$5"
    run_remote "${target}" "${port}" "${key}" \
        "curl -kfsS --resolve '${domain}:443:10.66.0.3' 'https://${domain}/'" | \
        grep -Fqx "${expected}" || fail "Caddy did not serve expected content for ${domain}"
}

verify_caddy_site_reachable() {
    local target="$1" port="$2" key="$3" domain="$4"
    run_remote "${target}" "${port}" "${key}" \
        "curl -kfsS --resolve '${domain}:443:10.66.0.3' 'https://${domain}/' -o /dev/null" || \
        fail "Caddy site became unreachable for ${domain}"
}

echo "[E2E] image=${QEMU_IMAGE}"
echo "[E2E] installer_commit=$(git rev-parse HEAD)"
echo "[E2E] source_mode=${E2E_SOURCE_MODE} ref=${INSTALL_REF} ssh_port=${E2E_SSH_PORT} wg_port=${E2E_WG_PORT} user=${QEMU_USER}"

# --- guest image + cloud-init seed + boot ------------------------------------
boot_vm "${TMP_DIR}" "${QEMU_IMAGE}" 20 2048 2 ztvps-e2e ztvps-e2e "" \
    "hostfwd=tcp:127.0.0.1:${QEMU_SSH_PORT}-:22" \
    "hostfwd=tcp:127.0.0.1:${QEMU_ADMIN_PORT}-:${E2E_SSH_PORT}" \
    "hostfwd=udp:127.0.0.1:${QEMU_WG_PORT}-:${E2E_WG_PORT}"
echo "[E2E] image_sha256=$(sha256sum "${TMP_DIR}/cloud.img" | cut -d' ' -f1)"

GUEST="${QEMU_USER}@127.0.0.1"
echo "[E2E] Waiting for cloud-init to finish (SSH on guest:22)..."
require_ssh_ready "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" 60
E2E_KNOWN_HOSTS="${TMP_DIR}/known_hosts"
: >"${E2E_KNOWN_HOSTS}"
chmod 0600 "${E2E_KNOWN_HOSTS}"
record_ssh_host_key 127.0.0.1 "${QEMU_SSH_PORT}" "${E2E_KNOWN_HOSTS}"
export E2E_KNOWN_HOSTS
require_wrong_host_key_rejected "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519"
require_wrong_scp_host_key_rejected "${GUEST}" "${QEMU_SSH_PORT}" \
    "${TMP_DIR}/id_ed25519"

# --- copy the repo into the guest -------------------------------------------
echo "[E2E] Copying the repository into the guest..."
copy_repo_to_guest "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519"

if [[ "${DO_BOOTSTRAP_TIMEOUT}" == "true" ]]; then
    echo "[E2E] Injecting a bounded pre-setup wg-easy startup timeout..."
    run_remote "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" \
        "python3 -c \"from pathlib import Path; path=Path('/tmp/ztrepo/roles/vps_orchestration/templates/docker-compose.yml.j2'); marker='    container_name: wg-easy\\n'; data=path.read_text(); count=data.count(marker); count == 1 or (_ for _ in ()).throw(RuntimeError('unexpected wg-easy service count')); path.write_text(data.replace(marker, marker + '    entrypoint: [\\\"sleep\\\", \\\"300\\\"]\\n'))\" && grep -q 'entrypoint: \[\"sleep\", \"300\"\]' /tmp/ztrepo/roles/vps_orchestration/templates/docker-compose.yml.j2 && cd /tmp/ztrepo && git add roles/vps_orchestration/templates/docker-compose.yml.j2 && git -c user.name=e2e -c user.email=e2e.invalid commit --amend --no-edit -q"
fi

# --- run the repository installer (non-interactive) --------------------------
echo "[E2E] Running the repository installer non-interactively (source_mode=${E2E_SOURCE_MODE})"
if [[ "${DO_BOOTSTRAP_TIMEOUT}" == "true" ]]; then
    bootstrap_failure_started="${SECONDS}"
    bootstrap_failure_log="${TMP_DIR}/bootstrap-failure.log"
    if run_repository_installer "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519" | \
        tee "${bootstrap_failure_log}"; then
        fail "injected wg-easy authentication timeout unexpectedly succeeded"
    fi
    bootstrap_failure_elapsed=$((SECONDS - bootstrap_failure_started))
    [[ "${bootstrap_failure_elapsed}" -ge 80 && "${bootstrap_failure_elapsed}" -le 1800 ]] || \
        fail "injected wg-easy authentication failure was not bounded"
    if grep -q "credential cleanup could not be verified" "${bootstrap_failure_log}"; then
        fail "safe upstream INIT default was rejected during cleanup"
    fi
    grep -q "secret state was scrubbed and setup remains retryable" \
        "${bootstrap_failure_log}" || fail "redacted retryable cleanup failure was not reported"
    record_ssh_host_key 127.0.0.1 "${QEMU_ADMIN_PORT}" "${E2E_KNOWN_HOSTS}"
    require_ssh_ready "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" 60
    verify_bootstrap_secret_free \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    verify_bootstrap_state \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" incomplete
    echo "[E2E] Injected bootstrap failure was nonzero, bounded, secret-free, and incomplete"

    echo "[E2E] Restoring the production role and retrying normally..."
    copy_repo_to_guest \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    bootstrap_retry_log="${TMP_DIR}/bootstrap-retry.log"
    run_repository_installer \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" existing | \
        tee "${bootstrap_retry_log}"
    verify_bootstrap_auth_tasks_ran "${bootstrap_retry_log}"
    verify_bootstrap_state \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" complete
    echo "[E2E] Same-VM retry executed both authentication phases to durable completion"
else
    run_repository_installer "${GUEST}" "${QEMU_SSH_PORT}" "${TMP_DIR}/id_ed25519"
fi

echo "[E2E] Verifying the deployed stack on the hardened SSH port ${QEMU_ADMIN_PORT}"
if ! ssh-keygen -F "[127.0.0.1]:${QEMU_ADMIN_PORT}" \
    -f "${E2E_KNOWN_HOSTS}" >/dev/null; then
    record_ssh_host_key 127.0.0.1 "${QEMU_ADMIN_PORT}" "${E2E_KNOWN_HOSTS}"
fi
require_wrong_host_key_rejected "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" \
    "${TMP_DIR}/id_ed25519"
export E2E_SSH_PORT E2E_WG_PORT
verify_deployment "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
verify_traffic_mode "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" \
    "${TMP_DIR}/id_ed25519" "${WG_TRAFFIC_MODE}"
verify_wg_login "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
verify_bootstrap_secret_free \
    "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
echo "[E2E] wg-easy login and secret scrub verified"

if [[ "${DO_STOPPED_CONTAINER}" == "true" ]]; then
    stopped_log="${TMP_DIR}/stopped-container.log"
    if ! run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" \
        "${TMP_DIR}/id_ed25519" 'sudo docker stop --time 15 adguard >/dev/null'; then
        fail "could not stop AdGuard for the negative health probe"
    fi
    if (verify_deployment "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" \
        "${TMP_DIR}/id_ed25519") >"${stopped_log}" 2>&1; then
        fail "stopped AdGuard container was accepted as healthy"
    fi
    grep -q 'container adguard is not running and healthy' "${stopped_log}" || \
        fail "stopped-container failure did not identify adguard"
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo docker start adguard >/dev/null'
    sleep 20
    verify_deployment "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" \
        "${TMP_DIR}/id_ed25519"
    echo "[E2E] Stopped container was identified and recovered"
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
    verify_traffic_mode "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" \
        "${TMP_DIR}/id_ed25519" "${WG_TRAFFIC_MODE}"
    echo "[E2E] Reboot survival verified"
fi

if [[ "${DO_CLIENT_TEST}" == "true" ]]; then
    echo "[E2E] Installing wireguard-tools and jq in the guest..."
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo apt-get update -qq >/dev/null && sudo apt-get install -y -qq wireguard-tools jq openssl dnsutils resolvconf >/dev/null'
    echo "[E2E] Running the in-guest WireGuard client handshake test..."
    run_remote_stdin "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "sudo WG_PASSWORD='${WG_PASS}' WG_PORT='${E2E_WG_PORT}' WG_TRAFFIC_MODE='${WG_TRAFFIC_MODE}' WG_INTERNAL_DOMAIN='${WG_INTERNAL_DOMAIN}' ADGUARD_INTERNAL_DOMAIN='${ADGUARD_INTERNAL_DOMAIN}' bash -s" \
        < "${SOURCE_DIR}/tests/e2e/client-in-guest.sh"
fi

if [[ "${DO_IDEMPOTENCY}" == "true" ]]; then
    install_reload_audit \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    E2E_DOCKER_PATH="/tmp/e2e-docker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    wg_container_id_before="$(run_remote "sysadmin@127.0.0.1" \
        "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo docker inspect wg-easy --format "{{.Id}}"')"
    adguard_container_id_before="$(run_remote "sysadmin@127.0.0.1" \
        "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo docker inspect adguard --format "{{.Id}}"')"
    caddy_container_id_before="$(run_remote "sysadmin@127.0.0.1" \
        "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo docker inspect caddy --format "{{.Id}}"')"
    caddy_admin_hash_before="$(remote_caddy_admin_hash \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519")"
    echo "[E2E] Re-copying the repository into the guest (the reboot clears /tmp)..."
    copy_repo_to_guest \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    echo "[E2E] Re-running the installer to verify idempotency..."
    idempotency_log="${TMP_DIR}/idempotency.log"
    run_repository_installer \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" existing | \
        tee "${idempotency_log}"
    echo "[E2E] Verifying the stack after the second installer run..."
    verify_deployment "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    wg_container_id_after="$(run_remote "sysadmin@127.0.0.1" \
        "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo docker inspect wg-easy --format "{{.Id}}"')"
    adguard_container_id_after="$(run_remote "sysadmin@127.0.0.1" \
        "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo docker inspect adguard --format "{{.Id}}"')"
    caddy_container_id_after="$(run_remote "sysadmin@127.0.0.1" \
        "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        'sudo docker inspect caddy --format "{{.Id}}"')"
    caddy_admin_hash_after="$(remote_caddy_admin_hash \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519")"
    [[ "${wg_container_id_after}" == "${wg_container_id_before}" ]] || \
        fail "completed wg-easy setup was recreated"
    [[ "${adguard_container_id_after}" == "${adguard_container_id_before}" ]] || \
        fail "AdGuard was recreated on a no-change rerun"
    [[ "${caddy_container_id_after}" == "${caddy_container_id_before}" ]] || \
        fail "Caddy was recreated on a no-change rerun"
    [[ "${caddy_admin_hash_after}" == "${caddy_admin_hash_before}" ]] || \
        fail "Caddy active config changed on a no-change rerun"
    verify_task_skipped "${idempotency_log}" "Compose | Activate | Reload running Caddy" || \
        fail "Caddy reload was not skipped on a no-change rerun"
    [[ "$(remote_reload_count "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519")" == 0 ]] || \
        fail "Caddy reload was invoked on a no-change rerun"
    verify_wg_login "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    verify_bootstrap_secret_free \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    echo "[E2E] Completed rerun preserved wg-easy identity and credentials"

    caddy_managed_hash_before="$(run_remote "sysadmin@127.0.0.1" \
        "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "sudo sha256sum /opt/vps-nook/Caddyfile | cut -d' ' -f1")"
    if [[ "${DO_INVALID_CADDY}" == "true" || "${DO_IDEMPOTENCY}" == "true" ]]; then
    echo "[E2E] Rejecting an invalid Caddyfile.d candidate without changing the live site..."
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "printf '%s\\n' 'caddy-transaction.invalid {' | sudo tee /opt/vps-nook/Caddyfile.d/e2e-invalid.conf >/dev/null"
    invalid_caddy_log="${TMP_DIR}/invalid-caddy.log"
    if run_compose_deployment \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" | \
        tee "${invalid_caddy_log}"; then
        fail "invalid Caddyfile.d candidate unexpectedly deployed"
    fi
    grep -Fq "Caddy candidate validation failed" "${invalid_caddy_log}" || \
        fail "invalid Caddy candidate did not report validation failure"
    caddy_managed_hash_after="$(run_remote "sysadmin@127.0.0.1" \
        "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "sudo sha256sum /opt/vps-nook/Caddyfile | cut -d' ' -f1")"
    [[ "${caddy_managed_hash_after}" == "${caddy_managed_hash_before}" ]] || \
        fail "invalid Caddy candidate replaced the managed Caddyfile"
    [[ "$(remote_caddy_admin_hash "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519")" == "${caddy_admin_hash_before}" ]] || \
        fail "invalid Caddy candidate changed the active admin config"
    [[ "$(run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" 'sudo docker inspect caddy --format "{{.Id}}"')" == "${caddy_container_id_before}" ]] || \
        fail "invalid Caddy candidate recreated Caddy"
    verify_caddy_site_reachable "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" \
        "${TMP_DIR}/id_ed25519" "${WG_INTERNAL_DOMAIN:-wg.internal}"
    fi

    echo "[E2E] Rolling back the managed file and active config after an injected reload failure..."
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "sudo rm -f /opt/vps-nook/Caddyfile.d/e2e-invalid.conf && sudo touch /tmp/e2e-caddy-fail-next-reload"
    reload_failure_log="${TMP_DIR}/reload-failure.log"
    if run_compose_deployment \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "${INTERNAL_DOMAIN_SUFFIX}" "wg-rollback.${INTERNAL_DOMAIN_SUFFIX}" \
        "${ADGUARD_INTERNAL_DOMAIN}" | \
        tee "${reload_failure_log}"; then
        fail "injected Caddy reload failure unexpectedly deployed"
    fi
    grep -Fq "prior managed and active configuration were restored" \
        "${reload_failure_log}" || fail "Caddy reload failure did not report rollback"
    [[ "$(run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" "sudo sha256sum /opt/vps-nook/Caddyfile | cut -d' ' -f1")" == "${caddy_managed_hash_before}" ]] || \
        fail "reload failure did not restore the prior managed Caddyfile"
    [[ "$(remote_caddy_admin_hash "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519")" == "${caddy_admin_hash_before}" ]] || \
        fail "reload failure did not restore the prior active config"
    [[ "$(run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" 'sudo docker inspect caddy --format "{{.Id}}"')" == "${caddy_container_id_before}" ]] || \
        fail "reload failure recreated Caddy"
    [[ "$(remote_reload_count "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519")" == 2 ]] || \
        fail "reload failure did not attempt exactly one changed reload and one rollback reload"
    verify_caddy_site_reachable "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" \
        "${TMP_DIR}/id_ed25519" "${WG_INTERNAL_DOMAIN}"
    echo "[E2E] Recovering with a valid Caddyfile.d change and live reload..."
    caddy_probe_domain="caddy-probe.${INTERNAL_DOMAIN_SUFFIX:-internal}"
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "sudo rm -f /opt/vps-nook/Caddyfile.d/e2e-invalid.conf && printf '%s\\n' '${caddy_probe_domain} {' '    tls internal' '    respond caddy-probe-live 200' '}' | sudo tee /opt/vps-nook/Caddyfile.d/e2e-valid.conf >/dev/null"
    recovery_caddy_log="${TMP_DIR}/recovery-caddy.log"
    run_compose_deployment \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" | \
        tee "${recovery_caddy_log}"
    caddy_admin_hash_recovered="$(remote_caddy_admin_hash \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519")"
    [[ "${caddy_admin_hash_recovered}" != "${caddy_admin_hash_before}" ]] || \
        fail "valid Caddyfile.d change did not update active admin config"
    [[ "$(run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" 'sudo docker inspect caddy --format "{{.Id}}"')" == "${caddy_container_id_before}" ]] || \
        fail "valid Caddyfile.d change recreated Caddy"
    [[ "$(remote_reload_count "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519")" == 3 ]] || \
        fail "valid Caddyfile.d change did not invoke exactly one additional reload"
    verify_caddy_site "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" \
        "${TMP_DIR}/id_ed25519" "${caddy_probe_domain}" caddy-probe-live
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "sudo rm -f /opt/vps-nook/Caddyfile.d/e2e-valid.conf"
    run_compose_deployment \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" >/dev/null
    [[ "$(remote_reload_count "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519")" == 4 ]] || \
        fail "Caddy fixture cleanup did not invoke exactly one additional reload"
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "sudo rm -rf /tmp/e2e-docker-bin /tmp/e2e-caddy-reload-count /tmp/e2e-caddy-fail-next-reload"
    unset E2E_DOCKER_PATH
    echo "[E2E] Invalid candidate preserved live state; valid recovery reloaded without recreation"

    echo "[E2E] Exercising retry from a nonzero setup_step..."
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "sudo docker stop wg-easy >/dev/null && sudo python3 -c \"import sqlite3; db=sqlite3.connect('/opt/vps-nook/volumes/wg-easy/wg-easy.db'); db.execute('DELETE FROM users_table'); db.execute('UPDATE general_table SET setup_step=2'); db.commit(); db.close()\""
    run_repository_installer \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" existing
    run_remote "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519" \
        "sudo python3 -c \"import sqlite3; db=sqlite3.connect('/opt/vps-nook/volumes/wg-easy/wg-easy.db'); rows=db.execute('SELECT setup_step FROM general_table').fetchall(); db.close(); raise SystemExit(0 if rows == [(0,)] else 1)\""
    verify_wg_login "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    verify_bootstrap_secret_free \
        "sysadmin@127.0.0.1" "${QEMU_ADMIN_PORT}" "${TMP_DIR}/id_ed25519"
    echo "[E2E] Nonzero setup state retried to durable completion"
fi

if [[ "${QEMU_HOLD_FOR_EXTERNAL_CLIENT:-0}" == 1 ]]; then
    : "${QEMU_READY_FILE:?QEMU_READY_FILE is required for external-client hold mode}"
    : "${QEMU_RELEASE_FILE:?QEMU_RELEASE_FILE is required for external-client hold mode}"
    ready_tmp="$(mktemp "${TMP_DIR}/ready.tmp.XXXXXX")"
    printf 'vps_fixture=ready\n' >"${ready_tmp}"
    chmod 0600 "${ready_tmp}"
    mv -f -- "${ready_tmp}" "${QEMU_READY_FILE}"
    echo "[E2E] disposable VPS fixture ready for external-client lifecycle"
    hold_deadline=$((SECONDS + ${QEMU_HOLD_TIMEOUT:-1800}))
    while [[ ! -e "${QEMU_RELEASE_FILE}" ]]; do
        kill -0 "${QEMU_PID}" >/dev/null 2>&1 || fail "VPS fixture VM exited while held"
        ((SECONDS < hold_deadline)) || fail "timed out waiting for external-client cleanup"
        sleep 2
    done
fi

echo "[E2E] PASS: repository installer E2E succeeded in qemu/KVM"
