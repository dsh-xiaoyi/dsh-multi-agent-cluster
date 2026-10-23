-- 注意：表名沿用了内部实例的 sec_heartbeat，但它的**职能属于"时光守护"的 L1 跨机互监**
--      （记录"哪台机器在多久前还能探通对端"，用于跨机互监）
--      如你介意名字，可自行改名并把 heartbeat-l1.ps1 里的表名一起改掉。IF OBJECT_ID('dbo.sec_heartbeat','U') IS NULL
CREATE TABLE dbo.sec_heartbeat (
  id bigint IDENTITY PRIMARY KEY,
  machine nvarchar(64), target nvarchar(64), ip nvarchar(64),
  ts datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
  l1_ok bit, latency_ms int, detail nvarchar(200)
);
IF NOT EXISTS (SELECT 1 FROM sys.database_permissions WHERE grantee_principal_id=DATABASE_PRINCIPAL_ID('dsh_mem_a') AND major_id=OBJECT_ID('dbo.sec_heartbeat'))
  GRANT SELECT, INSERT ON dbo.sec_heartbeat TO [dsh_mem_a];
IF NOT EXISTS (SELECT 1 FROM sys.database_permissions WHERE grantee_principal_id=DATABASE_PRINCIPAL_ID('dsh_guard') AND major_id=OBJECT_ID('dbo.sec_heartbeat'))
  GRANT SELECT, INSERT ON dbo.sec_heartbeat TO [dsh_guard];
IF NOT EXISTS (SELECT 1 FROM sys.database_permissions WHERE grantee_principal_id=DATABASE_PRINCIPAL_ID('dsh_mem_b') AND major_id=OBJECT_ID('dbo.sec_heartbeat'))
  GRANT SELECT, INSERT ON dbo.sec_heartbeat TO [dsh_mem_b];
SELECT 'HEARTBEAT-TABLE-READY' AS r;