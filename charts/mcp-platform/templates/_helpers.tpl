{{- define "mcp-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcp-platform.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 40 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 40 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Service names of the components; other templates and the nginx upstreams use these. */}}
{{- define "mcp-platform.gateway" -}}{{ default (printf "%s-gateway" (include "mcp-platform.fullname" .)) .Values.gateway.serviceName }}{{- end -}}
{{- define "mcp-platform.broker" -}}{{ default (printf "%s-broker" (include "mcp-platform.fullname" .)) .Values.broker.serviceName }}{{- end -}}
{{- define "mcp-platform.portal" -}}{{ printf "%s-portal" (include "mcp-platform.fullname" .) }}{{- end -}}
{{- define "mcp-platform.nginx" -}}{{ printf "%s-nginx" (include "mcp-platform.fullname" .) }}{{- end -}}
{{- define "mcp-platform.keycloak" -}}{{ printf "%s-keycloak" (include "mcp-platform.fullname" .) }}{{- end -}}

{{- define "mcp-platform.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "mcp-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{/* Call with (dict "root" . "component" "gateway"). */}}
{{- define "mcp-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mcp-platform.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* Image reference: registry/repository:version, where version may carry @sha256:digest as in compose.yaml. */}}
{{- define "mcp-platform.image" -}}
{{- $registry := .root.Values.global.imageRegistry -}}
{{- if .image.registry -}}{{- $registry = .image.registry -}}{{- end -}}
{{- printf "%s/%s:%s" $registry .image.repository (required "image version is required" .image.version) -}}
{{- end -}}

{{- define "mcp-platform.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
  {{- range . }}
  - name: {{ . }}
  {{- end }}
{{- end }}
{{- end -}}

{{/* Public address of the platform. */}}
{{- define "mcp-platform.origin" -}}
{{- required "global.publicOrigin is required (https://<domain>)" .Values.global.publicOrigin | trimSuffix "/" -}}
{{- end -}}

{{- define "mcp-platform.issuer" -}}
{{- printf "%s/auth/realms/%s" (include "mcp-platform.origin" .) .Values.keycloak.realm -}}
{{- end -}}

{{/* Keycloak endpoints on the address the platform's own components use (certificate of the internal CA). */}}
{{- define "mcp-platform.kcInternal" -}}
{{- printf "%s/auth/realms/%s/protocol/openid-connect" (required "keycloak.internalBaseUrl is required" .Values.keycloak.internalBaseUrl | trimSuffix "/") .Values.keycloak.realm -}}
{{- end -}}

{{/* Container security context shared by every workload; the user comes from the image. */}}
{{- define "mcp-platform.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end -}}

{{/* Environment of one component: derived entries, then the documented defaults of its env map, then extraEnv.
     Call with (dict "derived" <dict> "env" <dict> "extra" <list>). Values are always quoted: environment values are strings. */}}
{{- define "mcp-platform.env" -}}
{{- $merged := merge (dict) .env .derived -}}
{{- $overridden := list -}}
{{- range .extra }}{{- $overridden = append $overridden .name -}}{{- end }}
{{- range $name := keys $merged | sortAlpha }}
{{- $value := get $merged $name }}
{{- if and (ne (toString $value) "") (not (has $name $overridden)) }}
- name: {{ $name }}
  value: {{ toString $value | quote }}
{{- end }}
{{- end }}
{{- with .extra }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Pod security context with the user of the image. containerd refuses a pod that sets runAsGroup without runAsUser.
     Call with (dict "root" . "runAsUser" <uid>). */}}
{{- define "mcp-platform.podSecurityContext" -}}
{{- $context := deepCopy .root.Values.podSecurityContext -}}
{{- if .runAsUser }}{{- $_ := set $context "runAsUser" .runAsUser -}}{{- end -}}
{{- toYaml $context -}}
{{- end -}}
