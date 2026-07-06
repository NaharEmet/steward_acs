#!/bin/bash
set -euo pipefail
# Trigger OpenCode to analyze Meta-Harness plan

PLAN_FILE=$(ls -t metaanalysis/plan_*.md 2>/dev/null | head -1)

if [ -z "$PLAN_FILE" ]; then
  echo "No plan file found"
  exit 1
fi

echo "Analyzing: $PLAN_FILE"

# Build prompt that tells opencode to:
# 1. Read the plan file
# 2. Use acs_query tool to run additional queries
# 3. Generate comprehensive improvement recommendations

opencode run --format json "
Read the file at: $PLAN_FILE

This is a Meta-Harness analysis plan from an Agent Coordination System (ACS).
The plan contains system telemetry data including tool performance, error patterns, and agent feedback.

Your task:
1. Review the data in the plan file
2. Run additional queries using the acs_query tool if helpful
3. Produce a comprehensive analysis with:
   - Top 3 critical issues (with root causes)
   - Specific actionable improvements (numbered)
   - Priority matrix (HIGH/MED/LOW with rationale)
   - Expected impact for each fix
   - Next steps (what to do first)

Output your analysis in clear markdown format.
" 2>&1