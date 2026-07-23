#!/bin/bash
#
# Setup Windows Server 2022 Golden Image for Self-Validation
#
# Creates a ready-to-use Windows Server 2022 golden image using the
# windows-efi-installer Tekton pipeline with a custom autounattend.
# The pipeline output PVC backs a DataSource in a custom namespace
# (validation-os-images), which is created and owned by this tool.
#
# Flow:
#   1. Create the validation-os-images namespace
#   2. Pipeline downloads the ISO and injects our custom autounattend.xml
#   3. Pipeline creates a PVC and boots a VM that installs Windows Server 2022 onto it
#   4. FirstLogonCommands run post-update.ps1 (guest agent, OpenSSH, firewall, cleanup)
#   5. VM shuts down automatically after configuration
#   6. Create a DataSource pointing to the output PVC
#
# Prerequisites:
# - OpenShift Pipelines operator installed
# - ACCEPT_WINDOWS_EULA=true (user must explicitly accept Microsoft EULA)
# - STORAGE_CLASS set to a valid storage class
#
# Optional:
# - WIN_IMAGE_DOWNLOAD_URL: Custom Windows ISO download URL
# - WIN_INSTANCE_TYPE: Instance type (default: u1.large)
#

set -e

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "${SCRIPT_DIR}/../funcs.sh"

GOLDEN_IMAGE_NAMESPACE="${GOLDEN_IMAGE_NAMESPACE:-validation-os-images}"
GOLDEN_IMAGE_NAME="${GOLDEN_IMAGE_NAME:-win2k22}"

DEFAULT_WIN_IMAGE_URL="https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso"
WIN_IMAGE_URL="${WIN_IMAGE_DOWNLOAD_URL:-${DEFAULT_WIN_IMAGE_URL}}"

PIPELINE_VERSION="${TEKTON_PIPELINE_VERSION:->=v4.21.0}"

DEFAULT_INSTANCE_TYPE="u1.large"
INSTANCE_TYPE="${WIN_INSTANCE_TYPE:-${DEFAULT_INSTANCE_TYPE}}"

AUTOUNATTEND_CM_NAME="${GOLDEN_IMAGE_NAME}-autounattend"

# --- Helper Functions ---

cleanup_pipeline_sa() {
  if [ "${CREATED_PIPELINE_SA}" == "true" ]; then
    # Don't delete SA if pipeline is still running — it needs the SA to complete
    if [ -n "${PIPELINE_RUN_NAME:-}" ]; then
      local pr_status
      pr_status=$(oc get pipelinerun "${PIPELINE_RUN_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
        -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "")
      if [ "${pr_status}" == "Running" ] || [ "${pr_status}" == "ResolvingTaskRef" ]; then
        echo "Pipeline still running — skipping SA cleanup to avoid disruption."
        return
      fi
    fi
    echo "Cleaning up pipeline service account permissions..."
    oc adm policy remove-scc-from-user privileged -z pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
    oc adm policy remove-role-from-user edit -z pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
    local SA_LABEL
    SA_LABEL=$(oc get sa pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")
    if [ "${SA_LABEL}" == "ocp-virt-validation" ]; then
      oc delete serviceaccount pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
    fi
  fi
}

cleanup_autounattend_cm() {
  oc delete configmap "${AUTOUNATTEND_CM_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
}

cleanup_namespace() {
  cleanup_golden_image_resources "${GOLDEN_IMAGE_NAMESPACE}"
}

run_pipeline() {
  CREATED_PIPELINE_SA=false
  echo "Ensuring pipeline service account exists..."
  if ! oc get sa pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" &>/dev/null; then
    echo "Creating pipeline service account..."
    oc create serviceaccount pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" 2>/dev/null || true
    oc label serviceaccount pipeline -n "${GOLDEN_IMAGE_NAMESPACE}" app=ocp-virt-validation --overwrite
  fi
  echo "Granting pipeline service account privileged SCC and edit role..."
  oc adm policy add-scc-to-user privileged -z pipeline -n "${GOLDEN_IMAGE_NAMESPACE}"
  CREATED_PIPELINE_SA=true
  oc adm policy add-role-to-user edit -z pipeline -n "${GOLDEN_IMAGE_NAMESPACE}"

  if [ -z "${STORAGE_CLASS}" ]; then
    echo "ERROR: STORAGE_CLASS is not set"
    exit 1
  fi

  echo "Using storage class: ${STORAGE_CLASS}"
  echo "Using Windows ISO URL: ${WIN_IMAGE_URL}"
  echo "Using instance type: ${INSTANCE_TYPE}"

  create_autounattend_configmap

  echo ""
  echo "=== Running Windows Server 2022 Installation Pipeline ==="

  PIPELINE_RUN_NAME=$(oc create -n "${GOLDEN_IMAGE_NAMESPACE}" -o name -f - <<EOF | cut -d/ -f2
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
      value: "${GOLDEN_IMAGE_NAME}"
    - name: baseDvNamespace
      value: "${GOLDEN_IMAGE_NAMESPACE}"
    - name: instanceTypeName
      value: "${INSTANCE_TYPE}"
    - name: instanceTypeKind
      value: "VirtualMachineClusterInstancetype"
    - name: preferenceName
      value: "windows.2k22"
    - name: autounattendConfigMapName
      value: "${AUTOUNATTEND_CM_NAME}"
    - name: baseDvStorageClass
      value: "${STORAGE_CLASS}"
    - name: isoDVName
      value: "${GOLDEN_IMAGE_NAME}-iso"
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
  echo "Waiting for Windows installation to complete (this may take up to 3 hours)..."

  local TIMEOUT_SECONDS=10800
  local POLL_INTERVAL=60
  local ELAPSED=0

  while [ ${ELAPSED} -lt ${TIMEOUT_SECONDS} ]; do
    local STATUS
    STATUS=$(oc get pipelinerun "${PIPELINE_RUN_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
      -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Unknown")

    case "${STATUS}" in
      "Succeeded")
        echo "Pipeline completed successfully!"
        PIPELINE_SUCCEEDED=true
        break
        ;;
      "Failed"|"PipelineRunTimeout"|"TaskRunCancelled"|"CouldntGetPipeline")
        if [ "${STATUS}" == "CouldntGetPipeline" ]; then
          echo "ERROR: Failed to fetch pipeline from artifacthub."
          echo "For disconnected environments, manually install the pipeline first:"
          echo "  https://artifacthub.io/packages/tekton-pipeline/redhat-pipelines/windows-efi-installer"
          exit 1
        fi
        echo "ERROR: Pipeline failed with status: ${STATUS}"
        oc get pipelinerun "${PIPELINE_RUN_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" -o yaml | tail -50
        exit 1
        ;;
      *)
        local CURRENT_TASK
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

  for attempt in 1 2 3; do
    if oc label pvc "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" app=ocp-virt-validation --overwrite; then
      break
    fi
    [ "${attempt}" -lt 3 ] && echo "WARNING: Failed to label PVC (attempt ${attempt}/3), retrying in 5s..." && sleep 5
  done
  if [ "$(oc get pvc "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" -o jsonpath='{.metadata.labels.app}')" != "ocp-virt-validation" ]; then
    echo "ERROR: Failed to label PVC '${GOLDEN_IMAGE_NAME}' -- cleanup cannot identify tool-created resources."
    exit 1
  fi

  # The pipeline fills the disk via a VM, so CDI never marks the DV as Succeeded
  # (it stays PendingPopulation). Annotate the PVC to tell CDI it was populated,
  # which causes CDI to transition the DV to Succeeded.
  local DV_UID
  DV_UID=$(oc get dv "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")
  if [ -n "${DV_UID}" ]; then
    oc annotate pvc "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
      "cdi.kubevirt.io/storage.populatedFor=${DV_UID}" --overwrite 2>/dev/null || true
  fi
}

# NOTE: Keep autounattend.xml and post-update.ps1 in sync with
# manifests/windows/golden-image.yaml (ConfigMap: win2k22-autounattend)
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
              <Value>Administrator</Value>
              <PlainText>true</PlainText>
            </AdministratorPassword>
          </UserAccounts>
          <AutoLogon>
            <Enabled>true</Enabled>
            <Password>
              <Value>Administrator</Value>
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
    try {
      \$ErrorActionPreference = 'Stop'

      # Install QEMU guest agent
      Start-Process msiexec -Wait -ArgumentList "/i E:\\guest-agent\\qemu-ga-x86_64.msi /qn /passive /norestart"

      # Install and start OpenSSH server
      Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
      Set-Service -Name sshd -StartupType Automatic
      Start-Service sshd

      # Disable Windows Firewall entirely
      Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

      \$ErrorActionPreference = 'Continue'

      # Suppress network location wizard and set profile
      New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff" -Force | Out-Null
      Set-NetConnectionProfile -InterfaceAlias "Ethernet" -NetworkCategory Private -ErrorAction SilentlyContinue

      # Disable Server Manager auto-launch
      Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Name DoNotOpenServerManagerAtLogon -Value 1

      # Cleanup for smaller image (with timeouts to avoid hangs)
      Vssadmin delete shadows /all /quiet 2>\$null
      Remove-Item -Path \$env:Temp -Recurse -Force -ErrorAction SilentlyContinue
      powercfg -h off 2>\$null

      # DISM can hang -- run with a timeout
      \$dismJob = Start-Job { dism.exe /online /Cleanup-Image /StartComponentCleanup }
      if (-not (Wait-Job \$dismJob -Timeout 300)) {
        Stop-Job \$dismJob
        Remove-Job \$dismJob -Force
      } else {
        Remove-Job \$dismJob
      }

      # Rename cached unattend.xml to prevent sysprep issues
      if (Test-Path "C:\\Windows\\Panther\\unattend.xml") {
        Rename-Item "C:\\Windows\\Panther\\unattend.xml" "C:\\Windows\\Panther\\unattend.install.xml"
      }

      # Eject CD
      try { (New-Object -COMObject Shell.Application).NameSpace(17).ParseName("F:").InvokeVerb("Eject") } catch {}
    }
    finally {
      # Disable Windows Update to prevent it from blocking shutdown
      Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
      Set-Service wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
      # Always shut down, even if errors occurred above
      Stop-Computer -Force
    }
EOF
}

# --- Main Script ---

echo "=== Windows Server 2022 Golden Image Setup ==="
echo "Using golden image name: ${GOLDEN_IMAGE_NAME}"

# BYOI path: if DataSource already exists and is Ready, nothing to do.
DS_READY=$(oc get datasource "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [ "${DS_READY}" == "True" ]; then
  DS_LABEL="$(oc get datasource "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
    -o jsonpath='{.metadata.labels.app}' 2>/dev/null || true)"
  if [ "${DS_LABEL}" == "ocp-virt-validation" ]; then
    echo "DataSource '${GOLDEN_IMAGE_NAME}' already exists and is Ready (previous tool run)."
  else
    echo "DataSource '${GOLDEN_IMAGE_NAME}' already exists and is Ready (BYOI)."
  fi
  echo "Skipping golden image setup — using existing image."
  echo ""
  echo "=== Windows Server 2022 Golden Image Ready ==="
  echo "DataSource: ${GOLDEN_IMAGE_NAME} (namespace: ${GOLDEN_IMAGE_NAMESPACE})"
  exit 0
fi

# Tool-managed path: EULA required to download and create the image
if [ "${ACCEPT_WINDOWS_EULA}" != "true" ]; then
  echo "ACCEPT_WINDOWS_EULA is not set to 'true' and no existing DataSource found."
  echo "Skipping Windows golden image setup."
  echo ""
  echo "To enable Windows tests, either:"
  echo "  - Set ACCEPT_WINDOWS_EULA=true (tool will download and install Windows from Microsoft)"
  echo "  - Apply the BYOI manifests: oc apply -f manifests/windows/golden-image.yaml"
  exit 0
fi

echo "Microsoft EULA accepted by user"

echo "Checking if OpenShift Pipelines operator is installed..."
if ! oc get crd pipelines.tekton.dev &>/dev/null; then
  echo "WARNING: OpenShift Pipelines operator is not installed."
  echo "Cannot create Windows golden image without OpenShift Pipelines."
  echo "Windows tests will be skipped. All other test suites will run normally."
  echo ""
  echo "To enable Windows tests, install the OpenShift Pipelines operator from OperatorHub:"
  echo "  1. Go to OperatorHub in the OpenShift Console"
  echo "  2. Search for 'Red Hat OpenShift Pipelines'"
  echo "  3. Install the operator"
  exit 1
fi
echo "OpenShift Pipelines operator is installed"

# Tool-managed: create namespace, RBAC, run pipeline, create DataSource, cleanup on completion
# After pipeline success, preserve the namespace/PVC on post-pipeline failures
# (DataSource creation, labeling, etc.) so the 1-3 hour pipeline doesn't re-run.
PIPELINE_SUCCEEDED=false
trap 'exit_code=$?; cleanup_pipeline_sa; cleanup_autounattend_cm; if [ $exit_code -ne 0 ]; then if [ "${PIPELINE_SUCCEEDED}" != "true" ]; then cleanup_namespace; else echo "WARNING: Post-pipeline setup failed but PVC is intact. Re-run will detect and reuse it."; fi; fi' EXIT

echo "Ensuring namespace ${GOLDEN_IMAGE_NAMESPACE} exists..."
if ! oc get namespace "${GOLDEN_IMAGE_NAMESPACE}" &>/dev/null; then
  echo "Creating namespace ${GOLDEN_IMAGE_NAMESPACE}..."
  oc create namespace "${GOLDEN_IMAGE_NAMESPACE}"
  oc label namespace "${GOLDEN_IMAGE_NAMESPACE}" app=ocp-virt-validation --overwrite
else
  echo "Namespace ${GOLDEN_IMAGE_NAMESPACE} already exists"
  NS_LABEL=$(oc get namespace "${GOLDEN_IMAGE_NAMESPACE}" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")
  if [ "${NS_LABEL}" != "ocp-virt-validation" ]; then
    echo "ERROR: Namespace '${GOLDEN_IMAGE_NAMESPACE}' exists but is not tool-managed (missing app=ocp-virt-validation label)."
    echo "Cannot run automated Windows setup in a customer-owned namespace."
    echo ""
    echo "To resolve, either:"
    echo "  - Wait for the BYOI DataSource to become Ready (tool will detect and reuse it)"
    echo "  - Delete the namespace before using ACCEPT_WINDOWS_EULA=true"
    exit 1
  fi
fi

oc label namespace "${GOLDEN_IMAGE_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite

echo "Ensuring CDI clone RBAC exists..."
cat <<'RBAC_EOF' | oc apply -n "${GOLDEN_IMAGE_NAMESPACE}" -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: os-images.kubevirt.io:view
  labels:
    app: ocp-virt-validation
rules:
- apiGroups: [""]
  resources: [persistentvolumeclaims, persistentvolumeclaims/status]
  verbs: [get, list, watch]
- apiGroups: [snapshot.storage.k8s.io]
  resources: [volumesnapshots, volumesnapshots/status]
  verbs: [get, list, watch]
- apiGroups: [cdi.kubevirt.io]
  resources: [datavolumes]
  verbs: [get, list, watch]
- apiGroups: [cdi.kubevirt.io]
  resources: [datavolumes/source]
  verbs: [create]
- apiGroups: [cdi.kubevirt.io]
  resources: [datasources]
  verbs: [get, list, watch]
- apiGroups: [""]
  resources: [namespaces]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: os-images.kubevirt.io:view
  labels:
    app: ocp-virt-validation
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: os-images.kubevirt.io:view
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:authenticated
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:serviceaccounts
RBAC_EOF

# If a tool-created PVC exists from a previous run, reuse it (skip the 1-3 hour pipeline).
# This handles the case where a previous run's post-pipeline steps failed but the PVC is intact.
if oc get pvc "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" &>/dev/null; then
  PVC_LABEL=$(oc get pvc "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")
  if [ "${PVC_LABEL}" == "ocp-virt-validation" ]; then
    echo "PVC '${GOLDEN_IMAGE_NAME}' exists from a previous tool run -- reusing (skipping pipeline)."
    PIPELINE_SUCCEEDED=true
  else
    echo "ERROR: PVC '${GOLDEN_IMAGE_NAME}' already exists in namespace '${GOLDEN_IMAGE_NAMESPACE}' but is not owned by this tool."
    echo "Please remove it manually or use a different GOLDEN_IMAGE_NAME."
    exit 1
  fi
else
  run_pipeline
fi

# Create DataSource pointing to the PVC
echo ""
echo "=== Configuring DataSource ==="

echo "Creating DataSource '${GOLDEN_IMAGE_NAME}'..."
oc apply -n "${GOLDEN_IMAGE_NAMESPACE}" -f - <<DSEOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ${GOLDEN_IMAGE_NAME}
  labels:
    app: ocp-virt-validation
spec:
  source:
    pvc:
      name: ${GOLDEN_IMAGE_NAME}
      namespace: ${GOLDEN_IMAGE_NAMESPACE}
DSEOF

echo "Waiting for DataSource to become Ready..."
for i in $(seq 1 12); do
  DS_READY=$(oc get datasource "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "${DS_READY}" == "True" ]; then
    echo "DataSource '${GOLDEN_IMAGE_NAME}' is Ready"
    break
  fi
  echo "  Not ready yet (attempt ${i}/12), waiting 10s..."
  sleep 10
done

if [ "${DS_READY}" != "True" ]; then
  echo "ERROR: DataSource '${GOLDEN_IMAGE_NAME}' is not Ready after 2 minutes"
  echo "The PVC exists but the DataSource failed to reconcile."
  echo "Check with: oc get datasource ${GOLDEN_IMAGE_NAME} -n ${GOLDEN_IMAGE_NAMESPACE} -o yaml"
  exit 1
fi

# Cleanup pipeline resources (SA, autounattend CM)
trap - EXIT
cleanup_pipeline_sa
cleanup_autounattend_cm

echo ""
echo "=== Windows Server 2022 Golden Image Setup Complete ==="
echo "DataSource: ${GOLDEN_IMAGE_NAME} (namespace: ${GOLDEN_IMAGE_NAMESPACE})"
echo "PVC:        ${GOLDEN_IMAGE_NAME}"
echo ""
echo "Login: Administrator / Administrator"
echo "SSH:   Enabled on port 22"
