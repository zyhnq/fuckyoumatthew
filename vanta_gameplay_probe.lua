-- Vanta: 180-second observational gameplay capture. No remote calls, hooks or inputs.
local Players=game:GetService("Players")
local Input=game:GetService("UserInputService")
local Run=game:GetService("RunService")
local Http=game:GetService("HttpService")
assert(Run:IsClient(),"Join Practical Basketball and attach to its Roblox client")
assert(type(writefile)=="function","Probe needs executor writefile support")
local deadline=os.clock()+60
while not Players.LocalPlayer or not game:IsLoaded() do
    assert(os.clock()<deadline,"Client startup timed out; reattach inside the game")
    task.wait(.1)
end
local player=Players.LocalPlayer
assert(game.GameId==7529591378 or game.PlaceId==80681221431821,"Run this probe in Practical Basketball")
local scripts=player:FindFirstChild("PlayerScripts")
local aero=scripts and scripts:FindFirstChild("Aero")
local controllers=aero and aero:FindFirstChild("Controllers")
assert(controllers,"Wait until the Practical Basketball client loads")
local function controller(name)
    local module=controllers:FindFirstChild(name)
    if module then local ok,value=pcall(require,module); if ok then return value end end
end
local pc=assert(controller("Player"),"Player controller unavailable; enter a court")
local courts=controller("Courts")
local started=os.clock(); local active=true; local links={}; local roster={}; local next_roster=0
local report={version=1,requested_seconds=180,sample_interval=.1,started_unix=os.time(),game=game.GameId,place=game.PlaceId,
    observation_only=true,samples={},events={},errors={},geometry={},channels={},counts={actions={},inputs={},shots=0,possession_changes=0}}
local output="vanta_gameplay_probe.json"
local ids={[player]=0}; local serial=0; local last={}; local motion={}; local limits={samples=1801,events=3500,errors=30}
local function number(v) if type(v)=="number" and v==v and math.abs(v)<math.huge then return math.floor(v*1000+.5)/1000 end end
local function vector(v) if v then return {number(v.X),number(v.Y),number(v.Z)} end end
local function primitive(v)
    if type(v)=="boolean" then return v end
    if type(v)=="number" then return number(v) end
    if type(v)=="string" then return v:sub(1,100) end
end
local function error_log(message)
    if #report.errors<limits.errors then report.errors[#report.errors+1]={t=number(os.clock()-started),message=tostring(message):sub(1,200)} end
end
local function event(kind,value)
    if active and #report.events<limits.events then report.events[#report.events+1]={t=number(os.clock()-started),kind=kind,value=value} end
end
local function listen(signal,fn)
    if signal then local ok,link=pcall(function() return signal:Connect(fn) end); if ok and link then links[#links+1]=link end end
end
local function actor_id(who)
    if ids[who]==nil then serial=serial+1; ids[who]=serial end
    return ids[who]
end
local function current_character()
    local ok,c=pcall(function() return pc:GetCharacter() end)
    if ok and c then return c end
end
local function rig(who,c)
    local data=c and c.data
    local model=data and (data.model or data.Model or data.Character)
    if typeof(model)~="Instance" then model=nil end
    local folder=workspace:FindFirstChild("Characters")
    return model or folder and folder:FindFirstChild(who.Name) or who.Character
end
local fields={"Action","Basketball","Team","CourtNumber","Stamina","CanMove","OnCourt","InGame","InAir","Debounce","Hand","IsSprinting","Sprinting","HoldingG","ReleasedShot","ShotStartTime","BaseAnimation","CanClutch","AnkleBroken","AnklesBroken","KnockedDown"}
local function attributes(model,c)
    local data=c and c.data and c.data.Attributes
    local out={}
    for _,key in ipairs(fields) do
        local v=data and data[key]
        if v==nil and model then v=model:GetAttribute(key) end
        out[key]=primitive(v)
    end
    return out
end
local function root(model,c)
    local p=c and c.data and (c.data.HumanoidRootPart or c.data.Root)
    if typeof(p)=="Instance" and p:IsA("BasePart") then return p end
    return model and (model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart)
end
local rims={}; local balls={}; local feedback={}; local geometry_ready=false
local function refresh(c,own_model)
    roster={}
    for i,who in ipairs(Players:GetPlayers()) do if i>50 then break end
        local model=who==player and own_model or rig(who)
        local part=root(model,who==player and c or nil)
        if model and part then roster[#roster+1]={who=who,model=model,part=part,id=actor_id(who)} end
    end
    balls={}; local folder=workspace:FindFirstChild("Basketballs")
    if folder then for _,p in ipairs(folder:GetChildren()) do if p:IsA("BasePart") and #balls<8 then balls[#balls+1]=p end end end
    feedback={}; local gui=player:FindFirstChild("PlayerGui")
    if gui then for _,o in ipairs(gui:GetDescendants()) do
        if #feedback>=16 then break end
        if o:IsA("TextLabel") and (o.Name=="ReleaseTiming" or o.Name=="ShotFeedback" or o.Name=="ShotQuality" or o.Name=="Coverage") then feedback[#feedback+1]=o end
    end end
    if not geometry_ready then
        local map=workspace:FindFirstChild("Map")
        if map then
            geometry_ready=true
            for i,o in ipairs(map:GetDescendants()) do if i>20000 then break end
                if o:IsA("BasePart") then
                    local name=o.Name:lower():gsub("[^%w]","")
                    if (name=="rim" or name=="basketrim" or name=="hooprim") and #rims<16 then
                        rims[#rims+1]=o; report.geometry[#report.geometry+1]={kind="rim",position=vector(o.Position)}
                    elseif o.Parent and o.Parent.Name=="OutOfBounds" and #report.geometry<100 then
                        report.geometry[#report.geometry+1]={kind="boundary",position=vector(o.Position),size=vector(o.Size)}
                    end
                end
            end
        end
    end
end
local function save(reason)
    report.elapsed=number(os.clock()-started); report.reason=reason; report.finished=not active
    local ok,err=pcall(function() writefile(output,Http:JSONEncode(report)) end)
    if not ok then error_log("Save failed: "..tostring(err)); warn("Vanta probe could not save: "..tostring(err)) end
    return ok
end
local keys={"W","A","S","D","Z","X","C","V","H","E","G","Space","LeftShift","F6","F7"}
local allowed={}
for _,name in ipairs(keys) do allowed[name]=true end
for _,name in ipairs({"ButtonA","ButtonB","ButtonX","ButtonY","ButtonL1","ButtonR1","ButtonL2","ButtonR2","DPadUp","DPadDown","DPadLeft","DPadRight"}) do allowed[name]=true end
local function input_event(down,obj,processed)
    if not active or Input:GetFocusedTextBox() then return end
    local name=obj.KeyCode and obj.KeyCode.Name
    if allowed[name] then
        event("input",{key=name,down=down,processed=processed==true})
        if down then report.counts.inputs[name]=(report.counts.inputs[name] or 0)+1 end
    end
end
listen(Input.InputBegan,function(obj,p) input_event(true,obj,p) end)
listen(Input.InputEnded,function(obj,p) input_event(false,obj,p) end)
listen(Input.WindowFocusReleased,function() event("focus",false) end)
listen(Input.WindowFocused,function() event("focus",true) end)
listen(player.Idled,function(elapsed) event("idle",number(elapsed)) end)
local function finish(reason)
    if not active then return end
    event("capture_end",reason); active=false
    for _,link in ipairs(links) do pcall(function() link:Disconnect() end) end
    if save(reason) then print("Saved "..output.." ("..tostring(report.elapsed).." seconds / "..#report.samples.." samples)") end
end
listen(player.OnTeleport,function(phase)
    if phase==Enum.TeleportState.Started or phase==Enum.TeleportState.InProgress then finish("teleport / partial capture") end
end)
-- Observe existing public client signals only. Never invoke a service action.
local function small(v,depth)
    local p=primitive(v); if p~=nil then return p end
    if depth<1 and type(v)=="table" then
        local out={}; local n=0
        for k,x in pairs(v) do if type(k)=="string" or type(k)=="number" then n=n+1; if n>12 then break end; out[tostring(k)]=small(x,depth+1) end end
        return out
    end
end
for service_name,service in pairs(pc.Services or {}) do
    if type(service)=="table" then for name,signal in pairs(service) do
        local lower=tostring(name):lower()
        if #report.channels<30 and (lower:find("shot",1,true) or lower:find("score",1,true) or lower:find("feedback",1,true) or lower:find("made",1,true) or lower:find("miss",1,true)) and type(signal)=="table" and type(signal.Connect)=="function" then
            local label=tostring(service_name).."."..tostring(name)
            report.channels[#report.channels+1]=label
            listen(signal,function(...) local args={}; for i=1,math.min(6,select("#",...)) do args[i]=small(select(i,...),0) end; event("client_signal",{channel=label,args=args}) end)
        end
    end end
end
local function sample()
    local now=os.clock(); local c=current_character(); local model=rig(player,c); local mine=root(model,c)
    if now>=next_roster then next_roster=now+1; refresh(c,model) end
    local row={t=number(now-started),actors={},keys={},balls={},feedback={},typing=Input:GetFocusedTextBox()~=nil,mode=primitive(workspace:GetAttribute("Gamemode"))}
    if not row.typing then for _,key in ipairs(keys) do if Input:IsKeyDown(Enum.KeyCode[key]) then row.keys[#row.keys+1]=key end end end
    pcall(function()
        row.gamepad={}
        for _,state in ipairs(Input:GetGamepadState(Enum.UserInputType.Gamepad1)) do
            local name=state.KeyCode.Name
            if name=="Thumbstick1" or name=="Thumbstick2" or name=="ButtonL2" or name=="ButtonR2" then row.gamepad[name]=vector(state.Position) end
        end
    end)
    local own=attributes(model,c); row.local_attributes=own
    if c and c.Movement then row.move=vector(c.Movement.MoveDirection); row.last_move=vector(c.Movement.lastMoveDirection) end
    table.sort(roster,function(a,b)
        if a.id==0 then return b.id~=0 end; if b.id==0 then return false end
        return mine and (a.part.Position-mine.Position).Magnitude<(b.part.Position-mine.Position).Magnitude or not mine and a.id<b.id
    end)
    for _,actor in ipairs(roster) do
        if #row.actors>=8 then break end
        local other_court=actor.model:GetAttribute("CourtNumber")
        local same_court=own.CourtNumber==nil or other_court==nil or other_court==own.CourtNumber or tostring(other_court)==tostring(own.CourtNumber) or tonumber(own.CourtNumber)~=nil and tonumber(other_court)==tonumber(own.CourtNumber)
        if actor.part.Parent and actor.model:IsDescendantOf(workspace) and (actor.id==0 or same_court) then
            local a=actor.id==0 and own or attributes(actor.model)
            local p=actor.part.Position; local item={id=actor.id,position=vector(p),reported_velocity=vector(actor.part.AssemblyLinearVelocity),attributes=a}
            local previous=motion[actor.id]
            if previous and now>previous.t then
                local v=(p-previous.p)/(now-previous.t)
                if v.Magnitude<100 then item.observed_velocity=vector(v) else item.position_jump=true end
            end
            motion[actor.id]={p=p,t=now}; row.actors[#row.actors+1]=item
            local observed=last[actor.id]~=nil; local prior=last[actor.id] or {}
            if prior.Action~=a.Action then
                event("action",{actor=actor.id,from=prior.Action,to=a.Action})
                if observed and actor.id==0 and a.Action then report.counts.actions[a.Action]=(report.counts.actions[a.Action] or 0)+1 end
            end
            if prior.Basketball~=a.Basketball then event("possession",{actor=actor.id,has_ball=a.Basketball,initial=not observed}); if observed and actor.id==0 then report.counts.possession_changes=report.counts.possession_changes+1 end end
            if a.ShotStartTime and prior.ShotStartTime~=a.ShotStartTime then event(observed and "shot_start" or "initial_shot_state",{actor=actor.id,stamp=a.ShotStartTime,animation=a.BaseAnimation}); if observed and actor.id==0 then report.counts.shots=report.counts.shots+1 end end
            last[actor.id]={Action=a.Action,Basketball=a.Basketball,ShotStartTime=a.ShotStartTime}
        end
    end
    if c and c.Animation and c.Animation.Animator then
        row.tracks={}
        for i,t in ipairs(c.Animation.Animator:GetPlayingAnimationTracks()) do if i>12 then break end
            row.tracks[#row.tracks+1]={name=t.Name,position=number(t.TimePosition),speed=number(t.Speed),weight=number(t.WeightCurrent)}
        end
    end
    for _,ball in ipairs(balls) do if ball.Parent then row.balls[#row.balls+1]={position=vector(ball.Position),velocity=vector(ball.AssemblyLinearVelocity),mid_shot=primitive(ball:GetAttribute("MidShot"))} end end
    for _,label in ipairs(feedback) do if label.Parent and label.Visible then row.feedback[#row.feedback+1]={kind=label.Name,text=label.Text:sub(1,120)} end end
    if courts and courts.CurrentCourt then
        local court=courts.CurrentCourt; local q=court.Quarter
        row.court={number=primitive(court.CourtNumber),clock=primitive(court.Shotclock),home=primitive(court.Team1Score),away=primitive(court.Team2Score),status=primitive(court.Scoreboard and court.Scoreboard.LastStatus),quarter=q and primitive(q.QuarterCurrent),period_time=q and primitive(q.QuarterTime)}
    end
    if #report.samples<limits.samples then report.samples[#report.samples+1]=row end
end
print("Vanta probe: recording 3 minutes. Play normally; the probe sends no inputs. Checkpoints save every 30 seconds.")
save("recording")
local next_save=30; local next_progress=30
local ok,err=xpcall(function()
    while active and os.clock()-started<180 do
        local good,why=pcall(sample); if not good then error_log(why) end
        local elapsed=os.clock()-started
        if elapsed>=next_save then save("recording"); next_save=next_save+30 end
        if elapsed>=next_progress then print("Vanta probe: "..math.floor(elapsed).." / 180 seconds"); next_progress=next_progress+30 end
        task.wait(math.min(.1,math.max(.001,180-(os.clock()-started))))
    end
end,function(message) return tostring(message) end)
if not ok then error_log(err) end
finish(ok and "completed" or "error / partial capture")
return report
