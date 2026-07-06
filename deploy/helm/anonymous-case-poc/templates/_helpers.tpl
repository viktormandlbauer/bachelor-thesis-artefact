{{/* Release-scoped resource name prefix. */}}
{{- define "case-poc.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Common labels for all objects of this chart. */}}
{{- define "case-poc.labels" -}}
app.kubernetes.io/part-of: anonymous-case-poc
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Selector labels per component; call with (dict "root" . "component" "x") */}}
{{- define "case-poc.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{/*
Pod-level security context satisfying the cluster-wide "restricted"
Pod Security Standard; call with (dict "uid" <int>)
*/}}
{{- define "case-poc.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "case-poc.containerSecurityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
{{- end -}}
