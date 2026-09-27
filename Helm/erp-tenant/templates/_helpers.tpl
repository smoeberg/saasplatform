{{/*
Expand the name of the chart.
*/}}
{{- define "erp-tenant.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "erp-tenant.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "erp-tenant.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "erp-tenant.labels" -}}
helm.sh/chart: {{ include "erp-tenant.chart" . }}
{{ include "erp-tenant.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "erp-tenant.selectorLabels" -}}
app.kubernetes.io/name: {{ include "erp-tenant.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: dolibarr
tenant: {{ .Values.instance | quote }}
{{- end -}}

{{/*
Check if suspended
*/}}
{{- define "erp-tenant.isSuspended" -}}
{{- if .Values.suspended -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Check if migration is enabled
*/}}
{{- define "erp-tenant.isMigration" -}}
{{- if .Values.dolibarr.migration.enabled -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Check if rollback is enabled
*/}}
{{- define "erp-tenant.isRollback" -}}
{{- if .Values.rollback.enabled -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}
