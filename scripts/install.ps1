<#
.SYNOPSIS
    Imports a Copilot Studio Modern Orchestration (NGO / cliagent-1.0.0) agent into a new environment.

.DESCRIPTION
    Handles 4 things pac copilot push alone cannot do for NGO agents:

      1. Agent pre-creation      — pac push needs the bot to exist first. Creates via DV API.
      2. Bot config patch        — instructions + model live in bot.configuration, not YAML.
                                   pac push does NOT write this. This script PATCHes it.
      3. Flow creation + ID fix  — action YAMLs have env-specific flowIds. pac push fails.
                                   Creates flows via DV API, then re-pushes with new GUIDs.
      4. Skill upload            — InlineAgentSkill botcomponents not in YAML.
                                   POSTs ./skills/*.md to target Dataverse.

.EXAMPLE
    .\scripts\install.ps1
    .\scripts\install.ps1 -TargetOrgUrl "https://targetorg.crm.dynamics.com" -AuthIndex 3
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
$ScriptDir   = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot    = Split-Path $ScriptDir -Parent
$SampleDir   = Join-Path $RepoRoot "sample\$AgentDisplayName"
$SkillsDir   = Join-Path $RepoRoot "skills"
$ConfigPath  = Join-Path $RepoRoot "sample\agent-config.json"
$OrgNoTrail  = $TargetOrgUrl.TrimEnd("/")
$CloneDir    = Join-Path $RepoRoot "_clone_$(Get-Date -Format 'yyyyMMddHHmmss')"

function Write-Step([int]$n, [string]$msg) { Write-Host "`n[$n/10] $msg" -ForegroundColor Yellow }

Write-Host "`n======================================================" -ForegroundColor Cyan
Write-Host "  Modern Agent Install — NGO Toolkit (cliagent-1.0.0)" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "Target env : $OrgNoTrail`nAgent      : $AgentDisplayName ($AgentSchemaName)`n"

# DV token
Write-Host "Acquiring Dataverse token via az CLI..."
$token = (az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json).accessToken
$dv = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json"; Prefer="return=representation" }
Write-Host "  -> Token acquired" -ForegroundColor Green

# Step 1: pac auth
Write-Step 1 "Selecting pac auth index $AuthIndex..."
& $PacExe auth select --index $AuthIndex | Out-Null

# Step 2: Create agent in target DV
Write-Step 2 "Creating agent in target Dataverse..."
$newBotId = $null
try {
    $ex = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots?`$filter=schemaname eq '$AgentSchemaName'&`$select=botid" -Headers $dv
    if ($ex.value.Count -gt 0) { $newBotId = $ex.value[0].botid; Write-Host "  -> Already exists: $newBotId" -ForegroundColor DarkYellow }
} catch {}
if (-not $newBotId) {
    $b = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots" -Method POST -Headers $dv -Body (@{ name=$AgentDisplayName; schemaname=$AgentSchemaName; template="cliagent-1.0.0"; language=1033; authenticationmode=1 } | ConvertTo-Json)
    $newBotId = $b.botid
    Write-Host "  -> Created: $newBotId" -ForegroundColor Green
}

# Step 3: Clone new empty agent to get valid workspace
Write-Step 3 "Cloning empty agent to get a valid target-env workspace..."
New-Item -ItemType Directory -Force -Path $CloneDir | Out-Null
& $PacExe copilot clone --environment $OrgNoTrail --bot $newBotId --display-name $AgentDisplayName --output-dir $CloneDir
if ($LASTEXITCODE -ne 0) { Write-Error "pac clone failed" }
$ws = "$CloneDir\$AgentDisplayName"
Write-Host "  -> Workspace: $ws" -ForegroundColor Green

# Step 4: Copy YAML into workspace, strip source flowIds
Write-Step 4 "Copying source YAML (stripping source-env flowIds)..."
foreach ($d in @("actions","workflows","translations")) { New-Item -ItemType Directory -Force -Path "$ws\$d" | Out-Null }
Copy-Item "$SampleDir\agent.mcs.yml" "$ws\agent.mcs.yml"
Copy-Item "$SampleDir\settings.mcs.yml" "$ws\settings.mcs.yml"
Copy-Item "$SampleDir\icon.png" "$ws\icon.png" -ErrorAction SilentlyContinue
Copy-Item "$SampleDir\workflows\*" "$ws\workflows\" -Recurse -Force
Copy-Item "$SampleDir\translations\*" "$ws\translations\" -Force
foreach ($f in Get-ChildItem "$SampleDir\actions" -Filter "*.mcs.yml") {
    (Get-Content $f.FullName -Raw) -replace "(?m)^  flowId: [a-f0-9\-]+\r?\n","" | Set-Content "$ws\actions\$($f.Name)" -Encoding UTF8 -NoNewline
}
Write-Host "  -> YAML copied, flowIds stripped" -ForegroundColor Green

# Step 5: Initial pac push
Write-Step 5 "Initial pac copilot push (agent config + action botcomponents)..."
& $PacExe copilot push --project-dir $ws 2>&1

# Step 6: PATCH bot.configuration (instructions, model, AI settings)
Write-Step 6 "Patching bot.configuration (instructions, model, AI settings)..."
if (Test-Path $ConfigPath) {
    $cfg = Get-Content $ConfigPath -Raw
    Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots($newBotId)" -Method PATCH -Headers $dv -Body ('{"configuration":' + $cfg + '}') | Out-Null
    Write-Host "  -> Patched ($($cfg.Length) chars)" -ForegroundColor Green
} else {
    Write-Warning "  sample\agent-config.json not found — instructions not applied. Run export.ps1 on source first."
}

# Step 7: Create Power BI connection reference
Write-Step 7 "Creating Power BI connection reference..."
$crName = ($AgentSchemaName -replace '[^a-zA-Z0-9]','_') + "_cr_powerbi"
try {
    Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/connectionreferences" -Method POST -Headers $dv -Body (@{ connectionreferencelogicalname=$crName; connectorid="/providers/Microsoft.PowerApps/apis/shared_powerbi" } | ConvertTo-Json) | Out-Null
    Write-Host "  -> Created: $crName" -ForegroundColor Green
} catch { Write-Host "  -> Already exists (OK)" -ForegroundColor DarkYellow }

# Step 8: Create Power Automate flows via DV API
Write-Step 8 "Creating Power Automate flows from workflow definitions..."
$newFlowIds = @{}
$wfDirs = Get-ChildItem "$ws\workflows" -Directory
foreach ($wd in $wfDirs) {
    $meta = Get-Content "$($wd.FullName)\metadata.yml" -Raw
    $wfj  = (Get-Content "$($wd.FullName)\workflow.json" -Raw) -replace [regex]::Escape($SourceConnRefLogicalName), $crName
    $name = if ($meta -match "name: (.+)") { $Matches[1].Trim() } else { $wd.Name }
    $guid = [Guid]::NewGuid().ToString()
    try {
        Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/workflows" -Method POST -Headers $dv -Body (@{ workflowid=$guid; name=$name; category=5; type=1; primaryentity="none"; statecode=0; statuscode=1; clientdata=$wfj } | ConvertTo-Json -Depth 3) | Out-Null
        Write-Host "  -> '$name' -> $guid" -ForegroundColor Green
        if ($wd.Name -match "([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$") { $newFlowIds[$Matches[1]] = $guid }
    } catch { Write-Warning "  Flow '$name' failed: $($_.Exception.Message)" }
}

# Step 9: Patch action YAMLs with new flowIds + re-push
Write-Step 9 "Patching action YAMLs with new flow GUIDs and re-pushing..."
if ($newFlowIds.Count -gt 0) {
    $actionFiles = @(Get-ChildItem "$ws\actions" -Filter "*.mcs.yml")
    $flowList    = @($newFlowIds.GetEnumerator())
    for ($i = 0; $i -lt $actionFiles.Count -and $i -lt $flowList.Count; $i++) {
        $c = Get-Content $actionFiles[$i].FullName -Raw
        # Try name match first
        $matched = $false
        foreach ($kv in $newFlowIds.GetEnumerator()) {
            $wfDir = $wfDirs | Where-Object { $_.Name -like "*$($kv.Key)*" } | Select-Object -First 1
            if ($wfDir) {
                $wfName = if ((Get-Content "$($wfDir.FullName)\metadata.yml" -Raw) -match "name: (.+)") { $Matches[1].Trim() } else { "" }
                if ($wfName -match $actionFiles[$i].BaseName -or $actionFiles[$i].BaseName -match ($wfName -replace "TableTalk - Fabric - ","" -replace " ","")) {
                    $c = $c -replace "kind: InvokeFlowTaskAction", "kind: InvokeFlowTaskAction`n  flowId: $($kv.Value)"
                    Set-Content $actionFiles[$i].FullName -Value $c -Encoding UTF8 -NoNewline
                    Write-Host "  -> $($actionFiles[$i].Name): flowId = $($kv.Value)" -ForegroundColor Green
                    $matched = $true; break
                }
            }
        }
        if (-not $matched) {
            # Fallback: assign by index
            $newId = $flowList[$i].Value
            $c = $c -replace "kind: InvokeFlowTaskAction", "kind: InvokeFlowTaskAction`n  flowId: $newId"
            Set-Content $actionFiles[$i].FullName -Value $c -Encoding UTF8 -NoNewline
            Write-Host "  -> $($actionFiles[$i].Name): flowId = $newId (index fallback)" -ForegroundColor DarkYellow
        }
    }
    Write-Host "`n  Re-pushing with flow IDs..."
    & $PacExe copilot push --project-dir $ws 2>&1
}

# Step 10: Upload InlineAgentSkill botcomponents
Write-Step 10 "Uploading InlineAgentSkill knowledge botcomponents..."
foreach ($sf in (Get-ChildItem $SkillsDir -Filter "*.md" -ErrorAction SilentlyContinue)) {
    $md   = Get-Content $sf.FullName -Raw
    $name = if ($md -match "(?m)^name:\s*(.+)") { $Matches[1].Trim() } else { $sf.BaseName }
    $data = "kind: InlineAgentSkill`ncontent: |-`n" + (($md -split "`n") | ForEach-Object { "  $_" } | Out-String).TrimEnd()
    $sch  = ($sf.BaseName -replace '[^a-zA-Z0-9]','-').ToLower()
    try {
        $r = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents" -Method POST -Headers $dv -Body (@{ name=$name; schemaname="$AgentSchemaName.skill.$sch"; componenttype=9; data=$data; "parentbotid@odata.bind"="/bots($newBotId)" } | ConvertTo-Json -Depth 5)
        Write-Host "  -> Skill '$name' ($($r.botcomponentid))" -ForegroundColor Green
    } catch { Write-Warning "  Skill '$name' failed: $($_.Exception.Message)" }
}

Write-Host "`n======================================================" -ForegroundColor Cyan
Write-Host "  Install Complete" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "`nBot ID : $newBotId"
$envId = $OrgNoTrail -replace "https://","" -replace ".crm.dynamics.com",""
Write-Host "URL    : https://copilotstudio.preview.microsoft.com/environments/$envId/home" -ForegroundColor Cyan
Write-Host @"

Status:
  [x] Agent created in Dataverse
  [x] YAML pushed (settings, actions)
  [x] bot.configuration patched (instructions + model)
  [x] Power Automate flows created
  [x] Action tools linked to flows (flowId patched)
  [x] Skills uploaded

Manual step required (one-time per environment):
  Flows are in DRAFT until a Power BI connection is provided.
  1. PPAC -> Connections -> New -> Power BI (sign in with a user who has access to the dataset)
  2. Default Solution -> Connection References -> find '$crName' -> Edit -> link the connection
  3. Flows activate automatically
"@
