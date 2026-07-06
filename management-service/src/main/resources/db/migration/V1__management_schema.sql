-- Phase 2 (plan §6): persistent case projection, inbox, and transactional outbox for the
-- management side. Runs via Flyway in schema "management" (quarkus.flyway.default-schema).
-- Same table categories as the submission schema, minus the access-token hash (only the
-- submission side authenticates reporters).

create table cases (
    case_id    uuid primary key,
    status     text not null,
    created_at timestamptz not null,
    updated_at timestamptz not null
);

create table messages (
    message_id  uuid primary key,
    event_id    uuid not null unique,
    case_id     uuid not null references cases (case_id),
    direction   text not null,
    author      text not null,
    seq         bigint not null,
    body        text not null,
    traceparent text,
    created_at  timestamptz not null
);

create index messages_case_id_idx on messages (case_id);

create table inbox_events (
    event_id    uuid primary key,
    received_at timestamptz not null
);

create table outbox_events (
    event_id        uuid primary key,
    case_id         uuid not null,
    address         text not null,
    payload         jsonb not null,
    traceparent     text,
    tracestate      text,
    status          text not null,
    attempts        integer not null default 0,
    next_attempt_at timestamptz not null,
    created_at      timestamptz not null,
    published_at    timestamptz,
    last_error      text
);

-- The relay polls only PENDING rows that are due; partial index keeps that cheap.
create index outbox_events_pending_idx on outbox_events (next_attempt_at)
    where status = 'PENDING';
