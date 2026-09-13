#!/usr/bin/env bash
# In-guest WireGuard client E2E. Runs inside the deployed VM/VPS: creates a
# client through the wg-easy API on 127.0.0.1, brings up wg-quick locally,
# and verifies DNS + internal HTTPS endpoints through the VPN.
#
# Env:
#   WG_PASSWORD   wg-easy panel password (required)
#   WG_USER       panel username (default admin)
#   WG_ENDPOINT   endpoint to use in the client config (default: wg-easy container)
#   WG_PORT       container WireGuard UDP port (default 51820)
#   ROOT_CA       path to the fetched Caddy root CA (default installer path)
#   WG_TRAFFIC_MODE  services or full (default services)
set -euo pipefail

: "${WG_PASSWORD:?WG_PASSWORD is required}"
WG_USER="${WG_USER:-admin}"
WG_ENDPOINT="${WG_ENDPOINT:-}"
WG_PORT="${WG_PORT:-51820}"
ROOT_CA="${ROOT_CA:-/opt/vps-nook-installer/repo/fetched_certs/localhost/root.crt}"
WG_TRAFFIC_MODE="${WG_TRAFFIC_MODE:-services}"
CLIENT_NAME="e2e-client-$(date +%s)"
UI_PORT="${UI_PORT:-51821}"
WG_DOMAIN="${WG_INTERNAL_DOMAIN:-wg.internal}"
CADDY_IP="${CADDY_IP:-10.66.0.3}"
API_CLIENT_ID=""

command -v curl >/dev/null || { echo "[FAIL] curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "[FAIL] jq is required" >&2; exit 1; }
command -v wg-quick >/dev/null || { echo "[FAIL] wireguard-tools are required" >&2; exit 1; }
[[ -e /dev/net/tun ]] || { echo "[FAIL] /dev/net/tun is missing" >&2; exit 1; }
[[ "${WG_TRAFFIC_MODE}" == services || "${WG_TRAFFIC_MODE}" == full ]] \
    || { echo "[FAIL] WG_TRAFFIC_MODE must be services or full" >&2; exit 1; }
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

cleanup() {
    sudo wg-quick down /tmp/zt-e2e.conf >/dev/null 2>&1 || true
    if [[ -n "${API_CLIENT_ID}" ]]; then
        curl -fsS -u "${WG_USER}:${WG_PASSWORD}" -X DELETE \
            "http://127.0.0.1:${UI_PORT}/api/client/${API_CLIENT_ID}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${CLIENT_ID:-}" ]]; then
        # remove the test client from the wg-easy API so no peer is left behind
        curl -fsS -u "${WG_USER}:${WG_PASSWORD}" -X DELETE \
            "http://127.0.0.1:${UI_PORT}/api/client/${CLIENT_ID}" >/dev/null 2>&1 || true
    fi
    rm -f /tmp/zt-e2e.conf /tmp/zt-create.json /tmp/zt-api-create.json \
        /tmp/zt-api-list.json /tmp/zt-caddy-body /tmp/zt-caddy-headers \
        /tmp/zt-session-cookie /tmp/zt-session-login.json
}
trap cleanup EXIT

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
    curl -sS --resolve "${WG_DOMAIN}:443:${CADDY_IP}" --cacert "${ROOT_CA}" \
        -D /tmp/zt-caddy-headers -o /tmp/zt-caddy-body -w '%{http_code}' \
        "$@" "https://${WG_DOMAIN}${request_path}"
}

verify_normal_caddy_api() {
    local status

    status="$(caddy_request '/')"
    [[ "${status}" == "200" || "${status}" == "302" ]] || {
        echo "[FAIL] wg-easy root returned ${status} through Caddy" >&2
        exit 1
    }
    assert_no_policy_header /tmp/zt-caddy-headers

    jq -n --arg username "${WG_USER}" --arg password "${WG_PASSWORD}" \
        '{username: $username, password: $password, remember: false}' \
        >/tmp/zt-session-login.json
    chmod 0600 /tmp/zt-session-login.json
    # wg-easy 15.4 moved password login from POST /api/session to POST /api/auth/password
    status="$(caddy_request '/api/auth/password' -X POST -H 'Content-Type: application/json' \
        --data-binary @/tmp/zt-session-login.json -c /tmp/zt-session-cookie)"
    [[ "${status}" == "200" ]] || {
        echo "[FAIL] wg-easy login returned ${status} through Caddy" >&2
        exit 1
    }
    jq -e '.status == "success"' /tmp/zt-caddy-body >/dev/null || {
        echo "[FAIL] wg-easy login response was unsuccessful through Caddy" >&2
        exit 1
    }
    assert_no_policy_header /tmp/zt-caddy-headers
    chmod 0600 /tmp/zt-session-cookie

    status="$(caddy_request '/api/client' -X POST -H 'Content-Type: application/json' \
        -b /tmp/zt-session-cookie \
        --data "{\"name\":\"${CLIENT_NAME}-api\",\"expiresAt\":null}")"
    [[ "${status}" == "200" ]] || {
        echo "[FAIL] authenticated client create returned ${status} through Caddy" >&2
        exit 1
    }
    assert_no_policy_header /tmp/zt-caddy-headers
    cp /tmp/zt-caddy-body /tmp/zt-api-create.json
    API_CLIENT_ID="$(jq -r '.clientId' /tmp/zt-api-create.json)"
    [[ -n "${API_CLIENT_ID}" && "${API_CLIENT_ID}" != "null" ]] || {
        echo "[FAIL] authenticated client create returned no client id" >&2
        exit 1
    }

    status="$(caddy_request '/api/client' -b /tmp/zt-session-cookie)"
    [[ "${status}" == "200" ]] || {
        echo "[FAIL] authenticated client list returned ${status} through Caddy" >&2
        exit 1
    }
    assert_no_policy_header /tmp/zt-caddy-headers
    cp /tmp/zt-caddy-body /tmp/zt-api-list.json
    jq -e --arg id "${API_CLIENT_ID}" \
        '[.. | objects | .id? | tostring] | index($id) != null' \
        /tmp/zt-api-list.json >/dev/null || {
        echo "[FAIL] authenticated client list omitted the created client" >&2
        exit 1
    }

    status="$(caddy_request "/api/client/${API_CLIENT_ID}" -X DELETE \
        -b /tmp/zt-session-cookie)"
    [[ "${status}" == "200" ]] || {
        echo "[FAIL] authenticated client delete returned ${status} through Caddy" >&2
        exit 1
    }
    assert_no_policy_header /tmp/zt-caddy-headers

    status="$(caddy_request '/api/client' -b /tmp/zt-session-cookie)"
    [[ "${status}" == "200" ]] || {
        echo "[FAIL] authenticated cleanup list returned ${status} through Caddy" >&2
        exit 1
    }
    jq -e --arg id "${API_CLIENT_ID}" \
        '[.. | objects | .id? | tostring] | index($id) == null' \
        /tmp/zt-caddy-body >/dev/null || {
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
            /tmp/zt-caddy-headers)"
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
    assert_no_policy_header /tmp/zt-caddy-headers
    echo "[PASS] near-miss /cnfx retained normal upstream behavior"
}

# 1. create a client through the wg-easy API (HTTP Basic auth)
create_ok=false
for _ in $(seq 1 12); do
    if curl -fsS -u "${WG_USER}:${WG_PASSWORD}" -X POST \
        "http://127.0.0.1:${UI_PORT}/api/client" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"${CLIENT_NAME}\",\"expiresAt\":null}" >/tmp/zt-create.json 2>/dev/null; then
        create_ok=true
        break
    fi
    sleep 5
done
[[ "${create_ok}" == "true" ]] || { echo "[FAIL] could not create a wg-easy client (check WG_PASSWORD)" >&2; exit 1; }
CLIENT_ID="$(jq -r '.clientId' /tmp/zt-create.json 2>/dev/null || true)"
[[ -n "${CLIENT_ID}" && "${CLIENT_ID}" != "null" ]] || { echo "[FAIL] wg-easy did not return a client id" >&2; exit 1; }

# 2. fetch the client configuration and point it at the local endpoint
curl -fsS -u "${WG_USER}:${WG_PASSWORD}" \
    "http://127.0.0.1:${UI_PORT}/api/client/${CLIENT_ID}/configuration" >/tmp/zt-e2e.conf
grep -q '^\[Interface\]' /tmp/zt-e2e.conf || { echo "[FAIL] downloaded configuration is not a WireGuard config" >&2; exit 1; }
chmod 0600 /tmp/zt-e2e.conf
sed -i -E "s|^Endpoint = .*|Endpoint = ${WG_ENDPOINT}|" /tmp/zt-e2e.conf
full_ipv6_enabled=false
if [[ "${WG_TRAFFIC_MODE}" == services ]]; then
    # Model a malicious client that ignores the narrow generated policy. The
    # server firewall, not the client route, must enforce services.
    sed -i -E 's|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0, ::/0|' /tmp/zt-e2e.conf
    full_ipv6_enabled=true
    echo "[INFO] services adversarial client requests catch-all AllowedIPs"
elif grep -Eq '^AllowedIPs = 0\.0\.0\.0/0, ?::/0$' /tmp/zt-e2e.conf; then
    full_ipv6_enabled=true
elif ! grep -Eq '^AllowedIPs = 0\.0\.0\.0/0$' /tmp/zt-e2e.conf; then
    echo "[FAIL] full client profile has unexpected AllowedIPs" >&2
    exit 1
fi

# The API commits before the runtime WireGuard peer is guaranteed to be
# visible. Wait for that boundary so a slow guest cannot race wg-quick.
client_public_key="$(
    sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' \
        /tmp/zt-e2e.conf | tr -d '\r' | wg pubkey
)"
peer_ready=false
for _ in $(seq 1 30); do
    if sudo docker exec wg-easy wg show wg0 peers | grep -Fqx "${client_public_key}"; then
        peer_ready=true
        break
    fi
    sleep 1
done
unset client_public_key
[[ "${peer_ready}" == true ]] || {
    echo "[FAIL] created WireGuard client did not reach the server runtime" >&2
    exit 1
}

curl -4 --noproxy '*' --connect-timeout 8 --max-time 15 \
    -fsSk 'https://1.1.1.1/cdn-cgi/trace' -o /dev/null || {
    echo "[FAIL] IPv4 direct-egress control failed before WireGuard" >&2
    exit 1
}
echo "[PASS] IPv4 direct-egress control works before WireGuard"

ipv6_direct_egress=false
if curl -6 --noproxy '*' --connect-timeout 8 --max-time 15 \
    -fsSk 'https://[2606:4700:4700::1111]/cdn-cgi/trace' -o /dev/null; then
    ipv6_direct_egress=true
    echo "[PASS] IPv6 direct-egress control works before WireGuard"
else
    echo "[SKIP] IPv6 public-egress packet probe: test host has no direct IPv6"
fi

# 3. bring the tunnel up
sudo wg-quick up /tmp/zt-e2e.conf

# Force packets through the client interface and require a real handshake
# before testing services that are also locally routable from this guest.
handshake_ready=false
for _ in $(seq 1 15); do
    ping -I zt-e2e -c 1 -W 1 10.66.0.2 >/dev/null 2>&1 || true
    latest_handshake="$(wg show zt-e2e latest-handshakes | awk '{print $NF}' | sort -rn | head -1)"
    handshake_now="$(date +%s)"
    if [[ "${latest_handshake}" =~ ^[1-9][0-9]*$ ]] \
        && ((latest_handshake <= handshake_now && handshake_now - latest_handshake < 180)); then
        handshake_ready=true
        break
    fi
    sleep 2
done
[[ "${handshake_ready}" == true ]] || {
    echo "[FAIL] WireGuard client could not establish a handshake" >&2
    exit 1
}

# 4. verify: AdGuard DNS, then internal HTTPS with the trusted root CA
if ! ping -c 2 -W 3 10.66.0.2 >/dev/null 2>&1; then
    echo "[FAIL] AdGuard (10.66.0.2) is not reachable over the VPN" >&2
    exit 1
fi
echo "[PASS] AdGuard reachable over the VPN"

if ! curl -fsS --resolve "${WG_INTERNAL_DOMAIN:-wg.internal}:443:10.66.0.3" \
    --cacert "${ROOT_CA}" "https://${WG_INTERNAL_DOMAIN:-wg.internal}/" -o /dev/null; then
    echo "[FAIL] https://${WG_INTERNAL_DOMAIN:-wg.internal} is not reachable over the VPN" >&2
    exit 1
fi
echo "[PASS] https://${WG_INTERNAL_DOMAIN:-wg.internal} reachable (trusted root CA)"

verify_normal_caddy_api
verify_cve_route_policy

if ! curl -fsS --resolve "${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}:443:10.66.0.3" \
    --cacert "${ROOT_CA}" "https://${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}/" -o /dev/null; then
    echo "[FAIL] https://${ADGUARD_INTERNAL_DOMAIN:-adguard.internal} is not reachable over the VPN" >&2
    exit 1
fi
echo "[PASS] https://${ADGUARD_INTERNAL_DOMAIN:-adguard.internal} reachable (trusted root CA)"

probe_public_egress() {
    local family="$1" endpoint="$2"
    curl "-${family}" --noproxy '*' --interface zt-e2e --connect-timeout 8 --max-time 15 \
        -fsSk "${endpoint}" -o /dev/null
}

if probe_public_egress 4 'https://1.1.1.1/cdn-cgi/trace'; then
    [[ "${WG_TRAFFIC_MODE}" == full ]] || {
        echo "[FAIL] IPv4 public egress escaped services through WireGuard" >&2
        exit 1
    }
    echo "[PASS] IPv4 public egress works through full"
else
    [[ "${WG_TRAFFIC_MODE}" == services ]] || {
        echo "[FAIL] IPv4 public egress failed through full" >&2
        exit 1
    }
    echo "[PASS] IPv4 public egress is blocked through services"
fi

if [[ "${ipv6_direct_egress}" == true && "${full_ipv6_enabled}" == true ]]; then
    if probe_public_egress 6 'https://[2606:4700:4700::1111]/cdn-cgi/trace'; then
        [[ "${WG_TRAFFIC_MODE}" == full ]] || {
            echo "[FAIL] IPv6 public egress escaped services through WireGuard" >&2
            exit 1
        }
        echo "[PASS] IPv6 public egress works through full"
    else
        [[ "${WG_TRAFFIC_MODE}" == services ]] || {
            echo "[FAIL] IPv6 public egress failed through full" >&2
            exit 1
        }
        echo "[PASS] IPv6 public egress is blocked through services"
    fi
elif [[ "${ipv6_direct_egress}" == true ]]; then
    echo "[SKIP] IPv6 is outside this IPv4-only full profile"
fi

echo "--- diagnostics: private CA, local domains, WireGuard handshake ---"
echo "DNS resolution via AdGuard (10.66.0.2):"
for d in "${WG_INTERNAL_DOMAIN:-wg.internal}" "${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}"; do
    echo "  ${d} -> $(dig +short @10.66.0.2 "${d}" | tr '\n' ' ')"
done
echo "Private root CA fetched from the server:"
openssl x509 -in "${ROOT_CA}" -noout -subject -issuer -dates 2>/dev/null \
    || echo "  cannot read the root CA"
echo "Certificate served by Caddy for ${WG_INTERNAL_DOMAIN:-wg.internal}:"
echo | openssl s_client -connect 10.66.0.3:443 -servername "${WG_INTERNAL_DOMAIN:-wg.internal}" \
    -CAfile "${ROOT_CA}" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null \
    || echo "  cannot inspect the served certificate"
echo "WireGuard client interface (handshake / transfer):"
wg show | grep -E 'interface:|handshake:|transfer:' || true

latest_handshake="$(wg show all latest-handshakes | awk '{print $NF}' | sort -rn | head -1)"
handshake_now="$(date +%s)"
if [[ ! "${latest_handshake}" =~ ^[0-9]+$ ]] || \
    ((latest_handshake <= 0 || latest_handshake > handshake_now || handshake_now - latest_handshake > 180)); then
    echo "[FAIL] WireGuard client has no handshake in the last 180 seconds" >&2
    exit 1
fi
echo "[PASS] WireGuard client has a recent handshake"

echo "[PASS] in-guest WireGuard client E2E succeeded"
