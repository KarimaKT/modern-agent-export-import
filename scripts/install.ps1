<#
.SYNOPSIS
    Imports a Copilot Studio Modern Orchestration (NGO/cliagent-1.0.0) agent into a target environment.
    Handles the two complications that classic pac push misses:
      1. Flow ID remapping — action YAMLs contain source-env flowIds; this script patches them
         with the new GUIDs created in the target env after pac push.
      2. Skill upload — InlineAgentSkill botcomponents in ./skills/ are POSTed to target Dataverse.

.PARAMETER PacExe
    Path to pac.exe.

.PARAMETER TargetOrgUrl
    Target Dataverse org URL.

.PARAMETER AgentSchemaName
    Schema name of the agent (used to find the newly created bot in target DV).

.PARAMETER AgentName
    Display name of the agent folder under ./sample/.

.PARAMETER AuthIndex
    pac auth index for the target environment account.

.EXAMPLE
    .\scripts\install.ps1
    .\scripts\install.ps1 -TargetOrgUrl "https://myorg.crm.dynamics.com" -AuthIndex 3
#>
param(
    [string]$PacExe          = "C:\Users\kkanjitajdin\.nuget\packages\microsoft.powerapps.cli\2.8.1\tools\pac.exe",
    [string]$TargetOrgUrl    = "https://org07697283.crm.dynamics.com",
    [string]$AgentSchemaName = "Default_FabricAnalyst_dQTqzr",
    [string]$AgentName       = "Fabric Analyst",
    [int]   $AuthIndex       = 1
)

$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot   = Split-Path $ScriptDir -Parent
$AgentDir   = Join-Path $RepoRoot "sample\$AgentName"
$SkillsDir  = Join-Path $RepoRoot "skills"
$OrgNoTrail = $TargetOrgUrl.TrimEnd("/")

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Modern Agent Install — NGO Toolkit" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Target env : $OrgNoTrail"
Write-Host "Agent dir  : $AgentDir"
Write-Host ""

# ── Step 1: Select target auth ───────────────────────────────────────────────
Write-Host "[1/5] Selecting pac auth index $AuthIndex (target env)..." -ForegroundColor Yellow
& $PacExe auth select --index $AuthIndex
if ($LASTEXITCODE -ne 0) { Write-Error "pac auth select failed" }

# ── Step 2: Initial pac copilot push ─────────────────────────────────────────
Write-Host ""
Write-Host "[2/5] Running pac copilot push (creates agent + Power Automate flows)..." -ForegroundColor Yellow
Write-Host "      This creates new flows with new GUIDs in the target env."
& $PacExe copilot push --project-dir $AgentDir

if ($LASTEXITCODE -ne 0) {
    Write-Warning "pac copilot push returned exit code $LASTEXITCODE — continuing to attempt flow-ID fix."
}

# ── Step 3: Get DV bearer token for target env ───────────────────────────────
Write-Host ""
Write-Host "[3/5] Getting Dataverse access token for target env..." -ForegroundColor Yellow
$tokenJson = az account get-access-token --resource $OrgNoTrail 2>&1
if ($LASTEXITCODE -ne 0) {
    # Try switching az account to the target tenant
    Write-Warning "az token failed — you may need to run: az login --allow-no-subscriptions"
    Write-Warning "Then re-run install.ps1."
    Write-Host ""
    Write-Host "Attempting to continue without token (flow-ID fix and skill upload will be skipped)..."
    Write-Host ""
    $token = $null
} else {
    $token = ($tokenJson | ConvertFrom-Json).accessToken
}

if ($token) {
    $headers = @{
        Authorization      = "Bearer $token"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        Accept             = "application/json"
        "Content-Type"     = "application/json"
    }

    # ── Step 4: Flow ID fix ───────────────────────────────────────────────────
    Write-Host "[4/5] Remapping flow IDs in action YAMLs..." -ForegroundColor Yellow

    # Discover the new bot ID in target env
    $botQuery = "$OrgNoTrail/api/data/v9.2/bots?`$filter=schemaname eq '$AgentSchemaName'&`$select=botid,name,schemaname"
    try {
        $botResult = Invoke-RestMethod -Uri $botQuery -Headers $headers
        $newBotId  = $botResult.value[0].botid
        Write-Host "  → Found bot in target env: $newBotId" -ForegroundColor Green
    } catch {
        Write-Warning "Could not find bot '$AgentSchemaName' in target env. Flow-ID fix skipped."
        $newBotId = $null
    }

    if ($newBotId) {
        # Query all workflows in target env created by/for this agent
        # Workflows created by pac push have category=5 (Modern Flow) and name matching our prefix
        $wfQuery = "$OrgNoTrail/api/data/v9.2/workflows?`$filter=category eq 5&`$select=workflowid,name,createdon&`$orderby=createdon desc&`$top=50"
        $wfResult = Invoke-RestMethod -Uri $wfQuery -Headers $headers
        $flows    = $wfResult.value
        Write-Host "  → Found $($flows.Count) modern flows in target env (latest 50)"

        # Match flows to action YAMLs by name substring
        # Workflow dir names: TableTalk-Fabric-SendDAXQuery-{guid}, TableTalk-Fabric-Refreshdataset-{guid}
        $actionFiles = Get-ChildItem "$AgentDir\actions" -Filter "*.mcs.yml"
        $remapped = 0

        foreach ($actionFile in $actionFiles) {
            $content = Get-Content $actionFile.FullName -Raw
            if ($content -notmatch "kind: InvokeFlowTaskAction") { continue }

            # Extract current flowId
            if ($content -match "flowId:\s*([a-f0-9\-]+)") {
                $oldFlowId = $Matches[1]
            } else { continue }

            # Derive search prefix from action file name (e.g., ExecuteDAX → SendDAXQuery, RefreshDataset → Refreshdataset)
            $actionName = $actionFile.BaseName
            # Find the workflow folder whose name contains the old flow ID
            $wfDirs = Get-ChildItem "$AgentDir\workflows" -Directory | Where-Object { $_.Name -like "*$oldFlowId*" }
            if ($wfDirs) {
                # Extract display name prefix (everything before the GUID)
                $wfPrefix = ($wfDirs[0].Name -split "-[a-f0-9]{8}-")[0]
            } else {
                Write-Warning "  Could not determine workflow name for $actionName (flowId $oldFlowId)"
                continue
            }

            Write-Host "  Searching for flow matching prefix: '$wfPrefix'"
            # Find matching flow in target env (name contains the prefix)
            $match = $flows | Where-Object { $_.name -like "*$wfPrefix*" } | Select-Object -First 1
            if (-not $match) {
                Write-Warning "  No target flow found matching '$wfPrefix' for action $actionName"
                continue
            }

            $newFlowId = $match.workflowid
            Write-Host "  → $actionName : $oldFlowId → $newFlowId" -ForegroundColor Green
            $updated = $content -replace $oldFlowId, $newFlowId
            Set-Content $actionFile.FullName -Value $updated -Encoding UTF8
            $remapped++
        }

        if ($remapped -gt 0) {
            Write-Host ""
            Write-Host "  $remapped action file(s) updated. Re-running pac copilot push..." -ForegroundColor Yellow
            & $PacExe copilot push --project-dir $AgentDir
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Second pac copilot push returned exit code $LASTEXITCODE"
            }
        } else {
            Write-Host "  No flow IDs needed remapping (pac push may have handled it automatically)." -ForegroundColor DarkGray
        }

        # ── Step 5: Upload skills ─────────────────────────────────────────────
        Write-Host ""
        Write-Host "[5/5] Uploading skill botcomponents to target Dataverse..." -ForegroundColor Yellow
        $skillFiles = Get-ChildItem $SkillsDir -Filter "*.md"

        foreach ($sf in $skillFiles) {
            $mdContent = Get-Content $sf.FullName -Raw

            # Parse frontmatter for name and description
            $skillName = $sf.BaseName
            $skillDesc = ""
            if ($mdContent -match "(?s)^---\s*\nname:\s*(.+?)\n") { $skillName = $Matches[1].Trim() }
            if ($mdContent -match "(?s)description:\s*(.+?)\n") { $skillDesc = $Matches[1].Trim() }

            # Build the botcomponent payload
            $skillData = @"
kind: InlineAgentSkill
content: |-
$(($mdContent -split "`n" | ForEach-Object { "  $_" }) -join "`n")
"@

            $payload = @{
                name         = $skillName
                schemaname   = "$AgentSchemaName.skill.$($sf.BaseName -replace '[^a-zA-Z0-9]','-')"
                componenttype = 9
                data         = $skillData
                description  = $skillDesc
                "parentbotid@odata.bind" = "/bots($newBotId)"
            } | ConvertTo-Json -Depth 5

            try {
                $postHeaders = $headers.Clone()
                $postHeaders["Prefer"] = "return=representation"
                $resp = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents" `
                    -Method POST -Headers $postHeaders -Body $payload
                Write-Host "  → Uploaded skill: $skillName (ID: $($resp.botcomponentid))" -ForegroundColor Green
            } catch {
                Write-Warning "  Failed to upload skill '$skillName': $_"
            }
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Install Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Agent URL in Copilot Studio:"
# Extract env ID from org URL (Zava PP has env ID 97c5ffae-ff12-e84d-989c-2babf4594409)
Write-Host "  https://copilotstudio.preview.microsoft.com/environments/97c5ffae-ff12-e84d-989c-2babf4594409/home" -ForegroundColor Cyan
Write-Host ""
Write-Host "If the agent tools show errors, verify:"
Write-Host "  1. Power BI connection references are configured in the target env"
Write-Host "  2. Flow connections are authorized by the agent owner"
Write-Host "  3. Skills appear in the Knowledge tab of the agent"
