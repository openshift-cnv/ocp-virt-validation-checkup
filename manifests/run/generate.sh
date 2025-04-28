#!/bin/bash

# This script generates the manifests required to run the ocp-virt validation checkup


TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")

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
          image: quay.io/orenc/ocp-virt-validation-checkup-rhel9:v4.99.0-11
          imagePullPolicy: Always
          env:
            - name: DRY_RUN
              value: "false"
            - name: TIMESTAMP
              value: ${TIMESTAMP}
            - name: RESULTS_DIR
              value: /results
          volumeMounts:
            - name: results-volume
              mountPath: /results
      restartPolicy: Never
      volumes:
        - name: results-volume
          persistentVolumeClaim:
            claimName: ocp-virt-validation-pvc-${TIMESTAMP}
  backoffLimit: 1
EOF