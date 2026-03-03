# lib-json.ps1 — Shared JSON read/write utilities for Technique Radar
# Dot-source this file: . (Join-Path $SKILL_DIR "lib-json.ps1")

<#
.SYNOPSIS
    Safely read a JSON file and always return an array.
.DESCRIPTION
    Handles: file not found, parse errors, single-object vs array edge case.
    Returns an empty array on any failure.
.PARAMETER Path
    Path to the JSON file.
#>
function Read-JsonArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return @()
    }

    try {
        $raw = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $raw) { return ,@() }
        if ($raw -is [array]) { return ,$raw }
        # Single object: wrap in array with comma operator to prevent pipeline unwrap
        return ,@($raw)
    } catch {
        Write-Host "[LIB-JSON] WARN: Could not parse $([System.IO.Path]::GetFileName($Path)), returning empty array"
        return ,@()
    }
}

<#
.SYNOPSIS
    Write an array to a JSON file, always serializing as a JSON array.
.DESCRIPTION
    Wraps @() around data to force array output even for 0 or 1 elements.
.PARAMETER Path
    Path to the JSON file.
.PARAMETER Data
    Array of objects to serialize.
.PARAMETER Depth
    JSON serialization depth (default: 5).
#>
function Write-JsonArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,

        [Parameter(Mandatory=$true)]
        [AllowEmptyCollection()]
        $Data,

        [int]$Depth = 5
    )

    # Force array serialization — @() wrapping + explicit array JSON
    $arr = @($Data)
    if ($arr.Count -eq 0) {
        Set-Content -Path $Path -Value "[]" -Encoding UTF8
    } else {
        $json = @($arr) | ConvertTo-Json -Depth $Depth
        # ConvertTo-Json with single element may not produce array brackets
        if ($arr.Count -eq 1 -and $json -notmatch '^\s*\[') {
            $json = "[$json]"
        }
        Set-Content -Path $Path -Value $json -Encoding UTF8
    }
}
