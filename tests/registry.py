"""Single registry of retained executable contracts; collection never executes commands."""
import ast
import re
from dataclasses import dataclass
from pathlib import Path

@dataclass(frozen=True)
class Case:
    id: str
    marks: tuple[str, ...]
    argv: tuple[str, ...]
    timeout: int = 900

CONTRACTS = (
    Case('ansible-runtime', ('quick',), ("bash", "tests/validation/ansible-runtime.sh")),
    Case('backup-sandbox', ('quick',), ("bash", "tests/validation/backup-sandbox.sh")),
    Case('installer-contract', ('quick',), ("bash", "tests/validation/installer-contract.sh")),
    Case('secret-installer-contract', ('quick',), ("bash", "tests/validation/secret-installer-contract.sh")),
    Case('restore-sandbox', ('quick',), ("bash", "tests/validation/restore-sandbox.sh")),
    Case('compose-render', ('quick',), ("bash", "tests/validation/compose-render.sh")),
    Case('traffic-mode-contract', ('quick',), ("bash", "tests/validation/traffic-mode-contract.sh")),
    Case('hardening-contract', ('quick',), ("bash", "tests/validation/hardening-contract.sh")),
    Case('orchestration-core', ('quick',), ("bash", "tests/validation/orchestration-core.sh")),
    Case('ufw-docker-idempotency', ('quick',), ("bash", "tests/validation/ufw-docker-idempotency.sh")),
    Case('workflow-contract', ('quick',), ("bash", "tests/validation/workflow-contract.sh")),
    Case('qemu-source-contract', ('quick',), ("bash", "tests/validation/qemu-source-contract.sh")),
    Case('qemu-packet-contract', ('quick',), ("bash", "tests/validation/qemu-packet-contract.sh")),
    Case('sbom-contract', ('quick', 'release'), ("bash", "tests/validation/sbom-contract.sh")),
    Case('fixture-git-signing-contract', ('quick',), ("bash", "tests/validation/fixture-git-signing-contract.sh")),
    Case('release-artifacts-contract', ("release",), ("bash", "tests/validation/release-artifacts-contract.sh")),
    Case('release-workflow-contract', ("release",), ("bash", "tests/validation/release-workflow-contract.sh")),
    Case('release-publish-contract', ("release",), ("bash", "tests/validation/release-publish-contract.sh")),
    Case('release-contract', ("release",), ("bash", "tests/validation/release-contract.sh")),
    Case("release-pr", ("release",), ("bash", "scripts/release-contract.sh", "--pr")),
)
VMS = (
    Case("qemu-services", ("qemu",), ("bash", "tests/e2e/qemu-install.sh",
         "--client-test", "--idempotency-test", "--reboot-test", "--bootstrap-timeout-test",
         "--stopped-container-test", "--invalid-caddy-test"), 4200),
    Case("lifecycle-upgrade-restore", ("lifecycle",), ("bash", "tests/e2e/lifecycle-qemu.sh"), 4800),
    Case("remote-ssh", ("remote",), ("bash", "tests/e2e/qemu-remote-install.sh",
         "--ssh-rollback-test", "--ssh-cutover-test", "--reboot-test", "--ufw-backend-failure-test"), 4200),
)

# Required native boundaries from the migration map. Real SSH remains in VMS.
NATIVE = {
    "installer-ux.sh": ("tests/installer/test_ux.py", tuple("test_installer_" + name for name in (
        "defaults", "colors", "cancel", "edit_invalid_port", "ctrl_c", "eof", "password_length",
        "utf8", "password_confirmation", "legacy_variable", "legacy_path", "no_tty", "saved_state",
        "noninteractive", "noninteractive_utf8", "truncated", "sudo"))),
    "ssh-recovery.sh": ("tests/contracts/test_ssh_recovery.py", ("test_ssh_recovery_mocked_systemd",)),
    "check-tooling.sh": ("tests/runner/test_runner.py", (
        "test_wrapper_selection", "test_wrapper_failure", "test_wrapper_arguments", "test_bootstrap_help",
        "test_registry_rejects_loss", "test_command_stdin_exit_and_private_log", "test_gitleaks_hook_no_recursion")),
}


def validate_registry(root: Path, contracts=CONTRACTS, vms=VMS):
    cases = (*contracts, *vms)
    ids = [case.id for case in cases]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate scenario ID")
    registered = [case.argv[1] for case in contracts if case.argv[1].startswith("tests/validation/")]
    present = {str(path.relative_to(root)) for path in (root / "tests/validation").glob("*.sh")}
    if set(registered) != present or len(registered) != len(set(registered)):
        raise ValueError("Bash contract registration is incomplete or duplicated")
    if {case.marks for case in vms} != {("qemu",), ("lifecycle",), ("remote",)}:
        raise ValueError("required VM scenario is missing")
    for case in cases:
        if not (root / case.argv[1]).is_file():
            raise ValueError("registered script is missing: " + case.id)
    # The reviewed migration map protects mandatory historical boundaries even
    # if a script and its registry entry are accidentally removed together.
    historical = set(re.findall(r"^\| `([a-z-]+\.sh)(?: --self-test)?`",
                                (root / "docs/pytest-migration.md").read_text(), re.MULTILINE))
    if historical - set(NATIVE) - {Path(path).name for path in registered}:
        raise ValueError("required historical contract is missing")
    for filename, (path, required) in NATIVE.items():
        if filename not in historical or not (root / path).is_file():
            raise ValueError("required native fixture is missing")
        functions = {node.name for node in ast.parse((root / path).read_text()).body
                     if isinstance(node, ast.FunctionDef)}
        if not set(required) <= functions:
            raise ValueError("required native scenario is missing")
        if filename == "ssh-recovery.sh":
            function = next(node for node in ast.parse((root / path).read_text()).body
                            if isinstance(node, ast.FunctionDef) and node.name == required[0])
            axes = {}
            for decorator in function.decorator_list:
                if isinstance(decorator, ast.Call) and isinstance(decorator.func, ast.Attribute) \
                        and decorator.func.attr == "parametrize":
                    axes[ast.literal_eval(decorator.args[0])] = ast.literal_eval(decorator.args[1])
            if axes != {"active": [False, True], "socket_active": [False, True]}:
                raise ValueError("required four-case SSH recovery matrix is missing")
