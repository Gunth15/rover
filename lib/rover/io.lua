local M = {}

function M.open(file_path, options)
	return coroutine.yield(0, file_path, options)
end
-- must be IO function, will try to run concurrenty by default
function M.read(file, offset)
	return coroutine.yield(1, file, offset)
end
function M.write(file, string, offset)
	return coroutine.yield(2, file, string, offset)
end
function M.create(file_path, options)
	return coroutine.yield(5, file_path, options)
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

return M
