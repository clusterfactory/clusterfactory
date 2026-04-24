{{/* 
Deployment Mode Helpers
These helpers determine which components to enable based on the selected deployment mode.
*/}}

{{/*
Check if mode is gitea-actions
Returns: "true" or ""
*/}}
{{- define "clusterfactory.mode.isGiteaActions" -}}
{{- eq .Values.mode "gitea-actions" }}
{{- end }}

{{/*
Check if mode is jenkins
Returns: "true" or ""
*/}}
{{- define "clusterfactory.mode.isJenkins" -}}
{{- eq .Values.mode "jenkins" }}
{{- end }}

{{/*
Check if mode is both
Returns: "true" or ""
*/}}
{{- define "clusterfactory.mode.isBoth" -}}
{{- eq .Values.mode "both" }}
{{- end }}

{{/*
Check if Gitea Actions should be enabled
Returns: "true" or ""
Enabled when: mode=gitea-actions OR mode=both
*/}}
{{- define "clusterfactory.mode.giteaActionsEnabled" -}}
{{- or (eq .Values.mode "gitea-actions") (eq .Values.mode "both") }}
{{- end }}

{{/*
Check if Jenkins should be enabled
Returns: "true" or ""
Enabled when: mode=jenkins OR mode=both
*/}}
{{- define "clusterfactory.mode.jenkinsEnabled" -}}
{{- or (eq .Values.mode "jenkins") (eq .Values.mode "both") }}
{{- end }}

{{/*
Get Gitea Actions ENABLED config value
Returns: "true" or "false" as string
*/}}
{{- define "clusterfactory.mode.giteaActionsConfig" -}}
{{- if or (eq .Values.mode "gitea-actions") (eq .Values.mode "both") -}}
"true"
{{- else -}}
"false"
{{- end }}
{{- end }}

{{/*
Check if runner should be deployed
Returns: true or false (boolean for conditional template rendering)
*/}}
{{- define "clusterfactory.mode.runnerEnabled" -}}
{{- and .Values.runner.enabled (or (eq .Values.mode "gitea-actions") (eq .Values.mode "both")) }}
{{- end }}
