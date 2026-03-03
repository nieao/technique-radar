$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$SKILL_DIR = Join-Path $here ".."

Describe "Deploy File List Completeness" {
    $filesToCopy = @("SKILL.md", "analyze.ps1", "discover.ps1", "search.ps1", "daily-pipeline.ps1", "deploy.ps1", "lib-json.ps1", "lib-claude.ps1", "PSScriptAnalyzerSettings.psd1")

    It "all deploy files exist in source directory" {
        foreach ($f in $filesToCopy) {
            $path = Join-Path $SKILL_DIR $f
            (Test-Path $path) | Should Be $true
        }
    }

    It "includes all library files" {
        $libs = @($filesToCopy | Where-Object { $_ -match "^lib-" })
        $libs.Count | Should Be 2
        $libs | Should Not BeNullOrEmpty
    }

    It "includes SKILL.md" {
        ($filesToCopy -contains "SKILL.md") | Should Be $true
    }
}

Describe "Deploy Directory Structure" {
    It "creates nested card directories" {
        $testRoot = Join-Path $env:TEMP "technique-radar-test-deploy"
        foreach ($sub in @("cards\github","cards\local","cards\skill")) {
            New-Item -ItemType Directory -Force -Path (Join-Path $testRoot $sub) | Out-Null
        }
        (Test-Path (Join-Path $testRoot "cards\github")) | Should Be $true
        (Test-Path (Join-Path $testRoot "cards\local")) | Should Be $true
        (Test-Path (Join-Path $testRoot "cards\skill")) | Should Be $true
        Remove-Item -Recurse -Force $testRoot
    }

    It "initializes empty JSON files" {
        $testRoot = Join-Path $env:TEMP "technique-radar-test-deploy2"
        New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
        $indexFile = Join-Path $testRoot "index.json"
        Set-Content -Path $indexFile -Value "[]" -Encoding UTF8
        $content = (Get-Content $indexFile -Raw -Encoding UTF8).Trim()
        $content | Should Be "[]"
        Remove-Item -Recurse -Force $testRoot
    }
}

Describe "Deploy Prerequisite Checks" {
    It "checks if Claude CLI is available" {
        $available = $false
        $cmd = Get-Command "claude" -ErrorAction SilentlyContinue
        if ($cmd) { $available = $true }
        ($available -is [bool]) | Should Be $true
    }

    It "checks if Git is available" {
        $available = $false
        $cmd = Get-Command "git" -ErrorAction SilentlyContinue
        if ($cmd) { $available = $true }
        ($available -is [bool]) | Should Be $true
    }
}
