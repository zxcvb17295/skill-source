# Sync skills/ with sources/ using NTFS junctions (no symlink privilege needed).
#
# Windows counterpart of sync-skill-links.sh for machines where creating
# symlinks is not allowed. It follows the same rules:
#   - every directory under sources/ that holds a SKILL.md is a skill; dot
#     directories, node_modules and in-progress/ are skipped
#   - the skill is linked as skills/<dir name>; when that name is already used
#     by a skill from another source, skills/<source>-<dir name> is used
#   - a directory literally named "skill" is linked by its SKILL.md frontmatter
#     name instead (Agent-Reach's agent_reach/skill -> skills/agent-reach)
#   - directories matching a glob in .skillignore (relative to sources/) are
#     skipped; only registered submodules and sources/local are scanned
#   - links whose target disappeared are removed
#   - skills/graphify is a real directory: skill-codex.md is copied in as
#     SKILL.md and references/ is linked to the Codex references
# It also turns text placeholders left by a core.symlinks=false checkout
# (a file holding ../sources/...) into junctions.
#
# Usage:
#   .\scripts\sync-junctions.ps1 -WhatIf   # preview only, nothing is changed
#   .\scripts\sync-junctions.ps1           # apply
#
# Do not `git add skills/` on a machine where this was applied: the working
# tree then holds junctions instead of the symlink entries recorded by Git.
# Junction targets are absolute, so rerun this script if the repo is moved.
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$skillsDir = Join-Path $root 'skills'
$sourcesDir = [IO.Path]::GetFullPath((Join-Path $root 'sources'))
$sep = [string][IO.Path]::DirectorySeparatorChar
$ignoreCase = [StringComparison]::OrdinalIgnoreCase
$reparse = [IO.FileAttributes]::ReparsePoint

if (-not [IO.Directory]::Exists($sourcesDir)) { throw "sources directory not found: $sourcesDir" }
if (-not [IO.Directory]::Exists($skillsDir)) { throw "skills directory not found: $skillsDir" }

function Get-NormalPath([string]$Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
function Test-UnderSources([string]$Path) { $Path.StartsWith($sourcesDir + $sep, $ignoreCase) }
function Get-SourceName([string]$Path) { ($Path.Substring($sourcesDir.Length + 1) -split '[\\/]')[0] }
function Test-Reparse($Item) { ($Item.Attributes -band $reparse) -eq $reparse }
function Get-LinkTarget($Item) {
  $raw = $Item.Target | Select-Object -First 1
  if ($raw) { Get-NormalPath (([string]$raw) -replace '^\\\?\?\\', '') }
}
# Directory.Delete(path, $false) removes the reparse point only, never the target.
function Remove-LinkOnly([string]$Path) { [IO.Directory]::Delete($Path, $false) }
function New-DirJunction([string]$Path, [string]$Target) {
  New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
}
# Get-FileHash is missing in some Windows PowerShell 5.1 sessions; use .NET directly.
function Get-FileSha256([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) }
  finally { $sha.Dispose() }
}

# Every registered source must be checked out, otherwise its links would look dead.
# Only registered submodules (plus the in-repo sources/local) are scanned, so
# leftover folders of removed sources never turn into skills.
$registered = @{ 'local' = $true }
foreach ($line in @(git -C $root config -f .gitmodules --get-regexp '^submodule\..*\.path$')) {
  if (-not $line) { continue }
  $rel = ($line -split ' ', 2)[1]
  if (-not (Test-Path -LiteralPath (Join-Path $root "$rel\.git"))) {
    throw "source not initialized: $rel (run git submodule update --init first)"
  }
  $registered[($rel -split '[\\/]')[-1]] = $true
}

# .skillignore: one glob per line, relative to sources/, '#' starts a comment.
$ignoreGlobs = @()
$ignoreFile = Join-Path $root '.skillignore'
if ([IO.File]::Exists($ignoreFile)) {
  $ignoreGlobs = @([IO.File]::ReadAllLines($ignoreFile) | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
}
function Test-Ignored([string]$Dir) {
  $rel = $Dir.Substring($sourcesDir.Length + 1) -replace '\\', '/'
  foreach ($g in $ignoreGlobs) { if ($rel -like $g) { return $true } }
  $false
}
# A directory literally named "skill" is too generic; sync-skill-links.sh then uses the frontmatter name.
function Get-SkillLinkName([string]$Dir) {
  $leaf = [IO.Path]::GetFileName($Dir)
  if ($leaf -ne 'skill') { return $leaf }
  $lines = [IO.File]::ReadAllLines((Join-Path $Dir 'SKILL.md'))
  if ($lines.Count -gt 1 -and $lines[0] -eq '---') {
    foreach ($l in $lines[1..($lines.Count - 1)]) {
      if ($l -eq '---') { break }
      if ($l -match '^name:\s*(.+?)\s*$') {
        $fm = $Matches[1]   # copy first: the next -match overwrites $Matches
        if ($fm -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return $fm }
      }
    }
  }
  $leaf
}

$counts = [ordered]@{ Created = 0; Repointed = 0; Converted = 0; Removed = 0; Unchanged = 0; Warnings = 0 }
$links = @{}   # name -> target of managed junctions, as they are or will be after this run
$taken = @{}   # name -> why an existing entry blocks that name

function Write-Warn([string]$Message) {
  $counts.Warnings++
  Write-Host "WARN      $Message"
}

# Pass 1: inspect skills/, drop dead links, convert text placeholders.
foreach ($item in Get-ChildItem -LiteralPath $skillsDir -Force) {
  $name = $item.Name
  $path = $item.FullName

  if (Test-Reparse $item) {
    $target = Get-LinkTarget $item
    if ($target -and [IO.Directory]::Exists($target)) {
      if (Test-UnderSources $target) { $links[$name] = $target }
      else { $taken[$name] = "link outside sources: $target" }
      continue
    }
    if ($name -match '\.repair\.' -or ($target -and (Test-UnderSources $target))) {
      if ($PSCmdlet.ShouldProcess($path, 'Remove dangling link')) {
        Remove-LinkOnly $path
        Write-Host "REMOVED   $name (dangling link)"
      }
      $counts.Removed++
    } else {
      $taken[$name] = 'dangling link not managed here'
      Write-Warn "$name is a dangling link that is not managed here; left alone"
    }
    continue
  }

  if ($item.PSIsContainer) { $taken[$name] = 'real directory'; continue }

  $text = [IO.File]::ReadAllText($path).Trim()
  if ($text -match '^\.\./sources/[^\r\n]+$') {
    $target = Get-NormalPath (Join-Path $skillsDir $text)
    if ((Test-UnderSources $target) -and [IO.Directory]::Exists($target)) {
      if ($PSCmdlet.ShouldProcess($path, "Replace text placeholder with junction -> $target")) {
        Remove-Item -LiteralPath $path -Force
        try { New-DirJunction $path $target }
        catch { [IO.File]::WriteAllText($path, $text); throw }   # never lose the placeholder
        Write-Host "CONVERTED $name -> $target"
      }
      $links[$name] = $target
      $counts.Converted++
      continue
    }
    Write-Warn "$name placeholder target is missing: $text"
  }
  $taken[$name] = 'regular file'
}

# Pass 2: discover skills in sources/ and add or fix their links.
function Find-SkillDirs([string]$Dir) {
  # Windows file names are case-insensitive; sync-skill-links.sh matches SKILL.md
  # exactly, so a lowercase skill.md (as Graphify ships) must not count.
  $hasManifest = [IO.Directory]::EnumerateFiles($Dir, 'SKILL.md') |
    Where-Object { [IO.Path]::GetFileName($_) -ceq 'SKILL.md' } | Select-Object -First 1
  if ($hasManifest) { $Dir }
  foreach ($sub in [IO.Directory]::EnumerateDirectories($Dir)) {
    $leaf = [IO.Path]::GetFileName($sub)
    if ($leaf.StartsWith('.') -or $leaf -eq 'node_modules') { continue }
    if (([IO.File]::GetAttributes($sub) -band $reparse) -eq $reparse) { continue }
    Find-SkillDirs $sub
  }
}

$skillDirs = @(Find-SkillDirs $sourcesDir | Where-Object {
    $_ -ne $sourcesDir -and
    ($_.Substring($sourcesDir.Length + 1) -split '[\\/]') -notcontains 'in-progress' -and
    $registered.ContainsKey((Get-SourceName $_)) -and
    -not (Test-Ignored $_)
  } | Sort-Object)
$skillSet = @{}
foreach ($d in $skillDirs) { $skillSet[$d] = $true }

foreach ($dir in $skillDirs) {
  $name = Get-SkillLinkName $dir
  $srcName = Get-SourceName $dir
  $linkName = $name

  if ($links.ContainsKey($name)) {
    $existing = $links[$name]
    if ($existing -ieq $dir) { $counts.Unchanged++; continue }

    $stale = -not $skillSet.ContainsKey($existing)
    if ($stale -and (Get-SourceName $existing) -ieq $srcName) {
      # Same source, skill moved: re-point the existing link.
      $lp = Join-Path $skillsDir $name
      if ($PSCmdlet.ShouldProcess($lp, "Re-point junction $existing -> $dir")) {
        Remove-LinkOnly $lp
        try { New-DirJunction $lp $dir }
        catch { New-DirJunction $lp $existing; throw }
        Write-Host "REPOINTED $name -> $dir"
      }
      $links[$name] = $dir
      $counts.Repointed++
      continue
    }

    # Name belongs to another skill: fall back to <source>-<name>.
    $linkName = "$srcName-$name"
    if ($links.ContainsKey($linkName)) {
      if ($links[$linkName] -ieq $dir) { $counts.Unchanged++ }
      else { Write-Warn "alias $linkName already points elsewhere; skipped $dir" }
      continue
    }
  }

  if ($taken.ContainsKey($linkName)) {
    Write-Warn "cannot link $linkName -> $dir ($linkName is a $($taken[$linkName]))"
    continue
  }

  $lp = Join-Path $skillsDir $linkName
  if ($PSCmdlet.ShouldProcess($lp, "Create junction -> $dir")) {
    New-DirJunction $lp $dir
    Write-Host "CREATED   $linkName -> $dir"
  }
  $links[$linkName] = $dir
  $counts.Created++
}

# Pass 3: Graphify publishes per-platform files instead of SKILL.md.
$gSrc = Join-Path $sourcesDir 'graphify\graphify'
$gCodex = Join-Path $gSrc 'skill-codex.md'
$gRefTarget = Get-NormalPath (Join-Path $gSrc 'skills\codex\references')
$gDir = Join-Path $skillsDir 'graphify'

if ([IO.File]::Exists($gCodex)) {
  $gItem = Get-Item -LiteralPath $gDir -Force -ErrorAction SilentlyContinue
  if ($gItem -and (Test-Reparse $gItem)) {
    Write-Warn "$gDir must be a real directory, not a link; Graphify adapter skipped"
  } elseif ($gItem -and -not $gItem.PSIsContainer) {
    Write-Warn "$gDir is a file; Graphify adapter skipped"
  } else {
    if (-not $gItem -and $PSCmdlet.ShouldProcess($gDir, 'Create directory')) {
      New-Item -ItemType Directory -Path $gDir | Out-Null
    }

    $gManifest = Join-Path $gDir 'SKILL.md'
    if (Test-Path -LiteralPath $gManifest -PathType Container) {
      Write-Warn "$gManifest is not a regular file; skipped"
    } elseif ((-not [IO.File]::Exists($gManifest)) -or
              ((Get-FileSha256 $gManifest) -ne (Get-FileSha256 $gCodex))) {
      if ($PSCmdlet.ShouldProcess($gManifest, 'Copy skill-codex.md')) {
        Copy-Item -LiteralPath $gCodex -Destination $gManifest -Force
        Write-Host "COPIED    graphify\SKILL.md"
      }
      $counts.Created++
    } else {
      $counts.Unchanged++
    }

    $gRef = Join-Path $gDir 'references'
    $refItem = Get-Item -LiteralPath $gRef -Force -ErrorAction SilentlyContinue
    $replace = $false
    $create = $false
    if (-not [IO.Directory]::Exists($gRefTarget)) {
      Write-Warn "Graphify references target is missing: $gRefTarget"
    } elseif (-not $refItem) {
      $create = $true
    } elseif (Test-Reparse $refItem) {
      if ((Get-LinkTarget $refItem) -ieq $gRefTarget) { $counts.Unchanged++ } else { $replace = $true }
    } elseif ((-not $refItem.PSIsContainer) -and
              ([IO.File]::ReadAllText($refItem.FullName).Trim() -match '^\.\./\.\./sources/[^\r\n]+$')) {
      $replace = $true   # text placeholder from a core.symlinks=false checkout
    } else {
      Write-Warn "$gRef exists and is not a link; left alone"
    }

    if ($create -or $replace) {
      if ($PSCmdlet.ShouldProcess($gRef, "Link junction -> $gRefTarget")) {
        if ($replace) {
          if ($refItem.PSIsContainer) { Remove-LinkOnly $gRef } else { Remove-Item -LiteralPath $gRef -Force }
        }
        New-DirJunction $gRef $gRefTarget
        Write-Host "LINKED    graphify\references -> $gRefTarget"
      }
      if ($replace) { $counts.Converted++ } else { $counts.Created++ }
    }
  }
}

Write-Host ''
Write-Host ('Summary: ' + (($counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
if ($counts.Warnings -gt 0) { exit 1 }
