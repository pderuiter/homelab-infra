# CloudNative-PG Deployment Procedure

Complete procedure for deploying a highly-available PostgreSQL cluster using CloudNative-PG on Kubernetes with Flux GitOps.

## Prerequisites

- Kubernetes cluster with Flux GitOps configured
- Longhorn storage provisioner installed
- External-Secrets operator with Vault ClusterSecretStore (`vault-backend`)
- MinIO deployed for backup storage
- Prometheus/Grafana observability stack (for monitoring)
- Sufficient storage capacity (~25GB per PostgreSQL instance: 20GB data + 5GB WAL)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PostgreSQL Cluster                          │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   Primary    │  │   Replica 1  │  │   Replica 2  │              │
│  │ (postgres-1) │  │ (postgres-2) │  │ (postgres-3) │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
│         │                 │                 │                       │
│         ▼                 ▼                 ▼                       │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Async Streaming Replication               │   │
│  └─────────────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────┐       ┌─────────────────────┐             │
│  │   PgBouncer (RW)    │       │   PgBouncer (RO)    │             │
│  │   (2 instances)     │       │   (2 instances)     │             │
│  └─────────────────────┘       └─────────────────────┘             │
├─────────────────────────────────────────────────────────────────────┤
│                           Services                                  │
│  • postgres-cluster-pooler-rw:5432 (Writes via pooler)             │
│  • postgres-cluster-pooler-ro:5432 (Reads via pooler)              │
│  • postgres-cluster-rw:5432 (Direct primary)                       │
│  • postgres-cluster-ro:5432 (Direct replicas)                      │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                         ┌──────────────┐
                         │    MinIO     │
                         │  (Backups)   │
                         └──────────────┘
```

## Step 1: Create Vault Secrets

Generate and store credentials in Vault before deploying any manifests.

```bash
# Set Vault address
export VAULT_ADDR=https://your-vault-address:8200
export VAULT_SKIP_VERIFY=1  # Only for self-signed certs

# Generate secure passwords
POSTGRES_SUPERUSER_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
POSTGRES_APP_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
MINIO_ACCESS_KEY=$(openssl rand -base64 16 | tr -d '/+=' | head -c 20)
MINIO_SECRET_KEY=$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)

# Store PostgreSQL superuser credentials
vault kv put secret/kubernetes/postgres/superuser \
  username=postgres \
  password="$POSTGRES_SUPERUSER_PASS"

# Store PostgreSQL app user credentials
vault kv put secret/kubernetes/postgres/app \
  username=app \
  password="$POSTGRES_APP_PASS"

# Store MinIO backup credentials (for CNPG backup user)
vault kv put secret/kubernetes/postgres/minio-backup \
  access-key-id="$MINIO_ACCESS_KEY" \
  secret-access-key="$MINIO_SECRET_KEY"

# Verify secrets were created
vault kv get secret/kubernetes/postgres/superuser
vault kv get secret/kubernetes/postgres/app
vault kv get secret/kubernetes/postgres/minio-backup
```

**Note**: MinIO root credentials should already exist at `secret/kubernetes/minio` from your MinIO deployment.

## Step 2: Create Longhorn Database StorageClass

Create a dedicated StorageClass with single replica for PostgreSQL. CNPG handles HA at the database level, so we don't need Longhorn replication.

**File: `infrastructure/controllers/longhorn/storageclass-database.yaml`**

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-database
  labels:
    app.kubernetes.io/name: longhorn
    app.kubernetes.io/component: storageclass
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "30"
  fromBackup: ""
  fsType: "ext4"
  dataLocality: "best-effort"
  disableRevisionCounter: "true"
  dataEngine: "v1"
  unmapMarkSnapChainRemoved: "ignored"
```

Add to `infrastructure/controllers/longhorn/kustomization.yaml`:

```yaml
resources:
  # ... existing resources ...
  - storageclass-database.yaml
```

## Step 3: Deploy CloudNative-PG Operator

Create the CNPG operator directory and files:

**Directory: `infrastructure/controllers/cloudnative-pg/`**

**File: `namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
  labels:
    app.kubernetes.io/name: cloudnative-pg
```

**File: `helmrepository.yaml`**
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: cloudnative-pg
  namespace: cnpg-system
spec:
  interval: 24h
  url: https://cloudnative-pg.github.io/charts
```

**File: `helmrelease.yaml`**
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cloudnative-pg
  namespace: cnpg-system
spec:
  interval: 30m
  chart:
    spec:
      chart: cloudnative-pg
      version: "0.x"
      sourceRef:
        kind: HelmRepository
        name: cloudnative-pg
        namespace: cnpg-system
      interval: 12h
  install:
    crds: CreateReplace
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    remediation:
      retries: 3
  values:
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
      limits:
        cpu: 500m
        memory: 256Mi
    monitoring:
      podMonitorEnabled: true
      podMonitorAdditionalLabels:
        release: kube-prometheus-stack
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-role.kubernetes.io/control-plane
                  operator: DoesNotExist
```

**File: `kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
```

Add to `infrastructure/controllers/kustomization.yaml`:
```yaml
resources:
  # ... existing resources ...
  - cloudnative-pg
```

## Step 4: Create Database Configuration

Create the databases directory and all configuration files:

**Directory: `infrastructure/config/databases/`**

### 4.1 Namespace

**File: `namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: databases
  labels:
    app.kubernetes.io/name: databases
```

### 4.2 External Secrets

**File: `externalsecrets.yaml`**
```yaml
---
# PostgreSQL superuser credentials
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-superuser-credentials
  namespace: databases
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: postgres-superuser-credentials
    creationPolicy: Owner
    template:
      type: kubernetes.io/basic-auth
  data:
    - secretKey: username
      remoteRef:
        key: secret/data/kubernetes/postgres/superuser
        property: username
    - secretKey: password
      remoteRef:
        key: secret/data/kubernetes/postgres/superuser
        property: password
---
# PostgreSQL app user credentials
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-app-credentials
  namespace: databases
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: postgres-app-credentials
    creationPolicy: Owner
    template:
      type: kubernetes.io/basic-auth
  data:
    - secretKey: username
      remoteRef:
        key: secret/data/kubernetes/postgres/app
        property: username
    - secretKey: password
      remoteRef:
        key: secret/data/kubernetes/postgres/app
        property: password
---
# MinIO backup credentials (for CNPG backup user)
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: cnpg-minio-credentials
  namespace: databases
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: cnpg-minio-credentials
    creationPolicy: Owner
  data:
    - secretKey: ACCESS_KEY_ID
      remoteRef:
        key: secret/data/kubernetes/postgres/minio-backup
        property: access-key-id
    - secretKey: SECRET_ACCESS_KEY
      remoteRef:
        key: secret/data/kubernetes/postgres/minio-backup
        property: secret-access-key
---
# MinIO root credentials (for initial setup job)
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: minio-credentials
  namespace: databases
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: minio-credentials
    creationPolicy: Owner
  data:
    - secretKey: rootUser
      remoteRef:
        key: secret/data/kubernetes/minio
        property: root-user
    - secretKey: rootPassword
      remoteRef:
        key: secret/data/kubernetes/minio
        property: root-password
```

### 4.3 MinIO Setup Job

**File: `minio-setup-job.yaml`**
```yaml
---
# One-time Job to create MinIO bucket and user for CNPG backups
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-cnpg-setup
  namespace: databases
  labels:
    app.kubernetes.io/name: minio-setup
    app.kubernetes.io/component: backup-setup
  annotations:
    kustomize.toolkit.fluxcd.io/force: "enabled"
spec:
  ttlSecondsAfterFinished: 86400
  backoffLimit: 3
  template:
    metadata:
      labels:
        app.kubernetes.io/name: minio-setup
        app.kubernetes.io/component: backup-setup
    spec:
      restartPolicy: OnFailure
      serviceAccountName: default
      containers:
        - name: minio-setup
          image: minio/mc:latest
          command:
            - /bin/sh
            - -c
            - |
              set -e
              echo "Setting up MinIO for CNPG backups..."

              MINIO_ROOT_USER=$(cat /minio-creds/rootUser)
              MINIO_ROOT_PASSWORD=$(cat /minio-creds/rootPassword)
              CNPG_ACCESS_KEY=$(cat /cnpg-creds/ACCESS_KEY_ID)
              CNPG_SECRET_KEY=$(cat /cnpg-creds/SECRET_ACCESS_KEY)

              mc alias set myminio http://minio.minio.svc.cluster.local:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"

              echo "Creating bucket cnpg-backups..."
              mc mb myminio/cnpg-backups --ignore-existing

              echo "Creating user for CNPG..."
              mc admin user add myminio "$CNPG_ACCESS_KEY" "$CNPG_SECRET_KEY" 2>/dev/null || echo "User already exists"

              echo "Attaching readwrite policy..."
              mc admin policy attach myminio readwrite --user "$CNPG_ACCESS_KEY" 2>/dev/null || \
                mc admin policy set myminio readwrite user="$CNPG_ACCESS_KEY" 2>/dev/null || \
                echo "Policy already attached"

              echo "Enabling bucket versioning..."
              mc version enable myminio/cnpg-backups || echo "Versioning already enabled"

              echo "Setting lifecycle policy..."
              cat > /tmp/lifecycle.json << 'EOF'
              {
                "Rules": [
                  {
                    "ID": "cleanup-old-versions",
                    "Status": "Enabled",
                    "NoncurrentVersionExpiration": {
                      "NoncurrentDays": 30
                    }
                  }
                ]
              }
              EOF
              mc ilm import myminio/cnpg-backups < /tmp/lifecycle.json || echo "Lifecycle policy already set"

              echo "MinIO CNPG setup complete!"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          volumeMounts:
            - name: minio-credentials
              mountPath: /minio-creds
              readOnly: true
            - name: cnpg-credentials
              mountPath: /cnpg-creds
              readOnly: true
      volumes:
        - name: minio-credentials
          secret:
            secretName: minio-credentials
        - name: cnpg-credentials
          secret:
            secretName: cnpg-minio-credentials
```

### 4.4 PostgreSQL Cluster

**File: `postgres-cluster.yaml`**
```yaml
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-cluster
  namespace: databases
  labels:
    app.kubernetes.io/name: postgres
    app.kubernetes.io/component: database
spec:
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  instances: 3
  minSyncReplicas: 0
  maxSyncReplicas: 0
  primaryUpdateStrategy: unsupervised
  primaryUpdateMethod: switchover

  postgresql:
    parameters:
      shared_buffers: "256MB"
      effective_cache_size: "768MB"
      maintenance_work_mem: "64MB"
      work_mem: "16MB"
      wal_buffers: "16MB"
      min_wal_size: "256MB"
      max_wal_size: "1GB"
      checkpoint_completion_target: "0.9"
      checkpoint_timeout: "15min"
      random_page_cost: "1.1"
      effective_io_concurrency: "200"
      max_connections: "200"
      log_statement: "ddl"
      log_min_duration_statement: "1000"
      log_checkpoints: "on"
      log_lock_waits: "on"
      log_temp_files: "0"
      track_activities: "on"
      track_counts: "on"
      track_io_timing: "on"

    pg_hba:
      - host all all 10.0.0.0/8 scram-sha-256
      - host all all 172.16.0.0/12 scram-sha-256
      - host all all 192.168.0.0/16 scram-sha-256

  # Disable auto-created PodMonitor - we create a custom one with the required labels
  monitoring:
    enablePodMonitor: false

  superuserSecret:
    name: postgres-superuser-credentials

  bootstrap:
    initdb:
      database: app
      owner: app
      secret:
        name: postgres-app-credentials
      postInitSQL:
        - CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

  storage:
    storageClass: longhorn-database
    size: 20Gi
    pvcTemplate:
      accessModes:
        - ReadWriteOnce

  walStorage:
    storageClass: longhorn-database
    size: 5Gi
    pvcTemplate:
      accessModes:
        - ReadWriteOnce

  backup:
    barmanObjectStore:
      destinationPath: s3://cnpg-backups/postgres-cluster
      endpointURL: http://minio.minio.svc.cluster.local:9000
      s3Credentials:
        accessKeyId:
          name: cnpg-minio-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: cnpg-minio-credentials
          key: SECRET_ACCESS_KEY
      wal:
        compression: gzip
        maxParallel: 2
      data:
        compression: gzip
        jobs: 2
    retentionPolicy: "14d"

  resources:
    requests:
      cpu: 250m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 2Gi

  affinity:
    enablePodAntiAffinity: true
    topologyKey: kubernetes.io/hostname
    podAntiAffinityType: preferred
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist

  startDelay: 30
  stopDelay: 30
  failoverDelay: 0
  switchoverDelay: 30
```

### 4.5 Scheduled Backups

**File: `scheduled-backup.yaml`**
```yaml
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: postgres-cluster-daily-backup
  namespace: databases
  labels:
    app.kubernetes.io/name: postgres
    app.kubernetes.io/component: backup
spec:
  schedule: "0 2 * * *"
  suspend: false
  backupOwnerReference: self
  cluster:
    name: postgres-cluster
  immediate: true
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: postgres-cluster-weekly-backup
  namespace: databases
  labels:
    app.kubernetes.io/name: postgres
    app.kubernetes.io/component: backup
spec:
  schedule: "0 3 * * 7"
  suspend: false
  backupOwnerReference: self
  cluster:
    name: postgres-cluster
```

**Note**: CNPG uses 1-7 for day-of-week (1=Monday, 7=Sunday), not 0-6.

### 4.6 Maintenance CronJobs

**File: `maintenance-cronjob.yaml`**

See the full file in the repository. It includes:
- `postgres-vacuum-analyze`: Daily at 4AM UTC
- `postgres-reindex`: Weekly Sunday at 5AM UTC
- `postgres-stats-reset`: Monthly 1st at 6AM UTC

### 4.7 PgBouncer Connection Poolers

**File: `pooler.yaml`**

See the full file in the repository. It includes:
- `postgres-cluster-pooler-rw`: Read-write pooler (2 instances)
- `postgres-cluster-pooler-ro`: Read-only pooler (2 instances)

### 4.8 Custom PodMonitor for Prometheus

**File: `podmonitor.yaml`**

CNPG's auto-created PodMonitor doesn't include labels required for Prometheus discovery (e.g., `release: kube-prometheus-stack`). Since CNPG API doesn't support custom labels on PodMonitors, we disable the auto-created one and create a custom PodMonitor.

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: postgres-cluster
  namespace: databases
  labels:
    app.kubernetes.io/name: postgres
    app.kubernetes.io/component: database
    # Required for Prometheus to discover this PodMonitor
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - databases
  selector:
    matchLabels:
      cnpg.io/cluster: postgres-cluster
      cnpg.io/podRole: instance
  podMetricsEndpoints:
    - port: metrics
      metricRelabelings:
        - sourceLabels: [cluster]
          targetLabel: cnpg_cluster
          action: replace
---
# PodMonitor for PgBouncer poolers
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: postgres-cluster-pooler
  namespace: databases
  labels:
    app.kubernetes.io/name: postgres
    app.kubernetes.io/component: pooler
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - databases
  selector:
    matchLabels:
      cnpg.io/cluster: postgres-cluster
      cnpg.io/poolerName: postgres-cluster-pooler-rw
  podMetricsEndpoints:
    - port: metrics
```

### 4.9 Prometheus Alert Rules

**File: `prometheusrules.yaml`**

See the full file in the repository. Includes alerts for:
- Cluster health (no primary, degraded, not healthy)
- Replication lag
- Storage (nearly full, critical, WAL high)
- Connections (high count, pool exhaustion, long-running queries)
- Backups (failed, stale, WAL archiving issues)
- Performance (high latency, low cache hit ratio, deadlocks)

### 4.10 Grafana Dashboard

**File: `grafana-dashboard.yaml`**

ConfigMap containing the Grafana dashboard JSON for CloudNative-PG monitoring.

### 4.11 Kustomization

**File: `kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - externalsecrets.yaml
  - minio-setup-job.yaml
  - postgres-cluster.yaml
  - scheduled-backup.yaml
  - maintenance-cronjob.yaml
  - pooler.yaml
  - podmonitor.yaml
  - prometheusrules.yaml
  - grafana-dashboard.yaml
```

## Step 5: Enable Database Deployment

Add databases to `infrastructure/config/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - vault-auth
  - metallb
  - cert-manager
  - external-dns
  - databases  # Add this line
```

## Step 6: Commit and Deploy

```bash
# Add all files
git add infrastructure/controllers/cloudnative-pg/
git add infrastructure/controllers/longhorn/storageclass-database.yaml
git add infrastructure/config/databases/

# Commit
git commit -m "Add CloudNative-PG PostgreSQL cluster deployment"

# Push
git push

# Reconcile Flux
flux reconcile source git flux-system
flux reconcile kustomization infrastructure-controllers
flux reconcile kustomization infrastructure-config
```

## Step 7: Verify Deployment

```bash
# Check CNPG operator
kubectl get pods -n cnpg-system

# Check ExternalSecrets sync
kubectl get externalsecrets -n databases

# Check PostgreSQL cluster
kubectl get cluster -n databases

# Watch pods come up
kubectl get pods -n databases -w

# Check cluster health (should show 3/3 READY)
kubectl get cluster postgres-cluster -n databases
```

## Step 8: Verify Backups

```bash
# Check scheduled backups
kubectl get scheduledbackup -n databases

# Check backup status
kubectl get backups -n databases

# Verify MinIO bucket has data
kubectl exec -n minio deploy/minio -- mc ls local/cnpg-backups/
```

## Troubleshooting

### Grafana Dashboard Shows "No Data"

This is typically caused by Prometheus not scraping the PostgreSQL metrics. Follow these steps:

**1. Verify PodMonitors exist:**
```bash
kubectl get podmonitor -n databases
# Should show: postgres-cluster, postgres-cluster-pooler
```

**2. Check PodMonitor has correct label for Prometheus discovery:**
```bash
kubectl get podmonitor postgres-cluster -n databases -o jsonpath='{.metadata.labels}' | jq .
# Must include: "release": "kube-prometheus-stack"
```

**3. Verify Prometheus is scraping targets:**
```bash
kubectl exec -n observability prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null | \
  jq -r '.data.activeTargets[] | select(.scrapePool | contains("databases")) | "\(.labels.pod) - \(.health)"'
# Should show all postgres-cluster-* pods as "up"
```

**4. If PodMonitor is missing, re-apply it:**
```bash
kubectl apply -f infrastructure/config/databases/podmonitor.yaml
flux reconcile kustomization infrastructure-config --with-source
```

**5. Verify metrics are being collected:**
```bash
kubectl exec -n observability prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=cnpg_collector_up' 2>/dev/null | jq '.data.result'
# Should show value "1" for each PostgreSQL instance
```

### PodMonitor Not Discovered by Prometheus

**Cause**: Prometheus Operator uses label selectors to discover PodMonitors. If your PodMonitor doesn't have the required labels, it won't be scraped.

**Check Prometheus podMonitorSelector:**
```bash
kubectl get prometheus -n observability -o jsonpath='{.items[0].spec.podMonitorSelector}'
# Typically: {"matchLabels":{"release":"kube-prometheus-stack"}}
```

**Solution**: The CNPG operator's auto-created PodMonitor doesn't include custom labels. We disable it and create our own:

1. In `postgres-cluster.yaml`, set:
   ```yaml
   monitoring:
     enablePodMonitor: false
   ```

2. Create custom `podmonitor.yaml` with required labels:
   ```yaml
   metadata:
     labels:
       release: kube-prometheus-stack  # Required!
   ```

### Grafana Dashboard Shows "Datasource Prometheus was not found"

**Cause**: The dashboard JSON uses a datasource variable `${DS_PROMETHEUS}` that doesn't resolve.

**Solution**: Replace datasource references with the actual datasource name:
```bash
# Check your Grafana datasource name
kubectl get configmap -n observability -l grafana_datasource=1 -o yaml | grep -A5 "name:"

# If using the official CNPG dashboard, fix datasource references:
# Replace all "${DS_PROMETHEUS}" with "Prometheus" (or your datasource name)
```

### PodMonitor Disappears After Flux Reconciliation

**Symptoms**: Metrics stop flowing after Flux reconciles, PodMonitor is missing.

**Cause**: Flux may have issues applying multi-document YAML files, or there's a race condition.

**Diagnosis:**
```bash
# Check if PodMonitor exists
kubectl get podmonitor -n databases

# Check Flux kustomization status
flux get kustomization infrastructure-config

# Check Flux events
kubectl get events -n flux-system --sort-by='.lastTimestamp' | tail -20
```

**Solution:**
```bash
# Re-apply the PodMonitor manually
kubectl apply -f infrastructure/config/databases/podmonitor.yaml

# Force Flux to reconcile
flux reconcile kustomization infrastructure-config --with-source

# Verify both PodMonitors are created
kubectl get podmonitor -n databases
# Should show: postgres-cluster AND postgres-cluster-pooler
```

### Verifying End-to-End Monitoring

Complete verification checklist:
```bash
# 1. PostgreSQL pods are exposing metrics
kubectl exec -n databases postgres-cluster-1 -- curl -s localhost:9187/metrics | head -5

# 2. PodMonitors exist with correct labels
kubectl get podmonitor -n databases -o custom-columns=NAME:.metadata.name,RELEASE:.metadata.labels.release

# 3. Prometheus has discovered targets
kubectl exec -n observability prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null | \
  jq '.data.activeTargets | length'

# 4. Metrics are queryable
kubectl exec -n observability prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=cnpg_pg_database_size_bytes' 2>/dev/null | \
  jq '.data.result | length'

# 5. Grafana dashboard ConfigMap exists
kubectl get configmap -n databases -l grafana_dashboard=1
```

### Longhorn Storage Issues

If volumes are stuck in "faulted" state, check Longhorn node schedulability:

```bash
# Check node disk status
kubectl -n longhorn-system get nodes.longhorn.io

# If disks show "DiskPressure", reduce reserved percentage:
kubectl -n longhorn-system patch settings.longhorn.io storage-minimal-available-percentage \
  --type='merge' -p '{"value": "10"}'

# Or update per-node disk reserved space (15GB example):
kubectl -n longhorn-system patch nodes.longhorn.io <node-name> \
  --type='json' -p='[{"op": "replace", "path": "/spec/disks/<disk-id>/storageReserved", "value": 15739487846}]'
```

### Cluster Not Starting

```bash
# Check cluster status
kubectl describe cluster postgres-cluster -n databases

# Check operator logs
kubectl logs -n cnpg-system deploy/cloudnative-pg

# Check pod events
kubectl describe pod -n databases -l cnpg.io/cluster=postgres-cluster
```

### ExternalSecrets Not Syncing

```bash
# Check ExternalSecret status
kubectl get externalsecrets -n databases -o wide

# Verify ClusterSecretStore
kubectl get clustersecretstore vault-backend

# Check secret content (keys only)
kubectl get secret postgres-superuser-credentials -n databases -o jsonpath='{.data}' | jq 'keys'
```

## Connection Information

### Application Connection Strings

```bash
# Pooled connections (recommended)
# Read-Write: postgres://app:<password>@postgres-cluster-pooler-rw.databases:5432/app
# Read-Only:  postgres://app:<password>@postgres-cluster-pooler-ro.databases:5432/app

# Direct connections (for admin tasks)
# Primary:    postgres://postgres:<password>@postgres-cluster-rw.databases:5432/postgres
# Replicas:   postgres://postgres:<password>@postgres-cluster-ro.databases:5432/postgres
```

### Retrieving Credentials

```bash
# Get app user password
kubectl get secret postgres-app-credentials -n databases \
  -o jsonpath='{.data.password}' | base64 -d

# Get superuser password
kubectl get secret postgres-superuser-credentials -n databases \
  -o jsonpath='{.data.password}' | base64 -d
```

## Maintenance Operations

### Manual Backup

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: manual-backup-$(date +%Y%m%d-%H%M%S)
  namespace: databases
spec:
  cluster:
    name: postgres-cluster
EOF
```

### Switchover (Promote Replica)

```bash
kubectl cnpg promote postgres-cluster <replica-pod-name> -n databases
```

### Scale Instances

Edit `postgres-cluster.yaml` and change `instances: 3` to desired count, then:

```bash
git commit -am "Scale PostgreSQL to N instances"
git push
flux reconcile kustomization infrastructure-config
```

## Resource Requirements Summary

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit | Storage |
|-----------|-------------|-----------|----------------|--------------|---------|
| PostgreSQL (x3) | 250m | 2000m | 1Gi | 2Gi | 20Gi + 5Gi WAL |
| PgBouncer RW (x2) | 100m | 500m | 128Mi | 256Mi | - |
| PgBouncer RO (x2) | 100m | 500m | 128Mi | 256Mi | - |
| CNPG Operator | 100m | 500m | 100Mi | 256Mi | - |

**Total Storage**: ~75GB (3 instances x 25GB each)
