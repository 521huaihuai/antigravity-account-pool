<#
.SYNOPSIS
    Antigravity 本地账号池（命令行版）。

.DESCRIPTION
    只做三件事：备份凭据快照、写回凭据、重启客户端。
    不监听端口、不代理/改写/重放任何网络请求，也不修改 Antigravity 程序文件。

    凭据位置：Windows 凭据管理器 gemini:antigravity
    快照位置：%USERPROFILE%\.antigravity-pool\（DPAPI 当前用户加密）

.EXAMPLE
    .\agpool.ps1 list
    .\agpool.ps1 capture 主号
    .\agpool.ps1 switch 小号
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'current', 'capture', 'switch', 'remove', 'rename', 'nickname', 'shortcut', 'help')]
    [string]$Command = 'list',

    [Parameter(Position = 1)]
    [string]$Label,

    [Parameter(Position = 2)]
    [string]$NewLabel,

    [string]$AppPath,

    [switch]$NoRestart,
    [switch]$Yes,
    [switch]$Clear
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AgPool.Core.ps1')

function Write-Head($text) {
    Write-Host ''
    Write-Host "  $text" -ForegroundColor Cyan
}

function Show-Help {
    Write-Head 'Antigravity 本地账号池'
    @"
  用法：
    .\agpool.ps1 list               查看号池
    .\agpool.ps1 current            查看当前生效账号
    .\agpool.ps1 capture <名称>     保存当前登录账号
    .\agpool.ps1 switch <名称>      切换账号（会关闭并重启 Antigravity）
    .\agpool.ps1 switch <名称> -NoRestart   只写凭据，稍后手动启动
    .\agpool.ps1 remove <名称>      删除快照
    .\agpool.ps1 rename <旧> <新>   重命名快照
    .\agpool.ps1 nickname <名称> <昵称>   设置昵称；用 -Clear 清除
    .\agpool.ps1 shortcut <名称>    生成桌面一键切号快捷方式

  图形界面：
    双击 "agpool-gui.cmd"

  说明：
    本工具只在本地读写凭据管理器条目 gemini:antigravity，
    不监听端口、不代理或改写任何请求，也不修改 Antigravity 程序文件。
"@ | Write-Host
}

switch ($Command) {

    'help' { Show-Help }

    'list' {
        $profiles = @(Get-Profiles)
        $currentEmail = $null
        try { $currentEmail = (Get-CurrentAccount).Email } catch { }

        Write-Head "号池：$($script:ProfilesRoot)"
        if ($profiles.Count -eq 0) {
            Write-Host '  暂无账号。先在 Antigravity 登录，然后运行：.\agpool.ps1 capture 名称' -ForegroundColor DarkGray
            Write-Host ''
            return
        }

        $rows = foreach ($p in $profiles) {
            [pscustomobject]@{
                ACTIVE   = $(if ($p.Email -eq $currentEmail) { '*' } else { '' })
                LABEL    = $p.Label
                NICKNAME = $p.Nickname
                EMAIL    = $p.Email
                SAVED    = $p.CapturedAt
            }
        }
        $rows | Sort-Object @{ Expression = { if ($_.ACTIVE -eq '*') { 0 } else { 1 } } }, LABEL |
            Format-Table -AutoSize | Out-String -Width 140 | Write-Host
        Write-Host "  当前生效：$currentEmail" -ForegroundColor DarkGray
        Write-Host ''
    }

    'current' {
        try {
            $cur = Get-CurrentAccount
            $state = Get-State
            Write-Head '当前生效账号'
            Write-Host "  邮箱    : $($cur.Email)"
            Write-Host "  凭据到期: $($cur.Info.Expiry)"
            Write-Host "  快照    : $($state.active)"
            Write-Host "  可刷新  : $($cur.Info.HasRefresh)"
            Write-Host ''
        }
        catch {
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host ''
        }
    }

    'capture' {
        Assert-Label $Label
        $cur = Get-CurrentAccount
        $existing = Get-Profiles | Where-Object { $_.Label -eq $Label }
        if ($existing -and $existing.Email -ne $cur.Email) {
            Write-Warning "  名称 '$Label' 已被 $($existing.Email) 占用，本次将覆盖为 $($cur.Email)。"
        }
        $info = Save-Profile -Name $Label -Bytes $cur.Bytes -Source 'capture'
        Set-State -Active $Label
        Write-Head "已保存：$Label"
        Write-Host "  邮箱：$($info.Email)"
        Write-Host "  文件：$(Join-Path $script:ProfilesRoot $Label)"
        Write-Host ''
    }

    'switch' {
        Assert-Label $Label
        $profile = Get-Profile -Name $Label
        $targetEmail = $null
        try {
            $bytes = Unprotect-Bytes -Text ([IO.File]::ReadAllText($profile.CredFile, [Text.Encoding]::ASCII))
            $targetEmail = (Get-BlobInfo -Bytes $bytes).Email
        }
        catch { throw "快照 '$Label' 无法读取：$($_.Exception.Message)" }

        if (-not $Yes) {
            Write-Host ''
            Write-Host "  即将切换到：$targetEmail  [$Label]" -ForegroundColor Yellow
            Write-Host '  这会关闭并重启 Antigravity，未保存的对话或正在运行的 Agent 会中断。' -ForegroundColor Yellow
            $answer = Read-Host '  继续？(y/N)'
            if ($answer -notmatch '^(y|yes)$') { Write-Host '  已取消。' -ForegroundColor DarkGray; return }
        }

        Write-Host '  正在切换 ...' -ForegroundColor DarkGray
        $result = Invoke-AgPoolSwitch -Label $Label -NoRestart:$NoRestart -AppPath $AppPath
        Write-Head "已切换到 $($result.Email)"
        if ($NoRestart) {
            Write-Host '  已按 -NoRestart 跳过启动，请手动打开 Antigravity。' -ForegroundColor DarkGray
        }
        else {
            Write-Host '  客户端正在启动，登录态由官方客户端自行加载。'
        }
        Write-Host ''
    }

    'remove' {
        Assert-Label $Label
        $profile = Get-Profile -Name $Label
        if (-not $Yes) {
            Write-Host ''
            Write-Host "  将删除快照：$Label  ($($profile.Email))" -ForegroundColor Yellow
            Write-Host "  目录：$($profile.Dir)" -ForegroundColor Yellow
            $answer = Read-Host '  继续？(y/N)'
            if ($answer -notmatch '^(y|yes)$') { Write-Host '  已取消。' -ForegroundColor DarkGray; return }
        }
        Remove-Item -LiteralPath $profile.Dir -Recurse -Force
        $state = Get-State
        if ($state.active -eq $Label) { Set-State -Active '' }
        Write-Host "  已删除：$Label" -ForegroundColor DarkGray
        Write-Host ''
    }

    'rename' {
        Assert-Label $Label
        Assert-Label $NewLabel
        $profile = Get-Profile -Name $Label
        $dest = Join-Path $script:ProfilesRoot $NewLabel
        if (Test-Path -LiteralPath $dest) { throw "名称 '$NewLabel' 已存在。" }

        Move-Item -LiteralPath $profile.Dir -Destination $dest
        $metaFile = Join-Path $dest 'meta.json'
        $meta = Get-Content -LiteralPath $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $meta.label = $NewLabel
        [IO.File]::WriteAllText($metaFile, ($meta | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($true)))

        $state = Get-State
        if ($state.active -eq $Label) { Set-State -Active $NewLabel }
        Write-Host "  已重命名：$Label -> $NewLabel" -ForegroundColor Green
        Write-Host ''
    }

    'nickname' {
        Assert-Label $Label
        $profile = Get-Profile -Name $Label

        if ($Clear) { $value = '' }
        elseif ($PSBoundParameters.ContainsKey('NewLabel')) { $value = $NewLabel }
        else { throw '请提供昵称，或用 -Clear 清除：.\agpool.ps1 nickname 名称 昵称' }

        $saved = Set-ProfileNickname -Name $Label -Nickname $value
        if ($saved) { Write-Host "  已将 $Label 的昵称设为：$saved" -ForegroundColor Green }
        else { Write-Host "  已清除 $Label 的昵称" -ForegroundColor DarkGray }
        Write-Host ''
    }

    'shortcut' {
        Assert-Label $Label
        $profile = Get-Profile -Name $Label
        $scriptPath = $PSCommandPath
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desktop ("Antigravity - $Label.lnk")

        $hostExe = (Get-Process -Id $PID).Path
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = $hostExe
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" switch `"$Label`" -Yes"
        $lnk.WorkingDirectory = Split-Path -Path $scriptPath -Parent
        $lnk.IconLocation = "$(Get-AppExecutable -Override $AppPath),0"
        $lnk.Description = "切换到 $($profile.Email)"
        $lnk.Save()

        Write-Host "  已创建快捷方式：$lnkPath" -ForegroundColor Green
        Write-Host ''
    }
}
