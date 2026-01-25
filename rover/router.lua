local M = {}

---@class Connection
---@field host string
---@field method "GET" | "PUT" | "POST" | "PATCH" | "DELETE"
---@field req_headers string[]
---@field path_info string[]
---@field request_path string
---@field scheme string
---@field remote_ip number[]
---@field query_string string
---@field query_parmas string
---@field body string
---@field parsed_body any null unless populated by a plug
---@field assigns table passed from plugs
---@field config table immutable passed form the rover.load function
---@field shared_dict userdata passed to all instances of your application
---@field port number

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
---@param ... Route[]
---@return Router
function M.mux(route, ...)
	--TODO: handle case where two routes have the samespace
	return {
		[route] = ...,
	}
end
---@param route string
---@param func ConnectionFunction
---@return Route
function M.get(route, func)
	return {
		[route] = {
			["GET"] = func,
		},
	}
end
---@param route string
---@param func ConnectionFunction
---@return Route
function M.post(route, func)
	return {
		[route] = {
			["POST"] = func,
		},
	}
end
---@param route string
---@param func ConnectionFunction
---@return Route
function M.delete(route, func)
	return {
		[route] = {
			["DELETE"] = func,
		},
	}
end
---@param route string
---@param func ConnectionFunction
---@return Route
function M.put(route, func)
	return {
		[route] = {
			["PUT"] = func,
		},
	}
end
---@param route string
---@param func ConnectionFunction
---@return Route
function M.patch(route, func)
	return {
		[route] = {
			["PATCH"] = func,
		},
	}
end
---@param route string
---@param controller Controller
---@param except string[]
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
