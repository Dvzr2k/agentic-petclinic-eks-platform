# ADR-0003: One shared RDS instance, not one database per service

**Status:** Accepted

## Context

Three of the eight services — `customers-service`, `visits-service`, `vets-service` — need a
MySQL database. The "textbook" microservices pattern is one database per service, each fully
isolated. But the actual data model, inherited from the upstream Spring Petclinic application,
has a real foreign-key relationship across that boundary: `visits.pet_id` references `pets.id`,
and `pets` lives in `customers-service`'s schema. That relationship isn't something this
project introduced — it's how the application itself is built.

## Decision

A single shared RDS MySQL instance serves all three database-backed services, one instance per
environment (`petclinic-dev`, `petclinic-prod`). Each service still owns its own tables/schema
logically; they just share the same physical instance rather than each getting a separate one.

## Consequences

**Gained:**
- The `visits → pets` foreign key works as a real, enforced relational constraint — no
  eventual-consistency workaround, no cross-service join logic, no distributed-transaction
  handling for something that's fundamentally a single relational query.
- Simpler operations: one instance to size, back up, monitor, and apply the KMS/TLS/enhanced-
  monitoring hardening to (`terraform/modules/rds/`), instead of three.
- Lower cost — one `db.t4g.micro` instance instead of three, relevant for a project already
  optimizing hard for free-tier/low-cost operation.

**Given up / accepted risk:**
- Blast radius: an RDS outage or maintenance window affects all three domain services at
  once, not just one — the services aren't as independently deployable/scalable at the data
  layer as pure microservices doctrine would prescribe.
- Schema coupling: a breaking schema change in one service's tables carries more risk of
  affecting a neighbor than it would with full physical isolation.
- This is a deliberate compromise driven by the application's actual data model, not a
  default — if the FK relationship didn't exist, one-database-per-service would be the
  better default choice.
