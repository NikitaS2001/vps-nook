#!/usr/bin/env python3
"""Shared AWG feasibility, DKMS preparation and kernel-update transaction owner."""
import argparse
import contextlib
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import secrets
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

MODULE = 'amneziawg'
SOURCE_COMMIT = '0d5f03c543b709ab3c2e8d3f4a36994fbe249dc0'
ARCHIVE_SHA256 = '7901c2feebec12dd28361cbb8f249fa5a5bf973412cc2a70c10e8b4afb2f5a2c'
SOURCE_URL = f'https://codeload.github.com/amnezia-vpn/amneziawg-linux-kernel-module/tar.gz/{SOURCE_COMMIT}'
VERSION = '3.0.20260805'
DKMS_VERSION = f'{VERSION}+nook.{SOURCE_COMMIT[:16]}'
MIN_RAM_KIB = 900 * 1024
DISK_RESERVE_BYTES = 2 * 1024**3
BUILD_DISK_RESERVE_BYTES = 256 * 1024**2
BUILD_MEMORY_BYTES = 512 * 1024**2
BUILD_MEMORY = '512M'
BUILD_TIMEOUT = 1200
COMMAND_TIMEOUT = 120
DEPENDENCY_TIMEOUT = BUILD_TIMEOUT + COMMAND_TIMEOUT
DEPENDENCY_STOP_TIMEOUT = 30
# Historical authenticity anchor, not freshness/patch-status proof. Keep this
# pairing aligned with the checksum-pinned supported Ubuntu stock image.
UBUNTU_BASE_ARCHIVE = ('20260926T000000Z', '6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2')
STATE = Path('/var/lib/vps-nook/amneziawg')
SOURCE = Path('/usr/src') / f'{MODULE}-{DKMS_VERSION}'
ARCHIVE = STATE / 'source.tar.gz'
RECEIPT = STATE / 'receipt.json'
LOCK = STATE / 'module.lock'
DEPENDENCY_PENDING = STATE / 'dependency-transaction.json'
OWNER = Path('/usr/local/lib/vps-nook/awg_module.py')
LOCK_ENV = 'NOOK_AWG_LOCK_FD'
LOADED = Path('/sys/module/amneziawg')
MODULES_LOAD_FILE = Path('/etc/modules-load.d/amneziawg.conf')
SCHEMA = 1
PHASES = {'source_verified', 'built', 'installed', 'loaded', 'ready'}


class Refusal(RuntimeError):
    """An unsupported or unowned state must be preserved."""


def require(condition, message):
    if not condition:
        raise Refusal(message)


def run(argv, *, timeout=COMMAND_TIMEOUT, pass_fds=(), check=True, env=None):
    if env is None:
        env = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8'}
    result = subprocess.run(argv, text=True, capture_output=True, timeout=timeout,
                            pass_fds=pass_fds, env=env)
    if check and result.returncode:
        raise Refusal(f'{argv[0]} failed ({result.returncode}): {result.stderr.strip()}')
    return result


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def guard(path, *, directory=False, expected_uid=0, private=False):
    """Reject symlinks and writable parents before trusting a privileged path."""
    # Debian/Ubuntu usrmerge owns this canonical system alias. Other symlinks fail.
    if str(path).startswith('/lib/') and Path('/lib').is_symlink():
        require(Path('/lib').resolve() == Path('/usr/lib'), 'Unexpected /lib alias')
        path = Path('/usr/lib') / path.relative_to('/lib')
    for parent in reversed(path.parents):
        info = parent.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == expected_uid
                and not info.st_mode & 0o022, f'Unsafe parent: {parent}')
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    require(kind(info.st_mode) and info.st_uid == expected_uid
            and not info.st_mode & (0o077 if private else 0o022), f'Unsafe path: {path}')


def read_receipt(path=RECEIPT, expected_uid=0):
    # The caller guards absolute production parents; tests use private temp parents.
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == expected_uid
            and stat.S_IMODE(info.st_mode) == 0o600, f'Unsafe receipt: {path}')
    try:
        value = json.loads(path.read_text())
    except (ValueError, UnicodeError) as error:
        raise Refusal(f'Malformed AWG receipt: {path}') from error
    require(isinstance(value, dict) and value.get('schema') == SCHEMA
            and value.get('source_commit') == SOURCE_COMMIT
            and value.get('archive_sha256') == ARCHIVE_SHA256
            and isinstance(value.get('kernels'), dict)
            and value.get('phase') in ('initialized', 'source_verified'), 'Unknown AWG receipt identity')
    for kernel, record in value['kernels'].items():
        require(isinstance(record, dict) and record.get('phase') in PHASES,
                f'Malformed AWG kernel receipt: {kernel}')
    audit = value.get('dependency_audit')
    if audit is not None:
        require(isinstance(audit, dict) and set(audit) == {'schema', 'origin', 'packages', 'kernels'}
                and audit['schema'] == 1 and audit['origin'] in ('Debian', 'Ubuntu')
                and isinstance(audit['packages'], dict) and audit['packages']
                and isinstance(audit['kernels'], dict) and audit['kernels'], 'Malformed dependency audit')
        for kernel, names in audit['kernels'].items():
            require(isinstance(kernel, str) and re.fullmatch(r'[A-Za-z0-9_.+-]+', kernel)
                    and isinstance(names, list) and names and all(
                        isinstance(name, str) and name in audit['packages'] for name in names),
                    'Malformed dependency kernel audit')
        for name, record in audit['packages'].items():
            require(isinstance(name, str) and re.fullmatch(r'[a-z0-9][a-z0-9+.:_-]*', name)
                    and isinstance(record, dict) and set(record) == {'version', 'archive_sha256', 'payload_sha256'}
                    and isinstance(record['version'], str) and record['version']
                    and all(isinstance(record[key], str) and re.fullmatch(r'[0-9a-f]{64}', record[key])
                            for key in ('archive_sha256', 'payload_sha256')), 'Malformed dependency package audit')
    return value


def sync_state_directory():
    guard(STATE, directory=True, private=True)
    descriptor = os.open(STATE, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_receipt(value):
    guard(STATE, directory=True, private=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=STATE, prefix='.receipt.', delete=False) as stream:
        candidate = Path(stream.name)
        try:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            candidate.unlink()
            raise
    try:
        os.replace(candidate, RECEIPT)
        sync_state_directory()
    finally:
        candidate.unlink(missing_ok=True)


def validate_platform(*, os_id, os_version, architecture, kernel, ram_kib,
                      disk_bytes, tun, secure_boot, signature_enforced, lockdown, auto_reboot,
                      disk_reserve=DISK_RESERVE_BYTES, swap_active=False, zram_present=False):
    supported = ((os_id, os_version) == ('debian', '12')
                 and re.fullmatch(r'6\.1\.0-[0-9]+-(cloud-)?amd64', kernel)) or (
                     (os_id, os_version) == ('ubuntu', '24.04')
                     and re.fullmatch(r'6\.8\.0-[0-9]+-generic', kernel))
    require(architecture == 'x86_64' and supported,
            f'Unsupported AWG platform/kernel: {os_id} {os_version} {architecture} {kernel}')
    require(tun, 'AWG requires /dev/net/tun')
    require(ram_kib >= MIN_RAM_KIB, 'AWG requires at least 900 MiB OS-visible RAM')
    require(not swap_active and not zram_present, 'AWG requires no active swap or zram devices')
    require(disk_bytes >= disk_reserve, f'AWG requires {disk_reserve // 1024**2} MiB free workspace')
    require(secure_boot is False, 'AWG requires known-disabled Secure Boot')
    require(signature_enforced is False and lockdown == 'none',
            'AWG requires known-disabled module signature enforcement and lockdown')
    require(auto_reboot is False, 'Disable OS automatic reboot before selecting AWG')


def signing_state():
    secure_boot = False
    if Path('/sys/firmware/efi').exists():
        variables = list(Path('/sys/firmware/efi/efivars').glob('SecureBoot-*'))
        secure_boot = None
        if len(variables) == 1:
            data = variables[0].read_bytes()
            if len(data) == 5 and data[4] in (0, 1):
                secure_boot = bool(data[4])
    enforcement_path = Path('/sys/module/module/parameters/sig_enforce')
    enforcement = None
    if enforcement_path.is_file():
        raw = enforcement_path.read_text().strip()
        if raw in ('N', 'Y', '0', '1'):
            enforcement = raw in ('Y', '1')
    lockdown_path = Path('/sys/kernel/security/lockdown')
    lockdown = None
    if lockdown_path.is_file():
        match = re.search(r'\[([^]]+)\]', lockdown_path.read_text())
        if match:
            lockdown = match[1]
    elif not Path('/sys/firmware/efi').exists() and enforcement is False:
        # Unmounted securityfs is not proof of disabled lockdown; check boot policy.
        config_path = Path(f'/boot/config-{platform.release()}')
        if config_path.is_file():
            config = config_path.read_text()
            command_line = Path('/proc/cmdline').read_text()
            disabled = ('CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y' in config
                        or '# CONFIG_SECURITY_LOCKDOWN_LSM is not set' in config)
            if disabled and not re.search(r'(?:^|\s)lockdown=(?:integrity|confidentiality)(?:\s|$)', command_line):
                lockdown = 'none'
    return secure_boot, enforcement, lockdown


def swap_zram_state(swap_file=Path('/proc/swaps'), block_path=Path('/sys/block')):
    require(swap_file.is_file(), 'Cannot determine host swap state')
    require(block_path.is_dir(), 'Cannot determine host zram state')
    lines = swap_file.read_text().splitlines()
    require(lines and lines[0].split()[:4] == ['Filename', 'Type', 'Size', 'Used'],
            'Cannot determine host swap state')
    active_swap = any(line.strip() for line in lines[1:])
    zram_present = any(block_path.glob('zram*'))
    return active_swap, zram_present


def pre_hardening_check():
    config = run(['apt-config', 'dump']).stdout
    reboot = re.search(r'^Unattended-Upgrade::Automatic-Reboot\s+"([^"]*)";', config, re.M)
    auto_reboot = False if reboot is None else reboot[1].lower() not in ('false', '0', 'no')
    require(auto_reboot is False, 'Disable OS automatic reboot before selecting AWG')
    swap_active, zram_present = swap_zram_state()
    require(not swap_active and not zram_present, 'AWG requires no active swap or zram devices')
    secure_boot, enforcement, lockdown = signing_state()
    require(secure_boot is False, 'AWG requires known-disabled Secure Boot')
    require(enforcement is False and lockdown == 'none',
            'AWG requires known-disabled module signature enforcement and lockdown')


def platform_check(kernel, *, build_only=False):
    os_release = {}
    for line in Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            os_release[key] = value.strip('"')
    memory = re.search(r'^MemTotal:\s+(\d+) kB$', Path('/proc/meminfo').read_text(), re.M)
    require(memory is not None, 'Cannot determine OS-visible RAM')
    config = run(['apt-config', 'dump']).stdout
    reboot = re.search(r'^Unattended-Upgrade::Automatic-Reboot\s+"([^\"]*)";', config, re.M)
    auto_reboot = False if reboot is None else reboot[1].lower() not in ('false', '0', 'no')
    secure_boot, enforcement, lockdown = signing_state()
    disk_paths = (STATE, Path('/usr/src'), Path('/var/lib/dkms'), Path('/var/cache/apt'))
    free = []
    for path in disk_paths:
        while not path.exists():
            path = path.parent
        free.append(shutil.disk_usage(path).free)
    swap_active, zram_present = swap_zram_state()
    validate_platform(os_id=os_release.get('ID'), os_version=os_release.get('VERSION_ID'),
                      architecture=platform.machine(), kernel=kernel, ram_kib=int(memory[1]),
                      disk_bytes=min(free), tun=Path('/dev/net/tun').is_char_device(),
                      secure_boot=secure_boot, signature_enforced=enforcement,
                      lockdown=lockdown, auto_reboot=auto_reboot,
                      disk_reserve=BUILD_DISK_RESERVE_BYTES if build_only else DISK_RESERVE_BYTES,
                      swap_active=swap_active, zram_present=zram_present)
    require(Path('/run/systemd/system').is_dir(), 'AWG bounded builds require systemd')
    require(not re.search(r'AllowUnauthenticated\s+"true"|AllowInsecureRepositories\s+"true"', config, re.I),
            'APT authentication must remain enabled')
    require(Path('/proc/sys/kernel/modules_disabled').read_text().strip() == '0',
            'Kernel module loading is disabled')
    controllers = Path('/sys/fs/cgroup/cgroup.controllers')
    require(controllers.is_file() and {'memory', 'cpu'} <= set(controllers.read_text().split()),
            'AWG bounded builds require cgroup v2 memory/cpu controllers')
    require(run(['systemd-detect-virt', '--container', '--quiet'], check=False).returncode == 1,
            'AWG requires a host VM or dedicated server, not a container')
    # Package selection belongs exclusively to the isolated signed transaction.
    # Host apt-cache policy is neither a closure nor a constraint on a later resolver.
    return ['dkms', 'build-essential', f'linux-headers-{kernel}', 'kmod']


def distro_apt_boundary(directory, os_id):
    """Exclude host APT configuration from the isolated transaction.

    The transaction excludes host hooks, pins, authentication bypasses, sources,
    and cached indices. It does not delete host configuration.
    Trust assumes an honest root/dpkg/base OS and its guarded distro keyring.
    This does not prove anything against an already compromised privileged host.
    """
    require(os_id in ('debian', 'ubuntu'), 'Unsupported dependency distribution')
    root = Path(directory)
    keyring = Path('/usr/share/keyrings') / f'{os_id}-archive-keyring.gpg'
    guard(keyring)
    for name in ('parts', 'trusted', 'lists', 'lists/partial', 'archives', 'archives/partial'):
        (root / name).mkdir(mode=0o700, exist_ok=True)
    (root / 'empty').write_text('')
    if os_id == 'debian':
        entries = [('https://deb.debian.org/debian', 'bookworm bookworm-updates', 'main'),
                   ('https://security.debian.org/debian-security', 'bookworm-security', 'main')]
    else:
        entries = [('https://archive.ubuntu.com/ubuntu', 'noble noble-updates', 'main universe'),
                   ('https://security.ubuntu.com/ubuntu', 'noble-security', 'main universe'),
                   # Immutable official archive matching the supported stock-image
                   # epoch: authenticate/reinstall exact base versions retired
                   # from current indices, without upgrading or trusting dpkg alone.
                   (f'https://snapshot.ubuntu.com/ubuntu/{UBUNTU_BASE_ARCHIVE[0]}',
                    'noble noble-updates noble-security', 'main universe')]
    (root / 'distro.sources').write_text('\n\n'.join(
        f'Types: deb\nURIs: {uri}\nSuites: {suites}\nComponents: {components}\n'
        f'Architectures: amd64\nSigned-By: {keyring}\n' for uri, suites, components in entries))
    preferences = root / 'distro.preferences'
    preferences.write_text('Package: *\nPin: origin "snapshot.ubuntu.com"\nPin-Priority: -1\n'
                           if os_id == 'ubuntu' else '')
    settings = {
        'Dir::Etc::main': str(root / 'empty'), 'Dir::Etc::parts': str(root / 'parts'),
        'Dir::Etc::sourcelist': str(root / 'distro.sources'), 'Dir::Etc::sourceparts': str(root / 'parts'),
        'Dir::Etc::preferences': str(preferences), 'Dir::Etc::preferencesparts': str(root / 'parts'),
        'Dir::Etc::trusted': str(root / 'empty'), 'Dir::Etc::trustedparts': str(root / 'trusted'),
        'Dir::Etc::netrc': str(root / 'empty'), 'Dir::Etc::netrcparts': str(root / 'parts'),
        'Dir::State': str(root), 'Dir::State::lists': str(root / 'lists'),
        'Dir::State::extended_states': str(root / 'extended_states'), 'Dir::State::status': '/var/lib/dpkg/status',
        'Dir::Cache': str(root), 'Dir::Cache::archives': str(root / 'archives'), 'Dir::Cache::pkgcache': '',
        'Dir::Cache::srcpkgcache': '', 'Dir::Log': str(root),
        'APT::Install-Recommends': 'false', 'APT::Install-Suggests': 'false',
        'APT::Get::AllowUnauthenticated': 'false', 'Acquire::AllowInsecureRepositories': 'false',
        'Acquire::AllowDowngradeToInsecureRepositories': 'false',
        'Acquire::AllowWeakRepositories': 'false', 'Acquire::Check-Valid-Until': 'true',
        'Acquire::https::Verify-Peer': 'true', 'Acquire::https::Verify-Host': 'true',
        'Acquire::Retries': '0', 'Acquire::http::Timeout': '120', 'Acquire::https::Timeout': '120',
        'Dir::Bin::dpkg': '/usr/bin/dpkg', 'APT::Sandbox::User': 'root',
    }
    config = root / 'apt.conf'
    config.write_text('\n'.join(f'{key} "{value}";' for key, value in settings.items()) + '\n')
    config.chmod(0o600)
    return config


def verify_historical_release_scope(directory):
    """After apt signature verification, bind historical indices to the fixed epoch.

    No Valid-Until field is not a freshness proof. This explicit historical
    authenticity anchor never approves a newly installed dependency candidate.
    """
    root = Path(directory) / 'lists'
    stamp = UBUNTU_BASE_ARCHIVE[0]
    anchor = datetime.strptime(stamp, '%Y%m%dT%H%M%SZ').replace(tzinfo=timezone.utc)
    for suite in ('noble', 'noble-updates', 'noble-security'):
        release = root / f'snapshot.ubuntu.com_ubuntu_{stamp}_dists_{suite}_InRelease'
        guard(release)
        text = release.read_text()
        require(text.startswith('-----BEGIN PGP SIGNED MESSAGE-----'), 'Historical index lacks signed Release')
        fields = {}
        for key in ('Origin', 'Suite', 'Codename', 'Architectures', 'Components', 'Date'):
            values = re.findall(rf'^{key}: (.+)$', text, re.M)
            require(len(values) == 1, 'Malformed historical Release identity')
            fields[key] = values[0]
        require(fields['Origin'] == 'Ubuntu' and fields['Suite'] == suite and fields['Codename'] == 'noble'
                and 'amd64' in fields['Architectures'].split()
                and {'main', 'universe'} <= set(fields['Components'].split()), 'Historical Release scope differs')
        date = parsedate_to_datetime(fields['Date'])
        require(date.tzinfo is not None and date <= anchor, 'Historical Release exceeds declared epoch')
        if suite != 'noble':
            require((anchor - date).total_seconds() <= 48 * 3600, 'Historical Release is outside declared snapshot epoch')


def official_version(version, origin):
    codename = 'bookworm' if origin == 'Debian' else 'noble'
    # The dpkg status pseudo-index ('now') is not an archive provenance claim.
    origins = [item for item in version.origins if item.archive != 'now']
    require(version.downloadable and origins and all(
        item.trusted and item.origin == origin and item.codename in (
            codename, codename + '-updates', codename + '-security') for item in origins),
        f'Non-distro or unauthenticated dependency: {version.package.name}={version.version}')
    try:
        digest = version.record['SHA256']
    except KeyError as error:
        raise Refusal('Dependency lacks signed-index SHA256') from error
    require(re.fullmatch(r'[0-9a-f]{64}', digest or ''), 'Dependency lacks signed-index SHA256')
    return digest


def dependency_closure(cache, roots, origin):
    """Resolve all Depends/PreDepends, including satisfied installed alternatives.

    Installed versions must exist verbatim in signed current archives or the
    declared historical Ubuntu base anchor. New dependencies use current
    archives only; no silent downgrade, toolchain upgrade or provenance waiver.
    Essential packages supply implicit shell/core utilities required by dpkg/DKMS.
    """
    roots = list(roots) + [pkg.name for pkg in cache if pkg.essential and pkg.is_installed]
    selected = {}

    def select(pkg):
        if pkg.name in selected:
            return selected[pkg.name]
        if pkg.is_installed:
            matches = [v for v in pkg.versions if v.version == pkg.installed.version and v.downloadable]
            require(matches, f'The required installed version is unavailable in distro archives: '
                    f'{pkg.name}={pkg.installed.version}. Refresh the base image. Do not perform a broad upgrade.')
            version = matches[0]
        else:
            version = pkg.candidate
            require(version is not None, f'Missing distro dependency: {pkg.name}')
            current_sites = ('deb.debian.org', 'security.debian.org') if origin == 'Debian' else (
                'archive.ubuntu.com', 'security.ubuntu.com')
            require(any(item.archive != 'now' and getattr(item, 'site', None) in current_sites
                        for item in version.origins),
                    f'Historical archive cannot supply a new dependency: {pkg.name}')
        official_version(version, origin)
        pkg.candidate = version
        selected[pkg.name] = version
        pkg.mark_install(auto_fix=True, auto_inst=True, from_user=False)
        return version

    require(all(name in cache for name in roots), 'Missing required distro dependency package')
    queue = [select(cache[name]) for name in roots]
    while queue:
        version = queue.pop()
        for group in version.get_dependencies('Depends', 'PreDepends'):
            targets = [target for dep in group.or_dependencies for target in dep.target_versions]
            installed = [target for target in targets if target.package.is_installed
                         and target.version == target.package.installed.version]
            planned = [target for target in targets if target.package.candidate is not None
                       and target.version == target.package.candidate.version
                       and (target.package.marked_install or target.package.marked_upgrade)]
            candidates = installed or planned or [target for target in targets
                if target.package.candidate is not None and target.version == target.package.candidate.version]
            require(candidates, f'Unresolvable required dependency of {version.package.name}')
            target = candidates[0]
            if target.package.name not in selected:
                queue.append(select(target.package))
    require(not cache.broken_count, 'Broken distro dependency closure')
    for pkg in cache.get_changes():
        require(not pkg.marked_delete and pkg.name in selected, 'Resolver escaped bounded dependency closure')
        require(not pkg.is_installed or pkg.candidate.version == pkg.installed.version,
                f'Resolver would change installed version: {pkg.name}')
    # Auto-install may have changed candidates while expanding other roots.
    for name, version in selected.items():
        require(cache[name].candidate.version == version.version, f'Resolver changed exact dependency: {name}')
    return selected


def package_payload(name):
    """Detect changes since authenticated reinstall, not proof against hostile root."""
    listing = run(['/usr/bin/dpkg-query', '-L', name]).stdout.splitlines()
    digest = hashlib.sha256()
    for raw in sorted(listing):
        if not raw.startswith('/'):
            continue
        path = Path(raw)
        if not path.exists() and not path.is_symlink():
            digest.update(raw.encode() + b'\0missing\0')
            continue
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            continue
        digest.update(raw.encode() + b'\0' + str((info.st_mode, info.st_uid, info.st_gid)).encode() + b'\0')
        if stat.S_ISLNK(info.st_mode):
            digest.update(os.readlink(path).encode())
        elif stat.S_ISREG(info.st_mode):
            digest.update(bytes.fromhex(sha256(path)))
        else:
            raise Refusal(f'Unexpected dependency payload type: {path}')
    return digest.hexdigest()


def verify_deb_payload(version, directory, origin):
    """Authenticate the deb and compare its shipped files without extracting it.

    Conffile differences/diversions also fail closed: a reinstall preserving local
    configuration is not evidence that an executable/config payload is official.
    Maintainer-script generated state remains within ordinary signed-base-OS trust.
    """
    expected = official_version(version, origin)
    deb = Path(version.fetch_binary(destdir=str(directory)))
    guard(deb)
    require(sha256(deb) == expected, f'Authenticated deb checksum mismatch: {version.package.name}')
    regular = {}
    links = []
    with tempfile.TemporaryFile(dir=directory) as stream:
        result = subprocess.run(['/usr/bin/dpkg-deb', '--fsys-tarfile', str(deb)],
                                stdout=stream, stderr=subprocess.PIPE, timeout=COMMAND_TIMEOUT,
                                env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8'})
        require(result.returncode == 0, f'Cannot inspect authenticated deb: {version.package.name}')
        stream.seek(0)
        with tarfile.open(fileobj=stream, mode='r:') as bundle:
            for member in bundle:
                parts = Path(member.name).parts
                require(not member.name.startswith('/') and '..' not in parts, 'Unsafe distro deb payload path')
                target = Path('/') / Path(*parts)
                if member.isdir():
                    continue
                require(target.exists() or target.is_symlink(), f'Missing installed distro payload: {target}')
                info = target.lstat()
                if member.issym():
                    require(stat.S_ISLNK(info.st_mode) and os.readlink(target) == member.linkname
                            and info.st_uid == member.uid and info.st_gid == member.gid,
                            f'Changed installed distro symlink: {target}')
                elif member.isfile():
                    require(stat.S_ISREG(info.st_mode), f'Changed installed distro file type: {target}')
                    with bundle.extractfile(member) as payload:
                        digest = hashlib.sha256()
                        for chunk in iter(lambda: payload.read(1024 * 1024), b''):
                            digest.update(chunk)
                    expected_hash = digest.hexdigest()
                    require(sha256(target) == expected_hash and stat.S_IMODE(info.st_mode) == member.mode
                            and info.st_uid == member.uid and info.st_gid == member.gid,
                            f'Changed installed distro payload: {target}')
                    regular[Path(*parts).as_posix()] = expected_hash
                elif member.islnk():
                    link_parts = Path(member.linkname).parts
                    require(not member.linkname.startswith('/') and '..' not in link_parts, 'Unsafe distro hardlink')
                    links.append((target, Path(*link_parts).as_posix()))
                else:
                    raise Refusal(f'Unsupported distro deb payload type: {target}')
        for target, link in links:
            require(link in regular and target.is_file() and not target.is_symlink()
                    and sha256(target) == regular[link], f'Changed installed distro hardlink: {target}')
            info, source_info = target.stat(), (Path('/') / link).stat()
            require((info.st_mode, info.st_uid, info.st_gid) ==
                    (source_info.st_mode, source_info.st_uid, source_info.st_gid),
                    f'Changed installed distro hardlink metadata: {target}')
    return package_payload(version.package.name)


def dependency_roots(kernel):
    roots = {'dkms', 'build-essential', f'linux-headers-{kernel}', 'kmod', 'python3', 'python3-apt'}
    # Shell/Kbuild also use implicit base commands and generated alternatives.
    # Include their installed owners, even when apt emits no install operation.
    for command in ('sh', 'bash', 'awk', 'perl', 'gcc', 'cc', 'make', 'ld', 'as', 'nm',
                    'objcopy', 'objdump', 'strip', 'sed', 'grep', 'find', 'xargs',
                    'patch', 'tar', 'gzip', 'uname', 'python3'):
        location = shutil.which(command, path='/usr/sbin:/usr/bin:/sbin:/bin')
        if location is None:
            continue  # Missing compiler/tools must be supplied by the signed closure.
        target = Path(location).resolve(strict=True)
        locations = [target]
        # dpkg's bookworm database can still spell usrmerged files as /bin/*.
        for canonical, alias in (('/usr/bin', '/bin'), ('/usr/sbin', '/sbin'), ('/usr/lib', '/lib')):
            if target.is_relative_to(canonical):
                legacy = Path(alias) / target.relative_to(canonical)
                if legacy.resolve() == target:
                    locations.append(legacy)
        owners = []
        for path in locations:
            result = run(['/usr/bin/dpkg-query', '-S', str(path)], check=False)
            if result.returncode == 0:
                owners = result.stdout.splitlines()
                break
            require(result.returncode == 1 and 'no path found matching pattern' in result.stderr,
                    f'Cannot query installed build tool owner: {command}')
        require(owners, f'Unowned installed build tool: {command}')
        for line in owners:
            require(': ' in line, f'Cannot identify installed tool owner: {command}')
            names, owned_path = line.rsplit(': ', 1)
            require(Path(owned_path).resolve() == target, f'Ambiguous installed tool owner: {command}')
            for name in names.split(', '):
                require(re.fullmatch(r'[a-z0-9][a-z0-9+.:_-]*', name), 'Invalid tool package owner')
                roots.add(name)
    return sorted(roots)


def dependencies_worker(kernel, *, read_only=False, plan_only=False):
    # Dedicated subprocess: clear even python-apt's import-time host configuration.
    try:
        import apt
        import apt_pkg
        import apt.progress.base
    except ImportError as error:
        raise Refusal('AWG dependency authentication requires distro python3-apt') from error
    config = Path(os.environ['APT_CONFIG'])
    guard(config, private=True)
    for key in list(apt_pkg.config.keys()):
        apt_pkg.config.clear(key)
    apt_pkg.init_config()
    apt_pkg.init_system()
    os_id = 'debian' if re.search(r'^ID="?debian"?$', Path('/etc/os-release').read_text(), re.M) else 'ubuntu'
    origin = 'Debian' if os_id == 'debian' else 'Ubuntu'
    # Install: normal dpkg/frontend locking across snapshot/resolution/commit.
    # Hook authentication: strictly read-only; calling dpkg already owns its lock.
    # Neither path holds the module lock while dpkg executes DKMS/header hooks.
    with contextlib.nullcontext() if read_only else apt_pkg.SystemLock():
        cache = apt.Cache()
        require(cache.update(), 'Failed to authenticate fresh distro indices')
        cache.open()
        if os_id == 'ubuntu':
            verify_historical_release_scope(config.parent)
        selected = dependency_closure(cache, dependency_roots(kernel), origin)
        if plan_only:
            print(json.dumps(dict(feasible=True, packages=sorted(selected), origin=origin)))
            return  # No archive downloads, dpkg commit or module state initialization.
        old = read_receipt().get('dependency_audit')
        records = {name: dict(version=v.version, archive_sha256=official_version(v, origin))
                   for name, v in selected.items()}
        matching = (old is not None and old['origin'] == origin
                    and old['kernels'].get(kernel) == sorted(records)
                    and set(records) <= set(old['packages']))
        if matching:
            matching = all(cache[name].is_installed and cache[name].installed.version == record['version']
                           and old['packages'][name] == dict(record, payload_sha256=package_payload(name))
                           for name, record in records.items())
        if read_only:
            require(all(cache[name].is_installed for name in selected),
                    'Kernel hook cannot install missing dependencies; prepare dependencies first')
            require(not cache.get_changes(), 'Kernel hook authentication cannot change dpkg state')
        if not matching:
            if not read_only:
                for name in selected:
                    pkg = cache[name]
                    pkg.mark_install(auto_fix=False, auto_inst=False, from_user=False)
                    if pkg.is_installed:
                        cache._depcache.set_reinstall(pkg._pkg, True)
                require(cache.commit(apt.progress.base.AcquireProgress(), apt.progress.base.InstallProgress()),
                        'Authenticated dependency reinstall failed')
                cache.open()
            for name, record in records.items():
                require(cache[name].is_installed and cache[name].installed.version == record['version'],
                        f'Installed dependency version changed: {name}')
                versions = [v for v in cache[name].versions
                            if v.version == record['version'] and v.downloadable]
                require(versions and official_version(versions[0], origin) == record['archive_sha256'],
                        f'Authenticated dependency index changed: {name}')
                record['payload_sha256'] = verify_deb_payload(versions[0], config.parent / 'archives', origin)
            # Keep authenticated old-kernel header records for running-kernel readiness.
            merged = dict(old['packages']) if old is not None and old['origin'] == origin else {}
            merged.update(records)
            kernels = dict(old['kernels']) if old is not None and old['origin'] == origin else {}
            kernels[kernel] = sorted(records)
            audit = dict(schema=1, origin=origin, packages=merged, kernels=kernels)
            if not read_only:
                with module_lock():
                    value = inspect_state()
                    # A concurrent independent kernel hook may have published an
                    # audit since our pre-commit snapshot. Merge only our verified
                    # closure into the fresh authoritative receipt under this lock.
                    current = value.get('dependency_audit')
                    if current is None:
                        current = dict(schema=1, origin=origin, packages={}, kernels={})
                    require(current['origin'] == origin, 'Dependency audit distribution changed')
                    current['packages'].update(records)
                    current['kernels'][kernel] = sorted(records)
                    value['dependency_audit'] = current
                    write_receipt(value)
        else:
            audit = old
        print(json.dumps(dict(changed=not matching, packages=sorted(records), origin=origin,
                              **({'audit': audit} if read_only else {}))))


def verify_dependency_payloads(value, kernel):
    audit = value.get('dependency_audit')
    require(audit is not None and kernel in audit['kernels']
            and f'linux-headers-{kernel}' in audit['kernels'][kernel],
            'No authenticated dependency closure for this kernel; prepare dependencies first')
    require(set(dependency_roots(kernel)) <= set(audit['kernels'][kernel]),
            'Installed build-tool/alternative owners changed since authentication')
    for name in audit['kernels'][kernel]:
        record = audit['packages'][name]
        installed = run(['/usr/bin/dpkg-query', '-W', '-f=${Version}', name]).stdout
        # Header postinst/DKMS executes before dpkg marks that package configured.
        require(installed == record['version']
                and package_payload(name) == record['payload_sha256'],
                f'Authenticated dependency payload changed: {name}; rerun dependency preparation')


def authenticate_update_dependencies(kernel):
    """DKMS hook-safe authentication: downloads/reads only, never nested dpkg."""
    value = read_receipt()  # Malformed/unowned receipt is never an authentication miss.
    try:
        verify_dependency_payloads(value, kernel)
        return
    except Refusal:
        pass
    os_release = Path('/etc/os-release').read_text()
    os_id = 'debian' if re.search(r'^ID="?debian"?$', os_release, re.M) else 'ubuntu'
    with tempfile.TemporaryDirectory(prefix='.apt-auth.', dir=STATE) as directory:
        config = distro_apt_boundary(directory, os_id)
        env = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8',
               'APT_CONFIG': str(config), 'DEBIAN_FRONTEND': 'noninteractive'}
        result = run(['/usr/bin/python3', str(Path(__file__).resolve()), 'authenticate-worker',
                      '--kernel', kernel], env=env, timeout=BUILD_TIMEOUT + COMMAND_TIMEOUT)
        authenticated = json.loads(result.stdout.strip().splitlines()[-1])['audit']
    with module_lock():
        value = inspect_state()
        audit = value.get('dependency_audit')
        if audit is None:
            audit = dict(schema=1, origin=authenticated['origin'], packages={}, kernels={})
        require(audit['origin'] == authenticated['origin'], 'Dependency audit distribution changed')
        names = authenticated['kernels'][kernel]
        audit['packages'].update({name: authenticated['packages'][name] for name in names})
        audit['kernels'][kernel] = names
        value['dependency_audit'] = audit
        verify_dependency_payloads(value, kernel)
        write_receipt(value)


def dependency_feasibility(kernel):
    """Pre-vault feasibility uses the same isolated resolver without installing."""
    # Signed Ubuntu universe indices exceed the small /run tmpfs on 900 MiB
    # guests. Use an isolated disk-backed cache scratch, never host APT lists.
    guard(Path('/var/cache'), directory=True)
    os_release = Path('/etc/os-release').read_text()
    os_id = 'debian' if re.search(r'^ID="?debian"?$', os_release, re.M) else 'ubuntu'
    with tempfile.TemporaryDirectory(prefix='nook-awg-feasibility.', dir='/var/cache') as directory:
        config = distro_apt_boundary(directory, os_id)
        env = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8',
               'APT_CONFIG': str(config), 'DEBIAN_FRONTEND': 'noninteractive'}
        result = run(['/usr/bin/python3', str(Path(__file__).resolve()), 'dependencies-plan',
                      '--kernel', kernel], env=env, timeout=BUILD_TIMEOUT + COMMAND_TIMEOUT)
        require(json.loads(result.stdout.strip().splitlines()[-1]).get('feasible') is True,
                'Cannot establish signed distro dependency feasibility')


def dependency_slice(unit):
    require(re.fullmatch(r'nook-awg-deps-[0-9a-f]{32}', unit), 'Invalid dependency unit identity')
    return 'nook_awg_deps_' + unit.removeprefix('nook-awg-deps-') + '.slice'


def dependencies_unit(kernel):
    """The actual systemd-owned worker holds advisory and normal APT/dpkg locks."""
    unit = os.environ.get('NOOK_AWG_DEPENDENCY_UNIT', '')
    require(re.fullmatch(r'nook-awg-deps-[0-9a-f]{32}', unit), 'Invalid dependency unit identity')
    directory = STATE / ('.apt-txn.' + unit.removeprefix('nook-awg-deps-'))
    guard(directory, directory=True, private=True)
    guard(DEPENDENCY_PENDING, private=True)
    require(json.loads(DEPENDENCY_PENDING.read_text()) ==
            dict(schema=1, unit=unit, directory=str(directory)), 'Dependency transaction identity changed')
    require(Path(os.environ.get('APT_CONFIG', '')) == directory / 'apt.conf', 'Dependency APT boundary changed')
    require(os.environ.get('NOOK_AWG_DEPENDENCY_SLICE') == dependency_slice(unit),
            'Dependency slice identity changed')
    lock = STATE / 'dependencies.lock'
    fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        guard(lock, private=True)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Without acknowledgement the parent cannot distinguish a pending start
        # request from a vanished unit. It must retain the transaction boundary.
        with (directory / 'started.json').open('x') as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(dict(unit=unit, pid=os.getpid()), stream)
            stream.flush()
            os.fsync(stream.fileno())
        dependencies_worker(kernel)
    finally:
        os.close(fd)


def dependency_unit_stopped(unit, directory):
    """Positive termination proof, not merely disappearance of systemd-run."""
    acknowledgement = directory / 'started.json'
    if not acknowledgement.exists():
        return False
    guard(acknowledgement, private=True)
    started = json.loads(acknowledgement.read_text())
    require(isinstance(started, dict) and started.get('unit') == unit
            and isinstance(started.get('pid'), int) and started['pid'] > 0,
            'Malformed dependency start acknowledgement')
    slice_name = dependency_slice(unit)
    return (dependency_control_group_empty(unit + '.service', f'/{slice_name}/{unit}.service')
            and dependency_control_group_empty(slice_name, '/' + slice_name))


def dependency_control_group_empty(name, expected_group):
    result = run(['systemctl', 'show', name,
                  '--property=LoadState,ActiveState,SubState,MainPID,ControlGroup'], check=False)
    if result.returncode:
        return False
    properties = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    required = {'LoadState', 'ActiveState', 'SubState', 'ControlGroup'}
    if name.endswith('.service'):
        required.add('MainPID')
    if not required <= properties.keys():
        return False
    if properties['ActiveState'] not in ('inactive', 'failed') or properties.get('MainPID', '0') != '0':
        return False
    if properties['LoadState'] == 'not-found':
        return properties['ControlGroup'] == '' and properties['SubState'] == 'dead'
    if properties['LoadState'] != 'loaded':
        return False
    group = properties['ControlGroup']
    if not group:
        return properties['SubState'] in ('dead', 'failed')
    require(group == expected_group, 'Unexpected dependency control group')
    cgroup = Path('/sys/fs/cgroup') / group.lstrip('/')
    if not cgroup.exists():
        return True  # A removed cgroup cannot still contain a descendant.
    events = cgroup / 'cgroup.events'
    if not events.is_file():
        return False
    return bool(re.search(r'^populated 0$', events.read_text(), re.M))


def run_dependency_transaction(kernel, config, unit, directory):
    """Stop/wait the owned group on all exits; retain uncertain transaction state."""
    previous = signal.getsignal(signal.SIGTERM)

    def cancelled(signum, frame):
        raise Refusal('Dependency transaction cancelled; package state is not rolled back')

    signal.signal(signal.SIGTERM, cancelled)
    error = None
    result = None
    try:
        try:
            result = run(['systemd-run', '--quiet', '--wait', '--pipe', '--service-type=exec',
                          f'--unit={unit}', f'--slice={dependency_slice(unit)}',
                          '-p', f'MemoryMax={BUILD_MEMORY}', '-p', 'MemorySwapMax=0',
                          '-p', f'RuntimeMaxSec={DEPENDENCY_TIMEOUT}', '-p', 'KillMode=control-group',
                          '-p', f'TimeoutStopSec={DEPENDENCY_STOP_TIMEOUT}', '-p', 'SendSIGKILL=yes',
                          '-p', 'UnsetEnvironment=LD_PRELOAD LD_LIBRARY_PATH PYTHONPATH PYTHONHOME NOOK_AWG_LOCK_FD',
                          '--setenv=PATH=/usr/sbin:/usr/bin:/sbin:/bin', '--setenv=LANG=C.UTF-8',
                          f'--setenv=APT_CONFIG={config}', '--setenv=DEBIAN_FRONTEND=noninteractive',
                          f'--setenv=NOOK_AWG_DEPENDENCY_UNIT={unit}',
                          f'--setenv=NOOK_AWG_DEPENDENCY_SLICE={dependency_slice(unit)}',
                          '/usr/bin/python3', '-I', str(Path(__file__).resolve()), 'dependencies-unit',
                          '--kernel', kernel], timeout=DEPENDENCY_TIMEOUT + DEPENDENCY_STOP_TIMEOUT + COMMAND_TIMEOUT)
        except BaseException as failure:
            error = failure
        # stop waits for the job, including control-group SIGKILL escalation.
        # Check acknowledgement + unit/cgroup even after a successful worker exit.
        try:
            run(['systemctl', 'stop', unit + '.service', dependency_slice(unit)], check=False,
                timeout=DEPENDENCY_STOP_TIMEOUT + COMMAND_TIMEOUT)
            stopped = dependency_unit_stopped(unit, directory)
        except BaseException:
            stopped = False
        if not stopped:
            raise Refusal(f'Dependency unit termination unconfirmed: {unit}; preserve {directory} and '
                          f'{DEPENDENCY_PENDING} as the transaction lock; no package rollback claimed') from error
        guard(DEPENDENCY_PENDING, private=True)
        require(json.loads(DEPENDENCY_PENDING.read_text()) ==
                dict(schema=1, unit=unit, directory=str(directory)), 'Dependency transaction identity changed')
        guard(directory, directory=True, private=True)
        require(directory.parent == STATE and directory.name == '.apt-txn.' + unit.removeprefix('nook-awg-deps-'),
                'Unexpected dependency cleanup path')
        shutil.rmtree(directory)
        DEPENDENCY_PENDING.unlink()
        sync_state_directory()
        if error is not None:
            raise error
        return result
    finally:
        signal.signal(signal.SIGTERM, previous)


def install_dependencies(kernel):
    platform_check(kernel)
    inspect_state()
    guard(STATE, directory=True, private=True)
    # Persistent exclusive marker survives caller SIGKILL/reboot and acts as a
    # fail-closed logical lock if cgroup termination cannot be established.
    require(not DEPENDENCY_PENDING.exists() and not DEPENDENCY_PENDING.is_symlink(),
            'Interrupted/active dependency transaction; preserve its private boundary and recover explicitly')
    unit = 'nook-awg-deps-' + secrets.token_hex(16)
    directory = STATE / ('.apt-txn.' + unit.removeprefix('nook-awg-deps-'))
    directory.mkdir(mode=0o700)
    try:
        with DEPENDENCY_PENDING.open('x') as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(dict(schema=1, unit=unit, directory=str(directory)), stream)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        guard(directory, directory=True, private=True)
        require(directory.parent == STATE and directory.name == '.apt-txn.' + unit.removeprefix('nook-awg-deps-'),
                'Unexpected dependency staging path')
        directory.rmdir()  # Empty owned directory; no unit start request was sent.
        raise
    # Commit marker/directory entries before privileged work; on failure retain
    # both as a fail-closed transaction boundary (no unit start was requested).
    sync_state_directory()
    os_release = Path('/etc/os-release').read_text()
    os_id = 'debian' if re.search(r'^ID="?debian"?$', os_release, re.M) else 'ubuntu'
    config = distro_apt_boundary(directory, os_id)
    result = run_dependency_transaction(kernel, config, unit, directory)
    print(result.stdout.strip().splitlines()[-1])


def tree_hash(path):
    digest = hashlib.sha256()
    for item in sorted(path.rglob('*')):
        relative = item.relative_to(path)
        if relative.as_posix() == 'dkms.conf':
            continue
        info = item.lstat()
        require(not stat.S_ISLNK(info.st_mode), f'Symlink in AWG source: {relative}')
        if item.is_file():
            digest.update(relative.as_posix().encode() + b'\0' + bytes.fromhex(sha256(item)))
    return digest.hexdigest()


def dkms_config():
    return '\n'.join((
        f'PACKAGE_NAME="{MODULE}"', f'PACKAGE_VERSION="{DKMS_VERSION}"',
        f'BUILT_MODULE_NAME[0]="{MODULE}"', 'DEST_MODULE_LOCATION[0]="/updates/dkms"',
        'AUTOINSTALL="yes"',
        'POST_BUILD="nook-post-build ${kernelver}"',
        f'MAKE[0]="/usr/bin/python3 {OWNER} compile --kernel ${{kernelver}}"',
        'POST_INSTALL="nook-post-install ${kernelver}"',
        ''))


def verify_source(value):
    guard(SOURCE, directory=True)
    require(tree_hash(SOURCE) == value.get('tree_sha256'), 'AWG source tree changed')
    require((SOURCE / 'dkms.conf').read_text() == dkms_config(), 'AWG DKMS configuration changed')
    require((SOURCE / 'nook-post-install').stat().st_mode & 0o100, 'AWG post-install gate is not executable')


def inspect_state():
    if not STATE.exists() and not STATE.is_symlink():
        require(not SOURCE.exists() and not SOURCE.is_symlink(), 'Foreign AWG source directory')
        require(not Path('/var/lib/dkms/amneziawg').exists(), 'Foreign AWG DKMS state')
        return None
    guard(STATE, directory=True, private=True)
    require(RECEIPT.exists(), 'AWG state has no authoritative receipt; preserve for recovery')
    guard(RECEIPT, private=True)
    value = read_receipt()
    for path in (ARCHIVE, LOCK, STATE / 'dependencies.lock', DEPENDENCY_PENDING):
        if path.exists() or path.is_symlink():
            guard(path, private=True)
            if path == ARCHIVE:
                require(sha256(path) == ARCHIVE_SHA256, 'Managed AWG archive changed; preserve it')
    if SOURCE.exists() or SOURCE.is_symlink():
        verify_source(value)
        dkms_root = Path('/var/lib/dkms') / MODULE
        if dkms_root.exists() or dkms_root.is_symlink():
            guard(dkms_root, directory=True)
            for entry in dkms_root.iterdir():
                if entry.name == DKMS_VERSION:
                    guard(entry, directory=True)
                else:
                    require(entry.name.startswith('kernel-') and entry.is_symlink()
                            and str(entry.readlink()).startswith(DKMS_VERSION + "/"), 'Foreign DKMS version or active link')
    elif value.get('tree_sha256'):
        raise Refusal('Managed AWG source disappeared')
    return value


def module_info(kernel):
    result = run(['modinfo', '-k', kernel, MODULE], check=False)
    if result.returncode:
        require(result.returncode == 1 and 'not found' in result.stderr,
                f'Cannot inspect AWG module: {result.stderr.strip()}')
        return None
    info = {}
    for line in result.stdout.splitlines():
        if ':' in line:
            key, value = line.split(':', 1)
            info[key] = value.strip()
    filename = Path(info.get('filename', ''))
    guard(filename)
    vermagic = info.get('vermagic', '').split()
    require(info.get('version') == VERSION and vermagic and vermagic[0] == kernel,
            'AWG module version/vermagic mismatch')
    require(str(filename).startswith(f'/lib/modules/{kernel}/updates/dkms/'), 'Foreign AWG module path')
    info['sha256'] = sha256(filename)
    return info


def verify_installed(value, kernel):
    info = module_info(kernel)
    record = value['kernels'].get(kernel, {})
    phase = record.get('phase')
    expected_hash = record.get('candidate_sha256') if phase == 'built' else record.get('module_sha256')
    expected_source = record.get('raw_srcversion') if phase == 'built' else record.get('srcversion')
    require(info is not None and expected_hash == info['sha256']
            and expected_source == info.get('srcversion')
            and phase in ('built', 'installed', 'loaded', 'ready'), 'Unattributable AWG module')
    return info


def guard_managed_destinations():
    for directory in (OWNER.parent.parent, OWNER.parent,
                      Path('/etc/kernel/header_postinst.d'), Path('/etc/kernel/postinst.d')):
        if directory.exists() or directory.is_symlink():
            guard(directory, directory=True)
    if OWNER.exists() or OWNER.is_symlink():
        guard(OWNER)
        require(sha256(OWNER) == sha256(Path(__file__)), 'Foreign or different AWG helper; preserve it')
    for directory in (Path('/etc/modules-load.d'), Path('/etc/modprobe.d')):
        guard(directory, directory=True)
    if MODULES_LOAD_FILE.exists() or MODULES_LOAD_FILE.is_symlink():
        guard(MODULES_LOAD_FILE)
        require(MODULES_LOAD_FILE.read_text().strip() == MODULE, 'Foreign AWG persistence file')
    hook_content = '#!/bin/sh\nset -eu\nexec /usr/bin/python3 /usr/local/lib/vps-nook/awg_module.py verify-update --kernel "$1"\n'
    for path in (Path('/etc/kernel/header_postinst.d/zz-vps-nook-awg'),
                 Path('/etc/kernel/postinst.d/zz-vps-nook-awg')):
        if path.exists() or path.is_symlink():
            guard(path)
            require(path.read_text() == hook_content, 'Foreign AWG kernel hook; preserve it')


def preflight(kernel, *, build_only=False):
    guard_managed_destinations()
    platform_check(kernel, build_only=build_only)
    value = inspect_state()
    if not build_only:
        dependency_feasibility(kernel)
    if shutil.which('modinfo'):
        info = module_info(kernel)
        if info:
            require(value is not None, 'Foreign installed AWG module')
            verify_installed(value, kernel)
    loaded = LOADED
    if loaded.exists():
        require(value is not None, 'Foreign loaded AWG module')
        info = verify_installed(value, platform.release())
        require((loaded / 'version').read_text().strip() == VERSION
                and (loaded / 'srcversion').read_text().strip() == info.get('srcversion'),
                'Loaded AWG module identity mismatch')
    return value


@contextlib.contextmanager
def module_lock():
    guard(STATE, directory=True, private=True)
    inherited = os.environ.get(LOCK_ENV)
    if inherited is not None:
        fd = int(inherited)
        info = os.fstat(fd)
        expected = LOCK.lstat()
        require(info.st_ino == expected.st_ino and info.st_dev == expected.st_dev
                and info.st_uid == 0 and stat.S_ISREG(info.st_mode), 'Invalid inherited module lock')
        yield fd
        return
    fd = os.open(LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        guard(LOCK, private=True)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield fd
    finally:
        os.close(fd)


def initialize():
    if STATE.exists() or STATE.is_symlink():
        return inspect_state()
    for parent in (STATE.parent, STATE):
        if parent.exists() or parent.is_symlink():
            guard(parent, directory=True, private=parent == STATE)
        else:
            guard(parent.parent, directory=True)
            parent.mkdir(mode=0o700)
    value = dict(schema=SCHEMA, source_commit=SOURCE_COMMIT,
                 archive_sha256=ARCHIVE_SHA256, phase='initialized', kernels={})
    write_receipt(value)
    return value


def stage_source(value, archive):
    guard(archive)
    require(sha256(archive) == ARCHIVE_SHA256, 'AWG archive checksum mismatch')
    if SOURCE.exists() or SOURCE.is_symlink():
        verify_source(value)
        return
    require(not value.get('tree_sha256'), 'Managed source missing; refusing replacement')
    with tempfile.TemporaryDirectory(prefix='.awg-source.', dir=STATE) as directory:
        staging = Path(directory)
        with tarfile.open(archive, 'r:gz') as bundle:
            for member in bundle.getmembers():
                parts = Path(member.name).parts
                require(parts and parts[0] == f'amneziawg-linux-kernel-module-{SOURCE_COMMIT}'
                        and '..' not in parts and not member.name.startswith('/')
                        and (member.isfile() or member.isdir()), 'Unsafe AWG archive member')
                if len(parts) < 3 or parts[1] != 'src':
                    continue
                target = staging.joinpath(*parts[2:])
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True, mode=0o755)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                with bundle.extractfile(member) as stream, target.open('xb') as destination:
                    shutil.copyfileobj(stream, destination)
                target.chmod(0o644)
        require((staging / 'Makefile').is_file(), 'AWG archive lacks build owner')
        (staging / 'dkms.conf').write_text(dkms_config())
        hook = staging / 'nook-post-install'
        hook.write_text(f'#!/bin/sh\nset -eu\nexec /usr/bin/python3 {OWNER} record-installed --kernel "$1"\n')
        hook.chmod(0o700)
        post_build = staging / 'nook-post-build'
        post_build.write_text(f'#!/bin/sh\nset -eu\nexec /usr/bin/python3 {OWNER} record-built --kernel "$1"\n')
        post_build.chmod(0o700)
        value['phase'] = 'source_verified'
        value['tree_sha256'] = tree_hash(staging)
        # Publish only to a new absent source path; never overwrite operator state.
        shutil.copytree(staging, SOURCE)
    write_receipt(value)


def bounded_make(kernel):
    # Called only inside the systemd unit; the parent retains the module lock.
    start = time.monotonic()
    headers = Path('/usr/src') / f'linux-headers-{kernel}'
    guard(headers, directory=True)
    require(Path(f'/lib/modules/{kernel}/build').resolve() == headers,
            'Running-kernel header build path is not the authenticated distro header directory')
    run(['/usr/bin/make', '-j1', f'KERNELRELEASE={kernel}',
         f'KERNELDIR={headers}', f'WIREGUARD_VERSION={VERSION}'],
        timeout=BUILD_TIMEOUT, env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8'})
    lines = Path('/proc/self/cgroup').read_text().splitlines()
    paths = [line.split(':', 2)[2] for line in lines if line.startswith('0::')]
    require(len(paths) == 1, 'AWG build requires measurable cgroup v2 memory limits')
    cgroup = Path('/sys/fs/cgroup') / paths[0].lstrip('/')
    peak = int((cgroup / 'memory.peak').read_text().strip())
    require(peak <= BUILD_MEMORY_BYTES, 'AWG build exceeded its memory budget')
    print(json.dumps(dict(elapsed_seconds=round(time.monotonic() - start, 3),
                          cgroup_memory_peak_bytes=peak,
                          workspace_bytes=sum(p.stat().st_size for p in Path.cwd().rglob('*') if p.is_file()),
                          free_disk_bytes=shutil.disk_usage(STATE).free)))


def dependency_build_scope():
    # Compile's systemd-run normally creates a sibling service. During an APT
    # transaction it must remain inside the same owned slice, even if a distro
    # maintainer script did not forward our environment variable.
    paths = [line.split(':', 2)[2] for line in Path('/proc/self/cgroup').read_text().splitlines()
             if line.startswith('0::')]
    slices = [match[1] for path in paths for match in re.finditer(
        r'(?:^|/)(nook_awg_deps_[0-9a-f]{32}\.slice)(?:/|$)', path)]
    configured = os.environ.get('NOOK_AWG_DEPENDENCY_SLICE')
    if not slices and configured is None:
        return []
    require(len(slices) == 1 and (configured is None or configured == slices[0]),
            'Cannot identify owned dependency build slice')
    guard(DEPENDENCY_PENDING, private=True)
    pending = json.loads(DEPENDENCY_PENDING.read_text())
    require(isinstance(pending, dict) and slices[0] == dependency_slice(pending.get('unit', '')),
            'Dependency build slice transaction changed')
    return ['--slice=' + slices[0]]


def compile_module(kernel):
    # During normal signed kernel updates dpkg owns its lock: authenticate newly
    # installed headers/tools read-only, before compiling, without nested installs.
    platform_check(kernel, build_only=True)
    verify_source(read_receipt())
    authenticate_update_dependencies(kernel)
    with module_lock():
        value = read_receipt()
        platform_check(kernel, build_only=True)
        verify_dependency_payloads(value, kernel)
        verify_source(value)
        build = Path.cwd()
        require(str(build).startswith(f'/var/lib/dkms/{MODULE}/{DKMS_VERSION}/'), 'Unexpected DKMS build path')
        result = run(['systemd-run', '--quiet', '--wait', '--pipe', '--collect',
                      *dependency_build_scope(), f'--unit=nook-awg-build-{kernel}', f'--working-directory={build}',
                      '-p', f'MemoryMax={BUILD_MEMORY}', '-p', 'MemorySwapMax=0',
                      '-p', 'CPUQuota=100%', '-p', f'RuntimeMaxSec={BUILD_TIMEOUT}',
                      '-p', 'KillMode=control-group', '-p', f'TimeoutStopSec={DEPENDENCY_STOP_TIMEOUT}',
                      '-p', 'SendSIGKILL=yes', '-p', 'PrivateNetwork=yes', '/usr/bin/python3', str(OWNER), 'bounded-make',
                      '--kernel', kernel], timeout=BUILD_TIMEOUT + COMMAND_TIMEOUT)
        info = run(['modinfo', str(build / 'amneziawg.ko')]).stdout
        require('version:' in info and VERSION in info and kernel in info, 'Built module identity mismatch')
        source_version = re.search(r'^srcversion:\s+(\S+)$', info, re.M)
        require(source_version is not None, 'Built module lacks source identity')
        metrics = json.loads(result.stdout.strip().splitlines()[-1])
        value['kernels'][kernel] = dict(phase='built', built_sha256=sha256(build / 'amneziawg.ko'),
                                       dkms_config_sha256=sha256(SOURCE / 'dkms.conf'), build_metrics=metrics,
                                       raw_srcversion=source_version[1])
        write_receipt(value)
        print(result.stdout.strip())


def record_built(kernel):
    with module_lock():
        value = read_receipt()
        verify_source(value)
        record = value['kernels'].get(kernel)
        require(record is not None and record['phase'] == 'built', 'No successful AWG compiler receipt')
        artifacts = Path(f'/var/lib/dkms/{MODULE}/{DKMS_VERSION}/{kernel}/x86_64/module')
        candidates = list(artifacts.glob('amneziawg.ko*'))
        require(len(candidates) == 1, 'Ambiguous DKMS candidate')
        guard(candidates[0])
        metadata = run(['modinfo', str(candidates[0])]).stdout
        require(re.search(rf'^srcversion:\s+{re.escape(record["raw_srcversion"])}$', metadata, re.M),
                'DKMS candidate source identity changed')
        record['candidate_sha256'] = sha256(candidates[0])
        write_receipt(value)


def stamp_installed(value, kernel, info):
    record = value['kernels'].get(kernel)
    require(record is not None and record['phase'] == 'built'
            and record.get('candidate_sha256') == info['sha256']
            and record.get('raw_srcversion') == info.get('srcversion'), 'No verified DKMS install candidate')
    record['headers_package'] = run(['dpkg-query', '-W', '-f=${Version}', f'linux-headers-{kernel}']).stdout
    record['compiler_package'] = run(['dpkg-query', '-W', '-f=${Version}', 'gcc']).stdout
    record.update(phase='installed', module_sha256=info['sha256'],
                  srcversion=info.get('srcversion'), vermagic=info['vermagic'])
    write_receipt(value)


def record_installed(kernel):
    with module_lock():
        value = read_receipt()
        verify_source(value)
        # DKMS runs POST_INSTALL before its own depmod and ignores hook status.
        run(['depmod', '-a', kernel])
        info = module_info(kernel)
        require(info is not None, 'DKMS did not install AWG module')
        stamp_installed(value, kernel, info)


def mark_ready(kernel):
    with module_lock():
        value = inspect_state()
        info = verify_installed(value, kernel)
        guard(MODULES_LOAD_FILE)
        require(MODULES_LOAD_FILE.read_text().strip() == MODULE, 'AWG module persistence is missing')
        require((LOADED / 'version').read_text().strip() == VERSION
                and (LOADED / 'srcversion').read_text().strip() == info['srcversion'],
                'Loaded AWG identity mismatch')
        changed = value['kernels'][kernel]['phase'] != 'ready'
        if changed:
            value['kernels'][kernel]['phase'] = 'ready'
            write_receipt(value)
        print(json.dumps(dict(changed=changed, kernel=kernel, phase='ready')))


def prepare(kernel, archive):
    preflight(kernel, build_only=True)
    initialize()
    with module_lock() as fd:
        value = inspect_state()
        verify_dependency_payloads(value, kernel)
        stage_source(value, archive)
        value = read_receipt()
        info = module_info(kernel)
        changed = info is None
        if info:
            verify_installed(value, kernel)
            if value['kernels'][kernel]['phase'] == 'built':
                run(['depmod', '-a', kernel])
                stamp_installed(value, kernel, info)
        else:
            env = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8', LOCK_ENV: str(fd)}
            status = run(['dkms', 'status', '-m', MODULE, '-v', DKMS_VERSION]).stdout.strip()
            if not status:
                run(['dkms', 'add', '-m', MODULE, '-v', DKMS_VERSION], pass_fds=(fd,), env=env)
            if value['kernels'].get(kernel, {}).get('phase') != 'built':
                run(['dkms', 'build', '-m', MODULE, '-v', DKMS_VERSION, '-k', kernel],
                    timeout=BUILD_TIMEOUT + COMMAND_TIMEOUT, pass_fds=(fd,), env=env)
            run(['dkms', 'install', '-m', MODULE, '-v', DKMS_VERSION, '-k', kernel],
                timeout=BUILD_TIMEOUT + COMMAND_TIMEOUT, pass_fds=(fd,), env=env)
            value = read_receipt()
            info = verify_installed(value, kernel)
        run(['modprobe', MODULE])
        loaded = LOADED
        require((loaded / 'version').read_text().strip() == VERSION
                and (loaded / 'srcversion').read_text().strip() == info['srcversion'],
                'Loaded AWG identity mismatch')
        phase = value['kernels'][kernel]['phase']
        if phase != 'ready':
            value['kernels'][kernel]['phase'] = 'loaded'
            write_receipt(value)
            phase = 'loaded'
        print(json.dumps(dict(changed=changed, kernel=kernel, phase=phase)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('pre-hardening', 'preflight', 'initialize', 'dependencies',
                                         'dependencies-unit', 'dependencies-plan', 'authenticate-worker',
                                         'prepare', 'compile', 'record-installed',
                                         'record-built', 'ready', 'verify-update', 'bounded-make'))
    parser.add_argument('--kernel', default=platform.release())
    parser.add_argument('--archive', type=Path, default=ARCHIVE)
    args = parser.parse_args()
    require(os.geteuid() == 0, 'AWG preparation requires root')
    require(re.fullmatch(r'[A-Za-z0-9_.+-]+', args.kernel), 'Invalid kernel identifier')
    if args.action == 'pre-hardening':
        pre_hardening_check()
        print(json.dumps(dict(feasible=True)))
    elif args.action == 'preflight':
        preflight(args.kernel)
        print(json.dumps(dict(kernel=args.kernel, feasible=True)))
    elif args.action == 'initialize':
        preflight(args.kernel)
        existed = RECEIPT.exists()
        initialize()
        print(json.dumps(dict(changed=not existed, packages=platform_check(args.kernel),
                              source_url=SOURCE_URL, archive_checksum=f'sha256:{ARCHIVE_SHA256}')))
    elif args.action == 'dependencies':
        install_dependencies(args.kernel)
    elif args.action == 'dependencies-unit':
        dependencies_unit(args.kernel)
    elif args.action in ('dependencies-plan', 'authenticate-worker'):
        dependencies_worker(args.kernel, read_only=args.action == 'authenticate-worker',
                            plan_only=args.action == 'dependencies-plan')
    elif args.action == 'prepare':
        prepare(args.kernel, args.archive)
    elif args.action == 'ready':
        mark_ready(args.kernel)
    elif args.action == 'record-built':
        record_built(args.kernel)
    elif args.action == 'verify-update':
        platform_check(args.kernel, build_only=True)
        with module_lock():
            value = inspect_state()
            require(value is not None, 'No managed AWG update state')
            verify_installed(value, args.kernel)
    elif args.action == 'bounded-make':
        bounded_make(args.kernel)
    elif args.action == 'compile':
        compile_module(args.kernel)
    else:
        record_installed(args.kernel)


if __name__ == '__main__':
    try:
        main()
    except (Refusal, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f'AWG refused: {error}', file=sys.stderr)
        sys.exit(1)
