"""Import paths for simulator decision code and offline evaluation tools.

This module only supports the existing standalone script entry points; it does
not define a separate simulator or world-model project.
"""
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[3]
CODE_DIRS = ("src/decision/core", "src/decision/surrogate", "src/decision/novelty",
             "tools/sweep", "tools/reporting")
for relative in CODE_DIRS:
    path = str(REPO / relative)
    if path not in sys.path:
        sys.path.insert(0, path)
