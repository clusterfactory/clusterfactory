# bundle/ — test-only deployment scaffolding

Never shipped. Holds what CI needs to stand up a throwaway cluster and
deploy the package into it with egress blocked (uds-way.md §11 gate 3):

- `up.sh` — creates the cluster, installs Calico, applies the egress
  policy to every namespace the package touches. Idempotent; run it
  locally too: `bundle/up.sh <dir-with-zarf-init-pkg> && make package deploy`. Runs `zarf init` itself, *before* creating the package namespaces (see comment in the script).
- `kind-config.yaml` — kind cluster with the default CNI **disabled** so
  Calico can be installed. kindnet does not enforce `NetworkPolicy`; the
  egress test is a silent no-op without a policy-enforcing CNI.
- `default-deny-egress.yaml` — applied after `zarf init` to the namespaces
  the package does not manage (`default`, `zarf`). The application
  namespaces are created and locked down by `charts/config` itself; the
  deploy gate tests *that* policy. Allows in-cluster pods, DNS and the API
  server by node IP (the Jenkins config-reload sidecar lists ConfigMaps;
  without this rule Jenkins never leaves `Init`).

Deploy-time throwaway dependencies (test Postgres, etc.) live here too
once needed. Integration checks that run against this cluster live in
`tests/`.
