-- 012-text-hash1200.sql
-- [OPENSOURCE-20261124] 方案A：messages / memories 加持久化 text_hash1200 列 + 非聚簇索引，
-- 取代 HASHBYTES('MD5', LEFT(text,1200)) 的全表扫（TEXT-HASH1200）。
--
-- 根因（2026-11-24 实测）：HASHBYTES('MD5',LEFT(text,1200)) IN (20 字面量) 无法走索引，
--   对 600MB / 12 万行的 dbo.messages 做了约 20 遍全表扫 = 31,675ms，占 recall 的 75%。
--   持久化列为 binary(16)（MD5 of LEFT(text,1200)），配合非唯一索引，改后实测 5ms。
--
-- 幂等：每条语句都按 COL_LENGTH / 索引名存在判断；可重复执行。
-- 本文件只出脚本，不执行 DDL。SQL Server 单方言（与引擎用法一致）。
-- 列由写入路径维护（dsh-mem.ps1 的 INSERT/UPDATE + spool-import.ps1），并有自愈兜底回填。

-- 1) dbo.messages：text_hash1200 列 + 非聚簇索引
IF COL_LENGTH('dbo.messages', 'text_hash1200') IS NULL
  ALTER TABLE dbo.messages ADD text_hash1200 BINARY(16) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_messages_text_hash1200' AND object_id = OBJECT_ID('dbo.messages'))
  CREATE NONCLUSTERED INDEX IX_messages_text_hash1200 ON dbo.messages (text_hash1200);

-- 2) dbo.memories：text_hash1200 列 + 非聚簇索引（与 messages 对齐，供内容寻址）
IF COL_LENGTH('dbo.memories', 'text_hash1200') IS NULL
  ALTER TABLE dbo.memories ADD text_hash1200 BINARY(16) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_memories_text_hash1200' AND object_id = OBJECT_ID('dbo.memories'))
  CREATE NONCLUSTERED INDEX IX_memories_text_hash1200 ON dbo.memories (text_hash1200);

-- 3) 自愈兜底回填（幂等，只补 NULL 的一小批；与引擎 Get-MessagesByHash 的兜底一致）
UPDATE TOP (500) dbo.messages
   SET text_hash1200 = CONVERT(binary(16), HASHBYTES('MD5', LEFT(ISNULL(text, ''), 1200)))
 WHERE text_hash1200 IS NULL;

SELECT 'TEXT-HASH1200-READY' AS r;
