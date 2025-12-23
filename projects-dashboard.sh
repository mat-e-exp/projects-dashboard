#!/bin/bash

# Projects Dashboard
# A simple way to track your coding projects
# Works with git repos and regular folders

# Usage: ./projects-dashboard.sh [workspace_directory]
# If no directory specified, uses current directory

WORKSPACE="${1:-$(pwd)}"
OUTPUT_FILE="/tmp/projects-dashboard.html"

# Activity thresholds (days)
ACTIVE_DAYS=7
RECENT_DAYS=30
IDLE_DAYS=90

# Folders to skip when scanning
SKIP_FOLDERS="node_modules|.git|.venv|venv|__pycache__|.cache|dist|build|.next|.nuxt|target|vendor"

# Arrays to hold projects by activity
declare -a ACTIVE_PROJECTS
declare -a RECENT_PROJECTS
declare -a IDLE_PROJECTS
declare -a DORMANT_PROJECTS
declare -a ALERTS

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
    # Find most recently modified file, excluding common non-project folders
    local latest=$(find "$dir" -type f \
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
        -exec stat -f %m {} \; 2>/dev/null | sort -rn | head -1)

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
        # Get most recent file modification
        local latest=$(find "$dir" -type f \
            -not -path "*/.git/*" \
            -not -path "*/node_modules/*" \
            -not -path "*/.venv/*" \
            -not -path "*/venv/*" \
            -not -path "*/__pycache__/*" \
            -exec stat -f %m {} \; 2>/dev/null | sort -rn | head -1)

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
        echo "-"
    fi
}

# Count files in project (for non-git)
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
    elif [ -f "$dir/CLAUDE.md" ]; then
        echo "Claude"
    else
        echo "-"
    fi
}

# Main processing
cd "$WORKSPACE" || { echo "Error: Cannot access $WORKSPACE"; exit 1; }

# Get all subdirectories (excluding hidden and common non-project folders)
for dir in */; do
    [ ! -d "$dir" ] && continue

    project="${dir%/}"

    # Skip common non-project folders
    if echo "$project" | grep -qE "^($SKIP_FOLDERS)$"; then
        continue
    fi

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

    type=$(detect_type "$full_path")
    last_activity=$(last_activity_relative "$full_path" "$is_git")
    uncommit=$(uncommitted_count "$full_path")
    remote=$(remote_status "$full_path")
    files=$(file_count "$full_path")

    # Build row data
    row="$project|$type|$last_activity|$uncommit|$remote|$files|$is_git"

    # Categorize by activity
    if [ "$days" -le "$ACTIVE_DAYS" ]; then
        ACTIVE_PROJECTS+=("$row")
    elif [ "$days" -le "$RECENT_DAYS" ]; then
        RECENT_PROJECTS+=("$row")
    elif [ "$days" -le "$IDLE_DAYS" ]; then
        IDLE_PROJECTS+=("$row")
    else
        DORMANT_PROJECTS+=("$row")
    fi

    # Generate alerts (git repos only)
    if [ "$is_git" = "true" ]; then
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
            text-align: center;
            padding: 20px 0 30px;
            border-bottom: 1px solid #333;
            margin-bottom: 30px;
        }
        header h1 { font-size: 24px; font-weight: 500; color: #fff; }
        header .subtitle { color: #888; font-size: 14px; margin-top: 5px; }
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
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th {
            text-align: left;
            padding: 10px 12px;
            background: #252540;
            color: #888;
            font-weight: 500;
            font-size: 11px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        td { padding: 10px 12px; border-bottom: 1px solid #2a2a40; }
        tr:hover td { background: #252540; }
        .project-name { font-weight: 500; color: #fff; }
        .type { color: #888; }
        .clean { color: #4ade80; }
        .dirty { color: #f87171; }
        .synced { color: #4ade80; }
        .ahead { color: #facc15; }
        .behind { color: #f87171; }
        .no-git { color: #666; font-style: italic; }
        .local-only { color: #60a5fa; }
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
    </style>
</head>
<body>
<div class="container">
HTMLHEAD

# Header
echo "<header>" >> "$OUTPUT_FILE"
echo "<h1>Projects Dashboard</h1>" >> "$OUTPUT_FILE"
echo "<div class=\"subtitle\">$(date '+%Y-%m-%d %H:%M') &bull; $WORKSPACE</div>" >> "$OUTPUT_FILE"
echo "</header>" >> "$OUTPUT_FILE"

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
    echo "</div>" >> "$OUTPUT_FILE"
    echo "<table><thead><tr>" >> "$OUTPUT_FILE"
    echo "<th>Project</th><th>Type</th><th>Last Activity</th><th>Status</th><th>Remote</th><th>Files</th>" >> "$OUTPUT_FILE"
    echo "</tr></thead><tbody>" >> "$OUTPUT_FILE"

    for row in "${projects[@]}"; do
        IFS='|' read -r project type last_activity uncommit remote files is_git <<< "$row"

        # Determine classes
        uncommit_class="clean"
        [[ "$uncommit" == *"files"* ]] && uncommit_class="dirty"
        [[ "$uncommit" == "-" ]] && uncommit_class="no-git"

        remote_class="synced"
        [[ "$remote" == *"ahead"* ]] && remote_class="ahead"
        [[ "$remote" == *"behind"* ]] && remote_class="behind"
        [[ "$remote" == "local only" ]] && remote_class="local-only"
        [[ "$remote" == "-" ]] && remote_class="no-git"

        # Badge for git vs folder
        if [ "$is_git" = "true" ]; then
            badge="<span class=\"git-badge git\">git</span>"
        else
            badge="<span class=\"git-badge folder\">folder</span>"
        fi

        echo "<tr>" >> "$OUTPUT_FILE"
        echo "<td class=\"project-name\">$project $badge</td>" >> "$OUTPUT_FILE"
        echo "<td class=\"type\">$type</td>" >> "$OUTPUT_FILE"
        echo "<td>$last_activity</td>" >> "$OUTPUT_FILE"
        echo "<td class=\"$uncommit_class\">$uncommit</td>" >> "$OUTPUT_FILE"
        echo "<td class=\"$remote_class\">$remote</td>" >> "$OUTPUT_FILE"
        echo "<td>$files</td>" >> "$OUTPUT_FILE"
        echo "</tr>" >> "$OUTPUT_FILE"
    done

    echo "</tbody></table></div>" >> "$OUTPUT_FILE"
}

# Output sections
output_section "active" "Active" "Activity within 7 days" "${ACTIVE_PROJECTS[@]}"
output_section "recent" "Recent" "Activity 8-30 days" "${RECENT_PROJECTS[@]}"
output_section "idle" "Idle" "Activity 31-90 days" "${IDLE_PROJECTS[@]}"
output_section "dormant" "Dormant" "Activity >90 days" "${DORMANT_PROJECTS[@]}"

# Summary
total=$((${#ACTIVE_PROJECTS[@]} + ${#RECENT_PROJECTS[@]} + ${#IDLE_PROJECTS[@]} + ${#DORMANT_PROJECTS[@]}))
cat >> "$OUTPUT_FILE" << SUMMARY
<div class="summary">
    <div class="summary-item active"><div class="num">${#ACTIVE_PROJECTS[@]}</div><div class="label">Active</div></div>
    <div class="summary-item recent"><div class="num">${#RECENT_PROJECTS[@]}</div><div class="label">Recent</div></div>
    <div class="summary-item idle"><div class="num">${#IDLE_PROJECTS[@]}</div><div class="label">Idle</div></div>
    <div class="summary-item dormant"><div class="num">${#DORMANT_PROJECTS[@]}</div><div class="label">Dormant</div></div>
    <div class="summary-item"><div class="num">$total</div><div class="label">Total</div></div>
</div>
</div>
</body>
</html>
SUMMARY

echo "Dashboard generated: $OUTPUT_FILE"

# Open in browser (macOS)
if command -v open &> /dev/null; then
    open "$OUTPUT_FILE"
# Linux
elif command -v xdg-open &> /dev/null; then
    xdg-open "$OUTPUT_FILE"
fi
