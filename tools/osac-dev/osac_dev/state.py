"""Private advisory journal. Live observation remains authoritative."""

import fcntl
import hashlib
import json
import os
import tempfile
from contextlib import contextmanager
from pathlib import Path


class State:
    def __init__(self, root=None):
        self.root = Path(root or Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) / 'osac-dev')
        self.root.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.root.chmod(0o700)

    def path(self, target, suffix):
        return self.root / (hashlib.sha256(target.encode()).hexdigest() + suffix)

    @contextmanager
    def lock(self, target):
        fd = os.open(self.path(target, '.lock'), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError('target is locked by another operation') from None
            yield
        finally:
            os.close(fd)

    def load(self, target):
        path = self.path(target, '.json')
        return json.loads(path.read_text()) if path.exists() else {}

    def record(self, target, data):
        if set(data) - {'fingerprint', 'stage', 'target', 'server', 'resources', 'version'}:
            raise ValueError('unsupported journal field; secret material is forbidden')
        fd, name = tempfile.mkstemp(dir=self.root)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(data, stream, sort_keys=True)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.path(target, '.json'))
        finally:
            Path(name).unlink(missing_ok=True)
