#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE_PATH="${REPO_ROOT}/roles/vps_orchestration/templates/docker-compose.yml.j2"
TASK_PATH="${REPO_ROOT}/roles/vps_orchestration/tasks/compose.yml"
PROBE_TASK_PATH="${REPO_ROOT}/roles/vps_orchestration/tasks/compose_prepare.yml"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/compose-render.XXXXXX")"
ACTIVE_COMPOSE_FILE=""
ACTIVE_OVERRIDE_FILE=""
cleanup() {
  local status=$?
  if (( status != 0 )); then
    printf '[FAIL] compose-render failed; fixture diagnostics follow (synthetic inputs only).\n' >&2
    for log in "${FIXTURE_ROOT}"/*.log; do
      [[ ! -f ${log} ]] || tail -n 35 "${log}" >&2
    done
  fi
  if [[ -n "${ACTIVE_COMPOSE_FILE}" && -n "${ACTIVE_OVERRIDE_FILE}" ]]; then
    docker compose -f "${ACTIVE_COMPOSE_FILE}" -f "${ACTIVE_OVERRIDE_FILE}" \
      down --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf -- "${FIXTURE_ROOT}"
}
trap cleanup EXIT INT TERM
chmod 700 "${FIXTURE_ROOT}"

render_case() {
  local case_name="$1"
  local vars_path="${FIXTURE_ROOT}/${case_name}.json"
  local expected_path="${FIXTURE_ROOT}/${case_name}.expected"
  local rendered_path="${FIXTURE_ROOT}/${case_name}.yml"
  local override_path="${FIXTURE_ROOT}/${case_name}.override.yml"
  local config_path="${FIXTURE_ROOT}/${case_name}.config.json"

  local project_root="${FIXTURE_ROOT}/${case_name}-project"
  mkdir -p "${project_root}/volumes/wg-easy" "${project_root}/Caddyfile.d"
  : >"${project_root}/Caddyfile"
  chmod 700 "${project_root}" "${project_root}/volumes" \
    "${project_root}/volumes/wg-easy" "${project_root}/Caddyfile.d"
  chmod 600 "${project_root}/Caddyfile"

  CASE_NAME="${case_name}" VARS_PATH="${vars_path}" EXPECTED_PATH="${expected_path}" \
    PROJECT_ROOT="${project_root}" python3 - <<'PY'
import json
import os
from pathlib import Path

secrets = {
    "dollar": "Twelve$COMPOSE_PROBE",
    "scalars": "  quote\" and ' colon: hash# backslash\\ spaces  ",
    "completed": "Twelve$COMPOSE_PROBE",
}
secret = secrets[os.environ["CASE_NAME"]]
variables = {
    "adguard_bootstrap_ui_port": 3000,
    "adguard_container_ip": "10.66.0.2",
    "adguard_version": "v0.107.78",
    "adguard_image_digest": "sha256:1ea34eafe5dc691007946e8eaab7bf46b0de9412f39213d8c06e48b53bf9a6c5",
    "caddy_container_ip": "10.66.0.3",
    "caddy_version": "2.11.4",
    "caddy_image_digest": "sha256:df7f1c2fb114453b951de51a98efc010db1655a92c2e86be6706714e2417a78d",
    "docker_network_subnet": "10.66.0.0/24",
    "docker_network_ipv6_subnet": "fd00:67:0:0::/64",
    "project_root": os.environ["PROJECT_ROOT"],
    "wg_allowed_ips": ["10.8.0.0/24", "10.66.0.2/32"],
    "wg_client_dns": "10.66.0.2",
    "wg_container_port": 51820,
    "wg_easy_bootstrap_secret": secret,
    "wg_easy_admin_user": "admin",
    "wg_easy_bootstrap_ui_port": 51821,
    "wg_easy_container_ip": "10.66.0.4",
    "wg_easy_include_init": os.environ["CASE_NAME"] in {"dollar", "scalars"},
    "wg_easy_version": "15.4.0",
    "wg_easy_image_digest": "sha256:0e7bc9d34e86ddcaa92bc700d4d7dc9b33291dbc07ac8d13382f7c2095f949ec",
    "wg_port": 51820,
    "wg_public_host": "vpn.example.test",
    "wg_services_only_ipv4_destinations": ["10.8.0.0/24", "10.66.0.2/32"],
    "wg_services_only_ipv6_destinations": ["fd42:42:42::/64"],
    "wg_traffic_mode": "services",
    "wg_vpn_ipv6_subnet": "fd42:42:42::/64",
}
Path(os.environ["VARS_PATH"]).write_text(json.dumps(variables), encoding="utf-8")
Path(os.environ["EXPECTED_PATH"]).write_text(secret, encoding="utf-8")
PY
  chmod 600 "${vars_path}" "${expected_path}"

  cat >"${FIXTURE_ROOT}/render.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  tasks:
    - name: Render the production Compose template
      ansible.builtin.template:
        src: "${TEMPLATE_PATH}"
        dest: "${rendered_path}"
        mode: '0600'
      no_log: true
YAML
  cat >"${override_path}" <<YAML
---
services:
  wg-easy:
    volumes:
      - "${expected_path}:/run/expected-password:ro"
YAML
  ANSIBLE_NOCOLOR=1 ansible-playbook -i localhost, -c local \
    "${FIXTURE_ROOT}/render.yml" -e "@${vars_path}" \
    >"${FIXTURE_ROOT}/${case_name}.ansible.log" 2>&1
  docker compose -f "${rendered_path}" -f "${override_path}" \
    config --format json \
    >"${config_path}" 2>"${FIXTURE_ROOT}/${case_name}.compose.log"
  chmod 600 "${override_path}" "${config_path}" \
    "${FIXTURE_ROOT}/${case_name}.ansible.log" \
    "${FIXTURE_ROOT}/${case_name}.compose.log"

  CASE_NAME="${case_name}" CONFIG_PATH="${config_path}" \
    EXPECTED_PATH="${expected_path}" python3 - <<'PY'
import json
import os
from pathlib import Path

config = json.loads(Path(os.environ["CONFIG_PATH"]).read_text(encoding="utf-8"))
expected = Path(os.environ["EXPECTED_PATH"]).read_text(encoding="utf-8")
environment = config["services"]["wg-easy"]["environment"]
expects_init = os.environ["CASE_NAME"] in {"dollar", "scalars"}
if not expects_init:
    if any(name.startswith("INIT_") for name in environment):
        raise SystemExit(1)
elif environment["INIT_PASSWORD"] != expected.replace("$", "$$"):
    print("password_exact=false")
    raise SystemExit(1)
PY

  if [[ "${case_name}" == "completed" ]]; then
    return
  fi
  # Runtime assertion concerns environment bytes only. Do not allocate the
  # production subnets: a developer may already have the real stack running.
  cat >>"${override_path}" <<'YAML'
    networks: !reset []
    network_mode: none
YAML
  ACTIVE_COMPOSE_FILE="${rendered_path}"
  ACTIVE_OVERRIDE_FILE="${override_path}"
  docker compose -f "${rendered_path}" -f "${override_path}" \
    run --rm --no-deps --entrypoint node wg-easy -e \
    'const fs=require("fs");const expected=fs.readFileSync("/run/expected-password","utf8");process.exit(process.env.INIT_PASSWORD===expected?0:1)' \
    >"${FIXTURE_ROOT}/${case_name}.runtime.log" 2>&1
  chmod 600 "${FIXTURE_ROOT}/${case_name}.runtime.log"
  docker compose -f "${rendered_path}" -f "${override_path}" \
    down --remove-orphans >/dev/null 2>&1
  ACTIVE_COMPOSE_FILE=""
  ACTIVE_OVERRIDE_FILE=""
}

make_database() {
  local fixture_name="$1"
  local setup_step="$2"
  local fixture_dir="${FIXTURE_ROOT}/${fixture_name}/volumes/wg-easy"
  mkdir -p "${fixture_dir}"
  DB_PATH="${fixture_dir}/wg-easy.db" SETUP_STEP="${setup_step}" python3 - <<'PY'
import os
import sqlite3

connection = sqlite3.connect(os.environ["DB_PATH"])
connection.execute("CREATE TABLE general_table (setup_step INTEGER NOT NULL)")
connection.execute("INSERT INTO general_table (setup_step) VALUES (?)", (int(os.environ["SETUP_STEP"]),))
connection.commit()
connection.close()
PY
}

probe_case() {
  local fixture_name="$1"
  local expected="$2"
  local fixture_root="${FIXTURE_ROOT}/${fixture_name}"
  mkdir -p "${fixture_root}"
  cat >"${FIXTURE_ROOT}/probe-${fixture_name}.yml" <<YAML
---
- hosts: localhost
  gather_facts: false
  vars:
    project_root: "${fixture_root}"
  tasks:
    - ansible.builtin.import_tasks: "${PROBE_TASK_PATH}"
    - name: Assert the production state decision
      ansible.builtin.assert:
        that:
          - (wg_easy_initialized | bool) == (${expected} | bool)
      tags: [wg_bootstrap_state]
YAML
  if ! ANSIBLE_NOCOLOR=1 ansible-playbook -i localhost, -c local \
    "${FIXTURE_ROOT}/probe-${fixture_name}.yml" --tags wg_bootstrap_state \
    >"${FIXTURE_ROOT}/probe-${fixture_name}.log" 2>&1; then
    chmod 600 "${FIXTURE_ROOT}/probe-${fixture_name}.log"
    return 1
  fi
  chmod 600 "${FIXTURE_ROOT}/probe-${fixture_name}.log"
}

probe_failure_case() {
  local fixture_name="$1"
  if probe_case "${fixture_name}" false; then
    return 1
  fi
}

render_case dollar
render_case scalars
render_case completed
printf '%s\n' 'password_exact=true' 'scalar_encoding=true' \
  'completed_secret_free=true' 'vault_only_bootstrap=true'

probe_case absent false
make_database nonzero 2
probe_case nonzero false
make_database zero 0
probe_case zero true

mkdir -p "${FIXTURE_ROOT}/unexpected/volumes/wg-easy"
DB_PATH="${FIXTURE_ROOT}/unexpected/volumes/wg-easy/wg-easy.db" python3 - <<'PY'
import os
import sqlite3

connection = sqlite3.connect(os.environ["DB_PATH"])
connection.execute("CREATE TABLE unrelated (value INTEGER)")
connection.commit()
connection.close()
PY
probe_failure_case unexpected

mkdir -p "${FIXTURE_ROOT}/unreadable/volumes/wg-easy"
printf '%s' 'not-a-sqlite-database' >"${FIXTURE_ROOT}/unreadable/volumes/wg-easy/wg-easy.db"
probe_failure_case unreadable
printf '%s\n' 'state_absent=true' 'state_nonzero=true' 'state_zero=true' \
  'schema_fail_closed=true' 'unreadable_fail_closed=true'

COMPOSE_TASK_PATH="${TASK_PATH}" \
COMPOSE_PREPARE_TASK_PATH="${REPO_ROOT}/roles/vps_orchestration/tasks/compose_prepare.yml" \
CADDY_TASK_PATH="${REPO_ROOT}/roles/vps_orchestration/tasks/caddy_transaction.yml" \
COMPOSE_LIFECYCLE_TASK_PATH="${REPO_ROOT}/roles/vps_orchestration/tasks/compose_lifecycle.yml" \
VERIFY_TASK_PATH="${REPO_ROOT}/roles/vps_orchestration/tasks/verify.yml" python3 - <<'PY'
import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path

import yaml


def tasks_in(items):
    for task in items:
        yield task
        for section in ("block", "rescue", "always"):
            yield from tasks_in(task.get(section, []))


documents = []
for variable in (
    "COMPOSE_TASK_PATH",
    "COMPOSE_PREPARE_TASK_PATH",
    "CADDY_TASK_PATH",
    "COMPOSE_LIFECYCLE_TASK_PATH",
    "VERIFY_TASK_PATH",
):
    documents.extend(yaml.safe_load(Path(os.environ[variable]).read_text(encoding="utf-8")))

required_names = {
    "Compose | Detect | Select automated wg-easy bootstrap",
    "Compose | Deploy | Write docker-compose.yml",
    "Compose | Run | Start Docker Compose stack",
    "Compose | Bootstrap | Authenticate initial wg-easy setup",
    "Compose | Bootstrap | Authenticate re-secured wg-easy setup",
    "Compose | Rescue | Inspect scrubbed persistent Compose",
    "Compose | Rescue | Fail closed when persistent INIT variables remain",
    "Compose | Rescue | Inspect scrubbed wg-easy environment",
    "Compose | Rescue | Record credential scrub result",
    "Compose | Rescue | Fail closed when INIT_PASSWORD remains",
    "Compose | Rescue | Fail closed when unsafe INIT variables remain",
    "Verify | WG | wg-easy container env is free of INIT_PASSWORD",
}
tasks = {task.get("name"): task for task in tasks_in(documents)}
if not required_names.issubset(tasks):
    raise SystemExit(1)
for name in required_names:
    if tasks[name].get("no_log") in (None, False):
        raise SystemExit(1)

caddy_validation = tasks["Compose | Caddy | Validate complete candidate tree"]
caddy_argv = caddy_validation["ansible.builtin.command"]["argv"]
if not any(value.startswith("caddy:") and "@{{ caddy_image_digest }}" in value for value in caddy_argv):
    raise SystemExit(1)

# Caddyfile is a Docker file bind-mount: replacing it with mv leaves the
# container on the old inode while .Caddyfile.active.sha256 tracks the new path.
inplace_names = (
    "Compose | Activate | Install validated Caddyfile in place",
    "Compose | Rollback | Restore prior managed file in place",
)
for name in inplace_names:
    if name not in tasks:
        raise SystemExit(1)
    argv = tasks[name].get("ansible.builtin.command", {}).get("argv") or []
    if len(argv) < 4 or argv[0] != "python3" or "-c" not in argv:
        raise SystemExit(1)
    script = argv[argv.index("-c") + 1]
    if "O_TRUNC" not in script or "O_WRONLY" not in script:
        raise SystemExit(1)
    if "os.rename" in script or "os.replace" in script:
        raise SystemExit(1)

script = tasks[inplace_names[0]]["ansible.builtin.command"]["argv"][
    tasks[inplace_names[0]]["ansible.builtin.command"]["argv"].index("-c") + 1
]
root = tempfile.mkdtemp(prefix="caddy-inode.")
try:
    live = os.path.join(root, "Caddyfile")
    candidate = os.path.join(root, "candidate")
    previous = os.path.join(root, "previous")
    with open(live, "w", encoding="utf-8") as handle:
        handle.write("old-config\n")
    with open(candidate, "w", encoding="utf-8") as handle:
        handle.write("new-config\n")
    with open(previous, "w", encoding="utf-8") as handle:
        handle.write("old-config\n")
    inode = os.stat(live).st_ino
    held_fd = os.open(live, os.O_RDONLY)
    subprocess.check_call(["python3", "-c", script, candidate, live])
    if os.stat(live).st_ino != inode:
        raise SystemExit(1)
    if os.read(held_fd, 64) != b"new-config\n":
        raise SystemExit(1)
    if stat.S_IMODE(os.stat(live).st_mode) != 0o600:
        raise SystemExit(1)
    os.lseek(held_fd, 0, os.SEEK_SET)
    subprocess.check_call(["python3", "-c", script, previous, live])
    if os.stat(live).st_ino != inode:
        raise SystemExit(1)
    if os.read(held_fd, 64) != b"old-config\n":
        raise SystemExit(1)
    os.close(held_fd)

    # Contrast: mv/replace creates a new inode and leaves the held fd stale.
    with open(live, "w", encoding="utf-8") as handle:
        handle.write("old-config\n")
    with open(candidate, "w", encoding="utf-8") as handle:
        handle.write("new-config\n")
    stale_inode = os.stat(live).st_ino
    stale_fd = os.open(live, os.O_RDONLY)
    os.replace(candidate, live)
    if os.stat(live).st_ino == stale_inode:
        raise SystemExit(1)
    if os.read(stale_fd, 64) != b"old-config\n":
        raise SystemExit(1)
    os.close(stale_fd)
finally:
    shutil.rmtree(root, ignore_errors=True)
PY
printf '%s\n' 'credential_tasks_no_log=true' 'cleanup_registered=true' \
  'caddy_bind_mount_inode=true'
