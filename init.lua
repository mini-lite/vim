-- Author: S.Ghamri

-- Known issues:
-- column start at 1 which needs consideration when using vim logic
-- lite does not allow to move cursor to other position without adding new select
--      - this means that to keep selection you should not move cursor until yanking  

-- Change log-----------------------------------------------------------------
-- TODO: have a config for vim
-- TODO: enhance command line messaging system
-- TODO: if we lose focus do not react vim is asleep
-- TODO: track vim commands using a state
-- TODO: normal mode is working outside doc view
-- TODO: start adding important navigations
-- TODO: we need to set space as leader or adapt if user want space as leader
-- TDOD: add basic commands
-- TODO: create an option if vim global or only to doc views
-- TODO: let user extend commands
-- TODO: add disable vim config
-- TODO: clean collect active view and remove local definitions 
-- TODO: <NOT THAT EASY> correct cursor on selection problem, compensate everything
         -- selection region adapted
         -- make sure yank is correct
         -- put should be correct too

-- DONE: yanking shows flash of region change color to intense
-- DONE: visual select does not start from current char
-- DONE: enable yank and put
-- DONE: show message notifying the change of state
-- DONE: give the command line a name
-- DONE: change caret in normal vim mode
-- DONE: vim command-line
-- DONE: modal editing
-- DONE: let user extend keymaps
------------------------------------------------------------------------------

-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local translate = require "core.doc.translate"
local DocView = require "core.docview"

local command_line = require "plugins.command-line"
command_line.set_item_name("status:vim")
command_line.add_status_item()
command_line.minimal_status_view = true -- only item will show

local vim = {
  mode = "normal", -- normal, visual, command, insert
  registers = { ['"'] = "" },
  command_buffer = "",
  search_query = "",
  command_map = {},
  operators = {},
  motions = {},
  last_position = {}, -- save cursor position befor executions
  normal_keys = {},
  visual_keys = {},
}

-- state to track commands
local state = {
  count = 1,
  operator = nil,
  motion = nil,
  register = nil,
}

-- helper for debug
local function echo(fmt, ...)
  local text = string.format(fmt, ...)
  command_line.show_message({text}, 1)
end

-- remove selections 
local function deselect()
  for idx, line1, col1, _, _ in core.active_view.doc:get_selections(true) do
      core.active_view.doc:set_selections(idx, line1, col1)
  end
end

-- normalize count, default 1
local function get_count()
  return tonumber(state.count) or 1
end

-- reset state helper
local function reset_state()
  state.count = 1
  state.operator = nil
  state.motion = nil
  state.register = nil
  vim.command_buffer = "" -- debug
end

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

-- accumulate keys
local pending = ""
local prev_dig = false

-- input handler
local function handle_input(key)
  -- go insert
  if vim.mode == "insert" or vim.mode == "command" then
    return false
  end

  -- high prio keys
  if vim.mode == "normal" then
    -- normal key like i and v 
    if vim.normal_keys and vim.normal_keys[key] then
        vim.normal_keys[key]()
        pending = ""
        reset_state()
        return true
    end
  elseif vim.mode == "visual"  or vim.mode == "visual-line" then 
    -- visual key 
    if vim.visual_keys and vim.visual_keys[key] then
        vim.visual_keys[key]()
        pending = ""
        reset_state()
        vim.set_mode("normal") -- after y and p return to normal
        return true
    end
  end

  -- accumulate count digits only if no operator pending
  if not state.operator and (key:match("[1-9]") or (key == "0" and prev_dig )) then
    prev_dig = true
    state.count = (state.count == 1 and "" or tostring(state.count)) .. key
    return true
  end

  -- here numbers already filtered
  pending = pending .. key
  prev_dig = false

  -- try operator first
  if vim.operators[pending] then
    state.operator = vim.operators[pending]
    pending = ""
    return true
  end

  -- try motion
  if vim.motions[pending] then
    local count = get_count()
    if state.operator then
      state.operator(count, vim.motions[pending])
    else
      vim.motions[pending](count)
    end
    pending = ""
    reset_state()
    return true
  end

  -- if pending gets too long, reset
  if #pending > 2 then
    pending = ""
    reset_state()
    return true
  end
  
  return true
end

-- Handle printable keys
local function on_text(text)
    return handle_input(text)
end

-- on_event override
local original_on_event = core.on_event
function core.on_event(type, a, ...)

  if core.active_view.doc and core.active_view.doc.filename then
    if type == "textinput" then      
        if on_text(a) then
          return true -- block 
        end
    elseif type == "keypressed" then
        pressed[a] = true

        -- TODO: set arrow to look like hjkl
        if a == "down" then
            vim.motions["j"](state.count)
            return true
        end

        if a == "up" then
            vim.motions["k"](state.count)
            return true
        end

        if a == "escape" then
            vim.set_mode("normal")
            reset_state()
            instance_command:cancel_command()
            deselect()
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
  end -- active view

  return original_on_event(type, a, ...)
end

-- mode switch
function vim.set_mode(m)
    local message = ""
    if m == "normal" then
        style.caret_width = common.round(7 * SCALE)
        command_line.show_message({}, 0)     -- 0 = permanent
    elseif m == "insert" then
        style.caret_width = common.round(2 * SCALE)
        message = {
            style.accent, "-- INSERT --",
        }
        command_line.show_message(message, 0) -- 0 = permanent
    elseif m == "visual" then
        -- select current position
        -- coming from normal mode, what user is selecting is c+1
        local l, c = core.active_view.doc:get_selection() -- c starts from 1
        vim.last_position = {l=l, c=c} -- record last position to return to

        -- setup caret 
        style.caret_width = common.round(7 * SCALE)

        -- message
        message = {
            style.text, "-- VISUAL --",
        }
        command_line.show_message(message, 0) -- 0 = permanent
    elseif m == "visual-line" then
        local l, c = core.active_view.doc:get_selection() -- c starts from 1
        vim.last_position = {l=l, c=c} -- record last position to return to

        -- select line
        local doc = core.active_view.doc
        local line_text = doc.lines[l]
        doc:set_selection(l, 1, l, #line_text)
        
        -- setup caret 
        style.caret_width = common.round(7 * SCALE)

        -- message
        message = {
            style.text, "-- VISUAL-LINE --",
        }
        command_line.show_message(message, 0) -- 0 = permanent
    end
  vim.mode = m
end

-- TODO: we need a real parser
local vim_ex_commands = {
  ["w"]   = { action = "doc:save", desc = "Save file" },
  ["q"]   = { action = "core:quit", desc = "Quit editor" },
  ["q!"]  = { action = "core:force-quit", desc = "Force quit" },
  ["qa"]  = { action = "core:quit", desc = "Quit all" },
  ["e!"]  = { action = "doc:reload", desc = "reload fresh" }
}

function vim.run_command(cmd)
  local entry = vim_ex_commands[cmd]
  if entry then
    command.perform(entry.action)
  else
    core.log("vim unknown command: " .. cmd)
  end
end

function vim.get_suggests(input)
  local suggestions = {}
  for name, entry in pairs(vim_ex_commands) do
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

local function yank()
    local doc = core.active_view.doc
    local line1, col1, line2, col2 = doc:get_selection()
    if not (line1 == line2 and col1 == col2) then
        local text = doc:get_text(line1, col1, line2, col2)
        vim.registers['"'] = text
        -- TODO: change region color for sometime
        local old_selection_style = style.selection
        style.selection = style.accent
        core.redraw = true
        -- Restore after 150ms
        core.add_thread(function()
            echo("yanked! %s", text)
            -- TODO: 0.10 take as config
            coroutine.yield(0.9)
            style.selection = old_selection_style
            core.redraw = true
            deselect()
        end)
    end
end

-- define operators ---------------------------------------------------------
vim.operators = {
  -- ["d"]
  -- ["gu"]
  -- ["gU"]
  -- ["<"]
  -- [">"]
  -- ["c"]
  ["y"] = function(count, motion)
      yank()
  end,
  ["p"] = function(count, motion)
    local doc = core.active_view.doc
    local text = vim.registers['"'] or ""
    doc:insert(doc.cursor, text .. "\n")
  end,
}

-- define motions ----------------------------------------------------
local config = require "core.config"

-- helper text objects
local classify
do
  local map = {}
  for i = 0, 255 do
    map[i] = "punct"
  end
  for i = string.byte("0"), string.byte("9") do
    map[i] = "word"
  end
  for i = string.byte("A"), string.byte("Z") do
    map[i] = "word"
  end
  for i = string.byte("a"), string.byte("z") do
    map[i] = "word"
  end

  -- include as word
  map[string.byte("_")] = "word"
  map[string.byte("-")] = "word"

  for _, c in ipairs { 9, 10, 11, 12, 13, 32 } do
    map[c] = "space"
  end

  function classify(char)
    if not char or char == "" then return "eof" end
    return map[string.byte(char)] or "punct"
  end
end

local translations = {
  ["previous-char"]        = translate,
  ["next-char"]            = translate,
  ["next-word-start"] = function(doc, line, col)
    local char = doc:get_char(line, col)
    local ctype = classify(char)
  
    while true do
      line, col = doc:position_offset(line, col, 1)
      local next_char = doc:get_char(line, col)
      local next_type = classify(next_char)
      if next_type ~= ctype then
        ctype = next_type
        break
      end
    end
  
    while ctype == "space" do
      line, col = doc:position_offset(line, col, 1)
      local next_char = doc:get_char(line, col)
      ctype = classify(next_char)
    end
  
    return line, col
  end,
  ["previous-word-start"]  = function(doc, line, col)
    local char = doc:get_char(line, col)
    local ctype = classify(char)
  
    while true do
      line, col = doc:position_offset(line, col, -1)
      local next_char = doc:get_char(line, col)
      local next_type = classify(next_char)
      if next_type ~= ctype then
        ctype = next_type
        break
      end
    end
  
    while ctype == "space" do
      line, col = doc:position_offset(line, col, -1)
      local next_char = doc:get_char(line, col)
      ctype = classify(next_char)
    end
  
    return translate.start_of_word(doc, line, col)
  end,
  ["start-of-word"] = function(doc, line, col)
    local ctype = classify(doc:get_char(line, col))
    while true do
      local prev_line, prev_col = doc:position_offset(line, col, -1)
      if prev_line == line and prev_col == col then break end 
      local prev_type = classify(doc:get_char(prev_line, prev_col))
      if prev_type ~= ctype then break end
      line, col = prev_line, prev_col
    end
    return line, col
  end,
  
  ["end-of-word"] = function(doc, line, col)
    local ctype = classify(doc:get_char(line, col))
    while true do
      local next_line, next_col = doc:position_offset(line, col, 1)
      if next_line == line and next_col == col then break end 
      local next_type = classify(doc:get_char(next_line, next_col))
      if next_type ~= ctype then break end
      line, col = next_line, next_col
    end
    return line, col
  end,
  ["start-of-line"]        = translate,
  ["start-of-indentation"] = translate,
  ["end-of-line"]          = translate,
  ["start-of-doc"]         = translate,
  ["end-of-doc"]           = translate,
  ["next-line"]            = DocView.translate,
  ["previous-line"]        = DocView.translate,
  ["next-page"]            = DocView.translate,
  ["previous-page"]        = DocView.translate,
  ["next-block-end"]       = translate,
  ["previous-block-start"] = translate,
}

local function get_motion_fn(name)
  local obj = translations[name]
  if type(obj) == "function" then
    return obj
  elseif obj then
    return obj[name:gsub("-", "_")]
  end
  return nil
end

vim.motions = {
   ["h"] = function(count)
     local dv = core.active_view
     local motion_fn = get_motion_fn("previous-char")
     local l, c = dv.doc:get_selection()
   
     if not motion_fn then return end
     for _ = 1, count do
       if vim.mode == "visual" then
         l, c = dv.doc:position_offset(l, c, -1)
         dv.doc:set_selection(l, c, vim.last_position.l, vim.last_position.c)
       else
         dv.doc:move_to(motion_fn, dv)
       end
     end
   end,

   ["l"] = function(count)
     local dv = core.active_view
     local motion_fn = get_motion_fn("next-char")
     local l, c = dv.doc:get_selection()

     if not motion_fn then return end
     for _ = 1, count do
       if vim.mode == "visual" then
         l, c = dv.doc:position_offset(l, c, 1)
         dv.doc:set_selection(l, c, vim.last_position.l, vim.last_position.c)
       else
         dv.doc:move_to(motion_fn, dv)
       end
     end
   end,

  ["j"] = function(count)
    local dv = core.active_view
    local fn = get_motion_fn("next-line")
    local fn_end = get_motion_fn("end-of-line")
    local fn_back = get_motion_fn("previous-char")
    
    if not fn then return end
        for _ = 1, count do
        if vim.mode == "visual-line" then
            local old_line, old_col = dv.doc:get_selection()
            dv.doc:move_to(fn, dv)
            dv.doc:move_to(fn_end, dv)
            dv.doc:move_to(fn_back, dv)
            local nl, c, _, _ = dv.doc:get_selection()
            if nl == old_line then
               dv.doc:move_to(fn, dv)
               nl, c, _, _ = dv.doc:get_selection()
            end
            dv.doc:set_selection(nl, c+1, vim.last_position.l, 1)
        else
            dv.doc:move_to(fn, dv)
        end
    end
  end,

  ["k"] = function(count)
    local dv = core.active_view
    local fn = get_motion_fn("previous-line")
    local fn_end = get_motion_fn("start-of-line")
    --local fn_back = get_motion_fn("next-char")
    if not fn then return end
        for _ = 1, count do
        if vim.mode == "visual-line" then
            local old_line, old_col = dv.doc:get_selection()
            dv.doc:move_to(fn, dv)
            dv.doc:move_to(fn_end, dv)
            --dv.doc:move_to(fn_back, dv)
            local nl, c, _, _ = dv.doc:get_selection()
            if nl == old_line then
               dv.doc:move_to(fn, dv)
               nl, c, _, _ = dv.doc:get_selection()
            end
            local text = dv.doc.lines[vim.last_position.l]
            dv.doc:set_selection(nl, c, vim.last_position.l, #text)
        else
            dv.doc:move_to(fn, dv)
        end
    end
  end,

  ["w"] = function(count)
    local dv = core.active_view
    count = count or 1
    local next_word_start = get_motion_fn("next-word-start")
    for _ = 1, count do
        dv.doc:move_to(next_word_start, dv)
    end
  end,

  ["b"] = function(count)
    local dv = core.active_view
    local previous_word_start = get_motion_fn("previous-word-start")
    count = count or 1
    for _ = 1, count do
        dv.doc:move_to(previous_word_start, dv)
    end
  end,

  ["e"] = function(count)
    local dv = core.active_view
    count = count or 1
    local next_word_start = get_motion_fn("next-word-start")
    for _ = 1, count do
        dv.doc:move_to(next_word_start, dv)
        dv.doc:move_to(translations["end-of-word"], dv)
    end
  end,

  ["0"] = function()
    local doc = core.active_view.doc
    local line, _ = doc:get_selection()
    doc:set_selection(line, 1)
  end,

  ["^"] = function()
    local doc = core.active_view.doc
    local line, _ = doc:get_selection()
    local text = doc.lines[line] or ""
    local first_non_ws = text:find("%S") or 1
    doc:set_selection(line, first_non_ws)
  end,

  ["$"] = function()
    local doc = core.active_view.doc
    local line, _ = doc:get_selection()
    local text = doc.lines[line] or ""
    local last_col = #text + 1
    doc:set_selection(line, last_col)
  end,

  ["gg"] = function(count)
    local doc = core.active_view.doc
    local line = count or 1
    doc:set_selection(line, 1)
  end,

  ["G"] = function()
    local doc = core.active_view.doc
    local last_line = #doc.lines
    local last_col = #(doc.lines[last_line] or "") + 1
    doc:set_selection(last_line, last_col)
  end,
  ["i"] = function(obj)
      if vim.mode == "visual" then
          if obj == "w" then
          -- TODO: select current word without spaces
          end
      end
  end,
  ["a"] = function(obj)
      if vim.mode == "visual" then
          if obj == "w" then
          -- TODO: select current word without spaces
          end  
      end
  end,
}

-- normal keymaps
vim.normal_keys = {
  [":"] = function() end,
  ["/"] = function() end,
  ["?"] = function() end,
  ["*"] = vim.search_word_under_cursor,
  ["i"] = function()
    vim.set_mode("insert")
  end,
  ["v"] = function()
    vim.set_mode("visual")
  end,
  ["V"] = function(count, motion)
      vim.set_mode("visual-line")
  end,
  ["p"] = function(count, motion)
    local doc = core.active_view.doc
    local text = vim.registers['"'] or ""
    local line, col = doc:get_selection()
    doc:insert(line, col, text)
  end,
  ["u"] = function()
    local doc = core.active_view.doc
    doc:undo()
    echo("undo")
  end
}

-- Visula mode keymap
vim.visual_keys = {
  ["y"] = function(count, motion)
      yank()
  end,

  ["V"] = function(count, motion)
      vim.set_mode("visual-line")
  end,
}

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
