# vps_orchestration role

Deploys wg-easy, AdGuard Home, and Caddy on a private Docker network after host
hardening. It owns Docker installation, service volumes, Compose lifecycle,
traffic policy, UFW/Docker integration, Caddy activation, and readiness checks.

Use this role through [`site.yml`](../../site.yml). The executable input contract
is [`meta/argument_specs.yml`](meta/argument_specs.yml); defaults and pinned
upstream artifacts are in [`defaults/main.yml`](defaults/main.yml).

## Stable inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `project_root` | `/opt/vps-nook` | Managed Compose, Caddy, and service-data root |
| `wg_traffic_mode` | `services` | Server-enforced `services` or IPv4 `full` policy with optional IPv6 |
| `wg_amnezia_enabled` | `false` | Select AmneziaWG independently of traffic mode. The role automatically prepares the matching host module. A matching client is required. |
| `wg_amnezia_kernel_module` | `amneziawg` | Fixed supported kernel module identity |
| `wg_amnezia_overrided_executable` | `awg` | Fixed supported container tool identity |
| `docker_network_subnet` | `10.66.0.0/24` | Private service IPv4 network |
| `docker_network_ipv6_subnet` | `fd00:67:0:0::/64` | Private service IPv6 network |
| `wg_vpn_subnet` | `10.8.0.0/24` | WireGuard client IPv4 network |
| `wg_vpn_ipv6_subnet` | `fd42:42:42::/64` | WireGuard client IPv6 network |
| `wg_services_only_ipv4_destinations` | managed networks | Allowed IPv4 destinations in the default mode |
| `wg_services_only_ipv6_destinations` | managed networks | Allowed IPv6 destinations in the default mode |
| `wg_public_host` | required | Public endpoint written to new peer profiles |
| `wg_easy_bootstrap_secret` | required | Vault-sourced initial wg-easy password |
| `vault_adguard_password_hash` | required | Vault-sourced AdGuard bcrypt hash |
| `vps_services_vault_path` | service vault | Encrypted vault path proven before deployment |

Related group variables select ports, static container addresses, internal
names, the administrator name, certificate fetch destination, and pinned
artifact data. Start from
[`group_vars/all/vars.yml.example`](../../group_vars/all/vars.yml.example).

`wg_easy_admin_password`, `admin_password`, and `wg_enable_ipv6` are not
supported inputs. Keep credentials in a whole-file encrypted service vault with
mode `0600`; see [Configuration](../../docs/configuration.md).

## Traffic modes

See [traffic policy](../../docs/configuration.md#traffic-policy) for mode behavior
and client requirements. Transitions snapshot wg-easy state, apply policy while
it is stopped, and restore the snapshot if activation or readiness fails.

## VPN backend

The installer maps `NOOK_VPN_BACKEND=wg|awg` (default `wg`) to the role boolean
`wg_amnezia_enabled` (default `false`). Either backend supports `services` or `full`.
Selecting AWG does not change the routing default.

The shared orchestration role automatically prepares the host's AWG kernel module.
The role uses pinned upstream source, authenticated distro DKMS/build packages,
and headers for the exact running kernel. The installer only checks feasibility
before fresh encrypted-state commitment. A matching AmneziaWG client is required.

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
Dependency, build or load failures after commitment preserve authoritative
vault/backend inputs for rerun. The role preserves and refuses unknown
module/DKMS state. WG does not install or download AWG dependencies.
Module preparation precedes Docker. The role verifies version/vermagic and
loaded identity before AWG bootstrap.

New installer vaults store canonical `"false"`/`"true"` backend values.
The installer passes the backend value to Ansible as a native boolean.
Legacy vaults without the field remain WG.
Installer reruns preserve saved vault/password bytes:

- Omitting `NOOK_VPN_BACKEND` preserves the saved backend.
- Matching explicit input is accepted.
- Conflicting input is rejected.

Controller variables remain separate from installer state.

Backend changes are not a supported controller transition procedure for existing peers.
There is no silent migration. Changed protocol or routing requires refreshed
client profiles. AWG requires the matching application. See
[Configuration](../../docs/configuration.md#amneziawg) and
[module operations](../../docs/operations.md#amneziawg-kernel-module).

## Owned state and extension points

- The role owns `docker-compose.yml`, the managed `Caddyfile`, its activation
  marker, service volumes, traffic-mode marker, and the corresponding wg-easy
  routes and built-in pre-NAT firewall setting.
- It preserves `docker-compose.override.yml` and `Caddyfile.d/` as operator
  extension points.
- Caddy changes are validated in a private candidate tree, installed without
  changing the active bind-mount inode, reloaded, and rolled back on failure.
- wg-easy first-start credentials are removed from persisted Compose state after
  bootstrap. Reruns do not overwrite UI-managed state.
- The exact IPv4/IPv6 netfilter modules used by wg-easy are loaded and
  persisted on the host. A kernel that does not provide them is rejected;
  wg-easy keeps only the `NET_ADMIN` capability.
- With `wg_amnezia_enabled`, the role automatically prepares the pinned
  `amneziawg` source using bounded host DKMS. The role verifies and persists the
  module, then tells wg-easy to select it explicitly. Live interface checks use `awg`.
  Unsupported kernels fail closed. The role uses no userspace fallback or
  host `/lib/modules` bind mount.
- The fetched internal root CA is written to the configured controller
  destination.

## Tags

| Tag | Boundary |
| --- | --- |
| `docker` | Host netfilter modules, Docker repository, engine, and Compose plugin |
| `volumes` | Private project directories and service state |
| `adguard` | Managed AdGuard bootstrap configuration |
| `compose` | Compose preparation and lifecycle |
| `traffic_mode` | Server traffic policy transaction |
| `ufw_docker` | UFW/Docker integration |
| `verify` | Service, exposure, DNS, TLS, and policy checks |
| `wg_bootstrap_state` | Removal of first-start secret state |

Check mode is not a reliable change predictor because transactions depend on
live Docker, network, and firewall state. Use the disposable E2E scenarios in
[`tests/e2e`](../../tests/e2e/README.md).

The role requires `vps_hardening` to configure the host firewall first.
