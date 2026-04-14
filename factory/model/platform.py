"""Platform model - represents complete platform declaration."""

from dataclasses import dataclass, field
import json
from pathlib import Path
import yaml
from factory.hasher import sha256_of
from .artifact import Artifact


@dataclass
class WiringEdge:
    """
    A wiring edge declares a credential flow between two artifacts.
    
    Attributes:
        source: Source artifact name (producer)
        target: Target artifact name (consumer)
        credential: Credential type to wire
    """
    source: str
    target: str
    credential: str


@dataclass
class Platform:
    """
    Platform represents the complete input to the factory engine.
    
    The platform SHA is the structural contract fingerprint.
    Same artifact list + same wiring = same SHA.
    
    Attributes:
        name: Platform identifier (e.g. "gitea-jenkins")
        version: Platform version (e.g. "0.2.0")
        artifacts: List of artifacts to deploy
        wiring: List of wiring edges between artifacts
        airgap: Whether this platform runs in airgap mode
    """
    name: str
    version: str
    artifacts: list[Artifact]
    wiring: list[WiringEdge]
    airgap: bool = False

    @property
    def sha(self) -> str:
        """
        Compute platform SHA from artifacts and wiring.
        
        Returns:
            Hex-encoded SHA256 hash of platform structure
        """
        artifact_sha = sha256_of(
            json.dumps(sorted(a.sha for a in self.artifacts))
        )
        wiring_sha = sha256_of(
            json.dumps(sorted(
                f"{e.source}-{e.credential}-{e.target}"
                for e in self.wiring
            ))
        )
        return sha256_of(artifact_sha + wiring_sha)

    def artifact(self, name: str) -> Artifact | None:
        """
        Find artifact by name.
        
        Args:
            name: Artifact name to find
            
        Returns:
            Artifact if found, None otherwise
        """
        for artifact in self.artifacts:
            if artifact.name == name:
                return artifact
        return None

    @classmethod
    def from_yaml(cls, path: str) -> "Platform":
        """
        Load platform declaration from YAML file.
        
        Args:
            path: Path to platform.yaml file
            
        Returns:
            Platform instance
            
        Raises:
            FileNotFoundError: If path doesn't exist
            ValueError: If YAML is invalid
        """
        yaml_path = Path(path)
        if not yaml_path.exists():
            raise FileNotFoundError(f"Platform file not found: {path}")

        with open(yaml_path) as f:
            data = yaml.safe_load(f)

        if not data or "platform" not in data:
            raise ValueError(f"Invalid platform.yaml: missing 'platform' key")

        platform_data = data["platform"]
        
        artifacts = []
        for art_data in data.get("artifacts", []):
            artifacts.append(Artifact(
                name=art_data["name"],
                chart=art_data.get("chart"),
                version=art_data.get("version"),
                image=art_data["image"]
            ))

        wiring = []
        for wire_data in data.get("wiring", []):
            wiring.append(WiringEdge(
                source=wire_data["from"],
                target=wire_data["to"],
                credential=wire_data["credential"]
            ))

        return cls(
            name=platform_data["name"],
            version=platform_data["version"],
            artifacts=artifacts,
            wiring=wiring,
            airgap=data.get("airgap", False)
        )
