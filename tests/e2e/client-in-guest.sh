#!/usr/bin/env bash
# In-guest matching-kernel client. Private peer state survives lifecycle checks.
#
# Env:
#   WG_PASSWORD   wg-easy panel password (required)
#   WG_USER       panel username (default admin)
#   WG_ENDPOINT   endpoint to use in the client config (default: wg-easy container)
#   WG_PORT       container WireGuard UDP port (default 51820)
#   ROOT_CA       path to the fetched Caddy root CA (default installer path)
#   WG_TRAFFIC_MODE  services or full (default services)
set -euo pipefail
umask 077

: "${WG_PASSWORD:?WG_PASSWORD is required}"
WG_USER="${WG_USER:-admin}"
WG_ENDPOINT="${WG_ENDPOINT:-}"
WG_PORT="${WG_PORT:-51820}"
ROOT_CA="${ROOT_CA:-/opt/vps-nook-installer/repo/fetched_certs/localhost/root.crt}"
WG_TRAFFIC_MODE="${WG_TRAFFIC_MODE:-services}"
CLIENT_NAME="e2e-retained-client"
UI_PORT="${UI_PORT:-51821}"
WG_DOMAIN="${WG_INTERNAL_DOMAIN:-wg.internal}"
CADDY_IP="${CADDY_IP:-10.66.0.3}"
VAULTWARDEN_INTERNAL_DOMAIN="${VAULTWARDEN_INTERNAL_DOMAIN:-}"
API_CLIENT_ID=""
CLIENT_ID=""
CLIENT_ACTION="${CLIENT_ACTION:-once}"
case "${CLIENT_ACTION}" in once|prepare|check|cleanup) ;; *) exit 2 ;; esac
case "${NOOK_VPN_BACKEND:-wg}" in
    wg) VPN_TOOL=wg; VPN_LINK=wireguard ;;
    awg) VPN_TOOL=awg; VPN_LINK=amneziawg ;;
    *) echo "[FAIL] NOOK_VPN_BACKEND must be wg or awg" >&2; exit 2 ;;
esac

for tool in curl jq ip dig docker "${VPN_TOOL}" "${VPN_TOOL}-quick"; do
    command -v "${tool}" >/dev/null || { echo "[FAIL] prepared client tool missing: ${tool}" >&2; exit 1; }
done
[[ -e /dev/net/tun ]] || { echo "[FAIL] /dev/net/tun is missing" >&2; exit 1; }
[[ "${WG_TRAFFIC_MODE}" == services || "${WG_TRAFFIC_MODE}" == full ]] \
    || { echo "[FAIL] WG_TRAFFIC_MODE must be services or full" >&2; exit 1; }
CLIENT_STATE="${CLIENT_STATE:-$(mktemp -d /var/tmp/nook-client.XXXXXX)}"
[[ "${CLIENT_STATE}" == /* && ! -L "${CLIENT_STATE}" ]] || exit 2
if [[ "${CLIENT_ACTION}" == once || "${CLIENT_ACTION}" == prepare ]]; then
    [[ -d "${CLIENT_STATE}" ]] || mkdir -m 0700 "${CLIENT_STATE}"
    [[ -z "$(find "${CLIENT_STATE}" -mindepth 1 -print -quit)" ]] || exit 2
    printf 'nook-client-v1\n' >"${CLIENT_STATE}/owner"
else
    [[ -f "${CLIENT_STATE}/owner" && "$(<"${CLIENT_STATE}/owner")" == nook-client-v1 ]] || exit 2
fi
[[ "$(stat -c %a "${CLIENT_STATE}")" == 700 ]] || exit 2
cd "${CLIENT_STATE}"
TUNNEL_CREATED=false
CONTROL_CONTAINER=""
CONTROL_PID_OWNED=""

cleanup() {
    local status=$?
    trap - EXIT
    if [[ "${TUNNEL_CREATED}" == true ]]; then
        ip link delete zt-e2e || status=1
    fi
    if [[ -n "${CONTROL_CONTAINER}" ]]; then
        docker stop --time 5 "${CONTROL_CONTAINER}" >/dev/null || status=1
        [[ -z "${CONTROL_PID_OWNED:-}" ]] || wait "${CONTROL_PID_OWNED}" || status=1
        docker rm "${CONTROL_CONTAINER}" >/dev/null || status=1
    fi
    rm -f zt-session-login.json zt-session-cookie zt-caddy-body zt-caddy-headers \
        zt-api-create.json zt-api-list.json server.conf stripped.conf
    if [[ -n "${API_CLIENT_ID}" ]]; then
        curl -fsS -u "${WG_USER}:${WG_PASSWORD}" -X DELETE \
            "http://127.0.0.1:${UI_PORT}/api/client/${API_CLIENT_ID}" >/dev/null || status=1
    fi
    if [[ "${CLIENT_ACTION}" == once || "${CLIENT_ACTION}" == cleanup ]]; then
        [[ ! -f client-id ]] || CLIENT_ID="$(<client-id)"
        if [[ -n "${CLIENT_ID}" ]]; then
        curl -fsS -u "${WG_USER}:${WG_PASSWORD}" -X DELETE \
            "http://127.0.0.1:${UI_PORT}/api/client/${CLIENT_ID}" >/dev/null || status=1
        fi
        cd /
        rm -rf -- "${CLIENT_STATE}"
    fi
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
[[ "${CLIENT_ACTION}" != cleanup ]] || exit 0
if [[ -z "${WG_ENDPOINT}" ]]; then
    endpoint_host="$(
        docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' wg-easy
    )"
    [[ "${endpoint_host}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
        echo "[FAIL] could not determine the wg-easy container endpoint" >&2
        exit 1
    }
    WG_ENDPOINT="${endpoint_host}:${WG_PORT}"
fi

assert_no_policy_header() {
    local response_headers="$1"
    if grep -Eiq '^X-Zero-Trust-Policy:' "${response_headers}"; then
        echo "[FAIL] normal wg-easy route carried the CVE policy header" >&2
        exit 1
    fi
}

caddy_request() {
    local request_path="$1"
    shift
    curl -sS --interface zt-e2e --noproxy '*' --connect-timeout 8 --max-time 20 \
        --resolve "${WG_DOMAIN}:443:${CADDY_IP}" --cacert "${ROOT_CA}" \
        -D zt-caddy-headers -o zt-caddy-body -w '%{http_code}' \
        "$@" "https://${WG_DOMAIN}${request_path}"
}

verify_normal_caddy_api() {
    local status

    status="$(caddy_request '/')"
    [[ "${status}" == "200" || "${status}" == "302" ]] || {
        echo "[FAIL] wg-easy root returned ${status} through Caddy" >&2
        exit 1
    }
    assert_no_policy_header zt-caddy-headers

    jq -n --arg username "${WG_USER}" --arg password "${WG_PASSWORD}" \
        '{username: $username, password: $password, remember: false}' \
        >zt-session-login.json
    chmod 0600 zt-session-login.json
    # wg-easy 15.4 moved password login from POST /api/session to POST /api/auth/password
    status="$(caddy_request '/api/auth/password' -X POST -H 'Content-Type: application/json' \
        --data-binary @zt-session-login.json -c zt-session-cookie)"
    [[ "${status}" == "200" ]] || {
        echo "[FAIL] wg-easy login returned ${status} through Caddy" >&2
        exit 1
    }
    jq -e '.status == "success"' zt-caddy-body >/dev/null || {
        echo "[FAIL] wg-easy login response was unsuccessful through Caddy" >&2
        exit 1
    }
    assert_no_policy_header zt-caddy-headers
    chmod 0600 zt-session-cookie

    status="$(caddy_request '/api/client' -X POST -H 'Content-Type: application/json' \
        -b zt-session-cookie \
        --data "{\"name\":\"${CLIENT_NAME}-api\",\"expiresAt\":null}")"
    [[ "${status}" == "200" ]] || {
        echo "[FAIL] authenticated client create returned ${status} through Caddy" >&2
        exit 1
    }
    assert_no_policy_header zt-caddy-headers
    cp zt-caddy-body zt-api-create.json
    API_CLIENT_ID="$(jq -r '.clientId' zt-api-create.json)"
    [[ -n "${API_CLIENT_ID}" && "${API_CLIENT_ID}" != "null" ]] || {
        echo "[FAIL] authenticated client create returned no client id" >&2
        exit 1
    }

    status="$(caddy_request '/api/client' -b zt-session-cookie)"
    [[ "${status}" == "200" ]] || {
        echo "[FAIL] authenticated client list returned ${status} through Caddy" >&2
        exit 1
    }
    assert_no_policy_header zt-caddy-headers
    cp zt-caddy-body zt-api-list.json
    jq -e --arg id "${API_CLIENT_ID}" \
        '[.. | objects | .id? | tostring] | index($id) != null' \
        zt-api-list.json >/dev/null || {
        echo "[FAIL] authenticated client list omitted the created client" >&2
        exit 1
    }

    status="$(caddy_request "/api/client/${API_CLIENT_ID}" -X DELETE \
        -b zt-session-cookie)"
    [[ "${status}" == "200" ]] || {
        echo "[FAIL] authenticated client delete returned ${status} through Caddy" >&2
        exit 1
    }
    assert_no_policy_header zt-caddy-headers

    status="$(caddy_request '/api/client' -b zt-session-cookie)"
    [[ "${status}" == "200" ]] || {
        echo "[FAIL] authenticated cleanup list returned ${status} through Caddy" >&2
        exit 1
    }
    jq -e --arg id "${API_CLIENT_ID}" \
        '[.. | objects | .id? | tostring] | index($id) == null' \
        zt-caddy-body >/dev/null || {
        echo "[FAIL] authenticated client cleanup was incomplete" >&2
        exit 1
    }
    API_CLIENT_ID=""
    echo "[PASS] root, login, and authenticated client create/list/delete traversed Caddy"
}

verify_cve_route_policy() {
    local policy_path policy_value status

    for policy_path in /cnf /cnf/ /cnf/untrusted-token; do
        status="$(caddy_request "${policy_path}")"
        [[ "${status}" == "404" ]] || {
            echo "[FAIL] ${policy_path} returned ${status}, expected CVE policy 404" >&2
            exit 1
        }
        policy_value="$(awk -F ': *' \
            'tolower($1) == "x-zero-trust-policy" {gsub(/\r$/, "", $2); print $2}' \
            zt-caddy-headers)"
        [[ "${policy_value}" == "cve-2026-63089" ]] || {
            echo "[FAIL] ${policy_path} lacked the exact CVE policy header" >&2
            exit 1
        }
        echo "[PASS] ${policy_path} blocked by the CVE route policy"
    done

    status="$(caddy_request '/cnfx')"
    [[ "${status}" == "302" ]] || {
        echo "[FAIL] near-miss /cnfx returned ${status}, expected upstream 302" >&2
        exit 1
    }
    assert_no_policy_header zt-caddy-headers
    echo "[PASS] near-miss /cnfx retained normal upstream behavior"
}

api() {
    curl --noproxy '*' --connect-timeout 8 --max-time 20 -fsS \
        -u "${WG_USER}:${WG_PASSWORD}" "$@"
}

peer_fingerprint() {
    local server_key client_key
    api "http://127.0.0.1:${UI_PORT}/api/client/${CLIENT_ID}/configuration" >current.conf
    cmp -s original.conf current.conf || { echo '[FAIL] retained profile changed' >&2; return 1; }
    server_key="$(docker exec wg-easy "${VPN_TOOL}" show wg0 public-key)" || return
    client_key="$(awk -F ' = ' '$1 == "PrivateKey" {print $2}' original.conf | "${VPN_TOOL}" pubkey)" || return
    [[ "$(awk -F ' = ' '$1 == "PublicKey" {print $2}' original.conf)" == "${server_key}" ]] || return 1
    docker exec wg-easy "${VPN_TOOL}" show wg0 peers >server-peers || return
    grep -Fxq "${client_key}" server-peers || return 1
    api "http://127.0.0.1:${UI_PORT}/api/client" >clients.json || return
    jq -e --arg id "${CLIENT_ID}" --arg key "${client_key}" \
        'any(.[]; (.id|tostring) == $id and .publicKey == $key)' clients.json >/dev/null || return
    docker exec wg-easy "${VPN_TOOL}" showconf wg0 >server.conf || return
    awk '/^(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]) = /' server.conf | sort >server-parameters
    # wg-easy omits zero-valued S fields; the kernel may serialize them.
    awk '/^(S[1-4]|H[1-4]) = / && $3 != "0"' server.conf | sort >server-sh
    awk '/^(S[1-4]|H[1-4]) = / && $3 != "0"' original.conf | sort >client-parameters
    cmp -s server-sh client-parameters || return 1
    case "${VPN_TOOL}" in
        awg) [[ "$(grep -c '^H[1-4] = ' client-parameters)" == 4 ]] || return 1 ;;
        wg) [[ ! -s client-parameters ]] || return 1 ;;
    esac
    {
        printf '%s\n' "${VPN_TOOL}" "${CLIENT_ID}" "${server_key}" "${client_key}"
        sha256sum original.conf server-parameters
    } | sha256sum
}

service_dns() {
    local domain="$1"
    dig +short +time=5 +tries=1 -b "${CLIENT_IPV4}" @10.66.0.2 "${domain}" A
}

service_https() {
    local domain="$1"
    curl --interface zt-e2e --noproxy '*' --connect-timeout 8 --max-time 20 \
        -fsS --resolve "${domain}:443:${CADDY_IP}" --cacert "${ROOT_CA}" \
        "https://${domain}/" -o /dev/null
}

control_request() {
    local interface="$1" endpoint="$2"
    curl --interface "${interface}" --noproxy '*' --connect-timeout 3 --max-time 5 \
        -fsS "${endpoint}" -o /dev/null
}

verify_controlled_policy() {
    local endpoint
    for endpoint in "${CONTROL4}" "${CONTROL6}"; do
        control_request "${DIRECT_INTERFACE}" "${endpoint}" || return
        if control_request zt-e2e "${endpoint}"; then
            [[ "${WG_TRAFFIC_MODE}" == full ]] || return 1
        else
            [[ "${WG_TRAFFIC_MODE}" == services ]] || return 1
        fi
    done
}

fresh_tunnel() {
    # A new kernel interface cannot reuse session keys. Quick only strips the
    # profile: ip-link failure cannot invoke a userspace implementation.
    ip link add zt-e2e type "${VPN_LINK}" || return
    TUNNEL_CREATED=true
    "${VPN_TOOL}-quick" strip zt-e2e.conf >stripped.conf || return
    "${VPN_TOOL}" setconf zt-e2e stripped.conf || return
    ip address add "${CLIENT_IPV4}/32" dev zt-e2e || return
    ip -6 address add "${CLIENT_IPV6}/128" dev zt-e2e nodad || return
    local mtu
    mtu="$(awk -F ' = ' '$1 == "MTU" {print $2}' original.conf)"
    [[ "${mtu}" =~ ^[0-9]+$ ]] && ((mtu >= 1280 && mtu <= 65535)) || return 1
    ip link set zt-e2e mtu "${mtu}" up || return
    for address in 10.66.0.2 "${CADDY_IP}" 10.66.0.250 1.1.1.1; do
        ip route replace "${address}/32" dev zt-e2e || return
    done
    ip -6 route replace fd42:42:42::1/128 dev zt-e2e || return
    ip -6 route replace fd00:67:0:0::250/128 dev zt-e2e || return
    # The bound socket subscribes before sending and awaits its exact trusted
    # response. Success proves a post-creation handshake without timestamp polling.
    service_https "${WG_DOMAIN}" || return
    local server_key client_key epoch
    server_key="$(docker exec wg-easy "${VPN_TOOL}" show wg0 public-key)" || return
    client_key="$("${VPN_TOOL}" show zt-e2e public-key)" || return
    [[ "$("${VPN_TOOL}" show zt-e2e peers)" == "${server_key}" ]] || return 1
    epoch="$("${VPN_TOOL}" show zt-e2e latest-handshakes | awk -v key="${server_key}" '$1 == key {print $2}')"
    [[ "${epoch}" =~ ^[1-9][0-9]*$ ]] || return 1
    epoch="$(docker exec wg-easy "${VPN_TOOL}" show wg0 latest-handshakes | awk -v key="${client_key}" '$1 == key {print $2}')"
    [[ "${epoch}" =~ ^[1-9][0-9]*$ ]] || return 1
    "${VPN_TOOL}" show zt-e2e transfer | awk -v key="${server_key}" \
        '$1 == key && $2 > 0 && $3 > 0 {found=1} END {exit !found}' || return
    echo '[PASS] fresh matching kernel handshake carried a bound trusted response'
}

if [[ "${CLIENT_ACTION}" == prepare || "${CLIENT_ACTION}" == once ]]; then
    # Pinned API creation awaits saveConfig/sync before its successful response.
    api -X POST "http://127.0.0.1:${UI_PORT}/api/client" -H 'Content-Type: application/json' \
        -d "{\"name\":\"${CLIENT_NAME}\",\"expiresAt\":null}" >created.json
    CLIENT_ID="$(jq -er '.clientId | tostring | select(test("^[0-9]+$"))' created.json)"
    printf '%s\n' "${CLIENT_ID}" >client-id
    api "http://127.0.0.1:${UI_PORT}/api/client/${CLIENT_ID}/configuration" >original.conf
    peer_fingerprint >identity
else
    CLIENT_ID="$(<client-id)"
    [[ "${CLIENT_ID}" =~ ^[0-9]+$ ]] || exit 2
    peer_fingerprint >identity-current
    cmp -s identity identity-current || { echo '[FAIL] retained peer identity changed' >&2; exit 1; }
fi

CLIENT_IPV4="$(awk -F ' = ' '$1 == "Address" {split($2,a,","); split(a[1],b,"/"); print b[1]}' original.conf)"
CLIENT_IPV6="$(awk -F ' = ' '$1 == "Address" {split($2,a,","); gsub(/ /,"",a[2]); split(a[2],b,"/"); print b[1]}' original.conf)"
[[ -n "${CLIENT_IPV4}" && -n "${CLIENT_IPV6}" ]] || exit 1
public_ipv6=false
if curl -6 --noproxy '*' --connect-timeout 5 --max-time 8 -fsSk \
    'https://[2606:4700:4700::1111]/cdn-cgi/trace' -o /dev/null; then
    public_ipv6=true
else
    echo '[INFO] optional public IPv6 control unavailable; no public IPv6 proof'
fi
curl -4 --noproxy '*' --connect-timeout 5 --max-time 8 -fsSk \
    'https://1.1.1.1/cdn-cgi/trace' -o /dev/null
if [[ "${WG_TRAFFIC_MODE}" == full ]] && grep -q '::/0' original.conf; then
    [[ "${public_ipv6}" == true ]] || { echo '[FAIL] full ::/0 lacks a successful public probe' >&2; exit 1; }
fi
# Preserve the downloaded profile. Only the local probe profile overrides routes.
awk -v endpoint="${WG_ENDPOINT}" -v mode="${WG_TRAFFIC_MODE}" '
    /^Endpoint = / {$0="Endpoint = " endpoint}
    /^AllowedIPs = / {
        if (mode == "services") $0="AllowedIPs = 0.0.0.0/0, ::/0"
        else $0=$0 ", fd42:42:42::1/128, fd00:67:0:0::250/128"
    }
    /^PersistentKeepalive = / {$0="PersistentKeepalive = 0"}
    {print}
' original.conf >zt-e2e.conf

# Reuse the deployed immutable image. No pull, published ports or capabilities.
network="$(docker inspect wg-easy --format '{{range $name, $net := .NetworkSettings.Networks}}{{$name}}{{end}}')"
image="$(docker inspect wg-easy --format '{{.Image}}')"
CONTROL_CONTAINER="$(docker create --pull=never --network "${network}" --ip 10.66.0.250 \
    --ip6 fd00:67:0:0::250 --cap-drop ALL --security-opt no-new-privileges \
    --entrypoint node "${image}" -e \
    'process.on("SIGTERM",()=>process.exit(0));require("http").createServer((q,s)=>s.end("control")).listen(18080,"::",()=>console.log("LISTENING"))')"
coproc CONTROL { docker start -a "${CONTROL_CONTAINER}"; }
CONTROL_PID_OWNED="${CONTROL_PID}"
IFS= read -r -t 20 -u "${CONTROL[0]}" control_event
[[ "${control_event}" == LISTENING ]] || exit 1
CONTROL_PID="${CONTROL_PID_OWNED}"
CONTROL4='http://10.66.0.250:18080/'
CONTROL6='http://[fd00:67:0:0::250]:18080/'
DIRECT_INTERFACE="$(ip -j route get 10.66.0.250 | jq -er '.[0].dev')"
control_request "${DIRECT_INTERFACE}" "${CONTROL4}"
control_request "${DIRECT_INTERFACE}" "${CONTROL6}"
curl --noproxy '*' --connect-timeout 8 --max-time 20 -fsS \
    --resolve "${WG_DOMAIN}:443:${CADDY_IP}" --cacert "${ROOT_CA}" "https://${WG_DOMAIN}/" -o /dev/null

fresh_tunnel
for domain in "${WG_DOMAIN}" "${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}"; do
    [[ "$(service_dns "${domain}")" == "${CADDY_IP}" ]] || exit 1
    service_https "${domain}"
done
ping -6 -I zt-e2e -c 1 -W 5 fd42:42:42::1 >/dev/null
verify_controlled_policy
if control_request zt-e2e 'https://1.1.1.1/cdn-cgi/trace'; then
    [[ "${WG_TRAFFIC_MODE}" == full ]] || exit 1
else
    [[ "${WG_TRAFFIC_MODE}" == services ]] || exit 1
fi
if [[ "${public_ipv6}" == true ]] && grep -q '::/0' zt-e2e.conf; then
    ip -6 route replace 2606:4700:4700::1111/128 dev zt-e2e
    if control_request zt-e2e 'https://[2606:4700:4700::1111]/cdn-cgi/trace'; then
        [[ "${WG_TRAFFIC_MODE}" == full ]] || exit 1
    else
        [[ "${WG_TRAFFIC_MODE}" == services ]] || exit 1
    fi
fi
verify_normal_caddy_api
verify_cve_route_policy
if [[ -n "${VAULTWARDEN_INTERNAL_DOMAIN}" ]]; then
    [[ "$(service_dns "${VAULTWARDEN_INTERNAL_DOMAIN}")" == "${CADDY_IP}" ]] || exit 1
    service_https "${VAULTWARDEN_INTERNAL_DOMAIN}"
fi

ip link delete zt-e2e
TUNNEL_CREATED=false
for domain in "${WG_DOMAIN}" "${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}"; do
    if service_https "${domain}"; then exit 1; fi
    if service_dns "${domain}" >/dev/null 2>&1; then exit 1; fi
done
control_request "${DIRECT_INTERFACE}" "${CONTROL4}"
control_request "${DIRECT_INTERFACE}" "${CONTROL6}"
echo '[PASS] retained peer, bound services and controlled dual-stack policy verified'
