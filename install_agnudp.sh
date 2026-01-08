#!/usr/bin/env bash
set -e

### ================= BASIC CONFIG =================
UDP_PORT="36712"
DEFAULT_DAYS=30

HYSTERIA_BIN="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
DB_FILE="$CONFIG_DIR/udpusers.db"
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"

BACKUP_NAME="agnudp-backup.7z"

### ================= ROOT CHECK =================
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root"
  exit 1
fi

### ================= DEPENDENCIES =================
apt update
apt install -y curl jq sqlite3 openssl iptables cron p7zip-full

### ================= WEB SERVER CHECK =================
WEB_ROOT=""
if command -v nginx >/dev/null 2>&1; then
  WEB_ROOT="/var/www/html"
  echo "[✓] nginx detected"
elif command -v apache2 >/dev/null 2>&1; then
  WEB_ROOT="/var/www/html"
  echo "[✓] apache detected"
else
  echo "[+] No web server found, installing nginx"
  apt install -y nginx
  systemctl enable nginx
  systemctl start nginx
  WEB_ROOT="/var/www/html"
fi

### ================= BACKUP DIR =================
mkdir -p "$WEB_ROOT/backup"
chown -R www-data:www-data "$WEB_ROOT/backup" 2>/dev/null || true
chmod 755 "$WEB_ROOT/backup"

### ================= CERT MODE =================
echo
echo "Select certificate mode:"
echo "1) IP (self-signed, no domain needed)"
echo "2) Domain (Let's Encrypt)"
read -p "Choose [1-2]: " CERT_MODE

USE_LE=false
DOMAIN=""
CERT_PATH_CERT=""
CERT_PATH_KEY=""

if [[ "$CERT_MODE" == "2" ]]; then
  read -p "Enter domain (e.g. agnudp.example.com): " DOMAIN

  # Install certbot only if needed
  if ! command -v certbot >/dev/null 2>&1; then
    apt install -y certbot
  fi

  # DNS check (best-effort)
  SERVER_IP=$(curl -s https://api.ipify.org || true)
  DOMAIN_IP=$(getent ahosts "$DOMAIN" | awk '{print $1; exit}')
  if [[ -n "$SERVER_IP" && -n "$DOMAIN_IP" && "$SERVER_IP" != "$DOMAIN_IP" ]]; then
    echo "[!] DNS check failed: $DOMAIN resolves to $DOMAIN_IP but server IP is $SERVER_IP"
    echo "Fix DNS before continuing."
    exit 1
  fi

  EMAIL="admin@$DOMAIN"
  echo "[+] Requesting Let's Encrypt cert for $DOMAIN"
  certbot certonly --webroot \
    -w "$WEB_ROOT" \
    -d "$DOMAIN" \
    --agree-tos \
    --email "$EMAIL" \
    --non-interactive

  CERT_PATH_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  CERT_PATH_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

  if [[ ! -f "$CERT_PATH_CERT" || ! -f "$CERT_PATH_KEY" ]]; then
    echo "[!] Let's Encrypt failed"
    exit 1
  fi
else
  echo "[+] Using self-signed certificate (IP mode)"
  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$CONFIG_DIR/hysteria.server.key" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$CONFIG_DIR/hysteria.server.key" \
      -out "$CONFIG_DIR/hysteria.server.crt" \
      -subj "/CN=agnudp"
  fi
  CERT_PATH_CERT="$CONFIG_DIR/hysteria.server.crt"
  CERT_PATH_KEY="$CONFIG_DIR/hysteria.server.key"
fi

### ================= DOWNLOAD HYSTERIA =================
if [[ ! -f "$HYSTERIA_BIN" ]]; then
  echo "[+] Installing Hysteria v1.3.5"
  curl -L -o /tmp/hysteria \
    https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64
  chmod +x /tmp/hysteria
  mv /tmp/hysteria "$HYSTERIA_BIN"
fi

### ================= PREPARE DIR =================
mkdir -p "$CONFIG_DIR"

### ================= SQLITE =================
if [[ ! -f "$DB_FILE" ]]; then
sqlite3 "$DB_FILE" <<EOF
CREATE TABLE users (
  username TEXT PRIMARY KEY,
  password TEXT NOT NULL,
  expire_date TEXT NOT NULL
);
EOF
fi

### ================= CONFIG.JSON =================
cat > "$CONFIG_FILE" <<EOF
{
  "listen": ":${UDP_PORT}",
  "protocol": "udp",
  "cert": "${CERT_PATH_CERT}",
  "key": "${CERT_PATH_KEY}",
  "up_mbps": 100,
  "down_mbps": 100,
  "obfs": "agnudp",
  "auth": {
    "mode": "passwords",
    "config": []
  }
}
EOF

### ================= SYSTEMD =================
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria v1 UDP Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONFIG_DIR}
ExecStart=${HYSTERIA_BIN} server --config ${CONFIG_FILE}
Restart=always
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server.service

### ================= FIREWALL =================
iptables -C INPUT -p udp --dport ${UDP_PORT} -j ACCEPT 2>/dev/null \
|| iptables -A INPUT -p udp --dport ${UDP_PORT} -j ACCEPT

### ================= MANAGER =================
cat > /usr/local/bin/agnudp_manager.sh <<'EOF'
#!/usr/bin/env bash

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
DB="$CONFIG_DIR/udpusers.db"
DEFAULT_DAYS=30
BACKUP_NAME="agnudp-backup.7z"
TMP="/tmp/agnudp-restore"

update_config() {
  users=$(sqlite3 "$DB" "SELECT username||':'||password FROM users WHERE date(expire_date)>=date('now');")
  json=$(printf '%s\n' "$users" | jq -R . | jq -s .)
  jq ".auth.config = $json" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

add_user() {
  read -p "Username: " u
  read -p "Password: " p
  read -p "Days (default 30): " d
  d=${d:-$DEFAULT_DAYS}
  expire=$(date -d "+$d days" +%F)
  sqlite3 "$DB" "INSERT OR REPLACE INTO users VALUES('$u','$p','$expire');"
  update_config
  systemctl restart hysteria-server
}

extend_user() {
  read -p "Username: " u
  read -p "Add days: " d
  cur=$(sqlite3 "$DB" "SELECT expire_date FROM users WHERE username='$u';")
  [[ -z "$cur" ]] && echo "User not found" && return
  new=$(date -d "$cur +$d days" +%F)
  sqlite3 "$DB" "UPDATE users SET expire_date='$new' WHERE username='$u';"
  update_config
  systemctl restart hysteria-server
}

list_user() {
  sqlite3 "$DB" "SELECT username,expire_date FROM users;"
}

cleanup_expired() {
  sqlite3 "$DB" "DELETE FROM users WHERE date(expire_date)<date('now');"
  update_config
}

backup_restore_menu() {
  while true; do
    echo "=== Backup & Restore ==="
    echo "1) Backup"
    echo "2) Restore"
    echo "0) Back"
    read -p "Select: " c
    case $c in
      1) backup ;;
      2) restore ;;
      0) break ;;
    esac
  done
}

backup() {
  read -p "Backup Server IP: " IP
  read -s -p "Password: " PASS; echo
  7z a -t7z -p"$PASS" -mhe=on "/tmp/$BACKUP_NAME" "$DB" >/dev/null
  curl -f -T "/tmp/$BACKUP_NAME" "http://$IP/backup/$BACKUP_NAME" \
    && echo "Backup success"
}

restore() {
  read -p "Backup Server IP: " IP
  read -s -p "Password: " PASS; echo
  rm -rf "$TMP" && mkdir -p "$TMP"
  curl -f -o "$TMP/$BACKUP_NAME" "http://$IP/backup/$BACKUP_NAME" || return
  7z x -p"$PASS" "$TMP/$BACKUP_NAME" -o"$TMP" >/dev/null || return
  cp "$TMP/udpusers.db" "$DB"
  update_config
  systemctl restart hysteria-server
  rm -rf "$TMP"
  echo "Restore completed"
}

uninstall_all() {
  systemctl stop hysteria-server 2>/dev/null
  systemctl disable hysteria-server 2>/dev/null
  rm -f /etc/systemd/system/hysteria-server.service
  systemctl daemon-reload
  rm -rf /etc/hysteria
  rm -f /usr/local/bin/hysteria /usr/local/bin/agnudp /usr/local/bin/agnudp_manager.sh
  iptables -D INPUT -p udp --dport 36712 -j ACCEPT 2>/dev/null
  echo "AGN-UDP removed (3x-ui untouched)"
  exit
}

while true; do
  echo "==== AGN-UDP Manager ===="
  echo "1) Add user"
  echo "2) Extend user"
  echo "3) List users"
  echo "4) Cleanup expired"
  echo "5) Backup & Restore"
  echo "6) Uninstall"
  echo "0) Exit"
  read -p "Select: " c
  case $c in
    1) add_user ;;
    2) extend_user ;;
    3) list_user ;;
    4) cleanup_expired ;;
    5) backup_restore_menu ;;
    6) uninstall_all ;;
    0) exit ;;
  esac
done
EOF

chmod +x /usr/local/bin/agnudp_manager.sh
cat > /usr/local/bin/agnudp <<'EOF'
#!/bin/bash
/usr/local/bin/agnudp_manager.sh
EOF
chmod +x /usr/local/bin/agnudp

### ================= CRON =================
echo "0 1 * * * root /usr/local/bin/agnudp_manager.sh cleanup_expired" > /etc/cron.d/agnudp

### ================= START =================
systemctl start hysteria-server.service

echo
echo "[✓] AGN-UDP FINAL++ installer completed"
echo "[✓] Run: agnudp"
