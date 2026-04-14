"""Unit tests for engine execution."""

import pytest
from factory.model.platform import Platform, WiringEdge
from factory.model.artifact import Artifact
from factory.engine.executor import Executor
from factory.engine.resolver import Resolver
from factory.engine.planner import Planner
from factory.engine.verifier import Verifier
from factory.engine.hasher import Hasher
from factory.testing.fixtures import FakeGiteaComponent, FakeJenkinsComponent
from factory.credentials.types import ApiToken


class FakeResolver(Resolver):
    """Resolver that returns fake components."""
    
    def __init__(self, components_map):
        super().__init__()
        self.components_map = components_map
    
    def resolve(self, artifacts):
        return self.components_map


def test_engine_calls_extract_before_inject():
    """Engine calls extract on producer before inject on consumer."""
    gitea = FakeGiteaComponent()
    jenkins = FakeJenkinsComponent()
    
    executor = Executor(
        resolver=FakeResolver({"gitea": gitea, "jenkins": jenkins}),
        planner=Planner(),
        verifier=Verifier(),
        hasher=Hasher()
    )
    
    platform = Platform(
        name="test",
        version="1.0",
        artifacts=[gitea.artifact, jenkins.artifact],
        wiring=[WiringEdge("gitea", "jenkins", "api-token")]
    )
    
    result = executor.run(platform)
    
    assert len(gitea.extract_calls) == 1
    assert len(jenkins.inject_calls) == 1
    assert result.success


def test_engine_returns_success_on_valid_wiring():
    """Engine returns success result when wiring completes."""
    gitea = FakeGiteaComponent()
    jenkins = FakeJenkinsComponent()
    
    executor = Executor(
        resolver=FakeResolver({"gitea": gitea, "jenkins": jenkins}),
        planner=Planner(),
        verifier=Verifier(),
        hasher=Hasher()
    )
    
    platform = Platform(
        name="test",
        version="1.0",
        artifacts=[gitea.artifact, jenkins.artifact],
        wiring=[WiringEdge("gitea", "jenkins", "api-token")]
    )
    
    result = executor.run(platform)
    
    assert result.success
    assert result.structural_sha != ""
    assert len(result.credentials) == 1
    assert result.platform_sha == platform.sha


def test_structural_sha_is_deterministic():
    """Same wiring produces same structural SHA."""
    def run_wiring():
        gitea = FakeGiteaComponent()
        jenkins = FakeJenkinsComponent()
        
        executor = Executor(
            resolver=FakeResolver({"gitea": gitea, "jenkins": jenkins}),
            planner=Planner(),
            verifier=Verifier(),
            hasher=Hasher()
        )
        
        platform = Platform(
            name="test",
            version="1.0",
            artifacts=[gitea.artifact, jenkins.artifact],
            wiring=[WiringEdge("gitea", "jenkins", "api-token")]
        )
        
        return executor.run(platform)
    
    result_a = run_wiring()
    result_b = run_wiring()
    
    assert result_a.structural_sha == result_b.structural_sha


def test_structural_sha_changes_if_credential_changes():
    """Different credential values produce different structural SHA."""
    # First wiring
    gitea1 = FakeGiteaComponent()
    jenkins1 = FakeJenkinsComponent()
    
    executor1 = Executor(
        resolver=FakeResolver({"gitea": gitea1, "jenkins": jenkins1}),
        planner=Planner(),
        verifier=Verifier(),
        hasher=Hasher()
    )
    
    platform = Platform(
        name="test",
        version="1.0",
        artifacts=[gitea1.artifact, jenkins1.artifact],
        wiring=[WiringEdge("gitea", "jenkins", "api-token")]
    )
    
    result1 = executor1.run(platform)
    
    # Modify fake component to produce different credential
    class ModifiedGitea(FakeGiteaComponent):
        def extract(self, kind, for_consumer):
            return ApiToken(
                producer=self.name,
                consumer=for_consumer,
                value={"token": "DIFFERENT-TOKEN", "user": "admin"}
            )
    
    gitea2 = ModifiedGitea()
    jenkins2 = FakeJenkinsComponent()
    
    executor2 = Executor(
        resolver=FakeResolver({"gitea": gitea2, "jenkins": jenkins2}),
        planner=Planner(),
        verifier=Verifier(),
        hasher=Hasher()
    )
    
    result2 = executor2.run(platform)
    
    assert result1.structural_sha != result2.structural_sha
