#!/bin/sh
# S5 proxy for Alpine / Debian / Ubuntu. No Bash or pip dependencies.
set -eu
umask 077

case "${1:-}" in
  -h|--help|help)
    cat <<'HELP'
Usage: sh s5.sh [install|info|status|check|restart|update|uninstall]
No argument: interactive menu (requires a terminal).
Install: PORT=54352 PUBLIC_PORT=54352 PUBLIC_HOST=example.com sh s5.sh install
Optional: S5_USER, S5_PASSWORD, EXTERNAL_IFACE, ADOPT_EXISTING=1, REGEN=1
PORT is mandatory for first installation. PUBLIC_PORT defaults to PORT.
SOCKS5 TCP CONNECT with username/password; UDP is intentionally disabled for NAT.
HELP
    exit 0 ;;
esac
[ "$(id -u)" = 0 ] || { echo '错误: 请使用 root 运行。' >&2; exit 1; }
[ -r /etc/os-release ] || { echo '错误: 缺少 /etc/os-release，无法识别系统。' >&2; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
ID=${ID:-unknown}
case "$ID" in
  alpine) command -v apk >/dev/null || { echo '错误: Alpine 缺少 apk。' >&2; exit 1; } ;;
  debian|ubuntu) command -v apt-get >/dev/null || { echo '错误: Debian/Ubuntu 缺少 apt-get。' >&2; exit 1; } ;;
  *) echo "错误: 不支持系统 $ID；仅支持 Alpine / Debian / Ubuntu。" >&2; exit 1 ;;
esac
if ! command -v python3 >/dev/null 2>&1; then
  echo '安装缺失依赖 python3 ...'
  if [ "$ID" = alpine ]; then
    apk add --no-cache python3 || { echo '错误: python3 安装失败；检查上面的 apk 错误、软件源、DNS、网络及磁盘空间。' >&2; exit 1; }
  else
    if ! apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update; then
      echo '错误: apt 软件源刷新失败；检查上面的软件源、DNS、网络及磁盘空间错误。' >&2
      exit 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 install -y --no-install-recommends python3; then
      echo '错误: python3 安装失败；检查上面的 apt 错误、软件源、锁、网络及磁盘空间。' >&2
      exit 1
    fi
  fi
fi
exec python3 - "$@" <<'PY'
import contextlib
import datetime
import getpass
import ipaddress
import json
import os
import pathlib
import pwd
import re
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse

BASE = pathlib.Path('/etc/s5-proxy')
CONF = BASE / 'sockd.conf'
STATE = BASE / 'state.json'
BACKUP = BASE / 'original'
LOG = pathlib.Path('/var/log/s5-proxy-installer.log')
SERVICE = 's5-proxy'
STAGE = '初始化'
OS_ID = ''
MANAGER = ''
BIN = ''
LOCK = None


class Failure(Exception):
    pass


def fail(message):
    raise Failure(message)


def say(message):
    print(message, flush=True)


def run(args, *, check=True, secret_input=None):
    # Never log credential input or put passwords in command arguments.
    with LOG.open('a', encoding='utf-8') as log:
        log.write('\n[' + STAGE + '] ' + ' '.join(args) + '\n')
        result = subprocess.run(args, input=secret_input, text=True, timeout=300,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                env=dict(os.environ, LC_ALL='C', DEBIAN_FRONTEND='noninteractive'))
        output = result.stdout or ''
        if secret_input is None:
            log.write(output)
        if result.returncode and check:
            # Package-manager / daemon diagnostics are retained, not swallowed.
            say(output[-16000:].rstrip())
            fail('命令失败 (exit={}): {}。详见 {}'.format(result.returncode, ' '.join(args), LOG))
    return result


def atomic(path, content, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '-', dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, str(path))
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def initialize():
    global OS_ID, MANAGER, BIN, LOCK
    import fcntl
    values = {}
    for line in pathlib.Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            values[k] = v.strip('"\'')
    OS_ID = values.get('ID', '')
    if OS_ID not in ('alpine', 'debian', 'ubuntu'):
        fail('不支持系统: ' + OS_ID)
    if os.geteuid() != 0:
        fail('请用 root 运行')
    os.umask(0o077)
    LOG.parent.mkdir(parents=True, exist_ok=True)
    LOG.touch(mode=0o600, exist_ok=True)
    LOG.chmod(0o600)
    LOCK = open('/run/s5-proxy-installer.lock', 'a')
    try:
        fcntl.flock(LOCK, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fail('另一个 s5 脚本正在运行，请等它结束后重试')
    if OS_ID == 'alpine':
        MANAGER, BIN = 'openrc', '/usr/sbin/sockd'
    elif pathlib.Path('/run/systemd/system').is_dir():
        MANAGER, BIN = 'systemd', '/usr/sbin/danted'
    else:
        MANAGER, BIN = 'sysv', '/usr/sbin/danted'
    if STATE.exists():
        BASE.chmod(0o700)


def load(required=True):
    if not STATE.exists():
        if required:
            fail('未找到本脚本管理的部署；请先运行 install。已有 sockd/danted 不会被误认为本脚本配置')
        return None
    try:
        state = json.loads(STATE.read_text())
        for key in ('port', 'public_port', 'public_host', 'user', 'password', 'interface'):
            if key not in state:
                fail('状态文件缺少字段 ' + key)
        if state.get('schema') != 1:
            fail('不支持的状态文件版本')
        return state
    except (ValueError, OSError) as e:
        fail('无法读取状态文件 {}: {}'.format(STATE, e))


def package_present(package):
    args = ['apk', 'info', '-e', package] if OS_ID == 'alpine' else ['dpkg-query', '-W', '-f=${Status}', package]
    result = run(args, check=False)
    return result.returncode == 0 and (OS_ID == 'alpine' or result.stdout.strip() == 'install ok installed')


def dependencies(update=False):
    global STAGE
    STAGE = '检测 / 安装系统依赖'
    packages = ['ca-certificates', 'curl', 'iproute2', 'dante-server']
    packages += ['openrc', 'shadow'] if OS_ID == 'alpine' else ['passwd', 'init-system-helpers']
    missing = [p for p in packages if not package_present(p)]
    if OS_ID == 'alpine':
        repositories = pathlib.Path('/etc/apk/repositories')
        lines = repositories.read_text().splitlines()
        urls = [x.strip() for x in lines if x.strip() and not x.lstrip().startswith('#')]
        if not any(u.rstrip('/').endswith('/community') for u in urls):
            main = next((u.rstrip('/') for u in urls if re.search(r'/v\d+\.\d+/main/?$', u)), None)
            if not main:
                fail('Alpine 缺少 community 软件源，且不能从 main 推导同版本地址；请检查 /etc/apk/repositories')
            say('补充同版本 Alpine community 软件源: ' + main[:-4] + 'community')
            shutil.copy2(str(repositories), str(repositories) + '.s5-backup')
            with repositories.open('a') as f:
                f.write('\n' + main[:-4] + 'community\n')
        if missing:
            say('安装缺失依赖: ' + ', '.join(missing))
            run(['apk', 'add', '--no-cache'] + missing)
        if update:
            run(['apk', 'upgrade', '--no-cache', 'dante-server'])
    else:
        if missing or update:
            say('刷新 apt 软件源；将安装: ' + ', '.join(missing or ['dante-server']))
            run(['apt-get', '-o', 'Acquire::Retries=3', '-o', 'Acquire::http::Timeout=30', '-o', 'Acquire::https::Timeout=30', 'update'])
            # Suppress only package auto-start, and preserve any administrator policy.
            policy = pathlib.Path('/usr/sbin/policy-rc.d')
            added_policy = not os.path.lexists(str(policy))
            if added_policy:
                atomic(policy, '#!/bin/sh\nexit 101\n', 0o755)
            try:
                run(['apt-get', '-o', 'DPkg::Lock::Timeout=60', '-o', 'Acquire::Retries=3',
                     'install', '-y', '--no-install-recommends'] + (missing or ['dante-server']))
            finally:
                if added_policy:
                    policy.unlink()
    commands = [BIN, 'curl', 'ip', 'useradd', 'userdel', 'chpasswd']
    commands += ['rc-service', 'rc-update'] if MANAGER == 'openrc' else (['systemctl'] if MANAGER == 'systemd' else ['start-stop-daemon', 'update-rc.d'])
    for command in commands:
        if not shutil.which(command):
            fail('依赖安装后仍找不到命令: ' + command)
    try:
        pwd.getpwnam('nobody')
    except KeyError:
        fail('系统缺少 nobody 低权限账户')


def service_file():
    return pathlib.Path('/etc/systemd/system/s5-proxy.service') if MANAGER == 'systemd' else pathlib.Path('/etc/init.d/s5-proxy')


def active(name=SERVICE):
    if MANAGER == 'systemd':
        return run(['systemctl', 'is-active', '--quiet', name], check=False).returncode == 0
    if MANAGER == 'openrc':
        return run(['rc-service', name, 'status'], check=False).returncode == 0
    return run(['/etc/init.d/' + name, 'status'], check=False).returncode == 0 if pathlib.Path('/etc/init.d/' + name).exists() else False


def enabled(name):
    if MANAGER == 'systemd':
        return run(['systemctl', 'is-enabled', '--quiet', name], check=False).returncode == 0
    if MANAGER == 'openrc':
        return (pathlib.Path('/etc/runlevels/default') / name).exists()
    return any(list(pathlib.Path('/etc/rc{}.d'.format(n)).glob('S*' + name)) for n in range(2, 6))


def svc(action, name=SERVICE, check=True):
    args = ['systemctl', action, name] if MANAGER == 'systemd' else (['rc-service', name, action] if MANAGER == 'openrc' else ['/etc/init.d/' + name, action])
    return run(args, check=check)


def autostart(enable, name=SERVICE, check=True):
    if MANAGER == 'systemd':
        args = ['systemctl', 'enable' if enable else 'disable', name]
    elif MANAGER == 'openrc':
        args = ['rc-update', 'add' if enable else 'del', name, 'default']
    else:
        if enable:
            run(['update-rc.d', name, 'defaults'], check=check)
        args = ['update-rc.d', name, 'enable' if enable else 'disable']
    return run(args, check=check)


def write_service():
    if MANAGER == 'systemd':
        text = '''[Unit]
Description=Authenticated SOCKS5 proxy (Dante)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart={binary} -f /etc/s5-proxy/sockd.conf
Restart=on-failure
RestartSec=3
UMask=0077
LimitNOFILE=8192
[Install]
WantedBy=multi-user.target
'''.format(binary=BIN)
        atomic(service_file(), text, 0o644)
        run(['systemctl', 'daemon-reload'])
    elif MANAGER == 'openrc':
        text = '''#!/sbin/openrc-run
description="Authenticated SOCKS5 proxy (Dante)"
command="/usr/sbin/sockd"
command_args="-f /etc/s5-proxy/sockd.conf"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
pidfile="/run/s5-proxy.pid"
output_log="/var/log/s5-proxy.log"
error_log="/var/log/s5-proxy.log"
start_pre() { "$command" -V -f /etc/s5-proxy/sockd.conf; }
depend() { need net; after firewall; use dns; }
'''
        atomic(service_file(), text, 0o755)
    else:
        text = '''#!/bin/sh
### BEGIN INIT INFO
# Provides:          s5-proxy
# Required-Start:    $network $remote_fs
# Required-Stop:     $network $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Authenticated SOCKS5 proxy
### END INIT INFO
set -eu
DAEMON=/usr/sbin/danted
PID=/run/s5-proxy.pid
case "$1" in
 start) "$DAEMON" -V -f /etc/s5-proxy/sockd.conf
        start-stop-daemon --start --quiet --background --make-pidfile --pidfile "$PID" --exec "$DAEMON" -- -f /etc/s5-proxy/sockd.conf ;;
 stop) start-stop-daemon --stop --quiet --retry TERM/10/KILL/5 --pidfile "$PID" --exec "$DAEMON" --oknodo; rm -f "$PID" ;;
 restart) "$0" stop; "$0" start ;;
 status) start-stop-daemon --status --pidfile "$PID" --exec "$DAEMON" ;;
 *) echo "Usage: $0 {start|stop|restart|status}" >&2; exit 2 ;;
esac
'''
        atomic(service_file(), text, 0o755)


def port_value(value, name):
    if not re.fullmatch(r'[0-9]{1,5}', str(value)) or not 1 <= int(value) <= 65535:
        fail(name + ' 必须是 1–65535 的整数')
    return int(value)


def host_value(value):
    if not value:
        fail('请指定 PUBLIC_HOST=公网 IPv4 或域名；NAT 出口 IP 不一定是入站映射 IP')
    try:
        if ipaddress.ip_address(value).version != 4:
            fail('当前监听为 IPv4，请填写公网 IPv4 或具有 A 记录的域名')
    except ValueError:
        if len(value) > 253 or not all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', x) for x in value.split('.')):
            fail('PUBLIC_HOST 不是合法 IPv4 / 域名')
    return value


def settings(old):
    old = old or {}
    port = port_value(os.environ.get('PORT', str(old.get('port', ''))), 'PORT (内网监听端口)')
    public_port = port_value(os.environ.get('PUBLIC_PORT', str(old.get('public_port', port))), 'PUBLIC_PORT (外网映射端口)')
    host = host_value(os.environ.get('PUBLIC_HOST', old.get('public_host', '')))
    user = os.environ.get('S5_USER', old.get('user', 's5proxy'))
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,30}', user) or user in ('root', 'nobody'):
        fail('S5_USER 必须是有效的小写 Linux 用户名，不能用 root / nobody')
    if old and user != old['user']:
        fail('已部署后不能直接更改 S5_USER；请先卸载再安装')
    password = os.environ.get('S5_PASSWORD')
    if password is None:
        password = old.get('password') if os.environ.get('REGEN', '0') != '1' else None
        password = password or secrets.token_urlsafe(24)
    if not 8 <= len(password.encode('utf-8')) <= 128 or any(c in password for c in '\n\r\x00:'):
        fail('S5_PASSWORD 必须是 8–128 字节，不能含冒号、换行或 NUL')
    interface = os.environ.get('EXTERNAL_IFACE', old.get('interface', ''))
    if not interface:
        routes = json.loads(run(['ip', '-j', '-4', 'route', 'show', 'default']).stdout)
        routes.sort(key=lambda r: int(r.get('metric', 0)))
        interface = next((r.get('dev') for r in routes if r.get('dev')), '')
    if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', interface) or not (pathlib.Path('/sys/class/net') / interface).exists():
        fail('无法检测有效出口网卡；请设置 EXTERNAL_IFACE=eth0 等实际网卡名称')
    return dict(schema=1, port=port, public_port=public_port, public_host=host,
                user=user, password=password, interface=interface,
                account_created=old.get('account_created', False), legacy=old.get('legacy'))


def configuration(state):
    return '''# Managed by axixiansheng/s5-proxy
logoutput: stderr
internal: 0.0.0.0 port = {port}
external: {interface}
socksmethod: username
clientmethod: none
user.privileged: root
user.unprivileged: nobody
timeout.negotiate: 30
client pass {{
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}}
socks pass {{
    from: 0.0.0.0/0 to: 0.0.0.0/0
    user: {user}
    command: connect
    protocol: tcp
    socksmethod: username
    log: error
}}
socks block {{
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}}
'''.format(**state)


def listeners(port):
    output = run(['ss', '-H', '-ltnp', 'sport = :{}'.format(port)]).stdout.strip()
    return output


def recv_exact(sock, count):
    data = b''
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            fail('SOCKS 连接被关闭')
        data += chunk
    return data


def socks_test(state, bad_password=False, anonymous=False):
    with socket.create_connection(('127.0.0.1', state['port']), timeout=5) as sock:
        sock.sendall(b'\x05\x01\x00' if anonymous else b'\x05\x01\x02')
        response = recv_exact(sock, 2)
        if anonymous:
            if response != b'\x05\xff':
                fail('匿名访问没有被拒绝')
            return
        if response != b'\x05\x02':
            fail('SOCKS 未选择用户名密码认证: ' + response.hex())
        user = state['user'].encode()
        password = ('invalid-' + secrets.token_hex(8) if bad_password else state['password']).encode()
        sock.sendall(b'\x01' + bytes([len(user)]) + user + bytes([len(password)]) + password)
        response = recv_exact(sock, 2)
        if bad_password:
            if response[1] == 0:
                fail('错误密码没有被拒绝')
        elif response != b'\x01\x00':
            fail('SOCKS 用户名密码认证失败: ' + response.hex())


def health(state):
    global STAGE
    STAGE = '验证服务 / 监听 / 认证'
    last = ''
    for _ in range(15):
        try:
            if not active():
                fail('服务未运行')
            if not listeners(state['port']):
                fail('端口尚未监听')
            socks_test(state)
            socks_test(state, bad_password=True)
            socks_test(state, anonymous=True)
            return
        except (Failure, OSError) as e:
            last = str(e)
            time.sleep(1)
    diagnostics()
    fail('启动验证失败: ' + last)


def diagnostics():
    if MANAGER == 'systemd':
        result = run(['journalctl', '-u', SERVICE, '-n', '35', '--no-pager'], check=False)
        say(result.stdout[-12000:])
    elif pathlib.Path('/var/log/s5-proxy.log').exists():
        say(pathlib.Path('/var/log/s5-proxy.log').read_text(errors='replace')[-12000:])


def show_info(state=None):
    state = state or load()
    uri = 'socks5://{}:{}@{}:{}'.format(urllib.parse.quote(state['user'], safe=''),
            urllib.parse.quote(state['password'], safe=''), state['public_host'], state['public_port'])
    say('\n地址: {}\n外网端口: {}\n内网监听: {}\n用户名: {}\n密码: {}\n协议: SOCKS5 TCP / 用户名密码\n\nURI (是否可导入取决于客户端):\n{}'.format(
        state['public_host'], state['public_port'], state['port'], state['user'], state['password'], uri))
    say('\nNAT 面板需映射 TCP {} → 本机 {}。脚本不会修改供应商映射或防火墙。'.format(state['public_port'], state['port']))


def install():
    global STAGE
    old = load(False)
    # Validate required inputs before installing additional packages.
    port_value(os.environ.get('PORT', str((old or {}).get('port', ''))), 'PORT (首次安装必须指定)')
    host_value(os.environ.get('PUBLIC_HOST', (old or {}).get('public_host', '')))
    dependencies()
    state = settings(old)
    STAGE = '检测账户 / 端口冲突'
    try:
        existing_user = pwd.getpwnam(state['user'])
    except KeyError:
        existing_user = None
    if existing_user and not (old and old.get('account_created')):
        fail('账户 {} 已存在且不由本脚本创建；请用 S5_USER 指定新用户名，避免修改已有账户密码'.format(state['user']))
    if not old and service_file().exists():
        fail('独立服务文件已存在且缺少状态文件，拒绝覆盖: ' + str(service_file()))
    occupied = listeners(state['port'])
    legacy = 'sockd' if OS_ID == 'alpine' else 'danted'
    if occupied and not (old and state['port'] == old['port'] and active()):
        if os.environ.get('ADOPT_EXISTING') != '1' or not active(legacy):
            fail('端口 {} 已占用:\n{}\n若是现有 Dante，可显式设置 ADOPT_EXISTING=1 迁移；其他服务请换端口'.format(state['port'], occupied))
        owners = re.findall(r'\("([^\"]+)"', occupied)
        if not owners or any(p not in ('sockd', 'danted') for p in owners):
            fail('占用端口的进程不是 Dante，拒绝迁移:\n' + occupied)
        legacy_enabled = enabled(legacy)
        state['legacy'] = dict(name=legacy, active=True, enabled=legacy_enabled)
    with tempfile.TemporaryDirectory(prefix='s5-transaction-', dir='/run') as tmp:
        temp = pathlib.Path(tmp)
        candidate = temp / 'sockd.conf'
        atomic(candidate, configuration(state))
        STAGE = '校验 Dante 配置'
        run([BIN, '-V', '-f', str(candidate)])
        tracked = [CONF, STATE, service_file()]
        snapshot = {str(p): (p.read_bytes(), p.stat().st_mode & 0o777) if p.exists() else None for p in tracked}
        was_active = active()
        was_enabled = enabled(SERVICE)
        saved_shadow = None
        if existing_user:
            saved_shadow = next((x.split(':')[1] for x in pathlib.Path('/etc/shadow').read_text().splitlines() if x.split(':')[0] == state['user']), None)
        created = False
        stopped_legacy = False
        try:
            BASE.mkdir(mode=0o700, exist_ok=True)
            BASE.chmod(0o700)
            if state.get('legacy') and not old:
                BACKUP.mkdir(mode=0o700, exist_ok=True)
                for p in (pathlib.Path('/etc/sockd.conf'), pathlib.Path('/etc/danted.conf'), pathlib.Path('/etc/init.d/' + legacy)):
                    if p.exists():
                        shutil.copy2(str(p), str(BACKUP / p.name))
                atomic(BACKUP / 'legacy.json', json.dumps(state['legacy'], indent=2) + '\n')
            STAGE = '创建专用 S5 账户'
            if not existing_user:
                shell = '/sbin/nologin' if pathlib.Path('/sbin/nologin').exists() else '/usr/sbin/nologin'
                run(['useradd', '--system', '--no-create-home', '--shell', shell, '--comment', 'Managed by s5-proxy', state['user']])
                created = True
                state['account_created'] = True
            run(['chpasswd'], secret_input=state['user'] + ':' + state['password'] + '\n')
            STAGE = '切换配置 / 服务'
            atomic(CONF, configuration(state))
            write_service()
            if state.get('legacy') and active(legacy):
                svc('stop', legacy)
                stopped_legacy = True
                autostart(False, legacy)
            autostart(True)
            svc('restart' if was_active else 'start')
            health(state)
            atomic(STATE, json.dumps(state, ensure_ascii=False, indent=2) + '\n')
        except BaseException:
            say('部署失败，正在恢复变更前的配置、账户和服务 ...')
            svc('stop', check=False)
            autostart(False, check=False)
            for p in tracked:
                before = snapshot[str(p)]
                if before is None:
                    if p.exists():
                        p.unlink()
                else:
                    atomic(p, before[0].decode(), before[1])
            if MANAGER == 'systemd':
                run(['systemctl', 'daemon-reload'], check=False)
            if saved_shadow is not None:
                run(['chpasswd', '-e'], secret_input=state['user'] + ':' + saved_shadow + '\n', check=False)
            if created:
                run(['userdel', state['user']], check=False)
            if was_enabled:
                autostart(True, check=False)
            if was_active:
                svc('start', check=False)
            if stopped_legacy:
                if state['legacy']['enabled']:
                    autostart(True, legacy, check=False)
                svc('start', legacy, check=False)
            raise
    say('部署成功：服务运行、端口监听、正确密码认证、错误密码及匿名拒绝均已验证。')
    show_info(state)


def check():
    global STAGE
    state = load()
    health(state)
    STAGE = '验证 SOCKS5 出站 HTTPS / 远端 DNS'
    # Curl reads credentials from a 0600 file, not process arguments.
    with tempfile.TemporaryDirectory(prefix='s5-check-', dir='/run') as tmp:
        path = pathlib.Path(tmp) / 'curl.conf'
        escaped = (state['user'] + ':' + state['password']).replace('\\', '\\\\').replace('"', '\\"')
        atomic(path, 'proxy = "socks5h://127.0.0.1:{}"\nproxy-user = "{}"\nnoproxy = ""\n'.format(state['port'], escaped))
        result = run(['curl', '--config', str(path), '--fail', '--silent', '--show-error',
                      '--connect-timeout', '10', '--max-time', '25', 'https://api.ipify.org'])
        try:
            ipaddress.ip_address(result.stdout.strip())
        except ValueError:
            fail('出站检查返回的不是 IP 地址')
    say('通过：SOCKS5 认证、拒绝匿名和错误密码、远端 DNS、HTTPS 出站。出口 IP: ' + result.stdout.strip())
    say('此项检查走本机代理；外网映射需从另一台机器连接 {}:{} 验证。'.format(state['public_host'], state['public_port']))


def uninstall():
    global STAGE
    state = load()
    STAGE = '卸载本脚本管理的服务 / 账户'
    svc('stop')
    autostart(False)
    service_file().unlink()
    if MANAGER == 'systemd':
        run(['systemctl', 'daemon-reload'])
    elif MANAGER == 'sysv':
        run(['update-rc.d', SERVICE, 'remove'])
    if state.get('account_created'):
        run(['userdel', state['user']])
    legacy = state.get('legacy')
    if legacy:
        if legacy['enabled']:
            autostart(True, legacy['name'])
        if legacy['active']:
            svc('start', legacy['name'])
    # Only delete this script's fixed directory. Shared distro packages stay installed.
    shutil.rmtree(str(BASE))
    say('已卸载本脚本服务、配置和专用账户。' + (' 已恢复原 Dante 服务。' if legacy else ''))


def menu():
    try:
        terminal = open('/dev/tty', 'r+')
    except OSError:
        fail('无交互终端；请指定命令，例如 PORT=54352 PUBLIC_HOST=你的公网IP sh s5.sh install')
    with terminal:
        terminal.write('\nS5 一键脚本 — {}/{}\n1) 安装 / 修改配置\n2) 查看信息\n3) 状态\n4) 连通检查\n5) 更新 Dante\n6) 重启\n7) 卸载\n0) 退出\n选择: '.format(OS_ID, MANAGER))
        terminal.flush()
        choice = terminal.readline().strip()
        command = {'1': 'install', '2': 'info', '3': 'status', '4': 'check', '5': 'update', '6': 'restart', '7': 'uninstall', '0': 'exit'}.get(choice)
        if command is None:
            fail('无效选择')
        if command == 'install':
            old = load(False) or {}
            for key, label, default in (('PORT', '内网监听端口', old.get('port', '')),
                                       ('PUBLIC_PORT', '外网映射端口', old.get('public_port', os.environ.get('PORT', ''))),
                                       ('PUBLIC_HOST', '公网 IPv4 / 域名', old.get('public_host', ''))):
                if key in os.environ:
                    continue
                if key == 'PUBLIC_PORT' and not default:
                    default = os.environ.get('PORT', '')
                terminal.write('{} [{}]: '.format(label, default))
                terminal.flush()
                os.environ[key] = terminal.readline().strip() or str(default)
        if command == 'uninstall':
            terminal.write('卸载本脚本服务及专用账户？输入 yes: ')
            terminal.flush()
            if terminal.readline().strip() != 'yes':
                say('已取消')
                return 'exit'
        return command


def main():
    global STAGE
    initialize()
    if len(sys.argv) > 2:
        fail('每次只支持一个命令；运行 sh s5.sh --help 查看用法')
    command = sys.argv[1] if len(sys.argv) > 1 else menu()
    if command == 'install':
        install()
    elif command == 'info':
        show_info()
    elif command == 'status':
        state = load()
        say('服务: {} / {}\n监听端口: {}'.format(SERVICE, MANAGER, state['port']))
        result = svc('status', check=False)
        say(result.stdout.rstrip())
        say(listeners(state['port']))
        if not active():
            diagnostics()
            fail('服务未运行')
    elif command == 'check':
        check()
    elif command == 'restart':
        state = load()
        svc('restart' if active() else 'start')
        health(state)
        say('已重启并验证认证')
    elif command == 'update':
        state = load()
        dependencies(update=True)
        run([BIN, '-V', '-f', str(CONF)])
        svc('restart' if active() else 'start')
        health(state)
        say('Dante 已按系统软件源更新；端口和账户保留。软件包版本不会自动降级')
    elif command == 'uninstall':
        uninstall()
    elif command == 'exit':
        return
    else:
        fail('未知命令: ' + command + '；运行 sh s5.sh --help 查看用法')


def interrupted(signum, frame):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, interrupted)
try:
    main()
except KeyboardInterrupt:
    say('错误: 操作被中断；阶段: ' + STAGE)
    sys.exit(130)
except Exception as error:
    say('错误: {}\n失败阶段: {}\n诊断日志: {}'.format(error, STAGE, LOG))
    sys.exit(1)
PY
