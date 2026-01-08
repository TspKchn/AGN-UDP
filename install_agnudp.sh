#!/usr/bin/env bash
set -e

############################################
# AGN-UDP / Hysteria v1 FINAL REAL
############################################

### BASIC CONFIG
UDP_PORT=36712
UDP_RANGE_START=10000
UDP_RANGE_END=50000
OBFS="agnudp"
DEFAULT_DAYS=30

HYSTERIA_BIN="/usr/local/bin/hysteria"
CONF_DIR="/etc/hysteria"
CONF_FILE="$CONF_DIR/config.json"
DB_FILE="$CONF_DIR/users.db"
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
# DEPENDENCIES
############################################
apt update
apt install -y curl jq sqlite3 openssl iptables iptables-persistent p7zip-full

############################################
# NETWORK INTERFACE
############################################
IFACE=$(ip route | awk '/default/ {print $5; exit}')
echo "[✓] Network interface: $IFACE"

############################################
# WEB SERVER DETECT
############################################
WEB_SERVER=""
WEB_PORT=""

if command -v nginx >/dev/null 2>&1; then
  WEB_SERVER="nginx"
elif command -v apache2 >/dev/null 2>&1; then
  WEB_SERVER="apache"
fi

# detect used port
if ss -tulpn | grep -q ':80 '; then
  USED_80=1
else
  USED_80=0
fi

if ss -tulpn | grep -q ':8080 '; then
  USED_8080=1
else
  USED_8080=0
fi

############################################
# WEB SERVER SETUP
############################################
mkdir -p "$BACKUP_DIR"

if [[ -n "$WEB_SERVER" ]]; then
  echo "[✓] Existing web server detected: $WEB_SERVER"

  if [[ "$WEB_SERVER" == "nginx" ]]; then
    # do not overwrite existing config
    if [[ ! -f /etc/nginx/conf.d/agnudp-backup.conf ]]; then
      WEB_PORT=$(ss -tulpn | grep nginx | grep -E ':80|:8080' | head -1 | awk '{print $5}' | awk -F: '{print $NF}')
      WEB_PORT=${WEB_PORT:-80}

      cat > /etc/nginx/conf.d/agnudp-backup.conf <<EOF
location /backup {
    alias ${BACKUP_DIR};
    autoindex on;
}
EOF
      systemctl reload nginx
    fi
  else
    # apache
    if [[ ! -f /etc/apache2/conf-available/agnudp-backup.conf ]]; then
      cat > /etc/apache2/conf-available/agnudp-backup.conf <<EOF
Alias /backup "${BACKUP_DIR}"
<Directory "${BACKUP_DIR}">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
EOF
      a2enconf agnudp-backup
      systemctl reload apache2
    fi
    WEB_PORT=80
  fi

else
  echo "[+] No web server detected, installing nginx"

  apt install -y nginx
  systemctl unmask nginx || true
  systemctl enable nginx

  if [[ $USED_80 -eq 0 ]]; then
    WEB_PORT=80
  else
    WEB_PORT=8080
  fi

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
fi

echo "[✓] Backup URL port: $WEB_PORT"

############################################
# INSTALL HYSTERIA
############################################
if [[ ! -f "$HYSTERIA_BIN" ]]; then
  curl -L -o /tmp/hysteria https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64
  chmod +x /tmp/hysteria
  mv /tmp/hysteria "$HYSTERIA_BIN"
fi

############################################
# CONFIG + CERT
############################################
mkdir -p "$CONF_DIR"

openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
  -keyout "$CONF_DIR/server.key" \
  -out "$CONF_DIR/server.crt" \
  -subj "/CN=agnudp" >/dev/null 2>&1

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
cat > "$CONF_FILE" <<EOF
{
  "listen": ":${UDP_PORT}",
  "protocol": "udp",
  "cert": "${CONF_DIR}/server.crt",
  "key": "${CONF_DIR}/server.key",
  "up_mbps": 50,
  "down_mbps": 50,
  "obfs": "${OBFS}",
  "auth": {
    "mode": "passwords",
    "config": []
  }
}
EOF

############################################
# SYSTEMD
############################################
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AGN-UDP (Hysteria v1)
After=network.target

[Service]
ExecStart=${HYSTERIA_BIN} server --config ${CONF_FILE}
Restart=always
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

############################################
# FIREWALL (CRITICAL)
############################################
iptables -t nat -C PREROUTING -i $IFACE -p udp --dport ${UDP_RANGE_START}:${UDP_RANGE_END} -j DNAT --to-destination :${UDP_PORT} 2>/dev/null || \
iptables -t nat -A PREROUTING -i $IFACE -p udp --dport ${UDP_RANGE_START}:${UDP_RANGE_END} -j DNAT --to-destination :${UDP_PORT}

iptables -C INPUT -p udp --dport ${UDP_PORT} -j ACCEPT 2>/dev/null || \
iptables -A INPUT -p udp --dport ${UDP_PORT} -j ACCEPT

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.${IFACE}.rp_filter=0

cat > /etc/sysctl.d/99-agnudp.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.${IFACE}.rp_filter=0
EOF

sysctl --system
iptables-save > /etc/iptables/rules.v4

############################################
# MANAGER
############################################
cat > /usr/local/bin/agnudp <<'EOF'
#!/usr/bin/env bash
DB="/etc/hysteria/users.db"
CFG="/etc/hysteria/config.json"
SERVICE="hysteria-server"
BACKUP_DIR="/backup"
BACKUP_FILE="$BACKUP_DIR/agnudp-backup.7z"
DEFAULT_DAYS=30

update_cfg() {
  users=$(sqlite3 "$DB" "SELECT username||':'||password FROM users WHERE date(expire)>=date('now');")
  jq ".auth.config = $(printf '%s\n' "$users" | jq -R . | jq -s .)" "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  systemctl restart "$SERVICE"
}

add() {
  read -p "Username: " u
  read -p "Password: " p
  read -p "Days [$DEFAULT_DAYS]: " d
  d=${d:-$DEFAULT_DAYS}
  exp=$(date -d "+$d days" +%F)
  sqlite3 "$DB" "INSERT OR REPLACE INTO users VALUES('$u','$p','$exp');"
  update_cfg
}

extend() {
  read -p "Username: " u
  read -p "Add days: " d
  cur=$(sqlite3 "$DB" "SELECT expire FROM users WHERE username='$u';")
  [[ -z "$cur" ]] && echo "Not found" && return
  new=$(date -d "$cur +$d days" +%F)
  sqlite3 "$DB" "UPDATE users SET expire='$new' WHERE username='$u';"
  update_cfg
}

del() {
  read -p "Username: " u
  sqlite3 "$DB" "DELETE FROM users WHERE username='$u';"
  update_cfg
}

list() {
  sqlite3 "$DB" "SELECT username,expire FROM users;"
}

clean() {
  sqlite3 "$DB" "DELETE FROM users WHERE date(expire)<date('now');"
  update_cfg
}

backup() {
  read -p "Backup password (visible): " p
  rm -f "$BACKUP_FILE"
  7z a -t7z -p"$p" -mhe=on "$BACKUP_FILE" "$DB" >/dev/null && \
  echo "Backup saved at $BACKUP_FILE"
}

restore() {
  read -p "Restore Server IP: " ip
  read -p "Restore Password (visible): " p
  TMP="/tmp/agnudp-restore"
  rm -rf "$TMP" && mkdir -p "$TMP"
  curl -f -o "$TMP/agnudp-backup.7z" "http://$ip/backup/agnudp-backup.7z" || \
  curl -f -o "$TMP/agnudp-backup.7z" "http://$ip:8080/backup/agnudp-backup.7z" || \
  { echo "Download failed"; return; }
  7z x -p"$p" "$TMP/agnudp-backup.7z" -o"$TMP" >/dev/null || \
  { echo "Wrong password"; return; }
  cp "$TMP/users.db" "$DB"
  update_cfg
  rm -rf "$TMP"
}

uninstall() {
  read -p "Confirm uninstall AGN-UDP? [y/N]: " c
  [[ "$c" != "y" && "$c" != "Y" ]] && return
  systemctl stop hysteria-server
  systemctl disable hysteria-server
  rm -f /etc/systemd/system/hysteria-server.service
  systemctl daemon-reload
  rm -rf /etc/hysteria
  rm -f /usr/local/bin/agnudp
  rm -f /usr/local/bin/hysteria
  echo "AGN-UDP removed"
  exit 0
}

while true; do
  echo "==== AGN-UDP Manager ===="
  echo "1) Add user"
  echo "2) Extend user"
  echo "3) Delete user"
  echo "4) List users"
  echo "5) Cleanup expired"
  echo "6) Backup"
  echo "7) Restore"
  echo "8) Uninstall"
  echo "0) Exit"
  read -p "> " c
  case $c in
    1) add ;;
    2) extend ;;
    3) del ;;
    4) list ;;
    5) clean ;;
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
echo "======================================"
echo "AGN-UDP INSTALLED SUCCESSFULLY"
echo "UDP RANGE : ${UDP_RANGE_START}-${UDP_RANGE_END}"
echo "LISTEN    : ${UDP_PORT}"
echo "BACKUP URL: http://SERVER_IP:${WEB_PORT}/backup/agnudp-backup.7z"
echo "Run: agnudp"
echo "======================================"
