#!/bin/bash
#
# Setup Windows 11 Golden Image for Self-Validation
#
# This script creates a Windows 11 golden image using the windows-efi-installer
# Tekton pipeline. The image is used for Windows storage tests.
#
# Prerequisites:
# - Tekton pipelines installed
# - windows-efi-installer pipeline available
# - ACCEPT_WINDOWS_EULA=true (user must explicitly accept Microsoft EULA)
#

set -e

SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
NAMESPACE="${POD_NAMESPACE:-openshift-cnv}"
GOLDEN_IMAGE_NAME="windows11-golden-image"
CONFIGMAP_NAME="windows11-autounattend"

echo "=== Windows Golden Image Setup ==="

# Step 1: Check if EULA is accepted
if [ "${ACCEPT_WINDOWS_EULA}" != "true" ]; then
  echo "ACCEPT_WINDOWS_EULA is not set to 'true'"
  echo "Skipping Windows golden image setup"
  echo "To enable Windows tests, set ACCEPT_WINDOWS_EULA=true"
  exit 0
fi

echo "Microsoft EULA accepted by user"

# Step 2: Check if golden image DataSource already exists
echo "Checking if Windows golden image already exists..."
if oc get datasource ${GOLDEN_IMAGE_NAME} -n ${NAMESPACE} &>/dev/null; then
  echo "Windows golden image DataSource already exists in ${NAMESPACE}"
  echo "Skipping image creation"
  exit 0
fi

# Also check if the DataVolume exists
if oc get dv ${GOLDEN_IMAGE_NAME} -n ${NAMESPACE} &>/dev/null; then
  DV_PHASE=$(oc get dv ${GOLDEN_IMAGE_NAME} -n ${NAMESPACE} -o jsonpath='{.status.phase}')
  if [ "${DV_PHASE}" == "Succeeded" ]; then
    echo "Windows golden image DataVolume already exists and succeeded"
    exit 0
  fi
  echo "Found existing DataVolume in phase: ${DV_PHASE}"
fi

# Step 3: Check if Tekton pipeline exists
echo "Checking for windows-efi-installer pipeline..."
if ! oc get pipeline windows-efi-installer -n ${NAMESPACE} &>/dev/null; then
  echo "ERROR: windows-efi-installer pipeline not found in ${NAMESPACE}"
  echo "Please install kubevirt-tekton-tasks first"
  exit 1
fi

# Step 4: Get storage class
if [ -z "${STORAGE_CLASS}" ]; then
  STORAGE_CLASS=$(oc get sc -o json | jq -r '[.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class"=="true")][0].metadata.name')
fi

if [ -z "${STORAGE_CLASS}" ]; then
  echo "ERROR: No storage class specified and no default found"
  exit 1
fi

echo "Using storage class: ${STORAGE_CLASS}"

# Step 5: Apply our custom autounattend ConfigMap
echo "Applying Windows autounattend ConfigMap..."
oc apply -n ${NAMESPACE} -f "${SCRIPT_DIR}/windows11-autounattend.yaml"

# Step 6: Create and run the pipeline
echo "Creating Windows golden image pipeline run..."

PIPELINE_RUN_NAME=$(oc create -n ${NAMESPACE} -f - <<EOF | grep -oP 'pipelinerun.tekton.dev/\K[^ ]+'
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  generateName: windows11-golden-
  labels:
    app: self-validation
spec:
  pipelineRef:
    name: windows-efi-installer
  params:
    - name: winImageDownloadURL
      value: "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENT_CONSUMER_x64FRE_en-us.iso"
    - name: acceptEula
      value: "true"
    - name: baseDvName
      value: "${GOLDEN_IMAGE_NAME}"
    - name: baseDvNamespace
      value: "${NAMESPACE}"
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
EOF
)

echo "Created PipelineRun: ${PIPELINE_RUN_NAME}"

# Step 7: Wait for pipeline to complete (with timeout)
echo "Waiting for Windows installation to complete..."
echo "This may take 60-90 minutes for first-time setup"

TIMEOUT_SECONDS=7200  # 2 hours
POLL_INTERVAL=60
ELAPSED=0

while [ ${ELAPSED} -lt ${TIMEOUT_SECONDS} ]; do
  STATUS=$(oc get pipelinerun ${PIPELINE_RUN_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Unknown")
  
  case "${STATUS}" in
    "Succeeded")
      echo "Pipeline completed successfully!"
      echo "Windows golden image is ready: ${GOLDEN_IMAGE_NAME}"
      exit 0
      ;;
    "Failed"|"PipelineRunTimeout"|"TaskRunCancelled")
      echo "ERROR: Pipeline failed with status: ${STATUS}"
      oc get pipelinerun ${PIPELINE_RUN_NAME} -n ${NAMESPACE} -o yaml | tail -50
      exit 1
      ;;
    *)
      # Still running, show progress
      CURRENT_TASK=$(oc get pipelinerun ${PIPELINE_RUN_NAME} -n ${NAMESPACE} -o jsonpath='{.status.childReferences[-1].name}' 2>/dev/null || echo "starting")
      echo "[${ELAPSED}s] Status: ${STATUS}, Current: ${CURRENT_TASK}"
      ;;
  esac
  
  sleep ${POLL_INTERVAL}
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo "ERROR: Timeout waiting for Windows installation"
exit 1
