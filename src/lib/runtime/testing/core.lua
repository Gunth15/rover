local Core = {}
Core.__index = Core

function Core.new()
	return setmetatable({ tests = {} }, Core)
end

function Core:run(fn, name)
	if not name then
		local info = debug.getinfo(fn, "n")
		name = (info and info.name) or ("test_" .. (#self.tests + 1))
	end
	table.insert(self.tests, { func = fn, name = name })
end

return Core.new()
