#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with: sudo bash $0" >&2
  exit 1
fi

BASE="/opt/guacamole"
COMPOSE="$BASE/docker-compose.yml"
SSHD_CONF="/etc/ssh/sshd_config_guacamole"
SERVICE="/etc/systemd/system/sshd-guacamole.service"
APP_USER="${APP_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo)}}"
if [[ -z "$APP_USER" || "$APP_USER" == "root" ]]; then
  echo "Set APP_USER to the non-root desktop user, e.g. sudo APP_USER=youruser bash $0" >&2
  exit 1
fi
TS="$(date +%Y%m%d-%H%M%S)"
cd "$BASE"
set -a
source "$BASE/.env"
set +a

GATEWAY="$(docker network inspect guacamole_guac-net --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
if [[ -z "$GATEWAY" || "$GATEWAY" == "<no value>" ]]; then
  echo "ERROR: cannot detect guacamole_guac-net gateway" >&2
  docker network inspect guacamole_guac-net || true
  exit 1
fi

echo "Using Guacamole Docker gateway: $GATEWAY"

ssh-keygen -A >/dev/null
[[ -e "$SSHD_CONF" ]] && cp -a "$SSHD_CONF" "${SSHD_CONF}.bak.${TS}"
cat > "$SSHD_CONF" <<EOF
# Dedicated SSHD for Apache Guacamole/libssh2 compatibility.
# Docker-only listener: not LAN/Tailscale/public.
Port 2222
ListenAddress ${GATEWAY}
Protocol 2

HostKey /etc/ssh/ssh_host_rsa_key

PermitRootLogin no
AllowUsers ${APP_USER}
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no

AllowTcpForwarding no
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
PermitTTY yes

# Compatibility mode for guacd/libssh2. This is intentionally scoped to Docker-only 2222.
HostKeyAlgorithms ssh-rsa
PubkeyAcceptedAlgorithms +ssh-rsa,rsa-sha2-512,rsa-sha2-256
KexAlgorithms diffie-hellman-group14-sha1,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512
Ciphers aes128-ctr,aes192-ctr,aes256-ctr
MACs hmac-sha1,hmac-sha2-256,hmac-sha2-512

AuthorizedKeysFile .ssh/authorized_keys
LogLevel VERBOSE
Subsystem sftp internal-sftp
EOF

/usr/sbin/sshd -t -f "$SSHD_CONF"

if [[ ! -f "$SERVICE" ]]; then
  cat > "$SERVICE" <<EOF
[Unit]
Description=OpenSSH server for Apache Guacamole compatibility
After=network.target docker.service
Wants=docker.service

[Service]
ExecStart=/usr/sbin/sshd -D -f ${SSHD_CONF} -E /var/log/sshd-guacamole.log
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable --now sshd-guacamole.service
systemctl restart sshd-guacamole.service
sleep 1

echo "=== listener ==="
ss -tlnp | grep ':2222' || { echo "ERROR: no 2222 listener" >&2; exit 1; }

echo "=== host-side SSH test to compat daemon ==="
sudo -u "$APP_USER" ssh \
  -p 2222 \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=accept-new \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa,rsa-sha2-512,rsa-sha2-256 \
  -i "/home/${APP_USER}/.ssh/guacamole_rsa" \
  "${APP_USER}@${GATEWAY}" 'echo LIBSSH2_COMPAT_SSH_OK && whoami && hostname'

# Keep host mapping deterministic for future, but DB below uses direct gateway IP to remove DNS as a variable.
[[ -e "$COMPOSE" ]] && cp -a "$COMPOSE" "${COMPOSE}.bak.${TS}"
python3 - <<PY
from pathlib import Path
p = Path('$COMPOSE')
text = p.read_text()
import re
text = re.sub(r'host\.docker\.internal:[^"\n]+', 'host.docker.internal:$GATEWAY', text)
p.write_text(text)
PY

echo "=== recreate guacd/web ==="
docker compose up -d --force-recreate guacd guacamole
sleep 2

echo "=== guacd host mapping ==="
docker exec guac-guacd sh -lc 'getent hosts host.docker.internal || grep host.docker.internal /etc/hosts || true'

echo "=== container handshake test ==="
docker run --rm --network guacamole_guac-net alpine:3.20 sh -lc "
  apk add --no-cache openssh-client >/dev/null
  echo keyscan:
  ssh-keyscan -T 5 -p 2222 ${GATEWAY} 2>&1 | head -20
  echo noauth-handshake:
  ssh -vvv -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa -p 2222 nobody@${GATEWAY} true 2>&1 | grep -E 'kex: algorithm|host key algorithm|Server host key|Authentications that can continue|Permission denied|Connection refused|No route|Connection timed|Unable|error' || true
"

echo "=== update Guacamole SSH connection hostname to direct Docker gateway ==="
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" guac-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -P pager=off <<SQL
WITH target AS (
  SELECT connection_id FROM guacamole_connection
  WHERE connection_name = 'Hermes SSH' AND protocol = 'ssh'
)
UPDATE guacamole_connection_parameter p
SET parameter_value = '${GATEWAY}'
FROM target t
WHERE p.connection_id = t.connection_id AND p.parameter_name = 'hostname';

WITH target AS (
  SELECT connection_id FROM guacamole_connection
  WHERE connection_name = 'Hermes SSH' AND protocol = 'ssh'
)
UPDATE guacamole_connection_parameter p
SET parameter_value = '2222'
FROM target t
WHERE p.connection_id = t.connection_id AND p.parameter_name = 'port';
SQL

echo "=== redacted Guacamole SSH parameters ==="
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" guac-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -c "
SELECT c.connection_id, c.connection_name, p.parameter_name,
       CASE WHEN p.parameter_name IN ('private-key','password','passphrase')
            THEN '[REDACTED len=' || length(p.parameter_value)::text || ']'
            ELSE p.parameter_value END AS parameter_value
FROM guacamole_connection c
JOIN guacamole_connection_parameter p ON c.connection_id = p.connection_id
WHERE c.protocol = 'ssh'
ORDER BY c.connection_id, p.parameter_name;
"

echo "=== recent sshd-guacamole journal ==="
journalctl -u sshd-guacamole -n 60 --no-pager || true

echo "OK. In Guacamole reload the page, then start Hermes SSH again. Hostname should now show ${GATEWAY}, port 2222."
