#!/bin/bash
# Comprehensive triage download script
# Downloads artifacts for a GitHub issue and sets up the workspace
#
# Usage: triage-download.sh <issue-number-or-url>
# Example: triage-download.sh 157102
# Example: triage-download.sh https://github.com/cockroachdb/cockroach/issues/157102

# Only set strict mode when running directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the helper functions
source "$SCRIPT_DIR/triage-helpers.sh"

# Main download function
triage_download() {
    local input="$1"

    log_info "Starting triage download for: $input"

    # Parse the GitHub issue (capture only JSON output)
    local metadata_json
    local temp_output
    temp_output=$(parse_github_issue "$input" 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Failed to parse GitHub issue"
        return 1
    fi

    # Extract just the JSON part (between { and })
    metadata_json=$(echo "$temp_output" | grep -A 100 "^{" | grep -B 100 "^}" | sed -n '/^{/,/^}/p')

    # Extract fields from JSON
    local issue_num
    issue_num=$(echo "$metadata_json" | jq -r '.number')
    local download_url
    download_url=$(echo "$metadata_json" | jq -r '.download_url')
    local test_name
    test_name=$(echo "$metadata_json" | jq -r '.test_name')
    local sha
    sha=$(echo "$metadata_json" | jq -r '.sha')

    log_info "Issue #$issue_num: $test_name"

    # Set up workspace directory (absolute path from project root)
    local workspace_dir="$PROJECT_ROOT/workspace/issues/$issue_num"

    log_info "Workspace: $workspace_dir"

    # Check if artifacts already exist
    if [[ -d "$workspace_dir" ]] && [[ $(find "$workspace_dir" -type f 2>/dev/null | wc -l) -gt 0 ]]; then
        log_success "Artifacts already exist in workspace/issues/$issue_num"
        log_info "Workspace path: $workspace_dir"

        # Show what's available
        local file_count
        file_count=$(find "$workspace_dir" -type f | wc -l)
        log_info "Total files: $file_count"

        # Find test.log
        local test_log
        test_log=$(find "$workspace_dir" -name "test.log" -type f | head -1)
        if [[ -n "$test_log" ]]; then
            log_info "test.log: ${test_log#$PROJECT_ROOT/}"
        fi

        # Check for debug directory
        if [[ -d "$workspace_dir/debug" ]]; then
            local debug_count
            debug_count=$(find "$workspace_dir/debug" -type f | wc -l)
            log_info "debug.zip extracted: $debug_count files in debug/"
        fi

        echo ""
        echo "To navigate to workspace:"
        echo "  cd workspace/issues/$issue_num"
        echo ""

        # Checkout source code if we have a SHA
        if [[ -n "$sha" && "$sha" != "null" ]]; then
            echo ""
            log_info "Checking out source code at SHA: $sha"
            checkout_source_code "$sha" "cockroachdb" || true
            echo ""
        fi

        return 0
    fi

    # Download artifacts
    log_info "Downloading artifacts..."
    download_artifacts "$download_url" "$workspace_dir"

    if [[ $? -ne 0 ]]; then
        log_error "Failed to download artifacts"
        return 1
    fi

    # Show summary
    echo ""
    log_success "✓ Triage workspace ready!"
    echo ""
    echo "Issue: #$issue_num"
    echo "Workspace: workspace/issues/$issue_num"
    echo ""

    # Find test.log
    local test_log
    test_log=$(find "$workspace_dir" -name "test.log" -type f | head -1)
    if [[ -n "$test_log" ]]; then
        echo "test.log: ${test_log#$PROJECT_ROOT/}"
    fi

    # Show file counts
    local file_count
    file_count=$(find "$workspace_dir" -type f | wc -l)
    echo "Total files: $file_count"

    if [[ -d "$workspace_dir/debug" ]]; then
        local debug_count
        debug_count=$(find "$workspace_dir/debug" -type f | wc -l)
        echo "debug/ files: $debug_count"
    fi

    echo ""
    echo "To navigate to workspace:"
    echo "  cd workspace/issues/$issue_num"
    echo ""

    # Save metadata for easy reference
    echo "$metadata_json" > "$workspace_dir/metadata.json"
    log_info "Saved metadata to workspace/issues/$issue_num/metadata.json"

    # Checkout source code if we have a SHA
    if [[ -n "$sha" && "$sha" != "null" ]]; then
        echo ""
        log_info "Checking out source code at SHA: $sha"
        checkout_source_code "$sha" "cockroachdb" || true
        echo ""
    fi

    return 0
}

# Main entry point
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <github-issue-url-or-number>"
    echo ""
    echo "Examples:"
    echo "  $0 157102"
    echo "  $0 https://github.com/cockroachdb/cockroach/issues/157102"
    exit 1
fi

# Run the download
triage_download "$1"
