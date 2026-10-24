"""Interrupted setup fixtures must not orphan retained clients."""
import sqlite3

import pytest

from tests.e2e.bootstrap_retry import prepare_retry

pytestmark = pytest.mark.quick


@pytest.fixture
def database(tmp_path):
    path = tmp_path / "wg-easy.db"
    with sqlite3.connect(path) as connection:
        connection.executescript("""
            PRAGMA foreign_keys=ON;
            CREATE TABLE users_table (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT);
            CREATE TABLE clients_table (
                id INTEGER PRIMARY KEY,
                user_id INTEGER REFERENCES users_table(id) ON DELETE RESTRICT
            );
            CREATE TABLE general_table (setup_step INTEGER, retained TEXT);
            INSERT INTO users_table(username) VALUES ('initial-admin');
            INSERT INTO general_table VALUES (0, 'unchanged');
        """)
    return path


def test_retry_recreates_the_initial_owner(database):
    prepare_retry(database)
    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT setup_step, retained FROM general_table").fetchall() == [(2, "unchanged")]
        assert connection.execute("SELECT id FROM users_table").fetchall() == []
        connection.execute("PRAGMA foreign_keys=ON")
        # Exercise the pinned service's automatic user allocation and client owner.
        connection.execute("INSERT INTO users_table(username) VALUES ('recovered-admin')")
        connection.execute("INSERT INTO clients_table VALUES (7, 1)")
        assert connection.execute("SELECT id FROM users_table").fetchall() == [(1,)]
        assert connection.execute("PRAGMA foreign_key_check").fetchall() == []


@pytest.mark.parametrize("state", ["retained-client", "other-admin", "advanced-sequence", "incomplete", "multiple-admins"])
def test_retry_refuses_existing_or_unexpected_state(database, state):
    with sqlite3.connect(database) as connection:
        if state == "retained-client":
            connection.execute("INSERT INTO clients_table VALUES (7, 1)")
        elif state == "other-admin":
            connection.execute("UPDATE users_table SET id=2")
        elif state == "advanced-sequence":
            connection.execute("UPDATE sqlite_sequence SET seq=2 WHERE name='users_table'")
        elif state == "incomplete":
            connection.execute("UPDATE general_table SET setup_step=2")
        else:
            connection.execute("INSERT INTO users_table(username) VALUES ('other-admin')")
        before = list(connection.iterdump())

    with pytest.raises(RuntimeError):
        prepare_retry(database)

    with sqlite3.connect(database) as connection:
        assert list(connection.iterdump()) == before


def test_retry_does_not_create_a_missing_database(tmp_path):
    path = tmp_path / "missing.db"
    with pytest.raises(RuntimeError):
        prepare_retry(path)
    assert not path.exists()
