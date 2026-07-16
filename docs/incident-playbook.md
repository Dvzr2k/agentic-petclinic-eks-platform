# Incident Playbook

**Last Updated:** 2026-07-12

**Purpose:** Real incidents actually encountered and resolved while building this
platform — not hypothetical scenarios. Each one follows the same format: what
broke, how it was noticed, why it happened, and the exact fix. Kept here so the
same mistake doesn't get re-diagnosed from scratch next time, and as an honest
record of the debugging that went into this project.

## Table of Contents

1. [EKS nodes locked out of their own control plane](#1-eks-nodes-locked-out-of-their-own-control-plane)
2. [NetworkPolicy rollout broke config-server's GitHub access](#2-networkpolicy-rollout-broke-config-servers-github-access)
3. [LB controller IAM trust policy goes stale on every cluster rebuild](#3-lb-controller-iam-trust-policy-goes-stale-on-every-cluster-rebuild)
4. [RDS credentials secret blocks recreation after destroy](#4-rds-credentials-secret-blocks-recreation-after-destroy)
5. [Destroying EKS before the Ingress orphans the ALB](#5-destroying-eks-before-the-ingress-orphans-the-alb)
6. [KMS migration silently broke image pulls and CI pushes](#6-kms-migration-silently-broke-image-pulls-and-ci-pushes)
7. [Plaintext secrets leaking through Terraform plan files](#7-plaintext-secrets-leaking-through-terraform-plan-files)
8. [Terraform state lock blocks a second concurrent command](#8-terraform-state-lock-blocks-a-second-concurrent-command)
9. [EC2 vCPU quota silently blocks Karpenter from scaling](#9-ec2-vcpu-quota-silently-blocks-karpenter-from-scaling)
10. [Dead pre-Helm manifests silently drifting from real config](#10-dead-pre-helm-manifests-silently-drifting-from-real-config)
11. [Karpenter's post-install hook permanently broken by a discontinued image](#11-karpenters-post-install-hook-permanently-broken-by-a-discontinued-image)

---

## 1. EKS nodes locked out of their own control plane

**When:** After restricting the EKS API endpoint to a specific IP range (security fix HIGH-002)
**Symptom:** New EC2 instances launch and show `InService`/`Healthy` in the ASG, but never appear in `kubectl get nodes`. Karpenter can never successfully add capacity either.
**Root cause:** `endpoint_private_access` was `false`, with only the public endpoint enabled. Restricting `public_access_cidrs` to an admin's IP also blocked the *nodes themselves* — nodes reach the control plane via the public endpoint when private access is off, and a node's own IP was never in that admin-only CIDR list.

**Fix:**
```hcl
# terraform/modules/eks/main.tf
vpc_config {
  endpoint_public_access  = true
  endpoint_private_access = true   # was false — this is the actual fix
  public_access_cidrs     = var.public_access_cidrs
}
```
Nodes (already inside the VPC) get a path via the private endpoint that isn't subject to the public CIDR restriction; humans still use the restricted public path.

**Verify:** New EC2 instances register as `Ready` nodes within seconds of the apply completing.

---

## 2. NetworkPolicy rollout broke config-server's GitHub access

**When:** While applying default-deny NetworkPolicies across all namespaces (security fix MED-003)
**Symptom:** `config-server` pod stuck restarting on liveness-probe failure. Logs show `Connect timed out` trying to reach `github.com:443`.
**Root cause:** config-server is Git-backed (fetches its config from GitHub on startup and refresh) — the only one of 8 services that needs real internet egress. The default-deny rollout didn't include an internet-egress allowance for it, since none of the other services need one.

**Fix:** Added a dedicated NetworkPolicy allowing config-server egress to `0.0.0.0/0` (except the VPC CIDR) on port 443, same pattern already used for `genai-service`'s OpenAI API access.

**Verify:** `kubectl get pods -n petclinic-dev -l app.kubernetes.io/name=config-server` shows `1/1 Running` with 0 restarts after the fix.

**Lesson:** Before rolling out a default-deny policy, check *every* service's actual dependencies individually — don't assume they're all the same shape just because 7 of 8 are.

---

## 3. LB controller IAM trust policy goes stale on every cluster rebuild

**When:** Every time the EKS cluster gets destroyed and recreated
**Symptom:** Ingress fails with `AssumeRoleWithWebIdentity AccessDenied` immediately after a fresh cluster comes up.
**Root cause:** `install-lb-controller.sh` creates the IAM role via `aws iam create-role`, but falls back to `get-role` (no update) if it already exists — and it always already exists, since it isn't deleted by `terraform destroy` on EKS. Its trust policy still points at the *previous* cluster's OIDC provider, which no longer exists.

**Fix (not automatable in code — the role's identity is external to Terraform):**
```bash
NEW_OIDC=$(aws eks describe-cluster --name petclinic-dev --region eu-central-1 \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')
# rebuild trust policy JSON with $NEW_OIDC, then:
aws iam update-assume-role-policy --role-name petclinic-dev-lb-controller-role --policy-document file://trust.json
kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system
```

**Verify:** Check `kubectl describe ingress petclinic-ingress -n petclinic-dev` for `WebIdentityErr`/`AccessDenied` events immediately after any rebuild — this is the first thing to check, not a new bug each time.

---

## 4. RDS credentials secret blocks recreation after destroy

**When:** Recreating RDS after a `terraform destroy`
**Symptom:** `terraform apply` fails trying to create `aws_secretsmanager_secret.rds_credentials` — it already exists, in pending-deletion state.
**Root cause:** Secrets Manager soft-deletes by default (30-day recovery window). Destroying the RDS module doesn't remove that limbo state.

**Fix:**
```bash
aws secretsmanager delete-secret --secret-id petclinic/dev/rds-credentials \
  --force-delete-without-recovery --region eu-central-1
```
Run this immediately after destroying RDS, before ever trying to recreate it.

---

## 5. Destroying EKS before the Ingress orphans the ALB

**When:** Tearing down an environment
**Symptom:** The ALB keeps costing money even after `terraform destroy` on the EKS module reports success — it's nowhere in Terraform state.
**Root cause:** The ALB is created by the in-cluster AWS Load Balancer Controller in response to the Kubernetes `Ingress` object, not by Terraform. Destroying EKS before deleting the Ingress removes the controller before it ever gets a chance to clean up the ALB it created.

**Fix — order matters:**
```bash
kubectl delete -f k8s/base/ingress/ingress.yaml
# wait for the ALB to actually disappear before continuing
aws elbv2 describe-load-balancers --region eu-central-1  # should return empty
# only then:
terraform destroy ... # (or targeted destroy of module.eks)
```

---

## 6. KMS migration silently broke image pulls and CI pushes

**When:** After switching ECR repositories and Secrets Manager secrets from AWS-default encryption to customer-managed KMS keys (Checkov hardening pass)
**Symptom (would have appeared on the next real cluster use):** Node role loses the ability to pull images; CI role loses the ability to push them. Neither role had ever needed KMS permissions before.
**Root cause:** The AWS-managed default key handles authorization implicitly through the service's own IAM permissions. A customer-managed key requires the caller to *also* have explicit `kms:Decrypt`/`kms:Encrypt` permission on that specific key — nothing grants that automatically just because a role can already push/pull.

**Fix:** Added a scoped IAM statement to both roles, using `kms:ViaService` to restrict it so the permission only works when the KMS call originates from ECR itself (not a direct, unrelated KMS call):
```hcl
{
  Effect   = "Allow"
  Action   = "kms:Decrypt"
  Resource = "*"
  Condition = {
    StringEquals = { "kms:ViaService" = "ecr.eu-central-1.amazonaws.com" }
  }
}
```

**Lesson:** Any encryption-target change (default key → CMK) needs an audit of *every* role that reads/writes that resource, not just the resource's own config.

---

## 7. Plaintext secrets leaking through Terraform plan files

**When:** Discovered during a security audit, in `terraform/environments/dev/*.plan` files sitting on disk
**Symptom:** `terraform show -json destroy.plan | grep password` returned the real RDS master password in plaintext.
**Root cause:** `sensitive = true` only masks a value in Terraform's own CLI *output* — it does not encrypt or redact it inside a saved plan file. Anyone with read access to a `.plan` file can extract every real value via `terraform show -json`, regardless of `sensitive` markings.

**Fix:** Deleted all exposed `.plan` files, added `*.plan` to both `.gitignore` and the `block-secret-commit.sh` hook's detection patterns (previously only caught `.tfplan`, not the non-standard `.plan` extension this project happened to use).

**Lesson:** `sensitive = true` is a display filter, not encryption. Treat any Terraform plan file as if it contains every real secret value in the configuration, because it does.

---

## 8. Terraform state lock blocks a second concurrent command

**When:** Running a `terraform apply`/`destroy` in one terminal while starting another Terraform command against the same state in a different terminal
**Symptom:**
```
Error: Error acquiring the state lock
ConditionalCheckFailedException: The conditional request failed
```
**Root cause:** This is the DynamoDB lock table working exactly as designed — not a bug, a genuine safety mechanism preventing two operations from corrupting the same state file at once.

**Fix:** Not `terraform force-unlock` — that's for a genuinely abandoned lock (a terminal that got closed mid-apply). If the other operation is actually still running, the only correct fix is to wait for it to finish; the lock releases automatically on completion.

**How to tell the difference:** Check whether the resource the other operation was touching has actually finished changing state in AWS (e.g., `aws rds describe-db-instances` still shows `deleting`). If it's still actively changing, the lock is real and legitimate — don't force it.

---

## 9. EC2 vCPU quota silently blocks Karpenter from scaling

**When:** During live Karpenter scale-up testing
**Symptom:** A pod stays stuck `Pending` indefinitely. Karpenter's own logs show it trying and failing to provision a node, with an EC2 API error mentioning `VcpuLimitExceeded`.
**Root cause:** The account's EC2 vCPU service quota was 16. The *static* managed node group (8 `t4g.small` nodes at the time) was already consuming the entire quota by itself, leaving zero headroom for Karpenter to launch anything new — Karpenter wasn't broken, there was simply no vCPU allowance left in the account for it to use.

**Fix:** Scaled the static node group down (8 → 6 nodes) to free up quota headroom. Karpenter successfully provisioned a new node on the next attempt, no config changes needed — the NodePool/EC2NodeClass were correct the whole time.

**Lesson:** A capacity-provisioning failure isn't always a Kubernetes/Karpenter config problem — check the account-level AWS service quota first, especially in a learning account that hasn't had quotas raised from their defaults.

---

## 10. Dead pre-Helm manifests silently drifting from real config

**When:** Found during a routine security audit (4th round), not during a deployment
**Symptom:** No live failure — this was a *latent* risk, not an active incident. `k8s/base/{config-server,customers-service,...}/` directories still existed, containing the original raw `Deployment`/`Service`/`ConfigMap` manifests from before the Helm chart migration — still with the old insecure setting (`readOnlyRootFilesystem: false`) and a frozen `v1.0.0` image tag that CI never updates.
**Root cause:** When the project migrated to Helm + ArgoCD, these old manifests were never deleted — just left in place, unreferenced by any ArgoCD Application, but still reachable via `kubectl apply -k k8s/overlays/dev` (which pulled in `../../base`). Every security fix made afterward (like the `readOnlyRootFilesystem` fix) was applied to the *real* Helm chart, but this dead parallel copy was never touched, so it silently drifted further out of sync with every fix that came after it.

**Why it mattered even though nothing was actively broken:** applying that Kustomize overlay — even by habit, or as part of a disaster-recovery attempt — would have **silently overwritten the real, Helm-managed Deployments with the old insecure, stale-image version**, since the object names matched exactly. In prod specifically (no ArgoCD self-heal), that overwrite would have stayed in place until someone happened to notice.

**Fix:** Deleted all 33 dead manifest files, then removed the now-pointless `../../base` reference and the `images`/`replicas`/`patches` blocks from both `kustomization.yaml` files — keeping only what those overlays still genuinely needed (`ResourceQuota`, `LimitRange`, and prod's `HPA`/`PDB`). Verified via `kubectl kustomize` that both overlays render *only* those objects afterward.

**Lesson:** A migration to a new deployment mechanism (Helm, in this case) isn't complete until the *old* mechanism's artifacts are actually removed — "unused" and "harmless" are not the same thing if the old path can still technically be triggered.

---

## 11. Karpenter's post-install hook permanently broken by a discontinued image

**When:** Recreating dev from scratch after a full destroy/apply cycle, installing Karpenter via Helm
**Symptom:** `helm upgrade --install karpenter ...` never completes — the release sits at `pending-install` indefinitely. Killing and retrying the command reproduces the same hang every time, even though the Karpenter controller pods themselves show `Running`/`1/1` the whole time.
**Root cause:** The chart's post-install hook is a Job that runs `public.ecr.aws/bitnami/kubectl:1.30@sha256:13a2ad1bd37ce42ee2a6f1ab0d30595f42eb7fe4a90d6ec848550524104a1ed6` to patch two CRDs (`nodepools.karpenter.sh`, `nodeclaims.karpenter.sh`) with webhook-conversion config. That image fails to pull with `401 Unauthorized`/`not found` — checking the registry directly (`curl https://public.ecr.aws/v2/bitnami/kubectl/tags/list`) shows the entire repository has **zero tags**. Broadcom (which owns Bitnami via the VMware acquisition) discontinued most free Bitnami container images in 2025; this isn't a transient outage, the image is permanently gone. Helm's `--wait` behavior blocks the release from being marked `deployed` until every hook Job succeeds, so it hangs forever on a Job that can never succeed.

**Fix:** Skip the hook and apply what it would have done directly — no third-party image involved at all:
```bash
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.0.0 --namespace kube-system --no-hooks \
  --set settings.clusterName=<cluster_name> \
  --set settings.interruptionQueue=<karpenter_queue_name> \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<karpenter_role_arn>

kubectl patch customresourcedefinitions nodepools.karpenter.sh --type='merge' \
  -p '{"spec":{"conversion":{"strategy":"Webhook","webhook":{"conversionReviewVersions":["v1beta1","v1"],"clientConfig":{"service":{"name":"karpenter","port":8443,"namespace":"kube-system"}}}}}}'
kubectl patch customresourcedefinitions nodeclaims.karpenter.sh --type='merge' \
  -p '{"spec":{"conversion":{"strategy":"Webhook","webhook":{"conversionReviewVersions":["v1beta1","v1"],"clientConfig":{"service":{"name":"karpenter","port":8443,"namespace":"kube-system"}}}}}}'
```
If a release is already stuck from a prior attempt, clear it first: `kubectl delete secret sh.helm.release.v1.karpenter.v1 -n kube-system` (safe — the underlying Kubernetes resources it tracked are untouched by deleting Helm's own bookkeeping secret).

**Verify:** `helm list -n kube-system` shows `karpenter` with `STATUS: deployed`, not `pending-install`.

**Lesson:** A pinned third-party image (even by digest, even from a name-brand vendor) is an external dependency that can disappear entirely, not just drift. Don't chase a replacement image when the alternative — doing the two lines of actual work the hook performs, with tools already in the cluster — removes the dependency instead of relocating it.
