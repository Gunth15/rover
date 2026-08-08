--rover test command (searches for test.lua or you can specify the file to look for)
--testing.bench for benchmarking
--testing.simulate for DST
--testing.core for core
function rover.test(core)
	-- Isolate test to separate lua runtimes
	core.run(Encode_test)
	core.run(Decode_test)
end
--TODO: bench and simulate will not make it to version 0.1
function rover.bench(bench)
	bench.run()
	bench.endpoint("GET", "/", nil)
end

function rover.simulate(sim)
	sim.route("GET", "/", nil)
	sim.route("POST", "/input", model)
end

function Encode_test()
	local obj = rover.json.object({ a = 1, b = 2 })
	local str = rover.json.encode(obj)
	assert('{"a":1,"b":2}' == str or '{"b":2,"a":1}' == str)
end
function Decode_test()
	local str = '{"a":1,"b":2}'
	local x = rover.json.decode(str)
	assert(1 == x.a)
	assert(1 == x.b)
end
