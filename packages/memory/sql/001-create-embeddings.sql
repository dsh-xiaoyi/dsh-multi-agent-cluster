-- dbo.embeddings -- F plan (semantic recall) storage, per DESIGN-F proposal section 3.
-- Owner of this DDL: 192.0.2.11 (the memory DB host).  Created 2026-10-06.
-- Why the PK is (item_type, item_id, model): models can coexist / be compared /
-- be rolled out gradually, and re-embedding is a plain upsert per model.
IF OBJECT_ID('dbo.embeddings') IS NULL
BEGIN
  CREATE TABLE dbo.embeddings (
    item_type   varchar(16)  NOT NULL,   -- 'message' | 'memory'
    item_id     bigint       NOT NULL,
    model       varchar(64)  NOT NULL,   -- e.g. 'bge-m3'
    dim         smallint     NOT NULL,   -- 1024 for bge-m3
    vec         varbinary(max) NOT NULL, -- float32 little-endian, dim*4 bytes
    text_hash   binary(16)   NOT NULL,   -- MD5(original text): "content changed -> re-embed"
    created_at  datetime2    NOT NULL CONSTRAINT DF_emb_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_embeddings PRIMARY KEY (item_type, item_id, model)
  );
  CREATE INDEX IX_embeddings_model ON dbo.embeddings(model, created_at DESC);
END
