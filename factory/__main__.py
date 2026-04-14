"""Factory entrypoint - CLI for platform execution."""

import argparse
import logging
import sys
from pathlib import Path

from factory.model.platform import Platform
from factory.engine.executor import Executor
from factory.engine.resolver import Resolver
from factory.engine.planner import Planner
from factory.engine.verifier import Verifier
from factory.engine.hasher import Hasher
from factory.health.checker import HealthChecker


def setup_logging(level: str = "INFO"):
    """Configure logging."""
    logging.basicConfig(
        level=getattr(logging, level.upper()),
        format='%(asctime)s | %(name)s | %(levelname)s | %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )


def main():
    """Main entrypoint."""
    parser = argparse.ArgumentParser(description='ClusterFactory Python Engine')
    parser.add_argument(
        '--platform',
        type=str,
        default='/config/platform.yaml',
        help='Path to platform.yaml'
    )
    parser.add_argument(
        '--mode',
        type=str,
        default='wire',
        choices=['wire', 'verify', 'bundle'],
        help='Execution mode'
    )
    parser.add_argument(
        '--log-level',
        type=str,
        default='INFO',
        choices=['DEBUG', 'INFO', 'WARNING', 'ERROR'],
        help='Log level'
    )
    parser.add_argument(
        '--namespace',
        type=str,
        default='default',
        help='Kubernetes namespace'
    )
    
    args = parser.parse_args()
    
    setup_logging(args.log_level)
    log = logging.getLogger("factory")
    
    log.info("ClusterFactory starting")
    log.info(f"platform: {args.platform}")
    log.info(f"mode: {args.mode}")
    
    try:
        # Load platform
        platform = Platform.from_yaml(args.platform)
        log.info(f"loaded platform | name={platform.name} version={platform.version}")
        log.info(f"platform_sha | {platform.sha}")
        
        if args.mode == 'wire':
            # Execute wiring
            config = {'namespace': args.namespace}
            executor = Executor(
                resolver=Resolver(config),
                planner=Planner(),
                verifier=Verifier(),
                hasher=Hasher(),
                health=HealthChecker()
            )
            
            result = executor.run(platform)
            
            if result.success:
                log.info(f"SUCCESS | structural_sha={result.structural_sha}")
                log.info(f"credentials generated: {len(result.credentials)}")
                sys.exit(0)
            else:
                log.error("FAILED")
                for error in result.errors:
                    log.error(f"  {error}")
                sys.exit(1)
        
        elif args.mode == 'verify':
            log.info("Verify mode not yet implemented")
            sys.exit(1)
        
        elif args.mode == 'bundle':
            log.info("Bundle mode not yet implemented")
            sys.exit(1)
    
    except FileNotFoundError as e:
        log.error(f"File not found: {e}")
        sys.exit(1)
    except ValueError as e:
        log.error(f"Invalid configuration: {e}")
        sys.exit(1)
    except Exception as e:
        log.exception(f"Unexpected error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
