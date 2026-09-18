# bundle/ — test-only deployment scaffolding

Never shipped. Holds what CI needs to stand up a throwaway cluster and
deploy the package into it with egress blocked (uds-way.md §11 gate 3):

- `kind-config.yaml` — kind cluster with the default CNI **disabled** so
  Calico can be installed. kindnet does not enforce `NetworkPolicy`; the
  egress test is a silent no-op without a policy-enforcing CNI.
- `default-deny-egress.yaml` — applied to every namespace before
  `zarf init`, so any component that phones home fails to come up.

Deploy-time throwaway dependencies (test Postgres, etc.) live here too
once needed. Integration checks that run against this cluster live in
`tests/`.
