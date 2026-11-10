#!/bin/sh
set -eu
CHECKER_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$CHECKER_ROOT"
python3 scripts/sync_localization.py --check
swift build --product Checker
swift run CheckerCoreChecks
python3 -m unittest discover -s Tests -p 'test_*.py' -v
