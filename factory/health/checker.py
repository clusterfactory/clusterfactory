"""Health checker - parallel component readiness polling."""

import logging
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeoutError
from factory.components.base import Component

log = logging.getLogger("factory.health")


class HealthChecker:
    """
    Polls components in parallel until all are ready.
    
    Uses thread pool to check multiple components concurrently.
    """

    def __init__(self, max_workers: int = 10):
        """
        Initialize health checker.
        
        Args:
            max_workers: Maximum concurrent health checks
        """
        self.max_workers = max_workers

    def wait_all(self, components: list[Component], timeout: int = 300) -> None:
        """
        Wait for all components to become ready.
        
        Args:
            components: List of components to check
            timeout: Maximum time to wait in seconds
            
        Raises:
            TimeoutError: If any component doesn't become ready in time
        """
        log.info(f"waiting for {len(components)} components | timeout={timeout}s")
        
        start_time = time.time()
        
        with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
            futures = {}
            for component in components:
                future = executor.submit(self._wait_ready, component, timeout)
                futures[future] = component.name
            
            for future in futures:
                try:
                    elapsed = time.time() - start_time
                    remaining = max(1, timeout - int(elapsed))
                    future.result(timeout=remaining)
                    log.info(f"ready | {futures[future]}")
                except FuturesTimeoutError:
                    raise TimeoutError(
                        f"Component {futures[future]} not ready after {timeout}s"
                    )
                except Exception as e:
                    raise Exception(
                        f"Health check failed for {futures[future]}: {str(e)}"
                    )

    def _wait_ready(self, component: Component, timeout: int) -> None:
        """
        Poll component until ready.
        
        Args:
            component: Component to check
            timeout: Maximum time to wait
            
        Raises:
            TimeoutError: If component doesn't become ready
        """
        start_time = time.time()
        backoff = 1
        
        while time.time() - start_time < timeout:
            try:
                if component.ready():
                    return
            except Exception as e:
                log.debug(f"health check | {component.name} | {e}")
            
            time.sleep(backoff)
            backoff = min(backoff * 1.5, 10)
        
        raise TimeoutError(f"Component {component.name} not ready after {timeout}s")
