# jira-sh developer guide

`jr` is a **single bash file** (`./jr`) with Python embedded as `<<'PYEOF'` heredocs.
No build step, no dependencies beyond bash + curl + python3. The install script
just symlinks `~/bin/jr` → this file.

---

## File structure

```
jr          the whole program — bash frame + Python heredocs
install.sh  ln -sf to ~/bin/jr
README.md   user-facing docs
```

Everything lives in `jr`. When you add a command you edit one file.

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
| `_jr_resolve_adf` PYEOF (~lines 380–510) | `cmd_resolve` | Runs mistune; demotes heading levels +2; strips Claude Code footer; wraps in full "Resolved" template with checklist |
| `cmd_create` PYEOF (~lines 1504–1778) | `jr create` | Degrades to plain-text on missing mistune; no demoting |
| `cmd_edit` PYEOF (~lines 1817–1982) | `jr edit` | Near-identical to `cmd_create` version |
| `cmd_reply` PYEOF | `jr reply` | Copy of `cmd_edit`'s converter; prepends a blockquote "↳ In reply to <link>" reference to the parent comment, then posts the rendered body as a new comment |

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

If you change the Markdown→ADF logic, apply it to all three copies. They are
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
  it in `_jr_resolve_adf`. `cmd_reply`'s converter is a copy of `cmd_edit`'s.

- **`_jr_api_status` body/code split is newline-sensitive.** The separator is a
  literal `$'\n'` (ANSI-C quoting). The curl `-w '\n%{http_code}'` appends a
  real newline before the status code. If you add a second `-w` flag, the split
  breaks.

- **Windows console encoding.** `jr comments` renders emoji from Jira ADF.
  On Windows with a non-UTF-8 console (cp1252), Python's stdout raises
  `UnicodeEncodeError` on emoji. This is a display-only issue; the API calls
  are unaffected. The fix is `PYTHONUTF8=1` or piping through a UTF-8 terminal.

- **`jr resolve` requires `gh` and `mistune`.** Both are checked early and fail
  clearly. Other commands have no extra dependencies.

- **Transition to In Progress auto-assigns.** If the ticket is unassigned,
  `cmd_move` assigns it to the caller. If it's assigned to someone else, it
  refuses. This is intentional — don't remove it.

---

## Testing

There is no test suite. Test manually against a real Jira ticket:

```bash
jr transitions MT-XXXXX          # verify a ticket is reachable
jr view MT-XXXXX                  # smoke test API auth
bash jr set-field MT-XXXXX CapEx --list-options   # verify editmeta endpoint
```

For ADF changes, `jr create --dry-run` prints the payload JSON without
creating a ticket; `jr resolve` against a ticket already in Review will
re-fill the template and fail visibly if the ADF is bad.
