# Contributing

Small, focused changes are welcome. For substantial design changes, discuss an
issue first. Pull requests should explain the problem, resulting behavior,
validation and operational impact. Update the owning guide and relevant tests;
exclude credentials, inventories and private logs. Reviews are best-effort,
without a response SLA. Contributions use the [MIT License](LICENSE).

## Setup and checks

```bash
./scripts/bootstrap.sh
./scripts/check.sh
source .venv/bin/activate
```

`check.sh` finds `.venv` automatically. Direct tool commands require activation.
Pytest runs sequentially; do not use xdist.

| Command | Selection |
| --- | --- |
| `pytest` | Unprivileged quick tools, native fixtures and Bash contracts; no VM |
| `pytest -k installer` | Installer cases within quick |
| `pytest -m qemu` | Services-mode VM installation and negative scenarios |
| `pytest -m remote` | Real SSH rollback, cutover, UFW failure and reboot |
| `pytest -m lifecycle` | Baseline, current source, rerun and encrypted restore |
| `pytest -m release` | Local release contracts; no publication |
| `pytest --collect-only` | All cases without commands or deployment preparation |
| `scripts/check.sh --e2e` | Quick, then QEMU |
| `scripts/check.sh --release` | Quick, QEMU, lifecycle, then remaining release contracts |

Explicit `-m` replaces the default quick selection. Empty selections return 5;
invalid arguments return 4. Pytest collects failures; `check.sh` uses `-x` and
stops at the first failed gate. SBOM runs once in the release sequence.
Missing prerequisites fail. Quick checks do not invoke host `sudo` or require
passwordless sudo, including in CI. The real installer sudo/PTY scenario runs
inside the disposable QEMU guest. See [E2E](tests/e2e/README.md) for VM
prerequisites and scope.

## Isolation and diagnostics

Deployment fixtures use private source snapshots preserving Git history, tags
and dirty source files, excluding ignored operator inventory/vaults. They do
not prepare deployment files in your checkout. Bash adapters time out after
15 minutes, QEMU/remote after 70, lifecycle after 80. Cancellation allows
30 seconds for cleanup; daemonized QEMU ownership requires PID, process start
time and disk path. Incomplete cleanup fails the test.

Use `pytest --junitxml=reports/local.xml` or
`NOOK_JUNIT_DIR=reports scripts/check.sh`. Full logs stay in the printed private
`nook-pytest-logs.*` directory (0700, files 0600); remove them after diagnosis.
JUnit contains summaries, not captured command output. CI retains JUnit for
seven days. Never publish raw logs without checking them for secrets.

Register Bash contracts in [tests/registry.py](tests/registry.py), which also
preserves required historical and native scenario boundaries. Record validation
results and the tested commit in the pull request. Signing, remaining acceptance
gates and publication follow [Releasing](docs/releasing.md).
