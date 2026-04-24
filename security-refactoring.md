# Security Refactoring Plan

**Project:** ClusterFactory  
**Date:** 2026-04-20  
**Status:** Identified Issues - Remediation Required

## Executive Summary

This document outlines security vulnerabilities identified in the ClusterFactory codebase through comprehensive security review. Issues are categorized by severity (High, Medium, Low) and include specific remediation steps with code references.

**Total Issues:** 14  
**High Severity:** 4  
**Medium Severity:** 6  
**Low Severity:** 4

---

## 🔴 High Severity Issues

### 1. Hardcoded Default Admin Password

**Location:** `values.yaml` lines 67–69  
**Impact:** Public credential exposure leading to unauthorized administrative access

**Current Code:**
```yaml
gitea:
  admin:
    username: gitea-admin
    password: changeme123!
```

**Risk:**
- Default installation exposes Gitea with known credentials
- Password visible in `kubectl describe pod` via environment variables
- Searchable in public repositories and documentation

**Remediation:**
1. Generate random password in Helm pre-install hook
2. Store in Kubernetes Secret
3. Reference via `valueFrom.secretKeyRef` (matching Jenkins pattern at line 41)
4. Add migration notes for existing deployments

**Priority:** CRITICAL - Fix before next release

---

### 2. Gitea Credentials Exposed via Environment Variables

**Location:** `templates/wire-job.yaml` lines 34–37, `templates/_wire-helpers.tpl` line 37

**Current Code:**
```yaml
- name: GITEA_PASS
  value: {{ .Values.gitea.admin.password | quote }}
```

**Risk:**
- Credentials leak through `kubectl describe`
- Visible in event logs and audit trails
- Accessible to any service account with namespace read permissions

**Remediation:**
```yaml
- name: GITEA_PASS
  valueFrom:
    secretKeyRef:
      name: {{ include "clusterfactory.fullname" . }}-gitea-admin
      key: password
```

**Reference:** Jenkins already implements this correctly (line 41)

**Priority:** CRITICAL

---

### 3. API Tokens Logged in Error Paths

**Location:** `factory/components/gitea.py` line 182

**Current Code:**
```python
raise ValueError(f"Token mint failed: {token_data}")
```

**Risk:**
- Full API response including tokens written to logs on partial failures
- Token exposure in log aggregation systems
- Permanent credential leak in log storage

**Remediation:**
```python
# Redact sensitive fields
safe_data = {k: v for k, v in token_data.items() if k not in ['token', 'sha1']}
raise ValueError(f"Token mint failed: {safe_data}")
```

**Priority:** HIGH

---

### 4. SHA-1 Hash Usage for Token Storage

**Location:** `factory/components/gitea.py` line 179, `templates/_wire-helpers.tpl` line 44

**Current Code:**
```bash
jq -r ".sha1"
```

**Risk:**
- Gitea API uses SHA-1 for token hashing (deprecated hash algorithm)
- Vulnerable to collision attacks
- Compliance issues for security-sensitive deployments

**Remediation:**
1. Document limitation in README and security documentation
2. Add token rotation recommendations (30-day TTL)
3. Monitor Gitea upstream for SHA-256 migration
4. Implement automated token rotation in wire jobs

**Priority:** HIGH - Documentation required immediately

---

## 🟡 Medium Severity Issues

### 5. Unencrypted Cluster-Internal HTTP Traffic

**Location:** `factory/components/gitea.py` line 39

**Current Code:**
```python
f"http://{self.service}:{self.port}"
```

**Risk:**
- Plain HTTP vulnerable to in-cluster MITM attacks
- Compromised pod/node can intercept credentials
- Non-compliant with strict airgap security requirements

**Remediation:**
- Add TLS configuration option for cluster-internal services
- Document security trade-offs for airgap deployments
- Consider service mesh integration for mTLS

**Priority:** MEDIUM - Document workaround for strict environments

---

### 6. Missing Timeout on HTTP Requests

**Location:** `factory/components/gitea.py` lines 146, 153, 172, 235, 282, 320, 359, 372, 383

**Current Code:**
```python
resp = requests.post(...)  # No timeout
```

**Risk:**
- Wire job hangs indefinitely on slow/unresponsive Gitea
- Resource exhaustion from stuck pods
- Deployment failures with no clear error message

**Remediation:**
```python
# Add to class initialization
self.session = requests.Session()
self.session.timeout = 30  # Default timeout

# Or per-request
resp = requests.post(..., timeout=30)
```

**Note:** `ready()` check already implements `timeout=3` (line 64)

**Priority:** MEDIUM

---

### 7. Duplicate Credential Storage in Jenkins

**Location:** `templates/_wire-helpers.tpl` lines 106–112

**Current Code:**
```xml
<string>org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl</string>
<!-- ... -->
<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
```

**Risk:**
- Same Gitea token stored twice in Jenkins under different credential types
- Token username stored as password field
- Compromised Jenkins leaks credential in multiple formats

**Remediation:**
- Standardize on single credential type (UsernamePassword recommended)
- Remove StringCredentials variant
- Update job templates to reference unified credential ID

**Priority:** MEDIUM

---

### 8. Orphaned ClusterRoleBinding from Preflight Hooks

**Location:** `templates/preflight-rbac.yaml`

**Current Code:**
```yaml
helm.sh/hook-delete-policy: before-hook-creation
```

**Risk:**
- ClusterRoleBinding persists between installs
- ServiceAccount deleted but binding remains
- Potential privilege escalation if SA recreated with same name

**Remediation:**
```yaml
helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
```

**Priority:** MEDIUM

---

### 9. Shell/JSON Injection in Organization Names

**Location:** `templates/_wire-helpers.tpl` lines 55, 120, 129, 136, 143, 153, 186, 194

**Current Code:**
```bash
curl "https://gitea/api/v1/orgs/${ORG}/repos"
```

**Risk:**
- Unsanitized `wire.org` and `wire.repo.name` values injected into shell commands
- Example attack: `wire.org: "foo; rm -rf /"`
- JSON injection: `wire.org: 'foo","visibility":"public"'`

**Remediation:**
1. Add `values.schema.json` validation:
```json
{
  "properties": {
    "wire": {
      "properties": {
        "org": {
          "type": "string",
          "pattern": "^[a-z0-9][a-z0-9-]*[a-z0-9]$"
        },
        "repo": {
          "properties": {
            "name": {
              "type": "string",
              "pattern": "^[a-z0-9][a-z0-9-]*[a-z0-9]$"
            }
          }
        }
      }
    }
  }
}
```

2. Add runtime validation in Python engine

**Priority:** MEDIUM - HIGH (depending on user input sources)

---

### 10. Sensitive Path Disclosure in Error Messages

**Location:** `factory/model/platform.py` lines 111, 114, 120–122

**Current Code:**
```python
# Raises KeyError on missing fields
org = data["metadata"]["organization"]
```

**Risk:**
- Unhandled KeyError reveals file paths in traceback
- Generic exception handler in `__main__.py` logs full stack
- Internal path structure exposed in logs

**Remediation:**
```python
def from_yaml(cls, path: Path) -> "Platform":
    with path.open() as f:
        data = yaml.safe_load(f)
    
    # Validate required fields
    required = ["metadata.organization", "metadata.name", "spec"]
    for field in required:
        if not _get_nested(data, field.split(".")):
            raise ValueError(f"Missing required field: {field}")
    
    return cls(...)
```

**Priority:** MEDIUM

---

## 🟢 Low Severity / Hygiene Issues

### 11. Missing Pod Security Standards

**Location:** Gitea runner ServiceAccount, namespace configuration

**Risk:**
- Compromised CI workflow can create privileged pods
- No enforcement of Pod Security Admission
- Potential container escape via hostPath mounts

**Remediation:**
1. Document Pod Security Admission requirements
2. Add namespace labels in chart:
```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```
3. Add pre-flight check for PSA configuration

**Priority:** LOW - Documentation

---

### 12. Unsafe Image Pull in Bundle Script

**Location:** `hack/bundle.sh` line ~80

**Current Code:**
```bash
docker pull "${img}"
```

**Risk:**
- Shell metacharacters in subchart image names
- Trustworthy current dependencies, but risky pattern
- Supply chain attack vector if untrusted chart added

**Remediation:**
```bash
# Validate image format
if ! [[ "${img}" =~ ^[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+$ ]]; then
  echo "Invalid image format: ${img}"
  exit 1
fi
docker pull "${img}"
```

**Priority:** LOW

---

### 13. Broken Preflight Image Reference

**Location:** `templates/preflight-job.yaml` line 26

**Current Code:**
```yaml
image: {{ .Values.wire.image }}
```

**Risk:**
- `wire.image` is now a dictionary (bash/python keys)
- Template renders as Go map string: `map[bash:alpine:3.19 ...]`
- ImagePullBackOff on preflight when `persistence.enabled=true`

**Remediation:**
```yaml
image: {{ .Values.wire.image.bash }}
```

**Priority:** LOW - Functional bug, breaks preflight silently

---

### 14. Incorrect Security Advisory Path

**Location:** `SECURITY.md`

**Risk:**
- References incorrect repository path
- Security advisories may not reach maintainers
- Delayed vulnerability disclosure

**Remediation:**
- Update `SECURITY.md` with canonical repository URL
- Verify GitHub Security Advisory configuration
- Test security disclosure workflow

**Priority:** LOW

---

## Remediation Roadmap

### Phase 1: Critical Fixes (Target: Next Release)
- [ ] Issue #1: Implement secret-based Gitea password generation
- [ ] Issue #2: Migrate Gitea credentials to Secrets
- [ ] Issue #3: Add token redaction in error logging
- [ ] Issue #4: Document SHA-1 limitation and rotation policy

### Phase 2: Medium Priority (Target: Release + 1)
- [ ] Issue #5: Document TLS options for strict environments
- [ ] Issue #6: Add request timeouts globally
- [ ] Issue #7: Standardize Jenkins credential storage
- [ ] Issue #8: Fix hook deletion policy
- [ ] Issue #9: Implement values.schema.json validation
- [ ] Issue #10: Improve error handling in Platform.from_yaml

### Phase 3: Hardening (Target: Release + 2)
- [ ] Issue #11: Add Pod Security Standards enforcement
- [ ] Issue #12: Harden bundle.sh image validation
- [ ] Issue #13: Fix preflight image reference
- [ ] Issue #14: Update SECURITY.md

### Phase 4: Continuous Improvement
- [ ] Regular dependency updates via Dependabot
- [ ] Automated security scanning in CI/CD
- [ ] Penetration testing for wire job flows
- [ ] Security audit of jenkins.py and executor components

---

## Testing Requirements

### Security Tests to Add

1. **Credential Leak Tests**
   - Verify no passwords in pod specs
   - Check environment variable sources
   - Validate Secret references

2. **Injection Tests**
   - Test shell injection in org/repo names
   - Validate JSON escaping in API calls
   - Verify schema validation blocks malicious input

3. **Error Handling Tests**
   - Ensure tokens not logged on failures
   - Verify sanitized error messages
   - Check exception handling paths

4. **RBAC Tests**
   - Verify minimal permissions
   - Test hook cleanup
   - Validate ClusterRole scope

---

## Scope Limitations

This review covered:
- ✅ `values.yaml` and chart templates
- ✅ `factory/components/gitea.py`
- ✅ Wire helper scripts (`_wire-helpers.tpl`)
- ✅ Preflight job configurations
- ✅ RBAC manifests

**Not yet reviewed:**
- ⏳ `factory/components/jenkins.py`
- ⏳ Executor/resolver/planner/verifier modules
- ⏳ Test fixtures and test code
- ⏳ Runner engine implementations
- ⏳ Helm subchart configurations

**Recommendation:** Continue security review of remaining components before production deployment.

---

## References

- [OWASP Kubernetes Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Kubernetes_Security_Cheat_Sheet.html)
- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Helm Security Best Practices](https://helm.sh/docs/topics/securing_helm/)
- [CWE-798: Use of Hard-coded Credentials](https://cwe.mitre.org/data/definitions/798.html)

---

## Approval & Sign-off

- [ ] Security Review Complete
- [ ] Remediation Plan Approved
- [ ] Implementation Resources Allocated
- [ ] Timeline Confirmed

**Next Steps:** Prioritize Phase 1 critical fixes for immediate implementation.
