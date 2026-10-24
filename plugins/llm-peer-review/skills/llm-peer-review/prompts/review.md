<task>
Review the code described under "Review target" for concrete correctness bugs, race conditions, lock-ordering problems, security issues, non-atomic file operations, crashes, and invariant violations. Ignore style and naming.
Target: {{TARGET_LABEL}}
User focus: {{USER_FOCUS}}
</task>

<review_target>
{{TARGET_BLOCK}}
</review_target>

<review_method>
You are a standalone reviewer. Read the code yourself; do not launch other reviewers or agents.
Do not modify, create, delete, format, stage or commit files.
If the review target names a diff file, read that file first, then read the changed files and the code around them to confirm each finding in context.
</review_method>

<grounding_rules>
Every finding must be defensible from the code you actually read.
Do not invent files, lines, code paths, or runtime behavior you cannot support.
If a conclusion depends on an inference, state that explicitly in the finding `body` and lower the `confidence` score accordingly.
</grounding_rules>

<calibration_rules>
Prefer one strong, well-supported finding over several weak ones.
Do not dilute serious issues with filler.
If the code looks safe, say so directly and return no findings.
</calibration_rules>

<structured_output_contract>
Return only JSON matching the provided schema, with no text before or after it.
Every finding must include the affected file, `line_start` and `line_end`, a confidence score from 0 to 1, and a concrete recommendation.
List every file or area you inspected in `checked`.
</structured_output_contract>
