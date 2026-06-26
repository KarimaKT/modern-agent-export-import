<#
.SYNOPSIS
    Export EVERY modern Copilot Studio agent in an environment, each to its own bundle.

.DESCRIPTION
    A convenience wrapper around distribute/export.ps1 for backing up or migrating a whole
    environment. It finds every modern (instructions + tools) agent in the source environment and
    exports each one to its own {AgentName}-bundle.zip in the output folder. It keeps going if one
    agent fails, and prints a summary at the end.

    Each agent gets its own distribution solution (named from the agent). Classic (topic-based)
    agents are listed and skipped — this toolkit is for modern agents.

    PREREQUISITES
    -------------
    PowerShell 7+, Power Platform CLI (pac), Azure CLI (az), signed in to both.

.PARAMETER SourceOrgUrl   Dataverse org URL for the source environment.
.PARAMETER PublisherName  Publisher unique name OR customization prefix for the solutions.
.PARAMETER OutputDir      Folder for the bundles (one per agent). Defaults to .\agents-export.
.PARAMETER AuthIndex      pac auth index for the source environment.
.PARAMETER PacExe         Path to pac.exe. Auto-detected if not specified.

.EXAMPLE
    .\export-all.ps1 -SourceOrgUrl "https://myorg.crm.dynamics.com" -PublisherName "myprefix"
#>
param(
    [Parameter(Mandatory)][string] $SourceOrgUrl,
    [Parameter(Mandatory)][string] $PublisherName,
    [string] $OutputDir = "",
    [int]    $AuthIndex = 1,
    [string] $PacExe    = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$OrgNoTrail = $SourceOrgUrl.TrimEnd("/")
$OutputDir  = if ($OutputDir) { $OutputDir } else { Join-Path (Get-Location) "agents-export" }
$OutputDir  = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Step([string]$msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function OK([string]$msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function WARN([string]$msg) { Write-Host "    !   $msg" -ForegroundColor Yellow }
function INFO([string]$msg) { Write-Host "        $msg" -ForegroundColor DarkGray }

# Friendly token preflight (mirrors export.ps1).
function Get-DvToken {
    param([string]$OrgUrl)
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Error "The Azure CLI ('az') is not installed. Install it from https://aka.ms/installazurecliwindows, run 'az login', then retry."
    }
    $raw = az account get-access-token --resource $OrgUrl 2>&1
    $tok = $null
    try { $tok = ($raw | ConvertFrom-Json).accessToken } catch {}
    if (-not $tok) {
        $signedIn = $false
        try { if (az account show 2>$null) { $signedIn = $true } } catch {}
        if (-not $signedIn) { Write-Error "You're not signed in to Azure. Run 'az login', then retry." }
        Write-Error "Couldn't get access to '$OrgUrl'. Check the URL and your access. (az said: $raw)"
    }
    try {
        Invoke-RestMethod -Uri "$OrgUrl/api/data/v9.2/WhoAmI" -Headers @{ Authorization="Bearer $tok"; Accept="application/json" } -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Couldn't reach the environment at '$OrgUrl'. Check the URL is your Dataverse org URL and that your account has access. ($($_.Exception.Message))"
    }
    return $tok
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Export ALL modern agents in an environment" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Source : $OrgNoTrail"
Write-Host "  Output : $OutputDir"
Write-Host ""

Step "Listing agents"
$token = Get-DvToken -OrgUrl $OrgNoTrail
$dv = @{ Authorization="Bearer $token"; Accept="application/json" }
$allBots = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots?`$select=botid,name,template&`$orderby=name" -Headers $dv).value
$modern  = @($allBots | Where-Object { $_.template -like "cliagent-*" })
$classic = @($allBots | Where-Object { $_.template -notlike "cliagent-*" })
OK "$($modern.Count) modern agent(s) to export; $($classic.Count) classic agent(s) skipped"
if ($classic.Count -gt 0) { $classic | ForEach-Object { INFO "skip (classic): $($_.name)" } }
if ($modern.Count -eq 0) { Write-Error "No modern agents found in this environment." }

$exportPs1 = Join-Path $ScriptDir "export.ps1"
$results = @()
$usedBundleNames = @{}
foreach ($bot in $modern) {
    Step "Exporting '$($bot.name)'"
    # A safe, unique solution name per agent (include a short id so two same-named agents don't
    # share — and thus contaminate — one solution).
    $safe = ($bot.name -replace '[^A-Za-z0-9]', '')
    if (-not $safe) { $safe = "Agent" }
    $solName = "EXP$safe$($bot.botid.Substring(0,8) -replace '-','')"
    # Export into a per-agent work folder so two same-named agents can't overwrite each other's
    # bundle (export.ps1 always writes "<name>-bundle.zip"). We move the result out afterwards.
    $workDir = Join-Path $OutputDir "_work_$($bot.botid.Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    try {
        & $exportPs1 -SourceOrgUrl $OrgNoTrail -BotId $bot.botid -SolutionName $solName `
            -PublisherName $PublisherName -OutputDir $workDir -AuthIndex $AuthIndex -PacExe $PacExe 2>&1 |
            ForEach-Object { INFO $_ }
        $produced = Get-ChildItem $workDir -Filter "*-bundle.zip" | Select-Object -First 1
        if ($produced) {
            $leaf = $produced.Name
            if ($usedBundleNames.ContainsKey($leaf)) {
                $leaf = "$($bot.name -replace '[^\w\-]','-')-$($bot.botid.Substring(0,8))-bundle.zip"
                INFO "Another agent shares this name — saving as $leaf to avoid overwriting."
            }
            Move-Item $produced.FullName (Join-Path $OutputDir $leaf) -Force
            $usedBundleNames[$leaf] = $true
            OK "Bundle: $leaf"
            $results += [pscustomobject]@{ agent = $bot.name; status = "ok"; bundle = $leaf }
        } else {
            WARN "Export finished but no bundle found for '$($bot.name)'"
            $results += [pscustomobject]@{ agent = $bot.name; status = "no-bundle"; bundle = "" }
        }
    } catch {
        WARN "Failed: $($_.Exception.Message)"
        $results += [pscustomobject]@{ agent = $bot.name; status = "failed"; bundle = "" }
    } finally {
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Export-All Complete" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
$ok = @($results | Where-Object { $_.status -eq "ok" })
$bad = @($results | Where-Object { $_.status -ne "ok" })
Write-Host "  Output folder : $OutputDir"
Write-Host "  Exported      : $($ok.Count) / $($modern.Count)" -ForegroundColor Green
$ok | ForEach-Object { Write-Host "    [x] $($_.agent) -> $($_.bundle)" -ForegroundColor Green }
if ($bad.Count -gt 0) {
    Write-Host "  Not exported  : $($bad.Count)" -ForegroundColor Yellow
    $bad | ForEach-Object { Write-Host "    [!] $($_.agent) ($($_.status))" -ForegroundColor Yellow }
}
Write-Host ""
Write-Host "  Install any one with:"
Write-Host "    .\distribute\install.ps1 -BundleZip '<folder>\<Agent>-bundle.zip' -TargetOrgUrl <url>" -ForegroundColor Cyan
