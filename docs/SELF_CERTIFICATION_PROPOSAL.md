# Storage Self-Certification Suite Proposal

## Goal

Create a self-certification suite that proves storage infrastructure works well for virtualization, enabling cloud providers to validate their environment without Red Hat running tests.

**Guiding Principle (from @ngavrilo):**
> "Our goal is to include tests in the self validation suite that cover what we believe is important, tests that check that the infrastructure, cloud and provided storage functions well and supports virtualization. Not simply running as much tests as possible, nor testing negative cases for features."

---

## Why This Proposal

The self-validation suite is the gate cloud providers must pass to certify their storage infrastructure for OpenShift Virtualization. Today, that gate has significant blind spots:

- **Only ~27 out of ~253 storage tests** are included (~10% coverage).
- **4 entire categories have zero coverage**: Backup, Changed Block Tracking, Export, and Storage Migration.
- The existing tests cover basic VM lifecycle and snapshot/restore, but miss critical day-2 operations that enterprise customers depend on.

A provider can currently pass self-validation while their storage is broken for backups, volume hotplug, disk export, or storage migration. This proposal closes those gaps by adding 50 carefully selected tests that together prove core storage functionality works end-to-end.

### Selection Criteria

Every test in this proposal was chosen based on:

1. **Positive validation only** -- proves something works, does not test failure paths. Per the guiding principle, we validate infrastructure, not feature edge cases.
2. **Core functionality** -- each test covers a distinct code path that customers use in production. No redundant tests exercising the same logic differently.
3. **Upstream-maintained** -- all tests come from [kubevirt/kubevirt](https://github.com/kubevirt/kubevirt/tree/main/tests/storage), maintained by the KubeVirt community. No custom or downstream-only tests.
4. **Stability** -- none of the selected tests appear in the quarantine list. Only tests with a track record of reliable execution.
5. **Storage-infrastructure sensitivity** -- each test exercises the storage layer in a way that would surface provider-specific issues (CSI driver behavior, volume provisioning, snapshot support, etc.).

### Why 50 Tests

50 tests is the minimum set that covers every storage category with enough depth to catch real infrastructure problems, while staying small enough to run in a reasonable time (~30-45 minutes). Going below this count would leave categories with only 1-2 tests, insufficient to distinguish a genuine infrastructure issue from a one-off test problem. Going significantly above would add diminishing returns and increase runtime without meaningful coverage gain.

---

## Current State

| Metric | Value |
|--------|-------|
| Total storage tests available | ~253 |
| Currently in self-validation | ~27 (~10%) |
| Positive tests available to add | ~215 |

---

## Proposed Additions: 50 Core Tests

Following Natalie's guidance, these tests prove **core storage functionality works for virtualization**.

---

### Category 1: Backup (Enterprise Critical) - 5 tests

**Why this category:** Backup has **zero coverage** in the current suite. Backup and restore is the most critical enterprise storage operation -- without it, VMs have no disaster recovery path. These tests validate that the storage provider's CSI driver correctly supports volume snapshots and data export, which are the building blocks of any backup solution (OADP, Velero, Trilio, etc.).

**File:** [`tests/storage/backup.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/backup.go)

| # | Line | Test Name | Test ID | Why Selected |
|---|------|-----------|---------|----|
| 1 | [84](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/backup.go#L84) | "Full Backup with source VirtualMachine" | - | The most basic backup operation. If full backup doesn't work, nothing else will. |
| 2 | [302](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/backup.go#L302) | "Incremental Backup after VM shutdown and restart" | - | Validates that incremental backup state survives a VM power cycle -- critical for production backup schedules. |
| 3 | [803](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/backup.go#L803) | "Full and Incremental pull mode Backup with endpoint verification" | - | Pull mode backup is the recommended approach for external backup tools. Validates the export endpoint is accessible. |
| 4 | [882](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/backup.go#L882) | "Pull mode backup data integrity and export immutability" | - | Verifies backed-up data is actually correct and that exports cannot be tampered with after creation. |
| 5 | [1158](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/backup.go#L1158) | "should preserve checkpoints and perform incremental backup after live migration" | - | VMs migrate between nodes during maintenance. Backup state must survive migration or incremental backups break. |

---

### Category 2: CBT - Changed Block Tracking - 4 tests

**Why this category:** CBT has **zero coverage** in the current suite. Changed Block Tracking enables incremental backups by identifying which disk blocks changed since the last backup. Without CBT, every backup must be a full copy -- impractical for VMs with large disks. These tests validate that the storage provider correctly supports the CBT overlay mechanism that backup tools depend on.

**File:** [`tests/storage/cbt.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/cbt.go)

| # | Line | Test Name | Test ID | Why Selected |
|---|------|-----------|---------|----|
| 6 | [71](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/cbt.go#L71) | "VM matches cbt label selector, then unmatches" | - | Validates that CBT can be enabled and disabled per-VM via labels -- the primary user-facing control mechanism. |
| 7 | [196](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/cbt.go#L196) | "should create CBT overlay for hotplug volume and remove it on unplug" | - | Hotplugged volumes must also be tracked. If CBT doesn't follow hotplug, incremental backups miss new disks. |
| 8 | [268](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/cbt.go#L268) | "should persist CBT data across restart" | - | CBT state must survive VM restarts, otherwise the next backup after a reboot becomes a full backup unnecessarily. |
| 9 | [284](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/cbt.go#L284) | "should persist CBT data across live migration" | - | Same as above but for live migration. Maintenance operations must not invalidate CBT tracking. |

---

### Category 3: DataVolume Operations - 8 tests

**Why this category:** DataVolumes are the primary way users provision storage for VMs. The current suite has some basic DV tests, but misses PVC expansion, concurrent VM startup, lifecycle cleanup, and disk space reclamation (fstrim). These tests validate that the storage provider handles the full DataVolume lifecycle correctly under realistic conditions.

**File:** [`tests/storage/datavolume.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go)

| # | Line | Test Name | Test ID | Why Selected |
|---|------|-----------|---------|----|
| 10 | [125](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L125) | "PVC expansion is detected by VM and can be fully used" | - | Volume expansion is a GA requirement. The VM must see and use the additional space without restart. |
| 11 | [208](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L208) | "Check disk expansion accounts for actual usable size" | - | Some storage providers report capacity differently than usable space. This catches that mismatch. |
| 12 | [305](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L305) | "should successfully start multiple concurrent VMIs" | test_id:6686 | Validates concurrent volume provisioning -- a common production scenario when scaling up workloads. |
| 13 | [349](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L349) | "should be successfully started when using a PVC volume owned by a DataVolume" | test_id:5252 | Core path: VM boots from a PVC that was created via DataVolume. Most common provisioning flow. |
| 14 | [598](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L598) | "should be successfully started and stopped multiple times" | test_id:3191 | Validates volume attach/detach cycles don't leak or corrupt state. Catches CSI driver bugs on repeated operations. |
| 15 | [619](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L619) | "deleting VM should automatically delete DataVolumes and VMI owned by VM" | test_id:837 | Cleanup correctness -- orphaned volumes waste storage and can block future provisioning on some providers. |
| 16 | [836](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L836) | "should resolve DataVolume sourceRef" | - | SourceRef is used for golden image workflows. If resolution fails, template-based VM provisioning breaks. |
| 17 | [1019](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L1019) | "fstrim from the VM influences disk.img" | test_id:5894 | Validates thin provisioning support. Without fstrim propagation, disk images grow monotonically and waste storage. |

---

### Category 4: Storage Migration - 6 tests

**Why this category:** Storage migration has **zero coverage** in the current suite. Moving VM volumes between storage classes or from block to filesystem (and vice versa) is essential for storage upgrades, rebalancing, and migration between storage tiers. These tests validate that the storage provider supports the volume migration workflow that operators use during maintenance windows.

**File:** [`tests/storage/migration.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go)

| # | Line | Test Name | Test ID | Why Selected |
|---|------|-----------|---------|----|
| 18 | [300](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L300) | "should migrate the source volume from a source DV to a destination PVC" | - | Basic migration flow: DV to PVC. Validates data copy and cutover mechanics. |
| 19 | [374](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L374) | "should migrate the source volume from a source DV to a destination DV" | - | DV-to-DV migration, the most common pattern when both source and target are managed by CDI. |
| 20 | [400](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L400) | "should continously report storage migration metrics" | - | Observability during migration. Without metrics, operators cannot monitor progress or detect stalls. |
| 21 | [474](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L474) | "should trigger the migration once the destination DV exists" | - | Validates the declarative migration workflow -- create the destination, and migration starts automatically. |
| 22 | [604](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L604) | "should migrate the source volume from a block source and filesystem destination DVs" | - | Cross-mode migration (block to filesystem). Common when moving from one storage provider to another. |
| 23 | [638](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L638) | "should migrate a PVC with a VM using a containerdisk" | - | Migration with a mixed-source VM (containerdisk + PVC). Validates that non-PVC volumes don't interfere. |

---

### Category 5: Hotplug Operations - 6 tests

**Why this category:** Volume hotplug allows adding and removing disks from running VMs without downtime. This is a core day-2 operation for database VMs, scaling storage, and attaching temporary work volumes. The current suite has no hotplug coverage. These tests validate that the storage provider's CSI driver supports dynamic volume attach/detach while the VM is running.

**File:** [`tests/storage/hotplug.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go)

| # | Line | Test Name | Test ID | Why Selected |
|---|------|-----------|---------|----|
| 24 | [759](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go#L759) | "Should be able to add and use WFFC local storage" | - | WaitForFirstConsumer is the default binding mode on most cloud providers. Hotplug must work with it. |
| 25 | [968](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go#L968) | "Should be able to add and remove and re-add multiple volumes" | - | Validates the full add/remove/re-add cycle. Catches CSI drivers that leak device mappings. |
| 26 | [1059](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go#L1059) | "Should be able to add and remove multiple volumes" | - | Multiple concurrent hotplug operations. Validates that the CSI driver handles parallel attach requests. |
| 27 | [1118](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go#L1118) | "should allow to hotplug 75 volumes simultaneously" | - | Stress test for volume limits. Validates the provider's maximum attach count is sufficient. |
| 28 | [1274](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go#L1274) | "should allow hotplugging both a filesystem and block volume" | - | Mixed-mode hotplug. Some CSI drivers handle block and filesystem differently; both must work together. |
| 29 | [1162](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go#L1162) | "should permanently add hotplug volume when added to VM" | - | Validates that hotplugged volumes persist across VM restarts when added to the VM spec (not just VMI). |

---

### Category 6: Export Operations - 5 tests

**Why this category:** Export has **zero coverage** in the current suite. Exporting VM disks is required for data migration between clusters, archival, and offline analysis. These tests validate that the storage provider supports exporting volume data via the VirtualMachineExport API, which is also the mechanism backup tools use for pull-mode backup.

**File:** [`tests/storage/export.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/export.go)

| # | Line | Test Name | Test ID | Why Selected |
|---|------|-----------|---------|----|
| 30 | [611](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/export.go#L611) | "should make sure PVC export is Ready when source pod is Completed" | - | Basic export readiness. If the export endpoint never becomes ready, no data can be retrieved. |
| 31 | [1422](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/export.go#L1422) | "should create export from VMSnapshot" | - | Exporting from a snapshot is the safest way to get consistent data. Used by backup tools. |
| 32 | [1447](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/export.go#L1447) | "should export a restored VM disk as raw image, not archive" | - | Raw image export is required for importing into other clusters or hypervisors. Archive format is insufficient. |
| 33 | [1570](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/export.go#L1570) | "should create export from VMSnapshot with multiple volumes" | - | Real VMs have multiple disks. Export must handle all of them, not just the boot disk. |
| 34 | [1969](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/export.go#L1969) | "should generate updated DataVolumeTemplates on http endpoint when exporting" | - | Validates that the export metadata is complete enough to re-import the VM on a different cluster. |

---

### Category 7: Snapshot Operations - 5 tests

**Why this category:** The current suite has basic snapshot tests, but misses important scenarios: snapshots of paused VMs, snapshots with hotplug disks, and multi-volume snapshot behavior. These additional tests validate that snapshot works correctly under the conditions where it's most commonly used in production (during maintenance pauses, after hotplug operations, etc.).

**File:** [`tests/storage/snapshot.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/snapshot.go)

| # | Line | Test Name | Test ID | Why Selected |
|---|------|-----------|---------|----|
| 35 | [190](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/snapshot.go#L190) | "should create a snapshot when VM runStrategy is Manual" | - | Manual runStrategy is used for VMs managed by external orchestration. Snapshot must work regardless of strategy. |
| 36 | [414](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/snapshot.go#L414) | "without volumes with guest agent available" | test_id:6769 | Validates snapshot with guest agent (quiesced I/O). This is the production-recommended path for consistency. |
| 37 | [523](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/snapshot.go#L523) | "should succeed snapshot when VM is paused with Paused indication" | test_id:12182 | Pausing before snapshot is a common admin workflow. Some CSI drivers mishandle the paused state. |
| 38 | [569](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/snapshot.go#L569) | "should succeed online snapshot with hot plug disk" | - | Hotplugged disks must be included in snapshots. If not, restored VMs are missing data. |
| 39 | [1261](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/snapshot.go#L1261) | "Should show included and excluded volumes in the snapshot" | test_id:9705 | Multi-volume VMs need selective snapshot (e.g., skip temp disks). Validates the include/exclude mechanism. |

---

### Category 8: Restore Operations - 5 tests

**Why this category:** Restore is the other half of snapshot. Having a snapshot is useless if restore doesn't work correctly. The current suite has minimal restore coverage. These tests validate restore under the conditions that matter most: repeated restores from the same snapshot, restoring VMs with hotplug disks, and cross-namespace restore (golden image RBAC).

**File:** [`tests/storage/restore.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/restore.go)

| # | Line | Test Name | Test ID | Why Selected |
|---|------|-----------|---------|----|
| 40 | [298](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/restore.go#L298) | "should wait for snapshot to exist and be ready" | - | Validates the restore-waits-for-snapshot flow. Race conditions here can cause silent data corruption. |
| 41 | [1135](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/restore.go#L1135) | "should restore a vm multiple from the same snapshot" | test_id:5259 | A single snapshot is often used to spawn multiple VMs (dev/test environments). Validates clone-from-snapshot. |
| 42 | [1242](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/restore.go#L1242) | "should restore a vm that boots from a datavolume (not template)" | - | Restoring VMs that were created directly (not from template) -- a common path for imported or manually created VMs. |
| 43 | [1657](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/restore.go#L1657) | "should restore vm with hot plug disks" | - | Hotplugged volumes must be correctly restored. Pairs with snapshot test #38 to validate the full cycle. |
| 44 | [2073](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/restore.go#L2073) | "with cross namespace clone ability" (GoldenImageRBAC) | - | Golden images live in a shared namespace. Restore must work across namespace boundaries with proper RBAC. |

---

### Category 9: Storage Fundamentals - 6 tests

**Why this category:** These tests validate the most basic storage primitives that all other operations depend on. EmptyDisk, ephemeral volumes, hostdisk, shared disks, and raw block I/O are the foundation. If any of these fail, the higher-level tests (backup, snapshot, migration) will also fail, but with less clear error messages. Including fundamentals gives providers a clear signal when something is wrong at the base layer.

**File:** [`tests/storage/storage.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go)

| # | Line | Test Name | Test ID | Why Selected |
|---|------|-----------|---------|----|
| 45 | [290](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L290) | "should create a writeable emptyDisk with the right capacity" | test_id:3134 | EmptyDisk is the simplest volume type. If this fails, the storage provider has a fundamental issue. |
| 46 | [327](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L327) | "should create a writeable emptyDisk with the specified serial number" | test_id:3135 | Serial numbers are used by guest OS for device identification. Missing serials break storage automation inside VMs. |
| 47 | [393](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L393) | "started with Ephemeral PVC" | test_id:3136 | Ephemeral PVCs are used for stateless workloads. Validates that the storage provider handles copy-on-write correctly. |
| 48 | [578](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L578) | "should start with multiple hostdisks in the same directory" | test_id:3107 | Multiple hostdisks test concurrent volume mounts on the same node -- catches filesystem locking issues. |
| 49 | [1122](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L1122) | "should successfully start 2 VMs with a shareable disk" | - | Shared disks (RWX) are used for clustered applications (e.g., Oracle RAC). Validates ReadWriteMany support. |
| 50 | [1132](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L1132) | "should successfully write and read data" (block) | - | Raw block I/O is required for high-performance workloads and some database VMs. Validates block device support. |

---

## Summary

| Metric | Before | After |
|--------|--------|-------|
| Tests in Self-Validation | ~27 | ~77 |
| Coverage | ~10% | ~30% |
| Categories with 0 coverage | 4 | 0 |

### Tests by Category

| Category | Tests Added | Current Coverage |
|----------|-------------|-----------------|
| Backup | 5 | None (new) |
| CBT | 4 | None (new) |
| DataVolume | 8 | Partial |
| Migration | 6 | None (new) |
| Hotplug | 6 | None (new) |
| Export | 5 | None (new) |
| Snapshot | 5 | Partial |
| Restore | 5 | Partial |
| Storage | 6 | Partial |
| **Total** | **50** | |

---

## GA Requirements Mapping

The following table maps these 50 tests against the known GA requirements for cloud provider certification:

| GA Requirement | Covered By | Gaps Remaining |
|---|---|---|
| Spin up VM (Linux) | Existing compute conformance tests | - |
| Spin up VM (Windows) | Not in this proposal | Windows tests need separate discussion |
| VM from Upload / Import / Registry | Not in this proposal | Covered in follow-up (cloning & source types) |
| VM from Golden Images | #44 (cross-namespace clone/RBAC), #16 (sourceRef) | Partial |
| Volume Expansion | #10 (PVC expansion), #11 (usable size check) | Covered |
| Snapshot & Restore | #35-39 (snapshot), #40-44 (restore) | Covered |
| Backup & Restore (OADP) | #1-5 (backup), #6-9 (CBT) | Covered |
| Storage Live Migration | #18-23 (migration) | Covered |
| Hotplug Volumes | #24-29 (hotplug) | Covered |
| 20 VMs x 4 disks simultaneously | Not in this proposal | Requires custom scale tests |
| 4 VMs snapshot/restore concurrently | Not in this proposal | Requires custom concurrency tests |
| Snapshot SLA (10s) / Restore SLA (5min) | Not in this proposal | Requires custom timing assertions |
| Multiple storage classes | Not in this proposal | Requires multiple job runs per provider |

---

## What We're NOT Adding

| Category | Reason |
|----------|--------|
| Negative tests ("should fail...", "should reject...") | Per the guiding principle: we validate that infrastructure works, not that it correctly rejects bad input. Negative tests verify KubeVirt feature logic, not storage provider quality. |
| Quarantined tests | Tests in quarantine have known instability. Including them would cause false failures that undermine provider confidence in the suite. |
| Redundant tests | Multiple tests exercising the same code path add runtime without coverage. Each of our 50 tests validates a distinct operation. |
| Edge cases | Tests for unusual configurations (rare volume modes, deprecated features, extreme parameters) don't represent typical infrastructure validation. |
| Scale / SLA tests | These require custom test code with timing assertions and orchestration for concurrent VMs. They are important for GA but belong in a separate proposal due to different implementation requirements. |

---

## Implementation

For each test, add `decorators.StorageCritical` in the upstream [kubevirt/kubevirt](https://github.com/kubevirt/kubevirt) repository:

```go
// Before
It("should migrate the source volume from a source DV to a destination DV", func() {

// After
It("should migrate the source volume from a source DV to a destination DV", decorators.StorageCritical, func() {
```

The self-validation runner already picks up `StorageCritical`-labeled tests automatically via the existing label filter in `scripts/kubevirt/test-kubevirt.sh`:

```bash
if [ "${SIG}" == "storage" ]
then
  label_filter_joined="${label_filter_joined}||(StorageCritical)"
fi
```

No changes are needed in this repository. The work is entirely upstream.

---

## Items for Separate Discussion

| Topic | Question |
|-------|----------|
| **Windows VM** | Is Windows storage testing required for self-validation? If so, tests would come from tier2 (`openshift-virtualization-tests`), not upstream KubeVirt. |
| **Scale limits** | Is the 75 volumes hotplug test (#27) practical for all providers? Some cloud storage backends have lower attach limits. |
| **Cloning tests** | Clone operations (smart clone, host-assisted clone) are not in this proposal but are needed for full VM provisioning coverage. |
| **VM source types** | Upload, HTTP import, registry import are common provisioning methods not covered here. |
| **Scale / SLA tests** | 20 VMs x 4 disks, concurrent snapshot/restore, timing SLAs -- these need custom tests and a separate proposal. |

---

## References

- [Self-Validation Coverage](https://github.com/Ahmad-Hafe/ocp-virt-validation-checkup/blob/main/docs/STORAGE_TEST_COVERAGE.md)
- [Storage Checkup Coverage](https://github.com/Ahmad-Hafe/kubevirt-storage-checkup/blob/main/docs/STORAGE_CHECKUP_COVERAGE.md)
- [GA Criteria Document](https://docs.google.com/document/d/1XzBQtMQLMS3yidhqFhQDh1UYXB3yimIKUQtggJWABfM/edit?tab=t.0)
- [Gap Analysis Jira](https://redhat.atlassian.net/browse/CNV-84224)
