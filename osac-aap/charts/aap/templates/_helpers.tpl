{{/*
Expand the name of the chart.
*/}}
{{- define "osac-aap.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "osac-aap.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "osac-aap.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "osac-aap.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
AAP instance name
*/}}
{{- define "osac-aap.instanceName" -}}
{{- .Values.aap.instance.name }}
{{- end }}

{{/*
AAP gateway hostname (service name)
*/}}
{{- define "osac-aap.gatewayHostname" -}}
{{- include "osac-aap.instanceName" . }}
{{- end }}

{{/*
AAP EDA hostname
*/}}
{{- define "osac-aap.edaHostname" -}}
{{- printf "%s-eda-api" (include "osac-aap.instanceName" .) }}
{{- end }}

{{/*
AAP controller hostname
*/}}
{{- define "osac-aap.controllerHostname" -}}
{{- printf "%s-controller-service" (include "osac-aap.instanceName" .) }}
{{- end }}

{{/*
Shared wait-for-aap readiness script (bootstrap-job.yaml, create-api-token.yaml).
Wall-clock-bounded (1500s epoch deadline, not iteration count) since each
iteration can take up to ~65s worst case -- keep activeDeadlineSeconds above this.
*/}}
{{- define "osac-aap.waitForAapScript" -}}
echo "Checking AAP controller and gateway readiness..."

# A threshold < 1 would satisfy the streak check immediately, reintroducing the race.
case "${AAP_READINESS_CONSECUTIVE_SUCCESSES}" in
  ''|*[!0-9]*)
    echo "ERROR: AAP_READINESS_CONSECUTIVE_SUCCESSES must be a positive integer, got '${AAP_READINESS_CONSECUTIVE_SUCCESSES}'"
    exit 1
    ;;
esac
if [ "${AAP_READINESS_CONSECUTIVE_SUCCESSES}" -lt 1 ]; then
  echo "ERROR: AAP_READINESS_CONSECUTIVE_SUCCESSES must be >= 1, got '${AAP_READINESS_CONSECUTIVE_SUCCESSES}'"
  exit 1
fi

echo "Waiting for AAP to be ready (${AAP_READINESS_CONSECUTIVE_SUCCESSES} consecutive successful checks required)..."

# netrc avoids leaking the password via curl -u's process args; cleaned up via
# trap since /tmp is a shared emptyDir mounted by later containers too.
trap 'rm -f /tmp/.netrc' EXIT
( umask 077; printf 'machine %s\nlogin admin\npassword %s\n' "${AAP_GATEWAY_HOSTNAME}" "${AAP_PASSWORD}" > /tmp/.netrc )

POLL_INTERVAL=5
AUTH_FAILURE_LIMIT=5
consecutive_successes=0
auth_failures=0
READINESS_DEADLINE=$(( $(date +%s) + 1500 ))
i=0
while [ "$(date +%s)" -lt "${READINESS_DEADLINE}" ]; do
  i=$((i + 1))
  curl -sf --connect-timeout 5 --max-time 15 \
    "http://${AAP_CONTROLLER_GATEWAY_HOSTNAME}/api/v2/ping/" \
    | grep -q 'version'
  controller_ping="${?}"

  if [ "${controller_ping}" -ne 0 ]; then
    consecutive_successes=0
    echo "Attempt $i: controller_ping=fail gateway_ping=skipped auth=skipped delete=skipped streak: ${consecutive_successes}/${AAP_READINESS_CONSECUTIVE_SUCCESSES}"
    echo "AAP is not ready, waiting ${POLL_INTERVAL} seconds..."
    sleep "${POLL_INTERVAL}"
    continue
  fi

  curl -sf --connect-timeout 5 --max-time 15 \
    "http://${AAP_GATEWAY_HOSTNAME}/api/gateway/v1/ping/" \
    | grep -q 'good'
  gateway_ping="${?}"

  if [ "${gateway_ping}" -ne 0 ]; then
    consecutive_successes=0
    echo "Attempt $i: controller_ping=ok gateway_ping=fail auth=skipped delete=skipped streak: ${consecutive_successes}/${AAP_READINESS_CONSECUTIVE_SUCCESSES}"
    echo "AAP is not ready, waiting ${POLL_INTERVAL} seconds..."
    sleep "${POLL_INTERVAL}"
    continue
  fi

  response=$(curl -s --connect-timeout 5 --max-time 15 -w '\n%{http_code}' -X POST \
    --netrc-file /tmp/.netrc \
    "http://${AAP_GATEWAY_HOSTNAME}/api/gateway/v1/tokens/" \
    -H "Content-Type: application/json" -d '{"description": "readiness-check", "scope": "read"}')
  auth_code=$(echo "${response}" | tail -1)

  if [ "${auth_code}" = "200" ] || [ "${auth_code}" = "201" ]; then
    auth_failures=0
    auth_body=$(echo "${response}" | sed '$d')
    token_id=$(echo "${auth_body}" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)

    if [ -z "${token_id}" ]; then
      consecutive_successes=0
      delete_code="skipped"
      # Not logging auth_body: it may contain the live token value.
      echo "WARNING: readiness-check token created but its ID could not be parsed from the response"
    else
      delete_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 \
        -X DELETE --netrc-file /tmp/.netrc \
        "http://${AAP_GATEWAY_HOSTNAME}/api/gateway/v1/tokens/${token_id}/")
      case "${delete_code}" in
        2??)
          consecutive_successes=$((consecutive_successes + 1))
          ;;
        *)
          consecutive_successes=0
          echo "WARNING: readiness-check token cleanup failed (delete_code='${delete_code}')"
          ;;
      esac
    fi
    echo "Attempt $i: controller_ping=ok gateway_ping=ok auth=${auth_code} delete=${delete_code} streak: ${consecutive_successes}/${AAP_READINESS_CONSECUTIVE_SUCCESSES}"
  else
    consecutive_successes=0
    if [ "${auth_code}" = "401" ] || [ "${auth_code}" = "403" ]; then
      auth_failures=$((auth_failures + 1))
      echo "WARNING: AAP authentication rejected (HTTP ${auth_code}), consecutive auth failures: ${auth_failures}/${AUTH_FAILURE_LIMIT}"
      if [ "${auth_failures}" -ge "${AUTH_FAILURE_LIMIT}" ]; then
        echo "ERROR: AAP authentication is failing repeatedly -- check AAP_PASSWORD/admin credentials"
        exit 1
      fi
    else
      auth_failures=0
    fi
    echo "Attempt $i: controller_ping=ok gateway_ping=ok auth=${auth_code} delete=skipped streak: ${consecutive_successes}/${AAP_READINESS_CONSECUTIVE_SUCCESSES}"
  fi

  if [ "${consecutive_successes}" -ge "${AAP_READINESS_CONSECUTIVE_SUCCESSES}" ]; then
    echo "AAP is ready!"
    exit 0
  fi

  echo "AAP is not ready, waiting ${POLL_INTERVAL} seconds..."
  sleep "${POLL_INTERVAL}"
done
echo "Timeout waiting for AAP."
exit 1
{{- end }}

{{/*
Polls for the AAP admin-password Secret before wait-for-aap mounts it via
secretKeyRef -- otherwise a missing Secret at pod-schedule time blocks the
whole pod in Init:CreateContainerConfigError with no log output.
*/}}
{{- define "osac-aap.waitForAdminSecretScript" -}}
echo "Waiting for AAP admin password Secret to be created by the operator..."
for i in {1..60}; do
  if oc get secret "${AAP_ADMIN_SECRET_NAME}" -n "${NAMESPACE}" --request-timeout=10s >/dev/null 2>&1; then
    echo "Found admin password Secret."
    exit 0
  fi
  echo "Attempt $i: admin password Secret not found yet, waiting 5 seconds..."
  sleep 5
done
echo "ERROR: Timed out waiting for admin password Secret to be created."
exit 1
{{- end }}

{{/* Shared wait-for-aap init container env/volumeMounts/resources/securityContext. */}}
{{- define "osac-aap.waitForAapContainerSpec" -}}
env:
- name: HOME
  value: /tmp
- name: AAP_GATEWAY_HOSTNAME
  value: {{ include "osac-aap.gatewayHostname" . | quote }}
- name: AAP_CONTROLLER_GATEWAY_HOSTNAME
  value: {{ include "osac-aap.controllerHostname" . | quote }}
- name: AAP_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "osac-aap.instanceName" . }}-admin-password
      key: password
- name: AAP_READINESS_CONSECUTIVE_SUCCESSES
  value: {{ .Values.bootstrap.readinessConsecutiveSuccesses | quote }}
volumeMounts:
- name: tmp
  mountPath: /tmp
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  capabilities:
    drop: ["ALL"]
{{- end }}

{{/* Shared wait-for-admin-secret init container env/volumeMounts/resources/securityContext. */}}
{{- define "osac-aap.waitForAdminSecretContainerSpec" -}}
env:
- name: HOME
  value: /tmp
- name: NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: AAP_ADMIN_SECRET_NAME
  value: {{ printf "%s-admin-password" (include "osac-aap.instanceName" .) | quote }}
volumeMounts:
- name: tmp
  mountPath: /tmp
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  capabilities:
    drop: ["ALL"]
{{- end }}

{{/*
Name of the ConfigMap recording the fingerprint of the inputs applied by the
last successful bootstrap run.
*/}}
{{- define "osac-aap.bootstrapStateName" -}}
{{- printf "%s-bootstrap-state" (include "osac-aap.fullname" .) }}
{{- end }}

{{/*
Fingerprint of everything the config-as-code playbook reads, except the project
content, which is only known at run time (see bootstrapIdentityScript): the
rendered templates that become the config-as-code secrets and the instance
groups, plus the images the run uses. Bump algorithm= whenever the inputs or the
way they are folded in change, so existing markers stop matching.
*/}}
{{- define "osac-aap.bootstrapInputsHash" -}}
{{- $config := printf "%s\n---\n%s\n---\n%s"
  (include (print $.Template.BasePath "/config-as-code-secret.yaml") .)
  (include (print $.Template.BasePath "/config-as-code-manifest.yaml") .)
  (include (print $.Template.BasePath "/instance-groups.yaml") .) -}}
{{- $images := printf "algorithm=v1\nbootstrap=%s\nee=%s\neePull=%s"
  .Values.bootstrap.image
  (.Values.configAsCode.eeImage | default "")
  (.Values.configAsCode.eeImagePull | default "") -}}
{{- printf "%s\n---\n%s" $config $images | sha256sum -}}
{{- end }}

{{/*
Fingerprints the bootstrap inputs before the playbook runs and decides whether
the run can be skipped. Writes the fingerprint to /state/identity for the
bootstrap container, and /state/skip when the playbook can be skipped.
*/}}
{{- define "osac-aap.bootstrapIdentityScript" -}}
set -eu
if [ -n "${AAP_PROJECT_ARCHIVE_URI}" ]; then
  echo "Fingerprinting the project archive ${AAP_PROJECT_ARCHIVE_URI}"
  project="archive:$(curl -fsS --max-time 300 "${AAP_PROJECT_ARCHIVE_URI}" | sha256sum | cut -d' ' -f1)"
else
  # A git ref can move without any chart change, and this image carries no git
  # client to resolve it, so a git project can never be proven unchanged.
  echo "Project is a git ref, which cannot be fingerprinted: always running."
  project="git:${AAP_PROJECT_GIT_URI:-default}:${AAP_PROJECT_GIT_BRANCH:-default}:$(date +%s%N)"
fi
identity=$(printf '%s\n%s\n' "{{ include "osac-aap.bootstrapInputsHash" . }}" "${project}" | sha256sum | cut -d' ' -f1)
printf '%s' "${identity}" > /state/identity
echo "Bootstrap identity ${identity}"
if [ "${BOOTSTRAP_SKIP_WHEN_UNCHANGED}" != "true" ]; then
  echo "bootstrap.skipWhenUnchanged is off: running."
  exit 0
fi
marker=""
if [ -r /marker/identity ]; then
  marker=$(cat /marker/identity)
fi
if [ -n "${marker}" ] && [ "${marker}" = "${identity}" ]; then
  echo "Inputs unchanged since the last successful run ${marker}: skipping."
  : > /state/skip
  exit 0
fi
echo "Inputs changed since the last successful run ${marker:-none}: running."
{{- end }}

{{/*
Bootstrap container entrypoint: honour the skip decision, run the playbook and
record the fingerprint of what was applied. Recording after the playbook is what
makes the next identical upgrade skippable.
*/}}
{{- define "osac-aap.bootstrapRunScript" -}}
set -eu
if [ -f /state/skip ]; then
  echo "Bootstrap inputs unchanged: nothing to apply."
  exit 0
fi
ansible-playbook osac.config_as_code.subscription osac.config_as_code.configure
identity=$(cat /state/identity)
echo "Recording bootstrap identity ${identity}"
oc -n "${NAMESPACE}" patch configmap {{ include "osac-aap.bootstrapStateName" . }} \
  --type=merge -p "{\"data\":{\"identity\":\"${identity}\"}}" ||
  echo "WARNING: could not record the bootstrap identity; the next upgrade reruns."
{{- end }}

{{/* Shared bootstrap-state init container env/volumeMounts/resources/securityContext. */}}
{{- define "osac-aap.bootstrapStateContainerSpec" -}}
env:
- name: HOME
  value: /tmp
- name: AAP_PROJECT_ARCHIVE_URI
  value: {{ .Values.configAsCode.projectArchiveUri | default "" | quote }}
- name: AAP_PROJECT_GIT_URI
  value: {{ .Values.configAsCode.projectGitUri | default "" | quote }}
- name: AAP_PROJECT_GIT_BRANCH
  value: {{ .Values.configAsCode.projectGitBranch | default "" | quote }}
- name: BOOTSTRAP_SKIP_WHEN_UNCHANGED
  value: {{ .Values.bootstrap.skipWhenUnchanged | quote }}
volumeMounts:
- name: tmp
  mountPath: /tmp
- name: bootstrap-state
  mountPath: /state
- name: bootstrap-state-marker
  mountPath: /marker
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  capabilities:
    drop: ["ALL"]
{{- end }}
