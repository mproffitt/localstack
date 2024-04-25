# Localstack installation

This repo will install and configure localstack and crossplane inside a `kind`
cluster running locally on your machine.

If you have a professional license for localstack, it will install the pro version
otherwise the opensource version will be installed.

## Prerequisites

In order to use this repo, there are certain prerequisites that have to be met.

### Tools

You need the following tools installed to work with this repo.

- yq
- curl
- docker
- kind

The script also relies on both `helm` and `kustomize` however if these are not
discovered in your environment, the script will download them temporarily to
a bin folder at the current location `./`

### `/etc/hosts` file entry

To ensure communication, you need to add a hostfile entry for your primary
interface pointing to `localhost.localstack.cloud`

```nohighlight
192.168.1.2 localhost.localstack.cloud
```

### LOCALSTACK_AUTH_TOKEN

If you have a professional license, set your auth token into your environment

```bash
export LOCALSTACK_AUTH_TOKEN=<your-token>
```

### GITHUB_TOKEN

This script relies on the github api for discovering crossplane provider and
function versions. To prevent being rate limited by github, you may want to set
your github PAT into your environment

```bash
export GITHUB_TOKEN=<your-token>
```

## Execution

To run using the defaults:

```bash
./localstack-kind.sh
```

By default, the build script will install common AWS providers and composition
functions for crossplane to enable you to get started quickly.

### Providers

- dynamodb
- ec2
- iam
- kms
- lambda
- s3
- sqs
- sns

### Functions

- function-patch-and-transform
- function-go-templating

If you are running the professional version, the following providers will also
be installed:

- rds
- eks

Providers can be added to this set by passing them as args to the script.

Likewise, providers can be removed by adding the name prefixed with a `-`

```bash
./localstack-kind.sh kinesis cloudformation -ec2 -lambda
```

This installation will build a new kind cluster called `localstack` using the
configuration file [`kind.yaml`](./kind.yaml).

The kind installation mounts the docker socket file `/var/run/docker.sock` and
exposes ports 80, 443 and 4566 which `nginx` will bind to.

Once the cluster has started, nginx is installed with the following flags enabled

- `--enable-ssl-passthrough` - This hands off SSL to localstack so you're not
  having to worry about certiticates
- `--tcp-services-configmap=ingress-nginx/tcp-services` instructs NGINX to look
  for additional TCP services inside the `tcp-services` configmap

Localstack is installed using the values found inside `localstack-values.yaml`

It will also create a `ProviderConfig` with a dummy credential used to connect
to localstack. Localstack itself doesn't care about the values but simply requires
that "something" exists for them.
