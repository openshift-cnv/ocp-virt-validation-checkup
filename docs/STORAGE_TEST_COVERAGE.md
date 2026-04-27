# Storage Test Coverage

## Overview

| Metric | Count |
|--------|-------|
| Total sig-storage Tests | 314 |
| Test Categories | 15 |
| Supported Storage Providers | 17 |
| Quarantined Tests | ~20 |

## Test Selection Criteria

- **Default Mode:** `(sig-storage && conformance) || StorageCritical`
- **Full Suite Mode:** `sig-storage || StorageCritical`

---

## Test Categories

### 1. DataVolume Integration (~50 tests)

DataVolume is a custom resource that automates the import, clone, and upload of data into PVCs for use with VMs.

| Test | Test ID | Description |
|------|---------|-------------|
| Alpine import - start and stop multiple times | test_id:3189 | Validates that a VM using a DataVolume with an imported Alpine image can be started and stopped repeatedly without data corruption |
| Alpine import - start multiple concurrent VMIs | test_id:6686 | Tests that multiple VMs can simultaneously use DataVolumes from the same source image |
| Alpine import - using PVC owned by DataVolume | test_id:5252 | Verifies VM can start using a PVC that was created/managed by a DataVolume |
| Aggregate DV conditions from many DVs | - | Ensures VM status correctly reflects conditions from multiple attached DataVolumes |
| PVC from DV - VM template with DataVolume | test_id:4643 | Tests that VM templates can reference DataVolumes while VMs use the resulting PVC |
| Invalid DV - stop VM if DV is crashing | - | Validates graceful handling when DataVolume import fails (e.g., bad URL) |
| Invalid DV - handle invalid DataVolumes | test_id:3190 | Tests error handling for malformed or invalid DataVolume specs |
| oc/kubectl - Create VM with DataVolumeTemplates | test_id:836 | Tests VM creation with inline DataVolumeTemplate definitions via CLI |
| oc/kubectl - cascade=true deletes DVs | test_id:837 | Verifies that deleting VM with cascade=true also deletes owned DataVolumes |
| oc/kubectl - cascade=false orphans DVs | test_id:838 | Verifies that deleting VM with cascade=false preserves DataVolumes |
| HTTP import - start and stop multiple times | test_id:3191 | Tests DataVolume HTTP import source with repeated VM lifecycle operations |
| HTTP import - orphan delete removes owner refs | test_id:3192 | Validates owner reference cleanup when VM is orphan-deleted |
| Clone permission - resolve sourceRef with PVC | - | Tests DataVolume clone authorization using PVC as source reference |
| Clone permission - resolve sourceRef with Snapshot | - | Tests DataVolume clone authorization using VolumeSnapshot as source |
| Clone permission - report missing source PVC | - | Validates proper error reporting when clone source PVC doesn't exist |
| Clone - deny then allow with explicit role | test_id:3193 | Tests RBAC: clone fails without permission, succeeds after granting explicit role |
| Clone - deny then allow with implicit role | test_id:3194 | Tests RBAC: clone succeeds with namespace-level implicit permissions |
| Clone - explicit role (all namespaces) | test_id:5253 | Tests cluster-wide clone permission via ClusterRole |
| Clone - explicit role (one namespace) | test_id:5254 | Tests namespace-scoped clone permission via Role |
| Fedora fstrim - makes image smaller | test_id:5894 | Verifies that fstrim command in guest reclaims unused space in thin-provisioned disks |
| Fedora fstrim - preallocation disables trim | test_id:5898 | Validates that preallocated disks don't shrink with fstrim |
| PVC expansion - Block PVC | - | Tests online volume expansion for block-mode PVCs attached to running VMs |
| PVC expansion - Filesystem PVC | - | Tests online volume expansion for filesystem PVCs attached to running VMs |
| Disk expansion - actual usable size | - | Verifies that reported disk size matches actual usable capacity after expansion |
| [Serial] without fsgroup support | - | Tests VM startup with storage that doesn't support fsGroup (e.g., NFS) |
| [Serial] GC enabled | test_id:8567 | Tests automatic garbage collection of succeeded DataVolumes when feature is enabled |
| [Serial] GC disabled then enabled | test_id:8571 | Tests enabling GC after VM creation and annotating existing DVs for cleanup |

### 2. Volume Hotplug (~40 tests)

Hotplug allows dynamically attaching and detaching storage volumes to running VMs without requiring a restart.

| Test | Test ID | Description |
|------|---------|-------------|
| Add/remove DataVolume immediate | - | Tests hotplugging a DataVolume to a running VM with immediate attachment |
| Add/remove PersistentVolume immediate | - | Tests hotplugging an existing PVC to a running VM with immediate attachment |
| Add/remove DV wait for VM ready | - | Tests hotplug that waits for VM to be fully running before attaching |
| Add/remove PV wait for VM ready | - | Tests PVC hotplug that waits for VM readiness |
| Add/remove DV to VMI directly | - | Tests hotplug via VirtualMachineInstance API (bypassing VM controller) |
| Add/remove PV to VMI directly | - | Tests PVC hotplug directly to VMI object |
| Add/remove Block DataVolume | - | Tests hotplugging block-mode volumes (raw block device in guest) |
| Dry run - no actual changes | - | Validates dry-run flag prevents actual hotplug operations |
| Multiple volumes with VMs | - | Tests adding/removing several volumes in sequence to a VM |
| Multiple volumes with VMIs | - | Tests multi-volume hotplug operations directly on VMI |
| Multiple volumes with block | - | Tests hotplugging multiple block-mode volumes |
| Add, remove, re-add volumes | - | Validates volume can be re-attached after being removed |
| Hotplug 75 volumes simultaneously | - | Stress test: validates system handles large number of concurrent hotplug operations |
| Permanent hotplug to VM | - | Tests making a hotplugged volume permanent (persists across restarts) |
| Reject duplicate volume name | - | Validates error when trying to hotplug volume with existing name |
| Reject same volume different name | - | Validates error when same underlying volume is attached twice |
| Reject removing non-hotplugged volume | - | Ensures original VM volumes cannot be removed via hotplug API |
| Reject removing non-existent volume | - | Validates proper error for removing volume that doesn't exist |
| Hotplug filesystem and block together | - | Tests mixing filesystem and block volumes on same VM |
| Live migration with hotplug (containerDisk) | - | Validates hotplugged volumes migrate correctly with containerDisk VMs |
| Live migration with hotplug (persistent disk) | - | Validates hotplugged volumes migrate correctly with persistent storage |
| [Serial] LUN disk on offline VM | - | Tests hotplugging a LUN (raw SCSI) disk to a stopped VM |
| [Serial] LUN disk on online VM | - | Tests hotplugging a LUN disk to a running VM |
| Limit range - 1:1 cpu and mem ratio | test_id:10002 | Tests hotplug respects namespace LimitRange with equal cpu/mem ratios |
| Limit range - 1:1 mem, 4:1 cpu ratio | test_id:10003 | Tests hotplug with asymmetric cpu/memory limit ratios |
| Limit range - 2:1 mem, 4:1 cpu ratio | test_id:10004 | Tests hotplug pod resource allocation with specific ratios |
| Limit range - 2.25:1 mem, 5.75:1 cpu ratio | test_id:10005 | Tests hotplug with non-integer limit ratios |
| Hostpath volume hotplug | - | Tests hotplugging hostpath-provisioned volumes |
| iothreads with hotplug | - | Tests hotplug works correctly when VM uses dedicated IO threads |
| [Serial] Block access after virt-handler crash | - | Validates block device access survives virt-handler pod restart |

### 3. VM Snapshots (~30 tests)

VM Snapshots capture the state of a VM's disks at a point in time for backup and recovery.

| Test | Test ID | Description |
|------|---------|-------------|
| Create snapshot without DV GC | test_id:4611 | Tests snapshot creation when DataVolume garbage collection is disabled |
| Create snapshot with DV GC | test_id:8668 | Tests snapshot creation works correctly even when DVs are garbage collected |
| Include backend PVC in snapshot | - | Validates that independent DataVolume PVCs are included in VM snapshot |

### 4. VM Restore (~25 tests)

VM Restore recovers a VM to a previous state from a snapshot.

| Test | Test ID | Description |
|------|---------|-------------|
| Reject restore without snapshot | test_id:5255 | Validates restore fails gracefully when referenced snapshot doesn't exist |
| Restore VM with run strategy | - | Tests restore works with VMs using RunStrategy instead of Running field |
| Restore with good snapshot | test_id:5256 | Basic restore test: stopped VM restored from valid snapshot |
| Reject restore if VM running | test_id:5257 | Validates restore is blocked while VM is running (must stop first) |
| Reject restore if another in progress | test_id:5258 | Prevents concurrent restore operations on same VM |
| Fail restore to existing different VM | - | Validates restore to new VM fails if target name already exists |
| Restore to new VM with new MAC | - | Tests restore creates new VM with unique MAC address |
| Use existing ControllerRevisions (running) | - | Tests instancetype/preference restoration preserves revisions for running VM |
| Use existing ControllerRevisions (stopped) | - | Tests instancetype/preference restoration preserves revisions for stopped VM |
| Create new ControllerRevisions (running) | - | Tests restore to new VM creates fresh instancetype revisions |
| Create new ControllerRevisions (stopped) | - | Tests restore to new VM creates fresh preference revisions |
| Restore multiple times from same snapshot | test_id:5259 | Validates single snapshot can be used for multiple restore operations |
| Restore with larger size (same VM) | - | Tests restore when snapshot was smaller than current PVC |
| Restore with larger size (new VM) | - | Tests restore to new VM handles size differences |
| Restore from DataVolumeTemplate (same VM) | test_id:5260 | Tests restore of VM that uses inline DataVolumeTemplate |
| Restore from DataVolumeTemplate (new VM) | - | Tests restore to new VM from DataVolumeTemplate-based source |
| Restore from DataVolume (same VM) | test_id:5261 | Tests restore of VM using separate DataVolume reference |
| Restore from DataVolume (new VM) | - | Tests restore to new VM from DataVolume-based source |
| Restore from PVC (same VM) | test_id:5262 | Tests restore of VM directly referencing PVC |
| Restore from PVC (new VM) | - | Tests restore to new VM from PVC-based source |
| Restore with containerDisk + blank DV (same) | test_id:5263 | Tests restore of mixed storage: containerDisk + blank DataVolume |
| Restore with containerDisk + blank DV (new) | - | Tests restore to new VM with mixed storage types |
| Reject start during restore, allow after | - | Validates VM cannot start during restore but can after completion |
| Reject start during restore, allow after delete | - | Validates VM can start after restore object is deleted |
| Restore from online snapshot (same VM) | test_id:6053 | Tests restore from snapshot taken while VM was running |
| Restore from online snapshot (new VM) | - | Tests restore to new VM from online snapshot |
| Restore from online snapshot with guest agent | test_id:6766 | Tests restore from crash-consistent snapshot (guest agent quiesced) |
| Restore with backend storage (offline) | - | Tests restore of VM using backend storage from offline snapshot |
| Restore with backend storage (online) | - | Tests restore of VM using backend storage from online snapshot |

### 5. VM Clone (~15 tests)

VM Clone creates a copy of an existing VM with new identity.

| Test | Test ID | Description |
|------|---------|-------------|
| Reject non-snapshotable volume (VM source) | - | Validates clone fails if VM has volumes that can't be snapshotted |
| Reject non-snapshotable volume (snapshot source) | - | Validates clone fails if snapshot contains non-snapshotable volumes |
| Simple clone with snapshot storage class | - | Basic clone test using storage class that supports snapshots |
| Clone with instancetype (running VM) | - | Tests clone preserves instancetype configuration from running source |
| Clone with instancetype (stopped VM) | - | Tests clone preserves instancetype configuration from stopped source |
| Double cloning (clone from clone) | - | Validates a cloned VM can itself be used as a clone source |
| WFFC - wait for PVCs to bind | - | Tests clone with WaitForFirstConsumer doesn't delete resources prematurely |

### 6. Image Upload - virtctl (~15 tests)

virtctl image-upload allows uploading local disk images directly into PVCs.

| Test | Test ID | Description |
|------|---------|-------------|
| Upload and start VMI - DataVolume | test_id:4621 | Tests uploading image via virtctl, creating DV, and starting VM |
| Upload and start VMI - PVC | test_id:4621 | Tests uploading image via virtctl directly to PVC and starting VM |
| Force-bind flag - DataVolume | - | Tests --force-bind flag to immediately bind WFFC DataVolumes |
| Force-bind flag - PVC | - | Tests --force-bind flag to immediately bind WFFC PVCs |
| Block volumeMode | test_id:10671 | Tests uploading to block-mode volume |
| Filesystem volumeMode | test_id:10672 | Tests uploading to filesystem-mode volume |
| Invalid volume-mode fails | test_id:10674 | Validates proper error for unsupported volume-mode value |
| WFFC/PendingPopulation handling | - | Tests upload waits for consumer when using WFFC storage class |
| Archive volume - DataVolume | - | Tests uploading compressed archive to DataVolume |
| Archive volume - PVC | - | Tests uploading compressed archive to PVC |
| Fail - non-existent storageClass (DV) | - | Validates proper error when specified StorageClass doesn't exist |
| Fail - non-existent storageClass (PVC) | - | Validates proper error for PVC with missing StorageClass |
| Fail - DV provisioning fails | - | Tests error handling when DataVolume provisioning encounters errors |
| Fail - PVC provisioning fails | - | Tests error handling when PVC provisioning encounters errors |

### 7. Memory Dump (~12 tests)

Memory dump captures the RAM contents of a running VM for debugging or forensics.

| Test | Test ID | Description |
|------|---------|-------------|
| Get and remove - API endpoint | test_id:8499 | Tests triggering memory dump via direct API call and cleanup |
| Get and remove - virtctl | test_id:8500 | Tests triggering memory dump via `virtctl memory-dump` command |
| Multiple dumps | test_id:8502 | Tests taking multiple memory dumps in sequence |
| Dump to different PVCs | test_id:8503 | Tests dumping to one PVC, removing, then dumping to another |
| Dump, stop VM, remove dump | test_id:8506 | Tests cleanup of memory dump after VM is stopped |
| Dump, stop VM, start VM | test_id:8515 | Tests VM can restart after memory dump operation |
| Fail - PVC too small | test_id:8501 | Validates proper error when target PVC can't fit memory dump |
| Create PVC - get and remove | test_id:9034 | Tests memory dump with auto-created PVC |
| Create PVC - multiple dumps | test_id:9035 | Tests multiple dumps with auto-created PVCs |
| Create different PVCs | test_id:9036 | Tests creating multiple different PVCs for successive dumps |
| Remove stuck dump | test_id:9341 | Tests cleanup of memory dump that got stuck/failed |
| Download dump | test_id:9344 | Tests downloading memory dump contents after creation |
| Download existing dump | test_id:9343 | Tests downloading a previously created memory dump |

### 8. VirtIO-FS (~8 tests)

VirtIO-FS provides high-performance filesystem sharing between host and VM.

| Test | Test ID | Description |
|------|---------|-------------|
| Multiple PVCs - privileged virtiofsd | - | Tests sharing multiple PVCs with root virtiofsd process |
| Multiple PVCs - unprivileged virtiofsd | - | Tests sharing multiple PVCs with non-root virtiofsd |
| Empty PVC - unprivileged | - | Tests initializing and sharing an empty PVC (non-root) |
| Empty PVC - privileged | - | Tests initializing and sharing an empty PVC (root) |
| DataVolume - unprivileged | - | Tests VirtIO-FS with DataVolume-backed storage (non-root) |
| DataVolume - privileged | - | Tests VirtIO-FS with DataVolume-backed storage (root) |

### 9. Volume Migration (~15 tests)

Volume migration moves VM storage from one volume to another while the VM is running.

| Test | Test ID | Description |
|------|---------|-------------|
| DV to PVC - filesystem | - | Migrates DataVolume to PVC maintaining filesystem mode |
| DV to PVC - block | - | Migrates DataVolume to PVC maintaining block mode |
| DV to DV | - | Migrates from one DataVolume to another DataVolume |
| RWX block DVs | - | Migrates between ReadWriteMany block volumes |
| Block source to filesystem dest | - | Tests migration with volume mode conversion |
| PVC with containerdisk VM | - | Tests volume migration for VM that also uses containerDisk |
| Cancel by reverting | - | Tests canceling migration returns to original volume |
| Fail - destination too small | - | Validates migration fails if target volume is smaller |
| Restart condition for RWO | - | Tests proper handling when RWO volume can't migrate |
| ManualRecoveryRequired on shutdown | - | Tests recovery mode when migration fails at shutdown |
| Cancel and clear state | - | Tests clean cancellation clears migration state |
| Recover from interrupted migration | - | Tests resuming migration after interruption |
| Hotplug + persistent volume | - | Tests migration compatibility with volume hotplug (persistent) |
| Hotplug + ephemeral volume | - | Tests migration compatibility with volume hotplug (ephemeral) |
| Migrate hotplugged volume | - | Tests migrating a volume that was hotplugged |

### 10. Export (~10 tests)

VM Export creates downloadable archives of VM disks.

| Test | Test ID | Description |
|------|---------|-------------|
| Export with swtpm directories | - | Validates TPM state directories are included in export archive |
| Ingress with external links | - | Tests export route/ingress exposes correct download URLs |
| Limit range - PVC in use handling | - | Tests export waits when PVC is in use, starts when available |
| Recreate pod on cert update | - | Tests export server pod recreates when KubeVirt certs change |

### 11. SCSI Persistent Reservation (~5 tests)

SCSI PR enables shared storage clustering (e.g., for Windows Failover Clustering).

| Test | Test ID | Description |
|------|---------|-------------|
| Single VM with PR | - | Tests VM can use SCSI persistent reservation on LUN |
| Two VMs sharing LUN with PR | - | Tests two VMs can coordinate access to shared LUN via PR |
| Feature gate toggle | - | Tests enabling/disabling PR feature gate recreates virt-handler |

### 12. Storage Error Handling (~10 tests)

Tests for proper handling of storage failures and edge cases.

| Test | Test ID | Description |
|------|---------|-------------|
| Pause VMI on IO error | - | Tests VM pauses (not crashes) when disk IO error occurs |
| Report IO errors with errorPolicy | - | Tests IO errors are reported to guest when errorPolicy=report |
| K8s IO error event | test_id:6225 | Validates Kubernetes events are generated for storage IO errors |
| NFS with IPv6 | - | Tests VM with NFS storage accessed via IPv6 address |
| NFS with IPv4 (not qemu owned) | - | Tests NFS storage with different ownership configuration |
| HostDisk disabled - fail to start | test_id:4620 | Validates VM fails gracefully when HostDisk feature is disabled |
| PVC too small even with tolerance | test_id:3108 | Tests disk.img isn't created if PVC is too small even with slack |
| PVC small but within tolerance | test_id:3109 | Tests disk.img creation when PVC is small but acceptable |
| LUN disk - PVC source | - | Tests running VM with LUN disk backed by PVC |
| LUN disk - DataVolume source | - | Tests running VM with LUN disk backed by DataVolume |

### 13. Backend Storage

Tests for backend storage selection logic.

| Test | Test ID | Description |
|------|---------|-------------|
| Use RWO when RWX not supported | - | Validates fallback to RWO access mode when RWX unavailable |

---

## Storage Capabilities

Tests are filtered based on these storage capabilities:

| Capability | Description | Tests Affected |
|------------|-------------|----------------|
| `storageClassRhel` | Storage class for RHEL-based VMs | VM boot tests |
| `storageClassWindows` | Storage class for Windows VMs | Windows VM tests |
| `storageRWXBlock` | ReadWriteMany Block volume | Live migration, shared disk tests |
| `storageRWXFileSystem` | ReadWriteMany Filesystem | NFS, shared filesystem tests |
| `storageRWOFileSystem` | ReadWriteOnce Filesystem | Standard VM disk tests |
| `storageRWOBlock` | ReadWriteOnce Block | Raw block device tests |
| `storageClassCSI` | CSI driver storage class | CSI-specific features |
| `storageSnapshot` | Volume snapshot support | Snapshot, clone, restore tests |
| `onlineResize` | Online volume resize | PVC expansion tests |
| `WFFC` | WaitForFirstConsumer mode | Topology-aware provisioning tests |

### Dynamic Test Filtering

| Condition | Filter Applied | Effect |
|-----------|----------------|--------|
| No block storage (RWO/RWX) | `(!RequiresBlockStorage)` | Skips all block volume tests |
| Storage class not WFFC | `(!RequiresWFFCStorageClass)` | Skips WFFC-specific tests |

---

## Supported Storage Providers

| Provider | Capabilities | Best For |
|----------|--------------|----------|
| OCS (Virtualization) | RWX Block, RWO FS, RWO Block, Snapshot, CSI | Production CNV deployments |
| OCS RBD | RWX Block, RWO FS, RWO Block, Snapshot, CSI | High-performance block storage |
| OCS CephFS | RWX FS, Snapshot, CSI | Shared filesystem workloads |
| OCS WFFC | All OCS + WFFC | Topology-constrained clusters |
| LVMS | RWO FS, RWO Block, Snapshot, CSI | Single-node/edge deployments |
| NFS | RWX FS, RWO FS | Simple shared storage |
| HPP | RWO FS, RWO Block, Snapshot, CSI | Development/testing |
| HPP CSI Block | RWO FS, RWO Block, Snapshot, CSI | Local block storage |
| Portworx | RWX Block, RWO FS, RWO Block, Snapshot, CSI | Enterprise storage |
| AWS GP3 | RWO FS, RWO Block, Snapshot, CSI | AWS cloud deployments |
| AWS IO2 | RWO FS, RWO Block, Snapshot, CSI | High-IOPS AWS workloads |
| AWS FSx | RWX FS, RWO FS, Snapshot, CSI | AWS shared filesystem |
| Google HyperDisk | RWO FS, RWO Block, Snapshot, CSI | GCP high-performance |
| Google Cloud NetApp | RWX FS, RWO FS, Snapshot, CSI | GCP shared filesystem |
| GPFS | RWX FS, RWO FS, RWO Block, Snapshot, CSI | IBM enterprise storage |

---

## Quarantined Tests (sig-storage)

| Test ID | Reason | Tracking |
|---------|--------|----------|
| test_id:5360 | IO modes not configurable downstream | CNV-46717 |
| rfe_id:3106 | Bulk Quarantine | CNV-46717 |
| test_id:3190 | Bulk Quarantine | CNV-46717 |
| test_id:10818 | Bulk Quarantine | CNV-46717 |
| test_id:3134 | Bulk Quarantine | CNV-46717 |
| test_id:3109 | Bulk Quarantine | CNV-46717 |
| test_id:3131 | Bulk Quarantine | CNV-46717 |
| test_id:3137 | Bulk Quarantine | CNV-46717 |
| test_id:10819 | Bulk Quarantine | CNV-46717 |
| test_id:4620 | Host disk not supported d/s | CNV-46717 |
| test_id:851 | Host disk not supported d/s | CNV-46717 |
| test_id:2306 | Host disk not supported d/s | CNV-46717 |
| test_id:868 | Bulk Quarantine | CNV-46717 |
| test_id:3133 | Bulk Quarantine | CNV-46717 |
| test_id:1681 | Host disk not supported d/s | CNV-46717 |
| test_id:3130 | Bulk Quarantine | CNV-46717 |

---

## Permanently Skipped Tests

| Pattern | Reason |
|---------|--------|
| test_id:4620, 851, 852, 3107, 3057, 847, 2306, 1681 | Host disk not supported downstream |
| Should set BlockIO when set to match volume block sizes on files | HostDisk not supported d/s |
| should migrate with a shared ConfigMap | VirtIO-FS not supported d/s |
| Hotplug delete attachment pod several times should remain active | CNV-44793 |

---

## Running Storage Tests

```bash
# Run storage suite only
podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} \
  -e TEST_SUITES=storage \
  ${OCP_VIRT_VALIDATION_IMAGE} generate | oc apply -f -

# Dry run to see which tests will execute
podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} \
  -e TEST_SUITES=storage \
  -e DRY_RUN=true \
  ${OCP_VIRT_VALIDATION_IMAGE} generate | oc apply -f -

# Custom storage class with capabilities
podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} \
  -e STORAGE_CLASS=my-custom-sc \
  -e STORAGE_CAPABILITIES=storageRWOBlock,storageSnapshot,onlineResize \
  ${OCP_VIRT_VALIDATION_IMAGE} generate
```
