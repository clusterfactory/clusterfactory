#!/usr/bin/env python3
"""
ClusterFactory Test Runner

Runs test suites at different layers:
  - unit: Pure logic tests, no network
  - integration: Tests against live cluster
  - airgap: Full airgap simulation
  - upgrade: N → N+1 transition tests
  - all: Run all test layers
"""

import argparse
import subprocess
import sys
from pathlib import Path


LAYERS = {
    'unit': {
        'path': 'factory/testing/layers/unit/',
        'description': 'Unit tests (no network, no cluster)',
        'markers': None,
    },
    'integration': {
        'path': 'factory/testing/layers/integration/',
        'description': 'Integration tests (requires live cluster)',
        'markers': 'integration',
    },
    'airgap': {
        'path': 'factory/testing/layers/airgap/',
        'description': 'Airgap tests (no external network)',
        'markers': 'airgap',
    },
    'upgrade': {
        'path': 'factory/testing/layers/upgrade/',
        'description': 'Upgrade tests (N → N+1 transitions)',
        'markers': 'upgrade',
    },
}


def run_tests(layers, verbose=False, fail_fast=False, platform=None):
    """
    Run test layers.
    
    Args:
        layers: List of layer names to run
        verbose: Show verbose output
        fail_fast: Stop on first failure
        platform: Path to platform.yaml for tests
    """
    results = {}
    
    for layer in layers:
        if layer not in LAYERS:
            print(f"❌ Unknown layer: {layer}")
            print(f"Available layers: {', '.join(LAYERS.keys())}")
            sys.exit(1)
        
        config = LAYERS[layer]
        
        print(f"\n{'='*70}")
        print(f"Running {layer} tests")
        print(f"Description: {config['description']}")
        print(f"{'='*70}\n")
        
        # Build pytest command
        cmd = ['python3', '-m', 'pytest', config['path']]
        
        if verbose:
            cmd.append('-v')
        else:
            cmd.append('-q')
        
        if fail_fast:
            cmd.append('-x')
        
        if config['markers']:
            cmd.extend(['-m', config['markers']])
        
        if platform:
            cmd.extend(['--platform', platform])
        
        # Run tests
        result = subprocess.run(cmd, capture_output=False)
        results[layer] = result.returncode == 0
        
        if not results[layer] and fail_fast:
            print(f"\n❌ {layer} tests failed. Stopping (--fail-fast).")
            return results
    
    return results


def print_summary(results):
    """Print test results summary."""
    print(f"\n{'='*70}")
    print("TEST SUMMARY")
    print(f"{'='*70}\n")
    
    for layer, passed in results.items():
        status = "✅ PASSED" if passed else "❌ FAILED"
        desc = LAYERS[layer]['description']
        print(f"{layer:12} {status:12} - {desc}")
    
    print(f"\n{'='*70}")
    
    total = len(results)
    passed = sum(1 for v in results.values() if v)
    
    if passed == total:
        print(f"✅ All {total} test layers passed!")
        return 0
    else:
        print(f"❌ {total - passed}/{total} test layers failed")
        return 1


def main():
    parser = argparse.ArgumentParser(
        description='Run ClusterFactory test suites',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  # Run unit tests only
  ./run-tests.py unit
  
  # Run unit and integration tests
  ./run-tests.py unit integration
  
  # Run all tests with verbose output
  ./run-tests.py all -v
  
  # Run tests and stop on first failure
  ./run-tests.py all --fail-fast
  
Test Layers:
  unit         - Pure logic, no network (fast)
  integration  - Against live cluster (requires deployment)
  airgap       - Airgap simulation (no external network)
  upgrade      - Upgrade transitions (N → N+1)
  all          - Run all layers
'''
    )
    
    parser.add_argument(
        'layers',
        nargs='+',
        choices=list(LAYERS.keys()) + ['all'],
        help='Test layer(s) to run'
    )
    parser.add_argument(
        '-v', '--verbose',
        action='store_true',
        help='Verbose output'
    )
    parser.add_argument(
        '-x', '--fail-fast',
        action='store_true',
        help='Stop on first failure'
    )
    parser.add_argument(
        '--platform',
        help='Path to platform.yaml for tests'
    )
    
    args = parser.parse_args()
    
    # Expand 'all' to all layers
    if 'all' in args.layers:
        layers = list(LAYERS.keys())
    else:
        layers = args.layers
    
    # Run tests
    results = run_tests(
        layers=layers,
        verbose=args.verbose,
        fail_fast=args.fail_fast,
        platform=args.platform
    )
    
    # Print summary
    exit_code = print_summary(results)
    sys.exit(exit_code)


if __name__ == '__main__':
    main()
