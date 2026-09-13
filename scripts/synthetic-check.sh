#!/usr/bin/env bash
# Synthetic health check for the VPS Nook stack. Run on the VPS as root
# (e.g. via cron/systemd.timer). Catches "running but broken" states that
# restart policies miss: container health, internal HTTPS via Caddy, and
# WireGuard handshake freshness.
#
# A full *external* VPN->DNS->HTTPS check requires a real client; see
# tests/e2e/external-client-qemu.sh (manual) for that path.
set -euo pipefail

for legacy_name in "${!ZERO_TRUST_@}"; do
    [[ -n ${legacy_name} ]] || continue
    printf '[FAIL] %s is no longer accepted; use NOOK_%s (value not shown).\n' \
        "${legacy_name}" "${legacy_name#ZERO_TRUST_}" >&2
    exit 1
done

usage() {
    cat <<'EOF'
Usage: synthetic-check.sh

Run the live VPS Nook stack health check on the VPS.
EOF
}

case "${1:-}" in
    -h|--help)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        usage
        exit 0
        ;;
    '') ;;
    *) usage >&2; exit 2 ;;
esac

WG_INTERNAL_DOMAIN="${WG_INTERNAL_DOMAIN:-wg.internal}"
ADGUARD_INTERNAL_DOMAIN="${ADGUARD_INTERNAL_DOMAIN:-adguard.internal}"
CADDY_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' caddy 2>/dev/null || true)"

fail() { echo "[FAIL] $*" >&2; exit 1; }

echo "== containers =="
for c in wg-easy adguard caddy; do
    status="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
    [[ "${status}" == "running" ]] || fail "container ${c} status is ${status}"

    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo missing)"
    if [[ "${c}" == "wg-easy" && "${health}" == "none" ]]; then
        echo "[OK] ${c} running (no healthcheck configured)"
    elif [[ "${health}" == "healthy" ]]; then
        echo "[OK] ${c} running and healthy"
    else
        fail "container ${c} health is ${health}"
    fi
done

echo "== wg-easy readiness =="
wg_session_status="$(curl -sS -o /dev/null -w '%{http_code}' \
    http://127.0.0.1:51821/api/session 2>/dev/null || true)"
[[ "${wg_session_status}" == "401" ]] || \
    fail "wg-easy /api/session returned '${wg_session_status}', expected 401"
docker exec wg-easy wg show >/dev/null 2>&1 || fail "wg-easy wg show failed"
echo "[OK] wg-easy authentication and WireGuard interface ready"

echo "== HTTPS via Caddy (internal CA) =="
[[ -n "${CADDY_IP}" ]] || fail "could not determine the Caddy container IP"
for d in "${WG_INTERNAL_DOMAIN}" "${ADGUARD_INTERNAL_DOMAIN}"; do
    code="$(curl -kso /dev/null -w '%{http_code}' --resolve "${d}:443:${CADDY_IP}" "https://${d}/" 2>/dev/null || true)"
    case "${code}" in
        200|302|401) echo "[OK] HTTPS ${d} -> ${code}" ;;
        *) fail "HTTPS ${d} returned '${code}'" ;;
    esac
done

echo "== WireGuard handshake freshness =="
latest="$(docker exec wg-easy wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | sort -rn | head -1 || true)"
now="$(date +%s)"
if [[ -n "${latest}" ]] && [[ $((now - latest)) -lt 3600 ]]; then
    echo "[OK] recent WireGuard handshake (<= 1h)"
else
    echo "[WARN] no WireGuard handshake in the last hour"
fi

echo "[PASS] synthetic check"
