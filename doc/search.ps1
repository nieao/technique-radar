param(
    [Parameter(Mandatory=$true)]
    [string]$Query,

    [int]$TopN = 10,
    [string]$Tag = "",
    [string]$SourceType = "",
    [int]$MinCleverness = 0,
    [int]$MinReusability = 0,
    [switch]$ShowContent
)

$ErrorActionPreference = "Stop"
$SKILL_DIR  = Split-Path -Parent $MyInvocation.MyCommand.Path
$CARDS_DIR  = Join-Path $SKILL_DIR "cards"
$INDEX_FILE = Join-Path $SKILL_DIR "index.json"

if (-not (Test-Path $INDEX_FILE)) {
    Write-Host "[SEARCH] No index found. Run analyze.ps1 first to build your knowledge base."
    exit 0
}

# ── Load index ────────────────────────────────────────────────────────
$index = @()
try {
    $raw = Get-Content $INDEX_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($raw -is [array]) { $index = $raw } else { $index = @($raw) }
} catch {
    Write-Host "[SEARCH] Error reading index: $($_.Exception.Message)"
    exit 1
}

Write-Host "[SEARCH] Searching $($index.Count) cards for: $Query"

# ── Tokenize query ────────────────────────────────────────────────────
$queryTokens = $Query.ToLower() -split "\s+" | Where-Object { $_.Length -gt 1 }

# ── Score each card ───────────────────────────────────────────────────
$scored = @()

foreach ($card in $index) {
    # Apply filters
    if ($Tag -and ($card.tags -notcontains $Tag)) { continue }
    if ($SourceType -and ($card.source_type -ne $SourceType)) { continue }
    if ($MinCleverness -and ($card.cleverness -lt $MinCleverness)) { continue }
    if ($MinReusability -and ($card.reusability -lt $MinReusability)) { continue }

    # Build searchable text from card metadata
    $searchText = @(
        $card.title,
        $card.problem,
        ($card.tags -join " "),
        $card.source_name,
        $card.source_type
    ) -join " " | ForEach-Object { $_.ToLower() }

    # Also load card content for full-text search if the file exists
    $cardContent = ""
    if ($card.file -and (Test-Path $card.file)) {
        $cardContent = (Get-Content $card.file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue).ToLower()
    }
    $fullText = "$searchText $cardContent"

    # Score: count matching tokens + bonus for title/tag matches
    $score = 0
    $matchedTokens = 0
    foreach ($token in $queryTokens) {
        if ($fullText -match [regex]::Escape($token)) {
            $matchedTokens++

            # Bonus: token appears in title
            if ($card.title -and $card.title.ToLower() -match [regex]::Escape($token)) {
                $score += 3
            }
            # Bonus: token is a tag
            if ($card.tags -contains $token) {
                $score += 2
            }
            # Base score for content match
            $score += 1
        }
    }

    # Must match at least one token
    if ($matchedTokens -eq 0) { continue }

    # Bonus for matching ALL tokens
    if ($matchedTokens -eq $queryTokens.Count) { $score += 5 }

    # Quality bonus
    $score += ($card.cleverness + $card.reusability) * 0.1

    $scored += @{
        card  = $card
        score = $score
        matched = $matchedTokens
    }
}

# ── Sort and display ──────────────────────────────────────────────────
$results = $scored | Sort-Object { -$_.score } | Select-Object -First $TopN

if ($results.Count -eq 0) {
    Write-Host "[SEARCH] No matching cards found."
    Write-Host "[SEARCH] Try broader keywords or check available tags with: search.ps1 -Query '*' -TopN 999"
    exit 0
}

Write-Host "[SEARCH] Found $($scored.Count) matches, showing top $($results.Count):`n"

$rank = 0
foreach ($r in $results) {
    $rank++
    $c = $r.card
    $tagStr = if ($c.tags) { ($c.tags -join ", ") } else { "-" }

    Write-Host "  [$rank] $($c.title)"
    Write-Host "      Score: $([math]::Round($r.score, 1)) | Clever: $($c.cleverness)/10 | Reuse: $($c.reusability)/10"
    Write-Host "      Tags: $tagStr"
    Write-Host "      Problem: $($c.problem)"
    Write-Host "      Source: [$($c.source_type)] $($c.source_name)"

    if ($ShowContent -and $c.file -and (Test-Path $c.file)) {
        Write-Host "      ── Card Content ──"
        $content = Get-Content $c.file -Raw -Encoding UTF8
        # Indent content
        $content -split "`n" | ForEach-Object { Write-Host "      $_" }
        Write-Host "      ── End Card ──"
    }

    Write-Host ""
}

# ── Stats footer ──────────────────────────────────────────────────────
$totalCards = $index.Count
$byType = $index | Group-Object source_type
Write-Host "[SEARCH] Knowledge Base Stats:"
Write-Host "  Total cards: $totalCards"
foreach ($g in $byType) {
    Write-Host "  $($g.Name): $($g.Count) cards"
}

# ── Special: list all tags if query is '*' ────────────────────────────
if ($Query -eq "*") {
    $allTags = @{}
    foreach ($card in $index) {
        if ($card.tags) {
            foreach ($t in $card.tags) {
                if (-not $allTags.ContainsKey($t)) { $allTags[$t] = 0 }
                $allTags[$t]++
            }
        }
    }
    Write-Host "`n[SEARCH] All tags:"
    $allTags.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
        Write-Host "  $($_.Key): $($_.Value) cards"
    }
}
