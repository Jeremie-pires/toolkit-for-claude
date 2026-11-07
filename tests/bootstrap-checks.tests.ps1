# Checks the bootstrap.ps1 warnings for dead permission rules and shadowed skills.
# Run: powershell -NoProfile -File tests/bootstrap-checks.tests.ps1
$ErrorActionPreference = 'Stop'

# Load only the functions under test, so the script itself never runs
$bootstrap = Join-Path $PSScriptRoot '..\bootstrap.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($bootstrap, [ref]$null, [ref]$null)
foreach ($name in 'HasProp', 'Find-MidWildcardRules', 'Find-ShadowedSkills', 'Set-ConfigDirPaths', 'Get-HeldChanges') {
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

function NewBase {
  [pscustomobject]@{
    statusLine  = [pscustomobject]@{ type = 'command'; command = 'node "$HOME/.claude/statusline.js"' }
    permissions = [pscustomobject]@{ deny = @('Read(~/.claude/settings.json.bak-*)', 'Read(.env)') }
  }
}
$base = NewBase
Set-ConfigDirPaths $base 'D:\Claude\work\'
Check 'Windows config dir: status line command' $base.statusLine.command 'node "D:/Claude/work/statusline.js"'
Check 'Windows config dir: absolute rule, other rules kept' $base.permissions.deny @('Read(//d/Claude/work/settings.json.bak-*)', 'Read(.env)')
$base = NewBase
Set-ConfigDirPaths $base '/home/u/.claude-work'
Check 'POSIX config dir: absolute rule' $base.permissions.deny[0] 'Read(//home/u/.claude-work/settings.json.bak-*)'

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

  # A clone with an upstream: only files changed upstream since the common commit are held.
  # Windows PowerShell turns git's stderr into errors under 'Stop'; bootstrap.ps1 runs with 'Continue' too.
  $ErrorActionPreference = 'Continue'
  $origin = Join-Path $root 'origin.git'
  $clone = Join-Path $root 'clone'
  $other = Join-Path $root 'other'
  function Commit($repo, $file) {
    Set-Content (Join-Path $repo $file) (Get-Random)
    $null = & git -C $repo add $file 2>&1
    $null = & git -C $repo -c user.name=t -c user.email=t@t commit -q -m $file 2>&1
  }
  $null = & git init -q --bare $origin 2>&1
  $null = & git clone -q $origin $clone 2>&1
  Commit $clone 'README.md'
  $null = & git -C $clone push -q origin HEAD 2>&1
  $null = & git clone -q $origin $other 2>&1

  Commit $clone 'bootstrap.ps1'
  Check 'local unpushed change is not held' (Get-HeldChanges $clone '^bootstrap\.ps1$') @()

  Commit $other 'bootstrap.ps1'
  $null = & git -C $other push -q origin HEAD 2>&1
  $null = & git -C $clone fetch -q 2>&1
  Check 'upstream change is held, even when local commits exist' (Get-HeldChanges $clone '^bootstrap\.ps1$') @('bootstrap.ps1')
} finally {
  Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed) { Write-Host "$failed of $total failed"; exit 1 }
Write-Host "all $total passed"
