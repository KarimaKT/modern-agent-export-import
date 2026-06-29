# Specification — Distribute-Develop-Modern-CopilotStudio-agents

> This is the **source of truth** for the project. Update it **before** changing behavior or docs.
> It records what the tool does, why, what we assume, what we've proven, what we've decided, and
> what we still want to improve. Keep it accurate across versions so the tool stays reliable.
>
> **Spec version:** 1.0 · **Last updated:** 2026-06-26 · **Status of tool:** released (v1)

---

## 1. Purpose & audience

### 1.1 One-line purpose
Package a modern Copilot Studio agent into a single file and install it into any Power Platform
environment with one command.

### 1.2 Who it's for
**Low-code makers** — people who build agents in Copilot Studio and want to grab a working sample,
move an agent between environments, or share one for others to explore. **Not** primarily coders.
Many users won't know there are two kinds of Copilot Studio agent; the tool and its docs must not
assume that knowledge.

### 1.3 The problem it solves
Copilot Studio has two agent styles:
- **Modern** — built from instructions + tools + knowledge (most agents today).
- **Classic** — older, topic-based.

Microsoft's built-in solution export/import, the older Copilot Studio agent packaging commands, and
the VS Code Power Platform extension were designed around **classic** agents. They do not move a
**modern** agent cleanly between environments — components are dropped, GUIDs collide, or the deploy
crashes. This tool fills that gap so a modern agent travels in one piece.

### 1.4 Success criteria
1. A maker can package a modern agent with one command and install it elsewhere with one command.
2. The install never reports false success — if something didn't land, it says so and why.
3. After install, the user is told the **exact** finishing steps for **their** agent, in plain
   language, and only the steps that apply.
4. Works for **any** maker in **any** environment — no hardcoded tables, prefixes, or assumptions.

---

## 2. Audience & writing rules (for all user-facing docs)

1. **No jargon at the top.** Never use `CGO`, `NGO`, `cliagent-*`, `GenerativeAIRecognizer`,
   `CLICopilotRecognizer`, `WorkflowTool`, `InlineAgentSkill`, `bic:bundle=`, or component-type
   numbers in the README intro/quickstart. Those live in §8 and in `LEARNINGS.md` only.
2. **Plain agent-type words:** modern = instructions + tools + knowledge; classic = topic-based.
3. **Structure:** one-sentence purpose → short plain "why" → quickstart. Lead with **distribution**
   (share/install a sample), then **develop** (edit), then a short technical note linking to
   `LEARNINGS.md`. Emphasize **one command**.
4. **Voice:** warm, helpful, low-code. Use plain part names: "agent flows (Power Automate)",
   "skills", "skills with a code file", "knowledge web links", "knowledge files (PDF/Word)",
   "test cases".
5. **Keep tested accuracy**, but say it in maker language. Exact technical names belong in
   `LEARNINGS.md`.

---

## 3. Scope

### 3.1 In scope
- Export a modern Copilot Studio agent as a self-contained bundle (`distribute/`).
- Install that bundle into any environment, with honest post-install guidance (`distribute/`).
- Clone an agent to editable files, edit locally, and redeploy reliably (`develop/`).
- **Self-contained samples:** when an agent's flows depend on a **custom** Dataverse table, bundle
  the table definition + one seed row so install recreates a working sample automatically (§4.5).
- Detect and clearly report conditions the maker must resolve (other missing dependencies, skills
  with a code file, flows needing a connection, publish).

### 4.5 Self-contained table dependencies (custom Dataverse tables)
**Problem:** a flow that reads/writes a **custom** table (e.g. `cr1a2_orders`) makes the agent
depend on that table existing in the target. Without it, solution import fails.

**Behavior (tested mechanism — see §11):**
- **export** (both paths, in `distribute/export.ps1`):
  1. Detect custom-table references in each flow's `clientdata` — `"entityName":"<set or logical>"`
     and entity-set URL refs. Map each to its `EntityDefinitions` record; **keep only the maker's own
     tables: `IsCustomEntity = true` AND `IsManaged = false`** (Microsoft platform tables such as
     `msdyn_*`/AI Builder report `IsCustomEntity=true` but `IsManaged=true` and already exist in the
     target — never bundle those; system/standard tables are skipped too).
  2. Add each custom table's **Entity** to the solution: `AddSolutionComponent ComponentType=1
     AddRequiredComponents=$true` (pulls the table's columns + choice sets). Import will recreate it.
  3. Export up to **N sample rows** (default 5, set by `-SeedRows`) per table to
     `seed-data/<logical>.json` as a JSON **array** — only the table's own custom columns (those
     starting with the table's publisher prefix), excluding the primary-id and all system/navigation
     fields. **Warn at export** that these rows ship in the bundle, so they must not contain
     real/sensitive data. Record each table in `manifest.json` under `seedTables`
     (`logical`, `setName`, `primaryName`, `rowCount`).
- **install** (both paths): after a verified solution import, for each `seedTables` entry, if the
  target table currently has **zero rows**, insert all the sample rows and **warn the user they are
  SAMPLE data to replace with their own**. Best-effort and non-fatal; never overwrites existing data
  and re-installs don't duplicate (the empty-check guards it).*, insert the one seed row. This is **best-effort and
  non-fatal** — a failed seed insert warns but never aborts (the table and agent still installed).

**Why a few sample rows (not the whole table):** enough for the agent to demonstrate real behavior
on first run, without shipping someone's full dataset. Default 5 (tunable via `-SeedRows`). The rows
come from the source table, so the maker curates fictional/sample data there for a shareable sample;
the export and import both warn that these are sample rows to replace.

**Assumptions:** A8 (below). **Decision:** D9 (below). **Backlog U1 is now resolved by this.**

### 4.7 Identify the agent by name OR id (low-code friendly)
Makers often don't know what a GUID is. Both **export** scripts accept the agent's **display name**
as an alternative to its id:
- `distribute/export.ps1` and `develop/export.ps1` take `-BotId` (optional) and `-AgentName`.
- If `-BotId` is given, it is used as-is.
- Else the script resolves `-AgentName` among the source environment's **modern** agents:
  - **exactly one match** → use it (print which id was chosen);
  - **no match** → error listing the available modern agent names;
  - **more than one match** → if interactive, show a numbered pick list (name + id + last modified)
    and let the maker choose; if non-interactive, error and list the matching ids so they can pass
    `-BotId`.
- Name match is case-insensitive and exact on display name. (`develop/export.ps1` already uses
  `-AgentName` as the local folder name; it now doubles as the resolver.)
**Decision:** D10. **Backlog U2 resolved by this.**

### 4.8 Friendly first-run checks (preflight)
Low-code makers may not have the CLIs installed or signed in. Each script, at the point it acquires
a Dataverse token, gives **clear, actionable guidance** instead of a raw error when:
- the **Azure CLI** (`az`) isn't installed → link to install it;
- `az` isn't signed in → tell them to run `az login`;
- the **environment URL** can't be reached / token can't be acquired → say the URL may be wrong or
  they may need to sign in to that tenant.
The `pac` CLI is already auto-detected with an install message. Preflight returns the token so the
script reuses it (no double calls). **Decision:** D11.

### 4.9 `-WhatIf` dry run (preview before changing anything)
Both install scripts accept `-WhatIf`. With it, the script reads the bundle, prints a plain-language
plan of everything it *would* do to the target — import the agent, recreate/seed which custom
tables, which skills need a one-time re-upload, which flows need activating, and the final publish —
then exits **without making any change** (no import, no writes). Lets a cautious maker see the
impact first. **Decision:** D12.

### 4.10 Export every agent in an environment (`distribute/export-all.ps1`)
A convenience wrapper for backing up or migrating a whole environment. It lists every **modern**
agent in the source environment and runs `distribute/export.ps1` for each, writing one bundle per
agent into an output folder (one solution per agent, named from the agent). It continues past any
single agent's failure and prints a summary (which bundles were produced, which agents failed and
why). Skips classic agents with a note. **Decision:** D13.

### 4.6 (was 4.5) the rest of the path behaviors continue below


### 3.2 Out of scope (today)
- Classic (topic-based) agents — use standard Power Platform solution tooling.
- Creating agents from scratch.
- Adding **new** structural components (tools/flows/connectors/file-knowledge/code-skills) from
  local files — these are authored in Copilot Studio, then re-exported (platform limitation, §8).
- Automatic publishing (the platform's CLI publish is unreliable for modern agents — §8).

---

## 4. The two paths — required behavior

### 4.1 distribute/export.ps1 — package an agent into one bundle
**Interface:** `-SourceOrgUrl -BotId -SolutionName -PublisherName [-OutputDir=. -AuthIndex=1 -PacExe]`

**Must do, in order:**
1. Acquire a Dataverse token (az).
2. **Validate** the agent is modern (`template -like "cliagent-*"`); warn if no `agentSettings`;
   warn on custom topics. Reject classic with a clear message.
3. Find or create the distribution solution. **Resolve publisher by unique name OR customization
   prefix** (makers know the prefix).
4. **Surgically** add the agent's whole component graph to the solution: bot, all botcomponents
   (incl. file children of code-skills), flows, connection references — using a **candidate
   component-type list** per kind so it works across platform versions (§8.2). Never swallow the
   error silently.
5. **Verification net:** count solution components; abort if fewer than expected.
6. `pac solution export` the solution to `agent.zip`.
7. **ZIP sanity check:** the exported zip must contain `bots/*/bot.xml`; abort if not.
8. Download code-skill binary assets (the `.py`/`SKILL.md` files) to `skills-with-assets/`.
9. Write `manifest.json` (agent name, schema, template, `skillsWithAssets`, `connectorsRequired`).
10. Bundle `agent.zip` + `manifest.json` + `skills-with-assets/` into `{AgentName}-bundle.zip`
    using clean .NET zip (no Compress-Archive warnings); remove the loose files.

**Output:** a single `{AgentName}-bundle.zip`.

### 4.2 distribute/install.ps1 — install a bundle anywhere
**Interface:** `[-BundleZip] [-BundleDir] -TargetOrgUrl [-AuthIndex=1 -PacExe]`

**Must do, in order:**
1. Resolve and validate the bundle (`agent.zip` + `manifest.json` present).
2. `pac solution import`. **Do not trust pac's exit code** — it can print a FAILURE and still
   return 0 (§8.3). Capture output, scan for failure markers, **and verify the bot exists in
   Dataverse by schema name**. If either fails, stop loudly with the cause (e.g. a missing
   Dataverse table a flow needs) and how to fix it.
3. **Skills with a code file:** detect type-9 components whose data contains `bic:bundle=`; rebuild
   the upload `.zip` from `skills-with-assets/`; instruct a one-time CS UI re-upload. Never silently
   rewrite to inline (§8.4).
4. **Connections / flows:** read `connectorsRequired`; tell the user the flows imported already
   linked but arrive off with no connection — activate = add a connection + turn on.
5. **Resolve the real environment GUID** (via `pac env list`) for a working Copilot Studio link.
6. Summary that reflects only the steps that actually apply.

### 4.3 develop/export.ps1 — clone to editable files + build the bundle
**Interface:** `-SourceOrgUrl -BotId -AgentName -SolutionName -PublisherName [-OutputDir -AuthIndex=1 -PacExe]`

**Must do:**
1. Validate modern agent.
2. `pac copilot clone` → editable YAML under `sample/<AgentName>/` (for reading, diffing, review).
3. Call `distribute/export.ps1` to build the **deployable bundle** (the reliable artifact).
4. Write `sample/agent-config.json` (authoritative model + AI settings + instructions).
5. Write `sample/<AgentName>.instructions.md` (friendly editable instructions surface).
6. Summary states clearly what is editable-in-files-and-deploys vs what needs Copilot Studio.

### 4.4 develop/install.ps1 — install the bundle and apply file edits
**Interface:** `-BundleZip [-SampleDir] [-AgentName] -TargetOrgUrl [-AuthIndex=1 -PacExe]`

**Must do, in order:**
1. `pac solution import` with the **same failure detection** as 4.2 step 2.
2. Apply **instruction + model** edits via `bot.configuration` PATCH. Instructions from
   `instructions.md` are applied **only when the agent has a single static instruction segment**;
   multi/dynamic-segment agents fall back to `agent-config.json` (don't drop dynamic segments).
3. Apply **inline-skill content** edits (component `data` PATCH) and **tool/skill description**
   edits (component `description` column PATCH — descriptions are NOT in `data`, §8.5). Skip
   code-file skills (`bic:bundle=`) — those go through the re-upload path.
4. Code-file skills: rebuild zip + guide re-upload.
5. Flows: activate guidance. 6. Publish guidance (one-click; CLI publish crashes, §8).
**Never uses `pac copilot push`** (it silently drops components, §8.1).

---

## 5. What moves with an agent (component support)

Legend: ✅ transfers · ⚠️ transfers + one manual step · ❌ not supported ·
**T** tested in this project · **R** reasoned from platform behavior, not yet tested here.

| Part | Status | T/R | Notes |
|---|:---:|:---:|---|
| Instructions + model / AI settings | ✅ | T | Round-trip; editable in develop path |
| Tools (standard connectors) | ✅ | T | Flow needs a connection after install |
| Agent flows (Power Automate) | ✅ | T | Import linked + off; activate = connection + turn on |
| Skills — text / inline code | ✅ | T | Fully; content editable in develop path |
| Skills — with a code file (`.zip` of .py + SKILL.md) | ⚠️ | T | One-time CS re-upload; CS flags it |
| Tool / skill descriptions | ✅ | T | Editable in develop path (`description` column) |
| Knowledge — web links (+ description) | ✅ | T | Name, description, config all survive |
| Knowledge — files (PDF/Word) | ✅ | R | Binary travels in the bundle (tested in a prior session) |
| Test cases | ✅ | R | Carried in the bundle (prior session) |
| Child-agent tools (ConnectedAgentTool) | ✅ | T | References child by `botSchemaName`; child must exist in target |
| MCP tools — Microsoft-published (OOB) | ✅ | T | Carries `connectorId` + connection ref like a ConnectorTool; wire a connection |
| MCP tools — custom (your own server) | ⚠️ | R | Definition transfers; server must be reachable at same URL + custom connector in target |
| Custom connectors with inline code | ❌ | R | Azure Functions provisioning is unreliable — platform issue |
| Classic agents | ❌ | T | Different architecture — out of scope |

Any **R** row must be converted to **T** (or corrected) when a suitable test agent is available.

---

## 6. Assumptions (validate before relying on them)

- A1. Source and target are Dataverse environments the user can reach with `pac` + `az`.
- A2. The agent's `template` starts with `cliagent-` (modern). Verified at runtime.
- A3. The maker's publisher exists in the source env (resolved by prefix or unique name).
- A4. `bot.configuration` is a string field; PATCH bodies must string-encode it. (Tested.) An agent
  that was never configured/published has a **null** configuration — export must handle that without
  crashing (tested via a minimal agent; structure still transfers, no instructions/model to carry).
- A5. Local cloned YAML from `kind:` onward maps byte-for-byte to a component's `data` field;
  `mcs.metadata.description` maps to the `description` column. (Tested.)
- A6. The maker performs the one-click Publish themselves (no reliable CLI publish).
- A7. Dependencies an agent needs (custom tables, custom connectors) either exist in the target or
  are created by the maker — see UX backlog U1. **(Custom tables: now auto-bundled, §4.5.)**
- A8. Detecting table dependencies from flow `clientdata` is heuristic (string refs to entity set /
  logical names). We only act on tables confirmed `IsCustomEntity=true`; anything ambiguous is left
  to the existing missing-dependency detection (§4.2 step 2), which fails loudly with the name.

---

## 7. Decisions log (why the tool is built this way)

- D1. **Deploy via solution import, never `pac copilot push`.** Push is manifest-driven and dropped
  6 of 8 components in testing. (2026-06-26)
- D2. **Develop edits applied via targeted Dataverse writes** on top of solution import, not push.
- D3. **Skills with a code file are not silently inlined.** A silent rewrite would look fixed while
  the code can't run. We require an honest one-time re-upload.
- D4. **Install must verify, not trust.** pac import can return exit 0 on failure; we verify the bot
  exists in Dataverse and scan output for failure.
- D5. **Component-type enum is a candidate list, not a constant** (renumbered across platform
  versions); plus a post-add verification net and zip sanity check.
- D6. **Publisher accepts prefix or unique name** (makers know the prefix).
- D7. **Published on personal GitHub** as `Distribute-Develop-Modern-CopilotStudio-agents`.
- D8. **Docs are low-code-first**, jargon deferred to `LEARNINGS.md`.
- D9. **Self-contained samples auto-bundle custom table dependencies** (definition + 1 seed row) so
  a table-backed agent installs and works with one command. Only custom tables; system tables are
  never bundled. Seed insert is best-effort/non-fatal. (2026-06-26)
- D10. **Export accepts an agent by name** (`-AgentName`) as an alternative to `-BotId`, resolving
  among modern agents with an interactive pick when ambiguous. Removes the "find the GUID" friction
  for low-code makers. (2026-06-26)
- D11. **Friendly preflight** in every script: clear setup guidance when az/pac is missing or not
  signed in, or the environment is unreachable, instead of a cryptic token error. (2026-06-26)
- D12. **`-WhatIf` dry run** on both installs previews the full plan from the bundle and exits
  without changing the target. (2026-06-26)
- D13. **`export-all.ps1`** exports every modern agent in an environment to its own bundle (whole-
  environment backup/migration), continuing past per-agent failures with a summary. (2026-06-26)

---

## 8. Known platform behavior we work around (detail in LEARNINGS.md)

- 8.1 `pac copilot push` — silently drops components for modern agents. Not used.
- 8.2 Solution component-type enum renumbered across platform versions (bot/botcomponent/connref).
- 8.3 `pac solution import` can print FAILURE yet return exit code 0. Must verify independently.
- 8.4 Code-file skills store their code in source-env blob storage (`bic:bundle=` pointer); it 404s
  in the target. Only a CS UI upload recreates it.
- 8.5 A tool/skill **description** lives in the `description` column, not in `data`.
- 8.6 `pac copilot publish` / `pack` / `pull` crash for modern agents. Publish is a UI step.
- 8.7 `az account get-access-token --resource <url>` succeeds for **any** URL (Azure AD doesn't
  validate the resource exists), so a wrong environment URL passes the token step and fails later
  with a cryptic DNS error. Preflight therefore probes the environment with a `WhoAmI` call.
- 8.8 Bundle zip entry names must be built with `[IO.Path]::GetRelativePath(<subfolder>, file)`, not
  by string-replacing `$OutputDir` — the latter silently produces ABSOLUTE entries when the path
  form differs (e.g. 8.3 short names like `KKANJI~1` vs the long name), which then breaks extraction.

---

## 9. Reliability & versioning guarantees

- R1. No silent success: every deploy verifies the agent landed; failures stop with a cause.
- R2. No silent data loss: export verifies component counts and zip contents before shipping.
- R3. Cross-version safety: component-type handling uses candidate lists + count verification, so a
  future platform renumber fails loudly rather than shipping an empty bundle.
- R4. Idempotent installs: re-running install re-imports and re-applies edits safely.
- R5. When the platform changes, update §8 + LEARNINGS first, then code, then this spec's version.

---

## 10. UX backlog (improvements to make it more generic / easier)
- U1. ~~Self-contained samples for table-backed agents.~~ **RESOLVED (§4.5, D9):** export now
  auto-bundles each custom table's definition + 1 seed row; install recreates the table and seeds
  one row if empty. (System tables are never bundled; seed insert is best-effort.)
- U2. ~~Auto-detect the agent id / offer a picker.~~ **RESOLVED (§4.7, D10):** export accepts
  `-AgentName` and resolves the id among modern agents, with an interactive pick when ambiguous.
- U3. ~~Optional `-WhatIf` dry run for both installs.~~ **RESOLVED (§4.9, D12):** `-WhatIf` prints
  exactly what the install would do (import, table seeding, skill re-uploads, flow activation,
  publish) from the bundle manifest, then exits without touching the target.
- U4. ~~Multi-agent export (whole environment).~~ **RESOLVED (§4.10, D13):** `distribute/export-all.ps1`
  enumerates every modern agent in an environment and exports each to its own bundle, with a summary.
- U5. Convert remaining **R** rows in §5 to **T** with purpose-built test agents. **PARTIALLY DONE
  (2026-06-26):** ConnectedAgentTool and Microsoft-published (OOB) MCP confirmed tested via
  Presentation Buddy (which has both). Remaining R: custom MCP server, custom connectors with code,
  and (from prior sessions) file knowledge + test cases — keep as R until exercised here.
- U6. ~~Friendly first-run checks.~~ **RESOLVED (§4.8, D11):** all scripts run a preflight that gives
  clear setup guidance when the Azure CLI / Power Platform CLI is missing or not signed in, or the
  environment can't be reached — instead of a cryptic token error.

---

## 11. Test evidence (high-signal, reproducible)

- Distribute export/install round-trip across two environments; both old and new component-type
  enums; both recognizer styles (modern). All components landed; counts verified.
- Develop edit→deploy: instructions, an inline skill, and a tool description edited locally and
  confirmed persisted in Dataverse; all components present; single instruction segment preserved.
- Knowledge web link + description: injected, exported, imported to a second env, all fields
  survived.
- Failed-import detection: an agent whose flow needs a missing custom table aborts with the cause.
- **Self-contained tables (batch 1, 2026-06-26):** exported a table-backed agent (Presentation
  Buddy → custom `cr7a0_coffecoorders`); verified only the maker's own unmanaged table is bundled
  (a managed `msdyn_*` platform table is correctly skipped via `IsManaged=false`); installed to a
  clean env where the table did not exist → table recreated (unmanaged), 1 seed row inserted with
  all columns + choice value intact + fresh GUID, agent installed (this exact agent failed to
  install before the feature). Re-install is idempotent (existing data → no duplicate seed).

Keep this section updated as evidence is added or invalidated.

**Sample rows (5) + warnings (2026-06-29):** exported Presentation Buddy with -SeedRows 5; seed-data/<table>.json holds a 5-row JSON array; export warns the rows ship in the bundle (check for sensitive data). Installed into an emptied table: 5 rows inserted with a 'SAMPLE data — replace with your own' warning; verified 5 rows in Dataverse. Re-install is idempotent (table had data -> not seeded; stayed at 5).

**U5 — child-agent + MCP tools (2026-06-26):** Presentation Buddy has both a ConnectedAgentTool and
a Microsoft-published MCP tool. ConnectedAgentTool: source data is `kind: ConnectedAgentTool /
botSchemaName: Default_FabricAnalyst_dQTqzr` — it references the child **by schema name**; it
transferred to the target intact and the child agent exists there, so it resolves. OOB MCP (Work IQ
OneDrive): carries a Microsoft `connectorId` + connection reference exactly like a ConnectorTool and
transferred intact (data byte-identical in target). Both rows moved R→T. Custom MCP servers and
custom connectors with code remain reasoned-only (no such test agent available).

**Batch 2 (2026-06-26) — edge cases, 2 fixes:**
- No-table agent (Fabric Analyst): table logic is a clean no-op (seedTables=0, no seed-data, bundle
  unchanged). Develop path regression after the seed edits: full export+deploy clean.
- Minimal/empty agent (Clean Test Agent, **null `bot.configuration`**): **caught a crash** in both
  export scripts (`ConvertFrom-Json` on null) → fixed to handle null config with a clear warning;
  exports cleanly (bot.xml present, 0 components) and installs via `-BundleDir`.
- `-BundleDir` install path (extracted folder, not zip): verified end-to-end.
- Table+seed feature works through the **develop** path too (it reuses distribute export).

**U2 — resolve agent by name (2026-06-26):** unit-tested the resolver (unique → id; none → errors
listing available modern agents; ambiguous non-interactive → errors listing candidate ids). Real
end-to-end: exported "Fabric Analyst" with `-AgentName` (no `-BotId`) → resolved + full export;
a nonexistent name errors with the available-agents list. `-BotId` path unaffected (all prior tests).

**U6 — friendly preflight (2026-06-26):** happy path unchanged (token acquired + export works).
A wrong/unreachable environment URL now stops immediately at the token step with a clear "Couldn't
reach the environment... check the URL" message (verified) instead of a later cryptic DNS error —
the preflight probes with `WhoAmI` because `az` issues a token for any URL. Missing-`az` and
not-signed-in branches give install/`az login` guidance.

**U3 — `-WhatIf` dry run (2026-06-26):** both installs preview the full plan (import, table recreate
+ seed, local edits [develop], skill re-uploads, flow activation, publish) and exit without changing
the target. Verified on a table-backed bundle. **A latent bug surfaced and was fixed:** bundle zip
entries were built by string-replacing `$OutputDir`, which produced ABSOLUTE entry paths when the
path form differed (8.3 short name `KKANJI~1` vs long), breaking extraction — now uses
`[IO.Path]::GetRelativePath`. Also fixed a StrictMode `.Count` crash from the PowerShell
`$x = if(){@()}` empty-array-collapses-to-null gotcha. Real install of the same bundle confirmed
extraction + seeding work.

**U4 — export-all + robustness (2026-06-26):** `export-all.ps1` exported every modern agent in an
environment (5/5), skipped classic agents, continued past failures, one bundle each. Testing across
many real agents surfaced and fixed four export robustness issues: (1) the verification net
over-counted skill file children (type-14 subcomponents) → false abort, now excluded; (2) an agent
referencing a **deleted flow** hard-aborted with a misleading "type not valid" error → now warns and
skips the missing flow; (3) two agents sharing a display name overwrote each other's bundle → each
agent exports in an isolated work folder and collisions get a unique name (no data loss); (4)
same-named agents shared one distribution solution (cross-contamination) → unique solution per agent.

