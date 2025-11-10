# Triage Workflow

This document describes the detailed step-by-step process for triaging a CockroachDB roachtest failure.

## 1. Download Artifacts (All-in-One)

Use the comprehensive download script that handles everything:

```bash
# Downloads and sets up complete workspace
bash .claude/hooks/triage-download.sh 157102
```

**What this script does:**
1. Parses the GitHub issue (extracts metadata, URLs, timestamps, SHA)
2. Creates workspace at `workspace/issues/$ISSUE_NUM/`
3. Downloads artifacts.zip from TeamCity
4. Automatically tries to download debug.zip
5. Extracts everything and cleans up zip files
6. **Checks out CRDB source code at the exact SHA** from the failure
7. Saves metadata.json for reference
8. **Skips download if workspace already exists** (instant!)
9. Shows you file locations and counts

**Output tells you:**
- Where the workspace is: `workspace/issues/157102`
- Where test.log is located
- How many files were extracted
- Whether debug.zip is available

**Manual parsing (if you need just metadata):**
```bash
# Just parse the issue without downloading
bash .claude/hooks/triage-helpers.sh 157102
```

## 2. Explore the Logs

Start with test.log, which is the primary source of information.

**Use the Read tool** to examine `workspace/issues/157102/test.log`. Look for:
- **Panic messages**: Stack traces, panic: statements
- **Fatal errors**: FATAL, fatal error
- **Failure messages**: The actual error that caused the test to fail
- **Timing**: When did the failure occur?

### Important: Follow the breadcrumbs!

Test logs often reference other files for details. For example:
- "See 1.journalctl.txt for system logs" → Read that file
- "Node 2 crashed, see logs/cockroach.log.2" → Read that file
- "OOM occurred on node 3, check 3.dmesg.txt" → Read that file
- "Full query log in roachtest.log" → Read that file
- "details in run_123514.268378320_n4_bash-c-sysbench-dbdr.log" → Read that file

**Pattern:** Error message in test.log → Points to specific file → Read that file for root cause

Don't stop at test.log - follow the error trail through referenced files to understand the complete failure.

Once you have gathered enough context about the error, be sure to look into the system and database log files as they might contain crucial information:
- {NODE_ID}.dmesg.txt
- {NODE_ID}.journalctl.txt
And the cockroachdb logs:
- `logs/{NODE_ID}.unredacted/*.log

## 2.5. Read the Test Source Code

The download script automatically checks out the CockroachDB source code at the exact SHA that failed. This is incredibly valuable for understanding:
- **What the test is trying to do** - Read the test implementation
- **Expected vs actual behavior** - Compare what should happen with what did happen
- **Error message context** - Find where error messages originate in the code

**Test code location**: `cockroachdb/pkg/cmd/roachtest/tests/`

**How to find the test:**
```bash
# Example: For test "roachtest.sysbench/oltp_point_select"
# Look for files matching the test name
find cockroachdb/pkg/cmd/roachtest/tests/ -name "*sysbench*"

# Or use Grep to search for the test name
# Use the Grep tool to search for the test registration
```

**What to look for in test code:**
- Test setup and configuration
- Workload parameters
- Expected failure conditions
- Known issues or TODOs
- Recent changes (if you suspect a regression)

### Grepping CRDB Source for Error Messages

When you find error messages in logs (especially unredacted logs in `artifacts/logs/{NODE_NUMBER}.unredacted/*.log`), you can grep the CRDB source code to understand where they come from:

```bash
# Example: Found "context deadline exceeded" in logs
# Use Grep tool to search cockroachdb/pkg/ for the error message

# This helps you find:
# - Which component generated the error
# - Stack traces and context
# - Related error handling code
# - Comments explaining the error condition
```

**Typical workflow:**
1. Find error message in test.log or node logs
2. Grep CRDB source for that error message
3. Read the source code around the error
4. Understand if it's expected behavior, a bug, or infrastructure issue
5. Check if test code has known issues or TODOs for this error

**Example:**
```
Error in log: "could not acquire lease on range 123"

1. Grep cockroachdb/pkg/ for "could not acquire lease"
2. Find it's in pkg/kv/kvserver/replica_lease.go
3. Read the code - is this a timeout? A conflict?
4. Check test code - does it set aggressive timeouts?
5. Decision: Likely timing issue in test, not a real bug
```

## 3. Identify Patterns

See [patterns.md](patterns.md) for detailed information about infrastructure flake and bug indicators.

## 4. Request Additional Files if Needed

If test.log doesn't give you enough information, look at:

```bash
# Find all available logs (from workspace/issues/$ISSUE_NUM/)
find . -name "*.journalctl.txt"  # System logs (good for VM issues)
find . -name "*.dmesg.txt"       # Kernel messages (OOM, disk issues)
find . -name "cockroach.log"     # CockroachDB logs
find . -name "*.stderr"          # Process error output
find . -name "*.log" | head -20  # All log files

# If debug.zip was downloaded, check the debug/ directory
find debug/ -type f              # Cluster info, goroutines, heap dumps
```

**What's in debug.zip (if available):**
- `nodes/*/goroutines.txt` - Goroutine dumps from each node (good for deadlocks, hangs)
- `nodes/*/heap.prof` - Heap profiles (memory issues)
- `nodes/*/stacks.txt` - Stack traces
- `cluster.json` - Cluster configuration
- `nodes/*/ranges.json` - Range distribution info

Use the Read tool to examine any relevant files. Don't try to read everything - focus on what's relevant to the failure.

## 5. Search for Similar Issues

**Always search for similar issues** to identify patterns and check if this is a known flake:

```bash
# Search for similar test failures
gh issue list --repo cockroachdb/cockroach \
  --label C-test-failure \
  --search "\"<test-name>\"" \
  --limit 10 \
  --json number,title,url,labels

# Look at a specific similar issue
gh issue view <issue-number> --repo cockroachdb/cockroach
```

This helps you:
- Identify recurring patterns
- See if this is a known flake
- Find related bugs

## 6. Determine Team Assignment

See [teams.md](teams.md) for detailed team assignment guidelines.

## 7. Present Your Findings

Format your analysis as:

```
## Analysis Summary

**Classification:** INFRASTRUCTURE_FLAKE | TEST_BUG | ACTUAL_BUG
**Confidence:** 0.0 - 1.0

**Test Information:**
- Test: <test-name>
- Issue: #<number>
- Release: <release>
- SHA: <sha>

**Recommended Team:** <T-team-name>
**Team Confidence:** 0.0 - 1.0

## Evidence

<List the key evidence you found>

## Reasoning

<Explain your classification>

## Team Assignment Reasoning

<Explain why this team should handle it>

## Files Analyzed

<List the files you examined>

## Recommendations

<Any suggestions for next steps>
```

## 8. Save Your Analysis

Use the Write tool to create a triage summary file at `workspace/issues/$ISSUE_NUM/TRIAGE.md` with your findings.

The summary should include:
- **Classification**: INFRASTRUCTURE_FLAKE, TEST_BUG, or ACTUAL_BUG
- **Confidence**: Your confidence level (0.0 - 1.0)
- **Summary**: Brief explanation of the failure
- **Evidence**: Key evidence from logs
- **Recommended Team**: Which team should handle this

**Example format:**
```markdown
# Triage Summary - Issue #157102

**Date:** 2025-01-15 14:30:00 PST
**Classification:** INFRASTRUCTURE_FLAKE
**Confidence:** 0.85
**Recommended Team:** test-eng

## Summary

The test failed due to a VM restart during execution. The CockroachDB cluster was healthy
before the restart, and the failure occurred when the test tried to connect to a node
that had just been forcibly restarted by the cloud provider.

## Evidence

1. **VM Restart in journalctl.txt**:
   - Line 1234: "systemd[1]: Stopping CockroachDB..."
   - Line 1235: "kernel: Power button pressed"

2. **Test log shows connection refused**:
   - Line 567: "dial tcp 10.0.0.5:26257: connect: connection refused"

3. **Timing correlation**:
   - VM restart: 10:15:32
   - Test failure: 10:15:33 (1 second after restart)

## Recommendation

Close as infrastructure flake. The test was working correctly until the VM was restarted
by the infrastructure. No bug in CockroachDB code or test logic.

---
*Generated by Claude Code Triage System*
```

## 9. Cleanup

After saving your analysis, restore the CockroachDB submodule to master:

```bash
# Restore submodule to master (works from anywhere in the repo)
source .claude/hooks/triage-helpers.sh && restore_source_code
```

This ensures the submodule is left in a clean state for the next triage session.

**Note**: If you see `[WARN] Could not restore to master (this is okay)` - this is expected and harmless. It just means the submodule was already on master or doesn't have a master branch.

## Tips for Accurate Triage

1. **Read test.log thoroughly** - The answer is usually there
2. **Look for timestamps** - When did things go wrong?
3. **Check for VM/infrastructure messages** - Common cause of flakes
4. **Examine stack traces carefully** - Shows which CRDB code is involved
5. **Compare with similar issues** - Patterns emerge
6. **Be conservative** - If unsure, say so and explain why
7. **Provide evidence** - Quote relevant log lines
8. **Consider timing** - Did it fail during setup or during the actual test?
