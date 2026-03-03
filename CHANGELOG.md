# Changelog

## v1.3.0 — 2026-03-03 (AAA Security & Architecture Overhaul)

### Added
- `lib-claude.ps1` — Shared Claude CLI invocation utility with input validation
  - `Invoke-ClaudeCli` — Centralized CLI wrapper with timeout, cleanup, error handling
  - `Test-SourceInput` — Source string validator rejecting shell injection attacks
- `tests/lib-claude.Tests.ps1` — Security validation tests (12 test cases)
- `tests/discover.Tests.ps1` — Candidate management, dedup, scoring tests (14 test cases)
- `tests/daily-pipeline.Tests.ps1` — Pipeline filtering, summary, status tests (10 test cases)
- `tests/deploy.Tests.ps1` — File list completeness, directory structure tests (5 test cases)

### Security
- **Input validation**: All source inputs now pass through `Test-SourceInput` before processing
- **Injection prevention**: Rejects shell metacharacters (`;`, `|`, `` ` ``, `$`) in source strings
- **Temp file isolation**: Claude prompts use GUID-named temp files, cleaned up in `finally` block
- **Path sanitization**: Prompt file paths checked for unsafe characters before cmd.exe execution

### Improved
- **Architecture**: Extracted duplicated Claude CLI invocation from analyze.ps1 + discover.ps1 into shared lib-claude.ps1
- **Maintainability**: Magic numbers replaced with named constants ($MAX_FILE_CHARS, $MAX_TOTAL_CHARS, $MIN_CARD_LENGTH)
- **Type safety**: All new functions have [CmdletBinding()], [OutputType()], [ValidateRange()], [ValidateNotNullOrEmpty()]
- **Test coverage**: 31 → 74 tests across 7 test suites (lib-json, lib-claude, analyze, search, discover, daily-pipeline, deploy)
- **Error handling**: Process.Start failure handling, proper finally/Dispose pattern, graceful timeout recovery
- deploy.ps1 updated with lib-claude.ps1 in copy list

## v1.2.0 — 2026-03-03 (Auto-Pipeline Optimization)

### Added
- `lib-json.ps1` — Shared JSON read/write utility library (Read-JsonArray, Write-JsonArray)
- `tests/lib-json.Tests.ps1` — Pester unit tests for JSON utilities (10 test cases)
- `tests/analyze.Tests.ps1` — Pester tests for New-CardId, Get-ShortHash, source detection (12 test cases)
- `tests/search.Tests.ps1` — Pester tests for search scoring logic (8 test cases)
- CHANGELOG.md — Version history

### Fixed
- **[analyze.ps1] Get-SkillMaterial duplicate path** — Fallback now checks `.claude/skills` instead of duplicating `.openclaw/skills`
- **[analyze.ps1] PS5.1 compatibility** — Replaced `if` expression assignment with traditional variable assignment pattern
- **[discover.ps1] Null reference risk** — Safe description extraction with explicit null check before `.Substring()`
- **[discover.ps1] Multi-key sorting** — Replaced positional ScriptBlock args with explicit `@{ Expression; Ascending/Descending }` hashtable syntax
- **[daily-pipeline.ps1] JSON array serialization** — Replaced inline `@() | ConvertTo-Json` with `Write-JsonArray` ensuring consistent array output
- **[deploy.ps1] Missing self-deployment** — Added `deploy.ps1` and `lib-json.ps1` to `$filesToCopy`
- **[search.ps1] Redundant pipeline** — Simplified `ForEach-Object { $_.ToLower() }` to direct `.ToLower()` call

### Improved
- Eliminated 6+ instances of duplicate JSON read/write boilerplate across all scripts
- All scripts now dot-source `lib-json.ps1` for consistent JSON handling
- Sort-Object calls use explicit hashtable syntax for predictable multi-key sorting

## v1.1.0 — 2026-03-03 (Stability Fixes)

### Fixed
- fix(analyze): correct dedup condition precedence with -Force
- fix(search): handle wildcard query without token short-circuit
- fix(pipeline): normalize json loading for object/array compatibility
- docs(skill): add -NoProfile to PowerShell usage examples
- fix(analyze): remove dead Get-SourceHash, clear CLAUDECODE, force array json
- fix(discover): init relevance_score default, clear CLAUDECODE, rate-limit backoff
- fix(pipeline): force array json output for candidates file

## v1.0.0 — 2026-03-02 (Initial Release)

### Added
- analyze.ps1 — Source analysis engine with Claude CLI integration
- discover.ps1 — GitHub API repo discovery with AI pre-scoring
- search.ps1 — Full-text knowledge base search with scoring
- daily-pipeline.ps1 — Automated daily discovery + analysis pipeline
- deploy.ps1 — One-click deployment script
- SKILL.md — Complete skill documentation
