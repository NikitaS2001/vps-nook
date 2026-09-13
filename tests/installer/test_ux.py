"""Installer UI fixtures use a real PTY with provisioning functions stubbed."""
import os
import subprocess

from tests.installer.pty_fixture import create_ux
import pytest

pytestmark = pytest.mark.quick

@pytest.fixture
def ux(source_root, tmp_path, log_dir, request):
    return create_ux(source_root, tmp_path, log_dir / (request.node.name + ".log"))


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
