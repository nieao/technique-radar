@{
    # PSScriptAnalyzer settings for Technique Radar
    # This is a CLI tool — Write-Host is the intended output mechanism
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',           # CLI tool outputs to console by design
        'PSUseShouldProcessForStateChangingFunctions',  # Internal helper functions
        'PSUseApprovedVerbs',              # Internal private functions (Parse-Cards, Build-AnalysisPrompt, Collect-SourceFiles)
        'PSUseSingularNouns'               # Cards/Files are natural plural names in this context
    )

    Severity = @('Error', 'Warning')
}
