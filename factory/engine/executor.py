"""Executor - orchestrates platform wiring execution."""

import logging
from datetime import datetime, timezone

from factory.model.platform import Platform
from factory.model.result import PlatformResult
from .resolver import Resolver
from .planner import Planner
from .verifier import Verifier
from .hasher import Hasher

log = logging.getLogger("factory.engine")


class Executor:
    """
    Orchestrates platform wiring execution.
    
    Coordinates resolver, planner, health checker, and verifier to execute
    the complete wiring graph and produce a platform result.
    """

    def __init__(self, resolver: Resolver, planner: Planner, 
                 verifier: Verifier, hasher: Hasher, health=None):
        """
        Initialize executor.
        
        Args:
            resolver: Component resolver
            planner: Wiring graph planner
            verifier: Wire verifier
            hasher: Structural hash computer
            health: Health checker (optional)
        """
        self.resolver = resolver
        self.planner = planner
        self.verifier = verifier
        self.hasher = hasher
        self.health = health

    def run(self, platform: Platform) -> PlatformResult:
        """
        Execute platform wiring.
        
        Args:
            platform: Platform declaration
            
        Returns:
            PlatformResult with structural SHA and credentials
        """
        log.info(f"factory starting | platform_sha={platform.sha}")

        # 1. resolve artifact names → component instances
        components = self.resolver.resolve(platform.artifacts)
        log.info(f"resolved {len(components)} components")

        # 2. build directed wiring graph from declaration
        graph = self.planner.build(platform.wiring, components)
        log.info(f"wiring graph | {len(graph.edges)} edges")

        # 3. wait for all components ready (if health checker provided)
        if self.health:
            self.health.wait_all(list(components.values()), timeout=300)
            log.info("all components ready")

        # 4. execute wiring in dependency order
        credentials = []
        for edge in graph.topological_order():
            log.info(f"wiring | {edge.source.name} → {edge.target.name} | {edge.credential_kind}")
            
            try:
                credential = edge.source.extract(edge.credential_type, edge.target.name)
                edge.target.inject(credential)
                credentials.append(credential)
                log.info(f"wired  | sha={credential.sha[:12]}")
            except Exception as e:
                log.error(f"wiring failed | {edge.source.name} → {edge.target.name} | {e}")
                return PlatformResult(
                    platform_sha=platform.sha,
                    structural_sha="",
                    credentials=credentials,
                    timestamp=datetime.now(timezone.utc),
                    success=False,
                    errors=[f"Wiring failed: {str(e)}"]
                )

        # 5. verify all wires hold
        errors = self.verifier.verify_all(graph.edges, credentials)
        if errors:
            return PlatformResult(
                platform_sha=platform.sha,
                structural_sha="",
                credentials=credentials,
                timestamp=datetime.now(timezone.utc),
                success=False,
                errors=errors
            )

        # 6. produce structural sha
        structural_sha = self.hasher.hash(credentials)
        log.info(f"factory complete | structural_sha={structural_sha}")

        return PlatformResult(
            platform_sha=platform.sha,
            structural_sha=structural_sha,
            credentials=credentials,
            timestamp=datetime.now(timezone.utc),
            success=True
        )
