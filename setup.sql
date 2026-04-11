-- setup.sql
-- 
-- Initialization script for IronClaw's PostgreSQL database.
-- Run this as a superuser (e.g., the default 'postgres' user) BEFORE
-- starting the IronClaw instances. IronClaw will handle creating the
-- rest of the tables automatically via its internal migrations.

-- 1. Enable the vector extension (CRITICAL for Agent Memory/Embeddings)
-- This must be created in the target database ('ironclaw').
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. Optional: Create an initial admin user for multi-tenant access.
-- If you are relying on IronClaw's automatic bootstrap via the Gateway, 
-- you can skip this.
-- 
-- INSERT INTO users (id, display_name, role, status, created_at, updated_at) 
-- VALUES ('admin-1', 'System Admin', 'admin', 'active', NOW(), NOW());
