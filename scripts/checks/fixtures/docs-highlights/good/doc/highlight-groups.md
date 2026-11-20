# Highlight groups (fixture)

Both groups below exist as `nvim_set_hl(0, "Pi…", …)` calls in
`lua/pi/ui/highlights.lua`, including the one written across several lines.

| Group | Role |
| --- | --- |
| `PiGoodInline` | Label defined on a single line |
| `PiGoodMultiline` | Label whose definition breaks the line right after `nvim_set_hl(` |

## Terminal colours in tool output (`PiAnsi*`)

`PiAnsi*` groups are generated dynamically, one per distinct ANSI style, and are
the one family that is prose-only: no table row is required for them, and the
`nvim_set_hl` calls that create them are out of scope for this rule.
