# KubeVirt Storage Checkup Coverage

## Overview

The `kubevirt-storage-checkup` is a diagnostic tool that validates storage functionality for virtual machines in KubeVirt/OpenShift Virtualization environments. It uses the Kiagnose engine to perform a series of storage-related checks.

**Repository:** [Ahmad-Hafe/kubevirt-storage-checkup](https://github.com/Ahmad-Hafe/kubevirt-storage-checkup)

| Metric | Value |
|--------|-------|
| Check Categories | 11 |
| VM Operations Tested | 4 |
| Storage Features Validated | 8+ |

## Checks Performed

### 1. Version Detection

| Check | Description |
|-------|-------------|
| OCP Version | Detects OpenShift Container Platform version |
| CNV Version | Detects OpenShift Virtualization (CDI) version |

### 2. Default Storage Class Validation

| Check | Description | Error Condition |
|-------|-------------|-----------------|
| Default SC exists | Verifies a default storage class is configured | `no default storage class` |
| Single default SC | Ensures only one default storage class | `there are multiple default storage classes` |
| Virt default SC | Checks for `storageclass.kubevirt.io/is-default-virt-class` annotation | - |

### 3. PVC Creation and Binding

| Check | Description | Error Condition |
|-------|-------------|-----------------|
| PVC Creation | Creates a 10Mi blank DataVolume | Creation failure |
| PVC Binding | Verifies PVC binds within 1 minute | `pvc failed to bound` |

### 4. Storage Profiles Analysis

| Check | Result Field | Description |
|-------|--------------|-------------|
| Empty ClaimPropertySets | `storageProfilesWithEmptyClaimPropertySets` | Unknown provisioners |
| Spec-overridden | `storageProfilesWithSpecClaimPropertySets` | Manually configured profiles |
| Smart Clone Support | `storageProfilesWithSmartClone` | CSI clone or snapshot-based cloning |
| RWX Support | `storageProfilesWithRWX` | ReadWriteMany access mode |

### 5. VolumeSnapshotClass Validation

| Check | Result Field | Description |
|-------|--------------|-------------|
| Missing VSC | `storageProfileMissingVolumeSnapshotClass` | StorageProfiles using snapshot clone without VolumeSnapshotClass |

### 6. Golden Images Health

| Check | Result Field | Error Condition |
|-------|--------------|-----------------|
| DataImportCron status | `goldenImagesNotUpToDate` | DataImportCron not up-to-date or DataSource not ready |
| DataSource availability | `goldenImagesNoDataSource` | DataSource has no PVC or Snapshot source |

### 7. VMI Storage Configuration Audit

| Check | Result Field | Description |
|-------|--------------|-------------|
| Non-virt RBD SC | `vmsWithNonVirtRbdStorageClass` | VMs using plain RBD when virtualization SC exists |
| Unset EFS SC | `vmsWithUnsetEfsStorageClass` | VMs using EFS SC without uid/gid configured |

### 8. VM Boot from Golden Image

| Check | Result Field | Description |
|-------|--------------|-------------|
| VM Creation | `vmBootFromGoldenImage` | Creates VM from golden image PVC or Snapshot |
| Boot Verification | - | Waits for guest agent connection |
| Clone Type | `vmVolumeClone` | Reports: `snapshot`, `csi-clone`, or `host-assisted` |
| Clone Fallback | - | Reports fallback reason if not using smart clone |

### 9. VM Live Migration

| Check | Result Field | Description |
|-------|--------------|-------------|
| Migratable check | `vmLiveMigration` | Verifies VM has `IsMigratable` condition |
| Migration execution | - | Creates VirtualMachineInstanceMigration |
| Migration completion | - | Waits for migration to complete |

**Skip Conditions:**
- Single node cluster
- VM not migratable

### 10. VM Volume Hotplug

| Check | Result Field | Description |
|-------|--------------|-------------|
| Hotplug add | `vmHotplugVolume` | Adds volume to running VM |
| Volume ready | - | Waits for hotplug volume to be ready |
| Hotplug remove | - | Removes hotplugged volume |
| Volume removed | - | Verifies volume is removed |

### 11. Concurrent VM Boot

| Check | Result Field | Description |
|-------|--------------|-------------|
| Parallel boot | `concurrentVMBoot` | Boots N VMs simultaneously (default: 10) |
| All success | - | Verifies all VMs boot successfully |

**Configuration:** `spec.param.numOfVMs` (default: 10)

---

## GA Requirements Coverage Mapping

| GA Requirement | kubevirt-storage-checkup Coverage | Status |
|----------------|-----------------------------------|--------|
| **Linux VM** | ✅ VM Boot from Golden Image | Covered |
| **Windows VM** | ❌ Not tested | GAP |
| **Upload** | ❌ Not tested (uses golden images) | GAP |
| **Import (HTTP/registry)** | ❌ Not tested (uses golden images) | GAP |
| **Golden Images** | ✅ Golden Images Health Check + VM Boot | Covered |
| **20 VMs x 4 disks** | ⚠️ Concurrent VM Boot (configurable N, 1 disk) | Partial |
| **Snapshot** | ❌ Not tested | GAP |
| **Restore** | ❌ Not tested | GAP |
| **Clone** | ✅ VM Volume Clone (reports type) | Covered |
| **Host-assisted cloning** | ✅ Detected via clone fallback reason | Covered |
| **Compute Live migration** | ✅ VM Live Migration | Covered |
| **Storage live migration** | ❌ Not tested | GAP |
| **Hotplug/unplug** | ✅ VM Volume Hotplug | Covered |
| **Make permanent** | ❌ Not tested | GAP |
| **Volume expansion** | ❌ Not tested | GAP |

---

## Configuration Options

| Parameter | Description | Default |
|-----------|-------------|---------|
| `spec.timeout` | Checkup timeout | 10m |
| `spec.param.storageClass` | Storage class to use | Default SC |
| `spec.param.vmiTimeout` | VMI operation timeout | 3m |
| `spec.param.numOfVMs` | Number of concurrent VMs | 10 |
| `spec.param.skipTeardown` | Skip cleanup (`always`, `onfailure`, `never`) | `never` |

---

## Result Fields Summary

| Result Field | Type | Description |
|--------------|------|-------------|
| `status.succeeded` | bool | Overall checkup success |
| `status.failureReason` | string | Failure details |
| `status.result.cnvVersion` | string | CNV version |
| `status.result.ocpVersion` | string | OCP version |
| `status.result.defaultStorageClass` | string | Default SC name or error |
| `status.result.pvcBound` | string | PVC binding result |
| `status.result.storageProfilesWithEmptyClaimPropertySets` | string | SPs with unknown provisioners |
| `status.result.storageProfilesWithSpecClaimPropertySets` | string | SPs with manual config |
| `status.result.storageProfilesWithSmartClone` | string | SPs with smart clone |
| `status.result.storageProfilesWithRWX` | string | SPs with RWX support |
| `status.result.storageProfileMissingVolumeSnapshotClass` | string | SPs missing VSC |
| `status.result.goldenImagesNotUpToDate` | string | Stale golden images |
| `status.result.goldenImagesNoDataSource` | string | Golden images without DataSource |
| `status.result.vmsWithNonVirtRbdStorageClass` | string | VMs on non-virt RBD |
| `status.result.vmsWithUnsetEfsStorageClass` | string | VMs on misconfigured EFS |
| `status.result.vmBootFromGoldenImage` | string | Boot test result |
| `status.result.vmVolumeClone` | string | Clone type used |
| `status.result.vmLiveMigration` | string | Migration test result |
| `status.result.vmHotplugVolume` | string | Hotplug test result |
| `status.result.concurrentVMBoot` | string | Concurrent boot result |

---

## Comparison: kubevirt-storage-checkup vs ocp-virt-validation-checkup

| Feature | kubevirt-storage-checkup | ocp-virt-validation-checkup |
|---------|--------------------------|------------------------------|
| **Purpose** | Quick health check | Comprehensive E2E test suite |
| **Test Type** | Diagnostic checks | Full E2E tests from KubeVirt |
| **Runtime** | Minutes | Hours (FULL_SUITE) |
| **Golden Images** | Health check only | Full DataVolume tests |
| **Snapshot/Restore** | ❌ | ✅ |
| **Volume Expansion** | ❌ | ✅ |
| **Clone Types** | Reports type used | Full clone testing |
| **Windows** | ❌ | ❌ |
| **Concurrent VMs** | ✅ Configurable | ✅ Fixed (5 VMIs) |
| **Storage Migration** | ❌ | ✅ (FULL_SUITE) |

---

## Gaps for GA Criteria

The following GA requirements are **NOT covered** by kubevirt-storage-checkup:

1. **Windows VM** - No Windows testing
2. **Upload/Import** - Uses existing golden images only
3. **Snapshot/Restore operations** - Not tested
4. **Storage live migration** - Not tested
5. **Make permanent (hotplug persist)** - Not tested
6. **Volume expansion** - Not tested
7. **Multi-disk scenarios (4 disks)** - VMs have 1 disk
8. **Timing assertions** - No performance benchmarks

---

## Usage

```bash
# Apply permissions
kubectl apply -n <namespace> -f manifests/storage_checkup_permissions.yaml

# Run checkup
export CHECKUP_NAMESPACE=<namespace>
envsubst < manifests/storage_checkup.yaml | kubectl apply -f -

# Get results
kubectl get configmap storage-checkup-config -n <namespace> -o yaml

# Cleanup
envsubst < manifests/storage_checkup.yaml | kubectl delete -f -
```

---

## Source Code Reference

| File | Purpose |
|------|---------|
| `pkg/internal/checkup/checkup.go` | Main checkup logic (~1174 lines) |
| `pkg/internal/checkup/vmi.go` | VMI spec generation |
| `pkg/internal/status/status.go` | Result structure definition |
| `pkg/internal/config/config.go` | Configuration handling |
