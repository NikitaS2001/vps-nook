"""The QEMU stock-image cache is content-addressed and fails closed."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import stat

import pytest

pytestmark = pytest.mark.quick
ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tests/e2e/qemu_image_cache.py"
REGISTRY = ROOT / "tests/registry.py"


@pytest.fixture
def tmp_path():
    # Production rejects shared/writable ancestors, including /tmp. Exercise the
    # real guard in a private caller-owned home subtree, independent of TMPDIR.
    parent = Path.home().resolve()
    # The existing autouse remove_private_test_state owns the single cleanup.
    return Path(tempfile.mkdtemp(prefix='.nook-image-cache-test.', dir=parent))


@pytest.fixture
def owner():
    spec = importlib.util.spec_from_file_location("qemu_image_cache", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def private_dir(path):
    path.mkdir(mode=0o700)
    path.chmod(0o700)
    return path


def test_only_fixed_registry_stock_pairs_are_cacheable(owner):
    pairs = owner.registered_stock_pairs(REGISTRY)
    assert len(pairs) == 2
    assert all(url.startswith("https://") and len(checksum) == 64 for url, checksum in pairs)
    url, checksum = next(iter(pairs))
    assert (url, checksum) in pairs
    assert (url + ".prepared-awg", checksum) not in pairs


def test_miss_publishes_verified_cache_and_hit_avoids_download(owner, tmp_path):
    payload = b"fixture bytes representing the exact stock image"
    checksum = hashlib.sha256(payload).hexdigest()
    url = "https://fixture.invalid/stock.img"
    allowed = {(url, checksum)}
    cache = tmp_path / "cache"
    run_dir = private_dir(tmp_path / "run")
    calls = []

    def download(requested_url, output):
        calls.append(requested_url)
        output.write(payload)

    first = run_dir / "first.img"
    assert owner.cache_stock_image(url, checksum, cache, first, allowed_pairs=allowed,
                                   downloader=download) is False
    cache_file = cache / f"{checksum}.img"
    assert cache_file.read_bytes() == payload
    assert first.read_bytes() == payload
    assert stat.S_IMODE(cache_file.stat().st_mode) == 0o600
    assert cache_file.stat().st_nlink == 1

    second = run_dir / "second.img"
    assert owner.cache_stock_image(url, checksum, cache, second, allowed_pairs=allowed,
                                   downloader=lambda *_: pytest.fail("cache hit attempted download")) is True
    assert second.read_bytes() == payload
    assert calls == [url]


def test_cache_only_prep_publishes_no_per_run_file(owner, tmp_path):
    payload = b"verified stock image"
    checksum = hashlib.sha256(payload).hexdigest()
    url = "https://fixture.invalid/stock.img"
    cache = tmp_path / "cache"
    assert owner.cache_stock_image(url, checksum, cache, None,
                                   allowed_pairs={(url, checksum)},
                                   downloader=lambda _url, output: output.write(payload)) is False
    assert (cache / f"{checksum}.img").read_bytes() == payload
    assert not list(tmp_path.glob("*.img"))


def test_bad_download_digest_is_not_published(owner, tmp_path):
    expected = hashlib.sha256(b"expected").hexdigest()
    url = "https://fixture.invalid/bad.img"
    cache = tmp_path / "cache"
    run_dir = private_dir(tmp_path / "run")
    destination = run_dir / "cloud.img"

    def corrupt_download(_url, output):
        output.write(b"truncated or changed bytes")

    with pytest.raises(owner.CacheRefusal, match="not publishing"):
        owner.cache_stock_image(url, expected, cache, destination,
                                allowed_pairs={(url, expected)}, downloader=corrupt_download)
    assert not (cache / f"{expected}.img").exists()
    assert not destination.exists()
    assert not list(cache.glob(f".{expected}.download.*"))


def test_corrupt_existing_cache_is_preserved_and_refused(owner, tmp_path):
    payload = b"correct"
    checksum = hashlib.sha256(payload).hexdigest()
    url = "https://fixture.invalid/stock.img"
    cache = private_dir(tmp_path / "cache")
    run_dir = private_dir(tmp_path / "run")
    cache_file = cache / f"{checksum}.img"
    cache_file.write_bytes(b"operator-owned bad bytes")
    cache_file.chmod(0o600)
    before = cache_file.read_bytes()

    with pytest.raises(owner.CacheRefusal, match="preserving"):
        owner.cache_stock_image(url, checksum, cache, run_dir / "cloud.img",
                                allowed_pairs={(url, checksum)},
                                downloader=lambda *_: pytest.fail("must not overwrite corrupt entry"))
    assert cache_file.read_bytes() == before
    assert not (run_dir / "cloud.img").exists()


def test_symlink_cache_directory_is_refused(owner, tmp_path):
    target = private_dir(tmp_path / "target")
    link = tmp_path / "link"
    link.symlink_to(target, target_is_directory=True)
    run_dir = private_dir(tmp_path / "run")
    payload = b"stock"
    checksum = hashlib.sha256(payload).hexdigest()
    url = "https://fixture.invalid/stock.img"

    with pytest.raises(owner.CacheRefusal, match="symlink"):
        owner.cache_stock_image(url, checksum, link, run_dir / "cloud.img",
                                allowed_pairs={(url, checksum)},
                                downloader=lambda _url, stream: stream.write(payload))
    assert not (target / f"{checksum}.img").exists()


def test_wrong_cache_mode_and_destination_collision_fail_closed(owner, tmp_path):
    payload = b"stock"
    checksum = hashlib.sha256(payload).hexdigest()
    url = "https://fixture.invalid/stock.img"
    cache = private_dir(tmp_path / "cache")
    cache.chmod(0o755)
    run_dir = private_dir(tmp_path / "run")
    destination = run_dir / "existing.img"
    destination.write_bytes(b"operator file")
    before = destination.read_bytes()

    with pytest.raises(owner.CacheRefusal, match="mode 0700"):
        owner.cache_stock_image(url, checksum, cache, run_dir / "unused.img",
                                allowed_pairs={(url, checksum)},
                                downloader=lambda _url, stream: stream.write(payload))
    cache.chmod(0o700)
    with pytest.raises(owner.CacheRefusal, match="overwrite"):
        owner.cache_stock_image(url, checksum, cache, destination,
                                allowed_pairs={(url, checksum)},
                                downloader=lambda _url, stream: stream.write(payload))
    assert destination.read_bytes() == before
    assert not (cache / f"{checksum}.img").exists()


def test_unregistered_pair_does_not_create_cache_or_download(owner, tmp_path):
    cache = tmp_path / "cache"
    run_dir = private_dir(tmp_path / "run")
    destination = run_dir / "cloud.img"
    result = owner.cache_stock_image("https://example.invalid/modified.img", "0" * 64,
                                     cache, destination, allowed_pairs=set(),
                                     downloader=lambda *_: pytest.fail("unregistered download"))
    assert result is False
    assert not cache.exists()
    assert not destination.exists()


def test_cache_only_cli_accepts_only_registry_pair(owner, tmp_path, monkeypatch, capsys):
    payload = b"registered fixture image"
    checksum = hashlib.sha256(payload).hexdigest()
    url = "https://fixture.invalid/stock.img"
    registry = tmp_path / "registry.py"
    registry.write_text(f"FRESH_IMAGES = {{'fixture': ({url!r}, {checksum!r}, 'ubuntu', '963')}}\n")
    cache = tmp_path / "cache"

    def download(_url, output):
        output.write(payload)

    monkeypatch.setattr(owner, "_download_curl", download)
    result = owner.main(["--cache-only", url, checksum, str(cache), str(registry)])
    assert result == 0
    assert "verified_stock_image_cache=published" in capsys.readouterr().out
    assert (cache / f"{checksum}.img").read_bytes() == payload

    assert owner.main(["--cache-only", url, "0" * 64, str(cache), str(registry)]) == 1
    assert "mismatched digest" in capsys.readouterr().err


def test_writable_parent_is_refused_before_cache_creation_or_download(owner, tmp_path):
    shared = private_dir(tmp_path / 'shared')
    shared.chmod(0o777)
    cache = shared / 'cache'
    payload = b'stock'
    checksum = hashlib.sha256(payload).hexdigest()
    url = 'https://fixture.invalid/stock.img'
    with pytest.raises(owner.CacheRefusal, match='writable parent'):
        owner.cache_stock_image(url, checksum, cache, None, allowed_pairs={(url, checksum)},
                                downloader=lambda *_: pytest.fail('unsafe parent reached downloader'))
    assert not cache.exists()


def test_downloader_is_bounded_and_has_no_retry(owner):
    argv = owner.curl_argv("https://fixture.invalid/stock.img")
    assert "--connect-timeout" in argv and str(owner.CURL_CONNECT_SECONDS) in argv
    assert "--max-time" in argv and str(owner.CURL_MAX_SECONDS) in argv
    assert "--max-filesize" in argv
    assert "--proto" in argv and "=https" in argv
    assert "--retry" not in argv
