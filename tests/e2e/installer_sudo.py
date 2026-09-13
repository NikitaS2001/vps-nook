"""Real sudo/PTY coverage, invoked only inside the disposable installer VM."""
import os
from pathlib import Path
import subprocess
import tempfile

from tests.installer.pty_fixture import create_ux


def main():
    if os.geteuid() == 0:
        raise RuntimeError("installer sudo scenario must start as the unprivileged guest user")
    virtualization = subprocess.run(["systemd-detect-virt", "--vm"], check=True,
                                    capture_output=True, text=True, timeout=10).stdout.strip()
    if virtualization not in {"qemu", "kvm"}:
        raise RuntimeError("installer sudo scenario requires a disposable QEMU/KVM guest")
    root = Path(__file__).resolve().parents[2]
    temporary = Path(tempfile.mkdtemp(prefix="nook-sudo-pty-"))
    try:
        ux = create_ux(root, temporary, temporary / "pty.log",
                       consumer=("sudo", "-n", "-E", "bash", "-c", 'test "$EUID" -eq 0 && exec bash'))
        _, trace = ux.run_case("sudo pipe", ux.base + [("Install, edit, or cancel", "i\n")])
        assert "applied" in trace, "sudo pipeline did not complete installer input handling"
    finally:
        # Only this guest-only entrypoint escalates. The fixture may create root-owned state.
        subprocess.run(["sudo", "-n", "rm", "-rf", "--", str(temporary)], check=True,
                       stdin=subprocess.DEVNULL, timeout=10)
    print("[PASS] guest sudo pipeline: dialogue completed, passwords hidden, fixture state removed")


if __name__ == "__main__":
    main()
