#!/bin/bash
# Skill activation hook - checks if user prompt matches skill triggers
# Pure bash implementation - no Node.js required

set -e

# Read hook input from stdin
input=$(cat)

# Extract prompt from JSON (lowercase for case-insensitive matching)
prompt=$(echo "$input" | jq -r '.prompt // ""' | tr '[:upper:]' '[:lower:]')

# Exit if no prompt
[[ -z "$prompt" ]] && exit 0

# Load skill rules
rules_file="${CLAUDE_PROJECT_DIR}/.claude/skills/skill-rules.json"
[[ ! -f "$rules_file" ]] && exit 0

# Function to check if prompt contains any keyword
check_keywords() {
    local skill_name="$1"
    local keywords
    keywords=$(jq -r ".skills.${skill_name}.promptTriggers.keywords[]? // empty" "$rules_file")

    while IFS= read -r keyword; do
        [[ -z "$keyword" ]] && continue
        # Convert keyword to lowercase for case-insensitive match
        keyword_lower=$(echo "$keyword" | tr '[:upper:]' '[:lower:]')
        if [[ "$prompt" == *"$keyword_lower"* ]]; then
            return 0  # Match found
        fi
    done <<< "$keywords"

    return 1  # No match
}

# Function to check if prompt matches any intent pattern (regex)
check_intent_patterns() {
    local skill_name="$1"
    local patterns
    patterns=$(jq -r ".skills.${skill_name}.promptTriggers.intentPatterns[]? // empty" "$rules_file")

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        # Use grep for regex matching (case-insensitive)
        if echo "$prompt" | grep -qiE "$pattern"; then
            return 0  # Match found
        fi
    done <<< "$patterns"

    return 1  # No match
}

# Arrays to hold matched skills by priority
declare -a critical_skills=()
declare -a high_skills=()
declare -a medium_skills=()
declare -a low_skills=()

# Get all skill names
skill_names=$(jq -r '.skills | keys[]' "$rules_file")

# Check each skill for matches
while IFS= read -r skill_name; do
    [[ -z "$skill_name" ]] && continue

    # Check if skill has triggers
    has_triggers=$(jq -r ".skills.${skill_name}.promptTriggers // empty" "$rules_file")
    [[ -z "$has_triggers" || "$has_triggers" == "null" ]] && continue

    # Check for keyword or intent pattern match
    matched=false
    if check_keywords "$skill_name" || check_intent_patterns "$skill_name"; then
        matched=true
    fi

    # If matched, add to appropriate priority array
    if [[ "$matched" == "true" ]]; then
        priority=$(jq -r ".skills.${skill_name}.priority // \"medium\"" "$rules_file")
        case "$priority" in
            critical)
                critical_skills+=("$skill_name")
                ;;
            high)
                high_skills+=("$skill_name")
                ;;
            medium)
                medium_skills+=("$skill_name")
                ;;
            low)
                low_skills+=("$skill_name")
                ;;
        esac
    fi
done <<< "$skill_names"

# Generate output if any matches found
total_matches=$((${#critical_skills[@]} + ${#high_skills[@]} + ${#medium_skills[@]} + ${#low_skills[@]}))

if [[ $total_matches -gt 0 ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎯 SKILL ACTIVATION CHECK"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Critical skills
    if [[ ${#critical_skills[@]} -gt 0 ]]; then
        echo "⚠️ CRITICAL SKILLS (REQUIRED):"
        for skill in "${critical_skills[@]}"; do
            echo "  → $skill"
        done
        echo ""
    fi

    # High priority skills
    if [[ ${#high_skills[@]} -gt 0 ]]; then
        echo "📚 RECOMMENDED SKILLS:"
        for skill in "${high_skills[@]}"; do
            echo "  → $skill"
        done
        echo ""
    fi

    # Medium priority skills
    if [[ ${#medium_skills[@]} -gt 0 ]]; then
        echo "💡 SUGGESTED SKILLS:"
        for skill in "${medium_skills[@]}"; do
            echo "  → $skill"
        done
        echo ""
    fi

    # Low priority skills
    if [[ ${#low_skills[@]} -gt 0 ]]; then
        echo "📌 OPTIONAL SKILLS:"
        for skill in "${low_skills[@]}"; do
            echo "  → $skill"
        done
        echo ""
    fi

    echo "ACTION: Use Skill tool BEFORE responding"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

exit 0
