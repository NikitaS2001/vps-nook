# Repository Guidelines

## Project Overview

VPS Nook provisions one hardened VPS with Ansible: key-only SSH, UFW, fail2ban, and a private Docker stack of WireGuard (`wg-easy`), AdGuard Home, and Caddy internal TLS. Only SSH and WireGuard UDP are public; administration UIs stay localhost/private-network only.

Both remote controller-managed Ansible and the signed-release `install.sh` installer use `site.yml`. Treat changes as security-sensitive infrastructure work. Do not mix controller-managed configuration with installer state.

## Architecture & Data Flow

`site.yml` runs two privileged, fact-gathering plays on inventory group `vps`, in order:

1. `vps_hardening` (`hardening` tag): platform preflight → packages → administrator → sysctls → UFW → SSH cutover → fail2ban.
2. `vps_orchestration` (`orchestration` tag): vault/network preflight → netfilter → Docker → volumes → AdGuard → Compose/Caddy/bootstrap → traffic-policy reconciliation → Docker/UFW integration → runtime verification.

Role defaults and `group_vars/all` supply inputs; argument specifications and task assertions enforce contracts. Jinja templates render configuration, registered facts carry observed state, and handlers apply deferred changes. Keep changes in the owning phase file; each role's `tasks/main.yml` controls ordering and include/tag boundaries.

The services share dual-stack `vpn_net`. AdGuard resolves internal names to Caddy, which terminates internal TLS and proxies the UIs. Verification fetches the public CA to `fetched_certs/<inventory-host>/root.crt`. Service state defaults to `/opt/vps-nook`; encrypted installer inputs live under `/etc/vps-nook`, separately from its checkout and virtualenv under `/opt/vps-nook-installer`.

`wg_traffic_mode: services` restricts destinations on the server, not merely through client AllowedIPs. `full` requires IPv4 egress; IPv6 default routing requires a successful egress probe. Mode changes reconcile persisted markers, wg-easy SQLite policy, and live firewall rules; clients need refreshed profiles.

Preserve these transaction boundaries:

- **SSH/UFW:** allow current/new SSH and WireGuard before default-deny. Validate the SSH candidate, preserve service/socket rollback, flush handlers, and authenticate the new connection before removing old-port access.
- **Caddy:** validate the candidate together with operator extensions before activation. Preserve the bind-mounted file inode, reload, and restore on failure; do not substitute an atomic rename or generic template restart.
- **Bootstrap/policy:** wg-easy SQLite determines initialization state. Scrub Compose `INIT_*` credentials after bootstrap and on failure. Preserve policy snapshots, schema checks, rollback, and fail-closed handling of interrupted transactions. Docker bypasses ordinary UFW rules: retain the subsequent `ufw-docker` reconciliation.
- **Secrets/state:** retain `no_log: true`, restrictive permissions, and path/symlink guards. Never recreate volumes or discard malformed vault/policy state to make a rerun succeed.

## Key Directories

- `roles/vps_hardening/`, `roles/vps_orchestration/` — implementation and public input references; tasks, templates, handlers, defaults, and argument specifications evolve together.
- `group_vars/all/`, `inventory/` — tracked examples and ignored operator configuration. `inventory/localhost.yml` supports installer/local execution.
- `tests/installer/`, `tests/contracts/`, `tests/runner/` — native Python tests and adapters; `tests/validation/` retains Bash contracts; `tests/e2e/` owns VM/remote harnesses.
- `scripts/` — contributor gates, live operations, release tooling. `docs/` and role READMEs own detailed procedures and input references.
- `examples/` — optional private Compose/Caddy extensions; `.github/workflows/` — CI, weekly lifecycle, and release workflows.

## Development Commands

No compilation step. Bootstrap the pinned Python/Ansible toolchain first:

```bash
scripts/bootstrap.sh                 # create .venv; install tools and collections
scripts/check.sh                     # quick tools, native fixtures, Bash contracts
scripts/check.sh --e2e               # quick, then services-mode QEMU scenarios
scripts/check.sh --release           # quick, QEMU, lifecycle, remaining release contracts
source .venv/bin/activate            # required for direct tool commands below
pytest -k installer                 # focused installer cases within quick
pytest --collect-only               # list all cases without deployment preparation
ansible-lint --strict
yamllint .
pre-commit run gitleaks --all-files
```

`check.sh` finds `.venv/bin` automatically and stops at the first failed gate. It includes syntax, lint, secret scanning, and SSOT checks; use it for canonical shell-file selection and validation wiring.

For actual deployment, follow [Getting started](docs/getting-started.md#remote-ansible-deployment): prepare inventory and encrypted vaults before `ansible-playbook --ask-vault-pass site.yml`. Use `--tags hardening` or `--tags orchestration` only for an intentional phase boundary. Check mode cannot prove bootstrap, reloads, or SSH/firewall transactions. Run installers only on disposable development VPSs; `bash install.sh --help` is non-provisioning.

## Code Conventions & Common Patterns

- YAML starts with `---`; `.yamllint` sets a 140-character warning limit and forbids octal literals. Quote permissions, e.g. `mode: '0600'`.
- Name tasks `Area | Phase | Action`, use fully qualified Ansible modules, and prefer role-prefixed facts/registers (`vps_hardening_*`, `vps_orchestration_*`). Preserve tags across dynamic includes.
- Prefer declarative, idempotent modules. Probes need accurate `changed_when`/`failed_when` and explicit outcome assertions. Optional probes must feed an explicit policy decision, not silently weaken prerequisites.
- Variables, registered facts, and handlers are the dependency-injection/state-management pattern. Reuse existing transactions and `block`/`rescue` error handling rather than adding parallel activation paths.
- Bash uses strict mode, quoted expansions, command arrays, private temporary files, and trap-based cleanup/rollback. Preserve failure propagation; never trace credentials.
- Credentials belong in whole-file encrypted vaults; the services vault must be a regular non-symlink file with mode `0600`. Ordinary variables reference `vault_*` values. Plaintext `admin_password` and `wg_easy_admin_password` are rejected; never log secrets, hashes, or generated extra-vars.
- Public input changes require matching defaults, argument specs, examples, role references, and contracts. Keep image digests, upstream checksums, Python/collection pins, and GitHub Action SHA pins consistent.

## Important Files

- `site.yml`, `ansible.cfg` — entrypoint and controller defaults: remote inventory, strict host-key checking, YAML output, SSH pipelining.
- `roles/vps_hardening/meta/main.yml`, `roles/vps_orchestration/meta/argument_specs.yml` — public input contracts; role preflight assertions add invariants.
- `roles/vps_hardening/tasks/ssh.yml` — SSH cutover/rescue. Under `roles/vps_orchestration/tasks/`, `caddy_transaction.yml`, `compose_prepare.yml`, `compose_lifecycle.yml`, `traffic_mode.yml`, and `ufw_docker.yml` own stateful safety boundaries.
- `install.sh` — pinned signer, annotated-tag verification, exact-SHA `ansible-pull`, authoritative encrypted rerun state, secret cleanup. `UPGRADE.md` rejects v1 in-place upgrade/restore and legacy `ZERO_TRUST_*` inputs/paths.
- `requirements-dev.txt`, `requirements.yml`, `.ansible-lint`, `.yamllint`, `.pre-commit-config.yaml` — dependency and QA policy. `scripts/verify-ssot.sh` checks documentation/configuration consistency.
- `scripts/backup.sh`, `scripts/restore.sh`, `scripts/synthetic-check.sh` — live operations; see [Operations](docs/operations.md). Backup quiesces Compose and defaults to age encryption (`AGE_KEY`); restore validates extraction and readiness with rollback.
- `docs/extensions.md` — supported `docker-compose.override.yml` and `Caddyfile.d/` extension points; keep services private and digest-pinned.
- `docs/releasing.md`, `scripts/build-release-artifacts.sh`, `scripts/publish-release.sh` — signed release/attestation flow. The release workflow builds a verified draft, not a test gate; complete acceptance checks before tagging and use the publisher script.

## Runtime/Tooling Preferences

- Use Python 3, Bash, Ansible, pip/venv, and Ansible Galaxy—not Node/Bun. Bootstrap installs exact pins, including pytest 9.1.1; collection dependencies are `community.docker`, `community.general`, and `ansible.posix`.
- Supported target: fresh Debian 12 or Ubuntu 24.04, amd64/x86_64, at least 900 MiB OS-visible RAM, `/dev/net/tun`, and WireGuard support. Swap/zram are not managed; broad package upgrades are opt-in.
- Installer execution requires root and apt; interactive mode needs `/dev/tty`. Automation uses `NOOK_NONINTERACTIVE=1`; `NOOK_DEV_MODE=1` source overrides are only for disposable tests. Never weaken signature or host-key checks.
- Keep real inventory, vaults, `.vault_password`, logs, volumes, fetched certificates, and `.venv` untracked per `.gitignore`. Provider firewall/routing and rescue access remain operator responsibilities.

## Testing & QA

Pytest is the sequential runner; do not use xdist. `tests/registry.py` registers Bash contracts and VM scenarios and guards historical/native scenario boundaries. `tests/conftest.py` owns selection and fixtures; `tests/support.py` owns snapshots, subprocess execution, cleanup, and private diagnostics. Register new Bash contracts in the registry rather than adding another dispatcher.

Plain `pytest` defaults to `quick`; explicit `-m qemu`, `-m lifecycle`, `-m remote`, or `-m release` replaces that selection. Collection runs no subprocesses or deployment preparation. Execution fixtures preserve Git history/tags and dirty source in private snapshots, excluding ignored operator files; create deployment examples there, never in the working checkout.

No percentage-coverage gate: prove affected behavior, idempotency, failure propagation, and rollback. Native PTY/mocked-systemd tests do not replace real provisioning or SSH coverage. Some quick contracts invoke Docker Compose; missing prerequisites fail rather than silently skip. Quick checks never invoke host sudo, including in CI; real installer sudo/PTY coverage runs only inside the disposable QEMU guest.

CI runs quick checks and services-mode QEMU on Debian 12/Ubuntu 24.04; weekly adds lifecycle/restore. QEMU requires KVM, `qemu-system-x86_64`, `qemu-img`, `genisoimage`, and SSH/network tools. Real remote/public and full/IPv6 scenarios have additional prerequisites; use disposable hosts and pinned host keys. See [E2E](tests/e2e/README.md) for scope and commands: VM success does not prove provider networking, and `tests/ansible-pull-smoke.yml` proves only localhost inventory resolution.

[Contributing](CONTRIBUTING.md) owns timeouts and diagnostics. Use `NOOK_JUNIT_DIR=reports scripts/check.sh` or pytest's `--junitxml`; raw logs remain in private `nook-pytest-logs.*` directories. Inspect for secrets before sharing and remove them after diagnosis. Keep registry, `check.sh`, pre-commit, and workflow gates aligned.
