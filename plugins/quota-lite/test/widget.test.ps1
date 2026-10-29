$ErrorActionPreference='Stop'
$pluginRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $pluginRoot 'widget/widget-core.ps1')
$script:passed=0
function Assert-True([bool]$Value,[string]$Name){if(-not $Value){throw "FAIL: $Name"};$script:passed++;Write-Output "PASS: $Name"}
$desktop=[pscustomobject]@{Name='ChatGPT.exe';ProcessId=900;ExecutablePath='C:\Program Files\WindowsApps\OpenAI.Codex_26.0_x64__test\app\ChatGPT.exe';CommandLine='"ChatGPT.exe"'}
$cli=[pscustomobject]@{Name='codex.exe';ProcessId=100;ExecutablePath='C:\Users\test\AppData\Local\OpenAI\Codex\bin\hash\codex.exe';CommandLine='codex app-server'}
$helper=[pscustomobject]@{Name='ChatGPT.exe';ProcessId=200;ExecutablePath=$desktop.ExecutablePath;CommandLine='ChatGPT.exe --type=renderer'}
Assert-True ((Select-DesktopHost @($cli,$helper,$desktop)).ProcessId -eq 900) 'desktop selection excludes CLI and renderers regardless of PID order'
Assert-True ($null -eq (Select-DesktopHost @($cli,$helper))) 'no fallback to unrelated CLI when desktop exits'
Assert-True ($null -eq (Select-DesktopHost @($desktop,$desktop))) 'ambiguous desktop instances do not bind silently'
$expected=[pscustomobject]@{Id=900;StartTicks='123';Path=$desktop.ExecutablePath}
$reused=[pscustomobject]@{Id=900;StartTicks='456';Path=$desktop.ExecutablePath}
Assert-True (Test-DesktopIdentity $expected $expected) 'same desktop identity stays bound'
Assert-True (-not(Test-DesktopIdentity $expected $reused)) 'reused process ID is rejected'
Assert-True (-not(Test-DesktopIdentity $expected $null)) 'exited desktop is rejected'
$data=[pscustomobject]@{status='ok';buckets=@(
 [pscustomobject]@{id='other';name='Other pool';windows=@([pscustomobject]@{remainingPercent=20},[pscustomobject]@{remainingPercent=10})},
 [pscustomobject]@{id='codex';name='Codex';windows=@([pscustomobject]@{remainingPercent=95},[pscustomobject]@{remainingPercent=83})}
)}
$pools=@(Get-QuotaPools $data)
Assert-True ($pools.Count -eq 2 -and $pools[0].Name -eq 'Other pool' -and $pools[1].Windows.Count -eq 2) 'all pools and labels are retained'
$preferred=Get-PreferredPoolIndex $pools ''
Assert-True ($preferred -eq 1 -and $pools[$preferred].Windows[0].remainingPercent -eq 95) 'Codex is default even when another pool arrives first'
Assert-True ((Get-PreferredPoolIndex $pools 'other') -eq 0) 'manual pool selection persists across refresh'
$unknown=[pscustomobject]@{status='ok';buckets=@([pscustomobject]@{id='codex';name='Codex';windows=@([pscustomobject]@{remainingPercent=$null})})}
Assert-True ($null -eq @(Get-QuotaPools $unknown)[0].Windows[0].remainingPercent) 'unknown quota remains unknown'
$tempDir=Join-Path ([IO.Path]::GetTempPath()) ('quota-widget-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempDir)
$worker=Join-Path $tempDir 'slow-worker.mjs'
[IO.File]::WriteAllText($worker,@'
process.stdin.on('data',()=>{process.stdout.write(JSON.stringify({status:'error',error:{code:'cancelled'}}));process.exit(0)});
setTimeout(()=>{process.stdout.write(JSON.stringify({status:'ok',buckets:[]}));process.exit(0)},1800);
'@,[Text.UTF8Encoding]::new($false))
$node=Resolve-QuotaNode
$request=$null
try {
 $clock=[Diagnostics.Stopwatch]::StartNew();$request=Start-QuotaRequest $node $worker
 Assert-True ($clock.ElapsedMilliseconds -lt 1000) 'starting a slow request returns without waiting'
 Assert-True ($null -eq (Receive-QuotaRequest $request)) 'pending quota polling returns immediately'
 Add-Type -AssemblyName WindowsBase
 $script:beats=0;$script:reply=$null
 $frame=New-Object Windows.Threading.DispatcherFrame
 $timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(50)
 $timer.Add_Tick({$script:beats++;$script:reply=Receive-QuotaRequest $request;if($null -ne $script:reply -or $script:beats -ge 100){$frame.Continue=$false}})
 $timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame);$timer.Stop()
 Assert-True ($script:beats -ge 10 -and $script:reply.status -eq 'ok') ("WPF dispatcher stays responsive during slow quota read (beats=$script:beats; status=$($script:reply.status); node=$node; stdout=$($request.OutputTask.GetAwaiter().GetResult()); stderr=$($request.ErrorTask.GetAwaiter().GetResult()))")
 $request.Process.Dispose();$request=Start-QuotaRequest $node $worker;Stop-QuotaRequest $request
 $deadline=[datetime]::UtcNow.AddSeconds(3)
 while(-not $request.Process.HasExited -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 20}
 Assert-True $request.Process.HasExited 'closing cancels worker promptly'
} finally {
 if($request){Stop-QuotaRequest $request;try{if(-not $request.Process.HasExited){$request.Process.Kill()}}catch{};$request.Process.Dispose()}
 [IO.File]::Delete($worker);[IO.Directory]::Delete($tempDir)
}
Write-Output "Widget checks passed: $script:passed"