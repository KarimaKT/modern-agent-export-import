# Modern Agent Export/Import — Context for Next Session

*Last updated: 2026-06-25*

---

## What This Is

A PowerShell toolkit for exporting and importing Modern Copilot Studio agents (cliagent-1.0.0)
across environments. GitHub: https://github.com/KarimaKT/modern-agent-export-import

Two paths:
- **path1-solution/** — solution ZIP export/import (distribute a sample)
- **path2-vscode/** — pac clone/push developer workflow

---

## Key Tested Findings (don't re-research, don't assume)

### 1. Identifying a Modern agent — check ALL THREE
```
template = cliagent-1.0.0              (bot DV record)
recognizer.$kind = CLICopilotRecognizer (bot.configuration)
No type-2 botcomponents                (topics = Classic)
```

### 2. Components ALWAYS land in Default Solution
Copilot Studio UI creates all new tools, skills, knowledge in Default Solution regardless
of which named solution the agent belongs to. Confirmed on clean named-solution agent.
Fix: use `AddSolutionComponent` surgically before `pac solution export`.

### 3. pac copilot clone was never broken
It walks the agent's component graph directly (not solution membership). Gets everything.
The YAML it produces is correct. The gaps are in pac push, not clone.

### 4. Exactly 3 gaps in pac push
- **Flow GUIDs** (workflowId / flowId) are env-specific — strip before push, create flows
  via DV API, patch back, second push
- **bot.configuration** — pac push doesn't write it. PATCH after push.
  IMPORTANT: configuration is a STRING field in DV, not JSON column.
  Correct PATCH body: `@{ configuration = $configJson } | ConvertTo-Json -Depth 1`
  Wrong: `'{"configuration":' + $json + '}'`  ← OData rejects this
- **Skills with assets** — bic:bundle= blob is NOT in YAML, not reproducible via DV API.
  Fix: read SKILL.md from type-14 child via `/filedata/$value`, patch type-9 data to inline.

### 5. pac solution import handles almost everything
- bot.configuration ✅ (from bots/*/configuration.json in ZIP)
- InlineAgentSkill ✅
- Flow tools with correct GUIDs ✅ (solution import preserves them)
- File knowledge (PDFs, docs) ✅
- URL knowledge (type 16) ✅
- Connection references ✅ (created empty — wire manually, normal behavior)
- Skills with assets ❌ — bic:bundle= broken, use the inline fix

### 6. Skills with assets fix (tested, working)
The bic:bundle= blob is in Azure file storage, env-specific, not in DV component graph.
- The type-14 child components ARE in the solution ZIP with binary content
- Read SKILL.md binary: `GET /botcomponents({childId})/filedata/$value`
- Build inline: `"kind: InlineAgentSkill\ncontent: |-\n" + (SKILL.md lines indented 2 spaces)`
- PATCH /botcomponents({skillId}) with `@{ data = $newData } | ConvertTo-Json`
- Agent works immediately with instructions. Python execution needs manual ZIP re-upload via UI.

### 7. File knowledge (PDFs etc.) — works fine
- Stored as type-14 botcomponent with DV filedata binary
- Binary IS in solution ZIP → fully restored on import
- No special handling needed

### 8. BotManagement gateway API (undocumented)
CS UI calls: `https://powervamg.us-il301.gateway.prod.island.powerapps.com/api/botmanagement/v1/`
This is used for all agent content saves (skills, knowledge uploads, tool adds).
Cannot replicate skill bundle creation via DV OData API.

### 9. pac CLI known bugs (pac 2.8.1)
- SchemaName > 100 chars → StringLengthTooLong on push
- Workspace must be cloned from TARGET env (source workspace → UnknownDialogBase crash)
- Bot must pre-exist (pac push won't create it)
- pac push exit code 1 doesn't always mean complete failure — check DV state

### 10. File download pattern (binary)
`(Invoke-WebRequest -Uri "$org/api/data/v9.2/botcomponents($id)/filedata/`$value" -Headers @{ Authorization="Bearer $token" } -UseBasicParsing).Content`
NOT: `/filedata` (returns 400) or `?$select=filedata` (returns a GUID reference, not bytes)

---

## Environments

| Name | Org URL | pac auth | Used for |
|---|---|---|---|
| CDX (Contoso Group) | orgea8005ed.crm.dynamics.com | index 2, karima@M365x05526665.onmicrosoft.com | Source agents |
| Zava PP | org07697283.crm.dynamics.com | index 2 (same account has access to both) | Import testing |

---

## Test Agents in CDX

| Agent | BotId | Schema | Template | Notes |
|---|---|---|---|---|
| Fabric Analyst | d01d7579-bf47-4da7-b751-22a419ade844 | Default_FabricAnalyst_dQTqzr | cliagent-1.0.0 | 2 Agent Flows + 3 ConnectorTools + 1 InlineAgentSkill + 1 skill-with-assets (retail-sales-report) |
| CleanBuildAgent | f6e66b3e-5470-f111-ab0e-6045bdebf7f3 | cr7a0_CleanBuildAgent | cliagent-1.0.0 | Test agent in CleanBuildTest solution |
| Presentation Buddy | ca19513b-8c12-4721-a7e7-18a582cfd5ce | cr7a0_mytooltest_AsoY32 | cliagent-1.0.0 | Has ConnectorTool (Office365), McpTool (WorkIQ), ConnectedAgent (Fabric Analyst), WorkflowTools (CoffeeCo, requesttype) — note: CoffeeCo has cross-solution deps that break export |

---

## Active Solutions in CDX

| Name | Notes |
|---|---|
| FabricAnalystSample | Contains Fabric Analyst + all components (surgically added) |
| CleanBuildTest | Contains CleanBuildAgent |
| PresentationBuddySample | Contains PB but CoffeeCo has cross-solution deps — cannot export cleanly |

---

## What Still Needs Work

1. **T-SOL-4 (pending)**: Full surgical export of CleanBuildTest → import to Zava PP end-to-end
   (the CleanBuildTest solution with retail-sales-report skill) — never fully tested as a bundle.
2. **T-CLONE-1 (pending)**: Full pac clone → edit in VS Code → path2-vscode/install.ps1 end-to-end
3. **Presentation Buddy distribution**: Cross-solution connection refs (CoffeeCo, requesttype workflows)
   use borrowed refs from other solutions — would need those workflows rebuilt in its own solution.
4. **path1-solution/export.ps1 bundle ZIP**: Written but not tested end-to-end (export → bundle.zip → install.ps1 -BundleZip).

---

## Scripts

```powershell
$pac = "C:\Users\kkanjitajdin\.nuget\packages\microsoft.powerapps.cli\2.8.1\tools\pac.exe"
$sourceOrg = "https://orgea8005ed.crm.dynamics.com"
$targetOrg = "https://org07697283.crm.dynamics.com"

# Get DV token
$token = (az account get-access-token --resource $orgUrl | ConvertFrom-Json).accessToken
$dv = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json" }

# pac auth for CDX
& $pac auth select --index 2
```

---

## Best Practices for This Repo

1. **Never commit agent YAML, samples, or personal build work** to the public repo.
   Keep those in C:\src\Fabric, C:\src\Fabric-related, etc.

2. **Test before claiming something works.** The original session had untested assumptions
   that made it into LEARNINGS.md and scripts. Always prove with DV API queries.

3. **For solution export**: always use surgical `AddSolutionComponent` per component, not
   `AddRequiredComponents=true`. The latter is too broad and may pull in foreign components.

4. **For skills with assets**: the automated inline fix is correct and sufficient for samples.
   Be honest with users that Python execution needs manual re-upload. Don't promise what
   the DV API cannot deliver.

5. **README structure**: Problem → Prerequisites → Two paths (actionable first) → Background.
   Users want to get things working before reading the theory.

6. **pac version matters**: Tested with pac 2.8.1. Newer versions may fix some known bugs.
   Document the version when reporting bugs.
