local M = {}
M.__index = M

function M.new()
	local m = {}
	setmetatable(m, M)
	return m
end
function M:string(name)
	self.types[name] = "string"
end
function M:number(name)
	self.types[name] = "number"
end
function M:boolean(name)
	self.types[name] = "boolean"
end
function M:table(name)
	self.types[name] = "table"
end
function M:validate(data)
	for key, tval in ipairs(self.types) do
		local data_type = type(data[key])
		if tval ~= data_type then
			error("Unexpected type " .. data_type .. "for key " .. key .. ". Expected the type " .. tval .. ".")
		end
	end
end
return M
