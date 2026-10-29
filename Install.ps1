[CmdletBinding()]
param([string]$InstallRoot, [switch]$PrepareOnly)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'plugins\quota-lite'
. (Join-Path $source 'widget\widget-core.ps1')
$node=Resolve-QuotaNode
$nodeVersion=& $node --version
if($LASTEXITCODE -ne 0 -or [int]($nodeVersion.TrimStart('v').Split('.')[0]) -lt 20){throw 'Node.js 20+ is required.'}
$manifest=Get-Content -LiteralPath (Join-Path $source '.codex-plugin\plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not $InstallRoot){$InstallRoot=Join-Path $env:LOCALAPPDATA 'CodexQuotaLite'}
$InstallRoot=[IO.Path]::GetFullPath($InstallRoot)
$versionPath='releases/'+$manifest.version+'/plugins/quota-lite'
$destination=Join-Path $InstallRoot $versionPath
[void](New-Item -ItemType Directory -Path $destination -Force)
Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $destination -Recurse -Force
$mcpPath=Join-Path $destination '.mcp.json'
$mcp=Get-Content -LiteralPath $mcpPath -Raw -Encoding UTF8 | ConvertFrom-Json
$mcp.mcpServers.quota.command=$node
[IO.File]::WriteAllText($mcpPath,($mcp|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$marketplaceDirectory=Join-Path $InstallRoot '.agents\plugins'
[void](New-Item -ItemType Directory -Path $marketplaceDirectory -Force)
$marketplace=Get-Content -LiteralPath (Join-Path $PSScriptRoot '.agents\plugins\marketplace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$marketplace.plugins[0].source.path='./'+$versionPath
[IO.File]::WriteAllText((Join-Path $marketplaceDirectory 'marketplace.json'),($marketplace|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
Write-Output "Prepared quota-lite $($manifest.version): $destination"
if($PrepareOnly){return}
$codex=Get-Command codex -ErrorAction SilentlyContinue
$codexPath=if($codex){$codex.Source}else{$null}
if(-not $codexPath){
 $cliRoot=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
 $codexPath=Get-ChildItem -LiteralPath $cliRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | ForEach-Object {Join-Path $_.FullName 'codex.exe'} | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
}
if(-not $codexPath){throw 'Codex CLI not found. Install and launch Codex first.'}
& $codexPath plugin marketplace add $InstallRoot --json
if($LASTEXITCODE -ne 0){throw 'Marketplace registration failed.'}
& $codexPath plugin add 'quota-lite@quota-lite-community' --json
if($LASTEXITCODE -ne 0){throw 'Plugin installation failed. Close Codex and retry if the cache is in use.'}
Write-Output 'Installed. Restart Codex and ask: open the quota panel.'
