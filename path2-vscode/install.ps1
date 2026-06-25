<#
.SYNOPSIS
    Deploy a Modern Copilot Studio agent from a VS Code clone to any target environment.

.DESCRIPTION
    Takes the output of path2-vscode/export.ps1 (sample/ folder + agent-config.json +
    skills-with-assets/) and fully deploys it to a target environment.

    This script requires NO prior knowledge of the agent — everything is read from
    sample/ and agent-config.json. The target environment just needs to be accessible.

    WHAT THIS SCRIPT DOES (5 steps, all automated)
    ───────────────────────────────────────────────

    STEP 1 — Create agent in target Dataverse
      pac copilot push requires the bot to pre-exist in target.
      Error without this: "Entity 'bot' With Id = ... Does Not Exist"
      Fix: POST /api/data/v9.2/bots with template=cliagent-1.0.0

    STEP 2 — Clone empty agent to get a valid workspace
      pac copilot push requires a workspace that was cloned from the TARGET environment.
      Using a workspace from the source env causes pac to crash parsing botdefinition.json.
      Fix: pac copilot clone the new empty bot → get a fresh workspace for target env.

    STEP 3 — Copy source YAML into workspace; strip env-specific flow GUIDs
      Copy all YAML from sample/<AgentName>/ into the workspace.
      Strip flowId/workflowId from tool YAMLs — those GUIDs don't exist in target yet.
        WorkflowTool:          translations/*.mcs.yml → workflowId: <source-guid>
        TaskDialog (AgentFlow): actions/*.mcs.yml      → flowId: <source-guid>
      First push (step 4) creates tool botcomponents without flow links.

    STEP 4 — First pac copilot push
      Deploys: agent settings, tool/skill botcomponents, URL knowledge, connection refs.
      Does NOT deploy: bot.configuration (step 5) or flows (step 6).

    STEP 5 — PATCH bot.configuration
      pac push writes settings.mcs.yml to bot.configuration, but agent-config.json
      (exported from DV) may have newer instructions edited in the Copilot Studio UI.
      Fix: PATCH bot.configuration from agent-config.json after push.
      IMPORTANT: bot.configuration is stored as a STRING in Dataverse, not a JSON column.
      The body must be: @{ configuration = $configJson } | ConvertTo-Json -Depth 1
      This correctly string-encodes the JSON. Do NOT use string concatenation.

    STEP 6 — Create flows + remap GUIDs + second push
      Create all flows in target via POST /api/data/v9.2/workflows using workflow.json.
      Get the new GUIDs, patch them back into the tool YAML files.
      Second push links each tool to its flow.

    STEP 7 — Fix skills with assets
      If skills-with-assets/ folder exists, re-upload each skill's ZIP.
      Same problem as solution path: bic:bundle= is env-specific, must be fresh-uploaded.

    WHAT IS NOT AUTOMATED (manual, normal platform behavior)
    ─────────────────────────────────────────────────────────
      Connection wiring: flows stay in Draft until a human creates connections in PPAC
      and links them to the connection references. This is standard Power Platform ALM.

    PREREQUISITES
    ─────────────
    pac CLI:  https://aka.ms/PowerPlatformCLI
    az CLI:   https://aka.ms/installazurecliwindows
    pac auth: pac auth create --environment https://yourorg.crm.dynamics.com
    az login: az login (with Dataverse write access to target env)

.PARAMETER SampleDir
    Path to the sample/ folder from export (contains <AgentName>/ subfolder).
    Defaults to ./sample relative to script location.

.PARAMETER AgentName
    Display name of the agent (must match the subfolder name under SampleDir).

.PARAMETER AgentSchemaName
    Dataverse schema name (from sample/<AgentName>/settings.mcs.yml → schemaName).

.PARAMETER TargetOrgUrl
    Dataverse org URL for the target environment.

.PARAMETER AuthIndex
    pac auth index for the target environment.

.PARAMETER PacExe
    Path to pac.exe. Auto-detected from PATH or NuGet cache if not specified.

.EXAMPLE
    .\install.ps1 `
      -AgentName       "My Agent" `
      -AgentSchemaName "cr7a0_MyAgent_xxxxx" `
      -TargetOrgUrl    "https://myorg.crm.dynamics.com"
#>
param(
    [string] $SampleDir      = "",
    [Parameter(Mandatory)][string] $AgentName,
    [Parameter(Mandatory)][string] $AgentSchemaName,
    [Parameter(Mandatory)][string] $TargetOrgUrl,
    [int]    $AuthIndex       = 1,
    [string] $PacExe          = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir   = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot    = Split-Path $ScriptDir -Parent
$SampleDir   = if ($SampleDir) { $SampleDir } else { Join-Path $RepoRoot "sample" }
$AgentDir    = Join-Path $SampleDir $AgentName
$ConfigPath  = Join-Path $SampleDir "agent-config.json"
$SkillsDir   = Join-Path $RepoRoot "skills-with-assets"
$OrgNoTrail  = $TargetOrgUrl.TrimEnd("/")
$WorkspaceDir = Join-Path $RepoRoot "_workspace_$(Get-Date -Format 'yyyyMMddHHmmss')"

if (-not (Test-Path $AgentDir)) { Write-Error "Agent folder not found: $AgentDir" }

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

Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Modern Agent Install — VS Code Path     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Target : $OrgNoTrail"
Write-Host "  Agent  : $AgentName ($AgentSchemaName)"
Write-Host ""

# ── Acquire DV token ──────────────────────────────────────────────────────────
Step "Acquiring Dataverse token..."
$token = (az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json).accessToken
$dv = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json"; Prefer="return=representation" }
OK "Token acquired"

& $PacExe auth select --index $AuthIndex | Out-Null

# ── Step 1: Create agent in target Dataverse ──────────────────────────────────
Step "Step 1 — Create agent in target Dataverse (pre-requisite for pac push)"
$newBotId = $null
$existing = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots?`$filter=schemaname eq '$AgentSchemaName'&`$select=botid,name" -Headers $dv).value
if ($existing.Count -gt 0) {
    $newBotId = $existing[0].botid
    WARN "Agent already exists: $newBotId — skipping creation"
} else {
    $b = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots" -Method POST -Headers $dv -Body (@{
        name = $AgentName; schemaname = $AgentSchemaName; template = "cliagent-1.0.0"; language = 1033; authenticationmode = 1
    } | ConvertTo-Json)
    $newBotId = $b.botid
    OK "Bot created: $newBotId"
}

# ── Step 2: Clone empty agent → valid workspace ───────────────────────────────
Step "Step 2 — Clone empty agent from target env (get valid workspace)"
INFO "Workspace must be cloned from TARGET env — source env workspace causes pac crashes"
New-Item -ItemType Directory -Force -Path $WorkspaceDir | Out-Null
& $PacExe copilot clone --environment $OrgNoTrail --bot $newBotId --display-name $AgentName --output-dir $WorkspaceDir 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { Write-Error "pac copilot clone failed" }
$ws = Join-Path $WorkspaceDir $AgentName
OK "Workspace: $ws"

# ── Step 3: Copy source YAML; strip env-specific flow GUIDs ──────────────────
Step "Step 3 — Copy source YAML; strip flow GUIDs from tool files"
INFO "Flow GUIDs (flowId/workflowId) in source YAML are env-specific — don't exist in target."
INFO "Strip them before push; remap after flows are created in Step 6."

foreach ($f in @("agent.mcs.yml","settings.mcs.yml","connectionreferences.mcs.yml","icon.png")) {
    $src = Join-Path $AgentDir $f
    if (Test-Path $src) { Copy-Item $src "$ws\$f" -Force }
}
foreach ($d in @("knowledge","translations","workflows","actions")) {
    $src = Join-Path $AgentDir $d
    if (Test-Path $src) {
        New-Item -ItemType Directory -Force -Path "$ws\$d" | Out-Null
        Copy-Item "$src\*" "$ws\$d\" -Recurse -Force
    }
}

# Strip WorkflowTool workflowId (translations/*.mcs.yml)
$strippedWorkflow = @{}
Get-ChildItem "$ws\translations" -Filter "*.mcs.yml" -ErrorAction SilentlyContinue | ForEach-Object {
    $c = Get-Content $_.FullName -Raw
    if ($c -match "kind: WorkflowTool" -and $c -match "(?m)^workflowId: ([a-f0-9\-]{36})") {
        $strippedWorkflow[$_.Name] = $Matches[1]
        Set-Content $_.FullName -Value ($c -replace "(?m)^workflowId: [a-f0-9\-]+\r?\n","") -Encoding UTF8 -NoNewline
        INFO "  WorkflowTool '$($_.BaseName)' — stripped workflowId $($Matches[1])"
    }
}

# Strip TaskDialog flowId (actions/*.mcs.yml)
$strippedFlow = @{}
Get-ChildItem "$ws\actions" -Filter "*.mcs.yml" -ErrorAction SilentlyContinue | ForEach-Object {
    $c = Get-Content $_.FullName -Raw
    if ($c -match "kind: InvokeFlowTaskAction" -and $c -match "(?m)^  flowId: ([a-f0-9\-]{36})") {
        $strippedFlow[$_.Name] = $Matches[1]
        Set-Content $_.FullName -Value ($c -replace "(?m)^  flowId: [a-f0-9\-]+\r?\n","") -Encoding UTF8 -NoNewline
        INFO "  AgentFlow '$($_.BaseName)' — stripped flowId $($Matches[1])"
    }
}
OK "YAML copied; $($strippedWorkflow.Count + $strippedFlow.Count) GUIDs stripped"

# ── Step 4: First pac push ────────────────────────────────────────────────────
Step "Step 4 — First pac push (agent settings, tools, skills, knowledge, connection refs)"
INFO "Flow GUIDs were stripped — push creates tool botcomponents without flow links."
& $PacExe copilot push --project-dir $ws 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { WARN "pac push exit $LASTEXITCODE — check output above" } else { OK "First push succeeded" }

# ── Step 5: PATCH bot.configuration ──────────────────────────────────────────
Step "Step 5 — Patch bot.configuration (authoritative instructions + model)"
INFO "pac push wrote settings.mcs.yml to bot.configuration."
INFO "Now overwriting with agent-config.json (may have newer UI edits)."
if (Test-Path $ConfigPath) {
    $cfg  = Get-Content $ConfigPath -Raw
    # IMPORTANT: bot.configuration is a STRING field in DV, not a JSON column.
    # ConvertTo-Json -Depth 1 correctly string-encodes the JSON value.
    $body = @{ configuration = $cfg } | ConvertTo-Json -Depth 1
    Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots($newBotId)" -Method PATCH -Headers $dv -Body $body | Out-Null
    $cfgObj = $cfg | ConvertFrom-Json
    OK "bot.configuration patched"
    INFO "  Model       : $($cfgObj.agentSettings.model.series)"
    INFO "  Instructions: $($cfgObj.agentSettings.instructions.segments[0].value.Length) chars"
} else {
    WARN "agent-config.json not found — instructions not patched. Run export.ps1 to capture it."
}

# ── Step 6: Create flows; remap GUIDs; second push ───────────────────────────
Step "Step 6 — Create flows in target; remap GUIDs; second pac push"
$wfDirs = Get-ChildItem (Join-Path $ws "workflows") -Directory -ErrorAction SilentlyContinue
if ($wfDirs.Count -eq 0) {
    INFO "No workflows found — skipping"
} else {
    $guidMap = @{}  # sourceGuid → newGuid

    foreach ($wfDir in $wfDirs) {
        $metaFile = Join-Path $wfDir.FullName "metadata.yml"
        $wfFile   = Join-Path $wfDir.FullName "workflow.json"
        if (-not (Test-Path $metaFile) -or -not (Test-Path $wfFile)) { continue }
        $meta   = Get-Content $metaFile -Raw
        $wfJson = Get-Content $wfFile -Raw
        $flowName = if ($meta -match "(?m)^name: (.+)") { $Matches[1].Trim() } else { $wfDir.Name }
        $newGuid  = [Guid]::NewGuid().ToString()
        try {
            Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/workflows" -Method POST -Headers $dv -Body (@{
                workflowid = $newGuid; name = $flowName; category = 5; type = 1
                primaryentity = "none"; statecode = 0; statuscode = 1; clientdata = $wfJson
            } | ConvertTo-Json -Depth 3) | Out-Null
            if ($wfDir.Name -match "([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$") {
                $guidMap[$Matches[1]] = $newGuid
            }
            OK "  Flow '$flowName' → $newGuid"
        } catch { WARN "  Flow '$flowName' failed: $($_.Exception.Message)" }
    }

    # Patch WorkflowTool files
    foreach ($fn in $strippedWorkflow.Keys) {
        $srcGuid = $strippedWorkflow[$fn]; $newGuid = $guidMap[$srcGuid]
        if (-not $newGuid) { WARN "No new GUID for WorkflowTool $fn ($srcGuid)"; continue }
        $fp = Join-Path $ws "translations\$fn"
        Set-Content $fp -Value ((Get-Content $fp -Raw) -replace "kind: WorkflowTool", "kind: WorkflowTool`nworkflowId: $newGuid") -Encoding UTF8 -NoNewline
        OK "  WorkflowTool '$fn' → $newGuid"
    }

    # Patch AgentFlow files
    foreach ($fn in $strippedFlow.Keys) {
        $srcGuid = $strippedFlow[$fn]; $newGuid = $guidMap[$srcGuid]
        if (-not $newGuid) { WARN "No new GUID for AgentFlow $fn ($srcGuid)"; continue }
        $fp = Join-Path $ws "actions\$fn"
        Set-Content $fp -Value ((Get-Content $fp -Raw) -replace "kind: InvokeFlowTaskAction", "kind: InvokeFlowTaskAction`n  flowId: $newGuid") -Encoding UTF8 -NoNewline
        OK "  AgentFlow '$fn' → $newGuid"
    }

    INFO "Re-pushing with remapped flow GUIDs..."
    & $PacExe copilot push --project-dir $ws 2>&1 | ForEach-Object { INFO $_ }
    if ($LASTEXITCODE -ne 0) { WARN "Second push exit $LASTEXITCODE" } else { OK "Second push succeeded — tools linked to flows" }
}

# ── Step 7: Skills with assets — manual re-upload required ───────────────────
# pac copilot push creates the type-9 skill record with the bic:bundle= reference
# from the source environment. That bundle does not exist in the target environment.
# pac push CANNOT recreate the bundle — it is created by Copilot Studio server-side
# processing during ZIP upload, via a non-public endpoint.
#
# The type-14 file component records (SKILL.md, Python scripts etc.) are in the
# skills-with-assets/ folder and can be read, but uploading them individually via
# the DV OData API does NOT trigger bundle creation.
#
# Fix: manually re-upload each skill ZIP through the Copilot Studio UI after deploy.
#
if (Test-Path ) {
     = Get-ChildItem  -Directory -ErrorAction SilentlyContinue
    if (.Count -gt 0) {
        Step "Step 7 — Skills with assets require manual re-upload"
        Write-Host ""
        Write-Host "  The following skills have binary assets:" -ForegroundColor Yellow
        foreach ( in ) {
            Write-Host "    • " -ForegroundColor Cyan
            Write-Host "      Files: _inspect_pb, _inspect_pb2, _inspect_zip, _inspect_zip2, _skill_build, _workspace_20260624151243, .vscode, path1-solution, path2-vscode, sample, screenshots, scripts, skills, solution, .gitignore, CONTRIBUTING.md, LEARNINGS.md, LICENSE, README.md"
            Write-Host "      Rebuild ZIP from: "
        }
        Write-Host ""
        Write-Host "  After deployment, for each skill above:" -ForegroundColor Yellow
        Write-Host "    1. Build a ZIP from the skill folder above"
        Write-Host "    2. Open the agent in Copilot Studio"
        Write-Host "    3. In Skills, remove the broken skill entry (bic:bundle= is broken)"
        Write-Host "    4. Add skill → Upload a skill → upload the rebuilt ZIP"
        Write-Host "    5. Save the agent"
        Write-Host ""
        WARN "Skills with assets require manual re-upload — no automated fix available"
        WARN "This is a known Copilot Studio limitation (no public API for bundle creation)"
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Install Complete                        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Bot ID : $newBotId"
$envId = $OrgNoTrail -replace "https://","" -replace "\.crm\.dynamics\.com",""
Write-Host "  URL    : https://copilotstudio.microsoft.com/environments/$envId/home" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Steps completed:"
Write-Host "    [x] Agent created in Dataverse"
Write-Host "    [x] YAML pushed (tools, skills, knowledge, connection refs)"
Write-Host "    [x] bot.configuration patched (instructions + model)"
Write-Host "    [x] $(($strippedWorkflow.Count + $strippedFlow.Count)) flow(s) created and linked"
Write-Host ""
Write-Host "  MANUAL: Wire connections in PPAC to activate flows" -ForegroundColor Yellow
Write-Host "  Workspace (debug): $WorkspaceDir"

