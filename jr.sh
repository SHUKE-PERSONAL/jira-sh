#!/usr/bin/env bash
# jr - Jira Cloud CLI
# Source this file in ~/.bashrc:  source /path/to/jr.sh

_jr_check_env() {
  local missing=()
  [[ -z "${JIRA_BASE:-}"  ]] && missing+=(JIRA_BASE)
  [[ -z "${JIRA_EMAIL:-}" ]] && missing+=(JIRA_EMAIL)
  [[ -z "${JIRA_TOKEN:-}" ]] && missing+=(JIRA_TOKEN)
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "jr: missing env vars: ${missing[*]}" >&2
    echo "    Set them in ~/.bashrc or source a .env file" >&2
    return 1
  fi
}

_jr_auth() {
  echo -n "$JIRA_EMAIL:$JIRA_TOKEN" | base64 | tr -d '\n'
}

_jr_api() {
  local method=$1 path=$2 data=${3:-}
  local url="$JIRA_BASE/rest/api/3$path"
  local auth
  auth=$(_jr_auth)
  local args=(-s -f -X "$method"
    -H "Authorization: Basic $auth"
    -H "Content-Type: application/json"
    -H "Accept: application/json")
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}" "$url"
}

_jr_json_comment_body() {
  python3 -c "
import json, sys
print(json.dumps({
  'body': {
    'type': 'doc', 'version': 1,
    'content': [{'type': 'paragraph', 'content': [{'type': 'text', 'text': sys.argv[1]}]}]
  }
}))" "$1"
}

_jr_transition_id() {
  local ticket=$1 status=$2
  local transitions
  transitions=$(_jr_api GET "/issue/$ticket/transitions") || return 1
  python3 -c "
import json, sys
data = json.loads(sys.argv[1])
target = sys.argv[2].lower()
for t in data.get('transitions', []):
    if t['name'].lower() == target:
        print(t['id']); sys.exit(0)
sys.exit(1)
" "$transitions" "$status"
}

_jr_transition_names() {
  local transitions=$1
  python3 -c "
import json, sys
for t in json.loads(sys.argv[1]).get('transitions', []):
    print(' ', t['name'])
" "$transitions"
}

jr_move() {
  [[ $# -lt 2 ]] && { echo "Usage: jr move <TICKET> <STATUS>" >&2; return 1; }
  local ticket=$1 status=$2
  local transitions tid

  transitions=$(_jr_api GET "/issue/$ticket/transitions") || return 1
  tid=$(python3 -c "
import json, sys
target = sys.argv[1].lower()
for t in json.loads(sys.argv[2]).get('transitions', []):
    if t['name'].lower() == target:
        print(t['id']); sys.exit(0)
sys.exit(1)
" "$status" "$transitions") || {
    echo "jr: no transition named '$status'. Available:" >&2
    _jr_transition_names "$transitions" >&2
    return 1
  }

  _jr_api POST "/issue/$ticket/transitions" "{\"transition\":{\"id\":\"$tid\"}}" > /dev/null
  echo "$ticket → $status"
}

jr_comment() {
  [[ $# -lt 2 ]] && { echo "Usage: jr comment <TICKET> <TEXT>" >&2; return 1; }
  local ticket=$1; shift
  local body
  body=$(_jr_json_comment_body "$*") || return 1
  _jr_api POST "/issue/$ticket/comment" "$body" > /dev/null
  echo "comment added to $ticket"
}

jr_help() {
  cat <<'EOF'
Usage: jr <command> [args]

Commands:
  move    <TICKET> <STATUS>   Transition a ticket to a new status
  comment <TICKET> <TEXT>     Add a comment to a ticket
  help                        Show this help

Required env vars:
  JIRA_BASE    https://yourcompany.atlassian.net
  JIRA_EMAIL   your@email.com
  JIRA_TOKEN   your-api-token
EOF
}

jr() {
  _jr_check_env || return 1
  local cmd=${1:-help}
  shift 2>/dev/null || true
  case "$cmd" in
    move)         jr_move    "$@" ;;
    comment)      jr_comment "$@" ;;
    help|--help|-h) jr_help  ;;
    *) echo "jr: unknown command '$cmd'" >&2; jr_help >&2; return 1 ;;
  esac
}
