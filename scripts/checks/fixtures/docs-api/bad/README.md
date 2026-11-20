# Bad (fixture)

`M.hidden` exists in `lua/pi/init.lua` but is never documented, and `doc/api.md`
still advertises `pi.gone`, which the module no longer defines. One undocumented
function, one stale mention: two findings, both errors.
