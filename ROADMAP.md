# Credit Card Scraper Production Roadmap

This roadmap defines the engineering work needed to move the current system to a robust, scalable production posture.

## Prioritization Model

- `P0`: Immediate blockers for safe production operation.
- `P1`: Reliability and scale improvements after first stable production launch.
- `P2`: Security and compliance hardening.
- `P3`: Data/platform maturity and operational excellence.
- `P4`: Developer velocity and release discipline.

## Status Snapshot (2026-02-26)

- [x] `P0.1` First-class Docker artifacts and deployment manifests
- [x] `P0.2` Remove destructive SQLite auto-reset behavior in production paths
- [ ] `P0.3` Add PostgreSQL as first-class backend (core implementation done; full Postgres integration validation pending)
- [x] `P0.4` Admin/API authentication and private-access enforcement
- [ ] `P0.5` Secrets lifecycle hardening (partially done: masking + optional encryption + re-encryption utility; Secret Manager standardization and rotation drill pending)
- [x] `P0.6` Baseline observability
- [ ] `P1.1` Queue-backed job execution model
- [ ] `P1.2` Idempotency and retry policy per job type
- [ ] `P1.3` Isolate long-running scraping from API plane
- [ ] `P1.4` Failure isolation and cancellation semantics
- [ ] `P2.1` RBAC for admin and operational actions
- [ ] `P2.2` Audit logging expansion
- [ ] `P2.3` Secret rotation playbooks and policy
- [ ] `P2.4` Network hardening baseline
- [ ] `P2.5` Dependency scanning and image signing
- [ ] `P3.1` Automated backups and restore drills
- [ ] `P3.2` Data retention and lifecycle policies
- [ ] `P3.3` Migration governance and release safety
- [ ] `P3.4` Load/performance testing program
- [ ] `P3.5` SLOs and alerting policy
- [ ] `P4.1` CI/CD pipeline with gated releases
- [ ] `P4.2` Staging environment parity
- [ ] `P4.3` Release versioning and changelog discipline
- [ ] `P4.4` Change management and operational docs

## P0 - Immediate Production Blockers

### [x] P0.1 First-class Docker artifacts and deployment manifests

- Problem: Production deployment currently depends on ad-hoc, operator-authored Docker artifacts.
- Impact: High setup variance, slower incident recovery, and fragile reproducibility.
- Proposed change: Commit and maintain production-ready `Dockerfile.app`, `Dockerfile.frontend`, `docker-compose.prod.yml`, and reverse-proxy config in-repo with version control and release tagging.
- Owner role: Platform engineer.
- Effort: Medium.
- Risk: Low.
- Dependency: Agreement on base images, ports, and runtime command contract.
- Done criteria: Clean checkout can build API/worker/frontend images and start stack with one documented command path in CI and operator runbooks.

### [x] P0.2 Remove destructive SQLite auto-reset behavior in production paths

- Problem: Legacy behavior can drop/reset SQLite schema on mismatch.
- Impact: Critical data-loss risk in production and dangerous startup side effects.
- Proposed change: Remove/disable destructive reset path in production mode; fail fast with explicit migration error instead.
- Owner role: Backend engineer.
- Effort: Small.
- Risk: Medium.
- Dependency: Migration health checks and clear operator remediation steps.
- Done criteria: No production code path performs `drop_all`/schema reset; startup exits non-zero with clear error when migrations are pending.

### [ ] P0.3 Add PostgreSQL as first-class backend (Plan 2)

- Problem: SQLite-first assumptions limit concurrency and managed-cloud suitability.
- Impact: Limits scaling, durability guarantees, and operational flexibility.
- Proposed change: Validate full PostgreSQL support (`psycopg`), harden Alembic migrations for Postgres, and add tested Postgres deployment profile.
- Owner role: Backend engineer.
- Effort: Medium.
- Risk: Medium.
- Dependency: Cloud SQL integration test environment and migration test matrix.
- Done criteria: Integration test suite passes on Postgres; production migration path documented; rollback procedure verified.

### [x] P0.4 Admin/API authentication and private-access enforcement

- Problem: Access controls are not formalized as a mandatory production gate.
- Impact: Unauthorized access risk to financial and credential-sensitive operations.
- Proposed change: Enforce private/admin-only ingress and authentication at gateway plus API level; define mandatory auth middleware and deployment checks.
- Owner role: Security engineer + backend engineer.
- Effort: Medium.
- Risk: Medium.
- Dependency: Identity provider decision (IAP/basic auth/OIDC) and session/token strategy.
- Done criteria: Unauthenticated access to UI/API is blocked; authorization tests cover protected endpoints; security review sign-off complete.

### [ ] P0.5 Secrets lifecycle hardening

- Problem: Secrets can drift across env files, runtime settings, and operator workflows.
- Impact: Increased leakage probability and difficult emergency rotation.
- Proposed change: Standardize secret sources (Secret Manager or equivalent), remove plaintext secret persistence patterns, and define rotation/expiry runbook.
- Owner role: Security engineer.
- Effort: Medium.
- Risk: Medium.
- Dependency: Secret manager integration and runtime settings sync policy.
- Done criteria: No long-lived secrets stored in git or unmanaged files; rotation drill completed successfully within target time.

### [x] P0.6 Baseline observability

- Problem: Limited structured telemetry across API, worker, scraping jobs, and storage operations.
- Impact: Slow root-cause analysis and poor reliability visibility.
- Proposed change: Add structured logs, request/job correlation IDs, basic metrics (latency/error/job throughput), and error reporting.
- Owner role: Platform engineer.
- Effort: Medium.
- Risk: Low.
- Dependency: Logging backend choice and instrumentation conventions.
- Done criteria: Dashboards show API health, job backlog, job failures, scrape failure rates, and DB/storage errors with alert hooks.

## P1 - Reliability and Scaling

### [ ] P1.1 Queue-backed job execution model

- Problem: DB polling worker loop couples scheduling and execution with limited elasticity.
- Impact: Inefficient scaling, contention under load, and weaker failure handling.
- Proposed change: Introduce queue-backed execution (e.g., Cloud Tasks/Pub/Sub/Celery-compatible queue) with explicit enqueue/dequeue semantics.
- Owner role: Backend engineer + platform engineer.
- Effort: Large.
- Risk: High.
- Dependency: P0 observability and idempotency policy.
- Done criteria: Production jobs are enqueued and consumed through a managed queue with measurable throughput and backlog SLOs.

### [ ] P1.2 Idempotency and retry policy per job type

- Problem: Repeated/replayed jobs can create duplicate side effects and inconsistent state.
- Impact: Data quality issues and hard-to-debug reconciliation failures.
- Proposed change: Add idempotency keys, bounded retries with jitter/backoff, poison-job handling, and deterministic dedupe rules.
- Owner role: Backend engineer.
- Effort: Medium.
- Risk: Medium.
- Dependency: Queue-backed execution design.
- Done criteria: Duplicate enqueue of same idempotency key does not duplicate side effects; retry behavior is test-covered by job type.

### [ ] P1.3 Isolate long-running scraping from API plane

- Problem: Scraping workloads compete with API resources.
- Impact: API latency spikes and unstable user experience during high scrape volume.
- Proposed change: Separate compute/resource classes for scraping workers; reserve API capacity and apply concurrency limits.
- Owner role: Platform engineer.
- Effort: Medium.
- Risk: Medium.
- Dependency: Container resource profiling and autoscaling thresholds.
- Done criteria: API p95 latency remains within target during sustained scraping load tests.

### [ ] P1.4 Failure isolation and cancellation semantics

- Problem: Long-running or stuck tasks can hold resources and block system progress.
- Impact: Queue growth, operator intervention burden, and reduced reliability.
- Proposed change: Add explicit cancellation tokens, heartbeat/timeout enforcement, and per-stage failure boundaries.
- Owner role: Backend engineer.
- Effort: Medium.
- Risk: Medium.
- Dependency: Job state machine cleanup and worker lease/lock design.
- Done criteria: Operators can cancel stuck jobs safely; abandoned workers are recovered automatically without data corruption.

## P2 - Security and Compliance

### [ ] P2.1 RBAC for admin and operational actions

- Problem: Coarse access model cannot safely separate admin, operator, and read-only roles.
- Impact: Excess privilege and audit/compliance gaps.
- Proposed change: Introduce role-based access control for sensitive actions (reparse all, statement edits, runtime settings, credential ops).
- Owner role: Security engineer + backend engineer.
- Effort: Medium.
- Risk: Medium.
- Dependency: Identity integration and authorization policy matrix.
- Done criteria: Role matrix enforced in API and UI; automated tests validate deny/allow behavior.

### [ ] P2.2 Audit logging expansion

- Problem: Insufficient immutable record of who changed what and when.
- Impact: Weak incident forensics and compliance evidence.
- Proposed change: Expand audit trail coverage to auth events, statement mutations, rule changes, reparses, and credential updates.
- Owner role: Backend engineer.
- Effort: Medium.
- Risk: Low.
- Dependency: Centralized logging and retention policy.
- Done criteria: Critical actions emit structured audit entries with actor, target, before/after metadata, and timestamp.

### [ ] P2.3 Secret rotation playbooks and policy

- Problem: Rotation is manual and not standardized per provider.
- Impact: Slow response to compromise and operational mistakes.
- Proposed change: Document and automate periodic and emergency rotation workflows, including validation and rollback steps.
- Owner role: Security engineer.
- Effort: Small.
- Risk: Low.
- Dependency: Secret manager standardization from P0.
- Done criteria: Quarterly rotation drill completed for all high-risk secrets within agreed RTO.

### [ ] P2.4 Network hardening baseline

- Problem: Ingress/egress controls are not fully codified.
- Impact: Increased exposure surface and reduced blast-radius control.
- Proposed change: Enforce private ingress policy, restricted egress, firewall allowlists, and service-to-service identity constraints.
- Owner role: Platform engineer.
- Effort: Medium.
- Risk: Medium.
- Dependency: Final hosting topology for both plans.
- Done criteria: Network policy is codified and validated by automated checks; unauthorized network paths are blocked.

### [ ] P2.5 Dependency scanning and image signing

- Problem: Supply-chain integrity checks are incomplete.
- Impact: Vulnerable dependencies/images can reach production.
- Proposed change: Add SCA/SAST, container image scanning, SBOM generation, and signing/verification in release pipeline.
- Owner role: Platform engineer.
- Effort: Medium.
- Risk: Low.
- Dependency: CI/CD foundation from P4.
- Done criteria: Release pipeline blocks critical vulnerabilities and unsigned images from deployment.

## P3 - Data and Platform Maturity

### [ ] P3.1 Automated backups and restore drills

- Problem: Backup execution and restore confidence may depend on manual effort.
- Impact: Higher recovery risk during incidents.
- Proposed change: Automate scheduled backups for DB and statement archive with periodic restore validation in non-prod.
- Owner role: SRE/platform engineer.
- Effort: Medium.
- Risk: Medium.
- Dependency: Storage and DB retention decisions.
- Done criteria: Backup jobs run on schedule with alerts; restore drill succeeds at least monthly.

### [ ] P3.2 Data retention and lifecycle policies

- Problem: Statement artifacts/logs may grow without enforced retention controls.
- Impact: Rising storage cost and compliance risk.
- Proposed change: Define retention tiers, legal hold exceptions, and lifecycle rules for DB records, files, and logs.
- Owner role: Product + security + platform.
- Effort: Medium.
- Risk: Medium.
- Dependency: Compliance/legal requirements.
- Done criteria: Retention policy approved and technically enforced with auditable deletion behavior.

### [ ] P3.3 Migration governance and release safety

- Problem: Schema changes can be high-risk without strict process controls.
- Impact: Downtime or data inconsistency during upgrades.
- Proposed change: Add migration RFC checklist, forward/backward compatibility rules, preflight checks, and rollback playbooks.
- Owner role: Backend lead.
- Effort: Small.
- Risk: Low.
- Dependency: CI migration tests on SQLite and Postgres.
- Done criteria: Every migration has tested upgrade/downgrade path and approved rollout plan.

### [ ] P3.4 Load/performance testing program

- Problem: Capacity limits and bottlenecks are unknown under realistic production load.
- Impact: Surprise failures during growth or peak periods.
- Proposed change: Build repeatable load tests for API, worker throughput, scrape concurrency, and storage access patterns.
- Owner role: Performance engineer/platform engineer.
- Effort: Medium.
- Risk: Medium.
- Dependency: Stable staging environment and observability baseline.
- Done criteria: Performance budgets defined and tested; bottlenecks tracked to resolution.

### [ ] P3.5 SLOs and alerting policy

- Problem: No formal reliability objectives tied to paging thresholds.
- Impact: Reactive operations and alert fatigue.
- Proposed change: Define service-level objectives for availability, latency, and job completion; wire alerting to SLO error budgets.
- Owner role: SRE lead.
- Effort: Medium.
- Risk: Low.
- Dependency: Metrics instrumentation and incident process maturity.
- Done criteria: SLO dashboards and alert rules active with documented on-call response policy.

## P4 - Developer Velocity and Delivery

### [ ] P4.1 CI/CD pipeline with gated releases

- Problem: Build/test/deploy flow is not fully automated and standardized.
- Impact: Slower delivery and increased manual release risk.
- Proposed change: Implement CI/CD pipeline with lint/test/security/migration gates, image build/publish, and environment promotions.
- Owner role: Platform engineer.
- Effort: Medium.
- Risk: Medium.
- Dependency: P0 Docker artifacts and test coverage baseline.
- Done criteria: Every merge to release branch produces traceable artifact and controlled deploy path with approvals.

### [ ] P4.2 Staging environment parity

- Problem: Pre-production may not mirror production topology and controls.
- Impact: Undetected environment-specific failures.
- Proposed change: Maintain staging with same service decomposition, auth model, DB engine class, and storage patterns as production.
- Owner role: Platform engineer.
- Effort: Medium.
- Risk: Medium.
- Dependency: Infrastructure-as-code and budget allocation.
- Done criteria: Release candidates pass staging smoke/perf/security checks before production promotion.

### [ ] P4.3 Release versioning and changelog discipline

- Problem: Runtime state and deployment versions can be hard to correlate.
- Impact: Slower rollback and poor change traceability.
- Proposed change: Adopt semantic versioning, release notes template, and revision metadata surfaced in API/UI diagnostics.
- Owner role: Engineering manager + backend lead.
- Effort: Small.
- Risk: Low.
- Dependency: CI/CD metadata injection.
- Done criteria: Each production deploy maps to versioned tag, changelog entry, and reproducible artifact digest.

### [ ] P4.4 Change management and operational docs

- Problem: Operational knowledge is concentrated and not fully standardized.
- Impact: Onboarding friction and higher incident response variance.
- Proposed change: Formalize runbooks, ownership matrix, escalation paths, and maintenance windows in a living ops handbook.
- Owner role: Engineering manager + SRE.
- Effort: Small.
- Risk: Low.
- Dependency: Stabilized runbooks from P0-P3.
- Done criteria: Operator can execute common maintenance and incident flows using documentation only.

## Suggested Delivery Sequence

1. Complete all `P0` items before broad production onboarding.
2. Start `P1` queue/idempotency work immediately after first stable production milestone.
3. Parallelize selected `P2` controls with `P1` where dependencies allow.
4. Use `P3` SLO/load-testing outcomes to drive scaling and cost optimization.
5. Institutionalize with `P4` so releases become routine and auditable.
