# Fixture: good

Must produce **0** findings. Proves both directions are quiet on compliant code
and that the definition side is token-based: `PiGoodMultiline` puts its name on
the line after `nvim_set_hl(0,`, which a line-oriented regex would miss. Also
proves the `PiAnsi*` family exclusion — `lua/pi/ui/chat/ansi.lua` defines
`PiAnsiPending` literally (plus one name built by concatenation) and neither
needs a doc row.
