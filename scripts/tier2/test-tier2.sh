#!/bin/bash

set -ex

cd /openshift-virtualization-tests
oc image extract ghcr.io/astral-sh/uv:latest --file /uv,/uvx
chmod +x uv uvx

./uv sync --locked
./uv export --no-hashes

export ARTIFACTS=${RESULTS_DIR}/tier2
mkdir -p "${ARTIFACTS}"


SUBSCRIPTION_NAME=$(oc get subs -n openshift-cnv -l operators.coreos.com/kubevirt-hyperconverged.openshift-cnv= -o json | jq -r '.items[0].metadata.name')

DEFAULT_STORAGE_CLASS=$(oc get sc -o json | jq -r '[.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class"=="true")][0]'.metadata.name)
if [ -z "${STORAGE_CLASS}" ]; then
  STORAGE_CLASS=${DEFAULT_STORAGE_CLASS}
fi


./uv run pytest \
  -m "conformance and single_nic" \
  --skip-artifactory-check \
  --tc=hco_subscription:${SUBSCRIPTION_NAME} \
  --storage-class-matrix=${STORAGE_CLASS} \
  --default-storage-class=${DEFAULT_STORAGE_CLASS} \
  -s -o log_cli=true \
  --junitxml="${ARTIFACTS}/junit.results.xml" | tee ${ARTIFACTS}/tier2-log.txt
