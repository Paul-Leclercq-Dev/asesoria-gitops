{{/* Étiquettes communes. Usage : include "acrm.labels" (dict "root" $ "component" "api") */}}
{{- define "acrm.labels" -}}
app.kubernetes.io/name: acrm
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/part-of: expedita
app.kubernetes.io/version: {{ .root.Values.image.tag | default .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{/* Sélecteur stable (ne change jamais : un Deployment ne peut pas changer de sélecteur). */}}
{{- define "acrm.selector" -}}
app.kubernetes.io/name: acrm
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Image d'un composant publiée sur GHCR. Usage : include "acrm.image" (dict "root" $ "name" "acrm-api")
Avec une empreinte (image.digests.<nom>, écrite par la PR de version de release.yml) :
  ghcr.io/…/acrm-api:0.3.0@sha256:…  → Kubernetes tire l'image PAR L'EMPREINTE (le tag
  n'est plus qu'une étiquette lisible) : même si quelqu'un déplaçait le tag sur GHCR,
  le cluster continuerait d'exécuter exactement l'image scannée et signée.
*/}}
{{- define "acrm.image" -}}
{{- $tag := .root.Values.image.tag | default .root.Chart.AppVersion -}}
{{- $digest := index (.root.Values.image.digests | default dict) .name | default "" -}}
{{- if $digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) -}}
{{- fail (printf "image.digests.%s invalide (attendu sha256:<64 hex>) : %s" .name $digest) -}}
{{- end -}}
{{ printf "%s/%s:%s@%s" .root.Values.image.registry .name $tag $digest }}
{{- else -}}
{{ printf "%s/%s:%s" .root.Values.image.registry .name $tag }}
{{- end }}
{{- end }}

{{- define "acrm.tlsSecret" -}}
{{- .Values.tls.secretName | default (printf "%s-tls" (.Values.host | replace "." "-")) -}}
{{- end }}

{{- define "acrm.dbHost" -}}
{{- printf "%s-rw" .Values.postgres.clusterName -}}
{{- end }}

{{/* Pod : non-root, profil seccomp par défaut, pas de jeton d'API Kubernetes (inutile ici). */}}
{{- define "acrm.podSecurity" -}}
automountServiceAccountToken: false
securityContext:
  runAsNonRoot: true
  seccompProfile: { type: RuntimeDefault }
{{- with .root.Values.image.pullSecret }}
imagePullSecrets:
  - name: {{ . }}
{{- end }}
{{- end }}

{{/* Conteneur durci. uid explicite : Kubernetes ne peut pas vérifier « non-root » avec un USER nommé (node). */}}
{{- define "acrm.containerSecurity" -}}
securityContext:
  runAsUser: {{ .uid }}
  runAsGroup: {{ .uid }}
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: {{ if eq (toString .readOnly) "false" }}false{{ else }}true{{ end }}
  capabilities: { drop: [ALL] }
{{- end }}

{{/*
Connexion PostgreSQL d'un rôle, à mettre en tête de « env ». Kubernetes remplace
$(DB_PASSWORD) par la variable définie juste avant : le mot de passe reste dans le
Secret, jamais dans le manifeste. Mots de passe générés en hexadécimal (sûrs dans une URL).
Usage : include "acrm.dbEnv" (dict "root" $ "secret" .Values.secrets.dbApp "user" "acrm_app" "var" "DATABASE_URL")
*/}}
{{- define "acrm.dbEnv" -}}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef: { name: {{ .secret }}, key: password }
- name: {{ .var }}
  value: {{ printf "postgresql://%s:$(DB_PASSWORD)@%s:5432/%s" .user (include "acrm.dbHost" .root) .root.Values.postgres.database | quote }}
{{- end }}

{{- define "acrm.redisEnv" -}}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef: { name: {{ .Values.secrets.redis }}, key: password }
- name: REDIS_URL
  value: {{ printf "redis://:$(REDIS_PASSWORD)@%s-redis:6379" .Release.Name | quote }}
{{- end }}

{{/* Variables communes API + worker : ConfigMap + clés S3. */}}
{{- define "acrm.envFrom" -}}
envFrom:
  - configMapRef: { name: {{ .Release.Name }}-config }
  - secretRef: { name: {{ .Values.secrets.s3 }} }
{{- end }}

{{- define "acrm.tmpVolume" -}}
- name: tmp
  emptyDir: { sizeLimit: 64Mi }
{{- end }}
