"""Execute the client dependency owner without modifying the host resolver."""
import subprocess

import pytest

pytestmark = pytest.mark.quick


@pytest.mark.parametrize('backend', ['wg', 'awg'])
@pytest.mark.parametrize('mode', ['resolved', 'resolved-existing', 'legacy', 'conflict',
                                  'resolved-missing-client', 'resolved-nonexec', 'indeterminate', 'query-error-inactive',
                                  'apt-update-failure', 'apt-install-failure'])
def test_client_dependencies_preserve_active_resolver_provider(source_root, tmp_path, mode, backend):
    text = (source_root / 'tests/e2e/prepare-vpn-client.sh').read_text()
    start = text.index('prepare_client_dependencies() {')
    function = text[start:text.index('\n}\nprepare_client_dependencies', start) + 3]
    alias = tmp_path / 'resolvconf'
    executable = tmp_path / 'resolvectl'
    executable.write_text('test-only resolver executable')
    executable.chmod(0o600 if mode == 'resolved-nonexec' else 0o755)
    if mode == 'resolved-existing':
        alias.symlink_to(executable)
    if mode == 'conflict':
        alias.write_text('operator-owned foreign provider')
    before = alias.read_bytes() if mode == 'conflict' else None
    # Map only the install destination into the private fixture; execute the
    # production function's exact branching/argv. Fake apt never installs.
    function = function.replace('/usr/local/bin/resolvconf', str(alias))
    calls = tmp_path / 'calls'
    script = tmp_path / 'provider.sh'
    script.write_text('set -euo pipefail\n'
                      'MODE="$1"; RESOLVER="$2"; ALIAS="$3"; CALLS="$4"\n'
                      'CLIENT_BACKEND="$5"\n'
                      'systemctl() {\n'
                      ' if [[ "$MODE" == legacy ]]; then echo inactive; return 3;\n'
                      ' elif [[ "$MODE" == indeterminate ]]; then echo unknown; return 4;\n'
                      ' elif [[ "$MODE" == query-error-inactive ]]; then echo inactive; return 4;\n'
                      ' else echo active; fi\n}\n'
                      'command() {\n'
                      ' if [[ "$1" == -v && "$2" == resolvectl ]]; then\n'
                      '  [[ "$MODE" != resolved-missing-client ]] || return 1; printf "%s\\n" "$RESOLVER";\n'
                      ' elif [[ "$1" == -v && "$2" == resolvconf ]]; then\n'
                      '  [[ "$MODE" == resolved-existing || "$MODE" == conflict ]] || return 1; printf "%s\\n" "$ALIAS";\n'
                      ' else builtin command "$@"; fi\n}\n'
                      'apt-get() {\n'
                      ' printf "%s\\n" "$@" >> "$CALLS"\n'
                      ' [[ "$MODE:$1" != apt-update-failure:update && "$MODE:$1" != apt-install-failure:install ]] || return 42\n'
                      '}\n'
                      + function + '\nprepare_client_dependencies\n')
    result = subprocess.run(['bash', str(script), mode, str(executable), str(alias), str(calls), backend],
                            capture_output=True, text=True, timeout=5)
    if mode == 'conflict':
        assert result.returncode != 0
        assert alias.read_bytes() == before and not calls.exists()
        assert 'conflicting resolvconf provider' in result.stderr
    elif mode in ('resolved-missing-client', 'resolved-nonexec', 'indeterminate', 'query-error-inactive'):
        assert result.returncode != 0
        assert not calls.exists() and not alias.exists() and not alias.is_symlink()
    elif mode in ('apt-update-failure', 'apt-install-failure'):
        assert result.returncode == 42
        assert alias.is_symlink() and alias.resolve() == executable
        operations = calls.read_text().splitlines()
        assert ('install' in operations) == (mode == 'apt-install-failure')
        assert 'resolvconf' not in operations
    else:
        assert result.returncode == 0, result.stderr
        packages = calls.read_text().splitlines()
        assert packages[:2] == ['update', '-qq']
        assert ('resolvconf' in packages) == (mode == 'legacy')
        if mode != 'legacy':
            assert alias.is_symlink() and alias.resolve() == executable
        else:
            assert not alias.exists()
