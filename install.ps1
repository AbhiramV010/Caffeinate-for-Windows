<#
.SYNOPSIS
Installs caffeinate for the current user.

.DESCRIPTION
Builds caffeinate.cpp if a C++ compiler is available and installs the resulting
exe. If no compiler is found, falls back to installing the caffeinate.bat /
caffeinate.ps1 pair, which needs no toolchain. Either way the install directory
is added to your user PATH so `caffeinate` works from any shell.

Nothing here needs administrator rights.

.PARAMETER Scripts
Skip compiling and install the .bat/.ps1 version even if a compiler is present.

.PARAMETER Uninstall
Remove the install directory and take it back off your PATH.

.PARAMETER InstallDir
Where to install. Defaults to %LOCALAPPDATA%\Programs\Caffeinate.

.EXAMPLE
.\install.ps1

.EXAMPLE
.\install.ps1 -Scripts

.EXAMPLE
.\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Scripts,
    [switch]$Uninstall,
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\Caffeinate"
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Note($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Warn($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }

# --- user PATH helpers -------------------------------------------------------
# Read/write the *user* PATH from the registry rather than $env:PATH, which is
# the machine and user values already merged together.

function Get-UserPathEntries {
    $raw = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrEmpty($raw)) { return @() }
    # Deliberately keep empty segments. Plenty of real PATHs contain stray ";;"
    # runs, and an installer that quietly tidies them is rewriting something it
    # was never asked to touch. Uninstall should restore the value byte for byte.
    return @($raw -split ';')
}

function Test-PathContains($entries, $dir) {
    $needle = $dir.TrimEnd('\')
    foreach ($e in $entries) {
        if ($e -eq '') { continue }
        if ($e.TrimEnd('\') -ieq $needle) { return $true }
    }
    return $false
}

function Add-ToUserPath($dir) {
    $entries = Get-UserPathEntries
    if (Test-PathContains $entries $dir) {
        Write-Note "already on your PATH"
        return $false
    }
    $updated = (@($entries) + $dir) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
    Write-Note "added to your user PATH"
    return $true
}

function Remove-FromUserPath($dir) {
    $entries = Get-UserPathEntries
    if (-not (Test-PathContains $entries $dir)) { return $false }
    $needle = $dir.TrimEnd('\')
    $kept = @($entries | Where-Object { $_ -eq '' -or $_.TrimEnd('\') -ine $needle })
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
    return $true
}

# --- uninstall ---------------------------------------------------------------

if ($Uninstall) {
    Write-Step "Uninstalling caffeinate"
    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force
        Write-Note "removed $InstallDir"
    } else {
        Write-Note "nothing installed at $InstallDir"
    }
    if (Remove-FromUserPath $InstallDir) {
        Write-Note "removed from your user PATH"
    }
    Write-Host ""
    Write-Host "Done. Open a new shell for the PATH change to take effect." -ForegroundColor Green
    return
}

# --- compiler detection ------------------------------------------------------
# Returns a hashtable describing how to build, or $null if we found nothing.

function Import-VcVarsEnv($batch) {
    # Run the batch file in cmd, dump the resulting environment, and copy it
    # into this process so cl.exe becomes callable.
    $output = cmd /c "call `"$batch`" x64 >nul 2>&1 && set"
    if ($LASTEXITCODE -ne 0) { return $false }
    foreach ($line in $output) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
    return $true
}

function Find-Compiler {
    foreach ($name in 'cl', 'g++', 'clang++') {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            return @{ Kind = $(if ($name -eq 'cl') { 'msvc' } else { 'gcc' }); Exe = $cmd.Source; Name = $name }
        }
    }

    # No compiler on PATH. Ask vswhere where Visual Studio lives, then pull in
    # its build environment.
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsRoot = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null
        if ($vsRoot) {
            foreach ($rel in 'VC\Auxiliary\Build\vcvarsall.bat', 'VC\Auxiliary\Build\vcvars64.bat') {
                $bat = Join-Path $vsRoot $rel
                if (Test-Path $bat) {
                    Write-Note "loading MSVC environment from $rel"
                    if (Import-VcVarsEnv $bat) {
                        $cl = Get-Command cl -ErrorAction SilentlyContinue
                        if ($cl) { return @{ Kind = 'msvc'; Exe = $cl.Source; Name = 'cl' } }
                    }
                }
            }
        }
    }

    return $null
}

# --- build -------------------------------------------------------------------

function Build-Exe($compiler, $destDir) {
    $src = Join-Path $root 'caffeinate.cpp'
    if (-not (Test-Path $src)) { throw "caffeinate.cpp not found next to install.ps1" }

    $exe = Join-Path $destDir 'caffeinate.exe'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "caffeinate-build-$PID"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    try {
        if ($compiler.Kind -eq 'msvc') {
            & $compiler.Exe /nologo /EHsc /O2 /W3 $src /Fe:$exe /Fo:"$tmp\" | Write-Note
        } else {
            & $compiler.Exe -O2 -Wall -o $exe $src | Write-Note
        }
        if ($LASTEXITCODE -ne 0) { throw "$($compiler.Name) exited with code $LASTEXITCODE" }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $exe)) { throw "build reported success but $exe is missing" }
    return $exe
}

function Install-Scripts($destDir) {
    foreach ($f in 'caffeinate.bat', 'caffeinate.ps1') {
        $srcFile = Join-Path $root $f
        if (-not (Test-Path $srcFile)) { throw "$f not found next to install.ps1" }
        Copy-Item $srcFile (Join-Path $destDir $f) -Force
    }
    # .BAT is in PATHEXT, so plain `caffeinate` resolves to caffeinate.bat.
    return (Join-Path $destDir 'caffeinate.bat')
}

# --- main --------------------------------------------------------------------

Write-Step "Installing caffeinate to $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

$mode = 'scripts'
$compiler = $null

if ($Scripts) {
    Write-Note "-Scripts given, skipping the build"
} else {
    Write-Step "Looking for a C++ compiler"
    $compiler = Find-Compiler
    if ($compiler) {
        Write-Note "using $($compiler.Name) ($($compiler.Exe))"
        $mode = 'exe'
    } else {
        Write-Warn "No C++ compiler found (looked for cl, g++, clang++, and Visual Studio)."
        Write-Warn "Falling back to the script version, which works just as well."
        Write-Note ""
        Write-Note "To build the native exe instead, install a compiler and re-run:"
        Write-Note "  winget install Microsoft.VisualStudio.2022.BuildTools"
        Write-Note "  (select the 'Desktop development with C++' workload)"
        Write-Note ""
    }
}

if ($mode -eq 'exe') {
    Write-Step "Building caffeinate.exe"
    $installed = Build-Exe $compiler $InstallDir
    # Stale scripts from a previous -Scripts install would shadow the exe,
    # because PATHEXT resolves .BAT ahead of .EXE.
    foreach ($f in 'caffeinate.bat', 'caffeinate.ps1') {
        $old = Join-Path $InstallDir $f
        if (Test-Path $old) {
            Remove-Item $old -Force
            Write-Note "removed stale $f from a previous script install"
        }
    }
} else {
    Write-Step "Installing the script version"
    $installed = Install-Scripts $InstallDir
}
Write-Note "installed $(Split-Path -Leaf $installed)"

Write-Step "Updating PATH"
$pathChanged = Add-ToUserPath $InstallDir

Write-Step "Verifying"
try {
    if ($mode -eq 'exe') {
        # -t 0 asserts the flags, waits zero seconds, and exits cleanly.
        & $installed -t 0 | Out-Null
    } else {
        # Don't go through the .bat here: its timeout/t call fails when stdin is
        # redirected. Driving the .ps1 directly exercises the part that actually
        # matters anyway, the Add-Type P/Invoke into SetThreadExecutionState.
        & powershell -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $InstallDir 'caffeinate.ps1') -Reset | Out-Null
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Note "caffeinate ran successfully"
    } else {
        Write-Warn "caffeinate exited with code $LASTEXITCODE"
    }
} catch {
    Write-Warn "could not run caffeinate: $_"
}

Write-Host ""
Write-Host "Installed to $InstallDir" -ForegroundColor Green
if ($pathChanged) {
    Write-Host "Open a new shell, then try:" -ForegroundColor Green
} else {
    Write-Host "Try:" -ForegroundColor Green
}
Write-Host "  caffeinate -d           # keep the display awake until Ctrl+C"
Write-Host "  caffeinate -t 3600      # stay awake for an hour"
Write-Host "  caffeinate -i my-build  # stay awake until my-build finishes"
Write-Host ""
Write-Host "Uninstall with: .\install.ps1 -Uninstall" -ForegroundColor DarkGray
