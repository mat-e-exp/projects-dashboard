# Projects Dashboard

Bash script that generates an interactive HTML dashboard for tracking coding projects in a workspace directory.

## Project Structure

```
projects-dashboard/
├── projects-dashboard.sh    # Main script (all-in-one)
├── proj-dash-ss.png         # Screenshot for README
├── README.md                # User documentation
└── CLAUDE.md                # Developer documentation
```

## Key Files & Locations

| File | Purpose |
|------|---------|
| `projects-dashboard.sh` | Main script - scanning, detection, HTML generation |
| `/tmp/projects-dashboard.html` | Generated dashboard output |
| `~/.config/projects-dashboard/config.json` | Global config (workspace path, script location) |
| `~/.claude/hooks/project-dashboard.sh` | Claude Code session hook |
| `<workspace>/.projects-config.json` | Per-workspace project metadata |

## Dependencies

- **bash 4.0+** - Uses associative arrays
- **jq** - JSON parsing (required)
- **git** - Optional, for repository features

## Script Architecture

### Entry Points
- `main()` - CLI argument parsing
- `run_dashboard()` - Core dashboard generation
- `do_install()` / `do_uninstall()` - Hook management

### Key Functions
| Function | Purpose |
|----------|---------|
| `detect_type()` | Auto-detect tech stack from files (read-only display) |
| `detect_description()` | Auto-fill description from package.json or README.md |
| `days_since_commit()` | Git activity tracking |
| `days_since_modified()` | File modification tracking |
| `uncommitted_count()` | Git status check |
| `remote_status()` | Git remote sync status |
| `output_section()` | Generate HTML table for category |

### Project Categories
User-selectable project purpose (stored in config):
```bash
PROJECT_CATEGORIES="infra|products|fun|personal|skunkworks|other"
```

### Tech Stack Detection
Auto-detected from files (read-only, not editable):
- Next.js, Vite, React, Vue, Node.js
- Python, Rust, Go, Ruby, Java
- Shell, Documentation, Other

### Description Auto-fill
Attempts to populate description from (in order):
1. `package.json` → `description` field
2. `pyproject.toml` → `description` field
3. `README.md` → first non-heading, non-empty line

### Activity Thresholds
```bash
ACTIVE_DAYS=7      # 0-7 days
RECENT_DAYS=30     # 8-30 days
IDLE_DAYS=90       # 31-90 days
# >90 = Dormant
```

### Excluded Folders
```bash
SKIP_FOLDERS="node_modules|.git|.venv|venv|__pycache__|.cache|dist|build|.next|.nuxt|target|vendor"
```

## HTML Output

The script generates a self-contained HTML file with:
- Embedded CSS (dark theme)
- Embedded JavaScript for interactivity
- Embedded project data as JSON
- No external dependencies

### Dashboard Columns
| Column | Source | Editable |
|--------|--------|----------|
| Project | Directory name | No |
| Tech Stack | Auto-detected | No |
| Category | User-selected | Yes (dropdown) |
| Description | Auto-filled or user | Yes (input) |
| Last Activity | Git/file mtime | No |
| Status | Git status | No |
| Remote | Git remote | No |
| Visibility | GitHub API (public/private) | No |
| Files | File count | No |

## Config JSON Format

```json
{
  "project-name": {
    "category": "products",
    "description": "Project description"
  }
}
```

## Platform Detection

```bash
# macOS: stat -f %m, pbcopy/pbpaste, open
# Linux: stat -c %Y, xclip, xdg-open
```

## Development Notes

- Script uses `set -e` - fails on first error
- All paths resolved to absolute
- File scanning limited to 100 files per project (performance)
- HTML uses heredocs for multi-line generation
- JavaScript uses template literals (ES6)

## Testing

```bash
# Run for current directory
./projects-dashboard.sh .

# Run for specific workspace
./projects-dashboard.sh ~/projects

# Test hook installation
./projects-dashboard.sh --install ~/projects
cat ~/.claude/hooks/project-dashboard.sh
./projects-dashboard.sh --uninstall
```
