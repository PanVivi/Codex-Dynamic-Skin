[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$windowsRoot = Split-Path -Parent $PSScriptRoot
$injectorPath = Join-Path $windowsRoot 'scripts\injector.mjs'
$rendererPath = Join-Path $windowsRoot 'assets\renderer-inject.js'
$bootstrapTestPath = Join-Path $windowsRoot 'tests\injector-bootstrap.test.mjs'
$rendererTestPath = Join-Path $windowsRoot 'tests\renderer-inject.test.mjs'
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

# injector.mjs: accept both legacy Codex shell markers and the semantic shell
# observed on Codex 26.903.8094.0. Keep the old selectors for backward compatibility.
$injector = [System.IO.File]::ReadAllText($injectorPath)
$injector = Replace-Exact $injector `
  "      shell: Boolean(document.querySelector('main.main-surface'))," `
  '      shell: Boolean(document.querySelector(''main.main-surface, main:has([role="main"])'')),' `
  'injector probe shell'
$injector = Replace-Exact $injector `
  "      composer: Boolean(document.querySelector('.composer-surface-chrome'))," `
  '      composer: Boolean(document.querySelector(''.composer-surface-chrome, [role="textbox"]'')),' `
  'injector probe composer'
$injector = Replace-Exact $injector `
  "      const shell = document.querySelector('main.main-surface');" `
  '      const shell = document.querySelector(''main.main-surface, main:has([role="main"])'');' `
  'injector early shell'
$injector = Replace-Exact $injector `
  "      composer: box(document.querySelector('.composer-surface-chrome'))," `
  '      composer: box(document.querySelector(''.composer-surface-chrome, [role="textbox"]'')),' `
  'injector verify composer'
[System.IO.File]::WriteAllText($injectorPath, $injector, $utf8)

# renderer-inject.js: for post-26.903 builds, restore stable legacy class hooks at
# runtime. This avoids depending on Codex CSS-module suffixes such as _ihb90_2.
$renderer = [System.IO.File]::ReadAllText($rendererPath)
$renderer = Replace-Exact $renderer `
  '    const shellPresent = Boolean(document.querySelector("main.main-surface"));' `
  '    const shellPresent = Boolean(document.querySelector("main.main-surface, main:has([role=''main''])"));' `
  'renderer media shell'

$oldShell = '    const shellMain = document.querySelector("main.main-surface");'
$newShell = @'
    const legacyShellMain = document.querySelector("main.main-surface");
    const shellMain = legacyShellMain || document.querySelector("main:has([role='main'])");
    if (shellMain && !legacyShellMain) {
      shellMain.classList.add("main-surface", "codex-dream-skin-main-alias");
    }
    const legacyComposerSurface = document.querySelector(".composer-surface-chrome");
    const composerSurface = legacyComposerSurface ||
      document.querySelector('[role="textbox"]')?.closest?.('[class*="_ComposerLayoutRoot_"]') ||
      document.querySelector('[role="textbox"]') || null;
    if (composerSurface && !legacyComposerSurface) {
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

# The upstream regression fixtures model the old selector literally. Teach those
# fixtures about the additional semantic selector so the same tests exercise the
# compatibility path rather than failing before the payload can run.
$bootstrapTest = [System.IO.File]::ReadAllText($bootstrapTestPath)
$bootstrapTest = Replace-Exact $bootstrapTest `
  '        if (selector === "main.main-surface") return markers.shell ? {} : null;' `
  '        if (selector === "main.main-surface" || selector === ''main.main-surface, main:has([role="main"])'') return markers.shell ? {} : null;' `
  'bootstrap fixture semantic shell'
[System.IO.File]::WriteAllText($bootstrapTestPath, $bootstrapTest, $utf8)

$rendererTest = [System.IO.File]::ReadAllText($rendererTestPath)
$oldRendererFixture = '      if (selector === "main.main-surface") return hasShell ? shellMain : null;'
$newRendererFixture = @'
      if (selector === "main.main-surface" ||
          selector === "main:has([role='main'])" ||
          selector === "main.main-surface, main:has([role='main'])") {
        return hasShell ? shellMain : null;
      }
'@.TrimEnd()
$rendererTest = Replace-Exact $rendererTest $oldRendererFixture $newRendererFixture 'renderer fixture semantic shell'
[System.IO.File]::WriteAllText($rendererTestPath, $rendererTest, $utf8)

# Fail fast if the resulting source is incomplete or still depends exclusively
# on the legacy shell/composer markers.
$checks = @(
  @{ Path = $injectorPath; Pattern = 'main:has\(\[role="main"\]\)' },
  @{ Path = $injectorPath; Pattern = '\[role="textbox"\]' },
  @{ Path = $rendererPath; Pattern = 'codex-dream-skin-main-alias' },
  @{ Path = $rendererPath; Pattern = 'codex-dream-skin-composer-alias' },
  @{ Path = $rendererPath; Pattern = '_ComposerLayoutRoot_' },
  @{ Path = $bootstrapTestPath; Pattern = 'main\.main-surface, main:has' },
  @{ Path = $rendererTestPath; Pattern = 'main:has' }
)
foreach ($check in $checks) {
  if (-not [regex]::IsMatch([System.IO.File]::ReadAllText($check.Path), $check.Pattern)) {
    throw "Compatibility verification failed for $($check.Path): $($check.Pattern)"
  }
}

Write-Host 'Codex 26.903 compatibility patch applied successfully.' -ForegroundColor Green
