# traffic-monitor

一键安装 VPS 流量监控工具。脚本安装 vnStat 和 msmtp，支持当前统计周期流量补录、阶梯邮件提醒和可选达限关机。`status` 同时显示 vnStat 记录与可补录的 Linux 内核流量累计值。

> **计费口径先核对**：当前版本把 `rx + tx` 相加，以十进制 GB（1 GB = 1,000,000,000 字节）计算。部分 VPS 服务商只计算出站流量，或有不同的重置时刻。若口径不同，请先调整脚本，不要启用自动关机。vnStat 不能自动补算安装前的流量，安装器可将服务商显示的当前已用总量作为本统计周期的补录值。

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

安装器会先提示“[] 内为默认选项，直接按回车即可确认”，然后依次询问：

1. 显示当前机器时区，询问是否更改。更改后 vnStat 旧记录不会按新时区重算。
2. 公网网卡（默认从 IPv4 默认路由识别）与主机标识。
3. 每月统计重置日（1～28 日，默认 1 日）、每个统计周期的流量上限和阶梯提醒值，单位为十进制 GB。非 1 日重置时使用 vnStat 每日记录累计。
4. 显示 vnStat 已记录的本周期用量，询问当前已使用总流量。默认使用 vnStat 数值；填入更大数值时，差额作为本周期补录流量，下个周期自动失效。已经越过的提醒阶梯会记为已处理，避免安装后集中发送旧提醒。
5. 达限动作：`alert` 仅发邮件，或 `shutdown` 自动关机。自动关机还需要输入 `YES` 确认。
6. SMTP 服务器、端口、发件账号、收件邮箱与应用密码/授权码。SMTP 服务器默认 `smtp.gmail.com`，端口默认 `587`；收件邮箱没有默认值，必须填写。Gmail 应用密码中的空格会自动移除，其他 SMTP 密码保持原样。
7. 询问是否让内核流量也从上述当前总量开始累计，默认为 `Y`。选择后内核对照值会从输入的总量继续增长，跨重启保留，下个统计周期自动归零；系统原始计数和 vnStat 数据库不会被修改。选择 `N` 则只显示本次开机的内核原始累计。

安装器会发送一封测试邮件。只有 SMTP 提交成功后才启用定时任务。授权码在终端输入时不显示，保存在仅 root 可读的 `/etc/traffic-monitor/smtp-password`；msmtp 配置保存在仅 root 可读的 `/root/.msmtprc-traffic-monitor`，以兼容 Debian 的 AppArmor 规则。请勿将这些文件提交到 GitHub。

## 查看与验证

```bash
status
sudo traffic-monitor --check
systemctl status traffic-monitor.timer
journalctl -u traffic-monitor.service -n 30 --no-pager
```

安装后的前几分钟，vnStat 可能尚无数据；如果填写了本周期已用总量，监控可先使用补录值，之后自动叠加 vnStat 实测流量。定时任务启动两分钟后首次检查，随后每五分钟检查一次；重复安装也会重新安排计时器。`--check` 只显示用量，不发送邮件或关机。更改统计重置日不会改写 vnStat 历史；非 1 日重置时请确认每日记录覆盖统计周期起点。

`status` 会将 vnStat 原始表格标为“不含手动补录”，并另行显示邮件监控用量、vnStat 含补录累计值与内核含补录累计值。邮件阶梯和流量上限以“vnStat 原始统计＋本周期补录”为唯一判断值；vnStat 表格中的 `estimated` 预测值不参与判断。

需要重新发送测试邮件时：

```bash
sudo traffic-monitor --test-mail
```

## 一键卸载

从仓库下载卸载脚本，查看内容后以 root 运行：

```bash
curl -fL -o uninstall_traffic_monitor.sh https://raw.githubusercontent.com/leovan0x13a/traffic-monitor/main/uninstall_traffic_monitor.sh
sudo bash uninstall_traffic_monitor.sh
```

输入 `YES` 后，脚本停止并禁用项目定时任务，删除项目程序、配置、SMTP 授权码和提醒状态；若安装时备份了原有 `status`，会将其恢复。机器时区保持当前设置，内核网卡计数不受影响。脚本最后询问是否卸载 `vnstat` 和 `msmtp` 软件包，只有输入 `PURGE` 才执行；软件包可能被其他程序使用。vnStat 的历史数据库默认保留。

## 文件位置

| 路径 | 用途 |
| --- | --- |
| `/usr/local/sbin/traffic-monitor` | 监控与邮件程序 |
| `/usr/local/bin/status` | 合并显示命令 |
| `/etc/traffic-monitor/` 与 `/root/.msmtprc-traffic-monitor` | 监控配置、SMTP 授权码与 msmtp 配置，仅 root 可读 |
| `/var/lib/traffic-monitor/state.json` | 本统计周期已发送提醒的记录 |
| `/var/lib/traffic-monitor/kernel-baseline.json` | 可选的内核流量补录与跨重启累计状态 |
| `/etc/systemd/system/traffic-monitor.timer` | 定时检查 |

若安装前已存在 `/usr/local/bin/status`，安装器会保留一次备份：`/usr/local/bin/status.traffic-monitor-backup`。

## 注意事项

- vnStat 实测用量加本周期补录值是提醒和关机的依据。内核累计值仅供对照，可从同一已用总量开始并跨重启继续。两种补录都只存在项目配置中，不修改 vnStat 数据库或 Linux 内核网卡计数。突然重启前尚未进入最近一次五分钟检查的少量内核流量可能无法补记。
- 若用量已经超过上限，选择 `shutdown` 后，定时检查会执行关机；重新开机后仍超限时也会再次关机。请先在 `alert` 模式核对计费口径。
- 邮件发送失败不会阻止已启用的自动关机；发送失败信息会进入 systemd 日志。
- SMTP 提交成功仅表示邮件服务器接收了邮件，不保证收件箱最终送达。
- 脚本不会从第三方 GitHub 仓库拉取额外代码；监控程序和 systemd 文件内嵌在安装器中。
