#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly ROOT_DIR
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qemu-source-contract.XXXXXX")"
readonly TMP_DIR
trap 'find "${TMP_DIR}" -depth -delete' EXIT

git -C "${TMP_DIR}" init -q -b main
printf 'kept\n' >"${TMP_DIR}/kept"
printf 'deleted\n' >"${TMP_DIR}/deleted"
git -C "${TMP_DIR}" add kept deleted
git -C "${TMP_DIR}" -c user.name=test -c user.email=test.invalid -c commit.gpgsign=false \
    commit -qm fixture
find "${TMP_DIR}/deleted" -delete
printf 'untracked\n' >"${TMP_DIR}/untracked"
mkdir -p "${TMP_DIR}/examples/vaultwarden"
printf 'recipe\n' >"${TMP_DIR}/examples/vaultwarden/README.md"
printf 'recipe\n' >"${TMP_DIR}/examples/vaultwarden/compose.override.yml"
printf 'recipe\n' >"${TMP_DIR}/examples/vaultwarden/Caddyfile.conf"
printf '#!/usr/bin/env bash\n' >"${TMP_DIR}/examples/vaultwarden/manage.sh"
chmod 0755 "${TMP_DIR}/examples/vaultwarden/manage.sh"

mapfile -d '' -t paths < <(
    "${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-source-list "${TMP_DIR}"
)
printf '%s\n' "${paths[@]}" | sort >"${TMP_DIR}/actual"
printf '%s\n' \
    examples/vaultwarden/Caddyfile.conf \
    examples/vaultwarden/README.md \
    examples/vaultwarden/compose.override.yml \
    examples/vaultwarden/manage.sh \
    kept \
    untracked | sort >"${TMP_DIR}/expected"
cmp "${TMP_DIR}/expected" "${TMP_DIR}/actual" || {
    printf 'qemu-source-contract: source list included a deletion or lost an existing path\n' >&2
    exit 1
}

# Later edits must not change either the deployed tree or its client checks.
"${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-source-snapshot "${TMP_DIR}" "${TMP_DIR}/snapshot"
printf 'changed after snapshot\n' >"${TMP_DIR}/kept"
[[ $(<"${TMP_DIR}/snapshot/kept") == kept && -f ${TMP_DIR}/snapshot/untracked && ! -e ${TMP_DIR}/snapshot/deleted ]] || {
    printf 'qemu-source-contract: snapshot is not isolated from later working-tree changes\n' >&2
    exit 1
}
# Literal source contracts, not shell expansion.
# shellcheck disable=SC2016
grep -Fq 'tar -C "${SOURCE_DIR}" -czf - .' "${ROOT_DIR}/tests/e2e/qemu-install.sh"
# shellcheck disable=SC2016
grep -Fq '< "${SOURCE_DIR}/tests/e2e/client-in-guest.sh"' "${ROOT_DIR}/tests/e2e/qemu-install.sh"

fresh_env="$("${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-installer-env fresh)"
for credential in \
    NOOK_ADMIN_PASSWORD \
    NOOK_ADGUARD_PASSWORD \
    NOOK_WG_PASSWORD \
    NOOK_SSH_PUBKEY; do
    [[ ${fresh_env} == *"${credential}="* ]] \
        || { printf 'qemu-source-contract: fresh install omitted %s\n' "${credential}" >&2; exit 1; }
done

# Wrong backend and missing exact interface must propagate, even when generic
# `wg show` would succeed with no interfaces.
for backend in wg awg; do
    (
        source "${ROOT_DIR}/tests/e2e/common.sh"
        run_remote() {
            case "$4" in
                'echo ssh-ok') ;;
                'sudo ufw status verbose') echo 'Status: active' ;;
                'sudo ufw status') printf '2222/tcp\n51820/udp\n' ;;
                *'docker inspect --format'*) printf '/wg-easy running none\n/adguard running healthy\n/caddy running healthy\n' ;;
                "sudo docker exec wg-easy ${backend} show wg0") return 43 ;;
                *'docker exec wg-easy'*) return 0 ;;
                *'51821/api/session'*) echo 401 ;;
                *'3000/control/status'*) echo 200 ;;
                *'docker ps'*) ;;
                *INIT_PASSWORD*) echo CLEAN ;;
                *) return 44 ;;
            esac
        }
        NOOK_VPN_BACKEND="${backend}" verify_deployment fixture 22 fixture
    ) >"${TMP_DIR}/backend-check" 2>&1 && {
        echo 'qemu-source-contract: missing selected wg0 accepted' >&2
        exit 1
    }
done
bash -c "env ${fresh_env} sh -c '\
    test \"\$NOOK_ADMIN_PASSWORD\" = \"admin'\''secret\" && \
    test \"\$NOOK_ADGUARD_PASSWORD\" = \"adguard secret\" && \
    test \"\$NOOK_WG_PASSWORD\" = '\''wg\$secret'\'' && \
    test \"\$NOOK_SSH_PUBKEY\" = \"ssh-ed25519 AAAA fixture\"'" || {
    printf 'qemu-source-contract: fresh credential environment did not round-trip\n' >&2
    exit 1
}
existing_env="$("${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-installer-env existing)"
[[ -z ${existing_env} ]] || {
    printf 'qemu-source-contract: existing-state rerun exposed credential inputs\n' >&2
    exit 1
}

# Execute the real installer command builder without SSH or provisioning.
bash -se -- "${ROOT_DIR}" "${TMP_DIR}" <<'DISPATCH_CASES'
set -euo pipefail
ROOT_DIR="$1" TMP_DIR="$2"
for backend in wg awg; do
    (
        source "${ROOT_DIR}/tests/e2e/common.sh"
        source <(awk '/^build_installer_credential_env\(\)/,/^}/; /^run_repository_installer\(\)/,/^}/; /^run_guest_client\(\)/,/^}/' \
            "${ROOT_DIR}/tests/e2e/qemu-install.sh")
        run_remote() { printf '%s\n' "$4" >"${TMP_DIR}/dispatch"; echo 'NON-PRODUCTION DEVELOPMENT MODE'; }
        export ADMIN_PASS=fixture ADGUARD_PASS=fixture WG_PASS=fixture PUBKEY=fixture
        export E2E_SOURCE_MODE=development INSTALL_REF=fixture E2E_SSH_PORT=2222 E2E_WG_PORT=51820
        export WG_TRAFFIC_MODE=services INTERNAL_DOMAIN_SUFFIX=internal
        NOOK_VPN_BACKEND="${backend}" run_repository_installer fixture 22 fixture fresh >/dev/null
        run_remote_stdin() { cat >/dev/null; printf '%s\n' "$4" >"${TMP_DIR}/client-dispatch"; }
        SOURCE_DIR="${ROOT_DIR}" CLIENT_GUEST_STATE=/var/lib/private-client
        CLIENT_EXTENSION_READY=false QEMU_ADMIN_PORT=2222
        NOOK_VPN_BACKEND="${backend}" run_guest_client check
    )
    python3 - "${TMP_DIR}/dispatch" "${backend}" <<'PY'
from pathlib import Path
import shlex
import sys

words = shlex.split(Path(sys.argv[1]).read_text())
fields = dict(word.split("=", 1) for word in words if "=" in word)
assert fields.get("NOOK_VPN_BACKEND") == sys.argv[2], "installer backend forwarding"
client_words = shlex.split(Path(sys.argv[1]).with_name("client-dispatch").read_text())
client_fields = dict(word.split("=", 1) for word in client_words if "=" in word)
assert client_fields["NOOK_VPN_BACKEND"] == sys.argv[2]
assert client_fields["CLIENT_ACTION"] == "check"
assert client_fields["CLIENT_STATE"] == "/var/lib/private-client"
PY
done

python3 - "${ROOT_DIR}" "${TMP_DIR}" <<'PYLIFECYCLE'
from pathlib import Path
import subprocess
import sys
import tempfile

root, private = map(Path, sys.argv[1:])
source = (root / "tests/e2e/qemu-install.sh").read_text()
prepare_start = source.index('if [[ "${DO_CLIENT_TEST}" == true ]]; then')
prepare = source[prepare_start:source.index("\nfi", prepare_start) + 3]
reboot_start = source.index('if [[ "${DO_REBOOT}" == "true" ]]; then')
rerun_start = source.index('if [[ "${DO_IDEMPOTENCY}" == "true" ]]; then')
reboot = source[reboot_start:rerun_start]
rerun = source[rerun_start:source.index("    caddy_managed_hash_before=", rerun_start)] + "\nfi\n"
adapters = r'''
set -euo pipefail
TMP_DIR="$1"
NOOK_VPN_BACKEND="$2" SETUP_FAILURE="$3"
DO_CLIENT_TEST=true DO_REBOOT=true DO_IDEMPOTENCY=true DO_VAULTWARDEN=false
QEMU_ADMIN_PORT=2222 WG_TRAFFIC_MODE=services
phase=initial
run_guest_client() {
    printf 'client:%s\n' "$1" >>"${TMP_DIR}/sequence"
    case "$1" in
        prepare) peer=retained; checked=initial ;;
        check) [[ "${peer:-}" == retained ]]; checked="${phase}" ;;
        cleanup) peer=deleted ;;
        *) exit 42 ;;
    esac
}
reboot_and_await_guest() {
    [[ "${peer:-}" == retained && "${checked:-}" == initial ]]
    printf 'reboot\n' >>"${TMP_DIR}/sequence"
    phase=reboot
}
run_repository_installer() {
    [[ "${peer:-}" == retained && "${checked:-}" == reboot ]]
    printf 'rerun\n' >>"${TMP_DIR}/sequence"
    phase=rerun
}
sudo() { [[ "$1" == apt-get ]]; "$@"; }
apt-get() {
    printf 'apt:%s\n' "$*" >>"${TMP_DIR}/sequence"
    [[ "$1" != "${SETUP_FAILURE}" ]] || return 42
}
export TMP_DIR SETUP_FAILURE
export -f sudo apt-get
run_remote() {
    case "$4" in
        'sudo apt-get '*) bash -c "$4" ;;
        *) [[ "${phase}" != initial ]] || return 43; echo same-container ;;
    esac
}
verify_deployment() { :; }
verify_traffic_mode() { :; }
install_reload_audit() { :; }
remote_caddy_admin_hash() { echo same-config; }
copy_repo_to_guest() { :; }
verify_task_skipped() { :; }
remote_reload_count() { echo 0; }
verify_wg_login() { :; }
verify_bootstrap_secret_free() { :; }
'''
# Rerun is piped through tee in the owner; its phase is therefore observed
# through a private event file rather than a subshell-local variable.
adapters = adapters.replace("phase=rerun", 'printf rerun >"${TMP_DIR}/boundary"')
adapters = adapters.replace('checked="${phase}"', 'checked="${phase}"; [[ ! -f "${TMP_DIR}/boundary" ]] || checked="$(<"${TMP_DIR}/boundary")"')
program = "\n".join((adapters, prepare, reboot, rerun, '[[ "${peer}" == retained && "${checked}" == rerun ]]'))
for backend, failure in (("wg", ""), ("awg", ""), ("wg", "update"), ("wg", "install")):
    with tempfile.TemporaryDirectory(dir=private) as directory:
        result = subprocess.run(["bash", "-c", program, "lifecycle-contract", directory, backend, failure],
                                capture_output=True, timeout=10)
        sequence = (Path(directory) / "sequence").read_text().splitlines()
        packages = ["wireguard-tools", "jq", "openssl", "dnsutils", "resolvconf"]
        setup = ["apt:update -qq", "apt:install -y -qq " + " ".join(packages)]
        lifecycle = ["client:prepare", "client:check", "reboot", "client:check", "client:check", "rerun", "client:check"]
        if failure:
            assert result.returncode == 42, (failure, result.returncode)
            assert sequence == setup[:1 if failure == "update" else 2], "setup failure reached peer creation"
        else:
            assert result.returncode == 0, "peer must precede and survive actual reboot/rerun call sites"
            assert sequence == (setup if backend == "wg" else []) + lifecycle, \
                ("WG tools must be prepared before peer creation; AWG must remain externally prepared", backend, sequence)
        print(f"client-preparation: backend={backend} failure={failure or 'none'} exit={result.returncode}")
print("retained-lifecycle: actual preparation/reboot/rerun ordering passed")
PYLIFECYCLE
DISPATCH_CASES
vaultwarden_check="$("${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-vaultwarden-command check)"
[[ "${vaultwarden_check}" == "sudo /opt/vps-nook-installer/repo/examples/vaultwarden/manage.sh check --project-root /opt/vps-nook" ]] || {
    printf 'qemu-source-contract: Vaultwarden check command is not installer-managed and safely quoted\n' >&2
    exit 1
}
vaultwarden_resume="$("${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-vaultwarden-command install --resume)"
[[ "${vaultwarden_resume}" == "sudo /opt/vps-nook-installer/repo/examples/vaultwarden/manage.sh install --resume --project-root /opt/vps-nook" ]] || {
    printf 'qemu-source-contract: Vaultwarden resume command is not installer-managed and safely quoted\n' >&2
    exit 1
}
grep -Fq 'ipv4_address: 10.66.0.5' \
    "${ROOT_DIR}/examples/vaultwarden/compose.override.yml" || {
    printf 'qemu-source-contract: Vaultwarden must reserve a non-core VPN address\n' >&2
    exit 1
}
[[ "$(grep -c 'id_ed25519" existing' "${ROOT_DIR}/tests/e2e/qemu-install.sh")" -eq 4 ]] || {
    printf 'qemu-source-contract: retry paths are not explicitly existing-state reruns\n' >&2
    exit 1
}
grep -Fq "'sudo cat /opt/vps-nook/.wg-traffic-mode'" \
    "${ROOT_DIR}/tests/e2e/common.sh" || {
    printf 'qemu-source-contract: traffic mode must be read with privilege\n' >&2
    exit 1
}
grep -Fq "sh -c 'cd /opt/vps-nook-installer/repo" \
    "${ROOT_DIR}/tests/e2e/qemu-install.sh" || {
    printf 'qemu-source-contract: root-only installer checkout must be entered with privilege\n' >&2
    exit 1
}
grep -Fq -- '--extra-vars @/etc/vps-nook/installer-vault.yml' \
    "${ROOT_DIR}/tests/e2e/qemu-install.sh" || {
    printf 'qemu-source-contract: direct playbook runs must load encrypted installer state\n' >&2
    exit 1
}
grep -Fq 'if ! sudo test -s /etc/vps-nook/installer-vault.yml; then' \
    "${ROOT_DIR}/tests/e2e/run-public-install.sh" || {
    printf 'qemu-source-contract: public VPS reruns must omit fresh credential inputs\n' >&2
    exit 1
}
# These assertions intentionally match literal command substitutions in the harness.
# shellcheck disable=SC2016
if grep -Fq '\$(stat -c %a /etc/vps-nook)' \
    "${ROOT_DIR}/tests/e2e/run-public-install.sh"; then
    printf 'qemu-source-contract: private installer state must be inspected through sudo\n' >&2
    exit 1
fi
# shellcheck disable=SC2016
grep -Fq '\$(sudo stat -c %a /etc/vps-nook)' \
    "${ROOT_DIR}/tests/e2e/run-public-install.sh" || {
    printf 'qemu-source-contract: installer state directory mode check is missing\n' >&2
    exit 1
}
# shellcheck disable=SC2016
grep -Fq 'command -v nc >/dev/null || fail "nc not found"' \
    "${ROOT_DIR}/tests/e2e/run-public-install.sh" || {
    printf 'qemu-source-contract: public port probe prerequisite is not enforced\n' >&2
    exit 1
}
# shellcheck disable=SC2016
grep -Fq 'if timeout 6 nc -z -w 5 "${VPS_IP}" 443' \
    "${ROOT_DIR}/tests/e2e/run-public-install.sh" || {
    printf 'qemu-source-contract: public port probe must have an outer timeout\n' >&2
    exit 1
}
installer_release_ref="$(sed -n 's/^readonly OFFICIAL_RELEASE_REF="\([^"]*\)"$/\1/p' \
    "${ROOT_DIR}/install.sh")"
# Fixture intentionally matches the literal command substitution in the E2E source.
# shellcheck disable=SC2016
grep -Fq 'INSTALLER_RELEASE_REF="$(sed -n' "${ROOT_DIR}/tests/e2e/qemu-install.sh" \
    || { printf 'qemu-source-contract: production release assertion is not installer-derived\n' >&2; exit 1; }
# shellcheck disable=SC2016
grep -Fq 'Verified signed release tag ${INSTALLER_RELEASE_REF' \
    "${ROOT_DIR}/tests/e2e/qemu-install.sh" \
    || { printf 'qemu-source-contract: production provenance does not use installer release ref %s\n' \
        "${installer_release_ref}" >&2; exit 1; }
grep -Fq '"fd42:42:42::5/128"' \
    "${ROOT_DIR}/tests/e2e/external-client-qemu.sh" || {
    printf 'qemu-source-contract: external peer fixture must provide valid dual-stack addresses\n' >&2
    exit 1
}

QEMU_SOURCE_ROOT="${ROOT_DIR}" python3 - <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from tests.installer.pty_fixture import create_ux

root = Path(os.environ["QEMU_SOURCE_ROOT"])
harness = (root / "tests/e2e/qemu-install.sh").read_text()
copy_owner = re.search(r"^copy_repo_to_guest\(\) \{\n.*?^\}", harness, re.M | re.S).group()
caller = re.search(r'^copy_repo_to_guest "\$\{GUEST\}".*?(?=^if \[\[)', harness, re.M | re.S).group()

with tempfile.TemporaryDirectory(prefix="pty-prerequisites-") as directory:
    private = Path(directory)
    for scenario, expected in (("install", 0), ("update-failure", 41), ("install-failure", 42),
                               ("missing-after-install", 1), ("already-present", 0)):
        case = private / scenario
        binaries = case / "bin"
        binaries.mkdir(parents=True, mode=0o700)
        source = case / "source"
        source.mkdir()
        (source / "fixture").touch()
        for name in ("bash", "cat", "awk", "git", "tar", "gzip", "python3"):
            (binaries / name).symlink_to(shutil.which(name))
        if scenario == "already-present":
            (binaries / "strace").symlink_to(shutil.which("strace"))
        sudo = binaries / "sudo"
        sudo.write_text(f"#!{sys.executable}\nimport os, sys\nos.execvp(sys.argv[1], sys.argv[1:])\n")
        sudo.chmod(0o700)
        apt = binaries / "apt-get"
        apt.write_text(f'''#!{sys.executable}
import json, os, pathlib, sys
with open(os.environ["PACKAGE_LOG"], "a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\\n")
scenario = os.environ["SCENARIO"]
if sys.argv[1] == "update" and scenario == "update-failure":
    sys.exit(41)
if sys.argv[1] == "install":
    assert set(sys.argv[2:]) == {{"-y", "-qq", "git", "strace"}}
    if scenario == "install-failure":
        sys.exit(42)
    if scenario != "missing-after-install":
        pathlib.Path(os.environ["PATH"], "strace").symlink_to({shutil.which("strace")!r})
''')
        apt.chmod(0o700)
        script = '''
set -euo pipefail
run_remote() {
    case "$4" in
        *tests.e2e.installer_sudo*)
            command -v strace >/dev/null
            printf 'fixture\\n' >>"${FIXTURE_LOG}"
            ;;
        *) bash -c "$4" ;;
    esac
}
run_remote_stdin() {
    cat >/dev/null
    printf 'copied\\n' >>"${COPY_LOG}"
}
''' + copy_owner + "\n" + caller
        environment = {**os.environ, "PATH": str(binaries), "SCENARIO": scenario,
                       "PACKAGE_LOG": str(case / "packages"), "FIXTURE_LOG": str(case / "fixture-called"),
                       "COPY_LOG": str(case / "copied"), "SOURCE_DIR": str(source),
                       "TMP_DIR": str(case), "INSTALL_REF": "fixture", "GUEST": "fixture",
                       "QEMU_SSH_PORT": "2223"}
        result = subprocess.run([str(binaries / "bash"), "-c", script], env=environment,
                                capture_output=True, timeout=15)
        assert result.returncode == expected, (scenario, result.returncode)
        assert (case / "fixture-called").exists() == (expected == 0), scenario
        assert (case / "copied").exists() == (expected == 0), scenario
        if scenario == "already-present":
            assert not (case / "packages").exists()
        if expected == 0:
            fixture = case / "pty"
            fixture.mkdir(mode=0o700)
            ux = create_ux(root, fixture, case / "private-pty.log")
            _, trace = ux.run_case("prepared PATH", ux.base + [("Install, edit, or cancel", "i\n")],
                                   env_extra={"PATH": str(binaries)})
            fields = ux.backend_trace(trace)
            assert "applied" in trace and fields.backend == "wg" and fields.amnezia is False
        print(f"pty-prerequisites: guest-setup={scenario} exit={result.returncode} fixture={expected == 0}")

    for scenario, expected in (("missing-strace", 1), ("pidfd-failure", 39)):
        case = private / scenario
        scripts = case / "scripts"
        scripts.mkdir(parents=True)
        entry = scripts / "bootstrap.sh"
        entry.write_bytes((root / "scripts/bootstrap.sh").read_bytes())
        binaries = case / "bin"
        binaries.mkdir(mode=0o700)
        for name in ("bash", "dirname"):
            (binaries / name).symlink_to(shutil.which(name))
        if scenario == "pidfd-failure":
            (binaries / "strace").symlink_to(shutil.which("strace"))
        python = binaries / "python3"
        python.write_text(f'''#!{sys.executable}
import json, os, sys
with open(os.environ["PYTHON_LOG"], "w") as stream:
    json.dump(sys.argv[1:], stream)
sys.exit(39)
''')
        python.chmod(0o700)
        result = subprocess.run([str(binaries / "bash"), str(entry)],
                                env={**os.environ, "PATH": str(binaries), "PYTHON_LOG": str(case / "python")},
                                capture_output=True, timeout=10)
        assert result.returncode == expected, (scenario, result.returncode)
        assert not (case / ".venv").exists()
        if scenario == "missing-strace":
            assert not (case / "python").exists()
        else:
            assert json.loads((case / "python").read_text())[0] == "-c"
        print(f"pty-prerequisites: bootstrap={scenario} exit={result.returncode} venv=False")
print("pty-prerequisites: setup-cases=7 actual-PTY-cases=2 owned-state-removed")
PY

printf 'qemu-source-contract: source filter and credential-free rerun PASS\n'

# The real health owner must subscribe before triggering and fail on EOF.
bash -se -- "${ROOT_DIR}" "${TMP_DIR}" <<'HEALTH_CASES'
    set -euo pipefail
    ROOT_DIR="$1" TMP_DIR="$2"
    source "${ROOT_DIR}/tests/e2e/common.sh"
    curl() {
        printf 'subscribed\n' >"${TMP_DIR}/subscribed"
        printf 'HTTP/1.1 200 OK\r\n\r\n{"Type":"container","Action":"stop"}\n'
        IFS= read -r event <"${TMP_DIR}/events"
        printf '%s\n' "${event}"
    }
    docker() {
        [[ "$1" == inspect ]] || return 2
        printf '[{"Name":"/wg-easy","State":{"Running":true}},'
        printf '{"Name":"/adguard","State":{"Running":true,"Health":{"Status":"%s"}}},' "${HEALTH_STATUS}"
        printf '{"Name":"/caddy","State":{"Running":true,"Health":{"Status":"healthy"}}}]\n'
    }
    trigger() {
        [[ -f "${TMP_DIR}/subscribed" ]] || return 3
        printf '{"Action":"health_status: healthy"}\n' >"${TMP_DIR}/events"
    }
    mkfifo "${TMP_DIR}/events"
    export -f trigger
    HEALTH_STATUS=healthy await_container_health trigger
    if (HEALTH_STATUS=unhealthy await_container_health trigger); then
        echo 'qemu-source-contract: unhealthy EOF accepted' >&2
        exit 1
    fi
HEALTH_CASES

# Drive the actual reboot owner and its real inotify observer with a private
# serial file. Adapters replace only SSH and guest writes, never the observer.
bash -se -- "${ROOT_DIR}" "${TMP_DIR}" <<'BOOT_CASES'
set -euo pipefail
ROOT_DIR="$1" BASE="$2"
source "${ROOT_DIR}/tests/e2e/common.sh"
source <(awk '/^reboot_and_await_guest\(\)/,/^}/' "${ROOT_DIR}/tests/e2e/qemu-install.sh")
for scenario in ready stale-boot wrong-ssh-boot; do
    TMP_DIR="${BASE}/${scenario}"
    mkdir "${TMP_DIR}"
    : >"${TMP_DIR}/serial.log"
    QEMU_ADMIN_PORT=2222
    openssl() { printf '0123456789abcdef0123456789abcdef\n'; }
    run_remote_stdin() { cat >"${TMP_DIR}/guest-setup"; }
    run_remote() {
        case "$4" in
            'sudo systemctl reboot')
                boot=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
                [[ "${scenario}" != stale-boot ]] || boot=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
                touch "${TMP_DIR}/rebooted"
                printf '\nNOOK_READY 0123456789abcdef0123456789abcdef %s\n' "${boot}" >>"${TMP_DIR}/serial.log"
                ;;
            'cat /proc/sys/kernel/random/boot_id')
                if [[ ! -f "${TMP_DIR}/rebooted" || "${scenario}" == wrong-ssh-boot ]]; then
                    echo aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
                else
                    echo bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
                fi
                ;;
            *) return 42 ;;
        esac
    }
    set +e
    (set -e; reboot_and_await_guest) >"${TMP_DIR}/result" 2>&1
    status=$?
    set -e
    if [[ "${scenario}" == ready ]]; then
        [[ "${status}" == 0 ]]
    else
        [[ "${status}" != 0 ]]
    fi
    echo "reboot-owner: ${scenario} exit=${status}"
done
BOOT_CASES

for invalid in bogus 'awg;exit 0'; do
    if NOOK_VPN_BACKEND="${invalid}" "${ROOT_DIR}/tests/e2e/qemu-install.sh" \
        --self-test-installer-env fresh >"${TMP_DIR}/invalid" 2>&1; then
        echo 'qemu-source-contract: malformed backend accepted' >&2
        exit 1
    fi
done
