# Modern Copilot Studio Agent — Toolkit

> **pac CLI gap (June 2026):** `pac copilot pack` crashes on cliagent-* workspaces and `pac copilot pull` crashes. `pac copilot extract-template` + `create` silently ignores agent configuration (open issue #1259). Native cliagent ALM support is on the pac CLI roadmap. Until it ships, this toolkit fills the gaps. See [LEARNINGS.md](LEARNINGS.md) for the full comparison.

Two workflows for Modern Copilot Studio agents (`cliagent-*` template):
- **distribute/** — export an agent as a ZIP, share it, install it anywhere
- **develop/** — clone an agent to YAML, edit in VS Code, deploy changes

---

## Prerequisites

Both paths require:

| Tool | Install |
|------|---------|
| pac CLI | https://aka.ms/PowerPlatformCLI |
| az CLI | https://aka.ms/installazurecliwindows |
| pac auth | `pac auth create --environment https://yourorg.crm.dynamics.com` |
| az login | `az login` (needs Dataverse access) |

The **develop/** path additionally requires:
- [Power Platform Tools for VS Code](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.powerplatform-vscode) for YAML editing and schema hints

---

## What agent components are supported

This matrix applies to **both paths**. Check it before using either workflow on your agent.

| Component | distribute/ | develop/ | Notes |
|-----------|:-----------:|:--------:|-------|
| Agent instructions + model (bot.configuration) | ✅ | ✅ | Authoritative version always exported and applied on import |
| ConnectorTools (standard MS connectors) | ✅ | ✅ | Connection wiring is one manual step per env — expected platform behavior |
| WorkflowTool / TaskDialog (Agent Flows) | ✅ | ✅ | distribute/: GUIDs preserved; develop/: remapped automatically |
| InlineAgentSkill (markdown-only skill) | ✅ | ✅ | Full round-trip, no extra steps |
| Skill with Python/code assets — instructions | ✅ | ✅ | Exported from SKILL.md and re-applied on import |
| Skill with Python/code assets — code execution | ⚠️ manual | ⚠️ manual | Requires re-upload via CS UI (see note below) |
| URL knowledge sources | ✅ | ✅ | Full round-trip |
| File knowledge (PDF, DOCX) | ✅ | ❌ | Binary preserved in solution ZIP; not captured by pac clone |
| Evaluation test cases | ✅ | ❌ | In solution ZIP; not captured by pac clone |
| ConnectedAgentTool | ✅ | ✅ | Child agent must exist in target by same schema name |
| **Custom connectors with inline code** | ❌ | ❌ | Azure Functions provisioning is unreliable — platform issue |
| **MCP server tools** | ⚠️ | ⚠️ | Tool definition transfers; server must be running at same URL in target |
| **Connection refs (new 2026 CS UI)** | ❌ | ❌ | Reports: new UI creates connection refs without backing connector record |
| Classic agents (default-2.x.x template) | ❌ | ❌ | Different architecture — use standard pac solution or pac copilot push |

> **Why skills with code require a manual upload step:**
> When you upload a skill ZIP through the Copilot Studio UI, CS runs a server-side process that stores the binary assets (Python scripts etc.) in Azure blob storage and generates an environment-specific bundle reference token. There is no public API for this process — it happens inside CS's own backend. Without this token, the code assets are unreachable at runtime. The skill ZIP is exported and ready in the bundle; you just need to trigger that server-side process by uploading it once through the CS UI. The install script pauses and opens the browser for you at the right point. This is a one-time step per environment.



## Get started

### Identify your agent

Both scripts require your agent's **BotId** — the GUID in the Copilot Studio URL:  
`https://copilotstudio.microsoft.com/environments/{envId}/agents/{BotId}`

Your agent must use the `cliagent-*` template (visible in PPAC → agent record). Classic agents (`default-2.x.x`) are not supported.

---

### distribute/ — Share an agent as a ZIP

**Export** (run once to produce a shareable bundle):
```powershell
.\distribute\export.ps1 `
  -SourceOrgUrl "https://yourorg.crm.dynamics.com" `
  -BotId        "your-bot-guid" `
  -SolutionName "MyAgentSample" `
  -PublisherName "YourPublisher"
# Produces: MyAgent-bundle.zip
```

**Install** (anyone can run this against their own environment):
```powershell
.\distribute\install.ps1 `
  -BundleZip    ".\MyAgent-bundle.zip" `
  -TargetOrgUrl "https://targetorg.crm.dynamics.com"
# Agent appears in Copilot Studio. Wire connections in PPAC when prompted.
```

After install: wire connections for any ConnectorTool flows in PPAC → Power Automate.

---

### develop/ — Clone an agent to YAML, edit, deploy

**Export** (clone agent to editable YAML):
```powershell
.\develop\export.ps1 `
  -SourceOrgUrl "https://yourorg.crm.dynamics.com" `
  -BotId        "your-bot-guid" `
  -AgentName    "My Agent"
# Produces: sample/My Agent/ (YAML), agent-config.json, skills-with-assets/
```

**Edit** YAML files in VS Code:
- `sample/My Agent/settings.mcs.yml` — agent name, auth, model
- `sample/My Agent/translations/*.mcs.yml` — tool/skill definitions
- `sample/My Agent/workflows/*/workflow.json` — flow logic

**Deploy** to any environment:
```powershell
.\develop\install.ps1 `
  -TargetOrgUrl    "https://targetorg.crm.dynamics.com" `
  -AgentName       "My Agent" `
  -AgentSchemaName "publisher_MyAgent_xxxxx"
# Agent created, YAML pushed, flows remapped, bot.configuration applied.
```

---

## Repo structure

```
distribute/
  export.ps1    ← export agent → {AgentName}-bundle.zip
  install.ps1   ← install from bundle ZIP

develop/
  export.ps1    ← pac clone + bot.configuration + skill asset download
  install.ps1   ← bot pre-create + pac push + flow GUID remap + bot.configuration PATCH

LEARNINGS.md    ← tested findings, pac CLI gap analysis, known bugs
CONTRIBUTING.md ← how to contribute
```

---

See [LEARNINGS.md](LEARNINGS.md) for technical details on all gaps, pac CLI known bugs, the Default Solution membership problem, and the full component matrix.
