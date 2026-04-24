{{/* 
Expand the name of the chart.
*/}}
{{- define "clusterfactory.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "clusterfactory.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "clusterfactory.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "clusterfactory.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Image reference with optional digest pinning
Usage: {{ include "clusterfactory.image" (dict "Values" .Values "name" "gitea") }}
Returns: repository@digest if digest is set, otherwise repository:tag
*/}}
{{- define "clusterfactory.image" -}}
{{- $img := index .Values.images .name }}
{{- if $img.digest }}
{{- printf "%s@%s" $img.repository $img.digest }}
{{- else }}
{{- printf "%s:%s" $img.repository $img.tag }}
{{- end }}
{{- end }}

{{/*
Wire image reference based on engine
Returns: repository@digest if digest is set, otherwise repository:tag
*/}}
{{- define "clusterfactory.wire.image" -}}
{{- $engine := .Values.wire.engine }}
{{- $img := index .Values.images.wire $engine }}
{{- if $img.digest }}
{{- printf "%s@%s" $img.repository $img.digest }}
{{- else }}
{{- printf "%s:%s" $img.repository $img.tag }}
{{- end }}
{{- end }}
