<#
.SYNOPSIS
    Export a Modern Copilot Studio agent for VS Code editing + reliable redeploy.

.DESCRIPTION
    Produces three things from a source agent:

      sample/<AgentName>/        Editable YAML (pac copilot clone) — for reading, diffing,
                                 code review, and version control.
      sample/<AgentName>.instructions.md
                                 The agent's instructions as a plain Markdown file — THE thing
                                 you edit to change agent behaviour. Edits here are deployed.
      <AgentName>-bundle.zip     The deployable artifact (a Dataverse solution bundle) used by
                                 develop/install.ps1. Built with the same reliable mechanism as
                                 the distribute/ path — every tool, skill, flow, knowledge source
                                 and eval case is captured.

    WHY THIS DESIGN (read this — it defines what you can and cannot edit)
    ────────────────────────────────────────────────────────────────────
    `pac copilot push` cannot reliably deploy cliagent-* agents (it is manifest-driven and
    silently drops components, and its post-push reader crashes). So this toolkit does NOT use
    pac push. Instead it deploys via Dataverse solution import — the same reliable path the
    distribute/ workflow uses.

    That choice creates ONE clear constraint, and the scripts are explicit about it at runtime:

      ✅ DEPLOYABLE by editing locally — instructions, model, and AI settings.
         You edit sample/<AgentName>.instructions.md (or agent-config.json for model/AI settings)
         and develop/install.ps1 applies them via a Dataverse bot.configuration PATCH.

      ⚠️ NOT deployable by hand-editing YAML — adding/removing tools, connectors, skills, flows,
         or changing a tool's wiring. The structure is carried by the solution bundle exactly as
         it was in the source agent. To change structure, make the change in Copilot Studio on a
         source agent and re-run this export. (This is a platform limitation, not a missing
         feature — there is no reliable API to push arbitrary structural YAML for cliagent-*.)

    The editable YAML in sample/ is still valuable: read it, diff it in pull requests, and use it
    to understand the agent. Just know that structural edits to it are not what gets deployed.

    PREREQUISITES
    ─────────────
    pac CLI:  https://aka.ms/PowerPlatformCLI
    az CLI:   https://aka.ms/installazurecliwindows
    pac auth: pac auth create --environment https://yourorg.crm.dynamics.com
    az login: az login (with Dataverse access to source env)

.PARAMETER SourceOrgUrl    Dataverse org URL for the source environment.
.PARAMETER BotId           Dataverse bot GUID.
.PARAMETER AgentName       Display name (used as folder name under sample/).
.PARAMETER SolutionName    Name for the distribution solution created in the source env.
.PARAMETER PublisherName   Publisher unique name OR customization prefix for that solution.
.PARAMETER OutputDir       Root folder for output. Defaults to the repo root.
.PARAMETER AuthIndex       pac auth index for the source environment.
.PARAMETER PacExe          Path to pac.exe. Auto-detected if not specified.

.EXAMPLE
    .\export.ps1 -SourceOrgUrl "https://myorg.crm.dynamics.com" -BotId "xxxx-..." `
                 -AgentName "My Agent" -SolutionName "MyAgentSample" -PublisherName "myprefix"
#>
param(
    [Parameter(Mandatory)][string] $SourceOrgUrl,
    [string] $BotId     = "",
    [Parameter(Mandatory)][string] $AgentName,
    [Parameter(Mandatory)][string] $SolutionName,
    [Parameter(Mandatory)][string] $PublisherName,
    [string] $OutputDir = "",
    [int]    $AuthIndex = 1,
    [string] $PacExe    = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot   = Split-Path $ScriptDir -Parent
$OutputDir  = if ($OutputDir) { $OutputDir } else { $RepoRoot }
$OutputDir  = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
$OrgNoTrail = $SourceOrgUrl.TrimEnd("/")

if (-not $PacExe) {
    $PacExe = (Get-Command "pac" -ErrorAction SilentlyContinue)?.Source
    if (-not $PacExe) {
        $PacExe = Get-ChildItem "$env:USERPROFILE\.nuget\packages\microsoft.powerapps.cli" -Filter "pac.exe" -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $PacExe) { Write-Error "pac CLI not found. Install: https://aka.ms/PowerPlatformCLI" }
}

function Step([string]$msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function OK([string]$msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function WARN([string]$msg) { Write-Host "    !   $msg" -ForegroundColor Yellow }
function INFO([string]$msg) { Write-Host "        $msg" -ForegroundColor DarkGray }

# Friendly preflight (see distribute/export.ps1 for rationale): clear guidance when az is missing,
# not signed in, or the environment is unreachable. Returns the access token.
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
        if (-not $signedIn) { Write-Error "You're not signed in to Azure. Run 'az login' (use the account that can access this environment), then retry." }
        Write-Error "Couldn't get access to '$OrgUrl'. Check the environment URL is correct and that your signed-in account has access to that tenant/environment. (az said: $raw)"
    }
    try {
        Invoke-RestMethod -Uri "$OrgUrl/api/data/v9.2/WhoAmI" -Headers @{ Authorization="Bearer $tok"; Accept="application/json" } -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Couldn't reach the environment at '$OrgUrl'. Check the URL is your Dataverse org URL (like https://yourorg.crm.dynamics.com) and that your account has access. ($($_.Exception.Message))"
    }
    return $tok
}

# Resolve a modern (cliagent-*) agent's BotId from its display name (see distribute/export.ps1).
function Resolve-BotIdByName {
    param([string]$Name, [string]$OrgUrl, [hashtable]$Headers)
    $enc = [uri]::EscapeDataString($Name)
    $found = @((Invoke-RestMethod -Uri "$OrgUrl/api/data/v9.2/bots?`$filter=name eq '$enc'&`$select=botid,name,template,modifiedon" -Headers $Headers).value | Where-Object { $_.template -like "cliagent-*" })
    if ($found.Count -eq 1) { return $found[0].botid }
    if ($found.Count -eq 0) {
        $all = @((Invoke-RestMethod -Uri "$OrgUrl/api/data/v9.2/bots?`$select=name,template&`$orderby=name" -Headers $Headers).value | Where-Object { $_.template -like "cliagent-*" })
        Write-Host "  No modern agent named '$Name'. Available modern agents:" -ForegroundColor Yellow
        $all | ForEach-Object { Write-Host "    - $($_.name)" -ForegroundColor White }
        Write-Error "Agent '$Name' not found. Use an exact name above, or pass -BotId."
    }
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-Host "  Multiple modern agents named '$Name'. Choose one:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $found.Count; $i++) {
            Write-Host ("    [{0}] {1}  (id {2}, modified {3})" -f ($i+1), $found[$i].name, $found[$i].botid, $found[$i].modifiedon) -ForegroundColor White
        }
        $pick = Read-Host "  Enter number (1-$($found.Count))"
        $idx = 0
        if ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $found.Count) { return $found[$idx-1].botid }
        Write-Error "Invalid selection."
    }
    Write-Host "  Multiple modern agents named '$Name'. Pass one of these with -BotId:" -ForegroundColor Yellow
    $found | ForEach-Object { Write-Host "    $($_.botid)" -ForegroundColor White }
    Write-Error "Ambiguous agent name '$Name'. Re-run with -BotId."
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Modern Agent Export -- Develop (edit) Path" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Source : $OrgNoTrail"
Write-Host "  Agent  : $AgentName"
Write-Host ""

# ── Acquire DV token ──────────────────────────────────────────────────────────
Step "Acquiring Dataverse token"
$token = Get-DvToken -OrgUrl $OrgNoTrail
$dv = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json" }
OK "Token acquired"

# Resolve agent by name if no id was given (the develop path already takes -AgentName as the folder).
if (-not $BotId) {
    Step "Finding agent '$AgentName' by name"
    $BotId = Resolve-BotIdByName -Name $AgentName -OrgUrl $OrgNoTrail -Headers $dv
    OK "Resolved to BotId $BotId"
}

# ── Step 1: Validate Modern agent ─────────────────────────────────────────────
Step "Step 1 -- Validate Modern Copilot Studio agent (cliagent-* template)"
$bot = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots($BotId)?`$select=botid,name,schemaname,template,configuration" -Headers $dv
$cfg = if ($bot.configuration) { $bot.configuration | ConvertFrom-Json } else { $null }
if ($bot.template -notlike "cliagent-*") {
    Write-Error "template='$($bot.template)' -- expected 'cliagent-*'. Classic agents (default-2.x.x) use a different workflow; this toolkit is for cliagent-* agents only."
}
if (-not $cfg) { WARN "This agent has no saved configuration yet (never configured/published) -- instructions/model won't be captured." }
elseif (-not $cfg.agentSettings) { WARN "bot.configuration has no 'agentSettings' block -- this agent may be Classic despite the template value." }
OK "$($bot.name) ($($bot.schemaname)) -- template: $($bot.template)"

# ── Step 2: pac copilot clone → editable YAML (for reading / diffing / git) ───
Step "Step 2 -- pac copilot clone (editable YAML for inspection + version control)"
& $PacExe auth select --index $AuthIndex | Out-Null
$sampleDir = Join-Path $OutputDir "sample"
$agentDir  = Join-Path $sampleDir $AgentName
if (Test-Path $agentDir) { Remove-Item $agentDir -Recurse -Force }
& $PacExe copilot clone --environment $OrgNoTrail --bot $BotId --display-name $AgentName --output-dir $sampleDir 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { Write-Error "pac copilot clone failed" }
$yamlCount = (Get-ChildItem $agentDir -Filter "*.mcs.yml" -Recurse).Count
OK "$yamlCount YAML files cloned to: sample\$AgentName\"

# ── Step 3: Build the deployable bundle (reliable solution-based export) ──────
Step "Step 3 -- Build deployable bundle (solution export -- the same reliable path as distribute/)"
INFO "This is what install.ps1 deploys. It captures ALL components (tools, skills, flows, knowledge)."
$distExport = Join-Path (Split-Path $ScriptDir -Parent) "distribute\export.ps1"
& $distExport -SourceOrgUrl $OrgNoTrail -BotId $BotId -SolutionName $SolutionName -PublisherName $PublisherName -OutputDir $OutputDir -AuthIndex $AuthIndex -PacExe $PacExe
if ($LASTEXITCODE -ne 0) { Write-Error "Bundle export failed" }
$bundleZip = Join-Path $OutputDir ("$($bot.name -replace '[^\w\-]','-')-bundle.zip")
if (-not (Test-Path $bundleZip)) { Write-Error "Expected bundle not found: $bundleZip" }
OK "Deployable bundle: $(Split-Path $bundleZip -Leaf)"

# ── Step 4: Surface editable instructions (the deployable edit surface) ───────
Step "Step 4 -- Surface editable instructions + model config"
if ($cfg) {
    # agent-config.json (full bot.configuration) is the authoritative, deployable edit surface.
    $configPath = Join-Path $sampleDir "agent-config.json"
    $bot.configuration | Set-Content $configPath -Encoding UTF8
    OK "agent-config.json saved (model + AI settings + instructions -- deployable)"

    # Also write instructions as a friendly Markdown file for easy editing.
    $instrPath = Join-Path $sampleDir "$AgentName.instructions.md"
    $instrText = ($cfg.agentSettings.instructions.segments | Where-Object { $_.value } | ForEach-Object { $_.value }) -join "`n`n"
    @"
<!-- Edit this file to change the agent's instructions, then run develop/install.ps1. -->
<!-- These instructions ARE deployed (via a Dataverse bot.configuration update). -->
<!-- Model: $($cfg.agentSettings.model.series)  |  Agent: $AgentName -->

$instrText
"@ | Set-Content $instrPath -Encoding UTF8
    OK "$AgentName.instructions.md saved ($($instrText.Length) chars -- edit this to change behaviour)"
} else {
    WARN "No saved configuration -- skipping agent-config.json and instructions.md (nothing to edit yet)."
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Export Complete" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Editable YAML : sample\$AgentName\   ($yamlCount files -- read / diff / review)"
Write-Host "  Instructions  : sample\$AgentName.instructions.md   (edit -> deploys)"
Write-Host "  Model/AI cfg  : sample\agent-config.json            (edit -> deploys)"
Write-Host "  Deploy bundle : $(Split-Path $bundleZip -Leaf)"
Write-Host ""
Write-Host "  WHAT YOU CAN EDIT IN VS CODE AND DEPLOY:" -ForegroundColor Cyan
Write-Host "    [deploys] instructions ($AgentName.instructions.md), model + AI settings (agent-config.json),"
Write-Host "              inline-skill content + tool/skill/knowledge descriptions (sample\$AgentName\translations\*)"
Write-Host "    [CS UI]   add/remove tools, connectors, flows; ZIP-packaged code skills; file knowledge" -ForegroundColor Yellow
Write-Host "              -> make those changes in Copilot Studio, then re-run this export." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Deploy with:"
Write-Host "    .\develop\install.ps1 -BundleZip '$bundleZip' -TargetOrgUrl <url>" -ForegroundColor Cyan
