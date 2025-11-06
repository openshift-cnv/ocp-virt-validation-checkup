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

TEST_SUITES=${TEST_SUITES:-"compute,network,storage,ssp,tier2"}
FULL_SUITE=${FULL_SUITE:-"false"}
STORAGE_CLASS=${STORAGE_CLASS:-""}
STORAGE_CAPABILITIES=${STORAGE_CAPABILITIES:-""}

# Calculate storage size based on test suites (2Gi per suite, 10Gi for tier2)
IFS=',' read -ra TEST_SUITES_ARRAY <<< "${TEST_SUITES}"
TOTAL_STORAGE=0
for suite in "${TEST_SUITES_ARRAY[@]}"; do
  if [[ "$suite" == "tier2" ]]; then
    TOTAL_STORAGE=$((TOTAL_STORAGE + 10))
  else
    TOTAL_STORAGE=$((TOTAL_STORAGE + 2))
  fi
done
STORAGE_SIZE="${TOTAL_STORAGE}Gi"

ALLOWED_TEST_SUITES="compute|network|storage|ssp|tier2"
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

# Validate STORAGE_CAPABILITIES if provided
if [[ -n "${STORAGE_CAPABILITIES}" ]]; then
  valid_capabilities=("storageClassRhel" "storageClassWindows" "storageRWXBlock" "storageRWXFileSystem" "storageRWOFileSystem" "storageRWOBlock" "storageClassCSI" "storageSnapshot" "onlineResize" "WFFC")
  
  # Parse comma-separated capabilities
  IFS=',' read -ra capabilities_array <<< "${STORAGE_CAPABILITIES}"
  
  # Validate each capability
  for capability in "${capabilities_array[@]}"; do
    # Trim whitespace
    capability=$(echo "$capability" | xargs)
    
    # Skip empty entries
    if [[ -z "$capability" ]]; then
      echo "Error: Empty storage capability found in STORAGE_CAPABILITIES"
      echo "Valid capabilities are: ${valid_capabilities[*]}"
      exit 1
    fi
    
    # Check if capability is valid
    valid=false
    for valid_cap in "${valid_capabilities[@]}"; do
      if [[ "$capability" == "$valid_cap" ]]; then
        valid=true
        break
      fi
    done
    
    if [[ "$valid" == false ]]; then
      echo "Error: Invalid storage capability '${capability}' in STORAGE_CAPABILITIES"
      echo "Valid capabilities are: ${valid_capabilities[*]}"
      exit 1
    fi
  done
  
  # Ensure STORAGE_CLASS is provided when STORAGE_CAPABILITIES is used
  if [[ -z "${STORAGE_CLASS}" ]]; then
    echo "Error: STORAGE_CLASS must be set when using STORAGE_CAPABILITIES"
    exit 1
  fi
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
      storage: ${STORAGE_SIZE}
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
      terminationGracePeriodSeconds: 60
      securityContext:
        fsGroup: 1001
      containers:
        - name: ocp-virt-validation-checkup
          image: ${OCP_VIRT_VALIDATION_IMAGE}
          imagePullPolicy: Always
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: DRY_RUN
              value: "${DRY_RUN}"
            - name: TIMESTAMP
              value: ${TIMESTAMP}
            - name: RESULTS_DIR
              value: /results
            - name: TEST_SUITES
              value: ${TEST_SUITES}
            - name: TEST_SKIPS
              value: ${TEST_SKIPS}
            - name: FULL_SUITE
              value: "${FULL_SUITE}"
            - name: STORAGE_CLASS
              value: ${STORAGE_CLASS}
            - name: STORAGE_CAPABILITIES
              value: ${STORAGE_CAPABILITIES}              
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
