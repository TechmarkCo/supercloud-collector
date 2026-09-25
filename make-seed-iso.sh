#!/bin/sh
# Build a NoCloud seed ISO labeled "cidata" for the SuperCloud collector VM.
# Usage: ./make-seed-iso.sh SITEID TOKEN
set -eu
SITE="${1:-${SUPERCLOUD_SITE:-REPLACE_SITE}}"
TOKEN="${2:-${SUPERCLOUD_TOKEN:-REPLACE_TOKEN}}"
MASTER="${SUPERCLOUD_MASTER:-https://supercloud.techmarkcompany.com}"
OUT="${3:-cidata.iso}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/cidata.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
cat > "$STAGE/meta-data" << EOF
instance-id: supercloud-collector-01
local-hostname: supercloud-collector
EOF
cat > "$STAGE/network-config" << 'EOF'
version: 2
ethernets:
  id0:
    match:
      name: "en*"
    dhcp4: true
    dhcp-identifier: mac
  id1:
    match:
      name: "eth*"
    dhcp4: true
    dhcp-identifier: mac
EOF
cat > "$STAGE/user-data" << EOF
#cloud-config
hostname: supercloud-collector
manage_etc_hosts: true
timezone: Asia/Bangkok
package_update: true
packages:
  - ca-certificates
  - curl
write_files:
  - path: /etc/supercloud.env
    permissions: "0600"
    content: |
      SUPERCLOUD_MASTER=${MASTER}
      SUPERCLOUD_SITE=${SITE}
      SUPERCLOUD_TOKEN=${TOKEN}
runcmd:
  - dhclient -v || true
  - . /etc/supercloud.env
  - if [ -n "\$SUPERCLOUD_SITE" ] && [ "\$SUPERCLOUD_SITE" != "REPLACE_SITE" ]; then curl -fsSL ${MASTER}/collector/install.sh | sh -s -- --site "\$SUPERCLOUD_SITE" --token "\$SUPERCLOUD_TOKEN"; fi
EOF
if command -v hdiutil >/dev/null 2>&1; then
  hdiutil makehybrid -iso -joliet -default-volume-name cidata -o "$OUT" "$STAGE"
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -output "$OUT" -volid cidata -joliet -rock "$STAGE"
elif command -v mkisofs >/dev/null 2>&1; then
  mkisofs -output "$OUT" -volid cidata -joliet -rock "$STAGE"
elif command -v xorriso >/dev/null 2>&1; then
  xorriso -as mkisofs -V cidata -o "$OUT" -joliet -rock "$STAGE"
else
  echo "Need hdiutil or genisoimage." >&2
  exit 1
fi
echo "Wrote $OUT"
