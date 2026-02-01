#!/bin/bash
# Nexus Migration Script: Kubernetes to Docker
#
# Prerequisites:
# - kubectl access to the Kubernetes cluster
# - SSH access to the Docker host (hosting.bsdserver.lan)
# - This script should be run from a machine with access to both

set -e

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/wbyc-k8s-config}"
DOCKER_HOST="hosting.bsdserver.lan"
DOCKER_HOST_DATA_DIR="/opt/nexus-data"
BACKUP_FILE="/tmp/nexus-backup.tar.gz"

echo "=== Nexus Migration: Kubernetes → Docker ==="
echo ""
echo "Kubernetes config: $KUBECONFIG"
echo "Docker host: $DOCKER_HOST"
echo "Data directory: $DOCKER_HOST_DATA_DIR"
echo ""

# Step 1: Scale down Nexus in Kubernetes
echo "[1/7] Scaling down Nexus in Kubernetes..."
kubectl --kubeconfig="$KUBECONFIG" scale deployment nexus -n nexus --replicas=0
echo "Waiting for pod to terminate..."
kubectl --kubeconfig="$KUBECONFIG" wait --for=delete pod -l app=nexus -n nexus --timeout=120s 2>/dev/null || true
echo "✓ Nexus scaled down"

# Step 2: Create backup pod
echo ""
echo "[2/7] Creating backup pod to access Nexus data..."
kubectl --kubeconfig="$KUBECONFIG" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nexus-backup
  namespace: nexus
spec:
  containers:
  - name: backup
    image: alpine:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: nexus-data
      mountPath: /nexus-data
  volumes:
  - name: nexus-data
    persistentVolumeClaim:
      claimName: nexus-data
  restartPolicy: Never
EOF

echo "Waiting for backup pod to be ready..."
kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=Ready pod/nexus-backup -n nexus --timeout=120s
echo "✓ Backup pod ready"

# Step 3: Create tarball of Nexus data
echo ""
echo "[3/7] Creating backup tarball (this may take a while)..."
kubectl --kubeconfig="$KUBECONFIG" exec -n nexus nexus-backup -- \
  tar czf /tmp/nexus-backup.tar.gz -C /nexus-data .
echo "✓ Backup tarball created"

# Step 4: Copy tarball to local machine
echo ""
echo "[4/7] Copying backup to local machine..."
kubectl --kubeconfig="$KUBECONFIG" cp nexus/nexus-backup:/tmp/nexus-backup.tar.gz "$BACKUP_FILE"
BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "✓ Backup copied ($BACKUP_SIZE)"

# Step 5: Clean up backup pod
echo ""
echo "[5/7] Cleaning up backup pod..."
kubectl --kubeconfig="$KUBECONFIG" delete pod nexus-backup -n nexus
echo "✓ Backup pod deleted"

# Step 6: Transfer to Docker host and extract
echo ""
echo "[6/7] Transferring backup to Docker host..."
ssh "$DOCKER_HOST" "sudo mkdir -p $DOCKER_HOST_DATA_DIR && sudo chown 200:200 $DOCKER_HOST_DATA_DIR"
scp "$BACKUP_FILE" "$DOCKER_HOST:/tmp/nexus-backup.tar.gz"
ssh "$DOCKER_HOST" "sudo tar xzf /tmp/nexus-backup.tar.gz -C $DOCKER_HOST_DATA_DIR && sudo chown -R 200:200 $DOCKER_HOST_DATA_DIR && rm /tmp/nexus-backup.tar.gz"
echo "✓ Data extracted to $DOCKER_HOST:$DOCKER_HOST_DATA_DIR"

# Step 7: Update docker-compose to use host path and start
echo ""
echo "[7/7] Starting Nexus on Docker host..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Copy docker-compose to Docker host
scp "$SCRIPT_DIR/docker-compose.yml" "$DOCKER_HOST:/tmp/docker-compose-nexus.yml"

# Create directory and start container
ssh "$DOCKER_HOST" << 'ENDSSH'
mkdir -p /opt/nexus
mv /tmp/docker-compose-nexus.yml /opt/nexus/docker-compose.yml

# Update docker-compose to use bind mount instead of named volume
sed -i 's|nexus-data:/nexus-data|/opt/nexus-data:/nexus-data|g' /opt/nexus/docker-compose.yml
sed -i '/^volumes:/,/driver: local/d' /opt/nexus/docker-compose.yml

cd /opt/nexus
docker compose up -d
ENDSSH

echo ""
echo "Waiting for Nexus to start (this takes 2-3 minutes)..."
sleep 30

for i in {1..20}; do
  if ssh "$DOCKER_HOST" "curl -sf http://localhost:8081/service/rest/v1/status" > /dev/null 2>&1; then
    echo "✓ Nexus is healthy!"
    break
  fi
  echo "  Waiting... ($i/20)"
  sleep 10
done

# Cleanup local backup
rm -f "$BACKUP_FILE"

echo ""
echo "=== Migration Complete ==="
echo ""
echo "Nexus is now running on $DOCKER_HOST"
echo ""
echo "Next steps:"
echo "1. Verify Nexus at https://nexus.bsdserver.nl"
echo "2. Create DNS CNAME: nexus.bsdserver.nl → hosting.bsdserver.lan"
echo "3. Remove Nexus from Kubernetes GitOps repo:"
echo "   - Delete infrastructure/controllers/nexus/"
echo "   - Update infrastructure/controllers/kustomization.yaml"
echo "4. Delete Longhorn PVC to reclaim storage:"
echo "   kubectl --kubeconfig=$KUBECONFIG delete pvc nexus-data -n nexus"
echo "   kubectl --kubeconfig=$KUBECONFIG delete namespace nexus"
