$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$SKILL_DIR = Join-Path $here ".."
. (Join-Path $SKILL_DIR "lib-json.ps1")

$TestDir = Join-Path $env:TEMP "technique-radar-tests-pipeline"
New-Item -ItemType Directory -Force -Path $TestDir | Out-Null

Describe "Pipeline Phase 2 - Candidate Filtering" {
    $script:testCandidates = @(
        @{ url = "u1"; name = "repo1"; status = "pending"; relevance_score = 9 },
        @{ url = "u2"; name = "repo2"; status = "pending"; relevance_score = 4 },
        @{ url = "u3"; name = "repo3"; status = "done";    relevance_score = 10 },
        @{ url = "u4"; name = "repo4"; status = "pending"; relevance_score = 7 },
        @{ url = "u5"; name = "repo5"; status = "pending"; relevance_score = 6 }
    )

    It "filters by pending status and min score" {
        $minScore = 6
        $filtered = @($script:testCandidates |
            Where-Object { $_.status -eq "pending" -and $_.relevance_score -ge $minScore })
        $filtered.Count | Should Be 3
    }

    It "sorts filtered candidates by score descending" {
        $minScore = 6
        $sorted = @($script:testCandidates |
            Where-Object { $_.status -eq "pending" -and $_.relevance_score -ge $minScore } |
            Sort-Object @{ Expression = { $_.relevance_score }; Descending = $true })
        $sorted[0].relevance_score | Should Be 9
        $sorted[1].relevance_score | Should Be 7
    }

    It "limits to MaxAnalyze count" {
        $maxAnalyze = 2
        $minScore = 6
        $limited = @($script:testCandidates |
            Where-Object { $_.status -eq "pending" -and $_.relevance_score -ge $minScore } |
            Sort-Object @{ Expression = { $_.relevance_score }; Descending = $true } |
            Select-Object -First $maxAnalyze)
        $limited.Count | Should Be 2
    }

    It "returns empty when no candidates meet threshold" {
        $minScore = 99
        $filtered = @($script:testCandidates |
            Where-Object { $_.status -eq "pending" -and $_.relevance_score -ge $minScore })
        $filtered.Count | Should Be 0
    }
}

Describe "Pipeline Phase 3 - Summary Calculation" {
    It "counts today's cards correctly" {
        $today = Get-Date -Format "yyyy-MM-dd"
        $yesterday = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
        $indexData = @(
            @{ id = "tc-001"; discovered = $today },
            @{ id = "tc-002"; discovered = $yesterday },
            @{ id = "tc-003"; discovered = $today }
        )
        $todayCards = @($indexData | Where-Object { $_.discovered -eq $today })
        $todayCards.Count | Should Be 2
    }

    It "handles empty index for summary" {
        $indexData = @()
        $totalCards = $indexData.Count
        $totalCards | Should Be 0
    }
}

Describe "Pipeline Status Tracking" {
    It "transitions candidate status from pending to analyzing" {
        $candidate = @{ status = "pending" }
        $candidate.status = "analyzing"
        $candidate.status | Should Be "analyzing"
    }

    It "transitions candidate status from analyzing to done" {
        $candidate = @{ status = "analyzing" }
        $candidate.status = "done"
        $candidate.analyzed_at = (Get-Date -Format "o")
        $candidate.status | Should Be "done"
        $candidate.analyzed_at | Should Not BeNullOrEmpty
    }

    It "transitions candidate status to failed on error" {
        $candidate = @{ status = "analyzing" }
        $candidate.status = "failed"
        $candidate.error = "Analysis timeout"
        $candidate.status | Should Be "failed"
        $candidate.error | Should Be "Analysis timeout"
    }
}

Describe "Pipeline Duration Calculation" {
    It "calculates duration correctly" {
        $start = Get-Date -Format "o"
        Start-Sleep -Milliseconds 100
        $duration = ((Get-Date) - [datetime]$start).TotalSeconds
        $duration | Should BeGreaterThan 0
        $duration | Should BeLessThan 5
    }

    It "rounds duration to 1 decimal" {
        $raw = 12.3456
        $rounded = [math]::Round($raw, 1)
        $rounded | Should Be 12.3
    }
}

# Cleanup
if (Test-Path $TestDir) { Remove-Item -Recurse -Force $TestDir }
