--- Vision fallback: shared helpers for image understanding via a configured
--- vision model.
---
--- When the main model cannot see images, the bundled pi extension
--- (extensions/vision.ts) describes attached images with a configured
--- vision-capable model and appends the description to the user message as a
--- marker block:
---
---     <pi-vision model="provider/modelId">
---     description…
---     </pi-vision>
---
--- This module is pure: marker construction/parsing, the decision of whether
--- a transform is expected for a submission, and the notify prefix the
--- extension uses when it fast-fails. Rendering and event wiring live in the
--- chat/history/manager modules.
local M = {}

--- Prefix of error notifications emitted by the vision extension on
--- fast-fail. pi.nvim uses it to restore the submit-time state.
M.NOTIFY_PREFIX = "[pi-vision]"

local OPEN_TAG = '<pi-vision model="'
local CLOSE_TAG = "</pi-vision>"

--- Build the marker block appended to the user message by the extension.
---@param model string "provider/modelId" that produced the description
---@param description string
---@return string
function M.make_marker(model, description)
    return OPEN_TAG .. model .. "\">\n" .. description .. "\n" .. CLOSE_TAG
end

---@class pi.VisionParseResult
---@field text string original user text (marker removed, surrounding blank lines trimmed)
---@field model string? model from the marker tag (nil when no marker)
---@field description string? description body (nil when no marker)

--- Split a user message text into the original part and the vision marker.
---@param text string
---@return pi.VisionParseResult
function M.parse(text)
    local open_start, open_end = text:find(OPEN_TAG, 1, true)
    if not open_start then
        return { text = text }
    end
    local close_start, close_end = text:find(CLOSE_TAG, open_end, true)
    if not close_start then
        return { text = text }
    end

    -- model="provider/modelId"> — value ends at the last '"' before the '>'
    local tag_end = text:find('">', open_end, true)
    if not tag_end or tag_end > close_start then
        return { text = text }
    end
    local model = text:sub(open_end + 1, tag_end - 1)

    local description = text:sub(tag_end + 2, close_start - 1)
    -- Strip the single newlines added by make_marker on both sides.
    description = description:gsub("^\n", ""):gsub("\n$", "")

    local original = text:sub(1, open_start - 1) .. text:sub(close_end + 1)
    original = vim.trim(original)

    return { text = original, model = model, description = description }
end

--- Whether a submission is expected to be transformed by the vision
--- extension, and with which model. Prediction drives the deferred render
--- (pending preview + spinner); the authoritative signal is always the
--- marker in the user-message event.
---@param opts pi.Options resolved config
---@param model_supports_vision boolean? current main model vision capability (nil = unknown)
---@param image_count integer number of image attachments
---@return string? model_ref configured vision model when a transform is expected, else nil
function M.expects_transform(opts, model_supports_vision, image_count)
    local ref = opts.vision and opts.vision.model
    if type(ref) ~= "string" or ref == "" then
        return nil
    end
    if image_count <= 0 then
        return nil
    end
    if model_supports_vision ~= false then
        -- Vision-capable or unknown: images go through untouched.
        return nil
    end
    return ref
end

--- Extract the failure reason from a vision extension error notification.
---@param message string?
---@return string? reason nil when the message is not a vision fast-fail
function M.parse_notify(message)
    if type(message) ~= "string" then
        return nil
    end
    local prefix = M.NOTIFY_PREFIX
    if message:sub(1, #prefix) ~= prefix then
        return nil
    end
    local reason = vim.trim(message:sub(#prefix + 1))
    return reason ~= "" and reason or "unknown error"
end

return M
