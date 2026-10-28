# End-to-end tests

These tests use disposable QEMU/KVM guests. They prove repository-controlled
guest behavior, including lifecycle; they do not prove provider firewall or
external routing. GitHub Actions stores no VPS credentials.

Local prerequisites are `qemu-system-x86_64`, `qemu-img`, KVM,
`genisoimage`, OpenSSH, curl, and the tools installed by
[`scripts/bootstrap.sh`](../../scripts/bootstrap.sh).
Prepare `strace` before bootstrap. Shared installer PTY checks require
Python 3.9+ and Linux 5.3+ with working `pidfd_open`; supported Debian 12 and
Ubuntu 24.04 images meet those version requirements.

## Standard entry points

After bootstrapping, activate `.venv` and select one suite:

| Command | Scenarios |
| --- | --- |
| `pytest -m qemu` | Core installation with six recovery/client flags, plus the stock WG/AWG matrix. No optional recipes |
| `pytest -m extension` | Vaultwarden recipe, Caddy activation, trusted HTTPS, rerun and reboot |
| `pytest -m remote` | Real SSH rollback/cutover, UFW failure and reboot |
| `pytest -m lifecycle` | Baseline/current/rerun/encrypted restore |

Each command runs one platform. Ubuntu 24.04 is the default.
Use image and user overrides for Debian. Missing KVM/tools fail.
Tests use private source snapshots and deployment files. Pytest owns cleanup.

Keep-state debugging is available only through direct Bash harnesses.
For quick checks, gate ordering and private logs, see [Contributing](../../CONTRIBUTING.md).

The examples below invoke Bash directly for targeted scenarios. Production
signed-tag and attestation verification remain separate release contracts.

## Repository installer guest

```bash
tests/e2e/qemu-install.sh \
  --client-test --idempotency-test --reboot-test
```

Run the registered Vaultwarden extension scenario separately:

```bash
pytest -m extension
```

It proves hardened `sysadmin` SSH, `sudo manage.sh`, installer-owned Caddy
activation, and Vaultwarden trusted HTTPS through the in-guest WireGuard client.

The extension scenario uses a separate guest with WG/services routing. It does
not change the core scenario. Direct targeted runs can still use
`tests/e2e/qemu-install.sh --vaultwarden-test --reboot-test`.

Before provisioning, the harness runs the installer dialogue through a real
`sudo` pipeline and PTY as the guest's unprivileged cloud user.
Provisioning functions are stubbed for this dialogue check.
The dialogue check verifies root execution, completion, and hidden password input.
Privileged fixture execution and cleanup stay inside the disposable guest.
Local quick checks never invoke host `sudo`.

Repository-copy setup installs missing git/strace packages and probes pidfd
before the shared fixture. Package or syscall failure stops the harness before
repository transfer or fixture invocation; it does not imply a passing sudo/PTY
scenario. Real guest sudo/ptrace interoperability is proved only by the QEMU run.

Supported flags:

| Flag | Scenario |
| --- | --- |
| `--client-test` | WireGuard handshake, DNS, and internal HTTPS from an in-guest client |
| `--idempotency-test` | No-change rerun and service identity/state preservation |
| `--reboot-test` | Host reboot followed by full readiness verification |
| `--bootstrap-timeout-test` | Interrupted initial wg-easy readiness and recoverable rerun |
| `--stopped-container-test` | Readiness failure when a managed service is stopped |
| `--invalid-caddy-test` | Invalid and reload-failing Caddy candidates preserve active state |
| `--vaultwarden-test` | Clean Vaultwarden recipe check/install/exact resume, installer Caddy activation, and trusted HTTPS through WireGuard |

Environment controls include `QEMU_IMAGE`, `QEMU_USER`, `INSTALL_REF`,
`E2E_SOURCE_MODE`, `NOOK_WG_TRAFFIC_MODE`, guest service ports, and host
forwarding ports. Ubuntu 24.04 is the default image.

`QEMU_IMAGE_CACHE_DIR` optionally enables a persistent caller-owned mode-0700 cache.
The cache accepts only exact URL/SHA pairs from `tests/registry.py::FRESH_IMAGES`.
The harness rehashes every cache hit.
For a cache miss, the HTTPS download has these limits:

- A 15-second connection timeout.
- A 30-minute overall timeout.
- A 2-GiB size cap.
- No retry loop.

The harness publishes the cache entry atomically only after its SHA matches.
Symlinks, wrong owners/modes, corrupted entries, and existing per-run destinations fail closed.
The harness copies the per-run image into the QEMU scratch directory and verifies it again.
Local/custom images are not cached and keep the existing SHA check.
Cache contents are raw registered stock images only.
Never use prepared guest disks or AWG state in the cache.

For Debian 12:

```bash
QEMU_IMAGE=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2 \
QEMU_USER=debian \
tests/e2e/qemu-install.sh --client-test --idempotency-test
```

`NOOK_VPN_BACKEND=wg` (default) or `awg` selects both the installer and the
exact `wg show wg0` / `awg show wg0` readiness query.
`tests/e2e/prepare-vpn-client.sh wg|awg` prepares matching client tools inside
the disposable guest. Both backends install `jq`, `openssl`, and `dnsutils`.
WG also installs `wireguard-tools`. Package failure stops before peer creation.
Fresh AWG images must have no prepared server module or DKMS state.
The production role installs the server module.
The AWG client-tools build runs after deployment.
Client checks require these tools:

- `curl`, `jq`, `ip`, `dig`, `ping`, and Python 3.
- The matching `wg` / `wg-quick` or `awg` / `awg-quick`.

The harness never prepares the server module before the installer.
It does not install a userspace fallback. Missing prerequisites fail.

WG and AWG client preparation preserve an active `systemd-resolved` provider.
They use `resolvectl`'s `resolvconf` compatibility entry point instead of
installing a second resolver manager. Installing Debian `resolvconf` can remove
`systemd-resolved` and break guest DNS before reboot.
Preparation refuses an existing conflicting provider without changing it.
An active service requires executable `resolvectl`.
An indeterminate service query refuses preparation before APT or alias creation.
Only a positively inactive systemd resolver uses the distro `resolvconf` package.
This policy applies to client tooling inside disposable guests, not host DNS configuration.

The pinned wg-easy 15.4.0 source ships amneziawg-tools v3.0.20260805.
Compatible client tools must support its generated Jc/Jmin/Jmax, S1-S4,
H1-H4 and optional I1-I5 fields.
Verify runtime compatibility with the pinned image digest on a fresh stock guest through the production role.
Include an authenticated client handshake.
Source inspection alone cannot establish runtime compatibility.

The interrupted-first-setup fixture runs before any client exists. It refuses
retained clients or an unexpected administrator identity. The fixture restores
the first-user allocation state before the installer retries bootstrap. Later
rerun and reboot checks preserve the administrator and retained peer.

Before a retry, the harness recopies private source as the hardened administrator.
It does not make cloud-user source public.

The client peer is created before the first completed-state rerun or reboot.
Its ID, original private profile and identity fingerprint remain in a private
guest directory until final cleanup.
If peer deletion fails, cleanup preserves the ownership marker and peer ID for
a later cleanup attempt. It still removes temporary session credentials.
Every boundary check compares server identity, peer membership and profile parameters.
Each check recreates only the client kernel interface and requires a bound, CA-authenticated HTTPS response.
That fresh interface has no prior session keys.
A positive old timestamp alone cannot pass.
DNS uses the tunnel address and routes, and both internal names
must resolve to `10.66.0.3`. Removing the interface must break bound DNS/HTTPS
while direct dual-stack controls remain reachable.

A temporary, unprivileged container reuses the already-deployed image
without pulling or publishing ports. It provides controlled forbidden IPv4
and IPv6 destinations outside the services allowlist.
Both direct controls must work.
Both tunnel requests must fail in services mode.
Allowed IPv6 traffic to the VPN server must also work.
Missing controlled IPv6 proof is a failure, never a skip.

`full` requires IPv4 egress.
Public IPv6 remains a separately reported optional control.
A full profile containing `::/0` requires an actual successful public IPv6 probe.

Client probes use a dedicated routing table with source and output-interface
rules. Host routes remain unchanged, so direct controls also work with strict
reverse-path filtering. An occupied table or rule priority stops the probe.
Numeric table queries also detect tables with configured iproute2 names.
Cleanup removes only the rules and routes created by that probe.

Service recovery subscribes to Docker events before starting a container.
Reboot installs an owned disposable oneshot and arms an inotify serial
observer before the trigger; a nonce, a new boot ID, service health and
authenticated SSH must all agree. Waits are bounded. Cleanup removes the
observer, guest unit, test container, peer and private credential artifacts.
The host cancels its observer by closing an owned pipe, not by signalling a
numeric PID that Bash may already have reaped.
The source/packet contracts execute safe adapters and the native observer;
they do not prove guest packets, cryptographic handshakes or sudo portability.

AWG installer cases also run `awg-build-cancellation.py` inside the disposable
guest. It uses the production build-transaction owner with an isolated state
directory and a service containing a worker and child process. SIGTERM and
SIGINT must stop both processes before releasing the lock or removing the
transaction marker. This proves service cancellation, not a kernel upgrade.
The normal installer still builds and verifies the actual AWG module.

The Vaultwarden path proves real Compose health, private/no-port runtime through
`manage.sh verify`, AdGuard DNS, WireGuard routing, the Caddy root CA, and a
2xx/3xx response from `vw.<suffix>` after reboot and installer rerun. It does
not prove provider firewall/external routing or Vaultwarden account, UI, login,
logout, or vault-item semantics.

## Remote controller guest

```bash
tests/e2e/qemu-remote-install.sh \
  --ssh-cutover-test --ssh-rollback-test \
  --ufw-backend-failure-test --reboot-test
```

| Flag | Scenario |
| --- | --- |
| `--ssh-cutover-test` | New login is proven before the old path is removed |
| `--ssh-rollback-test` | Failed SSH candidate restores the authenticated path |
| `--ufw-backend-failure-test` | Firewall backend failure preserves recovery access |
| `--reboot-test` | Remote deployment remains ready after reboot |

This harness creates inventory and encrypted vault fixtures in a private source
copy, deploys over SSH, and cleans up that copy. Operator files stay untouched.
Native `test_ssh_recovery_mocked_systemd` cases only render tasks with mocked
systemd; they do not replace this VM test.

## Lifecycle and restore

```bash
E2E_ARTIFACT_DIR=/absolute/private/path \
  tests/e2e/lifecycle-qemu.sh
```

The lifecycle harness deploys a signed Nook baseline (`E2E_BASELINE_REF`, default
`v2.0.0`), upgrades the same guest to the exact working tree, performs a no-change
rerun, and runs encrypted backup/restore. Before the first Nook release exists,
the default baseline is explicitly a working-tree snapshot: this proves
reinstallation and restore, not an upgrade from a released version. Explicitly
requested missing tags fail. Legacy v1 state is rejected in installer contracts;
in-place v1 migration is not supported. It accepts no
command-line flags; use `--help` for its environment variables. Set
`E2E_SOURCE_FIXTURE_ONLY=1` to validate the dual-ref fixture without a VM.

`restore-drill.sh --self-test-age-provenance` exercises age-package provenance
failure and interruption fixtures without a deployment target.

## External client and real VPS harnesses

`external-client-qemu.sh` connects a disposable client VM to an already
deployed VPS. Its explicit lifecycle modes are:

```bash
tests/e2e/external-client-qemu.sh --prepare-only --state-dir <private-dir>
tests/e2e/external-client-qemu.sh --cleanup --state-dir <private-dir>
```

Every mode requires these inputs:

- An explicit `VPS_HOST`. There is no default target.
- A pinned `VPS_KNOWN_HOSTS` file.
- A private SSH key.
- Ports and a provider environment.

Cleanup requires the exact host/SSH port/user captured in private `peer.env`.
A mismatch is rejected before remote actions and preserves state for a retry.
`--prepare-only` and `--cleanup` are mutually exclusive.
This is manual operator evidence, not a merge requirement.

`run-public-install.sh` exercises an explicit tag or development ref against a
fresh real VPS and accepts `--client-test` and `--reboot-test`. It requires an
explicit VPS address, key, source ref, and pinned known-hosts input. It is a
maintainer harness, not a replacement for the verified release path in the
root README. Never place live credentials in repository files, logs, or CI.

## Evidence boundary

Current pull-request CI runs the installer from the checked-out source in
explicit development mode and `services` mode on Debian 12 and Ubuntu 24.04.
The Weekly workflow is configured for every Monday at 02:17 UTC (Greenwich time) and supports manual dispatch
for pre-release checks and diagnostics. It repeats that default-mode matrix to catch upstream image
drift and adds the lifecycle upgrade/restore scenario on Ubuntu. Public-IPv6
packet proof for `full` is a manual dual-stack scenario because generic
GitHub-hosted runners do not guarantee IPv6 egress.

The core QEMU gate includes repository-installer Caddy failure scenarios, but
does not install Vaultwarden. `pytest -m extension` runs the recipe separately.
CI and Weekly publish independent core and extension results with separate
JUnit artifacts. Release acceptance includes both groups.

Private guest state, `nook-pytest-logs.*` diagnostics, and sentinel cleanup
remain pytest-owned for both groups.
For direct failure diagnosis only, set `E2E_KEEP_STATE_ON_FAILURE=1` with an
empty private `QEMU_STATE_DIR`.
The owned QEMU stays alive for diagnosis. The harness stops the host serial observer.
Use the same checkout for cleanup.
Stop the exact owned VM only through the guarded owner.
Remove its state only through the guarded owner:

```bash
python3 tests/qemu_owner.py cleanup "${QEMU_STATE_DIR:?}" \
  --sentinel "${QEMU_STATE_DIR:?}/.qemu-install-state" qemu-install-v1
```

The owner uses PIDFD signals.
It verifies captured process/disk/executable identity and private directory identity.
Unsupported PIDFD, missing startup identity, or any mismatch preserves state.
Do not replace these checks with numeric PID kills or blind directory removal.

External-client cleanup must use its own `--cleanup` mode.
That mode also reconciles the captured peer on the confirmed VPS.

Remote SSH/UFW negative cases are available through `pytest -m remote`.
They are not part of routine CI or the `check.sh --release` sequence.
Run these cases when a change touches the corresponding boundary.
Report the exact scenarios that completed.

Persist logs only in a private evidence directory.
Scan logs for credentials before sharing.

The provider firewall remains the operator's responsibility. Keep console or
rescue access during every real deployment.

Record tested revisions and completed scenarios in the pull request.
See [Releasing](../../docs/releasing.md) for outstanding acceptance gates.
JUnit records `lifecycle_baseline_kind`.
A `bootstrap-snapshot` result does not prove a released-version upgrade.


### Fresh WG/AWG acceptance

Registered `fresh-<debian|ubuntu>-<wg|awg>-<services|full>` cases use dated stock images.
The cases verify SHA256 before starting a guest.
AWG cases configure RAM to reach approximately 900 MiB of OS-visible RAM:

- 952 MiB for Debian.
- 963 MiB for Ubuntu.

The installer still enforces the actual OS-visible minimum.
The harness prepares client tools only after production module installation.
`pytest -m qemu` runs these cases sequentially, with retained-peer rerun/reboot checks.
A successful module build alone does not satisfy their packet, DNS, HTTPS or policy assertions.

The Debian pin uses the official 2026-10-23 daily build.
It contains the current `libexpat1` security version needed by the authenticated dependency closure.
The previous dated image contains a retired version and fails AWG feasibility.
Refreshing this test image does not permit package upgrades or waive archive authentication.

For manual runs, `QEMU_RAM_MIB` defaults to 2048.
The `QEMU_IMAGE_SHA256` input supplies an expected cloud-image digest.
Before counting a changed image as a supported acceptance case, validate each item:

- Image trust.
- Exact kernel.
- Actual RAM.
