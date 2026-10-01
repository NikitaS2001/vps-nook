# Vaultwarden: operator-owned internal service

> Operator-owned, **not supported core**: you own accounts, upgrades, recovery, and client compatibility.

- Service: `vaultwarden`; URL: `https://vw.internal`.
- Storage: upstream SQLite at `/opt/vps-nook/volumes/vaultwarden`.
- Exposure: private `vpn_net` through Caddy; no published host ports. The recipe
  reserves `10.66.0.5`, outside Nook's core `10.66.0.2`–`.4` addresses.
- Image: tag+digest in [`compose.override.yml`](compose.override.yml) are authoritative.
- Registration defaults closed; no admin, SMTP, or push credentials added.

## Before you start

- Existing Nook deployment; follow the [shared-override rules](../../docs/extensions.md).
- Connected VPN client trusting [this deployment's Caddy CA](../../docs/getting-started.md#trust-the-internal-ca).
- Same verified/tagged checkout used for deployment; current [encrypted off-host backup](../../docs/operations.md#backup).

All `manage.sh` commands run in a **VPS Bash root shell** (`sudo -i`), never on the controller.
Installer-managed deployments use `/opt/vps-nook-installer/repo/examples/vaultwarden`.
Controller-managed deployments transfer the entire reviewed `examples/vaultwarden/` directory from the same tagged
checkout through the authenticated administration path; retain the executable bit on `manage.sh`.
On the VPS, `cd` into that recipe directory.

## Install

```bash
./manage.sh check
./manage.sh install
```

See the [command contract](../README.md#executable-contract) for options and exit statuses.
`--project-root PATH` overrides `NOOK_PROJECT_ROOT` (default `/opt/vps-nook`).
For another deployment `internal_domain_suffix`, pass `--domain-suffix home.arpa` to **both** commands;
this generates matching Compose `DOMAIN` and Caddy hostnames. Reuse the same suffix on resume.

- Exit 0 from `check`: clean installation is ready; no deployed files or containers changed.
- Exit 3 from `check` or `install`: a valid shared override exists without Vaultwarden. Manually add **only** the
  generated Vaultwarden mapping between the printed markers beneath its existing single `services:` key.
  Preserve every other service and top-level setting; never overwrite the shared override. Then run:

  ```bash
  ./manage.sh install --resume
  ```

  Include the same `--domain-suffix` and project root used for preflight.
- Exit 1: stop and reconcile malformed Compose, existing service/Caddy ownership or path collisions.
  Symlinks and non-directory targets are rejected. Resume accepts only the exact generated effective service
  and absent or byte-identical Caddy fragment; it never overwrites differences.

Interrupted/failed startup preserves the override, Caddy fragment and volume for diagnosis.
Inspect the failure, then use `install --resume` with the same options. Exact completed state is safe to resume.
Only Vaultwarden starts; upstream health must become `healthy` within the bounded wait.

Activate Caddy through **exactly one** branch; never restart/reload Caddy directly:

- **VPS, installer-managed:** from the download directory, rerun the same verified, version-pinned `install.sh` bytes:
  `bash ./install.sh`.
- **Controller-managed:** from the same tagged checkout, activate `.venv` and run `ansible-playbook --ask-vault-pass site.yml`
  with the [current inventory user/port](../../docs/getting-started.md#remote-ansible-deployment).

Ansible validates and transactionally activates the complete Caddy configuration.

## Bootstrap: create the first account

```bash
./manage.sh bootstrap
```

Keep this root-shell process attached to `/dev/tty`. Over VPN/trusted HTTPS, create the first account at the printed URL,
then press Enter. Every VPN peer can register during this supervised window.
The default timeout is 600 seconds; `--timeout SECONDS` accepts 60–3600.
The shared override remains closed and unchanged; a private temporary third Compose file opens registration.
Enter, timeout and catchable signals recreate only Vaultwarden with `SIGNUPS_ALLOWED=false`, require health,
and prove runtime closure. Timeout/interruption or failed closure exits nonzero.

After SIGKILL, host/session loss, or any uncertain/failed closure, **close registration before doing anything else**:

```bash
./manage.sh bootstrap --close
```

This recovery command needs no terminal and never opens registration. Diagnose and retry if closure fails.
No accounts, tokens, SMTP or push settings are generated.

## Verify

```bash
./manage.sh verify
```

`[OK]` proves only automated checks: pinned configured/running image, private network, persistent bind,
closed configured/running signup, no published ports, matching Caddy/DOMAIN and upstream health.
Complete all three `[ACTION]` checks on a **VPN client**: trusted HTTPS without bypass; a saved item survives
logout/login; an independent signup in a private browser session is denied. Exit 0 does not prove these UI checks.
For client trust, use the [CA guide](../../docs/getting-started.md#trust-the-internal-ca) and
[Bitwarden certificate guidance](https://bitwarden.com/help/certificates/).

## Backup and restore

Use standard Nook [backup](../../docs/operations.md#backup)/[restore](../../docs/operations.md#restore): these stop the whole
project and include `volumes/vaultwarden`, `docker-compose.override.yml` and `Caddyfile.d`, not arbitrary extra files.
Repeat automated and VPN-client verification after restore.

## Update

First create an encrypted off-host backup. Review upstream changes and the recipe's coupled tag+digest change;
update the installed `services.vaultwarden.image` to match that reviewed recipe pin. From the VPS root shell:

```bash
(cd /opt/vps-nook && docker compose pull vaultwarden && docker compose up -d vaultwarden)
./manage.sh verify
```

Use your custom project root if applicable; repeat the VPN-client checks.
An image downgrade does not reverse SQLite migrations; data rollback requires the reviewed backup.

## Remove

First create and verify an encrypted off-host backup. Manually remove only `services.vaultwarden` from the shared override.
Preserve other services/settings. If no services remain, use `services: {}`; remove the override only when no top-level settings remain.
`--remove-orphans` removes **all** undeclared project containers: review other services first.
From the VPS root shell (adjust a custom project root):

```bash
cd /opt/vps-nook
rm Caddyfile.d/vaultwarden.conf
docker compose config -q
docker compose up -d --remove-orphans
```

Rerun the matching Caddy activation branch above.
Keep `volumes/vaultwarden`; destroy it only as a separate explicit action after confirming the off-host backup and that data is unnecessary.
