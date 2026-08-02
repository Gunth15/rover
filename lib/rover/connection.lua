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
---@param bytes string bytes to transfer
---@param headers table|nil optionale headers
function M.send_bytes(_self, status, bytes, headers)
	local h = headers or {}
	h["Content-Length"] = string.len(bytes)
	return {
		status = status,
		headers = h,
		body = bytes,
	}
end

---@param status number status of request
---@param table table json encodable table
---@param headers table|nil optional headers to add to response
function M.send_json(self, status, table, headers)
	headers["Content-Type"] = "application/json"
	local bytes = rover.json.encode(table)
	self:send_bytes(status, bytes, headers)
end

---@param status number status of request
---@param html string bytes of html
---@param headers table|nil optional headers to add to response
function M.send_html(self, status, html, headers)
	headers["Content-Type"] = "text/html"
	self:send_bytes(status, html, headers)
end

return M
