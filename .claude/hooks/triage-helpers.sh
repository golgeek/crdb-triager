#!/bin/bash
# Triage helper functions for CockroachDB roachtest issues
#
# This script provides utilities for:
# - Parsing GitHub issues to extract test failure metadata
# - Downloading artifacts from TeamCity
# - Extracting and organizing test logs
#
# Requirements:
# - gh (GitHub CLI)
# - jq (JSON processor)
# - curl
# - unzip
#
# Environment variables:
# - TEAMCITY_TOKEN: TeamCity authentication token
# - IAP_TOKEN: (Optional) Identity-Aware Proxy token for Prometheus/Grafana access
#              If not set, will attempt to generate using gcloud

# Only set strict mode when running directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper function for colored output
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Extract issue number from GitHub URL or issue number string
# Usage: extract_issue_number "https://github.com/cockroachdb/cockroach/issues/12345"
#        extract_issue_number "#12345"
#        extract_issue_number "12345"
extract_issue_number() {
    local input="$1"

    # Strip any leading # or "issue" prefix
    input="${input#\#}"
    input="${input#issue }"

    # Extract number from URL or plain number
    if [[ "$input" =~ github\.com.*issues/([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
    else
        log_error "Could not extract issue number from: $input"
        return 1
    fi
}

# Parse GitHub issue and extract all relevant metadata
# Usage: parse_github_issue "https://github.com/cockroachdb/cockroach/issues/12345"
#        parse_github_issue "12345"
# Output: JSON object with issue metadata
parse_github_issue() {
    local input="$1"
    local repo="${2:-cockroachdb/cockroach}"

    log_info "Parsing GitHub issue: $input"

    # Extract issue number
    local issue_num
    issue_num=$(extract_issue_number "$input")
    if [[ -z "$issue_num" ]]; then
        log_error "Failed to extract issue number"
        return 1
    fi

    log_info "Issue number: $issue_num"

    # Fetch issue and comments using gh CLI
    local tmp_file="/tmp/issue_${issue_num}.json"

    if ! gh issue view "$issue_num" \
        --repo "$repo" \
        --json title,body,number,comments,url > "$tmp_file" 2>/dev/null; then
        log_error "Failed to fetch issue from GitHub"
        return 1
    fi

    # Extract basic issue info
    local title
    title=$(jq -r '.title' "$tmp_file")
    local url
    url=$(jq -r '.url' "$tmp_file")
    local body
    body=$(jq -r '.body' "$tmp_file")

    log_info "Issue #$issue_num: $title"

    # Try to find the comment with artifacts (reverse order, newest first)
    local comment_body=""
    local num_comments
    num_comments=$(jq '.comments | length' "$tmp_file")

    log_info "Found $num_comments comments, searching for artifacts..."

    # Search comments in reverse order for "test artifacts and logs in:"
    for ((i=num_comments-1; i>=0; i--)); do
        local curr_body
        curr_body=$(jq -r ".comments[$i].body" "$tmp_file")

        if echo "$curr_body" | grep -q "test artifacts and logs in:"; then
            comment_body="$curr_body"
            log_info "Found artifacts in comment $((i+1))/$num_comments"
            break
        fi
    done

    # If no comment found, try the issue body
    if [[ -z "$comment_body" ]]; then
        if echo "$body" | grep -q "test artifacts and logs in:"; then
            comment_body="$body"
            log_info "Found artifacts in issue body"
        else
            log_error "No artifacts link found in issue or comments"
            return 1
        fi
    fi

    # Extract metadata using regex patterns
    local artifacts_url
    artifacts_url=$(echo "$comment_body" | grep -oE 'https://teamcity\.cockroachdb\.com/buildConfiguration/[^/]+/[0-9]+\?buildTab=artifacts#[^) ]+' | head -1)

    if [[ -z "$artifacts_url" ]]; then
        log_error "Could not extract TeamCity artifacts URL"
        return 1
    fi

    local release
    release=$(echo "$comment_body" | grep -oE 'release-[^,@ ]+' | head -1 | sed 's/release-//' || true)

    local sha
    sha=$(echo "$comment_body" | grep -oE '[a-f0-9]{40}' | head -1 || true)

    local test_path
    test_path=$(echo "$comment_body" | sed -n 's/.*test artifacts and logs in: *\([^ ]*\).*/\1/p' | head -1 | xargs || true)

    if [[ -z "$test_path" ]]; then
        log_error "Could not extract test path"
        log_error "Comment body preview:"
        echo "$comment_body" | head -20 >&2
        return 1
    fi

    local test_name
    test_name=$(echo "$comment_body" | grep -oE 'roachtest\.[^ \[]+' | head -1 | sed 's/roachtest\.//' || true)

    # Extract Grafana timestamps if available
    # Format: https://go.crdb.dev/roachtest-grafana/teamcity-20713915/test-name/START_TIMESTAMP/END_TIMESTAMP
    local start_timestamp=""
    local end_timestamp=""
    local grafana_url=""

    grafana_url=$(echo "$comment_body" | grep -oE 'https://go\.crdb\.dev/roachtest-grafana/[^)]+' | head -1 || true)
    if [[ -n "$grafana_url" ]]; then
        # Extract timestamps from Grafana URL
        if [[ "$grafana_url" =~ /([0-9]{13})/([0-9]{13})$ ]]; then
            start_timestamp="${BASH_REMATCH[1]}"
            end_timestamp="${BASH_REMATCH[2]}"
        fi
    fi

    # Construct download URL
    local download_url
    download_url=$(construct_download_url "$artifacts_url" "$test_path")

    # Output JSON
    cat <<EOF
{
  "number": $issue_num,
  "title": $(echo "$title" | jq -R .),
  "url": "$url",
  "test_name": $(echo "$test_name" | jq -R .),
  "release": $(echo "$release" | jq -R .),
  "sha": $(echo "$sha" | jq -R .),
  "test_path": $(echo "$test_path" | jq -R .),
  "artifacts_url": $(echo "$artifacts_url" | jq -R .),
  "download_url": $(echo "$download_url" | jq -R .),
  "grafana_url": $(echo "$grafana_url" | jq -R .),
  "start_timestamp": $(echo "$start_timestamp" | jq -R .),
  "end_timestamp": $(echo "$end_timestamp" | jq -R .)
}
EOF

    log_success "Successfully parsed issue #$issue_num"
}

# Construct TeamCity download URL from artifacts URL and test path
# Usage: construct_download_url "https://teamcity..." "/artifacts/path"
construct_download_url() {
    local artifacts_url="$1"
    local test_path="$2"

    # Extract build configuration and build ID
    if [[ "$artifacts_url" =~ buildConfiguration/([^/]+)/([0-9]+) ]]; then
        local build_config="${BASH_REMATCH[1]}"
        local build_id="${BASH_REMATCH[2]}"

        # Clean the test path
        local clean_path="${test_path#/artifacts/}"

        # URL encode the = character only (not slashes)
        clean_path="${clean_path//=/%3D}"

        echo "https://teamcity.cockroachdb.com/repository/download/${build_config}/${build_id}:id/${clean_path}/artifacts.zip"
    else
        log_error "Could not parse artifacts URL"
        return 1
    fi
}

# Download and extract artifacts from TeamCity
# Usage: download_artifacts "https://teamcity.cockroachdb.com/repository/download/..." [dest_dir]
# Downloads to current directory by default, or to dest_dir if provided
# Also tries to download debug.zip if available
download_artifacts() {
    local download_url="$1"
    local dest_dir="${2:-.}"  # Default to current directory

    log_info "Preparing to download artifacts from TeamCity ($download_url) to $dest_dir"

    if [[ -z "${TEAMCITY_TOKEN:-}" ]]; then
        log_error "TEAMCITY_TOKEN environment variable not set"
        log_info "Please set TEAMCITY_TOKEN with your TeamCity access token"
        return 1
    fi

    # Create destination directory
    mkdir -p "$dest_dir"

    # Check if artifacts already exist
    local file_count
    file_count=$(find "$dest_dir" -type f 2>/dev/null | wc -l | xargs)
    if [[ -d "$dest_dir" && $file_count -gt 0 ]]; then
        log_warn "Artifacts already exist in $dest_dir ($file_count files)"
        log_info "Skipping download. Delete the directory to re-download."
        return 0
    fi

    log_info "Downloading artifacts to: $dest_dir"

    local zip_file="${dest_dir}/artifacts.zip"

    # Download artifacts.zip with TeamCity authentication
    log_info "Downloading artifacts.zip from TeamCity..."
    local curl_error
    curl_error=$(curl -L -f -H "Authorization: Bearer $TEAMCITY_TOKEN" \
        "$download_url" -o "$zip_file" 2>&1)
    if [[ $? -ne 0 ]]; then
        log_error "Failed to download artifacts.zip"
        log_info "URL: $download_url"
        log_error "Curl error: $curl_error"
        return 1
    fi

    log_success "Downloaded artifacts.zip ($(du -h "$zip_file" | cut -f1))"

    # Extract artifacts
    log_info "Extracting artifacts.zip..."
    if ! unzip -q "$zip_file" -d "$dest_dir" 2>/dev/null; then
        log_error "Failed to extract artifacts"
        return 1
    fi

    # Remove the zip file to save space
    rm "$zip_file"

    # Try to download debug.zip if it exists
    local debug_url="${download_url/artifacts.zip/debug.zip}"
    local debug_dir="${dest_dir}/debug"
    local debug_zip="${dest_dir}/debug.zip"

    log_info "Checking for debug.zip..."
    local debug_error
    local debug_exit_code=0
    debug_error=$(curl -L -f -H "Authorization: Bearer $TEAMCITY_TOKEN" \
        "$debug_url" -o "$debug_zip" 2>&1) || debug_exit_code=$?
    if [[ $debug_exit_code -eq 0 ]]; then
        log_success "Found debug.zip ($(du -h "$debug_zip" | cut -f1))"

        # Extract debug.zip to separate directory
        mkdir -p "$debug_dir"
        log_info "Extracting debug.zip..."
        if unzip -q "$debug_zip" -d "$debug_dir" 2>/dev/null; then
            local debug_count
            debug_count=$(find "$debug_dir" -type f | wc -l | xargs)
            log_success "Extracted debug.zip ($debug_count files in debug/)"
        else
            log_warn "Failed to extract debug.zip"
        fi
        rm "$debug_zip"
    else
        log_info "No debug.zip available (this is normal)"
    fi

    log_success "Artifacts extracted to: $dest_dir"

    # List the extracted files
    file_count=$(find "$dest_dir" -type f | wc -l | xargs)
    log_info "Total: $file_count files extracted"
}

# Find test.log in a directory
# Usage: find_test_log "/path/to/artifacts"
find_test_log() {
    local search_dir="${1:-.}"

    find "$search_dir" -name "test.log" -type f
}

# Find all log files in a directory (test.log, *.journalctl.txt, *.dmesg.txt, etc.)
# Usage: find_all_logs "/path/to/artifacts"
find_all_logs() {
    local search_dir="${1:-.}"

    find "$search_dir" -type f \( \
        -name "test.log" -o \
        -name "*.journalctl.txt" -o \
        -name "*.dmesg.txt" -o \
        -name "*.log" \
    \) | sort
}

# Convert millisecond timestamp to human-readable date
# Usage: timestamp_to_date "1762605238000"
timestamp_to_date() {
    local timestamp_ms="$1"

    if [[ -z "$timestamp_ms" ]]; then
        echo ""
        return
    fi

    # Convert milliseconds to seconds
    local timestamp_sec=$((timestamp_ms / 1000))

    # Convert to human-readable format (macOS compatible)
    date -r "$timestamp_sec" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || echo "$timestamp_ms"
}

# Calculate test duration from start and end timestamps
# Usage: calculate_duration "1762605238000" "1762605993548"
calculate_duration() {
    local start_ms="$1"
    local end_ms="$2"

    if [[ -z "$start_ms" || -z "$end_ms" ]]; then
        echo ""
        return
    fi

    local duration_ms=$((end_ms - start_ms))
    local duration_sec=$((duration_ms / 1000))
    local duration_min=$((duration_sec / 60))
    local remaining_sec=$((duration_sec % 60))

    echo "${duration_min}m ${remaining_sec}s"
}

# Sanitize test name for Prometheus labels
# Replaces non-standard chars (/, =, etc.) with hyphens
# Usage: sanitize_test_name "tpcc-nowait/isolation-level=mixed/nodes=3/w=1"
# Output: "tpcc-nowait-isolation-level-mixed-nodes-3-w-1"
sanitize_test_name() {
    local test_name="$1"

    if [[ -z "$test_name" ]]; then
        echo ""
        return
    fi

    # Replace / and = with -
    echo "$test_name" | sed 's/[\/=]/-/g'
}

# Get IAP token for Prometheus/Grafana access
# Usage: get_iap_token
# Returns: IAP token (prints to stdout)
get_iap_token() {
    # If IAP_TOKEN is already set, use it
    if [[ -n "${IAP_TOKEN:-}" ]]; then
        echo "$IAP_TOKEN"
        return 0
    fi

    # Check if gcloud is available
    if ! command -v gcloud &>/dev/null; then
        log_error "gcloud CLI not found. Please install it or set IAP_TOKEN manually."
        return 1
    fi

    # Get current user's email
    local user_email
    user_email=$(gcloud config get-value account 2>/dev/null)
    if [[ -z "$user_email" ]]; then
        log_error "No gcloud account configured. Run: gcloud auth login"
        return 1
    fi

    # Generate IAP token
    local token
    token=$(gcloud auth print-identity-token "$user_email" \
        --impersonate-service-account=prom-helper-service@cockroach-testeng-infra.iam.gserviceaccount.com \
        --audiences=1063333028845-p47csl1ukrgnpnnjc7lrtrto6uqs9t37.apps.googleusercontent.com \
        --include-email 2>/dev/null)

    if [[ -z "$token" ]]; then
        log_error "Failed to generate IAP token"
        log_info "Try running: gcloud auth login"
        return 1
    fi

    echo "$token"
    return 0
}

# Query Prometheus for metrics during test run
# Usage: query_prometheus "1762605238000" "1762605993548" "query"
# Example: query_prometheus "$start_ts" "$end_ts" "up{job=\"cockroachdb\"}"
query_prometheus() {
    local start_ms="$1"
    local end_ms="$2"
    local query="$3"

    if [[ -z "$start_ms" || -z "$end_ms" || -z "$query" ]]; then
        log_error "Usage: query_prometheus <start_ms> <end_ms> <query>"
        return 1
    fi

    # Get IAP token
    local token
    token=$(get_iap_token)
    if [[ $? -ne 0 ]]; then
        log_error "Failed to get IAP token for Prometheus"
        return 1
    fi

    # Convert milliseconds to seconds for Prometheus
    local start_sec=$((start_ms / 1000))
    local end_sec=$((end_ms / 1000))

    # Prometheus range query endpoint (via Grafana)
    local prom_url="https://grafana.testeng.crdb.io/prometheus/api/v1/query_range"

    # Calculate step (1 data point per minute)
    local duration_sec=$((end_sec - start_sec))
    local step=60
    if [[ $duration_sec -lt 300 ]]; then
        # For short tests, use 10 second intervals
        step=10
    fi

    # Query Prometheus
    local response
    response=$(curl -s -H "Authorization: Bearer $token" -G \
        --data-urlencode "query=$query" \
        --data-urlencode "start=$start_sec" \
        --data-urlencode "end=$end_sec" \
        --data-urlencode "step=$step" \
        "$prom_url" 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Failed to query Prometheus: $response"
        return 1
    fi

    # Check for errors in response
    local status
    status=$(echo "$response" | jq -r '.status' 2>/dev/null)
    if [[ "$status" != "success" ]]; then
        log_error "Prometheus query failed"
        echo "$response" | jq -r '.error' 2>/dev/null || echo "$response"
        return 1
    fi

    # Return the response
    echo "$response"
    return 0
}

# Create a git worktree for a specific issue at a specific SHA
# This allows parallel triage of multiple issues, each with their own source tree
# Usage: create_source_worktree "f0bfb1cb00838ff45a508e4f1eba087e9835a674" "160863"
create_source_worktree() {
    local sha="$1"
    local issue_num="$2"

    if [[ -z "$sha" ]]; then
        log_error "No SHA provided"
        return 1
    fi

    if [[ -z "$issue_num" ]]; then
        log_error "No issue number provided"
        return 1
    fi

    # Get project root
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(cd "$script_dir/../.." && pwd)"
    local bare_repo="$project_root/cockroachdb.git"
    local worktree_path="$project_root/workspace/issues/$issue_num/cockroachdb"

    # Check if worktree already exists
    if [[ -d "$worktree_path/.git" ]] || [[ -f "$worktree_path/.git" ]]; then
        # Check if it's at the right SHA
        local current_sha
        current_sha=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null || echo "")
        if [[ "$current_sha" == "$sha"* ]]; then
            log_success "Worktree already exists at correct SHA"
            log_info "Source code: workspace/issues/$issue_num/cockroachdb/"
            return 0
        else
            log_info "Worktree exists but at different SHA, updating..."
            git -C "$worktree_path" checkout "$sha" 2>/dev/null || {
                # Need to fetch first
                git -C "$bare_repo" fetch origin "$sha" --depth 1 2>/dev/null || true
                git -C "$worktree_path" checkout "$sha" 2>/dev/null
            }
            if [[ $? -eq 0 ]]; then
                log_success "Updated worktree to SHA: $sha"
                return 0
            fi
        fi
    fi

    # Initialize bare clone if it doesn't exist
    if [[ ! -d "$bare_repo" ]]; then
        log_info "Initializing CockroachDB bare clone (one-time setup)..."
        log_info "This may take a few minutes..."
        if ! git clone --bare --filter=blob:none https://github.com/cockroachdb/cockroach.git "$bare_repo" 2>&1; then
            log_error "Failed to clone CockroachDB repository"
            return 1
        fi
        log_success "Bare clone created at cockroachdb.git/"
    fi

    log_info "Creating worktree for issue #$issue_num at SHA: $sha"

    # Fetch the SHA if needed
    (
        cd "$bare_repo" || return 1

        # Check if we already have this SHA
        if git cat-file -e "$sha^{commit}" 2>/dev/null; then
            log_info "SHA already available locally"
        else
            log_info "Fetching SHA from origin..."
            # Try fetching the specific SHA first (works for recent commits)
            if ! git fetch origin "$sha" --depth 1 2>/dev/null; then
                log_info "Fetching from master branch..."
                git fetch origin master 2>/dev/null || git fetch origin
            fi

            # Verify we have it now
            if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
                log_error "Could not fetch SHA: $sha"
                return 1
            fi
        fi
    )

    if [[ $? -ne 0 ]]; then
        return 1
    fi

    # Create the worktree
    # Note: git worktree add needs the path relative to bare repo or absolute
    if git -C "$bare_repo" worktree add "$worktree_path" "$sha" 2>&1; then
        log_success "Created worktree at: workspace/issues/$issue_num/cockroachdb/"
        log_info "Test code: workspace/issues/$issue_num/cockroachdb/pkg/cmd/roachtest/tests/"
        log_info "Full CRDB source: workspace/issues/$issue_num/cockroachdb/pkg/"
        return 0
    else
        log_error "Failed to create worktree"
        return 1
    fi
}

# Remove a git worktree for an issue (cleanup)
# Usage: remove_source_worktree "160863"
remove_source_worktree() {
    local issue_num="$1"

    if [[ -z "$issue_num" ]]; then
        log_error "No issue number provided"
        return 1
    fi

    # Get project root
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(cd "$script_dir/../.." && pwd)"
    local bare_repo="$project_root/cockroachdb.git"
    local worktree_path="$project_root/workspace/issues/$issue_num/cockroachdb"

    if [[ ! -d "$worktree_path" ]]; then
        log_info "No worktree found for issue #$issue_num"
        return 0
    fi

    log_info "Removing worktree for issue #$issue_num..."

    if git -C "$bare_repo" worktree remove "$worktree_path" --force 2>&1; then
        log_success "Removed worktree for issue #$issue_num"
        return 0
    else
        log_warn "Could not remove worktree cleanly, forcing removal..."
        rm -rf "$worktree_path"
        git -C "$bare_repo" worktree prune 2>/dev/null || true
        return 0
    fi
}

# List all active worktrees
# Usage: list_source_worktrees
list_source_worktrees() {
    # Get project root
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(cd "$script_dir/../.." && pwd)"
    local bare_repo="$project_root/cockroachdb.git"

    if [[ ! -d "$bare_repo" ]]; then
        log_info "No CockroachDB clone found"
        return 0
    fi

    log_info "Active worktrees:"
    git -C "$bare_repo" worktree list
}

# DEPRECATED: Use create_source_worktree instead
# Kept for backwards compatibility
checkout_source_code() {
    local sha="$1"
    local cockroach_dir="${2:-cockroachdb}"

    log_warn "checkout_source_code is deprecated. Use create_source_worktree instead."

    if [[ -z "$sha" ]]; then
        log_error "No SHA provided"
        return 1
    fi

    # Get project root (where cockroachdb submodule is)
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(cd "$script_dir/../.." && pwd)"
    local repo_path="$project_root/$cockroach_dir"

    if [[ ! -d "$repo_path" ]]; then
        log_error "CockroachDB repository not found at $repo_path"
        log_info "Run: git submodule update --init"
        return 1
    fi

    log_info "Checking out SHA: $sha"

    # Navigate to repo and fetch/checkout
    (
        cd "$repo_path" || return 1

        # Check if we already have this SHA
        if git cat-file -e "$sha^{commit}" 2>/dev/null; then
            log_info "SHA already available locally"
        else
            log_info "Fetching recent commits from origin..."
            # For recent issues, fetch latest commits from master
            if ! git fetch origin master 2>/dev/null; then
                log_warn "Could not fetch from origin, trying full fetch..."
                git fetch --unshallow 2>/dev/null || git fetch origin
            fi

            # Try again to see if we have the SHA now
            if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
                log_info "SHA still not found, trying specific fetch..."
                if ! git fetch origin "$sha" --depth 1 2>/dev/null; then
                    log_error "Could not fetch SHA: $sha"
                    return 1
                fi
            fi
        fi

        # Checkout the SHA (suppress git's informational messages)
        if git checkout "$sha" 2>/dev/null; then
            log_success "Checked out SHA: $sha"
        else
            log_error "Failed to checkout SHA: $sha"
            return 1
        fi
    )

    if [[ $? -eq 0 ]]; then
        log_info "Test code: $cockroach_dir/pkg/cmd/roachtest/tests/"
        log_info "Full CRDB source: $cockroach_dir/pkg/"
        return 0
    else
        return 1
    fi
}

# Restore source code to master branch
# Usage: restore_source_code
restore_source_code() {
    local cockroach_dir="${1:-cockroachdb}"

    # Find the git root directory (more reliable than BASH_SOURCE when sourced)
    local repo_path
    if git rev-parse --show-toplevel &>/dev/null; then
        # We're in a git repo, find the project root
        local git_root
        git_root="$(git rev-parse --show-toplevel)"
        repo_path="$git_root/$cockroach_dir"
    else
        log_error "Not in a git repository"
        return 1
    fi

    if [[ ! -d "$repo_path" ]]; then
        log_warn "CockroachDB repository not found at $repo_path"
        return 0
    fi

    log_info "Restoring submodule to master branch"

    # Navigate to repo and checkout master
    (
        cd "$repo_path" || return 1

        # Checkout master branch (suppress git's informational messages)
        if git checkout -q master 2>/dev/null; then
            log_success "Restored submodule to master"
        else
            log_warn "Could not restore to master (this is okay)"
        fi
    )

    return 0
}

# Extract and save common metrics for triage analysis
# Usage: extract_metrics <issue_num>
# Saves metrics to workspace/issues/$ISSUE_NUM/extracted-metrics.json
extract_metrics() {
    local issue_num="$1"

    # Get project root
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(cd "$script_dir/../.." && pwd)"
    local workspace_dir="$project_root/workspace/issues/$issue_num"
    local metadata_file="$workspace_dir/metadata.json"
    local metrics_file="$workspace_dir/extracted-metrics.json"

    if [[ ! -f "$metadata_file" ]]; then
        log_error "Metadata file not found: $metadata_file"
        return 1
    fi

    log_info "Extracting metrics for issue #$issue_num..."

    # Extract metadata
    local start_ts end_ts grafana_url test_name
    start_ts=$(jq -r '.start_timestamp' "$metadata_file")
    end_ts=$(jq -r '.end_timestamp' "$metadata_file")
    grafana_url=$(jq -r '.grafana_url' "$metadata_file")
    test_name=$(jq -r '.test_name' "$metadata_file")

    # Check if timestamps are available
    if [[ -z "$start_ts" || "$start_ts" == "null" || -z "$end_ts" || "$end_ts" == "null" ]]; then
        log_warn "No timestamps found - metrics not available for this test"
        # Create empty metrics file
        echo '{"error": "No timestamps available", "metrics_available": false}' > "$metrics_file"
        return 0
    fi

    # Extract test_run_id from Grafana URL
    local test_run_id
    if [[ "$grafana_url" =~ teamcity-([0-9]+) ]]; then
        test_run_id="teamcity-${BASH_REMATCH[1]}"
    else
        log_warn "Could not extract test_run_id from Grafana URL"
        echo '{"error": "No test_run_id found", "metrics_available": false}' > "$metrics_file"
        return 0
    fi

    # Sanitize test name for Prometheus labels
    local sanitized_test_name
    sanitized_test_name=$(sanitize_test_name "$test_name")

    log_info "Fetching metrics from Prometheus..."
    log_info "  Test run: $test_run_id"
    log_info "  Test name: $sanitized_test_name"
    log_info "  Time range: $(timestamp_to_date "$start_ts") to $(timestamp_to_date "$end_ts")"

    # Try to find cluster name
    local cluster=""
    local cluster_query="sys_uptime{job=\"cockroachdb\", test_run_id=\"$test_run_id\", test_name=\"$sanitized_test_name\"}"
    local cluster_response
    cluster_response=$(query_prometheus "$start_ts" "$end_ts" "$cluster_query" 2>&1)
    if [[ $? -eq 0 ]]; then
        cluster=$(echo "$cluster_response" | jq -r '.data.result[0].metric.cluster' 2>/dev/null)
        if [[ -z "$cluster" || "$cluster" == "null" ]]; then
            log_warn "No cluster found in Prometheus - metrics may not be available"
            echo "{\"error\": \"No cluster found\", \"metrics_available\": false, \"test_run_id\": \"$test_run_id\"}" > "$metrics_file"
            return 0
        fi
        log_info "  Cluster: $cluster"
    else
        log_warn "Failed to query Prometheus for cluster name"
        echo "{\"error\": \"Prometheus query failed\", \"metrics_available\": false}" > "$metrics_file"
        return 0
    fi

    # Initialize metrics object
    local metrics_json='{
        "metrics_available": true,
        "test_run_id": "'$test_run_id'",
        "cluster": "'$cluster'",
        "start_timestamp": "'$start_ts'",
        "end_timestamp": "'$end_ts'",
        "duration_seconds": '$((($end_ts - $start_ts) / 1000))',
        "metrics": {}
    }'

    # Query 1: Memory usage (RSS) - for detecting OOM
    log_info "  Querying memory usage..."
    local mem_query="sys_rss{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
    local mem_response
    mem_response=$(query_prometheus "$start_ts" "$end_ts" "$mem_query" 2>&1)
    if [[ $? -eq 0 ]]; then
        # Extract max RSS per node
        metrics_json=$(echo "$metrics_json" | jq --argjson mem "$mem_response" '.metrics.memory_rss = $mem.data.result | map({node: .metric.instance, max_bytes: (.values | map(.[1] | tonumber) | max), values: .values})')
    fi

    # Query 2: Disk space available - for detecting disk full
    log_info "  Querying disk space..."
    local disk_query="node_filesystem_avail_bytes{job=\"node\",test_run_id=\"$test_run_id\",cluster=\"$cluster\",mountpoint=\"/\"}"
    local disk_response
    disk_response=$(query_prometheus "$start_ts" "$end_ts" "$disk_query" 2>&1)
    if [[ $? -eq 0 ]]; then
        # Extract min available space per node
        metrics_json=$(echo "$metrics_json" | jq --argjson disk "$disk_response" '.metrics.disk_available = $disk.data.result | map({node: .metric.instance, min_bytes: (.values | map(.[1] | tonumber) | min), values: .values})')
    fi

    # Query 3: CPU usage - for detecting CPU starvation
    log_info "  Querying CPU usage..."
    local cpu_query="sys_cpu_combined_percent_normalized{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
    local cpu_response
    cpu_response=$(query_prometheus "$start_ts" "$end_ts" "$cpu_query" 2>&1)
    if [[ $? -eq 0 ]]; then
        metrics_json=$(echo "$metrics_json" | jq --argjson cpu "$cpu_response" '.metrics.cpu_usage = $cpu.data.result | map({node: .metric.instance, max_percent: (.values | map(.[1] | tonumber) | max), values: .values})')
    fi

    # Query 4: Goroutine count - for detecting goroutine leaks
    log_info "  Querying goroutine count..."
    local goroutine_query="go_goroutines{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
    local goroutine_response
    goroutine_response=$(query_prometheus "$start_ts" "$end_ts" "$goroutine_query" 2>&1)
    if [[ $? -eq 0 ]]; then
        metrics_json=$(echo "$metrics_json" | jq --argjson gor "$goroutine_response" '.metrics.goroutines = $gor.data.result | map({node: .metric.instance, max_count: (.values | map(.[1] | tonumber) | max), values: .values})')
    fi

    # Query 5: Node liveness - for detecting node crashes
    log_info "  Querying node liveness..."
    local liveness_query="liveness_livenodes{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
    local liveness_response
    liveness_response=$(query_prometheus "$start_ts" "$end_ts" "$liveness_query" 2>&1)
    if [[ $? -eq 0 ]]; then
        metrics_json=$(echo "$metrics_json" | jq --argjson live "$liveness_response" '.metrics.liveness = $live.data.result | map({node: .metric.instance, min_live_nodes: (.values | map(.[1] | tonumber) | min), values: .values})')
    fi

    # Add analysis hints
    metrics_json=$(echo "$metrics_json" | jq '. + {
        "analysis_hints": {
            "oom_detected": (.metrics.memory_rss // [] | map(select(.max_bytes > 30000000000)) | length > 0),
            "disk_full_detected": (.metrics.disk_available // [] | map(select(.min_bytes < 1000000000)) | length > 0),
            "high_cpu_detected": (.metrics.cpu_usage // [] | map(select(.max_percent > 95)) | length > 0),
            "goroutine_leak_detected": (.metrics.goroutines // [] | map(select(.max_count > 50000)) | length > 0)
        }
    }')

    # Save to file
    echo "$metrics_json" | jq '.' > "$metrics_file"

    if [[ $? -eq 0 ]]; then
        log_success "Metrics extracted to: workspace/issues/$issue_num/extracted-metrics.json"

        # Show analysis hints
        local oom=$(echo "$metrics_json" | jq -r '.analysis_hints.oom_detected')
        local disk=$(echo "$metrics_json" | jq -r '.analysis_hints.disk_full_detected')
        local cpu=$(echo "$metrics_json" | jq -r '.analysis_hints.high_cpu_detected')
        local goroutines=$(echo "$metrics_json" | jq -r '.analysis_hints.goroutine_leak_detected')

        echo ""
        log_info "Quick Analysis:"
        [[ "$oom" == "true" ]] && log_warn "  ⚠ High memory usage detected (possible OOM)"
        [[ "$disk" == "true" ]] && log_warn "  ⚠ Low disk space detected (possible disk full)"
        [[ "$cpu" == "true" ]] && log_warn "  ⚠ High CPU usage detected"
        [[ "$goroutines" == "true" ]] && log_warn "  ⚠ High goroutine count detected (possible leak)"

        if [[ "$oom" == "false" && "$disk" == "false" && "$cpu" == "false" && "$goroutines" == "false" ]]; then
            log_success "  ✓ No obvious infrastructure issues detected in metrics"
        fi
        echo ""

        return 0
    else
        log_error "Failed to save metrics"
        return 1
    fi
}

# Write triage summary to TRIAGE.md
# Usage: write_triage_summary <issue_num> <classification> <confidence> <summary> <evidence> [team]
write_triage_summary() {
    local issue_num="$1"
    local classification="$2"
    local confidence="$3"
    local summary="$4"
    local evidence="$5"
    local team="${6:-unknown}"

    # Get project root
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(cd "$script_dir/../.." && pwd)"
    local workspace_dir="$project_root/workspace/issues/$issue_num"
    local triage_file="$workspace_dir/TRIAGE.md"

    if [[ ! -d "$workspace_dir" ]]; then
        log_error "Workspace directory not found: $workspace_dir"
        return 1
    fi

    log_info "Writing triage summary to TRIAGE.md"

    # Get current date
    local date
    date=$(date "+%Y-%m-%d %H:%M:%S %Z")

    # Write the summary
    cat > "$triage_file" <<EOF
# Triage Summary - Issue #${issue_num}

**Date:** ${date}
**Classification:** ${classification}
**Confidence:** ${confidence}
**Recommended Team:** ${team}

## Summary

${summary}

## Evidence

${evidence}

---
*Generated by Claude Code Triage System*
EOF

    if [[ $? -eq 0 ]]; then
        log_success "Triage summary written to: workspace/issues/$issue_num/TRIAGE.md"
        return 0
    else
        log_error "Failed to write triage summary"
        return 1
    fi
}

# Main function for quick testing
# Usage: ./triage-helpers.sh "https://github.com/cockroachdb/cockroach/issues/12345"
main() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 <github-issue-url-or-number>"
        echo ""
        echo "Examples:"
        echo "  $0 https://github.com/cockroachdb/cockroach/issues/12345"
        echo "  $0 12345"
        echo "  $0 '#12345'"
        exit 1
    fi

    parse_github_issue "$1"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
