function rover.routes()
	--TODO:: Fix wildcards
	return {
		{ "/", GET = Hello, POST = Hello },
		{ "/me/:id", GET = Hello },
		{ "/is/f/:bob/:youruncle", GET = Hello, POST = Hello },
		{ "/wild/*wildcard", GET = Hello },
	}
end

function Hello(conn)
	return conn:send_bytes(200, nil, "<h1>Welcome</h1>")
end
