-- Author: S.Ghamri

-- BUGS ----------------------------------------------------------------------

-- FIX: vi{ includes last } if first char on line
-- FIX: clean i and a, maybe they can become translations since same arguments
-- FIX: more tests to the inner and around scenarios

-- FEATURES ------------------------------------------------------------------

-- TODO: update README
-- TODO: clean code before becoming unmaintable (KISS)
-- TODO: Ctrl-r redo
-- TODO: . think about how to implement repeat last change
-- TODO: r replace single character. next key goes in place of selected char
-- TODO: ~ toggle case of the current char

-- TODO: add second count to implement something like 3d2k
-- TODO: follow delete() naming and reduce noise adopt short naming
-- TODO: add mechanisms to use registers, yank and put can accept register argument

-- TODO: it must be under 1000 lines of code
-- TODO: shift is still selecting in normal disable it, either disable this or support it
-- TODO: normal mode is working outside doc view, to benifit from : command line outside
-- TODO: "space" can be used as leader or adapt if user want space as leader
-- TODO: let user extend commands
-- TODO: add disable vim config, to allow user enable or disable it
-- TODO: how to test vim, it is starting to be big, minor change is going to effect other areas
-- TODO: enable only overrides only when vim plugin is loaded
-- TODO: <command line> enhance command line messaging system with FiFo with time

-- DONE -----------------------------------------------------------------------

-- DONE: enable x and X  and s and S a single character deletion
-- DONE: enable f and F motion to jump to next character (translation)
-- DONE: implement % to match brackets
-- DONE: put does not make selection at the end in multiple lines
-- DONE: yy yank a line
-- DONE: put can handle clipboard , add a config that allows vim system to use clipboard
-- DONE: copy path of the current file in clipboard
-- DONE: start pomping a command parser, user can add custom commands
-- DONE: delete multiple lines throws selection below we should stay on top
-- DONE: check unused variables, enable lsp and reformat code
-- DONE: we are moving to center even if visible when clicking $
-- DONE: add default operators to vim operators
-- DONE: add a config to use only / and ? to search entire file
-- DONE: clean yank paths
--      - normalize select, delete, put, move.
--      - they must use same coordinates, same clear logic for the future.
-- DONE: cursor hides after putting multiple lines
-- DONE: enhance put()
--       - dd does does yank but put does not recognize is full line to yank below
--       - put adds one character when yanked is visual line
-- DONE: search returns a selection we should be able to yank directly (normal + 1 selection = yank possible)
-- DONE: delete what is selected, we need a mode o-pending where motion for operation
-- DONE: refactor to simplify motions code
-- DONE: start adding important navigations
-- DONE: let's escape pass through
-- DONE: reverse search is not working
-- DONE: implement start *
-- DONE: now turn logic into a state machine to turn the emulation realistic
--          handle_input is the state_machine run logic
--          rely of delete_to, select_to and move_to otherwise we define our own
-- DONE: caret is adapting to text size
-- DONE: correct visual j k behavior
-- DONE: motions can be function that accept text objects
-- DONE: deleting a line does not leave an empty line behind
-- DONE: track vim commands using a state
-- DONE: puting also flashes and yanking flashes in all situations
-- DONE: p and P insert even when empty. when adding a new line go selection to beginning of that line
-- DONE: insert next line o and O
-- DONE: fix the put in the next line no added empty line we must ensure that only one \n exists
-- DONE: any delete will go to register to be put
-- DONE: key flow in insert is not smooth, is typing smooth now ???
-- DONE: vim is overriding arrows in normal mode
-- DONE: dd delete
-- DONE: a bug we need to click ddd to get dd
-- DONE: copy is adding new lines
-- DONE: enhance visual line mode
-- DONE: correct cursor on selection problem, override all doc view related functions
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
local style = require "core.style"
local translate = require "core.doc.translate"
local DocView = require "core.docview"
local config = require "core.config"
local search = require "core.doc.search"

-- vim plugin defaults
---@class VimConfig
---@field unified_search boolean
---@field unnamedplus boolean
---@class core.config
---@field vim VimConfig
config.vim = {
  unified_search = true,
  unnamedplus = true,
}

-- m: forward definitions
local get_translation
local resolve_motion
local get_region
local find_match

-- m: require
local command_line = require "plugins.command-line"
command_line.set_item_name("status:vim")
command_line.add_status_item()
command_line.minimal_status_view = true -- only item will show

-- helper for debug
local function echo(fmt, ...)
  local text = string.format(fmt, ...)
  command_line.show_message({ text }, 1)
end

-- TODO: rework this part I am not sure. is the width correct
local base_caret_width = 10
local function update_caret_width()
  local scale = 1
  local base_font_size = 20 -- TODO: enhance how caret size is calculated
  scale = style.code_font:get_size() / base_font_size
  style.caret_width = math.floor(base_caret_width * scale + 0.5)
end

local function get_doc()
  local dv = core.active_view
  if not dv or not dv.doc then
    return nil
  end
  return dv.doc
end

local function center_selection_in_view(_, line)
  local docview = core.active_view
  if not docview then return end
  local minl, maxl = docview:get_visible_line_range()
  local center = true
  if line <= maxl + 1 and line >= minl - 1 then
    return
  end
  docview:scroll_to_line(line, false, center)
end

local vim = {
  mode = "normal", -- normal, visual, command, insert, delete
  registers = {
    ['"'] = "",    -- unnamed register
    ['0'] = "",    -- yank register
    ['1'] = "",    -- last delete
    ['+'] = "",    -- system clipboard
    ['*'] = ""     -- primary selection (linux)
    -- "% : abs_filename
    -- "/ : last search query (vim.search_query)
  },
  command_buffer = "",
  search_query = "",
  command_map = {},
  operators = {},
  motions = {},
  last_position = {}, -- save cursor position befor executions
  max_col = 0,
  normal_keys = {},
  visual_keys = {},
  remap_keys = {},
  dir = 0,
}

-- state to track commands
local state = {
  count = 1,
  operator = nil,
  text_object = nil,
  motion_prefix = nil,
  motion = nil,
  register = nil,
}

-- remove selection
local function deselect()
  local doc = get_doc()
  if not doc then return end
  for idx, _, _, line2, col2 in doc:get_selections(true) do
    doc:set_selections(idx, line2, col2)
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
  state.motions_prefix = nil
  state.register = nil
  state.text_object = nil
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

-- keys that can modify text
local modifying_keys = {
  ["return"] = true,
  ["backspace"] = true,
  ["tab"] = true,
  ["delete"] = true,
  ["insert"] = true,
  ["space"] = true
}

-- keys remaps
vim.remap_keys = {
  ["down"]  = "j",
  ["up"]    = "k",
  ["left"]  = "h",
  ["right"] = "l",
}

-- accumulate keys
local pending = ""
local prev_dig = false

-- m: input_handler
local function handle_input(key)
  if vim.mode == "insert" or vim.mode == "command" then
    return false -- release input
  end

  -- pending too long, reset
  if #pending > 3 then
    pending = ""
    reset_state()
    return true
  end

  -- accumulate count digits only if no operator pending
  if not state.operator and (key:match("[1-9]") or (key == "0" and prev_dig)) then
    prev_dig = true
    state.count = (state.count == 1 and "" or tostring(state.count)) .. key
    return true
  end

  pending = pending .. key -- by now all numbers are filtred
  prev_dig = false         -- other key then digit is pressed

  if vim.mode == "normal" then
    state.operator = vim.operators["move"] -- default normal mode operator

    -- we have composite motion
    if not (#pending == 2 and pending:sub(1, 1):match("[fFtT]")) then
      -- normal key like i and v but we are not in middle of motion
      if vim.normal_keys and vim.normal_keys[key] then
        vim.normal_keys[key]()
        pending = ""
        reset_state()
        return true
      end

      if vim.normal_keys and vim.normal_keys[pending] then
        vim.normal_keys[pending]()
        pending = ""
        reset_state()
        return true
      end
    end
  elseif vim.mode == "visual" or vim.mode == "visual-line" then
    if vim.visual_keys and vim.visual_keys[key] then
      vim.visual_keys[key]()
      pending = ""
      reset_state()
      vim.set_mode("normal")
      return true
    end
  end

  if vim.mode == "visual" then
    state.operator = vim.operators["select"]
  end

  if vim.mode == "visual-line" then
    state.operator = vim.operators["line_select"]
  end

  -- 1. operator go o-pending waiting for motion
  if vim.operators[pending] and vim.mode ~= "o-pending" then
    state.operator = vim.operators[pending]
    if vim.mode == "visual" or vim.mode == "visual-line" then
      state.operator()
      reset_state()
    else
      vim.set_mode("o-pending")
    end
    pending = ""
    return true
  end

  -- 2. simple motions like h, j, k, l, w, e, etc.
  if vim.motions[pending] then
    local count = get_count()
    if state.operator then -- there is an operator already
      state.operator(count, vim.motions[pending], nil, nil)
    end
    pending = ""
    reset_state()
    return true
  end

  -- 3. pending with prefix i or a
  if #pending == 2 and pending:sub(1, 1):match("[iafFtT]") then
    state.motion_prefix = pending:sub(1, 1)
    state.text_object = pending:sub(2, 2)

    if state.motion_prefix and state.text_object then
      local count = get_count()
      state.operator(count, nil, state.motion_prefix, state.text_object)
      pending = ""
      reset_state()
      return true
    end
  end

  return true
end

-- m: on_event override
local original_on_event = core.on_event
function core.on_event(type, a, ...)
  local doc = get_doc()

  if doc and doc.filename then
    if type == "textinput" then
      if handle_input(a) then
        return true -- block
      end
    elseif type == "keypressed" then
      -- some key remaps to input
      if vim.remap_keys[a] and vim.mode ~= "normal" then
        if handle_input(vim.remap_keys[a]) then
          return true
        end
      end

      if a == "escape" then -- no return to let escape reach other modules
        instance_command:cancel_command()
        forward_search:cancel_command()
        deselect()
        pending = ""
        reset_state()
        vim.set_mode("normal")
      end

      if vim.mode == "normal" then
        if modifying_keys[a] then
          return true -- block in normal mode
        end
      end
    elseif type == "keyreleased" then
      -- released
    end
  end -- active view

  return original_on_event(type, a, ...)
end

local function return_to_line()
  local doc = get_doc()
  if not doc then return end

  local l, c = doc:get_selection()
  local line_text = doc.lines[l] or ""
  if c > #line_text - 1 then
    doc:set_selection(l, #line_text - 1, l, #line_text - 1)
  end
end

-- m: mode_switch
function vim.set_mode(m)
  local message = {}
  if m == "normal" then
    return_to_line()
    style.caret_width = common.round(7 * SCALE)
    update_caret_width()
    command_line.show_message({}, 0) -- 0 = permanent
  elseif m == "insert" then
    style.caret_width = common.round(1.5 * SCALE)
    message = {
      style.accent, "-- INSERT --",
    }
    command_line.show_message(message, 0) -- 0 = permanent
  elseif m == "visual" then
    local doc = get_doc()
    if not doc then return end
    local l, c = doc:get_selection()     -- c starts from 1
    vim.last_position = { l = l, c = c } -- record last position to return to
    style.caret_width = common.round(7 * SCALE)
    update_caret_width()
    message = {
      style.text, "-- VISUAL --",
    }
    command_line.show_message(message, 0) -- 0 = permanent
  elseif m == "visual-line" then
    local doc = get_doc()
    if not doc then return end
    local l, c = doc:get_selection()                         -- c starts from 1
    vim.last_position = { l = l, c = c, ll = #doc.lines[l] } -- record last position to return to
    doc:set_selection(l, #doc.lines[l], l, 1)
    style.caret_width = common.round(7 * SCALE)
    update_caret_width()
    message = {
      style.text, "-- VISUAL-LINE --",
    }
    command_line.show_message(message, 0) -- 0 = permanent
  elseif m == "o-pending" then
    message = {
      style.text, "-- O-PENDING --",
    }
    command_line.show_message(message, 0) -- 0 = permanent
  end
  vim.mode = m
end

-- default ex commands
local vim_ex_commands = {
  ["w"]    = { action = "doc:save", desc = "Save file" },
  ["q"]    = { action = "core:quit", desc = "Quit editor" },
  ["q!"]   = { action = "core:force-quit", desc = "Force quit" },
  ["qa"]   = { action = "core:quit", desc = "Quit all" },
  ["e!"]   = { action = "doc:reload", desc = "Reload fresh" },
  ["bd"]   = { action = "root:close", desc = "Delete buffer" },
  ["path"] = {
    action = function()
      local doc = get_doc()
      if not doc then
        return
      end
      local filepath = doc.abs_filename
      system.set_clipboard(filepath)
      echo("%s", filepath)
    end,
    desc = "Retrieve File Path"
  },
}

-- vim.register_command("greet", function(name) core.log("Hello, " .. (name or "world") .. "!") end, "Greet someone")
function vim.register_command(cmd, action, desc)
  if not cmd or not action then
    core.log("invalid command registration")
    return
  end
  vim_ex_commands[cmd] = { action = action, desc = desc or "" }
end

-- run command with optional arguments
function vim.run_command(cmd, ...)
  local entry = vim_ex_commands[cmd]
  if not entry then
    core.log("vim unknown command: " .. cmd)
    return
  end

  if type(entry.action) == "function" then
    entry.action(...)
  else
    command.perform(entry.action, ...)
  end
end

function vim.forward_search(query)
  local doc = get_doc()
  if not doc then return end
  local line, col, line2, col2
  local l, c = doc:get_selection()
  line, col, line2, col2 = search.find(doc, l, c, query, { wrap = config.vim.unified_search })

  if (line and col and line2 and col2) then
    vim.search_query = query
    doc:set_selection(line2, col2 - 1, line, col)
    center_selection_in_view(doc, line)
  end
end

function vim.backward_search(query)
  local doc = get_doc()
  if not doc then return end
  local l, c = doc:get_selection()
  local line, col, line2, col2 = search.find(doc, l, c, query, { wrap = config.vim.unified_search, reverse = true })
  if (line and col and line2 and col2) then
    vim.search_query = query
    doc:set_selection(line, col, line2, col2 - 1)
    center_selection_in_view(doc, line)
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

local function get_text(line1, col1, line2, col2) -- m: get_text
  local doc = get_doc()
  if not doc then return end

  if line1 > line2 or (line1 == line2 and col1 > col2) then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end

  local out = {}
  for line = line1, line2 do
    local t = doc.lines[line] or ""
    local s = (line == line1) and col1 or 1
    local e = (line == line2) and col2 or #t
    out[#out + 1] = t:sub(s, e)
  end

  return table.concat(out, "")
end

-- m: flash()
local function flash(l1, c1, l2, c2, color, time, doc)
  core.add_thread(function()
    local old_caret_width = style.caret_width
    style.caret_width = 0
    local old_selection_style = style.selection
    style.selection = color
    doc:set_selection(l1, c1, l2, c2)
    coroutine.yield(time)
    style.caret_width = old_caret_width
    style.selection = old_selection_style
    core.redraw = true
    deselect() -- NOTE: we may lose selection
  end)
end

local function y_type(doc, text, l1, c1, l2, c2)
  local line_width = 0
  if l1 == l2 then -- single line case
    line_width = #doc.lines[l1]
    if #text == line_width then
      return "line"
    end
  else
    if (c1 == 1 and c2 == #doc.lines[l2]) or (c2 == 1 and c1 == #doc.lines[l1]) then
      return "line"
    end
  end
  return "char"
end

-- m: yank()
local function yank(l1, c1, l2, c2, flash_time)
  local ft = flash_time or 0
  local flash_color = style.accent
  local doc = get_doc()
  if not doc then return end
  if not (l1 and c1 and l2 and c2) then
    l1, c1, l2, c2 = doc:get_selection()
  end
  local yank_type = "char"
  local text = get_text(l1, c1, l2, c2)
  if not text then return end
  yank_type = y_type(doc, text, l1, c1, l2, c2)

  -- update registers
  if config.vim.unnamedplus then
    system.set_clipboard(text)
    vim.registers['+'] = { text = text, type = yank_type } -- clipboard does not have metadata
  end
  vim.registers['"'] = { text = text, type = yank_type }

  -- only when yank
  vim.registers['0'] = { text = text, type = yank_type }

  if ft ~= 0 then
    flash(l1, c1, l2, c2, flash_color, ft, doc)
  end
end

-- m: delete()
local function delete(el, ec, sl, sc)
  local doc = get_doc()
  if not doc then return end
  if not (el and ec and sl and sc) then
    el, ec, sl, sc = doc:get_selection()
  end
  local reg_text = get_text(sl, sc, el, ec)
  if not reg_text then return end
  local yank_type = y_type(doc, reg_text, sl, sc, el, ec)
  local text = ""

  if el == sl then
    text = doc.lines[el]
    if ec >= sc then
      if ec == #text then el, ec = el + 1, 1 else ec = ec + 1 end
    else
      if sc == #text then sl, sc = sl + 1, 1 else sc = sc + 1 end
    end
  elseif el > sl then
    text = doc.lines[el]
    if ec == #text then el, ec = el + 1, 1 else ec = ec + 1 end
  else
    text = doc.lines[sl]
    if sc == #text then sl, sc = sl + 1, 1 else sc = sc + 1 end
  end

  -- TODO: do i need this part ?
  if sl > el or (sl == el and sc > ec) then
    sl, el, sc, ec = el, sl, ec, sc
  end

  if config.vim.unnamedplus then
    system.set_clipboard(reg_text)
    vim.registers['+'] = { text = reg_text, type = yank_type }
  end
  vim.registers['"'] = { text = reg_text, type = yank_type }
  vim.registers['1'] = { text = reg_text, type = yank_type }
  doc:remove(sl, sc, el, ec)
end

-- m: put()
local function put(direction, count)
  count = count or 1
  local doc = get_doc()
  if not doc then return end
  local flash_time = 0.2
  local flash_color = style.selection

  local l, c = doc:get_selection()

  local reg = vim.registers['"'] or { text = "", type = "char" }
  local yank_type = reg.type or "char"

  if config.vim.unnamedplus then
    reg = { text = system.get_clipboard(), type = "char" }
    if vim.registers['+'].text == reg.text then
      yank_type = vim.registers['+'].type
    else
      vim.registers['+'] = reg
    end
  end

  if not reg.text then return end
  local text = reg.text or ""

  if direction ~= "up" then
    direction = "down"
  end

  local lines = {}
  for line in text:gmatch("([^\n]+)") do
    table.insert(lines, line)
  end

  for _ = 1, count do
    if yank_type == "line" then
      local insert_line = direction == "down" and (l + 1) or l
      local line_textt = ""
      if direction == "down" then
        for i = #lines, 1, -1 do
          line_textt = lines[i]
          if not line_textt:match("\n$") then
            line_textt = line_textt .. "\n"
          end
          doc:insert(insert_line, 1, line_textt)
          doc:set_selection(insert_line, 1)
        end
        flash(insert_line, 1, insert_line + #lines - 1, #lines[#lines], flash_color, flash_time, doc)
      else
        for i, line_text in ipairs(lines) do
          if not line_text:match("\n$") then
            line_textt = line_text .. "\n"
          end
          doc:insert(insert_line + i - 1, 1, line_textt)
          doc:set_selection(insert_line + i - 1, 1)
        end
        flash(insert_line, 1, insert_line + #lines - 1, #line_textt, flash_color, flash_time, doc)
      end
    else                         -- char
      doc:insert(l, c + 1, text) -- +1 after cursor
      local nl, nc = doc:position_offset(l, c, #text)
      doc:set_selection(nl, nc)
      flash(l, c + 1, nl, nc, flash_color, flash_time, doc)
    end
  end
end

resolve_motion = function(motion, motion_prefix, text_object)
  local doc = get_doc()
  if not doc then return end
  local l2, c2 = doc:get_selection()

  if motion_prefix and text_object then
    if motion_prefix == "a" or motion_prefix == "i" then
      return get_region(l2, c2, motion_prefix, text_object)
    elseif motion_prefix == "f" or motion_prefix == "F" then
      core.log("%s %s", motion_prefix, text_object)
      local this_char = get_translation("this-char")
      local dir = motion_prefix == "f" and 1 or -1
      local l1, c1 = this_char(doc, l2, c2, text_object, dir)
      return l1, c1, l2, c2
    end
  end

  if motion and type(motion) == "function" then
    -- new l, new c, old l, old c
    return motion(doc, l2, c2)
  end
end


-- m: operators
-- operator by definition needs a motion (area to work on)
vim.operators = {

  ["move"] = function(count, motion, motion_prefix, text_object)
    local doc = get_doc()
    if not doc then return end
    local l1, c1, l2, c2
    for _ = 1, count do
      l1, c1, l2, c2 = resolve_motion(motion, motion_prefix, text_object)
    end
    if not (l1 and c1 and l2 and c2) then
      return
    end
    doc:set_selection(l1, c1, l1, c1)
    center_selection_in_view(doc, l1)
  end,

  ["select"] = function(_, motion, motion_prefix, text_object)
    local doc = get_doc()
    if not doc then return end
    local endl, endc, startl, startc = doc:get_selection()
    local l, c
    -- if return equl pair then just movement
    endl, endc, l, c = resolve_motion(motion, motion_prefix, text_object)
    if not (endl == l and endc == c) then
      startl = l
      startc = c
    end

    if not (endl and endc and startl and startc) then
      return
    end
    doc:set_selection(endl, endc, startl, startc)
  end,


  ["line_select"] = function(_, motion, motion_prefix, text_object)
    local doc = get_doc()
    if not doc then return end
    local endl, endc, startl, startc = doc:get_selection() -- line already selected
    endl, endc = resolve_motion(motion, motion_prefix, text_object)
    if not (endl and endc and startl and startc) then
      return
    end

    local text = doc.lines[endl]
    if startl == endl then
      if vim.dir > 0 then
        startc = #text
        endc = 1
      elseif vim.dir < 0 then
        startc = 1
        endc = #text
      else
        -- pass
      end
    elseif startl > endl then
      text = doc.lines[startl]
      startc = #text
      endc = 1
    elseif startl < endl then
      text = doc.lines[endl]
      startc = 1
      endc = #text
    end
    doc:set_selection(endl, endc, startl, startc)
  end,

  ["d"] = function(_, motion, motion_prefix, text_object)
    if motion or (motion_prefix and text_object) then
      local l1, c1, l2, c2 = resolve_motion(motion, motion_prefix, text_object)
      local doc = get_doc()
      if not doc then return end
      doc:set_selection(l1, c1, l2, c2)
    end
    delete()
    vim.set_mode("normal") -- after y and p return to normal
  end,
  ["y"] = function(_, motion, motion_prefix, text_object)
    if motion or (motion_prefix and text_object) then
      local l1, c1, l2, c2 = resolve_motion(motion, motion_prefix, text_object)
      yank(l1, c1, l2, c2, 0.4)
    else
      yank(nil, nil, nil, nil, 0.4)
    end
    vim.set_mode("normal")
  end,
  -- ["gu"]
  -- ["gU"]
  -- ["<"]
  -- [">"]
  -- ["c"]
}

-- define motions ----------------------------------------------------
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

-- m: translations
local translations = {
  ["previous-char"]        = translate,
  ["next-char"]            = translate,
  ["next-word-start"]      = function(doc, line, col)
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
  ["start-of-word"]        = function(doc, line, col)
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

  ["end-of-word"]          = function(doc, line, col)
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
  ["this-char"]            = function(doc, l, c, ch, dir)
    if not ch then
      ch = doc:get_char(l, c)
    end
    while true do
      local nl, nc = doc:position_offset(l, c, dir)
      if nl == l and nc == c then return end
      l, c = nl, nc
      if (doc.lines[l] or ""):sub(c, c) == ch then return l, c end
    end
  end,
}

get_translation = function(name)
  local obj = translations[name]
  if type(obj) == "function" then
    return obj
  elseif obj then
    return obj[name:gsub("-", "_")]
  end
end

-- m: motions define the region operators act on
vim.motions = {
  ["h"] = function(doc, l, c)
    -- stop line start
    if c == 1 then
      return
    end

    local new_l, new_c = doc:position_offset(l, c, -1)
    vim.max_col = new_c
    vim.dir = 0
    return new_l, new_c, new_l, new_c
  end,

  ["l"] = function(doc, l, c)
    local line_text = doc.lines[l] or ""

    -- stop line end
    if c > #line_text - 2 then
      return
    end

    local new_l, new_c = doc:position_offset(l, c, 1)
    vim.max_col = new_c
    vim.dir = 0
    return new_l, new_c, new_l, new_c
  end,

  ["j"] = function(_, l, _)
    -- down
    vim.dir = -1
    return l + 1, vim.max_col, l + 1, vim.max_col
  end,

  ["k"] = function(_, l, _)
    -- up
    vim.dir = 1
    return l - 1, vim.max_col, l - 1, vim.max_col
  end,

  ["w"] = function(doc, l, c)
    local l2, c2 = l, c
    local next_word_start = get_translation("next-word-start")
    l2, c2 = next_word_start(doc, l, c)
    return l2, c2, l2, c2
  end,
  ["b"] = function(doc, l, c)
    local previous_word_start = get_translation("previous-word-start")
    l, c = previous_word_start(doc, l, c)
    return l, c, l, c
  end,

  ["e"] = function(doc, l, c)
    local next_word_start = get_translation("next-word-start")
    local word_end = get_translation("end-of-word")
    l, c = next_word_start(doc, l, c)
    l, c = word_end(doc, l, c)
    return l, c, l, c
  end,

  ["0"] = function(doc, _, _)
    local line, _ = doc:get_selection()
    return line, 1, line, 1
  end,

  ["^"] = function(doc, _, _)
    local line, _ = doc:get_selection()
    local text = doc.lines[line] or ""
    local first_non_ws = text:find("%S") or 1
    return line, first_non_ws, line, first_non_ws
  end,

  ["$"] = function(doc, _, _)
    local line, _ = doc:get_selection()
    local text = doc.lines[line] or ""
    local last_col = #text + 1
    return line, last_col, line, last_col
  end,

  ["gg"] = function(_, _, _)
    local line
    if get_count() > 1 then
      line = get_count()
    else
      line = 1
    end
    return line, 1, line, 1
  end,

  ["G"] = function(doc, _, _)
    local last_line = #doc.lines
    local last_col = #(doc.lines[last_line] or "") + 1
    return last_line, last_col, last_line, last_col
  end,

  ["d"] = function(doc, l, _)
    return l, 1, l, #doc.lines[l]
  end,

  ["y"] = function(doc, l, _)
    return l, 1, l, #doc.lines[l]
  end,

  ["%"] = function(doc, l, c)
    local l2, c2
    l2, c2 = find_match(doc, l, c)
    return l2, c2, l, c
  end,
}

-- m: normal_keymaps
vim.normal_keys = {
  [":"] = function() end,
  ["/"] = function() end,
  ["?"] = function() end,
  ["*"] = function()
    local doc = get_doc()
    if not doc then return end
    local l, c = doc:get_selection()
    local start_l, start_c = get_translation("start-of-word")(doc, l, c)
    local end_l, end_c = get_translation("end-of-word")(doc, l, c)
    local query = get_text(end_l, end_c, start_l, start_c)
    vim.forward_search(query)
  end,
  ["i"] = function()
    vim.set_mode("insert")
  end,
  ["v"] = function()
    vim.set_mode("visual")
  end,
  ["V"] = function(_, _)
    vim.set_mode("visual-line")
  end,
  ["u"] = function()
    local doc = get_doc()
    if not doc then return end
    doc:undo()
    echo("undo")
  end,
  ["o"] = function()
    local doc = get_doc()
    if not doc then return end
    local l = doc:get_selection()
    doc:set_selection(l + 1, 1)
    vim.set_mode("insert")
    doc:insert(l + 1, 1, "\n")
  end,
  ["O"] = function()
    local doc = get_doc()
    if not doc then return end
    local l = doc:get_selection()
    vim.set_mode("insert")
    doc:insert(l, 1, "\n")
  end,
  ["p"] = function(_)
    put("down")
    vim.set_mode("normal")
  end,
  ["P"] = function(_)
    put("up")
    vim.set_mode("normal")
  end,
  ["n"] = function(_)
    vim.forward_search(vim.search_query)
  end,
  ["N"] = function(_)
    vim.backward_search(vim.search_query)
  end,
  ["s"] = function()
    local doc = get_doc()
    if not doc then return end
    local l, c = doc:get_selection()
    delete(l, c, l, c)
    vim.set_mode("insert")
  end,
  ["S"] = function()
    local doc = get_doc()
    if not doc then return end
    local l, _ = doc:get_seletion()
    delete(l, 1, l, #doc.lines[l] - 1) -- do not delete newline
    vim.set_mode("insert")
  end,
  ["x"] = function()
    local doc = get_doc()
    if not doc then return end
    local l, c = doc:get_selection()
    delete(l, c, l, c)
  end,
  ["X"] = function()
    local doc = get_doc()
    if not doc then return end
    local l, c = doc:get_selection()
    delete(l, c-1, l, c-1)
  end,
}

-- Visula mode keymap
vim.visual_keys = {
  ["V"] = function(_, _)
    vim.set_mode("visual-line")
  end,
  ["p"] = function(_)
    put("down")
    vim.set_mode("normal")
  end,
  ["*"] = function()
    local doc = get_doc()
    if not doc then return end
    local end_l, end_c, start_l, start_c = doc:get_selection()
    local query = get_text(end_l, end_c, start_l, start_c)
    vim.forward_search(query)
  end,

  ["#"] = function()
    local doc = get_doc()
    if not doc then return end
    local l, c, oldl, oldc = doc:get_selection()
    core.log("selection: %s %s %s %s", l, c, oldl, oldc)
    core.log("text: %s", get_text(l, c, oldl, oldc))
    core.log("line length: %s", #doc.lines[l])
    yank(l, c, oldl, oldc)
    local reg = vim.registers['"'] or { text = "", type = "char" }
    local text = reg.text or ""
    core.log("yanked text: %s", text)
    core.log("yanked type: %s", reg.type)
    core.log("yanked text length: %s", #text)
    delete(l, c, oldl, oldc)
  end,
}

-- command to launch the command line
vim.normal_keys[":"] = function()
  vim.set_mode("command")
  instance_command:start_command {
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

-- command to launch the search line
vim.normal_keys["/"] = function()
  vim.set_mode("command")
  forward_search:start_command {
    submit = function(input)
      vim.forward_search(input) -- jump to first occurance
      vim.set_mode("normal")
    end,
    suggest = function(_)
      return "" -- highlights user input, kind of suggests
    end,
    cancel = function()
      vim.set_mode("normal")
    end
  }
end

-- command to launch the search line
vim.normal_keys["?"] = function()
  vim.set_mode("command")
  backward_search:start_command {
    submit = function(input)
      vim.backward_search(input) -- jump to first occurance
      vim.set_mode("normal")
    end,
    suggest = function(_)
      return "" -- highlights user input, kind of suggests
    end,
    cancel = function()
      vim.set_mode("normal")
    end
  }
end

local pairs = { ["("] = ")", ["["] = "]", ["{"] = "}"}
local closing = { [")"] = "(", ["]"] = "[", ["}"] = "{"}

-- m: get region
get_region = function(l1, c1, motion_prefix, text_object)
  local doc = get_doc()
  local l2, c2

  if motion_prefix == "i" or motion_prefix == "a" then
    if text_object == "w" then
      l2, c2 = translations["start-of-word"](doc, l1, c1)
      l1, c1 = translations["end-of-word"](doc, l1, c1)
      if motion_prefix == "i" then
        return l1, c1, l2, c2
      elseif motion_prefix == "a" then
        return l1, c1 + 1, l2, c2 - 1
      end
    elseif text_object == "s" then
      --
    elseif text_object == "p" then
      --
    elseif pairs[text_object] then
      -- TODO: edge case on the bracket
      local l, c = l1, c1
      local this_char = get_translation("this-char")
      l2, c2 = this_char(doc, l1, c1, text_object, -1)
      l1, c1 = find_match(doc, l2, c2)

      -- check inside pairs
      if not (l2 < l or (l2 == l and c2 < c)) or
          not (l1 > l or (l1 == l and c1 > c)) then
        return
      end

      if motion_prefix == "i" then
        return l1, c1 - 1, l2, c2 + 1
      elseif motion_prefix == "a" then
        return l1, c1, l2, c2
      end
    elseif closing[text_object] then
      -- TODO: edge case on the bracket
      local l, c = l1, c1
      local this_char = get_translation("this-char")
      l1, c1 = this_char(doc, l1, c1, text_object, 1)
      l2, c2 = find_match(doc, l1, c1)

      -- check inside pairs
      if not (l2 < l or (l2 == l and c2 < c)) or
          not (l1 > l or (l1 == l and c1 > c)) then
        return
      end

      if motion_prefix == "i" then
        return l1, c1 - 1, l2, c2 + 1
      elseif motion_prefix == "a" then
        return l1, c1, l2, c2
      end
    -- "text" and "text"
    elseif text_object == '"' or text_object == "'" then
      local this_char = get_translation("this-char")
      l1, c1 = this_char(doc, l1, c1, text_object, 1)
      l2, c2 = this_char(doc, l1, c1, text_object, -1)

      if motion_prefix == "i" then
        return l1, c1 - 1, l2, c2 + 1
      elseif motion_prefix == "a" then
        return l1, c1, l2, c2
      end

      return l1, c1, l2, c2
    end
  end
end

-- brackets
-- TODO: this is a translations
find_match = function(doc, line, col)
  local char = doc.lines[line] and doc.lines[line]:sub(col, col)
  if not (pairs[char] or closing[char]) then return end
  local dir         = pairs[char] and 1 or -1 -- forward of backward search
  local match       = dir == 1 and pairs[char] or closing[char]
  local depth       = 0
  -- backward direction closing becomes open
  local open, close = dir == 1 and pairs or closing, dir == 1 and closing or pairs

  for l = line, dir == 1 and #doc.lines or 1, dir do
    local start, stop, step = l == line and col + dir or (dir == 1 and 1 or #doc.lines[l]),
        dir == 1 and #doc.lines[l] or
        1, dir
    for c = start, stop, step do
      local ch = doc.lines[l]:sub(c, c)
      if open[ch] then
        depth = depth + 1
      elseif close[ch] then
        if depth > 0 then
          depth = depth - 1
        elseif ch == match then
          return l, c
        end
      end
    end
  end
end

-- m: vim_docview ----------------------------------------------------
function DocView:draw_line_body(line, x, y)
  -- draw highlight if any selection ends on this line (unchanged)
  local draw_highlight = false
  local hcl = config.highlight_current_line
  if hcl ~= false then
    for _, line1, col1, line2, col2 in self.doc:get_selections(false) do
      if line1 == line then
        if hcl == "no_selection" then
          if (line1 ~= line2) or (col1 ~= col2) then
            draw_highlight = false
            break
          end
        end
        draw_highlight = true
        break
      end
    end
  end
  if draw_highlight and core.active_view == self then
    self:draw_line_highlight(x + self.scroll.x, y)
  end

  -- draw selection if it overlaps this line (end made inclusive)
  local lh = self:get_line_height()
  for _, line1, col1, line2, col2 in self.doc:get_selections(true) do
    if line >= line1 and line <= line2 then
      local text = self.doc.lines[line] or ""
      local s = (line == line1) and col1 or 1
      local e = (line == line2) and col2 or (#text + 1)

      -- expand visual end by +1 for non-empty selections on the final line
      local draw_e = e
      if not (line1 == line2 and col1 == col2) and line == line2 then
        draw_e = math.min(e + 1, #text + 1)
      end

      local x1 = x + self:get_col_x_offset(line, s)
      local x2 = x + self:get_col_x_offset(line, draw_e)
      if x1 ~= x2 then
        local selection_color = style.selection
        -- Only call is_search_selection if the method exists
        if type(self.doc.is_search_selection) == "function" and self.doc:is_search_selection(line1, s, line, e) then
          selection_color = style.search_selection or style.caret
        end
        renderer.draw_rect(x1, y, x2 - x1, lh, selection_color)
      end
    end
  end

  return self:draw_line_text(line, x, y)
end

-- Initialization ---------------
vim.set_mode("normal")

return vim

