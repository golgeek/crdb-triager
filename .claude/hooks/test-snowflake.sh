#!/bin/bash
# Test script for Snowflake integration
# Usage: ./test-snowflake.sh <issue-number>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the helper functions
source "$SCRIPT_DIR/triage-helpers.sh"
source "$SCRIPT_DIR/snowflake-helpers.sh"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

test_snowflake() {
    local issue_num="${1:-}"

    if [[ -z "$issue_num" ]]; then
        cat <<EOF
Usage: $0 <issue-number>

This script tests the Snowflake integration by:
  1. Checking Snowflake CLI and credentials
  2. Loading test metadata from workspace
  3. Finding last successful run
  4. Getting test history
  5. Calculating bisect range
  6. Searching for first failure in history

Example:
  $0 157102

Prerequisites:
  - Run 'bash .claude/hooks/triage-download.sh <issue-number>' first
  - Snowflake credentials must be set:
    export SNOWFLAKE_ACCOUNT='your_account'
    export SNOWFLAKE_USER='your_username'
    export SNOWFLAKE_PASSWORD='your_pat_token'
  - snowsql CLI must be installed (brew install snowflake-snowsql)
EOF
        exit 1
    fi

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Testing Snowflake Integration for Issue #$issue_num${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Step 1: Check Snowflake CLI and credentials
    echo -e "${GREEN}Step 1: Checking Snowflake CLI and credentials${NC}"
    echo ""

    if ! command -v snowsql &>/dev/null; then
        log_error "snowsql CLI not found"
        echo ""
        echo "Install with:"
        echo "  brew install snowflake-snowsql"
        echo ""
        echo "Or download from:"
        echo "  https://docs.snowflake.com/en/user-guide/snowsql-install-config.html"
        exit 1
    fi
    log_success "snowsql CLI found: $(which snowsql)"

    if [[ -z "${SNOWFLAKE_ACCOUNT:-}" ]]; then
        log_error "SNOWFLAKE_ACCOUNT not set"
        echo ""
        echo "Set with:"
        echo "  export SNOWFLAKE_ACCOUNT='your_account'"
        exit 1
    fi
    log_success "SNOWFLAKE_ACCOUNT: $SNOWFLAKE_ACCOUNT"

    if [[ -z "${SNOWFLAKE_USER:-}" ]]; then
        log_error "SNOWFLAKE_USER not set"
        echo ""
        echo "Set with:"
        echo "  export SNOWFLAKE_USER='your_username'"
        exit 1
    fi
    log_success "SNOWFLAKE_USER: $SNOWFLAKE_USER"

    if [[ -z "${SNOWFLAKE_PASSWORD:-}" ]]; then
        log_error "SNOWFLAKE_PASSWORD not set"
        echo ""
        echo "Set with:"
        echo "  export SNOWFLAKE_PASSWORD='your_pat_token'"
        exit 1
    fi
    log_success "SNOWFLAKE_PASSWORD: [set]"

    echo ""
    log_info "Database: ${SNOWFLAKE_DATABASE:-DATAMART_PROD}"
    log_info "Schema: ${SNOWFLAKE_SCHEMA:-TEAMCITY}"
    log_info "Warehouse: ${SNOWFLAKE_WAREHOUSE:-COMPUTE_WH}"
    echo ""

    # Step 2: Check if metadata exists
    echo -e "${GREEN}Step 2: Loading test metadata${NC}"
    echo ""

    local metadata_file="$PROJECT_ROOT/workspace/issues/$issue_num/metadata.json"
    if [[ ! -f "$metadata_file" ]]; then
        log_error "Metadata file not found: $metadata_file"
        echo ""
        echo "Run this first:"
        echo "  bash .claude/hooks/triage-download.sh $issue_num"
        exit 1
    fi

    log_success "Metadata file found"

    # Extract metadata
    local test_name sha release branch_name
    test_name=$(jq -r '.test_name' "$metadata_file")
    sha=$(jq -r '.sha' "$metadata_file")
    release=$(jq -r '.release' "$metadata_file")

    # Construct branch name from release (e.g., "24.3" -> "release-24.3")
    if [[ -n "$release" && "$release" != "null" ]]; then
        branch_name="release-$release"
    else
        branch_name="master"
    fi

    echo ""
    echo "Test metadata:"
    echo "  Issue: #$issue_num"
    echo "  Test: $test_name"
    echo "  SHA: $sha"
    echo "  Release: $release"
    echo "  Branch: $branch_name"
    echo ""

    # Step 3: Test basic Snowflake connectivity
    echo -e "${GREEN}Step 3: Testing Snowflake connectivity${NC}"
    echo ""

    log_info "Running test query..."
    local test_query="SELECT CURRENT_TIMESTAMP() as now, CURRENT_USER() as user, CURRENT_DATABASE() as database"
    local test_result
    test_result=$(query_snowflake "$test_query" 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Snowflake connectivity test failed"
        echo ""
        echo "Error:"
        echo "$test_result"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Verify credentials are correct"
        echo "  2. Check account identifier format (e.g., 'xy12345.us-east-1')"
        echo "  3. Ensure PAT has necessary permissions"
        echo "  4. Try logging in manually: snowsql -a \$SNOWFLAKE_ACCOUNT -u \$SNOWFLAKE_USER"
        exit 1
    fi

    log_success "Snowflake connectivity test passed"
    echo ""
    echo "Connection details:"
    echo "$test_result" | jq '.[0]' 2>/dev/null || echo "$test_result"
    echo ""

    # Step 4: Find last successful run
    echo -e "${GREEN}Step 4: Finding last successful run${NC}"
    echo ""

    log_info "Searching for last success of: $test_name"
    if [[ -n "$branch_name" && "$branch_name" != "null" ]]; then
        log_info "Filtering by branch: $branch_name"
    fi

    local last_success
    last_success=$(find_last_success "$test_name" "$branch_name" 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Failed to find last successful run"
        echo ""
        echo "Error:"
        echo "$last_success"
        echo ""
        log_warn "This might mean:"
        echo "  - Test has never passed on this branch"
        echo "  - Test name format doesn't match Snowflake data"
        echo "  - No test runs in the last 90 days"
        echo ""
        echo "Trying without branch filter..."
        last_success=$(find_last_success "$test_name" "" 2>&1)

        if [[ $? -ne 0 ]]; then
            log_error "Still failed - test may not exist in Snowflake"
            exit 1
        fi
    fi

    log_success "Found last successful run"
    echo ""
    echo "Last success details:"
    echo "$last_success" | jq '.[0]' 2>/dev/null || echo "$last_success"
    echo ""

    local last_success_sha
    last_success_sha=$(echo "$last_success" | jq -r '.[0].sha // .[0].SHA' 2>/dev/null)
    local last_success_date
    last_success_date=$(echo "$last_success" | jq -r '.[0].start_date // .[0].START_DATE' 2>/dev/null)

    if [[ -z "$last_success_sha" || "$last_success_sha" == "null" ]]; then
        log_warn "No SHA found in last success result"
        echo ""
        echo "This might mean:"
        echo "  - SHAs are not stored in the BUILDS table"
        echo "  - SHA extraction logic needs adjustment"
        echo ""
        echo "Raw result:"
        echo "$last_success" | jq '.' 2>/dev/null || echo "$last_success"
    else
        log_info "Last success SHA: $last_success_sha"
        log_info "Last success date: $last_success_date"
    fi
    echo ""

    # Step 5: Get test history
    echo -e "${GREEN}Step 5: Getting test history${NC}"
    echo ""

    log_info "Fetching last 20 test runs..."
    local history
    history=$(get_test_history "$test_name" 20 "$branch_name" 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Failed to get test history"
        echo ""
        echo "Error:"
        echo "$history"
    else
        log_success "Retrieved test history"
        echo ""

        local run_count
        run_count=$(echo "$history" | jq 'length' 2>/dev/null || echo "0")
        echo "Found $run_count test runs"
        echo ""

        # Show summary
        echo "Recent test runs (last 10):"
        echo "$history" | jq -r '.[:10] | .[] | "\(.start_date // .START_DATE)  \(.test_status // .TEST_STATUS | ascii_upcase)  \(.sha // .SHA // "no-sha")"' 2>/dev/null || echo "Failed to parse history"
        echo ""

        # Calculate pass/fail rate
        local pass_count fail_count
        pass_count=$(echo "$history" | jq '[.[] | select(.test_status == "success" or .TEST_STATUS == "success")] | length' 2>/dev/null || echo "0")
        fail_count=$(echo "$history" | jq '[.[] | select(.test_status == "failure" or .TEST_STATUS == "failure")] | length' 2>/dev/null || echo "0")

        if [[ $run_count -gt 0 ]]; then
            local pass_rate
            pass_rate=$(awk "BEGIN {printf \"%.1f\", ($pass_count / $run_count) * 100}")
            echo "Pass rate (last 20 runs): $pass_rate% ($pass_count passed, $fail_count failed)"
        fi
    fi
    echo ""

    # Step 6: Calculate bisect range (if we have both SHAs)
    if [[ -n "$last_success_sha" && "$last_success_sha" != "null" && -n "$sha" && "$sha" != "null" ]]; then
        echo -e "${GREEN}Step 6: Calculating bisect range${NC}"
        echo ""

        log_info "Finding bisect range..."
        local bisect_info
        bisect_info=$(find_bisect_range "$sha" "$test_name" "$branch_name" 2>&1)

        if [[ $? -ne 0 ]]; then
            log_error "Failed to calculate bisect range"
            echo ""
            echo "Error:"
            echo "$bisect_info"
        else
            log_success "Calculated bisect range"
            echo ""
            echo "Bisect information:"
            echo "$bisect_info" | jq '.' 2>/dev/null || echo "$bisect_info"
            echo ""

            local commit_count
            commit_count=$(echo "$bisect_info" | jq -r '.commit_count' 2>/dev/null)

            if [[ -n "$commit_count" && "$commit_count" != "null" ]]; then
                log_info "Commits to bisect: $commit_count"
                echo ""

                # Step 7: Try to find first failure in test history
                echo -e "${GREEN}Step 7: Searching for first failure in test history${NC}"
                echo ""

                log_info "Checking test history for failures between SHAs..."
                local first_failure
                first_failure=$(find_first_failure "$test_name" "$last_success_sha" "$sha" 2>&1)

                if [[ $? -eq 0 && -n "$first_failure" ]]; then
                    log_success "First failure found in test history!"
                    echo ""
                    echo "First failure SHA: $first_failure"
                    echo ""
                    log_info "This means you may not need to bisect manually!"
                    echo "  View the change: git show $first_failure"
                else
                    log_info "No first failure found in test history"
                    echo ""
                    echo "This means:"
                    echo "  - Not all commits in the range have been tested"
                    echo "  - You may need to run manual git bisect"
                    echo ""
                    echo "Manual bisect command:"
                    echo "  cd cockroachdb"
                    echo "  git bisect start $sha $last_success_sha"
                fi
            fi
        fi
    else
        log_warn "Skipping bisect range calculation (SHA not available)"
    fi
    echo ""

    # Summary
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Test Summary${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "✅ Snowflake CLI: PASS"
    echo "✅ Credentials: PASS"
    echo "✅ Connectivity: PASS"

    if [[ -n "$last_success" ]]; then
        echo "✅ Find last success: PASS"
    else
        echo "❌ Find last success: FAIL"
    fi

    if [[ -n "$history" ]]; then
        echo "✅ Get test history: PASS"
    else
        echo "❌ Get test history: FAIL"
    fi

    if [[ -n "$last_success_sha" && "$last_success_sha" != "null" ]]; then
        echo "✅ Bisect range: PASS"
    else
        echo "⚠️  Bisect range: SKIPPED (no SHA)"
    fi

    echo ""
    echo "You can now use Snowflake helpers in your triage workflow!"
    echo ""
    echo "Quick commands:"
    echo "  # Find last success"
    echo "  bash .claude/hooks/snowflake-helpers.sh last-success \"$test_name\" \"$branch_name\""
    echo ""
    echo "  # Get test history"
    echo "  bash .claude/hooks/snowflake-helpers.sh history \"$test_name\" 100"
    echo ""
    echo "  # Calculate bisect range"
    echo "  bash .claude/hooks/snowflake-helpers.sh bisect \"$sha\" \"$test_name\" \"$branch_name\""
    echo ""
    echo "  # Use bisect helper"
    echo "  bash .claude/hooks/bisect-helper.sh info $issue_num"
    echo ""
}

# Main
if [[ $# -eq 0 ]]; then
    cat <<EOF
Usage: $0 <issue-number>

Example:
  $0 157102

This script tests the Snowflake integration by:
  1. Checking Snowflake CLI and credentials
  2. Loading test metadata from workspace
  3. Finding last successful run
  4. Getting test history
  5. Calculating bisect range
  6. Searching for first failure in history

Prerequisites:
  - Run 'bash .claude/hooks/triage-download.sh <issue-number>' first
  - Set Snowflake credentials
  - Install snowsql CLI
EOF
    exit 1
fi

test_snowflake "$1"
