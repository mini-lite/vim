-- Author: S.Ghamri

-- Change log-----------------------------------------------------------------

-- TODO: put adds one character
-- TODO: cursor hides after putting
-- TODO: normalize select, delete, put, move. they must use same coordinates, same logic

-- ONGOING: now turn logic into a state machine to turn the emulation realistic
--          handle_input is the state_machine run logic
--          rely of delete_to, select_to and move_to otherwise we define our own

-- TODO: put can handle clipboard
-- TODO: how to test vim, it is starting to be big, minor change is going to effect other areas
-- TODO: enable only overrides only when vim plugin is loaded
-- TODO: delete what is selected, we need a mode o-pending where motion for operation
-- TODO: shift is still selecting in normal disable it
-- TODO: refactor to simplify motions code
-- TODO: collect configs for vim plugin
-- TODO: enhance command line messaging system with FiFo with time 
-- TODO: if we lose focus do not react vim is asleep
-- TODO: normal mode is working outside doc view
-- TODO: start adding important navigations
-- TODO: we need to set space as leader or adapt if user want space as leader
-- TODO: create an option if vim global or only to doc views
-- TODO: let user extend commands
-- TODO: add disable vim config
-- TODO: clean collect active view and remove local definitions 

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
local config = require "core.config" 
local ime = require "core.ime"

-- m: forward definitions
local resolve_motion
local get_region
local select_operator
local line_select_operator
local block_select_operator
local move_operator

-- m: require
local command_line = require "plugins.command-line"
command_line.set_item_name("status:vim")
command_line.add_status_item()
command_line.minimal_status_view = true -- only item will show

-- helper for debug
local function echo(fmt, ...)
  local text = string.format(fmt, ...)
  command_line.show_message({text}, 1)
end


local function get_doc()
  local dv = core.active_view
  if not dv or not dv.doc then
    return nil
  end
  return dv.doc
end

local caret_offset = 0

local function echo_char_under_cursor()
  local doc = get_doc()
  local line, col = doc:get_selection()
  local text = doc.lines[line] or ""
  local char = text:sub(col, col)  -- Lite XL col is 1-based
  if char == "" then
    char = "<EOL>"
  end
  echo("%s", char)
end

local vim = {
  mode = "normal", -- normal, visual, command, insert, delete
  registers = { ['"'] = "" },
  command_buffer = "",
  search_query = "",
  command_map = {},
  operators = {},
  motions = {},
  last_position = {}, -- save cursor position befor executions
  max_col = 0;
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

-- remove selections 
local function deselect()
  local doc = get_doc()
  for idx, line1, col1, _, _ in doc:get_selections(true) do
      doc:set_selections(idx, line1, col1)
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

-- remaps
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
  -- go insert
  if vim.mode == "insert" or vim.mode == "command" then
    return false
  end

  -- if pending gets too long, reset
  if #pending > 3 then
    pending = ""
    reset_state()
    return true
  end

  -- accumulate count digits only if no operator pending
  if not state.operator and (key:match("[1-9]") or (key == "0" and prev_dig )) then
    prev_dig = true
    state.count = (state.count == 1 and "" or tostring(state.count)) .. key
    return true
  end

  -- here numbers already filtered, no number
  pending = pending .. key
  prev_dig = false -- other key then digit is pressed
  
  -- high prio keys
  if vim.mode == "normal" then

    -- default move operator
    state.operator = move_operator

    -- normal key like i and v 
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

  elseif vim.mode == "visual"  or vim.mode == "visual-line" then 
    -- visual key 
    if vim.visual_keys and vim.visual_keys[key] then
        vim.visual_keys[key]()
        pending = ""
        reset_state()
        vim.set_mode("normal")
        return true
    end
  end

  -- 1. operator go o-pending waiting for motion
  -- operator works on region "l1, c1, l2, c2"
  if vim.operators[pending] and vim.mode ~= "o-pending" then
    state.operator = vim.operators[pending]
    if vim.mode == "visual" or vim.mode == "visual-line" then
      state.operator() -- execute operator
      reset_state()
    else -- in normal operators need motion
      vim.set_mode("o-pending")
    end
    pending = ""
    return true
  end

  if vim.mode == "visual" then
     state.operator = select_operator
  end

  if vim.mode == "visual-line" then
     state.operator = line_select_operator
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
  if #pending == 2 and (pending:sub(1,1) == "i" or pending:sub(1,1) == "a") then
    state.motion_prefix = pending:sub(1,1) -- 'i' or 'a'
    state.text_object = pending:sub(2,2)
 
    if state.motion_prefix and state.text_object then
      local count = get_count()
      state.operator(count, nil, state.motion_prefix, state.text_object)
      pending = ""
      reset_state()
      vim.mode = "normal"
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
        pressed[a] = true

        -- some key remaps to input
        if vim.remap_keys[a] and vim.mode ~= "normal" then
            if handle_input(vim.remap_keys[a]) then
                return true
            end
        end

        if a == "escape" then
            vim.set_mode("normal")
            reset_state()
            instance_command:cancel_command()
            deselect()
            pending = ""
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
    local message = ""
    if m == "normal" then
        return_to_line()
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
        local doc = get_doc()
        local l, c = doc:get_selection() -- c starts from 1
        vim.last_position = {l=l, c=c} -- record last position to return to

        -- setup caret 
        style.caret_width = common.round(7 * SCALE)

        -- message
        message = {
            style.text, "-- VISUAL --",
        }

        command_line.show_message(message, 0) -- 0 = permanent
    elseif m == "visual-line" then 
        local doc = get_doc()
        local l, c = doc:get_selection() -- c starts from 1
        vim.last_position = {l=l, c=c, ll=#doc.lines[l]} -- record last position to return to

        -- select line
        -- put selection at the end of line
        doc:set_selection(l, #doc.lines[l], l, 1)
        
        -- setup caret 
        style.caret_width = common.round(7 * SCALE)

        -- message
        message = {
            style.text, "-- VISUAL-LINE --",
        }
        command_line.show_message(message, 0) -- 0 = permanent
     elseif m == "o-pending" then
        -- message
        message = {
            style.text, "-- O-PENDING --",
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

local function get_text(line1, col1, line2, col2)
  -- line and columns here are 0 col based
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
    out[#out+1] = t:sub(s, e)
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
        deselect()
    end)
end

-- m: yank() works with get_selection
local function yank(l1, c1, l2, c2, flash_time)
    local flash_time = flash_time or 0
    local flash_color = style.accent
    local doc = get_doc()
    if not (l1 and c1 and l2 and c2) then
        l1, c1, l2, c2 = doc:get_selection()
    end

    local text = get_text(l1, c1, l2, c2)

    -- TODO: find a better way then using modes here
    local yank_type = "char"
    if vim.mode == "normal" or vim.mode == "visual-line" then
        yank_type = "line"
    elseif vim.mode == "visual" then
        yank_type = "char"
    end

    vim.registers['"'] = { text = text, type = yank_type }

    -- highlight yanked 
    flash(l1, c1, l2, c2, flash_color, flash_time, doc)

    vim.set_mode("normal") -- after y and p return to normal
end

-- m: delete() works with get_selection
local function delete(l1, c1, l2, c2)
  local doc = get_doc() 
  if not doc then return end

  if not (l1 and c1 and l2 and c2) then
    l1, c1, l2, c2 = doc:get_selection()
    if l1 > l2 or (l1 == l2 and c1 > c2) then
      l1, c1, l2, c2 = l2, c2, l1, c1
    end

    local text = doc.lines[l2]
    if c2 == #text then -- we are at \n then next line
        l2 = l2 + 1
        c2 = 1
    else
        c2 = c2 + 1 -- doc:remove uses 1-col
    end
    yank(l1, c1, l2, c2)
  elseif l1 > l2 or (l1 == l2 and c1 > c2) then
    l1, c1, l2, c2 = l2, c2, l1, c1
    c2 = c2 + 1
    yank(l1, c1, l2, c2)
  end
  doc:remove(l1, c1, l2, c2)
  vim.set_mode("normal") -- after y and p return to normal
end

-- m: put()
local function put(direction, count)
    count = count or 1
    local doc = get_doc()
    local l, c = doc:get_selection()
    local reg = vim.registers['"'] or { text = "", type = "char" }
    local yank_type = reg.type or "char"
    local text = reg.text or ""
    local flash_time = 0.1
    local flash_color = style.selection
    if not reg.text then return end

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
            if direction == "down" then
                for i = #lines, 1, -1 do
                    local line_text = lines[i]
                    if not line_text:match("\n$") then
                        line_text = line_text .. "\n"
                    end
                    doc:insert(insert_line, 1, line_text)
                    doc:set_selection(insert_line, 1)
                    flash(insert_line, 1, insert_line, #line_text, flash_color, flash_time, doc)
                end
            else
                for i, line_text in ipairs(lines) do
                    if not line_text:match("\n$") then
                        line_text = line_text .. "\n"
                    end
                    doc:insert(insert_line + i - 1, 1, line_text)
                    doc:set_selection(insert_line + i -1, 1)
                    flash(insert_line + i - 1, 1, insert_line + i - 1, #line_text, flash_color, flash_time, doc)
                end
            end
        else
            -- replicate vim behavior insert after cursor
            doc:insert(l, c+1, text)
            flash(l, c, l, c + 1 + #text, flash_color, flash_time, doc)
            l, c = doc:position_offset(l, c, 1)
            doc:set_selection(l, c)
        end
    end

    vim.set_mode("normal") -- after y and p return to normal
end

-- respect a format for region
--local function normalize_region(l1, c1, l2, c2)
--    if not (l1 and c1 and l2 and c2) then return end
--    if l1 > l2 or (l1 == l2 and c1 > c2) then
--        l1, c1, l2, c2 = l2, c2, l1, c1
--    end
--    return l1, c1, l2, c2 
--end

resolve_motion = function(motion, motion_prefix, text_object)
  local doc = get_doc()
  local l2, c2, l1, c1 = doc:get_selection() 
  
  -- no motion
  if motion_prefix and text_object then
      return get_region(l2, c2, motion_prefix, text_object)
  end

  -- motion
  if motion and type(motion) == "function" then
      -- new l, new c, old l, old c
      -- TODO: motion calls another get_selection()
      return motion(doc, l2, c2)
  end
end


-- m: operators 
-- default visual operator
-- TODO: add them to vim operators
line_select_operator = function(count, motion, motion_prefix, text_object)
    local doc = get_doc()

    local endl, endc, startl, startc = doc:get_selection() -- line already selected
    local endl, endc, _, _ = resolve_motion(motion, motion_prefix, text_object)

    if not (endl and endc and startl and startc ) then
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
        local text = doc.lines[startl]
        startc = #text
        endc = 1
    elseif startl < endl then
        local text = doc.lines[endl]
        startc = 1
        endc = #text
    end

    doc:set_selection(endl, endc, startl, startc)
end

select_operator = function(count, motion, motion_prefix, text_object)
    local doc = get_doc()
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
end

-- default normal operator
move_operator = function(count, motion, motion_prefix, text_object)
           local doc = get_doc()
           local l1, c1, l2, c2 = resolve_motion(motion, motion_prefix, text_object)
           if not (l1 and c1 and l2 and c2) then
               return
           end
           doc:set_selection(l1, c1, l1, c1)
end

-- operator by definition needs a motion (area to work on)
vim.operators = {
    ["d"] = function(count, motion, motion_prefix, text_object)
        if vim.mode == "o-pending" then
           local l1, c1, l2, c2 = resolve_motion(motion, motion_prefix, text_object)
           delete(l1, c1, l2, c2)
        else
           -- we are in visual mode then execute
           delete()
        end
    end,
    ["y"] = function(count, motion, motion_prefix, text_object)
        if vim.mode == "o-pending" then
           local l1, c1, l2, c2 = resolve_motion(motion, motion_prefix, text_object)
           yank(l1, c1, l2, c2)
        else
           -- we are in visual mode then execute
           yank(nil, nil, nil, nil, 0.4) 
        end
    end,
  -- ["gu"]
  -- ["gU"]
  -- ["<"]
  -- [">"]
  -- ["c"]
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

-- m: translations
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
  ["select-down"] = function(doc, line, col)
    -- go to the end
    if line >= #doc.lines then
      return line, col
    end
    local next_line = line + 1
    local text = doc.lines[next_line] or ""
    return next_line, #text
  end,
  ["select-up"] = function(doc, line, col)
    -- go to the start
    if line <= 1 then
        return line, col 
    end
    local prev_line = line - 1
    return prev_line, 1 
  end,
  ["deselect-down"] = function(doc, line, col)
    -- go to the end
    if line >= #doc.lines then
      return line, col
    end
    local next_line = line + 1
    return next_line, 1
  end,
  ["deselect-up"] = function(doc, line, col)
  -- go to the start
  if line <= 1 then
      return line, col 
  end
  local prev_line = line - 1
  local text = doc.lines[prev_line] or ""
  return prev_line, #text 
  end,
  ["next-line"]            = DocView.translate,
  ["previous-line"]        = DocView.translate,
  ["next-page"]            = DocView.translate,
  ["previous-page"]        = DocView.translate,
  ["next-block-end"]       = translate,
  ["previous-block-start"] = translate,
}

-- gets both functions and function from table
local function get_motion_fn(name)
  local obj = translations[name]
  if type(obj) == "function" then
    return obj
  elseif obj then
    return obj[name:gsub("-", "_")]
  end
  return nil
end

-- m: motions
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

  ["j"] = function(doc, l, c)
    -- down
    vim.dir = -1
    return l+1, vim.max_col, l+1 , vim.max_col
    end,

  ["k"] = function(doc, l, c)
    -- up
    vim.dir = 1
    return l-1, vim.max_col, l-1 , vim.max_col
    end,

  ["w"] = function()
        local doc = get_doc()
        local l, c = doc:get_selection()
        local l2, c2 = l, c
        count = count or 1
        local next_word_start = get_motion_fn("next-word-start")
        l2, c2 = next_word_start(doc, l, c)
        return l, c, l2, c2
    end,
  ["b"] = function()
    local doc = get_doc()
    local previous_word_start = get_motion_fn("previous-word-start")
    count = count or 1
    for _ = 1, count do
        doc:move_to(previous_word_start, doc)
    end
  end,

  ["e"] = function()
    local doc = get_doc()
    count = count or 1
    local next_word_start = get_motion_fn("next-word-start")
    for _ = 1, count do
        doc:move_to(next_word_start, doc)
        doc:move_to(translations["end-of-word"], doc)
    end
  end,

  ["0"] = function()
    local doc = get_doc()
    local line, _ = doc:get_selection()
    return line, 1, line, 1
  end,

  ["^"] = function()
    local doc = get_doc()
    local line, _ = doc:get_selection()
    local text = doc.lines[line] or ""
    local first_non_ws = text:find("%S") or 1
    return line, first_non_ws, line, first_non_ws
  end,

  ["$"] = function()
    local doc = get_doc()
    local line, _ = doc:get_selection()
    local text = doc.lines[line] or ""
    local last_col = #text + 1
    return line, last_col, line, last_col
  end,

  ["gg"] = function()
    local doc = get_doc()
    local line = 1
    return line, 1, line, 1
  end,

  ["G"] = function()
    local doc = get_doc()
    local last_line = #doc.lines
    local last_col = #(doc.lines[last_line] or "") + 1
    return last_line, last_col, last_line, last_col
  end,
  ["d"] = function ()
    -- TODO: use translation end of line
    local doc = get_doc()
    local line = doc:get_selection()
    local total_lines = #doc.lines
    if line >= total_lines then
        return line, 1, line, #doc.lines[line]
    else
        return line, 1, line + 1, 1
    end
 end,
}

-- m: normal_keymaps
vim.normal_keys = {
  [":"] = function() end,
  ["/"] = function() end,
  ["?"] = function() end,
  ["*"] = vim.search_word_under_cursor,
  ["#"] = echo_char_under_cursor,
  ["i"] = function()
    vim.set_mode("insert")
  end,
  ["v"] = function()
    vim.set_mode("visual")
  end,
  ["V"] = function(count, motion)
      vim.set_mode("visual-line")
  end,
  ["u"] = function()
    local doc = get_doc()
    doc:undo()
    echo("undo")
  end,
  ["o"] = function()
      local doc = get_doc()
      local l = doc:get_selection()
      doc:set_selection(l+1, 1)
      vim.set_mode("insert")
      doc:insert(l+1, 1, "\n")
  end,
  ["O"] = function()
      local doc = get_doc()
      local l = doc:get_selection()
      vim.set_mode("insert")
      doc:insert(l, 1, "\n")
  end,
  ["p"] = function(count)
      -- TODO: use count for loop
      put("down")
  end,
  ["P"] = function(count)
      -- TODO: use count for loop
      put("up")
  end,
}

-- Visula mode keymap
vim.visual_keys = {
  ["V"] = function(count, motion)
      vim.set_mode("visual-line")
  end,
  ["p"] = function(count)
      -- TODO: use count for loop
      put("down")
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

-- m: get region
get_region = function(l1, c1, motion_prefix, text_object)
  local doc = get_doc()
  local l2, c2
  if text_object == "w" then
    local l2, c2 = translations["start-of-word"](doc, l1, c1)
    local l1, c1 = translations["end-of-word"](doc, l1, c1)
    if motion_prefix == "i" then
      return l1, c1, l2, c2
    elseif motion_prefix == "a" then
      return l1, c1 + 1, l2, c2 - 1 
    end

  elseif text_object == "s" then
  elseif text_object == "p" then
  -- TODO: else between quotes and parenthesis
  end
end


-- m: vim_docview ----------------------------------------------------
function DocView:draw_line_body(line, x, y)
  -- draw highlight if any selection ends on this line (unchanged)
  local draw_highlight = false
  local hcl = config.highlight_current_line
  if hcl ~= false then
    for lidx, line1, col1, line2, col2 in self.doc:get_selections(false) do
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
  for lidx, line1, col1, line2, col2 in self.doc:get_selections(true) do
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
