"""The only custom SSH boundary; never used for native cluster access."""

import re
import shlex


class HostExecutor:
    def __init__(self, runner, host=None):
        if host and not re.fullmatch(r'[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*', host):
            raise ValueError('invalid host binding')
        self.runner = runner
        self.host = host

    def run(self, args, **kwargs):
        command = list(map(str, args))
        if self.host not in (None, 'localhost', 'local'):
            command = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '--', self.host, shlex.join(command)]
        return self.runner.run(command, **kwargs)

    def read_file(self, path):
        result = self.run(['cat', '--', path], binary=True)
        return result.encode() if isinstance(result, str) else result
