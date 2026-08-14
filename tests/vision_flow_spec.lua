-- Vision fallback flow (chat + history level, backend stubbed):
-- * success: non-vision main model + configured vision model → deferred
--   render, marker delivery renders original text + vision block;
-- * fast-fail: prefixed error notify restores prompt text and attachments;
-- * vision-capable main model → no-op (images pass through untouched);
-- * unconfigured → no-op;
-- * queued (steer) delivery with prefix matching;
-- * vision block rendering, auto-collapse and pending preview row.

local Config = require("pi.config")
local Chat = require("pi.ui.chat")
local History = require("pi.ui.chat.history")
local Vision = require("pi.vision")
local Extension = require("pi.ui.extension")

local TAB = 1101

local function pump(ms)
    vim.wait(ms or 60)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function buf_contains(buf, sub)
    for _, l in ipairs(lines_of(buf)) do
        if l:find(sub, 1, true) then
            return true
        end
    end
    return false
end

--- Exact match on the trimmed line (avoids substring collisions like
--- "detail line 1" inside "detail line 13").
local function buf_has_exact_line(buf, line)
    for _, l in ipairs(lines_of(buf)) do
        if vim.trim(l) == line then
            return true
        end
    end
    return false
end

--- Chat with a capturing agent stub (no RPC, no real model calls).
local function setup_chat()
    local sent = {}
    local chat = Chat.new(TAB, "side", {
        send = function(cmd)
            sent[#sent + 1] = cmd
            return true
        end,
    })
    return chat, sent
end

local function teardown_chat(chat)
    pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
end

local function set_prompt(chat, text)
    vim.api.nvim_buf_set_lines(chat._prompt:buf(), 0, -1, false, vim.split(text, "\n", { plain = true }))
end

local function attach(chat, n)
    for i = 1, n do
        chat._attachments:_add_item(("img%d.png"):format(i), "QUJD", "image/png", 3)
    end
end

--- Simulate the user message_start event carrying `text`.
local function deliver_user_message(chat, text)
    chat:on_message_start({
        message = {
            role = "user",
            timestamp = 1700000000000,
            content = { { type = "text", text = text } },
        },
    })
    pump(120)
end

describe("vision fallback flow", function()
    local saved_vision

    before_each(function()
        saved_vision = Config.options.vision
    end)

    after_each(function()
        Config.options.vision = saved_vision
    end)

    it("defers rendering and renders the vision block on transformed delivery (non-vision main model)", function()
        Config.options.vision = { model = "google/gemini-2.5-pro" }
        local chat, sent = setup_chat()
        chat:update_state({ model = { id = "qwen3-coder", input = { "text" } } })

        set_prompt(chat, "fix this layout")
        attach(chat, 2)
        chat:_send_message(nil)
        pump(80)

        -- Prompt/attachments consumed; command carries rpc-shaped images.
        assert.are.equal("", chat._prompt:text())
        assert.are.equal(0, chat._attachments:count())
        assert.are.equal(1, #sent)
        assert.are.equal(2, #sent[1].images)
        assert.are.equal("image/png", sent[1].images[1].mimeType)

        -- Render is deferred: no user message yet, pending preview active.
        assert.is_false(buf_contains(chat._history:buf(), "fix this layout"))
        assert.is_not_nil(chat._vision_inflight)
        assert.is_not_nil(chat._history._vision_pending)

        -- Deliver the transformed user message.
        local transformed = "fix this layout\n\n"
            .. Vision.make_marker("google/gemini-2.5-pro", "A screenshot of a broken flex layout.")
        deliver_user_message(chat, transformed)

        local hbuf = chat._history:buf()
        assert.is_true(buf_contains(hbuf, "fix this layout"))
        assert.is_true(buf_contains(hbuf, "vision"))
        assert.is_true(buf_contains(hbuf, "google/gemini-2.5-pro"))
        assert.is_true(buf_contains(hbuf, "A screenshot of a broken flex layout."))
        -- The marker itself is never rendered raw.
        assert.is_false(buf_contains(hbuf, "<pi-vision"))
        assert.is_nil(chat._vision_inflight)
        assert.is_nil(chat._history._vision_pending)

        teardown_chat(chat)
    end)

    it("fast-fail restores prompt text and attachments", function()
        Config.options.vision = { model = "google/gemini-2.5-pro" }
        local chat = setup_chat()
        chat:update_state({ model = { id = "qwen3-coder", input = { "text" } } })

        set_prompt(chat, "retry me")
        attach(chat, 1)
        chat:_send_message(nil)
        pump(80)
        assert.are.equal("", chat._prompt:text())
        assert.are.equal(0, chat._attachments:count())

        -- Extension fast-fails with a prefixed error notification.
        Extension.handle({ chat = chat }, {
            method = "notify",
            notifyType = "error",
            message = "[pi-vision] vision model call failed: boom",
        })
        pump(80)

        assert.are.equal("retry me", chat._prompt:text())
        assert.are.equal(1, chat._attachments:count())
        assert.is_nil(chat._vision_inflight)
        assert.is_nil(chat._history._vision_pending)
        assert.is_false(buf_contains(chat._history:buf(), "retry me"))

        teardown_chat(chat)
    end)

    it("is a no-op when the main model supports images", function()
        Config.options.vision = { model = "google/gemini-2.5-pro" }
        local chat, sent = setup_chat()
        chat:update_state({ model = { id = "claude-sonnet", input = { "text", "image" } } })

        set_prompt(chat, "look at this")
        attach(chat, 1)
        chat:_send_message(nil)
        pump(80)

        -- Rendered immediately, no pending state, images untouched.
        assert.is_true(buf_contains(chat._history:buf(), "look at this"))
        assert.is_true(buf_contains(chat._history:buf(), "1 image attached"))
        assert.is_nil(chat._vision_inflight)
        assert.is_nil(chat._history._vision_pending)
        assert.are.equal(1, #sent[1].images)

        teardown_chat(chat)
    end)

    it("is a no-op when vision is not configured", function()
        Config.options.vision = {}
        local chat = setup_chat()
        chat:update_state({ model = { id = "qwen3-coder", input = { "text" } } })

        set_prompt(chat, "plain send")
        attach(chat, 1)
        chat:_send_message(nil)
        pump(80)

        assert.is_true(buf_contains(chat._history:buf(), "plain send"))
        assert.is_true(buf_contains(chat._history:buf(), "1 image attached"))
        assert.is_nil(chat._vision_inflight)

        teardown_chat(chat)
    end)

    it("renders an untransformed delivery when the prediction misses", function()
        Config.options.vision = { model = "google/gemini-2.5-pro" }
        local chat = setup_chat()
        chat:update_state({ model = { id = "qwen3-coder", input = { "text" } } })

        set_prompt(chat, "edge case")
        attach(chat, 1)
        chat:_send_message(nil)
        pump(80)
        assert.is_not_nil(chat._vision_inflight)

        -- No marker: render normally and settle the pending state. Deliver
        -- with the image still attached (the extension never transformed it).
        chat:on_message_start({
            message = {
                role = "user",
                timestamp = 1700000000000,
                content = {
                    { type = "text", text = "edge case" },
                    { type = "image", data = "QUJD", mimeType = "image/png" },
                },
            },
        })
        pump(120)
        assert.is_true(buf_contains(chat._history:buf(), "edge case"))
        assert.is_true(buf_contains(chat._history:buf(), "1 image attached"))
        assert.is_nil(chat._vision_inflight)
        assert.is_nil(chat._history._vision_pending)

        teardown_chat(chat)
    end)

    it("handles queued (steer) deliveries via prefix matching", function()
        Config.options.vision = { model = "google/gemini-2.5-pro" }
        local chat = setup_chat()
        chat:update_state({ model = { id = "qwen3-coder", input = { "text" } } })

        set_prompt(chat, "queued with image")
        attach(chat, 1)
        chat:_send_message("steer")
        pump(80)

        -- Pending queue entry, not rendered yet.
        assert.are.equal(1, #chat._history:get_pending_queue())
        assert.is_false(buf_contains(chat._history:buf(), "queued with image"))

        local transformed = "queued with image\n\n" .. Vision.make_marker("google/gemini-2.5-pro", "desc")
        deliver_user_message(chat, transformed)

        assert.are.equal(0, #chat._history:get_pending_queue())
        assert.is_true(buf_contains(chat._history:buf(), "queued with image"))
        assert.is_true(buf_contains(chat._history:buf(), "desc"))
        assert.is_nil(chat._vision_inflight)

        teardown_chat(chat)
    end)

    it("fast-fail of a queued submission drops the pending entry and restores the prompt", function()
        Config.options.vision = { model = "google/gemini-2.5-pro" }
        local chat = setup_chat()
        chat:update_state({ model = { id = "qwen3-coder", input = { "text" } } })

        set_prompt(chat, "queued fail")
        attach(chat, 1)
        chat:_send_message("steer")
        pump(80)
        assert.are.equal(1, #chat._history:get_pending_queue())

        Extension.handle({ chat = chat }, {
            method = "notify",
            notifyType = "error",
            message = "[pi-vision] instruction generation failed: nope",
        })
        pump(80)

        assert.are.equal(0, #chat._history:get_pending_queue())
        assert.are.equal("queued fail", chat._prompt:text())
        assert.are.equal(1, chat._attachments:count())

        teardown_chat(chat)
    end)
end)

describe("vision history rendering", function()
    local function setup_history()
        local h = History.new(TAB)
        vim.api.nvim_win_set_buf(0, h:buf())
        h:set_win(0)
        return h
    end

    it("renders header, model and description; collapses long descriptions", function()
        local h = setup_history()
        h:add_user_message("look", nil, nil)
        pump(60)
        local long_desc = {}
        for i = 1, 20 do
            long_desc[i] = "detail line " .. i
        end
        h:add_vision_block("openai/gpt-4o", table.concat(long_desc, "\n"))
        pump(150)

        local buf = h:buf()
        assert.is_true(buf_contains(buf, "look"))
        assert.is_true(buf_contains(buf, "vision"))
        assert.is_true(buf_contains(buf, "openai/gpt-4o"))
        -- output_visible = 8 → collapsed view keeps the tail and elides the rest.
        assert.is_true(buf_contains(buf, "detail line 20"))
        assert.is_true(buf_contains(buf, "lines"))
        assert.is_false(buf_has_exact_line(buf, "detail line 1"))

        -- Toggle round-trip expands and collapses again.
        local block = h._tool_blocks["vision-1"]
        assert.is_not_nil(block)
        h:_set_tool_block_expanded(block, true)
        pump(80)
        assert.is_true(buf_has_exact_line(buf, "detail line 1"))
        h:_set_tool_block_expanded(block, false)
        pump(80)
        assert.is_false(buf_has_exact_line(buf, "detail line 1"))

        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    it("shows the pending preview row while a transform is in flight", function()
        local h = setup_history()
        h:set_vision_pending({ text = "describe this", image_count = 2, model = "p/m" })
        pump(60)

        local ns = vim.api.nvim_create_namespace("pi-chat")
        local marks = vim.api.nvim_buf_get_extmarks(h:buf(), ns, 0, -1, { details = true })
        local found
        for _, m in ipairs(marks) do
            if m[4].virt_lines then
                for _, row in ipairs(m[4].virt_lines) do
                    for _, chunk in ipairs(row) do
                        if chunk[1]:find("describe this", 1, true) then
                            found = true
                        end
                        if chunk[1]:find("p/m", 1, true) then
                            found = found and true
                        end
                    end
                end
            end
        end
        assert.is_true(found)

        h:set_vision_pending(nil)
        pump(60)
        assert.is_nil(h._vision_pending)

        pcall(vim.api.nvim_buf_delete, h:buf(), { force = true })
    end)

    it("remove_pending_queue_entry falls back to prefix matching", function()
        local h = setup_history()
        h:add_pending_queue_entry("steer", "queued", "queued", 1)
        assert.is_nil(h:remove_pending_queue_entry("totally different"))
        assert.are.equal(1, #h:get_pending_queue())
        local entry = h:remove_pending_queue_entry('queued\n\n<pi-vision model="p/m">\nd\n</pi-vision>')
        assert.is_not_nil(entry)
        assert.are.equal("queued", entry.text)
        assert.are.equal(0, #h:get_pending_queue())
        pcall(vim.api.nvim_buf_delete, h:buf(), { force = true })
    end)
end)
