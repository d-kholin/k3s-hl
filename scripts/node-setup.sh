#!/usr/bin/env bash
# Node prerequisites for this cluster (Debian/Ubuntu).
# Idempotent — safe to re-run. Run as root on every k3s node:
#   sudo ./node-setup.sh
#
# Installs/enables:
#   - open-iscsi + iscsid      (Longhorn volume attachment)
#   - nfs-common               (RWX volumes / NFS backup targets)
#   - cryptsetup + dm_crypt    (longhorn-encrypted StorageClass)
# Also blacklists Longhorn devices from multipathd if it is running
# (known cause of volume attach failures), and pins kubelet to a static
# resolv.conf so DHCP/Tailscale search domains never leak into pod
# resolv.conf (a leaked search domain breaks external DNS in musl/Alpine
# images: the zone answers <name>.<search-domain> with NOERROR/NODATA and
# musl stops the search without ever trying the bare name).

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

echo "== Pinning kubelet to a static resolv.conf (no search domains) =="
cat > /etc/rancher/k3s/resolv.conf <<'EOF'
nameserver 192.168.11.1
nameserver 1.1.1.1
EOF
if ! grep -q 'resolv-conf=' /etc/rancher/k3s/config.yaml; then
  cat >> /etc/rancher/k3s/config.yaml <<'EOF'

# Kubelet: use a static resolv.conf so DHCP/Tailscale search domains
# do not leak into pod resolv.conf (breaks musl DNS for external names)
kubelet-arg:
  - "resolv-conf=/etc/rancher/k3s/resolv.conf"
EOF
  echo "  config.yaml updated — restart k3s to apply: systemctl restart k3s"
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
check "kubelet resolv-conf"  grep -q 'resolv-conf=' /etc/rancher/k3s/config.yaml
check "static resolv.conf"   test -s /etc/rancher/k3s/resolv.conf

echo "== Disk space for Longhorn data path (/var/lib/longhorn) =="
df -h /var/lib/longhorn 2>/dev/null || df -h /var/lib

if [ "$fail" -ne 0 ]; then
  echo "RESULT: one or more checks FAILED" >&2
  exit 1
fi
echo "RESULT: node ready for Longhorn (incl. encrypted volumes)"
