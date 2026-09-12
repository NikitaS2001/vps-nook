# End-to-end tests

These tests use disposable QEMU/KVM guests. They prove repository-controlled
host behavior; they do not prove a provider firewall, provider routing, or a
real host lifecycle. GitHub Actions stores no VPS credentials.

Local prerequisites are `qemu-system-x86_64`, `qemu-img`, KVM,
`genisoimage`, OpenSSH, curl, and the tools installed by
[`scripts/bootstrap.sh`](../../scripts/bootstrap.sh).

## Standard entry points

```bash
./scripts/check.sh --e2e
./scripts/check.sh --release
```

`--e2e` runs the repository installer in explicit development-source mode on
the CI-selected Debian 12 or Ubuntu 24.04 image. It exercises default
`services` behavior with a real in-guest client, reruns idempotently, and
reboots. Production tag and attestation verification are separate release
contracts. `--release` adds the lifecycle upgrade/restore drill and those
release contracts.

## Repository installer guest

```bash
tests/e2e/qemu-install.sh \
  --client-test --idempotency-test --reboot-test
```

Supported flags:

| Flag | Scenario |
| --- | --- |
| `--client-test` | WireGuard handshake, DNS, and internal HTTPS from an in-guest client |
| `--idempotency-test` | No-change rerun and service identity/state preservation |
| `--reboot-test` | Host reboot followed by full readiness verification |
| `--bootstrap-timeout-test` | Interrupted initial wg-easy readiness and recoverable rerun |
| `--stopped-container-test` | Readiness failure when a managed service is stopped |
| `--invalid-caddy-test` | Invalid and reload-failing Caddy candidates preserve active state |

Environment controls include `QEMU_IMAGE`, `QEMU_USER`, `INSTALL_REF`,
`E2E_SOURCE_MODE`, `NOOK_WG_TRAFFIC_MODE`, guest service ports, and host
forwarding ports. Ubuntu 24.04 is the default image. For Debian 12:

```bash
QEMU_IMAGE=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2 \
QEMU_USER=debian \
tests/e2e/qemu-install.sh --client-test --idempotency-test
```

`NOOK_WG_TRAFFIC_MODE=full` requires IPv4 egress. A dual-stack test
environment additionally exercises IPv6 routing; IPv4-only hosts generate
IPv4-only full-tunnel profiles.

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

This harness creates ignored controller inventory and encrypted vault fixtures,
deploys over SSH, and removes the controller fixtures during cleanup.

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

Normal mode requires a pinned `VPS_KNOWN_HOSTS` file, private SSH key, VPS host,
ports, and a provider environment. `--prepare-only` and `--cleanup` are mutually
exclusive. This is manual operator evidence, not a merge requirement.

`run-public-install.sh` exercises an explicit tag or development ref against a
fresh real VPS and accepts `--client-test` and `--reboot-test`. It requires an
explicit VPS address, key, source ref, and pinned known-hosts input. It is a
maintainer harness, not a replacement for the verified release path in the
root README. Never place live credentials in repository files, logs, or CI.

## Evidence boundary

Current pull-request CI runs the installer from the checked-out source in
explicit development mode and `services` mode on Debian 12 and Ubuntu 24.04.
Weekly automation runs every Monday at 02:17 UTC (Greenwich time) and supports manual dispatch
for pre-release checks and diagnostics. It repeats that default-mode matrix to catch upstream image
drift and adds the lifecycle upgrade/restore scenario on Ubuntu. Public-IPv6
packet proof for `full` is a manual dual-stack scenario because generic
GitHub-hosted runners do not guarantee IPv6 egress.

The pytest QEMU gate includes repository-installer Caddy failure scenarios.
Remote SSH/UFW negative cases are available through `pytest -m remote`; they are
not part of routine CI or the `check.sh --release` sequence. Run them when a change
touches the corresponding boundary and report the exact scenarios that completed.
Persist logs only in a
private evidence directory and scan them for credentials before sharing.

The provider firewall remains the operator's responsibility. Keep console or
rescue access during every real deployment.

## Pytest entrypoints

Activate `.venv`, then use `pytest -m qemu` for services installation, client,
idempotency, reboot, bootstrap-timeout, stopped-container and invalid-Caddy
scenarios. `pytest -m remote` runs SSH rollback/cutover/reboot and UFW backend
failure in a disposable VM; native `test_ssh_recovery_mocked_systemd` cases
only render recovery tasks with mocked systemd.

`pytest -m lifecycle` runs baseline/current/rerun/encrypted restore with the
existing harness, including its explicit pre-release reinstall/restore fallback.
The terminal and JUnit record `lifecycle_baseline_kind`; `bootstrap-snapshot`
is not proof of an upgrade from a released version. An explicitly requested
missing `E2E_BASELINE_REF` remains an error. All image/user/port settings above
remain applicable.
Run each supported platform explicitly with its image and cloud user.
Source snapshots and deployment files are private to each test. Pytest takes
ownership of cleanup; keep-state debugging applies only to direct Bash runs.
Missing KVM/tools fail the selected suite. Logs remain private locally; CI
uploads only JUnit summaries. See [acceptance evidence](../../docs/pytest-validation.md).
