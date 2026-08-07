#!/bin/bash
#
# Mirror the Windows Server 2022 ISO to an in-cluster HTTP server.
#
# Downloads the ISO into a PVC and serves it via nginx so the
# windows-efi-installer Tekton pipeline can fetch it without reaching
# software-static.download.prss.microsoft.com.
#
# Prints the ISO HTTP URL on stdout. All other output goes to stderr.
# Idempotent: if the server is already running, returns the URL immediately.
#
# Caller must export WIN_IMAGE_DOWNLOAD_URL with the returned URL before
# running run-ci-validation.sh, and add software-static.download.prss.microsoft.com
# to the EgressFirewall block list.
#
# Environment:
#   GOLDEN_IMAGE_NAMESPACE   namespace for all resources (default: validation-os-images)
#   WIN_IMAGE_DOWNLOAD_URL   source ISO URL (default: Microsoft Server 2022 eval)
#   STORAGE_CLASS            storage class for the PVC (default: cluster default)

set -euo pipefail

NAMESPACE="${GOLDEN_IMAGE_NAMESPACE:-validation-os-images}"
DEFAULT_ISO_URL="https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso"
SOURCE_ISO_URL="${WIN_IMAGE_DOWNLOAD_URL:-${DEFAULT_ISO_URL}}"
ISO_FILENAME="windows-server-2022.iso"
ISO_PVC="windows-iso-cache"
ISO_SERVER="windows-iso-server"
STORAGE_CLASS="${STORAGE_CLASS:-}"
PVC_SIZE="8Gi"
DOWNLOADER_IMAGE="registry.redhat.io/ubi9/ubi-minimal:latest"
NGINX_IMAGE="registry.redhat.io/rhel9/nginx-124:latest"

err() { echo "$*" >&2; }

# Idempotent: return immediately if server already running with ISO present
EXISTING_ROUTE=$(oc get route "${ISO_SERVER}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -n "${EXISTING_ROUTE}" ]; then
  PVC_PHASE=$(oc get pvc "${ISO_PVC}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "${PVC_PHASE}" = "Bound" ]; then
    err "> ISO server already running at http://${EXISTING_ROUTE}/${ISO_FILENAME}"
    echo "http://${EXISTING_ROUTE}/${ISO_FILENAME}"
    exit 0
  fi
fi

err "=== Creating ISO cache PVC (${PVC_SIZE}) ==="
SC_LINE=""
[ -n "${STORAGE_CLASS}" ] && SC_LINE="storageClassName: ${STORAGE_CLASS}"
oc apply -n "${NAMESPACE}" -f - >&2 <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${ISO_PVC}
  labels:
    app: ocp-virt-validation
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${PVC_SIZE}
  ${SC_LINE}
EOF

err "=== Downloading ISO into cluster PVC (this may take a while) ==="
oc delete job windows-iso-downloader -n "${NAMESPACE}" --ignore-not-found=true --wait=true >&2

oc create -n "${NAMESPACE}" -f - >&2 <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: windows-iso-downloader
  labels:
    app: ocp-virt-validation
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: ocp-virt-validation
    spec:
      restartPolicy: OnFailure
      securityContext:
        runAsUser: 1001
        runAsGroup: 1001
        fsGroup: 1001
      containers:
      - name: downloader
        image: ${DOWNLOADER_IMAGE}
        command: ["/bin/bash", "-c"]
        args:
          - |
            set -e
            if [ -f "/data/${ISO_FILENAME}" ]; then
              echo "ISO already present, skipping download"
              exit 0
            fi
            echo "Downloading from ${SOURCE_ISO_URL}..."
            curl -L --retry 3 --retry-delay 10 --progress-bar \
              -o "/data/${ISO_FILENAME}.tmp" "${SOURCE_ISO_URL}"
            mv "/data/${ISO_FILENAME}.tmp" "/data/${ISO_FILENAME}"
            echo "Download complete: \$(du -sh /data/${ISO_FILENAME})"
        volumeMounts:
        - name: iso-data
          mountPath: /data
        resources:
          requests:
            cpu: 200m
            memory: 256Mi
      volumes:
      - name: iso-data
        persistentVolumeClaim:
          claimName: ${ISO_PVC}
EOF

err "Waiting for ISO download to complete (timeout: 3h)..."
oc wait job/windows-iso-downloader -n "${NAMESPACE}" \
  --for=condition=complete --timeout=3h >&2

err "=== Deploying ISO HTTP server ==="
oc apply -n "${NAMESPACE}" -f - >&2 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${ISO_SERVER}
  labels:
    app: ocp-virt-validation
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${ISO_SERVER}
  template:
    metadata:
      labels:
        app: ${ISO_SERVER}
        app.kubernetes.io/part-of: ocp-virt-validation
    spec:
      containers:
      - name: nginx
        image: ${NGINX_IMAGE}
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: iso-data
          mountPath: /opt/app-root/src
          readOnly: true
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
      volumes:
      - name: iso-data
        persistentVolumeClaim:
          claimName: ${ISO_PVC}
          readOnly: true
---
apiVersion: v1
kind: Service
metadata:
  name: ${ISO_SERVER}
  labels:
    app: ocp-virt-validation
spec:
  selector:
    app: ${ISO_SERVER}
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${ISO_SERVER}
  labels:
    app: ocp-virt-validation
spec:
  to:
    kind: Service
    name: ${ISO_SERVER}
  port:
    targetPort: 8080
EOF

err "Waiting for ISO server to be ready..."
oc rollout status deployment/${ISO_SERVER} -n "${NAMESPACE}" --timeout=5m >&2

ROUTE=$(oc get route "${ISO_SERVER}" -n "${NAMESPACE}" -o jsonpath='{.spec.host}')
err "> ISO server ready: http://${ROUTE}/${ISO_FILENAME}"
echo "http://${ROUTE}/${ISO_FILENAME}"
