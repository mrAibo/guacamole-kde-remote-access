#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with: sudo bash $0" >&2
  exit 1
fi

NET="guacamole_guac-net"
PORT="2222"
HELPER="/usr/local/sbin/guacamole-bridge-firewall.sh"
SERVICE="/etc/systemd/system/guacamole-bridge-firewall.service"
TS="$(date +%Y%m%d-%H%M%S)"

GATEWAY="$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET")"
SUBNET="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$NET")"
BRIDGE="$(ip -o route show "$SUBNET" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"

if [[ -z "$GATEWAY" || -z "$SUBNET" || -z "$BRIDGE" ]]; then
  echo "ERROR: Could not detect gateway/subnet/bridge" >&2
  echo "GATEWAY=$GATEWAY SUBNET=$SUBNET BRIDGE=$BRIDGE" >&2
  docker network inspect "$NET" || true
  ip route || true
  exit 1
fi

echo "Detected: NET=$NET SUBNET=$SUBNET GATEWAY=$GATEWAY BRIDGE=$BRIDGE PORT=$PORT"

echo "=== Before: listener + container probe ==="
ss -tlnp | grep ":${PORT}" || true
docker run --rm --network "$NET" alpine:3.20 sh -lc "apk add --no-cache netcat-openbsd openssh-client >/dev/null; nc -vz -w 3 ${GATEWAY} ${PORT}; ssh-keyscan -T 3 -p ${PORT} ${GATEWAY} 2>&1 | head -5" || true

echo "=== Firewall status ==="
ufw status verbose 2>/dev/null || true
nft list ruleset 2>/dev/null | sed -n '1,120p' || true

echo "=== Add immediate iptables allow rule (specific to Guacamole bridge) ==="
iptables -C INPUT -i "$BRIDGE" -s "$SUBNET" -d "$GATEWAY" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -i "$BRIDGE" -s "$SUBNET" -d "$GATEWAY" -p tcp --dport "$PORT" -j ACCEPT

echo "=== Add persistent helper service ==="
[[ -e "$HELPER" ]] && cp -a "$HELPER" "${HELPER}.bak.${TS}"
cat > "$HELPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
NET="$NET"
PORT="$PORT"
GATEWAY="\$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "\$NET")"
SUBNET="\$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "\$NET")"
BRIDGE="\$(ip -o route show "\$SUBNET" | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1)}' | head -1)"
iptables -C INPUT -i "\$BRIDGE" -s "\$SUBNET" -d "\$GATEWAY" -p tcp --dport "\$PORT" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -i "\$BRIDGE" -s "\$SUBNET" -d "\$GATEWAY" -p tcp --dport "\$PORT" -j ACCEPT
EOF
chmod 755 "$HELPER"

[[ -e "$SERVICE" ]] && cp -a "$SERVICE" "${SERVICE}.bak.${TS}"
cat > "$SERVICE" <<EOF
[Unit]
Description=Allow Guacamole Docker bridge to reach host SSHD compatibility port
After=docker.service sshd-guacamole.service
Wants=docker.service sshd-guacamole.service

[Service]
Type=oneshot
ExecStart=${HELPER}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now guacamole-bridge-firewall.service

echo "=== After: iptables rule ==="
iptables -S INPUT | grep -- "--dport ${PORT}" || true

echo "=== After: container network probe ==="
docker run --rm --network "$NET" alpine:3.20 sh -lc "
  apk add --no-cache openssh-client netcat-openbsd >/dev/null
  echo nc:
  nc -vz -w 5 ${GATEWAY} ${PORT}
  echo keyscan:
  ssh-keyscan -T 5 -p ${PORT} ${GATEWAY} 2>&1 | head -20
  echo noauth-handshake:
  ssh -vvv -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa -p ${PORT} nobody@${GATEWAY} true 2>&1 | grep -E 'kex: algorithm|host key algorithm|Server host key|Authentications that can continue|Permission denied|Connection refused|No route|Connection timed|Unable|error' || true
"

echo "=== Restart guacd/web to clear stale state ==="
cd /opt/guacamole
docker compose up -d --force-recreate guacd guacamole
sleep 2
docker logs guac-guacd --tail=80 || true

echo "OK. Now reload Guacamole and try Hermes SSH again. If it fails, immediately run:"
echo "sudo tail -160 /var/log/sshd-guacamole.log"
echo "sudo docker logs guac-guacd --tail=160"
