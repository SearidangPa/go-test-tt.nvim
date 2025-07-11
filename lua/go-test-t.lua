---@class GoTestT
local go_test = {}
go_test.__index = go_test

---@param opts GoTestT.Options
function go_test.new(opts)
  opts = opts or {}
  local self = setmetatable({}, go_test)
  self.go_test_prefix = opts.go_test_prefix or 'go test'

  self.job_id = -1
  self.tests_info = {}
  self.go_test_ns_id = vim.api.nvim_create_namespace 'GoTestT'

  self.pin_tester = require('terminal_test.pin_test').new {
    update_display_buffer_func = function(tests_info) self.displayer:update_display_buffer(tests_info) end,
    toggle_display_func = function(do_not_close) self.displayer:toggle_display(do_not_close) end,
    retest_in_terminal_by_name = function(test_name) self.term_tester:retest_in_terminal_by_name(test_name) end,
    test_nearest_in_terminal_func = function() return self.term_tester:test_nearest_in_terminal() end,
    add_test_info_func = function(test_info) self.tests_info[test_info.name] = test_info end,
  }

  self.displayer = require('util_go_test_display').new {
    display_title = 'Go Test Results',
    rerun_in_term_func = function(test_name) self.term_tester:retest_in_terminal_by_name(test_name) end,
    get_tests_info_func = function() return self.tests_info end,
    get_pinned_tests_func = function() return self.pin_tester.pinned_list end,
    preview_terminal_func = function(test_name) return self.term_tester:preview_terminal(test_name) end,
  }

  self.term_tester = require('terminal_test.terminal_test').new {
    go_test_prefix = self.go_test_prefix,
    tests_info = self.tests_info,
    pin_test_func = function(test_info) self.pin_tester:pin_test(test_info) end,
    get_pinned_tests_func = function() return self.pin_tester.pinned_list end,
    get_test_info_func = function(test_name) return self.tests_info[test_name] end,
    add_test_info_func = function(test_info) self.tests_info[test_info.name] = test_info end,
    ns_id = vim.api.nvim_create_namespace 'Terminal Test',
    toggle_display_func = function(do_not_close) self.displayer:toggle_display(do_not_close) end,
    update_display_buffer_func = function(tests_info) self.displayer:update_display_buffer(tests_info) end,
  }
  local user_command_prefix = opts.user_command_prefix or ''
  self:setup_user_command(user_command_prefix)
  return self
end

---@param opts GoTestT.Options
function go_test:set_go_test_prefix(opts)
  assert(type(opts) == 'table', 'Options must be a table')
  assert(opts.go_test_prefix, 'go_test_prefix must be provided in options')
  local new_prefix = opts.go_test_prefix
  local self_ref = self
  self_ref.go_test_prefix = new_prefix
  self_ref.term_tester.go_test_prefix = new_prefix
end

function go_test:setup_user_command(user_command_prefix)
  require 'terminal-multiplexer'
  local self_ref = self
  local term_tester = self_ref.term_tester
  vim.api.nvim_create_user_command(user_command_prefix .. 'TestT', function() self_ref.displayer:toggle_display() end, {})
  vim.api.nvim_create_user_command(user_command_prefix .. 'TestAll', function() self_ref:test_all(false) end, {})
  vim.api.nvim_create_user_command(user_command_prefix .. 'TestPkg', function() self_ref:test_all(true) end, {})
  vim.api.nvim_create_user_command(user_command_prefix .. 'TestBuf', function() term_tester:test_buf_in_terminals() end, {})

  vim.api.nvim_create_user_command(user_command_prefix .. 'TestTerm', function()
    local util_find_test = require 'util_find_test_func'
    local test_name, _ = util_find_test.get_enclosing_test()
    if not test_name then
      local last_test = self_ref.term_tester.terminal_multiplexer.last_terminal_name
      if last_test then
        local test_info = self_ref.term_tester.get_test_info_func(last_test)
        self.term_tester:test_in_terminal(test_info, true)
      end
    else
      self_ref.term_tester:test_nearest_in_terminal()
    end
  end, {})

  vim.api.nvim_create_user_command(user_command_prefix .. 'TestView', function() term_tester:test_nearest_with_view_term() end, {})
  vim.api.nvim_create_user_command(user_command_prefix .. 'TestReset', function() self_ref:reset_all() end, {})
end

function go_test:reset_keep_pin()
  local self_ref = self
  self_ref.job_id = -1
  self_ref.tests_info = {}
  self_ref.term_tester:reset()
  self_ref.displayer:reset()
end

function go_test:reset_all()
  local self_ref = self
  self_ref:reset_keep_pin()
  self_ref.pin_tester.pinned_list = {}
end

function go_test:test_all(test_in_pkg_only)
  local self_ref = self
  test_in_pkg_only = test_in_pkg_only or false
  local test_command
  local intermediate_path
  if test_in_pkg_only then
    local util_path = require 'util_go_test_path'
    intermediate_path = util_path.get_intermediate_path()
    test_command = string.format('%s %s -v --json', self_ref.go_test_prefix, intermediate_path)
  else
    test_command = string.format('%s ./... -v --json', self_ref.go_test_prefix)
  end

  self_ref:reset_keep_pin()
  self_ref.displayer:create_window_and_buf()

  self_ref:_clean_up_prev_job()
  self_ref.job_id = vim.fn.jobstart(test_command, {
    stdout_buffered = false,

    on_stdout = function(_, data)
      assert(data, 'No data received from job')
      for _, line in ipairs(data) do
        if line == '' then
          goto continue
        end

        local ok, decoded = pcall(vim.json.decode, line)
        if not ok or not decoded then
          goto continue
        end

        if self_ref._ignored_actions[decoded.Action] then
          goto continue
        end

        if decoded.Action == 'run' then
          self_ref:_add_golang_test(decoded, test_in_pkg_only, intermediate_path)
          self_ref.displayer:update_display_buffer()
          goto continue
        end

        if decoded.Action == 'output' then
          if decoded.Test or decoded.Package then
            self_ref:_filter_golang_output(decoded)
          end
          goto continue
        end

        if self_ref._action_state[decoded.Action] then
          self_ref:_mark_outcome(decoded)
          self_ref.displayer:update_display_buffer()
          goto continue
        end

        ::continue::
      end
    end,

    on_exit = function() end,
  })
end

--- === Private functions ===

function go_test:_clean_up_prev_job()
  local self_ref = self
  if self_ref.job_id ~= -1 then
    vim.notify('Stopping job', vim.log.levels.INFO)
    vim.fn.jobstop(self_ref.job_id)
    vim.diagnostic.reset()
  end
end

---@param entry table
---@param test_in_pkg_only boolean
---@param intermediate_path string
function go_test:_add_golang_test(entry, test_in_pkg_only, intermediate_path)
  local self_ref = self
  if not entry.Test then
    return
  end

  local test_command
  if test_in_pkg_only then
    test_command = string.format('%s %s -v', self_ref.go_test_prefix, intermediate_path)
  else
    test_command = string.format('%s ./... -v', self_ref.go_test_prefix)
  end

  ---@type terminal.testInfo
  local test_info = {
    name = entry.Test,
    status = 'running',
    filepath = '',
    test_command = test_command,
    set_ext_mark = false,
    output = {},
  }

  self_ref.tests_info[entry.Test] = test_info
  vim.schedule(function() self_ref.displayer:update_display_buffer() end)
end

function go_test:_filter_golang_output(entry)
  local self_ref = self
  assert(entry, 'No entry provided')
  if not entry.Test then
    return
  end
  local test_info = self_ref.tests_info[entry.Test]
  if not test_info then
    vim.notify('Filter Output: Test info not found for ' .. entry.Test, vim.log.levels.WARN)
    return
  end

  local trimmed_output = vim.trim(entry.Output)
  table.insert(test_info.output, trimmed_output)

  local file, line_num_any = string.match(trimmed_output, 'Error Trace:%s+([^:]+):(%d+)')
  if file and line_num_any then
    local line_num = tonumber(line_num_any)
    assert(line_num, 'Line number must be a number')
    test_info.fail_at_line = line_num
    test_info.filepath = file
  end

  if trimmed_output:match '^--- FAIL:' then
    test_info.status = 'fail'
    self_ref.pin_tester:pin_test(test_info)
    require('util_go_test_quickfix').add_fail_test(test_info)
  end
  self_ref.tests_info[entry.Test] = test_info
  self_ref.displayer:update_display_buffer()
end

function go_test:_mark_outcome(entry)
  local self_ref = self
  if not entry.Test then
    return
  end
  local key = entry.Test
  local test_info = self_ref.tests_info[key]
  if not test_info then
    return
  end

  test_info.status = entry.Action
  self_ref.tests_info[key] = test_info
  if entry.Action == 'fail' then
    require('util_go_test_quickfix').add_fail_test(test_info)
    self_ref.pin_tester:pin_test(test_info)
    vim.schedule(function() self_ref.displayer:update_display_buffer() end)
  end
end

go_test._ignored_actions = {
  skip = true,
}

go_test._action_state = {
  pause = true,
  cont = true,
  start = true,
  fail = true,
  pass = true,
}

return go_test
