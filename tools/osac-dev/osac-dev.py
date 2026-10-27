#!/usr/bin/env python3
"""Workstation entry point; no global installation required."""

import sys
from osac_dev.cli import main, wrapper_main

if __name__ == '__main__':
    if sys.argv[1:2] == ['--make-wrapper']:
        sys.exit(wrapper_main())
    sys.exit(main())
