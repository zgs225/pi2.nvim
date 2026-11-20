-- Prerequisite handling shared by the hermetic e2e scripts (`tests/*_e2e.lua`).
--
-- `make e2e` is a CI gate, so "a prerequisite is missing" must not read as green:
-- a script that prints `[SKIP] …` and then exits 0 reports coverage that never
-- ran. That is the false-green class of G25, and exactly what happened to
-- `tests/resume_partitions_e2e.lua` in CI (Gitea #125) — the only layer that
-- renders the resume picker with the REAL telescope picker was skipped every run
-- while `make e2e` printed `all 9 script(s) passed`.
--
-- The run is graded by **exit code**, never by grepping output:
--
--   | code | meaning                                                        |
--   |------|----------------------------------------------------------------|
--   | 0    | every assertion ran and passed                                 |
--   | 1    | at least one assertion failed                                  |
--   | 2    | a prerequisite is missing and `PI_E2E_REQUIRE_DEPS=1` (gate)    |
--   | 3    | a prerequisite is missing, gate mode off (a local run may skip) |
--
-- `PI_E2E_REQUIRE_DEPS=1` is what CI sets, so a missing dependency is red there
-- while a developer without the optional checkout can still run the layer
-- locally. `make e2e` counts exit 3 separately and says so in its summary.
--
-- Loaded from a script that `make e2e` runs as
-- `nvim --headless -u tests/minimal_init.lua -l tests/<name>_e2e.lua`:
-- `minimal_init.lua` puts this directory on `package.path`, so
--
--     local deps = require("e2e_deps")
--
-- works from any cwd.

local M = {}

---Whether a missing prerequisite is fatal for this run. CI sets it.
---@type boolean
M.require_deps = vim.env.PI_E2E_REQUIRE_DEPS == "1"

---Stop the script: a prerequisite the whole script needs is missing.
---
---Exits 2 under `PI_E2E_REQUIRE_DEPS=1` (the gate must not pass on a skip) and 3
---otherwise (a local run without the optional checkout prints the reason and
---`make e2e` counts it as skipped).
---@param reason string
---@return nil
function M.skip(reason)
    print("[SKIP] " .. reason)
    if M.require_deps then
        print("[FAIL] " .. reason .. " — PI_E2E_REQUIRE_DEPS=1 forbids skipping")
        vim.cmd("cq 2")
    end
    print("e2e: skipped (set PI_E2E_REQUIRE_DEPS=1 to make a skip fatal)")
    vim.cmd("cq 3")
end

---A prerequisite for ONE later assertion: the rest of the script still runs.
---
---Returns `false` only when the skip is not allowed (gate mode), so the caller
---records a failure for the assertion it could not exercise instead of leaving a
---half-run script green.
---@param reason string
---@return boolean allowed
function M.skip_part(reason)
    print("[SKIP] " .. reason)
    if M.require_deps then
        print("[FAIL] " .. reason .. " — PI_E2E_REQUIRE_DEPS=1 forbids a partial run")
        return false
    end
    return true
end

---True when `path` is a directory; otherwise records the missing prerequisite.
---@param path string
---@param reason string
---@return boolean present
function M.require_dir(path, reason)
    if vim.fn.isdirectory(path) == 1 then
        return true
    end
    M.skip(reason)
    return false
end

---True when `name` is an executable in `$PATH`; otherwise records it.
---@param name string
---@param reason string
---@return boolean present
function M.require_executable(name, reason)
    if vim.fn.executable(name) == 1 then
        return true
    end
    M.skip(reason)
    return false
end

return M
