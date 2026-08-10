#!/usr/bin/env bash
# Longhorn node prerequisites for this cluster (Debian/Ubuntu).
# Idempotent — safe to re-run. Run as root on every k3s node:
#   sudo ./node-setup.sh
#
# Installs/enables:
#   - open-iscsi + iscsid      (Longhorn volume attachment)
#   - nfs-common               (RWX volumes / NFS backup targets)
#   - cryptsetup + dm_crypt    (longhorn-encrypted StorageClass)
# Also blacklists Longhorn devices from multipathd if it is running
# (known cause of volume attach failures).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root (sudo $0)" >&2
  exit 1
fi

echo "== Installing packages =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y open-iscsi nfs-common cryptsetup

echo "== Enabling iscsid =="
systemctl enable --now iscsid

echo "== Loading kernel modules (and persisting across reboots) =="
modprobe iscsi_tcp
modprobe dm_crypt
cat > /etc/modules-load.d/longhorn.conf <<'EOF'
iscsi_tcp
dm_crypt
EOF

# multipathd grabs Longhorn's /dev/sdX devices and breaks attachment.
if systemctl is-active --quiet multipathd; then
  echo "== multipathd active: blacklisting Longhorn devices =="
  mkdir -p /etc/multipath/conf.d
  cat > /etc/multipath/conf.d/longhorn.conf <<'EOF'
blacklist {
    devnode "^sd[a-z0-9]+"
}
EOF
  systemctl restart multipathd
fi

echo "== Verifying =="
fail=0
check() {
  # check <label> <command...>
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "  OK   $label"
  else
    echo "  FAIL $label"
    fail=1
  fi
}

check "iscsid active"        systemctl is-active --quiet iscsid
check "iscsiadm present"     command -v iscsiadm
check "iscsi_tcp module"     grep -qw '^iscsi_tcp' /proc/modules
check "dm_crypt module"      grep -qw '^dm_crypt' /proc/modules
check "cryptsetup present"   command -v cryptsetup
check "nfs mount helper"     command -v mount.nfs

echo "== Disk space for Longhorn data path (/var/lib/longhorn) =="
df -h /var/lib/longhorn 2>/dev/null || df -h /var/lib

if [ "$fail" -ne 0 ]; then
  echo "RESULT: one or more checks FAILED" >&2
  exit 1
fi
echo "RESULT: node ready for Longhorn (incl. encrypted volumes)"
