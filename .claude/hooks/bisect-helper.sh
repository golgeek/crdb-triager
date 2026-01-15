#!/bin/bash
# Helper script for bisecting test failures
#
# This script helps you bisect between the last successful run and the current failure
# to identify which commit introduced the bug.
#
# Usage:
#   ./bisect-helper.sh <issue-number>
#
# Prerequisites:
#   - Run triage-download.sh first to set up the workspace and download bisect-info.json
#   - Snowflake must be configured to get bisect information

set -euo pipefail

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the helper functions
source "$SCRIPT_DIR/triage-helpers.sh"
source "$SCRIPT_DIR/snowflake-helpers.sh"

# Main bisect helper function
bisect_helper() {
    local issue_num="$1"

    log_info "Bisect Helper for Issue #$issue_num"
    echo ""

    # Check if workspace exists
    local workspace_dir="$PROJECT_ROOT/workspace/issues/$issue_num"
    if [[ ! -d "$workspace_dir" ]]; then
        log_error "Workspace not found for issue #$issue_num"
        log_info "Run: bash .claude/hooks/triage-download.sh $issue_num"
        return 1
    fi

    # Check if bisect-info.json exists
    local bisect_file="$workspace_dir/bisect-info.json"
    if [[ ! -f "$bisect_file" ]]; then
        log_error "Bisect information not found"
        log_info "This might mean:"
        log_info "  1. Snowflake is not configured"
        log_info "  2. No successful run was found in test history"
        log_info "  3. The test has never passed on this branch"
        echo ""
        log_info "To manually specify bisect range:"
        log_info "  cd cockroachdb"
        log_info "  git bisect start <bad-sha> <good-sha>"
        return 1
    fi

    # Load bisect information
    local last_success_sha failure_sha commit_count test_name first_failure_sha
    last_success_sha=$(jq -r '.last_success_sha' "$bisect_file")
    failure_sha=$(jq -r '.failure_sha' "$bisect_file")
    commit_count=$(jq -r '.commit_count' "$bisect_file")
    test_name=$(jq -r '.test_name' "$bisect_file")
    first_failure_sha=$(jq -r '.first_failure_sha // empty' "$bisect_file")

    echo "Bisect Range Information:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test: $test_name"
    echo "Last success: $last_success_sha"
    echo "Current failure: $failure_sha"
    echo "Commits to bisect: $commit_count"

    if [[ -n "$first_failure_sha" ]]; then
        log_success "First failure found in test history: $first_failure_sha"
        echo ""
        log_info "This means you may not need to bisect!"
        log_info "The regression was likely introduced in commit: $first_failure_sha"
        echo ""
        log_info "To view the diff:"
        echo "  cd cockroachdb"
        echo "  git show $first_failure_sha"
        echo ""
        log_info "To see what changed between last success and first failure:"
        echo "  cd cockroachdb"
        echo "  git log --oneline $last_success_sha..$first_failure_sha"
        echo "  git diff $last_success_sha..$first_failure_sha"
    else
        echo ""
        log_warn "First failure not found in test history"
        log_info "You'll need to run a manual bisect"
        echo ""

        if [[ $commit_count -lt 10 ]]; then
            log_info "Only $commit_count commits in range - you can manually check each one:"
            echo ""
            echo "  cd cockroachdb"
            echo "  git log --oneline --reverse $last_success_sha..$failure_sha"
            echo ""
        else
            log_info "Running git bisect (will take ~${commit_count} iterations)"
            echo ""
            echo "To start git bisect:"
            echo "  cd cockroachdb"
            echo "  git bisect start $failure_sha $last_success_sha"
            echo "  # Git will checkout a commit in the middle"
            echo "  # Run the test manually or check test results in Snowflake"
            echo "  git bisect good   # if test passes"
            echo "  git bisect bad    # if test fails"
            echo "  # Repeat until git identifies the first bad commit"
            echo "  git bisect reset  # when done"
            echo ""
        fi
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show commits in range
    log_info "Commits in bisect range:"
    echo ""

    local cockroach_dir="$PROJECT_ROOT/cockroachdb"
    cd "$cockroach_dir"

    # Show compact log
    git log --oneline --reverse "$last_success_sha..$failure_sha" | head -20

    if [[ $commit_count -gt 20 ]]; then
        echo "..."
        echo "(showing first 20 of $commit_count commits)"
    fi

    echo ""

    # Suggest automated bisect if we have Snowflake data
    if [[ -z "$first_failure_sha" ]] && command -v snowsql &>/dev/null; then
        log_info "Want to automate the bisect using Snowflake test results?"
        echo ""
        echo "Run:"
        echo "  bash .claude/hooks/snowflake-helpers.sh find-first-failure \\"
        echo "    \"$test_name\" \\"
        echo "    \"$last_success_sha\" \\"
        echo "    \"$failure_sha\""
        echo ""
    fi

    return 0
}

# View diff between last success and failure
view_diff() {
    local issue_num="$1"

    local workspace_dir="$PROJECT_ROOT/workspace/issues/$issue_num"
    local bisect_file="$workspace_dir/bisect-info.json"

    if [[ ! -f "$bisect_file" ]]; then
        log_error "Bisect information not found"
        return 1
    fi

    local last_success_sha failure_sha first_failure_sha
    last_success_sha=$(jq -r '.last_success_sha' "$bisect_file")
    failure_sha=$(jq -r '.failure_sha' "$bisect_file")
    first_failure_sha=$(jq -r '.first_failure_sha // empty' "$bisect_file")

    local end_sha="$failure_sha"
    if [[ -n "$first_failure_sha" ]]; then
        log_info "Showing changes that introduced the failure"
        end_sha="$first_failure_sha"
    else
        log_info "Showing all changes in bisect range"
    fi

    local cockroach_dir="$PROJECT_ROOT/cockroachdb"
    cd "$cockroach_dir"

    echo ""
    echo "Commits:"
    git log --oneline "$last_success_sha..$end_sha"
    echo ""

    log_info "Showing diff (press 'q' to quit)..."
    sleep 1
    git diff "$last_success_sha..$end_sha" | less
}

# Main entry point
if [[ $# -eq 0 ]]; then
    cat <<EOF
Usage: $0 <command> <issue-number>

Commands:
  info <issue-number>     Show bisect information and instructions
  diff <issue-number>     View the diff between last success and failure

Examples:
  $0 info 157102
  $0 diff 157102

Prerequisites:
  Run 'bash .claude/hooks/triage-download.sh <issue-number>' first
EOF
    exit 1
fi

command="$1"
issue_num="$2"

case "$command" in
    info)
        bisect_helper "$issue_num"
        ;;
    diff)
        view_diff "$issue_num"
        ;;
    *)
        log_error "Unknown command: $command"
        log_info "Use 'info' or 'diff'"
        exit 1
        ;;
esac
