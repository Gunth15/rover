--rover test command (searches for test.lua or you can specify the file to look for)
--testing.bench for benchmarking
--testing.fuzz for fuzzing
--testing.core for core
--NOTE: should Add test for iterating over json arrays with null values
function rover.test(core)
	-- Isolate test to separate coroutines
	core.run(encode_test)
	core.run(decode_test)
end
function rover.bench(bench)
	bench.run(function(t)
		local x = 0
		for i = 1, 100, 1 do
			local x = x + (i * 2)
		end
	end)
end
function rover.fuzz(fuzzer)
	--Fuzzer need to generate random input
	--ref https://github.com/golang/go/blob/master/src/internal/fuzz/mutator.go
	--https://lcamtuf.coredump.cx/afl/technical_details.txt
	-- for every intersting edge, generate a corpus
	-- Make a bitmap of every unique path
	-- Timeout  of 1 se for path
	-- fuzz.fatal, fuzz.error, fuzz.fail
	fuzzer.add("balhlhlhadkjhfkhjdlk")
	fuzzer.add("true")
	fuzzer.add("1")
	fuzzer.run(fuxfuzz_decoder(str))
end

function encode_test(core)
	local obj = rover.json.object({ a = 1, b = 2 })
	local str = rover.json.encode(obj)
	core.expect_eql('{"a":1,"b":2}', str)
end
function decode_test(core)
	local str = '{"a":1,"b":2}'
	local x = rover.json.decode(str)
	core.expect_eql(1, x.a)
	core.expect_eql(1, x.b)
end
function fuzz_decoder(str)
	return rover.json.decode(str)
end
function fuzz_encoder(table)
	return rover.json.encode(table)
end
