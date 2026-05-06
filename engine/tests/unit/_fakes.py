"""In-memory fake components for unit tests. No network, deterministic.

These mirror the GiteaComponent / JenkinsComponent contract from
clusterfactory_engine.components but never make HTTP calls. A unit test asks
"given a graph, does the engine call extract → inject → verify in topological
order and produce a stable structural SHA?" — and that question is answered
without standing up Gitea or Jenkins.
"""
from typing import Type

from clusterfactory_engine.component import Component
from clusterfactory_engine.credential import (
    ApiToken, Credential, UserPass,
)


class FakeGitea(Component):
    """Producer-only fake. Mints a deterministic ApiToken/UserPass."""

    def __init__(self, name: str = "gitea", config: dict | None = None,
                 token: str = "fake-token-abc", user: str = "gitea-admin"):
        super().__init__(name, config or {})
        self._token = token
        self._user = user
        self.extract_calls: list[tuple[Type[Credential], str]] = []
        self.inject_calls: list[Credential] = []
        self.verify_calls: list[Credential] = []

    @property
    def url(self) -> str:
        return "http://fake-gitea:3000"

    def ready(self) -> bool:
        return True

    def produces(self) -> list[Type[Credential]]:
        return [ApiToken, UserPass]

    def consumes(self) -> list[Type[Credential]]:
        return []

    def extract(self, kind: Type[Credential], for_consumer: str) -> Credential:
        self.extract_calls.append((kind, for_consumer))
        if kind is ApiToken:
            return ApiToken(
                producer=self.name, consumer=for_consumer,
                value={"token": self._token, "user": self._user,
                       "name": f"{for_consumer}-wiring"},
            )
        if kind is UserPass:
            return UserPass(
                producer=self.name, consumer=for_consumer,
                value={"username": self._user, "password": self._token},
            )
        raise ValueError(f"FakeGitea cannot produce {kind}")

    def inject(self, credential: Credential) -> None:
        # Producer-only; should never be called by the executor.
        self.inject_calls.append(credential)

    def verify(self, credential: Credential) -> bool:
        self.verify_calls.append(credential)
        return True


class FakeJenkins(Component):
    """Consumer-only fake. Stores injected credentials in-memory."""

    def __init__(self, name: str = "jenkins", config: dict | None = None,
                 verify_result: bool = True):
        super().__init__(name, config or {})
        self.stored: list[Credential] = []
        self.extract_calls: list[tuple[Type[Credential], str]] = []
        self.inject_calls: list[Credential] = []
        self.verify_calls: list[Credential] = []
        self._verify_result = verify_result

    @property
    def url(self) -> str:
        return "http://fake-jenkins:8080"

    def ready(self) -> bool:
        return True

    def produces(self) -> list[Type[Credential]]:
        return []

    def consumes(self) -> list[Type[Credential]]:
        return [ApiToken, UserPass]

    def extract(self, kind: Type[Credential], for_consumer: str) -> Credential:
        self.extract_calls.append((kind, for_consumer))
        raise ValueError("FakeJenkins is a consumer; no extract")

    def inject(self, credential: Credential) -> None:
        self.inject_calls.append(credential)
        self.stored.append(credential)

    def verify(self, credential: Credential) -> bool:
        self.verify_calls.append(credential)
        return self._verify_result
