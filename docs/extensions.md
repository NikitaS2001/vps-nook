# Adding an internal service

Extensions use two existing primitives: a Compose override on the shared
private network and a Caddy site fragment. The role owns the base stack and
does not overwrite these two extension points.

Create `/opt/vps-nook/docker-compose.override.yml`:

```yaml
services:
  myservice:
    image: example/myservice:1.0.0@sha256:<reviewed-digest>
    restart: unless-stopped
    networks:
      vpn_net: {}
    volumes:
      - ./volumes/myservice:/data
```

Create `/opt/vps-nook/Caddyfile.d/myservice.conf`:

```caddyfile
myservice.internal {
    tls internal
    reverse_proxy myservice:8080
}
```

Keep service data below `/opt/vps-nook/volumes` so the project backup
captures it. Data outside the project root is outside the backup contract.

Start the new service, then rerun the verified installer or remote playbook.
Ansible validates the complete Caddy candidate before reloading it; do not
restart Caddy directly.

```bash
cd /opt/vps-nook
sudo docker compose up -d myservice
```

Connect a VPN client and open `https://myservice.internal`. If a different
`internal_domain_suffix` is configured, use that suffix in the Caddy site.
AdGuard already rewrites names under the suffix to Caddy.

## Extension boundary

- Pin the image tag and digest.
- Do not publish a host port unless public exposure is an explicit, reviewed
  requirement; prefer the private `vpn_net` network and Caddy.
- Do not place plaintext credentials in the Compose override. Use a
  service-specific secret mechanism and ensure backups protect it.
- Add a service health check and include it in operator monitoring when the
  service matters.
- Review the container's capabilities, volumes, user, and update policy.

The `examples/` directory contains a larger Vaultwarden example. It is an
operator-owned extension, not part of the supported core service set.
