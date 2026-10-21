-- In-process unix-socket server for driving `pi.web.bridge` in tests.
--
-- It binds a `vim.uv` pipe to a filesystem path, accepts clients, reassembles
-- newline-delimited JSON from them and exposes small helpers to send records
-- back. Everything here is uv-callback safe: no `vim.fn` / `vim.api` calls run
-- from a uv callback (lines are buffered in Lua and decoded lazily on demand
-- from the main loop).
--
-- Usage:
--   local PipeServer = require("tests.helpers.uv_pipe_server")
--   local srv = PipeServer.new("/tmp/x/d.sock"):start()
--   assert(vim.wait(2000, function() return #srv:records_of("hello") == 1 end))
--   srv:send({ v = 1, type = "hello_ack" })
--   srv:stop()

local uv = vim.uv or vim.loop

---@class pi.TestUvPipeServer
---@field path string Socket path bound by the server
---@field lines string[] Every complete newline-terminated line received, in order
---@field clients pi.TestUvPipeServerClient[] Accepted client pipes, in order
local Server = {}
Server.__index = Server

---@class pi.TestUvPipeServerClient
---@field pipe uv_pipe_t
---@field buf string Pending partial line for this client
---@field open boolean

--- @param path? string Socket path; defaults to a fresh tempname
--- @return pi.TestUvPipeServer
function Server.new(path)
    return setmetatable({
        path = path or (vim.fn.tempname() .. ".sock"),
        lines = {},
        clients = {},
        _listening = false,
    }, Server)
end

--- Bind + listen. Removes a stale socket file first.
--- @return pi.TestUvPipeServer self
function Server:start()
    os.remove(self.path)
    local srv = uv.new_pipe(false)
    assert(srv, "uv.new_pipe failed")
    local ok, err = pcall(srv.bind, srv, self.path)
    if not ok then
        pcall(srv.close, srv)
        error("bind " .. self.path .. " failed: " .. tostring(err))
    end
    self._srv = srv
    srv:listen(128, function(accept_err)
        if accept_err then
            return
        end
        local client = uv.new_pipe(false)
        if not client then
            return
        end
        srv:accept(client)
        ---@type pi.TestUvPipeServerClient
        local entry = { pipe = client, buf = "", open = true }
        self.clients[#self.clients + 1] = entry
        client:read_start(function(read_err, data)
            if read_err then
                entry.open = false
                return
            end
            if data == nil then
                entry.open = false
                return
            end
            entry.buf = entry.buf .. data
            while true do
                local nl = entry.buf:find("\n", 1, true)
                if not nl then
                    break
                end
                local line = entry.buf:sub(1, nl - 1):gsub("\r$", "")
                entry.buf = entry.buf:sub(nl + 1)
                if line ~= "" then
                    self.lines[#self.lines + 1] = line
                end
            end
        end)
    end)
    self._listening = true
    return self
end

--- The most recently accepted client, or nil.
--- @return pi.TestUvPipeServerClient|nil
function Server:last_client()
    for i = #self.clients, 1, -1 do
        if self.clients[i].open then
            return self.clients[i]
        end
    end
    return self.clients[#self.clients]
end

--- Write a raw string to the newest client (no newline added).
--- @param raw string
--- @return boolean sent
function Server:send_raw(raw)
    local client = self:last_client()
    if not client then
        return false
    end
    local ok = pcall(client.pipe.write, client.pipe, raw)
    return ok
end

--- Encode a table (or take a string as-is) as one JSONL record and write it.
--- @param record table|string
--- @return boolean sent
function Server:send(record)
    local line = type(record) == "string" and record or vim.json.encode(record)
    return self:send_raw(line .. "\n")
end

--- Decoded records received so far (invalid lines are skipped).
--- @return table[]
function Server:records()
    local out = {}
    for _, line in ipairs(self.lines) do
        local ok, rec = pcall(vim.json.decode, line)
        if ok and type(rec) == "table" then
            out[#out + 1] = rec
        end
    end
    return out
end

--- Decoded records of one `type`.
--- @param kind string
--- @return table[]
function Server:records_of(kind)
    local out = {}
    for _, rec in ipairs(self:records()) do
        if rec.type == kind then
            out[#out + 1] = rec
        end
    end
    return out
end

--- Block (processing the event loop) until `pred()` is true.
--- @param pred fun(): boolean
--- @param timeout? integer milliseconds, default 2000
--- @return boolean ok
function Server:wait_for(pred, timeout)
    return vim.wait(timeout or 2000, pred, 10)
end

--- Close every accepted client, keeping the listener alive so a reconnecting
--- peer can dial again.
--- @param keep_listening? boolean
function Server:close_clients(keep_listening)
    for _, client in ipairs(self.clients) do
        client.open = false
        pcall(client.pipe.close, client.pipe)
    end
    self.clients = {}
    if not keep_listening then
        self._listening = false
    end
end

--- Close clients, stop listening and remove the socket file.
function Server:stop()
    self:close_clients()
    if self._srv then
        pcall(self._srv.close, self._srv)
        self._srv = nil
    end
    os.remove(self.path)
end

return Server
