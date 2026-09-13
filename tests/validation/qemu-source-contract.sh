#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly ROOT_DIR
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qemu-source-contract.XXXXXX")"
readonly TMP_DIR
trap 'find "${TMP_DIR}" -depth -delete' EXIT

git -C "${TMP_DIR}" init -q -b main
printf 'kept\n' >"${TMP_DIR}/kept"
printf 'deleted\n' >"${TMP_DIR}/deleted"
git -C "${TMP_DIR}" add kept deleted
git -C "${TMP_DIR}" -c user.name=test -c user.email=test.invalid -c commit.gpgsign=false \
    commit -qm fixture
find "${TMP_DIR}/deleted" -delete
printf 'untracked\n' >"${TMP_DIR}/untracked"

mapfile -d '' -t paths < <(
    "${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-source-list "${TMP_DIR}"
)
printf '%s\n' "${paths[@]}" | sort >"${TMP_DIR}/actual"
printf '%s\n' kept untracked >"${TMP_DIR}/expected"
cmp "${TMP_DIR}/expected" "${TMP_DIR}/actual" || {
    printf 'qemu-source-contract: source list included a deletion or lost an existing path\n' >&2
    exit 1
}

# Later edits must not change either the deployed tree or its client checks.
"${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-source-snapshot "${TMP_DIR}" "${TMP_DIR}/snapshot"
printf 'changed after snapshot\n' >"${TMP_DIR}/kept"
[[ $(<"${TMP_DIR}/snapshot/kept") == kept && -f ${TMP_DIR}/snapshot/untracked && ! -e ${TMP_DIR}/snapshot/deleted ]] || {
    printf 'qemu-source-contract: snapshot is not isolated from later working-tree changes\n' >&2
    exit 1
}
# Literal source contracts, not shell expansion.
# shellcheck disable=SC2016
grep -Fq 'tar -C "${SOURCE_DIR}" -czf - .' "${ROOT_DIR}/tests/e2e/qemu-install.sh"
# shellcheck disable=SC2016
grep -Fq '< "${SOURCE_DIR}/tests/e2e/client-in-guest.sh"' "${ROOT_DIR}/tests/e2e/qemu-install.sh"

fresh_env="$("${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-installer-env fresh)"
for credential in \
    NOOK_ADMIN_PASSWORD \
    NOOK_ADGUARD_PASSWORD \
    NOOK_WG_PASSWORD \
    NOOK_SSH_PUBKEY; do
    [[ ${fresh_env} == *"${credential}="* ]] \
        || { printf 'qemu-source-contract: fresh install omitted %s\n' "${credential}" >&2; exit 1; }
done
bash -c "env ${fresh_env} sh -c '\
    test \"\$NOOK_ADMIN_PASSWORD\" = \"admin'\''secret\" && \
    test \"\$NOOK_ADGUARD_PASSWORD\" = \"adguard secret\" && \
    test \"\$NOOK_WG_PASSWORD\" = '\''wg\$secret'\'' && \
    test \"\$NOOK_SSH_PUBKEY\" = \"ssh-ed25519 AAAA fixture\"'" || {
    printf 'qemu-source-contract: fresh credential environment did not round-trip\n' >&2
    exit 1
}
existing_env="$("${ROOT_DIR}/tests/e2e/qemu-install.sh" --self-test-installer-env existing)"
[[ -z ${existing_env} ]] || {
    printf 'qemu-source-contract: existing-state rerun exposed credential inputs\n' >&2
    exit 1
}
[[ "$(grep -c 'id_ed25519" existing' "${ROOT_DIR}/tests/e2e/qemu-install.sh")" -eq 3 ]] || {
    printf 'qemu-source-contract: retry paths are not explicitly existing-state reruns\n' >&2
    exit 1
}
grep -Fq "'sudo cat /opt/vps-nook/.wg-traffic-mode'" \
    "${ROOT_DIR}/tests/e2e/common.sh" || {
    printf 'qemu-source-contract: traffic mode must be read with privilege\n' >&2
    exit 1
}
grep -Fq "sh -c 'cd /opt/vps-nook-installer/repo" \
    "${ROOT_DIR}/tests/e2e/qemu-install.sh" || {
    printf 'qemu-source-contract: root-only installer checkout must be entered with privilege\n' >&2
    exit 1
}
grep -Fq -- '--extra-vars @/etc/vps-nook/installer-vault.yml' \
    "${ROOT_DIR}/tests/e2e/qemu-install.sh" || {
    printf 'qemu-source-contract: direct playbook runs must load encrypted installer state\n' >&2
    exit 1
}
grep -Fq 'if ! sudo test -s /etc/vps-nook/installer-vault.yml; then' \
    "${ROOT_DIR}/tests/e2e/run-public-install.sh" || {
    printf 'qemu-source-contract: public VPS reruns must omit fresh credential inputs\n' >&2
    exit 1
}
# These assertions intentionally match literal command substitutions in the harness.
# shellcheck disable=SC2016
if grep -Fq '\$(stat -c %a /etc/vps-nook)' \
    "${ROOT_DIR}/tests/e2e/run-public-install.sh"; then
    printf 'qemu-source-contract: private installer state must be inspected through sudo\n' >&2
    exit 1
fi
# shellcheck disable=SC2016
grep -Fq '\$(sudo stat -c %a /etc/vps-nook)' \
    "${ROOT_DIR}/tests/e2e/run-public-install.sh" || {
    printf 'qemu-source-contract: installer state directory mode check is missing\n' >&2
    exit 1
}
# shellcheck disable=SC2016
grep -Fq 'command -v nc >/dev/null || fail "nc not found"' \
    "${ROOT_DIR}/tests/e2e/run-public-install.sh" || {
    printf 'qemu-source-contract: public port probe prerequisite is not enforced\n' >&2
    exit 1
}
# shellcheck disable=SC2016
grep -Fq 'if timeout 6 nc -z -w 5 "${VPS_IP}" 443' \
    "${ROOT_DIR}/tests/e2e/run-public-install.sh" || {
    printf 'qemu-source-contract: public port probe must have an outer timeout\n' >&2
    exit 1
}
installer_release_ref="$(sed -n 's/^readonly OFFICIAL_RELEASE_REF="\([^"]*\)"$/\1/p' \
    "${ROOT_DIR}/install.sh")"
# Fixture intentionally matches the literal command substitution in the E2E source.
# shellcheck disable=SC2016
grep -Fq 'INSTALLER_RELEASE_REF="$(sed -n' "${ROOT_DIR}/tests/e2e/qemu-install.sh" \
    || { printf 'qemu-source-contract: production release assertion is not installer-derived\n' >&2; exit 1; }
# shellcheck disable=SC2016
grep -Fq 'Verified signed release tag ${INSTALLER_RELEASE_REF' \
    "${ROOT_DIR}/tests/e2e/qemu-install.sh" \
    || { printf 'qemu-source-contract: production provenance does not use installer release ref %s\n' \
        "${installer_release_ref}" >&2; exit 1; }
grep -Fq '"fd42:42:42::5/128"' \
    "${ROOT_DIR}/tests/e2e/external-client-qemu.sh" || {
    printf 'qemu-source-contract: external peer fixture must provide valid dual-stack addresses\n' >&2
    exit 1
}

printf 'qemu-source-contract: source filter and credential-free rerun PASS\n'
