#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY='NikitaS2001/vps-nook'

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }

[[ $# -eq 1 && "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "usage: $0 vX.Y.Z"
tag="$1"
cd "${ROOT_DIR}"

remote_url="$(git remote get-url origin 2>/dev/null || true)"
case "${remote_url}" in
    "https://github.com/${REPOSITORY}.git" | \
    "git@github.com:${REPOSITORY}.git" | \
    "ssh://git@github.com/${REPOSITORY}.git") ;;
    *) fail "origin is not the canonical ${REPOSITORY} repository" ;;
esac
gh auth status --hostname github.com >/dev/null \
    || fail "gh is not authenticated to github.com"
[[ "$(gh repo view "${REPOSITORY}" --json nameWithOwner --jq '.nameWithOwner')" == "${REPOSITORY}" ]] \
    || fail "gh repository identity mismatch"

git fetch --no-tags --force origin '+refs/heads/main:refs/remotes/origin/main'
remote_tag_object="$(git ls-remote --exit-code origin "refs/tags/${tag}" | awk 'NR == 1 {print $1}')" \
    || fail "release tag is not present on origin"
local_tag_object="$(git rev-parse --verify "refs/tags/${tag}" 2>/dev/null || true)"
[[ -n "${local_tag_object}" && "${remote_tag_object}" == "${local_tag_object}" ]] \
    || fail "local and remote release tag objects differ"
GITHUB_REF_NAME="${tag}" scripts/release-contract.sh --tag
sha="$(git rev-parse "${tag}^{commit}")"

enabled="$(gh api \
    --method GET \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    "/repos/${REPOSITORY}/immutable-releases" \
    --jq '.enabled')" \
    || fail "cannot read repository release immutability"
[[ "${enabled}" == true ]] \
    || fail "repository release immutability must be enabled before publication"
pass "repository release immutability is enabled"

[[ "$(gh release view "${tag}" --repo "${REPOSITORY}" \
    --json isDraft,tagName --jq 'select(.isDraft == true) | .tagName')" == "${tag}" ]] \
    || fail "release must exist as an unpublished draft for the exact tag"

workspace="$(mktemp -d "${TMPDIR:-/tmp}/publish-release.XXXXXX")"
cleanup() { rm -rf -- "${workspace}"; }
trap cleanup EXIT INT TERM
mkdir "${workspace}/local" "${workspace}/draft" "${workspace}/published"
scripts/build-release-artifacts.sh \
    --tag "${tag}" --sha "${sha}" --output "${workspace}/local"
gh release download "${tag}" --repo "${REPOSITORY}" --dir "${workspace}/draft"
scripts/release-contract.sh \
    --assets "${workspace}/draft" --tag "${tag}" --sha "${sha}"
for asset in "${workspace}/local"/*; do
    name="$(basename "${asset}")"
    cmp -- "${asset}" "${workspace}/draft/${name}" \
        || fail "draft asset bytes differ: ${name}"
    gh attestation verify "${workspace}/draft/${name}" \
        --repo "${REPOSITORY}" \
        --signer-workflow "${REPOSITORY}/.github/workflows/release.yml" \
        --source-ref "refs/tags/${tag}" \
        --source-digest "${sha}" >/dev/null \
        || fail "draft asset attestation failed: ${name}"
done
pass "draft tag, assets, checksums, and attestations are verified"

gh release edit "${tag}" --repo "${REPOSITORY}" \
    --draft=false --latest --verify-tag
gh release verify "${tag}" --repo "${REPOSITORY}" \
    || fail "published release attestation verification failed"
[[ "$(gh release view "${tag}" --repo "${REPOSITORY}" \
    --json isDraft,isImmutable,tagName \
    --jq 'select(.isDraft == false and .isImmutable == true) | .tagName')" == "${tag}" ]] \
    || fail "published release is not immutable"
gh release download "${tag}" --repo "${REPOSITORY}" --dir "${workspace}/published"
scripts/release-contract.sh \
    --assets "${workspace}/published" --tag "${tag}" --sha "${sha}"
for asset in "${workspace}/local"/*; do
    name="$(basename "${asset}")"
    cmp -- "${asset}" "${workspace}/published/${name}" \
        || fail "published asset bytes differ: ${name}"
done
pass "immutable release ${tag} is published and verified"
