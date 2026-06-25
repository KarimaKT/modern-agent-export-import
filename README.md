# Modern Copilot Studio Agent — Export / Import Toolkit

> **pac CLI 2.8.1 gap:** `pac copilot pack` crashes on cliagent-1.0.0 workspaces. `pac copilot pull` crashes. `pac copilot extract-template` + `create` silently ignores agent configuration (open issue #1259, 10+ months). `bot.configuration`, flow GUIDs, and skills-with-assets have no coverage in any stable pac release. This toolkit fills those gaps — see [LEARNINGS.md §12](LEARNINGS.md) for the full comparison.
>
> **pac CLI alpha:** An alpha with improved cliagent support is reported at the [CAP_ISVExp_Tools_Daily feed](https://dev.azure.com/msazure/One/_artifacts/feed/CAP_ISVExp_Tools_Daily) (authentication required). Test it against the gaps in §12 before choosing an approach.

PowerShell scripts to export, distribute, and import **Modern Copilot Studio agents**
(`cliagent-1.0.0`) across environments — filling specific tested gaps in the current stable pac CLI.

---

## Prerequisites

| Tool | Install |
|------|---------|
| pac CLI | https://aka.ms/PowerPlatformCLI |
| az CLI  | https://aka.ms/installazurecliwindows |
| pac auth | `pac auth create --environment https://yourorg.crm.dynamics.com` |
| az login | `az login` (needs Dataverse access) |

---

## Get started

**To distribute an agent as a ZIP (share with others or check in to source control):**
```powershell
.\path1-solution\export.ps1 `
  -SourceOrgUrl "https://yourorg.crm.dynamics.com" `
  -BotId        "your-bot-guid" `
  -SolutionName "MyAgentSample" `
  -PublisherName "YourPublisher"
# Produces MyAgent-bundle.zip — share that file.
```

**To install from a bundle ZIP:**
```powershell
.\path1-solution\install.ps1 `
  -BundleZip    ".\MyAgent-bundle.zip" `
  -TargetOrgUrl "https://targetorg.crm.dynamics.com"
# Agent appears in Copilot Studio. Wire connections in PPAC when prompted.
```

**To clone an agent for editing in VS Code, then deploy:**
```powershell
# 1. Clone to editable YAML
.\path2-vscode\export.ps1 `
  -SourceOrgUrl "https://yourorg.crm.dynamics.com" `
  -BotId        "your-bot-guid" `
  -AgentName    "My Agent"

# 2. Edit YAML in VS Code (settings.mcs.yml, translations/, workflows/)

# 3. Deploy to any environment
.\path2-vscode\install.ps1 `
  -TargetOrgUrl    "https://targetorg.crm.dynamics.com" `
  -AgentName       "My Agent" `
  -AgentSchemaName "publisher_MyAgent_xxxxx"
```

**Where to find your BotId:** open your agent in Copilot Studio — the GUID is in the URL.

---

## What this handles

Path 1 (solution ZIP) covers: `bot.configuration`, InlineAgentSkills, ConnectorTools,
WorkflowTool/TaskDialog flows (GUIDs preserved), URL + file knowledge, eval test cases.
Skills with Python/binary assets are auto-repaired post-import.

See the [full component matrix in LEARNINGS.md](LEARNINGS.md#4-what-pac-solution-import-gets-right).

---

## Known limitations

| Limitation | Notes |
|------------|-------|
| Skills with binary assets | Instructions auto-fixed; Python execution needs a manual ZIP re-upload via CS UI |
| ConnectedAgentTool | Child agent must exist in target by the same schema name |
| Connection wiring | One-time manual step in PPAC per connector (standard platform behavior) |
| Model availability | Target env must have the same model series (e.g. Claude/Anthropic) enabled |
| **Connection refs (new CS UI)** | Reports indicate 2026 CS UI creates connection references without a backing connector record — breaks solution export. Not reproduced here; agents using standard connections are unaffected. |
| **Custom connectors with inline code** | Azure Functions provisioning on import is unreliable — platform issue, not toolkit-specific. |
| **MCP server tools** | Tool definition transfers; MCP server must be running at the same URL in target. Local dev-tunnel URLs break. |

See [LEARNINGS.md](LEARNINGS.md) for detailed technical findings, tested patterns, and pac CLI known bugs.

---

## Repo structure

```
path1-solution/
  export.ps1    ← produces {AgentName}-bundle.zip
  install.ps1   ← imports bundle, fixes skills-with-assets

path2-vscode/
  export.ps1    ← pac clone + bot.configuration + skill binary download
  install.ps1   ← bot pre-create + pac push + flow GUID remap + bot.configuration PATCH

LEARNINGS.md    ← all tested findings with evidence
```
