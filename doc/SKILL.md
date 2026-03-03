---
name: technique-radar
description: Automated technique discovery, extraction, and knowledge management system. Analyzes GitHub repos, local code, and OpenClaw skills to extract reusable technique cards. Use when user says "analyze repo", "extract techniques", "scan code", "search techniques", "discover new repos", "技术雷达", "分析代码", "提取技巧", "搜索技巧". Supports three modes - discover (find new repos), analyze (extract technique cards), search (query knowledge base).
---

# Technique Radar

An automated pipeline for discovering, analyzing, and cataloging reusable code patterns, agent architectures, and engineering techniques from any source.

## Architecture

```
Sources                    Analyzer                   Knowledge Base
---------                  --------                   --------------
GitHub repos  ──┐
Local code    ──┼──► analyze.ps1 ──► Claude ──► cards\*.md + index.json
OpenClaw skills─┘                                      │
                                                       ▼
discover.ps1 ──► GitHub API ──► candidates.json    search.ps1
(scheduled)                                        (on-demand query)
```

## When to Use

- User wants to analyze a GitHub repo or local codebase for reusable patterns
- User wants to discover trending repos in AI/agent/automation space
- User wants to search their existing technique knowledge base
- Scheduled daily discovery of new interesting repos

## Usage

### Mode 1: Analyze a Source

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\nieao\.openclaw\skills\technique-radar\analyze.ps1" -Source "https://github.com/user/repo" -Timeout 180
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\nieao\.openclaw\skills\technique-radar\analyze.ps1" -Source "C:\Projects\my-agent" -Timeout 180
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\nieao\.openclaw\skills\technique-radar\analyze.ps1" -Source "skill:openclaw-skill-authoring" -Timeout 120
```

### Mode 2: Discover New Repos

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\nieao\.openclaw\skills\technique-radar\discover.ps1" -Topics "ai-agent,mcp-server,automation" -Timeout 120
```

### Mode 3: Search Knowledge Base

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\nieao\.openclaw\skills\technique-radar\search.ps1" -Query "async pattern agent" -TopN 10
```

### Mode 4: Batch Analyze All Skills

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\nieao\.openclaw\skills\technique-radar\analyze.ps1" -Source "skill:*" -Timeout 300
```

## Parameters

### analyze.ps1

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| -Source | Yes | - | GitHub URL, local path, or `skill:<name>` (use `skill:*` for all) |
| -Timeout | No | 180 | Seconds before timeout |
| -MaxFiles | No | 20 | Max source files to analyze per source |
| -Force | No | false | Re-analyze even if cards already exist for this source |

### discover.ps1

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| -Topics | No | ai-agent,mcp-server,tool-use,automation,claude | Comma-separated GitHub topics |
| -Since | No | 7 | Days to look back |
| -MinStars | No | 10 | Minimum stars filter |
| -Timeout | No | 120 | Seconds before timeout |

### search.ps1

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| -Query | Yes | - | Search keywords (space-separated, AND logic) |
| -TopN | No | 10 | Max results |
| -Tag | No | - | Filter by specific tag |
| -SourceType | No | - | Filter: github, local, skill |

## Project Files

| File | Content |
|------|---------|
| `analyze.ps1` | Source code analyzer (Claude CLI integration) |
| `discover.ps1` | GitHub API repo discovery |
| `search.ps1` | Local knowledge base search |
| `daily-pipeline.ps1` | Daily automation pipeline |
| `deploy.ps1` | One-click deployment |
| `lib-json.ps1` | Shared JSON read/write utilities |
| `lib-claude.ps1` | Shared Claude CLI invocation + input validation |
| `PSScriptAnalyzerSettings.psd1` | Static analysis rules configuration |
| `tests\*.Tests.ps1` | Pester unit tests (7 suites, 82 tests) |

## Result Files

| File | Content |
|------|---------|
| `cards\<source-type>\<id>.md` | Individual technique cards in markdown |
| `index.json` | Searchable index of all cards with metadata |
| `candidates.json` | Discovered repos pending analysis |
| `latest-meta.json` | Last operation status and timing |

## Running Tests

```powershell
# Run all Pester tests (works with Pester v3+)
Invoke-Pester -Path "doc\tests" -Verbose

# Run specific test file
Invoke-Pester -Path "doc\tests\lib-json.Tests.ps1" -Verbose

# Run PSScriptAnalyzer (static analysis)
Invoke-ScriptAnalyzer -Path doc/ -Recurse -Settings doc/PSScriptAnalyzerSettings.psd1
```

## CI/CD

GitHub Actions automatically runs on push/PR to main:
- PSScriptAnalyzer static analysis (zero warnings required)
- Pester test suite (82 tests, zero failures required)

Config: `.github/workflows/test.yml`

## Technique Card Format

Each card follows this structure:

```markdown
---
id: tc-20260303-001
title: Descriptive technique name
source_type: github | local | skill
source: URL or path
source_name: Short display name
tags: [tag1, tag2, tag3]
problem: One-line problem statement
cleverness: 1-10 rating of how novel/clever the technique is
reusability: 1-10 rating of how broadly applicable it is
discovered: 2026-03-03
---

## Problem
What challenge does this technique address?

## Technique
Core insight and approach.

## Code
Minimal code snippet demonstrating the technique.

## Why It's Clever
What makes this non-obvious or particularly elegant.

## When To Use
Concrete scenarios where you'd reach for this pattern.

## Adaptations
How to modify this for different contexts.
```
