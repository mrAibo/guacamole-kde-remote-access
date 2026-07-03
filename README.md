# Secure Guacamole + Tailscale + KDE Remote Desktop

A practical setup for secure browser-based remote access to an Arch/CachyOS KDE Wayland host.

It installs/configures:

- Apache Guacamole in Docker, bound to `127.0.0.1:8080`
- PostgreSQL backend with Guacamole TOTP enabled
- optional Tailscale Serve/Funnel in front of Guacamole
- browser SSH to the host through a Docker-only compatibility `sshd` on port `2222`
- KDE Plasma Wayland desktop access through KRdp on port `3390`
- narrow firewall rules for `guacd`/Guacamole Docker bridge access to host-only SSH/RDP targets

## Why this repo exists

This setup was consolidated after debugging several real failure modes:

1. `guacd`, not the Guacamole web container, opens SSH/RDP target connections.
2. `host.docker.internal:host-gateway` may resolve to the wrong bridge on custom Docker networks.
3. `guacd`/libssh2 can fail SSH handshakes against modern OpenSSH defaults.
4. Host firewall rules can silently drop Docker-bridge traffic to host services.
5. KRdp mirrors the active KDE session, so opening Guacamole on the same desktop creates an infinite mirror.

## Tested target

- CachyOS / Arch-like Linux
- KDE Plasma Wayland
- Docker Compose v2
- Apache Guacamole 1.6.0
- KRdp 6.x

## Quick start

```bash
git clone https://github.com/mrAibo/guacamole-kde-remote-access.git
cd guacamole-kde-remote-access
sudo bash scripts/install-all.sh
```

Open Guacamole locally:

```text
http://127.0.0.1:8080
```

Initial login after first bootstrap:

```text
guacadmin / guacadmin
```

Immediately:

1. Change the default password.
2. Create a non-default admin account.
3. Enroll TOTP.
4. Test backup.
5. Test `Host SSH` and `Hermes Desktop` / `KDE Desktop`.

## Optional Tailscale Serve

After hardening Guacamole:

```bash
tailscale serve --bg 8080
tailscale serve status
```

If Tailscale prints an admin approval URL, open it and approve Serve.

Only after Guacamole is hardened and tested:

```bash
tailscale funnel --bg 8080
tailscale funnel status
```

## Scripts

| Script | Purpose |
|---|---|
| `scripts/install-all.sh` | Runs the full setup in order |
| `scripts/01-setup-guacamole.sh` | Guacamole/Postgres/guacd Docker stack, localhost-only HTTP, backup script |
| `scripts/02-setup-guacamole-ssh-compat.sh` | Docker-gateway-only compatibility SSHD and Guacamole SSH connection |
| `scripts/03-fix-guacamole-bridge-firewall.sh` | Narrow firewall allow rule for Guacamole Docker bridge to SSHD |
| `scripts/04-setup-krdp-3390.sh` | KRdp user service, RDP firewall rule, Guacamole RDP connection |
| `scripts/diagnose-guacamole-ssh.sh` | Deep SSH/Guacamole diagnostics with secrets redacted |

## Main paths/services

| Item | Path/service |
|---|---|
| Guacamole base | `/opt/guacamole` |
| Compose file | `/opt/guacamole/docker-compose.yml` |
| Env file | `/opt/guacamole/.env` |
| Backups | `/opt/guacamole/backups` |
| Backup command | `/opt/guacamole/backup-guacamole.sh` |
| SSH key | `~/.ssh/guacamole_rsa` |
| Compat SSHD | `sshd-guacamole.service` on Docker gateway `:2222` |
| KRdp user service | `guacamole-krdp.service` on `:3390` |
| Bridge firewall | systemd oneshot helpers under `/etc/systemd/system/` |

## Backups

```bash
sudo /opt/guacamole/backup-guacamole.sh
ls -lh /opt/guacamole/backups
```

## Security notes

- Guacamole binds to `127.0.0.1:8080`, not LAN/public.
- Do not enable Tailscale Funnel until Guacamole is hardened.
- KRdp mirrors the active KDE Wayland desktop.
- The RDP password/private SSH key are generated locally and are not printed by the scripts.
- If you accidentally expose or screenshot a private key, rotate it.

## Troubleshooting

See [`docs/troubleshooting.md`](docs/troubleshooting.md).

## License

MIT. See [`LICENSE`](LICENSE).
