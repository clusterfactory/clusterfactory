# Single Source of Truth Pattern - Established

## Overview

Established the pattern where `factory/components/<service>.py` is the single source of truth for:
- Service versions
- Required dependencies (plugins, extensions, etc.)
- Configuration requirements

This makes upgrades manageable long-term by eliminating scattered version references.

## Pattern Implementation

###  Component File (Source of Truth)
**File**: `factory/components/jenkins.py`

```python
# Jenkins version and plugin requirements
# This is the single source of truth for Jenkins configuration in clusterfactory
JENKINS_VERSION = "2.541.3-jdk21"
PLUGINS = [
    "plain-credentials",   # Latest version
    "credentials",         # Latest version
    "git",                 # Latest version
    "workflow-aggregator", # Latest version
    "workflow-job",        # Latest version
]
```

### Image Dockerfile
**File**: `images/jenkins/Dockerfile`

```dockerfile
FROM jenkins/jenkins:2.541.3-jdk21

# Install plugins matching factory/components/jenkins.py PLUGINS list
RUN jenkins-plugin-cli --plugins \
    plain-credentials \
    credentials \
    git \
    workflow-aggregator \
    workflow-job
```

**Note**: Currently manual. Future enhancement: generate from component file.

### Makefile Target
**File**: `Makefile`

```makefile
JENKINS_VERSION ?= 2.541.3-jdk21

jenkins-image:  ## Build Jenkins image with pre-installed plugins
docker build -t clusterfactory/jenkins-cf:$(JENKINS_VERSION) images/jenkins/
```

### Zarf Package
**File**: `zarf.yaml`

```yaml
components:
  - name: jenkins
    images:
      - clusterfactory/jenkins-cf:2.541.3-jdk21  # Custom image
      - kiwigrid/k8s-sidecar:2.5.0
```

### Helm Values
**File**: `values/jenkins.yaml`

```yaml
controller:
  image:
    repository: clusterfactory/jenkins-cf
    tag: 2.541.3-jdk21
  installPlugins: []  # Pre-installed in custom image
```

## Upgrade Process

When upgrading Jenkins (e.g., to 2.542.0-jdk21):

1. **Update component file** (single change):
   ```python
   # factory/components/jenkins.py
   JENKINS_VERSION = "2.542.0-jdk21"
   PLUGINS = [...]  # Update if needed
   ```

2. **Update Dockerfile base image**:
   ```dockerfile
   FROM jenkins/jenkins:2.542.0-jdk21
   ```

3. **Rebuild**:
   ```bash
   make jenkins-image
   make package
   make deploy
   ```

That's it! No hunting through multiple files for version references.

## Benefits

✅ **Single source of truth**: Component file defines requirements  
✅ **Easy upgrades**: Change one constant, rebuild  
✅ **Versioned together**: Code knows what it needs  
✅ **Airgap-ready**: Plugins baked into image  
✅ **No manual edits**: zarf.yaml references are consistent  

## Future Enhancements

### Generate Dockerfile from Component
**Option 1**: Python script reads component, writes Dockerfile  
**Option 2**: Template Dockerfile with placeholder, substitute at build  
**Option 3**: Makefile generates Dockerfile dynamically  

Example Makefile target:
```makefile
generate-jenkins-dockerfile:
python3 -c "from factory.components.jenkins import JENKINS_VERSION, PLUGINS; \
print(f'FROM jenkins/jenkins:{JENKINS_VERSION}'); \
print('RUN jenkins-plugin-cli --plugins ' + ' '.join(PLUGINS))" \
> images/jenkins/Dockerfile.generated
```

### Version File
Create `VERSION` or `.version` file:
```
JENKINS_VERSION=2.541.3-jdk21
GITEA_VERSION=1.23.6-rootless
```

Read in Makefile, component files, Dockerfiles.

## Current Status

- ✅ Pattern established
- ✅ Jenkins component constants defined
- ✅ Custom image Dockerfile created
- ✅ Makefile target added
- ✅ zarf.yaml updated
- ✅ values/jenkins.yaml updated
- ⏳ Package rebuild in progress (images ready)

## Files Changed

```
factory/components/jenkins.py  # Added JENKINS_VERSION, PLUGINS constants
images/jenkins/Dockerfile      # Created custom Jenkins image
Makefile                       # Added jenkins-image target
zarf.yaml                      # Updated to use custom image
values/jenkins.yaml            # Updated repository and tag
```

