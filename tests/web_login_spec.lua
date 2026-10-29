-- Local login handshake (`pi.web.login`): the plugin runs `pi2 open --print`
-- and hands the printed signed-in URL to the opener.
--
-- Hermetic: `vim.system` is injected through the `system` option and the daemon
-- resolution through `resolve`, so no curl, no socket, no daemon and no real
-- `pi2` binary are involved.

local Login = require("pi.web.login")

--- `vim.system` stub: records the call and answers synchronously.
--- @param recorder table
--- @param stdout string
--- @param code? integer
--- @param stderr? string
--- @return fun(cmd: string[], opts: table, on_exit: fun(res: table)): table
local function system_stub(recorder, stdout, code, stderr)
    return function(cmd, opts, on_exit)
        recorder.argv = cmd
        recorder.opts = opts
        if on_exit then
            on_exit({ code = code or 0, stdout = stdout, stderr = stderr or "" })
        end
        return { wait = function() end }
    end
end

--- A resolvable daemon candidate (never executed).
--- @param bin? string
--- @return fun(): pi.web.DaemonCandidate
local function resolves(bin)
    return function()
        return { bin = bin or "/usr/bin/pi2", source = "path" }
    end
end

describe("pi.web.login", function()
    it("runs `pi2 open --print` and returns the printed url", function()
        local recorder = {}
        local url, err = Login.url({
            resolve = resolves(),
            system = system_stub(recorder, "http://127.0.0.1:7676/#t=dev-tok\n"),
        })

        assert.is_nil(err)
        assert.equals("http://127.0.0.1:7676/#t=dev-tok", url)
        assert.same({ "/usr/bin/pi2", "open", "--print" }, recorder.argv)
        assert.is_true(recorder.opts.text)
        -- The token lives in the URL fragment the CLI prints; it is never an
        -- argument (world-readable through `ps`) and never part of the request.
        assert.is_nil(table.concat(recorder.argv, " "):find("dev-tok", 1, true))
    end)

    it("keeps the last URL-shaped line when the CLI warns first", function()
        local url, err = Login.url({
            resolve = resolves(),
            system = system_stub({}, "warn: something\nhttp://127.0.0.1:7676/#t=abc\n"),
        })
        assert.is_nil(err)
        assert.equals("http://127.0.0.1:7676/#t=abc", url)
    end)

    it("reports a missing pi2 with the install commands, without running anything", function()
        local called = false
        local url, err = Login.url({
            resolve = function()
                return nil
            end,
            system = function()
                called = true
                return { wait = function() end }
            end,
        })
        assert.is_nil(url)
        assert.is_truthy(err:find("npm i -g @yuez/pi2d", 1, true))
        assert.is_truthy(err:find(":PiWebInstall", 1, true))
        assert.is_false(called)
    end)

    it("flattens the CLI's failure into one bounded line", function()
        local url, err = Login.url({
            resolve = resolves(),
            system = system_stub({}, "", 1, "pi2: no running pi2 daemon\nstart it first\n"),
        })
        assert.is_nil(url)
        assert.equals("pi2 open failed: pi2: no running pi2 daemon", err)

        local long = string.rep("x", 500)
        local _, truncated = Login.url({ resolve = resolves(), system = system_stub({}, "", 1, long) })
        local prefix = "pi2 open failed: "
        assert.is_truthy(#truncated <= #prefix + Login.BODY_LIMIT + 3, "unbounded error: " .. #truncated)
        assert.is_nil(truncated:find("\n", 1, true))
    end)

    it("falls back to stdout when the CLI fails silently on stderr", function()
        local url, err = Login.url({
            resolve = resolves(),
            system = system_stub({}, "boom\n", 2, ""),
        })
        assert.is_nil(url)
        assert.equals("pi2 open failed: boom", err)
    end)

    it("times out instead of blocking forever", function()
        local url, err = Login.url({
            resolve = resolves(),
            timeout = 30,
            -- Never answers: exercises the bounded `vim.wait`.
            system = function()
                return { wait = function() end }
            end,
        })
        assert.is_nil(url)
        assert.is_truthy(err:find("timed out", 1, true))
    end)

    it("reports a successful run that printed no URL", function()
        local url, err = Login.url({ resolve = resolves(), system = system_stub({}, "not a url\n") })
        assert.is_nil(url)
        assert.is_truthy(err:find("printed no URL", 1, true))
    end)

    it("open() hands the url to the opener and returns it", function()
        local opened = {}
        local url, err = Login.open({
            resolve = resolves(),
            system = system_stub({}, "http://127.0.0.1:7676/#t=abc\n"),
            opener = function(target)
                opened[#opened + 1] = target
                return true
            end,
        })
        assert.is_nil(err)
        assert.equals("http://127.0.0.1:7676/#t=abc", url)
        assert.same({ url }, opened)
    end)

    it("open() returns the url plus the opener error when opening fails", function()
        local url, err = Login.open({
            resolve = resolves(),
            system = system_stub({}, "http://127.0.0.1:7676/#t=abc\n"),
            opener = function()
                return false, "no opener"
            end,
        })
        assert.equals("http://127.0.0.1:7676/#t=abc", url)
        assert.equals("no opener", err)
    end)

    it("open() propagates a failed handshake without opening anything", function()
        local opened = false
        local url, err = Login.open({
            resolve = resolves(),
            system = system_stub({}, "", 1, "no daemon"),
            opener = function()
                opened = true
                return true
            end,
        })
        assert.is_nil(url)
        assert.is_truthy(err:find("no daemon", 1, true))
        assert.is_false(opened)
    end)

    it("open_url() prefers web.browser and spawns it detached", function()
        local spawned
        local ok, err = Login.open_url("http://127.0.0.1:7676/#t=abc", {
            config = { browser = "/usr/bin/firefox" },
            system = function(cmd, opts)
                spawned = { cmd = cmd, opts = opts }
                return {}
            end,
        })
        assert.is_true(ok)
        assert.is_nil(err)
        assert.same({ "/usr/bin/firefox", "http://127.0.0.1:7676/#t=abc" }, spawned.cmd)
        assert.is_true(spawned.opts.detach)
    end)
end)
