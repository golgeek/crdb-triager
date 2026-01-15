#!/bin/bash
# Test script for the new triage improvements
# Usage: ./test-improvements.sh <issue-number>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source helpers
source "$SCRIPT_DIR/triage-helpers.sh"

test_improvements() {
    local issue_num="${1:-}"

    if [[ -z "$issue_num" ]]; then
        cat <<EOF
Usage: $0 <issue-number>

This script tests all the new triage improvements:
1. Environment validation
2. Metrics extraction
3. Snowflake integration (if configured)
4. Bisect helper

Example:
  $0 157102

Prerequisites:
  - TEAMCITY_TOKEN must be set
  - gcloud auth login (for metrics)
  - Snowflake credentials (optional, for bisect features)
EOF
        exit 1
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Testing Triage Improvements for Issue #$issue_num"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Test 1: Environment validation
    echo "1️⃣  Testing environment validation..."
    echo ""
    if bash "$SCRIPT_DIR/triage-download.sh" "$issue_num" 2>&1 | head -20; then
        log_success "Environment validation passed"
    else
        log_error "Environment validation failed (check errors above)"
        exit 1
    fi
    echo ""

    # Test 2: Check workspace was created
    local workspace_dir="$PROJECT_ROOT/workspace/issues/$issue_num"
    echo "2️⃣  Checking workspace creation..."
    echo ""
    if [[ -d "$workspace_dir" ]]; then
        log_success "Workspace created: $workspace_dir"
        echo ""
        echo "Files in workspace:"
        ls -lh "$workspace_dir" | grep -v "^total" | head -20
    else
        log_error "Workspace not found"
        exit 1
    fi
    echo ""

    # Test 3: Check metrics extraction
    echo "3️⃣  Checking metrics extraction..."
    echo ""
    local metrics_file="$workspace_dir/extracted-metrics.json"
    if [[ -f "$metrics_file" ]]; then
        log_success "Metrics file created"
        echo ""
        echo "Analysis hints:"
        cat "$metrics_file" | jq '.analysis_hints' 2>/dev/null || cat "$metrics_file"
        echo ""
        echo "Metrics available:"
        cat "$metrics_file" | jq '.metrics | keys' 2>/dev/null || echo "  (error parsing metrics)"
    else
        log_warn "Metrics file not found (may not be available for this issue)"
    fi
    echo ""

    # Test 4: Check Snowflake bisect info
    echo "4️⃣  Checking Snowflake bisect information..."
    echo ""
    local bisect_file="$workspace_dir/bisect-info.json"
    if [[ -f "$bisect_file" ]]; then
        log_success "Bisect info file created"
        echo ""
        echo "Bisect information:"
        cat "$bisect_file" | jq '.' 2>/dev/null || cat "$bisect_file"
    else
        log_warn "Bisect info not found (Snowflake may not be configured)"
        echo ""
        echo "To enable Snowflake integration:"
        echo "  export SNOWFLAKE_ACCOUNT='your_account'"
        echo "  export SNOWFLAKE_USER='your_username'"
        echo "  export SNOWFLAKE_PASSWORD='your_pat_token'"
        echo "  brew install snowflake-snowsql"
    fi
    echo ""

    # Test 5: Bisect helper
    echo "5️⃣  Testing bisect helper..."
    echo ""
    if [[ -f "$bisect_file" ]]; then
        bash "$SCRIPT_DIR/bisect-helper.sh" info "$issue_num"
    else
        log_warn "Skipping bisect helper test (no bisect-info.json)"
    fi
    echo ""

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "✅ Environment validation: PASS"
    echo "✅ Workspace creation: PASS"

    if [[ -f "$metrics_file" ]]; then
        echo "✅ Metrics extraction: PASS"
    else
        echo "⚠️  Metrics extraction: SKIPPED (no timestamps)"
    fi

    if [[ -f "$bisect_file" ]]; then
        echo "✅ Snowflake integration: PASS"
        echo "✅ Bisect helper: PASS"
    else
        echo "⚠️  Snowflake integration: NOT CONFIGURED"
        echo "⚠️  Bisect helper: SKIPPED (no Snowflake)"
    fi

    echo ""
    echo "Workspace location: $workspace_dir"
    echo ""
    echo "To view the triage data:"
    echo "  cd $workspace_dir"
    echo "  ls -lh"
    echo ""
    echo "To start triaging with Claude Code:"
    echo "  Ask Claude to 'triage issue #$issue_num'"
    echo ""
}

# Main
test_improvements "$@"
