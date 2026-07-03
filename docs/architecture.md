# Architecture

## Default topology

```text
Remote browser
  ↓ HTTPS
Tailscale Serve/Funnel
  ↓ localhost on host
Apache Guacamole web container
  ↓ guacd protocol, Docker network
Guacd container
  ├─ SSH → Docker gateway:2222 → sshd-guacamole → host shell
  └─ RDP → Docker gateway:3390 → KRdp → active KDE Wayland session
```

## Network boundaries

| Service | Bind/exposure | Purpose |
|---|---|---|
| Guacamole HTTP | `127.0.0.1:8080` | Web UI, fronted by Tailscale Serve/Funnel |
| PostgreSQL | Docker network only | Guacamole DB |
| guacd | Docker network only | Protocol proxy |
| `sshd-guacamole` | Docker gateway only, default `:2222` | Browser SSH target |
| KRdp | default `:3390`, firewall-limited | KDE desktop RDP target |

## Why a separate SSHD?

Modern OpenSSH defaults can negotiate algorithms that older `guacd`/libssh2 cannot handle. Instead of weakening the host's main SSH server, this project creates a separate compatibility SSHD that:

- listens only on the Docker gateway
- accepts only the selected desktop user
- requires public-key auth
- disables root login, forwarding, agent forwarding, and X11 forwarding
- uses RSA host key / conservative algorithms for Guacamole compatibility

## Why explicit Docker gateway mapping?

`host.docker.internal:host-gateway` may resolve to `172.17.0.1`, while a custom Compose network may use `172.18.0.1` or another gateway. Guacamole target connections originate in `guacd`, so the mapping must be correct in the `guacd` container.

The scripts detect:

```bash
docker network inspect guacamole_guac-net --format '{{(index .IPAM.Config 0).Gateway}}'
```

and write the detected gateway explicitly.

## Why bridge firewall rules?

Some host firewalls drop container-to-host traffic. The symptom is:

```text
Host can connect to gateway:2222
Container on guacamole_guac-net times out on gateway:2222
```

The scripts add narrow allow rules:

```text
input interface: Guacamole bridge
source: Guacamole subnet
destination: Docker gateway
port: 2222 or 3390
```

For KRdp, an additional generic DROP on the RDP port can prevent LAN/public access after the bridge allow rule.

## KRdp mirror effect

KRdp mirrors the active KDE session. If the Guacamole browser tab is open inside that same mirrored session, the stream contains itself recursively. This is expected and confirms the desktop stream works. Test from another device for a normal view.
