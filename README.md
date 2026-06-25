# Modern Copilot Studio Agent — Export / Import Toolkit

A complete toolkit for exporting, committing to source control, and importing
**Modern Copilot Studio agents** (`cliagent-1.0.0`) — including full coverage of the ALM
gaps that `pac` CLI does not handle out of the box.

---


## The problem this solves

Microsoft Copilot Studio agents exist in two architectures. The newer **Modern** agent
(template `cliagent-1.0.0`, recognizer `CLICopilotRecognizer`) has ALM behaviors that
the standard `pac copilot clone/push` workflow does not fully support:

| Gap | Without this toolkit |
|-----|---------------------|
| Skills uploaded as ZIP files (Python/binary assets) | Break silently after solution import — appear in UI but assets are missing. *Note: markdown-only InlineAgentSkills work correctly; this gap affects only skills bundled with Python scripts or binary files.* |
| `bot.configuration` (instructions, model) | Not written by `pac push`; edits made in the UI diverge from YAML |
| Flow tool GUIDs (`workflowId`, `flowId`) | Source-env GUIDs embedded in YAML — pac push fails with "Workflow Does Not Exist" |
| No documentation on these gaps | Developers hit silent failures with no clear cause |

This toolkit was built and tested end-to-end against a real Modern agent (Fabric Analyst)
to prove exactly what works, what breaks, and how to fix each gap.

---


## Prerequisites

| Tool | Install |
|------|---------|
| pac CLI | [https://aka.ms/PowerPlatformCLI](https://aka.ms/PowerPlatformCLI) |
| az CLI | [https://aka.ms/installazurecliwindows](https://aka.ms/installazurecliwindows) |
| pac auth | `pac auth create --environment https://myorg.crm.dynamics.com` |
| az login | `az login` |

**Permissions required:**
- Source environment: Copilot Studio agent read access, Dataverse read
- Target environment: Copilot Studio create/write, Dataverse write, Flow create

---


## Two paths

### Path 1 — Solution ZIP (distribute as a sample or between orgs)

```
Author → export.ps1 → agent.zip + skills-with-assets/ → commit
Recipient → install.ps1 → pac solution import + skill re-upload
```

**Best for:** distributing samples, provisioning new environments, cross-tenant transfers.

```powershell
# Export
.\path1-solution\export.ps1 `
  -SourceOrgUrl "https://myorg.crm.dynamics.com" `
  -AgentName    "Fabric Analyst" `
  -BotId        "d01d7579-bf47-4da7-b751-22a419ade844"

# Install (recipient runs this)
.\path1-solution\install.ps1 `
  -TargetOrgUrl "https://targetorg.crm.dynamics.com" `
  -ZipPath      ".\agent.zip"
```

### Path 2 — VS Code developer workflow (iterate in source control)

```
Developer → export.ps1 → YAML in sample/ → edit in VS Code → install.ps1 → deploy
```

**Best for:** iterating on agent logic, PR-based review, multi-environment CI/CD.

```powershell
# Export (clone to YAML)
.\path2-vscode\export.ps1 `
  -SourceOrgUrl "https://myorg.crm.dynamics.com" `
  -AgentName    "Fabric Analyst" `
  -BotId        "d01d7579-bf47-4da7-b751-22a419ade844"

# Install (push to target)
.\path2-vscode\install.ps1 `
  -TargetOrgUrl    "https://targetorg.crm.dynamics.com" `
  -AgentName       "Fabric Analyst" `
  -AgentSchemaName "cr7a0_FabricAnalyst_dQTqzr"
```

---

---

## Background: What makes a Modern agent different from Classic

| Property | Modern (`cliagent-1.0.0`) | Classic (`default-2.1.0`) |
|----------|--------------------------|--------------------------|
| Template | `cliagent-1.0.0` | `default-2.1.0` |
| Recognizer | `CLICopilotRecognizer` | `GenerativeAIRecognizer` |
| Topics | ❌ None — orchestration via instructions + tools | ✅ Topics-based conversation flow |
| Instructions | `bot.configuration` field in Dataverse (authoritative) | `settings.mcs.yml` |
| Flow tools | WorkflowTool + TaskDialog (two distinct types) | TaskDialog only |
| Skill types | InlineAgentSkill (markdown) + skills-with-assets (ZIP/Python) | N/A |

### bot.configuration
In Modern agents, the instructions text, AI model selection, and other settings live in
the `configuration` field on the `bot` Dataverse record. When you edit instructions in
the Copilot Studio UI, they are written to this field — NOT back to `settings.mcs.yml`.

`pac push` writes YAML files but does not touch `bot.configuration`. This means YAML
can become stale. This toolkit always exports `bot.configuration` and PATCHes it after
import/push to ensure the authoritative version is deployed.

### Two flow tool types

**WorkflowTool** (Copilot Studio Workflows — newer pattern):
- YAML: `translations/<schema>.tool.<name>.mcs.yml` with `kind: WorkflowTool`
- Contains: `workflowId: <source-env-guid>`
- Flow definition: `workflows/<name>-<guid>/workflow.json`

**TaskDialog / InvokeFlowTaskAction** (Agent Flows / Power Automate — older pattern):
- YAML: `actions/<name>.mcs.yml` with `kind: TaskDialog`
- Contains: `flowId: <source-env-guid>` (indented under `kind: InvokeFlowTaskAction`)
- Flow definition: `workflows/<name>-<guid>/workflow.json`

In both cases, the GUID is source-environment-specific. **Path 2** (VS Code) strips
and remaps them. **Path 1** (solution import) preserves GUIDs automatically.

### Two skill types

**InlineAgentSkill** — knowledge content in markdown, stored in `translations/*.skill.*.mcs.yml`.
Works correctly with both `pac solution import` and `pac push`. No extra steps needed.

**Skills with assets** — uploaded as a ZIP file (Python code, binary files).
Copilot Studio stores a bundle reference token (`bic:bundle=catskill_*_zip_*`) in the
botcomponent record, but the binary blob is stored separately. Neither `pac solution export`
nor `pac clone` captures the binary blob. After import, the skill appears in the UI but its
Python assets are missing. Our scripts detect and re-upload these blobs.

---


## What pac solution import handles (verified test results)

> **Note on skills and solution import**: The commonly reported issue — "skills don't work via 
> solution import" — is specific to skills uploaded as ZIP files (with Python/binary assets). 
> **InlineAgentSkills (markdown-based knowledge) import correctly** with no extra steps.
> The ZIP-skill gap is handled automatically by `install.ps1`.

| Test Case | Result |
|-----------|--------|
| `bot.configuration` (instructions + model) | ✅ PASS — `configuration.json` in ZIP is imported |
| InlineAgentSkill (markdown knowledge) | ✅ PASS — fully restored |
| ConnectorTool (standard connector) | ✅ PASS — connector stubs created |
| McpTool | ✅ PASS — tool definitions restored |
| ConnectedAgentTool | ✅ PASS — restored by schema name |
| WorkflowTool (Copilot Studio Workflow) | ✅ PASS — flow GUIDs preserved by solution import |
| TaskDialog / InvokeFlowTaskAction (Agent Flow) | ✅ PASS — preserved by solution import |
| Evaluation test cases | ✅ PASS — fully restored |
| Connection reference stubs | ✅ PASS — created (empty, user wires manually — normal) |
| Skill with binary assets (ZIP+Python) | ⚠️ PARTIAL — record exists, bundle blob missing → `install.ps1` re-uploads |

**Critical requirement**: `AddRequiredComponents = $true` MUST be set when adding the bot
to the distribution solution. Without it, botcomponents (tools, skills) are NOT included
in the solution export. `export.ps1` handles this automatically.

---


## VS Code workflow

All Modern agent YAML is plain text and fully editable. Recommended setup:

1. Install [Power Platform Tools extension](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.powerplatform-vscode)
2. Open this repo in VS Code — `.vscode/settings.json` configures YAML schema validation
3. `*.mcs.yml` files are associated with YAML for syntax highlighting

**Key files per component type:**

| Component | File location |
|-----------|--------------|
| Agent settings / description | `settings.mcs.yml` |
| ConnectorTool | `translations/<schema>.tool.<connector-name>.mcs.yml` |
| McpTool | `translations/<schema>.httpslearnmicrososftcom_*.mcs.yml` |
| WorkflowTool | `translations/<schema>.tool.<name>.mcs.yml` (has `kind: WorkflowTool`) |
| InlineAgentSkill | `translations/<schema>.skill.<name>.mcs.yml` |
| ConnectedAgentTool | `translations/<schema>.action.<name>.mcs.yml` |
| TaskDialog / AgentFlow | `actions/<name>.mcs.yml` + `workflows/<name>-<guid>/` |
| URL knowledge sources | `knowledge/*.mcs.yml` |
| Connection references | `connectionreferences.mcs.yml` |
| Instructions + model | `sample/agent-config.json` → patched to `bot.configuration` after push |

---


## Known limitations (honest, not scary)

| Limitation | Mitigation |
|------------|-----------|
| Skills with binary assets need post-import re-upload | `install.ps1` (Path 1) handles this automatically |
| ConnectedAgentTool: child agent must exist by same schema name in target | Create or deploy the child agent first |
| Connection wiring: one-time manual step per env per connector | Normal platform behavior — document connectors required |
| Anthropic/Claude model availability: target env must have Claude model access | Check model availability in PPAC |
| Bot schema name 100-char Dataverse limit | `install.ps1` warns with fix instructions; rename tool in source |
| Flow creation requires Dataverse write on `workflows` entity | Ensure deploying user has the correct security role |

---


## Repo structure

```
path1-solution/
  export.ps1               ← pac solution export + skill bundle export
  install.ps1              ← pac solution import + skill bundle re-upload
  post-import-skills.ps1   ← standalone: re-upload skill bundles only

path2-vscode/
  export.ps1               ← pac copilot clone + bot.configuration export
  install.ps1              ← bot pre-create + pac push + flow GUID remap + bot.configuration PATCH

sample/
  Fabric Analyst/          ← example agent YAML (from pac copilot clone)
  agent-config.json        ← example bot.configuration

solution/
  FabricAnalystSample.zip  ← example solution package
  PresentationBuddySample.zip

skills/
  schema-definitions-and-dax.md  ← example InlineAgentSkill content

screenshots/               ← documentation screenshots
```

---


## Tested on

Tested end-to-end with **Fabric Analyst** agent:
- Template: `cliagent-1.0.0`
- Tools: ConnectorTool (Fabric REST), WorkflowTool (DAX query, dataset refresh)
- Skills: InlineAgentSkill (schema definitions + DAX patterns)
- Eval cases: 3 test cases
- Connection references: Power BI, Fabric REST API

All 10 test cases passed. See table above.




