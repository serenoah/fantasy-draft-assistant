# Weekly in-season refresh: download ESPN + Sleeper data, rebuild data/*.json, verify in headless Edge, install.
# Runs locally (Windows PowerShell 5.1) or in GitHub Actions (windows-latest). Throws on any failed check,
# leaving data/ untouched, so a bad API response can never be committed.
param([string]$Repo = (Split-Path -Parent $PSScriptRoot), [switch]$NoInstall)
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$work = Join-Path ([IO.Path]::GetTempPath()) ("fda-refresh-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$dl = Join-Path $work 'dl'; $out = Join-Path $work 'out'
New-Item -ItemType Directory -Force $dl, $out | Out-Null

function Download($url, $file, $headers = @{}){
  for($i = 1; $i -le 3; $i++){
    try { Invoke-WebRequest -UseBasicParsing -Uri $url -Headers $headers -OutFile (Join-Path $dl $file) -TimeoutSec 300; return }
    catch { if($i -eq 3){ throw "Download failed for $url : $($_.Exception.Message)" }; Start-Sleep -Seconds (10 * $i) }
  }
}

Download 'https://api.sleeper.app/v1/state/nfl' 'sl_state.json'
$state = Get-Content -Raw (Join-Path $dl 'sl_state.json') | ConvertFrom-Json
if($state.season_type -ne 'regular'){ "Sleeper reports season_type '$($state.season_type)'; nothing to refresh."; return }
$season = $state.season; $week = [int]$state.week
"Refreshing season $season, current week $week"

$espnFilter = '{"players":{"filterSlotIds":{"value":[0,2,4,6,23,16,17]},"limit":450,"sortPercOwned":{"sortPriority":1,"sortAsc":false},"filterStatsForTopScoringPeriodIds":{"value":2,"additionalValue":["00' + $season + '","10' + $season + '"]}}}'
Download "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/$season/segments/0/leaguedefaults/3?view=kona_player_info" 'espn.json' @{ 'X-Fantasy-Filter' = $espnFilter }
Download "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/$season`?view=proTeamSchedules_wl" 'espn_teams.json'
Download 'https://api.sleeper.app/v1/players/nfl' 'sl_players.json'
Download "https://api.sleeper.app/v1/stats/nfl/regular/$season" 'sl_stats.json'
Download "https://api.sleeper.app/v1/projections/nfl/regular/$season" 'sl_proj.json'

& "$PSScriptRoot\merge.ps1" -Repo $Repo -Dl $dl -Out (Join-Path $work 'merged.json')
$merged = Get-Content -Raw (Join-Path $work 'merged.json') | ConvertFrom-Json
$matchedCount = @($merged.matched | ? { $_.espn }).Count
if($matchedCount -lt 0.9 * @($merged.matched).Count){ throw "Only $matchedCount of $(@($merged.matched).Count) players matched ESPN data; refusing to update." }

& "$PSScriptRoot\update.ps1" -Repo $Repo -Merged (Join-Path $work 'merged.json') -TeamsFile (Join-Path $dl 'espn_teams.json') -OutDir $out -CurWeek $week

# Structural validation
$p = Get-Content -Raw -Encoding UTF8 (Join-Path $out 'players.json') | ConvertFrom-Json
$k = Get-Content -Raw -Encoding UTF8 (Join-Path $out 'dstk.json') | ConvertFrom-Json
if(@($p).Count -lt 200){ throw "Only $(@($p).Count) players in output." }
if(@($k.DST).Count -ne 32 -or @($k.K).Count -lt 20){ throw "Unexpected DST/K counts: $(@($k.DST).Count) / $(@($k.K).Count)" }
$bad = @($p | ? { -not $_.position -or -not $_.team -or -not $_.id -or $_.projection.projPPG -isnot [ValueType] -or $_.adp.overall -isnot [ValueType] })
if($bad.Count){ throw "Malformed player records: $(($bad | % { $_.id }) -join ', ')" }

# Behavioral validation: embedded-data page, NaN sweep over every player, 10-round mock draft
$diag = (& "$PSScriptRoot\diag.ps1" -Repo $Repo -DataDir $out -Work $work -Slot 6 -Rounds 10 | Out-String) | ConvertFrom-Json
if(-not $diag){ throw 'Diagnostic page produced no results.' }
if(@($diag.errors).Count -or @($diag.nan).Count -or $diag.uiUndefinedOrNaN -or @($diag.mine).Count -ne 10){ throw "Diagnostic failed: $($diag | ConvertTo-Json -Depth 4 -Compress)" }
"Diagnostic passed: $($diag.n) players, mock draft:"; $diag.mine | % { "  $_" }

"--- notable changes ---"; $cl = Join-Path $out 'changes.log'; if(Test-Path $cl){ Get-Content $cl } else { '(none)' }
if(-not $NoInstall){
  Copy-Item (Join-Path $out 'players.json') (Join-Path $Repo 'data\players.json') -Force
  Copy-Item (Join-Path $out 'dstk.json') (Join-Path $Repo 'data\dstk.json') -Force
  "Installed refreshed data into $Repo\data"
} else { "Dry run; output left in $out" }
