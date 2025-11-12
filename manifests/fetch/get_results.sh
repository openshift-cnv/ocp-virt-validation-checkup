#!/bin/bash

# This script generates the manifests required to view the validation checkup results using an nginx server

NAMESPACE=${POD_NAMESPACE:-"ocp-virt-validation"}

if [ -z "${TIMESTAMP}" ]
then
  echo "Please provide the TIMESTAMP env var of the relevant job."
  echo "To get it, please run:"
  printf '%s\n' 'export TIMESTAMP="$(oc -n ocp-virt-validation get job --sort-by=.metadata.creationTimestamp -o jsonpath='\''{.items[0].spec.template.spec.containers[?(@.name=="ocp-virt-validation-checkup")].env[?(@.name=="TIMESTAMP")].value}'\'')"'
  exit 1
fi

# Determine PVC name: derive from CONFIGMAP_NAME by removing -results suffix, or use default
if [ -n "${CONFIGMAP_NAME}" ]; then
  # Remove -results suffix if present (for UI)
  PVC_CLAIM_NAME="${CONFIGMAP_NAME%-results}"
else
  PVC_CLAIM_NAME="ocp-virt-validation-pvc-${TIMESTAMP}"
fi

# nginx config map
cat <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-conf
  namespace: ${NAMESPACE}
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

        log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                          '\$status \$body_bytes_sent "\$http_referer" '
                          '"\$http_user_agent" "\$http_x_forwarded_for"';

        access_log /var/log/nginx/access.log main;

        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        keepalive_timeout 65;
        types_hash_max_size 2048;

        server {
            listen 8080;

            # Add CORS headers
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range' always;

            location / {
                alias /results/;
                autoindex on;
                autoindex_exact_size off;
                autoindex_localtime on;
                location ~ /\.\./ {
                    deny all;
                }
                
                # If directory is empty, show a helpful message
                try_files \$uri \$uri/ @empty;
            }
            
            location @empty {
                return 200 '<html><head><title>Self-Validation Results</title></head><body><h1>Self-Validation Results</h1><p>The results directory is empty or no files were found.</p><p>This could mean:</p><ul><li>The checkup is still running</li><li>The checkup completed but no results were generated</li><li>There was an issue with result generation</li></ul><p>Please check the checkup status and try again later.</p></body></html>';
                add_header Content-Type text/html;
            }
            
            # Health check endpoint
            location /health {
                access_log off;
                add_header 'Access-Control-Allow-Origin' '*' always;
                add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
                add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range' always;
                return 200 "healthy\n";
                add_header Content-Type text/plain;
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
    timestamp: "${TIMESTAMP}"
  name: pvc-reader-${TIMESTAMP}
  namespace: ${NAMESPACE}
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
        claimName: ${PVC_CLAIM_NAME}
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
    timestamp: "${TIMESTAMP}"
  name: pvc-reader-${TIMESTAMP}
  namespace: ${NAMESPACE}
spec:
  ports:
    - name: nginx
      port: 8080
      protocol: TCP
      targetPort: 8080
  selector:
    app: pvc-reader
    timestamp: "${TIMESTAMP}"
  type: ClusterIP
EOF

# nginx route
cat <<EOF
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: pvcreader-${TIMESTAMP}
  namespace: ${NAMESPACE}
  labels:
    app: pvc-reader
    timestamp: "${TIMESTAMP}"
spec:
  path: /
  port:
    targetPort: 8080
  tls:
    insecureEdgeTerminationPolicy: Redirect
    termination: edge
  to:
    kind: Service
    name: pvc-reader-${TIMESTAMP}
    weight: 100
  wildcardPolicy: None
  # ---
  # to view the results, visit the route endpoint:
  # oc get route pvcreader-${TIMESTAMP} -n ${NAMESPACE} -o jsonpath='{.status.ingress[0].host}'
EOF
