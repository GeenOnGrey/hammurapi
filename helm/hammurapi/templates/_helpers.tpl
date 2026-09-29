{{- define "hammurapi.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}{{ .Release.Name | trunc 63 | trimSuffix "-" }}{{ else }}{{ printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}{{ end }}
{{- end }}

{{- define "hammurapi.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- define "hammurapi.selector" -}}
app.kubernetes.io/name: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "hammurapi.secretName" -}}
{{- if .Values.existingSecret }}{{ .Values.existingSecret }}{{ else }}{{ include "hammurapi.fullname" . }}{{ end }}
{{- end }}

{{- define "hammurapi.image" -}}
{{ printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}

{{- define "hammurapi.coreImage" -}}
{{- $img := mergeOverwrite (deepCopy .Values.image) .Values.coreImage -}}
{{ printf "%s:%s" $img.repository ($img.tag | default .Chart.AppVersion) }}
{{- end }}

{{- define "hammurapi.runnerImage" -}}
{{- $img := mergeOverwrite (deepCopy .Values.image) .Values.runner.image -}}
{{ printf "%s:%s" $img.repository ($img.tag | default .Chart.AppVersion) }}
{{- end }}

{{- define "hammurapi.envFrom" -}}
envFrom:
  - configMapRef: { name: {{ include "hammurapi.fullname" . }} }
  - secretRef: { name: {{ include "hammurapi.secretName" . }} }
{{- end }}

{{- define "hammurapi.probes" -}}
livenessProbe:
  httpGet: { path: {{ .Values.probes.liveness.path }}, port: {{ .Values.probes.liveness.port }} }
  periodSeconds: 10
readinessProbe:
  httpGet: { path: {{ .Values.probes.readiness.path }}, port: {{ .Values.probes.readiness.port }} }
  periodSeconds: 5
{{- end }}
