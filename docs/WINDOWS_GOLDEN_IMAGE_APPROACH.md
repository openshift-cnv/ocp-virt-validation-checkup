# Windows Golden Image Creation via Tekton Pipeline

## Overview

This document describes the approach for creating Windows 11 golden images using the `windows-efi-installer` Tekton pipeline, suitable for self-validation Windows storage tests.

## Prerequisites

- OpenShift Virtualization installed
- OpenShift Pipelines (Tekton) installed
- User accepts Microsoft EULA (legal requirement - must be human decision)

## The Approach

### 1. Install the Pipeline

```bash
oc apply -f https://artifacthub.io/packages/tekton-pipeline/redhat-pipelines/windows-efi-installer
```

Or from kubevirt-tekton-tasks:
```bash
oc apply -f https://github.com/kubevirt/kubevirt-tekton-tasks/releases/download/v0.22.0/windows-efi-installer.yaml
```

### 2. Apply the Fixed ConfigMap (Windows 11 Specific)

The default autounattend.xml does NOT fully automate Windows 11 OOBE. Windows 11 requires a `BypassNRO` registry setting to skip the mandatory network requirement.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: windows11-autounattend
data:
  autounattend.xml: |
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
          <InputLocale>en-US</InputLocale>
          <SystemLocale>en-US</SystemLocale>
          <UILanguage>en-US</UILanguage>
          <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <DriverPaths>
            <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>E:\viostor\w11\amd64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\NetKVM\w11\amd64</Path></PathAndCredentials>
          </DriverPaths>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <DiskConfiguration>
            <WillShowUI>Never</WillShowUI>
            <Disk wcm:action="add">
              <CreatePartitions>
                <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>100</Size></CreatePartition>
                <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
              </CreatePartitions>
              <ModifyPartitions>
                <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Label>EFI</Label><Format>FAT32</Format></ModifyPartition>
                <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Label>Windows</Label><Letter>C</Letter><Format>NTFS</Format></ModifyPartition>
              </ModifyPartitions>
              <DiskID>0</DiskID>
              <WillWipeDisk>true</WillWipeDisk>
            </Disk>
          </DiskConfiguration>
          <ImageInstall>
            <OSImage>
              <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom>
              <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
            </OSImage>
          </ImageInstall>
          <UserData>
            <AcceptEula>true</AcceptEula>
            <FullName>Admin</FullName>
            <Organization>Test</Organization>
          </UserData>
        </component>
      </settings>
      
      <!-- KEY FIX: BypassNRO in specialize pass (runs BEFORE OOBE) -->
      <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add">
              <Order>1</Order>
              <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
              <Description>Bypass Windows 11 Network Requirement</Description>
            </RunSynchronousCommand>
          </RunSynchronous>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <ComputerName>WinTest</ComputerName>
          <TimeZone>UTC</TimeZone>
        </component>
      </settings>
      
      <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <UserAccounts>
            <LocalAccounts>
              <LocalAccount wcm:action="add">
                <Password><Value>Admin123!</Value><PlainText>true</PlainText></Password>
                <Group>Administrators</Group>
                <DisplayName>Admin</DisplayName>
                <Name>Admin</Name>
              </LocalAccount>
            </LocalAccounts>
          </UserAccounts>
          <AutoLogon>
            <Enabled>true</Enabled>
            <Password><Value>Admin123!</Value><PlainText>true</PlainText></Password>
            <Username>Admin</Username>
            <LogonCount>999</LogonCount>
          </AutoLogon>
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
              <CommandLine>powershell -ExecutionPolicy Bypass -Command "Start-Process msiexec -Wait -ArgumentList '/i E:\virtio-win-gt-x64.msi /qn /passive /norestart'"</CommandLine>
              <Description>Install VirtIO drivers</Description>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>2</Order>
              <CommandLine>powershell -ExecutionPolicy Bypass -Command "Start-Process msiexec -Wait -ArgumentList '/i E:\guest-agent\qemu-ga-x86_64.msi /qn /passive /norestart'"</CommandLine>
              <Description>Install QEMU Guest Agent</Description>
            </SynchronousCommand>
          </FirstLogonCommands>
        </component>
      </settings>
    </unattend>
  post-install.ps1: |
    Write-Host "Post-install complete"
```

### 3. Create the PipelineRun

```yaml
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  generateName: windows11-golden-
spec:
  pipelineRef:
    name: windows-efi-installer
  params:
    - name: winImageDownloadURL
      value: "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENT_CONSUMER_x64FRE_en-us.iso"
    - name: acceptEula
      value: "true"
    - name: baseDvName
      value: "windows11-golden-image"
    - name: baseDvNamespace
      value: "YOUR_NAMESPACE"
    - name: isoDVName
      value: "windows11-iso"
    - name: virtioContainerDiskName
      value: "quay.io/kubevirt/virtio-container-disk:v1.3.0"
    - name: autounattendConfigMapName
      value: "windows11-autounattend"
    - name: instanceTypeName
      value: "u1.2xlarge"
    - name: instanceTypeKind
      value: "VirtualMachineClusterInstancetype"
    - name: preferenceName
      value: "windows.11.virtio"
    - name: preferenceKind
      value: "VirtualMachineClusterPreference"
```

## The Key Fix Explained

### Problem
Windows 11 mandates internet connectivity during OOBE to force Microsoft account sign-in. Standard `<HideOnlineAccountScreens>true</HideOnlineAccountScreens>` doesn't bypass this.

### Solution
Add `BypassNRO` registry key in the `specialize` pass (runs BEFORE OOBE):

```xml
<settings pass="specialize">
  <component name="Microsoft-Windows-Deployment">
    <RunSynchronous>
      <RunSynchronousCommand>
        <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
      </RunSynchronousCommand>
    </RunSynchronous>
  </component>
</settings>
```

This is equivalent to the manual workaround: `Shift+F10 → oobe\bypassnro`

## Result

VM boots directly to desktop with:
- Local account: `Admin`
- Password: `Admin123!`
- VirtIO drivers installed
- QEMU guest agent installed
- No manual intervention required

## Timeline

Full pipeline run: ~40-50 minutes
- ISO download: ~17 min (6GB file)
- ISO modification: ~15 min
- Windows installation: ~15-20 min

## Self-Validation Integration (TODO)

1. User accepts MS EULA (parameter)
2. Self-validation triggers Tekton pipeline with fixed ConfigMap
3. Pipeline creates Windows golden image (DataVolume)
4. Windows storage tests clone from the golden image

## References

- Tekton Pipeline: https://artifacthub.io/packages/tekton-pipeline/redhat-pipelines/windows-efi-installer
- kubevirt-tekton-tasks: https://github.com/kubevirt/kubevirt-tekton-tasks
- Windows ISO URL (stable): https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENT_CONSUMER_x64FRE_en-us.iso
