function rover.load()
	AddTemplate = rover.template.load("<h1>ADDED <%= add() %></h1>")
	NameTemplate = rover.template.load("<h1>Hello <%= @name %></h1>")
end

function add()
	return 1 + 2
end

function rover.routes()
	--TODO:: Fix wildcards
	return {
		{ "/", GET = Hello },
		{ "/add", GET = Add },
		{ "/name/:name", GET = Name },
	}
end

function Hello(conn)
	return conn:send_bytes(200, "<h1>Welcome</h1>", {})
end

function Add(conn)
	return conn:send_bytes(200, AddTemplate({}))
end

function Name(conn)
	return conn:send_bytes(200, NameTemplate({ name = conn.assigns.name }))
end
