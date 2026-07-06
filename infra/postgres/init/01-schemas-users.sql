-- Phase 2 data ownership (plan §6): one local PostgreSQL instance, strict per-service
-- ownership. Each service gets its own schema and its own login; neither can touch the
-- other's schema. Runs once on first container start against POSTGRES_DB=case_poc.

CREATE USER submission_service WITH PASSWORD 'submission_service';
CREATE USER management_service WITH PASSWORD 'management_service';

-- AUTHORIZATION makes the service user the schema owner: full DDL/DML inside its own
-- schema (Flyway runs as this user), and no grants anywhere else.
CREATE SCHEMA submission AUTHORIZATION submission_service;
CREATE SCHEMA management AUTHORIZATION management_service;

-- No shared playground: the public schema is not writable, and connecting to the
-- database is an explicit grant instead of the PostgreSQL default.
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE CONNECT ON DATABASE case_poc FROM PUBLIC;
GRANT CONNECT ON DATABASE case_poc TO submission_service, management_service;
