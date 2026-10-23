-- 007-create-lesson-records.sql
-- Dedicated records library for LESSONS (error/incident records), item 2 of the five-thread close-out.
-- WHY: lessons are the biggest entries on the memory board (35 rows, avg ~3,900 chars) and they are
--      NOT rules -- nothing should read them at startup.  Moving them into their own table lets the
--      board stay a board, while the records library stays fully searchable on demand.
-- SAFETY: this script only CREATES; it never deletes.  The copy + read-back verification, and any
--      later purge of the source rows, are done by round3-lessons-to-records.ps1 (dry run by default).
-- Encoding: UTF-8 WITHOUT BOM (SQL files are read by sqlcmd / SSMS, not by PowerShell).
IF OBJECT_ID('dbo.lesson_records', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.lesson_records (
    record_id   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_lesson_records PRIMARY KEY,
    source_id   INT               NOT NULL,            -- dbo.memories.id this record was migrated from
    lesson_no   VARCHAR(32)       NULL,                -- 'LESSON 007' etc, parsed from the title
    title       NVARCHAR(200)     NOT NULL,
    body        NVARCHAR(MAX)     NOT NULL,
    body_len    INT               NOT NULL,            -- length AT migration time (read-back check)
    body_sha16  CHAR(16)          NOT NULL,            -- SHA256(body) first 16 hex, for the read-back check
    tags        NVARCHAR(400)     NULL,
    scope       NVARCHAR(64)      NULL,
    subject     NVARCHAR(64)      NULL,
    created_at  DATETIME2(3)      NULL,                -- original memory creation time
    moved_at    DATETIME2(3)      NOT NULL CONSTRAINT DF_lesson_records_moved DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT UQ_lesson_records_source UNIQUE (source_id)
  );
  PRINT 'created dbo.lesson_records';
END
ELSE PRINT 'dbo.lesson_records already exists';
GO
IF OBJECT_ID('dbo.lesson_records_safe', 'V') IS NULL
BEGIN
  EXEC('CREATE VIEW dbo.lesson_records_safe AS
        SELECT record_id, source_id, lesson_no, title, body_len, body_sha16, subject, created_at, moved_at
        FROM dbo.lesson_records;');
  PRINT 'created dbo.lesson_records_safe (no body column)';
END
ELSE PRINT 'dbo.lesson_records_safe already exists';
GO
-- The memory board keeps a pointer for every migrated lesson, so a search on the board still finds it.
IF OBJECT_ID('dbo.lesson_index', 'V') IS NULL
BEGIN
  EXEC('CREATE VIEW dbo.lesson_index AS
        SELECT source_id AS memory_id, lesson_no, title, body_len, moved_at
        FROM dbo.lesson_records;');
  PRINT 'created dbo.lesson_index (board-side pointer view)';
END
ELSE PRINT 'dbo.lesson_index already exists';
GO
