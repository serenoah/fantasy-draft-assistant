# Builds a test copy of index.html with the candidate data embedded (live fetch disabled), runs it headless, prints results.
param([string]$Repo, [string]$DataDir, [string]$Work, [int]$Slot = 6, [int]$Rounds = 10)
$h = [IO.File]::ReadAllText("$Repo\index.html")
$players = [IO.File]::ReadAllText("$DataDir\players.json").TrimStart([char]0xFEFF)
$dstk = [IO.File]::ReadAllText("$DataDir\dstk.json").TrimStart([char]0xFEFF)
$h = $h.Replace("const GITHUB_RAW_BASE = 'https://raw.githubusercontent.com/serenoah/fantasy-draft-assistant/main/data/';", "const GITHUB_RAW_BASE = 'https://invalid.invalid/';")
$h = $h.Replace("const FALLBACK_DSTK = { DST: [], K: [] };", "const FALLBACK_DSTK = { DST: [], K: [] };`nFALLBACK_PLAYERS.length = 0; FALLBACK_PLAYERS.push(...($players)); (function(d){ FALLBACK_DSTK.DST = d.DST; FALLBACK_DSTK.K = d.K; })($dstk);")
$diag = @"
<script>
(function w(){
  if(typeof ALL_PLAYERS==='undefined' || ALL_PLAYERS.length < 100){ return setTimeout(w, 200); }
  setTimeout(function(){
    var out = { src: DATA_SOURCE, n: ALL_PLAYERS.length, nan: [], top: [], mine: [], errors: [] };
    try {
      ALL_PLAYERS.forEach(function(p){
        var s = scorePlayer(p), b = computeBigBoardScore(p);
        var bad = Object.keys(s).filter(function(k){ return typeof s[k]==='number' && !isFinite(s[k]); });
        if(typeof b==='number' && !isFinite(b)) bad.push('bigBoard');
        if(b && typeof b==='object') Object.keys(b).forEach(function(k){ if(typeof b[k]==='number' && !isFinite(b[k])) bad.push('bb.'+k); });
        if(!isFinite(p.projection.projPPG)) bad.push('projPPG');
        if(bad.length) out.nan.push(p.id+':'+bad.join(','));
      });
      draftState.started = true; draftState.myDraftSlot = $Slot;
      out.top = availablePlayers().map(function(p){ return {p:p, s:scorePlayer(p).score}; })
        .sort(function(a,b){ return b.s-a.s; }).slice(0,15).map(function(x){ return x.s+' '+x.p.name+' '+x.p.position+' adp'+x.p.adp.overall; });
      var total = $Rounds * draftState.leagueSize;
      while(draftState.picks.length < total){
        var avail = availablePlayers();
        if(isMyTurn()){
          var best = avail.map(function(p){ return {p:p, s:scorePlayer(p).score}; }).sort(function(a,b){ return b.s-a.s; })[0];
          out.mine.push('R'+currentRound()+' '+best.p.name+' '+best.p.position+' '+best.p.team+' (score '+best.s+', adp '+best.p.adp.overall+')');
          makePick(best.p.id, true);
        } else {
          var next = avail.filter(function(p){ return p.adp; }).sort(function(a,b){ return a.adp.overall-b.adp.overall; })[0];
          makePick(next.id, false);
        }
      }
      var reason = document.body.innerText.match(/undefined|NaN/g);
      out.uiUndefinedOrNaN = reason ? reason.length : 0;
    } catch(e){ out.errors.push(String(e && e.stack || e)); }
    var d = document.createElement('div'); d.id = 'diagResults'; d.textContent = JSON.stringify(out); document.body.appendChild(d);
  }, 500);
})();
</script>
"@
[IO.File]::WriteAllText("$Work\diag_data.html", $h.Replace('</body>', $diag + '</body>'), (New-Object Text.UTF8Encoding $false))
$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
& $edge --headless=new --disable-gpu --no-sandbox --dump-dom --virtual-time-budget=60000 "file:///$($Work -replace '\\','/')/diag_data.html" 2>$null | Out-File -Encoding utf8 "$Work\dump_data.html"
$mt = [regex]::Match([IO.File]::ReadAllText("$Work\dump_data.html"), 'id="diagResults">([^<]*)')
if(-not $mt.Success){ 'NO RESULTS DIV'; return }
[System.Web.HttpUtility]::HtmlDecode($mt.Groups[1].Value) | ConvertFrom-Json | ConvertTo-Json -Depth 4
