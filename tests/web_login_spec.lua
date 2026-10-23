-- Login handshake (`pi.web.login`): read `<runtime>/daemon.json` + `cli.token`,
-- POST `/api/v1/console/session` and open the returned signed-in URL.
--
-- Hermetic: `vim.system` is replaced through the injectable `system` option (the
-- same stub shape `tests/image_compress_spec.lua` uses), so no curl, no socket
-- and no daemon are involved.

local Login = require("pi.web.login")

--- @return string
local function tmpdir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return dir
end

--- Write the daemon discovery file + CLI token into `dir`.
--- @param dir string
--- @param port? integer
--- @param token? string
local function runtime_fixture(dir, port, token)
    if port ~= nil then
        vim.fn.writefile(
            { vim.json.encode({ pid = 42, port = port, daemonId = "d-1", protocolVersion = 1 }) },
            dir .. "/daemon.json"
        )
    end
    if token ~= nil then
        vim.fn.writefile({ token }, dir .. "/cli.token")
    end
end

--- `vim.system` stub returning a canned curl result.
--- @param stdout string
--- @param code? integer
--- @return fun(cmd: string[], opts: table, on_exit: fun(res: table)): table, table
local function system_stub(recorder, stdout, code)
    return function(cmd, opts, on_exit)
        recorder.argv = cmd
        recorder.stdin = opts.stdin
        recorder.text = opts.text
        if on_exit then
            on_exit({ code = code or 0, stdout = stdout, stderr = "" })
        end
        return { wait = function() end }
    end
end

describe("pi.web.login", function()
    local dir

    before_each(function()
        dir = tmpdir()
    end)

    it("returns the signed-in url from the console session endpoint", function()
        runtime_fixture(dir, 7676, "cli-secret-token")
        local recorder = {}
        local url, err = Login.url({
            runtime_dir = dir,
            system = system_stub(recorder, '{"token":"dev-tok","url":"http://127.0.0.1:7676/#t=dev-tok"}\n200'),
        })

        assert.is_nil(err)
        assert.equals("http://127.0.0.1:7676/#t=dev-tok", url)
        assert.equals("curl", recorder.argv[1])
        assert.equals(true, recorder.text)
        -- The request targets the *real* port from daemon.json.
        assert.is_truthy(table.concat(recorder.argv, " "):find("http://127.0.0.1:7676/api/v1/console/session", 1, true))
        -- The token never travels in argv (world-readable through `ps`).
        assert.is_nil(table.concat(recorder.argv, " "):find("cli-secret-token", 1, true))
        assert.is_truthy(recorder.stdin:find("Authorization: Bearer cli-secret-token", 1, true))
    end)

    it("reports a missing daemon.json", function()
        runtime_fixture(dir, nil, "tok")
        local url, err = Login.url({ runtime_dir = dir, system = system_stub({}, "", 0) })
        assert.is_nil(url)
        assert.is_truthy(err:find("daemon.json", 1, true))
    end)

    it("reports a missing cli.token", function()
        runtime_fixture(dir, 7676, nil)
        local url, err = Login.url({ runtime_dir = dir, system = system_stub({}, "", 0) })
        assert.is_nil(url)
        assert.is_truthy(err:find("cli.token", 1, true))
    end)

    it("returns '<status> <body>' flattened and truncated for non-200", function()
        runtime_fixture(dir, 7676, "tok")
        local body = vim.json.encode({ error = "console login is loopback-only" })
        local url, err = Login.url({ runtime_dir = dir, system = system_stub({}, body .. "\n403") })
        assert.is_nil(url)
        assert.is_truthy(err:find("^403 ", 1))
        assert.is_truthy(err:find("loopback-only", 1, true))

        local long = string.rep("x", 500)
        local _, truncated = Login.url({ runtime_dir = dir, system = system_stub({}, long .. "\n400") })
        assert.is_truthy(#truncated <= 4 + Login.BODY_LIMIT + 3, "unbounded error body: " .. #truncated)
        assert.is_nil(truncated:find("\n", 1, true))
    end)

    it("times out instead of blocking forever", function()
        runtime_fixture(dir, 7676, "tok")
        local url, err = Login.url({
            runtime_dir = dir,
            timeout = 30,
            -- Never answers: exercises the bounded `vim.wait`.
            system = function()
                return { wait = function() end }
            end,
        })
        assert.is_nil(url)
        assert.is_truthy(err:find("timed out", 1, true))
    end)

    it("reports a failing curl without leaking the token", function()
        runtime_fixture(dir, 7676, "tok")
        local url, err = Login.url({
            runtime_dir = dir,
            system = function(cmd, _, on_exit)
                on_exit({ code = 7, stdout = "", stderr = "Failed to connect to 127.0.0.1" })
                return { wait = function() end }
            end,
        })
        assert.is_nil(url)
        assert.is_truthy(err:find("Failed to connect", 1, true))
    end)

    it("open() hands the url to the opener and returns it", function()
        runtime_fixture(dir, 7676, "tok")
        local opened = {}
        local url, err = Login.open({
            runtime_dir = dir,
            system = system_stub({}, '{"url":"http://127.0.0.1:7676/#t=abc"}\n200'),
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
        runtime_fixture(dir, 7676, "tok")
        local url, err = Login.open({
            runtime_dir = dir,
            system = system_stub({}, '{"url":"http://127.0.0.1:7676/#t=abc"}\n200'),
            opener = function()
                return false, "no opener"
            end,
        })
        assert.equals("http://127.0.0.1:7676/#t=abc", url)
        assert.equals("no opener", err)
    end)

    it("open() propagates a failed handshake", function()
        runtime_fixture(dir, 7676, nil)
        local opened = false
        local url, err = Login.open({
            runtime_dir = dir,
            system = system_stub({}, "", 0),
            opener = function()
                opened = true
                return true
            end,
        })
        assert.is_nil(url)
        assert.is_truthy(err)
        assert.is_false(opened)
    end)
end)
