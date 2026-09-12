"""Private source snapshots and bounded subprocess execution (Linux, sequential)."""
from contextlib import contextmanager
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import tempfile


class CommandFailure(RuntimeError):
    """Only safe metadata belongs in this exception, never command output or argv."""


@contextmanager
def short_state():
    # OpenSSH adds a random suffix to ControlPath; Linux sun_path is 108 bytes.
    # Keep runtime state short even when pytest basetemp/TMPDIR is deeply nested.
    with tempfile.TemporaryDirectory(prefix="nook-", dir="/tmp") as directory:
        yield Path(directory)


def snapshot(source, destination):
    destination.mkdir(mode=0o700)
    # A local clone owns its Git metadata and objects, retaining history and tags.
    # Never copy operator Git configuration, hooks, ignored inventory or vault files.
    subprocess.run(["git", "clone", "--quiet", "--no-hardlinks", "--no-checkout", str(source), str(destination)],
                   check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    branch = subprocess.run(["git", "-C", str(destination), "symbolic-ref", "-q", "HEAD"],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=30)
    if branch.returncode == 1:
        # PR merge checkouts may have no branch at HEAD. The Bash fixture uses
        # a branch name when constructing its guest-local development origin.
        for arguments in (("branch", "nook-pytest-source", "HEAD"),
                          ("symbolic-ref", "HEAD", "refs/heads/nook-pytest-source")):
            subprocess.run(["git", "-C", str(destination), *arguments], check=True,
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=30)
    elif branch.returncode:
        raise CommandFailure("could not inspect private Git snapshot HEAD")
    paths = subprocess.check_output(["git", "-C", str(source), "ls-files", "-z", "--cached", "--others",
                                     "--exclude-standard"], stdin=subprocess.DEVNULL, timeout=30).split(b"\0")
    for raw in set(paths) - {b""}:
        relative = Path(os.fsdecode(raw))
        src, dst = source / relative, destination / relative
        if not src.exists() and not src.is_symlink():
            continue
        # Reject symlink traversal rather than copying external operator material.
        if src.is_symlink() or source.resolve() not in src.resolve().parents:
            raise CommandFailure("source snapshot refuses symlinks outside regular source files")
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    # Populate the index without replacing dirty/deleted worktree files.
    subprocess.run(["git", "-C", str(destination), "reset", "--mixed", "--quiet", "HEAD"],
                   check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    return destination


def prepare_examples(root):
    for relative in ("inventory/hosts.yml", "group_vars/all/vars.yml",
                     "group_vars/all/vault_services.yml", "group_vars/all/vault_ssh.yml"):
        path = root / relative
        # Exclusive creation: even a test fixture must not overwrite existing state.
        with path.open("xb") as stream:
            os.chmod(path, 0o600)
            stream.write(path.with_suffix(path.suffix + ".example").read_bytes())


def process_identity(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] == "Z":
            return None
        return fields[19]
    except (FileNotFoundError, ProcessLookupError):
        return None


def cleanup_vms(registry, grace=30):
    """Never signal a recycled PID; verify start time AND VM disk in QEMU argv."""
    owned = []
    records = []
    for intent in registry.glob("*.intent"):
        pidfile, earliest, directory = intent.read_text().splitlines()
        try:
            value = Path(pidfile).read_text().strip()
        except FileNotFoundError:
            # QEMU normally removes its pidfile on graceful exit.
            continue
        if not value:
            continue
        pid = int(value)
        started = process_identity(pid)
        if started is not None and int(started) >= int(earliest):
            records.append((value, started, directory))
    for record in registry.glob("*.record"):
        records.append(tuple(record.read_text().splitlines()))
    for pid_text, started, directory in set(records):
        pid = int(pid_text)
        if process_identity(pid) != started:
            continue
        command = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        if not command or b"qemu-system-" not in command[0] or not any(
            os.fsencode(str(Path(directory) / "disk.qcow2")) in arg for arg in command
        ):
            raise CommandFailure("VM ownership verification failed")
        owned.append((pid, started))
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + grace
    while owned and time.monotonic() < deadline:
        owned = [(pid, start) for pid, start in owned if process_identity(pid) == start]
        if owned:
            time.sleep(0.1)
    for pid, start in owned:
        if process_identity(pid) == start:
            os.kill(pid, signal.SIGKILL)
    if owned:
        time.sleep(0.1)
    if any(process_identity(pid) == start for pid, start in owned):
        raise CommandFailure("VM cleanup incomplete")


def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        if fields[0] != "Z" and int(fields[2]) == pgid:
            return True
    return False


def stop_group(process, grace=30):
    deadline = time.monotonic() + grace
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=max(0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        pass
    # Children may still be cleaning up after their parent has returned.
    while group_alive(process.pid) and time.monotonic() < deadline:
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)
    deadline = time.monotonic() + 5
    while group_alive(process.pid):
        if time.monotonic() >= deadline:
            raise CommandFailure("process-group cleanup incomplete")
        time.sleep(0.05)


def safe_stage(log):
    # Only fixed labels reach terminal/JUnit; never forward raw harness lines.
    stages = ((b"Preparing the cloud image", "image download"),
              (b"Creating the cloud-init", "cloud-init seed"),
              (b"Booting the VM", "VM boot"),
              (b"Running the repository installer", "installer bootstrap"),
              (b"Installing Ansible collections", "Ansible collections"),
              (b"Running authenticated SSH rollback probe", "SSH rollback"),
              (b"Running SSH/UFW hardening cutover", "SSH cutover"),
              (b"Running full playbook after SSH cutover", "Ansible deployment"),
              (b"Exercising UFW backend failure", "UFW failure recovery"),
              (b"Installing Nook baseline", "baseline install"),
              (b"Running ansible-pull", "Ansible deployment"),
              (b"TASK [", "Ansible deployment"),
              (b"[E2E] Running the in-guest WireGuard client", "WireGuard client"),
              (b"[E2E] Rebooting the VM", "reboot"),
              (b"[E2E] Reboot survival verified", "post-reboot checks"),
              (b"[E2E] Running idempotency", "idempotency"),
              (b"[E2E] Running restore", "restore"),
              (b"[PASS] round-trip=", "restore archive round-trip"),
              (b"[PASS] malicious=", "restore malicious archive rejection"),
              (b"[PASS] case=preexisting-symlink", "restore symlink rejection"),
              (b"[PASS] case=concurrent-", "restore concurrent-state recovery"),
              (b"[PASS] case=activation-rollback", "restore activation rollback"),
              (b"[PASS] case=readiness-timeout", "restore readiness timeout"),
              (b"[PASS] case=rollback-start-failure", "restore restart failure"),
              (b"[PASS] case=lock-contention", "restore lock contention"),
              (b"[PASS] case=archive-symlink", "restore archive descriptor rejection"),
              (b"[PASS] case=identity-symlink", "restore identity descriptor rejection"),
              (b"[PASS] case=activation-interrupt", "restore activation interrupt"),
              (b"[PASS] case=restore-drill", "restore drill completed"),
              (b"[FAIL] restore drill failed", "restore drill failed"),
              (b"[FAIL] activation interrupt did not restore prior root", "restore interrupt rollback failed"),
              (b"[FAIL] activation interrupt did not restart prior stack", "restore interrupt restart failed"),
              (b"[CLEANUP]", "cleanup"))
    with log.open("rb") as stream:
        stream.seek(max(0, log.stat().st_size - 65536))
        tail = stream.read()
    matches = [(tail.rfind(needle), label) for needle, label in stages if needle in tail]
    return max(matches)[1] if matches else "harness"


def run(argv, *, cwd, log, timeout=900, env=None, case_id="command", heartbeat=None,
        registry=None, grace=30, expected=0):
    __tracebackhide__ = True
    log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    environment = os.environ.copy()
    environment["PYTHONUNBUFFERED"] = "1"
    environment["PATH"] = str(Path(sys.executable).parent) + os.pathsep + environment.get("PATH", "")
    environment.update(env or {})
    process = None
    started = time.monotonic()
    try:
        with log.open("wb") as output:
            os.chmod(log, 0o600)
            process = subprocess.Popen(argv, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True, umask=0o077)
            while True:
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    raise CommandFailure(f"{case_id}: timeout; private log: {log}")
                try:
                    code = process.wait(timeout=min(30, remaining))
                    break
                except subprocess.TimeoutExpired:
                    if heartbeat:
                        heartbeat(f"{case_id}: running ({int(time.monotonic() - started)}s); stage: {safe_stage(log)}")
            if code != expected:
                raise CommandFailure(f"{case_id}: exit {code}; stage: {safe_stage(log)}; private log: {log}")
            return code
    except OSError:
        raise CommandFailure(f"{case_id}: could not start required command; private log: {log}") from None
    finally:
        try:
            if process:
                stop_group(process, grace)
        finally:
            if registry:
                cleanup_vms(registry, grace)
