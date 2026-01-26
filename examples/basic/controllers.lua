local Hello = {}
function Hello.get(conn)
	return conn:send_html("<h1>Hello World</h1>")
end

local World = {}
function World.get(conn)
	--TODO: do some htmx to change hello to world
end

local Name = {}
function Name.get(conn)
	--TODO: make function that loads html file(like io.read, but in zig)
	return conn:send_html(200, "<h1> Hello" .. conn.params.name .. " !</h1>")
end

local Hellojson = {}
function Hellojson.get(conn)
	return conn:send_json(200, "hello")
end

local Nothing = {}
function Nothing.get(conn)
	return conn:send_json(400, nil)
end

return {
	hello = Hello,
	name = Name,
	world = World,
	json = Hellojson,
	nothing = Nothing,
}
