# Definitive Learnings: Modern Copilot Studio Agent ALM

*Authored from hands-on testing, June 2026.*
*Tests run against a real Modern Copilot Studio agent (`cliagent-1.0.0`) exported from one environment and imported into another.*

---

## 1. Identifying a cliagent-1.0.0 Agent

The **template** is the definitive structural identifier:

| Property | cliagent-1.0.0 | Classic |
|---|---|---|
| `template` (on bot DV record) | `cliagent-1.0.0` | `default-2.1.0` |
| `recognizer.$kind` (in bot.configuration) | `CLICopilotRecognizer` **or** `GenerativeAIRecognizer` | `GenerativeAIRecognizer` |
| Custom topics | None | Has custom topics |

**Important nuance on recognizer type:**
Both `CLICopilotRecognizer` (NGO/Modern orchestration) and `GenerativeAIRecognizer` (CGO) can appear
in `cliagent-1.0.0` agents. The recognizer governs *how the agent orchestrates* — not *how it exports*.
The ALM behaviors and export/import mechanics are identical for both. Do NOT reject a `cliagent-1.0.0`
agent solely because it uses `GenerativeAIRecognizer`.

The only hard guards to apply before export:
1. `template == cliagent-1.0.0` — if this is false, the agent is Classic; this toolkit is not designed for it.
2. No custom topics (type-2 botcomponents) — if topics exist, it's a Classic agent in a new container; test carefully.

Checking only the recognizer is insufficient and will produce false negatives.

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

When a skill is uploaded as a ZIP containing binary files (Python scripts, images, etc.):
- DV creates a type-9 botcomponent with data: kind: InlineAgentSkill\ncontent: <!-- bic:bundle=<hash> -->
- DV creates type-14 botcomponents as children with the actual binary content
- The ic:bundle= token references a binary blob in Copilot Studio server-side storage

**This blob is NOT accessible via standard Dataverse OData API.**
The bundle is created by a Copilot Studio server-side process during ZIP upload —
likely through a non-public CS-specific endpoint, not through /api/data/v9.2.

**TESTED:** Uploading type-14 file components via the 3-step DV file column protocol
(InitializeFileBlocksUpload → UploadBlock → CommitFileBlocksUpload) successfully stores
the binary bytes but does NOT trigger bundle creation. The type-9 skill's ic:bundle=
reference remains broken. The bundle token is opaque and environment-specific.

**Known workaround (manual only):** After solution import, re-upload the skill ZIP
manually through the Copilot Studio UI → Skills → Upload a skill.

**No automated fix is currently possible** without access to the undocumented CS upload endpoint.

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

---

## 6. pac copilot push known bugs (pac 2.8.1)

- **SchemaName > 100 chars**: If any botcomponent schemaname exceeds 100 characters (can happen with long tool display names or long connection reference logical names), pac push fails with `StringLengthTooLong`. Fix: rename the tool to a shorter display name in the source agent.
- **botdefinition.json from wrong env**: pac push requires the workspace to be cloned from the TARGET environment. Using a workspace cloned from the source env causes `UnknownDialogBase` errors from pac 2.8.1 parsing the source's botdefinition.json. Fix: always clone a fresh empty workspace from target before pushing.
- **Bot must pre-exist**: pac push fails with "Entity 'bot' Does Not Exist" if the bot wasn't pre-created. Fix: create bot via `POST /api/data/v9.2/bots` first.

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
| Distributing a sample to others | **Path 1 (solution ZIP)** — simpler, standard ALM |
| Iterating on an agent in VS Code | **Path 2 (clone/push)** — live source control |
| CI/CD pipeline | **Path 1 (solution ZIP)** — `pac solution import` is pipeline-safe |
| Agent modified only in Copilot Studio UI | **Path 1** — bot.configuration is in ZIP; pac clone gets stale YAML |
| Agent built and maintained in VS Code | **Path 2** — YAML is authoritative; skip the UI |

In both paths, skills with assets require the post-import fix (detect `bic:bundle=`, rebuild ZIP, re-upload). This is automated in our install scripts.



## 9. Skills with assets — final resolution

AUTOMATED FIX (tested):
After solution import or pac push, skills with bic:bundle= references can be partially
fixed by reading the SKILL.md from the imported type-14 file component and patching
the type-9 skill data field with inline InlineAgentSkill content.

Fix steps:
1. Find type-9 skills where data contains bic:bundle=
2. Get type-14 children: GET /botcomponents?filter=_parentbotcomponentid_value eq {skillId}
3. Find the SKILL.md child (filedata_name = 'SKILL.md')
4. Read binary: GET /botcomponents({childId})/filedata/\ → UTF-8 text
5. PATCH /botcomponents({skillId}) with data = inline InlineAgentSkill YAML

What is restored: skill name, description, full instructions (what agent reads)
What is NOT restored: Python execution via Code Interpreter (requires bundle)

For production agents where Python execution is required: manual ZIP re-upload via UI.
For sample distribution: automated fix is sufficient — instructions work correctly.


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

### Known gap — Custom connectors with inline code

Custom connectors with embedded C# script actions (Azure Functions backend) are known
to have unreliable provisioning during solution import. This is a platform-level issue
independent of this toolkit. Prefer connectors without inline code, or isolate the
code layer in flows/plugins.

### Known gap — McpTool (MCP server tools)

McpTool definitions export and import correctly. The MCP server itself must be running
and reachable at the same URL in the target environment. Local servers with dev-tunnel
URLs break on import — use a stable hosted URL or re-wire after import.

### pac CLI roadmap

Native cliagent-1.0.0 ALM support is on the pac CLI roadmap. When it ships, it may close
some or all of the gaps this toolkit addresses. Monitor pac CLI release notes at
https://aka.ms/PowerPlatformCLI and test new releases against the gaps in section 12
before deciding whether this toolkit is still needed for your workflow.

---

## 12. Official pac CLI gap assessment (pac 2.8.1, June 2026)

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
Our path1-solution/export.ps1 (using pac solution export with surgical AddSolutionComponent)
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
