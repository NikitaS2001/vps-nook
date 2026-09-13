#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }
isolated_git() {
    env -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS \
        GIT_NO_REPLACE_OBJECTS=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_COUNT=0 \
        git "$@"
}

mode="${1:---pr}"
asset_dir=''
asset_tag=''
asset_sha=''
case "${mode}" in
    --pr | --tag)
        [[ $# -eq 1 ]] || fail "usage: $0 ${mode}"
        ;;
    --assets)
        shift
        [[ $# -ge 1 ]] || fail "usage: $0 --assets DIR --tag TAG --sha SHA"
        asset_dir="$1"
        shift
        while (($#)); do
            (($# >= 2)) || fail "usage: $0 --assets DIR --tag TAG --sha SHA"
            case "$1" in
                --tag) asset_tag="$2" ;;
                --sha) asset_sha="$2" ;;
                *) fail "usage: $0 --assets DIR --tag TAG --sha SHA" ;;
            esac
            shift 2
        done
        ;;
    *) fail "usage: $0 [--pr|--tag|--assets DIR --tag TAG --sha SHA]" ;;
esac

release_ref="$(sed -nE 's/^readonly OFFICIAL_RELEASE_REF="([^"]+)"$/\1/p' install.sh)"
signer_identity="$(sed -nE 's/^readonly OFFICIAL_SIGNER_IDENTITY="([^"]+)"$/\1/p' install.sh)"
signer_public_key="$(sed -nE 's/^readonly OFFICIAL_SIGNER_PUBLIC_KEY="([^"]+)"$/\1/p' install.sh)"
[[ "${release_ref}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "installer release ref must be a vX.Y.Z tag"
[[ -n "${signer_identity}" && -n "${signer_public_key}" ]] \
    || fail "installer release signer is incomplete"

allowed_signers='.github/release-allowed-signers'
expected_signer="${signer_identity} ${signer_public_key}"
[[ -f "${allowed_signers}" && ! -L "${allowed_signers}" ]] \
    || fail "${allowed_signers} must be a regular file"
[[ "$(<"${allowed_signers}")" == "${expected_signer}" \
    && "$(wc -l <"${allowed_signers}")" -eq 1 ]] \
    || fail "${allowed_signers} must contain only the installer signer"
pass "release signer is pinned once"

if [[ "${mode}" == '--assets' ]]; then
    [[ -d "${asset_dir}" && ! -L "${asset_dir}" ]] \
        || fail "asset input must be a regular directory"
    [[ "${asset_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ \
        && "${asset_sha}" =~ ^[0-9a-f]{40}$ ]] \
        || fail "asset tag or source SHA is invalid"
    expected_names=$'CHANGELOG.md\nRELEASE_NOTES.md\nSHA256SUMS\nUPGRADE.md\ninstall.sh\ninstall.sh.sha256\nsbom.spdx.json'
    actual_names="$(find "${asset_dir}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
    [[ "${actual_names}" == "${expected_names}" ]] \
        || fail "release assets must match the seven-file allowlist"
    [[ -z "$(find "${asset_dir}" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] \
        || fail "release assets must be regular files"
    [[ -z "$(find "${asset_dir}" -mindepth 1 -maxdepth 1 -type f -links +1 -print -quit)" ]] \
        || fail "release assets must not be hard linked"

    expected_manifest=$'CHANGELOG.md\nRELEASE_NOTES.md\nUPGRADE.md\ninstall.sh\ninstall.sh.sha256\nsbom.spdx.json'
    manifest_names="$(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {print $2}' "${asset_dir}/SHA256SUMS")"
    [[ "$(wc -l <"${asset_dir}/SHA256SUMS")" -eq 6 \
        && "${manifest_names}" == "${expected_manifest}" ]] \
        || fail "SHA256SUMS must list the six payloads in bytewise order"
    (cd "${asset_dir}" && sha256sum --check --strict SHA256SUMS >/dev/null) \
        || fail "release payload checksum mismatch"
    [[ "$(grep -E '^[0-9a-f]{64}  install\.sh$' "${asset_dir}/SHA256SUMS")" \
        == "$(<"${asset_dir}/install.sh.sha256")" ]] \
        || fail "installer checksum files disagree"

    python3 - "${asset_dir}/sbom.spdx.json" "${asset_tag}" "${asset_sha}" <<'PY'
import json
import sys

path, tag, sha = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
packages = document.get("packages", [])
source = [item for item in packages if item.get("SPDXID") == "SPDXRef-Package-Source"]
valid = (
    document.get("spdxVersion") == "SPDX-2.3"
    and document.get("name") == f"vps-nook-{tag}"
    and document.get("documentNamespace")
        == f"https://github.com/NikitaS2001/vps-nook/releases/download/{tag}/sbom.spdx.json?sha={sha}"
    and len(source) == 1
    and source[0].get("versionInfo") == tag
    and {row.get("algorithm"): row.get("checksumValue") for row in source[0].get("checksums", [])}.get("SHA1") == sha
)
raise SystemExit(0 if valid else 1)
PY
    pass "seven release assets are complete and self-consistent"
    exit 0
fi

changelog_release_line="$(grep -E '^## \[v2\.0\.0\] - (Unreleased|[0-9]{4}-[0-9]{2}-[0-9]{2})$' CHANGELOG.md || true)"
[[ "$(wc -l <<<"${changelog_release_line}")" -eq 1 && -n "${changelog_release_line}" ]] \
    || fail "CHANGELOG must contain one v2.0.0 heading with Unreleased or an ISO release date"
grep -Fxq '## [v1.2.1] - 2026-08-20' CHANGELOG.md \
    || fail "CHANGELOG v1.2.1 date is incorrect"

if ! awk '
    function finish() { if (entry && !pin) exit 1 }
    /^  - name:/ { finish(); entry=1; pin=0; next }
    entry && /^    version: "==[^"]+"[[:space:]]*$/ { pin=1 }
    END { finish() }
' requirements.yml; then
    fail "every Ansible collection must use an exact == version"
fi
pass "structural release contract"

[[ "${mode}" == '--tag' ]] || exit 0

[[ "${changelog_release_line}" =~ ^##\ \[v2\.0\.0\]\ -\ [0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    || fail "tagged CHANGELOG must replace Unreleased with the ISO release date"

tag_name="${GITHUB_REF_NAME:-$(isolated_git describe --tags --exact-match 2>/dev/null || true)}"
[[ "${tag_name}" == "${release_ref}" ]] \
    || fail "tag ${tag_name:-<none>} does not match installer ref ${release_ref}"
[[ "$(isolated_git cat-file -t "refs/tags/${tag_name}" 2>/dev/null || true)" == tag ]] \
    || fail "release tag must be annotated and SSH-signed"
tagger_email="$(isolated_git for-each-ref --format='%(taggeremail)' "refs/tags/${tag_name}")"
[[ "${tagger_email}" == "<${signer_identity}>" ]] \
    || fail "release tagger identity must match the pinned signer principal"
isolated_git \
    -c gpg.format=ssh \
    -c gpg.ssh.allowedSignersFile="${ROOT_DIR}/${allowed_signers}" \
    verify-tag "${tag_name}" >/dev/null 2>&1 \
    || fail "release tag is not signed by the pinned maintainer key"
tag_commit="$(isolated_git rev-parse "${tag_name}^{commit}")"
head_commit="$(isolated_git rev-parse 'HEAD^{commit}')"
[[ "${tag_commit}" == "${head_commit}" ]] \
    || fail "release tag must point at HEAD"
main_commit="$(isolated_git rev-parse --verify 'refs/remotes/origin/main^{commit}' 2>/dev/null || true)"
[[ -n "${main_commit}" && "${tag_commit}" == "${main_commit}" ]] \
    || fail "release tag must point at the fetched origin/main commit"
[[ -z "$(isolated_git status --porcelain=v1 --untracked-files=all)" ]] \
    || fail "tag verification requires a clean worktree"
in_tag_ref="$(isolated_git show "${tag_name}:install.sh" \
    | sed -nE 's/^readonly OFFICIAL_RELEASE_REF="([^"]+)"$/\1/p')"
[[ "${in_tag_ref}" == "${tag_name}" ]] \
    || fail "tagged installer does not reference its own release tag"
pass "trusted SSH-signed tag ${tag_name} at ${tag_commit}"
