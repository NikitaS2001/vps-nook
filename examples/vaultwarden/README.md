# Vaultwarden: operator-owned internal service

> [!WARNING]
> Vaultwarden is an operator-owned extension. It is **not** part of VPS Nook's
> supported core service set: the operator owns its account lifecycle, upgrades,
> data recovery, and client compatibility.

This recipe runs [Vaultwarden](https://github.com/dani-garcia/vaultwarden) behind
Caddy on the private VPN network. It is pinned to upstream release `1.37.1` and
its published multi-architecture OCI image-index digest:

```text
vaultwarden/server:1.37.1@sha256:ebdfe70701c60ac0c28c697e787cea767d7972940b786037b29fe0d507f821e8
```

The index digest deliberately preserves upstream multi-architecture semantics;
VPS Nook itself is deployed on amd64. Vaultwarden uses its upstream SQLite
storage in `/data`, backed here by `./volumes/vaultwarden`. The UI is reachable
only over the VPN through Caddy at `https://vw.internal` using `tls internal`.
The recipe publishes no host ports.
The admin panel, external database and push integration remain disabled by
upstream defaults. This recipe adds no admin token, SMTP or push credentials.

## Prerequisites

Before changing an existing deployment, make an encrypted backup and copy it
off-host. Use the verified checkout that installed this Nook deployment, not a
newly downloaded or unrelated checkout. The public-installer checkout is
`/opt/vps-nook-installer/repo`; for a controller-managed deployment, it remains
on the controller. See [Getting started](../../docs/getting-started.md) for the
verified installer and controller workflows, and [Operations](../../docs/operations.md#backup)
for the backup command.

You need:

- an already deployed VPS Nook instance and a connected VPN client;
- the Caddy `root.crt` from that instance, trusted on the client before opening
  the Vaultwarden URL; follow [Trust the internal CA](../../docs/getting-started.md#trust-the-internal-ca);
- access to the same verified checkout to review and copy this recipe; and
- an encrypted, off-host backup before modifying an existing service deployment.

The normal encrypted backup command on an installer-managed VPS is:

```bash
sudo env AGE_KEY="age1..." \
  /opt/vps-nook-installer/repo/scripts/backup.sh
```

Keep the recipient and recovery identity outside the VPS. Do not use the
plaintext mode merely to make this procedure easier.

## Prepare the recipe and hostname

`vw.internal` is the default. If `internal_domain_suffix` is not `internal`,
prepare copies of **both** `compose.override.yml` and `Caddyfile.conf` from the
same verified checkout, replace `vw.internal` with `vw.<your-suffix>` in both,
and review the two copies together. `DOMAIN` and the Caddy site address must
always agree.

For example, use a private working directory on the host where you are
preparing the files (replace `RECIPE_DIR` with the matching verified checkout):

```bash
RECIPE_DIR=/opt/vps-nook-installer/repo/examples/vaultwarden
stage="$(mktemp -d)"
install -m 0644 "${RECIPE_DIR}/compose.override.yml" "${stage}/compose.override.yml"
install -m 0644 "${RECIPE_DIR}/Caddyfile.conf" "${stage}/Caddyfile.conf"
```

For a non-default suffix, edit both staged files, then check that this command
prints no matches before installing them (including matches in comments):

```bash
grep -nF -- 'vw.internal' "${stage}/compose.override.yml" "${stage}/Caddyfile.conf"
```

For the default suffix, copy the reviewed files unchanged. For a
controller-managed deployment, transfer only these reviewed staged files to the
VPS through the operator's authenticated administration path; do not fetch a
second checkout from the network.
On the VPS, set `stage` to the directory containing those prepared copies if it
differs from the local staging path above.

## Install safely

The repository directory is **not** a separate Compose project on the VPS.
Vaultwarden must be merged into the one project at `/opt/vps-nook`. The source
recipe is a fragment, while the installed override must contain one shared
`services:` mapping with all operator-added services.

Stop before changing anything if a Vaultwarden service is already effective or
if the target Caddy fragment already exists. The following check deliberately
also stops when the existing override cannot be rendered: repair or review the
existing deployment first.

```bash
cd /opt/vps-nook
if [[ -L docker-compose.override.yml ]]; then
  echo 'Refusing a symlinked override; review its owner and state.' >&2
  exit 1
fi
if [[ -f docker-compose.override.yml ]]; then
  merged="$(sudo docker compose -f docker-compose.yml -f docker-compose.override.yml \
    config --format json)" || exit 1
  if printf '%s' "${merged}" | python3 -c \
    'import json, sys; raise SystemExit(0 if "vaultwarden" in json.load(sys.stdin).get("services", {}) else 1)'
  then
    echo 'Vaultwarden is already defined; inspect its owner and state. Nothing was changed.' >&2
    exit 1
  fi
fi
if sudo test -e /opt/vps-nook/Caddyfile.d/vaultwarden.conf ||
  sudo test -L /opt/vps-nook/Caddyfile.d/vaultwarden.conf
then
  echo 'Caddyfile.d/vaultwarden.conf already exists; inspect it. Nothing was changed.' >&2
  exit 1
fi

for directory in /opt/vps-nook/volumes/vaultwarden /opt/vps-nook/Caddyfile.d; do
  if sudo test -L "${directory}" || { sudo test -e "${directory}" && ! sudo test -d "${directory}"; }; then
    echo "${directory} must be a real directory when it already exists. Nothing was changed." >&2
    exit 1
  fi
done

if ! sudo test -e /opt/vps-nook/volumes/vaultwarden &&
  ! sudo test -L /opt/vps-nook/volumes/vaultwarden
then
  sudo install -d -m 0755 /opt/vps-nook/volumes/vaultwarden
fi
if ! sudo test -e /opt/vps-nook/Caddyfile.d &&
  ! sudo test -L /opt/vps-nook/Caddyfile.d
then
  sudo install -d -m 0755 /opt/vps-nook/Caddyfile.d
fi
```

If `docker-compose.override.yml` does not exist, install the prepared Compose
fragment as that new file. If it already exists, open it with `sudoedit` and add
exactly the complete `vaultwarden` mapping from the prepared
`compose.override.yml` below its existing `services:` key. Do not replace the
file, do not change other service definitions, and do not add a second
`services:` key.

```bash
if [[ ! -e docker-compose.override.yml && ! -L docker-compose.override.yml ]]; then
  sudo install -m 0644 "${stage}/compose.override.yml" docker-compose.override.yml
else
  sudoedit /opt/vps-nook/docker-compose.override.yml
fi
```

For the second branch, copy the entire mapping beginning with
`vaultwarden:`—including its `image`, `container_name`, `restart`, `networks`,
`volumes`, and `environment` children—from the prepared fragment. Then install
the prepared Caddy fragment only after the collision check above:

```bash
sudo install -m 0644 "${stage}/Caddyfile.conf" \
  /opt/vps-nook/Caddyfile.d/vaultwarden.conf

cd /opt/vps-nook
sudo docker compose config -q
sudo docker compose up -d vaultwarden
```

This starts only Vaultwarden. It does not recreate the rest of the project.
Next, activate Caddy through its existing transaction, never through a direct
Caddy restart or reload:

- **Public-installer deployment:** rerun the same verified, version-pinned
  `install.sh` bytes used for this deployment—for example, from the verified
  download directory, `sudo bash ./install.sh`. Do not replace that step with a
  `latest` download.
- **Controller-managed deployment:** from the same tagged controller checkout,
  activate the existing virtual environment and rerun the established playbook
  command from [Getting started](../../docs/getting-started.md#remote-ansible-deployment),
  for example:

  ```bash
  source .venv/bin/activate
  ansible-playbook --ask-vault-pass site.yml
  ```

  Use the current inventory connection user and port after the initial run, as
  that guide requires.

The role validates the complete candidate—including `Caddyfile.d`—before it
activates and reloads Caddy. A failure leaves the active Caddy configuration
unchanged.

## Create the first account, then close registration

The committed recipe has `SIGNUPS_ALLOWED: "false"`. Do not add an
`ADMIN_TOKEN`, a bootstrap secret, or plaintext credentials. Create the first
account only in a short, supervised window while connected through the VPN.
Every VPN peer can register while signup is enabled.

On the VPS, edit **only** `services.vaultwarden.environment.SIGNUPS_ALLOWED`
in the installed override to the quoted string `"true"`:

```bash
sudoedit /opt/vps-nook/docker-compose.override.yml
cd /opt/vps-nook
sudo docker compose config -q
sudo docker compose up -d vaultwarden
```

Open the canonical HTTPS URL over the VPN with the trusted CA and create the
first account through the web vault. Immediately edit the same setting back to
`"false"` and recreate the service:

```bash
sudoedit /opt/vps-nook/docker-compose.override.yml
cd /opt/vps-nook
sudo docker compose config -q
sudo docker compose up -d vaultwarden
```

Do not leave this window unattended. If account creation fails or the session
is interrupted, return the setting to `"false"` and run the second sequence
before resuming. Merely editing the file does not change the running container:
the final `up -d vaultwarden` is required to apply the closed-registration
environment.

## Verify the service

Wait for Vaultwarden's upstream health check; the recipe intentionally does not
override it:

```bash
for attempt in $(seq 1 30); do
  health="$(sudo docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' vaultwarden 2>/dev/null || true)"
  [[ "${health}" == healthy ]] && break
  sleep 5
done
[[ "${health}" == healthy ]] || { echo "Vaultwarden health is ${health}" >&2; exit 1; }
```

From a VPN-connected client whose trust store contains this deployment's Caddy
root CA, open the canonical `https://vw.<suffix>` URL (the default is
`https://vw.internal`) without disabling TLS validation. Log in, save a test
vault item, log out, and log in again to confirm that the item persisted. In a
private browser session, attempt a second independent signup; it must be denied
after registration has been reclosed.

Confirm the resolved image reference and that the effective service has no
published ports:

```bash
cd /opt/vps-nook
sudo docker compose config --format json | python3 -c '
import json
import sys
service = json.load(sys.stdin)["services"]["vaultwarden"]
expected = "vaultwarden/server:1.37.1@sha256:ebdfe70701c60ac0c28c697e787cea767d7972940b786037b29fe0d507f821e8"
assert service["image"] == expected, service["image"]
assert not service.get("ports"), service.get("ports")
print(service["image"])
'
```

## Trust the private CA on clients

Browsers, the CLI, desktop applications, and mobile clients must each trust the
Caddy root CA as appropriate for their platform. Follow VPS Nook's
[client CA instructions](../../docs/getting-started.md#trust-the-internal-ca)
and Bitwarden's official [certificate guidance](https://bitwarden.com/help/certificates/).
Some clients or managed devices may not accept a user-installed private CA; test
the intended client rather than assuming universal mobile compatibility.

Never bypass an unexpected certificate error with `curl -k`, disabled client TLS
verification, `GIT_SSL_NO_VERIFY`, or an equivalent workaround. Do not publish
ports 80 or 443 to make a client work. Investigate the trusted CA, hostname, and
client trust store instead.

## Backup and restore

Use only the standard [`scripts/backup.sh`](../../scripts/backup.sh) and
[`scripts/restore.sh`](../../scripts/restore.sh) procedures. Backup briefly
stops the **whole** Compose project for consistency, then archives the existing
allowlist: `volumes/`, `docker-compose.yml`, `Caddyfile`, `Caddyfile.d`, and the
optional `docker-compose.override.yml`. Consequently, Vaultwarden's complete
`/data` must remain at `./volumes/vaultwarden`.

Do not add a parallel Vaultwarden backup script and do not assume arbitrary
files inside `/opt/vps-nook` are preserved. Extra configuration or secrets
outside that allowlist need their own reviewed, encrypted backup contract.
Restore replaces the active project tree and stops the whole project; follow the
standard restore guide and verify the restored service over the VPN afterwards.

## Update

Before an update, create and copy an encrypted backup off-host. Review the
upstream Vaultwarden release and change the tag and OCI index digest together in
the installed `services.vaultwarden.image` value. Do not advance one without the
other. Then run:

```bash
cd /opt/vps-nook
sudo docker compose pull vaultwarden
sudo docker compose up -d vaultwarden
```

Wait for `healthy`, then repeat the HTTPS login and saved-item read verification
above. An image rollback is **not** a guaranteed rollback of an SQLite database
that a newer Vaultwarden version has already migrated; restore the reviewed
backup if data rollback is required.

## Remove the service without destroying data

First create and verify an encrypted off-host backup. Use `sudoedit` to remove
only the complete `services.vaultwarden` mapping from
`/opt/vps-nook/docker-compose.override.yml`; do not alter other service
mappings or top-level settings. Inspect the resulting YAML and choose exactly
one valid shared-override state:

- If other services remain, retain their `services:` mapping unchanged.
- If Vaultwarden was the last service but needed top-level settings remain, use
  `services: {}` explicitly.
- If Vaultwarden was the last service and no needed top-level settings remain,
  remove `/opt/vps-nook/docker-compose.override.yml` entirely.

Do not leave a bare `services:` key with a null value. Only after selecting one
of those states, remove `/opt/vps-nook/Caddyfile.d/vaultwarden.conf`, validate
the resulting Compose configuration, reconcile it, and rerun the same verified
installer or controller playbook described above so Caddy again uses its
validated transaction:

```bash
cd /opt/vps-nook
sudo rm /opt/vps-nook/Caddyfile.d/vaultwarden.conf
sudo docker compose config -q
sudo docker compose up -d --remove-orphans
```

`--remove-orphans` removes every container no longer declared by the shared
project, not only Vaultwarden. Review any other operator-owned services first.
By default, keep `/opt/vps-nook/volumes/vaultwarden` as recoverable state. Delete
it only as a separate, explicit destructive action after confirming the
off-host backup and that the data is no longer needed.
