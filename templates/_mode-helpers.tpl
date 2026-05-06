{{/*
Mode → derived flags.

Mode values: gitea-actions | jenkins | both

Derivation:
  | mode           | gitea | jenkins | runner | gitea actions enabled |
  |----------------|-------|---------|--------|-----------------------|
  | gitea-actions  |   ✓   |    ✗    |   ✓    |          true         |
  | jenkins        |   ✓   |    ✓    |   ✗    |          false        |
  | both           |   ✓   |    ✓    |   ✓    |          true         |

Gitea is always installed — it's the git host in every mode.
*/}}

{{- define "clusterfactory.mode.giteaActionsEnabled" -}}
{{- if or (eq .Values.mode "gitea-actions") (eq .Values.mode "both") -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "clusterfactory.mode.jenkinsEnabled" -}}
{{- if or (eq .Values.mode "jenkins") (eq .Values.mode "both") -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "clusterfactory.mode.runnerEnabled" -}}
{{- if or (eq .Values.mode "gitea-actions") (eq .Values.mode "both") -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/*
Validate mode at template time. Renders an error if mode is invalid —
caught by helm template/install before any resources are created.

values.schema.json catches this earlier in normal use, but this gives
a clear error for tools that don't honor the schema.
*/}}
{{- define "clusterfactory.mode.validate" -}}
{{- $valid := list "gitea-actions" "jenkins" "both" -}}
{{- if not (has .Values.mode $valid) -}}
{{- fail (printf "Invalid mode %q. Must be one of: %s" .Values.mode (join ", " $valid)) -}}
{{- end -}}
{{- if not .Values.giteaAdmin.password -}}
{{- fail "giteaAdmin.password must be set. Pass --set giteaAdmin.password=<value> or use a values file." -}}
{{- end -}}
{{/* Mode and subchart enabled flags must be consistent. */}}
{{- $jenkinsExpected := include "clusterfactory.mode.jenkinsEnabled" . -}}
{{- $jenkinsActual := ternary "true" "false" (and .Values.jenkins .Values.jenkins.enabled) -}}
{{- if ne $jenkinsExpected $jenkinsActual -}}
{{- fail (printf "mode=%s requires jenkins.enabled=%s but got jenkins.enabled=%s. Use --set jenkins.enabled=%s or a values file that sets both consistently." .Values.mode $jenkinsExpected $jenkinsActual $jenkinsExpected) -}}
{{- end -}}
{{- if not .Values.gitea.enabled -}}
{{- fail "gitea.enabled must be true — Gitea is the git host in every mode." -}}
{{- end -}}
{{- end -}}
