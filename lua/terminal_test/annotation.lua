---@class terminalTest
---@field terminalTest.terminals TerminalMultiplexer
---@field terminalTest.tests_info table<string, terminal.testInfo>
---@field terminalTest.test_in_terminal fun(test_info: terminal.testInfo)
---@field terminalTest.test_buf_in_terminals fun(test_command_format: string)
---@field terminalTest.test_nearest_in_terminal fun(test_command_format: string)
---@field terminalTest.test_tracked_in_terminal fun()
---@field terminalTest.view_enclosing_test fun()
---@field terminalTest.view_last_test_teriminal fun()

---@class terminal.testInfo
---@field name string
---@field status string
---@field fail_at_line? number
---@field test_bufnr number
---@field test_line number
---@field test_command string
---@field file string

---@class gotest
---@field tests_info gotest.TestInfo[]
---@field job_id number

---@class gotest.TestInfo
---@field name string
---@field status string "running"|"pass"|"fail"|"paused"|"cont"|"start"
---@field fail_at_line number
---@field file string
