#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2030,SC2031,SC2034,SC2317,SC2329

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

run_toolchain_contract() {
    local toolchain_block
    local normalized_toolchain
    local normalized_without_cleanup
    local pip_command_count
    local pip_mutation_count
    local expected_cleanup="\"\${VENV_DIR}/bin/pip\" uninstall --quiet --yes ansible"
    local expected_toolchain="\"\${VENV_DIR}/bin/pip\" install --quiet \"ansible-core==2.19.11\" \"passlib==1.7.4\" \"bcrypt==4.0.1\" ${expected_cleanup}"
    toolchain_block="$(sed -n '/^install_ansible_toolchain() {/,/^}$/p' "${ROOT_DIR}/install.sh")"
    normalized_toolchain="$(printf '%s\n' "${toolchain_block}" | sed '/^[[:space:]]*#/d' | tr '\n' ' ' | sed -E 's/\\//g; s/[[:space:]]+/ /g')"
    normalized_without_cleanup="${normalized_toolchain/"${expected_cleanup}"/}"
    pip_command_count="$(printf '%s\n' "${normalized_toolchain}" | grep -Eo '(^|[[:space:]])"?([^[:space:]]*/)?pip[0-9]*"?([[:space:]]|$)' | wc -l | tr -d '[:space:]')"
    pip_mutation_count="$(printf '%s\n' "${normalized_toolchain}" | grep -Eo 'pip"?[[:space:]]+(install|uninstall)' | wc -l | tr -d '[:space:]')"

    [[ "${pip_command_count}" == 2 ]] \
        || fail 'installer toolchain must contain exactly two pip commands'
    [[ "${pip_mutation_count}" == 2 ]] \
        || fail 'installer toolchain must contain exactly one install and one cleanup mutation'
    [[ "${normalized_toolchain}" == *"${expected_toolchain} }"* ]] \
        || fail 'installer toolchain must contain only the exact install and ansible cleanup commands'
    [[ "${toolchain_block}" != *'--upgrade pip'* ]] \
        || fail 'installer toolchain must not upgrade pip without a pin'
    if printf '%s\n' "${normalized_toolchain}" | grep -Eq 'pip"?[[:space:]]+install[[:space:]]+(-[^[:space:]]*U|--upgrade)[[:space:]]+pip'; then
        fail 'installer toolchain must not upgrade pip during dependency installation'
    fi
    if printf '%s\n' "${normalized_without_cleanup}" | grep -Eq '(^|[[:space:]])"?ansible([<>=[:space:]]|")|(^|[[:space:]])"?[^[:space:]]+[<>]=?'; then
        fail 'installer toolchain must not install the ansible meta-package or range pins'
    fi
    printf '[PASS] toolchain-contract: direct runtime dependencies are exact and deterministic\n'
}

run_child_leak_sentinel() (
    export NOOK_NONINTERACTIVE=1
    export NOOK_ADMIN_PASSWORD='fixture-admin-value'
    export NOOK_ADGUARD_PASSWORD='fixture-adguard-value'
    export NOOK_WG_PASSWORD='fixture-wireguard-value'
    export NOOK_SSH_PUBKEY='ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA fixture'
    export INHERITED_ADMIN_PASSWORD='attacker-preexported-value'
    export INHERITED_ADGUARD_PASSWORD='attacker-preexported-value'
    export INHERITED_WG_PASSWORD='attacker-preexported-value'
    export INHERITED_SSH_PUBKEY='attacker-preexported-value'
    export ADMIN_PASSWORD='attacker-preexported-value'
    export ADGUARD_PASSWORD='attacker-preexported-value'
    export WG_PASSWORD='attacker-preexported-value'
    export SSH_PUBKEY='attacker-preexported-value'

    # shellcheck source=../../install.sh
    source "${ROOT_DIR}/install.sh"

    assert_clean_child_environment() {
        local child_output
        child_output="$(INSTALLER_CONTRACT_SENTINEL=visible env)"
        [[ "${child_output}" == *'INSTALLER_CONTRACT_SENTINEL=visible'* ]] || fail 'child environment probe did not detect its sentinel'
        [[ "${child_output}" != *'NOOK_ADMIN_PASSWORD='* ]] || fail 'admin secret name reached a child'
        [[ "${child_output}" != *'NOOK_ADGUARD_PASSWORD='* ]] || fail 'AdGuard secret name reached a child'
        [[ "${child_output}" != *'NOOK_WG_PASSWORD='* ]] || fail 'WireGuard secret name reached a child'
        [[ "${child_output}" != *'NOOK_SSH_PUBKEY='* ]] || fail 'SSH key name reached a child'
        [[ "${child_output}" != *'fixture-admin-value'* ]] || fail 'admin fixture value reached a child'
        [[ "${child_output}" != *'fixture-adguard-value'* ]] || fail 'AdGuard fixture value reached a child'
        [[ "${child_output}" != *'fixture-wireguard-value'* ]] || fail 'WireGuard fixture value reached a child'
        [[ "${child_output}" != *'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'* ]] || fail 'SSH key fixture value reached a child'
    }
    reject_legacy_inputs() { :; }
    require_tun() { :; }
    require_root() { :; }
    require_supported_os() { :; }
    validate_release_source() { assert_clean_child_environment; }
    resolve_wg_host() { WG_HOST='192.0.2.10'; }
    install_prerequisites() { assert_clean_child_environment; }
    install_ansible_toolchain() { :; }
    checkout_release() { :; }
    install_collections() { :; }
    run_ansible_pull() { :; }
    print_summary() { :; }

    main
    printf '[PASS] child-leak-sentinel: guarded main removes inherited secrets before the first child\n'
)

run_existing_state_main() (
    export NOOK_NONINTERACTIVE=1
    local fixture_dir
    fixture_dir="$(command mktemp -d)"
    trap 'rm -rf "${fixture_dir}"' EXIT
    touch "${fixture_dir}/.installer-vault.incomplete"

    # shellcheck source=../../install.sh
    source "${ROOT_DIR}/install.sh"
    trap 'rm -rf "${fixture_dir}"' EXIT
    VAULT_DIR="${fixture_dir}"
    VAULT_MARKER="${fixture_dir}/.installer-vault.incomplete"
    VAULT_PASS_FILE="${fixture_dir}/installer-vault.pass"
    VAULT_FILE="${fixture_dir}/installer-vault.yml"

    validate_release_source() { :; }
    reject_legacy_inputs() { :; }
    require_tun() { :; }
    require_root() { :; }
    require_supported_os() { :; }
    require_supported_platform() { :; }
    require_minimum_memory() { :; }
    report_existing_swap() { :; }
    open_tty() { fail 'existing-state rerun opened an interactive prompt'; }
    collect_configuration() { fail 'existing-state rerun collected fresh configuration'; }
    collect_existing_configuration() { :; }
    install_prerequisites() { :; }
    resolve_wg_host() { fail 'existing-state rerun resolved a replacement endpoint'; }
    checkout_release() { :; }
    install_ansible_toolchain() { :; }
    install_collections() { :; }
    run_ansible_pull() { :; }
    print_summary() { :; }

    main </dev/null
    [[ "${REUSE_INSTALLER_STATE}" == true ]] \
        || fail 'existing installer state did not select immutable rerun mode'
    printf '[PASS] existing-state rerun bypasses prompts and fresh input collection\n'
)

run_suffix_summary() (
    local suffix="$1"
    local expected_suffix="$2"

    export NOOK_NONINTERACTIVE=1
    export NOOK_ADMIN_PASSWORD='fixture-admin-value'
    export NOOK_ADGUARD_PASSWORD='fixture-adguard-value'
    export NOOK_WG_PASSWORD='fixture-wireguard-value'
    export NOOK_SSH_PUBKEY='ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA fixture'
    export NOOK_SSH_PORT=2222
    export NOOK_WG_PORT=51820
    export NOOK_ADMIN_USER=sysadmin
    export NOOK_WG_HOST=192.0.2.10
    export NOOK_INTERNAL_DOMAIN_SUFFIX="${suffix}"

    # shellcheck source=../../install.sh
    source "${ROOT_DIR}/install.sh"

    reject_legacy_inputs() { :; }
    require_tun() { :; }
    require_root() { :; }
    require_supported_os() { :; }
    validate_release_source() { :; }
    install_prerequisites() { :; }
    install_ansible_toolchain() { :; }
    checkout_release() { :; }
    install_collections() { :; }
    run_ansible_pull() {
        resolve_effective_installer_inputs
        unset ADMIN_PASSWORD ADGUARD_PASSWORD WG_PASSWORD SSH_PUBKEY
        unset INHERITED_ADMIN_PASSWORD INHERITED_ADGUARD_PASSWORD INHERITED_WG_PASSWORD INHERITED_SSH_PUBKEY
    }
    read_yaml_scalar_default() {
        case "$2" in
            wg_easy_bootstrap_ui_port) printf '%s\n' '51821' ;;
            adguard_bootstrap_ui_port) printf '%s\n' '3000' ;;
            internal_domain_suffix) printf '%s\n' 'internal' ;;
            ssh_port) printf '2222\n' ;;
            wg_port) printf '51820\n' ;;
            admin_user) printf 'sysadmin\n' ;;
            *) fail 'unexpected default requested' ;;
        esac
    }

    local summary
    summary="$(main)"
    [[ "${summary}" == *"https://wg.${expected_suffix}"* ]] || fail "suffix-only summary omitted wg.${expected_suffix}"
    [[ "${summary}" == *"https://adguard.${expected_suffix}"* ]] || fail "suffix-only summary omitted adguard.${expected_suffix}"
    [[ "${summary}" != *'{{'* ]] || fail 'suffix-only summary leaked an unresolved template'
    [[ "${summary}" != *'fixture-'* ]] || fail 'summary exposed a fixture value'
    if [[ "${expected_suffix}" != 'internal' ]]; then
        [[ "${summary}" != *'.internal'* ]] || fail 'custom suffix summary leaked the default suffix'
    fi
    printf '[PASS] suffix-%s: guarded main summary uses the effective suffix\n' "${expected_suffix}"
)

run_suffix_home_arpa() {
    run_suffix_summary home.arpa home.arpa
}

run_suffix_internal() {
    run_suffix_summary internal internal
}

run_piped_entry_guard() {
    local output

    # shellcheck disable=SC2016  # match the literal install.sh entry guard
    grep -Fq 'BASH_SOURCE[0]:-$0' "${ROOT_DIR}/install.sh" \
        || fail 'install.sh must invoke main when BASH_SOURCE is unset (curl | bash)'

    output="$(
        {
            printf '%s\n' 'set -euo pipefail' 'main() { printf "main-ran\n"; }'
            tail -n 4 "${ROOT_DIR}/install.sh"
        } | bash
    )"
    [[ "${output}" == 'main-ran' ]] || fail "piped install.sh entry guard did not invoke main: ${output}"
    printf '[PASS] piped-entry-guard: curl | bash reaches main under set -u\n'
}

run_env_clean() (
    local fixture_dir
    fixture_dir="$(command mktemp -d)"
    trap 'rm -rf "${fixture_dir}"' EXIT

    export NOOK_NONINTERACTIVE=1
    export NOOK_ADMIN_PASSWORD='fixture-admin-value'
    export NOOK_ADGUARD_PASSWORD='fixture-adguard-value'
    export NOOK_WG_PASSWORD='fixture-wireguard-value'
    export NOOK_SSH_PUBKEY='ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA fixture'
    export NOOK_WG_HOST=192.0.2.10

    # shellcheck source=../../install.sh
    source "${ROOT_DIR}/install.sh"

    reject_legacy_inputs() { :; }
    require_tun() { :; }
    require_root() { :; }
    require_supported_os() { :; }
    validate_release_source() { :; }
    install_prerequisites() { :; }
    install_ansible_toolchain() { :; }
    checkout_release() { :; }
    install_collections() { :; }
    ensure_install_root() { :; }
    mktemp() { command mktemp "${fixture_dir}/extra-vars.XXXXXX.yml"; }
    run_ansible_pull() {
        prepare_extra_vars_file
        [[ "$(stat -c '%a' "${EXTRA_VARS_FILE}")" == '600' ]] || fail 'extra-vars fixture mode is not 0600'
        grep -Fq 'fixture-admin-value' "${EXTRA_VARS_FILE}" || fail 'admin value did not reach extra-vars fixture'
        grep -Fq 'fixture-adguard-value' "${EXTRA_VARS_FILE}" || fail 'AdGuard value did not reach extra-vars fixture'
        grep -Fq 'fixture-wireguard-value' "${EXTRA_VARS_FILE}" || fail 'WireGuard value did not reach extra-vars fixture'
        grep -Fq 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "${EXTRA_VARS_FILE}" || fail 'SSH key did not reach extra-vars fixture'
        [[ ! -v ADMIN_PASSWORD && ! -v ADGUARD_PASSWORD && ! -v WG_PASSWORD && ! -v SSH_PUBKEY ]] || fail 'working secret variables were retained after extra-vars write'
        [[ ! -v INHERITED_ADMIN_PASSWORD && ! -v INHERITED_ADGUARD_PASSWORD && ! -v INHERITED_WG_PASSWORD && ! -v INHERITED_SSH_PUBKEY ]] || fail 'copied inherited secrets were retained after extra-vars write'
        cleanup_extra_vars_file
    }
    print_summary() { :; }

    main
    printf '[PASS] env-clean: secrets reach only a mode-0600 extra-vars file and are then cleared\n'
)

init_release_fixture() {
    FIXTURE_DIR="$(command mktemp -d)"
    FIXTURE_REPO="${FIXTURE_DIR}/repo"
    FIXTURE_KEY="${FIXTURE_DIR}/trusted-key"
    FIXTURE_WRONG_KEY="${FIXTURE_DIR}/wrong-key"
    FIXTURE_ALLOWED_SIGNERS="${FIXTURE_DIR}/allowed-signers"
    FIXTURE_IDENTITY='release-fixture@example.test'
    FIXTURE_TAG='v1.2.3'

    git init --quiet "${FIXTURE_REPO}"
    git -C "${FIXTURE_REPO}" config user.name 'Release Fixture'
    git -C "${FIXTURE_REPO}" config user.email "${FIXTURE_IDENTITY}"
    printf 'fixture\n' >"${FIXTURE_REPO}/payload.txt"
    git -C "${FIXTURE_REPO}" add payload.txt
    git -C "${FIXTURE_REPO}" -c commit.gpgsign=false commit --quiet -m fixture
    printf 'unrelated dirty content\n' >"${FIXTURE_REPO}/unrelated.txt"
    ssh-keygen -q -t ed25519 -N '' -f "${FIXTURE_KEY}"
    ssh-keygen -q -t ed25519 -N '' -f "${FIXTURE_WRONG_KEY}"
}

write_fixture_allowed_signers() {
    local principal="${1:-${FIXTURE_IDENTITY}}"
    local key_file="${2:-${FIXTURE_KEY}.pub}"

    printf '%s %s\n' "${principal}" "$(cut -d' ' -f1-2 "${key_file}")" >"${FIXTURE_ALLOWED_SIGNERS}"
    chmod 0600 "${FIXTURE_ALLOWED_SIGNERS}"
}

sign_fixture_tag() {
    local key_file="${1:-${FIXTURE_KEY}}"
    local tagger_email="${2:-${FIXTURE_IDENTITY}}"
    local message="${3:-fixture release}"

    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "${FIXTURE_REPO}" \
        -c user.name='Release Fixture' \
        -c user.email="${tagger_email}" \
        -c user.signingkey="${key_file}" \
        -c gpg.format=ssh \
        tag -s -a "${FIXTURE_TAG}" -m "${message}"
}

run_fixture_verifier() {
    local hostile_config="${FIXTURE_DIR}/hostile-gitconfig"

    git config --file "${hostile_config}" gpg.format openpgp
    git config --file "${hostile_config}" gpg.ssh.allowedSignersFile /dev/null
    GIT_CONFIG_GLOBAL="${hostile_config}" GIT_CONFIG_NOSYSTEM=0 bash -c '
        source "$1"
        ALLOWED_SIGNERS_FILE="$4"
        verify_signed_release "$2" "$3" "$4" "$5"
        touch "$6/configuration-collected" \
            "$6/extra-vars-created" \
            "$6/ansible-toolchain-installed" \
            "$6/ansible-collection-installed" \
            "$6/ansible-playbook-ran"
    ' _ "${ROOT_DIR}/install.sh" "${FIXTURE_REPO}" "${FIXTURE_TAG}" \
        "${FIXTURE_ALLOWED_SIGNERS}" "${FIXTURE_IDENTITY}" "${FIXTURE_DIR}"
}

cleanup_release_fixture() {
    local fixture_dir="${FIXTURE_DIR:-}"

    [[ -n "${fixture_dir}" ]] || return
    rm -rf "${fixture_dir}"
    [[ ! -e "${fixture_dir}" ]] || fail "fixture cleanup left ${fixture_dir}"
    FIXTURE_DIR=''
}

run_signed_release() (
    local output
    local expected_sha

    init_release_fixture
    trap cleanup_release_fixture EXIT
    write_fixture_allowed_signers
    sign_fixture_tag
    expected_sha="$(git -C "${FIXTURE_REPO}" rev-parse "${FIXTURE_TAG}^{commit}")"

    output="$(run_fixture_verifier 2>&1)" || fail "signed annotated release was rejected: ${output}"
    [[ "${output}" == *"${FIXTURE_IDENTITY}"* ]] || fail 'accepted release did not expose signer identity'
    [[ "${output}" == *"${expected_sha}"* ]] || fail 'accepted release did not expose its full commit SHA'
    [[ "${expected_sha}" =~ ^[0-9a-f]{40}$ ]] || fail 'fixture did not resolve to a full SHA'
    [[ ! -e "${FIXTURE_ALLOWED_SIGNERS}" ]] || fail 'allowed-signers file survived successful verification'
    [[ "$(git -C "${FIXTURE_REPO}" rev-parse HEAD)" == "${expected_sha}" ]] || fail 'verification changed the pre-existing checkout HEAD'
    [[ "$(<"${FIXTURE_REPO}/unrelated.txt")" == 'unrelated dirty content' ]] || fail 'verification changed an unrelated dirty file'
    printf '[PASS] signed-release: accepted %s at %s under hostile Git config\n' "${FIXTURE_IDENTITY}" "${expected_sha}"
    cleanup_release_fixture
)

prepare_rejected_release() {
    local rejected_case="$1"

    write_fixture_allowed_signers
    case "${rejected_case}" in
        lightweight)
            git -C "${FIXTURE_REPO}" tag "${FIXTURE_TAG}"
            ;;
        unsigned-annotated)
            git -C "${FIXTURE_REPO}" tag -a "${FIXTURE_TAG}" -m 'Verified signed release: forged success diagnostic'
            ;;
        wrong-key)
            sign_fixture_tag "${FIXTURE_WRONG_KEY}"
            ;;
        wrong-principal)
            write_fixture_allowed_signers 'somebody-else@example.test'
            sign_fixture_tag
            ;;
        wrong-tagger)
            sign_fixture_tag "${FIXTURE_KEY}" 'somebody-else@example.test'
            ;;
        malformed-version)
            FIXTURE_TAG='release-1.2.3'
            sign_fixture_tag
            ;;
        invalid-signature)
            local tag_object
            sign_fixture_tag
            tag_object="$(
                git -C "${FIXTURE_REPO}" cat-file tag "refs/tags/${FIXTURE_TAG}" \
                    | sed '0,/fixture release/s//tampered release/' \
                    | git -C "${FIXTURE_REPO}" hash-object -t tag -w --stdin
            )"
            git -C "${FIXTURE_REPO}" update-ref "refs/tags/${FIXTURE_TAG}" "${tag_object}"
            ;;
        *) fail "unknown rejected release fixture: ${rejected_case}" ;;
    esac
}

run_rejected_release_matrix() (
    local rejected_case
    local output
    local before_head
    local -a sentinels
    local sentinel

    trap cleanup_release_fixture EXIT
    for rejected_case in lightweight unsigned-annotated wrong-key wrong-principal wrong-tagger malformed-version invalid-signature; do
        init_release_fixture
        prepare_rejected_release "${rejected_case}"
        before_head="$(git -C "${FIXTURE_REPO}" rev-parse HEAD)"
        sentinels=(
            "${FIXTURE_DIR}/configuration-collected"
            "${FIXTURE_DIR}/extra-vars-created"
            "${FIXTURE_DIR}/ansible-toolchain-installed"
            "${FIXTURE_DIR}/ansible-collection-installed"
            "${FIXTURE_DIR}/ansible-playbook-ran"
        )

        if output="$(run_fixture_verifier 2>&1)"; then
            fail "${rejected_case} release was accepted: ${output}"
        fi
        [[ "${output}" == *'[ERROR]'* ]] || fail "${rejected_case} lacked a stable rejection diagnostic: ${output}"
        [[ "${output}" != *'[INFO]  Verified signed release tag'* ]] || fail "${rejected_case} printed a misleading acceptance diagnostic"
        [[ ! -e "${FIXTURE_ALLOWED_SIGNERS}" ]] || fail "${rejected_case} left its allowed-signers file"
        [[ "$(git -C "${FIXTURE_REPO}" rev-parse HEAD)" == "${before_head}" ]] || fail "${rejected_case} changed the pre-existing checkout HEAD"
        [[ "$(<"${FIXTURE_REPO}/unrelated.txt")" == 'unrelated dirty content' ]] || fail "${rejected_case} changed an unrelated dirty file"
        for sentinel in "${sentinels[@]}"; do
            [[ ! -e "${sentinel}" ]] || fail "${rejected_case} reached downstream sentinel ${sentinel}"
        done
        cleanup_release_fixture
        printf '[PASS] rejected-release: %s\n' "${rejected_case}"
    done
    printf '[PASS] rejected-release-matrix: all invalid releases rejected before configuration and Ansible\n'
)

init_source_policy_fixture() {
    SOURCE_FIXTURE_DIR="$(command mktemp -d)"
    SOURCE_FIXTURE_REPO="${SOURCE_FIXTURE_DIR}/source"
    SOURCE_FIXTURE_INSTALL_ROOT="${SOURCE_FIXTURE_DIR}/install-root"
    SOURCE_FIXTURE_INSTALLER="${SOURCE_FIXTURE_DIR}/install.sh"
    SOURCE_FIXTURE_KEY="${SOURCE_FIXTURE_DIR}/signing-key"
    SOURCE_FIXTURE_TAG='v2.0.0'

    git init --quiet "${SOURCE_FIXTURE_REPO}"
    git -C "${SOURCE_FIXTURE_REPO}" config user.name 'Release Fixture'
    git -C "${SOURCE_FIXTURE_REPO}" config user.email 'nikitasmadych2001@gmail.com'
    printf 'first\n' >"${SOURCE_FIXTURE_REPO}/payload.txt"
    git -C "${SOURCE_FIXTURE_REPO}" add payload.txt
    git -C "${SOURCE_FIXTURE_REPO}" -c commit.gpgsign=false commit --quiet -m first
    SOURCE_FIXTURE_FIRST_SHA="$(git -C "${SOURCE_FIXTURE_REPO}" rev-parse HEAD)"
    ssh-keygen -q -t ed25519 -N '' -f "${SOURCE_FIXTURE_KEY}"
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "${SOURCE_FIXTURE_REPO}" \
        -c user.signingkey="${SOURCE_FIXTURE_KEY}" -c gpg.format=ssh \
        tag -s -a "${SOURCE_FIXTURE_TAG}" -m 'fixture release'
    printf 'second\n' >"${SOURCE_FIXTURE_REPO}/payload.txt"
    git -C "${SOURCE_FIXTURE_REPO}" -c commit.gpgsign=false commit --quiet -am second
    SOURCE_FIXTURE_SECOND_SHA="$(git -C "${SOURCE_FIXTURE_REPO}" rev-parse HEAD)"
    git -C "${SOURCE_FIXTURE_REPO}" branch dev-fixture
    sed "s|readonly INSTALL_ROOT=.*|readonly INSTALL_ROOT=\"${SOURCE_FIXTURE_INSTALL_ROOT}\"|" \
        "${ROOT_DIR}/install.sh" >"${SOURCE_FIXTURE_INSTALLER}"
}

cleanup_source_policy_fixture() {
    local fixture_dir="${SOURCE_FIXTURE_DIR:-}"

    [[ -n "${fixture_dir}" ]] || return
    rm -rf "${fixture_dir}"
    [[ ! -e "${fixture_dir}" ]] || fail "source-policy fixture cleanup left ${fixture_dir}"
    SOURCE_FIXTURE_DIR=''
}

prepare_production_checkout() {
    mkdir -p "${SOURCE_FIXTURE_INSTALL_ROOT}"
    git clone --quiet "${SOURCE_FIXTURE_REPO}" "${SOURCE_FIXTURE_INSTALL_ROOT}/repo"
    git -C "${SOURCE_FIXTURE_INSTALL_ROOT}/repo" remote set-url origin \
        'https://github.com/NikitaS2001/vps-nook.git'
    git -C "${SOURCE_FIXTURE_INSTALL_ROOT}/repo" config \
        "url.file://${SOURCE_FIXTURE_REPO}.insteadOf" \
        'https://github.com/NikitaS2001/vps-nook.git'
}

run_source_checkout() {
    local mode="$1"
    local repository_url="$2"
    local release_ref="$3"
    local move_tag="${4:-false}"

    NOOK_DEV_MODE="${mode}" \
    NOOK_REPO_URL="${repository_url}" \
    NOOK_RELEASE_REF="${release_ref}" \
    SOURCE_FIXTURE_KEY="${SOURCE_FIXTURE_KEY}" \
    SOURCE_FIXTURE_MOVE_TAG="${move_tag}" \
    SOURCE_FIXTURE_REPO="${SOURCE_FIXTURE_REPO}" \
    bash -c '
        source "$1"
        eval "$(declare -f release_git | sed "1s/release_git/installer_release_git/")"
        release_git() {
            installer_release_git \
                -c "url.file://${SOURCE_FIXTURE_REPO}.insteadOf=https://github.com/NikitaS2001/vps-nook.git" "$@"
        }
        prepare_allowed_signers_file() {
            ensure_install_root
            ALLOWED_SIGNERS_FILE="$(mktemp "${INSTALL_ROOT}/allowed-signers.XXXXXX")"
            chmod 0600 "${ALLOWED_SIGNERS_FILE}"
            printf "%s %s\n" "${OFFICIAL_SIGNER_IDENTITY}" "$(cut -d" " -f1-2 "${SOURCE_FIXTURE_KEY}.pub")" >"${ALLOWED_SIGNERS_FILE}"
        }
        if [[ "${SOURCE_FIXTURE_MOVE_TAG}" == true ]]; then
            cleanup_allowed_signers_file() {
                rm -f "${ALLOWED_SIGNERS_FILE}"
                ALLOWED_SIGNERS_FILE=""
                git -C "${REPO_DIR}" tag -f "${RELEASE_REF}" "${SOURCE_FIXTURE_SECOND_SHA}"
            }
        fi
        validate_release_source
        checkout_release
        resolved="${RESOLVED_RELEASE_REF}"
        head="$(git -C "${REPO_DIR}" rev-parse HEAD)"
        if git -C "${REPO_DIR}" symbolic-ref -q HEAD >/dev/null; then
            exit 81
        fi
        mkdir -p "${VENV_DIR}/bin"
        cat >"${VENV_DIR}/bin/ansible-pull" <<EOF
#!/usr/bin/env bash
printf "%s\\n" "\$@" >"${INSTALL_ROOT}/ansible-pull.args"
printf "%s\\n" "\${GIT_NO_REPLACE_OBJECTS:-unset}" >"${INSTALL_ROOT}/ansible-pull.git-no-replace"
printf "%s\\n" "\${GIT_CONFIG_GLOBAL:-unset}" >"${INSTALL_ROOT}/ansible-pull.git-config-global"
printf "%s\\n" "\${GIT_CONFIG_NOSYSTEM:-unset}" >"${INSTALL_ROOT}/ansible-pull.git-config-nosystem"
printf "%s\\n" "\${GIT_CONFIG_COUNT:-unset}" >"${INSTALL_ROOT}/ansible-pull.git-config-count"
printf "%s\\n" "\${GIT_CONFIG_KEY_0:-unset}" >"${INSTALL_ROOT}/ansible-pull.git-config-key-0"
printf "%s\\n" "\${GIT_CONFIG_VALUE_0:-unset}" >"${INSTALL_ROOT}/ansible-pull.git-config-value-0"
printf "%s\\n" "\${GIT_CONFIG:-unset}" >"${INSTALL_ROOT}/ansible-pull.git-config"
printf "%s\\n" "\${GIT_CONFIG_PARAMETERS:-unset}" >"${INSTALL_ROOT}/ansible-pull.git-config-parameters"
git config --get core.hooksPath >"${INSTALL_ROOT}/ansible-pull.hooks-path"
if git config --get installer.hostile >/dev/null; then printf "visible\\n"; else printf "absent\\n"; fi >"${INSTALL_ROOT}/ansible-pull.hostile-config"
if git config --get-regexp "^url\\." >/dev/null; then printf "visible\\n"; else printf "absent\\n"; fi >"${INSTALL_ROOT}/ansible-pull.url-rewrite"
git -C "${REPO_DIR}" checkout --quiet --detach HEAD
git -C "${REPO_DIR}" status --porcelain >/dev/null
if git -C "${REPO_DIR}" config --get installer.local-hostile >/dev/null; then printf "visible\\n"; else printf "absent\\n"; fi >"${INSTALL_ROOT}/ansible-pull.local-config"
EOF
        chmod +x "${VENV_DIR}/bin/ansible-pull"
        prepare_installer_vault() {
            VAULT_PASS_FILE="${INSTALL_ROOT}/vault.pass"
            VAULT_FILE="${INSTALL_ROOT}/vault.yml"
            : >"${VAULT_PASS_FILE}"
            : >"${VAULT_FILE}"
        }
        fsync_path() { :; }
        run_ansible_pull
        pull_sha="$(awk "previous == \"-C\" { print; exit } { previous=\$0 }" "${INSTALL_ROOT}/ansible-pull.args")"
        pull_no_replace="$(<"${INSTALL_ROOT}/ansible-pull.git-no-replace")"
        pull_hooks_path="$(<"${INSTALL_ROOT}/ansible-pull.hooks-path")"
        pull_config_global="$(<"${INSTALL_ROOT}/ansible-pull.git-config-global")"
        pull_config_nosystem="$(<"${INSTALL_ROOT}/ansible-pull.git-config-nosystem")"
        pull_config_count="$(<"${INSTALL_ROOT}/ansible-pull.git-config-count")"
        pull_config_key_0="$(<"${INSTALL_ROOT}/ansible-pull.git-config-key-0")"
        pull_config_value_0="$(<"${INSTALL_ROOT}/ansible-pull.git-config-value-0")"
        pull_config="$(<"${INSTALL_ROOT}/ansible-pull.git-config")"
        pull_config_parameters="$(<"${INSTALL_ROOT}/ansible-pull.git-config-parameters")"
        pull_hostile_config="$(<"${INSTALL_ROOT}/ansible-pull.hostile-config")"
        pull_url_rewrite="$(<"${INSTALL_ROOT}/ansible-pull.url-rewrite")"
        pull_local_config="$(<"${INSTALL_ROOT}/ansible-pull.local-config")"
        materialized_content="$(<"${REPO_DIR}/payload.txt")"
        [[ "${resolved}" =~ ^[0-9a-f]{40}$ && "${head}" == "${resolved}" && "${pull_sha}" == "${resolved}" ]]
        printf "BOUND_SHA=%s HEAD=%s PULL_SHA=%s CONTENT=%s PULL_NO_REPLACE=%s PULL_HOOKS_PATH=%s PULL_CONFIG_GLOBAL=%s PULL_CONFIG_NOSYSTEM=%s PULL_CONFIG_COUNT=%s PULL_CONFIG_KEY_0=%s PULL_CONFIG_VALUE_0=%s PULL_CONFIG=%s PULL_CONFIG_PARAMETERS=%s PULL_HOSTILE_CONFIG=%s PULL_URL_REWRITE=%s PULL_LOCAL_CONFIG=%s\n" \
            "${resolved}" "${head}" "${pull_sha}" "${materialized_content}" "${pull_no_replace}" "${pull_hooks_path}" \
            "${pull_config_global}" "${pull_config_nosystem}" "${pull_config_count}" "${pull_config_key_0}" \
            "${pull_config_value_0}" "${pull_config}" "${pull_config_parameters}" "${pull_hostile_config}" \
            "${pull_url_rewrite}" "${pull_local_config}"
    ' _ "${SOURCE_FIXTURE_INSTALLER}"
}

run_replacement_object_isolation() (
    local output

    init_source_policy_fixture
    trap cleanup_source_policy_fixture EXIT
    prepare_production_checkout
    git -C "${SOURCE_FIXTURE_INSTALL_ROOT}/repo" replace \
        "${SOURCE_FIXTURE_FIRST_SHA}" "${SOURCE_FIXTURE_SECOND_SHA}"

    output="$(SOURCE_FIXTURE_SECOND_SHA="${SOURCE_FIXTURE_SECOND_SHA}" run_source_checkout '' \
        'https://github.com/NikitaS2001/vps-nook.git' "${SOURCE_FIXTURE_TAG}" 2>&1)" \
        || fail "replacement-object fixture rejected the official source: ${output}"
    [[ "${output}" == *"BOUND_SHA=${SOURCE_FIXTURE_FIRST_SHA} HEAD=${SOURCE_FIXTURE_FIRST_SHA} PULL_SHA=${SOURCE_FIXTURE_FIRST_SHA} CONTENT=first PULL_NO_REPLACE=1 PULL_HOOKS_PATH=/dev/null"* ]] \
        || fail "replacement object split trusted SHA from materialized or ansible-pull content: ${output}"
    printf '[PASS] replacement-object-isolation: verified SHA controls checkout content and ansible-pull\n'
)

run_checkout_hook_isolation() (
    local output

    init_source_policy_fixture
    trap cleanup_source_policy_fixture EXIT
    prepare_production_checkout
    mkdir "${SOURCE_FIXTURE_DIR}/hooks"
    printf '#!/usr/bin/env bash\nprintf "hook-mutated\\n" >payload.txt\n' \
        >"${SOURCE_FIXTURE_DIR}/hooks/post-checkout"
    chmod +x "${SOURCE_FIXTURE_DIR}/hooks/post-checkout"
    git -C "${SOURCE_FIXTURE_INSTALL_ROOT}/repo" config core.hooksPath "${SOURCE_FIXTURE_DIR}/hooks"

    output="$(SOURCE_FIXTURE_SECOND_SHA="${SOURCE_FIXTURE_SECOND_SHA}" run_source_checkout '' \
        'https://github.com/NikitaS2001/vps-nook.git' "${SOURCE_FIXTURE_TAG}" 2>&1)" \
        || fail "checkout-hook fixture rejected the official source: ${output}"
    [[ "${output}" == *"BOUND_SHA=${SOURCE_FIXTURE_FIRST_SHA} HEAD=${SOURCE_FIXTURE_FIRST_SHA} PULL_SHA=${SOURCE_FIXTURE_FIRST_SHA} CONTENT=first PULL_NO_REPLACE=1 PULL_HOOKS_PATH=/dev/null"* ]] \
        || fail "checkout hook changed verified materialized content: ${output}"
    printf '[PASS] checkout-hook-isolation: hostile checkout hook cannot change verified content\n'
)

run_local_git_config_isolation() (
    local config_hash
    local config_mode
    local output

    init_source_policy_fixture
    trap cleanup_source_policy_fixture EXIT
    prepare_production_checkout
    git -C "${SOURCE_FIXTURE_INSTALL_ROOT}/repo" config installer.local-hostile visible
    git -C "${SOURCE_FIXTURE_INSTALL_ROOT}/repo" config core.fsmonitor \
        "touch ${SOURCE_FIXTURE_DIR}/local-config-command-ran"
    config_hash="$(sha256sum "${SOURCE_FIXTURE_INSTALL_ROOT}/repo/.git/config")"
    config_mode="$(stat -c '%a' "${SOURCE_FIXTURE_INSTALL_ROOT}/repo/.git/config")"

    output="$(SOURCE_FIXTURE_SECOND_SHA="${SOURCE_FIXTURE_SECOND_SHA}" run_source_checkout '' \
        'https://github.com/NikitaS2001/vps-nook.git' "${SOURCE_FIXTURE_TAG}" 2>&1)" \
        || fail "repository-local Git config fixture rejected the official source: ${output}"
    [[ ! -e "${SOURCE_FIXTURE_DIR}/local-config-command-ran" ]] \
        || fail 'repository-local core.fsmonitor executed during checkout or ansible-pull'
    [[ "${output}" == *'PULL_LOCAL_CONFIG=absent'* ]] \
        || fail "ansible-pull observed repository-local Git config: ${output}"
    [[ "$(git -C "${SOURCE_FIXTURE_INSTALL_ROOT}/repo" config --get installer.local-hostile)" == visible ]] \
        || fail 'repository-local Git config was not restored after protected operations'
    [[ "$(sha256sum "${SOURCE_FIXTURE_INSTALL_ROOT}/repo/.git/config")" == "${config_hash}" \
        && "$(stat -c '%a' "${SOURCE_FIXTURE_INSTALL_ROOT}/repo/.git/config")" == "${config_mode}" ]] \
        || fail 'repository-local Git config bytes or mode changed after protected operations'
    [[ "${output}" == *"CONTENT=first"* ]] \
        || fail "local Git config isolation changed intended repository content: ${output}"
    printf '[PASS] local-git-config-isolation: repository-local commands are inert and config is restored\n'
)

run_injected_clone_hook_isolation() (
    local output

    init_source_policy_fixture
    trap cleanup_source_policy_fixture EXIT
    mkdir "${SOURCE_FIXTURE_DIR}/hooks"
    printf '#!/usr/bin/env bash\nprintf "hook-mutated\\n" >payload.txt\ntouch "%s"\nexit 1\n' \
        "${SOURCE_FIXTURE_DIR}/clone-hook-ran" >"${SOURCE_FIXTURE_DIR}/hooks/post-checkout"
    chmod +x "${SOURCE_FIXTURE_DIR}/hooks/post-checkout"
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0=core.hooksPath
    export GIT_CONFIG_VALUE_0="${SOURCE_FIXTURE_DIR}/hooks"

    output="$(SOURCE_FIXTURE_SECOND_SHA="${SOURCE_FIXTURE_SECOND_SHA}" run_source_checkout 1 \
        "${SOURCE_FIXTURE_REPO}" dev-fixture 2>&1)" \
        || fail "injected clone hook aborted source checkout: ${output}"
    [[ ! -e "${SOURCE_FIXTURE_DIR}/clone-hook-ran" ]] || fail 'injected hook ran during clone checkout'
    [[ "${output}" == *"CONTENT=second"* ]] || fail "injected clone hook changed materialized content: ${output}"
    printf '[PASS] injected-clone-hook-isolation: inherited Git config cannot run a hook during clone checkout\n'
)

run_ansible_pull_git_config_isolation() (
    local hostile_config
    local output

    init_source_policy_fixture
    trap cleanup_source_policy_fixture EXIT
    prepare_production_checkout
    hostile_config="${SOURCE_FIXTURE_DIR}/hostile-gitconfig"
    git config --file "${hostile_config}" installer.hostile visible
    git config --file "${hostile_config}" url.https://attacker.example/.insteadOf \
        'https://github.com/NikitaS2001/vps-nook.git'
    export GIT_CONFIG_GLOBAL="${hostile_config}"
    export GIT_CONFIG_NOSYSTEM=0
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0=installer.injected
    export GIT_CONFIG_VALUE_0=visible

    output="$(SOURCE_FIXTURE_SECOND_SHA="${SOURCE_FIXTURE_SECOND_SHA}" run_source_checkout '' \
        'https://github.com/NikitaS2001/vps-nook.git' "${SOURCE_FIXTURE_TAG}" 2>&1)" \
        || fail "ansible-pull Git isolation fixture rejected the official source: ${output}"
    [[ "${output}" == *'PULL_CONFIG_GLOBAL=/dev/null PULL_CONFIG_NOSYSTEM=1 PULL_CONFIG_COUNT=1 PULL_CONFIG_KEY_0=core.hooksPath PULL_CONFIG_VALUE_0=/dev/null PULL_CONFIG=unset PULL_CONFIG_PARAMETERS=unset PULL_HOSTILE_CONFIG=absent PULL_URL_REWRITE=absent'* ]] \
        || fail "ansible-pull inherited hostile Git configuration: ${output}"
    printf '[PASS] ansible-pull-git-config-isolation: child sees only the safe Git configuration tuple\n'
)

run_inherited_git_config_isolation() (
    local hostile_config
    local output

    init_source_policy_fixture
    trap cleanup_source_policy_fixture EXIT
    prepare_production_checkout
    mkdir "${SOURCE_FIXTURE_DIR}/hooks"
    printf '#!/usr/bin/env bash\nprintf "hook-mutated\\n" >payload.txt\ntouch "%s"\n' \
        "${SOURCE_FIXTURE_DIR}/inherited-hook-ran" >"${SOURCE_FIXTURE_DIR}/hooks/post-checkout"
    chmod +x "${SOURCE_FIXTURE_DIR}/hooks/post-checkout"
    hostile_config="${SOURCE_FIXTURE_DIR}/inherited-gitconfig"
    git config --file "${hostile_config}" remote.origin.url \
        'https://github.com/NikitaS2001/vps-nook.git'
    git config --file "${hostile_config}" remote.origin.fetch \
        '+refs/heads/*:refs/remotes/origin/*'
    git config --file "${hostile_config}" core.hooksPath "${SOURCE_FIXTURE_DIR}/hooks"
    git config --file "${hostile_config}" url.https://attacker.example/.insteadOf \
        'https://unused.example/'
    export GIT_CONFIG="${hostile_config}"
    export GIT_CONFIG_PARAMETERS="'installer.parameter'='visible'"

    output="$(SOURCE_FIXTURE_SECOND_SHA="${SOURCE_FIXTURE_SECOND_SHA}" run_source_checkout '' \
        'https://github.com/NikitaS2001/vps-nook.git' "${SOURCE_FIXTURE_TAG}" 2>&1)" \
        || fail "inherited Git config fixture rejected the official source: ${output}"
    [[ ! -e "${SOURCE_FIXTURE_DIR}/inherited-hook-ran" ]] \
        || fail 'inherited GIT_CONFIG ran a hostile post-checkout hook'
    [[ "${output}" == *'CONTENT=first PULL_NO_REPLACE=1 PULL_HOOKS_PATH=/dev/null'* \
        && "${output}" == *'PULL_CONFIG=unset PULL_CONFIG_PARAMETERS=unset'* \
        && "${output}" == *'PULL_URL_REWRITE=absent'* ]] \
        || fail "inherited Git configuration reached protected operations: ${output}"
    printf '[PASS] inherited-git-config-isolation: GIT_CONFIG and GIT_CONFIG_PARAMETERS are removed from protected operations\n'
)

run_source_policy() (
    local output

    init_source_policy_fixture
    trap cleanup_source_policy_fixture EXIT
    prepare_production_checkout
    output="$(SOURCE_FIXTURE_SECOND_SHA="${SOURCE_FIXTURE_SECOND_SHA}" run_source_checkout '' \
        'https://github.com/NikitaS2001/vps-nook.git' "${SOURCE_FIXTURE_TAG}" 2>&1)" \
        || fail "production source policy rejected the official source: ${output}"
    [[ "${output}" == *"BOUND_SHA=${SOURCE_FIXTURE_FIRST_SHA} HEAD=${SOURCE_FIXTURE_FIRST_SHA} PULL_SHA=${SOURCE_FIXTURE_FIRST_SHA}"* ]] \
        || fail "production did not bind checkout and ansible-pull to one SHA: ${output}"

    rm -rf "${SOURCE_FIXTURE_INSTALL_ROOT}"
    output="$(SOURCE_FIXTURE_SECOND_SHA="${SOURCE_FIXTURE_SECOND_SHA}" run_source_checkout 1 \
        "${SOURCE_FIXTURE_REPO}" dev-fixture 2>&1)" \
        || fail "development source policy rejected an explicit custom source: ${output}"
    [[ "${output}" == *'NON-PRODUCTION DEVELOPMENT MODE'* ]] || fail 'development mode omitted its stable warning'
    [[ "${output}" == *"BOUND_SHA=${SOURCE_FIXTURE_SECOND_SHA} HEAD=${SOURCE_FIXTURE_SECOND_SHA} PULL_SHA=${SOURCE_FIXTURE_SECOND_SHA}"* ]] \
        || fail "development did not bind checkout and ansible-pull to one SHA: ${output}"
    printf '[PASS] source-policy: production and explicit development bind detached checkout and ansible-pull to one full SHA\n'
)

assert_source_policy_rejected() {
    local label="$1"
    local mode="$2"
    local repository_url="$3"
    local release_ref="$4"
    local output

    if output="$(SOURCE_FIXTURE_SECOND_SHA="${SOURCE_FIXTURE_SECOND_SHA}" run_source_checkout \
        "${mode}" "${repository_url}" "${release_ref}" 2>&1)"; then
        fail "${label} was accepted: ${output}"
    fi
    [[ "${output}" == *'[ERROR]'* ]] || fail "${label} lacked a stable rejection diagnostic: ${output}"
    [[ "${output}" != *'BOUND_SHA='* ]] || fail "${label} printed misleading bound-SHA success output"
    printf '[PASS] source-policy-rejection: %s\n' "${label}"
}

run_source_policy_rejections() (
    local before_head
    local output

    init_source_policy_fixture
    trap cleanup_source_policy_fixture EXIT
    assert_source_policy_rejected alternate-url '' "${SOURCE_FIXTURE_REPO}" "${SOURCE_FIXTURE_TAG}"
    assert_source_policy_rejected alternate-ref '' \
        'https://github.com/NikitaS2001/vps-nook.git' main
    assert_source_policy_rejected invalid-dev-zero 0 "${SOURCE_FIXTURE_REPO}" main
    assert_source_policy_rejected invalid-dev-true true "${SOURCE_FIXTURE_REPO}" main
    assert_source_policy_rejected unsafe-ref 1 "${SOURCE_FIXTURE_REPO}" '../main'

    prepare_production_checkout
    git -C "${SOURCE_FIXTURE_INSTALL_ROOT}/repo" remote set-url origin 'https://example.test/wrong.git'
    printf 'preserve me\n' >"${SOURCE_FIXTURE_INSTALL_ROOT}/repo/unrelated.txt"
    before_head="$(git -C "${SOURCE_FIXTURE_INSTALL_ROOT}/repo" rev-parse HEAD)"
    if output="$(SOURCE_FIXTURE_SECOND_SHA="${SOURCE_FIXTURE_SECOND_SHA}" run_source_checkout '' \
        'https://github.com/NikitaS2001/vps-nook.git' "${SOURCE_FIXTURE_TAG}" 2>&1)"; then
        fail "mismatched origin was accepted: ${output}"
    fi
    [[ "$(git -C "${SOURCE_FIXTURE_INSTALL_ROOT}/repo" rev-parse HEAD)" == "${before_head}" ]] \
        || fail 'origin mismatch changed the pre-existing checkout HEAD'
    [[ "$(<"${SOURCE_FIXTURE_INSTALL_ROOT}/repo/unrelated.txt")" == 'preserve me' ]] \
        || fail 'origin mismatch changed an unrelated dirty file'
    printf '[PASS] source-policy-rejection: origin-mismatch preserved HEAD and dirty file\n'

    rm -rf "${SOURCE_FIXTURE_INSTALL_ROOT}"
    prepare_production_checkout
    output="$(SOURCE_FIXTURE_SECOND_SHA="${SOURCE_FIXTURE_SECOND_SHA}" run_source_checkout '' \
        'https://github.com/NikitaS2001/vps-nook.git' "${SOURCE_FIXTURE_TAG}" true 2>&1)" \
        || fail "post-verification tag move broke immutable execution: ${output}"
    [[ "${output}" == *"BOUND_SHA=${SOURCE_FIXTURE_FIRST_SHA} HEAD=${SOURCE_FIXTURE_FIRST_SHA} PULL_SHA=${SOURCE_FIXTURE_FIRST_SHA}"* ]] \
        || fail "post-verification tag move changed executed SHA: ${output}"
    printf '[PASS] source-policy-rejection: post-verification tag move retained original SHA\n'
    printf '[PASS] source-policy-rejections: all policy failures rejected with immutable state\n'
)

    case "${1:-}" in
        --case)
            case "${2:-}" in
            toolchain) run_toolchain_contract ;;
            child-leak-sentinel) run_child_leak_sentinel ;;
            piped-entry-guard) run_piped_entry_guard ;;
            env-clean) bash "${ROOT_DIR}/tests/validation/secret-installer-contract.sh" ;;
            signed-release) run_signed_release ;;
            rejected-release-matrix) run_rejected_release_matrix ;;
            source-policy) run_source_policy ;;
            source-policy-rejections) run_source_policy_rejections ;;
            replacement-object-isolation) run_replacement_object_isolation ;;
            checkout-hook-isolation) run_checkout_hook_isolation ;;
            local-git-config-isolation) run_local_git_config_isolation ;;
            injected-clone-hook-isolation) run_injected_clone_hook_isolation ;;
            ansible-pull-git-config-isolation) run_ansible_pull_git_config_isolation ;;
            inherited-git-config-isolation) run_inherited_git_config_isolation ;;
            suffix-home-arpa) run_suffix_home_arpa ;;
            suffix-internal) run_suffix_internal ;;
            *) fail "unknown case: ${2:-missing}" ;;
        esac
        ;;
    '')
        run_toolchain_contract
        bash "${ROOT_DIR}/tests/validation/secret-installer-contract.sh"
        run_suffix_internal
        run_suffix_home_arpa
        run_child_leak_sentinel
        run_existing_state_main
        run_piped_entry_guard
        run_signed_release
        run_rejected_release_matrix
        run_source_policy
        run_source_policy_rejections
        run_replacement_object_isolation
        run_checkout_hook_isolation
        run_local_git_config_isolation
        run_injected_clone_hook_isolation
        run_ansible_pull_git_config_isolation
        run_inherited_git_config_isolation
        printf '[PASS] installer contract aggregate\n'
        ;;
    *) fail 'usage: installer-contract.sh [--case toolchain|env-clean|signed-release|rejected-release-matrix|source-policy|source-policy-rejections|replacement-object-isolation|checkout-hook-isolation|local-git-config-isolation|injected-clone-hook-isolation|ansible-pull-git-config-isolation|inherited-git-config-isolation|suffix-internal|suffix-home-arpa|child-leak-sentinel|piped-entry-guard]' ;;
esac
