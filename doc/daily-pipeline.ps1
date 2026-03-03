param(
    [int]$MaxAnalyze = 3,       # Max repos to deep-analyze per run
    [int]$MinScore = 6,         # Minimum relevance score to auto-analyze
    [switch]$DiscoverOnly,      # Only discover, skip analysis
    [switch]$AnalyzeOnly        # Only analyze pending, skip discovery
)

$ErrorActionPreference = "Stop"
$SKILL_DIR       = Split-Path -Parent $MyInvocation.MyCommand.Path
$CANDIDATES_FILE = Join-Path $SKILL_DIR "candidates.json"
$StartedAt       = Get-Date -Format "o"

Write-Host "============================================"
Write-Host "  TECHNIQUE RADAR - Daily Pipeline"
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Host "============================================"

# ── Phase 1: Discovery ───────────────────────────────────────────────
if (-not $AnalyzeOnly) {
    Write-Host "`n[PHASE 1] Discovering new repositories..."
    & (Join-Path $SKILL_DIR "discover.ps1") -Topics "ai-agent,mcp-server,tool-use,autonomous-agent,llm-agent,claude,browser-use,agentic" -Since 3 -MinStars 5
}

# ── Phase 2: Auto-analyze top candidates ─────────────────────────────
if (-not $DiscoverOnly) {
    Write-Host "`n[PHASE 2] Analyzing top candidates..."

    if (-not (Test-Path $CANDIDATES_FILE)) {
        Write-Host "[PIPELINE] No candidates file found. Run discovery first."
    } else {
        $candidates = @()
        try {
            $raw = Get-Content $CANDIDATES_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($raw -is [array]) { $candidates = $raw }
            elseif ($raw) { $candidates = @($raw) }
        } catch {
            Write-Host "[PIPELINE] WARN: Could not parse candidates.json"
        }

        # Filter: pending + high enough score
        $toAnalyze = $candidates |
            Where-Object { $_.status -eq "pending" -and $_.relevance_score -ge $MinScore } |
            Sort-Object { -$_.relevance_score } |
            Select-Object -First $MaxAnalyze

        if ($toAnalyze.Count -eq 0) {
            Write-Host "[PIPELINE] No candidates meet analysis threshold (score >= $MinScore)"
        } else {
            $analyzed = 0
            foreach ($candidate in $toAnalyze) {
                Write-Host "`n[PIPELINE] Analyzing: $($candidate.name) (score: $($candidate.relevance_score))"

                # Mark as analyzing
                $candidate.status = "analyzing"
                @($candidates) | ConvertTo-Json -Depth 5 | Set-Content -Path $CANDIDATES_FILE -Encoding UTF8

                try {
                    & (Join-Path $SKILL_DIR "analyze.ps1") -Source $candidate.url -Timeout 180

                    # Mark as done
                    $candidate.status = "done"
                    $candidate.analyzed_at = (Get-Date -Format "o")
                    $analyzed++
                } catch {
                    Write-Host "[PIPELINE] Analysis failed: $($_.Exception.Message)"
                    $candidate.status = "failed"
                    $candidate.error = $_.Exception.Message
                }

                # Save updated status
                @($candidates) | ConvertTo-Json -Depth 5 | Set-Content -Path $CANDIDATES_FILE -Encoding UTF8
            }

            Write-Host "`n[PIPELINE] Analyzed $analyzed/$($toAnalyze.Count) repos"
        }
    }
}

# ── Phase 3: Summary report ──────────────────────────────────────────
Write-Host "`n[PHASE 3] Generating summary..."

$indexFile = Join-Path $SKILL_DIR "index.json"
$totalCards = 0
$todayCards = 0
$today = Get-Date -Format "yyyy-MM-dd"

if (Test-Path $indexFile) {
    try {
        $idx = Get-Content $indexFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($idx -and $idx -isnot [array]) { $idx = @($idx) }
        if ($idx) {
            $totalCards = $idx.Count
            $todayCards = ($idx | Where-Object { $_.discovered -eq $today }).Count
        }
    } catch {
        Write-Host "[PIPELINE] WARN: Could not parse index.json"
    }
}

$Duration = ((Get-Date) - [datetime]$StartedAt).TotalSeconds

Write-Host "`n============================================"
Write-Host "  DAILY RADAR REPORT"
Write-Host "  New cards today: $todayCards"
Write-Host "  Total knowledge base: $totalCards cards"
Write-Host "  Duration: $([math]::Round($Duration,1))s"
Write-Host "============================================"

# ── Metadata ──────────────────────────────────────────────────────────
$metaFinal = @{
    task_name     = "technique-radar-daily"
    new_cards     = $todayCards
    total_cards   = $totalCards
    started_at    = $StartedAt
    completed_at  = (Get-Date -Format "o")
    duration      = [math]::Round($Duration, 1)
    status        = "done"
} | ConvertTo-Json -Depth 3
Set-Content -Path (Join-Path $SKILL_DIR "latest-meta.json") -Value $metaFinal -Encoding UTF8

# ── Optional: Telegram notification ───────────────────────────────────
$OPENCLAW_BIN = "$env:USERPROFILE\AppData\Roaming\npm\openclaw.cmd"
if (Test-Path $OPENCLAW_BIN) {
    $msg = "[RADAR] Daily scan done. +$todayCards cards (total: $totalCards). Duration: $([math]::Round($Duration,1))s"
    try {
        & cmd.exe /c "`"$OPENCLAW_BIN`" message send --channel telegram --message `"$msg`"" 2>$null
    } catch {}
}
