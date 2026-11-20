# No fences — nothing to scan

This skills tree has prose only: `pgrep -f` would be dangerous inline, but the
mention is outside a fence, so it is not a one-liner. With no shell fence at all
the rule has nothing to scan and must warn instead of reporting a clean tree.
