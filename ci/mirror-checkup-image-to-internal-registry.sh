#!/bin/bash

# Mirror the validation checkup image to the OpenShift internal registry.
#
# The checkup image (OCP_VIRT_VALIDATION_IMAGE) is typically referenced by
# digest from the CSV's relatedImages. Two problems prevent a straightforward
# mirror to the internal registry:
#
# 1. The internal registry cannot serve multi-arch manifest lists. This script
#    mirrors the image as single-arch (linux/amd64) so pods can pull it.
#
# 2. The workstation does not use the cluster's IDMS. For pre-GA images where
#    the digest only exists in a mirror (e.g. Konflux builds), this script
#    queries the cluster's ImageDigestMirrorSets and tries each mirror in order.
#
# Usage: mirror-checkup-image-to-internal-registry.sh <source-image> <internal-registry-route>
# Output: prints the internal registry reference (by digest) to stdout

set -euo pipefail

SOURCE_IMAGE="$1"
INTERNAL_REGISTRY="$2"

IMAGE_BASE=$(echo "${SOURCE_IMAGE}" | sed 's|.*/||' | sed 's|[@:].*||')
IMAGE_DIGEST=$(echo "${SOURCE_IMAGE}" | grep -o '@sha256:[a-f0-9]*' || true)
IMAGE_SOURCE_REPO=$(echo "${SOURCE_IMAGE}" | sed 's|[@:].*||')
MIRROR_TIMEOUT="${MIRROR_TIMEOUT:-300}"

if [ -n "${IMAGE_DIGEST}" ]; then
  INTERNAL_IMAGE="${INTERNAL_REGISTRY}/kubevirt-mirror/${IMAGE_BASE}:disconnected"
else
  IMAGE_TAG=$(echo "${SOURCE_IMAGE}" | sed 's|.*:||')
  INTERNAL_IMAGE="${INTERNAL_REGISTRY}/kubevirt-mirror/${IMAGE_BASE}:${IMAGE_TAG}"
fi

MIRRORED=false
if [ -n "${IMAGE_DIGEST}" ]; then
  MIRROR_SOURCES=$(oc get imagedigestmirrorset -o json 2>/dev/null | \
    jq -r --arg src "${IMAGE_SOURCE_REPO}" \
    '.items[].spec.imageDigestMirrors[] | select(.source == $src) | .mirrors[]') || true

  for mirror in ${MIRROR_SOURCES}; do
    MIRROR_IMAGE="${mirror}${IMAGE_DIGEST}"
    echo "> Trying mirror: ${MIRROR_IMAGE}" >&2
    if timeout "${MIRROR_TIMEOUT}" oc image mirror --filter-by-os=linux/amd64 --insecure=true "${MIRROR_IMAGE}" "${INTERNAL_IMAGE}" >&2; then
      echo "> Mirrored to: ${INTERNAL_IMAGE}" >&2
      MIRRORED=true
      break
    fi
  done
fi

if [ "${MIRRORED}" = false ]; then
  echo "> No IDMS mirror worked, trying original source" >&2
  timeout "${MIRROR_TIMEOUT}" oc image mirror --filter-by-os=linux/amd64 --insecure=true \
    "${SOURCE_IMAGE}" "${INTERNAL_IMAGE}" >&2
  echo "> Mirrored to: ${INTERNAL_IMAGE}" >&2
fi

IST_TAG="${IMAGE_BASE}:disconnected"
if [ -z "${IMAGE_DIGEST}" ]; then
  IST_TAG="${IMAGE_BASE}:${IMAGE_TAG}"
fi

INTERNAL_REF=$(oc get imagestreamtag "${IST_TAG}" -n kubevirt-mirror \
  -o jsonpath='{.image.dockerImageReference}' 2>/dev/null) || true

if [ -z "${INTERNAL_REF}" ]; then
  echo "Error: Could not resolve image from internal registry (imagestreamtag ${IST_TAG} in kubevirt-mirror)" >&2
  exit 1
fi

echo "${INTERNAL_REF}"
