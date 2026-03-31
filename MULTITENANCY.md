# High-Density Scaling & Multi-Tenancy Guide

This document outlines the strategies for running many IronClaw agent instances (1,000+) on a single machine or cluster, based on the research and optimizations implemented in the `feature/nomad-multi-tenant` branch.

## Scaling Strategies

We provide three distinct levels of optimization depending on your isolation and density requirements.

### 1. Strategy A: "Slim" Independent Processes
Best for: Strict OS-level isolation where each agent must be a separate process.

*   **Runtime:** Switch to `current_thread` Tokio runtime to eliminate worker thread overhead.
*   **Database:** Set `DATABASE_POOL_SIZE=1` to prevent connection exhaustion.
*   **WASM:** Uses "Lazy Ticker" logic; the background epoch thread only spawns if a WASM tool is actually invoked.
*   **Environment:** Set `TOKIO_WORKER_THREADS=1`.
*   **Density:** ~15-25MB RAM per agent. Can fit ~3,000-4,000 agents on a 64GB machine.

### 2. Strategy B: Sharded Multi-Tenancy (Service Model)
Best for: High-performance chat with low latency and balanced resource usage.

*   **Architecture:** A small number of shards (e.g., 10 processes) each handle a large number of tenants (e.g., 100 users).
*   **Sharing:** All 100 tenants in a shard share the same WASM engine, Tokio thread pool, and HTTP connection pool.
*   **Persistence:** All shards connect to a central PostgreSQL database.
*   **Nomad Job:** See `ironclaw.nomad.hcl`.
*   **Density:** ~3-5MB RAM per active tenant. Can fit 15,000+ agents on a 64GB machine.

### 3. Strategy C: Dispatched Session Workers (Batch Model)
Best for: Maximum density, zero idle cost, and perfect turn-level isolation.

*   **Architecture:** Nomad "spawns" a short-lived container for a single message/turn and kills it immediately after.
*   **State:** The agent is "hydrated" from Postgres at the start of the turn and "dehydrated" (saved) at the end.
*   **Nomad Job:** See `ironclaw-worker.nomad.hcl`.
*   **Density:** Theoretically infinite agents, limited only by concurrent active turns.

---

## Resource Comparison (for 1,000 Agents)

| Metric | Baseline (Standard) | Slim Mode (Scenario A) | Multi-Tenant Shards (Scenario B) |
| :--- | :--- | :--- | :--- |
| **Tokio Threads** | 16,000 | 1,000 | **~40 total** |
| **WASM Tickers** | 1,000 | 0 to 1,000 (Lazy) | **10 total** |
| **DB Connections**| 10,000 | 1,000 | **~200 total** |
| **RAM (RSS)** | ~60GB | ~20GB | **~3GB** |
| **Context Swapping**| Extreme (High Lag) | Moderate | **Minimal (Fast)** |

---

## Operational Guide

### Database Setup
High-density scaling **requires PostgreSQL**. SQLite (libSQL) is not suitable for sharding as multiple processes cannot safely write to the same local file across a network.

1.  Provision a central Postgres server (RDS, Supabase, or a Nomad-managed task).
2.  Ensure `pgvector` is installed on the Postgres server for agent memory.

### Nomad Deployment
1.  **Build the Image:**
    ```bash
    docker build -t nearai/ironclaw:latest .
    ```
2.  **Configure Shards:**
    Edit `ironclaw.nomad.hcl` to set your `DATABASE_URL` and `SECRETS_MASTER_KEY`.
3.  **Run:**
    ```bash
    nomad job run ironclaw.nomad.hcl
    ```

### Spawning New Agents
To "spawn" a new agent in a multi-tenant or sharded environment:
1.  Add a new record to the `users` table in the shared Postgres database.
2.  The existing shards will automatically recognize the new `user_id` when traffic arrives for them or when a routine is due.

## Implementation Details

*   **Lazy Ticker:** Located in `src/tools/wasm/runtime.rs`. Uses `AtomicBool` to defer `std::thread::spawn` until the first WASM preparation call.
*   **Slim Runtime:** Located in `src/main.rs`. Re-configures the Tokio runtime builder based on `TOKIO_WORKER_THREADS` before `async_main` starts.
*   **Health Check:** Root-level `/health` added to `src/channels/web/server.rs` for orchestrator compatibility.
