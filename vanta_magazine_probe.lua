-- Vanta Urban magazine diagnosis. Reads client state and saves one local JSON file.
local player=assert(game:GetService("Players").LocalPlayer,"Run on the Roblox client")
local http=game:GetService("HttpService")
assert(type(getgc)=="function","This capture needs getgc")
assert(type(writefile)=="function","This capture needs writefile")
local report={version=1,placeId=game.PlaceId,gameId=game.GameId,tables={},samples={},sources={},errors={}}
local tracked={}
local known=setmetatable({},{__mode="k"})
local function relevant(key)
    if type(key)~="string" then return false end
    local s=key:lower()
    return s:find("ammo",1,true) or s:find("clip",1,true) or s:find("mag",1,true)
        or s:find("round",1,true) or s:find("reload",1,true) or s:find("chamber",1,true)
        or s:find("weapon",1,true) or s:find("equipped",1,true)
end
local function path(object)
    local ok,value=pcall(function() return object:GetFullName() end)
    return ok and value or nil
end
local function brief(value,depth,seen)
    local kind=type(value)
    if kind=="number" then return value==value and math.abs(value)<math.huge and value or tostring(value) end
    if kind=="string" then return value:sub(1,120) end
    if kind=="boolean" then return value end
    if kind~="table" then return kind=="function" and "<function>" or path(value) or tostring(value):sub(1,120) end
    if seen[value] or depth<=0 then return "<table>" end
    seen[value]=true
    local copy,count={},0
    for key,item in next,value do
        if count>=40 then break end
        if type(key)=="string" or type(key)=="number" then
            copy[tostring(key)]=brief(item,depth-1,seen); count=count+1
        end
    end
    seen[value]=nil
    return copy
end
local function fields(object)
    local copy,count={},0
    for key,value in next,object do
        if count>=24 then break end
        if relevant(key) or key=="Fire" or key=="Name" or key=="Id" or key=="Type" or key=="Slots" then
            copy[tostring(key)]=brief(value,2,{}); count=count+1
        end
    end
    return copy
end
local function scan()
    local ok,objects=pcall(getgc,true)
    if not ok or type(objects)~="table" then report.errors[#report.errors+1]="Client table scan failed"; return end
    for _,object in pairs(objects) do
        if #tracked>=96 then break end
        if type(object)=="table" and not known[object] then
            local match=false
            for key in next,object do if relevant(key) then match=true; break end end
            if match then
                known[object]=true
                local keys={}
                for key in next,object do
                    if #keys>=64 then break end
                    if type(key)=="string" or type(key)=="number" then keys[#keys+1]=tostring(key) end
                end
                table.sort(keys)
                tracked[#tracked+1]=object
                report.tables[#tracked]={id=#tracked,keys=keys,initial=fields(object)}
            end
        end
    end
end
-- Scan before allocating the report's samples so the capture cannot discover its own tables.
scan()
local function instances()
    local result={}
    local function inspect(object)
        local attrs={}
        local ok,all=pcall(function() return object:GetAttributes() end)
        if ok then for key,value in pairs(all) do if relevant(key) then attrs[key]=brief(value,1,{}) end end end
        if next(attrs) or object:IsA("Tool") then result[#result+1]={path=path(object),attributes=attrs} end
    end
    for _,container in pairs({player:FindFirstChild("Backpack"),player.Character}) do
        if container then
            inspect(container)
            for _,object in ipairs(container:GetDescendants()) do
                if #result>=64 then break end
                if object:IsA("Tool") or relevant(object.Name) then
                    inspect(object)
                    if object:IsA("ValueBase") then
                        result[#result+1]={path=path(object),value=brief(object.Value,1,{})}
                    end
                end
            end
        end
    end
    return result
end
local started=os.clock()
print("Vanta magazine capture started. Fire a few rounds, reload, and switch weapons during the next 12 seconds.")
repeat
    local sample={time=os.clock()-started,values={},instances=instances()}
    for id,object in ipairs(tracked) do sample.values[id]=fields(object) end
    report.samples[#report.samples+1]=sample
    task.wait(.1)
until os.clock()-started>=12 or #report.samples>=140
if type(getloadedmodules)=="function" and type(decompile)=="function" then
    local ok,modules=pcall(getloadedmodules)
    if ok and type(modules)=="table" then
        for _,module in ipairs(modules) do
            if #report.sources>=6 then break end
            local name=path(module)
            if name=="ReplicatedStorage.Weapons.Inventory" or name=="ReplicatedStorage.Weapons.Clips"
                or name=="ReplicatedStorage.Weapons.WeaponData" or name=="ReplicatedStorage.Weapons.Config" then
                local decoded,source=pcall(decompile,module)
                if decoded and type(source)=="string" then
                    local lines={}
                    for line in (source.."\n"):gmatch("(.-)\n") do lines[#lines+1]=line end
                    local selected={}
                    for i,line in ipairs(lines) do
                        if relevant(line) or line:find("RPM",1,true) then
                            for j=math.max(1,i-4),math.min(#lines,i+6) do selected[j]=true end
                        end
                    end
                    local excerpts,bytes={},0
                    for i,line in ipairs(lines) do
                        if selected[i] and bytes<24000 then excerpts[#excerpts+1]={line=i,text=line}; bytes=bytes+#line end
                    end
                    report.sources[#report.sources+1]={path=name,excerpts=excerpts}
                end
            end
        end
    end
end
writefile("vanta_magazine_probe.json",http:JSONEncode(report))
print("Saved vanta_magazine_probe.json")
