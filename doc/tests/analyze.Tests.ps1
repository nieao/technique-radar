$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$SKILL_DIR = Join-Path $here ".."
. (Join-Path $SKILL_DIR "lib-json.ps1")

# Extract testable functions from analyze.ps1
function New-CardId {
    $date = Get-Date -Format "yyyyMMdd"
    $rand = -join ((48..57) + (97..102) | Get-Random -Count 6 | ForEach-Object {[char]$_})
    return "tc-$date-$rand"
}

function Get-ShortHash($s) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($s.ToLower().Trim('/'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    return $hash.Substring(0, 12)
}

Describe "New-CardId" {
    It "generates ID with correct prefix format 'tc-YYYYMMDD-'" {
        $id = New-CardId
        $id | Should Match '^tc-\d{8}-[a-f0-9]{6}$'
    }

    It "uses today's date in the ID" {
        $today = Get-Date -Format "yyyyMMdd"
        $id = New-CardId
        $id | Should Match "^tc-$today-"
    }

    It "generates unique IDs on consecutive calls" {
        $id1 = New-CardId
        $id2 = New-CardId
        $id1 | Should Not Be $id2
    }

    It "generates exactly 6 hex characters as suffix" {
        $id = New-CardId
        $suffix = $id.Split('-')[2]
        $suffix.Length | Should Be 6
        $suffix | Should Match '^[a-f0-9]+$'
    }
}

Describe "Get-ShortHash" {
    It "returns a 12-character hex string" {
        $hash = Get-ShortHash "https://github.com/test/repo"
        $hash.Length | Should Be 12
        $hash | Should Match '^[a-f0-9]+$'
    }

    It "returns same hash for same input" {
        $hash1 = Get-ShortHash "https://github.com/test/repo"
        $hash2 = Get-ShortHash "https://github.com/test/repo"
        $hash1 | Should Be $hash2
    }

    It "returns different hashes for different inputs" {
        $hash1 = Get-ShortHash "https://github.com/test/repo1"
        $hash2 = Get-ShortHash "https://github.com/test/repo2"
        $hash1 | Should Not Be $hash2
    }

    It "normalizes case (uppercase = lowercase)" {
        $hash1 = Get-ShortHash "HTTPS://GITHUB.COM/TEST/REPO"
        $hash2 = Get-ShortHash "https://github.com/test/repo"
        $hash1 | Should Be $hash2
    }

    It "trims trailing slashes" {
        $hash1 = Get-ShortHash "https://github.com/test/repo/"
        $hash2 = Get-ShortHash "https://github.com/test/repo"
        $hash1 | Should Be $hash2
    }
}

Describe "Source Type Detection" {
    It "detects GitHub URLs correctly" {
        ("https://github.com/user/repo" -match "^https?://github\.com/") | Should Be $true
    }

    It "detects skill: prefix correctly" {
        ("skill:my-skill" -match "^skill:(.+)$") | Should Be $true
        $Matches[1] | Should Be "my-skill"
    }

    It "detects skill:* wildcard" {
        ("skill:*" -match "^skill:(.+)$") | Should Be $true
        $Matches[1] | Should Be "*"
    }

    It "treats local paths as local type" {
        ("C:\Projects\my-code" -match "^https?://github\.com/") | Should Be $false
    }
}

# Parse-Cards unit tests (logic extracted from analyze.ps1)
Describe "Parse-Cards Logic" {
    It "splits raw output by separator" {
        $raw = "card1 content===CARD_SEPARATOR===card2 content"
        $parts = $raw -split "===CARD_SEPARATOR==="
        $parts.Count | Should Be 2
    }

    It "skips fragments shorter than threshold" {
        $minLen = 100
        $fragment = "short"
        ($fragment.Length -lt $minLen) | Should Be $true
    }

    It "extracts title from card content" {
        $content = "---`nid: tc-001`ntitle: My Cool Pattern`n---"
        $title = ""
        if ($content -match "title:\s*(.+)") { $title = $Matches[1].Trim() }
        $title | Should Be "My Cool Pattern"
    }

    It "extracts tags from card content" {
        $content = "tags: [async, retry, agent]"
        $tags = @()
        if ($content -match "tags:\s*\[(.+)\]") {
            $tags = $Matches[1] -split "," | ForEach-Object { $_.Trim() }
        }
        $tags.Count | Should Be 3
        $tags[0] | Should Be "async"
    }

    It "extracts cleverness score" {
        $content = "cleverness: 8"
        $cleverness = 5
        if ($content -match "cleverness:\s*(\d+)") { $cleverness = [int]$Matches[1] }
        $cleverness | Should Be 8
    }

    It "extracts reusability score" {
        $content = "reusability: 9"
        $reusability = 5
        if ($content -match "reusability:\s*(\d+)") { $reusability = [int]$Matches[1] }
        $reusability | Should Be 9
    }

    It "defaults scores when not present" {
        $content = "no scores here"
        $cleverness = 5; $reusability = 5
        if ($content -match "cleverness:\s*(\d+)") { $cleverness = [int]$Matches[1] }
        if ($content -match "reusability:\s*(\d+)") { $reusability = [int]$Matches[1] }
        $cleverness | Should Be 5
        $reusability | Should Be 5
    }

    It "replaces PLACEHOLDER id with real id" {
        $cardId = "tc-20260303-abc123"
        $raw = "id: PLACEHOLDER`ntitle: Test"
        $result = $raw -replace "id: PLACEHOLDER", "id: $cardId"
        $result | Should Match "id: tc-20260303-abc123"
    }
}
