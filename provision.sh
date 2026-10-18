#!/bin/bash
# Runs INSIDE the Debian chroot as root (invoked by install.sh).
set -euo pipefail

DEV_USER=${DEV_USER:-user}
# The chroot shares Android's PID namespace and UID space. Never use a UID/GID that
# Android uses (1000 = system, 10000+ = apps), or the user could signal system processes.
DEV_UID=${DEV_UID:-500000}
SSH_PORT=${SSH_PORT:-2222}
TZ_NAME=${TZ_NAME:-UTC}
MIRROR=${MIRROR:-}        # empty = deb.debian.org
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

[ -s /root/authorized_keys.pub ] || { echo "missing /root/authorized_keys.pub" >&2; exit 1; }

# There is no init system in a chroot: never let dpkg try to start services.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
trap 'rm -f /usr/sbin/policy-rc.d' EXIT

# Android network groups (some kernels only let these groups open sockets).
getent group aid_inet >/dev/null || groupadd -g 3003 aid_inet
getent group aid_net_raw >/dev/null || groupadd -g 3004 aid_net_raw
echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99android

if [ -n "$MIRROR" ]; then
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
        [ -f "$f" ] && sed -i "s#https\?://deb.debian.org#${MIRROR%/}#g" "$f"
    done
fi

apt-get update
apt-get full-upgrade -y
apt-get install -y --no-install-recommends \
    openssh-server sudo git curl wget ca-certificates less \
    build-essential pkg-config python3 python3-dev python3-pip python3-venv pipx \
    golang-go \
    tmux vim htop procps iproute2 iputils-ping netcat-openbsd \
    unzip zip xz-utils jq ripgrep rsync tzdata

if [ -f "/usr/share/zoneinfo/$TZ_NAME" ]; then
    ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
    echo "$TZ_NAME" > /etc/timezone
fi
echo 'LANG=C.UTF-8' > /etc/default/locale

# Dev user: key-only login, passwordless sudo.
getent group "$DEV_USER" >/dev/null || groupadd -g "$DEV_UID" "$DEV_USER"
id "$DEV_USER" >/dev/null 2>&1 ||
    useradd -m -u "$DEV_UID" -g "$DEV_USER" -s /bin/bash -G sudo,aid_inet,aid_net_raw "$DEV_USER"
usermod -p '*' "$DEV_USER"
usermod -aG aid_inet,aid_net_raw root
for u in _apt sshd; do id "$u" >/dev/null 2>&1 && usermod -aG aid_inet "$u"; done
echo "$DEV_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$DEV_USER"
chmod 440 "/etc/sudoers.d/90-$DEV_USER"

install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "/home/$DEV_USER/.ssh"
install -m 600 -o "$DEV_USER" -g "$DEV_USER" /root/authorized_keys.pub \
    "/home/$DEV_USER/.ssh/authorized_keys"
rm -f /root/authorized_keys.pub

# sshd: custom port, keys only.
cat > /etc/ssh/sshd_config.d/10-phone.conf <<CONF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
ClientAliveInterval 30
ClientAliveCountMax 6
CONF
# pam_loginuid / pam_selinux fail inside an Android chroot and would reject logins.
sed -i -E 's/^(session.*pam_(loginuid|selinux)\.so)/#\1/' /etc/pam.d/sshd
ssh-keygen -A
mkdir -p /run/sshd
/usr/sbin/sshd -t

apt-get clean
echo "provision done: $(. /etc/os-release; echo "$PRETTY_NAME")"
