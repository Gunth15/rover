do
local _ENV = _ENV
package.preload[ "connection" ] = function( ... ) local arg = _G.arg;
---@class Connection
---@field host string
---@field method "GET" | "PUT" | "POST" | "PATCH" | "DELETE"
---@field req_headers table
---@field path_info string[]
---@field request_path string
---@field remote_ip number[]
---@field query_string string
---@field query_parmas string
---@field assigns table path parmas
---@field shared table  values from the rover.load function
---@field port number
local M = {}
M.__index = M

---@class Response
---@field status number
---@field headers table
---@field body string

---@param status number status of request
---@param headers table|nil optionale headers
---@param bytes string bytes to transfer
function M.send_bytes(_self, status, headers, bytes)
	local h = headers or {}
	h["Content-Length"] = string.len(bytes)
	return {
		status = status,
		headers = h,
		body = bytes,
	}
end

return M
end
end

do
local _ENV = _ENV
package.preload[ "rover" ] = function( ... ) local arg = _G.arg;
rover.connection = require("connection")
-- rover.plugins = require("plugins")
-- rover.router = require("router")
-- rover.io = require("io")
end
end

