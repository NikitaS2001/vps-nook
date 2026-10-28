#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
readonly VENV_DIR="${ROOT_DIR}/.venv"

usage() {
    cat <<EOF
Usage: ${0##*/} [--help]

Create ${VENV_DIR} and install the pinned development dependencies.

Options:
  -h, --help  Show this help and exit.
EOF
}

case "${1:-}" in
    '') ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

command -v python3 >/dev/null || {
    printf 'bootstrap: python3 is required\n' >&2
    exit 1
}

command -v strace >/dev/null || {
    printf 'bootstrap: strace is required for the native installer PTY tests\n' >&2
    exit 1
}
# Probe the actual syscall before creating or modifying development tooling.
python3 -c 'import os; descriptor = os.pidfd_open(os.getpid()); os.close(descriptor)'

python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/python" -m pip install --disable-pip-version-check \
    -r "${ROOT_DIR}/requirements-dev.txt"
"${VENV_DIR}/bin/ansible-galaxy" collection install \
    -r "${ROOT_DIR}/requirements.yml"

printf 'bootstrap: ready; run scripts/check.sh\n'
