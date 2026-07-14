# jira-sh

A minimal bash CLI for Jira Cloud. One command: `jr`.

## Setup

```bash
# 1. Clone
git clone https://github.com/shukebeta/jira-sh ~/Projects/jira-sh

# 2. Install (adds source line to ~/.bashrc)
bash ~/Projects/jira-sh/install.sh

# 3. Set env vars in ~/.bashrc
export JIRA_BASE=https://yourcompany.atlassian.net
export JIRA_EMAIL=your@email.com
export JIRA_TOKEN=your-api-token
# Optional: pipe-separated project keys for resolving bare ticket numbers (default: MT|DOS)
export JIRA_PROJECT_PREFIXES="MT|DOS"

# 4. Reload
source ~/.bashrc
```

## Usage

```bash
jr move PROJ-123 "In Review"
jr comment PROJ-123 "Deployed to staging"
jr view PROJ-123
jr help
```

A bare `.`, `@`, or an omitted `TICKET` derives the ticket from the current
branch name (e.g. on `feature/mt-63504` you can just run `jr view`). A bare
number (`jr view 63504`) is resolved against `JIRA_PROJECT_PREFIXES`.

## Commands

| Command | What it does |
| --- | --- |
| `start [TICKET]` | Start work: reach In Progress in one hop, or via Ready when Jira blocks the direct jump. Claims the ticket; handles the CapEx gate. |
| `move <TICKET> <STATUS>` | Transition a ticket (moving to In Progress claims it for you; errors if owned by someone else). |
| `comment <TICKET> <TEXT>` | Add a comment. |
| `view [TICKET]` | Show a ticket's fields and full rendered description. |
| `resolve [--force] [TICKET]` | Move to review, then fill the review template comment from the current branch's PR. |
| `approve [--force] [--no-sql] [--no-jenkins] [TICKET]` | Finish review, then fill the Code Review Checklist (see below). |
| `merge [--force] [TICKET]` | Merge the approved PR, move Merge → Test in Main, then fill the Merge Results template. |
| `create --title "..." [...]` | Create a ticket from `~/.jr.toml` defaults, with per-invocation overrides (see [Creating tickets](#creating-tickets)). |
| `edit [TICKET] [--title ...] [--body ...]` | Update the title and/or body of a ticket you reported (`--force` edits any ticket). |
| `set-field <TICKET> <FIELD> <VALUE\|--list-options>` | Set a custom field via the Edit screen; `--list-options` lists a select field's allowed values. |
| `transitions <TICKET>` | List available transitions. |
| `assign [TICKET] [NAME]` | Assign to a user (fuzzy name/email match); NAME omitted = assign to yourself; TICKET omitted = current branch. |
| `assign -u\|--unassign [TICKET]` | Clear the assignee. |
| `users <TICKET> [query]` | List assignable users. |

## Review workflow

The three workflow commands fill the Jira templates the team's automation posts
on each transition, so you don't hand-edit ADF tables:

```
jr resolve   → Review            (fill the Resolved comment from the PR)
jr approve   → Test in Branch    (fill the Code Review Checklist)
jr merge     → Test in Main      (fill the Merge Results table)
```

Each is idempotent: if the ticket is already in the target status the move is
skipped and the comment is still filled. A checklist already authored by someone
else is left untouched; an already-filled comment is not overwritten unless you
pass `--force`.

### `jr resolve`

Moves a ticket → Review, then fills the auto-generated **Resolved** comment from
the current branch's PR: a short bulleted change summary, the PR link, and the
team's review **Checklist**. The first checklist item — *DDT script run using
DFXDDT & in correct folder* — is answered **Yes** automatically when the PR adds
a new file under `DFXSQL/DDT/UpdateScripts/`; otherwise it's left open.

### `jr approve`

Moves Review → Test in Branch, then fills the auto-generated **Code Review
Checklist** comment: ticks the **Done** column, keeps the first three rows plus
the last, blanks **Comments**, and reduces the **Action** line to *Ready for
test*. Not every ticket touches SQL and not every project runs Jenkins, so those
rows can be dropped:

```bash
jr approve              # keep both rows (default)
jr approve --no-sql     # drop the SQL Standards row
jr approve --no-jenkins # drop the Jenkins pipelines row
jr approve -sj          # short forms bundle: -s (no-sql) -j (no-jenkins) -f (force)
jr approve -sjf MT-63504 # skip both rows and overwrite a filled checklist
```

## Creating tickets

`jr create` builds the payload from `~/.jr.toml` (`[create]`, `[create.team]`,
`[create.sprint]`, `[create.extra_fields]`) and lets any invocation override
those defaults:

```bash
jr create --title "Fix widget" --type Bug \
  -F customfield_12533='{"id":"16498"}' \   # Bug Severity QA (raw JSON)
  --component DFX --sprint active
jr create --title "..." --dry-run           # print the JSON payload, create nothing
```

Override flags (all optional; defaults come from config):

| Flag | Effect |
| --- | --- |
| `-F, --field customfield_X=<value\|json>` | Set any field (repeatable). `{…}`/`[…]` → raw JSON, a bare number → number, anything else → `{"value": …}`. Same value semantics as `set-field`. |
| `--component <name\|id>` | Add a component (repeatable); numeric → `{"id":…}`, else `{"name":…}`. |
| `--team <name\|id>` | Override the `[create.team]` default; numeric → `{"id":…}`, else `{"value":…}`. |
| `--sprint <id\|active\|none>` | Target a specific sprint id, force the board's active sprint, or attach none. (`--no-sprint` is the same as `none`.) |
| `--priority`, `--points`, `--type`, `--epic` | Override the matching `[create]` default. |

**Per-issue-type profiles** let a type declare its own defaults and required
fields so `--type Bug` picks the right values without any flags:

```toml
[create.type.Bug]
priority     = "High"
extra_fields = { customfield_12533 = { id = "16499" } }  # Bug Severity QA default
```

The `[create.type.<Type>]` key must match the issue-type name. Its `extra_fields`
merge over the global `[create.extra_fields]`; its scalar keys (`priority`,
`story_points`, `epic`, `labels`) override the corresponding `[create]` value.

**Precedence** (highest wins):

```
CLI flag  >  [create.type.<Type>]  >  [create.extra_fields] / [create]
```

## Transition validators

Some workflow transitions enforce required fields. `jr move` handles two
automatically:

**Time Spent** — if Jira rejects the transition with a "time spent" error, jr
prompts for a duration (e.g. `30m`, `1h`). Press Enter to submit `0m`.

**CapEx** — if Jira rejects a transition (commonly `→ Ready`) because a CapEx
field is missing, jr prompts `CapEx? [y/N]` and patches the field before
retrying. Requires `[move.capex]` in `~/.jr.toml`:

```toml
[move.capex]
field     = "customfield_XXXXX"   # Jira custom field ID for CapEx
yes_value = "Yes"                 # option label when CapEx (default: Yes)
no_value  = "No"                  # option label when not CapEx (default: No)
```

## Requirements

- bash
- curl
- python3

Core commands (`move`, `comment`, `view`, `approve`, `transitions`, `assign`,
`users`) use the Python standard library only.

The `jr resolve` and `jr merge` commands additionally need:

- [`gh`](https://cli.github.com/) — the GitHub CLI, authenticated for the repo's
  owner. If you use a multi-account `gh` wrapper that routes by repo owner, make
  sure the right account is selected (e.g. `GH_PROFILE=work`), or `gh pr view`
  will 404 on private org repos.

The `jr resolve` command also needs:

- [`mistune`](https://pypi.org/project/mistune/) — renders the PR description
  (Markdown) into Jira's ADF format. Install with `pip install mistune`. If it's
  missing, `jr resolve` exits with a hint rather than posting raw Markdown.
