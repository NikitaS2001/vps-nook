#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="${ROOT_DIR}/.github/workflows/release.yml"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-workflow.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT INT TERM
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

python3 - "${workflow}" "${tmp}/draft.sh" <<'PY'
import re
import sys
from pathlib import Path
import yaml

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
document = yaml.safe_load(text)
assert document.get("permissions") == {"contents": "read"}
job = document["jobs"]["draft"]
assert job["permissions"] == {
    "artifact-metadata": "write",
    "attestations": "write",
    "contents": "write",
    "id-token": "write",
}
uses = [step["uses"] for step in job["steps"] if "uses" in step]
assert uses and all(re.fullmatch(r"[^@]+@[0-9a-f]{40}", item) for item in uses)
assert any(item.startswith("actions/attest@") for item in uses)
runs = {step.get("name"): step["run"] for step in job["steps"] if "run" in step}
source = runs["Verify signed tag and protected source branch"]
draft = runs["Create and verify draft release"]
assert "'+refs/heads/main:refs/remotes/origin/main'" in source
assert source.index("git fetch") < source.index("release-contract.sh --tag")
assert "subject-path: release/*" in text
assert "gh release create" in draft and "--draft" in draft
assert "gh release download" in draft and "cmp --" in draft
assert "draft_verified=true" in draft
assert '"${draft_created}" == true && "${draft_verified}" == false' in draft
for forbidden in (
    "immutable-releases", "gh release edit", "gh release verify", "published=true",
    "SHA256SUMS.sig", "user.signingkey", "PRIVATE_KEY", "git tag ",
    "candidate", "final-verify", "wheelhouse", ".omo/",
):
    assert forbidden not in text, forbidden
Path(sys.argv[2]).write_text(draft, encoding="utf-8")
PY

mkdir -p "${tmp}/work/release" "${tmp}/work/scripts" "${tmp}/bin" "${tmp}/runner"
printf 'payload\n' >"${tmp}/work/release/payload"
cat >"${tmp}/work/scripts/release-contract.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"${tmp}/bin/gh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${GH_CALL_LOG}"
case "${1:-} ${2:-}" in
    'release create') exit 0 ;;
    'release download')
        [[ "${GH_MODE}" != draft-failure ]] || exit 41
        while (($#)); do
            if [[ "$1" == --dir ]]; then
                cp "${FIXTURE_RELEASE}"/* "$2/"
                break
            fi
            shift
        done
        ;;
    'release delete') printf 'delete\n' >"${GH_DELETE_SENTINEL}" ;;
    *) exit 90 ;;
esac
SH
chmod 0755 "${tmp}/draft.sh" "${tmp}/work/scripts/release-contract.sh" "${tmp}/bin/gh"

run_draft_fixture() {
    local mode="$1" log="${tmp}/${1}.log" sentinel="${tmp}/${1}.delete"
    local status=0
    (
        cd "${tmp}/work"
        PATH="${tmp}/bin:${PATH}" \
            RUNNER_TEMP="${tmp}/runner" \
            GITHUB_STEP_SUMMARY="${tmp}/${mode}.summary" \
            TAG=v1.3.0 \
            GITHUB_REPOSITORY=NikitaS2001/vps-nook \
            GITHUB_SHA=0000000000000000000000000000000000000000 \
            GH_CALL_LOG="${log}" \
            GH_DELETE_SENTINEL="${sentinel}" \
            GH_MODE="${mode}" \
            FIXTURE_RELEASE="${tmp}/work/release" \
            bash "${tmp}/draft.sh"
    ) >/dev/null 2>&1 || status=$?
    case "${mode}" in
        draft-failure)
            ((status != 0)) || fail 'failed draft fixture passed'
            [[ -s "${sentinel}" ]] || fail 'failed draft was not cleaned up'
            ;;
        success)
            ((status == 0)) || fail 'verified draft fixture failed'
            [[ ! -e "${sentinel}" ]] || fail 'verified draft was deleted before handoff'
            grep -Fq 'Verified draft ready' "${tmp}/${mode}.summary" \
                || fail 'verified draft handoff was not reported'
            ! grep -Eq 'release (edit|verify)' "${log}" \
                || fail 'workflow published or verified a public release'
            ;;
    esac
}

run_draft_fixture draft-failure
run_draft_fixture success
printf '[PASS] failed-draft cleanup and verified-draft handoff\n'
printf 'RELEASE WORKFLOW CONTRACT PASS\n'
