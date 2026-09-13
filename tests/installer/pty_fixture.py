"""Shared stdlib-only installer PTY fixture for local and disposable-guest checks."""
import os
import pathlib
import pty
import select
import shlex
import signal
import subprocess
import time
from types import SimpleNamespace


def create_ux(root, tmp, log, *, consumer=("bash",)):
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(tmp / "key")], check=True, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    key = (tmp / "key.pub").read_text().strip()
    installer = (root / "install.sh").read_text()
    installer = installer.replace('readonly INSTALL_ROOT="/opt/vps-nook-installer"', f'readonly INSTALL_ROOT="{tmp}/installer"')
    installer = installer.replace('VAULT_DIR="/etc/vps-nook"', f'VAULT_DIR="{tmp}/vault"')
    for old in ("/opt/zero-trust-vps-installer", "/opt/zero-trust-vps", "/etc/zero-trust-vps", "/opt/zt-backups"):
        installer = installer.replace(old, str(tmp / pathlib.Path(old).name))
    stubs = f'''
require_root() {{ :; }}
require_supported_os() {{ PRETTY_NAME='Fixture Linux'; }}
require_supported_platform() {{ :; }}
require_minimum_memory() {{ :; }}
require_tun() {{ :; }}
available_memory_mib() {{ echo 1024; }}
report_existing_swap() {{ :; }}
install_prerequisites() {{ echo prerequisites >>"{tmp}/trace"; }}
installer_state_paths_present() {{ [[ ${{UX_EXISTING:-0}} == 1 ]]; }}
load_installer_inputs() {{
    SSH_PORT=2222; WG_PORT=51820; ADMIN_USER=sysadmin; WG_HOST=203.0.113.10
    WG_INTERNAL_DOMAIN=wg.internal; ADGUARD_INTERNAL_DOMAIN=adguard.internal
    INTERNAL_DOMAIN_SUFFIX=internal; INTERNAL_DOMAINS='wg.internal adguard.internal'
}}
checkout_release() {{ RESOLVED_RELEASE_REF=fixture; echo verified >>"{tmp}/trace"; }}
read_yaml_scalar_default() {{
    local path="$1"
    path="{root}/${{path#*/repo/}}"
    awk -v key="$2" '$1 == key ":" {{gsub(/"/, "", $2); print $2; exit}}' "$path"
}}
install_ansible_toolchain() {{ :; }}
install_collections() {{ :; }}
detect_public_ip() {{ echo 203.0.113.10; }}
run_ansible_pull() {{ resolve_effective_installer_inputs; echo applied >>"{tmp}/trace"; }}
'''
    marker = 'if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then'
    fixture = tmp / "entry.sh"
    fixture.write_text(installer.replace(marker, stubs + "\n" + marker))
    secrets = ["Admin-fixture-123", "Adguard-fixture-123", "Wireguard-fixture-123"]

    def run_case(name, answers, expected=0, env_extra=None, color=False):
        trace = tmp / "trace"
        trace.unlink(missing_ok=True)
        trace.touch(mode=0o600)
        pid, fd = pty.fork()
        if pid == 0:
            os.umask(0o077)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("NOOK_", "ZERO_TRUST_"))}
            env.update(TERM="xterm", NO_COLOR="1")
            env.update(env_extra or {})
            if color:
                env.pop("NO_COLOR", None)
            os.execvpe("bash", ["bash", "-c", f"cat {shlex.quote(str(fixture))} | {shlex.join(consumer)}"], env)
        output = b""
        cursor = 0
        status = None
        ended = 0
        deadline = time.monotonic() + 30
        steps = iter(answers)
        pending = next(steps, None)
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        chunk = b""
                    output += chunk
                if pending:
                    needle, answer = pending
                    index = output.find(needle.encode(), cursor)
                    if index >= 0:
                        cursor = index + len(needle)
                        # Wait for read -s to disable echo before entering secrets.
                        time.sleep(0.03)
                        os.write(fd, answer.encode())
                        pending = next(steps, None)
                ended, status = os.waitpid(pid, os.WNOHANG)
                if ended:
                    break
            else:
                raise AssertionError(f"{name}: timed out waiting for {pending[0] if pending else 'exit'}; output withheld")
            result = os.waitstatus_to_exitcode(status)
            assert result == expected, (name, result, "output withheld")
            assert pending is None, (name, pending[0])
            for secret in secrets:
                assert secret.encode() not in output, f"{name}: secret echoed"
            assert (b"\x1b[" in output) == color, f"{name}: terminal color policy failed"

            return output.decode(errors="replace"), trace.read_text() if trace.exists() else ""
        finally:
            log.touch(mode=0o600)
            log.write_bytes(output)
            if not ended:
                try:
                    os.killpg(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    ended, _ = os.waitpid(pid, os.WNOHANG)
                    if ended:
                        break
                    time.sleep(0.1)
            if not ended:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)
            os.close(fd)

    base = [("VPN purpose (1 or 2)", "\n"), ("Public WireGuard hostname", "\n"),
            ("SSH public key", key + "\n")]
    for label, secret in zip(("Administrator account password", "AdGuard password", "WireGuard panel password"), secrets):
        base += [(label + ":", secret + "\n"), ("Confirm " + label + ":", secret + "\n")]
    base += [("Customize ports", "n\n")]
    unicode_long = "я" * 37
    automated = {"NOOK_NONINTERACTIVE": "1", "NOOK_ADMIN_PASSWORD": secrets[0],
                 "NOOK_ADGUARD_PASSWORD": secrets[1], "NOOK_WG_PASSWORD": secrets[2],
                 "NOOK_SSH_PUBKEY": key, "NOOK_WG_HOST": "203.0.113.10"}
    return SimpleNamespace(**locals())
