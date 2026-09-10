import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import * as random from "@pulumi/random";

const config    = new pulumi.Config();
const gcpConfig = new pulumi.Config("gcp");

const project      = gcpConfig.require("project");
const region       = gcpConfig.get("region")     ?? "us-central1";
const namePrefix   = config.get("namePrefix")     ?? "dash-full";
const dbName       = config.get("dbName")         ?? "app";
const dbUsername   = config.get("dbUsername")     ?? "appuser";
const dbVmType     = config.get("dbVmType")       ?? "n2-standard-4";
const dbDiskGb     = config.getNumber("dbDiskGb") ?? 35;
const backendImage   = config.get("backendImage")     ?? "";
const backendRuntime = config.get("backendRuntime") ?? "cr"; // "cr" | "gke"
// When true: Neon (external serverless Postgres, ~$0/mo) is used instead of the GCE VM (~$52/mo).
// GCE VM resources below are preserved — set useNeon: false to revert.
const useNeon = config.getBoolean("useNeon") ?? false;
const neonDatabaseUrl = useNeon ? config.requireSecret("neonDatabaseUrl") : undefined;

// ── APIs ──────────────────────────────────────────────────────────────────────
const apis = [
  "compute.googleapis.com",
  "artifactregistry.googleapis.com",
  "secretmanager.googleapis.com",
  "run.googleapis.com",
  "cloudscheduler.googleapis.com",
  "container.googleapis.com",
].map(api => new gcp.projects.Service(`api-${api.split(".")[0]}`, {
  project,
  service: api,
  disableOnDestroy: false,
}));

// ── VPC ───────────────────────────────────────────────────────────────────────
const network = new gcp.compute.Network("vpc", {
  name: `${namePrefix}-vpc`,
  autoCreateSubnetworks: false,
}, { dependsOn: apis });

const subnet = new gcp.compute.Subnetwork("subnet", {
  name: `${namePrefix}-subnet`,
  ipCidrRange: "10.8.0.0/20",
  region,
  network: network.id,
});

new gcp.compute.Firewall("allow-internal-to-db", {
  name: `${namePrefix}-allow-internal-db`,
  network: network.id,
  direction: "INGRESS",
  sourceRanges: ["10.0.0.0/8"],
  allows: [{ protocol: "tcp", ports: ["5432"] }],
});

// ── Postgres on GCE (~$52/mo always-on) ──────────────────────────────────────
// Skipped when useNeon=true. Resources preserved here; re-enable by setting useNeon: false.
let dbPassword: random.RandomPassword | undefined;
let dbVmIp: pulumi.Output<string> = pulumi.output("n/a");
let dbUrlSecretVersion: gcp.secretmanager.SecretVersion | undefined;

if (!useNeon) {
  dbPassword = new random.RandomPassword("db-password", {
    length: 24,
    special: false,
  });

  // Runs once at first boot (guarded by sentinel). Installs Postgres 16 + pg_bigm,
  // configures VPC-wide access, and creates the app user/db.
  const _startupScript = `#!/bin/bash
set -euo pipefail
SENTINEL=/var/lib/postgresql/.pg16_initialized
[ -f "$SENTINEL" ] && exit 0
_meta() { curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" -H Metadata-Flavor:Google; }
DB_PASS=$(_meta db-password)
DB_NAME=$(_meta db-name)
DB_USER=$(_meta db-username)
echo "deb http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-16 postgresql-server-dev-16 build-essential git
PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
git clone --depth 1 https://github.com/pgbigm/pg_bigm.git /tmp/pg_bigm
make -C /tmp/pg_bigm USE_PGXS=1 PG_CONFIG="$PG_CONFIG"
make -C /tmp/pg_bigm USE_PGXS=1 PG_CONFIG="$PG_CONFIG" install
rm -rf /tmp/pg_bigm
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf
echo "shared_preload_libraries = 'pg_bigm'" >> /etc/postgresql/16/main/postgresql.conf
echo "host all all 10.0.0.0/8 scram-sha-256" >> /etc/postgresql/16/main/pg_hba.conf
systemctl restart postgresql@16-main
sleep 5
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
sudo -u postgres psql -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS pg_bigm;"
touch "$SENTINEL"`;

  const dbVm = new gcp.compute.Instance("pg-vm", {
    name: `${namePrefix}-pg`,
    machineType: dbVmType,
    zone: `${region}-a`,
    bootDisk: {
      initializeParams: {
        image: "debian-cloud/debian-12",
        size: dbDiskGb,
        type: "pd-ssd",
      },
    },
    networkInterfaces: [{
      network: network.id,
      subnetwork: subnet.id,
    }],
    metadata: {
      "db-password": dbPassword.result,
      "db-name": dbName,
      "db-username": dbUsername,
      "startup-script": _startupScript,
    },
    tags: [`${namePrefix}-pg`],
  });

  dbVmIp = dbVm.networkInterfaces.apply(nics => nics[0].networkIp!);
}

// ── Secret Manager ────────────────────────────────────────────────────────────
const dbUrlSecret = new gcp.secretmanager.Secret("database-url", {
  secretId: `${namePrefix}-database-url`,
  replication: { auto: {} },
}, { dependsOn: apis });

// GCE mode: Pulumi writes the secret version with the internal VPC URL.
// Neon mode: Pulumi writes the version with the Neon URL from config (set by deploy.sh before pulumi up).
if (!useNeon && dbPassword) {
  dbUrlSecretVersion = new gcp.secretmanager.SecretVersion("database-url-v1", {
    secret: dbUrlSecret.id,
    secretData: pulumi.interpolate`postgresql://${dbUsername}:${dbPassword.result}@${dbVmIp}:5432/${dbName}`,
  }, { retainOnDelete: true });
} else if (useNeon && neonDatabaseUrl) {
  dbUrlSecretVersion = new gcp.secretmanager.SecretVersion("database-url-v1", {
    secret: dbUrlSecret.id,
    secretData: neonDatabaseUrl,
  }, { retainOnDelete: true });
}

// ── Artifact Registry ─────────────────────────────────────────────────────────
const registry = new gcp.artifactregistry.Repository("repo", {
  location: region,
  repositoryId: `${namePrefix}-repo`,
  format: "DOCKER",
}, { dependsOn: apis });

// ── Service Account ───────────────────────────────────────────────────────────
const backendSa = new gcp.serviceaccount.Account("backend-sa", {
  accountId: `${namePrefix}-backend-sa`,
  displayName: "Dashboard Backend SA",
});

new gcp.secretmanager.SecretIamMember("backend-db-url-access", {
  secretId: dbUrlSecret.id,
  role: "roles/secretmanager.secretAccessor",
  member: pulumi.interpolate`serviceAccount:${backendSa.email}`,
});

new gcp.projects.IAMMember("backend-ar-reader", {
  project,
  role: "roles/artifactregistry.reader",
  member: pulumi.interpolate`serviceAccount:${backendSa.email}`,
});

// ── Cloud Run backend (cr mode only) ─────────────────────────────────────────
// GCE mode: Direct VPC Egress reaches the Postgres VM on its private IP.
// Neon mode: No VPC egress needed — Neon is external HTTPS; min=0 → ~$0/mo.
let _backendUrl: pulumi.Output<string> = pulumi.output("");
if (backendRuntime !== "gke") {
  const crDeps: pulumi.Resource[] = [registry];
  if (dbUrlSecretVersion) crDeps.push(dbUrlSecretVersion);

  const backendService = new gcp.cloudrunv2.Service("backend-service", {
    name: `${namePrefix}-backend`,
    location: region,
    ingress: "INGRESS_TRAFFIC_ALL",
    template: {
      serviceAccount: backendSa.email,
      containers: [{
        image: backendImage !== "" ? backendImage : "us-docker.pkg.dev/cloudrun/container/hello",
        ports: [{ containerPort: 8080 }],
        resources: {
          limits: { cpu: "1", memory: "512Mi" },
        },
        envs: [{
          name: "DATABASE_URL",
          valueSource: {
            secretKeyRef: {
              secret: dbUrlSecret.secretId,
              version: "latest",
            },
          },
        }],
        startupProbe: {
          tcpSocket: { port: 8080 },
          initialDelaySeconds: 10,
          periodSeconds: 15,
          failureThreshold: namePrefix.includes("full") ? 200 : 60,
          timeoutSeconds: 5,
        },
      }],
      scaling: {
        minInstanceCount: 0,
        maxInstanceCount: 5,
      },
      ...(useNeon ? {} : {
        vpcAccess: {
          networkInterfaces: [{
            network: network.name,
            subnetwork: subnet.name,
          }],
          egress: "PRIVATE_RANGES_ONLY",
        },
      }),
    },
  }, { dependsOn: crDeps });

  new gcp.cloudrunv2.ServiceIamMember("backend-public", {
    project,
    location: region,
    name: backendService.name,
    role: "roles/run.invoker",
    member: "allUsers",
  });

  // ── Scheduled min-instance scaling (8am–5pm America/Los_Angeles) ─────────────
  // Keeps one warm instance during demo hours so there's no cold-start latency.
  // Outside those hours min=0 so the service scales to zero and costs ~nothing.
  const schedulerSa = new gcp.serviceaccount.Account("scheduler-sa", {
    accountId: `${namePrefix}-sched-sa`,
    displayName: "Cloud Run min-instance scheduler",
  });

  new gcp.projects.IAMMember("scheduler-run-developer", {
    project,
    role: "roles/run.developer",
    member: pulumi.interpolate`serviceAccount:${schedulerSa.email}`,
  });

  const _svcPath = pulumi.interpolate`projects/${project}/locations/${region}/services/${backendService.name}`;
  const _patchUri = pulumi.interpolate`https://run.googleapis.com/v2/${_svcPath}?updateMask=template.scaling.minInstanceCount`;
  const _scaleUp   = Buffer.from(JSON.stringify({ template: { scaling: { minInstanceCount: 1 } } })).toString("base64");
  const _scaleDown = Buffer.from(JSON.stringify({ template: { scaling: { minInstanceCount: 0 } } })).toString("base64");

  new gcp.cloudscheduler.Job("scale-up-backend", {
    name: `${namePrefix}-scale-up-backend`,
    region,
    schedule: "0 8 * * 1-5",
    timeZone: "America/Los_Angeles",
    httpTarget: {
      uri: _patchUri,
      httpMethod: "PATCH",
      body: _scaleUp,
      headers: { "Content-Type": "application/json" },
      oidcToken: { serviceAccountEmail: schedulerSa.email, audience: "https://run.googleapis.com/" },
    },
  }, { dependsOn: apis });

  new gcp.cloudscheduler.Job("scale-down-backend", {
    name: `${namePrefix}-scale-down-backend`,
    region,
    schedule: "0 17 * * 1-5",
    timeZone: "America/Los_Angeles",
    httpTarget: {
      uri: _patchUri,
      httpMethod: "PATCH",
      body: _scaleDown,
      headers: { "Content-Type": "application/json" },
      oidcToken: { serviceAccountEmail: schedulerSa.email, audience: "https://run.googleapis.com/" },
    },
  }, { dependsOn: apis });

  _backendUrl = backendService.uri;
}

// ── GKE node-pool scheduler (gke mode only, weekdays 8am–5pm Pacific) ────────
if (backendRuntime === "gke") {
  const _gkeZone    = `${region}-a`;
  const _gkeCluster = `${namePrefix}-cluster`;
  const _resizeUri  = `https://container.googleapis.com/v1/projects/${project}/zones/${_gkeZone}/clusters/${_gkeCluster}/nodePools/default-pool/setSize`;

  const gkeSchedSa = new gcp.serviceaccount.Account("gke-sched-sa", {
    accountId: `${namePrefix}-gke-sched-sa`,
    displayName: "GKE node-pool scheduler",
  });

  new gcp.projects.IAMMember("gke-sched-cluster-admin", {
    project,
    role: "roles/container.clusterAdmin",
    member: pulumi.interpolate`serviceAccount:${gkeSchedSa.email}`,
  });

  const projectData = gcp.organizations.getProject({ projectId: project });
  new gcp.serviceaccount.IAMMember("gke-sched-sa-token-creator", {
    serviceAccountId: gkeSchedSa.name,
    role: "roles/iam.serviceAccountTokenCreator",
    member: pulumi.interpolate`serviceAccount:service-${pulumi.output(projectData).apply(p => p.number)}@gcp-sa-cloudscheduler.iam.gserviceaccount.com`,
  });

  const _nodeUp   = Buffer.from(JSON.stringify({ nodeCount: 1 })).toString("base64");
  const _nodeDown = Buffer.from(JSON.stringify({ nodeCount: 0 })).toString("base64");

  new gcp.cloudscheduler.Job("gke-scale-up", {
    name: `${namePrefix}-gke-scale-up`,
    region,
    schedule: "0 8 * * 1-5",
    timeZone: "America/Los_Angeles",
    httpTarget: {
      uri: _resizeUri,
      httpMethod: "POST",
      body: _nodeUp,
      headers: { "Content-Type": "application/json" },
      oauthToken: { serviceAccountEmail: gkeSchedSa.email, scope: "https://www.googleapis.com/auth/cloud-platform" },
    },
  }, { dependsOn: apis });

  new gcp.cloudscheduler.Job("gke-scale-down", {
    name: `${namePrefix}-gke-scale-down`,
    region,
    schedule: "0 17 * * 1-5",
    timeZone: "America/Los_Angeles",
    httpTarget: {
      uri: _resizeUri,
      httpMethod: "POST",
      body: _nodeDown,
      headers: { "Content-Type": "application/json" },
      oauthToken: { serviceAccountEmail: gkeSchedSa.email, scope: "https://www.googleapis.com/auth/cloud-platform" },
    },
  }, { dependsOn: apis });
}

// ── DB VM scheduler (GCE mode only, weekdays 7:45am start → 5:10pm stop Pacific) ─
// Skipped when useNeon=true — no VM to schedule.
// Starts 15 min before Cloud Run warm-up at 8am so Postgres is ready on first request.
if (!useNeon) {
  const dbVmSchedSa = new gcp.serviceaccount.Account("db-vm-sched-sa", {
    accountId: `${namePrefix}-dbvm-sched-sa`,
    displayName: "DB VM start/stop scheduler",
  });

  new gcp.projects.IAMMember("db-vm-sched-instance-admin", {
    project,
    role: "roles/compute.instanceAdmin.v1",
    member: pulumi.interpolate`serviceAccount:${dbVmSchedSa.email}`,
  });

  const _vmStartUri = `https://compute.googleapis.com/compute/v1/projects/${project}/zones/${region}-a/instances/${namePrefix}-pg/start`;
  const _vmStopUri  = `https://compute.googleapis.com/compute/v1/projects/${project}/zones/${region}-a/instances/${namePrefix}-pg/stop`;
  const _emptyBody  = Buffer.from("{}").toString("base64");

  new gcp.cloudscheduler.Job("db-vm-start", {
    name: `${namePrefix}-db-vm-start`,
    region,
    schedule: "45 7 * * 1-5",
    timeZone: "America/Los_Angeles",
    httpTarget: {
      uri: _vmStartUri,
      httpMethod: "POST",
      body: _emptyBody,
      headers: { "Content-Type": "application/json" },
      oauthToken: { serviceAccountEmail: dbVmSchedSa.email, scope: "https://www.googleapis.com/auth/cloud-platform" },
    },
  }, { dependsOn: apis });

  new gcp.cloudscheduler.Job("db-vm-stop", {
    name: `${namePrefix}-db-vm-stop`,
    region,
    schedule: "10 17 * * 1-5",
    timeZone: "America/Los_Angeles",
    httpTarget: {
      uri: _vmStopUri,
      httpMethod: "POST",
      body: _emptyBody,
      headers: { "Content-Type": "application/json" },
      oauthToken: { serviceAccountEmail: dbVmSchedSa.email, scope: "https://www.googleapis.com/auth/cloud-platform" },
    },
  }, { dependsOn: apis });
}

// ── Outputs ───────────────────────────────────────────────────────────────────
export const dbVmInternalIp   = useNeon ? pulumi.output("n/a — using Neon") : dbVmIp;
export const artifactRegistry = pulumi.interpolate`${region}-docker.pkg.dev/${project}/${registry.repositoryId}`;
export const backendUrl       = _backendUrl;
export const databaseUrl      = useNeon
  ? pulumi.output("(Neon URL written to Secret Manager by deploy.sh)")
  : pulumi.secret(
      dbPassword
        ? pulumi.interpolate`postgresql://${dbUsername}:${dbPassword.result}@${dbVmIp}:5432/${dbName}`
        : pulumi.output("n/a")
    );
