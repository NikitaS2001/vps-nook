"""Production SSH recovery tasks with mocked systemd; real SSH is a VM gate."""
import copy
import socket
import yaml
import pytest
from tests.support import run

pytestmark = pytest.mark.quick

@pytest.mark.parametrize("active", [False, True], ids=["before-activation", "after-activation"])
@pytest.mark.parametrize("socket_active", [False, True], ids=["socket-inactive", "socket-active"])
def test_ssh_recovery_mocked_systemd(active, socket_active, source_root, tmp_path, log_dir, request):
    root, temp = source_root, tmp_path
    tasks = yaml.safe_load((root / 'roles/vps_hardening/tasks/ssh.yml').read_text())
    transaction = next(task for task in tasks if 'rescue' in task)
    assert tasks[0]['ansible.builtin.file']['path'] == '/run/sshd'
    assert transaction['block'][0]['ansible.builtin.template']['validate'] == '/usr/sbin/sshd -t -f %s'
    snapshot = next(task for task in tasks if task['name'] == 'SSH | Snapshot | Preserve recovery state')
    address = '127.0.0.2' if active else '127.0.0.1'
    ssh_service_name = 'ssh.service' if socket_active else 'ssh'
    with socket.socket() as listener:
        listener.bind((address, 0))
        listener.listen()
        port = listener.getsockname()[1]
        config = temp / 'sshd_config'
        backup = temp / 'sshd_config.backup'
        config.write_text('candidate' if active else 'original')
        backup.write_text('original')
        recovery = copy.deepcopy(transaction['rescue'])
        for task in recovery:
            if 'ansible.builtin.copy' in task:
                task['ansible.builtin.copy']['dest'] = str(config)
                task['ansible.builtin.copy'].pop('validate')
            if 'ansible.builtin.systemd_service' in task:
                # Render real production arguments and conditions without changing the host.
                settings = task.pop('ansible.builtin.systemd_service')
                task['ansible.builtin.debug'] = {'msg': settings}
                task['register'] = 'recovery_service' if settings['name'] == '{{ ssh_service_name }}' else 'recovery_socket'
                expected_name = ssh_service_name if task['register'] == 'recovery_service' else 'ssh.socket'
                expected = 'started' if socket_active else 'restarted'
                if 'Release listeners' in task['name']:
                    expected = 'stopped'
                if task['register'] == 'recovery_socket':
                    expected = 'started' if socket_active else 'stopped'
                register = 'service' if task['register'] == 'recovery_service' else 'socket'
                task['failed_when'] = (
                    f"recovery_{register}.msg.name != '{expected_name}' or "
                    f"recovery_{register}.msg.state != '{expected}'")
        variables = {
            'ansible_connection': 'local',
            'ssh_service_name': ssh_service_name, 'ssh_socket_name': 'ssh.socket',
            'vps_hardening_manage_ssh_socket': True,
            'vps_hardening_original_sshd': {'stdout_lines': ['port 22']},
            'vps_hardening_original_listeners': {'stdout_lines': [
                f'LISTEN 0     128    {address}:{port}     0.0.0.0:* users:(("sshd",pid=1,fd=3))']},
            'vps_hardening_original_socket_properties': {'stdout_lines': ['LoadState=loaded',
                f'ActiveState={"active" if socket_active else "inactive"}',
                f'UnitFileState={"enabled" if socket_active else "disabled"}']},
            'ansible_facts': {'services': {'ssh.service': {'state': 'running', 'status': 'enabled'}}},
            'vps_hardening_sshd_config': {'backup_file': str(backup)} if active else {},
            'expected_listeners': [{'address': address, 'port': port}],
        }
        play = [{'hosts': 'localhost', 'gather_facts': False, 'vars': variables, 'tasks': [
            next(task for task in tasks if task['name'] == 'SSH | Snapshot | Normalize SSH service fact key'),
            snapshot,
            next(task for task in tasks if task['name'] == 'SSH | Snapshot | Initialize original SSH listeners'),
            next(task for task in tasks if task['name'] == 'SSH | Snapshot | Preserve listeners from active sshd'),
            {'ansible.builtin.assert': {'that': [
                "vps_hardening_ssh_service_fact_name == 'ssh.service'",
                'vps_hardening_original_ssh_service.state == "running"',
                'vps_hardening_original_ssh_listeners == expected_listeners']}},
            {'ansible.builtin.set_fact': {'vps_hardening_ssh_activation_started': active}},
            {'block': [{'ansible.builtin.command': '/bin/false', 'changed_when': False}], 'rescue': recovery},
        ]}]
        path = temp / 'play.yml'
        path.write_text(yaml.safe_dump(play))
        log = log_dir / (request.node.name + ".log")
        run(['ansible-playbook', '-i', 'localhost,', '-c', 'local', str(path)],
            cwd=source_root, log=log, timeout=45, expected=2)
        output = log.read_text()
        assert 'undefined' not in output
        message = 'previous configuration and service state were restored' if active else 'before activation'
        assert message in output
        assert config.read_text() == 'original'


def test_ssh_snapshot_preserves_listener_endpoints(source_root, tmp_path, log_dir):
    tasks = yaml.safe_load((source_root / 'roles/vps_hardening/tasks/ssh.yml').read_text())
    names = {
        'SSH | Snapshot | Normalize SSH service fact key',
        'SSH | Snapshot | Preserve recovery state',
        'SSH | Snapshot | Initialize original SSH listeners',
        'SSH | Snapshot | Preserve listeners from active sshd',
        'SSH | Snapshot | Preserve listeners from active socket',
        'SSH | Snapshot | Preserve listeners from sshd configuration',
        'SSH | Snapshot | Preserve loopback ports from sshd configuration',
        'SSH | Snapshot | Require original recovery listeners',
    }
    snapshot_tasks = [task for task in tasks if task['name'] in names]
    expected_listeners = [
        {'address': '127.0.0.2', 'port': 2202},
        {'address': '0.0.0.0', 'port': 22},
        {'address': '::1', 'port': 2222},
        {'address': '::', 'port': 22},
    ]
    variables = {
        'ssh_service_name': 'ssh.service',
        'vps_hardening_original_listeners': {'stdout_lines': [
            'LISTEN 0 128 127.0.0.2:2202 0.0.0.0:* users:(("sshd",pid=1,fd=3))',
            'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=4))',
            'LISTEN 0 128 [::1]:2222 [::]:* users:(("sshd",pid=1,fd=5))',
            'LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=1,fd=6))',
            'LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=1,fd=7))',
        ]},
        'vps_hardening_original_socket_properties': {'stdout_lines': [
            'LoadState=loaded', 'ActiveState=active', 'UnitFileState=enabled', 'Listen=*:2022 (Stream)']},
        'vps_hardening_original_sshd': {'stdout_lines': ['listenaddress 127.0.0.9:2022', 'port 2022']},
        'ansible_facts': {'services': {'ssh.service': {'state': 'running', 'status': 'enabled'}}},
        'expected_listeners': expected_listeners,
    }
    play = [{'hosts': 'localhost', 'gather_facts': False, 'vars': variables, 'tasks': [
        *snapshot_tasks,
        {'ansible.builtin.assert': {'that': [
            'vps_hardening_original_ssh_listeners == expected_listeners',
            'vps_hardening_original_ssh_listeners | map(attribute="port") | map("type_debug") | list == ["int", "int", "int", "int"]',
            'vps_hardening_original_ssh_ports is not defined']}},
    ]}]
    path = tmp_path / 'snapshot.yml'
    path.write_text(yaml.safe_dump(play))
    run(['ansible-playbook', '-i', 'localhost,', '-c', 'local', str(path)],
        cwd=source_root, log=log_dir / 'listener-snapshot.log', timeout=45)
