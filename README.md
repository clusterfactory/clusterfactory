# clusterfactory

**Airgap CI platform: Gitea (git) + Jenkins (workflow engine), auto-wired, delivered as a Zarf package.**

Zarf handles supply chain: signed bundle, SBOMs, image transport, Helm installs. clusterfactory handles what Zarf doesn't — cross-service credential wiring. After Zarf installs Gitea and Jenkins, a small Python wire engine mints an API token from Gitea, stores it in Jenkins as a credential, creates a `cf-demo/hello-world` repo, commits a Jenkinsfile, and creates a matching Jenkins pipeline. It emits a structural SHA proving the wiring graph executed as declared.

## Demo

On a connected machine:
```bash
zarf package create .
```

Transfer `clusterfactory-ci-0.3.0-amd64.tar.zst` to the airgapped cluster. Then:
```bash
zarf package deploy clusterfactory-ci-0.3.0-amd64.tar.zst \
    --key cosign.pub \
    --set GITEA_ADMIN_PASSWORD=<yourpassword>
```

At the end, Zarf prints the structural SHA and the port-forward commands. Push to `cf-demo/hello-world` to trigger a build.

## Status

v0.3 is a demo. One deployment mode (Gitea as git, Jenkins as CI). Additional components (Harbor, OpenBao) and third-party extensibility are planned for v0.4+. See `refactor-to-zarf.md` for the roadmap.

## Requirements

- [Zarf](https://zarf.dev/) 0.32.0+
- Kubernetes 1.28+
- kubectl

## License

MIT - see [LICENSE](LICENSE)
