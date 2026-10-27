"""Validate only consuming-stage inputs; do not expose their bytes or hashes."""

import json
import tempfile
import zipfile
from contextlib import contextmanager
from pathlib import Path


def validate_pull_secret(path):
    try:
        data = json.loads(Path(path).read_bytes())
        auths = data['auths']
        if not isinstance(auths, dict) or not auths or not all(
            isinstance(v, dict) and (v.get('auth') or v.get('identitytoken') or (v.get('username') and v.get('password')))
            for v in auths.values()
        ):
            raise ValueError()
    except (OSError, ValueError, KeyError, TypeError):
        raise ValueError('pull-secret file must be readable JSON with nonempty registry auth entries') from None


def validate_license(path):
    try:
        with zipfile.ZipFile(path) as archive:
            if not archive.namelist() or archive.testzip() is not None:
                raise ValueError()
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError):
        raise ValueError('AAP license must be a readable nonempty subscription-manifest ZIP; entitlement is not verified') from None


@contextmanager
def private_input(content):
    with tempfile.TemporaryDirectory(prefix='osac-dev-') as directory:
        path = Path(directory) / 'input'
        with path.open('xb') as stream:
            path.chmod(0o600)
            stream.write(content)
        yield path


def require_creation_input(path):
    if not path:
        raise ValueError('creating a named target requires --pull-secret-file (or PULL_SECRET_FILE)')
    validate_pull_secret(path)
