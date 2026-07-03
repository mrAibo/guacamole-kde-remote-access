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
APP_GROUP="$(id -gn "$APP_USER")"
BASE="/opt/guacamole"
TS="$(date +%Y%m%d-%H%M%S)"

backup_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    cp -a "$path" "${path}.bak.${TS}"
    echo "Backed up $path -> ${path}.bak.${TS}"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || missing+=("$1")
}

missing=()
for c in docker openssl curl bash systemctl; do require_cmd "$c"; done
if (( ${#missing[@]} > 0 )); then
  echo "Installing missing packages: ${missing[*]}"
  pacman -S --needed --noconfirm "${missing[@]}"
fi

systemctl enable --now docker
systemctl enable --now tailscaled || true

install -d -m 700 -o "$APP_USER" -g "$APP_GROUP" "$BASE" "$BASE/init" "$BASE/backups"

if [[ ! -f "$BASE/.env" ]]; then
  POSTGRES_PASSWORD="$(openssl rand -hex 32)"
  cat > "$BASE/.env" <<EOF
GUAC_VERSION=1.6.0
POSTGRES_VERSION=16-alpine
POSTGRES_DB=guacamole_db
POSTGRES_USER=guacamole_user
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
GUACAMOLE_HTTP_BIND=127.0.0.1
GUACAMOLE_HTTP_PORT=8080
EOF
  chown "$APP_USER:$APP_GROUP" "$BASE/.env"
  chmod 600 "$BASE/.env"
else
  echo "$BASE/.env exists; leaving unchanged"
fi

backup_if_exists "$BASE/docker-compose.yml"
cat > "$BASE/docker-compose.yml" <<'EOF'
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
    networks:
      - guac-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10

  guacd:
    image: guacamole/guacd:${GUAC_VERSION}
    container_name: guac-guacd
    restart: unless-stopped
    networks:
      - guac-net

  guacamole:
    image: guacamole/guacamole:${GUAC_VERSION}
    container_name: guac-web
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      guacd:
        condition: service_started
    environment:
      GUACD_HOSTNAME: guacd
      GUACD_PORT: "4822"
      POSTGRESQL_HOSTNAME: postgres
      POSTGRESQL_PORT: "5432"
      POSTGRESQL_DATABASE: ${POSTGRES_DB}
      POSTGRESQL_USER: ${POSTGRES_USER}
      POSTGRESQL_PASSWORD: ${POSTGRES_PASSWORD}
      WEBAPP_CONTEXT: ROOT
      TOTP_ENABLED: "true"
      TOTP_ISSUER: "Guacamole"
    ports:
      - "${GUACAMOLE_HTTP_BIND}:${GUACAMOLE_HTTP_PORT}:8080"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - guac-net

networks:
  guac-net:
    driver: bridge

volumes:
  guac-postgres-data:
EOF
chown "$APP_USER:$APP_GROUP" "$BASE/docker-compose.yml"
chmod 640 "$BASE/docker-compose.yml"

if [[ -s "$BASE/init/001-initdb.sql" ]]; then
  echo "Init SQL already exists; leaving unchanged"
else
  docker run --rm guacamole/guacamole:1.6.0 /opt/guacamole/bin/initdb.sh --postgresql > "$BASE/init/001-initdb.sql"
  chown "$APP_USER:$APP_GROUP" "$BASE/init/001-initdb.sql"
  chmod 640 "$BASE/init/001-initdb.sql"
fi

backup_if_exists "$BASE/backup-guacamole.sh"
cat > "$BASE/backup-guacamole.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BASE="/opt/guacamole"
cd "$BASE"
set -a
# shellcheck disable=SC1091
source "$BASE/.env"
set +a
mkdir -p "$BASE/backups"
DATE="$(date +%Y%m%d-%H%M%S)"
OUT="$BASE/backups/guacamole_${DATE}.sql.gz"
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip -9 > "$OUT"
chmod 600 "$OUT"
echo "$OUT"
EOF
chown "$APP_USER:$APP_GROUP" "$BASE/backup-guacamole.sh"
chmod 750 "$BASE/backup-guacamole.sh"

cd "$BASE"
docker compose pull
docker compose up -d

echo "=== docker compose ps ==="
docker compose ps

echo "=== local HTTP check ==="
for _ in {1..30}; do
  if curl -fsSI http://127.0.0.1:8080 >/dev/null; then
    curl -I http://127.0.0.1:8080 | head -5
    break
  fi
  sleep 2
done

echo "Setup done. Guacamole is bound to 127.0.0.1:8080 only."
