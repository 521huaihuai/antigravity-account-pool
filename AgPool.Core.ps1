# AgPool.Core.ps1
# 公共核心：凭据读写、快照管理、切号流程。
# 不监听端口、不代理请求、不修改 Antigravity 程序文件。

$ErrorActionPreference = 'Stop'

$script:CredTarget   = 'gemini:antigravity'
$script:Root         = Join-Path $env:USERPROFILE '.antigravity-pool'
$script:ProfilesRoot = Join-Path $script:Root 'profiles'
$script:StateFile    = Join-Path $script:Root 'state.json'

if (-not ('AgPool.CredApi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace AgPool {
    public static class CredApi {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct CREDENTIAL {
            public uint Flags;
            public uint Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credPtr);

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CredWrite(ref CREDENTIAL cred, uint flags);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool CredFree(IntPtr cred);
    }
}
'@
}

function Get-AppExecutable {
    param([string]$Override)
    if ($Override) {
        if (-not (Test-Path -LiteralPath $Override)) { throw "找不到指定路径：$Override" }
        return (Resolve-Path -LiteralPath $Override).Path
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe'),
        (Join-Path $env:ProgramFiles 'Antigravity\Antigravity.exe')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    throw '未找到 Antigravity.exe，请用 -AppPath 显式指定。'
}

function Assert-Label {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw '必须指定账号名称。' }
    if ($Name -eq '.' -or $Name -eq '..') { throw '非法名称。' }
    if ($Name -match '[\\/:*?"<>|\x00-\x1f]') { throw '名称不能包含 \ / : * ? " < > | 或控制字符。' }
    if ($Name.Length -gt 40) { throw '名称最长 40 个字符。' }
}

function Read-CredentialBlob {
    $ptr = [IntPtr]::Zero
    if (-not [AgPool.CredApi]::CredRead($script:CredTarget, 1, 0, [ref]$ptr)) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($err -eq 1168) { throw "凭据管理器里没有 $($script:CredTarget)，请先在 Antigravity 中登录。" }
        throw "读取凭据失败，Win32 错误码 $err"
    }
    try {
        $c = [Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][AgPool.CredApi+CREDENTIAL])
        $bytes = New-Object byte[] $c.CredentialBlobSize
        [Runtime.InteropServices.Marshal]::Copy($c.CredentialBlob, $bytes, 0, $c.CredentialBlobSize)
        return ,$bytes
    }
    finally {
        [AgPool.CredApi]::CredFree($ptr) | Out-Null
    }
}

function Write-CredentialBlob {
    param([byte[]]$Bytes)
    $c = [AgPool.CredApi+CREDENTIAL]::new()
    $c.Type = 1
    $c.TargetName = $script:CredTarget
    $c.UserName = 'antigravity'
    $c.Persist = 2
    $c.CredentialBlobSize = [uint32]$Bytes.Length
    $c.CredentialBlob = [Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes.Length)
    try {
        [Runtime.InteropServices.Marshal]::Copy($Bytes, 0, $c.CredentialBlob, $Bytes.Length)
        if (-not [AgPool.CredApi]::CredWrite([ref]$c, 0)) {
            throw "写入凭据失败，Win32 错误码 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($c.CredentialBlob)
    }
}

function Get-BlobInfo {
    param([byte[]]$Bytes)
    try {
        $obj = ([Text.Encoding]::UTF8.GetString($Bytes)) | ConvertFrom-Json
    }
    catch {
        throw '凭据内容不是预期的 JSON 结构，可能 Antigravity 版本已变更。'
    }
    $sha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)) -replace '-', '')
    [pscustomobject]@{
        Email      = [string]$obj.id_token_email
        AuthMethod = [string]$obj.auth_method
        Expiry     = [string]$obj.token.expiry
        HasRefresh = [bool]$obj.token.refresh_token
        Sha256     = $sha
    }
}

function Protect-Bytes {
    param([byte[]]$Bytes)
    $b64 = [Convert]::ToBase64String($Bytes)
    $sec = ConvertTo-SecureString -String $b64 -AsPlainText -Force
    ConvertFrom-SecureString -SecureString $sec
}

function Unprotect-Bytes {
    param([string]$Text)
    $sec = ConvertTo-SecureString -String $Text
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $b64 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    [Convert]::FromBase64String($b64)
}

function Get-Profiles {
    if (-not (Test-Path -LiteralPath $script:ProfilesRoot)) { return @() }
    Get-ChildItem -LiteralPath $script:ProfilesRoot -Directory | ForEach-Object {
        $metaFile = Join-Path $_.FullName 'meta.json'
        $credFile = Join-Path $_.FullName 'cred.dat'
        if (-not (Test-Path -LiteralPath $metaFile) -or -not (Test-Path -LiteralPath $credFile)) { return }
        try { $meta = Get-Content -LiteralPath $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { return }
        [pscustomobject]@{
            Label      = $_.Name
            Email      = [string]$meta.email
            Nickname   = [string]$meta.nickname
            CapturedAt = [string]$meta.capturedAt
            LastUsed   = [string]$meta.lastUsed
            Sha256     = [string]$meta.sha256
            Dir        = $_.FullName
            CredFile   = $credFile
        }
    }
}

function Get-Profile {
    param([string]$Name)
    $p = Get-Profiles | Where-Object { $_.Label -eq $Name }
    if (-not $p) { throw "号池里没有名为 '$Name' 的账号。" }
    $p
}

function Save-Profile {
    param([string]$Name, [byte[]]$Bytes, [string]$Source = 'capture')
    $info = Get-BlobInfo -Bytes $Bytes
    $dir = Join-Path $script:ProfilesRoot $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $protected = Protect-Bytes -Bytes $Bytes
    [IO.File]::WriteAllText((Join-Path $dir 'cred.dat'), $protected, [Text.Encoding]::ASCII)

    $metaFile = Join-Path $dir 'meta.json'
    $lastUsed = ''
    $nickname = ''
    if (Test-Path -LiteralPath $metaFile) {
        try {
            $old = Get-Content -LiteralPath $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $lastUsed = [string]$old.lastUsed
            $nickname = [string]$old.nickname
        }
        catch {
            $lastUsed = ''
            $nickname = ''
        }
    }

    $meta = [ordered]@{
        label      = $Name
        email      = $info.Email
        nickname   = $nickname
        authMethod = $info.AuthMethod
        capturedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        lastUsed   = $lastUsed
        sha256     = $info.Sha256
        source     = $Source
    }
    [IO.File]::WriteAllText($metaFile, ($meta | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($true)))
    $info
}

function New-AutoLabel {
    param([string]$Email)
    $base = ($Email -split '@')[0]
    $base = ($base -replace '[^\w\-.]', '')
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'account' }
    if ($base.Length -gt 32) { $base = $base.Substring(0, 32) }

    $existing = @(Get-Profiles | ForEach-Object { $_.Label })
    $name = $base
    $i = 2
    while ($existing -contains $name) { $name = "$base-$i"; $i++ }
    $name
}

function Set-ProfileLastUsed {
    param([string]$Name)
    $metaFile = Join-Path (Join-Path $script:ProfilesRoot $Name) 'meta.json'
    if (-not (Test-Path -LiteralPath $metaFile)) { return }
    try {
        $meta = Get-Content -LiteralPath $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $meta | Add-Member -NotePropertyName lastUsed -NotePropertyValue ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Force
        [IO.File]::WriteAllText($metaFile, ($meta | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($true)))
    }
    catch { }
}

function Set-ProfileNickname {
    param([string]$Name, [string]$Nickname)
    $metaFile = Join-Path (Join-Path $script:ProfilesRoot $Name) 'meta.json'
    if (-not (Test-Path -LiteralPath $metaFile)) { throw "找不到账号 '$Name' 的快照。" }

    $nickname = $Nickname.Trim()
    if ($nickname.Length -gt 24) { throw '昵称最长 24 个字符。' }

    $meta = Get-Content -LiteralPath $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $meta | Add-Member -NotePropertyName nickname -NotePropertyValue $nickname -Force
    [IO.File]::WriteAllText($metaFile, ($meta | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($true)))
    $nickname
}

function Get-State {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return [pscustomobject]@{ active = $null; switchedAt = $null } }
    try { Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { [pscustomobject]@{ active = $null; switchedAt = $null } }
}

function Set-State {
    param([string]$Active)
    New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
    $state = [ordered]@{ active = $Active; switchedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    [IO.File]::WriteAllText($script:StateFile, ($state | ConvertTo-Json), (New-Object Text.UTF8Encoding($true)))
}

function Close-Antigravity {
    $procs = Get-Process -Name 'Antigravity', 'language_server' -ErrorAction SilentlyContinue
    if (-not $procs) { return }

    $main = $procs | Where-Object { $_.ProcessName -eq 'Antigravity' -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($main) { $null = $main.CloseMainWindow() }

    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Name 'Antigravity', 'language_server' -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 300
    }

    Get-Process -Name 'Antigravity', 'language_server' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

function Start-Antigravity {
    param([string]$Exe)
    Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Path $Exe -Parent)
}

function Update-CachedLoginName {
    param([string]$Email)
    $p = Join-Path $env:APPDATA 'Antigravity\app_storage.json'
    if (-not (Test-Path -LiteralPath $p)) { return }
    try {
        $raw = Get-Content -LiteralPath $p -Raw
        $pattern = '("agy\.onboarding\.lastLoginUsername"\s*:\s*")[^"]*(")'
        if ($raw -notmatch $pattern) { return }

        $backup = "$p.bak-" + (Get-Date).ToString('yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $p -Destination $backup -Force

        $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $m.Groups[1].Value + $Email + $m.Groups[2].Value
        }
        $new = [regex]::Replace($raw, $pattern, $evaluator)
        if ($new -ne $raw) {
            [IO.File]::WriteAllText($p, $new, (New-Object Text.UTF8Encoding($false)))
        }

        Get-ChildItem -LiteralPath (Split-Path $p -Parent) -Filter 'app_storage.json.bak-*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

function Get-CurrentAccount {
    $bytes = Read-CredentialBlob
    $info = Get-BlobInfo -Bytes $bytes
    [pscustomobject]@{
        Bytes = $bytes
        Info  = $info
        Email = $info.Email
    }
}

function Sync-CurrentAccount {
    $cur = Get-CurrentAccount
    $profiles = @(Get-Profiles)

    $match = $profiles | Where-Object { $_.Email -eq $cur.Email } | Select-Object -First 1
    if (-not $match) {
        $label = New-AutoLabel -Email $cur.Email
        Save-Profile -Name $label -Bytes $cur.Bytes -Source 'auto' | Out-Null
        return [pscustomobject]@{ Action = 'added'; Label = $label; Email = $cur.Email; Sha256 = $cur.Info.Sha256 }
    }
    if ($match.Sha256 -ne $cur.Info.Sha256) {
        Save-Profile -Name $match.Label -Bytes $cur.Bytes -Source 'autosave' | Out-Null
        return [pscustomobject]@{ Action = 'updated'; Label = $match.Label; Email = $cur.Email; Sha256 = $cur.Info.Sha256 }
    }
    [pscustomobject]@{ Action = 'none'; Label = $match.Label; Email = $cur.Email; Sha256 = $cur.Info.Sha256 }
}

function Invoke-AgPoolSwitch {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$NoRestart,
        [string]$AppPath
    )

    $profile = Get-Profile -Name $Label
    $targetBytes = Unprotect-Bytes -Text ([IO.File]::ReadAllText($profile.CredFile, [Text.Encoding]::ASCII))
    $targetInfo = Get-BlobInfo -Bytes $targetBytes

    # 覆盖前回存当前账号的最新凭据，避免 refresh token 轮换后快照过期
    try {
        $cur = Get-CurrentAccount
        if ($cur.Email -ne $targetInfo.Email) {
            $match = Get-Profiles | Where-Object { $_.Email -eq $cur.Email } | Select-Object -First 1
            if ($match) { Save-Profile -Name $match.Label -Bytes $cur.Bytes -Source 'autosave' | Out-Null }
        }
    }
    catch { }

    $exe = Get-AppExecutable -Override $AppPath
    Close-Antigravity
    Write-CredentialBlob -Bytes $targetBytes

    $verify = Get-BlobInfo -Bytes (Read-CredentialBlob)
    if ($verify.Sha256 -ne $targetInfo.Sha256) {
        throw '写入校验失败：凭据管理器中的内容与快照不一致，请重试。'
    }

    Update-CachedLoginName -Email $targetInfo.Email
    Set-ProfileLastUsed -Name $Label
    Set-State -Active $Label

    if (-not $NoRestart) { Start-Antigravity -Exe $exe }

    [pscustomobject]@{
        Label  = $Label
        Email  = $targetInfo.Email
        Expiry = $targetInfo.Expiry
    }
}
