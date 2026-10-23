-- 005-create-credentials.sql · 专门的密码库（凭据仓库）· 11 维护 · 2026-10-11
-- 目的：把散落在 kind='secret' 里的"密码 + 对应地址"整理成**可结构化调用**的表。
-- 依据：凭据可以明文保存在**受控的共享库**里，但只走 secret 通道；口令不要经由命令行传递。
-- 原则：**只增不改** —— 本表是新的调用入口，原有 secret 条目一律保留 ✓
-- 幂等：可重复执行 ✓

IF OBJECT_ID('dbo.credentials','U') IS NULL
BEGIN
  CREATE TABLE dbo.credentials (
    id          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_credentials PRIMARY KEY,
    name        NVARCHAR(160) NOT NULL,          -- 唯一调用名，如 sql-sa-3x / share-node-c / mail-163-xxx
    category    NVARCHAR(40)  NOT NULL,          -- sql-login|share|game-account|app-key|product-key|backup-code|address|prose-blob|other
    address     NVARCHAR(300) NULL,              -- 对应地址：主机/UNC/URL/IP,端口；没有就 NULL
    username    NVARCHAR(160) NULL,
    secret      NVARCHAR(MAX) NULL,              -- 明文（R39 授权）
    extra       NVARCHAR(MAX) NULL,              -- 备注/JSON：端口、驱动、用途、关联
    source_ref  NVARCHAR(160) NULL,              -- 来源：'[922]' / 'artifact 1304' / 'owner 2026-10-11'
    is_active   BIT NOT NULL CONSTRAINT DF_credentials_active DEFAULT (1),
    created_at  DATETIME2(0) NOT NULL CONSTRAINT DF_credentials_created DEFAULT (SYSUTCDATETIME()),
    updated_at  DATETIME2(0) NOT NULL CONSTRAINT DF_credentials_updated DEFAULT (SYSUTCDATETIME())
  );
  CREATE UNIQUE INDEX UX_credentials_name ON dbo.credentials(name);
  CREATE INDEX IX_credentials_cat ON dbo.credentials(category, is_active);
END
GO

-- 安全视图：**不含 secret 列** ⇒ 列清单/浏览用它，不会把明文带到报告或截图里
IF OBJECT_ID('dbo.credentials_safe','V') IS NULL
  EXEC('CREATE VIEW dbo.credentials_safe AS
        SELECT id, name, category, address, username,
               CASE WHEN secret IS NULL THEN 0 ELSE LEN(secret) END AS secret_len,
               extra, source_ref, is_active, created_at, updated_at
        FROM dbo.credentials')
GO

-- 审计视图：谁在什么时候被调用过（可选，先建空表；工具会写）
IF OBJECT_ID('dbo.credential_access','U') IS NULL
BEGIN
  CREATE TABLE dbo.credential_access (
    id         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_credential_access PRIMARY KEY,
    name       NVARCHAR(160) NOT NULL,
    action     NVARCHAR(40)  NOT NULL,   -- get|export|list|verify
    machine    NVARCHAR(60)  NULL,
    actor      NVARCHAR(120) NULL,
    at         DATETIME2(0)  NOT NULL CONSTRAINT DF_credaccess_at DEFAULT (SYSUTCDATETIME())
  );
  CREATE INDEX IX_credaccess_name ON dbo.credential_access(name, at DESC);
END
GO
