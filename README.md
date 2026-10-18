# Android + Magisk 上的 Debian chroot

在 Magisk 的手机上跑 Debian 13 (trixie, 当前 stable) arm64 chroot，开机自动启动 sshd，之后用 SSH 连进去开发。

| 文件 | 在哪里运行 | 作用 |
|---|---|---|
| `install.sh` | 电脑 | 一键安装:下载 rootfs、校验、解压到手机、装脚本、装软件、启动 |
| `debian.sh` | 手机 (root) | chroot 管理:`start` `stop` `restart` `status` `shell` `exec` |
| `boot.sh` | 手机 (Magisk) | 开机后自动执行 `debian.sh start` |
| `provision.sh` | chroot 内 | 建用户、装 sshd/git/golang/python 等 |

## 安装

前提:手机已连接 adb, Magisk 里已授予 adb shell root 权限;电脑上有 `~/.ssh/id_*.pub`。

```bash
./install.sh
```

可选环境变量:`SSH_PORT=2222`、`DEV_USER=user`、`MIRROR=https://mirrors.tuna.tsinghua.edu.cn`(apt 镜像，如果你在中国)、`PUBKEY=~/.ssh/xxx.pub`(默认 `~/.ssh/id_ed25519.pub`)。

安装结束会打印连接命令,例如 `ssh -p 2222 user@192.168.x.x`。登录只允许密钥,`user` 用户可无密码 `sudo`。

## 日常管理

```bash
adb shell su -M -c '/data/adb/debian/debian.sh status'
adb shell su -M -c '/data/adb/debian/debian.sh stop'
adb shell su -M -c '/data/adb/debian/debian.sh start'
adb shell -t su -M -c '/data/adb/debian/debian.sh shell'   # 进 user 用户的 shell
```

开机日志:`/data/adb/debian/boot.log`。

## 注意

- 先 `stop` 再删除:`/data/debian` 里 bind 了 `/dev`,卸载前直接 `rm -rf` 会删到系统设备文件。
  卸载请用:`debian.sh stop && rm -rf --one-file-system /data/debian /data/adb/debian /data/adb/service.d/99-debian.sh`
- 升级系统:chroot 里 `sudo apt update && sudo apt full-upgrade`。
- 系统更新后要在Magisk里Install boot保住root,否则开机脚本不会运行。
- `debian.sh start` 会持有内核 wakelock,让 CPU 不休眠。如果熄屏后 SSH 仍然断开, 多半是 Wi-Fi 进入了省电模式,请检查系统的电池优化/Wi-Fi 省电设置。
