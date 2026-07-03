#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with: sudo bash $0" >&2
  exit 1
fi

APP_USER="${APP_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo)}}"
if [[ -z "$APP_USER" || "$APP_USER" == "root" ]]; then
  echo "Set APP_USER to the non-root desktop user, e.g. sudo APP_USER=youruser bash $0" >&2
  exit 1
fi
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
APP_UID="$(id -u "$APP_USER")"
BASE="/opt/guacamole"
NET="guacamole_guac-net"
RDP_PORT="3390"
RDP_USER="guac-rdp"
SECRET_DIR="$APP_HOME/.config/guacamole-krdp"
SECRET_FILE="$SECRET_DIR/rdp.env"
SERVICE_DIR="$APP_HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/guacamole-krdp.service"
FW_HELPER="/usr/local/sbin/guacamole-krdp-bridge-firewall.sh"
FW_SERVICE="/etc/systemd/system/guacamole-krdp-bridge-firewall.service"
TS="$(date +%Y%m%d-%H%M%S)"

echo "=== 1) Install packages ==="
pacman -S --needed --noconfirm krdp freerdp

KRDP_BIN="$(command -v krdpserver || true)"
if [[ -z "$KRDP_BIN" ]]; then
  echo "ERROR: krdpserver not found after installing krdp" >&2
  pacman -Ql krdp | sed -n '1,160p' || true
  exit 1
fi

echo "krdpserver: $KRDP_BIN"

GATEWAY="$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET")"
SUBNET="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$NET")"
BRIDGE="$(ip -o route show "$SUBNET" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
if [[ -z "$GATEWAY" || -z "$SUBNET" || -z "$BRIDGE" ]]; then
  echo "ERROR: Could not detect Docker network gateway/subnet/bridge" >&2
  docker network inspect "$NET" || true
  ip route || true
  exit 1
fi

echo "Docker target: gateway=$GATEWAY subnet=$SUBNET bridge=$BRIDGE"

mkdir -p "$SECRET_DIR" "$SERVICE_DIR"
chown -R "$APP_USER:$APP_USER" "$APP_HOME/.config" "$SERVICE_DIR" "$SECRET_DIR"
chmod 700 "$SECRET_DIR"

if [[ ! -f "$SECRET_FILE" ]]; then
  PASS="$(openssl rand -base64 24 | tr -d '\n')"
  cat > "$SECRET_FILE" <<EOF
KRDP_USER=$RDP_USER
KRDP_PASSWORD=$PASS
KRDP_PORT=$RDP_PORT
EOF
  chown "$APP_USER:$APP_USER" "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
  echo "Generated KRdp credentials in $SECRET_FILE"
else
  echo "Using existing KRdp credentials in $SECRET_FILE"
fi
# shellcheck disable=SC1090
source "$SECRET_FILE"
KRDP_USER="${KRDP_USER:-$RDP_USER}"

CERT_DIR="$SECRET_DIR/certs"
CERT="$CERT_DIR/krdp.crt"
KEY="$CERT_DIR/krdp.key"
mkdir -p "$CERT_DIR"
chown "$APP_USER:$APP_USER" "$CERT_DIR"
chmod 700 "$CERT_DIR"
if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
  sudo -u "$APP_USER" openssl req -nodes -new -x509 -keyout "$KEY" -out "$CERT" -days 365 -subj "/CN=guacamole-krdp" >/dev/null 2>&1
  chmod 600 "$KEY"
  chmod 644 "$CERT"
  chown "$APP_USER:$APP_USER" "$KEY" "$CERT"
fi

echo "=== 2) Configure KRdp user service ==="
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=KRdp server for Guacamole on port $RDP_PORT
After=graphical-session.target plasma-workspace.target
PartOf=graphical-session.target

[Service]
Type=simple
EnvironmentFile=$SECRET_FILE
ExecStart=$KRDP_BIN -u \${KRDP_USER} -p \${KRDP_PASSWORD} --port \${KRDP_PORT} --certificate $CERT --certificate-key $KEY --quality 80
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
chown "$APP_USER:$APP_USER" "$SERVICE_FILE"
chmod 600 "$SERVICE_FILE"

# Native KRdp may need portal authorization. Configure when possible; harmless if keys are ignored by this version.
sudo -u "$APP_USER" XDG_RUNTIME_DIR="/run/user/$APP_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$APP_UID/bus" \
  kwriteconfig6 --file krdpserverrc --group General --key Certificate "$CERT" || true
sudo -u "$APP_USER" XDG_RUNTIME_DIR="/run/user/$APP_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$APP_UID/bus" \
  kwriteconfig6 --file krdpserverrc --group General --key CertificateKey "$KEY" || true

# Grant KDE portal permission for the native KRdp server if permission-store is available.
sudo -u "$APP_USER" XDG_RUNTIME_DIR="/run/user/$APP_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$APP_UID/bus" \
  busctl --user call org.freedesktop.impl.portal.PermissionStore /org/freedesktop/impl/portal/PermissionStore org.freedesktop.impl.portal.PermissionStore SetPermission ssssb kde-authorized remote-desktop org.kde.krdpserver yes true 2>/dev/null || true

sudo -u "$APP_USER" XDG_RUNTIME_DIR="/run/user/$APP_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$APP_UID/bus" systemctl --user daemon-reload
sudo -u "$APP_USER" XDG_RUNTIME_DIR="/run/user/$APP_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$APP_UID/bus" systemctl --user enable --now guacamole-krdp.service
sleep 3

echo "=== 3) Firewall: allow only Guacamole Docker bridge -> host KRdp port ==="
iptables -C INPUT -i "$BRIDGE" -s "$SUBNET" -d "$GATEWAY" -p tcp --dport "$RDP_PORT" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -i "$BRIDGE" -s "$SUBNET" -d "$GATEWAY" -p tcp --dport "$RDP_PORT" -j ACCEPT

[[ -e "$FW_HELPER" ]] && cp -a "$FW_HELPER" "${FW_HELPER}.bak.${TS}"
cat > "$FW_HELPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
NET="$NET"
PORT="$RDP_PORT"
GATEWAY="\$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "\$NET")"
SUBNET="\$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "\$NET")"
BRIDGE="\$(ip -o route show "\$SUBNET" | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1)}' | head -1)"
iptables -C INPUT -i "\$BRIDGE" -s "\$SUBNET" -d "\$GATEWAY" -p tcp --dport "\$PORT" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -i "\$BRIDGE" -s "\$SUBNET" -d "\$GATEWAY" -p tcp --dport "\$PORT" -j ACCEPT
EOF
chmod 755 "$FW_HELPER"

[[ -e "$FW_SERVICE" ]] && cp -a "$FW_SERVICE" "${FW_SERVICE}.bak.${TS}"
cat > "$FW_SERVICE" <<EOF
[Unit]
Description=Allow Guacamole Docker bridge to reach KRdp desktop port
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=$FW_HELPER
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now guacamole-krdp-bridge-firewall.service

echo "=== 4) Verify KRdp listener and Docker reachability ==="
ss -tlnp | grep -E ":($RDP_PORT)" || true
sudo -u "$APP_USER" XDG_RUNTIME_DIR="/run/user/$APP_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$APP_UID/bus" \
  systemctl --user --no-pager status guacamole-krdp.service || true

docker run --rm --network "$NET" alpine:3.20 sh -lc "apk add --no-cache netcat-openbsd >/dev/null; nc -vz -w 5 $GATEWAY $RDP_PORT"

echo "=== 5) Add/Update Guacamole RDP connection ==="
if [[ ! -f "$BASE/.env" ]]; then
  echo "ERROR: missing $BASE/.env" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source "$BASE/.env"
set +a

# Upsert connection and parameters. Secrets are stored in Guacamole Postgres, not printed.
docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" guac-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
DECLARE
  cid integer;
BEGIN
  SELECT connection_id INTO cid FROM guacamole_connection WHERE connection_name = 'Hermes Desktop';
  IF cid IS NULL THEN
    INSERT INTO guacamole_connection (connection_name, protocol, max_connections, max_connections_per_user)
    VALUES ('Hermes Desktop', 'rdp', NULL, NULL)
    RETURNING connection_id INTO cid;
  ELSE
    UPDATE guacamole_connection SET protocol='rdp' WHERE connection_id=cid;
    DELETE FROM guacamole_connection_parameter WHERE connection_id=cid;
  END IF;

  INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value) VALUES
    (cid, 'hostname', '$GATEWAY'),
    (cid, 'port', '$RDP_PORT'),
    (cid, 'username', '$KRDP_USER'),
    (cid, 'password', '$KRDP_PASSWORD'),
    (cid, 'security', 'any'),
    (cid, 'ignore-cert', 'true'),
    (cid, 'server-layout', '${RDP_SERVER_LAYOUT:-de-de-qwertz}'),
    (cid, 'enable-wallpaper', 'true'),
    (cid, 'resize-method', 'display-update'),
    (cid, 'color-depth', '24');
END
\$\$;
SQL

echo "=== 6) Guacamole RDP connection parameters (redacted) ==="
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" guac-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -c "
SELECT c.connection_id, c.connection_name, p.parameter_name,
       CASE WHEN p.parameter_name IN ('password') THEN '[REDACTED len=' || length(p.parameter_value)::text || ']'
            ELSE p.parameter_value END AS parameter_value
FROM guacamole_connection c
JOIN guacamole_connection_parameter p ON c.connection_id=p.connection_id
WHERE c.connection_name='Hermes Desktop'
ORDER BY p.parameter_name;
"

echo
echo "OK. In Guacamole reload the page; open connection: Hermes Desktop"
echo "KRdp credential file: $SECRET_FILE (root/user readable only). Password not printed."
echo "If first KRdp start requests KDE Remote Desktop permission, confirm it locally once."
echo "Logs: journalctl --user -u guacamole-krdp.service --no-pager -n 100"