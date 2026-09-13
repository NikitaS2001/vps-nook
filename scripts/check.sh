#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
usage() {
    printf 'Usage: %s [--e2e|--release]\nRun quick checks; --e2e adds QEMU; --release adds QEMU, lifecycle and release contracts.\n' "${0##*/}"
}
[[ $# -le 1 ]] || { usage >&2; exit 2; }
mode=quick
case "${1:-}" in
    '') ;;
    --e2e) mode=e2e ;;
    --release) mode=release ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
if [[ -d ${ROOT_DIR}/.venv ]]; then
    export PATH="${ROOT_DIR}/.venv/bin:${PATH}"
fi
command -v pytest >/dev/null || { printf 'check: missing pytest; run scripts/bootstrap.sh\n' >&2; exit 1; }
cd "${ROOT_DIR}"
report_args=()
# Each stage has its own report; do not overwrite earlier failures.
run_stage() {
    local stage="$1" expression="$2"
    report_args=()
    if [[ -n ${NOOK_JUNIT_DIR:-} ]]; then
        mkdir -p -- "${NOOK_JUNIT_DIR}"
        report_args+=("--junitxml=${NOOK_JUNIT_DIR}/${stage}.xml")
    fi
    pytest -x -m "${expression}" "${report_args[@]}" </dev/null
}
run_stage quick quick
if [[ ${mode} != quick ]]; then
    run_stage qemu qemu
fi
if [[ ${mode} == release ]]; then
    run_stage lifecycle lifecycle
    run_stage release 'release and not quick'
fi
