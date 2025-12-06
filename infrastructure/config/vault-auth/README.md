# Vault Kubernetes Authentication Setup

This directory contains the Kubernetes resources for External Secrets Operator to authenticate with Vault.

## Prerequisites

Before Flux can deploy the ClusterSecretStore, you must configure Vault to accept Kubernetes authentication.

## Manual Vault Configuration

Run these commands on your Vault server or from a machine with Vault CLI access:

```bash
# Set Vault address (if not already set)
export VAULT_ADDR="https://192.168.2.170:8200"

# Authenticate to Vault (use your preferred method)
vault login

# Enable Kubernetes auth method (if not already enabled)
vault auth enable -path=kubernetes kubernetes

# Configure the Kubernetes auth method
# You'll need to get these values from your Kubernetes cluster:
#
# 1. Kubernetes API server CA certificate
# 2. Kubernetes API server URL
# 3. A JWT token from a ServiceAccount (the vault-auth SA created by this config)

# Get the Kubernetes CA certificate (run on a machine with kubectl access):
kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d > /tmp/k8s-ca.crt

# Get a long-lived token for the vault-auth service account
# First, create a token secret (after deploying the vault-auth SA):
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: external-secrets
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
EOF

# Wait for the token to be populated
sleep 5

# Get the token
REVIEWER_TOKEN=$(kubectl get secret vault-auth-token -n external-secrets -o jsonpath='{.data.token}' | base64 -d)

# Configure Vault's Kubernetes auth
vault write auth/kubernetes/config \
    kubernetes_host="https://kube-api.bsdserver.nl:6443" \
    kubernetes_ca_cert=@/tmp/k8s-ca.crt \
    token_reviewer_jwt="$REVIEWER_TOKEN"

# Create a policy that allows reading DNS secrets
vault policy write external-secrets-dns - <<EOF
# Read-only access to DNS secrets
path "secret/data/dns" {
  capabilities = ["read"]
}

path "secret/metadata/dns" {
  capabilities = ["read", "list"]
}
EOF

# Create a role that binds the policy to the Kubernetes ServiceAccount
vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=vault-auth \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets-dns \
    ttl=1h
```

## Verification

After configuring Vault, verify the setup:

```bash
# Check if the auth method is configured
vault read auth/kubernetes/config

# Check the role
vault read auth/kubernetes/role/external-secrets

# Check the policy
vault policy read external-secrets-dns
```

## Troubleshooting

### "permission denied" errors
- Ensure the `external-secrets-dns` policy has the correct path
- Vault KV v2 uses `secret/data/<path>` for reading data
- Verify the role is bound to the correct ServiceAccount and namespace

### "invalid token" errors
- The ServiceAccount token may have expired
- Recreate the token secret and update the Vault config
- Ensure the Kubernetes CA certificate is correct

### TLS errors
- The CA certificate in `vault-ca-configmap.yaml` must match Vault's TLS certificate
- Verify with: `openssl s_client -connect 192.168.2.170:8200 -showcerts`

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                          │
│  ┌─────────────────┐    ┌─────────────────────────────────────┐ │
│  │ External Secrets│    │        external-secrets namespace   │ │
│  │    Operator     │───▶│  vault-auth ServiceAccount          │ │
│  └────────┬────────┘    │  (with system:auth-delegator role)  │ │
│           │             └─────────────────────────────────────┘ │
│           │                                                      │
│           │ Uses SA token for                                    │
│           │ Kubernetes auth                                      │
│           ▼                                                      │
└───────────┼─────────────────────────────────────────────────────┘
            │
            │ HTTPS (TLS verified with CA cert)
            │
            ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Vault (192.168.2.170:8200)                   │
│  ┌─────────────────┐    ┌─────────────────────────────────────┐ │
│  │ Kubernetes Auth │    │   Policy: external-secrets-dns      │ │
│  │   (validates    │───▶│   - read secret/data/dns            │ │
│  │    SA tokens)   │    │                                     │ │
│  └─────────────────┘    └─────────────────────────────────────┘ │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                   KV v2: secret/dns                         │ │
│  │   - transip_private_key                                     │ │
│  │   - transip_login                                           │ │
│  │   - key_name (TSIG)                                         │ │
│  │   - key_secret (TSIG)                                       │ │
│  │   - key_algorithm                                           │ │
│  │   - dns_server                                              │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```
