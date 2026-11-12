<#
.SYNOPSIS
  Sync this machine's ~/.claude with the toolkit-for-claude repo. Idempotent.

.DESCRIPTION
  Default = PREVIEW (nothing written, shows the diff). Use -Apply to write.
  First run on a new PC (use your fork):
    gh repo clone <you>/toolkit-for-claude $HOME\.claude-kit
    & $HOME\.claude-kit\bootstrap.ps1            # preview
    & $HOME\.claude-kit\bootstrap.ps1 -Apply     # apply
  After that, an async SessionStart hook runs it with -Apply -Quiet. In that mode the
  update runs at most once every 24 hours, upstream changes to files that run code
  (bootstrap.ps1, settings.base.json, statusline.js, plugin hooks, agents and scripts) are held back until a
  manual -Apply, and warnings go to ~/.claude/claude-kit-sync.json (the status line shows
  them as "kit!"). With warnings left, a -Quiet run writes them to stderr and exits 2, so
  the asyncRewake hook wakes Claude to raise them. A second, synchronous hook runs
  -Report, which only prints the last run's warnings as session context, so they also
  reach Claude's first reply.

  The clone is updated with git rebase --autostash, so local commits and uncommitted edits
  are carried over; a conflict is aborted and leaves the clone as it was. Preview only fetches.

  What it touches: ~/.claude/settings.json (merged, backed up), ~/.claude/CLAUDE.md and
  ~/.claude/statusline.js (three-way merged with local edits, backed up; a conflict goes to
  <file>.kit-merge, never into the file), ~/.claude/claude-kit-base/ (merge bases),
  ~/.claude/claude-kit-sync.json, and ~/.claude/rules/ (created if missing, never written
  inside). The first backup of each file is also kept for good as <file>.pre-kit. It never
  touches credentials, history or projects.
  When CLAUDE_CONFIG_DIR is set, that folder replaces ~/.claude everywhere above.
#>
[CmdletBinding()]
param(
  [switch]$Apply,
  [switch]$Quiet,
  [switch]$Force,
  # Only print the last run's warnings for the synchronous SessionStart hook
  [switch]$Report,
  [string]$KitDir = (Join-Path $HOME '.claude-kit'),
  # Only used when $KitDir does not exist yet; afterwards the clone's own origin is the source
  [string]$Repo
)

$ErrorActionPreference = 'Continue'
# Claude Code keeps its config in CLAUDE_CONFIG_DIR when set; the SessionStart hook inherits it
$claude = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$statePath = Join-Path $claude 'claude-kit-sync.json'
$pullEvery = [TimeSpan]::FromHours(24)
$keepBackups = 5
# Upstream changes to these paths run code on this machine, so auto-sync never takes them unreviewed
$reviewPattern = '^(bootstrap\.ps1|global/settings\.base\.json|global/statusline\.js)$|^plugins/[^/]+/(hooks|agents)/|^plugins/.+\.(ps1|psm1|js|mjs|cjs|ts|py|sh|bat|cmd)$'
$warnings = New-Object System.Collections.Generic.List[string]

function Say($m) { if (-not $Quiet) { Write-Host $m } }
function Warn($m) { $warnings.Add($m); Say "! $m" }
# The status line is not shown everywhere (the desktop app), so the hooks also hand the warnings to Claude
function Get-WarningText($warnings, $kitDir, $statePath) {
  $count = @($warnings).Count
  if (-not $count) { return $null }
  # Claude Code caps hook output at 10,000 characters
  $max = 8000
  $lines = @("Kit sync (bootstrap.ps1) left $count warning(s). Kit clone: $kitDir. State file: $statePath.")
  $i = 0
  foreach ($w in $warnings) {
    $i++
    $line = "$i. $w"
    if ((($lines + $line) -join "`n").Length -gt $max) { $lines += '(more in the state file)'; break }
    $lines += $line
  }
  return ($lines -join "`n")
}
function Get-HookContext($warnings, $kitDir, $statePath) {
  $text = Get-WarningText $warnings $kitDir $statePath
  if (-not $text) { return $null }
  $payload = [pscustomobject]@{
    hookSpecificOutput = [pscustomobject]@{ hookEventName = 'SessionStart'; additionalContext = $text }
  }
  $json = $payload | ConvertTo-Json -Compress -Depth 3
  # ASCII only, so the console code page cannot garble a path with accents
  return [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}
function HasProp($o, $n) { return $null -ne $o -and $null -ne $o.PSObject.Properties[$n] }
function SetProp($o, $n, $v) {
  if (HasProp $o $n) { $o.$n = $v } else { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v }
}
# Returns $null when the file exists but is not valid JSON, so callers never overwrite it blindly.
function ReadJson($p) {
  if (-not (Test-Path $p)) { return [pscustomobject]@{} }
  $t = [IO.File]::ReadAllText($p, $utf8)
  if (-not $t.Trim()) { return [pscustomobject]@{} }
  try { return ($t | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}
function ToJson($o) {
  $j = $o | ConvertTo-Json -Depth 20
  return ($j -replace '\\u0027', "'" -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0026', '&')
}
# Claude Code reads ':*' as a wildcard only at the end of a Bash rule; elsewhere it is a literal colon and the rule never matches
function Find-MidWildcardRules($permissions) {
  foreach ($list in 'allow', 'ask', 'deny') {
    if (HasProp $permissions $list) { @($permissions.$list) | Where-Object { $_ -match '^Bash\(.*:\*(?!\)$)' } }
  }
}
# User skills named like a kit plugin skill: both show up in the skill list
function Find-ShadowedSkills($userSkillsDir, $kitDir) {
  if (-not (Test-Path $userSkillsDir)) { return }
  $kitSkills = @(Get-ChildItem (Join-Path $kitDir 'plugins\*\skills\*') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
  Get-ChildItem $userSkillsDir -Directory |
    Where-Object { ($kitSkills -contains $_.Name) -and (Test-Path (Join-Path $_.FullName 'SKILL.md')) } |
    ForEach-Object Name
}
# settings.base.json points at ~/.claude; a custom config folder needs its own paths.
# Permission rules take an absolute path as //<posix path> (Windows C:\x becomes /c/x).
function Set-ConfigDirPaths($base, $configDir) {
  $fwd = $configDir.TrimEnd('\', '/') -replace '\\', '/'
  $posix = $fwd
  if ($fwd -match '^([A-Za-z]):(.*)$') { $posix = '/' + $Matches[1].ToLower() + $Matches[2] }
  if ((HasProp $base 'statusLine') -and (HasProp $base.statusLine 'command')) {
    $base.statusLine.command = $base.statusLine.command.Replace('$HOME/.claude/', "$fwd/")
  }
  if (HasProp $base 'permissions') {
    foreach ($list in 'allow', 'ask', 'deny') {
      if (HasProp $base.permissions $list) {
        $base.permissions.$list = @($base.permissions.$list | ForEach-Object { $_.Replace('(~/.claude/', "(/$posix/") })
      }
    }
  }
}
# Files matching $pattern changed upstream; a two-way diff would also list local commits
function Get-HeldChanges($kitDir, $pattern) {
  @(& git -C $kitDir diff --name-only 'HEAD...@{u}' 2>$null | Where-Object { $_ -match $pattern })
}
# The plugin is refreshed from the fork on GitHub, so it is behind when it was installed from an
# older upstream commit. Never while upstream has commits the clone has not taken: those may be held for review.
function Test-PluginBehind($kitDir, $installedSha) {
  if (-not $installedSha) { return $false }
  $upstream = (& git -C $kitDir rev-parse '@{u}' 2>$null)
  if ($LASTEXITCODE -ne 0 -or $installedSha -eq $upstream) { return $false }
  $null = & git -C $kitDir merge-base --is-ancestor '@{u}' HEAD 2>&1
  if ($LASTEXITCODE -ne 0) { return $false }
  $null = & git -C $kitDir merge-base --is-ancestor $installedSha '@{u}' 2>&1
  return ($LASTEXITCODE -eq 0)
}
# The stash entry git leaves when it could not re-apply the autostash after a rebase, or $null
function Find-PendingAutostash($kitDir) {
  @(& git -C $kitDir stash list --format='%gd%x09%gs' 2>$null) |
    Where-Object { ($_ -split "`t", 2)[1] -eq 'autostash' } |
    ForEach-Object { ($_ -split "`t", 2)[0] } | Select-Object -First 1
}
# git also leaves the failed re-apply in the working tree, with conflict markers in the files that clashed
function Write-AutostashWarning($kitDir, $ref) {
  $conflicted = @(& git -C $kitDir diff --name-only --diff-filter=U 2>$null)
  if ($conflicted.Count) {
    Warn "a kit update left conflict markers in $($conflicted -join ', ') in ${kitDir}; your version from before is saved in $ref. Resolve the markers, run git -C $kitDir reset -q, then git -C $kitDir stash drop $ref; deployed files are not updated until then"
  } else {
    Warn "your edits from before a kit update are saved in $ref; once the files in $kitDir hold what you want, run git -C $kitDir stash drop $ref; deployed files are not updated until then"
  }
}
# Fetch, hold upstream code changes for review, then replay local commits and uncommitted edits
# on top of upstream. A conflict is aborted, so the clone is left exactly as it was.
function Update-KitClone($kitDir) {
  $result = [pscustomobject]@{ updated = $false; pulled = $false; stashPending = $false }
  # Updating now would bury the parked edits under more upstream changes
  $pending = Find-PendingAutostash $kitDir
  if ($pending) {
    $result.stashPending = $true
    Write-AutostashWarning $kitDir $pending
    return $result
  }
  $headBefore = (& git -C $kitDir rev-parse HEAD 2>$null)
  $null = & git -C $kitDir -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 fetch --quiet 2>&1
  $held = @()
  if ($LASTEXITCODE -eq 0) {
    $held = Get-HeldChanges $kitDir $reviewPattern
  }
  if ($LASTEXITCODE -ne 0) {
    Warn 'git fetch skipped (offline, auth, or no upstream branch); using the local copy'
    return $result
  }
  if ($held.Count -and ($Quiet -or -not $Apply)) {
    # lastPull is left as is, so the check runs again at every launch until the change is reviewed
    Warn "upstream changes to $($held -join ', ') wait for review: read git -C $kitDir log -p HEAD..@{u}, then run bootstrap.ps1 -Apply"
    return $result
  }
  # Preview writes nothing, and a rebase rewrites local commits and stashes edits
  if (-not $Apply) {
    $behind = [int](& git -C $kitDir rev-list --count 'HEAD..@{u}' 2>$null)
    $ahead = [int](& git -C $kitDir rev-list --count '@{u}..HEAD' 2>$null)
    $carry = if (& git -C $kitDir status --porcelain --untracked-files=no 2>$null) { ', carrying uncommitted edits' } else { '' }
    if (-not $behind) { Say '= kit up to date' }
    elseif ($ahead) { Say "~ would rebase $ahead local commit(s) onto $behind upstream commit(s)$carry" }
    else { Say "~ would fast-forward the kit by $behind upstream commit(s)$carry" }
    return $result
  }
  foreach ($f in $held) { Say "~ upstream change to $f (runs code on this machine)" }
  $null = & git -C $kitDir rebase --autostash --quiet '@{u}' 2>&1
  if ($LASTEXITCODE -ne 0) {
    # Also re-applies the autostash; fails harmlessly when git refused before the rebase started
    $null = & git -C $kitDir rebase --abort 2>&1
    Warn "kit update skipped: local changes in $kitDir conflict with upstream; run git -C $kitDir pull --rebase --autostash and resolve, then bootstrap.ps1 -Apply"
    return $result
  }
  $result.updated = $true
  $result.pulled = $headBefore -ne (& git -C $kitDir rev-parse HEAD 2>$null)
  # The rebase succeeded but the edits did not fit back: git parked them in the stash
  $pending = Find-PendingAutostash $kitDir
  if ($pending) {
    $result.stashPending = $true
    Write-AutostashWarning $kitDir $pending
  }
  return $result
}
# Kit-deployed files belong to the kit; machine-local additions go in rules/, which Claude Code
# loads in every project and the kit never writes inside
function Get-RulesHint($claudeDir) { "machine-local content belongs in $(Join-Path $claudeDir 'rules')" }
function Initialize-RulesDir($claudeDir) {
  $rules = Join-Path $claudeDir 'rules'
  if (Test-Path $rules) { return }
  if (-not $Apply) { Say "~ would create $rules"; return }
  New-Item -ItemType Directory -Force $rules | Out-Null
  Say "+ created $rules"
}
function FileHash($p) { if (Test-Path $p) { return (Get-FileHash $p).Hash } return '' }
# An editor or a tool that rewrites CRLF as LF (or back) changes no line, so kit files are compared
# and merged on their LF form
function Read-TextLF($p) { return [IO.File]::ReadAllText($p, $utf8).Replace("`r`n", "`n") }
function TextHash($p) {
  if (-not (Test-Path $p)) { return '' }
  $sha256 = [Security.Cryptography.SHA256]::Create()
  return (($sha256.ComputeHash($utf8.GetBytes((Read-TextLF $p))) | ForEach-Object { $_.ToString('X2') }) -join '')
}
function Backup($p) {
  if (-not (Test-Path $p)) { return }
  $leaf = Split-Path $p -Leaf
  # The user's copy from before the kit is never pruned: the oldest backup if one is left, else the file itself
  $preKit = "$p.pre-kit"
  if (-not (Test-Path $preKit)) {
    $oldest = Get-ChildItem (Split-Path $p -Parent) -Filter "$leaf.bak-*" | Sort-Object LastWriteTime | Select-Object -First 1
    if ($oldest) { Copy-Item $oldest.FullName $preKit } else { Copy-Item $p $preKit }
  }
  Copy-Item $p "$p.bak-$stamp" -Force
  Get-ChildItem (Split-Path $p -Parent) -Filter "$leaf.bak-*" | Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $keepBackups | Remove-Item -Force
}
# Records the kit's version as the next merge base, and $dst as what the kit last wrote
function Save-KitBase($src, $dst, $key) {
  $basePath = Join-Path (Join-Path $claude 'claude-kit-base') $key
  New-Item -ItemType Directory -Force (Split-Path $basePath) | Out-Null
  Copy-Item $src $basePath -Force
  $applied[$key] = FileHash $dst
  Remove-Item "$dst.kit-merge" -Force -ErrorAction SilentlyContinue
}
function Write-KitFile($from, $src, $dst, $key) {
  Backup $dst
  Copy-Item $from $dst -Force
  Save-KitBase $src $dst $key
}
# Raw bytes of git's stdout: PowerShell would decode it as text and change line endings
function Get-GitBytes($kitDir, [string[]]$gitArgs) {
  $psi = New-Object Diagnostics.ProcessStartInfo 'git'
  $psi.Arguments = (@('-C', "`"$kitDir`"") + $gitArgs) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  try { $p = [Diagnostics.Process]::Start($psi) } catch { return $null }
  $ms = New-Object IO.MemoryStream
  $p.StandardOutput.BaseStream.CopyTo($ms)
  $null = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  if ($p.ExitCode -ne 0) { return $null }
  return , $ms.ToArray()
}
# Installs from before merge bases only recorded the hash of what the kit wrote. Find that version
# in the clone's history, as checked out (--filters applies the clone's line-ending settings) or raw.
function Find-BaseInHistory($kitDir, $key, $hash) {
  if (-not $hash) { return $null }
  $sha256 = [Security.Cryptography.SHA256]::Create()
  foreach ($rev in @(& git -C $kitDir log --format=%H -- "global/$key" 2>$null)) {
    foreach ($mode in @('--filters', '-p')) {
      $bytes = Get-GitBytes $kitDir @('cat-file', $mode, "${rev}:global/$key")
      if ($null -eq $bytes) { continue }
      if ((($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('X2') }) -join '') -eq $hash) { return , $bytes }
    }
  }
  return $null
}
# Three-way merge into a temp copy of $dst; returns git merge-file's exit code
# (0 clean, 1 to 127 conflicts, anything else an error: the count is capped at 127 and a fatal error exits 128).
# The inputs are merged as LF, so a side that only changed line endings does not clash on every line;
# the result takes the kit's line endings.
function Invoke-MergeFile($dst, $basePath, $src, $out) {
  $temps = @()
  $inputs = foreach ($p in @($basePath, $src)) {
    # A missing input is passed as is, so git reports the error
    if (-not (Test-Path $p)) { $p; continue }
    $t = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($t, (Read-TextLF $p), $utf8)
    $temps += $t
    $t
  }
  try {
    [IO.File]::WriteAllText($out, (Read-TextLF $dst), $utf8)
    $null = & git merge-file -q -L local -L kit-base -L kit $out $inputs[0] $inputs[1] 2>&1
    $code = $LASTEXITCODE
    if ((Test-Path $src) -and [IO.File]::ReadAllText($src, $utf8).Contains("`r`n")) {
      [IO.File]::WriteAllText($out, ([IO.File]::ReadAllText($out, $utf8).Replace("`n", "`r`n")), $utf8)
    }
    return $code
  } finally {
    if ($temps.Count) { Remove-Item $temps -Force -ErrorAction SilentlyContinue }
  }
}
# A text merge of code can be clean for git and still not parse; returns why it cannot be deployed, or $null
function Test-ScriptSyntax($path) {
  if ([IO.Path]::GetExtension($path) -ne '.js') { return $null }
  $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $node) { return 'node is not on PATH, so the merged script cannot be checked' }
  $null = & $node.Source --check $path 2>&1
  if ($LASTEXITCODE -ne 0) { return 'the merged script fails node --check' }
  return $null
}
# Kit-owned files. The kit's version from the last write is the merge base; without it a local edit
# cannot be told from an upstream one. Local edits are merged with kit changes, never dropped, and a
# conflict is left in <dst>.kit-merge instead of the deployed file.
function Merge-KitFile($src, $dst, $key) {
  if (-not (Test-Path $src)) { return }
  $basePath = Join-Path (Join-Path $claude 'claude-kit-base') $key
  $mergePath = "$dst.kit-merge"
  $srcHash = TextHash $src
  $dstHash = TextHash $dst
  $baseHash = TextHash $basePath

  if (-not $dstHash) {
    if (-not $Apply) { Say "~ would create $dst"; return }
    Write-KitFile $src $src $dst $key
    Say "+ created $dst"
    return
  }
  if ($dstHash -eq $srcHash) {
    if ($Apply) { Save-KitBase $src $dst $key }
    Say "= $dst (unchanged)"
    return
  }
  if ($baseHash -and $srcHash -eq $baseHash) { Say "= $dst (kit unchanged, local edits kept)"; return }

  # applied holds the raw hash of what the kit wrote, so it is compared with the raw file
  $notEdited = if ($baseHash) { $dstHash -eq $baseHash } else { -not $applied[$key] -or (FileHash $dst) -eq $applied[$key] }
  if ($notEdited) {
    if (-not $Apply) { Say "~ would update $dst"; return }
    Write-KitFile $src $src $dst $key
    Say "+ updated $dst"
    return
  }

  $recovered = $null
  if (-not $baseHash) {
    $bytes = Find-BaseInHistory $KitDir $key $applied[$key]
    if ($null -eq $bytes) {
      if ($Apply -and $Force) {
        Write-KitFile $src $src $dst $key
        Say "+ updated $dst (local edits backed up)"
        return
      }
      Warn "$dst was edited outside the kit and the version it started from is unknown; not replaced. Move the change to the kit, or run bootstrap.ps1 -Apply -Force to back it up and replace it; $(Get-RulesHint $claude)"
      return
    }
    $recovered = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllBytes($recovered, $bytes)
    $basePath = $recovered
  }

  # Same extension as $dst, so node --check reads it as the same kind of script
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kit-merge-$([guid]::NewGuid())" + [IO.Path]::GetExtension($dst))
  try {
    $code = Invoke-MergeFile $dst $basePath $src $tmp
    $unusable = $null
    if ($code -eq 0) { $unusable = Test-ScriptSyntax $tmp }
    if ($code -lt 0 -or $code -gt 127) {
      Warn "git merge-file failed on $dst (exit code $code); kept as is"
    } elseif ($code -gt 0 -or $unusable) {
      if (-not $Apply) { Say "~ conflict, would write $mergePath"; return }
      Copy-Item $tmp $mergePath -Force
      if ($unusable) {
        Warn "$dst has local edits merged with kit changes, but $unusable; kept as is. Fix $mergePath, copy it over $dst, then run bootstrap.ps1 -Apply; $(Get-RulesHint $claude)"
      } else {
        Warn "$dst has local edits that clash with kit changes; kept as is. Resolve the conflict markers in $mergePath, copy it over $dst, then run bootstrap.ps1 -Apply; $(Get-RulesHint $claude)"
      }
    } elseif (-not $Apply) {
      Say "~ would merge kit changes into $dst (local edits kept)"
    } else {
      Write-KitFile $tmp $src $dst $key
      Say "+ merged kit changes into $dst (local edits kept, backup made)"
    }
  } finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($recovered) { Remove-Item $recovered -Force -ErrorAction SilentlyContinue }
  }
}

# -Report (the synchronous SessionStart hook): Claude's first reply waits for it, so the last run's
# warnings reach Claude however fast the user types. No git and no writes, so it stays well under a second.
if ($Report) {
  $last = ReadJson $statePath
  $recorded = @()
  if (HasProp $last 'warnings') { $recorded = @($last.warnings | Where-Object { $_ }) }
  $hookLine = Get-HookContext $recorded $KitDir $statePath
  if ($hookLine) { [Console]::Out.WriteLine($hookLine) }
  exit 0
}

if (-not (Test-Path $claude)) { New-Item -ItemType Directory -Force $claude | Out-Null }

$state = ReadJson $statePath
if ($null -eq $state) { $state = [pscustomobject]@{} }
$applied = @{}
if (HasProp $state 'applied') { foreach ($p in $state.applied.PSObject.Properties) { $applied[$p.Name] = $p.Value } }
$lastPull = [datetime]::MinValue
if (HasProp $state 'lastPull') { [void][datetime]::TryParse($state.lastPull, [ref]$lastPull) }

# 1. Get / update the kit (rebase local work on upstream; offline is fine; throttled in -Quiet mode)
$pulled = $false
# Edits parked in the autostash: the clone's tree lacks them, so deployed files must not follow it
$stashPending = $false
if (Test-Path (Join-Path $KitDir '.git')) {
  $due = $Force -or -not $Quiet -or ((Get-Date) - $lastPull) -ge $pullEvery
  if ($due) {
    $sync = Update-KitClone $KitDir
    if ($sync.updated) { $lastPull = Get-Date }
    $pulled = $sync.pulled
    $stashPending = $sync.stashPending
  } else {
    $pending = Find-PendingAutostash $KitDir
    if ($pending) {
      $stashPending = $true
      Write-AutostashWarning $KitDir $pending
    }
  }
} else {
  if (-not $Apply -or -not $Repo) { Say "Kit not found at $KitDir. Clone your fork first: gh repo clone <you>/toolkit-for-claude $KitDir"; exit 1 }
  $null = & git clone --quiet $Repo $KitDir 2>&1
  if ($LASTEXITCODE -ne 0) { Say '! clone failed (auth? network?)'; exit 1 }
  $lastPull = Get-Date
}

# 2. Merge settings.json (kit keys only; everything local is preserved)
$basePath = Join-Path $KitDir 'global\settings.base.json'
$curPath = Join-Path $claude 'settings.json'
$base = ReadJson $basePath
$cur = ReadJson $curPath
if ($null -ne $base -and $env:CLAUDE_CONFIG_DIR) { Set-ConfigDirPaths $base $claude }

# The kit's marketplace points at wherever this clone came from, so a fork needs no edits
$origin = (& git -C $KitDir remote get-url origin 2>$null)
if ($null -ne $base -and $origin) {
  if ($origin -match 'github\.com[:/]([^/]+/[^/]+?)(\.git)?/?$') { $source = [pscustomobject]@{ source = 'github'; repo = $Matches[1] } }
  else { $source = [pscustomobject]@{ source = 'git'; url = $origin } }
  if (-not (HasProp $base 'extraKnownMarketplaces')) { SetProp $base 'extraKnownMarketplaces' ([pscustomobject]@{}) }
  SetProp $base.extraKnownMarketplaces 'workshop' ([pscustomobject]@{ source = $source })
}

if ($null -eq $base) {
  Warn "$basePath is not valid JSON; settings.json left untouched"
} elseif ($null -eq $cur) {
  Warn "$curPath is not valid JSON; fix it (or restore a .bak) then re-run. Left untouched."
} else {
  $before = ToJson (ReadJson $curPath)

  # statusLine: kit wins (portable path)
  if (HasProp $base 'statusLine') { SetProp $cur 'statusLine' $base.statusLine }

  # maps: add/overwrite kit entries, keep the rest
  foreach ($k in 'env', 'extraKnownMarketplaces', 'enabledPlugins') {
    if (HasProp $base $k) {
      if (-not (HasProp $cur $k)) { SetProp $cur $k ([pscustomobject]@{}) }
      foreach ($p in $base.$k.PSObject.Properties) { SetProp $cur.$k $p.Name $p.Value }
    }
  }

  # Former plugin ids, dropped once the kit enables their new name
  if ((HasProp $cur 'enabledPlugins') -and (HasProp $cur.enabledPlugins 'toolkit@workshop')) {
    $cur.enabledPlugins.PSObject.Properties.Remove('claude-kit@workshop')
  }

  # permissions: union of lists
  if (HasProp $base 'permissions') {
    if (-not (HasProp $cur 'permissions')) { SetProp $cur 'permissions' ([pscustomobject]@{}) }
    foreach ($list in 'allow', 'ask', 'deny') {
      if (HasProp $base.permissions $list) {
        $existing = @()
        if (HasProp $cur.permissions $list) { $existing = @($cur.permissions.$list) }
        $merged = @($existing + @($base.permissions.$list) | Select-Object -Unique)
        SetProp $cur.permissions $list $merged
      }
    }
  }

  # hooks: kit-owned entries (command runs the kit's bootstrap.ps1) are replaced by the kit's; others are kept
  if (HasProp $base 'hooks') {
    if (-not (HasProp $cur 'hooks')) { SetProp $cur 'hooks' ([pscustomobject]@{}) }
    foreach ($ev in $base.hooks.PSObject.Properties) {
      $curList = @()
      if (HasProp $cur.hooks $ev.Name) {
        $curList = @($cur.hooks.($ev.Name) | Where-Object {
          -not @($_.hooks | Where-Object { $_.command -match '\.claude-kit[\\/]bootstrap\.ps1' }).Count
        })
      }
      SetProp $cur.hooks $ev.Name @($curList + @($ev.Value))
    }
  }

  # defaults: only when missing locally
  foreach ($k in 'autoUpdatesChannel', 'theme', 'model') {
    if ((HasProp $base $k) -and -not (HasProp $cur $k)) { SetProp $cur $k $base.$k }
  }

  $after = ToJson $cur
  $valid = $true
  try { $null = $after | ConvertFrom-Json -ErrorAction Stop } catch { $valid = $false }

  if (-not $valid) {
    Warn 'merged settings.json did not re-parse; left untouched'
  } elseif ($before -eq $after) {
    Say '= settings.json (unchanged)'
  } elseif (-not $Apply) {
    # The copies hold the whole settings.json, credentials included, so they never outlive the diff
    $a = Join-Path $env:TEMP 'claude-settings.current.json'
    $b = Join-Path $env:TEMP 'claude-settings.merged.json'
    try {
      [IO.File]::WriteAllText($a, $before, $utf8)
      [IO.File]::WriteAllText($b, $after, $utf8)
      Say '~ settings.json would change:'
      & git --no-pager diff --no-index --no-color -U1 -- $a $b
    } finally {
      Remove-Item $a, $b -Force -ErrorAction SilentlyContinue
    }
  } else {
    Backup $curPath
    [IO.File]::WriteAllText($curPath, $after, $utf8)
    Say '+ settings.json updated (backup kept)'
  }

  # Credentials belong in the user environment, not in a settings file that gets backed up
  if (HasProp $cur 'env') {
    $secretKeys = @($cur.env.PSObject.Properties.Name | Where-Object { $_ -match '(TOKEN|API_KEY|SECRET|PASSWORD)' })
    if ($secretKeys.Count) {
      Warn "settings.json env holds credentials ($($secretKeys -join ', ')); move them to user environment variables (see README, Security notes)"
    }
  }

  if (HasProp $cur 'permissions') {
    $deadRules = @(Find-MidWildcardRules $cur.permissions)
    if ($deadRules.Count) {
      Warn "permission rules never match, ':*' works only at the end ($($deadRules -join ', ')); use a space-separated '*' instead"
    }
  }
}

# 3. Global rules, status line script, and the folder for machine-local rules
Initialize-RulesDir $claude
if ($stashPending) {
  Say "~ $claude\CLAUDE.md and statusline.js not updated while local edits wait in the kit's stash"
} else {
  Merge-KitFile (Join-Path $KitDir 'global\CLAUDE.md') (Join-Path $claude 'CLAUDE.md') 'CLAUDE.md'
  Merge-KitFile (Join-Path $KitDir 'global\statusline.js') (Join-Path $claude 'statusline.js') 'statusline.js'
}

$shadowed = @(Find-ShadowedSkills (Join-Path $claude 'skills') $KitDir)
if ($shadowed.Count) {
  Warn "user skills in $claude\skills share a name with kit plugin skills ($($shadowed -join ', ')); remove the local copy if the kit's version replaces it"
}

# 4. Plugins: install the missing ones; refresh the kit plugin when it is behind the clone
$installedPath = Join-Path $claude 'plugins\installed_plugins.json'
$installed = @()
$installedJson = ReadJson $installedPath
if ((HasProp $installedJson 'plugins')) { $installed = @($installedJson.plugins.PSObject.Properties.Name) }
$wanted = @()
if (HasProp $base 'enabledPlugins') { $wanted = @($base.enabledPlugins.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { $_.Name }) }
$missing = @($wanted | Where-Object { $installed -notcontains $_ })
$claudeCli = Get-Command claude -ErrorAction SilentlyContinue

# The SessionStart hook is async, so these calls never delay the session
function Run-Claude([string[]]$cliArgs) {
  if ($Quiet) { $null = & $claudeCli.Source @cliArgs 2>&1 } else { & $claudeCli.Source @cliArgs }
  return ($LASTEXITCODE -eq 0)
}

foreach ($id in $missing) {
  if (-not $Apply) { Say "~ would install plugin $id"; continue }
  if (-not $claudeCli) { Warn "claude CLI not found; run in Claude Code: /plugin install $id"; continue }
  Say "+ installing plugin $id"
  if (Run-Claude @('plugin', 'install', $id, '--scope', 'user')) { $installed += $id }
  else { Warn "install failed for $id; run in Claude Code: /plugin install $id" }
}

# Remove the old plugin only once its replacement is in place, so the commands never disappear
if ($installed -contains 'claude-kit@workshop') {
  if (-not $Apply) { Say '~ would uninstall plugin claude-kit@workshop (renamed to toolkit@workshop)' }
  elseif ($claudeCli -and ($installed -contains 'toolkit@workshop')) {
    Say '+ uninstalling plugin claude-kit@workshop (renamed to toolkit@workshop)'
    if (-not (Run-Claude @('plugin', 'uninstall', 'claude-kit@workshop', '--scope', 'user'))) { Warn 'uninstall failed for claude-kit@workshop; run in Claude Code: /plugin uninstall claude-kit@workshop' }
  }
}

# Also catches a clone updated by hand, or a refresh that failed on an earlier run
$pluginSha = $null
if ($installed -contains 'toolkit@workshop') { $pluginSha = @($installedJson.plugins.'toolkit@workshop')[0].gitCommitSha }
$pluginBehind = $pulled -or (Test-PluginBehind $KitDir $pluginSha)
if ($pluginBehind -and -not $Apply -and ($installed -contains 'toolkit@workshop')) { Say '~ would refresh toolkit@workshop' }
if ($Apply -and $pluginBehind -and $claudeCli -and ($installed -contains 'toolkit@workshop')) {
  Say '+ refreshing toolkit@workshop (restart Claude Code to load it)'
  if (-not (Run-Claude @('plugin', 'marketplace', 'update', 'workshop'))) { Warn 'marketplace update failed for workshop' }
  elseif (-not (Run-Claude @('plugin', 'update', 'toolkit@workshop', '--scope', 'user'))) { Warn 'plugin update failed for toolkit@workshop' }
}

# 5. Record what was applied and any warnings (read by the status line)
if ($Apply) {
  $newState = [pscustomobject]@{
    lastRun  = (Get-Date).ToString('o')
    lastPull = $lastPull.ToString('o')
    applied  = [pscustomobject]$applied
    warnings = @($warnings)
  }
  [IO.File]::WriteAllText($statePath, (ToJson $newState), $utf8)
} else {
  Say "`nPreview only. Re-run with -Apply to write."
}

# 6. Wake Claude: the asyncRewake hook shows stderr to Claude on exit code 2, even before the user's first prompt
if ($Quiet -and $warnings.Count) {
  # Raw UTF-8 bytes, so the console code page cannot garble a path with accents
  $bytes = $utf8.GetBytes((Get-WarningText $warnings $KitDir $statePath) + "`n")
  $stderr = [Console]::OpenStandardError()
  $stderr.Write($bytes, 0, $bytes.Length)
  $stderr.Flush()
  exit 2
}
