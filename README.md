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
| PowerShell 7+ | https://aka.ms/powershell (the scripts use PS7 syntax; Windows PowerShell 5.1 will not run them) |
| pac CLI | https://aka.ms/PowerPlatformCLI |
| az CLI | https://aka.ms/installazurecliwindows |
| pac auth | `pac auth create --environment https://yourorg.crm.dynamics.com` |
| az login | `az login` (needs Dataverse access) |

Run the scripts in **`pwsh`** (PowerShell 7), and make sure your `pac auth` profile and `az login` both point at the right environment. Each script takes an `-AuthIndex` to select the `pac auth` profile (see `pac auth list`).

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
# Agent appears in Copilot Studio. The script prints the exact follow-up steps for your agent.
```

#### After install

The agent, its tools, skills, knowledge and flows are imported. Depending on what your agent uses, up to three follow-ups remain — the script lists exactly the ones that apply:

1. **ZIP-packaged skills** (only if your agent has them). A skill uploaded as a `.zip` bundling Python + `SKILL.md` stores its code in the *source* environment's storage, which can't travel in a solution. The skill imports **empty** and Copilot Studio flags it. Fix once: open the agent → click the skill → ⋯ → **Replace/Edit** → upload the ZIP the script rebuilt for you → Save. *(Skills whose code is written **inline** in the skill text are not affected — they transfer fully.)*

2. **Agent flows** (only if your agent uses Power Automate flows). They import **already linked to the agent's tools** — there is nothing to "add". They simply arrive **turned off with no connection**. Activate each one in [make.powerautomate.com](https://make.powerautomate.com): open the flow → it shows *"a connection that needs to be fixed"* → assign or create a connection → **Save** → **turn the flow On**.

3. *P.S. — connections.* Step 2 is the standard Power Platform "wire a connection per environment" step; it applies to any solution with connector-backed flows, not just this toolkit. Nothing special here.

Then **Publish** the agent in Copilot Studio to make it live on channels.

### What transfers — component support matrix

Legend: ✅ transfers automatically · ⚠️ transfers, one manual step · ❌ not supported. A † marks rows **reasoned from connector/solution mechanics but not exercised in this toolkit's own tests** — verify for your agent.

| Component | Transfers | Notes |
|-----------|:---------:|-------|
| Agent instructions + model (bot.configuration) | ✅ | Full round-trip |
| ConnectorTools (standard MS connectors) | ✅ | Flow imports linked but off; wire a connection + turn on |
| Agent flows (WorkflowTool / TaskDialog) | ✅ | Carried in the bundle, GUIDs preserved, tool→flow link intact |
| Inline skills (markdown, incl. **inline** code) | ✅ | Full round-trip |
| URL knowledge sources | ✅ | Full round-trip incl. the source's description (tested) |
| File knowledge (PDF, DOCX) | ✅ | Binary preserved in the bundle |
| Evaluation test cases | ✅ | Carried in the bundle |
| ConnectedAgentTool † | ✅ | Child agent must already exist in target by the same schema name |
| **ZIP-packaged skills** (`.zip` of Python + SKILL.md) | ⚠️ manual | One-time ZIP re-upload via the CS UI (see note below) |
| **OOB MCP tools** (Microsoft-published MCP connector) † | ⚠️ | Behaves like a ConnectorTool: definition transfers, wire a connection |
| **Custom MCP tools** (your own MCP server) † | ⚠️ | Definition transfers, but the server must be reachable at the **same URL** in the target and the custom connector/connection must exist there |
| Custom connectors with inline code † | ❌ | Azure Functions provisioning is unreliable — platform issue |
| Classic agents (`default-2.x.x`) | ❌ | Different architecture — use standard pac solution tooling |

> **The two kinds of "Python skill" — only one needs a manual step:**
> - **Inline-code skill** — the Python/logic is written *inside* the skill's markdown. It lives in the skill's `data` field and transfers like any inline skill. **Nothing to do.**
> - **ZIP-packaged skill** — you uploaded a `.zip` bundling `.py` files + `SKILL.md`. Copilot Studio stored the code in Azure blob storage in the *source* environment and left only a `bic:bundle=` pointer in the record. That pointer 404s in the target, so the skill imports **empty** and CS flags it. There is no public API to recreate the bundle — only a UI upload does. The install script detects this, rebuilds the ZIP, and tells you exactly where to upload it. The scripts deliberately do **not** silently rewrite it to inline markdown (that would *look* fixed while the code still can't run). See [LEARNINGS.md](LEARNINGS.md).


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
| Change the agent's **instructions** (system prompt, rules, persona) | ✅ **VS Code** — `sample/<Agent>.instructions.md` | `bot.configuration` patch |
| Change the **model** or **AI settings** | ✅ **VS Code** — `sample/agent-config.json` | `bot.configuration` patch |
| Edit an **inline skill's** content | ✅ **VS Code** — `sample/<Agent>/translations/*.skill.*.mcs.yml` | component `data` patch |
| Reword a **tool or skill description** | ✅ **VS Code** — the `description:` line in the matching `translations/` file | component `description` patch |
| **Edit a ZIP-packaged skill's code** (`.py` files) | ⚠️ **Copilot Studio UI** | Re-upload the skill ZIP in CS (the script rebuilds it for you) |
| **Add / remove** a tool, connector, or flow | ⚠️ **Copilot Studio UI** | Build it in CS, then re-run `develop/export.ps1` |
| **Add or edit a knowledge source** (URL or its description) | ⚠️ **Copilot Studio UI** | Change it in CS, then re-export — it round-trips in the bundle |
| **Add** a skill packaged as a code ZIP, or **file knowledge** (PDF/DOCX) | ⚠️ **Copilot Studio UI** (binary upload) | Upload in CS, then re-export |
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
