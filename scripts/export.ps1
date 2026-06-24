<#
.SYNOPSIS
    Exports a Copilot Studio Modern Orchestration (NGO) agent from a source environment.
    Captures YAML via pac copilot clone AND skill/knowledge botcomponents from Dataverse.

.DESCRIPTION
    Classic pac copilot clone misses:
      1. InlineAgentSkill (knowledge) botcomponents stored in Dataverse
    This script captures both and saves them to ./sample/ and ./skills/.

.PARAMETER PacExe
    Path to pac.exe. Defaults to the Microsoft.PowerApps.CLI NuGet tool path.

.PARAMETER SourceOrgUrl
    Dataverse org URL for the source environment.

.PARAMETER AgentName
    Display name of the agent to clone.

.PARAMETER AuthIndex
    pac auth index for the source environment account.

.EXAMPLE
    .\scripts\export.ps1
#>
param(
    [string]$PacExe     = "C:\Users\kkanjitajdin\.nuget\packages\microsoft.powerapps.cli\2.8.1\tools\pac.exe",
    [string]$SourceOrgUrl = "https://orgea8005ed.crm.dynamics.com",
    [string]$AgentName  = "Fabric Analyst",
    [string]$BotId      = "d01d7579-bf47-4da7-b751-22a419ade844",
    [int]   $AuthIndex  = 2
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot  = Split-Path $ScriptDir -Parent

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Modern Agent Export — NGO Toolkit" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Source env : $SourceOrgUrl"
Write-Host "Agent      : $AgentName"
Write-Host ""

# ── Step 1: Select source auth ──────────────────────────────────────────────
Write-Host "[1/4] Selecting pac auth index $AuthIndex (source env)..." -ForegroundColor Yellow
& $PacExe auth select --index $AuthIndex | Out-Null

# ── Step 2: pac copilot clone ───────────────────────────────────────────────
Write-Host "[2/4] Cloning agent YAML via pac copilot clone..." -ForegroundColor Yellow
$sampleDir = Join-Path $RepoRoot "sample"
& $PacExe copilot clone `
    --environment $SourceOrgUrl `
    --agent $AgentName `
    --output-dir $sampleDir

if ($LASTEXITCODE -ne 0) {
    Write-Error "pac copilot clone failed with exit code $LASTEXITCODE"
}
Write-Host "  → YAML cloned to: $sampleDir\$AgentName" -ForegroundColor Green

# ── Step 3: Get DV bearer token via az CLI ───────────────────────────────────
Write-Host "[3/4] Fetching Dataverse access token via az CLI..." -ForegroundColor Yellow
$orgNoTrail = $SourceOrgUrl.TrimEnd("/")
$tokenJson  = az account get-access-token --resource $orgNoTrail 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "az account get-access-token failed. Trying az login..."
    az login --allow-no-subscriptions | Out-Null
    $tokenJson = az account get-access-token --resource $orgNoTrail
}
$token   = ($tokenJson | ConvertFrom-Json).accessToken
$headers = @{
    Authorization    = "Bearer $token"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    Accept           = "application/json"
}

# ── Step 4: Export skill botcomponents (type 9, InlineAgentSkill) ────────────
Write-Host "[4/4] Exporting skill botcomponents from Dataverse..." -ForegroundColor Yellow
$uri     = "$orgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$BotId' and componenttype eq 9&`$select=botcomponentid,name,schemaname,data,description"
$result  = Invoke-RestMethod -Uri $uri -Headers $headers
$skills  = $result.value | Where-Object { $_.data -like "*kind: InlineAgentSkill*" }

$skillsDir = Join-Path $RepoRoot "skills"
New-Item -ItemType Directory -Force -Path $skillsDir | Out-Null
$exported  = 0

foreach ($skill in $skills) {
    # Extract the content block from the YAML data field
    $yaml    = $skill.data
    $content = ""
    if ($yaml -match "(?s)content:\s*\|-\s*\n(.*?)(?:\n\w|\z)") {
        $content = $Matches[1] -replace "(?m)^  ", ""  # strip 2-space indent
    } elseif ($yaml -match "(?s)content:\s*'(.*?)'") {
        $content = $Matches[1]
    } else {
        # fallback: save raw YAML data
        $content = $yaml
    }

    $safeName = ($skill.name -replace '[\\/:*?"<>|]', '-').Trim()
    $outPath  = Join-Path $skillsDir "$safeName.md"
    $content | Set-Content $outPath -Encoding UTF8
    Write-Host "  → Saved: skills\$safeName.md" -ForegroundColor Green
    $exported++
}

if ($exported -eq 0) {
    Write-Host "  (No InlineAgentSkill components found for this bot)" -ForegroundColor DarkGray
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Export Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$agentDir = Join-Path $sampleDir $AgentName
$yamls    = (Get-ChildItem $agentDir -Filter "*.mcs.yml" -Recurse).Count
Write-Host "  Agent YAML files : $yamls"
Write-Host "  Skill files      : $exported"
Write-Host ""
Write-Host "Next step: run scripts\install.ps1 to deploy to a target environment."
