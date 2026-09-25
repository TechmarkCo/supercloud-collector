#!/bin/sh
# First-boot hook for a pre-baked VM. NIC is already on DHCP.
set -eu
MASTER="${SUPERCLOUD_MASTER:-https://supercloud.techmarkcompany.com}"
SITE="${SUPERCLOUD_SITE:-}"
TOKEN="${SUPERCLOUD_TOKEN:-}"
if [ -f /etc/supercloud.env ]; then
  . /etc/supercloud.env
fi
if [ -z "$SITE" ] || [ -z "$TOKEN" ]; then
  echo "Set SUPERCLOUD_SITE and SUPERCLOUD_TOKEN in /etc/supercloud.env"
  exit 1
fi
curl -fsSL "$MASTER/collector/install.sh" | sh -s -- --site "$SITE" --token "$TOKEN"
