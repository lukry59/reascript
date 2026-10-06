-- Usage: sh tests/run.sh [filter]
package.path = "./Drums/?.lua;./tests/?.lua;" .. package.path

local files = {}
local p = io.popen("ls tests/*_test.lua")
for line in p:lines() do files[#files + 1] = line:match("tests/(.+)%.lua$") end
p:close()

local filter = arg[1]
local passed, failed = 0, 0
for _, name in ipairs(files) do
  local ok_load, cases = pcall(require, name)
  if not ok_load then
    print("LOAD FAIL " .. name .. ": " .. tostring(cases))
    failed = failed + 1
  else
    local names = {}
    for k in pairs(cases) do names[#names + 1] = k end
    table.sort(names)
    for _, case in ipairs(names) do
      local full = name .. " :: " .. case
      if not filter or full:find(filter, 1, true) then
        local ok, err = xpcall(cases[case], debug.traceback)
        if ok then
          passed = passed + 1
          print("ok   " .. full)
        else
          failed = failed + 1
          print("FAIL " .. full .. "\n" .. err)
        end
      end
    end
  end
end
print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
