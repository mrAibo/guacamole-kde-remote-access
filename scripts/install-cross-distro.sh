#!/usr/bin/env bash
set -euo pipefail

# Cross-distro installer for the portable subset:
# - Docker + Compose
# - Apache Guacamole + PostgreSQL + guacd
# - Docker-gateway-only compatibility SSHD
# - narrow bridge firewall for container -> host SSH
# - optional KRdp only when krdpserver is available/installable
#
# Tested directly on Arch/CachyOS. Debian/Ubuntu/Fedora/openSUSE paths are
# intentionally conservative and may need distro-specific package names.

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with: sudo bash $0" >&2
  exit 1
fi

APP_USER="${APP_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo)}}"
if [[ -z "$APP_USER" || "$APP_USER" == "root" ]]; then
  echo "Set APP_USER to the non-root desktop user, e.g. sudo APP_USER=youruser bash $0" >&2
  exit 1
fi
id "$APP_USER" >/dev/null
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
APP_GROUP="$(id -gn "$APP_USER")"
APP_UID="$(id -u "$APP_USER")"

GUAC_BASE="${GUAC_BASE:-/opt/guacamole}"
GUAC_VERSION="${GUAC_VERSION:-1.6.0}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16-alpine}"
POSTGRES_DB="${POSTGRES_DB:-guacamole_db}"
POSTGRES_USER="${POSTGRES_USER:-guacamole_user}"
GUAC_HTTP_BIND="${GUAC_HTTP_BIND:-127.0.0.1}"
GUAC_HTTP_PORT="${GUAC_HTTP_PORT:-8080}"
GUAC_SSH_PORT="${GUAC_SSH_PORT:-2222}"
KRDP_PORT="${KRDP_PORT:-3390}"
KRDP_USER="${KRDP_USER:-guac-rdp}"
ENABLE_KRDP="${ENABLE_KRDP:-auto}"
NET_NAME="${NET_NAME:-guacamole_guac-net}"
TS="$(date +%Y%m%d-%H%M%S)"

log(){ printf '\n==> %s\n' "$*"; }
has(){ command -v "$1" >/dev/null 2>&1; }
backup(){ [[ -e "$1" ]] && cp -a "$1" "${1}.bak.${TS}"; }

source_os_release(){
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
  else
    ID=unknown
  fi
}

install_packages(){
  log "Installing base packages"
  source_os_release
  echo "Detected distro: ${PRETTY_NAME:-$ID}"

  if has pacman; then
    pacman -Syu --needed --noconfirm docker openssh openssl curl bash python iptables
    if [[ "$ENABLE_KRDP" != "0" ]]; then
      pacman -S --needed --noconfirm krdp freerdp || true
    fi
  elif has apt-get; then
    apt-get update
    apt-get install -y docker.io docker-compose-plugin openssh-server openssl curl bash python3 iptables iproute2 ca-certificates
    if [[ "$ENABLE_KRDP" == "1" ]]; then
      apt-get install -y krdp freerdp2-x11 || echo "WARN: KRdp package not available via apt; desktop step will be skipped unless krdpserver exists." >&2
    fi
  elif has dnf; then
    dnf install -y docker docker-compose-plugin openssh-server openssl curl bash python3 iptables iproute ca-certificates
    systemctl enable --now sshd || true
    if [[ "$ENABLE_KRDP" == "1" ]]; then
      dnf install -y krdp freerdp || echo "WARN: KRdp package not available via dnf; desktop step will be skipped unless krdpserver exists." >&2
    fi
  elif has zypper; then
    zypper --non-interactive install docker docker-compose openssh openssl curl bash python3 iptables iproute2 ca-certificates
    systemctl enable --now sshd || true
    if [[ "$ENABLE_KRDP" == "1" ]]; then
      zypper --non-interactive install krdp freerdp || echo "WARN: KRdp package not available via zypper; desktop step will be skipped unless krdpserver exists." >&2
    fi
  else
    echo "ERROR: unsupported package manager. Install Docker, Compose, OpenSSH, openssl, curl, python3, iptables manually." >&2
    exit 1
  fi
}

ensure_docker(){
  log "Starting Docker"
  systemctl enable --now docker
  if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker Compose v2 is required: docker compose version" >&2
    exit 1
  fi
}

write_stack(){
  log "Writing Guacamole stack"
  install -d -m 755 -o "$APP_USER" -g "$APP_GROUP" "$GUAC_BASE" "$GUAC_BASE/init" "$GUAC_BASE/backups"
  if [[ ! -f "$GUAC_BASE/.env" ]]; then
    cat > "$GUAC_BASE/.env" <<EOF
GUAC_VERSION=$GUAC_VERSION
POSTGRES_VERSION=$POSTGRES_VERSION
POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$(openssl rand -hex 32)
GUACAMOLE_HTTP_BIND=$GUAC_HTTP_BIND
GUACAMOLE_HTTP_PORT=$GUAC_HTTP_PORT
EOF
    chown "$APP_USER:$APP_GROUP" "$GUAC_BASE/.env"
    chmod 600 "$GUAC_BASE/.env"
  fi

  backup "$GUAC_BASE/docker-compose.yml"
  cat > "$GUAC_BASE/docker-compose.yml" <<'EOF'
services:
  postgres:
    image: postgres:${POSTGRES_VERSION}
    container_name: guac-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - guac-postgres-data:/var/lib/postgresql/data
      - ./init:/docker-entrypoint-initdb.d:ro
    networks: [guac-net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10

  guacd:
    image: guacamole/guacd:${GUAC_VERSION}
    container_name: guac-guacd
    restart: unless-stopped
    environment:
      LOG_LEVEL: debug
    networks: [guac-net]

  guacamole:
    image: guacamole/guacamole:${GUAC_VERSION}
    container_name: guac-web
    restart: unless-stopped
    depends_on:
      postgres: { condition: service_healthy }
      guacd: { condition: service_started }
    environment:
      GUACD_HOSTNAME: guacd
      GUACD_PORT: "4822"
      POSTGRESQL_HOSTNAME: postgres
      POSTGRESQL_PORT: "5432"
      POSTGRESQL_DATABASE: ${POSTGRES_DB}
      POSTGRESQL_USERNAME: ${POSTGRES_USER}
      POSTGRESQL_PASSWORD: ${POSTGRES_PASSWORD}
      WEBAPP_CONTEXT: ROOT
      TOTP_ENABLED: "true"
      TOTP_ISSUER: "Guacamole"
    ports:
      - "${GUACAMOLE_HTTP_BIND}:${GUACAMOLE_HTTP_PORT}:8080"
    networks: [guac-net]

networks:
  guac-net: { driver: bridge }
volumes:
  guac-postgres-data:
EOF
  chown "$APP_USER:$APP_GROUP" "$GUAC_BASE/docker-compose.yml"
  chmod 640 "$GUAC_BASE/docker-compose.yml"

  chmod 755 "$GUAC_BASE/init"
  if [[ ! -s "$GUAC_BASE/init/001-initdb.sql" ]]; then
    docker pull "guacamole/guacamole:$GUAC_VERSION"
    docker run --rm "guacamole/guacamole:$GUAC_VERSION" /opt/guacamole/bin/initdb.sh --postgresql > "$GUAC_BASE/init/001-initdb.sql"
    chown "$APP_USER:$APP_GROUP" "$GUAC_BASE/init/001-initdb.sql"
    chmod 644 "$GUAC_BASE/init/001-initdb.sql"
  fi

  cat > "$GUAC_BASE/backup-guacamole.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
BASE="$GUAC_BASE"
cd "\$BASE"
set -a; source "\$BASE/.env"; set +a
mkdir -p "\$BASE/backups"
OUT="\$BASE/backups/guacamole_\$(date +%Y%m%d-%H%M%S).sql.gz"
docker compose exec -T postgres pg_dump -U "\$POSTGRES_USER" "\$POSTGRES_DB" | gzip -9 > "\$OUT"
chmod 600 "\$OUT"
echo "\$OUT"
EOF
  chown "$APP_USER:$APP_GROUP" "$GUAC_BASE/backup-guacamole.sh"
  chmod 750 "$GUAC_BASE/backup-guacamole.sh"

  (cd "$GUAC_BASE" && docker compose pull && docker compose up -d)
}

patch_gateway(){
  log "Detecting Guacamole Docker gateway"
  local gateway
  gateway="$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET_NAME")"
  python3 - "$GUAC_BASE/docker-compose.yml" "$gateway" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
gw = sys.argv[2]
text = path.read_text()
text = re.sub(r'host\.docker\.internal:[^"\n]+', f'host.docker.internal:{gw}', text)
if 'host.docker.internal:' not in text:
    text = text.replace('''    environment:\n      LOG_LEVEL: debug\n    networks: [guac-net]\n''', f'''    environment:\n      LOG_LEVEL: debug\n    extra_hosts:\n      - "host.docker.internal:{gw}"\n    networks: [guac-net]\n''')
    text = text.replace('''    ports:\n      - "${GUACAMOLE_HTTP_BIND}:${GUACAMOLE_HTTP_PORT}:8080"\n    networks: [guac-net]\n''', f'''    ports:\n      - "${{GUACAMOLE_HTTP_BIND}}:${{GUACAMOLE_HTTP_PORT}}:8080"\n    extra_hosts:\n      - "host.docker.internal:{gw}"\n    networks: [guac-net]\n''')
path.write_text(text)
PY
  (cd "$GUAC_BASE" && docker compose up -d --force-recreate guacd guacamole)
  printf '%s\n' "$gateway"
}

setup_key(){
  log "Creating RSA PEM key for Guacamole SSH"
  install -d -m 700 -o "$APP_USER" -g "$APP_GROUP" "$APP_HOME/.ssh"
  if [[ ! -f "$APP_HOME/.ssh/guacamole_rsa" ]]; then
    sudo -u "$APP_USER" ssh-keygen -t rsa -b 4096 -m PEM -N "" -C "guacamole-rsa-$(hostname)" -f "$APP_HOME/.ssh/guacamole_rsa" >/dev/null
  fi
  chmod 600 "$APP_HOME/.ssh/guacamole_rsa"
  chmod 644 "$APP_HOME/.ssh/guacamole_rsa.pub"
  touch "$APP_HOME/.ssh/authorized_keys"
  chown "$APP_USER:$APP_GROUP" "$APP_HOME/.ssh/authorized_keys"
  chmod 600 "$APP_HOME/.ssh/authorized_keys"
  local pub
  pub="$(cat "$APP_HOME/.ssh/guacamole_rsa.pub")"
  grep -Fq "$pub" "$APP_HOME/.ssh/authorized_keys" || printf 'no-port-forwarding,no-X11-forwarding,no-agent-forwarding %s\n' "$pub" >> "$APP_HOME/.ssh/authorized_keys"
}

setup_compat_sshd(){
  local gw="$1"
  local conf=/etc/ssh/sshd_config_guacamole
  local svc=/etc/systemd/system/sshd-guacamole.service
  log "Configuring Docker-gateway-only SSHD on $gw:$GUAC_SSH_PORT"
  ssh-keygen -A >/dev/null
  backup "$conf"
  cat > "$conf" <<EOF
Port $GUAC_SSH_PORT
ListenAddress $gw
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
PermitRootLogin no
AllowUsers $APP_USER
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
HostKeyAlgorithms ssh-rsa
PubkeyAcceptedAlgorithms +ssh-rsa,rsa-sha2-512,rsa-sha2-256
KexAlgorithms diffie-hellman-group14-sha1,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512
Ciphers aes128-ctr,aes192-ctr,aes256-ctr
MACs hmac-sha1,hmac-sha2-256,hmac-sha2-512
AuthorizedKeysFile .ssh/authorized_keys
LogLevel VERBOSE
Subsystem sftp internal-sftp
EOF
  /usr/sbin/sshd -t -f "$conf"
  backup "$svc"
  cat > "$svc" <<EOF
[Unit]
Description=OpenSSH server for Apache Guacamole compatibility
After=network.target docker.service
Wants=docker.service
[Service]
ExecStart=/usr/sbin/sshd -D -f $conf -E /var/log/sshd-guacamole.log
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sshd-guacamole.service
}

allow_bridge_port(){
  local port="$1" name="$2" drop_others="${3:-0}" gw subnet bridge helper svc
  gw="$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET_NAME")"
  subnet="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$NET_NAME")"
  bridge="$(ip -o route show "$subnet" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
  log "Allowing Guacamole Docker bridge $bridge/$subnet -> $gw:$port"
  iptables -C INPUT -i "$bridge" -s "$subnet" -d "$gw" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i "$bridge" -s "$subnet" -d "$gw" -p tcp --dport "$port" -j ACCEPT
  if [[ "$drop_others" == "1" ]]; then
    iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport "$port" -j DROP
  fi
  helper="/usr/local/sbin/apache-guacamole-${name}-bridge-firewall.sh"
  svc="/etc/systemd/system/apache-guacamole-${name}-bridge-firewall.service"
  cat > "$helper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
NET="$NET_NAME"; PORT="$port"; DROP="$drop_others"
GW="\$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "\$NET")"
SUB="\$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "\$NET")"
BR="\$(ip -o route show "\$SUB" | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1)}' | head -1)"
iptables -C INPUT -i "\$BR" -s "\$SUB" -d "\$GW" -p tcp --dport "\$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i "\$BR" -s "\$SUB" -d "\$GW" -p tcp --dport "\$PORT" -j ACCEPT
[[ "\$DROP" == 1 ]] && { iptables -C INPUT -p tcp --dport "\$PORT" -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport "\$PORT" -j DROP; }
EOF
  chmod 755 "$helper"
  cat > "$svc" <<EOF
[Unit]
Description=Allow Guacamole Docker bridge to reach host $name port
After=docker.service
Wants=docker.service
[Service]
Type=oneshot
ExecStart=$helper
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$(basename "$svc")"
}

setup_krdp_if_available(){
  [[ "$ENABLE_KRDP" != "0" ]] || return 0
  if ! has krdpserver; then
    echo "WARN: krdpserver not available; skipping KRdp. See docs/distro-support.md for desktop alternatives." >&2
    return 0
  fi
  log "Configuring optional KRdp on port $KRDP_PORT"
  local dir env certdir svcdir usersvc
  dir="$APP_HOME/.config/guacamole-krdp"
  env="$dir/rdp.env"
  certdir="$dir/certs"
  svcdir="$APP_HOME/.config/systemd/user"
  usersvc="$svcdir/guacamole-krdp.service"
  install -d -m 700 -o "$APP_USER" -g "$APP_GROUP" "$dir" "$certdir" "$svcdir"
  if [[ ! -f "$env" ]]; then
    cat > "$env" <<EOF
KRDP_USER=$KRDP_USER
KRDP_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
KRDP_PORT=$KRDP_PORT
EOF
    chown "$APP_USER:$APP_GROUP" "$env"; chmod 600 "$env"
  fi
  # shellcheck disable=SC1090
  source "$env"
  if [[ ! -f "$certdir/krdp.key" ]]; then
    sudo -u "$APP_USER" openssl req -nodes -new -x509 -keyout "$certdir/krdp.key" -out "$certdir/krdp.crt" -days 365 -subj "/CN=$(hostname)-krdp" >/dev/null 2>&1
  fi
  chown -R "$APP_USER:$APP_GROUP" "$dir"
  chmod 600 "$certdir/krdp.key" 2>/dev/null || true
  cat > "$usersvc" <<EOF
[Unit]
Description=KRdp server for Apache Guacamole
After=graphical-session.target plasma-workspace.target
PartOf=graphical-session.target
[Service]
Type=simple
EnvironmentFile=$env
ExecStart=$(command -v krdpserver) -u \${KRDP_USER} -p \${KRDP_PASSWORD} --port \${KRDP_PORT} --certificate $certdir/krdp.crt --certificate-key $certdir/krdp.key --quality 80
Restart=on-failure
RestartSec=3
[Install]
WantedBy=default.target
EOF
  chown "$APP_USER:$APP_GROUP" "$usersvc"; chmod 600 "$usersvc"
  sudo -u "$APP_USER" XDG_RUNTIME_DIR="/run/user/$APP_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$APP_UID/bus" systemctl --user daemon-reload || true
  sudo -u "$APP_USER" XDG_RUNTIME_DIR="/run/user/$APP_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$APP_UID/bus" systemctl --user enable --now guacamole-krdp.service || true
  allow_bridge_port "$KRDP_PORT" krdp 1
}

psql_exec(){
  cd "$GUAC_BASE"
  set -a
  # shellcheck disable=SC1091
  source "$GUAC_BASE/.env"
  set +a
  docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" guac-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1
}

upsert_connections(){
  local gw="$1" key
  log "Creating/updating Guacamole connections"
  key="$(cat "$APP_HOME/.ssh/guacamole_rsa")"
  psql_exec <<SQL
DO \$\$
DECLARE cid integer;
BEGIN
 SELECT connection_id INTO cid FROM guacamole_connection WHERE connection_name='Host SSH';
 IF cid IS NULL THEN INSERT INTO guacamole_connection (connection_name, protocol) VALUES ('Host SSH','ssh') RETURNING connection_id INTO cid; ELSE UPDATE guacamole_connection SET protocol='ssh' WHERE connection_id=cid; DELETE FROM guacamole_connection_parameter WHERE connection_id=cid; END IF;
 INSERT INTO guacamole_connection_parameter VALUES
  (cid,'hostname','$gw'),(cid,'port','$GUAC_SSH_PORT'),(cid,'username','$APP_USER'),(cid,'private-key',\$KEY\$$key\$KEY\$);
END \$\$;
SQL
  if [[ -f "$APP_HOME/.config/guacamole-krdp/rdp.env" ]] && has krdpserver; then
    # shellcheck disable=SC1091
    source "$APP_HOME/.config/guacamole-krdp/rdp.env"
    psql_exec <<SQL
DO \$\$
DECLARE cid integer;
BEGIN
 SELECT connection_id INTO cid FROM guacamole_connection WHERE connection_name='KDE Desktop';
 IF cid IS NULL THEN INSERT INTO guacamole_connection (connection_name, protocol) VALUES ('KDE Desktop','rdp') RETURNING connection_id INTO cid; ELSE UPDATE guacamole_connection SET protocol='rdp' WHERE connection_id=cid; DELETE FROM guacamole_connection_parameter WHERE connection_id=cid; END IF;
 INSERT INTO guacamole_connection_parameter VALUES
  (cid,'hostname','$gw'),(cid,'port','$KRDP_PORT'),(cid,'username','$KRDP_USER'),(cid,'password','$KRDP_PASSWORD'),(cid,'security','any'),(cid,'ignore-cert','true'),(cid,'resize-method','display-update'),(cid,'color-depth','24');
END \$\$;
SQL
  fi
}

verify(){
  local gw="$1"
  log "Verification"
  (cd "$GUAC_BASE" && docker compose ps)
  curl -fsSI "http://127.0.0.1:$GUAC_HTTP_PORT" | head -8 || true
  docker run --rm --network "$NET_NAME" alpine:3.20 sh -lc "apk add --no-cache netcat-openbsd openssh-client >/dev/null; nc -vz -w 5 $gw $GUAC_SSH_PORT; ssh-keyscan -T 5 -p $GUAC_SSH_PORT $gw 2>&1 | head -3" || true
  if has krdpserver; then
    docker run --rm --network "$NET_NAME" alpine:3.20 sh -lc "apk add --no-cache netcat-openbsd >/dev/null; nc -vz -w 5 $gw $KRDP_PORT" || true
  fi
}

install_packages
ensure_docker
write_stack
GATEWAY="$(patch_gateway | tail -1)"
setup_key
setup_compat_sshd "$GATEWAY"
allow_bridge_port "$GUAC_SSH_PORT" ssh 0
setup_krdp_if_available
upsert_connections "$GATEWAY"
verify "$GATEWAY"

cat <<EOF

DONE.
Open Guacamole locally: http://127.0.0.1:$GUAC_HTTP_PORT
Initial login: guacadmin / guacadmin
Harden immediately: change password, create a non-default admin, enroll TOTP, test backups.
Optional Tailscale Serve: tailscale serve --bg $GUAC_HTTP_PORT
EOF
