# Failure Patterns

This document describes common patterns that help identify whether a failure is an infrastructure flake, test bug, or actual bug in CockroachDB.

## Infrastructure Flake Indicators

### VM Restarts or Reboots
```
# Look for in journalctl:
- "Stopped target" messages
- "Starting" after unexpected shutdown
- Boot sequences
```

**Example evidence:**
- systemd messages about stopping services
- kernel: Power button pressed
- Reboot messages in system logs

**Why it's a flake:** The test didn't cause the VM to restart - the cloud provider or infrastructure did.

### Disk Full
```
# Look for:
- "no space left on device"
- df output showing 100% usage
- Write failures
```

**Example evidence:**
- Failed to write file: no space left on device
- Disk usage at 100% in logs
- Unable to create log files

**Why it's a flake:** Test infrastructure should provision enough disk space. If the disk fills up, it's an infrastructure issue.

### Network Issues
```
# Look for:
- "connection refused"
- "no route to host"
- "i/o timeout"
- During infrastructure setup, not test execution
```

**Example evidence:**
- Failed to connect to node: connection refused
- Network unreachable errors
- DNS resolution failures

**Why it's a flake:** If network issues occur during setup or between infrastructure components, it's not a CockroachDB bug.

### OOM (Out of Memory)
```
# Look for in dmesg:
- "Out of memory"
- "Killed process"
- OOM killer messages
```

**Example evidence:**
- kernel: Out of memory: Killed process
- oom_reaper: reaped process
- Process killed by OOM killer

**Why it's a flake:** If the OOM killer targets test infrastructure (not CockroachDB), or if the VM simply ran out of memory, it's an infrastructure issue.

### TeamCity Agent Issues
```
# Look for:
- Agent disconnected messages
- Build canceled by agent
- Agent heartbeat failures
```

**Example evidence:**
- TeamCity agent lost connection
- Build was canceled
- Agent became unresponsive

**Why it's a flake:** TeamCity infrastructure problems are not test or CockroachDB bugs.

## Test Bug Indicators

### Test Timeout Issues
```
# Look for:
- Test exceeded maximum duration
- Test timeout before actual failure
- Aggressive timeout settings in test code
```

**Example evidence:**
- Test timeout after 30m (but test typically runs 45m)
- Hard-coded timeout too short for workload
- Test didn't wait long enough for cluster to stabilize

**Why it's a test bug:** The test logic or configuration is incorrect, not CockroachDB.

### Unable to Run Workload
```
# Look for:
- Failed to install third-party tool (sysbench, pgbench, etc.)
- Download failures for test dependencies
- Incompatible tool versions
```

**Example evidence:**
- apt-get failed to install sysbench
- Could not download workload binary
- Version mismatch between tool and test

**Why it's a test bug:** Test infrastructure or test setup is broken.

### Test Logic Errors
```
# Look for:
- Test expects incorrect behavior
- Test assertions don't match reality
- Test cleanup failures
```

**Example evidence:**
- Test expects immediate replication but doesn't wait
- Assertion fails because test doesn't account for timing
- Test tries to clean up resources that don't exist

**Why it's a test bug:** The test code itself has bugs.

## Actual Bug Indicators

### SQL Panics
```
# Stack trace in CRDB code:
- pkg/sql/*
- Assertion failures
- Unexpected nil pointers
```

**Example evidence:**
- panic: runtime error: invalid memory address or nil pointer dereference
- Stack trace shows sql package panic
- Assertion failed in SQL execution

**Why it's a bug:** CockroachDB code panicked during SQL execution - this is a real bug.

### Data Corruption
```
# Look for:
- Checksum mismatches
- Inconsistent replicas
- Unexpected data values
```

**Example evidence:**
- Checksum mismatch detected
- Replica divergence
- Query returns wrong results

**Why it's a bug:** Data integrity is compromised - this is a critical bug.

### Concurrency Issues
```
# Look for:
- Deadlock messages
- "fatal error: concurrent map writes"
- Race detector output
```

**Example evidence:**
- Detected race condition
- Deadlock detected in transaction
- Concurrent map access panic

**Why it's a bug:** Race conditions and deadlocks in CockroachDB code are bugs.

### Memory Leaks in CRDB Process
```
# Look for:
- Continuously growing memory usage
- goroutine leaks
- Heap growth without corresponding workload
```

**Example evidence:**
- Memory usage grows from 1GB to 20GB during test
- Goroutine count increases from 100 to 10,000
- No corresponding increase in workload

**Why it's a bug:** If CockroachDB is leaking memory during normal operation, it's a bug.

### Assertion Failures
```
# Look for:
- Assertion failed messages
- Invariant violations
- Consistency check failures
```

**Example evidence:**
- Assertion failed: expected x but got y
- Invariant violated: range count mismatch
- Consistency checker found error

**Why it's a bug:** Assertions and invariants should never fail - these indicate bugs.

## Gray Areas (Require Careful Analysis)

### Timeouts During Operation
Could be either:
- **Infrastructure flake** if network/VM issues caused the timeout
- **Test bug** if timeout is set too aggressively
- **Actual bug** if CRDB hung or became unresponsive

**How to distinguish:**
- Check system logs for infrastructure issues
- Check test code for timeout values
- Check CRDB logs for hangs or performance issues
- Look at Prometheus metrics for resource usage

### Connection Refused Errors
Could be either:
- **Infrastructure flake** if VM restarted or network failed
- **Actual bug** if CRDB crashed or became unresponsive

**How to distinguish:**
- Check journalctl for VM restart
- Check CRDB logs for crash or panic
- Check timing - did it happen during setup or during test?

### Performance Degradation
Could be either:
- **Infrastructure flake** if VM had resource contention
- **Test bug** if test expectations are unrealistic
- **Actual bug** if CRDB regressed in performance

**How to distinguish:**
- Check Prometheus metrics for resource usage
- Compare with historical test runs
- Check for recent CRDB changes
- Verify test expectations are reasonable

## Decision Framework

Use this framework to classify failures:

1. **Check system logs first** (journalctl, dmesg)
   - VM restart? → INFRASTRUCTURE_FLAKE
   - Disk full? → INFRASTRUCTURE_FLAKE
   - OOM killer? → Check what was killed

2. **Check test.log for failure location**
   - During setup? → Likely INFRASTRUCTURE_FLAKE or TEST_BUG
   - During test execution? → Could be any type

3. **Check CRDB logs for panics/crashes**
   - Panic in CRDB code? → ACTUAL_BUG
   - No panic but assertion failure? → ACTUAL_BUG

4. **Check test code**
   - Unrealistic timeout? → TEST_BUG
   - Failed to install dependency? → TEST_BUG

5. **Check for patterns in similar issues**
   - Same failure repeatedly? → Likely ACTUAL_BUG
   - Different failures on same test? → Likely TEST_BUG or INFRASTRUCTURE_FLAKE

6. **When in doubt, mark as uncertain**
   - Provide evidence for multiple possibilities
   - Explain what additional information would help
   - Recommend further investigation
