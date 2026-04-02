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
