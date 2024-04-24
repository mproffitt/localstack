#!/bin/bash

function wait_for_cluster_resource () {
  local type=$1
  local name=$2

  echo "Waiting for $type $name to be ready..."
  until kubectl get $type --no-headers 2>&1 | grep -q "$name"; do
    echo -n "."
    sleep 1
  done
  echo
}

if [ -z "$LOCALSTACK_AUTH_TOKEN" ]; then
  echo "Please set LOCALSTACK_AUTH_TOKEN environment variable"
  echo " export LOCALSTACK_AUTH_TOKEN=<your-token>"
  exit 1
fi

kind delete cluster -n localstack 2>/dev/null
kind create cluster -n localstack --config kind.yaml

## install nginx-ingress
kustomize build ./nginx | kubectl apply -f -

namespace="ingress-nginx"
label_selector="app.kubernetes.io/component=controller"
timeout=90

# Wait for the resource to exist
echo "Waiting for nginx ingress controller to be created..."
until kubectl get pods -n $namespace -l $label_selector --no-headers | grep -q "Running"; do
  echo -n "."
  sleep 1
done
echo

echo "Pod is created, waiting for it to be ready..."
# Now wait for the resource to be ready
kubectl wait --namespace $namespace \
  --for=condition=ready pod \
  --selector=$label_selector \
  --timeout=${timeout}s

# install helm repos
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo add localstack-repo https://helm.localstack.cloud
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

## install crossplane
kubectl create namespace crossplane-system
helm install crossplane --namespace crossplane-system crossplane-stable/crossplane

namespace="crossplane-system"
label_selector="app=crossplane-rbac-manager"
timeout=90

# Wait for the resource to exist
echo "Waiting for crossplane rbac manager to be created..."
until kubectl get pods -n $namespace -l $label_selector --no-headers | grep -q "Running"; do
  echo -n "."
  sleep 1
done
echo

echo "Pod is created, waiting for it to be ready..."
# Now wait for the resource to be ready
kubectl wait --namespace $namespace \
  --for=condition=ready pod \
  --selector=$label_selector \
  --timeout=${timeout}s


kubectl create secret generic localstack-aws-token --namespace crossplane-system \
    --from-literal=credentials="$(
        echo -e '[default]\naws_access_key_id = localstack\naws_secret_access_key = localstacksecret'
    )"

# Wait for the provider and function CRDs to be ready
echo "Waiting for Crossplane to be ready..."
wait_for_cluster_resource crd providers.pkg.crossplane.io
wait_for_cluster_resource crd functions.pkg.crossplane.io

## install localstack
kubectl create namespace localstack-system
kubectl create secret generic localstack-auth-token --namespace localstack-system \
    --from-literal=token="$LOCALSTACK_AUTH_TOKEN"

# rebuild chart dependencies
helm dependency build charts/localstack
helm install localstack --namespace localstack-system \
  localstack-repo/localstack --values localstack-values.yaml

# Occasionally crossplane doesn't finish preparing before the providers are
# installed, so we'll sleep for a bit to give it time to (hopefully) finish
echo "Sleeping 30 seconds"
sleep 30

# install the providers and functions
kubectl apply -f providers.yaml
echo "Waiting for aws provider config CRD to be available..."
wait_for_cluster_resource crd providerconfigs.aws.upbound.io

# For some reason the provider config crd isn't always immediately available
sleep 10

# install the provider config
kubectl apply -f providerconfig.yaml
