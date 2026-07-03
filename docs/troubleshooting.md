# Troubleshooting

## SSH: `Auth key successfully imported` then `SSH handshake failed`

The private key was parsed. Suspect networking or SSH algorithm negotiation.

Useful command:

```bash
sudo bash scripts/diagnose-guacamole-ssh.sh
```

Key clues:

```text
nc <gateway> 2222 timed out
ssh-keyscan <gateway> empty
```

If host-side SSH works but a Docker container times out, the host firewall is dropping Docker-bridge INPUT traffic. Run the bridge firewall script.

## Wrong `host.docker.internal` gateway

Do not blindly hard-code `172.17.0.1`. Detect the actual Guacamole network gateway:

```bash
docker network inspect guacamole_guac-net --format '{{(index .IPAM.Config 0).Gateway}}'
```

The SSH compatibility script rewrites Guacamole's compose file to use the detected gateway.

## KRdp infinite mirror

KRdp mirrors your active KDE Wayland desktop. If you open Guacamole inside that same desktop, you see:

```text
Desktop -> browser -> Guacamole -> Desktop -> browser -> ...
```

This is expected. Test from another device, or minimize/move the local browser window.

## RDP keyboard layout is English / wrong

Symptom examples:

```text
z/y swapped
ä/ö/ü missing or wrong
@, €, \\, |, { }, [ ] broken
```

Reason: Guacamole's RDP layer needs the server-side keyboard layout. If `server-layout` is missing, guacd defaults to US English QWERTY even if KDE itself is German.

Set a persistent layout in the Guacamole database and restart Guacamole services:

```bash
# German / Germany
sudo bash scripts/05-set-rdp-keyboard-layout.sh de-de-qwertz

# German / Switzerland
sudo bash scripts/05-set-rdp-keyboard-layout.sh de-ch-qwertz

# Last-resort Unicode input mode if AltGr/special keys still fail
sudo bash scripts/05-set-rdp-keyboard-layout.sh failsafe
```

After running the script, fully disconnect the active RDP session, reload the browser page, and reconnect.

Supported known values include:

```text
de-de-qwertz
de-ch-qwertz
fr-ch-qwertz
failsafe
```

`server-layout` is the RDP server layout, not the browser/client layout.

## KRdp permission prompt

KRdp may need a KDE/portal permission prompt on first start. Confirm it locally.

Logs:

```bash
journalctl --user -u guacamole-krdp.service -n 120 --no-pager
```

## `sudo` rejects a newly changed password

Arch/CachyOS may lock PAM through `faillock` after three failed sudo attempts. Reset as root:

```bash
su -
faillock --user aibo
faillock --user aibo --reset
faillock --user aibo
```

Then test:

```bash
sudo -k
sudo -v
```

## Tailscale Serve requires approval

Run:

```bash
tailscale serve --bg 8080
```

If it prints an approval link, open it and approve Serve in the Tailscale admin UI.

## Public Funnel checklist

Before enabling:

```bash
tailscale funnel --bg 8080
```

Verify:

- default `guacadmin` password changed
- TOTP enrolled
- non-default admin created
- backups tested
- SSH/RDP connections tested
- you understand KRdp mirrors the active local desktop
