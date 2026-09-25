#!/bin/sh
# SuperCloud site collector — internet bootstrap.
#   curl -fsSL https://supercloud.techmarkcompany.com/collector/install.sh | sudo sh -s -- --site SITE --token TOKEN
set -eu
MASTER="${SUPERCLOUD_MASTER:-https://supercloud.techmarkcompany.com}"
HUB="${SUPERCLOUD_HUB:-$MASTER/collector/v1}"
SITE="${SUPERCLOUD_SITE:-}"
TOKEN="${SUPERCLOUD_TOKEN:-${BASTION_TOKEN:-}}"
HOSTNAME_SET="${SUPERCLOUD_HOSTNAME:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --site) SITE="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --hub) HUB="$2"; shift 2 ;;
    --master) MASTER="$2"; shift 2 ;;
    --hostname) HOSTNAME_SET="$2"; shift 2 ;;
    *) echo "unknown arg $1"; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)."
  exit 1
fi
if [ -z "$SITE" ] || [ -z "$TOKEN" ]; then
  echo "Need --site SITEID --token TOKEN (from SuperCloud → Sites → Reveal token)."
  exit 1
fi

install_node() {
  if command -v node >/dev/null 2>&1; then
    return
  fi
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nodejs
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nodejs
  else
    echo "Install Node.js 20+ then re-run."
    exit 1
  fi
}

install_helpers() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y -qq sshpass iputils-ping openssh-client ca-certificates >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sshpass iputils openssh-clients ca-certificates >/dev/null 2>&1 || true
  fi
}

install_node
install_helpers

install -d -m 755 /opt/bastion /etc/bastion
curl -fsSL "$MASTER/collector/bastion-collector.mjs" -o /opt/bastion/bastion-collector.mjs
curl -fsSL "$MASTER/collector/start-collector.sh" -o /opt/bastion/start-collector.sh || true
chmod 755 /opt/bastion/bastion-collector.mjs /opt/bastion/start-collector.sh 2>/dev/null || chmod 755 /opt/bastion/bastion-collector.mjs

HOST="${HOSTNAME_SET:-COLLECTOR-$(echo "$SITE" | tr '[:lower:]' '[:upper:]')}"
if [ ! -f /etc/bastion/collector.config.json ]; then
  cat > /etc/bastion/collector.config.json << EOF
{
  "siteId": "$SITE",
  "hostname": "$HOST",
  "hubUrl": "$HUB",
  "token": "$TOKEN",
  "inventoryPath": "/etc/bastion/inventory.yaml",
  "pollSeconds": 20,
  "autoUpgrade": true,
  "honeypot": {
    "enabled": true,
    "bind": "0.0.0.0",
    "services": [
      { "name": "SSH", "port": 2222, "banner": "SSH-2.0-OpenSSH_8.4" },
      { "name": "HTTP", "port": 8088 },
      { "name": "SMB", "port": 4450 }
    ]
  }
}
EOF
  chmod 600 /etc/bastion/collector.config.json
else
  echo "Keeping existing /etc/bastion/collector.config.json"
fi
if [ ! -f /etc/bastion/inventory.yaml ]; then
  cat > /etc/bastion/inventory.yaml << EOF
# Drop site inventory here (firewall, switches, endpoints, servers).
# chmod 600 this file. Config and upgrades come from $MASTER
org: $SITE
site: $SITE
collector:
  hostname: $HOST
EOF
  chmod 600 /etc/bastion/inventory.yaml
fi

cat > /etc/systemd/system/bastion-collector.service << 'UNIT'
[Unit]
Description=SuperCloud site collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/bastion
ExecStart=/usr/bin/node /opt/bastion/bastion-collector.mjs --config /etc/bastion/collector.config.json
Restart=always
RestartSec=10
Environment=NODE_TLS_REJECT_UNAUTHORIZED=0

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now bastion-collector
systemctl --no-pager --lines=20 status bastion-collector || true
echo "Collector installed. It uses DHCP on the VM NIC and phones home to $HUB"
