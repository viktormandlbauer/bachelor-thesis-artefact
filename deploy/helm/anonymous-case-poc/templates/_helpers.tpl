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

{{/*
Service image reference, optionally prefixed with the internal registry
(values.yaml images.registry); call with (dict "root" . "img" .Values.images.<svc>)
*/}}
{{- define "case-poc.image" -}}
{{- with .root.Values.images.registry -}}{{ . }}/{{ end -}}
{{ .img.repository }}:{{ .img.tag }}
{{- end -}}

{{/*
Node pinning for the stateful infra components (Artemis, PostgreSQL,
Keycloak): they run on the dedicated control-plane node, where their
local-path PVs live (values.yaml `scheduling.infraNodeSelector`).
*/}}
{{- define "case-poc.infraNodeSelector" -}}
{{- with .Values.scheduling.infraNodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Soft preference of the stateless app services for worker nodes (label
case-poc/role=worker, set by the k3s agent config). Preferred — not
required — so a single-node cluster (WORKERS=0) still schedules them.
*/}}
{{- define "case-poc.servicesNodeAffinity" -}}
{{- if .Values.scheduling.servicesPreferWorkers }}
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: case-poc/role
              operator: In
              values: [worker]
{{- end }}
{{- end -}}
