# ADR-0011: In-cluster logging (Loki) over CloudWatch Logs

**Status:** Accepted

## Context

Centralized log aggregation was needed so logs from all 8 services survive pod restarts and
rescheduling. The original plan (`PETPLAT-61` in `docs/jira-backlog.md`) was AWS-native:
CloudWatch Logs, fed by FluentBit running with its own IRSA role to call the CloudWatch API —
the same IRSA pattern already used by ESO, Karpenter, and the LB Controller.

## Decision

Use an in-cluster logging stack instead: **Loki** for storage, fed by **FluentBit** forwarding
directly to `http://loki.monitoring:3100` — no AWS API calls involved. `PETPLAT-61` was
removed from scope entirely; its acceptance criteria for `PETPLAT-59` states this explicitly:
*"No IRSA role required — Loki is in-cluster."*

## Consequences

**Gained:**
- One fewer IRSA role in the account, directly reinforcing this project's actual security
  principle: only things that genuinely need to talk to AWS get an IRSA role. Logging
  entirely within the cluster means FluentBit needs zero AWS permissions at all.
- No CloudWatch ingestion/storage costs — relevant for a project already optimized hard for
  low cost.
- Logs and metrics live in one UI (Grafana, alongside Prometheus) instead of splitting the
  "where do I look" question across the AWS Console and a separate dashboard tool.

**Given up / accepted risk:**
- Log durability is tied to the cluster's own lifecycle — Loki's data lives on a
  PersistentVolume inside the cluster, so destroying the EKS cluster (which this project's
  dev environment does routinely, for cost) destroys that volume's log history with it.
  CloudWatch Logs would have persisted independently of the cluster's lifecycle — a real
  tradeoff, not just a theoretical one, given how often dev gets torn down here.
- No built-in cross-account or multi-cluster log aggregation — if this project ever grew
  beyond two clusters, CloudWatch's centralization would start to matter more than it does
  today.
