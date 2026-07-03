#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with: sudo bash $0" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_step() {
  local label="$1"
  local script="$2"
  echo
  echo "================================================================"
  echo "== $label"
  echo "================================================================"
  bash "$script"
}

run_step "1/4 Guacamole Docker stack" "$HERE/01-setup-guacamole.sh"
run_step "2/4 Docker-only SSH compatibility service" "$HERE/02-setup-guacamole-ssh-compat.sh"
run_step "3/4 Guacamole bridge firewall for SSH" "$HERE/03-fix-guacamole-bridge-firewall.sh"
run_step "4/4 KRdp desktop on port 3390 + Guacamole RDP connection" "$HERE/04-setup-krdp-3390.sh"

echo
cat <<'EOF'
DONE.

Open Guacamole:
  http://127.0.0.1:8080

Initial login:
  guacadmin / guacadmin

Immediately harden:
  1. Change guacadmin password.
  2. Create a non-default admin user.
  3. Enroll TOTP.
  4. Test backup: sudo /opt/guacamole/backup-guacamole.sh
  5. Test Host SSH and KDE/Hermes Desktop.

Optional Tailscale Serve after hardening:
  tailscale serve --bg 8080
EOF
