"""Artifact model - represents a chart + image component."""

from dataclasses import dataclass, field
from factory.hasher import sha256_of


@dataclass
class Artifact:
    """
    An artifact is a deployable component with optional chart and required image.
    
    Attributes:
        name: Component identifier (e.g. "gitea", "jenkins")
        chart: Optional Helm chart reference (e.g. "gitea/gitea")
        version: Optional chart version (e.g. "11.0.1")
        image: Container image reference (e.g. "gitea/gitea:1.23.6-rootless")
        sha: Computed structural hash of this artifact
    """
    name: str
    chart: str | None
    version: str | None
    image: str

    sha: str = field(init=False, repr=False)

    def __post_init__(self):
        """Compute artifact SHA from chart:version:image tuple."""
        self.sha = sha256_of(f"{self.chart}:{self.version}:{self.image}")
