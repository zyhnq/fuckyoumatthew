-- Read-only trace of a running Vanta AOTR farm. No movement/input/remote calls.
local player=assert(game:GetService("Players").LocalPlayer,"Run on the client")
assert(game.GameId==4658598196 or game.PlaceId==13379208636,"Join AOT Revolution first")
assert(type(writefile)=="function","Executor writefile support required")
local http=game:GetService("HttpService")
local report={version=1,placeId=game.PlaceId,samples={},modules={},sources={},errors={}}
local function full(value) local ok,path=pcall(function() return value:GetFullName() end); return ok and path or nil end
local function value(v)
    if type(v)=="number" then if v==v and math.abs(v)<math.huge then return v end; return tostring(v) end
    if type(v)=="string" or type(v)=="boolean" then return v end
    return full(v) or tostring(v):sub(1,200)
end
local function sample()
    local char=player.Character; local root=char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
    local hum=char and char:FindFirstChildOfClass("Humanoid")
    local gui=player:FindFirstChild("PlayerGui"); local hub=gui and gui:FindFirstChild("VantaAOTR")
    local status=hub and hub:FindFirstChild("Status",true)
    local s={time=os.clock(),status=status and status.Text,health=hum and hum.Health,root=full(root),physics={},titans={},controls={}}
    if root then
        s.position=tostring(root.Position); s.velocity=tostring(root.AssemblyLinearVelocity); s.anchored=root.Anchored
        for _,obj in ipairs(root:GetChildren()) do
            local d={name=obj.Name,class=obj.ClassName}
            for _,key in ipairs({"Velocity","MaxForce","CFrame","MaxTorque","Enabled","VectorVelocity","Position","P","D"}) do local ok,v=pcall(function() return obj[key] end); if ok and v~=nil then d[key]=value(v) end end
            s.physics[#s.physics+1]=d
        end
    end
    if hub then
        for _,obj in ipairs(hub:GetDescendants()) do
            if obj.Name:sub(1,7)=="Toggle_" then local knob=obj:FindFirstChildWhichIsA("Frame"); s.controls[obj.Name]=knob and knob.Position.X.Offset end
        end
    end
    local titans=workspace:FindFirstChild("Titans")
    if titans then
        s.titanCount=#titans:GetChildren()
        for _,titan in ipairs(titans:GetChildren()) do
            local h=titan:FindFirstChildOfClass("Humanoid")
            local boxes=titan:FindFirstChild("Hitboxes"); local hit=boxes and boxes:FindFirstChild("Hit"); local nape=hit and hit:FindFirstChild("Nape")
            if h and h.Health>0 and nape and root then s.titans[#s.titans+1]={name=titan.Name,health=h.Health,distance=(nape.Position-root.Position).Magnitude} end
        end
        table.sort(s.titans,function(a,b) return a.distance<b.distance end)
        while #s.titans>6 do table.remove(s.titans) end
    end
    report.samples[#report.samples+1]=s
end
local candidates={}
if type(getloadedmodules)=="function" then
    local ok,modules=pcall(getloadedmodules)
    if ok and type(modules)=="table" then for _,module in pairs(modules) do
        local path=full(module)
        if path and not path:lower():find("cutscene",1,true) and path:find("Host.Modules",1,true) then
            report.modules[#report.modules+1]=path
            local name=module.Name:lower(); local score=0
            if name:find("hitbox",1,true) or name:find("attack",1,true) or name:find("combat",1,true) then score=100
            elseif name:find("network",1,true) or name:find("socket",1,true) or name:find("remote",1,true) or name:find("input",1,true) then score=95
            elseif name=="blades" then score=90 elseif name=="odmg" then score=85 elseif name:find("cache",1,true) then score=70 end
            if score>0 then candidates[#candidates+1]={object=module,path=path,score=score} end
        end
    end else report.errors[#report.errors+1]=tostring(modules) end
end
print("Vanta AOTR trace started. Enable Auto farm and close its menu during this 12-second capture.")
for i=1,13 do sample(); if i<13 then task.wait(1) end end
table.sort(candidates,function(a,b) return a.score>b.score end)
for i=1,math.min(10,#candidates) do
    local item=candidates[i]; local ok,source=pcall(function() return item.object.Source end)
    if (not ok or type(source)~="string" or source=="") and type(decompile)=="function" then ok,source=pcall(decompile,item.object) end
    if ok and type(source)=="string" then report.sources[#report.sources+1]={path=item.path,source=source:sub(1,180000),truncated=#source>180000}
    else report.sources[#report.sources+1]={path=item.path,error=tostring(source):sub(1,200)} end
end
writefile("vanta_aotr_trace.json",http:JSONEncode(report))
print("Saved vanta_aotr_trace.json")
