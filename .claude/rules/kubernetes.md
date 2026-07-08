---
paths:
  - "k8s/**/*.yaml"
  - "k8s/**/*.yml"
---

# Kubernetes Rules

## Directory Structure

```
k8s/
├── base/                     # Shared manifests (all environments)
│   ├── namespaces.yaml       # Namespace definitions
│   ├── {service-name}/       # One directory per service
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── configmap.yaml    # If needed
│   ├── ingress/              # ALB Ingress Controller
│   └── external-secrets/     # ExternalSecret CRs
└── overlays/
    ├── dev/                  # Dev patches: 1 replica, smaller resources
    └── prod/                 # Prod patches: 2+ replicas, HPA, larger resources
```

## Required Labels

Every Kubernetes resource MUST include these labels:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: {service-name}
    app.kubernetes.io/part-of: petclinic
    app.kubernetes.io/managed-by: kubectl
    app.kubernetes.io/component: {backend|frontend|infrastructure}
```

## Deployment Requirements

Every Deployment MUST include:

1. **Health probes** using Spring Boot Actuator. Use a `startupProbe`, not a fixed `initialDelaySeconds`, since Spring Boot startup time varies (observed 68-76s in real testing) — a fixed delay risks killing a pod that's still booting, not actually broken:
   ```yaml
   startupProbe:
     httpGet:
       path: /actuator/health
       port: http
     periodSeconds: 10
     failureThreshold: 30   # up to 5 min for Spring Boot to boot
   readinessProbe:
     httpGet:
       path: /actuator/health/readiness
       port: http
     periodSeconds: 10
     failureThreshold: 3
   livenessProbe:
     httpGet:
       path: /actuator/health/liveness
       port: http
     periodSeconds: 15
     failureThreshold: 3
   ```

2. **Resource requests and limits** (memory request reflects real observed Spring Boot usage, ~350-390MiB idle — not a low placeholder that would cause node memory-pressure evictions):
   ```yaml
   resources:
     requests:
       memory: "384Mi"
       cpu: "100m"
     limits:
       memory: "512Mi"
       cpu: "400m"
   ```

3. **Image with SHA tag** (never `latest`):
   ```yaml
   image: {account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic/{service}:{sha}
   ```

## Service Startup Order

Config Server MUST start before all other services. Discovery Server MUST start before application services.

Use init containers to wait for dependencies:
- All services (except config-server): wait for config-server:8888
- Application services: wait for discovery-server:8761

## Secrets

- NEVER put secrets directly in YAML manifests
- Use ExternalSecret CRs that reference AWS Secrets Manager
- Mount secrets as environment variables, not files (unless certificates)

## Namespaces

- Dev: `petclinic-dev`
- Prod: `petclinic-prod`
- All resources MUST specify their namespace explicitly

## Overlay Patterns

Dev overlay: single replica, smaller resource requests, relaxed probes
Prod overlay: 2+ replicas, HPA, full resource limits, strict probes
