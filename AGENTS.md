# Repository Guidelines

## Project Overview

VPS Nook provisions a single hardened VPS with Ansible: key-only SSH, UFW, fail2ban, and a private Docker stack of WireGuard (`wg-easy`), AdGuard Home, and Caddy internal TLS. Public exposure is SSH and WireGuard UDP; administration UIs stay localhost/private-network only.

Two deployment paths share `site.yml`: remote controller-managed Ansible, or `install.sh` using a verified signed release and exact-commit `ansible-pull`. Treat changes as security-sensitive infrastructure work, not ordinary application deployment.

## Architecture & Data Flow

`site.yml` runs two privileged, fact-gathering plays on inventory group `vps`, in order:

1. `roles/vps_hardening` (`hardening` tag): platform preflight → packages → administrator → sysctls → UFW → SSH cutover → fail2ban.
2. `roles/vps_orchestration` (`orchestration` tag): vault/network preflight → netfilter modules → Docker → volumes → AdGuard → Compose/Caddy → traffic-policy reconciliation → Docker/UFW integration → runtime verification.

Role defaults and `group_vars/all` supply variables; `meta/argument_specs.yml` declares public inputs; task assertions enforce additional invariants. Jinja templates render service configuration, registered facts carry observed state, and handlers apply deferred changes. Keep work in its owning phase file; `tasks/main.yml` owns preflight and include/tag boundaries.

The three containers share dual-stack `vpn_net`. AdGuard rewrites the internal domain suffix to Caddy, which terminates internal TLS and proxies the UIs. Verification fetches the public Caddy CA to `fetched_certs/<inventory-host>/root.crt`. Persistent service state defaults to `/opt/vps-nook`; installer configuration lives separately in encrypted state under `/etc/vps-nook`, with its checkout at `/opt/vps-nook-installer/repo`.

`wg_traffic_mode: services` is server-enforced access to managed VPN/service destinations, not merely client AllowedIPs. `full` requires IPv4 egress; IPv6 default routing is enabled only after a successful egress probe. Mode changes reconcile persisted state, wg-easy SQLite policy, and live firewall rules transactionally; clients need updated profiles. Do not mix public-installer state with controller-managed deployments.

Preserve these safety boundaries:

- **SSH/UFW:** allow current/new SSH and WireGuard before default-deny; validate the SSH candidate, preserve service/socket rollback, flush handlers, and prove the new connection before removing old-port access.
- **Caddy:** validate the candidate and extension tree before activation; preserve the bind-mounted file inode, reload, and restore on failure. Do not replace this with a generic template restart.
- **Bootstrap/policy:** wg-easy SQLite determines first-run state. Scrub Compose `INIT_*` credentials after initialization and on failure; preserve traffic-policy backup/reconciliation/rollback and UFW-Docker ordering.
- **Secrets/state:** use `no_log: true`, restrictive permissions, and existing path/symlink guards. Never recreate volumes or discard malformed vault state to make a rerun succeed.

## Key Directories

- `roles/vps_hardening/`, `roles/vps_orchestration/` — implementation; `tasks/`, `templates/`, `handlers/`, `defaults/`, and `meta/argument_specs.yml` must evolve together.
- `group_vars/all/`, `inventory/` — deployment examples. Real variables, vaults, and host inventory are private; `inventory/localhost.yml` supports controlled local runs.
- `scripts/` — contributor checks, backup/restore, health checks, and release tooling.
- `tests/validation/` — Bash fixture contracts registered in `tests/registry.py`; `tests/e2e/` — disposable QEMU and remote scenarios.
- `docs/` — installation, configuration, operations, security, extensions, and release procedures; role READMEs document supported inputs.
- `examples/` — optional Compose/Caddy extensions, not additional core services.
- `.github/workflows/` — static/QEMU CI, weekly lifecycle checks, and release artifact workflows.

## Development Commands

No compilation step or application package manager. Canonical setup and checks:

```bash
scripts/bootstrap.sh                 # creates .venv; installs pinned tools/collections
scripts/check.sh                     # syntax, lint, secret scan, SSOT, local contracts
scripts/check.sh --e2e               # adds services-mode QEMU client/rerun/reboot checks
scripts/check.sh --release           # adds QEMU lifecycle and release contracts
```

`check.sh` automatically uses `.venv/bin`. For direct Ansible/lint commands, first run `source .venv/bin/activate`. Individual lint commands are `ansible-lint --strict`, `yamllint .`, and `pre-commit run gitleaks --all-files`; use `check.sh` for the complete shell-file selection and contract suite.

For remote deployment, copy and edit `inventory/hosts.yml.example` and the three `group_vars/all/*.example` files as described in `docs/getting-started.md`; replace every placeholder before encrypting:

```bash
chmod 0600 group_vars/all/vault_services.yml group_vars/all/vault_ssh.yml
ansible-vault encrypt group_vars/all/vault_services.yml group_vars/all/vault_ssh.yml
ansible-playbook --ask-vault-pass --syntax-check site.yml
ansible-playbook --ask-vault-pass site.yml -u root
```

After cutover, update inventory to the managed account/port (defaults `sysadmin`, `2222`). Use `--tags hardening` or `--tags orchestration` only for an intentional phase boundary. Check mode cannot prove stateful bootstrap, service reloads, or SSH/firewall transactions. Run installers only on disposable VPSs during development; `bash install.sh --help` documents inputs without provisioning.

## Code Conventions & Common Patterns

- YAML starts with `---`; follow `.yamllint` (140-character warning limit; no implicit/explicit octal literals). Quote permission strings, e.g. `mode: '0600'`.
- Name tasks `Area | Phase | Action`, use fully qualified Ansible modules, and prefer descriptive role-prefixed registered facts (`vps_hardening_*`, `vps_orchestration_*`). Preserve tags on dynamic include boundaries and their tasks.
- Prefer idempotent modules with declarative `state`. For command probes, set accurate `changed_when`/`failed_when` and explicitly assert required outcomes. Optional capability probes must feed an explicit policy decision, not silently weaken a prerequisite.
- Variables, registered facts, and handlers are the dependency-injection/state-management model. Reuse existing defaults, templates, and transactions rather than adding a parallel configuration or restart path.
- Bash uses strict mode, quoted expansions, command arrays, and trap-based cleanup/rollback. Preserve failure propagation and private temporary-file handling; never enable tracing around credentials.
- Credentials belong in whole-file encrypted vaults. The services vault must be a regular non-symlink file with mode `0600`; ordinary variables reference `vault_*` values. Plaintext `admin_password` and `wg_easy_admin_password` are rejected. Do not log hashes, bootstrap secrets, generated extra-vars, or private keys.
- Keep image digests, upstream script checksums, Python/collection pins, and GitHub Action SHA pins reviewed and consistent. Input changes require corresponding argument specs, examples, role references, and relevant contracts.

## Important Files

- `site.yml`, `ansible.cfg` — role order and controller defaults: remote inventory, strict host-key checking, YAML output, SSH pipelining.
- `install.sh` — signed-tag verification, platform/input validation, authoritative encrypted rerun state, exact-SHA `ansible-pull`, and secret cleanup. `UPGRADE.md` defines the breaking v2 boundary: no v1 restore/migration; legacy `ZERO_TRUST_*` inputs/paths are rejected.
- `roles/vps_hardening/tasks/ssh.yml` — SSH cutover/rescue; `roles/vps_orchestration/tasks/caddy_transaction.yml`, `compose_lifecycle.yml`, `traffic_mode.yml`, and `ufw_docker.yml` — stateful safety mechanisms.
- `requirements-dev.txt`, `requirements.yml`, `.ansible-lint`, `.yamllint`, `.pre-commit-config.yaml` — toolchain and QA policy.
- `scripts/check.sh`, `scripts/verify-ssot.sh`, `tests/registry.py` — validation entrypoint, cross-file documentation/configuration contracts, and ordered test dispatch.
- `scripts/backup.sh`, `scripts/restore.sh`, `scripts/synthetic-check.sh` — live operations; see `docs/operations.md`. Backup quiesces Compose and encrypts with age by default (`AGE_KEY`); restore validates/stages before activation and rolls back failures.
- `docs/releasing.md`, `scripts/build-release-artifacts.sh`, `scripts/publish-release.sh` — signed release/attestation flow. The release workflow leaves a verified draft; publication uses the script, not ad hoc UI edits.

## Runtime/Tooling Preferences

- Use Python 3, Bash, Ansible, pip/venv, and Ansible Galaxy—not Node/Bun. `scripts/bootstrap.sh` installs exact pins from `requirements-dev.txt` and `requirements.yml` (`community.docker`, `community.general`, `ansible.posix`).
- Supported VPS baseline: fresh Debian 12 or Ubuntu 24.04, amd64/x86_64, at least 900 MiB OS-visible RAM, `/dev/net/tun`, and WireGuard support. Neither role manages swap/zram; broad package upgrades are opt-in.
- The installer requires root and apt; interactive mode needs `/dev/tty`. Automation uses `NOOK_NONINTERACTIVE=1`; `NOOK_DEV_MODE=1` release-source overrides are only for disposable tests. Do not weaken production signature or host-key checks.
- Keep real inventory, vaults, `.vault_password`, logs, volumes, fetched certificates, and `.venv` untracked per `.gitignore`. Provider firewall/routing and rescue access remain operator responsibilities.

## Testing & QA

Pytest is the sequential runner for native Python fixtures, Bash contracts and disposable QEMU scenarios; Molecule and tox are not used. There is no percentage-coverage gate; prove affected behavior, idempotency, failure propagation, and rollback. Some contracts render or execute Docker Compose; inspect prerequisites before treating every local test as static.

Choose focused contracts for the changed boundary, for example:

```bash
bash tests/validation/ansible-runtime.sh
bash tests/validation/compose-render.sh
bash tests/validation/traffic-mode-contract.sh
bash tests/validation/hardening-contract.sh
bash tests/validation/secret-installer-contract.sh
bash tests/validation/restore-sandbox.sh
bash tests/validation/workflow-contract.sh
bash scripts/verify-ssot.sh
```

Register new quick contracts in `tests/registry.py`. Keep validation wiring aligned with `scripts/check.sh`, pre-commit, and workflows; `workflow-contract.sh` checks that structure. Deployment fixtures create examples only in private source snapshots; ignored operator files are never copied. Collection performs no subprocess execution or deployment preparation.

CI runs bootstrap/quick checks, then services-mode QEMU on Debian 12 and Ubuntu 24.04; weekly adds lifecycle/restore coverage. QEMU needs `qemu-system-x86_64`, `qemu-img`, `genisoimage`, KVM, and SSH/network tooling. See `tests/e2e/README.md` for targeted SSH rollback, Caddy failure, and manual full/IPv6 scenarios; these are not all routine CI gates. QEMU proves repository-controlled host behavior, not provider networking. Public/remote tests require disposable hosts and pinned host keys. `tests/ansible-pull-smoke.yml` proves only localhost inventory resolution, not deployment.
