#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Cleaning ocp-virt-validation namespace ==="
oc delete namespace ocp-virt-validation || true

# Build and push image only if OCP_VIRT_VALIDATION_IMAGE is not defined
if [ -z "${OCP_VIRT_VALIDATION_IMAGE:-}" ]; then
  echo "=== OCP_VIRT_VALIDATION_IMAGE not defined, building and pushing image ==="
  OCP_VIRT_VALIDATION_IMAGE=$("${SCRIPT_DIR}/build-and-push-image.sh" | tail -n 1)
  export OCP_VIRT_VALIDATION_IMAGE
else
  echo "=== Using provided image: ${OCP_VIRT_VALIDATION_IMAGE} ==="
fi

# Set environment variables with defaults
DRY_RUN="${DRY_RUN:-true}"
OCP_VIRT_VALIDATION_TIMEOUT="${OCP_VIRT_VALIDATION_TIMEOUT:-10m}"

echo "=== Generating and applying validation checkup manifests ==="
DRY_RUN="${DRY_RUN}" \
OCP_VIRT_VALIDATION_IMAGE="${OCP_VIRT_VALIDATION_IMAGE}" \
  ${REPO_ROOT}/manifests/run/generate.sh | oc apply -f -

echo "=== Waiting for job to complete (timeout: ${OCP_VIRT_VALIDATION_TIMEOUT}) ==="
if ! oc wait --for=condition=complete --timeout="${OCP_VIRT_VALIDATION_TIMEOUT}" job -n ocp-virt-validation -l app=ocp-virt-validation; then
  echo "Error: Job did not complete within ${OCP_VIRT_VALIDATION_TIMEOUT}"
  echo "Job status:"
  oc get job -n ocp-virt-validation -l app=ocp-virt-validation
  echo ""
  echo "Pod logs:"
  oc logs -n ocp-virt-validation -l app=ocp-virt-validation --tail=50
  exit 1
fi

echo "=== Verifying job completed successfully ==="
JOB_STATUS=$(oc get job -n ocp-virt-validation -l app=ocp-virt-validation -o jsonpath='{.items[0].status.conditions[?(@.type=="Complete")].status}')
if [ "${JOB_STATUS}" != "True" ]; then
  echo "Error: Job did not complete successfully"
  echo "Job status:"
  oc get job -n ocp-virt-validation -l app=ocp-virt-validation -o yaml
  exit 1
fi

echo "=== Verifying pod completed successfully ==="
POD_STATUS=$(oc get pod -n ocp-virt-validation -l app=ocp-virt-validation -o jsonpath='{.items[0].status.phase}')
if [ "${POD_STATUS}" != "Succeeded" ]; then
  echo "Error: Pod did not complete successfully. Current status: ${POD_STATUS}"
  echo "Pod details:"
  oc describe pod -n ocp-virt-validation -l app=ocp-virt-validation
  echo ""
  echo "Pod logs:"
  oc logs -n ocp-virt-validation -l app=ocp-virt-validation --tail=100
  exit 1
fi

echo "> Job and pod completed successfully"

echo "=== Getting timestamp from job ==="
TIMESTAMP=$(oc -n ocp-virt-validation get job --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].spec.template.spec.containers[?(@.name=="ocp-virt-validation-checkup")].env[?(@.name=="TIMESTAMP")].value}')
echo "> Timestamp: ${TIMESTAMP}"

if [ -z "${TIMESTAMP}" ]; then
  echo "Error: TIMESTAMP is empty, cannot verify results"
  exit 1
fi

echo "=== Verifying configMap results ==="
"${SCRIPT_DIR}/verify-configmap.sh" "ocp-virt-validation-${TIMESTAMP}"

echo "=== Downloading result artifacts ==="
TIMESTAMP="${TIMESTAMP}" "${SCRIPT_DIR}/download-results.sh"

echo "=== Verifying result artifacts ==="
"${SCRIPT_DIR}/verify-results.sh" "${REPO_ROOT}/_out"

echo "=== Validation checkup completed successfully ==="
