# Pester v3 compatible: resolve lib-json.ps1 via the test file path from Pester internals
$testFilePath = $Pester.CurrentTestGroup.ScriptBlock.File
if (-not $testFilePath) {
    # Fallback: use the test path that Pester passes
    $testFilePath = $MyInvocation.MyCommand.Path
}
$libPath = Join-Path (Split-Path (Split-Path $testFilePath -Parent) -Parent) "lib-json.ps1"
if (-not (Test-Path $libPath)) {
    # Hard fallback
    $libPath = "E:\claude code\auto-skill-test\doc\lib-json.ps1"
}
. $libPath

$TestDir = Join-Path $env:TEMP "technique-radar-tests-json"
New-Item -ItemType Directory -Force -Path $TestDir | Out-Null

Describe "Read-JsonArray" {
    It "returns empty array when file does not exist" {
        $result = Read-JsonArray (Join-Path $TestDir "nonexistent.json")
        $result.Count | Should Be 0
    }

    It "returns empty array for empty JSON array '[]'" {
        $file = Join-Path $TestDir "empty.json"
        Set-Content -Path $file -Value "[]" -Encoding UTF8
        $result = Read-JsonArray $file
        $result.Count | Should Be 0
    }

    It "returns single-element array for JSON object" {
        $file = Join-Path $TestDir "single.json"
        Set-Content -Path $file -Value '{"id":"tc-001","title":"Test"}' -Encoding UTF8
        $result = Read-JsonArray $file
        $result.Count | Should Be 1
        $result[0].id | Should Be "tc-001"
    }

    It "returns correct array for multi-element JSON array" {
        $file = Join-Path $TestDir "multi.json"
        Set-Content -Path $file -Value '[{"id":"tc-001"},{"id":"tc-002"},{"id":"tc-003"}]' -Encoding UTF8
        $result = Read-JsonArray $file
        $result.Count | Should Be 3
        $result[1].id | Should Be "tc-002"
    }

    It "returns empty array for malformed JSON" {
        $file = Join-Path $TestDir "broken.json"
        Set-Content -Path $file -Value "{invalid json" -Encoding UTF8
        $result = Read-JsonArray $file
        $result.Count | Should Be 0
    }

    It "handles UTF-8 content correctly" {
        $file = Join-Path $TestDir "utf8.json"
        Set-Content -Path $file -Value '[{"title":"Test card"}]' -Encoding UTF8
        $result = Read-JsonArray $file
        $result.Count | Should Be 1
    }
}

Describe "Write-JsonArray" {
    It "writes empty array as '[]'" {
        $file = Join-Path $TestDir "write-empty.json"
        Write-JsonArray $file @()
        $content = (Get-Content $file -Raw -Encoding UTF8).Trim()
        $content | Should Be "[]"
    }

    It "writes single element as JSON array" {
        $file = Join-Path $TestDir "write-single.json"
        Write-JsonArray $file @(@{ id = "tc-001"; title = "Test" })
        $content = (Get-Content $file -Raw -Encoding UTF8).Trim()
        $content | Should Match '^\['
        $content | Should Match '\]$'
    }

    It "writes multiple elements correctly" {
        $file = Join-Path $TestDir "write-multi.json"
        Write-JsonArray $file @(@{ id = "tc-001" }, @{ id = "tc-002" })
        $result = Read-JsonArray $file
        $result.Count | Should Be 2
    }

    It "round-trips data correctly" {
        $file = Join-Path $TestDir "roundtrip.json"
        $original = @(
            @{ id = "tc-001"; title = "Pattern A"; cleverness = 8 },
            @{ id = "tc-002"; title = "Pattern B"; cleverness = 6 }
        )
        Write-JsonArray $file $original
        $result = Read-JsonArray $file
        $result.Count | Should Be 2
    }
}

# Cleanup
if (Test-Path $TestDir) { Remove-Item -Recurse -Force $TestDir }
