# Internal service examples

These recipes are operator-owned, not part of the supported core service set.
They use Nook's existing [extension points](../docs/extensions.md); they do not
add an installer module or extend core service support.

## Layout

Each service lives in `examples/<service>/` with:

- `README.md`: the service's installation, bootstrap, verification, update and
  removal procedure, including its support and backup boundaries.
- `compose.override.yml`: a digest-pinned service fragment for the shared
  private `vpn_net`, with persistent state under `volumes/<service>`.
- `Caddyfile.conf`: an internal TLS site fragment for the service UI.

Additional files belong in a recipe only when the service actually needs them.

## Available recipes

| Service | Purpose | Internal hostname | Persistent state | Status |
| --- | --- | --- | --- | --- |
| [Vaultwarden](vaultwarden/README.md) | Bitwarden-compatible password vault | `vw.internal` | `volumes/vaultwarden` | operator-owned, not part of the supported core service set |

## One deployed Compose project

The repository directories are **not** separate Compose projects on the VPS.
Definitions for selected services must be manually combined under the single
`services:` key in `/opt/vps-nook/docker-compose.override.yml`.

If that file does not exist, install the first recipe's Compose fragment as the
new override. If it already exists, merge only the selected service mapping,
preserving every other service and top-level setting. **Never copy a new
fragment over an existing override.** An existing service key or target Caddy
fragment is a reason to stop and reconcile ownership and state, not overwrite
it or create a second alias.

Install Caddy fragments into `/opt/vps-nook/Caddyfile.d/` under distinct service
names. Follow the service README for hostname changes and activation through
the verified installer or controller playbook's Caddy validation transaction.
