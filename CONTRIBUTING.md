# 贡献指南

## 最重要的一条

**提交前必须跑 secret-scan，BLOCK 必须为 0。**

```powershell
powershell -File ops\secret-scan.ps1 -Root .
```

它会把真实私网 IP、邮箱、口令、令牌、私钥标成 BLOCK；示例值请用
`192.0.2.x`（RFC 5737 文档网段）、`EXAMPLE_PASSWORD`、`EXAMPLE_TOKEN_0000000000`。

## 报告问题

- 用 issue，写清：现象、期望、复现步骤、`ops\doctor.ps1` 输出（脱敏后）。
- **贴日志前先脱敏**：主机名、IP、账号、令牌一律替换。
- 涉及安全问题的（泄露、注入风险），请走 `SECURITY.md` 里的私密渠道，不要开公开 issue。

## 提交代码

1. Fork → 分支（`feat/xxx`、`fix/xxx`）
2. 改动要有**可复核的证据**：数字、命令输出、截图（脱敏）
3. 新增规则/脚本要写清"它判什么、什么情况下会误报"
4. 提交信息：`type(scope): 一句话`，例如 `fix(guard): 修正周包检查的自相矛盾判据`

## 代码风格

- PowerShell 脚本带 UTF-8 BOM（否则 5.1 读中文会乱码）
- 不做"静默失败（最不建议的做法）"：出错要打印原因，不能吞掉
- 不写"差不多/应该可以"：判据必须一义
