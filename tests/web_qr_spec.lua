-- `:PiWebPair`'s QR view (`pi.web.qr`), the `POST /api/v1/pair` mint that feeds
-- it (`pi.web.ctl.mint_pair`) and the report normaliser (`pi.web.ctl.pairing_report`).
--
-- The matrix itself is the daemon's job (byte mode, ECC M); this spec covers the
-- presentation contract: half-block mapping, quiet zone, metadata lines, the
-- forced black-on-white highlight, the keymaps, and the payload validation that
-- keeps a malformed report from reaching the buffer.

local Ctl = require("pi.web.ctl")
local Qr = require("pi.web.qr")

local function tmp_matrix(size)
    local rows = {}
    for row = 1, size do
        local cells = {}
        for col = 1, size do
            cells[#cells + 1] = ((row + col) % 2 == 0) and "1" or "0"
        end
        rows[#rows + 1] = table.concat(cells)
    end
    return rows
end

local function report(overrides)
    local matrix = tmp_matrix(21)
    local payload = {
        url = "http://192.168.2.10:7676/pair/ABCD2345",
        code = "ABCD2345",
        expiresAt = (os.time() + 600) * 1000,
        qr = { version = 1, ecc = "M", mask = 2, size = 21, rows = matrix },
    }
    for key, value in pairs(overrides or {}) do
        payload[key] = value
    end
    return vim.json.encode(payload)
end

describe("pi.web.qr", function()
    after_each(function()
        Qr.close()
    end)

    it("maps two module rows per line with half blocks", function()
        assert.same({ "▀▄" }, Qr.lines({ "10", "01" }, 0))
        assert.same({ "█▀" }, Qr.lines({ "11", "10" }, 0))
        assert.same({ "  " }, Qr.lines({ "00", "00" }, 0))
        -- An odd module count renders the trailing row as an upper half and adds
        -- one blank line so the bottom quiet zone keeps its height.
        assert.same({ "▀", " " }, Qr.lines({ "1" }, 0))
    end)

    it("adds the quiet zone on every side", function()
        local lines = Qr.lines({ "10", "01" }, 2)
        -- ceil(2/2) = 1 blank line above and below for an even row count.
        assert.equals(3, #lines)
        assert.equals("  ▀▄  ", lines[2])
        assert.equals(2 + 4, vim.fn.strdisplaywidth(lines[1]))
        assert.equals(2 + 4, vim.fn.strdisplaywidth(lines[3]))
        -- An odd matrix grows the bottom margin by one module row so both quiet
        -- zones still cover the requested number of modules.
        local odd = Qr.lines({ "10", "01", "11" }, 2)
        assert.equals(5, #odd)
        assert.equals(2 + 4, vim.fn.strdisplaywidth(odd[#odd]))
        for _, index in ipairs({ 1, #lines, #odd }) do
            local line = (index == #odd) and odd[index] or lines[index]
            assert.equals("", vim.trim(line))
        end
    end)

    it("labels the remaining lifetime of the code", function()
        local now = 1_700_000_000
        assert.equals("expires in 10:00", Qr.expiry_label((now + 600) * 1000, now))
        assert.equals("expires in 0:07", Qr.expiry_label((now + 7) * 1000, now))
        assert.equals("expired", Qr.expiry_label((now - 1) * 1000, now))
        assert.is_nil(Qr.expiry_label(nil, now))
    end)

    it("puts the link, code and keys under the symbol", function()
        local lines = Qr.meta_lines({
            url = "http://h:7676/pair/ABCD2345",
            code = "ABCD2345",
            expires_at = (os.time() + 60) * 1000,
        })
        assert.equals(4, #lines)
        assert.equals("", lines[1])
        assert.equals("http://h:7676/pair/ABCD2345", lines[2])
        assert.is_truthy(lines[3]:find("code ABCD2345", 1, true))
        assert.is_truthy(lines[3]:find("expires in", 1, true))
        assert.is_truthy(lines[4]:find("q close", 1, true))
    end)

    it("draws the symbol in a float with the forced-contrast highlight", function()
        local rows = tmp_matrix(21)
        Qr.open({
            rows = rows,
            url = "http://192.168.2.10:7676/pair/ABCD2345",
            code = "ABCD2345",
            expires_at = (os.time() + 600) * 1000,
        })
        local win, buf = Qr.win(), Qr.buf()
        assert.is_truthy(win and vim.api.nvim_win_is_valid(win))
        assert.equals(Qr.FILETYPE, vim.bo[buf].filetype)

        local body = Qr.lines(rows)
        local meta = Qr.meta_lines({ url = "http://192.168.2.10:7676/pair/ABCD2345", code = "ABCD2345" })
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.equals(#body + #meta, #lines)
        assert.equals(body[1], lines[1])

        -- The highlight is attached to the symbol lines only (bytes 0..#line).
        local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
        local qr_marks = 0
        for _, mark in ipairs(marks) do
            if mark[4].hl_group == Qr.HL then
                qr_marks = qr_marks + 1
            end
        end
        assert.equals(#body, qr_marks)
        local hl = vim.api.nvim_get_hl(0, { name = Qr.HL })
        assert.equals("ffffff", string.format("%06x", hl.bg))
        assert.equals("000000", string.format("%06x", hl.fg))

        local keys = {}
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            keys[map.lhs] = true
        end
        assert.is_true(keys.q)
        assert.is_true(keys["<Esc>"])
        assert.is_true(keys.y)
        -- `r` only exists when the caller injected a refresh callback.
        assert.is_nil(keys.r)

        Qr.close()
        assert.is_nil(Qr.win())
        assert.is_false(vim.api.nvim_buf_is_valid(buf))
    end)

    it("offers `r` to mint a new code when a refresh callback is given", function()
        local refreshed = 0
        Qr.open({
            rows = tmp_matrix(21),
            url = "http://h:7676/pair/ABCD2345",
            code = "ABCD2345",
            refresh = function()
                refreshed = refreshed + 1
            end,
        })
        local buf = Qr.buf()
        local keymap
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            if map.lhs == "r" then
                keymap = map
            end
        end
        assert.is_truthy(keymap)
        vim.api.nvim_buf_call(buf, function()
            vim.cmd("normal r")
        end)
        assert.equals(1, refreshed)
        -- The refresh path closes the stale view first.
        assert.is_nil(Qr.win())
    end)

    it("refuses an empty matrix instead of opening an empty float", function()
        local saved = vim.notify
        local messages = {}
        vim.notify = function(message)
            messages[#messages + 1] = message
        end
        local ok = pcall(Qr.open, { rows = {}, url = "u", code = "c" })
        vim.notify = saved
        assert.is_true(ok)
        assert.is_nil(Qr.win())
        assert.is_truthy(messages[1]:find("empty QR matrix", 1, true))
    end)
end)

describe("pi.web.ctl.pair", function()
    local saved = {}

    local function base(kind, name, address, url)
        return { kind = kind, name = name, address = address, url = url }
    end

    --- A decoded `POST /api/v1/pair` response with an arbitrary url and base list.
    local function minted(url, bases)
        return {
            url = url,
            code = "ABCD2345",
            expiresAt = (os.time() + 600) * 1000,
            qr = { version = 1, ecc = "M", mask = 2, size = 21, rows = tmp_matrix(21) },
            bases = bases,
        }
    end

    local messages
    before_each(function()
        messages = {}
        saved.notify = vim.notify
        vim.notify = function(msg)
            messages[#messages + 1] = tostring(msg)
        end
        saved.ensure_running = Ctl.ensure_running
        Ctl.ensure_running = function()
            return { port = 7676 }
        end
        saved.mint = Ctl.mint_pair
        saved.reachable = Ctl.reachable
        Ctl.reachable = function(_, on_done)
            on_done(true, "connected")
        end
        saved.select = vim.ui.select
        saved.qr_open = Qr.open
    end)

    after_each(function()
        Ctl.ensure_running = saved.ensure_running
        Ctl.mint_pair = saved.mint
        Ctl.reachable = saved.reachable
        vim.ui.select = saved.select
        Qr.open = saved.qr_open
        vim.notify = saved.notify
    end)

    local LAN = base("lan", "wlan0", "192.168.11.7", "http://192.168.11.7:7676")
    local TAILSCALE = base("tailscale", "tailscale0", "100.64.0.14", "http://100.64.0.14:7676")

    it("asks which network interface to use and mints on the chosen base", function()
        local calls, attempts = {}, 0
        Ctl.mint_pair = function(chosen_base, on_done)
            attempts = attempts + 1
            -- `false` records "no pin": `calls[#calls + 1] = nil` would not grow
            -- (and `x == nil and false or x` yields nil — hence the explicit branch).
            if chosen_base == nil then
                calls[attempts] = false
            else
                calls[attempts] = chosen_base
            end
            local url = attempts == 1 and "http://127.0.0.1:7676/pair/ABCD2345"
                or "http://100.64.0.14:7676/pair/ABCD2345"
            on_done(Ctl.pairing_report(minted(url, { LAN, TAILSCALE })), nil)
        end
        local items, option
        vim.ui.select = function(list, opts, on_choice)
            items = list
            option = opts
            on_choice(list[2])
        end

        Ctl.pair()

        -- The menu lists the interface name + IP of every base, best first.
        assert.equals(2, #items)
        assert.equals("wlan0", items[1].name)
        assert.equals("192.168.11.7", items[1].address)
        assert.equals("tailscale0", items[2].name)
        assert.equals("100.64.0.14", items[2].address)
        assert.is_truthy(option.prompt:find("which address", 1, true))
        assert.is_truthy(Ctl.base_label(items[1]):find("192.168.11.7", 1, true))

        -- The first code was minted on the daemon's default base (no pin);
        -- picking a different interface mints again, pinned to that base.
        assert.equals(2, attempts)
        assert.is_false(calls[1])
        assert.equals("http://100.64.0.14:7676", calls[2])

        -- Headless: no float, but the reachable link is reported.
        assert.equals(0, #vim.api.nvim_list_uis())
        local reported = table.concat(messages, "\n")
        assert.is_truthy(reported:find("http://100.64.0.14:7676/pair/ABCD2345", 1, true))
        assert.is_truthy(reported:find("(code ABCD2345)", 1, true))
    end)

    it("skips the menu when there is a single base, and draws it", function()
        Ctl.mint_pair = function(_, on_done)
            on_done(Ctl.pairing_report(minted("http://192.168.11.7:7676/pair/ABCD2345", { LAN })), nil)
        end
        local asked = false
        vim.ui.select = function(_, _, _)
            asked = true
        end
        local opened
        Qr.open = function(opts)
            opened = opts
        end
        -- Pretend a UI exists: the float path is what a desktop Neovim takes.
        local real_list = vim.api.nvim_list_uis
        vim.api.nvim_list_uis = function()
            return { { chan = 1 } }
        end
        Ctl.pair()
        vim.api.nvim_list_uis = real_list

        assert.is_false(asked)
        assert.is_truthy(opened)
        assert.equals("http://192.168.11.7:7676/pair/ABCD2345", opened.url)
        assert.equals("ABCD2345", opened.code)
        assert.equals(21, #opened.rows)
    end)

    it("reports a cancelled menu without minting again", function()
        local calls = 0
        Ctl.mint_pair = function(_, on_done)
            calls = calls + 1
            on_done(Ctl.pairing_report(minted("http://192.168.11.7:7676/pair/ABCD2345", { LAN, TAILSCALE })), nil)
        end
        vim.ui.select = function(_, _, on_choice)
            on_choice(nil)
        end
        Ctl.pair()
        assert.equals(1, calls)
        assert.is_truthy(table.concat(messages, "\n"):find("pairing cancelled", 1, true))
    end)

    it("surfaces a mint failure instead of drawing anything", function()
        Ctl.mint_pair = function(_, on_done)
            on_done(nil, "curl failed: connection refused")
        end
        local opened = false
        Qr.open = function()
            opened = true
        end
        Ctl.pair()
        assert.is_false(opened)
        assert.is_truthy(table.concat(messages, "\n"):find("connection refused", 1, true))
    end)

    it("refuses to draw a code for an unreachable address", function()
        Ctl.mint_pair = function(_, on_done)
            on_done(Ctl.pairing_report(minted("http://192.168.11.7:7676/pair/ABCD2345", { LAN })), nil)
        end
        Ctl.reachable = function(_, on_done)
            on_done(false, "ECONNREFUSED")
        end
        local opened = false
        Qr.open = function()
            opened = true
        end
        Ctl.pair()
        local reported = table.concat(messages, "\n")
        assert.is_false(opened)
        assert.is_truthy(reported:find("not reachable", 1, true))
        assert.is_truthy(reported:find("web.host", 1, true))
        assert.is_truthy(reported:find("firewall", 1, true))
    end)

    it("refuses a loopback link even when the probe would succeed", function()
        Ctl.mint_pair = function(_, on_done)
            on_done(Ctl.pairing_report(minted("http://127.0.0.1:7676/pair/ABCD2345", {})), nil)
        end
        local opened = false
        Qr.open = function()
            opened = true
        end
        Ctl.pair()
        local reported = table.concat(messages, "\n")
        assert.is_false(opened)
        assert.is_truthy(reported:find("only works on this machine", 1, true))
        assert.is_truthy(reported:find("web.host", 1, true))
    end)
end)

describe("pi.web.ctl.mint_pair", function()
    --- `vim.system` stub: records the argv and answers with a canned CLI result.
    local function fake_system(reply, captured)
        return function(argv, opts, on_exit)
            captured.argv = argv
            captured.opts = opts
            on_exit(reply)
            return {}
        end
    end

    --- A resolvable `pi2` (never executed).
    local function resolves(bin)
        return function()
            return { bin = bin or "/usr/bin/pi2", source = "path" }
        end
    end

    local function body(overrides)
        local payload = {
            url = "http://192.168.11.7:7676/pair/ABCD2345",
            code = "ABCD2345",
            expiresAt = (os.time() + 600) * 1000,
            qr = { version = 1, ecc = "M", mask = 2, size = 21, rows = tmp_matrix(21) },
            bases = {},
        }
        for key, value in pairs(overrides or {}) do
            payload[key] = value
        end
        return vim.json.encode(payload)
    end

    it("runs `pi2 pairing --json` and decodes the report", function()
        local captured = { reply = { code = 0, stderr = "", stdout = body() } }
        local report, err
        Ctl.mint_pair(nil, function(value, failure)
            report, err = value, failure
        end, { resolve = resolves(), system = fake_system(captured.reply, captured), timeout = 100 })

        assert.is_nil(err)
        assert.is_truthy(report)
        assert.equals("ABCD2345", report.code)
        assert.equals(21, #report.rows)
        -- No HTTP and no token handling here: the CLI owns the exchange.
        assert.same({ "/usr/bin/pi2", "pairing", "--json" }, captured.argv)
        assert.is_true(captured.opts.text)
        assert.is_nil(captured.opts.stdin)
    end)

    it("pins the chosen base with --base", function()
        local captured = { reply = { code = 0, stderr = "", stdout = body() } }
        Ctl.mint_pair("http://100.64.0.14:7676", function() end, {
            resolve = resolves(),
            system = fake_system(captured.reply, captured),
            timeout = 100,
        })
        assert.same({ "/usr/bin/pi2", "pairing", "--json", "--base", "http://100.64.0.14:7676" }, captured.argv)
    end)

    it("surfaces the CLI failure as one line", function()
        local captured = {
            reply = { code = 1, stderr = "pi2: pairing refused: base must be one of: …\nmore", stdout = "" },
        }
        local report, err
        Ctl.mint_pair("http://evil.example:9999", function(value, failure)
            report, err = value, failure
        end, { resolve = resolves(), system = fake_system(captured.reply, captured), timeout = 100 })

        assert.is_nil(report)
        assert.is_truthy(err:find("pairing failed", 1, true))
        assert.is_truthy(err:find("base must be one of", 1, true))
        assert.is_nil(err:find("\n", 1, true))
    end)

    it("rejects an unreadable body instead of drawing garbage", function()
        local captured = { reply = { code = 0, stderr = "", stdout = "not json" } }
        local report, err
        Ctl.mint_pair(nil, function(value, failure)
            report, err = value, failure
        end, { resolve = resolves(), system = fake_system(captured.reply, captured), timeout = 100 })

        assert.is_nil(report)
        assert.is_truthy(err:find("unreadable JSON", 1, true))
    end)

    it("fails fast when pi2 cannot be resolved", function()
        local calls = 0
        local function system()
            calls = calls + 1
            return {}
        end

        local report, err
        Ctl.mint_pair(nil, function(value, failure)
            report, err = value, failure
        end, {
            resolve = function()
                return nil
            end,
            system = system,
            timeout = 100,
        })
        assert.is_nil(report)
        assert.is_truthy(err:find("npm i -g @yuez/pi2d", 1, true))
        -- Nothing is shelled out without a binary.
        assert.equals(0, calls)
    end)

    it("times out instead of blocking forever", function()
        local report, err
        Ctl.mint_pair(nil, function(value, failure)
            report, err = value, failure
        end, {
            resolve = resolves(),
            timeout = 30,
            system = function()
                return {}
            end,
        })
        assert.is_nil(report)
        assert.is_truthy(err:find("timed out", 1, true))
    end)
end)

describe("pi.web.ctl.probe_target", function()
    it("splits host and port, with scheme defaults", function()
        assert.same({ "192.168.11.7", 7676 }, { Ctl.probe_target("http://192.168.11.7:7676") })
        assert.same({ "host.tail1234.ts.net", 443 }, { Ctl.probe_target("https://host.tail1234.ts.net") })
        assert.same({ "host.tail1234.ts.net", 7676 }, { Ctl.probe_target("https://host.tail1234.ts.net:7676/") })
        assert.same({ "[::1]", 7676 }, { Ctl.probe_target("http://[::1]:7676") })
        assert.same({ nil, nil }, { Ctl.probe_target("not a url") })
        assert.same({ nil, nil }, { Ctl.probe_target(nil) })
    end)
end)

describe("pi.web.ctl.pairing_report", function()
    it("decodes the mint response", function()
        local decoded = Ctl.pairing_report(report())
        assert.is_truthy(decoded)
        assert.equals("http://192.168.2.10:7676/pair/ABCD2345", decoded.url)
        assert.equals("ABCD2345", decoded.code)
        assert.equals(21, decoded.size)
        assert.equals(1, decoded.version)
        assert.equals(21, #decoded.rows)
        assert.is_truthy(decoded.expires_at)
    end)

    it("rejects a text-mode report, a broken matrix and missing fields", function()
        assert.is_nil(Ctl.pairing_report(nil))
        assert.is_nil(Ctl.pairing_report(""))
        assert.is_nil(Ctl.pairing_report("url     http://127.0.0.1:7676/pair/ABCD2345\ncode    ABCD2345\n"))
        assert.is_nil(Ctl.pairing_report("not json"))
        -- A payload without the matrix cannot be drawn.
        assert.is_nil(Ctl.pairing_report(vim.json.encode({ url = "u", code = "c" })))
        -- 0/1 only: a foreign character must not reach the renderer.
        local bad_rows = vim.json.encode({ url = "u", code = "c", qr = { rows = { "10", "2x" }, size = 2 } })
        assert.is_nil(Ctl.pairing_report(bad_rows))
        -- Rows must match the advertised side length.
        local ragged = vim.json.encode({ url = "u", code = "c", qr = { rows = { "101", "10" }, size = 3 } })
        assert.is_nil(Ctl.pairing_report(ragged))
        local missing_url = vim.json.encode({ code = "c", qr = { rows = { "10", "01" } } })
        assert.is_nil(Ctl.pairing_report(missing_url))
    end)
end)
