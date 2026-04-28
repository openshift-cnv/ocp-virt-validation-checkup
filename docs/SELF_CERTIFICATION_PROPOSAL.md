# Storage Self-Certification Suite Proposal

## Goal

Create a self-certification suite that proves storage infrastructure works well for virtualization, enabling cloud providers to validate their environment without Red Hat running tests.

**Guiding Principle (from @ngavrilo):**
> "Our goal is to include tests in the self validation suite that cover what we believe is important, tests that check that the infrastructure, cloud and provided storage functions well and supports virtualization. Not simply running as much tests as possible, nor testing negative cases for features."

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

**File:** [`tests/storage/backup.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/backup.go)

| # | Line | Test Name | Test ID |
|---|------|-----------|---------|
| 1 | [84](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/backup.go#L84) | "Full Backup with source VirtualMachine" | - |
| 2 | [302](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/backup.go#L302) | "Incremental Backup after VM shutdown and restart" | - |
| 3 | [803](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/backup.go#L803) | "Full and Incremental pull mode Backup with endpoint verification" | - |
| 4 | [882](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/backup.go#L882) | "Pull mode backup data integrity and export immutability" | - |
| 5 | [1158](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/backup.go#L1158) | "should preserve checkpoints and perform incremental backup after live migration" | - |

---

### Category 2: CBT - Changed Block Tracking - 4 tests

**File:** [`tests/storage/cbt.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/cbt.go)

| # | Line | Test Name | Test ID |
|---|------|-----------|---------|
| 6 | [71](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/cbt.go#L71) | "VM matches cbt label selector, then unmatches" | - |
| 7 | [196](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/cbt.go#L196) | "should create CBT overlay for hotplug volume and remove it on unplug" | - |
| 8 | [268](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/cbt.go#L268) | "should persist CBT data across restart" | - |
| 9 | [284](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/cbt.go#L284) | "should persist CBT data across live migration" | - |

---

### Category 3: DataVolume Operations - 8 tests

**File:** [`tests/storage/datavolume.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go)

| # | Line | Test Name | Test ID |
|---|------|-----------|---------|
| 10 | [125](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L125) | "PVC expansion is detected by VM and can be fully used" | - |
| 11 | [208](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L208) | "Check disk expansion accounts for actual usable size" | - |
| 12 | [305](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L305) | "should successfully start multiple concurrent VMIs" | test_id:6686 |
| 13 | [349](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L349) | "should be successfully started when using a PVC volume owned by a DataVolume" | test_id:5252 |
| 14 | [598](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L598) | "should be successfully started and stopped multiple times" | test_id:3191 |
| 15 | [619](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L619) | "deleting VM should automatically delete DataVolumes and VMI owned by VM" | test_id:837 |
| 16 | [836](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L836) | "should resolve DataVolume sourceRef" | - |
| 17 | [1019](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L1019) | "fstrim from the VM influences disk.img" | test_id:5894 |

---

### Category 4: Storage Migration - 6 tests

**File:** [`tests/storage/migration.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go)

| # | Line | Test Name | Test ID |
|---|------|-----------|---------|
| 18 | [300](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L300) | "should migrate the source volume from a source DV to a destination PVC" | - |
| 19 | [374](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L374) | "should migrate the source volume from a source DV to a destination DV" | - |
| 20 | [400](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L400) | "should continously report storage migration metrics" | - |
| 21 | [474](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L474) | "should trigger the migration once the destination DV exists" | - |
| 22 | [604](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L604) | "should migrate the source volume from a block source and filesystem destination DVs" | - |
| 23 | [638](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L638) | "should migrate a PVC with a VM using a containerdisk" | - |

---

### Category 5: Hotplug Operations - 6 tests

**File:** [`tests/storage/hotplug.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go)

| # | Line | Test Name | Test ID |
|---|------|-----------|---------|
| 24 | [759](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go#L759) | "Should be able to add and use WFFC local storage" | - |
| 25 | [968](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go#L968) | "Should be able to add and remove and re-add multiple volumes" | - |
| 26 | [1059](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go#L1059) | "Should be able to add and remove multiple volumes" | - |
| 27 | [1118](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go#L1118) | "should allow to hotplug 75 volumes simultaneously" | - |
| 28 | [1274](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go#L1274) | "should allow hotplugging both a filesystem and block volume" | - |
| 29 | [1162](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/hotplug.go#L1162) | "should permanently add hotplug volume when added to VM" | - |

---

### Category 6: Export Operations - 5 tests

**File:** [`tests/storage/export.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/export.go)

| # | Line | Test Name | Test ID |
|---|------|-----------|---------|
| 30 | [611](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/export.go#L611) | "should make sure PVC export is Ready when source pod is Completed" | - |
| 31 | [1422](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/export.go#L1422) | "should create export from VMSnapshot" | - |
| 32 | [1447](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/export.go#L1447) | "should export a restored VM disk as raw image, not archive" | - |
| 33 | [1570](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/export.go#L1570) | "should create export from VMSnapshot with multiple volumes" | - |
| 34 | [1969](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/export.go#L1969) | "should generate updated DataVolumeTemplates on http endpoint when exporting" | - |

---

### Category 7: Snapshot Operations - 5 tests

**File:** [`tests/storage/snapshot.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/snapshot.go)

| # | Line | Test Name | Test ID |
|---|------|-----------|---------|
| 35 | [190](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/snapshot.go#L190) | "should create a snapshot when VM runStrategy is Manual" | - |
| 36 | [414](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/snapshot.go#L414) | "without volumes with guest agent available" | test_id:6769 |
| 37 | [523](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/snapshot.go#L523) | "should succeed snapshot when VM is paused with Paused indication" | test_id:12182 |
| 38 | [569](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/snapshot.go#L569) | "should succeed online snapshot with hot plug disk" | - |
| 39 | [1261](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/snapshot.go#L1261) | "Should show included and excluded volumes in the snapshot" | test_id:9705 |

---

### Category 8: Restore Operations - 5 tests

**File:** [`tests/storage/restore.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/restore.go)

| # | Line | Test Name | Test ID |
|---|------|-----------|---------|
| 40 | [298](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/restore.go#L298) | "should wait for snapshot to exist and be ready" | - |
| 41 | [1135](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/restore.go#L1135) | "should restore a vm multiple from the same snapshot" | test_id:5259 |
| 42 | [1242](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/restore.go#L1242) | "should restore a vm that boots from a datavolume (not template)" | - |
| 43 | [1657](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/restore.go#L1657) | "should restore vm with hot plug disks" | - |
| 44 | [2073](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/restore.go#L2073) | "with cross namespace clone ability" (GoldenImageRBAC) | - |

---

### Category 9: Storage Fundamentals - 6 tests

**File:** [`tests/storage/storage.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go)

| # | Line | Test Name | Test ID |
|---|------|-----------|---------|
| 45 | [290](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L290) | "should create a writeable emptyDisk with the right capacity" | test_id:3134 |
| 46 | [327](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L327) | "should create a writeable emptyDisk with the specified serial number" | test_id:3135 |
| 47 | [393](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L393) | "started with Ephemeral PVC" | test_id:3136 |
| 48 | [578](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L578) | "should start with multiple hostdisks in the same directory" | test_id:3107 |
| 49 | [1122](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L1122) | "should successfully start 2 VMs with a shareable disk" | - |
| 50 | [1132](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L1132) | "should successfully write and read data" (block) | - |

---

## Summary

| Metric | Before | After |
|--------|--------|-------|
| Tests in Self-Validation | ~27 | ~77 |
| Coverage | ~10% | ~30% |
| Categories with 0 coverage | 4 | 0 |

### Tests by Category

| Category | Tests Added |
|----------|-------------|
| Backup | 5 |
| CBT | 4 |
| DataVolume | 8 |
| Migration | 6 |
| Hotplug | 6 |
| Export | 5 |
| Snapshot | 5 |
| Restore | 5 |
| Storage | 6 |
| **Total** | **50** |

---

## What We're NOT Adding

| Category | Reason |
|----------|--------|
| Negative tests ("should fail...", "should reject...") | Not proving infrastructure works |
| Quarantine tests | Unstable |
| Redundant tests | Same functionality tested multiple ways |
| Edge cases | Not core functionality |

---

## Implementation

For each test, add `decorators.StorageCritical`:

```go
// Before
It("should migrate the source volume from a source DV to a destination DV", func() {

// After
It("should migrate the source volume from a source DV to a destination DV", decorators.StorageCritical, func() {
```

---

## Items for Separate Discussion

| Topic | Question |
|-------|----------|
| **Windows VM** | Is Windows storage testing required? |
| **Scale limits** | Is 75 volumes test practical for users? |

---

## References

- [Self-Validation Coverage](https://github.com/Ahmad-Hafe/ocp-virt-validation-checkup/blob/main/docs/STORAGE_TEST_COVERAGE.md)
- [Storage Checkup Coverage](https://github.com/Ahmad-Hafe/kubevirt-storage-checkup/blob/main/docs/STORAGE_CHECKUP_COVERAGE.md)
- [GA Criteria Document](https://docs.google.com/document/d/1XzBQtMQLMS3yidhqFhQDh1UYXB3yimIKUQtggJWABfM/edit?tab=t.0)
- [Gap Analysis Jira](https://redhat.atlassian.net/browse/CNV-84224)
