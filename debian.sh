#!/system/bin/sh
# Debian chroot manager. Runs on the phone as root (via Magisk su).
# Installed to /data/adb/debian/debian.sh by install.sh.
#
#   debian.sh start | stop | restart | status
#   debian.sh shell [user]        interactive shell (default user: user)
#   debian.sh exec CMD [ARGS...]  run CMD inside the chroot as root
#                                 (leading VAR=value arguments set env vars)

umask 022

ROOT="${DEBIAN_ROOT:-/data/debian}"
DEV_USER="${DEBIAN_USER:-user}"
DNS="${DEBIAN_DNS:-1.1.1.1 8.8.8.8}"
WAKELOCK=debian-chroot
DEBIAN_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

die() { echo "debian.sh: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root (use: su -M -c ...)"
[ -x "$ROOT/bin/sh" ] || [ -x "$ROOT/usr/bin/sh" ] || die "no rootfs at $ROOT"

mounted() { grep -q " $1 " /proc/mounts; }

run_in_root() {
    chroot "$ROOT" /usr/bin/env -i \
        HOME=/root USER=root LOGNAME=root \
        TERM="${TERM:-xterm}" LANG=C.UTF-8 PATH="$DEBIAN_PATH" "$@"
}

do_mount() {
    if ! mounted "$ROOT"; then
        mount --bind "$ROOT" "$ROOT" || die "bind mount of $ROOT failed"
        # Keep our mounts out of Android's mount namespace propagation.
        mount -o rprivate none "$ROOT" 2>/dev/null
        # /data is nosuid; allow setuid binaries (sudo, su) inside the rootfs only.
        mount -o remount,bind,suid "$ROOT" 2>/dev/null ||
            echo "warning: could not clear nosuid on $ROOT; sudo may not work" >&2
    fi
    mounted "$ROOT/proc" || mount -t proc proc "$ROOT/proc"
    mounted "$ROOT/sys" || mount -t sysfs sysfs "$ROOT/sys"
    mounted "$ROOT/dev" || mount --bind /dev "$ROOT/dev"
    mounted "$ROOT/dev/pts" ||
        mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts "$ROOT/dev/pts"
    mkdir -p "$ROOT/dev/shm"
    mounted "$ROOT/dev/shm" || mount -t tmpfs -o mode=1777 tmpfs "$ROOT/dev/shm"
    mounted "$ROOT/tmp" || mount -t tmpfs -o mode=1777 tmpfs "$ROOT/tmp"
    mounted "$ROOT/run" || mount -t tmpfs -o mode=755 tmpfs "$ROOT/run"

    # DNS and hosts: Android has no resolv.conf we can reuse.
    rm -f "$ROOT/etc/resolv.conf"
    : > "$ROOT/etc/resolv.conf"
    for ns in $DNS; do echo "nameserver $ns" >> "$ROOT/etc/resolv.conf"; done
    grep -qs localhost "$ROOT/etc/hosts" || echo "127.0.0.1 localhost" >> "$ROOT/etc/hosts"
}

do_umount() {
    for m in dev/shm dev/pts dev sys proc tmp run ""; do
        p="$ROOT${m:+/$m}"
        mounted "$p" && { umount "$p" 2>/dev/null || umount -l "$p"; }
    done
}

kill_procs() {
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        [ "$pid" = "$$" ] && continue
        r=$(readlink "$p/root" 2>/dev/null) || continue
        [ "$r" = "$ROOT" ] && kill -"$1" "$pid" 2>/dev/null
    done
}

sshd_running() {
    [ -f "$ROOT/run/sshd.pid" ] && kill -0 "$(cat "$ROOT/run/sshd.pid")" 2>/dev/null
}

start_sshd() {
    if [ ! -x "$ROOT/usr/sbin/sshd" ]; then
        echo "sshd is not installed yet, skipping"
        return 0
    fi
    if sshd_running; then
        echo "sshd already running"
        return 0
    fi
    mkdir -p "$ROOT/run/sshd" && chmod 755 "$ROOT/run/sshd"
    run_in_root /usr/sbin/sshd && echo "sshd started"
}

cmd_start() {
    do_mount
    # Keep the CPU awake so SSH sessions survive screen-off.
    echo "$WAKELOCK" > /sys/power/wake_lock 2>/dev/null
    start_sshd
}

cmd_stop() {
    kill_procs TERM
    sleep 2
    kill_procs KILL
    echo "$WAKELOCK" > /sys/power/wake_unlock 2>/dev/null
    do_umount
    echo "stopped"
}

cmd_status() {
    if mounted "$ROOT/proc"; then echo "chroot : mounted"; else echo "chroot : not mounted"; fi
    if sshd_running; then echo "sshd   : running"; else echo "sshd   : not running"; fi
    echo "address:"
    ip -4 -o addr show 2>/dev/null | grep -v ' lo ' | sed 's/^/  /'
}

case "$1" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_stop; cmd_start ;;
    status) cmd_status ;;
    shell) shift; do_mount; run_in_root /bin/su -l "${1:-$DEV_USER}" ;;
    exec) shift; [ $# -gt 0 ] || die "exec needs a command"; do_mount; run_in_root "$@" ;;
    *) sed -n '2,9p' "$0"; exit 1 ;;
esac
