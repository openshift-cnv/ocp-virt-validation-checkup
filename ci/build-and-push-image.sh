#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Build and push image to OpenShift internal registry
LOCAL_IMAGE="${LOCAL_IMAGE:-localhost/ocp-virt-validation-checkup:test}"

echo "=== Building validation checkup image ==="
podman build --no-cache -f "${REPO_ROOT}/ci/Dockerfile.ci" -t "${LOCAL_IMAGE}" "${REPO_ROOT}"

# Create namespace for image registry project
echo "=== Creating ocp-virt-validation namespace ==="
oc create namespace ocp-virt-validation || true

# Push to OpenShift internal registry
echo "=== Pushing image to OpenShift internal registry ==="

# Enable default route for image registry if not already enabled
echo "=== Enabling registry default route ==="
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"defaultRoute":true}}'

# Wait a moment for route to be created
sleep 2

# Get external registry route for pushing
EXTERNAL_REGISTRY=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
EXTERNAL_REGISTRY_IMAGE="${EXTERNAL_REGISTRY}/ocp-virt-validation/ocp-virt-validation-checkup:test"

# Set internal registry image for the job (will be used after push)
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
INTERNAL_REGISTRY_IMAGE="${INTERNAL_REGISTRY}/ocp-virt-validation/ocp-virt-validation-checkup:test"

# Tag and push image to registry
echo "=== Tagging and pushing image to registry ==="
podman tag "${LOCAL_IMAGE}" "${EXTERNAL_REGISTRY_IMAGE}"

# Get token and login to registry
echo "=== Logging in to registry at ${EXTERNAL_REGISTRY} ==="
REGISTRY_TOKEN=$(oc create token builder -n ocp-virt-validation --duration=1h)
echo "${REGISTRY_TOKEN}" | podman login -u admin --password-stdin --tls-verify=false "${EXTERNAL_REGISTRY}"

podman push --tls-verify=false "${EXTERNAL_REGISTRY_IMAGE}"

echo "=== Image pushed successfully: ${INTERNAL_REGISTRY_IMAGE} ==="

# Output the internal registry image URL (so it can be captured by the caller)
echo "${INTERNAL_REGISTRY_IMAGE}"
