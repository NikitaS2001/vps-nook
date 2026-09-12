# Pytest acceptance evidence

Validation date: 2026-09-12. These runs use the uncommitted working tree,
including pre-existing deployment changes. They do not certify a tagged release.
The preserved boundaries are listed in the [migration map](pytest-migration.md).

## Local checks

- `scripts/check.sh`: 93 passed, one permitted local sudo skip (214.63 seconds).
- Direct `pytest`: 93 passed, one permitted local sudo skip (216.39 seconds).
  The JUnit testcase sets match `check.sh` exactly: 94 quick cases, zero VM cases.
- Runner fault-injection suite: 51 passed, including TERM-ignoring descendants,
  short Unix socket paths, detached merge snapshots, the mandatory SSH matrix,
  VM gate flags and lifecycle provenance allowlisting.
- `pytest -m release`: six passed, including the PR release contract. Signing
  fixtures stayed isolated; no project release was signed, drafted, attested or
  published.
- All seven tool checks passed: Bash syntax for every selected file, ShellCheck,
  Ansible syntax, ansible-lint, yamllint, the Gitleaks hook and SSOT.
- Collection includes separate installer PTY cases and four explicitly named
  mocked-systemd SSH recovery cases. Selection/empty selection/argument errors,
  closed stdin, exit propagation, timeout, SIGINT/SIGTERM, snapshot isolation,
  setup failure, daemonized VM ownership and incomplete cleanup are exercised.
- Synthetic secrets were absent from terminal output and JUnit for assertion,
  setup, explicit pytest failure, failed command and lifecycle provenance cases.

Reports from this session are private local artifacts under `/tmp`:
`nook-final-check/quick.xml`, `nook-final-default.xml`, `nook-runner-final-complete.xml`
and `nook-final-release.xml`. Raw diagnostics stay in private `nook-pytest-logs.*`
directories (0700 directories, 0600 files); CI uploads only JUnit summaries.

## VM acceptance

Ubuntu 24.04: the complete `qemu` case passed in 1721.22 seconds, including
bootstrap timeout/scrub/retry, stopped-container recovery, reboot, real client
handshake, idempotency, Caddy candidate/reload rollback and nonzero setup retry.
The runner completed cleanup successfully. Report: `/tmp/nook-qemu-ubuntu-final.xml`.
Debian 12: the same complete `qemu` case passed in 973.81 seconds with cleanup.
Report: `/tmp/nook-qemu-debian.xml`.
Ubuntu remote SSH: passed in 337.74 seconds, including an authenticated old
session and fresh login after rollback, rollback reboot, cutover with old-port
closure, UFW backend failure recovery, full deployment and final reboot.
Cleanup passed. Report: `/tmp/nook-remote-final.xml`.
Lifecycle: passed in 676.12 seconds, including current-source application,
no-change rerun, encrypted restore, restored stack/network readiness and cleanup.
Report: `/tmp/nook-lifecycle-final.xml`; JUnit explicitly records
`lifecycle_baseline_kind=bootstrap-snapshot`.

The first Ubuntu negative-bootstrap run found a harness bug: a provenance check masked a nonzero installer status when
called in a conditional. The harness now preserves the pipeline status; native
success/failure fixtures verify that behavior. No installer behavior was changed.
The runner also handles QEMU removing its pidfile on normal exit, covered by a
cleanup regression case. Remote verification also exposed the Unix socket
path limit: runtime state now uses a short private `/tmp` directory, with a
real AF_UNIX bind/cleanup regression test.

The configured origin and local checkout currently have no v2 release tags.
An explicit missing-baseline probe failed before VM creation and reported both
VM-stop and ephemeral-state cleanup success. The normal lifecycle command
preserves the existing pre-release reinstall/restore fallback and records
`lifecycle_baseline_kind=bootstrap-snapshot` in JUnit. Such a run does not prove
an upgrade from a released version.

Final ownership audit found zero live test-owned VMs and zero remaining short
runtime directories. Only private diagnostic logs and JUnit reports were retained.

## CI boundary

Workflow contracts validate the retained CI job structure and platform matrix,
pytest/bootstrap entrypoints, 80-minute QEMU job limits and always-uploaded
JUnit summaries with seven-day retention. Two actual successful Weekly runs
against the final published commit remain required for migration acceptance.
These may be dispatched manually without waiting for the weekly schedule.
Weekly runs on Mondays at 02:17 UTC (Greenwich time). Local runner checks are
not substitutes for those runs or another revision's release gates.

## PR review follow-up

Review found that a parent could exit immediately on SIGTERM while a child was
still cleaning up. The runner now gives the whole process group the remaining
grace period before SIGKILL. A regression case checks that a surviving child can
finish its cleanup after the parent exits; all 52 runner cases passed locally.
Final commit and CI evidence will be recorded in the pull request.

The first PR CI run failed in the restore sandbox. A local stress probe reproduced
a race in its activation-interrupt observer: the project directory could move
between checking the payload's existence and Bash's shorthand file read, aborting
the fixture. The observer now tolerates that temporary absence while waiting for
the restored payload. Production restore behavior is unchanged. After the fix,
50 concurrent-root and 50 activation-interrupt cycles passed without retries of
failed cases. Failure summaries also include allowlisted restore stage names;
raw fixture output remains private.
