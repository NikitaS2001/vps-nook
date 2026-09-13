# Documentation

Start with [Getting started](getting-started.md) for either the verified public
installer or a remote Ansible controller. v2.0.0 installation URLs remain
previews until publication; see [compatibility](../UPGRADE.md).

| Guide | Use it when |
| --- | --- |
| [Getting started](getting-started.md) | Installing and connecting the first client |
| [Configuration](configuration.md) | Selecting traffic policy, names, ports, and encrypted inputs |
| [Operations](operations.md) | Checking health, backing up, restoring, upgrading, or recovering access |
| [Security](security.md) | Reviewing trust boundaries, exposure, and accepted risks |
| [Extensions](extensions.md) | Placing another service behind VPN-only HTTPS |
| [Releasing](releasing.md) | Preparing and publishing a maintainer release |

The [hardening role](../roles/vps_hardening/README.md) and
[orchestration role](../roles/vps_orchestration/README.md) pages are compact
input/tag references. The [E2E reference](../tests/e2e/README.md) owns the test
matrix and command-line flags. Contributor setup belongs in
[CONTRIBUTING.md](../CONTRIBUTING.md).

Documentation is plain GitHub Markdown. Each fact should have one canonical
home; link to it instead of copying it into another page.
