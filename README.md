# Distribute-Develop-Modern-CopilotStudio-agents

A toolkit for **Modern Copilot Studio agents** (`cliagent-*` template — instructions + tools, no topics; covers both **CGO** `GenerativeAIRecognizer` and **NGO** `CLICopilotRecognizer`).

> **Why this exists (pac CLI gap, June 2026):** for `cliagent-*` agents, `pac copilot pack` crashes, `pac copilot pull` crashes, `pac copilot push` silently drops components, and `pac copilot publish` crashes. So this toolkit does **not** rely on any of them. It deploys with the mechanisms that *are* reliable: **Dataverse solution import** (structure) and **targeted Dataverse writes** (your edits). See [LEARNINGS.md](LEARNINGS.md) for the evidence.

Two workflows:
- **distribute/** — package an agent as a ZIP, share it, install it into any environment.
- **develop/** — clone an agent to editable files, change it in VS Code, redeploy reliably.

---

## Prerequisites

| Tool | Install |
|------|---------|
| pac CLI | https://aka.ms/PowerPlatformCLI |
| az CLI | https://aka.ms/installazurecliwindows |
| pac auth | `pac auth create --environment https://yourorg.crm.dynamics.com` |
| az login | `az login` (needs Dataverse access) |

The **develop/** path also benefits from the [Power Platform Tools for VS Code](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.powerplatform-vscode) extension for YAML schema hints.

**Identify your agent.** Both paths need your agent's **BotId** — the GUID in the Copilot Studio URL `https://copilotstudio.microsoft.com/environments/{envId}/agents/{BotId}`. Your agent must use the `cliagent-*` template (Classic `default-2.x.x` agents are not supported).

---

## distribute/ — share an agent as a ZIP

The primary workflow: package an agent into a single bundle and install it into any environment.

**Export** (run once to produce a shareable bundle):
```powershell
.\distribute\export.ps1 `
  -SourceOrgUrl  "https://yourorg.crm.dynamics.com" `
  -BotId         "your-bot-guid" `
  -SolutionName  "MyAgentSample" `
  -PublisherName "myprefix"          # publisher unique name OR customization prefix
# Produces: MyAgent-bundle.zip
```

**Install** (anyone can run this against their own environment):
```powershell
.\distribute\install.ps1 `
  -BundleZip    ".\MyAgent-bundle.zip" `
  -TargetOrgUrl "https://targetorg.crm.dynamics.com"
# Agent appears in Copilot Studio. The script guides any connection wiring and skill upload.
```

After install, two one-time-per-environment steps (the script tells you exactly what to do): wire connections for any connector flows in Power Automate, and re-upload any skills that run Python/code via the CS UI.

### What transfers — component support matrix

| Component | Transfers | Notes |
|-----------|:---------:|-------|
| Agent instructions + model (bot.configuration) | ✅ | Full round-trip |
| ConnectorTools (standard MS connectors) | ✅ | Connection wiring is one manual step per env |
| WorkflowTool / TaskDialog (Agent Flows) | ✅ | Carried in the bundle (flow GUIDs preserved) |
| InlineAgentSkill (markdown skill) | ✅ | Full round-trip |
| URL knowledge sources | ✅ | Full round-trip |
| File knowledge (PDF, DOCX) | ✅ | Binary preserved in the bundle |
| Evaluation test cases | ✅ | Carried in the bundle |
| ConnectedAgentTool | ✅ | Child agent must exist in target by the same schema name |
| Skill with Python/code assets | ⚠️ manual | One-time ZIP re-upload via the CS UI (see note below) |
| MCP server tools | ⚠️ | Definition transfers; server must be reachable at the same URL in target |
| Custom connectors with inline code | ❌ | Azure Functions provisioning is unreliable — platform issue |
| Classic agents (`default-2.x.x`) | ❌ | Different architecture — use standard pac solution tooling |

> **Why skills with code need a one-time manual upload:** uploading a skill ZIP through the Copilot Studio UI triggers a server-side process that stores the Python/binary assets in Azure blob storage and mints an environment-specific bundle token. A transferred skill carries only a `bic:bundle=` pointer to the **source** environment's blob, which 404s in the target — so the model can read neither the instructions nor the code until you re-upload. There is no public API for this; the install script detects the broken skill, rebuilds the ZIP, and points you to where to upload it. The scripts deliberately do **not** silently rewrite the skill to inline markdown (that would look fixed while the code still can't run). See [LEARNINGS.md](LEARNINGS.md) for details.

---

## develop/ — edit an agent in VS Code, redeploy

The development workflow: clone an agent to editable files, change it locally under source control, and redeploy reliably (via solution import, not `pac copilot push`).

**Export** (clone to editable files + build a deployable bundle):
```powershell
.\develop\export.ps1 `
  -SourceOrgUrl  "https://yourorg.crm.dynamics.com" `
  -BotId         "your-bot-guid" `
  -AgentName     "My Agent" `
  -SolutionName  "MyAgentSample" `
  -PublisherName "myprefix"
# Produces:
#   sample/My Agent/                 editable YAML (read / diff / review)
#   sample/My Agent.instructions.md  the instructions — edit this to change behaviour
#   sample/agent-config.json         model + AI settings
#   My Agent-bundle.zip              the deployable artifact
```

**Edit, then deploy:**
```powershell
.\develop\install.ps1 `
  -BundleZip    ".\My Agent-bundle.zip" `
  -TargetOrgUrl "https://targetorg.crm.dynamics.com"
# Solution import (full structure) + applies your instruction/skill edits via Dataverse.
# Ends by opening the agent for the one-click Publish.
```

### What you change in VS Code vs. in the Copilot Studio UI

The boundary is **wording/behaviour vs. structure** — the scripts state it at every step.

| You want to… | Where | How it deploys |
|---|---|---|
| Change the agent's **instructions** (system prompt, rules, persona) | ✅ **VS Code** — `sample/<Agent>.instructions.md` | `develop/install.ps1` → `bot.configuration` |
| Change the **model** or **AI settings** | ✅ **VS Code** — `sample/agent-config.json` | `develop/install.ps1` → `bot.configuration` |
| Edit an **inline (markdown) skill's** content | ✅ **VS Code** — `sample/<Agent>/translations/*.skill.*.mcs.yml` | `develop/install.ps1` → component `data` patch |
| Reword a **tool / knowledge description** | ✅ **VS Code** — matching `translations/` or `knowledge/` file | `develop/install.ps1` → component `data` patch |
| **Add / remove** a tool, connector, or flow | ⚠️ **Copilot Studio UI** | Build it in CS, then re-run `develop/export.ps1` |
| **Add** a skill that runs Python / code | ⚠️ **Copilot Studio UI** (code-bundle upload) | Upload the skill ZIP in CS (the script hands you the ZIP) |
| **Add** file knowledge (PDF, DOCX) | ⚠️ **Copilot Studio UI** (binary upload) | Upload in CS, then re-export |
| **Publish** changes to go live | ⚠️ **Copilot Studio UI** — one click | Click **Publish**; the script opens the agent for you |

**Rule of thumb:** editing the *words and behaviour* of things that already exist → VS Code. Adding *new structure*, or anything needing a connection or binary upload → Copilot Studio UI, then re-export. Every deploy ends with a one-click **Publish** (`pac copilot publish` crashes for cliagent-*). The cloned YAML in `sample/<Agent>/` is always useful for reading, diffing, and code review — even for structural parts you can't push from the CLI.

---

## Repo structure

```
distribute/
  export.ps1    ← export agent → {AgentName}-bundle.zip (surgical solution add + skill assets)
  install.ps1   ← pac solution import + skill re-upload guidance + connection wiring

develop/
  export.ps1    ← pac clone (editable YAML) + instructions.md + agent-config.json + deployable bundle
  install.ps1   ← pac solution import + apply instruction/skill edits via Dataverse + Publish guidance

LEARNINGS.md    ← tested findings, pac CLI gap analysis, known bugs, the component-type enum trap
CONTRIBUTING.md ← how to contribute
SECURITY.md / SUPPORT.md / CODE_OF_CONDUCT.md
```

---

See [LEARNINGS.md](LEARNINGS.md) for the technical detail behind all of this: the reliable-vs-unreliable pac commands, the Default Solution membership problem, the solutioncomponent enum trap, and the skills-with-assets mechanism.
