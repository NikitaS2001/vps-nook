#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly ROOT_DIR="${WORKFLOW_CONTRACT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"

fail() {
    printf 'workflow-contract: %s\n' "$*" >&2
    exit 1
}

validate_entrypoints() {
    [[ -x ${ROOT_DIR}/scripts/bootstrap.sh ]] || fail 'scripts/bootstrap.sh is not executable'
    [[ -x ${ROOT_DIR}/scripts/check.sh ]] || fail 'scripts/check.sh is not executable'
    "${ROOT_DIR}/scripts/check.sh" --help >/dev/null 2>&1
    if "${ROOT_DIR}/scripts/check.sh" --unknown >/dev/null 2>&1; then
        fail 'scripts/check.sh accepted an unknown mode'
    fi
}

validate_workflows() {
    WORKFLOW_ROOT="${ROOT_DIR}" python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

import yaml

root = Path(os.environ["WORKFLOW_ROOT"])
workflow_dir = root / ".github" / "workflows"
required = {"ci.yml", "weekly.yml", "scorecard.yml"}
present = {path.name for path in workflow_dir.glob("*.yml")}
missing = required - present
if missing:
    sys.exit(f"workflow-contract: missing workflows: {', '.join(sorted(missing))}")
if "security.yml" in present:
    sys.exit("workflow-contract: legacy security.yml remains")

documents = {}
for name in present:
    path = workflow_dir / name
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        sys.exit(f"workflow-contract: {name} did not safe-load: {error}")
    if not isinstance(document, dict) or not isinstance(document.get("jobs"), dict):
        sys.exit(f"workflow-contract: {name} has no jobs mapping")
    documents[name] = document

    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not re.search(r"\buses:\s*", line):
            continue
        match = re.search(r"uses:\s*[^@\s]+@([0-9a-f]{40})\s+#\s+v\S+", line)
        if not match:
            sys.exit(f"workflow-contract: {name}:{line_number} action is not pinned to a full SHA with version comment")

ci = documents["ci.yml"]
if ci.get("permissions") != {"contents": "read"}:
    sys.exit("workflow-contract: ci.yml permissions are not contents: read")
ci_jobs = ci["jobs"]
if set(ci_jobs) != {"static", "qemu"}:
    sys.exit("workflow-contract: ci.yml must contain only static and qemu jobs")
static_runs = [step.get("run") for step in ci_jobs["static"].get("steps", [])]
if static_runs.count("scripts/bootstrap.sh") != 1 or static_runs.count("scripts/check.sh") != 1:
    sys.exit("workflow-contract: CI static job does not use both contributor entrypoints exactly once")
includes = ci_jobs["qemu"].get("strategy", {}).get("matrix", {}).get("include", [])
if {row.get("os") for row in includes} != {"debian-12", "ubuntu-24.04"}:
    sys.exit("workflow-contract: CI QEMU matrix is not Debian 12 plus Ubuntu 24.04")
service_steps = [step for step in ci_jobs["qemu"].get("steps", []) if step.get("name") == "Run services E2E"]
if len(service_steps) != 1 or "services" not in str(service_steps[0]):
    sys.exit("workflow-contract: CI does not explicitly run services")

weekly = documents["weekly.yml"]
triggers = weekly.get("on", {})
if triggers.get("schedule") != [{"cron": "17 2 * * 1"}] or "workflow_dispatch" not in triggers:
    sys.exit("workflow-contract: Weekly must run on Mondays at 02:17 UTC and support manual dispatch")
if "nightly.yml" in present:
    sys.exit("workflow-contract: obsolete nightly.yml remains")
if weekly.get("permissions") != {"contents": "read"}:
    sys.exit("workflow-contract: weekly.yml permissions are not contents: read")
weekly_jobs = weekly["jobs"]
if set(weekly_jobs) != {"qemu", "lifecycle"}:
    sys.exit("workflow-contract: weekly.yml lacks QEMU or lifecycle jobs")
matrix = weekly_jobs["qemu"].get("strategy", {}).get("matrix", {})
includes = matrix.get("include", [])
if {row.get("os") for row in includes} != {"debian-12", "ubuntu-24.04"}:
    sys.exit("workflow-contract: weekly OS matrix is incomplete")
service_steps = [step for step in weekly_jobs["qemu"].get("steps", []) if step.get("name") == "Run services E2E"]
if len(service_steps) != 1 or service_steps[0].get("env", {}).get("NOOK_WG_TRAFFIC_MODE") != "services":
    sys.exit("workflow-contract: generic hosted weekly must use services")
lifecycle_runs = [step.get("run", "") for step in weekly_jobs["lifecycle"].get("steps", [])]
if lifecycle_runs.count(".venv/bin/pytest -m lifecycle --junitxml=reports/lifecycle.xml") != 1:
    sys.exit("workflow-contract: weekly lifecycle does not test upgrade and restore")

for name, jobs in (("ci", ci_jobs), ("weekly", weekly_jobs)):
    for job_name, job in jobs.items():
        steps = job.get("steps", [])
        if sum(step.get("run") == "scripts/bootstrap.sh" for step in steps) != 1:
            sys.exit("workflow-contract: each test job must bootstrap pinned tools")
        uploads = [step for step in steps if "actions/upload-artifact@" in step.get("uses", "")]
        if len(uploads) != 1 or uploads[0].get("if") != "always()":
            sys.exit("workflow-contract: every test job needs an unconditional JUnit upload")
        artifact = uploads[0].get("with", {})
        if artifact.get("retention-days") != 7 or not artifact.get("path", "").startswith("reports/"):
            sys.exit("workflow-contract: upload only test summaries for seven days")
        if job_name == "qemu":
            if job.get("timeout-minutes") != 80:
                sys.exit("workflow-contract: QEMU needs 80 minutes including cleanup/reporting")
            if sum(step.get("run") == ".venv/bin/pytest -m qemu --junitxml=reports/qemu.xml" for step in steps) != 1:
                sys.exit("workflow-contract: QEMU must use the pytest adapter")
if ci_jobs["qemu"].get("needs") != "static":
    sys.exit("workflow-contract: QEMU must follow quick checks")

scorecard = documents["scorecard.yml"]
analysis = scorecard["jobs"].get("analysis", {})
permissions = analysis.get("permissions", {})
if permissions != {"contents": "read", "security-events": "write"}:
    sys.exit("workflow-contract: Scorecard permissions are not least-privilege for SARIF")
score_steps = analysis.get("steps", [])
score = next((step for step in score_steps if "ossf/scorecard-action@" in step.get("uses", "")), None)
if not score or score.get("continue-on-error") is not True or score.get("with", {}).get("publish_results") is not False:
    sys.exit("workflow-contract: Scorecard is not advisory")
PY
}

self_test() {
    validate_entrypoints
    validate_workflows
    printf 'workflow-contract self-test: PASS\n' >&2
}

case "${1:-}" in
    '') validate_entrypoints; validate_workflows ;;
    --self-test) [[ $# -eq 1 ]] || fail 'self-test accepts no additional arguments'; self_test ;;
    *) fail 'usage: workflow-contract.sh [--self-test]' ;;
esac

printf '{"entrypoints":true,"workflows":true,"sha_pins":true}\n'
