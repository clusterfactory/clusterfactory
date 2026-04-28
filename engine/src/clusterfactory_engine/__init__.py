"""clusterfactory_engine - Wire engine for cross-service credential injection."""

__version__ = "0.3.0"

from .component import Component
from .credential import Credential, ApiToken, UserPass, RunnerToken
from .resolver import resolve, register
from .planner import build_graph, WiringGraph
from .executor import Executor
from .verifier import verify_all
from .hasher import structural_sha

__all__ = [
    "Component",
    "Credential",
    "ApiToken",
    "UserPass",
    "RunnerToken",
    "resolve",
    "register",
    "build_graph",
    "WiringGraph",
    "Executor",
    "verify_all",
    "structural_sha",
]
