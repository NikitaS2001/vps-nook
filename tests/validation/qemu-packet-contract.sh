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
    for scenario in fresh kernel-failure response-failure wrong-peer zero-transfer \
        route-conflict rule-conflict route-query-failure route-install-failure rule-install-failure; do
        (
            export VPN_TOOL="${backend}" VPN_LINK=wireguard
            [[ "${backend}" != awg ]] || VPN_LINK=amneziawg
            export CLIENT_IPV4=10.8.0.7 CLIENT_IPV6=fd42:42:42::7 WG_DOMAIN=wg.internal CADDY_IP=10.66.0.3
            export PROBE_ROUTE_TABLE=51822 PROBE_RULE_PRIORITY=11000
            PROBE_ROUTE_FAMILIES=()
            PROBE_ROUTE_RULES=()
            ROUTING_STATE="$(mktemp -d "${TMP_DIR}/routing.XXXXXX")"
            export ROUTING_STATE
            printf 'MTU = 1420\n' >original.conf
            cp original.conf zt-e2e.conf
            ip() {
                printf '%s\n' "$*" >>routes
                if [[ "$1 $2" == 'link add' ]]; then
                    [[ "$4" == type && "$5" == "${VPN_LINK}" ]] || return 2
                    [[ "${scenario}" != kernel-failure ]] || return 42
                    touch kernel-created
                fi
                if [[ "${2:-}" == -j ]]; then
                    [[ "${scenario}" != route-query-failure ]] || return 73
                    if [[ "${scenario}" == route-conflict && "$3" == route ]]; then
                        printf '[{"table":%s}]\n' "${PROBE_ROUTE_TABLE}"
                    elif [[ "${scenario}" == rule-conflict && "$3" == rule ]]; then
                        printf '[{"priority":%s}]\n' "${PROBE_RULE_PRIORITY}"
                    else
                        printf '[]\n'
                    fi
                elif [[ "${2:-} ${3:-}" == 'route add' ]]; then
                    [[ "${scenario}" != route-install-failure || "$1" != -6 ]] || return 74
                    touch "${ROUTING_STATE}/table-${1#-}"
                elif [[ "${2:-} ${3:-}" == 'rule add' ]]; then
                    [[ "${scenario}" != rule-install-failure || "$1" != -6 ]] || return 75
                    touch "${ROUTING_STATE}/rule-${1#-}-${5}"
                elif [[ "${2:-} ${3:-}" == 'rule del' ]]; then
                    rm "${ROUTING_STATE}/rule-${1#-}-${5}"
                elif [[ "${2:-} ${3:-}" == 'route flush' ]]; then
                    rm "${ROUTING_STATE}/table-${1#-}"
                fi
            }
            wg-quick() { [[ "${backend}" == wg && "$1" == strip && "$2" == /* && -f "$2" ]]; }
            awg-quick() { [[ "${backend}" == awg && "$1" == strip && "$2" == /* && -f "$2" ]]; }
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
            cleanup_probe_routing
            [[ -z "$(find "${ROUTING_STATE}" -type f -print -quit)" ]]
            if [[ "${scenario}" == fresh ]]; then
                [[ "${result}" == 0 ]]
            else
                [[ "${result}" != 0 ]]
            fi
        )
    done
done

# Execute the top-level public IPv6 owner, not a reconstructed policy function.
# Its EXIT trap must preserve main/foreign routes even when the full probe fails.
awk '
    /^if \[\[ "\$\{public_ipv6\}" == true \]\] && grep -q/ {body=1}
    body {print}
    body && /^fi$/ {exit}
' "${CLIENT}" >"${TMP_DIR}/public-ipv6-owner.sh"
[[ -s "${TMP_DIR}/public-ipv6-owner.sh" ]]
for scenario in services full failed-full; do
    for initial_route in present absent; do
        (
            CLIENT_STATE="$(mktemp -d "${TMP_DIR}/public-ipv6.XXXXXX")"
            cd "${CLIENT_STATE}"
            ROUTING_STATE="${CLIENT_STATE}/routing"
            mkdir -p "${ROUTING_STATE}/main" "${ROUTING_STATE}/probe" \
                "${ROUTING_STATE}/foreign"
            printf 'eth0\n' >"${ROUTING_STATE}/main/unrelated"
            if [[ "${initial_route}" == present ]]; then
                printf 'eth1\n' >"${ROUTING_STATE}/main/2606:4700:4700::1111"
            fi
            printf 'foreign-route\n' >"${ROUTING_STATE}/foreign/table-4"
            printf 'foreign-rule\n' >"${ROUTING_STATE}/foreign/rule-6"
            cp -a "${ROUTING_STATE}/main" "${CLIENT_STATE}/expected-main"
            cp -a "${ROUTING_STATE}/foreign" "${CLIENT_STATE}/expected-foreign"
            touch "${ROUTING_STATE}/zt-e2e"
            printf '[Peer]\nAllowedIPs = ::/0\n' >zt-e2e.conf
            ip() {
                local entry
                if [[ "$1 ${2:-} ${3:-}" == 'link delete zt-e2e' ]]; then
                    rm "${ROUTING_STATE}/zt-e2e"
                    # Kernel interface removal also removes its main-table routes.
                    for entry in "${ROUTING_STATE}/main/"*; do
                        [[ "$(<"${entry}")" != zt-e2e ]] || rm "${entry}"
                    done
                elif [[ "${2:-}" == -j ]]; then
                    # Existing foreign routing is not owned by this probe.
                    printf '[{"table":51823,"priority":12000}]\n'
                elif [[ "${2:-} ${3:-}" == 'route replace' ]]; then
                    [[ "$1" == -6 && "$4" == 2606:4700:4700::1111/128 \
                        && "$5" == dev && "$6" == zt-e2e ]] || return 2
                    printf 'zt-e2e\n' >"${ROUTING_STATE}/main/2606:4700:4700::1111"
                elif [[ "${2:-} ${3:-}" == 'route add' ]]; then
                    [[ "$4" == default && "$5" == dev && "$6" == zt-e2e \
                        && "$7" == table && "$8" == 51822 ]] || return 2
                    printf 'zt-e2e\n' >"${ROUTING_STATE}/probe/table-${1#-}"
                elif [[ "${2:-} ${3:-}" == 'rule add' ]]; then
                    [[ "$4" == priority && "$8" == lookup && "$9" == 51822 ]] || return 2
                    printf '%s\n' "$6:$7" >"${ROUTING_STATE}/probe/rule-${1#-}-$5"
                elif [[ "${2:-} ${3:-}" == 'rule del' ]]; then
                    [[ "$4" == priority && "$8" == lookup && "$9" == 51822 ]] || return 2
                    rm "${ROUTING_STATE}/probe/rule-${1#-}-$5"
                elif [[ "${2:-} ${3:-}" == 'route flush' ]]; then
                    [[ "$4" == table && "$5" == 51822 ]] || return 2
                    rm "${ROUTING_STATE}/probe/table-${1#-}"
                else
                    return 2
                fi
            }
            curl() {
                [[ "$1" == --interface && "$2" == zt-e2e ]] || return 2
                [[ -f "${ROUTING_STATE}/zt-e2e" \
                    && "$(<"${ROUTING_STATE}/probe/table-6")" == zt-e2e \
                    && "$(<"${ROUTING_STATE}/probe/rule-6-11001")" == oif:zt-e2e ]] || return 2
                touch "${CLIENT_STATE}/probe-requested"
                [[ "${scenario}" == full ]]
            }
            # No guest command may escape to the host if cleanup regresses.
            docker() { return 2; }
            export CLIENT_IPV4=10.8.0.7 CLIENT_IPV6=fd42:42:42::7
            PROBE_ROUTE_TABLE=51822 PROBE_RULE_PRIORITY=11000
            result=0
            # Do not use `(...) ||`: that disables errexit inside the owner.
            set +e
            (
                set -e
                PROBE_ROUTE_FAMILIES=() PROBE_ROUTE_RULES=()
                CLIENT_ACTION=check CLIENT_ID="" API_CLIENT_ID="" CONTROL_CONTAINER=""
                TUNNEL_CREATED=true public_ipv6=true
                WG_TRAFFIC_MODE=full
                [[ "${scenario}" != services ]] || WG_TRAFFIC_MODE=services
                trap cleanup EXIT
                configure_probe_routing
                source "${TMP_DIR}/public-ipv6-owner.sh"
            )
            result=$?
            set -e
            if [[ "${scenario}" == failed-full ]]; then
                [[ "${result}" != 0 ]]
            else
                [[ "${result}" == 0 ]]
            fi
            [[ -f "${CLIENT_STATE}/probe-requested" ]]
            [[ ! -e "${ROUTING_STATE}/zt-e2e" ]]
            [[ -z "$(find "${ROUTING_STATE}/probe" -type f -print -quit)" ]]
            if ! diff -ru "${CLIENT_STATE}/expected-main" "${ROUTING_STATE}/main"; then
                printf 'qemu-packet-contract: public IPv6 changed main routes: %s initial=%s\n' \
                    "${scenario}" "${initial_route}" >&2
                exit 1
            fi
            diff -ru "${CLIENT_STATE}/expected-foreign" "${ROUTING_STATE}/foreign"
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
