#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKIP_MIRROR_SETUP="${SKIP_MIRROR_SETUP:-false}"
KUBEVIRT_RELEASE="${KUBEVIRT_RELEASE:-}"
PULL_SECRET="${PULL_SECRET:-}"
DRY_RUN="${DRY_RUN:-true}"
OCP_VIRT_VALIDATION_TIMEOUT="${OCP_VIRT_VALIDATION_TIMEOUT:-10m}"
ACCEPT_WINDOWS_EULA="${ACCEPT_WINDOWS_EULA:-false}"
CLEANUP_MIRRORS="${CLEANUP_MIRRORS:-false}"

cleanup_mirror_resources() {
  oc delete imagetagmirrorset ocp-virt-validation-mirrors --ignore-not-found=true || true
  oc delete imagedigestmirrorset ocp-virt-validation-digest-mirrors --ignore-not-found=true || true
  oc delete namespace kubevirt-mirror --ignore-not-found=true --wait=true --timeout=5m || true
}

cleanup() {
  rm -f "${CLUSTER_PULL_SECRET:-}" 2>/dev/null || true
  if [ "${CLEANUP_MIRRORS}" = "true" ]; then
    echo "=== Cleaning up mirror sets (CLEANUP_MIRRORS=true) ==="
    cleanup_mirror_resources
    echo "Waiting for MachineConfigPools to stabilize..."
    oc wait machineconfigpool --all --for=condition=Updated --timeout=30m || true
    echo "> Mirror cleanup complete"
  fi
}
trap cleanup EXIT

echo "=== Pre-flight checks ==="
for cmd in oc jq; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "Error: ${cmd} is required but not found in PATH"
    exit 1
  fi
done

if ! oc whoami &>/dev/null; then
  echo "Error: not logged in to an OpenShift cluster (oc whoami failed)"
  exit 1
fi

echo "> Pre-flight checks passed"

echo "=== Cleaning up previous runs ==="
for node in $(oc get node -o NAME); do oc debug -n default "${node}" -- chroot /host crictl rmi --prune; done || true
cleanup_mirror_resources
oc delete namespace ocp-virt-validation --ignore-not-found=true --wait=true || true
echo "Waiting for MachineConfigPools to stabilize..."
oc wait machineconfigpool --all --for=condition=Updated --timeout=30m
echo "> Cleanup complete"

echo "=== Authenticating to source registries ==="
CLUSTER_PULL_SECRET=$(mktemp)
oc get secret/pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${CLUSTER_PULL_SECRET}"

for registry in registry.redhat.io quay.io/openshift-virtualization/konflux-builds; do
  AUTH_B64=$(jq -r --arg r "${registry}" '.auths[$r].auth // empty' "${CLUSTER_PULL_SECRET}")
  if [ -z "${AUTH_B64}" ]; then
    echo "Warning: no credentials found for ${registry} in cluster pull secret, skipping" >&2
    continue
  fi
  AUTH=$(echo "${AUTH_B64}" | base64 -d)
  oc registry login --registry="${registry}" --auth-basic="${AUTH%%:*}:${AUTH#*:}"
done

if [ "${SKIP_MIRROR_SETUP}" != "true" ]; then
  echo "=== Mirroring images to internal registry and applying mirror sets ==="
  MIRROR_ARGS=(--use-internal-registry --apply-mirror-set --never-contact-source)
  [ -n "${KUBEVIRT_RELEASE}" ] && MIRROR_ARGS+=(--kubevirt-release "${KUBEVIRT_RELEASE}")
  [ -n "${PULL_SECRET}" ] && MIRROR_ARGS+=(--pull-secret "${PULL_SECRET}")
  "${REPO_ROOT}/disconnected/mirror-images.sh" "${MIRROR_ARGS[@]}"

  echo "=== Waiting for all MachineConfigPool rollouts to complete ==="
  oc wait machineconfigpool --all --for=condition=Updated --timeout=30m
  sleep 30
  oc wait machineconfigpool --all --for=condition=Updated --timeout=30m
  echo "> MachineConfigPools are stable"

  echo "=== Re-mirroring images (registry pod may have restarted during MCP update) ==="
  REMIRROR_ARGS=(--use-internal-registry)
  [ -n "${KUBEVIRT_RELEASE}" ] && REMIRROR_ARGS+=(--kubevirt-release "${KUBEVIRT_RELEASE}")
  [ -n "${PULL_SECRET}" ] && REMIRROR_ARGS+=(--pull-secret "${PULL_SECRET}")
  "${REPO_ROOT}/disconnected/mirror-images.sh" "${REMIRROR_ARGS[@]}"
else
  echo "=== Skipping mirror setup (SKIP_MIRROR_SETUP=true) ==="
fi

echo "=== Authenticating to internal registry ==="
INTERNAL_REGISTRY=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
LOGIN_TOKEN=$(oc create token registry-pusher -n kubevirt-mirror --duration=1h)
oc registry login --registry="${INTERNAL_REGISTRY}" --auth-basic="unused:${LOGIN_TOKEN}" --insecure=true

if [ -n "${OCP_VIRT_VALIDATION_IMAGE:-}" ]; then
  echo "=== Mirroring checkup image to internal registry ==="
  echo "> Public image: ${OCP_VIRT_VALIDATION_IMAGE}"
  OCP_VIRT_VALIDATION_IMAGE=$("${SCRIPT_DIR}/mirror-checkup-image-to-internal-registry.sh" \
    "${OCP_VIRT_VALIDATION_IMAGE}" "${INTERNAL_REGISTRY}")
  echo "> Using in-cluster image: ${OCP_VIRT_VALIDATION_IMAGE}"
fi

if [ "${ACCEPT_WINDOWS_EULA}" = "true" ]; then
  echo "=== Preparing disconnected Windows test ==="
  GOLDEN_IMAGE_NAMESPACE="${GOLDEN_IMAGE_NAMESPACE:-validation-os-images}"

  # Pre-create the namespace so resources are ready before the Tekton pipeline
  # launches inside the checkup pod. setup-golden-image.sh reuses it when
  # it finds the app=ocp-virt-validation label.
  if ! oc get namespace "${GOLDEN_IMAGE_NAMESPACE}" &>/dev/null; then
    oc create namespace "${GOLDEN_IMAGE_NAMESPACE}"
    oc label namespace "${GOLDEN_IMAGE_NAMESPACE}" \
      app=ocp-virt-validation \
      pod-security.kubernetes.io/enforce=privileged \
      --overwrite
  fi

  echo "=== Mirroring Windows ISO to internal cluster server ==="
  WIN_IMAGE_DOWNLOAD_URL=$(GOLDEN_IMAGE_NAMESPACE="${GOLDEN_IMAGE_NAMESPACE}" \
    "${SCRIPT_DIR}/setup-windows-iso-mirror.sh")
  export WIN_IMAGE_DOWNLOAD_URL
  echo "> Windows ISO URL: ${WIN_IMAGE_DOWNLOAD_URL}"

  echo "=== Blocking Microsoft Update egress for disconnected Windows test ==="
  oc apply -n "${GOLDEN_IMAGE_NAMESPACE}" -f - <<'EFEOF'
apiVersion: k8s.ovn.org/v1
kind: EgressFirewall
metadata:
  name: default
  labels:
    app: ocp-virt-validation
spec:
  egress:
  - type: Deny
    to:
      dnsName: software-static.download.prss.microsoft.com
  - type: Deny
    to:
      dnsName: windowsupdate.microsoft.com
  - type: Deny
    to:
      dnsName: download.windowsupdate.com
  - type: Deny
    to:
      dnsName: update.microsoft.com
  - type: Deny
    to:
      dnsName: fe2cr.update.microsoft.com
  - type: Deny
    to:
      dnsName: sls.update.microsoft.com
  - type: Deny
    to:
      dnsName: github.com
  - type: Deny
    to:
      dnsName: objects.githubusercontent.com
  - type: Allow
    to:
      cidrSelector: 0.0.0.0/0
EFEOF

  echo "> EgressFirewall applied to namespace ${GOLDEN_IMAGE_NAMESPACE}"
fi

echo "=== Running disconnected validation checkup ==="
OCP_VIRT_VALIDATION_IMAGE="${OCP_VIRT_VALIDATION_IMAGE:-}" \
DRY_RUN="${DRY_RUN}" \
OCP_VIRT_VALIDATION_TIMEOUT="${OCP_VIRT_VALIDATION_TIMEOUT}" \
ACCEPT_WINDOWS_EULA="${ACCEPT_WINDOWS_EULA}" \
  "${SCRIPT_DIR}/run-ci-validation.sh"

echo "=== Disconnected validation checkup completed successfully ==="
