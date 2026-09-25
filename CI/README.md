# CI - Continuous Integration

## Overview

CI-systemet tester alle SellYourSaaS remote actions mod et rigtigt Kubernetes-cluster (k3d) for at verificere:
- **Fase 1b**: Grundlæggende K8s-integration (deploy, suspend, unsuspend, undeploy)
- **Fase 1c**: Livscyklus (rollback, restore, secrets-flow)

## Test Niveauer

### Niveau 1 - Protokol-test (ved hver commit)
Tester at scripts:
- Accepterer de rigtige parametre
- Returnerer korrekte exit-koder
- Skriver status-filer
- Er idempotente

### Niveau 2 - Integrations-test (nightly)
Tester at scripts:
- Efterlader K8s i forventet tilstand
- Opretter/sletter ressourcer korrekt
- Håndterer fejl korrekt (fail-closed)

## Kør lokalt

```bash
# 1. Start test-cluster
k3d cluster create saas-test

# 2. Installer nødvendige tools
# - kubectl
# - helm
# - curl
# - jq
# - yq (for values manipulation)

# 3. Kør tests
./CI/run-tests.sh
```

## GitHub Actions

Workflow-filen `.github/workflows/scripts-ci.yml` kører automatisk:
- Ved push til main
- Ved pull requests

### Setup GitHub Actions

1. Opret filen `.github/workflows/scripts-ci.yml`:

```yaml
name: scripts-ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup k3d
        uses: nolar/setup-k3d-k3s@v1
      
      - name: Setup Helm
        uses: azure/setup-helm@v4
      
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y curl jq
          # Install yq
          wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
          chmod +x /usr/local/bin/yq
      
      - name: Run tests
        run: ./CI/run-tests.sh
```

2. For S3-tests (MinIO mock):

```yaml
      - name: Setup MinIO
        run: |
          docker run -d -p 9000:9000 -p 9001:9001 \
            -e MINIO_ROOT_USER=minioadmin \
            -e MINIO_ROOT_PASSWORD=minioadmin \
            quay.io/minio/minio server /data --console-address ":9001"
          sleep 5
          curl -X PUT http://localhost:9000/minioadmin/minioadmin/xmlns/ \
            -H "Host: localhost:9000"
```

## Test Scenarier

### Fase 1b Tests
| Test | Beskrivelse | Forventet resultat |
|------|-------------|-------------------|
| beforedeploy | Validerer values-fil | exit 0, status=predeploy-ok |
| deploy | Opretter namespace + resources | namespace findes, pods kører |
| deploy (igen) | Idempotens | exit 0, ingen fejl |
| suspend | Skalerer til 0 | replicas=0, PVC bevaret |
| unsuspend | Skalerer op | replicas=1, pods kører |
| refresh | Re-konvergering | exit 0, status=deployed |
| recreateauthorizedkeys | Roterer secrets | ny secret oprettet |
| beforeundeploy | DB-dump | dump-fil oprettet/uploadet |
| undeploy | Nedlæggelse | namespace slettet |

### Fase 1c Tests
| Test | Beskrivelse | Forventet resultat |
|------|-------------|-------------------|
| migrate | Pre-migration snapshot | snapshot uploadet til S3 |
| rollback | Gendan til tidligere version | version gendannet, healthz OK |
| restore-tenant | Gendan fra backup | tenant fungerer |
| verify-secrets-flow | SealedSecrets flow | alle secrets er SealedSecrets |

## Fejlhåndtering

Hvis tests fejler:

1. **Tjek cluster status**: `kubectl get nodes`
2. **Tjek pods**: `kubectl get pods -A`
3. **Tjek logs**: `kubectl logs <pod> -n <namespace>`
4. **Tjek ressourcer**: `kubectl get all -n tenant-test1`

## Exit Kriterier

### Fase 1b
- ✅ Alle 10 tests bestået
- ✅ Protokol-test (Niveau 1) grøn

### Fase 1c
- ✅ Alle 14 tests bestået
- ✅ Rollback-test bestået
- ✅ Restore-test bestået
- ✅ Secrets-flow verificeret
