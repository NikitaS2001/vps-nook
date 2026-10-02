#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROLE="${ROOT}/roles/vps_orchestration"

grep -q '^argument_specs:' "${ROLE}/meta/argument_specs.yml"
grep -q 'choices: \[services, full\]' "${ROLE}/meta/argument_specs.yml"
grep -q '^wg_traffic_mode: "services"$' "${ROLE}/defaults/main.yml"
grep -q 'wg_easy_admin_password is not defined' "${ROLE}/tasks/main.yml"
grep -q 'wg_easy_bootstrap_secret is defined' "${ROLE}/tasks/main.yml"

if grep -R -E '^[[:space:]]+(apt|apt_repository|assert|command|copy|debug|fail|fetch|file|find|get_url|include_tasks|meta|service|set_fact|shell|slurp|stat|systemd|tempfile|template|uri|user|wait_for):' \
    "${ROLE}/tasks" "${ROLE}/handlers"; then
    echo 'non-FQCN builtin module found' >&2
    exit 1
fi

grep -q -- '- NET_ADMIN' "${ROLE}/templates/docker-compose.yml.j2"
if grep -q -E 'SYS_MODULE|/lib/modules' "${ROLE}/templates/docker-compose.yml.j2"; then
    echo 'unnecessary kernel capability or module mount found' >&2
    exit 1
fi

[[ "$(grep -c "mode: '0700'" "${ROLE}/tasks/volumes.yml")" -eq 3 ]]
for boundary in compose_prepare.yml caddy_transaction.yml compose_lifecycle.yml; do
    grep -q "${boundary}" "${ROLE}/tasks/compose.yml"
done

grep -q 'netfilter_modules.yml' "${ROLE}/tasks/main.yml"
grep -q 'community.general.modprobe:' "${ROLE}/tasks/netfilter_modules.yml"
grep -q 'persistent: present' "${ROLE}/tasks/netfilter_modules.yml"
if grep -q 'linux-modules-extra' "${ROLE}/tasks/netfilter_modules.yml"; then
    echo 'kernel-package fallback would hide an unsupported host kernel' >&2
    exit 1
fi
for module in iptable_filter ip6table_filter iptable_nat ip6table_nat xt_MASQUERADE xt_comment xt_tcpudp; do
    grep -q "^[[:space:]]*- ${module}$" "${ROLE}/tasks/netfilter_modules.yml"
done

grep -q '^wg_amnezia_enabled: false$' "${ROLE}/defaults/main.yml"
grep -q 'modinfo' "${ROLE}/tasks/main.yml"
grep -q 'wg_amnezia_kernel_module' "${ROLE}/tasks/netfilter_modules.yml"
if grep -R -q -E 'dkms|kernel-mgmt|make -C' "${ROLE}/tasks"; then
  echo 'role must not build kernel modules' >&2
  exit 1
fi
grep -q 'OVERRIDE_AUTO_AWG' "${ROLE}/templates/docker-compose.yml.j2"
grep -q 'vps_orchestration_wg_executable' "${ROLE}/tasks/traffic_mode.yml"
grep -q 'vps_orchestration_wg_executable' "${ROLE}/tasks/verify.yml"
grep -q 'WG_EXEC' "${ROOT}/scripts/synthetic-check.sh"

printf '[PASS] argument_specs, FQCN, vault-only bootstrap, private volumes, host netfilter, minimal container capabilities, transaction boundaries\n'
