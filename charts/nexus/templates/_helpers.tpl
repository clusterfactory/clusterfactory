{{- define "cf-nexus.labels" -}}
app.kubernetes.io/name: nexus
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: clusterfactory
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}
{{- define "cf-nexus.image" -}}
{{- $ref := printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- if .Values.image.digest }}{{ printf "%s@%s" $ref .Values.image.digest }}{{ else }}{{ $ref }}{{ end -}}
{{- end }}
