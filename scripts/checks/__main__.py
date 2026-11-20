"""Entry point: `python3 -m scripts.checks`."""

import sys

from .framework import main

if __name__ == "__main__":
    sys.exit(main())
