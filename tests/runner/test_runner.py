"""Fault injection stays in tiny fixture suites, never recursively runs project checks."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import pytest

from tests.registry import CONTRACTS, VMS, validate_registry
from tests.support import CommandFailure, cleanup_vms, process_identity, run, snapshot
from tests.contracts.test_tools import tool_argv

pytestmark = pytest.mark.quick


@pytest.fixture
def wrapper(tmp_path, source_root):
    (tmp_path / "scripts").mkdir()
    entry = tmp_path / "scripts/check.sh"
    entry.write_bytes((source_root / "scripts/check.sh").read_bytes())
    binary = tmp_path / ".venv/bin"
    binary.mkdir(parents=True)
    fake = binary / "pytest"
    fake.write_text('''#!/usr/bin/env python3
import os, sys
with open(os.environ['CALL_LOG'], 'a') as log:
    log.write(repr(sys.argv[1:]) + '\\n')
assert sys.stdin.read() == ''
if sys.argv[3] == os.environ.get('FAIL_STAGE'):
    sys.exit(23)
''')
    fake.chmod(0o700)
    return entry, {**os.environ, "CALL_LOG": str(tmp_path / "calls"), "NOOK_JUNIT_DIR": ""}


@pytest.mark.parametrize("option,stages", [(None, ["quick"]), ("--e2e", ["quick", "qemu"]),
                                           ("--release", ["quick", "qemu", "lifecycle", "release and not quick"])])
def test_wrapper_selection(wrapper, option, stages):
    import ast
    entry, env = wrapper
    result = subprocess.run(["bash", str(entry)] + ([option] if option else []), env=env,
                            input=b"unconsumed operator stdin", capture_output=True, timeout=10)
    assert result.returncode == 0
    calls = [ast.literal_eval(line) for line in Path(env["CALL_LOG"]).read_text().splitlines()]
    assert calls == [["-x", "-m", stage] for stage in stages]


@pytest.mark.parametrize("stage", ["quick", "qemu", "lifecycle", "release and not quick"])
def test_wrapper_failure(wrapper, stage):
    entry, env = wrapper
    result = subprocess.run(["bash", str(entry), "--release"], env={**env, "FAIL_STAGE": stage},
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
    assert result.returncode == 23
    assert stage in Path(env["CALL_LOG"]).read_text().splitlines()[-1]


@pytest.mark.parametrize("args,code", [(["--unknown"], 2), (["--e2e", "extra"], 2),
                                      (["--help", "extra"], 2), (["--help"], 0)])
def test_wrapper_arguments(wrapper, args, code):
    entry, env = wrapper
    result = subprocess.run(["bash", str(entry), *args], env=env, capture_output=True, timeout=10)
    assert result.returncode == code
    assert not Path(env["CALL_LOG"]).exists()
    assert b"Usage:" in (result.stdout if code == 0 else result.stderr)


def test_bootstrap_help(source_root, tmp_path):
    (tmp_path / "scripts").mkdir()
    entry = tmp_path / "scripts/bootstrap.sh"
    entry.write_bytes((source_root / "scripts/bootstrap.sh").read_bytes())
    result = subprocess.run(["bash", str(entry), "--help"], capture_output=True, timeout=10)
    assert result.returncode == 0 and b"pinned development dependencies" in result.stdout
    assert not result.stderr and not (tmp_path / ".venv").exists()


@pytest.mark.parametrize("mutation", ["missing", "duplicate", "renamed", "vm"])
def test_registry_rejects_loss(source_root, mutation):
    from dataclasses import replace
    contracts, vms = CONTRACTS, VMS
    if mutation == "missing":
        contracts = contracts[1:]
    elif mutation == "duplicate":
        contracts = (*contracts, contracts[0])
    elif mutation == "renamed":
        contracts = (replace(contracts[0], argv=("bash", "tests/validation/renamed.sh")), *contracts[1:])
    else:
        vms = vms[:-1]
    with pytest.raises(ValueError):
        validate_registry(source_root, contracts, vms)


def test_gitleaks_hook_no_recursion(source_root):
    assert tool_argv("gitleaks", source_root) == ("pre-commit", "run", "gitleaks", "--all-files")


def test_command_stdin_exit_and_private_log(tmp_path):
    log = tmp_path / "output"
    with pytest.raises(CommandFailure, match="exit 23"):
        run([sys.executable, "-c", "import sys; assert not sys.stdin.read(); print('fixture-secret'); sys.exit(23)"],
            cwd=tmp_path, log=log)
    assert log.stat().st_mode & 0o777 == 0o600
    assert log.read_text().strip() == "fixture-secret"


def test_timeout_kills_children(tmp_path):
    pidfile = tmp_path / "pid"
    program = ("import subprocess,time; from pathlib import Path; "
               "p=subprocess.Popen(['sleep','300']); "
               f"Path({str(pidfile)!r}).write_text(str(p.pid)); time.sleep(300)")
    with pytest.raises(CommandFailure, match="timeout"):
        run([sys.executable, "-c", program], cwd=tmp_path, log=tmp_path / "log", timeout=0.5, grace=0.2)
    assert process_identity(int(pidfile.read_text())) is None


def test_vm_recycled_pid_not_signalled(tmp_path):
    (tmp_path / "test.record").write_text(f"{os.getpid()}\nwrong-start-time\n{tmp_path}\n")
    cleanup_vms(tmp_path, grace=0.1)


def test_vm_wrong_ownership_rejected(tmp_path):
    (tmp_path / "test.record").write_text(f"{os.getpid()}\n{process_identity(os.getpid())}\n{tmp_path}\n")
    with pytest.raises(CommandFailure, match="ownership"):
        cleanup_vms(tmp_path, grace=0.1)


@pytest.mark.parametrize("record", ["", "partial\n", "partial\nrecord\n"],
                         ids=["empty", "one-line", "two-line"])
def test_incomplete_vm_record_uses_valid_intent(tmp_path, record):
    executable = tmp_path / "qemu-system-fixture"
    executable.symlink_to(sys.executable)
    directory = tmp_path / "vm"
    directory.mkdir()
    child = subprocess.Popen([str(executable), "-c",
                              "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)",
                              f"file={directory}/disk.qcow2"], start_new_session=True)
    try:
        time.sleep(0.1)
        started = process_identity(child.pid)
        pidfile = tmp_path / "vm.pid"
        pidfile.write_text(str(child.pid))
        (tmp_path / "vm.intent").write_text(f"{pidfile}\n{started}\n{directory}\n")
        (tmp_path / "vm.record").write_text(record)
        cleanup_vms(tmp_path, grace=0.1)
        assert child.wait(timeout=5) == -signal.SIGKILL
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()


@pytest.mark.parametrize("race_stage", ["cmdline", "sigterm"])
def test_vm_exit_race_during_cleanup(tmp_path, monkeypatch, race_stage):
    import tests.support as support

    executable = tmp_path / "qemu-system-fixture"
    executable.symlink_to(sys.executable)
    directory = tmp_path / "vm"
    directory.mkdir()
    child = subprocess.Popen([str(executable), "-c", "import time; time.sleep(300)",
                              f"file={directory}/disk.qcow2"], start_new_session=True)
    try:
        started = process_identity(child.pid)
        (tmp_path / "vm.record").write_text(f"{child.pid}\n{started}\n{directory}\n")
        if race_stage == "cmdline":
            original_identity = support.process_identity
            checked = False

            def process_identity_after_exit(pid):
                nonlocal checked
                value = original_identity(pid)
                if pid == child.pid and value == started and not checked:
                    checked = True
                    child.terminate()
                    child.wait(timeout=5)
                    return started
                return value

            monkeypatch.setattr(support, "process_identity", process_identity_after_exit)
        else:
            original_kill = support.os.kill

            def signal_after_exit(pid, sig):
                if pid == child.pid and sig == signal.SIGTERM:
                    original_kill(child.pid, sig)
                    child.wait(timeout=5)
                    raise ProcessLookupError
                return original_kill(pid, sig)

            monkeypatch.setattr(support.os, "kill", signal_after_exit)
        cleanup_vms(tmp_path, grace=0.1)
        assert child.poll() is not None
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()


@pytest.mark.parametrize("detached", [False, True], ids=["branch", "detached-merge"])
def test_snapshot_preserves_dirty_sources_excludes_secrets(tmp_path, detached):
    source = tmp_path / "source"
    source.mkdir()
    def git(*args):
        subprocess.run(["git", "-C", str(source), *args], check=True, capture_output=True)
    git("init", "-q")
    (source / ".gitignore").write_text("vault\n")
    (source / "tracked").write_text("original")
    (source / "deleted").write_text("tracked, then removed")
    git("add", ".")
    git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
        "commit", "-qm", "fixture")
    git("tag", "fixture-baseline")
    if detached:
        git("checkout", "--detach", "-q")
        git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "--allow-empty", "-qm", "detached merge fixture")
    (source / "tracked").write_text("staged")
    git("add", "tracked")
    (source / "tracked").write_text("dirty")
    (source / "deleted").unlink()
    (source / "new").write_text("new")
    (source / "vault").write_text("operator secret")
    result = snapshot(source, tmp_path / "copy")
    assert (result / "tracked").read_text() == "dirty"
    assert subprocess.check_output(["git", "-C", str(result), "show", ":tracked"]) == b"dirty"
    assert (result / "new").read_text() == "new"
    assert subprocess.check_output(["git", "-C", str(result), "show", ":new"]) == b"new"
    assert not (result / "vault").exists()
    assert not (result / "deleted").exists()
    assert subprocess.run(["git", "-C", str(result), "ls-files", "--error-unmatch", "deleted"],
                          capture_output=True).returncode == 1
    assert set(subprocess.check_output(["git", "-C", str(result), "diff", "--cached", "--name-status"]).splitlines()) == {
        b"M\ttracked", b"D\tdeleted", b"A\tnew"}
    assert (source / "vault").read_text() == "operator secret"
    assert subprocess.check_output(["git", "-C", str(result), "rev-parse", "HEAD"]) == subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"])
    assert subprocess.check_output(["git", "-C", str(result), "rev-parse", "--abbrev-ref", "HEAD"]).strip() != b"HEAD"
    if detached:
        assert subprocess.check_output(["git", "-C", str(source), "rev-parse", "--abbrev-ref", "HEAD"]).strip() == b"HEAD"
    assert subprocess.check_output(["git", "-C", str(result), "tag", "--list"]).strip() == b"fixture-baseline"


def test_snapshot_ignores_repository_git_environment(tmp_path, monkeypatch):
    source = tmp_path / "source"
    source.mkdir()
    def git(*args):
        return subprocess.run(["git", "-C", str(source), *args], check=True, capture_output=True)
    git("init", "-q")
    (source / "tracked").write_text("original")
    git("add", "tracked")
    git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
        "commit", "-qm", "fixture")
    (source / "tracked").write_text("dirty")
    source_tree = git("write-tree").stdout
    source_head = git("rev-parse", "HEAD").stdout
    source_diff = git("diff", "--cached").stdout
    monkeypatch.setenv("GIT_DIR", str(source / ".git"))
    monkeypatch.setenv("GIT_INDEX_FILE", str(source / ".git/index"))
    result = snapshot(source, tmp_path / "copy")
    assert subprocess.check_output(["git", "write-tree"]) == source_tree
    assert subprocess.check_output(["git", "rev-parse", "HEAD"]) == source_head
    assert subprocess.check_output(["git", "diff", "--cached"]) == source_diff
    monkeypatch.delenv("GIT_DIR")
    monkeypatch.delenv("GIT_INDEX_FILE")
    assert (result / ".git").resolve() != (source / ".git").resolve()
    assert subprocess.check_output(["git", "-C", str(result), "show", ":tracked"]) == b"dirty"

@pytest.fixture
def tiny_suite(tmp_path, source_root):
    # Copy only collection/report hooks; imports resolve to project helpers.
    (tmp_path / "conftest.py").write_text((source_root / "tests/conftest.py").read_text().replace(
        'ROOT = Path(__file__).resolve().parents[1]', f'ROOT = Path({str(source_root)!r})'))
    (tmp_path / "pytest.ini").write_bytes((source_root / "pytest.ini").read_bytes())
    (tmp_path / "test_fixture.py").write_text('''import pytest
@pytest.mark.quick
def test_quick(): pass
@pytest.mark.qemu
def test_qemu(): pass
''')
    return tmp_path, {**os.environ, "PYTHONPATH": str(source_root), "PYTEST_ADDOPTS": "",
                      "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1"}


@pytest.mark.parametrize("args,code,selected", [([], 0, "1 passed"), (["-m", "qemu"], 0, "1 passed"),
    (["-k", "absent"], 5, "2 deselected"), (["--unknown"], 4, "unrecognized arguments"),
    (["--collect-only"], 0, "2 tests collected"), (["test_fixture.py::test_quick"], 0, "1 passed")])
def test_pytest_selection(tiny_suite, args, code, selected):
    root, env = tiny_suite
    result = subprocess.run([sys.executable, "-m", "pytest", *args], cwd=root, env=env,
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == code
    assert selected in result.stdout + result.stderr
    assert not (root / "inventory").exists()


@pytest.mark.parametrize("phase", ["call", "setup", "explicit-fail", "command"])
def test_secret_absent_from_terminal_and_junit(tiny_suite, phase):
    root, env = tiny_suite
    (root / "test_fixture.py").write_text('''import pytest
@pytest.fixture
def fixture():
    PHASE_SETUP
@pytest.mark.quick
def test_secret(fixture):
    PHASE_CALL
'''.replace("PHASE_SETUP", "assert False, 'FAKE-PRIVATE-KEY-93847'" if phase == "setup" else "pass")
        .replace("PHASE_CALL", "pytest.fail('FAKE-PRIVATE-KEY-93847')" if phase == "explicit-fail"
                 else "assert False, 'FAKE-PRIVATE-KEY-93847'"))
    if phase == "command":
        (root / "test_fixture.py").write_text("import pytest\n@pytest.mark.quick\n"
            "def test_secret(command, tmp_path):\n"
            "    command(['bash', '-c', 'echo FAKE-PRIVATE-KEY-93847; exit 23'], cwd=tmp_path)\n")
    result = subprocess.run([sys.executable, "-m", "pytest", "--junitxml=report.xml", "--showlocals", "--tb=long"],
                            cwd=root, env=env, capture_output=True, text=True, timeout=20)
    assert result.returncode == 1
    assert "FAKE-PRIVATE-KEY-93847" not in result.stdout + result.stderr + (root / "report.xml").read_text()


@pytest.mark.parametrize("interrupt", [signal.SIGINT, signal.SIGTERM], ids=["ctrl-c", "sigterm"])
def test_interrupt_stops_owned_children(tiny_suite, interrupt):
    root, env = tiny_suite
    pidfile = root / "child.pid"
    (root / "test_fixture.py").write_text('''import sys
import pytest
from tests.support import run
@pytest.mark.quick
def test_wait(tmp_path):
    run([sys.executable, '-c', PROGRAM], cwd=tmp_path, log=tmp_path/'log', grace=0.2)
'''.replace("PROGRAM", repr("import os,time; from pathlib import Path; "
                            f"Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(300)")))
    child = subprocess.Popen([sys.executable, "-m", "pytest"], cwd=root, env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        deadline = time.monotonic() + 10
        while not pidfile.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert pidfile.exists()
        child.send_signal(interrupt)
        assert child.wait(timeout=10) == 2
        assert process_identity(int(pidfile.read_text())) is None
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()


@pytest.mark.parametrize("record_kind", ["record", "intent"])
def test_daemonized_vm_cleanup_after_state_removed(tmp_path, record_kind):
    # A process with a QEMU-shaped argv is sufficient to prove ownership checks;
    # real KVM behavior belongs to test_vm.
    executable = tmp_path / "qemu-system-fixture"
    executable.symlink_to(sys.executable)
    directory = tmp_path / "deleted-vm"
    directory.mkdir()
    child = subprocess.Popen([str(executable), "-c", "import time; time.sleep(300)",
                              f"file={directory}/disk.qcow2"], start_new_session=True)
    try:
        started = process_identity(child.pid)
        if record_kind == "record":
            (tmp_path / "vm.record").write_text(f"{child.pid}\n{started}\n{directory}\n")
        else:
            pidfile = tmp_path / "vm.pid"
            pidfile.write_text(str(child.pid))
            (tmp_path / "vm.intent").write_text(f"{pidfile}\n{started}\n{directory}\n")
        directory.rmdir()
        cleanup_vms(tmp_path, grace=1)
        assert child.wait(timeout=5) == -signal.SIGTERM
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()


def test_new_unregistered_contract_rejected(source_root, tmp_path):
    directory = tmp_path / "tests/validation"
    directory.mkdir(parents=True)
    for path in (source_root / "tests/validation").glob("*.sh"):
        (directory / path.name).touch()
    (directory / "forgotten.sh").touch()
    with pytest.raises(ValueError, match="registration"):
        validate_registry(tmp_path)


def test_setup_failure_cleans_private_files(tiny_suite):
    root, env = tiny_suite
    operator = root / "operator-vault"
    operator.write_text("operator input")
    (root / "test_fixture.py").write_text('''from pathlib import Path
import tempfile
import pytest
@pytest.fixture
def fixture():
    with tempfile.TemporaryDirectory(dir=ROOT, prefix='ephemeral') as path:
        Path(path, 'private-key').write_text('fake key')
        raise RuntimeError('setup fault')
        yield
@pytest.mark.quick
def test_setup(fixture): pass
'''.replace("ROOT", repr(str(root))))
    result = subprocess.run([sys.executable, "-m", "pytest"], cwd=root, env=env,
                            capture_output=True, timeout=20)
    assert result.returncode == 1
    assert not list(root.glob("ephemeral*"))
    assert operator.read_text() == "operator input"


@pytest.mark.parametrize("boundary", ["script-and-registration", "native-case", "ssh-matrix"])
def test_required_boundary_cannot_disappear(private_repo, boundary):
    contracts = CONTRACTS
    if boundary == "script-and-registration":
        (private_repo / CONTRACTS[0].argv[1]).unlink()
        contracts = CONTRACTS[1:]
    elif boundary == "ssh-matrix":
        path = private_repo / "tests/contracts/test_ssh_recovery.py"
        path.write_text(path.read_text().replace('"active", [False, True]', '"active", [False]'))
    else:
        path = private_repo / "tests/installer/test_ux.py"
        path.write_text(path.read_text().replace("def test_installer_eof(", "def removed_eof("))
    with pytest.raises(ValueError, match="required"):
        validate_registry(private_repo, contracts)


def test_stage_summary_does_not_forward_log(tmp_path):
    from tests.support import safe_stage
    log = tmp_path / "log"
    log.write_text("[E2E] Booting the VM FAKE-SECRET\nTASK [fixture restore FAKE-SECRET]\n")
    assert safe_stage(log) == "Ansible deployment"
    log.write_text("[PASS] case=activation-interrupt FAKE-SECRET\n[FAIL] restore drill failed FAKE-SECRET\n")
    assert safe_stage(log) == "restore drill failed"


def test_clean_vm_may_remove_pidfile(tmp_path):
    (tmp_path / "vm.intent").write_text(f"{tmp_path}/removed.pid\n0\n{tmp_path}/removed-state\n")
    cleanup_vms(tmp_path, grace=0.1)


def test_incomplete_cleanup_is_a_failure(tmp_path, monkeypatch):
    import tests.support as support
    def failed_cleanup(*args):
        raise CommandFailure("VM cleanup incomplete")
    monkeypatch.setattr(support, "cleanup_vms", failed_cleanup)
    with pytest.raises(CommandFailure, match="cleanup incomplete"):
        run(["true"], cwd=tmp_path, log=tmp_path / "log", registry=tmp_path)


@pytest.mark.parametrize("status", [0, 23], ids=["success", "installer-failure"])
def test_qemu_installer_preserves_status_in_conditional(source_root, tmp_path, status):
    source = (source_root / "tests/e2e/qemu-install.sh").read_text()
    start = source.index("run_repository_installer() {")
    function = source[start:source.index("\n}\n", start) + 3]
    fixture = tmp_path / "status.sh"
    fixture.write_text('''set -euo pipefail
TMP_DIR="$1"
E2E_SOURCE_MODE=development
INSTALL_REF=fixture
ADMIN_PASS=fixture ADGUARD_PASS=fixture WG_PASS=fixture PUBKEY=fixture
E2E_SSH_PORT=2222 E2E_WG_PORT=51820 WG_TRAFFIC_MODE=services
INTERNAL_DOMAIN_SUFFIX=internal WG_INTERNAL_DOMAIN=wg.internal ADGUARD_INTERNAL_DOMAIN=adguard.internal
build_installer_credential_env() { :; }
run_remote() { echo 'NON-PRODUCTION DEVELOPMENT MODE'; return STATUS; }
fail() { exit 97; }
'''.replace("STATUS", str(status)) + function + '''
if run_repository_installer fixture 22 fixture; then
    exit 0
else
    exit "$?"
fi
''')
    run(["bash", str(fixture), str(tmp_path)], cwd=tmp_path, log=tmp_path / "log", expected=status)


def test_lifecycle_provenance_is_allowlisted(tiny_suite):
    root, env = tiny_suite
    (root / "test_fixture.py").write_text('''import pytest
@pytest.mark.quick
def test_provenance(command, tmp_path):
    command(['bash', '-c', 'mkdir -p "$E2E_ARTIFACT_DIR"; printf "baseline_kind=bootstrap-snapshot\\\\npassword=FAKE-PROVENANCE-SECRET\\\\n" >"$E2E_ARTIFACT_DIR/source-provenance.txt"'], cwd=tmp_path)
''')
    result = subprocess.run([sys.executable, "-m", "pytest", "--junitxml=report.xml"], cwd=root, env=env,
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0
    report = (root / "report.xml").read_text()
    assert 'name="lifecycle_baseline_kind" value="bootstrap-snapshot"' in report
    assert "FAKE-PROVENANCE-SECRET" not in result.stdout + result.stderr + report


def test_vm_gate_flags_are_preserved():
    gates = {case.id: set(case.argv[2:]) for case in VMS}
    assert gates["qemu-services"] == {"--client-test", "--idempotency-test", "--reboot-test",
                                       "--bootstrap-timeout-test", "--stopped-container-test", "--invalid-caddy-test"}
    assert gates["remote-ssh"] == {"--ssh-rollback-test", "--ssh-cutover-test", "--reboot-test",
                                   "--ufw-backend-failure-test"}
    assert gates["lifecycle-upgrade-restore"] == set()


def test_short_runtime_state_supports_ssh_control_socket():
    import socket
    from tests.support import short_state
    with short_state() as state:
        assert state.stat().st_mode & 0o777 == 0o700
        directory = state / "ztvps-remote.123456"
        directory.mkdir()
        path = directory / ("rollback-control." + "x" * 16)
        with socket.socket(socket.AF_UNIX) as control:
            control.bind(str(path))
    assert not state.exists()


def test_timeout_kills_term_ignoring_descendant(tmp_path):
    pidfile = tmp_path / "stubborn.pid"
    child_code = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)"
    parent_code = ("import subprocess,time; from pathlib import Path; "
                   f"p=subprocess.Popen([{sys.executable!r},'-c',{child_code!r}]); "
                   f"Path({str(pidfile)!r}).write_text(str(p.pid)); time.sleep(300)")
    with pytest.raises(CommandFailure, match="timeout"):
        run([sys.executable, "-c", parent_code], cwd=tmp_path, log=tmp_path / "log", timeout=0.5, grace=0.2)
    assert process_identity(int(pidfile.read_text())) is None


def test_children_receive_cleanup_grace_after_parent_exits(tmp_path):
    marker = tmp_path / "cleaned"
    ready = tmp_path / "ready"
    child_code = f'''import signal, time
from pathlib import Path
def cleanup(signum, frame):
    time.sleep(0.15)
    Path({str(marker)!r}).write_text('cleaned')
    raise SystemExit(0)
signal.signal(signal.SIGTERM, cleanup)
Path({str(ready)!r}).touch()
while True:
    time.sleep(1)
'''
    parent_code = f'''import subprocess, time
from pathlib import Path
subprocess.Popen([{sys.executable!r}, '-c', {child_code!r}])
while not Path({str(ready)!r}).exists():
    time.sleep(0.01)
'''
    # Successful parent exit also requires orderly cleanup of its descendants.
    run([sys.executable, "-c", parent_code], cwd=tmp_path, log=tmp_path / "log", timeout=10, grace=2)
    assert marker.read_text() == "cleaned"
