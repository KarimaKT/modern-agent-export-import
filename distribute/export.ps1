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
      SKILL.md                         Skill instructions (re-uploaded via CS UI; manual step)
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
    Optional — provide this OR -AgentName. If omitted, the agent is found by -AgentName.

.PARAMETER AgentName
    The agent's display name. Used to look up the agent when -BotId is not given (a friendly
    alternative to hunting for the GUID). If several modern agents share the name, you'll be asked
    to choose (or, non-interactively, given their ids to pass via -BotId).

.PARAMETER SolutionName
    Unique name for the distribution solution (created if it doesn't exist).

.PARAMETER PublisherName
    Publisher unique name OR customization prefix for the distribution solution.

.PARAMETER OutputDir
    Folder where agent.zip, skills-with-assets/, and manifest.json will be written.
    Defaults to current directory.

.PARAMETER AuthIndex
    pac auth index for the source environment.

.PARAMETER PacExe
    Path to pac.exe. Auto-detected from PATH or NuGet cache if not specified.

.EXAMPLE
    # By name (low-code friendly — no GUID needed)
    .\export.ps1 -SourceOrgUrl "https://myorg.crm.dynamics.com" `
      -AgentName "My Agent" -SolutionName "MyAgentSample" -PublisherName "myprefix"

.EXAMPLE
    # By id
    .\export.ps1 `
      -SourceOrgUrl "https://myorg.crm.dynamics.com" `
      -BotId        "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
      -SolutionName "MyAgentSample" `
      -PublisherName "MyPublisher"
#>
param(
    [Parameter(Mandatory)][string] $SourceOrgUrl,
    [string] $BotId      = "",
    [string] $AgentName  = "",
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

if (-not $BotId -and -not $AgentName) {
    Write-Error "Provide either -BotId (the agent's id) or -AgentName (its display name). With -AgentName the script finds the id for you."
}

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

# Friendly preflight: acquire a Dataverse token, but turn the common first-run failures (no Azure
# CLI, not signed in, wrong/unreachable environment URL) into clear, actionable guidance instead of
# a cryptic error. Returns the access token.
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
        if (-not $signedIn) {
            Write-Error "You're not signed in to Azure. Run 'az login' (use the account that can access this environment), then retry."
        }
        Write-Error "Couldn't get access to '$OrgUrl'. Check the environment URL is correct and that your signed-in account has access to that tenant/environment. (az said: $raw)"
    }
    # az issues a token for ANY resource URL without checking it exists, so probe the environment is
    # actually reachable with a quick WhoAmI — turning a wrong URL into clear guidance, not a later
    # cryptic "No such host" failure.
    try {
        Invoke-RestMethod -Uri "$OrgUrl/api/data/v9.2/WhoAmI" -Headers @{ Authorization="Bearer $tok"; Accept="application/json" } -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Couldn't reach the environment at '$OrgUrl'. Check the URL is your Dataverse org URL (like https://yourorg.crm.dynamics.com) and that your account has access. ($($_.Exception.Message))"
    }
    return $tok
}

# Resolve a modern (cliagent-*) agent's BotId from its display name, in the given environment.
# One match -> returns the id. None -> errors with the available names. Many -> interactive pick
# (or, when non-interactive, errors listing the candidates so the caller can pass -BotId).
function Resolve-BotIdByName {
    param([string]$Name, [string]$OrgUrl, [hashtable]$Headers)
    $enc = [uri]::EscapeDataString($Name)
    $found = @((Invoke-RestMethod -Uri "$OrgUrl/api/data/v9.2/bots?`$filter=name eq '$enc'&`$select=botid,name,schemaname,template,modifiedon" -Headers $Headers).value | Where-Object { $_.template -like "cliagent-*" })
    if ($found.Count -eq 1) { return $found[0].botid }
    if ($found.Count -eq 0) {
        $all = @((Invoke-RestMethod -Uri "$OrgUrl/api/data/v9.2/bots?`$select=name,template&`$orderby=name" -Headers $Headers).value | Where-Object { $_.template -like "cliagent-*" })
        Write-Host "  No modern agent named '$Name' in this environment. Available modern agents:" -ForegroundColor Yellow
        $all | ForEach-Object { Write-Host "    - $($_.name)" -ForegroundColor White }
        Write-Error "Agent '$Name' not found. Use one of the names above (exact), or pass -BotId."
    }
    # More than one with the same display name — disambiguate.
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
    $found | ForEach-Object { Write-Host "    $($_.botid)  (modified $($_.modifiedon))" -ForegroundColor White }
    Write-Error "Ambiguous agent name '$Name'. Re-run with -BotId."
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Modern Agent Export — Solution Path     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Source : $OrgNoTrail"
Write-Host "  Solution: $SolutionName"
Write-Host ""

# ── Acquire DV token ──────────────────────────────────────────────────────────
Step "Acquiring Dataverse token..."
$token = Get-DvToken -OrgUrl $OrgNoTrail
$dv = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json" }
OK "Token acquired"

# Resolve agent by name if no id was given.
if (-not $BotId) {
    Step "Finding agent '$AgentName' by name"
    $BotId = Resolve-BotIdByName -Name $AgentName -OrgUrl $OrgNoTrail -Headers $dv
    OK "Resolved to BotId $BotId"
}

# ── Step 1: Validate Modern agent ─────────────────────────────────────────────
Step "Step 1 — Validate Modern Copilot Studio agent (cliagent-* template)"
$bot = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots($BotId)?`$select=botid,name,schemaname,template,configuration" -Headers $dv
# An agent that has never been configured/published has a null configuration — handle it safely
# instead of crashing on ConvertFrom-Json.
$cfg = if ($bot.configuration) { $bot.configuration | ConvertFrom-Json } else { $null }
if (-not $cfg) {
    WARN "This agent has no saved configuration yet (never configured/published). Export will proceed; structure transfers, but there are no instructions/model to carry."
}

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
    # Resolve publisher by uniquename first, then fall back to customization prefix (what most
    # users actually know, e.g. "cr7a0"). This avoids a hard stop when the friendly prefix is passed.
    $pub = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/publishers?`$filter=uniquename eq '$PublisherName'&`$select=publisherid,uniquename" -Headers $dv).value
    if (-not $pub) {
        $pub = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/publishers?`$filter=customizationprefix eq '$PublisherName'&`$select=publisherid,uniquename" -Headers $dv).value
        if ($pub) { INFO "Resolved publisher by prefix '$PublisherName' -> uniquename '$($pub[0].uniquename)'" }
    }
    if (-not $pub) { Write-Error "Publisher '$PublisherName' not found (tried uniquename and customization prefix). List publishers: pac org list, or check PPAC > Solutions > Publishers." }
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

# Helper: add a component to the solution, trying each candidate component-type.
#
# WHY CANDIDATE TYPES: the Dataverse solutioncomponent "componenttype" enum for bots and
# botcomponents was renumbered across platform versions. Older environments use bot=10185 /
# botcomponent=10186 / connectionreference=10132; newer environments use 10223 / 10224 / 10161.
# A hardcoded value silently 404s on the "wrong" platform — and because the failure used to be
# swallowed, the export produced an EMPTY bundle with a green "success" message. This helper
# tries each known type, treats an "already present" error as success, and THROWS if every
# candidate fails so the problem is loud, not silent.
#
# Returns the component-type that worked (so callers can count real successes).
function Add-ToSolution {
    param([string]$ComponentId, [int[]]$CandidateTypes, [string]$Label = "component")
    $lastErr = $null
    foreach ($ct in $CandidateTypes) {
        try {
            Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/AddSolutionComponent" -Method POST -Headers $dv -Body (@{
                ComponentId = $ComponentId; ComponentType = $ct
                SolutionUniqueName = $SolutionName; AddRequiredComponents = $false; DoNotIncludeSubcomponents = $false
            } | ConvertTo-Json) | Out-Null
            return $ct
        } catch {
            $code = $null
            try { $code = [int]$_.Exception.Response.StatusCode.value__ } catch {}
            $msg = $_.ErrorDetails.Message
            if ($code -eq 404) { $lastErr = "HTTP 404 — componenttype $ct not valid in this environment"; continue }
            # Any non-404 error on a valid type almost always means "already a component of the
            # solution" — that is the desired end state, so treat it as success.
            if ($msg -match 'already|duplicate|0x80060889|0x80048403') { return $ct }
            $lastErr = "HTTP $code — $msg"; continue
        }
    }
    throw "Failed to add $Label ($ComponentId) to solution '$SolutionName'. Last error: $lastErr"
}

# Component-type candidates per logical kind (older platform value first, newer second).
$TYPE_BOT     = @(10185, 10223)
$TYPE_BOTCOMP = @(10186, 10224)
$TYPE_FLOW    = @(29)
$TYPE_CONNREF = @(10132, 10161)

# Add the bot itself
$resolvedBotType = Add-ToSolution $BotId $TYPE_BOT "bot"
INFO "Added bot (componenttype $resolvedBotType)"

# Get all botcomponents (type 9 = tools/skills, type 14 = file assets, type 15 = gpt config)
$allBotComps = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$BotId'&`$select=botcomponentid,name,componenttype,data" -Headers $dv).value
$flowIds = @()
$addedBotComps = 0
foreach ($comp in $allBotComps) {
    Add-ToSolution $comp.botcomponentid $TYPE_BOTCOMP "botcomponent '$($comp.name)'" | Out-Null
    $addedBotComps++
    # Track flow references
    if ($comp.data -match "(?m)^workflowId: ([a-f0-9\-]{36})") { $flowIds += $Matches[1] }
    if ($comp.data -match "(?m)^  flowId: ([a-f0-9\-]{36})")   { $flowIds += $Matches[1] }
    # For skills with assets, also add type-14 children
    if ($comp.data -like "*bic:bundle=*") {
        $children = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotcomponentid_value eq '$($comp.botcomponentid)'&`$select=botcomponentid,filedata_name" -Headers $dv).value
        foreach ($child in $children) { Add-ToSolution $child.botcomponentid $TYPE_BOTCOMP "skill file" | Out-Null; $addedBotComps++ }
        INFO "Skill with assets '$($comp.name)': added $($children.Count) file component(s)"
    }
}
OK "Added $addedBotComps botcomponents"

# Add workflows (type 29)
$flowIds = $flowIds | Sort-Object -Unique
foreach ($fid in $flowIds) {
    Add-ToSolution $fid $TYPE_FLOW "flow" | Out-Null
}
OK "Added $($flowIds.Count) flow(s)"

# Add connection references (type 10132 / 10161) — enumerate from workflow definitions
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
$addedConnRefs = 0
foreach ($crName in $connRefNames) {
    $cr = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/connectionreferences?`$filter=connectionreferencelogicalname eq '$crName'&`$select=connectionreferenceid" -Headers $dv).value
    if ($cr) { Add-ToSolution $cr[0].connectionreferenceid $TYPE_CONNREF "connection reference '$crName'" | Out-Null; $addedConnRefs++ }
}
OK "Added $addedConnRefs connection reference(s)"

# ── Custom table dependencies — make the sample self-contained ────────────────
# If a flow reads/writes a CUSTOM Dataverse table, the agent depends on that table existing in the
# target or solution import fails. We bundle each custom table's definition (so import recreates it)
# and capture one seed row (exported in Step 5b) so the installed sample has realistic data.
# IMPORTANT: only CUSTOM tables (IsCustomEntity=true). System/standard tables already exist in every
# environment and must never be bundled.
$TYPE_ENTITY = 1
$seedTables = @()
$tableRefs = @()
foreach ($fid in $flowIds) {
    try {
        $wf = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/workflows($fid)?`$select=clientdata" -Headers $dv
        foreach ($m in [regex]::Matches($wf.clientdata, '"entityName"\s*:\s*"([a-zA-Z0-9_]+)"')) {
            $tableRefs += $m.Groups[1].Value
        }
    } catch {}
}
$tableRefs = $tableRefs | Sort-Object -Unique | Where-Object { $_ }
foreach ($ref in $tableRefs) {
    # The ref may be the entity SET name (plural) or the logical name. Resolve both ways.
    $ent = $null
    try { $ent = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/EntityDefinitions(LogicalName='$ref')?`$select=LogicalName,EntitySetName,MetadataId,PrimaryIdAttribute,PrimaryNameAttribute,IsCustomEntity,IsManaged" -Headers $dv } catch {}
    if (-not $ent) {
        try {
            $byset = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/EntityDefinitions?`$filter=EntitySetName eq '$ref'&`$select=LogicalName,EntitySetName,MetadataId,PrimaryIdAttribute,PrimaryNameAttribute,IsCustomEntity,IsManaged" -Headers $dv).value
            if ($byset) { $ent = $byset[0] }
        } catch {}
    }
    if (-not $ent) { continue }
    # Only bundle the maker's OWN tables: custom AND unmanaged. Microsoft platform tables (e.g.
    # msdyn_*, AI Builder) report IsCustomEntity=true but IsManaged=true — they already exist in
    # every environment that has the relevant platform feature, so never bundle them.
    if (-not $ent.IsCustomEntity -or $ent.IsManaged) { INFO "Table '$($ent.LogicalName)': platform/managed table, not bundled (exists in target)"; continue }

    # Add the Entity (with its columns/choices) to the solution so import recreates the table.
    Add-ToSolution $ent.MetadataId @($TYPE_ENTITY) "custom table '$($ent.LogicalName)'" | Out-Null
    $seedTables += [pscustomobject]@{
        logical     = $ent.LogicalName
        setName     = $ent.EntitySetName
        primaryId   = $ent.PrimaryIdAttribute
        primaryName = $ent.PrimaryNameAttribute
    }
    OK "Bundled custom table '$($ent.LogicalName)' (definition + 1 seed row)"
}
if ($seedTables.Count -eq 0) { INFO "No custom table dependencies to bundle" }

# ── Verification net — fail LOUDLY if the surgical add did not land ────────────
# This is the safety guarantee against the silent-empty-bundle failure mode. We count what is
# actually in the solution and compare it to what we expected to add. Sub-components pulled in
# automatically (DoNotIncludeSubcomponents=$false) mean the real count is >= the expected
# minimum; if it is far short, a component-type mismatch silently failed and we must abort
# BEFORE pac export produces a broken bundle.
$expectedMin = 1 + $addedBotComps + $flowIds.Count + $addedConnRefs
$actualCount = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/solutioncomponents?`$filter=_solutionid_value eq $solId&`$select=componenttype&`$count=true" -Headers $dv).'@odata.count'
INFO "Solution component check: $actualCount present, expected at least $expectedMin"
if ($actualCount -lt $expectedMin) {
    Write-Error "Solution '$SolutionName' has only $actualCount component(s) but at least $expectedMin were expected. The surgical add did not fully land (likely a Dataverse component-type mismatch). Aborting before producing an incomplete bundle."
}
OK "Verified $actualCount component(s) in solution"

# ── Step 4: pac solution export ───────────────────────────────────────────────
Step "Step 4 — pac solution export"
& $PacExe auth select --index $AuthIndex | Out-Null
$zipPath = Join-Path $OutputDir "agent.zip"
& $PacExe solution export --name $SolutionName --path $zipPath --environment $OrgNoTrail --overwrite 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { Write-Error "pac solution export failed" }
OK "agent.zip ($([Math]::Round((Get-Item $zipPath).Length/1KB))KB)"

# Sanity check — the exported ZIP must actually contain the bot definition. A tiny ZIP with no
# bot means the surgical add failed and we are about to ship a useless bundle.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zc = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
$hasBot = @($zc.Entries | Where-Object { $_.FullName -match '^bots/.+/bot\.xml$' }).Count -gt 0
$compEntries = @($zc.Entries | Where-Object { $_.FullName -match '^botcomponents/' -and $_.FullName -match 'botcomponent\.xml$' }).Count
$zc.Dispose()
if (-not $hasBot) {
    Write-Error "Exported agent.zip contains no bot definition (bots/*/bot.xml missing). The export is incomplete — do not distribute this bundle."
}
INFO "ZIP sanity: bot.xml present, $compEntries botcomponent(s) packaged"

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

# ── Step 5b: Export one seed row per bundled custom table ──────────────────────
Step "Step 5b — Export seed data for custom tables ($($seedTables.Count))"
$seedManifest = @()
foreach ($tbl in $seedTables) {
    try {
        $row = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/$($tbl.setName)?`$top=1" -Headers $dv).value | Select-Object -First 1
        if (-not $row) { INFO "  '$($tbl.logical)': source table empty — no seed row"; $seedManifest += @{ logical=$tbl.logical; setName=$tbl.setName; primaryName=$tbl.primaryName; hasSeed=$false }; continue }
        # Keep only this table's own data columns: prefix_* columns, excluding the primary id and any
        # navigation/system fields. The primary id is dropped so the target generates a fresh GUID.
        $prefix = ($tbl.logical -split '_')[0] + '_'
        $seed = @{}
        foreach ($p in $row.PSObject.Properties) {
            if ($p.Name -like "$prefix*" -and $p.Name -ne $tbl.primaryId -and $p.Name -notlike '_*' -and $p.Name -notmatch '@') {
                $seed[$p.Name] = $p.Value
            }
        }
        $seedDir = Join-Path $OutputDir "seed-data"
        New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
        ($seed | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $seedDir "$($tbl.logical).json") -Encoding UTF8
        OK "  '$($tbl.logical)': 1 seed row ($($seed.Keys.Count) columns)"
        $seedManifest += @{ logical=$tbl.logical; setName=$tbl.setName; primaryName=$tbl.primaryName; hasSeed=$true }
    } catch {
        WARN "  '$($tbl.logical)': could not export seed row ($($_.Exception.Message))"
        $seedManifest += @{ logical=$tbl.logical; setName=$tbl.setName; primaryName=$tbl.primaryName; hasSeed=$false }
    }
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
    seedTables      = $seedManifest
    importNotes = @(
        "Run install.ps1 to import this bundle.",
        "install.ps1 will: (1) pac solution import, (2) seed custom tables, (3) guide skill re-upload.",
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

# Build the bundle entirely with System.IO.Compression for clean, warning-free relative paths.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($bundleZipPath, 'Create')
try {
    foreach ($f in @((Join-Path $OutputDir "agent.zip"), (Join-Path $OutputDir "manifest.json"))) {
        if (Test-Path $f) {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f, (Split-Path $f -Leaf)) | Out-Null
        }
    }
    $skillsDir = Join-Path $OutputDir "skills-with-assets"
    if (Test-Path $skillsDir) {
        Get-ChildItem $skillsDir -Recurse -File | ForEach-Object {
            $entryName = $_.FullName.Replace($OutputDir + "\", "") -replace "\\", "/"
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entryName) | Out-Null
        }
    }
    $seedDir = Join-Path $OutputDir "seed-data"
    if (Test-Path $seedDir) {
        Get-ChildItem $seedDir -Recurse -File | ForEach-Object {
            $entryName = $_.FullName.Replace($OutputDir + "\", "") -replace "\\", "/"
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entryName) | Out-Null
        }
    }
} finally {
    $zip.Dispose()
}

$bundleSize = [Math]::Round((Get-Item $bundleZipPath).Length/1KB)
OK "$bundleZipName ($bundleSize KB)"

# Clean up loose files (now inside bundle)
Remove-Item (Join-Path $OutputDir "agent.zip") -ErrorAction SilentlyContinue
Remove-Item (Join-Path $OutputDir "manifest.json") -ErrorAction SilentlyContinue
Remove-Item $skillsDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $OutputDir "seed-data") -Recurse -Force -ErrorAction SilentlyContinue

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
