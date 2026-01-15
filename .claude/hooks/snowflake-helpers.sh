#!/bin/bash
# Snowflake integration for test history and bisecting failures
#
# This script provides utilities for:
# - Querying test history from Snowflake
# - Finding the last successful run of a test
# - Identifying the SHA range for bisecting
#
# Requirements:
# - snowsql (Snowflake CLI) - Install: https://docs.snowflake.com/en/user-guide/snowsql-install-config.html
# - SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PASSWORD (or other auth method)
#
# Environment variables:
# - SNOWFLAKE_ACCOUNT: Your Snowflake account identifier
# - SNOWFLAKE_USER: Snowflake username
# - SNOWFLAKE_PASSWORD: Snowflake Personal Access Token (PAT)
# - SNOWFLAKE_DATABASE: Database name (default: DATAMART_PROD)
# - SNOWFLAKE_SCHEMA: Schema name (default: TEAMCITY)
# - SNOWFLAKE_WAREHOUSE: Warehouse name (default: COMPUTE_WH)

# Only set strict mode when running directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the helper functions for logging
source "$SCRIPT_DIR/triage-helpers.sh"

# Snowflake connection defaults (override with environment variables)
SNOWFLAKE_DATABASE="${SNOWFLAKE_DATABASE:-DATAMART_PROD}"
SNOWFLAKE_SCHEMA="${SNOWFLAKE_SCHEMA:-TEAMCITY}"
SNOWFLAKE_WAREHOUSE="${SNOWFLAKE_WAREHOUSE:-COMPUTE_WH}"

# Check if Snowflake CLI is available
check_snowflake_cli() {
    if ! command -v snowsql &>/dev/null; then
        log_error "snowsql (Snowflake CLI) not found"
        log_info "Install from: https://docs.snowflake.com/en/user-guide/snowsql-install-config.html"
        return 1
    fi

    # Check required environment variables
    if [[ -z "${SNOWFLAKE_ACCOUNT:-}" ]]; then
        log_error "SNOWFLAKE_ACCOUNT environment variable not set"
        return 1
    fi

    if [[ -z "${SNOWFLAKE_USER:-}" ]]; then
        log_error "SNOWFLAKE_USER environment variable not set"
        return 1
    fi

    # PAT required
    if [[ -z "${SNOWFLAKE_PASSWORD:-}" ]]; then
        log_error "SNOWFLAKE_PASSWORD (Personal Access Token) must be set"
        return 1
    fi

    return 0
}

# Execute a Snowflake query and return JSON results
# Usage: query_snowflake "SELECT * FROM test_results LIMIT 10"
query_snowflake() {
    local query="$1"

    if ! check_snowflake_cli; then
        return 1
    fi

    log_info "Executing Snowflake query..."

    # Build snowsql command
    local cmd="snowsql"
    cmd="$cmd -a $SNOWFLAKE_ACCOUNT"
    cmd="$cmd -u $SNOWFLAKE_USER"
    cmd="$cmd -d $SNOWFLAKE_DATABASE"
    cmd="$cmd -s $SNOWFLAKE_SCHEMA"
    cmd="$cmd -w $SNOWFLAKE_WAREHOUSE"
    cmd="$cmd -o output_format=json"
    cmd="$cmd -o friendly=false"
    cmd="$cmd -o timing=false"
    cmd="$cmd -q \"$query\""

    # Add PAT authentication
    cmd="SNOWSQL_PWD='$SNOWFLAKE_PASSWORD' $cmd"

    # Execute query
    local result
    result=$(eval "$cmd" 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Snowflake query failed"
        echo "$result" >&2
        return 1
    fi

    echo "$result"
    return 0
}

# Find the last successful run of a test
# Usage: find_last_success "roachtest.restore/tpce/400GB/nodes=10" "release-24.3"
# Returns: JSON with {build_id, start_date, branch_name, status}
find_last_success() {
    local test_name="$1"
    local branch="${2:-}"  # Optional: filter by release branch

    log_info "Searching for last successful run of: $test_name"
    if [[ -n "$branch" ]]; then
        log_info "  Filtering by branch: $branch"
    fi

    # Query using TC_EXECUTED_TESTS structure from your example
    # Note: We need to join BUILDS table to get SHA info
    local query="
    WITH TC_BUILDS AS (
        SELECT
            id as build_id,
            name as build_name,
            build_type_id as build_type,
            branch_name,
            start_date,
            -- Extract SHA from branch_name or use revision if available
            CASE
                WHEN branch_name RLIKE '[a-f0-9]{40}' THEN REGEXP_SUBSTR(branch_name, '[a-f0-9]{40}')
                ELSE NULL
            END as sha
        FROM DATAMART_PROD.TEAMCITY.BUILDS
        WHERE start_date > DATEADD(DAY, -90, CURRENT_DATE())
          AND build_name ILIKE '%roachtest%'
    ),
    TC_EXECUTED_TESTS AS (
        SELECT
            b.start_date,
            b.build_id,
            b.build_type,
            b.branch_name,
            b.sha,
            a.test_name,
            LOWER(a.status) as test_status,
            a.duration as test_duration_ms
        FROM DATAMART_PROD.TEAMCITY.TESTS a
        INNER JOIN TC_BUILDS b ON (a.BUILD_ID = b.BUILD_ID)
        WHERE a.test_name IS NOT NULL
          AND LOWER(a.status) NOT IN ('unknown', 'skipped', 'error')
    )
    SELECT
        build_id,
        start_date,
        branch_name,
        sha,
        test_status
    FROM TC_EXECUTED_TESTS
    WHERE test_name = '$test_name'
      AND test_status = 'success'
    "

    # Add branch filter if provided
    if [[ -n "$branch" ]]; then
        # Handle both exact match and "like" patterns
        query="$query AND (branch_name = '$branch' OR branch_name LIKE '%$branch%')"
    fi

    query="$query
    ORDER BY start_date DESC
    LIMIT 1;
    "

    local result
    result=$(query_snowflake "$query")

    if [[ $? -ne 0 ]]; then
        log_error "Failed to query Snowflake for last success"
        return 1
    fi

    echo "$result"
    return 0
}

# Get test history for a specific test
# Usage: get_test_history "roachtest.restore/tpce/400GB/nodes=10" 100 "release-24.3"
# Returns: JSON array with test run history
get_test_history() {
    local test_name="$1"
    local limit="${2:-100}"
    local branch="${3:-}"

    log_info "Fetching test history for: $test_name (limit: $limit)"

    local query="
    WITH TC_BUILDS AS (
        SELECT
            id as build_id,
            name as build_name,
            build_type_id as build_type,
            branch_name,
            start_date,
            CASE
                WHEN branch_name RLIKE '[a-f0-9]{40}' THEN REGEXP_SUBSTR(branch_name, '[a-f0-9]{40}')
                ELSE NULL
            END as sha
        FROM DATAMART_PROD.TEAMCITY.BUILDS
        WHERE start_date > DATEADD(DAY, -90, CURRENT_DATE())
          AND build_name ILIKE '%roachtest%'
    ),
    TC_EXECUTED_TESTS AS (
        SELECT
            b.start_date,
            b.build_id,
            b.build_type,
            b.branch_name,
            b.sha,
            a.test_name,
            LOWER(a.status) as test_status,
            a.duration as test_duration_ms
        FROM DATAMART_PROD.TEAMCITY.TESTS a
        INNER JOIN TC_BUILDS b ON (a.BUILD_ID = b.BUILD_ID)
        WHERE a.test_name IS NOT NULL
          AND LOWER(a.status) NOT IN ('unknown', 'skipped', 'error')
    )
    SELECT
        build_id,
        start_date,
        branch_name,
        sha,
        test_status,
        test_duration_ms
    FROM TC_EXECUTED_TESTS
    WHERE test_name = '$test_name'
    "

    if [[ -n "$branch" ]]; then
        query="$query AND (branch_name = '$branch' OR branch_name LIKE '%$branch%')"
    fi

    query="$query
    ORDER BY start_date DESC
    LIMIT $limit;
    "

    local result
    result=$(query_snowflake "$query")

    if [[ $? -ne 0 ]]; then
        log_error "Failed to query Snowflake for test history"
        return 1
    fi

    echo "$result"
    return 0
}

# Find the SHA range for bisecting between last success and current failure
# Usage: find_bisect_range "abc123def" "release-24.3"
# Returns: JSON with {last_success_sha, failure_sha, commit_count}
find_bisect_range() {
    local failure_sha="$1"
    local test_name="$2"
    local branch="${3:-}"

    log_info "Finding bisect range for failure at $failure_sha"

    # Find last success
    local last_success
    last_success=$(find_last_success "$test_name" "$branch")

    if [[ $? -ne 0 ]]; then
        log_error "Could not find last successful run"
        return 1
    fi

    # Extract SHA from last success
    local last_success_sha
    last_success_sha=$(echo "$last_success" | jq -r '.[0].sha // .[0].SHA' 2>/dev/null)

    if [[ -z "$last_success_sha" || "$last_success_sha" == "null" ]]; then
        log_warn "Could not extract SHA from last success - may not be available in build metadata"
        log_info "Last success result: $last_success"
        return 1
    fi

    log_success "Last success: $last_success_sha"
    log_info "Current failure: $failure_sha"

    # Count commits between last success and failure
    # This requires the cockroachdb git repository
    local cockroach_dir="$PROJECT_ROOT/cockroachdb"

    if [[ ! -d "$cockroach_dir/.git" ]]; then
        log_error "CockroachDB repository not found at $cockroach_dir"
        return 1
    fi

    # Navigate to repo and count commits
    local commit_count
    commit_count=$(cd "$cockroach_dir" && git rev-list --count "$last_success_sha..$failure_sha" 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        log_error "Failed to count commits in range"
        return 1
    fi

    log_info "Commits in bisect range: $commit_count"

    # Return JSON
    cat <<EOF
{
  "last_success_sha": "$last_success_sha",
  "failure_sha": "$failure_sha",
  "commit_count": $commit_count,
  "test_name": "$test_name",
  "branch": "$branch"
}
EOF

    return 0
}

# Get commits in bisect range
# Usage: get_bisect_commits "abc123" "def456"
# Returns: List of commit SHAs between the two commits
get_bisect_commits() {
    local start_sha="$1"
    local end_sha="$2"

    local cockroach_dir="$PROJECT_ROOT/cockroachdb"

    if [[ ! -d "$cockroach_dir/.git" ]]; then
        log_error "CockroachDB repository not found"
        return 1
    fi

    log_info "Getting commits between $start_sha and $end_sha"

    # Get commit list
    local commits
    commits=$(cd "$cockroach_dir" && git rev-list --reverse "$start_sha..$end_sha" 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        log_error "Failed to get commit list"
        return 1
    fi

    echo "$commits"
    return 0
}

# Find the first failing commit using Snowflake test history
# Usage: find_first_failure "roachtest.restore/tpce/400GB/nodes=10" "abc123" "def456"
# Returns: SHA of the first commit that failed (if found in test history)
find_first_failure() {
    local test_name="$1"
    local start_sha="$2"  # Last success
    local end_sha="$3"    # Known failure

    log_info "Searching test history for first failure..."

    # Get commits in range
    local commits
    commits=$(get_bisect_commits "$start_sha" "$end_sha")

    if [[ $? -ne 0 ]]; then
        return 1
    fi

    # For each commit, check if we have test results in Snowflake
    while IFS= read -r sha; do
        log_info "  Checking $sha..."

        local query="
        WITH TC_BUILDS AS (
            SELECT
                id as build_id,
                name as build_name,
                build_type_id as build_type,
                branch_name,
                start_date,
                CASE
                    WHEN branch_name RLIKE '[a-f0-9]{40}' THEN REGEXP_SUBSTR(branch_name, '[a-f0-9]{40}')
                    ELSE NULL
                END as sha
            FROM DATAMART_PROD.TEAMCITY.BUILDS
            WHERE start_date > DATEADD(DAY, -90, CURRENT_DATE())
              AND build_name ILIKE '%roachtest%'
        ),
        TC_EXECUTED_TESTS AS (
            SELECT
                b.start_date,
                b.build_id,
                b.sha,
                a.test_name,
                LOWER(a.status) as test_status
            FROM DATAMART_PROD.TEAMCITY.TESTS a
            INNER JOIN TC_BUILDS b ON (a.BUILD_ID = b.BUILD_ID)
            WHERE a.test_name IS NOT NULL
              AND LOWER(a.status) NOT IN ('unknown', 'skipped', 'error')
        )
        SELECT sha, test_status, start_date
        FROM TC_EXECUTED_TESTS
        WHERE test_name = '$test_name'
          AND sha = '$sha'
        ORDER BY start_date DESC
        LIMIT 1;
        "

        local result
        result=$(query_snowflake "$query")

        if [[ $? -eq 0 ]]; then
            local status
            status=$(echo "$result" | jq -r '.[0].test_status' 2>/dev/null)

            if [[ "$status" == "failure" ]]; then
                log_success "First failure found at: $sha"
                echo "$sha"
                return 0
            fi
        fi
    done <<< "$commits"

    log_warn "No test results found in Snowflake for commits in range"
    log_info "You may need to run a manual git bisect"
    return 1
}

# Save bisect information to workspace
# Usage: save_bisect_info <issue_num> <bisect_json>
save_bisect_info() {
    local issue_num="$1"
    local bisect_json="$2"

    local workspace_dir="$PROJECT_ROOT/workspace/issues/$issue_num"
    local bisect_file="$workspace_dir/bisect-info.json"

    if [[ ! -d "$workspace_dir" ]]; then
        log_error "Workspace directory not found: $workspace_dir"
        return 1
    fi

    echo "$bisect_json" | jq '.' > "$bisect_file"

    if [[ $? -eq 0 ]]; then
        log_success "Bisect info saved to: workspace/issues/$issue_num/bisect-info.json"
        return 0
    else
        log_error "Failed to save bisect info"
        return 1
    fi
}

# Main function for testing
main() {
    if [[ $# -eq 0 ]]; then
        cat <<EOF
Usage: $0 <command> [args...]

Commands:
  last-success <test-name> [branch]
      Find the last successful run of a test

  history <test-name> [limit] [branch]
      Get test history

  bisect <failure-sha> <test-name> [branch]
      Find the bisect range for a failure

  find-first-failure <test-name> <start-sha> <end-sha>
      Find the first failing commit in a range

Examples:
  $0 last-success "roachtest.restore/tpce/400GB/nodes=10" "release-24.3"
  $0 history "roachtest.restore/tpce/400GB/nodes=10" 50
  $0 bisect "abc123def" "roachtest.restore/tpce/400GB/nodes=10" "release-24.3"

Environment variables required:
  SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PASSWORD (or SNOWFLAKE_PRIVATE_KEY_PATH)

Optional:
  SNOWFLAKE_DATABASE (default: COCKROACH_TEST_RESULTS)
  SNOWFLAKE_SCHEMA (default: PUBLIC)
  SNOWFLAKE_WAREHOUSE (default: COMPUTE_WH)
EOF
        exit 1
    fi

    local command="$1"
    shift

    case "$command" in
        last-success)
            find_last_success "$@"
            ;;
        history)
            get_test_history "$@"
            ;;
        bisect)
            find_bisect_range "$@"
            ;;
        find-first-failure)
            find_first_failure "$@"
            ;;
        *)
            log_error "Unknown command: $command"
            exit 1
            ;;
    esac
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
