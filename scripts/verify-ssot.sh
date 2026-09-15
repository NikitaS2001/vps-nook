#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR
cd "${ROOT_DIR}"

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

command -v python3 >/dev/null || fail 'python3 is required'

python3 - "${ROOT_DIR}" <<'PY'
from __future__ import annotations

import re
import shlex
import sys
from os import environ, readlink
from pathlib import Path
from urllib.parse import unquote

import yaml

root = Path(sys.argv[1]).resolve()
errors: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def read(relative: str) -> str:
    path = root / relative
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        errors.append(f"cannot read {relative}: {error}")
        return ""


def read_override(variable: str, relative: str) -> str:
    override = environ.get(variable)
    if not override:
        return read(relative)
    path = Path(override)
    try:
        return path.read_bytes().decode("utf-8")
    except (OSError, UnicodeError) as error:
        errors.append(f"cannot read {variable}={path}: {error}")
        return ""


alias = root / "CLAUDE.md"
canonical = root / "AGENTS.md"
try:
    valid_alias = (
        alias.is_symlink()
        and readlink(alias) == "AGENTS.md"
        and not canonical.is_symlink()
        and canonical.is_file()
        and alias.resolve(strict=True) == canonical
    )
except (OSError, RuntimeError):
    valid_alias = False
check(valid_alias, "CLAUDE.md must be a relative symlink to the regular repository-root AGENTS.md")
if errors:
    for error in errors:
        print(f"[FAIL] {error}", file=sys.stderr)
    sys.exit(1)


def github_slug(heading: str) -> str:
    value = re.sub(r"<[^>]+>", "", heading.strip().lower())
    value = re.sub(r"[^\w\- ]", "", value, flags=re.UNICODE)
    return value.replace(" ", "-")


required_docs = {
    "README.md",
    "getting-started.md",
    "configuration.md",
    "operations.md",
    "security.md",
    "extensions.md",
    "releasing.md",
}
actual_docs = {path.name for path in (root / "docs").glob("*.md")}
check(required_docs <= actual_docs,
      f"docs/ is missing required pages: {sorted(required_docs - actual_docs)}")

readme = read_override("VERIFY_SSOT_README_PATH", "README.md")

release_url_pattern = re.compile(
    r"https://github\.com/NikitaS2001/vps-nook/releases/"
    r"(?:latest/download|download/v[0-9]+\.[0-9]+\.[0-9]+)/install\.sh"
)
publication_marker = "<!-- release-installer: post-merge-maintainer-publication -->"
release_statuses: dict[str, int] = {}
status_fixture = environ.get("VERIFY_SSOT_RELEASE_STATUS_FIXTURE")
if status_fixture:
    try:
        status_lines = Path(status_fixture).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        errors.append(f"cannot read release URL status fixture {status_fixture}: {error}")
        status_lines = []
    for line_number, line in enumerate(status_lines, start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(f"({release_url_pattern.pattern}) ([1-5][0-9]{{2}})", line)
        if not match:
            errors.append(f"status fixture malformed row {line_number}: {line}")
            continue
        url, raw_status = match.groups()
        if url in release_statuses:
            errors.append(f"{url} duplicate status fixture row")
            continue
        release_statuses[url] = int(raw_status)


def strip_shell_comment(command: str) -> str:
    quote = ""
    escaped = False
    for index, character in enumerate(command):
        if escaped:
            escaped = False
            continue
        if character == "\\" and quote != "'":
            escaped = True
            continue
        if character in {"'", '"'}:
            if not quote:
                quote = character
            elif quote == character:
                quote = ""
            continue
        if character == "#" and not quote and (index == 0 or command[index - 1].isspace()):
            return command[:index]
    return command


def shell_line_state(line: str, initial_quote: str) -> tuple[str, bool]:
    quote = initial_quote
    index = 0
    while index < len(line):
        character = line[index]
        if character == "#" and not quote and (index == 0 or line[index - 1].isspace()):
            break
        if character == "\\" and quote != "'":
            if index == len(line) - 1:
                return quote, True
            index += 2
            continue
        if character in {"'", '"'}:
            if not quote:
                quote = character
            elif quote == character:
                quote = ""
        index += 1
    return quote, False


def logical_commands(lines: list[str]) -> list[str]:
    commands: list[str] = []
    pending = ""
    quote = ""
    for line in lines:
        quote, continued = shell_line_state(line, quote)
        if continued:
            pending += line[:-1]
            continue
        if quote:
            pending += line + "\n"
            continue
        commands.append(pending + line)
        pending = ""
    if pending:
        commands.append(pending)
    return commands


def check_release_command(command: str, marker_present: bool, relative: Path) -> None:
    executable = strip_shell_comment(command)
    urls = release_url_pattern.findall(executable)
    if not urls:
        return
    ambiguous = any(item in executable for item in ("$", "<<", ">>", "<(", ">(", ";", "&&", "||", "\\\n"))
    try:
        lexer = shlex.shlex(executable, posix=True, punctuation_chars="|;&<>()")
        lexer.whitespace_split = True
        lexer.commenters = "#"
        tokens = list(lexer)
    except ValueError:
        tokens = []
        ambiguous = True
    if any(token in {";", "&", "&&", "||", "<", ">", "<<", ">>", "(", ")"} for token in tokens):
        ambiguous = True
    if ambiguous:
        for url in dict.fromkeys(urls):
            errors.append(f"{relative}: {url} unsupported/ambiguous executable syntax")
        return

    stages: list[list[str]] = [[]]
    for token in tokens:
        if token == "|":
            stages.append([])
        else:
            stages[-1].append(token)
    findings: list[str] = []
    for index, stage in enumerate(stages[:-1]):
        if not stage or stage[0] not in {"curl", "wget"}:
            continue
        stage_urls = [token for token in stage if release_url_pattern.fullmatch(token)]
        consumer = stages[index + 1]
        if consumer in (["bash"], ["sh"], ["sudo", "bash"], ["sudo", "sh"]):
            findings.extend(stage_urls)

    if not findings and "|" in tokens and any(token in {"curl", "wget", "bash", "sh"} for token in tokens):
        for url in dict.fromkeys(urls):
            errors.append(f"{relative}: {url} unsupported/ambiguous executable syntax")
        return
    for url in dict.fromkeys(findings):
        if not marker_present:
            errors.append(f"{relative}: {url} missing structural marker")
        status = release_statuses.get(url)
        if status is None:
            errors.append(f"{relative}: {url} HTTP missing")
        elif not 200 <= status < 300:
            errors.append(f"{relative}: {url} HTTP {status}")


def check_release_installer_blocks(text: str, relative: Path) -> None:
    in_fence = False
    shell_fence = False
    fence = ""
    marker_present = False
    block: list[str] = []
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    for line_number, line in enumerate(lines, start=1):
        syntax_line = line.removesuffix("\r")
        if not in_fence:
            shell_match = re.fullmatch(r"((?:`{3,}|~{3,}))(bash|sh|shell)[ \t]*", syntax_line)
            if shell_match:
                in_fence = True
                shell_fence = True
                fence = shell_match.group(1)
                marker_present = line_number > 1 and lines[line_number - 2].removesuffix("\r") == publication_marker
                block = []
            else:
                fence_match = re.match(r"((?:`{3,}|~{3,}))", syntax_line)
                if not fence_match:
                    continue
                fence = fence_match.group(1)
                if re.match(r"(?:`{3,}|~{3,})(?:bash|sh|shell)\b", syntax_line):
                    errors.append(f"{relative}: malformed executable-doc input at line {line_number}")
                in_fence = True
                shell_fence = False
            continue
        if syntax_line.rstrip() == fence:
            if shell_fence:
                for command in logical_commands(block):
                    check_release_command(command, marker_present, relative)
            in_fence = False
            shell_fence = False
            block = []
        elif shell_fence:
            block.append(line)
    if in_fence and shell_fence:
        errors.append(f"{relative}: malformed executable-doc input: unclosed shell fence")


if environ.get("VERIFY_SSOT_README_PATH"):
    check_release_installer_blocks(readme, Path("README.md"))
    if errors:
        for error in errors:
            print(f"[FAIL] {error}", file=sys.stderr)
        raise SystemExit(1)
    print("[PASS] release installer fixture contract")
    raise SystemExit(0)

start_marker = "<!-- ssot:verified-quickstart:start -->"
end_marker = "<!-- ssot:verified-quickstart:end -->"
verified_doc = read("docs/getting-started.md")
check(verified_doc.count(start_marker) == 1 and verified_doc.count(end_marker) == 1,
      "Getting started must contain one verified-quickstart marker pair")
quickstart = ""
if start_marker in verified_doc and end_marker in verified_doc:
    quickstart = verified_doc.split(start_marker, 1)[1].split(end_marker, 1)[0]

installer = read("install.sh")
release_match = re.search(
    r'^readonly OFFICIAL_RELEASE_REF="(v[0-9]+\.[0-9]+\.[0-9]+)"$',
    installer,
    re.MULTILINE,
)
release_ref = release_match.group(1) if release_match else ""
check(bool(release_ref), "install.sh must define a SemVer OFFICIAL_RELEASE_REF")
quick_start = "<!-- ssot:quickstart:start -->"
quick_end = "<!-- ssot:quickstart:end -->"
check(readme.count(quick_start) == 1 and readme.count(quick_end) == 1,
      "README must contain one quickstart marker pair")
preview = readme.split(quick_start, 1)[-1].split(quick_end, 1)[0]
latest_command = "curl -fsSL https://github.com/NikitaS2001/vps-nook/releases/latest/download/install.sh | bash"
check(latest_command in preview, "quickstart must use the latest published release")
check("/main/install.sh" not in readme and "/raw/main/" not in readme,
      "public installation must not execute installer bytes from main")
check("HTTPS source" in readme, "quickstart must describe its trust boundary")
required_quickstart_fragments = [
    f"gh release download {release_ref}",
    "--repo NikitaS2001/vps-nook",
    "--pattern install.sh",
    "--pattern install.sh.sha256",
    "gh attestation verify install.sh",
    "--signer-workflow",
    "NikitaS2001/vps-nook/.github/workflows/release.yml",
    f"--source-ref refs/tags/{release_ref}",
    "sha256sum --check install.sh.sha256",
    "sudo bash ./install.sh",
]
positions = [quickstart.find(fragment) for fragment in required_quickstart_fragments]
check(all(position >= 0 for position in positions),
      "verified quick start is missing a required download/attestation/checksum/local-execution step")
check(positions == sorted(positions), "verified quick start steps are out of order")
check("curl" not in quickstart and "| sudo" not in quickstart,
      "verified quick start must execute only verified local bytes")

getting_started = read("docs/getting-started.md")
controller_steps = [
    getting_started.find("./scripts/bootstrap.sh"),
    getting_started.find("ansible-vault encrypt"),
    getting_started.find("ansible-playbook --ask-vault-pass --syntax-check"),
    getting_started.find("ansible-playbook --ask-vault-pass site.yml"),
]
check(all(position >= 0 for position in controller_steps),
      "remote controller path is missing a bootstrap, vault, or playbook step")
check(controller_steps == sorted(controller_steps),
      "remote controller path must bootstrap tools before the first Ansible command")

expected_assets = {
    "CHANGELOG.md",
    "RELEASE_NOTES.md",
    "SHA256SUMS",
    "UPGRADE.md",
    "install.sh",
    "install.sh.sha256",
    "sbom.spdx.json",
}
workflow = read(".github/workflows/release.yml")
workflow_assets = set(re.findall(r"^\s+release/([A-Za-z0-9._-]+)\s*\\?$", workflow, re.MULTILINE))
check(workflow_assets == expected_assets,
      f"release workflow assets differ from contract: {sorted(workflow_assets)}")
releasing = read("docs/releasing.md")
release_section = releasing.split("The protected `release.yml` workflow", 1)[-1]
release_section = release_section.split("## Publish", 1)[0]
documented_assets = set(re.findall(r"^- `([^`]+)`$", release_section, re.MULTILINE))
check(documented_assets == expected_assets,
      f"docs/releasing.md assets differ from contract: {sorted(documented_assets)}")
check("scripts/publish-release.sh" in releasing,
      "docs/releasing.md must name the local final publisher")
check("--draft=false" in read("scripts/publish-release.sh"),
      "local publisher must perform the final draft-to-public transition")
check("/releases/latest" in read("scripts/publish-release.sh"),
      "local publisher must verify GitHub's latest release after publication")

def table_inputs(relative: str) -> set[str]:
    text = read(relative)
    section = text.split("## Stable inputs", 1)[-1].split("\n## ", 1)[0]
    return set(re.findall(r"^\| `([a-z][a-z0-9_]*)` \|", section, re.MULTILINE))


def argument_inputs(relative: str) -> set[str]:
    data = yaml.safe_load(read(relative)) or {}
    return set(data.get("argument_specs", {}).get("main", {}).get("options", {}))


for doc, spec in (
    ("roles/vps_hardening/README.md", "roles/vps_hardening/meta/main.yml"),
    ("roles/vps_orchestration/README.md", "roles/vps_orchestration/meta/argument_specs.yml"),
):
    documented = table_inputs(doc)
    declared = argument_inputs(spec)
    check(documented == declared,
          f"{doc} input table differs from {spec}: missing={sorted(declared - documented)}, "
          f"extra={sorted(documented - declared)}")

markdown_files = []
for path in root.rglob("*.md"):
    relative_parts = path.relative_to(root).parts
    if any(part in {".git", ".omo", ".venv", "node_modules"} for part in relative_parts):
        continue
    markdown_files.append(path)

code_blocks = 0
local_links = 0
for path in markdown_files:
    relative = path.relative_to(root)
    text = readme if relative == Path("README.md") else read(str(relative))
    try:
        structural_text = readme if relative == Path("README.md") else path.read_bytes().decode("utf-8")
    except (OSError, UnicodeError):
        structural_text = text
    check_release_installer_blocks(structural_text, relative)
    check(re.search(r"[\u0400-\u04ff]", text) is None,
          f"{relative} contains Cyrillic; public documentation is English")

    fence_lines = [line for line in text.splitlines() if line.startswith("```")]
    check(len(fence_lines) % 2 == 0, f"{relative} has unbalanced fenced code blocks")
    in_fence = False
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line.startswith("```"):
            continue
        if not in_fence:
            code_blocks += 1
        in_fence = not in_fence

    headings: set[str] = set()
    for match in re.finditer(r"^#{1,6}\s+(.+?)\s*$", text, re.MULTILINE):
        slug = github_slug(match.group(1))
        if slug:
            headings.add(slug)

    for match in re.finditer(r"(?<!!)\[[^]]*\]\(([^)]+)\)", text):
        raw_target = match.group(1).strip()
        target = raw_target.split(" ", 1)[0].strip("<>")
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        local_links += 1
        file_part, separator, anchor = target.partition("#")
        target_path = path if not file_part else (path.parent / unquote(file_part)).resolve()
        try:
            target_path.relative_to(root)
        except ValueError:
            errors.append(f"{relative} link escapes repository: {target}")
            continue
        check(target_path.exists(), f"{relative} has broken local link: {target}")
        if anchor and target_path.exists() and target_path.suffix.lower() == ".md":
            target_text = target_path.read_text(encoding="utf-8")
            target_headings = {
                github_slug(item.group(1))
                for item in re.finditer(r"^#{1,6}\s+(.+?)\s*$", target_text, re.MULTILINE)
            }
            check(unquote(anchor).lower() in target_headings,
                  f"{relative} has broken Markdown anchor: {target}")

check("pytest==9.1.1" in read("requirements-dev.txt"), "pytest development pin is missing")
check((root / "pytest.ini").is_file(), "pytest configuration is missing")
check((root / "tests/registry.py").is_file(), "pytest contract registry is missing")
check(not (root / "tests/validation/manifest.txt").exists(), "legacy test dispatcher manifest remains")

if errors:
    for error in errors:
        print(f"[FAIL] {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"[PASS] verified installer sequence release={release_ref}")
print(f"[PASS] docs_required={len(required_docs)} docs_present={len(actual_docs)} markdown_files={len(markdown_files)} "
      f"local_links={local_links} code_blocks={code_blocks} cyrillic=0")
print("[PASS] role_input_tables=2 release_assets=7 local_publisher=verified")
PY
