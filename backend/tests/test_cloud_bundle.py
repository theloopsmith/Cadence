"""Ensure deployment cannot accidentally copy patient files or credentials."""
import importlib.util
from pathlib import Path
import tarfile


def test_cloud_bundle_only_copies_allowed_source_files(tmp_path):
    root = tmp_path / 'source'
    app = root / 'backend/app'
    app.mkdir(parents=True)
    (root / 'deploy/gcp').mkdir(parents=True)
    for relative in ['backend/app/main.py', 'backend/app/view.html', 'backend/requirements-lock.txt', 'deploy/gcp/install.sh']:
        (root / relative).write_text('source')
    for relative in ['backend/.env', 'backend/app/.env', 'backend/app/patient.sqlite', 'backend/app/patient.json']:
        (root / relative).write_text('secret')
    (app / '__pycache__').mkdir()
    (app / '__pycache__/main.py').write_text('cache')
    path = Path(__file__).resolve().parents[2] / 'scripts/build_cloud_bundle.py'
    spec = importlib.util.spec_from_file_location('cloud_bundle', path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    archive = tmp_path / 'demo.tar.gz'
    module.build(archive, root=root)
    with tarfile.open(archive) as bundle:
        assert set(bundle.getnames()) == {'backend/app/main.py', 'backend/app/view.html', 'backend/requirements-lock.txt', 'deploy/gcp/install.sh'}


def test_demo_secrets_are_scoped_private_and_stable(tmp_path, monkeypatch, capsys):
    path = Path(__file__).resolve().parents[2] / 'scripts/prepare_cloud_demo.py'
    spec = importlib.util.spec_from_file_location('cloud_demo_config', path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    monkeypatch.setattr(module, 'ROOT', tmp_path)
    for name in module.PROVIDER_FIELDS:
        monkeypatch.delenv(name, raising=False)
    (tmp_path / 'backend').mkdir()
    (tmp_path / 'backend/.env').write_text('META_API_KEY=fake-meta-key\nTWILIO_AUTH_TOKEN=must-not-copy\n')
    module.prepare('cadence.example.test')
    env = tmp_path / '.local/gcp-demo/backend.env'
    accounts = tmp_path / '.local/gcp-demo/accounts.env'
    first = module.dotenv_values(env)
    credentials = accounts.read_text()
    assert first['META_API_KEY'] == 'fake-meta-key'
    assert first['TWILIO_AUTH_TOKEN'] == ''
    assert first['CADENCE_ENV'] == 'public_demo'
    assert first['ALLOW_STATIC_TOKENS'] == 'false'
    assert 'ENABLE_RESEARCH_METRICS' not in first
    assert len(first['JWT_SECRET']) >= 32
    assert env.stat().st_mode & 0o777 == 0o600
    assert accounts.stat().st_mode & 0o777 == 0o600
    module.prepare('other.example.test')
    assert module.dotenv_values(env)['JWT_SECRET'] == first['JWT_SECRET']
    assert accounts.read_text() == credentials
    output = capsys.readouterr().out
    assert 'fake-meta-key' not in output and first['JWT_SECRET'] not in output


def test_public_demo_does_not_publish_api_schema_or_interactive_docs():
    import os
    import subprocess
    import sys
    root = Path(__file__).resolve().parents[2]
    subprocess.run([sys.executable, "-c", "from app.main import app; assert not {'/docs','/redoc','/openapi.json'} & {route.path for route in app.routes}"],
        cwd=root / "backend", env={**os.environ,"CADENCE_ENV":"public_demo"}, check=True, capture_output=True)
