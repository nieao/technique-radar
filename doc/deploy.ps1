# Technique Radar - One-Click Deployer
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File deploy.ps1

$ErrorActionPreference = "Stop"
$SKILL_DIR = "$env:USERPROFILE\.openclaw\skills\technique-radar"
$SOURCE_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "============================================"
Write-Host "  Technique Radar - Deployer"
Write-Host "============================================"

# ── Create directory structure ─────────────────────────────────────────
Write-Host "[DEPLOY] Creating skill directory..."
New-Item -ItemType Directory -Force -Path $SKILL_DIR | Out-Null
foreach ($sub in @("cards\github","cards\local","cards\skill")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $SKILL_DIR $sub) | Out-Null
}

# ── Copy all script files ─────────────────────────────────────────────
$filesToCopy = @("SKILL.md", "analyze.ps1", "discover.ps1", "search.ps1", "daily-pipeline.ps1", "deploy.ps1", "lib-json.ps1", "lib-claude.ps1", "PSScriptAnalyzerSettings.psd1")

foreach ($f in $filesToCopy) {
    $src = Join-Path $SOURCE_DIR $f
    $dst = Join-Path $SKILL_DIR $f
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $dst -Force
        Write-Host "[DEPLOY] Copied: $f"
    } else {
        Write-Host "[DEPLOY] WARNING: $f not found in source directory"
    }
}

# ── Initialize empty index if not exists ───────────────────────────────
$indexFile = Join-Path $SKILL_DIR "index.json"
if (-not (Test-Path $indexFile)) {
    Set-Content -Path $indexFile -Value "[]" -Encoding UTF8
    Write-Host "[DEPLOY] Initialized empty index"
}

$candidatesFile = Join-Path $SKILL_DIR "candidates.json"
if (-not (Test-Path $candidatesFile)) {
    Set-Content -Path $candidatesFile -Value "[]" -Encoding UTF8
    Write-Host "[DEPLOY] Initialized empty candidates list"
}

# ── Verify installation ───────────────────────────────────────────────
Write-Host "`n[DEPLOY] Verifying installation..."

$allGood = $true
foreach ($f in $filesToCopy) {
    $path = Join-Path $SKILL_DIR $f
    if (Test-Path $path) {
        Write-Host "  [OK] $f"
    } else {
        Write-Host "  [FAIL] $f"
        $allGood = $false
    }
}

if (-not $allGood) {
    Write-Host "`n[DEPLOY] WARNING: Some files were not copied successfully"
}

# Check Claude CLI availability
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host "  [OK] Claude CLI found"
} else {
    Write-Host "  [WARN] Claude CLI not in PATH - analyze will not work"
}

# Check git availability
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "  [OK] Git found"
} else {
    Write-Host "  [WARN] Git not in PATH - GitHub repo cloning will not work"
}

# ── Print usage guide ─────────────────────────────────────────────────
Write-Host "`n============================================"
Write-Host "  Installation Complete!"
Write-Host "============================================"
Write-Host ""
Write-Host "Quick Start:"
Write-Host ""
Write-Host "  1. Analyze a GitHub repo:"
Write-Host "     powershell -NoProfile -ExecutionPolicy Bypass -File `"$SKILL_DIR\analyze.ps1`" -Source `"https://github.com/browser-use/browser-use`""
Write-Host ""
Write-Host "  2. Analyze your local code:"
Write-Host "     powershell -NoProfile -ExecutionPolicy Bypass -File `"$SKILL_DIR\analyze.ps1`" -Source `"C:\Projects\my-project`""
Write-Host ""
Write-Host "  3. Analyze all your OpenClaw skills:"
Write-Host "     powershell -NoProfile -ExecutionPolicy Bypass -File `"$SKILL_DIR\analyze.ps1`" -Source `"skill:*`""
Write-Host ""
Write-Host "  4. Discover trending repos:"
Write-Host "     powershell -NoProfile -ExecutionPolicy Bypass -File `"$SKILL_DIR\discover.ps1`""
Write-Host ""
Write-Host "  5. Search your knowledge base:"
Write-Host "     powershell -NoProfile -ExecutionPolicy Bypass -File `"$SKILL_DIR\search.ps1`" -Query `"agent async pattern`""
Write-Host ""
Write-Host "  6. Run full daily pipeline:"
Write-Host "     powershell -NoProfile -ExecutionPolicy Bypass -File `"$SKILL_DIR\daily-pipeline.ps1`""
Write-Host ""
Write-Host "Tip: Set up a Windows Task Scheduler job to run daily-pipeline.ps1"
Write-Host "     every morning for fully automated knowledge accumulation."
Write-Host ""
Write-Host "Skill dir: $SKILL_DIR"
