# Design: Vegas season player-prop scoring signal

**Date:** 2026-08-08
**Status:** Approved
**Scope:** `index.html` scoring engine + `data/players.json` — adds a new, bounded scoring factor (`propsBonus`) alongside the existing `scheduleDifficultyBonus`/`redZoneBonus` factors.

## Background

`CLAUDE.md`'s "Pending / next up" section has flagged this since the schedule-difficulty feature shipped (Aug 2026): incorporate real Vegas/sportsbook season-long player prop lines (season rushing/receiving yards and TDs for RB, receiving yards/TDs for WR, the equivalent for QB/TE) as a scoring signal, following the same "fair, not too strong," real-data-only discipline already established for `TEAM_SCHEDULE_DIFFICULTY`. Not started previously — blocked on WebSearch quota exhaustion in the session that built schedule-difficulty.

## Decisions

1. **Player scope: everyone, best-effort.** Attempt research broadly rather than pre-filtering to top tiers; expect most late-round/bench players to come back empty and fall through to the same neutral-0 "no data" handling `redZoneBonus` already uses.
2. **Prop categories: yards + TDs**, where available — season rushing/receiving/passing yards O/U plus season total-TD O/U (a single combined rush+rec TD line for RB/WR, matching how books actually post it, not split by type; passing TD as its own line for QB).
3. **Scoring mechanism: implied-points-vs-model delta.** Convert found prop lines to an implied full-PPR season point total using the league's actual scoring formula, and compare against the player's own `projection.projSeasonPts` — the same "market vs. model" idea as the existing ADP bonus, but stat-grounded instead of rank-based.

## Data schema

New optional field per player in `data/players.json` (RB/WR/TE/QB only — DST/K excluded, same reasoning `TEAM_SCHEDULE_DIFFICULTY` already documents: a season yardage/TD line isn't a meaningful concept for those positions):

```json
"vegasProps": {
  "rushYards": 1050,
  "totalTD": 9,
  "recYards": 350,
  "passYards": null,
  "passTD": null,
  "source": "DraftKings",
  "asOf": "2026-08-08"
}
```

Absent entirely (no `vegasProps` key) for any player with no real posted line — never a guessed/interpolated value.

## No-fabrication gate (required dimensions per position)

A player only gets a nonzero `propsBonus` if the *required* dimensions for their position were actually found. This avoids a structural bias where a player with only partial market coverage (e.g. a pass-catching RB with a rushing-yards line but no receiving-yards line found) reads as "overvalued by the model" purely because the market data is incomplete, not because the model is wrong.

- **RB:** `rushYards` AND `totalTD` required. `recYards` adds to the implied total if found, but is never required (many backs are pure runners with negligible receiving work — requiring it would zero out real signal for them for no good reason).
- **WR/TE:** `recYards` AND `totalTD` required.
- **QB:** `passYards` AND `passTD` required.

Missing a required dimension → `propsBonus = 0`, identical in spirit to `redZoneBonus`'s "no data → neutral 0" handling.

## Implied points formula

Verified against the app's own existing data rather than assumed: full-PPR skill-position scoring is `rushYds/10 + recYds/10 + receptions×1 + TD×6` (confirmed exactly against Jahmyr Gibbs' `prevSeason`: 122.3+61.6+77+108 = 368.9, matching his stored `pprPts`). QB passing scoring is `passYds/25 + passTD×4` (confirmed against Lamar Jackson's `prevSeason`: 101.96+84 = 175.96 ≈ his non-rushing point total of 176.0; Josh Allen and Drake Maye's entries show a few points of drift from this exact formula, consistent with this being hand-authored data with known minor inconsistencies per `CLAUDE.md`'s data-confidence notes — not a sign of a different formula).

Since prop books don't post a receptions line, the implied-points calculation for props omits the reception-count term (props are yards + TD only):

- RB: `impliedPts = rushYards/10 + (recYards ?? 0)/10 + totalTD*6`
- WR/TE: `impliedPts = recYards/10 + totalTD*6`
- QB: `impliedPts = passYards/25 + passTD*4`

## Score integration

```
deltaPct = (impliedPts - player.projection.projSeasonPts) / player.projection.projSeasonPts
propsBonus = clamp(round(deltaPct / 0.20 * 5), -5, +5)
```

A ≥20% gap between Vegas-implied season points and the model's own projection maxes out the ±5 clamp. This is deliberately set at parity with `SCHEDULE_DIFFICULTY_CLAMP`'s most generous stage (±5), not above it, and — unlike the stage-scaled schedule/risk factors — flat across all draft stages, since like the ADP bonus this is a market-consistency check rather than a roster-construction-pressure factor.

`propsBonus` is added into `base` in both `scorePlayer()` and `computeBigBoardScore()` alongside `rzBonus`/`scheduleBonus`, and returned in both functions' result objects.

## UI / explainability integration

Threaded through the same three places `scheduleBonus` already appears, so the new factor is visible and explainable rather than a silent number:

1. **Reasoning clauses** (the per-player narrative text) — a clause fires only when `|propsBonus| >= 3` (mirroring the existing `Math.abs(comps.scheduleBonus||0) >= 3` threshold), naming the market/model disagreement in plain language.
2. **`scoreBreakdownRows()`** — a row showing the found prop line(s), the implied point total, and the resulting bonus/penalty, in the same style as the existing schedule-difficulty row.
3. **`buildCompareVerdict()`** — a `propsBonus` entry added to the `diffs` array used when explaining why one compared player outranks another.

## Research plan and honesty about coverage

"Everyone, best-effort" does not mean literal per-player queries for all 200 players — sportsbooks simply don't post season props for deep bench/backup players, and 200 individual searches would blow the WebSearch session quota (200 calls, doesn't reset mid-conversation) for no return on most of them. Instead: find bulk aggregator pages (season-prop roundup articles/pages covering many players per fetch, grouped by position or team) via a smaller number of WebSearch calls, then WebFetch those specific pages (WebFetch to a known URL doesn't consume the WebSearch quota, per `CLAUDE.md`'s existing notes) to extract many players' lines per fetch. Final coverage will be reported honestly (e.g. "found real lines for N of 200 players") rather than implied as complete.

## Testing plan

Follow `CLAUDE.md`'s established workflow exactly, since there is no Node/Python test framework in this environment:

1. Copy `index.html` to a scratch location, append a diagnostic `<script>` exercising `vegasPropsBonus()` (and the required-dimension gate) against a handful of known player fixtures with hand-picked `vegasProps` values, run headless Edge, verify results.
2. After real data lands in `players.json`: commit + push (data changes are invisible locally, per `CLAUDE.md`), then re-run the diagnostic against the now-live data.
3. Check for `NaN` across the full player pool.
4. Run a multi-round mock draft as a regression check before committing anything that touches scoring.
