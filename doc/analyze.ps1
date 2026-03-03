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
$StartedAt   = Get-Date -Format "o"

# Ensure directories exist
foreach ($sub in @("github","local","skill")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $CARDS_DIR $sub) | Out-Null
}
New-Item -ItemType Directory -Force -Path $TEMP_DIR | Out-Null

# ── Helper: Generate unique card ID ──────────────────────────────────
function New-CardId {
    $date = Get-Date -Format "yyyyMMdd"
    $rand = -join ((48..57) + (97..102) | Get-Random -Count 6 | ForEach-Object {[char]$_})
    return "tc-$date-$rand"
}

# ── Helper: Compute source hash for dedup ────────────────────────────
function Get-SourceHash($s) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($s.ToLower().Trim('/'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "" | Select-Object -First 1
    # Simplified: use first 12 chars
}
function Get-ShortHash($s) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($s.ToLower().Trim('/'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    return $hash.Substring(0, 12)
}

# ── Detect source type ───────────────────────────────────────────────
$SourceType = ""
$SourceName = ""
$SourceMaterial = ""

if ($Source -match "^https?://github\.com/") {
    $SourceType = "github"
    $SourceName = ($Source -replace "https?://github\.com/","" -replace "\.git$","" -replace "/$","")
    Write-Host "[RADAR] Analyzing GitHub repo: $SourceName"
} elseif ($Source -match "^skill:(.+)$") {
    $skillName = $Matches[1]
    $SourceType = "skill"
    if ($skillName -eq "*") {
        Write-Host "[RADAR] Batch mode: analyzing all skills"
    } else {
        $SourceName = $skillName
        Write-Host "[RADAR] Analyzing skill: $SourceName"
    }
} else {
    $SourceType = "local"
    $SourceName = Split-Path -Leaf $Source
    Write-Host "[RADAR] Analyzing local code: $SourceName"
}

# ── Check if already analyzed (skip if -Force) ──────────────────────
if ((-not $Force) -and -not ($SourceType -eq "skill" -and $skillName -eq "*")) {
    $existingHash = Get-ShortHash $Source
    if (Test-Path $INDEX_FILE) {
        $existingIndex = @()
        try {
            $raw = Get-Content $INDEX_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($raw -is [array]) { $existingIndex = $raw }
            elseif ($raw) { $existingIndex = @($raw) }
        } catch {
            Write-Host "[RADAR] WARN: Could not parse index.json, skipping dedup check"
        }
        $alreadyDone = $existingIndex | Where-Object { $_.source_hash -eq $existingHash }
        if ($alreadyDone) {
            Write-Host "[RADAR] Already analyzed this source. Use -Force to re-analyze."
            Write-Host "[RADAR] Found $($alreadyDone.Count) existing cards."
            exit 0
        }
    }
}

# ── Gather source material ───────────────────────────────────────────

function Get-GitHubMaterial($repoUrl) {
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

function Get-LocalMaterial($path) {
    if (-not (Test-Path $path)) {
        return "ERROR: Path not found: $path"
    }
    return Collect-SourceFiles $path
}

function Get-SkillMaterial($name) {
    $skillPath = Join-Path "$env:USERPROFILE\.openclaw\skills" $name
    if (-not (Test-Path $skillPath)) {
        # Try Cowork skills path
        $skillPath = Join-Path "$env:USERPROFILE\.openclaw\skills" $name
        if (-not (Test-Path $skillPath)) {
            return "ERROR: Skill not found: $name"
        }
    }
    return Collect-SourceFiles $skillPath
}

function Collect-SourceFiles($rootDir) {
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
            if ($content.Length -gt 8000) {
                $content = $content.Substring(0, 8000) + "`n... [TRUNCATED at 8000 chars]"
            }
            $material += "`n=== FILE: $relPath ===`n$content`n"
        }
    }

    # Truncate total material if too large
    if ($material.Length -gt 60000) {
        $material = $material.Substring(0, 60000) + "`n... [TOTAL MATERIAL TRUNCATED]"
    }

    return $material
}

# ── Build analysis prompt ────────────────────────────────────────────

function Build-AnalysisPrompt($sourceType, $sourceName, $sourceUrl, $material) {
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

# ── Execute analysis via Claude CLI ──────────────────────────────────

function Invoke-ClaudeAnalysis($prompt) {
    $promptFile = Join-Path $TEMP_DIR "analysis-prompt.txt"
    Set-Content -Path $promptFile -Value $prompt -Encoding UTF8

    Write-Host "[RADAR] Sending to Claude for analysis..."

    # Use Claude Code CLI via cmd.exe pipe pattern
    $cmdLine = "type `"$promptFile`" | claude -p --output-format text"

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo.FileName = "cmd.exe"
    $proc.StartInfo.Arguments = "/c $cmdLine"
    $proc.StartInfo.UseShellExecute = $false
    $proc.StartInfo.RedirectStandardOutput = $true
    $proc.StartInfo.RedirectStandardError = $true
    $proc.StartInfo.CreateNoWindow = $true
    $proc.StartInfo.WorkingDirectory = $TEMP_DIR

    $proc.Start() | Out-Null

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $exited = $proc.WaitForExit($Timeout * 1000)
    if (-not $exited) {
        try { $proc.Kill() } catch {}
        $proc.Dispose()
        Write-Host "[RADAR] TIMEOUT after ${Timeout}s"
        return $null
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $proc.ExitCode
    $proc.Dispose()

    if ($exitCode -ne 0) {
        Write-Host "[RADAR] Claude returned exit code $exitCode"
        Write-Host "[RADAR] stderr: $stderr"
    }

    return $stdout
}

# ── Parse Claude output into individual cards ────────────────────────

function Parse-Cards($rawOutput, $sourceType) {
    if (-not $rawOutput) { return @() }

    $cards = @()
    $rawCards = $rawOutput -split "===CARD_SEPARATOR==="

    foreach ($rawCard in $rawCards) {
        $rawCard = $rawCard.Trim()
        if ($rawCard.Length -lt 100) { continue }  # Skip empty/tiny fragments

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
        $cardFile = Join-Path $CARDS_DIR $sourceType "$cardId.md"
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

function Update-Index($newCards) {
    $index = @()
    if (Test-Path $INDEX_FILE) {
        try {
            $existing = Get-Content $INDEX_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($existing -is [array]) { $index = [System.Collections.ArrayList]@($existing) }
            elseif ($existing) { $index = [System.Collections.ArrayList]@(,$existing) }
            else { $index = [System.Collections.ArrayList]@() }
        } catch {
            Write-Host "[RADAR] WARN: Could not parse index.json, starting fresh index"
            $index = [System.Collections.ArrayList]@()
        }
    } else {
        $index = [System.Collections.ArrayList]@()
    }

    foreach ($card in $newCards) {
        $index.Add($card) | Out-Null
    }

    $indexJson = $index | ConvertTo-Json -Depth 5
    Set-Content -Path $INDEX_FILE -Value $indexJson -Encoding UTF8
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
$metaFinal = @{
    task_name    = "technique-radar-analyze"
    source       = $Source
    source_type  = $SourceType
    cards_created = $allNewCards.Count
    started_at   = $StartedAt
    completed_at = (Get-Date -Format "o")
    duration     = [math]::Round($Duration, 1)
    status       = if ($allNewCards.Count -gt 0) { "done" } else { "no-cards" }
} | ConvertTo-Json -Depth 3
Set-Content -Path (Join-Path $SKILL_DIR "latest-meta.json") -Value $metaFinal -Encoding UTF8

Write-Host "`n[RADAR] Complete: $($allNewCards.Count) cards extracted in $([math]::Round($Duration,1))s"
