#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROLE="${ROOT}/roles/vps_orchestration"

grep -q '^argument_specs:' "${ROLE}/meta/argument_specs.yml"
grep -q 'choices: \[services, full\]' "${ROLE}/meta/argument_specs.yml"
grep -q '^wg_traffic_mode: "services"$' "${ROLE}/defaults/main.yml"
grep -q 'wg_easy_admin_password is not defined' "${ROLE}/tasks/main.yml"
grep -q 'wg_easy_bootstrap_secret is defined' "${ROLE}/tasks/main.yml"

python3 - "${ROLE}" <<'MODULE_KEYS'
from pathlib import Path
import sys
import yaml

builtins = {'apt', 'apt_repository', 'assert', 'command', 'copy', 'debug', 'fail', 'fetch', 'file',
            'find', 'get_url', 'include_tasks', 'meta', 'service', 'set_fact', 'shell', 'slurp', 'stat',
            'systemd', 'tempfile', 'template', 'uri', 'user', 'wait_for'}

def check(tasks):
    for task in tasks:
        assert not builtins.intersection(task), 'non-FQCN builtin task module'
        for boundary in ('block', 'rescue', 'always'):
            if boundary in task:
                check(task[boundary])

for subtree in ('tasks', 'handlers'):
    for path in (Path(sys.argv[1]) / subtree).glob('*.yml'):
        check(yaml.safe_load(path.read_text()) or [])
MODULE_KEYS

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
grep -q 'awg_module.py preflight' "${ROLE}/tasks/main.yml"
grep -q 'amneziawg_prepare.yml' "${ROLE}/tasks/netfilter_modules.yml"
if grep -R -q -E 'make -C|git clone'  "${ROLE}/tasks"; then
  echo 'role must delegate compilation to the bounded pinned owner' >&2
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
# Execute the parsed transaction owners in Ansible. Only Docker, HTTP and the
# two templates are sandbox boundaries; control flow and persisted operations
# remain the owners' actual tasks.
python3 - "${ROLE}" "${TMP}" <<'PY'
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import yaml

role, private = map(Path, sys.argv[1:])
sandbox = private / "compose"
sandbox.mkdir(mode=0o700)
template = sandbox / "docker-compose.yml.j2"
template.write_text("services:\n  wg-easy:\n    environment:\n"
                    "{% if wg_easy_include_init %}      INIT_PASSWORD: fixture-secret\n{% endif %}"
                    "      SAFE: true\n")
(sandbox / "Caddyfile.j2").write_text("new-managed\n")
docker = sandbox / "docker"
docker.write_text("""#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  image) echo fixture-image ;;
  run)
    for ((index=1; index<=$#; index++)); do
      if [[ "${!index}" == --volume ]]; then
        index=$((index + 1))
        tree="${!index%%:/etc/caddy:ro}"
        [[ "$(cat "${tree}/Caddyfile.d/operator.conf")" == operator-extension ]]
        [[ "$(cat "${tree}/Caddyfile")" == new-managed ]]
      fi
    done
    [[ "${COMPOSE_FAULT}" != caddy-validate ]] || exit 62 ;;
  inspect)
    if [[ "$*" == *State.Running* ]]; then echo true
    elif [[ "$*" == *Config.Env* ]]; then
      [[ "${COMPOSE_FAULT}" != inspect-env ]] || exit 70
      cat "${COMPOSE_PROJECT}/runtime-env"
    else exit 2; fi ;;
  ps) [[ "${COMPOSE_FAULT}" != inspect ]] || exit 70; test ! -f "${COMPOSE_PROJECT}/runtime-env" || echo fixture-id ;;
  rm)
    [[ "${COMPOSE_FAULT}" != remove ]] || exit 71
    [[ -f "${COMPOSE_PROJECT}/runtime-env" ]] || exit 1
    rm "${COMPOSE_PROJECT}/runtime-env" ;;
  exec)
    [[ "${COMPOSE_FAULT}" != caddy-reload && "${COMPOSE_FAULT}" != caddy-rollback ]] || {
      if [[ ! -f "${COMPOSE_PROJECT}/reload-failed" ]]; then
        touch "${COMPOSE_PROJECT}/reload-failed"; exit 63
      fi
      [[ "${COMPOSE_FAULT}" != caddy-rollback ]] || exit 64
    } ;;
  compose)
    # The operator's override links wg-easy to Caddy. Credential cleanup
    # must target wg-easy without recreating either unrelated or linked UIs.
    if [[ "${2:-}" == always && ( "${3:-}" == all || ( "${3:-}" == wg-easy && "${4:-}" == true ) ) ]]; then
      printf 'recreated-caddy\n' >"${COMPOSE_PROJECT}/caddy-id"
    fi
    count=0
    [[ ! -f "${COMPOSE_PROJECT}/compose-count" ]] || count="$(<"${COMPOSE_PROJECT}/compose-count")"
    count=$((count + 1))
    echo "${count}" >"${COMPOSE_PROJECT}/compose-count"
    if [[ "${count}" == 1 && "${COMPOSE_FAULT}" == start ]]; then exit 61; fi
    if [[ "${count}" -gt 1 && ( "${COMPOSE_FAULT}" == recreate || "${COMPOSE_FAULT}" == resecure-start ) ]]; then exit 65; fi
    grep 'INIT_PASSWORD:' "${COMPOSE_PROJECT}/docker-compose.yml" \
      | sed 's/.*INIT_PASSWORD: /INIT_PASSWORD=/' >"${COMPOSE_PROJECT}/runtime-env" || [[ "$?" == 1 ]]
    ;;
  login)
    count=0
    [[ ! -f "${COMPOSE_PROJECT}/login-count" ]] || count="$(<"${COMPOSE_PROJECT}/login-count")"
    count=$((count + 1))
    echo "${count}" >"${COMPOSE_PROJECT}/login-count"
    case "${COMPOSE_FAULT}" in
      success|cleanup|resecure-start) ;;
      resecure-auth) [[ "${count}" == 1 ]] || exit 68 ;;
      *) exit 66 ;;
    esac ;;
  cleanup) exit 67 ;;
  *) exit 2 ;;
esac
""")
docker.chmod(0o700)

def adapt(tasks):
    for task in tasks:
        for section in ("block", "rescue", "always"):
            if section in task:
                adapt(task[section])
        if "ansible.builtin.template" in task:
            module = task["ansible.builtin.template"]
            module["src"] = str(sandbox / module["src"])
        if "community.docker.docker_compose_v2" in task:
            module = task.pop("community.docker.docker_compose_v2")
            task["ansible.builtin.command"] = {
                "argv": ["docker", "compose", module.get("recreate", "auto"),
                         *module.get("services", ["all"]), str(module.get("dependencies", True)).lower()]
            }
        if "ansible.builtin.uri" in task:
            del task["ansible.builtin.uri"]
            task["ansible.builtin.command"] = {"argv": ["docker", "login"]}
            for key in ("until", "retries", "delay"):
                task.pop(key, None)
        if "ansible.builtin.include_tasks" in task:
            task["ansible.builtin.include_tasks"] = str(sandbox / task["ansible.builtin.include_tasks"])

for name in ("compose.yml", "compose_prepare.yml", "compose_lifecycle.yml", "caddy_transaction.yml"):
    tasks = yaml.safe_load((role / "tasks" / name).read_text())
    adapt(tasks)
    (sandbox / name).write_text(yaml.safe_dump(tasks, sort_keys=False))

scenarios = ("start", "caddy-validate", "caddy-reload", "caddy-rollback",
             "bootstrap", "recreate", "remove", "inspect", "inspect-env",
             "scrub", "cleanup", "resecure-start", "resecure-auth",
             "success", "completed", "malformed")
for scenario in scenarios:
    project = sandbox / scenario
    (project / "volumes/wg-easy").mkdir(parents=True, mode=0o700)
    with sqlite3.connect(project / "volumes/wg-easy/wg-easy.db") as db:
        db.execute("CREATE TABLE general_table (setup_step INTEGER)")
        db.execute("INSERT INTO general_table VALUES (?)", (0 if scenario == "completed" else 1,))
        if scenario == "malformed":
            db.execute("ALTER TABLE general_table RENAME TO malformed_table")
    database = (project / "volumes/wg-easy/wg-easy.db").read_bytes()
    (project / "Caddyfile").write_text("old-managed\n")
    (project / "caddy-id").write_text("retained-caddy\n")
    inode = (project / "Caddyfile").stat().st_ino
    (project / "Caddyfile.d").mkdir()
    (project / "Caddyfile.d/operator.conf").write_text("operator-extension\n")
    (project / "docker-compose.override.yml").write_text("services:\n  wg-easy:\n    depends_on: [caddy]\n")
    override = (project / "docker-compose.override.yml").read_bytes()
    play = [{"hosts": "localhost", "connection": "local", "gather_facts": False,
             "vars": {"project_root": str(project), "caddy_version": "fixture",
                      "caddy_image_digest": "sha256:fixture", "wg_easy_admin_user": "fixture",
                      "wg_easy_bootstrap_secret": "fixture-secret", "wg_easy_bootstrap_ui_port": 51821},
             "tasks": [{"ansible.builtin.include_tasks": str(sandbox / "compose.yml")}]}]
    # A failed render is injected at its existing template boundary, after the
    # credential render, not by changing the owner transaction structure.
    if scenario in ("scrub", "cleanup"):
        lifecycle = yaml.safe_load((sandbox / "compose_lifecycle.yml").read_text())
        def break_scrub(tasks):
            for task in tasks:
                for section in ("block", "rescue", "always"):
                    if section in task:
                        break_scrub(task[section])
                if task.get("vars", {}).get("wg_easy_include_init") is False:
                    if scenario == "scrub":
                        task["ansible.builtin.template"]["src"] = str(sandbox / "missing-template")
                if scenario == "cleanup" and "ansible.builtin.find" in task:
                    del task["ansible.builtin.find"]
                    task["ansible.builtin.command"] = {"argv": ["docker", "cleanup"]}
        break_scrub(lifecycle)
        original = (sandbox / "compose_lifecycle.yml").read_text()
        (sandbox / "compose_lifecycle.yml").write_text(yaml.safe_dump(lifecycle, sort_keys=False))
        caller = yaml.safe_load((sandbox / "compose.yml").read_text())
        break_scrub(caller)
        caller_original = (sandbox / "compose.yml").read_text()
        (sandbox / "compose.yml").write_text(yaml.safe_dump(caller, sort_keys=False))
    playbook = sandbox / "play.yml"
    playbook.write_text(yaml.safe_dump(play, sort_keys=False))
    env = dict(os.environ, PATH=str(sandbox) + os.pathsep + os.environ["PATH"],
               COMPOSE_PROJECT=str(project), COMPOSE_FAULT=scenario)
    result = subprocess.run(["ansible-playbook", "-i", "localhost,", str(playbook)],
                            env=env, capture_output=True, timeout=90)
    if scenario in ("scrub", "cleanup"):
        (sandbox / "compose_lifecycle.yml").write_text(original)
        (sandbox / "compose.yml").write_text(caller_original)
    text = result.stdout.decode()
    compose = project / "docker-compose.yml"
    init = compose.exists() and "INIT_PASSWORD:" in compose.read_text()
    if scenario != "scrub":
        assert not init, f"compose scenario={scenario} exit={result.returncode} persisted_INIT=true"
    assert result.returncode == (0 if scenario in ("success", "completed") else 2), (scenario, result.returncode)
    assert "fixture-secret" not in text, f"{scenario}: no_log leaked fixture credentials"
    assert (project / "volumes/wg-easy/wg-easy.db").read_bytes() == database, scenario
    assert (project / "caddy-id").read_text() == "retained-caddy\n", f"{scenario}: credential scrub recreated Caddy"
    assert (project / "docker-compose.override.yml").read_bytes() == override, scenario
    if scenario.startswith("caddy"):
        assert (project / "Caddyfile").read_text() == "old-managed\n", scenario
        assert (project / "Caddyfile").stat().st_ino == inode, scenario
    assert not list(project.glob(".Caddyfile.candidate.*")), scenario
    assert not list(project.glob(".Caddyfile.previous.*")), scenario
    assert not list(project.glob(".caddy-validate.*")), scenario
    if scenario not in ("success", "completed", "malformed"):
        import re
        primary_codes = {"start": 61, "caddy-validate": 62, "caddy-reload": 63, "caddy-rollback": 63,
                         "bootstrap": 66, "recreate": 66, "remove": 66, "inspect": 66,
                         "inspect-env": 66, "scrub": 66, "cleanup": 67,
                         "resecure-start": 65, "resecure-auth": 68}
        codes = re.findall(r"\(rc=(\d+)\)", text)
        assert str(primary_codes[scenario]) in codes, (scenario, codes)
        cleanup_failed = scenario in ("remove", "inspect", "inspect-env", "recreate", "scrub", "resecure-start")
        actual_cleanup = re.findall(r"credential cleanup failed=(True|False)", text)
        assert str(cleanup_failed) in actual_cleanup, (scenario, "cleanup_failed", actual_cleanup)
        if scenario == "caddy-rollback":
            assert "64" in codes, (scenario, codes)
    if scenario == "scrub":
        assert compose.stat().st_mode & 0o777 == 0o600, scenario
        assert not (project / "runtime-env").exists(), scenario
    elif scenario not in ("inspect", "inspect-env", "malformed"):
        environment = project / "runtime-env"
        assert not environment.exists() or "INIT_PASSWORD=" not in environment.read_text(), scenario
    print(f"[PASS] compose-owner scenario={scenario} exit={result.returncode} "
          f"persisted_INIT={str(init).lower()} sqlite_unchanged=true primary_preserved=true")
PY
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
            many-recent|stale|never)
                if [[ "${6:-}" == latest-handshakes ]]; then
                    case "${READINESS_SCENARIO}" in
                        many-recent)
                            awk -v count="${READINESS_PEER_COUNT:?}" \
                                -v recent="${READINESS_RECENT:?}" -v old="${READINESS_OLD:?}" \
                                'BEGIN { for (i = 1; i <= count; i++) print "peer-" i, (i == int(count / 2) ? recent : old) }'
                            ;;
                        stale)
                            printf 'peer-a %s\npeer-b %s\npeer-c %s\n' \
                                "$((READINESS_OLD - 2))" "${READINESS_OLD}" "$((READINESS_OLD - 1))"
                            ;;
                        never) printf 'peer-a 0\npeer-b 0\n' ;;
                    esac
                fi
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
cat >"${TMP}/bin/date" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && "$1" == +%s ]] || exit 2
printf '%s\n' "${READINESS_NOW:?}"
SH
chmod 0755 "${TMP}/bin/docker" "${TMP}/bin/curl" "${TMP}/bin/date"
export PATH="${TMP}/bin:${PATH}"
export READINESS_LOG="${TMP}/docker.log"
export READINESS_NOW=2000000000 READINESS_PEER_COUNT=100000
READINESS_RECENT_AGE=30
READINESS_STALE_AGE=7200
export READINESS_RECENT="$((READINESS_NOW - READINESS_RECENT_AGE))"
export READINESS_OLD="$((READINESS_NOW - READINESS_STALE_AGE))"

for READINESS_BACKEND in wg awg; do
    export READINESS_BACKEND
    for READINESS_SCENARIO in missing tool-failure disappearing-readiness disappearing ready many-recent stale never; do
        export READINESS_SCENARIO
        : >"${READINESS_LOG}"
        code=0
        timeout 20 bash "${ROOT}/scripts/synthetic-check.sh" >"${TMP}/synthetic.log" 2>&1 || code=$?
        if [[ "${READINESS_SCENARIO}" == ready || "${READINESS_SCENARIO}" == many-recent \
            || "${READINESS_SCENARIO}" == stale || "${READINESS_SCENARIO}" == never ]]; then
            if [[ "${code}" != 0 ]]; then
                printf '[FAIL] synthetic backend=%s scenario=%s expected=0 actual=%s\n' \
                    "${READINESS_BACKEND}" "${READINESS_SCENARIO}" "${code}" >&2
                exit 1
            fi
            if [[ "${READINESS_SCENARIO}" == many-recent ]]; then
                grep -Fq '[OK] recent WireGuard handshake (<= 1h)' "${TMP}/synthetic.log"
                if grep -Fq '[WARN]' "${TMP}/synthetic.log"; then
                    echo 'recent synthetic handshake emitted a warning' >&2
                    exit 1
                fi
            else
                grep -Fq '[WARN]' "${TMP}/synthetic.log"
            fi
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
