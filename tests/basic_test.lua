function rover.test(core)
	core:run(function()
		assert(1 + 1 == 2)
	end, "test add")
	return core
end
