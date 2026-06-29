<#
.SYNOPSIS
    Deploy a Modern Copilot Studio agent and apply your VS Code edits, reliably.

.DESCRIPTION
    Takes the output of develop/export.ps1 — a deployable bundle ZIP plus the editable files in
    sample/ — and deploys it to a target environment WITHOUT pac copilot push (which is unreliable
    for cliagent-* agents). Deployment uses Dataverse solution import for structure, then applies
    your local edits via targeted Dataverse writes.

    ─────────────────────────────────────────────────────────────────────────────
    WHAT YOU CAN EDIT IN VS CODE (and this script deploys)
    ─────────────────────────────────────────────────────────────────────────────
      • Agent instructions      sample/<Agent>.instructions.md   (the system prompt / behaviour)
      • Model + AI settings      sample/agent-config.json         (model series, content moderation…)
      • Inline skill content     sample/<Agent>/translations/*.skill.*.mcs.yml  (markdown skills)
      • Tool / knowledge wording sample/<Agent>/translations/*, knowledge/*      (descriptions)

      These are applied to existing components via reliable Dataverse writes.

    ─────────────────────────────────────────────────────────────────────────────
    WHAT YOU MUST DO IN THE COPILOT STUDIO UI (then re-run develop/export.ps1)
    ─────────────────────────────────────────────────────────────────────────────
      • ADD or REMOVE a tool, connector, or flow   (needs connection wiring / Power Automate)
      • ADD a skill that runs Python / code         (needs the server-side bundle upload)
      • ADD file knowledge (PDF, DOCX)              (needs the binary upload gateway)

      These change the agent's STRUCTURE. There is no reliable CLI path to push new structural
      components for cliagent-* agents, so build them once in Copilot Studio, then re-export to
      bring the new structure into your bundle and local files.

    ─────────────────────────────────────────────────────────────────────────────
    THE ONE RUNTIME STEP THAT ALWAYS APPLIES: PUBLISH
    ─────────────────────────────────────────────────────────────────────────────
      Dataverse writes update the agent's authoring (draft) copy. To make changes live on
      channels you must PUBLISH. pac copilot publish crashes for cliagent-* agents, so this is a
      one-click step in Copilot Studio. This script opens the agent and tells you exactly where.

    PREREQUISITES
    ─────────────
    pac CLI / az CLI, pac auth + az login with access to the target environment.

.PARAMETER BundleZip      Path to the <Agent>-bundle.zip produced by develop/export.ps1.
.PARAMETER SampleDir      Path to the sample/ folder with your edited files. Defaults to repo sample/.
.PARAMETER AgentName      Display name (the sample/<AgentName>/ subfolder). Auto-detected if omitted.
.PARAMETER TargetOrgUrl   Dataverse org URL for the target environment.
.PARAMETER AuthIndex      pac auth index for the target environment.
.PARAMETER PacExe         Path to pac.exe. Auto-detected if not specified.

.EXAMPLE
    .\install.ps1 -BundleZip ..\My-Agent-bundle.zip -TargetOrgUrl https://target.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $BundleZip,
    [string] $SampleDir    = "",
    [string] $AgentName    = "",
    [Parameter(Mandatory)][string] $TargetOrgUrl,
    [switch] $WhatIf,
    [int]    $AuthIndex    = 1,
    [string] $PacExe       = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot   = Split-Path $ScriptDir -Parent
$SampleDir  = if ($SampleDir) { $SampleDir } else { Join-Path $RepoRoot "sample" }
$OrgNoTrail = $TargetOrgUrl.TrimEnd("/")

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

# Friendly preflight (see distribute/export.ps1): clear guidance when az is missing, not signed in,
# or the environment is unreachable. Returns the access token.
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

# Resolve the Power Platform environment GUID for an org URL (for a working Copilot Studio link).
function Resolve-EnvId {
    param([string]$OrgUrl, [string]$PacExePath, [int]$AuthIdx)
    try {
        & $PacExePath auth select --index $AuthIdx | Out-Null
        $orgHost = ([Uri]$OrgUrl).Host
        foreach ($ln in (& $PacExePath env list 2>$null)) {
            if ($ln -match [regex]::Escape($orgHost) -and
                $ln -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { return $Matches[1] }
        }
    } catch {}
    return $null
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Modern Agent Deploy -- Develop (edit) Path" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Target : $OrgNoTrail"
Write-Host ""

# ── Resolve bundle ────────────────────────────────────────────────────────────
Step "Resolving bundle + edited files"
if (-not (Test-Path $BundleZip)) { Write-Error "BundleZip not found: $BundleZip" }
$tempExtractDir = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-bundle-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempExtractDir | Out-Null
Expand-Archive -Path $BundleZip -DestinationPath $tempExtractDir -Force
$zipPath      = Join-Path $tempExtractDir "agent.zip"
$manifestPath = Join-Path $tempExtractDir "manifest.json"
if (-not (Test-Path $zipPath))      { Write-Error "agent.zip not found in bundle" }
if (-not (Test-Path $manifestPath)) { Write-Error "manifest.json not found in bundle" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$agentSchema = $manifest.agentSchema
if (-not $AgentName) { $AgentName = $manifest.agentName }
$agentDir = Join-Path $SampleDir $AgentName
OK "Agent: $AgentName  (schema: $agentSchema)"
if (Test-Path $agentDir) { OK "Edited files: sample\$AgentName\" } else { WARN "sample\$AgentName\ not found -- will deploy bundle as-is (no local edits applied)" }

# ── -WhatIf: preview the plan, then stop without changing anything ─────────────
if ($WhatIf) {
    # Pre-assign arrays (an if-block emitting an empty array collapses to $null — see distribute/install.ps1).
    $seedT = @();   if ($manifest.PSObject.Properties["seedTables"])       { $seedT  = @($manifest.seedTables) }
    $skillsW = @(); if ($manifest.PSObject.Properties["skillsWithAssets"]) { $skillsW = @($manifest.skillsWithAssets) }
    $conns = @();   if ($manifest.PSObject.Properties["connectorsRequired"] -and $manifest.connectorsRequired) { $conns = @($manifest.connectorsRequired) }
    $hasEdits = Test-Path $agentDir
    Write-Host ""
    Write-Host "  DRY RUN (-WhatIf): here's what deploy WOULD do to" -ForegroundColor Cyan
    Write-Host "  $OrgNoTrail  (nothing is actually changed)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   1. Import the agent '$($manifest.agentName)' and all its parts."
    if ($seedT.Count -gt 0) { Write-Host "   2. Recreate $($seedT.Count) custom table(s) + add their sample rows (only if empty)." } else { Write-Host "   2. No custom tables to recreate." }
    if ($hasEdits) { Write-Host "   3. Apply your edits from sample\$AgentName\ (instructions / model / skill text / descriptions)." } else { Write-Host "   3. No local edits folder found -- bundle deployed as-is." }
    if ($skillsW.Count -gt 0) { Write-Host "   4. Ask you to re-upload $($skillsW.Count) code-file skill(s) once in Copilot Studio." } else { Write-Host "   4. No code-file skills to re-upload." }
    if ($conns.Count -gt 0) { Write-Host "   5. Tell you to activate the agent's flow(s) (connection + turn on)." } else { Write-Host "   5. No connector flows to activate." }
    Write-Host "   6. Open the agent so you can click Publish."
    Write-Host ""
    OK "Dry run complete -- no changes made. Re-run without -WhatIf to deploy."
    if (Test-Path $tempExtractDir) { Remove-Item $tempExtractDir -Recurse -Force }
    return
}

# ── DV token ──────────────────────────────────────────────────────────────────
$token = Get-DvToken -OrgUrl $OrgNoTrail
$dv = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json"; Prefer="return=representation" }
$dvBase = "$OrgNoTrail/api/data/v9.2"

# ── Step 1: Solution import (reliable structure) ─────────────────────────────
Step "Step 1 -- Import agent structure (pac solution import)"
INFO "Reliable path: imports bot, all tools/skills/flows/knowledge/eval cases. No pac push."
& $PacExe auth select --index $AuthIndex | Out-Null
$importOut  = & $PacExe solution import --path $zipPath --environment $OrgNoTrail 2>&1
$importExit = $LASTEXITCODE
$importOut | ForEach-Object { INFO $_ }
$importText = ($importOut | Out-String)

# Locate the imported bot. Do NOT trust pac's exit code (it can print a FAILURE and still return 0)
# -- verify the bot actually landed in Dataverse.
$bot = (Invoke-RestMethod -Uri "$dvBase/bots?`$filter=schemaname eq '$agentSchema'&`$select=botid,name" -Headers $dv).value | Select-Object -First 1
if (($importExit -ne 0) -or ($importText -match 'cannot be imported|Missing dependenc|FAILURE') -or -not $bot) {
    Write-Host ""
    Write-Host "  SOLUTION IMPORT FAILED -- the agent was NOT installed." -ForegroundColor Red
    if ($importText -match 'Missing dependenc|cannot be imported') {
        Write-Host "  Cause: a dependency (often a Dataverse table or connector used by a flow) is" -ForegroundColor Yellow
        Write-Host "  missing in the target. See the pac error above ('Required type=... schemaName=...')." -ForegroundColor Yellow
        Write-Host "  Fix: create/import that dependency in the target first, then re-run." -ForegroundColor Yellow
    }
    Write-Error "Imported bot (schema '$agentSchema') not found in target. Aborting."
}
$botId = $bot.botid
OK "Solution imported -- bot present: $($bot.name) ($botId)"

# ── Step 1b: Seed custom tables with SAMPLE data (best-effort, non-fatal) ─────
$seedTables = @()
if ($manifest.PSObject.Properties["seedTables"]) { $seedTables = @($manifest.seedTables) }
if ($seedTables.Count -gt 0) {
    Step "Step 1b -- Seeding $($seedTables.Count) custom table(s) with sample data"
    $seededAny = $false
    foreach ($tbl in $seedTables) {
        try {
            if (-not $tbl.hasSeed) { INFO "  '$($tbl.logical)': no sample rows in bundle -- skipping"; continue }
            $existing = (Invoke-RestMethod -Uri "$dvBase/$($tbl.setName)?`$top=1&`$select=$($tbl.primaryName)" -Headers $dv).value
            if ($existing.Count -gt 0) { INFO "  '$($tbl.logical)': already has data -- not seeding"; continue }
            $seedFile = Join-Path $tempExtractDir "seed-data\$($tbl.logical).json"
            if (-not (Test-Path $seedFile)) { INFO "  '$($tbl.logical)': seed file missing -- skipping"; continue }
            $rows = @(Get-Content $seedFile -Raw | ConvertFrom-Json)
            $n = 0
            foreach ($row in $rows) {
                Invoke-RestMethod -Uri "$dvBase/$($tbl.setName)" -Method POST -Headers $dv -Body ($row | ConvertTo-Json -Depth 5) | Out-Null
                $n++
            }
            OK "  '$($tbl.logical)': seeded $n sample row(s)"
            if ($n -gt 0) { $seededAny = $true }
        } catch {
            WARN "  '$($tbl.logical)': could not seed ($($_.Exception.Message))"
        }
    }
    if ($seededAny) { WARN "Those are SAMPLE rows shipped with the agent -- replace them with your own data before real use." }
}

# ── Step 2: Apply instruction / model / AI-settings edits (bot.configuration) ─
Step "Step 2 -- Apply your instruction + model edits (bot.configuration)"
$configPath = Join-Path $SampleDir "agent-config.json"
$instrPath  = Join-Path $SampleDir "$AgentName.instructions.md"
if (Test-Path $configPath) {
    $cfgJson = Get-Content $configPath -Raw
    $cfgObj  = $cfgJson | ConvertFrom-Json
    # instructions.md is the friendly edit surface — if present, it wins over agent-config.json.
    # SAFETY: instructions.md is a single markdown blob. Applying it is only sound when the agent
    # has exactly one StaticSegment (the common case). If the agent uses multiple or dynamic
    # instruction segments, we do NOT collapse them (that would drop dynamic segments) — we keep
    # agent-config.json's exact structure and tell the user to edit it instead.
    if (Test-Path $instrPath) {
        $md = (Get-Content $instrPath -Raw) -replace '(?m)^\s*<!--.*?-->\s*$', ''   # drop helper comment lines
        $md = $md.Trim()
        $segs = @($cfgObj.agentSettings.instructions.segments)
        $singleStatic = ($segs.Count -eq 1) -and ($segs[0].'$kind' -eq 'StaticSegment')
        if ($md -and $singleStatic) {
            $cfgObj.agentSettings.instructions.segments[0].value = $md
            $cfgJson = $cfgObj | ConvertTo-Json -Depth 50
            INFO "Instructions taken from $AgentName.instructions.md ($($md.Length) chars)"
        } elseif ($md) {
            WARN "Agent has $($segs.Count) instruction segment(s)/dynamic content -- not applying instructions.md."
            WARN "Edit instructions inside agent-config.json instead to preserve segment structure."
        }
    }
    # bot.configuration is a STRING field in Dataverse — ConvertTo-Json -Depth 1 string-encodes it.
    $body = @{ configuration = $cfgJson } | ConvertTo-Json -Depth 1
    Invoke-RestMethod -Uri "$dvBase/bots($botId)" -Method PATCH -Headers $dv -Body $body | Out-Null
    OK "bot.configuration applied (model: $($cfgObj.agentSettings.model.series))"
} else {
    INFO "No agent-config.json -- keeping instructions/model from the imported bundle"
}

# ── Step 3: Apply inline-skill content + tool/knowledge description edits ─────
Step "Step 3 -- Apply your skill content + description edits"
# Two safe, tested edit surfaces on EXISTING components:
#   • inline-skill markdown  -> the component 'data' field (kind: InlineAgentSkill with inline content)
#   • tool/skill/knowledge description -> the component 'description' column (from mcs.metadata.description)
# ZIP-packaged skills (bic:bundle=) are NOT touched here -- they need the manual upload in Step 4.
$translDir = Join-Path $agentDir "translations"
$dataPatched = 0; $descPatched = 0; $skippedAssets = 0
if (Test-Path $translDir) {
    $targetComps = (Invoke-RestMethod -Uri "$dvBase/botcomponents?`$filter=_parentbotid_value eq '$botId' and componenttype eq 9&`$select=botcomponentid,name,description,data" -Headers $dv).value
    foreach ($file in (Get-ChildItem $translDir -Filter "*.mcs.yml")) {
        $raw  = Get-Content $file.FullName -Raw
        $name = if ($raw -match "(?m)^\s*componentName:\s*(.+)$") { $Matches[1].Trim().Trim('"') } else { $null }
        if (-not $name) { continue }
        $tc = $targetComps | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if (-not $tc) { continue }

        # (a) description column — from mcs.metadata.description (single-line). Safe for every kind.
        if ($raw -match "(?m)^\s*description:\s*(.+)$") {
            $desc = $Matches[1].Trim().Trim('"')
            if ($desc -and (($tc.description ?? "").Trim() -ne $desc)) {
                Invoke-RestMethod -Uri "$dvBase/botcomponents($($tc.botcomponentid))" -Method PATCH -Headers $dv -Body (@{ description = $desc } | ConvertTo-Json -Depth 1) | Out-Null
                OK "  Description updated: '$name'"
                $descPatched++
            }
        }

        # (b) inline-skill content — the body from 'kind:' onward maps 1:1 to the 'data' field.
        $idx = $raw.IndexOf("kind:")
        if ($idx -ge 0) {
            $localData = $raw.Substring($idx).TrimEnd()
            if ($localData -match "bic:bundle=") { $skippedAssets++; continue }   # ZIP skill -> Step 4
            if ($localData -match "kind:\s*InlineAgentSkill" -and (($tc.data ?? "").TrimEnd() -ne $localData)) {
                Invoke-RestMethod -Uri "$dvBase/botcomponents($($tc.botcomponentid))" -Method PATCH -Headers $dv -Body (@{ data = $localData } | ConvertTo-Json -Depth 1) | Out-Null
                OK "  Skill content updated: '$name'"
                $dataPatched++
            }
        }
    }
}
if (($dataPatched + $descPatched) -eq 0) { INFO "No inline-skill or description edits to apply (everything matches the bundle)" }
if ($skippedAssets -gt 0) { INFO "$skippedAssets ZIP-packaged skill(s) handled in Step 4, not here" }

# ── Step 4: Skills with code assets — manual re-upload ───────────────────────
$skillsWithAssets = @()
if ($manifest.PSObject.Properties["skillsWithAssets"]) { $skillsWithAssets = @($manifest.skillsWithAssets) }
$envId = Resolve-EnvId -OrgUrl $OrgNoTrail -PacExePath $PacExe -AuthIdx $AuthIndex
if (-not $envId) { $envId = $OrgNoTrail -replace "https://","" -replace "\.crm\.dynamics\.com","" }
$agentUrl = "https://copilotstudio.microsoft.com/environments/$envId/agents/$botId"

if ($skillsWithAssets.Count -gt 0) {
    Step "Step 4 -- Skills with code assets need a one-time manual upload ($($skillsWithAssets.Count))"
    $skillSrcRoot = Join-Path $tempExtractDir "skills-with-assets"
    $reupload = @()
    foreach ($s in $skillsWithAssets) {
        $sName = if ($s.PSObject.Properties["skill"]) { $s.skill } else { $s }
        $sDir  = Join-Path $skillSrcRoot $sName
        if (Test-Path $sDir) {
            $zp = Join-Path (Split-Path (Resolve-Path $BundleZip).Path -Parent) "$sName-skill.zip"
            if (Test-Path $zp) { Remove-Item $zp -Force }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $z = [System.IO.Compression.ZipFile]::Open($zp,'Create')
            try { Get-ChildItem $sDir -File | ForEach-Object { [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z,$_.FullName,$_.Name)|Out-Null } } finally { $z.Dispose() }
            $reupload += @{ name=$sName; zip=$zp }
            OK "  Ready to upload: $zp"
        }
    }
    Write-Host ""
    Write-Host "  These are ZIP-packaged skills (a .zip bundling Python + SKILL.md). Their code bundle" -ForegroundColor Yellow
    Write-Host "  lives in the SOURCE environment's storage and cannot transfer — so the skill arrives" -ForegroundColor Yellow
    Write-Host "  empty and Copilot Studio will flag it. Re-upload the ZIP once to recreate it here:" -ForegroundColor Yellow
    Write-Host "    open the agent > click the skill > three-dot menu > Replace/Edit > upload the ZIP > Save." -ForegroundColor White
    Write-Host "  (Skills with code written INLINE in the skill text transfer fine and need nothing.)" -ForegroundColor DarkGray
}

# ── Step 5: Activate flows (connection + turn on) ────────────────────────────
# Flows import already linked to the agent's tools (GUIDs preserved by solution import). They
# arrive turned OFF with an empty connection reference. There is nothing to "add" to the agent —
# only activate each flow: assign a connection, then turn it on.
$connectors = @()
if ($manifest.PSObject.Properties["connectorsRequired"] -and $manifest.connectorsRequired) { $connectors = @($manifest.connectorsRequired) }
if ($connectors.Count -gt 0) {
    Step "Step 5 -- Activate the agent's flows (one-time per environment)"
    Write-Host "  The flows are already imported and linked to the agent. They just need activating:" -ForegroundColor Yellow
    Write-Host "    1. Open https://make.powerautomate.com and switch to this environment." -ForegroundColor White
    Write-Host "    2. Under Solutions (or My flows), open each imported flow." -ForegroundColor White
    Write-Host "    3. It shows 'This flow uses a connection that needs to be fixed' -- assign/create a" -ForegroundColor White
    Write-Host "       connection for each connector below, then Save." -ForegroundColor White
    Write-Host "    4. Turn the flow On." -ForegroundColor White
    Write-Host "    Connector(s) used:" -ForegroundColor Yellow
    $connectors | ForEach-Object { Write-Host "      - $_" -ForegroundColor White }
}

# ── Step 6: PUBLISH (the one runtime step that always applies) ────────────────
Step "Step 6 -- Publish to make your changes live (one click)"
Write-Host "  Your edits are saved to the agent's authoring copy. To go live you must PUBLISH." -ForegroundColor Yellow
Write-Host "  (pac copilot publish crashes for cliagent-* agents, so this is a one-click UI step.)" -ForegroundColor DarkGray
Write-Host "    1. Open: $agentUrl" -ForegroundColor White
Write-Host "    2. Click 'Publish' (top-right) and confirm." -ForegroundColor White
try { Start-Process $agentUrl; INFO "Opening agent in browser..." } catch { WARN "Open manually: $agentUrl" }

# ── Cleanup + summary ─────────────────────────────────────────────────────────
if (Test-Path $tempExtractDir) { Remove-Item $tempExtractDir -Recurse -Force }

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Deploy Complete" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Agent : $($bot.name) ($botId)"
Write-Host "  URL   : $agentUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Applied:"
Write-Host "    [x] Structure imported (tools, skills, flows, knowledge, eval cases)"
Write-Host "    [x] Instructions + model/AI settings"
if (($dataPatched + $descPatched) -gt 0) {
    Write-Host "    [x] Edits applied: $dataPatched skill content, $descPatched description(s)"
} else {
    Write-Host "    [-] No inline-skill / description edits"
}
if ($skillsWithAssets.Count -gt 0) { Write-Host "    [!] $($skillsWithAssets.Count) ZIP-packaged skill(s): upload ZIP in CS (Step 4)" -ForegroundColor Yellow }
if ($connectors.Count -gt 0)       { Write-Host "    [!] Activate flow(s) in Power Automate: connection + turn on (Step 5)" -ForegroundColor Yellow }
Write-Host "    [>] PUBLISH in Copilot Studio to go live (Step 6)" -ForegroundColor Yellow
