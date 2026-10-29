-- Specs for `pi.host`: environment adoption, the headless boot/stop loop, and
-- the "prints nothing" contract. The boot test runs a real `nvim -l` child
-- (that is the only way to observe `vim.wait` + quit semantics) with a dummy
-- daemon socket so no daemon is spawned.

local Host = require("pi.host")

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

describe("pi.host", function()
    local saved = {}

    before_each(function()
        Host._reset()
        saved.socket = vim.env.PI2_SOCKET
        saved.daemon = vim.env.PI2_DAEMON_SOCKET
        saved.runtime = vim.env.PI2_RUNTIME_DIR
        -- Hermetic runtime dir: `daemon_present` reads `<runtime>/daemon.json`, so
        -- the spec must not see the daemon of the machine running it.
        local runtime = vim.fn.tempname()
        vim.fn.mkdir(runtime, "p")
        vim.env.PI2_RUNTIME_DIR = runtime
    end)

    after_each(function()
        Host._reset()
        vim.env.PI2_SOCKET = saved.socket
        vim.env.PI2_DAEMON_SOCKET = saved.daemon
        vim.env.PI2_RUNTIME_DIR = saved.runtime
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

    it("pi.web.start creates the bridge lazily and stop tears it down", function()
        local Config = require("pi.config")
        local Web = require("pi.web")
        local Instance = require("pi.web.instance")
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")

        local prev_socket = vim.env.PI2_SOCKET
        local prev_autostart = Config.options.web.autostart
        local prev_binary = Config.options.web.binary
        local prev_enabled = Config.options.web.enabled
        vim.env.PI2_SOCKET = dir .. "/d.sock"
        Config.options.web.autostart = false
        Config.options.web.binary = dir .. "/missing-pi2-daemon"

        local bridge = Web.start()
        assert.is_true(bridge ~= nil)
        local status = Web.status()
        assert.is_true(status.enabled)
        assert.is_false(status.daemon_present)
        assert.is_true(status.started)
        assert.equals(Instance.instance().workspace_id, status.workspace_id)

        Web.stop()
        assert.is_true(Instance.instance() == nil)
        assert.is_false(Web.status().enabled)

        Config.options.web.autostart = prev_autostart
        Config.options.web.binary = prev_binary
        Config.options.web.enabled = prev_enabled
        vim.env.PI2_SOCKET = prev_socket
    end)

    it('defaults to autostart = "auto" and keeps the deprecated web keys', function()
        local Config = require("pi.config")
        local web = Config.options.web
        -- New keys: `autostart` defaults to "auto", `binary` is unset so the
        -- resolution ladder (PATH → plugin data → checkout) decides.
        assert.equals("auto", web.autostart)
        assert.is_nil(web.binary)
        -- Deprecated aliases stay typed and unset by default; their normalisation
        -- lives in `pi.web.ops.autostart_mode()`, not in `pi.config`.
        assert.is_nil(web.daemon)
        assert.is_nil(web.auto_start)

        local prev_binary, prev_daemon, prev_auto = web.binary, web.daemon, web.auto_start
        web.binary = "/opt/pi2/bin/pi2"
        web.daemon = "/opt/pi2/bin/pi2-legacy"
        web.auto_start = false
        assert.equals("/opt/pi2/bin/pi2", Config.options.web.binary)
        assert.equals("/opt/pi2/bin/pi2-legacy", Config.options.web.daemon)
        assert.is_false(Config.options.web.auto_start)

        web.binary, web.daemon, web.auto_start = prev_binary, prev_daemon, prev_auto
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
