# Codex 额度：界面线程只做显示，读取在独立的可取消进程中完成。
. (Join-Path $PSScriptRoot 'widget-core.ps1')

$desktop = Select-DesktopHost @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue)
if ($null -eq $desktop) { exit }
try {
  $script:desktopProcess = [System.Diagnostics.Process]::GetProcessById([int]$desktop.ProcessId)
  $script:desktopIdentity = [pscustomobject]@{ Id=$script:desktopProcess.Id; StartTicks=$script:desktopProcess.StartTime.ToUniversalTime().Ticks.ToString(); Path=$script:desktopProcess.MainModule.FileName }
} catch { exit }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class QuotaDpi {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static void Enable() {
    try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
    try { SetProcessDPIAware(); } catch { }
  }
}
"@
[QuotaDpi]::Enable()
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\CodexQuotaWidget', [ref]$created)
if (-not $created) { $mutex.Dispose(); exit }
$closeSignal = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, 'Local\CodexQuotaWidget.Close')
[void]$closeSignal.Reset()

$stateDir = Join-Path $env:APPDATA 'CodexQuotaWidget'
$stateFile = Join-Path $stateDir 'state.json'
$script:request = $null
$script:pools = @()
$script:rendering = $false
$script:closing = $false
$script:lastUpdated = $null
$pluginRoot = Split-Path $PSScriptRoot -Parent
$nodePath = Resolve-QuotaNode
$workerPath = Join-Path $pluginRoot 'src\read-quota.mjs'

function Load-State {
  try { if (Test-Path -LiteralPath $stateFile) { return (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch {}
  return $null
}
function Save-State($x, $y) {
  try {
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    @{left=[int]$x;top=[int]$y} | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
  } catch {}
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Codex 额度" Width="344" SizeToContent="Height" MinHeight="220" MaxHeight="420"
 WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True" Background="#FCFCFE"
 SnapsToDevicePixels="True" UseLayoutRounding="True" FontFamily="Microsoft YaHei"
 TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
 <Border BorderBrush="#D2D6E0" BorderThickness="1" Background="#FCFCFE">
  <StackPanel Margin="16,13">
   <Grid x:Name="DragHeader" Background="Transparent">
    <TextBlock Text="Codex 额度" FontSize="13.5" FontWeight="Bold" Foreground="#18181B" VerticalAlignment="Center"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
     <Button x:Name="RefreshButton" Content="刷新" FontSize="11.5" Padding="5,2" Margin="0,0,6,0" Background="Transparent" BorderThickness="0" Foreground="#646474"/>
     <Button x:Name="CloseButton" Content="关闭" FontSize="11.5" Padding="5,2" Background="Transparent" BorderThickness="0" Foreground="#646474"/>
    </StackPanel>
   </Grid>
   <TextBlock x:Name="PoolName" Text="Codex" FontSize="11" Foreground="#6D7180" Margin="0,10,0,0"/>
   <ComboBox x:Name="PoolPicker" DisplayMemberPath="Name" SelectedValuePath="Id" FontSize="11.5" Margin="0,8,0,0" Visibility="Collapsed"/>
   <StackPanel x:Name="Rows" Margin="0,10,0,0"/>
   <TextBlock x:Name="StateText" Text="正在读取额度…" FontSize="10.5" Foreground="#7A7A85" Margin="0,14,0,0" TextTrimming="CharacterEllipsis"/>
  </StackPanel>
 </Border>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($name in @('DragHeader','RefreshButton','CloseButton','PoolName','PoolPicker','Rows','StateText')) { $ui[$name]=$win.FindName($name) }
$converter = New-Object Windows.Media.BrushConverter
$brushMuted=$converter.ConvertFromString('#7A7A85')
$brushRed=$converter.ConvertFromString('#DC4444')
$brushAmber=$converter.ConvertFromString('#B77912')
$brushBlue=$converter.ConvertFromString('#2463EB')
$brushTrack=$converter.ConvertFromString('#E6E8EE')

function Set-StateText([string]$Text, [bool]$Failed=$false) {
  $ui.StateText.Text=$Text; $ui.StateText.ToolTip=$Text
  $ui.StateText.Foreground=if($Failed){$brushRed}else{$brushMuted}
}
function Format-Reset($Window) {
  if (-not $Window.resetAt) { return '重置时间暂不可用' }
  try { $reset=[DateTimeOffset]::Parse($Window.resetAt).ToLocalTime() } catch { return '重置时间暂不可用' }
  $span=$reset-[DateTimeOffset]::Now
  if($span.TotalSeconds -le 0){return '已到重置时间，等待更新'}
  $minutes=[Math]::Ceiling($span.TotalMinutes)
  $duration=if($minutes -ge 1440){'{0} 天 {1} 小时' -f [Math]::Floor($minutes/1440),[Math]::Floor(($minutes%1440)/60)}elseif($minutes -ge 60){'{0} 小时 {1} 分钟' -f [Math]::Floor($minutes/60),($minutes%60)}else{'{0} 分钟' -f $minutes}
  return ('{0}后重置 · {1:MM/dd HH:mm}' -f $duration,$reset)
}
function Get-WindowLabel($Window) {
  $duration=$Window.windowDurationMins
  if($duration -eq 10080){return '每周额度'}
  if($null -ne $duration -and $duration -gt 0){
    if($duration%1440 -eq 0){return ('{0} 天额度' -f ($duration/1440))}
    if($duration%60 -eq 0){return ('{0} 小时额度' -f ($duration/60))}
    return ('{0} 分钟额度' -f $duration)
  }
  if($Window.id -eq 'secondary'){return '长期额度'}
  return '当前额度'
}
function Render-SelectedPool {
  $ui.Rows.Children.Clear()
  $pool=$ui.PoolPicker.SelectedItem
  if($null -eq $pool){return}
  foreach($window in @($pool.Windows)){
    $remaining=$window.remainingPercent
    $row=New-Object Windows.Controls.StackPanel
    $row.Margin=[Windows.Thickness]::new(0,0,0,13)
    $grid=New-Object Windows.Controls.Grid
    $label=New-Object Windows.Controls.TextBlock
    $label.Text=Get-WindowLabel $window; $label.FontSize=11.5; $label.Foreground=$brushMuted
    $label.VerticalAlignment='Center'
    $value=New-Object Windows.Controls.TextBlock
    $value.Text=if($null -eq $remaining){'—'}else{'{0:0.#}%' -f $remaining}
    $value.FontSize=19; $value.FontWeight='Bold'; $value.HorizontalAlignment='Right'
    $value.Foreground=if($null -eq $remaining){$brushMuted}elseif($remaining -le 0){$brushRed}elseif($remaining -lt 30){$brushAmber}else{$brushBlue}
    [void]$grid.Children.Add($label);[void]$grid.Children.Add($value)
    $bar=New-Object Windows.Controls.ProgressBar
    $bar.Height=6; $bar.Minimum=0; $bar.Maximum=100; $bar.Value=if($null -eq $remaining){0}else{$remaining}
    $bar.Margin=[Windows.Thickness]::new(0,6,0,0); $bar.BorderThickness=[Windows.Thickness]::new(0)
    $bar.Background=$brushTrack; $bar.Foreground=$value.Foreground
    $reset=New-Object Windows.Controls.TextBlock
    $reset.Text=if($null -eq $remaining){'额度暂未提供'}else{Format-Reset $window}
    $reset.FontSize=10.5; $reset.Foreground=$brushMuted; $reset.TextWrapping='Wrap'; $reset.Margin=[Windows.Thickness]::new(0,6,0,0)
    [void]$row.Children.Add($grid);[void]$row.Children.Add($bar);[void]$row.Children.Add($reset)
    [void]$ui.Rows.Children.Add($row)
  }
  if(@($pool.Windows).Count -eq 0){
    $empty=New-Object Windows.Controls.TextBlock; $empty.Text='当前额度池暂未提供窗口数据';$empty.Foreground=$brushMuted
    [void]$ui.Rows.Children.Add($empty)
  }
}
function Show-QuotaResult($Data) {
  if($Data.status -ne 'ok'){
    $errorText=if($Data.error.message){[string]$Data.error.message}else{'当前账户尚未返回可用额度'}
    if($script:lastUpdated){$errorText='更新失败，保留上次数据 · '+$script:lastUpdated.ToString('HH:mm')+' · '+$errorText}
    Set-StateText $errorText $true;return
  }
  $previous=$ui.PoolPicker.SelectedValue
  $script:pools=@(Get-QuotaPools $Data)
  $script:rendering=$true
  try {
    $ui.PoolPicker.Items.Clear()
    foreach($pool in $script:pools){[void]$ui.PoolPicker.Items.Add($pool)}
    $ui.PoolPicker.SelectedIndex=Get-PreferredPoolIndex $script:pools $previous
    $ui.PoolPicker.Visibility=if($script:pools.Count -gt 1){'Visible'}else{'Collapsed'}
    $ui.PoolName.Visibility=if($script:pools.Count -gt 1){'Collapsed'}else{'Visible'}
    $ui.PoolName.Text=if($script:pools.Count){$script:pools[0].Name}else{'尚无额度池'}
  } finally {$script:rendering=$false}
  Render-SelectedPool
  try {$script:lastUpdated=[DateTimeOffset]::Parse($Data.fetchedAt).ToLocalTime()}catch{$script:lastUpdated=[DateTimeOffset]::Now}
  Set-StateText ('更新于 {0:HH:mm} · 每分钟刷新' -f $script:lastUpdated)
}
function Update-Quota {
  if($script:closing -or $null -ne $script:request){return}
  Set-StateText '正在读取额度…';$ui.RefreshButton.IsEnabled=$false
  try {$script:request=Start-QuotaRequest $nodePath $workerPath}
  catch {$ui.RefreshButton.IsEnabled=$true;Set-StateText '无法启动额度读取，请检查插件运行环境' $true}
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class QuotaWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action,uint param,out RECT rc,uint winIni);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int cx,int cy,uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int command);
}
"@
$script:winInterop=New-Object Windows.Interop.WindowInteropHelper($win)
$win.Add_SourceInitialized({[void][QuotaWin]::ShowWindow($script:winInterop.Handle,4)})
function Get-WidgetRect {
  $rect=New-Object QuotaWin+RECT
  [void][QuotaWin]::GetWindowRect($script:winInterop.Handle,[ref]$rect)
  return $rect
}
function Apply-Position {
  $handle=$script:winInterop.Handle;if($handle -eq [IntPtr]::Zero){return}
  $current=Get-WidgetRect;$width=$current.R-$current.L;$height=$current.B-$current.T
  if($width -le 0 -or $height -le 0){return}
  $area=New-Object QuotaWin+RECT;[void][QuotaWin]::SystemParametersInfo(0x0030,0,[ref]$area,0)
  $saved=Load-State;$x=$null;$y=$null
  if($saved -and $saved.PSObject.Properties.Name -contains 'left'){$x=[int]$saved.left;$y=[int]$saved.top}
  if($null -eq $x -or $x -lt $area.L -or $x -gt ($area.R-80) -or $y -lt $area.T -or $y -gt ($area.B-60)){$x=$area.R-$width-24;$y=$area.B-$height-24}
  [void][QuotaWin]::SetWindowPos($handle,[IntPtr](-1),$x,$y,0,0,0x0001 -bor 0x0040)
}
function Save-Position {
  if($script:winInterop.Handle -eq [IntPtr]::Zero){return}
  $rect=Get-WidgetRect;if($rect.R -gt $rect.L){Save-State $rect.L $rect.T}
}
function Test-BoundDesktopAlive {
  try {
    $script:desktopProcess.Refresh()
    if($script:desktopProcess.HasExited){return $false}
    $actual=[pscustomobject]@{Id=$script:desktopProcess.Id;StartTicks=$script:desktopProcess.StartTime.ToUniversalTime().Ticks.ToString();Path=$script:desktopProcess.MainModule.FileName}
    return (Test-DesktopIdentity $script:desktopIdentity $actual)
  } catch {return $false}
}

$pollTimer=New-Object Windows.Threading.DispatcherTimer
$pollTimer.Interval=[TimeSpan]::FromMilliseconds(100)
$pollTimer.Add_Tick({
  if($closeSignal.WaitOne(0)){$win.Close();return}
  if($null -eq $script:request){return}
  $result=Receive-QuotaRequest $script:request
  if($null -ne $result){
    $script:request.Process.Dispose();$script:request=$null;$ui.RefreshButton.IsEnabled=$true
    Show-QuotaResult $result
  } elseif(([DateTime]::UtcNow-$script:request.StartedAt).TotalSeconds -gt 25){Stop-QuotaRequest $script:request}
})
$lifeTimer=New-Object Windows.Threading.DispatcherTimer
$lifeTimer.Interval=[TimeSpan]::FromMilliseconds(350)
$lifeTimer.Add_Tick({if(-not (Test-BoundDesktopAlive)){$win.Close()}})
$refreshTimer=New-Object Windows.Threading.DispatcherTimer
$refreshTimer.Interval=[TimeSpan]::FromSeconds(60)
$refreshTimer.Add_Tick({Update-Quota})
$ui.DragHeader.Add_MouseLeftButtonDown({if($_.OriginalSource -is [Windows.Controls.TextBlock] -or $_.OriginalSource -eq $ui.DragHeader){$win.DragMove()}})
$ui.RefreshButton.Add_Click({Update-Quota})
$ui.CloseButton.Add_Click({$win.Close()})
$ui.PoolPicker.Add_SelectionChanged({if(-not $script:rendering){Render-SelectedPool}})
$win.Add_LocationChanged({$script:pendingSave=$true})
$win.Add_MouseLeftButtonUp({if($script:pendingSave){Save-Position;$script:pendingSave=$false}})
$win.Add_Closing({
  $script:closing=$true;$pollTimer.Stop();$lifeTimer.Stop();$refreshTimer.Stop()
  Save-Position;Stop-QuotaRequest $script:request
})
$win.Add_ContentRendered({Apply-Position;Update-Quota})
try {
  $pollTimer.Start();$lifeTimer.Start();$refreshTimer.Start()
  [void]$win.ShowDialog()
} finally {
  Stop-QuotaRequest $script:request
  try {$mutex.ReleaseMutex()}catch{}
  $closeSignal.Dispose();$mutex.Dispose();$script:desktopProcess.Dispose()
}
