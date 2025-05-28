#!/hint/bash

#
# Common functions used by test scripts
#

tests::hco::disable() {
  local hco_namespace

  # On hypershift guest clusters the control plane pods are running on the infra cluster
  CONTROL_PLANE_TOPOLOGY=$(oc get infrastructure cluster -o=jsonpath='{$.status.controlPlaneTopology}')
  if [[ ${CONTROL_PLANE_TOPOLOGY} != "External" ]]; then
    # Disable CVO so that it doesn't reconcile the OLM Operator
    oc scale deployment/cluster-version-operator \
      --namespace='openshift-cluster-version' \
      --replicas='0'

    # Disable OLM so that it doesn't reconcile the HCO Operator
    oc scale deployment/olm-operator \
      --namespace='openshift-operator-lifecycle-manager' \
      --replicas='0'
  fi

  # Disable HCO so that it doesn't reconcile CRs CDI, KubeVirt, ...
  hco_namespace=$(
    oc get deployments --all-namespaces \
      --field-selector=metadata.name='hco-operator' \
      --output=jsonpath='{$.items[0].metadata.namespace}'
  )
  oc scale deployment/hco-operator \
    --namespace="${hco_namespace}" \
    --replicas='0'

  # Ensure HCO pods are gone
  oc wait pods \
    --namespace="${hco_namespace}" \
    --selector='name=hyperconverged-cluster-operator' \
    --for=delete \
    --timeout='2m' ||
    echo 'failed to verify HCO pods are gone / were already gone at the point we executed oc wait'
}

#
# (Re-)Enable HCO operator.
#
tests::hco::enable() {
  local hco_namespace

  # HCO
  hco_namespace=$(
    oc get deployments --all-namespaces \
      --field-selector=metadata.name='hco-operator' \
      --output=jsonpath='{$.items[0].metadata.namespace}'
  )
  oc scale deployment/hco-operator \
    --namespace="${hco_namespace}" \
    --replicas='1'

  # On hypershift guest clusters the control plane pods are running on the infra cluster
  CONTROL_PLANE_TOPOLOGY=$(oc get infrastructure cluster -o=jsonpath='{$.status.controlPlaneTopology}')
  if [[ ${CONTROL_PLANE_TOPOLOGY} != "External" ]]; then
    # OLM
    oc scale deployment/olm-operator \
      --namespace='openshift-operator-lifecycle-manager' \
      --replicas='1'

    # CVO
    oc scale deployment/cluster-version-operator \
      --namespace='openshift-cluster-version' \
      --replicas='1'
  fi

  # Ensure HCO is available
  oc wait deployment/hco-operator \
    --namespace="${hco_namespace}" \
    --for=condition='Available' \
    --timeout='2m'
}

#
# Get the namespace where HCO is installed.
#
# Outputs:
#   Writes HCO namespace to stdout (fails if HCO is not installed).
#
tests::hco::get_namespace() {
  oc get deployments \
    --all-namespaces \
    --field-selector='metadata.name=hco-operator' \
    --output=jsonpath='{$.items[0].metadata.namespace}'
}

#
# Waits until all DataImportCrons are ready.
#
tests::hco::wait_for_data_import_crons() {
  local hco_namespace=$(tests::hco::get_namespace)

  local default_namespace="openshift-virtualization-os-images"

  # Get DataImportCrons from HCO object and extract their name and namespace
  local data_import_crons=$(
    oc get hyperconverged/kubevirt-hyperconverged \
      --namespace="${hco_namespace}" \
      --output=jsonpath='{$.status.dataImportCronTemplates}' |
    # Using compact output so newline is only between elements of the array.
    # Then we can iterate over them later.
    jq --compact-output "[.[] | {name: .metadata.name, namespace: (.metadata.namespace // \"${default_namespace}\")}] | .[]"
  )

  # Total timeout for all objects is 20 minutes.
  local wait_timeout=1200
  for data_import_cron in ${data_import_crons}; do
    local data_import_cron_name=$(echo "${data_import_cron}" | jq --raw-output '.name')
    local data_import_cron_namespace=$(echo "${data_import_cron}" | jq --raw-output '.namespace')

    local start_time=$(date +%s)
    oc wait "dataimportcrons/${data_import_cron_name}" \
      --namespace="${data_import_cron_namespace}" \
      --for=condition=UpToDate \
      --timeout="${wait_timeout}s"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    wait_timeout=$((wait_timeout - duration))
    if [ ${wait_timeout} -lt 0 ]; then
      wait_timeout=0
    fi
  done
}

tests::normalize_docker_tag() {
  echo $1 | sed -Ee 's/^(v[0-9]+[.][0-9]+[.][0-9]+(-(alpha|rc).[0-9]+)?).*$/\1/'
}

#
# Get the namespace where CDI is installed.
#
# Outputs:
#   Writes CDI namespace to stdout (fails if CDI is not installed).
#
tests::cdi::get_namespace() {
  oc get deployments \
    --all-namespaces \
    --field-selector='metadata.name=cdi-apiserver' \
    --output=jsonpath='{$.items[0].metadata.namespace}'
}

#
# Changes CDI loglevel via the CDI Operator.
#
# OLM operator must be disabled beforehand so that it won't revert the changes.
#
# Arguments:
# - $1: loglevel to set
# - $2: namespace where CDI is installed
#
tests::cdi::set_loglevel() {
  local loglevel cdi_namespace

  loglevel=$1
  shift
  cdi_namespace=$1
  shift

  oc set env deployment cdi-operator \
    --namespace="${cdi_namespace}" \
    --containers='cdi-operator' \
    VERBOSITY="${loglevel}"

}

#
# Get the namespace where KubeVirt is installed.
#
# Outputs:
#   Writes KubeVirt namespace to stdout (fails if KubeVirt is not installed).
#
tests::kubevirt::get_namespace() {
  oc get deployments \
    --all-namespaces \
    --field-selector='metadata.name=virt-api' \
    --output=jsonpath='{$.items[0].metadata.namespace}'
}

#
# Get KV image reference.
# Arguments:
# - $1: KV namespace.
# - $2: Private registry pull secrets.
#
tests::kubevirt::get_image_ref() {
  local KUBEVIRT_IMAGE_REF=$(
    oc get deployment virt-api \
      --namespace="$1" \
      --output=jsonpath='{$.spec.template.spec.containers[0].image}'
  )

  # If the image doesn't exist, it was probably pulled from a mirror
  # using rules from an OCP ImageContentSourcePolicy
  if ! oc image info -a "$2" "${KUBEVIRT_IMAGE_REF}" &>/dev/null; then
    local KUBEVIRT_IMAGE_SHA256=${KUBEVIRT_IMAGE_REF##*@}
    local KUBEVIRT_IMAGE=${KUBEVIRT_IMAGE_REF%@*}
    local KUBEVIRT_IMAGE_NAME=${KUBEVIRT_IMAGE##*/}
    KUBEVIRT_IMAGE=$(
      oc get idms,imagecontentsourcepolicy --output='json' |
        jq -r '
            [ .. | .mirrors? ]
            | map(select(. != null))
            | flatten
            | map(select(endswith("'"${KUBEVIRT_IMAGE_NAME}"'")))
            | first
          '
    )

    KUBEVIRT_IMAGE_REF=${KUBEVIRT_IMAGE}@${KUBEVIRT_IMAGE_SHA256}
  fi

  echo "${KUBEVIRT_IMAGE_REF}"
}

#
# Get KV image labels.
# Arguments:
# - $1: Image reference.
# - $2: Private registry pull secrets.
#
tests::kubevirt::get_image_labels() {
  oc image info --output='json' \
    --registry-config="$2" \
    --skip-verification \
    "$1" |
    jq '.config.config.Labels'
}

#
# Remove containers and volumes from the previous test builds
#
tests::docker::build_cleanup() {
  docker stop --all -t0 || true
  docker rm --all || true
  docker volume prune --force || true
  #  make clean
}

#
# Disable the SSP operator by deleting its CR. It is useful to disable its
# reconciliation loop when changes are being made to SSP managed
# CustomResources. HCO needs to be disabled first before calling this func.
# To reenable SSP you have to reenable HCO, which will recreate the SSP CR.
#
tests::ssp::disable() {
  local ssp_namespace

  ssp_namespace=$(
    oc get deployments --all-namespaces \
      --field-selector=metadata.name='ssp-operator' \
      --output=jsonpath='{$.items[0].metadata.namespace}'
  )

  oc delete ssp ssp-kubevirt-hyperconverged \
    --namespace="${ssp_namespace}" \
    --cascade=foreground \
    --wait=true \
    --timeout='2m' ||
    echo 'failed to delete SSP CR'
}

tests::does_image_exist() {
  local image="$1"
  if oc image info ${image} &>/dev/null; then
      return 0
  else
      return 1
  fi
}

#
# Get the namespace where the Prometheus stack is installed.
#
# Outputs:
#   Writes the Prometheus namespace to stdout
#
tests::monitoring::get_prometheus_namespace() {
  oc get statefulsets \
    --all-namespaces \
    --field-selector='metadata.name=prometheus-k8s' \
    --output=jsonpath='{$.items[0].metadata.namespace}' \
    --ignore-not-found
}

create_kubeconfig() {
  SERVICE_ACCOUNT_DIR=/var/run/secrets/kubernetes.io/serviceaccount
  TOKEN=$(cat ${SERVICE_ACCOUNT_DIR}/token)
  CA_CERT=${SERVICE_ACCOUNT_DIR}/ca.crt
  NAMESPACE=$(cat ${SERVICE_ACCOUNT_DIR}/namespace)
  APISERVER=https://kubernetes.default.svc

  KUBECONFIG_FILE=kubeconfig

  oc config set-cluster in-cluster \
    --server="${APISERVER}" \
    --certificate-authority="${CA_CERT}" \
    --embed-certs=true \
    --kubeconfig="${KUBECONFIG_FILE}"

  oc config set-credentials sa-user \
    --token="${TOKEN}" \
    --kubeconfig="${KUBECONFIG_FILE}"

  oc config set-context sa-context \
    --cluster=in-cluster \
    --user=sa-user \
    --namespace="${NAMESPACE}" \
    --kubeconfig="${KUBECONFIG_FILE}"

  oc config use-context sa-context --kubeconfig="${KUBECONFIG_FILE}"
}

