function rover.routes()
	return {
		{ "/", GET = Hello },
		{ "/", POST = Hello },
		{ "/", PUT = Hello },
		{ "/", PATCH = Hello },
		{ "/", DELETE = Hello },
		{ "/girl/:id", DELETE = Hello },
	}
end

function Hello(_)
	return conn:send_bytes("<h1>Welcome</h1>")
end
