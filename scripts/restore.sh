#!/usr/bin/env bash
# Restore a backup produced by scripts/backup.sh. Run on the VPS as root.
set -euo pipefail
umask 077

for legacy_name in "${!ZERO_TRUST_@}"; do
    [[ -n ${legacy_name} ]] || continue
    printf '[FAIL] %s is no longer accepted; use NOOK_%s (value not shown).\n' \
        "${legacy_name}" "${legacy_name#ZERO_TRUST_}" >&2
    exit 1
done


usage() {
    cat <<'EOF'
Usage: restore.sh <backup.tar.gz|backup.tar.gz.age> [age-identity.txt]

Validate and stage a vps-nook backup, then activate it atomically. An
age identity is required when the archive is encrypted.
EOF
}

if [[ ${1:-} == --help ]]; then
    usage
    exit 0
fi
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

PROJECT_ROOT="${NOOK_PROJECT_ROOT:-/opt/vps-nook}"
BACKUP="$1"
AGE_KEY="${2:-${NOOK_AGE_KEY:-}}"
PARENT_INPUT="$(dirname -- "${PROJECT_ROOT}")"
BASE="$(basename -- "${PROJECT_ROOT}")"
PARENT="$(realpath -e -- "${PARENT_INPUT}")" \
    || { echo "[FAIL] project parent does not exist" >&2; exit 1; }
[[ "${PROJECT_ROOT}" == "${PARENT}/${BASE}" ]] \
    || { echo "[FAIL] project root must use its canonical parent" >&2; exit 1; }
command -v python3 >/dev/null || { echo "[FAIL] python3 is required" >&2; exit 1; }
command -v flock >/dev/null || { echo "[FAIL] flock is required" >&2; exit 1; }

exec {LOCK_FD}>"${PARENT}/.nook-restore.lock"
flock -n "${LOCK_FD}" || { echo "[FAIL] another restore is active" >&2; exit 1; }
[[ ! -L "${PROJECT_ROOT}" ]] \
    || { echo "[FAIL] project root must not be a symlink" >&2; exit 1; }
if [[ -d "${PROJECT_ROOT}" ]]; then
    ROOT_PRESENT_AT_START=1
    ROOT_ID_AT_START="$(stat -c '%d:%i' -- "${PROJECT_ROOT}")"
elif [[ -e "${PROJECT_ROOT}" || -L "${PROJECT_ROOT}" ]]; then
    echo "[FAIL] project root must be an absent path or a real directory" >&2
    exit 1
else
    ROOT_PRESENT_AT_START=0
    ROOT_ID_AT_START=
fi

STAGING="$(mktemp -d "${PARENT}/.nook-restore.stage.XXXXXX")"
STAGING_ID="$(stat -c '%d:%i' -- "${STAGING}")"
ROLLBACK="$(mktemp -d "${PARENT}/.nook-restore.rollback.XXXXXX")"
FAILED="$(mktemp -d "${PARENT}/.nook-restore.failed.XXXXXX")"
rmdir -- "${ROLLBACK}" "${FAILED}"
ROLLBACK_ID=
FAILED_ID=
ARCHIVE_TMP="$(mktemp "${PARENT}/.nook-restore.archive.XXXXXX")"
chmod 0600 "${ARCHIVE_TMP}"

parent_device="$(stat -c %d -- "${PARENT}")"
[[ "$(stat -c %d -- "${STAGING}")" == "${parent_device}" ]] \
    || { echo "[FAIL] staging is not on the project filesystem" >&2; exit 1; }

activated=0
activation_pending=0
had_prior=0
failed_owned=0
prior_restored=0
rollback_restart_failed=0

guarded_remove() {
    local path="$1" name expected_id
    name="$(basename -- "${path}")"
    case "${name}" in
        .nook-restore.stage.*) expected_id="${STAGING_ID}" ;;
        .nook-restore.rollback.*) expected_id="${ROLLBACK_ID}" ;;
        .nook-restore.failed.*) expected_id="${FAILED_ID}" ;;
        *) return 1 ;;
    esac
    [[ ! -e ${path} && ! -L ${path} ]] && return 0
    [[ -n ${expected_id} && "$(dirname -- "${path}")" == "${PARENT}" \
        && -d "${path}" && ! -L "${path}" \
        && "$(stat -c '%d:%i' -- "${path}")" == "${expected_id}" \
        && "$(stat -c %d -- "${path}")" == "${parent_device}" ]] || return 1
    rm -rf -- "${path}"
}

rename_noreplace() {
    local helper_timeout="${NOOK_RENAME_TIMEOUT:-10}"
    [[ ${helper_timeout} =~ ^[1-9][0-9]*$ ]] \
        || { echo "[FAIL] rename helper timeout must be a positive integer" >&2; return 1; }
    timeout "${helper_timeout}" python3 - "${PARENT}" "$1" "$2" <<'PY'
import ctypes
import errno
import os
import stat
import sys

parent, source, destination = sys.argv[1:]
if "/" in source or "/" in destination or source in ("", ".", "..") or destination in ("", ".", ".."):
    raise SystemExit("unsafe rename name")
flags = os.O_RDONLY | os.O_DIRECTORY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
parent_fd = os.open(parent, flags)
try:
    if not stat.S_ISDIR(os.fstat(parent_fd).st_mode):
        raise SystemExit("parent is not a directory")
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise SystemExit("renameat2 is unavailable")
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    if renameat2(parent_fd, os.fsencode(source), parent_fd, os.fsencode(destination), 1) != 0:
        error = ctypes.get_errno()
        if error in (errno.ENOSYS, errno.EINVAL):
            raise SystemExit("RENAME_NOREPLACE is unsupported")
        raise OSError(error, os.strerror(error), destination)
finally:
    os.close(parent_fd)
PY
}

rollback_disk() {
    if [[ -e "${PROJECT_ROOT}" || -L "${PROJECT_ROOT}" ]]; then
        [[ ! -L "${PROJECT_ROOT}" ]] || return 1
        rename_noreplace "${BASE}" "$(basename -- "${FAILED}")" || return 1
        failed_owned=1
        FAILED_ID="$(stat -c '%d:%i' -- "${FAILED}")"
    fi
    if [[ ${had_prior} -eq 1 ]]; then
        [[ -d "${ROLLBACK}" && ! -L "${ROLLBACK}" ]] || return 1
        rename_noreplace "$(basename -- "${ROLLBACK}")" "${BASE}" || return 1
        had_prior=0
        prior_restored=1
    fi
    activated=0
    activation_pending=0
}

cleanup() {
    local rc=$? rollback_needed=0 rollback_succeeded=0
    trap - EXIT HUP INT TERM
    if [[ ${activation_pending} -eq 1 || ${activated} -eq 1 || ${had_prior} -eq 1 ]]; then
        rollback_needed=1
        if rollback_disk; then
            rollback_succeeded=1
        else
            echo "[FAIL] automatic disk rollback failed; preserved rollback state at ${ROLLBACK}" >&2
        fi
    fi
    if [[ ${prior_restored} -eq 1 && ${rollback_restart_failed} -eq 0 ]]; then
        compose_args
        if docker compose "${COMPOSE_ARGS[@]}" up -d; then
            prior_restored=0
        else
            rollback_restart_failed=1
            echo "[FAIL] rollback restored disk state but the prior stack failed to restart" >&2
        fi
    fi
    guarded_remove "${STAGING}" \
        || echo "[FAIL] preserved unvalidated staging path: ${STAGING}" >&2
    if [[ ${failed_owned} -eq 1 && ${rollback_restart_failed} -eq 0 \
        && ${prior_restored} -eq 0 && (${rollback_needed} -eq 0 || ${rollback_succeeded} -eq 1) ]]; then
        if guarded_remove "${FAILED}"; then
            failed_owned=0
        else
            echo "[FAIL] preserved unvalidated failed path: ${FAILED}" >&2
        fi
    fi
    if [[ ${had_prior} -eq 0 ]]; then
        guarded_remove "${ROLLBACK}" \
            || echo "[FAIL] preserved unvalidated rollback path: ${ROLLBACK}" >&2
    fi
    rm -f -- "${ARCHIVE_TMP}"
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

materialize_archive() {
    python3 - "${BACKUP}" "${AGE_KEY}" "${ARCHIVE_TMP}" <<'PY'
import os
import shutil
import stat
import subprocess
import sys

archive_path, identity_path, output_path = sys.argv[1:]
flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
archive_fd = os.open(archive_path, flags)
identity_fd = None
try:
    if not stat.S_ISREG(os.fstat(archive_fd).st_mode):
        raise SystemExit("backup is not a regular file")
    magic = os.read(archive_fd, 18)
    os.lseek(archive_fd, 0, os.SEEK_SET)
    if magic.startswith(b"age-encryption.org"):
        if not identity_path:
            raise SystemExit("encrypted backup requires an age identity file")
        age = shutil.which("age")
        if age is None:
            raise SystemExit("'age' is not installed")
        identity_fd = os.open(identity_path, flags)
        if not stat.S_ISREG(os.fstat(identity_fd).st_mode):
            raise SystemExit("age identity is not a regular file")
        output_fd = os.open(output_path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
        try:
            result = subprocess.run(
                [age, "-d", "-i", f"/proc/self/fd/{identity_fd}",
                 f"/proc/self/fd/{archive_fd}"],
                pass_fds=(archive_fd, identity_fd), stdout=output_fd, check=False,
            )
        finally:
            os.close(output_fd)
        if result.returncode != 0:
            raise SystemExit("age decryption failed")
    else:
        with open(output_path, "wb", opener=lambda _path, _flags: os.open(
            output_path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW
        )) as destination:
            with os.fdopen(os.dup(archive_fd), "rb") as source:
                shutil.copyfileobj(source, destination)
finally:
    if identity_fd is not None:
        os.close(identity_fd)
    os.close(archive_fd)
if not stat.S_ISREG(os.stat(output_path, follow_symlinks=False).st_mode) or os.path.getsize(output_path) == 0:
    raise SystemExit("materialized archive is empty or invalid")
os.chmod(output_path, 0o600, follow_symlinks=False)
PY
}

validate_and_extract() {
    python3 - "${ARCHIVE_TMP}" "${STAGING}" "${BASE}" <<'PY'
import os
import posixpath
import stat
import sys
import tarfile

archive_path, staging, expected_root = sys.argv[1:]
flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
archive_fd = os.open(archive_path, flags)
try:
    if not stat.S_ISREG(os.fstat(archive_fd).st_mode):
        raise SystemExit("archive is not a regular file")
    with os.fdopen(os.dup(archive_fd), "rb") as archive_file:
        with tarfile.open(fileobj=archive_file, mode="r:gz") as archive:
            members = archive.getmembers()
            raw_names = set()
            normalized = {}
            kinds = {}
            for member in members:
                raw = member.name
                if not raw or raw.startswith("/"):
                    raise SystemExit("absolute or empty archive member")
                if raw in raw_names:
                    raise SystemExit("duplicate raw archive member")
                raw_names.add(raw)
                parts = raw.split("/")
                if any(part == ".." for part in parts):
                    raise SystemExit("traversal archive member")
                name = posixpath.normpath(raw)
                if name in ("", ".", "..") or name.startswith("../"):
                    raise SystemExit("traversal archive member")
                if name in normalized:
                    raise SystemExit("normalized duplicate archive member")
                normalized[name] = raw
                path_parts = name.split("/")
                if path_parts[0] != expected_root:
                    raise SystemExit("archive has the wrong project root")
                if member.issym() or member.islnk():
                    raise SystemExit("archive links are forbidden")
                if not (member.isdir() or member.isreg()):
                    raise SystemExit("archive special members are forbidden")
                kinds[name] = "dir" if member.isdir() else "file"
            if not members:
                raise SystemExit("archive is empty")
            for name, kind in kinds.items():
                components = name.split("/")
                for end in range(1, len(components)):
                    prefix = "/".join(components[:end])
                    if kinds.get(prefix) == "file":
                        raise SystemExit("archive file-directory conflict")
            for member in members:
                name = posixpath.normpath(member.name)
                relative = name[len(expected_root):].lstrip("/")
                if not relative:
                    if not member.isdir():
                        raise SystemExit("project root member is not a directory")
                    continue
                destination = os.path.join(staging, *relative.split("/"))
                if member.isdir():
                    os.makedirs(destination, mode=member.mode & 0o777, exist_ok=True)
                    continue
                os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    raise SystemExit("regular member has no data")
                file_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                if hasattr(os, "O_NOFOLLOW"):
                    file_flags |= os.O_NOFOLLOW
                output_fd = os.open(destination, file_flags, member.mode & 0o777)
                try:
                    with os.fdopen(output_fd, "wb", closefd=False) as output:
                        while True:
                            block = source.read(1024 * 1024)
                            if not block:
                                break
                            output.write(block)
                finally:
                    os.close(output_fd)
finally:
    os.close(archive_fd)
PY
}

compose_args() {
    COMPOSE_ARGS=(-f "${PROJECT_ROOT}/docker-compose.yml")
    if [[ -f "${PROJECT_ROOT}/docker-compose.override.yml" ]]; then
        COMPOSE_ARGS+=(-f "${PROJECT_ROOT}/docker-compose.override.yml")
    fi
}

wait_for_readiness() {
    local timeout_seconds="${NOOK_RESTORE_READY_TIMEOUT:-120}"
    local interval_seconds="${NOOK_RESTORE_READY_INTERVAL:-2}"
    local expected running deadline
    [[ ${timeout_seconds} =~ ^[1-9][0-9]*$ ]] \
        || { echo "[FAIL] readiness timeout must be a positive integer" >&2; return 1; }
    [[ ${interval_seconds} =~ ^[0-9]+([.][0-9]+)?$ ]] \
        || { echo "[FAIL] readiness interval must be nonnegative" >&2; return 1; }
    expected="$(docker compose "${COMPOSE_ARGS[@]}" config --services | LC_ALL=C sort -u)"
    [[ -n ${expected} ]] || { echo "[FAIL] restored Compose project has no services" >&2; return 1; }
    deadline=$((SECONDS + timeout_seconds))
    while ((SECONDS <= deadline)); do
        running="$(docker compose "${COMPOSE_ARGS[@]}" ps --status running --services | LC_ALL=C sort -u)"
        [[ ${running} == "${expected}" ]] && return 0
        ((SECONDS >= deadline)) && break
        sleep "${interval_seconds}"
    done
    echo "[FAIL] restored services did not become ready before timeout" >&2
    return 1
}

echo "[1/4] Validating and staging the backup..."
materialize_archive
validate_and_extract

echo "[2/4] Stopping the current stack..."
if [[ ${ROOT_PRESENT_AT_START} -eq 1 ]]; then
    [[ -d "${PROJECT_ROOT}" && ! -L "${PROJECT_ROOT}" \
        && "$(stat -c '%d:%i' -- "${PROJECT_ROOT}")" == "${ROOT_ID_AT_START}" ]] \
        || { echo "[FAIL] project root changed while restore was staging" >&2; exit 1; }
    compose_args
    docker compose "${COMPOSE_ARGS[@]}" stop
    rename_noreplace "${BASE}" "$(basename -- "${ROLLBACK}")"
    had_prior=1
    ROLLBACK_ID="$(stat -c '%d:%i' -- "${ROLLBACK}")"
elif [[ -e "${PROJECT_ROOT}" || -L "${PROJECT_ROOT}" ]]; then
    activation_pending=1
    echo "[FAIL] project root appeared while restore was staging" >&2
    exit 1
fi

echo "[3/4] Activating the staged restore..."
activation_pending=1
rename_noreplace "$(basename -- "${STAGING}")" "${BASE}"
activation_pending=0
activated=1
compose_args
if ! docker compose "${COMPOSE_ARGS[@]}" config -q \
    || ! docker compose "${COMPOSE_ARGS[@]}" up -d \
    || ! wait_for_readiness; then
    echo "[FAIL] restored stack failed to start; rolling back" >&2
    if rollback_disk; then
        if [[ ${prior_restored} -eq 1 ]]; then
            compose_args
            if ! docker compose "${COMPOSE_ARGS[@]}" up -d; then
                rollback_restart_failed=1
                echo "[FAIL] rollback restored disk state but the prior stack failed to restart" >&2
                exit 1
            fi
            prior_restored=0
        fi
        if [[ ${failed_owned} -eq 1 ]]; then
            if guarded_remove "${FAILED}"; then
                failed_owned=0
            else
                echo "[FAIL] preserved unvalidated failed path: ${FAILED}" >&2
                exit 1
            fi
        fi
    else
        echo "[FAIL] automatic disk rollback failed; preserved rollback state at ${ROLLBACK}" >&2
        exit 1
    fi
    exit 1
fi

activated=0
had_prior=0
guarded_remove "${ROLLBACK}" \
    || { echo "[FAIL] rollback path identity changed; refusing deletion" >&2; exit 1; }
rm -f -- "${ARCHIVE_TMP}"
echo "[4/4] Finished."
echo "[OK] Restored from ${BACKUP}. Re-run the playbook and synthetic checks."
