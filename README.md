# Distribute-Develop-Modern-CopilotStudio-agents

**Package a Copilot Studio agent into one file and install it into any environment — with a single command.**

Use it to share a ready-made agent as a sample, move an agent between your dev/test/prod environments, or hand someone a working agent they can install and start exploring.

## Why this tool

Copilot Studio has two kinds of agent:

- **Modern agents** — built from **instructions + tools + knowledge** (the kind most people build today).
- **Classic agents** — the older, **topic-based** style.

Microsoft's built-in solution export/import and the VS Code Power Platform extension were designed around classic agents, and they don't move a **modern** agent cleanly from one environment to another — pieces get dropped or the agent won't deploy. This tool fills that gap so a modern agent travels in one piece, every time.

## What you need

| | |
|---|---|
| **PowerShell 7+** | https://aka.ms/powershell — run the commands in `pwsh` |
| **Power Platform CLI** (`pac`) | https://aka.ms/PowerPlatformCLI |
| **Azure CLI** (`az`) | https://aka.ms/installazurecliwindows |
| **Signed in** | `pac auth create --environment https://yourorg.crm.dynamics.com` and `az login`, both pointing at your environment |

You'll also need to point the script at your agent — either by its **name** or its **id**:
- **By name** (easiest): pass `-AgentName "My Agent"` and the script finds it for you.
- **By id**: pass `-BotId` with the GUID from the agent's Copilot Studio web address
  (`.../agents/{this-is-the-agent-id}`).

---

## Quickstart — share and install an agent

### 1. Package the agent (run once)

```powershell
.\distribute\export.ps1 `
  -SourceOrgUrl  "https://yourorg.crm.dynamics.com" `
  -AgentName     "My Agent" `        # or use -BotId "your-agent-id"
  -SolutionName  "MyAgentSample" `
  -PublisherName "yourprefix"        # your publisher prefix (e.g. "cr1a2") or its unique name
```

You get **one file**: `MyAgent-bundle.zip`. Share it, commit it, or email it.

### 2. Install it into any environment

```powershell
.\distribute\install.ps1 `
  -BundleZip    ".\MyAgent-bundle.zip" `
  -TargetOrgUrl "https://targetorg.crm.dynamics.com"
```

The agent appears in Copilot Studio. The script then prints the exact finishing steps **for that specific agent** — only the ones that actually apply.

> **Want to preview first?** Add `-WhatIf` to the install command to see exactly what it would do — which agent it imports, which tables it recreates, which skills need a re-upload, which flows to turn on — **without changing anything**. Run it again without `-WhatIf` to actually install.

> **Custom tables come along automatically.** If your agent's flows use a custom Dataverse table, the export bundles that table's design **plus a few sample rows** (5 by default, set with `-SeedRows`), and install recreates the table and adds those rows for you — so a table-backed sample just works. (Only *your* tables; Microsoft's built-in tables already exist everywhere and are left alone. If a row already exists in the target, install won't add a duplicate.)
>
> **If install ever stops with a "missing dependency" message:** your agent needs something the target environment doesn't have yet (for example a custom connector). The message names exactly what's missing — add it in the target, then run install again. (The tool checks for this instead of pretending the install worked.)

### 3. Finish setup (only what applies to your agent)

- **Skills that include a code file** — a skill you uploaded as a `.zip` with Python in it can't carry its code across environments, so it arrives empty and Copilot Studio flags it. The script rebuilds the `.zip` for you; upload it once in the agent (click the skill → ⋯ → **Replace/Edit** → upload → Save). *Skills whose code is written straight into the skill text come across fine — nothing to do.*
- **Agent flows (Power Automate)** — they import **already connected to your agent**; they just arrive turned **off** with no connection. In [make.powerautomate.com](https://make.powerautomate.com), open each flow → it asks you to fix the connection → pick or create one → **Save** → **turn it On**.
- **Publish** — in Copilot Studio, click **Publish** to make your changes live. (The script opens the agent for you.)

*P.S. — "wiring a connection" in step 2 is the normal Power Platform step for any flow in a new environment; nothing special to this tool.*

### What moves with your agent

| Part of the agent | Comes across | Notes |
|---|:---:|---|
| Instructions + chosen model | ✅ | Exactly as set |
| Tools (standard connectors) | ✅ | Give the flow a connection after install |
| Agent flows (Power Automate) | ✅ | Imported and linked; turn them on |
| Skills (text / inline code) | ✅ | Fully |
| Skills with a code file (`.zip`) | ⚠️ once | Upload the `.zip` once in Copilot Studio |
| Knowledge — web links | ✅ | Link and its description come across |
| Knowledge — files (PDF, Word) | ✅ | The file travels in the bundle |
| Test cases | ✅ | Fully |
| Custom Dataverse tables a flow uses | ✅ | Table design + a few sample rows are bundled; install adds them if the table is empty |
| Child-agent tools (one agent calling another) | ✅ | The child agent must already exist in the target (matched by its internal name) |
| Connect-an-AI-service tools (Microsoft-published MCP) | ✅ | Comes across like a connector — give it a connection after install |
| Your own MCP server tools | ⚠️ † | Comes across, but your server must be reachable at the same address and its connector must exist in the target |
| Custom connectors that contain code | ❌ † | The code layer doesn't move reliably — a platform limit |

† Not exercised in this tool's own tests. See [LEARNINGS.md](LEARNINGS.md).

---

## Edit an agent in VS Code, then redeploy

Want to change an agent and push the change? The **develop** path clones the agent into editable files, you edit, and it redeploys — reliably (it installs the bundle, then applies your edits; it does **not** use the unreliable CLI push).

```powershell
# 1. Clone to editable files + build the deployable bundle
.\develop\export.ps1 `
  -SourceOrgUrl  "https://yourorg.crm.dynamics.com" `
  -AgentName     "My Agent" `        # finds the agent by name (or add -BotId "your-agent-id")
  -SolutionName  "MyAgentSample" `
  -PublisherName "yourprefix"

# 2. Edit the files (see table below), then deploy
.\develop\install.ps1 `
  -BundleZip    ".\My Agent-bundle.zip" `
  -TargetOrgUrl "https://targetorg.crm.dynamics.com"
```

### What you edit in files vs. in Copilot Studio

| You want to… | Do it in… |
|---|---|
| Change the **instructions** | a file — `sample/<Agent>.instructions.md` |
| Change the **model** or AI settings | a file — `sample/agent-config.json` |
| Change a **skill's text** | a file — `sample/<Agent>/translations/…skill…` |
| Reword a **tool's or skill's description** | a file — the same place |
| **Add or remove** a tool, connector, flow, or knowledge source | Copilot Studio, then re-run the export |
| **Add** a code-file skill or a knowledge file (PDF/Word) | Copilot Studio, then re-run the export |
| **Publish** to go live | Copilot Studio (one click) |

**The simple rule:** changing the *words and settings* of things that already exist → do it in files. *Adding new pieces* → do it in Copilot Studio, then export again. Every deploy ends with one **Publish** click.

---

## Under the hood

This tool installs your agent as a Dataverse **solution** (the reliable way to move every piece at once) and then applies any file edits with small, targeted Dataverse updates. It deliberately avoids the Copilot Studio CLI commands that are unreliable for modern agents today, and it verifies the install really happened instead of trusting a "success" message. The full reasoning, every tested finding, and the known platform quirks are in **[LEARNINGS.md](LEARNINGS.md)**.

## What's in this repo

```
distribute/   export.ps1     →  package an agent into one bundle file
              export-all.ps1 →  package every modern agent in an environment (one bundle each)
              install.ps1    →  install a bundle into any environment (supports -WhatIf preview)

develop/      export.ps1  →  clone to editable files + build the bundle
              install.ps1 →  install the bundle and apply your file edits (supports -WhatIf)

LEARNINGS.md        the tested findings and platform details
SPEC.md             what the tool does and why (source of truth)
CONTRIBUTING.md · SECURITY.md · SUPPORT.md · CODE_OF_CONDUCT.md
```

> **Back up or migrate a whole environment:** `distribute\export-all.ps1 -SourceOrgUrl "..." -PublisherName "yourprefix"` exports every modern agent into its own bundle in one folder.


