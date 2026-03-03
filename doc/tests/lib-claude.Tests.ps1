$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$SKILL_DIR = Join-Path $here ".."
. (Join-Path $SKILL_DIR "lib-claude.ps1")

Describe "Test-SourceInput" {
    It "validates GitHub URLs" {
        $result = Test-SourceInput "https://github.com/user/repo"
        $result.Valid | Should Be $true
        $result.Type | Should Be "github"
        $result.Name | Should Be "user/repo"
    }

    It "validates GitHub URLs with trailing slash" {
        $result = Test-SourceInput "https://github.com/user/repo/"
        $result.Valid | Should Be $true
        $result.Sanitized | Should Be "https://github.com/user/repo"
    }

    It "validates skill: prefix" {
        $result = Test-SourceInput "skill:my-skill"
        $result.Valid | Should Be $true
        $result.Type | Should Be "skill"
        $result.Name | Should Be "my-skill"
    }

    It "validates skill:* wildcard" {
        $result = Test-SourceInput "skill:*"
        $result.Valid | Should Be $true
        $result.Type | Should Be "skill"
        $result.Name | Should Be "*"
    }

    It "validates local paths" {
        $result = Test-SourceInput "C:\Projects\my-code"
        $result.Valid | Should Be $true
        $result.Type | Should Be "local"
        $result.Name | Should Be "my-code"
    }

    It "rejects injection attempts with semicolons" {
        $result = Test-SourceInput "https://evil.com; rm -rf /"
        $result.Valid | Should Be $false
    }

    It "rejects injection attempts with pipes" {
        $result = Test-SourceInput "https://evil.com | malicious"
        $result.Valid | Should Be $false
    }

    It "rejects injection attempts with backticks" {
        $result = Test-SourceInput ('repo' + [char]96 + 'whoami')
        $result.Valid | Should Be $false
    }

    It "returns correct hashtable structure" {
        $result = Test-SourceInput "skill:test"
        $result.Keys | Should Not BeNullOrEmpty
        ($result.ContainsKey("Valid")) | Should Be $true
        ($result.ContainsKey("Type")) | Should Be $true
        ($result.ContainsKey("Name")) | Should Be $true
        ($result.ContainsKey("Sanitized")) | Should Be $true
    }
}

Describe "Invoke-ClaudeCli Parameter Validation" {
    It "rejects empty prompt" {
        $threw = $false
        try {
            Invoke-ClaudeCli -Prompt "" -TimeoutSeconds 10
        } catch {
            $threw = $true
        }
        $threw | Should Be $true
    }

    It "rejects too-short timeout" {
        $threw = $false
        try {
            Invoke-ClaudeCli -Prompt "test" -TimeoutSeconds 1
        } catch {
            $threw = $true
        }
        $threw | Should Be $true
    }

    It "rejects too-long timeout" {
        $threw = $false
        try {
            Invoke-ClaudeCli -Prompt "test" -TimeoutSeconds 9999
        } catch {
            $threw = $true
        }
        $threw | Should Be $true
    }
}
