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

Cancellation stops the owned build service and confirms its cgroup is empty
before releasing the module lock. If start or termination cannot be confirmed,
`/var/lib/vps-nook/amneziawg/build-transaction` remains as a recovery barrier.
Later managed operations refuse this state, including after reboot.
Preserve its `transaction.json` and any `started.json` for investigation.
Do not delete the directory merely because the caller exited or a unit query
returns `not found`. Confirm the captured service and its descendants stopped,
then reconcile the interrupted DKMS state before explicitly recovering it.
This barrier does not claim that a process lock survives its owner's exit.

The shared preflight runs before fresh encrypted-state commitment.
Its network-backed signed dependency feasibility check has a separate
24-minute installer budget, not the 30-second secret/vault command budget.
Dependency, build or load failures after commitment preserve authoritative
vault/backend inputs for rerun. The role preserves and refuses unknown
module/DKMS state. WG does not install or download AWG dependencies.

Module preparation precedes Docker. The role verifies version/vermagic and
loaded identity before AWG bootstrap.

The pinned source commit is `0d5f03c543b709ab3c2e8d3f4a36994fbe249dc0`,
SHA256 `7901c2feebec12dd28361cbb8f249fa5a5bf973412cc2a70c10e8b4afb2f5a2c`.
Upstream source is unsigned. Its checksum pin is distributed in the signed
VPS Nook release. Distro dependencies retain distro APT trust.

Managed state is under `/var/lib/vps-nook/amneziawg`, separate from service
volumes and encrypted installer inputs. Do not delete its receipt to adopt an
unknown module or bypass a failure. The receipt records source and per-kernel
build/install identity. DKMS hooks reuse the same guarded build owner.
Separate kernel/header postinst verification rejects missing or mismatched
receipts even when distro DKMS ignores a module hook error.

Matching dependency receipts authenticate installed payloads without reinstalling them.
A newly staged ABI or changed toolchain may require network access to canonical
signed archives for read-only payload authentication inside the hook.
The hook never runs a nested package installation under dpkg's lock.
Unavailable exact versions or failed authentication refuse the candidate while
retaining prior kernel audits.

These checks assume an honest base OS, root account, dpkg and distro keyrings.
They do not attest a previously compromised host.

Kernel updates may stage another signed distro kernel and trigger DKMS.
The installer does not initiate those upgrades.
Before an operator reboot, require both conditions:

- An installed receipt for the exact target ABI.
- Successful header/DKMS hooks.

Failed builds do not approve a reboot.
A failed hook does not roll back kernel packages or bootloader selection.
Provider-initiated reboots remain outside this policy.

```bash
sudo cat /var/lib/vps-nook/amneziawg/receipt.json
sudo dkms status -m amneziawg
sudo modinfo -F version amneziawg
sudo docker exec wg-easy awg show wg0
```

Loading or metadata alone does not prove a matching-client handshake.

Plain `wg show wg0` returns `Not supported` for an AmneziaWG interface.
Use `awg` when troubleshooting.
The role and `scripts/synthetic-check.sh` select the executable automatically.

Connect with a matching AmneziaWG client and a refreshed profile.
Check DNS and both internal HTTPS sites through the tunnel.
Module loading and `awg show wg0` do not by themselves establish client interoperability.
Routing changes require refreshed profiles for either backend.

### Disposable pre-release AWG smoke

This external-provider smoke is not part of this repository run.
It remains **NOT RUN** until an operator separately confirms the exact target is disposable.
Never target a production or operator-state VPS.

Before deployment:

1. Separately confirm that the exact provider VPS is disposable.
2. Use a fresh supported VPS running Debian 12 or Ubuntu 24.04.
3. Confirm that the VPS meets the documented kernel, RAM, disk, and TUN requirements.
4. Retain provider console/rescue access.
5. Confirm SSH and AWG UDP rules.

Use controller Ansible against the exact feature commit SHA as the primary prerelease proof.
Use a private inventory and whole-file encrypted vault.
Follow the [existing remote Ansible procedure](getting-started.md#remote-ansible-deployment)
through the shared production role.
Replace the placeholder below with the exact reviewed SHA from the PR.
Do not follow a moving branch:

```bash
FEATURE_SHA=replace-with-exact-reviewed-commit-sha
git clone --branch feat/amneziawg-support --single-branch \
  https://github.com/NikitaS2001/vps-nook.git vps-nook-prerelease
cd vps-nook-prerelease
git checkout --detach "${FEATURE_SHA}"
test "$(git rev-parse HEAD)" = "${FEATURE_SHA}"
```

Before running the shared production role:

1. Complete the existing encrypted-vault/private-inventory preparation.
2. Use the pinned controller toolchain.
3. Review SSH access and provider rescue access.

Do not bypass signed-release or host-key verification for normal signed-release use.
The optional `NOOK_DEV_MODE=1` installer check has these requirements:

- The operator separately confirms that the exact target is disposable.
- The operator locally verifies the installer bytes and SHA.
- The operator labels the check **NON-PRODUCTION**.

This development-mode check is not equivalent to the signed-release installer.
Never pipe an unreviewed branch script into `sudo`.
Never weaken signer verification.

Record evidence privately. Check each item:

- Target/kernel identity and module receipt.
- An authenticated handshake from a matching AWG client.
- DNS resolution and trusted HTTPS for both internal names.
- No-tunnel negatives.
- Service-mode IPv4/IPv6 enforcement.

For `full`, verify IPv4 egress.
Verify only the IPv6 default route supported by the successful host probe.
Test both IPv6 omission and deny cases.
Rerun without changing peer/volume identities.
Confirm a new handshake.

Before an operator reboot, require each condition:

- A verified `installed` receipt for the exact target ABI.
- Successful header/DKMS hooks.
- Available rescue access.

After boot, verify that the module is loaded.
Establish a fresh handshake.
A failed hook does not roll back kernel packages.
Provider-initiated reboots remain outside this policy.
Keep raw inventory, vaults, keys and logs private.
Remove only owned disposable resources.

Installer reruns preserve the backend in the encrypted vault:

- Omitting `NOOK_VPN_BACKEND` preserves the saved backend.
- A matching `NOOK_VPN_BACKEND` is accepted.
- A conflicting `NOOK_VPN_BACKEND` is rejected.

Legacy vaults without `wg_amnezia_enabled` remain WG without a vault rewrite.
Do not delete or edit saved state to force a switch.
There is no silent migration or supported controller transition procedure for existing peers.
Changing the wire protocol requires refreshed profiles and matching applications.

## Removing the deployment

There is no automated uninstall. First verify an off-host backup and restore a
safe SSH/firewall configuration with console access available. Then stop Compose
and remove only confirmed project paths. Removing service volumes and installer
state destroys VPN peers, DNS state, certificates and saved credentials; host
users, Docker and firewall rules require separate review.
