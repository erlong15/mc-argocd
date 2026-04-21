{{/* vim: set filetype=mustache: */}}
{{- define "cert-manager-webhook-yc.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cert-manager-webhook-yc.fullname" -}}
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

{{- define "cert-manager-webhook-yc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cert-manager-webhook-yc.selfSignedIssuer" -}}
{{ printf "%s-selfsign" (include "cert-manager-webhook-yc.fullname" .) }}
{{- end -}}

{{- define "cert-manager-webhook-yc.rootCAIssuer" -}}
{{ printf "%s-ca" (include "cert-manager-webhook-yc.fullname" .) }}
{{- end -}}

{{- define "cert-manager-webhook-yc.rootCACertificate" -}}
{{ printf "%s-ca" (include "cert-manager-webhook-yc.fullname" .) }}
{{- end -}}

{{- define "cert-manager-webhook-yc.servingCertificate" -}}
{{ printf "%s-webhook-tls" (include "cert-manager-webhook-yc.fullname" .) }}
{{- end -}}
