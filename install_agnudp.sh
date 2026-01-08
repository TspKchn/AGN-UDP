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

### ================= WEB SERVER CHECK (NO FORCE NGINX) =================
WEB_ROOT=""
WEB_MODE="none"

if command -v nginx >/dev/null 2>&1 || command -v apache2 >/dev/null 2>&1; then
  WEB_ROOT="/var/www/html"
  WEB_MODE="http"
  echo "[✓] Web server detected (HTTP backup enabled)"
else
  echo "[!] No web server detected"
  echo "[!] HTTP backup disabled (use SCP or python http.server)"
fi

### ================= BACKUP DIR (ONLY IF WEB EXISTS) =================
if [[ "$WEB_MODE" == "http" ]]; then
  mkdir -p "$WEB_ROOT/backup"
  chown -R www-data:www-data "$WEB_ROOT/backup" 2>/dev/null || true
  chmod 755 "$WEB_ROOT/backup"
fi

### ================= CERT MODE =================
echo
echo "Select certificate mode:"
echo "1) IP (self-signed)"
echo "2) Domain (Let's Encrypt, requires existing web server)"
read -p "Choose [1-2]: " CERT_MODE

CERT_PATH_CERT=""
CERT_PATH_KEY=""

if [[ "$CERT_MODE" == "2" ]]; then
  if [[ "$WEB_MODE" != "http" ]]; then
    echo "[!] Domain mode requires an existing web server"
    exit 1
  fi

  read -p "Enter domain: " DOMAIN
  apt install -y certbot

  SERVER_IP=$(curl -s https://api.ipify.org || true)
  DOMAIN_IP=$(getent ahosts "$DOMAIN" | awk '{print $1; exit}')
  if [[ -n "$SERVER_IP" && -n "$DOMAIN_IP" && "$SERVER_IP" != "$DOMAIN_IP" ]]; then
    echo "[!] DNS mismatch, abort"
    exit 1
  fi

  certbot certonly --webroot \
    -w "$WEB_ROOT" \
    -d "$DOMAIN" \
    --agree-tos \
    --email "admin@$DOMAIN" \
    --non-interactive

  CERT_PATH_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  CERT_PATH_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
else
  mkdir -p "$CONFIG_DIR"
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$CONFIG_DIR/hysteria.server.key" \
    -out "$CONFIG_DIR/hysteria.server.crt" \
    -subj "/CN=agnudp"

  CERT_PATH_CERT="$CONFIG_DIR/hysteria.server.crt"
  CERT_PATH_KEY="$CONFIG_DIR/hysteria.server.key"
fi

### ================= DOWNLOAD HYSTERIA =================
if [[ ! -f "$HYSTERIA_BIN" ]]; then
  curl -L -o "$HYSTERIA_BIN" \
    https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64
  chmod +x "$HYSTERIA_BIN"
fi

### ================= SQLITE =================
mkdir -p "$CONFIG_DIR"
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
WorkingDirectory=${CONFIG_DIR}
ExecStart=${HYSTERIA_BIN} server --config ${CONFIG_FILE}
Restart=always
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server

### ================= FIREWALL (OPTIONAL) =================
iptables -C INPUT -p udp --dport ${UDP_PORT} -j ACCEPT 2>/dev/null \
|| iptables -A INPUT -p udp --dport ${UDP_PORT} -j ACCEPT

### ================= MANAGER =================
cat > /usr/local/bin/agnudp <<'EOF'
#!/usr/bin/env bash

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
DB="$CONFIG_DIR/udpusers.db"
DEFAULT_DAYS=30
BACKUP_NAME="agnudp-backup.7z"

update_config() {
  users=$(sqlite3 "$DB" "SELECT username||':'||password FROM users WHERE date(expire_date)>=date('now');")
  json=$(printf '%s\n' "$users" | jq -R . | jq -s .)
  jq ".auth.config = $json" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

if [[ "$1" == "cleanup_expired" ]]; then
  sqlite3 "$DB" "DELETE FROM users WHERE date(expire_date)<date('now');"
  update_config
  exit 0
fi

backup() {
  read -s -p "Encrypt password: " PASS; echo
  7z a -t7z -p"$PASS" -mhe=on "/tmp/$BACKUP_NAME" "$DB"
  echo "[✓] Backup created: /tmp/$BACKUP_NAME"
  echo "Use scp or python3 -m http.server to transfer"
}

restore() {
  read -p "Path to backup file: " FILE
  read -s -p "Password: " PASS; echo
  7z x -p"$PASS" "$FILE" -o"$CONFIG_DIR"
  update_config
  systemctl restart hysteria-server
}

while true; do
  echo "1) Add user"
  echo "2) List users"
  echo "3) Backup"
  echo "4) Restore"
  echo "0) Exit"
  read -p "Select: " c
  case $c in
    1)
      read -p "Username: " u
      read -p "Password: " p
      read -p "Days: " d
      d=${d:-$DEFAULT_DAYS}
      exp=$(date -d "+$d days" +%F)
      sqlite3 "$DB" "INSERT OR REPLACE INTO users VALUES('$u','$p','$exp');"
      update_config
      systemctl restart hysteria-server
      ;;
    2) sqlite3 "$DB" "SELECT username,expire_date FROM users;" ;;
    3) backup ;;
    4) restore ;;
    0) exit ;;
  esac
done
EOF

chmod +x /usr/local/bin/agnudp

### ================= CRON =================
echo "0 1 * * * root /usr/local/bin/agnudp cleanup_expired" > /etc/cron.d/agnudp

### ================= START =================
systemctl start hysteria-server

echo
echo "[✓] AGN-UDP installer completed"
echo "[✓] Run: agnudp"
