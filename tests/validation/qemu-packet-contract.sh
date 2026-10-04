#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly ROOT_DIR
readonly CLIENT="${ROOT_DIR}/tests/e2e/client-in-guest.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qemu-packet-contract.XXXXXX")"
trap 'rm -rf -- "${TMP_DIR}"' EXIT
cd "${TMP_DIR}"
# Each adapter matrix runs in its own Bash process, separate from controller
# commands. Function extraction is the existing owner seam, not a product hook.
bash -se -- "${CLIENT}" "${TMP_DIR}" <<'PACKET_CASES'
set -euo pipefail
IFS=$'\n\t'
CLIENT="$1" TMP_DIR="$2"
# Load actual function bodies without executing guest setup on the controller.
source <(awk '/^[a-z_]+\(\) \{/ {body=1} body {print} /^}/ {body=0}' "${CLIENT}")

# Execute the actual request owner with a command adapter, never host networking.
(
    export WG_DOMAIN=wg.internal CADDY_IP=10.66.0.3 ROOT_CA=/private/root.crt
    curl() {
        local interface=false proxy=false ca=false
        while (($#)); do
            case "$1" in
                --interface) [[ "$2" == zt-e2e ]] && interface=true; shift ;;
                --noproxy) [[ "$2" == '*' ]] && proxy=true; shift ;;
                --cacert) [[ "$2" == /private/root.crt ]] && ca=true; shift ;;
            esac
            shift
        done
        [[ "${interface}" == true && "${proxy}" == true && "${ca}" == true ]]
    }
    export -f curl
    caddy_request /
) || { echo 'qemu-packet-contract: trusted request is not tunnel bound' >&2; exit 1; }

(
    export WG_DOMAIN=wg.internal CADDY_IP=10.66.0.3 ROOT_CA=/private/root.crt CLIENT_IPV4=10.8.0.7
    curl() {
        local arguments="$*"
        [[ "${arguments}" == *'--interface'* && "${arguments}" == *'zt-e2e'* \
            && "${arguments}" == *'--noproxy'* && "${arguments}" == *'--cacert'* ]]
    }
    dig() {
        [[ "$*" == *'-b'* && "$*" == *'10.8.0.7'* && "$*" == *'@10.66.0.2'* ]] || return 1
        printf '10.66.0.3\n'
    }
    export -f curl dig
    service_https wg.internal
    service_https adguard.internal
    [[ "$(service_dns wg.internal)" == 10.66.0.3 ]]
    [[ "$(service_dns adguard.internal)" == 10.66.0.3 ]]
)

for backend in wg awg; do
for scenario in retained deleted-peer changed-server changed-profile missing-id changed-parameters; do
    (
        export CLIENT_ID=7 UI_PORT=51821 VPN_TOOL="${backend}"
        printf '[Interface]\nPrivateKey = fixture-private\n[Peer]\nPublicKey = fixture-server\n' >original.conf
        if [[ "${backend}" == awg ]]; then
            printf 'H1 = 11\nH2 = 12\nH3 = 13\nH4 = 14\n' >>original.conf
        fi
        api() {
            case "$1" in
                */configuration)
                    cat original.conf
                    [[ "${scenario}" != changed-profile ]] || echo 'Jc = 5'
                    ;;
                */api/client)
                    [[ "${scenario}" != missing-id ]] || { echo '[]'; return; }
                    printf '[{"id":7,"publicKey":"fixture-client"}]\n'
                    ;;
                *) return 2 ;;
            esac
        }
        wg() { [[ "$1" == pubkey ]] || return 2; cat >/dev/null; echo fixture-client; }
        awg() { wg "$@"; }
        docker() {
            [[ "$1" == exec && "$2" == wg-easy && "$3" == "${backend}" ]] || return 2
            case "$4 ${6:-}" in
                'show public-key')
                    [[ "${scenario}" != changed-server ]] || { echo wrong-server; return; }
                    echo fixture-server ;;
                'show peers')
                    [[ "${scenario}" != deleted-peer ]] || return 0
                    echo fixture-client ;;
                'showconf ')
                    awk '/^H[1-4] = /' original.conf
                    [[ "${scenario}" != changed-parameters ]] || echo 'S1 = 57'
                    ;;
                *) return 2 ;;
            esac
        }
        export -f api wg awg docker
        result=0
        peer_fingerprint >fingerprint || result=$?
        if [[ "${scenario}" == retained ]]; then
            [[ "${result}" == 0 && -s fingerprint ]]
        else
            [[ "${result}" != 0 ]]
        fi
    )
done
done

for backend in wg awg; do
    for scenario in fresh kernel-failure response-failure wrong-peer zero-transfer; do
        (
            export VPN_TOOL="${backend}" VPN_LINK=wireguard
            [[ "${backend}" != awg ]] || VPN_LINK=amneziawg
            export CLIENT_IPV4=10.8.0.7 CLIENT_IPV6=fd42:42:42::7 WG_DOMAIN=wg.internal CADDY_IP=10.66.0.3
            printf 'MTU = 1420\n' >original.conf
            ip() {
                printf '%s\n' "$*" >>routes
                if [[ "$1 $2" == 'link add' ]]; then
                    [[ "$4" == type && "$5" == "${VPN_LINK}" ]] || return 2
                    [[ "${scenario}" != kernel-failure ]] || return 42
                    touch kernel-created
                fi
            }
            wg-quick() { [[ "${backend}" == wg && "$1" == strip ]]; }
            awg-quick() { [[ "${backend}" == awg && "$1" == strip ]]; }
            selected_tool() {
                case "$*" in
                    $'setconf\nzt-e2e\nstripped.conf') test -f kernel-created ;;
                    $'show\nzt-e2e\npublic-key') echo fixture-client ;;
                    $'show\nzt-e2e\npeers')
                        [[ "${scenario}" != wrong-peer ]] || { echo wrong; return; }
                        echo fixture-server ;;
                    $'show\nzt-e2e\nlatest-handshakes') printf 'fixture-server\t1\n' ;;
                    $'show\nzt-e2e\ntransfer')
                        [[ "${scenario}" != zero-transfer ]] || { printf 'fixture-server\t0\t0\n'; return; }
                        printf 'fixture-server\t50\t60\n' ;;
                    *) return 2 ;;
                esac
            }
            wg() { [[ "${backend}" == wg ]] || return 2; selected_tool "$@"; }
            awg() { [[ "${backend}" == awg ]] || return 2; selected_tool "$@"; }
            docker() {
                [[ "$3" == "${backend}" && "$4" == show && "$5" == wg0 ]] || return 2
                case "$6" in
                    public-key) echo fixture-server ;;
                    latest-handshakes) printf 'fixture-client\t1\n' ;;
                    *) return 2 ;;
                esac
            }
            service_https() { test -f kernel-created && [[ "${scenario}" != response-failure ]]; }
            export -f ip wg-quick awg-quick selected_tool wg awg docker service_https
            rm -f kernel-created routes
            result=0
            fresh_tunnel >fresh-result || result=$?
            if [[ "${scenario}" == fresh ]]; then
                [[ "${result}" == 0 ]]
                for destination in 10.66.0.2/32 10.66.0.3/32 fd42:42:42::1/128 fd00:67:0:0::250/128; do
                    grep -Fq "${destination}" routes
                done
            else
                [[ "${result}" != 0 ]]
            fi
        )
    done
done

for scenario in services full unavailable-ipv6 leaked-ipv6; do
    (
        export WG_TRAFFIC_MODE=services DIRECT_INTERFACE=bridge
        [[ "${scenario}" != full ]] || WG_TRAFFIC_MODE=full
        export CONTROL4=http://10.66.0.250:18080/ CONTROL6='http://[fd00:67::250]:18080/'
        control_request() {
            printf '%s %s\n' "$1" "$2" >>controls
            if [[ "$1" == bridge ]]; then
                [[ "${scenario}" != unavailable-ipv6 || "$2" != "${CONTROL6}" ]]
                return
            fi
            [[ "${scenario}" == full || ( "${scenario}" == leaked-ipv6 && "$2" == "${CONTROL6}" ) ]]
        }
        export -f control_request
        : >controls
        result=0
        verify_controlled_policy || result=$?
        case "${scenario}" in
            services|full)
                [[ "${result}" == 0 ]]
                [[ "$(wc -l <controls)" == 4 ]]
                ;;
            *) [[ "${result}" != 0 ]] ;;
        esac
    )
done

for action in prepare check cleanup; do
    (
        CLIENT_STATE="${TMP_DIR}/${action}"
        mkdir -m 0700 "${CLIENT_STATE}"
        cd "${CLIENT_STATE}"
        printf '7\n' >client-id
        touch zt-session-cookie zt-session-login.json
        export CLIENT_ACTION="${action}" CLIENT_ID=7 API_CLIENT_ID="" CONTROL_CONTAINER="" TUNNEL_CREATED=false
        export WG_USER=fixture WG_PASSWORD=fixture UI_PORT=51821
        curl() { printf 'deleted\n' >>"${TMP_DIR}/deleted-${action}"; }
        export -f curl
        cleanup
    )
    if [[ "${action}" == cleanup ]]; then
        [[ -f "${TMP_DIR}/deleted-${action}" && ! -d "${TMP_DIR}/${action}" ]]
    else
        [[ ! -e "${TMP_DIR}/deleted-${action}" && -f "${TMP_DIR}/${action}/client-id" ]]
        [[ ! -e "${TMP_DIR}/${action}/zt-session-cookie" && ! -e "${TMP_DIR}/${action}/zt-session-login.json" ]]
    fi
done
mkdir -m 0700 "${TMP_DIR}/interrupted"
for interruption in 1 2; do
    set +e
    (
        set -e
        CLIENT_STATE="${TMP_DIR}/interrupted"
        cd "${CLIENT_STATE}"
        printf '7\n' >client-id
        touch zt-session-cookie zt-session-login.json
        CLIENT_ACTION=check CLIENT_ID=7 API_CLIENT_ID="" CONTROL_CONTAINER="" TUNNEL_CREATED=false
        trap cleanup EXIT
        trap 'exit 130' TERM
        kill -TERM "${BASHPID}"
    )
    interrupted_status=$?
    set -e
    [[ "${interrupted_status}" == 130 ]]
    [[ -f "${TMP_DIR}/interrupted/client-id" && ! -e "${TMP_DIR}/interrupted/zt-session-cookie" ]]
    printf 'retained-client: interruption=%s exit=130 private scratch removed\n' "${interruption}"
done
PACKET_CASES
printf 'qemu-packet-contract: owner behavior passed; no guest packets executed\n'
