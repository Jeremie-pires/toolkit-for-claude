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
  git pull runs at most once every 24 hours, upstream changes to files that run code
  (bootstrap.ps1, settings.base.json, statusline.js, plugin hooks, agents and scripts) are held back until a
  manual -Apply, and warnings go to ~/.claude/claude-kit-sync.json (the status line shows
  them as "kit!").

  What it touches: ~/.claude/settings.json (merged, backed up), ~/.claude/CLAUDE.md,
  ~/.claude/statusline.js, ~/.claude/claude-kit-sync.json. The first backup of each file is
  also kept for good as <file>.pre-kit. It never touches credentials, history or projects.
  When CLAUDE_CONFIG_DIR is set, that folder replaces ~/.claude everywhere above.
#>
[CmdletBinding()]
param(
  [switch]$Apply,
  [switch]$Quiet,
  [switch]$Force,
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
function FileHash($p) { if (Test-Path $p) { return (Get-FileHash $p).Hash } return '' }
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
# Kit-owned files: overwrite only if the local copy is the one the kit wrote last time.
# A local edit is kept (with a warning) in -Quiet mode, and backed up then replaced otherwise.
function Sync-File($src, $dst, $key) {
  if (-not (Test-Path $src)) { return }
  $srcHash = FileHash $src
  $dstHash = FileHash $dst
  if ($srcHash -eq $dstHash) { $applied[$key] = $srcHash; Say "= $dst (unchanged)"; return }
  $editedLocally = $dstHash -and $applied[$key] -and ($dstHash -ne $applied[$key])
  if (-not $Apply) {
    $note = ''
    if ($editedLocally) { $note = ' (local edits will be backed up)' }
    Say "~ would update $dst$note"
    return
  }
  if ($editedLocally -and $Quiet) {
    Warn "$dst was edited outside the kit; not replaced. Move the change to the kit, then run bootstrap.ps1 -Apply."
    return
  }
  Backup $dst
  Copy-Item $src $dst -Force
  $applied[$key] = $srcHash
  Say "+ updated $dst"
}

if (-not (Test-Path $claude)) { New-Item -ItemType Directory -Force $claude | Out-Null }

$state = ReadJson $statePath
if ($null -eq $state) { $state = [pscustomobject]@{} }
$applied = @{}
if (HasProp $state 'applied') { foreach ($p in $state.applied.PSObject.Properties) { $applied[$p.Name] = $p.Value } }
$lastPull = [datetime]::MinValue
if (HasProp $state 'lastPull') { [void][datetime]::TryParse($state.lastPull, [ref]$lastPull) }

# 1. Get / update the kit (fast-forward only; offline is fine; throttled in -Quiet mode)
$pulled = $false
if (Test-Path (Join-Path $KitDir '.git')) {
  $due = $Force -or -not $Quiet -or ((Get-Date) - $lastPull) -ge $pullEvery
  if ($due) {
    $headBefore = (& git -C $KitDir rev-parse HEAD 2>$null)
    $null = & git -C $KitDir -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 fetch --quiet 2>&1
    $held = @()
    if ($LASTEXITCODE -eq 0) {
      $held = Get-HeldChanges $KitDir $reviewPattern
    }
    if ($LASTEXITCODE -ne 0) {
      Warn 'git fetch skipped (offline, auth, or no upstream branch); using the local copy'
    } elseif ($held.Count -and ($Quiet -or -not $Apply)) {
      # lastPull is left as is, so the check runs again at every launch until the change is reviewed
      Warn "upstream changes to $($held -join ', ') wait for review: read git -C $KitDir log -p HEAD..@{u}, then run bootstrap.ps1 -Apply"
    } else {
      foreach ($f in $held) { Say "~ upstream change to $f (runs code on this machine)" }
      $null = & git -C $KitDir merge --ff-only --quiet '@{u}' 2>&1
      if ($LASTEXITCODE -eq 0) {
        $lastPull = Get-Date
        $pulled = $headBefore -ne (& git -C $KitDir rev-parse HEAD 2>$null)
      } else {
        Warn 'git merge skipped (local changes or diverged history in the kit); using the local copy'
      }
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

# 3. Global rules and status line script
Sync-File (Join-Path $KitDir 'global\CLAUDE.md') (Join-Path $claude 'CLAUDE.md') 'CLAUDE.md'
Sync-File (Join-Path $KitDir 'global\statusline.js') (Join-Path $claude 'statusline.js') 'statusline.js'

$shadowed = @(Find-ShadowedSkills (Join-Path $claude 'skills') $KitDir)
if ($shadowed.Count) {
  Warn "user skills in $claude\skills share a name with kit plugin skills ($($shadowed -join ', ')); remove the local copy if the kit's version replaces it"
}

# 4. Plugins: install the missing ones; after a pull with new commits, refresh the kit plugin
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

if ($Apply -and $pulled -and $claudeCli -and ($installed -contains 'toolkit@workshop')) {
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
