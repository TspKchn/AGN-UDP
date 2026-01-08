#!/usr/bin/env bash
set -e

############################################
# AGN-UDP / Hysteria v1
# FINAL INSTALLER (NGINX SAFE)
############################################

### BASIC CONFIG
UDP_PORT="36712"
OBFS="agnudp"
DEFAULT_DAYS=30

HYSTERIA_BIN="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
DB_FILE="$CONFIG_DIR/users.db"
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"

BACKUP_DIR="/backup"
BACKUP_FILE="$BACKUP_DIR/agnudp-backup.7z"

############################################
# ROOT CHECK
############################################
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root"
  exit 1
fi

############################################
# DOMAIN (CERT CN ONLY)
############################################
echo
read -p "Enter domain name (for certificate CN, any name ok): " DOMAIN
DOMAIN=${DOMAIN:-agnudp.local}
echo "[✓] Certificate CN: $DOMAIN"
echo

############################################
# DEPENDENCIES
############################################
apt update
apt install -y curl jq sqlite3 openssl p7zip-full nginx

############################################
# NGINX SAFE SETUP
############################################

# Unmask nginx (fix masked service)
systemctl unmask nginx 2>/dev/null || true
rm -f /etc/systemd/system/nginx.service 2>/dev/null || true
systemctl daemon-reload

# Detect web port (80 -> 8080)
if ss -tulpn | grep -q ':80 '; then
  WEB_PORT=8080
else
  WEB_PORT=80
fi
echo "[✓] Web server port: $WEB_PORT"

# Prepare backup dir
mkdir -p "$BACKUP_DIR"

# Minimal nginx config (no conflict with xray)
rm -f /etc/nginx/sites-enabled/*
rm -f /etc/nginx/conf.d/*

cat > /etc/nginx/nginx.conf <<EOF
worker_processes auto;
events { worker_connections 1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    server {
        listen ${WEB_PORT};
        server_name _;
        root ${BACKUP_DIR};
        autoindex on;
    }
}
EOF

systemctl restart nginx
systemctl enable nginx

############################################
# INSTALL HYSTERIA
############################################
if [[ ! -f "$HYSTERIA_BIN" ]]; then
  curl -L -o /tmp/hysteria \
    https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64
  chmod +x /tmp/hysteria
  mv /tmp/hysteria "$HYSTERIA_BIN"
fi

mkdir -p "$CONFIG_DIR"

############################################
# SELF-SIGNED CERT
############################################
if [[ ! -f "$CONFIG_DIR/server.key" ]]; then
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$CONFIG_DIR/server.key" \
    -subj "/CN=$DOMAIN" \
    -out "$CONFIG_DIR/server.csr"

  openssl x509 -req -days 3650 \
    -in "$CONFIG_DIR/server.csr" \
    -signkey "$CONFIG_DIR/server.key" \
    -out "$CONFIG_DIR/server.crt"

  rm -f "$CONFIG_DIR/server.csr"
fi

############################################
# SQLITE DB
############################################
if [[ ! -f "$DB_FILE" ]]; then
sqlite3 "$DB_FILE" <<EOF
CREATE TABLE users (
  username TEXT PRIMARY KEY,
  password TEXT NOT NULL,
  expire DATE NOT NULL
);
EOF
fi

############################################
# HYSTERIA CONFIG
############################################
cat > "$CONFIG_FILE" <<EOF
{
  "listen": ":${UDP_PORT}",
  "protocol": "udp",
  "cert": "${CONFIG_DIR}/server.crt",
  "key": "${CONFIG_DIR}/server.key",
  "up_mbps": 100,
  "down_mbps": 100,
  "obfs": "${OBFS}",
  "auth": {
    "mode": "passwords",
    "config": []
  }
}
EOF

############################################
# SYSTEMD SERVICE
############################################
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AGN-UDP (Hysteria v1)
After=network.target

[Service]
ExecStart=${HYSTERIA_BIN} server --config ${CONFIG_FILE}
Restart=always
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

############################################
# MANAGER SCRIPT (FULL)
############################################
cat > /usr/local/bin/agnudp <<'EOF'
#!/usr/bin/env bash

DB="/etc/hysteria/users.db"
CFG="/etc/hysteria/config.json"
SERVICE="hysteria-server"
BACKUP_DIR="/backup"
BACKUP_FILE="$BACKUP_DIR/agnudp-backup.7z"
DEFAULT_DAYS=30

update_config() {
  users=$(sqlite3 "$DB" "SELECT username||':'||password FROM users WHERE date(expire)>=date('now');")
  jq ".auth.config = $(printf '%s\n' "$users" | jq -R . | jq -s .)" \
    "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  systemctl restart "$SERVICE"
}

add_user() {
  read -p "Username: " u
  read -p "Password: " p
  read -p "Days [$DEFAULT_DAYS]: " d
  d=${d:-$DEFAULT_DAYS}
  exp=$(date -d "+$d days" +%F)
  sqlite3 "$DB" "INSERT OR REPLACE INTO users VALUES('$u','$p','$exp');"
  update_config
  echo "User added"
}

extend_user() {
  read -p "Username: " u
  read -p "Add days: " d
  cur=$(sqlite3 "$DB" "SELECT expire FROM users WHERE username='$u';")
  [[ -z "$cur" ]] && echo "User not found" && return
  new=$(date -d "$cur +$d days" +%F)
  sqlite3 "$DB" "UPDATE users SET expire='$new' WHERE username='$u';"
  update_config
  echo "User extended"
}

delete_user() {
  read -p "Username to delete: " u
  exists=$(sqlite3 "$DB" "SELECT username FROM users WHERE username='$u';")
  [[ -z "$exists" ]] && echo "User not found" && return
  read -p "Confirm delete user '$u'? [y/N]: " c
  [[ "$c" != "y" && "$c" != "Y" ]] && return
  sqlite3 "$DB" "DELETE FROM users WHERE username='$u';"
  update_config
  echo "User deleted"
}

list_user() {
  echo "USERNAME | EXPIRE"
  echo "------------------"
  sqlite3 "$DB" "SELECT username,expire FROM users;"
}

cleanup_expired() {
  sqlite3 "$DB" "DELETE FROM users WHERE date(expire)<date('now');"
  update_config
  echo "Expired users cleaned"
}

backup() {
  read -p "Backup password (visible): " p
  mkdir -p "$BACKUP_DIR"
  rm -f "$BACKUP_FILE"
  7z a -t7z -p"$p" -mhe=on "$BACKUP_FILE" "$DB" >/dev/null \
    && echo "Backup saved at $BACKUP_FILE" \
    || echo "Backup failed"
}

restore() {
  read -p "Backup Server IP: " IP
  read -p "Backup password (visible): " p

  TMP="/tmp/agnudp-restore"
  rm -rf "$TMP" && mkdir -p "$TMP"

  curl -f -o "$TMP/agnudp-backup.7z" "http://$IP/agnudp-backup.7z" \
  || curl -f -o "$TMP/agnudp-backup.7z" "http://$IP:8080/agnudp-backup.7z" \
  || { echo "Download failed"; return; }

  7z x -p"$p" "$TMP/agnudp-backup.7z" -o"$TMP" >/dev/null \
  || { echo "Wrong password or corrupted file"; return; }

  cp "$TMP/users.db" "$DB"
  update_config
  rm -rf "$TMP"
  echo "Restore completed"
}

uninstall() {
  read -p "Confirm uninstall AGN-UDP? [y/N]: " c
  [[ "$c" != "y" && "$c" != "Y" ]] && return
  systemctl stop "$SERVICE"
  systemctl disable "$SERVICE"
  rm -f /etc/systemd/system/hysteria-server.service
  systemctl daemon-reload
  rm -rf /etc/hysteria
  rm -f /usr/local/bin/agnudp
  rm -f /usr/local/bin/hysteria
  echo "AGN-UDP removed"
  exit 0
}

while true; do
  echo "====== AGN-UDP Manager ======"
  echo "1) Add user"
  echo "2) Extend user"
  echo "3) Delete user"
  echo "4) List users"
  echo "5) Cleanup expired users"
  echo "6) Backup"
  echo "7) Restore"
  echo "8) Uninstall AGN-UDP"
  echo "0) Exit"
  read -p "> " c
  case $c in
    1) add_user ;;
    2) extend_user ;;
    3) delete_user ;;
    4) list_user ;;
    5) cleanup_expired ;;
    6) backup ;;
    7) restore ;;
    8) uninstall ;;
    0) exit ;;
  esac
done
EOF

chmod +x /usr/local/bin/agnudp

############################################
# DONE
############################################
echo
echo "[✓] AGN-UDP installed successfully"
echo "[✓] Web server running on port: $WEB_PORT"
echo "[✓] Backup URL example:"
echo "    http://SERVER_IP:${WEB_PORT}/agnudp-backup.7z"
echo "[✓] Run manager: agnudp"
