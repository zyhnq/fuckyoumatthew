-- Vanta AOT Revolution mission diagnostic: reads only, never fires remotes,
-- moves characters, simulates input, requires modules or installs hooks.
local player=assert(game:GetService("Players").LocalPlayer,"Run on the Roblox client")
assert(game.GameId==4658598196 or game.PlaceId==13379208636,"Join Attack on Titan Revolution first")
assert(type(writefile)=="function","This diagnostic needs executor writefile support")
local http=game:GetService("HttpService")
local replicated=game:GetService("ReplicatedStorage")
local report={version=1,placeId=game.PlaceId,gameId=game.GameId,errors={},bindings={},modules={},samples={},sources={}}
local function path(root,parts)
    for _,name in ipairs(parts) do root=root and root:FindFirstChild(name) end
    return root
end
local function full(object) local ok,value=pcall(function() return object:GetFullName() end); return ok and value or nil end
local function scalar(value)
    if type(value)=="number" then if value==value and math.abs(value)<math.huge then return value end; return tostring(value) end
    if type(value)=="string" then return value:sub(1,160) end
    if type(value)=="boolean" then return value end
    return tostring(value):sub(1,160)
end
local function describe(object)
    if not object then return nil end
    local result={path=full(object),class=object.ClassName}
    local ok,value=pcall(function() return object.Value end); if ok and value~=nil then result.value=scalar(value) end
    ok,value=pcall(function() return object.Text end); if ok and type(value)=="string" then result.text=value:sub(1,200) end
    return result
end
local function children(object,limit)
    local result={}; if not object then return result end
    for _,child in ipairs(object:GetChildren()) do if #result>=limit then break end; result[#result+1]={name=child.Name,class=child.ClassName} end
    return result
end
local function gameplay_attributes(object)
    local result={}; if not object then return result end
    local ok,attributes=pcall(object.GetAttributes,object)
    if ok then for key,value in pairs(attributes) do
        local lower=key:lower()
        if lower:find("blade",1,true) or lower:find("gas",1,true) or lower:find("grab",1,true) or lower:find("gear",1,true) or lower:find("health",1,true) or lower:find("reload",1,true) then result[key]=scalar(value) end
    end end
    return result
end
local candidates={}; local seen={}
local function module_score(name)
    local n=name:lower()
    if n:find("attack",1,true) or n:find("combat",1,true) or n:find("hitbox",1,true) then return 100 end
    if n:find("blade",1,true) or n:find("odm",1,true) or n:find("gear",1,true) then return 90 end
    if n:find("remote",1,true) or n:find("network",1,true) or n:find("mission",1,true) then return 60 end
    return 0
end
report.capabilities={getloadedmodules=type(getloadedmodules)=="function",decompile=type(decompile)=="function"}
if type(getloadedmodules)=="function" then
    local ok,modules=pcall(getloadedmodules)
    if ok and type(modules)=="table" then for _,module in pairs(modules) do
        local location=full(module)
        if location and (location:sub(1,17)=="ReplicatedStorage" or location:find("PlayerScripts",1,true) or location:find("Character",1,true)) then
            local score=module_score(location)
            if score>0 and #report.modules<140 then report.modules[#report.modules+1]=location end
            if score>0 and not seen[module] then seen[module]=true; candidates[#candidates+1]={module=module,path=location,score=score} end
        end
    end else report.errors[#report.errors+1]="Loaded modules: "..tostring(modules):sub(1,200) end
end
local function snapshot()
    local char=player.Character
    local root=char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
    local hum=char and char:FindFirstChildOfClass("Humanoid")
    local main=char and char:FindFirstChild("Main")
    local titans=workspace:FindFirstChild("Titans")
    local remotes=path(replicated,{"Assets","Remotes"})
    local gui=player:FindFirstChild("PlayerGui")
    local sample={time=os.clock(),character=full(char),health=hum and hum.Health,attributes=gameplay_attributes(char),main=children(main,48),
        weapon=describe(main and main:FindFirstChild("W")),bladeSets=describe(path(gui,{"Interface","HUD","Main","Top","Blade","Sets"})),titans={}}
    report.bindings={characterChildren=children(char,48),titanFolder=full(titans),post=describe(remotes and remotes:FindFirstChild("POST")),get=describe(remotes and remotes:FindFirstChild("GET")),
        remoteChildren=children(remotes,48),refill=describe(path(workspace,{"Unclimbable","Reloads","GasTanks","Refill"})),
        retry=describe(path(gui,{"Interface","Rewards","Main","Info","Main","Buttons","Retry"})),
        buttons=children(path(gui,{"Interface","Buttons"}),32),workspaceChildren=children(workspace,60)}
    local main_values={}
    if main then for _,object in ipairs(main:GetChildren()) do
        if object:IsA("ValueBase") then main_values[#main_values+1]=describe(object) end
    end end
    sample.mainValues=main_values
    if titans then for _,titan in ipairs(titans:GetChildren()) do
        if #sample.titans>=18 then break end
        if titan:IsA("Model") then
            local nape=path(titan,{"Hitboxes","Hit","Nape"})
            local health=titan:FindFirstChildOfClass("Humanoid")
            local marker=titan:FindFirstChild("Marker")
            local item={name=titan.Name,health=health and health.Health,children=children(titan,24),nape=describe(nape),attributes=gameplay_attributes(titan)}
            if nape and root and nape:IsA("BasePart") then item.distance=(nape.Position-root.Position).Magnitude end
            if marker then local ok,adornee=pcall(function() return marker.Adornee end); if ok then item.markedPart=full(adornee) end end
            sample.titans[#sample.titans+1]=item
        end
    end end
    report.samples[#report.samples+1]=sample
end
print("Vanta AOTR mission test started. Play normally, attack a titan and reload during the next 12 seconds.")
for i=1,7 do snapshot(); if i<7 then task.wait(2) end end
table.sort(candidates,function(a,b) return a.score>b.score end)
local function related(line)
    local text=line:lower()
    return text:find("invokeserver",1,true) or text:find("fireserver",1,true) or text:find("nape",1,true) or text:find("full_reload",1,true) or text:find("slash_escape",1,true)
end
for i=1,math.min(8,#candidates) do
    local candidate=candidates[i]
    local ok,source=pcall(function() return candidate.module.Source end)
    if (not ok or type(source)~="string" or source=="") and type(decompile)=="function" then ok,source=pcall(decompile,candidate.module) end
    local result={path=candidate.path,excerpts={}}
    if ok and type(source)=="string" then
        local lines={}; for line in (source.."\n"):gmatch("(.-)\n") do lines[#lines+1]=line end
        local last=0; local size=0
        for index,line in ipairs(lines) do
            if related(line) and index>last and #result.excerpts<8 and size<18000 then
                local excerpt={}; for j=math.max(1,index-4),math.min(#lines,index+8) do excerpt[#excerpt+1]=lines[j]:sub(1,600) end
                local value=table.concat(excerpt,"\n"); result.excerpts[#result.excerpts+1]={line=index,text=value}; size=size+#value; last=index+8
            end
        end
    else result.error=tostring(source):sub(1,200) end
    report.sources[#report.sources+1]=result
end
writefile("vanta_aotr_probe.json",http:JSONEncode(report))
print("Saved vanta_aotr_probe.json. Send this JSON file back for Vanta integration.")
