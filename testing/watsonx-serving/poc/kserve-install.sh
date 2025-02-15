#!/bin/bash

# running from opendatahub-io/caikit-tgis-serving::scripts/install/kserve-install.sh

# Environment variables
# - CHECK_UWM: Set this to "false", if you want to skip the User Workload Configmap check message
# - TARGET_OPERATOR: Set this among odh, rhods or brew, if you want to skip the question in the script.

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
set -x

source "$(dirname "$(realpath "$0")")/../env.sh"
source "$(dirname "$(realpath "$0")")/../utils.sh"

input=y
if [ "$input" = "y" ]; then
    if [[ ! -n ${TARGET_OPERATOR} ]]
    then
      read -p "TARGET_OPERATOR is not set. Is it for odh or rhods or brew?" input_target_op
      if [[ $input_target_op == "odh" || $input_target_op == "rhods" || $input_target_op == "brew" ]]
      then
        export TARGET_OPERATOR=$input_target_op
        export TARGET_OPERATOR_TYPE=$(getOpType $input_target_op)
      else
        echo "[ERR] Only 'odh' or 'rhods' or 'brew' can be entered"
        exit 1
      fi
    else
      export TARGET_OPERATOR_TYPE=$(getOpType $TARGET_OPERATOR)
    fi

    if [[ ! -n ${BREW_TAG} ]]
    then
      read -p "BREW_TAG is not set, what is BREW_TAG?" brew_tag
      if [[ $brew_tag =~ ^[0-9]+$ ]]
      then
        export BREW_TAG=$brew_tag
      else
        echo "[ERR] BREW_TAG must be number only"
        exit 1
      fi
    fi

    export KSERVE_OPERATOR_NS=$(getKserveNS)
    export TARGET_OPERATOR_NS=$(getOpNS ${TARGET_OPERATOR})
    echo
    echo "Let's install KServe"
else
    echo "ERROR: Please check the configmap and execute this script again"
    exit 1
fi

mkdir -p ${BASE_DIR}
mkdir -p ${BASE_CERT_DIR}

# Install Service Mesh operators
echo "[INFO] Install Service Mesh operators"
echo
#oc apply -f custom-manifests/service-mesh/operators.yaml

wait_for_csv_installed servicemeshoperator openshift-operators
wait_for_csv_installed kiali-operator openshift-operators
wait_for_csv_installed jaeger-operator openshift-operators
oc wait --for=condition=ready pod -l name=istio-operator -n openshift-operators --timeout=300s
oc wait --for=condition=ready pod -l name=jaeger-operator -n openshift-operators --timeout=300s
oc wait --for=condition=ready pod -l name=kiali-operator -n openshift-operators --timeout=300s

# Create an istio instance
echo
echo "[INFO] Create an istio instance"
echo
oc create ns istio-system -oyaml --dry-run=client | oc apply -f-
oc::wait::object::availability "oc get project istio-system" 2 60

oc apply -f custom-manifests/service-mesh/smcp.yaml
wait_for_pods_ready "app=istiod" "istio-system"
wait_for_pods_ready "app=istio-ingressgateway" "istio-system"
wait_for_pods_ready "app=istio-egressgateway" "istio-system"
wait_for_pods_ready "app=jaeger" "istio-system"

oc wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=300s
oc wait --for=condition=ready pod -l app=istio-ingressgateway -n istio-system --timeout=300s
oc wait --for=condition=ready pod -l app=istio-egressgateway -n istio-system --timeout=300s
oc wait --for=condition=ready pod -l app=jaeger -n istio-system --timeout=300s

# kserve/knative
echo
echo "[INFO]Update SMMR"
echo
if [[ ${TARGET_OPERATOR_TYPE} == "odh" ]];
then
  oc create ns opendatahub -oyaml --dry-run=client | oc apply -f-
  oc::wait::object::availability "oc get project opendatahub" 2 60
else
  oc create ns redhat-ods-applications -oyaml --dry-run=client | oc apply -f-
  oc::wait::object::availability "oc get project redhat-ods-applications" 2 60
fi
oc create ns knative-serving -oyaml --dry-run=client | oc apply -f-
oc::wait::object::availability "oc get project knative-serving" 2 60

oc delete -f custom-manifests/service-mesh/smmr-${TARGET_OPERATOR_TYPE}.yaml --ignore-not-found
oc apply -f custom-manifests/service-mesh/smmr-${TARGET_OPERATOR_TYPE}.yaml
oc apply -f custom-manifests/service-mesh/peer-authentication.yaml
oc apply -f custom-manifests/service-mesh/peer-authentication-${TARGET_OPERATOR_TYPE}.yaml
# we need this because of https://access.redhat.com/documentation/en-us/openshift_container_platform/4.12/html/serverless/serving#serverless-domain-mapping-custom-tls-cert_domain-mapping-custom-tls-cert

echo
echo "[INFO] Install Serverless Operator"
echo
#oc apply -f custom-manifests/serverless/operators.yaml
wait_for_csv_installed serverless-operator openshift-operators

wait_for_pods_ready "name=knative-openshift" "openshift-operators"
wait_for_pods_ready "name=knative-openshift-ingress" "openshift-operators"
wait_for_pods_ready "name=knative-operator" "openshift-operators"
oc wait --for=condition=ready pod -l name=knative-openshift -n openshift-operators --timeout=300s
oc wait --for=condition=ready pod -l name=knative-openshift-ingress -n openshift-operators --timeout=300s
oc wait --for=condition=ready pod -l name=knative-operator -n openshift-operators --timeout=300s

# Create a Knative Serving installation
echo
echo "[INFO] Create a Knative Serving installation"
echo
oc apply -f custom-manifests/serverless/knativeserving-istio.yaml

wait_for_pods_ready "app=controller" "knative-serving"
wait_for_pods_ready "app=net-istio-controller" "knative-serving"
wait_for_pods_ready "app=net-istio-webhook" "knative-serving"
wait_for_pods_ready "app=autoscaler-hpa" "knative-serving"
wait_for_pods_ready "app=domain-mapping" "knative-serving"
wait_for_pods_ready "app=webhook" "knative-serving"
oc delete pod -n knative-serving -l app=activator --force --grace-period=0
oc delete pod -n knative-serving -l app=autoscaler --force --grace-period=0
wait_for_pods_ready "app=activator" "knative-serving"
wait_for_pods_ready "app=autoscaler" "knative-serving"

oc wait --for=condition=ready pod -l app=controller -n knative-serving --timeout=300s
oc wait --for=condition=ready pod -l app=net-istio-controller -n knative-serving --timeout=300s
oc wait --for=condition=ready pod -l app=net-istio-webhook -n knative-serving --timeout=300s
oc wait --for=condition=ready pod -l app=autoscaler-hpa -n knative-serving --timeout=300s
oc wait --for=condition=ready pod -l app=domain-mapping -n knative-serving --timeout=300s
oc wait --for=condition=ready pod -l app=webhook -n knative-serving --timeout=300s
oc wait --for=condition=ready pod -l app=activator -n knative-serving --timeout=300s
oc wait --for=condition=ready pod -l app=autoscaler -n knative-serving --timeout=300s

# Generate wildcard cert for a gateway.
export DOMAIN_NAME=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' | awk -F'.' '{print $(NF-1)"."$NF}')
export COMMON_NAME=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'|sed 's/apps.//')

# cd ${BASE_CERT_DIR}
## Generate wildcard cert using openssl
#echo
#echo "[INFO] Generate wildcard cert using openssl"
#echo
#bash -xe ./scripts/generate-wildcard-certs.sh ${BASE_CERT_DIR} ${DOMAIN_NAME} ${COMMON_NAME}

# Create the Knative gateways
oc create secret tls wildcard-certs --cert=${BASE_CERT_DIR}/wildcard.crt --key=${BASE_CERT_DIR}/wildcard.key -n istio-system -oyaml --dry-run=client | oc apply -f-
oc apply -f custom-manifests/serverless/gateways.yaml

# Create brew catalogsource
if [[ ${TARGET_OPERATOR} == "brew" ]];
then
  echo
  echo "[INFO] Create catalogsource for brew registry"
  echo
  sed "s/<%brew_tag%>/$BREW_TAG/g" custom-manifests/brew/catalogsource.yaml |oc apply -f -

  wait_for_pods_ready "olm.catalogSource=rhods-catalog-dev" "openshift-marketplace"
  oc wait --for=condition=ready pod -l olm.catalogSource=rhods-catalog-dev -n openshift-marketplace --timeout=60s
fi

# Deploy odh/rhods operator
echo
echo "[INFO] Deploy odh/rhods operator"
echo
if [[ ${TARGET_OPERATOR_TYPE} == "rhods" ]];
then
  oc create ns ${TARGET_OPERATOR_NS} -oyaml --dry-run=client | oc apply -f-
  oc::wait::object::availability "oc get project ${TARGET_OPERATOR_NS} " 2 60
fi
oc apply -f custom-manifests/opendatahub/${TARGET_OPERATOR}-operators-2.0.yaml

wait_for_pods_ready "name=rhods-operator" "${TARGET_OPERATOR_NS}"
oc wait --for=condition=ready pod -l name=rhods-operator -n ${TARGET_OPERATOR_NS} --timeout=300s

echo
echo "[INFO] Deploy KServe"
echo
oc apply -f custom-manifests/opendatahub/kserve-dsc.yaml

tries_left=30 # 30*10s = 5min
while true; do
    if [[ $tries_left == 0 ]]; then
        echo "ERROR: the DataScienceCluster didn't get ready in time :/"
        oc get -f custom-manifests/opendatahub/kserve-dsc.yaml -oyaml
        exit 1
    fi
    sleep 10
    phase=$(oc get -f custom-manifests/opendatahub/kserve-dsc.yaml -ojsonpath={.status.phase})
    tries_left=$((tries_left - 1))

    if [[ -z "$phase" || "$phase" == "Progressing" ]]; then
        continue
    fi
    if [[ "$phase" == "Ready" ]]; then
        echo "DataScienceCluster is ready :)"
        break
    fi
done
