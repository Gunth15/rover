local M = {}

--TODO: Handle chunck encoding/streamed bodies of request
--and allow seting max header size

---@class streamOptions
---@field length integer
---@field read_length integer
---@field read_timeout integer
---@alias stream fun(opts: streamOptions): string

---@class HttpResponse
---@field status number
---@field headers string[]
---@field body any

--- @alias ConnectionFunction fun(conn: Connection): HttpResponse

---@class Route
---@field GET ConnectionFunction | nil
---@field POST ConnectionFunction | nil
---@field DELETE ConnectionFunction | nil
---@field PUT ConnectionFunction | nil
---@field PATCH ConnectionFunction | nil

---@alias Router Route[]

---multiplexes a route to a given namespace, route
---@param route string
---@return Router
-- TODO: allow opt out
-- TODO: check to see of controller function exist
function M.resources(route, controller, except)
	M.mux(
		route,
		M.get("/", controller.index),
		M.get("/:id/edit", controller.edit),
		M.get("/new", controller.new),
		M.get("/:id", controller.show),
		M.post("/", controller.create),
		M.patch("/:id", controller.update),
		M.put("/:id", controller.update),
		M.delete(":id", controller.delete)
	)
end

return M
