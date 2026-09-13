#!/usr/bin/env bash
# Re-run the current public installer against an already upgraded guest and
# prove that durable service identity and the encrypted installer state did not
# change. This script intentionally does not create or own the guest lifecycle.
set -euo pipefail
umask 077

if [[ ${1:-} == --help ]]; then
    echo 'Usage: idempotency-rerun.sh user@host ssh-port ssh-key repo-url current-ref'
    echo 'The existing encrypted installer state supplies all deployment credentials.'
    exit 0
fi
[[ $# -eq 5 ]] || { echo '[FAIL] expected target, port, key, repo URL, and ref' >&2; exit 2; }

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

TARGET="$1"
PORT="$2"
KEY="$3"
REPO_URL="$4"
CURRENT_REF="$5"
SSH_PORT="${E2E_SSH_PORT:-2222}"
WG_PORT="${E2E_WG_PORT:-51820}"
DOMAIN_SUFFIX="${INTERNAL_DOMAIN_SUFFIX:-internal}"
WG_DOMAIN="${WG_INTERNAL_DOMAIN:-wg.${DOMAIN_SUFFIX}}"
ADGUARD_DOMAIN="${ADGUARD_INTERNAL_DOMAIN:-adguard.${DOMAIN_SUFFIX}}"

[[ ${PORT} =~ ^[1-9][0-9]{0,4}$ && ${SSH_PORT} =~ ^[1-9][0-9]{0,4}$ \
    && ${WG_PORT} =~ ^[1-9][0-9]{0,4}$ ]] \
    || { echo '[FAIL] ports must be positive integers' >&2; exit 2; }
[[ ${CURRENT_REF} =~ ^[A-Za-z0-9._/@+-]+$ && ${CURRENT_REF} != *..* \
    && ${CURRENT_REF} != /* && ${CURRENT_REF} != */ ]] \
    || { echo '[FAIL] unsafe current ref' >&2; exit 2; }

remote_snapshot() {
    run_remote "${TARGET}" "${PORT}" "${KEY}" 'sudo bash -se' <<'REMOTE'
set -euo pipefail
project=/opt/vps-nook
for path in \
    "${project}/volumes/wg-easy/wg-easy.db" \
    "${project}/volumes/caddy/data/caddy/pki/authorities/local/root.crt" \
    "${project}/docker-compose.yml" \
    /etc/vps-nook/installer-vault.pass \
    /etc/vps-nook/installer-vault.yml; do
    test -f "${path}" && test ! -L "${path}"
    printf 'file:%s=%s\n' "${path}" "$(sha256sum "${path}" | cut -d' ' -f1)"
done
for container in wg-easy adguard caddy; do
    printf 'container:%s=%s\n' "${container}" \
        "$(docker inspect "${container}" --format '{{.Id}}')"
done
REMOTE
}

before="$(remote_snapshot)"

printf -v q_repo '%q' "${REPO_URL}"
printf -v q_ref '%q' "${CURRENT_REF}"
printf -v q_suffix '%q' "${DOMAIN_SUFFIX}"
printf -v q_domains '%q' "${WG_DOMAIN} ${ADGUARD_DOMAIN}"

echo '[E2E] Re-running the current installer on the upgraded guest...'
run_remote "${TARGET}" "${PORT}" "${KEY}" \
    "sudo env NOOK_DEV_MODE=1 NOOK_NONINTERACTIVE=1 \
    NOOK_REPO_URL=${q_repo} NOOK_RELEASE_REF=${q_ref} \
    NOOK_SSH_PORT='${SSH_PORT}' NOOK_WG_PORT='${WG_PORT}' \
    NOOK_ADMIN_USER=sysadmin \
    NOOK_INTERNAL_DOMAIN_SUFFIX=${q_suffix} NOOK_INTERNAL_DOMAINS=${q_domains} \
    bash /var/tmp/zt-current-install.sh"

after="$(remote_snapshot)"
if [[ ${after} != "${before}" ]]; then
    diff -u <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") >&2 || true
    fail 'no-change rerun changed durable state or recreated a service'
fi

verify_deployment "${TARGET}" "${PORT}" "${KEY}"
echo 'predicate.current_rerun_state_unchanged=PASS'
echo '[E2E] PASS: current-version rerun preserved service and vault identity'
