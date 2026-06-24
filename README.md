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


---

## End-to-End Test Results (Jun 24, 2026)

### What Was Tested
- **Source**: Fabric Analyst agent in CDX (`orgea8005ed`) — `cliagent-1.0.0` template
- **Target**: Zava PP (`org07697283`)

### What Worked ✅

| Step | Result |
|------|--------|
| DV API skill discovery (type 9 botcomponents) | ✅ `data` field contains InlineAgentSkill YAML |
| Agent creation via `POST /api/data/v9.2/bots` | ✅ Creates a new NGO agent |
| `pac copilot clone` of new empty agent | ✅ Gets a valid workspace for the target env |
| `pac copilot push` (flowId stripped) | ✅ 7 changes: settings, action botcomponents, GPT config |
| Connection reference creation via DV API | ✅ `POST /api/data/v9.2/connectionreferences` |
| Flow creation via DV API (`statecode=0, statuscode=1`) | ✅ Flows created in Draft state |
| `pac copilot push` (with new flowId) | ✅ 8 changes: action botcomponents linked to flows |
| Skill upload via `POST /api/data/v9.2/botcomponents` | ✅ `schema-definitions-and-dax` visible in Copilot Studio |
| Agent visible in Copilot Studio | ✅ "Fabric Analyst" in Zava PP agents list |

### What pac push Does NOT Do (Discovered) ❌

1. **pac push does NOT create new agents** — `Entity 'bot' With Id = ... Does Not Exist`. You must create the bot via DV API first.

2. **pac push does NOT create Power Automate flows** — `Entity 'Workflow' With Id = ... Does Not Exist`. The `workflows/` directory content is ignored unless the flow already exists. You must create flows separately via the DV API.

3. **pac push requires a workspace linked to the target env** — the `.mcs/botdefinition.json` from a source env clone contains env-specific types (`CloudFlowDefinition`, `UnknownDialogBase` in pac 2.8.1) that cause crashes. You must clone from the TARGET env first.

4. **pac push requires `AgentId` to be non-null** — `Sync info is missing Id` error. The bot must pre-exist.

### The Flow ID Problem — Confirmed

pac push with source-env `flowId` in action YAML fails with:
```
{"errors":[{"code":10000,"message":"Entity 'Workflow' With Id = b5d08619... Does Not Exist"}]}
```

The fix is:
1. Strip `flowId` from action YAMLs before first push → creates action botcomponents without flow links
2. Create flows via DV API → get new GUIDs  
3. Add `flowId` with new GUIDs → re-push → links actions to flows

### Instructions Not Visible in New UI

The Copilot Studio "New experience" UI shows a blank instructions field. The instructions in `settings.mcs.yml` (`StaticSegment`) ARE pushed correctly (verified via DV API `configuration` field), but the new UI displays them differently than the classic view. The agent will run with the correct instructions.

### Skills — Confirmed Working

The `schema-definitions-and-dax` skill appears in the Copilot Studio Skills section after `POST /api/data/v9.2/botcomponents`. The skill knowledge is immediately available to the agent.

### Flows Require Manual Connection

Power Automate flows are created in **Draft** state. They require a human to:
1. Create a Power BI connection in PPAC
2. Link it to the connection reference
3. Flows then auto-activate

This is a one-time manual step per environment. The flow logic itself is fully imported.

### pac auth Note

Both CDX (source) and Zava PP (target) environments are in the same CDX tenant (`301759bc-5be1-40f1-8a44-822e286f5a9d`). pac auth index 2 (`karima@M365x05526665.onmicrosoft.com`) has access to both. The install.ps1 uses `--index 2` by default.
