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

Core positive functionality NOT currently tested:

| # | Capability | Self-Validation | Storage Checkup | Impact |
|---|------------|-----------------|-----------------|--------|
| 1 | **Volume Expansion** | ❌ | ❌ | Cannot verify storage supports disk expansion |
| 2 | **Storage Migration** | ❌ | ❌ | Cannot verify data can move between volumes |
| 3 | **Hotplug Persistence** | ❌ | ❌ | Cannot verify hotplug survives VM restart |

---

## Proposed Additions

### Add 3 Tests to Self-Validation

| # | Test Name | File Location | Current Labels | Proposed Change |
|---|-----------|---------------|----------------|-----------------|
| 1 | "PVC expansion is detected by VM and can be fully used" | `tests/storage/datavolume.go:125` | `StorageReq, RequiresVolumeExpansion` | Add `StorageCritical` |
| 2 | "should migrate the source volume from a source DV to a destination DV" | `tests/storage/migration.go:374` | None | Add `StorageCritical` |
| 3 | "should permanently add hotplug volume when added to VM" | `tests/storage/hotplug.go:1162` | `Quarantine` | Remove `Quarantine`, Add `StorageCritical` |

### Why These Tests?

| Test | What It Proves |
|------|----------------|
| **Volume Expansion** | Storage infrastructure supports growing VM disks - core feature for production workloads |
| **Storage Migration** | Data can be moved between volumes - essential for maintenance and upgrades |
| **Hotplug Persistence** | Hotplug configuration survives VM restart - proves feature works end-to-end |

### What We're NOT Adding

| Category | Reason |
|----------|--------|
| Negative test cases | Not proving infrastructure works |
| Edge cases | Not core functionality |
| Scale tests (75 volumes) | Impractical for user self-certification |
| Timing/performance tests | Storage checkup handles basic validation |
| 4-disk specific tests | 1-2 disks proves the concept works |

---

## Combined Self-Certification Coverage

After proposed additions:

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
