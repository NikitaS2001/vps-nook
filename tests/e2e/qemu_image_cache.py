#!/usr/bin/env python3
"""Stage only registry-pinned stock QEMU images in a private SHA cache."""
import argparse
import ast
import fcntl
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

MAX_IMAGE_BYTES = 2 * 1024**3
CURL_MAX_SECONDS = 1800
CURL_CONNECT_SECONDS = 15


class CacheRefusal(RuntimeError):
    """Unsafe, untrusted, or unverifiable cache input; preserve existing files."""


def registered_stock_pairs(registry_path):
    tree = ast.parse(Path(registry_path).read_text(encoding="utf-8"), filename=str(registry_path))
    values = None
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == "FRESH_IMAGES" for target in node.targets
        ):
            values = ast.literal_eval(node.value)
            break
    if not isinstance(values, dict) or not values:
        raise CacheRefusal("fresh-image registry is missing or malformed")
    pairs = set()
    for item in values.values():
        if not isinstance(item, tuple) or len(item) != 4:
            raise CacheRefusal("fresh-image registry entry is malformed")
        url, checksum = item[:2]
        if not isinstance(url, str) or not url.startswith("https://"):
            raise CacheRefusal("fresh-image registry URL is not HTTPS")
        if not isinstance(checksum, str) or re.fullmatch(r"[0-9a-f]{64}", checksum) is None:
            raise CacheRefusal("fresh-image registry checksum is malformed")
        pairs.add((url, checksum))
    return pairs


def _directory(path, uid, *, create):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise CacheRefusal("cache path must be absolute and contain no parent traversal")
    current = Path("/")
    parts = path.parts[1:]
    if not parts:
        raise CacheRefusal("cache path must not be filesystem root")
    for index, part in enumerate(parts):
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError:
            if not create:
                raise CacheRefusal("cache directory is missing") from None
            try:
                os.mkdir(current, 0o700)
            except FileExistsError:
                pass
            info = current.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise CacheRefusal("cache path contains a non-directory or symlink")
        if info.st_uid not in (0, uid) or info.st_mode & 0o022:
            raise CacheRefusal("cache path has an unsafe owner or writable parent")
        if index == len(parts) - 1 and (info.st_uid != uid or stat.S_IMODE(info.st_mode) != 0o700):
            raise CacheRefusal("cache directory must be owned by the caller with mode 0700")
    return path


def _open_owned_file(path, uid, *, create=False):
    flags = os.O_RDWR | os.O_NOFOLLOW
    if create:
        flags |= os.O_CREAT
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise CacheRefusal(f"cannot safely open cache object ({error.__class__.__name__})") from None
    info = os.fstat(descriptor)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != uid
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        os.close(descriptor)
        raise CacheRefusal("The cache object must be a regular file owned by the caller. It must have exactly one hard link and mode 0600.")
    return descriptor


def _hash_fd(descriptor):
    digest = hashlib.sha256()
    offset = 0
    while True:
        chunk = os.pread(descriptor, 1024 * 1024, offset)
        if not chunk:
            break
        digest.update(chunk)
        offset += len(chunk)
        if offset > MAX_IMAGE_BYTES:
            raise CacheRefusal("image exceeds the 2 GiB cache limit")
    return digest.hexdigest(), offset


def _fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def curl_argv(url):
    return [
        "curl", "--disable", "--fail", "--location", "--silent", "--show-error",
        "--proto", "=https", "--proto-redir", "=https",
        "--connect-timeout", str(CURL_CONNECT_SECONDS),
        "--max-time", str(CURL_MAX_SECONDS),
        "--max-filesize", str(MAX_IMAGE_BYTES), "--output", "-", url,
    ]


def _download_curl(url, output):
    argv = curl_argv(url)
    try:
        result = subprocess.run(argv, stdout=output, stderr=subprocess.DEVNULL,
                                timeout=CURL_MAX_SECONDS + 15, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CacheRefusal(f"bounded stock-image download failed ({error.__class__.__name__})") from None
    if result.returncode != 0:
        raise CacheRefusal(f"bounded stock-image download failed (curl rc={result.returncode})")


def _same_inode(path, descriptor):
    try:
        path_info = path.lstat()
        fd_info = os.fstat(descriptor)
    except OSError:
        return False
    return (stat.S_ISREG(path_info.st_mode) and path_info.st_dev == fd_info.st_dev
            and path_info.st_ino == fd_info.st_ino)


def _validate_destination(destination, uid):
    destination = Path(destination)
    parent_info = destination.parent.lstat()
    if (not stat.S_ISDIR(parent_info.st_mode) or stat.S_ISLNK(parent_info.st_mode)
            or parent_info.st_uid != uid or parent_info.st_mode & 0o077):
        raise CacheRefusal("per-run image directory must be caller-owned and private")
    if destination.exists() or destination.is_symlink():
        raise CacheRefusal("refusing to overwrite an existing per-run image")
    return destination


def _copy_verified(source, destination, checksum, uid):
    destination = _validate_destination(destination, uid)
    source_fd = _open_owned_file(source, uid)
    output_fd = None
    try:
        actual, size = _hash_fd(source_fd)
        if actual != checksum or size == 0:
            raise CacheRefusal("cached image SHA256 mismatch")
        os.lseek(source_fd, 0, os.SEEK_SET)
        output_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        digest = hashlib.sha256()
        copied = 0
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                written = os.write(output_fd, view)
                view = view[written:]
            digest.update(chunk)
            copied += len(chunk)
        if copied != size or digest.hexdigest() != checksum:
            raise CacheRefusal("per-run image copy failed SHA256 verification")
        os.fsync(output_fd)
    except BaseException:
        if output_fd is not None and _same_inode(destination, output_fd):
            destination.unlink(missing_ok=True)
        raise
    finally:
        if output_fd is not None:
            os.close(output_fd)
        os.close(source_fd)


def cache_stock_image(url, checksum, cache_dir, destination, *, allowed_pairs, downloader=None):
    """Populate/reuse an allowlisted cache object, then copy it into run scratch."""
    if not isinstance(checksum, str) or re.fullmatch(r"[0-9a-f]{64}", checksum) is None:
        raise CacheRefusal("expected SHA256 is malformed")
    if (url, checksum) not in allowed_pairs:
        return False
    if not url.startswith("https://"):
        raise CacheRefusal("registered stock-image URL must use HTTPS")

    uid = os.geteuid()
    if destination is not None:
        destination = _validate_destination(destination, uid)
    cache = _directory(cache_dir, uid, create=True)
    image = cache / f"{checksum}.img"
    lock_path = cache / f".{checksum}.lock"
    lock_fd = _open_owned_file(lock_path, uid, create=True)
    stage_path = None
    stage_fd = None
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        try:
            image_info = image.lstat()
        except FileNotFoundError:
            image_info = None

        hit = image_info is not None
        if hit:
            if (not stat.S_ISREG(image_info.st_mode) or stat.S_ISLNK(image_info.st_mode)
                    or image_info.st_uid != uid or stat.S_IMODE(image_info.st_mode) != 0o600
                    or image_info.st_nlink != 1):
                raise CacheRefusal("existing cache entry has unsafe type, owner, mode, or links")
            image_fd = _open_owned_file(image, uid)
            try:
                actual, size = _hash_fd(image_fd)
            finally:
                os.close(image_fd)
            if actual != checksum or size == 0:
                raise CacheRefusal("existing cache entry failed SHA256; preserving it")
        else:
            stage_fd, stage_name = tempfile.mkstemp(prefix=f".{checksum}.download.", dir=cache)
            stage_path = Path(stage_name)
            if downloader is None:
                downloader = _download_curl
            with os.fdopen(stage_fd, "wb", closefd=True) as output:
                stage_fd = None
                downloader(url, output)
                output.flush()
                os.fsync(output.fileno())
            staged_fd = _open_owned_file(stage_path, uid)
            try:
                actual, size = _hash_fd(staged_fd)
                if actual != checksum or size == 0:
                    raise CacheRefusal("downloaded stock image failed SHA256; not publishing")
            finally:
                os.close(staged_fd)

            try:
                os.link(stage_path, image, follow_symlinks=False)
            except FileExistsError:
                # A concurrent writer may publish the same digest; verify it, never replace it.
                image_fd = _open_owned_file(image, uid)
                try:
                    actual, size = _hash_fd(image_fd)
                finally:
                    os.close(image_fd)
                if actual != checksum or size == 0:
                    raise CacheRefusal("concurrent cache entry failed SHA256; preserving it")
                hit = True
            else:
                hit = False
                stage_path.unlink()
                stage_path = None
            _fsync_directory(cache)

        if destination is not None:
            _copy_verified(image, destination, checksum, uid)
        return hit
    finally:
        if stage_fd is not None:
            os.close(stage_fd)
        if stage_path is not None:
            try:
                stage_path.unlink()
                _fsync_directory(cache)
            except FileNotFoundError:
                pass
        os.close(lock_fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image_url")
    parser.add_argument("sha256")
    parser.add_argument("cache_dir")
    parser.add_argument("registry")
    parser.add_argument("destination", nargs="?")
    parser.add_argument("--cache-only", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.cache_only == (args.destination is not None):
            raise CacheRefusal("provide a destination unless --cache-only is selected")
        if re.fullmatch(r"[0-9a-f]{64}", args.sha256) is None:
            raise CacheRefusal("expected SHA256 is malformed")
        allowed = registered_stock_pairs(args.registry)
        if args.image_url in {url for url, _ in allowed} and (args.image_url, args.sha256) not in allowed:
            raise CacheRefusal("registered stock-image URL has a mismatched digest")
        if (args.image_url, args.sha256) not in allowed:
            return 3
        hit = cache_stock_image(args.image_url, args.sha256, args.cache_dir,
                                args.destination, allowed_pairs=allowed)
        print("verified_stock_image_cache=hit" if hit else "verified_stock_image_cache=published")
        return 0
    except (CacheRefusal, OSError, ValueError) as error:
        print(f"stock-image cache refused: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
