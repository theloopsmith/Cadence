"""The LAN launcher advertises addresses only and cleans up its advertisement."""
import importlib.util
from pathlib import Path
from unittest.mock import Mock


def test_phone_launcher_advertises_without_credentials_and_cleans_up(tmp_path, monkeypatch):
    path = Path(__file__).resolve().parents[2] / 'scripts/run_phone_backend.py'
    spec = importlib.util.spec_from_file_location('cadence_phone_launcher', path)
    launcher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(launcher)
    monkeypatch.setattr(launcher, 'ROOT', tmp_path)
    python = tmp_path / 'backend/.venv/bin/python'
    python.parent.mkdir(parents=True)
    python.touch()
    local = tmp_path / '.local'
    local.mkdir()
    login = local / 'phone-login.txt'
    login.write_text('Username: fixture\nPassword: fixture-not-a-real-password\n')
    original_login = login.read_bytes()
    monkeypatch.setattr(launcher.sys, 'argv', ['run_phone_backend.py'])
    monkeypatch.setattr(launcher.socket, 'socket', Mock(return_value=Mock()))
    monkeypatch.setattr(launcher.shutil, 'which', lambda name: '/usr/bin/dns-sd')
    monkeypatch.setattr(launcher.subprocess, 'check_output', lambda *a, **kw: 'My-Mac\n')
    advertiser = Mock()
    popen = Mock(return_value=advertiser)
    monkeypatch.setattr(launcher.subprocess, 'Popen', popen)
    call = Mock(return_value=0)
    monkeypatch.setattr(launcher.subprocess, 'call', call)
    assert launcher.main() == 0
    args = popen.call_args.args[0]
    assert args == ['/usr/bin/dns-sd', '-R', 'Cadence on My-Mac', '_cadence._tcp', 'local', '8001']
    assert 'Password' not in repr(args)
    advertiser.terminate.assert_called_once()
    advertiser.wait.assert_called_once_with(timeout=5)
    assert login.read_bytes() == original_login
    env = call.call_args.kwargs['env']
    assert env['TWILIO_AUTH_TOKEN'] == ''
    assert env['CAREGIVER_PRIMARY_PHONE'] == ''
    assert '--host' in call.call_args.args[0]
    assert '0.0.0.0' in call.call_args.args[0]


def test_phone_signing_key_survives_restart_with_private_permissions(tmp_path):
    path = Path(__file__).resolve().parents[2] / 'scripts/run_phone_backend.py'
    spec = importlib.util.spec_from_file_location('cadence_phone_key', path)
    launcher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(launcher)
    first = launcher.phone_signing_secret(tmp_path)
    assert len(first) >= 32
    assert launcher.phone_signing_secret(tmp_path) == first
    assert (tmp_path / 'phone-jwt-secret').stat().st_mode & 0o777 == 0o600
    other = tmp_path / 'other-server'
    other.mkdir()
    assert launcher.phone_signing_secret(other) != first


def test_phone_launcher_does_not_silently_replace_damaged_signing_key(tmp_path):
    import pytest
    path = Path(__file__).resolve().parents[2] / 'scripts/run_phone_backend.py'
    spec = importlib.util.spec_from_file_location('cadence_phone_bad_key', path)
    launcher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(launcher)
    key = tmp_path / 'phone-jwt-secret'
    key.write_text('incomplete')
    with pytest.raises(ValueError):
        launcher.phone_signing_secret(tmp_path)
    assert key.read_text() == 'incomplete'
