{{/*
Standard chart helpers.
*/}}

{{- define "clusterfactory.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "clusterfactory.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "clusterfactory.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "clusterfactory.labels" -}}
app.kubernetes.io/name: {{ include "clusterfactory.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "clusterfactory.chart" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{/*
Service DNS names — derived from how the upstream subcharts name their services.
Used by the wire Job to reach Gitea and Jenkins.
*/}}
{{- define "clusterfactory.giteaService" -}}
{{- printf "%s-gitea-http.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- end -}}

{{- define "clusterfactory.jenkinsService" -}}
{{- printf "%s-jenkins.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- end -}}

{{/*
Names of the secrets the wire Job consumes.
*/}}
{{- define "clusterfactory.giteaAdminSecret" -}}
clusterfactory-gitea-admin
{{- end -}}

{{- define "clusterfactory.jenkinsAdminSecret" -}}
{{- printf "%s-jenkins" .Release.Name -}}
{{- end -}}
