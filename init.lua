-- Author: Salah Eddine Ghamri
-- Change log-----------------------------------------------------------------
-- TODO: vim command-line
-- TODO: change caret in normal vim mode
-- TDOD: add basic commands
-- TODO: use set_mode that pushes a message to indicate vim mode change
-- TODO: create an option if vim global or only to doc views
-- TODO: let user extend commands

-- DONE: modal editing
-- DONE: let user extend keymaps
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
  normal_keys = {},
  visual_keys = {},
}

-- keys
local pressed = {}

-- keys that can modify text
local modifying_keys = {
  ["return"] = true,
  ["backspace"] = true,
  ["tab"] = true,
  ["delete"] = true,
  ["insert"] = true,
  ["space"] = true
}

local function handle_normal(text)
  local fn = vim.normal_keys[text]
  if fn then
      fn()
  end
  return true --block 
end

local function handle_command(text)
  -- command parser logic here
  local res = true -- return from command
  if res then
     vim.mode = "normal"    
     block_keys = true
  end
  return true -- block
end

local function handle_insert(text)
  -- TODO: define other keys
  return false
end

-- Handle printable keys
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
local original_on_event = core.on_event
function core.on_event(type, a, ...)
  if type == "textinput" then      
    if on_text(a) then
       return true -- block 
    end
  elseif type == "keypressed" then
    pressed[a] = true

    if a == "escape" then
        vim.mode = "normal"
        return true -- block
    end

    if vim.mode == "normal" then
        if modifying_keys[a] then
            return true -- block in normal mode
        end
    end

  elseif type == "keyreleased" then
    pressed[a] = false
  end

  return original_on_event(type, a, ...)
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
  [":"] = function() end,
  ["/"] = function() end,
  ["?"] = function() end,
  ["*"] = vim.search_word_under_cursor,
  ["i"] = function() vim.mode = "insert" end,
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
}

-- Visula mode keymap
vim.visual_keys = {
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
