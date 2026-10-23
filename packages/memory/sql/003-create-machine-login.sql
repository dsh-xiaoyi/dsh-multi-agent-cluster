-- 003-create-machine-login.sql  (TEMPLATE - parameters are substituted by new-machine-cred.ps1)
--
-- WHY a per-machine login (not one shared account): a shared account cannot be rotated for one
-- machine without disrupting the others, and it makes the audit trail ("who wrote this row")
-- meaningless.  The old shared account dsh_memory is DISABLED for exactly that reason.
--
-- PRIVILEGE MODEL (least privilege that still lets dsh-mem.ps1 do its job):
--   * data tables      : SELECT/INSERT/UPDATE/DELETE  (sync upserts, memories are edited)
--   * dbo.embeddings   : SELECT/INSERT/UPDATE/DELETE  (embed + housekeeping re-point/clean)
--   * dbo.machines     : SELECT/INSERT/UPDATE         (roster MERGE; no DELETE - rows are a registry)
--   * dbo.messages_history : INSERT/SELECT **plus an explicit DENY DELETE,UPDATE**
--       The DENY is required, not cosmetic: these logins also receive DATABASE-level rights, and a
--       database-level GRANT covers every table created later -- including this one.  A table-level
--       DENY overrides the wider GRANT, which is what makes history append-only.  (Found by guard
--       check 16e on 2026-10-06 after a plain GRANT of INSERT/SELECT failed to stop deletes.)
--   * NO DDL, NO BACKUP unless the machine is the database host.
--
-- Run on the host with Windows integrated auth:
--   sqlcmd -S 192.0.2.11,1433 -d DSHMemory -E -v login="dsh_mem_new" pw="..." -i 003-create-machine-login.sql

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$(login)')
  CREATE LOGIN [$(login)] WITH PASSWORD = N'$(pw)', CHECK_POLICY = ON;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(login)')
  CREATE USER [$(login)] FOR LOGIN [$(login)];
GO
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.sessions         TO [$(login)];
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.messages         TO [$(login)];
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.memories         TO [$(login)];
GRANT SELECT, INSERT, UPDATE         ON dbo.machines         TO [$(login)];
GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.embeddings       TO [$(login)];
GRANT INSERT, SELECT                 ON dbo.messages_history TO [$(login)];
DENY  DELETE, UPDATE                 ON dbo.messages_history TO [$(login)];
GO

-- verification (run as the NEW login; DELETE must come back 0 and INSERT 1):
--   SELECT SUSER_SNAME(),
--          HAS_PERMS_BY_NAME('dbo.messages_history','OBJECT','DELETE') AS can_delete_history,
--          HAS_PERMS_BY_NAME('dbo.messages_history','OBJECT','INSERT') AS can_insert_history;
