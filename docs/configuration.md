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

Set `wg_traffic_mode` explicitly when changing policy:

| Mode | Behavior |
| --- | --- |
| `services` (default) | Server-enforced IPv4/IPv6 access only to `wg_services_only_ipv4_destinations` and `wg_services_only_ipv6_destinations` |
| `full` | Internet access through the VPS; requires IPv4 egress and adds IPv6 only after a successful host egress probe |

Editing client AllowedIPs cannot bypass services-mode policy. Without host IPv6
egress, full-mode profiles omit `::/0`, leaving client IPv6 outside the VPN.
Transitions are transactional and require updated client profiles. There is no
`wg_enable_ipv6` input.

## AmneziaWG

The installer accepts `NOOK_VPN_BACKEND=wg|awg`. The default, `wg`, selects
ordinary WireGuard. The value `awg` selects AmneziaWG. Backend and traffic
policy are independent. Either backend can use `services` (default) or `full`.
In controller variables, the corresponding role input is
`wg_amnezia_enabled: false|true`.

The shared orchestration role automatically prepares the host's AWG kernel module.
The role uses pinned upstream source, authenticated distro DKMS/build packages,
and headers for the exact running kernel. The installer only checks feasibility
before fresh encrypted-state commitment. A matching AmneziaWG client is required.

Dependency preparation uses private transaction-local APT configuration, signed
canonical distro archives, and private lists/cache. The role does not replace
host APT configuration or accept third-party dependency candidates.
Distro `python3-apt` is required. The role authenticates the complete required
build/toolchain dependency graph against distro package payloads, including already-installed tools.

Required installed packages may be reinstalled at exactly their installed
versions. The role performs no broad upgrade or silent downgrade.
The role refuses unavailable exact versions, changed conffiles, diversions, or
unowned tools rather than adopting them. Package changes are not a package
rollback transaction.

Ubuntu uses a source-controlled official snapshot at `20260926T000000Z`, paired
with the pinned stock-image checksum. This snapshot can authenticate exact
already-installed base versions retired from current indices.
Its negative APT priority and explicit resolver checks prohibit historical-only
new dependency candidates. New packages require current canonical archive metadata.

The snapshot retains Ubuntu archive signatures, TLS and APT validity checks.
Historical authenticity does not prove freshness or patch status.
A Release without `Valid-Until` supplies no expiry bound.

The role checks the declared Release scope/date. Unavailable exact versions
still fail closed. This anchor is not an environment or user override.
It does not approve an arbitrary provider image's baseline.

Supported platforms and resource requirements:

- Debian 12 with a 6.1 `amd64` or `cloud-amd64` kernel.
- Ubuntu 24.04 with a GA 6.8 `generic` kernel.
- amd64 architecture and at least 900 MiB of OS-visible RAM.
- At least 2 GiB of free build space before dependency installation.
- At least 256 MiB of free build space remaining for compilation.
- An available `/dev/net/tun` device.

The role refuses other kernel flavours. It also refuses these host conditions:

- Enabled or unknown Secure Boot, module signature enforcement, or lockdown.
- Enabled unattended automatic reboot.
- Active swap or any zram devices.

Builds use one CPU, a 512 MiB memory limit, no build swap, and a 20-minute timeout.
The role uses no PPA, userspace fallback, kernel replacement, or automatic reboot.

The shared preflight runs before fresh encrypted-state commitment.
Its network-backed signed dependency feasibility check has a separate
24-minute installer budget, not the 30-second secret/vault command budget.
Dependency, build or load failures after commitment preserve authoritative
vault/backend inputs for rerun. The role preserves and refuses unknown
module/DKMS state. WG does not install or download AWG dependencies.

Module preparation precedes Docker. The role verifies version/vermagic and
loaded identity before AWG bootstrap.

wg-easy receives `EXPERIMENTAL_AWG`/`OVERRIDE_AUTO_AWG` and disables its userspace
fallback. The container gets no `/lib/modules` mount or module privileges.

New encrypted installer vaults persist `wg_amnezia_enabled` as the canonical
lowercase `"false"` or `"true"` string.
The installer passes the backend value to Ansible as a native boolean.
A legacy installer vault without that field means WG, without rewriting the vault.
On rerun:

- Omitting `NOOK_VPN_BACKEND` preserves the saved backend.
- A matching explicit value is accepted.
- A conflicting value is rejected.

The saved vault and vault-password file remain authoritative.
The installer preserves their bytes on reuse and on prerequisite failure.

The installer does not migrate existing tunnels.
Changing a controller variable is not a supported backend-transition procedure.
AWG changes the wire protocol.
Existing clients need refreshed profiles and a matching client application.
Do not assume initialized peers are converted automatically.

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
| `NOOK_VPN_BACKEND` | `wg` (default) or `awg`. Independent of traffic mode. For AWG, the shared role prepares the module automatically. A matching client is required. |
| `NOOK_SSH_PORT`, `NOOK_WG_PORT` | Optional ports; defaults come from the roles |
| `NOOK_ADMIN_USER` | Optional administrator username |
| `NOOK_INTERNAL_DOMAIN_SUFFIX` | Optional internal DNS suffix |
| `NOOK_INTERNAL_DOMAINS` | Optional pair of distinct internal hostnames |

On rerun omit credential inputs. Supplied ordinary settings must match the saved
vault. The interactive wizard also reuses saved inputs; it cannot silently rotate
credentials, change routing, or switch backend. Omitted backend input preserves
the saved choice rather than applying the fresh-install WG default.

`NOOK_DEV_MODE=1` allows `NOOK_REPO_URL` and `NOOK_RELEASE_REF` for disposable
development fixtures only. Production accepts the built-in repository and release.
`NO_COLOR` disables terminal colors. No progress control codes are emitted to logs.

For backup and restore, `NOOK_PROJECT_ROOT` selects an explicit project root and
`NOOK_KEEP_BACKUPS` sets backup retention. These are not installer path overrides.
All old `ZERO_TRUST_*` inputs are rejected, with values omitted from diagnostics.
