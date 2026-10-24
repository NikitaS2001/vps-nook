"""Policy and persisted-state failures must stop module preparation."""
import importlib.util
import json
from pathlib import Path

import pytest

pytestmark = pytest.mark.quick
OWNER = Path(__file__).resolve().parents[2] / 'roles/vps_orchestration/files/awg_module.py'


@pytest.fixture
def owner():
    spec = importlib.util.spec_from_file_location('awg_module', OWNER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def platform_inputs():
    return dict(os_id='debian', os_version='12', architecture='x86_64',
                kernel='6.1.0-53-cloud-amd64', ram_kib=921600,
                disk_bytes=2 * 1024**3, tun=True, secure_boot=False,
                signature_enforced=False, lockdown='none', auto_reboot=False,
                swap_active=False, zram_present=False)


@pytest.mark.parametrize('os_id,version,kernel', [
    ('debian', '12', '6.1.0-53-cloud-amd64'),
    ('debian', '12', '6.1.0-53-amd64'),
    ('ubuntu', '24.04', '6.8.0-142-generic'),
])
def test_fresh_platform_does_not_require_module(owner, os_id, version, kernel):
    values = platform_inputs()
    values.update(os_id=os_id, os_version=version, kernel=kernel)
    owner.validate_platform(**values)


@pytest.mark.parametrize('change', [
    {'os_version': '13'}, {'architecture': 'aarch64'},
    {'kernel': '6.8.0-100-aws'}, {'kernel': '6.12.0-1-cloud-amd64'},
    {'ram_kib': 921599}, {'disk_bytes': 2 * 1024**3 - 1},
    {'tun': False}, {'secure_boot': True}, {'secure_boot': None},
    {'signature_enforced': True}, {'signature_enforced': None},
    {'lockdown': 'integrity'}, {'lockdown': None}, {'auto_reboot': True},
    {'swap_active': True}, {'zram_present': True},
])
def test_infeasible_platform_refused(owner, change):
    values = platform_inputs()
    values.update(change)
    with pytest.raises(owner.Refusal):
        owner.validate_platform(**values)


def test_unknown_state_is_preserved(owner, tmp_path):
    receipt = tmp_path / 'receipt.json'
    receipt.write_text('{broken')
    receipt.chmod(0o600)
    before = receipt.read_bytes()
    with pytest.raises(owner.Refusal):
        owner.read_receipt(receipt, expected_uid=receipt.stat().st_uid)
    assert receipt.read_bytes() == before


def test_symlink_state_refused(owner, tmp_path):
    original = tmp_path / 'original'
    original.write_text('{}')
    receipt = tmp_path / 'receipt.json'
    receipt.symlink_to(original)
    with pytest.raises(owner.Refusal):
        owner.read_receipt(receipt, expected_uid=original.stat().st_uid)
    assert original.read_text() == '{}'


def test_foreign_source_identity_refused(owner, tmp_path):
    receipt = tmp_path / 'receipt.json'
    receipt.write_text(json.dumps({'schema': 1, 'source_commit': 'foreign'}))
    receipt.chmod(0o600)
    with pytest.raises(owner.Refusal):
        owner.read_receipt(receipt, expected_uid=receipt.stat().st_uid)


def test_checksum_failure_does_not_publish_source(owner, tmp_path, monkeypatch):
    archive = tmp_path / 'source.tar.gz'
    archive.write_bytes(b'wrong upstream bytes')
    source = tmp_path / 'source'
    monkeypatch.setattr(owner, 'SOURCE', source)
    monkeypatch.setattr(owner, 'guard', lambda *args, **kwargs: None)
    value = {'kernels': {}}
    with pytest.raises(owner.Refusal, match='checksum'):
        owner.stage_source(value, archive)
    assert not source.exists()
    assert value == {'kernels': {}}
    assert archive.read_bytes() == b'wrong upstream bytes'


def fake_lock():
    from contextlib import contextmanager

    @contextmanager
    def locked():
        yield 9
    return locked


def test_build_failure_preserves_previous_receipt(owner, monkeypatch):
    value = {'kernels': {'old': {'phase': 'ready', 'module_sha256': 'unchanged'}}}
    before = json.dumps(value, sort_keys=True)
    calls = []
    monkeypatch.setattr(owner, 'module_lock', fake_lock())
    monkeypatch.setattr(owner, 'read_receipt', lambda: value)
    monkeypatch.setattr(owner, 'platform_check', lambda kernel, **kwargs: None)
    monkeypatch.setattr(owner, 'verify_source', lambda receipt: None)
    monkeypatch.setattr(owner, 'verify_dependency_payloads', lambda *args: None)
    monkeypatch.setattr(owner, 'authenticate_update_dependencies', lambda *args: None)
    monkeypatch.setattr(owner.Path, 'cwd', lambda: Path(f'/var/lib/dkms/{owner.MODULE}/{owner.DKMS_VERSION}/build'))

    def reject(argv, **kwargs):
        calls.append(argv)
        raise owner.Refusal('compiler failed')

    monkeypatch.setattr(owner, 'run', reject)
    with pytest.raises(owner.Refusal, match='compiler failed'):
        owner.compile_module('6.1.0-53-cloud-amd64')
    assert json.dumps(value, sort_keys=True) == before
    command = calls[0]
    assert command[0] == 'systemd-run'
    assert 'MemoryMax=512M' in command and 'MemorySwapMax=0' in command
    assert 'PrivateNetwork=yes' in command and 'RuntimeMaxSec=1200' in command
    assert not any('modprobe' in part for part in command)


def test_load_failure_does_not_publish_ready(owner, monkeypatch):
    kernel = '6.1.0-53-cloud-amd64'
    value = {'kernels': {kernel: {'phase': 'installed'}}}
    info = {'sha256': 'installed', 'srcversion': 'source'}
    monkeypatch.setattr(owner, 'preflight', lambda kernel, **kwargs: value)
    monkeypatch.setattr(owner, 'initialize', lambda: value)
    monkeypatch.setattr(owner, 'module_lock', fake_lock())
    monkeypatch.setattr(owner, 'inspect_state', lambda: value)
    monkeypatch.setattr(owner, 'stage_source', lambda *args: None)
    monkeypatch.setattr(owner, 'verify_dependency_payloads', lambda *args: None)
    monkeypatch.setattr(owner, 'read_receipt', lambda: value)
    monkeypatch.setattr(owner, 'module_info', lambda kernel: info)
    monkeypatch.setattr(owner, 'verify_installed', lambda *args: info)

    def reject(argv, **kwargs):
        assert argv == ['modprobe', owner.MODULE]
        raise owner.Refusal('load failed')

    monkeypatch.setattr(owner, 'run', reject)
    with pytest.raises(owner.Refusal, match='load failed'):
        owner.prepare(kernel, Path('/unused'))
    assert value['kernels'][kernel]['phase'] == 'installed'


def test_interrupted_install_reuses_verified_candidate(owner, monkeypatch):
    kernel = '6.1.0-53-cloud-amd64'
    value = {'kernels': {kernel: {'phase': 'built', 'candidate_sha256': 'candidate',
                                 'raw_srcversion': 'known'}}}
    info = {'sha256': 'candidate', 'srcversion': 'known'}
    monkeypatch.setattr(owner, 'module_info', lambda kernel: info)
    assert owner.verify_installed(value, kernel) == info


@pytest.mark.parametrize('value', ['true', '1', 'yes', 'unknown'])
def test_reboot_refusal_before_hardening(owner, monkeypatch, value):
    import subprocess

    config = f'Unattended-Upgrade::Automatic-Reboot "{value}";\n'
    monkeypatch.setattr(owner.os, 'geteuid', lambda: 0)
    monkeypatch.setattr(owner.sys, 'argv', ['awg_module.py', 'pre-hardening'])
    calls = []

    def apt_config(argv, **kwargs):
        calls.append(argv)
        assert argv == ['apt-config', 'dump']
        return subprocess.CompletedProcess(argv, 0, stdout=config, stderr='')

    monkeypatch.setattr(owner, 'run', apt_config)
    with pytest.raises(owner.Refusal, match='automatic reboot'):
        owner.main()
    assert calls == [['apt-config', 'dump']]


def test_controller_reboot_guard_precedes_hardening():
    import yaml

    plays = yaml.safe_load((OWNER.parents[3] / 'site.yml').read_text())
    guards = plays[0].get('pre_tasks', [])
    assert any(task.get('ansible.builtin.script', {}).get('cmd', '').endswith('awg_module.py pre-hardening')
               and 'wg_amnezia_enabled' in task.get('when', '') for task in guards)


def test_swap_zram_state_is_read_only(owner, tmp_path):
    swaps = tmp_path / 'swaps'
    block = tmp_path / 'block'
    block.mkdir()
    swaps.write_text('Filename Type Size Used Priority\n')
    assert owner.swap_zram_state(swaps, block) == (False, False)
    swaps.write_text('Filename Type Size Used Priority\n/swapfile file 100 0 -2\n')
    assert owner.swap_zram_state(swaps, block) == (True, False)
    swaps.write_text('Filename Type Size Used Priority\n')
    (block / 'zram0').mkdir()
    assert owner.swap_zram_state(swaps, block) == (False, True)
    assert swaps.read_text() == 'Filename Type Size Used Priority\n'
    with pytest.raises(owner.Refusal, match='Cannot determine host swap state'):
        owner.swap_zram_state(tmp_path / 'missing-swaps', block)
    with pytest.raises(owner.Refusal, match='Cannot determine host zram state'):
        owner.swap_zram_state(swaps, tmp_path / 'missing-block')
    swaps.write_text('invalid header\n')
    with pytest.raises(owner.Refusal, match='Cannot determine host swap state'):
        owner.swap_zram_state(swaps, block)


@pytest.mark.parametrize('state', [(True, False), (False, True)])
def test_swap_zram_refused_before_hardening(owner, monkeypatch, state):
    import subprocess

    config = 'Unattended-Upgrade::Automatic-Reboot "false";\n'
    monkeypatch.setattr(owner.os, 'geteuid', lambda: 0)
    monkeypatch.setattr(owner.sys, 'argv', ['awg_module.py', 'pre-hardening'])
    calls = []

    def apt_config(argv, **kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, stdout=config, stderr='')

    monkeypatch.setattr(owner, 'run', apt_config)
    monkeypatch.setattr(owner, 'swap_zram_state', lambda: state)
    monkeypatch.setattr(owner, 'signing_state', lambda: pytest.fail('signing probe must not run'))
    with pytest.raises(owner.Refusal, match='no active swap or zram'):
        owner.main()
    assert calls == [['apt-config', 'dump']]


def closure_fixture():
    from types import SimpleNamespace

    class Package:
        def __init__(self, name, installed=False, origin='Debian', downloadable=True):
            self.name = name
            self.essential = False
            self.is_installed = installed
            self.marked_install = False
            self.marked_upgrade = False
            self.marked_delete = False
            self.dependencies = []
            version = SimpleNamespace(package=self, version='1.0', downloadable=downloadable,
                origins=[SimpleNamespace(trusted=True, origin=origin, codename='bookworm', archive='stable', site='deb.debian.org')],
                record={'SHA256': 'a' * 64}, get_dependencies=lambda *args: self.dependencies)
            self.versions = [version]
            self.candidate = version
            self.installed = version if installed else None

        def mark_install(self, **kwargs):
            assert kwargs == {'auto_fix': True, 'auto_inst': True, 'from_user': False}
            self.marked_install = not self.is_installed

    class Cache(dict):
        broken_count = 0

        def __iter__(self):
            return iter(self.values())

        def get_changes(self):
            return [pkg for pkg in self.values() if pkg.marked_install]

    root = Package('dkms')
    gcc = Package('gcc', installed=True)
    make = Package('make', installed=True)
    root.dependencies = [SimpleNamespace(or_dependencies=[SimpleNamespace(target_versions=gcc.versions)])]
    gcc.dependencies = [SimpleNamespace(or_dependencies=[SimpleNamespace(target_versions=make.versions)])]
    return Cache(dkms=root, gcc=gcc, make=make), Package


def test_full_closure_includes_already_installed_transitive_tools(owner):
    cache, _ = closure_fixture()
    assert set(owner.dependency_closure(cache, ['dkms'], 'Debian')) == {'dkms', 'gcc', 'make'}
    assert not cache['gcc'].marked_install and not cache['make'].marked_install


def test_historical_origin_can_authenticate_only_exact_installed_versions(owner):
    cache, _ = closure_fixture()
    for pkg in cache.values():
        item = pkg.candidate.origins[0]
        item.origin = 'Ubuntu'
        item.codename = 'noble'
        item.site = 'archive.ubuntu.com' if not pkg.is_installed else 'snapshot.ubuntu.com'
    result = owner.dependency_closure(cache, ['dkms'], 'Ubuntu')
    assert result['gcc'].version == cache['gcc'].installed.version == '1.0'
    assert result['make'].version == cache['make'].installed.version == '1.0'
    assert not cache['gcc'].marked_upgrade and not cache['make'].marked_upgrade


@pytest.mark.parametrize('site', ['snapshot.ubuntu.com', 'foreign.example', None])
def test_new_package_requires_current_archive_not_historical_or_unknown_origin(owner, site):
    cache, _ = closure_fixture()
    for pkg in cache.values():
        item = pkg.candidate.origins[0]
        item.origin = 'Ubuntu'
        item.codename = 'noble'
        item.site = 'archive.ubuntu.com'
    cache['dkms'].candidate.origins[0].site = site
    with pytest.raises(owner.Refusal, match='cannot supply a new dependency'):
        owner.dependency_closure(cache, ['dkms'], 'Ubuntu')


@pytest.mark.parametrize('field,value', [('origin', 'ThirdParty'), ('trusted', False),
                                         ('codename', 'bookworm-backports')])
def test_installed_transitive_tool_requires_official_authenticated_index(owner, field, value):
    cache, _ = closure_fixture()
    setattr(cache['make'].candidate.origins[0], field, value)
    with pytest.raises(owner.Refusal, match='Non-distro or unauthenticated dependency'):
        owner.dependency_closure(cache, ['dkms'], 'Debian')


def test_installed_exact_tool_version_unavailable_refuses_without_upgrade(owner):
    cache, _ = closure_fixture()
    cache['gcc'].candidate.downloadable = False
    with pytest.raises(owner.Refusal):
        owner.dependency_closure(cache, ['dkms'], 'Debian')
    assert cache['gcc'].installed.version == '1.0'


def test_resolver_cannot_install_unrelated_package(owner):
    cache, package = closure_fixture()
    cache['unrelated'] = package('unrelated')
    cache['unrelated'].marked_install = True
    with pytest.raises(owner.Refusal, match='escaped bounded dependency closure'):
        owner.dependency_closure(cache, ['dkms'], 'Debian')


def test_status_pseudo_origin_is_not_an_archive(owner):
    from types import SimpleNamespace

    cache, _ = closure_fixture()
    version = cache['gcc'].candidate
    version.origins.append(SimpleNamespace(archive='now', origin='', trusted=False, codename=''))
    assert owner.official_version(version, 'Debian') == 'a' * 64
    version.origins = version.origins[1:]
    with pytest.raises(owner.Refusal):
        owner.official_version(version, 'Debian')


@pytest.mark.parametrize('os_id,keyring,suite', [
    ('debian', '/usr/share/keyrings/debian-archive-keyring.gpg', 'bookworm'),
    ('ubuntu', '/usr/share/keyrings/ubuntu-archive-keyring.gpg', 'noble'),
])
def test_transaction_local_signedby_config_excludes_host_sourceparts_and_hooks(
        owner, tmp_path, monkeypatch, os_id, keyring, suite):
    guarded = []
    monkeypatch.setattr(owner, 'guard', lambda path, **kwargs: guarded.append(str(path)))
    config = owner.distro_apt_boundary(tmp_path, os_id)
    text = config.read_text()
    sources = (tmp_path / 'distro.sources').read_text()
    assert guarded == [keyring]
    assert f'Signed-By: {keyring}' in sources and suite in sources
    assert 'foreign' not in sources and 'Trusted:' not in sources
    for key in ('main', 'parts', 'sourceparts', 'trustedparts', 'preferencesparts'):
        assert f'Dir::Etc::{key} "{tmp_path}/' in text
    assert 'Dir::State::status "/var/lib/dpkg/status";' in text
    assert f'Dir::State::extended_states "{tmp_path}/extended_states";' in text
    assert 'APT::Install-Recommends "false";' in text
    assert 'APT::Get::AllowUnauthenticated "false";' in text
    assert 'Acquire::AllowInsecureRepositories "false";' in text
    assert 'Pre-Invoke' not in text and 'Post-Invoke' not in text
    assert not list((tmp_path / 'parts').iterdir())
    assert 'Acquire::Check-Valid-Until "true";' in text
    preferences = (tmp_path / 'distro.preferences').read_text()
    if os_id == 'ubuntu':
        from tests.registry import FRESH_IMAGES
        assert owner.UBUNTU_BASE_ARCHIVE == ('20260926T000000Z', FRESH_IMAGES['ubuntu'][1])
        assert f'https://snapshot.ubuntu.com/ubuntu/{owner.UBUNTU_BASE_ARCHIVE[0]}' in sources
        assert preferences == 'Package: *\nPin: origin "snapshot.ubuntu.com"\nPin-Priority: -1\n'
    else:
        assert preferences == '' and 'snapshot.ubuntu.com' not in sources


def test_tool_payload_change_blocks_compile_before_commands(owner, monkeypatch):
    value = {'dependency_audit': {'kernels': {'k': ['linux-headers-k']},
        'packages': {'linux-headers-k': {'version': '1', 'payload_sha256': 'original'}}}}
    from types import SimpleNamespace

    monkeypatch.setattr(owner, 'run', lambda *args, **kwargs: SimpleNamespace(stdout='1'))
    monkeypatch.setattr(owner, 'package_payload', lambda name: 'changed')
    monkeypatch.setattr(owner, 'dependency_roots', lambda kernel: [f'linux-headers-{kernel}'])
    with pytest.raises(owner.Refusal, match='payload changed'):
        owner.verify_dependency_payloads(value, 'k')
    with pytest.raises(owner.Refusal, match='No authenticated dependency closure'):
        owner.verify_dependency_payloads(value, 'next-kernel')


def test_malformed_dependency_audit_preserved(owner, tmp_path):
    receipt = tmp_path / 'receipt.json'
    receipt.write_text(json.dumps(dict(schema=1, source_commit=owner.SOURCE_COMMIT,
        archive_sha256=owner.ARCHIVE_SHA256, kernels={}, phase='initialized', dependency_audit={'schema': 1})))
    receipt.chmod(0o600)
    original = receipt.read_bytes()
    with pytest.raises(owner.Refusal, match='Malformed dependency audit'):
        owner.read_receipt(receipt, expected_uid=receipt.stat().st_uid)
    assert receipt.read_bytes() == original


def test_role_uses_existing_owner_not_unconstrained_host_apt():
    import yaml

    tasks = yaml.safe_load((OWNER.parents[1] / 'tasks/amneziawg_prepare.yml').read_text())
    dependency = [task for task in tasks if task.get('register') == 'vps_orchestration_awg_dependencies']
    assert len(dependency) == 1
    assert dependency[0]['ansible.builtin.command']['argv'][-1] == 'dependencies'
    assert 'changed' in dependency[0]['changed_when']
    assert not any('ansible.builtin.apt' in task for task in tasks)


@pytest.mark.parametrize('changed', [False, True])
def test_authenticated_deb_payload_compared_without_extraction_or_dpkg_install(
        owner, tmp_path, monkeypatch, changed):
    import hashlib
    import io
    import tarfile
    from types import SimpleNamespace

    cache, _ = closure_fixture()
    version = cache['gcc'].candidate
    deb = tmp_path / 'gcc.deb'
    deb.write_bytes(b'authenticated archive fixture')
    version.record['SHA256'] = hashlib.sha256(deb.read_bytes()).hexdigest()
    version.fetch_binary = lambda **kwargs: str(deb)
    installed = tmp_path / 'gcc'
    installed.write_bytes(b'foreign executable' if changed else b'official executable')
    installed.chmod(0o644)
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode='w') as bundle:
        member = tarfile.TarInfo(str(installed).lstrip('/'))
        member.size = len(b'official executable')
        member.mode = 0o644
        member.uid = installed.stat().st_uid
        member.gid = installed.stat().st_gid
        bundle.addfile(member, io.BytesIO(b'official executable'))
    commands = []

    def inspect_deb(argv, **kwargs):
        commands.append(argv)
        kwargs['stdout'].write(archive.getvalue())
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(owner, 'guard', lambda *args, **kwargs: None)
    monkeypatch.setattr(owner.subprocess, 'run', inspect_deb)
    monkeypatch.setattr(owner, 'package_payload', lambda name: 'verified-fingerprint')
    if changed:
        with pytest.raises(owner.Refusal, match='Changed installed distro payload'):
            owner.verify_deb_payload(version, tmp_path, 'Debian')
    else:
        assert owner.verify_deb_payload(version, tmp_path, 'Debian') == 'verified-fingerprint'
    assert commands == [['/usr/bin/dpkg-deb', '--fsys-tarfile', str(deb)]]
    assert installed.read_bytes() == (b'foreign executable' if changed else b'official executable')


def test_new_kernel_hook_authentication_is_readonly_and_extends_existing_receipt(owner, tmp_path, monkeypatch):
    from types import SimpleNamespace

    old = {'schema': 1, 'origin': 'Debian', 'packages': {'linux-headers-old': {'version': 'old'}},
           'kernels': {'old': ['linux-headers-old']}}
    new = {'schema': 1, 'origin': 'Debian', 'packages': {'linux-headers-new': {'version': 'new'}},
           'kernels': {'new': ['linux-headers-new']}}
    value = {'dependency_audit': old, 'kernels': {'old': {'phase': 'ready'}}}
    monkeypatch.setattr(owner, 'STATE', tmp_path)
    monkeypatch.setattr(owner, 'read_receipt', lambda: value)
    monkeypatch.setattr(owner, 'inspect_state', lambda: value)
    monkeypatch.setattr(owner, 'module_lock', fake_lock())
    monkeypatch.setattr(owner, 'distro_apt_boundary', lambda root, os_id: Path(root) / 'apt.conf')
    checked = []

    def verify(receipt, kernel):
        checked.append(kernel)
        if len(checked) == 1:
            raise owner.Refusal('new header lacks authentication')

    calls = []
    written = []

    def read_only(argv, **kwargs):
        calls.append((argv, kwargs))
        return SimpleNamespace(stdout=json.dumps({'audit': new}))

    monkeypatch.setattr(owner, 'verify_dependency_payloads', verify)
    monkeypatch.setattr(owner, 'run', read_only)
    monkeypatch.setattr(owner, 'write_receipt', lambda receipt: written.append(receipt))
    owner.authenticate_update_dependencies('new')
    assert len(calls) == 1 and calls[0][0][-3:] == ['authenticate-worker', '--kernel', 'new']
    assert set(calls[0][1]['env']) == {'PATH', 'LANG', 'APT_CONFIG', 'DEBIAN_FRONTEND'}
    assert owner.LOCK_ENV not in calls[0][1]['env']
    assert set(value['dependency_audit']['kernels']) == {'old', 'new'}
    assert value['kernels']['old']['phase'] == 'ready'
    assert checked == ['new', 'new'] and written == [value]


def test_existing_authenticated_closure_avoids_hook_network_or_reinstall(owner, monkeypatch):
    value = {'dependency_audit': {'existing': True}}
    monkeypatch.setattr(owner, 'read_receipt', lambda: value)
    monkeypatch.setattr(owner, 'verify_dependency_payloads', lambda *args: None)
    monkeypatch.setattr(owner, 'run', lambda *args, **kwargs: pytest.fail('unnecessary download/install'))
    owner.authenticate_update_dependencies('matching')


def test_python_apt_absence_is_explicit_refusal(owner, monkeypatch):
    import builtins

    original = builtins.__import__

    def missing(name, *args, **kwargs):
        if name == 'apt':
            raise ImportError('python3-apt missing')
        return original(name, *args, **kwargs)

    monkeypatch.setattr(builtins, '__import__', missing)
    with pytest.raises(owner.Refusal, match='requires distro python3-apt'):
        owner.dependencies_worker('k')


@pytest.mark.parametrize('read_only,plan_only', [(False, False), (True, False), (False, True)])
def test_worker_locking_and_installed_reinstall_match_transaction_mode(
        owner, tmp_path, monkeypatch, read_only, plan_only):
    from contextlib import contextmanager
    from types import ModuleType, SimpleNamespace

    cache, _ = closure_fixture()
    cache['dkms'].is_installed = True
    cache['dkms'].installed = cache['dkms'].candidate
    calls = []
    locked = {'dpkg': False, 'module': False}

    @contextmanager
    def system_lock():
        assert not locked['dpkg']
        locked['dpkg'] = True
        calls.append('system-lock')
        try:
            yield
        finally:
            locked['dpkg'] = False

    @contextmanager
    def module_lock():
        assert not locked['module']
        locked['module'] = True
        try:
            yield 9
        finally:
            locked['module'] = False

    def commit(*args):
        assert locked['dpkg'] and not locked['module']
        calls.append('commit')
        with module_lock():  # A dpkg/DKMS hook can acquire the module lock.
            # Another ABI publishes after the worker's pre-commit snapshot.
            value['dependency_audit'] = dict(schema=1, origin='Debian',
                packages={'linux-headers-other': {'version': 'other', 'archive_sha256': 'c' * 64,
                                                 'payload_sha256': 'd' * 64}},
                kernels={'other': ['linux-headers-other']})
        return True

    for package in cache.values():
        package.mark_install = lambda **kwargs: None
    cache.update = lambda: True
    cache.open = lambda: None
    cache.commit = commit
    cache._depcache = SimpleNamespace(set_reinstall=lambda package, enabled: calls.append(('reinstall', enabled)))
    for package in cache.values():
        package._pkg = object()
    apt = ModuleType('apt')
    apt.__path__ = []
    apt.Cache = lambda: cache
    progress = ModuleType('apt.progress')
    progress.__path__ = []
    base = ModuleType('apt.progress.base')
    base.AcquireProgress = base.InstallProgress = lambda: object()
    progress.base = base
    apt.progress = progress
    apt_pkg = ModuleType('apt_pkg')
    apt_pkg.config = SimpleNamespace(keys=lambda: ['DPkg::Pre-Invoke'], clear=lambda key: calls.append(('clear', key)))
    apt_pkg.init_config = apt_pkg.init_system = lambda: None
    apt_pkg.SystemLock = system_lock
    for name, module in [('apt', apt), ('apt.progress', progress), ('apt.progress.base', base), ('apt_pkg', apt_pkg)]:
        monkeypatch.setitem(owner.sys.modules, name, module)
    monkeypatch.setenv('APT_CONFIG', str(tmp_path / 'apt.conf'))
    original = owner.Path.read_text
    monkeypatch.setattr(owner.Path, 'read_text', lambda path, *args, **kwargs:
                        'ID=debian\n' if str(path) == '/etc/os-release' else original(path, *args, **kwargs))
    monkeypatch.setattr(owner, 'guard', lambda *args, **kwargs: None)
    monkeypatch.setattr(owner, 'dependency_roots', lambda kernel: ['dkms', 'gcc', 'make'])
    monkeypatch.setattr(owner, 'dependency_closure', lambda *args: {p.name: p.candidate for p in cache.values()})
    value = {'kernels': {}}
    monkeypatch.setattr(owner, 'read_receipt', lambda: value)
    monkeypatch.setattr(owner, 'inspect_state', lambda: value)
    monkeypatch.setattr(owner, 'module_lock', module_lock)
    monkeypatch.setattr(owner, 'verify_deb_payload', lambda *args: calls.append('deb-verify') or 'b' * 64)
    written = []
    monkeypatch.setattr(owner, 'write_receipt', lambda receipt: written.append(receipt))
    owner.dependencies_worker('k', read_only=read_only, plan_only=plan_only)
    assert ('clear', 'DPkg::Pre-Invoke') in calls
    if plan_only:
        assert 'system-lock' in calls and 'commit' not in calls and 'deb-verify' not in calls and not written
        assert not any(isinstance(call, tuple) and call[0] == 'reinstall' for call in calls)
    elif read_only:
        assert 'commit' not in calls and 'system-lock' not in calls and not written
        assert not any(isinstance(call, tuple) and call[0] == 'reinstall' for call in calls)
    else:
        assert 'system-lock' in calls and 'commit' in calls and written == [value]
        assert calls.count(('reinstall', True)) == 3
        assert set(value['dependency_audit']['packages']) == {'dkms', 'gcc', 'make', 'linux-headers-other'}
        assert value['dependency_audit']['kernels']['other'] == ['linux-headers-other']
        assert value['dependency_audit']['kernels']['k'] == ['dkms', 'gcc', 'make']


def test_installed_implicit_tool_and_alternative_owner_join_closure(owner, tmp_path, monkeypatch):
    from types import SimpleNamespace

    tool = tmp_path / 'foreign-awk'
    tool.write_bytes(b'already installed third-party tool')
    alias = tmp_path / 'awk'
    alias.symlink_to(tool)
    monkeypatch.setattr(owner.shutil, 'which', lambda command, **kwargs: str(alias) if command == 'awk' else None)
    calls = []

    def query(argv, **kwargs):
        calls.append(argv)
        return SimpleNamespace(returncode=0, stdout=f'foreign-awk: {tool}\n', stderr='')

    monkeypatch.setattr(owner, 'run', query)
    roots = owner.dependency_roots('k')
    assert 'foreign-awk' in roots and 'python3-apt' in roots
    assert calls == [['/usr/bin/dpkg-query', '-S', str(tool)]]
    value = {'dependency_audit': {'kernels': {'k': ['linux-headers-k']},
        'packages': {'linux-headers-k': {'version': '1', 'payload_sha256': 'a' * 64}}}}
    with pytest.raises(owner.Refusal, match='alternative owners changed'):
        owner.verify_dependency_payloads(value, 'k')


def transaction_fixture(owner, tmp_path, monkeypatch):
    unit = 'nook-awg-deps-' + 'a' * 32
    directory = tmp_path / ('.apt-txn.' + 'a' * 32)
    directory.mkdir(mode=0o700)
    config = directory / 'apt.conf'
    config.write_text('private config')
    pending = tmp_path / 'dependency-transaction.json'
    pending.write_text(json.dumps(dict(schema=1, unit=unit, directory=str(directory))))
    pending.chmod(0o600)
    monkeypatch.setattr(owner, 'STATE', tmp_path)
    monkeypatch.setattr(owner, 'DEPENDENCY_PENDING', pending)
    monkeypatch.setattr(owner, 'guard', lambda *args, **kwargs: None)
    return unit, directory, config, pending


@pytest.mark.parametrize('failure', ['none', 'timeout', 'cancel'])
def test_dependency_transaction_stops_owned_service_and_slice_before_cleanup(owner, tmp_path, monkeypatch, failure):
    import subprocess

    unit, directory, config, pending = transaction_fixture(owner, tmp_path, monkeypatch)
    calls = []

    def managed(argv, **kwargs):
        calls.append(argv)
        if argv[0] == 'systemd-run':
            if failure == 'timeout':
                raise subprocess.TimeoutExpired(argv, 1)
            if failure == 'cancel':
                raise KeyboardInterrupt()
            return subprocess.CompletedProcess(argv, 0, stdout='{"changed": true}', stderr='')
        assert argv == ['systemctl', 'stop', unit + '.service', owner.dependency_slice(unit)]
        assert directory.exists() and pending.exists()
        return subprocess.CompletedProcess(argv, 0, stdout='', stderr='')

    def terminated(name, path):
        assert calls[-1][0:2] == ['systemctl', 'stop']
        assert path.exists() and pending.exists()
        return True

    monkeypatch.setattr(owner, 'run', managed)
    monkeypatch.setattr(owner, 'dependency_unit_stopped', terminated)
    if failure == 'none':
        assert owner.run_dependency_transaction('k', config, unit, directory).returncode == 0
    else:
        error = subprocess.TimeoutExpired if failure == 'timeout' else KeyboardInterrupt
        with pytest.raises(error):
            owner.run_dependency_transaction('k', config, unit, directory)
    assert not directory.exists() and not pending.exists()
    command = calls[0]
    for option in ('MemoryMax=512M', 'MemorySwapMax=0', 'KillMode=control-group', 'SendSIGKILL=yes',
                   f'RuntimeMaxSec={owner.DEPENDENCY_TIMEOUT}',
                   f'TimeoutStopSec={owner.DEPENDENCY_STOP_TIMEOUT}', '--slice=' + owner.dependency_slice(unit)):
        assert option in command
    assert 'dependencies-unit' in command and '--collect' not in command


@pytest.mark.parametrize('failure', ['timeout', 'stop-error', 'live-group'])
def test_uncertain_dependency_termination_preserves_private_boundary_and_logical_lock(
        owner, tmp_path, monkeypatch, failure):
    import subprocess

    unit, directory, config, pending = transaction_fixture(owner, tmp_path, monkeypatch)
    before = pending.read_bytes()
    calls = []

    def managed(argv, **kwargs):
        calls.append(argv)
        if argv[0] == 'systemd-run' and failure == 'timeout':
            raise subprocess.TimeoutExpired(argv, 1)
        if argv[0] == 'systemctl' and failure == 'stop-error':
            raise owner.Refusal('manager unavailable')
        return subprocess.CompletedProcess(argv, 0, stdout='{"changed": true}', stderr='')

    monkeypatch.setattr(owner, 'run', managed)
    monkeypatch.setattr(owner, 'dependency_unit_stopped', lambda *args: False)
    with pytest.raises(owner.Refusal, match='termination unconfirmed'):
        owner.run_dependency_transaction('k', config, unit, directory)
    assert directory.exists() and config.read_text() == 'private config'
    assert pending.read_bytes() == before
    monkeypatch.setattr(owner, 'platform_check', lambda *args, **kwargs: None)
    monkeypatch.setattr(owner, 'inspect_state', lambda: {})
    before_calls = len(calls)
    with pytest.raises(owner.Refusal, match='Interrupted/active dependency transaction'):
        owner.install_dependencies('k')
    assert len(calls) == before_calls


@pytest.mark.parametrize('ack,active,main_pid,slice_populated,expected', [
    (False, 'inactive', '0', False, False),
    (True, 'active', '123', False, False),
    (True, 'inactive', '123', False, False),
    (True, 'inactive', '0', True, False),
    (True, 'inactive', '0', False, True),
])
def test_dependency_termination_requires_ack_inactive_service_and_empty_whole_slice(
        owner, tmp_path, monkeypatch, ack, active, main_pid, slice_populated, expected):
    import subprocess

    unit, directory, _, _ = transaction_fixture(owner, tmp_path, monkeypatch)
    if ack:
        (directory / 'started.json').write_text(json.dumps(dict(unit=unit, pid=123)))
    slice_name = owner.dependency_slice(unit)
    original_exists = owner.Path.exists
    original_is_file = owner.Path.is_file
    original_read_text = owner.Path.read_text
    slice_cgroup = '/sys/fs/cgroup/' + slice_name

    def exists(path):
        return True if str(path) == slice_cgroup else original_exists(path)

    def is_file(path):
        return True if str(path) == slice_cgroup + '/cgroup.events' else original_is_file(path)

    def read_text(path, *args, **kwargs):
        if str(path) == slice_cgroup + '/cgroup.events':
            return 'populated ' + ('1' if slice_populated else '0') + '\n'
        return original_read_text(path, *args, **kwargs)

    def show(argv, **kwargs):
        assert argv[0:2] == ['systemctl', 'show']
        if argv[2].endswith('.service'):
            text = f'LoadState=loaded\nActiveState={active}\nSubState=dead\nMainPID={main_pid}\nControlGroup=\n'
        else:
            text = f'LoadState=loaded\nActiveState=inactive\nSubState=dead\nControlGroup=/{slice_name}\n'
        return subprocess.CompletedProcess(argv, 0, stdout=text, stderr='')

    monkeypatch.setattr(owner.Path, 'exists', exists)
    monkeypatch.setattr(owner.Path, 'is_file', is_file)
    monkeypatch.setattr(owner.Path, 'read_text', read_text)
    monkeypatch.setattr(owner, 'run', show)
    assert owner.dependency_unit_stopped(unit, directory) is expected


def test_dkms_sibling_build_joins_transaction_slice_from_cgroup_even_without_environment(owner, tmp_path, monkeypatch):
    unit, _, _, pending = transaction_fixture(owner, tmp_path, monkeypatch)
    slice_name = owner.dependency_slice(unit)
    monkeypatch.delenv('NOOK_AWG_DEPENDENCY_SLICE', raising=False)
    original = owner.Path.read_text
    monkeypatch.setattr(owner.Path, 'read_text', lambda path, *args, **kwargs:
        f'0::/{slice_name}/{unit}.service\n' if str(path) == '/proc/self/cgroup' else original(path, *args, **kwargs))
    assert owner.dependency_build_scope() == ['--slice=' + slice_name]
    pending.write_text(json.dumps(dict(schema=1, unit='nook-awg-deps-' + 'b' * 32)))
    with pytest.raises(owner.Refusal, match='slice transaction changed'):
        owner.dependency_build_scope()


def test_actual_dependency_unit_owns_advisory_lock_before_apt_worker(owner, tmp_path, monkeypatch):
    import fcntl
    import os

    unit, directory, config, _ = transaction_fixture(owner, tmp_path, monkeypatch)
    monkeypatch.setenv('NOOK_AWG_DEPENDENCY_UNIT', unit)
    monkeypatch.setenv('NOOK_AWG_DEPENDENCY_SLICE', owner.dependency_slice(unit))
    monkeypatch.setenv('APT_CONFIG', str(config))
    seen = []

    def actual_worker(kernel):
        assert kernel == 'k'
        assert json.loads((directory / 'started.json').read_text())['unit'] == unit
        probe = os.open(tmp_path / 'dependencies.lock', os.O_RDWR)
        try:
            with pytest.raises(BlockingIOError):
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(probe)
        seen.append(kernel)

    monkeypatch.setattr(owner, 'dependencies_worker', actual_worker)
    owner.dependencies_unit('k')
    assert seen == ['k']
    probe = os.open(tmp_path / 'dependencies.lock', os.O_RDWR)
    try:
        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
    finally:
        os.close(probe)


@pytest.mark.parametrize('durability_failure', [False, True])
def test_pending_transaction_directory_is_durable_before_unit_start(owner, tmp_path, monkeypatch, durability_failure):
    import subprocess

    pending = tmp_path / 'dependency-transaction.json'
    monkeypatch.setattr(owner, 'STATE', tmp_path)
    monkeypatch.setattr(owner, 'DEPENDENCY_PENDING', pending)
    monkeypatch.setattr(owner, 'platform_check', lambda *args, **kwargs: None)
    monkeypatch.setattr(owner, 'inspect_state', lambda: {})
    monkeypatch.setattr(owner, 'guard', lambda *args, **kwargs: None)
    events = []
    original_sync = owner.sync_state_directory

    def durable():
        assert pending.is_file()
        assert json.loads(pending.read_text())['directory'].startswith(str(tmp_path / '.apt-txn.'))
        if durability_failure:
            raise OSError('injected parent directory fsync failure')
        original_sync()
        events.append('durable')

    def boundary(directory, os_id):
        assert events == ['durable']
        return directory / 'apt.conf'

    def start(kernel, config, unit, directory):
        assert events == ['durable']
        events.append('start')
        return subprocess.CompletedProcess([], 0, stdout='{"changed": false}', stderr='')

    monkeypatch.setattr(owner, 'sync_state_directory', durable)
    monkeypatch.setattr(owner, 'distro_apt_boundary', boundary)
    monkeypatch.setattr(owner, 'run_dependency_transaction', start)
    if durability_failure:
        with pytest.raises(OSError, match='fsync failure'):
            owner.install_dependencies('k')
        assert events == []
        assert pending.is_file()
        assert owner.Path(json.loads(pending.read_text())['directory']).is_dir()
    else:
        owner.install_dependencies('k')
        assert events == ['durable', 'start']


def test_completed_transaction_removal_is_durable(owner, tmp_path, monkeypatch):
    import subprocess

    unit, directory, config, pending = transaction_fixture(owner, tmp_path, monkeypatch)
    monkeypatch.setattr(owner, 'run', lambda argv, **kwargs: subprocess.CompletedProcess(argv, 0, stdout='{}', stderr=''))
    monkeypatch.setattr(owner, 'dependency_unit_stopped', lambda *args: True)
    events = []
    original_sync = owner.sync_state_directory
    def durable_removal():
        assert not directory.exists() and not pending.exists()
        original_sync()
        events.append('durable')
    monkeypatch.setattr(owner, 'sync_state_directory', durable_removal)
    owner.run_dependency_transaction('k', config, unit, directory)
    assert events == ['durable']


def test_pre_vault_feasibility_uses_disk_cache_scratch_not_run_tmpfs(owner, tmp_path, monkeypatch):
    import subprocess
    import tempfile

    calls = []
    original_temporary = tempfile.TemporaryDirectory
    def scratch(*, prefix, dir):
        assert prefix == 'nook-awg-feasibility.'
        assert dir == '/var/cache'
        calls.append('disk-scratch')
        return original_temporary(prefix=prefix, dir=tmp_path)
    def boundary(directory, os_id):
        calls.append('isolated-boundary')
        assert owner.Path(directory).parent == tmp_path
        return owner.Path(directory) / 'apt.conf'
    def plan(argv, **kwargs):
        assert argv[2:] == ['dependencies-plan', '--kernel', 'k']
        assert kwargs['env']['APT_CONFIG'].endswith('/apt.conf')
        calls.append('plan-only')
        return subprocess.CompletedProcess(argv, 0, stdout='{"feasible": true}', stderr='')
    monkeypatch.setattr(owner, 'guard', lambda *args, **kwargs: None)
    monkeypatch.setattr(owner.tempfile, 'TemporaryDirectory', scratch)
    monkeypatch.setattr(owner, 'distro_apt_boundary', boundary)
    monkeypatch.setattr(owner, 'run', plan)
    owner.dependency_feasibility('k')
    assert calls == ['disk-scratch', 'isolated-boundary', 'plan-only']
    assert list(tmp_path.iterdir()) == []


def historical_release_fixture(owner, tmp_path, monkeypatch):
    directory = tmp_path / 'lists'
    directory.mkdir()
    monkeypatch.setattr(owner, 'guard', lambda *args, **kwargs: None)
    files = {}
    for suite in ('noble', 'noble-updates', 'noble-security'):
        path = directory / f'snapshot.ubuntu.com_ubuntu_{owner.UBUNTU_BASE_ARCHIVE[0]}_dists_{suite}_InRelease'
        path.write_text('-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\n'
                        f'Origin: Ubuntu\nSuite: {suite}\nCodename: noble\n'
                        'Architectures: amd64 arm64\nComponents: main universe\n'
                        'Date: Fri, 25 Sep 2026 18:00:00 UTC\n')
        files[suite] = path
    return files


def test_historical_release_scope_does_not_claim_freshness(owner, tmp_path, monkeypatch):
    historical_release_fixture(owner, tmp_path, monkeypatch)
    owner.verify_historical_release_scope(tmp_path)


@pytest.mark.parametrize('old,new', [
    ('Origin: Ubuntu', 'Origin: ThirdParty'),
    ('Suite: noble-updates', 'Suite: noble-security'),
    ('Codename: noble', 'Codename: jammy'),
    ('Architectures: amd64 arm64', 'Architectures: arm64'),
    ('Components: main universe', 'Components: main'),
    ('Date: Fri, 25 Sep 2026 18:00:00 UTC', 'Date: Sat, 26 Sep 2026 01:00:00 UTC'),
    ('Date: Fri, 25 Sep 2026 18:00:00 UTC', 'Date: Tue, 22 Sep 2026 18:00:00 UTC'),
])
def test_historical_release_scope_and_declared_epoch_fail_closed(owner, tmp_path, monkeypatch, old, new):
    files = historical_release_fixture(owner, tmp_path, monkeypatch)
    path = files['noble-updates']
    path.write_text(path.read_text().replace(old, new))
    with pytest.raises(owner.Refusal):
        owner.verify_historical_release_scope(tmp_path)
