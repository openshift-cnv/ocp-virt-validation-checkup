# Disconnected Environments

The validation checkup can be run on disconnected (air-gapped) OpenShift clusters by using a mirror registry. This document explains how to configure the checkup for disconnected environments.

## Prerequisites for Disconnected Environments
1. A mirror registry accessible from the cluster (either an external registry or the OpenShift internal registry).
2. All required test images mirrored to the registry (see [Mirroring Required Images](#mirroring-required-images)).
3. Both an `ImageTagMirrorSet` (ITMS) and an `ImageDigestMirrorSet` (IDMS) configured to redirect image pulls from upstream registries to the mirror (see [Mirror Set Configuration](#mirror-set-configuration)).

## How It Works
The validation checkup references upstream image paths (e.g. `quay.io/kubevirt/...`). In disconnected environments, mirror sets transparently redirect these pulls to the mirror registry at the CRI-O level on each node. No changes to the checkup configuration or environment variables are needed.

Two types of mirror sets are required because test images are referenced in two different ways:
- **ITMS** (ImageTagMirrorSet): intercepts tag-based image references (e.g. `quay.io/kubevirt/alpine-container-disk-demo:v1.8.1`) used by the KubeVirt test suites (compute, network, storage).
- **IDMS** (ImageDigestMirrorSet): intercepts digest-based image references (e.g. `quay.io/openshift-cnv/qe-net-utils@sha256:...`) used by the tier2 test suite.



## Certificate Configuration
If using an external mirror registry, the cluster must trust its TLS certificate.

### Option 1: Add the Registry Certificate to the Cluster (Recommended)

1. Create a ConfigMap containing the registry's CA certificate:
```bash
$ oc create configmap registry-ca \
    --from-file=my-mirror-registry.example.com..5000=/path/to/ca-certificate.crt \
    -n openshift-config
```

2. Update the cluster's image configuration to use the ConfigMap:
```bash
$ oc patch image.config.openshift.io/cluster --patch '{"spec":{"additionalTrustedCA":{"name":"registry-ca"}}}' --type=merge
```

### Option 2: Configure the Registry as Insecure
**Not recommended for production environments.**

```bash
$ oc patch image.config.openshift.io/cluster --type=merge --patch '
{
  "spec": {
    "registrySources": {
      "insecureRegistries": [
        "my-mirror-registry.example.com:5000"
      ]
    }
  }
}'
```

**Note:** After modifying the image configuration, the Machine Config Operator will roll out changes to all nodes. Wait for the rollout to complete:
```bash
$ oc wait machineconfigpool --all --for=condition=Updated --timeout=30m
```

## Mirroring Required Images

The validation checkup uses several container images from public registries. In disconnected environments, all of these must be mirrored to an accessible registry.

All mirroring should be performed from a bastion host (workstation) that has access to both the internet (to pull upstream images) and the disconnected cluster (to push images to the mirror registry).

**Important:** When mirroring multi-architecture images (such as `qe-net-utils`), always use `--keep-manifest-list=true` with `oc image mirror`. Some test frameworks reference images by their manifest list digest rather than by tag. If only single-architecture manifests are pushed, digest-based pulls will fail with "manifest unknown".

### KubeVirt Test Images (from `quay.io/kubevirt`)

The KubeVirt test suites (compute, network, storage) use container disk images and utility containers from `quay.io/kubevirt`. The exact tag corresponds to the upstream KubeVirt version bundled with your OpenShift Virtualization release (e.g. `v1.8.1` for CNV 4.22).

To determine the correct tag, extract the upstream version label from the `virt-operator` image:
```bash
$ VIRT_OPERATOR_IMAGE=$(oc get deployment virt-operator -n openshift-cnv -o jsonpath='{.spec.template.spec.containers[0].image}')
$ KUBEVIRT_TAG=$(oc image info -a ~/pull-secret.json ${VIRT_OPERATOR_IMAGE} -o json --filter-by-os=linux/amd64 | jq -r '.config.config.Labels["upstream-version"]')
$ KUBEVIRT_RELEASE="v${KUBEVIRT_TAG%%-[0-9]*}"
$ echo "KubeVirt release tag: ${KUBEVIRT_RELEASE}"
```

The `mirror-images.sh` helper script (see [Automated Mirroring Script](#automated-mirroring-script)) auto-detects this tag from the cluster. In disconnected environments where `oc image info` cannot reach the upstream registry, the script defaults to `v1.8.2`. Override with `--kubevirt-release` if your CNV version uses a different upstream KubeVirt release.

The following images must be mirrored with the `${KUBEVIRT_RELEASE}` tag:

| Image | Used by |
|-------|---------|
| `quay.io/kubevirt/cirros-container-disk-demo:${KUBEVIRT_RELEASE}` | Compute, Network, Storage tests - lightweight VM container disk |
| `quay.io/kubevirt/alpine-container-disk-demo:${KUBEVIRT_RELEASE}` | Compute, Network tests - Alpine VM container disk |
| `quay.io/kubevirt/fedora-with-test-tooling-container-disk:${KUBEVIRT_RELEASE}` | Storage, Network tests - Fedora VM with test tools |
| `quay.io/kubevirt/alpine-with-test-tooling-container-disk:${KUBEVIRT_RELEASE}` | Storage tests - Alpine VM with test tools |
| `quay.io/kubevirt/alpine-ext-kernel-boot-demo:${KUBEVIRT_RELEASE}` | Compute tests - kernel boot testing |
| `quay.io/kubevirt/virtio-container-disk:${KUBEVIRT_RELEASE}` | Storage tests - VirtIO driver disk |
| `quay.io/kubevirt/disks-images-provider:${KUBEVIRT_RELEASE}` | Storage tests - DaemonSet that pre-provisions disk images on nodes |
| `quay.io/kubevirt/vm-killer:${KUBEVIRT_RELEASE}` | Storage export tests - download/utility pod |

### Tier2 Test Images (from `quay.io/openshift-cnv`)

The tier2 conformance tests (`openshift-virtualization-tests`) use the following images from `quay.io/openshift-cnv`:

| Image | Used by |
|-------|---------|
| `quay.io/openshift-cnv/qe-cnv-tests-fedora:41` | Fedora VM container disk - used by most conformance tests that start a VM |
| `quay.io/openshift-cnv/qe-net-utils:latest` | Network utility DaemonSet - used by network-related conformance tests. **Must be mirrored with `--keep-manifest-list=true`** because the test framework references it by digest. |

For multi-architecture clusters, the following arch-specific Fedora images are also needed:

| Image | Architecture |
|-------|-------------|
| `quay.io/openshift-cnv/qe-cnv-tests-fedora:41-arm64` | ARM64 / aarch64 |
| `quay.io/openshift-cnv/qe-cnv-tests-fedora:41-s390x` | s390x |

### Other Required Images

| Image | Used by |
|-------|---------|
| `registry.redhat.io/rhel9/nginx-124:latest` | Results viewer - nginx server for browsing test artifacts |

### Mirroring Commands

Mirror all required images to your registry. Use `oc image mirror` with `--keep-manifest-list=true` to preserve multi-architecture manifest lists:

```bash
MIRROR_REGISTRY="my-mirror-registry.example.com:5000"

# Determine the KubeVirt release tag (see above)
# KUBEVIRT_RELEASE=v1.8.1

# --- KubeVirt test images ---
KUBEVIRT_IMAGES=(
  "cirros-container-disk-demo"
  "alpine-container-disk-demo"
  "fedora-with-test-tooling-container-disk"
  "alpine-with-test-tooling-container-disk"
  "alpine-ext-kernel-boot-demo"
  "virtio-container-disk"
  "disks-images-provider"
  "vm-killer"
)

for img in "${KUBEVIRT_IMAGES[@]}"; do
  echo "Mirroring quay.io/kubevirt/${img}:${KUBEVIRT_RELEASE} ..."
  oc image mirror --keep-manifest-list=true \
    "quay.io/kubevirt/${img}:${KUBEVIRT_RELEASE}" \
    "${MIRROR_REGISTRY}/kubevirt/${img}:${KUBEVIRT_RELEASE}"
done

# --- Tier2 test images ---
oc image mirror --keep-manifest-list=true \
  "quay.io/openshift-cnv/qe-cnv-tests-fedora:41" \
  "${MIRROR_REGISTRY}/openshift-cnv/qe-cnv-tests-fedora:41"

oc image mirror --keep-manifest-list=true \
  "quay.io/openshift-cnv/qe-net-utils:latest" \
  "${MIRROR_REGISTRY}/openshift-cnv/qe-net-utils:latest"

# --- Results viewer ---
oc image mirror --keep-manifest-list=true \
  "registry.redhat.io/rhel9/nginx-124:latest" \
  "${MIRROR_REGISTRY}/rhel9/nginx-124:latest"
```

A helper script is provided at [`mirror-images.sh`](mirror-images.sh) that automates the mirroring process. See [Automated Mirroring Script](#automated-mirroring-script) below.

## Mirror Set Configuration

After mirroring the images, configure both an `ImageTagMirrorSet` (ITMS) and an `ImageDigestMirrorSet` (IDMS) so that the cluster redirects all image pulls to your mirror. Both are required:
- **ITMS** handles tag-based references (used by KubeVirt test suites)
- **IDMS** handles digest-based references (used by tier2 test suite)

Create a file named `image-mirror-sets.yaml`:
```yaml
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: ocp-virt-validation-mirrors
spec:
  imageTagMirrors:
    - source: quay.io/kubevirt
      mirrors:
        - my-mirror-registry.example.com:5000/kubevirt
    - source: quay.io/openshift-cnv
      mirrors:
        - my-mirror-registry.example.com:5000/openshift-cnv
    - source: registry.redhat.io/rhel9
      mirrors:
        - my-mirror-registry.example.com:5000/rhel9
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ocp-virt-validation-digest-mirrors
spec:
  imageDigestMirrors:
    - source: quay.io/kubevirt
      mirrors:
        - my-mirror-registry.example.com:5000/kubevirt
    - source: quay.io/openshift-cnv
      mirrors:
        - my-mirror-registry.example.com:5000/openshift-cnv
    - source: registry.redhat.io/rhel9
      mirrors:
        - my-mirror-registry.example.com:5000/rhel9
```

Apply it:
```bash
$ oc apply -f image-mirror-sets.yaml
```

**Note:** After applying the mirror sets, the Machine Config Operator will roll out changes to all nodes. Wait for the rollout to complete:
```bash
$ oc wait machineconfigpool --all --for=condition=Updated --timeout=30m
```

## Using the OpenShift Internal Registry

If you do not have an external mirror registry, you can use the OpenShift cluster's built-in image registry as the mirror target. The mirroring is performed from a bastion host (workstation) that has access to both the internet (to pull images) and the cluster (to push images).

### Step 1: Expose the Internal Registry

```bash
$ oc patch configs.imageregistry.operator.openshift.io/cluster \
    --type=merge --patch '{"spec":{"defaultRoute":true}}'
```

Get the registry hostname:
```bash
$ INTERNAL_REGISTRY=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
$ echo "Internal registry: ${INTERNAL_REGISTRY}"
```

### Step 2: Create the Mirror Namespace and Set Permissions

```bash
$ oc new-project kubevirt-mirror

# Allow all cluster nodes to pull images from this namespace
$ oc policy add-role-to-group system:image-puller system:authenticated -n kubevirt-mirror
$ oc policy add-role-to-group system:image-puller system:unauthenticated -n kubevirt-mirror
```

### Step 3: Log in to the Internal Registry

```bash
$ oc whoami -t | podman login -u $(oc whoami) --password-stdin ${INTERNAL_REGISTRY} --tls-verify=false
```

**Note:** If `oc whoami` returns `system:admin` (certificate-based auth with no token), create a service account for pushing:
```bash
$ oc create sa registry-pusher -n kubevirt-mirror
$ oc adm policy add-role-to-user system:image-builder -n kubevirt-mirror -z registry-pusher
$ SA_TOKEN=$(oc create token registry-pusher -n kubevirt-mirror --duration=1h)
$ echo "${SA_TOKEN}" | podman login -u unused --password-stdin ${INTERNAL_REGISTRY} --tls-verify=false
```

### Step 4: Mirror Images

Use `oc image mirror` with `--keep-manifest-list=true` to preserve multi-architecture manifest lists. This is critical because some test images (e.g. `qe-net-utils`) are referenced by their manifest list digest:

```bash
# KUBEVIRT_RELEASE=v1.8.1  # Determine the correct tag (see above)

IMAGES=(
  "quay.io/kubevirt/cirros-container-disk-demo:${KUBEVIRT_RELEASE}"
  "quay.io/kubevirt/alpine-container-disk-demo:${KUBEVIRT_RELEASE}"
  "quay.io/kubevirt/fedora-with-test-tooling-container-disk:${KUBEVIRT_RELEASE}"
  "quay.io/kubevirt/alpine-with-test-tooling-container-disk:${KUBEVIRT_RELEASE}"
  "quay.io/kubevirt/alpine-ext-kernel-boot-demo:${KUBEVIRT_RELEASE}"
  "quay.io/kubevirt/virtio-container-disk:${KUBEVIRT_RELEASE}"
  "quay.io/kubevirt/disks-images-provider:${KUBEVIRT_RELEASE}"
  "quay.io/kubevirt/vm-killer:${KUBEVIRT_RELEASE}"
  "quay.io/openshift-cnv/qe-cnv-tests-fedora:41"
  "quay.io/openshift-cnv/qe-net-utils:latest"
  "registry.redhat.io/rhel9/nginx-124:latest"
)

for img in "${IMAGES[@]}"; do
  img_name=$(echo "${img}" | sed 's|.*/||')
  echo "Mirroring ${img} -> ${INTERNAL_REGISTRY}/kubevirt-mirror/${img_name}"
  oc image mirror --keep-manifest-list=true --insecure=true \
    "${img}" "${INTERNAL_REGISTRY}/kubevirt-mirror/${img_name}"
done
```

### Step 5: Configure Mirror Sets for the Internal Registry

The internal registry's in-cluster service name is `image-registry.openshift-image-registry.svc:5000`. Create both ITMS and IDMS:

```yaml
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: ocp-virt-validation-mirrors
spec:
  imageTagMirrors:
    - source: quay.io/kubevirt
      mirrors:
        - image-registry.openshift-image-registry.svc:5000/kubevirt-mirror
    - source: quay.io/openshift-cnv
      mirrors:
        - image-registry.openshift-image-registry.svc:5000/kubevirt-mirror
    - source: registry.redhat.io/rhel9
      mirrors:
        - image-registry.openshift-image-registry.svc:5000/kubevirt-mirror
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ocp-virt-validation-digest-mirrors
spec:
  imageDigestMirrors:
    - source: quay.io/kubevirt
      mirrors:
        - image-registry.openshift-image-registry.svc:5000/kubevirt-mirror
    - source: quay.io/openshift-cnv
      mirrors:
        - image-registry.openshift-image-registry.svc:5000/kubevirt-mirror
    - source: registry.redhat.io/rhel9
      mirrors:
        - image-registry.openshift-image-registry.svc:5000/kubevirt-mirror
```

```bash
$ oc apply -f image-mirror-sets.yaml
$ oc wait machineconfigpool --all --for=condition=Updated --timeout=30m
```

## Automated Mirroring Script

A helper script at [`mirror-images.sh`](mirror-images.sh) automates the entire mirroring process. It supports both external mirror registries and the OpenShift internal registry, and handles authentication, manifest list preservation, and mirror set generation. Run it from a bastion host with access to both the internet and the cluster.

Usage:
```bash
# Mirror to an external registry
$ ./disconnected/mirror-images.sh --registry my-mirror-registry.example.com:5000

# Mirror to the OpenShift internal registry
$ ./disconnected/mirror-images.sh --use-internal-registry

# Specify a custom KubeVirt release tag
$ ./disconnected/mirror-images.sh --registry my-mirror-registry.example.com:5000 --kubevirt-release v1.8.1

# Also generate and apply ITMS + IDMS
$ ./disconnected/mirror-images.sh --registry my-mirror-registry.example.com:5000 --apply-mirror-set
```

The script will:
1. Auto-detect the KubeVirt release tag from the cluster (if not provided)
2. Mirror all required images with `--keep-manifest-list=true` to preserve multi-arch manifest lists
3. When using `--use-internal-registry`, expose the internal registry route, create the mirror namespace, configure RBAC, and authenticate
4. Optionally generate and apply both `ImageTagMirrorSet` and `ImageDigestMirrorSet`
