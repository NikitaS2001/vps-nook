#!/usr/bin/env bash
# This helper prepares matching client tools only. The server module must come from the production role.
set -euo pipefail
umask 077
readonly TOOLS_COMMIT=9f70177d204d5be66c5b043518a57b7d62b3f9d1
readonly TOOLS_SHA256=090f9383532822a756d078890b447e00af7f46bd30a10f9f47c46d633d807b19
readonly TOOLS_VERSION=3.0.20260805
[[ $# -eq 1 ]] || { echo 'Usage: prepare-vpn-client.sh wg|awg' >&2; exit 2; }
readonly CLIENT_BACKEND="$1"
case "${CLIENT_BACKEND}" in wg|awg) ;; *) echo 'Expected backend: wg or awg' >&2; exit 2 ;; esac
[[ "${EUID}" -eq 0 ]] || exit 1
[[ "${CLIENT_BACKEND}" != awg || -d /sys/module/amneziawg ]] || exit 1
prepare_client_dependencies() {
    local -a packages=(jq openssl dnsutils)
    case "${CLIENT_BACKEND}" in
        wg) packages+=(wireguard-tools) ;;
        awg) packages+=(curl) ;;
    esac
    local resolver existing state status
    if state="$(systemctl is-active systemd-resolved)"; then
        [[ "${state}" == active ]] || return 1
        # Keep the active distro resolver. Installing Debian resolvconf replaces
        # its resolv.conf symlink with a stub-only resolver and breaks DNS.
        if ! resolver="$(command -v resolvectl)" || [[ ! -x "${resolver}" ]]; then
            echo 'systemd-resolved is active, but resolvectl is missing or not executable. The helper refuses to replace the resolver.' >&2
            return 1
        fi
        if existing="$(command -v resolvconf)"; then
            [[ "$(readlink -f -- "${existing}")" == "$(readlink -f -- "${resolver}")" ]] || {
                echo 'Refusing a conflicting resolvconf provider with active systemd-resolved' >&2
                return 1
            }
        else
            [[ ! -e /usr/local/bin/resolvconf && ! -L /usr/local/bin/resolvconf ]] || return 1
            # resolvectl supports the resolvconf CLI when invoked under this name.
            ln -s -- "${resolver}" /usr/local/bin/resolvconf
        fi
    else
        status=$?
        [[ "${status}" == 3 && "${state}" == inactive ]] || {
            echo 'Resolver service state is indeterminate. The helper refuses to replace the resolver.' >&2
            return 1
        }
        packages+=(resolvconf)
    fi
    apt-get update -qq >/dev/null
    apt-get install -y -qq --no-install-recommends "${packages[@]}" >/dev/null
}
prepare_client_dependencies
[[ "${CLIENT_BACKEND}" == awg ]] || exit 0
client_build="$(mktemp -d /var/tmp/nook-awg-client-build.XXXXXX)"
trap 'rm -rf -- "${client_build}"' EXIT HUP INT TERM
curl --fail --location --silent --show-error --max-time 120 \
    "https://codeload.github.com/amnezia-vpn/amneziawg-tools/tar.gz/${TOOLS_COMMIT}" \
    -o "${client_build}/tools.tar.gz"
printf '%s  %s\n' "${TOOLS_SHA256}" "${client_build}/tools.tar.gz" | sha256sum --check --status
mkdir "${client_build}/source"
tar --extract --gzip --file "${client_build}/tools.tar.gz" --directory "${client_build}/source" \
    --strip-components=1 --no-same-owner --no-same-permissions
systemd-run --quiet --wait --pipe --collect --unit=nook-awg-client-build \
    -p MemoryMax=512M -p MemorySwapMax=0 -p CPUQuota=100% -p RuntimeMaxSec=1200 \
    -p PrivateNetwork=yes /usr/bin/make -C "${client_build}/source/src" -j1
"${client_build}/source/src/wg" --version | grep -q "${TOOLS_VERSION}"
for destination in /usr/local/bin/awg /usr/local/bin/awg-quick; do
    [[ ! -e "${destination}" && ! -L "${destination}" ]] || { printf 'Refusing existing client tool: %s\n' "${destination}" >&2; exit 1; }
done
install -m 0755 "${client_build}/source/src/wg" /usr/local/bin/awg
install -m 0755 "${client_build}/source/src/wg-quick/linux.bash" /usr/local/bin/awg-quick
