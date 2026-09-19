#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly ROOT_DIR

TMP_DIR=""

fail() {
    printf '[FAIL] examples-contract: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local status=$?
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf -- "${TMP_DIR}"
    fi
    return "${status}"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

assert_present() {
    local path="$1"
    [[ -f "${path}" ]] || fail "required recipe path is missing: ${path#"${ROOT_DIR}"/}"
}

assert_absent() {
    local path="$1"
    [[ ! -e "${path}" && ! -L "${path}" ]] || fail "obsolete flat recipe path remains: ${path#"${ROOT_DIR}"/}"
}

assert_absent "${ROOT_DIR}/examples/vaultwarden-compose.override.yml"
assert_absent "${ROOT_DIR}/examples/vaultwarden.caddy.conf"
assert_present "${ROOT_DIR}/examples/README.md"
for recipe in "${ROOT_DIR}"/examples/*/; do
    [[ -d "${recipe}" ]] || continue
    for file in README.md compose.override.yml Caddyfile.conf manage.sh; do
        assert_present "${recipe}${file}"
    done
    [[ -x "${recipe}manage.sh" ]] || fail "recipe manage.sh must be executable: ${recipe}"
done

command -v docker >/dev/null 2>&1 || fail 'docker is required'
docker info >/dev/null 2>&1 || fail 'a reachable Docker daemon is required'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose is required'
command -v python3 >/dev/null 2>&1 || fail 'python3 is required'

CADDY_IMAGE="$(CADDY_DEFAULTS="${ROOT_DIR}/roles/vps_orchestration/defaults/main.yml" python3 - <<'PY'
import os
import re
from pathlib import Path

import yaml

path = Path(os.environ["CADDY_DEFAULTS"])
try:
    defaults = yaml.safe_load(path.read_text(encoding="utf-8"))
except (OSError, yaml.YAMLError) as error:
    raise SystemExit(f"cannot parse Caddy defaults: {error}")

if not isinstance(defaults, dict):
    raise SystemExit("Caddy defaults must be a mapping")
version = defaults.get("caddy_version")
digest = defaults.get("caddy_image_digest")
if not isinstance(version, str) or not version:
    raise SystemExit("caddy_version must be a non-empty string")
if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
    raise SystemExit("caddy_image_digest must be a SHA-256 digest")
print(f"caddy:{version}@{digest}")
PY
)"
readonly CADDY_IMAGE

if ! docker image inspect "${CADDY_IMAGE}" >/dev/null 2>&1; then
    docker pull "${CADDY_IMAGE}" >/dev/null \
        || fail "the production-pinned Caddy image is required: ${CADDY_IMAGE}"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/examples-contract.XXXXXX")"
chmod 700 "${TMP_DIR}"
PROJECT_DIR="${TMP_DIR}/project"
CADDY_DIR="${TMP_DIR}/caddy"
COMPOSE_FILE="${PROJECT_DIR}/compose.yml"
CONFIG_JSON="${TMP_DIR}/compose.json"
mkdir -p "${PROJECT_DIR}/volumes/vaultwarden" "${CADDY_DIR}/Caddyfile.d"
chmod 700 "${PROJECT_DIR}" "${PROJECT_DIR}/volumes" \
    "${PROJECT_DIR}/volumes/vaultwarden" "${CADDY_DIR}" "${CADDY_DIR}/Caddyfile.d"

cat >"${COMPOSE_FILE}" <<'YAML'
---
services: {}
networks:
  vpn_net: {}
YAML

cp -- "${ROOT_DIR}/examples/vaultwarden/Caddyfile.conf" \
    "${CADDY_DIR}/Caddyfile.d/vaultwarden.conf"
cat >"${CADDY_DIR}/Caddyfile" <<'CADDYFILE'
import Caddyfile.d/*.conf
CADDYFILE
chmod 600 "${COMPOSE_FILE}" "${CADDY_DIR}/Caddyfile" \
    "${CADDY_DIR}/Caddyfile.d/vaultwarden.conf"

docker compose --project-directory "${PROJECT_DIR}" \
    -f "${COMPOSE_FILE}" \
    -f "${ROOT_DIR}/examples/vaultwarden/compose.override.yml" \
    config --format json >"${CONFIG_JSON}"
chmod 600 "${CONFIG_JSON}"

PROJECT_DIR="${PROJECT_DIR}" CONFIG_JSON="${CONFIG_JSON}" python3 - <<'PY'
import json
import os
from pathlib import Path

config_path = Path(os.environ["CONFIG_JSON"])
project_dir = Path(os.environ["PROJECT_DIR"]).resolve()
try:
    config = json.loads(config_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"cannot parse Compose model: {error}")

services = config.get("services")
if not isinstance(services, dict) or set(services) != {"vaultwarden"}:
    raise SystemExit("Compose model must contain only the vaultwarden service")
service = services["vaultwarden"]
if not isinstance(service, dict):
    raise SystemExit("vaultwarden service must be a mapping")

expected_image = (
    "vaultwarden/server:1.37.1@"
    "sha256:ebdfe70701c60ac0c28c697e787cea767d7972940b786037b29fe0d507f821e8"
)
if service.get("image") != expected_image:
    raise SystemExit("vaultwarden image must use the reviewed tag and digest")
if service.get("container_name") != "vaultwarden":
    raise SystemExit("vaultwarden container name must remain vaultwarden")
if service.get("restart") != "unless-stopped":
    raise SystemExit("vaultwarden restart policy must be unless-stopped")

networks = service.get("networks")
if not isinstance(networks, dict) or set(networks) != {"vpn_net"}:
    raise SystemExit("vaultwarden must attach only to vpn_net")

volumes = service.get("volumes")
if not isinstance(volumes, list) or len(volumes) != 1:
    raise SystemExit("vaultwarden must have exactly one persistent bind mount")
mount = volumes[0]
if not isinstance(mount, dict):
    raise SystemExit("vaultwarden persistent mount must use long syntax after rendering")
expected_source = project_dir / "volumes/vaultwarden"
if mount.get("type") != "bind" or mount.get("target") != "/data":
    raise SystemExit("vaultwarden persistent mount must bind to /data")
source = mount.get("source")
if not isinstance(source, str) or not Path(source).is_absolute() or Path(source).resolve() != expected_source:
    raise SystemExit("vaultwarden bind source must resolve from the temporary base project")

environment = service.get("environment")
if not isinstance(environment, dict):
    raise SystemExit("vaultwarden environment must be a mapping")
if environment.get("DOMAIN") != "https://vw.internal":
    raise SystemExit("vaultwarden DOMAIN must be https://vw.internal")
if environment.get("SIGNUPS_ALLOWED") != "false":
    raise SystemExit("vaultwarden registrations must be closed by default")
for name in environment:
    normalized_name = name.upper()
    if (
        normalized_name == "ADMIN_TOKEN"
        or ("SMTP" in normalized_name and "PASS" in normalized_name)
        or (
            ("DATABASE" in normalized_name or normalized_name.startswith("DB_"))
            and ("PASS" in normalized_name or "URL" in normalized_name)
        )
    ):
        raise SystemExit(f"vaultwarden environment must not include credential key: {name}")

if service.get("ports", []) != []:
    raise SystemExit("vaultwarden must not publish host ports")
if "healthcheck" in service:
    raise SystemExit("vaultwarden must retain the upstream healthcheck without an override")
PY

docker run --rm --network none \
    --volume "${CADDY_DIR}:/etc/caddy:ro" \
    "${CADDY_IMAGE}" \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

printf '[PASS] examples-contract: Vaultwarden recipe renders safely and Caddy accepts its imported fragment\n'

# Real Compose parses every model; only daemon mutations and runtime inspection
# are faked. The private fixture's id stub never changes host privileges.
env ROOT_DIR="${ROOT_DIR}" FIXTURE="${TMP_DIR}/manage" REAL_DOCKER="$(command -v docker)" python3 - <<'PY'
import copy
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import stat
import subprocess
import time

root = Path(os.environ["FIXTURE"])
root.mkdir(mode=0o700)
bin_dir = root / "bin"
bin_dir.mkdir(mode=0o700)
temps = root / "tmp"
temps.mkdir(mode=0o700)
recipe = Path(os.environ["ROOT_DIR"]) / "examples/vaultwarden"
manager = recipe / "manage.sh"
env = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"], TMPDIR=str(temps))
env.pop("NOOK_PROJECT_ROOT", None)
env.pop("BASH_ENV", None)

docker_stub = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

args = sys.argv[1:]
root = Path(os.environ["FIXTURE"])
if args[0] == "compose":
    if args[1] == "version" or "config" in args:
        os.execv(os.environ["REAL_DOCKER"], [os.environ["REAL_DOCKER"], *args])
    if "ps" in args:
        print("fixture-vaultwarden")
        sys.exit(0)
    assert args[-3:] == ["up", "-d", "vaultwarden"], args
    model = json.loads(subprocess.check_output(
        [os.environ["REAL_DOCKER"], *args[:-3], "config", "--format", "json"]))
    with (root / "mutations").open("a") as stream:
        stream.write(json.dumps({"argv": args, "model": model}) + "\n")
    signup = model["services"]["vaultwarden"]["environment"]["SIGNUPS_ALLOWED"]
    previous = json.loads((root / "runtime").read_text()) if (root / "runtime").exists() else []
    was_open = previous and previous[0]["Config"]["Env"] == ["SIGNUPS_ALLOWED=true"]
    if os.environ.get("START_FAIL") or (
        os.environ.get("CLOSE_FAIL") and signup == "false" and was_open
    ):
        sys.exit(1)
    unhealthy = os.environ.get("UNHEALTHY") or (os.environ.get("OPEN_UNHEALTHY") and signup == "true")
    runtime = [{
        "Config": {"Image": model["services"]["vaultwarden"]["image"], "Env": ["SIGNUPS_ALLOWED=" + signup]},
        "State": {"Running": True, "Health": {"Status": "unhealthy" if unhealthy else "healthy"}},
        "HostConfig": {"PortBindings": {}},
        "NetworkSettings": {"Ports": {"80/tcp": None}},
    }]
    (root / "runtime").write_text(json.dumps(runtime))
elif args[0] == "inspect":
    print((root / "runtime").read_text())
else:
    raise SystemExit("Unexpected Docker invocation")
'''
for name, content in {
    "docker": docker_stub,
    "id": '#!/bin/sh\nprintf "%s\\n" "${FIXTURE_UID:-0}"\n',
    "sleep": '#!/bin/sh\nprintf "%s\\n" "$1" >> "$FIXTURE/sleeps"\n',
}.items():
    path = bin_dir / name
    path.write_text(content)
    path.chmod(0o700)


def project(name):
    path = root / name
    path.mkdir()
    (path / "docker-compose.yml").write_text("---\nservices: {}\nnetworks:\n  vpn_net: {}\n")
    return path


def mutations():
    path = root / "mutations"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def snapshot(path):
    return {
        str(p.relative_to(path)): (p.lstat().st_mode, os.readlink(p) if p.is_symlink()
                                  else p.read_bytes() if p.is_file() else None)
        for p in path.rglob("*")
    }


def invoke(path, *args, code=0, extra=None, executable=manager, add_root=True):
    argv = [str(executable), *args]
    if add_root:
        argv += ["--project-root", str(path)]
    result = subprocess.run(argv, env=env | (extra or {}), text=True, capture_output=True, timeout=40)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    assert not list(temps.iterdir()), "Private rendering files survived command exit"
    return result


def no_change(path, *args, code=1, **kwargs):
    before, calls = snapshot(path), mutations()
    result = invoke(path, *args, code=code, **kwargs)
    assert snapshot(path) == before and mutations() == calls, args
    return result


clean = project("clean")
for args in (("--help",), ("check", "--help")):
    result = invoke(clean, *args, add_root=False, extra={"FIXTURE_UID": "1000"})
    assert "Usage:" in result.stdout
for args in (
    (), ("unknown",), ("check", "--unknown"), ("check", ""),
    ("check", "--project-root"), ("check", "--domain-suffix"),
    ("check", "--domain-suffix", "--resume"), ("check", "--resume"),
    ("verify", "--domain-suffix", "internal"), ("install", "--close"),
    ("install", "--timeout", "60"), ("install", "--resume", "--resume"),
    ("check", "--project-root", str(clean), "--project-root", str(clean)),
    ("check", "--domain-suffix", "internal", "--domain-suffix", "internal"),
    ("bootstrap", "--timeout", "59"), ("bootstrap", "--timeout", "3601"),
    ("bootstrap", "--timeout", "x"), ("bootstrap", "--close", "--timeout", "60"),
):
    result = no_change(clean, *args, code=2, add_root=False)
    assert "Usage:" in result.stderr and "[FAIL]" in result.stderr
for command in ("check", "install", "bootstrap", "verify"):
    no_change(clean, command, extra={"FIXTURE_UID": "1000"})

# Observe the actual default passed to path validation without reading /opt.
python = shutil.which("python3")
probe = bin_dir / "python3"
probe.write_text('#!/bin/sh\nif [ "$2" = paths ]; then\n'
                 '  printf "%s" "$3" > "$FIXTURE/default-root"\n  exit 1\nfi\n'
                 f'exec "{python}" "$@"\n')
probe.chmod(0o700)
invoke(clean, "check", code=1, add_root=False)
assert (root / "default-root").read_text() == "/opt/vps-nook"
probe.unlink()
no_change(clean, "check", code=0, extra={"NOOK_PROJECT_ROOT": "/wrong-environment-root"})
invoke(clean, "check", add_root=False, extra={"NOOK_PROJECT_ROOT": str(clean)})
for suffix in ("", "Upper", "a..b", "-bad", "bad-", "local", "home.local", "a b", "a\nb", "a" * 64,
               ".".join(["a" * 63] * 4)):
    no_change(clean, "check", "--domain-suffix", suffix, code=2 if not suffix else 1)
for path in ("/", "//tmp", "relative", str(clean) + "/../clean", str(clean) + "/", str(clean) + "\n"):
    no_change(clean, "check", "--project-root", path, add_root=False)

result = no_change(clean, "check", code=0)
assert "[OK]" in result.stdout
result = invoke(clean, "install")
assert len(mutations()) == 1 and mutations()[0]["argv"][-3:] == ["up", "-d", "vaultwarden"]
assert "version-pinned installer" in result.stdout and "controller playbook" in result.stdout
assert (clean / "docker-compose.override.yml").read_bytes() == (recipe / "compose.override.yml").read_bytes()
assert (clean / "Caddyfile.d/vaultwarden.conf").read_bytes() == (recipe / "Caddyfile.conf").read_bytes()
for file in ("docker-compose.override.yml", "Caddyfile.d/vaultwarden.conf"):
    assert stat.S_IMODE((clean / file).stat().st_mode) == 0o644
installed = snapshot(clean)
invoke(clean, "install", "--resume")
assert snapshot(clean) == installed
no_change(clean, "check")
no_change(clean, "install")

merged = project("merged")
override = merged / "docker-compose.override.yml"
override.write_text("---\nservices:\n  unrelated:\n    image: busybox:1.37\nx-owner: preserve-me\n")
original = override.read_bytes()
for command in ("check", "install"):
    result = no_change(merged, command, "--domain-suffix", "home.arpa", code=3)
fragment = result.stdout.split("----- BEGIN VAULTWARDEN COMPOSE FRAGMENT -----\n")[1].split(
    "----- END VAULTWARDEN COMPOSE FRAGMENT -----")[0]
assert "vw.home.arpa" in fragment and "vw.internal" not in fragment
assert "single services:" in result.stdout and "--resume" in result.stdout and "home.arpa" in result.stdout
override.write_text(original.decode().replace("x-owner:", fragment.split("services:\n", 1)[1] + "x-owner:"))
merged_bytes = override.read_bytes()
invoke(merged, "install", "--resume", "--domain-suffix", "home.arpa")
assert override.read_bytes() == merged_bytes
model = mutations()[-1]["model"]
assert model["x-owner"] == "preserve-me" and model["services"]["unrelated"]["image"] == "busybox:1.37"
assert "vw.home.arpa" in (merged / "Caddyfile.d/vaultwarden.conf").read_text()
assert "vw.internal" not in (merged / "Caddyfile.d/vaultwarden.conf").read_text()
invoke(merged, "verify")
invoke(merged, "install", "--resume", "--domain-suffix", "home.arpa")
assert override.read_bytes() == merged_bytes
no_change(merged, "install", "--resume")  # Same suffix is mandatory.

for collision in ("override-link", "override-dir", "caddy-link", "caddy-dir", "caddy-mismatch",
                  "caddy-parent-link", "caddy-parent-file", "volume-link", "volume-file",
                  "volumes-link", "volumes-file", "base-link", "base-dir", "invalid-compose"):
    target = project(collision)
    if collision.startswith("override"):
        path = target / "docker-compose.override.yml"
        path.symlink_to(root / "missing") if collision.endswith("link") else path.mkdir()
    elif collision in ("caddy-link", "caddy-dir", "caddy-mismatch"):
        (target / "Caddyfile.d").mkdir()
        path = target / "Caddyfile.d/vaultwarden.conf"
        if collision.endswith("link"): path.symlink_to(recipe / "Caddyfile.conf")
        elif collision.endswith("dir"): path.mkdir()
        else: path.write_text("operator-owned\n")
    elif collision.startswith("caddy-parent"):
        path = target / "Caddyfile.d"
        path.symlink_to(root, target_is_directory=True) if collision.endswith("link") else path.write_text("file")
    elif collision.startswith("volumes"):
        path = target / "volumes"
        path.symlink_to(root, target_is_directory=True) if collision.endswith("link") else path.write_text("file")
    elif collision.startswith("volume"):
        (target / "volumes").mkdir()
        path = target / "volumes/vaultwarden"
        path.symlink_to(root, target_is_directory=True) if collision.endswith("link") else path.write_text("file")
    elif collision.startswith("base"):
        path = target / "docker-compose.yml"
        path.unlink()
        path.symlink_to(clean / "docker-compose.yml") if collision.endswith("link") else path.mkdir()
    else:
        (target / "docker-compose.override.yml").write_text("services: [invalid\n")
    for command in ("check", "install"):
        no_change(target, command)
link = root / "project-link"
link.symlink_to(clean, target_is_directory=True)
no_change(clean, "check", "--project-root", str(link), add_root=False)
for source_fault in ("symlink", "missing-hostname"):
    copied = root / ("recipe-" + source_fault)
    shutil.copytree(recipe, copied)
    fragment_path = copied / "Caddyfile.conf"
    if source_fault == "symlink":
        fragment_path.unlink()
        fragment_path.symlink_to(recipe / "Caddyfile.conf")
    else:
        fragment_path.write_text("other.internal {}\n")
    no_change(project("source-" + source_fault), "install", executable=copied / "manage.sh")

# Simulate another operator publishing after preflight but before our link.
race = project("publication-race")
calls = mutations()
probe.write_text('#!/bin/sh\nif [ "$2" = publish ]; then\n'
                 '  printf "operator-owned\\n" > "$4"\nfi\n'
                 f'exec "{python}" "$@"\n')
probe.chmod(0o700)
invoke(race, "install", code=1)
probe.unlink()
assert (race / "docker-compose.override.yml").read_text() == "operator-owned\n"
assert not list(race.glob(".vaultwarden-*")) and mutations() == calls

prefix = project("hostname-prefix")
invoke(prefix, "install", "--domain-suffix", "internal.example")
invoke(prefix, "verify")
assert "vw.internal.example" in (prefix / "Caddyfile.d/vaultwarden.conf").read_text()

# Exact adoption rejects extra keys, not merely an unexpected image or hostname.
for change in (
    lambda text: text.replace("restart: unless-stopped", "restart: always"),
    lambda text: text + "    labels:\n      operator: changed\n",
    lambda text: text.replace('SIGNUPS_ALLOWED: "false"', 'SIGNUPS_ALLOWED: "true"'),
):
    before = (clean / "docker-compose.override.yml").read_text()
    (clean / "docker-compose.override.yml").write_text(change(before))
    no_change(clean, "install", "--resume")
    (clean / "docker-compose.override.yml").write_text(before)
caddy = clean / "Caddyfile.d/vaultwarden.conf"
caddy_bytes = caddy.read_bytes()
caddy.write_bytes(caddy_bytes + b"# operator edit\n")
no_change(clean, "install", "--resume")
caddy.write_bytes(caddy_bytes)
caddy.unlink()
invoke(clean, "install", "--resume")  # Interrupted after override publication.
assert caddy.read_bytes() == caddy_bytes

for failure in ("START_FAIL", "UNHEALTHY"):
    target = project(failure.lower())
    (root / "sleeps").unlink(missing_ok=True)
    result = invoke(target, "install", code=1, extra={failure: "1"})
    assert "--resume" in result.stderr
    assert (target / "docker-compose.override.yml").is_file() and (target / "Caddyfile.d/vaultwarden.conf").is_file()
    assert (target / "volumes/vaultwarden").is_dir()
    if failure == "UNHEALTHY":
        assert (root / "sleeps").read_text().splitlines() == ["5"] * 30
    invoke(target, "install", "--resume")

invoke(clean, "install", "--resume")
result = no_change(clean, "verify", code=0)
assert result.stdout.count("[ACTION]") == 3 and "[OK]" in result.stdout
runtime_file = root / "runtime"
good_runtime = json.loads(runtime_file.read_text())
for fault in ("image", "host-ports", "live-ports", "signup", "duplicate-signup", "unhealthy", "stopped"):
    runtime = copy.deepcopy(good_runtime)
    container = runtime[0]
    if fault == "image": container["Config"]["Image"] = "wrong:image"
    elif fault == "host-ports": container["HostConfig"]["PortBindings"] = {"80/tcp": [{"HostPort": "80"}]}
    elif fault == "live-ports": container["NetworkSettings"]["Ports"] = {"80/tcp": [{"HostPort": "80"}]}
    elif fault == "signup": container["Config"]["Env"] = ["SIGNUPS_ALLOWED=true"]
    elif fault == "duplicate-signup": container["Config"]["Env"] *= 2
    elif fault == "unhealthy": container["State"]["Health"]["Status"] = "unhealthy"
    else: container["State"]["Running"] = False
    runtime_file.write_text(json.dumps(runtime))
    no_change(clean, "verify")
runtime_file.write_text(json.dumps(good_runtime))
override = clean / "docker-compose.override.yml"
good_override = override.read_text()
for text in (
    good_override.replace("vaultwarden/server:", "wrong/server:"),
    good_override + '    ports:\n      - "8080:80"\n',
    good_override.replace('SIGNUPS_ALLOWED: "false"', 'SIGNUPS_ALLOWED: "true"'),
    good_override.replace("vw.internal", "vw.home.arpa"),
    good_override.replace("./volumes/vaultwarden:/data", "./volumes/other:/data"),
    good_override.replace("ipv4_address: 10.66.0.5", "ipv4_address: 10.66.0.6"),
):
    override.write_text(text)
    no_change(clean, "verify")
override.write_text(good_override)
caddy.write_bytes(caddy_bytes.replace(b"vw.internal", b"vw.home.arpa"))
no_change(clean, "verify")
caddy.write_bytes(caddy_bytes)


def bootstrap(mode, extra=None):
    before, start = snapshot(clean), len(mutations())
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(str(manager), [str(manager), "bootstrap", "--project-root", str(clean), "--timeout", "60"],
                  env | (extra or {}))
    output, triggered, reaped = b"", False, False
    deadline = time.monotonic() + 85
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    data = b""
                output += data
                if not triggered and b"Press Enter here" in output:
                    triggered = True
                    # Observe the real three-file model and private temporary file while open.
                    opened = mutations()[-1]
                    assert opened["argv"].count("-f") == 3
                    temporary = Path(opened["argv"][-4])
                    assert stat.S_IMODE(temporary.stat().st_mode) == 0o600
                    assert opened["model"]["services"]["vaultwarden"]["environment"]["SIGNUPS_ALLOWED"] == "true"
                    assert json.loads(runtime_file.read_text())[0]["Config"]["Env"] == ["SIGNUPS_ALLOWED=true"]
                    if mode == "enter": os.write(fd, b"\n")
                    elif mode == "term": os.kill(pid, signal.SIGTERM)
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                reaped = True
                code = os.waitstatus_to_exitcode(status)
                break
        else:
            raise AssertionError("Bootstrap did not exit within its bounded timeout")
        text = output.decode()
        assert code == (0 if mode == "enter" and not extra else 1), text
        assert triggered or (extra and extra.get("OPEN_UNHEALTHY")), text
        calls = mutations()[start:]
        assert [c["argv"].count("-f") for c in calls] == [2, 3, 2]
        assert [c["model"]["services"]["vaultwarden"]["environment"]["SIGNUPS_ALLOWED"] for c in calls] == [
            "false", "true", "false"]
        assert snapshot(clean) == before and not list(temps.iterdir())
        if extra and extra.get("CLOSE_FAIL"):
            assert "--close" in text and "[FAIL]" in text
        else:
            assert json.loads(runtime_file.read_text())[0]["Config"]["Env"] == ["SIGNUPS_ALLOWED=false"]
        return text
    finally:
        os.close(fd)
        if not reaped:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)


for mode in ("enter", "term", "timeout"):
    bootstrap(mode)
bootstrap("enter", {"OPEN_UNHEALTHY": "1"})
bootstrap("enter", {"CLOSE_FAIL": "1"})
# Recovery works without a controlling terminal and repairs a still-open runtime.
assert json.loads(runtime_file.read_text())[0]["Config"]["Env"] == ["SIGNUPS_ALLOWED=true"]
before = len(mutations())
invoke(clean, "bootstrap", "--close")
assert len(mutations()) == before + 1 and mutations()[-1]["argv"].count("-f") == 2
assert json.loads(runtime_file.read_text())[0]["Config"]["Env"] == ["SIGNUPS_ALLOWED=false"]
invoke(clean, "bootstrap", "--close")
subprocess_result = subprocess.run(
    [str(manager), "bootstrap", "--project-root", str(clean)], env=env,
    start_new_session=True, capture_output=True, text=True, timeout=40)
assert subprocess_result.returncode == 1 and "/dev/tty" in subprocess_result.stderr
assert not list(temps.iterdir())
assert all(call["argv"][-3:] == ["up", "-d", "vaultwarden"] for call in mutations())
assert all("--remove-orphans" not in call["argv"] for call in mutations())
print("[PASS] examples-contract: manage.sh usage, read-only checks, install/resume, bootstrap closure and runtime verification")
PY
