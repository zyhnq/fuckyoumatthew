-- language: Lua, file: pivot_hub.lua, runtime: Roblox client executor, target: Practical Basketball / Windows
local Core = {}
local defaults = {hold=550, lead=0, tap=40, gap=110, macro="Z X C", shot="F6", combo="F7", menu="RightShift"}
local limits = {hold={50,2000}, lead={-250,250}, tap={20,250}, gap={20,500}}
function Core.copy(source)
    local result = {}; for key, value in pairs(source) do result[key] = value end; return result
end
function Core.parse(source, tap, gap)
    if type(source) ~= "string" or #source > 1024 then return nil, "Sequence must be text, up to 1024 characters." end
    local steps = {}
    for word in source:upper():gmatch("%S+") do
        local chord, hold_ms, gap_ms = word:match("^([^:]+):(%d+)/(%d+)$")
        if not chord then chord = word; hold_ms = tap; gap_ms = gap end
        local shifted, key = chord:match("^(SHIFT%+)([ZXCVH])$")
        if not shifted then key = chord:match("^([ZXCVH])$") end
        if not key then return nil, "Use Z X C V H or SHIFT+key; optional :hold/gap in ms." end
        hold_ms, gap_ms = tonumber(hold_ms), tonumber(gap_ms)
        if not hold_ms or hold_ms < 20 or hold_ms > 250 or not gap_ms or gap_ms < 20 or gap_ms > 500 then
            return nil, "Each hold must be 20-250 ms; each gap 20-500 ms."
        end
        steps[#steps+1] = {keys=shifted and {"LeftShift",key} or {key}, hold=hold_ms, gap=gap_ms}
        if #steps > 24 then return nil, "Maximum sequence length is 24 steps." end
    end
    if #steps == 0 then return nil, "Enter at least one step." end
    return steps
end
local function hotkey(value)
    if value == "RightShift" then return true end
    if type(value) ~= "string" then return false end
    local index = tonumber(value:match("^F(%d+)$"))
    return index and index >= 1 and index <= 12 and index ~= 8 and value == "F"..index
end
function Core.validate(source)
    if type(source) ~= "table" then return nil, "Profile must be an object." end
    local result = {}
    for name, range in pairs(limits) do
        local value = tonumber(source[name])
        if not value or value ~= value or value < range[1] or value > range[2] then
            return nil, name.." must be "..range[1].." to "..range[2].."."
        end
        result[name] = math.floor(value)
    end
    local used = {}
    for _, name in ipairs({"shot","combo","menu"}) do
        local value = source[name]
        if not hotkey(value) or used[value] then return nil, "Use unique F1-F12 or RightShift; F8 stays Cancel." end
        used[value] = true; result[name] = value
    end
    local steps, err = Core.parse(source.macro, result.tap, result.gap)
    if not steps then return nil, err end
    result.macro = source.macro
    return result
end
function Core.median(samples)
    if #samples == 0 then return nil end
    local sorted = {}; for _, value in ipairs(samples) do sorted[#sorted+1] = value end
    table.sort(sorted); local middle = math.floor(#sorted/2)+1
    return #sorted%2 == 1 and sorted[middle] or (sorted[middle-1]+sorted[middle])/2
end
function Core.runner(deps)
    local self = {current=nil, held={}, closed=false}
    function self:release(owner)
        local keys = {}; for key, token in pairs(self.held) do if not owner or token == owner then keys[#keys+1] = key end end
        table.sort(keys, function(a,b) return a ~= "LeftShift" and b == "LeftShift" end)
        for _, key in ipairs(keys) do
            local ok = pcall(deps.send, key, false)
            if ok then self.held[key] = nil end
        end
        return next(self.held) == nil
    end
    function self:cancel()
        if self.current then self.current.cancelled = true end
        self.current = nil
        return self:release()
    end
    function self:wait(ms, token)
        local deadline = deps.now()+ms/1000
        while deps.now() < deadline do
            if token.cancelled or self.closed then return false end
            deps.frame()
        end
        return not token.cancelled and not self.closed
    end
    function self:step(keys, ms, token)
        if token.cancelled or self.closed then return false end
        for _, key in ipairs(keys) do if deps.down(key) then error("Release "..key.." before starting.") end end
        for _, key in ipairs(keys) do self.held[key] = token; deps.send(key, true) end
        local start = deps.now()
        if not self:wait(ms, token) then return false end
        for index = #keys, 1, -1 do
            local key = keys[index]; deps.send(key, false); self.held[key] = nil
        end
        return true, (deps.now()-start)*1000
    end
    function self:start(action, done)
        if self.closed or self.current then return false, "An action is already running." end
        if next(self.held) then return false, "Key release is pending. Press F8 to retry." end
        local token = {}; self.current = token
        deps.spawn(function()
            local ok, result = pcall(action, token)
            local released = self:release(token)
            if self.current ~= token then return end
            self.current = nil
            if not released then done(false, "Key release failed. Press F8 and tap the affected key.")
            else done(ok, result) end
        end)
        return true
    end
    return self
end
function Core.scope()
    local self={changes={},order={},cleanup={},callbacks={},closed=false}
    function self:defer(fn) self.cleanup[#self.cleanup+1]=fn end
    function self:attribute(object,key,value)
        self.attributes=self.attributes or {}
        local cache=self.attributes[object]
        if not cache then cache={}; self.attributes[object]=cache end
        if not cache[key] then
            local item={original=object:GetAttribute(key)}; cache[key]=item
            self:defer(function() if object:GetAttribute(key)==item.applied then object:SetAttribute(key,item.original) end end)
        end
        cache[key].applied=value; object:SetAttribute(key,value)
    end
    function self:set(object,key,value)
        assert(not self.closed,"Scope is closed")
        local properties=self.changes[object]
        if not properties then properties={}; self.changes[object]=properties end
        if not properties[key] then
            properties[key]={original=object[key]}; self.order[#self.order+1]={object,key}
        end
        properties[key].applied=value; object[key]=value
    end
    function self:close()
        if self.closed then return end
        self.closed=true
        for index=#self.cleanup,1,-1 do pcall(self.cleanup[index]) end
        for index=#self.order,1,-1 do
            local pair=self.order[index]; local saved=self.changes[pair[1]][pair[2]]
            pcall(function() if pair[1][pair[2]]==saved.applied then pair[1][pair[2]]=saved.original end end)
        end
    end
    return self
end
function Core.module_registry(report)
    local self={definitions={},active={},errors={},closed=false}
    function self:register(id,definition)
        assert(not self.definitions[id],"Duplicate module: "..id)
        self.definitions[id]=definition
    end
    function self:disable(id)
        local entry=self.active[id]; if not entry then return end
        self.active[id]=nil; entry.scope:close()
    end
    function self:enable(id,settings)
        if self.closed then return false,"Module system is closed" end
        if self.active[id] then return true end
        local definition=self.definitions[id]; if not definition then return false,"Unknown module" end
        for _,other in ipairs(definition.conflicts or {}) do if self.active[other] then return false,"Disable "..other.." first" end end
        local scope=Core.scope()
        local ok,state=pcall(definition.start,scope,settings)
        if not ok then scope:close(); self.errors[id]=tostring(state); return false,tostring(state) end
        self.errors[id]=nil; self.active[id]={scope=scope,state=state,settings=settings,elapsed=0}
        return true
    end
    function self:step(dt)
        local ids={}; for id in pairs(self.active) do ids[#ids+1]=id end
        for _,id in ipairs(ids) do
            local entry=self.active[id]; local definition=self.definitions[id]
            if entry and definition.step then
                entry.elapsed=entry.elapsed+dt
                if entry.elapsed>=(definition.interval or 0) then
                    local elapsed=entry.elapsed; entry.elapsed=0
                    local ok,err=pcall(definition.step,entry.scope,entry.state,entry.settings,elapsed)
                    if not ok then self:disable(id); self.errors[id]=tostring(err); report(id..": "..tostring(err)) end
                end
            end
        end
    end
    function self:stop_all()
        local ids={}; for id in pairs(self.active) do ids[#ids+1]=id end
        for _,id in ipairs(ids) do self:disable(id) end
    end
    function self:close() self:stop_all(); self.closed=true end
    return self
end
function Core.bounded(value,minimum,maximum)
    value=tonumber(value)
    if not value or value~=value or value==math.huge or value==-math.huge or value<minimum or value>maximum then return nil end
    return value
end
function Core.animation_release(scope,deps)
    local state={watched={},sent={},metadata=setmetatable({},{__mode="k"}),profiles=deps.profiles or {},pending={},closed=false}
    local function profile(track,name)
        local animation=track.Animation
        local key=name.."/"..tostring(animation and animation.AnimationId or "")
        if not state.profiles[key] then
            local attributes=deps.attributes()
            local initial=.60
            if attributes and attributes.Action=="Dunking" then initial=.36 end
            if name=="InsideHandLayup1R" then initial=.70 end
            state.profiles[key]={ratio=initial}
        end
        return state.profiles[key]
    end
    function state:feedback(code)
        code=tonumber(code)
        if not code or code%1~=0 or code<1 or code>8 or #self.pending==0 then return end
        local pending=table.remove(self.pending,1)
        local p=pending.profile; local early=code<=3; local late=code>=6
        if early then p.early=math.max(p.early or .25,pending.ratio)
        elseif late then p.late=math.min(p.late or .85,pending.ratio)
        else deps.report(code==5 and "Perfect release / keeping timing" or "Good release / keeping timing"); return end
        if p.early and p.late and p.early>=p.late then
            if early then p.late=nil else p.early=nil end
        end
        if p.early and p.late then p.ratio=(p.early+p.late)/2
        else
            local step=(code==1 or code==8) and .06 or (code==2 or code==7) and .04 or .02
            p.ratio=math.max(.25,math.min(p.ceiling or .85,pending.ratio+(early and step or -step)))
        end
        p.ratio=math.max(.25,math.min(p.ceiling or .85,p.ratio))
        deps.report(late and "Late feedback / next release earlier" or "Early feedback / next release later")
    end
    local function release_time(track)
        if state.metadata[track]==nil then
            local ok,time=pcall(function() return track:GetTimeOfKeyframe("Release") end)
            state.metadata[track]=ok and Core.bounded(time,.0001,30) or false
        end
        return state.metadata[track] or nil
    end
    local function eligible(track)
        if state.closed or deps.paused() or not deps.held() then return nil end
        local attributes=deps.attributes()
        if not attributes or (attributes.Action~="Shooting" and attributes.Action~="Dunking") or attributes.ReleasedShot~=false then return nil end
        local shot=Core.bounded(attributes.ShotStartTime,0,math.huge)
        local name=attributes.BaseAnimation
        if not shot or type(name)~="string" or name=="" or state.sent[shot] then return nil end
        local animation=track.Animation
        local named=track.Name==name or animation and animation.Name==name
        local generic=track.Name=="Animation" and animation and animation.Name=="Animation" and release_time(track)~=nil
        if not named and not generic then return nil end
        return shot,name
    end
    local function release(track,marker)
        local shot,name=eligible(track); if not shot then return end
        local entry=state.watched[track]; if not entry or entry.shot~=shot then return end
        if marker=="Pause" or (entry.release_time and marker~="Shot phase") then return end
        state.sent={[shot]=true}
        local ok,err=pcall(deps.release)
        if not ok then state.error=tostring(err); state.closed=true; deps.failed(state.error); return end
        if entry.release_time then
            local p=profile(track,name)
            if #state.pending>=8 then table.remove(state.pending,1) end
            state.pending[#state.pending+1]={profile=p,ratio=p.ratio}
        end
        deps.report("Animation release / "..name.." / "..marker)
    end
    local function disconnect(track)
        local entry=state.watched[track]; if not entry then return end
        state.watched[track]=nil
        for _,connection in ipairs(entry.connections) do connection:Disconnect() end
    end
    scope:defer(function()
        state.closed=true
        local tracks={}; for track in pairs(state.watched) do tracks[#tracks+1]=track end
        for _,track in ipairs(tracks) do disconnect(track) end
    end)
    function state:step(dt)
        local tracks=deps.tracks(); local present={}
        for _,track in ipairs(tracks) do
            present[track]=true
            local shot=eligible(track)
            local prior=self.watched[track]
            if prior and shot and prior.shot~=shot and track.TimePosition<=(prior.position or 0) then disconnect(track) end
            if shot and not self.watched[track] then
                local entry={connections={},shot=shot,release_time=release_time(track)}; self.watched[track]=entry
                entry.connections[#entry.connections+1]=track:GetMarkerReachedSignal("Release"):Connect(function() release(track,"Release") end)
            end
            local entry=self.watched[track]
            if entry and entry.release_time and type(track.TimePosition)=="number" and track.TimePosition>0 then
                local attributes=deps.attributes()
                if attributes and type(attributes.BaseAnimation)=="string" then
                    local p=profile(track,attributes.BaseAnimation)
                    if track.Speed==0 and track.TimePosition<entry.release_time then
                        p.ceiling=math.max(.25,math.min(.85,track.TimePosition/entry.release_time))
                        p.ratio=math.min(p.ratio,p.ceiling)
                    end
                    local position=track.TimePosition
                    if attributes.Action=="Dunking" and type(track.Speed)=="number" and track.Speed>0 then
                        position=position+track.Speed*math.min(1/60,math.max(0,tonumber(dt) or 0))
                    end
                    if position>=entry.release_time*p.ratio then release(track,"Shot phase") end
                end
            end
            if entry and entry.release_time and type(track.TimePosition)=="number" and track.TimePosition>=entry.release_time then release(track,"Release keyframe") end
            if entry then entry.position=track.TimePosition end
        end
        local gone={}; for track in pairs(self.watched) do if not present[track] then gone[#gone+1]=track end end
        for _,track in ipairs(gone) do disconnect(track) end
    end
    return state
end
function Core.validate_recording(source)
    if type(source)~="table" or type(source.steps)~="table" or #source.steps<1 or #source.steps>64 then return nil,"Recording must contain 1-64 steps" end
    local result={version=1,steps={}}; local total=0
    for _,step in ipairs(source.steps) do
        if type(step)~="table" or type(step.key)~="string" or not step.key:match("^[ZXCVH]$") then return nil,"Unsupported recorded key" end
        local hold=Core.bounded(step.hold,20,5000); local gap=Core.bounded(step.gap,0,5000)
        if not hold or not gap or type(step.shift)~="boolean" then return nil,"Invalid step timing or modifier" end
        total=total+hold+gap; if total>60000 then return nil,"Recording exceeds 60 seconds" end
        result.steps[#result.steps+1]={key=step.key,shift=step.shift,hold=hold,gap=gap}
    end
    return result
end
function Core.validate_module_settings(source,defaults,ranges)
    if type(source)~="table" then return nil,"Settings must be an object" end
    local result={}
    for key,value in pairs(defaults) do
        local incoming=source[key]
        if incoming==nil then incoming=value end
        if type(value)=="number" then
            local range=ranges[key]; incoming=range and Core.bounded(incoming,range[1],range[2])
            if not incoming then return nil,"Invalid setting: "..key end
        elseif type(value)=="string" then
            if type(incoming)~="string" or #incoming>100 then return nil,"Invalid setting: "..key end
        elseif type(value)=="boolean" and type(incoming)~="boolean" then return nil,"Invalid setting: "..key end
        result[key]=incoming
    end
    return result
end

local function create_pivot_modules(ctx)
    local Engine={settings={walk_speed=20,jump_power=50,fly_speed=32,spin_speed=90,fov=85,time=14,range=34,esp_distance=300,
        guard_distance=4,guard_range=25,block_range=12,steal_range=5,steal_key="",spectate="",
        on_ball_speed=20,off_ball_speed=20,guard_target="",jump_key="Space",rebound_range=8,team_check=true},ranges={walk_speed={4,60},jump_power={10,120},fly_speed={4,100},spin_speed={10,360},fov={40,110},time={0,24},range={5,60},esp_distance={30,1000},guard_distance={2,10},guard_range={5,60},block_range={3,18},steal_range={2,8},on_ball_speed={4,60},off_ball_speed={4,60},rebound_range={3,15}},definitions={},recording={version=1,steps={}}}
    local registry=Core.module_registry(ctx.report); Engine.registry=registry
    local players,input,run=ctx.players,ctx.input,ctx.run
    local lighting=game:GetService("Lighting")
    local camera_service=function() return assert(workspace.CurrentCamera,"Camera unavailable") end
    local function rig(who)
        who=who or ctx.player
        local folder=workspace:FindFirstChild("Characters")
        return (folder and folder:FindFirstChild(who.Name)) or who.Character
    end
    local function root(who)
        local model=rig(who); return model and (model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart)
    end
    local function character()
        local model=assert(rig(),"Enter a court before enabling this module")
        return model,assert(model:FindFirstChildOfClass("Humanoid"),"Local Humanoid unavailable"),assert(root(),"Local root unavailable")
    end
    Engine.rig=rig
    local key_codes={LeftShift=0x10,Space=0x20}
    local held={}
    local function emit(key,down)
        if type(keypress)=="function" and type(keyrelease)=="function" then
            local code=key_codes[key] or string.byte(key)
            if down then keypress(code) else keyrelease(code) end
        else game:GetService("VirtualInputManager"):SendKeyEvent(down,Enum.KeyCode[key],false,game) end
    end
    local function release_owned(owner)
        for key,token in pairs(held) do if token==owner then local ok=pcall(emit,key,false); if ok then held[key]=nil end end end
    end
    local function hold(scope,key,down)
        if down then
            if held[key] and held[key]~=scope then return end
            if not held[key] and input:IsKeyDown(Enum.KeyCode[key]) then return end
            if not held[key] then held[key]=scope; emit(key,true) end
        elseif held[key]==scope then emit(key,false); held[key]=nil end
    end
    local function add(id,title,category,description,spec)
        spec.id=id; spec.title=title; spec.category=category; spec.description=description
        registry:register(id,spec); Engine.definitions[#Engine.definitions+1]=spec
    end
    local function property(id,title,object,key,value,conflicts)
        local function apply(scope,_,settings) scope:set(object(),key,type(value)=="function" and value(settings) or value) end
        add(id,title,"World","Restores the original value when disabled",{start=function(scope,s) apply(scope,nil,s) end,step=apply,interval=.1,conflicts=conflicts})
    end
    add("fov","Custom FOV","Camera","Applies after camera updates each rendered frame; restores on disable",{start=function(scope,s)
        local binding="PivotCameraFOV"
        local function apply() scope:set(camera_service(),"FieldOfView",s.fov) end
        apply()
        scope:defer(function() run:UnbindFromRenderStep(binding) end)
        run:BindToRenderStep(binding,Enum.RenderPriority.Last.Value+1,function()
            local ok,err=pcall(apply)
            if not ok then registry:disable("fov"); ctx.report("FOV disabled / "..tostring(err)) end
        end)
    end})
    property("time","Time of day",function() return lighting end,"ClockTime",function(s) return s.time end,{"fullbright"})
    property("shadows","Remove shadows",function() return lighting end,"GlobalShadows",false,{"fullbright"})
    property("fog","Remove distance fog",function() return lighting end,"FogEnd",1000000,{"fullbright"})
    local function fullbright(scope)
        scope:set(lighting,"Brightness",2); scope:set(lighting,"Ambient",Color3.new(1,1,1)); scope:set(lighting,"OutdoorAmbient",Color3.new(1,1,1))
        scope:set(lighting,"GlobalShadows",false); scope:set(lighting,"FogEnd",1000000); scope:set(lighting,"ClockTime",14)
    end
    add("fullbright","Fullbright","World","Lighting, ambient, shadows, fog and daytime",{start=fullbright,step=fullbright,interval=.2,conflicts={"time","shadows","fog"}})
    local function effects(scope)
        for _,parent in ipairs({lighting,camera_service()}) do
            for _,obj in ipairs(parent:GetDescendants()) do if obj:IsA("PostEffect") then scope:set(obj,"Enabled",false) end end
        end
    end
    add("post_effects","Remove post effects","World","Disables blur, bloom, depth of field and color effects locally",{start=effects,step=effects,interval=1})
    local function atmosphere(scope)
        for _,obj in ipairs(lighting:GetChildren()) do if obj:IsA("Atmosphere") then scope:set(obj,"Density",0); scope:set(obj,"Haze",0) end end
    end
    add("atmosphere","Clear atmosphere","World","Restorable atmospheric density and haze",{start=atmosphere,step=atmosphere,interval=1})
    local function clouds(scope)
        local terrain=workspace:FindFirstChildOfClass("Terrain"); if not terrain then return end
        for _,obj in ipairs(terrain:GetChildren()) do if obj:IsA("Clouds") then scope:set(obj,"Cover",0); scope:set(obj,"Density",0) end end
    end
    add("clouds","Clear clouds","World","Local cloud cover and density",{start=clouds,step=clouds,interval=1})
    local function attribute_module(id,title,values,description,conflicts)
        local function apply(scope,state,s)
            local model=character()
            if state and model~=state then error("Character changed; re-enable the module") end
            for key,value in pairs(values) do
                assert(model:GetAttribute(key)~=nil,"Observed attribute unavailable: "..key)
                scope:attribute(model,key,type(value)=="function" and value(s) or value)
            end
            return model
        end
        add(id,title,"Player",description.." / client attributes; game or server may replace them",{start=function(scope,s) return apply(scope,nil,s) end,step=apply,interval=0,conflicts=conflicts})
    end
    attribute_module("speed","Client speed override",{WalkSpeed=function(s) return s.walk_speed end},"Observed WalkSpeed attribute",{"split_speed"})
    attribute_module("stamina","Client stamina override",{Stamina=100},"Observed Stamina attribute")
    attribute_module("movement_lock","Remove client movement lock",{CanMove=true},"Observed CanMove attribute")
    attribute_module("turn_lock","Remove client turn lock",{CanTurn=true},"Observed CanTurn attribute")
    attribute_module("debounce","Remove client debounce",{Debounce=false},"Observed Debounce attribute")
    attribute_module("cold","Remove client cold state",{Cold=false},"Observed Cold attribute")
    attribute_module("sprint","Client sprint state",{Sprinting=true},"Observed Sprinting attribute")
    local function held_ball(model)
        if not model then return nil end
        for _,obj in ipairs(model:GetDescendants()) do
            if obj:IsA("Motor6D") and obj.Name=="Basketball" and obj.Part1 and obj.Part1:IsA("BasePart") then return obj.Part1 end
        end
    end
    local function split_speed(scope,state,s)
        local model=character(); if state and model~=state then error("Character changed") end
        assert(model:GetAttribute("WalkSpeed")~=nil,"WalkSpeed attribute unavailable")
        scope:attribute(model,"WalkSpeed",held_ball(model) and s.on_ball_speed or s.off_ball_speed); return model
    end
    add("split_speed","On / off ball speed","Player","Chooses an observed client speed from the ball joint",{start=function(scope,s) return split_speed(scope,nil,s) end,step=split_speed,interval=.05,conflicts={"speed"}})
    add("jump","Jump power","Player","Standard Humanoid jump property; custom controllers may ignore it",{start=function(scope,s)
        local _,humanoid=character(); scope:set(humanoid,"UseJumpPower",true); scope:set(humanoid,"JumpPower",s.jump_power); return humanoid
    end,step=function(scope,humanoid,s) assert(humanoid.Parent,"Character removed"); scope:set(humanoid,"JumpPower",s.jump_power) end,interval=.1})
    local function noclip(scope,state)
        local model=character(); if state and state~=model then error("Character changed") end
        for _,part in ipairs(model:GetDescendants()) do if part:IsA("BasePart") then scope:set(part,"CanCollide",false) end end
        return model
    end
    add("noclip","Local collision override","Player","Disables collisions on the observed rig; custom physics may override it",{start=function(scope) return noclip(scope) end,step=noclip})
    add("auto_sprint","Hold sprint while moving","Player","Holds LeftShift with W; yields while a combo is running",{start=function(scope)
        character(); scope:defer(function() release_owned(scope) end)
    end,step=function(scope)
        hold(scope,"LeftShift",not ctx.runner.current and not input:GetFocusedTextBox() and input:IsKeyDown(Enum.KeyCode.W))
    end})
    add("spin","Spin","Player","Rotates the observed local root",{start=function(scope)
        local _,humanoid,part=character(); scope:set(humanoid,"AutoRotate",false); return part
    end,step=function(_,part,s,dt) assert(part.Parent,"Character removed"); part.CFrame=part.CFrame*CFrame.Angles(0,math.rad(s.spin_speed)*dt,0) end,conflicts={"fly","guard"}})
    add("fly","Flight","Player","Camera-relative WASD, Space up, Q down",{start=function(scope)
        local _,humanoid,part=character(); scope:set(humanoid,"PlatformStand",true)
        local attachment=Instance.new("Attachment"); attachment.Parent=part; scope:defer(function() attachment:Destroy() end)
        local mover=Instance.new("LinearVelocity"); mover.Attachment0=attachment; mover.RelativeTo=Enum.ActuatorRelativeTo.World; mover.MaxForce=math.huge; mover.VectorVelocity=Vector3.zero; mover.Parent=part
        scope:defer(function() mover:Destroy() end); return {part=part,mover=mover}
    end,step=function(_,state,s)
        assert(state.part.Parent,"Character removed")
        local camera=camera_service(); local vector=Vector3.zero
        if not input:GetFocusedTextBox() then
            if input:IsKeyDown(Enum.KeyCode.W) then vector=vector+camera.CFrame.LookVector end
            if input:IsKeyDown(Enum.KeyCode.S) then vector=vector-camera.CFrame.LookVector end
            if input:IsKeyDown(Enum.KeyCode.D) then vector=vector+camera.CFrame.RightVector end
            if input:IsKeyDown(Enum.KeyCode.A) then vector=vector-camera.CFrame.RightVector end
            if input:IsKeyDown(Enum.KeyCode.Space) then vector=vector+Vector3.yAxis end
            if input:IsKeyDown(Enum.KeyCode.Q) then vector=vector-Vector3.yAxis end
        end
        state.mover.VectorVelocity=vector.Magnitude>0 and vector.Unit*s.fly_speed or Vector3.zero
    end,conflicts={"spin","guard"}})
    local function candidates(kind)
        local list={}
        if kind=="players" then
            for _,who in ipairs(players:GetPlayers()) do if who~=ctx.player then local model=rig(who); if model then list[#list+1]={object=model,label=who.DisplayName or who.Name,who=who} end end end
        elseif kind=="balls" then
            local folder=workspace:FindFirstChild("Basketballs")
            if folder then for _,obj in ipairs(folder:GetChildren()) do if obj:IsA("BasePart") then list[#list+1]={object=obj,label="Ball"} end end end
        elseif kind=="rims" then
            local map=workspace:FindFirstChild("Map")
            if map then for _,obj in ipairs(map:GetDescendants()) do if obj:IsA("BasePart") and obj.Name=="Rim" then list[#list+1]={object=obj,label="Rim"} end end end
        end
        return list
    end
    local function position(obj)
        if obj:IsA("BasePart") then return obj.Position,obj end
        local part=obj:FindFirstChild("HumanoidRootPart") or obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
        return part and part.Position,part
    end
    local function esp(id,title,kind,names)
        local function update(scope,state,s)
            local seen={}; local origin=camera_service().CFrame.Position; local count=0
            for _,item in ipairs(candidates(kind)) do
                local point,part=position(item.object)
                local local_rig=rig(); local team=local_rig and local_rig:GetAttribute("Team")
                local other_team=kind=="players" and item.object:GetAttribute("Team")
                local teammate=s.team_check and team and team~=0 and other_team==team
                if point and part and not teammate and (point-origin).Magnitude<=s.esp_distance and count<20 then
                    count=count+1; seen[item.object]=true
                    local visual=state.items[item.object]
                    if not visual then
                        if names then
                            local billboard=Instance.new("BillboardGui"); billboard.Adornee=part; billboard.AlwaysOnTop=true; billboard.Size=UDim2.fromOffset(180,26); billboard.StudsOffset=Vector3.new(0,3,0); billboard.Parent=state.folder
                            local text=Instance.new("TextLabel"); text.BackgroundTransparency=1; text.Size=UDim2.fromScale(1,1); text.TextColor3=Color3.fromRGB(215,195,232); text.TextSize=12; text.Font=Enum.Font.BuilderSans; text.TextStrokeTransparency=.4; text.Parent=billboard
                            visual={object=billboard,text=text}; state.items[item.object]=visual
                        else
                            local highlight=Instance.new("Highlight"); highlight.Adornee=item.object; highlight.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop; highlight.FillColor=Color3.fromRGB(164,132,190); highlight.OutlineColor=Color3.fromRGB(215,195,232); highlight.FillTransparency=.7; highlight.Parent=state.folder
                            visual={object=highlight}; state.items[item.object]=visual
                        end
                    end
                    if visual.text then visual.text.Text=item.label.." / "..math.floor((point-origin).Magnitude).." studs" end
                end
            end
            for obj,visual in pairs(state.items) do if not seen[obj] then visual.object:Destroy(); state.items[obj]=nil end end
        end
        add(id,title,"Visuals","Distance-limited local overlays; maximum 20 objects",{start=function(scope,s)
            local folder=Instance.new("Folder"); folder.Name="Pivot_"..id; folder.Parent=workspace; scope:defer(function() folder:Destroy() end)
            local state={folder=folder,items={}}; update(scope,state,s); return state
        end,step=update,interval=.25})
    end
    esp("player_esp","Player highlights","players",false)
    esp("player_names","Player names / distances","players",true)
    esp("ball_esp","Ball highlights","balls",false)
    esp("ball_names","Ball distances","balls",true)
    esp("rim_esp","Rim highlights","rims",false)
    local function line(parent)
        local object=Instance.new("Frame"); object.BorderSizePixel=0; object.BackgroundColor3=Color3.fromRGB(193,166,213); object.AnchorPoint=Vector2.new(0,.5); object.Parent=parent; return object
    end
    local function draw_line(object,a,b)
        local d=b-a; object.Position=UDim2.fromOffset(a.X,a.Y); object.Size=UDim2.fromOffset(d.Magnitude,1); object.Rotation=math.deg(math.atan2(d.Y,d.X)); object.Visible=true
    end
    local function nearest_rim(origin)
        local best,distance
        for _,item in ipairs(candidates("rims")) do local d=(item.object.Position-origin).Magnitude; if not distance or d<distance then best=item.object; distance=d end end
        return best,distance
    end
    function Engine:select_defensive_rim()
        local _,_,part=character(); self.defensive_rim=assert(nearest_rim(part.Position),"No map rim found")
        ctx.report("Selected nearest rim as defensive goal")
    end
    local function selected_target(s)
        assert(s.guard_target~="","Enter a defense target username")
        local matches={}
        for _,who in ipairs(players:GetPlayers()) do if who~=ctx.player and who.Name:lower():sub(1,#s.guard_target)==s.guard_target:lower() then matches[#matches+1]=who end end
        assert(#matches==1,"Defense target must match one other player")
        local model=assert(rig(matches[1]),"Target rig unavailable")
        return model,assert(root(matches[1]),"Target root unavailable")
    end
    local function jump_key(s) assert(s.jump_key=="Space" or s.jump_key:match("^[A-Z]$"),"Jump key must be Space or A-Z"); return s.jump_key end
    local function pulse(scope,state,key)
        if ctx.runner.current or input:GetFocusedTextBox() or state.pulse then return end
        hold(scope,key,true); state.pulse=key; state.release_at=os.clock()+.06
    end
    local function finish_pulse(scope,state)
        if state.pulse and os.clock()>=state.release_at then hold(scope,state.pulse,false); state.pulse=nil end
    end
    add("guard","Guard selected player","Defense","WASD steering between your chosen target and chosen defensive rim",{start=function(scope,s)
        character(); local model,part=selected_target(s); assert(Engine.defensive_rim and Engine.defensive_rim.Parent,"Select your defensive rim first")
        scope:defer(function() release_owned(scope) end); return {model=model,part=part}
    end,step=function(scope,state,s)
        local mine=assert(root(),"Local root unavailable"); assert(state.part.Parent and Engine.defensive_rim.Parent,"Target or rim removed")
        local distance=(state.part.Position-mine.Position).Magnitude
        local delta=Engine.defensive_rim.Position-state.part.Position; delta=Vector3.new(delta.X,0,delta.Z)
        local desired=state.part.Position+(delta.Magnitude>.01 and delta.Unit*s.guard_distance or Vector3.zero)
        local direction=desired-mine.Position; direction=Vector3.new(direction.X,0,direction.Z)
        local camera=camera_service(); local forward=camera.CFrame.LookVector; forward=Vector3.new(forward.X,0,forward.Z)
        local right=camera.CFrame.RightVector; right=Vector3.new(right.X,0,right.Z)
        local enabled=distance<=s.guard_range and direction.Magnitude>1 and not input:GetFocusedTextBox() and not ctx.runner.current and forward.Magnitude>.01
        local f=enabled and direction.Unit:Dot(forward.Unit) or 0; local r=enabled and direction.Unit:Dot(right.Unit) or 0
        hold(scope,"W",f>.3); hold(scope,"S",f<-.3); hold(scope,"D",r>.3); hold(scope,"A",r<-.3)
    end,conflicts={"fly","spin"}})
    add("block","Block selected shooter","Defense","Pulses your jump key after a new observed ShotStartTime and InAir state",{start=function(scope,s)
        character(); local model,part=selected_target(s); jump_key(s)
        assert(type(model:GetAttribute("ShotStartTime"))=="number","Target shot timestamp unavailable")
        scope:defer(function() release_owned(scope) end)
        return {model=model,part=part,shot=model:GetAttribute("ShotStartTime"),last=0}
    end,step=function(scope,state,s)
        finish_pulse(scope,state); assert(state.part.Parent,"Defense target removed")
        local shot=state.model:GetAttribute("ShotStartTime")
        if type(shot)=="number" and shot~=state.shot then state.shot=shot; state.pending=os.clock() end
        if state.pending and os.clock()-state.pending<.8 and state.model:GetAttribute("InAir")==true and os.clock()-state.last>1 then
            local mine=assert(root(),"Local root unavailable")
            if (state.part.Position-mine.Position).Magnitude<=s.block_range and not ctx.runner.current then pulse(scope,state,jump_key(s)); state.last=os.clock(); state.pending=nil end
        end
    end,conflicts={"rebound"}})
    add("rebound","Nearby rebound jump","Defense","Pulses jump for a descending MidShot ball nearby; no ball teleporting",{start=function(scope,s)
        character(); jump_key(s); scope:defer(function() release_owned(scope) end); return {last=0,positions={}}
    end,step=function(scope,state,s,dt)
        finish_pulse(scope,state); local mine=assert(root(),"Local root unavailable"); local current={}
        for _,item in ipairs(candidates("balls")) do
            local ball=item.object; local previous=state.positions[ball]; current[ball]=ball.Position
            if previous and dt>0 and ball:GetAttribute("MidShot")==true and os.clock()-state.last>1 then
                local descending=(ball.Position.Y-previous.Y)/dt<-.5
                local height=ball.Position.Y-mine.Position.Y
                if descending and height>2 and height<10 and (ball.Position-mine.Position).Magnitude<=s.rebound_range and not ctx.runner.current then
                    pulse(scope,state,jump_key(s)); state.last=os.clock()
                end
            end
        end
        state.positions=current
    end,interval=.03,conflicts={"block"}})
    add("hoop_tracer","Nearest hoop tracer","Visuals","Projects a line from the screen bottom to the nearest rim",{start=function(scope)
        local object=line(ctx.gui); scope:defer(function() object:Destroy() end); return object
    end,step=function(_,object)
        local camera=camera_service(); local part=root(); local rim=nearest_rim(part and part.Position or camera.CFrame.Position)
        object.Visible=false; if not rim then return end
        local point,visible=camera:WorldToViewportPoint(rim.Position)
        if visible then draw_line(object,Vector2.new(camera.ViewportSize.X/2,camera.ViewportSize.Y-18),Vector2.new(point.X,point.Y)) end
    end})
    add("range_circle","Shot range circle","Visuals","Projects a circle in studs around the local root",{start=function(scope)
        character(); local folder=Instance.new("Folder"); folder.Parent=ctx.gui; scope:defer(function() folder:Destroy() end)
        local lines={}; for i=1,40 do lines[i]=line(folder) end; return lines
    end,step=function(_,lines,s)
        local part=assert(root(),"Local root unavailable"); local camera=camera_service(); local center=part.Position-Vector3.new(0,2.8,0)
        for i=1,40 do
            local a=(i-1)*math.pi*2/40; local b=i*math.pi*2/40
            local pa,va=camera:WorldToViewportPoint(center+Vector3.new(math.cos(a)*s.range,0,math.sin(a)*s.range))
            local pb,vb=camera:WorldToViewportPoint(center+Vector3.new(math.cos(b)*s.range,0,math.sin(b)*s.range))
            lines[i].Visible=false; if va and vb then draw_line(lines[i],Vector2.new(pa.X,pa.Y),Vector2.new(pb.X,pb.Y)) end
        end
    end})
    add("spectate","Spectate player","Camera","Enter an exact username or unique username prefix",{start=function(scope,s)
        assert(s.spectate~="","Enter a target username first")
        local matches={}; for _,who in ipairs(players:GetPlayers()) do if who.Name:lower():sub(1,#s.spectate)==s.spectate:lower() then matches[#matches+1]=who end end
        assert(#matches==1,"Target must match exactly one player")
        local model=assert(rig(matches[1]),"Target rig unavailable"); local subject=model:FindFirstChild("Head") or model:FindFirstChildOfClass("Humanoid")
        assert(subject,"Target camera subject unavailable"); local camera=camera_service(); scope:set(camera,"CameraSubject",subject); scope:set(camera,"CameraType",Enum.CameraType.Custom)
        return subject
    end,step=function(_,subject) assert(subject.Parent,"Spectate target left") end,interval=.5})
    local function shooting_adapter()
        local scripts=assert(ctx.player:FindFirstChild("PlayerScripts"),"PlayerScripts unavailable")
        local aero=assert(scripts:FindFirstChild("Aero"),"Game client not loaded")
        local controllers=assert(aero:FindFirstChild("Controllers"),"Game controllers unavailable")
        local modules=assert(aero:FindFirstChild("Modules"),"Game modules unavailable")
        local components=assert(modules:FindFirstChild("Components"),"Input components unavailable")
        local input_module=assert(components:FindFirstChild("Input"),"Input component unavailable")
        local player_module=assert(controllers:FindFirstChild("Player"),"Player controller unavailable")
        local keyboard_module=assert(input_module:FindFirstChild("Keyboard"),"Keyboard component unavailable")
        -- These are the same cached, initialized modules identified in the live capture.
        local controller=require(player_module); local keyboard=require(keyboard_module)
        assert(type(controller.GetCharacter)=="function" and type(keyboard.IsActionDown)=="function","Game shooting API changed")
        local services=keyboard.Services
        local shoot=services and services.InputService and services.InputService.Shoot
        assert(shoot and type(shoot.Fire)=="function","Game shoot endpoint unavailable")
        local function current() return controller:GetCharacter() end
        local value=assert(current(),"Enter a court first")
        local animator=value.Animation and value.Animation.Animator
        assert(animator,"Character animator unavailable")
        local devices={{component=keyboard,actions={"Shoot","Jump"}}}
        local gamepad_module=input_module:FindFirstChild("Gamepad")
        if gamepad_module then
            local ok,gamepad=pcall(require,gamepad_module)
            if ok and type(gamepad.IsActionDown)=="function" then devices[#devices+1]={component=gamepad,actions={"Shoot","JumpClutch"}} end
        end
        return {
            attributes=function() local c=current(); return c and c.data and c.data.Attributes end,
            tracks=function() assert(current()==value,"Character changed"); return animator:GetPlayingAnimationTracks() end,
            held=function()
                for _,device in ipairs(devices) do
                    for _,action in ipairs(device.actions) do
                        local ok,down=pcall(device.component.IsActionDown,device.component,action)
                        if ok and down then return true end
                    end
                end
                return false
            end,
            release=function() shoot:Fire({Shoot=false}) end,
            feedback=function(scope,callback)
                local service=services.InterfaceService
                local signal=service and service.ShowFeedback
                if not signal or type(signal.Connect)~="function" then return false end
                local connection=signal:Connect(function(model,_,timing)
                    if model==value.data.model then callback(tonumber(timing)) end
                end)
                scope:defer(function() connection:Disconnect() end); return true
            end,
        }
    end
    Engine.release_profiles={}
    add("meter_release","Auto Green","Shooting","Earlier animation release with automatic Early/Late correction. Keyboard/controller. Live green timing remains experimental.",{start=function(scope)
        character()
        local adapter=shooting_adapter()
        adapter.paused=function() return input:GetFocusedTextBox()~=nil or ctx.runner.current~=nil end
        adapter.report=ctx.report
        adapter.failed=function(err) registry:disable("meter_release"); ctx.report("Auto release stopped / "..err) end
        adapter.profiles=Engine.release_profiles
        local state=Core.animation_release(scope,adapter)
        local feedback=adapter.feedback(scope,function(code) state:feedback(code) end)
        state:step(); assert(not state.error,state.error); ctx.report(feedback and "Auto release on / automatic feedback correction" or "Auto release on / feedback correction unavailable")
        return state
    end,step=function(_,state,_,dt) state:step(dt) end})
    local function feedback_hook(scope)
        local model=character(); local part=model:FindFirstChild("HumanoidRootPart"); local feedback=part and part:FindFirstChild("ShotFeedback"); local value=feedback and feedback:FindFirstChild("ReleaseTiming")
        assert(value and value:IsA("TextLabel"),"Observed shot-feedback label unavailable")
        local connection=value:GetPropertyChangedSignal("Text"):Connect(function() ctx.report("Game feedback / "..value.Text) end)
        scope:defer(function() connection:Disconnect() end)
    end
    add("shot_feedback","Live shot feedback","Shooting","Reads the observed ReleaseTiming label",{start=feedback_hook})
    add("hide_meters","Hide local meter graphics","Visuals","Restores the local meter Enabled states on disable",{start=function(scope)
        local model=character(); for _,obj in ipairs(model:GetDescendants()) do if obj:IsA("BillboardGui") and obj.Name:find("Meter",1,true) then scope:set(obj,"Enabled",false) end end
    end})
    Engine.emit=emit; Engine.held=held
    function Engine:stop()
        self.registry:stop_all(); for _,owner in pairs(held) do release_owned(owner) end
        self.capturing=false; self.pending_move=nil
        if next(held) then ctx.report("Input release pending / press F8 to retry") end
        return next(held)==nil
    end
    function Engine:close() self:stop(); self.registry:close() end
    function Engine:stop_controls()
        for _,id in ipairs({"auto_sprint","guard","block","rebound","meter_release","fly","spin"}) do self.registry:disable(id) end
        for _,owner in pairs(held) do release_owned(owner) end
        self.capturing=false
    end
    local original_start=ctx.runner.start
    function ctx.runner:start(action,done)
        for _,owner in pairs(held) do release_owned(owner) end
        if next(held) then return false,"Module key release pending; press F8" end
        return original_start(self,action,done)
    end
    local last_rig=rig()
    ctx.connect(run.Heartbeat,function(dt)
        local current=rig(); if current~=last_rig then Engine:stop(); last_rig=current end
        registry:step(dt)
    end)
    ctx.connect(input.WindowFocusReleased,function() Engine:stop() end)
    ctx.connect(input.TextBoxFocused,function() Engine:stop_controls() end)
    ctx.connect(input.InputBegan,function(event) if event.KeyCode==Enum.KeyCode.F8 then Engine:stop() end end)
    return Engine
end

Core.create_pivot_modules=create_pivot_modules
if C4_HUB_TEST then return Core end
local PivotUI,PivotModules

local players, input = game:GetService("Players"), game:GetService("UserInputService")
local run_service, http = game:GetService("RunService"), game:GetService("HttpService")
local player = assert(players.LocalPlayer, "Run C4 Hub on the client.")
local parent = player:WaitForChild("PlayerGui")
local previous = parent:FindFirstChild("C4PracticalHub")
if previous then
    local event = previous:FindFirstChild("Stop")
    if not event then error("Close the existing C4PracticalHub first.") end
    event:Fire()
    local deadline=os.clock()+.5
    while previous.Parent and os.clock()<deadline do task.wait() end
    if previous.Parent then error("Previous hub could not release its keys. Press F8 first.") end
end
local config = Core.copy(defaults)
local alive, capture, capture_start = true, false, nil
local connections, samples, history, logs, profiles = {}, {}, {}, {}, {}
local press, release = keypress, keyrelease
local native = type(press)=="function" and type(release)=="function"
local virtual; pcall(function() virtual=game:GetService("VirtualInputManager") end)
local backend = native and "Native keys" or (virtual and "VirtualInputManager (unverified)" or "Unavailable")
local file = "c4_practical_hub_v2.json"
local disk_read = type(readfile)=="function"
local disk_write = type(writefile)=="function"
local restored = "Session profiles"
if disk_read then
    local ok, data = pcall(function()
        local raw=readfile(file); assert(#raw<=65536, "Profile file is too large."); return http:JSONDecode(raw)
    end)
    if ok and type(data)=="table" and data.version==2 and type(data.profiles)=="table" then
        for index=1,3 do profiles[index]=Core.validate(data.profiles[tostring(index)]) end
        if profiles[1] then config=Core.copy(profiles[1]) end
        restored="Saved profiles restored; slot 1 is the startup profile"
    end
end
local runner = Core.runner({
    now=os.clock, frame=function() run_service.Heartbeat:Wait() end, spawn=task.spawn,
    down=function(key) return input:IsKeyDown(Enum.KeyCode[key]) end,
    send=function(key, down)
        if native then
            local code=key=="LeftShift" and 0x10 or string.byte(key)
            if down then press(code) else release(code) end
        elseif virtual then virtual:SendKeyEvent(down, Enum.KeyCode[key], false, game)
        else error("Keyboard simulation is unavailable in this runtime.") end
    end,
})
local function connect(signal, callback)
    local connection=signal:Connect(callback); connections[#connections+1]=connection; return connection
end
local function make(class, properties, parent_object)
    local object=Instance.new(class)
    for key,value in pairs(properties) do object[key]=value end
    object.Parent=parent_object; return object
end
local bg, card, accent = Color3.fromRGB(15,19,27), Color3.fromRGB(26,33,45), Color3.fromRGB(234,139,65)
local white, muted = Color3.fromRGB(233,239,249), Color3.fromRGB(151,169,191)
local gui=make("ScreenGui", {Name="C4PracticalHub",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=100,ZIndexBehavior=Enum.ZIndexBehavior.Sibling},parent)
local stop=make("BindableEvent",{Name="Stop"},gui)
local window=make("Frame",{Size=UDim2.fromOffset(600,620),Position=UDim2.fromScale(.5,.5),AnchorPoint=Vector2.new(.5,.5),BackgroundColor3=bg,BorderSizePixel=0},gui)
make("UICorner",{CornerRadius=UDim.new(0,14)},window)
make("UIStroke",{Color=Color3.fromRGB(49,61,79),Thickness=1},window)
local scale=make("UIScale",{Scale=1},window)
local function label(owner, value, height, color)
    return make("TextLabel",{Size=UDim2.new(1,-8,0,height or 28),BackgroundTransparency=1,Text=value,TextColor3=color or white,Font=Enum.Font.BuilderSans,TextSize=14,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left},owner)
end
local function box(owner, value, height)
    local object=make("TextBox",{Size=UDim2.new(1,-8,0,height or 34),BackgroundColor3=card,BorderSizePixel=0,Text=value,TextColor3=white,Font=Enum.Font.RobotoMono,TextSize=15,ClearTextOnFocus=false,TextWrapped=true},owner)
    make("UICorner",{CornerRadius=UDim.new(0,6)},object); return object
end
local function button(owner,value,callback)
    local object=make("TextButton",{Size=UDim2.new(1,-8,0,34),BackgroundColor3=card,BorderSizePixel=0,Text=value,TextColor3=accent,Font=Enum.Font.BuilderSansBold,TextSize=14,AutoButtonColor=true},owner)
    make("UICorner",{CornerRadius=UDim.new(0,6)},object)
    connect(object.Activated,callback); return object
end
local header=label(window,"C4  /  PRACTICAL BASKETBALL                                      v2",36)
header.Position=UDim2.fromOffset(20,10); header.Size=UDim2.new(1,-110,0,36); header.Active=true
local subtitle=label(window,"SHOT LAB     /     COMBO EDITOR     /     PROFILES",26,muted)
subtitle.Position=UDim2.fromOffset(20,45)
local close=button(window,"X",function() stop:Fire() end)
close.Size=UDim2.fromOffset(36,32); close.Position=UDim2.new(1,-52,0,12)
local tabs=make("Frame",{Position=UDim2.fromOffset(16,82),Size=UDim2.new(1,-32,0,36),BackgroundTransparency=1},window)
make("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,8),SortOrder=Enum.SortOrder.LayoutOrder},tabs)
local pages, tab_buttons = {}, {}
for index,name in ipairs({"Shot Lab","Combos","Profiles","Diagnostics"}) do
    local page=make("ScrollingFrame",{Position=UDim2.fromOffset(20,132),Size=UDim2.new(1,-40,1,-236),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=4,ScrollBarImageColor3=accent,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y,Visible=index==1},window)
    make("UIListLayout",{Padding=UDim.new(0,8),SortOrder=Enum.SortOrder.LayoutOrder},page)
    make("UIPadding",{PaddingBottom=UDim.new(0,12)},page)
    pages[name]=page
    local tab=button(tabs,name,function()
        for key,object in pairs(pages) do object.Visible=key==name end
        for key,object in pairs(tab_buttons) do object.BackgroundColor3=key==name and Color3.fromRGB(61,47,36) or card end
    end)
    tab.Size=UDim2.new(.25,-6,1,0); tab.LayoutOrder=index; tab_buttons[name]=tab
end
tab_buttons["Shot Lab"].BackgroundColor3=Color3.fromRGB(61,47,36)
local status=label(window,"Ready / "..restored,44,muted)
status.Position=UDim2.new(0,20,1,-94); status.Size=UDim2.new(1,-40,0,44)
local cancel_button
local function report(message)
    if not alive then return end
    message=tostring(message); status.Text=message
    logs[#logs+1]=os.date("%H:%M:%S").."  "..message
    if #logs>30 then table.remove(logs,1) end
end
local function protect(callback)
    return function()
        local ok,err=pcall(callback); if not ok then report(err) end
    end
end
local controls={}
local function sync()
    for name,object in pairs(controls) do object.Text=tostring(config[name]) end
end
local function commit()
    local candidate=Core.copy(config)
    for name,object in pairs(controls) do candidate[name]=object.Text end
    local validated,err=Core.validate(candidate)
    if not validated then report(err); return false end
    config=validated; sync(); return true
end
local function field(page,name,caption,height)
    label(page,caption,26,muted); local object=box(page,tostring(config[name]),height)
    controls[name]=object
    connect(object.FocusLost,function() commit() end); return object
end
local function cancel(reason)
    capture=false; capture_start=nil
    local released=runner:cancel()
    report(released and (reason or "Cancelled; keys released.") or "Release failed. Press F8 again and tap affected keys.")
    return released
end
cancel_button=button(window,"F8  /  CANCEL ALL INPUT",function() cancel() end)
cancel_button.Position=UDim2.new(0,20,1,-44); cancel_button.Size=UDim2.new(1,-40,0,30)
local function launch(action)
    if input:GetFocusedTextBox() then return end
    if capture then report("Stop manual capture before running inputs."); return end
    if not commit() then return end
    local ok,err=runner:start(action,function(success,result)
        report(success and (result or "Complete.") or ("Action failed: "..tostring(result)))
    end)
    if not ok then report(err) end
end
local shot_page=pages["Shot Lab"]
label(shot_page,"TIMED RELEASE",28,accent)
label(shot_page,"Calibrate against live shot feedback. Moving shots, stamina, and animations can change timing.",44,muted)
field(shot_page,"hold","Base hold duration / 50-2000 ms")
field(shot_page,"lead","Release lead / -250 to +250 ms; positive releases sooner")
local history_label
local function refresh_history()
    local lines={"Recent shots / actual held time / feedback"}
    for index=math.max(1,#history-5),#history do
        local item=history[index]
        lines[#lines+1]=string.format("%d. target %d ms / actual %.1f ms / %s",index,item.target,item.actual,item.feedback or "unrated")
    end
    history_label.Text=table.concat(lines,"\n")
end
local function shoot()
    launch(function(token)
        local target=math.max(50,math.min(2000,config.hold-config.lead))
        report("Shot active / target "..target.." ms")
        local ok,actual=runner:step({"E"},target,token)
        if not ok then return end
        history[#history+1]={target=target,actual=actual}
        if #history>50 then table.remove(history,1) end
        refresh_history(); return string.format("Released / %.1f ms actual / rate the shot below.",actual)
    end)
end
button(shot_page,"SHOOT / configured hotkey",shoot)
local function feedback(kind)
    if runner.current or not commit() then return end
    local item=history[#history]
    if not item or item.feedback then report("Run a new shot before rating."); return end
    item.feedback=kind
    if kind~="Green" then
        local direction=kind=="Early" and 10 or -10
        config.hold=math.max(50,math.min(2000,item.target+config.lead+direction)); sync()
    end
    refresh_history(); report(kind=="Green" and "Marked green; timing kept." or "Timing adjusted by 10 ms; test again.")
end
button(shot_page,"EARLY / hold 10 ms longer",function() feedback("Early") end)
button(shot_page,"GREEN / keep this timing",function() feedback("Green") end)
button(shot_page,"LATE / release 10 ms sooner",function() feedback("Late") end)
button(shot_page,"TOGGLE MANUAL CAPTURE / hold and release E",function()
    if runner.current then report("Cancel the current action first."); return end
    capture=not capture; capture_start=nil
    report(capture and "Capture armed. Hold/release E manually; capture successful releases, then apply median." or "Capture stopped.")
end)
button(shot_page,"APPLY MEDIAN OF CAPTURED RELEASES",function()
    if runner.current or not commit() then return end
    local median=Core.median(samples)
    if not median then report("Capture manual releases first."); return end
    config.hold=math.max(50,math.min(2000,math.floor(median+.5))); config.lead=0; sync()
    capture=false; capture_start=nil; report("Applied "..#samples.." samples / "..config.hold.." ms median.")
end)
button(shot_page,"CLEAR CAPTURE SAMPLES",function() samples={}; capture_start=nil; report("Capture samples cleared.") end)
history_label=label(shot_page,"Recent shots / none yet",142,muted)
local combo_page=pages.Combos
label(combo_page,"COMBO EDITOR",28,accent)
label(combo_page,"Space-separated inputs: Z X C V H. SHIFT+C adds sprint. Z:40/110 sets a step's hold/gap in ms. Maximum 24 steps.",58,muted)
field(combo_page,"macro","Sequence",70)
field(combo_page,"tap","Default key hold / 20-250 ms")
field(combo_page,"gap","Default gap / 20-500 ms")
button(combo_page,"VALIDATE SEQUENCE",function()
    if commit() then local steps=Core.parse(config.macro,config.tap,config.gap); report("Valid / "..#steps.." steps.") end
end)
local function combo()
    launch(function(token)
        local steps,err=Core.parse(config.macro,config.tap,config.gap); if not steps then error(err) end
        for index,step in ipairs(steps) do
            report("Combo / "..index.." of "..#steps)
            if not runner:step(step.keys,step.hold,token) then return end
            if index<#steps and not runner:wait(step.gap,token) then return end
        end
        return "Combo complete / "..#steps.." steps."
    end)
end
button(combo_page,"RUN SEQUENCE / configured hotkey",combo)
local profile_page=pages.Profiles
label(profile_page,"PROFILES + HOTKEYS",28,accent)
label(profile_page,"Three slots. Save explicitly; slot 1 loads at startup. F8 always cancels. Profiles persist when file access is available.",52,muted)
local slot=1
local slot_button
slot_button=button(profile_page,"SLOT 1 / click to cycle",function() slot=slot%3+1; slot_button.Text="SLOT "..slot.." / click to cycle" end)
field(profile_page,"shot","Shot hotkey / F1-F12 or RightShift")
field(profile_page,"combo","Combo hotkey / unique; F8 is reserved")
field(profile_page,"menu","Menu hotkey / unique; F8 is reserved")
button(profile_page,"SAVE SELECTED SLOT",protect(function()
    if not commit() then return end
    profiles[slot]=Core.copy(config)
    if not disk_write then report("Slot "..slot.." saved for this session; disk access unavailable."); return end
    local data={version=2,profiles={}}
    for index=1,3 do if profiles[index] then data.profiles[tostring(index)]=profiles[index] end end
    writefile(file,http:JSONEncode(data)); report("Saved slot "..slot.." to "..file)
end))
button(profile_page,"LOAD SELECTED SLOT",function()
    if not profiles[slot] then report("This slot is empty."); return end
    if not cancel("Loading profile...") then return end
    config=Core.copy(profiles[slot]); sync(); report("Loaded slot "..slot)
end)
button(profile_page,"RESTORE DEFAULT CONTROLS",function()
    if cancel() then config=Core.copy(defaults); sync(); report("Default controls restored; saved slots kept.") end
end)
local diagnostic_page=pages.Diagnostics
label(diagnostic_page,"RUNTIME",28,accent)
local diagnostic=label(diagnostic_page,"",156,muted)
button(diagnostic_page,"COPY SHOT HISTORY + LOG",protect(function()
    assert(type(setclipboard)=="function","Clipboard API is unavailable.")
    setclipboard(http:JSONEncode({version=2,place=game.PlaceId,shots=history,log=logs,samples=samples}))
    report("Session report copied.")
end))
button(diagnostic_page,"RETRY KEY RELEASE",function() cancel() end)
local log_label=label(diagnostic_page,"",300,muted)
local function unload()
    if not alive then return end
    if PivotModules and not PivotModules:stop() then report("Input release pending / F8 to retry"); return end
    if PivotModules then PivotModules:close() end
    if not cancel("Unloading...") then report("Unload paused until held keys are released. Press F8, then X."); return end
    alive=false; runner.closed=true
    for _,connection in ipairs(connections) do connection:Disconnect() end
    gui:Destroy()
end
connect(stop.Event,unload)
connect(gui.Destroying,function()
    if PivotModules then PivotModules:close() end
    if not alive then return end
    runner:cancel(); runner.closed=true; alive=false
    for _,connection in ipairs(connections) do connection:Disconnect() end
end)
connect(player.CharacterRemoving,function() cancel("Character removed; input cancelled.") end)
connect(input.WindowFocusReleased,function() cancel("Window lost focus; input cancelled.") end)
connect(input.TextBoxFocused,function() cancel("Editing controls; input cancelled.") end)
connect(input.InputBegan,function(event,processed)
    local key=event.KeyCode.Name
    if key=="F8" then cancel(); return end
    if processed or input:GetFocusedTextBox() then return end
    if key==config.menu then window.Visible=not window.Visible
    elseif key==config.shot then shoot()
    elseif key==config.combo then combo()
    elseif capture and key=="E" and not runner.current and not capture_start then capture_start=os.clock() end
end)
connect(input.InputEnded,function(event)
    if event.KeyCode==Enum.KeyCode.E and capture_start then
        local duration=(os.clock()-capture_start)*1000; capture_start=nil
        if capture and duration>=50 and duration<=2000 then
            samples[#samples+1]=duration; if #samples>20 then table.remove(samples,1) end
            report(string.format("Captured %.1f ms / %d samples / median %.1f ms",duration,#samples,Core.median(samples)))
        else report("Capture ignored / duration outside 50-2000 ms.") end
    end
end)
local camera_connection, drag, origin, start_position
local function clamp_window()
    local camera=workspace.CurrentCamera; if not camera then return end
    local view=camera.ViewportSize
    scale.Scale=math.max(.1,math.min(1,(view.X-24)/600,(view.Y-60)/620))
    local half_x,half_y=300*scale.Scale,310*scale.Scale
    local position=window.Position
    local x=math.max(half_x+4,math.min(view.X-half_x-4,position.X.Scale*view.X+position.X.Offset))
    local y=math.max(half_y+4,math.min(view.Y-half_y-40,position.Y.Scale*view.Y+position.Y.Offset))
    window.Position=UDim2.fromOffset(x,y)
end
local function watch_camera()
    if camera_connection then camera_connection:Disconnect() end
    local camera=workspace.CurrentCamera
    if camera then camera_connection=connect(camera:GetPropertyChangedSignal("ViewportSize"),clamp_window) end
    clamp_window()
end
watch_camera(); connect(workspace:GetPropertyChangedSignal("CurrentCamera"),watch_camera)
connect(header.InputBegan,function(event)
    if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch then
        drag=event; origin=event.Position; start_position=window.Position
    end
end)
connect(input.InputChanged,function(event)
    if not drag then return end
    local mouse=drag.UserInputType==Enum.UserInputType.MouseButton1 and event.UserInputType==Enum.UserInputType.MouseMovement
    if event==drag or mouse then
        local delta=event.Position-origin
        window.Position=UDim2.new(start_position.X.Scale,start_position.X.Offset+delta.X,start_position.Y.Scale,start_position.Y.Offset+delta.Y)
    end
end)
connect(input.InputEnded,function(event) if event==drag then drag=nil; clamp_window() end end)
local elapsed,frames=0,0
connect(run_service.Heartbeat,function(dt)
    elapsed=elapsed+dt; frames=frames+1
    if elapsed<.5 then return end
    diagnostic.Text=string.format("Backend: %s\nDisk read/write: %s / %s\nPlace: %s\nFrame rate: %.0f fps\nAction: %s / capture: %s\nHotkeys: %s shot / %s combo / %s menu / F8 cancel",backend,tostring(disk_read),tostring(disk_write),tostring(game.PlaceId),frames/elapsed,runner.current and "running" or "idle",capture and "armed" or "off",config.shot,config.combo,config.menu)
    local lines={}; for index=math.max(1,#logs-9),#logs do lines[#lines+1]=logs[index] end
    log_label.Text=table.concat(lines,"\n"); elapsed=0; frames=0
end)
report("Ready / "..restored)

-- language: Lua, file: pivot_visuals.lua, runtime: Roblox client, target: C4 Practical Hub v2
do
    local players=game:GetService("Players")
    local player=players.LocalPlayer
    local gui=assert(player:WaitForChild("PlayerGui"):FindFirstChild("C4PracticalHub"),"Start Pivot first.")
    assert(not gui:FindFirstChild("CourtsideVisuals"),"Use the complete v4 file to replace the Courtside layout.")
    if gui:FindFirstChild("CompactVisuals") then return end
    local input=game:GetService("UserInputService")
    local run=game:GetService("RunService")
    local connections={}
    local function on(signal,callback) local c=signal:Connect(callback); connections[#connections+1]=c; return c end
    local function make(class,props,parent)
        local object=Instance.new(class); for k,v in pairs(props) do object[k]=v end
        object.Parent=parent; return object
    end
    local function rgb(r,g,b) return Color3.fromRGB(r,g,b) end
    local theme={base=rgb(20,21,24),rail=rgb(20,21,24),panel=rgb(28,30,34),input=rgb(24,26,30),line=rgb(43,46,52),
        text=rgb(230,232,237),muted=rgb(145,151,163),accent=rgb(192,201,220),selected=rgb(39,44,54),green=rgb(159,190,170)}
    local function corner(object,n)
        local c=object:FindFirstChildWhichIsA("UICorner") or make("UICorner",{},object); c.CornerRadius=UDim.new(0,n)
    end
    local function border(object,color)
        local c=object:FindFirstChildWhichIsA("UIStroke") or make("UIStroke",{},object)
        c.Color=color or theme.line; c.Thickness=1; c.ApplyStrokeMode=Enum.ApplyStrokeMode.Border; return c
    end
    local function frame(parent,x,y,w,h,color)
        return make("Frame",{Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),BackgroundColor3=color or theme.panel,BorderSizePixel=0},parent)
    end
    local function animate(object,properties)
        local service=game:GetService("TweenService")
        if service then
            local ok=pcall(function() service:Create(object,TweenInfo.new(.18,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),properties):Play() end)
            if ok then return end
        end
        for key,value in pairs(properties) do object[key]=value end
    end
    local function icon(parent,kind,x,y,color)
        local root=frame(parent,x,y,20,20); root.Name="LineIcon"; root.BackgroundTransparency=1
        local function line(a,b,c,d)
            local dx,dy=c-a,d-b
            local part=frame(root,(a+c)/2,(b+d)/2,math.sqrt(dx*dx+dy*dy),1.4,color)
            part.AnchorPoint=Vector2.new(.5,.5); part.Rotation=math.deg(math.atan2(dy,dx)); corner(part,1)
        end
        local function ring(a,b,size)
            local part=frame(root,a,b,size,size); part.BackgroundTransparency=1; corner(part,size/2); border(part,color)
        end
        if kind=="Diagnostics" then
            line(2,9,10,2); line(10,2,18,9); line(4,8,4,17); line(4,17,16,17); line(16,17,16,8); line(8,17,8,12); line(8,12,12,12); line(12,12,12,17)
        elseif kind=="Shot Lab" then
            ring(4,4,12); ring(8,8,4); line(10,1,10,4); line(10,16,10,19); line(1,10,4,10); line(16,10,19,10)
        elseif kind=="Combos" then
            line(5,5,15,5); line(15,5,15,15); line(15,15,5,15)
            for _,point in ipairs({{3,3},{13,3},{3,13}}) do local node=frame(root,point[1],point[2],4,4,color); corner(node,1) end
        elseif kind=="Profiles" then
            line(3,5,17,5); line(3,10,17,10); line(3,15,17,15)
            for _,point in ipairs({{7,5},{13,10},{6,15}}) do local node=frame(root,point[1]-1,point[2]-2,3,4,color); corner(node,1) end
        elseif kind=="Search" then ring(3,3,10); line(12,12,17,17)
        else
            for _,point in ipairs({{3,3},{12,3},{3,12},{12,12}}) do local node=frame(root,point[1],point[2],5,5); node.BackgroundTransparency=1; border(node,color); corner(node,1) end
        end
        return root
    end
    local function icon_color(root,color)
        for _,part in ipairs(root:GetDescendants()) do if part:IsA("Frame") then part.BackgroundColor3=color elseif part:IsA("UIStroke") then part.Color=color end end
    end
    local function label(parent,value,x,y,w,h,size,color)
        return make("TextLabel",{Text=value,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),BackgroundTransparency=1,
            TextColor3=color or theme.text,Font=Enum.Font.BuilderSans,TextSize=size or 12,TextXAlignment=Enum.TextXAlignment.Left,
            TextYAlignment=Enum.TextYAlignment.Center,TextWrapped=true,BorderSizePixel=0},parent)
    end
    local function small_button(parent,value,callback)
        local b=make("TextButton",{Text=value,Size=UDim2.fromOffset(110,28),BackgroundColor3=theme.panel,BorderSizePixel=0,
            TextColor3=theme.text,TextSize=11,Font=Enum.Font.BuilderSans,AutoButtonColor=false},parent)
        corner(b,5)
        on(b.Activated,callback)
        on(b.MouseEnter,function() if not b:GetAttribute("RailItem") then animate(b,{BackgroundColor3=theme.selected}) end end)
        on(b.MouseLeave,function() if not b:GetAttribute("RailItem") then animate(b,{BackgroundColor3=theme.panel}) end end)
        return b
    end
    local shell=gui:FindFirstChildWhichIsA("Frame")
    local header,subtitle,status,close,cancel,nav
    local pages,tabs,fields,rows,actions={},{},{},{},{}
    local names={["TIMED RELEASE"]="Shot Lab",["COMBO EDITOR"]="Combos",["PROFILES + HOTKEYS"]="Profiles",RUNTIME="Diagnostics"}
    for _,obj in ipairs(shell:GetChildren()) do
        if obj:IsA("TextLabel") then
            if obj.Text:find("C4  /",1,true) then header=obj elseif obj.Text:find("SHOT LAB",1,true) then subtitle=obj else status=obj end
        elseif obj:IsA("TextButton") then if obj.Text=="X" then close=obj else cancel=obj end
        elseif obj:IsA("ScrollingFrame") then
            for _,child in ipairs(obj:GetChildren()) do if child:IsA("TextLabel") and names[child.Text] then pages[names[child.Text]]=obj end end
        elseif obj:IsA("Frame") then nav=obj end
    end
    assert(header and status and pages.Diagnostics,"Unsupported Pivot layout.")
    make("Folder",{Name="CompactVisuals"},gui)
    shell.BackgroundColor3=theme.base; corner(shell,9); border(shell)
    header.Text=""; header.Position=UDim2.fromOffset(68,0); header.Size=UDim2.new(1,-112,0,42)
    subtitle.Visible=false
    nav.Visible=false
    local rail=frame(shell,0,0,68,548,theme.rail); rail.ZIndex=0; rail.Visible=false; corner(rail,0)
    local rail_line=frame(shell,20,97,660,1,theme.line)
    local top_line=frame(shell,20,54,660,1,theme.line)
    local logo=label(shell,"Pivot",20,12,100,28,19,theme.text); logo.Font=Enum.Font.BuilderSansBold; logo.TextXAlignment=Enum.TextXAlignment.Left
    local heading=label(shell,"Practical Basketball",94,14,240,26,11,theme.muted); heading.Font=Enum.Font.BuilderSansMedium
    close.BackgroundColor3=theme.rail; close.TextColor3=theme.muted; close.TextSize=12; corner(close,4)
    local search=make("TextBox",{Text="",PlaceholderText="Find a control...",PlaceholderColor3=theme.muted,Position=UDim2.fromOffset(484,10),Size=UDim2.fromOffset(166,23),
        ClearTextOnFocus=false,TextSize=11,TextColor3=theme.text,BackgroundColor3=theme.input,BorderSizePixel=0,Font=Enum.Font.BuilderSans},shell)
    corner(search,4)
    search.TextXAlignment=Enum.TextXAlignment.Left
    make("UIPadding",{PaddingLeft=UDim.new(0,26),PaddingRight=UDim.new(0,8)},search)
    local search_symbol=icon(shell,"Search",487,12,theme.muted)
    local aliases={ ["SHOOT / configured hotkey"]="Shoot",["EARLY / hold 10 ms longer"]="Early  +10 ms",["GREEN / keep this timing"]="Green",["LATE / release 10 ms sooner"]="Late  -10 ms",
        ["TOGGLE MANUAL CAPTURE / hold and release E"]="Capture manual timing",["APPLY MEDIAN OF CAPTURED RELEASES"]="Use captured median",["CLEAR CAPTURE SAMPLES"]="Clear samples",
        ["VALIDATE SEQUENCE"]="Validate sequence",["RUN SEQUENCE / configured hotkey"]="Run combo",["SAVE SELECTED SLOT"]="Save profile",["LOAD SELECTED SLOT"]="Load profile",
        ["RESTORE DEFAULT CONTROLS"]="Reset controls",["COPY SHOT HISTORY + LOG"]="Copy session report",["RETRY KEY RELEASE"]="Release held keys" }
    local definitions={
        ["Base hold duration / 50-2000 ms"]={"Shot timing","50-2000 ms","hold"},["Release lead / -250 to +250 ms; positive releases sooner"]={"Release lead","Positive = earlier release","lead"},
        Sequence={"Sequence","Z X C V H / SHIFT+key / key:hold/gap","macro"},["Default key hold / 20-250 ms"]={"Hold duration","20-250 ms","tap"},["Default gap / 20-500 ms"]={"Move interval","20-500 ms","gap"},
        ["Shot hotkey / F1-F12 or RightShift"]={"Shoot key","F1-F12 or RightShift","shot"},["Combo hotkey / unique; F8 is reserved"]={"Combo key","Unique key; F8 reserved","combo"},["Menu hotkey / unique; F8 is reserved"]={"Menu key","Unique key; F8 reserved","menu"},
    }
    local function decorate_button(b)
        actions[b.Text]=b; b.TextTransparency=1; b.AutoButtonColor=false; b.BackgroundColor3=theme.panel; b.Size=UDim2.new(1,-6,0,30); corner(b,5)
        local display=label(b,aliases[b.Text] or b.Text,8,0,100,30,11); display.Size=UDim2.new(1,-16,1,0); display.TextXAlignment=Enum.TextXAlignment.Center
        on(b:GetPropertyChangedSignal("Text"),function() display.Text=aliases[b.Text] or b.Text:gsub(" / click to cycle"," / select") end)
        on(b.MouseEnter,function() animate(b,{BackgroundColor3=theme.selected}) end)
        on(b.MouseLeave,function() animate(b,{BackgroundColor3=theme.panel}) end)
    end
    for name,page in pairs(pages) do
        page.ScrollBarThickness=2; page.ScrollBarImageColor3=theme.accent
        page:FindFirstChildWhichIsA("UIListLayout").Padding=UDim.new(0,6)
        local children=page:GetChildren()
        for index,child in ipairs(children) do
            if child:IsA("GuiObject") then
                child.LayoutOrder=index*10
                if child:IsA("TextLabel") then
                    local d=definitions[child.Text]; local box=children[index+1]
                    if d and box and box:IsA("TextBox") then
                        local multi=d[3]=="macro"
                        local row=frame(page,0,0,0,multi and 108 or 52); row.Size=UDim2.new(1,-6,0,multi and 108 or 52); row.LayoutOrder=child.LayoutOrder; corner(row,4)
                        child.Parent=row; child.Text=d[1]; child.TextSize=12; child.Font=Enum.Font.BuilderSans; child.TextColor3=theme.text; child.Position=UDim2.fromOffset(12,6); child.Size=UDim2.new(1,-128,0,20)
                        local helper=label(row,d[2],12,27,220,16,10,theme.muted); helper.Size=UDim2.new(1,-128,0,16)
                        box.Parent=row; box.TextSize=12; box.BackgroundColor3=theme.input; box.TextColor3=theme.text; box.Font=Enum.Font.RobotoMono; corner(box,3)
                        box.Position=multi and UDim2.fromOffset(12,51) or UDim2.new(1,-104,0,12); box.Size=multi and UDim2.new(1,-24,0,44) or UDim2.fromOffset(92,28); box.MultiLine=multi
                        local outline=border(box)
                        if multi then child.Size=UDim2.new(1,-24,0,20); helper.Size=UDim2.new(1,-24,0,16) end
                        on(box.Focused,function() outline.Color=theme.accent end); on(box.FocusLost,function() outline.Color=theme.line end)
                        fields[d[3]]=box; rows[#rows+1]={name=d[1],description=d[2],page=name,row=row}
                    elseif names[child.Text] or name=="Diagnostics" then child.Visible=false
                    else
                        if child.Text:find("Calibrate against live shot feedback",1,true) then child.Text="Manual shot lab  /  F6 action"; child.Size=UDim2.new(1,-6,0,22) end
                        child.TextSize=11; child.TextColor3=theme.muted; child.TextYAlignment=Enum.TextYAlignment.Top
                    end
                elseif child:IsA("TextButton") then decorate_button(child); if name=="Diagnostics" then child.Visible=false end end
            end
        end
    end
    local function group(list)
        local first=actions[list[1]]; local row=frame(first.Parent,0,0,0,30); row.Size=UDim2.new(1,-6,0,30); row.BackgroundTransparency=1; row.LayoutOrder=first.LayoutOrder
        make("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,6),SortOrder=Enum.SortOrder.LayoutOrder},row)
        for index,name in ipairs(list) do local b=actions[name]; b.Parent=row; b.LayoutOrder=index; b.Size=UDim2.new(1/#list,-6*(#list-1)/#list,1,0) end
    end
    group({"EARLY / hold 10 ms longer","GREEN / keep this timing","LATE / release 10 ms sooner"})
    group({"APPLY MEDIAN OF CAPTURED RELEASES","CLEAR CAPTURE SAMPLES"})
    group({"SAVE SELECTED SLOT","LOAD SELECTED SLOT"})
    local home=pages.Diagnostics
    home:FindFirstChildWhichIsA("UIListLayout"):Destroy()
    local account=frame(home,0,0,0,84); account.Size=UDim2.new(1,-6,0,84); corner(account,7)
    local name=player.DisplayName or player.Name
    local kicker=label(account,"Account",16,10,420,16,10,theme.muted)
    local display_name=label(account,name,16,28,450,25,18); display_name.Font=Enum.Font.BuilderSansBold
    local greeting=label(account,"@"..player.Name,16,55,430,17,11,theme.muted)
    local badge=frame(account,0,0,1,1); badge.Visible=false
    local session_label=label(account,"",0,0,1,1); session_label.Visible=false
    local stats=frame(home,0,94,0,54); stats.Size=UDim2.new(1,-6,0,54); corner(stats,7)
    local stat_values={}
    for index,title in ipairs({"Players","Session","FPS","Ping","Enabled"}) do
        local cell=frame(stats,0,0,0,54); cell.Position=UDim2.new((index-1)/5,0,0,0); cell.Size=UDim2.new(.2,0,1,0); cell.BackgroundTransparency=1
        local caption=label(cell,title,10,8,100,16,10,theme.muted); caption.Size=UDim2.new(1,-14,0,16)
        local value=label(cell,"--",10,26,100,20,15); value.Font=Enum.Font.BuilderSansMedium; value.Size=UDim2.new(1,-14,0,20); stat_values[title]=value
        if index>1 then local line=frame(cell,0,9,1,36,theme.line) end
    end
    local server=frame(home,0,158,0,108); server.Size=UDim2.new(1,-6,0,108); corner(server,7)
    label(server,"Session",14,12,240,20,13)
    label(server,"Practical Basketball",14,33,240,17,10,theme.muted)
    local place_text=label(server,"Place  "..string.format("%.0f",game.PlaceId),14,59,270,17,10,theme.muted)
    local server_text=label(server,"Server  "..tostring(game.JobId or "Local session"),14,78,270,16,10,theme.muted)
    server_text.TextTruncate=Enum.TextTruncate.AtEnd; server_text.TextWrapped=false
    local function copy(value)
        if type(setclipboard)=="function" then local ok=pcall(setclipboard,tostring(value)); status.Text=ok and "Copied to clipboard." or "Clipboard unavailable."
        else status.Text="Clipboard unavailable in this runtime." end
    end
    local copy_place=small_button(server,"Copy place ID",function() copy(string.format("%.0f",game.PlaceId)) end)
    local copy_server=small_button(server,"Copy server ID",function() copy(game.JobId or "") end)
    border(copy_place); border(copy_server)
    local runtime=frame(home,0,274,0,52); runtime.Size=UDim2.new(1,-6,0,52); corner(runtime,4)
    label(runtime,"Quick controls",14,8,240,18,12)
    local native=type(keypress)=="function" and type(keyrelease)=="function"
    local runtime_text=label(runtime,"Right Shift  Menu     F8  Stop all",14,27,500,16,10,theme.muted); runtime_text.Size=UDim2.new(1,-28,0,16)
    local bottom=frame(home,0,334,0,60); bottom.Size=UDim2.new(1,-6,0,60); bottom.BackgroundTransparency=1
    local storage=frame(bottom,0,0,0,60); storage.Size=UDim2.new(.5,-4,1,0); corner(storage,4)
    label(storage,"Profiles",12,9,180,18,12)
    local storage_text=label(storage,"3 profile slots",12,30,250,17,10,theme.muted); storage_text.Size=UDim2.new(1,-24,0,17)
    local report_card=frame(bottom,0,0,0,60); report_card.Position=UDim2.new(.5,4,0,0); report_card.Size=UDim2.new(.5,-4,1,0); corner(report_card,4)
    local export=actions["COPY SHOT HISTORY + LOG"]; export.Parent=report_card; export.Visible=true; export.Position=UDim2.fromOffset(10,14); export.Size=UDim2.new(1,-20,0,32)
    home.AutomaticCanvasSize=Enum.AutomaticSize.None; home.CanvasSize=UDim2.fromOffset(0,410)
    local rail_items={}
    local selected="Diagnostics"
    local result_page=make("ScrollingFrame",{Position=UDim2.fromOffset(84,52),Size=UDim2.new(1,-96,1,-120),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=2,
        CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,Visible=false},shell)
    make("UIListLayout",{Padding=UDim.new(0,6),SortOrder=Enum.SortOrder.LayoutOrder},result_page)
    local show
    local result_buttons={}
    for _,entry in ipairs(rows) do
        local result=small_button(result_page,entry.name.."  /  "..entry.page,function()
            search.Text=""; show(entry.page)
            pcall(function() pages[entry.page].CanvasPosition=Vector2.new(0,math.max(0,entry.row.AbsolutePosition.Y-pages[entry.page].AbsolutePosition.Y+pages[entry.page].CanvasPosition.Y)) end)
        end)
        result.Size=UDim2.new(1,-6,0,34); result_buttons[#result_buttons+1]={button=result,entry=entry}
    end
    local no_results=label(result_page,"No matching controls.",0,0,300,32,12,theme.muted)
    local function add_search(title,description,callback)
        local result=small_button(result_page,title.."  /  Modules",callback)
        result.Size=UDim2.new(1,-6,0,34)
        result_buttons[#result_buttons+1]={button=result,entry={name=title,description=description,page="Modules"}}
    end
    show=function(name)
        selected=name; result_page.Visible=false; if PivotUI and PivotUI.hide_extra then PivotUI.hide_extra() end
        for key,page in pairs(pages) do page.Visible=key==name end
        heading.Text="Practical Basketball"
        for key,item in pairs(rail_items) do
            local active=key==name; item.button.BackgroundColor3=active and theme.selected or theme.rail
            icon_color(item.icon,active and theme.accent or theme.muted); item.label.TextColor3=active and theme.accent or theme.muted
            if item.indicator then item.indicator.Visible=active end
        end
    end
    for index,entry in ipairs({{"Diagnostics","Home","⌂"},{"Shot Lab","Main","≡"},{"Combos","Combos","⋮"},{"Profiles","Settings","⚙"}}) do
        local name,caption,glyph=entry[1],entry[2],entry[3]
        local b=small_button(shell,caption,function() search.Text=""; show(name) end)
        b:SetAttribute("RailItem",true)
        b.Position=UDim2.fromOffset(20+(index-1)*100,62); b.Size=UDim2.fromOffset(94,30); b.TextTransparency=1; b.BackgroundColor3=theme.rail
        local symbol=icon(b,name,7,5,theme.muted)
        local text=label(b,caption,33,0,60,30,11,theme.muted)
        local indicator=frame(b,8,29,78,2,theme.accent); corner(indicator,1)
        rail_items[name]={button=b,icon=symbol,label=text,indicator=indicator}
        on(b.MouseEnter,function() if selected~=name then b.BackgroundColor3=theme.panel end end)
        on(b.MouseLeave,function() b.BackgroundColor3=selected==name and theme.selected or theme.rail end)
    end
    for _,button in ipairs(nav:GetChildren()) do
        if button:IsA("TextButton") and pages[button.Text] then local name=button.Text; on(button.Activated,function() show(name) end) end
    end
    on(search:GetPropertyChangedSignal("Text"),function()
        local query=search.Text:lower(); if PivotUI and PivotUI.hide_extra then PivotUI.hide_extra() end
        if query=="" then show(selected); return end
        for _,page in pairs(pages) do page.Visible=false end
        result_page.Visible=true; heading.Text="Search"
        local count=0
        for _,item in ipairs(result_buttons) do
            local match=(item.entry.name.." "..item.entry.description.." "..item.entry.page):lower():find(query,1,true)~=nil
            item.button.Visible=match; if match then count=count+1 end
        end
        no_results.Visible=count==0
    end)
    local profile_circle=frame(shell,21,0,26,26,theme.selected); corner(profile_circle,13); border(profile_circle,theme.accent)
    local profile_initial=label(profile_circle,tostring(name):sub(1,1),0,0,26,26,12,theme.accent); profile_initial.TextXAlignment=Enum.TextXAlignment.Center
    local rail_name=label(shell,tostring(name),5,0,58,15,9,theme.muted); rail_name.TextXAlignment=Enum.TextXAlignment.Center
    profile_circle.Visible=false; rail_name.Visible=false
    local footer=frame(shell,20,0,0,1,theme.line)
    status.TextSize=10; status.TextColor3=theme.muted
    cancel.TextTransparency=1; cancel.BackgroundColor3=theme.selected; corner(cancel,4)
    local cancel_text=label(cancel,"Stop all  ·  F8",0,0,96,28,11); cancel_text.TextXAlignment=Enum.TextXAlignment.Center
    local scale=shell:FindFirstChildWhichIsA("UIScale")
    local function layout_nav()
        local w=shell.Size.X.Offset
        for i,key in ipairs({"Diagnostics","Shot Lab","Modules","Combos","Profiles"}) do
            local item=rail_items[key]
            if item then
                local width=(w-40)/5
                item.button.Position=UDim2.fromOffset(20+(i-1)*width,62); item.button.Size=UDim2.fromOffset(width-4,30)
                local compact=w<560
                item.icon.Visible=not compact
                item.label.Position=UDim2.fromOffset(compact and 0 or 33,0); item.label.Size=UDim2.new(1,compact and 0 or -35,1,0)
                item.label.TextXAlignment=compact and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left
                if item.indicator then item.indicator.Position=UDim2.new(0,7,1,-1); item.indicator.Size=UDim2.new(1,-14,0,2) end
            end
        end
    end
    local camera_link
    local function fit()
        local camera=workspace.CurrentCamera; if not camera then return end
        local v=camera.ViewportSize
        local w=math.max(340,math.min(760,v.X-24)); local h=math.max(430,math.min(580,v.Y-32))
        scale.Scale=math.min(1,(v.X-12)/w,(v.Y-12)/h); shell.Size=UDim2.fromOffset(w,h)
        rail_line.Size=UDim2.new(1,-40,0,1); top_line.Size=UDim2.new(1,-40,0,1)
        layout_nav()
        local narrow=w<560
        search.Visible=not narrow; search.Position=UDim2.new(1,-214,0,10)
        search_symbol.Visible=not narrow; search_symbol.Position=UDim2.new(1,-211,0,12)
        heading.Visible=not narrow; heading.Size=UDim2.new(1,-320,0,26)
        close.Position=UDim2.new(1,-35,0,10); close.Size=UDim2.fromOffset(23,23)
        for _,page in pairs(pages) do page.Position=UDim2.fromOffset(20,112); page.Size=UDim2.new(1,-34,1,-174) end
        result_page.Position=UDim2.fromOffset(20,112); result_page.Size=UDim2.new(1,-34,1,-174)
        profile_circle.Position=UDim2.new(0,21,1,-64); rail_name.Position=UDim2.new(0,5,1,-32)
        footer.Position=UDim2.new(0,20,1,-49); footer.Size=UDim2.new(1,-40,0,1)
        status.Position=UDim2.new(0,20,1,-43); status.Size=UDim2.new(1,-145,0,34)
        cancel.Position=UDim2.new(1,-116,1,-39); cancel.Size=UDim2.fromOffset(96,28)
        local compact=w<560
        kicker.Size=UDim2.new(1,-28,0,16)
        display_name.Size=UDim2.new(1,-30,0,25); display_name.TextSize=18; greeting.Size=UDim2.new(1,-30,0,17)
        account.Size=UDim2.new(1,-6,0,84)
        copy_place.Position=compact and UDim2.fromOffset(12,108) or UDim2.new(1,-126,0,18)
        copy_server.Position=compact and UDim2.new(.5,3,0,108) or UDim2.new(1,-126,0,55)
        copy_place.Size=compact and UDim2.new(.5,-15,0,28) or UDim2.fromOffset(112,28); copy_server.Size=copy_place.Size
        server.Size=UDim2.new(1,-6,0,compact and 148 or 108)
        place_text.Size=UDim2.new(1,-(compact and 28 or 146),0,17); server_text.Size=UDim2.new(1,-(compact and 28 or 146),0,16)
        runtime.Position=UDim2.fromOffset(0,compact and 314 or 274); bottom.Position=UDim2.fromOffset(0,compact and 374 or 334)
        bottom.Size=UDim2.new(1,-6,0,compact and 126 or 60)
        storage.Size=compact and UDim2.new(1,0,0,60) or UDim2.new(.5,-4,1,0)
        report_card.Position=compact and UDim2.fromOffset(0,66) or UDim2.new(.5,4,0,0)
        report_card.Size=storage.Size
        home.CanvasSize=UDim2.fromOffset(0,compact and 510 or 404)
        local p=shell.Position; local hw=w*scale.Scale/2; local hh=h*scale.Scale/2
        shell.Position=UDim2.fromOffset(math.max(hw+6,math.min(v.X-hw-6,p.X.Scale*v.X+p.X.Offset)),math.max(hh+6,math.min(v.Y-hh-6,p.Y.Scale*v.Y+p.Y.Offset)))
    end
    local function watch()
        if camera_link then camera_link:Disconnect() end
        if workspace.CurrentCamera then camera_link=on(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"),fit) end
        fit()
    end
    watch(); show("Diagnostics")
    on(workspace:GetPropertyChangedSignal("CurrentCamera"),watch)
    on(input.InputEnded,function(event) if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch then fit() end end)
    local elapsed,frames,started=0,0,os.clock()
    on(run.Heartbeat,function(dt)
        elapsed=elapsed+dt; frames=frames+1; if elapsed<.5 then return end
        stat_values.FPS.Text=tostring(math.floor(frames/elapsed+.5)); stat_values.Session.Text=tostring(math.floor((os.clock()-started)/60)).."m"
        local count,max="--",tostring(players.MaxPlayers or "--"); pcall(function() count=tostring(#players:GetPlayers()) end)
        stat_values.Players.Text=count.."/"..max
        local ping="--"; pcall(function() ping=tostring(math.floor(player:GetNetworkPing()*1000+.5)).."ms" end); stat_values.Ping.Text=ping
        local active=0
        if PivotModules then for _ in pairs(PivotModules.registry.active) do active=active+1 end end
        stat_values.Enabled.Text=tostring(active)
        runtime_text.Text=tostring(fields.menu.Text).."  Menu     F8  Stop all"
        elapsed=0; frames=0
    end)
    PivotUI={theme=theme,label=label,button=small_button,pages=pages,rail_items=rail_items,show=show,heading=heading,search=search,cancel=cancel,actions=actions,icon=icon,icon_color=icon_color,animate=animate,add_search=add_search,layout_nav=layout_nav}
    on(gui.Destroying,function() for _,c in ipairs(connections) do c:Disconnect() end end)
end

do
    local ui=PivotUI
    local engine=Core.create_pivot_modules({players=players,player=player,input=input,run=run_service,runner=runner,gui=gui,connect=connect,report=report})
    PivotModules=engine
    local theme=ui.theme
    local function paint_switch(button,on)
        if button:GetAttribute("On")==on then return end
        button:SetAttribute("On",on)
        local track=button:FindFirstChild("Track"); local knob=track and track:FindFirstChild("Knob")
        if not knob then return end
        ui.animate(track,{BackgroundColor3=on and theme.accent or theme.line})
        ui.animate(knob,{BackgroundColor3=on and theme.base or theme.muted,Position=UDim2.fromOffset(on and 20 or 2,2)})
        local row=button.Parent
        if row and row.Name:sub(1,10)=="ModuleRow_" then row.BackgroundColor3=on and theme.selected or theme.panel; row.BackgroundTransparency=on and .4 or 0 end
    end
    local function switch(parent,callback)
        local button=make("TextButton",{Name="Toggle",Text="",AutoButtonColor=false,BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromOffset(44,26)},parent)
        local track=make("Frame",{Name="Track",Position=UDim2.fromOffset(4,4),Size=UDim2.fromOffset(36,18),BorderSizePixel=0},button)
        make("UICorner",{CornerRadius=UDim.new(0,9)},track)
        local knob=make("Frame",{Name="Knob",Size=UDim2.fromOffset(14,14),BorderSizePixel=0},track)
        make("UICorner",{CornerRadius=UDim.new(0,7)},knob)
        connect(button.Activated,callback); paint_switch(button,false)
        return button
    end
    local page=make("ScrollingFrame",{Name="PivotModules",Position=UDim2.fromOffset(20,112),Size=UDim2.new(1,-34,1,-174),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=2,Visible=false,CanvasSize=UDim2.fromOffset(0,0)},window)
    local tabs={"Shooting","Player","Defense","Visuals","World","Camera","Recorder","Options"}
    local category="Shooting"; local rows={}; local fields={}; local y=0
    local expanded,choosing,section_button,record_tools
    local auxiliary={}; local capture_switch
    local function clear()
        for _,object in ipairs(rows) do object:Destroy() end; rows={}; fields={}; auxiliary={}; y=46
    end
    local function own(object) rows[#rows+1]=object; return object end
    local function text(value,size,color,height)
        local object=own(ui.label(page,value,2,y,500,height or 22,size or 12,color or theme.text)); object.Size=UDim2.new(1,-12,0,height or 22); y=y+(height or 22)+5; return object
    end
    local function action(value,callback)
        local object=own(ui.button(page,value,function() local ok,err=pcall(callback); if not ok then report(tostring(err)) end end))
        object.Position=UDim2.fromOffset(0,y); object.Size=UDim2.new(1,-6,0,30); y=y+36; return object
    end
    local function field(key,caption)
        local row=own(make("Frame",{Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,36),BackgroundColor3=theme.panel,BorderSizePixel=0},page))
        local label=ui.label(row,caption,10,8,220,20,11,theme.muted); label.Size=UDim2.new(.6,-14,0,20)
        local box=make("TextBox",{Name="Module_"..key,Text=tostring(engine.settings[key]),ClearTextOnFocus=false,Font=Enum.Font.RobotoMono,TextSize=11,TextColor3=theme.text,BackgroundColor3=theme.input,BorderSizePixel=0,Position=UDim2.new(.6,0,0,4),Size=UDim2.new(.4,-6,0,28)},row)
        fields[key]=box; y=y+42
        connect(box.FocusLost,function()
            local original=engine.settings[key]; local value=box.Text
            if type(original)=="number" then local range=engine.ranges[key]; value=Core.bounded(value,range[1],range[2]); if not value then box.Text=tostring(original); report("Value outside allowed range: "..key); return end end
            if #box.Text>100 then box.Text=tostring(original); return end
            engine.settings[key]=value
        end)
    end
    local buttons={}; local rebuild
    local function update_buttons()
        for id,button in pairs(buttons) do
            if button.Parent then paint_switch(button,engine.registry.active[id]~=nil) end
        end
        for _,entry in ipairs(auxiliary) do if entry.button.Parent then paint_switch(entry.button,entry.read()) end end
        if capture_switch then paint_switch(capture_switch,capture) end
    end
    local function toggle_action(caption,read,write)
        local row=own(make("Frame",{Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,32),BackgroundTransparency=1},page))
        local title=ui.label(row,caption,4,0,300,30,11,theme.text); title.Size=UDim2.new(1,-60,0,30)
        local button=switch(row,function() local ok,err=pcall(write,not read()); if not ok then report(tostring(err)) end; update_buttons() end)
        button.Position=UDim2.new(1,-48,0,3); auxiliary[#auxiliary+1]={button=button,read=read}; y=y+36
        paint_switch(button,read()); return button
    end
    local capture_key,capture_started,last_ended
    local function stop_capture()
        engine.capturing=false; capture_key=nil; capture_started=nil; last_ended=nil
    end
    local loop_token
    local function playback(loop)
        stop_capture(); local recording,err=Core.validate_recording(engine.recording); assert(recording,err)
        local ok,message=runner:start(function(token)
            if loop then loop_token=token end
            repeat
                for _,step in ipairs(recording.steps) do
                    local keys=step.shift and {"LeftShift",step.key} or {step.key}
                    if not runner:step(keys,step.hold,token) or not runner:wait(step.gap,token) then return end
                end
                if loop and not runner:wait(150,token) then return end
            until not loop or token.cancelled
        end,function(success,result) if loop then loop_token=nil end; report(success and "Recording playback finished" or tostring(result)) end)
        assert(ok,message)
    end
    connect(input.InputBegan,function(event,processed)
        if not engine.capturing or processed or input:GetFocusedTextBox() or runner.current then return end
        local key=event.KeyCode.Name
        if key:match("^[ZXCVH]$") then
            if capture_key then report("Recorder accepts one dribble key at a time"); return end
            if #engine.recording.steps>=64 or os.clock()-engine.capture_begin>=60 then stop_capture(); report("Recorder limit reached"); return end
            if last_ended and #engine.recording.steps>0 then engine.recording.steps[#engine.recording.steps].gap=math.min(5000,math.floor((os.clock()-last_ended)*1000+.5)) end
            capture_key={key=key,shift=input:IsKeyDown(Enum.KeyCode.LeftShift)}; capture_started=os.clock()
        end
    end)
    connect(input.InputEnded,function(event)
        if engine.capturing and capture_key and event.KeyCode.Name==capture_key.key then
            capture_key.hold=math.max(20,math.min(5000,math.floor((os.clock()-capture_started)*1000+.5))); capture_key.gap=100
            engine.recording.steps[#engine.recording.steps+1]=capture_key; last_ended=os.clock(); capture_key=nil; capture_started=nil
            report("Recorded "..#engine.recording.steps.." dribble steps")
        end
    end)
    local function export(data)
        assert(type(setclipboard)=="function","Clipboard unavailable"); setclipboard(http:JSONEncode(data)); report("Copied JSON")
    end
    local function settings_data()
        local result={}; for key,value in pairs(engine.settings) do result[key]=value end; return result
    end
    local function apply_settings(data)
        local validated,err=Core.validate_module_settings(data,engine.settings,engine.ranges); assert(validated,err)
        engine:stop(); for key,value in pairs(validated) do engine.settings[key]=value end
    end
    rebuild=function()
        clear(); buttons={}
        if section_button then section_button.Text=category.."  ▾" end
        if choosing then
            for _,name in ipairs(tabs) do action(name,function() category=name; choosing=false; expanded=nil; page.CanvasPosition=Vector2.new(0,0); rebuild() end) end
        elseif category=="Recorder" then
            text("Z X C V H + Shift / 64 steps / 60 seconds",11,theme.muted)
            toggle_action("Record dribbles",function() return engine.capturing==true end,function(on)
                if on then cancel(); engine:stop(); engine.recording={version=1,steps={}}; engine.capturing=true; engine.capture_begin=os.clock(); capture_key=nil; last_ended=nil; report("Recording dribble inputs / F8 to stop")
                else stop_capture(); report("Saved "..#engine.recording.steps.." steps in this session") end
            end)
            action("Play recording once",function() playback(false) end)
            toggle_action("Loop recording",function() return loop_token~=nil and runner.current==loop_token and not loop_token.cancelled end,function(on)
                if on then playback(true) elseif runner.current==loop_token then runner:cancel(); loop_token=nil end
            end)
            action(record_tools and "Files / import and export  ▴" or "Files / import and export  ▾",function() record_tools=not record_tools; rebuild() end)
            if record_tools then
            action("Copy recording JSON",function() local value,err=Core.validate_recording(engine.recording); assert(value,err); export(value) end)
            local box=own(make("TextBox",{Name="RecordingImport",Text="",PlaceholderText="Paste recording JSON",ClearTextOnFocus=false,MultiLine=true,Font=Enum.Font.RobotoMono,TextSize=10,TextColor3=theme.text,BackgroundColor3=theme.input,BorderSizePixel=0,Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,76)},page)); y=y+82
            action("Import pasted recording",function() assert(#box.Text<=32768,"JSON exceeds 32 KB"); local value,err=Core.validate_recording(http:JSONDecode(box.Text)); assert(value,err); stop_capture(); engine.recording=value; report("Imported "..#value.steps.." steps") end)
            action("Save recording to disk",function() assert(type(writefile)=="function","Disk write unavailable"); local value,err=Core.validate_recording(engine.recording); assert(value,err); writefile("pivot_recording.json",http:JSONEncode(value)); report("Saved pivot_recording.json") end)
            action("Load recording from disk",function() assert(type(readfile)=="function","Disk read unavailable"); local raw=readfile("pivot_recording.json"); assert(#raw<=32768,"Recording exceeds size limit"); local value,err=Core.validate_recording(http:JSONDecode(raw)); assert(value,err); stop_capture(); engine.recording=value; report("Loaded recording") end)
            end
        elseif category=="Options" then
            text("Settings load without enabling modules.",11,theme.muted)
            field("esp_distance","Overlay distance / studs")
            toggle_action("Team filter",function() return engine.settings.team_check end,function(on) engine.settings.team_check=on end)
            action("Copy module settings",function() export(settings_data()) end)
            action("Save module settings",function() assert(type(writefile)=="function","Disk write unavailable"); writefile("pivot_module_settings.json",http:JSONEncode(settings_data())); report("Saved module settings") end)
            action("Load module settings",function() assert(type(readfile)=="function","Disk read unavailable"); local raw=readfile("pivot_module_settings.json"); assert(#raw<=16384,"Settings exceed size limit"); apply_settings(http:JSONDecode(raw)); rebuild(); report("Loaded settings / all modules off") end)
            action("Disable every module / restore values",function() cancel(); engine:stop(); update_buttons(); report("All modules disabled") end)
        else
            local options={speed={{"walk_speed","Client walk speed"}},split_speed={{"on_ball_speed","On-ball speed"},{"off_ball_speed","Off-ball speed"}},jump={{"jump_power","Jump power"}},fly={{"fly_speed","Flight speed"}},spin={{"spin_speed","Degrees / second"}},guard={{"guard_target","Target username"},{"guard_distance","Guard spacing"},{"guard_range","Activation range"}},block={{"guard_target","Target username"},{"block_range","Activation range"},{"jump_key","Jump / block key"}},rebound={{"rebound_range","Activation range"},{"jump_key","Jump key"}},range_circle={{"range","Range / studs"}},time={{"time","Time / 0-24"}},fov={{"fov","Field of view"}},spectate={{"spectate","Target username"}}}
            for _,definition in ipairs(engine.definitions) do
                if definition.category==category then
                    local id=definition.id
                    local row=own(make("Frame",{Name="ModuleRow_"..id,Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,60),BackgroundColor3=theme.panel,BackgroundTransparency=0,BorderSizePixel=0},page))
                    make("UICorner",{CornerRadius=UDim.new(0,5)},row)
                    local title=ui.label(row,definition.title,14,8,300,22,13,theme.text); title.Size=UDim2.new(1,-110,0,22)
                    local summary=ui.label(row,definition.description,14,32,300,16,10,theme.muted); summary.Size=UDim2.new(1,-110,0,16); summary.TextWrapped=false; summary.TextTruncate=Enum.TextTruncate.AtEnd
                    local detail=ui.button(row,expanded==id and "−" or "+",function() if expanded==id then expanded=nil else expanded=id end; rebuild() end)
                    detail.Name="Details"; detail.Position=UDim2.new(1,-79,0,18); detail.Size=UDim2.fromOffset(24,24); detail.BackgroundTransparency=1
                    buttons[id]=switch(row,function()
                        if engine.registry.active[id] then engine.registry:disable(id) else local ok,err=engine.registry:enable(id,engine.settings); if not ok then report(tostring(err)) end end
                        update_buttons()
                    end)
                    buttons[id].Position=UDim2.new(1,-48,0,17)
                    connect(row.MouseEnter,function() row.BackgroundColor3=theme.panel; row.BackgroundTransparency=.25 end)
                    connect(row.MouseLeave,function() row.BackgroundColor3=engine.registry.active[id] and theme.selected or theme.panel; row.BackgroundTransparency=engine.registry.active[id] and .4 or 0 end)
                    y=y+68
                    if expanded==id then
                        text(definition.description,10,theme.muted,40).TextWrapped=true
                        for _,entry in ipairs(options[id] or {}) do field(entry[1],entry[2]) end
                        if id=="guard" then action("Use nearest rim as defensive goal",function() engine:select_defensive_rim() end) end
                        y=y+7
                    end
                end
            end
        end
        page.CanvasSize=UDim2.fromOffset(0,y+8); update_buttons()
    end
    section_button=ui.button(page,category.."  ▾",function() choosing=not choosing; page.CanvasPosition=Vector2.new(0,0); rebuild() end)
    section_button.Name="ModuleCategory"; section_button.Position=UDim2.fromOffset(0,0); section_button.Size=UDim2.fromOffset(142,28)
    local rail=ui.button(window,"Modules",function()
        ui.search.Text=""; ui.show("Modules"); rebuild()
    end)
    rail.Name="ModulesNav"; rail.Position=UDim2.fromOffset(9,302); rail.Size=UDim2.fromOffset(50,54); rail.TextTransparency=1; rail.BackgroundColor3=theme.rail
    rail:SetAttribute("RailItem",true)
    local glyph=ui.icon(rail,"Modules",15,8,theme.muted)
    local caption=ui.label(rail,"Modules",0,33,50,16,10,theme.muted); caption.TextXAlignment=Enum.TextXAlignment.Center
    local indicator=make("Frame",{Position=UDim2.fromOffset(0,17),Size=UDim2.fromOffset(2,18),BackgroundColor3=theme.accent,BorderSizePixel=0,Visible=false},rail)
    ui.pages.Modules=page; ui.rail_items.Modules={button=rail,icon=glyph,label=caption,indicator=indicator}
    glyph.Position=UDim2.fromOffset(7,5); caption.Position=UDim2.fromOffset(33,0); caption.Size=UDim2.new(1,-35,1,0); caption.TextXAlignment=Enum.TextXAlignment.Left
    ui.layout_nav()
    connect(rail.MouseLeave,function() rail.BackgroundColor3=page.Visible and theme.selected or theme.rail end)
    ui.hide_extra=function() page.Visible=false end
    connect(gui.Destroying,function() engine:close() end)
    connect(ui.cancel.Activated,function() engine:stop(); update_buttons() end)
    local capture_button=ui.actions["TOGGLE MANUAL CAPTURE / hold and release E"]
    if capture_button then
        capture_button.BackgroundColor3=theme.panel
        for _,child in ipairs(capture_button:GetChildren()) do if child:IsA("TextLabel") then child.Size=UDim2.new(1,-58,1,0) end end
        capture_switch=switch(capture_button,function() capture=not capture; capture_start=nil; report(capture and "Manual timing capture on" or "Manual timing capture off"); update_buttons() end)
        capture_switch.Position=UDim2.new(1,-48,0,2)
    end
    local elapsed=0
    connect(run_service.Heartbeat,function(dt) elapsed=elapsed+dt; if elapsed>.2 then elapsed=0; update_buttons() end end)
    for _,definition in ipairs(engine.definitions) do
        local id,section=definition.id,definition.category
        ui.add_search(definition.title,definition.description,function()
            ui.search.Text=""; category=section; expanded=id; choosing=false; ui.show("Modules"); page.CanvasPosition=Vector2.new(0,0); rebuild()
        end)
    end
    rebuild()
end

