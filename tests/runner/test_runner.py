"""Fault injection stays in tiny fixture suites, never recursively runs project checks."""
import os
from pathlib import Path
import select
import signal
import shutil
import subprocess
import sys
import time
from unittest.mock import Mock

import pytest

from tests.registry import CONTRACTS, VMS, validate_registry
from tests.support import CommandFailure, cleanup_vms, process_identity, run, snapshot
from tests.contracts.test_tools import tool_argv

pytestmark = pytest.mark.quick


def write_vm_record(path, text):
    from tests.qemu_owner import identity, write_private_json
    fields = text.splitlines()
    if path.suffix in (".record", ".intent") and len(fields) == 3:
        first, started, directory = fields
        directory = Path(directory)
        executable = path.parent / "qemu-system-fixture"
        if not executable.exists():
            executable = Path("/usr/bin/qemu-system-x86_64")
        value = {"schema": 1, "phase": "running" if path.suffix == ".record" else "launching",
                 "directory": str(directory), "disk": str(directory / "disk.qcow2"),
                 "executable": str(executable),
                 "identity": identity(directory) if directory.exists() else [0, 0, os.geteuid(), 0o700]}
        if path.suffix == ".record":
            value.update(pid=int(first), started=started, pidfile=str(directory / "qemu.pid"), earliest=0,
                         pidfile_parent_identity=value["identity"])
        else:
            value.update(pidfile=first, earliest=int(started), pidfile_parent_identity=identity(Path(first).parent))
        write_private_json(path, value)
    else:
        path.write_text(text)
        path.chmod(0o600)


@pytest.fixture
def vm_children(tmp_path):
    registry = tmp_path / "registry"
    registry.mkdir(mode=0o700)
    executable = registry / "qemu-system-fixture"
    shutil.copy2(sys.executable, executable)
    children = []

    def start(name):
        directory = registry / name
        directory.mkdir(mode=0o700)
        (directory / "disk.qcow2").write_bytes(b"owned fixture disk\n")
        child = subprocess.Popen([str(executable), "-u", "-c",
                                  "import time; print('ready', flush=True); time.sleep(300)",
                                  "-drive", f"file={directory}/disk.qcow2,if=virtio,format=qcow2"],
                                 stdout=subprocess.PIPE, start_new_session=True)
        children.append(child)
        assert select.select([child.stdout], [], [], 5)[0], "fixture child readiness timeout"
        assert child.stdout.readline() == b"ready\n"
        write_vm_record(directory / "qemu.pid", str(child.pid))
        record_path = registry / f"{name}.record"
        write_vm_record(record_path, f"{child.pid}\n{process_identity(child.pid)}\n{directory}\n")
        return directory, child, record_path

    try:
        yield registry, start
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()  # Only our own live, unreaped Popen children.
            child.wait(timeout=5)
            child.stdout.close()


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
                                           ("--release", ["quick", "qemu", "extension", "lifecycle", "release and not quick"])])
def test_wrapper_selection(wrapper, option, stages):
    import ast
    entry, env = wrapper
    result = subprocess.run(["bash", str(entry)] + ([option] if option else []), env=env,
                            input=b"unconsumed operator stdin", capture_output=True, timeout=10)
    assert result.returncode == 0
    calls = [ast.literal_eval(line) for line in Path(env["CALL_LOG"]).read_text().splitlines()]
    assert calls == [["-x", "-m", stage] for stage in stages]


@pytest.mark.parametrize("stage", ["quick", "qemu", "extension", "lifecycle", "release and not quick"])
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


@pytest.mark.parametrize("mutation", ["missing", "duplicate", "renamed", "vm", "extension-missing",
                                     "extension-in-core", "extension-core-marker", "extension-disabled"])
def test_registry_rejects_loss(source_root, mutation):
    from dataclasses import replace
    contracts, vms = CONTRACTS, VMS
    if mutation == "missing":
        contracts = contracts[1:]
    elif mutation == "duplicate":
        contracts = (*contracts, contracts[0])
    elif mutation == "renamed":
        contracts = (replace(contracts[0], argv=("bash", "tests/validation/renamed.sh")), *contracts[1:])
    elif mutation == "extension-missing":
        vms = tuple(case for case in vms if case.id != "extension-vaultwarden")
    elif mutation == "extension-in-core":
        vms = tuple(replace(case, argv=(*case.argv, "--vaultwarden-test")) if case.id == "qemu-services" else case
                    for case in vms)
    elif mutation == "extension-core-marker":
        vms = tuple(replace(case, marks=("qemu",)) if case.id == "extension-vaultwarden" else case for case in vms)
    elif mutation == "extension-disabled":
        vms = tuple(replace(case, argv=tuple(arg for arg in case.argv if arg != "--vaultwarden-test"))
                    if case.id == "extension-vaultwarden" else case for case in vms)
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
    started = int(process_identity(os.getpid())) + 1
    write_vm_record(tmp_path / "test.record", f"{os.getpid()}\n{started}\n{tmp_path}\n")
    with pytest.raises(CommandFailure, match="start time"):
        cleanup_vms(tmp_path, grace=0.1)


@pytest.mark.parametrize("stale_first", [True, False], ids=["stale-first", "stale-last"])
def test_vm_cleanup_continues_after_stale_record(vm_children, monkeypatch, stale_first):
    from tests.qemu_owner import private_json, write_private_json

    registry, start = vm_children
    _, stale, stale_record = start("stale")
    valid = [start("valid-one"), start("valid-two")]
    value = private_json(stale_record)
    value["started"] = str(int(value["started"]) + 1)
    write_private_json(stale_record, value)
    paths = [stale_record, *(record for _, _, record in valid)]
    if not stale_first:
        paths.reverse()
    original_glob = Path.glob

    def ordered_glob(path, pattern):
        if path == registry and pattern == "*.record":
            return iter(paths)
        return original_glob(path, pattern)

    monkeypatch.setattr(Path, "glob", ordered_glob)
    with pytest.raises(CommandFailure, match="start time") as failure:
        cleanup_vms(registry, grace=0.1)
    assert failure.value.__cause__ is not None
    assert stale.poll() is None
    for directory, child, record in valid:
        assert child.wait(timeout=5) == -signal.SIGTERM
        assert directory.exists() and record.exists()
    assert stale_record.exists()


@pytest.mark.parametrize("kind", ["record", "intent"])
@pytest.mark.parametrize("malformed", ["truncated", "null-directory"])
def test_vm_cleanup_continues_after_invalid_entry(vm_children, kind, malformed):
    from tests.qemu_owner import private_json, write_private_json

    registry, start = vm_children
    directory, child, record = start("valid")
    bad_path = registry / f"invalid.{kind}"
    if malformed == "truncated":
        write_vm_record(bad_path, '{"schema":')
    else:
        value = private_json(record)
        if kind == "intent":
            value["phase"] = "launching"
            del value["pid"]
            del value["started"]
        value["directory"] = None
        write_private_json(bad_path, value)
    before = bad_path.read_bytes()
    with pytest.raises(CommandFailure, match="VM ownership cleanup incomplete"):
        cleanup_vms(registry, grace=0.1)
    assert child.wait(timeout=5) == -signal.SIGTERM
    assert bad_path.read_bytes() == before
    assert directory.exists() and record.exists()


def test_vm_cleanup_rejects_unsafe_registry_before_signals(vm_children):
    registry, start = vm_children
    children = [start("one")[1], start("two")[1]]
    registry.chmod(0o755)
    try:
        with pytest.raises(CommandFailure, match="private real directory"):
            cleanup_vms(registry, grace=0.1)
        assert all(child.poll() is None for child in children)
    finally:
        registry.chmod(0o700)


def test_vm_cleanup_lists_registry_before_reading_entries(vm_children, monkeypatch):
    registry, start = vm_children
    _, child, _ = start("valid")
    original_glob = Path.glob

    def failed_intents(path, pattern):
        if path == registry and pattern == "*.intent":
            raise OSError("fixture registry listing failure")
        return original_glob(path, pattern)

    def unexpected_read(*args):
        pytest.fail("entry read before all root registry checks completed")

    monkeypatch.setattr(Path, "glob", failed_intents)
    monkeypatch.setattr("tests.support.private_json", unexpected_read)
    with pytest.raises(CommandFailure, match="registry listing failure"):
        cleanup_vms(registry, grace=0.1)
    assert child.poll() is None


def test_vm_wrong_ownership_rejected(tmp_path):
    write_vm_record(tmp_path / "test.record", f"{os.getpid()}\n{process_identity(os.getpid())}\n{tmp_path}\n")
    with pytest.raises(CommandFailure, match="ownership"):
        cleanup_vms(tmp_path, grace=0.1)


@pytest.mark.parametrize("record", ["", "partial\n", "partial\nrecord\n"],
                         ids=["empty", "one-line", "two-line"])
def test_incomplete_vm_record_uses_valid_intent(vm_children, record):
    registry, start = vm_children
    directory, child, record_path = start("recover")
    _, other, _ = start("other")
    intent = registry / "recover.intent"
    write_vm_record(intent, f"{directory / 'qemu.pid'}\n{process_identity(child.pid)}\n{directory}\n")
    write_vm_record(record_path, record)
    cleanup_vms(registry, grace=0.1)
    assert child.wait(timeout=5) == -signal.SIGTERM
    assert other.wait(timeout=5) == -signal.SIGTERM
    assert record_path.exists() and intent.exists()


@pytest.mark.parametrize("race_stage", ["cmdline", "sigterm"])
def test_vm_exit_race_during_cleanup(tmp_path, monkeypatch, race_stage):
    import tests.qemu_owner as owner

    executable = tmp_path / "qemu-system-fixture"
    shutil.copy2(sys.executable, executable)
    directory = tmp_path / "vm"
    directory.mkdir()
    child = subprocess.Popen([str(executable), "-c", "import time; time.sleep(300)",
                              "-drive", f"file={directory}/disk.qcow2"], start_new_session=True)
    try:
        started = process_identity(child.pid)
        write_vm_record(tmp_path / "vm.record", f"{child.pid}\n{started}\n{directory}\n")
        if race_stage == "cmdline":
            original_snapshot = owner.snapshot
            checked = False

            def snapshot_after_exit(pid):
                nonlocal checked
                value = original_snapshot(pid)
                if pid == child.pid and value is not None and not checked:
                    checked = True
                    child.terminate()
                    child.wait(timeout=5)
                return value

            monkeypatch.setattr(owner, "snapshot", snapshot_after_exit)
        else:
            original_signal = owner.signal.pidfd_send_signal

            def signal_after_exit(descriptor, sig):
                original_signal(descriptor, sig)
                child.wait(timeout=5)
                raise ProcessLookupError

            monkeypatch.setattr(owner.signal, "pidfd_send_signal", signal_after_exit)
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


@pytest.mark.parametrize("tracked", [False, True])
def test_snapshot_preserves_guidance_alias(tmp_path, tracked):
    source = tmp_path / "source"
    source.mkdir()
    def git(*args):
        return subprocess.check_output(["git", "-C", str(source), *args])
    git("init", "-q")
    (source / "AGENTS.md").write_bytes(b"# Shared guidance\n")
    if tracked:
        (source / "CLAUDE.md").symlink_to("AGENTS.md")
    git("add", ".")
    git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
        "commit", "-qm", "fixture")
    if not tracked:
        (source / "CLAUDE.md").symlink_to("AGENTS.md")
    result = snapshot(source, tmp_path / "copy")
    alias = result / "CLAUDE.md"
    assert alias.is_symlink()
    assert os.readlink(alias) == "AGENTS.md"
    assert alias.resolve(strict=True) == result / "AGENTS.md"
    assert alias.read_bytes() == (source / "AGENTS.md").read_bytes()
    assert subprocess.check_output(["git", "-C", str(result), "ls-files", "--stage", "--", "CLAUDE.md"]).startswith(b"120000 ")
    assert subprocess.check_output(["git", "-C", str(result), "show", ":CLAUDE.md"]) == b"AGENTS.md"


@pytest.mark.parametrize("case", ["wrong", "absolute", "escaping", "noncanonical", "other", "missing",
                                 "symlinked-canonical", "ignored-canonical"])
def test_snapshot_rejects_unsafe_guidance_alias(tmp_path, case):
    source = tmp_path / "source"
    source.mkdir()
    def git(*args):
        subprocess.run(["git", "-C", str(source), *args], check=True, capture_output=True)
    git("init", "-q")
    (source / "README.md").write_text("ordinary sentinel\n")
    git("add", ".")
    git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
        "commit", "-qm", "fixture")
    canonical = source / "AGENTS.md"
    if case == "symlinked-canonical":
        canonical.symlink_to("README.md")
    elif case != "missing":
        canonical.write_text("shared guidance\n")
    if case == "ignored-canonical":
        (source / ".gitignore").write_text("/AGENTS.md\n")
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "AGENTS.md").write_text("external sentinel\n")
    target = {"wrong": "README.md", "absolute": str(canonical), "escaping": "../outside/AGENTS.md",
              "noncanonical": "./AGENTS.md"}.get(case, "AGENTS.md")
    (source / ("OTHER.md" if case == "other" else "CLAUDE.md")).symlink_to(target)
    with pytest.raises(CommandFailure, match="^source snapshot refuses symlinks outside regular source files$"):
        snapshot(source, tmp_path / "copy")


@pytest.mark.parametrize("case", ["missing", "regular", "wrong", "absolute", "escaping", "self-loop"])
def test_ssot_rejects_invalid_guidance_alias(private_repo, tmp_path, case):
    alias = private_repo / "CLAUDE.md"
    assert alias.is_symlink() and os.readlink(alias) == "AGENTS.md"
    alias.unlink()
    sentinel = "PRIVATE_ALIAS_TARGET_SENTINEL"
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "AGENTS.md").write_text(sentinel)
    if case == "regular":
        alias.write_text(sentinel)
    elif case != "missing":
        target = {"wrong": "README.md", "absolute": str(private_repo / "AGENTS.md"),
                  "escaping": "../outside/AGENTS.md", "self-loop": "CLAUDE.md"}[case]
        alias.symlink_to(target)
    env = {key: value for key, value in os.environ.items() if key != "VERIFY_SSOT_README_PATH"}
    try:
        result = subprocess.run(["bash", "scripts/verify-ssot.sh"], cwd=private_repo, env=env,
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        assert result.returncode == 1
        assert result.stderr == b"[FAIL] CLAUDE.md must be a relative symlink to the regular repository-root AGENTS.md\n"
        assert sentinel.encode() not in result.stdout + result.stderr
        assert b"Traceback" not in result.stdout + result.stderr
    finally:
        if alias.exists() or alias.is_symlink():
            alias.unlink()
        alias.symlink_to("AGENTS.md")


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
    shutil.copy2(sys.executable, executable)
    directory = tmp_path / "deleted-vm"
    directory.mkdir()
    child = subprocess.Popen([str(executable), "-c", "import time; time.sleep(300)",
                              "-drive", f"file={directory}/disk.qcow2"], start_new_session=True)
    try:
        started = process_identity(child.pid)
        if record_kind == "record":
            write_vm_record(tmp_path / "vm.record", f"{child.pid}\n{started}\n{directory}\n")
        else:
            pidfile = tmp_path / "vm.pid"
            write_vm_record(pidfile, str(child.pid))
            write_vm_record(tmp_path / "vm.intent", f"{pidfile}\n{started}\n{directory}\n")
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
    directory = tmp_path / "removed-state"
    write_vm_record(tmp_path / "vm.intent", f"{tmp_path}/removed.pid\n0\n{directory}\n")
    write_vm_record(tmp_path / "vm.record", f"1073741824\n1\n{directory}\n")
    cleanup_vms(tmp_path, grace=0.1)


def test_unrecorded_startup_missing_pidfile_is_incomplete(tmp_path):
    write_vm_record(tmp_path / "vm.intent", f"{tmp_path}/missing.pid\n0\n{tmp_path}/state\n")
    with pytest.raises(CommandFailure, match="possible orphan"):
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
    common = (source_root / "tests/e2e/common.sh").read_text()
    vpn_start = common.index("vpn_executable() {\n")
    vpn_function = common[vpn_start:common.index("\n}\n", vpn_start) + 3]
    source = (source_root / "tests/e2e/qemu-install.sh").read_text()
    start = source.index("run_repository_installer() {")
    function = source[start:source.index("\n}\n", start) + 3]
    fixture = tmp_path / "status.sh"
    fixture.write_text('''set -euo pipefail
TMP_DIR="$1"
NOOK_VPN_BACKEND=wg
E2E_SOURCE_MODE=development
INSTALL_REF=fixture
ADMIN_PASS=fixture ADGUARD_PASS=fixture WG_PASS=fixture PUBKEY=fixture
E2E_SSH_PORT=2222 E2E_WG_PORT=51820 WG_TRAFFIC_MODE=services
INTERNAL_DOMAIN_SUFFIX=internal WG_INTERNAL_DOMAIN=wg.internal ADGUARD_INTERNAL_DOMAIN=adguard.internal
build_installer_credential_env() { :; }
run_remote() { echo 'NON-PRODUCTION DEVELOPMENT MODE'; return STATUS; }
fail() { exit 97; }
'''.replace("STATUS", str(status)) + vpn_function + function + '''
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


@pytest.fixture
def vpn_dispatch(monkeypatch, tmp_path):
    import tests.e2e.test_vm as vm

    monkeypatch.setattr(vm.shutil, "which", Mock(return_value="/fixture/tool"))
    monkeypatch.setattr(vm.os, "access", Mock(return_value=True))
    return vm, Mock(), tmp_path


@pytest.mark.parametrize("selection", [
    (backend, traffic, expected)
    for backend in ("wg", "awg")
    for traffic, expected in ((None, "services"), ("", "services"), ("services", "services"), ("full", "full"))
])
def test_vpn_dispatch_preserves_services_selection(vpn_dispatch, monkeypatch, selection):
    # Given a selected backend and an independent routing choice.
    vm, command, root = vpn_dispatch
    backend, traffic, expected = selection
    monkeypatch.setenv("NOOK_VPN_BACKEND", backend)
    if traffic is None:
        monkeypatch.delenv("NOOK_WG_TRAFFIC_MODE", raising=False)
    else:
        monkeypatch.setenv("NOOK_WG_TRAFFIC_MODE", traffic)
    case = next(case for case in VMS if case.id == "qemu-services")

    # When the actual pytest VM owner dispatches the registered case.
    vm.test_vm(case, root, command)

    # Then the real harness receives the requested backend and routing.
    command.assert_called_once_with(case.argv, cwd=root, timeout=case.timeout,
                                    env={"NOOK_WG_TRAFFIC_MODE": expected, "NOOK_VPN_BACKEND": backend})


@pytest.mark.parametrize("backend", [None, ""])
def test_vpn_dispatch_defaults_backend(vpn_dispatch, monkeypatch, backend):
    vm, command, root = vpn_dispatch
    monkeypatch.delenv("NOOK_WG_TRAFFIC_MODE", raising=False)
    if backend is None:
        monkeypatch.delenv("NOOK_VPN_BACKEND", raising=False)
    else:
        monkeypatch.setenv("NOOK_VPN_BACKEND", backend)
    case = next(case for case in VMS if case.id == "qemu-services")

    vm.test_vm(case, root, command)

    assert command.call_args.kwargs["env"] == {"NOOK_WG_TRAFFIC_MODE": "services", "NOOK_VPN_BACKEND": "wg"}


@pytest.mark.parametrize("traffic", ["bogus", "full; exit 0"])
def test_vpn_dispatch_rejects_invalid_before_preparation(vpn_dispatch, monkeypatch, traffic):
    vm, command, root = vpn_dispatch
    monkeypatch.setenv("NOOK_WG_TRAFFIC_MODE", traffic)
    vm.shutil.which.reset_mock()
    vm.os.access.reset_mock()
    case = next(case for case in VMS if case.id == "qemu-services")

    with pytest.raises(CommandFailure):
        vm.test_vm(case, root, command)

    command.assert_not_called()
    vm.shutil.which.assert_not_called()
    vm.os.access.assert_not_called()


@pytest.mark.parametrize("case", [case for case in VMS if case.id != "qemu-services" and not case.env], ids=lambda case: case.id)
def test_vpn_dispatch_other_vm_defaults_unchanged(vpn_dispatch, monkeypatch, case):
    vm, command, root = vpn_dispatch
    monkeypatch.setenv("NOOK_WG_TRAFFIC_MODE", "full")
    monkeypatch.setenv("NOOK_VPN_BACKEND", "awg")

    vm.test_vm(case, root, command)

    command.assert_called_once_with(case.argv, cwd=root, timeout=case.timeout, env={"NOOK_WG_TRAFFIC_MODE": "services"})


def test_vpn_dispatch_propagates_harness_failure(vpn_dispatch, monkeypatch):
    vm, command, root = vpn_dispatch
    monkeypatch.setenv("NOOK_WG_TRAFFIC_MODE", "full")
    failure = CommandFailure("fixture harness exit 23")
    command.side_effect = failure
    case = next(case for case in VMS if case.id == "qemu-services")

    with pytest.raises(CommandFailure) as caught:
        vm.test_vm(case, root, command)

    assert caught.value is failure


def test_vpn_dispatch_missing_prerequisite_fails(vpn_dispatch, monkeypatch):
    vm, command, root = vpn_dispatch
    monkeypatch.setenv("NOOK_WG_TRAFFIC_MODE", "services")
    vm.shutil.which.return_value = None
    case = next(case for case in VMS if case.id == "qemu-services")

    with pytest.raises(CommandFailure):
        vm.test_vm(case, root, command)

    command.assert_not_called()


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


def test_qemu_shell_traps_use_shared_owned_cleanup():
    scripts = (
        Path("tests/e2e/qemu-install.sh"),
        Path("tests/e2e/qemu-remote-install.sh"),
        Path("tests/e2e/lifecycle-qemu.sh"),
        Path("tests/e2e/external-client-qemu.sh"),
    )
    for path in scripts:
        source = path.read_text(encoding="utf-8")
        start = source.find("cleanup() {")
        end = source.find("trap cleanup EXIT", start)
        assert start >= 0 and end > start, f"{path} cleanup trap not found"
        body = source[start:end]
        assert "cleanup_owned_qemu" in body, f"{path} must delegate VM shutdown to the shared owner"
        assert not any(
            "kill" in line and "QEMU_PID" in line
            for line in body.splitlines()
        ), f"{path} must not signal QEMU using a bare pidfile PID"
        cleanup_call = body.index("cleanup_owned_qemu")
        for line in body.splitlines():
            if "rm -rf" in line and "TMP_DIR" in line:
                assert body.index(line) > cleanup_call, f"{path} removes VM state before owned shutdown"

    common = Path("tests/e2e/common.sh").read_text(encoding="utf-8")
    assert "cleanup_owned_qemu()" in common, "shared PIDFD cleanup owner missing"
    owner = Path("tests/qemu_owner.py").read_text(encoding="utf-8")
    assert "pidfd_open" in owner and "pidfd_send_signal" in owner, "shared cleanup must pin PID identity"
    assert "os.kill(" not in owner, "shared owner must not fall back to numeric PID signals"
    assert "QEMU_START_TICKS" in common and "disk.qcow2" in common, "shared cleanup must verify start and disk identity"


@pytest.mark.parametrize("state", ["failed", "pending", "missing", "malformed"])
def test_short_state_preserves_private_root_when_cleanup_status_incomplete(tmp_path, state):
    import tests.support as support
    from tests.qemu_owner import identity
    registry = tmp_path / "process-registry"
    registry.mkdir(mode=0o700)
    retained = None
    original = None
    try:
        with support.short_state(registry) as retained:
            original = identity(retained)
            owner = support._SCRATCH_OWNERS[str(registry)]
            owner.begin()
            if state == "failed":
                owner.finish(False)
            elif state == "missing":
                owner.status.unlink()
            elif state == "malformed":
                owner.status.write_text("complete\n")
        assert retained.is_dir(), "scratch was deleted without complete process cleanup"
    finally:
        if retained is not None and retained.is_dir():
            assert retained.parent == Path("/tmp") and retained.name.startswith("nook-")
            assert identity(retained) == original
            retained.rmdir()  # exact verified empty test-owned root; no VM/files


def test_short_state_complete_registry_removes_root(tmp_path):
    import tests.support as support
    registry = tmp_path / "process-registry"
    registry.mkdir(mode=0o700)
    with support.short_state(registry) as directory:
        owner = support._SCRATCH_OWNERS[str(registry)]
        owner.begin()
        owner.finish(True)
    assert not directory.exists(), "verified complete scratch was not reclaimed"


def test_short_state_pending_writer_failure_cannot_use_stale_complete(tmp_path, monkeypatch):
    import tests.support as support
    from tests.qemu_owner import identity
    registry = tmp_path / "process-registry"
    registry.mkdir(mode=0o700)
    retained = None
    original = None
    try:
        with support.short_state(registry) as retained:
            original = identity(retained)
            previous = (registry / "cleanup.status").read_bytes()
            def failed_writer(*args):
                raise OSError("injected record write failure")
            with monkeypatch.context() as patch:
                patch.setattr(support, "write_private_json", failed_writer)
                patch.setattr(support.subprocess, "Popen", lambda *args, **kwargs: pytest.fail("launch before pending publication"))
                with pytest.raises(CommandFailure, match="safely"):
                    support.run(["true"], cwd=tmp_path, log=tmp_path / "log", registry=registry)
            assert (registry / "cleanup.status").read_bytes() == previous
        assert retained.is_dir(), "stale complete authorized deletion after failed pending write"
    finally:
        if retained is not None and retained.is_dir():
            assert retained.parent == Path("/tmp") and retained.name.startswith("nook-")
            assert identity(retained) == original
            retained.rmdir()


@pytest.mark.parametrize("failure", ["group", "vm", "final-status"])
def test_scratch_cleanup_failure_preserves_root_and_denies_next_launch(tmp_path, monkeypatch, failure):
    import tests.support as support
    from tests.qemu_owner import identity
    registry = tmp_path / "process-registry"
    registry.mkdir(mode=0o700)
    retained = None
    original = None
    called = []
    try:
        with support.short_state(registry) as retained:
            original = identity(retained)
            original_writer = support.write_private_json
            def group_cleanup(*args):
                called.append("group")
                if failure == "group":
                    raise CommandFailure("injected group cleanup incomplete")
            def vm_cleanup(*args):
                called.append("vm")
                if failure == "vm":
                    raise CommandFailure("injected VM cleanup incomplete")
            def write_status(path, value):
                if failure == "final-status" and value["state"] == "complete" and value["generation"] > 0:
                    raise OSError("injected final status write failure")
                return original_writer(path, value)
            with monkeypatch.context() as patch:
                patch.setattr(support, "stop_group", group_cleanup)
                patch.setattr(support, "cleanup_vms", vm_cleanup)
                patch.setattr(support, "write_private_json", write_status)
                with pytest.raises((CommandFailure, OSError)):
                    support.run(["true"], cwd=tmp_path, log=tmp_path / "log", registry=registry)
                assert called == ["group", "vm"], "both cleanup owners must run"
                patch.setattr(support.subprocess, "Popen", lambda *args, **kwargs: pytest.fail("unconfirmed prior cleanup launched"))
                with pytest.raises(CommandFailure):
                    support.run(["true"], cwd=tmp_path, log=tmp_path / "second-log", registry=registry)
        assert retained.is_dir()
    finally:
        if retained is not None and retained.is_dir():
            assert retained.parent == Path("/tmp") and retained.name.startswith("nook-")
            assert identity(retained) == original
            retained.rmdir()


def test_scratch_removal_failure_does_not_mask_primary(tmp_path, monkeypatch):
    import tests.support as support
    from tests.qemu_owner import identity
    retained = None
    original = None
    try:
        def failed_remove(*args):
            raise OSError("injected removal failure")
        with monkeypatch.context() as patch:
            patch.setattr(support.shutil, "rmtree", failed_remove)
            with pytest.raises(ValueError, match="primary sentinel"):
                with support.short_state() as retained:
                    original = identity(retained)
                    raise ValueError("primary sentinel")
        assert retained.is_dir()
    finally:
        if retained is not None and retained.is_dir():
            assert retained.parent == Path("/tmp") and retained.name.startswith("nook-")
            assert identity(retained) == original
            retained.rmdir()
