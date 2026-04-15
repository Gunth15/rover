print("Loaded file")
function rover.routes()
	return {
		{ "/", GET = Hello },
	}
end

function Hello(_)
	return "<h1>Welcome</h1>"
	-- conn:send_bytes("<h1>Welcome</h1>")
end
