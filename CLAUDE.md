# Fantasy Draft Assistant

A personal fantasy football draft-assistant web app for a 12-team, Full PPR, single-QB redraft league. Built for the 2026 season. The user opens `index.html` locally in a browser during their draft — it is **not** a Claude Artifact.

## Architecture

- **`index.html`** — the entire app: UI, CSS, and the full scoring/logic engine, all in one file, vanilla JS, no build step, no framework.
- **`data/players.json`** — ~200 hand-researched QB/RB/WR/TE players (schema documented near the top of the scoring section in `index.html` and in git history — read a player entry directly rather than guessing the shape).
- **`data/dstk.json`** — 32 DST + 24 K, lighter schema (no `prevSeason`/`anomalyAdjusted`/`risk`).
- **GitHub repo `serenoah/fantasy-draft-assistant`** is the sync point. `index.html` fetches `data/*.json` live from `raw.githubusercontent.com` on load (falls back to a local relative file, then a tiny embedded dataset, if that fails). **This means data-file changes must be committed AND pushed before they take effect for the user** — a local-only edit does nothing until pushed.

## Critical testing workflow

There is no Node/Python in this environment and no test framework. The **only** way to verify JS logic changes:

1. Copy `index.html` to a scratch location (e.g. the job's `tmp/` dir).
2. Append a `<script>` block before `</body>` that waits for `ALL_PLAYERS.length > 0`, exercises the function(s) under test, and writes a JSON result into a `<div id="diagResults...">`.
3. Run headless Edge: `msedge.exe --headless=new --disable-gpu --no-sandbox --dump-dom --virtual-time-budget=20000 "file:///<path>" > dump.html`
4. Extract the results div from the dump and read it.

**Local `data/` edits are invisible to this harness** — `fetch()` on a `file://` page can't read local relative files (browser security), and the live GitHub fetch will win and pull the *old* pushed data. So: for JS-only changes, this works fine (data is unaffected). For data-file changes, you must commit + push first, *then* run the diagnostic against the live (now-current) data to verify.

Always check for `NaN` across the full player pool and run a multi-round mock draft as a regression check before committing anything that touches scoring.

## Editing `players.json` / `dstk.json`

- It's PowerShell-formatted JSON (`ConvertTo-Json` style: two spaces after each `:`). Apostrophes are sometimes stored as the literal 6-character escape sequence `'` rather than a real `'` — if a text-based `Edit` match fails unexpectedly, this is usually why.
- The reliable technique for surgical edits: PowerShell `Get-Content -Raw`, `IndexOf` an anchor (usually a unique `"id":  "player-id"` string), splice with `.Substring`, `Set-Content -NoNewline`. **Always validate with `ConvertFrom-Json` immediately after** — a broken splice fails silently otherwise (see: the A.J. Brown edit that silently dropped the `position` field, caught only by a live-data diagnostic showing "undefined starters" in the reasoning text).
- Team codes must match exactly between `players.json` and `dstk.json` for the same team (a `WSH`/`WAS` mismatch on Washington's DST silently broke team-level lookups for months — fixed, but check for this pattern before trusting any new team-level feature).

## Scoring engine — key design decisions (don't re-litigate these without re-reading why)

- **`valueScore` is normalized WITHIN position**, not across the whole player pool. Comparing raw VORP magnitude cross-position systematically overrates shallow-replacement positions (TE, RB) and underrates deep ones (WR) — this was a real, confirmed bug (TE/RB crowded the top of the board over clearly-better-ADP WRs) fixed by scoring each position against its own pool.
- **`POSITION_VALUE_DAMPENER`** blends the model's score with real ADP percentile for TE (heavy, 0.15 model weight) and QB (moderate, 0.55) — those positions get systematically overvalued by pure VORP math (single-starter-slot cliff). RB/WR get a light touch (0.88) purely as a cross-position sanity check.
- **`scarcityScore`** measures what fraction of a position's *original* tier≤3 pool has been drafted (a ratio), not a raw remaining count — a raw count structurally favors shallow positions the same way raw VORP does.
- **`TEAM_SCHEDULE_DIFFICULTY`** (added Aug 2026) — real, researched per-team playoff-week (15-17) opponent strength, split by run-defense (RB) vs pass-defense (WR/TE/QB), since a team's schedule can be tough for one and soft for the other. This *replaced* an attempt to use `player.schedule.playoffSosGrade` — that per-player field was found to be internally inconsistent across 32/33 team rosters (authored as narrative color, not real data) and is still unused/unreliable; don't wire it into scoring without re-authoring it first.
- **Every scoring-affecting factor should be modest and bounded.** Compare any new point swing against the existing scale: `ADP_BONUS_CLAMP` (~±2.4 effective), `BYE_CONFLICT_PENALTY` (5/10), `RISK_PENALTY` (2-18 by round stage), `redZoneBonus` (+8 cap), `SCHEDULE_DIFFICULTY_CLAMP` (±5 early to ±3 late). The user has explicitly asked more than once for factors to be "fair" and "not too strong" — err toward smaller, not larger.
- **Real data over fabrication, always.** Every projection adjustment should be traceable to a real, checkable fact (a teammate's documented injury, a real red-zone-volume-vs-TD mismatch, a real trade). The user has explicitly pushed back to verify this isn't just confirmation bias from something they mentioned — the standard to hold is: would this same finding get flagged if the user hadn't brought up the specific player?

## Data confidence / research notes

- Player data was researched via WebFetch/WebSearch across many sessions (rookies, red-zone usage, target share, injury context, trade updates). Treat any given player's data as reasonably current as of its `meta.lastUpdated`, but not infallible — a full 6-agent audit (Aug 2026) found real bugs: 13 bye-week mismatches, stale trade data (players whose team changed but whose own record didn't), and missing-but-clearly-warranted projection adjustments. More of the same is likely still lurking; a similar audit pass is cheap to re-run periodically.
- **WebSearch has a per-session quota (200 calls) that does not reset within a conversation.** If it's exhausted, WebFetch to *specific known URLs* still works (doesn't consume the quota) — Wikipedia team/season pages and ESPN team stat pages have both proven reliable this project; Pro-Football-Reference blocks WebFetch (403); ad-hoc StatMuse "ask" URLs are unreliable (inconsistent/contradictory results across repeated fetches — don't trust a single StatMuse fetch for anything load-bearing). To raise the WebSearch cap for a *future* session, the user needs to set `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` in their environment *before* that session starts (it's read once at launch, not re-checked mid-session).

## In-season data refresh (`tools/`)

- Oct 7 2026 the whole pool was refreshed from **public JSON APIs** (no WebSearch quota needed): ESPN `lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/2026/segments/0/leaguedefaults/3?view=kona_player_info` (needs an `X-Fantasy-Filter` header; gives PPR ADP, rest-of-season projections as statSourceId 1, 2026 actuals as statSourceId 0, injury status), `...seasons/2026?view=proTeamSchedules_wl` (team ids + byes), and Sleeper `api.sleeper.app/v1/players/nfl`, `/stats/nfl/regular/2026`, `/projections/nfl/regular/2026` (teams, injuries, `adp_ppr`). Sleeper is more current than ESPN on team affiliation (ESPN shows practice-squad players as FA).
- Re-run: download those to a scratch `dl/` dir (see `tools/merge.ps1` for filenames), then `merge.ps1` → `update.ps1` (writes new players.json/dstk.json to an out dir; bump `$CUR_WEEK`) → `diag.ps1 -DataDir <out>` which embeds the candidate data into a test page so it can be verified **before** pushing. Old values are kept in `adp.preseasonAug`, `blurb.preseasonSummary`, `blurb.preseasonRiskReason`; new facts in `inSeason2026`.
- Never rewrite `index.html` with PowerShell `Get-Content`/`Set-Content` — PS 5.1 reads it as ANSI and mangles every non-ASCII character. Use the Edit tool or `[IO.File]` with explicit UTF-8.
- Known, pre-existing (not data-related): mock drafts with the model's top pick each round take 3 TEs + a DST by round 10 — roster-construction/need-multiplier logic, not yet investigated.

## Pending / next up

- **Vegas/sportsbook player prop lines** — the user wants season-long rushing/receiving yards and TD props (RB), receiving yards/TD props (WR), and the equivalent for QB/TE, incorporated as a scoring signal. Not started — blocked on WebSearch quota in the session where schedule-difficulty was built (Aug 2026); needs a fresh session's search budget to do real research rather than guessing at numbers. When picking this up: follow the same "fair, not too strong" bounded-adjustment pattern as `TEAM_SCHEDULE_DIFFICULTY`, and the same real-data-only discipline — never fabricate a plausible-looking line.
