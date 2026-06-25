# Modern Copilot Studio Agent — Export / Import Toolkit

A complete toolkit for exporting, committing to source control, and importing
**Modern Copilot Studio agents** (`cliagent-1.0.0`) — including full coverage of the ALM
gaps that `pac` CLI does not handle out of the box.

---

## The problem this solves

Microsoft Copilot Studio agents exist in two architectures. The newer **Modern** agent
(template `cliagent-1.0.0`, recognizer `CLICopilotRecognizer`) has ALM behaviors that
the standard `pac copilot clone/push` and `pac solution` workflows do not fully support:

| Gap | Without this toolkit |
|-----|---------------------|
| `bot.configuration` (instructions, model) | Not written by `pac push`; edits made in the Copilot Studio UI diverge from YAML silently |
| Flow tool GUIDs (`workflowId`, `flowId`) | Source-env GUIDs embedded in YAML — pac push fails with "Entity 'Workflow' Does Not Exist" |
| Skills uploaded as ZIP files (Python/binary assets) | Appear in the UI after import but binary assets are unreachable at runtime. *Note: markdown-only InlineAgentSkills work correctly — this gap affects only ZIP-bundled skills with Python scripts or binary files.* |
| Botcomponents always land in Default Solution | Tools, skills, and knowledge added via the UI go to Default Solution regardless of which named solution the agent belongs to — a naive pac solution export misses them |

This toolkit closes all four gaps with tested, scripted solutions.

---

## Prerequisites

| Tool | Install |
|------|---------|
| pac CLI | https://aka.ms/PowerPlatformCLI |
| az CLI | https://aka.ms/installazurecliwindows |
| pac auth | `pac auth create --environment https://yourorg.crm.dynamics.com` |
| az login | `az login` (needs Dataverse access) |

**Permissions required:**
- Source environment: Copilot Studio read, Dataverse read
- Target environment: Copilot Studio create/write, Dataverse write, Flow create

---

## Get started

**To share an agent with someone** (as a ZIP file they can install):
```powershell
.\path1-solution\export.ps1 -SourceOrgUrl "https://yourorg.crm.dynamics.com" -AgentName "My Agent" -BotId "your-bot-guid"
# → produces MyAgent-bundle.zip. Share that file.
```

**To install an agent from a bundle ZIP:**
```powershell
.\path1-solution\install.ps1 -BundleZip ".\MyAgent-bundle.zip" -TargetOrgUrl "https://targetorg.crm.dynamics.com"
# → agent appears in Copilot Studio. Wire connections in PPAC when prompted.
```

**To edit an agent in VS Code and deploy changes:**
```powershell
# 1. Clone to YAML
.\path2-vscode\export.ps1 -SourceOrgUrl "https://yourorg.crm.dynamics.com" -AgentName "My Agent" -BotId "your-bot-guid"
# → editable YAML files appear under sample/

# 2. Edit YAML files in VS Code (settings.mcs.yml, translations/, workflows/)

# 3. Deploy to any environment
.\path2-vscode\install.ps1 -TargetOrgUrl "https://targetorg.crm.dynamics.com" -AgentName "My Agent" -AgentSchemaName "publisher_MyAgent_xxxxx"
```

**Where to find your BotId:** Copilot Studio → open your agent → the URL contains the bot GUID:
`https://copilotstudio.microsoft.com/environments/{envId}/agents/{BotId}`

---

## Background: What makes a Modern agent different from Classic

| Property | Modern (`cliagent-1.0.0`) | Classic (`default-2.1.0`) |
|----------|--------------------------|--------------------------|
| Template | `cliagent-1.0.0` | `default-2.1.0` |
| Recognizer | `CLICopilotRecognizer` (NGO) or `GenerativeAIRecognizer` (CGO) | `GenerativeAIRecognizer` |
| Topics | None — orchestration via instructions + tools | Topics-based conversation flow |
| Instructions | `bot.configuration` field in Dataverse (authoritative) | In `settings.mcs.yml` |
| Flow tools | WorkflowTool (newer) + TaskDialog (older) | TaskDialog only |
| Skills | InlineAgentSkill (markdown) + skills-with-assets (ZIP/Python) | N/A |

### bot.configuration

When you edit an agent's instructions in the Copilot Studio UI, they are written to
`bot.configuration` in Dataverse — **not** back to `settings.mcs.yml`. These two can
silently diverge. This toolkit always exports `bot.configuration` and PATCHes it on import
so the authoritative version is always deployed.

### Two flow tool types

**WorkflowTool** (Copilot Studio Workflows):
- YAML: `translations/<schema>.tool.<name>.mcs.yml` with `kind: WorkflowTool`, `workflowId: <guid>`

**TaskDialog** (Agent Flows / Power Automate):
- YAML: `actions/<name>.mcs.yml` with `kind: TaskDialog`, `flowId: <guid>`

Both embed source-env-specific GUIDs. Path 2 (VS Code) strips and remaps them.
Path 1 (solution import) preserves GUIDs automatically.

### Two skill types

**InlineAgentSkill** — markdown content, stored in `translations/*.skill.*.mcs.yml`.
Works correctly with both solution import and pac push. No extra steps needed.

**Skills with assets** — uploaded as a ZIP file containing Python scripts or binary files.
Copilot Studio stores a bundle reference token (`bic:bundle=...`) that points to
server-side Azure file storage. This blob is not captured in solution exports or pac clone.
After import, the skill record exists but assets are unreachable. `install.ps1` handles
this automatically by recovering the skill instructions and guiding the re-upload.

---

## What pac solution import handles (verified)

> **Note on skills**: The reported issue — "skills don't work via solution import" — is
> specific to ZIP-uploaded skills with binary/Python assets. **InlineAgentSkills
> (markdown-only) import correctly** with no extra steps. `install.ps1` handles the rest.

| Component | pac solution import |
|-----------|-------------------|
| `bot.configuration` (instructions, model) | ✅ Restored from `configuration.json` in ZIP |
| InlineAgentSkill (markdown) | ✅ Fully restored |
| ConnectorTool, McpTool | ✅ Tool definitions restored |
| WorkflowTool / TaskDialog | ✅ Flow GUIDs preserved — no remap needed |
| ConnectedAgentTool | ✅ Restored by schema name |
| URL knowledge sources | ✅ Fully restored |
| File knowledge (uploaded PDFs, docs) | ✅ Binary content preserved |
| Evaluation test cases | ✅ Fully restored |
| Connection references | ✅ Created empty — wire manually (normal platform behavior) |
| Skills with binary assets (ZIP+Python) | ⚠️ Record exists, bundle blob broken → `install.ps1` fixes automatically |

**Requirement**: All botcomponents must be added to the distribution solution before export.
Copilot Studio always creates new components in Default Solution — `export.ps1` handles
this surgically without pulling in unrelated components.

---

## VS Code workflow

All Modern agent content is plain text, fully editable in VS Code.

Install [Power Platform Tools](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.powerplatform-vscode)
for pac CLI integration and `.mcs.yml` schema validation.

| Component | File location after export |
|-----------|--------------------------|
| Instructions, model | `settings.mcs.yml` (see note on bot.configuration above) |
| ConnectorTool, McpTool, WorkflowTool, InlineAgentSkill, ConnectedAgentTool | `translations/<schema>.<type>.<name>.mcs.yml` |
| Agent Flow (older) | `actions/<name>.mcs.yml` + `workflows/<name>-<guid>/workflow.json` |
| URL knowledge | `knowledge/<name>.mcs.yml` |
| Connection references | `connectionreferences.mcs.yml` |
| Authoritative instructions | `agent-config.json` (exported separately, patched after push) |

---

## Known limitations

| Limitation | Mitigation |
|------------|-----------|
| Skills with binary assets | `install.ps1` auto-fixes instructions; optional manual ZIP re-upload for Python execution |
| ConnectedAgentTool | Child agent must exist in target env by the same schema name |
| Connection wiring | One-time manual step per env per connector (normal platform behavior) |
| Claude/Anthropic model | Target env must have the same model series enabled |
| Botcomponent schemaname > 100 chars | `install.ps1` warns; rename the tool in source env |

---

## Repo structure

```
path1-solution/
  export.ps1    ← produces {AgentName}-bundle.zip (single file to share)
  install.ps1   ← imports bundle ZIP, fixes skills, opens browser for re-upload

path2-vscode/
  export.ps1    ← pac clone + bot.configuration export + skill asset download
  install.ps1   ← bot pre-create + pac push + flow GUID remap + bot.configuration PATCH

LEARNINGS.md    ← all tested findings with evidence (no assumptions)
```

---

## Tested on

End-to-end tested June 2026 against a real `cliagent-1.0.0` agent exported from one
environment and imported into a fresh environment via the full pipeline:

```
export.ps1 → Fabric-Analyst-bundle.zip → (delete agent in target) → install.ps1 -BundleZip
```

Agent under test had:
- Tools: 3× ConnectorTool (Power BI), 2× TaskDialog (Agent Flows)
- Skills: 1× InlineAgentSkill, 1× skill-with-assets (ZIP + Python script)
- Knowledge: (none in this test — PDF knowledge tested separately, confirmed working)
- Evaluation test cases: 10 records
- Connection references: 1 (Power BI — empty after import, as expected)

### Verified after import

| Component | Result |
|-----------|--------|
| `bot.configuration` (instructions + model) | ✅ Restored from ZIP |
| ConnectorTools (3× Power BI) | ✅ Present |
| TaskDialog flows — flow records exist in target with correct GUIDs | ✅ Verified via DV API |
| InlineAgentSkill | ✅ Present |
| skill-with-assets (retail-sales-report) | ✅ Repaired to InlineAgentSkill — instructions work |
| Evaluation test cases (10 records) | ✅ Present |
| Connection reference (Power BI) | ✅ Created empty — wire manually in Power Automate |

See `LEARNINGS.md` for all tested technical findings.
