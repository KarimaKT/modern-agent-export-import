# Definitive Learnings: Modern Copilot Studio Agent ALM

*Authored from hands-on testing, June 24 2026.*
*Tests run against: Fabric Analyst (cliagent-1.0.0) in CDX (orgea8005ed) → Zava PP (org07697283)*

---

## 1. Identifying a Modern Copilot Studio Agent

A Modern agent has ALL of the following — check all three before assuming anything:

| Property | Modern | Classic |
|---|---|---|
| `template` (on bot DV record) | `cliagent-1.0.0` | `default-2.1.0` |
| `recognizer.$kind` (in bot.configuration) | `CLICopilotRecognizer` | `GenerativeAIRecognizer` |
| Custom topics | None | Has custom topics |

Checking only the template is insufficient — some agents in transition may have the template set but retain classic behavior.

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

TESTED: Uploaded test-knowledge.pdf to CleanBuildAgent via CS UI, added to solution,
exported, imported to target env. Result: PDF binary (549 bytes) fully preserved.

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

