function rover.routes()
	--TODO:: Fix wildcards
	return {
		{ "/", GET = Hello },
	}
end

function Hello(_)
	return conn:send_bytes("<h1>Welcome</h1>")
end
