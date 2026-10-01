# Adding an internal service

Extensions use two existing primitives: a Compose override on the shared
private network and a Caddy site fragment. The role owns the base stack and
does not overwrite these two extension points.

Use the [service recipe index](../examples/README.md) for complete, operator-owned
examples, including [Vaultwarden](../examples/vaultwarden/README.md). Each service
has its own `examples/<service>/` directory, not its own deployed Compose project.

There is only one `/opt/vps-nook/docker-compose.override.yml`. If it does not
exist, create it with the first recipe. Otherwise merge only the new service
mapping under the existing `services:` key, preserving other services and
top-level settings. Never copy a fragment over an existing override. If the
service key or target Caddy fragment already exists, stop and reconcile its
configuration and state before proceeding.

Published recipes provide the mandatory four-command
[`manage.sh` interface](../examples/README.md#executable-contract): `check`,
`install`, `bootstrap`, and `verify`, executed only in a VPS root shell.
They use the shipped Compose/Caddy fragments as configuration sources of truth,
never rewrite an existing shared override, and never reload Caddy themselves.
Exit 3 requests an operator merge followed by exact `install --resume` adoption.
Ansible retains transactional Caddy activation; Nook's existing scripts retain
backup/restore ownership. Update and removal remain reviewed service README
procedures, not manager commands.

Minimal Compose fragment:

```yaml
---
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

Keep all persistent service state under `/opt/vps-nook/volumes/<service>`.
The standard [backup](operations.md#backup) and [restore](operations.md#restore) procedure
stops the entire Compose project, including override services, and archives
`volumes/`, the managed `docker-compose.yml` and `Caddyfile`, and the optional
`docker-compose.override.yml` and `Caddyfile.d`.
An arbitrary file inside `/opt/vps-nook` is **not** backed up automatically.
Additional secrets or configuration outside these allowlisted paths need a
separate protected backup contract; the project root alone is not a boundary
that guarantees inclusion.

Start the new service, then rerun the verified installer or remote playbook.
Ansible validates the complete Caddy candidate before reloading it; do not
restart Caddy directly.

```bash
cd /opt/vps-nook
sudo docker compose config -q
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
- Use the upstream image health check when provided; otherwise add a
  service-appropriate check. Include it in operator monitoring when the service
  matters.
- Review the container's capabilities, volumes, user, and update policy.

The per-service recipes are operator-owned extensions, not part of the
supported core service set.
