# Rollback Runbook

**Last Updated:** 2026-07-08

**Purpose:** How to recover when a bad image reaches a service — three methods, in the order you should actually try them, plus the emergency fallback.

**Status:** Documented per PETPLAT-54's design. **Not yet tested end-to-end** — GitOps with ArgoCD (Epic 17) is not deployed in this repo yet, so "ArgoCD syncs the previous version" cannot be verified until that epic is built. The `kubectl rollout undo` fallback works today, independent of ArgoCD, and is safe to rely on in the meantime.

## Table of Contents

- [Why there are three methods](#why-there-are-three-methods)
- [Method 1: GitOps rollback (primary, once ArgoCD exists)](#method-1-gitops-rollback-primary-once-argocd-exists)
- [Method 2: ArgoCD UI/CLI rollback](#method-2-argocd-uicli-rollback)
- [Method 3: kubectl rollout undo (emergency fallback, works today)](#method-3-kubectl-rollout-undo-emergency-fallback-works-today)
- [Testing this runbook](#testing-this-runbook)

## Why there are three methods

CI never deploys anything — it only builds images and commits a tag (see `docs/technical-spec.md#cicd-pipeline`). That means a "bad deploy" is really just "a bad commit in Git," which gives you two clean, GitOps-native ways to undo it (Methods 1 and 2), plus one direct cluster-level escape hatch that doesn't depend on Git or ArgoCD at all (Method 3) for when you need to act immediately and sort out the Git history afterward.

## Method 1: GitOps rollback (primary, once ArgoCD exists)

### Procedure: Revert a bad image tag commit

**When:** A new image tag was deployed and the service is now broken/degraded.
**Who:** Anyone with push access to `petclinic-platform`.
**Time:** ~2-5 minutes (git revert + ArgoCD's sync interval).

**Steps:**
1. Find the bad commit: `git log --oneline -- helm-values/{service}.yaml`
2. Revert it: `git revert <bad-commit-sha>`
3. Push: `git push origin main`

**Verify:**
- Dev: ArgoCD auto-syncs within its poll interval — check `argocd app get {service}-dev` or the ArgoCD UI shows the reverted tag deployed.
- Prod: sync is manual — run `argocd app sync {service}-prod` (or approve in the ArgoCD UI) after confirming the revert commit is correct.
- `kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name={service}` shows new pods running the previous (good) image tag.

**Rollback (of the rollback):** If the revert itself was wrong, `git revert` the revert commit — same procedure, same direction, no special case.

## Method 2: ArgoCD UI/CLI rollback

### Procedure: Roll back via ArgoCD's own history

**When:** You want to roll back immediately without waiting on a Git revert + sync cycle, or the bad commit isn't a clean single commit to revert.
**Who:** Anyone with ArgoCD access.
**Time:** ~1 minute.

**Steps:**
1. `argocd app history {service}-{env}` — list previous synced revisions.
2. `argocd app rollback {service}-{env} <revision-id>` — or use the ArgoCD UI's "History and Rollback" panel.

**Verify:**
- `argocd app get {service}-{env}` shows the target revision as current.
- `kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name={service}` shows pods on the rolled-back image.

**Rollback (of the rollback):** `argocd app rollback {service}-{env} <the-revision-you-just-left>`.

**Note:** This rolls back what's *running*, but doesn't change Git — the next auto-sync (dev) would just redeploy the bad version again unless you also do Method 1. Treat this as a fast stop-the-bleeding step, not a substitute for fixing Git.

## Method 3: kubectl rollout undo (emergency fallback, works today)

### Procedure: Direct Deployment rollback, bypassing Git and ArgoCD entirely

**When:** ArgoCD is unavailable, or you need to act faster than a Git-based fix allows. This is the one method that already works right now, since it doesn't depend on Epic 17 existing.
**Who:** Anyone with `kubectl` access to the cluster.
**Time:** Seconds.

**Steps:**
1. `kubectl rollout history deployment/{service} -n petclinic-{env}` — list revisions.
2. `kubectl rollout undo deployment/{service} -n petclinic-{env}` — reverts to the previous revision (or add `--to-revision=N` for a specific one).

**Verify:**
- `kubectl rollout status deployment/{service} -n petclinic-{env}` confirms the rollout completed.
- `kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name={service}` shows healthy pods.

**Rollback (of the rollback):** `kubectl rollout undo deployment/{service} -n petclinic-{env}` again reverses it (Kubernetes deployment history works the same way Helm's does — it doesn't erase anything, so undoing an undo is just another undo).

**Important caveat:** if ArgoCD exists and has auto-sync/self-heal enabled (dev's default), it will detect this manual change as drift from Git and revert it back to the bad version on its next reconcile. This method is a genuine emergency-only measure — follow it up with Method 1 (fix Git) as soon as the immediate fire is out, or the bad version will silently come back.

## Testing this runbook

Per PETPLAT-54's acceptance criteria, the intended test is: deploy a bad image → `git revert` → confirm ArgoCD syncs the previous version → confirm the service recovers. **This cannot be executed yet** — it requires ArgoCD to be deployed (Epic 17), which is not yet built in this repo. Once Epic 17 lands, run through Method 1 end-to-end against a real (intentionally broken) test deploy and update this section with the result.
