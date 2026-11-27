# Mirror skills from sources/ into real directories for Antigravity on Windows.
#
# Antigravity follows a top-level ~/.agents/skills junction, but skips child
# NTFS junctions (ReparsePoint) under skills/, so only real directories load.
# This script mirrors each discovered skill from sources/ into
# ~/.gemini/config/skills/<name> using robocopy /MIR, leaving Claude Code and
# Codex junctions untouched.
#
# Discovery and naming rules match scripts/sync-junctions.ps1:
#   - only registered submodules (.gitmodules) and sources/local are scanned
#   - dot directories, node_modules, in-progress/ and .skillignore globs are skipped
#   - SKILL.md is matched case-sensitively
#   - a directory literally named "skill" uses its SKILL.md frontmatter name
#   - duplicate names match skills/<name> when present, otherwise <source>-<name>
#
# Managed directories are tracked in .skill-source-managed.json inside TargetDir
# so removed/ignored skills are pruned without touching manually added skills.
#
# Usage:
#   .\scripts\sync-antigravity-skills.ps1 -WhatIf   # preview only
#   .\scripts\sync-antigravity-skills.ps1           # sync to ~/.gemini/config/skills
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$TargetDir = (Join-Path $HOME '.gemini\config\skills')
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$skillsDir = Join-Path $root 'skills'
$sourcesDir = [IO.Path]::GetFullPath((Join-Path $root 'sources'))
$targetRoot = [IO.Path]::GetFullPath($TargetDir)
$manifestPath = Join-Path $targetRoot '.skill-source-managed.json'
$reparse = [IO.FileAttributes]::ReparsePoint

if (-not [IO.Directory]::Exists($sourcesDir)) { throw "sources directory not found: $sourcesDir" }

function Get-NormalPath([string]$Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
function Get-SourceName([string]$Path) { ($Path.Substring($sourcesDir.Length + 1) -split '[\\/]')[0] }
function Test-Reparse($Item) { ($Item.Attributes -band $reparse) -eq $reparse }
function Get-LinkTarget($Item) {
  $raw = $Item.Target | Select-Object -First 1
  if ($raw) { Get-NormalPath (([string]$raw) -replace '^\\\?\?\\', '') }
}

# Only registered submodules (plus in-repo sources/local) are scanned.
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

function Get-SkillBaseName([string]$Dir) {
  $leaf = [IO.Path]::GetFileName($Dir)
  if ($leaf -ne 'skill') { return $leaf }
  $lines = [IO.File]::ReadAllLines((Join-Path $Dir 'SKILL.md'))
  if ($lines.Count -gt 1 -and $lines[0] -eq '---') {
    foreach ($l in $lines[1..($lines.Count - 1)]) {
      if ($l -eq '---') { break }
      if ($l -match '^name:\s*(.+?)\s*$') {
        $fm = $Matches[1]
        if ($fm -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return $fm }
      }
    }
  }
  $leaf
}

function Find-SkillDirs([string]$Dir) {
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

# Resolve target names. For colliding base names (e.g. retro), inspect the
# single existing junction in skills/<name> so naming matches Claude/Codex
# without statting every junction in skills/.
$byBase = [ordered]@{}
foreach ($dir in $skillDirs) {
  $base = Get-SkillBaseName $dir
  if (-not $byBase.Contains($base)) { $byBase[$base] = New-Object System.Collections.Generic.List[string] }
  $byBase[$base].Add((Get-NormalPath $dir))
}

$desired = [ordered]@{}
foreach ($base in $byBase.Keys) {
  $dirs = $byBase[$base]
  if ($dirs.Count -eq 1) {
    $desired[$base] = $dirs[0]
    continue
  }

  $existingTarget = $null
  $existingItem = Get-Item -LiteralPath (Join-Path $skillsDir $base) -Force -ErrorAction SilentlyContinue
  if ($existingItem -and (Test-Reparse $existingItem)) {
    $existingTarget = Get-LinkTarget $existingItem
  }

  $winner = $dirs | Where-Object { $existingTarget -and ($_ -ieq $existingTarget) } | Select-Object -First 1
  if (-not $winner) { $winner = $dirs[0] }
  $desired[$base] = $winner

  foreach ($dir in $dirs) {
    if ($dir -ieq $winner) { continue }
    $alias = "$(Get-SourceName $dir)-$base"
    $desired[$alias] = $dir
  }
}

# Load previously managed skill names so stale entries can be pruned safely.
$managedPrev = @{}
if ([IO.File]::Exists($manifestPath)) {
  $raw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($n in @($raw.skills)) {
    if ($n) { $managedPrev[[string]$n] = $true }
  }
}

$counts = [ordered]@{ Created = 0; Updated = 0; Unchanged = 0; Removed = 0; Warnings = 0 }
$managedNext = New-Object System.Collections.Generic.List[string]

function Write-Warn([string]$Message) {
  $counts.Warnings++
  Write-Host "WARN      $Message"
}

if (-not [IO.Directory]::Exists($targetRoot)) {
  if ($PSCmdlet.ShouldProcess($targetRoot, 'Create Antigravity skills directory')) {
    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
  }
}

foreach ($name in ($desired.Keys | Sort-Object)) {
  $src = $desired[$name]
  $dst = Join-Path $targetRoot $name
  $existing = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue

  if ($existing -and -not $managedPrev.ContainsKey($name)) {
    Write-Warn "skipped $name ($dst already exists and is not managed by skill-source)"
    continue
  }

  $existedBefore = $null -ne $existing
  if ($PSCmdlet.ShouldProcess($dst, "Mirror from $src")) {
    # Exclude .git (both directory and submodule pointer file) and node_modules;
    # /XJ prevents traversing nested junctions inside upstream repos.
    $null = & robocopy $src $dst /MIR /XD .git node_modules /XF .git /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
    $rc = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($rc -ge 8) { throw "robocopy failed (exit $rc) mirroring $name from $src" }

    if (-not $existedBefore) {
      Write-Host "CREATED   $name"
      $counts.Created++
    } elseif ($rc -eq 0) {
      $counts.Unchanged++
    } else {
      Write-Host "UPDATED   $name"
      $counts.Updated++
    }
  } else {
    if ($existedBefore) { $counts.Updated++ } else { $counts.Created++ }
  }
  $managedNext.Add($name)
}

foreach ($oldName in ($managedPrev.Keys | Sort-Object)) {
  if ($desired.Contains($oldName)) { continue }
  $oldPath = Join-Path $targetRoot $oldName
  if (Test-Path -LiteralPath $oldPath) {
    if ($PSCmdlet.ShouldProcess($oldPath, 'Remove stale managed skill')) {
      Remove-Item -LiteralPath $oldPath -Recurse -Force
      Write-Host "REMOVED   $oldName"
    }
    $counts.Removed++
  }
}

if ($PSCmdlet.ShouldProcess($manifestPath, 'Update managed skills manifest')) {
  $manifestObj = [ordered]@{
    source = $root
    skills = @($managedNext | Sort-Object)
  }
  $json = $manifestObj | ConvertTo-Json -Depth 3
  [IO.File]::WriteAllText($manifestPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

$global:LASTEXITCODE = 0
Write-Host ''
Write-Host ('Antigravity Summary: ' + (($counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
if ($counts.Warnings -gt 0) { exit 1 }
