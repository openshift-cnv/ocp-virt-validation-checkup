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
| Currently in self-validation | ~27 |
| Current coverage | ~10% |
| Categories with 0 coverage | 4 (backup, cbt, storage, reservation) |

---

## Current Coverage by Category

| Category | Total Tests | In Self-Validation | Gap |
|----------|-------------|-------------------|-----|
| backup.go | 18 | 0 | **18** |
| cbt.go | 5 | 0 | **5** |
| datavolume.go | 22 | 2 | 20 |
| export.go | 30 | 2 | 28 |
| hotplug.go | 41 | 9 | 32 |
| migration.go | 28 | 1 | **27** |
| restore.go | 34 | 6 | 28 |
| snapshot.go | 25 | 6 | 19 |
| storage.go | 29 | 0 | **29** |
| memorydump.go | 7 | 1 | 6 |

---

## Proposed Additions: 26 Tests

### Category 1: Backup (Enterprise Critical) - 5 tests

Backup is essential for enterprise virtualization. Currently **0 tests** in self-validation.

| # | Test Name | File:Line | Why It's Important |
|---|-----------|-----------|-------------------|
| 1 | "Full Backup with source VirtualMachine" | `backup.go:84` | Proves full VM backup works |
| 2 | "Incremental Backup after VM shutdown and restart" | `backup.go:302` | Proves incremental backup works |
| 3 | "Full and Incremental pull mode Backup with endpoint verification" | `backup.go:803` | Proves pull mode backup works |
| 4 | "Pull mode backup data integrity and export immutability" | `backup.go:882` | Proves backup data is correct |
| 5 | "should preserve checkpoints and perform incremental backup after live migration" | `backup.go:1158` | Proves backup works with migration |

### Category 2: CBT - Changed Block Tracking (Backup Integration) - 3 tests

CBT is critical for efficient incremental backups. Currently **0 tests** in self-validation.

| # | Test Name | File:Line | Why It's Important |
|---|-----------|-----------|-------------------|
| 6 | "should persist CBT data across restart" | `cbt.go:268` | Proves CBT survives restart |
| 7 | "should persist CBT data across live migration" | `cbt.go:284` | Proves CBT survives migration |
| 8 | "should create CBT overlay for hotplug volume and remove it on unplug" | `cbt.go:196` | Proves CBT works with hotplug |

### Category 3: DataVolume (Core Operations) - 3 tests

| # | Test Name | File:Line | Why It's Important |
|---|-----------|-----------|-------------------|
| 9 | "PVC expansion is detected by VM and can be fully used" | `datavolume.go:125` | Proves volume expansion works |
| 10 | "should successfully start multiple concurrent VMIs" | `datavolume.go:305` | Proves concurrent VM boot works |
| 11 | "should resolve DataVolume sourceRef" | `datavolume.go:836` | Proves DataSource/golden images work |

### Category 4: Storage Migration - 5 tests

Storage migration has only **1 test** in self-validation. Critical for maintenance/upgrades.

| # | Test Name | File:Line | Why It's Important |
|---|-----------|-----------|-------------------|
| 12 | "should migrate the source volume from a source DV to a destination DV" | `migration.go:374` | Basic storage migration |
| 13 | "should migrate the source volume from a source DV to a destination PVC" | `migration.go:300` | Migration with expansion |
| 14 | "should migrate the source volume from a block source and filesystem destination DVs" | `migration.go:604` | Cross-mode migration |
| 15 | "should continously report storage migration metrics" | `migration.go:400` | Proves observability works |
| 16 | "should migrate a PVC with a VM using a containerdisk" | `migration.go:638` | Mixed storage scenario |

### Category 5: Hotplug (Advanced Operations) - 3 tests

| # | Test Name | File:Line | Why It's Important |
|---|-----------|-----------|-------------------|
| 17 | "should permanently add hotplug volume when added to VM" | `hotplug.go:1162` | Proves hotplug persists after reboot |
| 18 | "Should be able to add and remove multiple volumes" | `hotplug.go:1059` | Proves multi-volume works |
| 19 | "should allow to hotplug 75 volumes simultaneously" | `hotplug.go:1118` | Proves scale/stress |

### Category 6: Storage Fundamentals - 4 tests

Basic storage operations have **0 tests** in self-validation.

| # | Test Name | File:Line | Why It's Important |
|---|-----------|-----------|-------------------|
| 20 | "should create a writeable emptyDisk with the right capacity" | `storage.go:290` | Proves emptyDisk works |
| 21 | "started with Ephemeral PVC" | `storage.go:393` | Proves ephemeral storage works |
| 22 | "should start with multiple hostdisks in the same directory" | `storage.go:578` | Proves hostdisk works |
| 23 | "should successfully write and read data" (block) | `storage.go` | Proves data integrity |

### Category 7: Export - 2 tests

| # | Test Name | File:Line | Why It's Important |
|---|-----------|-----------|-------------------|
| 24 | "should create export from VMSnapshot with multiple volumes" | `export.go:1570` | Proves multi-volume export |
| 25 | "should export a restored VM disk as raw image, not archive" | `export.go` | Proves export format |

### Category 8: Restore - 1 test

| # | Test Name | File:Line | Why It's Important |
|---|-----------|-----------|-------------------|
| 26 | "with cross namespace clone ability" (context) | `restore.go:2073` | Proves golden image RBAC + host-assisted clone |

---

## What We're NOT Adding

| Category | Examples | Reason |
|----------|----------|--------|
| Negative tests | "should fail when...", "should reject..." | Not proving infrastructure works |
| Edge cases | Corrupted data, timeouts | Not core functionality |
| Quarantine tests | Unstable tests | May cause false failures |
| Performance tests | Timing assertions | Storage checkup handles basic validation |

---

## Summary of Changes

| Metric | Before | After |
|--------|--------|-------|
| Tests in Self-Validation | ~27 | ~53 |
| Coverage | ~10% | ~21% |
| Categories with 0 coverage | 4 | 0 |

### Coverage by Category After Changes

| Category | Before | After |
|----------|--------|-------|
| Backup | 0 | 5 |
| CBT | 0 | 3 |
| DataVolume | 2 | 5 |
| Migration | 1 | 6 |
| Hotplug | 9 | 12 |
| Storage | 0 | 4 |
| Export | 2 | 4 |
| Restore | 6 | 7 |

---

## Combined Self-Certification Coverage

After proposed additions, Self-Validation + Storage Checkups covers:

| Core Capability | Self-Validation | Storage Checkup | Combined |
|-----------------|-----------------|-----------------|----------|
| VM boot | ✅ | ✅ | ✅ |
| Import/Upload | ✅ | ❌ | ✅ |
| Snapshot | ✅ | ❌ | ✅ |
| Restore | ✅ | ❌ | ✅ |
| Clone | ✅ | ✅ | ✅ |
| Hotplug | ✅ | ✅ | ✅ |
| Live Migration | ✅ | ✅ | ✅ |
| Export | ✅ | ❌ | ✅ |
| **Backup** | ✅ (new) | ❌ | ✅ |
| **CBT** | ✅ (new) | ❌ | ✅ |
| **Volume Expansion** | ✅ (new) | ❌ | ✅ |
| **Storage Migration** | ✅ (new) | ❌ | ✅ |
| **Hotplug Persistence** | ✅ (new) | ❌ | ✅ |
| **Block Storage** | ✅ (new) | ❌ | ✅ |
| **Multi-volume** | ✅ (new) | ❌ | ✅ |
| **Data Integrity** | ✅ (new) | ❌ | ✅ |
| **EmptyDisk/Ephemeral** | ✅ (new) | ❌ | ✅ |

---

## Items for Separate Discussion

| Topic | Question |
|-------|----------|
| **Windows VM** | Is Windows storage testing required? Currently no Windows tests in storage component. |
| **Timing requirements** | Are 10s snapshot / 5min restore hard requirements? |
| **Scale testing** | Is 75 volumes test practical for users, or should it be optional? |

---

## Implementation Plan

1. **Review**: Get approval from @ngavrilo, @orenc on proposed 26 tests
2. **Prioritize**: Identify which tests to add first (recommend: Backup, CBT, Migration)
3. **PR to KubeVirt**: Add `StorageCritical` decorator to approved tests
4. **Verify**: Confirm tests appear in self-validation after merge
5. **Document**: Update coverage documentation

---

## Implementation: Adding StorageCritical Label

For each test, add `decorators.StorageCritical`:

```go
// Before
It("should migrate the source volume from a source DV to a destination DV", func() {

// After
It("should migrate the source volume from a source DV to a destination DV", decorators.StorageCritical, func() {
```

For tests in `Quarantine`, also remove that decorator if the test is stable.

---

## References

- [Self-Validation Coverage](https://github.com/Ahmad-Hafe/ocp-virt-validation-checkup/blob/main/docs/STORAGE_TEST_COVERAGE.md)
- [Storage Checkup Coverage](https://github.com/Ahmad-Hafe/kubevirt-storage-checkup/blob/main/docs/STORAGE_CHECKUP_COVERAGE.md)
- [GA Criteria Document](https://docs.google.com/document/d/1XzBQtMQLMS3yidhqFhQDh1UYXB3yimIKUQtggJWABfM/edit?tab=t.0)
- [Gap Analysis Jira](https://redhat.atlassian.net/browse/CNV-84224)
