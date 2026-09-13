# VPS Nook v2 compatibility

v2.0.0 is a breaking rename, not an in-place upgrade from v1.

## Existing v1 installations

The new installer rejects `ZERO_TRUST_*` and the old standard deployment paths
before installing packages or changing the host. It does not delete, move or
convert old vaults, containers or backups. Do not remove old state merely to
bypass this check: the old containers and firewall configuration may still exist.

Keep the old release checkout for operating your existing server. Export and verify
an encrypted off-host backup before any migration. Use a fresh VPS for VPS Nook;
manual migration of service data is outside the supported installation path.
Do not restore a v1 project archive over v2: it contains old paths and configuration.

Historical releases and attestations retain their original repository identity,
`NikitaS2001/ansible-zero-trust-vps`. Do not rewrite their tags or treat new-repository
attestations as evidence for historical assets.

## Compatible Nook updates

Once a compatible Nook release is published, back up the project, verify the new
installer as described in [Getting started](docs/getting-started.md#verified-installation),
and run its local bytes. Keep the original SSH session open and confirm a new login.
The installer reuses `/etc/vps-nook` inputs and rejects implicit credential changes.
Check WireGuard, DNS and HTTPS, then test backup and restore. Configuration or secret
rotation should be a separate operation.
