# Storage Self-Certification Suite Proposal

## Goal

Create a self-certification suite that proves storage infrastructure works well for virtualization, enabling cloud providers to validate their environment without Red Hat running tests.

**Guiding Principle (from @ngavrilo):**
> "Our goal is to include tests in the self validation suite that cover what we believe is important, tests that check that the infrastructure, cloud and provided storage functions well and supports virtualization. Not simply running as much tests as possible, nor testing negative cases for features."

---

## Current Coverage

### Self-Validation (Default Mode)
Tests with `(sig-storage && conformance) || StorageCritical` labels.

| Capability | Status | Notes |
|------------|--------|-------|
| VM boot from DataVolume | ✅ | Multiple test cases |
| Upload | ✅ | Upload to PVC tests |
| Import (HTTP/Registry) | ✅ | Registry import tests |
| Snapshot | ✅ | Online/offline snapshots |
| Restore | ✅ | VM restore from snapshot |
| Clone | ✅ | DataVolume cloning |
| Hotplug/Unplug | ✅ | Add/remove volumes |
| Live Migration | ✅ | With hotplug volumes |
| Export | ✅ | PVC/VM export |

### Storage Checkups
Quick diagnostic checks (not E2E tests).

| Check | Status | Notes |
|-------|--------|-------|
| Default storage class | ✅ | Validates configuration |
| PVC binding | ✅ | Storage provisioner works |
| Golden image health | ✅ | DataImportCron status |
| VM boot from golden image | ✅ | End-to-end boot test |
| Clone type detection | ✅ | Reports smart/host-assisted |
| Live migration | ✅ | Single disk |
| Hotplug/Unplug | ✅ | Add + remove |
| Concurrent VM boot | ✅ | Configurable N VMs |

---

## Identified Gaps

Core functionality needed to prove "storage works well for virtualization":

| # | Capability | Self-Validation | Storage Checkup | Impact |
|---|------------|-----------------|-----------------|--------|
| 1 | **Volume Expansion** | ❌ | ❌ | Cannot verify storage supports disk growth |
| 2 | **Storage Migration** | ❌ | ❌ | Cannot verify data moves between volumes |
| 3 | **Hotplug Persistence** | ❌ | ❌ | Cannot verify hotplug survives VM restart |
| 4 | **Block Storage Hotplug** | ⚠️ Partial | ❌ | Block mode hotplug not fully validated |
| 5 | **Cross-mode Migration** | ❌ | ❌ | Block↔Filesystem migration not tested |
| 6 | **Multi-volume Operations** | ⚠️ Partial | ❌ | Multiple disks not explicitly tested |
| 7 | **Data Integrity** | ⚠️ Partial | ❌ | Write/read verification limited |

---

## Proposed Additions

### Add 7 Tests to Self-Validation

#### Priority 1: Core Storage Features (Must Have)

| # | Test Name | File Location | Current Labels | Proposed Change |
|---|-----------|---------------|----------------|-----------------|
| 1 | "PVC expansion is detected by VM and can be fully used" | `tests/storage/datavolume.go:125` | `StorageReq, RequiresVolumeExpansion` | Add `StorageCritical` |
| 2 | "should migrate the source volume from a source DV to a destination DV" | `tests/storage/migration.go:374` | None | Add `StorageCritical` |
| 3 | "should permanently add hotplug volume when added to VM" | `tests/storage/hotplug.go:1162` | `Quarantine` | Remove `Quarantine`, Add `StorageCritical` |

#### Priority 2: Storage Mode Coverage (Important)

| # | Test Name | File Location | Current Labels | Proposed Change |
|---|-----------|---------------|----------------|-----------------|
| 4 | "should migrate the source volume from a block source and filesystem destination DVs" | `tests/storage/migration.go:604` | `RequiresBlockStorage` | Add `StorageCritical` |
| 5 | "should be able to add and remove volumes" (block entries) | `tests/storage/hotplug.go` | `RequiresBlockStorage` | Add `StorageCritical` |

#### Priority 3: Multi-Volume & Data Integrity (Recommended)

| # | Test Name | File Location | Current Labels | Proposed Change |
|---|-----------|---------------|----------------|-----------------|
| 6 | "Should be able to add and remove multiple volumes" | `tests/storage/hotplug.go:1059` | None | Add `StorageCritical` |
| 7 | "should successfully write and read data" (block) | `tests/storage/storage.go` | `RequiresBlockStorage` | Add `StorageCritical` |

### What Each Test Proves

| # | Test | What It Proves for Virtualization |
|---|------|-----------------------------------|
| 1 | **Volume Expansion** | Storage supports growing VM disks - essential for production workloads |
| 2 | **Storage Migration** | Data can move between volumes - needed for maintenance/upgrades |
| 3 | **Hotplug Persistence** | Hotplug config survives restart - proves feature is production-ready |
| 4 | **Block↔FS Migration** | Both storage modes can migrate - proves flexibility |
| 5 | **Block Hotplug** | Block storage works for dynamic attachment - validates block mode |
| 6 | **Multi-volume** | Multiple disks work together - proves real-world scenarios |
| 7 | **Data Integrity** | Written data reads correctly - fundamental storage guarantee |

### What We're NOT Adding

| Category | Reason |
|----------|--------|
| Negative test cases | Not proving infrastructure works |
| Scale tests (75 volumes) | Impractical for user self-certification |
| Timing/performance tests | Not core functionality validation |
| Edge cases / error handling | Focus is on positive validation |

---

## Combined Self-Certification Coverage

After proposed additions (7 tests):

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
| **Volume Expansion** | ✅ (new) | ❌ | ✅ |
| **Storage Migration** | ✅ (new) | ❌ | ✅ |
| **Hotplug Persistence** | ✅ (new) | ❌ | ✅ |
| **Block↔FS Migration** | ✅ (new) | ❌ | ✅ |
| **Block Hotplug** | ✅ (new) | ❌ | ✅ |
| **Multi-volume Ops** | ✅ (new) | ❌ | ✅ |
| **Data Integrity** | ✅ (new) | ❌ | ✅ |

### Summary of Changes

| Metric | Before | After |
|--------|--------|-------|
| Tests in Self-Validation | ~25 | ~32 |
| Core capabilities covered | 11 | 18 |
| Storage modes validated | Filesystem | Filesystem + Block |

---

## Items for Separate Discussion

| Topic | Question |
|-------|----------|
| **Windows VM** | Is Windows storage testing required for self-certification? Currently no Windows tests in storage component. |
| **Multi-disk (4 disks)** | Is 1-2 disk testing sufficient to prove functionality? |
| **Concurrent operations** | Storage checkup tests N VMs - is this sufficient? |

---

## Implementation Plan

1. **Review**: Get approval from @ngavrilo, @orenc on proposed additions
2. **PR to KubeVirt**: Add `StorageCritical` decorator to the 3 tests
3. **Verify**: Confirm tests appear in self-validation after merge
4. **Document**: Update coverage documentation

---

## References

- [Self-Validation Coverage](https://github.com/Ahmad-Hafe/ocp-virt-validation-checkup/blob/main/docs/STORAGE_TEST_COVERAGE.md)
- [Storage Checkup Coverage](https://github.com/Ahmad-Hafe/kubevirt-storage-checkup/blob/main/docs/STORAGE_CHECKUP_COVERAGE.md)
- [GA Criteria Document](https://docs.google.com/document/d/1XzBQtMQLMS3yidhqFhQDh1UYXB3yimIKUQtggJWABfM/edit?tab=t.0)
- [Gap Analysis Jira](https://redhat.atlassian.net/browse/CNV-84224)
