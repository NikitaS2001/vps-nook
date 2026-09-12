# Pytest migration map

The pre-migration working-tree dispatcher and CI are mapped below. Bash adapters retain their internal assertions.

| Previous entry | Pytest destination | Set |
| --- | --- | --- |
| `ansible-runtime.sh` | `test_bash[ansible-runtime]` | quick |
| `backup-sandbox.sh` | `test_bash[backup-sandbox]` | quick |
| `installer-contract.sh` | `test_bash[installer-contract]` | quick |
| `secret-installer-contract.sh` | `test_bash[secret-installer-contract]` | quick |
| `restore-sandbox.sh` | `test_bash[restore-sandbox]` | quick |
| `compose-render.sh` | `test_bash[compose-render]` | quick |
| `traffic-mode-contract.sh` | `test_bash[traffic-mode-contract]` | quick |
| `hardening-contract.sh` | `test_bash[hardening-contract]` | quick |
| `orchestration-core.sh` | `test_bash[orchestration-core]` | quick |
| `ufw-docker-idempotency.sh` | `test_bash[ufw-docker-idempotency]` | quick |
| `workflow-contract.sh --self-test` | `test_bash[workflow-contract]` | quick |
| `check-tooling.sh` | `tests/runner/test_runner.py` | quick |
| `qemu-source-contract.sh` | `test_bash[qemu-source-contract]` | quick |
| `qemu-packet-contract.sh` | `test_bash[qemu-packet-contract]` | quick |
| `sbom-contract.sh` | `test_bash[sbom-contract]` | quick |
| `fixture-git-signing-contract.sh` | `test_bash[fixture-git-signing-contract]` | quick |
| `installer-ux.sh` | `tests/installer/test_ux.py (independent PTY cases)` | quick |
| `ssh-recovery.sh` | `tests/contracts/test_ssh_recovery.py (four mocked-systemd cases)` | quick |
| check.sh: bash-syntax | `test_tool[bash-syntax]` | quick |
| check.sh: shellcheck | `test_tool[shellcheck]` | quick |
| check.sh: ansible-syntax | `test_tool[ansible-syntax]` | quick |
| check.sh: ansible-lint | `test_tool[ansible-lint]` | quick |
| check.sh: yamllint | `test_tool[yamllint]` | quick |
| check.sh: gitleaks | `test_tool[gitleaks]` | quick |
| check.sh: ssot | `test_tool[ssot]` | quick |
| `release-artifacts-contract.sh` | `test_bash[release-artifacts-contract]` | release |
| `release-workflow-contract.sh` | `test_bash[release-workflow-contract]` | release |
| `release-publish-contract.sh` | `test_bash[release-publish-contract]` | release |
| `release-contract.sh` | `test_bash[release-contract]` | release |
| scripts/release-contract.sh --pr | `test_bash[release-pr]` | release |
| qemu-install.sh --client-test --idempotency-test --reboot-test | `test_vm[qemu-services]` (also enables existing bootstrap, stopped-container and Caddy negatives) | qemu |
| lifecycle-qemu.sh | `test_vm[lifecycle-upgrade-restore]` | lifecycle |
| qemu-remote-install.sh SSH rollback/cutover/reboot/UFW failure | `test_vm[remote-ssh]` | remote |

Workflow --self-test and normal calls execute the same validation: one adapter remains. SBOM carries both quick and release markers; check.sh excludes quick tests from its final release stage so SBOM runs once. Release signing, draft creation, attestation and publication remain separate operations.

Acceptance evidence is recorded in `docs/pytest-validation.md`; runner migration alone does not satisfy release gates.

The signing-isolation fixture intentionally runs SBOM with hostile inherited Git settings; this is distinct from the normal SBOM case.
