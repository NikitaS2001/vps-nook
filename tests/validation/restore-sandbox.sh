#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESTORE="${RESTORE_UNDER_TEST:-${ROOT_DIR}/scripts/restore.sh}"
BACKUP="${BACKUP_UNDER_TEST:-${ROOT_DIR}/scripts/backup.sh}"
ACTIVE_SANDBOX=

cleanup() {
    [[ -z ${ACTIVE_SANDBOX} || ! -e ${ACTIVE_SANDBOX} ]] || rm -rf -- "${ACTIVE_SANDBOX}"
}
trap cleanup EXIT

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

usage() {
    echo "usage: restore-sandbox.sh [--round-trip encrypted|plaintext|missing-root] [--malicious class] [--case name] [--self-test-malicious]" >&2
}

tree_digest() {
    local root="$1"
    if [[ ! -e ${root} && ! -L ${root} ]]; then
        echo absent
        return
    fi
    {
        find "${root}" -xdev -printf '%P|%y|%m|%l\n' | sort
        find "${root}" -xdev -type f -exec sha256sum {} + | sort
    } | sha256sum | cut -d' ' -f1
}

assert_no_restore_siblings() {
    if find "${ACTIVE_SANDBOX}/parent" -maxdepth 1 \
        \( -name '.nook-restore.stage.*' -o -name '.nook-restore.rollback.*' \
        -o -name '.nook-restore.failed.*' -o -name '.nook-restore.archive.*' \) \
        -print -quit | grep -q .; then
        fail "restore left a staging, rollback, failed, or archive sibling"
    fi
}

new_sandbox() {
    ACTIVE_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/zt-restore-test.XXXXXX")"
    mkdir -p "${ACTIVE_SANDBOX}/bin" "${ACTIVE_SANDBOX}/parent"
    export RESTORE_TEST_ROOT="${ACTIVE_SANDBOX}/parent/vps-nook"
    export RESTORE_TEST_LOG="${ACTIVE_SANDBOX}/events"
    export RESTORE_TEST_STATE="${ACTIVE_SANDBOX}/state"
    : >"${RESTORE_TEST_LOG}"
    : >"${RESTORE_TEST_STATE}"
    install_fake_tools
}

install_fake_tools() {
    cat >"${ACTIVE_SANDBOX}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'compose %s\n' "$*" >>"${RESTORE_TEST_LOG:?}"
mode="${RESTORE_TEST_MODE:-success}"
if [[ $* == *' config -q' ]]; then
    if [[ ${mode} == concurrent-rollback ]]; then
        mv -- "${RESTORE_TEST_ROOT}" "${RESTORE_TEST_ROOT}.displaced"
        mkdir -- "${RESTORE_TEST_ROOT}"
        printf 'competitor\n' >"${RESTORE_TEST_ROOT}/competitor"
        exit 42
    fi
    [[ ${mode} != config-failure && ${mode} != rollback-start-failure ]] || exit 41
elif [[ $* == *' config --services' ]]; then
    printf 'wg-easy\ncaddy\n'
elif [[ $* == *' up -d'* ]]; then
    count="$(wc -l <"${RESTORE_TEST_STATE}")"
    printf 'up\n' >>"${RESTORE_TEST_STATE}"
    if [[ ${mode} == startup-failure && ${count} -eq 0 ]]; then exit 43; fi
    if [[ ${mode} == rollback-start-failure ]]; then exit 44; fi
elif [[ $* == *' ps --status running --services' ]]; then
    [[ ${mode} == readiness-timeout ]] || printf 'wg-easy\ncaddy\n'
fi
SH
    cat >"${ACTIVE_SANDBOX}/bin/age" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -d ]]; then
    input="${@: -1}"
    tail -n +2 -- "${input}"
else
    input="${@: -1}"
    printf 'age-encryption.org/v1\n'
    cat -- "${input}"
fi
SH
    chmod 0700 "${ACTIVE_SANDBOX}/bin/docker" "${ACTIVE_SANDBOX}/bin/age"
}

make_project() {
    local root="$1" marker="$2"
    mkdir -p "${root}/volumes/wg-easy" \
        "${root}/volumes/caddy/data/caddy/pki/authorities/local"
    printf '%s-db\n' "${marker}" >"${root}/volumes/wg-easy/wg-easy.db"
    printf '%s-ca\n' "${marker}" >"${root}/volumes/caddy/data/caddy/pki/authorities/local/root.crt"
    printf 'services: {}\n' >"${root}/docker-compose.yml"
    printf '%s-override\n' "${marker}" >"${root}/docker-compose.override.yml"
}

make_archive() {
    local marker="$1" source="${ACTIVE_SANDBOX}/archive-source"
    make_project "${source}/vps-nook" "${marker}"
    tar -czf "${ACTIVE_SANDBOX}/restore.tar.gz" -C "${source}" vps-nook
}

run_restore() {
    local archive="$1" mode="${2:-success}"
    PATH="${ACTIVE_SANDBOX}/bin:${PATH}" \
        RESTORE_TEST_MODE="${mode}" \
        NOOK_PROJECT_ROOT="${RESTORE_TEST_ROOT}" \
        NOOK_RESTORE_READY_TIMEOUT="${RESTORE_TEST_READY_TIMEOUT:-1}" \
        NOOK_RESTORE_READY_INTERVAL=0.05 \
        bash "${RESTORE}" "${archive}" "${ACTIVE_SANDBOX}/identity" \
        >"${ACTIVE_SANDBOX}/stdout" 2>"${ACTIVE_SANDBOX}/stderr"
}

assert_restored_payload() {
    local marker="$1"
    [[ $(<"${RESTORE_TEST_ROOT}/volumes/wg-easy/wg-easy.db") == "${marker}-db" ]] \
        || fail "wg-easy DB was not restored"
    [[ $(<"${RESTORE_TEST_ROOT}/volumes/caddy/data/caddy/pki/authorities/local/root.crt") == "${marker}-ca" ]] \
        || fail "Caddy CA was not restored"
    [[ $(<"${RESTORE_TEST_ROOT}/docker-compose.override.yml") == "${marker}-override" ]] \
        || fail "Compose override was not restored"
    local override="-f ${RESTORE_TEST_ROOT}/docker-compose.override.yml"
    grep -F -- "${override} config -q" "${RESTORE_TEST_LOG}" >/dev/null \
        || fail "restored override missing from config -q"
    grep -F -- "${override} up -d" "${RESTORE_TEST_LOG}" >/dev/null \
        || fail "restored override missing from up -d"
}

run_round_trip() {
    local mode="$1" output archive
    new_sandbox
    make_project "${RESTORE_TEST_ROOT}" saved
    output="${ACTIVE_SANDBOX}/backup.tar.gz"
    printf 'identity\n' >"${ACTIVE_SANDBOX}/identity"
    if [[ ${mode} == encrypted ]]; then
        PATH="${ACTIVE_SANDBOX}/bin:${PATH}" RESTORE_TEST_MODE=success \
            AGE_KEY=test-recipient NOOK_PROJECT_ROOT="${RESTORE_TEST_ROOT}" \
            bash "${BACKUP}" "${output}" >"${ACTIVE_SANDBOX}/backup.out" 2>"${ACTIVE_SANDBOX}/backup.err"
        archive="${output}.age"
    else
        PATH="${ACTIVE_SANDBOX}/bin:${PATH}" RESTORE_TEST_MODE=success \
            NOOK_PROJECT_ROOT="${RESTORE_TEST_ROOT}" \
            bash "${BACKUP}" --allow-plaintext "${output}" \
            >"${ACTIVE_SANDBOX}/backup.out" 2>"${ACTIVE_SANDBOX}/backup.err"
        archive="${output}"
    fi
    [[ -s ${archive} && $(stat -c %a "${archive}") == 600 ]] || fail "private backup missing"
    if [[ ${mode} == missing-root ]]; then
        rm -rf -- "${RESTORE_TEST_ROOT}"
    else
        printf 'destroyed-db\n' >"${RESTORE_TEST_ROOT}/volumes/wg-easy/wg-easy.db"
        printf 'destroyed-ca\n' >"${RESTORE_TEST_ROOT}/volumes/caddy/data/caddy/pki/authorities/local/root.crt"
        printf 'destroyed-override\n' >"${RESTORE_TEST_ROOT}/docker-compose.override.yml"
    fi
    : >"${RESTORE_TEST_LOG}"
    run_restore "${archive}" success || fail "${mode} restore failed"
    assert_restored_payload saved
    assert_no_restore_siblings
    echo "[PASS] round-trip=${mode} restored_db_ca_override_and_compose_inputs"
    cleanup
    ACTIVE_SANDBOX=
}

run_malicious() {
    local attack_class="$1" archive project outside before after rc
    new_sandbox
    project="${RESTORE_TEST_ROOT}"
    archive="${ACTIVE_SANDBOX}/attack.tar.gz"
    outside="${ACTIVE_SANDBOX}/escape"
    make_project "${project}" original
    mkdir -p "${ACTIVE_SANDBOX}/payload"
    printf 'sentinel\n' >"${outside}"
    case "${attack_class}" in
        traversal)
            printf 'escaped\n' >"${ACTIVE_SANDBOX}/payload/value"
            tar -czf "${archive}" -C "${ACTIVE_SANDBOX}/payload" --transform='s,^value$,../escape,' value
            ;;
        absolute)
            printf 'escaped\n' >"${outside}"
            tar -czPf "${archive}" "${outside}"
            printf 'sentinel\n' >"${outside}"
            ;;
        symlink)
            mkdir -p "${ACTIVE_SANDBOX}/payload/vps-nook"
            ln -s "${outside}" "${ACTIVE_SANDBOX}/payload/vps-nook/link"
            tar -czf "${archive}" -C "${ACTIVE_SANDBOX}/payload" vps-nook
            ;;
        hardlink)
            mkdir -p "${ACTIVE_SANDBOX}/payload/vps-nook"
            printf 'linked\n' >"${ACTIVE_SANDBOX}/payload/vps-nook/source"
            ln "${ACTIVE_SANDBOX}/payload/vps-nook/source" "${ACTIVE_SANDBOX}/payload/vps-nook/hardlink"
            tar -czf "${archive}" -C "${ACTIVE_SANDBOX}/payload" vps-nook
            ;;
        special)
            mkdir -p "${ACTIVE_SANDBOX}/payload/vps-nook"
            mkfifo "${ACTIVE_SANDBOX}/payload/vps-nook/fifo"
            tar -czf "${archive}" -C "${ACTIVE_SANDBOX}/payload" vps-nook
            ;;
        duplicate)
            mkdir -p "${ACTIVE_SANDBOX}/payload/vps-nook"
            printf 'duplicate\n' >"${ACTIVE_SANDBOX}/payload/vps-nook/file"
            tar -czf "${archive}" -C "${ACTIVE_SANDBOX}/payload" vps-nook/file vps-nook/file
            ;;
        normalized-duplicate)
            mkdir -p "${ACTIVE_SANDBOX}/payload/vps-nook"
            printf 'duplicate\n' >"${ACTIVE_SANDBOX}/payload/vps-nook/file"
            tar -czf "${archive}" -C "${ACTIVE_SANDBOX}/payload" vps-nook/file vps-nook/./file
            ;;
        file-dir-conflict)
            printf 'file\n' >"${ACTIVE_SANDBOX}/payload/file"
            printf 'child\n' >"${ACTIVE_SANDBOX}/payload/child"
            tar -cf "${ACTIVE_SANDBOX}/first.tar" -C "${ACTIVE_SANDBOX}/payload" --transform='s,^file$,vps-nook/path,' file
            tar -rf "${ACTIVE_SANDBOX}/first.tar" -C "${ACTIVE_SANDBOX}/payload" --transform='s,^child$,vps-nook/path/child,' child
            gzip -c "${ACTIVE_SANDBOX}/first.tar" >"${archive}"
            ;;
        symlink-prefix)
            mkdir -p "${ACTIVE_SANDBOX}/payload/vps-nook"
            ln -s "${outside}" "${ACTIVE_SANDBOX}/payload/vps-nook/link"
            printf 'child\n' >"${ACTIVE_SANDBOX}/payload/child"
            tar -cf "${ACTIVE_SANDBOX}/first.tar" -C "${ACTIVE_SANDBOX}/payload" vps-nook/link
            tar -rf "${ACTIVE_SANDBOX}/first.tar" -C "${ACTIVE_SANDBOX}/payload" --transform='s,^child$,vps-nook/link/child,' child
            gzip -c "${ACTIVE_SANDBOX}/first.tar" >"${archive}"
            ;;
        wrong-root)
            mkdir -p "${ACTIVE_SANDBOX}/payload/not-vps-nook"
            printf 'wrong\n' >"${ACTIVE_SANDBOX}/payload/not-vps-nook/file"
            tar -czf "${archive}" -C "${ACTIVE_SANDBOX}/payload" not-vps-nook
            ;;
        *) fail "unknown malicious class ${attack_class}" ;;
    esac
    printf 'identity\n' >"${ACTIVE_SANDBOX}/identity"
    before="$(tree_digest "${project}")"
    set +e
    run_restore "${archive}" success
    rc=$?
    set -e
    after="$(tree_digest "${project}")"
    [[ ${rc} -ne 0 ]] || fail "${attack_class} archive was accepted"
    [[ ! -s ${RESTORE_TEST_LOG} ]] || fail "${attack_class} reached Compose"
    [[ $(<"${outside}") == sentinel ]] || fail "${attack_class} changed an outside file"
    [[ ${before} == "${after}" ]] || fail "${attack_class} changed the project"
    assert_no_restore_siblings
    echo "[PASS] malicious=${attack_class} rejected_before_stop_or_write"
    cleanup
    ACTIVE_SANDBOX=
}

run_preexisting_symlink() {
    local before rc
    new_sandbox
    make_archive restored
    mkdir -p "${ACTIVE_SANDBOX}/outside-root"
    printf 'sentinel\n' >"${ACTIVE_SANDBOX}/outside-root/state"
    ln -s "${ACTIVE_SANDBOX}/outside-root" "${RESTORE_TEST_ROOT}"
    printf 'identity\n' >"${ACTIVE_SANDBOX}/identity"
    before="$(tree_digest "${ACTIVE_SANDBOX}/outside-root")"
    set +e; run_restore "${ACTIVE_SANDBOX}/restore.tar.gz" success; rc=$?; set -e
    [[ ${rc} -ne 0 ]] || fail "preexisting symlink was accepted"
    [[ ! -s ${RESTORE_TEST_LOG} ]] || fail "preexisting symlink reached Compose"
    [[ ${before} == "$(tree_digest "${ACTIVE_SANDBOX}/outside-root")" ]] || fail "symlink redirected a write"
    [[ -L ${RESTORE_TEST_ROOT} ]] || fail "preexisting symlink was replaced"
    assert_no_restore_siblings
    echo '[PASS] case=preexisting-symlink rejected_without_redirected_write'
    cleanup; ACTIVE_SANDBOX=
}

run_failure_case() {
    local case_name="$1" mode="$2" prior="$3" before rc
    new_sandbox
    make_archive restored
    printf 'identity\n' >"${ACTIVE_SANDBOX}/identity"
    if [[ ${prior} == present ]]; then make_project "${RESTORE_TEST_ROOT}" prior; fi
    before="$(tree_digest "${RESTORE_TEST_ROOT}")"
    set +e; run_restore "${ACTIVE_SANDBOX}/restore.tar.gz" "${mode}"; rc=$?; set -e
    [[ ${rc} -ne 0 ]] || fail "${case_name} unexpectedly succeeded"
    [[ ${before} == "$(tree_digest "${RESTORE_TEST_ROOT}")" ]] || fail "${case_name} did not restore exact prior state"
    if [[ ${prior} == present ]]; then
        grep -F ' up -d' "${RESTORE_TEST_LOG}" >/dev/null || fail "${case_name} did not attempt prior-stack restart"
    fi
    if [[ ${case_name} == rollback-start-failure ]]; then
        grep -F 'prior stack failed to restart' "${ACTIVE_SANDBOX}/stderr" >/dev/null \
            || fail "rollback restart failure was not reported"
        find "${ACTIVE_SANDBOX}/parent" -maxdepth 1 -type d \
            -name '.nook-restore.failed.*' -print -quit | grep -q . \
            || fail "rollback restart failure did not preserve the failed restored tree"
    else
        assert_no_restore_siblings
    fi
    echo "[PASS] case=${case_name} failure_restored_exact_prior_state"
    cleanup; ACTIVE_SANDBOX=
}

run_activation_rollback() {
    run_failure_case activation-rollback-config config-failure present
    run_failure_case activation-rollback-startup startup-failure present
    run_failure_case activation-rollback-absent startup-failure absent
    echo '[PASS] case=activation-rollback config_and_startup_failures_restored_prior_or_absence'
}

run_readiness_timeout() {
    run_failure_case readiness-timeout-present readiness-timeout present
    run_failure_case readiness-timeout-absent readiness-timeout absent
    echo '[PASS] case=readiness-timeout restored_prior_or_absence'
}

run_lock_contention() {
    local before rc lock_fd
    new_sandbox
    make_project "${RESTORE_TEST_ROOT}" prior
    make_archive restored
    printf 'identity\n' >"${ACTIVE_SANDBOX}/identity"
    before="$(tree_digest "${RESTORE_TEST_ROOT}")"
    exec {lock_fd}>"${ACTIVE_SANDBOX}/parent/.nook-restore.lock"
    flock -n "${lock_fd}"
    set +e; run_restore "${ACTIVE_SANDBOX}/restore.tar.gz" success; rc=$?; set -e
    flock -u "${lock_fd}"
    exec {lock_fd}>&-
    [[ ${rc} -ne 0 ]] || fail "lock contention unexpectedly succeeded"
    [[ ${before} == "$(tree_digest "${RESTORE_TEST_ROOT}")" ]] || fail "lock contention changed project"
    [[ ! -s ${RESTORE_TEST_LOG} ]] || fail "lock contention reached Compose"
    assert_no_restore_siblings
    echo '[PASS] case=lock-contention rejected_before_state_change'
    cleanup; ACTIVE_SANDBOX=
}

run_descriptor_rejection() {
    local kind="$1" rc before archive
    new_sandbox
    make_project "${RESTORE_TEST_ROOT}" prior
    make_archive restored
    printf 'identity\n' >"${ACTIVE_SANDBOX}/identity.real"
    before="$(tree_digest "${RESTORE_TEST_ROOT}")"
    if [[ ${kind} == archive-symlink ]]; then
        ln -s "${ACTIVE_SANDBOX}/restore.tar.gz" "${ACTIVE_SANDBOX}/archive-link"
        archive="${ACTIVE_SANDBOX}/archive-link"
        printf 'identity\n' >"${ACTIVE_SANDBOX}/identity"
    else
        PATH="${ACTIVE_SANDBOX}/bin:${PATH}" age -r recipient "${ACTIVE_SANDBOX}/restore.tar.gz" >"${ACTIVE_SANDBOX}/restore.tar.gz.age"
        archive="${ACTIVE_SANDBOX}/restore.tar.gz.age"
        ln -s "${ACTIVE_SANDBOX}/identity.real" "${ACTIVE_SANDBOX}/identity"
    fi
    set +e; run_restore "${archive}" success; rc=$?; set -e
    [[ ${rc} -ne 0 ]] || fail "${kind} unexpectedly succeeded"
    [[ ${before} == "$(tree_digest "${RESTORE_TEST_ROOT}")" ]] || fail "${kind} changed project"
    [[ ! -s ${RESTORE_TEST_LOG} ]] || fail "${kind} reached Compose"
    assert_no_restore_siblings
    echo "[PASS] case=${kind} descriptor_open_rejected_symlink"
    cleanup; ACTIVE_SANDBOX=
}

run_activation_interrupt() {
    local before pid rc
    new_sandbox
    make_project "${RESTORE_TEST_ROOT}" prior
    make_archive restored
    printf 'identity\n' >"${ACTIVE_SANDBOX}/identity"
    before="$(tree_digest "${RESTORE_TEST_ROOT}")"
    PATH="${ACTIVE_SANDBOX}/bin:${PATH}" \
        RESTORE_TEST_MODE=readiness-timeout \
        NOOK_PROJECT_ROOT="${RESTORE_TEST_ROOT}" \
        NOOK_RESTORE_READY_TIMEOUT=10 \
        NOOK_RESTORE_READY_INTERVAL=0.05 \
        bash "${RESTORE}" "${ACTIVE_SANDBOX}/restore.tar.gz" "${ACTIVE_SANDBOX}/identity" \
        >"${ACTIVE_SANDBOX}/stdout" 2>"${ACTIVE_SANDBOX}/stderr" &
    pid=$!
    for _ in {1..2000}; do
        # The root is atomically renamed during activation. A file can disappear
        # after -f succeeds; Bash's $(<file) then aborts this observer. A failed
        # cat inside the conditional simply means the new root is not ready yet.
        if [[ $(cat -- "${RESTORE_TEST_ROOT}/volumes/wg-easy/wg-easy.db" 2>/dev/null) == restored-db ]]; then
            break
        fi
        sleep 0.005
    done
    kill -TERM "${pid}"
    set +e; wait "${pid}"; rc=$?; set -e
    [[ ${rc} -ne 0 ]] || fail "activation interrupt unexpectedly succeeded"
    [[ ${before} == "$(tree_digest "${RESTORE_TEST_ROOT}")" ]] || fail "activation interrupt did not restore prior root"
    grep -F ' up -d' "${RESTORE_TEST_LOG}" >/dev/null || fail "activation interrupt did not restart prior stack"
    assert_no_restore_siblings
    echo '[PASS] case=activation-interrupt signal_restored_prior_root_and_restarted'
    cleanup; ACTIVE_SANDBOX=
}

run_restore_drill() {
    local remote_work
    new_sandbox
    make_project "${RESTORE_TEST_ROOT}" saved
    cat >"${ACTIVE_SANDBOX}/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
command="${@: -1}"
bash -c "${command}"
SH
    cat >"${ACTIVE_SANDBOX}/bin/sudo" <<'SH'
#!/usr/bin/env bash
exec "$@"
SH
    cat >"${ACTIVE_SANDBOX}/bin/age-keygen" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -o ]]; then
    printf 'private-test-identity\n' >"$2"
else
    printf 'age1testrecipient\n'
fi
SH
    chmod 0700 "${ACTIVE_SANDBOX}/bin/ssh" "${ACTIVE_SANDBOX}/bin/sudo" \
        "${ACTIVE_SANDBOX}/bin/age-keygen"
    remote_work="/var/tmp/zt-restore-drill.$(basename "${ACTIVE_SANDBOX}" | tr '.' '_')"
    PATH="${ACTIVE_SANDBOX}/bin:${PATH}" \
        RESTORE_DRILL_REMOTE_WORK="${remote_work}" \
        RESTORE_DRILL_PROJECT_ROOT="${RESTORE_TEST_ROOT}" \
        RESTORE_DRILL_TIMEOUT=30 \
        "${ROOT_DIR}/tests/e2e/restore-drill.sh" fake-target 1 fake-key \
        >"${ACTIVE_SANDBOX}/drill.out" 2>"${ACTIVE_SANDBOX}/drill.err" \
        || { sed -n '1,40p' "${ACTIVE_SANDBOX}/drill.out" >&2; \
            sed -n '1,40p' "${ACTIVE_SANDBOX}/drill.err" >&2; fail "restore drill failed"; }
    grep -F '[E2E] PASS: encrypted destructive backup/restore recovered DB, Caddy CA, and override' \
        "${ACTIVE_SANDBOX}/drill.out" >/dev/null || fail "restore drill did not report recovery"
    assert_restored_payload saved
    [[ ! -e ${remote_work} ]] || fail "restore drill left remote work state"
    assert_no_restore_siblings
    echo '[PASS] case=restore-drill encrypted_destructive_remote_surface_recovered_state'
    cleanup; ACTIVE_SANDBOX=
}

run_concurrent_root() {
    local rc watcher
    new_sandbox
    make_archive restored
    printf 'identity\n' >"${ACTIVE_SANDBOX}/identity"
    (
        while ! find "${ACTIVE_SANDBOX}/parent" -maxdepth 1 -type d -name '.nook-restore.stage.*' -print -quit | grep -q .; do sleep 0.005; done
        mkdir "${RESTORE_TEST_ROOT}"
        printf 'competitor\n' >"${RESTORE_TEST_ROOT}/state"
    ) &
    watcher=$!
    set +e; run_restore "${ACTIVE_SANDBOX}/restore.tar.gz" success; rc=$?; set -e
    wait "${watcher}"
    [[ ${rc} -ne 0 ]] || fail "concurrent root unexpectedly succeeded"
    [[ ! -e ${RESTORE_TEST_ROOT} && ! -L ${RESTORE_TEST_ROOT} ]] || fail "concurrent root did not restore prior absence"
    assert_no_restore_siblings
    echo '[PASS] case=concurrent-root conflict_restored_prior_absence'
    cleanup; ACTIVE_SANDBOX=
}

run_concurrent_rollback() {
    local before rc
    new_sandbox
    make_project "${RESTORE_TEST_ROOT}" prior
    make_archive restored
    printf 'identity\n' >"${ACTIVE_SANDBOX}/identity"
    before="$(tree_digest "${RESTORE_TEST_ROOT}")"
    set +e; run_restore "${ACTIVE_SANDBOX}/restore.tar.gz" concurrent-rollback; rc=$?; set -e
    [[ ${rc} -ne 0 ]] || fail "concurrent rollback unexpectedly succeeded"
    [[ ${before} == "$(tree_digest "${RESTORE_TEST_ROOT}")" ]] || fail "concurrent rollback lost prior root"
    [[ -d ${RESTORE_TEST_ROOT}.displaced ]] || fail "concurrent rollback fixture was not exercised"
    rm -rf -- "${RESTORE_TEST_ROOT}.displaced"
    assert_no_restore_siblings
    echo '[PASS] case=concurrent-rollback conflict_preserved_prior_root'
    cleanup; ACTIVE_SANDBOX=
}

run_all() {
    run_round_trip encrypted
    run_round_trip plaintext
    run_round_trip missing-root
    for attack_class in traversal absolute symlink hardlink special duplicate normalized-duplicate file-dir-conflict symlink-prefix wrong-root; do
        run_malicious "${attack_class}"
    done
    run_preexisting_symlink
    run_concurrent_root
    run_concurrent_rollback
    run_activation_rollback
    run_readiness_timeout
    run_failure_case rollback-start-failure rollback-start-failure present
    run_lock_contention
    run_descriptor_rejection archive-symlink
    run_descriptor_rejection identity-symlink
    run_activation_interrupt
    run_restore_drill
}

case "${1:-}" in
    '') run_all ;;
    --round-trip)
        [[ $# -eq 2 && $2 =~ ^(encrypted|plaintext|missing-root)$ ]] || { usage; exit 2; }
        run_round_trip "$2"
        ;;
    --malicious)
        [[ $# -eq 2 ]] || { usage; exit 2; }
        run_malicious "$2"
        ;;
    --case)
        [[ $# -eq 2 ]] || { usage; exit 2; }
        case "$2" in
            preexisting-symlink) run_preexisting_symlink ;;
            concurrent-root) run_concurrent_root ;;
            concurrent-rollback) run_concurrent_rollback ;;
            activation-rollback) run_activation_rollback ;;
            readiness-timeout) run_readiness_timeout ;;
            rollback-start-failure) run_failure_case rollback-start-failure rollback-start-failure present ;;
            lock-contention) run_lock_contention ;;
            archive-symlink) run_descriptor_rejection archive-symlink ;;
            identity-symlink) run_descriptor_rejection identity-symlink ;;
            activation-interrupt) run_activation_interrupt ;;
            restore-drill) run_restore_drill ;;
            *) fail "unknown case $2" ;;
        esac
        ;;
    --self-test-malicious)
        [[ $# -eq 1 ]] || { usage; exit 2; }
        for attack_class in traversal absolute symlink hardlink special duplicate normalized-duplicate file-dir-conflict symlink-prefix wrong-root; do
            run_malicious "${attack_class}"
        done
        ;;
    *) usage; exit 2 ;;
esac
