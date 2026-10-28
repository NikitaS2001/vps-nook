"""Execute the shared owner against disposable fake QEMU children, never KVM/VPS."""
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys

import pytest

from tests import qemu_owner as owner

pytestmark = pytest.mark.quick


@pytest.fixture
def fake_qemu(tmp_path):
    executable = tmp_path / "qemu-system-fixture"
    shutil.copy2(sys.executable, executable)
    directory = tmp_path / "state"
    directory.mkdir(mode=0o700)
    owner.init_state(directory)
    (directory / "disk.qcow2").write_bytes(b"owned fake disk\n")
    owner.prepare_state(directory, executable)
    child = subprocess.Popen([str(executable), "-u", "-c",
                              "import time; print('ready', flush=True); time.sleep(300)",
                              "-drive", f"file={directory}/disk.qcow2,if=virtio,format=qcow2"],
                             stdout=subprocess.PIPE, start_new_session=True)
    try:
        assert select.select([child.stdout], [], [], 5)[0], "fake child readiness timeout"
        assert child.stdout.readline() == b"ready\n"
        pidfile = directory / "qemu.pid"
        pidfile.write_text(str(child.pid))
        pidfile.chmod(0o600)
        record = owner.publish_state(directory)
        yield directory, child, record
    finally:
        if child.poll() is None:
            child.kill()  # live, unreaped Popen-owned child, never a daemon pidfile PID
        child.wait(timeout=5)
        child.stdout.close()


def test_bash_manual_wrapper_without_external_registry_stops_owned_vm(source_root, fake_qemu):
    directory, child, _ = fake_qemu
    environment = dict(os.environ)
    environment.pop("E2E_PROCESS_REGISTRY", None)
    result = subprocess.run(["bash", "-c", 'source "$1"; cleanup_owned_qemu "$2"', "fixture",
                             str(source_root / "tests/e2e/common.sh"), str(directory)],
                            env=environment, capture_output=True, timeout=10)
    assert result.returncode == 0, result.stderr.decode()
    assert child.wait(timeout=5) == -signal.SIGTERM
    assert not directory.exists()


@pytest.mark.parametrize("mismatch", ["start", "exe", "disk"])
def test_identity_mismatch_preserves_process_and_state(fake_qemu, mismatch):
    directory, child, record = fake_qemu
    if mismatch == "start":
        record["started"] = str(int(record["started"]) + 1)
    elif mismatch == "exe":
        record["executable"] = "/not-the-owned-qemu"
    else:
        record["disk"] = str(directory / "foreign.qcow2")
    owner.write_private_json(directory / ".qemu-owner.json", record)
    with pytest.raises(owner.OwnerError):
        owner.cleanup_state(directory, grace=0.1)
    assert child.poll() is None
    assert directory.is_dir()


def test_pidfd_unavailable_never_falls_back_to_numeric_signal(fake_qemu, monkeypatch):
    directory, child, _ = fake_qemu
    with monkeypatch.context() as patch:
        patch.delattr(owner.os, "pidfd_open")
        patch.setattr(owner.os, "kill", lambda *args: pytest.fail("numeric PID signal used"))
        with pytest.raises(owner.OwnerError, match="PIDFD support"):
            owner.cleanup_state(directory)
    assert child.poll() is None
    assert directory.is_dir()


def test_missing_startup_pidfile_preserves_possible_orphan_state(tmp_path):
    directory = tmp_path / "state"
    directory.mkdir(mode=0o700)
    owner.init_state(directory)
    executable = tmp_path / "qemu-system-fixture"
    shutil.copy2(sys.executable, executable)
    owner.prepare_state(directory, executable)
    with pytest.raises(owner.OwnerError):
        owner.cleanup_state(directory)
    assert directory.is_dir()


def test_replaced_directory_cannot_be_adopted_or_deleted(tmp_path):
    directory = tmp_path / "state"
    directory.mkdir(mode=0o700)
    record = owner.init_state(directory)
    record["identity"][1] += 1
    owner.write_private_json(directory / ".qemu-owner.json", record)
    with pytest.raises(owner.OwnerError, match="identity changed"):
        owner.cleanup_state(directory)
    assert directory.is_dir()


def test_existing_unrecorded_state_cannot_be_adopted(tmp_path):
    directory = tmp_path / "state"
    directory.mkdir(mode=0o700)
    (directory / "disk.qcow2").write_bytes(b"operator disk")
    with pytest.raises(owner.OwnerError, match="no ownership record"):
        owner.init_state(directory)
    assert (directory / "disk.qcow2").read_bytes() == b"operator disk"


def test_external_client_requires_explicit_target_before_side_effects(source_root, tmp_path):
    environment = dict(os.environ)
    environment.pop("VPS_HOST", None)
    state = tmp_path / "must-not-create"
    result = subprocess.run(["bash", str(source_root / "tests/e2e/external-client-qemu.sh"),
                             "--prepare-only", "--state-dir", str(state)],
                            env=environment, capture_output=True, timeout=5)
    assert result.returncode != 0
    assert b"VPS_HOST is required; refusing an implicit remote target" in result.stderr
    assert not state.exists()


def test_missing_pidfd_support_even_when_recorded_pid_is_absent(tmp_path, monkeypatch):
    with monkeypatch.context() as patch:
        patch.delattr(owner.os, "pidfd_open")
        patch.setattr(owner.os, "kill", lambda *args: pytest.fail("numeric PID signal used"))
        with pytest.raises(owner.OwnerError, match="PIDFD support"):
            owner.terminate_owned(1073741824, "1", tmp_path / "disk.qcow2")


def test_zombie_owned_pid_requires_ready_pidfd_before_removal(fake_qemu):
    directory, child, _ = fake_qemu
    descriptor = os.pidfd_open(child.pid)
    try:
        signal.pidfd_send_signal(descriptor, signal.SIGTERM)
        poller = select.poll()
        poller.register(descriptor, select.POLLIN)
        assert poller.poll(5000), "owned child did not exit"
        assert owner.snapshot(child.pid) is None
        owner.cleanup_state(directory, grace=0.1)
        assert not directory.exists()
        assert child.wait(timeout=5) == -signal.SIGTERM
    finally:
        os.close(descriptor)


def test_pidfd_signal_failure_preserves_live_child_and_state(fake_qemu, monkeypatch):
    directory, child, _ = fake_qemu
    def denied(*args):
        raise PermissionError("injected pidfd signal denial")
    with monkeypatch.context() as patch:
        patch.setattr(owner.signal, "pidfd_send_signal", denied)
        with pytest.raises(PermissionError, match="denial"):
            owner.cleanup_state(directory, grace=0.1)
    assert child.poll() is None
    assert directory.is_dir()


def test_unconfirmed_exit_preserves_state(fake_qemu, monkeypatch):
    directory, child, _ = fake_qemu
    class Unready:
        def register(self, *args):
            pass
        def poll(self, *args):
            return []
    with monkeypatch.context() as patch:
        patch.setattr(owner.select, "poll", Unready)
        patch.setattr(owner.signal, "pidfd_send_signal", lambda *args: None)
        with pytest.raises(owner.OwnerError, match="did not exit"):
            owner.cleanup_state(directory, grace=0.1)
    assert child.poll() is None
    assert directory.is_dir()


def test_startup_pidfile_parent_identity_is_bound(fake_qemu):
    directory, child, record = fake_qemu
    record["phase"] = "launching"
    del record["pid"]
    del record["started"]
    record["pidfile_parent_identity"][1] += 1
    owner.write_private_json(directory / ".qemu-owner.json", record)
    with pytest.raises(owner.OwnerError, match="parent identity"):
        owner.publish_state(directory)
    assert child.poll() is None
    assert directory.is_dir()


def test_unrelated_operator_state_cannot_be_adopted(tmp_path):
    directory = tmp_path / "state"
    directory.mkdir(mode=0o700)
    operator = directory / "operator-private-key"
    operator.write_text("test-only operator sentinel")
    with pytest.raises(owner.OwnerError, match="no ownership record"):
        owner.init_state(directory)
    assert operator.read_text() == "test-only operator sentinel"


def test_symlink_explicit_state_rejected_before_mutation(tmp_path):
    directory = tmp_path / "operator"
    directory.mkdir(mode=0o700)
    alias = tmp_path / "alias"
    alias.symlink_to(directory, target_is_directory=True)
    with pytest.raises(owner.OwnerError, match="symlink"):
        owner.validate_explicit_state_path(alias)
    assert list(directory.iterdir()) == []


def test_external_record_uses_captured_identity_not_new_proc_snapshot(fake_qemu, tmp_path, monkeypatch):
    directory, child, record = fake_qemu
    external = tmp_path / "external.record"
    with monkeypatch.context() as patch:
        patch.setattr(owner, "snapshot", lambda *args: pytest.fail("publication reread live /proc"))
        owner.publish_external_record(directory, external, record["pid"], record["started"])
    value = owner.private_json(external)
    assert value["pid"] == child.pid
    assert value["started"] == record["started"]
    assert value["executable"] == record["executable"]
    assert value["identity"] == record["identity"]


def test_external_cleanup_wrong_target_fails_before_network(source_root, tmp_path):
    directory = tmp_path / "state"
    directory.mkdir(mode=0o700)
    owner.init_state(directory)
    peer = directory / "peer.env"
    peer.write_text("PEER_PUBLIC_KEY=" + "A" * 43 + "=\nVPS_HOST=captured.example\nVPS_SSH_PORT=22\nVPS_SSH_USER=sysadmin\n")
    peer.chmod(0o600)
    key = tmp_path / "key"
    key.write_text("fixture only")
    known = tmp_path / "known"
    known.write_text("fixture only")
    binary = tmp_path / "bin"
    binary.mkdir()
    network = tmp_path / "must-not-connect"
    ssh = binary / "ssh"
    ssh.write_text('#!/bin/bash\ntouch "${NETWORK_SENTINEL:?}"\nexit 99\n')
    ssh.chmod(0o700)
    environment = {**os.environ, "VPS_HOST": "wrong.example", "VPS_SSH_PORT": "22", "VPS_SSH_USER": "sysadmin",
                   "VPS_SSH_KEY": str(key), "VPS_KNOWN_HOSTS": str(known), "NETWORK_SENTINEL": str(network),
                   "PATH": str(binary) + os.pathsep + os.environ["PATH"]}
    result = subprocess.run(["bash", str(source_root / "tests/e2e/external-client-qemu.sh"),
                             "--cleanup", "--state-dir", str(directory)],
                            env=environment, capture_output=True, timeout=5)
    assert result.returncode != 0
    assert b"External cleanup target differs" in result.stderr
    assert not network.exists()
    assert directory.is_dir() and peer.is_file()
