import pytest

pytestmark = pytest.mark.quick
TOOLS = ("bash-syntax", "shellcheck", "ansible-syntax", "ansible-lint", "yamllint", "gitleaks", "ssot")


def tool_argv(name, root):
    scripts = ["install.sh"] + [str(p.relative_to(root)) for pattern in
               ("scripts/*.sh", "tests/validation/*.sh", "tests/e2e/*.sh") for p in sorted(root.glob(pattern))]
    return {"bash-syntax": ("bash", "-n", *scripts), "shellcheck": ("shellcheck", *scripts),
            "ansible-syntax": ("ansible-playbook", "--syntax-check", "site.yml"),
            "ansible-lint": ("ansible-lint", "--strict"), "yamllint": ("yamllint", "."),
            "gitleaks": ("pre-commit", "run", "gitleaks", "--all-files"),
            "ssot": ("bash", "scripts/verify-ssot.sh")}[name]


@pytest.mark.parametrize("tool", TOOLS)
def test_tool(tool, deployment_repo, command):
    argv = tool_argv(tool, deployment_repo)
    if tool == "bash-syntax":
        # bash -n with multiple filenames only parses the first one.
        for script in argv[2:]:
            command(("bash", "-n", script), cwd=deployment_repo)
    else:
        command(argv, cwd=deployment_repo)
