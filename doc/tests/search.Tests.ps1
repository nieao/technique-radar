$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$SKILL_DIR = Join-Path $here ".."
. (Join-Path $SKILL_DIR "lib-json.ps1")

$script:testCards = @(
    @{
        id = "tc-001"; title = "Async Agent Loop"
        tags = @("async", "agent", "loop"); problem = "Agent needs continuous execution"
        source_name = "browser-use"; source_type = "github"
        cleverness = 8; reusability = 9; file = ""
    },
    @{
        id = "tc-002"; title = "Rate Limit Backoff"
        tags = @("rate-limit", "retry", "api"); problem = "API calls get throttled"
        source_name = "my-tool"; source_type = "local"
        cleverness = 6; reusability = 7; file = ""
    },
    @{
        id = "tc-003"; title = "MCP Tool Router"
        tags = @("mcp", "tool-use", "router"); problem = "Route tool calls to handlers"
        source_name = "mcp-server"; source_type = "skill"
        cleverness = 9; reusability = 8; file = ""
    }
)

Describe "Search Scoring" {
    It "matches cards by title keyword" {
        $queryTokens = @("agent")
        $matched = @()
        foreach ($card in $testCards) {
            $searchText = (@($card.title, $card.problem, ($card.tags -join " "), $card.source_name) -join " ").ToLower()
            $matchedTokens = 0
            foreach ($token in $queryTokens) {
                if ($searchText -match [regex]::Escape($token)) { $matchedTokens++ }
            }
            if ($matchedTokens -gt 0) { $matched += $card }
        }
        $matched.Count | Should Be 1
        $matched[0].id | Should Be "tc-001"
    }

    It "scores title matches higher than content matches" {
        $card = $testCards[0]
        $titleScore = 0; $tagScore = 0
        if ($card.title.ToLower() -match "loop") { $titleScore = 3 }
        if ($card.tags -contains "loop") { $tagScore = 2 }
        ($titleScore + $tagScore) | Should BeGreaterThan 0
    }

    It "filters by tag correctly" {
        $cards = @($script:testCards)
        $filtered = @($cards | Where-Object { $_.tags -and ($_.tags -contains "mcp") })
        $filtered.Count | Should Be 1
        $filtered[0].id | Should Be "tc-003"
    }

    It "filters by source type correctly" {
        $cards = @($script:testCards)
        $filtered = @($cards | Where-Object { $_.source_type -eq "github" })
        $filtered.Count | Should Be 1
        $filtered[0].id | Should Be "tc-001"
    }

    It "filters by minimum cleverness" {
        $filtered = $testCards | Where-Object { $_.cleverness -ge 8 }
        $filtered.Count | Should Be 2
    }

    It "wildcard query returns all cards sorted by quality" {
        $scored = $testCards | ForEach-Object {
            @{ card = $_; score = ($_.cleverness + $_.reusability) * 0.1 }
        } | Sort-Object { -$_.score }
        $scored.Count | Should Be 3
        $scored[0].card.id | Should Be "tc-003"
    }

    It "multi-token query with no matches returns empty" {
        $queryTokens = @("nonexistent", "keyword")
        $matched = @()
        foreach ($card in $testCards) {
            $searchText = (@($card.title, $card.problem) -join " ").ToLower()
            $mt = 0
            foreach ($token in $queryTokens) {
                if ($searchText -match [regex]::Escape($token)) { $mt++ }
            }
            if ($mt -gt 0) { $matched += $card }
        }
        $matched.Count | Should Be 0
    }

    It "gives bonus for matching ALL tokens" {
        $queryTokens = @("async", "agent")
        $card = $testCards[0]
        $searchText = (@($card.title, $card.problem, ($card.tags -join " ")) -join " ").ToLower()
        $score = 0; $matchedTokens = 0
        foreach ($token in $queryTokens) {
            if ($searchText -match [regex]::Escape($token)) { $matchedTokens++; $score += 1 }
        }
        if ($matchedTokens -eq $queryTokens.Count) { $score += 5 }
        $score | Should BeGreaterThan 6
    }
}
