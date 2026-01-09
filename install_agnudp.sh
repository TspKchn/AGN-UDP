#!/usr/bin/env bash
set -e

### ================= BASIC CONFIG =================
UDP_PORT="36712"
UDP_RANGE="10000:65000"
OBFS="agnudp"

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
DB_FILE="$CONFIG_DIR/users.db"

HYSTERIA_BIN="/usr/local/bin/hysteria"
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"

BACKUP_DIR="/backup"
BACKUP_FILE="$BACKUP_DIR/agnudp-backup.7z"

NGINX_PORT="8080"
NGINX_CONF="/etc/nginx/conf.d/agnudp-backup.conf"

### ================= ROOT CHECK =================
[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1

### ================= DOMAIN INPUT =================
echo
read -p "Enter DOMAIN (DNS must point to this VPS): " DOMAIN
[[ -z "$DOMAIN" ]] && echo "Domain required" && exit 1

SERVER_IP=$(curl -s https://api.ipify.org || true)
DOMAIN_IP=$(getent ahosts "$DOMAIN" | awk '{print $1; exit}')

if [[ -n "$SERVER_IP" && -n "$DOMAIN_IP" && "$SERVER_IP" != "$DOMAIN_IP" ]]; then
  echo "DNS ERROR: $DOMAIN -> $DOMAIN_IP (server $SERVER_IP)"
  exit 1
fi

### ================= DEPENDENCIES =================
apt update
apt install -y curl jq sqlite3 openssl iptables iptables-persistent nginx p7zip-full

### ================= INSTALL HYSTERIA =================
if [[ ! -f "$HYSTERIA_BIN" ]]; then
  curl -L -o /tmp/hysteria https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64
  chmod +x /tmp/hysteria
  mv /tmp/hysteria "$HYSTERIA_BIN"
fi

### ================= CERT (ORIGINAL STYLE) =================
mkdir -p "$CONFIG_DIR"

openssl genrsa -out "$CONFIG_DIR/hysteria.ca.key" 2048
openssl req -new -x509 -days 3650 \
  -key "$CONFIG_DIR/hysteria.ca.key" \
  -subj "/CN=Hysteria Root CA" \
  -out "$CONFIG_DIR/hysteria.ca.crt"

openssl req -newkey rsa:2048 -nodes \
  -keyout "$CONFIG_DIR/hysteria.server.key" \
  -subj "/CN=$DOMAIN" \
  -out "$CONFIG_DIR/hysteria.server.csr"

openssl x509 -req -days 3650 \
  -in "$CONFIG_DIR/hysteria.server.csr" \
  -CA "$CONFIG_DIR/hysteria.ca.crt" \
  -CAkey "$CONFIG_DIR/hysteria.ca.key" \
  -CAcreateserial \
  -out "$CONFIG_DIR/hysteria.server.crt" \
  -extfile <(printf "subjectAltName=DNS:%s" "$DOMAIN")

### ================= SQLITE DB =================
if [[ ! -f "$DB_FILE" ]]; then
sqlite3 "$DB_FILE" <<EOF
CREATE TABLE users (
  username TEXT PRIMARY KEY,
  password TEXT NOT NULL,
  expire DATE NOT NULL
);
EOF
fi

### ================= CONFIG.JSON =================
cat > "$CONFIG_FILE" <<EOF
{
  "listen": ":$UDP_PORT",
  "protocol": "udp",
  "cert": "$CONFIG_DIR/hysteria.server.crt",
  "key": "$CONFIG_DIR/hysteria.server.key",
  "up": "100 Mbps",
  "down": "100 Mbps",
  "obfs": "$OBFS",
  "auth": {
    "mode": "passwords",
    "config": []
  }
}
EOF

### ================= SYSTEMD =================
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AGN-UDP Service
After=network.target

[Service]
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$HYSTERIA_BIN server -c $CONFIG_FILE
Restart=always
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

### ================= NETWORK / FIREWALL =================
IFACE=$(ip route | awk '/default/ {print $5; exit}')

iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport $UDP_RANGE -j DNAT --to :$UDP_PORT 2>/dev/null || \
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport $UDP_RANGE -j DNAT --to :$UDP_PORT

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.$IFACE.rp_filter=0

iptables-save > /etc/iptables/rules.v4

### ================= BACKUP DIR =================
mkdir -p "$BACKUP_DIR"
chmod 755 "$BACKUP_DIR"

### ================= SAFE NGINX SETUP =================

# remove old conflicting agnudp config if exists
rm -f /etc/nginx/sites-enabled/agnudp 2>/dev/null

# write isolated config (DO NOT touch nginx.conf)
cat > "$NGINX_CONF" <<EOF
server {
    listen $NGINX_PORT;
    server_name _;

    location /backup/ {
        alias $BACKUP_DIR/;
        autoindex on;
    }
}
EOF

# validate before reload (safe)
if nginx -t; then
    systemctl reload nginx
else
    echo "❌ nginx config error, abort install"
    exit 1
fi

### ================= MANAGER =================
cat > /usr/local/bin/agnudp <<'EOF'
#!/usr/bin/env bash

CFG="/etc/hysteria/config.json"
DB="/etc/hysteria/users.db"
BACKUP="/backup/agnudp-backup.7z"

update_cfg() {
  users=$(sqlite3 "$DB" "select username||\":\"||password from users where date(expire)>=date('now')")
  jq ".auth.config = $(printf '%s\n' "$users" | jq -R . | jq -s .)" "$CFG" > /tmp/cfg && mv /tmp/cfg "$CFG"
  systemctl restart hysteria-server
}

while true; do
echo "====== AGN-UDP MENU ======"
echo "1) Add User"
echo "2) Extend User"
echo "3) Delete User"
echo "4) List User"
echo "5) Backup (users.db)"
echo "6) Restore (users.db)"
echo "7) Uninstall"
echo "0) Exit"
read -p "> " c

case $c in
1)
  read -p "Username: " u
  read -p "Password: " p
  read -p "Days: " d
  e=$(date -d "+$d days" +%F)
  sqlite3 "$DB" "insert or replace into users values('$u','$p','$e')"
  update_cfg
;;
2)
  read -p "Username: " u
  read -p "Add days: " d
  cur=$(sqlite3 "$DB" "select expire from users where username='$u'")
  new=$(date -d "$cur +$d days" +%F)
  sqlite3 "$DB" "update users set expire='$new' where username='$u'"
  update_cfg
;;
3)
  read -p "Username: " u
  sqlite3 "$DB" "delete from users where username='$u'"
  update_cfg
;;
4)
  sqlite3 "$DB" "select username,expire from users;"
;;
5)
  read -p "Backup password: " p
  rm -f "$BACKUP"
  7z a -p"$p" -mhe=on "$BACKUP" "$DB"
  echo "Backup saved: $BACKUP"
;;
6)
  read -p "Restore Server IP: " ip
  read -p "Backup password: " p
  tmp=/tmp/agnudp-restore
  rm -rf "$tmp" && mkdir -p "$tmp"
  curl -f -o "$tmp/db.7z" "http://$ip:8080/backup/agnudp-backup.7z" || { echo "Download failed"; break; }
  7z x -p"$p" "$tmp/db.7z" -o"$tmp" || { echo "Wrong password"; break; }
  cp "$tmp/users.db" "$DB"
  update_cfg
;;
7)
  systemctl stop hysteria-server
  systemctl disable hysteria-server
  rm -rf /etc/hysteria /usr/local/bin/agnudp /etc/systemd/system/hysteria-server.service
  rm -f /etc/nginx/conf.d/agnudp-backup.conf
  systemctl reload nginx
  systemctl daemon-reload
  exit
;;
0) exit ;;
esac
done
EOF

chmod +x /usr/local/bin/agnudp

echo
echo "======================================"
echo "AGN-UDP INSTALLED"
echo "Domain: $DOMAIN"
echo "Backup URL: http://$DOMAIN:$NGINX_PORT/backup/agnudp-backup.7z"
echo "Run: agnudp"
echo "======================================"
