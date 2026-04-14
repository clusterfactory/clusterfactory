"""Fake components for unit testing."""

from factory.components.base import Component
from factory.credentials.types import ApiToken, RunnerToken, UserPass


class FakeGiteaComponent(Component):
    """In-memory Gitea. No network. Deterministic credentials."""

    def __init__(self, artifact=None, config=None):
        if artifact is None:
            from factory.model.artifact import Artifact
            artifact = Artifact("gitea", None, None, "gitea/gitea:1.23.6-rootless")
        super().__init__(artifact, config or {})
        self.extract_calls = []
        self.inject_calls = []
        self._ready = True

    @property
    def url(self):
        return "http://gitea-service:3000"

    def ready(self):
        return self._ready

    def produces(self):
        return [ApiToken, RunnerToken]

    def consumes(self):
        return []

    def extract(self, kind, for_consumer):
        if kind == ApiToken:
            credential = ApiToken(
                producer=self.name,
                consumer=for_consumer,
                value={"token": "fake-gitea-token-deterministic", "user": "admin"}
            )
        elif kind == RunnerToken:
            credential = RunnerToken(
                producer=self.name,
                consumer=for_consumer,
                value={"token": "fake-runner-token"}
            )
        else:
            raise ValueError(f"Cannot produce {kind}")
        
        self.extract_calls.append((kind, for_consumer, credential))
        return credential

    def inject(self, credential):
        self.inject_calls.append(credential)

    def verify(self, credential):
        return True


class FakeJenkinsComponent(Component):
    """In-memory Jenkins. Records inject calls for assertion."""

    def __init__(self, artifact=None, config=None):
        if artifact is None:
            from factory.model.artifact import Artifact
            artifact = Artifact("jenkins", None, None, "jenkins/jenkins:2.541.3-jdk21")
        super().__init__(artifact, config or {})
        self.extract_calls = []
        self.inject_calls = []
        self._ready = True

    @property
    def url(self):
        return "http://jenkins-service:8080"

    def ready(self):
        return self._ready

    def produces(self):
        return []

    def consumes(self):
        return [ApiToken, UserPass]

    def extract(self, kind, for_consumer):
        raise ValueError(f"Jenkins does not produce {kind}")

    def inject(self, credential):
        self.inject_calls.append(credential)

    def verify(self, credential):
        return credential in self.inject_calls
