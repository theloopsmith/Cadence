"""A configured encryption key must never leave a plaintext SQLite file."""

import builtins
import sqlite3
import sys
import types

import pytest

from app.config import settings
from app.db import DatabaseEncryptionError, init_db_sync

PLAINTEXT_HEADER = b"SQLite format 3"


def test_a_key_without_sqlcipher_does_not_open_a_plaintext_database(monkeypatch, tmp_path):
    """sqlcipher3 is not installed here. The old path caught that and opened
    the standard library, so a configured key still wrote 'SQLite format 3'."""
    monkeypatch.setattr(settings, "sqlite_encryption_key", "clinic-key")
    real_import = builtins.__import__

    def block_sqlcipher(name, globals=None, locals=None, fromlist=(), level=0):
        if name == "sqlcipher3":
            raise ImportError("sqlcipher3 is not installed")
        return real_import(name, globals, locals, fromlist, level)

    monkeypatch.setattr(builtins, "__import__", block_sqlcipher)
    path = tmp_path / "clinical.db"

    with pytest.raises(DatabaseEncryptionError):
        init_db_sync(str(path))

    if path.exists():
        assert not path.read_bytes().startswith(PLAINTEXT_HEADER)


def test_a_plaintext_file_is_rejected_when_a_key_is_configured(monkeypatch, tmp_path):
    """A module named sqlcipher3 that does not encrypt must not be accepted
    just because the import succeeded."""
    monkeypatch.setattr(settings, "sqlite_encryption_key", "clinic-key")
    fake = types.ModuleType("sqlcipher3")
    fake.connect = sqlite3.connect
    fake.Row = sqlite3.Row
    monkeypatch.setitem(sys.modules, "sqlcipher3", fake)
    path = tmp_path / "pretend-cipher.db"

    with pytest.raises(DatabaseEncryptionError):
        init_db_sync(str(path))
