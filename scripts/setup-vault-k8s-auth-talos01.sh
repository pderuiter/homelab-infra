#!/bin/bash
#
# Setup Vault Kubernetes Authentication for wbyc-k8s-talos01 cluster
#
# This creates a separate auth path in Vault for the Talos cluster,
# reusing the same policy and role name pattern as the main cluster.
#
# Prerequisites:
# - Vault CLI installed and configured (VAULT_ADDR, VAULT_TOKEN)
# - kubectl access to the talos01 cluster (KUBECONFIG)
#
# Usage: KUBECONFIG=~/.kube/wbyc-k8s-talos01 ./setup-vault-k8s-auth-talos01.sh
#

set -euo pipefail

# Configuration
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.2.170:8200}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"
K8S_HOST="https://192.168.2.20:6443"
AUTH_PATH="kubernetes-talos01"
ROLE_NAME="external-secrets"
POLICY_NAME="external-secrets-policy"
SA_NAME="vault-auth"
SA_NAMESPACE="external-secrets"

echo "=== Vault Kubernetes Auth Setup for talos01 ==="
echo "Vault Address: $VAULT_ADDR"
echo "Kubernetes API: $K8S_HOST"
echo "Auth Path: $AUTH_PATH"
echo ""

# Check if vault is accessible
echo "Checking Vault connectivity..."
if ! vault status > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to Vault at $VAULT_ADDR"
    echo "Please ensure VAULT_ADDR is set and you are authenticated"
    exit 1
fi
echo "Vault is accessible"
echo ""

# Step 1: Enable Kubernetes auth method at talos01-specific path
echo "Step 1: Enabling Kubernetes auth method at path: $AUTH_PATH..."
if vault auth list | grep -q "^${AUTH_PATH}/"; then
    echo "Kubernetes auth already enabled at path: $AUTH_PATH"
else
    vault auth enable -path="$AUTH_PATH" kubernetes
    echo "Kubernetes auth enabled at path: $AUTH_PATH"
fi
echo ""

# Step 2: Get Kubernetes CA certificate
echo "Step 2: Getting Kubernetes CA certificate..."
K8S_CA_CERT_FILE=$(mktemp)
kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d > "$K8S_CA_CERT_FILE"
echo "Retrieved Kubernetes CA certificate"
echo ""

# Cleanup function
cleanup() {
    rm -f "$K8S_CA_CERT_FILE"
}
trap cleanup EXIT

# Step 3: Ensure namespace and service account exist
echo "Step 3: Ensuring namespace and service account exist..."
kubectl create namespace "$SA_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount "$SA_NAME" -n "$SA_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
echo "Namespace and ServiceAccount ready"
echo ""

# Step 4: Create a long-lived token for the service account
echo "Step 4: Creating service account token secret..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SA_NAME}-token
  namespace: ${SA_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF

echo "Waiting for token to be populated..."
sleep 5

SA_TOKEN=$(kubectl get secret "${SA_NAME}-token" -n "$SA_NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)
if [ -z "$SA_TOKEN" ]; then
    echo "ERROR: Failed to get service account token"
    exit 1
fi
echo "Service account token retrieved"
echo ""

# Step 5: Configure Vault Kubernetes auth for talos01
echo "Step 5: Configuring Vault Kubernetes auth..."
K8S_ISSUER=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null | grep -o '"issuer":"[^"]*"' | cut -d'"' -f4 || echo "https://kubernetes.default.svc.cluster.local")
echo "Kubernetes JWT issuer: $K8S_ISSUER"

K8S_CA_CERT_CONTENT=$(cat "$K8S_CA_CERT_FILE")

vault write "auth/${AUTH_PATH}/config" \
    kubernetes_host="$K8S_HOST" \
    kubernetes_ca_cert="$K8S_CA_CERT_CONTENT" \
    token_reviewer_jwt="$SA_TOKEN" \
    issuer="$K8S_ISSUER" \
    disable_local_ca_jwt=true
echo "Vault Kubernetes auth configured for talos01"
echo ""

# Step 6: Create/update the policy (broader than dns-only for future use)
echo "Step 6: Creating Vault policy..."
vault policy write "$POLICY_NAME" - <<EOF
# Read access to all kubernetes secrets for External Secrets Operator
path "secret/data/dns" {
  capabilities = ["read"]
}

path "secret/metadata/dns" {
  capabilities = ["read", "list"]
}

path "secret/data/kubernetes/*" {
  capabilities = ["read"]
}

path "secret/metadata/kubernetes/*" {
  capabilities = ["read", "list"]
}
EOF
echo "Policy '$POLICY_NAME' created"
echo ""

# Step 7: Create the role
echo "Step 7: Creating Vault role..."
vault write "auth/${AUTH_PATH}/role/${ROLE_NAME}" \
    bound_service_account_names="$SA_NAME" \
    bound_service_account_namespaces="$SA_NAMESPACE" \
    policies="$POLICY_NAME" \
    ttl=1h
echo "Role '$ROLE_NAME' created"
echo ""

# Step 8: Create ClusterRoleBinding for auth-delegator (on talos01 cluster)
echo "Step 8: Creating ClusterRoleBinding for auth-delegator..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${SA_NAMESPACE}
EOF
echo "ClusterRoleBinding created"
echo ""

# Verification
echo "=== Verification ==="
echo ""
echo "Auth method config:"
vault read "auth/${AUTH_PATH}/config"
echo ""
echo "Role config:"
vault read "auth/${AUTH_PATH}/role/${ROLE_NAME}"
echo ""
echo "Policy:"
vault policy read "$POLICY_NAME"
echo ""

echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "1. Update ClusterSecretStore to use mountPath: '$AUTH_PATH'"
echo "2. Commit and push changes"
echo "3. Verify: kubectl get clustersecretstore vault-backend"
