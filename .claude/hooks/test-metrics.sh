#!/bin/bash
# Test script for Prometheus metrics integration
# Usage: ./test-metrics.sh <issue-number>

#set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the helper functions
source "$SCRIPT_DIR/triage-helpers.sh"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

test_metrics() {
    local issue_num="${1:-157102}"

    echo -e "${GREEN}=== Testing Prometheus Metrics Integration ===${NC}"
    echo ""

    # Step 1: Check if metadata exists
    local metadata_file="$PROJECT_ROOT/workspace/issues/$issue_num/metadata.json"
    if [[ ! -f "$metadata_file" ]]; then
        echo -e "${RED}✗ Metadata file not found${NC}"
        echo "  Expected: $metadata_file"
        echo ""
        echo "Run this first:"
        echo "  bash .claude/hooks/triage-download.sh $issue_num"
        exit 1
    fi

    echo -e "${GREEN}✓ Metadata file found${NC}"

    # Step 2: Extract metadata
    local start_ts end_ts grafana_url test_name
    start_ts=$(jq -r '.start_timestamp' "$metadata_file")
    end_ts=$(jq -r '.end_timestamp' "$metadata_file")
    grafana_url=$(jq -r '.grafana_url' "$metadata_file")
    test_name=$(jq -r '.test_name' "$metadata_file")

    echo ""
    echo "Issue: #$issue_num"
    echo "Test: $test_name"
    echo "Grafana URL: $grafana_url"
    echo ""

    if [[ -z "$start_ts" || "$start_ts" == "null" || -z "$end_ts" || "$end_ts" == "null" ]]; then
        echo -e "${YELLOW}⚠ No timestamps found in metadata${NC}"
        echo "  This test may not have Grafana metrics available"
        exit 0
    fi

    echo "Start time: $(timestamp_to_date "$start_ts")"
    echo "End time:   $(timestamp_to_date "$end_ts")"
    echo "Duration:   $(calculate_duration "$start_ts" "$end_ts")"
    echo ""

    # Step 3: Extract test_run_id from Grafana URL
    local test_run_id
    if [[ "$grafana_url" =~ teamcity-([0-9]+) ]]; then
        test_run_id="teamcity-${BASH_REMATCH[1]}"
        echo -e "${GREEN}✓ Extracted test_run_id: $test_run_id${NC}"
    else
        echo -e "${RED}✗ Could not extract test_run_id from Grafana URL${NC}"
        exit 1
    fi
    echo ""

    # Step 3.5: Sanitize test name for Prometheus labels
    local sanitized_test_name
    sanitized_test_name=$(sanitize_test_name "$test_name")
    echo "Sanitized test name for Prometheus: $sanitized_test_name"
    echo ""

    # Step 4: Test IAP token generation
    echo "Testing IAP token generation..."
    local token
    token=$(get_iap_token)
    if [[ $? -eq 0 && -n "$token" ]]; then
        echo -e "${GREEN}✓ IAP token generated successfully${NC}"
        echo "  Token length: ${#token} characters"
    else
        echo -e "${RED}✗ Failed to generate IAP token${NC}"
        echo ""
        echo "Make sure you're logged in to gcloud:"
        echo "  gcloud auth login"
        exit 1
    fi
    echo ""

    # Step 5: Find cluster name
    echo "Finding cluster name..."
    local cluster_query
    # Use a simple metric query to get the cluster label
    # Note: test_name in Prometheus has / and = replaced with -
    cluster_query="sys_uptime{job=\"cockroachdb\", test_run_id=\"$test_run_id\", test_name=\"$sanitized_test_name\"}"

    local cluster_response cluster
    cluster_response=$(query_prometheus "$start_ts" "$end_ts" "$cluster_query" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}✗ Failed to query for cluster name${NC}"
        echo "$cluster_response"
        exit 1
    fi

    # Extract cluster from the first result's metric labels
    echo $cluster_response
    cluster=$(echo "$cluster_response" | jq -r '.data.result[0].metric.cluster' 2>&1)
    if [[ -z "$cluster" || "$cluster" == "null" ]]; then
        echo -e "${YELLOW}⚠ No cluster found${NC}"
        echo "  This might mean metrics aren't available for this test run"
        echo ""
        echo "Response:"
        echo "$cluster_response" | jq '.' 2>/dev/null || echo "$cluster_response"
        exit 0
    fi

    echo -e "${GREEN}✓ Found cluster: $cluster${NC}"
    echo ""

    # Step 6: Test a few key metrics
    echo "Testing metric queries..."
    echo ""

    # Test 1: Memory usage
    echo "1. Querying memory usage (sys_rss)..."
    local mem_query="sys_rss{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
    local mem_response
    mem_response=$(query_prometheus "$start_ts" "$end_ts" "$mem_query" 2>&1)
    if [[ $? -eq 0 ]]; then
        local result_count
        result_count=$(echo "$mem_response" | jq '.data.result | length' 2>/dev/null || echo "0")
        echo -e "${GREEN}   ✓ Success - Found $result_count series${NC}"
    else
        echo -e "${RED}   ✗ Failed${NC}"
        echo "$mem_response"
    fi
    echo ""

    # Test 2: Goroutines
    echo "2. Querying goroutine count..."
    local goroutine_query="go_goroutines{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
    local goroutine_response
    goroutine_response=$(query_prometheus "$start_ts" "$end_ts" "$goroutine_query" 2>&1)
    if [[ $? -eq 0 ]]; then
        local result_count
        result_count=$(echo "$goroutine_response" | jq '.data.result | length' 2>/dev/null || echo "0")
        echo -e "${GREEN}   ✓ Success - Found $result_count series${NC}"
    else
        echo -e "${RED}   ✗ Failed${NC}"
        echo "$goroutine_response"
    fi
    echo ""

    # Test 3: Node disk space
    echo "3. Querying disk space (node_filesystem_avail_bytes)..."
    local disk_query="node_filesystem_avail_bytes{job=\"node\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
    local disk_response
    disk_response=$(query_prometheus "$start_ts" "$end_ts" "$disk_query" 2>&1)
    if [[ $? -eq 0 ]]; then
        local result_count
        result_count=$(echo "$disk_response" | jq '.data.result | length' 2>/dev/null || echo "0")
        echo -e "${GREEN}   ✓ Success - Found $result_count series${NC}"
    else
        echo -e "${RED}   ✗ Failed${NC}"
        echo "$disk_response"
    fi
    echo ""

    # Summary
    echo -e "${GREEN}=== Test Complete ===${NC}"
    echo ""
    echo "You can now use these queries in your triage workflow:"
    echo ""
    echo "# Extract variables from metadata"
    echo "start=\$(jq -r '.start_timestamp' workspace/issues/$issue_num/metadata.json)"
    echo "end=\$(jq -r '.end_timestamp' workspace/issues/$issue_num/metadata.json)"
    echo "test_run_id=\"$test_run_id\""
    echo "cluster=\"$cluster\""
    echo ""
    echo "# Query metrics"
    echo "source .claude/hooks/triage-helpers.sh"
    echo "query_prometheus \"\$start\" \"\$end\" \"sys_rss{job=\\\"cockroachdb\\\",test_run_id=\\\"\$test_run_id\\\",cluster=\\\"\$cluster\\\"}\" | jq '.'"
    echo ""
}

# Main
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <issue-number>"
    echo ""
    echo "Example:"
    echo "  $0 157102"
    echo ""
    echo "This script tests the Prometheus metrics integration by:"
    echo "  1. Checking if metadata exists for the issue"
    echo "  2. Extracting timestamps and test info"
    echo "  3. Testing IAP token generation"
    echo "  4. Finding the cluster name"
    echo "  5. Running sample metric queries"
    exit 1
fi

test_metrics "$1"
