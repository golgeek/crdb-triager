# CockroachDB Roachtest Triage Assistant

An AI-powered triage assistant for analyzing CockroachDB roachtest failures. This system combines Claude Code with expert triage knowledge to help you quickly classify test failures and determine root causes.

## What It Does

This tool helps you analyze CockroachDB nightly test failures to determine:
- **Infrastructure flakes** - VM issues, network problems, disk full, OOM kills, etc.
- **Product bugs** - Real regressions or bugs in CockroachDB code that need team assignment

The triager works **interactively** - you drive the conversation, ask questions, and guide the analysis. Claude Code acts as your expert assistant, not a fully automated system.

## How It Works

**You're in control.** The triager is an interactive assistant that:

1. **Activates automatically** when you mention triage keywords or issue numbers
2. **Downloads artifacts** - TeamCity logs, debug.zip, source code at the exact SHA
3. **Analyzes intelligently** - Reads logs, examines test source, searches for similar issues
4. **Responds to your guidance** - "Check the journalctl logs", "Grep CRDB source for that error", "What does the test code do?"
5. **Provides structured analysis** - Classification, confidence, evidence, team assignment

**This is NOT autopilot.** You make the final call on:
- Whether it's a flake or bug
- Release-blocker status
- Confidence levels
- When to dig deeper vs when you have enough context

## Quick Start

### Prerequisites

You'll need these tools installed:

```bash
# GitHub CLI (for fetching issue data)
brew install gh
gh auth login

# jq (for JSON parsing)
brew install jq

# gcloud (for Prometheus metrics access via IAP)
gcloud auth login

# Git (for source code submodule)
git submodule update --init --recursive
```

**Environment variables:**

```bash
# Required - get this from TeamCity
export TEAMCITY_TOKEN="your_teamcity_token_here"

# Optional - gh CLI handles this automatically
export GITHUB_TOKEN="your_github_token"
```

### Usage

Just start a conversation with Claude Code in the root of this repository
and mention what you want to triage:

```
You: Triage issue #157102

Claude: 🎯 SKILL ACTIVATION CHECK
        📚 RECOMMENDED SKILLS: triager

        I'll help you triage this issue. Let me start by downloading
        the artifacts and analyzing the failure...
```

The triager automatically:
- Parses the GitHub issue
- Downloads TeamCity artifacts to `workspace/issues/157102/`
- Checks out CockroachDB source at the failing SHA
- Reads logs and provides initial analysis

**Then you drive the conversation:**

```
You: Check the journalctl logs for OOM

You: Grep the CRDB source for that error message

You: What does the test code actually do?

You: Search for similar failures in the past month

You: Is this a release blocker?
```

The assistant responds to your requests and helps you build up context until you're confident in the classification.

## What Gets Analyzed

When you triage an issue, the assistant has access to:

**Artifacts downloaded automatically:**
- `test.log` - Main test output (usually the smoking gun)
- `test.xml` - Structured test results
- `debug.zip` - System logs from all nodes (journalctl, dmesg, CockroachDB logs)
- Node-specific logs: `{NODE_ID}.dmesg.txt`, `{NODE_ID}.journalctl.txt`
- CockroachDB logs: `logs/{NODE_ID}.unredacted/*.log`

**Source code at exact SHA:**
- Test source: `cockroachdb/pkg/cmd/roachtest/tests/`
- Full CockroachDB source for grepping error messages

**External context:**
- Similar issues via GitHub search
- Team ownership mappings
- Prometheus metrics (OOM, CPU, disk space) via IAP-authenticated queries

**Expert knowledge:**
- Infrastructure flake patterns (OOM kills, disk full, network issues)
- Release-blocker criteria
- Team assignment logic

## Example: Interactive Triage Session

Here's what a typical triage session looks like:

```
You: Triage issue #157102

Claude: [Downloads artifacts, reads test.log]

        Initial analysis: Test failed with "context deadline exceeded"
        Let me check if this is an infrastructure issue...

You: Check the system logs for OOM

Claude: [Reads journalctl logs]

        Found evidence of OOM kill at 10:45:23 UTC
        Node n3 was killed by the kernel with exit code 137

You: Is this a release blocker?

Claude: No, this is an infrastructure flake (OOM kill).
        Confidence: 0.95

        Evidence:
        - Kernel OOM killer invoked
        - No product code changes could prevent this
        - Test passed on retry

        Classification: INFRASTRUCTURE_FLAKE
        Team: Test Platform (for investigation of resource limits)
```

**You drive the depth of analysis.** Ask follow-up questions, request specific log files, or ask Claude to grep the source code for error messages.

## Tips for Effective Triage

1. **Let the skill activate** - When you mention "triage" or an issue number, let Claude load the skill
2. **Guide the analysis** - You know what to look for; ask specific questions
3. **Check system logs** - OOM kills, disk full, and network issues hide in journalctl/dmesg
4. **Read test source** - Understanding test intent helps classify failures
5. **Search for patterns** - Ask Claude to find similar historical issues
6. **Be pragmatic** - Don't spend 30 minutes on an obvious flake
7. **Use Prometheus** - Memory/CPU metrics can confirm OOM or resource starvation
8. **Trust your judgment** - The assistant provides evidence; you make the final call

## Why This Works Better Than Automation

**The old approach (Go tool with fixed prompts):**
- Rigid workflow couldn't adapt to different failure types
- Token limits forced chunking and information loss
- No ability to ask follow-up questions
- Generic analysis that missed nuance

**The triager skill approach:**
- You steer based on your expertise
- Full context window (200K tokens) - read entire logs
- Interactive: "check this", "grep for that", "what does the test do?"
- Learns from your guidance during the session
- Handles edge cases through conversation

Think of it as **pair programming for triage** - you're the expert, Claude is your assistant with perfect memory and the ability to instantly search thousands of lines of logs.

## Under the Hood

**Components:**

- `.claude/skills/triager/` - Expert knowledge base (workflow, patterns, teams)
- `.claude/hooks/triage-helpers.sh` - Bash utilities for downloading artifacts
- `.claude/hooks/skill-activation-prompt.sh` - Auto-activates skill on triage keywords
- `cockroachdb/` - Source code submodule (auto-checked-out at failure SHA)
- `workspace/issues/*/` - Per-issue workspace for artifacts and analysis

**Dependencies:**

- `gh` - GitHub CLI for issue data
- `jq` - JSON parsing in bash scripts
- `gcloud` - IAP token generation for Prometheus access
- `git` - Source code submodule management

## Troubleshooting

**Skill not activating?**
- Use explicit keywords: "triage issue #12345" or "analyze test failure"
- Check [.claude/skills/skill-rules.json](.claude/skills/skill-rules.json) for trigger patterns

**Artifacts download failing?**
- Verify `TEAMCITY_TOKEN` environment variable is set
- Check the TeamCity artifact URL is accessible
- Ensure sufficient disk space in `workspace/`

**Prometheus metrics access failing?**
- Run `gcloud auth login` to authenticate
- Verify your account has IAP permissions for test infrastructure
- Test with: `bash .claude/hooks/test-metrics.sh <issue-number>`

**Source code checkout issues?**
- Ensure git submodule is initialized: `git submodule update --init`
- Check network access to github.com/cockroachdb/cockroach

## Advanced: Customizing the Skill

The skill knowledge lives in [.claude/skills/triager/](.claude/skills/triager/):

- [workflow.md](.claude/skills/triager/workflow.md) - Modify the triage workflow
- [patterns.md](.claude/skills/triager/patterns.md) - Add new flake/bug patterns you discover
- [teams.md](.claude/skills/triager/teams.md) - Update team ownership mappings
- [prometheus.md](.claude/skills/triager/prometheus.md) - Add new metric queries

**The best part:** You can edit these files during a triage session and the skill will use the updated knowledge immediately in the next conversation.

## Why a Skill Instead of an Agent?

This system is intentionally built as a **skill** (expert knowledge base) rather than an **agent** (autonomous workflow):

**Skills are better for triage because:**
- You're the domain expert - the skill augments your knowledge
- Every failure is different - rigid workflows can't handle edge cases
- Human judgment is critical for release-blocker decisions
- Interactive guidance beats automation for complex analysis

**You maintain control:**
- "Check this specific log file"
- "Grep the source for this error"
- "Is this similar to issue #123456?"
- Make the final call on classification and confidence

Think of it as an expert assistant, not autopilot.

## License

Built for CockroachDB test infrastructure. Adapt freely for your own use cases.
