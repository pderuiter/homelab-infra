# Homelab Infrastructure - GitOps with FluxCD

A production-grade, GitOps-managed Kubernetes homelab running on bare-metal nodes. All cluster state is declared in this repository and continuously reconciled by [FluxCD](https://fluxcd.io/).


## Why GitOps?

Traditional management relies on imperative commands (`kubectl apply`, `helm install`) that leave no audit trail and are impossible to reproduce reliably. GitOps takes a different approach:

- **Git is the single source of truth.** Every change is a commit, every rollback is a revert.
- **FluxCD watches this repo** and reconciles the cluster state automatically. No manual `kubectl` required for deployments.
- **Two-phase deployment ordering** ensures controllers (CRDs, operators) are healthy before dependent configuration (databases, apps, secrets) is applied.
- **Self-healing** — if someone manually changes a resource, Flux reverts it to match Git within the reconciliation interval.


## Cluster Overview

| Detail | Value |
|--------|-------|
| **Cluster** | `wbyc-k8s` (We Build Your Cloud) |
| **Kubernetes** | v1.34.2 |
| **Domain** | bsdserver.nl (public), bsdserver.lan (internal) |
| **Nodes** | 3 masters + 3 workers (bare-metal VMs) |
| **CNI** | Cilium |
| **kube-proxy** | IPVS with `strictARP: true` (required for MetalLB L2) |
| **API endpoint** | https://kube-api.bsdserver.nl:6443 |


## Repository Structure

```
homelab-infra/
├── clusters/wbyc-k8s/           # Cluster entry point for Flux
│   ├── flux-system/             # Flux bootstrap components
│   ├── infrastructure.yaml      # Defines two Kustomizations (controllers → config)
│   └── kustomization.yaml       # Root: includes flux-system + infrastructure
│
├── infrastructure/
│   ├── controllers/             # Phase 1: Operators, Helm releases, system components
│   │   ├── cert-manager/        #   TLS certificates (Let's Encrypt + TransIP DNS-01)
│   │   ├── cloudnative-pg/      #   PostgreSQL operator
│   │   ├── external-dns/        #   RFC2136 DNS updates to internal BIND
│   │   ├── external-secrets/    #   Syncs secrets from HashiCorp Vault
│   │   ├── longhorn/            #   Distributed block storage
│   │   ├── metallb/             #   L2 LoadBalancer (192.168.2.160-169)
│   │   ├── observability/       #   Prometheus, Grafana, Loki, Alloy, ntfy
│   │   ├── traefik/             #   Ingress controller
│   │   ├── synology-csi/        #   Synology NAS iSCSI/NFS (deployed, not active)
│   │   ├── node-tuning/         #   Sysctl tuning (inotify limits)
│   │   ├── sealed-secrets/      #   Encrypted secrets for Git
│   │   ├── vault-unseal/        #   Auto-unseals HashiCorp Vault (3 deployments)
│   │   ├── minio/               #   S3-compatible object storage
│   │   ├── kubevious/           #   Cluster visualization and validation
│   │   ├── homepage/            #   Dashboard (homepage.bsdserver.nl)
│   │   ├── searxng/             #   Metasearch engine
│   │   ├── bytestash/           #   Code snippet storage
│   │   ├── web-check/           #   Website monitoring
│   │   └── external-dns-transip/#   TransIP DNS provider for cert-manager
│   │
│   └── config/                  # Phase 2: Apps, databases, secrets (depends on controllers)
│       ├── vault-auth/          #   Vault ↔ Kubernetes auth binding
│       ├── databases/           #   CNPG PostgreSQL clusters + pooler
│       ├── ghost/               #   Blog platform (blog.bsdserver.nl)
│       ├── keycloak/            #   Identity & access management
│       ├── taiga/               #   Project management
│       ├── phpipam/             #   IP address management
│       ├── sonarqube/           #   Code quality analysis
│       ├── listmonk/            #   Email newsletter
│       ├── eda/                 #   Event-Driven Ansible
│       ├── homelab-dashboard/   #   Custom status dashboard (homelab.bsdserver.nl)
│       ├── cert-manager/        #   ClusterIssuers (staging + production)
│       ├── metallb/             #   IPAddressPools + L2Advertisement
│       ├── external-dns/        #   TSIG key for RFC2136
│       └── synology-csi/        #   StorageClass definitions
│
├── ansible/                     # Node preparation playbooks
│   ├── prepare-longhorn-disks.yaml
│   └── test-pvc.yml
│
├── apps/                        # Reserved for future app deployments
│   ├── base/
│   ├── staging/
│   └── production/
│
├── scripts/                     # Utility scripts (gitignored)
└── .kubevious.yaml              # Manifest validation config
```

## Deployment Flow

Flux reconciles in two ordered phases, defined in `clusters/wbyc-k8s/infrastructure.yaml`:

```
┌─────────────────────────────────────────────────────────┐
│  1. infrastructure-controllers  (interval: 1h)          │
│     Deploys: CRDs, operators, Helm releases             │
│     wait: true ← must be healthy before phase 2         │
└──────────────────────┬──────────────────────────────────┘
                       │ dependsOn
┌──────────────────────▼──────────────────────────────────┐
│  2. infrastructure-config  (interval: 1h)               │
│     Deploys: Apps, databases, secrets, ClusterIssuers   │
│     Depends on: controllers being Ready                 │
└─────────────────────────────────────────────────────────┘
```

This ensures that CRDs (like `Certificate`, `ExternalSecret`, `Cluster`) exist before resources that use them are applied.


## Design Decisions

### Secrets: Vault + External Secrets Operator

Secrets are stored in HashiCorp Vault and synced into Kubernetes by the External Secrets Operator (ESO). This avoids committing secrets to Git while keeping the GitOps model intact — the `ExternalSecret` manifests in Git declare *what* secrets to fetch, and ESO handles the *how*.

- **ClusterSecretStore** authenticates to Vault using Kubernetes service account tokens
- **25 ExternalSecrets** with 1-hour refresh intervals
- **Webhook disabled** — ESO's validating webhook has a known bug causing ~3 CPU cores of overhead. Validation happens via kubectl/GitOps instead.


### Storage: Longhorn

Longhorn provides replicated block storage across worker nodes. Each worker has a dedicated 150 GB disk (`/dev/sdb` or `/dev/sdc`) for Longhorn volumes. Two storage classes exist:

- `longhorn` — default, for general workloads
- `longhorn-database` — tuned for database I/O patterns


### Networking: MetalLB + Traefik

On bare-metal there's no cloud load balancer, so MetalLB provides L2 LoadBalancer services. Traefik sits behind MetalLB as the ingress controller:

- **MetalLB** advertises IPs from `192.168.2.160-169` via ARP
- **Traefik** handles HTTP→HTTPS redirect, TLS termination, and routing
- **kube-proxy runs in IPVS mode** with `strictARP: true` — mandatory for MetalLB L2 to work correctly. Without it, all nodes respond to ARP for LoadBalancer IPs, causing intermittent timeouts.


### DNS: Split-Horizon

Two DNS systems serve different purposes:

- **Internal (BIND via RFC2136)** — `external-dns` automatically creates DNS records on the internal BIND server for cluster services
- **Public (TransIP DNS-01)** — `cert-manager` uses TransIP's API to solve DNS-01 challenges for Let's Encrypt certificates


### Databases: CloudNative-PG

PostgreSQL is managed by the CloudNative-PG operator, which handles replication, failover, and backups. Database clusters are defined in `infrastructure/config/databases/`. Grafana uses CNPG PostgreSQL instead of SQLite.

### Observability: Prometheus + Grafana + Loki + Alertmanager

The full monitoring stack runs in the `observability` namespace:

- **Prometheus** scrapes metrics from all instrumented workloads
- **Grafana** visualizes metrics and logs (backed by CNPG PostgreSQL)
- **Loki** aggregates logs from all pods
- **Alloy** (Grafana Agent) collects and ships logs/metrics
- **ntfy** receives alerts from Alertmanager and Flux notifications

Custom PrometheusRules monitor external-secrets sync failures, Flux reconciliation errors, certificate expiry, pod health, Longhorn volume health, and node pressure.


### Vault Auto-Unseal

HashiCorp Vault runs outside the cluster on three Docker hosts. Three `vault-unseal` deployments run inside the cluster, each holding a different subset of unseal keys. Pod anti-affinity (required, not preferred) ensures each deployment runs on a separate worker node — if any single node goes down, the remaining two can still unseal Vault.


### Node Tuning

A DaemonSet applies sysctl settings on every node at boot, primarily increasing `inotify` limits (`max_user_watches=524288`, `max_user_instances=512`) required by Loki, Alloy, Flux, and other file-watching components.


### Resource Limits

Every pod has explicit resource requests and limits, sized from actual Prometheus metrics with 1.5-2x headroom for bursts. For Helm charts that don't properly template resource values, HelmRelease `postRenderers` with JSON patches are used to inject limits into rendered manifests.


### Image Tags

All container images use specific version tags, never `:latest`. This prevents unexpected breakages from upstream changes and ensures deployments are reproducible. Version updates are explicit git commits.


## Manifest Validation

[Kubevious CLI](https://github.com/kubevious/cli) validates manifests before they reach the cluster:

```bash
./scripts/validate-manifests.sh infrastructure/
```

This checks for API syntax errors, missing references (ConfigMaps, Secrets, ServiceAccounts), label selector mismatches, and security best practices. Configuration is in `.kubevious.yaml`, targeting Kubernetes v1.34.2.


## Notifications

| Channel | Source | Topic |
|---------|--------|-------|
| ntfy | Alertmanager | `ntfy.bsdserver.nl/alerts` |
| ntfy | Flux | `ntfy.bsdserver.nl/flux` |

Flux sends reconciliation errors and Git revision updates to ntfy. Alertmanager forwards firing alerts for infrastructure issues.


## Common Operations

```bash
# Check overall Flux status
flux get all -A

# Force reconciliation
flux reconcile kustomization infrastructure-controllers
flux reconcile kustomization infrastructure-config

# Check HelmRelease status
flux get helmreleases -A

# View Flux error logs
flux logs --level=error

# Temporarily pause reconciliation
flux suspend kustomization <name>
flux resume kustomization <name>

# Validate manifests locally
./scripts/validate-manifests.sh infrastructure/
```


## Bootstrapping

To bootstrap Flux on a fresh cluster:

```bash
# 1. Set GitHub credentials in .env
# 2. Run the bootstrap script
./install-flux.sh
```

This installs the Flux CLI, runs pre-flight checks, and bootstraps the cluster to track this repository's `clusters/wbyc-k8s` path.


## Ansible

The `ansible/` directory contains playbooks for node preparation:

- **prepare-longhorn-disks.yaml** — Partitions and formats dedicated storage disks for Longhorn on worker nodes
- **test-pvc.yml** — Smoke test for PVC creation and mounting
