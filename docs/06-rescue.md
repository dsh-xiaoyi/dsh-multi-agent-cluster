# 故障自诊与回滚（dsh-rescue 方法）

> 场景：改了 DSH 配置/插件之后，它起不来、或者行为异常。
> 原则：**先取证，再回滚；不要"凭感觉重装"**。

> 第一次读到这里，不必一次记住；先照着跑一遍，遇到问题再回来查对应那一节。
## 一、证据在哪（按优先级）

| 证据 | 位置（占位） | 说明 |
|---|---|---|
| 插件安装日志 | `~/.dsh/profiles/<p>/.plugin-manager/logs/operation-*\pnpm.log` | 装了什么、报了什么 |
| 插件补丁 | `~/.dsh/profiles/<p>/cordis.patch.yml` | 改过什么；看有没有 `.bak-before-*` |
| 会话投影缓存 | `~/.dsh/storages/session_projcache/sessions/*.json` | 会话状态异常时看 |
| GitHub 拉取日志 | `~/.dsh/profiles/<p>/logs/github-connection-*\git.log` | 私有源/网络问题 |
| 桥/插件日志 | 插件配置里的 `logPath` | 是否 ARMED、是否注入失败 |
| 记忆库 | `messages` / `memories` / `ops_findings` | 什么时候改的、改了什么 |

> **红线**：`~/.dsh/.credentials.yaml`、`attachments`、`session_projcache` 属隐私，取证时不要外发。

## 二、决策树（先定"能不能不重装"）

```
DSH 起不来？
├─ 有 cordis.patch.yml.bak-before-* ？
│   ├─ 有 → R1 配置回滚（拷回 .bak → 重启）
│   └─ 无 → 看 pnpm.log 最后失败点 → R2 插件回滚
├─ 能起但插件行为异常？
│   ├─ 先 R3 只禁用（disabled: true），别急着卸载 —— 最安全的第一步
│   └─ 确认是新插件导致 → R2
└─ 会话/记忆读不出来？
    ├─ 先只读检查库（不要写）
    └─ 需要恢复 → R4 记忆库回滚（还原到临时库验证后再切换）
```

## 三、五套回滚剧本

```
R1 配置回滚：copy cordis.patch.yml.bak-before-<原因>-<时间> 覆盖 → 重启
R2 插件回滚：从 package.json 移除依赖 → 删除 node_modules 中对应目录 → 重启
R3 只禁用  ：patch 里 disabled: true（不卸载）→ 重启；验证通过再决定是否卸载
R4 库回滚  ：RESTORE 到临时库 → 校验行数 → 改名切换（不要直接覆盖在用库）
R5 全局兜底：整个 profile 目录快照（打包前先停 DSH，避免文件半写）
```

## 四、每次改动前的三条预防

```
① 先备份：任何 patch/index.mjs 改动前，存一份 .bak-before-<原因>-<时间>
② 改完必重启：插件改动不重启 = 改动未生效（且会静默失效）
③ 留行为证据：重启后看"新版本才有的输出"，不要只看进程在不在
```
