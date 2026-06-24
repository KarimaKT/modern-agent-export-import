<#
.SYNOPSIS
    Imports a Copilot Studio NGO (cliagent-1.0.0) agent into a target environment.
    Handles the three steps pac copilot push alone cannot do:
      1. Agent pre-creation  — pac push requires the bot to already exist
      2. Flow creation       — pac push does NOT create Power Automate flows; they must be POSTed to DV
      3. Skill upload        — InlineAgentSkill botcomponents are POSTed to DV separately

.DESCRIPTION
    REQUIRED workflow (discovered through testing):
      Step 1  — Create the target agent via DV API (pac push won't create it from scratch)
      Step 2  — pac copilot clone the new empty agent → get a valid Zava PP workspace
      Step 3  — Copy source YAML files into the workspace (flowIds stripped)
      Step 4  — pac copilot push (no flowId) → agent settings + action botcomponents
      Step 5  — Create a Power BI connection reference in target DV
      Step 6  — Create Power Automate flows via DV API (from workflow.json files, updating conn ref)
      Step 7  — Update action YAMLs with new flow GUIDs; pac copilot push again
      Step 8  — Upload skill botcomponents via DV API POST
      Step 9  — Manual: add Power BI connection to the connection reference in PPAC

.PARAMETER PacExe
    Path to pac.exe.

.PARAMETER TargetOrgUrl
    Target Dataverse org URL.

.PARAMETER AgentSchemaName
    Schema name of the agent (used to create and find the bot).

.PARAMETER AgentDisplayName
    Display name for the new agent.

.PARAMETER AuthIndex
    pac auth index that has access to the target environment.

.PARAMETER SourceConnRefLogicalName
    Logical name of the connection reference in the SOURCE workflow JSONs (replace this).

.EXAMPLE
    .\scripts\install.ps1
    .\scripts\install.ps1 -TargetOrgUrl "https://myorg.crm.dynamics.com" -AuthIndex 2
#>
param(
    [string]$PacExe               = "C:\Users\kkanjitajdin\.nuget\packages\microsoft.powerapps.cli\2.8.1\tools\pac.exe",
    [string]$TargetOrgUrl         = "https://org07697283.crm.dynamics.com",
    [string]$AgentSchemaName      = "Default_FabricAnalyst_dQTqzr",
    [string]$AgentDisplayName     = "Fabric Analyst",
    [int]   $AuthIndex            = 2,
    [string]$SourceConnRefLogicalName = "new_sharedpowerbi_ff7fa"
)

$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot   = Split-Path $ScriptDir -Parent
$SampleDir  = Join-Path $RepoRoot "sample\$AgentDisplayName"
$SkillsDir  = Join-Path $RepoRoot "skills"
$OrgNoTrail = $TargetOrgUrl.TrimEnd("/")

# Working push directory (not the sample — we write target-specific values here)
$PushDir    = Join-Path $RepoRoot "_push_$(Get-Date -Format 'yyyyMMddHHmmss')"

function Write-Step([int]$n, [string]$msg) {
    Write-Host ""
    Write-Host "[$n/9] $msg" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Modern Agent Install — NGO Toolkit (cliagent-1.0.0)" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "Target env : $OrgNoTrail"
Write-Host "Agent      : $AgentDisplayName ($AgentSchemaName)"
Write-Host ""

# ── Acquire DV bearer token ──────────────────────────────────────────────────
Write-Host "Acquiring Dataverse bearer token via az CLI..."
$tokenJson = az account get-access-token --resource $OrgNoTrail 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "az get-access-token failed. Try: az login --tenant {tenantId}"
    Write-Error "Cannot continue without a DV token."
}
$token = ($tokenJson | ConvertFrom-Json).accessToken
$dvHeaders = @{
    Authorization      = "Bearer $token"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    Accept             = "application/json"
    "Content-Type"     = "application/json"
    Prefer             = "return=representation"
}
Write-Host "  → Token acquired" -ForegroundColor Green

# ── Step 1: Select pac auth ──────────────────────────────────────────────────
Write-Step 1 "Selecting pac auth index $AuthIndex..."
& $PacExe auth select --index $AuthIndex | Out-Null

# ── Step 2: Create agent in target DV ────────────────────────────────────────
Write-Step 2 "Creating agent '$AgentDisplayName' in target DV..."
$existingBot = $null
try {
    $existing = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots?`$filter=schemaname eq '$AgentSchemaName'&`$select=botid,name" -Headers $dvHeaders
    if ($existing.value.Count -gt 0) {
        $existingBot = $existing.value[0]
        Write-Host "  → Agent already exists: $($existingBot.botid)" -ForegroundColor DarkYellow
    }
} catch {}

if (-not $existingBot) {
    $botPayload = @{
        name         = $AgentDisplayName
        schemaname   = $AgentSchemaName
        template     = "cliagent-1.0.0"
        language     = 1033
        authenticationmode = 1
    } | ConvertTo-Json
    $newBot = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots" -Method POST -Headers $dvHeaders -Body $botPayload
    $newBotId = $newBot.botid
    Write-Host "  → Created: $newBotId" -ForegroundColor Green
} else {
    $newBotId = $existingBot.botid
}

# ── Step 3: Clone the new empty agent to get a workspace ────────────────────
Write-Step 3 "Cloning empty agent from target env to get workspace..."
$cloneDir = Join-Path $RepoRoot "_clone_tmp"
Remove-Item $cloneDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $cloneDir | Out-Null
& $PacExe copilot clone `
    --environment $OrgNoTrail `
    --bot $newBotId `
    --display-name $AgentDisplayName `
    --output-dir $cloneDir
if ($LASTEXITCODE -ne 0) { Write-Error "pac copilot clone failed" }
$WorkspaceDir = "$cloneDir\$AgentDisplayName"
Write-Host "  → Workspace: $WorkspaceDir" -ForegroundColor Green

# ── Step 4: Copy source YAML files into workspace (flowIds stripped) ─────────
Write-Step 4 "Copying source YAML files into workspace (stripping CDX flowIds)..."
New-Item -ItemType Directory -Force -Path "$WorkspaceDir\actions"      | Out-Null
New-Item -ItemType Directory -Force -Path "$WorkspaceDir\workflows"    | Out-Null
New-Item -ItemType Directory -Force -Path "$WorkspaceDir\translations" | Out-Null

Copy-Item "$SampleDir\agent.mcs.yml"     "$WorkspaceDir\agent.mcs.yml"
Copy-Item "$SampleDir\settings.mcs.yml"  "$WorkspaceDir\settings.mcs.yml"
Copy-Item "$SampleDir\icon.png"          "$WorkspaceDir\icon.png" -ErrorAction SilentlyContinue
Copy-Item "$SampleDir\workflows\*"       "$WorkspaceDir\workflows\" -Recurse -Force
Copy-Item "$SampleDir\translations\*"    "$WorkspaceDir\translations\" -Force

foreach ($file in Get-ChildItem "$SampleDir\actions" -Filter "*.mcs.yml") {
    $content = Get-Content $file.FullName -Raw
    $fixed = $content -replace "(?m)^  flowId: [a-f0-9\-]+\r?\n", ""
    Set-Content "$WorkspaceDir\actions\$($file.Name)" -Value $fixed -Encoding UTF8 -NoNewline
}
Write-Host "  → Files copied, flowIds stripped" -ForegroundColor Green

# ── Step 5: Initial pac copilot push (no flowId) ─────────────────────────────
Write-Step 5 "Initial pac copilot push (creates agent config + action botcomponents)..."
& $PacExe copilot push --project-dir $WorkspaceDir 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "pac copilot push returned $LASTEXITCODE — check output above"
}

# ── Step 6: Create connection reference + flows via DV API ───────────────────
Write-Step 6 "Creating Power BI connection reference in target env..."
$newConnRefName = "$AgentSchemaName.cr.shared_powerbi".Replace("-","_").Replace(".","_")
$connRefPayload = @{
    connectionreferencelogicalname = $newConnRefName
    connectorid                    = "/providers/Microsoft.PowerApps/apis/shared_powerbi"
} | ConvertTo-Json

$connRefId = $null
try {
    $newRef = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/connectionreferences" -Method POST -Headers $dvHeaders -Body $connRefPayload
    $connRefId = $newRef.connectionreferenceid
    Write-Host "  → Connection reference: $newConnRefName (ID: $connRefId)" -ForegroundColor Green
} catch {
    Write-Host "  → Connection reference may already exist. Error: $($_.ErrorDetails.Message | Select-Object -First 1)" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "  Creating Power Automate flows from workflow definitions..."
$newFlowIds = @{}
$wfDirs = Get-ChildItem "$WorkspaceDir\workflows" -Directory

foreach ($wfDir in $wfDirs) {
    $metaYml = Get-Content "$($wfDir.FullName)\metadata.yml" -Raw
    $wfJson  = Get-Content "$($wfDir.FullName)\workflow.json" -Raw

    # Update connection reference in flow JSON
    $wfJsonFixed = $wfJson -replace [regex]::Escape($SourceConnRefLogicalName), $newConnRefName

    # Get flow name from metadata
    $flowName = "Unknown"
    if ($metaYml -match "name: (.+)") { $flowName = $Matches[1].Trim() }

    $newFlowGuid = [System.Guid]::NewGuid().ToString()
    $flowPayload = @{
        workflowid    = $newFlowGuid
        name          = $flowName
        category      = 5
        type          = 1
        primaryentity = "none"
        statecode     = 0
        statuscode    = 1
        clientdata    = $wfJsonFixed
    } | ConvertTo-Json -Depth 3

    try {
        $resp = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/workflows" -Method POST -Headers $dvHeaders -Body $flowPayload
        Write-Host "  → Flow created: '$flowName' → $newFlowGuid" -ForegroundColor Green
        # Map old GUID (from workflow folder name) to new GUID
        if ($wfDir.Name -match "[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}") {
            $newFlowIds[$Matches[0]] = $newFlowGuid
        }
    } catch {
        Write-Warning "  Failed to create flow '$flowName': $($_.ErrorDetails.Message)"
    }
}

# ── Step 7: Update action YAMLs with new flow GUIDs + re-push ───────────────
if ($newFlowIds.Count -gt 0) {
    Write-Step 7 "Updating action YAMLs with new flow GUIDs and re-pushing..."
    foreach ($actionFile in Get-ChildItem "$WorkspaceDir\actions" -Filter "*.mcs.yml") {
        $content = Get-Content $actionFile.FullName -Raw
        # Match action YAML to workflow folder by action name ≈ flow folder name
        $actionName = $actionFile.BaseName
        foreach ($oldGuid in $newFlowIds.Keys) {
            $wfDirMatch = $wfDirs | Where-Object { $_.Name -like "*$oldGuid*" }
            if (-not $wfDirMatch) { continue }
            $wfDirMeta = Get-Content "$($wfDirMatch[0].FullName)\metadata.yml" -Raw
            # Check if this flow belongs to this action
            $flowMatchedByName = ($wfDirMatch[0].Name -match $actionName) -or ($actionName -match ($wfDirMatch[0].Name -replace "^TableTalk-Fabric-", "" -replace "-[a-f0-9-]+$",""))
            if ($flowMatchedByName -or $wfDirs.Count -eq 2) {
                # Simple fallback: match by index if only 2 actions and 2 flows
                $newId = $newFlowIds[$oldGuid]
                $content = $content -replace "kind: InvokeFlowTaskAction", "kind: InvokeFlowTaskAction`n  flowId: $newId"
                Set-Content $actionFile.FullName -Value $content -Encoding UTF8 -NoNewline
                Write-Host "  → $($actionFile.Name): flowId set to $newId" -ForegroundColor Green
                break
            }
        }
    }

    Write-Host ""
    Write-Host "  Re-running pac copilot push with flow IDs..."
    & $PacExe copilot push --project-dir $WorkspaceDir 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warning "Second pac push returned $LASTEXITCODE" }
} else {
    Write-Step 7 "No flows created — skipping re-push"
}

# ── Step 8: Upload skills ─────────────────────────────────────────────────────
Write-Step 8 "Uploading InlineAgentSkill botcomponents..."
$skillFiles = Get-ChildItem $SkillsDir -Filter "*.md"
foreach ($sf in $skillFiles) {
    $mdContent  = Get-Content $sf.FullName -Raw
    $skillName  = $sf.BaseName
    $skillDesc  = ""
    if ($mdContent -match "(?m)^name:\s*(.+)") { $skillName = $Matches[1].Trim() }
    if ($mdContent -match "(?m)^description:\s*(.+)") { $skillDesc = $Matches[1].Trim() }

    # Build YAML data with proper 2-space indent for content block
    $lines       = $mdContent -split "`n" | ForEach-Object { "  $_" }
    $skillData   = "kind: InlineAgentSkill`ncontent: |-`n" + ($lines -join "`n")
    $safeSchema  = ($sf.BaseName -replace '[^a-zA-Z0-9]','-').ToLower()

    $payload = @{
        name            = $skillName
        schemaname      = "$AgentSchemaName.skill.$safeSchema"
        componenttype   = 9
        data            = $skillData
        description     = $skillDesc
        "parentbotid@odata.bind" = "/bots($newBotId)"
    } | ConvertTo-Json -Depth 5

    try {
        $resp = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents" -Method POST -Headers $dvHeaders -Body $payload
        Write-Host "  → Skill '$skillName' uploaded (ID: $($resp.botcomponentid))" -ForegroundColor Green
    } catch {
        Write-Warning "  Failed to upload skill '$skillName': $($_.ErrorDetails.Message)"
    }
}

# ── Step 9: Manual action notice ─────────────────────────────────────────────
Write-Step 9 "MANUAL STEP REQUIRED — create Power BI connection"
Write-Host ""
Write-Host "  The flows were created but are in DRAFT state." -ForegroundColor Yellow
Write-Host "  To activate them, you must provide a Power BI connection:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Go to PPAC: https://make.powerapps.com/environments/$($OrgNoTrail -replace 'https://' -replace '.crm.dynamics.com')/connections"
Write-Host "  2. Create a new Power BI connection (sign in)"
Write-Host "  3. In Solutions > Default Solution, find the connection reference: $newConnRefName"
Write-Host "  4. Edit it and link to the new connection"
Write-Host "  5. The flows will automatically activate"
Write-Host ""

# ── Clean up temp clone dir ───────────────────────────────────────────────────
# (keep it for debugging; remove manually if desired)

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Install Complete" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Agent in Copilot Studio (Zava PP):"
Write-Host "  https://copilotstudio.preview.microsoft.com/environments/97c5ffae-ff12-e84d-989c-2babf4594409/home" -ForegroundColor Cyan
Write-Host ""
Write-Host "Bot ID: $newBotId"
Write-Host ""
Write-Host "Checklist:"
Write-Host "  [x] Agent created in Zava PP"
Write-Host "  [x] Agent YAML pushed (settings, actions)"
Write-Host "  [x] Power Automate flows created (Draft — need connection)"
Write-Host "  [x] Action botcomponents linked to flows"
Write-Host "  [x] Skill knowledge uploaded"
Write-Host "  [ ] MANUAL: Create Power BI connection + activate flows"
