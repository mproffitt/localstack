#!/bin/bash
set -o pipefail

DEFAULT_PROVIDERS=(
  "dynamodb"
  "ec2"
  "iam"
  "kms"
  "lambda"
  "s3"
  "sqs"
  "sns"
  "function-patch-and-transform"
  "function-go-templating"
)

if [ -n $LOCALSTACK_AUTH_TOKEN ]; then
  DEFAULT_PROVIDERS+=(
    "rds"
    "eks"
  )
fi

TOKEN_HEADER=""
if [ -n $GITHUB_TOKEN ]; then
  TOKEN_HEADER=""
fi

function get_latest_version () {
  local repo=$1
  if [ -z $GITHUB_TOKEN ]; then
    curl -sL -H "Accept: application/vnd.github+json" \
      https://api.github.com/repos/$repo/releases/latest \
      | yq .tag_name

    return
  fi
  curl -sL -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    https://api.github.com/repos/$repo/releases/latest \
    | yq .tag_name
}

DEFAULT_VERSION="$(get_latest_version crossplane-contrib/provider-upjet-aws)"

function  contains() {
  case $2 in *"$1"*) true;; *) false;; esac;
}

function beginswith () {
  case $2 in "$1"*) true;; *) false;; esac;
}

if [ $# -ne 0 ]; then
  for arg in "$@"; do
    if contains "provider" $arg; then
      arg=$(awk -F- '{print $NF}' <<< $arg)
    fi

    # if we start a provider with -, it means we want to remove it
    if beginswith "-" $arg; then
      arg="${arg:1}"
      DEFAULT_PROVIDERS=( "${DEFAULT_PROVIDERS[@]/$arg}" )
    else
      if ! grep -q $arg <<< "${DEFAULT_PROVIDERS[*]}"; then
        DEFAULT_PROVIDERS+=("$arg")
      fi
    fi
  done

  # Remove any empty elements
  for i in ${!DEFAULT_PROVIDERS[@]}; do [[ -z ${DEFAULT_PROVIDERS[i]} ]] && unset DEFAULT_PROVIDERS[i]; done
fi

echo "Creating localstack cluster with the following crossplane providers:"
echo "  ${DEFAULT_PROVIDERS[*]}"
echo

for provider in "${DEFAULT_PROVIDERS[@]}"; do
    if ! contains "function" $provider; then
      yq -ie "with(.spec.endpoint.services; select(all_c(. != \"$provider\")) | . += [\"$provider\"])" providerconfig.yaml
    fi
done
readonly timeout=90

function print_logs () {
  local name=$1
  while read line; do
    echo "  [$name] $line"
  done
}

##
# This function is used to wait for CRDs to be created in the cluster.
function wait_for_cluster_resource () {
  local name=$1
  local type=$2
  local resource=$3

  echo "  [$name] Waiting for $type $resource to be ready..."
  echo -n "  [$name] "
  until kubectl get $type --no-headers 2>&1 | grep -q "$name"; do
    echo -n "."
    sleep 1
  done
  echo
}

##
# This function is used to wait for a pod to be created. Once created, it
# will further wait until the API marks the pod as being ready.
function wait_for_pod_ready () {
  local name=$1
  local namespace=$2
  local label_selector=$3

  # Wait for the resource to exist
  echo "  [$name] waiting for pod to be created..."
  echo -n "  [$name] "
  until kubectl get pods -n $namespace -l $label_selector --no-headers | grep -q "Running"; do
    echo -n "."
    sleep 1
  done
  echo

  echo "  [$name] pod '$1/$2' is created, waiting for it to be ready..."
  kubectl wait --namespace $namespace \
    --for=condition=ready pod \
    --selector=$label_selector \
    --timeout=${timeout}s | print_logs $name
}

function header () {
  tput bold
  echo
  echo "========================================================================"
  echo "$1"
  echo "========================================================================"
  tput sgr0
}

##
# If kind is not installed, we cannot continue
if ! command -v kind &>/dev/null; then
  echo "kind not found, please install it"
  echo "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
  exit 1
fi

##
# Create the providers file.
# Provider family AWS is always created
cat <<EOT > providers-generated.yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-family-aws
spec:
  package: xpkg.upbound.io/upbound/provider-family-aws:${DEFAULT_VERSION}
EOT

##
# add the selected providers and functions to the providers file
#
for provider in "${DEFAULT_PROVIDERS[@]}"; do
  name="$(awk -F: '{print $1}' <<< $provider)"
  version="$(awk -F: '{print $2}' <<< $provider)"
  if contains "function" $name; then
    org=crossplane-contrib
    if contains "/" $name; then
      org="$(awk -F/ '{print $1}' <<< $name)"
      name="$(awk -F/ '{print $2}' <<< $name)"
    fi

    if [ -z "$version" ]; then
      version="$(get_latest_version $org/$name)"
    fi
    cat <<EOT >> providers-generated.yaml
---
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: $name
spec:
  package: xpkg.upbound.io/$org/$name:$version
EOT
  else
    if [ -z "$version" ]; then
      version="$DEFAULT_VERSION"
    fi
    cat <<EOT >> providers-generated.yaml
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-$name
spec:
  package: xpkg.upbound.io/upbound/provider-aws-$name:$version
EOT
  fi
done

if [ ! -d bin ]; then
  mkdir bin
fi
export PATH=$PATH:$(pwd)/bin

# Install additional tools kustomize and helm
{
  cd bin
  if ! command -v kustomize &>/dev/null; then
    echo "Downloading kustomize..."
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
  fi

  if ! command -v helm &>/dev/null; then
    echo "Downloading helm..."
    export HELM_INSTALL_DIR="$(pwd)"
    curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
  cd ..
}

# I think this is a bit dangerous as it encompases altering system files, not
# owned by the current user. Probably better left out for now and have the user
# explicitly add it manually if they need to.
#
# if ! grep -q "localhost.localstack.cloud" /etc/hosts; then
#   echo "Adding 'localhost.localstack.cloud' to /etc/hosts..."
#   echo "$(ip route get 1.2.3.4 | awk '{print $7}') localhost.localstack.cloud" | sudo tee -a /etc/hosts
# fi

header "Setting up kind cluster 'localstack'..."
{
  if kind get clusters | grep -q localstack; then
    echo "[kind] Deleting existing kind cluster 'localstack'..."
    kind delete cluster -n localstack 2>/dev/null
  fi
  kind create cluster -n localstack --config kind.yaml
  echo
}

## install nginx-ingress
name="nginx"
header "Installing nginx-ingress"
{
  kustomize build ./nginx | kubectl apply -f - | print_logs $name
  wait_for_pod_ready $name "ingress-nginx" "app.kubernetes.io/component=controller"
}

name="helm"
# install helm repos
header "Adding helm repos..."
{
  helm repo add crossplane-stable https://charts.crossplane.io/stable | print_logs $name
  helm repo add localstack-repo https://helm.localstack.cloud | print_logs $name
  helm repo update | print_logs $name
}

# install localstack
name="localstack"
header "Installing localstack..."
{
  kubectl create namespace localstack-system | print_logs $name
  yq -ie 'del(.extraEnvVars[] | select(.name == "LOCALSTACK_AUTH_TOKEN"))' localstack-values.yaml
  yq -ie '.image.repository = "localstack/localstack"' localstack-values.yaml

  if [ -n "$LOCALSTACK_AUTH_TOKEN" ]; then
    echo "  [localstack] Installing localstack-pro..."
    echo "  [localstack] Creating localstack-auth-token secret..."
    kubectl create secret generic localstack-auth-token --namespace localstack-system \
      --from-literal=token="$LOCALSTACK_AUTH_TOKEN" | print_logs $name

    # Edit the values file to use the pro image and add the auth token
    yq -ie '.image.repository = "localstack/localstack-pro"' localstack-values.yaml
    yq -ie '.extraEnvVars += [{"name": "LOCALSTACK_AUTH_TOKEN", "valueFrom": {"secretKeyRef": {"name": "localstack-auth-token", "key": "token"}}}]' localstack-values.yaml
  fi

  # rebuild chart dependencies
  helm install localstack --namespace localstack-system \
    localstack-repo/localstack --values localstack-values.yaml | print_logs $name
}

# install crossplane
name="crossplane"
header "Installing Crossplane..."
{
  kubectl create namespace crossplane-system | print_logs $name
  helm install crossplane --namespace crossplane-system crossplane-stable/crossplane | print_logs $name

  wait_for_pod_ready "crossplane" "crossplane-system" "app=crossplane"
  wait_for_pod_ready "crossplane-rbac-manager" "crossplane-system" "app=crossplane-rbac-manager"

  # create a dummy secret for the aws provider
  kubectl create secret generic localstack-aws-token --namespace crossplane-system \
    --from-literal=credentials="$(
        echo -e '[default]\naws_access_key_id = localstack\naws_secret_access_key = localstacksecret'
    )" | print_logs $name

  # Wait for the provider and function CRDs to be ready
  echo "  [$name] Waiting for Crossplane to be ready..."
  wait_for_cluster_resource $name crd providers.pkg.crossplane.io
  wait_for_cluster_resource $name crd functions.pkg.crossplane.io
}

# Occasionally crossplane doesn't finish preparing before the providers are
# installed, so we'll sleep for a bit to give it time to (hopefully) finish
echo
echo "Sleeping 30 seconds"
sleep 30

# install the providers and provider config
name="providers"
header "Installing Crossplane providers and functions..."
{
  # install the providers and functions
  kubectl apply -f providers-generated.yaml | print_logs $name
  wait_for_cluster_resource crossplane crd providerconfigs.aws.upbound.io

  # For some reason the provider config crd isn't always immediately available
  sleep 10

  # install the provider config
  kubectl apply -f providerconfig.yaml | print_logs $name
}
