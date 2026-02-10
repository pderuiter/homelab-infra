# Kubevious

Kubevious provides application-centric visualization and validation for Kubernetes clusters.

## Dashboard Access

- **URL**: https://kubevious.bsdserver.nl
- **Features**:
  - Application-centric cluster visualization
  - Real-time cluster state exploration
  - Configuration error detection
  - Relationship mapping between resources

## CLI Validation

The Kubevious CLI validates manifests before deployment to catch errors early.

### Installation

```bash
# Install to ~/bin
curl https://get.kubevious.io/cli.sh | bash -s -- ~/bin

# Add to PATH (add to ~/.zshrc or ~/.bashrc)
export PATH="$HOME/bin:$PATH"
```

### Usage

You can create a validation script in `scripts/validate-manifests.sh`:

```bash
#!/usr/bin/env bash
# Kubevious validation script
set -e

KUBEVIOUS_BIN="$HOME/bin/kubevious"
if [ -f "$KUBEVIOUS_BIN" ]; then
    KUBEVIOUS="$KUBEVIOUS_BIN"
elif command -v kubevious &>/dev/null; then
    KUBEVIOUS="kubevious"
else
    echo "❌ Kubevious CLI not found."
    exit 1
fi

K8S_VERSION="1.30.2"
TARGET="${1:-infrastructure/}"

$KUBEVIOUS guard "$TARGET" \
  --k8s-version "$K8S_VERSION" \
  --ignore-unknown \
  --ignore-non-k8s \
  --skip-community-rules
```

Or use kubevious directly:

```bash
# Basic validation
kubevious guard infrastructure/ --k8s-version 1.30.2 --ignore-unknown --ignore-non-k8s

# With live cluster (validates CRDs)
kubevious guard infrastructure/ --live-k8s

# Single file
kubevious guard infrastructure/controllers/traefik/helmrelease.yaml --ignore-unknown
```

### Validation Rules

Kubevious checks for:
- ✅ Kubernetes API syntax validity
- ✅ Resource references (ConfigMaps, Secrets, ServiceAccounts)
- ✅ Label selector mismatches
- ✅ Security best practices
- ✅ Resource limits and requests
- ✅ Image pull policies
- ✅ Liveness/readiness probes
- ✅ Cross-manifest violations

### Configuration

See `.kubevious.yaml` in the repository root for configuration options:
- K8s version target
- Ignore patterns
- Skip rules for homelab environment

### Git Pre-commit Hook

Optionally install a git hook to validate manifests before committing:

```bash
cd homelab-infra/
kubevious install-git-hook
```

## Dashboard Components

| Component | Purpose | Resources |
|-----------|---------|-----------|
| **backend** | API server | 100m-500m CPU, 256Mi-512Mi RAM |
| **parser** | Manifest parser | 100m-500m CPU, 256Mi-512Mi RAM |
| **ui** | Web interface | 50m-200m CPU, 128Mi-256Mi RAM |
| **mysql** | Database backend | 100m-500m CPU, 256Mi-512Mi RAM, 10Gi storage |

## Storage

- MySQL database: 10Gi Longhorn PVC
- StorageClass: `longhorn`

## Monitoring

ServiceMonitor enabled for Prometheus scraping.

## References

- [Kubevious Dashboard](https://github.com/kubevious/kubevious)
- [Kubevious CLI](https://github.com/kubevious/cli)
- [Helm Chart](https://github.com/kubevious/helm)
- [Rules Library](https://github.com/kubevious/rules-library)
