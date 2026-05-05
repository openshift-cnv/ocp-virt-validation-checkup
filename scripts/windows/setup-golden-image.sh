#!/bin/bash
#
# Setup Windows 11 Golden Image for Self-Validation
#
# This script creates a Windows 11 golden image using the windows-efi-installer
# Tekton pipeline. The image is used for Windows storage tests.
#
# Prerequisites:
# - OpenShift Pipelines operator installed
# - ACCEPT_WINDOWS_EULA=true (user must explicitly accept Microsoft EULA)
#
# Optional:
# - WIN_IMAGE_DOWNLOAD_URL: Custom Windows ISO download URL
# - STORAGE_CLASS: Storage class to use (defaults to cluster default)
#

set -e

SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

# Golden images should be created in the standard OS images namespace
GOLDEN_IMAGE_NAMESPACE="openshift-virtualization-os-images"
GOLDEN_IMAGE_NAME="windows11-golden-image"
CONFIGMAP_NAME="windows11-autounattend"

# Default Windows 11 ISO URL (can be overridden via WIN_IMAGE_DOWNLOAD_URL env var)
DEFAULT_WIN_IMAGE_URL="https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENT_CONSUMER_x64FRE_en-us.iso"
WIN_IMAGE_URL="${WIN_IMAGE_DOWNLOAD_URL:-${DEFAULT_WIN_IMAGE_URL}}"

# Pipeline version for hub resolver
PIPELINE_VERSION="${TEKTON_PIPELINE_VERSION:-v4.21.0}"

echo "=== Windows Golden Image Setup ==="

# Step 1: Check if EULA is accepted
if [ "${ACCEPT_WINDOWS_EULA}" != "true" ]; then
  echo "ACCEPT_WINDOWS_EULA is not set to 'true'"
  echo "Skipping Windows golden image setup"
  echo "To enable Windows tests, set ACCEPT_WINDOWS_EULA=true"
  exit 0
fi

echo "Microsoft EULA accepted by user"

# Step 2: Check if OpenShift Pipelines is installed (check for Pipeline CRD)
echo "Checking if OpenShift Pipelines operator is installed..."
if ! oc get crd pipelines.tekton.dev &>/dev/null; then
  echo "ERROR: OpenShift Pipelines operator is not installed"
  echo ""
  echo "Please install the OpenShift Pipelines operator from OperatorHub:"
  echo "  1. Go to OperatorHub in the OpenShift Console"
  echo "  2. Search for 'Red Hat OpenShift Pipelines'"
  echo "  3. Install the operator"
  echo ""
  echo "Or install via CLI:"
  echo "  oc apply -f https://raw.githubusercontent.com/openshift/pipelines-operator/main/config/samples/subscription.yaml"
  exit 1
fi

echo "OpenShift Pipelines operator is installed"

# Step 3: Ensure the golden image namespace exists
echo "Ensuring namespace ${GOLDEN_IMAGE_NAMESPACE} exists..."
if ! oc get namespace ${GOLDEN_IMAGE_NAMESPACE} &>/dev/null; then
  echo "Creating namespace ${GOLDEN_IMAGE_NAMESPACE}..."
  oc create namespace ${GOLDEN_IMAGE_NAMESPACE}
fi

# Step 4: Check if golden image DataSource already exists
echo "Checking if Windows golden image already exists..."
if oc get datasource ${GOLDEN_IMAGE_NAME} -n ${GOLDEN_IMAGE_NAMESPACE} &>/dev/null; then
  echo "Windows golden image DataSource already exists in ${GOLDEN_IMAGE_NAMESPACE}"
  echo "Skipping image creation"
  exit 0
fi

# Also check if the DataVolume exists
if oc get dv ${GOLDEN_IMAGE_NAME} -n ${GOLDEN_IMAGE_NAMESPACE} &>/dev/null; then
  DV_PHASE=$(oc get dv ${GOLDEN_IMAGE_NAME} -n ${GOLDEN_IMAGE_NAMESPACE} -o jsonpath='{.status.phase}')
  if [ "${DV_PHASE}" == "Succeeded" ]; then
    echo "Windows golden image DataVolume already exists and succeeded"
    exit 0
  fi
  echo "Found existing DataVolume in phase: ${DV_PHASE}"
fi

# Step 5: Get storage class (should be passed from entrypoint.sh)
if [ -z "${STORAGE_CLASS}" ]; then
  STORAGE_CLASS=$(oc get sc -o json | jq -r '[.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class"=="true")][0].metadata.name')
fi

if [ -z "${STORAGE_CLASS}" ] || [ "${STORAGE_CLASS}" == "null" ]; then
  echo "ERROR: No storage class specified and no default found"
  echo "Please set STORAGE_CLASS environment variable"
  exit 1
fi

echo "Using storage class: ${STORAGE_CLASS}"
echo "Using Windows ISO URL: ${WIN_IMAGE_URL}"

# Step 6: Apply our custom autounattend ConfigMap to the golden image namespace
# NOTE: This custom ConfigMap includes the BypassNRO fix for Windows 11.
# Once kubevirt/kubevirt-tekton-tasks#845 is merged and released,
# this ConfigMap can be removed in favor of the upstream default.
echo "Applying Windows autounattend ConfigMap to ${GOLDEN_IMAGE_NAMESPACE}..."
oc apply -n ${GOLDEN_IMAGE_NAMESPACE} -f "${SCRIPT_DIR}/windows11-autounattend.yaml"

# Step 7: Create and run the pipeline using hub resolver
# The hub resolver automatically downloads the pipeline and tasks from artifacthub.io
# This eliminates the need for users to manually install kubevirt-tekton-tasks
echo "Creating Windows golden image pipeline run..."
echo "Using hub resolver to fetch pipeline from artifacthub (version: ${PIPELINE_VERSION})"
echo "Note: Hub resolver requires internet access. For offline environments, pre-install the pipeline."

PIPELINE_RUN_NAME=$(oc create -n ${GOLDEN_IMAGE_NAMESPACE} -f - <<EOF | grep -oP 'pipelinerun.tekton.dev/\K[^ ]+'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: windows11-golden-
  labels:
    app: self-validation
spec:
  pipelineRef:
    resolver: hub
    params:
      - name: catalog
        value: redhat-pipelines
      - name: type
        value: artifact
      - name: kind
        value: pipeline
      - name: name
        value: windows-efi-installer
      - name: version
        value: "${PIPELINE_VERSION}"
  params:
    - name: winImageDownloadURL
      value: "${WIN_IMAGE_URL}"
    - name: acceptEula
      value: "true"
    - name: baseDvName
      value: "${GOLDEN_IMAGE_NAME}"
    - name: baseDvNamespace
      value: "${GOLDEN_IMAGE_NAMESPACE}"
    - name: autounattendConfigMapName
      value: "${CONFIGMAP_NAME}"
    - name: instanceTypeName
      value: "u1.2xlarge"
    - name: instanceTypeKind
      value: "VirtualMachineClusterInstancetype"
    - name: preferenceName
      value: "windows.11.virtio"
    - name: preferenceKind
      value: "VirtualMachineClusterPreference"
  taskRunSpecs:
    - pipelineTaskName: modify-windows-iso-file
      podTemplate:
        securityContext:
          fsGroup: 107
          runAsUser: 107
EOF
)

echo "Created PipelineRun: ${PIPELINE_RUN_NAME}"

# Step 8: Wait for pipeline to complete (with timeout)
echo "Waiting for Windows installation to complete..."
echo "This may take 60-90 minutes for first-time setup"

TIMEOUT_SECONDS=7200  # 2 hours
POLL_INTERVAL=60
ELAPSED=0

while [ ${ELAPSED} -lt ${TIMEOUT_SECONDS} ]; do
  STATUS=$(oc get pipelinerun ${PIPELINE_RUN_NAME} -n ${GOLDEN_IMAGE_NAMESPACE} -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Unknown")
  
  case "${STATUS}" in
    "Succeeded")
      echo "Pipeline completed successfully!"
      echo "Windows golden image is ready: ${GOLDEN_IMAGE_NAME} in namespace ${GOLDEN_IMAGE_NAMESPACE}"
      exit 0
      ;;
    "Failed"|"PipelineRunTimeout"|"TaskRunCancelled"|"CouldntGetPipeline")
      echo "ERROR: Pipeline failed with status: ${STATUS}"
      echo ""
      # Check if it's a resolver error
      if [ "${STATUS}" == "CouldntGetPipeline" ]; then
        echo "Failed to fetch pipeline from artifacthub. This could mean:"
        echo "  1. No internet access (hub resolver requires network)"
        echo "  2. The pipeline version ${PIPELINE_VERSION} doesn't exist"
        echo ""
        echo "For offline environments, manually install the pipeline first:"
        echo "  https://artifacthub.io/packages/tekton-pipeline/redhat-pipelines/windows-efi-installer"
      fi
      oc get pipelinerun ${PIPELINE_RUN_NAME} -n ${GOLDEN_IMAGE_NAMESPACE} -o yaml | tail -50
      exit 1
      ;;
    *)
      # Still running, show progress
      CURRENT_TASK=$(oc get pipelinerun ${PIPELINE_RUN_NAME} -n ${GOLDEN_IMAGE_NAMESPACE} -o jsonpath='{.status.childReferences[-1].name}' 2>/dev/null || echo "starting")
      echo "[${ELAPSED}s] Status: ${STATUS}, Current: ${CURRENT_TASK}"
      ;;
  esac
  
  sleep ${POLL_INTERVAL}
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo "ERROR: Timeout waiting for Windows installation"
exit 1
