"""Bounded, non-shell process boundary. Never echo backend output on failure."""

import subprocess


class CommandError(RuntimeError):
    pass


class Runner:
    def run(self, args, *, timeout=120, input=None, binary=False):
        try:
            result = subprocess.run(list(map(str, args)), input=input, capture_output=True,
                                    text=not binary, timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise CommandError(f'{args[0]} could not run or exceeded its deadline') from error
        if result.returncode:
            # stderr/arguments may contain secrets or untrusted object data.
            raise CommandError(f'{args[0]} failed (exit {result.returncode}); inspect protected backend diagnostics')
        return result.stdout
