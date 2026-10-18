#!/system/bin/sh
# Magisk late_start service script: bring up the Debian chroot and sshd at boot.
# Installed to /data/adb/service.d/99-debian.sh by install.sh.

LOG=/data/adb/debian/boot.log

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 5; done
sleep 10

{
    echo "=== $(date) ==="
    /data/adb/debian/debian.sh start
} >> "$LOG" 2>&1
