# Fixture: bad

Must produce **2** findings: one defined-but-undocumented group
(`PiBadUndocumented`, reported at `lua/pi/ui/highlights.lua` on its name line)
and one documented-but-undefined group (`PiBadStale`, reported at
`doc/highlight-groups.md` on its row). Both directions of the rule fire.
