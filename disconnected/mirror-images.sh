#!/bin/bash

set -e

SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

KUBEVIRT_RELEASE=""
MIRROR_REGISTRY=""
USE_INTERNAL_REGISTRY=false
APPLY_MIRROR_SET=false
PULL_SECRET="${PULL_SECRET:-}"
TLS_VERIFY=true

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

TIER2_IMAGES=(
  "quay.io/openshift-cnv/qe-cnv-tests-fedora:41"
  "quay.io/openshift-cnv/qe-net-utils:latest"
)

OTHER_IMAGES=(
  "registry.redhat.io/rhel9/nginx-124:latest"
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Mirror all required images for the OCP Virt Validation Checkup to a
disconnected registry.

Options:
  --registry REGISTRY          Target mirror registry (e.g. my-registry.example.com:5000)
  --use-internal-registry      Use the OpenShift internal image registry as mirror target.
                               Exposes the registry route, creates the namespace, and
                               authenticates from the current workstation.
  --kubevirt-release TAG       KubeVirt release tag (e.g. v1.8.1). Auto-detected if omitted.
  --pull-secret FILE           Path to pull secret for registry authentication
  --insecure                   Skip TLS verification for the mirror registry
  --apply-mirror-set           Generate and apply ITMS + IDMS after mirroring
  -h, --help                   Show this help message

Examples:
  # Mirror to external registry, auto-detect KubeVirt version
  $(basename "$0") --registry my-registry.example.com:5000

  # Mirror to the OpenShift internal registry
  $(basename "$0") --use-internal-registry

  # Mirror with specific version and apply mirror sets
  $(basename "$0") --registry my-registry.example.com:5000 --kubevirt-release v1.8.1 --apply-mirror-set
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)       MIRROR_REGISTRY="$2"; shift 2 ;;
    --use-internal-registry) USE_INTERNAL_REGISTRY=true; shift ;;
    --kubevirt-release)      KUBEVIRT_RELEASE="$2"; shift 2 ;;
    --pull-secret)    PULL_SECRET="$2"; shift 2 ;;
    --insecure)       TLS_VERIFY=false; shift ;;
    --apply-mirror-set)      APPLY_MIRROR_SET=true; shift ;;
    -h|--help)        usage ;;
    *)                echo "Unknown option: $1"; usage ;;
  esac
done

detect_kubevirt_release() {
  echo "Auto-detecting KubeVirt release tag from cluster..."

  local virt_operator_image
  virt_operator_image=$(oc get deployment virt-operator -n openshift-cnv \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || true

  if [ -z "${virt_operator_image}" ]; then
    echo "Error: Could not find virt-operator deployment. Is OpenShift Virtualization installed?"
    exit 1
  fi

  local pull_secret_arg=""
  if [ -n "${PULL_SECRET}" ]; then
    pull_secret_arg="-a ${PULL_SECRET}"
  else
    local tmp_secret
    tmp_secret=$(mktemp)
    oc get secret/pull-secret -n openshift-config \
      -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${tmp_secret}"
    pull_secret_arg="-a ${tmp_secret}"
  fi

  local insecure_flag=""
  if [ "${TLS_VERIFY}" = false ]; then
    insecure_flag="--insecure=true"
  fi

  local kubevirt_tag=""
  kubevirt_tag=$(oc image info ${pull_secret_arg} ${insecure_flag} "${virt_operator_image}" \
    -o json --filter-by-os=linux/amd64 2>/dev/null | \
    jq -r '.config.config.Labels["upstream-version"] // empty') || true

  if [ -z "${kubevirt_tag}" ]; then
    kubevirt_tag=$(oc image info ${pull_secret_arg} ${insecure_flag} "brew.${virt_operator_image}" \
      -o json --filter-by-os=linux/amd64 2>/dev/null | \
      jq -r '.config.config.Labels["upstream-version"] // empty') || true
  fi

  if [ -z "${kubevirt_tag}" ]; then
    local csv_version
    csv_version=$(oc get csv -n openshift-cnv -o json | \
      jq -r '.items[] | select(.metadata.name | startswith("kubevirt-hyperconverged")).spec.version') || true
    if [ -n "${csv_version}" ]; then
      local konflux_version="v$(echo "${csv_version}" | cut -d. -f1)-$(echo "${csv_version}" | cut -d. -f2)"
      local image_name_with_digest
      image_name_with_digest=$(echo "${virt_operator_image}" | sed 's|.*/||')
      local konflux_image="quay.io/openshift-virtualization/konflux-builds/${konflux_version}/${image_name_with_digest}"
      kubevirt_tag=$(oc image info ${pull_secret_arg} "${konflux_image}" \
        -o json --filter-by-os=linux/amd64 2>/dev/null | \
        jq -r '.config.config.Labels["upstream-version"] // empty') || true
    fi
  fi

  if [ -z "${kubevirt_tag}" ]; then
    KUBEVIRT_RELEASE="v1.8.2"
    echo "WARNING: Could not auto-detect KubeVirt release tag. Using default: ${KUBEVIRT_RELEASE}"
    echo "         Override with --kubevirt-release if needed."
    return
  fi

  KUBEVIRT_RELEASE="v${kubevirt_tag%%-[0-9]*}"
  echo "Detected KubeVirt release: ${KUBEVIRT_RELEASE}"
}

setup_internal_registry() {
  echo "=== Setting up OpenShift internal registry ==="

  local registry_config
  registry_config=$(oc get configs.imageregistry.operator.openshift.io/cluster \
    -o jsonpath='{.spec.defaultRoute}' 2>/dev/null) || true

  if [ "${registry_config}" != "true" ]; then
    echo "Exposing internal registry with default route..."
    oc patch configs.imageregistry.operator.openshift.io/cluster \
      --type=merge --patch '{"spec":{"defaultRoute":true}}'
    echo "Waiting for route to be available..."
    sleep 10
  fi

  MIRROR_REGISTRY=$(oc get route default-route -n openshift-image-registry \
    -o jsonpath='{.spec.host}')
  echo "Internal registry route: ${MIRROR_REGISTRY}"

  if ! oc get project kubevirt-mirror &>/dev/null; then
    echo "Creating kubevirt-mirror namespace..."
    oc new-project kubevirt-mirror
  fi

  echo "Configuring RBAC permissions..."
  oc policy add-role-to-group system:image-puller system:authenticated -n kubevirt-mirror 2>/dev/null || true
  oc policy add-role-to-group system:image-puller system:unauthenticated -n kubevirt-mirror 2>/dev/null || true

  echo "Authenticating to internal registry..."
  local login_user
  local login_token
  login_user=$(oc whoami 2>/dev/null) || true

  if [ "${login_user}" = "system:admin" ]; then
    echo "  system:admin uses certificates, creating a service account for push access..."
    oc create sa registry-pusher -n kubevirt-mirror 2>/dev/null || true
    oc adm policy add-role-to-user system:image-builder -n kubevirt-mirror -z registry-pusher 2>/dev/null || true
    login_token=$(oc create token registry-pusher -n kubevirt-mirror --duration=1h)
    login_user="unused"
  else
    login_token=$(oc whoami -t)
  fi

  echo "${login_token}" | podman login -u "${login_user}" --password-stdin "${MIRROR_REGISTRY}" \
    --tls-verify=false

  TLS_VERIFY=false
}

get_mirror_flags() {
  local flags=""
  if [ "${USE_INTERNAL_REGISTRY}" = true ]; then
    flags+="--filter-by-os=linux/amd64 "
  else
    flags+="--keep-manifest-list=true "
  fi
  if [ "${TLS_VERIFY}" = false ]; then
    flags+="--insecure=true "
  fi
  if [ -n "${PULL_SECRET}" ]; then
    flags+="-a ${PULL_SECRET} "
  fi
  echo "${flags}"
}

mirror_kubevirt_images() {
  echo ""
  echo "=== Mirroring KubeVirt test images (tag: ${KUBEVIRT_RELEASE}) ==="

  local target_prefix
  if [ "${USE_INTERNAL_REGISTRY}" = true ]; then
    target_prefix="${MIRROR_REGISTRY}/kubevirt-mirror"
  else
    target_prefix="${MIRROR_REGISTRY}/kubevirt"
  fi

  local flags
  flags=$(get_mirror_flags)

  local failed=()
  for img in "${KUBEVIRT_IMAGES[@]}"; do
    local source="quay.io/kubevirt/${img}:${KUBEVIRT_RELEASE}"
    local target="${target_prefix}/${img}:${KUBEVIRT_RELEASE}"
    echo ""
    echo "  ${source}"
    echo "  -> ${target}"

    if oc image mirror ${flags} \
      "${source}" "${target}" 2>&1; then
      echo "  OK"
    else
      echo "  FAILED"
      failed+=("${img}")
    fi
  done

  if [ ${#failed[@]} -gt 0 ]; then
    echo ""
    echo "WARNING: Failed to mirror ${#failed[@]} image(s): ${failed[*]}"
  fi
}

mirror_tier2_images() {
  echo ""
  echo "=== Mirroring tier2 test images ==="

  local target_prefix
  if [ "${USE_INTERNAL_REGISTRY}" = true ]; then
    target_prefix="${MIRROR_REGISTRY}/kubevirt-mirror"
  else
    target_prefix="${MIRROR_REGISTRY}/openshift-cnv"
  fi

  local flags
  flags=$(get_mirror_flags)

  local failed=()
  for full_image in "${TIER2_IMAGES[@]}"; do
    local image_name_tag
    image_name_tag=$(echo "${full_image}" | sed 's|.*/||')

    local target="${target_prefix}/${image_name_tag}"
    echo ""
    echo "  ${full_image}"
    echo "  -> ${target}"

    if oc image mirror ${flags} \
      "${full_image}" "${target}" 2>&1; then
      echo "  OK"
    else
      echo "  FAILED"
      failed+=("${image_name_tag}")
    fi
  done

  if [ ${#failed[@]} -gt 0 ]; then
    echo ""
    echo "WARNING: Failed to mirror ${#failed[@]} tier2 image(s): ${failed[*]}"
  fi
}

mirror_other_images() {
  echo ""
  echo "=== Mirroring additional images ==="

  local target_prefix
  if [ "${USE_INTERNAL_REGISTRY}" = true ]; then
    target_prefix="${MIRROR_REGISTRY}/kubevirt-mirror"
  else
    target_prefix="${MIRROR_REGISTRY}"
  fi

  local flags
  flags=$(get_mirror_flags)

  for full_image in "${OTHER_IMAGES[@]}"; do
    local image_name
    image_name=$(echo "${full_image}" | sed 's|.*/||')

    local target="${target_prefix}/${image_name}"
    echo ""
    echo "  ${full_image}"
    echo "  -> ${target}"

    if oc image mirror ${flags} \
      "${full_image}" "${target}" 2>&1; then
      echo "  OK"
    else
      echo "  FAILED (image may require authentication - check pull secret)"
    fi
  done
}

generate_mirror_set() {
  local mirror_set_file
  mirror_set_file=$(mktemp --suffix=.yaml)

  local target_prefix
  if [ "${USE_INTERNAL_REGISTRY}" = true ]; then
    target_prefix="image-registry.openshift-image-registry.svc:5000/kubevirt-mirror"
  else
    target_prefix="${MIRROR_REGISTRY}/kubevirt"
  fi

  local tier2_prefix
  if [ "${USE_INTERNAL_REGISTRY}" = true ]; then
    tier2_prefix="image-registry.openshift-image-registry.svc:5000/kubevirt-mirror"
  else
    tier2_prefix="${MIRROR_REGISTRY}/openshift-cnv"
  fi

  local other_prefix
  if [ "${USE_INTERNAL_REGISTRY}" = true ]; then
    other_prefix="image-registry.openshift-image-registry.svc:5000/kubevirt-mirror"
  else
    other_prefix="${MIRROR_REGISTRY}"
  fi

  cat > "${mirror_set_file}" <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: ocp-virt-validation-mirrors
spec:
  imageTagMirrors:
    - source: quay.io/kubevirt
      mirrors:
        - ${target_prefix}
    - source: quay.io/openshift-cnv
      mirrors:
        - ${tier2_prefix}
    - source: registry.redhat.io/rhel9
      mirrors:
        - ${other_prefix}
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ocp-virt-validation-digest-mirrors
spec:
  imageDigestMirrors:
    - source: quay.io/kubevirt
      mirrors:
        - ${target_prefix}
    - source: quay.io/openshift-cnv
      mirrors:
        - ${tier2_prefix}
    - source: registry.redhat.io/rhel9
      mirrors:
        - ${other_prefix}
EOF

  echo ""
  echo "=== Generated Mirror Sets (ITMS + IDMS) ==="
  cat "${mirror_set_file}"

  if [ "${APPLY_MIRROR_SET}" = true ]; then
    echo ""
    echo "Applying mirror sets..."
    oc apply -f "${mirror_set_file}"
    echo ""
    echo "Waiting for MachineConfigPools to update (this may take several minutes)..."
    oc wait machineconfigpool --all --for=condition=Updated --timeout=30m
    echo "MachineConfigPools updated."
  else
    echo ""
    echo "To apply these mirror sets, run:"
    echo "  oc apply -f ${mirror_set_file}"
    echo "  oc wait machineconfigpool --all --for=condition=Updated --timeout=30m"
  fi
}

# --- Main ---

if [ "${USE_INTERNAL_REGISTRY}" = false ] && [ -z "${MIRROR_REGISTRY}" ]; then
  echo "Error: Either --registry or --use-internal-registry is required."
  echo ""
  usage
fi

if [ -z "${KUBEVIRT_RELEASE}" ]; then
  detect_kubevirt_release
else
  echo "Using provided KubeVirt release: ${KUBEVIRT_RELEASE}"
fi

if [ "${USE_INTERNAL_REGISTRY}" = true ]; then
  setup_internal_registry
fi

mirror_kubevirt_images
mirror_tier2_images
mirror_other_images

generate_mirror_set

echo ""
echo "=== Mirroring complete ==="
echo ""
echo "Next steps:"
if [ "${APPLY_MIRROR_SET}" = false ]; then
  echo "  1. Apply the mirror sets (ITMS + IDMS) - see above"
  echo "  2. Wait for MachineConfigPools to update"
fi
echo "  - Run the validation checkup as usual (mirror sets handle image redirection transparently):"
echo "    podman run -e OCP_VIRT_VALIDATION_IMAGE=\${OCP_VIRT_VALIDATION_IMAGE} \\"
echo "      \${OCP_VIRT_VALIDATION_IMAGE} generate | oc apply -f -"
