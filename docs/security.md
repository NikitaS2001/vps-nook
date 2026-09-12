# Security model

The project reduces public exposure; it does not make a compromised VPS or
administrator harmless.

## Trust boundaries

- The provider controls the hypervisor, network, console, and external
  firewall. Its control plane is outside this repository.
- The maintainer release process controls signed tags and attested release
  assets. Operators verify the downloaded installer before privileged use.
- The VPS root account, the managed sudo administrator, and members of the
  Docker group are root-equivalent.
- Ansible Vault protects secrets at rest, not while a privileged process is
  actively using them.
- A WireGuard peer is an authenticated network participant, not an
  administrator. Server-side traffic policy limits its destinations.

## Network exposure

Only hardened SSH and WireGuard UDP are intended to be public. wg-easy and
AdGuard bootstrap interfaces bind to localhost. Caddy provides HTTPS inside the
private Docker/VPN network, while host TCP/443 remains closed.

`services` is the default and applies IPv4/IPv6 destination policy on the
server. `full` requires IPv4 egress and includes IPv6 only when the host has
IPv6 egress; on IPv4-only hosts, profiles omit `::/0` and client IPv6 is not
tunneled. UFW is integrated with Docker's own iptables rules; provider firewall
rules remain an independent operator duty.

Fail2Ban does not trust the VPN subnet by default. A compromised peer therefore
does not receive an SSH brute-force exemption.

## Host changes

The hardening role installs a non-root administrator, disables SSH password and
root login, validates SSH before cutover, applies UFW default-deny rules, and
installs Fail2Ban. The previous SSH path is retained until the new path is
proven, with rollback on failure.

The roles require at least 900 MiB of RAM visible to the OS, normally a 1 GB
VPS plan after hypervisor reservations. Existing swap is observed only for
diagnostics and is never modified. Package upgrades are opt-in.

## Secrets

Remote deployments require whole-file encrypted Ansible Vault files with mode
`0600`. The public installer creates a root-owned encrypted vault and random
vault password under `/etc/vps-nook`. It removes temporary plaintext and
signer files on success or failure.

Credentials are not accepted through legacy plaintext variables. Compose does
not retain the wg-easy bootstrap secret after initial setup. Logs, inventories,
vault contents, private keys, and production evidence must not be posted in
issues or pull requests.

## Service configuration

Container images are digest pinned. Capabilities and bind mounts are limited to
the service needs, but containers share the security fate of the Docker daemon
and host kernel.

Caddy changes use a validate-stage-activate transaction. An invalid site does
not replace the active configuration; a failed reload restores the prior bytes.
Backup restore similarly validates in staging and rolls back the prior project
when activation fails.

## Accepted risks

- Initial package installation and image pulls depend on the configured public
  registries and the host's TLS/DNS path.
- The administrator and Docker group are intentionally root-equivalent.
- The internal Caddy CA must be distributed and trusted by each client.
- The project does not provision provider firewalls, off-host backups,
  monitoring, endpoint security, or automatic credential rotation.
- Single-host operation has no high-availability guarantee.

Report suspected vulnerabilities using [SECURITY.md](../SECURITY.md).
