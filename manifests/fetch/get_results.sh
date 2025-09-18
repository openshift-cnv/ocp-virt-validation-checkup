#!/bin/bash

# This script generates the manifests required to view the validation checkup results using an nginx server


if [ -z "${TIMESTAMP}" ]
then
  echo "Please provide the TIMESTAMP env var of the relevant job."
  echo "To get it, please run:"
  printf '%s\n' 'export TIMESTAMP="$(oc -n ocp-virt-validation get job --sort-by=.metadata.creationTimestamp -o jsonpath='\''{.items[0].spec.template.spec.containers[?(@.name=="ocp-virt-validation-checkup")].env[?(@.name=="TIMESTAMP")].value}'\'')"'
  exit 1
fi

# nginx config map
cat <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-conf
  namespace: ocp-virt-validation
data:
  nginx.conf: |-
    user nginx;
    worker_processes auto;

    error_log /var/log/nginx/error.log warn;
    pid /var/run/nginx.pid;

    events {
        worker_connections 1024;
    }

    http {
        include /etc/nginx/mime.types;
        default_type application/octet-stream;

        log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                          '$status $body_bytes_sent "$http_referer" '
                          '"$http_user_agent" "$http_x_forwarded_for"';

        access_log /var/log/nginx/access.log main;

        sendfile on;

        keepalive_timeout 65;

        server {
            listen 8080;

            location / {
                alias /results/;
                autoindex on;
                autoindex_exact_size off;
                autoindex_localtime on;
                location ~ /\.\./ {
                    deny all;
                }
            }
        }
    }
EOF


# nginx pod
cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: pvc-reader
  name: pvc-reader-${TIMESTAMP}
  namespace: ocp-virt-validation
spec:
  containers:
    - image: registry.redhat.io/rhel9/nginx-124:latest
      name: pod
      command:
        - "sh"
        - "-c"
        - "nginx -g \"daemon off;\""
      volumeMounts:
        - mountPath: /results
          name: results
        - name: conf
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
      resources: {}
  dnsPolicy: ClusterFirst
  restartPolicy: Always
  volumes:
    - name: results
      persistentVolumeClaim:
        claimName: ocp-virt-validation-pvc-${TIMESTAMP}
    - name: conf
      configMap:
        name: nginx-conf
        items:
          - key: nginx.conf
            path: nginx.conf
EOF

# nginx service
cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: pvc-reader
  name: pvc-reader
  namespace: ocp-virt-validation
spec:
  ports:
    - name: nginx
      port: 8080
      protocol: TCP
      targetPort: 8080
  selector:
    app: pvc-reader
  type: ClusterIP
EOF

# nginx route
cat <<EOF
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: pvcreader
  namespace: ocp-virt-validation
spec:
  path: /
  port:
    targetPort: 8080
  tls:
    insecureEdgeTerminationPolicy: Redirect
    termination: edge
  to:
    kind: Service
    name: pvc-reader
    weight: 100
  wildcardPolicy: None
  # ---
  # to view the results, visit the route endpoint:
  # oc get route pvcreader -n ocp-virt-validation -o jsonpath='{.status.ingress[0].host}'
EOF