# Helm Chart Guide

**Last Updated:** 2026-07-08

**Purpose:** Explains the generic Helm chart at `helm/petclinic-service/`, how values are layered per service and per environment, and how to deploy, modify, or extend it. Replaces the raw `k8s/base/` + `k8s/overlays/` Kustomize setup as the source of truth for how the 8 Petclinic services get deployed.

## Table of Contents

- [Chart Structure](#chart-structure)
- [Values Hierarchy](#values-hierarchy)
- [Deploying a Service Manually](#deploying-a-service-manually)
- [Adding a New Service](#adding-a-new-service)
- [Changing Resources, Replicas, or Environment Variables](#changing-resources-replicas-or-environment-variables)
- [ArgoCD Integration](#argocd-integration)

## Chart Structure

One generic chart, shared by all 8 services — nothing service-specific is hardcoded in the templates themselves:

```
helm/petclinic-service/
├── Chart.yaml
├── values.yaml              # Chart defaults (probe paths, security context, base resources, etc.)
└── templates/
    ├── deployment.yaml      # Deployment: probes, resources, env vars, init containers, security context
    ├── service.yaml         # ClusterIP Service
    ├── configmap.yaml       # Non-secret env vars (merges per-service config + per-env overrides)
    ├── serviceaccount.yaml
    ├── hpa.yaml             # HorizontalPodAutoscaler — conditional, see below
    ├── pdb.yaml             # PodDisruptionBudget — conditional, see below
    └── _helpers.tpl         # Shared template helpers (labels, name, replica/configmap resolution)
```

Each service is installed as its **own Helm release**, and the release name (e.g. `customers-service`) is what the templates use as the resource name and as the lookup key for per-service override maps (see below). This is why `_helpers.tpl`'s `petclinic-service.name` helper is just `.Release.Name` — there's no separate "app name" concept distinct from the release.

**HPA and PDB are conditional, not universal.** `hpa.yaml` and `pdb.yaml` only render a resource if the current release name appears in `.Values.autoscalingOverrides` / `.Values.podDisruptionBudgetOverrides` respectively — otherwise the template produces nothing. Only 5 of 8 services get an HPA in prod (api-gateway, customers-service, visits-service, vets-service, genai-service) and only 6 of 8 get a PDB (those 5 minus genai-service, plus config-server and discovery-server). Dev never populates either override map, so no service ever gets an HPA or PDB in dev.

## Values Hierarchy

Three layers, merged in this order (later layers win on conflicting keys):

```
helm/petclinic-service/values.yaml     (chart defaults — probe paths, security context, base resources)
        ↓
helm-values/{service}.yaml             (per-service — port, env vars, init containers, secret refs, component label)
        ↓
helm-values/{dev,prod}.yaml            (per-environment — image registry/tag, replica/HPA/PDB overrides, per-env ConfigMap values)
```

Applied via multiple `-f` flags, later files taking precedence — this is plain Helm/Kubernetes values merging, no special logic:

```bash
helm template customers-service helm/petclinic-service/ \
  -f helm-values/customers-service.yaml \
  -f helm-values/dev.yaml
```

**Per-service, per-environment settings** (replica count, HPA targets, PDB, and the DB-backed services' `SPRING_DATASOURCE_URL`) don't fit a simple 2-file merge on their own, since they vary along *both* axes at once. These use override maps keyed by release name, defined in `helm-values/{env}.yaml` and read via `index`/`hasKey` in the templates — e.g. `prod.yaml`'s `replicaOverrides.genai-service: 1` while `replicaOverrides.customers-service: 2`. See `helm/petclinic-service/values.yaml`'s comments for the full list of override maps (`replicaOverrides`, `autoscalingOverrides`, `podDisruptionBudgetOverrides`, `configMapOverrides`).

## Deploying a Service Manually

```bash
helm upgrade --install customers-service helm/petclinic-service/ \
  -n petclinic-dev \
  -f helm-values/customers-service.yaml \
  -f helm-values/dev.yaml \
  --set image.tag=${SHA}
```

- Release name (`customers-service`) must match the service's values filename and the keys used in `helm-values/{env}.yaml`'s override maps.
- `--set image.tag=${SHA}` overrides the default tag from the env values file — this is how CI will pin a specific build (see [ArgoCD Integration](#argocd-integration)).
- To deploy all 8 services to dev, repeat this command per service (or see `scripts/validate-helm.sh` for the same loop, minus the actual install — it only renders/validates).

## Adding a New Service

1. Create `helm-values/{new-service}.yaml` — set `component`, `image.name`, `service.port`, `configMap`, `env`, and `initContainers` (see any existing per-service file as a template).
2. If it needs prod HPA/PDB/a non-default replica count, add its entry to the relevant override map(s) in `helm-values/prod.yaml`. If it doesn't need one (like genai-service/admin-server don't get HPA), leave it out of that map entirely — that's what makes it conditional.
3. If it needs a database or another secret, add the `env` entries with `secretKeyRef` pointing at the exact secret name/key the ExternalSecret creates (see `k8s/base/external-secrets/`) — a wrong secret name renders and validates cleanly but the pod will `CreateContainerConfigError` at runtime, since nothing checks the secret actually exists until the pod tries to mount it.
4. Run `./scripts/validate-helm.sh` to confirm it renders and dry-runs cleanly for both environments.
5. *(Once Epic 17/ArgoCD exists)* add a corresponding ArgoCD `Application` — see [ArgoCD Integration](#argocd-integration).

## Changing Resources, Replicas, or Environment Variables

- **A resource/probe/security-context default for all 8 services** → edit `helm/petclinic-service/values.yaml`.
- **One service's port, env vars, secrets, or init containers** → edit that service's `helm-values/{service}.yaml`.
- **One service's CPU/memory** (like api-gateway's higher limits) → override `resources` in that service's own values file — the per-service file wins over the chart default.
- **Prod replica count / HPA min-max / PDB for one service** → edit the relevant override map entry in `helm-values/prod.yaml`, not the chart defaults — this is deliberately per-service, not a blanket setting, since prod replica counts genuinely differ (2 for most, 1 for genai-service/admin-server).
- **Image tag** → normally set via `--set image.tag=${SHA}` at deploy time (CI does this); the values files' `image.tag` is just a fallback default.

After any change, re-run `./scripts/validate-helm.sh` before deploying — it renders every service × environment combination and dry-run validates all of them in one pass.

## ArgoCD Integration

**Not yet implemented** — this section covers Epic 17 (GitOps with ArgoCD), which hasn't been built in this repo yet. Once it exists, this section should document:

- Where the ArgoCD `Application` CRDs live (`k8s/argocd/applications/{dev,prod}/`, one per service per environment)
- How an `Application` points at this chart + the corresponding `helm-values/{service}.yaml` + `helm-values/{env}.yaml`
- How CI updates `image.tag` in Git (not a live cluster) and ArgoCD detects and syncs the change
- Dev auto-sync vs. prod manual-approval sync behavior

Until Epic 17 lands, deployment is manual (`helm upgrade --install ...`, as above).
