# 恢复与演练

> 第一次读到这里，不必一次记住；先照着跑一遍，遇到问题再回来查对应那一节。
## 目标

```
RPO：最近一次备份之后的数据，允许丢；备份频率决定 RPO（本项目示例：每日全库 + 每周整包）
RTO：从"发现坏了"到"服务可用"的时间；靠演练证明，不靠感觉
```

## 恢复路径必须"不依赖出故障的那一层"

```
故障层        恢复手段（优先级从高到低）
记忆库挂了    ① 从 .bak 恢复到临时库验证 ② 验证通过再切换 ③ 不要直接覆盖在用库
中枢挂了      ① 点对点（另一台机器直连）② 本地脚本 ③ 才考虑中枢
用户界面起不来 ① 交互式任务启动 ② 手动启动 ③ 远程桌面
```

## 恢复演练（示例：数据库）

```powershell
# 1) 校验备份可用（不覆盖任何东西）
sqlcmd -E -Q "RESTORE VERIFYONLY FROM DISK='D:\backup\DSHMemory_full.bak' WITH CHECKSUM"

# 2) 恢复到临时库
sqlcmd -E -Q "RESTORE DATABASE DSHMemory_restoretest FROM DISK='D:\backup\DSHMemory_full.bak'
              WITH MOVE 'DSHMemory' TO 'D:\data\restoretest.mdf',
                   MOVE 'DSHMemory_log' TO 'D:\data\restoretest_log.ldf', REPLACE"

# 3) 对平行数（记忆条数、消息条数）
# 4) 清理临时库
sqlcmd -E -Q "DROP DATABASE DSHMemory_restoretest"
```

## 演练判据（可复核）

```
① VERIFYONLY 通过  ② 恢复耗时与吞吐有数字  ③ 关键表行数对平  ④ 零残留
四条齐全才算 PASS；缺一条就写"未验证"，不写"应该没问题"
```

## 备份保留（示例口径）

```
本地整包：超过 180 天 → 提醒用户 → 用户确认后才删（脚本不自动删）
冷备：同样 180 天
云端：长期保留
打包用的明文暂存：确认同步后立即删除
```
