function rover.routes()
	--TODO:: Fix wildcards
	return {
		{ "/", GET = Hello, POST = Hello },
	}
end

function Hello(conn)
	return conn:send_bytes(200, "<h1>Welcome</h1>", {})
end
