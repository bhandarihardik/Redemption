{{/*
Common labels applied to every object in the chart.
*/}}
{{- define "the-redemption.labels" -}}
app.kubernetes.io/part-of: the-redemption
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Shared container spec: probes, security context, resources, lifecycle hook,
envFrom, volume mounts. Both the baseline and burst Deployments call this
same template so a probe or security-context change is made ONCE, in one
place, instead of drifting between two copy-pasted Deployment files the way
the equivalent Kustomize manifests had to.

Takes a dict with 'root' (the top-level template context, for .Values/.Chart
access) and 'resources' (the tier-specific resources block to apply).
*/}}
{{- define "the-redemption.container" -}}
- name: the-redemption
  image: "{{ .root.Values.image.repository }}:{{ .root.Values.image.tag }}"
  imagePullPolicy: {{ .root.Values.image.pullPolicy }}
  ports:
    - name: http
      containerPort: 8080
    - name: metrics
      containerPort: 9090
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
  resources:
    {{- toYaml .resources | nindent 4 }}
  startupProbe:
    httpGet:
      path: {{ .root.Values.probes.startup.path }}
      port: http
    failureThreshold: {{ .root.Values.probes.startup.failureThreshold }}
    periodSeconds: {{ .root.Values.probes.startup.periodSeconds }}
  readinessProbe:
    httpGet:
      path: {{ .root.Values.probes.readiness.path }}
      port: http
    periodSeconds: {{ .root.Values.probes.readiness.periodSeconds }}
    failureThreshold: {{ .root.Values.probes.readiness.failureThreshold }}
    timeoutSeconds: {{ .root.Values.probes.readiness.timeoutSeconds }}
  livenessProbe:
    httpGet:
      path: {{ .root.Values.probes.liveness.path }}
      port: http
    periodSeconds: {{ .root.Values.probes.liveness.periodSeconds }}
    failureThreshold: {{ .root.Values.probes.liveness.failureThreshold }}
    timeoutSeconds: {{ .root.Values.probes.liveness.timeoutSeconds }}
  lifecycle:
    preStop:
      exec:
        command: ["sh", "-c", "sleep {{ .root.Values.preStopSleepSeconds }}"]
  envFrom:
    - configMapRef:
        name: the-redemption-config
    - secretRef:
        name: the-redemption-secrets
  volumeMounts:
    - name: tmp
      mountPath: /tmp
{{- end -}}

{{/*
Shared pod-level securityContext (runAsNonRoot, fsGroup, seccomp) — same
across both tiers, Pod Security Standards "restricted" compliant.
*/}}
{{- define "the-redemption.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 10001
fsGroup: 10001
seccompProfile:
  type: RuntimeDefault
{{- end -}}
