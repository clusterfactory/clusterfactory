"""Wire engine CLI entry point."""
import argparse
import logging
import os
import sys
import yaml
from pathlib import Path
from kubernetes import client, config as k8s_config

from . import resolver
from .planner import build_graph
from .executor import Executor
from .verifier import verify_all
from .hasher import structural_sha
from . import credential as cred_module

# Import components to register them
from .components import gitea, jenkins  # noqa: F401


def main():
    """Main entry point for wire engine."""
    ap = argparse.ArgumentParser(description="clusterfactory wire engine")
    ap.add_argument("--platform", default="/config/platform.yaml",
                    help="Path to platform.yaml")
    ap.add_argument("--log-level", default="INFO",
                    choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    args = ap.parse_args()

    logging.basicConfig(
        level=args.log_level,
        format="[%(name)s] %(levelname)s %(message)s",
    )
    log = logging.getLogger("engine")

    log.info(f"clusterfactory wire engine v0.3.0")
    log.info(f"loading platform spec from {args.platform}")

    # Load platform spec
    try:
        spec = yaml.safe_load(Path(args.platform).read_text())
    except Exception as e:
        log.error(f"Failed to load platform spec: {e}")
        sys.exit(1)

    # 1. Resolve components
    log.info("resolving components...")
    components = {}
    for c in spec["spec"]["components"]:
        try:
            cls = resolver.resolve(c["kind"])
            components[c["name"]] = cls(name=c["name"], config=c["config"])
            log.info(f"resolved {c['name']} ({c['kind']})")
        except Exception as e:
            log.error(f"Failed to resolve component {c['name']}: {e}")
            sys.exit(1)

    # 2. Wait for all components to be ready
    log.info("waiting for components to be ready...")
    for comp in components.values():
        try:
            comp.ready()
            log.info(f"{comp.name} ready at {comp.url}")
        except Exception as e:
            log.error(f"Component {comp.name} failed readiness check: {e}")
            sys.exit(1)

    # 3. Build wiring graph
    log.info("building wiring graph...")
    try:
        graph = build_graph(spec["spec"]["wiring"], components, cred_module)
        log.info(f"wiring graph: {len(graph.edges)} edges")
    except Exception as e:
        log.error(f"Failed to build wiring graph: {e}")
        sys.exit(1)

    # 4. Execute in topological order
    log.info("executing wiring...")
    executor = Executor(log)
    try:
        credentials = executor.run(graph)
        log.info(f"executed {len(credentials)} wires")
    except Exception as e:
        log.error(f"Wiring execution failed: {e}")
        sys.exit(1)

    # 5. Verify all wires hold
    log.info("verifying wires...")
    errors = verify_all(graph, credentials)
    if errors:
        log.error(f"Verification failed:")
        for err in errors:
            log.error(f"  {err}")
        sys.exit(1)
    log.info("all wires verified")

    # 6. Emit structural SHA
    sha = structural_sha(credentials)
    log.info(f"structural_sha: {sha}")

    # 7. Write result to ConfigMap
    log.info("writing result ConfigMap...")
    try:
        # Load in-cluster config
        k8s_config.load_incluster_config()
        v1 = client.CoreV1Api()
        
        # Create or update cf-wire-result ConfigMap
        configmap = client.V1ConfigMap(
            metadata=client.V1ObjectMeta(name="cf-wire-result"),
            data={"structural_sha": sha}
        )
        
        try:
            v1.create_namespaced_config_map(
                namespace=os.getenv("POD_NAMESPACE", "cicd"),
                body=configmap
            )
            log.info("created cf-wire-result ConfigMap")
        except client.exceptions.ApiException as e:
            if e.status == 409:  # Already exists
                v1.patch_namespaced_config_map(
                    name="cf-wire-result",
                    namespace=os.getenv("POD_NAMESPACE", "cicd"),
                    body=configmap
                )
                log.info("updated cf-wire-result ConfigMap")
            else:
                raise
    except Exception as e:
        log.error(f"Failed to write result ConfigMap: {e}")
        sys.exit(1)

    log.info("wire engine complete")


if __name__ == "__main__":
    main()
