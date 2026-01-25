local M = {}

function M.accepts(content_type)
	return function(conn)
		if conn.resp_headers["Content-Type"] ~= "text/html" then
			error("Invalid content type(expected " .. content_type .. ")")
		end
		return conn
	end
end

function M.log(conn)
	local before = os.time()
	print("New request:\n", conn, " \n[", os.date(), "]")
	--adds to list of middlewares to run after request
	conn:run_after_send(function()
		print("Total time: ", os.time() - before, "ms")
	end)
	return conn
end

function M.group(plugs)
	return function(conn)
		for _, plug in ipairs(plugs) do
			conn = plug(conn)
		end
		return conn
	end
end
return M
