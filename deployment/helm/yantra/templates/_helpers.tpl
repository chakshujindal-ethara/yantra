{{/* Names and labels. */}}
{{- define "yantra.fullname" -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "yantra.baseLabels" -}}
app.kubernetes.io/part-of: yantra
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
yantra.dev/env: {{ .Values.env }}
{{- end -}}

{{/* Object labels. Pod templates use baseLabels + selector instead (no duplicate keys). */}}
{{- define "yantra.labels" -}}
{{ include "yantra.baseLabels" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Selector labels for one component: (dict "root" $ "component" "gateway") */}}
{{- define "yantra.selector" -}}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* image ref: (dict "img" .Values.image.python) -> repo@digest, else repo:tag. */}}
{{- define "yantra.image" -}}
{{- if .img.digest -}}
{{ .img.repository }}@{{ .img.digest }}
{{- else if .img.tag -}}
{{ .img.repository }}:{{ .img.tag }}
{{- else -}}
{{ fail (printf "image %s needs a digest (staging/prod) or a tag (local)" .img.repository) }}
{{- end -}}
{{- end -}}

{{- define "yantra.release" -}}
{{- if .Values.release -}}{{ .Values.release }}
{{- else if .Values.image.python.digest -}}{{ .Values.image.python.digest }}
{{- else -}}{{ .Values.image.python.tag }}
{{- end -}}
{{- end -}}

{{/* The Secret holding one key. */}}
{{- define "yantra.secretName" -}}
{{- printf "%s-%s" (include "yantra.fullname" .root) .key -}}
{{- end -}}

{{/* Every secret key the release references, as a list of dicts {name, optional}. */}}
{{- define "yantra.secretKeys" -}}
{{- $keys := .Values.secrets.keys -}}
{{- if .Values.odoo.enabled -}}
{{- range .Values.odoo.secretKeys -}}
{{- $keys = append $keys (dict "name" . "optional" false) -}}
{{- end -}}
{{- end -}}
{{- if .Values.assess.enabled -}}
{{- range .Values.assess.secretKeys -}}
{{- $keys = append $keys (dict "name" . "optional" false) -}}
{{- end -}}
{{- if .Values.assess.vertex -}}
{{- $keys = append $keys (dict "name" "vertex-service-account" "optional" false) -}}
{{- end -}}
{{- end -}}
{{- toYaml $keys -}}
{{- end -}}

{{/* Is a key optional? (dict "root" $ "key" "sentry-dsn") */}}
{{- define "yantra.secretOptional" -}}
{{- $opt := "false" -}}
{{- range (include "yantra.secretKeys" .root | fromYamlArray) -}}
{{- if and (eq .name $.key) .optional -}}{{- $opt = "true" -}}{{- end -}}
{{- end -}}
{{- $opt -}}
{{- end -}}

{{/* env entries for a map of ENV_VAR -> secret key. (dict "root" $ "map" ...) */}}
{{- define "yantra.secretEnv" -}}
{{- range $env, $key := .map }}
- name: {{ $env }}
  valueFrom:
    secretKeyRef:
      name: {{ include "yantra.secretName" (dict "root" $.root "key" $key) }}
      key: value
      optional: {{ include "yantra.secretOptional" (dict "root" $.root "key" $key) }}
{{- end }}
{{- end -}}

{{/* env entries for a plain map; empty values are skipped (unset). */}}
{{- define "yantra.plainEnv" -}}
{{- range $k, $v := . }}
{{- if ne (toString $v) "" }}
- name: {{ $k }}
  value: {{ toString $v | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "yantra.apiHost" -}}api.{{ .Values.domain }}{{- end -}}
{{- define "yantra.appHost" -}}app.{{ .Values.domain }}{{- end -}}
{{- define "yantra.filesHost" -}}files.{{ .Values.domain }}{{- end -}}
{{- define "yantra.assessHost" -}}assess.{{ .Values.domain }}{{- end -}}

{{/* Keycloak's base URL for in-cluster calls: assess.keycloakUrl, else the issuer's origin. */}}
{{- define "yantra.assessKeycloak" -}}
{{- if .Values.assess.keycloakUrl -}}{{ trimSuffix "/" .Values.assess.keycloakUrl }}
{{- else -}}{{ regexReplaceAll "/realms/.*$" .Values.assess.keycloakIssuer "" }}{{- end -}}
{{- end -}}

{{/* The adapter's settings on work-api and work-events (yantra_assess's v2 engine). */}}
{{- define "yantra.assessWorkEnv" -}}
{{- $full := include "yantra.fullname" . -}}
- {name: YANTRA_ASSESS_ENGINE, value: "v2"}
- {name: YANTRA_ASSESS_ODOO_URL, value: {{ printf "http://%s-odoo:%v" $full .Values.odoo.port | quote }}}
- {name: YANTRA_ASSESS_APP_URL, value: {{ printf "https://%s" (include "yantra.assessHost" .) | quote }}}
- {name: YANTRA_ASSESS_RETURN_URL, value: {{ printf "https://%s" (include "yantra.appHost" .) | quote }}}
- {name: YANTRA_ASSESS_KEYCLOAK_TOKEN_URL, value: {{ printf "%s/realms/yantra/protocol/openid-connect/token" (include "yantra.assessKeycloak" .) | quote }}}
- {name: YANTRA_ASSESS_CLIENT_ID, value: {{ .Values.assess.clientId | quote }}}
{{- with .Values.assess.syncSeconds }}
- {name: YANTRA_ASSESS_SYNC_SECONDS, value: {{ . | toString | quote }}}
{{- end }}
{{- include "yantra.secretEnv" (dict "root" . "map" (dict "YANTRA_ASSESS_CLIENT_SECRET" "assess-client-secret")) }}
{{- end -}}

{{- define "yantra.odooEnv" -}}
{{- $full := include "yantra.fullname" . -}}
- {name: HOST, value: {{ .Values.odoo.dbHost | quote }}}
- {name: USER, value: {{ .Values.odoo.dbUser | quote }}}
- name: PASSWORD
  valueFrom: {secretKeyRef: {name: {{ include "yantra.secretName" (dict "root" . "key" "odoo-db-password") }}, key: value}}
- {name: YANTRA_GATEWAY_URL, value: {{ .Values.odoo.gatewayUrl | default (printf "http://%s-gateway:%v" $full .Values.python.gateway.port) | quote }}}
- {name: YANTRA_KEYCLOAK_URL, value: {{ .Values.odoo.keycloakUrl | quote }}}
- {name: YANTRA_KEYCLOAK_CLIENT_ID, value: {{ .Values.odoo.keycloakClientId | quote }}}
- name: YANTRA_KEYCLOAK_CLIENT_SECRET
  valueFrom: {secretKeyRef: {name: {{ include "yantra.secretName" (dict "root" . "key" "keycloak-odoo-client-secret") }}, key: value}}
{{- if .Values.assess.enabled }}
{{- $s3 := .Values.assess.s3 }}
{{- $assess := printf "https://%s" (include "yantra.assessHost" .) }}
- {name: YANTRA_ODOO_PUBLIC_URL, value: {{ $assess | quote }}}
- {name: YANTRA_ASSESS_APP_URL, value: {{ $assess | quote }}}
- {name: YANTRA_APP_URL, value: {{ printf "https://%s" (include "yantra.appHost" .) | quote }}}
- {name: YANTRA_ASSESS_S3_BUCKET, value: {{ $s3.bucket | quote }}}
- {name: YANTRA_ASSESS_S3_REGION, value: {{ $s3.region | quote }}}
- {name: YANTRA_ASSESS_S3_FOLDER, value: {{ $s3.folder | quote }}}
- {name: YANTRA_ASSESS_S3_ENDPOINT, value: {{ $s3.endpoint | default .Values.config.YANTRA_S3_ENDPOINT | quote }}}
- {name: YANTRA_ASSESS_S3_PUBLIC_ENDPOINT, value: {{ $s3.publicEndpoint | default .Values.config.YANTRA_S3_PUBLIC_ENDPOINT | quote }}}
- {name: YANTRA_ASSESS_KEYCLOAK_ISSUER, value: {{ .Values.assess.keycloakIssuer | quote }}}
- {name: YANTRA_ASSESS_JWKS_URL, value: {{ printf "%s/realms/yantra/protocol/openid-connect/certs" (include "yantra.assessKeycloak" .) | quote }}}
- {name: YANTRA_ASSESS_CLIENT_ID, value: {{ .Values.assess.clientId | quote }}}
- {name: YANTRA_SMTP_HOST, value: {{ .Values.config.YANTRA_SMTP_HOST | default "" | quote }}}
- {name: YANTRA_SMTP_PORT, value: {{ .Values.config.YANTRA_SMTP_PORT | default "" | quote }}}
- {name: YANTRA_MAIL_DOMAIN, value: {{ .Values.domain | quote }}}
{{- include "yantra.secretEnv" (dict "root" . "map" (dict "YANTRA_ASSESS_S3_ACCESS_KEY" "assess-s3-access-key" "YANTRA_ASSESS_S3_SECRET_KEY" "assess-s3-secret-key" "YANTRA_ASSESS_REDIS_URL" "assess-redis-url")) }}
{{- if .Values.assess.vertex }}
- {name: YANTRA_VERTEX_SA_JSON_FILE, value: /var/run/yantra/vertex/value}
{{- end }}
{{- end }}
{{- end -}}
