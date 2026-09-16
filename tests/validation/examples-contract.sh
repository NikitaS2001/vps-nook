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
assert_present "${ROOT_DIR}/examples/vaultwarden/README.md"
assert_present "${ROOT_DIR}/examples/vaultwarden/compose.override.yml"
assert_present "${ROOT_DIR}/examples/vaultwarden/Caddyfile.conf"

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
