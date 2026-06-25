<#
.SYNOPSIS
    Export a Modern Copilot Studio agent as a self-contained distributable package.

.DESCRIPTION
    Produces a single bundle ZIP:
      {AgentName}-bundle.zip
        agent.zip                    pac solution export (all components, flows, knowledge)
        skills-with-assets/          binary files for ZIP-uploaded skills with Python assets
        manifest.json                inventory — install.ps1 reads this to know what to do

    The bundle ZIP is self-contained: share it, commit it to GitHub, or email it.
    Recipients run install.ps1 pointing at the bundle ZIP — no other files needed.

    WHY THIS SCRIPT EXISTS
    ─────────────────────
    pac solution export alone produces an incomplete ZIP unless the agent's botcomponents
    are explicitly added to the solution first. Copilot Studio ALWAYS creates new tools,
    skills, and knowledge sources in the Default Solution, regardless of which named
    solution the agent belongs to. A naive export misses them entirely.

    This script:
      1. Validates the agent is a Modern Copilot Studio agent (cliagent-1.0.0)
      2. Walks the agent's own component graph (same approach pac clone uses)
      3. Adds each component surgically to the distribution solution
         — NOT AddRequiredComponents=true, which is too broad and pulls in foreign components
      4. Exports the solution ZIP
      5. Separately exports binary skill assets (type-14 filedata components)
         because the solution ZIP includes the file records but the bundle blob
         that references them is NOT reconstituted on import without a re-upload

    WHAT THE RESULTING BUNDLE CONTAINS ({AgentName}-bundle.zip)
    ────────────────────────────────────────────────────────────
    agent.zip
      bots/{schema}/                   Bot record + configuration.json (instructions, model)
      botcomponents/{schema}.*/        All tools, skills, connection refs, eval cases
      Workflows/                       Power Automate flow definitions
    
    skills-with-assets/{skill-name}/   One folder per ZIP-uploaded skill (Python/binary)
      SKILL.md                         Skill instructions (used for automated inline fix)
      *.py / *.png / etc.              Binary assets (used for optional manual re-upload)
    
    manifest.json                      install.ps1 reads this — no parameters needed

    PREREQUISITES
    ─────────────
    pac CLI:  https://aka.ms/PowerPlatformCLI
    az CLI:   https://aka.ms/installazurecliwindows
    pac auth: pac auth create --environment https://yourorg.crm.dynamics.com
    az login: az login (with Dataverse access to source env)

.PARAMETER SourceOrgUrl
    Dataverse org URL for the source environment.

.PARAMETER BotId
    Dataverse bot GUID (find in Copilot Studio → agent URL, or Settings → Details).

.PARAMETER SolutionName
    Unique name for the distribution solution (created if it doesn't exist).

.PARAMETER PublisherName
    Publisher unique name for the distribution solution.

.PARAMETER OutputDir
    Folder where agent.zip, skills-with-assets/, and manifest.json will be written.
    Defaults to current directory.

.PARAMETER AuthIndex
    pac auth index for the source environment.

.PARAMETER PacExe
    Path to pac.exe. Auto-detected from PATH or NuGet cache if not specified.

.EXAMPLE
    .\export.ps1 `
      -SourceOrgUrl "https://myorg.crm.dynamics.com" `
      -BotId        "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
      -SolutionName "MyAgentSample" `
      -PublisherName "MyPublisher"
#>
param(
    [Parameter(Mandatory)][string] $SourceOrgUrl,
    [Parameter(Mandatory)][string] $BotId,
    [Parameter(Mandatory)][string] $SolutionName,
    [Parameter(Mandatory)][string] $PublisherName,
    [string] $OutputDir  = ".",
    [int]    $AuthIndex  = 1,
    [string] $PacExe     = ""
)

$ErrorActionPreference = "Stop"
$OrgNoTrail = $SourceOrgUrl.TrimEnd("/")
# Resolve to absolute path — [System.IO.File]::WriteAllBytes requires absolute paths
$OutputDir  = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)

# Resolve pac.exe
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
Write-Host "║  Modern Agent Export — Solution Path     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Source : $OrgNoTrail"
Write-Host "  BotId  : $BotId"
Write-Host "  Solution: $SolutionName"
Write-Host ""

# ── Acquire DV token ──────────────────────────────────────────────────────────
Step "Acquiring Dataverse token..."
$token = (az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json).accessToken
$dv = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json" }
OK "Token acquired"

# ── Step 1: Validate Modern agent ─────────────────────────────────────────────
Step "Step 1 — Validate Modern Copilot Studio agent (cliagent-* template)"
$bot = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots($BotId)?`$select=botid,name,schemaname,template,configuration" -Headers $dv
$cfg = $bot.configuration | ConvertFrom-Json

# Hard requirement: cliagent-* template prefix.
# The template field identifies the agent architecture. Classic agents use default-2.x.x.
# cliagent-* agents use instructions + tools (no topics) with bot.configuration as authoritative.
# We check the prefix rather than exact version so future cliagent-1.0.1 etc. are accepted.
if ($bot.template -notlike "cliagent-*") {
    Write-Error "template='$($bot.template)' — expected 'cliagent-*'. Classic agents (default-2.x.x) use a different workflow; this toolkit is for cliagent-* agents only."
}

# Corroborate: cliagent agents have agentSettings in bot.configuration; classic agents do not.
if (-not $cfg.agentSettings) {
    WARN "bot.configuration has no 'agentSettings' block — this agent may be Classic despite the template value. Export will proceed but verify after import."
}

# Informational: recognizer type. Both CLICopilotRecognizer (NGO) and GenerativeAIRecognizer
# (CGO) are valid in cliagent containers. Export behavior is identical for both.
$recognizerKind = $cfg.recognizer.'$kind'
if ($recognizerKind -eq "CLICopilotRecognizer") {
    INFO "Recognizer: CLICopilotRecognizer (NGO)"
} elseif ($recognizerKind -eq "GenerativeAIRecognizer") {
    INFO "Recognizer: GenerativeAIRecognizer (CGO in cliagent container)"
} else {
    WARN "Recognizer: $recognizerKind (unrecognized — export will proceed)"
}

# Soft warning: custom topics suggest a Classic/Topics agent
$customTopics = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$BotId' and componenttype eq 2&`$select=name" -Headers $dv).value
if ($customTopics.Count -gt 0) {
    WARN "$($customTopics.Count) custom topic(s) found — this looks like a Classic (topics-based) agent."
    WARN "This toolkit is designed for instructions-based agents. Topics will export, but test carefully after import."
}

OK "$($bot.name) ($($bot.schemaname)) — template: $($bot.template) ✓"

# ── Step 2: Find or create distribution solution ──────────────────────────────
Step "Step 2 — Find or create distribution solution '$SolutionName'"
$existingSol = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/solutions?`$filter=uniquename eq '$SolutionName'&`$select=solutionid,uniquename" -Headers $dv).value
if ($existingSol.Count -gt 0) {
    $solId = $existingSol[0].solutionid
    WARN "Solution already exists: $solId — reusing"
} else {
    $pub = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/publishers?`$filter=uniquename eq '$PublisherName'&`$select=publisherid" -Headers $dv).value
    if (-not $pub) { Write-Error "Publisher '$PublisherName' not found. Run: pac solution create-settings" }
    $sol = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/solutions" -Method POST -Headers (@{} + $dv + @{Prefer="return=representation"}) -Body (@{
        uniquename   = $SolutionName
        friendlyname = $SolutionName
        version      = "1.0.0.1"
        "publisherid@odata.bind" = "/publishers($($pub[0].publisherid))"
    } | ConvertTo-Json)
    $solId = $sol.solutionid
    OK "Solution created: $solId"
}

# ── Step 3: Add ALL agent components to solution (surgical, not AddRequiredComponents) ──
Step "Step 3 — Add agent components to solution (surgical graph traversal)"
INFO "Walking agent component graph — same approach as pac copilot clone"

# Helper: add component to solution, ignore if already present
function Add-ToSolution([string]$componentId, [int]$componentType) {
    try {
        Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/AddSolutionComponent" -Method POST -Headers $dv -Body (@{
            ComponentId = $componentId; ComponentType = $componentType
            SolutionUniqueName = $SolutionName; AddRequiredComponents = $false; DoNotIncludeSubcomponents = $false
        } | ConvertTo-Json) | Out-Null
    } catch {} # already in solution = OK
}

# Add the bot itself (type 10185)
Add-ToSolution $BotId 10185
INFO "Added bot"

# Get all botcomponents (type 9 = tools/skills, type 14 = file assets, type 15 = gpt config)
$allBotComps = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$BotId'&`$select=botcomponentid,name,componenttype,data" -Headers $dv).value
$flowIds = @()
foreach ($comp in $allBotComps) {
    Add-ToSolution $comp.botcomponentid 10186
    # Track flow references
    if ($comp.data -match "(?m)^workflowId: ([a-f0-9\-]{36})") { $flowIds += $Matches[1] }
    if ($comp.data -match "(?m)^  flowId: ([a-f0-9\-]{36})")   { $flowIds += $Matches[1] }
    # For skills with assets, also add type-14 children
    if ($comp.data -like "*bic:bundle=*") {
        $children = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotcomponentid_value eq '$($comp.botcomponentid)'&`$select=botcomponentid,filedata_name" -Headers $dv).value
        foreach ($child in $children) { Add-ToSolution $child.botcomponentid 10186 }
        INFO "Skill with assets '$($comp.name)': added $($children.Count) file component(s)"
    }
}
OK "Added $($allBotComps.Count) botcomponents"

# Add workflows (type 29)
$flowIds = $flowIds | Sort-Object -Unique
foreach ($fid in $flowIds) {
    Add-ToSolution $fid 29
}
OK "Added $($flowIds.Count) flow(s)"

# Add connection references (type 10132) — enumerate from workflow definitions
$connRefNames = @()
foreach ($fid in $flowIds) {
    try {
        $wf = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/workflows($fid)?`$select=clientdata" -Headers $dv
        ($wf.clientdata | ConvertFrom-Json).properties.connectionReferences.PSObject.Properties | ForEach-Object {
            $connRefNames += $_.Value.connection.connectionReferenceLogicalName
        }
    } catch {}
}
$connRefNames = $connRefNames | Sort-Object -Unique | Where-Object { $_ }
foreach ($crName in $connRefNames) {
    $cr = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/connectionreferences?`$filter=connectionreferencelogicalname eq '$crName'&`$select=connectionreferenceid" -Headers $dv).value
    if ($cr) { Add-ToSolution $cr[0].connectionreferenceid 10132 }
}
OK "Added $($connRefNames.Count) connection reference(s)"

# ── Step 4: pac solution export ───────────────────────────────────────────────
Step "Step 4 — pac solution export"
& $PacExe auth select --index $AuthIndex | Out-Null
$zipPath = Join-Path $OutputDir "agent.zip"
& $PacExe solution export --name $SolutionName --path $zipPath --environment $OrgNoTrail --overwrite 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { Write-Error "pac solution export failed" }
OK "agent.zip ($([Math]::Round((Get-Item $zipPath).Length/1KB))KB)"

# ── Step 5: Export binary skill assets (skills with assets) ───────────────────
Step "Step 5 — Export binary skill assets (bic:bundle= skills)"
$skillsWithAssets = $allBotComps | Where-Object { $_.data -like "*bic:bundle=*" }
INFO "Skills with assets: $($skillsWithAssets.Count)"
$skillManifest = @()

foreach ($skill in $skillsWithAssets) {
    $skillDir = Join-Path $OutputDir "skills-with-assets\$($skill.name)"
    New-Item -ItemType Directory -Force -Path $skillDir | Out-Null

    $children = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotcomponentid_value eq '$($skill.botcomponentid)'&`$select=botcomponentid,name,filedata_name" -Headers $dv).value
    $files = @()
    foreach ($child in $children) {
        $fileName = $child.filedata_name
        if (-not $fileName) { $fileName = $child.name -replace '^\./',''}
        # Download binary via file download endpoint
        $filePath = Join-Path $skillDir $fileName
        try {
            $fileBytes = (Invoke-WebRequest -Uri "$OrgNoTrail/api/data/v9.2/botcomponents($($child.botcomponentid))/filedata/`$value" `
                -Headers @{ Authorization="Bearer $token" } -UseBasicParsing).Content
            [System.IO.File]::WriteAllBytes($filePath, $fileBytes)
            OK "  Skill '$($skill.name)': $fileName ($($fileBytes.Length) bytes)"
            $files += $fileName
        } catch {
            # Fallback: read the full record and extract filedata as base64
            try {
                $rec = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents($($child.botcomponentid))?`$select=filedata" -Headers $dv
                if ($rec.filedata) {
                    $bytes = [Convert]::FromBase64String($rec.filedata)
                    [System.IO.File]::WriteAllBytes($filePath, $bytes)
                    OK "  Skill '$($skill.name)': $fileName ($($bytes.Length) bytes, base64)"
                    $files += $fileName
                }
            } catch { WARN "  Could not download $fileName for skill '$($skill.name)'" }
        }
    }
    $skillManifest += @{ skill = $skill.name; files = $files }
}

# ── Step 6: Write manifest.json ───────────────────────────────────────────────
Step "Step 6 — Writing manifest.json"
$manifest = @{
    exportedAt      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    agentName       = $bot.name
    agentSchema     = $bot.schemaname
    template        = $bot.template
    sourceOrg       = $OrgNoTrail
    skillsWithAssets = $skillManifest
    connectorsRequired = $connRefNames
    importNotes = @(
        "Run install.ps1 to import this bundle.",
        "install.ps1 will: (1) pac solution import, (2) fix skills with assets.",
        "After import, manually wire connections for: $($connRefNames -join ', ')."
    )
} | ConvertTo-Json -Depth 5
$manifest | Set-Content (Join-Path $OutputDir "manifest.json") -Encoding UTF8
OK "manifest.json written"

# ── Step 7: Package everything into a single bundle ZIP ───────────────────────
Step "Step 7 — Creating bundle ZIP"
$bundleZipName = "$($bot.name -replace '[^\w\-]','-')-bundle.zip"
$bundleZipPath = Join-Path $OutputDir $bundleZipName
Remove-Item $bundleZipPath -ErrorAction SilentlyContinue

# Add agent.zip, manifest.json, and skills-with-assets/ to one archive
$filesToBundle = @(
    (Join-Path $OutputDir "agent.zip"),
    (Join-Path $OutputDir "manifest.json")
)
foreach ($f in $filesToBundle) {
    if (Test-Path $f) { Compress-Archive -Path $f -DestinationPath $bundleZipPath -Update }
}
$skillsDir = Join-Path $OutputDir "skills-with-assets"
if (Test-Path $skillsDir) {
    # Add each skill folder preserving the relative path
    Get-ChildItem $skillsDir -Recurse -File | ForEach-Object {
        $relPath = $_.FullName.Replace($OutputDir + "\", "")
        # Compress-Archive doesn't support relative paths well — use .NET directly
    }
    # Use System.IO.Compression for proper relative paths
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($bundleZipPath, 'Update')
    Get-ChildItem $skillsDir -Recurse -File | ForEach-Object {
        $entryName = $_.FullName.Replace($OutputDir + "\", "") -replace "\\", "/"
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entryName) | Out-Null
    }
    $zip.Dispose()
}

$bundleSize = [Math]::Round((Get-Item $bundleZipPath).Length/1KB)
OK "$bundleZipName ($bundleSize KB)"

# Clean up loose files (agent.zip, manifest.json, skills-with-assets/ now inside bundle)
Remove-Item (Join-Path $OutputDir "agent.zip") -ErrorAction SilentlyContinue
Remove-Item (Join-Path $OutputDir "manifest.json") -ErrorAction SilentlyContinue
Remove-Item $skillsDir -Recurse -Force -ErrorAction SilentlyContinue

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Export Complete                         ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Bundle ZIP : $bundleZipPath" -ForegroundColor Cyan
Write-Host "  Size       : $bundleSize KB"
Write-Host "  Skills w/assets: $($skillsWithAssets.Count)"
Write-Host "  Connectors : $($connRefNames.Count) (need connection wiring after import)"
Write-Host ""
Write-Host "  Share this single file. Recipients run:"
Write-Host "    .\install.ps1 -BundleZip '$bundleZipPath' -TargetOrgUrl <url>" -ForegroundColor Cyan
