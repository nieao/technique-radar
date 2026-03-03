$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$SKILL_DIR = Join-Path $here ".."
. (Join-Path $SKILL_DIR "lib-json.ps1")

# Tunable constants (same as analyze.ps1)
$MAX_FILE_CHARS  = 4000
$MAX_TOTAL_CHARS = 35000

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

# Trim-FileContent (copied from analyze.ps1 for unit testing)
function Trim-FileContent {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory=$true)][string]$Content,
        [int]$MaxChars = $MAX_FILE_CHARS
    )
    $text = $Content
    $text = [regex]::Replace($text, '/\*[\s\S]*?\*/', '')
    $text = [regex]::Replace($text, '"""[\s\S]*?"""', '""""""')
    $text = [regex]::Replace($text, "'''[\s\S]*?'''", "''''''")
    $text = [regex]::Replace($text, '<#[\s\S]*?#>', '')
    $text = [regex]::Replace($text, '(\r?\n\s*){3,}', "`n`n")
    $text = [regex]::Replace($text, '"[^"\r\n]{200,}"', '"[... long string ...]"')
    $text = [regex]::Replace($text, "'[^'\r\n]{200,}'", "'[... long string ...]'")
    $lines = $text -split "`n"
    $result = [System.Collections.ArrayList]::new()
    $importRun = [System.Collections.ArrayList]::new()
    foreach ($line in $lines) {
        if ($line -match '^\s*(import |from .+ import|require\(|using |#include )') {
            $importRun.Add($line) | Out-Null
        } else {
            if ($importRun.Count -gt 15) {
                for ($i = 0; $i -lt 5; $i++) { $result.Add($importRun[$i]) | Out-Null }
                $result.Add("// ... ($($importRun.Count - 5) more imports omitted)") | Out-Null
            } elseif ($importRun.Count -gt 0) {
                foreach ($imp in $importRun) { $result.Add($imp) | Out-Null }
            }
            $importRun.Clear()
            $result.Add($line) | Out-Null
        }
    }
    if ($importRun.Count -gt 15) {
        for ($i = 0; $i -lt 5; $i++) { $result.Add($importRun[$i]) | Out-Null }
        $result.Add("// ... ($($importRun.Count - 5) more imports omitted)") | Out-Null
    } elseif ($importRun.Count -gt 0) {
        foreach ($imp in $importRun) { $result.Add($imp) | Out-Null }
    }
    $text = $result -join "`n"
    if ($text.Length -gt $MaxChars) {
        $sigLines = ($text -split "`n") | Where-Object {
            $_ -match '^\s*(def |function |class |interface |struct |enum |pub fn |fn |export |module |type |const |async function |async def )'
        }
        if ($sigLines.Count -gt 0) {
            $summary = "// [SMART TRIM] File too large - showing signatures only ($($sigLines.Count) definitions)`n"
            $summary += ($sigLines -join "`n")
            $headerLen = [math]::Min(800, $MaxChars / 3)
            $text = $text.Substring(0, [int]$headerLen) + "`n`n$summary"
        }
    }
    if ($text.Length -gt $MaxChars) {
        $text = $text.Substring(0, $MaxChars) + "`n... [TRIMMED at $MaxChars chars]"
    }
    return $text
}

# Get-RepoStructure (copied from analyze.ps1 for unit testing)
function Get-RepoStructure {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory=$true)][string]$RootDir,
        [int]$MaxEntries = 40
    )
    $skipDirs = @("node_modules",".git","__pycache__",".venv","dist","build",".next","vendor",
                  "coverage",".nyc_output",".tox",".mypy_cache",".pytest_cache")
    $entries = [System.Collections.ArrayList]::new()
    $dirCount = 0; $fileCount = 0
    $topItems = Get-ChildItem -Path $RootDir -ErrorAction SilentlyContinue | Sort-Object { -not $_.PSIsContainer }, Name
    foreach ($item in $topItems) {
        if ($entries.Count -ge $MaxEntries) { break }
        if ($item.PSIsContainer) {
            if ($item.Name -in $skipDirs) { continue }
            $dirCount++
            $entries.Add([string]"$([char]0x251C)$([char]0x2500)$([char]0x2500) $($item.Name)/") | Out-Null
            $subItems = Get-ChildItem -Path $item.FullName -ErrorAction SilentlyContinue | Sort-Object { -not $_.PSIsContainer }, Name
            foreach ($sub in $subItems) {
                if ($entries.Count -ge $MaxEntries) { break }
                if ($sub.PSIsContainer) {
                    if ($sub.Name -in $skipDirs) { continue }
                    $dirCount++
                    $entries.Add([string]"$([char]0x2502)   $([char]0x251C)$([char]0x2500)$([char]0x2500) $($sub.Name)/") | Out-Null
                } else {
                    $fileCount++
                    $entries.Add([string]"$([char]0x2502)   $([char]0x251C)$([char]0x2500)$([char]0x2500) $($sub.Name)") | Out-Null
                }
            }
        } else {
            $fileCount++
            $entries.Add([string]"$([char]0x251C)$([char]0x2500)$([char]0x2500) $($item.Name)") | Out-Null
        }
    }
    $tree = $entries -join "`n"
    if ($entries.Count -ge $MaxEntries) {
        $tree += "`n... (truncated)"
    }
    $summary = "($fileCount source files, $dirCount directories)"
    return "=== REPO STRUCTURE ===`n$tree`n$summary`n"
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

# ── Trim-FileContent tests ──────────────────────────────────────────

Describe "Trim-FileContent" {
    It "removes C-style block comments" {
        $input = "before`n/* this is`na comment */`nafter"
        $result = Trim-FileContent -Content $input -MaxChars 4000
        $result | Should Not Match '/\*'
        $result | Should Match 'before'
        $result | Should Match 'after'
    }

    It "removes PowerShell block comments" {
        $input = "line1`n<# block`ncomment #>`nline2"
        $result = Trim-FileContent -Content $input -MaxChars 4000
        $result | Should Not Match '<#'
        $result | Should Match 'line1'
        $result | Should Match 'line2'
    }

    It "collapses multiple blank lines into one" {
        $input = "a`n`n`n`n`nb"
        $result = Trim-FileContent -Content $input -MaxChars 4000
        # Should have at most 2 consecutive newlines (one blank line)
        $result | Should Not Match '(\r?\n\s*){3,}'
    }

    It "replaces long string literals with placeholder" {
        $longStr = '"' + ('x' * 250) + '"'
        $input = "var s = $longStr;"
        $result = Trim-FileContent -Content $input -MaxChars 4000
        $result | Should Match '\[... long string ...\]'
    }

    It "preserves short string literals unchanged" {
        $input = 'var s = "hello world";'
        $result = Trim-FileContent -Content $input -MaxChars 4000
        $result | Should Match 'hello world'
    }

    It "compresses import blocks longer than 15 lines" {
        $imports = (1..20 | ForEach-Object { "import module$_" }) -join "`n"
        $input = "$imports`nfunction main() {}"
        $result = Trim-FileContent -Content $input -MaxChars 4000
        $result | Should Match 'import module1'
        $result | Should Match 'import module5'
        $result | Should Match 'more imports omitted'
        $result | Should Not Match 'import module20'
    }

    It "keeps import blocks of 15 or fewer lines intact" {
        $imports = (1..10 | ForEach-Object { "import module$_" }) -join "`n"
        $input = "$imports`nfunction main() {}"
        $result = Trim-FileContent -Content $input -MaxChars 4000
        $result | Should Match 'import module10'
        $result | Should Not Match 'omitted'
    }

    It "hard-truncates at MaxChars limit" {
        $input = 'x' * 5000
        $result = Trim-FileContent -Content $input -MaxChars 500
        ($result.Length -le 560) | Should Be $true  # 500 + marker text
        $result | Should Match 'TRIMMED at 500 chars'
    }

    It "activates signature extraction for large files with functions" {
        $funcs = (1..50 | ForEach-Object { "function func$_() {`n    // body line $_ padding" + ('z' * 60) + "`n}" }) -join "`n"
        $result = Trim-FileContent -Content $funcs -MaxChars 1000
        $result | Should Match 'SMART TRIM'
        $result | Should Match 'function func'
    }

    It "returns small content unchanged" {
        $input = "small file content"
        $result = Trim-FileContent -Content $input -MaxChars 4000
        $result | Should Be "small file content"
    }
}

# ── File Priority Scoring tests ─────────────────────────────────────

Describe "File Priority Scoring" {
    It "ranks SKILL.md as priority 0" {
        $name = "skill.md"
        if ($name -eq "skill.md" -or $name -match "^readme") { $p = 0 } else { $p = 99 }
        $p | Should Be 0
    }

    It "ranks main.py as priority 1 (entry file)" {
        $name = "main.py"
        $p = 5
        if ($name -match "(test|spec|mock|fixture|example)") { $p = 99 }
        elseif ($name -eq "skill.md" -or $name -match "^readme") { $p = 0 }
        elseif ($name -match "^(main|index|app|cli|agent|server)\." ) { $p = 1 }
        $p | Should Be 1
    }

    It "ranks package.json as priority 2 (config)" {
        $name = "package.json"
        $p = 5
        if ($name -match "(test|spec|mock|fixture|example)") { $p = 99 }
        elseif ($name -eq "skill.md" -or $name -match "^readme") { $p = 0 }
        elseif ($name -match "^(main|index|app|cli|agent|server)\." ) { $p = 1 }
        elseif ($name -match "^(package\.json|pyproject\.toml|cargo\.toml|go\.mod)$" ) { $p = 2 }
        $p | Should Be 2
    }

    It "ranks src/ files as priority 3" {
        $relPath = "src/utils.ts"
        $name = "utils.ts"
        $p = 5
        if ($name -match "(test|spec|mock|fixture|example)") { $p = 99 }
        elseif ($name -eq "skill.md" -or $name -match "^readme") { $p = 0 }
        elseif ($name -match "^(main|index|app|cli|agent|server)\." ) { $p = 1 }
        elseif ($name -match "^(package\.json|pyproject\.toml|cargo\.toml|go\.mod)$" ) { $p = 2 }
        elseif ($relPath -match "^(src|lib|core)[/\\]") { $p = 3 }
        $p | Should Be 3
    }

    It "demotes test files to priority 99" {
        $name = "test_utils.py"
        $p = 5
        if ($name -match "(test|spec|mock|fixture|example)") { $p = 99 }
        $p | Should Be 99
    }

    It "demotes mock files to priority 99" {
        $name = "mock_api.js"
        $p = 5
        if ($name -match "(test|spec|mock|fixture|example)") { $p = 99 }
        $p | Should Be 99
    }
}

# ── Get-RepoStructure tests ────────────────────────────────────────

Describe "Get-RepoStructure" {
    # Setup: create test directory structure (Pester 3.4 compatible)
    $testRoot = Join-Path $env:TEMP "test-repo-structure-$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $testRoot "src") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $testRoot "node_modules") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $testRoot ".git") | Out-Null
    Set-Content -Path (Join-Path $testRoot "README.md") -Value "readme"
    Set-Content -Path (Join-Path $testRoot "package.json") -Value "{}"
    Set-Content -Path (Join-Path $testRoot "src\index.ts") -Value "export {}"
    Set-Content -Path (Join-Path $testRoot "src\utils.ts") -Value "export {}"

    It "starts with === REPO STRUCTURE ===" {
        $result = Get-RepoStructure -RootDir $testRoot
        $result | Should Match '=== REPO STRUCTURE ==='
    }

    It "includes file and directory counts" {
        $result = Get-RepoStructure -RootDir $testRoot
        $result | Should Match 'source files'
        $result | Should Match 'directories'
    }

    It "skips node_modules and .git" {
        $result = Get-RepoStructure -RootDir $testRoot
        $result | Should Not Match 'node_modules'
        $result | Should Not Match '\.git/'
    }

    It "includes src directory and its files" {
        $result = Get-RepoStructure -RootDir $testRoot
        $result | Should Match 'src/'
        $result | Should Match 'index\.ts'
    }

    It "truncates when exceeding MaxEntries" {
        $result = Get-RepoStructure -RootDir $testRoot -MaxEntries 2
        $result | Should Match 'truncated'
    }

    # Cleanup
    if (Test-Path $testRoot) { Remove-Item -Recurse -Force $testRoot }
}

# ── Constants validation ────────────────────────────────────────────

Describe "Tunable Constants" {
    It "MAX_FILE_CHARS is 4000 (reduced from 8000)" {
        $MAX_FILE_CHARS | Should Be 4000
    }

    It "MAX_TOTAL_CHARS is 35000 (reduced from 60000)" {
        $MAX_TOTAL_CHARS | Should Be 35000
    }
}
