-- 011-memory-signals.sql
-- Memory "four-stage" signals + full-text search (FTS) increment for the memory engine.
--
-- Adds the columns and tables the engine's four-stage recall path reads/writes
-- (ACCESS-REINFORCE / CO-OCCUR / MOOD / VALENCE-CONTEXT), then creates the full-text indexes
-- the two-stage FTS retrieval path relies on (FTS-2STAGE / FTS-SEARCH).
--
-- Idempotent: every statement is guarded by IF NOT EXISTS / COL_LENGTH, so it is safe to run
-- repeatedly.  SQL Server, single dialect (matches the engine's SQL Server usage).
--
-- FTS note: the KEY INDEX must point at each table's primary key.  The base tables are created
-- with inline `id bigint IDENTITY PRIMARY KEY`, so their PK names are auto-generated and differ
-- per instance; we resolve each PK name dynamically instead of hardcoding it.

-- 1) dbo.memories: four signal columns (older schemas may already have some; all guarded).
IF COL_LENGTH('dbo.memories', 'access_count') IS NULL
  ALTER TABLE dbo.memories ADD access_count INT NOT NULL CONSTRAINT DF_memories_access DEFAULT (0);
IF COL_LENGTH('dbo.memories', 'last_injected_at') IS NULL
  ALTER TABLE dbo.memories ADD last_injected_at DATETIME2 NULL;
IF COL_LENGTH('dbo.memories', 'valence') IS NULL
  ALTER TABLE dbo.memories ADD valence TINYINT NULL;   -- 0..10 mood signal; NULL = not set
IF COL_LENGTH('dbo.memories', 'context') IS NULL
  ALTER TABLE dbo.memories ADD context NVARCHAR(MAX) NULL;

-- 2) dbo.memory_refs: co-occurrence edges (cited pairs bumped during recall).
--    CO-OCCUR marker: the engine increments `relation='cooccurs'` weights on search hits.
IF OBJECT_ID('dbo.memory_refs', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.memory_refs (
    id         BIGINT      IDENTITY(1,1) NOT NULL CONSTRAINT PK_memory_refs PRIMARY KEY,
    memory_id  BIGINT      NOT NULL,
    cited_id   BIGINT      NOT NULL,
    relation   VARCHAR(24) NOT NULL CONSTRAINT DF_memory_refs_relation DEFAULT ('cooccurs'),
    weight     INT         NOT NULL CONSTRAINT DF_memory_refs_weight   DEFAULT (0),
    created_at DATETIME2   NOT NULL CONSTRAINT DF_memory_refs_created  DEFAULT (SYSUTCDATETIME())
  );
  CREATE INDEX IX_memory_refs_mem   ON dbo.memory_refs (memory_id, relation);
  CREATE INDEX IX_memory_refs_cited ON dbo.memory_refs (cited_id, relation);
  PRINT 'created dbo.memory_refs';
END
ELSE PRINT 'dbo.memory_refs already exists';

-- 3) dbo.agent_state: scalar mood/energy signals the engine decays each cycle.
--    MOOD marker: boredom / curiosity / energy / social_drive.
IF OBJECT_ID('dbo.agent_state', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.agent_state (
    state_name VARCHAR(32) NOT NULL CONSTRAINT PK_agent_state PRIMARY KEY,
    value      FLOAT       NOT NULL CONSTRAINT DF_agent_state_value   DEFAULT (0),
    updated_at DATETIME2   NOT NULL CONSTRAINT DF_agent_state_updated DEFAULT (SYSUTCDATETIME())
  );
  PRINT 'created dbo.agent_state';
END
ELSE PRINT 'dbo.agent_state already exists';

-- Seed (only when the row is missing).
IF NOT EXISTS (SELECT 1 FROM dbo.agent_state WHERE state_name = 'boredom')
  INSERT dbo.agent_state (state_name, value) VALUES ('boredom', 1.0);
IF NOT EXISTS (SELECT 1 FROM dbo.agent_state WHERE state_name = 'curiosity')
  INSERT dbo.agent_state (state_name, value) VALUES ('curiosity', 0.6);
IF NOT EXISTS (SELECT 1 FROM dbo.agent_state WHERE state_name = 'energy')
  INSERT dbo.agent_state (state_name, value) VALUES ('energy', 0.1);
IF NOT EXISTS (SELECT 1 FROM dbo.agent_state WHERE state_name = 'social_drive')
  INSERT dbo.agent_state (state_name, value) VALUES ('social_drive', 0.5);

-- 4) Full-text search: one catalog + one index on memories(title, body, tags) and messages(text),
--    LANGUAGE 2052 (Simplified Chinese), CHANGE_TRACKING AUTO (matches the live instance).
IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = N'ft_dshmemory')
  EXEC(N'CREATE FULLTEXT CATALOG ft_dshmemory;');

DECLARE @pk NVARCHAR(128);

IF NOT EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID('dbo.memories'))
BEGIN
  SELECT @pk = i.name FROM sys.indexes i
   WHERE i.object_id = OBJECT_ID('dbo.memories') AND i.is_primary_key = 1;
  IF @pk IS NOT NULL
    EXEC(N'CREATE FULLTEXT INDEX ON dbo.memories (title LANGUAGE 2052, body LANGUAGE 2052, tags LANGUAGE 2052) KEY INDEX ' + QUOTENAME(@pk) + N' ON ft_dshmemory WITH CHANGE_TRACKING AUTO;');
END

IF NOT EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID('dbo.messages'))
BEGIN
  SELECT @pk = i.name FROM sys.indexes i
   WHERE i.object_id = OBJECT_ID('dbo.messages') AND i.is_primary_key = 1;
  IF @pk IS NOT NULL
    EXEC(N'CREATE FULLTEXT INDEX ON dbo.messages (text LANGUAGE 2052) KEY INDEX ' + QUOTENAME(@pk) + N' ON ft_dshmemory WITH CHANGE_TRACKING AUTO;');
END

SELECT 'MEMORY-SIGNALS-READY' AS r;
