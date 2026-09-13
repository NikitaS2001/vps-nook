#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ ${1:-} == --help ]]; then
    echo 'Usage: restore-drill.sh [--self-test-age-provenance] [user@host] [ssh-port] [ssh-key]'
    exit 0
fi
if [[ ${1:-} == --self-test-age-provenance ]]; then
    [[ $# -eq 1 ]] || { echo '[FAIL] self-test accepts no additional arguments' >&2; exit 2; }
    command -v docker >/dev/null || { echo '[FAIL] docker is required for age provenance self-test' >&2; exit 1; }
    self_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/zt-age-provenance.XXXXXX")"
    trap 'rm -rf -- "${self_test_dir}"' EXIT
    awk 'index($0, "<<'\''REMOTE_AGE'\''") {emit=1; next}
        $0 == "REMOTE_AGE" {exit} emit {print}' "$0" >"${self_test_dir}/prepare.sh"
    awk 'index($0, "<<'\''REMOTE_CLEANUP'\''") {emit=1; next}
        $0 == "REMOTE_CLEANUP" {exit} emit {print}' "$0" >"${self_test_dir}/cleanup.sh"
    chmod 0700 "${self_test_dir}/prepare.sh" "${self_test_dir}/cleanup.sh"

    docker run --rm -v "${self_test_dir}:/fixture:ro" ubuntu:24.04 bash -se <<'STALE_PREEXISTING'
set -euo pipefail
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends age >/dev/null
install -d -m 0700 /var/tmp/zt-restore-drill
printf 'age-package-installed-by-test=stale-run\n' >/var/tmp/zt-restore-drill/age-package-installed-by-test
chmod 0600 /var/tmp/zt-restore-drill/age-package-installed-by-test
DRILL_WORK=/var/tmp/zt-restore-drill AGE_RUN_ID=current-run bash /fixture/prepare.sh
test ! -e /var/tmp/zt-restore-drill/age-package-installed-by-test
DRILL_WORK=/var/tmp/zt-restore-drill AGE_RUN_ID=current-run bash /fixture/cleanup.sh
dpkg-query -W age >/dev/null 2>&1
STALE_PREEXISTING
    echo '[PASS] age-provenance=stale-marker-preexisting-package-retained'

    docker run --rm -v "${self_test_dir}:/fixture:ro" ubuntu:24.04 bash -se <<'STALE_MISSING'
set -euo pipefail
install -d -m 0700 /var/tmp/zt-restore-drill
printf 'age-package-installed-by-test=stale-run\n' >/var/tmp/zt-restore-drill/age-package-installed-by-test
chmod 0600 /var/tmp/zt-restore-drill/age-package-installed-by-test
DRILL_WORK=/var/tmp/zt-restore-drill AGE_RUN_ID=current-run bash /fixture/prepare.sh
grep -Fqx 'age-package-installed-by-test=current-run' /var/tmp/zt-restore-drill/age-package-installed-by-test
DRILL_WORK=/var/tmp/zt-restore-drill AGE_RUN_ID=current-run bash /fixture/cleanup.sh
! dpkg-query -W age >/dev/null 2>&1
STALE_MISSING
    echo '[PASS] age-provenance=stale-marker-missing-package-current-install-removed'

    docker run --rm -v "${self_test_dir}:/fixture:ro" ubuntu:24.04 bash -se <<'INTERRUPTED'
set -euo pipefail
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends age >/dev/null
install -d -m 0700 /var/tmp/zt-restore-drill
DRILL_WORK=/var/tmp/zt-restore-drill AGE_RUN_ID=current-run bash /fixture/cleanup.sh
dpkg-query -W age >/dev/null 2>&1
INTERRUPTED
    echo '[PASS] age-provenance=interrupted-without-current-marker-package-retained'

    docker run --rm -v "${self_test_dir}:/fixture:ro" ubuntu:24.04 bash -se <<'CURRENT_OWNER'
set -euo pipefail
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends age >/dev/null
install -d -m 0700 /var/tmp/zt-restore-drill
printf 'age-package-installed-by-test=current-run\n' >/var/tmp/zt-restore-drill/age-package-installed-by-test
chmod 0600 /var/tmp/zt-restore-drill/age-package-installed-by-test
DRILL_WORK=/var/tmp/zt-restore-drill AGE_RUN_ID=current-run bash /fixture/cleanup.sh
! dpkg-query -W age >/dev/null 2>&1
CURRENT_OWNER
    echo '[PASS] age-provenance=current-marker-owned-package-removed'
    exit 0
fi
[[ $# -le 3 ]] || { echo '[FAIL] too many arguments' >&2; exit 2; }

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${E2E_DIR}/../.." && pwd)"
# shellcheck source=tests/e2e/common.sh
source "${E2E_DIR}/common.sh"

TARGET="${1:-sysadmin@127.0.0.1}"
PORT="${2:-${QEMU_ADMIN_PORT:-2255}}"
KEY="${3:-${TMP_DIR:-/tmp}/id_ed25519}"
REMOTE_WORK="${RESTORE_DRILL_REMOTE_WORK:-/var/tmp/zt-restore-drill}"
REMOTE_PROJECT_ROOT="${RESTORE_DRILL_PROJECT_ROOT:-/opt/vps-nook}"
DRILL_TIMEOUT="${RESTORE_DRILL_TIMEOUT:-600}"
AGE_PREP_TIMEOUT="${RESTORE_DRILL_AGE_PREP_TIMEOUT:-420}"
AGE_RUN_ID="$(openssl rand -hex 16)"
[[ ${REMOTE_WORK} =~ ^/var/tmp/zt-restore-drill([.][A-Za-z0-9_-]+)?$ ]] \
    || { echo '[FAIL] unsafe remote work path' >&2; exit 2; }
[[ ${REMOTE_PROJECT_ROOT} =~ ^/[A-Za-z0-9._/-]+$ \
    && ${REMOTE_PROJECT_ROOT} != / && ${REMOTE_PROJECT_ROOT} != *'/../'* ]] \
    || { echo '[FAIL] unsafe remote project root' >&2; exit 2; }
[[ ${DRILL_TIMEOUT} =~ ^[1-9][0-9]*$ ]] \
    || { echo '[FAIL] restore drill timeout must be a positive integer' >&2; exit 2; }
[[ ${AGE_PREP_TIMEOUT} =~ ^[1-9][0-9]*$ ]] \
    || { echo '[FAIL] age preparation timeout must be a positive integer' >&2; exit 2; }
cleanup_remote() {
    local original_rc=$? cleanup_rc=0
    trap - EXIT
    run_remote "${TARGET}" "${PORT}" "${KEY}" \
        "sudo timeout --signal=TERM --kill-after=15s '${AGE_PREP_TIMEOUT}s' env DRILL_WORK='${REMOTE_WORK}' AGE_RUN_ID='${AGE_RUN_ID}' bash -s" <<'REMOTE_CLEANUP' || cleanup_rc=$?
set -euo pipefail
work="${DRILL_WORK}"
provenance="${work}/age-package-installed-by-test"
installed_by_this_run=false
if [[ -f "${provenance}" && ! -L "${provenance}" \
    && "$(stat -c '%a:%U:%h' "${provenance}")" == '600:root:1' \
    && "$(<"${provenance}")" == "age-package-installed-by-test=${AGE_RUN_ID}" ]]; then
    installed_by_this_run=true
fi
if [[ "${installed_by_this_run}" == true ]]; then
    if dpkg-query -W -f='${db:Status-Status}' age 2>/dev/null \
        | grep -Fqx 'installed'; then
        export DEBIAN_FRONTEND=noninteractive
        removed=0
        for attempt in 1 2 3; do
            if timeout --signal=TERM --kill-after=10s 120s \
                apt-get remove -y -qq age >/dev/null; then
                removed=1
                break
            fi
            printf '[E2E] age dependency cleanup retry=%s\n' "${attempt}" >&2
            sleep 3
        done
        [[ "${removed}" == 1 ]]
    fi
    ! dpkg-query -W -f='${db:Status-Status}' age 2>/dev/null \
        | grep -Fqx 'installed'
    printf '[E2E] age dependency cleanup=test-installed-removed package_remains=false\n'
else
    package_remains=false
    if dpkg-query -W -f='${db:Status-Status}' age 2>/dev/null \
        | grep -Fqx 'installed'; then
        package_remains=true
    fi
    printf '[E2E] age dependency cleanup=pre-existing-retained package_remains=%s\n' \
        "${package_remains}"
fi
rm -rf -- "${work}"
rm -f -- /var/tmp/zt-f3-backup.sh /var/tmp/zt-f3-restore.sh
exit 0
REMOTE_CLEANUP
    if (( cleanup_rc != 0 )); then
        echo "[FAIL] restore drill remote cleanup failed rc=${cleanup_rc}" >&2
        return "${cleanup_rc}"
    fi
    return "${original_rc}"
}
trap cleanup_remote EXIT

run_remote "${TARGET}" "${PORT}" "${KEY}" \
    "sudo install -d -m 0700 '${REMOTE_WORK}'"
run_remote "${TARGET}" "${PORT}" "${KEY}" \
    "sudo timeout --signal=TERM --kill-after=15s '${AGE_PREP_TIMEOUT}s' env DRILL_WORK='${REMOTE_WORK}' AGE_RUN_ID='${AGE_RUN_ID}' bash -s" <<'REMOTE_AGE'
set -euo pipefail
umask 077
work="${DRILL_WORK}"
provenance="${work}/age-package-installed-by-test"
rm -f -- "${provenance}"

verify_age() {
    local probe
    probe="$(mktemp -d "${work}/age-probe.XXXXXX")"
    trap 'rm -rf -- "${probe}"' RETURN
    printf 'restore-drill-age-probe\n' >"${probe}/plain"
    age-keygen -o "${probe}/identity" >/dev/null 2>&1
    age -r "$(age-keygen -y "${probe}/identity")" \
        "${probe}/plain" >"${probe}/cipher" 2>/dev/null
    age -d -i "${probe}/identity" "${probe}/cipher" \
        >"${probe}/roundtrip" 2>/dev/null
    cmp -s "${probe}/plain" "${probe}/roundtrip"
    rm -rf -- "${probe}"
    trap - RETURN
}

if command -v age >/dev/null 2>&1 \
    && command -v age-keygen >/dev/null 2>&1 \
    && verify_age; then
    printf '[E2E] age dependency state=pre-existing verified=true\n'
    exit 0
fi

package_preexisting=false
if dpkg-query -W -f='${db:Status-Status}' age 2>/dev/null \
    | grep -Fqx 'installed'; then
    package_preexisting=true
else
    package_preexisting=false
fi

export DEBIAN_FRONTEND=noninteractive
installed=0
for attempt in 1 2 3; do
    if timeout --signal=TERM --kill-after=10s 120s apt-get update -qq \
        && timeout --signal=TERM --kill-after=10s 120s \
            apt-get install -y -qq --no-install-recommends age >/dev/null; then
        installed=1
        break
    fi
    printf '[E2E] age dependency install retry=%s\n' "${attempt}" >&2
    sleep 3
done
[[ "${installed}" == 1 ]] || {
    echo '[FAIL] age dependency installation exhausted bounded retries' >&2
    exit 1
}
command -v age >/dev/null 2>&1
command -v age-keygen >/dev/null 2>&1
verify_age || {
    echo '[FAIL] age dependency failed encryption/decryption verification' >&2
    exit 1
}
if [[ "${package_preexisting}" == false ]]; then
    provenance_tmp="$(mktemp "${work}/age-package-installed-by-test.tmp.XXXXXX")"
    printf 'age-package-installed-by-test=%s\n' "${AGE_RUN_ID}" >"${provenance_tmp}"
    chmod 0600 "${provenance_tmp}"
    mv -f -- "${provenance_tmp}" "${provenance}"
fi
if [[ "${package_preexisting}" == true ]]; then
    printf '[E2E] age dependency state=pre-existing-repaired verified=true\n'
else
    printf '[E2E] age dependency state=test-installed verified=true cleanup=scheduled\n'
fi
REMOTE_AGE
run_remote_stdin "${TARGET}" "${PORT}" "${KEY}" \
    "sudo tee /var/tmp/zt-f3-backup.sh >/dev/null && sudo chmod 0755 /var/tmp/zt-f3-backup.sh && sudo cp /var/tmp/zt-f3-backup.sh '${REMOTE_WORK}/backup.sh'" \
    <"${ROOT_DIR}/scripts/backup.sh"
run_remote_stdin "${TARGET}" "${PORT}" "${KEY}" \
    "sudo tee /var/tmp/zt-f3-restore.sh >/dev/null && sudo chmod 0755 /var/tmp/zt-f3-restore.sh && sudo cp /var/tmp/zt-f3-restore.sh '${REMOTE_WORK}/restore.sh'" \
    <"${ROOT_DIR}/scripts/restore.sh"
BACKUP_SHA="$(sha256sum "${ROOT_DIR}/scripts/backup.sh" | cut -d' ' -f1)"
RESTORE_SHA="$(sha256sum "${ROOT_DIR}/scripts/restore.sh" | cut -d' ' -f1)"
run_remote "${TARGET}" "${PORT}" "${KEY}" \
    "printf '%s  %s\\n' '${BACKUP_SHA}' '${REMOTE_WORK}/backup.sh' '${RESTORE_SHA}' '${REMOTE_WORK}/restore.sh' | sudo sha256sum -c - >/dev/null"

run_remote "${TARGET}" "${PORT}" "${KEY}" \
    "sudo timeout --signal=TERM --kill-after=30s '${DRILL_TIMEOUT}s' env DRILL_PROJECT_ROOT='${REMOTE_PROJECT_ROOT}' DRILL_WORK='${REMOTE_WORK}' bash -s" <<'REMOTE'
set -euo pipefail
umask 077
step=preflight
trap 'echo "[FAIL] restore drill remote step=${step}" >&2' ERR
project="${DRILL_PROJECT_ROOT}"
work="${DRILL_WORK}"
db="${project}/volumes/wg-easy/wg-easy.db"
ca="${project}/volumes/caddy/data/caddy/pki/authorities/local/root.crt"
override="${project}/docker-compose.override.yml"
command -v age >/dev/null
command -v age-keygen >/dev/null
test -f "${db}"
test -f "${ca}"
override_was_present=0
if [[ -f "${override}" ]]; then
    override_was_present=1
else
    test ! -e "${override}"
fi
db_before="$(sha256sum "${db}" | cut -d' ' -f1)"
ca_before="$(sha256sum "${ca}" | cut -d' ' -f1)"
override_before=absent
if [[ "${override_was_present}" == 1 ]]; then
    override_before="$(sha256sum "${override}" | cut -d' ' -f1)"
fi
step=backup
age-keygen -o "${work}/identity" >/dev/null 2>&1
chmod 0600 "${work}/identity"
install -m 0600 "${work}/identity" "${work}/restore-identity"
recipient="$(age-keygen -y "${work}/identity")"
env AGE_KEY="${recipient}" NOOK_PROJECT_ROOT="${project}" \
    "${work}/backup.sh" "${work}/backup.tar.gz" >/dev/null
archive="${work}/backup.tar.gz.age"
test -s "${archive}"
test "$(stat -c %a "${archive}")" = 600
head -c 18 "${archive}" | grep -q '^age-encryption.org'
step=destructive-mutation
if [[ "${override_was_present}" == 1 ]]; then
    docker compose -f "${project}/docker-compose.yml" \
        -f "${override}" stop >/dev/null
else
    docker compose -f "${project}/docker-compose.yml" stop >/dev/null
fi
rm -f -- "${db}" "${ca}" "${override}"
step=restore
if ! env NOOK_PROJECT_ROOT="${project}" \
    "${work}/restore.sh" "${archive}" "${work}/restore-identity" \
    >"${work}/restore.out" 2>"${work}/restore.err"; then
    sed -n '1,20p' "${work}/restore.out" >&2
    sed -n '1,20p' "${work}/restore.err" >&2
    exit 1
fi
step=verification
test "$(sha256sum "${db}" | cut -d' ' -f1)" = "${db_before}"
test "$(sha256sum "${ca}" | cut -d' ' -f1)" = "${ca_before}"
if [[ "${override_was_present}" == 1 ]]; then
    test "$(sha256sum "${override}" | cut -d' ' -f1)" = "${override_before}"
    docker compose -f "${project}/docker-compose.yml" -f "${override}" config -q
else
    test ! -e "${override}"
    docker compose -f "${project}/docker-compose.yml" config -q
fi
echo 'predicate.override_state_preserved=PASS'
docker exec wg-easy wg show >/dev/null
rm -f -- "${work}/identity" "${work}/restore-identity"
test ! -e "${work}/identity" && test ! -e "${work}/restore-identity"
echo 'predicate.age_identities_deleted=PASS'
step=complete
REMOTE

echo '[E2E] PASS: encrypted destructive backup/restore recovered DB, Caddy CA, and override'
