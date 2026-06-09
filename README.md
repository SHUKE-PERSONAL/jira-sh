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

# 4. Reload
source ~/.bashrc
```

## Usage

```bash
jr move PROJ-123 "In Review"
jr comment PROJ-123 "Deployed to staging"
jr help
```

## Requirements

- bash
- curl
- python3 (stdlib only)
