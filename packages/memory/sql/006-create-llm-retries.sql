-- 006-create-llm-retries.sql (v2) · 模型请求重试事件表 · 11 · 2026-10-11
-- v1 用了列名 `at`，与 T-SQL 的 AT（AT TIME ZONE）冲突 ⇒ 改为 `at_utc` ✓
-- 幂等：可重复执行 ✓（表结构不符时先删重建 —— 该表只存事件，重建不丢原始数据，
-- 因为原始数据在会话日志里，随时可重新导入 ✓）
IF OBJECT_ID('dbo.llm_retry_daily','V') IS NOT NULL DROP VIEW dbo.llm_retry_daily;
GO
IF OBJECT_ID('dbo.llm_retries','U') IS NOT NULL AND COL_LENGTH('dbo.llm_retries','at_utc') IS NULL
BEGIN
  DROP TABLE dbo.llm_retries;
END
GO
IF OBJECT_ID('dbo.llm_retries','U') IS NULL
BEGIN
  CREATE TABLE dbo.llm_retries (
    id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_llm_retries PRIMARY KEY,
    machine      NVARCHAR(60)  NOT NULL,
    session_id   NVARCHAR(160) NULL,
    retry_id     NVARCHAR(64)  NOT NULL,
    at_utc       DATETIME2(0)  NOT NULL,
    turn         INT NULL,
    step         INT NULL,
    attempt      INT NOT NULL,
    max_retries  INT NULL,
    delay_ms     FLOAT NULL,
    code         NVARCHAR(40)  NULL,
    message      NVARCHAR(240) NULL,
    imported_at  DATETIME2(0)  NOT NULL CONSTRAINT DF_llmretries_imported DEFAULT (SYSUTCDATETIME())
  );
  CREATE UNIQUE INDEX UX_llm_retries_row ON dbo.llm_retries(machine, retry_id, attempt);
  CREATE INDEX IX_llm_retries_at ON dbo.llm_retries(at_utc DESC);
  CREATE INDEX IX_llm_retries_code ON dbo.llm_retries(code, at_utc DESC);
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_permissions WHERE major_id = OBJECT_ID('dbo.llm_retries') AND grantee_principal_id = USER_ID('dsh_mem_a'))
BEGIN
  GRANT SELECT, INSERT ON dbo.llm_retries TO dsh_mem_a, dsh_mem_b, dsh_guard, dsh_memory;
END
GO
CREATE VIEW dbo.llm_retry_daily AS
SELECT CAST(r.at_utc AS DATE) AS day,
       r.machine,
       COUNT(*)                       AS retry_rows,
       COUNT(DISTINCT r.retry_id)     AS incidents,
       SUM(CASE WHEN r.attempt >= r.max_retries THEN 1 ELSE 0 END) AS at_cap,
       CAST(SUM(r.delay_ms) / 1000.0 AS DECIMAL(10,1)) AS backoff_seconds,
       MAX(r.attempt)                 AS worst_attempt
FROM dbo.llm_retries r
GROUP BY CAST(r.at_utc AS DATE), r.machine
GO
