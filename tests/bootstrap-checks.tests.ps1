# Checks the bootstrap.ps1 warnings for dead permission rules and shadowed skills.
# Run: powershell -NoProfile -File tests/bootstrap-checks.tests.ps1
$ErrorActionPreference = 'Stop'

# Load only the functions under test, so the script itself never runs
$bootstrap = Join-Path $PSScriptRoot '..\bootstrap.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($bootstrap, [ref]$null, [ref]$null)
foreach ($name in 'HasProp', 'Find-MidWildcardRules', 'Find-ShadowedSkills') {
  $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
  if (-not $fn) { throw "$name not found in bootstrap.ps1" }
  Invoke-Expression $fn.Extent.Text
}

$failed = 0
$total = 0
function Check($label, $actual, $expected) {
  $script:total++
  $a = @($actual) -join ', '
  $e = @($expected) -join ', '
  if ($a -ne $e) { $script:failed++; Write-Host "FAIL $label (got: '$a', expected: '$e')" }
}

$permissions = [pscustomobject]@{
  allow = @('Bash(ls:*)', 'Bash(git:* push)', 'Bash(npm run *)', 'WebFetch(domain:*.example.com)', 'Agent(isolation:*)')
  deny  = @('Bash(rm:* -rf)')
}
Check 'mid-pattern :* is flagged, trailing :* and non-Bash rules are not' (Find-MidWildcardRules $permissions) @('Bash(git:* push)', 'Bash(rm:* -rf)')
Check 'no permission lists' (Find-MidWildcardRules ([pscustomobject]@{})) @()

$root = Join-Path ([IO.Path]::GetTempPath()) "bootstrap-checks-$PID"
try {
  $kit = Join-Path $root 'kit'
  $userSkills = Join-Path $root 'skills'
  foreach ($d in 'plugins\toolkit\skills\humanizer', 'plugins\toolkit\skills\references') { New-Item -ItemType Directory -Force (Join-Path $kit $d) | Out-Null }
  foreach ($d in 'humanizer', 'references', 'mine') { New-Item -ItemType Directory -Force (Join-Path $userSkills $d) | Out-Null }
  # 'references' has no SKILL.md, so it is not a skill
  foreach ($d in 'humanizer', 'mine') { Set-Content (Join-Path $userSkills "$d\SKILL.md") 'x' }

  Check 'user skill named like a kit skill is flagged' (Find-ShadowedSkills $userSkills $kit) @('humanizer')
  Check 'missing user skills folder' (Find-ShadowedSkills (Join-Path $root 'none') $kit) @()
} finally {
  Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed) { Write-Host "$failed of $total failed"; exit 1 }
Write-Host "all $total passed"
