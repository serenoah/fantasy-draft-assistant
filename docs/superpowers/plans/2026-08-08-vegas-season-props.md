# Vegas Season Player-Prop Scoring Signal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bounded `propsBonus` scoring factor to the draft assistant, driven by real researched Vegas season player-prop lines, threaded through both scoring functions and all three explainability surfaces (reasoning text, score breakdown, compare verdict) — the same way `TEAM_SCHEDULE_DIFFICULTY`/`scheduleDifficultyBonus` already work.

**Architecture:** Two pure JS functions (`impliedSeasonPtsFromProps`, `vegasPropsBonus`) added to `index.html`'s scoring section, reading an optional per-player `vegasProps` field from `data/players.json`. A required-dimension gate (see design spec) prevents partial market coverage from reading as model disagreement. Real prop data is hand-researched (this is a static single-file app with no live odds API) and spliced into `players.json` using the project's existing PowerShell technique, then committed and pushed (required for the live `raw.githubusercontent.com` fetch to see it).

**Tech Stack:** Vanilla JS (no build step), `data/players.json` (PowerShell-formatted JSON), headless Microsoft Edge for verification (no Node/Python in this environment), WebSearch/WebFetch for research.

## Global Constraints

- No `UPDATE`/build step/test framework exists — verification is exclusively the headless-Edge diagnostic technique documented in `CLAUDE.md`: copy `index.html` to a scratch file, append a `<script>` before `</body>`, run `msedge.exe --headless=new --disable-gpu --no-sandbox --dump-dom --virtual-time-budget=20000 "file:///<path>"`, read the results `<div>` from the dumped HTML.
- `data/players.json` edits are invisible to the running app until committed **and pushed** — `index.html` fetches live from `raw.githubusercontent.com`.
- Apostrophes in `players.json` are sometimes the literal 6-character escape sequence `&#39;` (verbatim, not a real `'`) — a text `Edit` match can fail silently for this reason.
- Every scoring-affecting factor must be modest and bounded, comparable to (not larger than) the least-aggressive existing factor. `propsBonus` is clamped to **±5**, at parity with `SCHEDULE_DIFFICULTY_CLAMP`'s most generous stage, per the approved design.
- Real, verifiable data only — never a fabricated or estimated prop line. A player with incomplete market coverage gets `propsBonus = 0`, never a guessed value.
- Design source of truth: `docs/superpowers/specs/2026-08-08-vegas-season-props-design.md` (already committed).

---

### Task 1: Core scoring functions (`impliedSeasonPtsFromProps`, `vegasPropsBonus`)

**Files:**
- Modify: `index.html` (insert new consts/functions after `POSITION_VALUE_DAMPENER`, before the `FALLBACK DATA` section)
- Test: scratch diagnostic HTML (no fixed path — created fresh each run in Step 2)

**Interfaces:**
- Consumes: `player.position` (`'RB'|'WR'|'TE'|'QB'|...`), `player.vegasProps` (`{rushYards, recYards, passYards, totalTD, passTD, source, asOf} | undefined`), `player.projection.projSeasonPts` (`number`) — all existing/spec'd fields.
- Produces: `impliedSeasonPtsFromProps(player) -> number | null`; `vegasPropsBonus(player) -> number` (integer in `[-5, 5]`). Both pure functions, no side effects, no dependency on `ALL_PLAYERS`/`draftState`.

- [ ] **Step 1: Write the failing diagnostic test**

Create a scratch copy of the app first so the test has something to run against:

```powershell
Copy-Item "C:\Users\mason\OneDrive\Desktop\FantasyDraftAssistant\index.html" "$env:TEMP\fda_diag1.html"
```

Append this `<script>` block immediately before `</body>` in `$env:TEMP\fda_diag1.html` (the main app `<script>` earlier in the document runs first and defines everything at global scope, so these functions are already defined by the time this block executes — no need to wait for `ALL_PLAYERS`):

```html
<script>
(function(){
  const results = {};

  // RB: rushYards/10 + recYards/10 + totalTD*6 = 120+30+60 = 210; model 250 -> deltaPct -0.16 -> raw -4
  results.rbFullData = vegasPropsBonus({ position:'RB', vegasProps:{ rushYards:1200, totalTD:10, recYards:300 }, projection:{ projSeasonPts:250 } });

  // RB missing required totalTD -> null implied -> 0
  results.rbMissingRequiredDim = vegasPropsBonus({ position:'RB', vegasProps:{ rushYards:1200, recYards:300 }, projection:{ projSeasonPts:250 } });

  // No vegasProps at all -> 0
  results.rbNoProps = vegasPropsBonus({ position:'RB', projection:{ projSeasonPts:250 } });

  // WR huge positive gap -> clamps at +5. implied = 1600/10 + 14*6 = 160+84=244; model 200 -> deltaPct 0.22 -> raw 5.5 -> clamp 5
  results.wrClampedPositive = vegasPropsBonus({ position:'WR', vegasProps:{ recYards:1600, totalTD:14 }, projection:{ projSeasonPts:200 } });

  // WR extreme gap must still clamp at exactly 5, never exceed it
  results.wrNeverExceedsClamp = vegasPropsBonus({ position:'WR', vegasProps:{ recYards:2000, totalTD:20 }, projection:{ projSeasonPts:100 } });

  // QB: implied = 4800/25 + 38*4 = 192+152=344; model 380 -> deltaPct -0.0947 -> raw -2.37 -> round -2
  results.qbModestNegative = vegasPropsBonus({ position:'QB', vegasProps:{ passYards:4800, passTD:38 }, projection:{ projSeasonPts:380 } });

  // QB missing required passTD -> 0
  results.qbMissingRequiredDim = vegasPropsBonus({ position:'QB', vegasProps:{ passYards:4800 }, projection:{ projSeasonPts:380 } });

  // DST/K always 0 regardless of vegasProps (position not handled)
  results.dstAlwaysZero = vegasPropsBonus({ position:'DST', vegasProps:{ rushYards:9999, totalTD:9999 }, projection:{ projSeasonPts:100 } });

  // impliedSeasonPtsFromProps returns the raw number too, for a direct sanity check
  results.impliedPtsForRb = impliedSeasonPtsFromProps({ position:'RB', vegasProps:{ rushYards:1200, totalTD:10, recYards:300 } });

  document.body.insertAdjacentHTML('beforeend', '<div id="diagResults1">'+JSON.stringify(results)+'</div>');
})();
</script>
</body>
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
msedge.exe --headless=new --disable-gpu --no-sandbox --dump-dom --virtual-time-budget=20000 "file:///C:/Users/mason/AppData/Local/Temp/fda_diag1.html" > "$env:TEMP\fda_diag1_dump.html"
```

Search the dump for `diagResults1`. Expected: **not found**, or a JS error — `vegasPropsBonus`/`impliedSeasonPtsFromProps` don't exist in `index.html` yet.

- [ ] **Step 3: Implement the functions**

In `index.html`, find this exact text (the end of the `POSITION_VALUE_DAMPENER` block, right before the fallback-data section):

```javascript
const POSITION_VALUE_DAMPENER = { QB: 0.55, TE: 0.15, RB: 0.88, WR: 0.88, DST: 1.0, K: 1.0 };

/* ================= FALLBACK DATA (used only if both live + no data files are reachable) ============ */
```

Replace it with:

```javascript
const POSITION_VALUE_DAMPENER = { QB: 0.55, TE: 0.15, RB: 0.88, WR: 0.88, DST: 1.0, K: 1.0 };

// Vegas season player-prop lines vs. the model's own season projection --
// see docs/superpowers/specs/2026-08-08-vegas-season-props-design.md. Real,
// hand-researched season win-total lines live on data/players.json's
// optional `vegasProps` field; this is a static single-file app, so there
// is no live odds fetch here. A player only contributes a bonus when the
// position's REQUIRED dimensions were actually found -- partial market
// coverage (e.g. a pass-catching RB whose receiving-yards line couldn't be
// found) must not read as "the model disagrees with Vegas" when it's
// really just a research gap. recYards on RBs is additive-only, never
// required, since many backs are pure runners with no meaningful
// receiving prop to find. DST/K are unhandled (no season yardage/TD
// concept applies to them), same as TEAM_SCHEDULE_DIFFICULTY.
const PROPS_BONUS_CLAMP = 5;
const PROPS_BONUS_MAX_DELTA_PCT = 0.20; // a >=20% implied-vs-model gap maxes out the clamp
function impliedSeasonPtsFromProps(player){
  const vp = player.vegasProps;
  if(!vp) return null;
  if(player.position==='RB'){
    if(vp.rushYards==null || vp.totalTD==null) return null;
    return vp.rushYards/10 + (vp.recYards||0)/10 + vp.totalTD*6;
  }
  if(player.position==='WR' || player.position==='TE'){
    if(vp.recYards==null || vp.totalTD==null) return null;
    return vp.recYards/10 + vp.totalTD*6;
  }
  if(player.position==='QB'){
    if(vp.passYards==null || vp.passTD==null) return null;
    return vp.passYards/25 + vp.passTD*4;
  }
  return null;
}
function vegasPropsBonus(player){
  const impliedPts = impliedSeasonPtsFromProps(player);
  if(impliedPts===null) return 0;
  const modelPts = player.projection && player.projection.projSeasonPts;
  if(!modelPts) return 0;
  const deltaPct = (impliedPts - modelPts) / modelPts;
  const raw = (deltaPct / PROPS_BONUS_MAX_DELTA_PCT) * PROPS_BONUS_CLAMP;
  return Math.max(-PROPS_BONUS_CLAMP, Math.min(PROPS_BONUS_CLAMP, Math.round(raw)));
}

/* ================= FALLBACK DATA (used only if both live + no data files are reachable) ============ */
```

- [ ] **Step 4: Run the diagnostic again to confirm it passes**

```powershell
Copy-Item "C:\Users\mason\OneDrive\Desktop\FantasyDraftAssistant\index.html" "$env:TEMP\fda_diag1.html"
# re-append the same <script> block from Step 1 before </body>
msedge.exe --headless=new --disable-gpu --no-sandbox --dump-dom --virtual-time-budget=20000 "file:///C:/Users/mason/AppData/Local/Temp/fda_diag1.html" > "$env:TEMP\fda_diag1_dump.html"
```

Extract `#diagResults1` from the dump. Expected exact values:
```json
{
  "rbFullData": -4,
  "rbMissingRequiredDim": 0,
  "rbNoProps": 0,
  "wrClampedPositive": 5,
  "wrNeverExceedsClamp": 5,
  "qbModestNegative": -2,
  "qbMissingRequiredDim": 0,
  "dstAlwaysZero": 0,
  "impliedPtsForRb": 210
}
```

- [ ] **Step 5: Commit**

```bash
cd "C:\Users\mason\OneDrive\Desktop\FantasyDraftAssistant"
git add index.html
git commit -m "Add vegasPropsBonus/impliedSeasonPtsFromProps scoring functions

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: Wire into both scoring functions and all three explainability surfaces

**Files:**
- Modify: `index.html` (`scorePlayer`, `computeBigBoardScore`, `buildReasoning`, `scoreBreakdownRows`, `buildCompareVerdict`)

**Interfaces:**
- Consumes: `vegasPropsBonus(player)`, `impliedSeasonPtsFromProps(player)` from Task 1.
- Produces: `scorePlayer(player)` and `computeBigBoardScore(player)` both return an added `propsBonus: number` key in their result object (the `comps` object every downstream explainability function receives).

- [ ] **Step 1: Write the failing diagnostic test**

```powershell
Copy-Item "C:\Users\mason\OneDrive\Desktop\FantasyDraftAssistant\index.html" "$env:TEMP\fda_diag2.html"
```

Append before `</body>` (this one needs real loaded data, so it waits for `ALL_PLAYERS`, per `CLAUDE.md`'s documented pattern):

```html
<script>
(function(){
  const startedAt = Date.now();
  function tryRun(){
    if(typeof ALL_PLAYERS !== 'undefined' && ALL_PLAYERS.length > 0){
      runTest();
    } else if(Date.now() - startedAt < 15000){
      setTimeout(tryRun, 200);
    } else {
      document.body.insertAdjacentHTML('beforeend', '<div id="diagResults2">'+JSON.stringify({error:'ALL_PLAYERS never loaded'})+'</div>');
    }
  }
  function runTest(){
    const results = {};
    const rb = ALL_PLAYERS.find(p => p.position==='RB' && p.projection && p.projection.projSeasonPts);
    const original = rb.vegasProps;
    // Deliberately far above the model's own projection so propsBonus must clamp to +5.
    rb.vegasProps = { rushYards: Math.round(rb.projection.projSeasonPts*10*1.3), totalTD: 12 };

    const comps = scorePlayer(rb);
    results.scorePlayerHasPropsBonus = comps.propsBonus === 5;

    const bigComps = computeBigBoardScore(rb);
    results.bigBoardHasPropsBonus = bigComps.propsBonus === 5;

    const rows = scoreBreakdownRows(rb, comps);
    results.breakdownHasPropsRow = rows.some(r => r.label === 'Vegas season player props');

    const reasoning = buildReasoning(rb, comps);
    results.reasoningMentionsProps = /Vegas season props/i.test(reasoning);

    // compare-verdict diff needs two players -- reuse rb as winner, any other RB as runner-up
    const other = ALL_PLAYERS.find(p => p.position==='RB' && p.id !== rb.id && p.projection);
    const otherComps = scorePlayer(other);
    const verdict = buildCompareVerdict([{player: rb, comps}, {player: other, comps: otherComps}]);
    results.verdictIsAString = typeof verdict === 'string' && verdict.length > 0;

    rb.vegasProps = original; // restore before any other diagnostic logic runs
    document.body.insertAdjacentHTML('beforeend', '<div id="diagResults2">'+JSON.stringify(results)+'</div>');
  }
  tryRun();
})();
</script>
</body>
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
msedge.exe --headless=new --disable-gpu --no-sandbox --dump-dom --virtual-time-budget=20000 "file:///C:/Users/mason/AppData/Local/Temp/fda_diag2.html" > "$env:TEMP\fda_diag2_dump.html"
```

Expected: `scorePlayerHasPropsBonus` and `bigBoardHasPropsBonus` are `false` (or `comps.propsBonus` is `undefined`, since neither function computes it yet), `breakdownHasPropsRow` is `false`.

- [ ] **Step 3: Wire `scorePlayer()`**

Find this exact text:

```javascript
  const rzBonus = redZoneBonus(player);
  const scheduleBonus = scheduleDifficultyBonus(player, stage);

  let base = valueScore*SCORE_WEIGHTS.value + scarcityScore*SCORE_WEIGHTS.scarcity;
  base += adpBonus;
  base += rzBonus;
  base += scheduleBonus;
  base *= needMult;
  base -= byePenalty;
  base -= riskPenalty;
  base -= competitionPenalty;

  let score = Math.max(1, Math.min(100, Math.round(base)));
```

Replace with:

```javascript
  const rzBonus = redZoneBonus(player);
  const scheduleBonus = scheduleDifficultyBonus(player, stage);
  const propsBonus = vegasPropsBonus(player);

  let base = valueScore*SCORE_WEIGHTS.value + scarcityScore*SCORE_WEIGHTS.scarcity;
  base += adpBonus;
  base += rzBonus;
  base += scheduleBonus;
  base += propsBonus;
  base *= needMult;
  base -= byePenalty;
  base -= riskPenalty;
  base -= competitionPenalty;

  let score = Math.max(1, Math.min(100, Math.round(base)));
```

Then find:

```javascript
  return { score, valueScore, scarcityScore, adpBonus, rzBonus, scheduleBonus, needMult, byePenalty, riskPenalty, competitionPenalty, deltaPicks, stage };
```

Replace with:

```javascript
  return { score, valueScore, scarcityScore, adpBonus, rzBonus, scheduleBonus, propsBonus, needMult, byePenalty, riskPenalty, competitionPenalty, deltaPicks, stage };
```

- [ ] **Step 4: Wire `computeBigBoardScore()`**

Find this exact text:

```javascript
  const rzBonus = redZoneBonus(player);
  // No round-stage concept here (this score is roster/draft-progress
  // independent) -- use the "mid" clamp as a fixed middle-ground weight.
  const scheduleBonus = scheduleDifficultyBonus(player, 'mid');

  let base = valueScore*0.80 + scarcityScore*0.20 + adpBonus + rzBonus + scheduleBonus - flatRiskPenalty - competitionPenalty;
  let score = Math.max(1, Math.min(100, Math.round(base)));
```

Replace with:

```javascript
  const rzBonus = redZoneBonus(player);
  // No round-stage concept here (this score is roster/draft-progress
  // independent) -- use the "mid" clamp as a fixed middle-ground weight.
  const scheduleBonus = scheduleDifficultyBonus(player, 'mid');
  const propsBonus = vegasPropsBonus(player);

  let base = valueScore*0.80 + scarcityScore*0.20 + adpBonus + rzBonus + scheduleBonus + propsBonus - flatRiskPenalty - competitionPenalty;
  let score = Math.max(1, Math.min(100, Math.round(base)));
```

Then find:

```javascript
  return { score, valueScore, scarcityScore, adpBonus, rzBonus, scheduleBonus, flatRiskPenalty, competitionPenalty, deltaPicks, modelRank };
```

Replace with:

```javascript
  return { score, valueScore, scarcityScore, adpBonus, rzBonus, scheduleBonus, propsBonus, flatRiskPenalty, competitionPenalty, deltaPicks, modelRank };
```

*Note: the exact text above appears once each in the file — `grep -n` for it first if an `Edit` reports "not unique" (that would mean this plan's file-read snapshot drifted from the live file; re-read the surrounding lines and adjust the anchor before editing).*

- [ ] **Step 5: Wire the reasoning clause in `buildReasoning()`**

Find this exact text:

```javascript
  if(Math.abs(comps.scheduleBonus||0) >= 3){
    const matchupType = player.position==='RB' ? 'run defenses' : 'pass defenses';
    clauses.push(comps.scheduleBonus>0
      ? `Favorable weeks 15-17 schedule against soft ${matchupType}.`
      : `Tough weeks 15-17 schedule against strong ${matchupType}.`);
  }
```

Replace with:

```javascript
  if(Math.abs(comps.scheduleBonus||0) >= 3){
    const matchupType = player.position==='RB' ? 'run defenses' : 'pass defenses';
    clauses.push(comps.scheduleBonus>0
      ? `Favorable weeks 15-17 schedule against soft ${matchupType}.`
      : `Tough weeks 15-17 schedule against strong ${matchupType}.`);
  }
  if(Math.abs(comps.propsBonus||0) >= 3){
    clauses.push(comps.propsBonus>0
      ? `Vegas season props imply meaningfully more points than the model's own projection.`
      : `Vegas season props imply meaningfully fewer points than the model's own projection.`);
  }
```

- [ ] **Step 6: Wire the breakdown row in `scoreBreakdownRows()`**

Find this exact text:

```javascript
  const sched = TEAM_SCHEDULE_DIFFICULTY[player.team];
  if(sched && comps.scheduleBonus !== undefined){
    const rank = player.position==='RB' ? sched.avgOppRunRank : sched.avgOppPassRank;
    const matchupType = player.position==='RB' ? 'run defenses' : 'pass defenses';
    const sb = comps.scheduleBonus;
    const value = sb===0 ? `neutral — avg. weeks 15-17 opponent rank ${rank.toFixed(1)}/32 vs ${matchupType}`
      : `${sb>0?'+':''}${sb} pts — avg. weeks 15-17 opponent rank ${rank.toFixed(1)}/32 vs ${matchupType} (${sb>0?'favorable':'difficult'})`;
    rows.push({ label: 'Playoff-week schedule difficulty', value });
  }
  return rows;
```

Replace with:

```javascript
  const sched = TEAM_SCHEDULE_DIFFICULTY[player.team];
  if(sched && comps.scheduleBonus !== undefined){
    const rank = player.position==='RB' ? sched.avgOppRunRank : sched.avgOppPassRank;
    const matchupType = player.position==='RB' ? 'run defenses' : 'pass defenses';
    const sb = comps.scheduleBonus;
    const value = sb===0 ? `neutral — avg. weeks 15-17 opponent rank ${rank.toFixed(1)}/32 vs ${matchupType}`
      : `${sb>0?'+':''}${sb} pts — avg. weeks 15-17 opponent rank ${rank.toFixed(1)}/32 vs ${matchupType} (${sb>0?'favorable':'difficult'})`;
    rows.push({ label: 'Playoff-week schedule difficulty', value });
  }
  if(player.vegasProps && comps.propsBonus !== undefined){
    const impliedPts = impliedSeasonPtsFromProps(player);
    const modelPts = player.projection && player.projection.projSeasonPts;
    const pb = comps.propsBonus;
    const value = (impliedPts===null || !modelPts)
      ? 'incomplete line(s) found for this position — not enough to compare'
      : `${pb===0?'neutral':(pb>0?'+':'')+pb+' pts'} — Vegas implies ${Math.round(impliedPts)} season pts vs model's ${Math.round(modelPts)}`;
    rows.push({ label: 'Vegas season player props', value });
  }
  return rows;
```

- [ ] **Step 7: Wire the compare-verdict diff in `buildCompareVerdict()`**

Find this exact text:

```javascript
    { label:'red-zone (touchdown-equity) usage', delta: (winner.comps.rzBonus||0) - (runnerUp.comps.rzBonus||0) },
    { label:'playoff-week schedule difficulty', delta: (winner.comps.scheduleBonus||0) - (runnerUp.comps.scheduleBonus||0) },
```

Replace with:

```javascript
    { label:'red-zone (touchdown-equity) usage', delta: (winner.comps.rzBonus||0) - (runnerUp.comps.rzBonus||0) },
    { label:'playoff-week schedule difficulty', delta: (winner.comps.scheduleBonus||0) - (runnerUp.comps.scheduleBonus||0) },
    { label:'Vegas season player props', delta: (winner.comps.propsBonus||0) - (runnerUp.comps.propsBonus||0) },
```

- [ ] **Step 8: Run the diagnostic again to confirm it passes**

```powershell
Copy-Item "C:\Users\mason\OneDrive\Desktop\FantasyDraftAssistant\index.html" "$env:TEMP\fda_diag2.html"
# re-append the same <script> block from Step 1 before </body>
msedge.exe --headless=new --disable-gpu --no-sandbox --dump-dom --virtual-time-budget=20000 "file:///C:/Users/mason/AppData/Local/Temp/fda_diag2.html" > "$env:TEMP\fda_diag2_dump.html"
```

Extract `#diagResults2`. Expected: every value `true` (`scorePlayerHasPropsBonus`, `bigBoardHasPropsBonus`, `breakdownHasPropsRow`, `reasoningMentionsProps`, `verdictIsAString`).

- [ ] **Step 9: Commit**

```bash
cd "C:\Users\mason\OneDrive\Desktop\FantasyDraftAssistant"
git add index.html
git commit -m "Wire propsBonus into scoring, reasoning, breakdown, and compare verdict

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: Research real Vegas season player-prop lines

**Files:**
- Create: `<scratchpad>/vegas_props_research.json` (the session scratchpad directory — this is a working artifact, not part of the app; it feeds Task 4)

**Interfaces:**
- Produces: a JSON file mapping `data/players.json` player `id` strings to the same `vegasProps` shape defined in Task 1/the design spec: `{ rushYards, recYards, passYards, totalTD, passTD, source, asOf }` (omit keys that weren't found rather than writing `null` for all of them — Task 4 reads whichever keys are present).

This is a research task, not a code task — the exact players found can't be known in advance. What's fixed is the method, the budget, the required rigor, and the output format.

- [ ] **Step 1: Get the full player list to match against**

```powershell
$players = Get-Content -Raw "C:\Users\mason\OneDrive\Desktop\FantasyDraftAssistant\data\players.json" | ConvertFrom-Json
$players | Where-Object { $_.position -in @('RB','WR','TE','QB') } | Select-Object id, name, team, position, tier | ConvertTo-Json | Out-File "$env:TEMP\fda_player_index.json" -Encoding utf8
```

This is the lookup table for matching a name found in research back to an exact `id` — match on `name` (allowing for suffix punctuation drift) AND `team`, never on name alone (two different-team players can share a name).

- [ ] **Step 2: Research in position batches, using bulk aggregator pages, not per-player queries**

Budget: aim to stay well under half the session's 200-call WebSearch quota on the *search* calls specifically (WebFetch to a specific known URL doesn't count against it, per `CLAUDE.md`), since Task 3 research and any later re-research both draw from the same pool. Search for aggregator/roundup pages that list many players' season prop lines on one page (a single sportsbook's season-props hub, or a media roundup article), then WebFetch those specific pages to extract as many players per fetch as possible, rather than one query per player.

Starting queries (adjust based on what actually surfaces good aggregator pages — this is exploratory by nature):
- `"2026 NFL season rushing yards prop bets" running backs DraftKings FanDuel`
- `"2026 fantasy football" "season long" player prop win totals RB WR`
- `"2026 NFL receiving yards" season prop bets wide receivers`
- `"2026 NFL passing yards" "passing touchdowns" season prop bets quarterbacks`
- `"2026 NFL" tight end receiving yards touchdowns season props`
- `"2026 NFL total touchdowns" season prop bets running back wide receiver`

For each promising result, WebFetch the specific page and extract every player/line pair it lists (not just the one player you were originally looking for) — a single good roundup page can cover a dozen-plus players in one fetch.

- [ ] **Step 3: Apply the same rigor standard already established for this project**

For every line you're about to record:
- It must be a real, findable, dated line from an identifiable source (a named sportsbook or a specific article citing one) — never interpolated or estimated "because it seems about right" for a player whose actual line you couldn't find.
- If two sources disagree on the same player's line, say so in your own notes/summary to the user rather than silently picking one (same standard already applied to conflicting StatMuse fetches on this project).
- If Pro-Football-Reference-style blocked sources or unreliable ad-hoc StatMuse-style pages are all you can find for a player, skip that player rather than trust a single unreliable fetch — leave them with no `vegasProps` entry, which the required-dimension gate already turns into a clean `propsBonus = 0` rather than a wrong signal.

- [ ] **Step 4: Write findings incrementally to the scratch file**

Append each confirmed player to `<scratchpad>/vegas_props_research.json` as you go (don't hold everything in memory until the end — write incrementally so partial progress survives if the session is interrupted):

```json
{
  "jahmyr-gibbs-det-rb": { "rushYards": 1100, "totalTD": 11, "recYards": 550, "source": "DraftKings", "asOf": "2026-08-09" },
  "josh-allen-buf-qb": { "passYards": 4100, "passTD": 32, "source": "FanDuel", "asOf": "2026-08-09" }
}
```

- [ ] **Step 5: Report coverage honestly**

Once research is wound down (budget spent or diminishing returns on new aggregator pages), report to the user: how many of the ~200 RB/WR/TE/QB players got a real entry, broken down by position, and name any players you specifically expected to find but couldn't (e.g. notable names with no posted season prop found) — this is the same "willing to report a negative result" standard already established for this project. Do not proceed to Task 4 silently; surface this summary first.

---

### Task 4: Apply researched data to `data/players.json`

**Files:**
- Modify: `data/players.json`

**Interfaces:**
- Consumes: `<scratchpad>/vegas_props_research.json` from Task 3.
- Produces: each researched player's JSON object in `data/players.json` gains a `vegasProps` key matching the shape consumed by `impliedSeasonPtsFromProps` (Task 1).

- [ ] **Step 1: For each researched player, splice in the field using the project's documented technique**

Per `CLAUDE.md`'s "Editing players.json" section — `Get-Content -Raw`, find a unique anchor (`"id":  "<player-id>"`), splice with `.Substring`, `Set-Content -NoNewline`, validate with `ConvertFrom-Json` immediately after every single splice (not batched at the end — a broken splice fails silently otherwise). Concretely, for one player:

```powershell
$raw = Get-Content -Raw "C:\Users\mason\OneDrive\Desktop\FantasyDraftAssistant\data\players.json"
$anchor = '"id":  "jahmyr-gibbs-det-rb"'
$idx = $raw.IndexOf($anchor)
if($idx -lt 0){ throw "anchor not found" }
# Find the end of this player object's "projection" block (or another stable
# nearby field) to insert the new vegasProps sibling key after it -- inspect
# the actual surrounding text with $raw.Substring($idx, 800) first, since
# object layout varies slightly per player entry.
```

Because exact byte offsets differ per player entry (some have longer `blurb`/`newsLog` sections than others), inspect each player's actual surrounding JSON with `$raw.Substring($idx, 1500)` before deciding where to splice the new `"vegasProps": {...},` key in — insert it as a new top-level sibling field on the player object (next to `"projection"` is a natural, readable spot), not inside another object.

- [ ] **Step 2: Validate after every single player's edit**

```powershell
$check = Get-Content -Raw "C:\Users\mason\OneDrive\Desktop\FantasyDraftAssistant\data\players.json" | ConvertFrom-Json
$check.Count  # must still equal the pre-edit count (200) -- a broken splice can silently drop or duplicate an object
($check | Where-Object id -eq 'jahmyr-gibbs-det-rb').vegasProps  # must show the new field
```

If `ConvertFrom-Json` throws or the count changed, the file is broken — do not proceed to the next player until it's fixed (revert that one splice and retry).

- [ ] **Step 3: Repeat Step 1-2 for every player recorded in Task 3's scratch file**

- [ ] **Step 4: Final full-file validation**

```powershell
$final = Get-Content -Raw "C:\Users\mason\OneDrive\Desktop\FantasyDraftAssistant\data\players.json" | ConvertFrom-Json
$final.Count  # still 200
($final | Where-Object { $_.vegasProps }).Count  # the real coverage number to report
```

- [ ] **Step 5: Commit and push**

```bash
cd "C:\Users\mason\OneDrive\Desktop\FantasyDraftAssistant"
git add data/players.json
git commit -m "Add researched Vegas season player-prop lines to player data

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
git push
```

Pushing is required — per `CLAUDE.md`, the running app fetches `data/players.json` live from `raw.githubusercontent.com`, so a local-only commit has no effect on what the user sees.

---

### Task 5: Live verification — diagnostic re-run, NaN sweep, mock-draft regression

**Files:**
- None modified — this task only runs diagnostics against what Tasks 1-4 already produced.

**Interfaces:**
- Consumes: `scorePlayer`, `computeBigBoardScore`, `ALL_PLAYERS`, `draftState`, `makePick(playerId, mine)` — all existing/already-wired.

- [ ] **Step 1: Re-run Task 2's diagnostic against the live pushed data**

```powershell
Copy-Item "C:\Users\mason\OneDrive\Desktop\FantasyDraftAssistant\index.html" "$env:TEMP\fda_diag2_live.html"
```

This time, instead of injecting a fake `vegasProps` override, find a *real* player who now has one from Task 4 and confirm the field is actually live-loaded and flowing through. Append before `</body>`:

```html
<script>
(function(){
  const startedAt = Date.now();
  function tryRun(){
    if(typeof ALL_PLAYERS !== 'undefined' && ALL_PLAYERS.length > 0){
      runTest();
    } else if(Date.now() - startedAt < 15000){
      setTimeout(tryRun, 200);
    } else {
      document.body.insertAdjacentHTML('beforeend', '<div id="diagResultsLive">'+JSON.stringify({error:'ALL_PLAYERS never loaded'})+'</div>');
    }
  }
  function runTest(){
    const results = {};
    const withProps = ALL_PLAYERS.filter(p => p.vegasProps);
    results.playersWithVegasProps = withProps.length;
    results.dataSource = typeof DATA_SOURCE !== 'undefined' ? DATA_SOURCE : 'unknown';
    if(withProps.length > 0){
      const sample = withProps[0];
      const comps = scorePlayer(sample);
      results.samplePlayerId = sample.id;
      results.samplePropsBonus = comps.propsBonus;
      results.samplePropsBonusIsFinite = Number.isFinite(comps.propsBonus);
    }
    document.body.insertAdjacentHTML('beforeend', '<div id="diagResultsLive">'+JSON.stringify(results)+'</div>');
  }
  tryRun();
})();
</script>
</body>
```

Run:
```bash
msedge.exe --headless=new --disable-gpu --no-sandbox --dump-dom --virtual-time-budget=20000 "file:///C:/Users/mason/AppData/Local/Temp/fda_diag2_live.html" > "$env:TEMP\fda_diag2_live_dump.html"
```

Expected: `dataSource` is `"live"` (confirms the push in Task 4 actually took effect — if it's `"local"` or `"fallback"`, the live fetch failed and the diagnostic isn't actually testing real data), `playersWithVegasProps` matches Task 4's final coverage count, `samplePropsBonusIsFinite` is `true`.

- [ ] **Step 2: NaN sweep across the full player pool**

Append (or reuse the same live-data-loaded diagnostic) this check:

```html
<script>
(function(){
  const startedAt = Date.now();
  function tryRun(){
    if(typeof ALL_PLAYERS !== 'undefined' && ALL_PLAYERS.length > 0){
      runTest();
    } else if(Date.now() - startedAt < 15000){
      setTimeout(tryRun, 200);
    } else {
      document.body.insertAdjacentHTML('beforeend', '<div id="diagResultsNaN">'+JSON.stringify({error:'ALL_PLAYERS never loaded'})+'</div>');
    }
  }
  function runTest(){
    const badPlayers = [];
    for(const p of ALL_PLAYERS){
      if(p.position==='DST' || p.position==='K') continue;
      const comps = scorePlayer(p);
      const big = computeBigBoardScore(p);
      if(!Number.isFinite(comps.score) || !Number.isFinite(comps.propsBonus) || !Number.isFinite(big.score) || !Number.isFinite(big.propsBonus)){
        badPlayers.push({ id: p.id, scoreOk: Number.isFinite(comps.score), propsBonusOk: Number.isFinite(comps.propsBonus) });
      }
    }
    document.body.insertAdjacentHTML('beforeend', '<div id="diagResultsNaN">'+JSON.stringify({ badPlayers, checkedCount: ALL_PLAYERS.filter(p=>p.position!=='DST'&&p.position!=='K').length })+'</div>');
  }
  tryRun();
})();
</script>
</body>
```

Expected: `badPlayers` is an empty array.

- [ ] **Step 3: Multi-round mock-draft regression**

Append this diagnostic, which drives a full simple auto-draft through the real app functions (`makePick`) to catch any crash/NaN that only shows up once players start getting removed from the pool round over round:

```html
<script>
(function(){
  const startedAt = Date.now();
  function tryRun(){
    if(typeof ALL_PLAYERS !== 'undefined' && ALL_PLAYERS.length > 0){
      runTest();
    } else if(Date.now() - startedAt < 15000){
      setTimeout(tryRun, 200);
    } else {
      document.body.insertAdjacentHTML('beforeend', '<div id="diagResultsMockDraft">'+JSON.stringify({error:'ALL_PLAYERS never loaded'})+'</div>');
    }
  }
  function runTest(){
    draftState = { started:true, leagueSize:12, myDraftSlot:1, picks:[], drafted:new Set(), myRoster:{} };
    const errors = [];
    const totalPicks = 12*8; // 8 rounds, enough to exercise every roundStage
    for(let i=0; i<totalPicks; i++){
      const pool = availablePlayers();
      if(pool.length===0) break;
      try {
        const scored = pool.map(p => ({ p, s: scorePlayer(p).score }));
        if(scored.some(x => !Number.isFinite(x.s))){
          errors.push({ pickNumber: i+1, issue: 'non-finite score in pool' });
        }
        scored.sort((a,b)=>b.s-a.s);
        const pickNumber = draftState.picks.length + 1;
        const team = teamAtPick(pickNumber, draftState.leagueSize);
        makePick(scored[0].p.id, team===draftState.myDraftSlot);
      } catch(e){
        errors.push({ pickNumber: i+1, issue: String(e) });
        break;
      }
    }
    document.body.insertAdjacentHTML('beforeend', '<div id="diagResultsMockDraft">'+JSON.stringify({ picksCompleted: draftState.picks.length, errors })+'</div>');
  }
  tryRun();
})();
</script>
</body>
```

Expected: `picksCompleted` is `96`, `errors` is an empty array.

- [ ] **Step 4: Report final results to the user**

Summarize: real coverage count/percentage (from Task 3/4), confirmation that `dataSource` was `"live"` during verification, NaN sweep result, mock-draft regression result. This is the completion report — do not claim the feature is "done" without these four numbers in hand.
