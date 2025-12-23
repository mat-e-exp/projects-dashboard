#!/bin/bash

# Projects Dashboard
# A dynamic way to track your coding projects
# Works with git repos and regular folders
# Supports JSON config for user overrides
#
# Usage:
#   ./projects-dashboard.sh [workspace]     Run dashboard for workspace
#   ./projects-dashboard.sh --install [ws]  Install hook for Claude Code
#   ./projects-dashboard.sh --uninstall     Remove hook
#   ./projects-dashboard.sh --help          Show help

set -e

# Script location (resolve symlinks)
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Config locations
GLOBAL_CONFIG_DIR="$HOME/.config/projects-dashboard"
GLOBAL_CONFIG="$GLOBAL_CONFIG_DIR/config.json"
CLAUDE_HOOKS_DIR="$HOME/.claude/hooks"
CLAUDE_HOOK="$CLAUDE_HOOKS_DIR/project-dashboard.sh"

# Output
OUTPUT_FILE="/tmp/projects-dashboard.html"

# Activity thresholds (days)
ACTIVE_DAYS=7
RECENT_DAYS=30
IDLE_DAYS=90

# Folders to skip when scanning
SKIP_FOLDERS="node_modules|.git|.venv|venv|__pycache__|.cache|dist|build|.next|.nuxt|target|vendor"

# Project categories for dropdown
PROJECT_CATEGORIES="infra|products|fun|personal|skunkworks|other"

# Detect platform
detect_platform() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

PLATFORM=$(detect_platform)

# Platform-specific stat for modification time
get_mtime() {
    local file="$1"
    if [ "$PLATFORM" = "macos" ]; then
        stat -f %m "$file" 2>/dev/null
    else
        stat -c %Y "$file" 2>/dev/null
    fi
}

# Check dependencies
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required but not installed."
        echo ""
        if [ "$PLATFORM" = "macos" ]; then
            echo "Install with: brew install jq"
        else
            echo "Install with: sudo apt install jq  (Debian/Ubuntu)"
            echo "          or: sudo yum install jq  (RHEL/CentOS)"
        fi
        exit 1
    fi
}

# Show help
show_help() {
    cat << 'EOF'
Projects Dashboard - Track your coding projects

USAGE:
    projects-dashboard.sh [OPTIONS] [WORKSPACE]

OPTIONS:
    --install [WORKSPACE]   Install as Claude Code session hook
    --uninstall             Remove Claude Code hook
    --help                  Show this help message

ARGUMENTS:
    WORKSPACE              Directory containing projects (default: from config or current dir)

EXAMPLES:
    # Run dashboard for current directory
    ./projects-dashboard.sh

    # Run dashboard for specific workspace
    ./projects-dashboard.sh ~/dev/projects

    # Install as Claude Code hook
    ./projects-dashboard.sh --install ~/dev/projects

    # Remove hook
    ./projects-dashboard.sh --uninstall

CONFIG:
    Global config: ~/.config/projects-dashboard/config.json
    Project config: <workspace>/.projects-config.json

EOF
}

# Install hook
do_install() {
    local workspace="$1"

    # Resolve workspace to absolute path
    if [ -n "$workspace" ]; then
        workspace="$(cd "$workspace" 2>/dev/null && pwd)" || {
            echo "Error: Cannot access workspace: $1"
            exit 1
        }
    else
        workspace="$(pwd)"
    fi

    echo "Installing Projects Dashboard..."
    echo ""

    # Create global config directory
    mkdir -p "$GLOBAL_CONFIG_DIR"

    # Write global config
    cat > "$GLOBAL_CONFIG" << EOF
{
  "workspace": "$workspace",
  "script": "$SCRIPT_PATH"
}
EOF
    echo "Created config: $GLOBAL_CONFIG"

    # Create Claude hooks directory
    mkdir -p "$CLAUDE_HOOKS_DIR"

    # Write hook script
    cat > "$CLAUDE_HOOK" << EOF
#!/bin/bash
# Projects Dashboard - Claude Code session hook
# Installed by: $SCRIPT_PATH

CONFIG="$GLOBAL_CONFIG"

if [ -f "\$CONFIG" ]; then
    SCRIPT=\$(jq -r '.script' "\$CONFIG")
    WORKSPACE=\$(jq -r '.workspace' "\$CONFIG")

    if [ -x "\$SCRIPT" ]; then
        "\$SCRIPT" "\$WORKSPACE"
    else
        echo "Projects Dashboard: Script not found or not executable: \$SCRIPT"
    fi
else
    echo "Projects Dashboard: Config not found: \$CONFIG"
fi
EOF
    chmod +x "$CLAUDE_HOOK"
    echo "Created hook: $CLAUDE_HOOK"

    # Ensure main script is executable
    chmod +x "$SCRIPT_PATH"

    echo ""
    echo "Installation complete!"
    echo ""
    echo "Workspace: $workspace"
    echo "Dashboard will run when you start a new Claude Code session."
    echo ""
    echo "To change workspace later, edit: $GLOBAL_CONFIG"
    echo "Or run: $SCRIPT_PATH --install /new/workspace"
}

# Uninstall hook
do_uninstall() {
    echo "Uninstalling Projects Dashboard..."
    echo ""

    if [ -f "$CLAUDE_HOOK" ]; then
        rm "$CLAUDE_HOOK"
        echo "Removed hook: $CLAUDE_HOOK"
    else
        echo "Hook not found: $CLAUDE_HOOK"
    fi

    if [ -f "$GLOBAL_CONFIG" ]; then
        rm "$GLOBAL_CONFIG"
        rmdir "$GLOBAL_CONFIG_DIR" 2>/dev/null || true
        echo "Removed config: $GLOBAL_CONFIG"
    else
        echo "Config not found: $GLOBAL_CONFIG"
    fi

    echo ""
    echo "Uninstallation complete."
}

# Determine workspace
get_workspace() {
    local arg_workspace="$1"

    # Priority: argument > config > current directory
    if [ -n "$arg_workspace" ]; then
        echo "$(cd "$arg_workspace" 2>/dev/null && pwd)" || echo "$arg_workspace"
    elif [ -f "$GLOBAL_CONFIG" ]; then
        jq -r '.workspace // empty' "$GLOBAL_CONFIG" 2>/dev/null || echo "$(pwd)"
    else
        echo "$(pwd)"
    fi
}

# Arrays to hold projects by category
declare -a ACTIVE_PROJECTS
declare -a RECENT_PROJECTS
declare -a IDLE_PROJECTS
declare -a DORMANT_PROJECTS
declare -a UNREGISTERED_PROJECTS
declare -a ALERTS

# Load config file using jq
load_config() {
    local config_file="$1"
    if [ -f "$config_file" ]; then
        # Return the config as-is, we'll query it with jq as needed
        echo "loaded"
    else
        echo ""
    fi
}

# Check if project is in config
is_registered() {
    local project="$1"
    local config_file="$2"
    if [ -f "$config_file" ]; then
        jq -e --arg p "$project" '.[$p] != null' "$config_file" > /dev/null 2>&1
    else
        return 1
    fi
}

# Get config value
get_config_value() {
    local project="$1"
    local field="$2"
    local default="$3"
    local config_file="$4"

    if [ -f "$config_file" ]; then
        local value=$(jq -r --arg p "$project" --arg f "$field" '.[$p][$f] // empty' "$config_file" 2>/dev/null)
        if [ -n "$value" ]; then
            echo "$value"
        else
            echo "$default"
        fi
    else
        echo "$default"
    fi
}

# Calculate days since last git commit
days_since_commit() {
    local dir="$1"
    if [ -d "$dir/.git" ]; then
        local last_commit=$(git -C "$dir" log -1 --format=%ct 2>/dev/null)
        if [ -n "$last_commit" ]; then
            local now=$(date +%s)
            echo $(( (now - last_commit) / 86400 ))
            return
        fi
    fi
    echo ""
}

# Calculate days since last file modification (for non-git folders)
days_since_modified() {
    local dir="$1"
    local latest=""

    while IFS= read -r -d '' file; do
        local mtime=$(get_mtime "$file")
        if [ -n "$mtime" ]; then
            if [ -z "$latest" ] || [ "$mtime" -gt "$latest" ]; then
                latest="$mtime"
            fi
        fi
    done < <(find "$dir" -type f \
        -not -path "*/.git/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/.venv/*" \
        -not -path "*/venv/*" \
        -not -path "*/__pycache__/*" \
        -not -path "*/.cache/*" \
        -not -path "*/dist/*" \
        -not -path "*/build/*" \
        -not -path "*/.next/*" \
        -not -path "*/target/*" \
        -print0 2>/dev/null | head -z -n 100)

    if [ -n "$latest" ]; then
        local now=$(date +%s)
        echo $(( (now - latest) / 86400 ))
    else
        echo "999"
    fi
}

# Get last activity as relative time
last_activity_relative() {
    local dir="$1"
    local is_git="$2"

    if [ "$is_git" = "true" ]; then
        git -C "$dir" log -1 --format="%cr" 2>/dev/null | sed 's/ ago//'
    else
        local latest=""
        while IFS= read -r -d '' file; do
            local mtime=$(get_mtime "$file")
            if [ -n "$mtime" ]; then
                if [ -z "$latest" ] || [ "$mtime" -gt "$latest" ]; then
                    latest="$mtime"
                fi
            fi
        done < <(find "$dir" -type f \
            -not -path "*/.git/*" \
            -not -path "*/node_modules/*" \
            -not -path "*/.venv/*" \
            -not -path "*/venv/*" \
            -not -path "*/__pycache__/*" \
            -print0 2>/dev/null | head -z -n 100)

        if [ -n "$latest" ]; then
            local now=$(date +%s)
            local diff=$((now - latest))
            if [ $diff -lt 3600 ]; then
                echo "$((diff / 60)) mins"
            elif [ $diff -lt 86400 ]; then
                echo "$((diff / 3600)) hours"
            elif [ $diff -lt 604800 ]; then
                echo "$((diff / 86400)) days"
            elif [ $diff -lt 2592000 ]; then
                echo "$((diff / 604800)) weeks"
            else
                echo "$((diff / 2592000)) months"
            fi
        else
            echo "unknown"
        fi
    fi
}

# Get uncommitted file count (git only)
uncommitted_count() {
    local dir="$1"
    if [ -d "$dir/.git" ]; then
        local count=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        if [ "$count" -gt 0 ]; then
            echo "$count files"
        else
            echo "clean"
        fi
    else
        echo "-"
    fi
}

# Get remote sync status (git only)
remote_status() {
    local dir="$1"
    if [ -d "$dir/.git" ]; then
        local remote=$(git -C "$dir" remote 2>/dev/null)
        if [ -z "$remote" ]; then
            echo "local only"
            return
        fi
        local status=$(git -C "$dir" status -sb 2>/dev/null | head -1)
        if echo "$status" | grep -q "ahead"; then
            local ahead=$(echo "$status" | sed -n 's/.*ahead \([0-9]*\).*/\1/p')
            echo "↑$ahead ahead"
        elif echo "$status" | grep -q "behind"; then
            local behind=$(echo "$status" | sed -n 's/.*behind \([0-9]*\).*/\1/p')
            echo "↓$behind behind"
        else
            echo "synced"
        fi
    else
        echo "local-only"
    fi
}

# Get repository visibility (public/private) from GitHub
repo_visibility() {
    local dir="$1"
    if [ -d "$dir/.git" ]; then
        local remote_url=$(git -C "$dir" remote get-url origin 2>/dev/null)
        if [ -z "$remote_url" ]; then
            echo "local-only"
            return
        fi
        # Check if it's a GitHub URL
        if echo "$remote_url" | grep -qE "github\.com[:/]"; then
            # Extract owner/repo from URL
            local repo_path=$(echo "$remote_url" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
            if [ -n "$repo_path" ]; then
                # Use GitHub API - public repos return data, private repos return 404
                local http_code=$(curl -s -o /dev/null -w "%{http_code}" "https://api.github.com/repos/$repo_path" 2>/dev/null)
                if [ "$http_code" = "200" ]; then
                    echo "public"
                    return
                elif [ "$http_code" = "404" ]; then
                    echo "private"
                    return
                fi
            fi
            echo "unknown"
        else
            echo "non-github"
        fi
    else
        echo "local-only"
    fi
}

# Count files in project
file_count() {
    local dir="$1"
    find "$dir" -type f \
        -not -path "*/.git/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/.venv/*" \
        -not -path "*/venv/*" \
        -not -path "*/__pycache__/*" \
        2>/dev/null | wc -l | tr -d ' '
}

# Detect project type from files
detect_type() {
    local dir="$1"

    if [ -f "$dir/package.json" ]; then
        if [ -f "$dir/next.config.js" ] || [ -f "$dir/next.config.mjs" ]; then
            echo "Next.js"
        elif [ -f "$dir/vite.config.js" ] || [ -f "$dir/vite.config.ts" ]; then
            echo "Vite"
        elif grep -q "react" "$dir/package.json" 2>/dev/null; then
            echo "React"
        elif grep -q "vue" "$dir/package.json" 2>/dev/null; then
            echo "Vue"
        else
            echo "Node.js"
        fi
    elif [ -f "$dir/requirements.txt" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ]; then
        echo "Python"
    elif [ -f "$dir/Cargo.toml" ]; then
        echo "Rust"
    elif [ -f "$dir/go.mod" ]; then
        echo "Go"
    elif [ -f "$dir/Gemfile" ]; then
        echo "Ruby"
    elif [ -f "$dir/pom.xml" ] || [ -f "$dir/build.gradle" ]; then
        echo "Java"
    elif ls "$dir"/*.sh >/dev/null 2>&1; then
        echo "Shell"
    elif [ -f "$dir/README.md" ] || [ -f "$dir/CLAUDE.md" ]; then
        echo "Documentation"
    else
        echo "Other"
    fi
}

# Auto-detect description from package.json or README.md
detect_description() {
    local dir="$1"
    local desc=""

    # Try package.json description field
    if [ -f "$dir/package.json" ]; then
        desc=$(jq -r '.description // empty' "$dir/package.json" 2>/dev/null)
        if [ -n "$desc" ] && [ "$desc" != "null" ]; then
            echo "$desc"
            return
        fi
    fi

    # Try pyproject.toml description
    if [ -f "$dir/pyproject.toml" ]; then
        desc=$(grep -m1 '^description' "$dir/pyproject.toml" 2>/dev/null | sed 's/description *= *["'"'"']\(.*\)["'"'"']/\1/')
        if [ -n "$desc" ]; then
            echo "$desc"
            return
        fi
    fi

    # Try README.md - get first non-empty, non-heading line
    if [ -f "$dir/README.md" ]; then
        desc=$(grep -v '^#' "$dir/README.md" 2>/dev/null | grep -v '^$' | grep -v '^\[' | grep -v '^!' | head -1 | sed 's/^[[:space:]]*//' | cut -c1-100)
        if [ -n "$desc" ]; then
            echo "$desc"
            return
        fi
    fi

    echo ""
}

# Auto-import config from Downloads folder
import_from_downloads() {
    local workspace="$1"
    local config_file="$workspace/.projects-config.json"
    local downloads_dir="$HOME/Downloads"
    local imported=false

    # Look for projects-config*.json files in Downloads
    for download_file in "$downloads_dir"/projects-config*.json; do
        [ -f "$download_file" ] || continue

        # Validate it's valid JSON
        if ! jq empty "$download_file" 2>/dev/null; then
            echo "Warning: Invalid JSON in $download_file, skipping"
            continue
        fi

        # Check if it's for this workspace (has project names that exist here)
        local first_project=$(jq -r 'keys[0] // empty' "$download_file" 2>/dev/null)
        if [ -n "$first_project" ] && [ -d "$workspace/$first_project" ]; then
            # Merge with existing config if present
            if [ -f "$config_file" ]; then
                # Merge: new file overwrites existing keys
                local merged=$(jq -s '.[0] * .[1]' "$config_file" "$download_file")
                echo "$merged" > "$config_file"
                echo "Config imported and merged from: $download_file"
            else
                cp "$download_file" "$config_file"
                echo "Config imported from: $download_file"
            fi

            # Remove the downloaded file
            rm "$download_file"
            imported=true
            break
        fi
    done

    $imported && return 0 || return 1
}

# Run the dashboard
run_dashboard() {
    local WORKSPACE="$1"
    local CONFIG_FILE="$WORKSPACE/.projects-config.json"

    # Verify workspace exists
    if [ ! -d "$WORKSPACE" ]; then
        echo "Error: Workspace not found: $WORKSPACE"
        exit 1
    fi

    # Auto-import config from Downloads if present
    import_from_downloads "$WORKSPACE" || true

    cd "$WORKSPACE" || { echo "Error: Cannot access $WORKSPACE"; exit 1; }

    # Collect all project data for JSON embedding
    ALL_PROJECTS_JSON="["
    first_project=true

    # Get all subdirectories
    for dir in */; do
        [ ! -d "$dir" ] && continue

        project="${dir%/}"

        # Skip common non-project folders
        if echo "$project" | grep -qE "^($SKIP_FOLDERS)$"; then
            continue
        fi

        # Skip hidden directories
        [[ "$project" == .* ]] && continue

        full_path="$WORKSPACE/$project"
        is_git="false"
        [ -d "$full_path/.git" ] && is_git="true"

        # Get days since last activity
        if [ "$is_git" = "true" ]; then
            days=$(days_since_commit "$full_path")
            [ -z "$days" ] && days=$(days_since_modified "$full_path")
        else
            days=$(days_since_modified "$full_path")
        fi

        detected_type=$(detect_type "$full_path")
        detected_desc=$(detect_description "$full_path")

        # Get config values
        if is_registered "$project" "$CONFIG_FILE"; then
            registered="true"
            category=$(get_config_value "$project" "category" "other" "$CONFIG_FILE")
            description=$(get_config_value "$project" "description" "$detected_desc" "$CONFIG_FILE")
        else
            registered="false"
            category="other"
            description="$detected_desc"
        fi

        last_activity=$(last_activity_relative "$full_path" "$is_git")
        uncommit=$(uncommitted_count "$full_path")
        remote=$(remote_status "$full_path")
        visibility=$(repo_visibility "$full_path")
        files=$(file_count "$full_path")

        # Build row data
        row="$project|$category|$last_activity|$uncommit|$remote|$visibility|$files|$is_git|$description|$registered|$detected_type"

        # Add to JSON array
        if [ "$first_project" = "true" ]; then
            first_project=false
        else
            ALL_PROJECTS_JSON+=","
        fi

        # Escape description for JSON
        escaped_desc=$(echo "$description" | sed 's/\\/\\\\/g; s/"/\\"/g')

        ALL_PROJECTS_JSON+="{\"name\":\"$project\",\"category\":\"$category\",\"techStack\":\"$detected_type\",\"lastActivity\":\"$last_activity\",\"uncommitted\":\"$uncommit\",\"remote\":\"$remote\",\"visibility\":\"$visibility\",\"files\":$files,\"isGit\":$is_git,\"description\":\"$escaped_desc\",\"registered\":$registered,\"days\":$days}"

        # Categorize
        if [ "$registered" = "false" ]; then
            UNREGISTERED_PROJECTS+=("$row")
        elif [ "$days" -le "$ACTIVE_DAYS" ]; then
            ACTIVE_PROJECTS+=("$row")
        elif [ "$days" -le "$RECENT_DAYS" ]; then
            RECENT_PROJECTS+=("$row")
        elif [ "$days" -le "$IDLE_DAYS" ]; then
            IDLE_PROJECTS+=("$row")
        else
            DORMANT_PROJECTS+=("$row")
        fi

        # Generate alerts (git repos only, registered projects)
        if [ "$is_git" = "true" ] && [ "$registered" = "true" ]; then
            if [ "$uncommit" != "clean" ] && [ "$uncommit" != "-" ]; then
                ALERTS+=("$project: $uncommit uncommitted")
            fi
            if echo "$remote" | grep -q "ahead"; then
                ALERTS+=("$project: $remote (needs push)")
            fi
            if [ "$remote" = "local only" ]; then
                ALERTS+=("$project: no remote configured")
            fi
        fi
    done

    ALL_PROJECTS_JSON+="]"

    # Generate HTML
    cat > "$OUTPUT_FILE" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Projects Dashboard</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif;
            background: #1a1a2e;
            color: #eee;
            padding: 20px;
            min-height: 100vh;
        }
        .container { max-width: 1400px; margin: 0 auto; }
        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 20px 0 30px;
            border-bottom: 1px solid #333;
            margin-bottom: 30px;
        }
        .header-left { }
        header h1 { font-size: 24px; font-weight: 500; color: #fff; }
        header .subtitle { color: #888; font-size: 14px; margin-top: 5px; }
        .header-actions { display: flex; gap: 10px; }
        .btn {
            padding: 8px 16px;
            border-radius: 6px;
            font-size: 13px;
            font-weight: 500;
            cursor: pointer;
            border: none;
            transition: all 0.2s;
        }
        .btn-primary {
            background: #4ade80;
            color: #1a1a2e;
        }
        .btn-primary:hover { background: #22c55e; }
        .btn-primary:disabled {
            background: #333;
            color: #666;
            cursor: not-allowed;
        }
        .btn-secondary {
            background: #333;
            color: #eee;
        }
        .btn-secondary:hover { background: #444; }
        .section { margin-bottom: 30px; }
        .section-header {
            display: flex;
            align-items: center;
            gap: 10px;
            margin-bottom: 12px;
            padding-bottom: 8px;
            border-bottom: 1px solid #333;
        }
        .section-header .icon {
            width: 12px;
            height: 12px;
            border-radius: 50%;
        }
        .section-header h2 { font-size: 14px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
        .section-header .count { color: #888; font-size: 13px; }
        .section-header .desc { color: #666; font-size: 12px; margin-left: auto; }
        .active .icon { background: #4ade80; box-shadow: 0 0 8px #4ade80; }
        .recent .icon { background: #facc15; }
        .idle .icon { background: #888; }
        .dormant .icon { background: #444; }
        .unregistered .icon { background: #60a5fa; box-shadow: 0 0 8px #60a5fa; }
        table { width: 100%; border-collapse: collapse; font-size: 13px; table-layout: fixed; }
        .col-project { width: 15%; }
        .col-tech { width: 8%; }
        .col-category { width: 10%; }
        .col-desc { width: 25%; }
        .col-activity { width: 10%; }
        .col-status { width: 10%; }
        .col-remote { width: 10%; }
        .col-visibility { width: 8%; }
        .col-files { width: 4%; }
        th {
            text-align: left;
            padding: 10px 12px;
            background: #252540;
            color: #888;
            font-weight: 500;
            font-size: 11px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        td { padding: 10px 12px; border-bottom: 1px solid #2a2a40; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        tr:hover td { background: #252540; }
        .project-name { font-weight: 500; color: #fff; }
        .tech-stack { color: #888; font-size: 12px; }
        .clean { color: #4ade80; }
        .dirty { color: #f87171; }
        .synced { color: #4ade80; }
        .ahead { color: #facc15; }
        .behind { color: #f87171; }
        .no-git { color: #666; font-style: italic; }
        .local-only { color: #60a5fa; }
        .visibility-public { color: #4ade80; }
        .visibility-private { color: #facc15; }
        .visibility-local { color: #60a5fa; }
        .visibility-unknown { color: #666; }
        .git-badge {
            display: inline-block;
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 10px;
            font-weight: 500;
            margin-left: 8px;
        }
        .git-badge.git { background: #334155; color: #94a3b8; }
        .git-badge.folder { background: #3f3f46; color: #a1a1aa; }
        .new-badge {
            display: inline-block;
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 10px;
            font-weight: 500;
            margin-left: 8px;
            background: #1e3a5f;
            color: #60a5fa;
        }
        .alerts {
            background: #2a1a1a;
            border: 1px solid #4a2a2a;
            border-radius: 8px;
            padding: 15px 20px;
            margin-bottom: 30px;
        }
        .alerts h3 { color: #f87171; font-size: 12px; text-transform: uppercase; margin-bottom: 10px; }
        .alerts ul { list-style: none; }
        .alerts li { padding: 5px 0; color: #fca5a5; font-size: 13px; }
        .alerts li::before { content: "⚠ "; }
        .summary {
            display: flex;
            gap: 30px;
            justify-content: center;
            padding: 20px;
            background: #252540;
            border-radius: 8px;
            margin-top: 20px;
        }
        .summary-item { text-align: center; }
        .summary-item .num { font-size: 24px; font-weight: 600; }
        .summary-item .label { font-size: 11px; color: #888; text-transform: uppercase; margin-top: 4px; }
        .summary-item.active .num { color: #4ade80; }
        .summary-item.recent .num { color: #facc15; }
        .summary-item.idle .num { color: #888; }
        .summary-item.dormant .num { color: #555; }
        .summary-item.unregistered .num { color: #60a5fa; }

        /* Interactive elements */
        select.type-select {
            background: #252540;
            color: #eee;
            border: 1px solid #333;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 12px;
            cursor: pointer;
        }
        select.type-select:hover { border-color: #4ade80; }
        select.type-select.modified { border-color: #facc15; background: #2a2a1a; }

        input.desc-input {
            background: #252540;
            color: #eee;
            border: 1px solid #333;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 12px;
            width: 200px;
        }
        input.desc-input:hover { border-color: #4ade80; }
        input.desc-input:focus { border-color: #4ade80; outline: none; }
        input.desc-input.modified { border-color: #facc15; background: #2a2a1a; }

        .register-btn {
            background: #1e3a5f;
            color: #60a5fa;
            border: none;
            padding: 4px 10px;
            border-radius: 4px;
            font-size: 11px;
            cursor: pointer;
            font-weight: 500;
        }
        .register-btn:hover { background: #2563eb; color: #fff; }
        .register-all-btn {
            background: #1e3a5f;
            color: #60a5fa;
            border: none;
            padding: 6px 12px;
            border-radius: 4px;
            font-size: 12px;
            cursor: pointer;
            font-weight: 500;
            margin-left: auto;
        }
        .register-all-btn:hover { background: #2563eb; color: #fff; }

        .toast {
            position: fixed;
            bottom: 20px;
            right: 20px;
            background: #4ade80;
            color: #1a1a2e;
            padding: 12px 20px;
            border-radius: 8px;
            font-weight: 500;
            display: none;
            z-index: 1000;
            max-width: 400px;
        }
        .toast.show { display: block; animation: fadeIn 0.3s; }
        .toast.info { background: #60a5fa; }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }

        .changes-banner {
            background: #2a2a1a;
            border: 1px solid #facc15;
            border-radius: 8px;
            padding: 12px 20px;
            margin-bottom: 20px;
            display: none;
            justify-content: space-between;
            align-items: center;
        }
        .changes-banner.show { display: flex; }
        .changes-banner .text { color: #facc15; font-size: 13px; }
        .changes-banner .actions { display: flex; gap: 10px; }

        .save-instructions {
            background: #1e3a5f;
            border: 1px solid #60a5fa;
            border-radius: 8px;
            padding: 15px 20px;
            margin-bottom: 20px;
            display: none;
        }
        .save-instructions.show { display: block; }
        .save-instructions h4 { color: #4ade80; font-size: 14px; margin-bottom: 10px; }
        .save-instructions p { color: #94a3b8; font-size: 13px; margin: 5px 0; }
        .save-instructions strong { color: #60a5fa; }
    </style>
</head>
<body>
<div class="container">
HTMLHEAD

    # Header with save button
    cat >> "$OUTPUT_FILE" << HEADER
<header>
    <div class="header-left">
        <h1>Projects Dashboard</h1>
        <div class="subtitle">$(date '+%Y-%m-%d %H:%M') &bull; $WORKSPACE</div>
    </div>
    <div class="header-actions">
        <button class="btn btn-secondary" onclick="resetChanges()">Reset</button>
        <button class="btn btn-primary" id="saveBtn" onclick="saveConfig()" disabled>Save Config</button>
    </div>
</header>

<div class="changes-banner" id="changesBanner">
    <span class="text">You have unsaved changes</span>
    <div class="actions">
        <button class="btn btn-secondary" onclick="resetChanges()">Discard</button>
        <button class="btn btn-primary" onclick="saveConfig()">Save Config</button>
    </div>
</div>

<div class="save-instructions" id="saveInstructions">
    <h4>Config downloaded!</h4>
    <p>Your config has been saved to your Downloads folder.</p>
    <p>It will be <strong>automatically imported</strong> the next time the dashboard runs.</p>
    <p style="margin-top: 10px; color: #888;">Just restart Claude Code or run the dashboard script again.</p>
</div>
HEADER

    # Alerts
    if [ ${#ALERTS[@]} -gt 0 ]; then
        echo "<div class=\"alerts\"><h3>Alerts</h3><ul>" >> "$OUTPUT_FILE"
        for alert in "${ALERTS[@]}"; do
            echo "<li>$alert</li>" >> "$OUTPUT_FILE"
        done
        echo "</ul></div>" >> "$OUTPUT_FILE"
    fi

    # Function to output a section
    output_section() {
        local class="$1"
        local title="$2"
        local desc="$3"
        shift 3
        local projects=("$@")

        [ ${#projects[@]} -eq 0 ] && return

        echo "<div class=\"section $class\">" >> "$OUTPUT_FILE"
        echo "<div class=\"section-header\">" >> "$OUTPUT_FILE"
        echo "<div class=\"icon\"></div>" >> "$OUTPUT_FILE"
        echo "<h2>$title</h2>" >> "$OUTPUT_FILE"
        echo "<span class=\"count\">(${#projects[@]})</span>" >> "$OUTPUT_FILE"
        echo "<span class=\"desc\">$desc</span>" >> "$OUTPUT_FILE"
        if [ "$class" = "unregistered" ]; then
            echo "<button class=\"register-all-btn\" onclick=\"registerAll()\">Register All</button>" >> "$OUTPUT_FILE"
        fi
        echo "</div>" >> "$OUTPUT_FILE"
        echo "<table><thead><tr>" >> "$OUTPUT_FILE"

        if [ "$class" = "unregistered" ]; then
            echo "<th>Project</th><th>Tech Stack</th><th>Category</th><th>Description</th><th>Last Activity</th><th>Status</th><th>Action</th>" >> "$OUTPUT_FILE"
        else
            echo "<th class=\"col-project\">Project</th><th class=\"col-tech\">Tech Stack</th><th class=\"col-category\">Category</th><th class=\"col-desc\">Description</th><th class=\"col-activity\">Last Activity</th><th class=\"col-status\">Status</th><th class=\"col-remote\">Remote</th><th class=\"col-visibility\">Visibility</th><th class=\"col-files\">Files</th>" >> "$OUTPUT_FILE"
        fi
        echo "</tr></thead><tbody>" >> "$OUTPUT_FILE"

        for row in "${projects[@]}"; do
            IFS='|' read -r project category last_activity uncommit remote visibility files is_git description registered detected_type <<< "$row"

            # Determine classes
            uncommit_class="clean"
            [[ "$uncommit" == *"files"* ]] && uncommit_class="dirty"
            [[ "$uncommit" == "-" ]] && uncommit_class="no-git"

            remote_class="synced"
            [[ "$remote" == *"ahead"* ]] && remote_class="ahead"
            [[ "$remote" == *"behind"* ]] && remote_class="behind"
            [[ "$remote" == "local only" ]] && remote_class="local-only"
            [[ "$remote" == "local-only" ]] && remote_class="local-only"

            visibility_class="visibility-unknown"
            [[ "$visibility" == "public" ]] && visibility_class="visibility-public"
            [[ "$visibility" == "private" ]] && visibility_class="visibility-private"
            [[ "$visibility" == "local-only" ]] && visibility_class="visibility-local"

            # Badge for git vs folder
            if [ "$is_git" = "true" ]; then
                badge="<span class=\"git-badge git\">git</span>"
            else
                badge="<span class=\"git-badge folder\">folder</span>"
            fi

            echo "<tr data-project=\"$project\">" >> "$OUTPUT_FILE"

            if [ "$class" = "unregistered" ]; then
                echo "<td class=\"project-name\">$project $badge<span class=\"new-badge\">NEW</span></td>" >> "$OUTPUT_FILE"
                echo "<td class=\"tech-stack\">$detected_type</td>" >> "$OUTPUT_FILE"

                # Category dropdown
                echo "<td><select class=\"type-select\" data-project=\"$project\" data-field=\"category\" onchange=\"markModified(this)\">" >> "$OUTPUT_FILE"
                IFS='|' read -ra cats <<< "$PROJECT_CATEGORIES"
                for c in "${cats[@]}"; do
                    selected=""
                    [ "$c" = "$category" ] && selected="selected"
                    echo "<option value=\"$c\" $selected>$c</option>" >> "$OUTPUT_FILE"
                done
                echo "</select></td>" >> "$OUTPUT_FILE"

                # Description input (auto-filled)
                echo "<td><input type=\"text\" class=\"desc-input\" data-project=\"$project\" data-field=\"description\" placeholder=\"Add description...\" onchange=\"markModified(this)\" value=\"$description\"></td>" >> "$OUTPUT_FILE"
                echo "<td>$last_activity</td>" >> "$OUTPUT_FILE"
                echo "<td class=\"$uncommit_class\">$uncommit</td>" >> "$OUTPUT_FILE"
                echo "<td><button class=\"register-btn\" onclick=\"registerProject('$project')\">Register</button></td>" >> "$OUTPUT_FILE"
            else
                echo "<td class=\"project-name\">$project $badge</td>" >> "$OUTPUT_FILE"
                echo "<td class=\"tech-stack\">$detected_type</td>" >> "$OUTPUT_FILE"

                # Category dropdown for registered projects
                echo "<td><select class=\"type-select\" data-project=\"$project\" data-field=\"category\" onchange=\"markModified(this)\">" >> "$OUTPUT_FILE"
                IFS='|' read -ra cats <<< "$PROJECT_CATEGORIES"
                for c in "${cats[@]}"; do
                    selected=""
                    [ "$c" = "$category" ] && selected="selected"
                    echo "<option value=\"$c\" $selected>$c</option>" >> "$OUTPUT_FILE"
                done
                echo "</select></td>" >> "$OUTPUT_FILE"

                # Description input
                echo "<td><input type=\"text\" class=\"desc-input\" data-project=\"$project\" data-field=\"description\" placeholder=\"Add description...\" onchange=\"markModified(this)\" value=\"$description\"></td>" >> "$OUTPUT_FILE"
                echo "<td>$last_activity</td>" >> "$OUTPUT_FILE"
                echo "<td class=\"$uncommit_class\">$uncommit</td>" >> "$OUTPUT_FILE"
                echo "<td class=\"$remote_class\">$remote</td>" >> "$OUTPUT_FILE"
                echo "<td class=\"$visibility_class\">$visibility</td>" >> "$OUTPUT_FILE"
                echo "<td>$files</td>" >> "$OUTPUT_FILE"
            fi

            echo "</tr>" >> "$OUTPUT_FILE"
        done

        echo "</tbody></table></div>" >> "$OUTPUT_FILE"
    }

    # Output sections - Unregistered first if any
    output_section "unregistered" "Unregistered" "New projects - register to track" "${UNREGISTERED_PROJECTS[@]}"
    output_section "active" "Active" "Activity within 7 days" "${ACTIVE_PROJECTS[@]}"
    output_section "recent" "Recent" "Activity 8-30 days" "${RECENT_PROJECTS[@]}"
    output_section "idle" "Idle" "Activity 31-90 days" "${IDLE_PROJECTS[@]}"
    output_section "dormant" "Dormant" "Activity >90 days" "${DORMANT_PROJECTS[@]}"

    # Summary
    total=$((${#ACTIVE_PROJECTS[@]} + ${#RECENT_PROJECTS[@]} + ${#IDLE_PROJECTS[@]} + ${#DORMANT_PROJECTS[@]}))
    unreg=${#UNREGISTERED_PROJECTS[@]}

    cat >> "$OUTPUT_FILE" << SUMMARY
<div class="summary">
    <div class="summary-item unregistered"><div class="num">$unreg</div><div class="label">Unregistered</div></div>
    <div class="summary-item active"><div class="num">${#ACTIVE_PROJECTS[@]}</div><div class="label">Active</div></div>
    <div class="summary-item recent"><div class="num">${#RECENT_PROJECTS[@]}</div><div class="label">Recent</div></div>
    <div class="summary-item idle"><div class="num">${#IDLE_PROJECTS[@]}</div><div class="label">Idle</div></div>
    <div class="summary-item dormant"><div class="num">${#DORMANT_PROJECTS[@]}</div><div class="label">Dormant</div></div>
    <div class="summary-item"><div class="num">$((total + unreg))</div><div class="label">Total</div></div>
</div>
SUMMARY

    # Embed project data and JavaScript
    cat >> "$OUTPUT_FILE" << JSBLOCK
<div class="toast" id="toast"></div>

<script>
// Embedded project data
const projectsData = $ALL_PROJECTS_JSON;
const workspace = "$WORKSPACE";
const configFile = "$CONFIG_FILE";
const platform = "$PLATFORM";

// Track modifications
let modifications = {};
let hasChanges = false;

function markModified(element) {
    const project = element.dataset.project;
    const field = element.dataset.field;
    const value = element.value;

    if (!modifications[project]) {
        modifications[project] = {};
    }
    modifications[project][field] = value;

    element.classList.add('modified');
    hasChanges = true;
    updateUI();
}

function registerProject(project) {
    if (!modifications[project]) {
        modifications[project] = {};
    }
    modifications[project].registered = true;

    // Get current values from inputs
    const categorySelect = document.querySelector(\`select[data-project="\${project}"]\`);
    const descInput = document.querySelector(\`input[data-project="\${project}"]\`);

    if (categorySelect) modifications[project].category = categorySelect.value;
    if (descInput) modifications[project].description = descInput.value;

    hasChanges = true;
    updateUI();
    showToast(\`\${project} marked for registration. Save to confirm.\`);
}

function registerAll() {
    const unregistered = projectsData.filter(p => !p.registered);
    unregistered.forEach(p => {
        if (!modifications[p.name]) {
            modifications[p.name] = {};
        }
        modifications[p.name].registered = true;

        // Get current values from inputs
        const categorySelect = document.querySelector(\`select[data-project="\${p.name}"]\`);
        const descInput = document.querySelector(\`input[data-project="\${p.name}"]\`);

        if (categorySelect) modifications[p.name].category = categorySelect.value;
        if (descInput) modifications[p.name].description = descInput.value;
    });

    hasChanges = true;
    updateUI();
    showToast(\`\${unregistered.length} projects marked for registration. Save to confirm.\`);
}

function updateUI() {
    document.getElementById('saveBtn').disabled = !hasChanges;
    document.getElementById('changesBanner').classList.toggle('show', hasChanges);
}

function resetChanges() {
    modifications = {};
    hasChanges = false;

    // Reset all modified elements
    document.querySelectorAll('.modified').forEach(el => {
        el.classList.remove('modified');
        // Reset to original value from projectsData
        const project = el.dataset.project;
        const field = el.dataset.field;
        const projectData = projectsData.find(p => p.name === project);
        if (projectData && field) {
            el.value = projectData[field] || '';
        }
    });

    document.getElementById('saveInstructions').classList.remove('show');
    updateUI();
    showToast('Changes discarded');
}

function saveConfig() {
    // Check for modified but unregistered projects
    const modifiedUnregistered = [];
    projectsData.forEach(p => {
        if (!p.registered && modifications[p.name]) {
            if (!modifications[p.name].registered) {
                // Has modifications but not marked for registration
                if (modifications[p.name].category || modifications[p.name].description !== undefined) {
                    modifiedUnregistered.push(p.name);
                }
            }
        }
    });

    if (modifiedUnregistered.length > 0) {
        const proceed = confirm(
            \`Warning: \${modifiedUnregistered.length} project(s) have changes but are not registered:\\n\\n\` +
            modifiedUnregistered.join('\\n') +
            \`\\n\\nThese changes will be lost. Click OK to save anyway, or Cancel to go back and register them.\`
        );
        if (!proceed) return;
    }

    // Build config object from current data + modifications
    const config = {};

    // Start with existing registered projects
    projectsData.forEach(p => {
        if (p.registered || (modifications[p.name] && modifications[p.name].registered)) {
            config[p.name] = {
                category: modifications[p.name]?.category || p.category || 'other',
                description: modifications[p.name]?.description || p.description || ''
            };
        }
    });

    // Apply any other modifications
    Object.keys(modifications).forEach(project => {
        if (config[project]) {
            if (modifications[project].category) config[project].category = modifications[project].category;
            if (modifications[project].description !== undefined) config[project].description = modifications[project].description;
        }
    });

    // Generate JSON and download file
    const json = JSON.stringify(config, null, 2);
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    const filename = \`projects-config-\${timestamp}.json\`;

    const blob = new Blob([json], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);

    // Show success message
    document.getElementById('saveInstructions').classList.add('show');

    // Clear modifications after save
    modifications = {};
    hasChanges = false;
    document.querySelectorAll('.modified').forEach(el => el.classList.remove('modified'));
    updateUI();

    showToast('Config saved! Will auto-import on next dashboard run.', 'info');
}

function showToast(message, type = 'success') {
    const toast = document.getElementById('toast');
    toast.textContent = message;
    toast.className = 'toast show' + (type === 'info' ? ' info' : '');
    setTimeout(() => toast.classList.remove('show'), 3000);
}

// Initialize
updateUI();
</script>
</div>
</body>
</html>
JSBLOCK

    echo "Dashboard generated: $OUTPUT_FILE"

    # Open in browser
    if [ "$PLATFORM" = "macos" ]; then
        open "$OUTPUT_FILE"
    elif command -v xdg-open &> /dev/null; then
        xdg-open "$OUTPUT_FILE"
    fi
}

# Main entry point
main() {
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --install)
            check_dependencies
            do_install "${2:-}"
            exit 0
            ;;
        --uninstall)
            do_uninstall
            exit 0
            ;;
        *)
            check_dependencies
            local workspace=$(get_workspace "${1:-}")
            run_dashboard "$workspace"
            ;;
    esac
}

main "$@"
