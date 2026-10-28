"""Installer UI fixtures use a real PTY with provisioning functions stubbed."""
import os
import re
import subprocess

from tests.installer import pty_fixture
from tests.installer.pty_fixture import create_ux
import pytest

pytestmark = pytest.mark.quick

@pytest.fixture
def ux(source_root, tmp_path, log_dir, request):
    request.node.user_properties.append(("private_log_directory", str(log_dir)))
    return create_ux(source_root, tmp_path, log_dir / (request.node.name + ".log"))


def test_installer_defaults(ux):
    run_case = ux.run_case
    base = ux.base
    output, trace = run_case("pipe, defaults and completion", base + [("Install, edit, or cancel", "i\n")])
    assert "applied" in trace and "TCP 2222" in output and "fetched_certs/localhost/root.crt" in output
    fields = ux.backend_trace(trace)
    assert fields.backend == "wg" and fields.amnezia is False and fields.routing == "services"


def test_installer_script_consumer(source_root, tmp_path, log_dir, request):
    request.node.user_properties.append(("private_log_directory", str(log_dir)))
    ux = create_ux(source_root, tmp_path, log_dir / (request.node.name + ".log"),
                   consumer=("bash", "-c", 'exec bash "$1"', "nook-script-pty"),
                   consumer_script=True)
    _, trace = ux.run_case("script consumer", ux.base + [("Install, edit, or cancel", "i\n")])
    assert "applied" in trace
    assert ux.backend_trace(trace) == pty_fixture.BackendTrace("wg", False, "services")


@pytest.mark.parametrize("backend,selection,enabled", [("wg", "1", "false"), ("awg", "2", "true")])
@pytest.mark.parametrize("routing,selection_mode", [("services", "1"), ("full", "2")])
def test_installer_backend_choice(ux, backend, selection, enabled, routing, selection_mode):
    answers = ux.base.copy()
    answers[:2] = [("VPN backend (1 or 2)", selection + "\n"), ("VPN purpose (1 or 2)", selection_mode + "\n")]
    _, trace = ux.run_case("backend independent of routing", answers + [("Install, edit, or cancel", "i\n")])
    fields = ux.backend_trace(trace)
    assert fields.backend == backend and fields.amnezia is (enabled == "true") and fields.routing == routing


@pytest.mark.parametrize("invalid", ["bogus", "0", "3", "AWG"])
def test_installer_backend_invalid(ux, invalid):
    answers = [("VPN backend (1 or 2)", invalid + "\n")] + ux.base
    _, trace = ux.run_case("invalid backend retries", answers + [("Install, edit, or cancel", "i\n")])
    fields = ux.backend_trace(trace)
    assert fields.backend == "wg" and fields.amnezia is False


@pytest.mark.parametrize("initial,edited,backend,enabled", [("1", "2", "awg", "true"), ("2", "1", "wg", "false")])
def test_installer_backend_edit(ux, initial, edited, backend, enabled):
    answers = ux.base.copy()
    answers[0] = ("VPN backend (1 or 2)", initial + "\n")
    answers += [("Install, edit, or cancel", "e\n"), ("Field to edit", "8\n"),
                ("VPN backend (1 or 2)", edited + "\n"), ("Install, edit, or cancel", "i\n")]
    _, trace = ux.run_case("edit backend only", answers)
    fields = ux.backend_trace(trace)
    assert fields.backend == backend and fields.amnezia is (enabled == "true") and fields.routing == "services"


def test_installer_colors(ux):
    run_case = ux.run_case
    base = ux.base
    run_case("TTY colors", base + [("Install, edit, or cancel", "i\n")], color=True)


@pytest.mark.parametrize("selection", ["1", "2"])
def test_installer_cancel(ux, selection):
    run_case = ux.run_case
    base = ux.base
    answers = base.copy()
    answers[0] = ("VPN backend (1 or 2)", selection + "\n")
    output, trace = run_case("safe default cancellation", answers + [("Install, edit, or cancel", "\n")], 130)
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


@pytest.mark.parametrize("boundary", [0, 1, 4, 11])
def test_installer_ctrl_c(ux, boundary):
    run_case = ux.run_case
    answers = ux.base.copy()
    answers[0] = ("VPN backend (1 or 2)", "2\n")
    prompt = answers[boundary][0] if boundary < len(answers) else "Install, edit, or cancel"
    _, trace = run_case("Ctrl+C", answers[:boundary] + [(prompt, "\x03")], 130)
    assert "applied" not in trace


@pytest.mark.parametrize("boundary", [0, 1, 4, 11])
def test_installer_eof(ux, boundary):
    run_case = ux.run_case
    answers = ux.base.copy()
    answers[0] = ("VPN backend (1 or 2)", "2\n")
    prompt = answers[boundary][0] if boundary < len(answers) else "Install, edit, or cancel"
    _, trace = run_case("EOF", answers[:boundary] + [(prompt, "\x04")], 1)
    assert "applied" not in trace


def test_installer_password_length(ux):
    run_case = ux.run_case
    base = ux.base
    bad = base.copy()
    bad[4:4] = [("Administrator account password:", "short\n")]
    run_case("password length retry", bad + [("Install, edit, or cancel", "i\n")])


def test_installer_utf8(ux):
    run_case = ux.run_case
    base = ux.base
    unicode_long = ux.unicode_long
    unicode_retry = base.copy()
    unicode_retry[6:6] = [("AdGuard password:", unicode_long + "\n")]
    output, _ = run_case("bcrypt UTF-8 byte limit retry", unicode_retry + [("Install, edit, or cancel", "i\n")])
    assert "at most 72 UTF-8 bytes" in output and unicode_long not in output


def test_installer_password_confirmation(ux):
    run_case = ux.run_case
    base = ux.base
    secrets = ux.secrets
    mismatch = base.copy()
    mismatch[5:6] = [("Confirm Administrator account password:", "different\n"),
                     ("Administrator account password:", secrets[0] + "\n"),
                     ("Confirm Administrator account password:", secrets[0] + "\n")]
    run_case("password confirmation retry", mismatch + [("Install, edit, or cancel", "i\n")])


@pytest.mark.parametrize("readiness", ["TERMINAL_UPDATE", "READ_ENTER"])
def test_installer_secret_readiness_failure(ux, monkeypatch, readiness):
    monkeypatch.setattr(pty_fixture, readiness, re.compile(rb"(?!)"))
    with pytest.raises(pty_fixture.DialogueTimeout) as failure:
        ux.run_case("missing secret-read readiness", ux.base + [("Install, edit, or cancel", "i\n")])
    assert failure.value.pending == ux.base[{"TERMINAL_UPDATE": 4, "READ_ENTER": 0}[readiness]][0]
    assert "applied" not in (ux.tmp / "trace").read_text()
    assert not (ux.tmp / "echo-ready").exists() and not (ux.tmp / "traced-entry.sh").exists()


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


@pytest.mark.parametrize("backend,enabled", [("wg", "false"), ("awg", "true")])
def test_installer_saved_state(ux, backend, enabled):
    run_case = ux.run_case
    output, trace = run_case("saved-state interactive review", [("Install, edit, or cancel", "i\n")],
                             env_extra={"UX_EXISTING": "1", "UX_SAVED_BACKEND": backend})
    assert "applied" in trace and "Administrator account password:" not in output
    assert "password:" not in output
    fields = ux.backend_trace(trace)
    assert fields.backend == backend and fields.amnezia is (enabled == "true")


def test_installer_saved_backend_immutable(ux):
    answers = [("Install, edit, or cancel", "e\n"), ("Install, edit, or cancel", "i\n")]
    output, trace = ux.run_case("saved AWG cannot edit", answers, env_extra={"UX_EXISTING": "1", "UX_SAVED_BACKEND": "awg"})
    assert "Field to edit" not in output and "password:" not in output
    fields = ux.backend_trace(trace)
    assert fields.backend == "awg" and fields.amnezia is True


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
