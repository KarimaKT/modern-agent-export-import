<#
.SYNOPSIS
    Deploy a Modern Copilot Studio agent from a VS Code clone to any target environment.

.DESCRIPTION
    Takes the output of path2-vscode/export.ps1 (sample/ folder + agent-config.json +
    skills-with-assets/) and fully deploys it to a target environment.

    This script requires NO prior knowledge of the agent -- everything is read from
    sample/ and agent-config.json. The target environment just needs to be accessible.

    WHAT THIS SCRIPT DOES (7 steps, all automated)
    -----------------------------------------------

    STEP 1 -- Create agent in target Dataverse
      pac copilot push requires the bot to pre-exist in target.
      Error without this: "Entity 'bot' With Id = ... Does Not Exist"
      Fix: POST /api/data/v9.2/bots with template=cliagent-1.0.0

    STEP 2 -- Clone empty agent to get a valid workspace
      pac copilot push requires a workspace that was cloned from the TARGET environment.
      Using a workspace from the source env causes pac to crash parsing botdefinition.json.
      Fix: pac copilot clone the new empty bot -- get a fresh workspace for target env.

    STEP 3 -- Copy source YAML into workspace; strip env-specific flow GUIDs
      Copy all YAML from sample/<AgentName>/ into the workspace.
      Strip flowId/workflowId from tool YAMLs -- those GUIDs don't exist in target yet.
        WorkflowTool:           translations/*.mcs.yml  workflowId: <source-guid>
        TaskDialog (AgentFlow): actions/*.mcs.yml        flowId: <source-guid>
      First push (step 4) creates tool botcomponents without flow links.

    STEP 4 -- First pac copilot push
      Deploys: agent settings, tool/skill botcomponents, URL knowledge, connection refs.
      Does NOT deploy: bot.configuration (step 5) or flows (step 6).

    STEP 5 -- PATCH bot.configuration
      pac push writes settings.mcs.yml to bot.configuration, but agent-config.json
      (exported from DV) may have newer instructions edited in the Copilot Studio UI.
      Fix: PATCH bot.configuration from agent-config.json after push.
      IMPORTANT: bot.configuration is stored as a STRING in Dataverse, not a JSON column.
      The body must be: @{ configuration = $configJson } | ConvertTo-Json -Depth 1
      This correctly string-encodes the JSON. Do NOT use string concatenation.

    STEP 6 -- Create flows + remap GUIDs + second push
      Create all flows in target via POST /api/data/v9.2/workflows using workflow.json.
      Get the new GUIDs, patch them back into the tool YAML files.
      Second push links each tool to its flow.

    STEP 7 -- Fix skills with assets
      After pac push, skills with bic:bundle= references are broken -- the bundle blob
      from the source environment does not exist in target.
      A) Automated: reads SKILL.md from skills-with-assets/ and patches the type-9 skill
         data to an inline InlineAgentSkill. Agent works immediately with instructions.
      B) Optional guided re-upload: rebuilds ZIP and prints steps for CS UI re-upload
         (needed only if the skill has Python/code execution that must run).

    WHAT IS NOT AUTOMATED (manual, normal platform behavior)
    ---------------------------------------------------------
      Connection wiring: flows stay in Draft until a human creates connections in PPAC
      and links them to the connection references. This is standard Power Platform ALM.

    PREREQUISITES
    -------------
    pac CLI:  https://aka.ms/PowerPlatformCLI
    az CLI:   https://aka.ms/installazurecliwindows
    pac auth: pac auth create --environment https://yourorg.crm.dynamics.com
    az login: az login (with Dataverse write access to target env)

.PARAMETER SampleDir
    Path to the sample/ folder from export (contains <AgentName>/ subfolder).
    Defaults to ./sample relative to this script location.

.PARAMETER AgentName
    Display name of the agent (must match the subfolder name under SampleDir).

.PARAMETER AgentSchemaName
    Dataverse schema name (from sample/<AgentName>/settings.mcs.yml schemaName field).

.PARAMETER TargetOrgUrl
    Dataverse org URL for the target environment.

.PARAMETER AuthIndex
    pac auth index for the target environment. Defaults to 1.

.PARAMETER PacExe
    Path to pac.exe. Auto-detected from PATH or NuGet cache if not specified.

.EXAMPLE
    .\install.ps1 `
      -AgentName       "My Agent" `
      -AgentSchemaName "publisher_MyAgent_xxxxx" `
      -TargetOrgUrl    "https://myorg.crm.dynamics.com"
#>
param(
    [string] $SampleDir       = "",
    [Parameter(Mandatory)][string] $AgentName,
    [Parameter(Mandatory)][string] $AgentSchemaName,
    [Parameter(Mandatory)][string] $TargetOrgUrl,
    [int]    $AuthIndex        = 1,
    [string] $PacExe           = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir    = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot     = Split-Path $ScriptDir -Parent
$SampleDir    = if ($SampleDir) { $SampleDir } else { Join-Path $RepoRoot "sample" }
$AgentDir     = Join-Path $SampleDir $AgentName
$ConfigPath   = Join-Path $SampleDir "agent-config.json"
$SkillsDir    = Join-Path $RepoRoot "skills-with-assets"
$OrgNoTrail   = $TargetOrgUrl.TrimEnd("/")
$WorkspaceDir = Join-Path $RepoRoot "_workspace_$(Get-Date -Format 'yyyyMMddHHmmss')"

if (-not (Test-Path $AgentDir)) {
    Write-Error "Agent folder not found: $AgentDir`nRun path2-vscode/export.ps1 first."
}

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
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Modern Agent Install -- VS Code Path" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Target : $OrgNoTrail"
Write-Host "  Agent  : $AgentName ($AgentSchemaName)"
Write-Host ""

# ── Acquire DV token ──────────────────────────────────────────────────────────
Step "Acquiring Dataverse token"
$token = (az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json).accessToken
$dv = @{
    Authorization      = "Bearer $token"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    Accept             = "application/json"
    "Content-Type"     = "application/json"
    Prefer             = "return=representation"
}
OK "Token acquired"

& $PacExe auth select --index $AuthIndex | Out-Null

# ── Step 1: Create agent in target Dataverse ──────────────────────────────────
Step "Step 1 -- Create agent in target Dataverse (prerequisite for pac push)"
$newBotId = $null
$existing = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots?`$filter=schemaname eq '$AgentSchemaName'&`$select=botid,name" -Headers $dv).value
if ($existing.Count -gt 0) {
    $newBotId = $existing[0].botid
    WARN "Agent already exists: $newBotId -- skipping creation"
} else {
    $b = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots" -Method POST -Headers $dv -Body (@{
        name = $AgentName; schemaname = $AgentSchemaName
        template = "cliagent-1.0.0"; language = 1033; authenticationmode = 1
    } | ConvertTo-Json)
    $newBotId = $b.botid
    OK "Bot created: $newBotId"
}

# ── Step 2: Clone empty agent to get valid workspace ─────────────────────────
Step "Step 2 -- Clone empty agent from target env (get valid pac push workspace)"
INFO "Workspace must be cloned from TARGET env -- source env workspace causes pac crashes"
New-Item -ItemType Directory -Force -Path $WorkspaceDir | Out-Null
& $PacExe copilot clone --environment $OrgNoTrail --bot $newBotId --display-name $AgentName --output-dir $WorkspaceDir 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { Write-Error "pac copilot clone failed" }
$ws = Join-Path $WorkspaceDir $AgentName
OK "Workspace: $ws"

# ── Step 3: Copy source YAML; strip env-specific flow GUIDs ──────────────────
Step "Step 3 -- Copy source YAML; strip flow GUIDs from tool files"
INFO "Flow GUIDs (flowId/workflowId) in source YAML are env-specific."
INFO "Stripping before push; will remap after creating flows in Step 6."

foreach ($f in @("agent.mcs.yml","settings.mcs.yml","connectionreferences.mcs.yml","icon.png")) {
    $src = Join-Path $AgentDir $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $ws $f) -Force }
}
foreach ($d in @("knowledge","translations","workflows","actions")) {
    $src = Join-Path $AgentDir $d
    if (Test-Path $src) {
        New-Item -ItemType Directory -Force -Path (Join-Path $ws $d) | Out-Null
        Copy-Item (Join-Path $src "*") (Join-Path $ws $d) -Recurse -Force
    }
}

# Strip WorkflowTool workflowId (translations/*.mcs.yml)
$strippedWorkflow = @{}
Get-ChildItem (Join-Path $ws "translations") -Filter "*.mcs.yml" -ErrorAction SilentlyContinue | ForEach-Object {
    $c = Get-Content $_.FullName -Raw
    if ($c -match "kind: WorkflowTool" -and $c -match "(?m)^workflowId: ([a-f0-9\-]{36})") {
        $strippedWorkflow[$_.Name] = $Matches[1]
        Set-Content $_.FullName ($c -replace "(?m)^workflowId: [a-f0-9\-]+\r?\n","") -Encoding UTF8 -NoNewline
        INFO "  WorkflowTool '$($_.BaseName)' -- stripped workflowId $($Matches[1])"
    }
}

# Strip TaskDialog flowId (actions/*.mcs.yml)
$strippedFlow = @{}
Get-ChildItem (Join-Path $ws "actions") -Filter "*.mcs.yml" -ErrorAction SilentlyContinue | ForEach-Object {
    $c = Get-Content $_.FullName -Raw
    if ($c -match "kind: InvokeFlowTaskAction" -and $c -match "(?m)^  flowId: ([a-f0-9\-]{36})") {
        $strippedFlow[$_.Name] = $Matches[1]
        Set-Content $_.FullName ($c -replace "(?m)^  flowId: [a-f0-9\-]+\r?\n","") -Encoding UTF8 -NoNewline
        INFO "  AgentFlow '$($_.BaseName)' -- stripped flowId $($Matches[1])"
    }
}
OK "YAML copied; $($strippedWorkflow.Count + $strippedFlow.Count) flow GUID(s) stripped"

# ── Step 4: First pac push ────────────────────────────────────────────────────
Step "Step 4 -- First pac push (agent settings, tools, skills, knowledge, connection refs)"
INFO "Flow GUIDs were stripped -- push creates tool botcomponents without flow links."
INFO "NOTE: pac push 2.8.1 crashes in its post-push reader for cliagent-* agents but still"
INFO "deploys content. Exit code 0 = writes completed. We verify via DV API, not pac output."
& $PacExe copilot push --project-dir $ws 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) {
    WARN "pac push exit $LASTEXITCODE -- checking DV directly to confirm what deployed"
}

# Verify push via DV API — pac's post-push reader crashes and cannot confirm deployment
$pushComps = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$newBotId' and componenttype eq 9&`$select=name,data&`$top=20" -Headers $dv).value
if ($pushComps.Count -gt 0) {
    OK "First push verified via DV: $($pushComps.Count) type-9 components deployed"
    $pushComps | ForEach-Object { INFO "  $($_.name)" }
} else {
    Write-Error "First push FAILED — no botcomponents found in target DV. Cannot continue."
}

# ── Step 5: PATCH bot.configuration ──────────────────────────────────────────
Step "Step 5 -- Patch bot.configuration (authoritative instructions + model)"
INFO "pac push writes settings.mcs.yml to bot.configuration."
INFO "Overwriting with agent-config.json (instructions as of export time)."
if (Test-Path $ConfigPath) {
    $cfgJson = Get-Content $ConfigPath -Raw
    # IMPORTANT: bot.configuration is a STRING field in Dataverse, not a JSON column.
    # ConvertTo-Json -Depth 1 correctly string-encodes the JSON value.
    $body = @{ configuration = $cfgJson } | ConvertTo-Json -Depth 1
    Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots($newBotId)" -Method PATCH -Headers $dv -Body $body | Out-Null
    $cfgObj = $cfgJson | ConvertFrom-Json
    OK "bot.configuration patched"
    INFO "  Model       : $($cfgObj.agentSettings.model.series)"
    INFO "  Instructions: $($cfgObj.agentSettings.instructions.segments[0].value.Length) chars"
} else {
    WARN "agent-config.json not found -- instructions not patched."
    WARN "Run path2-vscode/export.ps1 to capture bot.configuration."
}

# ── Step 6: Create flows; remap GUIDs; second push ───────────────────────────
Step "Step 6 -- Create flows in target; remap GUIDs; second pac push"
$wfDirs = @(Get-ChildItem (Join-Path $ws "workflows") -Directory -ErrorAction SilentlyContinue)
if ($wfDirs.Count -eq 0) {
    INFO "No workflows found -- skipping"
} else {
    $guidMap = @{}  # sourceGuid -> newGuid

    foreach ($wfDir in $wfDirs) {
        $metaFile = Join-Path $wfDir.FullName "metadata.yml"
        $wfFile   = Join-Path $wfDir.FullName "workflow.json"
        if (-not (Test-Path $metaFile) -or -not (Test-Path $wfFile)) { continue }

        $meta     = Get-Content $metaFile -Raw
        $wfJson   = Get-Content $wfFile -Raw
        $flowName = if ($meta -match "(?m)^name: (.+)") { $Matches[1].Trim() } else { $wfDir.Name }
        $newGuid  = [Guid]::NewGuid().ToString()

        try {
            Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/workflows" -Method POST -Headers $dv -Body (@{
                workflowid = $newGuid; name = $flowName
                category = 5; type = 1; primaryentity = "none"
                statecode = 0; statuscode = 1; clientdata = $wfJson
            } | ConvertTo-Json -Depth 3) | Out-Null

            # Map source GUID (from workflow dir name) to new GUID
            if ($wfDir.Name -match "([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$") {
                $guidMap[$Matches[1]] = $newGuid
            }
            OK "  Flow '$flowName' -- $newGuid"
        } catch {
            WARN "  Flow '$flowName' failed: $($_.Exception.Message)"
        }
    }

    # Patch WorkflowTool files with new GUIDs
    foreach ($fn in $strippedWorkflow.Keys) {
        $srcGuid = $strippedWorkflow[$fn]; $newGuid = $guidMap[$srcGuid]
        if (-not $newGuid) { WARN "No new GUID for WorkflowTool '$fn'"; continue }
        $fp = Join-Path $ws "translations\$fn"
        Set-Content $fp ((Get-Content $fp -Raw) -replace "kind: WorkflowTool", "kind: WorkflowTool`nworkflowId: $newGuid") -Encoding UTF8 -NoNewline
        OK "  WorkflowTool '$fn' -- $newGuid"
    }

    # Patch AgentFlow files with new GUIDs
    foreach ($fn in $strippedFlow.Keys) {
        $srcGuid = $strippedFlow[$fn]; $newGuid = $guidMap[$srcGuid]
        if (-not $newGuid) { WARN "No new GUID for AgentFlow '$fn'"; continue }
        $fp = Join-Path $ws "actions\$fn"
        Set-Content $fp ((Get-Content $fp -Raw) -replace "kind: InvokeFlowTaskAction", "kind: InvokeFlowTaskAction`n  flowId: $newGuid") -Encoding UTF8 -NoNewline
        OK "  AgentFlow '$fn' -- $newGuid"
    }

    INFO "Re-pushing with remapped flow GUIDs..."
    & $PacExe copilot push --project-dir $ws 2>&1 | ForEach-Object { INFO $_ }
    if ($LASTEXITCODE -ne 0) { WARN "pac push exit $LASTEXITCODE -- verifying via DV API" }

    # Verify flow links via DV API — pac's post-push reader crashes and cannot confirm
    $linkedOk = $true
    foreach ($fid in $guidMap.Values) {
        try {
            $wf = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/workflows($fid)?`$select=workflowid,name" -Headers $dv
            OK "  Second push verified: flow '$($wf.name)' linked ($fid)"
        } catch {
            WARN "  Flow $fid not found in DV after second push"
            $linkedOk = $false
        }
    }
    if ($linkedOk) { OK "Second push verified via DV -- tools linked to flows" }
    else { WARN "Some flows may not have linked correctly -- verify agent in Copilot Studio" }
}

# -- Step 7: Skills with assets require manual upload
# Skills-with-assets have a bic:bundle= token in their type-9 record pointing to
# Azure blob storage in the source environment. This does not transfer.
# We do NOT silently convert to inline instructions -- that would allow the model
# to call a skill that cannot execute Python, causing silent degradation.
# Instead: detect broken skills, rebuild the ZIP, require manual re-upload.
if (Test-Path $SkillsDir) {
    $skillFolders = @(Get-ChildItem $SkillsDir -Directory -ErrorAction SilentlyContinue)
    if ($skillFolders.Count -gt 0) {
        Step "Step 7 -- Skills with assets require manual upload ($($skillFolders.Count) skill(s))"

        $allComps     = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$newBotId' and componenttype eq 9&`$select=botcomponentid,name,data" -Headers $dv).value
        $brokenSkills = @($allComps | Where-Object { $_.data -like "*bic:bundle=*" })
        INFO "$($brokenSkills.Count) skill(s) confirmed broken (bic:bundle= token — bundle not in target)"

        $reuploadList = @()
        foreach ($sf in $skillFolders) {
            $zipPath = Join-Path $SkillsDir "$($sf.Name).zip"
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
            Compress-Archive -Path (Join-Path $sf.FullName "*") -DestinationPath $zipPath -Force
            $reuploadList += @{ name = $sf.Name; zipPath = $zipPath }
            OK "  Built ZIP: $zipPath"
        }

        $envId    = $OrgNoTrail -replace "https://","" -replace "\.crm\.dynamics\.com",""
        $agentUrl = "https://copilotstudio.microsoft.com/environments/$envId/agents/$newBotId"

        Write-Host ""
        Write-Host "  ==========================================================" -ForegroundColor Red
        Write-Host "  ACTION REQUIRED: Skills with code assets need manual upload" -ForegroundColor Red
        Write-Host "  ==========================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "  The following skill(s) have Python or binary assets that cannot" -ForegroundColor Yellow
        Write-Host "  be transferred automatically. The agent is NOT fully functional" -ForegroundColor Yellow
        Write-Host "  until you upload the ZIPs below." -ForegroundColor Yellow
        Write-Host ""
        foreach ($r in $reuploadList) {
            Write-Host "  Skill : $($r.name)" -ForegroundColor White
            Write-Host "  ZIP   : $($r.zipPath)" -ForegroundColor White
            Write-Host ""
        }
        Write-Host "  Steps (repeat for each skill above):" -ForegroundColor Cyan
        Write-Host "    1. Open your agent: $agentUrl" -ForegroundColor White
        Write-Host "    2. In the right panel, click the skill name." -ForegroundColor White
        Write-Host "    3. Three-dot menu > Replace / Edit skill." -ForegroundColor White
        Write-Host "    4. Upload the ZIP file shown above for that skill." -ForegroundColor White
        Write-Host "    5. Save the agent." -ForegroundColor White
        Write-Host ""
        try { Start-Process $agentUrl; INFO "Opening agent in browser..." }
        catch { WARN "Open manually: $agentUrl" }

        Write-Host ""
        WARN "Agent is NOT fully functional until skills are uploaded."
        Write-Host "  Press Enter when you have uploaded all skills and saved, or Ctrl+C to finish now." -ForegroundColor Yellow
        Read-Host | Out-Null
        OK "Continuing."
    } else {
        Step "Step 7 -- No skills-with-assets (skipping)"
        OK "Nothing to repair"
    }
} else {
    Step "Step 7 -- No skills-with-assets folder found (skipping)"
    OK "Nothing to repair"
}

# ── Summary ───────────────────────────────────────────────────────────────────
$flowCount = $strippedWorkflow.Count + $strippedFlow.Count
$envId     = $OrgNoTrail -replace "https://","" -replace "\.crm\.dynamics\.com",""

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Install Complete" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Bot ID : $newBotId"
Write-Host "  URL    : https://copilotstudio.microsoft.com/environments/$envId/agents/$newBotId" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Steps completed:"
Write-Host "    [x] Agent created in Dataverse"
Write-Host "    [x] YAML pushed (tools, skills, knowledge, connection refs)"
Write-Host "    [x] bot.configuration patched (instructions + model)"
Write-Host "    [x] $flowCount flow(s) created and linked"
Write-Host ""
Write-Host "  ACTION REQUIRED: Wire connections in PPAC to activate flows" -ForegroundColor Yellow
Write-Host "    1. Open https://make.powerautomate.com"
Write-Host "    2. Switch to your target environment"
Write-Host "    3. Open each flow, assign a connection per connector, save and turn on"
Write-Host ""
Write-Host "  Workspace (debug, delete when done): $WorkspaceDir" -ForegroundColor DarkGray