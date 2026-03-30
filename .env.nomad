# .env.nomad - Environment Template for Nomad-managed IronClaw Shards
#
# Copy this to your secrets manager (e.g. HashiCorp Vault) or use it 
# to populate the Nomad job's 'template' block.

# ── Multi-Tenancy (Crucial for Scenario 3) ──────────────────────────
# Tells IronClaw to use WorkspacePool and multi-user logic.
AGENT_MULTI_TENANT=true
HEARTBEAT_MULTI_TENANT=true

# ── Networking ──────────────────────────────────────────────────────
# Nomad dynamically assigns ports; these should match the 'env' block 
# in the .nomad file.
HTTP_HOST=0.0.0.0
HTTP_PORT=8080
GATEWAY_HOST=0.0.0.0
GATEWAY_PORT=9000

# ── Database ────────────────────────────────────────────────────────
# A shared PostgreSQL instance is required for sharding.
# All shards MUST point to the same database.
DATABASE_BACKEND=postgres
DATABASE_URL="postgres://user:password@postgres-server:5432/ironclaw"

# ── Shard Tuning ────────────────────────────────────────────────────
# Since one process handles ~100 users, we increase the pool size
# and worker threads compared to a single-user instance.
DATABASE_POOL_SIZE=20
TOKIO_WORKER_THREADS=4

# ── Tooling & Sandbox ────────────────────────────────────────────────
# For high-density agents, consider disabling the heavy Docker sandbox
# unless you require strict code isolation for every agent.
SANDBOX_ENABLED=false
WASM_ENABLED=true

# ── Security ────────────────────────────────────────────────────────
# Ensure each shard has the same master key to decrypt shared secrets.
SECRETS_MASTER_KEY="your-shared-32-byte-hex-key-here"
