# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| latest  | Yes       |

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report vulnerabilities by emailing the maintainers or opening a
[GitHub Security Advisory](https://github.com/clusterfactory/clusterfactory/security/advisories/new).

Include:
- Description of the vulnerability
- Steps to reproduce
- Affected versions
- Suggested fix (if known)

You will receive a response within 72 hours. We aim to release a patch within 14 days of confirmation.

## Security Scanning

This repository runs automated security scans on every push:
- **Trivy** — Helm/K8s misconfiguration scanning
- **OSSF Scorecard** — supply chain security score

Results are visible in the [GitHub Security tab](https://github.com/clusterfactory/clusterfactory/security/code-scanning).

## Known Limitations

### Gitea API Token Storage (SHA-1)

**Issue**: Gitea's API uses SHA-1 for token hashing (`sha1` field in API responses).

**Risk**: SHA-1 is cryptographically deprecated and vulnerable to collision attacks.

**Mitigation**:
1. **Token Rotation**: Rotate Gitea API tokens regularly (recommended: 30-day TTL)
2. **Network Isolation**: Run Gitea in isolated network segments
3. **Monitor Upstream**: We track [Gitea upstream](https://github.com/go-gitea/gitea/issues) for SHA-256 migration
4. **Audit Access**: Review token usage in Gitea admin panel regularly

**Implementation**:
```bash
# Manual token rotation (run monthly)
kubectl exec -n cicd deploy/gitea -- \
  gitea admin user regenerate-secret --username gitea-admin
```

For production deployments requiring stronger cryptographic guarantees, consider:
- Using Gitea behind mTLS/VPN
- Implementing token expiry automation
- Regular security audits of token access patterns
