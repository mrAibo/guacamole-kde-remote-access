#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with: sudo bash $0" >&2
  exit 1
fi

APP_USER="${APP_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo)}}"
[[ -n "$APP_USER" && "$APP_USER" != "root" ]] || APP_USER="${GUAC_APP_USER:-}"
if [[ -z "$APP_USER" ]]; then
  echo "Set APP_USER to the non-root desktop user, e.g. sudo APP_USER=youruser bash $0" >&2
  exit 1
fi
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6 2>/dev/null || echo "/home/$APP_USER")"
BASE="${GUAC_BASE:-/opt/guacamole}"
NET="${NET_NAME:-guacamole_guac-net}"
SSH_PORT="${GUAC_SSH_PORT:-2222}"

cd "$BASE"
set -a
# shellcheck disable=SC1091
source "$BASE/.env"
set +a

GATEWAY="$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET" 2>/dev/null || true)"
SUBNET="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$NET" 2>/dev/null || true)"
BRIDGE="$(ip -o route show "$SUBNET" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1 || true)"

echo "=== 1) containers ==="
docker compose ps || true

echo
echo "=== 2) network/listeners ==="
echo "APP_USER=$APP_USER APP_HOME=$APP_HOME NET=$NET GATEWAY=$GATEWAY SUBNET=$SUBNET BRIDGE=$BRIDGE SSH_PORT=$SSH_PORT"
ss -tlnp | grep -E ":(22|${SSH_PORT}|8080|4822|5432)" || true

echo
echo "=== 3) compat sshd journal ==="
journalctl -u sshd-guacamole -n 120 --no-pager || true

echo
echo "=== 4) host local compat ssh test ==="
if [[ -n "$GATEWAY" && -f "$APP_HOME/.ssh/guacamole_rsa" ]]; then
  sudo -u "$APP_USER" ssh \
    -p "$SSH_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    -o HostKeyAlgorithms=+ssh-rsa \
    -o PubkeyAcceptedAlgorithms=+ssh-rsa,rsa-sha2-512,rsa-sha2-256 \
    -i "$APP_HOME/.ssh/guacamole_rsa" \
    "$APP_USER@$GATEWAY" 'echo HOST_COMPAT_SSH_OK && whoami && hostname' || true
else
  echo "Skipping: missing gateway or $APP_HOME/.ssh/guacamole_rsa"
fi

echo
echo "=== 5) guacd hosts file ==="
docker exec guac-guacd sh -lc 'grep host.docker.internal /etc/hosts; echo ---; cat /etc/hosts' || true

echo
echo "=== 6) network probe from same docker network ==="
if [[ -n "$GATEWAY" ]]; then
  docker run --rm --network "$NET" --add-host "host.docker.internal:$GATEWAY" alpine:3.20 sh -lc "
    apk add --no-cache openssh-client netcat-openbsd >/dev/null
    echo hosts:; getent hosts host.docker.internal || true
    echo nc-gateway-${SSH_PORT}:; nc -vz -w 5 ${GATEWAY} ${SSH_PORT} || true
    echo ssh-keyscan-${SSH_PORT}:; ssh-keyscan -T 5 -p ${SSH_PORT} ${GATEWAY} 2>&1 | head -20 || true
    echo ssh-handshake-noauth-${SSH_PORT}:; ssh -vvv -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa -p ${SSH_PORT} nobody@${GATEWAY} true 2>&1 | grep -E 'kex: algorithm|host key algorithm|Server host key|Authentications that can continue|Permission denied|Connection refused|No route|Connection timed|Unable|error' || true
  " || true
else
  echo "Skipping: Docker gateway not detected"
fi

echo
echo "=== 7) Guacamole SSH connection parameters (secrets redacted) ==="
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" guac-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -c "
SELECT c.connection_id,
       c.connection_name,
       p.parameter_name,
       CASE
         WHEN p.parameter_name IN ('private-key','password','passphrase')
           THEN '[REDACTED len=' || length(p.parameter_value)::text || ']'
         ELSE p.parameter_value
       END AS parameter_value
FROM guacamole_connection c
JOIN guacamole_connection_parameter p ON c.connection_id = p.connection_id
WHERE c.protocol = 'ssh'
ORDER BY c.connection_id, p.parameter_name;
" || true

echo
echo "=== 8) latest guacd logs ==="
docker logs guac-guacd --tail=160 || true

echo
echo "=== done ==="
