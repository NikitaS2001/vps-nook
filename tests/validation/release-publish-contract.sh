#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-publish.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT INT TERM
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

mkdir -p "${tmp}/work/scripts" "${tmp}/bin" "${tmp}/fixture"
cp "${ROOT_DIR}/scripts/publish-release.sh" "${tmp}/work/scripts/"
printf 'fixture\n' >"${tmp}/fixture/payload"
cat >"${tmp}/work/scripts/release-contract.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"${tmp}/work/scripts/build-release-artifacts.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
output=''
while (($#)); do
    if [[ "$1" == --output ]]; then output="$2"; fi
    shift 2
done
cp "${FIXTURE_ASSETS}"/* "${output}/"
SH
cat >"${tmp}/bin/git" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-} ${2:-}" in
    'remote get-url') printf '%s\n' "${REMOTE_URL}" ;;
    'fetch --no-tags') exit 0 ;;
    'ls-remote --exit-code') printf '%s\trefs/tags/v1.3.0\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
    'rev-parse --verify') printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
    'rev-parse v1.3.0^{commit}') printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
    *) printf 'unexpected git call: %s\n' "$*" >&2; exit 90 ;;
esac
SH
cat >"${tmp}/bin/gh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${GH_CALL_LOG}"
case "${1:-} ${2:-}" in
    'auth status') exit 0 ;;
    'repo view') printf 'NikitaS2001/vps-nook\n' ;;
    'api --method') printf '%s\n' "${IMMUTABLE_ENABLED}" ;;
    'api /repos/NikitaS2001/vps-nook/releases/latest')
        if [[ "${PUBLISH_MODE}" == latest-mismatch ]]; then
            printf 'v1.2.9\n'
        else
            printf 'v1.3.0\n'
        fi
        ;;
    'release view') printf 'v1.3.0\n' ;;
    'release download')
        while (($#)); do
            if [[ "$1" == --dir ]]; then
                cp "${FIXTURE_ASSETS}"/* "$2/"
                break
            fi
            shift
        done
        ;;
    'attestation verify')
        [[ "${PUBLISH_MODE}" != attestation-failure ]] || exit 41
        ;;
    'release edit') printf 'published\n' >"${PUBLISHED_SENTINEL}" ;;
    'release verify')
        [[ "${PUBLISH_MODE}" != post-publish-failure ]] || exit 42
        ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 91 ;;
esac
SH
chmod 0755 "${tmp}/work/scripts/"*.sh "${tmp}/bin/git" "${tmp}/bin/gh"

run_fixture() {
    local mode="$1" immutable="$2" remote_url="$3"
    local log="${tmp}/${mode}.log" published="${tmp}/${mode}.published" status=0
    (
        cd "${tmp}/work"
        PATH="${tmp}/bin:${PATH}" \
            FIXTURE_ASSETS="${tmp}/fixture" \
            GH_CALL_LOG="${log}" \
            IMMUTABLE_ENABLED="${immutable}" \
            PUBLISH_MODE="${mode}" \
            PUBLISHED_SENTINEL="${published}" \
            REMOTE_URL="${remote_url}" \
            scripts/publish-release.sh v1.3.0
    ) >/dev/null 2>&1 || status=$?
    case "${mode}" in
        wrong-repository)
            ((status != 0)) || fail 'wrong repository passed'
            [[ ! -e "${log}" && ! -e "${published}" ]] \
                || fail 'wrong repository reached GitHub or publication'
            ;;
        immutable-disabled)
            ((status != 0)) || fail 'disabled immutability passed'
            [[ ! -e "${published}" ]] || fail 'disabled immutability published'
            ! grep -Fq 'release edit' "${log}" || fail 'disabled immutability reached publication'
            ;;
        attestation-failure)
            ((status != 0)) || fail 'failed attestation passed'
            [[ ! -e "${published}" ]] || fail 'failed attestation published'
            ;;
        post-publish-failure)
            ((status != 0)) || fail 'post-publish failure passed'
            [[ -s "${published}" ]] || fail 'post-publish fixture never published'
            ! grep -Fq 'release delete' "${log}" || fail 'publisher deleted after publication'
            ;;
        latest-mismatch)
            ((status != 0)) || fail 'latest release mismatch passed'
            [[ -s "${published}" ]] || fail 'latest mismatch fixture never published'
            grep -Fq 'api /repos/NikitaS2001/vps-nook/releases/latest' "${log}" \
                || fail 'publisher skipped latest release verification'
            ! grep -Fq 'release delete' "${log}" || fail 'publisher deleted after latest mismatch'
            ;;
        success)
            ((status == 0)) || fail 'valid publication failed'
            [[ -s "${published}" ]] || fail 'valid publication did not publish'
            grep -Fq 'release verify v1.3.0' "${log}" \
                || fail 'valid publication skipped release verification'
            grep -Fq 'api /repos/NikitaS2001/vps-nook/releases/latest' "${log}" \
                || fail 'valid publication skipped latest release verification'
            ! grep -Fq 'release delete' "${log}" || fail 'valid publication deleted release'
            ;;
    esac
}

canonical='https://github.com/NikitaS2001/vps-nook.git'
run_fixture wrong-repository true https://github.com/example/other.git
run_fixture immutable-disabled false "${canonical}"
run_fixture attestation-failure true "${canonical}"
run_fixture post-publish-failure true "${canonical}"
run_fixture latest-mismatch true "${canonical}"
run_fixture success true "${canonical}"

! grep -En 'GH_TOKEN=|github_pat_|secrets\.' "${ROOT_DIR}/scripts/publish-release.sh" >/dev/null \
    || fail 'publisher contains stored-token plumbing'
printf '[PASS] repository, immutability, attestation, latest selection, monotonicity, and success fixtures\n'
printf 'RELEASE PUBLISH CONTRACT PASS\n'
