#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/traffic-mode-contract.XXXXXX")"
cleanup() { find "${TMP}" -depth -delete; }
trap cleanup EXIT INT TERM

PROJECT="${TMP}/project"
BIN="${TMP}/bin"
DB="${PROJECT}/volumes/wg-easy/wg-easy.db"
LOG="${TMP}/docker.log"
mkdir -p "${PROJECT}/volumes/wg-easy" "${BIN}"
: >"${LOG}"
printf 'preserved\n' >"${PROJECT}/volumes/wg-easy/wg0.conf"

python3 - "${DB}" <<'PY'
import json
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as database:
    database.execute("CREATE TABLE user_configs_table (id TEXT PRIMARY KEY, default_allowed_ips TEXT NOT NULL)")
    database.execute("INSERT INTO user_configs_table VALUES ('wg0', ?)", (json.dumps(["0.0.0.0/0", "::/0"]),))
    database.execute("CREATE TABLE interfaces_table (name TEXT PRIMARY KEY, firewall_enabled INTEGER NOT NULL)")
    database.execute("INSERT INTO interfaces_table VALUES ('wg0', 0)")
    database.execute("CREATE TABLE clients_table (id TEXT PRIMARY KEY, allowed_ips TEXT, firewall_ips TEXT)")
    database.execute("INSERT INTO clients_table VALUES ('peer', ?, NULL)", (json.dumps(["0.0.0.0/0", "::/0"]),))
PY

cat >"${BIN}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"${TRAFFIC_TEST_LOG:?}"
case "${1:-}" in
  inspect)
    printf 'wg-id true\n'
    ;;
  stop)
    exit 0
    ;;
  start)
    count_file="${TRAFFIC_TEST_START_COUNT:?}"
    count="$(( $(cat "${count_file}") + 1 ))"
    printf '%s\n' "${count}" >"${count_file}"
    if [[ -n "${TRAFFIC_TEST_FAIL_START_AFTER:-}" && "${count}" -gt "${TRAFFIC_TEST_FAIL_START_AFTER}" ]]; then
      exit 72
    fi
    [[ ! -e "${TRAFFIC_TEST_RUNTIME_DRIFT:-/nonexistent}" ]] || find "${TRAFFIC_TEST_RUNTIME_DRIFT}" -delete
    ;;
  exec)
    shift 2
    if [[ "$*" == "wg show wg0" || "$*" == "awg show wg0" ]]; then
      [[ ! -e "${TRAFFIC_TEST_FAIL_READINESS:-/nonexistent}" ]]
      exit
    fi
    firewall="$(python3 - "${TRAFFIC_TEST_DB:?}" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    print(db.execute("SELECT firewall_enabled FROM interfaces_table WHERE name='wg0'").fetchone()[0])
PY
)"
    [[ ! -e "${TRAFFIC_TEST_RUNTIME_DRIFT:-/nonexistent}" ]] || firewall=0
    family="${1:-}"
    shift
    if [[ "${1:-}" == -C ]]; then
      [[ "${firewall}" == 1 ]]
      exit
    fi
    if [[ "${1:-}" == -S && "${2:-}" == WG_CLIENTS && "${firewall}" == 1 ]]; then
      if [[ "${family}" == iptables ]]; then
        printf '%s\n' '-N WG_CLIENTS'
        [[ -z "${TRAFFIC_TEST_BROAD_ACCEPT:-}" ]] || printf '%s\n' '-A WG_CLIENTS -s 0.0.0.0/0 -d 0.0.0.0/0 -j ACCEPT'
        printf '%s\n' '-A WG_CLIENTS -s 10.8.0.2/32 -d 10.66.0.2/32 -j ACCEPT' '-A WG_CLIENTS -j DROP'
      else
        printf '%s\n' '-N WG_CLIENTS'
        [[ -z "${TRAFFIC_TEST_BROAD_ACCEPT:-}" ]] || printf '%s\n' '-A WG_CLIENTS -s ::/0 -d ::/0 -j ACCEPT'
        printf '%s\n' '-A WG_CLIENTS -s fd42:42:42::2/128 -d fd42:42:42::/64 -j ACCEPT' '-A WG_CLIENTS -j DROP'
      fi
      exit
    fi
    exit 1
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod 0755 "${BIN}/docker"
cat >"${BIN}/cp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -e "${TRAFFIC_TEST_FAIL_SNAPSHOT:-/nonexistent}" ]]; then
  destination="${@: -1}"
  mkdir -p "${destination}"
  /usr/bin/cp "${TRAFFIC_TEST_DB:?}" "${destination}/wg-easy.db"
  exit 71
fi
exec /usr/bin/cp "$@"
SH
chmod 0755 "${BIN}/cp"
cat >"${BIN}/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -c && "${2:-}" == *'os.replace(temporary, destination)'* && -e "${TRAFFIC_TEST_FAIL_AFTER_MARKER:-/nonexistent}" ]]; then
  /usr/bin/python3 "$@"
  exit 73
fi
exec /usr/bin/python3 "$@"
SH
chmod 0755 "${BIN}/python3"

cat >"${TMP}/playbook.yml" <<YAML
---
- hosts: localhost
  connection: local
  gather_facts: false
  become: false
  vars:
    project_root: "${PROJECT}"
    wg_traffic_mode: services
    wg_services_only_ipv4_destinations: ["10.8.0.0/24", "10.66.0.2/32", "10.66.0.3/32"]
    wg_services_only_ipv6_destinations: ["fd42:42:42::/64"]
    vps_orchestration_traffic_mode_readiness_retries: 1
    wg_amnezia_enabled: false
    wg_amnezia_overrided_executable: awg
    # Mirrors the role default; this contract imports task files directly and
    # therefore does not load role defaults.
    vps_orchestration_wg_executable: >-
      {{ wg_amnezia_overrided_executable if wg_amnezia_enabled | bool else 'wg' }}
  tasks:
    - ansible.builtin.import_tasks: "${ROOT}/roles/vps_orchestration/tasks/traffic_mode.yml"
YAML

export PATH="${BIN}:${PATH}"
export TRAFFIC_TEST_LOG="${LOG}"
export TRAFFIC_TEST_DB="${DB}"
export TRAFFIC_TEST_START_COUNT="${TMP}/start-count"
printf '0\n' >"${TRAFFIC_TEST_START_COUNT}"

for unsafe_root in / relative/path /tmp/../unsafe; do
  if ansible-playbook "${TMP}/playbook.yml" -e "project_root=${unsafe_root}" >"${TMP}/unsafe-root.log" 2>&1; then
    echo "unsafe project_root unexpectedly succeeded: ${unsafe_root}" >&2
    exit 1
  fi
  grep -Fq 'non-zero return code' "${TMP}/unsafe-root.log"
done

read_policy() {
  python3 - "${DB}" <<'PY'
import json,sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    routes=json.loads(db.execute("SELECT default_allowed_ips FROM user_configs_table").fetchone()[0])
    firewall=db.execute("SELECT firewall_enabled FROM interfaces_table WHERE name='wg0'").fetchone()[0]
    client_raw=db.execute("SELECT firewall_ips FROM clients_table WHERE id='peer'").fetchone()[0]
    client=json.loads(client_raw) if client_raw is not None else None
print(json.dumps({"routes":routes,"firewall":firewall,"client":client},sort_keys=True))
PY
}

ansible-playbook "${TMP}/playbook.yml" >"${TMP}/services.log"
[[ "$(<"${PROJECT}/.wg-traffic-mode")" == services ]]
[[ "$(read_policy)" == '{"client": ["10.8.0.0/24", "10.66.0.2/32", "10.66.0.3/32", "fd42:42:42::/64"], "firewall": 1, "routes": ["10.8.0.0/24", "10.66.0.2/32", "10.66.0.3/32", "fd42:42:42::/64"]}' ]]
grep -Fq 'docker exec wg-easy wg show wg0' "${LOG}"
grep -Fq 'docker exec wg-easy iptables -C FORWARD -i wg0 -j WG_CLIENTS' "${LOG}"
grep -Fq 'docker exec wg-easy ip6tables -S WG_CLIENTS' "${LOG}"

before_mutations="$(grep -Ec '^docker (stop|start) ' "${LOG}" || true)"
before_live_checks="$(grep -Ec '^docker exec ' "${LOG}" || true)"
ansible-playbook "${TMP}/playbook.yml" >"${TMP}/rerun.log"
[[ "$(grep -Ec '^docker (stop|start) ' "${LOG}" || true)" == "${before_mutations}" ]]
after_live_checks="$(grep -Ec '^docker exec ' "${LOG}" || true)"
if [[ "${after_live_checks}" -le "${before_live_checks}" ]]; then
  echo "converged rerun skipped live firewall validation: exec_before=${before_live_checks} exec_after=${after_live_checks}" >&2
  exit 1
fi
live_check_delta="$((after_live_checks - before_live_checks))"

export TRAFFIC_TEST_RUNTIME_DRIFT="${TMP}/runtime-drift"
touch "${TRAFFIC_TEST_RUNTIME_DRIFT}"
before_mutations="$(grep -Ec '^docker (stop|start) ' "${LOG}" || true)"
ansible-playbook "${TMP}/playbook.yml" >"${TMP}/runtime-drift.log"
[[ ! -e "${TRAFFIC_TEST_RUNTIME_DRIFT}" ]]
after_mutations="$(grep -Ec '^docker (stop|start) ' "${LOG}" || true)"
[[ "${after_mutations}" -gt "${before_mutations}" ]]
runtime_drift_mutation_delta="$((after_mutations - before_mutations))"
unset TRAFFIC_TEST_RUNTIME_DRIFT

python3 - "${DB}" <<'PY'
import json,sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE user_configs_table SET default_allowed_ips=?", (json.dumps(["0.0.0.0/0","::/0"]),))
    db.execute("UPDATE interfaces_table SET firewall_enabled=0 WHERE name='wg0'")
    db.execute("UPDATE clients_table SET firewall_ips=NULL")
PY
export TRAFFIC_TEST_BROAD_ACCEPT=1
if ansible-playbook "${TMP}/playbook.yml" >"${TMP}/broad-accept.log" 2>&1; then
  echo 'broad IPv4/IPv6 ACCEPT before terminal DROP unexpectedly passed readiness' >&2
  exit 1
fi
unset TRAFFIC_TEST_BROAD_ACCEPT
ansible-playbook "${TMP}/playbook.yml" >"${TMP}/drift.log"
[[ "$(read_policy)" == '{"client": ["10.8.0.0/24", "10.66.0.2/32", "10.66.0.3/32", "fd42:42:42::/64"], "firewall": 1, "routes": ["10.8.0.0/24", "10.66.0.2/32", "10.66.0.3/32", "fd42:42:42::/64"]}' ]]

ansible-playbook "${TMP}/playbook.yml" \
  -e wg_traffic_mode=full \
  -e vps_orchestration_full_ipv6_enabled=true >"${TMP}/full.log"
[[ "$(<"${PROJECT}/.wg-traffic-mode")" == full ]]
[[ "$(read_policy)" == '{"client": null, "firewall": 0, "routes": ["0.0.0.0/0", "::/0"]}' ]]

ansible-playbook "${TMP}/playbook.yml" \
  -e wg_traffic_mode=full \
  -e vps_orchestration_full_ipv6_enabled=false >"${TMP}/full-ipv4-only.log"
[[ "$(<"${PROJECT}/.wg-traffic-mode")" == full ]]
[[ "$(read_policy)" == '{"client": null, "firewall": 0, "routes": ["0.0.0.0/0"]}' ]]

# An AmneziaWG host owns the interface through awg; readiness must query it
# there because plain `wg show wg0` reports "Not supported" for such interfaces.
amnezia_exec_before="$(grep -Ec '^docker exec ' "${LOG}" || true)"
ansible-playbook "${TMP}/playbook.yml" \
  -e wg_amnezia_enabled=true -e wg_traffic_mode=full >"${TMP}/amnezia.log"
grep -Fq 'docker exec wg-easy awg show wg0' "${LOG}"
if [[ "$(grep -Ec '^docker exec ' "${LOG}" || true)" -le "${amnezia_exec_before}" ]]; then
  echo 'AmneziaWG run skipped live validation entirely' >&2
  exit 1
fi
[[ "$(<"${PROJECT}/.wg-traffic-mode")" == full ]]
ansible-playbook "${TMP}/playbook.yml" -e wg_traffic_mode=full >"${TMP}/amnezia-rerun.log"
if grep -Fq 'docker exec wg-easy awg show wg0' "${TMP}/amnezia-rerun.log"; then
  echo 'non-AmneziaWG run still queried the awg executable' >&2
  exit 1
fi

cp "${DB}" "${TMP}/before-post-marker-fault.db"
post_marker_db_sha="$(sha256sum "${DB}" | cut -d' ' -f1)"
post_marker_state_sha="$(sha256sum "${PROJECT}/.wg-traffic-mode" | cut -d' ' -f1)"
export TRAFFIC_TEST_FAIL_AFTER_MARKER="${TMP}/fail-after-marker"
touch "${TRAFFIC_TEST_FAIL_AFTER_MARKER}"
if ansible-playbook "${TMP}/playbook.yml" >"${TMP}/post-marker-fault.log" 2>&1; then
  echo 'post-marker fault unexpectedly succeeded' >&2
  exit 1
fi
unset TRAFFIC_TEST_FAIL_AFTER_MARKER
cmp "${DB}" "${TMP}/before-post-marker-fault.db"
if [[ "$(<"${PROJECT}/.wg-traffic-mode")" != full ]]; then
  echo "post-marker rollback left marker=$(<"${PROJECT}/.wg-traffic-mode") with full DB" >&2
  exit 1
fi
[[ -z "$(find "${PROJECT}" -maxdepth 1 -name '.wg-traffic-mode.transaction.*' -print -quit)" ]]
post_marker_transaction_count="$(find "${PROJECT}" -maxdepth 1 -name '.wg-traffic-mode.transaction.*' | wc -l)"

cp "${DB}" "${TMP}/before-snapshot.db"
wg_before_snapshot="$(sha256sum "${PROJECT}/volumes/wg-easy/wg0.conf")"
touch "${TMP}/fail-snapshot"
export TRAFFIC_TEST_FAIL_SNAPSHOT="${TMP}/fail-snapshot"
if ansible-playbook "${TMP}/playbook.yml" >"${TMP}/snapshot.log" 2>&1; then
  echo 'partial snapshot failure unexpectedly succeeded' >&2
  exit 1
fi
unset TRAFFIC_TEST_FAIL_SNAPSHOT
cmp "${DB}" "${TMP}/before-snapshot.db"
[[ "$(sha256sum "${PROJECT}/volumes/wg-easy/wg0.conf")" == "${wg_before_snapshot}" ]]
[[ "$(<"${PROJECT}/.wg-traffic-mode")" == full ]]
[[ -z "$(find "${PROJECT}" -maxdepth 1 -name '.wg-traffic-mode.transaction.*' -print -quit)" ]]

touch "${PROJECT}/.wg-traffic-mode.new"
if ansible-playbook "${TMP}/playbook.yml" -e wg_traffic_mode=full >"${TMP}/residue.log" 2>&1; then
  echo 'commit residue unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'interrupted traffic-mode transaction requires operator recovery' "${TMP}/residue.log"
find "${PROJECT}/.wg-traffic-mode.new" -delete

cp "${DB}" "${TMP}/before-rollback.db"
cp "${PROJECT}/.wg-traffic-mode" "${TMP}/before-rollback.marker"
rollback_start_count_before="$(<"${TRAFFIC_TEST_START_COUNT}")"
touch "${TMP}/fail-readiness"
export TRAFFIC_TEST_FAIL_READINESS="${TMP}/fail-readiness"
if ansible-playbook "${TMP}/playbook.yml" >"${TMP}/rollback.log" 2>&1; then
  echo 'readiness failure unexpectedly succeeded' >&2
  exit 1
fi
unset TRAFFIC_TEST_FAIL_READINESS
cmp "${DB}" "${TMP}/before-rollback.db"
cmp "${PROJECT}/.wg-traffic-mode" "${TMP}/before-rollback.marker"
rollback_start_count_after="$(<"${TRAFFIC_TEST_START_COUNT}")"
[[ "$((rollback_start_count_after - rollback_start_count_before))" == 2 ]]
[[ -z "$(find "${PROJECT}" -maxdepth 1 -name '.wg-traffic-mode.transaction.*' -print -quit)" ]]
grep -Fq 'original wg-easy state was restored' "${TMP}/rollback.log"

cp "${DB}" "${TMP}/before-absent-marker-rollback.db"
find "${PROJECT}/.wg-traffic-mode" -delete
absent_marker_start_count_before="$(<"${TRAFFIC_TEST_START_COUNT}")"
touch "${TMP}/fail-readiness"
export TRAFFIC_TEST_FAIL_READINESS="${TMP}/fail-readiness"
if ansible-playbook "${TMP}/playbook.yml" >"${TMP}/absent-marker-rollback.log" 2>&1; then
  echo 'absent-marker readiness failure unexpectedly succeeded' >&2
  exit 1
fi
unset TRAFFIC_TEST_FAIL_READINESS
cmp "${DB}" "${TMP}/before-absent-marker-rollback.db"
[[ ! -e "${PROJECT}/.wg-traffic-mode" ]]
absent_marker_start_count_after="$(<"${TRAFFIC_TEST_START_COUNT}")"
absent_marker_restart_delta="$((absent_marker_start_count_after - absent_marker_start_count_before))"
absent_marker_transaction_count="$(find "${PROJECT}" -maxdepth 1 -name '.wg-traffic-mode.transaction.*' | wc -l)"
if [[ "${absent_marker_restart_delta}" != 2 || "${absent_marker_transaction_count}" != 0 ]] \
  || ! grep -Fq 'original wg-easy state was restored' "${TMP}/absent-marker-rollback.log"; then
  printf '[FAIL] absent_marker_rollback=marker_absent:%s,restart_delta:%s,transaction_residue:%s,rollback_complete:%s\n' \
    "$([[ ! -e "${PROJECT}/.wg-traffic-mode" ]] && printf true || printf false)" \
    "${absent_marker_restart_delta}" \
    "${absent_marker_transaction_count}" \
    "$(grep -Fq 'original wg-easy state was restored' "${TMP}/absent-marker-rollback.log" && printf true || printf false)" >&2
  exit 1
fi

cp "${DB}" "${TMP}/before-absent-marker-partial-snapshot.db"
absent_partial_start_count_before="$(<"${TRAFFIC_TEST_START_COUNT}")"
touch "${TMP}/fail-absent-marker-partial-snapshot"
export TRAFFIC_TEST_FAIL_SNAPSHOT="${TMP}/fail-absent-marker-partial-snapshot"
if ansible-playbook "${TMP}/playbook.yml" >"${TMP}/absent-marker-partial-snapshot.log" 2>&1; then
  echo 'absent-marker partial snapshot failure unexpectedly succeeded' >&2
  exit 1
fi
unset TRAFFIC_TEST_FAIL_SNAPSHOT
cmp "${DB}" "${TMP}/before-absent-marker-partial-snapshot.db"
[[ ! -e "${PROJECT}/.wg-traffic-mode" ]]
absent_partial_start_count_after="$(<"${TRAFFIC_TEST_START_COUNT}")"
absent_partial_restart_delta="$((absent_partial_start_count_after - absent_partial_start_count_before))"
[[ "${absent_partial_restart_delta}" == 1 ]]
[[ -z "$(find "${PROJECT}" -maxdepth 1 -name '.wg-traffic-mode.transaction.*' -print -quit)" ]]
printf 'full\n' >"${PROJECT}/.wg-traffic-mode"
chmod 0600 "${PROJECT}/.wg-traffic-mode"

cp "${DB}" "${TMP}/before-rollback-failure.db"
touch "${TMP}/fail-readiness"
export TRAFFIC_TEST_FAIL_READINESS="${TMP}/fail-readiness"
export TRAFFIC_TEST_FAIL_START_AFTER="$(( $(cat "${TRAFFIC_TEST_START_COUNT}") + 1 ))"
if ansible-playbook "${TMP}/playbook.yml" >"${TMP}/rollback-failure.log" 2>&1; then
  echo 'rollback restart failure unexpectedly succeeded' >&2
  exit 1
fi
unset TRAFFIC_TEST_FAIL_READINESS TRAFFIC_TEST_FAIL_START_AFTER
cmp "${DB}" "${TMP}/before-rollback-failure.db"
[[ "$(<"${PROJECT}/.wg-traffic-mode")" == full ]]
retained_snapshot="$(find "${PROJECT}" -maxdepth 1 -name '.wg-traffic-mode.transaction.*' -type d -print -quit)"
[[ -n "${retained_snapshot}" && -f "${retained_snapshot}/snapshot-complete" ]]
find "${retained_snapshot}" -depth -delete

python3 - "${DB}" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("ALTER TABLE interfaces_table RENAME TO incompatible_interfaces_table")
PY
before_bad="$(sha256sum "${PROJECT}/volumes/wg-easy/wg0.conf")"
if ansible-playbook "${TMP}/playbook.yml" >"${TMP}/schema.log" 2>&1; then
  echo 'incompatible policy schema unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(sha256sum "${PROJECT}/volumes/wg-easy/wg0.conf")" == "${before_bad}" ]]
grep -Eq 'no such table|policy' "${TMP}/schema.log"

TRAFFIC_TASK="${ROOT}/roles/vps_orchestration/tasks/traffic_mode.yml" python3 - <<'PY'
import os
from pathlib import Path
source=Path(os.environ["TRAFFIC_TASK"]).read_text()
for forbidden in ("DOCKER-USER", "POSTROUTING", "systemctl", "traffic-mode-firewall"):
    if forbidden in source:
        raise SystemExit(f"obsolete host policy remains: {forbidden}")
for required in ("firewall_enabled", "WG_CLIENTS", "vps_orchestration_wg_executable"):
    if required not in source:
        raise SystemExit(f"missing pre-NAT policy invariant: {required}")
PY

printf '[PASS] amneziawg=live_readiness_uses_awg_executable; plain_mode_uses_wg\n'
printf '[PASS] services=private_routes,firewall_enabled,WG_CLIENTS_v4_v6_terminal_drop\n'
printf '[PASS] full=default_routes,firewall_disabled\n'
printf '[PASS] marker_drift=reconciled_from_database\n'
printf '[PASS] converged_live_validation=exec_delta:%s; runtime_drift_repair=mutation_delta:%s\n' "${live_check_delta}" "${runtime_drift_mutation_delta}"
printf '[PASS] existing_peer_catch_all=overridden_by_global_firewall_ips\n'
printf '[PASS] readiness=actual_wg0; rollback=whole_volume_and_marker_restored\n'
printf '[PASS] existing_marker_rollback=byte_restored,restart_delta:%s,transaction_residue:0\n' "$((rollback_start_count_after - rollback_start_count_before))"
printf '[PASS] absent_marker_rollback=marker_absent:true,restart_delta:%s,transaction_residue:%s,rollback_complete:true\n' \
  "${absent_marker_restart_delta}" "${absent_marker_transaction_count}"
printf '[PASS] absent_marker_partial_snapshot=source_untouched,marker_absent:true,restart_delta:%s,transaction_residue:0\n' \
  "${absent_partial_restart_delta}"
printf '[PASS] post_marker_fault=db_sha256:%s,marker_sha256:%s,transactions:%s\n' "${post_marker_db_sha}" "${post_marker_state_sha}" "${post_marker_transaction_count}"
printf '[PASS] partial_snapshot=source_untouched,no_restore_from_incomplete_copy; commit_residue=rejected\n'
printf '[PASS] rollback_restart_failure=private_complete_snapshot_retained_for_operator_recovery\n'
printf '[PASS] incompatible_schema=failed_before_mutation; host_nat_policy=absent\n'
printf '[PASS] project_root=root,relative,parent_segment rejected_before_filesystem_access\n'
