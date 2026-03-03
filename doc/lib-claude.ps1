# lib-claude.ps1 — Shared Claude CLI invocation utilities for Technique Radar
# Dot-source this file: . (Join-Path $SKILL_DIR "lib-claude.ps1")

<#
.SYNOPSIS
    Invoke Claude CLI with a prompt string, returning stdout text.
.DESCRIPTION
    Writes prompt to temp file, pipes through cmd.exe to Claude CLI.
    Handles timeouts, exit code errors, and CLAUDECODE env removal.
    Sanitizes file paths to prevent command injection.
.PARAMETER Prompt
    The prompt text to send to Claude.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for Claude response (default: 180).
.PARAMETER WorkDir
    Working directory for the process (default: $env:TEMP).
.OUTPUTS
    [string] Claude's response text, or $null on failure.
#>
function Invoke-ClaudeCli {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt,

        [ValidateRange(10, 600)]
        [int]$TimeoutSeconds = 180,

        [string]$WorkDir = $env:TEMP
    )

    # Validate WorkDir exists
    if (-not (Test-Path $WorkDir)) {
        New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    }

    # Write prompt to temp file (avoids command injection via cmd.exe)
    $promptFile = Join-Path $WorkDir "claude-prompt-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    try {
        Set-Content -Path $promptFile -Value $Prompt -Encoding UTF8

        # Validate prompt file path contains no dangerous characters
        if ($promptFile -match '[;&|`$]') {
            Write-Warning "[LIB-CLAUDE] Prompt file path contains unsafe characters"
            return $null
        }

        $cmdLine = "type `"$promptFile`" | claude -p --output-format text"

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo.FileName = "cmd.exe"
        $proc.StartInfo.Arguments = "/c $cmdLine"
        $proc.StartInfo.UseShellExecute = $false
        $proc.StartInfo.RedirectStandardOutput = $true
        $proc.StartInfo.RedirectStandardError = $true
        $proc.StartInfo.CreateNoWindow = $true
        $proc.StartInfo.WorkingDirectory = $WorkDir
        # Allow claude CLI to run inside a Claude Code session
        $proc.StartInfo.EnvironmentVariables.Remove("CLAUDECODE") | Out-Null

        $started = $proc.Start()
        if (-not $started) {
            Write-Warning "[LIB-CLAUDE] Failed to start process"
            return $null
        }

        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { Write-Verbose "[LIB-CLAUDE] Process kill failed: $($_.Exception.Message)" }
            Write-Warning "[LIB-CLAUDE] TIMEOUT after ${TimeoutSeconds}s"
            return $null
        }

        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $proc.ExitCode

        if ($exitCode -ne 0) {
            Write-Warning "[LIB-CLAUDE] Claude returned exit code $exitCode"
            if ($stderr) { Write-Verbose "[LIB-CLAUDE] stderr: $stderr" }
        }

        return $stdout
    }
    catch {
        Write-Warning "[LIB-CLAUDE] Exception: $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($proc) { $proc.Dispose() }
        # Cleanup temp prompt file
        if (Test-Path $promptFile) {
            Remove-Item -Path $promptFile -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
    Validate and sanitize a source path/URL for safe usage.
.DESCRIPTION
    Checks input against known-good patterns (GitHub URL, skill: prefix, local path).
    Rejects inputs containing shell metacharacters.
.PARAMETER Source
    The source string to validate.
.OUTPUTS
    [hashtable] with keys: Valid (bool), Type (string), Name (string), Sanitized (string).
#>
function Test-SourceInput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Source
    )

    $result = @{ Valid = $false; Type = ""; Name = ""; Sanitized = "" }

    # Reject obvious injection attempts
    if ($Source -match '[;&|`\$\(\)]' -and $Source -notmatch '^\w:\\') {
        Write-Warning "[LIB-CLAUDE] Source contains potentially unsafe characters: $Source"
        return $result
    }

    if ($Source -match "^https?://github\.com/[\w\-\.]+/[\w\-\.]+/?$") {
        $result.Valid = $true
        $result.Type = "github"
        $result.Name = ($Source -replace "https?://github\.com/","" -replace "\.git$","" -replace "/$","")
        $result.Sanitized = $Source.TrimEnd('/')
    }
    elseif ($Source -match "^skill:[\w\-\*]+$") {
        $result.Valid = $true
        $result.Type = "skill"
        $result.Name = ($Source -replace "^skill:","")
        $result.Sanitized = $Source
    }
    elseif (Test-Path $Source -IsValid) {
        $result.Valid = $true
        $result.Type = "local"
        $result.Name = Split-Path -Leaf $Source
        $result.Sanitized = $Source
    }
    else {
        Write-Warning "[LIB-CLAUDE] Unrecognized source format: $Source"
    }

    return $result
}
