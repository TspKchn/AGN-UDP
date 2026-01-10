#!/usr/bin/env bash
set -e

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
NGINX_PORT="8080"
NGINX_CONF="/etc/nginx/conf.d/agnudp-backup.conf"

[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

read -p "Enter DOMAIN (DNS must point to this VPS): " DOMAIN
[[ -z "$DOMAIN" ]] && { echo "Domain required"; exit 1; }

apt update
apt install -y \
  curl jq sqlite3 openssl \
  iptables iptables-persistent \
  nginx p7zip-full sshpass

if [[ ! -f "$HYSTERIA_BIN" ]]; then
  curl -L -o /tmp/hysteria \
    https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64
  chmod +x /tmp/hysteria
  mv /tmp/hysteria "$HYSTERIA_BIN"
fi

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

mkdir -p "$STATE_DIR"

sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS users (
  username TEXT PRIMARY KEY,
  password TEXT NOT NULL,
  expire DATE NOT NULL
);
EOF

cat > "$CONFIG_FILE" <<EOF
{
  "listen": ":$UDP_PORT",
  "protocol": "udp",
  "cert": "$CONFIG_DIR/server.crt",
  "key": "$CONFIG_DIR/server.key",
  "up": "100 Mbps",
  "down": "100 Mbps",
  "obfs": "$OBFS",
  "auth": { "mode": "passwords", "config": [] }
}
EOF

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

IFACE=$(ip route | awk '/default/ {print $5; exit}')

# UDP NAT for Hysteria
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport $UDP_RANGE -j DNAT --to :$UDP_PORT 2>/dev/null || \
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport $UDP_RANGE -j DNAT --to :$UDP_PORT

# Allow AGN-UDP backup / restore (TCP 8080)
iptables -C INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || \
iptables -I INPUT -p tcp --dport 8080 -j ACCEPT

# Kernel / network tuning
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.$IFACE.rp_filter=0

iptables-save > /etc/iptables/rules.v4

mkdir -p "$BACKUP_DIR"
chmod 755 "$BACKUP_DIR"

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

nginx -t && systemctl reload nginx

curl -fsSL "$REPO_RAW/agnudp" -o /usr/local/bin/agnudp
chmod +x /usr/local/bin/agnudp

cat > /etc/cron.d/agnudp <<EOF
0 3 * * * root /usr/local/bin/agnudp sync-local >> /var/log/agnudp-sync.log 2>&1
10 3 * * * root /usr/local/bin/agnudp cleanup >> /var/log/agnudp-clean.log 2>&1
EOF

echo
echo
echo "======================================"
echo "AGN-UDP Installed. Run: agnudp"
echo "Manage users & backup/restore: agnudp"
echo "Backup URL: http://$DOMAIN:$NGINX_PORT/backup/"
echo "======================================"
