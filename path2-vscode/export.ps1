<#
.SYNOPSIS
    Export a Modern Copilot Studio agent for VS Code editing (clone/push workflow).

.DESCRIPTION
    Produces a source-control-friendly folder structure for editing in VS Code:
      sample/<AgentName>/       YAML from pac copilot clone (all tools, skills, flows)
      sample/agent-config.json  Authoritative bot.configuration (instructions, model)
      skills-with-assets/       Binary files for ZIP-uploaded skills

    WHY THIS SCRIPT EXISTS (the two things pac copilot clone misses)
    ───────────────────────────────────────────────────────────────
    pac copilot clone is NOT broken — it correctly walks the agent's component graph
    and captures everything in YAML. It reliably captures:
      - All tool definitions (ConnectorTool, McpTool, WorkflowTool, TaskDialog)
      - All flow definitions (workflow.json)
      - All connection references (connectionreferences.mcs.yml)
      - InlineAgentSkill markdown skills (in translations/*.mcs.yml)
      - URL knowledge sources (in knowledge/*.mcs.yml)

    But it misses two things:

    GAP 1 — bot.configuration (instructions may be stale in YAML)
      settings.mcs.yml contains instructions as of the LAST pac push.
      Any edits in the Copilot Studio UI write to bot.configuration in Dataverse,
      NOT back to settings.mcs.yml. The two can silently diverge.
      This script exports the authoritative bot.configuration to agent-config.json.

    GAP 2 — Binary skill assets not in YAML
      Skills uploaded as ZIP files (containing Python scripts, images, etc.) store
      a bic:bundle= reference token in their YAML. The actual binary files are in
      type-14 botcomponents (filedata field) — pac clone does not capture binaries.
      This script downloads them to skills-with-assets/{skill-name}/.

    WHAT THE VS CODE WORKFLOW LOOKS LIKE
    ─────────────────────────────────────
    1. Run export.ps1 → get sample/ folder + agent-config.json + skills-with-assets/
    2. Edit YAML in VS Code:
         settings.mcs.yml      → instructions, model, auth
         translations/*.mcs.yml → tool descriptions, inputs, outputs
         knowledge/*.mcs.yml    → URL knowledge source URLs
         workflows/*/workflow.json → flow logic
    3. Run path2-vscode/install.ps1 → deploy to any target environment

    PREREQUISITES
    ─────────────
    pac CLI:  https://aka.ms/PowerPlatformCLI
    az CLI:   https://aka.ms/installazurecliwindows
    pac auth: pac auth create --environment https://yourorg.crm.dynamics.com
    az login: az login (with Dataverse access to source env)

.PARAMETER SourceOrgUrl    Dataverse org URL for the source environment.
.PARAMETER BotId           Dataverse bot GUID.
.PARAMETER AgentName       Display name (used as folder name under sample/).
.PARAMETER OutputDir       Root folder for output. Defaults to current directory.
.PARAMETER AuthIndex       pac auth index for the source environment.
.PARAMETER PacExe          Path to pac.exe. Auto-detected if not specified.

.EXAMPLE
    .\export.ps1 -SourceOrgUrl "https://myorg.crm.dynamics.com" -BotId "xxxx-..." -AgentName "My Agent"
#>
param(
    [Parameter(Mandatory)][string] $SourceOrgUrl,
    [Parameter(Mandatory)][string] $BotId,
    [Parameter(Mandatory)][string] $AgentName,
    [string] $OutputDir = ".",
    [int]    $AuthIndex = 1,
    [string] $PacExe    = ""
)

$ErrorActionPreference = "Stop"
$OrgNoTrail = $SourceOrgUrl.TrimEnd("/")
# Resolve to absolute path — [System.IO.File]::WriteAllBytes requires absolute paths
$OutputDir  = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)

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
Write-Host "║  Modern Agent Export — VS Code Path      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Source : $OrgNoTrail"
Write-Host "  Agent  : $AgentName ($BotId)"
Write-Host ""

# ── Acquire DV token ──────────────────────────────────────────────────────────
Step "Acquiring Dataverse token..."
$token = (az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json).accessToken
$dv = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json" }
OK "Token acquired"

# ── Step 1: Validate Modern agent ─────────────────────────────────────────────
Step "Step 1 — Validate Modern Copilot Studio agent (cliagent-1.0.0)"
$bot = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots($BotId)?`$select=botid,name,schemaname,template,configuration" -Headers $dv
$cfg = $bot.configuration | ConvertFrom-Json

# Hard requirement: cliagent-1.0.0 template.
if ($bot.template -ne "cliagent-1.0.0") {
    Write-Error "template='$($bot.template)' — expected 'cliagent-1.0.0'. This toolkit is for cliagent-1.0.0 agents only."
}

# Informational: recognizer type. Both CLICopilotRecognizer (NGO) and GenerativeAIRecognizer
# (CGO) are valid in cliagent-1.0.0 containers. Export behavior is identical for both.
$recognizerKind = $cfg.recognizer.'$kind'
if ($recognizerKind -eq "CLICopilotRecognizer") {
    INFO "Recognizer: CLICopilotRecognizer (Modern / NGO)"
} elseif ($recognizerKind -eq "GenerativeAIRecognizer") {
    INFO "Recognizer: GenerativeAIRecognizer (CGO in cliagent container) — export works the same"
} else {
    WARN "Recognizer: $recognizerKind (unrecognized — export will proceed)"
}

# Soft warning: custom topics suggest a Classic/Topics agent
$customTopics = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$BotId' and componenttype eq 2&`$select=name" -Headers $dv).value
if ($customTopics.Count -gt 0) {
    WARN "$($customTopics.Count) custom topic(s) found — looks like a Classic (topics-based) agent."
    WARN "This toolkit is designed for instructions-based agents. Topics will clone, but test carefully."
}

OK "$($bot.name) ($($bot.schemaname)) — template: cliagent-1.0.0 ✓"

# ── Step 2: pac copilot clone → YAML ─────────────────────────────────────────
Step "Step 2 — pac copilot clone (all YAML: tools, skills, flows, connection refs)"
& $PacExe auth select --index $AuthIndex | Out-Null
$sampleDir = Join-Path $OutputDir "sample"
& $PacExe copilot clone --environment $OrgNoTrail --bot $BotId --display-name $AgentName --output-dir $sampleDir 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { Write-Error "pac copilot clone failed" }
$agentDir  = Join-Path $sampleDir $AgentName
$yamlCount = (Get-ChildItem $agentDir -Filter "*.mcs.yml" -Recurse).Count
OK "$yamlCount YAML files cloned to: $agentDir"

# ── Step 3: Export authoritative bot.configuration ────────────────────────────
Step "Step 3 — Export bot.configuration (authoritative instructions + model)"
INFO "settings.mcs.yml may be stale if the agent was edited in the Copilot Studio UI."
INFO "bot.configuration in Dataverse is always authoritative."
$configJson = $bot.configuration
if ($configJson.Length -gt 0) {
    $configJson | Set-Content (Join-Path $sampleDir "agent-config.json") -Encoding UTF8
    $instrLen = $cfg.agentSettings.instructions.segments[0].value.Length
    OK "agent-config.json saved"
    INFO "  Model       : $($cfg.agentSettings.model.series)"
    INFO "  Instructions: $instrLen chars"

    # Warn if YAML instructions differ from DV
    $settingsPath = Join-Path $agentDir "settings.mcs.yml"
    if (Test-Path $settingsPath) {
        $yamlText   = Get-Content $settingsPath -Raw
        $dvInstr50  = $cfg.agentSettings.instructions.segments[0].value.Substring(0, [Math]::Min(50, $instrLen))
        if (-not $yamlText.Contains($dvInstr50)) {
            WARN "settings.mcs.yml instructions differ from bot.configuration."
            WARN "The agent was edited in the Copilot Studio UI after the last pac push."
            WARN "agent-config.json is authoritative — install.ps1 will apply it."
        }
    }
} else {
    WARN "bot.configuration is empty — instructions may not have been set on source agent"
}

# ── Step 4: Export binary skill assets ────────────────────────────────────────
Step "Step 4 — Export binary skill assets (bic:bundle= skills)"
$allComps = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$BotId'&`$select=botcomponentid,name,componenttype,data" -Headers $dv).value
$skillsWithAssets = $allComps | Where-Object { $_.data -like "*bic:bundle=*" }

INFO "Skills with assets: $($skillsWithAssets.Count)"
$n = 0
foreach ($skill in $skillsWithAssets) {
    $skillDir = Join-Path $OutputDir "skills-with-assets\$($skill.name)"
    New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
    $children = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotcomponentid_value eq '$($skill.botcomponentid)'&`$select=botcomponentid,name,filedata_name" -Headers $dv).value
    foreach ($child in $children) {
        $fileName = if ($child.filedata_name) { $child.filedata_name } else { $child.name -replace '^\./',''}
        $filePath = Join-Path $skillDir $fileName
        try {
            $fileBytes = (Invoke-WebRequest -Uri "$OrgNoTrail/api/data/v9.2/botcomponents($($child.botcomponentid))/filedata/`$value" `
                -Headers @{ Authorization="Bearer $token" } -UseBasicParsing).Content
            [System.IO.File]::WriteAllBytes($filePath, $fileBytes)
            OK "  $($skill.name)/$fileName ($($fileBytes.Length) bytes)"
            $n++
        } catch {
            try {
                $rec = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents($($child.botcomponentid))?`$select=filedata" -Headers $dv
                if ($rec.filedata) {
                    [System.IO.File]::WriteAllBytes($filePath, [Convert]::FromBase64String($rec.filedata))
                    OK "  $($skill.name)/$fileName (base64)"
                    $n++
                }
            } catch { WARN "Could not download $fileName for '$($skill.name)'" }
        }
    }
}
if ($n -eq 0 -and $skillsWithAssets.Count -eq 0) { INFO "No skills with assets — nothing to export" }

# ── Step 5: Component inventory ───────────────────────────────────────────────
Step "Step 5 — Component inventory"
Write-Host ""
Write-Host "  Component inventory for '$AgentName':"
$allComps | Group-Object componenttype | Sort-Object Name | ForEach-Object {
    $typeName = switch ($_.Name) {
        9  { "Tools / Skills" }
        14 { "File assets" }
        15 { "GPT config" }
        19 { "Eval test cases" }
        default { "Type $($_.Name)" }
    }
    Write-Host "    $typeName : $($_.Count)"
}
$wfCount = (Get-ChildItem (Join-Path $agentDir "workflows") -Directory -ErrorAction SilentlyContinue).Count
Write-Host "    Workflows        : $wfCount"
Write-Host "    Skills w/ assets : $($skillsWithAssets.Count)"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Export Complete                         ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  sample/$AgentName/  : $yamlCount YAML files (edit in VS Code)"
Write-Host "  agent-config.json   : $(if($configJson.Length -gt 0){'saved (authoritative)'}else{'MISSING'})"
Write-Host "  skills-with-assets/ : $n binary file(s)"
Write-Host ""
Write-Host "  Edit YAML, then run:"
Write-Host "    .\install.ps1 -TargetOrgUrl <url>" -ForegroundColor Cyan
