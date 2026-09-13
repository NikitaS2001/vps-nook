# vps_hardening role

Applies the host baseline before service orchestration: minimum-host preflight,
packages, a managed administrator, transactional SSH cutover, sysctl, UFW, and
Fail2Ban.

Use this role through [`site.yml`](../../site.yml). The executable input contract
is [`meta/main.yml`](meta/main.yml); defaults are in
[`defaults/main.yml`](defaults/main.yml).

## Stable inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `ssh_port` | `2222` | Hardened SSH TCP port |
| `wg_port` | `51820` | WireGuard UDP port allowed by UFW |
| `admin_user` | `sysadmin` | Managed non-root administrator |
| `admin_group` | `sudo` | Privileged primary group |
| `admin_shell` | `/bin/bash` | Login shell |
| `admin_password_hash` | empty | Optional precomputed password hash; plaintext is rejected |
| `vault_admin_ssh_pubkey` | empty | Managed administrator public key |
| `vps_hardening_authorized_keys_exclusive` | `true` | Remove unmanaged administrator keys on convergence |
| `ssh_service_name` | `ssh` | OpenSSH service unit |
| `ssh_socket_name` | `ssh.socket` | OpenSSH socket unit when socket activation exists |
| `ssh_allow_tcp_forwarding` | `yes` | OpenSSH forwarding policy |
| `vps_hardening_manage_ssh_socket` | `true` | Let `sshd_config` own the hardened port |
| `wg_easy_bootstrap_ui_port` | `51821` | Localhost wg-easy forwarding destination |
| `adguard_bootstrap_ui_port` | `3000` | Localhost AdGuard forwarding destination |
| `fail2ban_ignore_ips` | loopback only | Addresses exempt from Fail2Ban |
| `fail2ban_bantime` | `3600` | Ban duration in seconds |
| `fail2ban_findtime` | `600` | Retry observation window in seconds |
| `fail2ban_maxretry` | `5` | Attempts allowed before a ban |
| `vps_hardening_apply_package_upgrade` | `false` | Apply the selected apt upgrade before installation |
| `vps_hardening_package_upgrade_mode` | `safe` | Supported apt upgrade policy |
| `vps_hardening_enable_ufw_on_local_connection` | `false` | Installer-only opt-in for local Ansible |

## Preconditions and effects

- Enforces the [supported VPS baseline](../../README.md#before-you-start).
- The public installer reports existing swap for diagnostics; this role never
  changes swap or zram.
- `sudo` is installed before the managed user is created.
- Password and root SSH login are disabled. Candidate SSH configuration and
  reachability are validated before the old path is removed; failures restore
  the previous state.
- UFW defaults to deny incoming traffic and allows managed SSH and WireGuard
  ports. Provider firewall configuration remains the operator's responsibility.
- The administrator is reconciled to the privileged and Docker groups. Both
  sudo and Docker access are root-equivalent.
- The VPN subnet is not ignored by Fail2Ban by default.

Check mode is not a reliable change predictor because safe cutover requires
runtime probes. Test on a disposable host or use the E2E matrix instead.

## Tags

| Tag | Boundary |
| --- | --- |
| `preflight` | Platform, memory, input, and secret validation |
| `packages` | apt packages and optional upgrades |
| `user` | Administrator, sudo, groups, and SSH key |
| `ssh` | SSH candidate, cutover, proof, and rollback |
| `sysctl` | Managed kernel settings |
| `ufw` | Host firewall |
| `fail2ban` | SSH brute-force protection |
| `ssh_ufw_cleanup` | Proven-old-path cleanup |

The role has no external Ansible role dependency. It must run before
[`vps_orchestration`](../vps_orchestration/README.md).
