[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Timeout', Justification='Used inside Invoke-ClaudeAnalysis')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MaxFiles', Justification='Used inside Collect-SourceFiles')]
param(
    [Parameter(Mandatory=$true)]
    [string]$Source,

    [int]$Timeout = 180,
    [int]$MaxFiles = 20,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$SKILL_DIR   = Split-Path -Parent $MyInvocation.MyCommand.Path
$CARDS_DIR   = Join-Path $SKILL_DIR "cards"
$INDEX_FILE  = Join-Path $SKILL_DIR "index.json"
$TEMP_DIR    = Join-Path $env:TEMP "technique-radar"

# Tunable constants
$MAX_FILE_CHARS   = 8000   # Max chars per file before truncation
$MAX_TOTAL_CHARS  = 60000  # Max total material chars
$MIN_CARD_LENGTH  = 100    # Min chars for a valid card fragment

# Import shared utilities
. (Join-Path $SKILL_DIR "lib-json.ps1")
. (Join-Path $SKILL_DIR "lib-claude.ps1")
$StartedAt   = Get-Date -Format "o"

# Ensure directories exist
foreach ($sub in @("github","local","skill")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $CARDS_DIR $sub) | Out-Null
}
New-Item -ItemType Directory -Force -Path $TEMP_DIR | Out-Null

# ── Helper: Generate unique card ID ──────────────────────────────────
function New-CardId {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $date = Get-Date -Format "yyyyMMdd"
    $rand = -join ((48..57) + (97..102) | Get-Random -Count 6 | ForEach-Object {[char]$_})
    return "tc-$date-$rand"
}

# ── Helper: Compute source hash for dedup ────────────────────────────
function Get-ShortHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory=$true)][string]$s)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($s.ToLower().Trim('/'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    return $hash.Substring(0, 12)
}

# ── Validate and detect source type ──────────────────────────────────
$validated = Test-SourceInput $Source
if (-not $validated.Valid) {
    Write-Host "[RADAR] ERROR: Invalid source input: $Source"
    exit 1
}
$SourceType = $validated.Type
$SourceName = $validated.Name
$Source = $validated.Sanitized
$SourceMaterial = ""

# Handle skill:* batch mode
$skillName = ""
if ($SourceType -eq "skill") {
    $skillName = $SourceName
    if ($skillName -eq "*") {
        Write-Host "[RADAR] Batch mode: analyzing all skills"
    } else {
        Write-Host "[RADAR] Analyzing skill: $SourceName"
    }
} elseif ($SourceType -eq "github") {
    Write-Host "[RADAR] Analyzing GitHub repo: $SourceName"
} else {
    Write-Host "[RADAR] Analyzing local code: $SourceName"
}

# ── Check if already analyzed (skip if -Force) ──────────────────────
if ((-not $Force) -and -not ($SourceType -eq "skill" -and $skillName -eq "*")) {
    $existingHash = Get-ShortHash $Source
    $existingIndex = Read-JsonArray $INDEX_FILE
    if ($existingIndex.Count -gt 0) {
        $alreadyDone = $existingIndex | Where-Object { $_.source_hash -eq $existingHash }
        if ($alreadyDone) {
            Write-Host "[RADAR] Already analyzed this source. Use -Force to re-analyze."
            Write-Host "[RADAR] Found $($alreadyDone.Count) existing cards."
            exit 0
        }
    }
}

# ── Gather source material ───────────────────────────────────────────

function Get-GitHubMaterial {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory=$true)][string]$repoUrl)
    $cloneDir = Join-Path $TEMP_DIR "repo-$(Get-ShortHash $repoUrl)"
    if (Test-Path $cloneDir) { Remove-Item -Recurse -Force $cloneDir }

    # Shallow clone
    Write-Host "[RADAR] Cloning repo (shallow)..."
    git clone --depth 1 $repoUrl $cloneDir 2>&1 | Out-Null

    if (-not (Test-Path $cloneDir)) {
        Write-Host "[RADAR] Clone failed, trying via GitHub API..."
        # Fallback: download as zip via API
        $apiUrl = $repoUrl -replace "github\.com","api.github.com/repos"
        $zipUrl = "$apiUrl/zipball"
        $zipFile = Join-Path $TEMP_DIR "repo.zip"
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -TimeoutSec 30
            Expand-Archive -Path $zipFile -DestinationPath $cloneDir -Force
        } catch {
            return "ERROR: Could not fetch repository"
        }
    }

    return Collect-SourceFiles $cloneDir
}

function Get-LocalMaterial {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory=$true)][string]$path)
    if (-not (Test-Path $path)) {
        return "ERROR: Path not found: $path"
    }
    return Collect-SourceFiles $path
}

function Get-SkillMaterial {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory=$true)][string]$name)
    # Primary path: OpenClaw skills
    $skillPath = Join-Path "$env:USERPROFILE\.openclaw\skills" $name
    if (-not (Test-Path $skillPath)) {
        # Fallback: Claude Code skills
        $skillPath = Join-Path "$env:USERPROFILE\.claude\skills" $name
        if (-not (Test-Path $skillPath)) {
            return "ERROR: Skill not found: $name (checked .openclaw and .claude)"
        }
    }
    return Collect-SourceFiles $skillPath
}

function Collect-SourceFiles {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory=$true)][string]$rootDir)
    $extensions = @("*.py","*.js","*.ts","*.ps1","*.md","*.json","*.yaml","*.yml","*.toml","*.sh","*.go","*.rs","*.cmd","*.bat")
    $skipDirs = @("node_modules",".git","__pycache__",".venv","dist","build",".next","vendor")
    $material = ""

    # Always include README first
    $readmes = Get-ChildItem -Path $rootDir -Filter "README*" -File -ErrorAction SilentlyContinue
    foreach ($r in $readmes) {
        $content = Get-Content $r.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($content) {
            $material += "`n=== FILE: $($r.Name) ===`n$content`n"
        }
    }

    # Collect key source files (sorted by relevance heuristic)
    $allFiles = @()
    foreach ($ext in $extensions) {
        $found = Get-ChildItem -Path $rootDir -Filter $ext -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $skip = $false
                foreach ($d in $skipDirs) {
                    if ($_.FullName -like "*\$d\*" -or $_.FullName -like "*/$d/*") { $skip = $true; break }
                }
                -not $skip
            }
        $allFiles += $found
    }

    # Prioritize: SKILL.md, main/index/app files, then by size (smaller = more focused)
    $prioritized = $allFiles | Sort-Object {
        $name = $_.Name.ToLower()
        if ($name -eq "skill.md") { 0 }
        elseif ($name -match "^(main|index|app|cli|agent|server)\." ) { 1 }
        elseif ($name -match "^(config|package|pyproject|cargo)\." ) { 2 }
        elseif ($_.Length -lt 5000) { 3 }
        else { 4 }
    } | Select-Object -First $MaxFiles

    foreach ($f in $prioritized) {
        if ($f.Name -match "README") { continue }  # Already added
        $relPath = $f.FullName.Replace($rootDir, "").TrimStart('\','/')
        $content = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($content -and $content.Length -gt 0) {
            # Truncate very large files
            if ($content.Length -gt $MAX_FILE_CHARS) {
                $content = $content.Substring(0, $MAX_FILE_CHARS) + "`n... [TRUNCATED at $MAX_FILE_CHARS chars]"
            }
            $material += "`n=== FILE: $relPath ===`n$content`n"
        }
    }

    # Truncate total material if too large
    if ($material.Length -gt $MAX_TOTAL_CHARS) {
        $material = $material.Substring(0, $MAX_TOTAL_CHARS) + "`n... [TOTAL MATERIAL TRUNCATED]"
    }

    return $material
}

# ── Build analysis prompt ────────────────────────────────────────────

function Build-AnalysisPrompt {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory=$true)][string]$sourceType,
        [Parameter(Mandatory=$true)][string]$sourceName,
        [Parameter(Mandatory=$true)][string]$sourceUrl,
        [Parameter(Mandatory=$true)][string]$material
    )
    $today = Get-Date -Format "yyyy-MM-dd"

    $prompt = @"
You are a senior software architect analyzing source code to extract reusable technique cards.

SOURCE TYPE: $sourceType
SOURCE NAME: $sourceName
SOURCE URL: $sourceUrl
DATE: $today

INSTRUCTIONS:
Analyze the following source material and extract ALL noteworthy techniques, patterns, and architectural decisions. Focus on:

1. **Code patterns** that solve common problems in clever ways
2. **Agent architectures** - how autonomous agents are structured, how they chain tools, handle errors, manage state
3. **Prompt engineering techniques** - effective prompting patterns, structured output formats
4. **Integration patterns** - how different systems/APIs are connected
5. **Error handling and resilience** - retry logic, fallback strategies, graceful degradation
6. **Performance tricks** - caching, batching, async patterns
7. **Security patterns** - input validation, sandboxing, permission models

For EACH technique found, output a card in EXACTLY this format (output multiple cards separated by ===CARD_SEPARATOR===):

---
id: PLACEHOLDER
title: [Concise descriptive title]
source_type: $sourceType
source: $sourceUrl
source_name: $sourceName
tags: [tag1, tag2, tag3, tag4]
problem: [One-line problem statement]
cleverness: [1-10]
reusability: [1-10]
discovered: $today
---

## Problem
[2-3 sentences describing the challenge]

## Technique
[Core insight and approach in 3-5 sentences]

## Code
``````
[Minimal code snippet - ONLY the essential part, 5-30 lines max]
``````

## Why It's Clever
[1-2 sentences on what makes this non-obvious]

## When To Use
[Concrete scenarios, 2-3 bullet points]

## Adaptations
[How to modify for different contexts]

===CARD_SEPARATOR===

QUALITY RULES:
- Extract 3-10 cards per source (more for rich sources, fewer for simple ones)
- Each card must be SELF-CONTAINED - someone reading just the card should understand the technique
- Code snippets must be MINIMAL - strip away everything that's not essential to the technique
- Tags should be specific and searchable (e.g. "async", "retry", "mcp", "agent-loop", "tool-use")
- cleverness 7+ means truly novel; 5-6 means solid engineering; below 5 means standard practice (still worth recording)
- reusability 7+ means applicable across many projects; 5-6 means useful in similar domains

SOURCE MATERIAL:
$material
"@

    return $prompt
}

# ── Execute analysis via Claude CLI (delegated to lib-claude.ps1) ────

function Invoke-ClaudeAnalysis {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$AnalysisPrompt
    )

    Write-Host "[RADAR] Sending to Claude for analysis..."
    return Invoke-ClaudeCli -Prompt $AnalysisPrompt -TimeoutSeconds $Timeout -WorkDir $TEMP_DIR
}

# ── Parse Claude output into individual cards ────────────────────────

function Parse-Cards {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [string]$rawOutput,
        [Parameter(Mandatory=$true)][string]$sourceType
    )
    if (-not $rawOutput) { return @() }

    $cards = @()
    $rawCards = $rawOutput -split "===CARD_SEPARATOR==="

    foreach ($rawCard in $rawCards) {
        $rawCard = $rawCard.Trim()
        if ($rawCard.Length -lt $MIN_CARD_LENGTH) { continue }  # Skip empty/tiny fragments

        # Generate unique ID
        $cardId = New-CardId

        # Replace PLACEHOLDER id with real id
        $cardContent = $rawCard -replace "id: PLACEHOLDER", "id: $cardId"

        # Extract title for index
        $title = ""
        if ($cardContent -match "title:\s*(.+)") { $title = $Matches[1].Trim() }

        # Extract tags
        $tags = @()
        if ($cardContent -match "tags:\s*\[(.+)\]") {
            $tags = $Matches[1] -split "," | ForEach-Object { $_.Trim() }
        }

        # Extract scores
        $cleverness = 5; $reusability = 5
        if ($cardContent -match "cleverness:\s*(\d+)") { $cleverness = [int]$Matches[1] }
        if ($cardContent -match "reusability:\s*(\d+)") { $reusability = [int]$Matches[1] }

        # Extract problem
        $problem = ""
        if ($cardContent -match "problem:\s*(.+)") { $problem = $Matches[1].Trim() }

        # Save card file
        $cardFile = Join-Path (Join-Path $CARDS_DIR $sourceType) "$cardId.md"
        Set-Content -Path $cardFile -Value $cardContent -Encoding UTF8

        $cards += @{
            id          = $cardId
            title       = $title
            tags        = $tags
            cleverness  = $cleverness
            reusability = $reusability
            problem     = $problem
            source_type = $sourceType
            source      = $Source
            source_hash = Get-ShortHash $Source
            file        = $cardFile
            discovered  = (Get-Date -Format "yyyy-MM-dd")
        }

        Write-Host "[RADAR] Card: $title (clever=$cleverness reuse=$reusability)"
    }

    return $cards
}

# ── Update index ─────────────────────────────────────────────────────

function Update-Index {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][array]$newCards)
    $existing = Read-JsonArray $INDEX_FILE
    $index = [System.Collections.ArrayList]@($existing)

    foreach ($card in $newCards) {
        $index.Add($card) | Out-Null
    }

    Write-JsonArray $INDEX_FILE @($index)
    Write-Host "[RADAR] Index updated: $($index.Count) total cards"
}

# ── Main execution ───────────────────────────────────────────────────

$allNewCards = @()

if ($SourceType -eq "skill" -and $skillName -eq "*") {
    # Batch mode: analyze all skills
    $skillsRoot = "$env:USERPROFILE\.openclaw\skills"
    $skillDirs = Get-ChildItem -Path $skillsRoot -Directory -ErrorAction SilentlyContinue

    foreach ($dir in $skillDirs) {
        $sName = $dir.Name
        Write-Host "`n[RADAR] ── Analyzing skill: $sName ──"

        $material = Get-SkillMaterial $sName
        if ($material -match "^ERROR:") {
            Write-Host "[RADAR] $material"
            continue
        }

        $prompt = Build-AnalysisPrompt "skill" $sName "skill:$sName" $material
        $output = Invoke-ClaudeAnalysis $prompt
        $cards = Parse-Cards $output "skill"

        if ($cards.Count -gt 0) {
            $allNewCards += $cards
        }
    }
} else {
    # Single source analysis
    switch ($SourceType) {
        "github" {
            $SourceMaterial = Get-GitHubMaterial $Source
        }
        "local" {
            $SourceMaterial = Get-LocalMaterial $Source
        }
        "skill" {
            $SourceMaterial = Get-SkillMaterial $SourceName
        }
    }

    if ($SourceMaterial -match "^ERROR:") {
        Write-Host "[RADAR] $SourceMaterial"
        exit 1
    }

    $prompt = Build-AnalysisPrompt $SourceType $SourceName $Source $SourceMaterial
    $output = Invoke-ClaudeAnalysis $prompt
    $allNewCards = Parse-Cards $output $SourceType
}

# Update index with all new cards
if ($allNewCards.Count -gt 0) {
    Update-Index $allNewCards
}

# ── Write metadata ───────────────────────────────────────────────────
$Duration = ((Get-Date) - [datetime]$StartedAt).TotalSeconds
$finalStatus = "no-cards"
if ($allNewCards.Count -gt 0) { $finalStatus = "done" }
$metaFinal = @{
    task_name    = "technique-radar-analyze"
    source       = $Source
    source_type  = $SourceType
    cards_created = $allNewCards.Count
    started_at   = $StartedAt
    completed_at = (Get-Date -Format "o")
    duration     = [math]::Round($Duration, 1)
    status       = $finalStatus
} | ConvertTo-Json -Depth 3
Set-Content -Path (Join-Path $SKILL_DIR "latest-meta.json") -Value $metaFinal -Encoding UTF8

Write-Host "`n[RADAR] Complete: $($allNewCards.Count) cards extracted in $([math]::Round($Duration,1))s"
