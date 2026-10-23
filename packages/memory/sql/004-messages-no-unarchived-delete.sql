-- 004-messages-no-unarchived-delete.sql
-- PHASE 3 of "memory with time": make it IMPOSSIBLE to destroy a message row that has no copy in
-- the append-only archive.  Database-side, host-side, no CLI change, no cluster rollout.
--
-- WHY THIS AND NOT "DENY DELETE ON dbo.messages":
--   sync must still remove rows the session log no longer has (that is how the current table keeps
--   mirroring the log).  A blanket DENY would break every sync.  What actually needs enforcing is
--   the INVARIANT: *every real removal is preceded by an archive*.  Measured 2026-10-06: after a
--   truncated-log sync, all 4 removed rows already had a copy in dbo.messages_history.
--   So the trigger refuses only the deletes that would lose something.
--
-- EXEMPTION for probe sessions (guard*/p2*): the guards create throwaway sessions and must be able
--   to clean them up without archiving -- they are test artifacts, not memory (66 such rows existed
--   when this was written).  ANY scratch/experiment session must therefore use a `guard` or `p2`
--   prefix, otherwise its cleanup will be refused (that is a feature: it forces the prefix).
--
-- REVERSIBILITY (recorded so a future session can undo it in one statement):
--   DROP TRIGGER dbo.trg_messages_require_archive;
--
-- Run with Windows integrated auth (the machine logins have no DDL rights, by design):
--   sqlcmd -S 192.0.2.11,1433 -d DSHMemory -E -i 004-messages-no-unarchived-delete.sql

IF OBJECT_ID('dbo.trg_messages_require_archive', 'TR') IS NOT NULL
  DROP TRIGGER dbo.trg_messages_require_archive;
GO

CREATE TRIGGER dbo.trg_messages_require_archive
ON dbo.messages
INSTEAD OF DELETE
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @missing int;

  SELECT @missing = COUNT(*)
  FROM deleted d
  WHERE d.session_id NOT LIKE 'guard%'
    AND d.session_id NOT LIKE 'p2%'
    AND NOT EXISTS (
      SELECT 1 FROM dbo.messages_history h
      WHERE h.session_id = d.session_id AND h.seq = d.seq
    );

  IF @missing > 0
  BEGIN
    DECLARE @msg nvarchar(400) =
      N'Phase 3 protection: refusing to delete ' + CAST(@missing AS nvarchar(10)) +
      N' row(s) from dbo.messages that have no copy in dbo.messages_history. ' +
      N'Every real removal must be preceded by an archive (sync does this automatically). ' +
      N'Probe sessions (session_id starting with guard or p2) are exempt.';
    RAISERROR(@msg, 16, 1);
    RETURN;   -- nothing at all is deleted: fail closed, and loudly
  END

  -- all rows are precedented (or exempt) -> perform the real delete
  DELETE m
  FROM dbo.messages m
  JOIN deleted d ON d.id = m.id;
END
GO

-- health check (informational): the trigger must exist and be enabled
SELECT name, is_disabled, is_instead_of_trigger
FROM sys.triggers
WHERE parent_id = OBJECT_ID('dbo.messages');
GO
