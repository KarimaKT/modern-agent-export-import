# Definitive Learnings: Modern Copilot Studio Agent ALM

*Authored from hands-on testing, June 2026.*
*Tests run against a real Modern Copilot Studio agent (`cliagent-1.0.0`) exported from one environment and imported into another.*

---

## 0. Architecture decision: both paths deploy via solution import (NOT pac push)

**This is the most important learning in this document.** For `cliagent-*` agents, the only
*reliable* ways to write content into an environment are:

1. **`pac solution import`** — deploys the full agent structure (bot, all tools, skills, flows,
   knowledge, eval cases) from a solution ZIP. Reliable. Used by BOTH paths.
2. **Dataverse Web API PATCH of `bot.configuration`** — instructions, model, AI settings.
   (Tested: PATCH persists. Instructions: only collapse the editable markdown into the segments
   array when the agent has exactly ONE StaticSegment; multi/dynamic-segment agents are left to
   `agent-config.json` to avoid dropping dynamic segments.)
3. **Dataverse Web API PATCH of an existing botcomponent** — two distinct fields, both tested:
   - `data` field → **inline-skill** markdown. The local YAML from `kind:` onward maps byte-for-byte
     to `data`, and it is the field the runtime reads. (Only for `kind: InlineAgentSkill` without a
     `bic:bundle=` pointer; ZIP-packaged skills are excluded.)
   - `description` column → **tool / skill descriptions** (the `mcs.metadata.description` in the
     cloned `translations/*` YAML maps to this column, NOT into `data`). Patching `data` alone would
     silently fail to update a description — both fields must be handled. (Knowledge-source
     descriptions live in `knowledge/*` and are not reconciled by the develop install today.)

The following pac commands are **unreliable for cliagent-* and are NOT used to deploy**:

| pac command | Failure | Verdict |
|---|---|---|
| `pac copilot push` | Manifest-driven: deploys only the components listed in the empty-clone's `botdefinition.json`. In testing it deployed **2 of 8** components (dropped all 3 connectors + 3 skills) with no error. | Do not use to deploy |
| `pac copilot publish` | Crashes with `System.ArgumentException` (tested twice). | Publish via CS UI (one click) |
| `pac copilot pack` | Crashes on cliagent workspace format. | Use solution export |
| `pac copilot pull` | Crashes (`ArgumentOutOfRangeException`). | Use clone |

**Consequence for the develop/ path UX (documented at runtime + in README):**
- Editable in VS Code and deployed: instructions, model/AI settings, inline-skill content,
  tool/knowledge descriptions (i.e. the *wording and behaviour* of existing components).
- Requires the Copilot Studio UI, then re-export: adding/removing tools, connectors, flows;
  skills with Python/code; file knowledge (i.e. *new structure* or anything needing a connection
  or binary upload).
- Every deploy ends with a one-click **Publish** in CS (because `pac copilot publish` crashes).

`pac copilot clone` is still used by develop/export.ps1 — but only to produce **editable YAML for
reading, diffing, and code review**, never as the deploy mechanism.

---


## 1. Identifying a Modern (cliagent-*) Agent

### The template field

The `template` field on the Dataverse `bot` record is the definitive structural identifier.
It is set at agent creation and is not user-editable. Known values:

| template value | Architecture |
|---|---|
| `cliagent-1.0.0` | Modern — instructions-based, tools, no topics |
| `default-2.1.0` | Classic — topics-based conversation flow (current) |
| `default-2.0.1` | Classic — older version |

**Use a prefix check (`cliagent-*`), not an exact match.** Future versions (`cliagent-1.0.1` etc.)
will have the same architecture and ALM behavior. An exact match on `cliagent-1.0.0` would
reject valid future agents unnecessarily.

### Secondary discriminator: agentSettings in bot.configuration

cliagent agents always have an `agentSettings` block in `bot.configuration`.
Classic agents have `gPTSettings` but not `agentSettings`. Use this as a corroborating check:

```
cliagent-*  → bot.configuration.agentSettings EXISTS    (instructions, model, etc.)
default-*   → bot.configuration.gPTSettings EXISTS, no agentSettings
```

### Recognizer type does NOT discriminate architecture

Both `CLICopilotRecognizer` (NGO) and `GenerativeAIRecognizer` (CGO) appear in cliagent
agents. The recognizer governs orchestration style, not the ALM format. Export/import
mechanics are identical for both. Do NOT reject an agent based on recognizer type.

### Custom topics as a soft warning

If a cliagent-* agent has type-2 botcomponents (custom topics), it may be in transition
or misconfigured. Export will work but verify behavior after import.

### The reliable check sequence

1. `template -like "cliagent-*"` — hard gate
2. `bot.configuration.agentSettings` exists — corroboration
3. No type-2 botcomponents — soft warning only

---

## 2. What pac copilot clone captures

`pac copilot clone` walks the **agent's own component graph** — it does NOT look at solution membership. It reliably captures:

| File/Folder | Content | Notes |
|---|---|---|
| `agent.mcs.yml` | Bot metadata | Minimal — kind: GptComponentMetadata |
| `settings.mcs.yml` | Agent settings, model, **partial instructions** | ⚠️ See gap below |
| `connectionreferences.mcs.yml` | All connection references used by agent's flows | Complete |
| `translations/*.mcs.yml` | ALL tool/skill/action definitions | ConnectorTool, McpTool, WorkflowTool, InlineAgentSkill, ConnectedAgentTool |
| `knowledge/*.mcs.yml` | URL knowledge sources | Complete |
| `workflows/*/metadata.yml` | Flow metadata | Complete |
| `workflows/*/workflow.json` | Flow logic JSON | Complete |
| `actions/*.mcs.yml` | Agent Flow (Power Automate) tool definitions | Older pattern; flowId is source-env-specific |

**pac clone is NOT broken.** It captures everything correctly — including skills, tools, and flows.

---

## 3. Gaps that pac copilot push cannot handle (clone/push path)

These are the ONLY reasons our install script exists. There are exactly three:

### Gap 1 — Flow GUIDs are environment-specific

Every flow-backed tool YAML embeds an env-specific GUID:
- `WorkflowTool` in `translations/*.mcs.yml` → `workflowId: <source-guid>`
- `TaskDialog/InvokeFlowTaskAction` in `actions/*.mcs.yml` → `flowId: <source-guid>`

`pac copilot push` fails with *"Entity 'Workflow' Does Not Exist"* because those GUIDs don't exist in the target environment.

**Fix in install.ps1:**
1. Strip the GUIDs from YAML before first push
2. Create flows in target via `POST /api/data/v9.2/workflows`
3. Patch the new GUIDs back into the YAML
4. Second push — links tools to flows

### Gap 2 — bot.configuration is not written by pac push

`settings.mcs.yml` contains instructions as they were **at the last pac push**. Any edits made in the Copilot Studio UI go to `bot.configuration` in Dataverse — **not** back to the YAML. These two can silently diverge. pac push overwrites `bot.configuration` with whatever is in `settings.mcs.yml`, potentially reverting UI edits.

`bot.configuration` also holds: model series, AI settings (`useModelKnowledge`, `isFileAnalysisEnabled`, etc.), channel settings, and `GenerativeActionsEnabled`.

**Fix in install.ps1:** After pac push, PATCH `bot.configuration` from the separately-exported `agent-config.json`.

**Note on PATCH body:** `bot.configuration` is stored as a **string** in Dataverse (nvarchar), not a JSON column. The PATCH body must be:
```powershell
$body = @{ configuration = $configJson } | ConvertTo-Json -Depth 1  # correctly string-encodes
```
NOT `'{"configuration":' + $json + '}'` — that sends an object literal, not a string value, and gets rejected with OData error.

### GAP 3 — Skills with assets (ZIP-uploaded Python/binary skills)

#### How CS stores skills-with-assets — the two-layer design

When a skill ZIP is uploaded through the Copilot Studio UI, CS creates two separate things:

**TYPE-9 botcomponent** — the skill record the agent references:

```
name: "retail-sales-report"          ← display name (survives import)
data: "kind: InlineAgentSkill
       content: <!-- bic:bundle=AgentSchema.file.skillname_hash -->"
```

The `content` field contains **only a bundle pointer token — no instructions, no name**.
The model reads instructions at runtime by resolving the bundle token against Azure blob storage.

**TYPE-14 botcomponents** — file asset children of the type-9:

```
SKILL.md         ← the actual instructions: name, description, full markdown
retail_report.py ← the Python script
```

SKILL.md is the authoritative source of skill instructions. The Azure bundle blob is a
CS-server-side copy created during ZIP upload through a non-public endpoint.

#### What breaks on import — the "unnamed skills" problem

After any naive solution import or pac push into a new environment:
- The type-9 record imports with its `content: <!-- bic:bundle=... -->` intact
- The type-14 children (SKILL.md, .py) also import correctly
- BUT the bundle token references Azure blob storage that **does not exist in the target environment**

When CS resolves the bundle token at runtime it gets a 404. The skill shows in the CS UI
with its display name but **no description, no instructions** — the model cannot use it.
This is the "unnamed skills" problem: the DV name field survives, the content does not.

**pac copilot clone has the same problem.** The cloned YAML carries the same broken pointer:

```yaml
mcs.metadata:
  componentName: retail-sales-report          # name preserved in YAML metadata
  description: Generate a retail sales report... # description preserved
kind: InlineAgentSkill
content: <!-- bic:bundle=Default_FabricAnalyst_dQTqzr.file.retailsalesreportzip_cL7-s -->
```

mcs.metadata carries name and description correctly. But `content` is the broken pointer.
pac push to a target environment produces an empty, unusable skill.

#### Our fix — a deliberate override, not a restore

We cannot recreate the bundle blob (requires the undocumented CS server-side upload endpoint).
Instead, we read SKILL.md from the imported type-14 child and PATCH the type-9 data field:

```
BEFORE: data = "kind: InlineAgentSkill\ncontent: <!-- bic:bundle=... -->"
AFTER:  data = "kind: InlineAgentSkill\ncontent: |-\n  ---\n  name: ...\n  instructions..."
```

This is an **override, not a restore**. The skill changes from bundle-backed to inline.

| | After naive import | After our fix | After manual re-upload via CS UI |
|--|--|--|--|
| Model reads instructions | Empty — skill useless | Full SKILL.md content | Full content |
| Python/code execution | Broken | No Code Interpreter | Restored |
| Skill in CS UI | Present but empty | Works as inline skill | Works with code |

The DV API PATCH is the only automated path available. pac CLI has no command for this.
Required: `PATCH /api/data/v9.2/botcomponents({id})` with `{ data: <inline yaml> }`
---

## 4. What pac solution import gets right

`pac solution import` is a Dataverse ALM operation that handles:

| Component | Status | Notes |
|---|---|---|
| `bot.configuration` | ✅ **Restored** | From `bots/{schema}/configuration.json` in ZIP |
| InlineAgentSkill (markdown) | ✅ **Restored** | `data` field with full markdown |
| Flow tools (WorkflowTool, TaskDialog) | ✅ **Restored + remapped** | Flow GUIDs preserved (same IDs as source) |
| ConnectorTool / McpTool | ✅ **Restored** | Connection references created empty — wire manually |
| ConnectedAgentTool | ✅ **Restored** | References target agent by schema name — agent must exist in target |
| URL knowledge sources | ✅ **Restored** | Full KnowledgeSourceConfiguration |
| Evaluation test cases | ✅ **Restored** | All type-19 MultiTurnEvaluationCase records |
| Connection references | ✅ **Created** | Records created, `connectionid` is null — normal, wire manually |
| Skills with assets (ZIP + Python) | ❌ **Broken** | Binary file components (type-14) are imported, but bundle blob is NOT reconstituted. Skill appears but assets unreachable. |

### Why solution import is preferred for distribution

1. No flow GUID remap needed — solution import handles this natively
2. `bot.configuration` is included in the ZIP — no separate DV API call needed on export
3. Everything in one ZIP — simpler to share and version-control
4. The only extra script step is fixing skills with assets (which also affects the clone path)

---

## 5. The critical solution membership problem

**Copilot Studio ALWAYS creates new botcomponents in Default Solution**, regardless of which named solution the agent belongs to. This affects EVERY component added via the UI: tools, skills, knowledge sources, connection references.

This means:
- A naive `pac solution export` of your named solution will be missing all botcomponents
- `AddRequiredComponents = $true` fixes this but is too broad — it may pull in components from other solutions
- The surgical fix: enumerate the agent's own component graph, add each component explicitly with `AddRequiredComponents = $false`

### What to add surgically before export

```
Bot record (componenttype 10185)
All botcomponents (componenttype 10186): type 9 + type 14 (file children) + type 15
All workflows (componenttype 29): referenced by tool botcomponents
All connection references (componenttype 10132): referenced by those workflows
```

Do NOT add:
- System solution components (they belong to platform solutions)
- Components from other agents (even if transitive dependencies)
- Components whose schemaname starts with a publisher prefix not owned by this solution author

### CRITICAL: solutioncomponent componenttype enum differs across platform versions

`AddSolutionComponent` takes a `ComponentType` integer. **These values were renumbered between
Dataverse platform versions.** Observed first-hand (June 2026):

| Logical component | Older environment | Newer environment |
|---|---|---|
| Bot | 10185 | 10223 |
| Bot Component | 10186 | 10224 |
| Connection Reference | 10132 | 10161 |
| Workflow | 29 | 29 (unchanged) |

A script that hardcodes the older values calls `AddSolutionComponent` with `ComponentType=10186`
on a newer environment and gets **HTTP 404**. If that error is swallowed, the surgical add does
nothing, `pac solution export` produces a near-empty ZIP (only workflows, the one stable type),
and the user ships a broken bundle while every console line says "OK Added N".

**This was a real shipped bug.** All prior testing exported from one older-enum environment, so it
was never caught. Reproduced cleanly: exporting from the newer environment produced a 6 KB bundle
with zero tools/skills/config, and the script reported success.

**Fixes that make the toolkit version-proof:**
1. Try a CANDIDATE LIST of component types per logical kind (e.g. bot = `@(10185, 10223)`), stop
   on the first that succeeds, treat an "already a component" error as success, and THROW if every
   candidate 404s. Never swallow the error silently.
2. After adding, run a VERIFICATION NET: count `solutioncomponents` for the solution and assert it
   is >= (1 bot + N botcomponents + flows + connection refs). Abort loudly before export if short.
3. After `pac solution export`, SANITY-CHECK the ZIP actually contains `bots/{schema}/bot.xml`.

The verification net is the real guarantee: even if a future platform renumbers the enum again to
a value not in the candidate list, the count check fails loudly instead of shipping an empty bundle.

---

## 6. pac copilot push known bugs (pac 2.8.1)

- **SchemaName > 100 chars**: If any botcomponent schemaname exceeds 100 characters (can happen with long tool display names or long connection reference logical names), pac push fails with `StringLengthTooLong`. Fix: rename the tool to a shorter display name in the source agent.
- **botdefinition.json from wrong env**: pac push requires the workspace to be cloned from the TARGET environment. Using a workspace cloned from the source env causes `UnknownDialogBase` errors from pac 2.8.1 parsing the source's botdefinition.json. Fix: always clone a fresh empty workspace from target before pushing.
- **Bot must pre-exist**: pac push fails with "Entity 'bot' Does Not Exist" if the bot wasn't pre-created. Fix: create bot via `POST /api/data/v9.2/bots` first.
- **pac push crashes after completing deployment** (critical): Both pac pushes in the develop/ path crash with `System.ArgumentOutOfRangeException: Unknown type 'Microsoft.Agents.ObjectModel.UnknownDialogBase'` in `ReadWorkspaceDefinitionAsync`. The crash happens in the **post-push status read**, not during the write. The Dataverse writes complete before the crash occurs, and exit code is 0. This means:
  1. The push DID deploy content — verified by DV API queries after each push
  2. pac CLI does NOT confirm what it deployed (the validation phase crashed)
  3. There is no pac-provided confirmation that the deploy was complete or correct
  
  **This is why develop/ path uses DV API verification after the push**, not pac output, to confirm success. The develop/ path is fundamentally dependent on the DV API queries to know what actually landed. If you use pac push without the DV verification steps, you cannot know whether the deploy was complete.
  
  This crash is a pac CLI bug: pac 2.8.1 does not understand `cliagent-*` YAML in its post-push reader, despite having deployed it. This is the core reason this toolkit exists — pac does not reliably support cliagent-* agents.

---

## 7. VS Code editing

All Modern agent content is plain text and fully editable in VS Code:

| File | Edit for... |
|---|---|
| `settings.mcs.yml` | Instructions, model series, auth settings |
| `translations/{tool}.mcs.yml` | Tool display name, description, inputs/outputs |
| `knowledge/{source}.mcs.yml` | URL knowledge source URL/description |
| `workflows/{name}/workflow.json` | Power Automate flow logic |
| `actions/{tool}.mcs.yml` | Agent Flow tool definition (older pattern) |

**Caveat**: After editing `settings.mcs.yml` instructions and pushing, the changes go to `bot.configuration` via pac push. If the agent was later edited in the Copilot Studio UI, `agent-config.json` (from export) would be more current than `settings.mcs.yml`. Always run a fresh export before editing locally if the agent was modified in the UI.

---

## 8. Summary: When to use each path

| Scenario | Recommended path |
|---|---|
| Distributing a sample to others | **distribute/** — package once, install anywhere |
| Iterating on an agent's instructions/skills in VS Code | **develop/** — edit files, redeploy via solution import |
| CI/CD pipeline | **distribute/** — `pac solution import` is pipeline-safe |
| Agent modified only in Copilot Studio UI | either — both capture authoritative bot.configuration |
| Adding new tools/connectors/flows | **Copilot Studio UI**, then re-export (no reliable CLI push) |

Both paths deploy via solution import (§0). Skills with code assets require the one-time manual
re-upload in both paths (detect `bic:bundle=`, rebuild ZIP, upload via CS UI).



## 9. Skills with assets — final resolution (SHIPPED BEHAVIOR)

The shipped install scripts use **guided manual re-upload**, NOT an automated inline patch.

Rationale: an automated inline PATCH (read SKILL.md from the imported type-14 child, rewrite the
type-9 `data` to inline InlineAgentSkill) *can* restore the instructions text, but it cannot
restore Python/code execution (that still needs the Azure bundle blob, recreated only by the CS
UI upload). The result is a skill that *looks* fixed and is referenced by the model but silently
fails to run its code. We rejected that silent degradation. Instead the scripts:

1. Detect type-9 skills whose `data` still contains `bic:bundle=` after import/push
2. Rebuild a ready-to-upload ZIP from the exported SKILL.md + assets (skills-with-assets/)
3. Print mandatory re-upload steps, open the agent in the browser, and pause
4. Leave the skill honestly broken until the user completes the one-time CS UI upload

The manual upload is the ONLY path that triggers CS's server-side process to recreate the bundle
blob — which restores BOTH the instructions and the code execution in the target environment.

(The inline-override technique is still documented in §3 as background, but it is intentionally
not what the scripts do.)


## 10. File knowledge uploads (PDFs, docs) — WORKS through solution import

TESTED: Uploaded a PDF file to an agent via CS UI, added to solution,
exported, imported to target env. Result: PDF binary fully preserved.

How it works:
- CS UI calls POST/PUT to powervamg.us-il301.gateway.prod.island.powerapps.com/api/botmanagement/v1/
  (BotManagement gateway — not standard DV OData)
- Creates type-14 botcomponent with filedata binary stored in DV (no Azure bundle reference)
- schemaname pattern: {agentSchema}.file.{filename_sanitized}_{hash}
- filedata binary IS included in solution ZIP under botcomponents/{schema}/filedata/
- Solution import correctly restores the binary via type-14 botcomponent

WHY it works (vs skills with assets which break):
- File knowledge stores the binary DIRECTLY in DV filedata (standard file column)
- Skills with assets store a bic:bundle= TOKEN referencing Azure blob storage
- Solution export captures DV filedata but NOT external Azure blob references

SUMMARY of knowledge source behavior:
  URL knowledge (type 16)          ✅ Works through solution import
  File knowledge (PDF/doc, type 14) ✅ Works through solution import  
  Skills with assets (ZIP+Python)   ❌ bic:bundle= broken — needs inline fix


## 11. Connector types tested — and known platform gaps

### What we tested

All ConnectorTool instances in our test agent use **standard Microsoft-published connectors**
(specifically `shared_powerbi` — the Power BI connector). These have stable `connectorId` strings,
no custom code, and no Azure Functions. Export/import carries the `connectorId` reference;
the connection reference is created empty and wired manually. This worked correctly.

### Known gap — Connection references from the new CS UI (reported, not reproduced)

Reports from the Copilot Studio community (June 2026) indicate that connection references
created via the **newer Copilot Studio UI** may not point at the underlying connector records
correctly. This would break solution export because `AddSolutionComponent` for a malformed
connection reference would either fail or produce a solution that errors on import.

**This has not been reproduced or verified in this toolkit's own testing.** Our test agent
uses connection references created before this UI change and they export correctly.

If you hit this: file feedback on the platform issue. The workaround is to check your
connection reference records in PPAC / DV before export and confirm they have a valid
`connectorid` foreign key set.

### MCP tools — distinguish OOB from custom (reasoned, not tested in this toolkit)

There are two kinds, and they behave differently. Neither was exercised in this toolkit's own
tests — this is reasoned from the tested behavior of `ConnectorTool` (which carries a `connectorId`
plus a `connectionReference`) and from how solution import handles connector records.

- **OOB MCP** — a Microsoft-published MCP connector from the connector catalog. It is referenced
  like any standard connector (`connectorId` pointing at a `shared_*` API). Expected to behave like
  a `ConnectorTool`: the tool definition transfers in the solution; you wire a connection in the
  target. No hosting on your side.
- **Custom MCP** — your own MCP server, surfaced via a custom connector / your server URL. The tool
  definition transfers, BUT: (a) the **custom connector** must exist in the target (custom connectors
  with backing code provision unreliably — see below), and (b) the **server must be reachable at the
  same URL** in the target. Dev-tunnel or environment-specific URLs break on import — use a stable
  hosted URL or re-point the connection after import.

Verify MCP behavior for your specific agent before relying on it.

### Known gap — Custom connectors with inline code

Custom connectors with embedded C# script actions (Azure Functions backend) are known
to have unreliable provisioning during solution import. This is a platform-level issue
independent of this toolkit. Prefer connectors without inline code, or isolate the
code layer in flows/plugins.

### Agent flows after import (tested)

Flows (WorkflowTool / TaskDialog) import via solution import with their **original GUIDs
preserved**, so the tool→flow link stays intact — there is nothing to re-add to the agent. Tested
state immediately after import: each flow's `statecode = 0` (**Draft / off**) and its connection
reference imports with an empty `connectionid`. Activation is the only manual step: assign a
connection, Save, and turn the flow On. This is standard Power Platform per-environment behavior,
not specific to this toolkit.

### pac CLI roadmap

Native cliagent-1.0.0 ALM support is on the pac CLI roadmap. When it ships, it may close
some or all of the gaps this toolkit addresses. Monitor pac CLI release notes at
https://aka.ms/PowerPlatformCLI and test new releases against the gaps in section 12
before deciding whether this toolkit is still needed for your workflow.

---

## 12. Complete export and import task breakdown

This table covers every task required to export or import a cliagent-* agent,
split by path. For each task: what is needed, what the default tools do, what
breaks, and what this toolkit does instead.

### distribute/ path — export tasks

| Task | What is needed | Default pac CLI behavior | What this toolkit does |
|------|---------------|--------------------------|------------------------|
| **Identify all agent components** | Walk the full component graph: bot record, all botcomponents (tools, skills, knowledge, eval cases, file children), flows, connection references | No command does this — `pac copilot clone` walks YAML but not solution membership; `pac solution export` of a named solution misses anything added via the CS UI (always lands in Default Solution) | `distribute/export.ps1` queries DV for all botcomponents of the agent and their flow/connref dependencies |
| **Add components to a solution** | All components must be in the same solution before export, or they will be missing from the ZIP | `AddRequiredComponents=true` exists but pulls in foreign components from other solutions | Surgical `AddSolutionComponent` per component with `AddRequiredComponents=false` — only this agent's components |
| **Export solution ZIP** | A Dataverse solution ZIP containing all agent content | `pac solution export` works once all components are in the solution | Calls `pac solution export` after surgical add |
| **Export skill binary assets** | SKILL.md and Python scripts from type-14 file children via `/botcomponents({id})/filedata/$value` | Not captured by `pac solution export` or any pac command | Downloads each file via DV file download endpoint |
| **Write manifest.json** | Inventory of skill names, connector names, export metadata so install.ps1 knows what to do | No pac mechanism | Written by export.ps1; read by install.ps1 |

### distribute/ path — install tasks

| Task | What is needed | Default pac CLI behavior | What this toolkit does |
|------|---------------|--------------------------|------------------------|
| **Import solution** | `pac solution import` restores: bot record, bot.configuration, all botcomponents, flows (GUIDs preserved), connection references (empty), knowledge, eval cases | Works correctly. This is the core of the distribute path. | Calls `pac solution import` — no workaround needed |
| **Wire connections** | Each ConnectorTool flow has connection references that need a real connection assigned | Platform behavior — expected one-time manual step per environment | Script tells user which connectors to wire in PPAC |
| **Handle ConnectedAgentTool** | The referenced child agent must exist in target by the same schema name | No pac mechanism | Script documents this requirement; no automation possible |
| **Handle skills with Python/code assets** | After import, the skill's bic:bundle= token references Azure blob storage in the source env — blob does not exist in target. CS stores the bundle in Azure via a server-side process triggered only by ZIP upload through its UI. There is no public API for this process. | No pac mechanism | Script detects broken skills, rebuilds the ZIP from exported assets, pauses and requires the user to re-upload via CS UI — the only path that triggers the server-side bundle creation |

### develop/ path — export tasks

| Task | What is needed | Default pac CLI behavior | What this toolkit does |
|------|---------------|--------------------------|------------------------|
| **Clone agent to YAML** | All tool/skill/knowledge/flow definitions as editable YAML files | `pac copilot clone` — works correctly, produces complete YAML | Calls `pac copilot clone` |
| **Export bot.configuration** | Authoritative instructions, model, AI settings — these are in DV, not in the cloned YAML (YAML can be stale if agent was edited in CS UI) | Not captured by `pac copilot clone` | Exports via `GET /bots({id})` selecting the configuration field |
| **Export skill binary assets** | SKILL.md and Python scripts from type-14 file children | Not captured by `pac copilot clone` | Downloads each file via DV file download endpoint |

### develop/ path — install tasks (solution-import based — see §0)

The develop/ install path was redesigned (June 2026) to stop using `pac copilot push`, which
silently dropped components (deployed 2 of 8 in testing). It now reuses the reliable distribute/
mechanism and layers your edits on top.

| Task | What is needed | Why pac push failed | What this toolkit does |
|------|---------------|---------------------|------------------------|
| **Deploy full structure** | bot + all tools/skills/flows/knowledge/eval cases in target | `pac copilot push` is manifest-driven and deployed only 2 of 8 components, silently | `pac solution import` of the bundle built by develop/export.ps1 (identical to distribute/) |
| **Apply instruction/model edits** | Deploy the developer's edits to instructions + model + AI settings | pac push writes stale settings.mcs.yml | `PATCH /bots({id})` configuration from agent-config.json, with instructions.md taking precedence |
| **Apply inline-skill / description edits** | Deploy edits to existing inline skills and tool/knowledge descriptions | No pac mechanism | For each edited `translations/*` file: strip the `mcs.metadata:` header and `PATCH` the matching botcomponent's `data` (tested: byte-for-byte match to the `data` field) |
| **Handle skills with Python/code assets** | bic:bundle= token is env-specific | No pac mechanism | Detect, rebuild ZIP, require one-time manual CS UI re-upload |
| **Publish** | Changes must be published to go live | `pac copilot publish` crashes (`ArgumentException`) | Open the agent and instruct the one-click Publish in the CS UI |

Flow GUIDs are no longer stripped/remapped: solution import preserves them natively, exactly as in
the distribute/ path. The old strip-and-remap-and-second-push dance was a workaround for pac push
and is gone.

## 13. Official pac CLI gap assessment (pac 2.8.1, June 2026)

This is a comparison between pac CLI stable and what this toolkit adds.
All findings are from: the official pac.doc.json, live testing, and open GitHub issues.

### pac copilot clone — what it captures

pac copilot clone correctly captures everything in the agent's YAML component graph:
- Dialog YAML (topics, actions, connection references, translations, knowledge, workflows)
- Tool definitions (ConnectorTool, McpTool, WorkflowTool, InlineAgentSkill)

**It does NOT capture:**
- `bot.configuration` (authentication, channels, security, instructions — no parameter exists)
- Binary skill assets (bic:bundle= references — not in YAML graph)

### pac copilot push — what it does

Push is a round-trip of exactly what clone pulled. It does not resolve or remap flow GUIDs,
does not write bot.configuration, and cannot restore skill binaries.

### pac copilot pack — confirmed broken for cliagent workspaces

`pac copilot pack` was designed to package a workspace into a solution ZIP. **It does not
support the full cliagent-1.0.0 workspace format.** Running it on a cloned workspace produces:

```
Error: Workspace is not a valid agent workspace.
Unsupported file: connectionreferences.mcs.yml
Unsupported directory: actions/
Unsupported directory: knowledge/
Unsupported directory: translations/
Unsupported directory: workflows/
```

This means pac copilot pack **cannot be used for cliagent-1.0.0 agents** as of 2.8.1.
Our `distribute/export.ps1` (using pac solution export with surgical AddSolutionComponent)
is the only working pack path for these agents.

### pac copilot pull — crashes with ArgumentOutOfRangeException

`pac copilot pull` on a cliagent-1.0.0 workspace crashes with an unhandled exception
(System.ArgumentOutOfRangeException). The crash appears to be an internal parsing failure
when encountering cliagent-specific YAML structures (actions/, knowledge/, translations/).
Filed as undefined behavior — no public issue tracked yet.

### pac copilot extract-template + create — ignores configuration (issue #1259, #1306)

`pac copilot extract-template` generates a `kickStartTemplate-1.0.0.json` that contains
agent description, instructions, settings, and knowledge sources. However, `pac copilot create`
silently ignores this JSON file — creating an empty agent with no configuration.
Open since August 2025, no Microsoft response.

### Open bugs that affect cliagent ALM (pac 2.8.1)

| Issue | Bug | Status |
|---|---|---|
| #1259 | extract-template/create ignores configuration (instructions, knowledge, settings) | Open 10+ months |
| #1306 | create ignores kickStartTemplate-1.0.0.json entirely | Open |
| #1253 | solution import fails for agents with file attachments | Open |
| #1282 | publish crashes on non-English Dataverse locale | Open |
| #1307 | publish race condition — always fails on first attempt | Open |
| #1372 | All copilot commands crash on Turkish/Azerbaijani locale | Open |
| #1393 | pac copilot mcp --run breaks MCP stdio protocol (stdout corruption) | Open |

### VS Code extension

The Power Platform Tools extension (microsoft-IsvExpTools.powerplatform-vscode) has **no
dedicated Copilot Studio agent tooling**. Its GUI features are for Power Pages and PCF controls.
For agents, it is purely a pac CLI host — its only value is dropping `pac` into the terminal
and providing YAML schema hints. Current: v2.0.145.

### Net assessment: where this toolkit adds value

| Our gap | pac 2.8.1 status | Toolkit value |
|---|---|---|
| bot.configuration export/import | Not captured anywhere in pac | ✅ Real gap closed |
| Flow GUID remap (Path 2) | Not handled — push re-embeds source GUIDs | ✅ Real gap closed |
| Skills-with-assets repair | No pac mechanism | ✅ Real gap closed |
| Solution packaging (Path 1) | pac copilot pack crashes on cliagent workspaces | ✅ Real gap closed |
| Default Solution membership | No pac mechanism for surgical component add | ✅ Real gap closed |
