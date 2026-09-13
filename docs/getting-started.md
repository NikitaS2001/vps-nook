# Getting started

Choose one installation path. The public installer is the recommended path for
one fresh VPS. Remote Ansible is intended for an existing controller workflow.

## Before installation

Check the [VPS requirements](../README.md#before-you-start) before choosing a path.
Neither role modifies swap or zram.

> [!WARNING]
> Open the planned SSH and WireGuard ports in the provider firewall before
> deployment. Keep the original SSH session open and provider console access
> available until login on the hardened port succeeds.

## Quick installation

The root README contains the canonical version-pinned command. v2.0.0 is still
in preparation; wait for its publication before using the preview URLs.
If curl is missing, install it first:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
```

After publication, a sudo-capable user can use this variant:

```text
curl -fsSL https://github.com/NikitaS2001/vps-nook/releases/download/v2.0.0/install.sh | sudo bash
```

Both commands require an SSH terminal for prompts, even though the script arrives
through a pipe. For automation use `NOOK_NONINTERACTIVE=1` and the documented
[configuration inputs](configuration.md). Never paste real passwords into shell
history. The wizard uses hidden input and confirms each password.

Piping a script to Bash executes bytes trusted through HTTPS. The installer's
signed-tag verification protects the subsequent checkout, not the script
already executing. Use the following path for verification before execution.

## Verified installation

The v2.0.0 release must be published first. Install [GitHub CLI](https://cli.github.com/)
and authenticate with `gh auth login`. Use a new download directory.

<!-- ssot:verified-quickstart:start -->
```bash
mkdir vps-nook-install
cd vps-nook-install
gh auth login
gh release download v2.0.0 \
  --repo NikitaS2001/vps-nook \
  --pattern install.sh \
  --pattern install.sh.sha256
gh attestation verify install.sh \
  --repo NikitaS2001/vps-nook \
  --signer-workflow \
    NikitaS2001/vps-nook/.github/workflows/release.yml \
  --source-ref refs/tags/v2.0.0
sha256sum --check install.sh.sha256
sudo bash ./install.sh
```
<!-- ssot:verified-quickstart:end -->

The installer verifies the SSH-signed tag, checks out its exact commit and shows
the effective settings before applying server roles. Source-verification packages
may already be installed when you cancel; secrets are removed from temporary files.

Reruns reuse the authoritative encrypted inputs under `/etc/vps-nook`; see
[automated inputs](configuration.md#automated-installer-inputs) and
[upgrade compatibility](../UPGRADE.md). Do not mix controller deployments with
installer state. Malformed vaults are preserved for recovery, never replaced.

## Remote Ansible deployment

On the controller, clone a tagged release and create local files from the
examples:

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
cp group_vars/all/vars.yml.example group_vars/all/vars.yml
cp group_vars/all/vault_services.yml.example \
  group_vars/all/vault_services.yml
cp group_vars/all/vault_ssh.yml.example group_vars/all/vault_ssh.yml
chmod 0600 group_vars/all/vault_services.yml \
  group_vars/all/vault_ssh.yml
```

Edit the inventory and variables. Replace every vault placeholder, including
`vault_admin_password_hash`, `vault_adguard_password_hash`,
`vault_wg_easy_bootstrap_secret`, and `vault_admin_ssh_pubkey`. The wg-easy
secret must be at least 12 characters. Set `wg_public_host` and review
`wg_traffic_mode`.

Bootstrap the pinned controller toolchain, then encrypt both vault files before
running the playbook:

```bash
./scripts/bootstrap.sh
source .venv/bin/activate
ansible-vault encrypt \
  group_vars/all/vault_services.yml \
  group_vars/all/vault_ssh.yml
ansible-playbook --ask-vault-pass --syntax-check site.yml
ansible-playbook --ask-vault-pass site.yml -u root
```

After the first run, change the inventory connection to the managed account and
hardened port before rerunning:

```yaml
ansible_user: sysadmin
ansible_port: 2222
```

The service vault must remain a regular, non-symlink, whole-file encrypted
Ansible Vault with mode `0600`. Plaintext `wg_easy_admin_password` and
`admin_password` variables are rejected.

## First WireGuard client

Forward the wg-easy UI through SSH:

```bash
ssh -p <ssh_port> -L 51821:127.0.0.1:51821 \
  <admin_user>@<vps-address>
```

Open `http://127.0.0.1:51821`, sign in, create a client, and import its profile.
Connect the client before opening the internal sites. The default
[traffic policy](configuration.md#traffic-policy) reaches managed services only.

The internal sites default to `https://wg.internal` and
`https://adguard.internal`. [Trust your Caddy CA](#trust-the-internal-ca) before
using them.

AdGuard's bootstrap UI is available through a separate tunnel when needed:

```bash
ssh -p <ssh_port> -L 3000:127.0.0.1:3000 \
  <admin_user>@<vps-address>
```

Continue with [Configuration](configuration.md) or
[Operations](operations.md).

## Trust the internal CA

Only install the CA from your own VPS. Its trust applies to certificates issued
by that CA; remove it when retiring the server. Do not copy the CA private key.

On your computer, copy the public certificate from the authenticated server
(replace the address, username and SSH port):

```bash
ssh -p 2222 sysadmin@<vps-address> \
  'sudo cat /opt/vps-nook-installer/repo/fetched_certs/localhost/root.crt' \
  > vps-nook-root.crt
openssl x509 -in vps-nook-root.crt -noout -subject -fingerprint -sha256
```

Compare the fingerprint with the same command on the server before trusting it.
For controller-managed installation, use `fetched_certs/<inventory-host>/root.crt`.

- **Windows:** open the certificate, choose Install Certificate, and select
  Trusted Root Certification Authorities for the intended user or computer.
- **macOS:** import it into Keychain Access, open the certificate's Trust settings,
  and enable trust for SSL. Authenticate when prompted.
- **Debian/Ubuntu desktop:** copy the `.crt` file to
  `/usr/local/share/ca-certificates/vps-nook.crt`, then run
  `sudo update-ca-certificates`. Other Linux distributions use different trust tools.
- **Android:** transfer the public certificate, then use Settings to install a
  CA certificate (usually under Security / Encryption & credentials). Settings
  names depend on the device; some apps do not trust user-installed CAs.
- **iOS/iPadOS:** transfer and open the certificate, install its downloaded profile
  in Settings, then enable full trust under General / About / Certificate Trust Settings.

Reconnect the VPN and visit both internal HTTPS sites. Some browsers use a separate
certificate store; if necessary, import the same CA into the browser's Authorities
store. Do not work around an unexpected certificate warning by disabling verification.

Platform references: [Apple certificate trust](https://support.apple.com/en-ie/102390),
[macOS Keychain trust](https://support.apple.com/en-gb/guide/keychain-access/kyca11871/mac),
[Android certificates](https://support.google.com/pixelphone/answer/2844832?hl=en), and
[Ubuntu trust store](https://ubuntu.com/server/docs/how-to/security/install-a-root-ca-certificate-in-the-trust-store/).

## If setup stops

The final message identifies the failed stage and whether encrypted inputs remain.
Fix the reported prerequisite and rerun the same tagged installer. Keep your original
SSH session open; a local listener check does not prove your provider firewall permits
new logins. Use [SSH recovery](operations.md#ssh-recovery) if needed.
