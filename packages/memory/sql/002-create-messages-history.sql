-- 002-create-messages-history.sql
-- Append-only archive for "memory with time" (memory [326]).
--
-- WHY: sync replaces a session's rows with DELETE + re-INSERT.  If a machine's local session log is
-- rolled back (whole-VM snapshot, crash, truncation), the next sync deletes the tail that only the
-- database still had -- and that loss is unrecoverable (measured window: sync every ~16 s).
--
-- DESIGN: the CLI archives ONLY the difference it is about to destroy:
--   archive_reason='dropped' -> the seq is no longer in the log  (rollback / deletion)
--   archive_reason='changed' -> same seq, different text          (regenerate / compaction)
-- A healthy sync archives nothing, so this costs nothing in the normal case.
--
-- APPEND-ONLY BY PRIVILEGE: the three machine logins get INSERT + SELECT only.  No DELETE, no
-- UPDATE.  So even a buggy -- or malicious -- code path cannot erase history; only a Windows
-- (integrated-auth) operator can, which is the intended separation (user directive, 2026-10-06).
--
-- Run with Windows integrated auth (the low-privilege logins have no DDL rights):
--   sqlcmd -S 192.0.2.11,1433 -d DSHMemory -E -i 002-create-messages-history.sql

IF OBJECT_ID('dbo.messages_history') IS NULL
BEGIN
  CREATE TABLE dbo.messages_history (
    history_id     bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_messages_history PRIMARY KEY,
    id             bigint         NOT NULL,   -- original dbo.messages.id (keeps traceability)
    session_id     varchar(64)    NOT NULL,
    seq            bigint         NOT NULL,
    turn           int            NULL,
    role           varchar(24)    NOT NULL,
    text           nvarchar(max)  NULL,
    created_at     datetime2(3)   NOT NULL,
    archived_at    datetime2(3)   NOT NULL CONSTRAINT DF_msg_hist_at DEFAULT SYSUTCDATETIME(),
    archive_reason varchar(16)    NOT NULL,   -- 'dropped' | 'changed'
    archived_by    nvarchar(128)  NULL
  );
  CREATE INDEX IX_messages_history_sess ON dbo.messages_history (session_id, seq);
  CREATE INDEX IX_messages_history_at   ON dbo.messages_history (archived_at);
  CREATE INDEX IX_messages_history_orig ON dbo.messages_history (id);
END
GO

-- append-only for the machine accounts: INSERT + SELECT, deliberately no DELETE/UPDATE
GRANT INSERT, SELECT ON dbo.messages_history TO dsh_mem_a;
GRANT INSERT, SELECT ON dbo.messages_history TO dsh_mem_b;
GRANT INSERT, SELECT ON dbo.messages_history TO dsh_guard;
GO

-- DENY is REQUIRED, not redundant: the three logins already hold DATABASE-level DELETE and UPDATE,
-- and a database-level GRANT covers every table -- including one created later -- so a plain GRANT
-- of INSERT+SELECT would NOT stop them from deleting history.  A table-level DENY overrides a
-- wider GRANT.  Found by guard check 16e on 2026-10-06 (fn_my_permissions still listed DELETE).
DENY DELETE, UPDATE ON dbo.messages_history TO dsh_mem_a;
DENY DELETE, UPDATE ON dbo.messages_history TO dsh_mem_b;
DENY DELETE, UPDATE ON dbo.messages_history TO dsh_guard;
GO
