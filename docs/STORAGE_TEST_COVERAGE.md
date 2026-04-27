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

| Test | Test ID |
|------|---------|
| Alpine import - should be successfully started and stopped multiple times | test_id:3189 |
| Alpine import - should successfully start multiple concurrent VMIs | test_id:6686 |
| Alpine import - should be successfully started when using a PVC volume owned by a DataVolume | test_id:5252 |
| Should accurately aggregate DataVolume conditions from many DVs | - |
| PVC from Datavolume - should NOT be rejected when VM template lists a DataVolume | test_id:4643 |
| Invalid DataVolume - should be possible to stop VM if datavolume is crashing | - |
| Invalid DataVolume - should correctly handle invalid DataVolumes | test_id:3190 |
| oc/kubectl - Creating a VM with DataVolumeTemplates should succeed | test_id:836 |
| oc/kubectl - deleting VM with cascade=true should automatically delete DataVolumes and VMI | test_id:837 |
| oc/kubectl - deleting VM with cascade=false should orphan DataVolumes and VMI | test_id:838 |
| Alpine http import - should be successfully started and stopped multiple times | test_id:3191 |
| Alpine http import - should remove owner references on DataVolume if VM is orphan deleted | test_id:3192 |
| Clone permission - should resolve DataVolume sourceRef with PVC source | - |
| Clone permission - should resolve DataVolume sourceRef with Snapshot source | - |
| Clone permission - should report DataVolume without source PVC | - |
| Clone permission - deny then allow clone with explicit role | test_id:3193 |
| Clone permission - deny then allow clone with implicit role | test_id:3194 |
| Clone permission - with explicit role (all namespaces) | test_id:5253 |
| Clone permission - with explicit role (one namespace) | test_id:5254 |
| Fedora VMI fstrim - by default, fstrim will make the image smaller | test_id:5894 |
| Fedora VMI fstrim - with preallocation true, fstrim has no effect | test_id:5898 |
| PVC expansion - with Block PVC | - |
| PVC expansion - with Filesystem PVC | - |
| Check disk expansion accounts for actual usable size | - |
| [Serial] without fsgroup support should successfully start | - |
| [Serial] GC of succeeded DV when GC is enabled | test_id:8567 |
| [Serial] GC is disabled, and after VM creation, GC is enabled and DV is annotated | test_id:8571 |

### 2. Volume Hotplug (~40 tests)

| Test | Test ID |
|------|---------|
| Online VM - should add/remove volume with DataVolume immediate attach | - |
| Online VM - should add/remove volume with PersistentVolume immediate attach | - |
| Online VM - should add/remove volume with DataVolume wait for VM to finish starting | - |
| Online VM - should add/remove volume with PersistentVolume wait for VM to finish starting | - |
| Online VM - should add/remove volume with DataVolume immediate attach, VMI directly | - |
| Online VM - should add/remove volume with PersistentVolume immediate attach, VMI directly | - |
| Online VM - should add/remove volume with Block DataVolume immediate attach | - |
| Online VM - should not add/remove volume with dry run | - |
| Online VM - Should be able to add and remove multiple volumes with VMs | - |
| Online VM - Should be able to add and remove multiple volumes with VMIs | - |
| Online VM - Should be able to add and remove multiple volumes with VMs and block | - |
| Online VM - Should be able to add and remove and re-add multiple volumes | - |
| Online VM - should allow to hotplug 75 volumes simultaneously | - |
| Online VM - should permanently add hotplug volume when added to VM | - |
| Online VM - should reject hotplugging a volume with the same name | - |
| Online VM - should reject hotplugging the same volume with an existing volume name | - |
| Online VM - should reject removing a volume which wasn't hotplugged | - |
| Online VM - should reject removing a volume which doesn't exist | - |
| Online VM - should allow hotplugging both a filesystem and block volume | - |
| VMI migration - should allow live migration with attached hotplug volumes (containerDisk) | - |
| VMI migration - should allow live migration with attached hotplug volumes (persistent disk) | - |
| [Serial] Hotplug LUN disk on an offline VM | - |
| [Serial] Hotplug LUN disk on an online VM | - |
| Limit range - 1 to 1 cpu and mem ratio | test_id:10002 |
| Limit range - 1 to 1 mem ratio, 4 to 1 cpu ratio | test_id:10003 |
| Limit range - 2 to 1 mem ratio, 4 to 1 cpu ratio | test_id:10004 |
| Limit range - 2.25 to 1 mem ratio, 5.75 to 1 cpu ratio | test_id:10005 |
| Hostpath - should attach a hostpath based volume to running VM | - |
| iothreads - should allow adding and removing hotplugged volumes | - |
| [Serial] Should preserve access to block devices if virt-handler crashes | - |

### 3. VM Snapshots (~30 tests)

| Test | Test ID |
|------|---------|
| Should successfully create a snapshot without DV garbage collection | test_id:4611 |
| Should successfully create a snapshot with DV garbage collection | test_id:8668 |
| With independent DataVolume - Should also include backend PVC in the snapshot | - |

### 4. VM Restore (~25 tests)

| Test | Test ID |
|------|---------|
| With simple VM and no snapshot - should reject restore | test_id:5255 |
| With simple VM with run strategy and snapshot - should successfully restore | - |
| With simple VM and good snapshot exists - should successfully restore | test_id:5256 |
| Should reject restore if VM running | test_id:5257 |
| Should reject restore if another in progress | test_id:5258 |
| Should fail restoring to a different VM that already exists | - |
| Restore to a new VM with changed name and MAC address | - |
| Instancetype/preferences - should use existing ControllerRevisions (running VM) | - |
| Instancetype/preferences - should use existing ControllerRevisions (stopped VM) | - |
| Instancetype/preferences - should create new ControllerRevisions (running VM) | - |
| Instancetype/preferences - should create new ControllerRevisions (stopped VM) | - |
| Should restore a vm multiple from the same snapshot | test_id:5259 |
| Should restore a vm with restore size bigger than PVC size (same VM) | - |
| Should restore a vm with restore size bigger than PVC size (new VM) | - |
| Should restore a vm that boots from a datavolumetemplate (same VM) | test_id:5260 |
| Should restore a vm that boots from a datavolumetemplate (new VM) | - |
| Should restore a vm that boots from a datavolume (not template) (same VM) | test_id:5261 |
| Should restore a vm that boots from a datavolume (not template) (new VM) | - |
| Should restore a vm that boots from a PVC (same VM) | test_id:5262 |
| Should restore a vm that boots from a PVC (new VM) | - |
| Should restore a vm with containerdisk and blank datavolume (same VM) | test_id:5263 |
| Should restore a vm with containerdisk and blank datavolume (new VM) | - |
| Should reject vm start if restore in progress | - |
| Should restore a vm from an online snapshot (same VM) | test_id:6053 |
| Should restore a vm from an online snapshot (new VM) | - |
| Should restore a vm from an online snapshot with guest agent | test_id:6766 |
| Should restore a vm with backend storage (offline snapshot) | - |
| Should restore a vm with backend storage (online snapshot) | - |

### 5. VM Clone (~15 tests)

| Test | Test ID |
|------|---------|
| Should reject source with non snapshotable volume (VM source) | - |
| Should reject source with non snapshotable volume (snapshot source) | - |
| With snapshot storage class - with a simple clone | - |
| With instancetype/preferences - should create new ControllerRevisions (running VM) | - |
| With instancetype/preferences - should create new ControllerRevisions (stopped VM) | - |
| Double cloning: clone target as a clone source | - |
| With WaitForFirstConsumer binding mode - should not delete vmsnapshot until PVCs bound | - |

### 6. Image Upload - virtctl (~15 tests)

| Test | Test ID |
|------|---------|
| Upload an image and start a VMI with PVC - Should succeed DataVolume | test_id:4621 |
| Upload an image and start a VMI with PVC - Should succeed PVC | test_id:4621 |
| Create upload volume with force-bind flag - Should succeed DataVolume | - |
| Create upload volume with force-bind flag - Should succeed PVC | - |
| Block volumeMode - Should succeed | test_id:10671 |
| Filesystem volumeMode - Should succeed | test_id:10672 |
| Should fail with invalid volume-mode | test_id:10674 |
| Upload fails when DV is in WFFC/PendingPopulation phase | - |
| Create upload archive volume - Should succeed DataVolume | - |
| Create upload archive volume - Should succeed PVC | - |
| Upload fails creating a DV when using a non-existent storageClass | - |
| Upload fails creating a PVC when using a non-existent storageClass | - |
| Upload doesn't succeed when DV provisioning fails | - |
| Upload doesn't succeed when PVC provisioning fails | - |

### 7. Memory Dump (~12 tests)

| Test | Test ID |
|------|---------|
| Should be able to get and remove memory dump - calling endpoint directly | test_id:8499 |
| Should be able to get and remove memory dump - using virtctl | test_id:8500 |
| Run multiple memory dumps | test_id:8502 |
| Run memory dump to a pvc, remove and run to different pvc | test_id:8503 |
| Run memory dump, stop vm and remove memory dump | test_id:8506 |
| Run memory dump, stop vm start vm | test_id:8515 |
| Run memory dump with pvc too small should fail | test_id:8501 |
| Creating a PVC - Should be able to get and remove memory dump | test_id:9034 |
| Creating a PVC - Run multiple memory dumps | test_id:9035 |
| Creating a PVC - Run memory dump, remove and create different pvc | test_id:9036 |
| Should be able to remove memory dump while stuck | test_id:9341 |
| Download - should create memory dump and download it | test_id:9344 |
| Download - should download existing memory dump | test_id:9343 |

### 8. VirtIO-FS (~8 tests)

| Test | Test ID |
|------|---------|
| VirtIO-FS with multiple PVCs - should be accessible (privileged virtiofsd) | - |
| VirtIO-FS with multiple PVCs - should be accessible (unprivileged virtiofsd) | - |
| VirtIO-FS with an empty PVC - unprivileged virtiofsd | - |
| VirtIO-FS with an empty PVC - privileged virtiofsd | - |
| Run a VMI with VirtIO-FS and a datavolume - unprivileged virtiofsd | - |
| Run a VMI with VirtIO-FS and a datavolume - privileged virtiofsd | - |

### 9. Volume Migration (~15 tests)

| Test | Test ID |
|------|---------|
| Should migrate from source DV to destination PVC (filesystem volume) | - |
| Should migrate from source DV to destination PVC (block volume) | - |
| Should migrate from source DV to destination DV | - |
| Should migrate from source and destination block RWX DVs | - |
| Should migrate from block source and filesystem destination DVs | - |
| Should migrate a PVC with a VM using a containerdisk | - |
| Should cancel the migration by reverting to source volume | - |
| Should fail to migrate when destination image is smaller | - |
| Should set restart condition (second volume is RWO and not part of migration) | - |
| Should refuse to restart VM and set ManualRecoveryRequired at shutdown | - |
| Should cancel migration and clear volume migration state | - |
| Should recover from interrupted volume migration | - |
| Hotplug volumes - should add and remove with persistent volume | - |
| Hotplug volumes - should add and remove with ephemeral volume | - |
| Hotplug volumes - should be able to migrate an hotplugged volume | - |

### 10. Export (~10 tests)

| Test | Test ID |
|------|---------|
| Should export a VM and verify swtpm directories in the gz archive | - |
| Ingress should populate external links and cert | - |
| With limit range - should report export pending if PVC is in use | - |
| Should recreate exportserver pod when KubeVirt cert params updated | - |

### 11. SCSI Persistent Reservation (~5 tests)

| Test | Test ID |
|------|---------|
| Should successfully start a VM with persistent reservation | - |
| Should successfully start 2 VMs with persistent reservation on same LUN | - |
| With PersistentReservation feature gate toggled - should delete and recreate virt-handler | - |

### 12. Storage Error Handling (~10 tests)

| Test | Test ID |
|------|---------|
| With error disk - should pause VMI on IO error | - |
| With error disk - should report IO errors with errorPolicy set to report | - |
| K8s IO events - Should catch the IO error event | test_id:6225 |
| With NFS Disk PVC using ipv6 address of the NFS pod | - |
| With NFS Disk PVC using ipv4 address of the NFS pod | - |
| HostDisk feature gate disabled - should fail to start a VMI | test_id:4620 |
| Should not initialize empty PVC when disk is too small (even with toleration) | test_id:3108 |
| Should initialize empty PVC when disk is too small but within toleration | test_id:3109 |
| With lun disk - should run the VMI using PVC source | - |
| With lun disk - should run the VMI using DataVolume source | - |

### 13. Backend Storage

| Test | Test ID |
|------|---------|
| Should use RWO when RWX is not supported | - |

---

## Storage Capabilities

Tests are filtered based on these storage capabilities:

| Capability | Description |
|------------|-------------|
| `storageClassRhel` | Storage class for RHEL-based VMs |
| `storageClassWindows` | Storage class for Windows VMs |
| `storageRWXBlock` | ReadWriteMany Block volume support |
| `storageRWXFileSystem` | ReadWriteMany Filesystem support |
| `storageRWOFileSystem` | ReadWriteOnce Filesystem support |
| `storageRWOBlock` | ReadWriteOnce Block volume support |
| `storageClassCSI` | CSI driver storage class |
| `storageSnapshot` | Volume snapshot support |
| `onlineResize` | Online volume resize capability |
| `WFFC` | WaitForFirstConsumer binding mode |

### Dynamic Test Filtering

| Condition | Filter Applied |
|-----------|----------------|
| No block storage (RWO/RWX) | `(!RequiresBlockStorage)` - skips block tests |
| Storage class not WFFC | `(!RequiresWFFCStorageClass)` - skips WFFC tests |

---

## Supported Storage Providers

| Provider | Capabilities |
|----------|--------------|
| OCS (Virtualization) | RWX Block, RWO FS, RWO Block, Snapshot, CSI |
| OCS RBD | RWX Block, RWO FS, RWO Block, Snapshot, CSI |
| OCS CephFS | RWX FS, Snapshot, CSI |
| OCS WFFC | RWX Block, RWO FS, RWO Block, Snapshot, CSI, WFFC |
| LVMS | RWO FS, RWO Block, Snapshot, CSI |
| NFS | RWX FS, RWO FS |
| HPP | RWO FS, RWO Block, Snapshot, CSI |
| HPP CSI Block | RWO FS, RWO Block, Snapshot, CSI |
| Portworx | RWX Block, RWO FS, RWO Block, Snapshot, CSI |
| AWS GP3 | RWO FS, RWO Block, Snapshot, CSI |
| AWS IO2 | RWO FS, RWO Block, Snapshot, CSI |
| AWS FSx | RWX FS, RWO FS, Snapshot, CSI |
| Google HyperDisk | RWO FS, RWO Block, Snapshot, CSI |
| Google Cloud NetApp | RWX FS, RWO FS, Snapshot, CSI |
| GPFS | RWX FS, RWO FS, RWO Block, Snapshot, CSI |

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
