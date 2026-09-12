# Contributing

Thanks for taking the time to improve this project.

This is a personal Open Source project, maintained primarily for the author's
own infrastructure. Contributions are welcome when they improve security,
correctness, clarity, or reproducibility without making the core harder to
understand. Issues and pull requests are reviewed on a best-effort basis.

There is no guaranteed response SLA, public roadmap, or commitment to
implement feature requests, backport changes, or support every deployment
environment. Small, focused changes are the easiest to review.

## Before opening a pull request

1. Search existing issues and pull requests.
2. For a substantial design or feature change, open an issue first.
3. Keep the change focused and update the relevant documentation and tests.
4. Do not include credentials, private host details, generated evidence, or
   other private planning artifacts.

## Local checks

Set up the development environment with:

```sh
./scripts/bootstrap.sh
```

Run the fast checks before submitting a pull request:

```sh
./scripts/check.sh
```

If your change affects the deployment or release paths, also run the relevant
extended checks described by `./scripts/check.sh --help`.

## Pull requests

Pull requests should explain the problem, the chosen approach, and how the
change was tested. Include security and operational impact when applicable.

The maintainer may request changes, defer a contribution, or close it when it
does not fit the project's scope or minimal design. A pull request is not an
agreement to provide ongoing support for the resulting configuration.

By submitting a contribution, you confirm that you have the right to submit
it under the repository's [MIT License](LICENSE).

## Selecting tests

After `source .venv/bin/activate`, `pytest` runs quick checks and `pytest -k installer`
selects installer checks. Use `pytest -m qemu`, `pytest -m lifecycle`,
`pytest -m remote`, or `pytest -m release` for the corresponding suites.
`pytest --collect-only` lists all cases without commands or fixture preparation.
Explicit `-m` overrides the default quick selection. Empty selections return 5;
invalid arguments return 4. Pytest collects failures; `scripts/check.sh` uses `-x`
and stops at the first failed gate. `--e2e` runs quick then QEMU; `--release`
runs quick, QEMU, lifecycle, then release contracts (SBOM runs once).

Tests run sequentially; do not use xdist. Missing selected-suite prerequisites
are failures. Passwordless sudo is optional only for the local installer sudo
case; CI requires it. Each Bash adapter has a 15-minute timeout, VM/remote
adapters 70 minutes, and lifecycle 80 minutes. Lifecycle preserves the existing
pre-release reinstall/restore fallback and records `lifecycle_baseline_kind`
in JUnit. A `bootstrap-snapshot` result is not released-version upgrade proof.
Cancellation allows 30 seconds
for cleanup before force-stopping owned processes. Daemonized QEMU ownership
uses PID, Linux process start time and the VM disk path.

Private source snapshots preserve Git history, tags and dirty source files but
exclude ignored inventory/vault state. No deployment fixtures modify your checkout.
Full local command logs live in a printed private `nook-pytest-logs.*` directory
(mode 0700, files 0600); remove these after diagnosis. JUnit contains summaries,
not captured command output. CI retains only JUnit for seven days. Use
`pytest --junitxml=reports/local.xml`, or `NOOK_JUNIT_DIR=reports scripts/check.sh`.
See [the migration map](docs/pytest-migration.md) and
[acceptance evidence](docs/pytest-validation.md). Release signing and publication
remain separate operations.
