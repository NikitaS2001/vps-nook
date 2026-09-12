"""Installer UI fixtures use a real PTY with provisioning functions stubbed."""
import os
import pathlib
import pty
import select
import shlex
import signal
import shutil
import subprocess
import time
from types import SimpleNamespace
import pytest

pytestmark = pytest.mark.quick

@pytest.fixture
def ux(source_root, tmp_path, log_dir, request):
    root, tmp = source_root, tmp_path
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

    def run_case(name, answers, expected=0, env_extra=None, use_sudo=False, color=False):
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
            consumer = "sudo -n -E bash" if use_sudo else "bash"
            os.execvpe("bash", ["bash", "-c", f"cat {shlex.quote(str(fixture))} | {consumer}"], env)
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
            assert result == expected, (name, result, output[-1000:])
            assert pending is None, (name, pending[0])
            for secret in secrets:
                assert secret.encode() not in output, f"{name}: secret echoed"
            assert (b"\x1b[" in output) == color, f"{name}: terminal color policy failed"

            return output.decode(errors="replace"), trace.read_text() if trace.exists() else ""
        finally:
            log = log_dir / (request.node.name + ".log")
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


def test_installer_defaults(ux):
    run_case = ux.run_case
    base = ux.base
    output, trace = run_case("pipe, defaults and completion", base + [("Install, edit, or cancel", "i\n")])
    assert "applied" in trace and "TCP 2222" in output and "fetched_certs/localhost/root.crt" in output


def test_installer_colors(ux):
    run_case = ux.run_case
    base = ux.base
    run_case("TTY colors", base + [("Install, edit, or cancel", "i\n")], color=True)


def test_installer_cancel(ux):
    run_case = ux.run_case
    base = ux.base
    output, trace = run_case("safe default cancellation", base + [("Install, edit, or cancel", "\n")], 130)
    assert "applied" not in trace


def test_installer_edit_invalid_port(ux):
    run_case = ux.run_case
    base = ux.base
    edit = base + [("Install, edit, or cancel", "e\n"), ("Field to edit", "7\n"),
                   ("SSH port [2222]", "abc\n"), ("SSH port [2222]", "2223\n"),
                   ("WireGuard UDP port", "\n"), ("Administrator username", "\n"),
                   ("Internal DNS suffix", "\n"), ("Internal domains (wg-easy, AdGuard)", "\n"),
                   ("Install, edit, or cancel", "i\n")]
    output, _ = run_case("edit and inline port validation", edit, env_extra={"TERM": "dumb"})
    assert "TCP 2223" in output and "Please correct this field" in output


def test_installer_ctrl_c(ux):
    run_case = ux.run_case
    run_case("Ctrl+C", [("VPN purpose", "\x03")], 130)


def test_installer_eof(ux):
    run_case = ux.run_case
    run_case("EOF", [("VPN purpose", "\x04")], 1)


def test_installer_password_length(ux):
    run_case = ux.run_case
    base = ux.base
    bad = base.copy()
    bad[3:3] = [("Administrator account password:", "short\n")]
    run_case("password length retry", bad + [("Install, edit, or cancel", "i\n")])


def test_installer_utf8(ux):
    run_case = ux.run_case
    base = ux.base
    unicode_long = ux.unicode_long
    unicode_retry = base.copy()
    unicode_retry[5:5] = [("AdGuard password:", unicode_long + "\n")]
    output, _ = run_case("bcrypt UTF-8 byte limit retry", unicode_retry + [("Install, edit, or cancel", "i\n")])
    assert "at most 72 UTF-8 bytes" in output and unicode_long not in output


def test_installer_password_confirmation(ux):
    run_case = ux.run_case
    base = ux.base
    secrets = ux.secrets
    mismatch = base.copy()
    mismatch[4:5] = [("Confirm Administrator account password:", "different\n"),
                     ("Administrator account password:", secrets[0] + "\n"),
                     ("Confirm Administrator account password:", secrets[0] + "\n")]
    run_case("password confirmation retry", mismatch + [("Install, edit, or cancel", "i\n")])


def test_installer_legacy_variable(ux):
    run_case = ux.run_case
    secrets = ux.secrets
    output, trace = run_case("legacy variable rejection", [], 1, {"ZERO_TRUST_ADMIN_PASSWORD": secrets[0]})
    assert "NOOK_ADMIN_PASSWORD" in output and not trace


def test_installer_legacy_path(ux):
    run_case = ux.run_case
    tmp = ux.tmp
    legacy = tmp / "zero-trust-vps"
    legacy.mkdir()
    output, trace = run_case("legacy path rejection", [], 1)
    assert "Legacy installation" in output and not trace
    legacy.rmdir()


def test_installer_no_tty(ux):
    fixture = ux.fixture
    env = {k: v for k, v in os.environ.items() if not k.startswith(("NOOK_", "ZERO_TRUST_"))}
    result = subprocess.run(["bash", str(fixture)], env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True, timeout=10)
    assert result.returncode != 0 and b"TTY" in result.stdout


def test_installer_saved_state(ux):
    run_case = ux.run_case
    output, trace = run_case("saved-state interactive review", [("Install, edit, or cancel", "i\n")], env_extra={"UX_EXISTING": "1"})
    assert "applied" in trace and "Administrator account password:" not in output


def test_installer_noninteractive(ux):
    run_case = ux.run_case
    automated = ux.automated
    _, trace = run_case("NOOK noninteractive", [], env_extra=automated)
    assert "applied" in trace


def test_installer_noninteractive_utf8(ux):
    run_case = ux.run_case
    automated = ux.automated
    unicode_long = ux.unicode_long
    output, trace = run_case("noninteractive bcrypt UTF-8 byte limit", [], 1,
                             env_extra={**automated, "NOOK_ADGUARD_PASSWORD": unicode_long})
    assert "bcrypt limit" in output and "applied" not in trace and unicode_long not in output


def test_installer_truncated(ux):
    installer = ux.installer
    marker = ux.marker
    env = {k: v for k, v in os.environ.items() if not k.startswith(("NOOK_", "ZERO_TRUST_"))}
    truncated = installer[:installer.index(marker)]
    result = subprocess.run(["bash"], input=truncated, text=True, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
    assert "VPS NOOK" not in result.stdout


def test_installer_sudo(ux):
    run_case = ux.run_case
    base = ux.base
    if not shutil.which("sudo") or subprocess.run(["sudo", "-n", "true"], stdout=subprocess.DEVNULL,
                                                   stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, timeout=10).returncode:
        if os.environ.get("CI"):
            pytest.fail("CI requires passwordless sudo for the installer PTY case", pytrace=False)
        pytest.skip("passwordless sudo unavailable")
    run_case("sudo pipe", base + [("Install, edit, or cancel", "i\n")], use_sudo=True)
