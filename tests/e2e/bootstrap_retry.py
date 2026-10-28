"""Construct an interrupted first setup only in a disposable deployment with no clients."""
import argparse
import os
from pathlib import Path
import sqlite3
import subprocess

INITIAL_ADMIN_ID = 1
COMPLETE_SETUP_STEP = 0
RETRY_SETUP_STEP = 2


def prepare_retry(path: Path):
    if not path.is_file() or path.is_symlink():
        raise RuntimeError("Bootstrap retry requires an existing regular database")

    with sqlite3.connect(path.absolute().as_uri() + "?mode=rw", uri=True) as database:
        database.execute("PRAGMA foreign_keys=ON")
        database.execute("BEGIN IMMEDIATE")
        if database.execute("SELECT COUNT(*) FROM clients_table").fetchone()[0] != 0:
            raise RuntimeError("Bootstrap retry must run before creating clients")
        if database.execute("SELECT id FROM users_table ORDER BY id").fetchall() != [(INITIAL_ADMIN_ID,)]:
            raise RuntimeError("Bootstrap retry requires the original initial administrator")
        sequence = database.execute("SELECT seq FROM sqlite_sequence WHERE name='users_table'").fetchall()
        if sequence != [(INITIAL_ADMIN_ID,)]:
            raise RuntimeError("Bootstrap retry requires the first administrator allocation")
        if database.execute("SELECT setup_step FROM general_table").fetchall() != [(COMPLETE_SETUP_STEP,)]:
            raise RuntimeError("Bootstrap retry requires completed initial setup")
        if database.execute("PRAGMA foreign_key_check").fetchall():
            raise RuntimeError("Bootstrap retry refuses inconsistent foreign keys")

        database.execute("DELETE FROM users_table")
        # Pinned wg-easy assigns new clients to administrator 1. Reproduce the
        # allocator before the first user, not a later deleted administrator.
        database.execute("DELETE FROM sqlite_sequence WHERE name='users_table'")
        database.execute("UPDATE general_table SET setup_step=?", (RETRY_SETUP_STEP,))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise RuntimeError("Bootstrap retry fixture requires root inside a disposable guest")
    virtualization = subprocess.run(["systemd-detect-virt", "--vm"], check=True,
                                    capture_output=True, text=True, timeout=10).stdout.strip()
    if virtualization not in {"qemu", "kvm"}:
        raise RuntimeError("Bootstrap retry fixture requires a disposable QEMU/KVM guest")
    prepare_retry(args.database)


if __name__ == "__main__":
    main()
