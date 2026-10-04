"""Root-only integration tests for disposable CI containers, never production."""
import json
import ipaddress
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile

SCRIPT = '/workspace/s5.sh'
STATE = pathlib.Path('/etc/s5-proxy/state.json')
CONF = pathlib.Path('/etc/s5-proxy/sockd.conf')


def invoke(command, expected=0, **changes):
    env = dict(os.environ)
    for key in ('PORT', 'PUBLIC_PORT', 'PUBLIC_HOST', 'S5_USER', 'S5_PASSWORD', 'REGEN', 'ADOPT_EXISTING'):
        env.pop(key, None)
    env.update({k: str(v) for k, v in changes.items()})
    p = subprocess.run(['sh', SCRIPT, command], env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=420)
    if p.returncode != expected:
        raise AssertionError('{}: expected {}, got {}\n{}'.format(command, expected, p.returncode, p.stdout))
    return p.stdout


def main():
    assert os.geteuid() == 0
    assert not STATE.exists(), 'Only run inside a disposable clean container'
    assert 'PORT' in invoke('install', expected=1, PUBLIC_HOST='127.0.0.1')
    assert '65535' in invoke('install', expected=1, PORT=65536, PUBLIC_HOST='127.0.0.1')
    assert 'PUBLIC_HOST' in invoke('install', expected=1, PORT=15432, PUBLIC_HOST='bad/host')
    # Includes special characters to check curl configuration escaping and URI encoding.
    password = 'CI-only-$pass&"\\word'
    invoke('install', PORT=15432, S5_PASSWORD=password)
    first = json.loads(STATE.read_text())
    assert first['password'] == password
    assert ipaddress.ip_address(first['public_host']).is_global
    assert first['public_port'] == first['port']
    assert STATE.stat().st_mode & 0o777 == 0o600
    assert STATE.parent.stat().st_mode & 0o777 == 0o700
    invoke('check')
    invoke('restart')
    invoke('status')
    print('PASS: install, permissions, positive/negative authentication, HTTPS, restart')
    invoke('install', PORT=15433, PUBLIC_PORT=25433, PUBLIC_HOST='127.0.0.1')
    second = json.loads(STATE.read_text())
    assert second['password'] == first['password'] and second['user'] == first['user']
    assert second['port'] == 15433 and second['public_port'] == 25433
    assert second['public_host'] == '127.0.0.1'
    invoke('check')
    print('PASS: changed internal/public ports, preserved credentials')
    before_conf, before_state = CONF.read_bytes(), STATE.read_bytes()
    with socket.socket() as busy:
        busy.bind(('0.0.0.0', 15434))
        busy.listen()
        assert '15434' in invoke('install', expected=1, PORT=15434)
    assert CONF.read_bytes() == before_conf and STATE.read_bytes() == before_state
    print('PASS: port conflict leaves running installation intact')
    # Fail the actual service restart after config/password changes, then let rollback run.
    manager = 'systemctl' if pathlib.Path('/run/systemd/system').is_dir() else ('rc-service' if shutil.which('rc-service') else None)
    if manager:
        with tempfile.TemporaryDirectory() as directory:
            wrapper = pathlib.Path(directory) / manager
            original = shutil.which(manager)
            marker = pathlib.Path(directory) / 'injected'
            text = '#!/bin/sh\ncase " $* " in *"s5-proxy"*"restart"*|*"restart"*"s5-proxy"*) if [ ! -f "{}" ]; then touch "{}"; echo "Injected restart failure"; exit 42; fi;; esac\nexec "{}" "$@"\n'.format(marker, marker, original)
            wrapper.write_text(text)
            wrapper.chmod(0o755)
            invoke('install', expected=1, PORT=15435, S5_PASSWORD='CI-only-new-password', PATH=directory + ':' + os.environ['PATH'])
        assert CONF.read_bytes() == before_conf and STATE.read_bytes() == before_state
        invoke('check')
        print('PASS: failed restart rolls back configuration, password, and running service')
    invoke('update')
    assert json.loads(STATE.read_text())['password'] == first['password']
    invoke('uninstall')
    assert not STATE.parent.exists()
    assert subprocess.run(['id', first['user']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
    print('PASS: update preserves credentials; uninstall removes only owned account/config')
    # Run the normal legacy daemon and verify the adoption / restoration path.
    alpine = pathlib.Path('/etc/alpine-release').exists()
    binary = '/usr/sbin/sockd' if alpine else '/usr/sbin/danted'
    if not pathlib.Path(binary).exists():
        binary = '/usr/local/lib/s5-proxy-core/danted'
    legacy = 'sockd' if alpine else 'danted'
    config = pathlib.Path('/etc/sockd.conf' if alpine else '/etc/danted.conf')
    routes = json.loads(subprocess.check_output(['ip', '-j', '-4', 'route', 'show', 'default'], text=True))
    iface = routes[0]['dev']
    config.write_text('logoutput: stderr\ninternal: 0.0.0.0 port = 15436\nexternal: {}\nsocksmethod: username\nclientmethod: none\nuser.privileged: root\nuser.unprivileged: nobody\nclient pass {{ from: 0.0.0.0/0 to: 0.0.0.0/0 }}\nsocks pass {{ from: 0.0.0.0/0 to: 0.0.0.0/0 command: connect }}\n'.format(iface))
    if alpine:
        subprocess.run(['rc-update', 'add', legacy, 'default'], check=True)
        subprocess.run(['rc-service', legacy, 'start'], check=True)
    else:
        if binary.startswith('/usr/local/'):
            pathlib.Path('/etc/systemd/system/danted.service').write_text('[Unit]\nDescription=Legacy Dante for adoption test\n[Service]\nExecStart={} -f /etc/danted.conf\n[Install]\nWantedBy=multi-user.target\n'.format(binary))
            subprocess.run(['systemctl', 'daemon-reload'], check=True)
        subprocess.run(['systemctl', 'enable', legacy], check=True)
        subprocess.run(['systemctl', 'start', legacy], check=True)
    original = config.read_bytes()
    invoke('install', expected=1, PORT=15436, PUBLIC_HOST='127.0.0.1')
    invoke('install', PORT=15436, PUBLIC_HOST='127.0.0.1', ADOPT_EXISTING=1)
    invoke('check')
    assert config.read_bytes() == original
    assert json.loads(STATE.read_text())['legacy']['name'] == legacy
    invoke('uninstall')
    assert config.read_bytes() == original
    if alpine:
        subprocess.run(['rc-service', legacy, 'status'], check=True)
        assert pathlib.Path('/etc/runlevels/default/sockd').exists()
        subprocess.run(['rc-service', legacy, 'stop'], check=True)
    else:
        subprocess.run(['systemctl', 'is-active', '--quiet', legacy], check=True)
        subprocess.run(['systemctl', 'is-enabled', '--quiet', legacy], check=True)
        subprocess.run(['systemctl', 'stop', legacy], check=True)
    print('PASS: adopt existing Dante, preserve files, restore legacy service on uninstall')


if __name__ == '__main__':
    main()
