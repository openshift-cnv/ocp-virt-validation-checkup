#!/bin/bash

# This script generates the manifests required to run the ocp-virt validation checkup


if [ -z "${OCP_VIRT_VALIDATION_IMAGE}" ]
then
  echo "Error: Please provide OCP_VIRT_VALIDATION_IMAGE environment variable. Get it by running:"
  echo 'CSV_NAME=$(oc get csv -n openshift-cnv -o json | jq -r '\''.items[] | select(.metadata.name | startswith("kubevirt-hyperconverged")).metadata.name'\'')'
  echo 'oc get csv -n openshift-cnv $CSV_NAME -o json | jq -r '\''.spec.relatedImages[] | select(.name | contains("ocp-virt-validation-checkup")).image'\'
  exit 1
fi

DRY_RUN=${DRY_RUN:-"false"}
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")

TEST_SUITES=${TEST_SUITES:-"compute,network,storage,ssp"}
STORAGE_CLASS=${STORAGE_CLASS:-""}

ALLOWED_TEST_SUITES="compute|network|storage|ssp"
if [[ ! "$TEST_SUITES" =~ ^($ALLOWED_TEST_SUITES)(,($ALLOWED_TEST_SUITES))*$ ]]; then
  echo "Invalid TEST_SUITES format: \"$TEST_SUITES\""
  echo "Allowed values: comma-separated list of [$ALLOWED_TEST_SUITES]"
  exit 1
fi


TEST_SKIPS=${TEST_SKIPS:-""}

VALID_SKIP_REGEX='^([a-zA-Z0-9_:|-]+)(\|([a-zA-Z0-9_:|-]+))*$'
if [[ -n "${TEST_SKIPS}" && ! "${TEST_SKIPS}" =~ ${VALID_SKIP_REGEX} ]]; then
  echo "Invalid TEST_SKIPS format: \"${TEST_SKIPS}\""
  echo "Expected: pipe-separated list of test cases"
  exit 1
fi


# Namespace
cat <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: ocp-virt-validation
spec: {}
EOF

# Service Account
cat <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ocp-virt-validation-sa
  namespace: ocp-virt-validation
EOF

# RBAC
cat <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ocp-virt-validation-cluster-admin-binding
subjects:
  - kind: ServiceAccount
    name: ocp-virt-validation-sa
    namespace: ocp-virt-validation
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# PVC (to store the results)
cat <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ocp-virt-validation-pvc-${TIMESTAMP}
  namespace: ocp-virt-validation
  labels:
    app: ocp-virt-validation
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# Job
cat <<EOF
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ocp-virt-validation-job-${TIMESTAMP}
  namespace: ocp-virt-validation
spec:
  template:
    metadata:
      labels:
        app: ocp-virt-validation
    spec:
      serviceAccountName: ocp-virt-validation-sa
      securityContext:
        fsGroup: 1001
      containers:
        - name: ocp-virt-validation-checkup
          image: ${OCP_VIRT_VALIDATION_IMAGE}
          imagePullPolicy: Always
          env:
            - name: DRY_RUN
              value: ${DRY_RUN}
            - name: TIMESTAMP
              value: ${TIMESTAMP}
            - name: RESULTS_DIR
              value: /results
            - name: TEST_SUITES
              value: ${TEST_SUITES}
            - name: TEST_SKIPS
              value: ${TEST_SKIPS}
            - name: STORAGE_CLASS
              value: ${STORAGE_CLASS}
          volumeMounts:
            - name: results-volume
              mountPath: /results
      restartPolicy: Never
      volumes:
        - name: results-volume
          persistentVolumeClaim:
            claimName: ocp-virt-validation-pvc-${TIMESTAMP}
  backoffLimit: 0
EOF
