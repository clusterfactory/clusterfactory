"""Test configuration for pytest."""

import sys
from pathlib import Path

# Add factory to path
factory_path = Path(__file__).parent.parent.parent
sys.path.insert(0, str(factory_path.parent))
