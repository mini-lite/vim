-- Change log-----------------------------------------------------------------
-- TODO:


-- DONE: first look
------------------------------------------------------------------------------
-- mod-version:3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"

local vim = {
  mode = "normal", -- visual, command
  registers = { ['"'] = "" },  -- unnamed register
  command_buffer = "",
  search_query = "",
  motion_count = "",
  command_map = {},
}

-- key detection

local function handle_normal(text)
   -- block: insert
   -- block: backspace
   -- block: space
  local block_keys = true
  if text == ":" then -- do command also
    vim.mode = "command"
  elseif text == "i" then
    vim.mode = "insert"
  end
  return block_keys
end

local function handle_command(text)
  local block_keys = true
  local res = true -- return from command
  if res then
     vim.mode = "normal"    
  end
  return block_keys
end

local function handle_insert(text)
  local block_keys = false
  -- just intercept esc
  if text == "escape" then
      vim.mode = "normal"
  end
  return block_keys
end

local function on_text(text)
  if vim.mode == "normal" then
    return handle_normal(text)
  elseif vim.mode == "command" then
    return handle_command(text)
  elseif vim.mode == "insert" then
    return handle_insert(text)
  end
end

-- Intercept text input
-- Here so that vim controls all
local original_on_event = core.on_event
function core.on_event(type, ...)
  if type == "textinput" then
    local text = ...
    if on_text(text) then
       return true -- avoid propagation
    end
  end
  return original_on_event(type, ...)
end

-- Mode switch
function vim.set_mode(m)
  vim.mode = m
end

-- Command line execution
function vim.run_command(cmd)
  if cmd == "w" then command.perform "doc:save"
  elseif cmd == "q" then command.perform "core:quit"
  else core.log("Unknown command: " .. cmd) end
end

-- Minimal search impl
function vim.search_forward(pattern)
  local doc = core.active_view.doc
  local line = doc.cursor.line
  for i = line + 1, #doc.lines do
    if doc.lines[i]:find(pattern) then
      doc:move_to(i, 1)
      return
    end
  end
  core.log("Pattern not found: " .. pattern)
end

function vim.search_backward(pattern)
  local doc = core.active_view.doc
  for i = doc.cursor.line - 1, 1, -1 do
    if doc.lines[i]:find(pattern) then
      doc:move_to(i, 1)
      return
    end
  end
  core.log("Pattern not found: " .. pattern)
end

function vim.search_word_under_cursor()
  local doc = core.active_view.doc
  local line = doc.lines[doc.cursor.line]
  local col = doc.cursor.col
  local word = line:match("%w+", col)
  if word then vim.search_forward(word) end
end

-- Normal mode keymap
vim.normal_keys = {
  [":"] = function()
    core.command_view:enter(":", function(cmd)
      vim.run_command(cmd)
    end)
  end,
  ["/"] = function()
    core.command_view:enter("/", function(query)
      vim.search_forward(query)
    end)
  end,
  ["?"] = function()
    core.command_view:enter("?", function(query)
      vim.search_backward(query)
    end)
  end,
  ["*"] = vim.search_word_under_cursor,
  ["i"] = function() vim.set_mode("insert") end,
  ["y"] = function()
    local doc = core.active_view.doc
    local line = doc.lines[doc.cursor.line]
    vim.registers['"'] = line
    core.log("Yanked line")
  end,
  ["p"] = function()
    local doc = core.active_view.doc
    local text = vim.registers['"'] or ""
    doc:insert(doc.cursor, text .. "\n")
  end,
  ["escape"] = function() vim.set_mode("normal") end,
}

-- Status bar mode indicator
core.status_view:add_item({
  name = "status:vim_mode",
  alignment = "left",
  get_item = function()
    return { style.text, "[VIM: " .. vim.mode .. "] " }
  end
})

-- Init
vim.set_mode("normal")

return vim
