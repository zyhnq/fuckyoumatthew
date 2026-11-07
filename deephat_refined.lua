-- Compatibility loader for saved links. Urban Reload now loads Vanta Urban.
local source=game:HttpGet("https://raw.githubusercontent.com/zyhnq/fuckyoumatthew/main/vanta_urban.lua?v=20261106.13")
local run,err=loadstring(source,"@Vanta/vanta_urban.lua")
assert(run,err)
return run()
