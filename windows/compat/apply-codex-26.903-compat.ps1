[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$windowsRoot = Split-Path -Parent $PSScriptRoot
$injectorPath = Join-Path $windowsRoot 'scripts\injector.mjs'
$rendererPath = Join-Path $windowsRoot 'assets\renderer-inject.js'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Replace-Exact {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Old,
    [Parameter(Mandatory = $true)][string]$New,
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$ExpectedCount = 1
  )

  $count = [regex]::Matches($Text, [regex]::Escape($Old)).Count
  if ($count -ne $ExpectedCount) {
    throw "Patch anchor '$Name' expected $ExpectedCount occurrence(s), found $count. Upstream source changed; refusing a partial patch."
  }
  return $Text.Replace($Old, $New)
}

# injector.mjs: accept the post-26.903 semantic shell and textbox while preserving
# the legacy selectors for older Codex builds.
$injector = [System.IO.File]::ReadAllText($injectorPath)
$injector = Replace-Exact $injector `
  "      shell: Boolean(document.querySelector('main.main-surface'))," `
  "      shell: Boolean(document.querySelector('main.main-surface, main:has([role=`"main`"] )'.replace('] )', '])')))," `
  'injector probe shell'
$injector = Replace-Exact $injector `
  "      composer: Boolean(document.querySelector('.composer-surface-chrome'))," `
  "      composer: Boolean(document.querySelector('.composer-surface-chrome, [role=`"textbox`"]'))," `
  'injector probe composer'
$injector = Replace-Exact $injector `
  "      const shell = document.querySelector('main.main-surface');" `
  "      const shell = document.querySelector('main.main-surface, main:has([role=`"main`"] )'.replace('] )', '])'));" `
  'injector early shell'
$injector = Replace-Exact $injector `
  "      composer: box(document.querySelector('.composer-surface-chrome'))," `
  "      composer: box(document.querySelector('.composer-surface-chrome, [role=`"textbox`"]'))," `
  'injector verify composer'
[System.IO.File]::WriteAllText($injectorPath, $injector, $utf8)

# renderer-inject.js: restore the stable legacy class hooks at runtime instead of
# depending on the hashed CSS-module suffixes used by Codex 26.903.
$renderer = [System.IO.File]::ReadAllText($rendererPath)
$renderer = Replace-Exact $renderer `
  '    const shellPresent = Boolean(document.querySelector("main.main-surface"));' `
  '    const shellPresent = Boolean(document.querySelector("main.main-surface, main:has([role=''main''])"));' `
  'renderer media shell'

$oldShell = '    const shellMain = document.querySelector("main.main-surface");'
$newShell = @'
    const shellMain = document.querySelector("main.main-surface, main:has([role='main'])");
    if (shellMain && !shellMain.classList.contains("main-surface")) {
      shellMain.classList.add("main-surface", "codex-dream-skin-main-alias");
    }
    const composerSurface = document.querySelector(".composer-surface-chrome") ||
      document.querySelector('[role="textbox"]')?.closest?.('[class*="_ComposerLayoutRoot_"]') || null;
    if (composerSurface && !composerSurface.classList.contains("composer-surface-chrome")) {
      composerSurface.classList.add("composer-surface-chrome", "codex-dream-skin-composer-alias");
    }
'@.TrimEnd()
$renderer = Replace-Exact $renderer $oldShell $newShell 'renderer shell aliases'

$oldCleanup = @'
    document.querySelectorAll(`.${TASK_SEARCH_INPUT_CLASS}`).forEach((node) => node.classList.remove(TASK_SEARCH_INPUT_CLASS));
    document.getElementById(STYLE_ID)?.remove();
'@.TrimEnd()
$newCleanup = @'
    document.querySelectorAll(`.${TASK_SEARCH_INPUT_CLASS}`).forEach((node) => node.classList.remove(TASK_SEARCH_INPUT_CLASS));
    document.querySelectorAll(".codex-dream-skin-main-alias").forEach((node) => {
      node.classList.remove("main-surface", "codex-dream-skin-main-alias");
    });
    document.querySelectorAll(".codex-dream-skin-composer-alias").forEach((node) => {
      node.classList.remove("composer-surface-chrome", "codex-dream-skin-composer-alias");
    });
    document.getElementById(STYLE_ID)?.remove();
'@.TrimEnd()
$renderer = Replace-Exact $renderer $oldCleanup $newCleanup 'renderer alias cleanup'
[System.IO.File]::WriteAllText($rendererPath, $renderer, $utf8)

# Fail fast if the resulting files do not contain the compatibility markers.
$checks = @(
  @{ Path = $injectorPath; Pattern = 'main:has\(\[role="main"\]\)' },
  @{ Path = $injectorPath; Pattern = '\[role="textbox"\]' },
  @{ Path = $rendererPath; Pattern = 'codex-dream-skin-main-alias' },
  @{ Path = $rendererPath; Pattern = 'codex-dream-skin-composer-alias' },
  @{ Path = $rendererPath; Pattern = '_ComposerLayoutRoot_' }
)
foreach ($check in $checks) {
  if (-not [regex]::IsMatch([System.IO.File]::ReadAllText($check.Path), $check.Pattern)) {
    throw "Compatibility verification failed for $($check.Path): $($check.Pattern)"
  }
}

Write-Host 'Codex 26.903 compatibility patch applied successfully.' -ForegroundColor Green
