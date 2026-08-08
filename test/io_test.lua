--rover test command (searches in test directory for files with *_test naming convention or you can specify the file to look for using the f flag)
function rover.test(core)
	-- Isolate test to separate lua runtimes
	core.run(file_create)
	core.run(file_read)
	core.run(tmp)
end

function file_create()
	local file = rover.io.create("hello.text", {
		read = false,
		write_buffer = 64,
	})

	file:write([[hello
  10rest of line
  rest of file]])

	--TODO: Should close file when an attempt to GC is made
	file:close()
end
function file_read()
	local file = rover.io.open("hello.text", {
		read_buffer = 64,
	})

	local data = file:read(6)
	local n = file:read("*n")
	local line = file:read("*l")
	local rest = file:read("*a")
	assert(data == "hello ")
	assert(n == 10)
	assert(line == "rest of line")
	assert(rest == "rest of file")

	file:close()
end
