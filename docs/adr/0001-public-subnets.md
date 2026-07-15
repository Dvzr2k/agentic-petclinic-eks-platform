# ADR-0001: All-public subnets, no NAT Gateway

**Status:** Accepted

## Context

A standard "production-correct" VPC design puts compute and data resources (EKS nodes, RDS)
in private subnets, reachable only through a NAT Gateway for outbound internet access. A NAT
Gateway costs a fixed hourly rate plus per-GB data processing charges — for an environment
that gets destroyed and recreated frequently (this project's dev environment, for cost
reasons), that's a recurring cost paid again on every rebuild for a control that a different
mechanism can also provide.

## Decision

All resources — EKS nodes, RDS, the ALB — live in public subnets. No NAT Gateway exists
anywhere in this project. Network access control is enforced entirely through **security
groups**: deny-all by default, with only the specific ports and source security groups that
are actually needed explicitly allowed (e.g., RDS's security group only accepts port 3306
from the EKS node security group, not from `0.0.0.0/0`).

## Consequences

**Gained:**
- Zero NAT Gateway cost, in an account that gets rebuilt often for a learning/portfolio
  project — this was the deciding factor.
- One less moving part during environment teardown/recreation (no NAT Gateway lifecycle to
  manage, no Elastic IP to release/reallocate).

**Given up / accepted risk:**
- Resources technically have public IPs, which is a real deviation from typical enterprise
  practice — a misconfigured security group here is a more direct exposure than the same
  mistake in a private-subnet design, where the NAT boundary would still exist as a second
  layer.
- This tradeoff is acceptable specifically *because* it's a learning/portfolio environment
  with no real customer data — it would need revisiting before handling anything sensitive.
- Security groups become the single enforcement point, so they were treated as the real
  perimeter throughout this project (see the security-auditor rounds and `PETPLAT-71` in
  `docs/jira-backlog.md`), not an afterthought layered on top of network isolation.
