-- Author: Salah Eddine Ghamri

-- Change log-----------------------------------------------------------------
-- TODO: give the command line a name
-- TODO: show message notifying the change of state
-- TODO: we need to set space as leader or adapt if user want space as leader
-- TODO: change caret in normal vim mode
-- TDOD: add basic commands
-- TODO: create an option if vim global or only to doc views
-- TODO: let user extend commands

-- DONE: vim command-line
-- DONE: modal editing
-- DONE: let user extend keymaps
------------------------------------------------------------------------------

-- mod-version:3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local command_line = require "plugins.command-line"
command_line.minimal_status_view = true

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

-- set instance command line
local instance_command = command_line.new()
instance_command:set_prompt(":")

-- set forward search line 
local forward_search = command_line.new()
forward_search:set_prompt("/")

-- set backward search line 
local backward_search = command_line.new()
backward_search:set_prompt("?")

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

local function handle_insert(text)
  -- TODO: define other keys
  return false
end

-- Handle printable keys
local function on_text(text)
  if vim.mode == "normal" then
    return handle_normal(text)
  elseif vim.mode == "insert" then
    return handle_insert(text)
  end
end

-- Intercept text input
local original_on_event = core.on_event
function core.on_event(type, a, ...)
  if type == "textinput" then      
    if on_text(a) then
       -- TODO: only when i pressed on_text false
       return true -- block 
    end
  elseif type == "keypressed" then
    pressed[a] = true

    if a == "escape" then
        vim.mode = "normal"
        instance_command:cancel_command()
        return true --block
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

local vim_command_map = {
  w  = { action = "doc:save", desc = "Save file" },
  q  = { action = "core:quit", desc = "Quit editor" },
  qa = { action = "core:quit-all", desc = "Quit all" },
  wq = { action = "doc:save-and-quit", desc = "Save and quit" },
}

function vim.run_command(cmd)
  local entry = vim_command_map[cmd]
  if entry then
    command.perform(entry.action)
  else
    core.log("vim unknown command: " .. cmd)
  end
end

function vim.get_suggests(input)
  local suggestions = {}
  for name, entry in pairs(vim_command_map) do
    if name:find("^" .. input) then
      table.insert(suggestions, {
        name = name,
        desc = entry.desc or "",
        action = entry.action
      })
    end
  end
  return suggestions
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

-- command to launch the command line
vim.normal_keys[":"] = function()
  vim.set_mode("command")        
  instance_command:start_command{
    submit = function(input)
      vim.run_command(input)
      vim.set_mode("normal")     
    end,
    suggest = function(input)
      return vim.get_suggests(input)
    end,
    cancel = function()
      vim.set_mode("normal")     
    end
  }
end

-- Init
vim.set_mode("normal")

return vim
