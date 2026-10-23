# WinRM 基线（跨机管理）

> 只用于内网、专用账号、最小权限。**不要**把 WinRM 暴露到公网。

> 第一次读到这里，不必一次记住；先照着跑一遍，遇到问题再回来查对应那一节。
## 实测基线（Windows Server / Windows 10）

```
服务      WinRM: Running
监听      5985 (HTTP)
AllowUnencrypted  false
Basic             false
Kerberos          true
```

## 快速检查

```powershell
Get-Service WinRM | Select Name, Status
winrm enumerate winrm/config/listener
winrm get winrm/config/service
```

## 启用（内网，示例）

```powershell
Enable-PSRemoting -Force
# 若用工作组的本地账号，需要显式信任主机（不推荐域外长期使用）
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.0.2.17,192.0.2.18" -Concatenate
```

## 常用远端操作

```powershell
$c = Get-Credential
Invoke-Command -ComputerName 192.0.2.17 -Credential $c -ScriptBlock { Get-Service DSH* }
```

## 限制与坑

- 远端 `cmd.exe` 在受限令牌下可能被拒（报"拒绝访问"）——用 `Invoke-Command` 内直接跑 PowerShell，别套 cmd
- 需要"用户可见界面"的操作不要用 WinRM 启动：那是 session 0，看不见
- 凭证不要写进脚本；用 `Get-Credential` 或保管库
