# Database Initialization Strategy

**Last Updated:** 2026-06-22
**Purpose:** Defines how the shared `petclinic` MySQL database schemas are initialized for the three database-backed services.

## Strategy: Spring Boot Auto-Initialization

Spring Boot initializes schemas automatically on first startup using `spring.sql.init.mode=always` with the `mysql` profile active. No manual SQL execution or init containers required.

Each service's `src/main/resources/db/mysql/` contains:
- `schema.sql` — `CREATE DATABASE IF NOT EXISTS petclinic; USE petclinic;` + table definitions
- `data.sql` — seed data (types, sample owners, vets, specialties)

## Shared Database

All three services connect to the **same** `petclinic` database on a single RDS instance:

```
jdbc:mysql://{rds-endpoint}:3306/petclinic
```

## Schema Initialization Order

The `visits` table has `FOREIGN KEY (pet_id) REFERENCES pets(id)`, which is in the customers service schema. Deployment order matters:

1. **customers-service** — creates `types`, `owners`, `pets`
2. **vets-service** — creates `vets`, `specialties`, `vet_specialties` (independent)
3. **visits-service** — creates `visits` (depends on `pets` from step 1)

This order is enforced by Kubernetes init containers that wait for upstream services.

## Tables (7 total)

| Service | Tables | Foreign Keys |
|---------|--------|-------------|
| customers-service | `types`, `owners`, `pets` | `pets.owner_id` → `owners.id`, `pets.type_id` → `types.id` |
| vets-service | `vets`, `specialties`, `vet_specialties` | `vet_specialties.vet_id` → `vets.id`, `vet_specialties.specialty_id` → `specialties.id` |
| visits-service | `visits` | `visits.pet_id` → `pets.id` (cross-service FK) |

## Connection Configuration

Services receive database credentials via Kubernetes environment variables sourced from ExternalSecret CRs pointing to AWS Secrets Manager:

```
SPRING_DATASOURCE_URL=jdbc:mysql://{rds-endpoint}:3306/petclinic
SPRING_DATASOURCE_USERNAME={from secret}
SPRING_DATASOURCE_PASSWORD={from secret}
SPRING_PROFILES_ACTIVE=docker,mysql
```
