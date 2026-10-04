# Operations and recovery

The public installer retains its verified checkout at
`/opt/vps-nook-installer/repo`; the direct commands below use that path.
A remote Ansible deployment leaves the checkout on the controller. In that
case, stream the script from the same tagged controller checkout instead of
downloading a second copy, for example:

```bash
ssh -p <ssh_port> <admin_user>@<vps-address> \
  'sudo bash -s --' < scripts/synthetic-check.sh
```

Backup and restore default to `/opt/vps-nook`; set `NOOK_PROJECT_ROOT`
only for an intentional alternate deployment root. Backup and restore use the
same `sudo bash -s -- [arguments] < scripts/<name>.sh` pattern when the checkout
is on the controller.

## Health check

```bash
sudo /opt/vps-nook-installer/repo/scripts/synthetic-check.sh
```

The check verifies container state, wg-easy authentication readiness, internal
HTTPS, and recent WireGuard handshakes. A handshake warning is informational
when no client has connected recently. Scheduling and alert delivery are left
to the operator.

## Backup

Backups stop the complete Compose project briefly so application state is
consistent. Encryption prerequisites are validated before containers stop.
Generate and store an age identity outside the VPS, then pass its public
recipient:

```bash
sudo env AGE_KEY="age1..." \
  /opt/vps-nook-installer/repo/scripts/backup.sh
```

The output is an age-encrypted `.tar.gz.age` file with mode `0600`. It includes
managed Compose/Caddy configuration, volumes, and an optional Compose override.
Copy it off-host and test restoration regularly. The default retention is 14
files under `/opt/vps-nook-backups`; `NOOK_KEEP_BACKUPS` changes that count.

> [!WARNING]
> `--allow-plaintext` deliberately writes an unencrypted archive containing
> private service data. Use it only with a separately protected destination.

```bash
sudo /opt/vps-nook-installer/repo/scripts/backup.sh \
  --allow-plaintext /secure/path/backup.tar.gz
```

## Restore

Restore validates archive structure and safe extraction into a same-filesystem
staging directory. It stops the current stack, preserves its directory, and
activates the staged tree. Compose validation, startup and container readiness
checks follow activation; failures trigger restoration and restart of the prior
project. Restore does not run a separate Caddy configuration validation.

> [!WARNING]
> A successful restore replaces the active project tree with backup contents.
> Confirm the archive, age identity, target host, and off-host recovery copy
> before running it.

```bash
sudo /opt/vps-nook-installer/repo/scripts/restore.sh \
  /path/to/backup.tar.gz.age /path/to/age-identity.txt
```

After success, reconnect a WireGuard client and verify DNS and both internal
HTTPS endpoints. Preserve any reported rollback directory if automatic
recovery cannot restart the old stack.

## Upgrade

Read [UPGRADE.md](../UPGRADE.md) and the release notes before upgrading. Create
and copy an encrypted backup off-host, verify the new installer asset and
attestation as described in [Getting started](getting-started.md), then execute
the downloaded local bytes. Do not change traffic mode or rotate credentials in
the same maintenance window unless that is the specific goal.

The installer reuses its encrypted state and checks out the exact verified
release commit. After convergence, run the health check, reconnect a client,
and test DNS and internal HTTPS.

## SSH recovery

If the new login fails, keep the original session open and inspect:

```bash
sudo sshd -t
sudo systemctl status ssh --no-pager
sudo ufw status numbered
sudo journalctl -u ssh -n 100 --no-pager
```

Check the provider firewall independently; QEMU and UFW checks cannot prove its
rules. Use the provider console to restore the previous SSH configuration or
firewall access if both SSH sessions are lost.

## Service troubleshooting

```bash
cd /opt/vps-nook
sudo docker compose ps
sudo docker compose logs --tail=100 wg-easy adguard caddy
sudo /opt/vps-nook-installer/repo/scripts/synthetic-check.sh
```

Do not restart Caddy directly after editing a site. Rerun Ansible so the role
validates the complete candidate, activates it, and rolls back on reload
failure.

## AmneziaWG kernel module

For a fresh installation, `NOOK_VPN_BACKEND=awg` (controller input:
`wg_amnezia_enabled: true`) requires an operator-prepared module matching the
running kernel and the AmneziaWG tools in the pinned wg-easy image. Obtain and
prepare it through your operator-managed process before deployment. VPS Nook
does not build, install, or download an AWG module and has no userspace fallback.
The verified role default `wg_amnezia_kernel_module` is currently `amneziawg`:

```bash
uname -r
sudo modinfo amneziawg   # metadata must resolve for the running kernel
```

The installer's early metadata check runs before fresh encrypted-state commitment
or server roles. It does not load the module or prove protocol interoperability.
The role separately checks availability, then loads and persists the module with
`modprobe`; loader failure stops deployment. Existing installer vault and
vault-password bytes remain unchanged when that prerequisite fails.

Recheck module compatibility and availability for every kernel upgrade before
rebooting into the new kernel. A successful `modinfo` alone is not a successful
load or a matching-client handshake. After deployment, inspect the loaded module
and the exact AWG interface:

```bash
lsmod | grep amneziawg
sudo docker exec wg-easy awg show wg0   # jc/jmin/jmax/s1/s2/h1..h4 must appear
```

Plain `wg show wg0` returns `Not supported` for an AmneziaWG interface. Use
`awg` when troubleshooting; the role and `scripts/synthetic-check.sh` select the
executable automatically.

Connect with a matching AmneziaWG client and a refreshed profile, then check
DNS and both internal HTTPS sites through the tunnel. Module loading and
`awg show wg0` do not by themselves establish client interoperability.
Routing changes require refreshed profiles for either backend.

Installer reruns preserve the backend in the encrypted vault: omission preserves
it, a matching `NOOK_VPN_BACKEND` is accepted, and a conflict is rejected. Legacy
vaults without `wg_amnezia_enabled` remain WG without a vault rewrite. Do not
delete or edit saved state to force a switch. There is no silent migration or
supported controller transition procedure for existing peers; changing the wire
protocol requires refreshed profiles and matching applications.

## Removing the deployment

There is no automated uninstall. First verify an off-host backup and restore a
safe SSH/firewall configuration with console access available. Then stop Compose
and remove only confirmed project paths. Removing service volumes and installer
state destroys VPN peers, DNS state, certificates and saved credentials; host
users, Docker and firewall rules require separate review.
