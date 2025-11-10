# Prometheus Metrics Integration

This document explains how to query Prometheus metrics during triage to diagnose issues like OOM, CPU starvation, or disk usage.

## Quick Start

```bash
# Source the helper script
source .claude/hooks/triage-helpers.sh

# Extract timestamps from metadata
start=$(jq -r '.start_timestamp' workspace/issues/$ISSUE_NUM/metadata.json)
end=$(jq -r '.end_timestamp' workspace/issues/$ISSUE_NUM/metadata.json)

# Sanitize test name and find cluster
test_name=$(jq -r '.test_name' workspace/issues/$ISSUE_NUM/metadata.json)
sanitized_test_name=$(sanitize_test_name "$test_name")
test_run_id="teamcity-12345"  # Extract from Grafana URL

# Find cluster name
cluster=$(query_prometheus "$start" "$end" "sys_uptime{job=\"cockroachdb\", test_run_id=\"$test_run_id\", test_name=\"$sanitized_test_name\"}" | jq -r '.data.result[0].metric.cluster')

# Query metrics
query_prometheus "$start" "$end" "sys_rss{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
```

## Authentication

The helper script automatically generates an IAP token using your gcloud credentials:
- Uses `gcloud config get-value account` to get your email dynamically
- Impersonates the prom-helper-service service account
- Works for any user with gcloud configured

Alternatively, set `IAP_TOKEN` environment variable manually if you have a token.

## Important: Test Name Sanitization

**CRITICAL**: In Prometheus labels, the test_name has all non-standard chars (`/`, `=`, etc.) replaced with `-`.

Example:
- GitHub issue test name: `"tpcc-nowait/isolation-level=mixed/nodes=3/w=1"`
- Prometheus label value: `"tpcc-nowait-isolation-level-mixed-nodes-3-w-1"`

Always use the `sanitize_test_name()` helper function:

```bash
sanitized_test_name=$(sanitize_test_name "$test_name")
```

## Label Extraction from Grafana URL

All roachtest metrics have these labels (extracted from the Grafana URL in the issue):

```
Example Grafana URL:
https://go.crdb.dev/roachtest-grafana/teamcity-20596757/tpcc-nowait/.../1760342495871/1760343597051

Labels to use in queries:
- test_run_id="teamcity-20596757"
- test_name="tpcc-nowait-isolation-level-mixed-nodes-3-w-1" (sanitized!)
- cluster (computed dynamically, see below)
```

## Finding the Cluster Label

The cluster label must be discovered dynamically:

```bash
# First, sanitize the test name for Prometheus labels
sanitized_test_name=$(sanitize_test_name "$test_name")

# Then query a simple metric to get the cluster label from results
query="sys_uptime{job=\"cockroachdb\", test_run_id=\"$test_run_id\", test_name=\"$sanitized_test_name\"}"
cluster=$(query_prometheus "$start" "$end" "$query" | jq -r '.data.result[0].metric.cluster')

# Now use it in your queries
query_prometheus "$start" "$end" "up{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
```

## Available Metrics

### CockroachDB Metrics (`job="cockroachdb"`)

**System Resources:**
- `sys_uptime` - Node uptime (seconds)
- `sys_cpu_user_percent` - CPU usage in user space
- `sys_cpu_sys_percent` - CPU usage in kernel space
- `sys_rss` - Resident set size (memory usage in bytes)
- `sys_go_allocbytes` - Go allocated bytes
- `sys_go_totalbytes` - Go total bytes
- `go_goroutines` - Number of goroutines

**Storage:**
- `capacity` - Total storage capacity
- `capacity_available` - Available storage capacity
- `kv_rocksdb_flushes` - RocksDB/Pebble flush operations
- `kv_rocksdb_compactions` - RocksDB/Pebble compaction operations

**Transactions:**
- `txn_commits` - Transaction commit count
- `txn_aborts` - Transaction abort count

**SQL:**
- `sql_conns` - Active SQL connections
- `sql_query_count` - SQL query count

**Replication:**
- `replicas_leaders` - Number of raft leaders on this node
- `replicas_leaseholders` - Number of lease holders on this node
- `range_splits` - Range split operations
- `range_merges` - Range merge operations

### Node Exporter Metrics (`job="node"`)

**CPU:**
- `node_cpu_seconds_total` - CPU time spent in various modes

**Memory:**
- `node_memory_MemAvailable_bytes` - Available memory
- `node_memory_MemTotal_bytes` - Total memory
- `node_vmstat_oom_kill` - OOM killer invocations

**Disk:**
- `node_filesystem_avail_bytes` - Available disk space
- `node_filesystem_size_bytes` - Total disk space
- `node_disk_io_time_seconds_total` - Disk I/O time

**Network:**
- `node_network_receive_bytes_total` - Network bytes received
- `node_network_transmit_bytes_total` - Network bytes transmitted

### eBPF Exporter Metrics (`job="ebpf"`)

- Network latency metrics
- System call tracing
- Advanced performance monitoring

## Common Query Patterns

### Memory Usage Over Time
```bash
query_prometheus "$start" "$end" "sys_rss{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
```

### CPU Usage Rate
```bash
query_prometheus "$start" "$end" "rate(sys_cpu_user_percent{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}[1m])"
```

### Disk Space Available
```bash
query_prometheus "$start" "$end" "node_filesystem_avail_bytes{job=\"node\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
```

### OOM Killer Activity
```bash
query_prometheus "$start" "$end" "node_vmstat_oom_kill{job=\"node\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
```

### Goroutine Count
```bash
query_prometheus "$start" "$end" "go_goroutines{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}"
```

### Transaction Rate
```bash
query_prometheus "$start" "$end" "rate(txn_commits{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}[1m])"
```

## When to Use Prometheus

### OOM Issues
Check:
- `sys_rss` - Memory usage trends
- `node_memory_MemAvailable_bytes` - Available memory on VM
- `node_vmstat_oom_kill` - OOM killer activity

Look for:
- Continuously growing memory
- Memory usage reaching VM limits
- Spikes in OOM killer invocations

### CPU Starvation
Check:
- `sys_cpu_user_percent` - User space CPU usage
- `sys_cpu_sys_percent` - Kernel space CPU usage
- `node_cpu_seconds_total` - Total CPU time

Look for:
- CPU usage at 100%
- Sustained high CPU usage
- CPU bottlenecks

### Disk Full Errors
Check:
- `node_filesystem_avail_bytes` - Available disk space
- `capacity_available` - CRDB's view of available storage

Look for:
- Disk space approaching 0
- Rapid disk usage growth
- Disk space exhaustion

### Goroutine Leaks
Check:
- `go_goroutines` - Goroutine count over time

Look for:
- Continuously growing goroutine count
- Goroutines not being cleaned up
- Correlation with memory growth

### Network Issues
Check:
- `node_network_receive_bytes_total` - Bytes received
- `node_network_transmit_bytes_total` - Bytes transmitted

Look for:
- Network traffic drops
- Sustained high network usage
- Network saturation

### Performance Degradation
Check:
- `txn_commits` - Transaction commit rate
- `sql_query_count` - Query execution rate
- `replicas_leaders` - Leader distribution

Look for:
- Decreasing transaction/query rates
- Uneven leader distribution
- Performance regressions compared to baseline

## Timestamp Utilities

The helper script provides timestamp conversion functions:

```bash
# Convert timestamp to human-readable date
timestamp_to_date "1762605238000"
# Output: 2025-11-08 10:20:38 PST

# Calculate test duration
calculate_duration "1762605238000" "1762605993548"
# Output: 12m 35s
```

**Using timestamps in analysis:**
- Check when the test started/ended
- Correlate with log timestamps to understand timing
- Use Grafana URL to view metrics during the test run
- Compare duration with expected test runtime (unusually short = early failure)

## Testing Metrics Integration

Use the test script to verify Prometheus access:

```bash
bash .claude/hooks/test-metrics.sh <issue-number>
```

This will:
1. Check if metadata exists
2. Extract timestamps and test info
3. Test IAP token generation
4. Sanitize test name
5. Find cluster name
6. Run sample metric queries

## Example: Diagnosing an OOM Issue

```bash
# Source helper functions
source .claude/hooks/triage-helpers.sh

# Get metadata
start=$(jq -r '.start_timestamp' workspace/issues/157102/metadata.json)
end=$(jq -r '.end_timestamp' workspace/issues/157102/metadata.json)
test_name=$(jq -r '.test_name' workspace/issues/157102/metadata.json)
sanitized_test_name=$(sanitize_test_name "$test_name")
test_run_id="teamcity-20713915"

# Find cluster
cluster=$(query_prometheus "$start" "$end" "sys_uptime{job=\"cockroachdb\",test_run_id=\"$test_run_id\",test_name=\"$sanitized_test_name\"}" | jq -r '.data.result[0].metric.cluster')

# Check memory usage
query_prometheus "$start" "$end" "sys_rss{job=\"cockroachdb\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}" | jq '.data.result[].values'

# Check OOM killer
query_prometheus "$start" "$end" "node_vmstat_oom_kill{job=\"node\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}" | jq '.data.result[].values'

# Check available memory
query_prometheus "$start" "$end" "node_memory_MemAvailable_bytes{job=\"node\",test_run_id=\"$test_run_id\",cluster=\"$cluster\"}" | jq '.data.result[].values'
```

Analyze the results:
- If `sys_rss` grows continuously → Memory leak
- If `node_vmstat_oom_kill` increases → OOM occurred
- If `node_memory_MemAvailable_bytes` approaches 0 → VM ran out of memory
