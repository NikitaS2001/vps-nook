# Changelog

Notable changes are recorded here. The project follows Semantic Versioning.

## [v2.0.0] - 2026-09-13

- Rename the project to VPS Nook, with NOOK_* inputs and new server paths.
- Reject legacy installations before deployment; automatic v1 migration is not supported.
- Add a terminal setup wizard, inline input validation, and first-client guidance.
- Repair SSH validation, socket activation ordering, and local/remote cutover recovery.
- Enforce the AdGuard bcrypt limit in UTF-8 bytes before accepting a password.
- Separate quick installation from optional pre-execution release verification.
- Unify native fixtures, Bash contracts and QEMU scenarios under pytest with private diagnostics and bounded cleanup.
- Keep quick checks unprivileged; run real installer sudo/PTY coverage only inside the disposable QEMU guest.
- Run QEMU and lifecycle/restore weekly on Mondays at 02:17 UTC, with manual dispatch for pre-release checks.

## [v1.3.2] - 2026-08-31

- Derive the SPDX source checksum from deterministic Git tree data so independently built release assets match byte-for-byte.

## [v1.3.1] - 2026-08-31

- Permit `full` routing with IPv4 egress; add IPv6 routes only when the host has IPv6 egress.
- Rename traffic modes from `services_only`/`full_tunnel` to `services`/`full`.

## [v1.3.0] - 2026-08-30

- Verify the official installer through an SSH-signed release tag and exact commit.
- Pin automation, Ansible, collection, and OCI dependencies.
- Add deterministic checksums, an SPDX SBOM, GitHub attestations, and immutable releases.
- Harden secret persistence, firewall validation, recovery, and supported traffic modes.

## [v1.2.1] - 2026-08-20

- Preserve the Caddy bind-mount inode during configuration updates.
- Upgrade wg-easy to 15.4.0 and update its authentication check.

## [v1.2.0] - 2026-08-19

- Add production hardening, backup and restore, release contracts, and QEMU validation.
- Add configurable internal domains and a documented service extension path.

## [v1.1.0] - 2026-08-08

- Fix the installer release reference, required collection, and wg-easy password policy.

## [v1.0.0] - 2026-08-06

- Publish the first tagged release with the public installer.

[v2.0.0]: https://github.com/NikitaS2001/vps-nook/compare/v1.3.2...v2.0.0
[v1.3.2]: https://github.com/NikitaS2001/ansible-zero-trust-vps/compare/v1.3.1...v1.3.2

[v1.3.1]: https://github.com/NikitaS2001/ansible-zero-trust-vps/compare/v1.3.0...v1.3.1

[v1.3.0]: https://github.com/NikitaS2001/ansible-zero-trust-vps/compare/v1.2.1...v1.3.0
[v1.2.1]: https://github.com/NikitaS2001/ansible-zero-trust-vps/compare/v1.2.0...v1.2.1
[v1.2.0]: https://github.com/NikitaS2001/ansible-zero-trust-vps/compare/v1.1.0...v1.2.0
[v1.1.0]: https://github.com/NikitaS2001/ansible-zero-trust-vps/compare/v1.0.0...v1.1.0
[v1.0.0]: https://github.com/NikitaS2001/ansible-zero-trust-vps/releases/tag/v1.0.0
