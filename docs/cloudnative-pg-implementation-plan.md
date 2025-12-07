# CloudNative-PG Implementation Plan

**Date:** 2025-12-07
**Status:** Planning Phase

---

## Table of Contents
1. [Storage Strategy Discussion](#1-storage-strategy-discussion)
2. [Implementation Phases](#2-implementation-phases)
3. [Phase 1: Operator Deployment](#3-phase-1-operator-deployment)
4. [Phase 2: Storage Configuration](#4-phase-2-storage-configuration)
5. [Phase 3: PostgreSQL Cluster](#5-phase-3-postgresql-cluster)
6. [Phase 4: Backup Configuration](#6-phase-4-backup-configuration)
7. [Phase 5: Scheduled Maintenance](#7-phase-5-scheduled-maintenance)
8. [Phase 6: Monitoring & Alerting](#8-phase-6-monitoring--alerting)
9. [Phase 7: Connection Pooling](#9-phase-7-connection-pooling)
10. [Testing & Validation](#10-testing--validation)

---

## 1. Storage Strategy Discussion

### Current Situation
```
Longhorn StorageClass: numberOfReplicas: "2"
Worker Nodes: 3
```

### The Problem: Write Amplification

With your current setup, if you deploy CNPG with 3 PostgreSQL instances:
```
3 PostgreSQL instances × 2 Longhorn replicas = 6 copies of data
```

This causes:
- **6x write amplification** - every write goes to 6 disks
- **Wasted storage** - 6x the actual data size
- **Increased latency** - more replicas = more sync overhead
- **No additional safety** - CNPG already provides HA at application level

### CloudNative-PG Recommendation

From the official documentation:
> "For solutions like Ceph and Longhorn, reduce volume replicas to one at the storage level,
> leveraging CloudNativePG's built-in cluster resiliency instead."

### Options

#### Option A: Dedicated StorageClass for Databases (Recommended)
Create a new StorageClass with 1 replica specifically for CNPG.

**Pros:**
- No impact on existing workloads
- Optimal performance for databases
- Clear separation of concerns
- Other apps keep their 2 replicas

**Cons:**
- Two StorageClasses to manage
- Need to explicitly specify for database PVCs

#### Option B: Modify Default StorageClass to 1 Replica
Change the default Longhorn setting to 1 replica.

**Pros:**
- Simpler (one StorageClass)
- Better performance for all workloads

**Cons:**
- **Breaks HA for non-replicated apps** (Grafana, MinIO, etc.)
- Existing PVCs won't automatically change
- Risk if apps aren't designed for single-replica storage

#### Option C: Keep 2 Replicas (Not Recommended)
Accept the write amplification.

**Pros:**
- No changes needed
- Extra redundancy (arguably unnecessary)

**Cons:**
- 6x write amplification
- Wasted storage and IOPS
- Against best practices

### Decision Required

**Recommendation: Option A - Dedicated StorageClass**

This creates `longhorn-database` StorageClass with:
- `numberOfReplicas: "1"` - single storage replica
- `dataLocality: "best-effort"` - prefer local storage
- Other settings inherited from default

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-database
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
```

**Data Safety with 1 Replica:**
- CNPG maintains 3 PostgreSQL instances with streaming replication
- WAL archiving to MinIO provides point-in-time recovery
- Scheduled backups provide additional safety net
- If a storage node fails, CNPG promotes a replica (no data loss)

---

## 2. Implementation Phases

| Phase | Component | Duration | Dependencies |
|-------|-----------|----------|--------------|
| 1 | CNPG Operator | 15 min | None |
| 2 | Storage Configuration | 10 min | Phase 1 |
| 3 | PostgreSQL Cluster | 20 min | Phase 2 |
| 4 | Backup Configuration | 30 min | Phase 3, MinIO |
| 5 | Scheduled Maintenance | 15 min | Phase 3 |
| 6 | Monitoring & Alerting | 45 min | Phase 3, Prometheus |
| 7 | Connection Pooling | 15 min | Phase 3 |
| 8 | Testing & Validation | 60 min | All phases |

**Total estimated time: ~3.5 hours**

---

## 3. Phase 1: Operator Deployment

### Files to Create
```
infrastructure/controllers/cloudnative-pg/
├── kustomization.yaml
├── namespace.yaml
├── helmrepository.yaml
└── helmrelease.yaml
```

### Namespace
```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
  labels:
    app.kubernetes.io/name: cloudnative-pg
```

### HelmRepository
```yaml
# helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: cloudnative-pg
  namespace: cnpg-system
spec:
  interval: 24h
  url: https://cloudnative-pg.github.io/charts
```

### HelmRelease
```yaml
# helmrelease.yaml
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
      version: "0.x"  # Latest 0.x version
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
    # Resource limits for operator
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
      limits:
        cpu: 500m
        memory: 256Mi

    # Monitoring
    monitoring:
      podMonitorEnabled: true
      podMonitorAdditionalLabels:
        release: kube-prometheus-stack

    # Schedule on worker nodes
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-role.kubernetes.io/control-plane
                  operator: DoesNotExist
```

### Kustomization
```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
```

---

## 4. Phase 2: Storage Configuration

### Dedicated StorageClass for Databases
```yaml
# infrastructure/controllers/longhorn/storageclass-database.yaml
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

Add to Longhorn kustomization:
```yaml
resources:
  - ...existing...
  - storageclass-database.yaml
```

---

## 5. Phase 3: PostgreSQL Cluster

### Directory Structure
```
infrastructure/configs/databases/
├── kustomization.yaml
├── namespace.yaml
├── postgres-cluster.yaml
├── scheduled-backup.yaml
├── pooler.yaml
└── sealedsecret-minio.yaml
```

### Namespace
```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: databases
  labels:
    app.kubernetes.io/name: databases
```

### PostgreSQL Cluster
```yaml
# postgres-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: databases
spec:
  description: "Primary PostgreSQL cluster for homelab"

  # Cluster size: 1 primary + 2 replicas
  instances: 3

  # PostgreSQL version
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4

  # Primary update strategy
  primaryUpdateStrategy: unsupervised
  primaryUpdateMethod: switchover

  # PostgreSQL configuration
  postgresql:
    parameters:
      # Memory settings (adjust based on instance resources)
      shared_buffers: "256MB"
      effective_cache_size: "768MB"
      work_mem: "16MB"
      maintenance_work_mem: "128MB"

      # Connections
      max_connections: "100"

      # WAL settings
      wal_buffers: "8MB"
      min_wal_size: "512MB"
      max_wal_size: "1GB"

      # Checkpoints
      checkpoint_completion_target: "0.9"

      # Logging
      log_destination: "stderr"
      logging_collector: "off"
      log_min_duration_statement: "1000"  # Log queries > 1s
      log_checkpoints: "on"
      log_connections: "on"
      log_disconnections: "on"
      log_lock_waits: "on"
      log_temp_files: "0"

      # Autovacuum tuning
      autovacuum_vacuum_scale_factor: "0.1"
      autovacuum_analyze_scale_factor: "0.05"
      autovacuum_vacuum_cost_delay: "2ms"
      autovacuum_max_workers: "3"

      # Performance
      random_page_cost: "1.1"  # SSD optimized
      effective_io_concurrency: "200"

    pg_hba:
      - host all all 10.233.0.0/16 scram-sha-256  # Pod network
      - host all all 10.96.0.0/12 scram-sha-256   # Service network

  # Storage configuration (using dedicated StorageClass)
  storage:
    storageClass: longhorn-database
    size: 20Gi

  # Separate WAL storage for better performance
  walStorage:
    storageClass: longhorn-database
    size: 5Gi

  # Resource limits per instance
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi

  # Bootstrap: initialize new cluster
  bootstrap:
    initdb:
      database: app
      owner: app
      secret:
        name: postgres-app-credentials
      postInitSQL:
        - CREATE EXTENSION IF NOT EXISTS pg_stat_statements
        - CREATE EXTENSION IF NOT EXISTS pgcrypto

  # Superuser secret
  superuserSecret:
    name: postgres-superuser-credentials

  # Enable superuser access (for maintenance)
  enableSuperuserAccess: true

  # Monitoring
  monitoring:
    enablePodMonitor: true
    podMonitorMetricRelabelings:
      - sourceLabels: [cluster]
        targetLabel: cnpg_cluster
    podMonitorRelabelings:
      - sourceLabels: [__meta_kubernetes_pod_label_cnpg_io_cluster]
        targetLabel: cluster

  # Backup configuration (see Phase 4)
  backup:
    barmanObjectStore:
      destinationPath: s3://cnpg-backups/postgres
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
    retentionPolicy: "14d"

  # Node affinity - spread across workers
  affinity:
    enablePodAntiAffinity: true
    topologyKey: kubernetes.io/hostname
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist

  # Replication settings
  minSyncReplicas: 0
  maxSyncReplicas: 0  # Async replication (faster, slight data loss risk)

  # Startup/Liveness/Readiness probes
  startDelay: 30
  stopDelay: 30

  # Log level
  logLevel: info
```

### Database Credentials (to be sealed)
```yaml
# Plain secret template (DO NOT COMMIT - seal first!)
---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-superuser-credentials
  namespace: databases
type: kubernetes.io/basic-auth
stringData:
  username: postgres
  password: <GENERATE_SECURE_PASSWORD>
---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-app-credentials
  namespace: databases
type: kubernetes.io/basic-auth
stringData:
  username: app
  password: <GENERATE_SECURE_PASSWORD>
```

---

## 6. Phase 4: Backup Configuration

### MinIO Bucket Setup
Create a dedicated bucket for CNPG backups:
```bash
# Using mc (MinIO client)
mc mb minio/cnpg-backups
mc admin policy attach minio readwrite --user cnpg-backup-user
```

### MinIO Credentials Secret (to be sealed)
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cnpg-minio-credentials
  namespace: databases
type: Opaque
stringData:
  ACCESS_KEY_ID: <MINIO_ACCESS_KEY>
  SECRET_ACCESS_KEY: <MINIO_SECRET_KEY>
```

### Scheduled Backup
```yaml
# scheduled-backup.yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: postgres-daily-backup
  namespace: databases
spec:
  # Daily at 2:00 AM
  schedule: "0 0 2 * * *"

  # Backup from standby to reduce primary load
  backupOwnerReference: self

  # Target cluster
  cluster:
    name: postgres

  # Immediate backup on creation
  immediate: true

  # Don't suspend
  suspend: false
```

### On-Demand Backup (template)
```yaml
# backup-ondemand.yaml (apply manually when needed)
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: postgres-manual-YYYYMMDD
  namespace: databases
spec:
  cluster:
    name: postgres
```

### Volume Snapshot Class (for CSI snapshots)
```yaml
# volumesnapshotclass.yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapshot
  labels:
    velero.io/csi-volumesnapshot-class: "true"
driver: driver.longhorn.io
deletionPolicy: Delete
parameters:
  type: snap
```

### Volume Snapshot Backup (alternative to object store)
```yaml
# backup-snapshot.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: postgres-snapshot-YYYYMMDD
  namespace: databases
spec:
  cluster:
    name: postgres
  method: volumeSnapshot
  volumeSnapshot:
    className: longhorn-snapshot
    snapshotOwnerReference: cluster
```

---

## 7. Phase 5: Scheduled Maintenance

### PostgreSQL Maintenance Jobs

CNPG handles autovacuum automatically via PostgreSQL's built-in autovacuum. However, for additional maintenance tasks, create CronJobs:

```yaml
# maintenance-cronjobs.yaml
---
# Weekly VACUUM ANALYZE on all databases
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-vacuum-analyze
  namespace: databases
spec:
  schedule: "0 3 * * 0"  # Sunday 3:00 AM
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: vacuum
              image: ghcr.io/cloudnative-pg/postgresql:16.4
              command:
                - /bin/bash
                - -c
                - |
                  export PGPASSWORD=$(cat /secrets/password)
                  psql -h postgres-rw.databases.svc -U postgres -d app -c "VACUUM ANALYZE;"
                  psql -h postgres-rw.databases.svc -U postgres -d postgres -c "VACUUM ANALYZE;"
              volumeMounts:
                - name: superuser-secret
                  mountPath: /secrets
                  readOnly: true
          volumes:
            - name: superuser-secret
              secret:
                secretName: postgres-superuser-credentials
                items:
                  - key: password
                    path: password
---
# Weekly REINDEX (if needed)
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-reindex
  namespace: databases
spec:
  schedule: "0 4 * * 0"  # Sunday 4:00 AM
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: reindex
              image: ghcr.io/cloudnative-pg/postgresql:16.4
              command:
                - /bin/bash
                - -c
                - |
                  export PGPASSWORD=$(cat /secrets/password)
                  psql -h postgres-rw.databases.svc -U postgres -d app -c "REINDEX DATABASE app;"
              volumeMounts:
                - name: superuser-secret
                  mountPath: /secrets
                  readOnly: true
          volumes:
            - name: superuser-secret
              secret:
                secretName: postgres-superuser-credentials
                items:
                  - key: password
                    path: password
---
# Daily pg_stat_statements reset (optional - keeps stats fresh)
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-stats-reset
  namespace: databases
spec:
  schedule: "0 0 * * *"  # Daily midnight
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: stats-reset
              image: ghcr.io/cloudnative-pg/postgresql:16.4
              command:
                - /bin/bash
                - -c
                - |
                  export PGPASSWORD=$(cat /secrets/password)
                  psql -h postgres-rw.databases.svc -U postgres -d app -c "SELECT pg_stat_statements_reset();"
              volumeMounts:
                - name: superuser-secret
                  mountPath: /secrets
                  readOnly: true
          volumes:
            - name: superuser-secret
              secret:
                secretName: postgres-superuser-credentials
                items:
                  - key: password
                    path: password
```

### Maintenance Window Configuration

For controlled maintenance, use the `primaryUpdateStrategy`:
```yaml
# In Cluster spec
spec:
  primaryUpdateStrategy: supervised  # Requires manual promotion
  # OR
  primaryUpdateStrategy: unsupervised  # Automatic (default)

  # Maintenance window (optional annotation)
  # Used by external tools, not enforced by CNPG
```

---

## 8. Phase 6: Monitoring & Alerting

### Grafana Dashboard

```yaml
# grafana-dashboard-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-cnpg
  namespace: observability
  labels:
    grafana_dashboard: "1"
data:
  cnpg-dashboard.json: |
    {
      "__requires": [{"type": "grafana", "version": "9.0.0"}],
      "title": "CloudNativePG",
      "uid": "cloudnative-pg",
      ... # Full dashboard JSON from https://github.com/cloudnative-pg/grafana-dashboards
    }
```

Alternatively, add to Grafana HelmRelease:
```yaml
# In grafana values
dashboardProviders:
  dashboardproviders.yaml:
    providers:
      - name: 'cnpg'
        folder: 'Databases'
        type: file
        options:
          path: /var/lib/grafana/dashboards/cnpg

dashboards:
  cnpg:
    cloudnative-pg:
      url: https://raw.githubusercontent.com/cloudnative-pg/grafana-dashboards/main/charts/cluster/grafana-dashboard.json
      datasource: Prometheus
```

### PrometheusRule for Alerts

```yaml
# prometheus-rules-cnpg.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cnpg-alerts
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: cloudnative-pg.rules
      rules:
        # Cluster health
        - alert: CNPGClusterNotHealthy
          expr: |
            cnpg_collector_up == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "CNPG cluster {{ $labels.cluster }} is not healthy"
            description: "CloudNativePG cluster {{ $labels.cluster }} collector is down"

        - alert: CNPGClusterHAWarning
          expr: |
            cnpg_pg_replication_slots_active == 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "CNPG cluster {{ $labels.cluster }} has no active replication"
            description: "No active replication slots - cluster may not be HA"

        # Instance issues
        - alert: CNPGInstanceDown
          expr: |
            cnpg_collector_postgres_version == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "PostgreSQL instance {{ $labels.pod }} is down"
            description: "Instance {{ $labels.pod }} in cluster {{ $labels.cluster }} is not responding"

        - alert: CNPGPrimaryMissing
          expr: |
            count by (cluster) (cnpg_pg_replication_is_wal_receiver_up) == count by (cluster) (cnpg_collector_up)
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "CNPG cluster {{ $labels.cluster }} has no primary"
            description: "All instances are replicas - no primary available for writes"

        # Replication lag
        - alert: CNPGReplicationLagHigh
          expr: |
            cnpg_pg_replication_lag > 30
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "CNPG replication lag is high"
            description: "Replica {{ $labels.pod }} is {{ $value }}s behind primary"

        - alert: CNPGReplicationLagCritical
          expr: |
            cnpg_pg_replication_lag > 300
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "CNPG replication lag is critical"
            description: "Replica {{ $labels.pod }} is {{ $value }}s behind primary"

        # Backup issues
        - alert: CNPGBackupFailed
          expr: |
            time() - cnpg_pg_stat_archiver_last_archived_time > 3600
            AND cnpg_pg_stat_archiver_failed_count > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "CNPG WAL archiving is failing"
            description: "WAL archiving failed for cluster {{ $labels.cluster }}"

        - alert: CNPGLastBackupTooOld
          expr: |
            time() - cnpg_collector_last_available_backup_timestamp > 172800
          for: 1h
          labels:
            severity: critical
          annotations:
            summary: "CNPG last backup is too old"
            description: "Last backup for {{ $labels.cluster }} is over 48 hours old"

        # Connection issues
        - alert: CNPGConnectionsNearLimit
          expr: |
            cnpg_pg_stat_activity_connections / cnpg_pg_settings_setting{name="max_connections"} > 0.8
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "PostgreSQL connections near limit"
            description: "{{ $labels.pod }} is at {{ $value | humanizePercentage }} of max connections"

        - alert: CNPGConnectionsExhausted
          expr: |
            cnpg_pg_stat_activity_connections / cnpg_pg_settings_setting{name="max_connections"} > 0.95
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "PostgreSQL connections almost exhausted"
            description: "{{ $labels.pod }} is at {{ $value | humanizePercentage }} of max connections"

        # Storage issues
        - alert: CNPGStorageAlmostFull
          expr: |
            cnpg_pg_database_size_bytes / cnpg_collector_pg_wal_storage_size * 100 > 80
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "PostgreSQL storage almost full"
            description: "Database storage for {{ $labels.cluster }} is over 80% full"

        - alert: CNPGStorageCritical
          expr: |
            cnpg_pg_database_size_bytes / cnpg_collector_pg_wal_storage_size * 100 > 90
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "PostgreSQL storage critical"
            description: "Database storage for {{ $labels.cluster }} is over 90% full"

        # Query performance
        - alert: CNPGSlowQueries
          expr: |
            rate(cnpg_pg_stat_user_tables_seq_scan[5m]) > 100
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "High sequential scan rate detected"
            description: "{{ $labels.pod }} has high sequential scans - consider adding indexes"

        - alert: CNPGDeadlocksDetected
          expr: |
            increase(cnpg_pg_stat_database_deadlocks[5m]) > 0
          for: 1m
          labels:
            severity: warning
          annotations:
            summary: "PostgreSQL deadlocks detected"
            description: "Deadlocks occurred in database {{ $labels.datname }}"

        # Vacuum issues
        - alert: CNPGTablesNeedVacuum
          expr: |
            cnpg_pg_stat_user_tables_n_dead_tup > 10000
            AND cnpg_pg_stat_user_tables_last_autovacuum == 0
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "Tables need vacuum"
            description: "Table {{ $labels.relname }} has {{ $value }} dead tuples and hasn't been vacuumed"

        - alert: CNPGTransactionIDWraparound
          expr: |
            cnpg_pg_database_xact_commit > 2000000000
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Transaction ID wraparound risk"
            description: "Database {{ $labels.datname }} is at risk of transaction ID wraparound"
```

### Logging Configuration

PostgreSQL logs are sent to stderr and collected by Kubernetes. Configure Loki to capture them:

```yaml
# In Alloy config (if using Alloy for log collection)
loki.source.kubernetes "postgres_logs" {
  targets    = discovery.kubernetes.pods.targets

  selector {
    match_labels = {
      "cnpg.io/cluster" = "postgres"
    }
  }
}
```

For log queries in Grafana:
```logql
# All PostgreSQL logs
{namespace="databases", app_kubernetes_io_name="cloudnative-pg"}

# Error logs only
{namespace="databases", app_kubernetes_io_name="cloudnative-pg"} |= "ERROR"

# Slow queries (>1s)
{namespace="databases", app_kubernetes_io_name="cloudnative-pg"} |= "duration:"

# Connection events
{namespace="databases", app_kubernetes_io_name="cloudnative-pg"} |~ "connection (authorized|received)"

# Checkpoint events
{namespace="databases", app_kubernetes_io_name="cloudnative-pg"} |= "checkpoint"
```

---

## 9. Phase 7: Connection Pooling

### PgBouncer Pooler

```yaml
# pooler.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: postgres-pooler
  namespace: databases
spec:
  # Target cluster
  cluster:
    name: postgres

  # Number of pooler instances
  instances: 2

  # Pool mode
  type: rw  # Read-write (connects to primary)

  # PgBouncer configuration
  pgbouncer:
    poolMode: transaction  # transaction, session, or statement

    parameters:
      max_client_conn: "200"
      default_pool_size: "25"
      min_pool_size: "5"
      reserve_pool_size: "5"
      reserve_pool_timeout: "5"
      max_db_connections: "50"
      max_user_connections: "50"

      # Timeouts
      server_idle_timeout: "600"
      server_lifetime: "3600"
      client_idle_timeout: "0"
      query_timeout: "0"
      query_wait_timeout: "120"

      # Logging
      log_connections: "1"
      log_disconnections: "1"
      log_pooler_errors: "1"
      stats_period: "60"

  # Monitoring
  monitoring:
    enablePodMonitor: true

  # Resources
  template:
    spec:
      containers:
        - name: pgbouncer
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role.kubernetes.io/control-plane
                    operator: DoesNotExist
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: cnpg.io/poolerName
                      operator: In
                      values:
                        - postgres-pooler
                topologyKey: kubernetes.io/hostname
```

### Service Endpoints

After deployment, you'll have these services:
```
postgres-rw.databases.svc        -> Primary (direct)
postgres-ro.databases.svc        -> Read replicas (direct)
postgres-r.databases.svc         -> Any instance (direct)
postgres-pooler.databases.svc    -> PgBouncer (pooled connections)
```

---

## 10. Testing & Validation

### Pre-Deployment Checklist
- [ ] MinIO bucket created for backups
- [ ] MinIO credentials generated and sealed
- [ ] Database passwords generated and sealed
- [ ] Storage class created
- [ ] Prometheus/Grafana stack healthy

### Phase 1 Validation: Operator
```bash
# Verify operator is running
kubectl get pods -n cnpg-system
kubectl logs -n cnpg-system deployment/cnpg-cloudnative-pg -f

# Verify CRDs installed
kubectl get crd | grep cnpg
```

### Phase 3 Validation: Cluster
```bash
# Check cluster status
kubectl get cluster -n databases
kubectl describe cluster postgres -n databases

# Verify all instances running
kubectl get pods -n databases -l cnpg.io/cluster=postgres

# Check replication status
kubectl cnpg status postgres -n databases

# Test connection
kubectl run psql-test --rm -it --image=postgres:16 --restart=Never -- \
  psql -h postgres-rw.databases.svc -U app -d app -c "SELECT 1"
```

### Phase 4 Validation: Backups
```bash
# Trigger manual backup
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: postgres-test-backup
  namespace: databases
spec:
  cluster:
    name: postgres
EOF

# Check backup status
kubectl get backup -n databases
kubectl describe backup postgres-test-backup -n databases

# Verify in MinIO
mc ls minio/cnpg-backups/postgres/
```

### Phase 5 Validation: Maintenance Jobs
```bash
# Check CronJob status
kubectl get cronjobs -n databases

# Trigger manual vacuum
kubectl create job --from=cronjob/postgres-vacuum-analyze manual-vacuum -n databases

# Check job logs
kubectl logs job/manual-vacuum -n databases
```

### Phase 6 Validation: Monitoring
```bash
# Check metrics endpoint
kubectl port-forward -n databases svc/postgres-rw 9187:9187
curl localhost:9187/metrics | head -50

# Verify PodMonitor
kubectl get podmonitor -n databases

# Check Prometheus targets
# Open Prometheus UI -> Status -> Targets -> Look for cnpg endpoints
```

### Failover Test
```bash
# Get current primary
kubectl cnpg status postgres -n databases

# Trigger failover (delete primary pod)
kubectl delete pod postgres-1 -n databases  # Adjust pod name

# Watch failover
kubectl get pods -n databases -w

# Verify new primary
kubectl cnpg status postgres -n databases
```

### Recovery Test
```bash
# Create test data
kubectl run psql-test --rm -it --image=postgres:16 --restart=Never -- \
  psql -h postgres-rw.databases.svc -U app -d app -c \
  "CREATE TABLE test(id serial, data text); INSERT INTO test(data) VALUES ('before-backup');"

# Take backup
kubectl apply -f backup-ondemand.yaml

# Add more data
kubectl run psql-test --rm -it --image=postgres:16 --restart=Never -- \
  psql -h postgres-rw.databases.svc -U app -d app -c \
  "INSERT INTO test(data) VALUES ('after-backup');"

# Note the timestamp for PITR test

# Create recovery cluster (in separate namespace for testing)
# ... (recovery manifest)

# Verify recovered data
```

---

## Summary: Implementation Order

1. **Discuss & Approve** storage strategy (Option A recommended)
2. **Phase 1**: Deploy CNPG operator
3. **Phase 2**: Create `longhorn-database` StorageClass
4. **Phase 3**: Create MinIO bucket + sealed secrets
5. **Phase 3**: Deploy PostgreSQL cluster
6. **Phase 4**: Configure scheduled backups
7. **Phase 5**: Deploy maintenance CronJobs
8. **Phase 6**: Add Grafana dashboard + PrometheusRules
9. **Phase 7**: Deploy PgBouncer pooler
10. **Phase 8**: Run validation tests

---

## Questions Requiring Decision

1. **Storage Strategy**: Confirm Option A (dedicated StorageClass)?
2. **Cluster Size**: Start with 3 instances or 1 for testing?
3. **Database Names**: What application databases do you need?
4. **Backup Retention**: 14 days sufficient?
5. **Sync Replication**: Async (faster) or sync (safer)?
