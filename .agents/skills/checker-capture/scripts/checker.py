#!/usr/bin/env python3
"""Resolve the project's bridge even when the skill is symlinked globally."""
import os
from pathlib import Path
import sys

file = Path(__file__).resolve()
candidates = [file.parents[3] / "checker_bridge.py", file.parents[4] / "bridge/checker_bridge.py"]
bridge = next((candidate for candidate in candidates if candidate.is_file()), None)
if bridge is None:
    sys.exit("Checker 연결 파일을 찾지 못했어요. 설치를 다시 실행해 주세요.")
os.execv(sys.executable, [sys.executable, str(bridge)] + sys.argv[1:])
