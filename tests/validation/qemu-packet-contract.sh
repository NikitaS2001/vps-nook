#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly ROOT_DIR
readonly CLIENT="${ROOT_DIR}/tests/e2e/client-in-guest.sh"
readonly COMMON="${ROOT_DIR}/tests/e2e/common.sh"
readonly QEMU="${ROOT_DIR}/tests/e2e/qemu-install.sh"

grep -Fq "AllowedIPs = 0.0.0.0/0, ::/0" "${CLIENT}"
grep -Fq -- '--interface zt-e2e' "${CLIENT}"
grep -Fq 'https://1.1.1.1/cdn-cgi/trace' "${CLIENT}"
grep -Fq 'https://[2606:4700:4700::1111]/cdn-cgi/trace' "${CLIENT}"
grep -Fq 'public egress escaped services through WireGuard' "${CLIENT}"
grep -Fq 'public egress failed through full' "${CLIENT}"
grep -Fq 'IPv6 is outside this IPv4-only full profile' "${CLIENT}"
grep -Fq 'IPv6 public-egress packet probe: test host has no direct IPv6' "${CLIENT}"
grep -Fq 'docker exec wg-easy wg show wg0 peers' "${CLIENT}"
grep -Fq "docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' wg-easy" "${CLIENT}"
grep -Fq "tr -d '\\r' | wg pubkey" "${CLIENT}"
grep -Fq 'ping -I zt-e2e' "${CLIENT}"
grep -Fq 'WireGuard client could not establish a handshake' "${CLIENT}"
grep -Fq 'ip6tables -C FORWARD -i wg0 -j WG_CLIENTS' "${COMMON}"
grep -Fq "WG_PORT='\${E2E_WG_PORT}' WG_TRAFFIC_MODE='\${WG_TRAFFIC_MODE}'" "${QEMU}"
grep -Fq -- '--vaultwarden-test) DO_VAULTWARDEN=true; DO_CLIENT_TEST=true ;;' "${QEMU}"
# shellcheck disable=SC2016
grep -Fq 'VAULTWARDEN_INTERNAL_DOMAIN='"'"'${VAULTWARDEN_INTERNAL_DOMAIN}'"'"'' "${QEMU}"
# shellcheck disable=SC2016
grep -Fq 'VAULTWARDEN_INTERNAL_DOMAIN="${VAULTWARDEN_INTERNAL_DOMAIN:-}"' "${CLIENT}"
# shellcheck disable=SC2016
grep -Fq 'dig +short @10.66.0.2 "${VAULTWARDEN_INTERNAL_DOMAIN}" A' "${CLIENT}"
grep -Fq -- '--interface zt-e2e --connect-timeout 8 --max-time 15' "${CLIENT}"
# shellcheck disable=SC2016
grep -Fq -- '--cacert "${ROOT_CA}"' "${CLIENT}"
grep -Fq 'reachable through WireGuard with trusted root CA' "${CLIENT}"

printf 'qemu-packet-contract: strict IPv4 and environment-qualified IPv6 packet assertions wired PASS\n'
