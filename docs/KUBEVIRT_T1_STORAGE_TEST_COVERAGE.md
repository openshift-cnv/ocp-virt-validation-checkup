# KubeVirt T1 Storage Test Coverage

## Overview

This document catalogs the T1 (unit) tests for the storage component in the KubeVirt repository. T1 tests are fast, isolated unit tests that don't require a running cluster.

| Metric | Count |
|--------|-------|
| Total Storage Unit Tests | ~750+ |
| Test Categories | 25 |
| Source Packages | 24 |

## Test Location

All T1 storage tests are located in the `pkg/` directory:

```
pkg/storage/              # Core storage controllers and types
pkg/container-disk/       # Container disk handling
pkg/emptydisk/            # Empty disk management
pkg/ephemeral-disk/       # Ephemeral PVC-backed disks
pkg/host-disk/            # Host path disk handling
pkg/hotplug-disk/         # Hotplug disk paths
pkg/virt-handler/         # Handler-side storage operations
pkg/virt-launcher/        # Launcher-side storage operations
pkg/virt-controller/      # Controller-side volume migration
```

---

## Test Categories

### 1. Storage Admitters (~150 tests)

Webhook admission validation for storage-related resources.

**Location:** `pkg/storage/admitters/`

#### Disk Validation (`disks_test.go`)

| Test | Description |
|------|-------------|
| should accept valid disks (Disk/LUN/CDRom targets) | Validates single target per disk type |
| should allow disk without a target | Missing target defaults with matching volume |
| should reject disks with duplicate names | Two disks with same name |
| should reject disks with SATA and read-only set | SATA + read-only incompatible |
| should reject disks with PCI address on non-virtio bus | PCI address only with virtio |
| should reject disks with malformed PCI addresses | Invalid PCI string format |
| should reject disk with multiple targets | Disk + CDRom both set |
| should accept/reject boot order (>0 valid, 0 invalid) | Boot order validation |
| should accept disks with supported buses | virtio, SATA, SCSI, USB, default |
| should reject disks with unsupported I/O modes | Invalid io values |
| should reject disk with invalid cache mode | Bad cache value |
| should accept valid cache modes (none/writethrough/writeback) | Allowed cache enums |
| should reject/accept errorPolicy values | Valid: stop, report, ignore, enospace |
| should reject invalid SN characters/length | Serial number validation |
| should reject DedicatedIOThread with non-virtio bus | Dedicated IO thread requires virtio |
| should validate BlockSize (power-of-two, logical ≤ physical) | Custom block size limits |

#### Storage Hotplug Admitter (`storagehotplug_test.go`)

| Test | Description |
|------|-------------|
| Should properly calculate hotplug volumes | getHotplugVolumes from VolumeStatus |
| Should properly calculate permanent volumes | getPermanentVolumes subset |
| Should return proper admission response | Volume/disk count parity validation |
| Should reject permanent volume removal | Permanent volumes cannot be hotplug-removed |
| Should reject disk without volume | Disk must have matching volume |
| Should reject mutating permanent disk | Permanent disks are immutable |
| Should validate virtio bus for hotplug | Bus type restrictions |
| Should validate IOThreads + virtio | IOThreads require virtio |
| Should validate LUN SCSI | LUN requires SCSI bus |
| Should validate CD-ROM inject/eject | CD-ROM hotplug rules |
| Should reject boot order 0 | Invalid boot order |
| Should allow migrated volume claim changes | PVC claim change allowed for migrated volumes |

#### Utility Volumes Admitter

| Test | Description |
|------|-------------|
| should accept valid utility volumes on creation | Valid utility volumes pass |
| should reject duplicate utility volume names | Duplicate names rejected |
| should reject utility volume name conflicting with regular volume | Name clash with spec.volumes |
| should reject utility volume with empty PVC/name | Required fields |
| should reject utility volumes marked as permanent | Must be hotpluggable |
| should reject changes to existing utility volumes | PVC change on existing rejected |
| should reject utility volumes when feature gate disabled | FG enforcement |

#### VM Snapshot Admitter (`vmsnapshot_test.go`)

| Test | Description |
|------|-------------|
| should reject without feature gate | Snapshot FG required |
| should reject invalid request resource | Wrong GVR |
| should reject missing apigroup | spec.source.apiGroup required |
| should allow when VM does not exist | Missing VM OK at admission |
| should reject spec update | Snapshot spec immutable |
| should accept when VM is running | Always run strategy |
| should reject invalid kind/apiGroup | Source validation |

#### VM Restore Admitter (`vmrestore_test.go`)

| Test | Description |
|------|-------------|
| should reject without feature gate | No Snapshot FG → deny |
| should reject invalid request resource | Wrong GVR |
| should reject missing apigroup | spec.target.apiGroup required |
| should reject spec update | Restore spec not mutable |
| should allow when VM is not running | Halted VM OK |
| should reject if restore in progress | Another restore for target in flight |
| should reject volume overrides if no parameter | Empty VolumeRestoreOverride |
| should accept/reject volume restore/ownership policies | Policy validation |
| should reject restore with backend storage to different VM | Persistent TPM constraint |
| should reject/allow JSON patches | RFC6902 patch allowlist |

#### VM Export Admitter (`vmexport_test.go`)

| Test | Description |
|------|-------------|
| should reject invalid request resource | Wrong admission resource |
| should reject blank names | Empty spec.source.name |
| should reject unknown kind | spec.source.kind not recognized |
| should reject spec update | Export spec immutable on update |
| should allow metadata update | Finalizer/metadata changes OK |
| should allow valid APIGroup+kind+name | PVC, snapshot, VM sources |
| should reject invalid apigroups | Wrong apiGroup per kind |

#### VM Backup Admitter (`backup_test.go`)

| Test | Description |
|------|-------------|
| should reject invalid resource group/name | GVR validation |
| should reject without IncrementalBackup FG | Feature gate required |
| should allow update for non-spec changes | Labels/finalizers OK |
| should reject duplicate backup name | Unique backup names |
| should reject if another backup in progress | Concurrency control |
| should allow creating backup if existing is done | Done backups don't block |

#### DataVolumeTemplate Validation (`vm-storage-admitter_test.go`)

| Test | Description |
|------|-------------|
| should accept valid DataVolumeTemplate | DVT matching disk |
| should reject DVT in another namespace | Namespace must match VM |
| should reject DVT with SourceRef only | Unless VM has deletionTimestamp |
| should reject missing template name | Name required |
| should reject both PVC and Storage | Mutually exclusive |
| should reject datasource + Source conflict | Source resolution rules |
| Snapshot/restore in progress guards | Reject changes during operations |

---

### 2. VM Snapshots (~130 tests)

**Location:** `pkg/storage/snapshot/`

#### Snapshot Controller (`snapshot_test.go`)

| Test | Description |
|------|-------------|
| should initialize VirtualMachineSnapshot status | First sync: adds finalizer, sets status |
| should initialize status when source VM missing | "Source does not exist" |
| should unlock source VirtualMachine | Completed snapshot removes protection |
| shouldn't unlock if snapshot deleting before completed | Deleting phase handling |
| cleanup when VirtualMachineSnapshot is deleted | Deletes content, removes finalizers |
| should not delete content with retain policy | Retain + ready content preserved |
| should partial lock source if VM patch fails | Handle patch failures |
| should complete lock source | Full lock for running/stopped VM |
| should not lock if PVCs not exist/bound/populated/deleting | Lock preconditions |
| should not lock if pods using PVCs (offline) | Offline VM + pods block lock |
| should not lock if another snapshot in progress | Conflict handling |
| should create VirtualMachineSnapshotContent | Content creation when locked |
| should create online snapshot content | VM revision + VMI, indications |
| should create content with memory dump | Memory dump path |
| should update VirtualMachineSnapshotStatus | Propagates success from content |
| should update included/excluded volumes | Partial snapshot indication |
| should update error from content | Mirror content errors |
| should timeout if passed failure deadline | Deadline enforcement |
| should create VolumeSnapshot | CSI VolumeSnapshot creation |
| should freeze/unfreeze vm with guest agent | Quiesce operations |
| should set QuiesceTimeout indication | Windows VSS timeout handling |
| should update volume snapshot status per volume | Per-disk snapshot enablement |

#### Restore Controller (`restore_test.go`)

| Test | Description |
|------|-------------|
| should error if snapshot does not exist/failed/not ready | Precondition validation |
| should error if target exists and different from source | Cross-VM restore guard |
| should error if volumesnapshot doesn't exist | Missing VolumeSnapshot |
| should update restore status, initializing conditions | First status setup |
| should wait for target to be ready | Running VMI wait |
| should update restore with finalizer and owner | Protection setup |
| should create restore PVCs | PVC from VolumeSnapshot |
| should create PVC with max(snapshot, original) size | Size handling |
| restored pvc ownership policies (VM/none) | Owner refs on created PVC |
| volume restore policy InPlace | Overwrite path |
| PrefixTargetName policy | Target VM prefix naming |
| should override pvcs and volumes | VM volume patching |
| should cleanup, unlock vm, mark completed | Completion path |
| should restore to a new VM | New target creation |
| TargetReadinessPolicy (WaitEventually/StopTarget/FailImmediate) | Policy behaviors |
| should restore with instancetypes and preferences | ControllerRevision handling |

---

### 3. Changed Block Tracking & Backup (~200 tests)

**Location:** `pkg/storage/cbt/`, `pkg/virt-launcher/virtwrap/storage/`

#### CBT State Machine (`cbt_test.go`)

| Test | Description |
|------|-------------|
| should transition VM state when no VMI exists | CBT enabled via VM labels |
| should transition VM state based on VMI state | VM+VMI CBT state matrix |
| Namespace matches Label Selector | Namespace-level CBT |
| VM does not match Label Selector | CBT disabled transitions |
| should set CBT state to Initializing/PendingRestart/FGDisabled | Quick paths |
| should handle FG disabled correctly | Feature gate off handling |
| should reset invalid VM CBT state | State normalization |
| should disable CBT if VMI is nil | Selector removal |
| IsCBTEligibleVolume | Volume type eligibility (PVC/DV/HostDisk) |

#### Backup Controller (`backup_test.go`)

| Test | Description |
|------|-------------|
| should fail when source name is empty | errSourceNameEmpty |
| should get source from backupTracker | Tracker-based backup |
| should wait when backupTracker needs checkpoint redefinition | Wait states |
| verifyVMIEligibleForBackup | No volumes/CBT/enabled checks |
| sync during initialization | Wait for VM, VMI, eligible volumes |
| should add finalizer when not present | Finalizer management |
| should cleanup when VMI backup status missing | Error handling |
| initialization/progressing failures | Failure path handling |
| handleBackupInitiation | Patch/API start failures |
| updateStatus | Progressing/Done/Aborting conditions |
| resolveCompletion | VMI backup status mapping |
| should attach PVC and return | Utility volume patch |
| Full/Incremental backup initiation | Backup type handling |
| should update backupTracker with checkpoint | Checkpoint persistence |
| TTL helpers | Expiration handling |
| ExportReady with endpoints | Pull mode links |

#### Backup Tracker (`backuptracker_test.go`)

| Test | Description |
|------|-------------|
| trackerNeedsCheckpointRedefinition | Flag + checkpoint detection |
| should clear redefinition flag | clearRedefinitionFlag |
| should clear checkpoint and flag | clearCheckpointAndFlag |
| executeTracker | Missing/no-op/success/error paths |
| handleRedefinitionError | 503/422 error handling |

#### Push Target PVC (`push-target-pvc_test.go`)

| Test | Description |
|------|-------------|
| backupTargetPVCAttached | Mount detection |
| attachBackupTargetPVC | JSON patch add/replace |
| detachBackupTargetPVC | Remove from utilityVolumes |
| verifyBackupTargetPVC | Block mode rejection, FS OK |

#### virt-launcher Backup (`backup_test.go`)

| Test | Description |
|------|-------------|
| should fail if migration in progress | Migration blocks backup |
| should not start another backup | Duplicate detection |
| should fail if different backup in progress | Concurrent backup block |
| should freeze, start backup, and thaw | Quiesce flow |
| should continue without freeze if freeze fails | Graceful degradation |
| generateDomainBackup | XML generation, checkpoints |
| HandleBackupJobCompletedEvent | Completion/failure handling |
| Abort backup | Cancel operations |
| findDisksWithCheckpointBitmap | Bitmap discovery |

---

### 4. VM Export (~80 tests)

**Location:** `pkg/storage/export/`

#### Export Controller (`export_test.go`)

| Test | Description |
|------|-------------|
| should add vmexport to queue if matching PVC/VMSnapshot/VM/VMI added | Event handlers |
| Should create service based on VMExport name | Service creation |
| Should create pod based on VMExport | Exporter pod creation |
| should set TLS env vars when TLSConfiguration set | TLS configuration |
| Volume mount names should be trimmed | DNS label length |
| GetVolumeInfo should resolve volume paths | Path resolution |
| service name should be sanitized | DNS-1035 compliance |
| Should create cert secret | Certificate management |
| handleVMExportToken | Token secret handling |
| Should clean up when TTL reached | TTL enforcement |
| should find host when Ingress/Route defined | External URL discovery |
| Should properly expand instance types | Instancetype expansion |
| Should generate DataVolumes from VM | DV generation |

#### PVC Source (`pvc-source_test.go`)

| Test | Description |
|------|-------------|
| Should update status with valid token, no PVC | Pending state |
| archive/kubevirt content with/without route | Link generation |
| Should retry if PVC is in use | Contention handling |
| should detect content type properly | Kubevirt content detection |
| should create proper condition from PVC | Bound/lost/pending |

#### VM Source (`vm-source_test.go`)

| Test | Description |
|------|-------------|
| Should create export when VM stopped | Stopped VM export |
| Should create export with backend storage | TPM backend PVC |
| Should NOT create export when VM started | Running VM blocked |
| Should NOT create export when DV not complete | Import completion wait |
| Should stop running export when VM started | Pod cleanup |
| Should be skipped when VM has no volumes | Empty VM handling |

#### VMSnapshot Source (`vmsnapshot-source_test.go`)

| Test | Description |
|------|-------------|
| Should create restored PVCs from VMSnapshot | PVC restoration |
| Should not re-create restored PVCs | Idempotency |
| kubevirt/archive content type | Format handling |
| snapshot not ready | Pending state |

#### Backup Source (`backup-source_test.go`)

| Test | Description |
|------|-------------|
| Should create export when backup progressing | Backup export |
| Should update status according to backup | Ready gates |
| Should add vmexport to queue if VMBackup added | Event handling |
| BACKUP_CHECKPOINT env handling | Checkpoint passing |
| backup CA error handling | CA validation |

#### Export Server (`exportserver_test.go`)

| Test | Description |
|------|-------------|
| should handle archive/dir/raw/VM manifest/Token | Valid token paths |
| should fail bad token | 401 for wrong token |
| VM handler should return YAML/JSON | Manifest formats |
| Should override DVTemplates | HTTP URL generation |
| Secret handler | Token secret manifest |
| backupMapHandler/backupDataHandler | NBD map/data streaming |
| handleTunnel | mTLS CONNECT tunnel |
| buildServer | TLS configuration |

---

### 5. Disk Types (~100 tests)

#### Container Disk (`pkg/container-disk/`)

| Test | Description |
|------|-------------|
| by verifying mapping of qcow2/raw disk | Volume mount path resolution |
| by verifying host directory locations | GetVolumeMountDirOnHost |
| resources for guaranteed/non-guaranteed QOS | GenerateContainers resources |
| by verifying container generation | Multiple container disks |
| socket path resolution | Socket file detection |
| for migration pod with containerDisks | ExtractImageIDsFromSourcePod |
| should detect imageID from docker/containerd/cri-o | Runtime image ID parsing |
| security context on generated containers | Privilege escalation, capabilities |

#### Empty Disk (`pkg/emptydisk/`)

| Test | Description |
|------|-------------|
| should get new qcow2 image if not present | CreateTemporaryDisks |
| should generate non-conflicting volume paths | FilePathForVolumeName |
| should leave pre-existing disks alone | Idempotency |

#### Ephemeral Disk (`pkg/ephemeral-disk/`)

| Test | Description |
|------|-------------|
| Should create ephemeral image | Single volume overlay |
| Should create ephemeral images | Multiple volumes |
| Should create in idempotent way | Re-creation safety |
| Should create with block PVC | Block backing store |

#### Host Disk (`pkg/host-disk/`)

| Test | Description |
|------|-------------|
| Should not create disk.img when exists | Existing image unchanged |
| Should create disk.img if enough space | Sparse file creation |
| Should stop creating when not enough space | Space validation |
| Should subtract reserve if NOT enough space | Reserve handling |
| Should refuse with lessPVCSpaceToleration | Toleration enforcement |
| Should not re-create or chown disk.img | Pre-existing preservation |
| ReplacePVCByHostDisk | File/block mode handling |

#### Hotplug Disk (`pkg/hotplug-disk/`)

| Test | Description |
|------|-------------|
| GetHotplugTargetPodPathOnHost | Path resolution |
| GetFileSystemDirectoryTargetPathFromHostView | Directory creation |
| GetFileSystemDiskTargetPathFromHostView | Disk image file |

---

### 6. virt-handler Storage (~120 tests)

**Location:** `pkg/virt-handler/container-disk/`, `pkg/virt-handler/hotplug-disk/`

#### Container Disk Mount

| Test | Description |
|------|-------------|
| ContainerDisksReady | Socket readiness detection |
| should return true once everything ready | Ready path |
| should return false/error outside retry window | Timeout handling |
| kernel boot container paths | Kernel boot socket |
| ImageVolume always ready | Image volume handling |
| mount target checkpoint I/O | get/set/delete records |

#### Hotplug Disk Mount

| Test | Description |
|------|-------------|
| setMountTargetRecord should fail if UID empty | Validation |
| getMountTargetRecord from file/cache | Record retrieval |
| deleteMountTargetRecord | Cleanup |
| writePathToMountRecord should not duplicate | Idempotent write |
| isBlockVolume | Volume mode detection |
| should skip mounting utility volumes with block | Block utility skip |
| findVirtlauncherUID | Launcher pod lookup |
| mountBlockHotplugVolume/unmount | Cgroup allow/deny |
| getSourceMajorMinor | Device numbers |
| getBlockFileMajorMinor | Stat parsing |
| allowBlockMajorMinor/removeBlockMajorMinor | Cgroup rules |
| Should attempt to create block device file | mknod handling |
| getSourcePodFile | disk.img resolution |
| mount/unmount filesystem | Bind mount operations |
| mount and umount should work for filesystem volumes | Full integration |
| Unmount, if failed, should continue for other volumes | Partial failure |
| unmountAll should cleanup | Complete teardown |

#### findmnt

| Test | Description |
|------|-------------|
| Should return list of values with valid input | JSON parsing |
| Should return error if findmnt fails | Error handling |
| GetSourcePath should match source field | Path extraction |
| GetSourceDevice should return device | Device detection |
| GetOptions should return list | Option parsing |

---

### 7. virt-launcher Storage (~100 tests)

**Location:** `pkg/virt-launcher/virtwrap/storage/`

#### Backup

| Test | Description |
|------|-------------|
| should fail if migration in progress | Migration guard |
| backup after failure should allow retry | Retry support |
| incremental backup with checkpoint | Checkpoint handling |
| pull mode backup | Pull mode metadata |
| freeze, start backup, thaw | Quiesce sequence |
| continue without freeze if fails | Graceful degradation |
| generateDomainBackup | XML generation |
| HandleBackupJobCompletedEvent | Job completion |
| Abort backup | Cancel support |
| findDisksWithCheckpointBitmap | Bitmap discovery |

#### Backup Tunnel

| Test | Description |
|------|-------------|
| IsMatch | Name + time matching |
| prepareTLSConfig | CA/cert validation |
| closeNotifyConn | Connection cleanup |
| oneConnListener | Single connection accept |
| watchSocket | Socket file watch |
| openConnectTunnel | HTTP CONNECT tunnel |

#### CBT

| Test | Description |
|------|-------------|
| ShouldCreateQCOW2Overlay | Overlay creation conditions |
| isMigrationNewBackendStorage | Migration detection |
| ApplyChangedBlockTracking | Volume processing |
| runOverlayQMPSession | QMP blockdev-create |
| ApplyChangedBlockTrackingForMigration | Migration CBT |

#### FS Freeze

| Test | Description |
|------|-------------|
| should freeze VirtualMachineInstance | FSFreeze call |
| should fail freeze during migration | Migration guard |
| should unfreeze VirtualMachineInstance | FSThaw call |
| should auto-unfreeze after timeout | Timed thaw |

#### Memory Dump

| Test | Description |
|------|-------------|
| should update domain with memory dump info | CoreDumpWithFormat |
| should skip if same dump completed | Idempotency |
| should update if memory dump failed | Error handling |

#### VirtioFS

| Test | Description |
|------|-------------|
| Should not configure when no VirtioFS present | Empty domain |
| Should configure VirtioFS filesystems | Socket + target config |

#### Disk Source

| Test | Description |
|------|-------------|
| should resolve topology correctly | Path/backend/overlay |
| should detect hotplug disks correctly | HotplugDiskDir detection |

---

### 8. Volume Migration (~50 tests)

**Location:** `pkg/virt-controller/watch/volume-migration/`

| Test | Description |
|------|-------------|
| ValidateVolumes with empty VMI/VM | Nil validation |
| ValidateVolumes without migrated volumes | Same PVCs OK |
| ValidateVolumes with valid volumes | Different PVCs OK |
| ValidateVolumes with invalid LUN/shareable/filesystem | Type restrictions |
| ValidateVolumes with valid hotplugged volume | Hotplug allowed |
| ValidateVolumes with DV CSI/non-CSI storageclass | Storage class validation |
| VolumeMigrationCancel without updates | No cancel needed |
| VolumeMigrationCancel with reversion | Cancel applies |
| VolumeMigrationCancel with invalid update | Error handling |
| IsVolumeMigrating | Condition detection |
| PatchVMIStatusWithMigratedVolumes | Status update |
| ValidateVolumesUpdateMigration | Migration eligibility |
| PatchVMIVolumes | Spec update after migration |
| GenerateReceiverMigratedVolumes | Source/dest info |

---

### 9. Storage Types & Utils (~60 tests)

**Location:** `pkg/storage/types/`, `pkg/storage/utils/`

#### CDI Utils

| Test | Description |
|------|-------------|
| should return 0 with block volume mode | Block overhead |
| should return global/storage class overhead | Overhead resolution |

#### DataVolume Utils

| Test | Description |
|------|-------------|
| should ignore DV with no clone operation | Non-clone handling |
| should handle DV clone source namespace | Namespace defaulting |
| should handle DV clone sourceRef | DataSource resolution |

#### PVC Utils

| Test | Description |
|------|-------------|
| should handle non existing PVC | Not found |
| should detect filesystem/block device | VolumeMode detection |

#### Volume Utils

| Test | Description |
|------|-------------|
| IsUtilityVolume | Utility volume detection |
| GetTotalSizeMigratedVolumes | Size calculation |
| GetHotplugVolumes | Hotplug candidates |

#### GetVolumes

| Test | Description |
|------|-------------|
| should handle volume exclusions | WithBackendVolume/WithRegularVolumes |
| should trim backend volume name | DNS length compliance |

---

### 10. Backend Storage (~30 tests)

**Location:** `pkg/storage/backend-storage/`

| Test | Description |
|------|-------------|
| Should return VMStateStorageClass and RWX | Config-based SC |
| Should return default storage class | Fallback |
| Should default to RWO | Unknown SC |
| Should pick RWX when available | Access mode selection |
| Should pick RWO when RWX not possible | Fallback mode |
| MigrationHandoff | Label target, delete source |
| MigrationAbort | Remove target, keep source |
| Should keep shared PVC | Same PVC handling |
| createPVC with correct labels | Label application |
| IsBackendStorageNeeded | TPM/EFI/CBT detection |

---

### 11. NBD Client (~30 tests)

**Location:** `pkg/storage/nbdclient/`

| Test | Description |
|------|-------------|
| getExtentDescription base:allocation | Data/hole/zero strings |
| getExtentDescription qemu:dirty-bitmap | Clean/dirty strings |
| clampLength | Read length clamping |
| computeChunks | Chunk splitting |
| sortedContextsByOffset | Extent ordering |
| mapBuilder coalescing | Adjacent extent merge |
| mapBuilder clipping | Beyond endOffset trim |
| mapBuilder batching | Batch size enforcement |
| readProcessor | Chunk read/send |

---

### 12. Memory Dump (~15 tests)

**Location:** `pkg/storage/memorydump/`

| Test | Description |
|------|-------------|
| should update memory dump phase to InProgress | Phase transition |
| should update status to unmounting | Completion timestamps |
| should update status to failed | Failure handling |
| should update to completed when unmounted | Final state |
| should dissociate memory dump request | Cleanup |
| HandleRequest remove volume and update PVC | Unmount handling |

---

### 13. Hotplug Controller (~25 tests)

**Location:** `pkg/storage/hotplug/`

| Test | Description |
|------|-------------|
| should do nothing if VMI not running | No-op for stopped |
| should do nothing if non-hotplug volume added | Skip non-hotplug |
| should add hotplug volumes (DV/PVC) | Volume sync |
| should remove hotplug volumes | Volume removal |
| should not remove perm volume | Permanent protection |
| should not add if vmi has status for volume | Duplicate prevention |
| should remove when volume changes | Change detection |
| should not add with migration updatestrategy | Migration guard |
| should inject/eject CD-ROM | CD-ROM hotplug |

---

### 14. Pod Annotations (~15 tests)

**Location:** `pkg/storage/pod/annotations/`

| Test | Description |
|------|-------------|
| Should generate storage annotations | Velero hooks |
| Should not generate when skip annotation true | Skip variants |
| Should generate when skip annotation false | Falsy values |
| CR annotation override | VMI takes precedence |

---

### 15. OS Disk Validation (~6 tests)

**Location:** `pkg/os/disk/`

| Test | Description |
|------|-------------|
| VerifyQCOW2 should reject non-qcow2 | Format check |
| VerifyQCOW2 should reject backing file | Chain rejection |
| VerifyQCOW2 should run successfully | Valid qcow2 |
| VerifyImage should accept raw | Raw format |
| VerifyImage should succeed on qcow2 | Valid stats |
| VerifyImage should fail on unknown | Unknown format |

---

## Running T1 Storage Tests

```bash
# Run all storage unit tests
cd /path/to/kubevirt
make test WHAT="./pkg/storage/..."

# Run specific package tests
go test -v ./pkg/storage/snapshot/...
go test -v ./pkg/storage/admitters/...
go test -v ./pkg/storage/cbt/...
go test -v ./pkg/storage/export/...

# Run with coverage
go test -coverprofile=coverage.out ./pkg/storage/...
go tool cover -html=coverage.out

# Run a specific test
go test -v -run "TestSnapshotController" ./pkg/storage/snapshot/

# Using Bazel
bazel test //pkg/storage/...
```

---

## Test Organization Pattern

KubeVirt follows a consistent test organization:

1. **Suite file:** `*_suite_test.go` - Ginkgo bootstrap
2. **Test file:** `*_test.go` - Actual test cases
3. **Describe blocks:** Top-level component grouping
4. **Context blocks:** Scenario grouping
5. **It blocks:** Individual test cases
6. **DescribeTable:** Parameterized tests with Entry

Example structure:
```go
var _ = Describe("Storage Component", func() {
    Context("when condition X", func() {
        It("should do Y", func() {
            // Test code
        })
        
        DescribeTable("should handle cases",
            func(input, expected) {
                // Test code
            },
            Entry("case 1", input1, expected1),
            Entry("case 2", input2, expected2),
        )
    })
})
```

---

## Coverage Summary by Component

| Component | Approx. Tests | Coverage Focus |
|-----------|---------------|----------------|
| Admitters | ~150 | Webhook validation, RBAC, immutability |
| Snapshot | ~130 | Create/lock/content/restore lifecycle |
| CBT/Backup | ~200 | State machine, quiesce, checkpoint, export |
| Export | ~80 | Sources, links, pods, secrets, tunnel |
| Disk Types | ~100 | Container/empty/ephemeral/host disks |
| virt-handler | ~120 | Mount/unmount, hotplug, cgroups |
| virt-launcher | ~100 | Backup, CBT overlay, freeze, dump |
| Volume Migration | ~50 | Validation, cancel, patch, receiver |
| Storage Types | ~60 | CDI, DV, PVC, volume utils |
| Backend Storage | ~30 | SC selection, migration handoff |
| NBD Client | ~30 | Map/data streaming, chunking |
| Memory Dump | ~15 | Phase transitions, cleanup |
| Hotplug Controller | ~25 | Sync, CD-ROM, migration |
| Pod Annotations | ~15 | Velero hooks |
| OS Disk | ~6 | Format validation |

---

## Repository Reference

- **Repository:** https://github.com/kubevirt/kubevirt
- **Fork used:** https://github.com/Ahmad-Hafe/kubevirt
- **Test framework:** Ginkgo v2 + Gomega
- **Build system:** Bazel + Go modules
