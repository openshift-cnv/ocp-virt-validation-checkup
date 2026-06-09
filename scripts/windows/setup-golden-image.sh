#!/bin/bash
#
# Setup Windows Server 2022 Golden Image for Self-Validation
#
# Creates a ready-to-use Windows Server 2022 golden image using the
# windows-efi-installer Tekton pipeline with a custom autounattend.
# The resulting DataSource produces VMs that boot directly to the desktop
# with OpenSSH enabled and firewall disabled — no manual setup needed.
#
# Flow:
#   1. Pipeline downloads the ISO and injects our custom autounattend.xml
#   2. VM boots and installs Windows Server 2022 (Desktop Experience)
#   3. FirstLogonCommands run post-update.ps1 (guest agent, OpenSSH, firewall, cleanup)
#   4. VM shuts down automatically after configuration
#   5. Snapshot the disk and create a DataSource (this is the golden image)
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

DEFAULT_WIN_GOLDEN_IMAGE_NAME="windows2022-golden-image"
GOLDEN_IMAGE_NAME="${WIN_IMAGE_NAME:-${DEFAULT_WIN_GOLDEN_IMAGE_NAME}}"

DEFAULT_WIN_IMAGE_URL="https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso"
WIN_IMAGE_URL="${WIN_IMAGE_DOWNLOAD_URL:-${DEFAULT_WIN_IMAGE_URL}}"

PIPELINE_VERSION="${TEKTON_PIPELINE_VERSION:->=v4.21.0}"

DEFAULT_INSTANCE_TYPE="u1.large"
INSTANCE_TYPE="${WIN_INSTANCE_TYPE:-${DEFAULT_INSTANCE_TYPE}}"

AUTOUNATTEND_CM_NAME="${GOLDEN_IMAGE_NAME}-autounattend"
SYSPREP_DV_NAME="${WIN_SYSPREP_PVC:-${GOLDEN_IMAGE_NAME}}"
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

cleanup_pipeline_sa() {
  if [ "${CREATED_PIPELINE_SA}" == "true" ]; then
    echo "Cleaning up pipeline service account permissions..."
    oc adm policy remove-scc-from-user privileged -z pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
    oc adm policy remove-role-from-user edit -z pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
    oc delete serviceaccount pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
  fi
}

cleanup_autounattend_cm() {
  oc delete configmap "${AUTOUNATTEND_CM_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
}

create_autounattend_configmap() {
  echo "Creating custom autounattend ConfigMap for Windows Server 2022..."
  oc delete configmap "${AUTOUNATTEND_CM_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
  oc create -n "${GOLDEN_IMAGE_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${AUTOUNATTEND_CM_NAME}
  labels:
    app: ocp-virt-validation
data:
  autounattend.xml: |
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <SetupUILanguage>
            <UILanguage>en-US</UILanguage>
          </SetupUILanguage>
          <InputLocale>0409:00000409</InputLocale>
          <SystemLocale>en-US</SystemLocale>
          <UILanguage>en-US</UILanguage>
          <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <DriverPaths>
            <PathAndCredentials wcm:action="add" wcm:keyValue="1">
              <Path>E:\\</Path>
            </PathAndCredentials>
          </DriverPaths>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <DiskConfiguration>
            <WillShowUI>Never</WillShowUI>
            <Disk wcm:action="add">
              <CreatePartitions>
                  <CreatePartition wcm:action="add">
                      <Order>1</Order>
                      <Type>EFI</Type>
                      <Size>100</Size>
                  </CreatePartition>
                  <CreatePartition wcm:action="add">
                      <Order>2</Order>
                      <Type>MSR</Type>
                      <Size>16</Size>
                  </CreatePartition>
                  <CreatePartition wcm:action="add">
                      <Order>3</Order>
                      <Type>Primary</Type>
                      <Extend>true</Extend>
                  </CreatePartition>
              </CreatePartitions>
              <ModifyPartitions>
                <ModifyPartition wcm:action="add">
                    <Order>1</Order>
                    <PartitionID>1</PartitionID>
                    <Label>EFI</Label>
                    <Format>FAT32</Format>
                </ModifyPartition>
                <ModifyPartition wcm:action="add">
                    <Order>2</Order>
                    <PartitionID>3</PartitionID>
                    <Label>Windows</Label>
                    <Letter>C</Letter>
                    <Format>NTFS</Format>
                </ModifyPartition>
              </ModifyPartitions>
              <DiskID>0</DiskID>
              <WillWipeDisk>true</WillWipeDisk>
            </Disk>
          </DiskConfiguration>
          <ImageInstall>
            <OSImage>
              <InstallFrom>
                <MetaData wcm:action="add">
                  <Key>/Image/Index</Key>
                  <Value>2</Value>
                </MetaData>
              </InstallFrom>
              <InstallTo>
                <DiskID>0</DiskID>
                <PartitionID>3</PartitionID>
              </InstallTo>
            </OSImage>
          </ImageInstall>
          <UserData>
            <AcceptEula>true</AcceptEula>
          </UserData>
        </component>
      </settings>
      <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <InputLocale>0409:00000409</InputLocale>
          <SystemLocale>en-US</SystemLocale>
          <UILanguage>en-US</UILanguage>
          <UILanguageFallback>en-US</UILanguageFallback>
          <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <UserAccounts>
            <AdministratorPassword>
              <Value>Heslo123</Value>
              <PlainText>true</PlainText>
            </AdministratorPassword>
          </UserAccounts>
          <AutoLogon>
            <Enabled>true</Enabled>
            <Password>
              <Value>Heslo123</Value>
              <PlainText>true</PlainText>
            </Password>
            <Username>Administrator</Username>
          </AutoLogon>
          <TimeZone>UTC</TimeZone>
          <OOBE>
            <HideEULAPage>true</HideEULAPage>
            <HideLocalAccountScreen>true</HideLocalAccountScreen>
            <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
            <NetworkLocation>Work</NetworkLocation>
            <ProtectYourPC>3</ProtectYourPC>
          </OOBE>
          <FirstLogonCommands>
            <SynchronousCommand wcm:action="add">
              <Order>1</Order>
              <CommandLine>PowerShell -ExecutionPolicy Bypass -NoProfile F:\\post-update.ps1</CommandLine>
              <Description>Install SSH and configure system</Description>
            </SynchronousCommand>
          </FirstLogonCommands>
        </component>
      </settings>
    </unattend>
  post-update.ps1: |
    # Critical section - abort on any failure
    \$ErrorActionPreference = 'Stop'

    # Install QEMU guest agent
    Start-Process msiexec -Wait -ArgumentList "/i E:\\guest-agent\\qemu-ga-x86_64.msi /qn /passive /norestart"

    # Install and start OpenSSH server
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd

    # Disable Windows Firewall entirely
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

    # Non-critical cleanup - continue on error
    \$ErrorActionPreference = 'Continue'

    # Suppress network location wizard and set profile
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff" -Force | Out-Null
    Set-NetConnectionProfile -InterfaceAlias "Ethernet" -NetworkCategory Private -ErrorAction SilentlyContinue

    # Disable Server Manager auto-launch
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Name DoNotOpenServerManagerAtLogon -Value 1

    # Cleanup for smaller image
    \$PageFile = Get-CimInstance -ClassName Win32_PageFileSetting -Filter "Name like '%pagefile.sys'"
    if (\$PageFile) {
      \$PageFile | Remove-CimInstance
      \$PageFile = New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name= "C:\\pagefile.sys" }
      \$PageFile | Set-CimInstance -Property @{ InitialSize = 0; MaximumSize = 0 }
    }
    Vssadmin delete shadows /all /quiet
    Remove-Item -Path \$env:Temp -Recurse -Force -ErrorAction SilentlyContinue
    dism.exe /online /Cleanup-Image /StartComponentCleanup
    powercfg -h off

    # Rename cached unattend.xml to prevent sysprep issues
    if (Test-Path "C:\\Windows\\Panther\\unattend.xml") {
      mv C:\\Windows\\Panther\\unattend.xml C:\\Windows\\Panther\\unattend.install.xml
    }

    # Eject CD and shut down
    (New-Object -COMObject Shell.Application).NameSpace(17).ParseName("F:").InvokeVerb("Eject")
    Stop-Computer -Force
EOF
}

# --- Main Script ---

echo "=== Windows Server 2022 Golden Image Setup ==="

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
  exit 1
fi

echo "OpenShift Pipelines operator is installed"

# Step 3: Ensure the golden image namespace exists
echo "Ensuring namespace ${GOLDEN_IMAGE_NAMESPACE} exists..."
if ! oc get namespace "${GOLDEN_IMAGE_NAMESPACE}" &>/dev/null; then
  echo "Creating namespace ${GOLDEN_IMAGE_NAMESPACE}..."
  oc create namespace "${GOLDEN_IMAGE_NAMESPACE}"
fi

oc label namespace "${GOLDEN_IMAGE_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite

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
fi

trap 'cleanup_pipeline_sa; cleanup_autounattend_cm' EXIT

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

# Step 7: Create custom autounattend ConfigMap
create_autounattend_configmap

# Step 8: Check if PVC already exists (skip pipeline if so)
if oc get pvc "${SYSPREP_DV_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" &>/dev/null; then
  echo "PVC '${SYSPREP_DV_NAME}' already exists - skipping pipeline"
else
  echo ""
  echo "=== Running Windows Server 2022 Installation Pipeline ==="

PIPELINE_RUN_NAME=$(oc create -n "${GOLDEN_IMAGE_NAMESPACE}" -f - <<EOF | grep -oP 'pipelinerun.tekton.dev/\K[^ ]+'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: win2022-golden-
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
      value: "windows.2k22"
    - name: preferenceKind
      value: "VirtualMachineClusterPreference"
    - name: autounattendConfigMapName
      value: "${AUTOUNATTEND_CM_NAME}"
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

# Step 9: Wait for pipeline to complete
echo "Waiting for Windows installation to complete (this may take up to 3 hours)..."

TIMEOUT_SECONDS=10800
POLL_INTERVAL=60
ELAPSED=0

while [ ${ELAPSED} -lt ${TIMEOUT_SECONDS} ]; do
  STATUS=$(oc get pipelinerun "${PIPELINE_RUN_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
    -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Unknown")

  case "${STATUS}" in
    "Succeeded")
      echo "Pipeline completed successfully!"
      break
      ;;
    "Failed"|"PipelineRunTimeout"|"TaskRunCancelled"|"CouldntGetPipeline")
      echo "ERROR: Pipeline failed with status: ${STATUS}"
      if [ "${STATUS}" == "CouldntGetPipeline" ]; then
        echo "Failed to fetch pipeline from artifacthub."
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

# Step 10: Create snapshot from the ready PVC
echo ""
echo "=== Creating Golden Image Snapshot ==="

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
    persistentVolumeClaimName: ${SYSPREP_DV_NAME}
EOF

echo "Waiting for snapshot to be ready..."
SNAP_TIMEOUT=300
SNAP_ELAPSED=0
while [ ${SNAP_ELAPSED} -lt ${SNAP_TIMEOUT} ]; do
  READY=$(oc get volumesnapshot "${SNAPSHOT_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
    -o jsonpath='{.status.readyToUse}' 2>/dev/null || echo "false")
  if [ "${READY}" == "true" ]; then
    echo "VolumeSnapshot '${SNAPSHOT_NAME}' is ready"
    break
  fi
  sleep 5
  SNAP_ELAPSED=$((SNAP_ELAPSED + 5))
done

if [ "${READY}" != "true" ]; then
  echo "ERROR: Timeout waiting for snapshot"
  exit 1
fi

# Step 11: Create the final DataSource
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

# Cleanup
trap - EXIT
cleanup_pipeline_sa
cleanup_autounattend_cm

echo ""
echo "=== Windows Server 2022 Golden Image Setup Complete ==="
echo "DataSource: ${GOLDEN_IMAGE_NAME} (namespace: ${GOLDEN_IMAGE_NAMESPACE})"
echo "Snapshot:   ${SNAPSHOT_NAME}"
echo ""
echo "Login: Administrator / Heslo123"
echo "SSH:   Enabled on port 22"
