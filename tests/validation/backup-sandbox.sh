#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP="${ROOT}/scripts/backup.sh"
ACTIVE_SANDBOX=

cleanup_sandbox() {
    [[ -z ${ACTIVE_SANDBOX} || ! -e ${ACTIVE_SANDBOX} ]] || rm -rf -- "${ACTIVE_SANDBOX}"
}
trap cleanup_sandbox EXIT

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

run_characterization() {
    local sandbox bin project output log rc
    sandbox="$(mktemp -d)"
    ACTIVE_SANDBOX="${sandbox}"
    bin="${sandbox}/bin"
    project="${sandbox}/project"
    output="${sandbox}/backup.tar.gz"
    log="${sandbox}/events"
    mkdir -p "${bin}" "${project}/volumes"
    : >"${project}/docker-compose.yml"
    : >"${project}/volumes/state"

    cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BACKUP_TEST_LOG}"
EOF
cat >"${bin}/age" <<'EOF'
#!/usr/bin/env bash
output=
while (($#)); do
    if [[ $1 == -o ]]; then output=$2; shift 2; else shift; fi
done
if [[ -n ${output} ]]; then
    printf 'encrypted fixture\n' >"${output}"
else
    printf 'encrypted fixture\n'
fi
EOF
    chmod 700 "${bin}/docker" "${bin}/age"

    set +e
    PATH="${bin}:${PATH}" BACKUP_TEST_LOG="${log}" NOOK_PROJECT_ROOT="${project}" \
        AGE_KEY="test-recipient" bash "${BACKUP}" "${output}" \
        >"${sandbox}/stdout" 2>"${sandbox}/stderr"
    rc=$?
    set -e

    [[ ${rc} -eq 0 ]] || fail "characterization backup returned ${rc}"
    [[ -s "${output}.age" ]] || fail "characterization encrypted output missing"
    grep -q ' stop$' "${log}" || fail "characterization did not stop Compose"
    grep -q ' up -d --no-recreate$' "${log}" || fail "characterization did not restart Compose"
    rm -rf "${sandbox}"
    echo "[PASS] characterization: encrypted CLI run publishes an archive and restarts Compose"
}

run_missing_recipient() {
    local sandbox bin project output log rc
    sandbox="$(mktemp -d)"
    ACTIVE_SANDBOX="${sandbox}"
    bin="${sandbox}/bin"
    project="${sandbox}/project"
    output="${sandbox}/backup.tar.gz"
    log="${sandbox}/events"
    mkdir -p "${bin}" "${project}/volumes"
    : >"${project}/docker-compose.yml"
    cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BACKUP_TEST_LOG}"
EOF
    chmod 700 "${bin}/docker"
    set +e
    PATH="${bin}:${PATH}" BACKUP_TEST_LOG="${log}" NOOK_PROJECT_ROOT="${project}" \
        bash "${BACKUP}" "${output}" >"${sandbox}/stdout" 2>"${sandbox}/stderr"
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || fail "missing recipient unexpectedly succeeded"
    [[ ! -s "${log}" ]] || fail "missing recipient reached Compose"
    [[ ! -e "${output}" && ! -e "${output}.age" ]] || fail "missing recipient published output"
    rm -rf "${sandbox}"
    echo "[PASS] missing-recipient: fails before Compose stop"
}

run_missing_age() {
    local sandbox bin project output log rc
    sandbox="$(mktemp -d)"
    ACTIVE_SANDBOX="${sandbox}"
    bin="${sandbox}/bin"
    project="${sandbox}/project"
    output="${sandbox}/backup.tar.gz"
    log="${sandbox}/events"
    mkdir -p "${bin}" "${project}/volumes"
    : >"${project}/docker-compose.yml"
    cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BACKUP_TEST_LOG}"
EOF
    chmod 700 "${bin}/docker"
    set +e
    PATH="${bin}:/usr/bin:/bin" BACKUP_TEST_LOG="${log}" NOOK_PROJECT_ROOT="${project}" \
        AGE_KEY="test-recipient" bash "${BACKUP}" "${output}" \
        >"${sandbox}/stdout" 2>"${sandbox}/stderr"
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || fail "missing age unexpectedly succeeded"
    [[ ! -s "${log}" ]] || fail "missing age reached Compose"
    [[ ! -e "${output}" && ! -e "${output}.age" ]] || fail "missing age published output"
    rm -rf "${sandbox}"
    echo "[PASS] missing-age: fails before Compose stop"
}

run_encrypted() {
    local sandbox bin project output log rc mode
    sandbox="$(mktemp -d)"
    ACTIVE_SANDBOX="${sandbox}"
    bin="${sandbox}/bin"
    project="${sandbox}/project"
    output="${sandbox}/backup.tar.gz"
    log="${sandbox}/events"
    mkdir -p "${bin}" "${project}/volumes"
    : >"${project}/docker-compose.yml"
    : >"${project}/volumes/state"
    cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BACKUP_TEST_LOG}"
EOF
    cat >"${bin}/age" <<'EOF'
#!/usr/bin/env bash
output=
while (($#)); do
    if [[ $1 == -o ]]; then output=$2; shift 2; else shift; fi
done
if [[ -n ${output} ]]; then printf 'encrypted fixture\n' >"${output}"; else printf 'encrypted fixture\n'; fi
EOF
    chmod 700 "${bin}/docker" "${bin}/age"
    set +e
    PATH="${bin}:${PATH}" BACKUP_TEST_LOG="${log}" NOOK_PROJECT_ROOT="${project}" \
        AGE_KEY="test-recipient" bash "${BACKUP}" "${output}" \
        >"${sandbox}/stdout" 2>"${sandbox}/stderr"
    rc=$?
    set -e
    [[ ${rc} -eq 0 ]] || fail "encrypted backup returned ${rc}"
    [[ -s "${output}.age" && ! -e "${output}" ]] || fail "encrypted output path incorrect"
    mode="$(stat -c '%a' "${output}.age")"
    [[ ${mode} == 600 ]] || fail "encrypted output mode was ${mode}"
    [[ $(stat -c '%h' "${output}.age") == 1 ]] || fail "encrypted output retained an extra hard link"
    if find "${sandbox}" -maxdepth 1 -type f -name '.nook-backup.*' -print -quit | grep -q .; then
        fail "encrypted success left a private temporary file"
    fi
    grep -Fq "[OK] Backup written to ${output}.age " "${sandbox}/stdout" \
        || fail "encrypted final path was not reported exactly"
    rm -rf "${sandbox}"
    echo "[PASS] encrypted: only the expected mode-0600 .age path is published and reported"
}

run_plaintext_explicit() {
    local sandbox bin project output log rc mode
    sandbox="$(mktemp -d)"
    ACTIVE_SANDBOX="${sandbox}"
    bin="${sandbox}/bin"
    project="${sandbox}/project"
    output="${sandbox}/backup.tar.gz"
    log="${sandbox}/events"
    mkdir -p "${bin}" "${project}/volumes"
    : >"${project}/docker-compose.yml"
    : >"${project}/volumes/state"
    cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BACKUP_TEST_LOG}"
EOF
    chmod 700 "${bin}/docker"
    set +e
    PATH="${bin}:${PATH}" BACKUP_TEST_LOG="${log}" NOOK_PROJECT_ROOT="${project}" \
        bash "${BACKUP}" --allow-plaintext "${output}" \
        >"${sandbox}/stdout" 2>"${sandbox}/stderr"
    rc=$?
    set -e
    [[ ${rc} -eq 0 ]] || fail "explicit plaintext backup returned ${rc}"
    [[ -s "${output}" && ! -e "${output}.age" ]] || fail "plaintext output path incorrect"
    mode="$(stat -c '%a' "${output}")"
    [[ ${mode} == 600 ]] || fail "plaintext output mode was ${mode}"
    [[ $(stat -c '%h' "${output}") == 1 ]] || fail "plaintext output retained an extra hard link"
    tar -tzf "${output}" >/dev/null || fail "plaintext output was not a readable tar"
    grep -Fq '[3/4] Explicit plaintext backup requested.' "${sandbox}/stderr" \
        || fail "plaintext escape hatch was not identified as explicit"
    grep -Fq "[OK] Backup written to ${output} " "${sandbox}/stdout" \
        || fail "plaintext final path was not reported exactly"
    rm -rf "${sandbox}"
    echo "[PASS] plaintext-explicit: only the expected readable mode-0600 tar path is published"
}

run_archive_failure() {
    local sandbox bin project output log rc
    sandbox="$(mktemp -d)"
    ACTIVE_SANDBOX="${sandbox}"
    bin="${sandbox}/bin"
    project="${sandbox}/project"
    output="${sandbox}/backup.tar.gz"
    log="${sandbox}/events"
    mkdir -p "${bin}" "${project}/volumes"
    : >"${project}/docker-compose.yml"
    cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BACKUP_TEST_LOG}"
EOF
    cat >"${bin}/tar" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == -czf ]]; then exit 71; fi
exec /usr/bin/tar "$@"
EOF
    chmod 700 "${bin}/docker" "${bin}/tar"
    set +e
    PATH="${bin}:${PATH}" BACKUP_TEST_LOG="${log}" NOOK_PROJECT_ROOT="${project}" \
        bash "${BACKUP}" --allow-plaintext "${output}" \
        >"${sandbox}/stdout" 2>"${sandbox}/stderr"
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || fail "archive failure unexpectedly succeeded"
    grep -q ' stop$' "${log}" || fail "archive failure did not reach stop"
    grep -q ' up -d --no-recreate$' "${log}" || fail "archive failure did not restart Compose"
    [[ ! -e "${output}" && ! -e "${output}.age" ]] || fail "archive failure published output"
    rm -rf "${sandbox}"
    echo "[PASS] archive-failure: failure after stop restarts Compose and publishes nothing"
}

run_collision_race() {
    local sandbox bin project output log rc content
    sandbox="$(mktemp -d)"
    ACTIVE_SANDBOX="${sandbox}"
    bin="${sandbox}/bin"
    project="${sandbox}/project"
    output="${sandbox}/backup.tar.gz.age"
    log="${sandbox}/events"
    mkdir -p "${bin}" "${project}/volumes"
    : >"${project}/docker-compose.yml"
    : >"${project}/volumes/state"
    cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf 'compose %s\n' "$*" >>"${BACKUP_TEST_LOG}"
EOF
    cat >"${bin}/age" <<'EOF'
#!/usr/bin/env bash
printf 'encrypted fixture\n'
EOF
    cat >"${bin}/ln" <<'EOF'
#!/usr/bin/env bash
destination="${@: -1}"
printf 'collision-sentinel\n' >"${destination}"
printf 'publish collision\n' >>"${BACKUP_TEST_LOG}"
exec /usr/bin/ln "$@"
EOF
    cat >"${bin}/find" <<'EOF'
#!/usr/bin/env bash
printf 'rotation\n' >>"${BACKUP_TEST_LOG}"
exec /usr/bin/find "$@"
EOF
    chmod 700 "${bin}/docker" "${bin}/age" "${bin}/ln" "${bin}/find"
    set +e
    PATH="${bin}:${PATH}" BACKUP_TEST_LOG="${log}" NOOK_PROJECT_ROOT="${project}" \
        AGE_KEY="test-recipient" bash "${BACKUP}" "${output%.age}" \
        >"${sandbox}/stdout" 2>"${sandbox}/stderr"
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || fail "collision race unexpectedly succeeded"
    content="$(<"${output}")"
    [[ ${content} == collision-sentinel ]] || fail "collision overwrote the existing destination"
    grep -q '^publish collision$' "${log}" || fail "collision was not synchronized at publication"
    ! grep -q '^rotation$' "${log}" || fail "collision reached rotation"
    grep -q 'compose .* up -d --no-recreate$' "${log}" || fail "collision did not restart Compose"
    if find "${sandbox}" -maxdepth 1 -type f -name '.nook-backup.*' -print -quit | grep -q .; then
        fail "collision left a partial output"
    fi
    rm -rf "${sandbox}"
    echo "[PASS] collision-race: sentinel preserved, no rotation or partial, Compose restarted"
}

run_restart_failure() {
    local sandbox bin project output log rc mode
    sandbox="$(mktemp -d)"
    ACTIVE_SANDBOX="${sandbox}"
    bin="${sandbox}/bin"
    project="${sandbox}/project"
    output="${sandbox}/backup.tar.gz"
    log="${sandbox}/events"
    mkdir -p "${bin}" "${project}/volumes"
    : >"${project}/docker-compose.yml"
    : >"${project}/volumes/state"
    cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf 'compose %s\n' "$*" >>"${BACKUP_TEST_LOG}"
[[ $* != *' up -d --no-recreate' ]]
EOF
    cat >"${bin}/find" <<'EOF'
#!/usr/bin/env bash
printf 'rotation\n' >>"${BACKUP_TEST_LOG}"
exec /usr/bin/find "$@"
EOF
    chmod 700 "${bin}/docker" "${bin}/find"
    set +e
    PATH="${bin}:${PATH}" BACKUP_TEST_LOG="${log}" NOOK_PROJECT_ROOT="${project}" \
        bash "${BACKUP}" --allow-plaintext "${output}" \
        >"${sandbox}/stdout" 2>"${sandbox}/stderr"
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || fail "restart failure unexpectedly succeeded"
    [[ -s ${output} ]] || fail "restart failure removed the published archive"
    mode="$(stat -c '%a' "${output}")"
    [[ ${mode} == 600 ]] || fail "restart-failure archive mode was ${mode}"
    tar -tzf "${output}" >/dev/null || fail "restart-failure archive was invalid"
    grep -Fq "backup published at ${output}" "${sandbox}/stderr" \
        || fail "restart failure did not report the preserved archive"
    grep -Fq 'recovery required' "${sandbox}/stderr" \
        || fail "restart failure did not report recovery required"
    ! grep -q '^rotation$' "${log}" || fail "restart failure reached rotation"
    rm -rf "${sandbox}"
    echo "[PASS] restart-failure: nonzero result preserves the mode-0600 published archive"
}

run_encryption_failure() {
    local sandbox bin project output log rc
    sandbox="$(mktemp -d)"
    ACTIVE_SANDBOX="${sandbox}"
    bin="${sandbox}/bin"
    project="${sandbox}/project"
    output="${sandbox}/backup.tar.gz"
    log="${sandbox}/events"
    mkdir -p "${bin}" "${project}/volumes"
    : >"${project}/docker-compose.yml"
    : >"${project}/volumes/state"
    cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BACKUP_TEST_LOG}"
EOF
    cat >"${bin}/age" <<'EOF'
#!/usr/bin/env bash
exit 72
EOF
    chmod 700 "${bin}/docker" "${bin}/age"
    set +e
    PATH="${bin}:${PATH}" BACKUP_TEST_LOG="${log}" NOOK_PROJECT_ROOT="${project}" \
        AGE_KEY="test-recipient" bash "${BACKUP}" "${output}" \
        >"${sandbox}/stdout" 2>"${sandbox}/stderr"
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || fail "encryption failure unexpectedly succeeded"
    grep -q ' stop$' "${log}" || fail "encryption failure did not reach stop"
    grep -q ' up -d --no-recreate$' "${log}" || fail "encryption failure did not restart Compose"
    [[ ! -e "${output}" && ! -e "${output}.age" ]] || fail "encryption failure published output"
    if find "${sandbox}" -maxdepth 1 -type f -name '.nook-backup.*' -print -quit | grep -q .; then
        fail "encryption failure left a partial output"
    fi
    rm -rf "${sandbox}"
    echo "[PASS] encryption-failure: failure after stop restarts Compose and publishes nothing"
}

run_malformed_input() {
    local sandbox bin log rc_order rc_extra
    sandbox="$(mktemp -d)"
    ACTIVE_SANDBOX="${sandbox}"
    bin="${sandbox}/bin"
    log="${sandbox}/events"
    mkdir -p "${bin}"
    cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BACKUP_TEST_LOG}"
EOF
    chmod 700 "${bin}/docker"
    set +e
    PATH="${bin}:${PATH}" BACKUP_TEST_LOG="${log}" bash "${BACKUP}" \
        "${sandbox}/out.tar.gz" --allow-plaintext >/dev/null 2>&1
    rc_order=$?
    PATH="${bin}:${PATH}" BACKUP_TEST_LOG="${log}" bash "${BACKUP}" \
        --allow-plaintext "${sandbox}/one.tar.gz" "${sandbox}/two.tar.gz" >/dev/null 2>&1
    rc_extra=$?
    set -e
    [[ ${rc_order} -eq 2 && ${rc_extra} -eq 2 ]] || fail "malformed arguments were not rejected with rc2"
    [[ ! -s ${log} ]] || fail "malformed arguments reached Compose"
    rm -rf "${sandbox}"
    echo "[PASS] malformed-input: rejected argument order and extra arguments before Compose"
}

run_aggregate() {
    run_characterization
    run_encrypted
    run_plaintext_explicit
    run_missing_recipient
    run_missing_age
    run_archive_failure
    run_encryption_failure
    run_collision_race
    run_restart_failure
    run_malformed_input
    [[ ! -e ${ACTIVE_SANDBOX} ]] || fail "aggregate left its final sandbox directory"
    echo "[PASS] cleanup-receipt: sandbox directories and their fake binaries were removed; no processes were started"
    echo "[PASS] aggregate: all backup sandbox scenarios passed"
}

case "${1:-}" in
    --characterization) run_characterization ;;
    --missing-recipient) run_missing_recipient ;;
    --missing-age) run_missing_age ;;
    --encrypted) run_encrypted ;;
    --plaintext-explicit) run_plaintext_explicit ;;
    --archive-failure) run_archive_failure ;;
    --collision-race) run_collision_race ;;
    --restart-failure) run_restart_failure ;;
    --encryption-failure) run_encryption_failure ;;
    --malformed-input) run_malformed_input ;;
    '') run_aggregate ;;
    *) fail "usage: backup-sandbox.sh [--characterization|--encrypted|--plaintext-explicit|--missing-recipient|--missing-age|--archive-failure|--encryption-failure|--collision-race|--restart-failure|--malformed-input]" ;;
esac
