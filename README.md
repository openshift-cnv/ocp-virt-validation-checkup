# ocp-virt-validation-checkup
This repository provides the necessary scripts and utilities to run a validation checkup of OpenShift Virtualization inside a customer environment.

## Objectives
* Run a stable subset of functional tests of [KubeVirt](https://github.com/kubevirt/kubevirt)'s main SIGs: Compute, Network, Storage, as well as [SSP](https://github.com/kubevirt/ssp-operator) test suite. These are also known as Tier-1 test suites.
* Self-sustained, unified package that contains all of the required code to run the validation checkup. The test code is fully aligned with the extact OpenShift Virtualization build installed on the cluster under test. The test suites are being run by a Job object, which runs to a completion.
* Run the test suites, with optional modifications, in a streamlined way.
* Get and browse the validation checkup results with little effort. The test suite results, logs and artifacts are being stored in a PersistentVolumeClaim. A summary of the results is being stored to a ConfigMap.


## Pre-requisites
* [OpenShift Container Platform (OCP)](https://www.redhat.com/en/technologies/cloud-computing/openshift) with [OpenShift Virtualization](https://www.redhat.com/en/technologies/cloud-computing/openshift/virtualization) 4.19 (or above) installed.
* cluster-admin permissions.
* Valid credentials to Red Hat Registry (registry.redhat.io) - Must be logged in with valid Red Hat account:
```bash
$ podman login registry.redhat.io
```
A pull secret can be obtained from https://console.redhat.com/openshift/install/pull-secret  
* `oc` command line tool.
* For tests involving Virtual Machine live migration, a ReadWriteMany storage class should be available. e.g. [OpenShift Data Foundation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/storage/configuring-persistent-storage#red-hat-openshift-data-foundation).
* For storage test suite, a default VolumeSnapshotClass should be set.
* For SSP test suite, `enableCommonBootImageImport` in HyperConverged CR should be set to `false`.

## Usage
### Get the validation checkup image
On an OpenShift cluster with OpenShift Virtualization installed, get the validation-checkup image from the CSV of OpenShift Virtualization Operator:
```bash
$ CSV_NAME=$(oc get csv -n openshift-cnv -o json | jq -r '.items[] | select(.metadata.name | startswith("kubevirt-hyperconverged")).metadata.name')
$ OCP_VIRT_VALIDATION_IMAGE=$(oc get csv -n openshift-cnv $CSV_NAME -o json | jq -r '.spec.relatedImages[] | select(.name | contains("ocp-virt-validation-checkup")).image')
```

### Run the validation checkup
Once the OCP-Virt validation checkup image is obtained, run it to generate the manifests required to run the checkup.
Dump the run manifests to stdout:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} ${OCP_VIRT_VALIDATION_IMAGE} generate
```
This will generate the following manifests:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: ocp-virt-validation
spec: {}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ocp-virt-validation-sa
  namespace: ocp-virt-validation
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
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ocp-virt-validation-pvc-20250520-105358
  namespace: ocp-virt-validation
  labels:
    app: ocp-virt-validation
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ocp-virt-validation-job-20250520-105358
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
          image: registry.redhat.io/container-native-virtualization/ocp-virt-validation-checkup-rhel9:v4.19.0-28
          imagePullPolicy: Always
          env:
            - name: DRY_RUN
              value: "false"
            - name: TIMESTAMP
              value: 20250520-105358
            - name: RESULTS_DIR
              value: /results
            - name: TEST_SUITES
              value: compute,network,storage,ssp,tier2
            - name: TEST_SKIPS
              value: ""
          volumeMounts:
            - name: results-volume
              mountPath: /results
      restartPolicy: Never
      volumes:
        - name: results-volume
          persistentVolumeClaim:
            claimName: ocp-virt-validation-pvc-20250520-105358
  backoffLimit: 0
```
In order to apply these manifests directly onto the cluster in order to start the validation checkup, run:
```bash
podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} ${OCP_VIRT_VALIDATION_IMAGE} generate | oc apply -f -
```
You can use output redirection to a file in order to make adjustments, if needed:
```bash
podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} ${OCP_VIRT_VALIDATION_IMAGE} generate > run_manifests.yaml
```

### Make modifications
The default settings of the validation checkup can be modified before the execution.

#### Test Suites
By default, the validation checkup will run all of the test suites.  
It is possible to configure a subset of the suites to run. The available test suites are:
* `compute` - conformance tests with `sig-compute` label from the [KubeVirt](https://github.com/kubevirt/kubevirt/tree/main/tests) repository.
* `network` - conformance tests with `sig-network` label from the [KubeVirt](https://github.com/kubevirt/kubevirt/tree/main/tests) repository
* `storage` - conformance tests with `sig-storage` label + tests with `StorageCritical` label from the [KubeVirt](https://github.com/kubevirt/kubevirt/tree/main/tests) repository
* `ssp` - tests from [ssp-operator](https://github.com/kubevirt/ssp-operator/tree/main/tests) repository.
* `tier2` - Conformance tests from [openshift-virtualization-tests](https://github.com/RedHatQE/openshift-virtualization-tests) repository.

Use the `TEST_SUITES` environment variable, with a comma separated list of the desired suites, when running the `generate` script. The example below shows how to run only the `compute` and the `network` suites, by setting `TEST_SUITES` to `"compute,network"`:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} -e TEST_SUITES=compute,network,tier2 ${OCP_VIRT_VALIDATION_IMAGE} generate
```
This will configure the following environment variable for the job:
```yaml
apiVersion: batch/v1
kind: Job
spec:
  template:
    spec:
      containers:
        - name: ocp-virt-validation-checkup
          env:
            - name: TEST_SUITES
              value: compute,network,tier2
```

**Note:** the value passed to `TEST_SUITES` should be comma-separated.

#### Test Skips
In order to skip one or more test cases, a `TEST_SKIPS` environment variable can be specified.
Example:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} -e TEST_SKIPS="test_id:1783|test_id:1853" ${OCP_VIRT_VALIDATION_IMAGE} generate
```
**Note:** the value passed to `TEST_SKIPS` should be pipe-separated.

#### Full Suite
By default, only a small, representative and most robust test cases are selected to run.  
In order to run all of the available tests, without filtering only to the conformance ones, the ` FULL_SUITE` environment variable can be set to `true`.  
_Warning_: Using `FULL_SUITE=true` might prolong the checkup run time significantly, and a large amount of test failures/errors are expected.  

#### Storage Class
In order to set the storage class that will be used throughout the test suites, a `STORAGE_CLASS` environment variable should be specified.
Example:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} -e STORAGE_CLASS=ocs-storagecluster-ceph-rbd-virtualization ${OCP_VIRT_VALIDATION_IMAGE} generate
```
If no `STORAGE_CLASS` environment variable is set, the default storage class in the cluster will be used for the checkup.

**Note:** If the specified storage class is not recognized by the validation checkup and no `STORAGE_CAPABILITIES` are provided, the checkup will fail with an error message: *"The selected storage class was not found and neither STORAGE_CAPABILITIES have been provided"*. In such cases, you must either use a supported storage class or explicitly define the storage capabilities using the `STORAGE_CAPABILITIES` environment variable.

#### Storage Capabilities
The storage capabilities (such as: volume mode, access mode, snapshot support, etc.) are resolved based on the storage class name, using a predefined list of known storage providers. If the selected storage provider is not known, the `STORAGE_CAPABILITIES` env var must be passed, to instruct the tests what are the storage capabilities that should be put under tests.  
The syntax of `STORAGE_CAPABILITIES` env var is a comma-separated list of these properties:
- storageClassRhel
- storageClassWindows
- storageRWXBlock
- storageRWXFileSystem
- storageRWOFileSystem
- storageRWOBlock
- storageClassCSI
- storageSnapshot
- onlineResize
- WFFC

It is possible to set any subset of this list, according to the actual capabilities of the specified storage class.
Example:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} -e STORAGE_CLASS=my-awesome-sc -e STORAGE_CAPABILITIES=storageClassRhel,storageRWXFileSystem,storageRWOBlock,onlineResize ${OCP_VIRT_VALIDATION_IMAGE} generate
```
Which will produce the following Job yaml (only the relevant section is displayed):
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ocp-virt-validation-job-20250810-101901
  namespace: ocp-virt-validation
spec:
  template:
    spec:
      containers:
        - name: ocp-virt-validation-checkup
          env:
            - name: STORAGE_CLASS
              value: my-awesome-sc
            - name: STORAGE_CAPABILITIES
              value: storageClassRhel,storageRWXFileSystem,storageRWOBlock,onlineResize
...
```

**Note:** If the provisioner is recognized by [CDI](https://github.com/kubevirt/containerized-data-importer), it is possible to get the the supported access mode and volume mode for a given Storage Class by checking its StorageProfile, e.g.
```
$ oc get storageprofile my-custom-sc -o yaml | yq .status.claimPropertySets
- accessModes:
    - ReadWriteMany
  volumeMode: Filesystem
```
In this case, `storageRWXFileSystem` should be set.

**Note** If the `storageSnapshot` storage capability is not passed, tests that are requiring snapshots will fail with error. The snapshot tests are not skipped because they are a core functionality of OpenShift Virtualization.

#### Dry Run
In order to see which tests are going to be run, without actually executing them on the cluster, a `DRY_RUN` environment variable can be set:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} -e DRY_RUN=true ${OCP_VIRT_VALIDATION_IMAGE} generate
```

## Disconnected Environments
The validation checkup can be run on disconnected (air-gapped) OpenShift clusters by using a mirror registry. This section explains how to configure the checkup for disconnected environments.

### Prerequisites for Disconnected Environments
1. A mirror registry that contains all the required images
2. The cluster must be configured to pull images from the mirror registry

### Using the REGISTRY_SERVER Parameter
The `REGISTRY_SERVER` environment variable allows you to specify a custom mirror registry that replaces the default public registries (`registry.redhat.io`, `quay.io`, `ghcr.io`) used by the validation checkup.

Example:
```bash
$ podman run -e OCP_VIRT_VALIDATION_IMAGE=${OCP_VIRT_VALIDATION_IMAGE} -e REGISTRY_SERVER=my-mirror-registry.example.com:5000 ${OCP_VIRT_VALIDATION_IMAGE} generate
```

This will configure the Job to use your mirror registry for all image pulls:
```yaml
apiVersion: batch/v1
kind: Job
spec:
  template:
    spec:
      containers:
        - name: ocp-virt-validation-checkup
          env:
            - name: REGISTRY_SERVER
              value: my-mirror-registry.example.com:5000
```

When retrieving checkup results, you should also pass the `REGISTRY_SERVER` parameter so that the nginx pod used to serve results is pulled from your mirror registry:
```bash
$ podman run -e TIMESTAMP=${TIMESTAMP} -e REGISTRY_SERVER=my-mirror-registry.example.com:5000 ${OCP_VIRT_VALIDATION_IMAGE} get_results | oc apply -f -
```

### Mirror Registry Configuration
The mirror registry server **must be configured to allow image pulls without authentication** from within the cluster. The validation checkup relies on unauthenticated access to pull images from the mirror registry during test execution.

### Certificate Configuration
The cluster must trust the mirror registry's TLS certificate to avoid `x509: certificate signed by unknown authority` errors.

#### Option 1: Add the Registry Certificate to the Cluster (Recommended)
Add your mirror registry's CA certificate to the cluster's trusted CA bundle:

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

#### Option 2: Configure the Registry as Insecure
If you cannot add the certificate to the cluster, you can configure the registry as insecure. **This is not recommended for production environments.**

Add your mirror registry to the `registrySources.insecureRegistries` list in the cluster's image configuration:
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

**Note:** After modifying the image configuration, the Machine Config Operator will roll out changes to all nodes. Wait for the rollout to complete before running the validation checkup:
```bash
$ oc wait machineconfigpool --all --for=condition=Updated --timeout=30m
```

### Mirroring Required Images
Ensure that all images used by the validation checkup are mirrored to your registry. The primary images that need to be mirrored include:
- The OpenShift Virtualization related images (from `registry.redhat.io`)
- KubeVirt utility container images (from `quay.io/kubevirt`)
- The `astral-sh/uv` image (from `ghcr.io`) for tier2 tests
- The nginx image `rhel9/nginx-124:latest` (from `registry.redhat.io`) for viewing detailed results

You can use the `oc adm catalog mirror` or `oc image mirror` commands to mirror these images to your disconnected registry.


## Retrieve Checkup Results
The checkup results are available both in the form of a summary, and a browsable detailed results.

### Results Summary
Once the validation checkup finishes, a ConfigMap is being created at the `ocp-virt-validation` namespace with a summary of all results.  
The config map includes a yaml which is divided to a section for each executed test suite, as well as a summary section.  
Example:
```yaml
compute:
  failed_tests:
  - '[rfe_id:393][crit:high][vendor:cnv-qe@redhat.com][level:system][sig-compute]
    VM Live Migration Starting a VirtualMachineInstance  with a Alpine disk [test_id:1783]should
    be successfully migrated multiple times with cloud-init disk'
  - '[rfe_id:393][crit:high][vendor:cnv-qe@redhat.com][level:system][sig-compute]
    VM Live Migration with sata disks [test_id:1853]VM with containerDisk + CloudInit
    + ServiceAccount + ConfigMap + Secret + DownwardAPI + External Kernel Boot + USB
    Disk'
  - '[rfe_id:1177][crit:medium][vendor:cnv-qe@redhat.com][level:component][sig-compute]VirtualMachine
    A valid VirtualMachine given [test_id:1521]should remove VirtualMachineInstance
    once the VM is marked for deletion [storage-req]with Filesystem Disk'
  tests_failures: 3
  tests_passed: 63
  tests_run: 66
  tests_skipped: 0
network:
  failed_tests:
  - '[sig-network] network binding plugin with domain attachment managedTap type can
    establish communication between two VMs'
  tests_failures: 1
  tests_passed: 151
  tests_run: 152
  tests_skipped: 0
ssp:
  failed_tests:
  - '[It] DataSources rbac os-images With Edit permission should verify resource permissions
    [test_id:4774]: ServiceAcounts with edit role can create PVCs'
  - '[It] Prometheus Alerts VMStorageClassWarning [test_id:TODO] Should not fire VMStorageClassWarning
    when rxbounce is enabled'
  tests_failures: 2
  tests_passed: 294
  tests_run: 299
  tests_skipped: 3
storage:
  tests_failures: 0
  tests_passed: 15
  tests_run: 15
  tests_skipped: 0
summary:
  total_tests_failed: 6
  total_tests_passed: 526
  total_tests_run: 532
```

### Detailed Results
In order to view the detailed results of the validation checkup execution once the Job finishes, an nginx server that mounts the PVC should be set up.  
To do so, the timestamp of the last execution should first be retrieved:  
```bash
$ TIMESTAMP="$(oc -n ocp-virt-validation get job --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].spec.template.spec.containers[?(@.name=="ocp-virt-validation-checkup")].env[?(@.name=="TIMESTAMP")].value}')"
```
Then, use that timestamp and run:  
```bash
$ podman run -e TIMESTAMP=${TIMESTAMP} ${OCP_VIRT_VALIDATION_IMAGE} get_results
```
This command will generate the required manifests to set up an nginx server and expose it through a Route.  
The command output would look similar to:  
```yaml
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

        log_format main ' -  [] "" '
                          '  "" '
                          '"" ""';

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
---
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: pvc-reader
  name: pvc-reader-20250518-112311
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
        claimName: ocp-virt-validation-pvc-20250518-112311
    - name: conf
      configMap:
        name: nginx-conf
        items:
          - key: nginx.conf
            path: nginx.conf
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
```
**Note:** You can apply the manifests directly from the command, using:
```bash
$ podman run -e TIMESTAMP=${TIMESTAMP} ${OCP_VIRT_VALIDATION_IMAGE} get_results | oc apply -f -
configmap/nginx-conf created
pod/pvc-reader-20250518-112311 created
service/pvc-reader created
route.route.openshift.io/pvcreader created
```
The Route leading to the nginx server hosting the detailed results will be available at:  
```bash
$ oc get route pvcreader -n ocp-virt-validation -o jsonpath='{.status.ingress[0].host}'
```
The nginx server hosts a file directory, containing a directory for every executed test suite.  
For each subdirectory (compute, network, storage, ssp), there are:
* The full ginkgo log of the run
* JUnit file
* k8s-reporter folder, containing artifacts of the failed test runs.

In addition, a compressed `tar.gz` file is provided at the root directory, allowing the user to download it and browse the results locally.

**Note**
Instead of using the Route for the PVC Reader nginx server, you can use the following command to access it:
```bash
$ oc port-forward service/pvc-reader 8080:8080 -n ocp-virt-validation
```
And then the results will be accessible through http://localhost:8080
