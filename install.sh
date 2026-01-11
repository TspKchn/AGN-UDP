#!/usr/bin/env hysteria-server
set -e

### ================= FORCE CLEAN OLD AGN-UDP =================
echo "[*] Pre-clean old AGN-UDP (safe mode)"

set +e

# stop hysteria if exists
systemctl stop hysteria-server 2>/dev/null
systemctl disable hysteria-server 2>/dev/null

# remove agnudp cron
rm -f /etc/cron.d/agnudp

# remove agnudp files
rm -rf /etc/agnudp
rm -rf /etc/hysteria
rm -rf /backup
rm -f /usr/local/bin/agnudp
rm -f /usr/local/bin/hysteria

# remove systemd service
rm -f /etc/systemd/system/hysteria-server.service
rm -f /lib/systemd/system/hysteria-server.service
systemctl daemon-reload 2>/dev/null
systemctl reset-failed 2>/dev/null

# clean iptables (AGN-UDP only)
IFACE=$(ip route | awk '/default/ {print $5; exit}')
iptables -t nat -D PREROUTING -i "$IFACE" -p udp --dport 10000:65000 -j DNAT --to :36712 2>/dev/null
iptables -D INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null
iptables-save > /etc/iptables/rules.v4 2>/dev/null

# clean nginx agnudp config (old + new)
rm -f /etc/nginx/conf.d/agnudp-backup.conf

if [[ -f /etc/nginx/conf.d/vps.conf ]]; then
  sed -i '/AGN-UDP/d' /etc/nginx/conf.d/vps.conf
fi

nginx -t >/dev/null 2>&1 && systemctl reload nginx

set -e
echo "[✓] Old AGN-UDP cleaned"
echo
### ================= END FORCE CLEAN =================

### ================= BASIC CONFIG =================
REPO_RAW="https://raw.githubusercontent.com/TspKchn/AGN-UDP/main"

UDP_PORT="36712"
UDP_RANGE="10000:65000"
OBFS="agnudp"

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
DB_FILE="$CONFIG_DIR/users.db"

STATE_DIR="/etc/agnudp"

HYSTERIA_BIN="/usr/local/bin/hysteria"
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"

BACKUP_DIR="/backup"

# ใช้ไฟล์เดียวกับ ShowOn
NGINX_CONF="/etc/nginx/conf.d/vps.conf"
BACKUP_PORT="8080"

### ================= ROOT CHECK =================
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

### ================= DOMAIN INPUT =================
read -rp "Enter DOMAIN (DNS must point to this VPS): " DOMAIN
[[ -z "$DOMAIN" ]] && { echo "Domain required"; exit 1; }

### ================= DEPENDENCIES =================
apt update
apt install -y \
  curl jq sqlite3 openssl \
  iptables iptables-persistent \
  nginx p7zip-full sshpass

### ================= INSTALL HYSTERIA (FORCE) =================
rm -f "$HYSTERIA_BIN"
curl -L -o "$HYSTERIA_BIN" \
https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64
chmod +x "$HYSTERIA_BIN"

### ================= CERT =================
mkdir -p "$CONFIG_DIR"

openssl genrsa -out "$CONFIG_DIR/ca.key" 2048
openssl req -new -x509 -days 3650 \
  -key "$CONFIG_DIR/ca.key" \
  -subj "/CN=AGN-UDP CA" \
  -out "$CONFIG_DIR/ca.crt"

openssl req -newkey rsa:2048 -nodes \
  -keyout "$CONFIG_DIR/server.key" \
  -subj "/CN=$DOMAIN" \
  -out "$CONFIG_DIR/server.csr"

openssl x509 -req -days 3650 \
  -in "$CONFIG_DIR/server.csr" \
  -CA "$CONFIG_DIR/ca.crt" \
  -CAkey "$CONFIG_DIR/ca.key" \
  -CAcreateserial \
  -out "$CONFIG_DIR/server.crt"

### ================= SQLITE DB =================
mkdir -p "$STATE_DIR"

sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS users (
  username TEXT PRIMARY KEY,
  password TEXT NOT NULL,
  expire DATE NOT NULL
);
EOF

### ================= CONFIG.JSON =================
cat > "$CONFIG_FILE" <<EOF
{
  "listen": ":$UDP_PORT",
  "protocol": "udp",
  "cert": "$CONFIG_DIR/server.crt",
  "key": "$CONFIG_DIR/server.key",
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
Description=AGN-UDP (Hysteria v1)
After=network.target

[Service]
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

# UDP DNAT
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport $UDP_RANGE -j DNAT --to :$UDP_PORT 2>/dev/null || \
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport $UDP_RANGE -j DNAT --to :$UDP_PORT

# เปิด TCP 8080 สำหรับ backup
iptables -C INPUT -p tcp --dport $BACKUP_PORT -j ACCEPT 2>/dev/null || \
iptables -I INPUT -p tcp --dport $BACKUP_PORT -j ACCEPT

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.$IFACE.rp_filter=0

iptables-save > /etc/iptables/rules.v4

### ================= BACKUP DIR =================
mkdir -p "$BACKUP_DIR"
chmod 755 "$BACKUP_DIR"

### ================= NGINX (USE vps.conf) =================
if [[ ! -f "$NGINX_CONF" ]]; then
  echo "❌ $NGINX_CONF not found (ShowOn not installed?)"
  exit 1
fi

# เพิ่ม listen 8080 ถ้ายังไม่มี
if ! grep -q "listen $BACKUP_PORT" "$NGINX_CONF"; then
  sed -i "/server {/a\\    listen $BACKUP_PORT;" "$NGINX_CONF"
fi

# เพิ่ม location /backup ถ้ายังไม่มี
if ! grep -q "location /backup/" "$NGINX_CONF"; then
cat >> "$NGINX_CONF" <<'EOF'

    # AGN-UDP Backup
    location /backup/ {
        alias /backup/;
        autoindex on;
    }
EOF
fi

nginx -t && systemctl reload nginx

### ================= INSTALL AGNUDP =================
curl -fsSL "$REPO_RAW/agnudp" -o /usr/local/bin/agnudp
chmod +x /usr/local/bin/agnudp

### ================= CRON =================
cat > /etc/cron.d/agnudp <<EOF
0 3 * * * root /usr/local/bin/agnudp sync-local >> /var/log/agnudp-sync.log 2>&1
10 3 * * * root /usr/local/bin/agnudp cleanup >> /var/log/agnudp-clean.log 2>&1
EOF

### ================= DONE =================
echo
echo "======================================"
echo " AGN-UDP INSTALL COMPLETED"
echo "--------------------------------------"
echo " Domain     : $DOMAIN"
echo " UDP Port   : $UDP_PORT"
echo " Backup URL : http://$DOMAIN:$BACKUP_PORT/backup/"
echo
echo " Run manager: agnudp"
echo "======================================"
