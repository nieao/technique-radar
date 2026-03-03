param(
    [string]$Topics = "ai-agent,mcp-server,tool-use,autonomous-agent,llm-agent,claude,browser-use",
    [int]$Since = 7,
    [int]$MinStars = 10,
    [int]$Timeout = 120,
    [int]$MaxPerTopic = 10
)

$ErrorActionPreference = "Stop"
$SKILL_DIR      = Split-Path -Parent $MyInvocation.MyCommand.Path
$CANDIDATES_FILE = Join-Path $SKILL_DIR "candidates.json"
$INDEX_FILE     = Join-Path $SKILL_DIR "index.json"
$TEMP_DIR       = Join-Path $env:TEMP "technique-radar"
$StartedAt      = Get-Date -Format "o"

# Import shared utilities
. (Join-Path $SKILL_DIR "lib-json.ps1")
. (Join-Path $SKILL_DIR "lib-claude.ps1")

New-Item -ItemType Directory -Force -Path $TEMP_DIR | Out-Null

Write-Host "[DISCOVER] Starting repo discovery..."
Write-Host "[DISCOVER] Topics: $Topics"
Write-Host "[DISCOVER] Since: $Since days, MinStars: $MinStars"

# ── Load existing candidates and analyzed sources ─────────────────────
$existingCandidates = Read-JsonArray $CANDIDATES_FILE

$analyzedUrls = @{}
$idx = Read-JsonArray $INDEX_FILE
foreach ($entry in $idx) {
    if ($entry.source) { $analyzedUrls[$entry.source] = $true }
}
$existingUrls = @{}
foreach ($c in $existingCandidates) {
    if ($c.url) { $existingUrls[$c.url] = $true }
}

# ── GitHub API search ─────────────────────────────────────────────────
$sinceDate = (Get-Date).AddDays(-$Since).ToString("yyyy-MM-dd")
$topicList = $Topics -split ","
$newCandidates = @()

foreach ($topic in $topicList) {
    $topic = $topic.Trim()
    Write-Host "[DISCOVER] Searching topic: $topic"

    # GitHub search API - repos created/pushed since date with topic
    $searchQuery = "topic:$topic pushed:>=$sinceDate stars:>=$MinStars"
    $encodedQuery = [System.Uri]::EscapeDataString($searchQuery)
    $apiUrl = "https://api.github.com/search/repositories?q=$encodedQuery&sort=stars&order=desc&per_page=$MaxPerTopic"

    try {
        $headers = @{ "Accept" = "application/vnd.github.v3+json"; "User-Agent" = "technique-radar/1.0" }

        # Use GitHub token if available
        $ghToken = $env:GITHUB_TOKEN
        if (-not $ghToken) {
            # Try gh CLI auth
            try {
                $ghToken = (gh auth token 2>$null)
            } catch { Write-Verbose "[DISCOVER] gh auth token not available" }
        }
        if ($ghToken) {
            $headers["Authorization"] = "Bearer $ghToken"
        }

        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 30
        $repos = $response.items

        foreach ($repo in $repos) {
            $repoUrl = $repo.html_url

            # Skip if already known
            if ($existingUrls.ContainsKey($repoUrl) -or $analyzedUrls.ContainsKey($repoUrl)) {
                continue
            }

            # Safe description extraction (PS5.1 compatible, null-safe)
            $desc = ""
            if ($repo.description -and $repo.description.Length -gt 0) {
                $maxLen = [Math]::Min(200, $repo.description.Length)
                $desc = $repo.description.Substring(0, $maxLen)
            }

            $candidate = @{
                url              = $repoUrl
                name             = $repo.full_name
                description      = $desc
                stars            = $repo.stargazers_count
                language         = $repo.language
                topics           = $repo.topics
                pushed_at        = $repo.pushed_at
                discovered       = (Get-Date -Format "yyyy-MM-dd")
                status           = "pending"  # pending | analyzing | done | skipped
                match_topic      = $topic
                relevance_score  = 5          # default; overwritten by Claude scoring
                relevance_reason = ""
            }

            $newCandidates += $candidate
            $existingUrls[$repoUrl] = $true

            Write-Host "  [NEW] $($repo.full_name) ($($repo.stargazers_count) stars) - $($repo.description)"
        }

        # Rate limit: sleep between API calls
        Start-Sleep -Milliseconds 1000

    } catch {
        $errMsg = $_.Exception.Message
        Write-Host "[DISCOVER] API error for topic '$topic': $errMsg"
        # Back off on rate limit (403/429)
        if ($errMsg -match "403|429|rate limit") {
            Write-Host "[DISCOVER] Rate limited, waiting 30s before next topic..."
            Start-Sleep -Seconds 30
        }
        continue
    }
}

# ── AI-based relevance pre-scoring ────────────────────────────────────
# Use Claude to quickly score each candidate's relevance before full analysis

if ($newCandidates.Count -gt 0) {
    Write-Host "`n[DISCOVER] Pre-scoring $($newCandidates.Count) new candidates with Claude..."

    $candidateList = ""
    $idx = 0
    foreach ($c in $newCandidates) {
        $idx++
        $candidateList += "$idx. [$($c.name)] stars=$($c.stars) lang=$($c.language) topics=$($c.topics -join ',') desc: $($c.description)`n"
    }

    $scoringPrompt = @"
You are evaluating GitHub repositories for a developer who focuses on:
- AI agent architectures and autonomous systems
- MCP (Model Context Protocol) servers and tool integration
- Automation patterns and code techniques
- Claude Code, OpenAI Codex, and LLM-powered development tools
- Windows PowerShell automation

Rate each repository 1-10 for how likely it contains NOVEL, REUSABLE techniques worth studying.
10 = groundbreaking agent architecture or novel pattern
7-9 = solid engineering with clear reusable techniques
4-6 = standard implementation, might have some useful bits
1-3 = too simple, too niche, or irrelevant

Output ONLY a JSON array like: [{"idx":1,"score":7,"reason":"Novel agent loop pattern"},...]

REPOSITORIES:
$candidateList
"@

    $scoreOutput = Invoke-ClaudeCli -Prompt $scoringPrompt -TimeoutSeconds $Timeout -WorkDir $TEMP_DIR

    if ($scoreOutput -and $scoreOutput -match '\[[\s\S]*\]') {
        try {
            $scores = $Matches[0] | ConvertFrom-Json
            foreach ($s in $scores) {
                $i = $s.idx - 1
                if ($i -ge 0 -and $i -lt $newCandidates.Count) {
                    $newCandidates[$i].relevance_score = $s.score
                    $newCandidates[$i].relevance_reason = $s.reason
                    if ($s.score -lt 4) {
                        $newCandidates[$i].status = "skipped"
                    }
                }
            }
        } catch {
            Write-Host "[DISCOVER] Could not parse scoring output"
        }
    } elseif (-not $scoreOutput) {
        Write-Host "[DISCOVER] Scoring timed out or failed"
    }
}

# ── Merge and save candidates ─────────────────────────────────────────
$allCandidates = $existingCandidates + $newCandidates

# Sort: pending first, then by relevance score descending
$allCandidates = $allCandidates | Sort-Object @(
    @{ Expression = { if ($_.status -eq "pending") { 0 } else { 1 } }; Ascending = $true },
    @{ Expression = { $_.relevance_score }; Descending = $true }
)

Write-JsonArray $CANDIDATES_FILE $allCandidates

# ── Summary ───────────────────────────────────────────────────────────
$pendingCount = ($allCandidates | Where-Object { $_.status -eq "pending" }).Count
$highValue = ($newCandidates | Where-Object { $_.relevance_score -ge 7 })

Write-Host "`n[DISCOVER] ── Summary ──"
Write-Host "[DISCOVER] New repos found: $($newCandidates.Count)"
Write-Host "[DISCOVER] High-value (score >= 7): $($highValue.Count)"
Write-Host "[DISCOVER] Total pending analysis: $pendingCount"

if ($highValue.Count -gt 0) {
    Write-Host "`n[DISCOVER] Top candidates to analyze:"
    foreach ($hv in ($highValue | Sort-Object { -$_.relevance_score } | Select-Object -First 5)) {
        Write-Host "  [$($hv.relevance_score)/10] $($hv.name) - $($hv.relevance_reason)"
    }
}

# ── Metadata ──────────────────────────────────────────────────────────
$Duration = ((Get-Date) - [datetime]$StartedAt).TotalSeconds
$metaFinal = @{
    task_name     = "technique-radar-discover"
    topics        = $topicList
    new_found     = $newCandidates.Count
    high_value    = $highValue.Count
    total_pending = $pendingCount
    started_at    = $StartedAt
    completed_at  = (Get-Date -Format "o")
    duration      = [math]::Round($Duration, 1)
    status        = "done"
} | ConvertTo-Json -Depth 3
Set-Content -Path (Join-Path $SKILL_DIR "latest-meta.json") -Value $metaFinal -Encoding UTF8

Write-Host "[DISCOVER] Done in $([math]::Round($Duration,1))s"
