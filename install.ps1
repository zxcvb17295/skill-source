<#
Windows installer for Skill Source, using NTFS junctions (no symlink privilege).

Counterpart of install.sh:
  1. sync submodules and put each one on its .gitmodules branch
     (every submodule must have a clean working tree)
  2. link skills/ with scripts/sync-junctions.ps1
  3. point ~/.agents/skills and ~/.claude/skills at skills/ with a junction

Usage:
  .\install.ps1 -WhatIf   # preview, nothing is changed
  .\install.ps1           # install
  .\install.ps1 -Yes      # do not ask before replacing an existing target

An existing target that is not already our junction is renamed to
<name>.bak-<time>; it is never deleted. A junction is only unlinked, its
target is never touched.
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch]$Yes)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$skillsDir = Join-Path $root 'skills'
$reparse = [IO.FileAttributes]::ReparsePoint

function Invoke-Git([string]$Dir, [string[]]$GitArgs) {
  $out = & git -C $Dir @GitArgs
  if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed in $Dir (exit $LASTEXITCODE)" }
  $out
}
function Test-Git([string]$Dir, [string[]]$GitArgs) {
  $ErrorActionPreference = 'Continue'
  & git -C $Dir @GitArgs *> $null
  $LASTEXITCODE -eq 0
}
function Get-NormalPath([string]$Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
function Get-LinkTarget($Item) {
  $raw = $Item.Target | Select-Object -First 1
  if ($raw) { Get-NormalPath (([string]$raw) -replace '^\\\?\?\\', '') }
}

if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
  throw 'Run this from the Skill Source Git repository.'
}

# 1. Submodules ---------------------------------------------------------------
if ([IO.File]::Exists((Join-Path $root '.gitmodules'))) {
  if ($PSCmdlet.ShouldProcess($root, 'git submodule sync + update --init --recursive --merge')) {
    Invoke-Git $root @('submodule', 'sync', '--recursive') | Write-Host
    Invoke-Git $root @('submodule', 'update', '--init', '--recursive', '--merge') | Write-Host
  }

  foreach ($line in @(& git -C $root config -f .gitmodules --get-regexp '^submodule\..*\.path$')) {
    if (-not $line) { continue }
    $key, $path = $line -split ' ', 2
    $name = $key -replace '^submodule\.', '' -replace '\.path$', ''

    $branch = & git -C $root config -f .gitmodules --get "submodule.$name.branch"
    if (-not $branch) { throw "submodule '$name' has no branch in .gitmodules" }
    if (-not (Test-Git $root @('check-ref-format', '--branch', $branch))) { throw "invalid upstream branch name: $branch" }
    if ($path -notlike 'sources/*' -or $path -like '*/../*' -or $path.Substring(8) -like '*/*') {
      throw "every source must sit directly under sources/: $path"
    }

    $dir = Join-Path $root $path
    if (-not [IO.Directory]::Exists($dir)) {
      if ($WhatIfPreference) { Write-Host "SKIP      $path (not initialized yet)"; continue }
      throw "submodule not initialized: $path"
    }
    if (Invoke-Git $dir @('status', '--porcelain')) {
      throw "submodule has uncommitted changes or untracked files, handle them first: $path"
    }

    if ($PSCmdlet.ShouldProcess($path, "fetch origin $branch and track it")) {
      $commit = Invoke-Git $dir @('rev-parse', 'HEAD')
      Invoke-Git $dir @('fetch', 'origin', $branch) | Out-Null
      if (-not (Test-Git $dir @('show-ref', '--verify', '--quiet', "refs/remotes/origin/$branch"))) {
        throw "upstream branch origin/$branch not found: $path"
      }
      if ((Invoke-Git $dir @('branch', '--show-current')) -ne $branch) {
        if (Test-Git $dir @('show-ref', '--verify', '--quiet', "refs/heads/$branch")) {
          Invoke-Git $dir @('switch', $branch) | Out-Null
        } else {
          Invoke-Git $dir @('switch', '-c', $branch, $commit) | Out-Null
        }
      }
      Invoke-Git $dir @('branch', '--set-upstream-to', "origin/$branch", $branch) | Out-Null
      Write-Host "READY     $path ($branch)"
    }
  }
}

# 2. skills/ junctions --------------------------------------------------------
$sync = Join-Path $root 'scripts\sync-junctions.ps1'
$global:LASTEXITCODE = 0
if ($WhatIfPreference) { & $sync -WhatIf } else { & $sync }
if ($LASTEXITCODE -ne 0) { throw 'sync-junctions.ps1 reported warnings; fix them and rerun.' }

if (-not $WhatIfPreference) {
  $has = Get-ChildItem -LiteralPath $skillsDir -Directory -Force |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf } |
    Select-Object -First 1
  if (-not $has) { throw 'no installable skill found under skills/' }
}

# 3. ~/.agents/skills and ~/.claude/skills ------------------------------------
function Set-SkillsLink([string]$Path) {
  $want = Get-NormalPath $skillsDir
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  $isLink = $false
  if ($item) {
    $isLink = ($item.Attributes -band $reparse) -eq $reparse
    if ($isLink -and (Get-LinkTarget $item) -ieq $want) { Write-Host "KEEP      $Path"; return }
    Write-Host "Existing target will be moved aside: $Path"
    if ($isLink) { Write-Host "  (junction -> $(Get-LinkTarget $item))" }
    elseif ($item.PSIsContainer) {
      Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 20 | ForEach-Object { Write-Host "  $($_.Name)" }
    }
    if (-not $Yes -and -not $WhatIfPreference) {
      if ((Read-Host 'Type yes to continue') -ne 'yes') { throw "cancelled; $Path unchanged" }
    }
  }
  if ($PSCmdlet.ShouldProcess($Path, "Junction -> $want")) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    if ($item) {
      if ($isLink) { [IO.Directory]::Delete($Path, $false) }   # removes the link only
      else { Rename-Item -LiteralPath $Path -NewName ((Split-Path -Leaf $Path) + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    }
    New-Item -ItemType Junction -Path $Path -Target $want | Out-Null
    Write-Host "LINKED    $Path -> $want"
  }
}

Set-SkillsLink (Join-Path $HOME '.agents\skills')
Set-SkillsLink (Join-Path $HOME '.claude\skills')

# 4. Antigravity (~/.gemini/config/skills) ------------------------------------
$syncAgy = Join-Path $root 'scripts\sync-antigravity-skills.ps1'
$global:LASTEXITCODE = 0
if ($WhatIfPreference) { & $syncAgy -WhatIf } else { & $syncAgy }
if ($LASTEXITCODE -ne 0) { throw 'sync-antigravity-skills.ps1 reported warnings; fix them and rerun.' }

Write-Host 'Done.'
