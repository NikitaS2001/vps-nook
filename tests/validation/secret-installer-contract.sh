#!/usr/bin/env bash
# Fixture variables and function overrides are consumed by the sourced installer.
# shellcheck disable=SC1091,SC2016,SC2034,SC2317,SC2329
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ztvps-installer-secret.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT HUP INT TERM

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# shellcheck source=../../install.sh
source "${ROOT_DIR}/install.sh"
trap 'rm -rf -- "${TMP}"' EXIT HUP INT TERM

configure_fixture() {
    local state="$1"
    [[ -z "${VAULT_LOCK_FD:-}" ]] || exec {VAULT_LOCK_FD}>&-
    VAULT_DIR="${state}"
    VAULT_PASS_FILE="${state}/installer-vault.pass"
    VAULT_FILE="${state}/installer-vault.yml"
    VAULT_MARKER="${state}/.installer-vault.incomplete"
    VAULT_LOCK_FILE="${state}/.installer.lock"
    VAULT_OWNER="$(id -un)"
    VAULT_ANSIBLE_BIN="$(command -v ansible-vault)"
    VAULT_PYTHON_BIN="$(command -v python3)"
    VAULT_LOCK_FD=""
    EXTRA_VARS_FILE=""
    VAULT_PLAIN_FILE=""
    VAULT_PASS_TEMP=""
    VAULT_FILE_TEMP=""
    VAULT_MARKER_TEMP=""
}

set_inputs() {
    ADMIN_PASSWORD='fixture-admin-value'
    ADGUARD_PASSWORD='fixture-adguard-value'
    WG_PASSWORD='fixture-wireguard-value'
    SSH_PUBKEY='ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA fixture'
    WG_HOST='192.0.2.10'
    SSH_PORT='2222'
    WG_PORT='51820'
    ADMIN_USER='sysadmin'
    WG_INTERNAL_DOMAIN='wg.internal'
    ADGUARD_INTERNAL_DOMAIN='adguard.internal'
    INTERNAL_DOMAIN_SUFFIX='internal'
    WG_TRAFFIC_MODE='services'
    WG_TRAFFIC_MODE_INPUT=''
}

clear_inputs() {
    ADMIN_PASSWORD=''
    ADGUARD_PASSWORD=''
    WG_PASSWORD=''
    SSH_PUBKEY=''
    INHERITED_ADMIN_PASSWORD=''
    INHERITED_ADGUARD_PASSWORD=''
    INHERITED_WG_PASSWORD=''
    INHERITED_SSH_PUBKEY=''
    SSH_PORT=''
    WG_PORT=''
    ADMIN_USER=''
    INTERNAL_DOMAINS=''
    WG_INTERNAL_DOMAIN=''
    ADGUARD_INTERNAL_DOMAIN=''
    WG_HOST=''
    INTERNAL_DOMAIN_SUFFIX=''
    WG_TRAFFIC_MODE='services'
    WG_TRAFFIC_MODE_INPUT=''
}

view_vault() {
    "${VAULT_ANSIBLE_BIN}" view --vault-password-file "${VAULT_PASS_FILE}" "${VAULT_FILE}"
}

assert_private_pair() {
    validate_installer_vault || fail 'vault pair is not valid and decryptable'
    [[ "$(stat -c '%a' "${VAULT_PASS_FILE}")" == 600 ]] || fail 'vault password mode is not 0600'
    [[ "$(stat -c '%a' "${VAULT_FILE}")" == 600 ]] || fail 'vault payload mode is not 0600'
    grep -Fq '$ANSIBLE_VAULT;' "${VAULT_FILE}" || fail 'vault payload is not encrypted'
}

run_whole_vault_schema_contract() {
    local malformed_plain malformed_vault original_vault scenario state valid_plain
    state="${TMP}/whole-vault-schema"
    configure_fixture "${state}"
    set_inputs
    prepare_installer_vault
    original_vault="${TMP}/original-installer-vault.yml"
    cp -- "${VAULT_FILE}" "${original_vault}"
    valid_plain="${TMP}/valid-installer-vault.yml"
    view_vault >"${valid_plain}"
    malformed_plain="${TMP}/malformed-installer-vault.yml"
    malformed_vault="${TMP}/malformed-installer-vault.encrypted.yml"
    for scenario in duplicate-bootstrap unknown-key duplicate-and-unknown duplicate-routing missing-routing malformed-endpoint malformed-admin-hash-type malformed-control-type wrong-connection-control wrong-vault-path-control; do
        cp -- "${valid_plain}" "${malformed_plain}"
        case "${scenario}" in
            duplicate-bootstrap)
                printf '%s\n' 'wg_easy_bootstrap_secret: "duplicate-wireguard-value"' >>"${malformed_plain}"
                ;;
            unknown-key)
                printf '%s\n' 'unexpected_top_level_key: "must-be-rejected"' >>"${malformed_plain}"
                ;;
            duplicate-and-unknown)
                printf '%s\n' 'wg_easy_bootstrap_secret: "duplicate-wireguard-value"' \
                    'unexpected_top_level_key: "must-be-rejected"' >>"${malformed_plain}"
                ;;
            duplicate-routing)
                printf '%s\n' 'ssh_port: "2222"' >>"${malformed_plain}"
                ;;
            missing-routing)
                sed -i '/^wg_port:/d' "${malformed_plain}"
                ;;
            malformed-endpoint)
                sed -i 's/^wg_public_host:.*/wg_public_host: "invalid endpoint"/' "${malformed_plain}"
                ;;
            malformed-admin-hash-type)
                sed -i 's/^admin_password_hash:.*/admin_password_hash: [malformed]/' "${malformed_plain}"
                ;;
            malformed-control-type)
                sed -i 's/^vps_orchestration_enable_ufw_before_ufw_docker: "true"$/vps_orchestration_enable_ufw_before_ufw_docker: true/' "${malformed_plain}"
                ;;
            wrong-connection-control)
                sed -i 's/^ansible_connection:.*/ansible_connection: "ssh"/' "${malformed_plain}"
                ;;
            wrong-vault-path-control)
                sed -i 's|^vps_services_vault_path:.*|vps_services_vault_path: "/tmp/wrong-installer-vault.yml"|' "${malformed_plain}"
                ;;
        esac
        "${VAULT_ANSIBLE_BIN}" encrypt --vault-password-file "${VAULT_PASS_FILE}" \
            --output "${malformed_vault}" "${malformed_plain}"
        mv -- "${malformed_vault}" "${VAULT_FILE}"
        chmod 0600 "${VAULT_FILE}"
        case "${scenario}" in
            malformed-admin-hash-type|malformed-control-type|wrong-connection-control|wrong-vault-path-control)
                if validate_installer_vault >/dev/null 2>&1; then
                    fail "validator accepted malformed whole-vault scenario: ${scenario}"
                fi
                ;;
        esac
        clear_inputs
        if (load_installer_inputs) >/dev/null 2>&1; then
            fail "loader accepted malformed whole-vault scenario: ${scenario}"
        fi
        printf '[PASS] whole-vault-schema-rejection: %s\n' "${scenario}"
    done

    cp -- "${original_vault}" "${VAULT_FILE}"
    chmod 0600 "${VAULT_FILE}"
    clear_inputs
    load_installer_inputs
    validate_installer_vault || fail 'validator rejected valid whole-vault fixture'
    printf '[PASS] whole-vault-schema: malformed vaults rejected; valid vault loads\n'
}

if [[ "${1:-}" == --case ]]; then
    [[ "${2:-}" == whole-vault-schema ]] || fail "unknown case: ${2:-missing}"
    run_whole_vault_schema_contract
    exit 0
fi

run_whole_vault_schema_contract

state_one="${TMP}/one"
configure_fixture "${state_one}"
set_inputs
prepare_installer_vault
assert_private_pair
committed_with_marker="$(sha256sum "${VAULT_PASS_FILE}" "${VAULT_FILE}")"
clear_inputs
prepare_installer_vault
[[ ! -e "${VAULT_MARKER}" ]] || fail 'credential-free recovery retained a stale marker'
[[ "${committed_with_marker}" == "$(sha256sum "${VAULT_PASS_FILE}" "${VAULT_FILE}")" ]] \
    || fail 'stale-marker recovery replaced a valid committed vault pair'
plain_one="$(view_vault)"
[[ "${plain_one}" == *'admin_password_hash: "$6$'* ]] || fail 'random SHA-512 admin hash missing'
[[ "${plain_one}" == *'vault_adguard_password_hash: "$2'* ]] || fail 'random bcrypt AdGuard hash missing'
[[ "${plain_one}" == *'wg_easy_bootstrap_secret: "fixture-wireguard-value"'* ]] || fail 'wg-easy secret missing'
[[ "${plain_one}" == *'wg_traffic_mode: "services"'* ]] || fail 'default traffic mode missing'
for persisted_input in \
    'ssh_port: "2222"' \
    'wg_port: "51820"' \
    'wg_container_port: "51820"' \
    'admin_user: "sysadmin"' \
    'wg_public_host: "192.0.2.10"' \
    'wg_internal_domain: "wg.internal"' \
    'adguard_internal_domain: "adguard.internal"' \
    'internal_domain_suffix: "internal"'; do
    [[ "${plain_one}" == *"${persisted_input}"* ]] \
        || fail "effective installer input was not persisted: ${persisted_input}"
done
[[ "${plain_one}" != *'fixture-admin-value'* && "${plain_one}" != *'fixture-adguard-value'* ]] \
    || fail 'source passwords persisted as plaintext'
before="$(sha256sum "${VAULT_PASS_FILE}" "${VAULT_FILE}")"

set_inputs
prepare_installer_vault
after="$(sha256sum "${VAULT_PASS_FILE}" "${VAULT_FILE}")"
[[ "${before}" == "${after}" ]] || fail 'rerun regenerated persisted secrets'

INHERITED_ADMIN_PASSWORD=''
INHERITED_ADGUARD_PASSWORD=''
INHERITED_WG_PASSWORD=''
INHERITED_SSH_PUBKEY=''
NOOK_NONINTERACTIVE=1
collect_configuration_noninteractive
prepare_installer_vault
[[ "${before}" == "$(sha256sum "${VAULT_PASS_FILE}" "${VAULT_FILE}")" ]] \
    || fail 'credential-free rerun changed persisted secrets'

state_two="${TMP}/two"
configure_fixture "${state_two}"
set_inputs
prepare_installer_vault
assert_private_pair
rm -f -- "${VAULT_MARKER}"
fsync_path "${VAULT_DIR}"
plain_two="$(view_vault)"
admin_one="$(sed -n 's/^admin_password_hash: //p' <<<"${plain_one}")"
admin_two="$(sed -n 's/^admin_password_hash: //p' <<<"${plain_two}")"
adguard_one="$(sed -n 's/^vault_adguard_password_hash: //p' <<<"${plain_one}")"
adguard_two="$(sed -n 's/^vault_adguard_password_hash: //p' <<<"${plain_two}")"
[[ "${admin_one}" != "${admin_two}" && "${adguard_one}" != "${adguard_two}" ]] \
    || fail 'fresh installs reused deterministic hashes'

state_egress="${TMP}/egress"
configure_fixture "${state_egress}"
set_inputs
WG_TRAFFIC_MODE='full'
WG_TRAFFIC_MODE_INPUT='full'
if ! (curl() { [[ " $* " != *' -6 '* ]]; }; prepare_installer_vault) >/dev/null 2>&1; then
    fail 'fresh full-tunnel state unexpectedly required IPv6 egress'
fi
[[ -e "${VAULT_PASS_FILE}" && -e "${VAULT_FILE}" && -e "${VAULT_MARKER}" ]] \
    || fail 'IPv4-only full-tunnel preflight did not persist immutable installer state'
plain_egress="$(view_vault)"
[[ "${plain_egress}" == *'wg_traffic_mode: "full"'* ]] \
    || fail 'IPv4-only full state did not persist its traffic mode'
printf '[PASS] full preflight accepts IPv4-only egress before immutable state commit\n'

configure_fixture "${state_two}"

if (WG_TRAFFIC_MODE_INPUT=full; prepare_installer_vault) >/dev/null 2>&1; then
    fail 'implicit traffic-mode transition was accepted on rerun'
fi
for mismatch in \
    'SSH_PORT=2223' \
    'WG_PORT=51821' \
    'ADMIN_USER=otheradmin' \
    'WG_HOST=198.51.100.10' \
    'WG_INTERNAL_DOMAIN=other.internal' \
    'ADGUARD_INTERNAL_DOMAIN=other.internal' \
    'INTERNAL_DOMAIN_SUFFIX=home.arpa'; do
    clear_inputs
    mismatch_name="${mismatch%%=*}"
    mismatch_value="${mismatch#*=}"
    printf -v "${mismatch_name}" '%s' "${mismatch_value}"
    if (prepare_installer_vault) >/dev/null 2>&1; then
        fail "implicit ${mismatch_name} transition was accepted on rerun"
    fi
done
clear_inputs
INHERITED_ADMIN_PASSWORD='replacement-secret'
if (collect_existing_configuration) >/dev/null 2>&1; then
    fail 'credential input was silently accepted on rerun'
fi
clear_inputs
(
    WG_HOST='192.0.2.20'
    read_yaml_scalar_default() {
        case "$2" in
            ssh_port) printf '2222\n' ;;
            wg_port) printf '51820\n' ;;
            admin_user) printf 'sysadmin\n' ;;
            internal_domain_suffix) printf 'internal\n' ;;
            *) return 1 ;;
        esac
    }
    resolve_effective_installer_inputs
    [[ "${SSH_PORT}:${WG_PORT}:${ADMIN_USER}:${INTERNAL_DOMAINS}" \
        == '2222:51820:sysadmin:wg.internal adguard.internal' ]] \
        || fail 'fresh installer defaults did not resolve to explicit persisted values'
)
if (NOOK_WG_EASY_ADMIN_PASSWORD=legacy collect_configuration_noninteractive) >/dev/null 2>&1; then
    fail 'legacy plaintext wg-easy variable was accepted'
fi
if (NOOK_WG_ENABLE_IPV6=true collect_configuration) >/dev/null 2>&1; then
    fail 'legacy IPv6 toggle was accepted'
fi

for rename_boundary in 1 2 3; do
    interrupted_state="${TMP}/rename-${rename_boundary}"
    set +e
    (
        set -e
        configure_fixture "${interrupted_state}"
        set_inputs
        trap cleanup_on_failure EXIT HUP INT TERM
        RENAME_COUNT=0
        mv() {
            RENAME_COUNT=$((RENAME_COUNT + 1))
            command mv "$@"
            [[ "${RENAME_COUNT}" -ne "${rename_boundary}" ]] || exit 99
        }
        prepare_installer_vault
    ) >/dev/null 2>&1
    interrupted_rc=$?
    set -e
    [[ "${interrupted_rc}" -eq 99 ]] || fail "rename boundary ${rename_boundary} did not interrupt exactly"

    configure_fixture "${interrupted_state}"
    [[ -f "${VAULT_MARKER}" ]] || fail "rename boundary ${rename_boundary} lost its transaction marker"
    if [[ "${rename_boundary}" -lt 3 ]]; then
        before_rejection="$(find "${interrupted_state}" -maxdepth 1 -type f -printf '%f\n' | sort)"
        clear_inputs
        if (prepare_installer_vault) >/dev/null 2>&1; then
            fail "incomplete rename boundary ${rename_boundary} recovered by replacing committed paths"
        fi
        [[ "${before_rejection}" == "$(find "${interrupted_state}" -maxdepth 1 -type f -printf '%f\n' | sort)" ]] \
            || fail "incomplete rename boundary ${rename_boundary} mutated preserved state"
        printf '[PASS] vault rename boundary %s: incomplete state preserved and rejected fail-closed\n' "${rename_boundary}"
    else
        assert_private_pair
        interrupted_pair="$(sha256sum "${VAULT_PASS_FILE}" "${VAULT_FILE}")"
        clear_inputs
        prepare_installer_vault
        [[ ! -e "${VAULT_MARKER}" ]] || fail 'final rename recovery retained stale marker'
        [[ "${interrupted_pair}" == "$(sha256sum "${VAULT_PASS_FILE}" "${VAULT_FILE}")" ]] \
            || fail 'final rename recovery replaced committed vault pair'
        printf '[PASS] vault rename boundary 3: credential-free recovery preserved committed pair bytes\n'
    fi
done

swap_fixture="${TMP}/swaps"
printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/provider-swap file 1048576 0 -2\n' >"${swap_fixture}"
swap_before="$(sha256sum "${swap_fixture}")"
( report_existing_swap() { awk 'NR > 1 { print }' "${swap_fixture}" >/dev/null; }; report_existing_swap )
[[ "${swap_before}" == "$(sha256sum "${swap_fixture}")" ]] || fail 'swap reporting changed provider swap'
if (available_memory_mib() { printf '899\n'; }; require_minimum_memory) >/dev/null 2>&1; then
    fail 'host below 900 MiB was accepted'
fi
(available_memory_mib() { printf '900\n'; }; require_minimum_memory)
if (platform_arch() { printf 'aarch64\n'; }; require_supported_platform) >/dev/null 2>&1; then
    fail 'non-amd64 host was accepted'
fi
(platform_arch() { printf 'x86_64\n'; }; require_supported_platform)
is_supported_os_release debian 12 || fail 'Debian 12 was rejected'
is_supported_os_release debian 12.12 || fail 'a Debian 12 point release was rejected'
is_supported_os_release ubuntu 24.04 || fail 'Ubuntu 24.04 was rejected'
for unsupported_release in 'debian:11' 'debian:13' 'debian:120' 'ubuntu:22.04' 'ubuntu:24.04.1' 'fedora:42'; do
    unsupported_id="${unsupported_release%%:*}"
    unsupported_version="${unsupported_release#*:}"
    if is_supported_os_release "${unsupported_id}" "${unsupported_version}"; then
        fail "unsupported OS release was accepted: ${unsupported_release}"
    fi
done
supported_os_line="$(grep -En '^    require_supported_os$' "${ROOT_DIR}/install.sh" | cut -d: -f1)"
prerequisites_line="$(grep -En '^    install_prerequisites$' "${ROOT_DIR}/install.sh" | cut -d: -f1)"
[[ -n "${supported_os_line}" && -n "${prerequisites_line}" && "${supported_os_line}" -lt "${prerequisites_line}" ]] \
    || fail 'main does not validate the supported OS before installing prerequisites'
grep -Fq 'sudo bash ./install.sh' "${ROOT_DIR}/install.sh" \
    || fail 'installer help omits the verified local-bytes execution path'
if grep -Fq '| sudo bash' "${ROOT_DIR}/install.sh"; then
    fail 'installer still promotes piped sudo execution'
fi
grep -Fq 'WireGuard panel password (required, min 12 chars)' "${ROOT_DIR}/install.sh" \
    || fail 'installer help has a stale WireGuard password minimum'
grep -Fq 'verify the tagged release asset attestation and checksum before' "${ROOT_DIR}/install.sh" \
    || fail 'installer help omits the verified release-asset trust boundary'
grep -Fq 'installer independently verifies the SSH-signed tag and exact' "${ROOT_DIR}/install.sh" \
    || fail 'installer help omits independent tag and SHA verification'
if grep -Fq 'This hardened path is not yet published' "${ROOT_DIR}/install.sh"; then
    fail 'installer help retains the stale unpublished-path warning'
fi

mutation_trace="${TMP}/mutation-trace"
if (
    validate_release_source() { :; }
    require_root() { :; }
    require_supported_os() { :; }
    platform_arch() { printf 'x86_64\n'; }
    available_memory_mib() { printf '899\n'; }
    install_prerequisites() { printf 'mutation\n' >>"${mutation_trace}"; }
    main
) >/dev/null 2>&1; then
    fail 'low-memory guarded main unexpectedly succeeded'
fi
[[ ! -e "${mutation_trace}" ]] || fail 'low-memory rejection happened after installer mutation'
if (
    validate_release_source() { :; }
    require_root() { :; }
    require_supported_os() { :; }
    platform_arch() { printf 'aarch64\n'; }
    install_prerequisites() { printf 'mutation\n' >>"${mutation_trace}"; }
    main
) >/dev/null 2>&1; then
    fail 'non-amd64 guarded main unexpectedly succeeded'
fi
[[ ! -e "${mutation_trace}" ]] || fail 'architecture rejection happened after installer mutation'

if grep -ERn 'vps_swap_mode|NOOK_VPS_SWAP_MODE|zram-tools|bootstrap_swap' "${ROOT_DIR}/install.sh" \
    "${ROOT_DIR}/group_vars" "${ROOT_DIR}/inventory" >"${TMP}/swap-surface"; then
    fail 'installer/config still exposes swap or zram management'
fi
if grep -En 'write_extra_var (admin_password|adguard_password|wg_easy_admin_password)([[:space:]]|$)' \
    "${ROOT_DIR}/install.sh" >"${TMP}/plaintext-role-input"; then
    fail 'installer still sends a plaintext role password variable to Ansible'
fi
if grep -En 'NOOK_TEST_FAIL_AFTER|vault_crash_point' "${ROOT_DIR}/install.sh" \
    >"${TMP}/production-fault-hook"; then
    fail 'production installer still contains a test-only fault hook'
fi
grep -Fq 'this tag is required only by the release gate' "${ROOT_DIR}/install.sh" \
    || fail 'v2.0.0 release-preparation contract is not documented in the installer'
rerun_block="$(sed -n '/^REMOTE_RERUN=/,/^INNER_RERUN$/p' "${ROOT_DIR}/tests/e2e/run-public-install.sh")"
if grep -Eq 'NOOK_(ADMIN_PASSWORD|ADGUARD_PASSWORD|WG_PASSWORD|SSH_PUBKEY)' <<<"${rerun_block}"; then
    fail 'public E2E rerun still supplies credential inputs'
fi

printf '[PASS] installer state: atomic vault, immutable-input rerun, random hashes, legacy rejection, amd64/900MiB, swap unchanged\n'
