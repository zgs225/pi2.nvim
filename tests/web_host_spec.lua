-- Specs for `pi.host`: environment adoption, the headless boot/stop loop, and
-- the "prints nothing" contract. The boot test runs a real `nvim -l` child
-- (that is the only way to observe `vim.wait` + quit semantics) with a dummy
-- daemon socket so no `pi2d` is spawned.

local Host = require("pi.host")

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

describe("pi.host", function()
    local saved = {}

    before_each(function()
        Host._reset()
        saved.socket = vim.env.PI2_SOCKET
        saved.daemon = vim.env.PI2_DAEMON_SOCKET
    end)

    after_each(function()
        Host._reset()
        vim.env.PI2_SOCKET = saved.socket
        vim.env.PI2_DAEMON_SOCKET = saved.daemon
    end)

    it("adopts PI2_DAEMON_SOCKET unless PI2_SOCKET is set explicitly", function()
        vim.env.PI2_DAEMON_SOCKET = "/run/pi2/d.sock"
        vim.env.PI2_SOCKET = nil
        Host.adopt_env()
        assert.equals("/run/pi2/d.sock", vim.env.PI2_SOCKET)

        vim.env.PI2_SOCKET = "/run/pi2/explicit.sock"
        Host.adopt_env()
        assert.equals("/run/pi2/explicit.sock", vim.env.PI2_SOCKET)
    end)

    it("stops the wait loop on stop()", function()
        assert.is_false(Host._stopping)
        assert.is_true(Host.stop())
        assert.is_true(Host._stopping)
    end)

    it("boots headless, keeps the process alive, and exits on stop without printing", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local socket = dir .. "/d.sock"
        -- A plain file is enough for `pi.web.start_daemon` to think a daemon is
        -- present; the bridge then retries connecting instead of spawning one.
        vim.fn.writefile({ "not-a-socket" }, socket)
        local out_path = dir .. "/host.out"
        local script = dir .. "/host.lua"
        vim.fn.writefile({
            "local out = vim.env.PI2_TEST_OUT",
            'vim.defer_fn(function() require("pi.host").stop() end, 150)',
            'local ok = require("pi.host").start(vim.env.PI2_TEST_WS)',
            "vim.fn.writefile({ tostring(ok), tostring(vim.v.servername) }, out)",
        }, script)

        local prev_socket = vim.env.PI2_SOCKET
        local prev_out = vim.env.PI2_TEST_OUT
        local prev_ws = vim.env.PI2_TEST_WS
        vim.env.PI2_SOCKET = socket
        vim.env.PI2_TEST_OUT = out_path
        vim.env.PI2_TEST_WS = dir

        local command = {
            vim.v.progpath,
            "--headless",
            "-u",
            repo_root .. "/tests/minimal_init.lua",
            "-l",
            script,
        }
        local output = vim.fn.system(command)
        local exit_code = vim.v.shell_error

        vim.env.PI2_SOCKET = prev_socket
        vim.env.PI2_TEST_OUT = prev_out
        vim.env.PI2_TEST_WS = prev_ws

        assert.equals(0, exit_code)
        assert.is_nil(output:find("Error executing lua", 1, true))
        assert.is_nil(output:find("stack traceback", 1, true))

        local lines = vim.fn.readfile(out_path)
        assert.equals("true", lines[1])
        -- `serverstart()` must have produced a connectable address for
        -- `nvim --server <addr> --remote-ui`.
        assert.is_true(type(lines[2]) == "string" and #lines[2] > 0)
    end)
end)
