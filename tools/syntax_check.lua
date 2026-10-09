-- Parses every Lua file passed on the command line and reports syntax errors.
-- Doesn't run anything, so GMod globals don't matter.
--   luajit tools/syntax_check.lua $(find lua -name "*.lua")
local failed = 0
for _, path in ipairs(arg) do
	local fn, err = loadfile(path)
	if not fn then
		print(err)
		failed = failed + 1
	end
end
print(("%d file(s) checked, %d with errors"):format(#arg, failed))
os.exit(failed == 0 and 0 or 1)
