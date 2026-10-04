#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROLE="${ROOT}/roles/vps_orchestration"

grep -q '^argument_specs:' "${ROLE}/meta/argument_specs.yml"
grep -q 'choices: \[services, full\]' "${ROLE}/meta/argument_specs.yml"
grep -q '^wg_traffic_mode: "services"$' "${ROLE}/defaults/main.yml"
grep -q 'wg_easy_admin_password is not defined' "${ROLE}/tasks/main.yml"
grep -q 'wg_easy_bootstrap_secret is defined' "${ROLE}/tasks/main.yml"

if grep -R -E '^[[:space:]]+(apt|apt_repository|assert|command|copy|debug|fail|fetch|file|find|get_url|include_tasks|meta|service|set_fact|shell|slurp|stat|systemd|tempfile|template|uri|user|wait_for):' \
    "${ROLE}/tasks" "${ROLE}/handlers"; then
    echo 'non-FQCN builtin module found' >&2
    exit 1
fi

grep -q -- '- NET_ADMIN' "${ROLE}/templates/docker-compose.yml.j2"
if grep -q -E 'SYS_MODULE|/lib/modules' "${ROLE}/templates/docker-compose.yml.j2"; then
    echo 'unnecessary kernel capability or module mount found' >&2
    exit 1
fi

[[ "$(grep -c "mode: '0700'" "${ROLE}/tasks/volumes.yml")" -eq 3 ]]
for boundary in compose_prepare.yml caddy_transaction.yml compose_lifecycle.yml; do
    grep -q "${boundary}" "${ROLE}/tasks/compose.yml"
done

grep -q 'netfilter_modules.yml' "${ROLE}/tasks/main.yml"
grep -q 'community.general.modprobe:' "${ROLE}/tasks/netfilter_modules.yml"
grep -q 'persistent: present' "${ROLE}/tasks/netfilter_modules.yml"
if grep -q 'linux-modules-extra' "${ROLE}/tasks/netfilter_modules.yml"; then
    echo 'kernel-package fallback would hide an unsupported host kernel' >&2
    exit 1
fi
for module in iptable_filter ip6table_filter iptable_nat ip6table_nat xt_MASQUERADE xt_comment xt_tcpudp; do
    grep -q "^[[:space:]]*- ${module}$" "${ROLE}/tasks/netfilter_modules.yml"
done

grep -q '^wg_amnezia_enabled: false$' "${ROLE}/defaults/main.yml"
grep -q 'modinfo' "${ROLE}/tasks/main.yml"
grep -q 'wg_amnezia_kernel_module' "${ROLE}/tasks/netfilter_modules.yml"
if grep -R -q -E 'dkms|kernel-mgmt|make -C' "${ROLE}/tasks"; then
  echo 'role must not build kernel modules' >&2
  exit 1
fi
grep -q 'OVERRIDE_AUTO_AWG' "${ROLE}/templates/docker-compose.yml.j2"
grep -q 'vps_orchestration_wg_executable' "${ROLE}/tasks/traffic_mode.yml"
grep -q 'vps_orchestration_wg_executable' "${ROLE}/tasks/verify.yml"
grep -q 'WG_EXEC' "${ROOT}/scripts/synthetic-check.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/orchestration-readiness.XXXXXX")"
cleanup() {
    find "${TMP}" -depth -delete
    [[ ! -e "${TMP}" ]]
    printf '[CLEANUP] readiness_fixture_removed=%s\n' "${TMP}"
}
trap cleanup EXIT
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${READINESS_LOG:?}"
case "${1:-}" in
    inspect)
        case "${3:-}" in
            *IPAddress*) printf '10.66.0.3\n' ;;
            *State.Status*) printf 'running\n' ;;
            *State.Health*) printf 'healthy\n' ;;
            *) exit 2 ;;
        esac
        ;;
    exec)
        [[ "${2:-}" == wg-easy ]] || exit 2
        # A successful empty generic query is deliberately NOT readiness.
        [[ "$*" != "exec wg-easy wg show" && "$*" != "exec wg-easy awg show" ]] || exit 0
        [[ "${3:-}" == "${READINESS_BACKEND:?}" && "${4:-}" == show && "${5:-}" == wg0 ]] || exit 1
        case "${READINESS_SCENARIO:?}" in
            missing) exit 1 ;;
            tool-failure) exit 70 ;;
            disappearing-readiness)
                count="$(grep -Fxc "exec wg-easy ${READINESS_BACKEND} show wg0" "${READINESS_LOG}")"
                [[ "${count}" -eq 1 ]] || exit 1
                ;;
            disappearing) [[ "${6:-}" != latest-handshakes ]] || exit 1 ;;
            blocked)
                printf 'READY\n' >"${READINESS_FIFO:?}"
                read -r _ <"${READINESS_GATE:?}"
                ;;
            ready) ;;
            *) exit 2 ;;
        esac
        ;;
    *) exit 2 ;;
esac
SH
cat >"${TMP}/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${*: -1}" in
    http://127.0.0.1:51821/api/session) printf '401' ;;
    https://wg.internal/|https://adguard.internal/) printf '200' ;;
    *) exit 2 ;;
esac
SH
chmod 0755 "${TMP}/bin/docker" "${TMP}/bin/curl"
export PATH="${TMP}/bin:${PATH}"
export READINESS_LOG="${TMP}/docker.log"

for READINESS_BACKEND in wg awg; do
    export READINESS_BACKEND
    for READINESS_SCENARIO in missing tool-failure disappearing-readiness disappearing ready; do
        export READINESS_SCENARIO
        : >"${READINESS_LOG}"
        code=0
        timeout 20 bash "${ROOT}/scripts/synthetic-check.sh" >"${TMP}/synthetic.log" 2>&1 || code=$?
        if [[ "${READINESS_SCENARIO}" == ready ]]; then
            [[ "${code}" == 0 ]]
            grep -Fq '[WARN]' "${TMP}/synthetic.log"
            grep -Fq '[PASS]' "${TMP}/synthetic.log"
            grep -Fxq "exec wg-easy ${READINESS_BACKEND} show wg0 latest-handshakes" "${READINESS_LOG}"
        else
            if [[ "${code}" != 1 ]]; then
                printf '[FAIL] synthetic backend=%s scenario=%s expected=1 actual=%s\n' \
                    "${READINESS_BACKEND}" "${READINESS_SCENARIO}" "${code}" >&2
                exit 1
            fi
            if grep -Fq '[PASS]' "${TMP}/synthetic.log"; then
                echo 'failed synthetic check emitted success' >&2
                exit 1
            fi
        fi
        if grep -Exq 'exec wg-easy (wg|awg) show' "${READINESS_LOG}"; then
            echo 'synthetic readiness used a generic interface query' >&2
            exit 1
        fi
        printf '[PASS] synthetic backend=%s scenario=%s exit=%s\n' \
            "${READINESS_BACKEND}" "${READINESS_SCENARIO}" "${code}"
    done
done

# Execute the owning verification task, with bounded retries, not a copy of
# its command. No CA fetch, network wait or provisioning tasks are invoked.
python3 - "${ROLE}/tasks/verify.yml" "${TMP}/verify.yml" <<'PY'
import sys
import yaml
with open(sys.argv[1]) as stream:
    tasks = yaml.safe_load(stream)
task, = [task for task in tasks if task.get("register") == "vps_orchestration_wg_show"]
task.update(retries=1, delay=0)
with open(sys.argv[2], "w") as stream:
    yaml.safe_dump([{"hosts": "localhost", "connection": "local", "gather_facts": False,
                     "tasks": [task]}], stream)
PY
for READINESS_BACKEND in wg awg; do
    export READINESS_BACKEND
    for READINESS_SCENARIO in missing tool-failure ready; do
        export READINESS_SCENARIO
        : >"${READINESS_LOG}"
        code=0
        timeout 30 ansible-playbook -i localhost, "${TMP}/verify.yml" \
            -e "vps_orchestration_wg_executable=${READINESS_BACKEND}" >"${TMP}/verify.log" 2>&1 || code=$?
        if [[ "${READINESS_SCENARIO}" == ready ]]; then
            [[ "${code}" == 0 ]]
        else
            if [[ "${code}" != 2 ]]; then
                printf '[FAIL] verify backend=%s scenario=%s expected=2 actual=%s\n' \
                    "${READINESS_BACKEND}" "${READINESS_SCENARIO}" "${code}" >&2
                exit 1
            fi
        fi
        grep -Fxq "exec wg-easy ${READINESS_BACKEND} show wg0" "${READINESS_LOG}"
        if grep -Exq 'exec wg-easy (wg|awg) show' "${READINESS_LOG}"; then
            echo 'verification used a generic interface query' >&2
            exit 1
        fi
        printf '[PASS] verify backend=%s scenario=%s exit=%s\n' \
            "${READINESS_BACKEND}" "${READINESS_SCENARIO}" "${code}"
    done
done

export READINESS_BACKEND=awg READINESS_SCENARIO=ready
: >"${READINESS_LOG}"
code=0
timeout 30 ansible-playbook -i localhost, "${TMP}/verify.yml" \
    -e vps_orchestration_wg_executable=wg >"${TMP}/wrong-tool.log" 2>&1 || code=$?
[[ "${code}" == 2 ]]
grep -Fxq 'exec wg-easy wg show wg0' "${READINESS_LOG}"
printf '[PASS] verify wrong-tool=wg_on_awg exit=%s\n' "${code}"

code=0
timeout 20 bash "${ROOT}/scripts/synthetic-check.sh" --bogus >"${TMP}/malformed.log" 2>&1 || code=$?
[[ "${code}" == 2 ]]
printf '[PASS] synthetic malformed-option exit=%s\n' "${code}"

# Subscribe before launching a blocked Docker probe. Interrupt its whole
# owned process group, reap it, and resume against the same clean fixture.
python3 - "${ROOT}/scripts/synthetic-check.sh" "${TMP}" <<'PY'
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys

root = Path(sys.argv[2])
ready, gate = root / "ready.fifo", root / "gate.fifo"
os.mkfifo(ready, 0o600)
os.mkfifo(gate, 0o600)
descriptor = os.open(ready, os.O_RDWR | os.O_NONBLOCK)
try:
    with selectors.DefaultSelector() as events:
        events.register(descriptor, selectors.EVENT_READ)
        for cycle in range(2):
            environment = dict(os.environ, READINESS_SCENARIO="blocked",
                               READINESS_FIFO=str(ready), READINESS_GATE=str(gate))
            with (root / "interrupt.log").open("wb") as output:
                process = subprocess.Popen(["bash", sys.argv[1]], env=environment,
                                           stdout=output, stderr=output, start_new_session=True)
                try:
                    assert events.select(timeout=10), "Docker probe did not signal readiness"
                    assert os.read(descriptor, 4096) == b"READY\n"
                    os.killpg(process.pid, signal.SIGTERM)
                    assert process.wait(timeout=10) == -signal.SIGTERM
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=10)
            environment["READINESS_SCENARIO"] = "ready"
            result = subprocess.run(["bash", sys.argv[1]], env=environment,
                                    capture_output=True, timeout=20, check=True)
            assert b"[PASS]" in result.stdout and b"[WARN]" in result.stdout
            print(f"[PASS] synthetic interruption={cycle + 1} exit=-15 resume=0")
finally:
    os.close(descriptor)
    ready.unlink()
    gate.unlink()
PY

printf '[PASS] argument_specs, FQCN, vault-only bootstrap, private volumes, host netfilter, minimal container capabilities, transaction boundaries\n'
