#!/bin/bash
#
# Setup Windows 11 Golden Image for Self-Validation
#
# This script creates a Windows 11 golden image using the windows-efi-installer
# Tekton pipeline, then boots the sysprepped image with an unattend.xml to
# complete OOBE automatically. The final DataSource produces VMs that boot
# directly to the desktop with no manual setup.
#
# Flow:
#   1. Pipeline installs Windows + sysprep (creates sysprepped disk)
#   2. Create a temporary DataSource from the sysprepped disk
#   3. Boot from that DataSource with unattend.xml on SATA CD-ROM (skips OOBE)
#   4. Wait for guest agent + stabilization time
#   5. Snapshot the running VM at desktop state
#   6. Create final DataSource from snapshot (this is the golden image)
#
# Prerequisites:
# - OpenShift Pipelines operator installed
# - ACCEPT_WINDOWS_EULA=true (user must explicitly accept Microsoft EULA)
# - STORAGE_CLASS set to a valid storage class
#
# Optional:
# - WIN_IMAGE_DOWNLOAD_URL: Custom Windows ISO download URL
# - WIN_IMAGE_NAME: Custom golden image DataSource name
# - WIN_INSTANCE_TYPE: Instance type (default: u1.large)
#

set -e

GOLDEN_IMAGE_NAMESPACE="openshift-virtualization-os-images"

DEFAULT_WIN_GOLDEN_IMAGE_NAME="windows11-golden-image"
GOLDEN_IMAGE_NAME="${WIN_IMAGE_NAME:-${DEFAULT_WIN_GOLDEN_IMAGE_NAME}}"

DEFAULT_WIN_IMAGE_URL="https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENT_CONSUMER_x64FRE_en-us.iso"
WIN_IMAGE_URL="${WIN_IMAGE_DOWNLOAD_URL:-${DEFAULT_WIN_IMAGE_URL}}"

PIPELINE_VERSION="${TEKTON_PIPELINE_VERSION:->=v4.21.0}"

# u1.large provides enough vCPUs for Windows 11 (4 vCPUs, 8Gi RAM)
DEFAULT_INSTANCE_TYPE="u1.large"
INSTANCE_TYPE="${WIN_INSTANCE_TYPE:-${DEFAULT_INSTANCE_TYPE}}"

# Derived names for intermediate resources
# WIN_SYSPREP_PVC allows pointing to an existing sysprepped PVC (skips pipeline)
SYSPREP_DV_NAME="${WIN_SYSPREP_PVC:-${GOLDEN_IMAGE_NAME}-sysprep}"
SYSPREP_DS_NAME="${GOLDEN_IMAGE_NAME}-sysprep-ds"
OOBE_VM_NAME="${GOLDEN_IMAGE_NAME}-oobe-setup"
OOBE_CONFIGMAP_NAME="${GOLDEN_IMAGE_NAME}-unattend"
SNAPSHOT_NAME="${GOLDEN_IMAGE_NAME}-snap"

VOLUME_SNAPSHOT_CLASS="${VOLUME_SNAPSHOT_CLASS:-}"

# --- Helper Functions ---

detect_snapshot_class() {
  if [ -n "${VOLUME_SNAPSHOT_CLASS}" ]; then
    return
  fi
  local sc_provisioner
  sc_provisioner=$(oc get sc "${STORAGE_CLASS}" -o jsonpath='{.provisioner}' 2>/dev/null)
  if [ -z "${sc_provisioner}" ]; then
    echo "ERROR: Cannot determine provisioner for StorageClass '${STORAGE_CLASS}'"
    exit 1
  fi
  VOLUME_SNAPSHOT_CLASS=$(oc get volumesnapshotclass -o json 2>/dev/null | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    if item.get('driver') == '${sc_provisioner}':
        print(item['metadata']['name'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null)
  if [ -z "${VOLUME_SNAPSHOT_CLASS}" ]; then
    echo "ERROR: No VolumeSnapshotClass found for provisioner '${sc_provisioner}'"
    exit 1
  fi
  echo "Auto-detected VolumeSnapshotClass: ${VOLUME_SNAPSHOT_CLASS} (provisioner: ${sc_provisioner})"
}

cleanup_oobe_resources() {
  echo "Cleaning up temporary OOBE resources..."
  oc delete vm "${OOBE_VM_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" --wait=false 2>/dev/null || true
  oc delete configmap "${OOBE_CONFIGMAP_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
  oc delete datasource "${SYSPREP_DS_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
}

cleanup_pipeline_sa() {
  if [ "${CREATED_PIPELINE_SA}" == "true" ]; then
    echo "Cleaning up pipeline service account permissions..."
    oc adm policy remove-scc-from-user privileged -z pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
    oc adm policy remove-role-from-user edit -z pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
    oc delete serviceaccount pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
  fi
}

create_unattend_configmap() {
  echo "Creating unattend.xml ConfigMap for OOBE automation..."
  oc create -n "${GOLDEN_IMAGE_NAMESPACE}" -f - <<UNATTENDEOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${OOBE_CONFIGMAP_NAME}
  labels:
    app: ocp-virt-validation
data:
  unattend.xml: |
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <ComputerName>WinVM</ComputerName>
          <TimeZone>UTC</TimeZone>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add">
              <Order>1</Order>
              <Path>reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
      <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <InputLocale>0409:00000409</InputLocale>
          <SystemLocale>en-US</SystemLocale>
          <UILanguage>en-US</UILanguage>
          <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <OOBE>
            <HideEULAPage>true</HideEULAPage>
            <HideLocalAccountScreen>true</HideLocalAccountScreen>
            <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
            <NetworkLocation>Home</NetworkLocation>
            <ProtectYourPC>3</ProtectYourPC>
            <SkipMachineOOBE>true</SkipMachineOOBE>
            <SkipUserOOBE>true</SkipUserOOBE>
          </OOBE>
          <UserAccounts>
            <LocalAccounts>
              <LocalAccount wcm:action="add">
                <Password>
                  <Value>Admin123!</Value>
                  <PlainText>true</PlainText>
                </Password>
                <DisplayName>Admin</DisplayName>
                <Group>Administrators</Group>
                <Name>Admin</Name>
              </LocalAccount>
            </LocalAccounts>
          </UserAccounts>
          <AutoLogon>
            <Password>
              <Value>Admin123!</Value>
              <PlainText>true</PlainText>
            </Password>
            <Enabled>true</Enabled>
            <Username>Admin</Username>
          </AutoLogon>
        </component>
      </settings>
    </unattend>
UNATTENDEOF
  echo "ConfigMap '${OOBE_CONFIGMAP_NAME}' created"
}

create_sysprep_datasource() {
  echo "Creating temporary DataSource from sysprepped PVC..."
  oc create -n "${GOLDEN_IMAGE_NAMESPACE}" -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ${SYSPREP_DS_NAME}
  labels:
    app: ocp-virt-validation
spec:
  source:
    pvc:
      name: ${SYSPREP_DV_NAME}
      namespace: ${GOLDEN_IMAGE_NAMESPACE}
EOF
  echo "DataSource '${SYSPREP_DS_NAME}' created"
}

create_oobe_vm() {
  echo "Creating temporary VM to complete OOBE automatically..."
  oc create -n "${GOLDEN_IMAGE_NAMESPACE}" -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${OOBE_VM_NAME}
  labels:
    app: ocp-virt-validation
spec:
  runStrategy: Always
  instancetype:
    kind: VirtualMachineClusterInstancetype
    name: ${INSTANCE_TYPE}
  preference:
    kind: VirtualMachineClusterPreference
    name: windows.11.virtio
  dataVolumeTemplates:
    - metadata:
        name: ${OOBE_VM_NAME}-disk
      spec:
        storage:
          resources:
            requests:
              storage: 20Gi
          storageClassName: ${STORAGE_CLASS}
        sourceRef:
          kind: DataSource
          name: ${SYSPREP_DS_NAME}
          namespace: ${GOLDEN_IMAGE_NAMESPACE}
  template:
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: sysprep
              cdrom:
                bus: sata
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: ${OOBE_VM_NAME}-disk
        - name: sysprep
          sysprep:
            configMap:
              name: ${OOBE_CONFIGMAP_NAME}
EOF
  echo "VM '${OOBE_VM_NAME}' created"
}

wait_for_dv_ready() {
  local dv_name="${OOBE_VM_NAME}-disk"
  echo "Waiting for DataVolume '${dv_name}' clone to complete..."
  local timeout=1200
  local interval=15
  local elapsed=0

  while [ ${elapsed} -lt ${timeout} ]; do
    local dv_phase dv_progress
    dv_phase=$(oc get dv "${dv_name}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    dv_progress=$(oc get dv "${dv_name}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
      -o jsonpath='{.status.progress}' 2>/dev/null || echo "N/A")

    case "${dv_phase}" in
      "Succeeded")
        echo "DataVolume clone complete (${dv_progress})"
        return 0
        ;;
      "Failed")
        echo "ERROR: DataVolume clone failed"
        oc get dv "${dv_name}" -n "${GOLDEN_IMAGE_NAMESPACE}" -o yaml | tail -20
        return 1
        ;;
      *)
        echo "[${elapsed}s] DV phase: ${dv_phase}, progress: ${dv_progress}"
        ;;
    esac

    sleep ${interval}
    elapsed=$((elapsed + interval))
  done

  echo "ERROR: Timeout waiting for DataVolume clone (${timeout}s)"
  return 1
}

wait_for_vm_running() {
  echo "Waiting for VM to reach Running phase..."
  local timeout=300
  local interval=10
  local elapsed=0

  while [ ${elapsed} -lt ${timeout} ]; do
    local phase
    phase=$(oc get vmi "${OOBE_VM_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

    if [ "${phase}" == "Running" ]; then
      echo "VM is Running"
      return 0
    fi

    echo "[${elapsed}s] VM phase: ${phase}"
    sleep ${interval}
    elapsed=$((elapsed + interval))
  done

  echo "ERROR: Timeout waiting for VM to start (${timeout}s)"
  oc describe vmi "${OOBE_VM_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null | tail -30
  return 1
}

wait_for_desktop() {
  echo "Waiting for guest agent to report Windows OS..."
  local timeout=600
  local interval=15
  local elapsed=0

  while [ ${elapsed} -lt ${timeout} ]; do
    local guest_os
    guest_os=$(oc get vmi "${OOBE_VM_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
      -o jsonpath='{.status.guestOSInfo.name}' 2>/dev/null || echo "")

    if echo "${guest_os}" | grep -qi "windows"; then
      echo "Guest agent reports: ${guest_os}"
      echo "Polling for guest agent IP (indicates OOBE complete and desktop reached)..."
      local ip_timeout=600
      local ip_elapsed=0
      while [ ${ip_elapsed} -lt ${ip_timeout} ]; do
        local guest_ip
        guest_ip=$(oc get vmi "${OOBE_VM_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
          -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "")
        if [ -n "${guest_ip}" ]; then
          echo "Guest agent reports IP: ${guest_ip} - Windows OOBE completed"
          return 0
        fi
        echo "[${ip_elapsed}s] Waiting for guest agent IP..."
        sleep 15
        ip_elapsed=$((ip_elapsed + 15))
      done
      echo "ERROR: Timeout waiting for guest agent IP after OOBE"
      return 1
    fi

    echo "[${elapsed}s] Guest OS: ${guest_os:-not detected yet}"

    sleep ${interval}
    elapsed=$((elapsed + interval))
  done

  echo "ERROR: Timeout waiting for Windows guest agent (${timeout}s)"
  return 1
}

create_snapshot() {
  echo "Creating VolumeSnapshot of desktop-ready VM disk..."
  oc delete volumesnapshot "${SNAPSHOT_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
  oc create -n "${GOLDEN_IMAGE_NAMESPACE}" -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SNAPSHOT_NAME}
  labels:
    app: ocp-virt-validation
spec:
  volumeSnapshotClassName: ${VOLUME_SNAPSHOT_CLASS}
  source:
    persistentVolumeClaimName: ${OOBE_VM_NAME}-disk
EOF

  echo "Waiting for snapshot to be ready..."
  local timeout=120
  local interval=5
  local elapsed=0

  while [ ${elapsed} -lt ${timeout} ]; do
    local ready
    ready=$(oc get volumesnapshot "${SNAPSHOT_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
      -o jsonpath='{.status.readyToUse}' 2>/dev/null || echo "false")

    if [ "${ready}" == "true" ]; then
      echo "VolumeSnapshot '${SNAPSHOT_NAME}' is ready"
      return 0
    fi

    sleep ${interval}
    elapsed=$((elapsed + interval))
  done

  echo "ERROR: Timeout waiting for snapshot to become ready"
  return 1
}

create_datasource() {
  echo "Creating DataSource '${GOLDEN_IMAGE_NAME}' from snapshot..."
  oc delete datasource "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
  oc create -n "${GOLDEN_IMAGE_NAMESPACE}" -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ${GOLDEN_IMAGE_NAME}
  labels:
    app: ocp-virt-validation
spec:
  source:
    snapshot:
      name: ${SNAPSHOT_NAME}
      namespace: ${GOLDEN_IMAGE_NAMESPACE}
EOF
  echo "DataSource '${GOLDEN_IMAGE_NAME}' created"
}

# --- Main Script ---

echo "=== Windows Golden Image Setup ==="

# Step 1: Check if EULA is accepted
if [ "${ACCEPT_WINDOWS_EULA}" != "true" ]; then
  echo "ACCEPT_WINDOWS_EULA is not set to 'true'"
  echo "Skipping Windows golden image setup"
  echo "To enable Windows tests, set ACCEPT_WINDOWS_EULA=true"
  exit 0
fi

echo "Microsoft EULA accepted by user"
echo "Using golden image name: ${GOLDEN_IMAGE_NAME}"

# Step 2: Check if OpenShift Pipelines is installed
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
  echo "  oc apply -f - <<INSTALLEOF"
  echo "apiVersion: operators.coreos.com/v1alpha1"
  echo "kind: Subscription"
  echo "metadata:"
  echo "  name: openshift-pipelines-operator-rh"
  echo "  namespace: openshift-operators"
  echo "spec:"
  echo "  channel: stable"
  echo "  installPlanApproval: Automatic"
  echo "  name: openshift-pipelines-operator-rh"
  echo "  source: redhat-operators"
  echo "  sourceNamespace: openshift-marketplace"
  echo "INSTALLEOF"
  exit 1
fi

echo "OpenShift Pipelines operator is installed"

# Step 3: Ensure the golden image namespace exists
echo "Ensuring namespace ${GOLDEN_IMAGE_NAMESPACE} exists..."
if ! oc get namespace "${GOLDEN_IMAGE_NAMESPACE}" &>/dev/null; then
  echo "Creating namespace ${GOLDEN_IMAGE_NAMESPACE}..."
  oc create namespace "${GOLDEN_IMAGE_NAMESPACE}"
fi

# Step 4: Check if golden image DataSource already exists
echo "Checking if Windows golden image already exists..."
if oc get datasource "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" &>/dev/null; then
  echo "Windows golden image DataSource '${GOLDEN_IMAGE_NAME}' already exists in ${GOLDEN_IMAGE_NAMESPACE}"
  echo "Skipping image creation"
  exit 0
fi

# Step 5: Ensure pipeline service account exists
CREATED_PIPELINE_SA=false
echo "Ensuring pipeline service account exists..."
if ! oc get sa pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" &>/dev/null; then
  echo "Creating pipeline service account..."
  oc create serviceaccount pipeline -n "${GOLDEN_IMAGE_NAMESPACE}"
  oc adm policy add-scc-to-user privileged -z pipeline -n "${GOLDEN_IMAGE_NAMESPACE}"
  oc adm policy add-role-to-user edit -z pipeline -n "${GOLDEN_IMAGE_NAMESPACE}"
  CREATED_PIPELINE_SA=true
  trap cleanup_pipeline_sa EXIT
fi

# Step 6: Verify storage class and detect snapshot class
if [ -z "${STORAGE_CLASS}" ]; then
  echo "ERROR: STORAGE_CLASS is not set"
  exit 1
fi
detect_snapshot_class

echo "Using storage class: ${STORAGE_CLASS}"
echo "Using snapshot class: ${VOLUME_SNAPSHOT_CLASS}"
echo "Using Windows ISO URL: ${WIN_IMAGE_URL}"
echo "Using instance type: ${INSTANCE_TYPE}"

# Step 7: Check if sysprepped PVC already exists (skip pipeline if so)
if oc get pvc "${SYSPREP_DV_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" &>/dev/null; then
  echo "Sysprepped PVC '${SYSPREP_DV_NAME}' already exists - skipping pipeline"
else
  echo ""
  echo "=== Phase 1: Creating sysprepped Windows disk via pipeline ==="
  echo "Using hub resolver to fetch pipeline from artifacthub (version: ${PIPELINE_VERSION})"

PIPELINE_RUN_NAME=$(oc create -n "${GOLDEN_IMAGE_NAMESPACE}" -f - <<EOF | grep -oP 'pipelinerun.tekton.dev/\K[^ ]+'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: windows11-golden-
  labels:
    app: ocp-virt-validation
spec:
  timeouts:
    pipeline: "3h"
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
      value: "${ACCEPT_WINDOWS_EULA}"
    - name: baseDvName
      value: "${SYSPREP_DV_NAME}"
    - name: baseDvNamespace
      value: "${GOLDEN_IMAGE_NAMESPACE}"
    - name: instanceTypeName
      value: "${INSTANCE_TYPE}"
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

if [ -z "${PIPELINE_RUN_NAME}" ]; then
  echo "ERROR: Failed to create PipelineRun or parse its name"
  exit 1
fi

echo "Created PipelineRun: ${PIPELINE_RUN_NAME}"

# Step 8: Wait for pipeline to complete
echo "Waiting for Windows installation to complete..."
echo "This may take up to 3 hours for first-time setup"

TIMEOUT_SECONDS=10800
POLL_INTERVAL=60
ELAPSED=0

while [ ${ELAPSED} -lt ${TIMEOUT_SECONDS} ]; do
  STATUS=$(oc get pipelinerun "${PIPELINE_RUN_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
    -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Unknown")

  case "${STATUS}" in
    "Succeeded")
      echo "Pipeline completed successfully!"
      echo "Sysprepped disk '${SYSPREP_DV_NAME}' is ready"
      break
      ;;
    "Failed"|"PipelineRunTimeout"|"TaskRunCancelled"|"CouldntGetPipeline")
      echo "ERROR: Pipeline failed with status: ${STATUS}"
      echo ""
      if [ "${STATUS}" == "CouldntGetPipeline" ]; then
        echo "Failed to fetch pipeline from artifacthub. This could mean:"
        echo "  1. No internet access (hub resolver requires network)"
        echo "  2. The pipeline version ${PIPELINE_VERSION} doesn't exist"
        echo ""
        echo "For disconnected environments, manually install the pipeline first:"
        echo "  https://artifacthub.io/packages/tekton-pipeline/redhat-pipelines/windows-efi-installer"
      fi
      oc get pipelinerun "${PIPELINE_RUN_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" -o yaml | tail -50
      exit 1
      ;;
    *)
      CURRENT_TASK=$(oc get pipelinerun "${PIPELINE_RUN_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
        -o jsonpath='{.status.childReferences[-1].name}' 2>/dev/null || echo "starting")
      echo "[${ELAPSED}s] Status: ${STATUS}, Current: ${CURRENT_TASK}"
      ;;
  esac

  sleep ${POLL_INTERVAL}
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ ${ELAPSED} -ge ${TIMEOUT_SECONDS} ]; then
  echo "ERROR: Timeout waiting for Windows installation"
  exit 1
fi

fi  # end of pipeline skip check

# Step 9: Complete OOBE automatically
echo ""
echo "=== Phase 2: Completing OOBE automatically ==="
echo "Booting sysprepped image with unattend.xml to skip OOBE..."

trap cleanup_oobe_resources EXIT

create_sysprep_datasource
create_unattend_configmap
create_oobe_vm

if ! wait_for_dv_ready; then
  echo "ERROR: DataVolume clone failed - cannot proceed"
  exit 1
fi

if ! wait_for_vm_running; then
  echo "ERROR: VM failed to start after disk clone"
  exit 1
fi

if ! wait_for_desktop; then
  echo "ERROR: Failed to complete OOBE automatically"
  exit 1
fi

STABILIZATION_WAIT=300
echo "Waiting ${STABILIZATION_WAIT}s for Windows Setup to fully finalize before snapshotting..."
sleep ${STABILIZATION_WAIT}

echo "Gracefully shutting down Windows before snapshotting..."
/home/ocp-virt-validation-checkup/virtctl stop "${OOBE_VM_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}"

SHUTDOWN_TIMEOUT=300
SHUTDOWN_ELAPSED=0
while [ ${SHUTDOWN_ELAPSED} -lt ${SHUTDOWN_TIMEOUT} ]; do
  VMI_EXISTS=$(oc get vmi "${OOBE_VM_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null && echo "yes" || echo "no")
  if [ "${VMI_EXISTS}" == "no" ]; then
    echo "VM has shut down cleanly"
    break
  fi
  VMI_PHASE=$(oc get vmi "${OOBE_VM_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
  echo "[${SHUTDOWN_ELAPSED}s] Waiting for VM shutdown... VMI phase: ${VMI_PHASE}"
  sleep 10
  SHUTDOWN_ELAPSED=$((SHUTDOWN_ELAPSED + 10))
done

if [ ${SHUTDOWN_ELAPSED} -ge ${SHUTDOWN_TIMEOUT} ]; then
  echo "WARNING: Graceful shutdown timed out, force stopping..."
  /home/ocp-virt-validation-checkup/virtctl stop "${OOBE_VM_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" --force --grace-period 0 2>/dev/null || true
  sleep 15
fi

# Step 10: Snapshot the desktop-ready VM
echo ""
echo "=== Phase 3: Creating golden image snapshot ==="

if ! create_snapshot; then
  echo "ERROR: Failed to create snapshot"
  exit 1
fi

# Step 11: Create the final DataSource
if ! create_datasource; then
  echo "ERROR: Failed to create DataSource"
  exit 1
fi

# Step 12: Cleanup temporary resources and SA permissions (traps handle both)
trap - EXIT
cleanup_oobe_resources
cleanup_pipeline_sa

echo ""
echo "=== Windows Golden Image Setup Complete ==="
echo "DataSource: ${GOLDEN_IMAGE_NAME} (namespace: ${GOLDEN_IMAGE_NAMESPACE})"
echo "Snapshot:   ${SNAPSHOT_NAME}"
echo ""
echo "New VMs from this DataSource will boot directly to the Windows desktop."
echo "Login: Admin / Admin123!"
