#!/usr/bin/env python3
"""Pre-flight validation for Day 3 E2E test.

Validates the v0.3 package structure before attempting deployment.
"""
import sys
import yaml
from pathlib import Path

def validate():
    """Run all validation checks."""
    errors = []
    warnings = []
    
    print("🔍 Validating v0.3 package structure...\n")
    
    # Check zarf.yaml
    zarf_path = Path("zarf.yaml")
    if not zarf_path.exists():
        errors.append("zarf.yaml not found")
    else:
        try:
            with open(zarf_path) as f:
                zarf = yaml.safe_load(f)
            
            if zarf.get("metadata", {}).get("version") != "0.3.0":
                warnings.append(f"zarf.yaml version is {zarf.get('metadata', {}).get('version')}, expected 0.3.0")
            
            components = [c["name"] for c in zarf.get("components", [])]
            required = ["netpol", "gitea-secret", "gitea", "jenkins", "platform-spec", "wire"]
            missing = set(required) - set(components)
            if missing:
                errors.append(f"zarf.yaml missing components: {missing}")
            
            print(f"✓ zarf.yaml: {len(components)} components defined")
            
        except Exception as e:
            errors.append(f"zarf.yaml parse error: {e}")
    
    # Check platform.yaml
    platform_path = Path("platform.yaml")
    if not platform_path.exists():
        errors.append("platform.yaml not found")
    else:
        try:
            with open(platform_path) as f:
                platform = yaml.safe_load(f)
            
            components = platform.get("spec", {}).get("components", [])
            wiring = platform.get("spec", {}).get("wiring", [])
            
            if len(components) != 2:
                warnings.append(f"platform.yaml has {len(components)} components, expected 2")
            if len(wiring) != 1:
                warnings.append(f"platform.yaml has {len(wiring)} wires, expected 1")
            
            print(f"✓ platform.yaml: {len(components)} components, {len(wiring)} wires")
            
        except Exception as e:
            errors.append(f"platform.yaml parse error: {e}")
    
    # Check manifests
    manifests_dir = Path("manifests")
    if not manifests_dir.exists():
        errors.append("manifests/ directory not found")
    else:
        required_manifests = [
            "wire-rbac.yaml",
            "wire-job.yaml",
            "platform-configmap.yaml",
            "gitea-admin-secret.yaml",
            "networkpolicy.yaml"
        ]
        
        for manifest in required_manifests:
            path = manifests_dir / manifest
            if not path.exists():
                errors.append(f"manifests/{manifest} not found")
            else:
                print(f"✓ manifests/{manifest}")
    
    # Check values files
    values_dir = Path("values")
    if not values_dir.exists():
        errors.append("values/ directory not found")
    else:
        for values_file in ["gitea.yaml", "jenkins.yaml"]:
            path = values_dir / values_file
            if not path.exists():
                errors.append(f"values/{values_file} not found")
            else:
                print(f"✓ values/{values_file}")
    
    # Check engine
    engine_dir = Path("engine")
    if not engine_dir.exists():
        errors.append("engine/ directory not found")
    else:
        dockerfile = engine_dir / "Dockerfile"
        requirements = engine_dir / "requirements.txt"
        src = engine_dir / "src" / "clusterfactory_engine"
        
        if not dockerfile.exists():
            errors.append("engine/Dockerfile not found")
        else:
            print(f"✓ engine/Dockerfile")
        
        if not requirements.exists():
            errors.append("engine/requirements.txt not found")
        else:
            print(f"✓ engine/requirements.txt")
        
        if not src.exists():
            errors.append("engine/src/clusterfactory_engine/ not found")
        else:
            modules = list(src.glob("*.py"))
            components = list((src / "components").glob("*.py"))
            print(f"✓ engine/src: {len(modules)} modules, {len(components)} components")
    
    # Summary
    print("\n" + "="*70)
    if errors:
        print(f"❌ VALIDATION FAILED: {len(errors)} error(s)")
        for err in errors:
            print(f"   • {err}")
        return False
    
    if warnings:
        print(f"⚠️  {len(warnings)} warning(s):")
        for warn in warnings:
            print(f"   • {warn}")
    
    print(f"✅ VALIDATION PASSED")
    print("\nReady for deployment once Docker + Zarf are available.")
    print("See DAY3_E2E_TESTING.md for deployment instructions.")
    return True


if __name__ == "__main__":
    sys.exit(0 if validate() else 1)
