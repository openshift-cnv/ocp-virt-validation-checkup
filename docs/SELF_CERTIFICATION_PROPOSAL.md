# Storage Self-Certification Suite Proposal

## Goal

Create a self-certification suite that proves storage infrastructure works well for virtualization, enabling cloud providers to validate their environment without Red Hat running tests.

**Guiding Principle :**
> "Our goal is to include tests in the self validation suite that cover what we believe is important, tests that check that the infrastructure, cloud and provided storage functions well and supports virtualization, Not simply running as much tests as possible, nor testing negative cases for features."

---

## Why This Proposal

The self-validation suite is the gate cloud providers must pass to certify their storage infrastructure for OpenShift Virtualization. While storage coverage has grown significantly through upstream `StorageCritical` tagging, important gaps remain in categories that directly affect day-2 operations.

This proposal identifies what is already covered, what is still missing, and recommends specific tests to close the remaining gaps.

### Selection Criteria

Every proposed test was chosen based on:

1. **Positive validation only** -- proves something works, does not test failure paths.
2. **Core functionality** -- each test covers a distinct code path that customers use in production.
3. **Upstream-maintained** -- all tests come from [kubevirt/kubevirt](https://github.com/kubevirt/kubevirt/tree/main/tests/storage).
4. **Stability** -- none of the selected tests appear in the quarantine list.
5. **Storage-infrastructure sensitivity** -- each test exercises the storage layer in a way that would surface provider-specific issues.

---

## Current State (Verified June 16, 2026 on test-gcnv16)

The self-validation suite currently runs **71 storage tests**, picked up by the label filter `(sig-storage&&conformance)||(StorageCritical)`.

| Label | Count |
|-------|-------|
| `StorageCritical` | 60 |
| `conformance` (sig-storage) | 11 |
| **Total** | **71** |

### Current Coverage by Category

| Category | Tests | Source Label | Status |
|----------|-------|-------------|--------|
| Hotplug | 27 | StorageCritical | Well covered (offline, online, legacy, declarative, VMI, WFFC, block, migration) |
| Export | 11 | StorageCritical | Well covered (RAW, gzipped, archive, block, PROXY variants, multi-volume) |
| Restore | 11 | StorageCritical | Well covered (datavolumetemplate, online snapshot, guest agent, instancetype/preferences) |
| DataVolume (clone RBAC) | 9 | conformance | Covered, but only clone permission checking |
| Snapshot | 7 | StorageCritical | Covered (simple VM, running VM, guest agent, instancetype/preferences, complicated VM) |
| Memory dump | 2 | StorageCritical | Covered |
| Backup | 1 | StorageCritical | Minimal -- only incremental backup after live migration (PENDING status) |
| Storage Migration | 1 | StorageCritical | Minimal -- only block RWX DV migration |
| ImageUpload | 1 | StorageCritical | Minimal |
| Guestfs | 1 | conformance | Minimal |
| **DataVolume lifecycle** | **1** | conformance | **Minimal** -- only start/stop, no expansion/fstrim/concurrent/cleanup |
| **Storage fundamentals** | **0** | - | **Not covered** -- no emptyDisk, ephemeral, hostdisk, shareable, block I/O |

### Current 71 Tests (Full List)

<details>
<summary>Click to expand full test list</summary>

**Hotplug (27 tests):**
1. Offline VM - add volumes with DataVolume
2. Offline VM - add volumes with PersistentVolume
3. Offline VM block - boot from block volume
4. Offline VM block - start with hotplug block DataVolume
5. Offline VM block - start with hotplug block PersistentVolume
6. WFFC storage - boot from WFFC local storage
7. VMI - add/remove volume with DataVolume immediate attach, VMI directly
8. VMI - add/remove volume with PersistentVolume immediate attach, VMI directly
9. Online VM (legacy) - add/remove DataVolume immediate attach
10. Online VM (legacy) - add/remove PersistentVolume immediate attach
11. Online VM (legacy) - add/remove DataVolume wait for VM to finish starting
12. Online VM (legacy) - add/remove PersistentVolume wait for VM to finish starting
13. Online VM (legacy) - add/remove Block DataVolume immediate attach
14. Online VM (declarative) - add/remove DataVolume immediate attach
15. Online VM (declarative) - add/remove PersistentVolume immediate attach
16. Online VM (declarative) - add/remove DataVolume wait for VM to finish starting
17. Online VM (declarative) - add/remove PersistentVolume wait for VM to finish starting
18. Online VM (declarative) - add/remove Block DataVolume immediate attach
19. Online VM - add/remove DataVolume immediate attach
20. Online VM - add/remove PersistentVolume immediate attach
21. Online VM - add/remove DataVolume wait for VM to finish starting
22. Online VM - add/remove PersistentVolume wait for VM to finish starting
23. Online VM - add/remove Block DataVolume immediate attach
24. Online VM - add/remove DataVolume immediate attach (virtio)
25. Online VM - add/remove PersistentVolume immediate attach (virtio)
26. VMI migration - live migration with attached hotplug volumes containerDisk VMI
27. VMI migration - live migration with attached hotplug volumes persistent disk VMI

**Export (11 tests):**
28. PVC export - RAW kubevirt content type
29. PVC export - RAW gzipped kubevirt content type
30. PVC export - archive content type
31. PVC export - archive tarred gzipped content type
32. PVC export - RAW kubevirt block
33. PVC export - RAW kubevirt PROXY
34. PVC export - RAW gzipped PROXY
35. PVC export - archive PROXY
36. PVC export - archive tarred gzipped PROXY
37. PVC export - RAW kubevirt block PROXY
38. Generate DVs and expanded VM definition on http endpoint with multiple volumes

**Restore (11 tests):**
39. Restore VM from datavolumetemplate - to same VM
40. Restore VM from datavolumetemplate - to new VM
41. Restore from online snapshot - to same VM, stop after create restore
42. Restore from online snapshot - to new VM
43. Restore online snapshot with guest agent - to same VM
44. Restore online snapshot with guest agent - to new VM
45. Restore to new VM with changed name and MAC address
46. Instancetype/preferences - use existing ControllerRevisions (running VM)
47. Instancetype/preferences - use existing ControllerRevisions (stopped VM)
48. Instancetype/preferences - create new ControllerRevisions (running VM)
49. Instancetype/preferences - create new ControllerRevisions (stopped VM)

**DataVolume Clone RBAC (9 conformance tests):**
50. Clone permission - explicit role
51. Clone permission - implicit role
52. Clone permission - explicit role (all namespaces)
53. Clone permission - explicit role (one namespace)
54. Clone permission - explicit role snapshot clone
55. Clone permission - implicit insufficient role snapshot clone
56. Clone permission - implicit sufficient role snapshot clone
57. Clone permission - explicit role (all namespaces) snapshot clone
58. Clone permission - explicit role (one namespace) snapshot clone

**Snapshot (7 tests):**
59. Simple VM - should successfully create a snapshot
60. Simple VM - create snapshot when VM is running should succeed
61. Online VM snapshot - with volumes and guest agent available
62. Online VM snapshot - with volumes and no guest agent available
63. Complicated VM - should successfully create a snapshot
64. Instancetype/preferences - snapshot with running source VM
65. Instancetype/preferences - snapshot with stopped source VM

**Memory dump (2 tests):**
66. Run multiple memory dumps
67. virtctl - get and remove memory dump

**Backup (1 test):**
68. Incremental backup after live migration (PENDING)

**Storage Migration (1 test):**
69. Migrate source volume from block RWX DVs

**ImageUpload (1 test):**
70. Upload image and start VMI with DataVolume

**Guestfs (1 conformance test):**
71. Run guestfs command on a block-based PVC

</details>

---

## Gap Analysis: What's Missing

### Categories with Zero or Minimal Coverage

| Category | Current | Gap | Impact |
|----------|---------|-----|--------|
| **Storage Migration** | 1 test | 1 test missing | Only block RWX tested. DV-to-DV migration not covered. |
| **DataVolume Lifecycle** | 1 test | 4 tests missing | No concurrent VMIs, no fstrim, no cleanup validation, no sourceRef. |
| **Storage Fundamentals** | 0 tests | Full gap | EmptyDisk, ephemeral PVC, hostdisk, shareable disk, block I/O untested. |

### Categories with Good Coverage (No Action Needed)

| Category | Current | Assessment |
|----------|---------|------------|
| Hotplug | 27 tests | Comprehensive. Covers offline, online (3 modes), VMI, WFFC, block, migration. |
| Export | 11 tests | Comprehensive. Covers all content types, block, PROXY, multi-volume. |
| Restore | 11 tests | Comprehensive. Covers datavolumetemplate, online snapshot, guest agent, instancetype. |
| Snapshot | 7 tests | Good. Covers simple/running/online/complicated VMs, instancetype. |
| DataVolume Clone RBAC | 9 tests | Good. Covers explicit/implicit roles, namespace scoping, snapshot clone. |

---

## Proposed Additions: 11 Tests

Based on the verified current state, the following **11 tests** are needed to close the remaining gaps. All 11 tests were validated on a live cluster (test-gcnv16, GCP Hyperdisk) and passed.

> **Note:** The following tests were evaluated but removed from this proposal after failing validation:
> - **CBT tests** -- require cluster-level feature gate not universally available.
> - **Backup tests** -- depend on CBT being enabled; fail without it.
> - **PVC expansion tests** -- block volume expansion notification doesn't propagate to guest on all storage drivers.
> - **Block-to-filesystem migration** -- cross-mode migration not supported on all storage classes.
>
> These should be revisited once the underlying infrastructure requirements are more broadly available.

---

### Category 1: DataVolume Lifecycle - 4 tests to add

**Why:** The current DataVolume tests are entirely clone RBAC (conformance) and one start/stop test. Concurrent VM startup, cleanup, sourceRef resolution, and fstrim (thin provisioning) are all missing. These are basic day-1 and day-2 operations that every provider's storage must support.

**File:** [`tests/storage/datavolume.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go)

| # | Line | Test Name | Why Selected |
|---|------|-----------|---|
| 1 | [305](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L305) | "should successfully start multiple concurrent VMIs" | Validates concurrent volume provisioning -- common when scaling workloads. |
| 2 | [619](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L619) | "deleting VM should automatically delete DataVolumes and VMI owned by VM" | Cleanup correctness -- orphaned volumes waste storage. |
| 3 | [836](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L836) | "should resolve DataVolume sourceRef" | SourceRef is used for golden image workflows. |
| 4 | [1019](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/datavolume.go#L1019) | "fstrim from the VM influences disk.img" | Validates thin provisioning support. Without fstrim, disk images grow monotonically. |

---

### Category 2: Storage Migration - 1 test to add

**Why:** Only 1 migration test exists (block RWX). DV-to-DV migration is the most common migration scenario during storage upgrades and is not tested.

**File:** [`tests/storage/migration.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go)

| # | Line | Test Name | Why Selected |
|---|------|-----------|---|
| 5 | [374](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/migration.go#L374) | "should migrate the source volume from a source DV to a destination DV" | DV-to-DV migration, the most common pattern when both sides are managed by CDI. |

---

### Category 3: Storage Fundamentals - 6 tests to add

**Why:** Zero coverage. These tests validate the most basic storage primitives that all other operations depend on. If emptyDisk, ephemeral PVC, or block I/O don't work, higher-level tests (backup, snapshot, migration) will also fail with less clear error messages. Including fundamentals gives providers a clear signal when something is wrong at the base layer.

**File:** [`tests/storage/storage.go`](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go)

| # | Line | Test Name | Why Selected |
|---|------|-----------|---|
| 6 | [290](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L290) | "should create a writeable emptyDisk with the right capacity" | EmptyDisk is the simplest volume type. If this fails, the provider has a fundamental issue. |
| 7 | [327](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L327) | "should create a writeable emptyDisk with the specified serial number" | Serial numbers are used by guest OS for device identification. |
| 8 | [393](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L393) | "started with Ephemeral PVC" | Ephemeral PVCs are used for stateless workloads. Validates copy-on-write. |
| 9 | [578](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L578) | "should start with multiple hostdisks in the same directory" | Multiple hostdisks test concurrent volume mounts -- catches filesystem locking issues. |
| 10 | [1122](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L1122) | "should successfully start 2 VMs with a shareable disk" | Shared disks (RWX) are used for clustered applications. |
| 11 | [1132](https://github.com/kubevirt/kubevirt/blob/main/tests/storage/storage.go#L1132) | "should successfully write and read data" (block) | Raw block I/O is required for high-performance workloads. |

---

## Summary

| Metric | Before | After |
|--------|--------|-------|
| Tests in Self-Validation | 71 | 82 |
| Categories with 0 or minimal coverage | 3 | 0 |

### Proposed Tests by Category

| Category | Tests to Add | Current Tests | After |
|----------|-------------|---------------|-------|
| DataVolume Lifecycle | 4 | 1 | 5 |
| Storage Migration | 1 | 1 | 2 |
| Storage Fundamentals | 6 | 0 | 6 |
| **Total to add** | **11** | | |

---

## GA Requirements Mapping

| GA Requirement | Covered By | Gaps Remaining |
|---|---|---|
| Spin up VM (Linux) | Existing compute conformance tests | - |
| Spin up VM (Windows) | Not in scope | Windows tests need separate discussion |
| VM from Upload / Import / Registry | #70 (ImageUpload) | Partially covered; HTTP/registry import not tested |
| VM from Golden Images | #3 (sourceRef), clone RBAC tests | Partial |
| Volume Expansion | Not in scope | Requires storage driver support for online expansion notification |
| Snapshot & Restore | #59-65 (snapshot), #39-49 (restore) -- already 18 tests | Covered |
| Backup & Restore (OADP) | Not in scope | Backup tests require CBT feature gate; deferred |
| Storage Live Migration | #69 (existing) + proposed #5 | Partially covered; cross-mode migration deferred |
| Hotplug Volumes | 27 tests already running | Covered |
| 20 VMs x 4 disks simultaneously | Not in scope | Requires custom scale tests |
| 4 VMs snapshot/restore concurrently | Not in scope | Requires custom concurrency tests |
| Snapshot SLA (10s) / Restore SLA (5min) | Not in scope | Requires custom timing assertions |
| Multiple storage classes | Not in scope | Requires multiple job runs per provider |

---

## What We're NOT Adding

| Category | Reason |
|----------|--------|
| CBT (Changed Block Tracking) | Requires cluster-level feature gate not universally available. |
| Backup tests | Depend on CBT being enabled; fail without it. |
| PVC expansion tests | Block volume expansion notification doesn't propagate to guest on all storage drivers. |
| Block-to-filesystem migration | Cross-mode migration not supported on all storage classes. |
| Negative tests ("should fail...", "should reject...") | Per the guiding principle: we validate that infrastructure works, not that it correctly rejects bad input. |
| Quarantined tests | Tests in quarantine have known instability. |
| Redundant tests | Each test validates a distinct operation. No duplicates. |
| More hotplug / export / restore tests | Already well covered (27, 11, 11 tests respectively). |
| Scale / SLA tests | Require custom test code. Belong in a separate proposal. |

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
| **Windows VM** | Is Windows storage testing required for self-validation? |
| **Scale limits** | 20 VMs x 4 disks, concurrent snapshot/restore, timing SLAs -- requires custom tests. |
| **Cloning tests** | Clone operations (smart clone, host-assisted clone) are not in this proposal. |
| **VM source types** | HTTP import, registry import are common provisioning methods not covered. |

---

## References

- [Self-Validation Coverage](https://github.com/Ahmad-Hafe/ocp-virt-validation-checkup/blob/main/docs/STORAGE_TEST_COVERAGE.md)
- [Storage Checkup Coverage](https://github.com/Ahmad-Hafe/kubevirt-storage-checkup/blob/main/docs/STORAGE_CHECKUP_COVERAGE.md)
- [GA Criteria Document](https://docs.google.com/document/d/1XzBQtMQLMS3yidhqFhQDh1UYXB3yimIKUQtggJWABfM/edit?tab=t.0)
- [Gap Analysis Jira](https://redhat.atlassian.net/browse/CNV-84224)
