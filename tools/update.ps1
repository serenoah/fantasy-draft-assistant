# In-season refresh of players.json / dstk.json from ESPN + Sleeper public API data (merged.json from merge.ps1).
param([string]$Repo, [string]$Merged, [string]$TeamsFile, [string]$OutDir, [string]$AsOf = '2026-10-07')
$CUR_WEEK = 5; $LAST_WEEK = 18   # ESPN season projections run through NFL week 18

$m = Get-Content -Raw $Merged | ConvertFrom-Json
$byId = @{}; $m.matched | % { $byId[$_.id] = $_ }
$byes = @{}; ([IO.File]::ReadAllText($TeamsFile) | ConvertFrom-Json).settings.proTeams | % { $a=$_.abbrev.ToUpper(); if($a -eq 'WSH'){$a='WAS'}; $byes[$a] = [int]$_.byeWeek }

function RemGames($team){ $n = $LAST_WEEK - $CUR_WEEK + 1; $b = $byes[$team]; if($b -ge $CUR_WEEK -and $b -le $LAST_WEEK){ $n-- }; $n }
function InjLabel($e, $s){
  $st = if($e){ $e.inj } else { $null }
  if($s -and $s.inj -in 'IR','Out','PUP','DNR','Sus'){ if($st -notin 'INJURY_RESERVE','OUT'){ $st = $s.inj.ToUpper() } }
  if(-not $st){ 'ACTIVE' } else { $st }
}
function RiskFromInj($inj, $old){
  if($inj -in 'INJURY_RESERVE','OUT','IR','PUP','DNR','SUS','DOUBTFUL'){ return 'high' }
  if($inj -in 'QUESTIONABLE','DAY_TO_DAY'){ if($old -eq 'high'){ return 'high' }; return 'medium' }
  return $old
}
function PrettyInj($inj){ switch($inj){ 'INJURY_RESERVE'{'on injured reserve'} 'OUT'{'listed OUT'} 'DOUBTFUL'{'listed doubtful'} 'QUESTIONABLE'{'listed questionable'} 'DAY_TO_DAY'{'day-to-day'} 'PUP'{'on PUP'} 'DNR'{'not reporting/inactive'} default{"listed $inj"} } }

# Returns @{ppg; avail; act; gp; rosAvg; rosTotal} or $null
function InSeason($mm, $team){
  $e = $mm.espn; if(-not $e){ return $null }
  $gp = [int]$e.gp; $act = if($gp -gt 0){ [double]$e.actTotal / $gp } else { $null }
  if($e.rosAvg -and [double]$e.rosAvg -gt 0){
    $rosAvg = [double]$e.rosAvg; $projGames = [double]$e.rosTotal / $rosAvg
    $avail = [math]::Min(1.0, $projGames / (RemGames $team))
    $w = $gp / ($gp + 12.0)
    $healthy = if($act -ne $null){ (1-$w)*$rosAvg + $w*$act } else { $rosAvg }
    $ppg = [math]::Round($healthy * $avail, 1)
  } else { $rosAvg = 0; $avail = 0; $ppg = 0.5 }   # no ESPN ROS projection = not expected to play
  if($ppg -lt 0.5){ $ppg = 0.5 }
  @{ ppg=$ppg; avail=[math]::Round($avail,2); act=$act; gp=$gp; rosAvg=$rosAvg; rosTotal=[double]$e.rosTotal }
}
function PreseasonAdp($mm, $old){
  $vals = @(); if($mm.espn -and $mm.espn.espnAdp -gt 0){ $vals += [double]$mm.espn.espnAdp }
  if($mm.sleeper -and $mm.sleeper.adp -and [double]$mm.sleeper.adp -lt 500){ $vals += [double]$mm.sleeper.adp }
  if($vals.Count -eq 0){ return [double]$old }; ($vals | Measure-Object -Average).Average
}

# Within each position: ADP = avg(real draft ADP, the draft-ADP slot matching the player's current ROS position rank)
# Tier = original per-position tier counts reassigned in current-projection order.
function Rerank($list, $valueOf){
  foreach($grp in ($list | Group-Object position)){
    $g = @($grp.Group)
    $adps = @($g | % { $_.adp._pre } | Sort-Object)
    $tiers = @($g | % { $_.tier } | Sort-Object)
    $byVal = @($g | Sort-Object { -(& $valueOf $_) }, { $_.adp._pre })
    for($i=0; $i -lt $byVal.Count; $i++){
      $p = $byVal[$i]
      $p.adp.overall = [math]::Round(($p.adp._pre + $adps[$i]) / 2, 1)
      $p.tier = $tiers[$i]
    }
    $r = 1; foreach($p in ($g | Sort-Object { $_.adp.overall })){ $p.adp.positionRank = $r; $r++ }
  }
}

$log = New-Object System.Collections.Generic.List[string]
$players = Get-Content -Raw "$Repo\data\players.json" | ConvertFrom-Json
foreach($p in $players){
  $mm = $byId[$p.id]; $e = $mm.espn; $s = $mm.sleeper
  $oldTeam = $p.team
  $newTeam = if($s -and $s.team){ $s.team } elseif($e){ $e.team } elseif($s){ 'FA' } else { $p.team }
  if($newTeam -eq 'WSH'){ $newTeam = 'WAS' }
  if($newTeam -ne $oldTeam){
    $p.team = $newTeam; if($byes.ContainsKey($newTeam) -and $byes[$newTeam] -gt 0){ $p.byeWeek = $byes[$newTeam] }
    $p.newsLog = @($p.newsLog) + @([ordered]@{ date=$AsOf; headline="Team changed $oldTeam -> $newTeam"; source='Sleeper/ESPN rosters' })
    $log.Add("TEAM $($p.name): $oldTeam -> $newTeam")
  }
  $inj = InjLabel $e $s
  $is = InSeason $mm $p.team
  $oldPPG = [double]$p.projection.projPPG
  if($is){ $newPPG = $is.ppg } elseif(-not $e -and (-not $s -or -not $s.team)){ $newPPG = 0.5; $inj = 'NOT_ON_ROSTER' } else { $newPPG = [math]::Min($oldPPG, 2.0) }  # outside ESPN's top-450 rostered pool
  $ratio = if($oldPPG -gt 0){ $newPPG / $oldPPG } else { 1 }
  $p.projection.projPPG = $newPPG
  $p.projection.projSeasonPts = [math]::Round($newPPG * 17, 1)
  $p.projection.projFloor = [math]::Round([double]$p.projection.projFloor * $ratio, 1)
  $p.projection.projCeiling = [math]::Round([double]$p.projection.projCeiling * $ratio, 1)
  $p.projection.methodologyNote = "In-season refresh $($AsOf): ESPN rest-of-season per-game projection blended with actual 2026 PPR PPG (actual weight = games/(games+12)), scaled by ESPN's projected availability over the remaining schedule."
  $p.risk.injuryRisk = RiskFromInj $inj $p.risk.injuryRisk
  if($inj -eq 'NOT_ON_ROSTER'){ $p.risk.injuryRisk = 'high' }
  # Preseason injury concern that is now playing healthy every week: soften to medium.
  if($inj -eq 'ACTIVE' -and $is -and $is.gp -ge 3 -and $p.risk.injuryRisk -eq 'high'){ $p.risk.injuryRisk = 'medium'; $log.Add("RISK $($p.name): high -> medium (active, $($is.gp) games played)") }

  $p.adp | Add-Member -NotePropertyName preseasonAug -NotePropertyValue $p.adp.overall -Force
  $p.adp | Add-Member -NotePropertyName _pre -NotePropertyValue ([math]::Round((PreseasonAdp $mm $p.adp.overall),1)) -Force
  $p.adp.source = 'espn+sleeper-ppr-adp blended with rest-of-season position rank'
  $p.adp.asOf = $AsOf

  # Factual in-season blurb; keep the August text for reference.
  $act = if($is -and $is.act -ne $null){ "{0:N1} PPR PPG over {1} game{2} in 2026" -f $is.act,$is.gp,$(if($is.gp -eq 1){''}else{'s'}) } else { 'Has not played in 2026' }
  $ros = if($is -and $is.rosAvg -gt 0){ "ESPN projects {0:N1} PPG rest of season" -f $is.rosAvg } else { 'ESPN has no rest-of-season projection for him' }
  $injTxt = if($inj -eq 'NOT_ON_ROSTER'){ ' Not currently on an NFL roster.' } elseif($inj -ne 'ACTIVE'){ " Currently $(PrettyInj $inj) (as of $AsOf)." } else { '' }
  $teamTxt = if($newTeam -ne $oldTeam){ " Now with $newTeam (previously $oldTeam)." } else { '' }
  $p.blurb | Add-Member -NotePropertyName preseasonSummary -NotePropertyValue $p.blurb.summary -Force
  $p.blurb | Add-Member -NotePropertyName preseasonRiskReason -NotePropertyValue $p.blurb.riskReason -Force
  $p.blurb.summary = "$($p.name) ($($p.team)): $act; $ros.$injTxt$teamTxt"
  $p.blurb.riskReason = if($inj -ne 'ACTIVE'){ "$($p.name) is $(PrettyInj $inj) as of $AsOf (ESPN/Sleeper injury reports)." } else { $null }
  $p.situation.competitionNotes = "$($p.blurb.summary) Preseason note: $($p.situation.competitionNotes)"
  $p | Add-Member -NotePropertyName inSeason2026 -NotePropertyValue ([ordered]@{
    asOf=$AsOf; gamesPlayed=$(if($is){$is.gp}else{0}); pprPPG=$(if($is -and $is.act -ne $null){[math]::Round($is.act,2)}else{$null})
    espnRosPPG=$(if($is){[math]::Round($is.rosAvg,2)}else{$null}); espnRosTotal=$(if($is){[math]::Round($is.rosTotal,1)}else{$null})
    availability=$(if($is){$is.avail}else{$null}); injuryStatus=$inj; source='ESPN fantasy API (PPR) + Sleeper API'
  }) -Force
  $p.meta.lastUpdated = $AsOf
  if([math]::Abs($newPPG - $oldPPG) -ge 3){ $log.Add(("PPG {0}: {1} -> {2} ({3})" -f $p.name,$oldPPG,$newPPG,$inj)) }
}
# Add widely-rostered (>=40% on ESPN) skill players missing from our pool, built from real API data only.
$added = @()
foreach($x in ($m.missing | ? { $_.espn.pos -in 'QB','RB','WR','TE' -and [double]$_.espn.own -ge 40 -and [double]$_.espn.rosAvg -gt 0 })){
  $e = $x.espn; $s = $x.sleeper
  $team = if($s -and $s.team){ $s.team } else { $e.team }; if($team -eq 'WSH'){ $team='WAS' }
  $is = InSeason ([pscustomobject]@{ espn=$e; sleeper=$s }) $team
  $inj = InjLabel $e $s
  $slug = (($e.name.ToLower() -replace "[^a-z0-9 ]",'' -replace '\s+','-').Trim('-')) + "-$($team.ToLower())-$($e.pos.ToLower())"
  $pre = PreseasonAdp ([pscustomobject]@{ espn=$e; sleeper=$s }) 170
  $act = if($is.act -ne $null){ "{0:N1} PPR PPG over {1} games in 2026" -f $is.act,$is.gp } else { 'Has not played in 2026' }
  $ros = if($is.rosAvg -gt 0){ "ESPN projects {0:N1} PPG rest of season" -f $is.rosAvg } else { 'ESPN has no rest-of-season projection for him' }
  $injTxt = if($inj -ne 'ACTIVE'){ " Currently $(PrettyInj $inj) (as of $AsOf)." } else { '' }
  $summary = "$($e.name) ($team): $act; $ros.$injTxt"
  $added += [pscustomobject][ordered]@{
    id=$slug; name=$e.name; team=$team; position=$e.pos; byeWeek=$byes[$team]
    adp=[pscustomobject][ordered]@{ overall=[math]::Round($pre,1); positionRank=0; source='espn+sleeper-ppr-adp blended with rest-of-season position rank'; asOf=$AsOf; preseasonAug=$null; _pre=[math]::Round($pre,1) }
    prevSeason=[pscustomobject][ordered]@{ gamesPlayed=0; pprPts=0; pprPtsPerGame=0 }
    anomalyAdjusted=[pscustomobject][ordered]@{ adjustedPPG=$is.ppg; adjustments=@(); confidence='medium' }
    projection=[pscustomobject][ordered]@{ projPPG=$is.ppg; projSeasonPts=[math]::Round($is.ppg*17,1); projFloor=[math]::Round($is.ppg*0.7,1); projCeiling=[math]::Round($is.ppg*1.3,1); projGamesPlayed=17
      methodologyNote="Added $($AsOf) from ESPN/Sleeper data: ESPN rest-of-season per-game projection blended with actual 2026 PPR PPG (actual weight = games/(games+12)), scaled by projected availability." }
    schedule=[pscustomobject][ordered]@{ seasonSosGrade='C'; playoffSosGrade='C'; notes='' }
    situation=[pscustomobject][ordered]@{ depthChartRole=''; targetShareTrend='n/a'; oLineGrade=''; coachingSchemeChange=$null; competitionNotes=$summary }
    risk=[pscustomobject][ordered]@{ injuryRisk=(RiskFromInj $inj 'low'); durabilityHistory=''; ageFlag=$false; contractYear=$false; otherFlags=@() }
    tier=8
    blurb=[pscustomobject][ordered]@{ summary=$summary; sleeperReason=$null; riskReason=$(if($inj -ne 'ACTIVE'){"$($e.name) is $(PrettyInj $inj) as of $AsOf (ESPN/Sleeper injury reports)."}else{$null}) }
    newsLog=@([ordered]@{ date=$AsOf; headline='Added in in-season data refresh'; source='ESPN/Sleeper' })
    inSeason2026=[ordered]@{ asOf=$AsOf; gamesPlayed=$is.gp; pprPPG=$(if($is.act -ne $null){[math]::Round($is.act,2)}else{$null}); espnRosPPG=[math]::Round($is.rosAvg,2); espnRosTotal=[math]::Round($is.rosTotal,1); availability=$is.avail; injuryStatus=$inj; source='ESPN fantasy API (PPR) + Sleeper API' }
    meta=[pscustomobject][ordered]@{ lastUpdated=$AsOf; dataConfidence='medium' }
  }
  $log.Add(("ADD {0} {1} {2}: {3} PPG" -f $e.name,$e.pos,$team,$is.ppg))
}
# New players take the lowest existing tier at their position until Rerank redistributes tiers.
foreach($a in $added){ $a.tier = ($players | ? { $_.position -eq $a.position } | Measure-Object tier -Maximum).Maximum }
$players = @($players) + $added
Rerank $players { param($x) $x.projection.projPPG }

# DST / K
$dk = Get-Content -Raw "$Repo\data\dstk.json" | ConvertFrom-Json
foreach($p in @($dk.DST) + @($dk.K)){
  $mm = $byId[$p.id]; $s = $mm.sleeper
  if($p.position -eq 'K' -and $s -and $s.team -and $s.team -ne $p.team){ $log.Add("TEAM $($p.name): $($p.team) -> $($s.team)"); $p.team = $s.team; if($byes[$s.team]){ $p.byeWeek = $byes[$s.team] } }
  $is = InSeason $mm $p.team
  $old = [double]$p.projSeasonPts
  if($is){ $p.projSeasonPts = [math]::Round($is.ppg * 17) } elseif(-not ($s -and $s.team)){ $p.projSeasonPts = 8 }
  $p.adp | Add-Member -NotePropertyName preseasonAug -NotePropertyValue $p.adp.overall -Force
  $p.adp | Add-Member -NotePropertyName _pre -NotePropertyValue ([math]::Round((PreseasonAdp $mm $p.adp.overall),1)) -Force
  $act = if($is -and $is.act -ne $null){ "{0:N1} pts/game through {1} games in 2026; " -f $is.act,$is.gp } else { '' }
  $p.notes = "$($act)ESPN rest-of-season projection {0:N1} pts/game (as of $AsOf). Preseason: $($p.notes)" -f $(if($is){$is.rosAvg}else{0})
  $p.meta.lastUpdated = $AsOf
}
Rerank (@($dk.DST) + @($dk.K)) { param($x) $x.projSeasonPts }

foreach($p in @($players) + @($dk.DST) + @($dk.K)){ $p.adp.PSObject.Properties.Remove('_pre') }
$enc = New-Object System.Text.UTF8Encoding $true
[IO.File]::WriteAllText("$OutDir\players.json", (ConvertTo-Json @($players) -Depth 12), $enc)
[IO.File]::WriteAllText("$OutDir\dstk.json", ($dk | ConvertTo-Json -Depth 12), $enc)
$log | Set-Content -Encoding utf8 "$OutDir\changes.log"
"wrote $(@($players).Count) players, $(@($dk.DST).Count) DST, $(@($dk.K).Count) K; $($log.Count) notable changes"
