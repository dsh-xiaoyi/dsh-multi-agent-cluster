-- 009-agent-messages.sql
-- Transport table for dsh-agent-bridge (plan B, DB-transport variant).
--
-- WHY THIS SHAPE
--   The approved B1 rule was "only 11 opens a LAN port". This table goes one step tighter:
--   no machine opens anything. Messages ride the shared DSHMemory database that every machine
--   already reaches (1433 is already granted and synced), and each machine's poller hands a
--   message to ITS OWN 127.0.0.1 bridge, which injects it into the native agent inbox.
--   Net effect: cross-machine agent messaging with zero new listening surface.
--
-- GUARANTEES
--   * append-only for the cluster logins: INSERT + SELECT + UPDATE(delivered_at) only, no DELETE
--   * msg_id is the primary key -> a replayed enqueue cannot duplicate a message
--   * body is the message text; keep it OUT of logs and OUT of dbo.memories (trajectory only)
--
-- Idempotent: safe to run repeatedly.

IF OBJECT_ID('dbo.agent_messages', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.agent_messages (
        msg_id        UNIQUEIDENTIFIER NOT NULL
            CONSTRAINT PK_agent_messages PRIMARY KEY CLUSTERED,
        from_machine  NVARCHAR(64)     NOT NULL,
        to_machine    NVARCHAR(64)     NOT NULL,
        target        NVARCHAR(128)    NOT NULL,   -- logical target on the receiving machine
        delivery      NVARCHAR(8)      NOT NULL    -- queue | steer
            CONSTRAINT CK_agent_messages_delivery CHECK (delivery IN (N'queue', N'steer')),
        body          NVARCHAR(MAX)    NOT NULL,
        body_len      AS (LEN(body)) PERSISTED,
        created_at    DATETIME2(3)     NOT NULL CONSTRAINT DF_agent_messages_created DEFAULT (SYSUTCDATETIME()),
        delivered_at  DATETIME2(3)     NULL,
        attempt_count INT              NOT NULL CONSTRAINT DF_agent_messages_attempts DEFAULT (0),
        last_error    NVARCHAR(400)    NULL
    );
    CREATE NONCLUSTERED INDEX IX_agent_messages_inbox
        ON dbo.agent_messages (to_machine, delivered_at, created_at)
        INCLUDE (target, delivery);
    PRINT 'created dbo.agent_messages';
END
ELSE PRINT 'dbo.agent_messages already exists';

-- Read model without the message body (same principle as lesson_records_safe).
IF OBJECT_ID('dbo.agent_messages_safe', 'V') IS NULL
    EXEC('CREATE VIEW dbo.agent_messages_safe AS
          SELECT msg_id, from_machine, to_machine, target, delivery, body_len,
                 created_at, delivered_at, attempt_count, last_error
          FROM dbo.agent_messages;');
ELSE PRINT 'dbo.agent_messages_safe already exists';
GO
