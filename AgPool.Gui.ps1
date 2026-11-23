# AgPool.Gui.ps1
# Antigravity 账号池 - WPF 图形界面
# 需要 Windows PowerShell（STA），由 agpool-gui.cmd 启动。

[CmdletBinding()]
param([string]$AppPath)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. (Join-Path $PSScriptRoot 'AgPool.Core.ps1')

$script:AppPathOverride = $AppPath
$script:CliScript = Join-Path $PSScriptRoot 'agpool.ps1'
$script:BrushCache = @{}
$script:LogDir = Join-Path $env:TEMP 'agpool-logs'

# 文件监听桥接：FileSystemWatcher 的事件在线程池线程触发，
# PowerShell 脚本块不能在那里执行（会触发 PSInvalidOperation 崩溃）。
# 这里用编译好的 C# 类只做一件事：把回调 Post 回 UI 线程。
if (-not ('AgPool.StorageWatcher' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;

namespace AgPool {
    public sealed class StorageWatcher : IDisposable {
        private readonly FileSystemWatcher _watcher;
        private readonly SynchronizationContext _context;
        private readonly Action _callback;

        public StorageWatcher(string directory, string filter, SynchronizationContext context, Action callback) {
            _context = context;
            _callback = callback;
            _watcher = new FileSystemWatcher(directory, filter);
            _watcher.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName;
            _watcher.Changed += OnChanged;
            _watcher.Created += OnChanged;
            _watcher.Renamed += OnRenamed;
        }

        private void OnChanged(object sender, FileSystemEventArgs e) { Post(); }
        private void OnRenamed(object sender, RenamedEventArgs e) { Post(); }

        private void Post() {
            if (_context == null || _callback == null) { return; }
            try {
                _context.Post(delegate {
                    try { _callback(); } catch { }
                }, null);
            }
            catch { }
        }

        public void Start() { _watcher.EnableRaisingEvents = true; }
        public void Stop() { _watcher.EnableRaisingEvents = false; }

        public void Dispose() {
            try { _watcher.EnableRaisingEvents = false; _watcher.Dispose(); } catch { }
        }
    }
}
'@
}

function Write-GuiLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
        }
        $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath (Join-Path $script:LogDir 'agpool.log') -Value $line -Encoding UTF8
    }
    catch { }
}

function Initialize-LogDir {
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
            return
        }
        Get-ChildItem -LiteralPath $script:LogDir -Filter 'switch-*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

$global:AgPoolUI = [pscustomobject]@{
    Window       = $null
    Busy         = $false
    Signature    = ''
    CurrentEmail = $null
    LastSeenLogin = $null
    Watcher      = $null
    Debounce     = $null
    Poll         = $null
    Pending      = $null
}

function New-Brush {
    param([string]$Hex)
    if (-not $script:BrushCache.ContainsKey($Hex)) {
        $script:BrushCache[$Hex] = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
    }
    $script:BrushCache[$Hex]
}

function Format-ShortTime {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    try { return ([datetime]::Parse($Value)).ToString('MM-dd HH:mm') }
    catch { return $Value }
}

function Set-Status {
    param([string]$Text, [switch]$Error)
    $tb = $global:AgPoolUI.Window.FindName('StatusText')
    if (-not $tb) { return }
    $tb.Text = $Text
    if ($Error) { $tb.Foreground = New-Brush '#B42318' }
    else { $tb.Foreground = New-Brush '#6B7280' }
}

function Update-Header {
    $tb = $global:AgPoolUI.Window.FindName('CurrentText')
    if (-not $tb) { return }

    $email = $global:AgPoolUI.CurrentEmail
    if ($email) {
        $nickname = ''
        try {
            $profile = Get-Profiles | Where-Object { $_.Email -eq $email } | Select-Object -First 1
            if ($profile) { $nickname = $profile.Nickname }
        }
        catch { }

        if ($nickname) { $tb.Text = "当前：$nickname  ·  $email" }
        else { $tb.Text = "当前：$email" }
    }
    else {
        $tb.Text = '未检测到登录状态，请在 Antigravity 中登录'
    }
}

function New-SwitchHandler {
    param([string]$Name)
    $cli = $script:CliScript
    return {
        param($sender, $eventArgs)
        Start-AgPoolSwitch -Label $Name -CliPath $cli
    }.GetNewClosure()
}

function New-RemoveHandler {
    param([string]$Name)
    $profilesRoot = $script:ProfilesRoot
    return {
        param($sender, $eventArgs)
        $answer = [System.Windows.MessageBox]::Show(
            "确定从号池移除 `"$Name`" 吗？`n`n只删除本地快照，不影响当前登录状态。",
            '移除账号', 'YesNo', 'Question')
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            try {
                Remove-Item -LiteralPath (Join-Path $profilesRoot $Name) -Recurse -Force
                Set-Status "已移除 $Name"
                Update-AgPoolState -Force
            }
            catch {
                Set-Status "移除失败：$($_.Exception.Message)" -Error
            }
        }
    }.GetNewClosure()
}

function New-NicknameHandler {
    param([string]$Name)
    return {
        param($sender, $eventArgs)
        Edit-Nickname -Label $Name
    }.GetNewClosure()
}

function Show-NicknameDialog {
    param([string]$Current, [string]$Email)

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="设置昵称" Height="196" Width="380"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" Background="#F5F6F8"
        FontFamily="Microsoft YaHei UI, Segoe UI"
        TextOptions.TextFormattingMode="Display">
  <Grid Margin="20,18,20,16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" x:Name="Hint" Text="" FontSize="11.5" Foreground="#6B7280" TextTrimming="CharacterEllipsis"/>
    <TextBox Grid.Row="1" x:Name="Input" Margin="0,8,0,0" Height="32" FontSize="13" MaxLength="24"
             Padding="8,5" BorderBrush="#DDE1E6" BorderThickness="1" VerticalContentAlignment="Center"/>
    <TextBlock Grid.Row="2" x:Name="Counter" Text="留空表示清除昵称，最多 24 个字符" FontSize="11" Foreground="#9CA3AF" Margin="0,6,0,0"/>
    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="CancelBtn" Content="取消" Width="76" Height="30" Margin="0,0,8,0" IsCancel="True"
              Background="White" BorderBrush="#DDE1E6" BorderThickness="1" Foreground="#374151"/>
      <Button x:Name="OkBtn" Content="保存" Width="76" Height="30" IsDefault="True"
              Background="#1D9E75" BorderThickness="0" Foreground="White"/>
    </StackPanel>
  </Grid>
</Window>
'@

    $dialog = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $dialog.Owner = $global:AgPoolUI.Window
    $dialog.FindName('Hint').Text = "账号：$Email"
    $dialog.FindName('Input').Text = $Current

    $global:AgPoolNickname = @{ Dialog = $dialog; Accepted = $false; Result = '' }

    $dialog.FindName('OkBtn').Add_Click({
        $state = $global:AgPoolNickname
        $state.Result = [string]$state.Dialog.FindName('Input').Text
        $state.Accepted = $true
        $state.Dialog.Close()
    })

    $dialog.Add_ContentRendered({
        $input = $global:AgPoolNickname.Dialog.FindName('Input')
        $input.SelectAll()
        $input.Focus() | Out-Null
    })

    $null = $dialog.ShowDialog()
    $global:AgPoolNickname
}

function Edit-Nickname {
    param([string]$Label)

    if ($global:AgPoolUI.Busy) { Set-Status '正在切换中，请稍候...'; return }

    try {
        $profile = Get-Profile -Name $Label
        $result = Show-NicknameDialog -Current $profile.Nickname -Email $profile.Email
        if (-not $result.Accepted) { return }

        $nickname = ([string]$result.Result).Trim()
        Set-ProfileNickname -Name $Label -Nickname $nickname | Out-Null
        Write-GuiLog "nickname set: $Label -> '$nickname'"

        if ($nickname) { Set-Status "已把 $Label 的昵称设为「$nickname」" }
        else { Set-Status "已清除 $Label 的昵称" }

        Update-AgPoolState -Force
    }
    catch {
        Set-Status ("设置昵称失败：" + $_.Exception.Message) -Error
    }
}

function New-AccountCard {
    param($Profile, [bool]$IsCurrent)

    $card = [System.Windows.Controls.Border]::new()
    if ($IsCurrent) { $card.Style = $global:AgPoolUI.Window.FindResource('CurrentCardStyle') }
    else { $card.Style = $global:AgPoolUI.Window.FindResource('CardStyle') }

    $grid = [System.Windows.Controls.Grid]::new()
    $c1 = [System.Windows.Controls.ColumnDefinition]::new()
    $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $c2 = [System.Windows.Controls.ColumnDefinition]::new()
    $c2.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($c1)
    $grid.ColumnDefinitions.Add($c2)

    $left = [System.Windows.Controls.StackPanel]::new()
    $left.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $displayName = if ($Profile.Nickname) { $Profile.Nickname } else { $Profile.Email }

    $title = [System.Windows.Controls.TextBlock]::new()
    $title.Text = $displayName
    $title.FontSize = 13.5
    $title.FontWeight = [System.Windows.FontWeights]::SemiBold
    $title.Foreground = New-Brush '#1F2328'
    $title.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $left.Children.Add($title) | Out-Null

    if ($Profile.LastUsed) { $timeText = "上次切换 $(Format-ShortTime $Profile.LastUsed)" }
    else { $timeText = "保存于 $(Format-ShortTime $Profile.CapturedAt)" }

    if ($Profile.Nickname) { $metaText = "$($Profile.Email)  ·  $timeText" }
    else { $metaText = "别名 $($Profile.Label)  ·  $timeText" }

    $meta = [System.Windows.Controls.TextBlock]::new()
    $meta.Text = $metaText
    $meta.FontSize = 11
    $meta.Foreground = New-Brush '#6B7280'
    $meta.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
    $meta.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $left.Children.Add($meta) | Out-Null

    [System.Windows.Controls.Grid]::SetColumn($left, 0)
    $grid.Children.Add($left) | Out-Null

    $right = [System.Windows.Controls.StackPanel]::new()
    $right.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $right.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $right.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)

    $nickBtn = [System.Windows.Controls.Button]::new()
    $nickBtn.Content = '昵称'
    $nickBtn.Style = $global:AgPoolUI.Window.FindResource('GhostBtn')
    $nickBtn.FontSize = 11
    $nickBtn.Padding = [System.Windows.Thickness]::new(8, 4, 8, 4)
    $nickBtn.ToolTip = '设置或修改昵称'
    $nickBtn.Add_Click((New-NicknameHandler -Name $Profile.Label))
    $right.Children.Add($nickBtn) | Out-Null

    if ($IsCurrent) {
        $badge = [System.Windows.Controls.Border]::new()
        $badge.Background = New-Brush '#E1F5EE'
        $badge.CornerRadius = [System.Windows.CornerRadius]::new(9)
        $badge.Padding = [System.Windows.Thickness]::new(10, 3, 10, 3)
        $badge.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
        $badgeText = [System.Windows.Controls.TextBlock]::new()
        $badgeText.Text = '当前'
        $badgeText.FontSize = 11
        $badgeText.Foreground = New-Brush '#0F6E56'
        $badge.Child = $badgeText
        $right.Children.Add($badge) | Out-Null
    }
    else {
        $btn = [System.Windows.Controls.Button]::new()
        $btn.Content = '切换'
        $btn.Style = $global:AgPoolUI.Window.FindResource('PrimaryBtn')
        $btn.Tag = $Profile.Label
        $btn.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
        $btn.Add_Click((New-SwitchHandler -Name $Profile.Label))
        $right.Children.Add($btn) | Out-Null
    }

    [System.Windows.Controls.Grid]::SetColumn($right, 1)
    $grid.Children.Add($right) | Out-Null

    $card.Child = $grid
    $tip = "$($Profile.Email)   [$($Profile.Label)]"
    if ($Profile.Nickname) { $tip = "$($Profile.Nickname)`n" + $tip }
    $card.ToolTip = $tip + "`n右键可设置昵称或移除"

    $menu = [System.Windows.Controls.ContextMenu]::new()

    $nickItem = [System.Windows.Controls.MenuItem]::new()
    $nickItem.Header = '设置昵称…'
    $nickItem.Add_Click((New-NicknameHandler -Name $Profile.Label))
    $menu.Items.Add($nickItem) | Out-Null

    $item = [System.Windows.Controls.MenuItem]::new()
    $item.Header = '从号池移除'
    $item.Add_Click((New-RemoveHandler -Name $Profile.Label))
    $menu.Items.Add($item) | Out-Null

    $card.ContextMenu = $menu

    return $card
}

function Update-AccountList {
    $list = $global:AgPoolUI.Window.FindName('AccountList')
    $list.Children.Clear()

    $profiles = @(Get-Profiles)
    if ($profiles.Count -eq 0) {
        $empty = [System.Windows.Controls.StackPanel]::new()
        $empty.Margin = [System.Windows.Thickness]::new(0, 48, 0, 0)

        $t1 = [System.Windows.Controls.TextBlock]::new()
        $t1.Text = '号池还是空的'
        $t1.FontSize = 14
        $t1.Foreground = New-Brush '#374151'
        $t1.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center

        $t2 = [System.Windows.Controls.TextBlock]::new()
        $t2.Text = '在 Antigravity 里登录一个 Google 账号，这里会自动出现'
        $t2.FontSize = 11.5
        $t2.Foreground = New-Brush '#9CA3AF'
        $t2.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $t2.TextAlignment = [System.Windows.TextAlignment]::Center
        $t2.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $t2.Margin = [System.Windows.Thickness]::new(24, 8, 24, 0)

        $empty.Children.Add($t1) | Out-Null
        $empty.Children.Add($t2) | Out-Null
        $list.Children.Add($empty) | Out-Null
        return
    }

    $current = $global:AgPoolUI.CurrentEmail
    $sorted = $profiles | Sort-Object `
        @{ Expression = { if ($_.Email -eq $current) { 0 } else { 1 } } },
        @{ Expression = { if ($_.LastUsed) { $_.LastUsed } else { $_.CapturedAt } }; Descending = $true }

    foreach ($p in $sorted) {
        $card = New-AccountCard -Profile $p -IsCurrent ($p.Email -eq $current)
        $list.Children.Add($card) | Out-Null
    }
}

function Get-CachedLoginName {
    $p = Join-Path $env:APPDATA 'Antigravity\app_storage.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($p)
        $m = [regex]::Match($raw, '"agy\.onboarding\.lastLoginUsername"\s*:\s*"([^"]*)"')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    catch { }
    return $null
}

function Sync-OnLoginChange {
    if ($global:AgPoolUI.Busy) { return }
    $name = Get-CachedLoginName
    if (-not $name) { return }
    if ($name -eq $global:AgPoolUI.LastSeenLogin) { return }

    try {
        Update-AgPoolState -Force
        # 用户名可能先于凭据写入，只有确认凭据已是该账号才记录，否则等下一次事件重试
        if ($global:AgPoolUI.CurrentEmail -eq $name) {
            Write-GuiLog "login changed: $($global:AgPoolUI.LastSeenLogin) -> $name"
            $global:AgPoolUI.LastSeenLogin = $name
        }
    }
    catch { Write-GuiLog ("login sync error: " + $_.Exception.Message) }
}

function Update-AgPoolState {
    param([switch]$Force)
    if ($global:AgPoolUI.Busy) { return }

    $email = $null
    try { $email = (Get-CurrentAccount).Email } catch { $email = $null }
    $global:AgPoolUI.CurrentEmail = $email

    if ($email) {
        try {
            $sync = Sync-CurrentAccount
            if ($sync.Action -eq 'added') {
                Set-Status "已自动收藏新账号 $($sync.Email)（$($sync.Label)）"
            }
        }
        catch { }
    }

    $profiles = @(Get-Profiles)
    $sig = ($profiles | Sort-Object Label | ForEach-Object { "$($_.Label)|$($_.Email)|$($_.Nickname)|$($_.CapturedAt)|$($_.LastUsed)" }) -join ';'
    $sig = "$sig#$email"

    if ($Force -or $sig -ne $global:AgPoolUI.Signature) {
        $global:AgPoolUI.Signature = $sig
        Update-Header
        Update-AccountList
    }
}

function Start-AgPoolSwitch {
    param([string]$Label, [string]$CliPath)

    if ($global:AgPoolUI.Busy) { Set-Status '正在切换中，请稍候...'; return }

    $global:AgPoolUI.Busy = $true
    Set-Status "正在切换到 $Label，Antigravity 会被重启 ..."
    $global:AgPoolUI.Window.FindName('AccountList').IsEnabled = $false

    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $log = Join-Path $script:LogDir "switch-$stamp.out.log"
    $errLog = Join-Path $script:LogDir "switch-$stamp.err.log"
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $CliPath, 'switch', $Label, '-Yes')

    Write-GuiLog "switch start: label=$Label log=$log"

    $targetEmail = $null
    try { $targetEmail = (Get-Profile -Name $Label).Email } catch { }

    $proc = Start-Process -FilePath $psExe -ArgumentList $argList -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError $errLog

    $global:AgPoolUI.Pending = [pscustomobject]@{
        Proc        = $proc
        Log         = $log
        Err         = $errLog
        Label       = $Label
        TargetEmail = $targetEmail
        Started     = Get-Date
        TimedOut    = $false
    }
    $global:AgPoolUI.Poll.Start()
}

function Complete-SwitchTick {
    $pending = $global:AgPoolUI.Pending
    if (-not $pending) { $global:AgPoolUI.Poll.Stop(); return }

    try {
        if (-not $pending.Proc.HasExited) {
            if (((Get-Date) - $pending.Started).TotalSeconds -gt 90 -and -not $pending.TimedOut) {
                $pending.TimedOut = $true
                try { $pending.Proc.Kill() } catch { }
            }
            return
        }

        $global:AgPoolUI.Poll.Stop()
        $code = $null
        try { $pending.Proc.Refresh(); $code = $pending.Proc.ExitCode } catch { }
        if ($null -eq $code) { $code = 'n/a' }

        $actualEmail = $null
        try { $actualEmail = (Get-CurrentAccount).Email } catch { }
        $success = [bool]($actualEmail -and $pending.TargetEmail -and ($actualEmail -eq $pending.TargetEmail))

        $outText = ''
        $errText = ''
        try { $outText = Get-Content -LiteralPath $pending.Log -Raw -ErrorAction SilentlyContinue } catch { }
        try { $errText = Get-Content -LiteralPath $pending.Err -Raw -ErrorAction SilentlyContinue } catch { }

        Write-GuiLog ("switch end: label={0} exit={1} timeout={2} actual={3} target={4} success={5}" -f `
            $pending.Label, $code, $pending.TimedOut, $actualEmail, $pending.TargetEmail, $success)
        if ($outText) { Write-GuiLog ("  stdout: " + ($outText.Trim() -replace '\s+', ' ')) }
        if ($errText) { Write-GuiLog ("  stderr: " + ($errText.Trim() -replace '\s+', ' ')) }

        $global:AgPoolUI.Pending = $null
        $global:AgPoolUI.Busy = $false
        $global:AgPoolUI.Window.FindName('AccountList').IsEnabled = $true

        if ($pending.TimedOut) {
            Set-Status '切换超时，已终止切换进程' -Error
            [System.Windows.MessageBox]::Show('切换超过 90 秒未完成，已终止切换进程。请确认 Antigravity 是否正常运行，或在命令行执行 agpool.ps1 current 查看当前状态。', '切换超时', 'OK', 'Warning') | Out-Null
        }
        elseif ($success) {
            Set-Status "已切换到 $actualEmail，客户端正在启动"
        }
        else {
            $detail = (($errText + "`n" + $outText).Trim())
            if (-not $detail) { $detail = "退出码 $code；当前凭据仍为 $(if ($actualEmail) { $actualEmail } else { '未知' })" }
            Set-Status ("切换失败：" + ($detail -replace '\s+', ' ')) -Error
            [System.Windows.MessageBox]::Show($detail, '切换失败', 'OK', 'Error') | Out-Null
        }

        Update-AgPoolState -Force
    }
    catch {
        Write-GuiLog ("tick error: " + $_.Exception.Message)
        $global:AgPoolUI.Busy = $false
        $global:AgPoolUI.Pending = $null
        if ($global:AgPoolUI.Poll) { $global:AgPoolUI.Poll.Stop() }
        try { $global:AgPoolUI.Window.FindName('AccountList').IsEnabled = $true } catch { }
        Set-Status ("切换状态检查出错：" + $_.Exception.Message) -Error
    }
}

function Invoke-ManualCapture {
    if ($global:AgPoolUI.Busy) { Set-Status '正在切换中，请稍候...'; return }
    try {
        $result = Sync-CurrentAccount
        switch ($result.Action) {
            'added' { Set-Status "已收藏 $($result.Email)（$($result.Label)）" }
            'updated' { Set-Status "已更新 $($result.Label) 的凭据快照" }
            default { Set-Status "当前账号已在号池中：$($result.Label)" }
        }
        Update-AgPoolState -Force
    }
    catch {
        Set-Status $_.Exception.Message -Error
    }
}

function Open-PoolFolder {
    if (-not (Test-Path -LiteralPath $script:Root)) {
        New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
    }
    Start-Process explorer.exe $script:Root
}

try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\AgPoolGui')
    if (-not $mutex.WaitOne(0)) {
        [System.Windows.MessageBox]::Show('账号池界面已经在运行了。', 'Antigravity 账号池', 'OK', 'Information') | Out-Null
        exit
    }

    $xaml = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'AgPool.Gui.xaml'))
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $global:AgPoolUI.Window = $window

    try {
        $exe = Get-AppExecutable -Override $script:AppPathOverride
        Add-Type -AssemblyName System.Drawing
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
        $window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $icon.Handle, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    }
    catch { }

    $window.FindName('RefreshBtn').Add_Click({ Update-AgPoolState -Force })
    $window.FindName('SaveBtn').Add_Click({ Invoke-ManualCapture })
    $window.FindName('FolderBtn').Add_Click({ Open-PoolFolder })

    # 登录状态变化用文件事件触发，不做轮询
    $debounce = [System.Windows.Threading.DispatcherTimer]::new()
    $debounce.Interval = [TimeSpan]::FromMilliseconds(1200)
    $debounce.Add_Tick({
        try {
            $global:AgPoolUI.Debounce.Stop()
            Sync-OnLoginChange
        }
        catch { Write-GuiLog ("debounce error: " + $_.Exception.Message) }
    })
    $global:AgPoolUI.Debounce = $debounce

    $appDataDir = Join-Path $env:APPDATA 'Antigravity'
    if (Test-Path -LiteralPath $appDataDir) {
        $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
        if (-not [System.Threading.SynchronizationContext]::Current) {
            [System.Threading.SynchronizationContext]::SetSynchronizationContext(
                [System.Windows.Threading.DispatcherSynchronizationContext]::new($dispatcher))
        }
        $syncContext = [System.Threading.SynchronizationContext]::Current

        $onStorageChanged = [action] {
            try {
                Write-GuiLog 'storage event'
                $global:AgPoolUI.Debounce.Stop()
                $global:AgPoolUI.Debounce.Start()
            }
            catch { }
        }

        $watcher = [AgPool.StorageWatcher]::new($appDataDir, 'app_storage.json', $syncContext, $onStorageChanged)
        $watcher.Start()
        $global:AgPoolUI.Watcher = $watcher
        Write-GuiLog "watcher started: $appDataDir"
    }

    $poll = [System.Windows.Threading.DispatcherTimer]::new()
    $poll.Interval = [TimeSpan]::FromMilliseconds(400)
    $poll.Add_Tick({ Complete-SwitchTick })
    $global:AgPoolUI.Poll = $poll

    $window.Add_Activated({
        try { Update-AgPoolState } catch { Write-GuiLog ("activated error: " + $_.Exception.Message) }
    })
    $window.Add_Closed({
        if ($global:AgPoolUI.Watcher) {
            try { $global:AgPoolUI.Watcher.Stop() } catch { }
            try { $global:AgPoolUI.Watcher.Dispose() } catch { }
        }
        if ($global:AgPoolUI.Debounce) { $global:AgPoolUI.Debounce.Stop() }
        if ($global:AgPoolUI.Poll) { $global:AgPoolUI.Poll.Stop() }
        Write-GuiLog 'gui closed'
    })

    Initialize-LogDir
    Write-GuiLog "gui start: pid=$PID"
    $global:AgPoolUI.LastSeenLogin = Get-CachedLoginName
    Update-AgPoolState -Force
    $window.ShowDialog() | Out-Null
}
catch {
    $message = $_.Exception.Message
    if ($_.ScriptStackTrace) { $message += "`n`n" + $_.ScriptStackTrace }
    try {
        [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'AgPool.Gui.error.log'), $message, (New-Object Text.UTF8Encoding($false)))
    }
    catch { }
    [System.Windows.MessageBox]::Show($message, 'Antigravity 账号池 - 启动失败', 'OK', 'Error') | Out-Null
}
