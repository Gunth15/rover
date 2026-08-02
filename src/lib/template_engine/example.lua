function example(context)
	local list = {}
	list[#list + 1] = [===[
<!-- This will get turned into one big lua function where values passed to it are represented by a @<name> -->
<!DOCTYPE html>
<html lang="en" />

<head>
  <title>Examples</title>
</head>

<body>
  <h1>
    	]===]
	list[#list + 1] = "Lua string"
	list[#list + 1] = [===[

  </h1>
  <h2>
    	]===]
	list[#list + 1] = context.hello
	list[#list + 1] = [===[

  </h2>
  	]===]
	list[#list + 1] = 1 + 2
	list[#list + 1] = [===[

    <ol>
      	]===]
	for i = 1, #context.array, 1 do
		list[#list + 1] = [===[

        <li>
          	]===]
		list[#list + 1] = context.array[i]
		list[#list + 1] = [===[

        </li>
        	]===]
	end
	list[#list + 1] = [===[

    </ol>
</body	]===]
	return table.concat(list, "")
end

print(example({ array = { 1, 2, 3 }, hello = "hello" }))
