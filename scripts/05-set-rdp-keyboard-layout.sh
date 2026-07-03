#!/usr/bin/env bash
set -euo pipefail

# Set the server-side keyboard layout used by Apache Guacamole's RDP protocol.
#
# Why this exists:
# Guacamole itself is browser-layout-independent, but RDP is not. If the
# Guacamole RDP connection lacks the `server-layout` parameter, guacd defaults
# to US English QWERTY, which makes German/Swiss keyboards appear wrong
# (z/y swapped, broken AltGr/special characters, etc.).
#
# Usage:
#   sudo bash scripts/05-set-rdp-keyboard-layout.sh de-de-qwertz
#   sudo bash scripts/05-set-rdp-keyboard-layout.sh de-ch-qwertz
#   sudo bash scripts/05-set-rdp-keyboard-layout.sh failsafe
#
# Optional environment:
#   GUACAMOLE_BASE=/opt/guacamole   # compose/.env directory
#   NO_RESTART=1                    # skip guacd/guacamole restart

LAYOUT="${1:-de-de-qwertz}"
case "$LAYOUT" in
  de-de-qwertz|de-ch-qwertz|fr-ch-qwertz|failsafe) ;;
  *)
    echo "Unsupported layout: $LAYOUT" >&2
    echo "Use one of: de-de-qwertz, de-ch-qwertz, fr-ch-qwertz, failsafe" >&2
    exit 2
    ;;
esac

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with: sudo bash $0 $LAYOUT" >&2
  exit 1
fi

BASE="${GUACAMOLE_BASE:-/opt/guacamole}"
if [[ ! -f "$BASE/.env" ]]; then
  echo "Missing $BASE/.env" >&2
  exit 1
fi

cd "$BASE"
set -a
# shellcheck disable=SC1091
source "$BASE/.env"
set +a

if ! docker ps --format '{{.Names}}' | grep -qx guac-postgres; then
  echo "Container guac-postgres is not running" >&2
  exit 1
fi

echo "Setting Guacamole RDP server-layout to: $LAYOUT"

docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" guac-postgres \
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<SQL
WITH target AS (
  SELECT connection_id
  FROM guacamole_connection
  WHERE protocol = 'rdp'
)
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT connection_id, 'server-layout', '$LAYOUT'
FROM target
ON CONFLICT (connection_id, parameter_name)
DO UPDATE SET parameter_value = EXCLUDED.parameter_value;
SQL

echo "=== Guacamole RDP keyboard layout parameters ==="
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" guac-postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -P pager=off -c "
SELECT c.connection_name, c.protocol, p.parameter_name, p.parameter_value
FROM guacamole_connection c
JOIN guacamole_connection_parameter p ON p.connection_id = c.connection_id
WHERE c.protocol = 'rdp'
  AND p.parameter_name = 'server-layout'
ORDER BY c.connection_name;
"

if [[ "${NO_RESTART:-0}" != "1" ]]; then
  echo "=== Restarting Guacamole services so cached sessions/config are dropped ==="
  docker restart guac-guacd guac-web >/dev/null
else
  echo "NO_RESTART=1 set; skipping container restart."
fi

cat <<EOF

Done.

Next steps:
1. Fully disconnect the active Guacamole RDP session.
2. Reload the browser page.
3. Reconnect to the desktop.
4. Test: z/y, ä/ö/ü, @, €, \\, |, { }, [ ].

If AltGr/special keys still fail, try:
  sudo bash $0 failsafe
EOF
