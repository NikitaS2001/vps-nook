#!/usr/bin/env bash
# Public installer for vps-nook.
# Recommended usage after verifying release bytes locally:
#   sudo bash ./install.sh

set -euo pipefail
umask 077

readonly OFFICIAL_REPO_URL="https://github.com/NikitaS2001/vps-nook.git"
# Release-preparation target: this tag is required only by the release gate.
# Before the tag exists, source-tree tests must use explicit NOOK_DEV_MODE=1.
readonly OFFICIAL_RELEASE_REF="v2.0.0"
readonly OFFICIAL_SIGNER_IDENTITY="nikitasmadych2001@gmail.com"
readonly OFFICIAL_SIGNER_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILcfC1Stku7YQ0mLYptkX+t0SZiziyukPRofvs0YHZbx"
readonly OFFICIAL_SIGNER_FINGERPRINT="SHA256:m1EbotpPqWJ2dAhml0iska2ToWgeflq3cIAgyq9qSP0"
readonly INSTALL_ROOT="/opt/vps-nook-installer"
readonly REPO_DIR="${INSTALL_ROOT}/repo"
readonly VENV_DIR="${INSTALL_ROOT}/venv"
readonly MIN_AVAILABLE_MEMORY_MIB=900

VAULT_DIR="/etc/vps-nook"
VAULT_PASS_FILE="${VAULT_DIR}/installer-vault.pass"
VAULT_FILE="${VAULT_DIR}/installer-vault.yml"
VAULT_MARKER="${VAULT_DIR}/.installer-vault.incomplete"
VAULT_LOCK_FILE="${VAULT_DIR}/.installer.lock"
VAULT_OWNER="root"
VAULT_ANSIBLE_BIN="${VENV_DIR}/bin/ansible-vault"
VAULT_PYTHON_BIN="${VENV_DIR}/bin/python"
ANSIBLE_PULL_BIN="${VENV_DIR}/bin/ansible-pull"
OPENSSL_BIN="openssl"
VAULT_COMMAND_TIMEOUT=30
ANSIBLE_PULL_TIMEOUT=3600

RESOLVED_RELEASE_REF=""
REPO_URL="${OFFICIAL_REPO_URL}"
RELEASE_REF="${OFFICIAL_RELEASE_REF}"
DEVELOPMENT_MODE=false
CREATED_INSTALL_ROOT=false
CREATED_REPO_DIR=false
CREATED_VENV_DIR=false
EXTRA_VARS_FILE=""
VAULT_PLAIN_FILE=""
VAULT_PASS_TEMP=""
VAULT_FILE_TEMP=""
VAULT_MARKER_TEMP=""
VAULT_LOCK_FD=""
ALLOWED_SIGNERS_FILE=""
REPO_CONFIG_BACKUP=""
REPO_CONFIG_MODE=""
REPO_CONFIG_ISOLATED=false
SSH_PORT=""
WG_PORT=""
ADMIN_USER=""
ADMIN_PASSWORD=""
ADGUARD_PASSWORD=""
INTERNAL_DOMAINS=""
WG_INTERNAL_DOMAIN=""
ADGUARD_INTERNAL_DOMAIN=""
SSH_PUBKEY=""
WG_PASSWORD=""
WG_HOST=""
WG_TRAFFIC_MODE="services"
WG_TRAFFIC_MODE_INPUT=""
INTERNAL_DOMAIN_SUFFIX=""
NONINTERACTIVE=""
REUSE_INSTALLER_STATE=false
INHERITED_ADMIN_PASSWORD=""
INHERITED_ADGUARD_PASSWORD=""
INHERITED_WG_PASSWORD=""
INHERITED_SSH_PUBKEY=""

cleanup_on_failure() {
    local exit_code=$?

    cleanup_extra_vars_file
    cleanup_vault_temps
    unset ADMIN_PASSWORD ADGUARD_PASSWORD WG_PASSWORD SSH_PUBKEY
    unset INHERITED_ADMIN_PASSWORD INHERITED_ADGUARD_PASSWORD INHERITED_WG_PASSWORD INHERITED_SSH_PUBKEY
    cleanup_allowed_signers_file
    restore_repository_git_config

    if [[ "${exit_code}" -eq 0 ]]; then
        return
    fi
    warn "Stopped during ${CURRENT_STAGE:-startup} (exit ${exit_code})."
    if [[ -f ${VAULT_FILE} ]]; then
        warn "Encrypted inputs remain at ${VAULT_DIR}. Rerun the same tagged installer after resolving the error."
    else
        warn "No complete installer vault is available. Review the error before starting again."
    fi
    warn "Host-wide rollback is not implied; keep the original SSH session open."

    if [[ "${CREATED_REPO_DIR}" == "true" && "${CREATED_INSTALL_ROOT}" != "true" ]]; then
        warn "Installation failed. Removing partial repository checkout at ${REPO_DIR}."
        rm -rf "${REPO_DIR}"
    fi
    if [[ "${CREATED_VENV_DIR}" == "true" && "${CREATED_INSTALL_ROOT}" != "true" ]]; then
        warn "Installation failed. Removing partial Ansible virtualenv at ${VENV_DIR}."
        rm -rf "${VENV_DIR}"
    fi
    if [[ "${CREATED_INSTALL_ROOT}" == "true" ]]; then
        warn "Installation failed. Removing partial installer state at ${INSTALL_ROOT}."
        rm -rf "${INSTALL_ROOT}"
    fi
}
trap cleanup_on_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

cleanup_extra_vars_file() {
    if [[ -n "${EXTRA_VARS_FILE}" && -e "${EXTRA_VARS_FILE}" ]]; then
        rm -f "${EXTRA_VARS_FILE}"
    fi
}

cleanup_vault_temps() {
    local path
    for path in "${VAULT_PLAIN_FILE}" "${VAULT_PASS_TEMP}" "${VAULT_FILE_TEMP}" "${VAULT_MARKER_TEMP}"; do
        [[ -n "${path}" ]] && rm -f -- "${path}"
    done
    VAULT_PLAIN_FILE=""
    VAULT_PASS_TEMP=""
    VAULT_FILE_TEMP=""
    VAULT_MARKER_TEMP=""
}

cleanup_allowed_signers_file() {
    if [[ -n "${ALLOWED_SIGNERS_FILE}" && -e "${ALLOWED_SIGNERS_FILE}" ]]; then
        rm -f "${ALLOWED_SIGNERS_FILE}"
    fi
    ALLOWED_SIGNERS_FILE=""
}

restore_repository_git_config() {
    if [[ "${REPO_CONFIG_ISOLATED}" == "true" ]]; then
        cp -- "${REPO_CONFIG_BACKUP}" "${REPO_DIR}/.git/config"
        chmod "${REPO_CONFIG_MODE}" "${REPO_DIR}/.git/config"
        REPO_CONFIG_ISOLATED=false
    fi
    if [[ -n "${REPO_CONFIG_BACKUP}" && -e "${REPO_CONFIG_BACKUP}" ]]; then
        rm -f "${REPO_CONFIG_BACKUP}"
    fi
    REPO_CONFIG_BACKUP=""
    REPO_CONFIG_MODE=""
}

usage() {
    cat <<EOF
Usage: install.sh

Verify the release assets locally, then run:

  sudo bash ./install.sh

Interactive public installer for VPS Nook.

Production mode accepts only:
  https://github.com/NikitaS2001/vps-nook.git at v2.0.0
  Its annotated SSH-signed tag must match nikitasmadych2001@gmail.com
  (SHA256:m1EbotpPqWJ2dAhml0iska2ToWgeflq3cIAgyq9qSP0). The installer peels
  it to an exact SHA, detaches the checkout, and passes that SHA to ansible-pull.

Development-only source override (never production):
  NOOK_DEV_MODE=1   Enables NOOK_REPO_URL and NOOK_RELEASE_REF
                          and emits NON-PRODUCTION DEVELOPMENT MODE.

Quick installation trusts the HTTPS source of the executed script. For
pre-execution verification, verify the tagged release asset attestation and checksum before
executing it. The installer independently verifies the SSH-signed tag and exact
resolved SHA. Temporary signer and secret files are removed after success or failure.

Non-interactive mode for automated testing:
  NOOK_NONINTERACTIVE=1  Run without prompts. A fresh installation needs
                               the required NOOK_* inputs below.
  NOOK_SSH_PORT          Hardened SSH port (optional, default from role)
  NOOK_WG_PORT           WireGuard UDP port (optional, default from role)
  NOOK_ADMIN_USER        Admin username (optional, default from role)
  NOOK_ADMIN_PASSWORD    Admin password (required, min 8 chars)
  NOOK_ADGUARD_PASSWORD  AdGuard admin password (required, min 8 chars)
  NOOK_WG_PASSWORD       WireGuard panel password (required, min 12 chars)
  NOOK_INTERNAL_DOMAINS  Two internal hostnames, space separated
  NOOK_INTERNAL_DOMAIN_SUFFIX  Local DNS suffix for the internal domains
                               (optional, default internal; recommended
                               .internal or .home.arpa)
  NOOK_SSH_PUBKEY        SSH public key for the admin user (required)
  NOOK_WG_HOST           Public hostname/IP for clients (optional,
                               auto-detected when omitted)
  NOOK_WG_TRAFFIC_MODE   VPN routing: services or full
                          (optional, default services)

On rerun, the encrypted installer state is authoritative. Omit credential
inputs; any supplied non-secret input must match its persisted value.

This installer supports amd64 hosts with at least 900 MiB of RAM visible to
the OS, which normally corresponds to a 1 GB VPS plan.
Existing swap is reported for diagnostics and is never changed.

The public quickstart should use a tagged release, never main.
EOF
}

CURRENT_STAGE="Startup"
STAGE_STARTED=0
UI_ACCENT=""
UI_RESET=""
UI_OK=""
UI_WARN=""
UI_ERROR=""

init_ui() {
    if [[ -t 1 && -t 2 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]]; then
        UI_ACCENT=$'\033[36m'
        UI_OK=$'\033[32m'
        UI_WARN=$'\033[33m'
        UI_ERROR=$'\033[31m'
        UI_RESET=$'\033[0m'
    fi
}

stage() {
    if (( STAGE_STARTED > 0 )); then
        printf '  Previous stage: %ss\n' "$((SECONDS - STAGE_STARTED))"
    fi
    CURRENT_STAGE="$1"
    STAGE_STARTED=$SECONDS
    printf '\n%s  %s%s\n\n' "${UI_ACCENT}" "${CURRENT_STAGE}" "${UI_RESET}"
}

reject_legacy_inputs() {
    local name legacy_path
    for name in "${!ZERO_TRUST_@}"; do
        [[ -n ${name} ]] || continue
        case "${name}" in
            ZERO_TRUST_WG_ENABLE_IPV6|ZERO_TRUST_WG_EASY_ADMIN_PASSWORD)
                error "${name} was removed. See docs/configuration.md for supported NOOK_* inputs." ;;
            *) error "${name} is no longer accepted. Use NOOK_${name#ZERO_TRUST_} instead (value not shown)." ;;
        esac
    done
    for legacy_path in /opt/zero-trust-vps /opt/zero-trust-vps-installer /etc/zero-trust-vps /opt/zt-backups; do
        if [[ -e ${legacy_path} || -L ${legacy_path} ]]; then
            error "Legacy installation found at ${legacy_path}. VPS Nook v2 requires a fresh VPS; see UPGRADE.md. No migration was attempted."
        fi
    done
}

require_tun() {
    [[ -c /dev/net/tun ]] || error "/dev/net/tun is unavailable. Enable TUN in the VPS provider settings before retrying."
}

info() { printf '%s[INFO]%s  %s\n' "${UI_OK}" "${UI_RESET}" "$*"; }
warn() { printf '%s[WARN]%s  %s\n' "${UI_WARN}" "${UI_RESET}" "$*" >&2; }
error() {
    printf '%s[ERROR]%s %s\n' "${UI_ERROR}" "${UI_RESET}" "$*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "Run this installer as root: sudo bash ./install.sh"
    fi
}

is_supported_os_release() {
    local distribution_id="${1:-}"
    local version_id="${2:-}"

    case "${distribution_id}:${version_id}" in
        debian:12|debian:12.*|ubuntu:24.04)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

require_supported_os() {
    if [[ ! -r /etc/os-release ]]; then
        error "/etc/os-release not found. This installer supports Debian 12 and Ubuntu 24.04 only."
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    is_supported_os_release "${ID:-}" "${VERSION_ID:-}" \
        || error "Unsupported OS '${ID:-unknown}' version '${VERSION_ID:-unknown}'. This installer supports Debian 12 and Ubuntu 24.04 only."

    command -v apt-get >/dev/null 2>&1 || error "apt-get not found. This installer supports Debian 12 and Ubuntu 24.04 only."
}

platform_arch() {
    uname -m
}

require_supported_platform() {
    local arch
    arch="$(platform_arch)"
    [[ "${arch}" == x86_64 ]] \
        || error "Unsupported platform architecture '${arch}'. This installer supports amd64 only."
}

available_memory_mib() {
    awk '/^MemTotal:/ { print int($2 / 1024); exit }' /proc/meminfo
}

require_minimum_memory() {
    local memory_mib
    memory_mib="$(available_memory_mib)"
    [[ "${memory_mib}" =~ ^[0-9]+$ && "${memory_mib}" -ge "${MIN_AVAILABLE_MEMORY_MIB}" ]] \
        || error "At least ${MIN_AVAILABLE_MEMORY_MIB} MiB of RAM visible to the OS is required (normally a 1 GB VPS plan). Detected ${memory_mib:-unknown} MiB."
}

report_existing_swap() {
    local swap_summary
    swap_summary="$(awk 'NR > 1 { count++; total += $3 } END { printf "%d devices, %d MiB total", count + 0, int(total / 1024) }' /proc/swaps)"
    info "Existing swap: ${swap_summary}. The installer will not change swap configuration."
}

validate_traffic_mode() {
    case "${WG_TRAFFIC_MODE}" in
        services|full) ;;
        *) error "NOOK_WG_TRAFFIC_MODE must be services or full." ;;
    esac
}

require_traffic_egress() {
    [[ "${WG_TRAFFIC_MODE}" == full ]] || return 0
    curl -4 -fsS --max-time 10 -o /dev/null https://api.ipify.org \
        || error "Full-tunnel mode requires working IPv4 egress."
}

open_tty() {
    if [[ ! -r /dev/tty ]]; then
        error "Interactive installation requires a TTY. SSH into the VPS and run the installer from a terminal."
    fi
    { exec 3<>/dev/tty; } 2>/dev/null || error "Interactive installation requires a TTY. Use an SSH terminal or NOOK_NONINTERACTIVE=1."
}

prompt_choice() {
    local __var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local value

    if [[ -n ${default_value} ]]; then
        printf '%s [%s]: ' "${prompt_text}" "${default_value}" >&3
    else
        printf '%s: ' "${prompt_text}" >&3
    fi
    IFS= read -r value <&3 || error "Input closed; installation cancelled."
    printf -v "${__var_name}" '%s' "${value:-${default_value}}"
}

prompt_required_secret() {
    local __var_name="$1"
    local prompt_text="$2"
    local value
    local confirmation
    local minimum="${3:-8}"
    local maximum="${4:-4096}"

    if (( maximum <= 72 )); then
        printf '  Use at least %s characters, at most %s UTF-8 bytes. Input is hidden.\n' "${minimum}" "${maximum}" >&3
    else
        printf '  Use at least %s characters. Input is hidden.\n' "${minimum}" >&3
    fi
    while true; do
        printf "%s: " "${prompt_text}" >&3
        IFS= read -r -s value <&3 || error "Input closed; installation cancelled."
        printf "\n" >&3
        if [[ "${#value}" -lt ${minimum} ]] || ! secret_fits_byte_limit "${value}" "${maximum}"; then
            warn "Use at least ${minimum} characters and at most ${maximum} UTF-8 bytes."
            continue
        fi
        printf "Confirm %s: " "${prompt_text}" >&3
        IFS= read -r -s confirmation <&3 || error "Input closed; installation cancelled."
        printf "\n" >&3
        if [[ "${value}" != "${confirmation}" ]]; then
            warn "Values did not match. Try again."
            continue
        fi
        printf -v "${__var_name}" '%s' "${value}"
        break
    done
}

prompt_required_line() {
    local __var_name="$1"
    local prompt_text="$2"
    local value

    while true; do
        printf "%s: " "${prompt_text}" >&3
        IFS= read -r value <&3 || error "Input closed; installation cancelled."
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ -z "${value}" ]]; then
            warn "Value is required."
            continue
        fi
        printf -v "${__var_name}" '%s' "${value}"
        break
    done
}

validate_port() {
    local label="$1"
    local value="$2"

    if [[ -z "${value}" ]]; then
        return 0
    fi
    if ! [[ "${value}" =~ ^[0-9]{1,5}$ ]] || (( 10#${value} < 1 || 10#${value} > 65535 )); then
        error "${label} must be a number between 1 and 65535. Got: ${value}"
    fi
}

validate_optional_admin_user() {
    local value="$1"

    if [[ -z "${value}" ]]; then
        return 0
    fi
    if ! [[ "${value}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        error "Admin username must be a valid Linux user name. Got: ${value}"
    fi
}

validate_hostname() {
    local value="$1"
    local label
    local -a labels

    if [[ -z "${value}" || "${#value}" -gt 253 || "${value}" == .* || "${value}" == *. ]]; then
        return 1
    fi
    IFS=. read -r -a labels <<<"${value}"
    for label in "${labels[@]}"; do
        if [[ -z "${label}" || "${#label}" -gt 63 || ! "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
            return 1
        fi
    done
}

validate_internal_domains() {
    local value="$1"
    local -a internal_domains

    WG_INTERNAL_DOMAIN=""
    ADGUARD_INTERNAL_DOMAIN=""

    if [[ -z "${value}" ]]; then
        return 0
    fi

    read -r -a internal_domains <<<"${value}"
    if [[ "${#internal_domains[@]}" -ne 2 ]]; then
        error "Internal domains must be exactly two hostnames, for example: wg.internal adguard.internal"
    fi
    validate_hostname "${internal_domains[0]}" || error "Invalid internal hostname: ${internal_domains[0]}"
    validate_hostname "${internal_domains[1]}" || error "Invalid internal hostname: ${internal_domains[1]}"

    [[ ${internal_domains[0]} != "${internal_domains[1]}" ]] || error "Use two distinct internal domains."
    WG_INTERNAL_DOMAIN="${internal_domains[0]}"
    ADGUARD_INTERNAL_DOMAIN="${internal_domains[1]}"
}

validate_internal_domain_suffix() {
    local suffix="$1"
    local domains="$2"

    if [[ -z "${suffix}" ]]; then
        return 0
    fi
    validate_hostname "${suffix}" || error "Invalid internal domain suffix: ${suffix}"
    if [[ -n "${domains}" ]]; then
        local -a internal_domains
        read -r -a internal_domains <<<"${domains}"
        local d
        for d in "${internal_domains[@]}"; do
            if [[ "${d}" != *".${suffix}" ]]; then
                error "Internal domain '${d}' does not end with the configured suffix '.${suffix}'."
            fi
        done
    fi
}

validate_ssh_pubkey() {
    local value="$1"
    local key_type
    local key_body

    read -r key_type key_body _ <<<"${value}"
    case "${key_type}" in
        ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
            ;;
        *)
            error "Unsupported SSH public key type '${key_type}'. Use an OpenSSH public key, including FIDO/U2F sk-* keys."
            ;;
    esac
    if [[ "${#key_body}" -lt 32 || ! "${key_body}" =~ ^[A-Za-z0-9+/]+={0,3}$ ]]; then
        error "SSH public key body does not look like valid base64."
    fi
}

read_yaml_scalar_default() {
    local defaults_file="$1"
    local key="$2"

    awk -F: -v key="${key}" '
        $1 == key {
            value = $0
            sub(/^[^:]+:[[:space:]]*/, "", value)
            gsub(/^["'\''"]|["'\''"]$/, "", value)
            print value
            exit
        }
    ' "${defaults_file}"
}

validate_release_source() {
    case "${NOOK_DEV_MODE:-}" in
        '')
            DEVELOPMENT_MODE=false
            REPO_URL="${NOOK_REPO_URL:-${OFFICIAL_REPO_URL}}"
            RELEASE_REF="${NOOK_RELEASE_REF:-${OFFICIAL_RELEASE_REF}}"
            [[ "${REPO_URL}" == "${OFFICIAL_REPO_URL}" ]] \
                || error "Production mode accepts only the official repository: ${OFFICIAL_REPO_URL}"
            [[ "${RELEASE_REF}" == "${OFFICIAL_RELEASE_REF}" ]] \
                || error "Production mode accepts only the built-in release tag: ${OFFICIAL_RELEASE_REF}"
            ;;
        1)
            DEVELOPMENT_MODE=true
            REPO_URL="${NOOK_REPO_URL:-${OFFICIAL_REPO_URL}}"
            RELEASE_REF="${NOOK_RELEASE_REF:-${OFFICIAL_RELEASE_REF}}"
            warn "NON-PRODUCTION DEVELOPMENT MODE: arbitrary repository and ref enabled."
            ;;
        *)
            error "NOOK_DEV_MODE must be unset or exactly 1."
            ;;
    esac
    if [[ -z "${REPO_URL}" || "${REPO_URL}" =~ [[:space:]] || "${REPO_URL}" == -* ]]; then
        error "NOOK_REPO_URL must be a non-empty git URL without whitespace."
    fi
    if [[ -z "${RELEASE_REF}" || "${RELEASE_REF}" == -* || ! "${RELEASE_REF}" =~ ^[A-Za-z0-9._/@+-]+$ ]]; then
        error "NOOK_RELEASE_REF must be a non-empty git ref using only letters, numbers, '.', '_', '/', '@', '+', or '-'."
    fi
    if [[ "${RELEASE_REF}" == *..* || "${RELEASE_REF}" == *@\{* || "${RELEASE_REF}" == *.lock || "${RELEASE_REF}" == */ || "${RELEASE_REF}" == /* ]]; then
        error "NOOK_RELEASE_REF is not a safe git ref: ${RELEASE_REF}"
    fi
}

ensure_install_root() {
    if [[ ! -e "${INSTALL_ROOT}" ]]; then
        mkdir -p "${INSTALL_ROOT}"
        CREATED_INSTALL_ROOT=true
        return
    fi
    if [[ ! -d "${INSTALL_ROOT}" ]]; then
        error "${INSTALL_ROOT} exists but is not a directory."
    fi
}

install_prerequisites() {
    info "Installing source verification prerequisites..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git openssh-client sudo
    command -v visudo >/dev/null 2>&1 || error "sudo was installed without visudo."
    visudo -cf /etc/sudoers >/dev/null || error "Existing sudoers configuration is invalid."
}

install_ansible_toolchain() {
    info "Installing Ansible in ${VENV_DIR}..."
    apt-get install -y python3 python3-venv
    ensure_install_root
    if [[ ! -e "${VENV_DIR}" ]]; then
        CREATED_VENV_DIR=true
    fi
    python3 -m venv "${VENV_DIR}"
    # Pin the runtime versions validated for Debian 12 and Ubuntu 24.04.
    # passlib 1.7.4 needs bcrypt 4.0.1 because bcrypt >= 4.1 removed __about__.
    "${VENV_DIR}/bin/pip" install --quiet \
        "ansible-core==2.19.11" "passlib==1.7.4" "bcrypt==4.0.1"
    "${VENV_DIR}/bin/pip" uninstall --quiet --yes ansible
}

prepare_allowed_signers_file() {
    local actual_fingerprint

    actual_fingerprint="$(printf '%s\n' "${OFFICIAL_SIGNER_PUBLIC_KEY}" | ssh-keygen -lf - | awk '{print $2}')"
    [[ "${actual_fingerprint}" == "${OFFICIAL_SIGNER_FINGERPRINT}" ]] \
        || error "Built-in release signer fingerprint mismatch."

    ensure_install_root
    ALLOWED_SIGNERS_FILE="$(mktemp "${INSTALL_ROOT}/allowed-signers.XXXXXX")"
    chmod 0600 "${ALLOWED_SIGNERS_FILE}"
    printf '%s %s\n' "${OFFICIAL_SIGNER_IDENTITY}" "${OFFICIAL_SIGNER_PUBLIC_KEY}" >"${ALLOWED_SIGNERS_FILE}"
}

verify_signed_release() {
    local repository="$1"
    local tag="$2"
    local allowed_signers="$3"
    local expected_identity="$4"
    local object_type
    local tagger_email
    local verify_output
    local commit_sha

    if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "[ERROR] Release tag must match exact vX.Y.Z syntax: ${tag}"
        return 1
    fi
    if [[ "$(stat -c '%a' "${allowed_signers}" 2>/dev/null)" != "600" ]]; then
        warn "[ERROR] Release allowed-signers file must have mode 0600."
        return 1
    fi
    object_type="$(release_git -C "${repository}" cat-file -t "refs/tags/${tag}" 2>/dev/null)" || {
        warn "[ERROR] Release tag was not found: ${tag}"
        return 1
    }
    if [[ "${object_type}" != "tag" ]]; then
        warn "[ERROR] Release ref is not an annotated tag: ${tag}"
        return 1
    fi
    tagger_email="$(release_git -C "${repository}" for-each-ref --format='%(taggeremail)' "refs/tags/${tag}")"
    if [[ "${tagger_email}" != "<${expected_identity}>" ]]; then
        warn "[ERROR] Release tagger identity mismatch for ${tag}."
        return 1
    fi
    if ! verify_output="$(
        release_git -C "${repository}" \
            -c gpg.format=ssh \
            -c gpg.ssh.allowedSignersFile="${allowed_signers}" \
            verify-tag --raw "${tag}" 2>&1
    )"; then
        warn "[ERROR] Release tag signature verification failed for ${tag}."
        return 1
    fi
    if [[ "${verify_output}" != *"Good \"git\" signature for ${expected_identity}"* ]]; then
        warn "[ERROR] Release tag signer principal mismatch for ${tag}."
        return 1
    fi
    commit_sha="$(release_git -C "${repository}" rev-parse "${tag}^{commit}")"
    if [[ ! "${commit_sha}" =~ ^[0-9a-f]{40}$ ]]; then
        warn "[ERROR] Release tag did not resolve to a full commit SHA: ${tag}"
        return 1
    fi

    RESOLVED_RELEASE_REF="${commit_sha}"
    info "Verified signed release tag ${tag} for ${expected_identity} at ${commit_sha}."
}

release_git() {
    env -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS \
        GIT_NO_REPLACE_OBJECTS=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 \
        git "$@"
}

isolate_repository_git_config() {
    local config_file="${REPO_DIR}/.git/config"
    local origin_url

    [[ -f "${config_file}" && ! -L "${config_file}" ]] \
        || error "Repository local Git configuration must be a regular file."
    origin_url="$(GIT_CONFIG=/dev/null GIT_CONFIG_COUNT=0 \
        git config --file "${config_file}" --no-includes --get remote.origin.url)" \
        || error "Repository checkout has no origin URL in its local configuration."
    REPO_CONFIG_BACKUP="$(mktemp "${INSTALL_ROOT}/repo-config.XXXXXX")"
    REPO_CONFIG_MODE="$(stat -c '%a' "${config_file}")"
    cp -- "${config_file}" "${REPO_CONFIG_BACKUP}"
    chmod 0600 "${REPO_CONFIG_BACKUP}"
    REPO_CONFIG_ISOLATED=true
    rm -f "${config_file}"
    install -m 0600 /dev/null "${config_file}"
    GIT_CONFIG=/dev/null git config --file "${config_file}" remote.origin.url "${origin_url}"
    GIT_CONFIG=/dev/null git config --file "${config_file}" remote.origin.fetch \
        '+refs/heads/*:refs/remotes/origin/*'
}

checkout_release() {
    local checkout_head
    local existing_origin

    info "Checking out ${REPO_URL} at ${RELEASE_REF}..."
    ensure_install_root
    if [[ -d "${REPO_DIR}/.git" ]]; then
        existing_origin="$(GIT_CONFIG=/dev/null GIT_CONFIG_COUNT=0 \
            git config --file "${REPO_DIR}/.git/config" --no-includes --get remote.origin.url)" \
            || error "Existing checkout has no origin repository."
        [[ "${existing_origin}" == "${REPO_URL}" ]] \
            || error "Existing checkout origin does not match requested repository."
    elif [[ -e "${REPO_DIR}" ]]; then
        error "${REPO_DIR} exists but is not a git checkout. Remove it before retrying."
    else
        CREATED_REPO_DIR=true
        release_git clone --quiet "${REPO_URL}" "${REPO_DIR}"
    fi
    isolate_repository_git_config

    if [[ "${DEVELOPMENT_MODE}" == "true" ]]; then
        release_git -C "${REPO_DIR}" fetch --quiet origin "${RELEASE_REF}"
        RESOLVED_RELEASE_REF="$(release_git -C "${REPO_DIR}" rev-parse 'FETCH_HEAD^{commit}')"
    else
        release_git -C "${REPO_DIR}" fetch --quiet --tags origin
        prepare_allowed_signers_file
        verify_signed_release "${REPO_DIR}" "${RELEASE_REF}" "${ALLOWED_SIGNERS_FILE}" "${OFFICIAL_SIGNER_IDENTITY}" \
            || error "Release signature verification failed."
        cleanup_allowed_signers_file
    fi
    [[ "${RESOLVED_RELEASE_REF}" =~ ^[0-9a-f]{40}$ ]] \
        || error "Release ref did not resolve to a full commit SHA."
    release_git -c core.hooksPath=/dev/null -C "${REPO_DIR}" checkout --quiet --detach "${RESOLVED_RELEASE_REF}"
    checkout_head="$(release_git -C "${REPO_DIR}" rev-parse HEAD)"
    [[ "${checkout_head}" == "${RESOLVED_RELEASE_REF}" ]] \
        || error "Detached checkout HEAD does not match the resolved release SHA."
}

install_collections() {
    info "Installing Ansible collections from requirements.yml..."
    # --force: requirements.yml pins exact versions, and without --force an
    # already-installed older satisfying version would be kept forever.
    "${VENV_DIR}/bin/ansible-galaxy" collection install -r "${REPO_DIR}/requirements.yml" --force
}

# Validators run in a subshell so an invalid field does not end the wizard.
prompt_validated() {
    local target="$1" label="$2" fallback="$3"
    shift 3
    local candidate
    while true; do
        prompt_choice candidate "${label}" "${fallback}"
        if ( "$@" "${candidate}" ); then
            printf -v "${target}" '%s' "${candidate}"
            return
        fi
        warn "Please correct this field."
    done
}

validate_endpoint() {
    if [[ -z $1 ]] || ! validate_hostname "$1"; then
        error "Enter a hostname or IPv4 address."
    fi
}

validate_domain_pair() {
    validate_internal_domains "$1"
    [[ ${WG_INTERNAL_DOMAIN} != "${ADGUARD_INTERNAL_DOMAIN}" ]] || error "Use two distinct internal domains."
    validate_internal_domain_suffix "${INTERNAL_DOMAIN_SUFFIX}" "$1"
}

choose_traffic_mode() {
    local selection
    printf '\n  1  Private services only [default]\n     Reach your private DNS and HTTPS services.\n'
    printf '  2  All internet traffic\n     Route internet traffic through this VPS.\n'
    printf '     IPv6 stays outside the VPN if the VPS has no IPv6 egress.\n\n'
    while true; do
        prompt_choice selection "VPN purpose (1 or 2)" "$([[ ${WG_TRAFFIC_MODE} == full ]] && echo 2 || echo 1)"
        case "${selection}" in
            1) WG_TRAFFIC_MODE=services; break ;;
            2) WG_TRAFFIC_MODE=full; break ;;
            *) warn "Choose 1 or 2." ;;
        esac
    done
    WG_TRAFFIC_MODE_INPUT="${WG_TRAFFIC_MODE}"
}

advanced_configuration() {
    local previous_suffix="${INTERNAL_DOMAIN_SUFFIX}"
    prompt_validated SSH_PORT "SSH port" "${SSH_PORT}" validate_port "SSH port"
    prompt_validated WG_PORT "WireGuard UDP port" "${WG_PORT}" validate_port "WireGuard port"
    prompt_validated ADMIN_USER "Administrator username" "${ADMIN_USER}" validate_optional_admin_user
    prompt_validated INTERNAL_DOMAIN_SUFFIX "Internal DNS suffix" "${INTERNAL_DOMAIN_SUFFIX}" validate_endpoint
    if [[ ${INTERNAL_DOMAIN_SUFFIX} != "${previous_suffix}" ]]; then
        INTERNAL_DOMAINS="wg.${INTERNAL_DOMAIN_SUFFIX} adguard.${INTERNAL_DOMAIN_SUFFIX}"
    fi
    prompt_validated INTERNAL_DOMAINS "Internal domains (wg-easy, AdGuard)" "${INTERNAL_DOMAINS}" validate_domain_pair
    validate_internal_domains "${INTERNAL_DOMAINS}"
}

confirm_configuration() {
    local action field
    while true; do
        printf '\n  Ready to install\n\n'
        printf '  Release        %s\n  VPN mode       %s\n  Endpoint       %s\n' "${RELEASE_REF}" "${WG_TRAFFIC_MODE}" "${WG_HOST}"
        printf '  Administrator  %s\n  SSH            TCP %s\n  WireGuard      UDP %s\n' "${ADMIN_USER}" "${SSH_PORT}" "${WG_PORT}"
        printf '  Internal sites %s\n\n' "${INTERNAL_DOMAINS}"
        warn "Open these ports in your provider firewall. Keep this SSH session and provider console access available."
        prompt_choice action "Install, edit, or cancel (i/e/c)" c
        case "${action}" in
            i|I) return ;;
            e|E)
                if [[ ${REUSE_INSTALLER_STATE} == true ]]; then
                    warn "Saved configuration is immutable on rerun. Cancel and follow the configuration guide to change it."
                    continue
                fi
                printf '\n  1 VPN mode   2 Endpoint   3 SSH key   4 Admin password\n'
                printf '  5 AdGuard password   6 WireGuard password   7 Advanced settings\n'
                prompt_choice field "Field to edit" 1
                case "${field}" in
                    1) choose_traffic_mode ;;
                    2) prompt_validated WG_HOST "Public endpoint" "${WG_HOST}" validate_endpoint ;;
                    3) prompt_validated SSH_PUBKEY "SSH public key" "${SSH_PUBKEY}" validate_ssh_pubkey ;;
                    4) prompt_required_secret ADMIN_PASSWORD "Administrator account password" 8 ;;
                    5) prompt_required_secret ADGUARD_PASSWORD "AdGuard password" 8 72 ;;
                    6) prompt_required_secret WG_PASSWORD "WireGuard panel password" 12 ;;
                    7) advanced_configuration ;;
                    *) warn "Choose a field from 1 to 7." ;;
                esac
                ;;
            c|C) warn "Cancelled. Server roles were not applied; source-verification packages may remain installed."; exit 130 ;;
            *) warn "Choose i, e, or c." ;;
        esac
    done
}

collect_configuration() {
    if [[ -n "${NOOK_WG_ENABLE_IPV6:-}" ]]; then
        error "NOOK_WG_ENABLE_IPV6 is no longer accepted. IPv6 full-tunnel routing is enabled automatically when host IPv6 egress is available."
    fi
    if [[ "${NONINTERACTIVE}" == "1" ]]; then
        collect_configuration_noninteractive
        return
    fi

    stage "Step 1 of 4 - Network"
    choose_traffic_mode
    WG_HOST="$(detect_public_ip)"
    prompt_validated WG_HOST "Public WireGuard hostname or IPv4" "${WG_HOST}" validate_endpoint
    resolve_effective_installer_inputs

    stage "Step 2 of 4 - Access"
    info "Use the public key from your computer, never its private key."
    prompt_validated SSH_PUBKEY "SSH public key" "" validate_ssh_pubkey
    info "SSH uses your key. This password is for local account access; sudo is configured without a password."
    prompt_required_secret ADMIN_PASSWORD "Administrator account password" 8
    info "Choose separate passwords for DNS administration and VPN client management."
    prompt_required_secret ADGUARD_PASSWORD "AdGuard password" 8 72
    prompt_required_secret WG_PASSWORD "WireGuard panel password" 12

    stage "Step 3 of 4 - Settings"
    local advanced
    while true; do
        prompt_choice advanced "Customize ports, username, or internal domains? (y/n)" n
        case "${advanced}" in
            y|Y) advanced_configuration; break ;;
            n|N) break ;;
            *) warn "Choose y or n." ;;
        esac
    done
    stage "Step 4 of 4 - Review"
    confirm_configuration
}

require_min_length() {
    local value="$1"
    local label="$2"
    local min="${3:-8}"

    if [[ "${#value}" -lt "${min}" ]]; then
        error "${label} must be at least ${min} characters."
    fi
}

secret_fits_byte_limit() {
    local LC_ALL=C
    [[ ${#1} -le $2 ]]
}

require_max_length() {
    local value="$1"
    local label="$2"
    local max="$3"

    if ! secret_fits_byte_limit "${value}" "${max}"; then
        error "${label} must be at most ${max} UTF-8 bytes (bcrypt limit)."
    fi
}

detect_public_ip() {
    local ip=""

    ip="$(curl -fsS --max-time 10 -4 https://api.ipify.org 2>/dev/null)" || ip=""
    if [[ -z "${ip}" ]]; then
        ip="$(curl -fsS --max-time 10 -4 https://ifconfig.me 2>/dev/null)" || ip=""
    fi
    if [[ -z "${ip}" ]]; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    fi
    printf '%s' "${ip}"
}

collect_configuration_noninteractive() {
    if [[ -n "${NOOK_WG_EASY_ADMIN_PASSWORD:-}" ]]; then
        error "NOOK_WG_EASY_ADMIN_PASSWORD is no longer accepted. Use NOOK_WG_PASSWORD; it is persisted only in the encrypted installer vault."
    fi
    WG_TRAFFIC_MODE_INPUT="${NOOK_WG_TRAFFIC_MODE:-}"
    WG_TRAFFIC_MODE="${WG_TRAFFIC_MODE_INPUT:-services}"
    SSH_PORT="${NOOK_SSH_PORT:-}"
    WG_PORT="${NOOK_WG_PORT:-}"
    ADMIN_USER="${NOOK_ADMIN_USER:-}"
    ADMIN_PASSWORD="${INHERITED_ADMIN_PASSWORD}"
    ADGUARD_PASSWORD="${INHERITED_ADGUARD_PASSWORD}"
    WG_PASSWORD="${INHERITED_WG_PASSWORD}"
    INTERNAL_DOMAINS="${NOOK_INTERNAL_DOMAINS:-}"
    INTERNAL_DOMAIN_SUFFIX="${NOOK_INTERNAL_DOMAIN_SUFFIX:-}"
    SSH_PUBKEY="${INHERITED_SSH_PUBKEY}"
    WG_HOST="${NOOK_WG_HOST:-}"

    local missing=""
    local var
    if [[ "${REUSE_INSTALLER_STATE}" != true \
        && ( ! -f "${VAULT_PASS_FILE}" || ! -f "${VAULT_FILE}" ) ]]; then
        for var in ADMIN_PASSWORD ADGUARD_PASSWORD WG_PASSWORD SSH_PUBKEY; do
            if [[ -z "${!var}" ]]; then
                missing="${missing} NOOK_${var}"
            fi
        done
    fi
    if [[ -n "${missing}" ]]; then
        error "Non-interactive mode requires the following environment variables:${missing}"
    fi

    if [[ -n "${ADMIN_PASSWORD}${ADGUARD_PASSWORD}${WG_PASSWORD}" ]]; then
        require_min_length "${ADMIN_PASSWORD}" "Admin password"
        require_min_length "${ADGUARD_PASSWORD}" "AdGuard admin password"
        require_max_length "${ADGUARD_PASSWORD}" "AdGuard admin password" 72
        # wg-easy v15 requires at least 12 characters for the panel password at login.
        require_min_length "${WG_PASSWORD}" "WireGuard panel password" 12
    fi

    validate_port "SSH port" "${SSH_PORT}"
    validate_traffic_mode
    validate_port "WireGuard port" "${WG_PORT}"
    validate_optional_admin_user "${ADMIN_USER}"
    validate_internal_domains "${INTERNAL_DOMAINS}"
    validate_internal_domain_suffix "${INTERNAL_DOMAIN_SUFFIX}" "${INTERNAL_DOMAINS}"
    [[ -z "${SSH_PUBKEY}" ]] || validate_ssh_pubkey "${SSH_PUBKEY}"
    if [[ -n "${WG_HOST}" ]] && ! validate_hostname "${WG_HOST}"; then
        error "Invalid public hostname or IP for WireGuard clients: ${WG_HOST}"
    fi
}

installer_state_paths_present() {
    [[ -e "${VAULT_MARKER}" || -L "${VAULT_MARKER}" \
        || -e "${VAULT_PASS_FILE}" || -L "${VAULT_PASS_FILE}" \
        || -e "${VAULT_FILE}" || -L "${VAULT_FILE}" ]]
}

collect_existing_configuration() {
    if [[ -n "${ADMIN_PASSWORD}${ADGUARD_PASSWORD}${WG_PASSWORD}${SSH_PUBKEY}${INHERITED_ADMIN_PASSWORD}${INHERITED_ADGUARD_PASSWORD}${INHERITED_WG_PASSWORD}${INHERITED_SSH_PUBKEY}" ]]; then
        error "Existing installer state is immutable on rerun; omit credential inputs and use an explicit rotation procedure."
    fi
    collect_configuration_noninteractive
}

resolve_wg_host() {
    if [[ -n "${WG_HOST}" ]]; then
        return
    fi
    info "Detecting the public IP for WireGuard clients..."
    WG_HOST="$(detect_public_ip)"
    if [[ -z "${WG_HOST}" ]]; then
        if [[ "${NONINTERACTIVE}" == "1" ]]; then
            error "Could not auto-detect the public IP. Set NOOK_WG_HOST."
        fi
        prompt_required_line WG_HOST "WireGuard public hostname or IP"
    fi
    info "Using ${WG_HOST} as the WireGuard endpoint host."
}

json_quote() {
    local value="$1"

    printf '%s' "${value}" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

write_extra_var() {
    local key="$1"
    local value="$2"

    {
        printf '%s: ' "${key}"
        json_quote "${value}"
        printf '\n'
    } >>"${EXTRA_VARS_FILE}"
}

write_installer_inputs() {
    write_extra_var wg_traffic_mode "${WG_TRAFFIC_MODE}"
    write_extra_var vps_services_vault_path "${VAULT_FILE}"
}

read_installer_vault_inputs() {
    # shellcheck disable=SC2016
    timeout "${VAULT_COMMAND_TIMEOUT}" "${VAULT_ANSIBLE_BIN}" view \
        --vault-password-file "${VAULT_PASS_FILE}" "${VAULT_FILE}" \
        | "${VAULT_PYTHON_BIN}" -c '
import sys
import yaml

class UniqueKeyLoader(yaml.SafeLoader):
    pass

def construct_unique_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(None, None, "duplicate key", key_node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping

UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    construct_unique_mapping,
)
schema = {
    "ansible_connection",
    "vps_orchestration_enable_ufw_before_ufw_docker",
    "admin_password_hash",
    "vault_adguard_password_hash",
    "wg_easy_bootstrap_secret",
    "wg_public_host",
    "vault_admin_ssh_pubkey",
    "wg_traffic_mode",
    "vps_services_vault_path",
    "ssh_port",
    "wg_port",
    "wg_container_port",
    "admin_user",
    "wg_internal_domain",
    "adguard_internal_domain",
    "internal_domain_suffix",
}
order = (
    "ssh_port",
    "wg_port",
    "wg_container_port",
    "admin_user",
    "wg_public_host",
    "wg_internal_domain",
    "adguard_internal_domain",
    "internal_domain_suffix",
    "wg_traffic_mode",
)
try:
    vault = yaml.load(sys.stdin, Loader=UniqueKeyLoader)
except (TypeError, yaml.YAMLError):
    sys.exit(1)
if not isinstance(vault, dict) or set(vault) != schema:
    sys.exit(1)
if not all(isinstance(value, str) for value in vault.values()):
    sys.exit(1)
if vault["ansible_connection"] != "local":
    sys.exit(1)
if vault["vps_orchestration_enable_ufw_before_ufw_docker"] != "true":
    sys.exit(1)
if vault["vps_services_vault_path"] != sys.argv[1]:
    sys.exit(1)
if not vault["admin_password_hash"].startswith("$6$"):
    sys.exit(1)
if not vault["vault_adguard_password_hash"].startswith(("$2a$", "$2b$", "$2y$")):
    sys.exit(1)
if len(vault["wg_easy_bootstrap_secret"]) < 12:
    sys.exit(1)
if not vault["vault_admin_ssh_pubkey"]:
    sys.exit(1)
for key in order:
    print(vault[key])
' "${VAULT_FILE}"
}

reject_changed_installer_input() {
    local label="$1"
    local supplied="$2"
    local persisted="$3"

    if [[ -n "${supplied}" && "${supplied}" != "${persisted}" ]]; then
        error "Existing installer state uses ${label}=${persisted}; refusing an implicit configuration change."
    fi
}

load_installer_inputs() {
    local serialized_inputs
    local -a persisted_inputs
    local persisted_input
    local persisted_ssh_port persisted_wg_port persisted_wg_container_port
    local persisted_admin_user persisted_wg_host persisted_wg_domain
    local persisted_adguard_domain persisted_domain_suffix persisted_traffic

    serialized_inputs="$(read_installer_vault_inputs)" \
        || error "Existing installer vault has duplicate or missing persisted inputs."
    mapfile -t persisted_inputs <<<"${serialized_inputs}"
    [[ "${#persisted_inputs[@]}" -eq 9 ]] \
        || error "Existing installer vault has an invalid persisted input schema."
    persisted_ssh_port="${persisted_inputs[0]}"
    persisted_wg_port="${persisted_inputs[1]}"
    persisted_wg_container_port="${persisted_inputs[2]}"
    persisted_admin_user="${persisted_inputs[3]}"
    persisted_wg_host="${persisted_inputs[4]}"
    persisted_wg_domain="${persisted_inputs[5]}"
    persisted_adguard_domain="${persisted_inputs[6]}"
    persisted_domain_suffix="${persisted_inputs[7]}"
    persisted_traffic="${persisted_inputs[8]}"

    for persisted_input in "${persisted_inputs[@]}"; do
        [[ -n "${persisted_input}" ]] \
            || error "Existing installer vault has an incomplete input schema."
    done
    [[ "${persisted_wg_container_port}" == "${persisted_wg_port}" ]] \
        || error "Existing installer vault has inconsistent WireGuard ports."

    reject_changed_installer_input ssh_port "${SSH_PORT}" "${persisted_ssh_port}"
    reject_changed_installer_input wg_port "${WG_PORT}" "${persisted_wg_port}"
    reject_changed_installer_input admin_user "${ADMIN_USER}" "${persisted_admin_user}"
    reject_changed_installer_input wg_public_host "${WG_HOST}" "${persisted_wg_host}"
    reject_changed_installer_input wg_internal_domain "${WG_INTERNAL_DOMAIN}" "${persisted_wg_domain}"
    reject_changed_installer_input adguard_internal_domain "${ADGUARD_INTERNAL_DOMAIN}" "${persisted_adguard_domain}"
    reject_changed_installer_input internal_domain_suffix "${INTERNAL_DOMAIN_SUFFIX}" "${persisted_domain_suffix}"
    reject_changed_installer_input wg_traffic_mode "${WG_TRAFFIC_MODE_INPUT}" "${persisted_traffic}"

    SSH_PORT="${persisted_ssh_port}"
    WG_PORT="${persisted_wg_port}"
    ADMIN_USER="${persisted_admin_user}"
    WG_HOST="${persisted_wg_host}"
    WG_INTERNAL_DOMAIN="${persisted_wg_domain}"
    ADGUARD_INTERNAL_DOMAIN="${persisted_adguard_domain}"
    INTERNAL_DOMAINS="${persisted_wg_domain} ${persisted_adguard_domain}"
    INTERNAL_DOMAIN_SUFFIX="${persisted_domain_suffix}"
    WG_TRAFFIC_MODE="${persisted_traffic}"

    validate_port "Persisted SSH port" "${SSH_PORT}"
    validate_port "Persisted WireGuard port" "${WG_PORT}"
    validate_optional_admin_user "${ADMIN_USER}"
    validate_hostname "${WG_HOST}" || error "Persisted WireGuard endpoint is invalid."
    validate_internal_domains "${INTERNAL_DOMAINS}"
    validate_internal_domain_suffix "${INTERNAL_DOMAIN_SUFFIX}" "${INTERNAL_DOMAINS}"
    validate_traffic_mode
}

resolve_effective_installer_inputs() {
    local effective_input

    SSH_PORT="${SSH_PORT:-$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_hardening/defaults/main.yml" ssh_port)}"
    WG_PORT="${WG_PORT:-$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_orchestration/defaults/main.yml" wg_port)}"
    ADMIN_USER="${ADMIN_USER:-$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_hardening/defaults/main.yml" admin_user)}"
    INTERNAL_DOMAIN_SUFFIX="${INTERNAL_DOMAIN_SUFFIX:-$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_orchestration/defaults/main.yml" internal_domain_suffix)}"
    WG_INTERNAL_DOMAIN="${WG_INTERNAL_DOMAIN:-wg.${INTERNAL_DOMAIN_SUFFIX}}"
    ADGUARD_INTERNAL_DOMAIN="${ADGUARD_INTERNAL_DOMAIN:-adguard.${INTERNAL_DOMAIN_SUFFIX}}"
    INTERNAL_DOMAINS="${WG_INTERNAL_DOMAIN} ${ADGUARD_INTERNAL_DOMAIN}"

    for effective_input in \
        "${SSH_PORT}" "${WG_PORT}" "${ADMIN_USER}" "${WG_HOST}" \
        "${WG_INTERNAL_DOMAIN}" "${ADGUARD_INTERNAL_DOMAIN}" \
        "${INTERNAL_DOMAIN_SUFFIX}" "${WG_TRAFFIC_MODE}"; do
        [[ -n "${effective_input}" ]] \
            || error "Could not resolve the effective installer inputs."
    done
    validate_port "SSH port" "${SSH_PORT}"
    validate_port "WireGuard port" "${WG_PORT}"
    validate_optional_admin_user "${ADMIN_USER}"
    validate_hostname "${WG_HOST}" || error "WireGuard endpoint is invalid."
    validate_internal_domains "${INTERNAL_DOMAINS}"
    validate_internal_domain_suffix "${INTERNAL_DOMAIN_SUFFIX}" "${INTERNAL_DOMAINS}"
    validate_traffic_mode
}

fsync_path() {
    "${VAULT_PYTHON_BIN}" - "$1" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

vault_file_is_private() {
    [[ -f "$1" && ! -L "$1" && "$(stat -c '%U:%G:%a:%h' "$1" 2>/dev/null)" == "${VAULT_OWNER}:${VAULT_OWNER}:600:1" ]]
}

validate_installer_vault() {
    vault_file_is_private "${VAULT_PASS_FILE}" \
        && vault_file_is_private "${VAULT_FILE}" \
        && read_installer_vault_inputs >/dev/null
}

acquire_installer_lock() {
    [[ -z "${VAULT_LOCK_FD}" ]] || return 0
    install -d -o "${VAULT_OWNER}" -g "${VAULT_OWNER}" -m 0700 "${VAULT_DIR}"
    [[ -d "${VAULT_DIR}" && ! -L "${VAULT_DIR}" \
        && "$(stat -c '%U:%G:%a' "${VAULT_DIR}" 2>/dev/null)" == "${VAULT_OWNER}:${VAULT_OWNER}:700" ]] \
        || error "Installer vault directory is not private and owner-controlled."
    if [[ -e "${VAULT_LOCK_FILE}" || -L "${VAULT_LOCK_FILE}" ]]; then
        vault_file_is_private "${VAULT_LOCK_FILE}" \
            || error "Installer operation lock is not a private owner-controlled regular file."
    fi
    exec {VAULT_LOCK_FD}>"${VAULT_LOCK_FILE}"
    flock -n "${VAULT_LOCK_FD}" || error "Another VPS Nook installer operation is active."
    chown "${VAULT_OWNER}:${VAULT_OWNER}" "${VAULT_LOCK_FILE}"
    chmod 0600 "${VAULT_LOCK_FILE}"
}

hash_secret() {
    local scheme="$1"
    local secret="$2"
    if [[ "${scheme}" == bcrypt ]]; then
        printf '%s' "${secret}" | "${VAULT_PYTHON_BIN}" -c \
            'import sys; from passlib.hash import bcrypt; print(bcrypt.using(ident="2y", rounds=10).hash(sys.stdin.read()))'
    else
        printf '%s' "${secret}" | "${VAULT_PYTHON_BIN}" -c \
            'import sys; from passlib.hash import sha512_crypt; print(sha512_crypt.hash(sys.stdin.read()))'
    fi
}

write_vault_plaintext() {
    local admin_hash adguard_hash
    admin_hash="$(hash_secret sha512_crypt "${ADMIN_PASSWORD}")"
    adguard_hash="$(hash_secret bcrypt "${ADGUARD_PASSWORD}")"

    resolve_effective_installer_inputs
    EXTRA_VARS_FILE="${VAULT_PLAIN_FILE}"
    write_extra_var ansible_connection local
    write_extra_var vps_orchestration_enable_ufw_before_ufw_docker true
    write_extra_var admin_password_hash "${admin_hash}"
    write_extra_var vault_adguard_password_hash "${adguard_hash}"
    write_extra_var wg_easy_bootstrap_secret "${WG_PASSWORD}"
    write_extra_var wg_public_host "${WG_HOST}"
    write_extra_var vault_admin_ssh_pubkey "${SSH_PUBKEY}"
    write_installer_inputs
    write_extra_var ssh_port "${SSH_PORT}"
    write_extra_var wg_port "${WG_PORT}"
    write_extra_var wg_container_port "${WG_PORT}"
    write_extra_var admin_user "${ADMIN_USER}"
    write_extra_var wg_internal_domain "${WG_INTERNAL_DOMAIN}"
    write_extra_var adguard_internal_domain "${ADGUARD_INTERNAL_DOMAIN}"
    write_extra_var internal_domain_suffix "${INTERNAL_DOMAIN_SUFFIX}"

    unset ADMIN_PASSWORD ADGUARD_PASSWORD WG_PASSWORD SSH_PUBKEY
    unset INHERITED_ADMIN_PASSWORD INHERITED_ADGUARD_PASSWORD INHERITED_WG_PASSWORD INHERITED_SSH_PUBKEY
}

create_installer_vault() {
    VAULT_MARKER_TEMP="$(mktemp "${VAULT_DIR}/.installer-vault.incomplete.XXXXXX")"
    chmod 0600 "${VAULT_MARKER_TEMP}"
    fsync_path "${VAULT_MARKER_TEMP}"
    mv -f -- "${VAULT_MARKER_TEMP}" "${VAULT_MARKER}"
    VAULT_MARKER_TEMP=""
    fsync_path "${VAULT_DIR}"

    VAULT_PASS_TEMP="$(mktemp "${VAULT_DIR}/.installer-vault.pass.XXXXXX")"
    chmod 0600 "${VAULT_PASS_TEMP}"
    timeout "${VAULT_COMMAND_TIMEOUT}" "${OPENSSL_BIN}" rand -hex 32 >"${VAULT_PASS_TEMP}"
    fsync_path "${VAULT_PASS_TEMP}"

    VAULT_PLAIN_FILE="$(mktemp "${VAULT_DIR}/.installer-vault.plain.XXXXXX")"
    chmod 0600 "${VAULT_PLAIN_FILE}"
    write_vault_plaintext
    fsync_path "${VAULT_PLAIN_FILE}"

    VAULT_FILE_TEMP="$(mktemp "${VAULT_DIR}/.installer-vault.yml.XXXXXX")"
    chmod 0600 "${VAULT_FILE_TEMP}"
    timeout "${VAULT_COMMAND_TIMEOUT}" "${VAULT_ANSIBLE_BIN}" encrypt \
        --vault-password-file "${VAULT_PASS_TEMP}" --output "${VAULT_FILE_TEMP}" "${VAULT_PLAIN_FILE}"
    chmod 0600 "${VAULT_FILE_TEMP}"
    fsync_path "${VAULT_FILE_TEMP}"
    timeout "${VAULT_COMMAND_TIMEOUT}" "${VAULT_ANSIBLE_BIN}" view \
        --vault-password-file "${VAULT_PASS_TEMP}" "${VAULT_FILE_TEMP}" | cmp -s - "${VAULT_PLAIN_FILE}" \
        || error "New installer vault failed verification."
    rm -f -- "${VAULT_PLAIN_FILE}"
    VAULT_PLAIN_FILE=""
    EXTRA_VARS_FILE=""

    mv -f -- "${VAULT_PASS_TEMP}" "${VAULT_PASS_FILE}"
    VAULT_PASS_TEMP=""
    fsync_path "${VAULT_DIR}"
    mv -f -- "${VAULT_FILE_TEMP}" "${VAULT_FILE}"
    VAULT_FILE_TEMP=""
    fsync_path "${VAULT_DIR}"
    validate_installer_vault || error "Persisted installer vault failed verification."
}

prepare_installer_vault() {
    acquire_installer_lock
    if [[ -e "${VAULT_MARKER}" || -L "${VAULT_MARKER}" ]]; then
        vault_file_is_private "${VAULT_MARKER}" || error "Installer vault marker is not a private owner-controlled regular file."
        if validate_installer_vault; then
            rm -f -- "${VAULT_MARKER}"
            fsync_path "${VAULT_DIR}"
            load_installer_inputs
            unset ADMIN_PASSWORD ADGUARD_PASSWORD WG_PASSWORD SSH_PUBKEY
            unset INHERITED_ADMIN_PASSWORD INHERITED_ADGUARD_PASSWORD INHERITED_WG_PASSWORD INHERITED_SSH_PUBKEY
            require_traffic_egress
            return
        fi
        error "Interrupted installer vault transaction is incomplete or invalid; committed paths were preserved for manual recovery."
    elif [[ -e "${VAULT_PASS_FILE}" || -L "${VAULT_PASS_FILE}" \
        || -e "${VAULT_FILE}" || -L "${VAULT_FILE}" ]]; then
        [[ ( -e "${VAULT_PASS_FILE}" || -L "${VAULT_PASS_FILE}" ) \
            && ( -e "${VAULT_FILE}" || -L "${VAULT_FILE}" ) ]] \
            || error "Incomplete installer vault; refusing to deploy."
        validate_installer_vault || error "Existing installer vault is invalid; refusing to deploy."
        load_installer_inputs
        unset ADMIN_PASSWORD ADGUARD_PASSWORD WG_PASSWORD SSH_PUBKEY
        unset INHERITED_ADMIN_PASSWORD INHERITED_ADGUARD_PASSWORD INHERITED_WG_PASSWORD INHERITED_SSH_PUBKEY
        require_traffic_egress
        return
    fi
    require_traffic_egress
    create_installer_vault
}

run_ansible_pull() {
    prepare_installer_vault

    if [[ "${RESOLVED_RELEASE_REF}" != "${RELEASE_REF}" ]]; then
        info "Running ansible-pull from ${REPO_URL} at ${RELEASE_REF} (resolved to ${RESOLVED_RELEASE_REF})..."
    else
        info "Running ansible-pull from ${REPO_URL} at ${RELEASE_REF}..."
    fi
    rm -f -- "${VAULT_MARKER}"
    fsync_path "${VAULT_DIR}"
    env -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS \
        ANSIBLE_VAULT_PASSWORD_FILE="${VAULT_PASS_FILE}" \
        GIT_NO_REPLACE_OBJECTS=1 \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
        timeout "${ANSIBLE_PULL_TIMEOUT}" "${ANSIBLE_PULL_BIN}" \
        -U "${REPO_URL}" \
        -C "${RESOLVED_RELEASE_REF}" \
        -d "${REPO_DIR}" \
        -i inventory/localhost.yml \
        --vault-password-file "${VAULT_PASS_FILE}" \
        --extra-vars "@${VAULT_FILE}" \
        site.yml || error "ansible-pull failed; the encrypted installer state was retained for a safe rerun."
    restore_repository_git_config
}

print_summary() {
    local ssh_host='<vps-address>' server_addr
    local -a connection_fields
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        read -r -a connection_fields <<<"${SSH_CONNECTION}"
        server_addr="${connection_fields[2]:-}"
        if [[ ${server_addr} =~ ^[0-9a-fA-F:.]+$ ]]; then
            ssh_host="${server_addr}"
        fi
    fi
    local ui_port
    ui_port="$(read_yaml_scalar_default "${REPO_DIR}/roles/vps_hardening/defaults/main.yml" wg_easy_bootstrap_ui_port)"
    stage "Installation complete - Connect your first client"
    cat <<EOF
  1. On your computer, verify a NEW SSH login and keep this session open:

     ssh -p ${SSH_PORT} ${ADMIN_USER}@${ssh_host}

  2. On your computer, open the WireGuard panel tunnel:

     ssh -p ${SSH_PORT} -L ${ui_port}:127.0.0.1:${ui_port} ${ADMIN_USER}@${ssh_host}

     Open http://127.0.0.1:${ui_port} and sign in with your WireGuard panel password.
     Create a client, import its profile into WireGuard, then connect.
     VPN endpoint: ${WG_HOST}:${WG_PORT} (UDP); mode: ${WG_TRAFFIC_MODE}.

  3. Trust the Caddy root CA on your computer or phone:

     Server copy: ${REPO_DIR}/fetched_certs/localhost/root.crt
     Instructions: https://github.com/NikitaS2001/vps-nook/blob/${RELEASE_REF}/docs/getting-started.md#trust-the-internal-ca

  4. With the VPN connected, check both sites:

     https://${WG_INTERNAL_DOMAIN}
     https://${ADGUARD_INTERNAL_DOMAIN}

  Health check on the VPS:
     sudo ${REPO_DIR}/scripts/synthetic-check.sh

  Local checks cannot prove a new remote SSH login. Verify step 1 before disconnecting.
EOF
}

main() {
    export -n ADMIN_PASSWORD ADGUARD_PASSWORD WG_PASSWORD SSH_PUBKEY 2>/dev/null || true
    export -n INHERITED_ADMIN_PASSWORD INHERITED_ADGUARD_PASSWORD INHERITED_WG_PASSWORD INHERITED_SSH_PUBKEY 2>/dev/null || true
    INHERITED_ADMIN_PASSWORD="${NOOK_ADMIN_PASSWORD:-}"
    INHERITED_ADGUARD_PASSWORD="${NOOK_ADGUARD_PASSWORD:-}"
    INHERITED_WG_PASSWORD="${NOOK_WG_PASSWORD:-}"
    INHERITED_SSH_PUBKEY="${NOOK_SSH_PUBKEY:-}"
    export -n NOOK_ADMIN_PASSWORD NOOK_ADGUARD_PASSWORD NOOK_WG_PASSWORD NOOK_SSH_PUBKEY 2>/dev/null || true
    unset NOOK_ADMIN_PASSWORD NOOK_ADGUARD_PASSWORD NOOK_WG_PASSWORD NOOK_SSH_PUBKEY

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi
    if [[ $# -gt 0 ]]; then
        error "Unknown option: $1. Use --help for usage."
    fi

    init_ui
    reject_legacy_inputs
    NONINTERACTIVE="${NOOK_NONINTERACTIVE:-0}"
    [[ ${NONINTERACTIVE} == 0 || ${NONINTERACTIVE} == 1 ]] || error "NOOK_NONINTERACTIVE must be 0 or 1."
    printf '\n%s  VPS NOOK%s\n  Your private network, on your server.\n' "${UI_ACCENT}" "${UI_RESET}"
    stage "Checking server"

    # A fresh Debian/Ubuntu VPS usually only has C.UTF-8 generated, while the
    # SSH session forwards the caller's locale (e.g. ru_RU.UTF-8). Ansible
    # aborts with "unsupported locale setting" in that case, so pin a safe
    # locale for the toolchain and ansible-pull steps.
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8

    validate_release_source
    require_root
    require_supported_os
    require_supported_platform
    require_minimum_memory
    require_tun
    report_existing_swap
    info "System: ${PRETTY_NAME:-supported Linux}; memory: $(available_memory_mib) MiB; target: ${RELEASE_REF}"
    if [[ "${NONINTERACTIVE}" != 1 ]]; then
        open_tty
    fi
    if installer_state_paths_present; then
        REUSE_INSTALLER_STATE=true
        info "Existing encrypted installer state detected; persisted deployment inputs will be reused."
        collect_existing_configuration
    elif [[ ${NONINTERACTIVE} == 1 ]]; then
        # Fail invalid automated inputs before installing any prerequisites.
        collect_configuration
    fi
    stage "Verifying release"
    install_prerequisites
    if [[ -d ${REPO_DIR}/.git ]]; then
        info "Current checkout: $(release_git -C "${REPO_DIR}" rev-parse HEAD)"
    fi
    checkout_release
    if [[ ${REUSE_INSTALLER_STATE} != true ]]; then
        if [[ ${NONINTERACTIVE} == 1 ]]; then
            resolve_wg_host
        else
            collect_configuration
        fi
    fi
    stage "Preparing Ansible"
    install_ansible_toolchain
    install_collections
    if [[ ${REUSE_INSTALLER_STATE} == true && ${NONINTERACTIVE} != 1 ]]; then
        load_installer_inputs
        confirm_configuration
    fi
    stage "Installing and checking services"
    run_ansible_pull
    print_summary
}

# Piped shell execution leaves BASH_SOURCE unset; ${parameter:-$0} still invokes main.
# Sourcing the file keeps BASH_SOURCE different from $0, so tests can stub main.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
