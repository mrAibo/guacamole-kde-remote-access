# Security policy

This project configures remote access. Treat every deployment as security-sensitive.

## Supported versions

| Version | Supported |
|---|---:|
| `v0.1.x` | ✅ |
| older/unreleased local scripts | ❌ |

## Security model

Default design:

- Guacamole binds to `127.0.0.1:8080` only.
- Remote web access should go through Tailscale Serve first.
- Public Tailscale Funnel should only be enabled after Guacamole hardening.
- Guacamole's SSH/RDP targets are host-gateway-only services reached from the Guacamole Docker bridge.
- The compatibility SSHD is separate from the host's main SSHD.
- KRdp should be firewalled so only the Guacamole Docker bridge can reach it.

## Hardening checklist

Before enabling public access:

- [ ] Change the default `guacadmin` password.
- [ ] Create a non-default admin account.
- [ ] Enable/enroll TOTP.
- [ ] Disable or demote `guacadmin` if possible.
- [ ] Test `/opt/guacamole/backup-guacamole.sh`.
- [ ] Verify Guacamole is bound to localhost only.
- [ ] Verify SSH/RDP target ports are not exposed on LAN/public interfaces.
- [ ] Confirm Tailscale Serve works before Funnel.

## Secrets

Never commit:

- `/opt/guacamole/.env`
- private SSH keys
- KRdp password files
- database dumps
- screenshots containing private keys/passwords/TOTP secrets

If a private key was exposed, rotate it:

1. Generate a new key.
2. Update `authorized_keys`.
3. Update the Guacamole connection parameter.
4. Remove the old key from disk and `authorized_keys`.

## Reporting vulnerabilities

Open a private issue/discussion if available, or contact the repository owner directly. Do not publish working exploit details before a fix is available.
