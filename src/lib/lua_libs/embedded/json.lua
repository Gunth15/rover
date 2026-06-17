function M.array(table)
	return {
		__json_type = "array",
		data = table,
	}
end
function M.object(table)
	return {
		__json_type = "object",
		data = table,
	}
end
