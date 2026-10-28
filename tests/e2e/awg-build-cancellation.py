#!/usr/bin/env python3
"""Prove build-service cancellation only inside a disposable root-owned guest."""
import argparse
from contextlib import contextmanager
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

SCENARIO_TIMEOUT = 60
CANCELLED_STATUS = 130
CHILD_PROGRAM = 'import signal; signal.pause()'


def load_owner(path, state):
    spec = importlib.util.spec_from_file_location('nook_awg_owner', path)
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    owner.STATE = state
    owner.LOCK = state / 'module.lock'
    owner.BUILD_PENDING = state / 'build-transaction'
    owner.RECEIPT = state / 'receipt.json'
    owner.OWNER = state / 'worker.py'
    return owner


def isolated_owner():
    state = Path(__file__).resolve().parent
    location = state / 'owner-path'
    owner = load_owner(location.read_text().strip(), state)
    owner.guard(state, directory=True, private=True)
    owner.guard(location, private=True)
    return owner, state


def worker(kernel):
    owner, state = isolated_owner()
    owner.acknowledge_build_start(kernel)
    child = subprocess.Popen([sys.executable, '-c', CHILD_PROGRAM])
    # Both processes stay in the service cgroup. The controller uses pidfds.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(str(state / 'ready.sock'))
        connection.sendall(json.dumps([os.getpid(), child.pid]).encode() + b'\n')
    child.wait()
    raise RuntimeError('Build stand-in exited without cancellation')


def transaction(kernel):
    owner, state = isolated_owner()
    os.environ.pop(owner.LOCK_ENV, None)
    try:
        with owner.module_lock():
            owner.run_build_transaction(kernel, state)
    except KeyboardInterrupt:
        return CANCELLED_STATUS
    except owner.Refusal as error:
        if str(error) == 'AWG build cancelled':
            return CANCELLED_STATUS
        raise
    raise RuntimeError('Build stand-in unexpectedly completed')


def lock_available(owner):
    descriptor = os.open(owner.LOCK, os.O_RDWR | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        return True
    finally:
        os.close(descriptor)


def service_stopped(owner, record):
    unit = record['unit']
    return owner.dependency_control_group_empty(
        unit + '.service', f'/{record["slice"]}/{unit}.service')


@contextmanager
def smoke_state():
    state = Path(tempfile.mkdtemp(prefix='nook-build-smoke.', dir='/var/lib'))
    try:
        yield state
    except BaseException:
        print(f'awg-build-cancellation: private failure state retained at {state}', file=sys.stderr)
        raise
    else:
        shutil.rmtree(state)


def scenario(owner_path, cancellation):
    deadline = time.monotonic() + SCENARIO_TIMEOUT
    with smoke_state() as state:
        script = state / 'worker.py'
        script.write_bytes(Path(__file__).read_bytes())
        script.chmod(0o600)
        location = state / 'owner-path'
        location.write_text(str(owner_path) + '\n')
        location.chmod(0o600)
        owner = load_owner(owner_path, state)
        process = None
        unit_record = None
        pidfds = []
        cleanup_confirmed = True
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(state / 'ready.sock'))
            listener.listen(1)
            listener.settimeout(max(0.01, deadline - time.monotonic()))
            try:
                process = subprocess.Popen(
                    [sys.executable, str(script), 'transaction', '--kernel', os.uname().release],
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                with listener.accept()[0] as connection:
                    connection.settimeout(max(0.01, deadline - time.monotonic()))
                    with connection.makefile('rb') as stream:
                        identities = json.loads(stream.readline(1024))
                if not (isinstance(identities, list) and len(identities) == 2
                        and all(type(pid) is int and pid > 0 for pid in identities)):
                    raise RuntimeError('Invalid service readiness identities')
                pidfds = [os.pidfd_open(pid) for pid in identities]
                unit_record = json.loads((owner.BUILD_PENDING / 'transaction.json').read_text())
                if lock_available(owner):
                    raise RuntimeError('Build transaction released its lock before cancellation')
                process.send_signal(cancellation)
                output, errors = process.communicate(timeout=max(0.01, deadline - time.monotonic()))
                if process.returncode != CANCELLED_STATUS:
                    raise RuntimeError(f'Cancellation exited {process.returncode}: {errors.decode().strip()}')
                if not service_stopped(owner, unit_record):
                    raise RuntimeError('Build service remains active after cancellation')
                observer = select.poll()
                for descriptor in pidfds:
                    observer.register(descriptor, select.POLLIN)
                if len(observer.poll(0)) != len(pidfds):
                    raise RuntimeError('A build-service process survived cancellation')
                if owner.BUILD_PENDING.exists() or not lock_available(owner) or owner.RECEIPT.exists():
                    raise RuntimeError('Cancellation did not clear transaction state safely')
                print(f'awg-build-cancellation: {cancellation.name} service=stopped lock=available receipt=absent')
            finally:
                if unit_record is None and (owner.BUILD_PENDING / 'transaction.json').exists():
                    unit_record = json.loads((owner.BUILD_PENDING / 'transaction.json').read_text())
                if unit_record is not None:
                    owner.run(['systemctl', 'stop', unit_record['unit'] + '.service'],
                              check=False, timeout=SCENARIO_TIMEOUT)
                    cleanup_confirmed = service_stopped(owner, unit_record)
                if process is not None and process.poll() is None:
                    process.kill()
                    process.communicate(timeout=SCENARIO_TIMEOUT)
                for descriptor in pidfds:
                    os.close(descriptor)
                if not cleanup_confirmed:
                    raise RuntimeError(f'Unconfirmed guest smoke cleanup; preserve {state}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('owner_or_action')
    parser.add_argument('--kernel')
    args = parser.parse_args()
    if os.geteuid() != 0 or not Path('/run/systemd/system').is_dir():
        parser.error('Requires root inside a disposable systemd guest')
    if args.owner_or_action == 'bounded-make':
        worker(args.kernel)
    elif args.owner_or_action == 'transaction':
        return transaction(args.kernel)
    else:
        owner_path = Path(args.owner_or_action).resolve(strict=True)
        for cancellation in (signal.SIGTERM, signal.SIGINT):
            scenario(owner_path, cancellation)
    return 0


if __name__ == '__main__':
    sys.exit(main())
