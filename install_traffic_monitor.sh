#!/usr/bin/env bash
set -euo pipefail
umask 077

# Debian/Ubuntu installer. Run as root: bash install_traffic_monitor.sh
if [[ ${EUID} -ne 0 ]]; then
  echo '请以 root 身份运行。' >&2
  exit 1
fi
for cmd in apt-get systemctl timedatectl ip python3; do
  command -v "$cmd" >/dev/null || { echo "缺少命令: $cmd" >&2; exit 1; }
done

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y vnstat msmtp ca-certificates python3
systemctl enable --now vnstat.service

install -d -m 700 /etc/traffic-monitor /var/lib/traffic-monitor
cat > /usr/local/sbin/traffic-monitor <<'PYTHON'
#!/usr/bin/env python3
import argparse
import datetime as dt
import fcntl
import getpass
import json
import os
import re
import subprocess
import sys
import tempfile
from zoneinfo import available_timezones
from email.message import EmailMessage
from pathlib import Path

CONFIG = Path('/etc/traffic-monitor/config.json')
MSMTP = Path('/root/.msmtprc-traffic-monitor')
SECRET = Path('/etc/traffic-monitor/smtp-password')
STATE = Path('/var/lib/traffic-monitor/state.json')
LOCK = Path('/var/lib/traffic-monitor/lock')
KERNEL_BASE = Path('/var/lib/traffic-monitor/kernel-baseline.json')
KERNEL_LOCK = Path('/var/lib/traffic-monitor/kernel.lock')
GB = 1_000_000_000
os.umask(0o077)

class NoDataYet(RuntimeError):
    pass

def atomic_json(path, value):
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(value, out, ensure_ascii=False, indent=2)
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)

def ask(prompt, default=None):
    suffix = f' [{default}]' if default is not None else ''
    value = input(f'{prompt}{suffix}: ').strip()
    return value or default

def kernel(cfg):
    base = Path('/sys/class/net') / cfg['interface'] / 'statistics'
    return int((base / 'rx_bytes').read_text()) + int((base / 'tx_bytes').read_text())

def boot_id():
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()

def period_start(reset_day):
    today = dt.datetime.now().astimezone().date()
    start = dt.date(today.year, today.month, reset_day)
    if today < start:
        previous = today.replace(day=1) - dt.timedelta(days=1)
        start = dt.date(previous.year, previous.month, reset_day)
    return start

def kernel_period_total(cfg, period):
    raw = kernel(cfg)
    current_boot = boot_id()
    if not KERNEL_BASE.exists():
        return raw, '本次开机累计'
    with KERNEL_LOCK.open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        saved = json.loads(KERNEL_BASE.read_text())
        if saved.get('interface') != cfg['interface']:
            return raw, '本次开机累计'
        if 'total_bytes' not in saved:
            old_base = saved.get('bytes', 0)
            if saved.get('boot_id') == current_boot and raw >= old_base:
                displayed = raw - old_base
            else:
                displayed = raw
            includes_reported = False
        elif saved.get('period') != period:
            displayed = 0
            includes_reported = False
        else:
            displayed = int(saved.get('total_bytes', 0))
            previous_raw = int(saved.get('raw_bytes', raw))
            if saved.get('boot_id') == current_boot and raw >= previous_raw:
                displayed += raw - previous_raw
            else:
                # 重启或网卡计数归零后，从新计数继续累加。
                displayed += raw
            includes_reported = bool(saved.get('includes_reported_total'))
        atomic_json(KERNEL_BASE, {
            'interface': cfg['interface'], 'period': period,
            'boot_id': current_boot, 'raw_bytes': raw,
            'total_bytes': displayed,
            'includes_reported_total': includes_reported,
        })
    label = ('本统计周期累计（含补录）'
             if includes_reported else '本统计周期累计')
    return displayed, label

def configure():
    print('提示：[] 内为默认选项，直接按回车即可确认。')
    timezone = subprocess.check_output(
        ['timedatectl', 'show', '-p', 'Timezone', '--value'], text=True).strip() or 'UTC'
    print(f'当前机器时区：{timezone}')
    if ask('是否更改机器时区？y/N', 'N').lower() in ('y', 'yes'):
        selected = ask('新时区（如 Asia/Shanghai）')
        if selected not in available_timezones():
            raise ValueError('无效时区，请使用 IANA 时区名称')
        subprocess.run(['timedatectl', 'set-timezone', selected], check=True)
        subprocess.run(['systemctl', 'restart', 'vnstat.service'], check=True)
        print(f'时区已更改为 {selected}；vnStat 已有历史记录不会重新按新时区计算。')
    route = subprocess.check_output(['ip', '-o', '-4', 'route', 'show', 'default'], text=True)
    match = re.search(r'\bdev\s+(\S+)', route)
    default_iface = match.group(1) if match else None
    iface = ask('公网网卡', default_iface)
    if not iface or not Path('/sys/class/net', iface).is_dir():
        raise ValueError('网卡不存在')
    name = ask('主机标识', os.uname().nodename)
    reset_day = int(ask('每月流量统计重置日（1～28 日）', '1'))
    if not 1 <= reset_day <= 28:
        raise ValueError('重置日只能是 1～28 日')
    limit = float(ask('每个统计周期流量上限（十进制 GB）', '1000'))
    nodes = [float(x.strip()) for x in ask('提醒阶梯，逗号分隔（GB）', '50,100,200,300,400,500,600,700,800,900,950').split(',')]
    if limit <= 0 or any(x <= 0 or x >= limit for x in nodes):
        raise ValueError('阶梯必须大于 0 且小于熔断值')
    detected_bytes = 0
    try:
        _, detected_bytes = usage({'interface': iface, 'reset_day': reset_day})
    except NoDataYet:
        pass
    except RuntimeError as exc:
        if not str(exc).startswith('vnStat 中尚无网卡'):
            raise
    detected_gb = detected_bytes / GB
    print(f'vnStat 当前已记录本统计周期 {detected_gb:.3f} GB。')
    current_gb = float(ask('本统计周期当前已使用总流量（十进制 GB）',
                           f'{detected_gb:.3f}'))
    if current_gb < 0 or current_gb + 0.001 < detected_gb:
        raise ValueError('已使用总流量不能小于 vnStat 已记录的流量')
    supplement_gb = max(0.0, current_gb - detected_gb)
    supplement_period = period_start(reset_day).isoformat()
    action = ask('达限动作：alert=仅提醒，shutdown=关机', 'alert').lower()
    if action not in ('alert', 'shutdown'):
        raise ValueError('达限动作只能是 alert 或 shutdown')
    if action == 'shutdown' and ask('确认达限后自动关机？输入 YES', 'NO') != 'YES':
        raise ValueError('未确认自动关机')
    host = ask('SMTP 服务器', 'smtp.gmail.com')
    port = int(ask('SMTP 端口：587=STARTTLS，465=TLS', '587'))
    if port not in (465, 587):
        raise ValueError('目前仅支持端口 465 或 587')
    user = ask('发件邮箱/SMTP 用户名')
    recipient = ask('收件邮箱')
    if not host or not user or not recipient or not re.fullmatch(r'[A-Za-z0-9._-]+', host):
        raise ValueError('SMTP 信息不完整或服务器名无效')
    password = getpass.getpass('SMTP 应用密码或授权码（输入不显示）: ')
    if host.lower() == 'smtp.gmail.com':
        password = ''.join(password.split())
    if not password or '\n' in password:
        raise ValueError('SMTP 密码不能为空或包含换行')
    cfg = {'interface': iface, 'hostname': name, 'reset_day': reset_day,
           'limit_gb': limit,
           'nodes_gb': sorted(set(nodes)), 'action': action,
           'recipient': recipient,
           'supplement_gb': supplement_gb,
           'supplement_period': supplement_period}
    atomic_json(CONFIG, cfg)
    try:
        state = json.loads(STATE.read_text()) if STATE.exists() else {}
    except (OSError, json.JSONDecodeError):
        state = {}
    if state.get('period') != supplement_period:
        state = {'period': supplement_period, 'sent': [], 'limit_done': False}
    sent = set(state.get('sent', []))
    sent.update(str(node) for node in cfg['nodes_gb'] if node <= current_gb)
    state['sent'] = sorted(sent, key=float)
    state.setdefault('limit_done', False)
    atomic_json(STATE, state)
    if ask('是否让内核流量也从上述当前总量开始累计？Y/n', 'Y').lower() in ('y', 'yes'):
        atomic_json(KERNEL_BASE, {
            'interface': iface, 'period': supplement_period,
            'boot_id': boot_id(), 'raw_bytes': kernel(cfg),
            'total_bytes': round(current_gb * GB),
            'includes_reported_total': True,
        })
        print(f'内核对照值将从 {current_gb:.3f} GB 继续累加；系统原始计数不受影响。')
    else:
        KERNEL_BASE.unlink(missing_ok=True)
        print('内核对照值将仅显示本次开机累计。')
    SECRET.write_text(password + '\n')
    os.chmod(SECRET, 0o600)
    # msmtp 的密码文件仅 root 可读；凭据不放进进程参数或日志。
    msmtp = '\n'.join([
        'defaults', 'auth on', 'tls on',
        f'tls_starttls {"off" if port == 465 else "on"}',
        'tls_certcheck on', 'account default',
        f'host {host}', f'port {port}', f'from {user}', f'user {user}',
        f'passwordeval cat {SECRET}', ''
    ])
    MSMTP.write_text(msmtp)
    os.chmod(MSMTP, 0o600)
    print('配置已保存。先执行 traffic-monitor --test-mail 验证邮件。')

def load():
    return json.loads(CONFIG.read_text())

def send_mail(cfg, subject, body):
    msg = EmailMessage()
    # 发件地址从受限的 msmtp 配置中提取，避免在公开配置里重复存放。
    for line in MSMTP.read_text().splitlines():
        if line.startswith('from '):
            msg['From'] = line[5:]
            break
    msg['To'] = cfg['recipient']
    msg['Subject'] = subject
    msg.set_content(body)
    subprocess.run(['msmtp', '-C', str(MSMTP), '-t'], input=msg.as_bytes(), check=True)

def usage(cfg):
    iface = cfg['interface']
    raw = subprocess.check_output(['vnstat', '-i', iface, '--json'], text=True)
    data = json.loads(raw)
    interfaces = [x for x in data.get('interfaces', []) if x.get('name') == iface]
    if not interfaces:
        raise RuntimeError(f'vnStat 中尚无网卡 {iface} 的数据')
    today = dt.datetime.now().astimezone().date()
    day = cfg.get('reset_day', 1)
    start = period_start(day)
    traffic = interfaces[0].get('traffic', {})
    if day == 1:
        entries = [x for x in traffic.get('month', [])
                   if x.get('date', {}).get('year') == today.year
                   and x.get('date', {}).get('month') == today.month]
    else:
        entries = []
        for item in traffic.get('day', []):
            d = item.get('date', {})
            try:
                date = dt.date(d['year'], d['month'], d['day'])
            except (KeyError, ValueError):
                continue
            if start <= date <= today:
                entries.append(item)
        if entries and min(dt.date(x['date']['year'], x['date']['month'],
                                   x['date']['day']) for x in entries) > start:
            print('注意：vnStat 在本统计周期起始日之前没有每日记录，统计可能不完整。', file=sys.stderr)
    if not entries:
        raise NoDataYet('vnStat 尚无本统计周期数据，等待首次采集')
    return start.isoformat(), sum(int(x['rx']) + int(x['tx']) for x in entries)

def check(cfg, dry_run=False):
    try:
        period, count = usage(cfg)
    except NoDataYet as exc:
        period = period_start(cfg.get('reset_day', 1)).isoformat()
        if cfg.get('supplement_period') != period or cfg.get('supplement_gb', 0) <= 0:
            print(exc)
            return
        count = 0
    raw_used = count / GB
    supplement = (cfg.get('supplement_gb', 0.0)
                  if cfg.get('supplement_period') == period else 0.0)
    used = raw_used + supplement
    print(f'{cfg["hostname"]}: 邮件监控用量 {used:.3f} GB / {cfg["limit_gb"]:g} GB')
    if supplement > 0:
        print(f'vnStat 本统计周期累计（含补录）: {used:.3f} GB'
              f'（原始 {raw_used:.3f} + 补录 {supplement:.3f}）')
    else:
        print(f'vnStat 本统计周期累计: {used:.3f} GB')
    kernel_bytes, kernel_label = kernel_period_total(cfg, period)
    print(f'内核{kernel_label}: {kernel_bytes / GB:.3f} GB（系统原始计数，仅供对照）')
    if dry_run:
        return
    with LOCK.open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads(STATE.read_text()) if STATE.exists() else {}
        if state.get('period') != period:
            state = {'period': period, 'sent': [], 'limit_done': False}
            atomic_json(STATE, state)
        if used >= cfg['limit_gb']:
            if not state['limit_done']:
                try:
                    send_mail(cfg, f'流量达限：{cfg["hostname"]}',
                              f'主机：{cfg["hostname"]}\n已用：{used:.3f} GB\n上限：{cfg["limit_gb"]:g} GB\n动作：{cfg["action"]}')
                except Exception as exc:
                    print(f'达限邮件发送失败：{exc}', file=sys.stderr)
                else:
                    state['limit_done'] = True
                    atomic_json(STATE, state)
            if cfg['action'] == 'shutdown':
                subprocess.run(['/usr/sbin/shutdown', '-h', 'now'], check=True)
            return
        for node in cfg['nodes_gb']:
            key = str(node)
            if used >= node and key not in state['sent']:
                send_mail(cfg, f'流量提醒：{cfg["hostname"]} 达到 {node:g} GB',
                          f'主机：{cfg["hostname"]}\n已用：{used:.3f} GB\n提醒阶梯：{node:g} GB')
                state['sent'].append(key)
                atomic_json(STATE, state)

def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--configure', action='store_true')
    group.add_argument('--check', action='store_true', help='只显示，不发送邮件或关机')
    group.add_argument('--test-mail', action='store_true')
    args = parser.parse_args()
    if args.configure:
        configure()
    elif args.test_mail:
        cfg = load()
        send_mail(cfg, f'流量监控测试：{cfg["hostname"]}', 'SMTP 邮件发送测试成功。')
        print('测试邮件已提交给 SMTP 服务器。')
    else:
        check(load(), dry_run=args.check)

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError, KeyError, json.JSONDecodeError) as exc:
        print(f'流量监控错误：{exc}', file=sys.stderr)
        sys.exit(1)
PYTHON
chmod 700 /usr/local/sbin/traffic-monitor

traffic-monitor --configure
traffic-monitor --check
traffic-monitor --test-mail

cat > /etc/systemd/system/traffic-monitor.service <<'UNIT'
[Unit]
Description=Traffic threshold monitor
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/traffic-monitor
UNIT
cat > /etc/systemd/system/traffic-monitor.timer <<'UNIT'
[Unit]
Description=Check traffic every five minutes

[Timer]
OnActiveSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
if [[ -e /usr/local/bin/status && ! -e /usr/local/bin/status.traffic-monitor-backup ]]; then
  cp -a /usr/local/bin/status /usr/local/bin/status.traffic-monitor-backup
fi
cat > /usr/local/bin/status <<'STATUS'
#!/usr/bin/env bash
iface=$(python3 -c 'import json; print(json.load(open("/etc/traffic-monitor/config.json"))["interface"])')
reset_day=$(python3 -c 'import json; print(json.load(open("/etc/traffic-monitor/config.json")).get("reset_day", 1))')
echo "vnStat 原始记录："
if [[ "$reset_day" == 1 ]]; then
  vnstat -i "$iface" -m
else
  echo "统计周期每月 ${reset_day} 日重置；以下为每日原始值。"
  vnstat -i "$iface" -d
fi
echo
/usr/local/sbin/traffic-monitor --check
STATUS
chmod 755 /usr/local/bin/status
systemctl daemon-reload
systemctl enable traffic-monitor.timer
# 重复安装时计时器可能仍保持旧的 elapsed 状态；显式重启以重新安排下一次运行。
systemctl restart traffic-monitor.timer
echo '安装完成。运行 status 查看流量；运行 systemctl status traffic-monitor.timer 查看定时任务。'
