<#
.SYNOPSIS
    Exports a Copilot Studio Modern Orchestration (NGO / cliagent-1.0.0) agent.

.DESCRIPTION
    Classic 'pac copilot clone' misses three things for NGO agents:
      1. Bot configuration JSON  — bot.configuration in Dataverse (instructions, model, AI settings)
      2. InlineAgentSkill files  — knowledge botcomponents stored in Dataverse, not in YAML
      3. Flow ID context         — action YAMLs embed env-specific flowIds (handled by install.ps1)

    Saves to:
      ./sample/Fabric Analyst/   ← YAML (via pac clone)
      ./sample/agent-config.json ← bot.configuration (instructions, model, AI settings)
      ./skills/*.md              ← InlineAgentSkill knowledge files

.EXAMPLE
    .\scripts\export.ps1
    .\scripts\export.ps1 -SourceOrgUrl "https://myorg.crm.dynamics.com" -AgentName "My Agent" -BotId "your-guid"
#>
param(
    [string]$PacExe       = "C:\Users\kkanjitajdin\.nuget\packages\microsoft.powerapps.cli\2.8.1\tools\pac.exe",
    [string]$SourceOrgUrl = "https://orgea8005ed.crm.dynamics.com",
    [string]$AgentName    = "Fabric Analyst",
    [string]$BotId        = "d01d7579-bf47-4da7-b751-22a419ade844",
    [int]   $AuthIndex    = 2
)

$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot   = Split-Path $ScriptDir -Parent
$OrgNoTrail = $SourceOrgUrl.TrimEnd("/")

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Modern Agent Export — NGO Toolkit" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Source env : $OrgNoTrail`nAgent      : $AgentName ($BotId)`n"

# Step 1: pac auth
Write-Host "[1/5] Selecting pac auth index $AuthIndex..." -ForegroundColor Yellow
& $PacExe auth select --index $AuthIndex | Out-Null

# Step 2: pac clone
Write-Host "[2/5] Cloning YAML via pac copilot clone..." -ForegroundColor Yellow
$sampleDir = Join-Path $RepoRoot "sample"
& $PacExe copilot clone --environment $OrgNoTrail --agent $AgentName --output-dir $sampleDir
if ($LASTEXITCODE -ne 0) { Write-Error "pac copilot clone failed ($LASTEXITCODE)" }
Write-Host "  -> YAML: $sampleDir\$AgentName" -ForegroundColor Green

# Step 3: DV token
Write-Host "[3/5] Acquiring Dataverse token via az CLI..." -ForegroundColor Yellow
$token   = (az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json).accessToken
$headers = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json" }

# Step 4: Export bot.configuration
Write-Host "[4/5] Exporting bot.configuration (instructions + model)..." -ForegroundColor Yellow
$botResult  = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots($BotId)?`$select=configuration" -Headers $headers
$configJson = $botResult.configuration
if ($configJson.Length -gt 0) {
    $configPath = Join-Path $sampleDir "agent-config.json"
    $configJson | Set-Content $configPath -Encoding UTF8
    Write-Host "  -> sample\agent-config.json ($($configJson.Length) chars)" -ForegroundColor Green
} else {
    Write-Warning "  bot.configuration is empty on source agent"
}

# Step 5: Export InlineAgentSkill botcomponents
Write-Host "[5/5] Exporting InlineAgentSkill knowledge components..." -ForegroundColor Yellow
$uri    = "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$BotId' and componenttype eq 9&`$select=botcomponentid,name,data"
$skills = (Invoke-RestMethod -Uri $uri -Headers $headers).value | Where-Object { $_.data -like "*InlineAgentSkill*" }
$skillsDir = Join-Path $RepoRoot "skills"
New-Item -ItemType Directory -Force -Path $skillsDir | Out-Null
$n = 0
foreach ($s in $skills) {
    $content = if ($s.data -match "(?s)content:\s*\|-\s*\n(.*?)(?:\n[^\s]|\z)") { $Matches[1] -replace "(?m)^  ","" } else { $s.data }
    $outPath = Join-Path $skillsDir (($s.name -replace '[\\/:*?"<>|]','-').Trim() + ".md")
    $content | Set-Content $outPath -Encoding UTF8
    Write-Host "  -> skills\$(Split-Path $outPath -Leaf)" -ForegroundColor Green; $n++
}
if ($n -eq 0) { Write-Host "  (no InlineAgentSkill components found)" -ForegroundColor DarkGray }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Export Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$yc = (Get-ChildItem (Join-Path $sampleDir $AgentName) -Filter "*.mcs.yml" -Recurse).Count
Write-Host "  YAML files        : $yc`n  agent-config.json : $(if ($configJson.Length -gt 0){'saved'}else{'missing'})`n  Skill files       : $n`n"
Write-Host "Next: run scripts\install.ps1 to deploy to any environment."
