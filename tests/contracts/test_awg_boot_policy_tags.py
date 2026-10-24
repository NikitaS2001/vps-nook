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
    assert guard["tags"] == ["always"]
    assert "awg_module.py pre-hardening" in guard["ansible.builtin.script"]["cmd"]
    assert "wg_amnezia_enabled" in guard["when"]
    inventory = tmp_path / "inventory.ini"
    inventory.write_text("[vps]\ntag-fixture ansible_connection=local\n")
    result = subprocess.run(["ansible-playbook", str(site), "-i", str(inventory),
                             "--list-tasks", "--tags", tags], cwd=source_root,
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, "Ansible tagged task listing failed"
    assert guard["name"] in result.stdout
    if "vps_hardening :" in result.stdout:
        assert result.stdout.index(guard["name"]) < result.stdout.index("vps_hardening :")
