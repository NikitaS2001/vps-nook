"""Installer feasibility must not inherit the 30s secret/vault command budget."""
import importlib.util
import re
import subprocess

import pytest

pytestmark = pytest.mark.quick


@pytest.mark.parametrize('backend', ['wg', 'awg'])
def test_selected_backend_uses_separate_bounded_network_feasibility_budget(source_root, tmp_path, backend):
    installer = (source_root / 'install.sh').read_text()
    vault_budget = int(re.search(r'^VAULT_COMMAND_TIMEOUT=(\d+)$', installer, re.M)[1])
    awg_budget = int(re.search(r'^AWG_PREFLIGHT_TIMEOUT=(\d+)$', installer, re.M)[1])
    path = source_root / 'roles/vps_orchestration/files/awg_module.py'
    spec = importlib.util.spec_from_file_location('awg_budget_owner', path)
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    assert vault_budget == 30  # secret readiness/rollback tests retain their budget
    assert awg_budget == owner.DEPENDENCY_TIMEOUT + owner.COMMAND_TIMEOUT
    start = installer.index('require_selected_backend() {')
    function = installer[start:installer.index('\n}\n', start) + 3]
    repository = tmp_path / 'repo'
    target = repository / 'roles/vps_orchestration/files/awg_module.py'
    target.parent.mkdir(parents=True)
    target.write_text('# test-only verified owner placeholder\n')
    script = tmp_path / 'budget.sh'
    script.write_text('set -euo pipefail\n'
                      'VPN_BACKEND="$1"\nREPO_DIR="$2"\nOUTPUT="$3"\n'
                      'VAULT_COMMAND_TIMEOUT=30\n'
                      f'AWG_PREFLIGHT_TIMEOUT={awg_budget}\n'
                      'VAULT_PYTHON_BIN=/usr/bin/python3\n'
                      'validate_vpn_backend() { :; }\n'
                      'error() { exit 19; }\n'
                      'timeout() { printf "%s\\n" "$@" > "$OUTPUT"; }\n'
                      + function + '\nrequire_selected_backend\n')
    output = tmp_path / 'argv'
    result = subprocess.run(['bash', str(script), backend, str(repository), str(output)],
                            capture_output=True, timeout=5)
    assert result.returncode == 0
    if backend == 'wg':
        assert not output.exists()
    else:
        assert output.read_text().splitlines() == [str(awg_budget), '/usr/bin/python3', str(target), 'preflight']
