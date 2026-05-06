# Airgap delivery via Zarf

ClusterFactory uses [Zarf](https://zarf.dev/) as a thin wrapper for airgap delivery. The chart works connected without any Zarf involvement; Zarf is purely the delivery vehicle when the target cluster can't reach upstream registries.

## What Zarf does for us

- **Image collection.** `zarf package create` reads `zarf.yaml`, pulls every image listed under `components[].images`, and bundles them into the package tarball.
- **In-cluster registry.** `zarf package deploy` stands up a registry inside the target cluster and pushes the bundled images to it. Subchart pods pull from this in-cluster registry, not from the internet.
- **Helm install.** Zarf invokes `helm install` against the bundled chart with `values-airgap.yaml` overlaid on top of the user's values.
- **Signature verification.** The package can be signed with cosign; `zarf package deploy --key=cosign.pub` verifies the signature before deploying.

That's all. Zarf doesn't change how the chart works, doesn't replace Helm, and doesn't add runtime components beyond the in-cluster registry it stands up.

## Build the package

In a connected environment:

```sh
helm repo add gitea https://dl.gitea.com/charts/
helm repo add jenkins https://charts.jenkins.io
helm dependency build .

zarf package create . --confirm
```

The output is `zarf-package-clusterfactory-<arch>-<version>.tar.zst` — a single file containing the chart, its subchart deps, all required images, and metadata.

To sign the package:

```sh
zarf package create . --confirm --signing-key cosign.key
```

## Move the package across the airgap

Copy the `.tar.zst` file by whatever means your airgap policy allows — USB, SFTP through a one-way gateway, signed media drop. The package is self-contained; nothing else needs to cross.

## Deploy in the airgap

In the target environment:

```sh
zarf init --confirm

zarf package deploy zarf-package-clusterfactory-*.tar.zst --confirm \
  --set GITEA_ADMIN_PASSWORD='<your-password>'
```

`zarf init` is a one-time operation per cluster — it stands up the in-cluster registry and Zarf's own state. `zarf package deploy` is what actually installs ClusterFactory.

If the package was signed:

```sh
zarf package deploy zarf-package-clusterfactory-*.tar.zst --confirm \
  --key cosign.pub \
  --set GITEA_ADMIN_PASSWORD='<your-password>'
```

## Verify the deploy

After Zarf reports success:

```sh
kubectl -n cicd get pods                         # all pods Running
kubectl -n cicd logs job/cf-wire                 # wire script ran successfully
kubectl -n cicd get configmap cf-wire-result -o yaml  # wiring receipt
helm test cf -n cicd                             # functional checks pass
```

The output should be identical to a connected install — that's the point of treating airgap as a wrapper rather than an architecture.

## What's in the package

```
zarf-package-clusterfactory-amd64-0.4.0.tar.zst
├── checksums.txt
├── components/
│   └── clusterfactory/
│       ├── charts/                # this chart + subcharts
│       └── values/values-airgap.yaml
├── images/                        # OCI image layers
│   ├── alpine-curl-8.10.0/
│   ├── gitea-act_runner-0.2.11/
│   ├── gitea-gitea-1.23.6-rootless/
│   ├── jenkins-jenkins-2.541.3-jdk21/
│   └── ...
├── sboms.tar                      # SBOM for each image (skip with --skip-sbom)
└── zarf.yaml                      # the manifest
```

## Bumping subchart versions

When you bump `gitea` or `jenkins` in `Chart.yaml`, you also need to update the image list in `zarf.yaml`. This is the deliberate cost of pinning versions in two places — the alternative (auto-discovery from rendered templates) is convenient until it silently misses a transitively-referenced image and the airgap deploy fails.

The CI workflow runs `zarf package create` against every PR, which catches missing or mistyped images at build time rather than deploy time. See `.github/workflows/ci.yaml`.

## What Zarf doesn't solve

- **Configuration drift after install.** Zarf delivers a known state at time T0. What the operator does after T0 is between them and their change-management process. The `cf-wire-result` ConfigMap is a baseline you can diff against if you care.
- **Kernel-level dependencies.** If your Jenkinsfile pipelines need a kernel module the airgapped node doesn't have, Zarf can't help. Image-level deps only.
- **Day-2 operations.** Zarf installs. It doesn't manage upgrades over time, rotate certificates, or handle backup/restore. Those are separate concerns and intentionally outside the scope of "deliver the platform."
