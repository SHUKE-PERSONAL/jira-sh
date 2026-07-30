# jr.ps1 - PowerShell entry point for the bash `jr` CLI.
#
# All CLI logic stays in the bash `jr` script. This wrapper only locates
# bash.exe and the real `jr`, then forwards arguments, stdin, stdout and the
# exit code. PowerShell resolves a bare `jr` on PATH to this file (a .ps1 wins
# over the extensionless `jr` sitting next to it), so `jr view PROJ-123` works
# from a PowerShell prompt.
#
# The JIRA_* env vars must be set at the Windows *user* level - a
# non-interactive bash does not read ~/.bashrc, so vars exported there never
# reach the subprocess this wrapper spawns. See README "Setup".

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 defaults $OutputEncoding to ASCII, which mangles
# non-ASCII text piped into `jr comment`. This assignment is script-scoped, so
# it shadows the caller's value without changing their session.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Write-JrError([string]$msg) { [Console]::Error.WriteLine("jr: $msg") }

# --- locate bash.exe -------------------------------------------------------
# Git for Windows first: `where.exe bash` can hit C:\Windows\System32\bash.exe,
# the WSL launcher, whose Linux bash cannot run a script at a Windows path.
$candidates = @()

$git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($git) {
    # <install>\cmd\git.exe or <install>\bin\git.exe -> <install>\bin\bash.exe
    $candidates += (Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin\bash.exe')
}
foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
    if ($root) { $candidates += (Join-Path $root 'Git\bin\bash.exe') }
}
$candidates += @(
    Get-Command bash.exe -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notmatch '\\Windows\\(System32|SysWOW64|Sysnative)\\' } |
        ForEach-Object { $_.Source }
)

$bash = $candidates |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
    Select-Object -First 1

if (-not $bash) {
    Write-JrError 'cannot find bash.exe. Install Git for Windows (https://git-scm.com/download/win).'
    exit 127
}

# --- locate the bash jr script --------------------------------------------
$jr = Join-Path $PSScriptRoot 'jr'
if (-not (Test-Path -LiteralPath $jr -PathType Leaf)) {
    Write-JrError "the bash script 'jr' is not next to this wrapper (expected $jr). Re-run install.sh."
    exit 127
}

# Follow a link so bash gets the real file (install.sh may symlink or copy).
$item = Get-Item -LiteralPath $jr -Force
$target = if ($item.PSObject.Properties['LinkTarget']) { $item.LinkTarget } else { $item.Target | Select-Object -First 1 }
if ($target) {
    if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path -LiteralPath $jr -Parent) $target
    }
    if (Test-Path -LiteralPath $target -PathType Leaf) { $jr = $target }
}

# --- forward args + stdin, then propagate the exit code -------------------
# Arguments travel as environment variables, not on the bash command line:
# Windows PowerShell 5.1 drops embedded double quotes when it builds a native
# command line, which corrupts values like -F customfield_12533='{"id":"16498"}'.
# An env var reaches the child byte-exact, so every argument survives verbatim.
# For the same reason the -c payload below contains no double quotes of its own;
# the bash that does need them is passed in JR_PS_BOOT and eval'd there.
$boot = 'argv=(); i=0; while [ $i -lt $JR_PS_ARGC ]; do v="JR_PS_ARG$i"; argv+=("${!v}"); i=$((i+1)); done; exec bash "$JR_PS_SCRIPT" "${argv[@]}"'

$owned = @('JR_PS_SCRIPT', 'JR_PS_ARGC', 'JR_PS_BOOT')
$saved = @{}
foreach ($n in @('PYTHONUTF8')) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }

$code = 127   # stands if bash never got off the ground

try {
    [Environment]::SetEnvironmentVariable('JR_PS_SCRIPT', ($jr -replace '\\', '/'))
    [Environment]::SetEnvironmentVariable('JR_PS_ARGC', [string]$args.Count)
    [Environment]::SetEnvironmentVariable('JR_PS_BOOT', $boot)
    for ($i = 0; $i -lt $args.Count; $i++) {
        $name = "JR_PS_ARG$i"
        $owned += $name
        [Environment]::SetEnvironmentVariable($name, [string]$args[$i])
    }
    # Jira ADF carries emoji; without UTF-8 mode python3 raises
    # UnicodeEncodeError writing them to a legacy-codepage console.
    [Environment]::SetEnvironmentVariable('PYTHONUTF8', '1')

    # Windows PowerShell 5.1 turns a native command's stderr into an error
    # record whenever the caller redirects it (`jr view X 2>&1`); under 'Stop'
    # that aborts this wrapper before it can hand back jr's exit code.
    $ErrorActionPreference = 'Continue'

    if ($MyInvocation.ExpectingInput) {
        # Pipeline input reaches this script, not the child - hand it over
        # explicitly. Only when there is input: an unconditional `$input |`
        # closes stdin at once, which would EOF jr's interactive prompts
        # (CapEx, Time Spent).
        $input | & $bash --noprofile --norc -c 'set -f; eval $JR_PS_BOOT'
    } else {
        & $bash --noprofile --norc -c 'set -f; eval $JR_PS_BOOT'
    }
    if ($null -ne $LASTEXITCODE) { $code = $LASTEXITCODE }
}
finally {
    # A .ps1 runs in the caller's session - don't leak these into it.
    foreach ($n in $owned) { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue }
    foreach ($n in $saved.Keys) {
        if ($null -eq $saved[$n]) { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    }
}

exit $code
