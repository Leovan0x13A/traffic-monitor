#!/usr/bin/env bash
set -euo pipefail

# 仅清理本项目创建的文件。以 root 运行：bash uninstall_traffic_monitor.sh
if [[ ${EUID} -ne 0 ]]; then
  echo '请以 root 身份运行。' >&2
  exit 1
fi
if ! command -v systemctl >/dev/null; then
  echo '缺少 systemctl，无法安全停止定时任务。' >&2
  exit 1
fi

echo '即将停止 traffic-monitor 定时任务，并删除本项目的程序、配置、SMTP 授权码和提醒状态。'
read -r -p '确认卸载？输入 YES: ' confirmation
if [[ "$confirmation" != 'YES' ]]; then
  echo '已取消。'
  exit 0
fi

systemctl stop traffic-monitor.timer traffic-monitor.service 2>/dev/null || true
if systemctl is-active --quiet traffic-monitor.timer || systemctl is-active --quiet traffic-monitor.service; then
  echo 'traffic-monitor 服务仍在运行，已停止卸载以避免留下活动任务。' >&2
  exit 1
fi
systemctl disable traffic-monitor.timer 2>/dev/null || true
rm -f -- /etc/systemd/system/traffic-monitor.timer /etc/systemd/system/traffic-monitor.service
systemctl daemon-reload
systemctl reset-failed traffic-monitor.timer traffic-monitor.service 2>/dev/null || true

status_file=/usr/local/bin/status
status_backup=/usr/local/bin/status.traffic-monitor-backup
if [[ -f "$status_file" ]] && grep -Fq '/usr/local/sbin/traffic-monitor --check' "$status_file"; then
  if [[ -e "$status_backup" ]]; then
    mv -- "$status_backup" "$status_file"
    echo '已恢复安装前的 status 命令。'
  else
    rm -f -- "$status_file"
    echo '已删除本项目创建的 status 命令。'
  fi
elif [[ -e "$status_backup" ]]; then
  echo '检测到 status 已被修改，保留现有文件和备份，请手动核对。' >&2
fi

rm -f -- /usr/local/sbin/traffic-monitor /root/.msmtprc-traffic-monitor
rm -rf -- /etc/traffic-monitor /var/lib/traffic-monitor
echo '项目文件、邮件授权码和项目状态已清除。'

if command -v dpkg-query >/dev/null && command -v apt-get >/dev/null; then
  read -r -p '是否同时卸载 vnstat 和 msmtp 软件包？其他程序可能也在使用它们；输入 PURGE 才执行: ' purge
  if [[ "$purge" == 'PURGE' ]]; then
    apt-get purge -y vnstat msmtp
    echo 'vnstat 和 msmtp 软件包已卸载。'
  else
    echo '已保留 vnstat 和 msmtp 软件包及 vnStat 历史数据库。'
  fi
fi
echo '卸载完成。机器时区保持当前设置。'
