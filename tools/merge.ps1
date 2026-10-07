# Joins our players.json against ESPN + Sleeper public API data and writes merged.json
param([string]$Repo, [string]$Dl, [string]$Out)
Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer; $ser.MaxJsonLength = [int]::MaxValue

function Norm([string]$n){ $n = $n.ToLower() -replace "&#39;|'|\.|,|-"," " -replace '\b(jr|sr|ii|iii|iv|v)\b',''; $k = ($n -replace '\s+',' ').Trim() -replace ' ',''; if($k -eq 'kennethgainwell'){ $k='kennygainwell' }; $k }

$posMap = @{1='QB';2='RB';3='WR';4='TE';5='K';16='DST'}
$teams = @{}; ([IO.File]::ReadAllText("$Dl\espn_teams.json") | ConvertFrom-Json).settings.proTeams | % { $a=$_.abbrev.ToUpper(); if($a -eq 'WSH'){$a='WAS'}; $teams[[int]$_.id] = @{abbrev=$a; bye=[int]$_.byeWeek} }

$espn = @{}
foreach($q in ([IO.File]::ReadAllText("$Dl\espn.json") | ConvertFrom-Json).players){
  $pl = $q.player; $pos = $posMap[[int]$pl.defaultPositionId]; if(-not $pos){ continue }
  $ros = $pl.stats | ? { $_.statSourceId -eq 1 -and $_.statSplitTypeId -eq 0 -and $_.seasonId -eq 2026 } | Select -First 1
  $act = $pl.stats | ? { $_.statSourceId -eq 0 -and $_.statSplitTypeId -eq 0 -and $_.seasonId -eq 2026 } | Select -First 1
  $wk  = @($pl.stats | ? { $_.statSourceId -eq 0 -and $_.statSplitTypeId -eq 1 -and $_.seasonId -eq 2026 })
  $gp = 0; if($act -and $act.appliedAverage -gt 0){ $gp = [math]::Round($act.appliedTotal / $act.appliedAverage) }
  $rec = [ordered]@{
    name=$pl.fullName; pos=$pos; team=$teams[[int]$pl.proTeamId].abbrev; bye=$teams[[int]$pl.proTeamId].bye
    inj=$pl.injuryStatus; espnAdp=$pl.ownership.averageDraftPosition; own=$pl.ownership.percentOwned
    rosTotal=$(if($ros){$ros.appliedTotal}else{$null}); rosAvg=$(if($ros){$ros.appliedAverage}else{$null})
    actTotal=$(if($act){$act.appliedTotal}else{0}); gp=$gp
  }
  $key = (Norm $pl.fullName) + '|' + $pos; if($pos -eq 'DST'){ $key = $rec.team + '|DST' }
  $espn[$key] = $rec
}

$slp = $ser.DeserializeObject([IO.File]::ReadAllText("$Dl\sl_players.json"))
$slpProj = $ser.DeserializeObject([IO.File]::ReadAllText("$Dl\sl_proj.json"))
$slpStat = $ser.DeserializeObject([IO.File]::ReadAllText("$Dl\sl_stats.json"))
$sleeper = @{}
foreach($id in $slp.Keys){
  $s = $slp[$id]; $pos = $s['position']; if($pos -notin 'QB','RB','WR','TE','K','DEF'){ continue }
  if($pos -eq 'DEF'){ $pos='DST' }
  $pr = $slpProj[$id]; $stt = $slpStat[$id]
  $adp = if($pr -and $pr.ContainsKey('adp_ppr')){ [double]$pr['adp_ppr'] } else { $null }
  $rec = @{ team=$s['team']; inj=$s['injury_status']; status=$s['status']; adp=$adp
            ptsSoFar=$(if($stt -and $stt.ContainsKey('pts_ppr')){[double]$stt['pts_ppr']}else{0}); gp=$(if($stt -and $stt.ContainsKey('gp')){[double]$stt['gp']}else{0}) }
  if($pos -eq 'DST'){ $t = $id; if($t -eq 'WSH'){$t='WAS'}; $sleeper["$t|DST"] = $rec; continue }
  $key = (Norm $s['full_name']) + '|' + $pos
  # prefer the entry with a real ADP if duplicate names exist
  if(-not $sleeper.ContainsKey($key) -or ($adp -and $adp -lt 900)){ $sleeper[$key] = $rec }
}

$ours = Get-Content -Raw "$Repo\data\players.json" | ConvertFrom-Json
$dk = Get-Content -Raw "$Repo\data\dstk.json" | ConvertFrom-Json
$all = @($ours) + @($dk.DST) + @($dk.K)
$result = foreach($p in $all){
  $key = (Norm $p.name) + '|' + $p.position; if($p.position -eq 'DST'){ $key = $p.team + '|DST' }
  [ordered]@{ id=$p.id; name=$p.name; pos=$p.position; ourTeam=$p.team; ourBye=$p.byeWeek; ourAdp=$p.adp.overall; ourTier=$p.tier
              ourPPG=$(if($p.projection){$p.projection.projPPG}else{[math]::Round($p.projSeasonPts/17,2)}); espn=$espn[$key]; sleeper=$sleeper[$key] }
}
$ourKeys = @{}; foreach($p in $all){ $k=(Norm $p.name)+'|'+$p.position; if($p.position -eq 'DST'){$k=$p.team+'|DST'}; $ourKeys[$k]=1 }
$missing = $espn.GetEnumerator() | ? { -not $ourKeys.ContainsKey($_.Key) } | % { $v=$_.Value; $s=$sleeper[$_.Key]; [ordered]@{ key=$_.Key; espn=$v; sleeper=$s } }
@{ matched=@($result); missing=@($missing) } | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 $Out
"matched with espn: " + @($result | ? { $_.espn }).Count + " / " + @($result).Count
"matched with sleeper: " + @($result | ? { $_.sleeper }).Count
"espn players not in our data: " + @($missing).Count
