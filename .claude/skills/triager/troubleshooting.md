# Troubleshooting Guide

This document covers common issues you might encounter during triage and how to solve them.

## Common Script Issues

### Issue: "BASH_SOURCE[0]: parameter not set"
**Cause:** Trying to source the helper script with strict mode enabled.

**Solution:** Run the script directly instead of sourcing it:
```bash
bash .claude/hooks/triage-helpers.sh 157102
```

### Issue: "no such file or directory: workspace/issues/..."
**Cause:** Working directory is wrong or workspace doesn't exist.

**Solution:** Always use absolute paths or create directory first:
```bash
mkdir -p workspace/issues/$ISSUE_NUM
cd workspace/issues/$ISSUE_NUM  # Now you're in the right place
```

### Issue: "artifacts.zip and ... are identical"
**Cause:** Trying to move file onto itself.

**Solution:** You're already in the right directory, just extract:
```bash
# Already downloaded to correct location? Just extract:
unzip -q artifacts.zip && rm artifacts.zip
```

### Issue: JSON parsing fails with jq
**Cause:** Colored output from helper script contains ANSI codes.

**Solution:** Filter to just the JSON part:
```bash
bash .claude/hooks/triage-helpers.sh 157102 2>&1 | grep -A 20 "^{" | grep -B 20 "^}"
```

## Prometheus Metrics Issues

### Issue: Metrics access failing
**Causes:**
- Not logged into gcloud
- Missing IAP permissions
- Wrong Prometheus URL

**Solutions:**
```bash
# 1. Ensure you're logged into gcloud
gcloud auth login

# 2. Check your account
gcloud config get-value account

# 3. Verify IAP permissions for test-eng infrastructure
# (Contact test-eng if you don't have access)

# 4. Try setting IAP_TOKEN manually if auto-generation fails
export IAP_TOKEN="your_token_here"
```

### Issue: "No cluster found" when querying Prometheus
**Causes:**
- Test name not sanitized correctly
- Wrong test_run_id
- Metrics not available for this test

**Solutions:**
```bash
# 1. Verify test name is sanitized
sanitized_test_name=$(sanitize_test_name "$test_name")
echo "Sanitized: $sanitized_test_name"

# 2. Verify test_run_id from Grafana URL
# Should match: teamcity-XXXXXXX

# 3. Check if Grafana URL exists in metadata
jq -r '.grafana_url' workspace/issues/$ISSUE_NUM/metadata.json

# 4. If Grafana URL is missing, metrics may not be available
```

### Issue: "parse error: unknown function with name \"label_values\""
**Cause:** Using Grafana template function in PromQL query.

**Solution:** Use actual PromQL query instead:
```bash
# Wrong: label_values(...)
# Correct: sys_uptime{...}

# Then extract label from result:
cluster=$(query_prometheus "$start" "$end" "$query" | jq -r '.data.result[0].metric.cluster')
```

## Download Issues

### Issue: Download fails with "TEAMCITY_TOKEN not set"
**Cause:** TeamCity token not configured.

**Solution:**
```bash
export TEAMCITY_TOKEN="your_teamcity_token"
```

### Issue: Download fails with "Could not extract TeamCity artifacts URL"
**Cause:** Issue doesn't have the expected roachtest comment format.

**Solution:**
1. Check the issue manually for the roachtest comment
2. Verify the comment contains TeamCity artifacts URL
3. If format is different, you may need to update the regex in `triage-helpers.sh`

### Issue: Debug.zip not found (but this is normal)
**Cause:** Not all tests produce debug.zip files.

**Solution:** This is expected and normal. The script will continue without it. You'll see:
```
No debug.zip available (this is normal)
```

## Source Code Checkout Issues

### Issue: "Could not fetch SHA: <sha>"
**Causes:**
- SHA doesn't exist in repository
- Network issues
- Wrong submodule configuration

**Solutions:**
```bash
# 1. Verify submodule is initialized
git submodule update --init --recursive

# 2. Check if SHA exists
cd cockroachdb
git cat-file -e <sha>^{commit}

# 3. Try fetching manually
git fetch origin <sha> --depth 1

# 4. If all else fails, fetch full history
git fetch --unshallow
```

### Issue: "Not in a git repository" when restoring
**Cause:** Running restore from wrong directory.

**Solution:** Run from the triage project root:
```bash
cd /path/to/triage
source .claude/hooks/triage-helpers.sh && restore_source_code
```

## GitHub CLI Issues

### Issue: "gh: command not found"
**Cause:** GitHub CLI not installed.

**Solution:**
```bash
brew install gh
gh auth login
```

### Issue: "gh: Not Authorized"
**Cause:** Not logged into GitHub CLI.

**Solution:**
```bash
gh auth login
```

## Log File Issues

### Issue: Can't find test.log
**Cause:** Artifacts extracted to unexpected location.

**Solution:**
```bash
# Search for test.log
find workspace/issues/$ISSUE_NUM -name "test.log"

# Use the helper function
source .claude/hooks/triage-helpers.sh
find_test_log workspace/issues/$ISSUE_NUM
```

### Issue: Log file is too large to read
**Cause:** File exceeds Read tool limits.

**Solution:**
```bash
# Read in chunks using offset and limit
# Use Read tool with offset=0, limit=2000 for first 2000 lines
# Then offset=2000, limit=2000 for next 2000 lines, etc.
```

### Issue: Referenced log file not found
**Cause:** Log filename in test.log doesn't match actual file.

**Solution:**
```bash
# Search for similar filenames
find workspace/issues/$ISSUE_NUM -name "*journalctl*"
find workspace/issues/$ISSUE_NUM -name "*dmesg*"

# List all log files
find workspace/issues/$ISSUE_NUM -name "*.log"
```

## Analysis Issues

### Issue: Can't determine if it's a flake or bug
**Cause:** Unclear evidence or mixed signals.

**Solution:**
1. Be honest about uncertainty
2. Provide confidence < 0.7
3. List evidence for both possibilities
4. Search for similar issues to find patterns
5. Recommend further investigation

### Issue: Multiple possible root causes
**Cause:** Complex failure with cascading effects.

**Solution:**
1. Identify primary vs secondary failures
2. Use timestamps to determine order of events
3. Look for the **first** failure in logs
4. Explain the chain of causation
5. Classify based on primary root cause

### Issue: No clear team assignment
**Cause:** Failure spans multiple subsystems.

**Solution:**
1. Choose the most likely team (primary)
2. List alternative teams (secondary)
3. Explain reasoning for each
4. Use confidence levels
5. Suggest the primary team can re-assign if needed

## Tool Availability

### Environment Tools

You have access to these tools:
- **Bash**: Run shell commands
- **Read**: Read file contents (use this instead of cat)
- **Edit**: Edit file contents
- **Write**: Write new files
- **Grep**: Search for patterns in files
- **Glob**: Find files by pattern
- **gh** (GitHub CLI): Query issues, comments
- **jq**: Parse JSON
- **grep**, **sed**, **awk**: Text processing (via Bash)
- **find**: Search for files (via Bash)

**Important**: Always prefer specialized tools over bash commands:
- Use **Read** instead of `cat`
- Use **Grep** instead of `grep` command
- Use **Glob** instead of `find` for pattern matching

## When to Ask for Help

Ask the user for clarification when:
1. Issue format is unusual and parsing fails
2. Multiple conflicting pieces of evidence
3. Unclear what the test is supposed to do
4. Need domain expertise about specific subsystem
5. Metrics show unexpected patterns

Ask the user to provide:
1. Additional context about the test
2. Recent changes that might be related
3. Whether this is a new or existing test
4. Expected vs actual behavior
5. History of similar failures

## Performance Tips

### Speed Up Triage

1. **Use the download script** - Don't manually parse and download
   ```bash
   bash .claude/hooks/triage-download.sh <issue>
   ```

2. **Start with test.log** - Usually contains the key information

3. **Follow references** - Don't read all logs, follow breadcrumbs

4. **Search for similar issues early** - Patterns save time

5. **Use Read tool efficiently** - Read specific sections, not entire huge files

### Avoid Common Mistakes

1. **Don't read all logs** - Focus on relevant ones
2. **Don't skip similar issue search** - Patterns are valuable
3. **Don't guess test intent** - Read the test source code
4. **Don't ignore timestamps** - Timing is crucial
5. **Don't over-commit on uncertain classifications** - Be honest about confidence

## Getting More Help

If you encounter issues not covered here:

1. **Check the helper script source** - Comments explain functions
   ```bash
   cat .claude/hooks/triage-helpers.sh
   ```

2. **Test individual functions** - Source and run manually
   ```bash
   source .claude/hooks/triage-helpers.sh
   parse_github_issue 157102
   ```

3. **Check the test metrics script** - See how things work end-to-end
   ```bash
   bash .claude/hooks/test-metrics.sh 157102
   ```

4. **Consult documentation** - Check README and skill files

5. **Ask the user** - They may have insights or workarounds
