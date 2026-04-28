"""Pytest configuration: make `clusterfactory_engine` importable without a pip install.

Tests live under engine/tests/ and import from engine/src/clusterfactory_engine/. We
prepend src/ to sys.path so `pip install -e .` is optional in CI and locally.
"""
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))
