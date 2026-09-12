#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'SBOM FAIL: %s\n' "$*" >&2; exit 1; }

tag=''
sha=''
output=''
while (($#)); do
    (($# >= 2)) || fail "usage: $0 --tag TAG --sha SHA --output FILE"
    case "$1" in
        --tag) tag="$2" ;;
        --sha) sha="$2" ;;
        --output) output="$2" ;;
        *) fail "usage: $0 --tag TAG --sha SHA --output FILE" ;;
    esac
    shift 2
done
[[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ \
    && "${sha}" =~ ^[0-9a-f]{40}$ \
    && -n "${output}" ]] || fail "invalid arguments"
[[ ! -e "${output}" && ! -L "${output}" && -d "$(dirname "${output}")" ]] \
    || fail "output must be a new file in an existing directory"
[[ "$(git -C "${ROOT_DIR}" rev-parse --verify "${sha}^{commit}" 2>/dev/null || true)" == "${sha}" ]] \
    || fail "source SHA is not an exact local commit"

python3 - "${ROOT_DIR}" "${tag}" "${sha}" "${output}" <<'PY'
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote

root, tag, sha, output = sys.argv[1:]

def git(*arguments: str, text: bool = True):
    return subprocess.check_output(["git", "-C", root, *arguments], text=text)

def tagged(path: str) -> str:
    return git("show", f"{sha}:{path}")

installer = tagged("install.sh")
runtime_command = re.search(
    r'^\s*"\$\{VENV_DIR\}/bin/pip"\s+install\s+--quiet\s+\\\n'
    r'(?P<arguments>(?:\s*"[^"\n]+"\s*)+)$',
    installer,
    re.MULTILINE,
)
if runtime_command is None:
    raise SystemExit("SBOM FAIL: exact installer runtime command not found")
runtime_pins = []
for argument in re.findall(r'"([^"\n]+)"', runtime_command.group("arguments")):
    match = re.fullmatch(
        r"(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)==(?P<version>[^=\s]+)",
        argument,
    )
    if match is None:
        raise SystemExit(f"SBOM FAIL: installer runtime is not pinned exactly: {argument}")
    runtime_pins.append((match.group("name"), match.group("version")))
if not runtime_pins:
    raise SystemExit("SBOM FAIL: no exact installer runtime dependencies found")

requirements = tagged("requirements.yml")
raw_collections = re.findall(
    r"^\s*- name:\s*([^\s]+)\s*\n\s*version:\s*[\"']([^\"']+)[\"']\s*$",
    requirements,
    re.MULTILINE,
)
if not raw_collections:
    raise SystemExit("SBOM FAIL: no exact Ansible collection dependencies found")
collections = []
for name, constraint in raw_collections:
    if not constraint.startswith("==") or constraint[2:].startswith("=") or len(constraint) <= 2:
        raise SystemExit(f"SBOM FAIL: collection is not pinned exactly: {name}")
    collections.append((name, constraint[2:]))

defaults_text = tagged("roles/vps_orchestration/defaults/main.yml")
defaults = dict(re.findall(
    r"^([a-z0-9_]+):\s*[\"']?([^\"'\n#]+?)[\"']?\s*$",
    defaults_text,
    re.MULTILINE,
))
template = tagged("roles/vps_orchestration/templates/docker-compose.yml.j2")
image_templates = re.findall(r"^\s*image:\s*(\S.*)$", template, re.MULTILINE)
images = []
for candidate in image_templates:
    resolved = re.sub(
        r"{{\s*([a-z0-9_]+)\s*}}",
        lambda match: defaults.get(match.group(1), match.group(0)),
        candidate,
    )
    if "{{" in resolved or any(character.isspace() for character in resolved):
        raise SystemExit(f"SBOM FAIL: unresolved image reference: {resolved}")
    images.append(resolved)
if not images:
    raise SystemExit("SBOM FAIL: no OCI dependencies found")

epoch = int(git("show", "-s", "--format=%ct", sha).strip())
created = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
source_digest = hashlib.sha256(git("ls-tree", "-r", "-z", "--full-tree", sha, text=False)).hexdigest()

def base_package(spdx_id: str, name: str, version: str, location: str) -> dict:
    return {
        "SPDXID": spdx_id,
        "name": name,
        "versionInfo": version,
        "downloadLocation": location,
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "NOASSERTION",
        "copyrightText": "NOASSERTION",
    }

source = base_package(
    "SPDXRef-Package-Source",
    "vps-nook",
    tag,
    f"git+https://github.com/NikitaS2001/vps-nook.git@{sha}",
)
source["checksums"] = [
    {"algorithm": "SHA1", "checksumValue": sha},
    {"algorithm": "SHA256", "checksumValue": source_digest},
]

dependencies = []
for name, version in runtime_pins:
    normalized_name = re.sub(r"[-_.]+", "-", name).lower()
    package = base_package(
        "SPDXRef-Python-" + re.sub(r"[^A-Za-z0-9.-]", "-", normalized_name),
        name,
        version,
        "NOASSERTION",
    )
    package["externalRefs"] = [{
        "referenceCategory": "PACKAGE-MANAGER",
        "referenceType": "purl",
        "referenceLocator": f"pkg:pypi/{normalized_name}@{quote(version, safe='')}",
    }]
    dependencies.append(package)
for name, version in collections:
    package = base_package(
        "SPDXRef-Collection-" + re.sub(r"[^A-Za-z0-9.-]", "-", name),
        name,
        version,
        "NOASSERTION",
    )
    package["externalRefs"] = [{
        "referenceCategory": "PACKAGE-MANAGER",
        "referenceType": "purl",
        "referenceLocator": f"pkg:generic/{name}@{version}",
    }]
    dependencies.append(package)
for image in images:
    identifier = hashlib.sha256(image.encode()).hexdigest()[:16]
    dependencies.append(base_package(
        f"SPDXRef-OCI-{identifier}",
        image.split("@", 1)[0].rsplit(":", 1)[0],
        image.rsplit(":", 1)[-1],
        image,
    ))

document = {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": f"vps-nook-{tag}",
    "documentNamespace": (
        "https://github.com/NikitaS2001/vps-nook/"
        f"releases/download/{tag}/sbom.spdx.json?sha={sha}"
    ),
    "creationInfo": {
        "created": created,
        "creators": ["Tool: scripts/build-spdx-sbom.sh"],
    },
    "packages": [source, *sorted(dependencies, key=lambda item: item["SPDXID"])],
    "relationships": [
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": source["SPDXID"],
        },
        *[
            {
                "spdxElementId": source["SPDXID"],
                "relationshipType": "DEPENDS_ON",
                "relatedSpdxElement": dependency["SPDXID"],
            }
            for dependency in sorted(dependencies, key=lambda item: item["SPDXID"])
        ],
    ],
}

destination = Path(output)
destination.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
destination.chmod(0o600)
PY
