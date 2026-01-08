#!/usr/bin/env bash
set -e

####################################
# AGN-UDP / Hysteria v1 Installer
# Legacy-style DOMAIN (cert only)
# Clean / Stable / No-nginx / No-DNAT
####################################

### BASIC CONFIG
UDP_PORT="36712"
OBFS="agnudp"
DEFAULT_DAYS=30

HYSTERIA_BIN="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
DB_FILE="$CONFIG_DIR/users.db"
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"

### ROOT CHECK
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root"
  exit 1
fi

### ASK DOMAIN (LIKE OLD SCRIPT)
echo
read -p "Enter domain for certificate (any name is OK, no DNS required): " DOMAIN
DOMAIN=${DOMAIN:-agnudp.local}
echo "[✓] Certificate CN = $DOMAIN"
echo

### DEPENDENCIES
apt update
apt install -y curl jq sqlite3 openssl p7zip-full

### INSTALL HYSTERIA
if [[ ! -f "$HYSTERIA_BIN" ]]; then
  echo "[+] Installing Hysteria v1.3.5"
  curl -L -o /tmp/hysteria \
    https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64
  chmod +x /tmp/hysteria
  mv /tmp/hysteria "$HYSTERIA_BIN"
fi

### PREPARE DIR
mkdir -p "$CONFIG_DIR"

### SELF-SIGNED CERT (DOMAIN ONLY FOR CN/SAN)
if [[ ! -f "$CONFIG_DIR/server.key" ]]; then
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$CONFIG_DIR/server.key" \
    -subj "/CN=$DOMAIN" \
    -out "$CONFIG_DIR/server.csr"

  openssl x509 -req -days 3650 \
    -in "$CONFIG_DIR/server.csr" \
    -signkey "$CONFIG_DIR/server.key" \
    -extfile <(printf "subjectAltName=DNS:%s" "$DOMAIN") \
    -out "$CONFIG_DIR/server.crt"

  rm -f "$CONFIG_DIR/server.csr"
fi

### SQLITE DB
if [[ ! -f "$DB_FILE" ]]; then
sqlite3 "$DB_FILE" <<EOF
CREATE TABLE users (
  username TEXT PRIMARY KEY,
  password TEXT NOT NULL,
  expire DATE NOT NULL
);
EOF
fi

### CONFIG.JSON
cat > "$CONFIG_FILE" <<EOF
{
  "listen": ":$UDP_PORT",
  "protocol": "udp",
  "cert": "$CONFIG_DIR/server.crt",
  "key": "$CONFIG_DIR/server.key",
  "up_mbps": 100,
  "down_mbps": 100,
  "obfs": "$OBFS",
  "auth": {
    "mode": "passwords",
    "config": []
  }
}
EOF

### SYSTEMD SERVICE
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AGN-UDP (Hysteria v1)
After=network.target

[Service]
ExecStart=$HYSTERIA_BIN server --config $CONFIG_FILE
Restart=always
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

####################################
# AGN-UDP MANAGER (7 MENUS)
####################################

cat > /usr/local/bin/agnudp <<'EOF'
#!/usr/bin/env bash

DB="/etc/hysteria/users.db"
CFG="/etc/hysteria/config.json"
SERVICE="hysteria-server"
DEFAULT_DAYS=30
BACKUP="/tmp/agnudp-backup.7z"
TMP="/tmp/agnudp-restore"

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
}

extend_user() {
  read -p "Username: " u
  read -p "Add days: " d
  cur=$(sqlite3 "$DB" "SELECT expire FROM users WHERE username='$u';")
  [[ -z "$cur" ]] && echo "User not found" && return
  new=$(date -d "$cur +$d days" +%F)
  sqlite3 "$DB" "UPDATE users SET expire='$new' WHERE username='$u';"
  update_config
}

list_user() {
  sqlite3 "$DB" "SELECT username,expire FROM users;"
}

cleanup_expired() {
  sqlite3 "$DB" "DELETE FROM users WHERE date(expire)<date('now');"
  update_config
}

backup() {
  read -s -p "Backup password: " p; echo
  7z a -p"$p" -mhe=on "$BACKUP" "$DB" >/dev/null
  echo "Backup saved at $BACKUP"
}

restore() {
  read -p "Path to .7z file: " f
  read -s -p "Password: " p; echo
  rm -rf "$TMP"; mkdir -p "$TMP"
  7z x -p"$p" "$f" -o"$TMP" >/dev/null || return
  cp "$TMP/users.db" "$DB"
  update_config
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
  echo "3) List users"
  echo "4) Cleanup expired users"
  echo "5) Backup"
  echo "6) Restore"
  echo "7) Uninstall AGN-UDP"
  echo "0) Exit"
  read -p "> " c
  case $c in
    1) add_user ;;
    2) extend_user ;;
    3) list_user ;;
    4) cleanup_expired ;;
    5) backup ;;
    6) restore ;;
    7) uninstall ;;
    0) exit ;;
  esac
done
EOF

chmod +x /usr/local/bin/agnudp

echo
echo "[✓] AGN-UDP installed successfully"
echo "[✓] Certificate CN: $DOMAIN"
echo "[✓] Run command: agnudp"
