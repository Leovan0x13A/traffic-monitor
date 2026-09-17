# traffic-monitor

一键安装 VPS 流量提醒工具。脚本安装 vnStat 和 msmtp，按所选每月重置日统计指定网卡的接收＋发送流量，达到阶梯值时发邮件，达到上限时提醒或关机。`status` 同时显示 vnStat 记录与 Linux 内核网卡计数。

> **计费口径先核对**：当前版本把 `rx + tx` 相加，以十进制 GB（1 GB = 1,000,000,000 字节）计算。部分 VPS 服务商只计算出站流量，或有不同的重置时刻。若口径不同，请先调整脚本，不要启用自动关机。vnStat 从安装后开始记录，不能补算安装前的流量。

## 适用环境

- Debian 或 Ubuntu，使用 `apt` 和 systemd
- root 权限及可访问软件源的网络
- 可使用 SMTP 的发件邮箱，支持 587/STARTTLS 或 465/TLS

已在 WSL Ubuntu 24.04 验证安装、vnStat 采集、`status` 和 systemd 定时任务。真实 SMTP 发信、自动关机及 Debian 13 尚未实测。

## 安装

从 [GitHub 仓库](https://github.com/leovan0x13a/traffic-monitor) 下载脚本，查看内容后以 root 运行：

```bash
curl -fL -o install_traffic_monitor.sh https://raw.githubusercontent.com/leovan0x13a/traffic-monitor/main/install_traffic_monitor.sh
sudo bash install_traffic_monitor.sh
```

安装器依次询问：

1. 显示当前机器时区，询问是否更改。更改后 vnStat 旧记录不会按新时区重算。
2. 公网网卡（默认从 IPv4 默认路由识别）与主机标识。
3. 每月统计重置日（1～28 日，默认 1 日）、每账期上限和阶梯提醒值，单位为十进制 GB。非 1 日账期使用 vnStat 每日记录累计。
4. 达限动作：`alert` 仅发邮件，或 `shutdown` 自动关机。自动关机还需要输入 `YES` 确认。
5. SMTP 服务器、端口、发件账号、收件邮箱与应用密码/授权码。SMTP 服务器默认 `smtp.gmail.com`，端口默认 `587`；直接回车即可采用默认值。Gmail 应用密码中的空格会自动移除，其他 SMTP 密码保持原样。
6. 询问是否把当前内核网卡计数设为显示基线。选择后只显示从此刻起的内核流量；不清除系统原始计数或 vnStat 记录。重启或网卡计数回退后显示本次开机累计。

安装器会发送一封测试邮件。只有 SMTP 提交成功后才启用定时任务。授权码在终端输入时不显示，保存在仅 root 可读的 `/etc/traffic-monitor/smtp-password`；msmtp 配置保存在仅 root 可读的 `/root/.msmtprc-traffic-monitor`，以兼容 Debian 的 AppArmor 规则。请勿将这些文件提交到 GitHub。

## 查看与验证

```bash
status
sudo traffic-monitor --check
systemctl status traffic-monitor.timer
journalctl -u traffic-monitor.service -n 30 --no-pager
```

安装后的前几分钟，vnStat 可能尚无数据；监控会显示“等待首次采集”，之后自动继续。定时任务每五分钟检查一次。`--check` 只显示用量，不发送邮件或关机。更改账期重置日不会补算 vnStat 已删除或安装前的数据；非 1 日账期请确认每日记录覆盖账期起点。

需要重新发送测试邮件时：

```bash
sudo traffic-monitor --test-mail
```

## 文件位置

| 路径 | 用途 |
| --- | --- |
| `/usr/local/sbin/traffic-monitor` | 监控与邮件程序 |
| `/usr/local/bin/status` | 合并显示命令 |
| `/etc/traffic-monitor/` 与 `/root/.msmtprc-traffic-monitor` | 监控配置、SMTP 授权码与 msmtp 配置，仅 root 可读 |
| `/var/lib/traffic-monitor/state.json` | 本账期已发送提醒的记录 |
| `/var/lib/traffic-monitor/kernel-baseline.json` | 可选的内核计数显示基线 |
| `/etc/systemd/system/traffic-monitor.timer` | 定时检查 |

若安装前已存在 `/usr/local/bin/status`，安装器会保留一次备份：`/usr/local/bin/status.traffic-monitor-backup`。

## 注意事项

- vnStat 账期用量是提醒和关机的依据；内核计数仅供对照，重启后会重新开始。它们不应被视作同一个账期的数据。
- 若用量已经超过上限，选择 `shutdown` 后，定时检查会执行关机；重新开机后仍超限时也会再次关机。请先在 `alert` 模式核对计费口径。
- 邮件发送失败不会阻止已启用的自动关机；发送失败信息会进入 systemd 日志。
- SMTP 提交成功仅表示邮件服务器接收了邮件，不保证收件箱最终送达。
- 脚本不会从第三方 GitHub 仓库拉取额外代码；监控程序和 systemd 文件内嵌在安装器中。
