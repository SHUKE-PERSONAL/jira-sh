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
# It has to be a Git for Windows bash. Two traps shape this search:
#   * C:\Windows\System32\bash.exe AND %LOCALAPPDATA%\Microsoft\WindowsApps\
#     bash.exe are both WSL launchers, and WSL commonly shadows Git's bash on a
#     clean PATH. Its Linux bash cannot open a script at a Windows path and does
#     not inherit the Windows environment, so picking it breaks everything.
#   * git.exe is frequently a shim (scoop, chocolatey), so its own directory
#     says nothing about where bash lives - hence the `git --exec-path` probe,
#     which answers from the real install whatever the shim layout.
function Test-JrExe([string]$p) { return ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) }

# Git's bin\bash.exe is the launcher that sets up the msys environment - PATH to
# /usr/bin and /mingw64/bin, so jr finds curl, tr, grep, git. The same bash at
# usr\bin\bash.exe started straight from Windows gets none of that: it inherits
# only the Windows PATH, where `bash` itself resolves to WSL. Prefer the launcher.
function Get-JrBashLauncher([string]$p) {
    if ($p -match '(?i)^(.*)\\usr\\bin\\bash\.exe$') {
        $alt = Join-Path $Matches[1] 'bin\bash.exe'
        if (Test-JrExe $alt) { return $alt }
    }
    return $p
}

$candidates = @()
foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
    if ($root) { $candidates += (Join-Path $root 'Git\bin\bash.exe') }
}
$git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($git) {
    # <install>\cmd\git.exe or <install>\bin\git.exe -> <install>\bin\bash.exe
    $candidates += (Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin\bash.exe')
}
$candidates += @(
    Get-Command bash.exe -CommandType Application -All -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Source } |
        Where-Object { $_ -notmatch '\\Windows\\(System32|SysWOW64|Sysnative)\\' -and
                       $_ -notmatch '\\Microsoft\\WindowsApps\\' }
)

$bash = $candidates | Where-Object { Test-JrExe $_ } | Select-Object -First 1

if (-not $bash -and $git) {
    # <root>\mingw64\libexec\git-core -> <root>\{bin,usr\bin}\bash.exe
    try { $execPath = @(& $git.Source --exec-path 2>$null)[0] } catch { $execPath = $null }
    if ($execPath) {
        $root = Split-Path (Split-Path (Split-Path ($execPath -replace '/', '\') -Parent) -Parent) -Parent
        $bash = @("$root\bin\bash.exe", "$root\usr\bin\bash.exe") |
            Where-Object { Test-JrExe $_ } | Select-Object -First 1
    }
}

if (-not $bash) {
    Write-JrError 'cannot find a Git for Windows bash.exe (WSL bash will not do). Install Git for Windows: https://git-scm.com/download/win'
    exit 127
}
$bash = Get-JrBashLauncher $bash

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
# the bash that does need them travels in <tag>_BOOT and is eval'd there.
#
# The names carry a per-invocation tag: two jr calls in one PowerShell process
# (ForEach-Object -Parallel, ThreadJob) share one environment block, and a fixed
# name would let them read each other's arguments - silently operating on the
# wrong ticket.
#
# jr runs under the bash we picked, named explicitly: a bare `exec bash` would
# resolve through PATH, and on a clean Windows PATH that is WSL's bash.
$tag = 'JR' + [guid]::NewGuid().ToString('N')
$boot = 'argv=(); i=0; while [ $i -lt $%NS%_ARGC ]; do v=%NS%_ARG$i; argv+=("${!v}"); i=$((i+1)); done; exec "$%NS%_BASH" "$%NS%_SCRIPT" "${argv[@]}"'
$boot = $boot.Replace('%NS%', $tag)

# Fixed payload, quote-free. It refuses to run when the handover env is missing,
# which is what a WSL bash looks like from here: WSL drops the Windows
# environment, and an unguarded `eval` of nothing would exit 0 with no output -
# a silent no-op that reads like success to a caller.
$payload = 'set -f; b=${1}_BOOT; v=${!b}; if [ x${v:+1} = x ]; then echo jr: this bash did not inherit the wrapper environment, probably WSL bash. Install Git for Windows. >&2; exit 126; fi; eval $v'

$owned = @("${tag}_SCRIPT", "${tag}_ARGC", "${tag}_BOOT", "${tag}_BASH")
$saved = @{}
foreach ($n in @('PYTHONUTF8')) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
$savedConsoleOut = [Console]::OutputEncoding

$code = 127   # stands if bash never got off the ground

try {
    [Environment]::SetEnvironmentVariable("${tag}_SCRIPT", ($jr -replace '\\', '/'))
    [Environment]::SetEnvironmentVariable("${tag}_BASH", ($bash -replace '\\', '/'))
    [Environment]::SetEnvironmentVariable("${tag}_ARGC", [string]$args.Count)
    [Environment]::SetEnvironmentVariable("${tag}_BOOT", $boot)
    for ($i = 0; $i -lt $args.Count; $i++) {
        $name = "${tag}_ARG$i"
        $owned += $name
        # PowerShell parses an unquoted a,b into an array before this script sees
        # it; a native exe would have received the literal a,b. Rejoin so
        # -F customfield_X=a,b reaches jr the way it was typed. ([string] on an
        # array would join with spaces instead.)
        $value = if ($args[$i] -is [array]) { ($args[$i] | ForEach-Object { [string]$_ }) -join ',' }
                 else { [string]$args[$i] }
        # A Windows environment variable tops out at 32767 chars, and the process
        # environment as a whole is capped too. Checked here so both hosts give
        # the same actionable error: 5.1 would throw a raw .NET exception (which
        # takes the caller's script down with it) and 7 would get as far as bash
        # answering `Argument list too long`.
        if ($value.Length -gt 32000) {
            Write-JrError "argument $($i + 1) is too long ($($value.Length) chars) to pass through the Windows environment. Use --body-file for a large body."
            exit 1
        }
        [Environment]::SetEnvironmentVariable($name, $value)
    }
    # Jira ADF carries emoji; without UTF-8 mode python3 raises
    # UnicodeEncodeError writing them to a legacy-codepage console.
    [Environment]::SetEnvironmentVariable('PYTHONUTF8', '1')

    # PowerShell decodes the child's stdout with [Console]::OutputEncoding; on a
    # legacy codepage (cp437, cp1252) jr's UTF-8 output - em dashes, emoji from
    # ADF - arrives as mojibake. This one is process-global, hence the restore.
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

    # Windows PowerShell 5.1 turns a native command's stderr into an error
    # record whenever the caller redirects it (`jr view X 2>&1`); under 'Stop'
    # that aborts this wrapper before it can hand back jr's exit code.
    $ErrorActionPreference = 'Continue'

    if ($MyInvocation.ExpectingInput) {
        # Pipeline input reaches this script, not the child - hand it over
        # explicitly. Only when there is input: an unconditional `$input |`
        # closes stdin at once, which would EOF jr's interactive prompts
        # (CapEx, Time Spent).
        $input | & $bash --noprofile --norc -c $payload 'jr.ps1' $tag
    } else {
        & $bash --noprofile --norc -c $payload 'jr.ps1' $tag
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
    try { [Console]::OutputEncoding = $savedConsoleOut } catch { }
}

exit $code
