#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKIP_MIRROR_SETUP="${SKIP_MIRROR_SETUP:-false}"
KUBEVIRT_RELEASE="${KUBEVIRT_RELEASE:-}"
PULL_SECRET="${PULL_SECRET:-}"
DRY_RUN="${DRY_RUN:-true}"
OCP_VIRT_VALIDATION_TIMEOUT="${OCP_VIRT_VALIDATION_TIMEOUT:-10m}"

cleanup() {
  rm -f "${CLUSTER_PULL_SECRET:-}" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Pre-flight checks ==="
for cmd in oc podman jq; do
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
oc delete imagetagmirrorset ocp-virt-validation-mirrors --ignore-not-found=true || true
oc delete imagedigestmirrorset ocp-virt-validation-digest-mirrors --ignore-not-found=true || true
oc delete namespace kubevirt-mirror --ignore-not-found=true --wait=true || true
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
  echo "${AUTH#*:}" | podman login -u "${AUTH%%:*}" --password-stdin "${registry}"
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
echo "${LOGIN_TOKEN}" | podman login -u unused --password-stdin "${INTERNAL_REGISTRY}" --tls-verify=false

if [ -n "${OCP_VIRT_VALIDATION_IMAGE:-}" ]; then
  echo "=== Mirroring checkup image to internal registry ==="
  echo "> Public image: ${OCP_VIRT_VALIDATION_IMAGE}"
  OCP_VIRT_VALIDATION_IMAGE=$("${SCRIPT_DIR}/mirror-checkup-image-to-internal-registry.sh" \
    "${OCP_VIRT_VALIDATION_IMAGE}" "${INTERNAL_REGISTRY}")
  echo "> Using in-cluster image: ${OCP_VIRT_VALIDATION_IMAGE}"
fi

echo "=== Running disconnected validation checkup ==="
OCP_VIRT_VALIDATION_IMAGE="${OCP_VIRT_VALIDATION_IMAGE:-}" \
DRY_RUN="${DRY_RUN}" \
OCP_VIRT_VALIDATION_TIMEOUT="${OCP_VIRT_VALIDATION_TIMEOUT}" \
  "${SCRIPT_DIR}/run-ci-validation.sh"

echo "=== Disconnected validation checkup completed successfully ==="
