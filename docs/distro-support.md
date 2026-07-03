# Distribution support

This project now has two setup paths:

| Path | Best for | Status |
|---|---|---|
| `scripts/install-all.sh` | CachyOS/Arch/KDE, session-proven path | Tested on the original CachyOS host |
| `scripts/install-cross-distro.sh` | Portable Guacamole + SSH setup across common Linux families | Generic, best-effort, needs wider community testing |

## Supported distro families

| Distro family | Package manager | Guacamole Docker stack | Host SSH via Guacamole | KRdp desktop | Notes |
|---|---|---:|---:|---:|---|
| Arch / CachyOS / EndeavourOS | `pacman` | ✅ | ✅ | ✅ | Primary tested target |
| Debian / Ubuntu | `apt` | ✅ | ✅ | 🟡 | KRdp may not be packaged; use `ENABLE_KRDP=0` or install KRdp manually |
| Fedora | `dnf` | ✅ | ✅ | 🟡 | Docker package naming/policy may vary; Podman is not supported by these scripts yet |
| openSUSE | `zypper` | ✅ | ✅ | 🟡 | Docker Compose package naming may vary by release |

Legend:

- ✅ implemented in scripts
- 🟡 best-effort / depends on distro package availability
- ❌ not implemented

## Recommended commands

### Arch / CachyOS / EndeavourOS

```bash
sudo bash scripts/install-all.sh
```

or the portable path:

```bash
sudo bash scripts/install-cross-distro.sh
```

### Debian / Ubuntu

```bash
sudo APP_USER=$USER ENABLE_KRDP=0 bash scripts/install-cross-distro.sh
```

This installs Guacamole + browser SSH. For desktop access, choose one of:

- install KRdp manually if available for your KDE version, then rerun with `ENABLE_KRDP=1`
- add a separate VNC/xrdp target manually in Guacamole
- use SSH only

### Fedora

```bash
sudo APP_USER=$USER ENABLE_KRDP=0 bash scripts/install-cross-distro.sh
```

Fedora users may prefer Podman, but these scripts currently require Docker Compose v2.

### openSUSE

```bash
sudo APP_USER=$USER ENABLE_KRDP=0 bash scripts/install-cross-distro.sh
```

If Docker Compose is packaged differently on your release, install it first, then rerun.

## Desktop strategy by environment

| Desktop/session | Recommended protocol | Why |
|---|---|---|
| KDE Plasma Wayland | KRdp → Guacamole RDP | Native KDE remote desktop sharing |
| KDE Plasma X11 | KRdp if available, otherwise x11vnc/VNC | Depends on distro/version |
| GNOME Wayland | GNOME Remote Desktop or VNC/RDP target | Not automated yet |
| Headless server | SSH only, or TigerVNC virtual desktop | Avoids active-session sharing |
| Multi-user server | xrdp/TigerVNC virtual sessions | Separate sessions are safer than shadowing |

## Why desktop support is not fully universal yet

Guacamole is portable because it runs in Docker. Desktop sharing is less portable because Linux desktops expose different remote APIs:

- KDE Wayland: KRdp
- GNOME Wayland: GNOME Remote Desktop
- X11 desktops: x11vnc, TigerVNC, xrdp, xorgxrdp
- Headless systems: usually TigerVNC/xrdp virtual sessions

The project intentionally automates the session-proven KDE/KRdp path first and documents fallback strategies for other systems.

## Contributions wanted

Useful additions:

- Debian/Ubuntu KRdp package detection
- GNOME Remote Desktop setup helper
- xrdp/xorgxrdp virtual desktop recipe
- TigerVNC virtual desktop recipe
- nftables-native firewall persistence
- CI with shellcheck and containerized syntax tests
