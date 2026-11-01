# Checks which upstream paths auto-sync holds back for review (docs/specs/SPEC-review-guard.md).
# Run: powershell -NoProfile -File tests/review-guard.tests.ps1
$ErrorActionPreference = 'Stop'

$bootstrap = Join-Path $PSScriptRoot '..\bootstrap.ps1'
$line = Select-String -Path $bootstrap -Pattern '^\$reviewPattern\s*=' | Select-Object -First 1
if (-not $line) { throw '$reviewPattern not found in bootstrap.ps1' }
$reviewPattern = $null
Invoke-Expression $line.Line

$cases = [ordered]@{
  'bootstrap.ps1'                              = $true
  'global/settings.base.json'                  = $true
  'global/statusline.js'                       = $true
  'plugins/toolkit/hooks/hooks.json'           = $true
  'plugins/toolkit/scripts/dream-digest.mjs'   = $true
  'plugins/toolkit/skills/x/run.py'            = $true
  'plugins/toolkit/scripts/sync.sh'            = $true
  'plugins/toolkit/commands/dream.md'          = $false
  'plugins/toolkit/skills/humanizer/SKILL.md'  = $false
  'plugins/toolkit/.claude-plugin/plugin.json' = $false
  'global/CLAUDE.md'                           = $false
  'README.md'                                  = $false
  'tests/review-guard.tests.ps1'               = $false
}

$failed = 0
foreach ($path in $cases.Keys) {
  $held = $path -match $reviewPattern
  if ($held -ne $cases[$path]) {
    $failed++
    Write-Host "FAIL $path (held: $held, expected: $($cases[$path]))"
  }
}

if ($failed) { Write-Host "$failed of $($cases.Count) failed"; exit 1 }
Write-Host "all $($cases.Count) passed"
