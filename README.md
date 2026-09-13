# VPS Nook

**WireGuard, private DNS, and HTTPS on your VPS.**

[![CI](https://github.com/NikitaS2001/vps-nook/actions/workflows/ci.yml/badge.svg)](https://github.com/NikitaS2001/vps-nook/actions/workflows/ci.yml)
[![Weekly](https://github.com/NikitaS2001/vps-nook/actions/workflows/weekly.yml/badge.svg)](https://github.com/NikitaS2001/vps-nook/actions/workflows/weekly.yml)
[![Release](https://img.shields.io/github/v/release/NikitaS2001/vps-nook)](https://github.com/NikitaS2001/vps-nook/releases)

A small, self-hosted network on one server. Ansible configures the host and
runs three services; you manage VPN clients through a web interface.

| Service | What you get |
| --- | --- |
| WireGuard / wg-easy | VPN connections and client management |
| AdGuard Home | DNS filtering and private service names |
| Caddy | HTTPS for services inside your VPN |

SSH and WireGuard UDP are public. Administration panels stay on localhost or
inside the VPN. The default VPN mode reaches private services only; choose
**All internet traffic** during setup for an internet gateway.

## Before you start

- A **fresh Debian 12 or Ubuntu 24.04**, amd64 VPS.
- A **1 GB RAM** plan, with at least 900 MiB visible to the OS.
- Root or sudo access, an SSH terminal, and your computer's SSH public key.
- TUN, WireGuard and Docker networking support, plus outbound internet access.
- Provider console access in case you need to recover SSH.

> Installation changes SSH and the firewall. Open **TCP 2222** and
> **UDP 51820** in your provider firewall first, or your chosen custom ports.
> Keep your original SSH session open until a new key-based login succeeds.

## Install

For a fresh installation, download the installer from the latest published
stable release. v1 has no supported in-place upgrade: use a fresh VPS and read
[UPGRADE.md](UPGRADE.md).

<!-- ssot:quickstart:start -->
<!-- release-installer: post-merge-maintainer-publication -->
```bash
curl -fsSL https://github.com/NikitaS2001/vps-nook/releases/latest/download/install.sh | bash
```
<!-- ssot:quickstart:end -->

Run this command as root on your VPS. The wizard asks for your VPN purpose,
endpoint, SSH public key and three passwords. Press Enter to keep defaults;
ports and internal domains are available under additional settings. Review the
settings before applying them.

The downloaded bootstrap has its official release tag embedded in it. It
verifies that SSH-signed tag and checks out its exact commit. For a reproducible,
version-pinned installation, use the
[verified installation](docs/getting-started.md#verified-installation). For
reruns, recovery, or upgrades, use the same pinned tag and follow
[UPGRADE.md](UPGRADE.md).

Piping to Bash trusts the HTTPS source of the script you execute. Prefer
verification before execution? Follow the [verified installation](docs/getting-started.md#verified-installation).
That guide also covers sudo, installing curl, and remote Ansible deployment.

## Connect your first device

Confirm a new SSH login, tunnel to wg-easy, import a WireGuard client profile,
and trust your server's Caddy CA. Follow [the connection guide](docs/getting-started.md#first-wireguard-client);
the installer prints your actual ports, names and certificate location.

## Keep it running

- [Health checks, backups and recovery](docs/operations.md)
- [Configuration and automated installation](docs/configuration.md)
- [Security model and limitations](docs/security.md)
- [Adding a private service](docs/extensions.md)
- [Development](CONTRIBUTING.md) and [release process](docs/releasing.md)

VPS Nook is a personal open-source project, maintained on a best-effort basis.
It does not provide high availability, provider firewall management or a support
SLA. Off-host backups and alerting remain your responsibility.

Report vulnerabilities privately through [SECURITY.md](SECURITY.md).
Licensed under [MIT](LICENSE).
