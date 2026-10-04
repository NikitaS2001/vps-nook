"""Installer PTY fixture requiring Bash, strace, OpenSSH, awk and coreutils.

Requires Python 3.9+ and Linux 5.3+ with working pidfd_open support.
"""
import os
import pathlib
import pty
import re
import select
import shlex
import signal
import subprocess
import time
from dataclasses import dataclass
from types import SimpleNamespace

PTY_TIMEOUT = 30
TERMINAL_UPDATE = re.compile(rb"ioctl\(0, .*TCSETS[WF]?2?, .*c_lflag=.*\) += 0$")
READ_ENTER = re.compile(rb"read\(0, 0x[0-9a-f]+, 0x[0-9a-f]+")


class DialogueTimeout(AssertionError):
    def __init__(self, name: str, pending: str):
        self.pending = pending
        super().__init__(f"{name}: timed out waiting for {pending}; output withheld")


@dataclass(frozen=True)
class BackendTrace:
    backend: str
    amnezia: bool
    routing: str


def backend_trace(trace: str) -> BackendTrace:
    fields = dict(line.split("=", 1) for line in trace.splitlines() if "=" in line)
    return BackendTrace(fields["backend"], {"false": False, "true": True}[fields["amnezia"]], fields["routing"])


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
    VPN_BACKEND=${{UX_SAVED_BACKEND:-wg}}; validate_vpn_backend
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
run_ansible_pull() {{
    resolve_effective_installer_inputs
    printf 'backend=%s\\namnezia=%s\\nrouting=%s\\napplied\\n' \
        "$VPN_BACKEND" "$WG_AMNEZIA_ENABLED" "$WG_TRAFFIC_MODE" >>"{tmp}/trace"
}}
'''
    marker = 'if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then'
    fixture = tmp / "entry.sh"
    fixture.write_text(installer.replace(marker, stubs + "\n" + marker))
    secrets = ["Admin-fixture-123", "Adguard-fixture-123", "Wireguard-fixture-123"]

    def run_case(name, answers, expected=0, env_extra=None, color=False):
        trace = tmp / "trace"
        trace.unlink(missing_ok=True)
        trace.touch(mode=0o600)
        echo_path = tmp / "echo-ready"
        os.mkfifo(echo_path, mode=0o600)
        echo_read = os.open(echo_path, os.O_RDWR | os.O_NONBLOCK)
        traced_entry = tmp / "traced-entry.sh"
        # Start tracing after the consumer (including guest sudo) establishes
        # its privileges. Tracing sudo itself would disable setuid escalation.
        traced_entry.write_text("exec " + shlex.join([
            "strace", "-f", "-qq", "-e", "trace=ioctl,read", "-e", "raw=read", "-o", str(echo_path),
            "bash", "-c", f"cat {shlex.quote(str(fixture))} | bash",
        ]) + "\n")
        pid, fd = pty.fork()
        if pid == 0:
            os.close(echo_read)
            os.umask(0o077)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("NOOK_", "ZERO_TRUST_"))}
            env.update(TERM="xterm", NO_COLOR="1")
            env.update(env_extra or {})
            if color:
                env.pop("NO_COLOR", None)
            # Observe terminal ioctls and raw read entry, never secret bytes.
            # The real Bash builtin and its -r/-s flags remain untouched.
            os.execvpe("bash", ["bash", "-c", f"cat {shlex.quote(str(traced_entry))} | {shlex.join(consumer)}"], env)
        exited = os.pidfd_open(pid)
        output = b""
        echo_output = b""
        echo_records = b""
        echo_disabled = False
        terminal_read = False
        read_ready = False
        cursor = 0
        status = None
        ended = 0
        deadline = time.monotonic() + PTY_TIMEOUT
        steps = iter(answers)
        pending = next(steps, None)
        try:
            while time.monotonic() < deadline:
                ready = select.select([fd, echo_read, exited], [], [], max(0, deadline - time.monotonic()))[0]
                if echo_read in ready:
                    chunk = os.read(echo_read, 65536)
                    echo_records += chunk
                    echo_output += chunk
                    while b"\n" in echo_output:
                        line, echo_output = echo_output.split(b"\n", 1)
                        if b"ioctl(0, TCGETS" in line and b"c_lflag=" in line and line.endswith(b"= 0"):
                            terminal_read = True
                        if TERMINAL_UPDATE.search(line):
                            flags = line.split(b"c_lflag=", 1)[1].split(b",", 1)[0]
                            echo_disabled = re.search(rb"\bECHO\b", flags) is None
                        if terminal_read and READ_ENTER.search(line):
                            read_ready = True
                    # strace flushes raw arguments at syscall entry, before the
                    # blocked read returns or its line receives a newline.
                    if terminal_read and READ_ENTER.search(echo_output):
                        read_ready = True
                if fd in ready:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        chunk = b""
                    output += chunk
                if pending:
                    needle, answer = pending
                    index = output.find(needle.encode(), cursor)
                    secret_read = "password:" in needle
                    if index >= 0 and read_ready and (not secret_read or echo_disabled):
                        cursor = index + len(needle)
                        os.write(fd, answer.encode())
                        terminal_read = False
                        read_ready = False
                        if secret_read:
                            echo_disabled = False
                        pending = next(steps, None)
                if exited in ready:
                    ended, status = os.waitpid(pid, 0)
                    break
            else:
                raise DialogueTimeout(name, pending[0] if pending else "exit")
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
            ioctl_log = log.with_suffix(".ioctl.log")
            ioctl_log.touch(mode=0o600)
            ioctl_log.write_bytes(echo_records)
            if not ended:
                try:
                    os.killpg(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                if select.select([exited], [], [], PTY_TIMEOUT)[0]:
                    ended, _ = os.waitpid(pid, 0)
            if not ended:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)
            os.close(fd)
            os.close(echo_read)
            os.close(exited)
            echo_path.unlink()
            traced_entry.unlink()

    base = [("VPN backend (1 or 2)", "\n"), ("VPN purpose (1 or 2)", "\n"), ("Public WireGuard hostname", "\n"),
            ("SSH public key", key + "\n")]
    for label, secret in zip(("Administrator account password", "AdGuard password", "WireGuard panel password"), secrets):
        base += [(label + ":", secret + "\n"), ("Confirm " + label + ":", secret + "\n")]
    base += [("Customize ports", "n\n")]
    unicode_long = "я" * 37
    automated = {"NOOK_NONINTERACTIVE": "1", "NOOK_ADMIN_PASSWORD": secrets[0],
                 "NOOK_ADGUARD_PASSWORD": secrets[1], "NOOK_WG_PASSWORD": secrets[2],
                 "NOOK_SSH_PUBKEY": key, "NOOK_WG_HOST": "203.0.113.10"}
    return SimpleNamespace(**locals(), backend_trace=backend_trace)
