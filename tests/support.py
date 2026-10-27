"""Private source snapshots and bounded subprocess execution (Linux, sequential)."""
from contextlib import contextmanager
import secrets
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import tempfile

from tests.qemu_owner import OwnerError, identity, private_json, write_private_json, terminate_owned


class CommandFailure(RuntimeError):
    """Only safe metadata belongs in this exception, never command output or argv."""


_SCRATCH_OWNERS = {}


class ScratchOwner:
    """An in-memory capability prevents stale on-disk complete records authorizing deletion."""
    def __init__(self, registry, directory):
        self.registry = Path(registry).absolute()
        self.registry_identity = identity(self.registry)
        self.directory = directory
        self.root_identity = identity(directory)
        self.nonce = secrets.token_hex(16)
        self.generation = 0
        self.authorized = False
        self.retain = False
        self.status = self.registry / "cleanup.status"
        if self.status.exists() or self.status.is_symlink():
            raise OwnerError("New scratch registry already has cleanup state")
        self.write("complete")
        self.authorized = True

    def record(self, state):
        return {"schema": 1, "nonce": self.nonce, "generation": self.generation, "state": state,
                "root": str(self.directory), "identity": self.root_identity}

    def write(self, state):
        if identity(self.registry) != self.registry_identity:
            raise OwnerError("Process registry directory changed")
        write_private_json(self.status, self.record(state))

    def matches(self, state):
        return identity(self.registry) == self.registry_identity and private_json(self.status) == self.record(state)

    def begin(self):
        was_authorized = self.authorized
        self.authorized = False
        if not was_authorized or not self.matches("complete"):
            raise OwnerError("Previous process cleanup was not verified complete")
        self.generation += 1
        self.write("pending")

    def finish(self, complete):
        if not self.matches("pending"):
            raise OwnerError("Pending process generation changed")
        self.write("complete" if complete else "failed")
        self.authorized = bool(complete)


@contextmanager
def short_state(registry=None):
    # Linux SSH ControlPath is 108 bytes: runtime scratch remains short/private.
    directory = Path(tempfile.mkdtemp(prefix="nook-", dir="/tmp"))
    original = identity(directory)
    owner = None
    key = str(Path(registry).absolute()) if registry is not None else None
    try:
        if key is not None:
            if key in _SCRATCH_OWNERS:
                raise OwnerError("Scratch registry already has an active owner")
            owner = ScratchOwner(registry, directory)
            _SCRATCH_OWNERS[key] = owner
        yield directory
    finally:
        primary_error = sys.exc_info()[1]
        allowed = False
        try:
            allowed = identity(directory) == original and (
                key is None or (owner is not None and owner.authorized and not owner.retain and owner.matches("complete")))
        except (OSError, ValueError, OwnerError):
            pass
        if allowed:
            try:
                shutil.rmtree(directory)
            except OSError:
                print(f"Private QA scratch retained: {directory}; removal failed", file=sys.stderr)
                if owner is not None:
                    owner.authorized = False
                    if _SCRATCH_OWNERS.get(key) is owner:
                        del _SCRATCH_OWNERS[key]
                if primary_error is None:
                    raise
        else:
            print(f"Private QA scratch retained: {directory}; cleanup not confirmed", file=sys.stderr)
        if owner is not None and _SCRATCH_OWNERS.get(key) is owner:
            del _SCRATCH_OWNERS[key]


def snapshot(source, destination):
    destination.mkdir(mode=0o700)
    # A local clone owns its Git metadata and objects, retaining history and tags.
    # Never copy operator Git configuration, hooks, ignored inventory or vault files.
    git_environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    git_environment.update({
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "core.hooksPath",
        "GIT_CONFIG_VALUE_0": os.devnull,
    })
    subprocess.run(["git", "clone", "--quiet", "--no-hardlinks", "--no-checkout", str(source), str(destination)],
                   check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=30, env=git_environment)
    branch = subprocess.run(["git", "-C", str(destination), "symbolic-ref", "-q", "HEAD"],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=30, env=git_environment)
    if branch.returncode == 1:
        # PR merge checkouts may have no branch at HEAD. The Bash fixture uses
        # a branch name when constructing its guest-local development origin.
        for arguments in (("branch", "nook-pytest-source", "HEAD"),
                          ("symbolic-ref", "HEAD", "refs/heads/nook-pytest-source")):
            subprocess.run(["git", "-C", str(destination), *arguments], check=True,
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=30, env=git_environment)
    elif branch.returncode:
        raise CommandFailure("could not inspect private Git snapshot HEAD")
    paths = subprocess.check_output(["git", "-C", str(source), "ls-files", "-z", "--cached", "--others",
                                     "--exclude-standard"], stdin=subprocess.DEVNULL, timeout=30, env=git_environment).split(b"\0")
    for raw in set(paths) - {b""}:
        relative = Path(os.fsdecode(raw))
        src, dst = source / relative, destination / relative
        if not src.exists() and not src.is_symlink():
            continue
        if src.is_symlink():
            try:
                canonical = source / "AGENTS.md"
                valid_alias = (
                    relative == Path("CLAUDE.md")
                    and os.readlink(src) == "AGENTS.md"
                    and b"AGENTS.md" in paths
                    and not canonical.is_symlink()
                    and canonical.is_file()
                    and src.resolve(strict=True) == source.resolve() / "AGENTS.md"
                )
            except (OSError, RuntimeError):
                valid_alias = False
            if not valid_alias:
                raise CommandFailure("source snapshot refuses symlinks outside regular source files")
            dst.symlink_to("AGENTS.md")
            continue
        # Reject symlink traversal rather than copying external operator material.
        if src.is_symlink() or source.resolve() not in src.resolve().parents:
            raise CommandFailure("source snapshot refuses symlinks outside regular source files")
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    # The staged index must exactly match the materialized tree that gitleaks scans.
    subprocess.run(["git", "-C", str(destination), "add", "--all", "--"], check=True,
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=30, env=git_environment)
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


def validate_vm_entry(value, phase):
    from tests.qemu_owner import validate_state_record
    value = validate_state_record(value)
    if not isinstance(value, dict) or value.get("schema") != 1 or value.get("phase") != phase:
        raise OwnerError("Incomplete QEMU registry record")
    directory = Path(value["directory"])
    executable = Path(value["executable"])
    if not directory.is_absolute() or not executable.is_absolute() or not executable.name.startswith("qemu-system-"):
        raise OwnerError("Incomplete exact QEMU executable/directory ownership")
    if value.get("disk") != str(directory / "disk.qcow2"):
        raise OwnerError("QEMU owned disk record differs")
    if directory.exists() or directory.is_symlink():
        if identity(directory) != value["identity"]:
            raise OwnerError("QEMU registered directory identity changed")
    return value


def cleanup_vms(registry, grace=30):
    """Use captured exact executable/root identity, never adopt a live process's exe."""
    from tests.qemu_owner import private_text
    registry = Path(registry)
    try:
        identity(registry)
        record_paths = list(registry.glob("*.record"))
        intent_paths = list(registry.glob("*.intent"))
    except (OwnerError, OSError, ValueError, KeyError, TypeError, OverflowError) as error:
        raise CommandFailure(f"VM ownership cleanup incomplete: {error}") from error
    records = {}
    entry_errors = {}
    for record in record_paths:
        try:
            records[record.stem] = validate_vm_entry(private_json(record), "running")
        except (OwnerError, OSError, ValueError, KeyError, TypeError, OverflowError) as error:
            entry_errors[record.stem] = error
    for intent in intent_paths:
        if intent.stem in records:
            continue
        try:
            value = validate_vm_entry(private_json(intent), "launching")
            try:
                pid = private_text(Path(value["pidfile"]), expected_parent=value["pidfile_parent_identity"]).strip()
            except FileNotFoundError:
                raise OwnerError("QEMU intent has no pidfile or completed record; possible orphan") from None
            if not pid.isdigit():
                raise OwnerError("Malformed QEMU startup pidfile; possible orphan")
            started = process_identity(int(pid))
            if started is None or int(started) < int(value["earliest"]):
                raise OwnerError("Startup QEMU identity missing; possible orphan")
            value.update(pid=pid, started=started)
            records[intent.stem] = value
            entry_errors.pop(intent.stem, None)
        except (OwnerError, OSError, ValueError, KeyError, TypeError, OverflowError) as error:
            entry_errors[intent.stem] = error
    errors = list(entry_errors.values())
    for value in records.values():
        try:
            terminate_owned(value["pid"], value["started"], value["disk"], executable=value["executable"], grace=grace)
        except (OwnerError, OSError, ValueError, KeyError, TypeError, OverflowError) as error:
            errors.append(error)
    if errors:
        raise CommandFailure("VM ownership cleanup incomplete: " + " | ".join(str(error) for error in errors)) from errors[0]


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
    owner = None
    started = time.monotonic()
    try:
        if registry is not None:
            candidate = _SCRATCH_OWNERS.get(str(Path(registry).absolute()))
            if candidate is not None:
                candidate.begin()
                owner = candidate
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
    except (OSError, OwnerError):
        raise CommandFailure(f"{case_id}: could not start required command safely; private log: {log}") from None
    finally:
        primary_error = sys.exc_info()[1]
        if owner is not None and primary_error is not None:
            owner.retain = True
        cleanup_errors = []
        for cleanup in (lambda: stop_group(process, grace) if process else None,
                        lambda: cleanup_vms(registry, grace) if registry is not None else None):
            try:
                cleanup()
            except BaseException as error:
                cleanup_errors.append(error)
        if owner is not None:
            try:
                owner.finish(not cleanup_errors)
            except BaseException as error:
                cleanup_errors.append(error)
        if cleanup_errors:
            if primary_error is not None:
                print("QA cleanup incomplete; primary command error preserved and scratch retained", file=sys.stderr)
            else:
                raise cleanup_errors[0]
