# Dashboard Backend — Spring Boot + GCP Cloud Run

Production-grade **Java 21 / Spring Boot 4** REST API delivering sub-second responses across
4 million orders: full-text search, pre-aggregated analytics tables, serverless autoscaling,
and declarative Pulumi IaC on GCP. Supports both Cloud Run and GKE as backend runtimes with
container images stored in Artifact Registry (analogous to ECR + ECS/EKS in AWS deployments).

**[→ Portfolio demo](https://bganguly.github.io/?open=dashboard)**

## Using the App

1. **Search** — type in the search bar to query across all columns (name, notes, total, order ID, status, region, date) via GIN trigram index; sub-second on 4 M+ rows.
2. **Filter** — use the sidebar to narrow by status, region, date range, or total amount.
3. **Aggregates chart** — the chart shows daily orders by product category; drag the brush to zoom into any date window.

---

| Component | Implementation |
|---|---|
| **Java / Spring Boot back-end** | Spring Boot 4, Java 21, NamedParameterJdbcTemplate, Flyway |
| **PostgreSQL — SQL, DML/DDL, performance tuning** | GCE VM Postgres 16; Flyway DDL migrations; GIN index; pre-aggregated summary tables for sub-second chart queries on 4 M rows |
| **Serverless / cloud-native computing** | Cloud Run (default) or GKE — images in Artifact Registry; min-instances: 0, scales to zero, Direct VPC Egress to private Postgres; toggled via `BACKEND_RUNTIME` |
| **IaC (Terraform equivalent)** | Pulumi TypeScript (`infra/index.ts`) — VPC, GCE Postgres VM, Cloud Run service, IAM, Secret Manager, Artifact Registry all declared |
| **CI/CD pipelines** | `deploy.sh` — build → push to Artifact Registry → `pulumi up --yes`; auto bake via ephemeral GCE VM when DB is empty |
| **Secrets management** | GCP Secret Manager; `DATABASE_URL` injected at runtime via `secretKeyRef`, never stored in image or env file |
| **Networking, storage, DB architecture** | Private VPC, Direct VPC Egress, GCE VM Postgres on private IP (VPC firewall rules), pg-SSD boot disk |
| **BFF / integration layer** | Nginx frontend proxies `/api/*` to Cloud Run backend (TLS + SNI); Spring Boot orchestrates REST + DB |
| **RESTful APIs / microservices** | Two independent Cloud Run services; paginated list endpoint + aggregates endpoint |
| **Performance optimization** | Sub-second ILIKE search on 4 M rows via GIN index; pre-aggregated daily tables cut chart query time from seconds to milliseconds |
| **System design diagrams** | See architecture section below |

---


## Scale & Performance

> **4 M+ orders** in Cloud SQL PostgreSQL 16 — sub-second full-text search via GIN index on a denormalized `search_text` column; millisecond chart aggregates via pre-aggregated summary tables; zero sequential scans on the hot path.

```
Browser ──HTTPS──► Nginx / Cloud Run ──proxy /api/* (SNI)──► Spring Boot (CR or GKE) ──VPC──► GCE VM: Postgres 16
                   dash-frontend                             dash-backend                             dash-pg
                   0–3 instances                            CR: 0–5 / GKE: 1 pod                    4 M+ rows · GIN index
                                    ▲─────────────── Pulumi TypeScript IaC ──────────────────────────▲
```

---

## Running

```bash
./scripts/deploy.sh      # local [1] or GCP [2]
./scripts/infra-down.sh  # stop local [1] or teardown GCP [2]
./scripts/scale.sh       # interactive menu — scale up/down, pause/resume schedule
```

`./scripts/deploy.sh` prompts for local or GCP on every run:

```
./scripts/deploy.sh
  [1] Local  — starts Spring Boot on :8080 (uses local PG from .env)
  [2] GCP    — docker build → push to Artifact Registry → pulumi up --yes
                 provisions VPC · GCE Postgres VM · Cloud Run backend · Secret Manager
                 auto-restores demo snapshot from GCS if orders table is empty
```

### Cost control — scheduled 8am–5pm Pacific window (weekdays)

Both Cloud Run and GKE backends auto-scale on a weekday schedule managed by Cloud Scheduler:

| Runtime | Scale-up | Scale-down | Idle cost |
|---|---|---|---|
| **Cloud Run** | min-instances → 1 at 8am | min-instances → 0 at 5pm | ~$0 (scales to zero) |
| **GKE** | node pool → 1 at 8am | node pool → 0 at 5pm | ~$0 (no nodes running) |

`./scripts/scale.sh` detects the active runtime automatically and shows an interactive prompt:

```
=== scale.sh — dash-lite (GKE · nodes=1) ===

  [1] Scale up now    — bring backend online immediately
  [2] Scale down now  — stop node / drop to zero (saves cost)
  [3] Pause schedule  — disable the 8am/5pm auto-schedule
  [4] Resume schedule — re-enable the 8am/5pm auto-schedule

Choice [1/2/3/4]:
```

One-liners still work: `TIER=lite ./scripts/scale.sh up` / `down`

---

## Live Service

> **Schedule:** Cloud Run scales to zero on a Cloud Scheduler weekday schedule (8 am – 5 pm PT). Outside those hours the app is offline; first request after 8 am may cold-start (~5–10 s).

| | URL |
|---|---|
| **App** | https://dash-lite-frontend-77y7e2wykq-uc.a.run.app |
| **Backend API (direct)** | http:// |

```bash
# local
BASE=https://dash-lite-frontend-77y7e2wykq-uc.a.run.app
curl "$BASE/actuator/health"
curl "$BASE/api/orders?page=1&size=3" | jq .total
curl "$BASE/api/orders?q=sara+carter&page=1&size=3" | jq '.data[].customer'

# GCP — via frontend proxy (same as browser / API explorer)
BASE=https://dash-lite-frontend-77y7e2wykq-uc.a.run.app
curl "$BASE/api/orders?page=1&size=3" | jq .total
```

---

## Architecture

### Search & chart request flow — step by step

1. **Browser → Nginx frontend** — the React UI sends `GET /api/orders?q=sara` to the Cloud Run frontend service (Nginx on port 80), which proxies the `/api/*` path upstream to the Spring Boot backend over HTTPS with SNI.
2. **Spring Boot → GIN search** — Spring Boot issues `SELECT * FROM orders WHERE search_text ILIKE '%sara%'` against the GCE Postgres VM; the GIN index on the denormalized `search_text` column (name + notes + total + id + status + region + date) returns sub-second results across 4 M rows without a sequential scan.
3. **Chart path** — `GET /api/aggregates` is served entirely from pre-aggregated `daily_summary` and related rollup tables; Spring Boot never touches raw `orders` on the chart path.
4. **Secret injection** — Spring Boot reads `DATABASE_URL` from GCP Secret Manager at container start via `secretKeyRef`; no credentials are stored in the image or env files.
5. **Results → browser** — Spring Boot returns paginated JSON; the React frontend renders the orders table and Recharts chart.

```mermaid
sequenceDiagram
    participant B as Browser
    participant FE as Cloud Run Frontend (Nginx)
    participant SB as Spring Boot (Cloud Run / GKE)
    participant PG as GCE Postgres 16

    B->>FE: GET /api/orders?q=sara
    FE->>SB: proxy (HTTPS + SNI)
    SB->>PG: SELECT * FROM orders WHERE search_text ILIKE '%sara%' (GIN index)
    PG-->>B: paginated orders

    B->>FE: GET /api/aggregates
    FE->>SB: proxy
    SB->>PG: SELECT from daily_summary (pre-agg tables)
    PG-->>B: chart data
```

### Topology

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              GCP Project                                │
│                                                                         │
│   Artifact Registry                                                     │
│   ┌──────────────────┐                                                  │
│   │  frontend image  │                                                  │
│   │  backend image   │                                                  │
│   └──────────────────┘                                                  │
│           │ image pull                  Pulumi TypeScript (IaC)         │
│           ▼                             manages all resources below     │
│   ┌───────────────────────────────────────────────────────────────┐     │
│   │                       dash-vpc (private)                      │     │
│   │                                                               │     │
│   │  Cloud Run: dash-frontend      dash-backend (CR or GKE)      │     │
│   │  ┌─────────────────────────┐   ┌────────────────────────┐    │     │
│   │  │ Nginx (port 80)         │   │ Spring Boot (8080)     │    │     │
│   │  │ • serves Vite dist      │ HTTPS • REST /api/*        │    │     │
│   │  │ • proxies /api/* ───────┼──►│ • Flyway migrations   │    │     │
│   │  │   proxy_ssl_server_name │SNI│ • NamedParameterJdbc  │    │     │
│   │  │ • 0–3 instances         │   │ CR: 0–5 instances     │    │     │
│   │  └─────────────────────────┘   │ GKE: 1 pod, e2-std-2  │    │     │
│   │           ▲                    └──────────┬────────────┘    │     │
│   │           │ HTTPS                Direct VPC Egress          │     │
│   └───────────┼─────────────────────────────┼───────────────────┘     │
│               │                             │                           │
│           Browser              ┌────────────▼──────────┐               │
│                                │  GCE VM: Postgres 16  │               │
│                                │  dash-lite-pg         │               │
│                                │  • orders (4 M rows)  │               │
│                                │  • GIN index          │               │
│                                │  • pre-agg summary    │               │
│                                └───────────────────────┘               │
│                                                                         │
│   Secret Manager                                                        │
│   ┌──────────────────────┐                                              │
│   │ dash-database-url    │◄── secretKeyRef (backend container env)      │
│   └──────────────────────┘                                              │
└─────────────────────────────────────────────────────────────────────────┘

Deploy flow
───────────
local machine
  └─ deploy.sh
       ├─ docker build + push → Artifact Registry
       ├─ pulumi up --yes
       │    ├─ VPC / subnets / firewall
       │    ├─ GCE VM (Postgres 16, startup script installs + configures)
       │    ├─ Secret Manager secret (DATABASE_URL)
       │    ├─ Cloud Run frontend (BACKEND_URL env pointing at backend)
       │    └─ Cloud Run backend  [default]
       │         or GKE cluster + Deployment  [BACKEND_RUNTIME=gke]
       ├─ psql SSH row-count check → bake VM restore if DB empty
       └─ frontend deploy (chained)

Seed flow (bake VM, triggered when DB empty)
────────────────────────────────────────────
deploy.sh (auto) or scripts/bake-demo-snapshot.sh
  ├─ create ephemeral n2-standard-8 bake VM on same VPC
  ├─ gsutil cp gs://bikram-java-dash-snapshots/dash/demo-lite.dump → pg_restore
  └─ delete bake VM on completion
```

### Key design decisions

| Concern | Approach |
|---|---|
| **Search performance** | Denormalized `search_text` column (name + notes + total + id + status + region + date) with one GIN index — sub-second ILIKE on 4 M rows, single index hit per token, no cross-table OR |
| **Chart performance** | Pre-aggregated `daily_summary`, `daily_customer_category_summary`, `daily_status_category_summary`, `daily_filter_category_summary` — sub-second chart aggregates, queries never touch raw `orders` |
| **Trigger maintenance** | `fn_order_search_text()` (BEFORE INSERT/UPDATE on orders) + `fn_customer_name_to_orders()` (AFTER UPDATE on customers) keep `search_text` current without application-level logic |
| **Startup resilience** | Cloud Run startup probe with `failureThreshold: 60` × `periodSeconds: 15` = 15 min — survives long Flyway migrations (e.g. UPDATE + CREATE INDEX on 4 M rows) |
| **Zero-credential deploys** | Backend SA with `roles/secretmanager.secretAccessor` + `roles/cloudsql.client`; no passwords in code or Docker image |

---

## Snapshot Data

Demo data is seeded from a pre-built PostgreSQL dump stored in GCS:

```
gs://bikram-java-dash-snapshots/dash/demo-lite.dump
```

`deploy.sh` automatically triggers a restore when the `orders` table is empty:

1. Creates an ephemeral n2-standard-8 bake VM on the same VPC.
2. Runs `pg_restore` from the GCS snapshot into the GCE Postgres instance.
3. Deletes the bake VM on completion.

To manually trigger a restore:

```bash
./scripts/bake-demo-snapshot.sh
```

The snapshot contains 4 M+ orders across multiple customers, regions, and statuses — sized for realistic query performance testing without needing to generate synthetic data.

---

## Transactional Outbox

The backend uses database-level triggers to maintain consistency between the `orders` table and its derived state — a pattern analogous to the transactional outbox, but enforced at the DB layer rather than application code.

| Trigger | Event | Effect |
|---|---|---|
| `fn_order_search_text()` | BEFORE INSERT/UPDATE on `orders` | Recomputes `search_text` from name, notes, total, id, status, region, date |
| `fn_customer_name_to_orders()` | AFTER UPDATE on `customers` | Propagates customer name changes to all matching `orders.search_text` |

Key properties:
- **Atomic per trigger**: triggers execute within the same transaction as the INSERT/UPDATE — if the parent statement rolls back, the derived-state update rolls back too; no partial writes possible.
- **Multi-writer safe**: PostgreSQL serializes trigger execution per row; concurrent inserts don't interfere, making horizontal scaling of the application layer safe by construction.
- **Fail-closed**: if a trigger function raises an exception, the parent transaction aborts — no silent partial updates, unlike fire-and-forget application code.
- **No application-level sync**: `search_text` and customer-name propagation require zero application code; the DB enforces consistency regardless of which service or migration writes to `orders` or `customers`.

The pre-aggregated summary tables (`daily_summary`, `daily_customer_category_summary`, `daily_status_category_summary`, `daily_filter_category_summary`) are populated via controlled application writes on order insert/update, keeping chart aggregates in sync without touching raw `orders` on the query path.

For future event-driven extensions (e.g. publishing order state changes to an external message broker), this project is structured to adopt a true transactional outbox table: write the event to an `outbox` table in the same DB transaction as the order write, then have a separate relay process poll and publish — guaranteeing at-least-once delivery even if the broker is temporarily unavailable.

### How a future agent should test this

1. **Confirm the service is up**:
   ```bash
   BASE=https://dash-lite-frontend-77y7e2wykq-uc.a.run.app
   curl "$BASE/actuator/health"
   ```

2. **`search_text` is populated on insert** — create or locate a known order, then verify its `search_text` column contains the expected tokens (name, status, region, date). A mismatch means `fn_order_search_text` is not firing or is broken:
   ```bash
   psql "$DATABASE_URL" -c "SELECT id, search_text FROM orders ORDER BY id DESC LIMIT 3;"
   ```

3. **Customer rename propagates** — update a customer's name and confirm all matching `orders.search_text` rows reflect the change within the same transaction (check before/after without a sleep):
   ```bash
   psql "$DATABASE_URL" -c "UPDATE customers SET \"firstName\"='TestName' WHERE id=1;"
   psql "$DATABASE_URL" -c "SELECT COUNT(*) FROM orders WHERE search_text ILIKE '%testname%' AND \"customerId\"=1;"
   ```
   Expect the count to be nonzero immediately — no async wait needed.

4. **GIN index is used** — confirm ILIKE queries hit the index, not a sequential scan:
   ```bash
   psql "$DATABASE_URL" -c "EXPLAIN ANALYZE SELECT id FROM orders WHERE search_text ILIKE '%sara carter%' LIMIT 10;"
   ```
   Expect `Bitmap Index Scan` or `Index Scan` on the GIN index — not `Seq Scan`.

5. **Pre-aggregated tables are in sync** — compare a `COUNT(*)` from raw `orders` for a known date range against the corresponding `daily_summary` total; they should match:
   ```bash
   psql "$DATABASE_URL" -c "SELECT SUM(\"orderCount\") FROM daily_summary WHERE date >= '2024-01-01' AND date <= '2024-12-31';"
   psql "$DATABASE_URL" -c "SELECT COUNT(*) FROM orders WHERE \"placedAt\" >= '2024-01-01' AND \"placedAt\" <= '2024-12-31';"
   ```

6. **Chart queries never touch raw `orders`** — run `EXPLAIN ANALYZE` on the aggregates endpoint query path and confirm the plan shows reads from `daily_summary` (or other pre-agg tables), not `orders`.

### Verified baseline — treat as the regression threshold

These are the known performance characteristics of this deployment on Cloud Run with the 4 M-row dataset. **A future change to the schema, trigger functions, or pre-aggregation writes should reproduce results at least this good** — if re-runs come back slower or search_text goes stale, treat that as a regression.

| Check | Verified result |
|---|---|
| ILIKE search latency (`/api/orders?q=...`) | Sub-second end-to-end via GIN index on `search_text` — no sequential scan at 4 M rows |
| Chart aggregate latency (`/api/aggregates`) | Millisecond responses via pre-aggregated summary tables — queries never touch raw `orders` |
| `search_text` consistency on insert | Trigger fires synchronously; new order's `search_text` is queryable in the same transaction that created the order |
| Customer rename propagation | `fn_customer_name_to_orders` updates all affected `orders.search_text` rows atomically within the UPDATE transaction — no lag |
| Concurrent write safety | Spring Boot + Flyway migration on 4 M rows completes without trigger conflicts; Cloud Run startup probe (failureThreshold: 60 × 15s) survives long migrations |
