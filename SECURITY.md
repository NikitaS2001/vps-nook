# Security policy

Please do not report suspected vulnerabilities in a public issue or pull
request.

Use [GitHub Private Vulnerability Reporting](https://github.com/NikitaS2001/vps-nook/security/advisories/new)
to send a private report. Include the affected release or commit, deployment
context, reproduction steps, and any logs or proof of concept needed to
validate the issue. Remove credentials, private keys, hostnames, and other
sensitive data before submitting a report.

If Private Vulnerability Reporting is unavailable, contact the maintainer
through the private contact mechanism provided by the repository owner rather
than disclosing the issue publicly.

## Supported versions

Only the current stable release listed on the
[Releases page](https://github.com/NikitaS2001/vps-nook/releases)
is supported for security fixes. Older releases and unreleased development
branches are not covered by a backport commitment.

Reports are reviewed on a best-effort basis. There is no guaranteed response
or remediation SLA. After validation, the maintainer will determine the
appropriate fix, disclosure timing, and release notes.

## Operational safety

This project changes host firewall, SSH, Docker, and VPN configuration. Keep
an existing recovery path available while applying changes, use Ansible Vault
for secrets, and do not post inventories, vault contents, private keys, or
production logs in an issue or pull request.
