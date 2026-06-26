<#
.SYNOPSIS
    Imports a Modern Agent bundle (exported by export.ps1) into a target Dataverse environment.

.DESCRIPTION
    install.ps1 takes an agent bundle produced by export.ps1 and installs it into a target Power
    Platform environment.  A bundle is either a ZIP file ({AgentName}-bundle.zip) or an already-
    extracted folder (or git clone).

    BUNDLE CONTENTS
    ---------------
    agent.zip                         - Dataverse solution package
    manifest.json                     - Agent schema name, required connectors, skills metadata
    skills-with-assets/{skill-name}/  - One folder per ZIP-type skill containing SKILL.md and
                                        any Python / asset files

    WHAT pac solution import HANDLES
    ---------------------------------
    The Dataverse solution import (pac solution import) takes care of:
      - The bot / agent definition itself
      - Bot configuration records
      - Power Automate flows wired to the agent
      - Connector tools and knowledge sources
      - Evaluation test cases

    SKILLS-WITH-ASSETS LIMITATION
    ------------------------------
    Skills whose instructions are stored as file blobs (type-9 botcomponent records whose `data`
    field contains the sentinel string "bic:bundle=") are NOT restored by the solution import.
    The bundle blob lives in Azure storage in the SOURCE environment and is created only by a
    server-side process that runs when a ZIP is uploaded through the Copilot Studio UI. There is
    no public API for it, so it cannot transfer through a solution.

    This script does NOT silently rewrite the skill to inline markdown — that would let the model
    call a "skill" that cannot execute its Python/code, degrading behavior with no warning.
    Instead it:
       1. Detects the broken skill(s) (data still contains bic:bundle= after import)
       2. Rebuilds a ready-to-upload ZIP from the bundled SKILL.md + assets
       3. Prints clear, mandatory re-upload steps and opens the agent in the browser
       4. Pauses so you can re-upload through the CS UI (the only path that recreates the bundle)
    The skill stays honestly broken until you complete the upload.

    CONNECTION WIRING MANUAL STEP
    ------------------------------
    After import, every Power Automate flow that uses a connector will show a "needs connection"
    warning.  You must open each flow in the Power Automate portal and assign a valid connection
    for each connector listed in the manifest.  The summary printed at the end of this script
    lists the connectors and the portal URL.

.EXAMPLE
    .\install.ps1 -BundleZip .\MyAgent-bundle.zip -TargetOrgUrl https://myorg.crm.dynamics.com

.EXAMPLE
    .\install.ps1 -BundleDir .\MyAgent-bundle -TargetOrgUrl https://myorg.crm.dynamics.com -AuthIndex 2

.EXAMPLE
    .\install.ps1 -TargetOrgUrl https://myorg.crm.dynamics.com
    # Uses the current directory as the bundle folder
#>

[CmdletBinding()]
param(
    [string] $BundleZip    = "",
    [string] $BundleDir    = "",
    [Parameter(Mandatory)]
    [string] $TargetOrgUrl,
    [switch] $WhatIf,
    [int]    $AuthIndex    = 1,
    [string] $PacExe       = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helper output functions
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Normalise org URL (strip trailing slash)
# ---------------------------------------------------------------------------
$OrgNoTrail = $TargetOrgUrl.TrimEnd("/")

# ---------------------------------------------------------------------------
# Auto-detect pac.exe
# ---------------------------------------------------------------------------
if (-not $PacExe) {
    $PacExe = (Get-Command "pac" -ErrorAction SilentlyContinue)?.Source
    if (-not $PacExe) {
        $PacExe = Get-ChildItem "$env:USERPROFILE\.nuget\packages\microsoft.powerapps.cli" `
            -Filter "pac.exe" -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $PacExe) {
        Write-Error "pac CLI not found. Install: https://aka.ms/PowerPlatformCLI"
    }
}
INFO "pac.exe: $PacExe"

# ---------------------------------------------------------------------------
# Resolve the Power Platform environment GUID for an org URL.
# The Copilot Studio URL needs the environment ID (a GUID), NOT the org-url host prefix
# (e.g. "org07697283"). We map the org URL to its environment GUID via `pac env list`.
# Returns $null if it cannot be resolved (caller falls back to a generic instruction).
# ---------------------------------------------------------------------------
function Resolve-EnvId {
    param([string]$OrgUrl, [string]$PacExePath, [int]$AuthIdx)
    try {
        & $PacExePath auth select --index $AuthIdx | Out-Null
        $orgHost = ([Uri]$OrgUrl).Host
        foreach ($ln in (& $PacExePath env list 2>$null)) {
            if ($ln -match [regex]::Escape($orgHost) -and
                $ln -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
                return $Matches[1]
            }
        }
    } catch {}
    return $null
}

# ---------------------------------------------------------------------------
# Resolve bundle directory
# ---------------------------------------------------------------------------
Step "Resolving bundle"

$tempExtractDir = $null   # track so we can clean it up at the end

if ($BundleZip) {
    if (-not (Test-Path $BundleZip)) {
        Write-Error "BundleZip not found: $BundleZip"
    }
    $tempExtractDir = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-bundle-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempExtractDir | Out-Null
    INFO "Extracting $BundleZip to $tempExtractDir"
    Expand-Archive -Path $BundleZip -DestinationPath $tempExtractDir -Force
    $BundleDir = $tempExtractDir
}
elseif (-not $BundleDir) {
    $BundleDir = "."
}

$BundleDir = (Resolve-Path $BundleDir).Path
INFO "Bundle dir: $BundleDir"

# Validate required files
$zipPath      = Join-Path $BundleDir "agent.zip"
$manifestPath = Join-Path $BundleDir "manifest.json"

if (-not (Test-Path $zipPath)) {
    Write-Error "agent.zip not found in bundle directory: $BundleDir"
}
if (-not (Test-Path $manifestPath)) {
    Write-Error "manifest.json not found in bundle directory: $BundleDir"
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
OK "Bundle validated — agent schema: $($manifest.agentSchema)"

# ── -WhatIf: preview the plan, then stop without changing anything ─────────────
if ($WhatIf) {
    # NOTE: do NOT write `$x = if (...) { @() } else { @() }` — an if-block that outputs an empty
    # array collapses to $null, which then throws on .Count under StrictMode. Pre-assign instead.
    $seedT = @();   if ($manifest.PSObject.Properties["seedTables"])         { $seedT  = @($manifest.seedTables) }
    $skillsW = @(); if ($manifest.PSObject.Properties["skillsWithAssets"])   { $skillsW = @($manifest.skillsWithAssets) }
    $conns = @();   if ($manifest.PSObject.Properties["connectorsRequired"] -and $manifest.connectorsRequired) { $conns = @($manifest.connectorsRequired) }
    Write-Host ""
    Write-Host "  DRY RUN (-WhatIf): here's what install WOULD do to" -ForegroundColor Cyan
    Write-Host "  $OrgNoTrail" -ForegroundColor Cyan
    Write-Host "  (nothing below is actually changed)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "   1. Import the agent '$($manifest.agentName)' and all its parts (tools, skills, flows, knowledge, test cases)."
    if ($seedT.Count -gt 0) {
        Write-Host "   2. Recreate $($seedT.Count) custom table(s) and add one sample row each (only if the table is empty):"
        $seedT | ForEach-Object { Write-Host "        - $($_.logical)" }
    } else { Write-Host "   2. No custom tables to recreate." }
    if ($skillsW.Count -gt 0) {
        Write-Host "   3. Ask you to re-upload $($skillsW.Count) code-file skill(s) once in Copilot Studio:"
        $skillsW | ForEach-Object { Write-Host "        - $(if ($_.PSObject.Properties['skill']) { $_.skill } else { $_ })" }
    } else { Write-Host "   3. No code-file skills to re-upload." }
    if ($conns.Count -gt 0) {
        Write-Host "   4. Tell you to activate the agent's flow(s) (add a connection + turn on) for:"
        $conns | ForEach-Object { Write-Host "        - $_" }
    } else { Write-Host "   4. No connector flows to activate." }
    Write-Host "   5. Open the agent so you can click Publish."
    Write-Host ""
    OK "Dry run complete — no changes made. Re-run without -WhatIf to install."
    if ($tempExtractDir -and (Test-Path $tempExtractDir)) { Remove-Item $tempExtractDir -Recurse -Force }
    return
}

# Preflight the Dataverse token now (before the long import) so first-run auth problems surface
# immediately with clear guidance rather than after pac runs. Reused for verification + seeding.
$token  = Get-DvToken -OrgUrl $OrgNoTrail
$verHdr = @{ Authorization = "Bearer $token"; Accept = "application/json" }

# ---------------------------------------------------------------------------
# Step 1 — pac solution import
# ---------------------------------------------------------------------------
Step "Step 1 — Importing Dataverse solution"

INFO "Selecting pac auth index $AuthIndex"
& $PacExe auth select --index $AuthIndex | Out-Null

INFO "Running: pac solution import --path $zipPath --environment $OrgNoTrail"
$importOut = & $PacExe solution import --path $zipPath --environment $OrgNoTrail 2>&1
$importExit = $LASTEXITCODE
$importOut | ForEach-Object { INFO $_ }

# Do NOT trust pac's exit code: pac 2.8.1 can print "Error: ... cannot be imported ... missing
# dependencies" and STILL return exit code 0. Detect failure from the output text AND verify the
# bot actually landed in Dataverse. Either signal failing = hard stop.
$importText = ($importOut | Out-String)
$importFailed = ($importExit -ne 0) -or ($importText -match 'cannot be imported|Missing dependenc|FAILURE|^\s*Error:')

INFO "Verifying the agent actually imported (querying Dataverse)..."
$verBot   = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots?`$filter=schemaname eq '$($manifest.agentSchema)'&`$select=botid,name" -Headers $verHdr).value | Select-Object -First 1

if ($importFailed -or -not $verBot) {
    Write-Host ""
    Write-Host "  ===========================================================" -ForegroundColor Red
    Write-Host "  SOLUTION IMPORT FAILED -- the agent was NOT installed." -ForegroundColor Red
    Write-Host "  ===========================================================" -ForegroundColor Red
    if ($importText -match 'Missing dependenc|cannot be imported') {
        Write-Host "  Cause: the agent depends on something that does not exist in the target" -ForegroundColor Yellow
        Write-Host "  environment (often a Dataverse table or connector a flow uses). The relevant" -ForegroundColor Yellow
        Write-Host "  pac error is above -- look for 'Required type=... schemaName=...'." -ForegroundColor Yellow
        Write-Host "  Fix: create/import that dependency in the target first, then re-run install." -ForegroundColor Yellow
    } else {
        Write-Host "  See the pac output above for the specific error." -ForegroundColor Yellow
    }
    Write-Error "pac solution import did not produce the agent (schema '$($manifest.agentSchema)') in the target. Aborting."
}
OK "pac solution import verified -- bot present: $($verBot.name) ($($verBot.botid))"

# ---------------------------------------------------------------------------
# Step 1b — Seed custom tables (make the sample usable immediately)
# ---------------------------------------------------------------------------
# The bundle may include custom Dataverse tables the agent's flows use. Solution import recreates
# the table definitions; here we add one sample row per table IF it is currently empty, so the
# installed sample has realistic data to work with. Best-effort and NON-FATAL: a failed seed never
# aborts the install (the table and agent are already in place).
$seedTables = @()
if ($manifest.PSObject.Properties["seedTables"]) { $seedTables = @($manifest.seedTables) }
if ($seedTables.Count -gt 0) {
    Step "Step 1b — Seeding $($seedTables.Count) custom table(s) with sample data"
    $seedToken = (az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json).accessToken
    $seedDv = @{ Authorization="Bearer $seedToken"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json" }
    foreach ($tbl in $seedTables) {
        try {
            if (-not $tbl.hasSeed) { INFO "  '$($tbl.logical)': no seed row in bundle — skipping"; continue }
            $existing = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/$($tbl.setName)?`$top=1&`$select=$($tbl.primaryName)" -Headers $seedDv).value
            if ($existing.Count -gt 0) { INFO "  '$($tbl.logical)': already has data — not seeding"; continue }
            $seedFile = Join-Path $BundleDir "seed-data\$($tbl.logical).json"
            if (-not (Test-Path $seedFile)) { INFO "  '$($tbl.logical)': seed file missing — skipping"; continue }
            $seedBody = Get-Content $seedFile -Raw
            Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/$($tbl.setName)" -Method POST -Headers $seedDv -Body $seedBody | Out-Null
            OK "  '$($tbl.logical)': seeded 1 sample row"
        } catch {
            WARN "  '$($tbl.logical)': could not seed ($($_.Exception.Message)) — add a row manually if needed"
        }
    }
}

# ---------------------------------------------------------------------------
# Step 2 — Fix skills with assets
# ---------------------------------------------------------------------------
# Step 2 — Handle skills with assets (require manual upload — no silent degradation)
# ---------------------------------------------------------------------------
# Skills uploaded as ZIPs (with Python/binary assets) store their instructions in a
# bundle blob in Azure storage, referenced by a bic:bundle= token in the DV record.
# This blob does NOT transfer through solution import — it is environment-specific.
#
# What NOT to do: silently patch the skill to use inline markdown instructions.
# That causes the model to call a "skill" that cannot actually execute Python code,
# producing misleading or broken behavior without any warning.
#
# What we do instead:
#   1. Detect broken skills (data contains bic:bundle= after import)
#   2. Rebuild the skill ZIP from the bundle assets in the exported bundle
#   3. Print clear mandatory steps for the user to re-upload via the CS UI
#   4. The skill remains in its broken state until the user completes the upload
#      (the CS UI will show it as needing attention — honest, not silent)
# ---------------------------------------------------------------------------
$skillsWithAssets = @()
if ($manifest.PSObject.Properties["skillsWithAssets"]) {
    $skillsWithAssets = @($manifest.skillsWithAssets)
}

if ($skillsWithAssets.Count -gt 0) {
    Step "Step 2 — Skills with assets require manual upload ($($skillsWithAssets.Count) skill(s))"

    INFO "Acquiring Dataverse access token"
    $tokenObj = az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json
    $token    = $tokenObj.accessToken
    $dv = @{
        Authorization      = "Bearer $token"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        Accept             = "application/json"
        "Content-Type"     = "application/json"
        Prefer             = "return=representation"
    }
    $dvBase = "$OrgNoTrail/api/data/v9.2"

    # Locate the imported bot
    $botFilter = "schemaname eq '$($manifest.agentSchema)'"
    $botResp   = Invoke-RestMethod -Uri "$dvBase/bots?`$filter=$([uri]::EscapeDataString($botFilter))&`$select=botid,name" -Headers $dv
    $bot       = $botResp.value | Select-Object -First 1
    if (-not $bot) {
        WARN "Bot not found in target org — cannot verify skill state. Complete manual upload steps below."
        $botId = "unknown"
    } else {
        $botId = $bot.botid
        OK "Found bot: $($bot.name) ($botId)"

        # Verify skills are actually broken (confirm bic:bundle= is present after import)
        $compFilter   = "_parentbotid_value eq '$botId' and componenttype eq 9"
        $compResp     = Invoke-RestMethod -Uri "$dvBase/botcomponents?`$filter=$([uri]::EscapeDataString($compFilter))&`$select=botcomponentid,name,data" -Headers $dv
        $brokenSkills = @($compResp.value | Where-Object { $_.data -like "*bic:bundle=*" })
        INFO "$($brokenSkills.Count) skill(s) confirmed broken (bic:bundle= token present, bundle not in target)"
    }

    $envId    = Resolve-EnvId -OrgUrl $OrgNoTrail -PacExePath $PacExe -AuthIdx $AuthIndex
    if (-not $envId) { $envId = $OrgNoTrail -replace "https://", "" -replace "\.crm\.dynamics\.com", "" }
    $agentUrl = "https://copilotstudio.microsoft.com/environments/$envId/agents/$botId"

    Write-Host ""
    Write-Host "  =============================================================" -ForegroundColor Red
    Write-Host "  ACTION REQUIRED: ZIP-packaged skills need a one-time re-upload" -ForegroundColor Red
    Write-Host "  =============================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  These skills were uploaded as a .zip bundling Python + SKILL.md. Their code bundle" -ForegroundColor Yellow
    Write-Host "  lives in the SOURCE environment's storage and cannot transfer, so each skill arrives" -ForegroundColor Yellow
    Write-Host "  empty and Copilot Studio will flag it. Re-upload the ZIP once to recreate it here." -ForegroundColor Yellow
    Write-Host "  (Skills whose code is written INLINE in the skill text transfer fine -- nothing to do.)" -ForegroundColor DarkGray
    Write-Host ""

    # Write skill ZIPs to a stable location the user can access after the script completes.
    # When -BundleZip was used, the bundle was extracted to a temp dir that gets cleaned up.
    # Use the same directory as the original bundle ZIP (or current dir if -BundleDir was used).
    $skillZipOutputDir = if ($BundleZip) { Split-Path (Resolve-Path $BundleZip).Path -Parent } else { $BundleDir }
    $reuploadZips = @()
    foreach ($skillEntry in $skillsWithAssets) {
        $skillName     = if ($skillEntry.PSObject.Properties["skill"]) { $skillEntry.skill } else { $skillEntry }
        $skillAssetDir = Join-Path $BundleDir "skills-with-assets" $skillName
        $skillZipPath  = Join-Path $skillZipOutputDir "$skillName-skill.zip"

        if (Test-Path $skillAssetDir) {
            if (Test-Path $skillZipPath) { Remove-Item $skillZipPath -Force }
            Compress-Archive -Path (Join-Path $skillAssetDir "*") -DestinationPath $skillZipPath -Force
            OK "  Built ZIP: $skillZipPath"
            $reuploadZips += @{ name = $skillName; zip = $skillZipPath }
        } else {
            WARN "  No assets folder found for '$skillName' in bundle — re-download the bundle and retry."
        }
    }

    Write-Host ""
    Write-Host "  For each skill below, upload the ZIP through Copilot Studio:" -ForegroundColor Cyan
    $i = 1
    foreach ($r in $reuploadZips) {
        Write-Host "  Skill $i : $($r.name)" -ForegroundColor White
        Write-Host "    ZIP   : $($r.zip)" -ForegroundColor White
        $i++
    }
    Write-Host ""
    Write-Host "  Steps (repeat for each skill above):" -ForegroundColor Cyan
    Write-Host "    1. Open your agent: $agentUrl" -ForegroundColor White
    Write-Host "    2. In the right panel, click the skill name to open it." -ForegroundColor White
    Write-Host "    3. Click the three-dot menu on the skill card > Replace / Edit skill." -ForegroundColor White
    Write-Host "    4. Upload the ZIP file shown above for that skill." -ForegroundColor White
    Write-Host "    5. Save the agent." -ForegroundColor White
    Write-Host ""

    try { Start-Process $agentUrl; INFO "Opening agent in browser..." }
    catch { WARN "Could not open browser. Navigate manually: $agentUrl" }

    Write-Host ""
    WARN "install.ps1 will continue, but the agent is NOT fully functional until skills are uploaded."
    Write-Host "  Press Enter when you have uploaded all skills and saved the agent, or Ctrl+C to finish now." -ForegroundColor Yellow
    Read-Host | Out-Null
    OK "Continuing — verify the agent works end-to-end in Copilot Studio."

} else {
    Step "Step 2 — No skills-with-assets (skipping)"
    OK "Nothing to repair"
}
# ---------------------------------------------------------------------------
# Step 3 — Summary
# ---------------------------------------------------------------------------
Step "Step 3 — Summary"

# Determine bot ID (may already be set from Step 2; re-query if not)
if (-not (Get-Variable -Name "botId" -ErrorAction SilentlyContinue) -or -not $botId) {
    $botId = "<run Step 2 to resolve>"
    try {
        $tokenObj2  = az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json
        $dvBase2    = "$OrgNoTrail/api/data/v9.2"
        $hdrs2      = @{ Authorization = "Bearer $($tokenObj2.accessToken)"; Accept = "application/json" }
        $botFilter2 = "schemaname eq '$($manifest.agentSchema)'"
        $botUrl2    = "$dvBase2/bots?`$filter=$([uri]::EscapeDataString($botFilter2))&`$select=botid"
        $botResp2   = Invoke-RestMethod -Uri $botUrl2 -Headers $hdrs2 -Method Get
        $botId      = ($botResp2.value | Select-Object -First 1).botid
    }
    catch { $botId = "<could not resolve — check org URL and auth>" }
}

$envIdSummary = Resolve-EnvId -OrgUrl $OrgNoTrail -PacExePath $PacExe -AuthIdx $AuthIndex
if (-not $envIdSummary) { $envIdSummary = $OrgNoTrail -replace "https://", "" -replace "\.crm\.dynamics\.com", "" }
$csUrl        = "https://copilotstudio.microsoft.com/environments/$envIdSummary/agents/$botId"

Write-Host ""
Write-Host "  Bot ID             : $botId" -ForegroundColor White
Write-Host "  Copilot Studio URL : $csUrl" -ForegroundColor White
Write-Host ""

Write-Host "  What was done:" -ForegroundColor Cyan
Write-Host "    [x] agent.zip imported via pac solution import" -ForegroundColor Green
Write-Host "    [x] Bot configuration, flows, tools, knowledge, eval cases restored by solution" -ForegroundColor Green

if ($skillsWithAssets.Count -gt 0) {
    Write-Host "    [!] Skills-with-assets: manual upload required — see instructions above" -ForegroundColor Yellow
}
else {
    Write-Host "    [-] No skills-with-assets to repair" -ForegroundColor DarkGray
}

# Connection wiring instructions.
# NOTE: the manifest key is "connectorsRequired" (written by export.ps1). Reading the wrong key
# here previously meant this entire ACTION REQUIRED block was silently skipped, so users were
# never told to wire connections and their flows stayed dead.
$connectors = @()
if ($manifest.PSObject.Properties["connectorsRequired"] -and $manifest.connectorsRequired) {
    $connectors = @($manifest.connectorsRequired)
}

if ($connectors.Count -gt 0) {
    Write-Host ""
    WARN "Activate the agent's flows (connection + turn on)"
    Write-Host "    The flows imported already linked to the agent -- they just arrive turned off with" -ForegroundColor Yellow
    Write-Host "    no connection. To activate:" -ForegroundColor Yellow
    Write-Host "      1. Open https://make.powerautomate.com and switch to environment: $envIdSummary" -ForegroundColor White
    Write-Host "      2. Open each imported flow; it shows a connection that needs fixing." -ForegroundColor White
    Write-Host "      3. Assign or create a connection for each connector below, then Save:" -ForegroundColor White
    foreach ($connector in $connectors) {
        $displayName = if ($connector.PSObject.Properties["displayName"]) { $connector.displayName } else { $connector }
        Write-Host "           - $displayName" -ForegroundColor White
    }
    Write-Host "      4. Turn the flow On." -ForegroundColor White
    Write-Host "      5. Return to Copilot Studio and verify the agent runs end-to-end." -ForegroundColor White
}

# Temp dir cleanup
if ($tempExtractDir -and (Test-Path $tempExtractDir)) {
    INFO "Cleaning up temp extract dir: $tempExtractDir"
    Remove-Item $tempExtractDir -Recurse -Force
    OK "Temp dir removed"
}

Write-Host ""
OK "install.ps1 complete."
