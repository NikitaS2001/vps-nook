# Repository Guidelines

## Scope and sources of truth

VPS Nook provisions one hardened VPS with key-only SSH, UFW, fail2ban, and private WireGuard (`wg-easy`), AdGuard Home, and Caddy internal TLS; only SSH and WireGuard UDP are public, and administration UIs stay localhost/private-network only.
Both controller-managed Ansible and the signed-release installer use `site.yml`; keep controller configuration separate from installer state.

- Executable code/configuration describes current behavior; mandatory security rules here still apply. A disagreement is a defect: inspect the owner and reconcile stale prose or implementation in the same change without silently weakening the stricter safety rule.
- Sources of truth: `site.yml` and role `tasks/main.yml` for phase order; role defaults, argument specifications and preflight assertions for public inputs; `tests/registry.py`, `pytest.ini`, `tests/conftest.py` and `scripts/check.sh` for test selection.
- Owning scripts and `docs/operations.md` or `docs/releasing.md` define operational/release procedures. Future nested instructions must be non-conflicting and limited to their subtree.

## Core working rules

- Inspect the existing owner and its callers/contracts before editing; reuse or modify that owner instead of adding a parallel path.
- Make the smallest complete change, preserve failure propagation and rollback, update every touched public contract surface, and prove changed behavior with the narrowest adequate executable check.

## Architecture and transaction boundaries

`site.yml` runs two privileged, fact-gathering plays on `vps`; verify ordering against the playbook and role task entrypoints when changing the flow:

1. `vps_hardening` (`hardening`): platform preflight → packages → administrator → sysctls → UFW → SSH cutover → fail2ban.
2. `vps_orchestration` (`orchestration`): vault/network preflight → netfilter → Docker → volumes → AdGuard → Compose/Caddy/bootstrap → traffic policy → Docker/UFW integration → runtime verification.

Services share dual-stack `vpn_net`; AdGuard resolves internal names to Caddy, which terminates TLS and proxies UIs. Verification fetches the public CA to `fetched_certs/<inventory-host>/root.crt`.
Service state defaults to `/opt/vps-nook`; encrypted installer inputs live in `/etc/vps-nook`, separate from its checkout/virtualenv in `/opt/vps-nook-installer`.
`wg_traffic_mode: services` restricts destinations on the server, not just client AllowedIPs; `full` requires IPv4 egress and IPv6 default routing requires a successful probe. Changes reconcile persisted markers, wg-easy SQLite policy and live firewall rules; clients need refreshed profiles.

- **SSH/UFW:** allow current/new SSH and WireGuard before default-deny. Validate the SSH candidate, preserve service/socket rollback, flush handlers and authenticate the new connection before removing old-port access.
- **Caddy:** validate the whole candidate with operator extensions before activation. Preserve the bind-mounted inode, reload and restore prior bytes on failure; do not substitute atomic rename or generic template restart.
- **Bootstrap/policy:** wg-easy SQLite determines initialization. Scrub Compose `INIT_*` credentials after bootstrap and on failure. Preserve policy snapshots, schema checks, rollback and fail-closed interrupted transactions. Docker bypasses ordinary UFW: retain subsequent `ufw-docker` reconciliation.
- **Secrets/state:** retain `no_log: true`, restrictive permissions and path/symlink guards. Never recreate volumes or discard malformed vault/policy state to make a rerun succeed.

## Change ownership

| Change | Owner and companion surfaces |
| --- | --- |
| Hardening | `roles/vps_hardening/tasks/main.yml` and owning include; SSH cutover/rescue: `roles/vps_hardening/tasks/ssh.yml` |
| Orchestration | `roles/vps_orchestration/tasks/main.yml` and owning include; transactions in that directory: `caddy_transaction.yml`, `compose_prepare.yml`, `compose_lifecycle.yml`, `traffic_mode.yml`, `ufw_docker.yml` |
| Public inputs | Role defaults, argument specs/preflight, `group_vars/all`, role READMEs and contracts; hardening metadata: `roles/vps_hardening/meta/main.yml`; orchestration specs: `roles/vps_orchestration/meta/argument_specs.yml` |
| Installer | `install.sh`, `tests/installer/`, relevant validation contracts, `docs/getting-started.md`, `docs/configuration.md` |
| Live operations | Matching `scripts/backup.sh`, `scripts/restore.sh` or `scripts/synthetic-check.sh` and `docs/operations.md` |
| Releases | Release scripts, `.github/workflows/release.yml`, `docs/releasing.md`; complete acceptance before tagging, then use the publisher script for the verified draft |
| Private extensions | `docs/extensions.md`, `examples/`; keep Compose/Caddy extensions private and digest-pinned |

## Required constraints

- Use Python 3, Bash, Ansible, pip/venv and Ansible Galaxy. Supported targets: fresh Debian 12 or Ubuntu 24.04, amd64/x86_64, at least 900 MiB OS-visible RAM, `/dev/net/tun` and WireGuard support. Do not manage swap/zram; broad package upgrades are opt-in.
- YAML starts with `---`; follow `.yamllint` (140-character warning limit, no octal literals), and quote modes such as `'0600'`. Name tasks `Area | Phase | Action`, use fully qualified modules and role-prefixed facts/registers, and preserve tags through dynamic includes.
- Prefer declarative, idempotent modules. Probes need accurate `changed_when`/`failed_when` and outcome assertions; optional probes must feed explicit policy decisions. Reuse facts, registered variables, handlers and `block`/`rescue` transactions.
- Bash uses strict mode, quoted expansions, command arrays, private temporary files and trap cleanup/rollback. Never trace credentials or suppress failures.
- Credentials belong in whole-file encrypted vaults; the services vault must be a regular non-symlink file with mode `0600`. Ordinary variables reference `vault_*`; plaintext `admin_password` and `wg_easy_admin_password` are rejected. Never log secrets, hashes or generated extra-vars.
- Keep image digests, upstream checksums, Python/collection pins and GitHub Action SHA pins consistent. Public input changes require defaults, argument specs/preflight, examples, role references and contracts together.
- Installer: root and apt required; interactive execution needs `/dev/tty`; automation uses `NOOK_NONINTERACTIVE=1`. `NOOK_DEV_MODE=1` source overrides are only for disposable tests. Preserve pinned signer, annotated-tag verification, exact-SHA `ansible-pull`, authoritative encrypted rerun state and secret cleanup; never weaken signature or host-key checks.
- Follow `UPGRADE.md`: no v1 in-place upgrade/restore or legacy `ZERO_TRUST_*` inputs/paths. Backup quiesces Compose and defaults to age encryption (`AGE_KEY`); restore validates extraction/readiness with rollback.
- Keep real inventory, vaults, `.vault_password`, logs, volumes, fetched certificates and `.venv` untracked. Provider firewall/routing and rescue access remain operator responsibilities.

## Validation

Set up pinned tooling with `scripts/bootstrap.sh`; direct tool commands require `source .venv/bin/activate`. `scripts/check.sh` finds `.venv/bin` and selects sequential pytest stages, stopping at the first failed gate.
The default `quick` stage includes `tests/contracts/test_tools.py`: Bash syntax, ShellCheck, Ansible syntax, `ansible-lint --strict`, `yamllint .`, gitleaks and `scripts/verify-ssot.sh`.

| Changed behavior | Required proof |
| --- | --- |
| Documentation/instructions only | Targeted structural checks, then `scripts/check.sh` |
| Roles, scripts or contracts | Focused affected pytest cases, then `scripts/check.sh` |
| Compose/service mode | `scripts/check.sh --e2e` (quick, then services-mode QEMU) |
| SSH/UFW recovery or cutover | Focused checks and quick, then `pytest -m remote` |
| Lifecycle/restore or release | Focused checks and quick, corresponding `-m lifecycle`/`-m release`, or `scripts/check.sh --release` (quick, QEMU, lifecycle, remaining release contracts) |

- Pytest is sequential; never use xdist. Explicit `-m` replaces default `quick`; `pytest --collect-only` runs no subprocesses or deployment preparation. Register new Bash contracts in `tests/registry.py`, not another dispatcher; keep registry, wrapper, pre-commit and workflow gates aligned.
- Fixtures preserve history/tags and dirty source in private snapshots, excluding ignored operator files. Create deployment examples there, never in the checkout. Quick checks never invoke host sudo; missing prerequisites, including Docker Compose where required, fail rather than skip.
- Prove affected behavior, idempotency, failure propagation and rollback; no percentage-coverage gate. Native PTY/mocked-systemd tests do not replace real provisioning/SSH checks. VM success does not prove provider networking; `tests/ansible-pull-smoke.yml` proves only localhost inventory resolution.
- Never provision without confirming the target is a disposable development VPS. Follow `docs/getting-started.md` for inventory/encrypted vault preparation and use phase tags only intentionally. Check mode cannot prove bootstrap, reloads, SSH or firewall transactions; `bash install.sh --help` is non-provisioning.
- `CONTRIBUTING.md` and `tests/e2e/README.md` own prerequisites, timeouts and diagnostics. Use `NOOK_JUNIT_DIR=reports scripts/check.sh` or `--junitxml`; raw logs stay in private `nook-pytest-logs.*` directories. Never publish raw private logs or operator inventory/vault material; inspect diagnostics for secrets before sharing and remove private logs after diagnosis.
