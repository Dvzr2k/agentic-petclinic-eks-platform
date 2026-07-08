{{/*
Each service is deployed as its own Helm release (release name == service
name, e.g. "customers-service") — see the install command documented in
values.yaml. So the release name doubles as the resource name and the
lookup key for the per-service override maps.
*/}}
{{- define "petclinic-service.name" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "petclinic-service.labels" -}}
app.kubernetes.io/name: {{ include "petclinic-service.name" . }}
app.kubernetes.io/part-of: petclinic
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/component: {{ .Values.component }}
{{- end -}}

{{- define "petclinic-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "petclinic-service.name" . }}
{{- end -}}

{{/*
Resolves the replica count: per-service prod override if present, else the
chart default (1) — this is how dev implicitly gets 1 replica everywhere
without dev.yaml needing to say so.
*/}}
{{- define "petclinic-service.replicaCount" -}}
{{- $override := index .Values.replicaOverrides (include "petclinic-service.name" .) -}}
{{- if $override -}}{{ $override }}{{- else -}}{{ .Values.replicaCount }}{{- end -}}
{{- end -}}

{{/*
Merges configMapOverrides[<release-name>] (env-specific keys, e.g. the
per-env SPRING_DATASOURCE_URL) on top of the per-service base configMap.
Override wins on key collision.
*/}}
{{- define "petclinic-service.configMapData" -}}
{{- $override := index .Values.configMapOverrides (include "petclinic-service.name" .) | default dict -}}
{{- merge $override .Values.configMap | toYaml -}}
{{- end -}}
