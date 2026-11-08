-- Vanta Basketball: read-only Blacktop / badge-point integration capture.
-- Opens no menus, sends no remotes, and does not move or control your player.
local Players=game:GetService("Players")
local Storage=game:GetService("ReplicatedStorage")
local Http=game:GetService("HttpService")
local player=assert(Players.LocalPlayer,"Run in the Roblox client")
assert(game.GameId==7529591378 or game.PlaceId==80681221431821,"Run in Practical Basketball")
assert(type(writefile)=="function","Executor writefile support required")
local output="vanta_badge_match_probe.json"
local result={version=2,game=game.GameId,place=game.PlaceId,modules={},module_inventory={},remotes={},samples={},errors={}}
local function relevant(s)
    s=tostring(s):lower()
    for _,term in ipairs({"blacktop","queue","matchmaking","badge","result","reward","postgame","score","endgame","return","stat"}) do
        if s:find(term,1,true) then return true end
    end
    return false
end
local function visible(object)
    local current=object
    while current do
        if current:IsA("GuiObject") and not current.Visible or current:IsA("ScreenGui") and not current.Enabled then return false end
        current=current.Parent
    end
    return true
end
local function attributes(object)
    local out={}
    for k,v in pairs(object:GetAttributes()) do
        if type(v)=="string" then out[k]=v:sub(1,160)
        elseif type(v)=="number" and v==v and math.abs(v)<math.huge or type(v)=="boolean" then out[k]=v end
    end
    return out
end
local function save()
    local ok,err=pcall(function() writefile(output,Http:JSONEncode(result)) end)
    if not ok then warn("Vanta badge capture save failed: "..tostring(err)) end
end
local started=os.clock()
local function snapshot()
    local sample={elapsed=os.clock()-started,world=attributes(workspace),player=attributes(player),gui={},values={}}
    local gui=player:FindFirstChild("PlayerGui")
    if gui then
        for _,o in ipairs(gui:GetDescendants()) do
            if #sample.gui>=180 then break end
            if o:IsA("GuiObject") and relevant(o:GetFullName()) and not o:GetFullName():find("ViewBuild",1,true) and not o:GetFullName():find("WorldModel",1,true) then
                local item={path=o:GetFullName(),class=o.ClassName,visible=visible(o),attributes=attributes(o)}
                if o:IsA("TextLabel") or o:IsA("TextButton") then item.text=o.Text:sub(1,240) end
                sample.gui[#sample.gui+1]=item
            end
        end
    end
    for _,o in ipairs(player:GetDescendants()) do
        if #sample.values>=100 then break end
        if o:IsA("ValueBase") and relevant(o.Name) then
            local v=o.Value
            if type(v)=="number" or type(v)=="boolean" or type(v)=="string" then
                sample.values[#sample.values+1]={path=o:GetFullName(),value=v}
            end
        end
    end
    result.samples[#result.samples+1]=sample
    save()
end
local remoteRoot=Storage:FindFirstChild("Aero")
remoteRoot=Storage:FindFirstChild("AeroRemoteServices") or (remoteRoot and remoteRoot:FindFirstChild("AeroRemoteServices"))
if remoteRoot then
    for _,o in ipairs(remoteRoot:GetDescendants()) do
        if (o:IsA("RemoteEvent") or o:IsA("RemoteFunction")) and relevant(o:GetFullName()) then
            result.remotes[#result.remotes+1]={path=o:GetFullName(),class=o.ClassName}
        end
    end
end
snapshot()
print("Vanta match capture started. Play normally inside a Blacktop match for 45 seconds.")
task.spawn(function()
    for _=1,15 do task.wait(3); snapshot() end
    result.finished=true; save()
    print("Saved vanta_badge_match_probe.json")
end)
-- Decompile only relevant client-side integration modules. Never require them.
local candidates={}
local function priority(o)
    local n=o:GetFullName():lower()
    for _,term in ipairs({"result","reward","postgame","endgame"}) do if n:find(term,1,true) then return 100 end end
    if o.Parent and o.Parent.Name=="Controllers" then return 95 end
    if n:find("score",1,true) or n:find("stat",1,true) then return 90 end
    if n:find("queue",1,true) or n:find("blacktop",1,true) then return 70 end
    return 20
end
local scripts=player:FindFirstChild("PlayerScripts")
local aero=scripts and scripts:FindFirstChild("Aero")
if aero then
    for _,o in ipairs(aero:GetDescendants()) do
        if o:IsA("ModuleScript") then result.module_inventory[#result.module_inventory+1]=o:GetFullName() end
        local direct=o.Parent and o.Parent.Name=="Controllers"
        local integration=direct and (o.Name=="Gui" or o.Name=="Player" or o.Name=="Data" or o.Name=="Game" or o.Name=="Interface")
        if o:IsA("ModuleScript") and (relevant(o:GetFullName()) or integration) then candidates[#candidates+1]=o end
    end
end
table.sort(candidates,function(a,b)
    local ac,bc=priority(a),priority(b)
    if ac~=bc then return ac>bc end
    return a:GetFullName()<b:GetFullName()
end)
for i,o in ipairs(candidates) do
    if i>16 then result.modules_truncated=true; break end
    local item={path=o:GetFullName()}
    result.modules[#result.modules+1]=item
    if type(decompile)=="function" then
        local ok,source=pcall(decompile,o)
        if ok and type(source)=="string" then item.source=source:sub(1,120000); item.truncated=#source>120000
        else item.error=tostring(source):sub(1,240) end
    else item.error="decompile unavailable" end
    save(); task.wait()
end
result.module_capture_finished=true; save()
