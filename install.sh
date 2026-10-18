#!/usr/bin/env bash
# Run on the PC with the phone connected over adb (USB debugging on, Magisk
# superuser granted to the adb shell). Installs the latest Debian stable arm64
# rootfs into /data/debian on the phone, plus the chroot manager, a Magisk boot
# script and an SSH server (key login only).
#
# Optional env vars:
#   SUITE=trixie     Debian release (13 "trixie" is current stable)
#   DEV_USER=user    login user created in the chroot
#   SSH_PORT=2222    sshd port
#   MIRROR=...       apt mirror base URL, e.g. https://deb.debian.org
#   PUBKEY=...       public key file to authorize (default: ~/.ssh/id_ed25519.pub)
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
SUITE=${SUITE:-trixie}
DEV_USER=${DEV_USER:-user}
SSH_PORT=${SSH_PORT:-2222}
MIRROR=${MIRROR:-}
ROOTFS_DIR=/data/debian
CACHE="$DIR/.cache"
INDEX=https://images.linuxcontainers.org

for c in adb curl xz sha256sum awk; do
    command -v "$c" >/dev/null || { echo "missing command: $c" >&2; exit 1; }
done

rsu() { adb shell -T "su -M -c '$1'"; }   # run a command as root on the phone

adb get-state >/dev/null || { echo "no adb device" >&2; exit 1; }
rsu id | grep -q 'uid=0' || { echo "su failed: grant root to the adb shell in Magisk" >&2; exit 1; }

if [ -z "${PUBKEY:-}" ]; then
    for k in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
        [ -f "$k" ] && { PUBKEY=$k; break; }
    done
fi
[ -n "${PUBKEY:-}" ] && [ -f "$PUBKEY" ] || {
    echo "no SSH public key found; create one (ssh-keygen -t ed25519) or set PUBKEY=..." >&2; exit 1; }
echo ">> Authorizing $PUBKEY: $(ssh-keygen -lf "$PUBKEY" | cut -d' ' -f2-)"

if [ -n "$(rsu "ls -A $ROOTFS_DIR 2>/dev/null" | tr -d '\r')" ]; then
    echo "$ROOTFS_DIR already exists and is not empty on the phone." >&2
    echo "If it is mounted, run: debian.sh stop; then remove it with rm -rf --one-file-system." >&2
    exit 1
fi

echo ">> Finding the latest Debian $SUITE arm64 build"
path=$(curl -fsSL "$INDEX/meta/1.0/index-system" |
    awk -F';' -v s="$SUITE" '$1=="debian" && $2==s && $3=="arm64" && $4=="default" {p=$6} END {print p}')
[ -n "$path" ] || { echo "no build found for $SUITE" >&2; exit 1; }
url="$INDEX${path//:/%3A}"
echo "   $url"

mkdir -p "$CACHE"
curl -fL -o "$CACHE/SHA256SUMS" "$url/SHA256SUMS"
curl -fL -C - -o "$CACHE/rootfs.tar.xz" "$url/rootfs.tar.xz"
(cd "$CACHE" && grep ' rootfs.tar.xz$' SHA256SUMS | sha256sum -c -)

echo ">> Extracting rootfs to $ROOTFS_DIR on the phone (this takes a few minutes)"
rsu "mkdir -p $ROOTFS_DIR && chmod 755 $ROOTFS_DIR"
xz -dc "$CACHE/rootfs.tar.xz" | adb shell -T "su -M -c 'tar -xpf - -C $ROOTFS_DIR'"

echo ">> Installing manager and boot script"
adb push "$DIR/debian.sh" "$DIR/boot.sh" /data/local/tmp/ >/dev/null
rsu "mkdir -p /data/adb/debian /data/adb/service.d &&
     cp /data/local/tmp/debian.sh /data/adb/debian/debian.sh &&
     cp /data/local/tmp/boot.sh /data/adb/service.d/99-debian.sh &&
     chmod 755 /data/adb/debian/debian.sh /data/adb/service.d/99-debian.sh &&
     rm /data/local/tmp/debian.sh /data/local/tmp/boot.sh"

echo ">> Copying provisioning files into the rootfs"
adb shell -T "su -M -c 'cat > $ROOTFS_DIR/root/provision.sh'" < "$DIR/provision.sh"
adb shell -T "su -M -c 'cat > $ROOTFS_DIR/root/authorized_keys.pub'" < "$PUBKEY"

echo ">> Provisioning (apt upgrade and package install; needs network on the phone)"
TZ_NAME=$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)
rsu "/data/adb/debian/debian.sh exec DEV_USER=$DEV_USER SSH_PORT=$SSH_PORT TZ_NAME=$TZ_NAME MIRROR=$MIRROR /bin/bash /root/provision.sh"
rsu "rm -f $ROOTFS_DIR/root/provision.sh"

echo ">> Starting chroot and sshd"
rsu "/data/adb/debian/debian.sh start"
ip=$(adb shell "ip -4 -o addr show wlan0" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr -d '\r' | head -n1)

cat <<DONE

Done. Connect with:
  ssh -p $SSH_PORT $DEV_USER@${ip:-<phone-ip>}

It will start by itself after every reboot (Magisk service.d).
Manage it on the phone with:
  adb shell su -M -c '/data/adb/debian/debian.sh status|stop|start|shell'
DONE
