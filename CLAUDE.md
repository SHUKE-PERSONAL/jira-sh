# jira-sh developer guide

`jr` is a **single bash file** (`./jr`) with Python embedded as `<<'PYEOF'` heredocs.
No build step, no dependencies beyond bash + curl + python3. The install script
just symlinks `~/bin/jr` → this file.

---

## File structure

```
jr          the whole program — bash frame + Python heredocs
jr.ps1      Windows-only PowerShell entry point; delegates to `jr` under bash
install.sh  ln -sf to ~/bin (jr, plus jr.ps1 on Windows)
README.md   user-facing docs
```

Everything lives in `jr`. When you add a command you edit one file — `jr.ps1`
never needs touching for a new command (see [The PowerShell
wrapper](#the-powershell-wrapper-jrps1)).

---

## Architecture: bash frame + Python drops

The outer shell handles:
- env checks (`_jr_check_env`)
- argument dispatch (`case "$cmd" in ... esac` at the bottom)
- interactive prompts (`read -r -p`)
- bash-level retry loops

Python is used for anything that needs JSON parsing or non-trivial string
manipulation. It runs inline (`python3 -c "..."`) or in `PYEOF` heredocs.
The heredocs are substantial (50–300 lines each); each one is self-contained
and communicates with the bash caller via stdout/exit code.

**Rule:** don't add Python imports outside of heredocs/`-c` blocks. Everything
in the bash frame must run with no Python state.

---

## Core helpers

### `_jr_api` vs `_jr_api_status`

| | `_jr_api` | `_jr_api_status` |
|---|---|---|
| curl flag | `-f` (fails on 4xx/5xx) | `-w '\n%{http_code}'` (never fails) |
| output | body only | body + `\n` + HTTP code on last line |
| split pattern | n/a | `code=${resp##*$'\n'}; body=${resp%$'\n'*}` |
| use for | read-only or fire-and-forget calls | calls where you need to branch on HTTP code |

Use `_jr_api_status` whenever the caller needs to inspect the response code
(transitions, comment writes, set-field). Use `_jr_api` for everything else.

### `_jr_do_transition` (lines ~105–168)

All status moves go through this function. It handles two special validators
that Jira enforces at transition time:

1. **Time Spent** — if the 4xx body contains `"time spent"` (case-insensitive),
   prompt for a duration, default `0m`, retry with `update.worklog`.

2. **CapEx** — if the 4xx body contains `"capex"`, read `[move.capex]` from
   `~/.jr.toml`, prompt `y/N`, retry with the value inside `fields` (not
   `update`). **Critical:** CapEx is a transition-screen field, not an edit
   field — it must go in the transition `fields` body, not in a separate
   `PATCH /issue/{ticket}`.

To add a new transition validator: follow the same pattern — detect the keyword
in the error body, prompt or resolve from config, retry the transition POST.

---

## Markdown → ADF converters

There are **four separate copies** of the Markdown→ADF inline converter:

| Location | Used by | Special behaviour |
|----------|---------|-------------------|
| `_jr_resolve_adf` PYEOF (~lines 538–734) | `cmd_resolve` | Runs mistune; demotes heading levels +2; strips Claude Code footer; wraps in full "Resolved" template with checklist |
| `cmd_create` PYEOF (`_blocks`/`_inline`/`md_to_adf_doc`) | `jr create` | Degrades to plain-text on missing mistune; no demoting |
| `cmd_edit` PYEOF (`_blocks`/`_inline`/`md_to_adf_doc`) | `jr edit` | Near-identical to `cmd_create` version |
| `_jr_md_to_adf_body` PYEOF (~lines 180–273) | `jr comment` | Same converter as create/edit; reads markdown from `$JR_MD` (stdin is the heredoc script); emits `{"body": <doc>}`; exits 3 on empty body |

**ADF constraint you must not break:** a text node cannot carry both `code` and
`strong`/`em` marks. Jira returns 400. The pattern in `_jr_resolve_adf` is an
`add_mark` function; in the other two it is an inline `for n in kids` loop.
Both must skip applying `strong`/`em` when the node already has `code`.

Example guard (in `add_mark`):
```python
if mark.get("type") in ("strong", "em") and \
   any(m.get("type") == "code" for m in n.get("marks", [])):
    continue
```

If you change the Markdown→ADF logic, apply it to all four copies. They are
not shared because each lives inside a different heredoc scope.

---

## Comment state classifiers

`jr resolve`, `jr approve`, and `jr merge` each poll for an auto-generated
workflow template comment, fill it, and are idempotent. The classifier
functions return a tagged string:

| Function | States returned | File lines |
|----------|----------------|-----------|
| `_jr_resolved_state` | `TEMPLATE:<id>` `TEMPLATE_RETRY:<id>` `FILLED:<id>` `NONE:` | ~559–580 |
| `_jr_approve_state` | `TEMPLATE:<id>` `FILLED:<id>` `OTHER:<id>` `NONE:` | ~1042–1062 |
| `_jr_merge_state` | `TEMPLATE:<id>` `FILLED:<id>` `OTHER:<id>` `NONE:` | ~737–780 |

All detect by looking for the `atlassian-flag_on` emoji in the serialized
comment body, then by checking for template-marker strings like `<summary>`,
`<details>`, `<component>`.

---

## `~/.jr.toml` config

The file is read in two places: inside PYEOF blocks (Python `tomllib`) and in
`_jr_do_transition` (Python `-c`). All reads have a graceful fallback when the
file is missing.

| Section | Read by | Keys |
|---------|---------|------|
| `[move.capex]` | `_jr_do_transition` | `field`, `yes_value` (def "Yes"), `no_value` (def "No") |
| `[create]` | `cmd_create` PYEOF | `project`, `issuetype`, `priority`, `story_points`, `assignee`, `labels` |
| `[create.team]` | `cmd_create` PYEOF | `field`, `id` |
| `[create.sprint]` | `cmd_create` PYEOF | `auto`, `board` |
| `[create.extra_fields]` | `cmd_create` PYEOF | arbitrary `customfield_XXXXX = {id="..."}`  or `{value="..."}` |

`cmd_edit` does **not** read `~/.jr.toml`; it takes everything from CLI flags.

---

## Adding a new command

1. Write `cmd_yourcommand()` anywhere before the dispatch block.
2. Add the dispatch line: `yourcommand) cmd_yourcommand "$@" ;;`
3. Add a one-line entry to `cmd_help`.
4. If it calls Jira and needs to inspect HTTP codes, use `_jr_api_status` and
   call `_jr_comment_write` (or inline the same code/status split pattern).

For Python-heavy commands (JSON construction, ADF), use a `<<'PYEOF'` heredoc.
Pass data in via env vars (`FOO="$bar" python3 <<'PYEOF'`) or positional args
(`python3 -c "..." "$arg1"`). Use exit codes and stdout only; don't rely on
bash variables set inside the heredoc.

---

## Adding a new `~/.jr.toml` section

1. Parse it in Python with the same `tomllib`/`tomli` fallback pattern already
   in the file.
2. Document it in `cmd_help`'s "Optional ~/.jr.toml sections" block.
3. Update `README.md`.
4. Consider whether the setup-prompt template (inside the `cmd_create` PYEOF
   around the "jr: ~/.jr.toml not found" message) should mention it.

---

## Known constraints and past bugs

- **CapEx is transition-screen only.** `set-field` uses `PATCH /issue/{ticket}`
  (edit endpoint), which rejects transition-screen fields with 400. `jr move`
  injects them via the transition `fields` body instead.

- **Four ADF converters, not one.** They diverged intentionally (different
  template shapes), but the `code`+`strong`/`em` guard must be kept in sync
  across all four. Commit `bb0c23c` fixed it in `cmd_create`; `cccf7c7` fixed
  it in `_jr_resolve_adf`. `_jr_md_to_adf_body` (`jr comment`) carries the same
  guard.

- **`jr comment` markdown body comes from `$JR_MD`, not stdin.** A
  `python3 <<'PYEOF'` heredoc already consumes the process's stdin as the script
  source, so `sys.stdin.read()` inside it returns empty. `_jr_md_to_adf_body`
  reads the markdown from the `JR_MD` env var instead (`cmd_comment` sets it);
  the create/edit converters use the same env-var pattern.

- **`_jr_api_status` body/code split is newline-sensitive.** The separator is a
  literal `$'\n'` (ANSI-C quoting). The curl `-w '\n%{http_code}'` appends a
  real newline before the status code. If you add a second `-w` flag, the split
  breaks.

- **Windows console encoding.** `jr comments` renders emoji from Jira ADF.
  On Windows with a non-UTF-8 console (cp1252), Python's stdout raises
  `UnicodeEncodeError` on emoji. This is a display-only issue; the API calls
  are unaffected. The fix is `PYTHONUTF8=1` or piping through a UTF-8 terminal.
  `jr.ps1` covers the PowerShell entry point with both halves of that fix:
  `PYTHONUTF8=1` for the bash it spawns (no crash) plus a UTF-8
  `[Console]::OutputEncoding` (no mojibake). `PYTHONUTF8` alone only removes the
  exception — the text still lands garbled.

- **`jr resolve` requires `gh` and `mistune`.** Both are checked early and fail
  clearly. Other commands have no extra dependencies.

- **Transition to In Progress auto-assigns.** If the ticket is unassigned,
  `cmd_move` assigns it to the caller. If it's assigned to someone else, it
  refuses. This is intentional — don't remove it.

---

## The PowerShell wrapper (`jr.ps1`)

Windows-only entry point, installed by `install.sh` beside `~/bin/jr` (the
`MINGW*|MSYS*|CYGWIN*` arm of the `uname -s` case). PowerShell resolves a bare
`jr` on PATH to `jr.ps1` ahead of the extensionless `jr`, and the wrapper finds
the bash script as its own sibling (`$PSScriptRoot\jr`, following the symlink).

**It delegates and nothing else.** No CLI logic belongs there — a new command or
flag needs no change to `jr.ps1`. What it does own is a set of PowerShell- and
Windows-specific hazards, every one of them load-bearing:

- **Args travel as env vars** (`<tag>_ARGC`, `<tag>_ARG<n>`), not on the bash
  command line. Windows PowerShell 5.1 drops embedded double quotes when it
  builds a native command line, which corrupts values like
  `-F customfield_12533='{"id":"16498"}'`. For the same reason the one `-c`
  payload PowerShell does pass contains no double quotes of its own; the bash
  that needs them travels in `<tag>_BOOT` and is `eval`'d there.
  - `<tag>` is a per-invocation GUID. Two `jr` calls in one PowerShell process
    (`ForEach-Object -Parallel`, `Start-ThreadJob`) share one environment block,
    and fixed names let them read each other's arguments — which for `jr move` /
    `jr assign` means silently acting on the wrong ticket.
  - The `-c` payload **refuses to run when that env is missing** (exit 126). A
    bash that drops the Windows environment would otherwise `eval` an empty
    string and exit 0 with no output — a silent no-op that reads as success.
  - Args are capped at 32000 chars with a `--body-file` hint. Beyond ~32767 a
    Windows env var can't hold the value: 5.1 throws a .NET exception that takes
    the *caller's* script down, 7 gets as far as bash saying `Argument list too
    long`.
- **bash.exe discovery is fussy for good reasons.** `C:\Windows\System32\bash.exe`
  *and* `%LOCALAPPDATA%\Microsoft\WindowsApps\bash.exe` are both WSL launchers,
  and on a clean Windows PATH they shadow Git's bash. WSL's Linux bash can't open
  a script at a Windows path and doesn't inherit the environment, so both are
  filtered out. Then:
  - `git.exe` is often a **shim** (scoop, chocolatey), so its own directory says
    nothing about where bash lives — `git --exec-path` is the fallback that
    answers from the real install.
  - A candidate at `<root>\usr\bin\bash.exe` is remapped to `<root>\bin\bash.exe`
    when that exists. The `bin` one is the launcher that sets up the msys
    environment; `usr\bin\bash.exe` started from Windows inherits only the
    Windows PATH, where `curl` is System32's and **`bash` itself is WSL**.
  - The boot script `exec`s the selected bash **by path** (`<tag>_BASH`). A bare
    `exec bash` re-resolves through PATH and lands on WSL, which then reports
    `No such file or directory` for the Windows-path script.
- **Stdin is forwarded only under `$MyInvocation.ExpectingInput`.** A `.ps1` gets
  pipeline input itself and must hand it on, but an unconditional `$input |`
  closes the child's stdin — which EOFs the interactive CapEx / Time Spent
  prompts in `_jr_do_transition`.
- **`$ErrorActionPreference = 'Continue'` around the native call.** On 5.1 a
  child's stderr becomes an error record when the caller redirects it
  (`jr view X 2>&1`); under `Stop` that aborts the wrapper before it can hand
  back jr's exit code.
- **Both encodings are set.** `$OutputEncoding` (script-scoped) covers what
  PowerShell writes to the child's stdin — 5.1 defaults it to ASCII and would
  mangle non-ASCII piped into `jr comment`. `[Console]::OutputEncoding` covers
  the other direction: PowerShell decodes the child's stdout with it, so on a
  legacy console codepage (cp437, cp1252) jr's UTF-8 — em dashes, ADF emoji —
  arrives as mojibake. That one is process-global, hence saved and restored.

Two PowerShell behaviours the wrapper **cannot** paper over, both inherent to
being a `.ps1` rather than an `.exe`:

- On 5.1 a redirected stderr surfaces as a PowerShell error record decorated
  with the wrapper's own source line. The exit code is still correct.
- If the caller stops the pipeline early (`jr ls | Select-Object -First 3`), the
  script is torn down before its `exit` runs, so `$LASTEXITCODE` is left unset or
  `-1` on a *successful* call. Any `.ps1` behaves this way; there is no code path
  after a pipeline stop.

Verify wrapper changes on **both** `powershell.exe` (5.1) and `pwsh` (7+) —
their native-argument, stderr and encoding semantics differ, and 5.1 is the
strict one.

---

## Testing

There is no test suite. Test manually against a real Jira ticket:

```bash
jr transitions MT-XXXXX          # verify a ticket is reachable
jr view MT-XXXXX                  # smoke test API auth
bash jr set-field MT-XXXXX CapEx --list-options   # verify editmeta endpoint
```

For `jr.ps1`, install into a sandboxed `HOME` so the real `~/bin/jr` symlink is
left alone, and drive it from both PowerShell hosts:

```bash
HOME=/c/tmp/jrinst bash install.sh          # run twice: must be idempotent
powershell.exe -NoProfile -ExecutionPolicy Bypass -File suite.ps1  # 5.1
pwsh -NoProfile -File suite.ps1                                    # 7+
```

**The test script must pin PATH to the registry value**, or the test lies. A
PowerShell launched from Git Bash inherits Git's `mingw64`/`usr\bin` on PATH and
finds a working bash by accident; a Copilot or VS Code terminal does not, and
that is the environment where WSL's bash wins. Start `suite.ps1` with:

```powershell
$env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User') + ';C:\tmp\jrinst\bin'
```

Worth covering: a `-F` JSON arg, an empty arg, a multi-line arg, piped stdin,
success/failure exit codes, and non-ASCII output bytes.

For ADF changes, `jr create --dry-run` prints the payload JSON without
creating a ticket; `jr resolve` against a ticket already in Review will
re-fill the template and fail visibly if the ADF is bad.
