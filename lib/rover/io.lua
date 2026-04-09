local M = {}

function M.read(handle, buffsize, offset)
	local size = buffsize or 4096
	return coroutine.yield(sys_read(handle, size, offset))
end
function M.write(handle, string, offset)
	return coroutine.yield(sys_write(handle, string, offset))
end
function M.openat(handle, path, options)
	return coroutine.yield(sys_openat(handle, string, offset))
end
function M.close(handle)
	return coroutine.yield(sys_close(handle))
end

return M
