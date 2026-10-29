# Pure selection and nonblocking process helpers, shared by the window and tests.

function Resolve-QuotaNode {
  if($env:CODEX_QUOTA_NODE_PATH -and (Test-Path -LiteralPath $env:CODEX_QUOTA_NODE_PATH)){return $env:CODEX_QUOTA_NODE_PATH}
  $command=Get-Command node -ErrorAction SilentlyContinue
  if($command -and $command.Source){return $command.Source}
  $userProfile=[Environment]::GetFolderPath('UserProfile')
  $bundled=Join-Path $userProfile '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
  if(Test-Path -LiteralPath $bundled){return $bundled}
  $runtimeRoot=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
  if(Test-Path -LiteralPath $runtimeRoot){
    $runtime=Get-ChildItem -LiteralPath $runtimeRoot -Directory | Sort-Object LastWriteTimeUtc -Descending | ForEach-Object {Join-Path $_.FullName 'bin\node.exe'} | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
    if($runtime){return $runtime}
  }
  throw 'Node.js 20+ not found. Install Node.js or set CODEX_QUOTA_NODE_PATH.'
}

function Select-DesktopHost($Processes) {
  $candidates = @($Processes | Where-Object {
    $_.Name -ieq 'ChatGPT.exe' -and
    $_.ExecutablePath -match '(?i)[\\/]OpenAI\.Codex_[^\\/]+[\\/]app[\\/]ChatGPT\.exe$|[\\/]OpenAI[\\/]Codex[\\/](app[\\/])?ChatGPT\.exe$' -and
    $_.CommandLine -notmatch '(?i)--type(?:=|\s)'
  })
  # An ambiguous desktop identity must never silently bind to another instance.
  if ($candidates.Count -eq 1) { return $candidates[0] }
  return $null
}

function Test-DesktopIdentity($Expected, $Actual) {
  if ($null -eq $Expected -or $null -eq $Actual) { return $false }
  return ([int]$Expected.Id -eq [int]$Actual.Id -and
    [string]$Expected.StartTicks -eq [string]$Actual.StartTicks -and
    [string]$Expected.Path -ieq [string]$Actual.Path)
}

function Get-QuotaPools($Data) {
  if ($null -eq $Data -or $Data.status -ne 'ok') { return @() }
  return @($Data.buckets | Where-Object { $null -ne $_ -and $_.id } | ForEach-Object {
    $poolName = if ($_.name) { [string]$_.name } else { [string]$_.id }
    [pscustomobject]@{ Id = [string]$_.id; Name = $poolName; Windows = @($_.windows) }
  })
}

function Get-PreferredPoolIndex($Pools, [string]$PreviousId) {
  for ($index = 0; $index -lt $Pools.Count; $index++) {
    if ($PreviousId -and $Pools[$index].Id -eq $PreviousId) { return $index }
  }
  for ($index = 0; $index -lt $Pools.Count; $index++) {
    if ($Pools[$index].Id -ieq 'codex') { return $index }
  }
  if ($Pools.Count) { return 0 }
  return -1
}

function Start-QuotaRequest([string]$NodePath, [string]$WorkerPath) {
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $NodePath
  $info.Arguments = '"' + $WorkerPath + '"'
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
  $childProcess = [System.Diagnostics.Process]::Start($info)
  return [pscustomobject]@{
    Process = $childProcess
    OutputTask = $childProcess.StandardOutput.ReadToEndAsync()
    ErrorTask = $childProcess.StandardError.ReadToEndAsync()
    StartedAt = [DateTime]::UtcNow
    CancelledAt = $null
  }
}

function Stop-QuotaRequest($Request) {
  if ($null -eq $Request -or $null -ne $Request.CancelledAt) { return }
  $Request.CancelledAt = [DateTime]::UtcNow
  try { $Request.Process.StandardInput.WriteLine('cancel'); $Request.Process.StandardInput.Flush() } catch {}
}

function Receive-QuotaRequest($Request) {
  if ($null -eq $Request) { return $null }
  # Neither ReadToEnd nor Wait is called until both asynchronous reads complete.
  if (-not $Request.Process.HasExited -or -not $Request.OutputTask.IsCompleted -or -not $Request.ErrorTask.IsCompleted) { return $null }
  try {
    $payload = $Request.OutputTask.GetAwaiter().GetResult() | ConvertFrom-Json
    if ($payload.status -notin @('ok','unavailable','error')) { throw 'Invalid status' }
    return $payload
  } catch {
    return [pscustomobject]@{ status='error'; error=[pscustomobject]@{message='读取额度失败，请稍后刷新。'} }
  }
}
