--TODO: add HTMX, DaisyUI, Tailwind
--TODO: maybe websocket stuff
--TODO: make migration system and type validator
--TODO: make hyperperformant networking system in zig
--TODO:
--TODO: JSON, HTML, etc parsing
--TODO: stream evreything exceptr http body
--TODO: add logger
local plugins = rover.plugins
local controllers = require("controllers")
local rover = require("rover/rover")
function rover.load()
	print("moon rover started at", tostring(os.time()))
	--TODO: maybe make global state update all vm's somehow(shared dict)
	return { db = db }
end
function rover.plugs()
	--TODO: add content type blockers
	return {
		{ plugins.accepts("text/html"), { "/hello", "/world", "/:name" } },
		{ plugins.accepts("application/json"), "/api/*" },
		{ plugins.log, "*" },
	}
end
function rover.routes(plug)
	--TODO: support other wildcards
	--NOTE: https://hexdocs.pm/phoenix/routing.html(moc this)
	--NOTE: rover.router.(get,post,put,path,,delete)
	--NOTE: special router.resources to create a route that has everything you really need for most MVC apps.
	return {
		--Most specific first
		{ "/hello", GET = controllers.hello },
		{ "/world", GET = controllers.world },
		{ "/:name", GET = controllers.name },
		{ "/api", {
			{ "/hello", GET = controllers.json },
			{ "/nil", GET = controllers.nothing },
		} },
	}
end

function rover.onerror(conn, err)
	print("bruh")
end
