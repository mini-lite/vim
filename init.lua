-- Module: vim
-- Author: S.Ghamri

-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local translate = require "core.doc.translate"
local DocView = require "core.docview"
local config = require "core.config"
local search = require "core.doc.search"
local keymap = require "core.keymap"

config.vim = {
 unified_search = true,
 unnamedplus = true,
 flash_color = style.caret
}

-- m: forward definitions
local get_translation
local resolve_motion
local get_region
local find_match

local vim = {
 mode = "normal", -- normal, visual, command, insert, delete
 command_buffer  = "",
 search_query    = "",
 command_map     = {},
 operators       = {},
 motions         = {},
 max_col         = 0,
 normal_keys     = {},
 visual_keys     = {},
 remap_keys      = {},
 known_keymaps   = {},
 dir             = 0,
}

vim.registers = {
 ['"'] = "", -- unnamed register
 ['0'] = "", -- yank register
 ['1'] = "", -- last delete
 ['+'] = "", -- system clipboard
 ['*'] = ""  -- primary selection (linux)
 -- "% : abs_filename
 -- "/ : last search query (vim.search_query)
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

-- m: helpers
local function get_doc() -- gets active document view
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

local function set_vim_caret() -- reduce caret width when in insert mode
 if vim.mode == "insert" then
  style.caret_width = common.round(1.5 * SCALE)
 else
  style.caret_width = common.round(8 * SCALE)
 end
end

local function deselect()
 local doc = get_doc()
 if not doc then return end
 for idx, _, _, line2, col2 in doc:get_selections(true) do
  doc:set_selections(idx, line2, col2)
 end
end

local function get_count()
 return tonumber(state.count) or 1
end

local function reset_state()
 state.count = 1
 state.operator = nil
 state.motion = nil
 state.motions_prefix = nil
 state.register = nil
 state.text_object = nil
 vim.command_buffer = "" -- debug
end

-- m: command line vim integration
local command_line = require "plugins.command-line"

command_line.set_item_name("status:vim")
command_line.add_status_item()
command_line.minimal_status_view = true -- only item will show

local function decorate_with_vim(instance)
 local orig_start = instance.start_command
 function instance:start_command(opts)
  local result = orig_start(self, opts)
  vim.set_mode("command")
  return result
 end

 local orig_exec = instance.execute_or_return_command
 function instance:execute_or_return_command()
  local result = orig_exec(self)       -- if closed in_command here is false
  if not command_line.is_active() then -- no command line prompt is open
   vim.set_mode("normal")
  end
  return result
 end

 local orig_cancel = instance.cancel_command
 function instance:cancel_command()
  local result = orig_cancel(self)
  vim.set_mode("normal")
  return result
 end

 return instance
end

local instance_command = decorate_with_vim(command_line.new())
instance_command:set_prompt(":")

local forward_search = decorate_with_vim(command_line.new())
forward_search:set_prompt("/")

local backward_search = decorate_with_vim(command_line.new())
backward_search:set_prompt("?")

local function echo(fmt, ...)
 local text = string.format(fmt, ...)
 command_line.show_message({ text }, 1)
end

-- keys that can input
local input_keys = {
 ["return"] = true,
 ["backspace"] = true,
 ["tab"] = true,
 ["delete"] = true,
 ["insert"] = true,
 ["space"] = true
}

vim.mod_keys = {
 ctrl  = false,
 alt   = false,
 shift = false
}

vim.modifier_keys = {
 ["left ctrl"]   = false,
 ["right ctrl"]  = false,
 ["left shift"]  = false,
 ["right shift"] = false,
 ["left alt"]    = false,
 ["right alt"]   = false,
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

local function update_mod_keys()
 vim.mod_keys.ctrl  = (vim.modifier_keys["left ctrl"] or vim.modifier_keys["right ctrl"]) or false
 vim.mod_keys.shift = (vim.modifier_keys["left shift"] or vim.modifier_keys["right shift"]) or false
 vim.mod_keys.alt   = (vim.modifier_keys["left alt"] or vim.modifier_keys["right alt"]) or false
end

local function build_combo(key) -- detects a combo
 local mods = {}
 if vim.mod_keys.ctrl then table.insert(mods, "ctrl") end
 if vim.mod_keys.alt then table.insert(mods, "alt") end
 if vim.mod_keys.shift then table.insert(mods, "shift") end
 table.insert(mods, key:lower())
 return table.concat(mods, "+")
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
   if vim.modifier_keys[a] == nil and (vim.mod_keys.ctrl or vim.mod_keys.alt or vim.mod_keys.shift) then
    local cmb = build_combo(a)
    if vim.known_keymaps[cmb] == nil then
     -- nothing, let key reach original on_event
    else
     if handle_input(cmb) then 
      return true
     end
    end
   end

   if vim.modifier_keys[a] ~= nil then
    vim.modifier_keys[a] = true
    update_mod_keys()
   end

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
    if input_keys[a] then
     return true -- block in normal mode
    end
   end
  elseif type == "keyreleased" then
   if vim.modifier_keys[a] ~= nil then
    vim.modifier_keys[a] = false
    update_mod_keys()
   end
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
 set_vim_caret()
 if m == "normal" then
  return_to_line()
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
  local l, c = doc:get_selection() -- c starts from 1
  message = {
   style.text, "-- VISUAL --",
  }
  command_line.show_message(message, 0) -- 0 = permanent
 elseif m == "visual-line" then
  local doc = get_doc()
  if not doc then return end
  local l, c = doc:get_selection() -- c starts from 1
  doc:set_selection(l, #doc.lines[l], l, 1)
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

-- m: keymaps registration
-- TODO: not tested, test it
function vim.register_keymap(mode, combo, fn)
  local function clean(s)
    return s:lower():match("^%s*(.-)%s*$")
  end

  local parts = {}
  for part in combo:gmatch("[^%+]+") do
    table.insert(parts, clean(part))
  end

  local key
  if #parts > 1 then
    key = table.concat(parts, "+")  -- "ctrl+x"
  else
    key = parts[1]                  -- "x"
  end

  vim.known_keymaps[key] = true

  if mode == "normal" then
    vim.normal_keys[key] = fn
  elseif mode == "visual" then
    vim.visual_keys[key] = fn
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
  deselect() -- selection is lost here
 end)
end


local function get_yank_type(doc, text, l1, c1, l2, c2)
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
 local doc = get_doc()
 if not doc then return end
 if not (l1 and c1 and l2 and c2) then
  l1, c1, l2, c2 = doc:get_selection()
 end
 local yank_type = "char"
 local text = get_text(l1, c1, l2, c2)
 if not text then return end
 yank_type = get_yank_type(doc, text, l1, c1, l2, c2)

 -- update registers
 if config.vim.unnamedplus then
  system.set_clipboard(text)
  vim.registers['+'] = { text = text, type = yank_type } -- clipboard does not have metadata
 end
 vim.registers['"'] = { text = text, type = yank_type }

 -- only when yank
 vim.registers['0'] = { text = text, type = yank_type }

 if ft ~= 0 then
  flash(l1, c1, l2, c2, config.vim.flash_color, ft, doc)
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
 local yank_type = get_yank_type(doc, reg_text, sl, sc, el, ec)
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

-- insert lines
local function get_insert_line(doc, direction, l, c)
 if not doc then return end
 local insert_line = 0

 if direction == "down" then
  if l == #doc.lines and doc.lines[l] == "" then
   insert_line = l
  else
   insert_line = l + 1
  end
 elseif direction == "up" then
  insert_line = l
 end

 return insert_line
end

-- m: put()
local function put(direction, count)
 local doc = get_doc()
 if not doc then return end
 local flash_time = 0.2
 count = count or 1

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
   local line_textt = ""

   local insert_line = get_insert_line(doc, direction, l, c)

   if insert_line > #doc.lines then -- add empty line
    local t = doc.lines[#doc.lines] or ""
    doc:insert(#doc.lines, #t, "\n")
    doc:set_selection(#doc.lines, 1)
   end

   if direction == "down" then -- downward
    for i = #lines, 1, -1 do
     line_textt = lines[i]
     if not line_textt:match("\n$") then
      line_textt = line_textt .. "\n"
     end
     doc:insert(insert_line, 1, line_textt)
     doc:set_selection(insert_line, 1)
    end
    flash(insert_line, 1, insert_line + #lines - 1, #lines[#lines], config.vim.flash_color, flash_time, doc)
   else -- upward
    for i, line_text in ipairs(lines) do
     if not line_text:match("\n$") then
      line_textt = line_text .. "\n"
     end
     doc:insert(insert_line + i - 1, 1, line_textt)
     doc:set_selection(insert_line + i - 1, 1)
    end
    flash(insert_line, 1, insert_line + #lines - 1, #line_textt, config.vim.flash_color, flash_time, doc)
   end
  else                        -- char
   doc:insert(l, c + 1, text) -- +1 after cursor
   local nl, nc = doc:position_offset(l, c, #text)
   doc:set_selection(nl, nc)
   flash(l, c + 1, nl, nc, config.vim.flash_color, flash_time, doc)
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
   if not text then return end
   startc = #text
   endc = 1
  elseif startl < endl then
   text = doc.lines[endl]
   if not text then return end
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
 ["this-char"]            = function(doc, l, c, ch, dir) -- find character and translate to it
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
 ["ctrl+r"] = function()
   local doc = get_doc()
   if not doc then return end
   doc:redo()
   echo("redo")
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
  delete(l, c - 1, l, c - 1)
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

-- update known keymaps
for k in pairs(vim.normal_keys) do vim.known_keymaps[k] = true end
for k in pairs(vim.visual_keys) do vim.known_keymaps[k] = true end


-- command to launch the command line
vim.normal_keys[":"] = function()
 instance_command:start_command {
  submit = function(input)
   vim.run_command(input) -- non blocking
  end,
  suggest = function(input)
   return vim.get_suggests(input)
  end,
  cancel = function()
  end
 }
end

-- command to launch the search line
vim.normal_keys["/"] = function()
 forward_search:start_command {
  submit = function(input)
   vim.forward_search(input) -- jump to first occurance
  end,
  suggest = function(_)
   return "" -- highlights user input, kind of suggests
  end,
  cancel = function()
  end
 }
end

-- command to launch the search line
vim.normal_keys["?"] = function()
 backward_search:start_command {
  submit = function(input)
   vim.backward_search(input) -- jump to first occurance
  end,
  suggest = function(_)
   return "" -- highlights user input, kind of suggests
  end,
  cancel = function()
  end
 }
end

-- m: pairs
local pairs = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local closing = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

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
  elseif pairs[text_object] then -- inner pair
   local l, c = l1, c1
   local this_char = get_translation("this-char")
   l2, c2 = this_char(doc, l1, c1, text_object, -1) -- dir -1 means up
   l1, c1 = find_match(doc, l2, c2)

   -- check inside pairs
   if not (l2 < l or (l2 == l and c2 < c)) or
       not (l1 > l or (l1 == l and c1 > c)) then
    return
   end

   if motion_prefix == "i" then
    if (c1 - 1) == 0 then
     l1 = l1 - 1
     c1 = #doc.lines[l1]
    else
     c1 = c1 - 1
    end
    return l1, c1, l2, c2 + 1
   elseif motion_prefix == "a" then
    return l1, c1, l2, c2
   end
  elseif closing[text_object] then -- inner pair
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

-- TODO: we defined two echo fix it
vim.echo = function(fmt, ...)
 local text = string.format(fmt, ...)
 command_line.show_message({ text }, 1)
end

-- confirm prompt
vim.confirm = function(message, cb)
 local prompt = decorate_with_vim(command_line.new())
 prompt:set_prompt(message .. " (y/yes to confirm): ")
 prompt:start_command {
  submit = function(input)
   local answer = input and input:lower()
   if answer == "y" or answer == "yes" then
    cb(true)
   else
    cb(false)
   end
  end,
  cancel = function()
  end
 }
end

return vim

