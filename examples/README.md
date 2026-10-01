# Internal service examples

These recipes are operator-owned, not part of the supported core service set.
They use Nook's existing [extension points](../docs/extensions.md); they do not
add an installer module or extend core service support.

## Layout

Each service lives in `examples/<service>/` with:

- Executable `manage.sh`: the root-shell interface defined below.
- `README.md`: the service's installation, bootstrap, verification, update and
  removal procedure, including its support and backup boundaries.
- `compose.override.yml`: a digest-pinned service fragment for the shared
  private `vpn_net`, with persistent state under `volumes/<service>`.
- `Caddyfile.conf`: an internal TLS site fragment for the service UI.

Additional files belong in a recipe only when the service actually needs them.

## Executable contract

Run every real command in a **VPS root shell**; `--help` needs no privilege.
Every recipe implements all four commands, including an explicit successful
“not required” `bootstrap` when the service needs no bootstrap:

```text
manage.sh check [--project-root PATH] [--domain-suffix SUFFIX]
manage.sh install [--project-root PATH] [--domain-suffix SUFFIX] [--resume]
manage.sh bootstrap [--project-root PATH] [--timeout SECONDS|--close]
manage.sh verify [--project-root PATH]
```

`--project-root` overrides `NOOK_PROJECT_ROOT`, whose default is `/opt/vps-nook`.
`--domain-suffix` defaults to `internal`; use the deployment's suffix, such as
`home.arpa`, consistently through check, install and resume. Suffixes must be
lowercase DNS labels, without empty labels, edge hyphens, whitespace, `.local`
or overlength hostnames. Bootstrap defaults to 600 seconds; accepted timeouts
are integers from 60 through 3600. `--close` performs recovery without opening
registration.

Unknown, duplicate, command-incompatible or missing-value options print usage
on stderr and exit 2. Output uses `[OK]` for successful automated checks,
`[ACTION]` for required operator steps, and `[FAIL]` for errors.

| Exit | Meaning |
| --- | --- |
| 0 | Requested automated operation completed; not proof of client UI behavior |
| 1 | Operational or preflight failure |
| 2 | Invalid usage |
| 3 | Valid existing shared override needs manual merge before `install --resume` |

`check` never changes deployed files or containers. An existing override without
the service produces a complete generated fragment between begin/end markers.
Merge only its service mapping under the existing single `services:` key,
preserve all other mappings/settings, then use `install --resume` with the same
suffix. Plain install rejects existing service/Caddy ownership; resume accepts
only the exact generated service and absent or byte-identical Caddy fragment.
Failed startup preserves installed files and data for diagnosis and resume.
Private temporary rendering files are cleaned on exit.

`install` starts only the selected service; Caddy activation remains Ansible's
transaction through the verified installer or tagged controller playbook.
`bootstrap` supervises a bounded registration window and closes it on exit;
after an uncatchable interruption, run `bootstrap --close` before proceeding.
`verify` distinguishes automated configuration/runtime proof from explicit
VPN-client actions. Update and removal remain service README procedures:
reviewed pin changes, backup confirmation and destructive shared-override edits
are not automated `update` or `remove` commands.

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
it or create a second alias; only exact recipe state can be adopted with resume.

Install Caddy fragments into `/opt/vps-nook/Caddyfile.d/` under distinct service
names. Follow the service README for hostname changes and activation through
the verified installer or controller playbook's Caddy validation transaction.
