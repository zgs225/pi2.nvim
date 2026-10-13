-- Chat:delete_pending_at_cursor — `dd` on a pending queued message in the
-- history buffer removes that single entry (compaction-held locally, or via
-- a clear_queue + re-enqueue transaction for pi-queued entries) and copies
-- its raw text into the unnamed register.

local Chat = require("pi.ui.chat")

local TAB = 1320

local function pump(ms)
    vim.wait(ms or 60)
end

local function teardown_chat(chat)
    pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
end

--- Chat whose send captures all commands and the latest clear_queue callback.
local function setup_chat()
    local sent = {}
    local clear_cb
    local chat = Chat.new(TAB, "side", {
        send = function(cmd, cb)
            sent[#sent + 1] = cmd
            if cmd.type == "clear_queue" then
                clear_cb = cb
            end
            return true
        end,
    })
    -- Fallback if History:remove_pending_queue_entry_at is not yet present on History.
    if not chat._history.remove_pending_queue_entry_at then
        chat._history.remove_pending_queue_entry_at = function(self, idx)
            local entry = self._pending_queue[idx]
            if not entry then
                return nil
            end
            table.remove(self._pending_queue, idx)
            self:_update_status_extmark()
            self:_emit_queue_count()
            return entry
        end
    end
    return chat, sent, function()
        return clear_cb
    end
end

local function set_prompt_local(chat, text)
    vim.api.nvim_buf_set_lines(chat._prompt:buf(), 0, -1, false, vim.split(text, "\n", { plain = true }))
end

---@param chat pi.Chat
---@param queue_type "steer"|"follow_up"
---@param text string
---@param expanded string
---@param images? table[]
local function add_pending(chat, queue_type, text, expanded, images)
    local image_count = images and #images or nil
    chat._history:add_pending_queue_entry(queue_type, text, expanded, image_count, images)
    local q = chat._history._pending_queue
    if images and q[#q] and not q[#q].images then
        q[#q].images = images
    end
end

describe("chat dd delete pending queued message", function()
    local notices
    local orig_notify

    before_each(function()
        notices = {}
        orig_notify = vim.notify
        vim.notify = function(msg, level)
            notices[#notices + 1] = { msg = msg, level = level }
        end
        vim.fn.setreg('"', "")
    end)

    after_each(function()
        vim.notify = orig_notify
    end)

    ---@param sub string
    ---@return table? notice
    local function find_notice(sub)
        for _, n in ipairs(notices) do
            if n.msg:find(sub, 1, true) then
                return n
            end
        end
        return nil
    end

    it("is a no-op when cursor is not on a pending entry", function()
        local chat, sent = setup_chat()
        add_pending(chat, "steer", "queued 1", "queued 1")
        chat._history.pending_index_at = function()
            return nil
        end

        chat:delete_pending_at_cursor()
        pump()

        assert.are.equal(0, #sent)
        assert.are.equal(1, #chat._history:get_pending_queue())
        assert.are.equal("", vim.fn.getreg('"'))

        teardown_chat(chat)
    end)

    it("deletes compaction-held entry locally without RPC and yanks to unnamed register", function()
        local chat, sent = setup_chat()
        chat._compacting = true
        set_prompt_local(chat, "compaction msg")
        chat:_queue_compaction_message("steer")

        assert.are.equal(1, #chat._compaction_queue)
        assert.are.equal(1, #chat._history:get_pending_queue())

        chat._history.pending_index_at = function()
            return 1
        end

        chat:delete_pending_at_cursor()
        pump()

        assert.are.equal(0, #sent)
        assert.are.equal(0, #chat._compaction_queue)
        assert.are.equal(0, #chat._history:get_pending_queue())
        assert.are.equal("compaction msg", vim.fn.getreg('"'))

        teardown_chat(chat)
    end)

    it(
        "clears pi queue, removes target, re-enqueues survivors in order, and pauses queue_update during transaction",
        function()
            local chat, sent, get_clear_cb = setup_chat()
            chat._streaming = true
            add_pending(chat, "steer", "s1", "s1")
            add_pending(chat, "steer", "s2-target", "s2-target")
            add_pending(chat, "follow_up", "f1", "f1")

            chat._history.pending_index_at = function()
                return 2
            end

            chat:delete_pending_at_cursor()

            assert.are.equal("s2-target", vim.fn.getreg('"'))
            assert.are.equal(1, #sent)
            assert.are.equal("clear_queue", sent[1].type)
            assert.is_true(chat._queue_sync_paused)

            -- While paused, an empty queue_update from pi must not wipe local pending entries.
            chat:on_queue_update({ type = "queue_update", steering = {}, followUp = {} })
            assert.are.equal(3, #chat._history:get_pending_queue())

            get_clear_cb()({
                type = "response",
                command = "clear_queue",
                success = true,
                data = { steering = { "s1", "s2-target" }, followUp = { "f1" } },
            })
            pump()

            assert.is_false(chat._queue_sync_paused)

            local remaining = chat._history:get_pending_queue()
            assert.are.equal(2, #remaining)
            assert.are.equal("s1", remaining[1].expanded_text)
            assert.are.equal("f1", remaining[2].expanded_text)

            -- Sent sequence: clear_queue, then steer s1, then follow_up f1
            assert.are.equal(3, #sent)
            assert.are.equal("clear_queue", sent[1].type)
            assert.are.same({ type = "steer", message = "s1" }, sent[2])
            assert.are.same({ type = "follow_up", message = "f1" }, sent[3])

            -- After transaction completes, on_queue_update is active again.
            chat:on_queue_update({ type = "queue_update", steering = { "s1" }, followUp = { "f1" } })
            assert.are.equal(2, #chat._history:get_pending_queue())

            teardown_chat(chat)
        end
    )

    it("preserves images on surviving entries and passes images from _send_message", function()
        local chat, sent, get_clear_cb = setup_chat()
        chat._streaming = true

        -- Verify _send_message passes 5th argument `images` to add_pending_queue_entry.
        local captured_fifth_arg
        local orig_add = chat._history.add_pending_queue_entry
        chat._history.add_pending_queue_entry = function(self, qtype, text, expanded, img_count, imgs)
            captured_fifth_arg = imgs
            orig_add(self, qtype, text, expanded, img_count, imgs)
            local q = self._pending_queue
            if imgs and q[#q] and not q[#q].images then
                q[#q].images = imgs
            end
        end

        chat._attachments:_add_item("pic.png", "aGVsbG8=", "image/png", 5)
        set_prompt_local(chat, "with image")
        chat:_send_message("steer")

        assert.is_table(captured_fifth_arg)
        assert.are.same({ { type = "image", data = "aGVsbG8=", mimeType = "image/png" } }, captured_fifth_arg)

        -- Add a second entry to delete so the first (with image) is a survivor.
        add_pending(chat, "follow_up", "drop me", "drop me")
        sent[1] = nil -- clear initial send from _send_message
        chat._history.pending_index_at = function()
            return 2
        end

        chat:delete_pending_at_cursor()
        get_clear_cb()({
            type = "response",
            command = "clear_queue",
            success = true,
            data = { steering = { "with image" }, followUp = { "drop me" } },
        })
        pump()

        assert.are.equal(2, #sent)
        assert.are.equal("clear_queue", sent[1].type)
        assert.are.same({
            type = "steer",
            message = "with image",
            images = { { type = "image", data = "aGVsbG8=", mimeType = "image/png" } },
        }, sent[2])

        teardown_chat(chat)
    end)

    it("sends the first survivor as prompt when chat._streaming == false", function()
        local chat, sent, get_clear_cb = setup_chat()
        chat._streaming = false
        add_pending(chat, "steer", "drop", "drop")
        add_pending(chat, "steer", "wake-up", "wake-up")
        add_pending(chat, "follow_up", "later", "later")

        chat._history.pending_index_at = function()
            return 1
        end

        chat:delete_pending_at_cursor()
        get_clear_cb()({
            type = "response",
            command = "clear_queue",
            success = true,
            data = { steering = { "drop", "wake-up" }, followUp = { "later" } },
        })
        pump()

        assert.are.equal(3, #sent)
        assert.are.equal("clear_queue", sent[1].type)
        assert.are.same({ type = "prompt", message = "wake-up" }, sent[2])
        assert.are.same({ type = "follow_up", message = "later" }, sent[3])

        teardown_chat(chat)
    end)

    it("warns and keeps local pending entries when clear_queue response has no data (pi < 1.1.0)", function()
        local chat, sent, get_clear_cb = setup_chat()
        chat._streaming = true
        add_pending(chat, "steer", "keep me", "keep me")

        chat._history.pending_index_at = function()
            return 1
        end

        chat:delete_pending_at_cursor()
        get_clear_cb()({
            type = "response",
            command = "clear_queue",
            success = true,
        })
        pump()

        assert.is_false(chat._queue_sync_paused)
        assert.are.equal(1, #sent)
        assert.are.equal(1, #chat._history:get_pending_queue())
        local warn = find_notice("requires pi 1.1.0")
        assert.is_not_nil(warn)
        assert.are.equal(vim.log.levels.WARN, warn.level)

        teardown_chat(chat)
    end)

    it("records compaction-queued messages in prompt history and resets nav", function()
        local chat = setup_chat()
        chat._compacting = true

        local added = {}
        local nav_reset = false
        chat._history_store = function()
            return {
                add = function(_, text)
                    added[#added + 1] = text
                end,
            }
        end
        chat._prompt_nav = {
            reset = function()
                nav_reset = true
            end,
        }

        set_prompt_local(chat, "recallable compaction msg")
        chat:_queue_compaction_message("follow_up")

        assert.are.same({ "recallable compaction msg" }, added)
        assert.is_true(nav_reset)

        teardown_chat(chat)
    end)
end)
