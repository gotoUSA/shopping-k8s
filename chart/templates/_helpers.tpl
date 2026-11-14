{{/* The app image: API, workers, Beat and the migrate Job all run it. */}}
{{- define "shopping.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end }}
