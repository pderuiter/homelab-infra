# CloudNative-PG Analysis & Decision Document

**Date:** 2025-12-07
**Version:** 1.27 (current)
**Purpose:** Evaluate CloudNative-PG as the PostgreSQL solution for homelab Kubernetes cluster

---

## Executive Summary

CloudNative-PG (CNPG) is a Kubernetes operator for managing PostgreSQL databases. It is an open-source project originally created by EDB (EnterpriseDB) and donated to the CNCF. It provides automated high availability, backup/recovery, and declarative PostgreSQL management.

**Recommendation:** CloudNative-PG is well-suited for this homelab cluster given the existing infrastructure (Longhorn storage, Prometheus/Grafana monitoring, MinIO for S3-compatible storage).

---

## Architecture Overview

### How It Works
- Deploys PostgreSQL as a **Cluster** custom resource
- One primary instance + optional hot standby replicas
- Uses PostgreSQL's native streaming replication (not storage-level)
- **Shared-nothing architecture**: each instance has its own PVC
- Operator manages failover, promotion, and self-healing automatically

### Key Components
| Component | Description |
|-----------|-------------|
| Operator | Controller managing Cluster resources (cnpg-system namespace) |
| Cluster | CRD representing a PostgreSQL deployment |
| Pooler | Optional PgBouncer connection pooling |
| Backup | CRD for point-in-time backups |
| ScheduledBackup | Cron-based backup automation |

---

## Pros

### 1. Kubernetes-Native Design
- Fully declarative (GitOps compatible)
- No external dependencies (Patroni, etcd, etc.)
- Direct Kubernetes API integration for HA
- Works with existing infrastructure-as-code workflows

### 2. High Availability
- Automatic failover to most synchronized replica
- Self-healing (failed instances automatically recreated)
- Synchronous and asynchronous replication options
- Quorum-based replication for data safety

### 3. Comprehensive Backup & Recovery
- **Object store backups**: S3, MinIO, Azure Blob, GCS
- **Volume snapshots**: Native Kubernetes CSI support
- **Point-in-time recovery (PITR)**: Restore to any timestamp
- **WAL archiving**: Continuous backup with RPO ≤ 5 minutes
- **Scheduled backups**: Cron-based with immediate trigger option
- Backup from standby (reduces primary load)

### 4. Excellent Monitoring Integration
- Prometheus metrics on port 9187 (per instance)
- Pre-built Grafana dashboards available
- Custom metric queries via ConfigMap
- PrometheusRule templates for alerting
- Compatible with existing kube-prometheus-stack

### 5. Security First
- TLS 1.3 by default for all connections
- Client certificate authentication for replication
- SCRAM-SHA-256 password encryption
- Non-root containers, read-only filesystem
- Signed container images with SBOM/SLSA attestations
- Network policy support

### 6. Connection Pooling (Built-in)
- Integrated PgBouncer via Pooler CRD
- Automatic TLS termination
- Prometheus metrics for pooler
- 60+ configurable PgBouncer parameters

### 7. Operational Features
- Rolling updates (PostgreSQL + operator)
- Online resize of PVCs (storage-class dependent)
- Cluster hibernation (scale to zero)
- Database import (offline/online with pg_dump)
- Major version upgrades via logical replication

### 8. Storage Flexibility
- Works with any CSI-compliant storage
- **Specifically supports Longhorn** (your current storage)
- Separate WAL volume option for performance
- Tablespace support for advanced use cases

---

## Cons

### 1. PostgreSQL Only
- No support for MySQL, MariaDB, or other databases
- If you need multiple database types, you'll need additional operators

### 2. Learning Curve
- Requires understanding of PostgreSQL internals (WAL, replication)
- Operator-specific concepts (Cluster, Pooler, Backup CRDs)
- Debugging requires PostgreSQL knowledge

### 3. Resource Overhead
- Each replica is a full PostgreSQL instance
- 3-instance HA cluster = 3x storage requirements
- Operator runs continuously (minimal CPU/memory)

### 4. Cross-Cluster Limitations
- Failover within a cluster is automatic
- **Cross-cluster failover requires manual intervention**
- Replica clusters need explicit promotion

### 5. Backup Complexity
- Object store backups require external storage (MinIO, S3)
- Volume snapshots require CSI driver support
- PITR requires WAL archiving to be enabled

### 6. Limited Connection Pooling Flexibility
- PgBouncer only (no PgPool-II)
- Single cluster per pooler
- Some managed config aspects not customizable

### 7. Version Upgrade Considerations
- Operator upgrades may require cluster restarts
- Major PostgreSQL upgrades need logical replication
- Some versions have breaking changes (check release notes)

---

## Comparison with Alternatives

| Feature | CloudNative-PG | Crunchy PGO | Zalando Postgres Operator |
|---------|----------------|-------------|---------------------------|
| License | Apache 2.0 | Apache 2.0 | MIT |
| CNCF Status | Sandbox | Not CNCF | Not CNCF |
| HA Mechanism | Native streaming | Patroni | Patroni |
| External Dependencies | None | etcd (optional) | etcd required |
| Connection Pooling | PgBouncer | pgBouncer | None (external) |
| Backup to S3 | Yes (native) | Yes (pgBackRest) | Yes (WAL-E/WAL-G) |
| Complexity | Medium | Higher | Medium |
| Active Development | Very active | Active | Active |

---

## Homelab Fit Assessment

### Integration with Existing Stack

| Existing Component | CNPG Integration |
|--------------------|------------------|
| **Longhorn** | Excellent - explicitly documented support, recommends replica=1 at storage level |
| **Prometheus/Grafana** | Excellent - native ServiceMonitor, pre-built dashboards |
| **MinIO** | Excellent - S3-compatible backup destination |
| **cert-manager** | Good - TLS certificate integration supported |
| **Sealed Secrets** | Good - can seal database credentials |
| **Flux GitOps** | Excellent - fully declarative CRDs |

### Resource Requirements (Minimal 3-node HA)

```yaml
# Per PostgreSQL instance (3 total for HA)
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 1Gi

# Storage per instance
storage: 10Gi  # Adjust based on needs

# Operator (single deployment)
resources:
  requests:
    cpu: 100m
    memory: 100Mi
```

**Total minimum for 3-node HA cluster:**
- CPU: 400m requests (300m instances + 100m operator)
- Memory: 868Mi requests
- Storage: 30Gi (10Gi × 3 instances)

---

## Recommended Configuration for Homelab

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-cluster
  namespace: databases
spec:
  instances: 3  # Primary + 2 replicas

  postgresql:
    parameters:
      shared_buffers: "256MB"
      max_connections: "100"

  storage:
    storageClass: longhorn
    size: 10Gi

  # Backup to MinIO
  backup:
    barmanObjectStore:
      destinationPath: s3://postgres-backups/
      endpointURL: http://minio.minio:9000
      s3Credentials:
        accessKeyId:
          name: minio-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: minio-credentials
          key: SECRET_ACCESS_KEY
    retentionPolicy: "7d"

  # Monitoring
  monitoring:
    enablePodMonitor: true

  # Affinity for worker nodes
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
```

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Data loss | Low | High | WAL archiving to MinIO, scheduled backups |
| Failover failure | Low | High | Test failover regularly, monitor replication lag |
| Operator unavailability | Low | Medium | Operator is stateless, redeploys automatically |
| Storage failure | Medium | High | Longhorn replication, PITR backups |
| Upgrade issues | Medium | Medium | Test in staging, read release notes |

---

## Decision

### Recommended: Adopt CloudNative-PG

**Rationale:**
1. **Best fit for Kubernetes-native PostgreSQL** - no external dependencies
2. **Excellent integration** with existing stack (Longhorn, Prometheus, MinIO)
3. **Production-grade features** without enterprise licensing
4. **Active CNCF project** with strong community
5. **GitOps compatible** - fits existing Flux workflow
6. **Comprehensive backup/recovery** with existing MinIO

### Next Steps
1. Deploy CNPG operator via Helm or manifest
2. Create initial PostgreSQL cluster (start with 1 instance for testing)
3. Configure backup to MinIO
4. Add Grafana dashboard
5. Test failover and recovery procedures
6. Scale to 3 instances for production workloads

---

## References

- [CloudNative-PG Documentation](https://cloudnative-pg.io/documentation/current/)
- [GitHub Repository](https://github.com/cloudnative-pg/cloudnative-pg)
- [Grafana Dashboards](https://github.com/cloudnative-pg/grafana-dashboards)
- [CNCF Sandbox Project](https://www.cncf.io/projects/cloudnativepg/)
