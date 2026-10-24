"""Single PIDFD-based owner for disposable QEMU processes and their private state."""
import argparse
import errno
import json
import os
from pathlib import Path
import select
import re
import shutil
import signal
import stat
import time


class OwnerError(RuntimeError):
    """Ownership or termination is unproved: do not signal or remove state."""


def identity(path):
    info = Path(path).lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise OwnerError("QEMU state must be a caller-owned, private real directory")
    return [info.st_dev, info.st_ino, info.st_uid, stat.S_IMODE(info.st_mode)]


def private_text(path, *, expected_parent=None):
    path = Path(path)
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(parent)
        actual = [info.st_dev, info.st_ino, info.st_uid, stat.S_IMODE(info.st_mode)]
        if info.st_uid != os.geteuid() or actual[3] != 0o700 or (expected_parent is not None and actual != expected_parent):
            raise OwnerError("Private record parent identity differs")
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
                raise OwnerError("Unsafe private ownership record")
            data = os.read(fd, 8193)
            if len(data) > 8192:
                raise OwnerError("Private ownership record exceeds size limit")
            return data.decode("utf-8")
        finally:
            os.close(fd)
    finally:
        os.close(parent)


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise OwnerError("Duplicate private record key")
        value[key] = item
    return value


def private_json(path):
    return json.loads(private_text(path), object_pairs_hook=unique_object)


def validate_state_record(value):
    if not isinstance(value, dict) or type(value.get("schema")) is not int or value["schema"] != 1:
        raise OwnerError("Invalid QEMU ownership schema")
    base = {"schema", "directory", "identity", "phase"}
    launching = {"pidfile", "pidfile_parent_identity", "executable", "disk", "earliest"}
    phases = {"initialized": base, "launching": base | launching, "running": base | launching | {"pid", "started"}}
    if value.get("phase") not in phases or set(value) != phases[value["phase"]]:
        raise OwnerError("Incomplete or unknown QEMU ownership fields")
    directory = Path(value["directory"])
    if not isinstance(value["directory"], str) or not directory.is_absolute() or str(directory.resolve()) != str(directory):
        raise OwnerError("Noncanonical owned QEMU directory")
    def valid_identity(item):
        return (isinstance(item, list) and len(item) == 4 and all(type(number) is int and number >= 0 for number in item)
                and item[2] == os.geteuid() and item[3] == 0o700)
    if not valid_identity(value["identity"]):
        raise OwnerError("Invalid captured private root identity")
    if value["phase"] != "initialized":
        executable = Path(value["executable"])
        pidfile = Path(value["pidfile"])
        if (not executable.is_absolute() or not executable.name.startswith("qemu-system-")
                or str(executable.resolve()) != str(executable) or not pidfile.is_absolute()
                or str(pidfile.resolve()) != str(pidfile) or not valid_identity(value["pidfile_parent_identity"])
                or value["disk"] != str(directory / "disk.qcow2")
                or type(value["earliest"]) is not int or value["earliest"] < 0):
            raise OwnerError("Invalid captured QEMU executable/disk/pidfile identity")
    if value["phase"] == "running":
        if type(value["pid"]) is not int or value["pid"] <= 1 or not isinstance(value["started"], str) or not value["started"].isdigit():
            raise OwnerError("Invalid captured QEMU PID/start identity")
    return value


def write_private_json(path, value):
    path = Path(path)
    identity(path.parent)
    if path.exists() or path.is_symlink():
        private_json(path)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{time.monotonic_ns()}")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    created = os.fstat(fd)
    try:
        data = (json.dumps(value, sort_keys=True) + "\n").encode()
        while data:
            data = data[os.write(fd, data):]
        os.fsync(fd)
        os.replace(temporary, path)
        parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        os.close(fd)
        if temporary.exists():
            current = temporary.lstat()
            if (current.st_dev, current.st_ino) != (created.st_dev, created.st_ino):
                raise OwnerError("Temporary record identity changed; preserve it")
            temporary.unlink()


def snapshot(pid):
    base = Path(f"/proc/{pid}")
    try:
        fields = (base / "stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] == "Z":
            return None
        exe = os.readlink(base / "exe")
        argv = [word for word in (base / "cmdline").read_bytes().split(bytes((0,))) if word]
        uids = next(line for line in (base / "status").read_text().splitlines() if line.startswith("Uid:")).split()[1:5]
        return (fields[19], exe, argv, tuple(map(int, uids)))
    except (FileNotFoundError, ProcessLookupError):
        return None


def verify_snapshot(value, started, disk, executable=None):
    ticks, exe, argv, uids = value
    if ticks != str(started) or any(uid != os.geteuid() for uid in uids):
        raise OwnerError("QEMU process start time or UID differs; preserve state")
    if not Path(exe).name.startswith("qemu-system-"):
        raise OwnerError("QEMU executable identity differs")
    if executable is not None and exe != str(executable):
        raise OwnerError("QEMU executable path differs")
    expected = os.fsencode(f"file={Path(disk).absolute()}")
    matches = [argv[index + 1] for index, word in enumerate(argv[:-1]) if word == b"-drive"]
    if not any(argument.split(b",", 1)[0] == expected for argument in matches):
        raise OwnerError("QEMU exact owned disk argument differs")


def terminate_owned(pid, started, disk, *, executable=None, grace=30):
    if not str(pid).isdigit() or int(pid) <= 1 or not str(started).isdigit():
        raise OwnerError("Malformed QEMU process identity")
    pid = int(pid)
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        raise OwnerError("PIDFD support is required. There is no numeric PID signal fallback.")
    value = snapshot(pid)
    if value is not None:
        verify_snapshot(value, started, disk, executable)
    try:
        descriptor = os.pidfd_open(pid)
    except OSError as error:
        if error.errno == errno.ESRCH and snapshot(pid) is None:
            return
        raise OwnerError("Cannot pin owned QEMU process") from error
    try:
        poller = select.poll()
        poller.register(descriptor, select.POLLIN)
        value = snapshot(pid)
        if value is None:
            if poller.poll(0):
                return
            raise OwnerError("QEMU identity disappeared without confirmed PIDFD exit")
        verify_snapshot(value, started, disk, executable)
        for sig, seconds in ((signal.SIGTERM, grace), (signal.SIGKILL, 5)):
            value = snapshot(pid)
            if value is None:
                if poller.poll(0):
                    return
                raise OwnerError("QEMU exit not confirmed")
            verify_snapshot(value, started, disk, executable)
            try:
                signal.pidfd_send_signal(descriptor, sig)
            except ProcessLookupError:
                if poller.poll(0):
                    return
                raise OwnerError("QEMU signal failed without confirmed exit")
            if poller.poll(max(0, int(seconds * 1000))):
                return
        raise OwnerError("Owned QEMU did not exit; preserve state")
    finally:
        os.close(descriptor)


def validate_explicit_state_path(path):
    path = Path(path).absolute()
    if path == Path("/") or ".." in path.parts:
        raise OwnerError("Unsafe explicit QEMU state path")
    for part in [*reversed(path.parents), path]:
        if part.is_symlink() or (part.exists() and not part.is_dir()):
            raise OwnerError("Explicit QEMU state path contains a symlink or non-directory")
    if path.exists():
        identity(path)


def validate_peer_target(directory, host, port, user):
    value = init_state(directory, existing=True)
    fields = {}
    for line in private_text(Path(directory) / "peer.env", expected_parent=value["identity"]).splitlines():
        key, separator, data = line.partition("=")
        if not separator or key in fields or key not in {"PEER_PUBLIC_KEY", "VPS_HOST", "VPS_SSH_PORT", "VPS_SSH_USER"}:
            raise OwnerError("Malformed external peer target state")
        fields[key] = data
    if set(fields) != {"PEER_PUBLIC_KEY", "VPS_HOST", "VPS_SSH_PORT", "VPS_SSH_USER"}:
        raise OwnerError("Incomplete external peer target state")
    if re.fullmatch(r"[A-Za-z0-9+/]{43}=", fields["PEER_PUBLIC_KEY"]) is None:
        raise OwnerError("Malformed external peer public identity")
    if (fields["VPS_HOST"], fields["VPS_SSH_PORT"], fields["VPS_SSH_USER"]) != (host, str(port), user):
        raise OwnerError("External cleanup target differs from captured peer target; state retained")


def init_state(directory, *, existing=False):
    directory = Path(directory).absolute()
    if directory == Path("/") or directory.resolve() != directory:
        raise OwnerError("QEMU state must be an absolute canonical, non-symlink path")
    current = identity(directory)
    record = directory / ".qemu-owner.json"
    if record.exists() or record.is_symlink():
        value = validate_state_record(private_json(record))
        if value.get("schema") != 1 or value.get("directory") != str(directory) or value.get("identity") != current:
            raise OwnerError("QEMU state identity changed")
        return value
    if existing:
        raise OwnerError("Existing QEMU state has no ownership record; preserve it")
    sentinels = {".qemu-install-state": "qemu-install-v1\n", ".lifecycle-state": "ztvps-lifecycle-v1\n",
                 ".external-client-state": "external-client-qemu-v1\n"}
    for entry in directory.iterdir():
        if entry.name not in sentinels or private_text(entry) != sentinels[entry.name]:
            raise OwnerError("Existing QEMU state has no ownership record; preserve it")
    value = {"schema": 1, "directory": str(directory), "identity": current, "phase": "initialized"}
    write_private_json(record, value)
    return value


def prepare_state(directory, executable, pidfile=None):
    directory = Path(directory).absolute()
    value = init_state(directory)
    if value["phase"] != "initialized":
        raise OwnerError("QEMU state already has a launch intent")
    selected = Path(pidfile).absolute() if pidfile is not None else directory / "qemu.pid"
    parent_identity = identity(selected.parent)
    value.update(phase="launching", pidfile=str(selected), pidfile_parent_identity=parent_identity,
                 executable=str(Path(executable).resolve()),
                 disk=str(directory / "disk.qcow2"), earliest=int(time.clock_gettime(time.CLOCK_BOOTTIME) * os.sysconf("SC_CLK_TCK")))
    write_private_json(directory / ".qemu-owner.json", value)
    return value


def publish_state(directory):
    directory = Path(directory).absolute()
    value = init_state(directory, existing=True)
    pidfile = Path(value["pidfile"])
    try:
        pid = int(private_text(pidfile, expected_parent=value["pidfile_parent_identity"]).strip())
    except (OSError, ValueError) as error:
        raise OwnerError("The owner cannot verify the startup pidfile identity. There may be an orphan process. Preserve the state.") from error
    process = snapshot(pid)
    if process is None or int(process[0]) < value["earliest"]:
        raise OwnerError("The owner cannot verify the startup identity. There may be an orphan process. Preserve the state.")
    verify_snapshot(process, process[0], value["disk"], value["executable"])
    value.update(phase="running", pid=pid, started=process[0])
    write_private_json(directory / ".qemu-owner.json", value)
    return value


def publish_external_intent(directory, record):
    value = init_state(directory, existing=True)
    if value.get("phase") != "launching":
        raise OwnerError("QEMU launch intent not prepared")
    record = Path(record)
    if record.exists() or record.is_symlink():
        raise OwnerError("External intent already exists")
    write_private_json(record, value)


def publish_external_record(directory, record, pid, started):
    value = init_state(directory, existing=True)
    if value.get("phase") != "running" or str(value.get("pid")) != str(pid) or value.get("started") != str(started):
        raise OwnerError("Captured QEMU publication identity changed")
    record = Path(record)
    if record.exists() or record.is_symlink():
        raise OwnerError("External ownership record already exists")
    write_private_json(record, value)


def cleanup_state(directory, *, sentinel=None, sentinel_text=None, keep_state=False, grace=30):
    directory = Path(directory).absolute()
    value = init_state(directory, existing=True)
    if value["phase"] == "launching":
        value = publish_state(directory)
    if value["phase"] == "running":
        terminate_owned(value["pid"], value["started"], value["disk"], executable=value["executable"], grace=grace)
    elif value["phase"] != "initialized":
        raise OwnerError("Unknown QEMU cleanup phase")
    if identity(directory) != value["identity"]:
        raise OwnerError("QEMU directory replaced; preserve it")
    if sentinel is not None:
        path = Path(sentinel)
        if path.parent != directory:
            raise OwnerError("Sentinel is outside owned state")
        if private_text(path, expected_parent=value["identity"]).strip() != sentinel_text:
            raise OwnerError("QEMU sentinel identity differs")
    if identity(directory) != value["identity"]:
        raise OwnerError("QEMU directory replaced before removal; preserve it")
    if not keep_state:
        shutil.rmtree(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check-path", "peer-target", "init", "prepare", "publish", "intent", "record", "cleanup"))
    parser.add_argument("directory", type=Path)
    parser.add_argument("--existing", action="store_true")
    parser.add_argument("--executable")
    parser.add_argument("--pidfile")
    parser.add_argument("--record", type=Path)
    parser.add_argument("--pid")
    parser.add_argument("--started")
    parser.add_argument("--host")
    parser.add_argument("--port")
    parser.add_argument("--user")
    parser.add_argument("--sentinel", nargs=2)
    parser.add_argument("--keep-state", action="store_true")
    args = parser.parse_args()
    try:
        if args.action == "check-path":
            validate_explicit_state_path(args.directory)
        elif args.action == "peer-target":
            validate_peer_target(args.directory, args.host, args.port, args.user)
        elif args.action == "init":
            init_state(args.directory, existing=args.existing)
        elif args.action == "prepare":
            prepare_state(args.directory, args.executable, args.pidfile)
        elif args.action == "publish":
            value = publish_state(args.directory)
            print(value["pid"], value["started"])
        elif args.action == "intent":
            publish_external_intent(args.directory, args.record)
        elif args.action == "record":
            publish_external_record(args.directory, args.record, args.pid, args.started)
        else:
            cleanup_state(args.directory, sentinel=args.sentinel[0] if args.sentinel else None,
                          sentinel_text=args.sentinel[1] if args.sentinel else None, keep_state=args.keep_state)
    except (OwnerError, OSError, ValueError, KeyError) as error:
        print(f"QEMU ownership cleanup refused: {error}", file=__import__("sys").stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
