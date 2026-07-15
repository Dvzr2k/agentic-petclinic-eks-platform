# ADR-0007: Generic Helm chart over per-service raw manifests

**Status:** Accepted — supersedes the project's original plain-K8s-manifest approach

## Context

The project initially deployed each of the 8 services from its own directory of raw
manifests (`Deployment`, `Service`, `ConfigMap` — roughly 24+ near-identical files), with
environment differences handled by Kustomize overlays patching those base files. Every shared
change (a security fix, a probe adjustment) had to be hand-applied across all 8 copies
independently — nothing enforced that they stayed in sync.

That risk stopped being theoretical: during the 4th security-audit round, the original raw
manifests were found still sitting in the repo, unreferenced by any ArgoCD Application, frozen
at a stale, less-secure configuration (`readOnlyRootFilesystem: false`, an old image tag) —
after the project had already migrated to Helm. Applying the old Kustomize overlay by habit
would have silently overwritten the real, Helm-managed Deployments with that stale version.
See incident #10 in `docs/incident-playbook.md` for the full account.

## Decision

Replace all 8 per-service manifest directories with a single generic Helm chart
(`helm/petclinic-service/`), parameterized entirely through values files: 8 small
per-service files (`helm-values/{service}.yaml`) plus 2 per-environment files
(`helm-values/{dev,prod}.yaml`), merged at deploy time.

## Consequences

**Gained:**
- One copy of the actual Kubernetes object logic. A fix to `deployment.yaml`'s template
  applies to all 8 services and both environments simultaneously — there is no longer a
  second copy that can be forgotten or left to drift.
- Values files hold only small config values (port, image tag, replica count), not full
  manifest logic — nothing left to drift into.
- Structurally eliminates the exact failure class behind incident #10: there's no abandoned
  "old version" of the chart that can silently exist alongside the real one, because there's
  only ever one chart.

**Given up / accepted risk:**
- Added Helm as a real dependency and a small learning curve — what actually gets applied to
  the cluster is now one layer removed from the raw YAML (`helm template` is needed to see
  the literal rendered output).
- The original raw manifests still had to be manually identified and deleted once the
  migration happened — the tooling change alone didn't retroactively clean up the old files;
  that cleanup was a separate, later fix (this is exactly what incident #10 exposed).
