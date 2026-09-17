#!/usr/bin/env bash
set -euo pipefail
umask 077

# Debian/Ubuntu installer. Run as root: bash install_traffic_monitor.sh
if [[ ${EUID} -ne 0 ]]; then
  echo '请以 root 身份运行。' >&2
  exit 1
fi
for cmd in apt-get systemctl ip python3; do
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
from email.message import EmailMessage
from pathlib import Path

CONFIG = Path('/etc/traffic-monitor/config.json')
MSMTP = Path('/etc/traffic-monitor/msmtprc')
SECRET = Path('/etc/traffic-monitor/smtp-password')
STATE = Path('/var/lib/traffic-monitor/state.json')
LOCK = Path('/var/lib/traffic-monitor/lock')
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

def configure():
    route = subprocess.check_output(['ip', '-o', '-4', 'route', 'show', 'default'], text=True)
    match = re.search(r'\bdev\s+(\S+)', route)
    default_iface = match.group(1) if match else None
    iface = ask('公网网卡', default_iface)
    if not iface or not Path('/sys/class/net', iface).is_dir():
        raise ValueError('网卡不存在')
    name = ask('主机标识', os.uname().nodename)
    limit = float(ask('每自然月熔断值（十进制 GB）', '1000'))
    nodes = [float(x.strip()) for x in ask('提醒阶梯，逗号分隔（GB）', '50,100,200,300,400,500,600,700,800,900,950').split(',')]
    if limit <= 0 or any(x <= 0 or x >= limit for x in nodes):
        raise ValueError('阶梯必须大于 0 且小于熔断值')
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
    recipient = ask('收件邮箱', user)
    if not host or not user or not recipient or not re.fullmatch(r'[A-Za-z0-9._-]+', host):
        raise ValueError('SMTP 信息不完整或服务器名无效')
    password = getpass.getpass('SMTP 应用密码或授权码（输入不显示）: ')
    if not password or '\n' in password:
        raise ValueError('SMTP 密码不能为空或包含换行')
    cfg = {'interface': iface, 'hostname': name, 'limit_gb': limit,
           'nodes_gb': sorted(set(nodes)), 'action': action,
           'recipient': recipient}
    atomic_json(CONFIG, cfg)
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
    raw = subprocess.check_output(['vnstat', '-i', iface, '--json', 'm'], text=True)
    data = json.loads(raw)
    interfaces = [x for x in data.get('interfaces', []) if x.get('name') == iface]
    if not interfaces:
        raise RuntimeError(f'vnStat 中尚无网卡 {iface} 的数据')
    today = dt.datetime.now().astimezone().date()
    months = interfaces[0].get('traffic', {}).get('month', [])
    current = [x for x in months if x.get('date', {}).get('year') == today.year
               and x.get('date', {}).get('month') == today.month]
    if not current:
        raise NoDataYet('vnStat 尚无本月数据，等待首次采集')
    item = current[-1]
    return today.strftime('%Y-%m'), int(item['rx']) + int(item['tx'])

def kernel(cfg):
    base = Path('/sys/class/net') / cfg['interface'] / 'statistics'
    return int((base / 'rx_bytes').read_text()) + int((base / 'tx_bytes').read_text())

def check(cfg, dry_run=False):
    try:
        period, count = usage(cfg)
    except NoDataYet as exc:
        print(exc)
        return
    used = count / GB
    print(f'{cfg["hostname"]}: {period} 已用 {used:.3f} GB / {cfg["limit_gb"]:g} GB')
    print(f'内核本次开机累计: {kernel(cfg) / GB:.3f} GB（仅供对照）')
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
                              f'主机：{cfg["hostname"]}\n账期：{period}\n已用：{used:.3f} GB\n上限：{cfg["limit_gb"]:g} GB\n动作：{cfg["action"]}')
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
                          f'主机：{cfg["hostname"]}\n账期：{period}\n已用：{used:.3f} GB\n提醒阶梯：{node:g} GB')
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
OnBootSec=2min
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
vnstat -i "$(python3 -c 'import json; print(json.load(open("/etc/traffic-monitor/config.json"))["interface"])')" -m
echo
/usr/local/sbin/traffic-monitor --check
STATUS
chmod 755 /usr/local/bin/status
systemctl daemon-reload
systemctl enable --now traffic-monitor.timer
echo '安装完成。运行 status 查看流量；运行 systemctl status traffic-monitor.timer 查看定时任务。'
