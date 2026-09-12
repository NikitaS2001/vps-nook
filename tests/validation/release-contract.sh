#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-contract.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT INT TERM

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
reject() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then fail "accepted ${label}"; fi
    printf '[PASS] rejected %s\n' "${label}"
}

repo="${tmp}/repo"
mkdir -p "${repo}/scripts" "${repo}/.github"
cp "${ROOT_DIR}/scripts/release-contract.sh" "${repo}/scripts/"
cp "${ROOT_DIR}/install.sh" "${ROOT_DIR}/requirements.yml" \
    "${ROOT_DIR}/CHANGELOG.md" "${repo}/"
sed -i 's/^## \[v2\.0\.0\] - [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$/## [v2.0.0] - Unreleased/' \
    "${repo}/CHANGELOG.md"
key="${tmp}/signer"
wrong_key="${tmp}/wrong"
ssh-keygen -q -t ed25519 -N '' -f "${key}"
ssh-keygen -q -t ed25519 -N '' -f "${wrong_key}"
identity='release-fixture@example.invalid'
sed -i \
    -e 's/^readonly OFFICIAL_RELEASE_REF=.*/readonly OFFICIAL_RELEASE_REF="v2.0.0"/' \
    -e "s/^readonly OFFICIAL_SIGNER_IDENTITY=.*/readonly OFFICIAL_SIGNER_IDENTITY=\"${identity}\"/" \
    -e "s#^readonly OFFICIAL_SIGNER_PUBLIC_KEY=.*#readonly OFFICIAL_SIGNER_PUBLIC_KEY=\"$(<"${key}.pub")\"#" \
    "${repo}/install.sh"
printf '%s %s\n' "${identity}" "$(<"${key}.pub")" >"${repo}/.github/release-allowed-signers"
git -C "${repo}" init -q
git -C "${repo}" config user.name 'Release Fixture'
git -C "${repo}" config user.email "${identity}"
git -C "${repo}" add .
git -C "${repo}" -c commit.gpgsign=false commit -qm fixture
remote="${tmp}/remote.git"
git init -q --bare "${remote}"
git -C "${repo}" remote add origin "${remote}"
git -C "${repo}" push -q origin HEAD:main
git -C "${repo}" fetch -q origin '+refs/heads/main:refs/remotes/origin/main'

sign() {
    local signing_key="${1:-${key}}"
    git -C "${repo}" -c gpg.format=ssh -c user.signingkey="${signing_key}" \
        tag -sam fixture v2.0.0
}
run_tag() {
    GITHUB_REF_NAME=v2.0.0 "${repo}/scripts/release-contract.sh" --tag
}

"${repo}/scripts/release-contract.sh" --pr
sign
reject unreleased-changelog run_tag
git -C "${repo}" tag -d v2.0.0 >/dev/null
sed -i 's/^## \[v2\.0\.0\] - Unreleased$/## [v2.0.0] - 2026-08-31/' \
    "${repo}/CHANGELOG.md"
git -C "${repo}" add CHANGELOG.md
git -C "${repo}" -c commit.gpgsign=false commit -qm 'date release'
git -C "${repo}" push -q origin HEAD:main
git -C "${repo}" fetch -q origin '+refs/heads/main:refs/remotes/origin/main'
sha="$(git -C "${repo}" rev-parse HEAD)"
sign
output="$(run_tag)"
grep -Fq "trusted SSH-signed tag v2.0.0 at ${sha}" <<<"${output}" \
    || fail 'valid tag lacks exact trust result'
printf '[PASS] trusted annotated SSH tag\n'

git -C "${repo}" tag -d v2.0.0 >/dev/null
git -C "${repo}" tag v2.0.0
reject lightweight-tag run_tag
git -C "${repo}" tag -d v2.0.0 >/dev/null
sign "${wrong_key}"
reject wrong-key-tag run_tag
git -C "${repo}" tag -d v2.0.0 >/dev/null
git -C "${repo}" config user.email wrong-tagger@example.invalid
sign
reject wrong-tagger-identity run_tag
git -C "${repo}" tag -d v2.0.0 >/dev/null
git -C "${repo}" config user.email "${identity}"
sign
printf 'dirty\n' >"${repo}/untracked"
reject dirty-worktree run_tag
rm "${repo}/untracked"
printf 'new head\n' >>"${repo}/CHANGELOG.md"
git -C "${repo}" add CHANGELOG.md
git -C "${repo}" -c commit.gpgsign=false commit -qm 'new head'
reject tag-not-at-head run_tag
git -C "${repo}" push -q origin HEAD:main
git -C "${repo}" fetch -q origin '+refs/heads/main:refs/remotes/origin/main'
git -C "${repo}" checkout -q --detach v2.0.0
reject tag-not-origin-main run_tag

printf 'RELEASE CONTRACT PASS\n'
