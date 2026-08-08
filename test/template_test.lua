--rover test command (searches in test directory for files with *_test naming convention or you can specify the file to look for using the f flag)
function rover.test(core)
	core.run(template_test)
end

function template_test()
	local expected = [[
    <!-- This will get turned into one big lua function where values passed to it are represented by a @<name> -->
    <!DOCTYPE html>
    <html lang="en" />

    <head>
      <title>Examples</title>
    </head>

    <body>
      <h1>
          Lua string
      </h1>
      <h2>
          hello
      </h2>
        3
        <ol>
            
            <li>
                1
            </li>
              
            <li>
                2
            </li>
              
            <li>
                3
            </li>
              
        </ol>
    </body>
  ]]
	local hello = rover.templ.load(
		"hello",
		[[
      <!-- This will get turned into one big lua function where values passed to it are represented by a @<name> -->
      <!DOCTYPE html>
      <html lang="en" />

      <head>
        <title>Examples</title>
      </head>

      <body>
        <h1>
          <%= "Lua string" %>
        </h1>
        <h2>
          <%= @hello %>
        </h2>
        <%= 1 + 2 %>
          <ol>
            <% for i=1, #@array, 1 do %>
              <li>
                <%= @array[i] %>
              </li>
              <% end %>
          </ol>
      </body>
      ]]
	)
	assert(expected == hello({ hello = "hello", array = { 1, 2, 3 } }))
end
