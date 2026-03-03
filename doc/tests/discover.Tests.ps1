$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$SKILL_DIR = Join-Path $here ".."
. (Join-Path $SKILL_DIR "lib-json.ps1")

$TestDir = Join-Path $env:TEMP "technique-radar-tests-discover"
New-Item -ItemType Directory -Force -Path $TestDir | Out-Null

Describe "Candidate Management" {
    It "loads empty candidates from nonexistent file" {
        $result = Read-JsonArray (Join-Path $TestDir "no-such-candidates.json")
        $result.Count | Should Be 0
    }

    It "saves and loads candidates correctly" {
        $file = Join-Path $TestDir "candidates.json"
        $candidates = @(
            @{ url = "https://github.com/user/repo1"; name = "user/repo1"; status = "pending"; relevance_score = 8 },
            @{ url = "https://github.com/user/repo2"; name = "user/repo2"; status = "done"; relevance_score = 5 }
        )
        Write-JsonArray $file $candidates
        $loaded = Read-JsonArray $file
        $loaded.Count | Should Be 2
        $loaded[0].url | Should Be "https://github.com/user/repo1"
    }

    It "filters pending candidates correctly" {
        $candidates = @(
            @{ url = "u1"; status = "pending"; relevance_score = 8 },
            @{ url = "u2"; status = "done"; relevance_score = 9 },
            @{ url = "u3"; status = "pending"; relevance_score = 3 },
            @{ url = "u4"; status = "pending"; relevance_score = 7 }
        )
        $minScore = 6
        $pending = @($candidates | Where-Object { $_.status -eq "pending" -and $_.relevance_score -ge $minScore })
        $pending.Count | Should Be 2
    }

    It "sorts candidates by status then relevance" {
        $candidates = @(
            @{ status = "done"; relevance_score = 9 },
            @{ status = "pending"; relevance_score = 5 },
            @{ status = "pending"; relevance_score = 8 }
        )
        $sorted = $candidates | Sort-Object @(
            @{ Expression = { if ($_.status -eq "pending") { 0 } else { 1 } }; Ascending = $true },
            @{ Expression = { $_.relevance_score }; Descending = $true }
        )
        $sorted[0].relevance_score | Should Be 8
        $sorted[1].relevance_score | Should Be 5
    }
}

Describe "URL Dedup Logic" {
    It "builds analyzed URLs lookup correctly" {
        $indexEntries = @(
            @{ source = "https://github.com/a/b" },
            @{ source = "https://github.com/c/d" }
        )
        $analyzedUrls = @{}
        foreach ($entry in $indexEntries) {
            if ($entry.source) { $analyzedUrls[$entry.source] = $true }
        }
        $analyzedUrls.ContainsKey("https://github.com/a/b") | Should Be $true
        $analyzedUrls.ContainsKey("https://github.com/x/y") | Should Be $false
    }

    It "skips already-known URLs" {
        $existingUrls = @{ "https://github.com/a/b" = $true }
        $repoUrl = "https://github.com/a/b"
        $skip = $existingUrls.ContainsKey($repoUrl)
        $skip | Should Be $true
    }

    It "allows new URLs" {
        $existingUrls = @{ "https://github.com/a/b" = $true }
        $repoUrl = "https://github.com/new/repo"
        $skip = $existingUrls.ContainsKey($repoUrl)
        $skip | Should Be $false
    }
}

Describe "Scoring Output Parsing" {
    It "parses valid JSON scoring array" {
        $scoreJson = '[{"idx":1,"score":8,"reason":"Novel pattern"},{"idx":2,"score":3,"reason":"Too simple"}]'
        $scores = $scoreJson | ConvertFrom-Json
        $scores.Count | Should Be 2
        $scores[0].score | Should Be 8
        $scores[1].reason | Should Be "Too simple"
    }

    It "extracts JSON array from mixed output" {
        $output = "Here are the scores:`n[{`"idx`":1,`"score`":7,`"reason`":`"Good`"}]`nDone."
        if ($output -match '\[[\s\S]*\]') {
            $json = $Matches[0]
            $parsed = $json | ConvertFrom-Json
            $parsed[0].score | Should Be 7
        } else {
            throw "JSON not found in output"
        }
    }

    It "handles malformed JSON gracefully" {
        $output = "no json here"
        $found = $output -match '\[[\s\S]*\]'
        $found | Should Be $false
    }
}

Describe "Rate Limit Detection" {
    It "detects 403 rate limit" {
        $errMsg = "Response status code does not indicate success: 403 (Forbidden)"
        ($errMsg -match "403|429|rate limit") | Should Be $true
    }

    It "detects 429 rate limit" {
        $errMsg = "Response status code: 429 Too Many Requests"
        ($errMsg -match "403|429|rate limit") | Should Be $true
    }

    It "does not false-positive on normal errors" {
        $errMsg = "Could not resolve host name"
        ($errMsg -match "403|429|rate limit") | Should Be $false
    }
}

# Cleanup
if (Test-Path $TestDir) { Remove-Item -Recurse -Force $TestDir }
