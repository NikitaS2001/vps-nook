"""Collection is read-only; all preparation happens in execution fixtures."""
import os
import signal
import shutil
from contextlib import nullcontext
from pathlib import Path
import tempfile

import pytest

from tests.registry import validate_registry
from tests.support import CommandFailure, prepare_examples, run, short_state, snapshot

ROOT = Path(__file__).resolve().parents[1]


def pytest_configure(config):
    if not config.option.markexpr and not config.option.collectonly:
        config.option.markexpr = "quick"
    if getattr(config.option, "numprocesses", None):
        raise pytest.UsageError("VPS Nook tests require sequential execution")
    try:
        validate_registry(ROOT)
    except ValueError as error:
        raise pytest.UsageError(str(error)) from None


def pytest_sessionstart(session):
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    session.config._nook_term_handler = signal.signal(signal.SIGTERM, interrupted)


def pytest_sessionfinish(session, exitstatus):
    signal.signal(signal.SIGTERM, session.config._nook_term_handler)



@pytest.fixture(autouse=True)
def remove_private_test_state(tmp_path):
    # pytest normally retains failed tmp_path directories, including fixture keys.
    # This suite keeps only the separate private diagnostics directory.
    yield
    shutil.rmtree(tmp_path)
    if tmp_path.exists():
        pytest.fail("private test state cleanup incomplete", pytrace=False)



@pytest.fixture(scope="session")
def source_root():
    return ROOT


@pytest.fixture
def private_repo(source_root, tmp_path):
    return snapshot(source_root, tmp_path / "repo")


@pytest.fixture
def deployment_repo(private_repo):
    prepare_examples(private_repo)
    return private_repo


@pytest.fixture(scope="session")
def log_dir(request):
    # Survive fixture cleanup for local diagnosis; CI uploads only JUnit summaries.
    path = Path(tempfile.mkdtemp(prefix="nook-pytest-logs."))
    path.chmod(0o700)
    request.config._nook_log_dir = path
    return path


@pytest.fixture
def command(request, log_dir, tmp_path):
    registry = tmp_path / "process-registry"
    registry.mkdir(mode=0o700)
    with short_state() as temporary:
        counter = 0

        def execute(argv, *, cwd, timeout=900, env=None, expected=0):
            nonlocal counter
            counter += 1
            identifier = request.node.name.replace("/", "_")
            reporter = request.config.pluginmanager.get_plugin("terminalreporter")
            def heartbeat(message):
                if reporter:
                    capture = request.config.pluginmanager.get_plugin("capturemanager")
                    with capture.global_and_fixture_disabled() if capture else nullcontext():
                        reporter.write_line(message)
                        reporter.flush()
            if counter == 1:
                heartbeat(f"{identifier}: starting")
            environment = {"TMPDIR": str(temporary), "E2E_PROCESS_REGISTRY": str(registry),
                           "QEMU_STATE_DIR": "", "E2E_KEEP_STATE_ON_FAILURE": "0", "E2E_ARTIFACT_DIR": str(temporary / "evidence")}
            environment.update(env or {})
            result = run(argv, cwd=cwd, timeout=timeout, env=environment, expected=expected,
                       log=log_dir / f"{identifier}-{counter}.log", case_id=identifier,
                       heartbeat=heartbeat, registry=registry)
            provenance = temporary / "evidence/source-provenance.txt"
            if provenance.is_file():
                kinds = {"baseline_kind=release": "release", "baseline_kind=bootstrap-snapshot": "bootstrap-snapshot"}
                for line in provenance.read_text().splitlines():
                    if line in kinds:
                        kind = kinds[line]
                        request.node.user_properties.append(("lifecycle_baseline_kind", kind))
                        heartbeat(f"{identifier}: lifecycle baseline kind: {kind}")
            return result
        yield execute


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    # Keep rich failure evidence private; never publish assertion operands,
    # traceback source lines, argv, environment or captured fixture output.
    if report.failed:
        directory = getattr(item.config, "_nook_log_dir", None)
        if directory is None:
            directory = Path(tempfile.mkdtemp(prefix="nook-pytest-logs."))
            item.config._nook_log_dir = directory
        details = directory / (item.name.replace("/", "_") + "." + report.when + ".log")
        with details.open("w") as stream:
            os.chmod(details, 0o600)
            stream.write(str(report.longrepr))
            for _, output in report.sections:
                stream.write("\n" + output)
        if call.excinfo and isinstance(call.excinfo.value, CommandFailure):
            report.longrepr = str(call.excinfo.value)
        else:
            kind = call.excinfo.typename if call.excinfo else "failure"
            report.longrepr = f"{item.nodeid}: {kind} in {report.when}; private log: {details}"
    report.sections = []
