# Localstack installation

This repo will install and configure localstack and crossplane inside a `kind`
cluster running locally on your machine. It will then expose ports 80, 443 and 4566
outside of the cluster so you can access localstack services using the AWS CLI
and view your resources in `app.localstack.cloud`

> **Note**
>
> This setup assumes you are using a localstack professional license.
>
> If you do not have a professional license and are just using this for personal
> educative purposes, I recommend you sign up for the hobby license which is free.
>
> If you just want to use the opensource version, you will need to edit the
> install script and localstack-values.yaml file to remote the pro bindings.

## Prerequisites

In order to use this repo, there are certain prerequisites that have to be met.

### Tools

You need the following tools installed to work with this repo.

- kustomize
- helm
- docker
- kind

### `/etc/hosts` file entry

To ensure communication, you need to add a hostfile entry for your primary
interface pointing to `localhost.localstack.cloud`

```bash
echo "$(ip route get 1.2.3.4 | awk '{print $7}') localhost.localstack.cloud" | sudo tee -a /etc/hosts
```

### LOCALSTACK_AUTH_TOKEN

Set your auth token into your environment

```bash
export LOCALSTACK_AUTH_TOKEN=<your-token>
```

## Install

```bash
./install.sh
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

Additonally to this, port 4566 is added to the list of container ports and also
to the nginx service so it can be exposed outside the cluster.

Localstack is installed using the values found inside `localstack-values.yaml`

> **Note**
>
> Currently the helm chart for `localstack` is forked into this repo. This is
> because the upstream chart does not currently support `ingressClass` as a
> available option, instead relying on the deprecated annotation to set the
> ingress class.
>
> Once this has been fixed, I will be removing the chart from this repo and
> instead relying entirely on the upstream chart.

Crossplane is installed into kind using default values. The installation script
will also create the following providers and functions

- upbound/provider-family-aws
- upbound/provider-aws-ec2
- upbound/provider-aws-kms
- upbound/provider-aws-rds
- crossplane-contrib/function-patch-and-transform
- crossplane-contrib/function-go-templating

It will also create a `ProviderConfig` with a dummy credential used to connect
to localstack. Localstack itself doesn't care about the values but simply requires
that "something" exists for them.
