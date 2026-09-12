# Security model

Only SSH and WireGuard UDP are intended to be public. Administration interfaces
bind to localhost or the private network; Caddy serves internal HTTPS while
host TCP/443 stays closed. Server-side [traffic policy](configuration.md#traffic-policy)
restricts VPN peers independently of client AllowedIPs. Fail2Ban does not exempt
the VPN subnet by default.

## Trust boundaries

- The provider controls the hypervisor, network, console and external firewall.
- Root, the sudo administrator and Docker-group members are root-equivalent.
- Piping the installer to Bash trusts HTTPS. Signed-tag verification protects
  the subsequent checkout; [verify the downloaded installer first](getting-started.md#verified-installation)
  to establish trust before executing privileged code.
- Ansible Vault protects secrets at rest, not from a privileged running process.
  See [secret storage and rerun inputs](configuration.md#secret-boundary).
- Digest-pinned containers still share the Docker daemon and host kernel.

## Transaction boundaries

SSH configuration is validated before cutover; the new connection must succeed
before old-port access is removed. Service/socket recovery preserves the prior
path on failure. UFW/Docker integration enforces the managed network policy;
it cannot configure or verify a provider firewall.

Caddy validates the complete candidate, preserves the bind-mounted file inode,
reloads and restores prior bytes on failure. wg-easy bootstrap secrets are
scrubbed from Compose after initialization and on failure. Traffic-mode changes
preserve state for rollback. [Restore](operations.md#restore) stages archives,
then validates Compose and readiness after activation with rollback on failure.

## Operator responsibilities

Keep console access, encrypted off-host backups and trusted client devices.
Distribute only your own public Caddy CA and remove its trust when retiring the
server. Configure provider rules, monitoring and credential rotation separately.
The single-host design has no high availability; package/image downloads depend
on external registries and the host's TLS/DNS path.

Never publish inventories, vaults, private keys or raw production logs. Report
vulnerabilities privately through [SECURITY.md](../SECURITY.md).
