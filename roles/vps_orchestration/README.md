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

`services` is the default. IPv4 and IPv6 forwarding rules on the server restrict
peers to explicit managed destinations, regardless of client-side AllowedIPs.

`full` is an explicit mode transition. It requires working host IPv4 egress and
adds IPv6 routing only when host IPv6 egress works. It snapshots the complete
wg-easy state, applies the policy while wg-easy is stopped, and restores that
snapshot if activation or readiness fails.

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
