# VPS Nook v2 validation

Local validation on 2026-09-11. Release publication is still pending.
The GitHub repository is now `NikitaS2001/vps-nook`; the local origin uses that URL.

| Check | Result |
| --- | --- |
| `scripts/check.sh` | PASS; all quick validation contracts |
| Installer and release source/asset contracts | PASS |
| PTY wizard: pipe, defaults, edits, retry, cancellation, EOF, colors | PASS |
| PTY wizard through sudo on Ubuntu 24.04 | PASS |
| UTF-8 bcrypt byte limit, interactive and automated | PASS |
| Local SSH recovery fixtures without `ansible_port` | PASS |
| Ubuntu remote SSH rollback, authenticated cutover, stack and reboot | PASS |
| Lifecycle: same-version reinstall, state identity, encrypted restore | PASS |
| Debian 12 installer, client, reboot and retry scenarios | PASS |
| Ubuntu 24.04 installer, client, reboot and retry scenarios | PASS |

The lifecycle baseline is an explicitly labelled snapshot of the current v2 tree:
there is no published compatible v2 baseline yet. This proves reinstall and restore,
not a released-version upgrade. Automatic v1 migration is deliberately unsupported.

Long QEMU tests run from isolated source copies. The installer harness also freezes
the source used for later guest copies and client checks. A previous development
run mixed revisions while files were being edited; it is not counted as passing.

The remote negative test exposed a socket/service ordering failure. The final
successful run stops the socket-owned SSH service before disabling the socket,
restores socket/service state on failure, and authenticates through the original
connection (including a proxy) before reporting the failed cutover.

During the Ubuntu rerun, the official archive's HTTP endpoint timed out from both
the VM and controller while HTTPS responded. Only that disposable VM's APT archive
URI was switched to HTTPS; package signature validation remained enabled.

QEMU covers guest behavior, not a hosting provider's firewall or external routing.
The local recovery fixture renders real recovery tasks but mocks systemd operations;
the remote rollback test exercises real Ubuntu systemd and authenticated SSH.

Before publication: run two successful Weekly matrices, validate a signed v2 draft
and its downloaded installer, then follow [the release process](releasing.md).
The README command remains a preview until the actual release asset exists.
