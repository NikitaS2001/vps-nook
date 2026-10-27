"""The early boot policy guard must survive intentionally tagged deployment."""
import subprocess

import pytest
import yaml

pytestmark = pytest.mark.quick


@pytest.mark.parametrize("tags", ["hardening,orchestration", "packages,compose", "hardening", "compose"])
def test_awg_boot_guard_is_listed_before_tagged_role_tasks(source_root, tmp_path, tags):
    site = source_root / "site.yml"
    plays = yaml.safe_load(site.read_text())
    guard = plays[0]["pre_tasks"][0]
    inventory = tmp_path / "inventory.ini"
    inventory.write_text("[vps]\ntag-fixture ansible_connection=local\n")
    result = subprocess.run(["ansible-playbook", str(site), "-i", str(inventory),
                             "--list-tasks", "--tags", tags], cwd=source_root,
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, "Ansible tagged task listing failed"
    assert guard["name"] in result.stdout
    if "vps_hardening :" in result.stdout:
        assert result.stdout.index(guard["name"]) < result.stdout.index("vps_hardening :")


@pytest.mark.parametrize("guard_exit", [0, 37])
def test_awg_guard_runs_from_spaced_checkout(source_root, tmp_path, guard_exit):
    guard = yaml.safe_load((source_root / "site.yml").read_text())[0]["pre_tasks"][0]
    checkout = tmp_path / "controller checkout"
    helper = checkout / "roles/vps_orchestration/files/awg_module.py"
    helper.parent.mkdir(parents=True)
    guard_marker = tmp_path / "guard-ran"
    next_marker = tmp_path / "next-phase-ran"
    helper.write_text(
        "#!/usr/bin/env python3\n"
        "import pathlib\n"
        "import sys\n"
        "assert sys.argv[1:] == ['pre-hardening']\n"
        f"pathlib.Path({str(guard_marker)!r}).write_text('guard ran\\n')\n"
        f"sys.exit({guard_exit})\n"
    )
    helper.chmod(0o700)
    playbook = checkout / "site.yml"
    playbook.write_text(yaml.safe_dump([{
        "name": "Spaced checkout guard sandbox",
        "hosts": "localhost",
        "connection": "local",
        "gather_facts": False,
        "become": False,
        "vars": {"wg_amnezia_enabled": True},
        "pre_tasks": [guard],
        "tasks": [{
            "name": "Sandbox | Record next phase",
            "ansible.builtin.copy": {
                "content": "next phase ran\n",
                "dest": str(next_marker),
                "mode": "0600",
            },
            "tags": ["always"],
        }],
    }], explicit_start=True, sort_keys=False))
    result = subprocess.run(
        ["ansible-playbook", str(playbook), "-i", "localhost,", "--tags", "compose"],
        cwd=checkout, capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == (0 if guard_exit == 0 else 2), result.stdout + result.stderr
    assert guard_marker.read_text() == "guard ran\n"
    if guard_exit == 0:
        assert next_marker.read_text() == "next phase ran\n"
    else:
        assert not next_marker.exists()
