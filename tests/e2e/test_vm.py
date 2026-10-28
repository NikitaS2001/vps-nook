import os
import shutil
import pytest
from tests.registry import VMS
from tests.support import CommandFailure


@pytest.mark.parametrize("case", [pytest.param(case, id=case.id, marks=[getattr(pytest.mark, m) for m in case.marks])
                                  for case in VMS])
def test_vm(case, private_repo, command):
    environment = {"NOOK_WG_TRAFFIC_MODE": "services"}
    if case.id == "qemu-services":
        traffic_mode = os.environ.get("NOOK_WG_TRAFFIC_MODE") or "services"
        if traffic_mode not in ("services", "full"):
            raise CommandFailure("NOOK_WG_TRAFFIC_MODE must be services or full")
        environment["NOOK_WG_TRAFFIC_MODE"] = traffic_mode
        environment["NOOK_VPN_BACKEND"] = os.environ.get("NOOK_VPN_BACKEND") or "wg"
    environment.update(case.env)
    for tool in ("qemu-system-x86_64", "qemu-img", "genisoimage", "curl", "ssh", "ssh-keygen", "openssl"):
        if not shutil.which(tool):
            raise CommandFailure(f"required VM tool missing: {tool}")
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        raise CommandFailure("selected VM suite requires accessible /dev/kvm")
    command(case.argv, cwd=private_repo, timeout=case.timeout, env=environment)
