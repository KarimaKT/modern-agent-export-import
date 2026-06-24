# Modern Agent Export/Import Toolkit

A reusable PowerShell CLI toolkit for exporting and importing **Copilot Studio Modern Orchestration** (NGO / `cliagent-1.0.0`) agents across environments — with the two extra steps that `pac copilot clone/push` alone cannot handle.

> **To be published at:** [your GitHub org]/modern-agent-export-import

---

## The Problem

### Classic (CGO) agents — it just works
Classic Copilot Studio agents use `pac copilot clone` → edit in VS Code → `pac copilot push`.  
All agent content (instructions, topics, connection references) lives in YAML. The VS Code extension handles everything.

### NGO agents (`cliagent-1.0.0`) — two extra complications

#### Complication 1: Skills / Knowledge sources live in Dataverse, not YAML
`pac copilot clone` only captures `agent.mcs.yml`, `settings.mcs.yml`, `actions/*.mcs.yml`, and `workflows/`. It silently **skips** `InlineAgentSkill` botcomponents (type 9) stored in Dataverse. These are your knowledge bases — schema files, DAX patterns, reference documents. Without them, the imported agent loses all its grounding context.

#### Complication 2: Action YAMLs contain environment-specific Flow IDs
Every `actions/*.mcs.yml` that wraps a Power Automate flow has a `flowId` field:

```yaml
action:
  kind: InvokeFlowTaskAction
  flowId: b5d08619-c241-f111-bec7-6045bd024dba   # ← CDX-specific GUID
```

When `pac copilot push` creates the agent in a new environment, it re-creates the Power Automate flows with **new GUIDs**. The `flowId` in the action YAML goes stale and the tools fail silently — the agent runs but never actually calls the flows.

---

## What This Toolkit Does

| Step | What | Tool |
|------|------|------|
| Clone agent YAML | agent + settings + actions + workflows | `pac copilot clone` |
| Export skills | `InlineAgentSkill` botcomponents → `.md` files | `export.ps1` |
| Push to new env | creates agent + new flows | `pac copilot push` |
| **Remap Flow IDs** | discovers new GUIDs, patches action YAMLs, re-pushes | **`install.ps1`** |
| **Upload skills** | POSTs skill `.md` files to target Dataverse | **`install.ps1`** |

---

## Repository Structure

```
modern-agent-export-import/
  sample/
    Fabric Analyst/          ← exported agent YAML (pac clone output)
      agent.mcs.yml          ← minimal metadata (kind: GptComponentMetadata)
      settings.mcs.yml       ← instructions (StaticSegment), model, auth config
      actions/
        ExecuteDAX.mcs.yml   ← TaskDialog wrapping a Power Automate flow
        RefreshDataset.mcs.yml
      workflows/
        TableTalk-Fabric-SendDAXQuery-{guid}/   ← flow definition JSON
        TableTalk-Fabric-Refreshdataset-{guid}/
      translations/
  skills/
    schema-definitions-and-dax.md   ← exported InlineAgentSkill knowledge file
  scripts/
    export.ps1               ← export from source env
    install.ps1              ← install to new env (augmented push)
  .vscode/
    extensions.json          ← recommends Power Platform Tools extension
    settings.json            ← pac CLI path setting
  README.md
  CONTRIBUTING.md
  LICENSE
```

---

## Prerequisites

- **pac CLI** — [Install Power Platform CLI](https://learn.microsoft.com/en-us/power-platform/developer/cli/introduction)
  - Tested with `Microsoft.PowerApps.CLI` 2.8.1+
- **Azure CLI** (`az`) — for acquiring Dataverse bearer tokens
  - `az login` with an account that has access to both environments
- **Power Platform environments** with:
  - Copilot Studio (Modern Orchestration / NGO enabled)
  - Anthropic Claude model access (the sample agent uses `Opus48`)
  - Power BI connector available
- **pac auth** — at least one profile configured per environment:
  ```powershell
  pac auth create --environment https://yourorg.crm.dynamics.com
  ```

---

## Usage

### 1. Export from source environment

```powershell
cd C:\src\modern-agent-export-import
.\scripts\export.ps1
```

This will:
- Re-clone the agent YAML to `./sample/Fabric Analyst/`
- Export all `InlineAgentSkill` botcomponents to `./skills/*.md`
- Print a summary of what was captured

To export a different agent, pass parameters:
```powershell
.\scripts\export.ps1 `
  -SourceOrgUrl "https://yourorg.crm.dynamics.com" `
  -AgentName "My Agent" `
  -BotId "your-bot-guid-here" `
  -AuthIndex 2
```

### 2. Install to target environment

```powershell
.\scripts\install.ps1
```

To target a different environment:
```powershell
.\scripts\install.ps1 `
  -TargetOrgUrl "https://targetorg.crm.dynamics.com" `
  -AgentSchemaName "Default_MyAgent_xxxxx" `
  -AuthIndex 3
```

**What install.ps1 does (step by step):**

1. **Selects target pac auth** (`pac auth select --index N`)
2. **Initial push** — `pac copilot push` creates the agent, deploys flows with new GUIDs
3. **Acquires DV token** — `az account get-access-token --resource {targetOrgUrl}`
4. **Discovers new bot ID** — queries `bots` table by schema name
5. **Queries new flow GUIDs** — `GET /api/data/v9.2/workflows?$filter=category eq 5`
6. **Patches action YAMLs** — replaces old flowIds with new GUIDs in each `actions/*.mcs.yml`
7. **Re-pushes** — second `pac copilot push` with corrected flow IDs
8. **Uploads skills** — POSTs each `skills/*.md` as a Dataverse `botcomponent` (type 9)

---

## The Flow ID Problem — Explained

When `pac copilot push` runs for the first time, it:
1. Creates a new Copilot Studio agent in the target environment
2. Deploys Power Automate flows from the `workflows/` directory
3. The flows get **new GUIDs** in the target environment

The `actions/*.mcs.yml` files still point to the **source environment's** flow GUIDs. The agent runs but tool calls silently fail.

**The fix:** After the initial push, query the target Dataverse for workflows with `category eq 5` (Modern Flows), match them by name prefix to the original workflow folder names, then update the `flowId` fields in the action YAMLs and push again.

Example — what `ExecuteDAX.mcs.yml` looks like before and after:
```yaml
# BEFORE (source env flowId — stale after push to new env)
action:
  kind: InvokeFlowTaskAction
  flowId: b5d08619-c241-f111-bec7-6045bd024dba

# AFTER (target env flowId — patched by install.ps1)
action:
  kind: InvokeFlowTaskAction
  flowId: a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

---

## How Skills / Knowledge Are Handled

The sample agent includes one `InlineAgentSkill`:

**`skills/schema-definitions-and-dax.md`** — ContosoRetail Power BI dataset schema:
- Table names and column types
- DAX query patterns (SUMX/FILTER joins, TOPN for sampling, adaptive row limits)
- Join patterns (no active relationships)

`export.ps1` fetches these by querying:
```
GET {orgUrl}/api/data/v9.2/botcomponents
  ?$filter=_parentbotid_value eq '{botId}' and componenttype eq 9
  &$select=botcomponentid,name,schemaname,data,description
```

`install.ps1` re-uploads them via:
```
POST {orgUrl}/api/data/v9.2/botcomponents
  { componenttype: 9, data: "kind: InlineAgentSkill\ncontent: |-\n  ...", ... }
```

---

## VS Code Editing Workflow

**Yes — NGO agents are fully editable in VS Code**, just like CGO agents.

All content files are plain text:

| File | What to edit |
|------|-------------|
| `settings.mcs.yml` | Agent instructions (the `StaticSegment` → `value` field), model series, auth |
| `actions/*.mcs.yml` | Tool descriptions, input/output definitions, DAX prompts |
| `workflows/{name}/workflow.json` | Power Automate flow logic (advanced) |

**Recommended workflow:**
1. Edit files in VS Code (install the [Power Platform Tools](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.powerplatform-vscode) extension)
2. Run `.\scripts\install.ps1` to push changes
3. Test in Copilot Studio

**The gap vs. CGO:** The VS Code extension handles flow-ID patching and skill upload automatically for classic agents. For NGO agents, `install.ps1` fills this gap until the extension adds NGO support.

Install the recommended extensions (`.vscode/extensions.json`):
- **Power Platform Tools** — pac CLI integration, schema validation
- **YAML** (Red Hat) — YAML editing support for `.mcs.yml` files
- **PowerShell** — script editing

---

## Dataverse Botcomponent Type Reference

| Type | Description |
|------|-------------|
| 9    | Tool / Action / InlineAgentSkill (knowledge) |
| 15   | Agent GPT config |
| 19   | Evaluation test case |

---

## Architecture: What pac clone Captures vs. What the Scripts Add

```
pac copilot clone captures:
├── agent.mcs.yml            ✓ (metadata)
├── settings.mcs.yml         ✓ (instructions, model, auth)
├── actions/*.mcs.yml        ✓ (but flowIds are source-env-specific!)
├── workflows/*/workflow.json ✓ (flow definitions)
└── translations/*.mcs.yml   ✓

pac copilot clone MISSES:
├── skills/*.md              ✗ (InlineAgentSkill botcomponents in DV)
└── (flowId remapping)       ✗ (needs manual fix after push)

This toolkit adds:
├── export.ps1               → exports skills from DV to ./skills/*.md
└── install.ps1              → patches flowIds + uploads skills to target DV
```

---

## Known Issues & Workarounds

| Issue | Workaround |
|-------|-----------|
| `az account get-access-token` fails for target tenant | Run `az login --tenant {tenantId}` first |
| Power BI connection references break after push | Manually re-configure connection references in target env's PPAC |
| `pac copilot push` error on second push | Check that action YAMLs have valid flowIds; re-run manually |
| Anthropic model not available in target env | Request Anthropic access for the target environment |

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache 2.0 — see [LICENSE](LICENSE).
