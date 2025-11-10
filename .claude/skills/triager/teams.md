# Team Assignment Guide

This document helps you determine which CockroachDB team should handle a particular failure.

## Available Teams

These team names come from `cockroachdb/pkg/cmd/roachtest/registry/owners.go`:

### Data & Streaming Teams
- **`cdc`** - Change Data Capture and streaming
  - Changefeeds
  - CDC sinks
  - Data streaming

- **`disaster-recovery`** - Backup, restore, replication
  - BACKUP/RESTORE
  - Cluster-to-cluster replication
  - Recovery procedures

### Core Infrastructure Teams
- **`kv`** - Key-Value store core functionality
  - Raft consensus
  - Replication
  - Transaction layer
  - Concurrency control

- **`admission-control`** - Admission control and resource management
  - Flow control
  - Resource scheduling
  - QoS

- **`storage`** - Storage engine, disk management, Pebble
  - Pebble storage engine
  - Disk I/O
  - Compactions, flushes
  - LSM management

- **`server`** - Database server management and core infrastructure
  - Server lifecycle
  - Node management
  - Cluster settings

### SQL Teams
- **`sql-foundations`** - SQL core, catalog, schema changes, privileges
  - Schema changes (DDL)
  - Catalog operations
  - Privileges and RBAC
  - Database/schema management

- **`migrations`** - Schema migrations and DDL operations
  - Online schema changes
  - Migration tooling
  - DDL coordination

- **`sql-queries`** - SQL query processing, execution plans, optimization
  - Query execution
  - Query optimizer
  - Execution plans
  - SQL performance

### Observability Teams
- **`obs-prs`** - Observability (Puerto Rico team)
  - Metrics
  - Logging
  - Tracing
  - Monitoring

- **`obs-india-prs`** - Observability (India team)
  - Metrics
  - Logging
  - Tracing
  - Monitoring

### Other Teams
- **`product-security`** - Security, authentication, authorization
  - Authentication
  - Authorization
  - Encryption
  - Security features

- **`release-eng`** - Release engineering and CI/CD
  - Build system
  - Release process
  - CI/CD pipeline

- **`test-eng`** - Test infrastructure and roachtest framework
  - Roachtest framework
  - Test infrastructure
  - Test tooling

- **`dev-inf`** - Developer infrastructure and tooling
  - Developer tools
  - Development workflow
  - Build tooling

- **`field-engineering`** - Field engineering and customer-facing tools
  - Customer tools
  - Field support
  - Integration tools

## Team Assignment Logic

### By Error Location (Stack Traces)

If you have a stack trace, use the package path to determine the team:

- `pkg/kv/` → **kv**
- `pkg/sql/` → **sql-queries** or **sql-foundations** (see SQL subsystem rules)
- `pkg/storage/` → **storage**
- `pkg/ccl/changefeedccl/` → **cdc**
- `pkg/ccl/backupccl/` → **disaster-recovery**
- `pkg/server/` → **server**
- `pkg/util/admission/` → **admission-control**

### SQL Subsystem Rules

For SQL-related failures, distinguish between:

**sql-foundations:**
- Schema changes (ALTER, CREATE, DROP)
- Catalog operations
- Privilege/RBAC issues
- Database/schema management

**sql-queries:**
- Query execution errors
- Query planning issues
- Performance problems
- Query timeout/hang

**migrations:**
- Online schema change issues
- Migration-specific failures
- DDL coordination problems

### By Test Type

If the test name indicates a specific area:

- `backup*`, `restore*` → **disaster-recovery**
- `cdc*`, `changefeed*` → **cdc**
- `admission*` → **admission-control**
- `schemachange*` → **sql-foundations** or **migrations**
- `tpcc*`, `tpch*`, `kv*` → **sql-queries** or **kv**
- `encryption*`, `auth*` → **product-security**

### By Failure Type

**Infrastructure flakes:**
- VM/network issues → **test-eng**
- TeamCity problems → **test-eng**
- Test timeout/setup issues → **test-eng**

**Test bugs:**
- Roachtest framework → **test-eng**
- Test logic errors → **test-eng** (or original test author if known)

**Performance issues:**
- Query performance → **sql-queries**
- Replication performance → **kv**
- Disk I/O performance → **storage**
- Admission control → **admission-control**

## GitHub Label Format

**Note:** These team names are used in roachtest ownership, not necessarily GitHub labels. For GitHub issues, prefix with `T-`:

- roachtest team `kv` → GitHub label `T-kv`
- roachtest team `sql-queries` → GitHub label `T-sql-queries`
- etc.

## Decision Tree

Use this decision tree when assigning teams:

```
1. Is it an infrastructure flake?
   YES → test-eng
   NO → Continue

2. Is it a test bug?
   YES → test-eng
   NO → Continue

3. Do you have a stack trace?
   YES → Use package path to determine team
   NO → Continue

4. Is it a SQL error?
   YES →
     - Schema change? → sql-foundations or migrations
     - Query execution? → sql-queries
     - Unclear? → sql-foundations
   NO → Continue

5. Is it a replication/consistency issue?
   YES → kv
   NO → Continue

6. Is it a storage/disk issue?
   YES → storage
   NO → Continue

7. Is it a backup/restore issue?
   YES → disaster-recovery
   NO → Continue

8. Is it a CDC/changefeed issue?
   YES → cdc
   NO → Continue

9. Is it a performance issue?
   YES →
     - Query performance? → sql-queries
     - Replication performance? → kv
     - Disk I/O? → storage
     - Admission control? → admission-control
   NO → Continue

10. Still unclear?
    → Assign to server (catch-all for general issues)
    → Add detailed reasoning in your analysis
```

## Examples

### Example 1: SQL Panic
```
Stack trace: pkg/sql/opt/exec/execbuilder/relational.go:123

→ Team: sql-queries
→ Reason: Stack trace shows SQL optimizer/execution code
```

### Example 2: Replication Issue
```
Error: "could not acquire lease on range 123"
Stack trace: pkg/kv/kvserver/replica_lease.go

→ Team: kv
→ Reason: Lease acquisition is a KV layer responsibility
```

### Example 3: Schema Change Failure
```
Error: "cannot drop column while index backfill in progress"
Test: schemachange/mixed-version

→ Team: migrations or sql-foundations
→ Reason: Schema change coordination issue
```

### Example 4: Backup Failure
```
Test: backup/mixed-version
Error: "failed to write backup descriptor"

→ Team: disaster-recovery
→ Reason: Backup functionality
```

### Example 5: VM Restart
```
Error: "connection refused"
Evidence: VM restarted during test (journalctl)

→ Team: test-eng
→ Reason: Infrastructure flake
```

### Example 6: Changefeed Delay
```
Test: cdc/bank
Error: "changefeed fell behind"

→ Team: cdc
→ Reason: CDC functionality
```

## Confidence Levels

When assigning teams, also provide a confidence level:

- **0.9-1.0**: Very clear from stack trace or test type
- **0.7-0.9**: Strong evidence from error messages or failure pattern
- **0.5-0.7**: Reasonable inference from test name or symptoms
- **0.3-0.5**: Educated guess based on partial information
- **0.0-0.3**: Very uncertain, multiple teams could be responsible

**Always explain your reasoning**, especially for confidence < 0.7.

## Multiple Teams

Sometimes an issue involves multiple teams. In this case:
1. Choose the **primary** team (most likely root cause)
2. Mention **secondary** teams in your analysis
3. Explain why multiple teams might be involved

Example:
```
Primary Team: kv (0.7)
Secondary Team: storage (0.5)

Reasoning: The failure appears to be in range replication (KV),
but there are also Pebble errors in the logs (storage). The
replication issue likely triggered the storage errors as a
secondary effect.
```

## When Uncertain

If you're uncertain about team assignment:
1. Provide your best guess with confidence < 0.7
2. List alternative teams and why they might be responsible
3. Explain what additional information would help
4. Suggest looking at similar issues to find patterns

Remember: It's better to be honest about uncertainty than to guess incorrectly!
