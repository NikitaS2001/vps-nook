# Configuration

The examples in `group_vars/all/` are the starting point for remote deployment.
Role argument specifications are the executable input contract; the role
references summarize the stable surface without duplicating every internal
default.

## Secret boundary

Keep ordinary settings in `group_vars/all/vars.yml`. Keep all credentials in
whole-file encrypted vaults:

- `vault_admin_password_hash`: a random SHA-512 crypt hash;
- `vault_adguard_password_hash`: a bcrypt hash;
- `vault_wg_easy_bootstrap_secret`: the initial wg-easy password;
- `vault_admin_ssh_pubkey`: the managed administrator public key.

`vars.yml` must reference the vault values:

```yaml
admin_password_hash: "{{ vault_admin_password_hash }}"
wg_easy_bootstrap_secret: "{{ vault_wg_easy_bootstrap_secret }}"
```

Do not define `admin_password`, `wg_easy_admin_password`, or put plaintext
credentials in inventory, Compose overrides, command arguments, or issues.
wg-easy bootstrap values are first-start inputs; later UI changes are not
silently replaced by Ansible.

The public installer maintains the same logical values in its private encrypted
vault under `/etc/vps-nook` and preserves them across reruns.

## Traffic policy

```yaml
wg_traffic_mode: services
```

`services` is the default and is enforced on the server. Clients can reach only
`wg_services_only_ipv4_destinations` and
`wg_services_only_ipv6_destinations`; modifying AllowedIPs on a client does not
bypass that policy.

```yaml
wg_traffic_mode: full
```

`full` provides IPv4 internet egress through the VPS and requires working IPv4
egress. IPv6 is added when the host proves IPv6 egress; otherwise generated
profiles omit `::/0`, so client IPv6 remains outside the VPN. The mode is applied
as a rollback-capable transaction. There is no `wg_enable_ipv6` input. Changing
modes requires an explicit configuration change and updated client profiles.

## Ports and identity

Review these values before the first run:

| Input | Purpose |
| --- | --- |
| `ssh_port` | Hardened SSH listener and provider firewall rule |
| `wg_port` | Public WireGuard UDP port |
| `admin_user` | Managed, sudo-capable administrator |
| `vault_admin_ssh_pubkey` | Exclusive managed SSH key by default |
| `wg_public_host` | Public address written to new client profiles |

The administrator belongs to the sudo and Docker groups. Docker access is
root-equivalent. By default, reruns remove unmanaged keys and extra groups from
that account; see the [hardening reference](../roles/vps_hardening/README.md)
before changing the exclusivity policy.

## Internal names

The default suffix is `internal`, producing `wg.internal` and
`adguard.internal`. To use the reserved home-network suffix:

```yaml
internal_domain_suffix: home.arpa
```

The derived names become `wg.home.arpa` and `adguard.home.arpa`. Explicit
`wg_internal_domain` and `adguard_internal_domain` overrides must end in the
configured suffix. Avoid `.local`, which conflicts with mDNS, and unreserved
suffixes such as `.lan` or `.home`.

## Network addresses

The Docker and WireGuard IPv4/IPv6 networks must be distinct. Static container
addresses must belong to the Docker networks, and service-only destinations
must belong to a managed Docker or VPN network. Change these values only when
they overlap an existing host or provider network.

## Package policy

The hardening role does not upgrade all packages by default. Set
`vps_hardening_apply_package_upgrade: true` only when the deployment should
apply the configured apt upgrade mode. Image and upstream installer references
are digest/checksum pinned in role defaults; update them through a reviewed code
change rather than local overrides.

Neither role manages swap or zram. A host with less than 900 MiB of RAM visible
to the OS is rejected even if it has swap; this threshold normally corresponds
to a 1 GB VPS plan after hypervisor reservations.

## Automated installer inputs

Run `bash install.sh --help` for the complete input contract. Set these variables
on the **Bash process executing the installer**, not on the curl process. Use a
protected automation secret store; do not put passwords in command arguments,
shell history or repository files.

| Variable | Meaning |
| --- | --- |
| `NOOK_NONINTERACTIVE=1` | Disable terminal prompts; required for automation |
| `NOOK_ADMIN_PASSWORD` | Fresh-install local account password, at least 8 characters |
| `NOOK_ADGUARD_PASSWORD` | Fresh-install DNS panel password, at least 8 characters and at most 72 UTF-8 bytes |
| `NOOK_WG_PASSWORD` | Fresh-install VPN panel password, at least 12 characters |
| `NOOK_SSH_PUBKEY` | Fresh-install administrator's OpenSSH public key |
| `NOOK_WG_HOST` | Public WireGuard hostname or IPv4; detected when omitted |
| `NOOK_WG_TRAFFIC_MODE` | `services` (default) or `full` |
| `NOOK_SSH_PORT`, `NOOK_WG_PORT` | Optional ports; defaults come from the roles |
| `NOOK_ADMIN_USER` | Optional administrator username |
| `NOOK_INTERNAL_DOMAIN_SUFFIX` | Optional internal DNS suffix |
| `NOOK_INTERNAL_DOMAINS` | Optional pair of distinct internal hostnames |

On rerun omit credential inputs. Supplied ordinary settings must match the saved
vault. The interactive wizard also reuses saved inputs; it cannot silently rotate
credentials or change routing.

`NOOK_DEV_MODE=1` allows `NOOK_REPO_URL` and `NOOK_RELEASE_REF` for disposable
development fixtures only. Production accepts the built-in repository and release.
`NO_COLOR` disables terminal colors. No progress control codes are emitted to logs.

For operational scripts, `NOOK_PROJECT_ROOT` selects an explicit project root and
`NOOK_KEEP_BACKUPS` sets backup retention. These are not installer path overrides.
All old `ZERO_TRUST_*` inputs are rejected, with values omitted from diagnostics.
