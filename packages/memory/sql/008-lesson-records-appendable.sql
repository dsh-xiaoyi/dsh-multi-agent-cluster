-- 008-lesson-records-appendable.sql
-- Make dbo.lesson_records usable as the living RECORDS LIBRARY, not just a migration target:
--   * native records (guard errors / incidents) have no dbo.memories source  -> source_id becomes NULLable
--     (a plain UNIQUE constraint counts NULLs as equal, so it is replaced by a FILTERED unique index)
--   * every record says what it is (record_kind) and where it came from (origin), plus when it happened
--   * the safe view is recreated so it exposes the new columns
-- 2026-10-12 / item 2 step C.  Idempotent: safe to re-run.
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_lesson_records_source' AND parent_object_id = OBJECT_ID('dbo.lesson_records'))
BEGIN
  ALTER TABLE dbo.lesson_records DROP CONSTRAINT UQ_lesson_records_source;
  PRINT 'dropped UQ_lesson_records_source';
END
GO
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.lesson_records') AND name = 'source_id' AND is_nullable = 0)
BEGIN
  ALTER TABLE dbo.lesson_records ALTER COLUMN source_id INT NULL;
  PRINT 'source_id is now NULLable';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_lesson_records_source' AND object_id = OBJECT_ID('dbo.lesson_records'))
BEGIN
  CREATE UNIQUE INDEX UX_lesson_records_source ON dbo.lesson_records(source_id) WHERE source_id IS NOT NULL;
  PRINT 'created filtered unique index UX_lesson_records_source';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.lesson_records') AND name = 'record_kind')
BEGIN
  ALTER TABLE dbo.lesson_records ADD record_kind VARCHAR(24) NOT NULL CONSTRAINT DF_lesson_records_kind DEFAULT ('lesson');
  PRINT 'added record_kind';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.lesson_records') AND name = 'origin')
BEGIN
  ALTER TABLE dbo.lesson_records ADD origin NVARCHAR(120) NULL;
  PRINT 'added origin';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.lesson_records') AND name = 'happened_at')
BEGIN
  ALTER TABLE dbo.lesson_records ADD happened_at DATETIME2(3) NULL;
  PRINT 'added happened_at';
END
GO
-- recreate the view so the new columns are visible (a view expands its column list at creation)
IF OBJECT_ID('dbo.lesson_records_safe', 'V') IS NOT NULL DROP VIEW dbo.lesson_records_safe;
GO
CREATE VIEW dbo.lesson_records_safe AS
SELECT record_id, source_id, record_kind, lesson_no, title, body_len, body_sha16,
       subject, origin, happened_at, created_at, moved_at
FROM dbo.lesson_records;
GO
IF OBJECT_ID('dbo.lesson_index', 'V') IS NOT NULL DROP VIEW dbo.lesson_index;
GO
CREATE VIEW dbo.lesson_index AS
SELECT source_id AS memory_id, record_id, record_kind, lesson_no, title, body_len, moved_at
FROM dbo.lesson_records;
GO
