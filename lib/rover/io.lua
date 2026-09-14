local M = {}

local File = {}
File.__index = File
File.__gc = function(file)
	file:flush()
	file.close()
end

function M.open(file_path, options)
	local file = coroutine.yield(0, file_path, options)
	return setmetatable(file, File)
end
-- must be IO function, will try to run concurrenty by default
function M.read(file, offset)
	return coroutine.yield(1, file, offset)
end
function M.write(file, string, offset)
	return coroutine.yield(2, file, string, offset)
end
function M.create(file_path, options)
	local file = coroutine.yield(0, file_path, options)
	return setmetatable(file, File)
end
function M.close(file)
	return coroutine.yield(3, file)
end
function M.seek(file, whence)
	return coroutine.yield(7, file, whence)
end
function M.flush(file)
	return coroutine.yield(6, file)
end

function File:read(offset)
	M.read(self, offset)
end
function File:write(string, offset)
	M.write(self, string, offset)
end
function File:seek(whence)
	M.seek(self, whence)
end
function File:flush()
	M.flush(self)
end
function File:close()
	M.close(self)
end

return M
