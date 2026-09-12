# End-to-end tests

These tests use disposable QEMU/KVM guests. They prove repository-controlled
guest behavior, including lifecycle; they do not prove provider firewall or
external routing. GitHub Actions stores no VPS credentials.

Local prerequisites are `qemu-system-x86_64`, `qemu-img`, KVM,
`genisoimage`, OpenSSH, curl, and the tools installed by
[`scripts/bootstrap.sh`](../../scripts/bootstrap.sh).

## Standard entry points

After bootstrapping, activate `.venv` and select one suite:

| Command | Scenarios |
| --- | --- |
| `pytest -m qemu` | Services installation with all six flags listed below |
| `pytest -m remote` | Real SSH rollback/cutover, UFW failure and reboot |
| `pytest -m lifecycle` | Baseline/current/rerun/encrypted restore |

Each command runs one platform; Ubuntu 24.04 is the default. Use image and user
overrides for Debian. Missing KVM/tools fail. Tests use private source snapshots
and deployment files; pytest owns cleanup. Keep-state debugging is available
only through direct Bash harnesses. For quick checks, gate ordering and private
logs, see [Contributing](../../CONTRIBUTING.md).

The examples below invoke Bash directly for targeted scenarios. Production
signed-tag and attestation verification remain separate release contracts.

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
The Weekly workflow is configured for every Monday at 02:17 UTC (Greenwich time) and supports manual dispatch
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

Record tested revisions and completed scenarios in the pull request; see
[Releasing](../../docs/releasing.md) for outstanding acceptance gates. JUnit records `lifecycle_baseline_kind`; a
`bootstrap-snapshot` result does not prove a released-version upgrade.
