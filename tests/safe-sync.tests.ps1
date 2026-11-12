# Checks that auto-sync brings in upstream changes without losing local work (docs/specs/SPEC-safe-sync.md).
# Run: powershell -NoProfile -File tests/safe-sync.tests.ps1
# Windows PowerShell turns git's stderr into errors under 'Stop'; bootstrap.ps1 runs with 'Continue' too.
$ErrorActionPreference = 'Continue'

# Load only the functions under test, so the script itself never runs
$bootstrap = Join-Path $PSScriptRoot '..\bootstrap.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($bootstrap, [ref]$null, [ref]$null)
foreach ($name in 'Get-HeldChanges', 'Find-PendingAutostash', 'Write-AutostashWarning', 'Update-KitClone', 'Get-RulesHint', 'Initialize-RulesDir', 'FileHash', 'Read-TextLF', 'TextHash', 'Backup', 'Get-GitBytes', 'Find-BaseInHistory', 'Save-KitBase', 'Write-KitFile', 'Invoke-MergeFile', 'Test-ScriptSyntax', 'Merge-KitFile', 'Test-PluginBehind', 'Get-WarningText', 'Get-HookContext') {
  $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
  if (-not $fn) { throw "$name not found in bootstrap.ps1" }
  Invoke-Expression $fn.Extent.Text
}
$line = Select-String -Path $bootstrap -Pattern '^\$reviewPattern\s*=' | Select-Object -First 1
Invoke-Expression $line.Line

# Script-scope values the functions read, as in bootstrap.ps1
$Apply = $true
$Quiet = $true
$stamp = 'test'
$keepBackups = 5
$warnings = New-Object System.Collections.Generic.List[string]
$said = New-Object System.Collections.Generic.List[string]
function Say($m) { $said.Add($m) }
function Warn($m) { $warnings.Add($m) }

$failed = 0
$total = 0
function Check($label, $actual, $expected) {
  $script:total++
  $a = @($actual) -join ', '
  $e = @($expected) -join ', '
  if ($a -ne $e) { $script:failed++; Write-Host "FAIL $label (got: '$a', expected: '$e')" }
}

$root = Join-Path ([IO.Path]::GetTempPath()) "safe-sync-$PID"
$utf8 = New-Object System.Text.UTF8Encoding($false)

# Same results whatever the machine's git config: no global or system file, no line-ending conversion
$emptyConfig = Join-Path ([IO.Path]::GetTempPath()) "safe-sync-$PID.gitconfig"
[IO.File]::WriteAllText($emptyConfig, '', $utf8)
$env:GIT_CONFIG_GLOBAL = $emptyConfig
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'core.autocrlf'
$env:GIT_CONFIG_VALUE_0 = 'false'
foreach ($v in 'GIT_AUTHOR_NAME', 'GIT_COMMITTER_NAME') { Set-Item "env:$v" 't' }
foreach ($v in 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_EMAIL') { Set-Item "env:$v" 't@t' }

function RunGit($repo) { $out = & git -C $repo @args 2>&1; if ($LASTEXITCODE -ne 0) { throw "git $args failed: $out" }; $out }
function WriteFile($repo, $file, $text) { [IO.File]::WriteAllText((Join-Path $repo $file), $text, $utf8) }
function ReadFile($repo, $file) { [IO.File]::ReadAllText((Join-Path $repo $file), $utf8) }
function CommitFile($repo, $file, $text) {
  WriteFile $repo $file $text
  $null = RunGit $repo add $file
  $null = RunGit $repo commit -q -m $file
}
$lines = "1`n2`n3`n4`n5`n"

# A bare upstream, a "dev" clone that pushes upstream changes, and the kit clone under test
function NewFixture($name) {
  $dir = Join-Path $root $name
  New-Item -ItemType Directory -Force $dir | Out-Null
  $up = Join-Path $dir 'up.git'
  $null = & git init -q --bare -b main $up 2>&1
  $dev = Join-Path $dir 'dev'
  $null = & git clone -q $up $dev 2>&1
  CommitFile $dev 'a.txt' $lines
  $null = RunGit $dev push -q origin HEAD:main
  $kit = Join-Path $dir 'kit'
  $null = & git clone -q $up $kit 2>&1
  [pscustomobject]@{ dev = $dev; kit = $kit }
}
function PushUpstream($f, $file, $text) {
  CommitFile $f.dev $file $text
  $null = RunGit $f.dev push -q origin HEAD:main
}
# What a failed update must leave exactly as it was
function Snapshot($repo) {
  @((RunGit $repo rev-parse HEAD), (RunGit $repo status --porcelain), (RunGit $repo stash list)) -join '|'
}
function Run($f) {
  $warnings.Clear()
  Update-KitClone $f.kit
}
# Runs the real script as the hooks do; stdout and stderr kept apart and decoded as UTF-8
function RunBootstrap([string[]]$scriptArgs) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell'
  $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$bootstrap`"") + $scriptArgs) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $utf8
  $psi.StandardErrorEncoding = $utf8
  $p = [Diagnostics.Process]::Start($psi)
  $errTask = $p.StandardError.ReadToEndAsync()
  $out = $p.StandardOutput.ReadToEnd()
  $p.WaitForExit()
  [pscustomobject]@{ code = $p.ExitCode; out = $out.Trim(); err = $errTask.Result.Trim() }
}

try {
  New-Item -ItemType Directory -Force $root | Out-Null

  # Clean clone: plain fast-forward
  $f = NewFixture 'clean'
  PushUpstream $f 'a.txt' "1 up`n2`n3`n4`n5`n"
  $r = Run $f
  Check 'clean: HEAD at upstream' (RunGit $f.kit rev-parse HEAD) (RunGit $f.kit rev-parse '@{u}')
  Check 'clean: pulled' $r.pulled $true
  Check 'clean: updated' $r.updated $true
  Check 'clean: no warning' $warnings.Count 0

  # Local commit, no conflict: replayed on top of upstream
  $f = NewFixture 'local-commit'
  CommitFile $f.kit 'b.txt' 'mine'
  PushUpstream $f 'a.txt' "1 up`n2`n3`n4`n5`n"
  $r = Run $f
  Check 'local commit: upstream is an ancestor' $(& git -C $f.kit merge-base --is-ancestor '@{u}' HEAD 2>&1; $LASTEXITCODE) 0
  Check 'local commit: one commit ahead' (RunGit $f.kit rev-list --count '@{u}..HEAD') '1'
  Check 'local commit: local file kept' (ReadFile $f.kit 'b.txt') 'mine'
  Check 'local commit: upstream change in' (ReadFile $f.kit 'a.txt') "1 up`n2`n3`n4`n5`n"
  Check 'local commit: no warning' $warnings.Count 0

  # Uncommitted edit to a tracked file, no conflict: still uncommitted afterwards
  $f = NewFixture 'uncommitted'
  WriteFile $f.kit 'a.txt' "1`n2`n3`n4`n5 mine`n"
  PushUpstream $f 'a.txt' "1 up`n2`n3`n4`n5`n"
  $r = Run $f
  Check 'uncommitted: HEAD at upstream' (RunGit $f.kit rev-parse HEAD) (RunGit $f.kit rev-parse '@{u}')
  Check 'uncommitted: both edits in the file' (ReadFile $f.kit 'a.txt') "1 up`n2`n3`n4`n5 mine`n"
  Check 'uncommitted: edit still uncommitted' (RunGit $f.kit status --porcelain) ' M a.txt'
  Check 'uncommitted: stash empty' @(RunGit $f.kit stash list).Count 0
  Check 'uncommitted: no warning' $warnings.Count 0

  # Untracked files are left alone
  $f = NewFixture 'untracked'
  New-Item -ItemType Directory -Force (Join-Path $f.kit 'assets') | Out-Null
  WriteFile $f.kit 'assets\logo.txt' 'logo'
  PushUpstream $f 'a.txt' "1 up`n2`n3`n4`n5`n"
  $r = Run $f
  Check 'untracked: HEAD at upstream' (RunGit $f.kit rev-parse HEAD) (RunGit $f.kit rev-parse '@{u}')
  Check 'untracked: file kept' (ReadFile $f.kit 'assets\logo.txt') 'logo'
  Check 'untracked: no warning' $warnings.Count 0

  # Local commit that conflicts: clone exactly as before, one warning
  $f = NewFixture 'commit-conflict'
  CommitFile $f.kit 'a.txt' "1 mine`n2`n3`n4`n5`n"
  WriteFile $f.kit 'notes.txt' 'draft'
  PushUpstream $f 'a.txt' "1 up`n2`n3`n4`n5`n"
  $null = RunGit $f.kit fetch -q
  $before = Snapshot $f.kit
  $r = Run $f
  Check 'commit conflict: clone unchanged' (Snapshot $f.kit) $before
  Check 'commit conflict: no rebase left in progress' (Test-Path (Join-Path $f.kit '.git\rebase-merge')) $false
  Check 'commit conflict: not updated' $r.updated $false
  Check 'commit conflict: one warning' $warnings.Count 1

  # Local commit that conflicts, plus an uncommitted edit elsewhere: the abort brings the edit back
  $f = NewFixture 'commit-conflict-dirty'
  CommitFile $f.kit 'b.txt' 'base'
  $null = RunGit $f.kit push -q origin HEAD:main
  $null = RunGit $f.dev pull -q
  CommitFile $f.kit 'a.txt' "1 mine`n2`n3`n4`n5`n"
  WriteFile $f.kit 'b.txt' 'edited'
  PushUpstream $f 'a.txt' "1 up`n2`n3`n4`n5`n"
  $null = RunGit $f.kit fetch -q
  $before = Snapshot $f.kit
  $r = Run $f
  Check 'conflict with edit: clone unchanged' (Snapshot $f.kit) $before
  Check 'conflict with edit: edit kept' (ReadFile $f.kit 'b.txt') 'edited'
  Check 'conflict with edit: one warning' $warnings.Count 1

  # Untracked file in the way of an incoming one: clone exactly as before, one warning
  $f = NewFixture 'untracked-in-the-way'
  WriteFile $f.kit 'new.txt' 'mine'
  PushUpstream $f 'new.txt' 'upstream'
  $null = RunGit $f.kit fetch -q
  $before = Snapshot $f.kit
  $r = Run $f
  Check 'untracked in the way: clone unchanged' (Snapshot $f.kit) $before
  Check 'untracked in the way: file kept' (ReadFile $f.kit 'new.txt') 'mine'
  Check 'untracked in the way: not updated' $r.updated $false
  Check 'untracked in the way: one warning' $warnings.Count 1

  # Upstream change to a file that runs code: held in -Quiet mode, as before
  $f = NewFixture 'held'
  PushUpstream $f 'bootstrap.ps1' 'code'
  $headBefore = RunGit $f.kit rev-parse HEAD
  $r = Run $f
  Check 'held: HEAD unchanged' (RunGit $f.kit rev-parse HEAD) $headBefore
  Check 'held: not updated' $r.updated $false
  Check 'held: warning names the file' ($warnings[0] -match 'bootstrap\.ps1') $true

  # Uncommitted edit that conflicts when the autostash is re-applied: git keeps it in the stash
  $f = NewFixture 'autostash-conflict'
  WriteFile $f.kit 'a.txt' "1 mine`n2`n3`n4`n5`n"
  PushUpstream $f 'a.txt' "1 up`n2`n3`n4`n5`n"
  $r = Run $f
  Check 'autostash conflict: stash pending' $r.stashPending $true
  Check 'autostash conflict: edit is in the stash' ((RunGit $f.kit stash show -p 'stash@{0}') -join "`n" -match '\+1 mine') $true
  Check 'autostash conflict: one warning' $warnings.Count 1
  Check 'autostash conflict: warning names the file and stash drop' ($warnings[0] -match 'a\.txt.*stash@\{0\}.*stash drop stash@\{0\}') $true
  Check 'autostash conflict: git leaves markers in the tree' ((ReadFile $f.kit 'a.txt') -match '<<<<<<<') $true

  # Next run with the stash still there: same warning, no update, no new stash entry
  PushUpstream $f 'c.txt' 'more'
  $headBefore = RunGit $f.kit rev-parse HEAD
  $stashBefore = @(RunGit $f.kit stash list).Count
  $r = Run $f
  Check 'pending at start: stash pending' $r.stashPending $true
  Check 'pending at start: HEAD unchanged' (RunGit $f.kit rev-parse HEAD) $headBefore
  Check 'pending at start: no new stash entry' @(RunGit $f.kit stash list).Count $stashBefore
  Check 'pending at start: one warning' $warnings.Count 1
  Check 'pending at start: warning names stash drop' ($warnings[0] -match 'stash drop') $true

  # Following the warning's steps unblocks the next update
  WriteFile $f.kit 'a.txt' "1 up and mine`n2`n3`n4`n5`n"
  $null = RunGit $f.kit reset -q
  $null = RunGit $f.kit stash drop -q 'stash@{0}'
  $r = Run $f
  Check 'after recovery: not pending' $r.stashPending $false
  Check 'after recovery: updated' $r.updated $true
  Check 'after recovery: resolved edit kept' (ReadFile $f.kit 'a.txt') "1 up and mine`n2`n3`n4`n5`n"
  Check 'after recovery: no warning' $warnings.Count 0

  # A stash the user made by hand is not the kit's business
  $f = NewFixture 'user-stash'
  WriteFile $f.kit 'a.txt' "1 mine`n2`n3`n4`n5`n"
  $null = RunGit $f.kit stash push -q -m 'my work'
  PushUpstream $f 'a.txt' "1 up`n2`n3`n4`n5`n"
  $r = Run $f
  Check 'user stash: not pending' $r.stashPending $false
  Check 'user stash: updated' $r.updated $true
  Check 'user stash: stash kept' @(RunGit $f.kit stash list).Count 1
  Check 'user stash: no warning' $warnings.Count 0

  # Preview: fetch only, report what -Apply would do, leave the clone as it was
  $Apply = $false
  $f = NewFixture 'preview-rebase'
  CommitFile $f.kit 'b.txt' 'mine'
  WriteFile $f.kit 'a.txt' "1`n2`n3`n4`n5 mine`n"
  PushUpstream $f 'a.txt' "1 up`n2`n3`n4`n5`n"
  $null = RunGit $f.kit fetch -q
  $before = Snapshot $f.kit
  $said.Clear()
  $r = Run $f
  Check 'preview rebase: clone unchanged' (Snapshot $f.kit) $before
  Check 'preview rebase: not updated' $r.updated $false
  Check 'preview rebase: says what it would do' ($said -match 'would rebase') @('~ would rebase 1 local commit(s) onto 1 upstream commit(s), carrying uncommitted edits')
  Check 'preview rebase: no warning' $warnings.Count 0

  $f = NewFixture 'preview-ff'
  PushUpstream $f 'a.txt' "1 up`n2`n3`n4`n5`n"
  $headBefore = RunGit $f.kit rev-parse HEAD
  $said.Clear()
  $r = Run $f
  Check 'preview ff: HEAD unchanged' (RunGit $f.kit rev-parse HEAD) $headBefore
  Check 'preview ff: says it would fast-forward' ($said -match 'would fast-forward') @('~ would fast-forward the kit by 1 upstream commit(s)')
  $Apply = $true

  # rules-home: the folder for machine-local content is created, never written inside
  $claude = Join-Path $root 'config'
  New-Item -ItemType Directory -Force $claude | Out-Null
  $rules = Join-Path $claude 'rules'
  $Apply = $false
  $said.Clear()
  Initialize-RulesDir $claude
  Check 'rules preview: not created' (Test-Path $rules) $false
  Check 'rules preview: says it would create it' ($said -match 'would create') @("~ would create $rules")
  $Apply = $true
  Initialize-RulesDir $claude
  Check 'rules apply: created' (Test-Path $rules -PathType Container) $true
  Check 'rules apply: empty' @(Get-ChildItem $rules -Force).Count 0

  WriteFile $rules 'personal.md' '- Chat language: French.'
  $stampBefore = (Get-Item (Join-Path $rules 'personal.md')).LastWriteTimeUtc
  $listBefore = (Get-ChildItem $rules -Force | ForEach-Object { "$($_.Name)=$((Get-FileHash $_.FullName).Hash)" }) -join ','
  Initialize-RulesDir $claude
  Check 'rules existing: same files and hashes' ((Get-ChildItem $rules -Force | ForEach-Object { "$($_.Name)=$((Get-FileHash $_.FullName).Hash)" }) -join ',') $listBefore
  Check 'rules existing: timestamp unchanged' (Get-Item (Join-Path $rules 'personal.md')).LastWriteTimeUtc $stampBefore

  # The local-edit warning points at the rules folder
  $src = Join-Path $root 'kit-CLAUDE.md'
  $dst = Join-Path $claude 'CLAUDE.md'
  [IO.File]::WriteAllText($src, 'kit v2', $utf8)
  [IO.File]::WriteAllText($dst, 'kit v1 + my edit', $utf8)
  $applied = @{ 'CLAUDE.md' = 'HASH-OF-KIT-V1' }
  $warnings.Clear()
  # Not a git repo: the history lookup finds nothing
  $KitDir = $claude
  Merge-KitFile $src $dst 'CLAUDE.md'
  Check 'local edit: one warning' $warnings.Count 1
  Check 'local edit: warning ends with the rules hint' ($warnings[0].EndsWith("machine-local content belongs in $rules")) $true
  Check 'local edit: file kept' ([IO.File]::ReadAllText($dst, $utf8)) 'kit v1 + my edit'

  # file-merge: one folder per case, holding the kit's file, the deployed file and the base copy
  function NewMergeCase($name, $srcText, $dstText, $baseText) {
    $dir = Join-Path $root "merge-$name"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $script:claude = $dir
    $c = [pscustomobject]@{
      src = Join-Path $dir 'kit-CLAUDE.md'; dst = Join-Path $dir 'CLAUDE.md'
      base = Join-Path $dir 'claude-kit-base\CLAUDE.md'; merge = Join-Path $dir 'CLAUDE.md.kit-merge'; dir = $dir
    }
    if ($null -ne $srcText) { [IO.File]::WriteAllText($c.src, $srcText, $utf8) }
    if ($null -ne $dstText) { [IO.File]::WriteAllText($c.dst, $dstText, $utf8) }
    if ($null -ne $baseText) {
      New-Item -ItemType Directory -Force (Split-Path $c.base) | Out-Null
      [IO.File]::WriteAllText($c.base, $baseText, $utf8)
    }
    $script:applied = @{}
    $warnings.Clear()
    $said.Clear()
    $c
  }
  function Text($p) { if (Test-Path $p) { [IO.File]::ReadAllText($p, $utf8) } else { '<missing>' } }
  function Backups($c) { @(Get-ChildItem $c.dir -Filter 'CLAUDE.md.bak-*').Count }
  function Tree($dir) { (Get-ChildItem $dir -Recurse -File | ForEach-Object { "$($_.FullName)=$((Get-FileHash $_.FullName).Hash)" }) -join ',' }
  $v1 = "# rules`nintro`n`nkit line`n`nend`n"

  $c = NewMergeCase 'no-src' $null 'mine' $null
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'merge, src missing: dst untouched' (Text $c.dst) 'mine'
  Check 'merge, src missing: no base' (Test-Path $c.base) $false

  $c = NewMergeCase 'no-dst' $v1 $null $null
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'merge, dst missing: copied' (Text $c.dst) $v1
  Check 'merge, dst missing: base stored' (Text $c.base) $v1
  Check 'merge, dst missing: applied recorded' $applied['CLAUDE.md'] (Get-FileHash $c.dst).Hash

  $c = NewMergeCase 'same' $v1 $v1 $null
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'merge, dst = src: base stored' (Text $c.base) $v1
  Check 'merge, dst = src: no backup' (Backups $c) 0

  $c = NewMergeCase 'kit-unchanged' $v1 "$v1+ my line`n" $v1
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'merge, kit unchanged: dst kept' (Text $c.dst) "$v1+ my line`n"
  Check 'merge, kit unchanged: no warning' $warnings.Count 0

  $v2 = "# rules`nintro v2`n`nkit line`n`nend`n"
  $c = NewMergeCase 'not-edited' $v2 $v1 $v1
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'merge, not edited: replaced' (Text $c.dst) $v2
  Check 'merge, not edited: backup kept' (Backups $c) 1
  Check 'merge, not edited: base moved on' (Text $c.base) $v2

  # Both sides changed, different lines: both land, and a leftover .kit-merge goes away
  $c = NewMergeCase 'clean' $v2 "$v1+ my line`n" $v1
  [IO.File]::WriteAllText($c.merge, 'stale', $utf8)
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'merge, clean: both changes in dst' (Text $c.dst) "# rules`nintro v2`n`nkit line`n`nend`n+ my line`n"
  Check 'merge, clean: backup kept' (Backups $c) 1
  Check 'merge, clean: base moved on' (Text $c.base) $v2
  Check 'merge, clean: applied is the merged file' $applied['CLAUDE.md'] (Get-FileHash $c.dst).Hash
  Check 'merge, clean: stale .kit-merge removed' (Test-Path $c.merge) $false
  Check 'merge, clean: no warning' $warnings.Count 0

  # Next run: kit unchanged since the merge, so the local line stays without a new merge
  $warnings.Clear()
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'merge, clean then rerun: dst kept' (Text $c.dst) "# rules`nintro v2`n`nkit line`n`nend`n+ my line`n"
  Check 'merge, clean then rerun: no new backup' (Backups $c) 1

  $crlf1 = $v1 -replace "`n", "`r`n"
  $crlf2 = $v2 -replace "`n", "`r`n"
  $c = NewMergeCase 'crlf' $crlf2 "$crlf1+ my line`r`n" $crlf1
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'merge, CRLF: both changes, line endings kept' (Text $c.dst) ("# rules`nintro v2`n`nkit line`n`nend`n+ my line`n" -replace "`n", "`r`n")

  # A deployed file rewritten with LF endings and nothing else is not a local edit
  $c = NewMergeCase 'lf-only' $crlf1 $v1 $crlf1
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'merge, LF-only rewrite: reported unchanged' (@($said | Where-Object { $_ -match '\(unchanged\)' }).Count) 1
  Check 'merge, LF-only rewrite: dst untouched' (Text $c.dst) $v1
  Check 'merge, LF-only rewrite: no backup' (Backups $c) 0
  Check 'merge, LF-only rewrite: no warning' $warnings.Count 0

  $c = NewMergeCase 'lf-only-kit-changed' $crlf2 $v1 $crlf1
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'merge, LF-only rewrite then kit change: kit version deployed' (Text $c.dst) $crlf2
  Check 'merge, LF-only rewrite then kit change: no .kit-merge' (Test-Path $c.merge) $false
  Check 'merge, LF-only rewrite then kit change: no warning' $warnings.Count 0

  # A real local edit saved with LF still merges line by line with a CRLF kit, in the kit's endings
  $c = NewMergeCase 'lf-edit' $crlf2 "$v1+ my line`n" $crlf1
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'merge, LF edit vs CRLF kit: both changes, kit line endings' (Text $c.dst) ("# rules`nintro v2`n`nkit line`n`nend`n+ my line`n" -replace "`n", "`r`n")
  Check 'merge, LF edit vs CRLF kit: no .kit-merge' (Test-Path $c.merge) $false
  Check 'merge, LF edit vs CRLF kit: no warning' $warnings.Count 0

  # Both sides changed the same line: dst kept, markers only in .kit-merge
  $c = NewMergeCase 'conflict' $v2 "# rules`nintro mine`n`nkit line`n`nend`n" $v1
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'merge, conflict: dst kept' (Text $c.dst) "# rules`nintro mine`n`nkit line`n`nend`n"
  Check 'merge, conflict: markers in .kit-merge' ((Text $c.merge) -match '<<<<<<< local' -and (Text $c.merge) -match '>>>>>>> kit') $true
  Check 'merge, conflict: base unchanged' (Text $c.base) $v1
  Check 'merge, conflict: no backup' (Backups $c) 0
  Check 'merge, conflict: one warning naming .kit-merge' (@($warnings | Where-Object { $_ -match [regex]::Escape($c.merge) }).Count) 1
  Check 'merge, conflict: warning has the rules hint' ($warnings[0].EndsWith((Get-RulesHint $c.dir))) $true

  # Preview: says what it would do, writes nothing
  $Apply = $false
  foreach ($p in @(
      @('copy', $v1, $null, $null, 'would create'),
      @('merge', $v2, "$v1+ my line`n", $v1, 'would merge'),
      @('conflict', $v2, "# rules`nintro mine`n`nkit line`n`nend`n", $v1, 'conflict, would write'))) {
    $c = NewMergeCase "preview-$($p[0])" $p[1] $p[2] $p[3]
    $before = Tree $c.dir
    Merge-KitFile $c.src $c.dst 'CLAUDE.md'
    Check "merge preview $($p[0]): nothing written" (Tree $c.dir) $before
    Check "merge preview $($p[0]): says '$($p[4])'" (@($said | Where-Object { $_ -match $p[4] }).Count) 1
  }
  $Apply = $true

  # A merge-file failure is not a conflict count: it falls outside 1 to 127
  $c = NewMergeCase 'merge-error' $v2 "$v1+ my line`n" $null
  $code = Invoke-MergeFile $c.dst (Join-Path $c.dir 'missing-base') $c.src (Join-Path $c.dir 'out.md')
  Check 'merge-file error: exit code outside the conflict range' ($code -lt 0 -or $code -gt 127) $true

  # statusline.js: a clean text merge must also pass node --check before it is deployed
  function NewJsCase($name, $srcText, $dstText, $baseText) {
    $dir = Join-Path $root "js-$name"
    New-Item -ItemType Directory -Force (Join-Path $dir 'claude-kit-base') | Out-Null
    $script:claude = $dir
    $c = [pscustomobject]@{
      src = Join-Path $dir 'kit-statusline.js'; dst = Join-Path $dir 'statusline.js'
      base = Join-Path $dir 'claude-kit-base\statusline.js'; merge = Join-Path $dir 'statusline.js.kit-merge'; dir = $dir
    }
    [IO.File]::WriteAllText($c.src, $srcText, $utf8)
    [IO.File]::WriteAllText($c.dst, $dstText, $utf8)
    [IO.File]::WriteAllText($c.base, $baseText, $utf8)
    $script:applied = @{}
    $warnings.Clear()
    $said.Clear()
    $c
  }
  $js1 = "'use strict';`nconst a = 1;`n`nconst b = 2;`n`nconsole.log(a + b);`n"
  $js2 = "'use strict';`nconst a = 10;`n`nconst b = 2;`n`nconsole.log(a + b);`n"

  $c = NewJsCase 'valid' $js2 "$js1// mine`n" $js1
  Merge-KitFile $c.src $c.dst 'statusline.js'
  Check 'js valid merge: deployed' (Text $c.dst) "$js2// mine`n"
  Check 'js valid merge: no warning' $warnings.Count 0

  # The local edit opens a block the kit's change never closes: clean for git, broken for node
  $c = NewJsCase 'broken' $js2 "'use strict';`nconst a = 1;`n`nconst b = 2;`n`nif (a) {`n" $js1
  Merge-KitFile $c.src $c.dst 'statusline.js'
  Check 'js broken merge: dst kept' (Text $c.dst) "'use strict';`nconst a = 1;`n`nconst b = 2;`n`nif (a) {`n"
  Check 'js broken merge: merged text in .kit-merge' (Text $c.merge) "'use strict';`nconst a = 10;`n`nconst b = 2;`n`nif (a) {`n"
  Check 'js broken merge: base unchanged' (Text $c.base) $js1
  Check 'js broken merge: one warning naming node --check' (@($warnings | Where-Object { $_ -match 'node --check' -and $_ -match [regex]::Escape($c.merge) }).Count) 1

  $c = NewJsCase 'preview-broken' $js2 "'use strict';`nconst a = 1;`n`nconst b = 2;`n`nif (a) {`n" $js1
  $Apply = $false
  $before = Tree $c.dir
  Merge-KitFile $c.src $c.dst 'statusline.js'
  $Apply = $true
  Check 'js broken merge preview: nothing written' (Tree $c.dir) $before
  Check 'js broken merge preview: says it would write .kit-merge' (@($said | Where-Object { $_ -match 'would write' }).Count) 1

  # No node on PATH: the merge cannot be checked, so it is not deployed
  $c = NewJsCase 'no-node' $js2 "$js1// mine`n" $js1
  $pathBefore = $env:PATH
  $env:PATH = (($env:PATH -split ';') | Where-Object { $_ -and -not (Test-Path (Join-Path $_ 'node.exe')) }) -join ';'
  try { Merge-KitFile $c.src $c.dst 'statusline.js' } finally { $env:PATH = $pathBefore }
  Check 'js no node: dst kept' (Text $c.dst) "$js1// mine`n"
  Check 'js no node: merged text in .kit-merge' (Text $c.merge) "$js2// mine`n"
  Check 'js no node: one warning naming node' (@($warnings | Where-Object { $_ -match 'node' }).Count) 1

  # CLAUDE.md is never run through node
  $c = NewMergeCase 'md-no-node' $v2 "$v1+ my line`n" $v1
  $env:PATH = (($env:PATH -split ';') | Where-Object { $_ -and -not (Test-Path (Join-Path $_ 'node.exe')) }) -join ';'
  try { Merge-KitFile $c.src $c.dst 'CLAUDE.md' } finally { $env:PATH = $pathBefore }
  Check 'md without node: merged' (Text $c.dst) "# rules`nintro v2`n`nkit line`n`nend`n+ my line`n"

  # Installs from before merge bases: the base is the kit version whose hash was recorded as applied
  function NewLegacyCase($name, $crlf) {
    if ($crlf) { $env:GIT_CONFIG_VALUE_0 = 'true' }
    try {
      $f = NewFixture "legacy-$name"
      New-Item -ItemType Directory -Force (Join-Path $f.dev 'global') | Out-Null
      PushUpstream $f 'global/CLAUDE.md' $v1
      PushUpstream $f 'global/CLAUDE.md' $v2
      $null = RunGit $f.kit pull -q
    } finally { $env:GIT_CONFIG_VALUE_0 = 'false' }
    $c = NewMergeCase "legacy-$name" $null $null $null
    $c.src = Join-Path $f.kit 'global\CLAUDE.md'
    $script:KitDir = $f.kit
    $c
  }
  $c = NewLegacyCase 'lf' $false
  [IO.File]::WriteAllText($c.dst, "$v1+ my line`n", $utf8)
  $applied['CLAUDE.md'] = (Get-FileHash -InputStream ([IO.MemoryStream]::new($utf8.GetBytes($v1)))).Hash
  Merge-KitFile $c.src $c.dst 'CLAUDE.md'
  Check 'legacy in history: merged' (Text $c.dst) "# rules`nintro v2`n`nkit line`n`nend`n+ my line`n"
  Check 'legacy in history: base created' (Text $c.base) $v2
  Check 'legacy in history: no warning' $warnings.Count 0

  # A Windows clone checks files out with CRLF, so the recorded hash is of the CRLF version
  $c = NewLegacyCase 'crlf' $true
  $crlfV1 = $v1 -replace "`n", "`r`n"
  Check 'legacy CRLF: clone checked out with CRLF' ((Text $c.src) -match "`r`n") $true
  [IO.File]::WriteAllText($c.dst, "$crlfV1+ my line`r`n", $utf8)
  $applied['CLAUDE.md'] = (Get-FileHash -InputStream ([IO.MemoryStream]::new($utf8.GetBytes($crlfV1)))).Hash
  # The machine's setting still applies when bootstrap runs
  $env:GIT_CONFIG_VALUE_0 = 'true'
  try { Merge-KitFile $c.src $c.dst 'CLAUDE.md' } finally { $env:GIT_CONFIG_VALUE_0 = 'false' }
  Check 'legacy CRLF: merged' (Text $c.dst) ("# rules`nintro v2`n`nkit line`n`nend`n+ my line`n" -replace "`n", "`r`n")
  Check 'legacy CRLF: no warning' $warnings.Count 0

  # Not in the history: kept in every mode except -Apply -Force
  foreach ($mode in @(@{ quiet = $true; force = $false }, @{ quiet = $false; force = $false }, @{ quiet = $false; force = $true })) {
    $label = "legacy not found (Quiet=$($mode.quiet), Force=$($mode.force))"
    $c = NewLegacyCase "missing-$($mode.quiet)-$($mode.force)" $false
    [IO.File]::WriteAllText($c.dst, 'something else entirely', $utf8)
    $applied['CLAUDE.md'] = 'NOT-IN-HISTORY'
    $Quiet = $mode.quiet
    $Force = $mode.force
    Merge-KitFile $c.src $c.dst 'CLAUDE.md'
    if ($mode.force) {
      Check "${label}: replaced" (Text $c.dst) $v2
      Check "${label}: backup kept" (Backups $c) 1
    } else {
      Check "${label}: kept" (Text $c.dst) 'something else entirely'
      Check "${label}: one warning" $warnings.Count 1
      Check "${label}: warning names -Force" ($warnings[0] -match '-Apply -Force') $true
    }
  }
  $Quiet = $true
  $Force = $false

  # Plugin refresh: needed when the installed plugin is an older upstream commit, even if
  # this run pulled nothing, but never while upstream commits wait for review
  $f = NewFixture 'plugin'
  $old = RunGit $f.kit rev-parse HEAD
  PushUpstream $f 'a.txt' "1 up`n2`n3`n4`n5`n"
  $null = RunGit $f.kit pull -q
  $new = RunGit $f.kit rev-parse HEAD
  Check 'plugin: older installed commit is behind' (Test-PluginBehind $f.kit $old) $true
  Check 'plugin: installed at upstream is not behind' (Test-PluginBehind $f.kit $new) $false
  Check 'plugin: no recorded commit is not behind' (Test-PluginBehind $f.kit $null) $false
  Check 'plugin: unknown commit is not behind' (Test-PluginBehind $f.kit ('0' * 40)) $false
  CommitFile $f.kit 'b.txt' 'local'
  Check 'plugin: local commits alone do not make it behind' (Test-PluginBehind $f.kit $new) $false
  PushUpstream $f 'c.txt' 'held'
  $null = RunGit $f.kit fetch -q
  Check 'plugin: upstream commits not yet in the clone block the refresh' (Test-PluginBehind $f.kit $old) $false

  # Hook output: the warnings reach Claude as plain text (rewake) or one ASCII JSON line (-Report), within the size cap
  Check 'warning text: none without warnings' ($null -eq (Get-WarningText @() 'C:\kit' 'C:\cfg\state.json')) $true
  Check 'hook context: none without warnings' ($null -eq (Get-HookContext @() 'C:\kit' 'C:\cfg\state.json')) $true
  $line = Get-HookContext @('first warning', 'second warning') 'C:\kit' 'C:\cfg\state.json'
  Check 'hook context: one line' @($line -split "`n").Count 1
  $hook = ($line | ConvertFrom-Json).hookSpecificOutput
  Check 'hook context: event name' $hook.hookEventName 'SessionStart'
  Check 'hook context: both warnings listed' (($hook.additionalContext -match '1\. first warning') -and ($hook.additionalContext -match '2\. second warning')) $true
  Check 'hook context: clone and state paths named' (($hook.additionalContext.Contains('C:\kit')) -and ($hook.additionalContext.Contains('C:\cfg\state.json'))) $true
  $accent = [string][char]0xE9
  $line = Get-HookContext @("conflict in C:\Users\r${accent}mi\CLAUDE.md") 'C:\kit' 'C:\cfg\state.json'
  Check 'hook context: ASCII only' ($line -match '[^\x00-\x7F]') $false
  Check 'hook context: accent decodes back' (($line | ConvertFrom-Json).hookSpecificOutput.additionalContext.Contains("r${accent}mi")) $true
  $text = Get-WarningText @(1..20 | ForEach-Object { 'x' * 1000 }) 'C:\kit' 'C:\cfg\state.json'
  Check 'warning text: under the 10,000 character cap' ($text.Length -lt 10000) $true
  Check 'warning text: cut list says so' ($text.EndsWith('(more in the state file)')) $true

  # End to end: a clean hook run stays silent and does not wake Claude
  $f = NewFixture 'e2e-clean'
  PushUpstream $f 'a.txt' "1 up`n2`n3`n4`n5`n"
  $config = Join-Path $root 'e2e-clean-config'
  New-Item -ItemType Directory -Force $config | Out-Null
  $env:CLAUDE_CONFIG_DIR = $config
  try {
    $r = RunBootstrap @('-Apply', '-Quiet', '-KitDir', "`"$($f.kit)`"")
    $recorded = [IO.File]::ReadAllText((Join-Path $config 'claude-kit-sync.json'), $utf8) | ConvertFrom-Json
    Check 'e2e clean run: no warning recorded' @($recorded.warnings).Count 0
    Check 'e2e clean run: exit code 0' $r.code 0
    Check 'e2e clean run: stdout empty' $r.out ''
    Check 'e2e clean run: stderr empty' $r.err ''
    $r = RunBootstrap @('-Report', '-KitDir', "`"$($f.kit)`"")
    Check 'e2e report, no warning: exit code 0' $r.code 0
    Check 'e2e report, no warning: stdout empty' $r.out ''
  } finally {
    Remove-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
  }

  # End to end: -Report with no state file and no config folder writes nothing, not even the folder
  $config = Join-Path $root 'e2e-report-missing'
  $env:CLAUDE_CONFIG_DIR = $config
  try {
    $r = RunBootstrap @('-Report', '-KitDir', "`"$($f.kit)`"")
    Check 'e2e report, no state: exit code 0' $r.code 0
    Check 'e2e report, no state: stdout empty' $r.out ''
    Check 'e2e report, no state: config folder not created' (Test-Path $config) $false
  } finally {
    Remove-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
  }

  # End to end: while edits wait in the autostash, the deployed CLAUDE.md is never replaced,
  # neither on the run that parks them nor on a later throttled run
  $f = NewFixture 'e2e-stash'
  New-Item -ItemType Directory -Force (Join-Path $f.dev 'global') | Out-Null
  PushUpstream $f 'global/CLAUDE.md' "# rules`nkit v1`n"
  $null = RunGit $f.kit pull -q
  $config = Join-Path $root 'e2e-config'
  New-Item -ItemType Directory -Force $config | Out-Null
  $deployed = Join-Path $config 'CLAUDE.md'
  [IO.File]::WriteAllText($deployed, "# rules`nkit v1 + my section`n", $utf8)
  WriteFile $f.kit 'global/CLAUDE.md' "# rules`nkit v1 + my section`n"
  # The kit last wrote the user's version, so the deployed file looks unedited
  $state = [pscustomobject]@{ applied = [pscustomobject]@{ 'CLAUDE.md' = (Get-FileHash $deployed).Hash } }
  [IO.File]::WriteAllText((Join-Path $config 'claude-kit-sync.json'), ($state | ConvertTo-Json), $utf8)
  PushUpstream $f 'global/CLAUDE.md' "# rules`nkit v2`n"
  $env:CLAUDE_CONFIG_DIR = $config
  try {
    $r = RunBootstrap @('-Apply', '-Quiet', '-KitDir', "`"$($f.kit)`"")
    Check 'e2e parking run: exit code 2 wakes Claude' $r.code 2
    Check 'e2e parking run: stderr hands the warning to Claude' ($r.err -match 'Kit sync \(bootstrap\.ps1\) left 1 warning' -and $r.err -match 'stash drop') $true
    Check 'e2e parking run: stdout empty' $r.out ''
    Check 'e2e parking run: edit parked in the stash' ([bool](Find-PendingAutostash $f.kit)) $true
    Check 'e2e parking run: deployed file kept' ([IO.File]::ReadAllText($deployed, $utf8)) "# rules`nkit v1 + my section`n"
    Check 'e2e parking run: no base copy written' (Test-Path (Join-Path $config 'claude-kit-base')) $false
    $r = RunBootstrap @('-Apply', '-Quiet', '-KitDir', "`"$($f.kit)`"")
    $recorded = [IO.File]::ReadAllText((Join-Path $config 'claude-kit-sync.json'), $utf8) | ConvertFrom-Json
    Check 'e2e throttled run: deployed file kept' ([IO.File]::ReadAllText($deployed, $utf8)) "# rules`nkit v1 + my section`n"
    Check 'e2e throttled run: warning recorded' (@($recorded.warnings | Where-Object { $_ -match 'stash drop' }).Count) 1
    Check 'e2e throttled run: still wakes Claude' $r.code 2
    $r = RunBootstrap @('-Report', '-KitDir', "`"$($f.kit)`"")
    Check 'e2e report: exit code 0' $r.code 0
    Check 'e2e report: one JSON line' @($r.out -split "`n").Count 1
    Check 'e2e report: context names the warning' (($r.out | ConvertFrom-Json).hookSpecificOutput.additionalContext -match 'stash drop') $true
  } finally {
    Remove-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
  }
} finally {
  Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $emptyConfig -Force -ErrorAction SilentlyContinue
}

if ($failed) { Write-Host "$failed of $total failed"; exit 1 }
Write-Host "all $total passed"
