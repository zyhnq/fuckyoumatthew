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
    function self:restore(object,key)
        local saved=self.changes[object] and self.changes[object][key]
        if saved then if object[key]==saved.applied then object[key]=saved.original end; saved.applied=saved.original end
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
    local state={watched={},sent={},metadata=setmetatable({},{__mode="k"}),profiles=deps.profiles or {},pending={},closed=false,good_trials={},good_streak={},good_exhausted={}}
    local function telemetry(event) if deps.telemetry then pcall(deps.telemetry,event) end end
    local function target_ratio(p)
        local enabled=deps.good_correction and deps.good_correction() and (not deps.calibrate or deps.calibrate())
        if not enabled then state.good_trials[p]=nil; state.good_streak[p]=nil; state.good_exhausted[p]=nil end
        local trial=enabled and state.good_trials[p] or nil
        return math.max(.25,math.min(p.ceiling or .85,trial and trial.ratio or p.ratio)),trial
    end
    local function profile(track,name)
        local animation=track.Animation
        local key=name.."/"..tostring(animation and animation.AnimationId or "")
        if not state.profiles[key] then
            local attributes=deps.attributes()
            local initial=.60
            if attributes and attributes.Action=="Dunking" then initial=.36 end
            if name=="InsideHandLayup1R" then initial=.70 end
            state.profiles[key]={ratio=initial,dunk=attributes and attributes.Action=="Dunking"}
        end
        return state.profiles[key]
    end
    function state:feedback(code)
        code=tonumber(code)
        if not code or code%1~=0 or code<1 or code>8 or #self.pending==0 then return end
        local pending=table.remove(self.pending,1)
        telemetry({kind="feedback",code=code,shot=pending.shot,name=pending.name,ratio=pending.ratio,locked=pending.profile.perfect})
        if deps.calibrate and not deps.calibrate() then
            self.good_trials[pending.profile]=nil; self.good_streak[pending.profile]=nil
            if code==5 then pending.profile.ratio=pending.ratio; pending.profile.perfect=true; if deps.changed then deps.changed() end end
            return
        end
        local p=pending.profile; local early=code<=3; local late=code>=6
        if code==5 then self.good_trials[p]=nil; self.good_streak[p]=nil; self.good_exhausted[p]=nil end
        if (early or late) and pending.trial then
            self.good_trials[p]=nil; self.good_streak[p]=nil; self.good_exhausted[p]=true
            deps.report("Nearby timing rejected / restored established release")
            telemetry({kind="refinement",reason="Nearby timing rejected · baseline restored",shot=pending.shot,name=pending.name,ratio=p.ratio})
            return
        end
        if code==4 and deps.good_correction and deps.good_correction() then
            self.good_streak[p]=(self.good_streak[p] or 0)+1
            if not self.good_exhausted[p] and (not p.perfect or self.good_streak[p]>=2) then
                local trial=self.good_trials[p] or {center=p.ratio,attempt=0}
                if trial.attempt>=6 then
                    self.good_trials[p]=nil; self.good_exhausted[p]=true
                    deps.report("Good release / bounded search finished, baseline retained")
                    telemetry({kind="refinement",reason="Good · search finished; baseline retained",shot=pending.shot,name=pending.name,ratio=p.ratio})
                else
                    trial.attempt=trial.attempt+1
                    local offset=math.ceil(trial.attempt/2)*.003*(trial.attempt%2==1 and 1 or -1)
                    local minimum=math.max(.25,(p.early or .24)+.001)
                    local maximum=math.min(p.ceiling or .85,(p.late or .86)-.001)
                    if minimum<=maximum then trial.ratio=math.max(minimum,math.min(maximum,trial.center+offset)); self.good_trials[p]=trial end
                    deps.report("Good release / testing a small nearby phase")
                    telemetry({kind="refinement",reason="Good · testing nearby timing ("..trial.attempt.."/6)",shot=pending.shot,name=pending.name,ratio=trial.ratio or p.ratio})
                end
            else deps.report("Good release / established timing retained") end
            return
        end
        if early then p.early=math.max(p.early or .25,pending.ratio)
        elseif late then p.late=math.min(p.late or .85,pending.ratio)
        else
            if code==5 then
                p.ratio=pending.ratio
                p.perfect=true; p.good_center=nil; p.good_attempt=0
                deps.report("Perfect release / keeping timing")
            elseif (deps.refine_good and deps.refine_good() or not deps.refine_good and p.dunk) and not p.perfect then
                p.good_center=p.good_center or pending.ratio
                p.good_attempt=(p.good_attempt or 0)+1
                local attempt=p.good_attempt
                local offset=math.ceil(attempt/2)*.01*(attempt%2==1 and 1 or -1)
                local minimum=math.max(.25,(p.early or .24)+.001)
                local maximum=math.min(p.ceiling or .85,(p.late or .86)-.001)
                if minimum<=maximum then p.ratio=math.max(minimum,math.min(maximum,p.good_center+offset)) end
                if attempt>=6 then p.good_attempt=0 end
                deps.report("Good release / testing a nearby release phase")
            else deps.report("Good release / keeping timing") end
            if deps.changed then deps.changed() end
            return
        end
        p.perfect=false; p.good_center=nil; p.good_attempt=0
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
        if deps.changed then deps.changed() end
    end
    local function release_time(track)
        if state.metadata[track]==nil then
            local ok,time=pcall(function() return track:GetTimeOfKeyframe("Release") end)
            local valid=ok and Core.bounded(time,.0001,30)
            if valid then state.metadata[track]=valid end
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
        local expected=deps.active_track and deps.active_track(name)
        if expected and track~=expected then return nil end
        local animation=track.Animation
        local named=track.Name==name or animation and animation.Name==name
        local generic=track.Name=="Animation" and animation and animation.Name=="Animation" and release_time(track)~=nil
        if not named and not generic and track~=expected then return nil end
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
            local ratio,trial=target_ratio(p)
            state.pending[#state.pending+1]={profile=p,ratio=ratio,trial=trial,shot=shot,name=name,time=os.clock()}
        end
        if state.observed and state.observed.id==shot then state.observed.sent=true end
        local event={kind="release",shot=shot,name=name,ratio=entry.release_time and target_ratio(profile(track,name)) or nil,position=track.TimePosition,speed=track.Speed}
        if deps.snapshot then local ok,details=pcall(deps.snapshot); if ok then event.details=details end end
        telemetry(event)
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
        local attributes=deps.attributes()
        local active=attributes and (attributes.Action=="Shooting" or attributes.Action=="Dunking") and attributes.ReleasedShot==false
        local id=active and Core.bounded(attributes.ShotStartTime,0,math.huge)
        if self.observed and self.observed.id~=id then
            if not self.observed.sent then telemetry({kind="skip",shot=self.observed.id,name=self.observed.name,reason=self.observed.reason or "Shot ended before the release target"}) end
            self.observed=nil
        end
        if id and not self.observed then self.observed={id=id,name=attributes.BaseAnimation,sent=self.sent[id]==true} end
        if self.observed and not self.observed.sent then
            self.observed.name=attributes.BaseAnimation
            self.observed.reason=deps.paused() and "Shot paused while editing controls" or not deps.held() and "Shoot input released before the target" or "No matching shot animation or Release keyframe"
        end
        for i=#self.pending,1,-1 do
            local pending=self.pending[i]
            if pending.time and os.clock()-pending.time>8 then
                table.remove(self.pending,i)
                if pending.trial then self.good_trials[pending.profile]=nil; self.good_streak[pending.profile]=nil; self.good_exhausted[pending.profile]=true end
                telemetry({kind="unconfirmed",shot=pending.shot,name=pending.name})
            end
        end
        local tracks=deps.tracks(); local present={}
        for _,track in ipairs(tracks) do
            present[track]=true
            local shot=eligible(track)
            local prior=self.watched[track]
            if prior and shot and (prior.shot~=shot or prior.name~=select(2,eligible(track))) then disconnect(track) end
            if shot and not self.watched[track] then
                local entry={connections={},shot=shot,name=select(2,eligible(track)),release_time=release_time(track)}; self.watched[track]=entry
                entry.connections[#entry.connections+1]=track:GetMarkerReachedSignal("Release"):Connect(function() release(track,"Release") end)
            end
            local entry=self.watched[track]
            if entry and self.observed and entry.shot==self.observed.id and not self.observed.sent and deps.held() and not deps.paused() then self.observed.reason=entry.release_time and "Shot ended before the release target" or "Release keyframe was unavailable" end
            if entry and not entry.release_time then entry.release_time=release_time(track) end
            if entry and entry.release_time and type(track.TimePosition)=="number" and track.TimePosition>0 then
                local attributes=deps.attributes()
                if attributes and type(attributes.BaseAnimation)=="string" then
                    local p=profile(track,attributes.BaseAnimation)
                    if track.Speed==0 and track.TimePosition<entry.release_time then
                        p.ceiling=math.max(.25,math.min(.85,track.TimePosition/entry.release_time))
                        p.ratio=math.min(p.ratio,p.ceiling)
                    end
                    local position=track.TimePosition
                    if deps.lead and type(track.Speed)=="number" and track.Speed>0 then position=position+track.Speed*deps.lead() end
                    if attributes.Action=="Dunking" and type(track.Speed)=="number" and track.Speed>0 then
                        position=position+track.Speed*math.min(1/60,math.max(0,tonumber(dt) or 0))
                    end
                    if position>=entry.release_time*target_ratio(p) then release(track,"Shot phase") end
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
        if type(incoming)=="string" and (key:match("_color$") or key=="ui_accent" or key=="sky_tint" or key=="sky_decay") and not Core.hex_color(incoming) then return nil,"Invalid color: "..key end
        result[key]=incoming
    end
    return result
end

-- Geometric estimate only; this is not the server's shot-contest value.
function Core.coverage_estimate(origin,goal,defenders,radius)
    radius=math.max(1,radius or 12)
    local direction=goal and Vector3.new(goal.X-origin.X,0,goal.Z-origin.Z)
    if direction and direction.Magnitude>.01 then direction=direction.Unit else direction=nil end
    local remaining=1
    for _,position in ipairs(defenders) do
        local delta=Vector3.new(position.X-origin.X,0,position.Z-origin.Z); local distance=delta.Magnitude
        if distance<radius and math.abs(position.Y-origin.Y)<7 then
            local alignment=direction and distance>.01 and delta.Unit:Dot(direction) or 1
            local angle_weight=.35+.65*math.max(0,alignment)
            local closeness=math.max(0,math.min(1,(radius-distance)/(radius-1)))
            local pressure=closeness*closeness*angle_weight
            remaining=remaining*(1-pressure)
        end
    end
    return math.max(0,math.min(100,(1-remaining)*100))
end

function Core.hex_color(value)
    if type(value)~="string" then return nil end
    local hex=value:match("^#?(%x%x%x%x%x%x)$"); if not hex then return nil end
    return Color3.fromRGB(tonumber(hex:sub(1,2),16),tonumber(hex:sub(3,4),16),tonumber(hex:sub(5,6),16))
end

local function create_pivot_modules(ctx)
    local Engine={settings={walk_speed=20,jump_power=50,fly_speed=32,spin_speed=90,fov=85,time=14,range=34,esp_distance=300,
        guard_distance=4,guard_range=25,block_range=12,steal_range=5,steal_key="",spectate="",
        on_ball_speed=20,off_ball_speed=20,guard_target="",jump_key="Space",rebound_range=8,team_check=true,guard_sprint=false,ball_handler_only=false,guard_strength=1,block_delay=0,shot_range=34,glide_speed=20,ankle_range=8,ankle_delay=1.2,ankle_combo="ZX",custom_combo="Z X C",combo_delay=110,combo_bind="F5",meter_style="Vertical",auto_calibrate=true,ping_compensation=false,ping_factor=.5,takeover_threshold=100,theme_mode="Graphite",crosshair_shape="Cross",crosshair_color="#E6E8ED",crosshair_size=6,crosshair_gap=4,crosshair_thickness=2,crosshair_opacity=1,
        ball_trail_color="#AAC8FF",ball_trail_lifetime=.35,ball_trail_width=.6,ball_trail_opacity=.7,player_trail_color="#C6CFFF",player_trail_lifetime=.3,player_trail_width=.7,player_trail_opacity=.5,
        ball_color="#D1D6E0",ball_material="SmoothPlastic",ball_reflectance=0,ball_remove_texture=true,ball_glow=true,ball_glow_strength=.8,ball_bloom=.7,court_color="#444C60",court_line_color="#E6E8ED",court_material="SmoothPlastic",court_reflectance=0,court_part_name="CourtFloor",court_color_lines=true,court_remove_texture=true,court_three_color="#E6E8ED",court_free_color="#E6E8ED",court_three_enabled=true,court_free_enabled=true,court_rebuild_markings=true,court_three_radius=34,court_three_angle=128,court_free_radius=8,court_free_distance=21.5,court_corner_depth=6,court_line_width=.18,
        outline_color="#C0C9DC",outline_fill_color="#C0C9DC",outline_opacity=1,outline_fill_opacity=0,outline_through_walls=false,sky_preset="Night",sky_asset="",sky_tint="#8799BB",sky_decay="#283650",sky_stars=3000,sky_density=.22,sky_haze=.5,
        dribble_sprint=false,dribble_gap=180,dribble_combo_name="My combo",shot_hud_compact=false,module_preset_name="Favorites",model_preset="Sasuke",model_catalog="Curated",model_save_name="",model_style="Basketball",model_renderer="Native world",model_high_detail=true,model_headless=false,model_show_hair=true,model_show_hats=true,model_show_masks=true,model_show_capes=true,model_show_weapons=true,model_show_extras=true,coverage_radius=12,coverage_display="Both",coverage_scale=1,coverage_height=2.6,coverage_response=12,model_fit_pb=true,model_fit_scale=1.015,model_accessory_scale=1,model_asset="",model_height=6,model_offset=0,model_rotation=0,model_follow_pose=true,model_motion=true,model_hide_avatar=true,
        theme_custom=false,ui_accent="#C0C9DC",ui_font_size=14,ui_rounding=6,ui_opacity=1,refine_good=true,shot_hud=true},ranges={dribble_gap={80,1200},coverage_scale={.75,1.5},coverage_height={1,5},coverage_response={2,25},model_accessory_scale={.5,1.5},coverage_radius={4,20},model_fit_scale={.95,1.12},court_three_radius={20,45},court_three_angle={90,180},court_free_radius={3,12},court_free_distance={10,30},court_corner_depth={0,12},court_line_width={.05,.8},ball_glow_strength={.05,1},ball_bloom={0,2},crosshair_size={2,24},crosshair_gap={0,20},crosshair_thickness={1,6},crosshair_opacity={.1,1},ball_trail_lifetime={.05,2},ball_trail_width={.1,4},ball_trail_opacity={.05,1},player_trail_lifetime={.05,2},player_trail_width={.1,4},player_trail_opacity={.05,1},ball_reflectance={0,1},court_reflectance={0,1},outline_opacity={0,1},outline_fill_opacity={0,1},sky_stars={0,5000},sky_density={0,.6},sky_haze={0,5},model_height={2,12},model_offset={-6,6},model_rotation={0,360},ui_font_size={14,20},ui_rounding={0,14},ui_opacity={.2,1},guard_strength={.5,2},block_delay={0,.5},shot_range={5,60},glide_speed={4,60},ankle_range={2,20},ankle_delay={.5,5},combo_delay={20,500},ping_factor={0,1},takeover_threshold={1,100},walk_speed={4,60},jump_power={10,120},fly_speed={4,100},spin_speed={10,360},fov={40,110},time={0,24},range={5,60},esp_distance={30,1000},guard_distance={2,10},guard_range={5,60},block_range={3,18},steal_range={2,8},on_ball_speed={4,60},off_ball_speed={4,60},rebound_range={3,15}},definitions={},recording={version=1,steps={}}}
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
            for _,obj in ipairs(parent:GetDescendants()) do if obj:IsA("PostEffect") and obj.Name~="PivotBallBloom" then scope:set(obj,"Enabled",false) end end
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
    local cached_controller
    local function client_attributes()
        if not cached_controller then
            local scripts=ctx.player:FindFirstChild("PlayerScripts"); local aero=scripts and scripts:FindFirstChild("Aero")
            local folder=aero and aero:FindFirstChild("Controllers"); local module=folder and folder:FindFirstChild("Player")
            if module then local ok,value=pcall(require,module); if ok then cached_controller=value end end
        end
        local c=cached_controller and cached_controller:GetCharacter()
        return c and c.data and c.data.Attributes
    end
    local function attribute_module(id,title,values,description,conflicts)
        local function apply(scope,state,s)
            local model=character()
            if state and model~=state then error("Character changed; re-enable the module") end
            for key,value in pairs(values) do
                assert(model:GetAttribute(key)~=nil,"Observed attribute unavailable: "..key)
                local applied=type(value)=="function" and value(s) or value
                scope:attribute(model,key,applied)
                local attributes=client_attributes(); if attributes and attributes[key]~=nil then scope:set(attributes,key,applied) end
            end
            return model
        end
        add(id,title,"Player",description.." / client attributes; game or server may replace them",{start=function(scope,s) return apply(scope,nil,s) end,step=apply,interval=0,conflicts=conflicts})
    end
    attribute_module("speed","Speed boost",{WalkSpeed=function(s) return s.walk_speed end},"Observed WalkSpeed attribute",{"split_speed"})
    attribute_module("stamina","Infinite stamina",{Stamina=100},"Observed Stamina attribute")
    attribute_module("movement_lock","No stun",{CanMove=true},"Observed CanMove attribute")
    attribute_module("turn_lock","Remove client turn lock",{CanTurn=true},"Observed CanTurn attribute")
    attribute_module("debounce","No debounce",{Debounce=false},"Observed Debounce attribute")
    attribute_module("cold","No cold zone",{Cold=false},"Observed Cold attribute")
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
                            local text=Instance.new("TextLabel"); text.BackgroundTransparency=1; text.Size=UDim2.fromScale(1,1); text.TextColor3=Color3.fromRGB(215,195,232); text.TextSize=14; text.Font=Enum.Font.BuilderSans; text.TextStrokeTransparency=.4; text.Parent=billboard
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
        if s.guard_target=="" then
            local mine=assert(root(),"Local root unavailable"); local team=rig():GetAttribute("Team"); local best,best_part,distance
            for _,who in ipairs(players:GetPlayers()) do
                if who~=ctx.player then
                    local model=rig(who); local part=root(who)
                    local teammate=s.team_check and team and team~=0 and model and model:GetAttribute("Team")==team
                    if model and part and not teammate and (not s.ball_handler_only or held_ball(model)) then
                        local d=(part.Position-mine.Position).Magnitude
                        if not distance or d<distance then best=model; best_part=part; distance=d end
                    end
                end
            end
            assert(best,"No eligible opponent nearby"); return best,best_part
        end
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
        if s.guard_target=="" then
            local ok,model,part=pcall(selected_target,s)
            if not ok then release_owned(scope); return end
            state.model=model; state.part=part
        end
        local mine=assert(root(),"Local root unavailable"); assert(state.part.Parent and Engine.defensive_rim.Parent,"Target or rim removed")
        local distance=(state.part.Position-mine.Position).Magnitude
        local delta=Engine.defensive_rim.Position-state.part.Position; delta=Vector3.new(delta.X,0,delta.Z)
        local desired=state.part.Position+(delta.Magnitude>.01 and delta.Unit*s.guard_distance or Vector3.zero)
        local direction=desired-mine.Position; direction=Vector3.new(direction.X,0,direction.Z)
        local camera=camera_service(); local forward=camera.CFrame.LookVector; forward=Vector3.new(forward.X,0,forward.Z)
        local right=camera.CFrame.RightVector; right=Vector3.new(right.X,0,right.Z)
        local team=rig():GetAttribute("Team")
        local teammate=s.team_check and team and team~=0 and state.model:GetAttribute("Team")==team
        local allowed=not teammate and (not s.ball_handler_only or held_ball(state.model)~=nil)
        local enabled=allowed and distance<=s.guard_range and direction.Magnitude>1 and not input:GetFocusedTextBox() and not ctx.runner.current and forward.Magnitude>.01
        local f=enabled and direction.Unit:Dot(forward.Unit) or 0; local r=enabled and direction.Unit:Dot(right.Unit) or 0
        local threshold=.3/math.max(.5,s.guard_strength)
        hold(scope,"W",f>threshold); hold(scope,"S",f< -threshold); hold(scope,"D",r>threshold); hold(scope,"A",r< -threshold)
        hold(scope,"LeftShift",enabled and s.guard_sprint)
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
        if state.pending and os.clock()-state.pending>=s.block_delay and os.clock()-state.pending<.8 and state.model:GetAttribute("InAir")==true and os.clock()-state.last>1 then
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
            tracks=function()
                local c=current()
                local active=c and c.Animation and c.Animation.Animator
                return active and active:GetPlayingAnimationTracks() or {}
            end,
            active_track=function(name)
                local c=current(); local animations=c and c.Animation and c.Animation.Animations
                local wrapper=animations and rawget(animations,name)
                local track=wrapper and wrapper.AnimationObject
                return track and track.IsPlaying~=false and wrapper.IsPlaying~=false and track or nil
            end,
            begin=function() shoot:Fire({Shoot=true,Input="E"}) end,
            lead=function()
                if not Engine.settings.ping_compensation then return 0 end
                local ok,ping=pcall(function() return ctx.player:GetNetworkPing() end)
                return ok and math.max(0,math.min(.25,ping*Engine.settings.ping_factor)) or 0
            end,
            calibrate=function() return Engine.settings.auto_calibrate end,
            refine_good=function() return Engine.settings.practice_refinement end,
            good_correction=function() return Engine.settings.good_correction end,
            snapshot=function()
                local c=current(); local a=c and c.data and c.data.Attributes or {}; local movement=c and c.Movement and c.Movement.lastMoveDirection; local offset=a.meterOffset
                return {movement=movement and movement.Magnitude,shot_speed=a.ShotSpeed,meter_x=offset and offset.X,meter_y=offset and offset.Y,animation=a.BaseAnimation}
            end,
            telemetry=function(event) if Engine.record_shot then Engine:record_shot(event) end end,
            held=function()
                if Engine.auto_shoot_held then return true end
                for _,device in ipairs(devices) do
                    for _,action in ipairs(device.actions) do
                        local ok,down=pcall(device.component.IsActionDown,device.component,action)
                        if ok and down then return true end
                    end
                end
                return false
            end,
            release=function() shoot:Fire({Shoot=false}); Engine.auto_shoot_held=false end,
            feedback=function(scope,callback)
                local service=services.InterfaceService
                local signal=service and service.ShowFeedback
                if not signal or type(signal.Connect)~="function" then return false end
                local connection=signal:Connect(function(model,_,timing)
                    local c=current()
                    if c and c.data and model==c.data.model then callback(tonumber(timing)) end
                end)
                scope:defer(function() connection:Disconnect() end); return true
            end,
        }
    end
    Engine.release_profiles={}
    Engine.settings.practice_refinement=false
    Engine.settings.good_correction=true
    Engine.release_storage_status="No saved shot timing yet"
    local timing_file="pivot_release_timings.json"
    local timing_game=tostring(game.GameId or game.PlaceId or 0)
    local timing_user=tostring(ctx.player.UserId or 0)
    function Engine:validate_release_timings(data)
        assert(type(data)=="table" and data.version==1 and data.game==timing_game and data.user==timing_user,"Shot timing file belongs to a different game or player")
        assert(type(data.profiles)=="table","Invalid shot timing profiles")
        local result={}; local count=0
        for key,item in pairs(data.profiles) do
            count=count+1; assert(count<=512,"Too many shot timing profiles")
            assert(type(key)=="string" and #key<=300 and type(item)=="table","Invalid shot timing entry")
            local ratio=Core.bounded(item.ratio,.25,.85); assert(ratio,"Invalid saved release ratio")
            local copy={ratio=ratio}
            for _,field in ipairs({"early","late","ceiling","good_center"}) do if item[field]~=nil then copy[field]=assert(Core.bounded(item[field],.25,.85),"Invalid timing bound") end end
            for _,field in ipairs({"perfect","dunk"}) do if item[field]~=nil then assert(type(item[field])=="boolean","Invalid timing flag"); copy[field]=item[field] end end
            if item.good_attempt~=nil then assert(type(item.good_attempt)=="number" and item.good_attempt%1==0 and item.good_attempt>=0 and item.good_attempt<=6,"Invalid refinement count"); copy.good_attempt=item.good_attempt end
            result[key]=copy
        end
        return result,count
    end
    function Engine:save_release_timings()
        local data={version=1,game=timing_game,user=timing_user,profiles=self.release_profiles}
        self:validate_release_timings(data)
        assert(type(writefile)=="function","File writing unavailable")
        local raw=game:GetService("HttpService"):JSONEncode(data)
        writefile(timing_file,raw)
        assert(type(readfile)=="function" and readfile(timing_file)==raw,"Shot timing file readback failed")
        self.release_storage_status="Shot timing saved automatically"
    end
    function Engine:read_release_timings()
        assert(type(readfile)=="function","File reading unavailable")
        local raw=readfile(timing_file); assert(type(raw)=="string" and #raw<=262144,"Shot timing file is too large")
        local profiles,count=self:validate_release_timings(game:GetService("HttpService"):JSONDecode(raw))
        -- Preserve the table used by an active Auto Green instance.
        for key in pairs(self.release_profiles) do self.release_profiles[key]=nil end
        for key,item in pairs(profiles) do self.release_profiles[key]=item end
        self.release_storage_status="Restored "..count.." saved shot timings"; return count
    end
    function Engine:timing_changed()
        local ok,err=pcall(function() self:save_release_timings() end)
        if not ok then self.release_storage_status="Shot timing kept this session only: "..tostring(err); ctx.report(self.release_storage_status) end
    end
    if type(readfile)=="function" then
        local ok,err=pcall(function() Engine:read_release_timings() end)
        if not ok and type(isfile)=="function" then local exists,found=pcall(isfile,timing_file); if exists and found then Engine.release_storage_status="Saved timing could not load: "..tostring(err) end end
    end

    add("meter_release","Auto Green","Shooting","Earlier animation release with automatic Early/Late correction. Keyboard/controller. Live green timing remains experimental.",{start=function(scope)
        character()
        local adapter=shooting_adapter()
        adapter.paused=function() return input:GetFocusedTextBox()~=nil or ctx.runner.current~=nil end
        adapter.report=ctx.report
        adapter.failed=function(err) registry:disable("meter_release"); ctx.report("Auto release stopped / "..err) end
        adapter.profiles=Engine.release_profiles
        adapter.changed=function() Engine:timing_changed() end
        local state=Core.animation_release(scope,adapter)
        if Engine.attach_shot_hud then Engine:attach_shot_hud(scope) end
        local feedback=adapter.feedback(scope,function(code) state:feedback(code) end)
        state:step(); assert(not state.error,state.error); ctx.report("Auto Green on / "..Engine.release_storage_status..(feedback and "" or " / feedback unavailable"))
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
-- Additional controls use the existing game adapter and restore local changes on disable.
    local function client_parts()
        local scripts=ctx.player:FindFirstChild("PlayerScripts")
        local aero=scripts and scripts:FindFirstChild("Aero")
        assert(aero,"Game client unavailable")
        local controller=require(assert(aero:FindFirstChild("Controllers"):FindFirstChild("Player"),"Player controller unavailable"))
        local keyboard=require(assert(aero:FindFirstChild("Modules"):FindFirstChild("Components"):FindFirstChild("Input"):FindFirstChild("Keyboard"),"Keyboard adapter unavailable"))
        return controller,keyboard
    end
    local function local_state() local controller=client_parts(); return assert(controller:GetCharacter(),"Enter a court first") end
    local function opponent_near(distance,handler_only)
        local mine=root(); if not mine then return nil end
        local mymodel=rig(); local team=mymodel and mymodel:GetAttribute("Team")
        local best,best_distance
        for _,who in ipairs(players:GetPlayers()) do
            if who~=ctx.player then
                local model=rig(who); local part=root(who)
                local teammate=Engine.settings.team_check and team and team~=0 and model and model:GetAttribute("Team")==team
                if part and model and not teammate and (not handler_only or held_ball(model)) then
                    local d=(part.Position-mine.Position).Magnitude
                    if d<=distance and (not best_distance or d<best_distance) then best={model=model,part=part,who=who}; best_distance=d end
                end
            end
        end
        return best
    end
    function Engine:run_combo()
        local s=self.settings
        local steps,err=Core.parse(s.custom_combo,40,s.combo_delay); assert(steps,err)
        local ok,message=ctx.runner:start(function(token)
            for _,step in ipairs(steps) do
                if not ctx.runner:step(step.keys,step.hold,token) or not ctx.runner:wait(step.gap,token) then return end
            end
        end,function(success,result) ctx.report(success and "Combo finished" or tostring(result)) end)
        assert(ok,message)
    end
    add("dribble_macros","Dribble macros","Dribbling","Runs your custom sequence from its assigned keybind",{start=function(scope,s)
        assert(s.combo_bind~="F8" and s.combo_bind:match("^F%d+$"),"Choose an F1–F12 combo key other than F8")
        local n=tonumber(s.combo_bind:sub(2)); assert(n and n>=1 and n<=12,"Choose F1–F12")
        assert(Core.parse(s.custom_combo,40,s.combo_delay))
        local link=input.InputBegan:Connect(function(event,processed)
            if not processed and not input:GetFocusedTextBox() and event.KeyCode.Name==s.combo_bind and not ctx.runner.current then
                local ok,err=pcall(function() Engine:run_combo() end); if not ok then ctx.report(tostring(err)) end
            end
        end)
        scope:defer(function() link:Disconnect() end)
    end,conflicts={"dribble_library"}})
    add("auto_ankle","Auto ankle breaker","Dribbling","Attempts your dribble combo near an opponent; the game decides ankle breaks",{start=function(scope,s)
        local _,keyboard=client_parts(); assert(keyboard.Services.InputService.Dribble,"Dribble endpoint unavailable")
        assert(s.ankle_combo:match("^[ZXCVH]+$") and #s.ankle_combo<=8,"Use up to 8 Z/X/C/V/H inputs")
        return {keyboard=keyboard,last=-10}
    end,step=function(_,state,s)
        local c=local_state(); local attributes=c.data.Attributes
        if not ctx.runner.current and not input:GetFocusedTextBox() and held_ball(rig()) and attributes.Action=="" and opponent_near(s.ankle_range,false) and os.clock()-state.last>=s.ankle_delay then
            state.last=os.clock(); state.keyboard.Services.InputService.Dribble:Fire(s.ankle_combo,true,c.Movement and c.Movement.lastMoveDirection or Vector3.zero)
        end
    end,interval=.1,conflicts={"dribble_library"}})
    add("dribble_glide","Dribble glide","Dribbling","Adjusts the local movement velocity during dribble actions",{start=function()
        local c=local_state(); assert(c.Movement and c.Movement.MovementVelocity,"Movement velocity unavailable")
    end,step=function(scope,_,s)
        local c=local_state(); local a=c.data.Attributes
        if type(a.Action)=="string" and a.Action:lower():find("drib",1,true) then
            local movement=c.Movement; local direction=movement and movement.lastMoveDirection; local mover=movement and movement.MovementVelocity
            if mover and direction and direction.Magnitude>.1 then
                local velocity=mover.Velocity; local flat=Vector3.new(direction.X,0,direction.Z)
                if flat.Magnitude>.1 then scope:set(mover,"Velocity",flat.Unit*s.glide_speed+Vector3.new(0,velocity.Y,0)) end
            end
        end
    end,conflicts={"fly"}})
    add("auto_takeover","Auto takeover","Player","Sets the observed local Takeover state when TakeoverFill reaches your threshold; server effects are not guaranteed",{start=function()
        local a=local_state().data.Attributes
        assert(type(a.TakeoverFill)=="number" and type(a.Takeover)=="boolean","Takeover state unavailable")
    end,step=function(scope,_,s)
        local a=local_state().data.Attributes
        if a.TakeoverFill>=s.takeover_threshold and not a.Takeover then scope:set(a,"Takeover",true) end
    end,interval=.1})
    add("auto_shoot","Auto shoot","Shooting","Starts a shot while holding the ball within range; requires Auto Green",{start=function(scope)
        assert(registry.active.meter_release,"Enable Auto Green first")
        local adapter=shooting_adapter()
        scope:defer(function() if Engine.auto_shoot_held then pcall(adapter.release); Engine.auto_shoot_held=false end end)
        return {adapter=adapter,last=-10}
    end,step=function(_,state,s)
        if not registry.active.meter_release then registry:disable("auto_shoot"); return end
        local a=state.adapter.attributes(); local mine=root()
        if not a or not mine or input:GetFocusedTextBox() or ctx.runner.current then return end
        if Engine.auto_shoot_held then
            if os.clock()-state.last>1 then state.adapter.release() end
            return
        end
        local _,distance=nearest_rim(mine.Position)
        if held_ball(rig()) and a.Action=="" and a.ReleasedShot~=false and distance and distance<=s.shot_range and os.clock()-state.last>=1.2 and not state.adapter.held() then
            state.last=os.clock(); Engine.auto_shoot_held=true; state.adapter.begin()
        end
    end,interval=.03})
    add("rim_range","Range circle visualizer","Shooting","Draws the auto-shoot radius around the nearest rim",{start=function(scope)
        local folder=Instance.new("Folder"); folder.Parent=ctx.gui; scope:defer(function() folder:Destroy() end)
        local lines={}; for i=1,48 do lines[i]=line(folder) end; return lines
    end,step=function(_,lines,s)
        local mine=root(); local rim=mine and nearest_rim(mine.Position); local camera=camera_service()
        for i,object in ipairs(lines) do
            object.Visible=false
            if rim and mine then
                local a=(i-1)*math.pi*2/#lines; local b=i*math.pi*2/#lines; local center=Vector3.new(rim.Position.X,mine.Position.Y-2.8,rim.Position.Z)
                local pa,va=camera:WorldToViewportPoint(center+Vector3.new(math.cos(a)*s.shot_range,0,math.sin(a)*s.shot_range))
                local pb,vb=camera:WorldToViewportPoint(center+Vector3.new(math.cos(b)*s.shot_range,0,math.sin(b)*s.shot_range))
                if va and vb then draw_line(object,Vector2.new(pa.X,pa.Y),Vector2.new(pb.X,pb.Y)) end
            end
        end
    end})
    local meter_styles={Vertical=true,Rocket=true,Bat=true,Funnel=true,Hoop=true,Roblox=true,None=true}
    add("meter_style","Meter changer","Shooting","Displays your selected local meter style; does not alter shot timing",{start=function(scope,s)
        assert(meter_styles[s.meter_style],"Choose a supported meter style")
        local model=character(); local packet_controller
        local scripts=ctx.player:FindFirstChild("PlayerScripts"); local aero=scripts and scripts:FindFirstChild("Aero")
        local controllers=aero and aero:FindFirstChild("Controllers")
        if controllers and controllers:FindFirstChild("Meter") then packet_controller=require(controllers:FindFirstChild("Meter")) end
        return {model=model,controller=packet_controller}
    end,step=function(scope,state,s)
        assert(state.model.Parent,"Character removed")
        if state.style~=s.meter_style then
            if state.clone then state.clone:Destroy(); state.clone=nil end
            state.style=s.meter_style
            if s.meter_style~="None" then
                local source=state.model:FindFirstChild(s.meter_style.."Meter",true)
                assert(source and source:IsA("BillboardGui"),"Selected meter is unavailable on this character")
                local clone=source:Clone(); clone.Name="PivotMeter"; clone.Parent=source.Parent; state.clone=clone
                scope:defer(function() clone:Destroy() end)
                local _,keyboard=client_parts(); local configs=keyboard.Modules and keyboard.Modules.Config and keyboard.Modules.Config.Meters
                local config=configs and configs[s.meter_style]
                if config and config.ShowData then
                    for name,properties in pairs(config.ShowData) do
                        local object=clone:FindFirstChild(name,true)
                        if object then for property,value in pairs(properties) do object[property]=value end end
                    end
                else
                    for _,object in ipairs(clone:GetDescendants()) do if object:IsA("ImageLabel") then object.ImageTransparency=0 end end
                end
            end
        end
        local active=false
        for _,object in ipairs(state.model:GetDescendants()) do
            if object:IsA("BillboardGui") and object~=state.clone and object.Name:match("Meter$") then
                if object:GetAttribute("Active")==true then active=true end
                scope:set(object,"Enabled",false)
            end
        end
        if state.clone then
            state.clone.Enabled=active
            local fill=state.clone:FindFirstChild("FillGradient",true)
            local offset=state.model:GetAttribute("meterOffset")
            if fill and offset then fill.Offset=offset; fill.Rotation=state.model:GetAttribute("meterRotation") or 0 end
            local packet=state.controller and state.controller.ActivePackets[state.model]
            local green=state.clone:FindFirstChild("Meter_Green",true)
            local gradient=green and green:FindFirstChildWhichIsA("UIGradient",true)
            if gradient and packet and packet.greenGradient then gradient.Transparency=packet.greenGradient.Transparency end
        end
    end,conflicts={"hide_meters"}})

    local basketball_texture_data={["Sasuke"]={shirt="iVBORw0KGgoAAAANSUhEUgAABJIAAAReCAYAAACMxxrQAAGdlElEQVR42uy9C7xdRXn3/0yAJCBBTU4I55ILFyFeQESSEFAU2yo3SQK2/n3rFdq+BtRq+/+/Rat4o0rf9+37eQtIEC+11ksVyQUt4gXwUi+5iIiIARQBcw4lBGmJgDknyfy71t5rrZlnnmdm1t4nVMnva0832Xvt2WvNmpm11jO/+T1TCAAAAAAAAAAAAACADKagCgAAAAAAAAAAAABADggkAQAAAAAAAAAAAIAsEEgCAAAAAAAAAAAAAFkgkAQAAAAAAAAAAAAAskAgCQAAAAAAAAAAAABkgUASAAAAAAAAAAAAAMgCgSQAAAAAAAAAAAAAkAUCSQAAAAAAAAAAAAAgCwSSAAAAAAAAAAAAAEAWCCQBAAAAAAAAAAAAgCwQSAIAAAAAAAAAAAAAWSCQBAAAAAAAAAAAAACyQCAJAAAAAAAAAAAAAGSBQBIAAAAAAAAAAAAAyAKBJAAAAAAAAAAAAACQBQJJAAAAAAAAAAAAACALBJIAAAAAAAAAAAAAQBYIJAEAAAAAAAAAAACALBBIAgAAAAAAAAAAAABZIJAEAAAAAAAAAAAAALJAIAkAAAAAAAAAAAAAZIFAEgAAAAAAAAAAAADIAoEkAAAAAAAAAAAAAJAFAkkAAAAAAAAAAAAAIAsEkgAAAAAAAAAAAABAFggkAQAAAAAAAAAAAIAsEEgCAAAAAAAAAAAAAFkgkAQAAAAAAAAAAAAAskAgCQAAAAAAAAAAAABkgUASAAAAAAAAAAAAAMgCgSQAAAAAAAAAAAAAkAUCSQAAAAAAAAAAAAAgCwSSAAAAAAAAAAAAAEAWCCQBAAAAAAAAAAAAgCwQSAIAAAAAAAAAAAAAWSCQBAAAAAAAAAAAAACyQCAJAAAAAAAAAAAAAGSBQBIAAAAAAAAAAAAAyAKBJAAAAAAAAAAAAACQBQJJAAAAAAAAAAAAACALBJIAAAAAAAAAAAAAQBYIJAEAAAAAAAAAAACALBBIAgAAAAAAAAAAAABZIJAEAAAAAAAAAAAAALJAIAkAAAAAAAAAAAAAZIFAEgAAAAAAAAAAAADIAoEkAAAAAAAAAAAAAJAFAkkAAAAAAAAAAAAAIAsEkgAAAAAAAAAAAABAFggkAQAAAAAAAAAAAIAsEEgCAAAAAAAAAAAAAFkgkAQAAAAAAAAAAAAAskAgCQAAAAAAAAAAAABkgUASAAAAAAAAAAAAAMgCgSQAAAAAAAAAAAAAkAUCSQAAAAAAAAAAAAAgCwSSAAAAAAAAAAAAAEAWCCQBAAAAAAAAAAAAgCwQSAIAAAAAAAAAAAAAWSCQBAAAAAAAAAAAAACyQCAJAAAAAAAAAAAAAGSBQBIAAAAAAAAAAAAAyAKBJAAAAAAAAAAAAACQBQJJAAAAAAAAAAAAACALBJIAAAAAAAAAAAAAQBYIJAEAAAAAAAAAAACALBBIAgAAAAAAAAAAAABZIJAEAAAAAAAAAAAAALJAIAkAAAAAAAAAAAAAZIFAEgAAAAAAAAAAAADIAoEkAAAAAAAAAAAAAJAFAkkAAAAAAAAAAAAAIAsEkgAAAAAAAAAAAABAFggkAQAAAAAAAAAAAIAsEEgCAAAAAAAAAAAAAFkgkAQAAAAAAAAAAAAAskAgCQAAAAAAAAAAAABkgUASAAAAAAAAAAAAAMgCgSQAAAAAAAAAAAAAkAUCSQAAAAAAAAAAAAAgCwSSAAAAAAAAAAAAAEAWCCQBAAAAAAAAAAAAgCwQSAIAAAAAAAAAAAAAWSCQBAAAAAAAAAAAAACyQCAJAAAAAAAAAAAAAGSBQBIAAAAAAAAAAAAAyAKBJAAAAAAAAAAAAACQBQJJAAAAAAAAAAAAACALBJIAAAAAAAAAAAAAQBYIJAEAAAAAAAAAAACALBBIAgAAAAAAAAAAAABZIJAEAAAAAAAAAAAAALJAIAkAAAAAAAAAAAAAZIFAEgAAAAAAAAAAAADIAoEkAAAAAAAAAAAAAJAFAkkAAAAAAAAAAAAAIAsEkgAAAAAAAAAAAABAFggkAQAAAAAAAAAAAIAsEEgCAAAAAAAAAAAAAFkgkAQAAAAAAAAAAAAAskAgCQAAAAAAAAAAAABkgUASAAAAAAAAAAAAAMgCgSQAAAAAAAAAAAAAkAUCSQAAAAAAAAAAAAAgCwSSAAAAAAAAAAAAAEAWCCQBAAAAAAAAAAAAgCwQSAIAAAAAAAAAAAAAWSCQBAAAAAAAAAAAAACyQCAJAAAAAAAAAAAAAGSBQBIAAAAAAAAAAAAAyAKBJAAAAAAAAAAAAACQBQJJAAAAAAAAAAAAACALBJIAAAAAAAAAAAAAQBYIJAEAAAAAAAAAAACALBBIAgAAAAAAAAAAAABZIJAEAAAAAAAAAAAAALJAIAkAAAAAAAAAAAAAZIFAEgAAAAAAAAAAAADIAoEkAAAAAAAAAAAAAJAFAkkAAAAAAAAAAAAAIAsEkgAAAAAAAAAAAABAFggkAQAAAAAAAAAAAIAsEEgCAAAAAAAAAAAAAFkgkAQAAAAAAAAAAAAAskAgCQAAAAAAAAAAAABkgUASAAAAAAAAAAAAAMgCgSQAAAAAAAAAAAAAkAUCSQAAAAAAAAAAAAAgCwSSAAAAAAAAAAAAAEAWCCQBAAAAAAAAAAAAgCwQSAIAAAAAAAAAAAAAWSCQBAAAAAAAAAAAAACyQCAJAAAAAAAAAAAAAGSBQBIAAAAAAAAAAAAAyAKBJAAAAAAAAAAAAACQBQJJAAAAAAAAAAAAACALBJIAAAAAAAAAAAAAQBYIJAEAAAAAAAAAAACALBBIAgAAAAAAAAAAAABZIJAEAAAA7MU8fP/DC1ALAG0LAAAAALkgkAQAAADsxQ/6dr99bvrVg9tvQm2AyaRoU0XbQjAJAAAAePJhUAUAAADA3vuwT0Qv7twR2HvMxK5Tnj749HtQM6BXyuDkvvv+A9oVAAAA8OQFgSQAAABgL8QLItV3BXjoB73TDSL9IrzbtPfMHDjoUNQQAAAA8OQAS9sAAACAvYwbPnvzT4MgUoE15VK3h7c+8nrUEmjDww9uf7EYROq2qy9e9f2HUUsAAADAkwMokgAAAIC9iCve+sWHt973708bOXKAzv7LFyh3B/Yea80nZs2e8V7UGEhRBB6tMf+gfb767/6Vtty5jeY98+Cfnfs3L3sGagwAAAD43QaBJAAAAGAv4eN//ZW77vvp1iOqfx8064AymFS8Slii9yCYBGI89OD2d//nzeR7pM8eeegx+vonbi6DSBUIJgEAAAC/+yCQBAAAAOwF8CBSBYJJoFce2vrIPxhjxGWQRRCpUCIVr5wjjh/+xqvf8ZJTUIMAAADA7yYIJAEAQIIjDn+OLR+orSVjjPfaDlsOu5YsGep+39Rvd15bl+N83S0nqzwrlCp8Xfog4weTu1Eev/Ffc/ZH2yJRn3p5yieJHYiVc+sPbvW2vXTlarEK3rLqbO/fRx93TPsGUR++3j7/n5eeSwc9omdhL4JIi1++kJ61dJ74+ejYKL301FPdU/eef/u3exBc2ouYOfOQd/9nP62VR5/+5D/RksVLxG0LBVIRRIpy8H/Q33/+4vz2HnT37jgqfP/uzb/oqf8dtjDPD9y44zh1hi91nFRvv5sN3fIyNhfKdcvJ+Hm1/HB/eiqPH185HnWH+b7LE6qjZX3Hysur9/gP5u+OCa+DbU67tiWraO9nWpcnfCrtdrsKjP+adILjP9Sy/vMqRN/7RIeXTkf059r1CL3+81tM9Did+4hgx3spL1E/qd31x8esLyROT2K8zTxAfr9VvN519217VWwFZtsAAJB77eje5Lmv7p+0TXj1ofriVX6PjPNaldn9vmnuK+viTPf/maoc07y65ZDzfefV+2MbBOVV/zLezzqv3f/wNnDLIwr30v15E7y6f9I29U+yPW22Md6ru4+8LpryDD8zzfflLwR1W5djqPebk7oKjFNe00b4HrJmpbbPVyWCSNRVj2z44mZa/6XN4ufDQ8P01euvp5Hh4bLMKVPMewYHD/3CvHnzno6R4cnNU5867+mzZg1+4T/P+3uKpjV3eJi+ceON/QWRCrY+lf78le+s+w3V7dw446fzaoT2zsZMdyzu7flA6ENkwrFeGKP9XXXHaH8UdMcJf6w24RhthPLYWO2P2OFYTcJY7R+Dex0iYTT0D8+7ILnny6sjdi1zvxIr3Tv/Wnnh+OsfsHSFqNoXhfXvlSdf08J6d8+q82dIuKZJ1zYjXNuEaySvLyNffIxzjTP8WundQ0hnN6zUpj+S+Me30W4y3Hon516CV4t7DNIxenXqXP14vZvEPYV8b0HqvQUJ9xbBjVBQ/yTUv1MH0h2R8cc495yZYIzjdep1BLHHeuW5bc34fZeEe1nWcaU7Jb883meMUMHB/WQzvkn/c7cJ699tKiYsj99nR+6hxHspE97re/dk0Xt+BJIAAAB0qea7K6VH8Vr+z1rvPfc1Xp67rS0nfqzzWv5fJY6xfCeCf3TLq0ut/s979f7YBs33LYX/IqG87n9Y9wNbv1r/KMOfp6Yc6x6kFQ683sb/rl8e+816X5wvOn/87eD7sS+Qd6h1/dXnro9GZq11ymvamLSHcgNt2ukpx7+MZiSCSG4waX0imPTxj32MVr7xjVWbPWfnzikbh4fn/R5Ghycns2YN/96+++7cSETnFGf8nOVn00033EQjQyPi9kXbyQoidTlgx8H0lj96Z7ebW2cstHKjdpt7MER0+5+1fXQ/q4zxTr+sP9N3URv9qv+RO8azoZOEcm0wRksjvtUuDcFY7e9DtxxrxZ+XK8ofBG13zK7qySuPX8PESuPlUXNNrMulyDVRvioENSRcE/1xXN7ARs+qvxvhtcy5plnrXe+US5NQ/+pFp653curJsp927xLCeg+P2a9/6ZLcbKNdjd2rFK+OsP6d8viJFq56/Ffdeg/uKYKK6OdeQr55YKfDfxXvKYIOHt5beLtvg3q3lqItRuuuft8Uxly5w8rjJPl9nWw4vrEGGB52UB7vu6w8qflaYZy0bnmxViTfO9Wvtqkn716sj+vMk4l9UQUAAJBHM7nLZ2ykJ/pK6spWgHnl8RkN/4escZcYSCvJxDlLZz+7G3ZfO+W5K9NMU065mWk27y6e836w+aC7f6ZeUCFVRPPzHWm0US68dTnOq1j/bjnO7jS1bpwFHk45hu1QJbZ2yxHqMxBSO/U5deq08pPx8XHn6A1NnTpVvJ/bZ799ytddE7vkRmWbf9flEJXluyv3pk2bWr5OTIx3b2Q6e+ht3y3zBYtOpqOmv1D8XW1/ivc3XX9X+d9LzlwY7GcRTLpg5fnlG6uuvKKoh8Mt2a8PDR329rGxuy/BKPFkCiINXTh12n4f7LTzCfr0P36yUSGZ8F68MNW+Y9No2YZy29uOR3fSjH0PoZeeeCZ97btfqrtn2c6L9rxj3FliZWnatE6/27Fj3JtlL7Yvy9sxzqfORar94UyfPq3sX26/K3DLb8ZtfmEgfamasMSiHm/l0dMdQDvlGWGbZtDwx29lrZC3VE1SLZFSdWwtjbekQ1woFioZ/OLZN8SlOnwH2dWOXd+iS9Xc8tjXmqunlduOIe+6Ip6xujxTX6ekpTf+9cRIh+dcTZSlauLCSAoX6rB2GVuk2Kl30/0ZfpwUbOvVv3Kv5O2PcEJMvejJfw2rVzk+8pe+1fcHatfn9xnyNlV9N/cb2so1ZaGVIbFdhs2/uf/y619Z+tYtz4j9iQIFkt+fnKVq2i/wccBEFvJF1uoZdn/rVZpzj1Pd38YW+/nVafKWvikNQNaz8dNuvOuNqC5nqqW9HSiSAAAggRVmKVwlUvgnz1oHMyNuOUJ5njolR0EUlMdm6ZXZPyu8evNBntrGmZ10ZkK92VbLy/Nnu+s/YfbQSuVYoRwbzFmJx+LvF5u9JQpUYN7RB+WRUI77E/0rkvg582fB2Gswi9m0q0XPP56u/OjltPiMI3vaj0KZ9Il3fFX9/IKVK+krX76ehgYP6dbB7g8ODi5YOzx8xAhGjN9tZs4cHpk1MLjWkv1g0RCL4OGn3CCSQKFCuv179/X0e895wQL664v/kpYsXty0d79nO7PRVlQgef2lH0WSFcZSmzM2Uzg2u2OK1V4pKE+SNXhjM3/V1KxEQXlWGFvlfWMKJaYa9WfshfL4eSF+TfQVFdL45tc/VybZ4FoWXNPc0dzK9SSXJ1w7tGsj8Wujey2LXBuD+ufXSP3aJpdDviKM1ZenaKl7lJXrP1aOVl9OGXzvpfrmZUvlBepmm653K9SNfG/C7wHYPYV3Tmyk/jVFmNTWXIWNUx5XGcXuLaxyL8BUnFYYK1NjpldvruJGUnCx+gnU+cGrP75542PkHiy8F3PLcRVhTDlkI2OupExy6ylWnlIu7cUKJQSSAAAggRHWTYu+GYn10qatR5LijUSK+5DsuyHZFwj+D6T5bpDskSQbHYT+D5KPRD8eSdTSx0DySKKYR5IRPJIo8EMYnxgvVUG8nOK9ifGJ4NwXSoxAjURMme54JFXlcM+Y4r1SLcFm3or3JiY6v1v4GBVL0AoWnXYUnfLHz83eH/f9YqlbEUwqs27ZUFFXBBg+fOWH6U/OO69qp8t27955y9DQgldh1PjdZGBg6FVmn923EJllxTl9+Rln0le//JUwiNRtD1UbKXyRctuVy7K3LC3b6MjwCP3tJX9Lc0dGygY9vmOCqYs67b14r9P+/bGyeG+821+8sdfKKz60/dnR/V0+1hdlF/uU65FESY8kwc+OdI8kkjySTOiRVDvTaGqjiEdS4JXkjLnUwiOJBI8kIyhvjSGhdMEjifI8knK9kkKPKskmKHJto3b+f269k+RHE73GUdrTiHn0kOApZaIeVSYo1/dICr2Sgt9065/iXkkpjyQjn2DBI0nyqOrdI4ky/Rcl30Qj3GMYfo+R7ZFkevJIMpkeSSR4JJnWHknk3zFleCQZwSOpGdpdj6TQK4liXkmGol5JaY+khN+kEbySSPdKQiAJAABAZLaaz+704pFkg9nvwCMpw4eDIk4Ztq1HEmkeSTRJHkmxn+d+BhGPJMkfgfsQiD4GVvZGyvJIorhHEu1ZjyQSPJJI8UgaHhqi66/7svd2kYnt9R94aZmZrS1VCveYb1Kx1G3lG1dWb82ylj4zODj/qjlz5jwFo8bvBsW5mjlz8CpL9jO0m2YVjemSv/kgXfJBfbVioUCqA40tKdri2X/5Aho5cqB+rwgmfeqTn6KR4SHFDYWPxySMx/3ODEc8koh7JNnMsTnTI4l0C5WUjx0JHkm+hY1vkiJ5JLmKD0o5r6geSbJ6lFTLFXlU9zx6SFDVkqwE072SyPc0inglxUyUkh5JUd8/UjySrODXF17bvONikpVAyaJ6JJFyFbVZHknWCooyG78qc68k+ZaBKbiiXkmRX0t5JFm93mmSPJIoyyPJtvNIslb1SiLq0U9OUnBRrkdSc0ayPJISu8l1chRVpUaar6h4EspJ+ExKHknkKcIIXkkIJAEAQDtSWduC2WrJR8P5hzHa7GuLWW9JmRTNDKRkupGywPFShaxt4uxtrqJIyHBjxBlE0jOtSLO20uyhEWYPpVlDiimUKJw19CYn+8/aFptNIyF7G//uouOPjz649xpMiplwU7nU7fxuVrehqrP86ZQp+982ODj/bIwcv93MmjV49s6d+9xmppg/LRpRGdD5x0/ROWefo36nCC4Wnki9IAWR3GDS2SvOado76e1dVIqa/maGTSJrmD+2m8SYTEJGzXBmXVSNSmOzEfMZheWRJMxpo0Ay2mHVle7P2AtZ28jPHkaiR1LsWkiCIkbKZCofcFytK6trTTQDqXGuYaGmRMpoKqpsTSRbm5EVSIGyiV8PcrOGCfUeKsCodda2aLY2IkWJJKuoolnbctXNrK6lCkllgo1mcM3NBKuonaW8fEa7pzByJlcvW5twTk3GGOlmunSVSJpHEik+of64JimQEtnahLtXiiqRJCEdy+Ap3TtROvOtXJ7pIUMzAkkAAAAYKUVS4J+hZJbp3SOJJskjicQMKWrWNuaR5CmJbF5mmv48kugJ9EiipEcSaT4GNMkeSaR5JLHfcGbR1l57LX1o1arWD/A5VL5JmgKlk9Xt43T+ypVV+1xAZK4ZHJz/0ZGRkZkYQX67OOigkZkDA4MfJUPXkLELikb35gveRDfdcGPpV6QFFd2lbG0p2l5MHff3l11Kl15+qTyLLGXW2YMeSTRJHknq2NyvR5LgQaOrUHM9klIKp948kkjIHuYqbWK+L7JHkuT3R4rDkI341kiKmFAZE/dIkpQ2sso26h8oeCQRCQobxdMozJrnKpIkjySKeFRRtiIp8DRSs+UxTyPFI4myPZLCe4mURxLleiRxZUxwT0GtPJIoUMZwjyqnTkPBWZZHkpjlLtMjiXrwSKKWHkmyKlzwShI9knyfvLhHEsV96Ui/h0p6LkWyt8EjCQAAQJSUIik9S9HSI8kIk0MxBZHku2HUSUN51lX1k5BnXSk6i0vZPhLZHkmZPgam7exhahaSGR9MnTa1k8nJ+xlTvjetzOjmU2SJEjNFGbZEv3vuq3L4OvzivSJDG59NK97rZLQiuvLDV9K7LnqXWH7xAP/7rz+Oli5/prg/2n5W7wdL3Vj51VK3r33lK3TYggXVDp63a9e+m4eG5p+HUeS3g9mzh87bb+ruzcW5KU7gYQsOo8986jP0lje9WW2f7lK2VDuR3p//rIPLQKZW/h+/5tV02YcuK9+YPm1aN1OaP41d9ovpU5sxtttfpk+fWmZcCzySjJxYStvP6nf5jHtRtld+Qi1qkh5JklpU90gykkeSpEyS7fSCsVrySAoVSWqOsqhHkqR6oKhHD7HUbroiLOaRlPJGknwETdQbiQRFkkl49EiKJOnaFlEmiToTV5kU90gygtqWBGWS6rnUUpGUpUxyy0t4JKmKJCO72wRKJ+rNIymqTDJp38SkIizbI4l68kiiTI8kI3gkUWuPJKYkyvBISiqTDJFR/id6IzmydMkbKd8jSRqGQo8k74+gTEIgCQAA2s5Wx2ZjepidsMFsrJB5R/SDIMGXIHTMaOWRFPHfmByPJKu5Ayh+EopHkiXdc0n1NSDfgEJ5W/dIsnGPJLtnPZKsoESKre8vXgtl0stOO5XGxsaCzYpg0qLTj+o5o1vOUrehoSG66sNXddRJnR2bvdvSR+fPP/K6efMOfz5Gk/8aBgfnPX9weMF1xbkgsrOLM1OokL5y/fW0aNHx6vf6WcpWULS1ZW89UfxsdHS0DCJ9f8P3AyVSa9+PPj2SbMwjKao21T0/KNcjyeqWJ4HCSRzxrXZpUBROpGbWJM0bSax8IdtX0iNJqTxRESMokRS1b+iNJCljVAsk0jaw0bPq70bMG0n2SCL92sjrS/LqERUxmkeSYjLDjllTJJGYdY9U7x/FokuofyuqpEm56gWeRjbTI6nve4m0R5LN8kiidh5JgjeS7pEU766igovaeiQxJ6OURxJFDjsoT1Bu2bhHkuSN5GbNjLciktWuJCiTkKUNgSQAAOiV6PpwYTaWVI+k6q3QHyLw0cjwSOo5i1vEhyPmkWSyPZIyM9L0M4tIKV+JSBY3kpVJOR5JRRanOmubMxvWb9a2qpxOVriJYJ1/8d54nc2tOfdl1qqJca+NjN1/P5173nnlg7r0u0W2rCUvX5i1n9L75VK3t3+VHtn2mFj+0OBQ1zvpK7R40aJu9qvx0yYmdm0aHDz07wYGjpqBUeWJYWBgYMbAwODfTezcuWlix/hpRfMZGRqhb9xwQ0eFpGQ3K85tcY75UrY27aRQwBVtTSp/y5Yt9D8u/Ctav3G9N/YVbbzIoMZnj3fU2dz8WfZONreJ0COpZda2+nfZ2F5lhYv63ykeSWaPeCRR0iOp3qfWHknCJYupE3SPJOrBI8mIHknRbG1iljYStaqmtUeSyVTXSh5JCSWS6JGUytJGggIplq0t1yPJ0d94Hj2RbG2CwiaapY1ysrT52d9IUNi0UYDFPJJS9xC+uln3WzT9eiSJWdoiHklqljaTnaWNYh5J1N4jybTxSKKcLG2ZHkkm4pGUoUBKZmsz7ZRICCQBAACIIq4zj/hnaFnXbN8eSXaSPJL82T+b8oEI/A2UTCs5PhA9eSTZJ9AjySY9kqzmkWQn2SPJah5Jju+AN4sZzqJtGR0tg0kbN20Uf2/JmQvD5UYtSGV1o+5yt4vf//4ys1vTPnf/xb77/ubuOXPmvRkjzJ5l1uyhNxNNvdsS/UXVPt90fscLaXhoRP1ecU57zcpWUbStImugxPc3rKcXveQU+v7674tjoeyRZEUF0p7wSLKT5JEU9evoxyPJhh5JkldSO48kK3r2cNVoW48kS/ya6CsqRG+kqEeSDa5lwTXN85Cy2R5JVvTUiXkk2UDpkbw2BvUveyRJ1za5HOaRxOrLih5JVq7/WDlafblePSTVv1/fMY8km+2RZHWFjXYecz2SvHNiI/Wf55EUjGlueYFHku3JI8m6Ci5hrEyNmW09kmxLjyTreSQJ3khRjyTrZ82MeiTFxjUrK5ME370cjyQolBBIAgCAJOKsDrXP5GDaeiQp3kg9K5DCaTzFG8n482eRWVwSZnFNL5lWqIesbzk+BpJHEsU8kozgkUSCH0J8FrKftqZnaGGzaZnr+gtl0rsuukg14U4ZIOcEk3KMuN90/vn0teu/QmcvX17V1cCUKVMuPWRwwa1DQwtehZFmchkYGHrVrNmDtxpLl5KhgaLOT1i8mL5xw42hF5IUHPzi5p5/O2Xsvn7Denr1a16tZiIyJBoPBeOxNLve30yx0cf6thk1ox5Jgp9dZMZdVI0mFUphtrWYR1LvCiWjK5OYQokEz56w8qRMpmmPpFyvJFWhZDKvbdTO/8+td5L8aHJUuzFPI1WZFCqUSCuPYh5JgjJJUBJlKZRMjkLJyMokY5SciO6tTe/qZsr0X5Qu/ka4xzDCvUGeR5LpySPJZHokkeCRZFp7JJF/x5ThkWQEj6RmaJcUSsLoJnklGYp6JaU9khRlUkyhRFAoVeyLWy0AAMifrS4uFu6rPKOdmp2w5RWrU05nYqV6JWP9DG9Rq5BuOWTL61/zr2aWxXY/qF6D/bBGKSe+eefV3dIEpgPu/sTLs2TrCggqtH4Vfs2rCaqOoKzQakPLPDTUt5vvezVB7IDqAxN+Rq3oFo2s+nXjeQI0NgMRPwR3v0zVBjv7UyiTVl3ZCSRdUPoWyQ/+P/3efT0HEKoAxDNPnFcqnbSA0sXvv5ie//zj6YpVV9Box8Pp6N2WPjNnzvwLiMz/euCBe9ZhtOmdWbOGlhlD/58lOslYUzaLkcFhetOb3kTnrDg7+t1ChdRPAKmgUCAVy9k0isxsl11+md9fuq/cTiPlkVS182Y87rP/keJ1192/Tn3614FgYGIjEgU5yqgpp3t+jDO81A80XrnVeM6dbrr7VY/fSnnM98S65ZWvphmH3XL4YZFSHrdB8S5s5F3npPoO/P7q9uC3j3q/3PLkA2a/4o7r/uZsWCd5A2rqKbhOSKfL1q/Shdyr7/q1e5hSeYGJC/+nvz+WFeA202i/YvVurVEmPGy3/rV693eg3i+2mQnuE6xSAawc7decevfqn++PUu/N1tbfr7CBk/tF8W2nwoPj8yIXNiwvsCnyK8yrf6XFRLpr4IfUVDO7IVWCI4ELVlVOXe/N+MYqQtxNPk7y+8Z6fOMnyir7xca3pv0b7/4qmPSz8n18sH/sOWBvXuaGQBIAAGSSm6WhvlA5gSL/+YaXQ96re3E1boAniKQksuuY7obd1+Ki6n3dmqYcQ/VF2jg3U94PVg8x9ddM/RjDfrm+qShnpNxXfg/lllOXJ0dI/PKce1fnYcErJ9it5laiKS+sT6pvVg37uKmHqWVmNlt6pxjn4bDI5iY9x1YZogJfFhPeERe/WmRhK94rfY+cAFGRUapoV4UPk7uErty+65Xkzjq671M3o1vx+flVMMn6waTCM2nKPoa+t/anWfvP36/USXdu2EIvee3zaPiIWeLxrli+nBYvXkQbNmykVVdeQQ9ue6g4npMmxsdPOmRw3rcMmf97//33rsGo0yKAdPDICmN3v5XInNw575ZmDxxMK1Ysp7dc8Ga5vXUZ/dlDdOMnf0gPP/Drns57xUvPfT4tPGEuic9LRPRXF/4VXbNmdd3Op3Xb546ifdYDS7edF+12x7g3DnYyuXU8kdx27r4vTp0r/ZFTZGYr+lnRX9znKO93ic/Yu7+lBHaEByhjjSQsdAaCZrwpyzHa4Ri/PH/Y9x40vQCRplqSrifuAz2fUNEeX1n9hB5JzTc75RGbWDGiasnfXfmA5TiECS9nxlXo8BPkVa9T/7KSwd+N5nqlHnWgWvK3NO71KhKYs97ZFa4tRjk+54xJ9d7Uv9zmjGH1FBxnc39glMBQcJxKJi3x+Fhbq+8P1K7vey5ZR5EknaFmv9QGLtcmb5duOWpdOvUu/lzYLsNzY8L9qs+rG/DQf0G+IZX6kx5I585WwZnw+pMb0JH3p6lOo0a2xXK4YpvtV5C1zYt3KYGmyPMAAkkAAACi5CiS3GASiZlljBdoikuAwpnsZrG6oCASJTs8sxv7V6Ag4rujzcxWKiH9ANyZQVVtxGdmg/ARU1p5M4Nsj8tydAWWFWYa3foMjkNUdOm+AWEmm17aGDGPA38mlM+QiZ857VNSyF2xahXdcsuP6KoPXynuQ5HR7ajFc0t1Ua/+OI/86nFa+3+/S8ef+oyoOmnF8uEyoHTtF79EX/rStfSLe+4tzsHJlujkQw6Zt2Hq1Okfuu++Oz+J0UdnePjQ1+6Y+M0FtHv34qpBDA8O0VnLzqIL3nh+/Dw99FipQtt0/V197UMRhCxUSCNHDajbvP4Nb6B//c6/ejoFy/uN5eMe90jy23t1wx/0lz7GeKLQ446/rweKuNJHU5ZKShv3wYUrWKyodGh23FVMCQIdRRllgweplMJJVmyFAoFIoEhQaIT17b8GgQ8+nrMDDpPWGXlArydPrKz8kTeXJBX+1wJFjHb6NQUIU2aw8oJ64kpa9oDvKljk+uf1nq9I8pVhvDokZVnYIVKKJK6YCzqAprDR+jlTJHnKP7H+eX8yooK5nlRjija3nqQwDq/vsD+x/ZKaTaDccsoL7gP4ccYCRYJyK1Bsit2GhdGaI26agz9eBrODziSdp3BiA2Hge2SUG1otUBQo/CLZccntV1AmwXIcAAASHHH4c7KeTtoEmrTwE79FNsSXvsUDTzxkklqqlr9By831yFaLn7fCHZN+3Hp5yi+EcaNE9SYq3vn4Rz/4kffRpStXi195yyp/qdExzz9GPSD3wdk4ixjbBKncpUBDg4P08Y99rAzoxIIM/S51KoIMseVuFaNjo7R23Tr60BVX8Pb+CyL74X322fXR0dHRhzAiFcGj4Vm/GTd/Yoj+O5E9tA4gDY34CqQIRSa2IljYL6mlbFtGt9CrX/vqcnllrN+E3T17wAv4+U/v7qn/Hb7wMH3pWqub63AJhSAQSj/xiuVlfC2iAKHYfmUfoKCQaVWOkUfc5FK4nPKyq0HYYUWxQ9HnUuHrwRN+xq9kHJ8SiWhdDsWXHKXrP+8IotWhdojs1iJ8PW9pVnrvI2sDe6r/xBbJ+s9ugcnuGp6QXoIHTAEkS+QyxrVwyVkvDUAqJ6Uoite/q7i0rXwv77r7tr0qtgKzbQAAaBHmoUj2Nsr2SKrKc7dVMu/IFguK2sj6c848sRdPm5bKAsdyu4TlsewZUqYVNrdjWUZuKSNQkxom9EjiwgS/PPab9b44X3T++Nuyo4nyBfIONchA0k8js9bNaMIyg8RmygTFBomZXjrvFf5ERUY3zYS7XOp25sJyuVs/VMvdUgqnIqB1wcrz6Wtf+QqtrJQ0nd09lMhcsmvXPg8ecsj8jw0Ozj15bx2DZs+ee/Ks2SMf2zFODxq7+5IyiNQ9t2Umtq/fkAwiVV5WkxFEKgJIsSDSNauvoRe/5JROEElSm/CMUkIGIv/VD4wSUw25GTN7635WGeNZRp+Ef502+jVZiMLsalYcHMMsR1KpfNQSJDlCFjhSM2tSKmzHTmKQ7Ytl2KRAlGq1QSvIOuVna9OuifJVIagh4Zroj+PyBjZ6Vv3dCK9lQvY24ZqmnX6pfrxrm5g1zH8lRZMsX9t4/UuXZK6+lY9AsuiS69/PusfTIQp5trxfdes9uKcIKqKfewn55oGdDp5UTLinCDp4eG/h7b4V1MoUbTFadxWz3HnqZ7HDyuMky3LnZVcjsQGSkCyNlSfkLbSyKpWEezApa2a8FSn3TsI9FLK0hWBpGwAAZNJ4MygeGd5VKeaRVH1N9kpqvIPyPJKkPCxUyf3beiQ53kOaR1LgbaR6JFVfUzySiJXjvIr1n+uRRKwcw3aIeSSZHjySGo8IwRPAmr4aWbCGP0uxQXoWN2U2rfh+kdGtMOEufZPeuFLcrggmPXPpvL6WupGjgCkyeS1++UI1S1yV4W3F8mW0Zt06Wrd2LY3eP1ad0HOtnXLunDnzbzGGPjNlyj6fGxu7+74n87jz9KcPzdtvP3qltea/Ee0+dorTb0aGhmn5ihX0lgvelBXQmwyFGblL2Y7Ul7L98WtfTes3bGCeIUIGIbffGBLM7F0FnvGWd5CQVZP6yppoIkISnnWThH6nLFXbIx5JvokM90iinj2ShP1hSo+4R5Kc7Un3SNKW6vAdZGch8EaSFUTNG7keSWL1Omcz5pHkeiMllEiiR497d6C7ZYf6sl48kvjprTx6+HFSsK1X/8q9krc/wgkxmkdSaPaoeyQ5CpscjyTuoagqkTxvR00B04dHktceMz2S6vsOsbsGWdr8/pThkSRleCRl+IookFSPJJalrbq/TXk2BR5Jam+xTkY32UeJYtnaqnpKKZqC6w2eiwAAAEQ4/LDn2CA7UA/JgYKlDhkeSVKASl261nLpW+9L1uRykpuHkYzwjqdVOaFHUuwLfS19y1oC17xz6w9u9YrKXVpz9HHH5DcIaelbdcPYw9K34aGhJ2SpGznL3YoAlRZQqiiWvBWm3GuvXUsbN26U2vvX7BS7evfElHXbtt17/5NhzBkYmD9IU3YuM5bOtkR/wCOKw8Mj9OYLLqCzE1nYJvu8FRTBoyLDnxowrJaybRlNdM+WS9YiWQl5OXdv/kVP/e+whYdm3jynzbTzVp5oHknaA3PO0qAelqxJa8CcpS/tFtKQulZHMtVuX15id9ut+Yu8q/588hut66vFUqyeGkh8ZVx2PWU2l9ZHkF6CmFwb166+Wi7Fyl4CF8tOFv25dgOHMcrKf9Pb0rcwLud7JLVduyp5JKUC63n1r5tzt2nGrctJDm9Nfe1tS9ugSAIAgIx7PMpQIqU8kkwwox1XzISKJhPP1pZSIHlXQVeJxHbDe3ILNncmdoM0c2wi3Z1pFJ4LE0qkZNY3rhwKsrVZIQuLkOTHagokVo5pyvGypDlf6DdrWzXb62Ztcx+cp02dVt4AjY9PeCfOz9rWtA/3fbddTps2rXytsrl1AjZj9MaVb6Qzzng5vfHP/izYz4MGOkvdZsw6gDZ8cXMZoGib1at6v1ru9tPv3tfxT6qWzwmneHi4Y8pdZHorgkpr1q6jj37so92seWU9/IGxU/7A7GtXzZ9/xDd3WXOd3TXx1dHRe275XRpnZs8ePna/adNfauzu08cnJl7kdr/iPA4NDdOZZ5xBZ69YXnohSe3HrbftDz1Ot3/3Xi+A1Ov5Kt73VEjK765dt5b++l3v7GRhc2bm3exsbpbDOhva+Lj3QDS9zNpmaceOCW9g8bO2NeOPn7VN6F9Kf+QU/aJqV65H0rTpnf64w+kvgW4jnELP9EgyyRl3SZmUVijpD+Ki51LPCiXtATmQSLLrKWVlEWNSDxKrW1QoRcJQkkKJlUeCQklSAslpyxxlkhDhEp+jTSKzV8SUR1YmGbEvqAosHnAKsubJ+1O/5iiUIoFQw5U7geLPxBVYrOGYVGCOKZP8/hRGgIwa+DCiQkkaD9RcZqJCKe6RZFSFUvgLYsBJqR+uvJeyCgYm2kLAyagKJWm4khRKwuZe9jajNd9WCiVVmcQ8koJAv6IA39tAIAkAADLJMdPOWz8dBoqagJH1PB/iViGSMol5JEWymPHsFznm3JZlbQvTqzjbetlYYuU1WduECq1fYwqlZvU7lz5Y5qGhvi1mYfF31v2i74tgmI9B742Mre/nWXpifgjOflWBJ57NKtU+R8fup6s+chXt2rWLLlgpL3UrzJWLYMJkZPuqAkp3bthCC5fOpUWnHRXdvlr2VgRTNm3aVKaSL9RK1XnZbelFxtoXTeza/bdz5sz7pTF0k7XmW/vvP+0799xz5+bfpvFkaGjBwomJ8ZOKLHVEdAoRzTV2t+/x0T3mV7ziFZ3zYfPq9I4Nv6QN/3JnGLjskSLQlzJLL5ay3XLLD9X+4nZpLWub3s5lj6RGmeS39746oJq9remXsfTXfEQiIVuam4VIzAoVPDeyLHD1r6SyrIXjKFGYLYlnxUqaevPyuA1KJF29OGhxvz8rZfvyFWB+fMaKWbeI1VM1+WFs+DU/rqFlK5WzdIWni2VtszwLH8tWyrJiGUF/7A/y/J/+/tiIEibar1i952Rtk+udaw+NeD9jrJzFT5Mo1eVov2blLHfB/mjZyOqtWXa7sIF7WeiUZIxO8I5nBWSRC15eYFPkV5hX/0RJaY/kJ+e+IS9Z0wNxgQtWVU5d7yzLWkyJJIyT/L6xHt+siTff+jz441vT/hNL15QsncH+IVtbaq4GAABARW7WNj8ckfZIyi5H9UjKeSjqZymcvMFkLV2L/4qwRSJ7255fCpf4hT2etc3JutbD0rV4YDQ8PamlbuQYN/fjneSSm+HND351lr6tu3Ytbdi4SW+nlh4gQxsN0c27jfnR7omdt23bNnrnEzGGDAwMHzllinkOET3XWjrOGLvIkpmj9ZuOCmuFrz7KCCBN5hI2yvRCKpayvea1r6Ffjo626y/Z3bN9e+85a9szD+tx6ZX/YNj/0reWS9Uyl75lZ31Ty8/xSGpVYGe/hCVvefWfuVSt5dLA1kvVMtd65S88iqTx6ilJVrwC9KVSOeXlVUfLE9Ky/tt12L6WqmWdzz6WqiXLa91dszySWvWyZCA9t7zMJWaJ3Z7UpWo5WeQiYGkbAACAjAdvE1UdWVFR5AZ08jyS+Ex2k90jNzDEM7uxfwUKIiFsJM7MVqoJE/dK4hnZlEBTPUMYDYPxqe/wyTOmwLLCTKNbn5IZUliePxcXeCRZ05ciwvLjkpIa8axtkkdSon26bZrEjEqmzLR17nnn0llnLSuzqWmBhsIvZ7ICGO6StyJ4sfDEedEgBnUVO+7Stw0bNtDGjZtozbq1vlKN7ByydKYlOrNol1P2mUJz5szdYYkKWdXP7W57jzFmizF2zNopW63dtW2fffb79ylTxn9NRI+NjY0V65p2VvdPQ0NDxXqqA3bvnnrgrl0TTzPGDuw2Uw6eYs2QtXbEWlpgptDhZOkZxeor60goLGsnw13T7OLdN2cYZ+/pABJlqpCKrGx/9Y4LvZbjd89m/Ih7JCnt3e1tkidYXPPY0xhPGYmL9EARV/poylJJaeM+uHAFixWVDs2Od8vRFE6KMspKT55RhZOi2OLlxQJFgkJDq3dr5Sc9fl3gypgwaZ2RB/R6mbiVlT/y5pKkwv9aoIjRTr8WuWHKDFZeUE9cScse8F0Fi1z/vN7zFUmSNxVXzFlegaxDpBRJXDEn+Ap4r6lwAlckeco/sf55fzKigrle7s8UbW49SfEQXt9hf2L7JZrTc+WWU16gRObHGQsUCcotXp7cbcIlcEwxx5VDQQaVqra5wokNhEFGNmMTlmFsvA2uO5HsuKQsgdtLlUlQJAEAQIJcRVIvD/JSqCNQEHlL3/LNtHOWquVv0Ispd/wb6fKkKVL9uPsy026taIrvwJ5RJNlAmt02SBWYxmey/KxltHLlG5PqpK9/4uYyO9tk0otKibpKpYI1a9fSxk0bu0vgUqbxT1x7HxoaKlVHixcvpiWLFvcUPCoCbpOlBuPBwZgJ+paxLXThhW+n9RvWt+93Sj3GsxK2CxT1rEhaeJi+dK3VzXW4hKKFACYduOpFIRMonHow5W4iCapHUv7jh+5G3K8Zd2Y1JFy1E55G0a/H3b/b60Libs2ty0mYQ7dTJGUoiZJe2S0VTurX8yRV6b3PcMluVf/tFDc5HkmtFEVSwKk3yaUQiOlJIseOqr9kA1I5rRRFEfPstsokKJIAAADE4wSR7G15HklVedISOH8mi1tcCFP+qldSK48kqwWerLZ5S48kOexR+8FoS+C4R5KNB3q8mUHRK4mdT+s/+OoeSRQos0SFRZ+KpNqDpaqxNjNlUcUGr848tVLVztdeu442bNxAy5bF1UnFMqjJVsf0olKirsqn4E3nX+AFlirF0paxURob3UJbxsZ8b7FJbu/FEsGR4RFatGhRuU/FsrUlixf3XBd7Qn1UkaNC+vvLL6PLL7/MUwJZR2MkNGhliWbYb1RvkKhHkhR46rX7KV5iXDnkKGxyPD+yPZKUB5tA4cTqXVIQ+dWnKZxsqIzJeQ5UPZLSS7Hk88rL48o9kwhMaN5I/n5VCg3FAslRxLDrsIkrUEKrJqtcuKvmJCs99LBDIEHy2mWoiNHiIFq9+zcKmiKpqXfu0SN7/3BvJCtXr6AsUxQ2mkeSzfRISngjNXvfn0cSJT2Sgg4e90gSvJF0j6Rkdw0VXJIJd9Qjid2HpDySlECcVT2SuFAs7pGkeSNV46UcYNIVhZpHkhRo2ttBIAkAADLh2Sy07G161jVenmHl+T9kTcojKchbw/YzkcWNZb8wQRY39oOGZ3EzcvY2596nzt4mZl1j5SjZ25ry3GwsoQqaZ3Oxiax4XjlCfYZZ3Jp6mDq1yu407mUlqbKtcXKztlUZTNxsa+4DeJGdqnidmBj3Hpy97Z0sIt77DsX7xfcnJia8gJGY/a1bzraHHqJVV15J1157beOdxPa/CCYVgYhnnTifNq+/j7639qdZ9ZDzfhFEuf1795V/T59zIC064yhauGRuvD6d94sATvF+oQIq/qr3x8bGylT1o6Nbysx1Y6OjtO+++5WF3HvffWVRRcCpeN22bVv5OnugE8gaHh4py1wwf17579lz5tQddcniRaXaSH3Oyny/Ms/e/L1f0sMP/HrS6tNl/rMOpmVvPTG6P6UK6e0dFVKVnbDIKliNH8V4Ms3NEuhmW+v2lzJrm5MMyM3m5mbRKtt5Uc6Oce8BoMqq1sna5pTjZW0TMuso/ZEzffq08vS5/Y7IL9+QPF6Tk4UsJ911Pd7Ko6eXLdLN1iZckcLxO8cjqecsbSmPJDnbkzF6qEReqmMi2dqkLG1Wz7kmZWnzskoJ2iy/eoVsaEY4XW62sIQSqcrSZuS7DRNxy5ayxwW6CdYuY1o2N0tbNBudk20vJ0vbCYuX0N9cfAkdfPDB9Wd3//zntPwVy8Ksb076vJef8XJ6x9vfSU95ylPq761Zs5re876LlIhbU++/f8rv0dlnn0PPeuaz6MAZM2jqfp2+u3PnLtr+6+20efPtdPXVn6cbbrpBVyIZQ2uuXkOHHXZ4/cnWrVvpnRe9o5xQkbK0Fa+FsvT97/uAf7x3/5zO+cOz699aXG7zN/I2zmn+wudXB79/0bvfWf6+0F3LbxVlv++9Fwdl/+ErX5H0SCo++tQ/fZaeuTCcSLjjjjvoT/7sPHr8sUcFU25Ssh/ytGb+PU6YpS10hSIpW5vaW/KytCWztaUUTXt5ljYEkgAAoCXikqDkxHfojREsdWjtkZRQEGV7JDnfVLLXeMehSoFk5Y6QbGgSPJLoCfJIYocueCR5WbW4oqnPrFF+9iobeBB4M2VBFrnms6qdaQq5WBY3r5zu/aL7XuGd9IZzz+2ok86X1UkzZu1Pi04/io5aPHePLHd75FeP0w3/dAt99eM/qJe+DR85QCNHDbQuq1hiNjQ4RLRoUU+Bnuj7vR5fV3k0ese2su60wEe/1GbaiXq79PLLyj9vTBDap+fFw9Ijuv0lzNrG2rmk6OGZ3ZwBL+gvPfc/2fuDv9/WI0lNQtePR5JnssI8l6zp0SNJXvoSevS080jyA1ChokL1RlI9kmygZHGziAVKEy2tllXKCyY7Yh5JofdPXV+qQoofnuyRVHvYOIpcuRyupOWSGEfRIhyn5rmkLxnk9e/vvu8kGNaBjXgkZThPivV+4tKT6C1vfmsZCJEe8vfddx96+tOeRktPOJFOWLKUbrvtNvqf//sSuvXWW0OPpNg4Yq1a7za253XcJbKVZcoyYXySsv1Gcpko1/mwx5526mmlelZi3ty5dMbpZ9DVX/g8Gx/zPZLc8U30Rop6JDFlEiU8ktRxTQg8eUowGy9PHd72XoUSAkkAAJDAsBkITYmU8kjiMyImoZgJFU3GU860ViDxp95AgcQPy0qbOxO7XELFJ9LdmUbh5iahRPIVSJKiiSmH6nLk+jT1TTmJSqRQgcTKMU05pRKDwnImJsbFYIKaht1Kba0px89mZGlifMJTelT74CqO6nZaljNRv+e2y0qJxBHLMeSVU+zY2P330xWrVtG1166j97/vYlrsBmHIVygVfjtFMGTDFzerASWtfnLer5a+Vb9XLHsbOmqAnrV0nlrPv23vF8dQ1M1251gmq36k94NsbMp+rl+/ni58+4XlMsBGcGO6SqRQ5zBetk8KFDU7xp3+UncrUyt/eNau8R0ToRm3sV3Fkd8+i8+qdhvcyCvHpdXPjh0Tjjl045FUHFe1n+F4TsIA6iiJkh5JJjnjLimT0golfS2Y6LnUs0JJs0bhigTDrqeUlUWseVs9WkWhJD/3NRIjoygpSA6gGFkJJJ40V5kkKJREyxdjoh47JmLKIyuTjBjsVhVYxON+xjlH+v7Ur6JCyYjnwgiSMePYMut1ICuw3vD6c+ncN5xHBx301Mx7OkNHH300/e//+X/og5d8gL7xzRtZf4oFBFhD0BRhfM/r+weTKNeo1kXFfnNFmBEVf+F9hd8cw6VrixcvoRkzZojfn77//vS8Y59XB5ICE21BoWRUhZI0XEkKJWFzd5wUxksxcJVQKKnKJOaRFCiUguFt71QoIZAEAACZ5Jhp53kkhYGiwCOJtGw/QjnMG8nNtpbtkZRpzt27Z0ysPMcjKazQ+jVmvesprURvJGYBHL6d8EiycY8ku2c9ksJsbbpHUswzppWHV7S9d/57y+gYveG8c+n8lStp+bJlqhl3EbAY+csXlMvSioDSZBtEuwGZavnbhm5ApgosVUGm3waK/Sz+Ru/cVquOngiKOlj88oV+kE2gWMa2evUauqxWIUnKxYRHkmxCI3ojBR5JQSQo5pHkts9+s7clPJKs0c24veefHj2SFAsVCjySqA5+x7OsheMoRTySrBGWwImrtzWPpGaSIO6RpJ1fxSPJsv2SPJKiXknM00hR4jZxDS1bacIjiUj26Ak8qpgSl3n2GFK8m0hWgAQeQhGv6Gi/SngkkTNp5SrAwno36m9YySuJZAUXbytSa/mjV7ySzjv3T2jGjINa9/Y5c+bQ2972F3TvL+8tl4A1e5+4f9M8khL7bgSFVliuri6ylPJI0q7l/NV/Y/78+XTsc49VgyFl4O2YY+hZz3423f6TnzDFWYZHUmSJL4keSVZWNCkeSUGrZuNb0/4TS9cSHkn1/iFbGwJJAADQFq5IMhEjQhP1SJK9kQKPJMrzSFKdG3rxSPLKkT2Smq+lPJISiiLutWRMNFtatkdSoExi5TCPJOrBI6mZEfQVFn45vTQy53yyGXPvwVlaBMCtSYwyFScGisKb13R7bx4BCu+kdevWRc24C4oARhHMqRRKeyqgVAVrCqrAUhVI4cGl6m9PB4wKnsigEQ8g5Wa+u2bNarrwHW9vnkC5ok9q75WCIdJfqg5rnOUFbCBQA05Se1eVon0kJObKKCOYzuiKUtKzou0RjyRv0Ag8kkzPHklGO6xMjyR+gljxwhOlVO+hIoYrcIm0A5azteV6JIUSJV8AEfNIkrySlKOuPZIkhTNT/EQCc6FCisR2aSJpr6R6txFljK8AE1ukqowyjrJV9EiKXBz5p4WK5k/O+9MgiLRjfAfd8sMf0peu+xLdcOPX6cADD6TfO+X3afnyFXTkM470rmVzR+bSG173htJ/KCvdmPE1NjYza1ta7WSS2Q9LPRP31EyWy5dehXt8yotPoUMOOaTevlAgF56BCxYcWr83a9YsOmHRkjKQFAukqx5JJPUnxfw65pFkZXVRUI5q0WTC1hRd+pb3PIBAEgAAgCg5iiQ3mETBRKSr/OnFI8n39OndI4k81ZL7n2LWNnFmtlIJJdKdWztJHkn2CfJIMt6sr+SR5J6ZIN15n4oky49LTmrkP1S7Wdoy26fbpsPTk2cW77ckWxpVF8vdioDSxe8Xlrs5QY0qoLSnUti3CS5V+1QFk9yg0oyBA2iG8+/qs6qc7c5+b9/2mPfZf0XAqJ8A0pbRLWUAqVjO1gRyYt4lbgehcHxhkg8xy2FE0Rj0tmhWQjMpBlW8P1irP9C18UiyijdSXx5J3o6H3ki9eSSlFE69eSR5gSJBgaLVu1U9krRsX/L+WNEbSfZI8r4pby5JKvyvBVnDtNOvZcliyozAo4pfD5iSlj3ge9m+xPrn9Z6vSJK8xeW7jua9mEcSpe+q6h86e/k5parIZfv2R+iKVVfQpz/7qbqbPPrrX9NnPvspWnftGnrvey+ml7z4JbTPPh3fuSlTptCi4xfR0c85hm697dagJcsXaS2LX2Tfsz2SIpqliEcS9eGRdNzzjqNp06bX2297aBvdcOON9OpXv7qbKIHK10WLl9DHP/Fx1Usu5pHkeRpJ2SijHklM4WQTHklGuaHVAkVtsuOSsgQOHkkAAABipBQa6Qf5lh5JjhJJ8koKFESsHN0jybmb1ZOyOVlUuBKJmKeRUcqzwkyo+/M9eCQJyq7m5sRIVlIRRYXmkaQomoycJc049Vlls+LkZm2rZtmr7G+VF0314FzczBXtovFK6nwWy7ZWve8qmorsV8WrlM0tLIfE7G9uOZ0scp33i4DSf1/5RhoeGqSL3vVuP6DkHG+V4e2ZS+fR2M8eoju+/0u69/atWfU22e9XyqEn+nf31PtFVruFS+fSotOOirY36i5ju+iii2j9xo1O1r+O4sBrD043rrO2ldnZmscELwubcbO2Ne+7M8Pu+40Sgmh6mbXN1p5FdTlu9jTHC8zP2iYcr9IfOdOndfpX6fXkzLhPmx6WH/NIcj0/dI8kpghNOeRwjyQ1nxnJHklMuxLsl1GuU1JVRjySwspnylvnUU7LUx9ThCmlJ72RbOUno3isqO5FsqWSrFcQsoip2duMokxS7xpUMypZASRaVCkKINEbPU+RlFImtfVIomgvaI7z6KOPoWOP9ZdjFUqaz1/9efrMP39arNNHH3uMrlj1ITpswaF0+OFH1O8PDMymF77wZPpxHUjK8Ugy2R5JXn0lPZKoJ48kyvRI4mtDFy1aTEce6U80/PxnP6Nvf/ubdPrpp9PgIYP1+0ccfgSddOIL6Lvf/Y6vAMrwSEoqk0ykBiVvJKf/St5IdXlJj6S4eXZu9jZ4JAEAAIjSKH/07G2tPGjEJXC+AohbXAhT/qpXUiuPJKt5JFlt85YeSfLcTp0BTUs/wj2SbEzAxWYIRa8kdj551jXVI4mELGlCFqo+s7aRbdQXNiObVViZvmKDlxN4JMR2hQVEy9lQP02domiqAkr3l/5JK5adRWedtTyqUDpo4ABaeMJcemTbY+WSN1ctBPJZ8vJOYK6oT0o0xSKAdPlll9M1a1fT1HLW2YYKRFLetrw1mmZD3hh5N2Ld3HpZ14i17xyPpKYt9p01UfFIsk7KOcsUNjmeH9keScqDTaBwYuOUpCDyq09TONlQGZOzVEf1SJIfLMPAkHJ+reKRxMM8kkeS0E6C7FpW8UjiXkT8Omw0BQrbL6bcEtLP1ZMekjeSdPql+uHSJr4/pHokafXOvcpkRVJT79yjx4oRNf2az+ufKcuivbOzyfOffzzNnDnTv+aMbqG116517heYh5AxdPfPf0Ybf7CRDjlkkB7cupXuvOtO+vZ3vl0ugftt90iiSfJIct84YckJXj2WywJ/dAv9+Me3lgElN5B00EEH0XHHPZ++891/9c9IyiNJCoB62RW5RxL3HIt7JGneSNZIWTaFpXTBMCR7JCFLGwJJAADQM43yJ569LXdpkFG8khqBT55HkjqD3ItHkqdMkj2SAm8j1SPJUSaJWddYOYoyqSkv0yOJWDlaFje3nJYeSWUWJ7KBJ0C/WdsqZUKVFc71ICh2t5NtjQJzYU9Z5MyUeeU4VFnbuIJOztrmZMXyphi72d8o9Foad+phzbpry78Vy5bRypUrZUNuJ8tbkU2sMIQulr1pnkKTncXsd/l9cfla5FlldGwLXXb55bR6zZq6wUyUyiKqFS9Vf2naua/oq7O2MY+kKmubt+SszNo20SxjcRQSO+psa77ko6MICh8AGoUSK2eHU447DrXM2lb/LpPYjHtZ5+TxWvNIkp+MJsMjiWdpk7K1+Q/2k5OlLeWRxM3apOJjHj2sPSi6qzBLm9VzrrXySBKrV/D8kTySMpRIgUeSfLdhIm7ZkjKqvUcSP72VR08kG52rbDJ6qDGm0KmUQkbzSIqpoJx/LZi3wFuOVXDHnXfQfffd2y1f/n5R75dc8oEyW5uRt0imQDPS/cET4JFEe8AjqVjWtu++TTjgoYceovUb15c/cPMPf0CLFi2q67nYbsmSE+jyD10qmXTFPZKSWdoyPZLU3pKnQEpma4uZcROytCGQBAAALRGzAyUtOUJvDH6Bau+RlFAQZXskOd9Ustd4x6FKgWTljpBsaBI8kugJ8khihy54JOnZ6Pr3agk8ktgDsWVqKD+LnPOAp2rA+O+FCrqUCbfYzjPa++q1a2n9xg20+PhFdP7556sZ3qqAUhkYObPjNbT5u/dBpcQofKYKw/BUBraKOhPbhy5Le4FFPZJyPI3aeiSRUIDkkWSVrIR7xiOJJskjSRVY9eOR5D53cc8la3r0SJIkP5JHTzuPJD8AFSoqVG8k1SPJBkoWN4sYFy5o3lSSR1LEgkrxSHJ/kCkzVIUUPzzZI6kOmjqKXLkcrqTla99s45UkHKfmuaQvouT17+++7yTYziMpw3my3HJweMj7dOfOXfTAvz3Qvf4pVmLO5JWrCCOubBMuegcffDBddeVHextXyM0elvJIcpRl7PevXHVVn+OaX++nnXqqZ6hdcNedd3Yys1lLG3+wiV7xq1/R0GBT18NDQ/Syl51K11//ZUEhp8XN/fFN9EaKeiQxZRIlPJLUcU0IPHlKMBsvTx3e4JEEAABAQc0OZMKLdcwjybT1SAoUTSaerS2lQPKugq4Sie0Gv+3iFkjODK2/AZ9I972JgpubXjySgqt5LFtbeCtDJCT5sZoCiZVjMryW+sza5ikqaqWHlK0tPHGBhxe19fBSyslQ3IlZ34T2PjZ2P6299lrauGkTLV50PK1cGQ8oUTfDWvGXUintDbQxz64oFEjXrFlDl19+uXc+XC8wqb2HWQnldq6Gc9RsbdXHPOub80AqmXHzcmRJUL+jvWMOLWclCtu3tBuOkkj1SCJREaruF/dISiqU9LVg0n71rlDSrHtEkx6WpTSdRUwwcRJKlxRK8nOfZnoU5oYLFUqyR5IRB3IjuiGrTkyNQikSuhQlSaoyyUiXS12BRZpHkonuT/0qKpRMa4+klKqnOr6DZjyVXd920+M7ftMonqyN+k5Jnopp1VCvo4p7/5DySDI02fGIUPHX+Y8i692MGTPq7R5//HFav2F9Pb4WAaXbbrvNCyQV2y9etLgMJLXxSDJKe9QVSsLmkleS2M/zFUqqMol5JAUKpWB4g0cSAACACDkP4nkeSZEHcd+ERPFGYuUwbyQ321q2RxJpHkny5u09kmLlOR5JYYXWrzH9gae0Er2RmJ4ifDvhkWQFBRD/mf6ztnElj56tzWrNSlFstGmfOe09J7uVHhgdHRul1WtHaf2GjaV30vHHL6IVy5cngyiVSqkwxi6CSWN3bHtSK5WqbHLDRw20Ch6R54G0ZtI9xer2HstaJJvQ+IGiwJuFt+4cjyQbLPXsqwNK/cRT+uQEmnr0SLJSoIkpnQQlip5lLRxHKeKRZI2wBE5cva15JDWTBHGPJO38Kh5Jlu2X5JEU9UpinkaKEte4QVAxW2nCI4llK9W8kixX4jKvJEOKdxPJChC+P1b1SEr0q4RHEjmTVq4CLKx3o/6GdarDWDmLn9Y33RKnd436ebsU659rIZV6z/NI6m1cmRyPpF7vXfmrpXnz59Oxz/XNyrdufYC+9/3vegPsLbf8kF74ghfS/vvvXwdMiu/Nmze/s4yQMjySIkt8SfRIsrKiSfFIClo1G9+a9p9YupbwSKr3D9naEEgCAIC2pLK2+Y9nMY8kWfEReCRRnkeS6tzQi0eSlLVNzd6W8khKKIq415Ix6gNv42mU4ZFklKxrfAY1WGuT75FUmRO7WdvMJGRtq2bn5KxtVGanKrOkuVnbgmxrTXuVsq1V23eyrU147TQn+5tb41PdLHJuOU5WL7e98/0cu79QKK2j666/nj768Y/Q6aedQcuXLWtUSka+YSzMpJ81MK9c1lUolYrAUrH87dH/+A1tueuh39lsa8X7B83cn45cPELDXSVWrB74+x310Vq66iNXddvnRNMe3PMy0c2S1m3nRfY0W51fR4LUtPMJT4nnt8/GI2mamyXQy9rWKWeH2z5Z1jZXIVK286KcHePeOOhnbWvauZ+1TZg1VvojZ/r0aR2PLyfLYYH3u6qilPSsaHvEI8ndNvRIMj17JBntsDI9klh5SY8k37zcqooYKUupfMDSSr18j6RQouQLIGIeSZJXknLUPFsbqx9P8RMJzKlZ5JIeSZpHlWmVtU2zkdGUUabuO1bPIqf9ZvomzVHkkjJYmohHVdrtqMe7x0nySOr93pV7JJ14wlI6+OA53sTR5s2b6b777vM67Pe+/z165R+9kubPX1BvW3xv6QlL6Ze/vC/fI4mk/qSYX8c8kqysLgrKUS2aBMV2dOlb3vMAAkkAAACi5C4NIsUzxlf+9OKR5Hv69O6RRJ5qyf1PMWubODNbzf7pB+DODPbvkWSfII+khHcM+Qop4lnf+s0aZf1ygqxtVli7L8yiVe1TUyDJWan8At3AUJ1JLrccy3N6GS/rm5T9bXT0fvrQFVfQ2rVruyql42nFihXJOqtUO2XQxRBtf+hx+uUdD5aBpd+FJXCu6uhZJ86nGbP2b92ESgPtyy6n1WvXNIFCt51q7csdZ6w/EFgbKgKJjUM26ATWL8+R/lkSshySXI6Y9UzIrFPd8Af9pY8xXmrP/P22HklW8UbqyyPJ2/HQG6k3j6SUwqk3jyQvUCQoUML6JjYuaUvDWLYvI++PFb2RZI8k75vy5pKkwv9aoIjRTr/kMk6hd1DgUcXqiStpmVLOVRDJ9c/rPV+RJHmLy3cdzXsxjyRK31WVW2596EE67PDDm+DwPvvQUw86KOqR1HSXhEeSsB9bt26ld170DtpQLv0SFyeWS8Uuft8HSj+jYN+zPZLk4b/4/Xdd9Ne0YeMGxZyeyt9/33svDn5f8khauvTEWmVU8JvHH6cf3vLD4D73vnvvKQNMhQKpCpoU3ztx6Yn0uc//s9z+BY8kz9NIykYZ9UhiCieb8Egyyg2tFigKFH55HklQJiGQBAAA2aQUSelAU0uPJEeJJHklBQoiVo7ukeTczepJ2ZwsKlyJRMzTyCjlWWEm1L+Za+2RJCi7mpsTxfOFMryNxKxvpJ6fKhuan8Ss/6xt1Sz7RJ0Vy3hm2pUSyTPTNqRmWysUR1TPSDZLgSolEkcuh8rf5W1eUjSJ5TjtvS6Hmbg02d+KoMhYqVJas24dXXHlKlp21nJasXyZ76UUWR0wY+b+pVKpMqEu1ErVX7EUrloWR09wtrUiWFRQeBwVeIqjSJvQ3qvUR5d/6PJmI1O1z4l6DZk7rEzU2fd8xd1EN9ua5wVmWDt3yqmztrFyxoVyOlnbwv5SZiccHw88WWydtS1URFbZ2Yh5gdVZBY1J12Usa9uOCXHp2rjQ/mMeSa7nh+6RxBShKYcc7pGk5jMj2SOJaVeC/TLKdYodXj0oKB5JfH+IZblTFUCUWgoX90hKeSPZruJDM5lS3YtkSyVZr+DUdzJ7m1GUSepdg2pGJSuARIsqRQEkeqPnKZJSyqS2HkkFB86YQVOmTBF6QXOc//Hwv3ufFtsfcsghWR5Jr3rlf6PzV55Pj2zfTj/72V20fv16uvGmr9MDDzwgtrXgqJikL5alLqivpEeSnjTOGBNkzTMZFnE84HT00cfQEUc8w9tm/wMOoAv/6u3lXw6HH3EEHfOcY+jHt92a5ZGUVCaZSA1K3khO/5W8kerykh5JcfPs3Oxt8EgCAAAQpVH+6NnbWnnQiEvg/Jl8bnEhpEVSvZJaeSRZzSPJapu39Eiy+vOx65HEIxLcI8nGBFy9e76I34+axJCchWoPeSRlzZQFAq0wextXWER3RQqMqu093XOi7Z0rJaqlWqNjdMWqK2jdurU0PDxUBpWGh4dLxVIuleKHupnOKtyAUhVgcj9zX3N+g/938Tpj4AA9YNQDVfBo48YN5cMPc6cO8iXp2Rgj7V3paK09kvyBQPDwCvtNqETJ8UjSPcHad7+ERxK5HknykjXSFFU5HknKg02gcGL1LimIxA5FcY8kMqrVdFj5JHkkyea7YWBIMf+zikcSD/NIHklCOwmymlnFI4l7EfHrsOiNJHgkMeWWlv5P8+iRTr9UP1zaxPeHVI8krd65V5msSGrq3c+6J6+5tfTjn9xGjz7662IxFLvm8/r3lWUznz7TS0lP7KpXvN5z7z3lBMR+++1Xb7Fg/gKaN39BqaIRPZK6B/Dc5x5LM2YcRAcd9FQaGR6hF538YjrmmOfShe/4H84kWuwizbJ9JeY3Js8jySr1Hx/3eHN88YtPodkDs/u6Fg3MGqATT3oB3VoEklIeSVIA1POm4h5JXCgW90jSvJGskRSkwlI6Qe1KkgIcWdoQSAIAgF5plD/x7G161jVenpIdyzQXxRyPJHUGuRePJE+ZJHskBd5GqkeSo0wSs66xchRlUlNepkcSsXK0LG6BYiPfI0nMauUqs/poZMEafukBXHpwVrKIaLN8ySyDmgLP5ASIBE+wVHuPeIKN3j9WKpU2bNxUblukIC6CScuWLW8VVOLBnyqw5AaYOFKAyQ0W7WnWb9hQLmdYs2ZNaVLuPtWJnmDk99+UJ5iuxEtlK+RZ10wYWA3MY0JPOKMoGt1AkxFs+4NyTP/Z28QAEWntmIR+pyxV2yMeSTxLm5StzX+wn5wsbSmPpOAEC8XHPHqYp5GiuwqztFk951orjySxegXPH8kjKUOJFHgkyRcCE3HLlpRR7T2S+OmtPHoi2ehcZZPRQ43V/jz26KO0c9dO77PZswfo9NPPpOu+/CVZIWU6qe7dQFIRMNr64IPer916649o+/ZHaObMWfV7w8MjtPys5XTp5X8veiQV773kJb9PSxYv8YIARbayW354s5+FTB8kAiVm2llpsjySTCSbqkmMa41H0nHPO04I1LWjCOAVy8/Nh02eR1IyS1umR5LaW/IUSMlsbTEzbkKWNgSSAACgJWJ2oOTEt+wZY/rySEooiLI9kpxvKtlrvONQpUCyckdINjQJHkn0BHkksUMXPJL0bHSToIiwSjmSd0igkHIe8FQNWBhMIqZQ8gNMOWoj2RNsT7b3Kuvb6kKpNDhEwyPDtPysZeWDRK+BpVjASfrvPUWhOlq9Zm0ZPCqCSEGP8PoN9+nSFIWWVImi9HYdyJEUhbICkUTBZDN+iAo+pZ2H5bFygkBqv9naeH9g+xN5cMnxSNKEIH15JLnPXdxzyZoePZIkyY/k0dPOI8kPQIWKCtUbSfVIsoGSxc0ixoULmjeV5JEUsaBSPJLcH2TKDFUhxQ9P9kiqg6aOIlcuhysL+do323glCcepeS7piyh5/fu77+7fgw8+SM844sj6u4USaPmy5fSNb95Ejz76aFDeSS94IZ249CTvQX3nzp30q1/9yvNI+vZ3vkW3/vjH9KKTX1RvWwQ3/ugP/4i2bdtGn/7sp4LzeOjhh9N55/0pzZw503u/MJj+4r98sRnlYhc9a9V6j7gfOfHAlEeSoywTxicp22/qOu3219NOPY0WLDh0Uq5V8+fPpxeefDJ961vf9E685JHkjm+iN1LUI4kpkyjhkaSOa0LgyVOC2Xh56vAGjyQAAAAKRlsLbcKLdVTh0dYjKVB4mHi2tpQCybsKukokthv8tpcLBpwZWn8DPpHuKxmCm5tePJKCq3ksW1t4K0MkJPmxmgKJleMoM7zsY84X+s3aVs32ulmx3Afnad0saaVni3PixGxr5GdJc9vltGnTylcpm1tQDivfbZ+dLHJUejq5p8crR8naVrdT6h5X6bk07rV3sZy6/E49jN0/VmZ/27BxY5kFbGhokJ733OeVs6V1YCkz69kT/f7oaEdhtHpNxyT7X677l/K9yuPIOPXZ8TIa9/qLdF5MN5te8X036x+vT1eB5GdtaxR3qXbeKafpZV4WNi9rW/O+q2iqs6GNj3sPRNPLrG2FJ9KEN7D4Wdua8cfP2ibUv9IfOUW/qNqV65E0bXrneHdI3l/8txyTorhHEomKUPXJhXskJRVK+lowab96Vyhp1j2iSQ9TkqWziAkmTkLpkkJJfu7TTI/C3HChQkn2SDLiTYOR3JB1J6ZGoRQJXYqSJFWZZMS+oCqwSPNIMtH9qV8VhVJh1Lx40ZJaAVP0qSWLT6AvfG41rfviGvraDV+ju39+Nz3n2c+m0192Bp1+xpk0iwV6Hn74V+USKn6cV1/9OXrmwmfSnDlzvEDVW9/6Njpx6VK67vrr6LovX0eHHXY4veylp9KKZSu8bTtjxm/oq1+7nh597NEM1ZDQEDI8kox3/5DySDI9eSSZTI+k5z3vODrwwAPrz3bv3k2r115DH/zgB6L3wQcc8BT6yFUfo4VHHVW/97SnPo1ecNJJ9O1vfyvpkWSU9qgrlITNJa8ksZ/nK5RUZRLzSAoUSooCHIEkAAAAcuAjI2tbnkdSGChSPWPUKUxSvZHcbGvZHkmkeSTJm7f3SIqV53gkhRVav8b0B57SSvRGYnqK8O2ER1Io2apUQa5nTL9Z29yMZpZsmM0o5sbg7FcVeOLZrFp5eLF27maBIyXbj7hDTnv3M9KRlyGOVCWIDdo7uf+feYoV2d9+cc+9tHrt2rqEQxfMp6GhYTp49sG0aNHxe0S5lKJQUa1fv6F8veWWW0rFkRTIE7OtSa9uAyQbzSpYNVsr9RcvI6L+hbDf2FDhqH7B79Ja1ja9ncc8ktz22Wf/UzyS3Kxykhl3+PzTo0eSlQJNTOkkKFH0LGvhOEoRjyRrhCVw4uptzSOpmSSIeyRFW3bokWTZfkkeSVGvJOZppChxm0Cflq004ZHEspVqXkmWK3GZV5IhxbuJZEkS3x+reiRRvF8lPJLImbRyFWBhvTc7UAQpTjrpJDrqyIVeQGRkZIQuWPnm8i/Grl27aP2G9fSTn/zYmTzq8O3vfJvWXbuWXvfa19G0adObgPDUafTCF76o/Pvg3/xt9BpXjMX/3M0+1uz9b6dHku3TI2nuvPm06PhFnpH59u2/po0bNjjjmdxhH3vsUbrtJ7fSkc94Rv394vXZzz6G9t//gPJz1SMpssSXRI8kKyuaFI+koFWz8a1p/4mlawmPpHr/kK0NgSQAAGhLKmubH47I8IwRZ2jzPGOiyiT3ZritR5KUtU3N3pbySEooirjXkjGqiXbj8ZLhkWSUrGuZnjE5HkmdLE7Wn3GbhKxt1ezcuJi1jZosaWyxkZ9trWmvExNyNqsm25rfTrXsb3JWLDfbGivHqwe3nIn6Pdd4183a5i7V5IoaqrN0udnfmvY+0T0vXHBwz733lsGl4o0169bWH3S8lhbX+zE0PFy+V52akeFOprjh6rWbOc71KqpURVu2jJZeTlVHvX9sC20ZHaPR0S2lv5MYCGXnpcm25rdPN9saOQ/rVba1SqnildO9g3aVeE02QNfTyHSUTk0DrOtTLIecrG3MI2nc2x83a9tE6G3kZVvzT1hHERTe+PtZ25p2Wr0fKCjaZm2rftf1SnL7l4kpSknPirZHPJK8QSPwSDI9eyQZ7bAyPZL4CWLFC0+UflZJTREjZSmVD1haqZfvkRRKlHwBRMwjSfJKUo6aZ2tj9eMpfiKBOTWLXNIjSfOoMq2ytmk2MtX+3HvvvfTpz36a/vzNbwuURjmTGT/7+V30yU/9o+r296ErLiuDTa99zevoKU95Squy77rrTvrb/3VJ6eWUaTPv9ZMn2iPJ9OmRdMLiE8rJFJd77/0Fff2GrzvjWdhhq+PbtHEj/cHvvYye+tSD6s/mz51LZ55xJl199efjHkkk9SfF/DrmkWRldVFQjmrRJHhHRpe+5T0PIJAEAAAgeeORUiS5wSQKJiJDc+J2njG+p0/vHknkqZbc/xSztokzs5XqQT8Ad2a2f48k+wR5JCW8Y3hWLK51spPskSQnNfLX7kseSYn26bbp8PTkmcX7LalfjyStffbqCcb3TlbMlV5L69ZIDU6W0DH3oezNmfIu7S1mRcVcr+2dhPEj0P1I2dWiWRfd80Ph+WvlkZTyXLKJrIR7xiPJTpJHklW8kfrySPJ2PPRG6s0jKaVw6s0jyQsUsXE4Vu9W9UiSs32RkffHit5IskeS9015c0lS4X+NK5LU068pQJgyI/Co4tcDpqRlSjlXwSLXP6/3fEWS5C3OFXNr1qym/3j43+kv/uL/pXlz52U9fO/cuYu+v/679N73vZse2LrVU8zxDrDqw1fQ5js209v+/G00f/6CZPk7xnfQTTfeSP/n7/+OHvi3B3zlXywCTf6FJ9cjqcm2luORFNEsRTySKMMjqVCG7X/AAU4d76Sbf3hzqPj2FJeNYu5rX/8ave5153qBpOn770/HPvdY+vzVn4t6JHmeRlI2yqhHElM42YRHklFuaLVAUZvsuKQsgYNHEgAAgBgpRVL6Qb6lR5KjRJK8kgIFEStH90hy7mb1pGxOFhWuRCLmaWSU8qwwE+r+fA8eSYKyq7k5MZKVVOiRFFR3KnuVdH6Eeenwh3toY3p9ug/OniLJ5LZPwTRevUvSs6vJ7T186DZ9t/c94wkWtnc5u5gVPFG8+lE8wZJZDgMlX6S9e48Z/WYl9Osj5QkWZCVUFJFS7p2wgkLhBc/W1ighFDNto7R36j9bWxAgkpaukda+w+HI9fzQPZKYIjTlkMM9ktR8ZiR7JDHtSrBfRrlOSbUb8Uji+0Msy52qAKLUUri4R1LKG8lWKkjFY0V1L5ItlWS9glPfyextRlEmqXcNqhmV7I0kWlQJWdJI80bPUyRlKZMM0Y3fuJFu+uaN9NrXvJ5OP/UMGhkZpgMOOJD23bfxKyuUjr9+ZDvdvvl2uuaaL9ANN93g1JecLa3a4BvfuLE08D5nxTmlH9KRRy2kGQfOqMsvy96+nTZt2kSf/8LnaOOmjU1fITlDo3p9ZJK+lEeSV19JjyTqySMpJaJ6zrOPpiOOeIb3/iOPPEI333xznYmOhOzEfOD+waaNdOQRz6B9uvVabHf0McfQs5/9bLr99ttVj6SkMslEalDyRnL6r+SNVJeX9EiKm2fnZm/bW5VJyF0HAAAJjjj8Of6EfavsbTrRJXBZ5SoP4lHFRovvxzdP/kD24WSmH0mXJ0oq1C/Es64lviAW3/zXrT+41fvqpStXi8f0llVne/8+5rhjwkBRfoOKKDZ6aJ9SYLSn9h4q8dJKp3btPa+B/Be3d7ecdDq8lv0m2VzT/cWVAWW9ndnDpX5jfK+kXhpWOGw05dy9+Rc99b/DFh4auV22LNAkL1lrFbDSvIgMRWfUpZCGGLCi6OHoWdraHU5YcLZHUvYO8jgNReI0ifJaV69youPlJWcMrBqBa1H/quQi4ZGUU44QANMtdKjNEai/llXvvey93C4jcYvEr6prrJKno019R3ffq//ee6x/XrNPcKLe2FIzKQDaqv7TS83i9S95I/VQXxlZ2u66+7a9KrYCRRIAALS4hlBG9rbcpUEmofzwZ7R1jyR1BrkXjyRJqZFSWKgeSY5SQ8y6xspRlElNeZkeST0rNvI9ksqsWGS72cSa81llW+PkZm2rlAleNi7nAdzPktYcj58NrWmnflavhtLU2drAK0nO2mbE8qmbHaxonxN1lqvOfrpZvdz26ZffHHPHZLpbjtPe63JKT57mC342t+b8NudlwmvvZVYyt5xue/fLceuzOb+ucsDLbubI4t39dJV4XpY0tRz/vNT747R3vz6bfjPNy+bGy+nUg+sJJtVnUUtiOaw+XUWfm1XQVRRN87LCuVnbOuXscM67MSzLmyP5KNt5Uc6Oce8BoMqq1sna5pTjZW0TMuso/ZEzffq0xivMec7wssWRotRTPJK0B5z+PZJ4ljYpW5sUCOs3S1vKI0lWMugeScoDsjWRbG1Sljar51xr5ZEkVq+QDU3ySMpQIgUeSXqoUYsEScqo9h5J/PRWHj2RbHSussmkAjuG9DiHkPVN8baJKn4EBZgu0Ak9FE0kYtOMv6kseUESN7Fdhs3fz9LW1L8SeEpmaTORgJ8b+FB+gY8DJhL2kk264h5JySxtmR5JicB8SoGUzNYWM+MmZGlDIAkAAFoiLglKTqD36xlTfc31fOjHM8Yvx/WMkbLXeMcheCQRLycIo/EsT/16JNET5JHEDl3wSPKyallf0dRv1iie0cyydEieN0mQRa75rGpnWpa2WBY3r5zu/WJ+OX57J6a8czPSeTZPoueKn5HMb22dOuLeOX45jndFXY5l1aZlf7PV5vFynHZpvfqxQkI1uRxvxLA2ePXaBe839X7K5fhZ9uSMeTxToBu45FkTiZ0X3j69WnXq82Mf+Qc6YclS0VyeiLLev/oLn6N3v/9dzi452ii+Pz33P9bOlSw+bT2S1CR0/Xgkuc9d3HPJ8UoKzkvUI0lRKAUePe08kvwAVJh1SvVGUj2SbOCR5GYR48mdNG8qySMpYkGleCS5P2j9+iLFIyk4PNkjqV5G7Yxbcjk82yiPfNjGK0k4Ts1zSV9Eyevf3/3g+IIKZMcnlBdkyws8ksJ6r+tfsxJzgvCu90/gkcTLYxY+Wr1bVt/8tf45Xh7PlkfcK4nVl5GF3FWgiHtchddv2Qsq5ZHUVHfQYLzXlKJI9EaKeiSRnw2OEh5J6rgmBJ68bHk2Xp46vMEjCQAAgILR1kJHPWNCD5rWnjGBomnPeMaE3kgU3hVIHkkUpJkTPWO0VLo9eSQJT5t6trbwVoYEbxvV64WXY5pyxiecLE7OF/rN2lbN9k44WdvcQGal2OEnTsy2VpYzUb/ntstKicSRs7aRV47bPjvKqHCllleO094nvGxrzaNDo4zy27tYTje7Vn3GnPZe7k91o+003Cb7m/Hae1hO54Mqi5k7Q2+rbHpE3ky1sU22NS/voFsOU/C55bjtPcja1kUsx82CZ/x2Xu8Pa9Bu9jfXC6zK/ubPfOvtvM7axnQO40I5xevu3bvl+KqlrH5R4Wdta8YfOatg+6xtO3ZMOObQjUdSWc/WLz/mkeQpiVSPJBIVoeqTC/dISiqU9LVg4tK6nhVKmnWPaNLDBA/pLGKCiZNQuqRQkp/7NNOjMDdcqFCSPZKMeNNgRDfkyNI6k3TJUtdKycokIwZnVQUWaR5JJro/9WuOQimyltBw5U5o2hNXYLGGYyJLs4ziqWgigVCjLs1SvJuE8UB1dBMVStrSNSt6JBm14pSAk1I/KY8kkky0BYWSURVK0nAlKZSEzSWvJJL3K1ehpCqTmEdSoFAKhre9U6E0BY+IAACQh6TicP+IdOWG9HRTqyas9RQWvgKEPRCJma5sMIdiRUUE+/M+cL9pnX/Jm9fKCOu81goL6ygY/MxQcnmO0sL9I1kRwcvjR9Dsg/Mj9b6qbwvzUOwXmAQp/BlHJdNzI2vURtZrG1Jtyg/frmKjakvt2meqvedmt7Lp9m4tUxLp7Vxq75Ypk8T2Tqn2Tnu0vZPQ3inS3j1FkdjOibVzKzRoKx6DX57N6Dck9pu6fQblaF/YE+MxCe2T+lQlCW2etzFFtaSPzf7YytVf8TZLgSovHKMFtZHlglS3zXEFGm9zVj8sEsqr+rR1Xuu6azdGSMo5G4wVJIwVVlDgNn+8j4vtWe38Wh+30b5phXona0XVIe9yFM236u8Tddt98xoMBcJ5VK7KgSKWxD9fVRm/KntjojqENscQjmtCOeoYa5V7CmlsDFXF6bFRHiNti3sLcVSX7i28S4TfF3xVaVxlRKLiz+mjbt9NX9SDM+v2dZJUx9Ymd5NfQfwxjqlcY83XhgrbRp2coTZSlN/uay/3Uk9moEgCAIBMUlmx3Iti3FRY9kYKPJIozyNJdW7oxSNJytqmZm9LeSQlFEVqNivp6m7yPZKMknWNz6AGSwvzPZLkrFb9Z21zszeZIGubs8RSMtHmE4iJdC7JrGvJ9p4y0TZ57T1pFh9X4pGoHBOyLLVs73V/aZOlsG7noRIv6DeZXmCqh7WapdA/Hq7Ea9pTS08xirR3rzy5v0z+eExK+zR9jfE2kTVMV5SSbn69RzySvEEj8EgyPXskGe2wMj2S+Ani/Z1Clx+h3kNFjJSlVD5g2bM51yMplCj5AoiYR5LklaQcNc/WxurH678R83I1i1zSI0nzqDKtsrZFs7WpSiQTXo+zParkwSDHI4mcHix7VEn7pTbw3j2SgrrM8Ehi7VL3SDKCEDHDIykcWJXeSnJWy5RHEkn9STe/Vj2SrKwu+v/Ze/9o27KqvnOu96rqvqoiIJKIIYyAEGLaiBIRiK0dWyViN4nBjP6RxGgbMUbUdDLyo7vzc+SHf+TXMBnx9yB21Gh+SVp0tBTQmohJd0QUAemYCEFbiYJGkCqK8t776s0e556z954/vnOutfY+91XVu2s5noc695x59l57rrX3nvu7Pl8XJ0Q0WVZSbelb2/3AKCSNNtpoo42WttrSNVtMIvTUdBMjSTN91jOSLINGoJDc5mBGEhfNfAldrOyTWd2hHYwkvk2MJG1ThRhJ8sg41zcuR2EkkWBYyQO37D67jurJT5nT/vC0weJ1Jm1lgkX5uZYJZreupPkuEtawkuzWFf1fHLHAGLq+LXleY4sx2J31+U5g/nBP+KErIeM47viQP366YzbNve973/vogTc84PNd0V74KHM8NTyU72UkccBG2sRIslVKw0Zax0gKCmFMmxhJqlBk5uGs3zlkJJFjJMkddt0N2UiYkaS+iT/u7zzt1wxTisLDH7lkGXaQY1TZ84FhJJkbfMmQwv1v+10zdvxNNBvWVdQdmtnjmEaAkYQqF5iR5E6cVUaSLMKnjCTX/3Y8ITZSzEiS/QQRZ5Zp5MZTnZEkx6/u9zojKS8UxYwk7mAkKabRfFwBKwk+XDnMR+6EFzCSCqcucW6+tddZjYwke701GEmjjTbaaKM1P4GwJ436jXwnI0kokRArySkqTJyYkSSuZmNTNuGiYpVIHQoN9yRUX8x1M5KAsmu5OIkUGpGiImIkBYqmgl3SiujPyRXLtlbXtukpu3bFWm6cT6RLmrhqa3Fbk4qmnfvV7jV1DRMKIuT+JuNMrCQYhyL3N+2Stt+vM/VkXLqVSSWSdCWT+a7cx0Qno/7cfQ3F2buV6ThTXmhXNRHnYjt5Zi7JOHP/izxHrm17V7WTfZzzc3UTqrdniZP15z7OmZpW1PaIy3u1PUJxh/aXjCufjUOTC5vooD/6x750eV80+fnd7j7vec+jb/r6b6GPe/bHzePiwQc/RN/wzV9Pb/rXP6Td0wQLTLu2gfEVjEfbbpzs8/Ds7Fw9cT+54eNnjCTJ/IgZSUYhVyPkWEZS6GdGmJFktCtuu0pwnkJdmTCSfOcbJaK4lYt86jNFWBC9ykZalDGYsRLSizBSqdlFLHRvK4EyKbxqiCsRkI0EEVWBAgiy0dsUSU3KJBmvwkgiOJ60AjowJdzESEqVSZCRVCAjCSeo6C84nnSCrWEkUSMjCdLRIZIqYyQZBVADI6mqTCqJAgixkcT4RWykOV6VkZTDs1vd2wYjabTRRhtttLQx+acx0xrsVQwax44BzJfIxQaqjQzhooeRlPA3jsOMSZgvkCcRMJKYYubSBuZLzkjinJHEl8tIYsBIytb3q3X+al0/b2ckhfleHzlpvnMl34kSB8IVTDCO2WKXlu8bmGAxI4mOx0iK2EYBI6k6XoggI4mBum73v++//376y3/+L9Ozf/Oz58/uCjrf9U+/i/7xP/1OkJ/2dTsjiTNGUo3nFTA/qJWRlACxuJKzBBhJ5qSl8gMxkpgx8yeYHFTusWD1cBMjiaNJCzB62KNzoNqXABvJ9BCnCCSKPsDpUdWbkbGRMCOJUh4a6h875iVniFNGUgCZMfscMZIIOItSMvYDRBfof+tkidhICSOJGxlJm68l6owkbmIkUR8jCbCRYkZSPlwZMZKol5FkSEY1RhIlu+3isWckcc5IQmykhePHlSwKrp3ANRR3XkNdhTYUSaONNtpojc0+qYnc21qXBpWAHbMIfNoYSeET5DWMJKVMwowkxzYKGUmIHQMuSirKpCVeIyOplfki43QykmbliWECbHVtm5QJk1uWZBDsNnfvbkZC8VYOipozl6i7z6g4oi0uaVpBh13bhCuWesR4cFsjz1o6U/2w5OcSXz9JVXFEvksFkTw+Ko5IuHPhwibzfVZMmXyfXc+MQmKJo5UDkyuceoQ9u7aRYyQplzQZZ1JMmeNydr64sMl8n138zLhZFFNFMZL2cSZmyJLvixugVuLBOCrPtaLvzMY5KA4m1za15Kwwnc5KLY3gOJ3d1ohe9eWvohe+8EVLzhPRj7/1LfRN3/KNc7zJVc3FOT0T75V4fFXG416JpMcdSeWYZJi5R/gEFT9LAhybkWRd2pBbm/zssVzaaowkrGSIGUnRUp2SuLUhlzaOPde6GEmwe4EbGmIkNSiRHCMJX20UoNTC6VRWMpLs4S3KpTIkchmFTXStxNaBLXRpMwopoLDpUYBljCSoREIB1fxbc8lbwUiCLm0VRlLo0uZHLHJpqzKS7DxQYSRFa/VCRlLVpa2RkRSOljYFUtWtLXJpA9dXo41C0mijjTZatSnIcTGsl+SZDW1ixtgnNbSRGWNVHEWplhzrRe4HYCSRjePKaBE7BnZsAyOJbhMjyew6YCTpOJZjcGRGkrkhtiIUeVxUYSig2vjf80/XahBumOePy3z3DItKOgcDAcQJ89yOG8NIAnG6812NGy/68SQnEo9uwQBBb6eMpIThRXZzl/70h3/5Xy/45N9Bv+fln3+xdHNq//kDv0L/6Du/nR5++MPq+Mj5uJpQ3eMvcw/ENy4tjKTQsWgLI0lBVgxzSbCS4Di1u4dgyGLpi2f09DGSdAFKM3YoYyOFjCR2jKQ5nmS5EO7vjJGUIKgCRpJn/8z9lXil6d3DjKS5aMqsjqePY+cVW/kQrB6wnxFzKV5Eaftfb77bP9eBMSMJwekxIwkwlyqMJBZF+JSRZOMZhE/U7xEjael/gswlzUha4vQwkuYCuIzTyEjydbk2RhJ1MJLk/AbZSCkjafozhnOHSu0mRtKyY03Kb8qXwo1C0mijjTbaaPqcEa2FLv4mJGMklV5GEnLBytzaagok+0jFKZDsbjH6uHiw62zmzIN07F5F4mKum5EEHg3Fbm2B65R7kB0pkEyc0sBa2ujaphQVs9IDubX5A+cYXtTL8AriNCjuoOtbY743u7515ztO3BoLzCO/sPKuBPkej5ttLoc+z+08tNKVsOB8966EOM/Dco5x0fOHf4nzyi/5Mnrmb3rmvK+PPvoo/at/9YP0hh9447LNNg6WBG2d7QUcGrsS+fxGmyGURCEjiaAiNNwuy0iqKpSiwhDervUKpQjdAyE9RvBQdxEDECcQHSmU8H1fBD3y3nBeoYQZSQVO5AXTkMP7Wy5VShaWJIXKpIJOl7ECiyJGUkm3pxhmTzKqmhhJIerHMZKQQmk9I4lL4JIWMpIIMpJcuhqFUp2RVFYxkkojI2lRXOL+aWMkGYh2AyOpBPkYK5TAxxErifB2tSqUQmWSYSQ5hZKb3gYjabTRRhtttKRBZgyvYSRZVkzAjKlwOCghZXQzYyhiJNGRmDF0VGYMQTpAxkZizEZqYiRRzkiiy2UkEWAkUcJIQsyYVQyvMN9b3a24nu817gyKYxleXMl3quU7XWq+U8pP8fkuxwRXGUl8PEZSB1Ns4U8QImbErCXyTLGXv/z30H/5aZ+hLsR/7r0/R//gH7465X8w4FlsZSRRxkgim6vcODc3MpIoPdgpx44AI0kL9DQkBTGSlpzjeLcIxFOMJMBc6pgjZiWhZPQ0cdS4wkrSY5wSVlIGUaoyklLuHwWMJAa8vsxv1XCEDCOJUkYSBWdRbmIkLVOVZBrlZ2XLSsJTKAtGFVdYScmv1RhJHPc7HYmRRE2MJO5jJDGHrKRE54aHK2IkcS8jifSMX2MkVTbTnkEcI4lyRlLGSpqvN6idM4kYSbThWupObkORNNpoo43W2GqubfKkWFJGElZ8OEYStTGSQnLDGkYSUmqE7m3bFBaOtVRKsEBFKiwaGEklcF1bq9gAjKQLV6wDm0gqLLa6tk1P57BrG124U124pEnXNue2tuQrclubPr93WztXedri/iZ7/B7pIifjCFcvClzbSkFxztTStTnORT8s+a7dypZ8l8dFCg4uXMlknEO+a3e5wEVO5Lv6XfEDs2vb7La2zzPt2kapa9t8HGUc4LY295qIM22nzoc940gq8WR/XigODnmuXdtQf54rJZ7Oz4WRdKL2dxkvJ4c4pzI/D7/7is//AnrKU548b/suJ3/4TW+in//5nzPKGTaubUuea9c28NQ4GI+23bhxss8T4R64a+p3Q4Udxa5ol8JIkp/1jKSympFUot1qZCSZeFVGklzyRsq1sXhph9lcvMNopV47I8lLlLQAImMkIVZSsNfWrc30TzGuYU4B5pRgvYykiFFVulzbUre2UIlU/Pm4mVEFL86aGEkkrpgwowptV5jg6xlJri8bGEkmL2NGUgFCxAZGkhu3OSMpUmyGjCRC4wkvVaOMkcRYXeTihIgmoNhOl7613Q+MQtJoo4022mhpa10aRAEzRlJ61jFjNNNnPSOJlLOb/J8FMVYAVIYN84Ui5ot9Mqs7tIORxLeJkVRhx1Ds/OKdbNbkGJknwvpxslcm4adoU35GT81y1zUZh6AaoxqH9ZO/Kd+hAwv4vs5PFswlMg5MJi+DONoRSB43reCbGTfWNdFtDzsGGFsGBVA0zXlutyd8om72Q46MpD9dnCi/5DzDeiJgxopAOf7YDQLz9FjAo9jNM0yf8RmfSZ/8/E9WF+Pve//76IE3vq76NFou9XTjZcMcD/PRvN/LSOKAjbSJkaQ23LOR1jGSgkIY0yZGkioUmXkY9zeZeSlaGrYwkuQOe9O6gid0wEhS38Qf93ee9muGKUXh4UeUcfLsIMeoMv1kGUnmBl8ypHD/237XjB1/E82GdRV1h2b2OKYRYCShygVmJLmJrcpIkkX4lJHk+t+OpwLZeREjSfYTRJxZppEbT3VGkhy/ut/rjKS8UBQzkriDkaSYRvNxBawklG/T9S6C+SGVUQkuaKNCkWP9tTGS7P3AYCSNNtpoo43W/ATCnjTqhaZORpJQIiFWklMQWfZM4bxOhZ7QJuwYx0jyNnMmHoMnofpirpuRBJRdy8VJwHyhBrYRdH2j8PhMbmjaxGy7a9v0lH1x1yoKpj0pkRRMu1DotnZ+cAHTT/wXJZJtOA4dXMx0ziNFE4wj8n2OY57YLq5t+sm4dH+Tyrsz4c4m831yVRPGX3uXt1nZpRkOKM7e/e3MfvziU8txL0qBsHdts09ErWtbAe5vReX7FMcq+JRSSzxRl65zOj+nOHpaUdsjtvb84Lam3YFMnos4Z8JFTsY5A3H2rm1+vOy+9Zm/6zPpoz7qqfN+3rp1i/71v/lh+rEff4uHae/inIL8FC5+7kK+17Xt1LoQloOyzud/xkiSzI+YkWQUoTVCjmUkhX5mhBlJJoPcdpXgPGV2z9/JOlMxOD+XkNHj3ckwwiVnJNXYSIsyBjNWQnoRRio1u4iF7m0lUCaFVw1xJQKykSCiKlAAQTZ6myKpSZkk41UYSQTHk1ZAB6aEmxhJqTIJMpIKZCThBBX9BceTTrA1jCRqZCRBOjpEUmWMJKMAamAkVZVJJVEAITaSGL+IjTTHqzKScnh2q3vbYCSNNtpoo42WNib/NGZag72KQePYMYD5ErnYQLWRIVz0MJIS/sZxmDEJ8wXyJAJGElPMXNrAfMkZSZwzkvhyGUkMGEnZ+n6lUFLr+nk7IynM9/rISfOdK/lOlDgQrmCCccwWu7R838AEixlJdDxGUsY2WsNIIooZSUT0rGd9HH3aiz+Nrl1bLkUffPAh+n9+5P+uugtRxP3YyEjijJFU43kFzA9qZSQlQCyu5CwBRpI5aan8QIwkZsz8CSYHlXssWD3cxEjiaNICjB726Byo9iXARjI9xCkCiaIPcHpU9WZkbCTMSKKUh4b6x455yRnilJEUQGbMPkeMJAKqxuhsbNlIFHcvUGkiNlLCSOJGRtLma4k6I4mbGEnUx0gCbKSYkZQPV0aMJOplJJkZv8ZIomS3XTz2jCTOGUmIjbSco7iSRcG1E7iG4s5rqKvQhiJptNFGG62x2Sc1kXtb7LqGn4g4d6xZ4NPGSFrtaoUYSUqZhBlJjm0UMpKEMgm6rpk4gTJpidfISKLA1coyC5xio52RBF2tpDJrQ5K5Nfze9R3Yn8cuItFTvqrLYKTAM0qvZiZYLd9pW74/ZkywRrdCF6fyBDNW4kXjxqZSGxMsVuLV3Ap1fy7MpWXhh4fHLMf9ZS/9XHrGM56htvk9P/Nuev3rH1gUdCYvZEe4B+Zlu3ubVO4hJorOYwLjLliqdimMJOvShtza5GeP5dJWYyRhJUPMSIqW6pTErQ25tHHsudbFSILdC9zQECOpQYnkGEn4RFCAUgunU1nJSLKHd2L0JG50UtnU4tKGDzd2fQvYNpS6tHkFWMZIgkokFFApoWsueSsYSdClrcJICl3a/IhFLm1VRpKdByqMpGitXshIqrq0NTKSwtHSpkCqurVFLm2Er69GIWm00UYbbbS0Kfv1YthG8bfm707/aU9Q/YwkDWtYz0gS37QIJAZPQgEjiWwcV0Yjx5BJOraBkUS3iZFkdh0wknQcyzEoR2EkuTjoYaE5LqowJJe+pb/nn67pAlOv2ujxlO+eYVFJ52AggDhhnttxozcYxenOdzVuLKcLMM5Ef8ABgt6efsaOF/sLji1hN3fpT3v4P+VTXkgnJzfmqDdv3qSf+Im3qifPjuEkWSM4ATbO9Zl7IL5xaWEkhY5FWxhJCrJimEuClQTHqd09BEMWS188o6ePkaQLUJqxQxkbKWQksWMkzfEky4Vwf2eMpARBFTCSPPtn7q/EK03vHmYkzUVTwWTDcey8YisfgtUD9jNiLsWLKG3/6813++c6MGYkITg9ZiQB5lKFkcSiCJ8ykmw8g/CJ+j1iJC39T5C5pBlJS5weRtJUMFJxGhlJvi7XxkiiDkaSnN8gGyllJE1/xnDuUKndxEhadqxJ+U35UrhRSBpttNFGG02fM6K10MXfhKQKj15GklN4lNytrabIsI9UnALJ7hajj4sHu+uUGSQu5roZSe5snrm1MXBhASY/HCmQTJyC3bhknK2ubdPTXumKJW+cTw5uYhfMFnHgoNuacTeTeXlycnLxCl3DnGubdQ1b8nPvIkd75g8HcQLXtjlP6bBfzEucqT9RHONKJvNduZiJxJVuZTLffZylP2WcKd/RcS/Ste3AXIJxCo4j8/2ekxPj/rb0p4vj3PRkfk5xzlRCq3wQCiTt2rYo7mp5fqbYTTS7tp2KOHQ4LtP7u88+//mfRL/t4/8Llf8f/vDD9LaffNvFd27s8mrn8nZ6riYW7dq2zD/atQ2Mr2A82rYbF1M+SEbSyY39/p4i9pf9LaFIyBlJBBWh4Z2LZSRVFUpRYQhv13qFUoTugZAeI3iou4gBiBOIjhRK+L4vgh55bzivUMKMpAIvGgqmIYf3t1yqlCwsSQqVSQWOhVCBRREjqaTbUwyzJ77vbmMkhagfx0hCCqX1jCQugUtayEgiyEhy6WoUSnVGUlnFSCqNjKS54BT0TxsjyUC0GxhJJcjHWKEEPo5YSYS3q1WhFCqTDCPJKZQCBfgoJI022mijjYYLHw2ubW3rp32haCkYaWlD/gDJQLmVcoBDAYL6PpcgTv5xjiQhzgWOG+ItiiTQofNrpj9QSislfXBSkejtUHmidwgwkua3t7u2ufX9zoUskUqI7ZoKT9bNqpeRJPNcspEocPuBGyTyHTMeakoQdvkeu60ZRpIKwc49MXr26DgeJQJ8kMpPMvnu+CklYIGRiQPUeQQZScFOGw5IYUTTkPkOE9qPZ/Uz7BWO4Rf0kH7B838HPe2jP1q9/8u//H560w+/Sbm11RhJizJJ5/umARi6twn3wMT+2vYwASWQdCGCD+QLlryxcyWruaz5eZSAIsAqPvKFUCCeFSYkdvXxHCH7H7l9aQWYrs8wdN0i009TcTkQjOhlstCtFCtQ/OEyrm123rRKXKP4KMC1VE/y9j+NkgUzzP1DIr9eFipafL1GK8B8v9tFrgXO74Wxix9UyAGljvs1xi53bnsipc38aaOQ8gmulSzobVXowwq1yBbQn1d1h1lFH1UUZIgnJ9/AS9biQpyjYFklnnVZS5b4onnSXjfO8xuXPH3n46DntyX/K0vXApdOt33DrW0UkkYbbbTRelvNtU2XIxqYMfAJbT8zJiQ3PFbMmPnnK4oiy1oqJVigIhkvDYykEriuNTJjWhhJs/KkaGbMVte26encGXRto8UlzSw20m5rS76en2M3q8VtTedp5P6GXbGk25qJo/pBxllcxkpBcfTSNauoodmlS7q/Lfl+PruwacGBVTpN+a62R+T74o6n8126mMkf8G5r+3jatW2JM7mw2Qt1Fwe4rZG4WZ/c1ialioozPUkXSrzFDVAyjcT2mP6EcUi4thlG0pnaHunadq6WZTz3uc/ZL2sT+f9zP///0Uc+8vB8fPe7ry/8tWvbkqfT+05B0evaNv2uZCXJ8VUyRSnFrmiXwkhSk4ZjJJXVjKQS7VYjI8keIBMe3FFqV8lIEYNcSvEO4zpEKyPJS5S0ACJjJCFWUrDX1q3N9E8xrmFRYS50kasykiJGVelybUvd2kIlUvHn42ZGFbw4a2IkkbhiwowqtF1hgq9nJLm+bGAkmbyMGUkFCBEbGEl+Yg1GK6WF9JCRRGg84aVqlDGSGKuLXJwQ0QTYkenSt7b7gVFIGm200UYbLW0tiiQyT2q8s8wWZoyWNqxnJJFSLcn/WRBjBT6Z1cwXipgv1pFNd2gHI4lvEyOpwo4xz+IcI4mPzEgKHK/Y8pNKX37KnCboqFSHxetM2spIivJzLSPJbl1J810krFc4QSpSgFTibEDJPK+xxRgq5tbmO4H5w+nbfPiAkQTyvZOR9JznPFe5te34SD/7sz8rnpTbeAy2D0O4t87x1GBc1MtI4oCNtImRpDbcs5HWMZJqCqd1jCRVKAIKjajfOWQkkWMkyR32pnUFT+iAkaS+iT+OJBX6a04REx3+SAFilBmOUWXPB0ZJa27wpYIF97/t93ZFEmKLO4YQB0wjwEhClQvMSHInziojSRbhU0aS6387ngpUMEeMJNlPEHFmmUZuPNUZSV651c5IygtFMSOJOxhJimk0H1fASkL5ZhVOXGEkleCCNioUOYVfGyNpKJNGIWm00UYbrbnVFEn1G/lORpJQIiFWklMQmTgxI0lczcambMJFxSqRyDCNShCPwZNQfTHXzUgCyq7l4qQglJRnJLnurrlXoeMDnkv7H16RY3F/yhtnpUgqrfkJoPHhVVLsrobz3d90l835fjlMMJ/v2F2MARNF9U/ABKu6HDolX5Lv6iZ0qyuh7o8aE8y5EgaKSOS94ztoyaMn3f8k+tiP+Vi1b2dnp/TT//HdRpmS96d3Jdx+ET+PL/TEnaL89tORZH7EjCSjCK0RciwjKfQzI8xIMtoVt10lOE+h3k0YSXZ7yLjchQogqi2FyxlJNTbSoozBjJWQXoSRSs0uYqF7WwmUSeFVQ1yJgGwkiKgKFECQjd6mSGpSJsl4FUYSwfGk583AlHATIylVJkFGUoGMJJygor/geNIJtoaRRI2MJEhHh0iqjJFkFEANjKSqMqkkCiDERhLjF7GR5nhVRlIOz251b7uqyqRr49ZwtNFGG62tsbiBnl4njs0qBo16GssHBMvySpy42EC1kWa+QHyK/Gc+sHxfM2iCjy/MGMWO4fkVrS5nyI6xaiOGj6YdlsbFM7+JGDLin30bE02CL5DaVcE0oia3tCzJmDUjSbGSsidlTr3Ec7wlx/oYSe35Xh85ab5zJd+JEgdCyZVak+90e/KdQb7Lfyjf0Xhxjm4iP8U2on1Ix0uQ5xSgmJjQPjNmJYmN/6RP/CS6//4nqQx5+OGH6Rd/8RdcntYYSWS4H3MurR5+Uc7r8UQVfl2UDdP/aRaaTiV0sLmSs/YoAkmOyg+9DYc4zPDng8lB5R4fcnjqJxUPqrs4mrQcR205rpTMEfis4HoI5bGax/EHOD2qejP8ucyPdQbntOjwo/6xY57FK/upwM2atcGt+x9NUZZHhvcAIbpw/4t49kCDs56bG8HcqufYY11L4IuHYAqG8YIB7q8t1OZ7tiAzpRkTDVc9Nv21QVWOiWZ81e96jomc3XT/y3h27Jp4KH0ZzJMs42VZFFw7gWso7ryGugptKJJGG2200RqbfVITube1Lg0qFeWHfqIdM5LCJ8hrGElIqVFTWISMJKHUgK5rJk6gTFriNTKSVis22hlJF65YxAc3seV4Tm5rtrW6tk3KBOXGJZYaaZe0ZX+0G9qSp8gdjCYXMGbHSsKubQXGp4M7GE9MIZHv0tVL5qeOv+zz3pXMsIlknAsmz/IF7ea2HN/luJyrfL9wJZNxDvmu48j+XI6vVA4odzMhi9eucNjdL46jj8u8PSLfdX8u40a51BUbZ98PkgmG+nPXSzCO6U+p6JOugpKRdKJc4aRr2z7OzvXs6U9/Oj3pSfer/N+9/9BDDy4uaSeH/jk9Uwq8yVVt79pG87ypXduAqiEYj7bduHGysMKE5EG5xVGg1AsYSUSB0GUzI8m6tCG3NvnZY7m01RhJWMkQM5KipTolcWtDLm0ce651MZJg9wI3NMRIalAiOUYSvtooCS0bKaP6GUn28E6MnsSNTiqbWlza8OHGrm8B24ZSlzavAMsYSVCJhAIqZWjNJW8FIwm6tFUYSaFLmx+xyKWtykiy80CFkRSt1QsZSVWXtkZGUjha2hRIVbe2DMZNw6VtFJJGG2200TobXBJURXJsZcbYJzW0kRljVRxFqZZKaLKEGUlk47gyWsSOgR3bwEii28RIMrsOGEnoafLcHxtdo/xTR8OMMU/KtIvc8rcpz6KnZ5mCTsUppFQe9Tg638nA5+HTxZC54hVEklAklXtzOrNRPc2sCFLqgqXbIvc3qZBK4hhVHRtGkn9a7uOoGQM9UZd5YccNaZUMZdsTOOahJ7lT4RIppLRywTxtlr1qbN7cA3TRfu2RR+gdP/l2MO+ZePO266VvbrysHn+Y/WHf72UkhSZ0WxhJCrJimEuCleSOS8pIwktfPKOnj5GkC1DedSoUQ4SMJHaMJOkiZs2dQlstDuK5hx0ZI8mzf+b+ooCR5HYPM5LmZdRi3sJxrNuorXwIVg/Yz4i5FC+itP2vN9/tn+vAmJGE4PSYkQSYSxVGknUVDBlJNp5B+ET9HjGSyLqH2XjWLc+407UwkqaCEXLdqzGSfF2ujZFEHYwkOb9BNlLKSCLtBkcVRlI4r4HCk3LLa1B+U74UbhSSRhtttNFG0+eMaC10yozxDJpuZoxTNF0OM8azkchfFSBGEjmbOciMKbROiVR1fbPKIefWxsCFBZj8cBszZn4iuFNoCPcuGWera9v0tPdcuLbJQuak2LEHDrqtXcQ5n9+TeTkpkWzDrm2k4sj8nNzQLCNJxRH5fq7c1pZbh0UZpfMdxjm4a81HTOT7xfZMF9oicRf3t6Ly3cfZ/2FyMZNP6Jmka1tRaTG5rSnfQRnHKPhkHJnv3v1t32Ac6YJnXJDm7TEJrVzkBAtscn/TT77jPJ9d24zO4QzE2bu2LXGe/eyPo7vvPgH5XxbXv9NzZwB9EefU5ydR5CrY79p2enou4NALI+min1nHzxhJSkkUMpIIKkLDOxfLSKoqlKLCEN6u9QqlCN0DIT1G8FB3EQMQJxAdKZTwfV8EPfLecF6hhBlJBV40FExDDu9vuVQpWViSFCqTCjpdxgosihhJJd2eYpg98X13GyMpRP04RhJSKK1nJHEJXNJCRhJBRpJLV6NQqjOSyipGUmlkJM0Fp6B/2hhJBqLdwEgqQT7GCiXwccRKIrxdrQqlUJlkGElOoeSmt6upUBqFpNFGG220xtbiitW2ftoXipYbaFZKovwBkoEUK3clDhQ15vtcgjj5xzmSQDnTKm6ItyiSQIfOr9hVTnbLYQ+U0oudm1fwNnRh0RurlVn+Z7a7tlnlWuzWxlFaBbDinvxsyfcWd6u4MLoc7tj1LYxjlElaCRLkO9fynS8139nkOyX5rlzbgrrjokyKFYi50hDkOxw3BMfNnO/uiXz0hWU7/+7f/1r6e3//awmNaCdwqjCSPDx+q3tboNRTSh9O7a/tjERACSRdiOAD+YKlnexcyWoua34eJaAIsIqPfCEUiGeFCYldfZLRov+R25dWgOn6DEPXLTL9xAKUj8aHXCaL3UqxAqUEroslkFixVeIaxUcBs57aL/efRsmCGeb+IZEb5FjR4us1WgHm+92M62m7nLsddvGDCjmg1HG/xtjlzm1PpLSZP20UUj7BtZIFva0KfVihFtkC+vOq7jCr6KOKggzx5OQbeMlaXIhzFCyrxLMua8kSXzRPFnd2kPGS9J2Pg57flvyvLF0LFKhu+4Zb2ygkjTbaaKP1tporlr49yxhJmI3kGEnUxkgKyQ1rGEnItS10b6sxkiqKotDNChckmhlJJXBds09Q3Y14OyMJu1ptd22T7k3FubaJG2dU+rAPEEvuZlV1XavmuyzIBAq6lnyPCpmNSjyCyjHgstSZ7/N46XEpnPPcK/HcuGlkgUV1kdilUO+PVeIt+dTJFKMk31U8PF6se5t7Iozy3cyDOj8pyM+yaY7nimtYrCil2BXtUhhJatJwjKSympFUot1qZCTZA2THu7+jRP3uFTHIpRTvMK5DtDKSvERJCyAyRhJiJQV7bd3aTP8U4xoWFeZCF7kqIyliVJUu17bUrS1UIhV/Pm5mVMGB28RIkjMPZlSh7QoTfD0jyfVlAyPJ5GXMSCpAiNjASPITazBaKS2kh4wkQuMJL1WjjJHEWF3k4oSIJstKqi19a7sfGIWk0UYbbbTR0taiSJLFJILOMlsYSVrasJ6RZBk0UlFhNyd6MquZLxSxkqwjm+7QDkYS3yZGUtHsGMBIkkemWPXERkUS2/1CpkZW+zHvfnt+ypwm6KhUh8XrTNrKBIvycy0TzG5dSfNdJKxhJdmtK/q/OGKBoQEl87zGFmOomFub7wTmD6dv8+H9eLG/wLpffbylg/zhzxVebrS57ZMFpq1KJDweOERk9DGSOGAjbWIk2SplpnBqZiTVFE7rGEmqUAQUGlG/c8hIIsdIkjvsTesKntABI0l9E38cSSr015wiJjr8kQLEKDMco8qeD4yS1tzgSwUL7n/b7+2KJMQWdwwhDphGgJGEKheYkeROnFVGkizCp4wk1/92PBWoYI4YSbKfIOLMMo3ceKozkrxyq52RlBeKYkYSdzCSFNNoPq6AlQQfrhiFE1cYSSW4oI0KRe6808ZIGsqkUUgabbTRRmtuNYVG/Ua+k5EklEiIleQUFSZOzEgSV7OxKZtwUbFKpA6FhnsSqi/muhlJQNm1XJxECo1IURExkgJFU8EuaUX05+SKZVura9v0lF27Yi03zifSJU1ctbW4rUlF0879aveauoYJBRFyf5NxJlYSjEOR+5t2Sdvv15l6Mi7dyqQSSbqSyXxX7mOik1F/7r6G4uzdynScKS+0q5qIc7GdPDOXZJy5/0WeI9e2vavayT7O+bm6CdXbs8TJ+nMf50xNK2p7xOW92h6huEP7S8aVz8ahgwub7CD5vnwyLN9nwQa5cbJ38ZuYRXMc6Z4mWGDatQ2Mr2A82nbjZJ+HZ2fn6on7yQ0fP2MkSeZHzEgyCrkaIccykkI/M8KMJKNdcdtVgvMU6sqEkeQ73ygRxa0chnLnirAgepWNtChjMGMlpBdhpFKzi1jo3lYCZVJ41RBXIiAbCSKqAgUQZKO3KZKalEkyXoWRRHA8aQV0YEq4iZGUKpMgI6lARhJOUNFfcDzpBFvDSKJGRhKko0MkVcZIMgqgBkZSVZlUEgUQYiOJ8YvYSHO8KiMph2e3urddVWXStXFrONpoo43W1pj805jJGStzwYrjGYepg4qDnWtUxEqyegnWz5yda5T5B1yxDltA/r8IulARi9d5g1moi9hsnTZuQg5VB5swvePAJc3HM785b4v4ovhn38ZEk+ALpHZ17j/m5ClWY5JNjmxzbkn3texJmVMvLY5eS471MZLa870+ctJ850q+EyUOhNJ1bE2+0+3Jdwb5Lv8RdknjiCTDNhH1NqJ9SMdLkOfwbW4YL0TW1pAIqims6xoDFhhmJJHhfjDTJuc2pijn9XiiCr8uyobp/7RTnk4ltOtcyVl7FIAkR+WH3obF4Y/THo86/3DcRP+reFDdxdGk5dwFl+NKyRyBzwquh0Ae63kcf4DTo6o3w5/L/FhHzp/R4Uf9Y8c8i1f2U4GbNWuDW/c/mqKsQyneA4Towv1vnSxZHWB71nNzIyeul64jtlxL4IuHYAqG8YIB7q8t1OYzcHSlNGOi4arHpr82qMoxTe/IeIScWTl2rmQYz45d4PRq05ex+yiLc0mcRcG1E7iG4s5rqKvQhiJptNFGG62x2Sc1kXtb69KgErBjFoFPGyMpfIK8hpGklEmYkeTYRiEjCbFjwEVJRZm0xGtkJLUyX2ScTkbSrDwxTICtrm2TMmFyy5IMgt3m7t3NyMGFlbJIPClTcURbXNK0gg67tglXLPWI8eC2Rp61dKb6YcnPJb5+kqriiHyXCiJ5fFQckXDnwoVN5vusmDL5PrueGYXEEkcrByZXOPUIe3ZtI8dIUi5pMs6kmDLH5ex8cWGT+T67+JlxsyimimIk7eNMzJAl3xc3QK3Eg3FUnmtF35mNc1AcTK5tasnZhWvbuVqWMb2ezm5r+on8XhHk4aiLQsnEORVxZC91urbNv2skNmfCda4Qnq8jRtKSAMdmJFmXNuTWJj97LJe2GiMJKxliRlK0VKckbm3IpY1jz7UuRhLsXuCGhhhJDUokx0jCVxsloWUjZVQ/I8ke3qJcKkMil1HYRNdKbB3YQpc2o5ACCpseBVjGSIJKJBRQzb81l7wVjCTo0lZhJIUubX7EIpe2KiPJzgMVRlK0Vi9kJFVd2hoZSeFoaVMgVd3aMhg3DZe2UUgabbTRRuts0B2oiuTYyoyxT2poIzPGqjiKUi3F7k6YkUQ2jiujRewY2LENjCS6TYwks+uAkRS7c21ntThGkrkhtiIU7SInbvACqo3/Pf90rQbhhnn+uMx34MKXp3MwELCbH85zO24MIyl0BezIdzVuvOjHk5xIPLoFA4Sx21DMSGphGvUykggEQIwkDlwJL4eRREdiJIUCqy2MJAVZMcwlwUqC49TuHoIhi6UvntHTx0jSBSjvOhWKIUJGEjtGknQRs+ZOoa0WB/Hcw46MkeTZP3N/UcBIcruHGUlz0ZRZHU8fx84rtvIhWD1gPyPmUryI0va/3ny3f64DY0YSgtNjRhJgLlUYSdZVMGQk2XgG4RP1e8RIIuseZuNZtzzjTtfCSJoL4MB1r8ZI8nW5NkYSdTCS5PwG2UgpI4m0GxxVGEnhvAYKT8otr0H5TflSuFFIGm200UYbTZ8zorXQxd+EZIyk0stIQi5YmVtbTYFkH6k4BZLdLUYfFw92nc2ceZCO3atIXMx1M5Lc2Txzawtcp9yD7EiBZOKUBtbSRtc2paiYlR7Irc0fOMfwol6GVxCnQXEHXd8a873Z9a0733Hi1lhgHvmFlXclyPd43GxzOfR5buehla6EBee7dyXEeR6Wc0K3tunP1vVN3BAhGLeNgyVBW2d7AYfGrkQ+v9FmCCVRyEgiqAgNt8sykqoKpagwhLdrvUIpQvdASI8RPNRdxADECURHCiV83xdBj7w3nFcoYUZSgRN5wTTk8P6WS5WShSVJoTKpoNNlrMCiiJFU0u0phtmTjKomRlKI+nGMJKRQWs9I4hK4pIWMJIKMJJeuRqFUZySVVYyk0shIWhSXuH/aGEkGot3ASCpBPsYKJfBxxEoivF2tCqVQmWQYSU6h5Ka3q6lQGoWk0UYbbbTG1nIj3rZ+OrkRN9KG/AESsk03jKSSmYnpR9y5BxtSLuSuS7Fyx8ZbFEmgQ+fXTH+glFbqBtpJRaK3Q+WJ3iEG9uTT29td26ySJ3Zr4yitAsVGT3625HuLu1VcGF0Od6xoCuNYXZBSggT5zrV850vNdzb5Tkm+K9c20KMk1UqJIitXGoJ8h+OG4LiZ8909kY++QGDc+ANmH3DXGElOKbpZmRSw7pTSp6XQFFOoyLgQwQfyBUve2LmS1VzW/DxKQBFgFR/5QigQzwoTErv6JKNF/yO3L60A0/UZhq5bZPqJRREYjQ+5TBa7lWIFSglcF0sgsWKrxDWKjwJmPbVf7j+NkgUzzP1DIjfIsaLF12u0Asz3u9UeFji/F8YuflAhB5Q67tcYu9y57YmUNuLhAhvXPJPgWsmC3laFPqxQi2wB/XlVd5hV9FFFQYZ4cvINvGQtLsQ5CpZV4lmXtWSJL5oni3uMIOMl6TsfBz2/LflfWbrG+DrJbd9waxuFpNFGG2203lZzbdO3ZxkjCSs+HCOJ2hhJIblhDSMJKTVC97ZtCgvHWioluA2UCosGRlIJXNfWKjYAI+nCFevAJpIKi62ubdPTOezaRhfuVBcuadK1zbmtLfmK3Namz+/d1s5Vnra4v8kev0e6yMk4wtWLAte2UlCcM7V0bY5z0Q9Lvmu3siXf5XGRgoMLVzIZ55Dv2l0ucJET+a5+V/zA7No2u63t80y7tlHq2jYfRxkHuK2RuFlXLnXFxDm4j0klnuzPC8XBIc+1axvqz3OlxNP5uTCSTtT+Ste2fZxTmZ/GtU3250We7+Kcnql5ULu2LXmuXdvAU+NgPNp248bJPk+Ee+Cuqd8NFXYUu6JdCiNJftYzkspqRlKJdquRkWTiVRlJcskbKdfG4qUdZnPxDuM6RCsjyUuUtAAiYyQhVlKw19atzfRPMa5hUWEudJGrMpIiRlXpcm1L3dpCJVLx5+NmRhW8OGtiJJG4YsKMKrRdYYKvZyS5vmxgJJm8jBlJBQgRGxhJbtzmjKSokB4ykgiNJ7xUjTJGEmN1kYsTIpqAYjtd+tZ2PzAKSaONNtpoo6WtdWkQhQoLv5SnjxmjpQ3rGUlGzUEB0kX9gT2agHMNk1JWbGYk8W1iJFXYMRQ7v3gnmzU5RsaZRT8JtU/I4N9EfkYKpNx1TcYh4yLYGIf1U7wp36EDC/i+zk8WSi0yDkwmL4M42hFIHjft+jYrP6xrotsedgwwtgwK4Po257ndHopch8x+yJGR9KeLE+WXnGdYTwTM2EVOjj92g4B1PCH9YzfPMDg+dt4z8Uy+Txf8brxsmONhPpr3exlJHLCRNjGS1IZ7NtI6RlJN4bSOkaQKRUCh4fubzLwULQ1bGElyh71pXcETOmAkqW/ijyNJhf6aU8REhz9SgBhlhmNUmX6ySlpzgy8VLLj/bb+3K5IQW9wxhDhgGgFGEqpcYEaSm9iqjCRZhE8ZSa7/7XgqUMEcMZJkP0HEmWUaufFUZyR55VY7IykvFMWMJO5gJCmm0XxcASsJ5ZtVOHGFkVSCC9qoUOQUfm2MpKFMGoWk0UYbbbTmVlMk1QtNnYwkoURCrCSnILLsmVJbqlYyUzbHjnGMJG8zZ+IxeBKqL+a6GUlA2bVcnATMF2pgG0HXNwqPz+SGpk3Mtru2TU/ZF3etomDakxJJwbQLhW5r5wcXMP3Ef1Ei2Ybj0MHFTOc8UjTBOCLf5zjmie3i2qafjEv3N6m8OxPubDLfJ1e1qdumby7KLs1wQHH27m/7OPeUQr++XKePomt0X7lGdz2634ab16/Tw3yLPkS36JdvPXpwbbNPRK1rWwHub0Xl+xTHKviUUks8UZeuczo/z+c1ZHJaUdsjtvb84Lam3YFMnos4Z8JFTsY5A3H2rm1+vMwufk4JMbmneUXk5M5GhgU2uwqWko6v2ng8Oz2HS9fOQP5njCTJ/IgZSUYRWiPkWEZS6GdGmJFkMshtVwnOU2b3/J0sWjrlv1lCRo9fg4VX1uSMpBobaVHGYMZKSC/CSKVmF7HQva0EyqTwqiGuREA2EkRUBQogyEZvUyQ1KZNkvAojieB40growJRwEyMpVSZBRlKBjCScoKK/4HjSCbaGkUSNjCRIR4dIqoyRZBRADYykqjKpJAogxEYS4xexkeZ4VUZSDs9udW8bjKTRRhtttNHStih/Yve2LgYNXAJnlRFTXPQgKWbHlF5GEkeMJI4+3smMSZgvkpFkKxKWkcSZgGs98wV+P4XEEHahuiRGUtOTMifQ8u5tjpGQbQoqjIb5Xh85ab5bpUQTK2kDE4wxI+kZ5Tp9Qjmh5127m55V7qanl7bLpPfzTfpZvknvvnVK/+7WKf0C3zwqE4zg8Hd06m2MJCl/AgOtm5GkJwJkOufGTcgGSRlJMROsf/hVGEkkGUkU3hjzWkZScGPjFE6m35GCKBtQESNpBmJXFB0xIwnfWPr71gD+xwEjyZZ5ECMJ5AlWxoQIJKGIsey1XIHiUU2cTWQhowcdftQ/VtrkFTERIynqd8sqw4qkpd8towezfywbiXH3AmVZoLCJGEncyEiqsJFIPETbwkiiKiMJuc8ljCTARooZSdXh6hVcCMKdMpLMdUiNkYQKoKr/LSPJCsVyRlLERuKCFKSgFAnUroQU4MOlbRSSRhtttNHWNvukJnJvi13XbLzAHassJ8UWRtJqVyvESFLKJMxIcmyjkJEklEnQdc3ECZRJS7xGRhIFrlaWWeAUG+2MJOhqJZVZG5LMreFHN+DoxjlwESnhxWXFZTBS4JWWAhFggtXynbbl+1om2G8o1+nTrt2gF127Qc8sd686bLuC0+7fS67duPjv9/I5/eijj9C/vfUI/Wd+dE6LljyP8t1zcQMmGOnxW2OCxUq8mluhdV0rvrDq4DEewVECRaMsNBWAMXdxynb3NlggoiiPCYy7YKnapTCSrEsbcmvTN/bHcWmrMZKwkiFmJEVLdUri1oZc2jj2XOtiJMHuBW5oiJHUoERyjCR8IigJLRspo/oZSfbwToyexI1OKptaXNrCyhhwfQvYNpS6tHkFWMZIgkokFFApoWsueSsYSdClrcJICl3a/IhFLm1VRpKdByqMpGitXshIqrq0NTKSwtHSpkCqurVlMG4aLm1x1o022mijjQbbc5/ziezcgVY8+LYnqBZGEipQhS5rma1ZGIeo+rXwAwkbqWkzmDL/+Hqc0A6KQkER/HPfF7rjNG9uc88F8cQNXqgBa8hTdaNYUxs9nvM9pH5d/Ndzr91NL712P73k2r2XOn/8yKOP0A/cepje/ehpusHN+Q6VSNSQhR0JnQ6ntfmZ5XtTQiWuhGsm5PiJe/3iuQ7TziU9qMCTL+3I46Olax0X+QiG3KNQqgVUBaiq4KESr7K56YYGsOnaYav0d1Ywaqxgph1Sj1dJkEQY0tNPjenSvQcJizs5wG3xqv3d0CG5KX3c35S454Uw7YbMKQVfPpXSPQEFdTnNSArWrnZkT72w3tb/MZy7J42741Snt6W/3vWed16p2sooJI022mijVdpvee4nNt2h9MC4m26ckcKjuUAULVVruuMUH+i40XUfyH+gHi8vNPUViOqVoJ442r2LjHvX5IplXMMO7ldhHNGkK5a8cT45uIktccTnoziTi5bIy5OTk4vX7PPx+0t+7l3kaM/84ZVx6LBfzEucxK2MjCuZjiNczMThk8flGXQXff71++nF1+6la4f4t0z8y3j/zbceoe+7+RD9J76J94uZ7jk5mV3bZIfeY/ZryivUn5Pr3D6OyU+ZD2TzE8Wp5DmIQ5MLm/iLfn85LrMb2tmZGuY3Tvbj5fRUjxftzrY09P4un/YubDyzj7LP799fXOokI+nkxn5/T83x7SkQVesQDQWQXFfSeqePt2t14aOrQNFY2GkuDK0s7PRXjvpu92Ma8rrDnxUq1tQvY/urhFHVVdkMChQthdC1Rznq9zVb31AB6ur/jkpVIyOpZ6TBgtOmQrqBaHcW5rLCfE8/UWkpOPXvGGIktca7aoWksbRttNFGG621zNNQKGpjJPlCUciMCZAGKg5gvXQzYxoLT+sZSXRUZgxmx2RsJFMW8m9XGEkeNrN3tdLMmNQVyx5IgAcpwqGKiYELWcyMUXEOhSfrZtXF8DJ5Ll3gKHD7wYXIJd8J9BEFrm9hnMVnDbitaXM1HYLp8689iV5x/UmPyfyxUz695J576XtuPkQP0OnBDo9dvkO3NfQqE9DutHEVnNKW0XhRjojxF/y4YRcn/oKpDweubXGeZ4wkmZ9mrHPFfSfIWezeJtwDE/tr28PUw0ji6IbJMpKmX6m5rPl5lBJGEpfGglXISDq8VhlJaWZ7RhKb7UKMpJSVZJhGTJAhppbJQrfSCiOJCDN6HKPKuJUaZk+hgN1E2CXLMYSSOkg6riqMpKUwIRg9sN+t9rDA+b0wdvGLJEohI4kaGUnT9lRYSVsZSVxlJJnKRY2RZDosZyT5Eetd+QKXu2ZGkpmna4ykSsXNM5IYK5oCRpLbLjO/LflfKQxVGEnz9g23NpXBo4022mijJa1VkaTLEXVGUnOckBnTclN0eUuDti5dy38FfKJjSc/lLIWr/EJV6YRZL42HT904b1m6hguja5awtTKSeuKsWaqJOkz/128qd9EXXX8y/dZyz+NiTvkPt87oO27+6oU6KR83zSslK/nenf71X7j0pZpo3PTkdzuMW98YrFl6pW8Mty9961yq1rj0bb0CSSubckZSV8D9doF+b+v/xqVqnUsDu5eqNa71WqdAyuHlfISlb/FSqZZ4bd3ReUA6+79vwG5aqtZ0PDcsVavG6x6uTYykrlFWLaS3xjuWEumIS9W2KJquoCJpFJJGG2200RoLScdauraeGXMZN94Nt43R9V7lB5+YjKSmtW7B/t3mG29XZ9uanya/jloIfeyYYJ967Qa98q6n0Mnj7JLnlJheffZB+rFbj1x6vjf9ZVOhqacwdEQmWE9hNoq36uL5MgpFnYyksIC1sVB0jKVvWaFoc7xKoWJNIaVlhVvHUqz2zckrN9sKT2Edqn8pXVb4SJcgriwUrYdg9Ree+FiFolh5c/RCUdj/l1EoOg4jqYUh1QTT7oVa8XELRTI+UiaNQtJoo4022miwkFS9Lzk2I0kokdawkroYSQ0QpW2MpBVwYfiIdI1Co+1Ou1vh8RjeOG9TaGwtNKF8X69oasr3NYUmIvqca/fRF15/8uN6fvnOmx+iH3j04asHn3eF0ExB1F8oWjMfz+MLPXFfXWhqZCT1FK7WKGSCwtWqelrCSFp7qykDbYVxN3ZDc+Gj+b63sfCxmmkUVCLWsZHaCh8rK5v17lhZmMu/vp6R1FOY6+//xw8jqZGO3jwfbWEkNTONmut2/Uwj3P+ekdTaRiFptNFGG200WEha6iPb3NuW+6dkSdBjsHStv/C0sVCUFYy6CkXbb6SbfuFxvpQnV2xsLRRtyffjLoFD+Yr2//Ou3U//w/Vf94SYY/7p+YP0+kcf6ilbHn+pZzeMvjHfwyWaK93bwmljpTKp405DF5pWCwDqhaFVLm0dhaGju7ShgsexCkOgoLMJxt3dvVXJWb9ZX670uJTC0BbXN7TZx1z61rUEbs3WJwWPzYWmvsOxqjCENj8sNK2Y3RCEe0WhKVyyVinE1fu/saDToEA6xhK4jI00CkmjjTbaaKPBQlL3jfMTkZFUXdPWc6MrfmhTgeiSbpw3MJIuXLGIU7c1+TPaTazRtc24ZfHB5WpxSeuMY97fu6Sdq0JRX5x9P+z253x2udpvp3T1at6eKY7Id+m2Rty2PbvX/+rm3fSHRBHpdrqzrX1/p0z64evn4rgv+Y76U7qtKZe6wNVOxRH9GceReQ5cAoM8p9kVTrq27eNY1zPl5iYG3EWe7+Kcnql5cHJVa3Ftm9zWmLFroYwzvb93eTMudYnLW7XgtHIpx+OPkaRvMI/LSOpZKtW2w9sKc71lkctQIuWVoG2ub5UC0RbXt+iv/Qek7dc6FTbNBaKKwqbb9a1ScLr8pW/HZyQd36WtsbJUjbf6OcEql7arXkgarm2jjTbaaLVyDFoSVC3keBeqNcwY7faj3T3aFEjWp4m0y1LgXqP2A7jXkI0TFWBYOkzFhaHZRaVWGFLuKb4wlLnUMXBjWayt8Bd8POOqxVrRZF3SSLpQsXYZ86ZbomQVxZFuIs5FbvnblGeRS1vm4qbilMlcrDWOzncyyjvXD1EcmXvSLUvmsOrPw8eY6YXXbtAfun7fE26e+cN3PYUepg/vmUnMKt/Z5N48bqa+Ya2rm76vXfawY548HrI/9/lpXODMcbH5qdzKjM2bcpFzrm1gvNhX6+zGyXip5rl2zAs/F7j4xIwk64aGXbaszZO/cbEuX+zdoOSNlXU3E25w7rgg06OaQsm4YOHxKoc0vlNelFzadcq7SmUbCFy1jIuYNXcKbbU4iGdPVfrjwK20qA2f+wucG3H/20KI/sTS/1Ec6zZqKx/C7Qvsp+v/Knzc9r/efLd/rgPN/oF4zi1PuApG/e5cyOBVGTnXNnXBguIZc7qo39n0t32df87Gs255xp3O9VcIR8eue3D+M79ACSPJudv5hFGvNUWRdVXzroumzjP/GSuK7PmiVs9zhSzbT1Rx+0yWwl21NhRJo4022miV9pgxkrqXvG1YqpYUw9LCTvqB/AdWMZK64mxdutO4pcGjyWMtfcNubbeHGZNtmMzPx8b1zef7zp3tL971tMcdWLu17QDcf+3sl/dubnc6I6lrydvGfG9e4inh0OtdiapLzlYqlDYxkoRSZjNMO2EkbWclbV261uC61sVKav2VqH/8jmxTFLUpZNr7y7+9jpHUxkpaowhrP2zrGUmpoqiDkdS1FC6vu14KI8ktYVtZPFAQ7UtRKPUnQPdSuCA+YiS1xrtqiqRr4xZxtNFGG639xsS+yn9EsXIDFWiYWTxFXxQWWgFiajoM4kxqA/tfWtAxiRKWf+oP8pss/gt/fFZGsHidn/KzUDAwaU0EiieUFvIfYUWEjWf3AEh9xLaGb0MdhPoFI0FCiiJ5DHVfgq03by1dxyIeK6UFB08SXZw5P2lFftby3ecnDsf1fGetqOEkz1G+s1EmfdH1Jz9hi0i7ttv2L77roxZFEcxzMnnOIKEZjlkdjxvGDcFxM+enixN9AeQ5Gi+cjBdQZ/b5GeR7cxEK5LzJsUi1FM/Nem616i84R/uDLVR+7MaAnbXM1K4HqlOgaZVlqFrCnb8cNxavc9/1zRFIOcduriAwVzBQ4C7/9FEI8jk82UXnNE7HJoN+J/b9bccqB7Oe2i859pln9WAwFQSPhcBZ2SgW7Sl5OTULVSPnZ2V11govGZZ98PMaiBP9Guhb96Mcq4rrcyOeI7nj2gLO6ujaQl0SobkynTDi4arGphm79ZO6O7JyrBNSHTNXN9OeQdC1E4NziUtf9gpbe05J1UaB8lu+rrmWupPbUCSNNtpoo1VaLyNpO1TYxLmdjKTk+83ubfLq5ZgQ7ccRI2mdYqNTURQqNrZBtGWh6Biua8eCaPfnp26/99r99IrrT7oj5pzvufkQfe/NB1e6FKJPdKf/Ex4+3wPj1kq9LaZGgeLnCc9I0sqm4zKScL+39X8j/Lqfrh3+Sttm4B3YxkjC8PL1jKScUXVUmHb/Aens/74B2+zWVrFlW81ISjb/KIwkl4bHZyRtUWyGUO7VSqTjQLTx0re+NmDbo4022mijwULSsZau9TCSLvPGu3npWgjl3grjfjzanTet2Qn27zbfeLs62+UtXdteCF2T7+2F0Gdcu4u+5q5ff0fNO3/+7JfoP906P0q+N/1lU6GppzB0rELTtqWeG0yOLqlQ1Gl/HRawNhaKjrH0LSsUHQPOndUl1hRSWla4XTac++iFpx6Yc2ehqBmOvrJQVFma2bMEbmXlZkWhqOKad6kw7T6Xu75CUReFPeidblp5Q6Gos/B0pEKRjG+vt3avA7Y92mijjTZacPIu8HWpi9Ru5Mt8ElPfn8KU4MZZ1lnKAVxZ9uBB9XUTZwcyzAVHRZ1gC5vNMX+YPz6/FrVfPt7yzAkWmkqZ4+h4027sd1y/WgDr8rrEWbZT3jEW4qC7J2BjEbdj4vvg+EjXsCL6U7pi7UCXRbliHdyvDnF24FMdZ/lB7Iq1d7+S7mbT9qk4Ij/l+1KZsXOt2r1mrmpLHOySJuPsXeSCOIS3R/fntF9yO4tyKyvipk+5khWmz7+2VyI9EdzZWt//fdefRN9064Nzfy6uast4yfpz15G7/JHTisoHsvmp47j8lHHEcbFxaHJhK8v8Id8v4uZAvn8xXg7z3I2T/Xg5PT1XE5R0T5vzcxcHuKotLmz7PJHzceTCduPkZB6n8on7zv3Nfl7mo52Oyjz/ZowkPaGW9LZexCuZbubw/4s9ncSFKxbfgecps3voRhzfZ+pv6tMdKlFhxY2PB6OLHU7KdaDffe+Z7bLnPdWLcYGo1NzbxHm0qBN4dNVQcxEzR8wcuFJ0v5dq4aOkiqQi5om5k6LypowXFOac5k6NJ3F+R7oTUHAqNUaSuV6ggjNn6vfi0nX5IswH1f+iv+B40gnWwkha+t8G9L8AC06mf9zlTikEBi4u7ICCk08LX6VbdnuZ36IDVvwFKEhfMa9N8Ur08yWpw3pGUjAww/uBq9IGI2m00UYbrbGxuEEhxc9YyaBx7BgCPI7pN+1GUMqOoV5GUsLfOA4jKWG+QJ5EwEhiiplLG5gvOSOJc0YSXy4jiQEjKVvfr9b5q3X9vJ2RFOZ7feSk+c6VfCcKHQife+1uevG1G3fcfPOS6/fRb7l2T4WRRMdjJGVsIzSX1MaLzXNyQ3r+9jZG0pKvvJFjwRkjqcbzCpgf1MpISoBY7OZoqjKSzElL5QdiJDFj5k8wOajcY8Hq4SZGEkeTFmD0sEfnIEYSyEHXQ5wikCj6AKdHVW9GxkbCjCRKeWjBSUKNeckZ4pSRFEBmzD5HjCQiws6PwR4EiC7Q/5K5FLGREkYSNzKSNl9L1BlJ3MRIoj5GEmAjxYykfLgyYiRRLyPJkIxqjCRKdtvFY3/txDkjCbGRFo4fV7IouHYC11DceQ11JR6wjy4YbbTRRsvbcG1D0YdrW/rn4drWHmeja9uXX38yveTavXfk3PMjj36Evvn8g23jZbi2xfk+XNuGa9twbavu33BtCz4xXNuCzR2ubbYN17bRRhtttNHCGxMarm3DtW24tj1uXNueVq7dsUWkXfud1++jp5W7hmvbcG0brm3DtW24ttWuAYZr23BtG65tt7UNRtJoo402WuvDigojSZ4Uc4WFjUPqdUYOVV3bKiyLoherO2aSZXRY5pJjRVhW0sIGML98+HnAOFIfOOynZSXBs7tnJRUnmCiOfaA3S7MhilNsGOaSRTua/izFMpfAGv7Mtc1AqYoAQep4ja5tNk4J4ACiUJS5ttXzvaYoKm35XoVplzDfP63ce8fPO59+/V76vpsP+eMXMsH0+J3ZYE4BZJlgObPNM8Z0vksmGBovU77bPI8YazXXthIyKsp8H3Rc17Ya4466XNsKF4oRHrrfJBsJnJl0PEbIIKBosmyY4qhDdrf6XNtM/5SAQRO7tpWZ6wO3qxBFO4xh3IAJWBJmk2P0UEyNcpuBGT16fBg2kumfYhg9dde2CqOn2bWtdDGSUjaSYlNhaRJkNhFgJGV6EHmdcXjrta95LT3nOc+9Etemb37Lm+lVr/pjJGfWXte24ifWYLTmrm2Fgvmd0HiKlUh2/ikxHA7HsYwws10hI6lR0XTV2UijkDTaaKON1tl6lgYtrA1xr7zCtc0+HV6eXLW6tsXPNe2jOLyQZPqD/gCX6elTxbXNPpnVHTpf6fD06soUstfs41W/NobV9kVlDxmPzBf0mh0fTz8ddUt5gg1Yfmbpz6alb0jNYZ+mbXBtw4yjHtc2DvO9z7Utys+S5vuLrp3c8fPOi6/fS997UUhan+8gEf0TfrgyjnEcd3zIHz81b6zMdznaVri2+YfrftwQVN8RUfJQPi4UsRrnXCJlqT5w/sbFjIQ5XrDyY4rDxXY7Hqe2N2qubbzM57C/XO/WXNuWvMr6nRnf6dnzQjE77BFRBc/Pc3Fabw8JIwPwcX/nab92OJcVDnRAc7xoKRbr7TLxPGdsKbli17bD+Csc9L/t90M8jlzbRDywBJHJbJftQDMgXP/baUFeJ6ABYHagUL+J4x1wgTofCN3vSD1j+z93beNDPnEwXwbDJnRtW9KB3XURzLfp/O9OeMXMa7w8BOlxbXPnnYqSNXFtG4Wk0UYbbbTRgoun4do2XNuGa5vM98fSte0Z5To989bdavvvJNe2qT2z3E3PuXE/vffW+XBtG65tw7UNRx+ubcO1rQXudCdfoMKRQcO1Lfj54dp2jDYYSaONNtpojW24tg3XtuHa9vhxbfv4cs+VmXumfR2ubUmc4doWnRqGaxvRcG0L+/3OdG27uleo+XAdrm3Dte2YbSiSRhtttNEam31SUyDbgJqXBpWAHbMIfNoYSeET5DWMJKVMwowkxzYKGUlCmYQYSWTiBMqkJV4jI6mV+SLjdDKSLpRFxI4JcH5QEBXFjqGDgogcI0kqfCQ75kKJNOWGWGp0fn6umAfT/ihlkXhSpuKIto/jFXR6e5b8nN5XT/h2CqLzvTLKspZmJZXJzyV+Ufmu4oh8l4oseXx2cZ59/T73OMwqfO6U9z/uUbpQIxUzbvYKJZqVKlM7Oz+fnxRLJpjLz0Oewzgqz7Wi7wzmedkreUCen05xDILjdMorI/nYK4LsEjKpUDJxTkUcsVxhjmPyXMYhsZRDfl5KHua8LXLeticGgoofokDospmRpCUblpFEqxlJYHvMEqyckYSVDDEjKTI5sxtoZhPHRsKMpOWNVkYS7F6v+IGMpAYlkmMk4auNErmGEVZG9TOS7OE9KIe81s59VvV/cK2ktidRIDmFlIc9dinACkzgq3SFil3aqowkOw9UGEmRS1vISAoUmzVmk2MkhaOlTYFUgvE7K5FqLm2OQTkKSaONNtpooyVNQY6LYb3E35q/O/1nHzNm+pp8jlhnxrQxksQ32aFM/JNQwEgiG8eV0Uy8zYwkuk2MJLPrgJGk4wR254j1opb2NzJjyMQxD6blcVljd46ertUg3DDPH4N8f1a5fmXmoGeXe5b8UOPGi34c42x+DRhe6O2UkdTCNOplJBEIgBhJHMCzS7OT4bLTy9KOUGF3JEZSKLDawkiS912WuSRYSXCc2t1DMGTRP57R08dI0gUozdihjI0UMpLYMZLmeJLlQri/M0ZSgqAKGEme/TP3V+KVpncPM5Lmounc/1Ecw0hya994YSWB/YyYS/EiStv/evPd/rkOjBlJCE6PGUmAuXSFGUmyUGQZVzVGkq/LtTGSqIORJOc3yEZKGUnTnzGcO1RqNzGSlh1rUn5TvhRuFJJGG2200UbT54xoLXTBJ/KIkVR6GUnIBStza6spkNRZUCqRzGbYy16LQBJPaPUH7IN0zSZyFz5rGEnubJ65tQWuU+5BdqRAMnFKA2vJKJG6XN8CFyvs1oZc34zCjXoZXkGcBsUddH1rzPdm1zeR73dToaeXq3MJs9vXu+ka3ST242WrK2HB+e5dCaniSmgRZpFb2/RnMF6MWxtSRMauhEm+Q5fDEt4hZK5EPr/RZgglUchIIqgIDe9cLCOpqlCKCkN4u9YrlCJ0D4T0GMFD3UUMQJxAdKRQwvd9EfTIe8N5hRJmJBV40VC8xCojMS0KpaR0CSVJoTKpoNNlrMCiiJFU0u2ZX1sUSg2MJDyeaFYbcapQurqMpNLISFoUl7if2hhJBqLdwEgqQT7GCiXwccRKIrxdrQqlUJlkGElOoeSmt8FIGm200UYbLWmQGcNrGEmWFRMwYyocDkpIGdzLSKKIkURHYiRlPy+4BhjIoNRKjo9gn7dDNhJjNlITI4lyRhJdLiOJACOpVX2xhRkT53uruxXX873GnUFxiOk3lKt3+fIx1+4CjCQ+HiOpgym28CcIETNi1hJVmGKrGElcz/dmeULCSCKbq9w4NzcykihmJNU4dgQYSVqQqiEpiJE0s5Ii1RLufMNIAsyljjliZhtJRk8TR40rrCTSTKOElZRBlKqMpJT7RwEjiQGvL/NbNRwhw0iilJFEwVmUmxhJy6lZMo3ys7JlJeFLBhaMKq6wkpJfG4ykdp6cZCRxLyOJ9IxfYyRxJsfzZxB07ZQxkjJWkj2ntHAmESOJNvL37tQ2FEmjjTbaaI2t5tomT4olZSRhxYdjJFEbIykkN6xhJCHXttC9rcZIqiiKLGuplMjEWygsGhhJJXBdW6vYAIqiC1esA5tIKiyka5tUbEyubYvb2hRHuqTRfDyxa9veberCJU26tjm3tSVfkdva9Pm929q5ytMW9zfZ4/dIFzkZR7h6UeDaVgqKc6aWaqL+3PXPrz+5l65dv+eOcmervf8b6Ab9wq+dL71fyuy2dtFvhUw+7Jk/UomHXQWLcW1b5o8lz8+VEk/n58JIOpGucMq1bR/n1OS5cnkTCpGLPN/FOT1T86B2bVvyXLuwlfk+6MaNe/asrQtXuGU+s65t0xPovcubdjkk4/IWK+wodkW7FEaS/KxnJJXVjKQS7VYjI8nEqzKS5JI3Uq6NWhGDXErxDqOVeu2MJC9R0gKIjJGEWEnBXlu3NtM/SvGDFGBOCdbLSIoYVaXLtS11awuVSMWfj5sZVfDibDCSjPZHCxEbGElu3OaMpEixGSqsCY0nvFSNMkYSY3WRixMimoBiO1361nY/MApJo4022mijpa11aRAFzBhJ6VnHjNGwnfWMJFLObvJ/FsRYAYwkLtPTp3gHWLAdtjOS+DYxkirsGIpd5OyTXPMX/ZSuMFQ0zYt6lEIDPCmD/CR2eRo9Nctd12QcgmqMahzWT/6mfIcOLOD7Oj9ZMJf2b913BR8C3jeXckS+B/3p1A5iyKn8MvkpJwJmrAiU44/dIDBPjwtrhzfWjCQmHAc+PQbOOtMFvxsvQX5CHlOgvqNA9UQrGEkcsJE2MZLUjno20jpGUlAIY9rESFKFIjMP4/4mMy9FS8MWRpLcYW9aV/CEDhhJ6pv44/7O037NMKUoPPyIMk6eHeQYVaafLCPJ3OBLhhTuf9vvmrHjb6LZsK6i7tDMHsc0AowkVLnAjCQ3sV1pRpI8ELrf64ykvFAUM5K4g5GkmEbzcQWsJJRv0/UugvkhlVEJLmijQpFj87Uxkuz9wGAkjTbaaKONFraaIqleaOpkJAklEmIlOQWRZc8UzutU6AktUiQ5JRIZplEJ4jF4Eip/fgUjCSi7louTgPlCDWwj6PpG4fGZ3NC0iZl2bVsUH+SUSNMTXR1n+cElTlEw7SmOYr4UCt3Wzs/P5/8tWUuTEsk2HGe//TbnkaIJxhH5PscxEJfFtU0/GZfub1J5x2c36dYt73B2p7q27d7n83PnSnh2dr4kqcrP8xk2JKeV89l9TyvuJlfBND9FnNm1zcQ5A3H2rm1+vMwufk4JMbmteUXkpCAiwwKbXQVNfp6dncP5WMZR+X9qXQjL7P5m42eMJMn8iBlJRhFaI+RYRlLoZ0aYkWS0K267SnCeMrs3TwoBI8luDxmXu1ABRFhx4+PB6FU20qKMwYyVkF6EkUrNLmKhe1sJlEnhVUMIo8JsJIioChRAkI3epkhqUibJeBVGEsHxpBXQgSnhlWYkUSMjKeonj6TKGElGAdTASKoqk0qiAEJsJDF+ERtpjldlJOXw7Fb3tsFIGm200UYbLW0sblBI8TNWMmgcO4YAj2P6TbsRFBCCWKk5mhlJCX/jOIwkwFxKeRIBI4kpZi5tYL7kjCTOGUl8uYwkBoykbH2/Uiipdf28nZEU5nt95KT5zpV8Nzv4Lj6jsyv0yHm3rz996wwwkuh4jKSMbbSGkZTlOWAlEWCCdXM/NnIsOGMk1XheAfODWhlJHDOS2M3RVGUkmZOWyg/ESJq5KWGPR50vOSuGvxIiVziatACjhz06B6p9CbCRTA9xikCi6AOcHlW9GRkbCTOSKD432v4KuGiSM8QpIymAzJh9jhhJBFSN0dnYspEo7t5lH1I2UsJI4sFIykasT0fDSKJeRpKZ8WuMJIrmNRSP/bUT54wkxEZazlFcyaLg2glcQ3HnNdRVaEORNNpoo43W2OyTmsi9LXZds/ECd6xZ4NPGSAqfIK9hJCllEmYkObZRyEgSyiToumbiBMqkJV4jI4kCVyvr4uYUG+2MpNR1rebeFrqumbwwbnieIWISK3ARiZ7yVV0GIwWeUXo1M8Fq+U7t+f4BukX/x60P0x+49uuuxNzzmpsfog/wo+pI+nFj55c2JlisxKu5Fdo8L0meI9e1aNyQGTfGrZCCOAW7SCrXwznPjY+lGgeRkMTmMYFxFyxVuxRGknVpQ25t8rPHcmmrMZKwkiFmJCFXKbSB5ih4+83Yc62LkQS7F7ihIUZSgxLJMZLw1UYBSi2cTmUlI8ke3oNyKHOjk8qmFpc2fLix61vAtqHUpc0rwAYjCbu0VRlJdh6oMJIApCtnJFVd2hoZSeFoaVMgVd3aIpc2wtdXo5A02mijjTZa2uCNSKk+sp2/O/2nPUH1M5I0rGE9I0l80yKQGDwJBYwksnFcGc0iUrYykug2MZLMrgNGko6jSUgk+lV0OEAxcVxgQgkRqDnkcananQfFJDJP13SBqVdtdPvy/Y03H6bfcfcJfXy5546ef/79rTN6w82HYUWRi+V0AcbZ/AoTGr89F3LMeGnJczU8uTHfCQQgz3ASTBbmZLyE40Ym6LK0I2N91W5cWhhJoWPRFkaSvO+yzCXBSoLj1O4egiGL/vGMnj5Gki5AacYOZWykkJHEjpE0x5MsF8L9nTGSEgRVwEjy7J+5vxKvNL17mJE0F03n/o/iGEaSW/vGCysJ7GfEXIoXUdr+15vv9s91YMxIQnB6zEgCzKUryEj6wAc/QK9/4HWqUGQZVzVGkq/LtTGSqIORJOc3yEZKGUnTnzGcO1RqNzGSlh1rUn5TvhRuFJJGG2200UbT54xoLXTxN+WpwqOXkeQUHiV3a6spkNRZUCqRzGbYy14stPFKJCdA0EoGd4+3hpHkzuaZW5u/lCECJj8cKZBMHKHMUO5j4gvaFWv59cm17YK1IhRNKo7oT+mKJW+cTw7uZkuc/W9DtzXSLmkyL09OTg4MGe/m5uKY+DI/9y5ydMF0kocH7ZdzfyvLrcPFfl0wl85UvsM4wpXsX5x/mP78XR89/+6d6Nr23ecfMu5sS76j41IOLni7jpSuf7Y/pQJJu7YF+YnyXLrsHfKcJhc25dq2vC8VTbMb2tmZeoJ+42Q/Xk5Pz9XEol3blvFiXdim+XjvwsYz+2hq6PP79xeXOslIOrmx399TxP4y06qEFOWMJIKK0PDOxTKSqgqlqDCEt2u9QilC90BIjxE81F3EAMQJREcKJXzfF0GPvDecVyhhRlKBFw3FS6wyEtOiUEpKl1CSFCqTCjpdxgosihhJJd2e+bVFodTASMLjiWa1EacKpavFSHrooQfpm7/5m+h7v+97vSKzolCK+qmNkWQg2g2MpBLkY6xQAh9HrCTC29WqUAqVSYaR5BRKgQL8qrXBSBpttNFGa2yQGcNrGEmWFRMwYyocDkpIGdzLSKKIkURHYiRlPy+4BhjIoNRKjo9gn7dDNhJjNlITI4lyRhJdLiOJACOpVX2xhRkT53vssgQ3KMv3GncGxRH5+W4+o9ffeviOnXNe9+hDF/uIEWmYl7KakdTBFFNObI1MsSWvNGMJMpKoh5HE9XxvlickjCSyucqNc3MjI4liRlKNY0eAkaQFqRqSghhJMyspUi3hzjeMJMBc6pgjZraRZPQ0cdS4wkoizTRKWEkZRKnKSEq5fxQwkhjw+jK/VcMRMowkShlJFJxFuYmRtJyardNifFa2rCR8ycCCUcUVVlLya1eIkbQrIn3d138dveZf/POOuVJcG0hGEvcykpYj0sRI4kyO55lL6NopYyRlrCR7TmnhTCJGEm3k792xD9rHreFoo402Wt5+y3M/setMUWfGdMYJmTEtN0XABS5dChd/n7T5eH0zPNSnYSvhZRCABEVL1xrieAhLY7zKLwR/lt8vwaK4lo5RSywbl67VCkXtS9jiDdye72vzc992T8S+5q6n0dPLnSWyfj/fpD939n66xbRt3PhEbEn/+i9U43VOWGG8dfleZYrJi2HASFonbAgUP4VSO+ooDmIbNXy8jZHUcxNglE05I6kr4H67QL+39X+gaAIr9Vr6J/PD6+t/vAPNhz9YGohc7VbFa2BU5f2f/2K9//sGRL3//QZ/z2teS895znPvyGvS07NT+s7v/E76hm/8upbh2sRI6hplxtWydwLAS96SAJXNbo7TmM4pI6nS3vWed16p2sooJI022mijNRaSakvX1tx49xWGjnPjreM03DZG13uVH9xaaLr8wlBzBaga7zG58XZ1tq35afLrqIXQNfneXgh94fUb9FXXP+riW7/xv/u8J/R884uvef3F69edf4B+7NFHjpLvTX/ZVGjqKQwdq9DUWZiN4q26eL6MQlFuf53HPWKhKFr6dqxC0eZ4lULFmkJK3q2VwtOawgcoOB298BTWoTrj5XWbhC2+vlCUFubqmdNVeEoLFBkKmjMIT9j/L3rRi+mv/5Wvoad/7MeumnseffRReuD1r6O/9Jf/IuiWyygUedh7f3k37596HQkVijoLT0cqFMn49npr93rVCkmDkTTaaKON1nruiFys5rpI7Ua+k5EklEiIlVTYMpJ0nJiRNG1wyUzZhIsK648XMkyjEsRj4BYjf34FIwm4gc2sJMFI0i5WketUq3sVOj5g6X3NxarV9S10sbI3eNb1rZafyL0qukqK3dVwvntFU9mc7+1MsLfeOqUfKb9Gv/PaDfqY3/s59JRP+cQn5Bzzobe+86KQ9G9vPUI//ugj2qVtsyuhPr41JpjLz8BFD13eqy9Ytzab73K8hAoi5HKYuPC0zMcluWFBT9wpym8/HUnmR8xIMq6ZNUKOZSSFfmaEGUlB4cojiILxltyI424y1KGQ0eMLILiukjOSamykhdGDGSshvQgjlZpdxEKFU7HubSWbjff9FRQ+IBsJIqqAS1pY+CipIqkUw0Yq0f120fEqjCSC40m7xMaFpyVxSiKpKuB6gQJXwanf4fxXKHaVs655hem++59Er/zSL6OPefrT1z3iYaYf//G30N/4m39DuOfZ4ZEzkiLFnEdSZYwkU9hpYCShKt3SjZKRhA9Y8RegIH3FvFZaGUk5PLvVvW0wkkYbbbTRRstP4uJkToqfsZJB49gxBHgcSxFAbwSl7BjqZSQl/I3jMJIAcynlSQSMJKaYubSB+ZIzkjhnJPHlMpIYMJKy9f1qnb9a18/bGUlhvtdHTprvXMl3osSBcP//X3PzQTq/A6x6dvvwmvMPVagjwMJvKyMpYhsFjCRMneCALRY7D0JGEvcwkpZ85Y0cC84YSTWeV8D8oFZGEscHm90cTVVGkjlpqfxAjKSZmxL2eNT5krNi+CshcoWjSQswetijcxAjCczZroc4RSBR9AFOj6rejIyNhBlJFJ8bbX8FXDTJGeKUkRRAZsw+R4ykZdcEIyk4G1s2EsXdu+xDykZKGEmAt6i5i8e6lsAXDxGbysb73/7XP0ef+sIXrS46vPvd76K/+bf/Fn3kIx8W/V8fsT4dDSOJehlJZsavMZIomtdQPPbXTpwzkhAbaTlHcSWLgmsncA3FnddQV6ENRdJoo402WmOzT2oi97bWpUGlovzQT7TRSjLnW2O2s+LiZp+IOxe3XBEgnxCijlDubdB1zcQJlElLPK1MKm5lzlbFhlE4UawounDFIj64iS3HU7qtLUoL0q5bJONIlzQTZ3LREkuDtEvasj/aDW3JU+3qtbTd+3uXtHOl2MCubQXGp4M72G5/zmeXq/12SlcvmZ9ofyfXuTmOyHfpgiePj3Zz27cPllv0vXed0YuuPXGfkZVr1+i1136NfoVuzSqFXZ7q/lzGjXZz08d3ch8rIt9Rf+56G8ZReX6uFH04z8vsznZm8vzkEOdU5nkxLm9C8nGR57s4p2dKgTe5qu1d20Qc5cK2uEju3NaYsWvhFIfEUo69y5sed2Rc3goFSj3hQuaWTiChCxeKH5gr+0ulRAJnJD9/tzCSVru01RhJWMlQAsUHhUulSuLWhlzakqVqJVDglsTFzCpiMo3WHK9BiWRd2gq+2ijRUjXCyqiqIiZjQElFYOZGJ5VNLS5t+HBj1zdsnxcrfggrwAIByhLHKpFQQKWErrnkmT9jSSB94R/4QnrpZ7+Url+/vurcsINrf/drvpt+5mfeo5VIYMQil7YaI6nYeaAkC/mSpYGhwrrq0uYXDxJyawtHS5sCqerWVltqfMVd2kYhabTRRhuts8ElQVUkh39qvYYZw0Z9sb/L27+2MZIiFUdRqqViXtV+qA9oeBJX2EjFPqHFHbsv+rDW2eDdkU+3PIRFdE+AgGH1ujxZxF/w8fDT5Lk/lLJC4pbMU7XC0PVtpsdEccyTMnnA5N+mPIuenmWKDRWnkHFpq8XR+U4GPg+fLqI4MvfEdyTynVV/7v/wAzcfpj/Dj9KTn6BzzQf5UXrjzQ87lR6b3JvHjXESI6Py08oexmoCRvkpFBpEZmxK5YK1hDIOO4XNuNGMpOVYgvFiX9W266VvbrxU85zVnBR+jvHfY0bSoR/lKyWORRwxksy8PccL7rvMRFW4zJvjjgvSMFRg0eVw/EvQT/4ZP4bELKwknl8JqsuyDfTzuIrHS83Z7L6f0DmI5x52qI/7/Zt/kHV/JV5pevfsUiP9iaX/ozjFnI9t5YMPhwHvp+v/Knzc9r/efLd/rgPN/oF4unvFdULS73P/BwQdFkX45brDXLCgeExB/+t+Z9Pf0+unf8an0xd/8f9E995776rzwu6Bz66I9N2v+edh4XUqGO3nQfkazH9mxFLCSJr6aelulzDqFTGS5PzGZp50HeweIk5/xlDtUKndxEhadqxJ+U35Urir+oB9tNFGG220oLW6th0Lxp0qmnJ6dQ4nzj6eFMPSwk76gfwH6vG2ur71QbS742R/PiJcGLu19cOFLxPG/di4vuF8f+pHP5W+69tfTc973hPLsedd7/qP9Ae/6JX0gV/5wOMIPl//QnecbHONW9tKNwKf782ubxIOvd6VKGURUT9sthumXYEVb4ZpJ4ykLVBupFBqC9jputYIL8+ZS60wZ78j3Yc/gxV3xcn3DyFv2vu7Aaa9El7eftjabOfqW5/Dy3v6/77776ev/Tt/l178opesKjTs5qG3vOXN9Kf+zJ+ij3zkI+tg2qjgtM6W0uzvapq7iXcs9zZcuOrdMcRIao131WDbg5E02mijjdZxQrev8h81MzksKyZgxlQ4HJSQMriXkUQRI4mOxEjKft7yDBJGEuIj2OftkGPAmI3UxEiinJFEl8tIIsBIooSRdCxmTJzvPj9xOK7ne407g+JYhpfhzXzgVz5IX/0n/iy9732/9ISZW3bb+lV//E9fFJGUoqjKSOLjMZI6mGJNjCSu5DkaL5yMF1Bn9vkZ5HtzESphJJHNVW6cmxsZSZQe7JRjR4CRpAWpGpKCGElLznGl5zNGEmAudcwRSDnXxlHjCiuJNNMoYSVlEKUqIynl/lHASGLA68NaYg+FYcdIopSRRMFZlJsYScupWTKN8rOyZSXhSwYWjCqusJKSX6sxkjjudzoSI8n2/1d8+VfSCz/lU1erVX7p/e+nb/3fv5UefvhhM1emE0Y8XBEjiXsZSaRn/BojqbKZ9gyCrp0yRlLGSrLnlBbOJGIk0Ub+3igkjTbaaKNd8YZcsdC/i2XaqeOVjFPUayEQp2Q8jumpUFGv5bCGXr7OccrCOSDx6uOYqPrje35AOezk/Lr8mz8jXtU/GWeOV1yc6cP6s+TizavfD/2odlbGEfHUppt9du+YPlN9afp6iecjzgcQuerIY25yYskVqqzdJ5GfSZ4iPldXvlMl30s9310cAvlewnzXfbT0/Xve8zP0qq/+U/Srv/qrj/t5ZbeNX/FVf5Le/Z6f8eMF5Pmc7yLPC/lxU1S+k8t3R43wCQ3GTZzvtfGC8rzIV5TvFOd7Aa45Mt8JjJuY+9KTo5ELIQFeHZjb5XxbfLdTNDeXQv7/yMezQ0Ycx1KKy5sy55qc+eFuLUvd5KuYt+f+kvFCRlI2NyxzLJwjCJ/DCJwLyc3L5msFnMvMgVn6C0VHmyHGlBqTBYxxP9bx2FwGj+ovM9ZLZaz7/sf9vvS//yc/oxO3IL9OsE3F9XuR1xCu/+VoiuZCcrkYdUg8x4Jtr15LoClz/7fPe9l/Q5//e38f3XXXOpLM6dkpvfb7Xktv+bG3qDlSHjN0TEvTHCnmSnFNEDGSKOCE6nnNX7uaxDZjBV1pFXgucfwj8U/+Zuu5pAQ8NB+vdu10tRd3jaVto4022miVNi1tO9bStR5GUj1OjZFUi2OjQhRSoAXPf7C+ci5fuvbYLOVpWrMT7F/fErjNS99M3MtcurZiZdEqJljWYWvy/QUveD69+pv/Pj31qR/1uJxbPvjBX6VXfvlX09ve9o5Lzfemv/SFX7d07QhLPVW+b1jq2bkGy1w8R4ykvqVqIZw7/3i4FGv9UjW99mjz0je7fzMb6RhL4PDKvc61fjmcu9rvjUu5Wvo7WYq1bumb7+j+lUeV/ctX7nXvQX3pYd9ax76lhy1LpSpL38Bat/vuu59e/S3fSr/9Ez5h3VmYmd785n9Lr/qqV3X0f1m39A3AtCUjycLeu+O1rAVMV7ShpW+dS+BCRtLK6oldAnd4HUvbRhtttNFGC649coUGVZ9SmCciBSgq0qevlCuIjDIjfNqtHqOap65IkVTip66UPsUloGwKniJSo6IJPD0sQIlUep8e6iPjn0IahcbO/erCyUn9TLl4b+dQZRUau/cuHLOMoknHWY79Ekc+VaN9nHvucU/Tdu/tnah0Du7e2/2zyozde5PzmWy79/ZOXVolsPvdKY7M9ymOTfeL7ZniiHyf45h8v4hzco9TG+zeu0fFKQf3t5OLPrL5vntvjlOI3vb2n6Q/8mVfSe973/sfd/PJL77vffQlr/yKi22c8vue3fHaHRej4Ds5HBerUrjnIq9OQH5OcfQQPTkcF/sc+MTGQfkp45zEcfbHXU8Wu9+9IcbLlO+7926ciPFy+OONk5ODU5p+jH3xuzfuWfJzinPjngvHNZufu/cu8sQkqIwj2/S79on7Lo6MX1OLqqfoUEWH1KKx/KwAZRIhZRIW8bm5ugCFklckhR5lWCED1IoFqBXT6BVFWCBYQRIsdy4jpBh18fA5zfc7YYUMVCShc1uiTII6k0g1iBRJBSiSAhUioc7sUyQ1KZNkPNAtTYqkgn23nNIpuabA1xZUVyY5lbP+IlKE/Yk//ifot338x68+P+yWtH3bt/9DoCCyfQplvNCRzfZTAQour7j07sROSaRy2OR4qzKpEJXg/7QiyfY/VnMjVXeJVK5uGiruHKP+0VAmjULSaKONNlrvEyLxpIgUP2Mlg8axYwDzJXKxgY5shnDRw0hK+BvHYSQlzBfIkwgYSUwxc2kD8yVnJHHOSOLLZSQxYCRl6/vVOn+1rp+3M5LCfK+PnDTfuZLvRIkDYc6beec7f4r+yJd9Ff3Uv//px81c8lM/9R/oj3zpq+gnf/LfNTHBYkYSHY+RlLGNUN/WxovNc3K7OH97GyNpyVfeyLHgjJFU43kFzA9qZSQlQCx2czRVGUnmpKXyAzGSmDHzJ5gcVO6xYPVwEyOJo0kLMHrYo3MQIwnkoOshThFIFH2A06OqNyNjI2FGEqU8tOAkoca85AxxykgKIDNmnyNGEhFh58dgDwJEF+h/yVyK2EgJI4kbGUmbryXqjKTd//6sz/ps+t0v/Vy6fv36qvPDzqXt+x/4fnrzj/4o4MhRhZGUD1dGjCTqZSQZklGNkUTRvIbisb924pyRhNhIC8ePK1kUXDuBayjuvIa6Eg/YRxeMNtpoo+Wt1bVNn5WOvTRo7dK1zqVB1TVtOHr+82td18DVUDFrZLribF0K17ilXUt6mtMJrARcmViiUHTspZqP53y/99776O/87a+hz33pZz2m88kb/69/SX/6z/4FevjCgadys34b8v1YboXHX7pGwlS7HGHcyDzXcfQ46HELQ5fVYKnaUZa+rV65dYSlb3oC0q5GR1iq1rxUqm2Hm1zaLnup2hbXt2yp2mbXN7Bd3SuYNixVW7EH9ZVzbS5k9V9rWwuYbf3Ope0bvu6b6AWf/ILV54i3vf1t9FV//CvpkY883JqB2XA19vTHWfp2fJe2xqVq1XgrqyFTP3W6tNl21Za2XafRRhtttNHS9tSnfsxfcTciT1BmDCoBVb/WVGjaWhi6onbnx2bGdNud1wpMNbXR4znf9QfOz8/o+1/3hgvw6Yte9CmPyVzyDd/4D+gv/KW/SufnN1eMG1RRXMtGqiR0Opy2FoaOVVBdyRSz88+q+46tjKRK4Wlloai58FS/U1T9s5WRpAtQzff9ceFpNUKnXniqon5aCjNbCnVrClkNzB5azUhqKIhVj2d7oQiPJ3SAtxT++goh1cKTeP2jr/xy+tzf/bLVaqQPfehB+uZv+Ub69z/1Ux2FoqVgtJZCRpfMSNpSWMdxGjaoiZG04omBm96W/vrAB3/pr16l+6O7aLTRRhtttOo1HlHi1gNvwL3CowBGkopTzI2zU3iU5RVRJqbvH165cHCbdfjGIV5hsxnqzs19fHm139A/T4WXUz+8jzusq5evqr8OFzDq1Z3NabkcmOPg/py2w3TT/AX3fMzGKSaO+xndQe7G2cYpJo7rz+IVFVKZYQ6cW7NvErRVgVR3dPP5iQpOrfkeK5ogJaQj33Hifu3f+wZ6+zveSX/pL/wv9MxnPuO2zCHvfe8v0F/7mr9JP/gvfyiycqzmu89zOw/J/JziwIQ28XC+u/wM5qGwnFN0nvrDD8aLUSKpyDZOwgRx+Y4KqyHHjs2NFL7RsfnobM4Khlb7G5FpHi55AWSKZ+ZhOx/ODL3kRhzCtAt2aCPUu+YGE3cT4h8B1zX0TVgYCvdW5Kvc8aQMpU9kwEQTHnBQriN8EyrGMapwwfvoUtLCTokkMWZ7wu1yjKqYLr3fbME/SrZnfi21wk5J6kAyXjCsSwn2E+dlqRXmSkGn7bAQWsLCx7I9n/T8T6KXv/z30N13373qPHHr1i364X/9Q/TGN77eDEFQmpnnaQKfJcdIcgWnoH+sMxtmJBmINig4FTeuCsXT1XT+zkt2ap4E8yUsOAWGnQX9AUG0o0J/wFW6am0wkkYbbbTRGhtkxvAaRpJlxQTMmAqHgxJSBvcykihiJNGRGEnZz1ueQZ0ZQ5AOkLGRGLORmhhJlDOS6HIZSQQYSZQwko7FjInz3ecnDsf1fK9xZ1Acy/DiSr6TT+Af/Jdvope9/PfTd/yjf3Lp88a3f8c/oc/9b7+AfuAHfwizwEy+yzHBVUYSH4+R1MEUW/gThIgZMWuJKkyxVYwkrud7s1opYSSRzVVunJsbGUmUHuyUY0eAkaQRNhqSghhJS85xpeczRhJgLnXMETPbSDJ6mjhqXGElkWYaJaykDKJUZSSl3D8KGEkMeH2YCOehMOwYSZQykig4i3ITI2mZqiTTKD8rW1YSvmRgwajiCisp+bUaI4njfqcjMJL+8Bd+ET3jN65/OPHz730vfdu3fxs4RXDISqK1PDnJSOJeRhLpGb/GSKpspj2DoGunjJGUsZLsOaWFM4kYSbSRv3entqFIGm200UZrbK0uDXVmDFZ8FCfwqTFjKu46NcWGebJT2MbBioDlawUrk+afryiKZsGIUVrAs7uJIwQ5y6ciZZKJ06vYAIqivZMY09nZmVJYXDizMdHZ+ZlSbOxcq3bH8fzsXCmKJue0izhCdn3x/hxnWdKzc5Ta5dUSZ99gnFLU+7Lt3r+Ic36u8lTHKZU4+36Y90vGmfrh4vM4Tikozplauob6c+6faXuEZEYeFyk4uOh/GacQnf7aKf2Nv/X36HWv/wH6si/9Inrp5/zXR50vdoWjV3/rt9M73vHOeTun/NznAz4uuw09Oz9X+Yn6X8Y5P+yvzoddP5wrJZ7szwvFwSHP1fbA/jxXSjydn5OiaB9n2k45Xk4OcU5Nnk+f370vD9hFnu/inJ6peXDv5EZ0eqrzXL4/j1+mCzc3PuShXAqnP788gd45sy2fX+Zk9buhwo7gUrVo6dv0ZD2YPdX8LZVI4Myk40FhDmAkhQqkEu1WHyPJ9I8+XRptD1jy5hUxVpHo+ylb+uYUSEoxAehRxl2KC8U+dm4zsCIGKpCgwtkofpACzCnBChVwfl1UM9ykAJv6fel/nHPFSk7cfpZEiVT8+RgowFT/Z8QaeZ0BxxM57S8L1zZ0hJRCCie4evtlL/s8esmLP221MmV3Lt4pkd7zM/8RrCTzeVlKZf+oj5FU3LgN9VmpYjNUWBMaT/ESMy/wLOESOBjHKobMdhUssQLx2u4HRiFptNFGG220tPXAiRf3H/mkwy/lqSE+7NPh5UlYKzMmfq5pH8XhJSrTH/QHuExPnyowbvtkVnfofKXD06srH8les49XPYSF1fahchSbeGS+oNkxPl7s/IIdVcRxlE/pCkNF07yoRyk0wJMy4Dgin5BN+Rk9Nctd12QcgmqMahzWT/6mfIcOLOD7Oj+X78i8ZNWfBJVNbI6L/MP0t7e/4yfpj33ln6QXfsoL6A/+j/89fcErXr5pnvie1/6f9I//2Wvox3/sJ+bCzfy0dspzuz3hE3WzH3JkJP3p4oghp/LL5KecCJixIlCOP3aDwDw9Lqwd3lgzkvzxsfNe/DRaLllz4yXIT+jUE6jvKFA9UcpIOhwP+QqVpXpi8TcuZqae4wUrP6Y4XPR0jY4LEgWYG3y3f7zM57CfXJcmhSIzD+P+JjMvRUvDDnHMDnvTuoIn9Lk4rbdHLev2H/d3nvZrh/FSONABzfEQZXz55LxdJp53Plyw9GitYTmcby5eYf/bfp/OQ0HpUsYDbComs122A82AcP1vTscsrxPQADA7UCPfqHjqMiLYLjeedH/vXr/gFb+fnvKUJ68+b/z0u95F3/Yd34ZEnC7BYji92a7pYVY4D3JDoWjpp+Xw5apMxEiSR2RJBz1fuqeD4iEdH+Y3NBE6lVHhCjLMzLf23EIVJStaAjcX6q7YA/ZxazjaaKONlrdW17ZjuWA5uLBk0HTAtPMyTy9lew2Uu931DcdDNMlmlnUfTLsb7l3fgEuBaVMxLlY9hVDkXnWswuoaKHdHvvd8fxM0vtCTn/zr6GWf+zn0u37Xp9OLP/VT6GlPe2q6F7/yKx+kH/2xt9Kb3vRvLhzZPvShDx0v33u+/0SDz5uP5a6E/TDtNfPxPL7QE/eui2vP1uhgNVfidZu+OUlUuF3NOxgzktpvPzh0J9sK427shgpVu8I0anYR2+Le5u5cqy5i/f0estEb4dkN0OsqK7sTxh1+PSrM9W594poHvviFf+AL6au/+n+me++9d9W59JFHHqGv//qvo3/8z74r6P/VNH83XHtc7lrmoxaXu3oWbTMbQHG6XNcSeHave9tVc20bhaTRRhtttMZC0lIf2ebettw/JUvgHgNXq/4b8Y2FosYb6NtxI930C4+J3fnqusyR3du25HsNqr2x8LSqMNqe7//vO95MN05O4Bb92ukp/fbnv7jz5/M8by7DdLi3bXZxg2835jvK8xCqvaYwigpPl3G5zKbQ1Gwi1V8YWuXS1lEYOrpLGyp4HKswBAo6zS5tuFDR2b1VW75+s77cDetSCkNbXN/QZh/TpS1za+t0aYsXbnG139cUmu67/3569bd8K/32T/iE1bPLm9/yZvqKr/ij1Q2K+3/9iCUKINwrCk2hu1qlEFfv/8aCToMC6RhubZkC6aoVksbSttFGG220jnMINbi3xa5r/maCkDvWzA5qYyStdrVCjCRlBoYZSY5tFDKShHsbdF0zcQL3tiVeIyOJAlcr6+Im43QyklLXtZp7W+i6ZvLCuOFVb5wDF5Ho4qvqMhgxwUpvgai05Ttty/dLY4JlS1iZnUtW5Fbo2GKVi3Sb765QVAImmNmfGhPMjxvcn96t0OZ5SfIcua5F4yYrrBa1vIMyFzc3bmSeGx9LNQ6iAoXNYwLjLliqdimMJOvShtzaUCFsq0tbjZGE3Z5iRlK0VKckbm3IpY1jz7UuRhLsXuCGhhhJko1UUSJBRo8uNUaVIOQe189Isof3wEbK3OgEm6rJpS2scwDXt4BtQ6lL21JwamEkIbe2qGKzzL+5S96XfPGX0G993vNWX1c++OCD9H3f+9rZgS0shIUubX7EIpe2KiPJzgMVRlKkQAoZSVWXtkZGUqUwX3Npq7q11RRNV9ylbRSSRhtttNE6G7wRqT74xsyYsomRpGEN6xlJ4psWgcRAVwQYSWTjuDKaRaRsZSTRbWIkmV0HjCQdJ1A0uTX3dmk/9ymaEDvEHJeq3XlYCNHFkr4la4a98rjKd/bskDyds4GQ9ABLFJAZN3qD3fasyXc1biynCy1IJWFrAwYIensu5Jjx0pLnanO5Md8JBCDPcBJMlqalb8CtaNnp5Yl7xvqq3bi0MJJCx6ItjCR532WZS4KVBMep3b2aQskxevoYSboApRk7lLGRQkYSO0bSHE+yXAj3d8ZIShBUASPJs3/m/kq80vTuYUbSXDRlVsfTx7Hziq188MJKAvsZMZfiJYO2//Xmu/1zHRgzkpAQCTOSAHOpwkhiUYRPGUk2nkH4THF+87OeTZ/1WZ9Fd99998prS6afeNtb6XUPvE6xpJiKGU91RtKsKJJxGhlJvi7XxkiiDkaSnN8gGyllJE1/xoqikGnUxEhadswyKGuMpBaF0igkjTbaaKNd8WafeEdKpKrCI1BmRIoZr/AouVtbTZFhH6k4BZLdLUYfFw92sQKgpswgcTGXKTSqrm9WOVQCRQUZRYV7kB0pkEwcocxQ7mPiC9oVy7iGHdyvpKJJxRH9KV2x5I3zycHdbImz/23otmbczWRenpycXLxC1zDn2mZdw5b83LvI7RxnzlTBCe2Xc38ry63DxX5duMidqXyHcYwrmcx35WImElceF5nvPs7Sn1Oc6vxAU/xDHMJxpIIPubDt8vue3RI66dom+tPFcW56Mj+nOGcqoVU+CAWSdm0L8hPluXTZO+Q5TS5syrVteV8qmmY3tLMzdUN042Q/Xk5Pz9XEol3blvFiXdim+XjvwsZ0dqpdDtHn9+8vLnWSkXRyY7+/p/J4OUWcfBVKoiojqVSfuCNlUl2hFK8Fg0vrViuUIjSKk0ia8yk1uYgtb4d7GyiU8H2fs2GDQhhQiihYCYRty4QyCSiU4FKsknpE6QxKFDLhdhXTX8maOuyah7dnfm1RKCVrCZVLGrogKSVXYJnEKTVGklEm6fHkC6EF1K1f8YovoI979nNWX1s++OBD9MDrH3DXdy2MpBIqlPyVHCw4Bf1jlffIVdBBtIFCqYQKJTRdIYUS+HjxSlg8ztsVSqEyyTCSnEIpUICPQtJoo4022mjh06MavDVyyTKfcoWipWCkpQ35AyTEemHleJUpdOwj7hZmDBvXNv9kVnw2VO7YeIsiCXTo/JrpD5TSSkkfnFQkehsrWNTGaqWKdF0rBwVO6oplD6RzoRJKjTmedSFLpBIyzqHwZN2s2vLT5/v03/aJpndXAhsk8j1ytsuVIOzyneT/l0oQ0mZvOgQ798To2aN35KN8PLOOUxYNkI5XTKfZjovc1tCrt/0LXQWntGU0XpQjYvwFP27YKxzDL+ghHbm2xXnOcGpYlEk639183MxNytzbhHtgYn9te5iAEki6EMEH8gVLO9m5ktVc1vw8SkARYBUfVai3jWeFCc2MJHyctaLCutuh+gxD1y0y/TQVl0ugxFXLZKFbaQHnCXS4jGubnTetEtcoPgoguulJ3v6nUbJUGUnBuGKsaPH1Gq0A8/1utYcFzu+FsYtfBE+ySh33a4xd7tz2REqb+dNGIeUTnJ71rGfRZ3/mZ9Ndd921+nrybW9/K73hDQ84hZU/r+oOs4q+GnyII2WmVXA1MpLcdY1V4lmXtWSJL5oni9Nny3hJ+s6HR89vS/5Xlq4FLp1u+4Zb2ygkjTbaaKP1tpAZ406yjcwY+IS2nxkTkhsuixljWS8hI6miKLKspVJSKHAzI8kpk0ycCjOmhZE0K0+KZsacHxQgRSmddkqSc896KVoRJJkxZ3OcopYanZ+fw6VrME45bA/I1TmOWcKm4yx5Or2v4/A+DoE4kxLG5Pu+30g9SdVx9NI1q6iZ++cQRz9x5It+nm+rhILAKp2mfFfbI/J9OV5NM8OFgkg9CT/EmxRNxYyb84OSx16ouziHHZBxSNys77eTZqWKijM9SRdKPJmfC9NIbI/pTxiHSOSnZiSdqe1Z8vxUKLVUns95pQ/YXhHkL/ylgkjm+fS+VFCwjGPYSFaJNP1df375jXlclExRSjH8+lIYSfKznpFUVjOSSrRbjYwkN6ERpYwkzabiUBFjFbhE0Q7jOkQrI8lLlLQAImMkIVZSsNczIwkpnI3iJynMMWISUQsjKWJUFdP/OOeKlZy4/SyJEqn483EzowpenDUxkkhcMWFGFdounOA7NdJveuYzV19PPvTQQ/SGN75hYSNxhZFk8jJmJBUgRGxgJPmJNRitlBbSQ0YSofEUw69DRhJjdZGLEyKaADsyXfrWdj8wCkmjjTbaaKNVnyC12kkzVBR5OHEfM0ZLG9YzkkipluT/LIixAp/MauZL6NrGfCRGEt8mRlKFHWOexTlGUrABy89wHyMJqJbIKiwQI6nR7twpgWRPNbmrHYuRFOXnWkaS3bqS5rtIWK9wqvWhYiRlA0rmeY0txlAxtzbfQSJ63Q90EWQcxx0f8sevi5FUYy5xxZWwhKolQk/2yTwRDxhJfCRGEgdspE2MJLWjno20jpFUUzitYySpQhFQoET9ziEjiRwjSe6w627IRsKMJPVN/HEkqdBfc4qY6PBHChCjzHCMKns+MEpac4MvFSy4/22/tyuSEFvcsZs4YBoBRhKqXGBGUjzQa55cVUaS63/952c969n0GZ/+GavVSLv29ne8jR544Pthf/vxVGckeeVWOyMpLxTFjCTuYCQpplEhP0+mjCSjcOIKI6lw6hLn5lt33mljJA1l0igkjTbaaKM1t5oiqX4j38lIEkokxEpyCiITJ2YkiavZ2JRNuKhYJRIZplEJ4v3/7L0JtG1Hed/51ZPeu4/3JCNAAyAjCSRmBAhkEINAAWPjtg22szx1um1I7MRg7Dh0d1ZnxZ2V5WVI45DudOJeKx27u1cGD7Bih0zLuGNszIxAaBZICJBkMxgQAjTec4W+XmfYu77h/1XV3ufeB/hVOTcHnXfOd/au/VXt2lX/+v0ZrITqwdxkRhJQduXBSUIoKc9IctVdc69C1wesS9dcrFpd30IXK3YKDfnxen4i96polBS7q+F89w/daet8PxgmmM937C5WRNbY8xT5XnU5dEq+Qr6rh9BtXQl1fdSYYC4/A0Uk8t5RX7BubTbfZXsJXQmRy2HBhaelP06FCSK04k5RfvvuSDI/YkaSUYTWCDmWkRT6mRFmJBntijuuFNynUHUVGEm+ghO4/oFCprgVrsxIqrGRsjIGM1ZCehFGKjW7iIXubSlQJoWjhhBGhdlIEFEVKIAgG71NkdSkTJLxKowkgu1J95uBKeFWjKSiMskwkr775d9N5513/uyx5N13f53e/afvNvWfCCGHwqkZw0iiRkYSpKNDJFWJkWQUQA2MpKoyKRUUQIiNJNovYiON8aqMpDI8u9W97WRVJh3qj4a99NJLL22FxQPK8DpwbGYxaNRq7Hplj8UrccHFBqqNNPMF4lPkn/lA/r5m0AQf3zBexOt4wJ4ZQyIOA9aLVhsxXJq23Bofz/wmYsiIP/s2JpoEXyB1qoJpZFhJqhapykhax9OMJMVKKq2UuXg8xss5No2R1J7v9ZZTzHeu5DtRwYFQcqXm5DuV872lZ2jJdwb5Lv9QvqP24hzdRH6KNonabLG9BHlOAYqJCZ0zY1YSxc6Dmi2m87TGSCLD/WCm2f2xz1GZ87o9UYVfF2XD8H/EIGc5vthcyVl7FYEkR+WHPoZNHGb480HnoC4ib3J4rH8ZD6q7OOq0HDMrX1cq9BH4ruBqCOWx6sfxB7h4VfVh+HuZb+sM7mnR5Q9uEqrNs3hl3xW4XrPWuHX9oy7K8sjwGSBEF65/Ec9eaHDXc30j6Ft1H7tfYwmmY8eP0cte9oqVQcTc8slbb6Xf//1/Z/pIhn0kR/xFpmLGRM1Vt03Q59bkmKjHV/Wu+5jI2U3Xv4zHfuwk46H0ZdBPsoxXyqJg7ATGUDxxDHUylK5I6qWXXnppLHalJnJva90alCrKD72iHTOSwhXkOYwkpNSoKSxCRpJQJkHXNRMnUCbleI2MpNmKjXZG0soVi3jjJpavp3Rby0oLMm5iMo50STNxBjaL2GqkXdLy+Wg3tJynyB2MBhcwZsdKwq5tCcanjTsYD0whke/S1UvmJzrf7G6m2UQqzlCfmy9oN7d8ffN12VP5vqp/c12Sc4WT9Zmvb0vPoF3hsLufVCAolzRzXcbjEfmu6zO3G5VXycZZ14NkgqH6XNYSjGPqUyr6cJ6n0Z1tYfJ8ZxNnV+Z5Mi5vYkV+lefLOLsLpcAbXNXWrm0ijnJhy9sVlm5rA/vLuhZKVtLw/trlTbc7Mi5viQKlXsBIIgqELlszkqxLG3Jrk5/dL5e2GiMJKxliRlK0VScV3NqQSxvHnmuTGEmweoEbGmIkNSiRHCMJ9ympQMtGyqjpjCR7eQdGT8GNTiqbWlza8OXGrm8B24aKLm1eAVZiJEElEgqolKH6+H/w+19Fj7/ggtnjyN3FLr3/A+9TkpwmRlLo0uZbLHJpqzKSbD9QYSQBSFeZkVR1aWtkJIWtpU2BVHVrK8G4qbu09YmkXnrppZeJBW4JStUlW72oM5kZY1dqaEtmjFVxJKVaSqHJEmYkkY3jptGsy9O2jCQ6QYwkc+qAkYRWk8f6MC5pas89a5cxL5gS9Jgojlkp0y5y+d+GPItWz0qKDRUnUVZjNMXR+U4GPg9XF0PmilcQSXYXs2fn6DiSFUFKXZCrLXJ/0wqpckvXqg7ZbvxquT8e1WOgFXWpArDthrRKxsbRyh7smIdWcoeJS6SQ0soFs9osa9XYvCkXOefaBtqLfbXOblxoL9U8N3UffS5w8ZnKSApN6LZhJMnnLstcEqwkd12KjCS89cUzeqYxkvQElHedCsUQISOJHSNJuohZc6eITYUYSQUEVcBI8uyfsb4oYCS508OMpHEbtei3cBzrNmr3vgm3L3CeEXMp3kRp618fvjs/V4ExIwnB6TEjCTCXKowk6yoYMpJsPNGdLdlIx44dmz2e/MLnPk9/9K7/OrL1CLgUWne6FkbSMGGEXPdqjCQ/L9fGSKIJjCTZv0E2UpGRRNoNjiqMpLBfAxNPyi2vQflN5a1wfSKpl1566aUXfc+I9kIXmTGeyTGZGeMUTQfDjPFsJPKjAsRIckwfu5Cu2UTuAXwOIwksDcVubQxcWIDJD7cxY8YVwaVCY0+4OIkv7Am3NTlPOChtLCNJxRH16eJsJjJ9nPX/hG5rqzh743syLwclki3YtY1UHJmfgxuaZSSpOCLf95TbWn50yMoone8wDtHompdMvq+OZxhoi8TN7m9J5buPs/6HwcWsZVyYhGub8h2UcYyCL1/3pPLdu7+tC4wjXfCMC9J4PCahlYucYIEN7m/F/JTXZchPo3NYgDhr1zaZ58P5plH5Y127Frt7HsadrGtbbi/IVTC7sHmXQ+valt/fE3DozEha1TPr+CVGklIShYwkgorQ8MnFMpKqCqVoYggf13yFUoTugZAeI3iou4gBiBOIjhRK+Lkvgh55bzivUMKMpAQHDQnTkMPnW05VShaWJIXKpIRul7ECiyJGUioeTzLMnvi5u42RFKJ+HCMJKZTmM5I4BS5pgpH0ohe/mJ7+9KfPHks+9NBD9JGrrqQ7br8DMHqsQmkaIyk1MpLGCaegftoYSQai3cBISkE+xgol8HHESiJ8XK0KpVCZZBhJTqHkureTU6HUJ5J66aWXXhpLiytW2/5pP1GUH6BZKYnKC0gGUqzclbhkIpa/zymIU/44RxIoZ1rFDfGyIglU6PiKXeVktWzOQCm92Ll5BW9rBQv6BaPM8j/jK7zovgJdsrRyLXZr4yitAljxlPxsyfcWd6t4YjRf7tj1LYxjlElaCRLkO9fyneP8rNdUNd/Z5DsV8l25toEaJanOKygQy0pDkO+w3RBsN8kq6Cj59VvG7jkyz1174UJ7AV2Dh8cH+U6tPItImSSVPly0v7Y9EgElkHQhggvyCUs72bmS1VzWfD9KQBFgFR/ljVAgnhUmFOzqCxkt6h+5fWkFmJ6fYei6RaaehsnlFChx5TZZ7FaawH0CXS7j2sZWYWaUuEbxkUCvp87L/adRsmCGuV8kco0cK1r8fI1WgPl6t/6MCfbvibGLH1TIAaWO+zXGLnfueCKlzfhpo5DaxLniJVfQGWc8YvYY8qtfvWsD2TbHxVYZY++rusKsoo8qCjLEk5Nv4C1r8USco2BZJZ51WSts8UX9ZHLLCDJeIX3HNNb9W87/yta1QIHqjq+7tfWJpF566aWXqaXmiqUfz0qMJMxGcowkamMkheSGOYwk5NoWurfVGEkVRVHoZoUnJJoZSSlwXbMrqO5BvJ2RhF2tElSO6eF0gooilQfjw07yD+DO9tzXZ3IrZKlhogi4rlXzXU7IBAq6lnyPJjIblXgElWPAZWlivg/tpaFnACwwr8Rz7aaRBRbNgcQuhfp8rBIv59NEphiV873mUujd22ouhajdyPykID+TmWiKJ1ZlrjOzU0Yh17BYUUqxK9qBMJJs/iVf3bMYSSk6rUZGkr1Atr37J0pU714Rg1xK8QnjeYhWRpKXKGkBRImRhFhJwVlbtzZTP8m4hkUTc6GLXJWRFDGq0iTXtqJbW6hESv5+3MyogoOzJkaS7Hkwowod1/rt8887n5536fPo0KH5PlU33nQjvf/97zc/2shIMnkZM5ISECI2MJJ8xxq0VipOpIeMJELtCW9VoxIjibG6yMUJEU2WlVTb+tb2PNAnknrppZdeeimWFkWSnEwi6CyzDSNJSxvmM5IsgwYKZKDig4wiqaRhUsqKrRlJfIIYSUmzYwAjSV6ZZNUTwQHkn9GMJLtuW1J4EVQmydNvz0+Z0wQdleqweJ1J2zLBovycywSzR5eK+S4S1rCSGvqFDeuCfQXYmSyR5zW2GEPF3Nx8B4no9W1QOcSxYktdH/LXz9TnrHyXrc0dn5mYbXB2I9BuqMD64hCRMY2RxAEbaStGkp2lLCmcmhlJNYXTPEaSmigCCpSo3jlkJJFjJMkT9qZ1CffPgJGkvok/jiQV+mtOERNd/kgBYpQZjlFl7wdGSWse8KWCBde/rfd2RRJiizt2EwdMI8BIQjMXmJEUN/R4g1SehC8yklz9E7385d9Nj37sY2aPH++77z563/ve5+5jqL6LSuYQTm+VW+2MpPJEUcxI4gmMJMU0SuT7ySIjySicuMJISsGANpoocvedNkZSVyb1iaReeumll+ZSU2jUH+QnMpKEEgmxkpyiwsSJGUliNBubsgkXFatEIqOoSEE8BiuhejA3mZEElF15cBIpNCJFRcRIChRNCbukJVGf0hVLKjR2Nq5kK9aKUDTpOMaVbHTFyg/OO9IlTYzaWtzWpDJj6Vq1ZsgUXMOEggi5v8k4AysJxqHI/U27pK3Pa6FWxqVbmVQiSVcyme/aHY+K9bn8GoozuOkNcar9wujaxiNzCbnyyTxHrm1rV7WddZy9PfUQekSdV45Tqs91nIXqVtTxkM1PHcflp4wjrouNQ4MLW5Kubfl9uTIs32fBBjm6s24vA7NojCPd0wQLTLu25fxcu7BlVtJQ0OeX5ejOzthO5Yr70v3Nfr7ESJLMj5iRZBRyNUKOZSSFfmaEGUlGu+KOKwX3KXN6/kkWbZ3y30who8fvwSopwoLoVTZSVsZgxkpIL8JIpWYXsdC9LQXKpHDUEMKoMBsJIqoCBRBko7cpkpqUSTJehZFEsD1pBXRgSrgVI6moTEqJXvyiyzfuk/PKl774RfrQlR/CBCuTYHMYSdTISIJ0dIikKjGSjAKogZFUVSalggIoBYrvhK4W63hVRlIZnt3q3nayKpMOUS+99NJLL02Fya/GDM5YJResOJ5xmNqoOBi4RuGFJKvfYL3m7FyjzB9wxcpeSva/CLpQEYvX8YBZqIvYHJ34eeBUNZ4sWJq2Lmk+nvlNb4um/uzbmGgSfIHUqY71J6+hrktwAZHaiLMj25hb0n2ttFLm4mVHr5xj0xhJ7flebznFfOdKvhMVHAil69icfKdyvrf0DC35ziDf5R9hlzSOSDJsE0e3SdRmi+0lyHP4Nje0F8KVyEBdp13XgvZClTicc2lOf+xzVOa8bk9U4ddF2TD8n3bK0/0I7irKOWuvApDkqPzQx5Ad/rhY41Hlb+pb1r+MB9VdHHVazl0wX1cq9BH4ruBqCOSx7sfxB7h4VfVh+HuZb+vI+TO6/MFNQrV5Fq/suwLXa9Yat65/1EUZ58fgDBCiC9e/dbJkdYHtXc/1jVxwvXQVMX0s8dKXvJQuOP+C+WNHZrr62qvpjttvixq4H1uow/eOm8xUzJioueq26ccGVTmmqR0Zj5AzK8fOlQzjsR87WadXm76M3UdZe4MGWRSMncAYiieOoU6G0hVJvfTSSy+Nxa7URO5trVuDUsCOyQKfNkZSuII8h5GklEmYkeTYRiEjiQA7BgxKKsqkHK+RkdTKfJFxJjKSRuWJYQJktzXJjsmuWJaRpF3ScpzBLUsyCFZxVu5m5ODCSlkkVspUHFGyS5pW0GHXNuGKpZYYN25r5FlLo/LH5GeOr1dSVRyR71JBJK+PiiMSbk+4sMl8HxVTJt9H1zOjkMhx2nqGtUsaOUaSckkTK+ujYspcl8VedmGT+T7mlWk32c0tKUbSOs7ADMn57vJzc5YwjspzrehbwDxPo2ubzfPdUamlERy7o9uaXpFfK4I8HDUrlEycXRFHbFcY45g8l3FIbOWQn5eSh8XCuys6JUDASMoJsN+MJOvShtza5Gf3y6WtxkjCSoaYkRRt1UkFtzbk0sax59okRhKsXuCGhhhJDUokx0jCfUoq0LKRMmo6I8le3jS6XYZudFLZ1OLShi83dn0L2DZUdGnzCrASIwkqkVBA1f8SvfjFl9MZZ5wxe+x4991305UfudJcQOvSVmEkhS5tvsUil7YqI8n2AxVGEoB0lRlJVZe2RkZS2FraFEhVt7YSjJu6S1ufSOqll156mVigO1CqLtnqRZ3JzBi7UkNbMmOsiiNpt6nQ3QkzksjGcdNo1h1tW0YSnSBGkjl1wEiK3bkqrBe1tb+RGUMmjlmY1i5y4gEvoNr4S+BX12oQbpjn35L5Dlz4yulcszkLaoCBC2DASApdASfku2o3XvTjGGeiPmADQW8XGUktTKOpjCQCARAjiQN4doqdDJFb0bCMnTBDhCuL/FMZSaHAahtGkoKsGOaSYCXBdmpPD8GQRf14Rs80RpKegPKuU6EYImQksWMkSRcxa+4UsakQI6mAoAoYSZ79M9YXBYwkd3qYkTROmjKr6+nj2H7F7n0Tbl/gPCPmUryJ0ta/Pnx3fq4CY0YSgtNjRhJgLlUYSdZVMGQkiXjHjx+ni5/+zK0g25/7/OdGtzbEMLMuhdadroWRNE6AA9e9GiPJz8u1MZJoAiNJ9m+QjVRkJJF2g6MKIyns18DEk3LLa1B+U3krXJ9I6qWXXnrpRd8zor3QyT+UlxhJaSojCblgldzaagoku6TiFEj2tBh9XCzsOps5s5CO3atIDOYmM5LA0lDs1ha4TrmF7EiBZOKkBtaSUSJNcn0LXKywWxtyfTMKN5rK8AriNCjuoOtbY743u75NznecuDUWmP1atX+Qrm2ypbmf387l0Oe57YdmuhImnO/elZAqroQWYRa5tQ3/DNqLcWtDisjYlbCQ79DlMIVPCCVXIp/f6DCEkihkJBFUhIZPLpaRVFUoRRND+LjmK5QidA+E9BjBQ91FDECcQHSkUMLPfRH0yHvDeYUSZiQlOGhImIYcPt9yqlKysCQpVCYldLuMFVgUMZJS8XiSYfbEz91tjKQQ9eMYSUihNJ+RxAm7pL3iZd9Nj3vcd84ePz700EN07bXX0P333Rt7mUGF0jRGUmpkJGXFJa6fNkaSgWg3MJJSkI+xQgl8HLGSCB9Xq0IpVCYZRpJTKLnu7eRUKPWJpF566aWXxtLyIN62f7rwIG6kDeUFJGSbbhhJBYWOXeIue7Ah5ULZdSlW7th4WZEEKnR8LekPlNJKPUA7qUj0NlawqIO1CiD7M77Ci+4r0CXL2J2Hbm0cpVXR7nwqIynO9xZ3q3hiNF/uWNEUxlFXx7isRfnOtXznMD/v+spddFdxyoSr+c4m36mQ78q1DdQoSbVSQZFVF1iZfIfthmC7GfPdtBcOv4Dz3LUXLrQX0DU4pWiU763yMgrYSkrp0zLRFFOoyLgQwQX5hKWd7FzJai5rvh8loAiwio/yRigQzwoTCnb1hYwW9Y/cvrQCTM/PMHTdIlNPwyRuCpS4cpssditN4D6BLpdxbWOrMDNKXKP4SKDXU+fl/tMoWTDD3C8SuUaOFS1+vkYrwHy9W+1hgv17YuziBxVyQKnjfo2xy507nkhpIxYXhuN59nOeS8eOHZ89brz77nvoqqs+ChVqkS1g6DYplWVC0UcVBRlHykyr4ApdBKNWa+KM9W5c1gpbfFE/mdwygoxXSN8xjXX/lvO/snWN8TjJHV93a+sTSb300ksvU0vNtU0/npUYSVjx4RhJ1MZICskNcxhJSKkRurdtp7BwrKWUIhNvobBoYCSlwHVtrmIDKIpWrlgbNpFUWEjXNqnYGFzbstuad/WSjCTs2rZ2m1q5pEnXNue2lvMVua0Nn1+7re2pPG1xf5M1fkS6yMk4wtWLAte2lFCchdq6hupzrJ/RZSznu7wuUnCwqn8ZZ5Pv2l0Ou8hd/le+b4yjflcoJUbXttFtbZ1n2rWNiq5t43WUcYDbGomHdeVSl0ycjfuYVOJhV0FzPLA+95QST+dnZiTtqPOVrm3rOLsmz5XLm7hgqzxfxtldqH5Qu7blPNcubPlh7OjRzXVfucLl62td24YHgrXLm3Y5JOPyFivsKHZFOxBGkvysZySl2YykFJ1WIyPJxKsykuSWN1KujVoRg1xK8QnjeYhWRpKXKGkBRImRhFhJwVlbtzZTP8m4hkUTc6GLXJWRFDGq0iTXtqJbW6hESv5+3MyogoOzJkYSiRETZlTp4zp2/DR65jMu3mqi4PNf+By9/4MfKBx9IyPJ5GXMSEpAiNjASHLttsxIiibSQ4U1ofaEt6pRiZHEWF3k4oSIJqDYLm59a3se6BNJvfTSSy+9FEvr1iAKFRZ+K880ZoyWNsxnJBk1BwVIF/UP7NEEXNYwKWXF1owkPkGMpAo7hmLnF+yoIq4je9aLNmwRK6bKxQqslEF+Ers8jRRIZdc1GYeMi2BjHNareEO+QwcW8H2dnyyYS2QcmExeBnG0I5C8btr1bVR+WNdEdzzsGGDsGDzAUWjIc3s8FLkOmfOQLaNQny6OaHIqv0x+yo6AGbvIyfbHrhGwjiekf+z6GQbXx/Z7Jp7J92HA79pLkJ+QxxQ4FBJYwedxBX8aI4kDNtJWjCR1op6NNI+RVFM4zWMkqYkioEDx9U2mX4q2hmVGkjxhb1qXcIcOGEnqm/jjSFKhv+YUMdHljxQgRpnhGFWmnqyS1jzgSwULrn9b7+2KJMQWd+wmDphGgJGEZi4wI8l1bFVGkpyELzKSNsfxipe9nB796EdvNWb8xCc+Tvfde0/Epob1XVQyh3B6q9xqZySVJ4piRhJPYCQpptF4XQErCeWbVThxhZGUggFtNFHkFH5tjKSuTOoTSb300ksvzaWmSKpPNE1kJAklEmIlOQWRZc+k2la1VDJlc+wYx0hKmOlDkJEEJprmMJKAsisPTgLmCzWwjaDrG4XXZ3BD0yZm2rUtKz7IKZGGFV0dJ/9gjpMUTHuIo5gviUK3tb2NC5he8c9KJFtwHNq4mOmcR4omGEfk+xjHQFyya5teGZfub1J5txDubDLfV+5slAfswzezskszHFCctfvbwn589al8vZJSIKxd2+yKqHVty3k+HKda9d0okQgo+JRSS6yoS9c5nZ974x4y2a2o4yGbn1TOTxFnIVzkZJwFiLN2bfPtZXTxc0qIwW3NKyIHBREZFtjoKmjyc7HYg/2xjKPyf3cPbl1bgPwvMZIk8yNmJBlFaI2QYxlJoZ8ZYUaSySB3XCm4T5nT80+yaOuU/2YKGT1+DxbeWVNmJNXYSFkZgxkrIb0II5WaXcRC97YUKJPCUUM8EwHZSBBRFSiAIBu9TZHUpEyS8SqMJILtSSugA1PCrRhJSJl0yZbb2u677166+uqP6fqC7Ukn2BxGEjUykiAdHSKpSowkowBqYCRVlUmpoABCbCTRfhEbaYxXZSSV4dmt7m0nqzLpEPXSSy+99NK2ukR+NYY3q+DRinY5nvxsVlgwUkTAhSSrL2K95uwUEeYPKD6yTsD+F0GFBbF4HQ+YhYKBzdGJnwcqjPFkwdK0FT/4eOY3veRH/dm3MdEk+AKpUx3rT15DXZfgAjqFhVDVjHFyjlVXyoBiY4iXc2waI6k93+stp5jvXMl3ooIDoVR8zcl3OjH5ziDf5R9hBRBHJBlr4cf6GNE5FNtLkOfwbTaKIiJTe5U8J99ucn5y1V2IAu4Hq3yf1h/7HJU5r9sTVfh1UTYM/6dUbyaVcFdRzll7FYEkR+WHPoaspuNijUeVv6lvWf8yHuSocdRpOWVnvq5U6CPwXcHVEMpj1Y/jD3DxqurD8Pcy39YZ3NOiyx/cJFSbZ/HKvitwvWatcev6R12UVd3iM0CILlz/VqXJ6gLbu57rGzlSdDKoiLaxxLHjx+kpT37qVhMEd37lK3TNddeAMQUaCzDsI92YwtV/vcX6dBRt1Pa5ZfAh7vFVvRuVLMfOlQzjsR87MValEhiD2deo9RbdQuV9Q9xTeOIY6mQoXZHUSy+99NJY7EpN5N4Wu67hFRHnjjUKfNoYSbNdrRAjSSmTMCPJsY1CRpJQJkHXNRMnUCbleI2MJApcrayLm1NstDOSiq5rNfe20HXN5IVxw/MMEewS5lbKglW+qstgpMAzSq9mJlgt32m7fP+mMcEa3QpdnMoDSqzEi9qN7V/amGCxEq/mVmjzPBXyHLmuRe2mAJ8XFeHiJHxdWqDcuh1EQhKbxwTaXbBV7UAYSdalDbm1yc/ul0tbjZGElQwxIynaqpMKbm3IpY1jz7VJjCRYvcANDTGSGpRIjpGERxupQMtGyqjpjCR7eQdGT8GNTiqbWlza8OXGrm8B24aKLm1eAVZiJEElEgqYEr3ohS+ixzzmsVuNGT/96U/THbff7u/C0KWtwkgKXdp8i0UubVVGku0HKoykaK9eyEiqurQ1MpLC1tKmQKq6tZVg3NRd2vpEUi+99NLLxAIfRFJ1yXb87vCf9gY1nZGkYQ3zGUnim4F7jToP5L5k47hpNHIMmULFNjCS6AQxksypA0ZS7M6F3evgzwxsCfTgjRIiUHNoF7mK3XkwmURmdU1PME1VG30r5Ttw4Sunc9AQsJsfznPbbvQBx66AE/JdtRvL6QKMM1EfsIGgt8eJHAaudpU8V4fLjflOIAB5hpNgsjCXfByjdiMTNG/tKLG+ag8uLYykSICzFSNJQVYMc0mwkmA7taeHYMiifjyjZxojSU9AedepUAwRMpLYMZKki5g1d4rYVIiRVEBQBYwkz/4Z64sCRpI7PcxIGidNBZMNx7H9it37Jty+wHlGzKV4E6Wtf3347vxcBcaMJASnx4wkwFyqMJKsq2DISGKmi5/xTDp+fP62tuV27VtuuVm58Y4/x/bnjFuecadrYSQNE0bIda/GSPLzcm2MJJrASJL9G2QjFRlJpN3gqMJICvs1MPGk3PIalN9U3grXJ5J66aWXXnrR94xoL3TyD+VFhcdURpJTeKSyW1tNkWGXVJwCyZ4Wo4+Lhd15ygwSg7nJjCSwNBS7tfmhDBEw+eFIgWTiJOzGJeNoVyzjGrZxv5KKJu0alutTumLJB+edjZtYjrP+bei2ZtzNZF7u7OxsGDLANcy5tlnXsJyfaxc5WjN/OIgTuLaNeUqb82LOcYb6RHGMK5nMd+ViJhJXXheZ7z5Ork8ZZ8h3dN2zGxqPzCUYJ+E4Mt+P7OwY97dcny6Oc9OT+TnEWaiEVvkgFEjatS3IT5Tnit1E2oVNubbl96WiaXRDWyzUA9HRnXV72d3dUx2Ldm3L7cW6sA398dqFjUf20VDQ59fvZ5c6yUjaObo+313E/jLdqoQUlRlJBBWh4ZOLZSRVFUrRxBA+rvkKpQjdAyE9RvBQdxEDECcQHSmU8HNfBD3y3nBeoYQZSQkOGhKmIYfPt5yqlCwsSQqVSQndLmMFFkWMpFQ8nmSYPfFzdxsjKUT9OEYSUijNZySx4fk8+clPplNPPWX2uPHue+6mm2660bkL1hlJaRYjKTUyksYJp6B+2hhJBqLdwEhKQT7GCiXwccRKInxcrQqlUJlkGElOoRQowPtEUi+99NJLL3jio8G1rW3/tJ8oyhNGWtpQXkAyUG6lHOBQgKC+zymIU/44R5IQ5wLHDfGyIglU6Pha0h8opZWSPjipSPR2qDzRJwQYSePbXHbFshcS4EGScXjzLmQFqYSMkzJbBLGRWhlJMs8le4YCtx94QCLfI2e7shKEXb7HbmuGkaRCsHNPjNYeHccjRYAPUvlpdTaOn5ICFhiZOECdR5CRFJy04YAkRjQNme8woX17Vj/DXuEYfkE36ci1Lc5zzEjKyiSd764/plaeRcm9TbgHFuyvbQ0TUAJJFyK4IJ+w5I2dK1nNZc33owQUAVbxUd4IBeJZYULBrj7uI2T9I7cvrQDT8zMMXbfI1NMwuZwCJa7aJgvdShO4T6DLZVzbbL9plbhG8ZGAa6nu5O1/GiULZpj7RSK/XxYqWvx8jVaA+Xq32sME+/fE2MUPKuSAUsf9GmOXO3c8kdJm8+lnPP3p9LjHnbfVePGur3yFrrzqI/j87MwFW2WMva/qCrOKPqooyDhSZloFV+giGLVaE2esd+OyVtjii/rJ5PTZMl4hfcc01v1bzv/K1rXApdMdX3dr6xNJvfTSSy9TS821TU9HNDBj4ArtdGZMSG74ZjFjxp+vKIosaymlYIOKZLw0MJJS4LrWyIxpYSSNypOkmTHStY2Ela93WxviSBcqGq/nArq2UXZJM5uNYJyNOxjK1ey2pvM0cn9Drljabc3EEW5rMt+ly1hKKI7eumYVNWP9KPe3nO97owubFhxYpdOQ7+p4RL7n66XzXbqYyR/wbmvreNq1LccZXNjsQN3FAW5rJB7WB7e1Qami4tDADMlKPOwqKI7H1CeMQ8K1zTCSFup4pGvbnmcbKbc1U58rRZAf+GvXtpynw/tSQcEyjmEjWSXS8O/68/k3FgvvrugVpRS7oh0II0l+1jOS0mxGUopOq5GR5Do0oiIjiY2rZKSIQS6l+ITxPEQrI8lLlLQAosRIQqyk4KytW5upH6X4KUzMhS5yVUZSxKhKk1zbim5toRIp+ftxM6MKDs6aGEkkRkyYUbX+peW2tkec8Yitxouf+tSn6P5776MyqTDfC6uMJJOXMSMpASFiAyPJd6xBa6XiRHrISCLUnvBWNSoxkhiri1ycENEErkhx61vb80CfSOqll1566aVYWhRJZFZqvLPMNswYLW2Yz0gipVqS/zMhxgpcmdXMF4qYL9aRTVfoBEYSnyBGUoUdY9biHCMpOID8MzyNkRQ5XlmuTJqWnzKnCToq1WHxOpO2ZSRF+TmXkWSPLhXzXSSsVzhBKlKAVOJSg5J5XmOLMVTMzc13kIhe9+PDB4wklO/kr98kRlKNucTg+DCE23YxhFb2yayIB4wk3idGEgdspK0YSepEPRtpHiOppnCax0hSE0VAoRHVO4eMJHKMJHnC3rQu4f4ZMJLUN/HHkaRCf80pYqLLHylAjDLDMars/cAoac0DvlSw4Pq39d6uSEJsccdu4oBpBBhJaOYCM5Lihh5vkMqT8CVG0hMvuoiOHj06e6y4XBi57fbbxn5L1hNEnFmmkWtPdUaSV261M5LKE0UxI4knMJIU0yiR7yeLjCSjcOIKIykFA9poosjdd9oYSV2Z1CeSeumll16aS02RVH+Qn8hIEkokxEpyCiITJ2YkidFsbMomXFSsEokM0ygF8RishOrB3GRGElB25cFJQigpz0hy1V1zr0LXB6xL11ysWl3fQhcrdgoN+fF6fiL3qmiUFLur4Xz3D91p63w/GCaYz3fsLsaAiaLqJ2CCVV0OnZKvkO/qIXRbV0JdHzUmmMvPQBGJvHd8BXnhhXVrY8MG4Up9elfCif1xKkwQoRV3ivLbd0eS+REzkowitEbIsYyk0M+MMCPJaFfccaXgPoWqq8BI8hWcwPUPFDLFrXBlRlKNjZSVMZixEtKLMFKp2UUsdG9LgTIpHDXEMxGQjQQRVYECCLLR2xRJTcokGa/CSCLYnnS/GZgSbsVIkj990UVP3GpS4L777qdbb/2kiCvqC7YnnWBzGEnUyEiCdHSIpCoxkowCqIGRVFUmpYICCLGRRPtFbKQxXpWRVIZnt7q3nazKpEP90bCXXnrppa0w+dWYgWMzi0GjVmN5g2DJr8QFFxuoNtLMF4hPkX/mA/n7mkETfDwzYxQ7hsdXtLucITvGqo0YLk07LI2LZ34TMWTEn30bE02CL5A6VcE0MqwkVYtUZSSt42lGkmIllVbKXDwe4+Ucm8ZIas/3essp5jtX8p2o4EAouVJz8p1OTL4zyHf5h/IdtRfn6CbyUxwjOodiewnynAIUExM6Z8asJIqdBzVbTOdpjZFEhvvBTLP7Y5+jMud1e6IKvy7KhuH/iEHOcnyxuZKz9ioCSY7KD30MmzjM8OeDzkFdRN7k8Fj/Mh5Ud3HUaTlmVr6uVOgj8F3B1RDKY9WP4w9w8arqw/D3Mt/WGdzTossf3CRUm2fxyr4rcL1mrXHr+kddlOWR4TNAiC5c/yKevdDgruf6RtC36j62fSzxtKc/g846++ytxop33XUnve8D74d9LYVjAYZ9JEf8RaZixkTNVbdN0OfW5Jiox1f1rvuYyNlN17+Mx37sJOOh9GXQT7KMV8qiYOwExlA8cQx1MpSuSOqll156aSx2pSZyb2vdGpQqyg+9oh0zksIV5DmMJKTUqCksQkaSUGpA1zUTJ1Am5XiNjKTZio12RtLKFYt44yaWr6d0W8tKCzJuYjKOdEkzcQY2i9hqpF3S8vloN7Scp8gdjAYXMGbHSsKubQnGp407GA9MIZHv0tVL5ic63+xuZthEMs5Qn5svaDe3fH3zddlT+b6qf3NdknOFk/WZr69UDih3MyGL165w2N0vjqOvy3g8It91feZ2o/Iq2TjrepBMMFSfy1qCcUx9SkUfzvM0urMtTJ7vbOLsyjxPxuVNrMiv8nwZZ3ehFHiDq9ratU3EUS5s+bos3dYG9pd1LZSspOH9tcubbndkXN4SBUq9gJFEFAhdtmYkWZc25NYmP7tfLm01RhJWMsSMpGirTiq4tSGXNo491yYxkmD1Ajc0xEhqUCI5RhIebaQCLRspo6YzkuzlHRg9BTc6qWxqcWnDlxu7vgVsGyq6tHkFWImRBJVI5jNPvOiJdMbDz9hqrPiFL3ye7r/vXjWCqLu0VRhJoUubb7HIpa3KSLL9QIWRFO3VCxXWVZe2RkZS2FraFEhVt7YSjJu6S1ufSOqll156mVjglqBUXbLVizqTmTHk1rG2Y8ZYFUdSqqUUmixhRhLZOG4aLWLHwIptYCTRCWIkmVMHjCS0mjzWh3FJU3vuWbuMecGUoMdEccxKmXaRy/825Fm0elZSbKg4ibIaoymOzncy8Hm4uhgyV7yCSBKKmD07R8eRrAhS6oJcbZH7m1RIFeIYVR0bRpJfLfdxVI+BVtSlCsC2G9IqGSodT+CYh1Zyh4lLpJDSygWz2ixr1di8KRc559oG2ot9tc5uXGgv1Tw3dR99LnDxmcpICk3otmEkKciKYS4JVpK7LkVGEt764hk90xhJegLKu06FYoiQkcSOkSRdxKy5U8SmQoykAoIqYCR59s9YXxQwktzpYUbSuI1a9Fs4jnUbtXvfBKsHnGfEXIo3Udr614fvzs9VYMxIQnB6zEgCzKUKI8m6CiJG0oVPuHAzgT6vPPTQQ3T7HXdoF17rHmaQQNal0LrTtTCShgkj5LpXYyT5ebk2RhJNYCTJ/g2ykYqMJNJucFRhJIX9Gph4Um55DcpvKm+F6xNJvfTSSy+96HtGtBe6yIzxTI7JzBinaDoYZoxnI5EfFSBGkmP6YGZMonlKpKrrm1UOObc2P5QhwLYJWS82TspxpHuXjLMn3NbkPOGgtLGMJBVH1KeLs5nI9HHW/xO6ra3i7I3vybwclEi2YNc2UnFkfg5uaJaRpOKIfN9Tbmv50SEro3S+wzhEo2teMvm+Op5hoC0SN7u/JZXvPs76HwYXM7lCzyRd25JKi8FtTfkOyjhGwSfjyHz37m/rAuNIFzzjgjQej0lo5SInWGCD+1sxP+V1GfLT6BwWIM7atU3m+XC+aVT+WNeuxe6eh3En69qW2wtyFcwubN7l0Lq25ff3BBw6M5JW9cw6fomRpJREISOJoCI0fHKxjKSqQimaGMLHNV+hFKF7IKTHCB7qLmIA4gSiI4USfu6LoEfeG84rlDAjKcFBQ8I05PD5llOVkoUlSaEyKaHbZazAooiRlIrHkwyzJ37ubmMkhagfx0hCCqX5jKTh9bzzzqNTTz1l9nhxd3eXbrvtM0axKMcPqD0hhdI0RlJqZCSNE05B/bQxkgxEu4GRlIJ8jBVK4OOIlUT4uFoVSqEyyTCSnELJdW8np0KpTyT10ksvvTSWFlestv3TfqIoP0CzUhKVF5AMpFi5K3HJRCx/n1MQp/xxjiRQzrSKG+JlRRKo0PEVu8rJatmcgVJ6sXPzCt7WyhP0C0aZ5X/GV3jRfQW6ZGnlWuzWxlFaBbDiKfnZku8t7lbxxGi+3LHrWxjHKJO0EiTId67lOx9ovrPJdyrku3JtAzVKUp1XUCCWlYYg32G7IdhuklXQUfLrt4zdc2Seu/bChfYCugYPjw/ynVp5FpEySSp9uGh/bXskAkog6UIEF+QTlnaycyWruaz5fpSAIsAqPsoboUA8K0wo2NUXMlrUP3L70gowPT/jTtj8ilZ6pECJK7fJYrfSBO4T6HIZ1za2CjOjxDWKjwR6PXVe7j+NkgUzzP0ikWvkWNHi52u0AszXu/VnTLB/T4xd/KBCDih13K8xdrlzxxMpbYjo3HPP3WqceP/999PnPv/5fLuAroBm5oKtMsbeV3WFWUUfVRRkiCcn38Bb1uKJOEfBsko867JW2OKL+snklhFkvEL6jmms+7ec/5Wta4EC1R1fd2vrE0m99NJLL1NLzRVLP56VGEmYjeQYSdTGSArJDXMYSci1LXRvqzGSKoqi0M0KT0g0M5JS4LpmV1Ddg3g7Iwm7WiWoHNPD6QQVRSoPxoed5B/Ane25r8/kVshSw0QRcF2r5ruckAkUdC35Hk1kNirxCCrHgMvSxHwf28sUl8Ixz70Sz7WbRhZYNAcSuxTq87FKvJxPE5liVM73mkuhd2+ruRSidiPzk4L8TGaiKZ5YlbnOzE4ZhVzDYkUpxa5oB8JIkp/1jKQ0m5GUotNqZCTZC2Tbu3+iRPXuFTHIpRSfMJ6HaGUkeYmSFkCUGEmIlRSctXVrM/Wj2m9hYi50kasykiJGVZrk2lZ0awuVSMnfj5sZVXBw1sRIkj0PYlQ973nPp4d/x3Z8pK9//Wv00as+6hR3RbVZCyPJ5GXMSEpAiNjASPIda9BaqTiRHjKSCLUnvFWNSowkxuoiFydENFlWUm3rW9vzQJ9I6qWXXnrppVhaFElkVmq8s8w2jCQtbZjPSLIMGiiQgYoPMgqNkoZJKSu2ZiTxCWIkJc2OAYwkeWWSVU8EB5B/RjOS7LptSfFCUJkkT789P2VOE3RUqsPidSZtywSL8nMuE8weXSrmu0hYw0qyR5f0f3HEAkMNSuZ5jS3GUDE3N99BInp9G1QOcazYUteH/PUzFTQr32Vrc8dnJmYbnN0ItBsqsL44RGRMYyRxwEbaipFkZylLCqdmRlJN4TSPkaQmioBCI6p3DhlJ5BhJ8oS9aV3C/TNgJKlv4o8jSYX+mlPERJc/UoAYZYZjVNn7gVHSmgd8qWDB9W/rvV2RhNjijt3EAdMIMJLQzAVmJMUNPd4glSfhESPprLPOpuPHj281TvzSl75E9957j2EjccSmhvVdVDKHcHqr3GpnJJUnimJGEk9gJCmmUSLfTxYZSUbhxBVGUgoGtNFEkbvvtDGSujKpTyT10ksvvTSXmkKj/iA/kZEklEiIleQUFSZOzEgSo9nYlE24qFgl0gSFhlsJ1YO5yYwkoOzKg5NIoREpKiJGUqBoStglLYn6lK5YUqGxs3ElW7FWhKJJxzGuZKMrVn5w3pEuaWLU1uK2JpUZS9eqNUOm4BomFETI/U3GGVhJMA5F7m/aJW19Xgu1Mi7dyqQSSbqSyXzX7nhUrM/l11CcwU2PLZvIusXJOKvj5JG5hFz5ZJ4j17a1q9rOOs7ennoI1ceT45Tqcx1noboVdTxk81PHcfkp44jrYuPQ4MKWpGtbfl+uDMv3WbBBju6s28vALBrjSPc0wQLTrm05P9cubJmVNBT0+WU5urMztlO54r50f7OfLzGSJPMjZiQZhVyNkGMZSaGfGWFGktGuuONKwX3KnJ5/kkVbp/w3U8jo8XuwSoqwIHqVjZSVMZixEtKLMFKp2UUsdG9LgTIpHDXEMxGQjQQRVYECCLLR2xRJTcokGa/CSCLYnrQCOjAl3IqRtPz/zj/v/LHPm1u+8BdfIC+kE/UF25NOsDmMJGpkJEE6OkRSlRhJRgHUwEiqKpNSQQGUAsW3S1/Rr6VWRlIZnt3q3nayKpMO9UfDXnrppZe2wuRXYwZnrJILVhzPOExtVBzsXKMiVpLVS7Bec3auUeYPuGJlLyX7XwRdqIjF63jALNRFbI5O/DxwqhpPFixNW5c0H8/8prdFU3/2bUw0Cb5A6lTH+pPXUNcluIBIbcTZkW3MLem+Vlopc/Gyo1fOsWmMpPZ8r7ecYr5zJd+JCg6E0nVsTr7Ticl3Bvku/wi7pHFEkmGbOPoY0TkU20uQ5/BtbmgvNs/JneL4be26FrQXqsThnEtz+mOfozLndXuiCr8uyobh/7RTnk4l3FWUc9ZeBSDJUfmhjyE7/HGxxqPK39S3rH8ZD6q7OOq0nLtgvq5U6CPwXcHVEMhj3Y/jD3DxqurD8Pcy39aR82d0+YObhGrzLF7ZdwWu16w1bl3/qIsyzo/BGSBEF65/62TJ6gLbu57rG7ngeukqIh5LnHXWWXT48OHZY8SlacQX/uIvdP3DPhKNBQATcTx877jJTMWMiZqrbpt+bFCVY5orIuMRcmbl2LmSYTz2Yyfr9GrTl7H7KGtv0CCLgrETGEPxxDHUyVC6IqmXXnrppbHYlZrIva11a1AK2DFZ4NPGSApXkOcwkpQyCTOSHNsoZCQhdgwYlFSUSTleIyOplfki40xkJI3KE8MEyG5rkh2TXbEsI0m7pOU4g1uWZBCs4qzczcjBhZWySKyUqThmwIsUdNi1TbhiqSXGjdsaedbSqPwx+Znj65VUFUfku1QQyeuj4oiE2xMubDLfR8WUyffR9cwoJHIcrRwYXOHUkvPo2kaOkaRc0mScQTFlrstiL7uwyXwf88q0m6yYSoqRtI4zMENyvrv83JwljKPyXCv6FjDP0+jaZvN8d1RqaQTH7ui2plfk14ogD0fNCiUTZ1fEkddlsecYIctXGYfEVg75eSl5WCy8u6JTAgSMpJwA+81Isi5tyK1Nfna/XNpqjCSsZIgZSdFWnVRwa0MubRx7rk1iJMHqBW5oiJHUoERyjCQ82kgFWjZSRk1nJNnLm5RLZUjkMgqbaKzE1oEtdGkzCimgsJmiACsxkqASSZTHPnY70PbyPvbZz/65chOFjCTo0lZhJIUubb7FIpe2KiPJ9gMVRlK0Vy9kJFVd2hoZSWFraVMgVd3aSjBu6i5tfSKpl1566WVige5Aqbpkqxd1JjNj7EoNbcmMsSqOpFRLsbsTZiSRjeOm0SJ2DKzYBkYSnSBGkjl1wEiK3bkqrBe1tb+RGUMmjlmY1i5y4gEvoNr4S+BX12oQbpjn35L5Dlz4yukcNATs5ofz3LYbw0gKXQEn5LtqN17040lOJJZuQQNBbxcZSS1Mo6mMJAIBECOJA3h2ip0MkVvRsIydMEOEK4v8UxlJocBqG0aSgqwY5pJgJcF2ak8PwZBF/XhGzzRGkp6A8q5ToRgiZCSxYyRJFzFr7hSxqRAjqYCgChhJnv0z1hcFjCR3epiRNE6aMqvr6ePYfsXufROsHnCeEXMp3kRp618fvjs/V4ExIwnB6TEjCTCXKowk6ypoGUmPfOQjthorPvDAA3TXXXep/kqzkrDJoHUptO50LYykcQIcuO7VGEl+Xq6NkUQTGEmyf4NspCIjibQbHFUYSWG/BiaelFteg/Kbylvh+kRSL7300ksv+p4R7YVO/qG8xEhKUxlJyAWr5NZWUyDZJRWnQLKnxejjYmHX2cyZhXTsXkViMDeZkQSWhmK3tsB1yi1kRwokEyc1sJaMEmmS61vgYoXd2pDrm1G40VSGVxCnQXEHXd8a873Z9W1yvuPErbHAPPILK+9SkO9xu9nO5dDnue2HZroSJpzv3pWQKq6EFmEWubUN/wzai3FrQ4rI2JWwkO/Q5TCFTwglVyKf3+gwhJIoZCQRVISGTy6WkVRVKEUTQ/i45iuUInQPhPQYwUPdRQxAnEB0pFDCz30R9Mh7w3mFEmYkJThoSJiGHD7fcqpSsrAkKVQmJXS7jBVYFDGSUvF4kmH2xM/dbYykEPXjGElIoTSfkfS0ZzyDjh8/baux4lKRdPfdX4eMJGpmJKVZjKTUyEjKiktcP22MJAPRbmAkpSAfY4US+DhiJRE+rlaFUqhMMowkp1By3dvJqVDqE0m99NJLL42l5UG8bf904UHcSBvKC0jINt0wkgoKHbvEXfZgQ8qFsutSrNyx8bIiCVTo+FrSHyillXqAdlKR6O1QeaJPiIE9+fC2r/Ci+wp0yTJ256FbG0dpVbQ7n8pIivO9xd0qnhjNlztWNIVxrC5IKUGCfOdavvOB5jubfKdCvivXNlCjJNVKBUVWWWkI8h22G4LtZsx30144/ALOc9deuNBeQNfglKJRvlMrzyJgKymlT8tEU0yhIuNCBBfkE5a8sXMlq7ms+X6UgCLAKj7KG6FAPCtMKNjVFzJa1D9y+9IKMD0/407YTcJKpUcKlLhymyx2K03gPoEul3FtY6swM0pco/hIoNdT5+X+0yhZMMPcLxK5Ro4VLX6+RivAfL1b7WGC/Xti7OIHFXJAqeN+jbHLnTseUO+nn3Y6HTm8HWh76db2sY99DEz0YYVaZAsYuk06F7iwwyg1V6cowlvW4ok4R8GySjzrslbY4ov6yeSWEWS8QvqOaaz7t5z/la1rjMdJ7vi6W1ufSOqll156mVpqrm368azESMKKD8dIojZGUkhumMNIQkqN0L1tO4WFYy2lFJl4C4VFAyMpBa5rcxUbQFG0csXasImkwkK6tknFxuDalt3WvKuXZCRh17a129TKJU26tjm3tZyvyG1t+PzabW1P5WmL+5us8SPSRU7GEa5eFLi2pYTiLNTWNVSfiaxbWc53eV2k4GBV/zLOJt+1u1zgIifyXf2u+IHRtW10W1vnmXZto6Jr23gdZRzgtkbiYV251CUTZ+M+JpV42FXQHA+szz2lxNP5mRlJO+p8pWvbOs6uyXPl8ibqc5Xnyzi7C9UPate2nOfahS0/jB09urnuK1e4fH2ta9vwQLB2edMuh2Rc3mKFHcWuaAfCSJKf9YykNJuRlKLTamQkmXhVRpLc8kbKtTF5aYc5XHzCeB6ilZHkJUpaAFFiJCFWUnDW1q3N1I9S/BQm5kIXuSojKWJUpUmubUW3tlCJlPz9uJlRBQdnTYwkEiMmy6g668wz6djDHrbVGPHOO+/0eYkYSa4uGxhJJi9jRlICQsQGRpJrt2VGUjSRHiqsCbUnvFWNSowkxuoiFydENAHFdnHrW9vzQJ9I6qWXXnrppVhatwZRqLDwW3mmMWO0tGE+I8moOShAuqh/YI8m4LKGSSkrtmYk8QliJFXYMRQ7v2BHFXEd2bNetGGLWDFVLlZgpQzyk9jlaaRAKruuyThkXAQb47BexRvyHTqwgO/r/GTBXCLjwGTyMoijHYHkddOub6Pyw7omuuNhxwBjx+ABjkJDntvjoch1yJyHbBmF+nRxRJNT+WXyU3YEzNhFTrY/do2AdTwh/WPXzzC4PrbfM/FMvg8DftdegvyEPKbAoZDACj6PK/jTGEkcsJG2YiSpE/VspHmMpJrCaR4jSU0UAYWGr28y/VK0NSwzkuQJe9O6hDt0wEhS38QfR5IK/TWniIkuf6QAMcoMx6gy9WSVtOYBXypYcP3bem9XJCG2uGM3ccA0AowkNHOBGUmuY6sykuQkvGUknXvuuXTqkcNbjREfGvp2x0biiE0N67uoZA7h9Fa51c5IKk8UxYwknsBIUkyj8boCVhLKN6tw4gojKQUD2miiyCn82hhJXZnUJ5J66aWXXppLTZFUn2iayEgSSiTESnIKIsueSbWtaqlkyubYMY6RlDDThyAjCUw0zWEkAWVXHpwEzBdqYBtB1zcKr8/ghqZNzLRrW1Z8kFMiDSu6Ok7+wRwnKZj2EEcxXxKFbmt7GxcwveKflUi24Di0cTHTOY8UTTCOyPcxjlmxza5temVcur9J5d1CuLPJfB9c1YZqG76ZlV2a4YDirN3fFvbjq0/l65WUAmHt2mZXRK1rWwLub0nl+xDHKviUUkusqEvXOZ2fe+MeMtmtqOMhm59Uzk8RZyFc5GScBYizdm3z7WV08XNKiMFtzSsiBwURGRbY6Cpo8nOx2IP9sYyj8n93D25dW4D8LzGSJPMjZiQZRWiNkGMZSaGfGWFGkskgd1wpuE+Z0/NPsmjrlP9mChk9fg8W3llTZiTV2EhZGYMZKyG9CCOVml3EQve2FCiTwlFDPBMB2UgQURUogCAbvU2R1KRMkvEqjCSC7UkroANTwq0YSaeccmqxDbaUz3/us6GbY2pmJNEsRhI1MpIgHR0iqUqMJKMAamAkVZVJqaAAQmwk0X4RG2mMV2UkleHZre5tJ6sy6VB/NOyll156aStMfjWGN6vg0Yp2OZ78bFZYMFJEwIUkqy9ivebsFBHmDyg+sk7A/hdBhQWxeB0PmIWCgc3RiZ8HKozxZMHStBU/+HjmN73kR/3ZtzHRJPgCqVMd609eQ12X4AI6hYVQ1Yxxco5VV8qAYmOIl3NsGiOpPd/rLaeY71zJd6KCA6FUfM3Jdzox+c4g3+UfYQUQRyQZa+HH+hjRORTbS5Dn8G02iiIiU3uVPCffbnJ+ctVdiALuB6t8n9Yf+xyVOa/bE1X4dVE2DP+nVG8mlXBXUc5ZexWBJEflhz6GrKbjYo1Hlb+pb1n/Mh7kqHHUaTllZ76uVOgj8F3B1RDKY9WP4w9w8arqw/D3Mt/WGdzTossf3CRUm2fxyr4rcL1mrXHr+kddlFXd4jNAiC5c/1alyeoC27ue6xs5UnQyqAg8ljjrrLPo8OHD248Tbf3DMQUaCzDsI92YwtV/vcX6dBRt1Pa5ZfAh7vFVvRuVLMfOlQzjsR87MValEhiD2deo9RbdQuV9Q9xTeOIY6mQoXZHUSy+99NJY7EpN5N4Wu67hFRHnjjUKfNoYSbNdrRAjSSmTMCPJsY1CRpJQJkHXNRMnUCbleI2MJApcrSyzwCk22hlJRde1mntb6Lpm8sK44XmGCHYJcytlwSpf1WUwUuAZpVczE6yW77Rdvn/TmGCNboUuTmUFM1biRe3G9i9tTLBYiVdzK7R5ngp5jlzXonZTgM+LinBxEr4uLVBu3Q4iIYnNYwLtLtiqdiCMJOvShtza5Gf3y6WtxkjCSoaYkRRt1UkFtzbk0sax59okRhKsXuCGhhhJDUokx0jCo41UoGUjZdR0RpK9vAOjp+BGJ5VNLS5t+HJj17eAbUNFlzavACsxkpASicLPTysPPvgNuvvue9oYSdClrcJICl3a/Bkgl7YqI8n2AxVGUrRXL2QkVV3aGhlJYWtpUyBV3dpKMG7qLm19IqmXXnrpZWKBDyKpumQ7fnf4T3uDms5I0rCG+Ywk8c3AvUadB3JfsnHcNBo5hkyhYhsYSXSCGEnm1AEjKXbnwm5e8GcGZgJ68EYJEag5tItcxe48mEwis7qmJ5imqo2+lfIduPCV0zloCNjND+e5bTf6gGNXwAn5rtqN5XQBxpmoD9hA0NvjRA4DV7tKnqvD5cZ8JxCAPMNJska45OMYtRuZoHlrR4n1VXtwaWEkRQKcrRhJCrJimEuClQTbqT09BEMW9eMZPdMYSXoCyrtOhWKIkJHEjpEkXcSsuVPEpkKMpAKCKmAkefbPWF8UMJLc6WFG0jhpKphsOI7tV+zeN8HqAecZMZfiTZS2/vXhu/NzFRgzkhCcHjOSAHOpwkiyroKSkXTGGY/Ycpz4EN3/wP2QkUTWPcwggaxLoXWna2EkDRNGyHWvxkjy83JtjCSawEiS/RtkIxUZSaTd4KjCSAr7NTDxpNzyGpTfVN4K1yeSeumll1560feMaC908g/lRYXHVEaSU3iksltbTZFhl1ScAsmeFqOPi4XdecoMEoO5yYwksDQUu7X5oQwRMPnhSIFk4iTsxiXjaFcs4xq2cb+SiibtGpbrU7piyQfnnY2bWI6z/m3otmbczWRe7uzsbBgywDXMubZZ17Ccn2sXOVozfziIE7i2jXlKm/NiznGG+kRxjCuZzHflYiYSV14Xme8+Tq5PGWfId3Tdk3Rt2zCXYJyE48h8P7KzY9zfcn26OM5NT+bnEGehElrlg1Agade2ID9Rnit2E2kXNuXalt+XiqbRDW2xUA9ER3fW7WV3d091LNq1LbcX68I29MdrFzYe2UdDQZ9fv59d6iQjaefo+nx3EfvLdKsSUlRmJBFUhIZPLpaRVFUoRRND+LjmK5QidA+E9BjBQ91FDECcQHSkUMLPfRH0yHvDeYUSZiQlOGhImIYcPt9yqlKysCQpVCYldLuMFVgUMZJS8XiSYfbEz91tjKQQ9eMYSUihNJ+R9LBjD9unAaNtR2TGD6g9IYXSNEZSamQkjRNOQf20MZIMRLuBkZSCfIwVSuDjiJVE+LhaFUqhMskwkpxCKVCA94mkXnrppZdeghWnumtb2/5pP1GUJ4y0tKG8gGSg3Eo5wKEAQX2fUxCn/HGOJCHOBY4b4mVFEqjQ8bWkP1BKKyV9cFKR6O1QeaJPCDCSxre57IplLyTAgyTj8OZdyApSCRknZbYIYiO1MpJknkv2DAVuP/CARL5HznZlJQi7fI/d1gwjSYVg554YrT06jkeKAB+k8tPqbBw/JQUsMDJxgDqPICMpOGnDAUmMaBoy32FC+/asfoa9wjH8gm7SkWtbnOeYkZSVSTrfXX9MrTyLknubcA8s2F/bGiagBJIuRHBBPmHJGztXsprLmu9HCSgCrOKjvBEKxLPChIJdfdxHyPpHbl9aAabnZ9wJm1/RSo9AMKK3yUK30gTuE+hyGdc2229aJa5RfCTgWqo7efufRsmCGeZ+kcjvl4WKFj9foxVgvt6t9jDB/j0xdvGDCjmg1HG/xtjlzh1PUO/7M1D07oreFdDMXLBVxtj7qq4wq+ijioKMI2WmVXCFLoJRqzVxxno3LmuFLb6on0xOny3jFdJ3TGPdv+X8r2xdC1w63fF1t7Y+kdRLL730MrXUXNv0dEQDMwau0E5nxoTkhm8WM2b8+YqiyLKWUgo2qEjGSwMjKQWua43MmBZG0qg8SZoZI13bSFj5ere1IY50oaLxei6gaxtllzSz2QjG2biDoVzNbms6TyP3N+SKpd3WTBzhtibzXbqMpYTi6K1rVlEz1o9yf8v5vje6sGnBgVU6Dfmujkfke75eOt+li5n8Ae+2to6nXdtynMGFzQ7UXRzgtkbiYX1wWxuUKioODcyQrMTDroLieEx9wjgkXNsMI2mhjke6tu15tpFyWzP1uVIE+YG/dm3LeTq8LxUULOMYNpJVIg3/rj+ff2Ox8O6KXlFKsSvagTCS5Gc9IynNZiSl6LQaGUmuQyMqMpLYuEpGihjkUopPGM9DtDKSvERJCyBKjCTESgrO2rq1mfpRip/CxFzoIldlJEWMqjTJta3o1hYqkZK/HzczquDgrImRRGLEVGZUbTNOpDojydVlAyPJ5GXMSEpAiNjASPIda9BaqTiRHjKSCLUnvFWNSowkxuoiFydENAF2ZHHrW9vzwEn7XNQfDXvppZdeyuWiC5/B1KhIKhcPJ64hPupxasyYWhwbNWLHEGS+lH6wehhok3/L8USfqNRnHC/4l8oBNMdpPtzJF1DF3T4/TX5VYPH1KNMZSaUKm5/vjflZjefpQ80fT2Slh+3tbx/yvelfpoWvV/x+57uLhyHcE9N85uC5PlFUju83SRUfXKpxG5VE1cMpbH2bVF2FiaKt44WCleb6rsK5q/Ve/sH2wykrQJrTiQoSpHDiqTUeniwp7NybfAbF6mVq+aGJ9d9WIeVpFy5BeCbW/7QWEdd/e8YUz9MwkoCkbVo8alAmFeLjCafiFyqXpz5R1HKCSJn0yU/fcFLNrfSJpF566aWXxomk6nPJPk00uQdn9PzZ8ODcslXtwB+cGyeacDxEk2x+bg0meOLn4GkP8t/cB+dWmDauzm0nmlC+16DcW+b7nImm5gTB//Atke/f9InV+hcmxwknQkuuhNMniub0x2P7QivusyeaaoykevzJEzvFmZbCcTWfYMxImvuoKQNVdtY0Tx1UqqF54qP5ubdx4mP64z6eIAqQSRPrvTzxMXNms14dMyfmyl9v25pVP/ryxNz0+p828dHCSJo78QTp6FtMpM+cqTRnNWMiHdZ/g+taU/17RlJr6RNJvfTSSy+9wImk/Lw4xb2t9PxU2AJ3QhQb2z6Ib/ng3PgAfSIepJt+4cAnipDd+ex5mUnubc0P4rPy3Svx5imd4nydM/NzwvMdKpPazrbebqZMFM2bGWKame8oz02+z5soKk08HcRwmc1E02wBQH1iqP3Jed7EUM2lbbZgCz9YbjcxBCZ0pglUpk8MNc1AleNNmYgrKWH2bWJoiqIpmphrm6eZPzE0feav8egLEx5bTzRNuxyzJobQ4YcTTTN6NwThnjHRhCeG6hNx9fpvnNBpUCBFW+mmdW8xG6lPJPXSSy+99AInkiY/OO/r1qATNNE04cm8XTCy7QTRAT04T1Zs5P+1csWiwPXMsH2WP6PdxGQc795FxvVMxVEuaRPjmPfXLmmalTQtzroeeGAKiXyXrl7Nx2PZRDKOYi6Vj2d03RL5vqp/x1zCbnT2+lpXMra/644TX5dqHHfdc76j+pRxMuNIxpEuciaOqM84jq5PeQFKeZ7PN5/xzibOrjlf5fImKmiV58s4uwvVDw6uat5tDbiwbdzWBvaXdS2UcYb31y5vut1RweWtOuE0cysHniiavXNrH7a+6QfMJkbSlImd5q1SbSe83cTc1GmRg1AilWeCputTJkwQTZ7AavjX6Rek7dcmKmyaJ4gqCpvmiavGCaeD3/pWZyRNm3eep0BCE+mTZ5aq8WavE5Rd2hrLyTaR1GHbvfTSSy+16Ri0Jag6keNdqOYwY7Tbj3b3aFMgWZ8m0i5LgXuNOg/gXkM2TjQBw9JhKp4YGl1UahNDyh7ITwyVXOqsO4x0n4q+4OMZVy3WiibrkkbShYq1y5g33RJTVlEc6SbiXOTyvw15Frm0lVzcVJw0mIu1xtH5TkZ55+ohiiNzT7plyRxW9bn5mIoj3JXGOGyqLXJ/4+Hj5TgiL1nVD3KRw3FUj2Fd24xrGNt2Mx4njqNd9rBjnjpfUZ/rKjQucOa62PxUtWps3pSLnHNtA+3FvlpnNy60l2qem7qPPhe4+MSMJOuGhl22hL1QwEiyLl/s3aDkg5V1NxNucO66INOjmkLJuGDh9iqbNH5Szkou7TrlXaVKB+j7cesiZs2dbH1blywXz96q9MeBW2lSBz7WF7g34vq3EyH6E0n0WziOdRu1Mx/C7Qucp6v/2sSTq399+O78XAWa8wPxnFuecBWM6t25kMFRGTnXNjVgQfGMOV1U72zq276OP2fjWbc8407n6isFO/8Tdt2D/Z/5BSowkqy7HfuEUa81RZF1VfOui2aeZ/xnrCjC3qutjCTplsfleGH3dvK6t3VFUi+99NJLpXzTGEmTt7xtsXWnMBlWnNgpfqD8A9syY+pxtt2603ikwdLkfm19UxOZW8CFDxLGvQ0jaf6Wt8Z8n8gC2+98368tnn/pGEmTtrxtme/NWzwlHBq7ErUPrycykhokL1sxkoRSZmuYdoGRtD0raduta2UlUMPH25lLTfXjT2Q7RVGbQqa9vvzb8xhJbaykOYqw9ss2n5FUVBQFW7POTIfoYjpMT6BT6Ww6RKdtItxDTF+kh+gz9CBdT3v05c1E/rcCI8ltYZs5eaAg2geiUJqeAJO3wgXxESOpNV7f2tZLL7300gucSDohD+L74d4280n424kZU3yQ3hc3q29fRtJ+MWMOcmJ02sTTDDbSt3G+t8+jzZ0o2q+Jp20nWLedKELw+BPJSJo/0bQ9I6k+YbX9RNMW5JUDYSRpBdg0RtW2jKTyTMj0eUEkKdnHiaHJjKRpU2UH4dbWzqjar4mhNkYV+tXz6VT6XjpKl6QjTdl8NS3oD+kBuoO+Maue6hN9M2FtbqLvgBhJExN7NiOpOg+4/dY1IuzW1ieSeumll156KU4ktT/2bgsVNnFOJCOp4VH0mwbR/hZiJM1TbExUFIWKje0g2nii6JuhKKpMiG6V75PngfZnoqlQAfvFApuX75PT/9t+YnUKjFs/GGxjahRM7HzbM5L0hNP+MpJwvbfVf+PEzqyZo3CaZuLE3Jxpg/LEx3QBSIUpFW6Vapy4aqiOiRdkYv1Pa7DNbm1gAuT76WH0A3R01j33v9ADq7/KvOv2jCSXhvvPSNpuIr0y4TRxXnK/INp469u00ieSeumll156gRNJ+6XQmMJIOvgH74bHxlDxsS2M+1txK0/Tnp3g/E7wg7ebZzs4xdz2E6Fz8n3bidByJm67BW7W1retJpq2dSWs/MtWE01TJob2a6Jpu62eW5gcHdBE0UT763ACa8uJov3Y+laaKNoPOPc0wcp0OHe13g8Azr3vE09TYM4TJ4qa4egzJ4oqirkpW+DqJ9BuwvZaOk7PTztbjSc/zLv0r9J9+wzTnuZyN22iaJKkLbjqk2nlDRNFEyee9mmiSMZHyqQ+kdRLL7300gucSKo+l+z3ViChRJrDSpquqDiAB+ettgKhJdI5Co22J+0pD/LQNcy4d8nD3dm4kikXrZrbmnPFWrtfSXcz9fmKC5hUZixdq5avU1zV7Psyzt7mfKfF0S5p6/NaqMtddn/T9bly9Sq5mIWubfi6yDjDdURuevm6l69v3f1t6aq2s46zt6cmVpuOx7rOreLELnXx8QT56c4Xx6HBhU25tsn3c5Hvy+t+dGfdXnZ3dX1G7mno/ezCtnHxE/UZxTm6szO2U7nivnR/oybXNjTR1MhImjJxNUchE0xc7dvWta3ZSPu1Fa65GponPibuNNxH9zb35NpoLz+l3lsYPVtOEFW3Im65da1xYq796H2FvIaPbT2JNE4m0YL+Fd1Xngc8IEbSFJe7lv5oG0ZS89a16sTQllvXCvDsqRNOJ9tE0qH+iNhLL7300j7NQ8YBY3DGKrlgxfGMw9TGNYmdaxRwsYGObKx9eZxrlPkDrljZS8n+F0EXKmLxOh4wC5cnNkcnfh44VY0nC2x8rEuaj2d+09uiqT/7NvKKCr9A6lTH+pPXUNcluIDmrRyPRTzW7mslNxEXLzt65RybkJ8gp+N8r7ecYr5zJd+JCg6E0nVsTr7Ticl3Bvku/wi7pHHk9sQ2cfQxonMotpcgz+Hb3NBebJ6TO8Xx29p1LWgvVInDOZfm9Mc+R2XO6/YU98kU1Gw+L+uQZ1MJdxXlnLVXwcfQ+aGPITv8cbHGo8rf1LesfxnPtmlYaTYe5T5ijEuFPgLfFVwNgTzW/Tj+ABevqj4Mfy/zbR05f0aXP7hJqDbP4pV9V+B6zVrj1vWPuijj/BicAYN0wfVvnSxZXWB713N9IxdcL11FTB9LfD8f3bdJpGV5Ph2h7x+3xwVjC3X43nGTmYoZEzVX3Tb92CBosLifJN3WCTmzcuxcyTAe+7GTdXq16cvYfZS1N2iQRcHYCYyheOIY6mQoXZHUSy+99FIpUxlJB7M16AQxkibs9WnfUbQtI0mMhr6VGUnNPzN361o786Up7AFs1TwpmWD77d52gvN9v9wKTwwjaZt2E0O5ESNpplQHb1X7tmck6Q5ofxlJU7ZKtZ3wdHj5AWxV20qJVKZlb+f6Bo5r8g6mLbaqzTiDaQowmlkLBCVB5/Mp9D+n7ziQseVb0t10O39j/xlJwKVtvxlJ++/S1rhVrRpv5mzIUE9bwrhPNkXSqf0RsZdeeuml9XlOPIhUn2f8qvUcZgwb9QVxGl/bHpQjFUdSqqVkXtV5qA/oiSauPTDbFdrgQZmH19qDslrd8k+eonqC515Wr3klEH/Bx2MTJ3jwtitc9mcST3vwRouF5rrMsTtHq2vTINxWbfStlO/5G2G+u3lT1BBAnDDPbbvRB4ziTM531W686MdPg5FYugUNBL09TuSY9tKS5+pwuTHfCQQwK9YyjptIDRPKtBuZoPnBM1TYcf3BRW+Z2uSYfKVYgDNUuH9wMf32GC947jIXMHEaDwe2U3t6FVh02vTNKVB6+erCe3XyRB2PrwTVZaUD9Hmp4g3VYNs2qKfhgwn06yqN9Mf9+Y0/yLq+sK4I1L+dCNGfyPUfxbH9it37w5vLgM/TqwRr8HFb//rw3fm5CjTnB+Lp6hXjhEK9j/UfzDvkNJDjDtORm3jfOxOs3VK+h3foN+he4k39jK+bI+cgc2I4uonDKbjP4w4uYiQN9ZSr2yWMeq25rrHpJ9V9F/W34z9jqHao1G5iJOUTa1J+U3kr3MlW+kRSL7300kttsWK4+QyD6iSWBc1DeUnhkcZBcBAnxXbp67dTflXxhuPbfHDzurxJ48eslAd3Kd+7E9nTYvTx/Gq/oX9+89CR3GCaxGAumVc9eFiPkNSru5tTHg6McXB9pnFQro9zHETY9TEbJ5k47md0BbkHZxsnmTiuPlPBrc1fOJufdjWtVYHk4iT0dK7zE004teZ7rGjS9TE933Hi+nzH9SnzHOV7CvI9bjc4Tmu++zy3/ZDMzyEOTGgTD+e7y8+gHwqnc5KuV3/5QXsxSiQV2cZJth4L+Y4mVuGgX8Khy65ENh/1YayPt42RNORlKktehnimH7b94fqztvvTShnIXEr50FH9JFt3ASNJ64JUB2WuHzW5iOW3w7MV+SpPHD/3DfUjGvj4FpXw2wnpxAjLJEQ7RgolqMdJqagoSgUoku2n4HEl25vGdOn1YSdxjeLjGV9TTVGUioykJLDMsFmnFJwnzstUYySlhG7b6ojPpFPoknTkwMaWl9AROpMeoC+nh9SBtDCS0thP2+bq+0M44RTUTzLjAALjXQfRBgql5NpVori7Gu7fZa2Y6idBfwknrvDtwY+3qMxIcgol172dnJu8OiOpl1566aWxQGYMz2EkWVZMwIypcDioQMqYzIyhiJFE+8SMoX1lxhCkA5TYSIzZSE2MJCozkuhgGUkEGEmt6ottmDFxvvv8xOG4nu817gyKYxleXMl3quU7HWi+U5Gf4vNdtgmuMpJ4/xhJE5himT9BiJgRs5aowhSbxUjier4377MsMJLI5io39s2NjCQqXuwix44AI0kL9DQkBTGScs5xpeZLjCTAXJrQR4xKQsnoaeKocYWVpNs4FVhJJYhSlZFU5P5RwEhiwOvDWmIPhWHHSKIiI4mCuyg3MZJyVyWZRuW7smUl4S6UBaOKK6ykwq/VGEkc1zuBvvHidPB6i4uXmo4aI4k5ZCXRXJ6cZCTxVEYS6R6/xkiqHKa9g6CxU4mRVGIl2XtKC2cSMZJoS/7eX9bSFUm99NJLL43FKzVScJOtMWOw4iM5gU+NGRMoNcafqSg2nFLDxsGKgP1SWGTFhlFawLu7iZO8CjpWJpk4UxUbQFG0csWiteuZVFhI1zap2Bhc27Lb2hAnu2IlIbvGrm1rt6mVS1rBtU0qNkruaWu3tT2VpzpOqsSRbmsmjnJbw3FSQnEWausaqs+xfobjEZIZeV2k4GBV/zLOJt/V8UQuciLftYtZ8q5te3tKiadc0kQc6No2usuJOMBtbaw1EWc4Tp0Pa/cxqcTTroK5/arjgfW5p5R4Oj8HRVEaXdjW55vzfGcTZ9fkuXJzE/W5yvNlnN2F6gel25rMc+3ClsbnoKNHN9d95QoXu78NK9BrlzftckjG5S1W2FHsigaUGMPKetB7qv5bKpHAnUnHg8IcwEgKFUgpOq1pjCRTP/p2abQ9gk3FoSLGKhJ9PYWKH6RAUooJQI/SAi9R/1jJoA8DK2KgAgkqnI3iBynAnBIsUQL31+ECphJTCtR7rn+cc8lKTtx5poISKfn7MVCAqfovEWvkOAO2J3La31z/+Aotj+fxdPjAx5WPp1Pp3WmR673GSILtCZwfTWMkJdduU9BaqajYDBXWhNoT3qpGUOCZwj2LMI5VDJnjSlhiBeK1PQ/0iaReeumll16KZQqcGDFjEJx4GjNGw3bmM5JIObvJ/wlRwwAqw4b5EsKF7cqsXSZrZiTxCWIkVdgxFDu/YEcVUqtplvViFR7jph6l0AArZZCfxC5Po1WzsuuajENQjVGNw3rlb8h36MACvq/zkwVziYwDk8nLII52BJLXTSv4RsaNdU10x8OOAcaOwQOUd0Oe2+MJV9TNeciWUahPF0c0OZVfJj9lR8CMFYGy/bFrBGb1WMCj2PUzDK6P7ffi1Wi5Zc21lyA/IY8pUN9RoHqiGYwkDthIWzGS1Il6NtI8RlIwEca0FSNJTRSZfhjXN5l+KdoalhlJ8oS9aV3CHTpgJKlv4o/7J0/7NcOUovDyR3b1hh3kGFWmniwjyTzgS4YUrn9b75qx4x+i2bCuourQzB7HNAKMJDRzgRlJrmOrMpLkJHyRkbQ5jnNOwMads+mQ6L9S0J7qjCTZfnW91xlJ5YmimJHEExhJimk0XlfASkL5Nox3EcwPqYwSF1nurr91bL42RpJ9HjgZJ5W6a1svvfTSS6W0urbtlwuWc52SDJo2ezPsWlX+ucoHtnWvmuFiBWmSzWZpgftUeHoTXbDqB7D/Llb2AW9afmH3qv2aWK1BubfM9ynfn5zvB+HWtk/5PuX7W7sSTmgvk13f6mlQdiWcbgM4pz8e2xdacZ80uPZsjappVXO8yaZvThIVHlfzCcaMpPbHDw7dyRpNuIJ4zdVQsgGrM42aXcS2cW9zT67Bg/Ect7XYBq5e/xPd1lB1zHTNK389mpibevTrf3kTPZwemU450PHlV+gh+uX09Ur9T/fpi5rrFJe7lv6oIJFr6NcwjHtqAqA4k1zXCvDsqe5tJ5trW2ck9dJLL71MeOwlyM+YyaBx7BjAfIlcbKDayBAupjCSCvyN/WHGFJgvkCcRMJKYYubSFsyXMiOJy4wkPlhGEgNGUml/v1IoqX39vD0jKcz39Xfe8PpfpGs+eh3deO3HV39XfuCj9KofeFUx33/w+1+9+txN136Cbrz2E3TtVdev4qhzMid4/Phx+umfei39zr99G33o/R+h66++kT5+3c1003U30zUfuZb+4D//f/Sr//BNdOETLgrz/VU/+Cr66Ieuoo9ffwt9/Pqb6bqP3Ui/8PO/WMz3y553Gf3pH72XPnH9LfSJG25Zvb7pV96k8v0X3vBLq+P5xA2fXP1dd/VNq/eGOK/+gVfTVR++mm6+4ZOrv+s/dhP94s//bZzvm2O57LIX0Hv/+P1084230i033rp6ffOvvNkkDmYk/Y9v/Lt04zU30y03fUr9/Ytf/79wvgcNbTIjqZTngJVEgAk2mfuxJceCS4ykGs8rYH5QKyOpAMRi10dTlZFkbloqPxAjiRkzf8JZaUKMJMNfCZErHHVagNHDHp0D1b4E2EimhriIQKLoA1y8qvowSmwkzEiiIg8tuEmoNi85Q1xkJAWQGXPOESOJgKoxuhtbNhLF1QtUmoiNVGAkcSMjaeJY4mraO/Bx5TW0qDOSgNo5ZiSVmysjRhJNZSSZHr/GSKKoX0Px2I+duMxIQmykfI/iShYFYycwhuKJY6iTofStbb300ksvzasww+pO2b0tdl3zqzqE3LFGdlAbI2m2qxViJCnzKsxIcmyjkJEk3Kyg65qJE7i35XiNjCQKXK2si5uMM5GRVHRdq7m3ha5rJi+MG15ZsRG7iESraVWXwYgJZphTlgkWt58KGyxqdOb6/NUf+VH62b/xN+lx3/k4KCXf2TlK5593/urve17xvfT7/+H36C2/9o98vq/+I0VHiZlg0bGu8hIjQ5LkPKATTpv3Cq6FqVQ9lglGuv0+55Ln0OHDfrj3lKc8lS551rPp6muvMe3GNeDArdDmeSrkOXJdi9qNFVQZt0IK4iTsIomVeMbHUrWDSEhiXQgJtLtgq9qBMJKsSxtya9MNaX9c2mqMJOz2FDOSoq06qeDWhlzaOPZcm8RIgtUL3NAQI0mykSpKJMjokf0QYyUSYfe46Ywke3kHRk/BjU6wqZpc2vDlxq5vAduGii5tWWHTwkhCbm0w4CbeO9L99Gw6Qo86IN3FnfQQvYMeMPUfEIxClzbfYpFLW5WRZPuBCiMpUiCFjKSqS1sjIylsLW0ubVW3tpqi6SR3aesTSb300ksvEwt8EKnutMDMmLQVI0nDGuYzksQ3LQKJwUooYCSRjeOm0cgxZAoV28BIohPESDKnDhhJOk6wlcftubdb+3na1rdAzSGvS9XuPJhMIrO6Nm3LmlntKwmlgnzn0tY1k+9/+w2/RK/96deuJotayumnn07/3U/+93TBeRfQ//B330j33nuPqDYGjW6z0psY5nl4foHzEqlV+E0cBom5WfGM8p3DGmJyeCTx/e/73lfSRRc+CX73rDPPppe85Aq6+pqrCaEn1pfLtJeWPFfNkxvznUAA8gwnwWRp2voGVEs5t/LWjhLrq/bg0sJICh2LtmEkyecuy1wSrCTYTu3poT1gon48o2caI0lPQGnGDpXYSCEjiR0jaYwnWS6E67vESCogqAJGkmf/jPVV8ErTp4cZSeOkqWCy4TiGkeT2/nBmJYHzjJhL8ZZBW//68N35uQqMGUloCyJmJAHmUoWRxGLxqshI2sTZY6Z/T/fTz6TjdNrTLtrXceU9N91K76D76UGRjyObipJpT3VG0jBhpOI0MpL8vFwbI4kmMJJk/wbZSEVG0vDPGM4dKrWbGEn5xJqU31TeCtcnknrppZdeetH3DKvwCJRIVYWHW9EuK2a8oimV3dpqCiR1F5RKJHMYdvCChTZeieQECFrJ4J7xKkqkquubVQ6lQFFBRlHhFrIjBZKJk7Abl4yjXbGMa9jG/UoqmrRrWK5P6YolH5x3Nm5iOc76t6HbmnE3k3m5s7OzeoWuYc61zbqG5fxcu8gR7W2O06YYGSWfdlvLS5ir33JzAfrzP/GjP0l/7Sf/2noSKQUP+uD9U045hV70whfR6/7W6+mt//s/FtW2vAaH3O8O5zu6oYkV8cNHDrvB4srFbGdn7ba2cjfTSojhJ0i4NKnzTfnfxjij+9vmuhw+DAepa1c1fV3SxnVuGecFL3ghfcd3nA7r58iRw6utev+HdZGL8hPluXTZ2+Q5DS5syrUtvy8VTaMb2mKhHoiO7qzby+7unupYtGtbbi/WhW3oj9cubEyLXe1yiD6/fj+71ElG0s7R9fnuivbidBt+Cb2RkZSqK+5ImVRXKMWQGshcmq1QitAoTiJp7qfU5CKW3w7PNlAo4ec+Z8MGhTBgKiJhJRC2LRPKJKBQgsiXVPSI0hkEGTGpfFzJ1Be2vxLzftY1Dx/P+NqiUCpAjpLAMsMBSUplBZZJnFRjJBllkm5P+QCvol164SMeRT/3tn++r+PKf/GSH6Gr7voqyMfUxEhKoULJj+TghFNQP1Z5j1wFHUQbKJRSqFBC3RVSKIGPJ6+Exe28XaEUKpMMI8kplAIF+MlWOiOpl1566aWxQGYMz2EkWVYMYCQ1cDioQMrgqYwkihhJtE+MpNLPW55BgZGE+Ah2vR2ykRizkZoYSVRmJNHBMpIIMJJa1RfbMGPifI9dlurxTL4zNzCUmZ71zGfR3/jrP0Onn/4d6l/uvvtuesd//Pf02p/9aXrqxU+m//anfpL+zb/513TnV76iV80OH6ZXfu/30bMufpbLd1SNxXzHJ1dcw4T8FPWDlt+BmWIwcsBIOnb8NLr0kkvp0KH1UO+hhx6iW2+9RV37x1/weHrp5S+dzBRTTmyNTDFRVYqxBBlJNIWRxPV8bwZ1FxhJZBlJ3Ng3NzKSKGYk1Th2BBhJWpCqISmIkZRzjis1X2IkAeZSsY/Avbpi9DhGFYF7I1dYSabFF1hJJYhSlZFU5P5RwEjCasbYb9VwhAwjiYqMJAruotzESMq3Zuu0GN+VLSsJDxlYMKq4wkoq/FqNkcRxvVOBt/gH/ADd+7Wv79tYchnrnfRAeWyhhkQcspKIZvLkJCOJpzKS8hVpYiRVDtMyl9DYqcRIKrGS7D2lhTOJGEm0JX/vL2vpiqReeumll8YSMmPcvUgzYzySo8KKSSZOhZEUkhvmMJJUHMxIUsyYIiOpoiiyrKWUim5UzYwkp0wycQwjiWYwklaKIGK94sZppcwhyfjYfH9vsedZL0krgiQzZjHGSWqr0d7eHty6BuOkzfGAXB3jmC1sOk7O0+F9HYfXcUjHiZ4+13H2xjqWeR9NKA318EOv/mF67GMeq1Litttvo3/0ljfTe9/3njHONVdfTddc/TF6+++9jd76ln9CT37SU8bPn33WeivXtdddm1dB2augkrpeOt/3HtyDA8elgogMo0MOdC0jSZ2vYCSpOCI/H9zDv7s+ThqVKvJ4fvSV/w2de+65atLtnX/4h/San3oMnXbaWqX0iEc8kq546V+h97z3TzMBSSjxVsczMEMEI2lh83yjYFio48l5vju0F5vnY15phchaEeRdeKSCSOb58L5UULCMY9hIVok0/Lv+fP6NsV2kkqKUYle0A2Ekyc96RlKazUhK0Wk1MpJch6bDE3nKj6hvDhUxVoFLFJ0wdmtrZSR5iZIWQJQYSYiVFJy1UCj6BDCKH6QAc0qwqYykiFGVTP3jnEsRFA4ppAr2eY6RBI4/VCCJXGthJMk+HjOq0HER3frVu+gNf+fv0W/8y39Gp566nYvbgw9+g37hjX+Pbr3rLnUvrDKSTF7GjKQEhIgNjCTfsQatlbCrZY2RRKg94a1qVGIkMVYXuTghogmwI4tb39qeB07W0hVJvfTSSy+NpaZIyqs7kaLI8mTYOXPBOIxXX93qtIunV+n9Ip9dbQ1c25TaxiiJuM2ZhoHCgtHKrPy+XW01q9xuzWpcDcuv6nisww2Rc8qTugEfz6xq6kVhUFcl5xEGC68MVh+5okwKVtEK+VlyXZMB5W+i/Cw6WflFvkK+hy1u9f+OHz9Gz73kuaOyZlnuv/8++u3f+S16z/v+FOb7rbfeSm97+9vpq1/7Kt1+x+30zj/8A/oH//CX6f/5f3/T5bubBrauic7RCZxf4HxFjpFERUaSbzdlRVIp3y+99Hl07Njx8bOf/dxn6W3/7nfpjj/7szwIPHSInnPJc+nY8eNOCcCRIxTMd+y0Q9vme2E1Wq8SI4VoyQXO/E+OVKKVPr7UN8s+GvXNyA2OyctJWF/nMYb8v5rCSf2GViHoY6spnMBqPIpn7z3APYyDvgbXf+DexkgZA+5lUf8MFTFeGaPqHziaeqUNVtnmNo6UW+z85oiAwsbWk2ujDBRJUiVLTkWI1KKtiiS2DTt0y2PtGiauaU2RZBVz0VjCKWyCP9jHcqSDWX/nw1d+lF73ul+i++67f/YYcvnd173+79CVV16lzoLDPpJcW4raCnS5K6o2cX15xSVQbnF5DOvihapw9mpu8H927OTi2XsB7HMZurjpQQpBBZL7o65MGkpXJPXSSy+9NJaaIqnGSKKpjCShREKsJKcgMnFiRtJwwKlkyiZcVKwSiQzTKAXxGKyEyp+fwUgCyq5RgQCYB3l0gFynIkZSoGhKxjXKrrfVXKxaXd9CFyt2Cg294l/LT+RehVebqeAmiPM9VsJ75oKuz1TkwhC9+EUvobPOOlv9y2duu43+7W//6w0DAef777z9t1Z/pNMgKzgi1zZc/evWGJm4jIo7HzUlz0hyASQ/CSj4SuwUlJ/PfuYl9OxnPXv81HJb28euvor+4gtfoGuvu4ae8uSnjBNz5z3ucfTKV7ySfu8dv2euC5e6p5gtRuYL1q3N5rtsL6ErIXI5TMWV72p/DK9lMgq7FCE7iowkyfyIGUnIRTC6yiJeihHIegUfK0AiRpI9kYJHWZGRBFo+uP6BQgYobqIL5nRKFTZSVsZgxkpIL8JIpWYXsdC9LQXKpHDUEMKoMBsJIqoCBRBko7cpkpqUSTJehZFEsD1pBXRgSrgVI6moTNq4cn7gQx+h17zmdfTmN/8DuuiiJ0waP95666fp7//9X6Ebb7rZE4NMgs1hJFEjIwnS0SGSqsRIMgqgBkZSVZmUCgogxEYS7RexkcZ4VUZSGZ7d6t7WGUm99NJLL70US3E1Zg6Dxq3GEuBx5EkAfRAUEILESuMURlKBv7E/jCTMfIl5EgEjiSlmLoFV3FbmS5mRxGVGEh8sI4mBEqm0vx8rNoyiaS4jiVoUTdPzvdTonvTEJ9GxY8fU27d88pbtmGAl17Z9ZiTxREaSjldjJBFkJF32/MvozDPPHD9y11fvove+/72rj3zwQx+gr3/97vHfjh8/jV78ostjtlHASMLUCQ7YYrHzIGQk8Uzux5YcCy4xkopq05j5Qa2MJI6RJ07hBHt8jm4NgcKJsDImrPGo8rUyhpsYSRx1WkARA5RIgdrXs5GQMiZEIFH0AS5eVX0YJTYSZiRRfG+09eVvOlg1GDKSAsgMUg8CRRIBhVN0N7ZsJIqr1yjLCgobfPSQtwgZSVuPJZhuvOnj9GM/9hp629t+v3ns+Pa3/z792I+/hm686RNRAy8zkgAbKWYklZsrVHDRVEaS6fFrjCQqnLaLh9WtJUYSYiORUoWXsigYO4ExFE8cQ50MpSuSeumll14ai12pidzbYtc1vCISKT/0inbMSApXkOcwktTCf1kRUGckCWUSdF0zcQJlUo7XyEgiEydycZNxJjKS1m5ZvHFby9dTuq1lpQWNrlhrFzAZR7qkmTgDm0UwkrRLWj4f7YaW81S7reWyciVjdqwk7NqWYHzauIMtz2dvdLmioE3485ILnti1jVbuYOecfTademoeriyP+ctf/tLKwU7Wv74ueyrfV/Vvrot1bTt8+DC9/ud+fvU3xRWORre1dXy70nwoeUaSPN+le9rPv+4Nq7+pv6vySvzwknu0szmmZbnjjtvpT/7kXav8+eM/eRf9rZ99HZ1xxsPH6/vMZz6LnvSkJ9Mnb7lFuRXK+pSKPpznaXRnW5g839nE2TXXXbm8iRX5VZ4v4+wulAJvcFVbu7aJOMqFLbtILt3WBvaXdS2UrKTh/bXLm253ZFzeEgVKvYCRRBQIXbZmJFmXNuTWJj+7Xy5tNUYSVjLEjCRsZx5IRQoubRx7rk1iJMHqBW5oiJHUoERyjCQ82khAqYXTKc1kJNnLOzB6Cm50UtnU4tKGLzd2fQvYNlR0afMKsBIjCSqRUEClDPXHv+z3fuVXf43+43/6A/qJH/8ReuUrX0GHD+tH6r29B+md7/wj+t23/R5de+0N+qigS1uFkRS6tPkWi1zaqowk2w9UGEkA0lVmJFVd2hoZSWFraVMgVd3aIpc2c2AnOxupTyT10ksvvTQWuCUoVZds9aIOk7tBsYM9l1Z+hiBpfB0nmMaJIXDHh94v4pubRZ5kXtV5qA/I45RHYKfRTDwIz8kjHR5eozhkV3rBJ1ZxdDWB6T31mlcC8Rd8vNjxxXMjxAqXXVVLDF3fhvMJ45iVMnnB5L8NeRatnpUUGypOIsM5qcWJWkJWd9jVxRoj6dChU9ygbblVS8Yb09mybkx9DtctcezaNrl/oCmMpNQm32r+ba2SWZaXXH4FXXD+BeqB5iMf/Yha1f7whz9ET37Sk8cJukefcza9/IqX0y233KwmLpFCSisXrCWUYRolNu1GXi6pFAHtxb6qlXi99c21l2qes7oO4ecC/lgM095cD/lKBcciDiaebL89xgueu0xHlTiNh+OuC9IwIBiy2PqSxnaD68mv8cO9UgKqzeMrYUFe4QB9P67icV4TYML1rV9BPLfYoT7uz2/8Qdb1VfBK06dntxrpTyTRb+E4ydyP7d433lwGfJ6u/gsP+Lj+9eG783MVaM4PxNPVK8YJhXof6z8wkWexeJXHHWbAguIxwfq/5prr6ZprrqNf/l9+lX7zN3+dnvbUJ63ev+njt9DP/Mwb6MFvfIPgfKCNx0M/Jq+jHluo+gITr8OEkYozbD9G/R9YmcAw7VxPubpdwqhXsBFP9W9s+klXIW4RcfhnDOcO9cBRc7Bb82w9UcXts7AVrk8k9dJLL730ou8Z0V7oIjPGMznSVEaSUzSlsltbTYFkl1ScAsmeFqOPi4VdZzNnFtI1m8g9BM9hJLm7ecmtjYELCzD5iVgvNk7KcRZ7wsVJfGFPuK3JecLBBcwyklQcUZ8uzmYi08dZ/0/otraKsze+J/NyL3ABw65tpOLI/Fwro8gzkthepY2L3Ma1LRlJAHZtW7t6fWM5GDdl+d7e3sIxklbHMwy0ReIOLmPjCjNFrm1wfF18PwnXtmQZSSzRTAm7ts383fX12hOd1PqXrrjiCjrjjEeM3/n6179KV370ynU+bK7vlR/9ML361T9Ej3rko1b/feTI0RV0u5ifIs9H1zajcxhc26yiZle5ng3NKo3KH+vatdjdUxOrY5xdn59E2FUwu7B5l0Pr2pbf3xMuYpmRtKpn1vFLjCSlJAoZSQQVoeGTi2UkVRVK0cQQPq75CqUI3QMhPUbwUHcRAxAnEB0plPBzXwQ98t5wXqGEGUkJDhqSl1iVSExZoRRc/5BpFCqTErpdxgosihhJqXg8yTB74ufuNkZSiPpxjCSkUJrPSOIUuKRRoEwSebm8H33tq1+j48fX5gbL/718L5GHlmHmGFIoTWMkpUZG0jjhFNRPGyOJxNVqYySlIB9jhRL4OGIlET6uVoVSqEwyjCSnUHLdW2ck9dJLL730Uig1VyxqZnJETjXGyafC4aACKWMyM4YiRhLtEyOp9PPY4UZVABf4CHa9HbKRGLORmhhJVGYk0cEykrBbWyz92S9mTJzvwImJW9uPyfcSd6g0eDmUnKtgmO9Uzvd96hyKa5hFRtJ2P6wS8fix4/ScZ2uHu5s/eQu95z3vVm3vXX/yLvrMZz6tIj31KU+jF1z2giamWBMjiSt5jtoLF9qLr3KQn0G+N1/nAiOJGKjeWvrmRkYSxYykGseOQpc1V1khI4mca1thDjNkJDF02IzTHvfqitFDwHmUsFtezEqiCv/MMqqmcf+oiftHASOJAa8Pa4k9FAY5kpYYSRTcRbmJkYRc23C9U8hKwkOGsmsbBXe/Em8RMpI4rndqZCQhwGIkuGaoBeS2sQUB17YmRlIjTw653FErI4l0j19jJFUO095BIv+8MAEKrCToAFrhTCJGEm3J3/vLWroiqZdeeumlsdRcseRNMRUZSZiN5BhJ1MZICskNcxhJyLUtdG+rMZIqiiLLWkop2OEnmUYNjKQUuK7ZFVS3tbCdkYRdrRJUjsmtPEluKnAuVKSvp3NtE1ssjcICxikBixpc1+r5Lt0Fk2YkFduPPs5TD58ar+Yloi9+6YsrRdSSYbQsy9dzznmM5s+Qdwl7+sUX01v/139Cpx0/jW755M30wQ99kP74T/+YPnXrrdC1bfkbv/F//wb98//zn2rXRNEKlhDrt7zpH9M555xjT84xOuRlsYwkWRar3/2X9M9+/Z/mAfy4wrv+4eUEz1ve/Fb3u1ah8kOv+mG64Pzz1WdeeNkL6ZabPlXt3x75yEfRi194+aqeVH2GrofTXAq9e1vNpRC1G1XlQX4mX43OBc7nJqutV7FrWKwopdgV7UAYSfKznpGUZjOSUnRajYwke4FMeCJP+QH17hUxyKUUnzDaqdfOSPISJS2AKDGSECspOGvr1pZcyzZubdjVLnSRqzKSIkZVmuTaVnRrC5VIyd+PmxlV8ObSxEiSPQ9mVKHjChO8oJ/xirui2qyFkWTyMmYkJSBEbGAk+Y41aK2EXS1rjCRC7QlvVaMSI4mxusjFCRFNlpVU2/rW9jzQJ5J66aWXXnoplqqdNIEVFucssw0jSTN95jOSSDm7yf/pDwczkjgJ5ktwAizYDtszkvgEMZKSBLVARpK8MslyDIIDyD+jGUnJTDR59oa6YOL02VXUlPyUOU3QUakOi9eZtH6988476cEHxaTPkcN07nd+Z/4tUM3nPvbc8fPrCZ0FffZznx3r8c///M9od3dXfWbJ91k6ud17371BvhM9/9Ln06PPOYd2do7SCx71QnrBZS+kpz7lqfTG/+mXyq5tknUTtRdbA07VodN8/Dc0YzeuyIvWxKxOh0v9jEi35z7nufSwhx2b1b8tYbGXXvpd4wzO+sW0F3vgrPPUd3db5rs5T93czcRsw0o8gXZDBdYXh4iMaYwkDthIWzGS1Il6NtI8RlIwEca0FSNJTRSZfrhU7xwyksgxkuQJe9O6hPtnwEhS38Qf90+e9muGKUXh5UeUcfLsIMeosvcDw0gyD/iSIYXr39a7Zuz4h2g2rKuoOjSzxzGNACMJzVxgRlLc0EsTPNTCSHL1b9uTrm8GvyTvI7KeIOLMMo1ce6ozkmT71fVeZySVJ4piRhJPYCQpplEi308WGUmb/siNrwJGUgoGtNFEkbvvtDGS7HjrZJxU6lvbeumll14aC1JoyL/6KoVf0V47Rw2vQ8zsYoXVSkkpKsZXGYfE98Wr+jMfcPGG/3KuU0JZkcSri0fkj1L+fHKv8g99ZvxJc6T5M0m9ymO0dZHjOXpV/j7+wspNbOXkpH4mrd5bOlSNzjabI1y+d2Tl/JTrKrk4+drnODlHaOXStbNyzLKracv31k5UOgeX7y3/Uso5soqzszM6qMmyfG/t1EXqO8vfHeLIfB/iDPl5zz1300MP8XiRTj3lVDrrzLPy8QxxRL4//OEPp1NPPUU81BN948EHVwGW9XP9jTesXNpkefwF59OP/+iPu3xf1tvyO6eddpxe9rKXryaRhjpaLB6gGz9+o8r30bVNThFs3MSWcXQKpNXEWAIqg6Vr287muiQjBDl0COR7Miumm38b4oz5PsQ/fBj2KUdWebWz+tTFz3wmXXLJJTl21AUV3r/w8RfSD/7gq3B+ivY35if5PF87tOnOYnlOR0V7GfJ9+d7RHdFeNv94dJW3R5wsYfW7R4/k/BziHD2yclyz+bl8b2d1HfVJyziyDL+r+vjl8RzdUfEJ9NGW+SG5Z7Knkjmr++rk++gE4pm+WvfYvq8m0Ffrc5D3IcDyM6enbkiyX1H3Q3Mvc8KbVOAoJdX3+Hjk723qhNEdIrdtV/+mjaN7mq93eVXFXyJwT0P3tgTubeAeaesLnfx4bxP1ZH6apNuaq39fqUnco9Cf/Uw0yJD1TmIsYatFngM6R1WnRuui45XHFHhsQeHYgsDYwg2EElZu6fpPbkyQdAOHaqN8yLoN6DpVDSFkJBGop9yfmdcqI8n0/CqHTY4nUMFuPCmcVMH/yc/4+tf3FBfPjrMjRRJ53pHsJ9UfpeYdCn0iqZdeeumlF7O6afkZMxk0jpUEmC+Riw1UGxnCxRRGUoG/sT+MJI7oAAFPImAkMcXMpZBrQFXmS5mRxGVGEh8sI4kBI6m0v1/t81f7+nl7RlKY7+vvLLeh3XvvPXmQcegQXfGSK+jyF78E5vsTLryQnnfp8ygJps99991HX/ryl8dzWVrXf/gjH145tY0P/A87Rj/2oz9Bl7/4csgE+7m/+Xp6+tOers7n85//PL3rj9/l8h21ymK+48oKrwzXGElMVSZY2SBy/YkXXfYiOnMzaTe3nH766fRdz/0u2NA8EoUn8D/M4Rp13XaMpJyvvCXHgkuMJLaMpPgQeQ4jiWPkCbs+mqqMJHPTUn01YiRZx8F6ziFGkuGvhOoujjotwOhhj86Bal8CbCRTQ1xEIFH0AS5eVX0YJTYSZiRRfG+09YVYPYaRxEVGUgCZMeccMZLyqUlGT9z2A0QXqH/trInZSAVGEjcykrYeS+wXI4mmMZIAGylmJJWbKyNGEk1lJBmSUY2RRIXTdvHYj524zEhCbKTM8eNKFgVjJzCG4oljqJOh9K1tvfTSSy+NxbpZRO5trVuDUsBKysiQNkZSuMY7h5Gk0D2YkeTYRiEjSbi3Qdc1Eydwb8vxGhlJZOJELm4yzkRG0totix0TILutSXbM4NpGjpGkXdJynMEtSzIIVnFWbmsktq6tj1DGkatqKo4og2ublWZj1zbhiqWYGBv3N+Fy9eErP0RfvvNOOvvszPI555xH01ve/Gv0X/7gP9N/+E/voBtuuIEuvPCJ9D3f/Qr64R/6q6utbbJtfOnLX6IPfuj9q/89uIP94X99J7308ivo0Y9+9NjEzj/vfHrrW/63FTj6t3/3t+iGG66jy573AnrtT/91uvS5l47W9qvzXTxIf/Lud9Ntt39GKfq8a9v6mu9trm8yTLDltj3odre3l13hwCySVfIpyLhYiV/sZRc2me8PBi57Sxe2Ia8ue8ELN2qg9W9+9nN/Tr/4xl+g66+/zkKHxteXXH4FveXNb6FHPerMceJvWYcXXPAEuu22T4s814ykBczzNLq22TzfHeKY1fHd0W1NM2zWbmt2CxmPrmouzq6II7YrjHFMnss4JLZyyM/LrRCLhXdXxAKAYKvagTCSrEsbcmuTn90vl7YaIwkrGWJGUrRVJxXc2pBLG8eea5MYSbB6gRsaYiRJNlLZPQ4zemQ/hHzjUTqlmYwke3nT6HYZutEphU2DSxu+3Nj1LWDbUNGljf7/9u4u1LI0r+/42jMVa+i5MGBLLtSbtJ3QtDjdYEKLCIGQIclF8MYYzEUYEq8VRGWCAcELrxJQRBNyMQQJeaFnhojRq6QztsbJqKOM9lQzNTUO2gURDQS1sauqZcl523u9PM9av2ftfarPzPl8sC3mVNWqvdd+zqla3/Ps/xrcjXN9RlLpbm3FA46+/q7dJW/DjKTiXdpWZiRV79I2/4wt3aVtdUbS9OvAyoyk2nv1qjOSVu/SFs5Iqn62ZHdpW71bW+0ubYV/XyEkAawaDTneTWYbLXzPppt813T6F1T7jKTxsIbtM5IGv7OfjTKZfye0MCOpmx5nltEmxzt6RlL3lGYkTZ56YUbS+DjTOQYLs15Gb+0PZ8Z00++UDX6cvC6jMFSZajN/CebfXVsbwl1c54P1/tr/eq177rnnDlGj687fvva9/+Sfnv+35MmTd7v//Wu/Ovju9MV5+PSnP929+slXu+/75983Ou7ZDprv+kffdf7fkgdf+mL3X179z/s1tgtnJE3Xeb86I6lbnpHUhTOSJut9bUbSd37n3+n+5jf/jdHPvfnmm93nPve5cdGaLOhPvf5a93tf/r19SLoIf3+t+45v/47zu7qVZyQlM41aZyR1hQOUZiT1leHZu/hOhodP7sNMmtoOu+5EM5KqG6yOmZE0GrIymbk0mJVU/DydPr3SMOTB+ZnP6GmbkTQOUOMZO93SbKTqjKR+NiNpf7zhLJeufL6XZiQtjKCqzEiaz/7Zn6+Fe6WNn155RtI+mg6+bpWPM5mRNCsfg1k9hedZm7lUDU+z8z9++LPnNzuB9RlJpeH05RlJhZlLKzOS+sE3rxZnJE2PNxnhUz7v83/eTP9htf/jpsfrx7Ok+m43+Xxan5G0D+DD44QzkuZdLpuR1DXMSBp+fSvORlqckXT10+Xh3NX9wNGMpMMTi3Z+F7+83d4ZSUISwIrq3YF284vypWHHu9W7/kzGS892NO2W79a2tgNp+i2V2Q6k6dPqS7988I3d2W3mJt9IH9/tafYPrZWdSKt3fZvuHJrdra1y16nZN7JrO5Amx9nV7l5VeH1KG0DW7vpWuYtV+W5tpbu+TXa4TRZoOox7/t7/0tX5eH0Og9N/+LmPdS+/9NL5cOuWf1idHe83P/uZ7t/9+39b3CH2Mz/7092d97+/+8g/+8hh9lHgD//w/3b/5if/dfflL3/58B3mbn7Xtunne7+bf8e/+g3K/fosHLU0N2V6gOHcjsJ6X7rjz9n/nd2Z7Wu/9q/uP/ro0TvdZ3/rNycXZOUdd5/9rc92H/rWl8+HbZ955pkPdn/r2/529x//08+tr/Na8O26hbu1Xf104fNlcre20o7I+l0JF9Z78S6Hu+oVwtJdieZfz0sPY7CTaLITaH4hslv9jntpZ9L6DqVaGCo/ru07lGpDhEvzj+Yze9buInb4cPXZVnYola/7ZrdhK26EKb7gxZ1A5S8Kg51JhR1KpWfd71bu7FXbklTdmbQr/XVZ34HVTbvf9K555cez/zHZoVTtU5O7pJU+rXe75R1Yk4VTumve6PFMdiaNP5/mIXRXHd58cZwf+eiPdbuPHj68K3w9qN7LrLhDafjwC2mmukOpPCNpFpwq52e68748I2kyRLuwQ2lX3aFU+nJV2qFU+nu2cHfcrvy40h1K1Z1J+x2XlR1KlblKt40ZSQANF7rTH4f/dfFMjumsmMKMpGAOR7cwKaNvnZHU1WYkdSeakbT0x0/nGfSrM2O64nSApdlIfXk2UjQjqVuekdRd74ykrjAjKd19cczMmPp6X7671dtvv939wA9+f/fff/EXukePH0WfW++++273K7/6evfRH/2X57+/q8xT+amf/snux3/ix7vf/4PfX30OZz//+Xuf7374oz/Uvf76L1fXe+k0nnJGUtc4I2l697flGUl998FnPti98sq3j97K98f/74+7X/vMp5dGhO0f62d+/f90f/In/3901Jc+9FL30re+XB8R1neV6RP1mWLzz5vC58umGUn9+nrv0nkWCzOSuumMpD782hzOSOrqI1TW5th1hRlJ4w2p4yEppRlJhzXXr5z5pRlJhZlLiyNXyl/VRzN6ZjOqusLfjf3KrKRuZf7ZdEZV29y/Lpr711VmJJV3M9bvtzqZIzSZkdQtzkjqKn+L9tGMpMNfzcOZRst/K09nJZX/ydAPZlT1K7OSFv60tRlJff28d0fOSHrnz9/p/vydd/Y/Ls9I6ttmJPV9dVZSt3We3HBGUt86I6kbf8Vfm5G08jCnf4OU/u20NCNpaVbS9O+UZM5kaUZSd+T8va9WdiQBhNK7NAzfulaekVTe8TGbkdRlM5Kqkxu2zEgaHae8I2A4M2Z5RtLKjqLprKXdrnYT78FMo2BG0mxn0uQ4kxlJ3YYZSRd3NruYKTTcYXF+Z7b+aobMYcfG2V2rzl7Hi1lJw+Nc3Dnq/DiDbdfnH+8Ps2iudmyc3VHqbF0djnOheJzdbvTxobOPnx9nPyvp4vjj4+xWjnNxHvbPa3CcJ+8+6f7Vj/1o9/O/8PPdP/7u7+le/tDL53dSu/uBD+xfinff/YvuT//sT7t7997oPv7JV89nHZ3N/Nl/57/viufzE5/4ePfaa//z/K5tH/57f7/7pm/8pu6ZZ57Zf/fw7T97u7v/xfvdJ//bJ7pXP/5fL87/+XkbHGd/R5f3zT43d5d3Q7t4Xo9H671017bu8m5rZ3/A2Yyj6Xea31e42+H+Tjb9eEbSxet+eZzB+qzdte3sbX4f/vCHL+ZMDfzO7/5O94UvvDmebTQ5n+c7Drqu+9Trn+ruP/hi93XPPrs/D88++2z3yiuvdJ9/8/OX6/zJaCfeeH0eZiTdHayT4efL3cvPl0eTdX71689nJQ12iJy/XmfHefR49HXw4k5uFzORhut8+PH952/fnd/N7fx1P3s8gy+g419/+A702Z3ZDr/+8DV59OdWd5R2xRlJpbfqnGZG0vDXzmck7TbPSNrVnlY4I2lyvNUZScO3vA13Tkx3xEx34M7PU3XHT9OMpPkWpfEGiKUZSaVZSZVnPd2hOL175PDvq9IOsNlOsNYZSbUZVbvJ+S+vud10y8nsee4WdiLt5n8fxzOqiv84i2YkDb/Gl2dUlR5XdYHXNigVZ3ct7jZLZiRN1mV9RtKusBExmJE0+7xdnpFU27FZ3WHdlT6fym9V65ZmJPXl3UWz41RHNFXu2lZ961t2PXBrr4tcGgIs++bnvqXvGt4a1C1+H6dtRtL6cdZmJK0dZ3rU4iikyl785T9w9WGU3uSfPJ7ar1g5n/XjVX5m4QGch5jBsONhWLm68O6moacUhkbHOfxBw1A1DUCzoHMZCMZh6GJ9LYWk+sevhg4PAtNVgGg4zjCcXa33cRhaO874fA7X+/l5m5zPrk+O83j0ql+d//OPD49TfL7j4wyXxeg4k9fl8HwP63zt8YzX1fh1GS6gpfOZHWd9fe7D0Chgfc1lGBofZxyGukoYOrx17e7dy8A0GX49DT1XJ+juBy4e56PLMHQITFfHGa/D4nGuPt4fhn1Hv34YnoJQ1PXd8lvVJglg8cJl9biFUNTyj/zJBX7xrW9NFw0Loejo49VCUX6+V4dzr5735T8wfzilKeMNL3vtV05O9MJs5Oh8F7pNt/DOveZnsHh6+y75gxrPf3ZClrNLvzSEp/H8t31G1M9/vmIWn+dkRtJ02Hvz8VbOz9rDLQenxd+w8vKsh6LkCU6vB85+vP+l371VbUVIAghD0mqWOVFomoWiYWeJQlElNK10mOVf0PjLG0NT+XilaZL1552FonrpagtX6w+gaZh2dLx+dherptVVGhp/hLah3Eeu95bf37zeyz9xI9b7ex5W139D83EqD3v+9JvL+NFfj/efX6XvuDf943o+W2P5QrnleM2danaBWX1c8ROsz0jaeqk5PNDCCJemdLByGuLwEV/3huGj/XK/HIgqI5Maz/ty+NhYNtdPx8Ywt/zbl8Nc/uiXw1z7+W8LH8mMpK3hqTgdvdv+9W1jqZw8qw0hvXj+g7uuRed/PiMpJSQBUAxJh+vFlru3LV0/LbwFLt5RtDtih9KxF+JHXjiHF9BP40I6+hOuPRR1g3vAtIeipfB0fCg6Zr3Pd+JloShfr1vKz1Nf78PjBOWt7fOmJRRtK0PzD4frvbTOq0O1t4TRUni6jn8u95PQtHkDwHoYyq+ct4Whtbu0dd22wFS5sDwuDBWCTtsGlfYwFBWo5eO1hLilnTAnC0MtO5pqYS7rNNvDUHv5Cx/9QvA4OjS1vRybwlDp4VdD04avbqUh3BtCUzkMrYe49fMfBp1gB1LtrXRtX97qd2kTkgAohqTmC+fNF8yT0FSdkXQNoanhyjzfMHJsILqmC+fmHRtHXDiv3fY8eBlPfeF8HW/V/Ipb78EKOm5n0oZ1/pTXe/NbPt/TsHrM581wnU/uYzn6PGgJFCvBaeNbOcqhaPM7t07w1rfxF6BoRlJL2InfKpU94ePCXGsWuY6dSMslqH1/SkMgag5Ywc+2vyDZn9a4wyYORCs7bOJwFQan63/r2/qMpLbuvG0HUimkN5el1eNt/j7B8l3aQkISACPP/fVv6WcXIkdfKG+ZkXTshXI5AW28vr72nUhfdW/leRpvfVu63fmmwLTlLWs3Zb03hqGb/ta3+paeMPA2LOjFT6djw9Cpgupxb3071Vs7ts1IWglPG0NRHJ7WrxSP3KFUvlIuDdXeFJ42j9DZuKMoCiEN4Wnpyn9LyArf+7NtRlL2lsGT7lCKXuBjwl9bCInfArdSmrJQFMyA2lXe+b91i+Ssy51+RtIxYb260+kEO5SO2ZlU2qEkJAEw8p7NSGp+y9sRb92pHq/hQjfcmZEf79i3vB371p36cUZDnUtDmp88Hl04X921bTQsuVsZhj08zuWF893Lu4kVhyWvDNUersuz4cRnP7YN4b76+GF9Xt0N7cnl49x0nO7yeZ0PC388WjbJUPDxcQpDpmdDr5eOc/j48DhXr+Py677xOIP1Prz72/CEZseZDGs/P059GHl9WHjDOi8cp7satj34mfHHD6/Lfoj148ejT/MP3L34fDkM4S7fbe1K6eOHu7D13eNH47sc1o9zdzJsfjcb8t1ypdE0IykIIEfNSBpciB89THthRtLxs5KOfetaEHbay1Hb5f7KFqvjdhRl3aIlzE0/vG1GUjYracuOsPxl2z4jaTHsNMxIanor3HJ3vZYZSbO3sG2MB6Mh2teyQ6l9ATS/Fa5y/NKMpPR4ty0k3XGJCBBmniAUXX1sOSLNQ9EhGPWX16H9vqWMmk5fOM4oGPWH/RL95R3TBz/OHkffFp7Gxyv8w2bwOIePZ/l4fdfXQtHVx/rl/TpXz7mfbX0Yn8+u/uHD759P3xk8ocNzPH9oow/3lw938OPgyLMXcvKh0cyY/fHG66AvL4T5cS7D0+Hx9A3rc77er/53P1mQfT9+mcoh8rDeu8I5Gj+u2jrvJit88P8Hr0s/PLWzBTL8ifFxusn+rekv36/32U90o/U53WfTT4+3m5y06Ym7Ok5feDyz4/Vd9UnvjzNetn3p86Xr58cr/Ib5500/O079N0z68OXv2v/+0ZqofL5UO/NwfU4+1/vSq7sW87vC58vga2ptGPfowmb85w6+Kl9cr/SXX2/73eg07fraBdPV1/N+clYqYWh6vMknaj88Xt/tv/72uzBYTY/XT16teEZS+XXuL/+i6Sd/gQ13gI37zOwJT/6U4df18S8f/bi/oCz8xNV5mv09UXq5+v2PpS9so/O9//HyaRavl6d/WUz/5/jx9KszkiqfV5Pz3ve1u7b1l+e/dt6new93xa/vu9m/E/p6CB0ep/anDc776PxPH0/lvB9+dT9+XPMF3g1/Y/HDo9A0eX7TcjE93uzv1fEJG53/oLBMj9dPPlB+y1o9NM3+XXN1nP15P3x9S4rb9OvkbrY/e3i8heW7fx3GX98O638lDPXlf8fPHl/hbm23lR1JACtaZyTd+pkx8yu90wzRvukzklZ3OjXOeqkOKT7urWvlMLr9rmunGqK9/a2apRPW/M6y0wzjXjgBp5oFtm29Ny//r/jh8y0zxUozkrZ9w74Sdr7iZySNdzaddkZS+bxn5z98q1r7dO3qn5I9jPITOG5GUjnM9Sd461v9rVLJ8bLT0fiCNJ7/tk/Yo96qFr2eR7xV7RQzkmbL8PQzkpZDenq8U+1EOuFb1Y6cueStbQAUQ9J1DCfeNuLjlBfewWVjdSj3scO4b+KMpOi9bpXn95QvvGed7dj1OVlfJw2hN2cmWPWjTaFp41s9jwpNx96VcOVnjgpNLWHohDPBtgzhnh5v0z+eryMUNc5IqgasI0PRKd76thSKTjGce6lLbAkpyTvcrns498nDU8sw58ZQFA9H3xiKtg/Bag9P/alC0cpd8651mHbbXe7aQtFpZiQdMy3+qOHc/WlD0fD4pZ1JQhIAxZC0el1y6hlJg51IW2Ylte+ouIYL56Nul176FumWHRrZlXbzDo/38ML5uB0ax4am0nrfvqMpWu9bQlO8QG7IMO3bNnx+FkKXdhC1h6ItX4/3n1+l77hvDk3hjKSWcLVlh0wlXG27OV19RtLWS83hgY4dxh2ehjh8xNe9J7972+zKtWXDTF4kV2f0HBmIVmdlN+5wqv727TOSWsJc+/m/OTOSWu5yl3w9OmZGUjzTKO52G++6tjA8uzU4CUkAFEPS4XrxuLu3Ha6fFt4S9B68dW3TW3mOugtVdgH9NC6koz/hhr+VZ3nHxrGh6Jj1ftq3wJXW65by89TXe3FnUvZs1z9vTvBWz+Zh9OF6r75Fc+Pd26pfNjbuTGq40hiHps0bANbD0Ka7tDWEoZPfpa0UPE4VhgpB56hh3M2nd3XLWfvN+pZ3elxLGDrmrm+lh33Kt741vQVuy6NfCB5Hh6a2l2NTGCo9/Gpo2vDVrTSEe0Noqr5lbSXErZ//MOgEO5BO8Ra4pdlIQhIAxZDUfOH8lTgjqeHKPN8wcmwguqYL5yNmJJ3fFavrF++2NvxjxncTC+/aNrlbVn95l6vDXdIajzP5+MVd0p6MQlHbcS7Ow9nzebK/y9XF4xze1St+PFfHGaz35butlR/P/q5bg/V+fv4nr8v8rnDl17d+d7PDQhk/zvLrsnqc2et+WO+l8zk8zugudZW72o2OMzif9eOMz+fsLoGVdX54vsO7tl0cZ3rXs9Hd3AYn6Hydnx3n0ePR18Gru6old227utta35fvWjg8ztXHL+7yNrlL3cJd3laD08a3cty8GUnjC8zTzkhqeatU9oSPC3OtWeQ6diItl6Dj7vq2EoiOuetb7WfbX5DsT2vcYRMHopUdNs13fVsJTtf/1rfTz0g6/V3awrK0erzN3yfYdJe22x6S3LUNYMV3v/wDTgLjvzz/yvvPf3z3yV/4uI/7+C39OABc+Ykv/Yvb9W9hLzkAtKldUPq4j/v47fk4ANxW73MKAAAAAEgISQAAAABEhCQAAAAAImYkAUDrX56GDfu4jxu2DQC31M4pAAAAACDhrW0AAAAARIQkAAAAACJCEgAAAAARw7YBoMHXf/039M4C3E5/9EcPzRcF4NazIwkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiO6cAAAAAgIQdSQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABA5I5TAABws/yDlz7SOwu31y/99sd21gPWA9YDrevhabEjCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiNy5qQ/sG7/hud7Lc3u99fDBznrAesB6oHU9AABwvexIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgMidm/rAXnj+Ra/OLfbWwwfWA9YD1gPN6wEAgOtlRxIAAAAAkRu7I+ne/Te8OlgPWA9YDwAAcIPYkQQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAACROzf1gb3w/ItenVvsrYcPrAesB6wHmtcDAADXy44kAAAAACI3dkfSvftveHWwHrAesB4AAOAGsSMJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIndu6gN74fkXvTq32FsPH1gPWA9YDzSvBwAArpcdSQAAAABEbuyOpHv33/DqYD1gPWA9AADADWJHEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAETu3NQH9sLzL3p1brG3Hj6wHrAesB5oXg8AAFwvO5IAAAAAiNzYHUn37r/h1cF6wHrAegAAgBvEjiQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACI3LmpD+yF51/06txibz18YD1gPWA90LweAAC4XnYkAQAAABC5sTuS7t1/w6uD9YD1gPUAAAA3iB1JAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAELlzUx/YC8+/6NW5xd56+MB6wHrAeqB5PQAAcL3sSAIAAAAgcmN3JN27/4ZXB+sB6wHrgVvp737bP3QSbrFf+u2PWQ9YD1gPNK+Hp8WOJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIjcuakP7IXnX/Tq3GJvPXxgPWA9YD3QvB6+WvyP3/hFLy7WA9YD1gM3kh1JAAAAAER2TgEAAAAACTuSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJ/Ce1QZS71HGJJAAAAAElFTkSuQmCC",pants="iVBORw0KGgoAAAANSUhEUgAABJIAAAReCAYAAACMxxrQAAEHPElEQVR42uy9S7Ms3XaelUtWSOfynXPC52Y1QJb3FkFY2rKOZCGZoAuS7xc1aBCELxI2xpKxjS3bkrnYf4AGEfwHfoE7BF0a0KVHGBqGNuGwuURgUcS+fLsyK+ec4x2XmVW56nnk433OWrtyZWXOqr3GU2O884cWAAAAAAAAAAAAgR/iEgAAAAAAAAAAgAIiCQAAAAAAAAAAJBBJAAAAAAAAAAAggUgCAAAAAAAAAAAJRBIAAAAAAAAAAEggkgAAAAAAAAAAQAKRBAAAAAAAAAAAEogkAAAAAAAAAACQQCQBAAAAAAAAAIAEIgkAAAAAAAAAACQQSQAAAAAAAAAAIIFIAgAAAAAAAAAACUQSAAAAAAAAAABIIJIAAAAAAAAAAEACkQQAAAAAAAAAABKIJAAAAAAAAAAAkEAkAQAAAAAAAACABCIJAAAAAAAAAAAkEEkAAAAAAAAAACCBSAIAAAAAAAAAAAlEEgAAAAAAAAAASCCSAAAAAAAAAABAApEEAAAAAAAAAAASiCQAAAAAAAAAAJBAJAEAAAAAAAAAgAQiCQAAAAAAAAAAJBBJAAAAAAAAAAAggUgCAAAAAAAAAAAJRBIAAAAAAAAAAEggkgAAAAAAAAAAQAKRBAAAAAAAAAAAEogkAAAAAAAAAACQQCQBAAAAAAAAAIAEIgkAAAAAAAAAACQQSQAAAAAAAAAAIIFIAgAAAAAAAAAACUQSAAAAAAAAAABIIJIAAAAAAAAAAEACkQQAAAAAAAAAABKIJAAAAAAAAAAAkEAkAQAAAAAAAACABCIJAAAAAAAAAAAkEEkAAAAAAAAAACCBSAIAAAAAAAAAAAlEEgAAAAAAAAAASCCSAAAAAAAAAABAApEEAAAAAAAAAAASiCQAAAAAAAAAAJBAJAEAAAAAAAAAgAQiCQAAAAAAAAAAJBBJAAAAAAAAAAAggUgCAAAAAAAAAAAJRBIAAAAAAAAAAEggkgAAAAAAAAAAQAKRBAAAAAAAAAAAEogkAAAAAAAAAACQQCQBAAAAAAAAAIAEIgkAAAAAAAAAACQQSQAAAAAAAAAAIIFIAgAAAAAAAAAACUQSAAAAAAAAAABIIJIAAAAAAAAAAEACkQQAAAAAAAAAABKIJAAAAAAAAAAAkEAkAQAAAAAAAACABCIJAAAAAAAAAAAkEEkAAAAAAAAAACCBSAIAAAAAAAAAAAlEEgAAAAAAAAAASCCSAAAAAAAAAABAApEEAAAAAAAAAAASiCQAAAAAAAAAAJBAJAEAAAAAAAAAgAQiCQAAAAAAAAAAJBBJAAAAAAAAAAAggUgCAAAAAAAAAAAJRBIAAAAAAAAAAEggkgAAAAAAAAAAQAKRBAAAAAAAAAAAEogkAAAAAAAAAACQQCQBAAAAAAAAAIAEIgkAAAAAAAAAACQQSQAAAAAAAAAAIIFIAgAAAAAAAAAACUQSAAAAAAAAAABIIJIAAAAAAAAAAEACkQQAAAAAAAAAABKIJAAAAAAAAAAAkEAkAQAAAAAAAACABCIJAAAAAAAAAAAkEEkAAAAAAAAAACCBSAIAAAAAAAAAAAlEEgAAAAAAAAAASCCSAAAAAAAAAABAApEEAAAAAAAAAAASiCQAAAAAAAAAAJBAJAEAAAAAAAAAgAQiCQAAAAAAAAAAJBBJAAAAAAAAAAAggUgCAAAAAAAAAAAJRBIAAAAAAAAAAEggkgAAAAAAAAAAQAKRBAAAAAAAAAAAEogkAAAAAAAAAACQQCQBAAAAAAAAAIAEIgkAAAAAAAAAACQQSQAAAAAAAAAAIIFIAgAAAAAAAAAACUQSAAAAAAAAAABIIJIAAAAAAAAAAEACkQQAAAAAAAAAABKIJAAAAAAAAAAAkEAkAQAAAAAAAACABCIJAAAAAAAAAAAkEEkAAAAAAAAAACCBSAIAAAAAAAAAAAlEEgAAAAAAAAAASCCSAAAAAAAAAABAApEEAAAAAAAAAAASiCQAAAAAAAAAAJBAJAEAAAAAAAAAgAQiCQAAAAAAAAAAJBBJAAAAAAAAAAAggUgCAAAAAAAAAAAJRBIAAAAAAAAAAEggkgAAAAAAAAAAQAKRBAAAAAAAAAAAEogkAAAAAAAAAACQQCQBAAAAAAAAAIAEIgkAAAAAAAAAACQQSQAAAAAAAAAAIIFIAgAAAAAAAAAACUQSAAAAAAAAAABIIJIAAAAAAAAAAEACkQQAAAAAAAAAABKIJAAAAAAAAAAAkEAkAQAAAAAAAACABCIJAAAAAAAAAAAkEEkAAAAAAAAAACCBSAIAAAAAAAAAAAlEEgAAAAAAAAAASCCSAAAAAAAAAABAApEEAAAAAAAAAAASiCQAAAAA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AACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCqNpwAAAACAGlYkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQA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5gTlbgfK7LrFuPOi93WURVi4muvSezeo7c6L5f9PTl5mnRflaOfF6hXqunFi4YzOi/s7UIZdcME8zBde1oEyf+fHe+ehd+JgWjyZW5/ErY+bhxrOQ33yebAf7Af74W33w8N+TnnWH6D+9MtfX71Hkw2//flX1TxgHjAPHJ2HV2GuzbV5wDxgHnjWn4P+zl89AAAAAAlBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAACRn571C/vPf/svjw7mAfOAecBcYx7MA+YB88ATcSIJAAAAgIggCQAAAICIIAkAAACAiCAJAAAAgIggCQAAAICIIAkAAACAiCAJAAAAgIggCQAAAICIIAkAAACASH3WL+xPv/x18vC8r9/+/KtqHjAPmAeOzsOrMNfm2jxgHjAPPOvPQU4kAQAAABARJAEAAAAQESQBAAAAEKn+CgAAAABIOJEEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEDkp2f9wn7z699NHp739ee//LGaB8wD5oGj8/AqzLW5Ng+YB8wDz/pzkBNJAAAAAESe9kTSv/7THzw6b+w//vufzQPmAfPA4Xl4FebaXJsHzAPmgWf9OciJJAAAAAAigiQAAAAAIoIkAAAAACKCJAAAAAAigiQAAAAAIoIkAAAAACKCJAAAAAAi9Vm/sN/8+neTh+d9/fkvf6zmAfOAeeDoPLwKc22uzQPmAfPAs/4c5EQSAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAkZ+e9Qv7/T/+u0fnjf3hf/7FPGAeMA8cnodXYa7NtXnAPGAeeNafg5xIAgAAACAiSAIAAAAgIkgCAAAAICJIAgAAACAiSAIAAAAgIkgCAAAAICJIAgAAACAiSAIAAAAgIkgCAAAAICJIAgAAACAiSAIAAAAgIkgCAAAAICJIAgAAACAiSAIAAAAgIkgCAAAAICJIAgAAACAiSAIAAAAgIkgCAAAAICJIAgAAACAiSAIAAAAgIkgCAAAAIFKf9Qv731/+b/LwvK9/+Pnvq3nAPGAeODoPr8Jcm2vzgHnAPPCsPwc5kQQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABApPorAAAAACDhRBIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAkf8Hqq70eWn3oFYAAAAASUVORK5CYII="}}

    function Engine:basketball_assets(character)
        character=character or "Sasuke"
        local data=assert(basketball_texture_data[character],"No authored textures for this character")
        if self.basketball_asset_cache and self.basketball_asset_cache[character] then return self.basketball_asset_cache[character] end
        local load_asset=type(getcustomasset)=="function" and getcustomasset or type(getsynasset)=="function" and getsynasset
        if not load_asset or type(writefile)~="function" then return nil,"Basketball textures need custom-asset and file support in this executor" end
        local alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; local values={}
        for i=1,#alphabet do values[alphabet:sub(i,i)]=i-1 end
        local function decode(encoded)
            local bytes={}; local number,bits=0,0
            for i=1,#encoded do
                local value=values[encoded:sub(i,i)]
                if value then
                    number=number*64+value; bits=bits+6
                    if bits>=8 then bits=bits-8; local divisor=2^bits; bytes[#bytes+1]=string.char(math.floor(number/divisor)%256); number=number%divisor end
                end
            end
            return table.concat(bytes)
        end
        local assets={}
        local ok,err=pcall(function()
            for _,name in ipairs({"shirt","pants"}) do
                local path="Pivot_"..character.."_Basketball_v3_"..name..".png"
                writefile(path,decode(data[name]))
                assets[name]=assert(load_asset(path),"Could not register "..name.." texture")
            end
        end)
        if not ok then return nil,"Basketball texture loading failed: "..tostring(err) end
        self.basketball_asset_cache=self.basketball_asset_cache or {}; self.basketball_asset_cache[character]=assets; return assets
    end

-- Local cosmetics. No gameplay remotes are used by these modules.
    local function cosmetic_color(value) return assert(Core.hex_color(value),"Enter a six-digit color such as #A8C8FF") end
    local function new_local(scope,class,parent)
        local object=Instance.new(class); object.Parent=parent; scope:defer(function() object:Destroy() end); return object
    end
    add("coverage_hud","Coverage number","Cosmetics","Local geometric estimate: 0% open, 100% covered. Uses defender distance and basket direction; not the game's official contest percentage",{start=function(scope)
        local board=new_local(scope,"BillboardGui",ctx.gui); board.Name="PivotCoverage"; board.Size=UDim2.fromOffset(148,72); board.StudsOffsetWorldSpace=Vector3.new(0,2.6,0); board.AlwaysOnTop=false; board.LightInfluence=0; board.MaxDistance=150
        local label=new_local(scope,"TextLabel",board); label.BackgroundTransparency=1; label.Font=Enum.Font.SourceSansSemibold; label.TextSize=27; label.TextStrokeTransparency=.45; label.Size=UDim2.new(1,0,.55,0); label.Text="--%"
        local caption=new_local(scope,"TextLabel",board); caption.Size=UDim2.new(1,0,.26,0); caption.Position=UDim2.fromScale(0,.55); caption.BackgroundTransparency=1; caption.Font=Enum.Font.SourceSansSemibold; caption.TextSize=15; caption.TextStrokeTransparency=.5; caption.Text="COVERAGE EST."
        local track=new_local(scope,"Frame",board); track.Position=UDim2.fromScale(.14,.88); track.Size=UDim2.fromScale(.72,.06); track.BackgroundColor3=Color3.fromRGB(35,38,45); track.BorderSizePixel=0
        local fill=new_local(scope,"Frame",track); fill.Size=UDim2.fromScale(0,1); fill.BorderSizePixel=0
        for _,object in ipairs({track,fill}) do local corner=new_local(scope,"UICorner",object); corner.CornerRadius=UDim.new(1,0) end
        return {board=board,label=label,caption=caption,track=track,fill=fill}
    end,step=function(_,state,s,dt)
        local source=rig(); local mine=root(); local head=source and (source:FindFirstChild("Head") or mine)
        if not mine or not head then state.board.Enabled=false; state.value=nil; return end
        if state.source~=source then state.value=nil; state.source=source end
        state.board.Adornee=head; state.board.Enabled=true; state.board.Size=UDim2.fromOffset(148*s.coverage_scale,72*s.coverage_scale); state.board.StudsOffsetWorldSpace=Vector3.new(0,s.coverage_height,0)
        local defenders={}; local team=source:GetAttribute("Team")
        for _,who in ipairs(players:GetPlayers()) do
            if who~=ctx.player then
                local other=rig(who); local point=root(who)
                local teammate=other and team and team~=0 and other:GetAttribute("Team")==team
                if other and point and not teammate then
                    local humanoid=other:FindFirstChildOfClass("Humanoid")
                    if not humanoid or humanoid.Health>0 then defenders[#defenders+1]=point.Position end
                end
            end
        end
        local rim=nearest_rim(mine.Position)
        local target=Core.coverage_estimate(mine.Position,rim and rim.Position,defenders,s.coverage_radius)
        state.value=state.value and state.value+(target-state.value)*(1-math.exp(-s.coverage_response*(dt or .05))) or target
        local value=math.floor(state.value+.5)
        state.label.Text=tostring(value).."%"; state.label.TextSize=27*s.coverage_scale; state.caption.TextSize=15*s.coverage_scale
        state.label.Visible=s.coverage_display~="Bar"; state.track.Visible=s.coverage_display~="Number"; state.fill.Size=UDim2.fromScale(state.value/100,1)
        state.caption.Text=(value<15 and "OPEN" or value<40 and "LIGHT" or value<70 and "CONTESTED" or "SMOTHERED").." · EST."
        state.label.TextColor3=value<25 and Color3.fromRGB(132,222,164) or value<60 and Color3.fromRGB(242,205,115) or Color3.fromRGB(240,133,133)
        state.caption.TextColor3=state.label.TextColor3; state.fill.BackgroundColor3=state.label.TextColor3
    end,interval=.05})
    local function material(name)
        local allowed={SmoothPlastic=true,Plastic=true,Neon=true,Metal=true,Wood=true,WoodPlanks=true,Concrete=true,Glass=true}
        assert(allowed[name],"Choose a supported material"); return Enum.Material[name]
    end
    add("crosshair","Custom crosshair","Cosmetics","Dot, cross or ring with size, spacing, thickness and color controls",{start=function(scope)
        local frame=new_local(scope,"Frame",ctx.gui); frame.Name="PivotCrosshair"; frame.AnchorPoint=Vector2.new(.5,.5); frame.Position=UDim2.fromScale(.5,.5); frame.BackgroundTransparency=1; frame.Size=UDim2.fromOffset(1,1)
        local parts={}; for i=1,4 do local part=Instance.new("Frame"); part.BorderSizePixel=0; part.Parent=frame; parts[i]=part end
        local ring=Instance.new("Frame"); ring.BackgroundTransparency=1; ring.AnchorPoint=Vector2.new(.5,.5); ring.Parent=frame
        local round=Instance.new("UICorner"); round.CornerRadius=UDim.new(1,0); round.Parent=ring
        local stroke=Instance.new("UIStroke"); stroke.Parent=ring
        local dot=Instance.new("Frame"); dot.AnchorPoint=Vector2.new(.5,.5); dot.BorderSizePixel=0; dot.Parent=frame
        local dot_round=Instance.new("UICorner"); dot_round.CornerRadius=UDim.new(1,0); dot_round.Parent=dot
        return {parts=parts,ring=ring,stroke=stroke,dot=dot}
    end,step=function(_,state,s)
        local color=cosmetic_color(s.crosshair_color); local size=s.crosshair_size; local thickness=s.crosshair_thickness; local gap=s.crosshair_gap
        local shape=s.crosshair_shape; assert(shape=="Dot" or shape=="Cross" or shape=="Ring","Unknown crosshair shape")
        state.dot.Visible=shape=="Dot"; state.dot.Size=UDim2.fromOffset(thickness*2,thickness*2); state.dot.BackgroundColor3=color; state.dot.BackgroundTransparency=1-s.crosshair_opacity
        state.ring.Visible=shape=="Ring"; state.ring.Size=UDim2.fromOffset(size*2,size*2); state.stroke.Color=color; state.stroke.Thickness=thickness; state.stroke.Transparency=1-s.crosshair_opacity
        for i,part in ipairs(state.parts) do
            part.Visible=shape=="Cross"; part.BackgroundColor3=color; part.BackgroundTransparency=1-s.crosshair_opacity; part.AnchorPoint=Vector2.new(.5,.5)
            local horizontal=i<=2; local sign=i%2==1 and -1 or 1
            part.Position=UDim2.fromOffset(horizontal and sign*(gap+size/2) or 0,horizontal and 0 or sign*(gap+size/2))
            part.Size=UDim2.fromOffset(horizontal and size or thickness,horizontal and thickness or size)
        end
    end,interval=.05})
    local function trail_module(id,title,ball)
        add(id,title,"Cosmetics","Local trail with adjustable color, lifetime, width and opacity",{start=function(scope)
            local state={items={}}; scope:defer(function() for _,entry in pairs(state.items) do for _,object in ipairs(entry) do object:Destroy() end end end); return state
        end,step=function(_,state,s)
            local prefix=ball and "ball_trail_" or "player_trail_"; local parts={}
            if ball then
                for _,item in ipairs(candidates("balls")) do parts[#parts+1]=item.object end
                local own=held_ball(rig()); if own then parts[#parts+1]=own end
            else local part=root(); if part then parts[1]=part end end
            local seen={}; local color=cosmetic_color(s[prefix.."color"])
            for _,part in ipairs(parts) do
                if not seen[part] then
                    seen[part]=true
                    local entry=state.items[part]
                    if not entry then
                        local a=Instance.new("Attachment"); a.Name="PivotTrailA"; a.Position=Vector3.new(-.25,0,0); a.Parent=part
                        local b=Instance.new("Attachment"); b.Name="PivotTrailB"; b.Position=Vector3.new(.25,0,0); b.Parent=part
                        local trail=Instance.new("Trail"); trail.Name="PivotTrail"; trail.Attachment0=a; trail.Attachment1=b; trail.FaceCamera=true; trail.MinLength=.03; trail.Parent=part
                        entry={a,b,trail}; state.items[part]=entry
                    end
                    local trail=entry[3]; trail.Color=ColorSequence.new(color); trail.Transparency=NumberSequence.new(1-s[prefix.."opacity"]); trail.Lifetime=s[prefix.."lifetime"]; trail.WidthScale=NumberSequence.new(s[prefix.."width"])
                end
            end
            for part,entry in pairs(state.items) do if not seen[part] then for _,object in ipairs(entry) do object:Destroy() end; state.items[part]=nil end end
        end,interval=.1})
    end
    trail_module("ball_trail","Ball trail",true)
    trail_module("player_trail","Player trail",false)
    add("ball_appearance","Ball appearance","Cosmetics","Local color/material override; Neon glow stays on the ball surface with a bloom halo",{start=function(scope)
        local state={glows={},stars={}}
        local bloom=Instance.new("BloomEffect"); bloom.Name="PivotBallBloom"; bloom.Enabled=false; bloom.Parent=lighting; state.bloom=bloom
        scope:defer(function() bloom:Destroy(); for _,glow in pairs(state.glows) do glow:Destroy() end; for _,stars in pairs(state.stars) do stars:Destroy() end end)
        return state
    end,step=function(scope,state,s)
        local color=cosmetic_color(s.ball_color)
        if s.ball_finish=="Holographic" or s.ball_finish=="Galaxy" then
            local t=os.clock()*(s.ball_finish=="Galaxy" and .4 or .8)
            color=Color3.fromRGB(155+65*math.sin(t),130+65*math.sin(t+2),200+50*math.sin(t+4))
        end
        local chosen=material(s.ball_material); local parts={}; local seen={}; local glowing=0
        for _,item in ipairs(candidates("balls")) do parts[#parts+1]=item.object end
        local own=held_ball(rig()); if own then parts[#parts+1]=own end
        for _,part in ipairs(parts) do
            if not seen[part] then
                seen[part]=true
                scope:set(part,"Color",color); scope:set(part,"Material",chosen); scope:set(part,"Reflectance",s.ball_reflectance)
                local stars=state.stars[part]
                if s.ball_finish=="Galaxy" and not stars then stars=Instance.new("Sparkles"); stars.Name="PivotGalaxyStars"; stars.Parent=part; state.stars[part]=stars end
                if stars then stars.Enabled=s.ball_finish=="Galaxy"; stars.SparkleColor=Color3.fromRGB(205,207,255) end
                if s.ball_remove_texture then
                    if part:IsA("MeshPart") then scope:set(part,"TextureID","") end
                    for _,object in ipairs(part:GetDescendants()) do
                        if object:IsA("SpecialMesh") then scope:set(object,"TextureId","")
                        elseif object:IsA("Decal") or object:IsA("Texture") then scope:set(object,"Transparency",1) end
                    end
                else
                    if part:IsA("MeshPart") then scope:restore(part,"TextureID") end
                    for _,object in ipairs(part:GetDescendants()) do
                        if object:IsA("SpecialMesh") then scope:restore(object,"TextureId")
                        elseif object:IsA("Decal") or object:IsA("Texture") then scope:restore(object,"Transparency") end
                    end
                end
                local glow=state.glows[part]
                local enabled=s.ball_glow and s.ball_material=="Neon"
                if enabled and not glow then
                    glow=Instance.new("Highlight"); glow.Name="PivotBallSurfaceGlow"; glow.Adornee=part; glow.DepthMode=Enum.HighlightDepthMode.Occluded; glow.Parent=part; state.glows[part]=glow
                end
                if glow then
                    glow.Enabled=enabled; glow.FillColor=color; glow.OutlineColor=color
                    glow.FillTransparency=1-s.ball_glow_strength; glow.OutlineTransparency=math.max(.15,1-s.ball_glow_strength)
                end
                if enabled then glowing=glowing+1 end
            end
        end
        for part,glow in pairs(state.glows) do if not seen[part] then glow:Destroy(); state.glows[part]=nil end end
        for part,stars in pairs(state.stars) do if not seen[part] then stars:Destroy(); state.stars[part]=nil end end
        state.bloom.Enabled=glowing>0; state.bloom.Intensity=s.ball_bloom; state.bloom.Size=18; state.bloom.Threshold=.9
    end,interval=.1})
    local function court_line_kind(object)
        local piece=tostring(object:GetAttribute("GymPiece") or ""):lower():gsub("[^%w]","")
        if piece:match("^threepoint") then return "three" end
        if piece:match("^freethrow") or piece:match("^outerlane") or piece:match("^lanemarks") then return "free" end
        if piece:match("^hashmarks") or piece:match("^baselinemarks") or piece:match("^halfcourtline") or piece:match("^restrictedarc") then return "other" end
        -- PB calls its visible three-point mesh Takeback, outside the Lines folder.
        if object.Name=="Takeback" and object:IsA("MeshPart") and tostring(object.MeshId):match("13593871788$") then return "three" end
        local text=""; local current=object
        for _=1,4 do
            if not current or current==workspace then break end
            text=text.." "..current.Name:lower():gsub("[^%w]",""); current=current.Parent
        end
        local name=object.Name:lower()
        if name=="shooter" or name:find("trigger",1,true) or name:find("zone",1,true) or name:find("sensor",1,true) then return nil end
        if text:find("threepoint",1,true) or text:find("3point",1,true) or text:find("threept",1,true) or text:find("3pt",1,true) then return "three" end
        if text:find("freethrow",1,true) or text:find("foulcircle",1,true) or text:find("ftline",1,true) then return "free" end
        if name:find("line",1,true) or name:find("arc",1,true) or name:find("circle",1,true) or name=="paint" or name=="key" then return "other" end
    end
    local function court_line_nodes(state)
        local groups={three={},free={},other={}}; local seen={}
        local function add(object)
            if seen[object] then return end
            local kind=court_line_kind(object)
            if kind and (object:IsA("BasePart") or object:IsA("Decal") or object:IsA("Texture") or object:IsA("ImageLabel") or object:IsA("Frame")) then
                seen[object]=true; groups[kind][#groups[kind]+1]=object
            end
        end
        for _,object in ipairs(state.lines) do add(object); for _,child in ipairs(object:GetDescendants()) do add(child) end end
        for _,surface in ipairs(state.surfaces) do for _,object in ipairs(surface:GetDescendants()) do add(object) end end
        return groups
    end
    local function paint_court_line(scope,object,color,enabled)
        local property=object:IsA("BasePart") and "Color" or (object:IsA("Decal") or object:IsA("Texture")) and "Color3" or object:IsA("ImageLabel") and "ImageColor3" or "BackgroundColor3"
        if enabled then scope:set(object,property,color) else scope:restore(object,property) end
        if object:IsA("Decal") or object:IsA("Texture") then scope:restore(object,"Transparency") end
    end
    local function marking_anchors(state)
        local rims,free={},{}; local seen={}; local roots={}
        for _,name in ipairs({"Map","Courts","Court","Hoops"}) do local object=workspace:FindFirstChild(name); if object then roots[#roots+1]=object end end
        for _,folder in ipairs(roots) do
            for _,object in ipairs(folder:GetDescendants()) do
                if object:IsA("BasePart") and not seen[object] then
                    seen[object]=true
                    if object.Name=="Rim" then
                        local duplicate=false
                        for _,prior in ipairs(rims) do if (prior.Position-object.Position).Magnitude<1 then duplicate=true; break end end
                        if not duplicate then rims[#rims+1]=object end
                    elseif object.Name:lower()=="shooter" and object.Parent and object.Parent.Name:lower():gsub("[^%w]",""):find("freethrow",1,true) then free[#free+1]=object end
                end
            end
        end
        local anchors={}
        for _,rim in ipairs(rims) do
            local floor,y
            for _,surface in ipairs(state.surfaces) do
                if surface.Parent then
                    local point=surface.CFrame:PointToObjectSpace(rim.Position); local top=surface.Position.Y+surface.Size.Y/2; local height=rim.Position.Y-top
                    if math.abs(point.X)<=surface.Size.X/2+6 and math.abs(point.Z)<=surface.Size.Z/2+6 and height>=2 and height<=30 then floor=surface; y=top+.035; break end
                end
            end
            if floor then
                local center=Vector3.new(rim.Position.X,y,rim.Position.Z); local marker,distance
                for _,object in ipairs(free) do
                    local d=Vector3.new(object.Position.X-center.X,0,object.Position.Z-center.Z).Magnitude
                    if d>5 and d<35 and (not distance or d<distance) then marker=object; distance=d end
                end
                local toward
                if marker then toward=Vector3.new(marker.Position.X-center.X,0,marker.Position.Z-center.Z)
                else
                    local other,best
                    for _,object in ipairs(rims) do
                        local d=(object.Position-rim.Position).Magnitude
                        if object~=rim and d>30 and (not best or d<best) then other=object; best=d end
                    end
                    toward=other and Vector3.new(other.Position.X-center.X,0,other.Position.Z-center.Z) or Vector3.new(floor.Position.X-center.X,0,floor.Position.Z-center.Z)
                end
                if toward.Magnitude>.1 then
                    local forward=toward.Unit
                    -- Shooter markers can be off-center. Prefer the floor's court axis
                    -- when it agrees with the hoop direction, avoiding a skewed arc.
                    local best,best_dot
                    for _,axis in ipairs({floor.CFrame.RightVector,floor.CFrame.LookVector}) do
                        local flat=Vector3.new(axis.X,0,axis.Z)
                        if flat.Magnitude>.1 then
                            flat=flat.Unit; local dot=flat:Dot(forward)
                            if not best_dot or math.abs(dot)>best_dot then best=flat*(dot<0 and -1 or 1); best_dot=math.abs(dot) end
                        end
                    end
                    if best and best_dot>.98 then forward=best end
                    anchors[#anchors+1]={center=center,forward=forward,free_distance=marker and math.abs(toward:Dot(forward)) or nil}
                    if #anchors>=8 then break end
                end
            end
        end
        return anchors
    end
    local function update_court_markings(scope,state,s)
        local groups=court_line_nodes(state)
        for kind,objects in pairs(groups) do
            local enabled=s.court_color_lines and (kind=="three" and s.court_three_enabled or kind=="free" and s.court_free_enabled or kind=="other")
            local color=cosmetic_color(kind=="three" and s.court_three_color or kind=="free" and s.court_free_color or s.court_line_color)
            for _,object in ipairs(objects) do paint_court_line(scope,object,color,enabled) end
        end
        local three=not s.court_native_lines and s.court_color_lines and s.court_three_enabled and s.court_rebuild_markings and #groups.three==0
        local free=not s.court_native_lines and s.court_color_lines and s.court_free_enabled and s.court_rebuild_markings and #groups.free==0
        local anchors=(three or free) and marking_anchors(state) or {}
        for _,anchor in ipairs(anchors) do
            local angle=math.rad(s.court_marking_rotation or 0); local f=anchor.forward
            anchor.forward=Vector3.new(f.X*math.cos(angle)-f.Z*math.sin(angle),0,f.X*math.sin(angle)+f.Z*math.cos(angle))
            local right=Vector3.new(-anchor.forward.Z,0,anchor.forward.X)
            anchor.center=anchor.center+anchor.forward*(s.court_marking_forward or 0)+right*(s.court_marking_side or 0)
        end
        state.marking_anchors=anchors
        local signature=table.concat({tostring(three),tostring(free),s.court_three_radius,s.court_three_angle,s.court_free_radius,s.court_free_distance,s.court_corner_depth,s.court_line_width,s.court_marking_forward or 0,s.court_marking_side or 0,s.court_marking_rotation or 0},"/")
        for _,anchor in ipairs(anchors) do signature=signature..string.format("/%.2f/%.2f/%.2f/%.2f/%.2f/%.2f",anchor.center.X,anchor.center.Y,anchor.center.Z,anchor.forward.X,anchor.forward.Z,anchor.free_distance or 0) end
        if signature~=state.marking_signature then
            state.marking_signature=signature
            if not state.marking_folder then state.marking_folder=new_local(scope,"Folder",workspace); state.marking_folder.Name="PivotCourtMarkings" end
            for _,object in ipairs(state.marking_folder:GetChildren()) do object:Destroy() end
            state.marking_parts={}
            local function draw(a,b,kind)
                local midpoint=(a+b)/2; local inside=false
                for _,surface in ipairs(state.surfaces) do
                    local point=surface.CFrame:PointToObjectSpace(midpoint)
                    if math.abs(point.X)<=surface.Size.X/2+.1 and math.abs(point.Z)<=surface.Size.Z/2+.1 then inside=true; break end
                end
                local length=(b-a).Magnitude
                if not inside or length<.001 then return end
                local part=Instance.new("Part"); part.Name=kind=="three" and "ThreePointLine" or "FreeThrowLine"
                part.Anchored=true; part.CanCollide=false; part.CanTouch=false; part.CanQuery=false; part.CastShadow=false; part.Material=Enum.Material.SmoothPlastic
                part.Size=Vector3.new(s.court_line_width,.025,length+.015); part.CFrame=CFrame.new(midpoint,b); part.Parent=state.marking_folder
                state.marking_parts[#state.marking_parts+1]={object=part,kind=kind}
            end
            for _,anchor in ipairs(anchors) do
                local center=anchor.center; local forward=anchor.forward; local right=Vector3.new(-forward.Z,0,forward.X)
                if three then
                    local radius=s.court_three_radius; local angle=math.rad(s.court_three_angle/2); local previous
                    for i=0,64 do
                        local theta=-angle+2*angle*i/64
                        local point=center+forward*(math.cos(theta)*radius)+right*(math.sin(theta)*radius)
                        if previous then draw(previous,point,"three") end; previous=point
                    end
                    for _,sign in ipairs({-1,1}) do
                        local edge=right*(sign*math.sin(angle)*radius)
                        draw(center+forward*(math.cos(angle)*radius)+edge,center-forward*s.court_corner_depth+edge,"three")
                    end
                end
                if free then
                    local ft=center+forward*(anchor.free_distance or s.court_free_distance)
                    local previous
                    for i=0,48 do
                        local theta=2*math.pi*i/48; local point=ft+forward*(math.cos(theta)*s.court_free_radius)+right*(math.sin(theta)*s.court_free_radius)
                        if previous then draw(previous,point,"free") end; previous=point
                    end
                    draw(ft-right*s.court_free_radius,ft+right*s.court_free_radius,"free")
                end
            end
        end
        for _,entry in ipairs(state.marking_parts or {}) do entry.object.Color=cosmetic_color(entry.kind=="three" and s.court_three_color or s.court_free_color) end
        state.marking_summary=s.court_native_lines and "Original court artwork preserved / no replacement arcs" or "Native markings: "..#groups.three.." three-point / "..#groups.free.." free-throw; "..#(state.marking_parts or {}).." replacement segments"
    end

    local function named_court_parts(s)
        local surfaces,lines={},{}
        local roots={}; for _,name in ipairs({"Map","Courts","Court"}) do local object=workspace:FindFirstChild(name); if object then roots[#roots+1]=object end end
        local seen={}
        for _,folder in ipairs(roots) do
            for _,part in ipairs(folder:GetDescendants()) do
                if part:IsA("BasePart") and not seen[part] and part.Transparency<.95 then
                    seen[part]=true; local name=part.Name:lower(); local parent=part.Parent; local in_court=false
                    while parent and parent~=workspace do if parent.Name:lower():find("court",1,true) then in_court=true; break end; parent=parent.Parent end
                    local selected=s.court_part_name~="" and part.Name:lower()==s.court_part_name:lower()
                    local line_kind=court_line_kind(part)
                    local piece=tostring(part:GetAttribute("GymPiece") or ""):lower()
                    local gym_floor=piece:match("^insidezone") or piece:match("^paintzone") or piece:match("^outerzone")
                    if in_court and line_kind then lines[#lines+1]=part
                    elseif selected or gym_floor or name=="courtfloor" or name=="courtsurface" or name=="playingsurface" or (name=="floor" and in_court) then surfaces[#surfaces+1]=part end
                end
            end
        end
        return surfaces,lines
    end
    local function floor_under_player()
        local origin=assert(root(),"Enter a court first").Position+Vector3.new(0,3,0)
        local excluded={}
        for _,name in ipairs({"Characters","Basketballs","Hoops","Assets","PivotCosmeticModel","PivotCharacterVisuals"}) do local object=workspace:FindFirstChild(name); if object then excluded[#excluded+1]=object end end
        if ctx.player.Character then excluded[#excluded+1]=ctx.player.Character end
        local params=RaycastParams.new(); params.FilterType=Enum.RaycastFilterType.Exclude; params.IgnoreWater=true
        local hit
        for _=1,12 do
            params.FilterDescendantsInstances=excluded
            hit=workspace:Raycast(origin,Vector3.new(0,-80,0),params)
            if not hit then break end
            local part=hit.Instance
            if part and part:IsA("BasePart") and part.Transparency<.95 and hit.Normal.Y>.8 and not court_line_kind(part) then break end
            excluded[#excluded+1]=part; hit=nil
        end
        local floor=hit and hit.Instance
        assert(floor and floor:IsA("BasePart"),"No visible floor beneath you; stand on the court and enable again")
        local surfaces,lines={floor},{}; local seen={[floor]=true}
        local container=floor.Parent
        local parent=container
        while parent and parent~=workspace do
            if parent.Name:lower():match("^court%d*$") then container=parent; break end
            parent=parent.Parent
        end
        local top=floor.Position.Y+floor.Size.Y/2
        if container and container~=workspace then
            for _,part in ipairs(container:GetDescendants()) do
                if part:IsA("BasePart") and not seen[part] and part.Transparency<.95 then
                    local size=part.Size; local distance=(part.Position-floor.Position).Magnitude
                    local same_plane=math.abs((part.Position.Y+size.Y/2)-top)<=.6
                    local horizontal=math.abs(part.CFrame.UpVector.Y)>.9
                    if distance<=140 and same_plane and horizontal then
                        local name=part.Name:lower()
                        if court_line_kind(part) then lines[#lines+1]=part
                        elseif size.X>=4 and size.Z>=4 and size.Y<=4 then surfaces[#surfaces+1]=part end
                    end
                end
            end
        end
        return surfaces,lines
    end
    local function choose_court(s)
        if Engine.court_selection then
            local valid=true; for _,part in ipairs(Engine.court_selection.surfaces) do if not part.Parent then valid=false; break end end
            if valid then return Engine.court_selection.surfaces,Engine.court_selection.lines end
            Engine.court_selection=nil
        end
        local surfaces,lines=named_court_parts(s)
        if #surfaces==0 then return floor_under_player() end
        return surfaces,lines
    end
    function Engine:select_court_under_player()
        local surfaces,lines=floor_under_player()
        self.court_selection={surfaces=surfaces,lines=lines}
        local active=registry.active.court_appearance
        if active then registry:disable("court_appearance"); local ok,err=registry:enable("court_appearance",self.settings); assert(ok,err) end
        ctx.report("Selected court floor: "..surfaces[1]:GetFullName())
    end
    local function apply_court(scope,state,s)
        if state.selector~=s.court_part_name then
            Engine.court_selection=nil; state.surfaces,state.lines=choose_court(s); state.selector=s.court_part_name
        end
        local color=cosmetic_color(s.court_color); local line_color=cosmetic_color(s.court_line_color); local chosen=material(s.court_material)
        local remove_texture=s.court_remove_texture and not s.court_native_lines
        for object in pairs(state.appearances) do if not remove_texture then scope:restore(object,"Parent") end end
        for _,part in ipairs(state.surfaces) do
            if part.Parent then
                scope:set(part,"Color",color)
                if s.court_native_lines then
                    -- MaterialVariant artwork depends on its original base material.
                    -- Restoring only the variant/texture can still erase painted lines.
                    scope:restore(part,"Material"); scope:restore(part,"Reflectance")
                else scope:set(part,"Material",chosen); scope:set(part,"Reflectance",s.court_reflectance) end
                if remove_texture then
                    scope:set(part,"MaterialVariant","")
                    if part:IsA("MeshPart") then pcall(function() scope:set(part,"TextureID","") end) end
                else
                    scope:restore(part,"MaterialVariant")
                    if part:IsA("MeshPart") then scope:restore(part,"TextureID") end
                end
                for _,object in ipairs(part:GetDescendants()) do
                    if object:IsA("SurfaceAppearance") then
                        if remove_texture then state.appearances[object]=true; scope:set(object,"Parent",nil) end
                    elseif object:IsA("Texture") or object:IsA("Decal") then
                        if remove_texture then scope:set(object,"Transparency",1) else scope:restore(object,"Transparency") end
                    elseif object:IsA("SpecialMesh") then
                        if remove_texture then scope:set(object,"TextureId","") else scope:restore(object,"TextureId") end
                    end
                end
            end
        end
        update_court_markings(scope,state,s)
    end
    add("court_appearance","Court appearance","Cosmetics","Separate three-point/free-throw colors. Baked markings use adjustable local replacements; align them under Marking alignment.",{start=function(scope,s)
        local surfaces,lines=choose_court(s)
        local state={surfaces=surfaces,lines=lines,selector=s.court_part_name,appearances={}}
        apply_court(scope,state,s); ctx.report("Court appearance: "..#surfaces.." floor surfaces / "..#lines.." separate line parts")
        return state
    end,step=apply_court,interval=.5})
    add("self_outline","Player outline","Cosmetics","Outline and optional fill around your local character",{start=function(scope)
        character(); return new_local(scope,"Highlight",workspace)
    end,step=function(_,object,s)
        object.Adornee=rig(); object.OutlineColor=cosmetic_color(s.outline_color); object.FillColor=cosmetic_color(s.outline_fill_color); object.OutlineTransparency=1-s.outline_opacity; object.FillTransparency=1-s.outline_fill_opacity
        object.DepthMode=s.outline_through_walls and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
    end,interval=.1})
    add("sky","Custom sky","Cosmetics","Galaxy, night, sunset, daytime or a custom sky asset; tint and atmosphere controls",{start=function(scope,s)
        local source
        for _,object in ipairs(lighting:GetChildren()) do if object:IsA("Sky") then source=object; break end end
        local sky
        if s.sky_preset=="Galaxy" or s.sky_preset=="Custom" then
            local asset=s.sky_preset=="Galaxy" and "10542194896" or s.sky_asset
            asset=tostring(asset):match("^%s*(%d+)%s*$"); assert(asset and #asset<=18,"Enter a numeric sky model asset ID")
            local objects=game:GetObjects("rbxassetid://"..asset)
            for _,object in ipairs(objects) do
                if not sky then
                    local found=object:IsA("Sky") and object or object:FindFirstChildWhichIsA("Sky",true)
                    if found then sky=found:Clone() end
                end
                object:Destroy()
            end
            assert(sky,"Asset contains no Sky object")
        else sky=source and source:Clone() or Instance.new("Sky") end
        for _,child in ipairs(sky:GetChildren()) do child:Destroy() end
        sky.Name="PivotSky"
        for _,object in ipairs(lighting:GetChildren()) do if object:IsA("Sky") or object:IsA("Atmosphere") then scope:set(object,"Parent",nil) end end
        sky.Parent=lighting; scope:defer(function() sky:Destroy() end)
        local atmosphere=new_local(scope,"Atmosphere",lighting); atmosphere.Name="PivotAtmosphere"
        return {sky=sky,atmosphere=atmosphere}
    end,step=function(scope,state,s)
        local preset=s.sky_preset; assert(preset=="Night" or preset=="Sunset" or preset=="Day" or preset=="Galaxy" or preset=="Custom","Unknown sky preset")
        scope:set(lighting,"ClockTime",(preset=="Night" or preset=="Galaxy" or preset=="Custom") and 0 or preset=="Sunset" and 18.2 or 13)
        scope:set(lighting,"Ambient",cosmetic_color(s.sky_tint)); scope:set(lighting,"OutdoorAmbient",cosmetic_color(s.sky_tint))
        state.sky.CelestialBodiesShown=true; state.sky.StarCount=s.sky_stars; state.sky.SunAngularSize=12; state.sky.MoonAngularSize=9
        state.atmosphere.Color=cosmetic_color(s.sky_tint); state.atmosphere.Decay=cosmetic_color(s.sky_decay); state.atmosphere.Density=s.sky_density; state.atmosphere.Haze=s.sky_haze; state.atmosphere.Glare=preset=="Sunset" and .4 or 0
    end,interval=.2,conflicts={"time","fullbright","atmosphere"}})
    for _,id in ipairs({"time","fullbright","atmosphere"}) do
        local definition=registry.definitions[id]; definition.conflicts=definition.conflicts or {}; definition.conflicts[#definition.conflicts+1]="sky"
    end
    Engine.characters={
        {name="Tung Tung",asset="138151705692565"},{name="Sasuke",asset="12070631248"},
        {name="Gojo",asset="81832554167933"},{name="Naruto",asset="120654451966123"},{name="Itachi",asset="8297138758"},
        {name="Sukuna",asset="98979275032934"},{name="Goku",asset="1467391816"},{name="Luffy",asset="15350196603"},
        {name="Saitama",asset="74043844094306"},{name="Sonic",asset="96290299914524"},{name="Shadow",asset="8301293499"},
        {name="Spider-Man",asset="93697227789268"},{name="SpongeBob",asset="9727402003"},{name="Shrek",asset="5191546948"},
        {name="LeBron",asset="14515350167"},{name="Michael Jordan",asset="11456119979"},{name="Custom",asset=false}
    }
    local model_presets={}
    for _,entry in ipairs(Engine.characters) do model_presets[entry.name]=entry.asset end
    Engine.settings.model_outfit=""; Engine.settings.model_username=""
    function Engine:validate_character_reference(source,reference)
        assert(source=="Model" or source=="Outfit" or source=="Avatar","Unknown character source")
        reference=tostring(reference or ""):match("^%s*(.-)%s*$")
        if source=="Avatar" then
            assert(#reference>=1 and #reference<=21 and reference:match("^@?[%w_]+$"),"Enter a Roblox username or numeric user ID")
        else
            assert(reference:match("^%d+$") and #reference<=18 and reference:find("[1-9]"),source=="Outfit" and "Enter a positive numeric outfit ID" or "Enter a positive numeric Roblox model ID")
        end
        return reference
    end
    function Engine:source_cache_key(source,reference)
        return source=="Model" and reference or source:lower()..":"..reference:lower()
    end
    function Engine:character_reference(settings,name)
        settings=settings or self.settings; name=name or settings.model_preset
        if name=="Outfit" then return "Outfit",self:validate_character_reference("Outfit",settings.model_outfit)
        elseif name=="Avatar" then return "Avatar",self:validate_character_reference("Avatar",settings.model_username)
        else return "Model",self:validate_character_reference("Model",model_presets[name] or settings.model_asset) end
    end
    function Engine:source_objects(source,reference)
        reference=self:validate_character_reference(source,reference)
        if source=="Model" then return self:model_objects(reference) end
        local key=self:source_cache_key(source,reference); local cached=self.model_cache and self.model_cache[key]
        if cached then local copies={}; for _,object in ipairs(cached) do copies[#copies+1]=object:Clone() end; return copies end
        local service=ctx.players; local description
        local ok,err=pcall(function()
            if source=="Outfit" then
                local id=assert(Core.bounded(reference,1,9007199254740991),"Outfit ID is out of range")
                assert(type(service.GetHumanoidDescriptionFromOutfitIdAsync)=="function","Outfit import is unavailable in this client")
                description=service:GetHumanoidDescriptionFromOutfitIdAsync(id)
            else
                local user_id
                if reference:sub(1,1)~="@" and reference:match("^%d+$") then user_id=Core.bounded(reference,1,9007199254740991); assert(user_id,"User ID is out of range")
                else
                    assert(type(service.GetUserIdFromNameAsync)=="function","Username lookup is unavailable in this client")
                    user_id=service:GetUserIdFromNameAsync(reference:gsub("^@",""))
                end
                assert(type(service.GetHumanoidDescriptionFromUserIdAsync)=="function","Avatar import is unavailable in this client")
                description=service:GetHumanoidDescriptionFromUserIdAsync(user_id)
            end
        end)
        assert(ok,source.." lookup failed: "..tostring(err))
        assert(description,"Roblox returned no appearance for this source")
        local created,model=pcall(function()
            assert(type(service.CreateHumanoidModelFromDescriptionAsync)=="function","Avatar model creation is unavailable in this client")
            return service:CreateHumanoidModelFromDescriptionAsync(description,Enum.HumanoidRigType.R15)
        end)
        pcall(function() description:Destroy() end)
        assert(created,source.." model could not be created: "..tostring(model))
        assert(model and model:IsA("Model") and not model:IsDescendantOf(workspace),"Avatar import must return a detached model")
        return {model}
    end
    function Engine:selected_character_objects(name)
        local source,reference=self:character_reference(self.settings,name)
        return self:source_objects(source,reference)
    end

    Engine.model_library={version=1,models={}}
    Engine.model_cache={}; Engine.model_preload={busy=false,done=0,total=0,failed=0}
    local library_defaults={}
    library_defaults.model_outfit=Engine.settings.model_outfit; library_defaults.model_username=Engine.settings.model_username
    for _,key in ipairs({"model_style","model_fit_pb","model_fit_scale","model_accessory_scale","model_height","model_offset","model_rotation","model_follow_pose","model_motion","model_hide_avatar","model_high_detail","model_headless","model_show_hair","model_show_hats","model_show_masks","model_show_capes","model_show_weapons","model_show_extras"}) do library_defaults[key]=Engine.settings[key] end
    function Engine:validate_model_library(data)
        if type(data)~="table" or data.version~=1 or type(data.models)~="table" then return nil,"Invalid model library" end
        local result={version=1,models={}}; local names={}; local count=0
        for key in pairs(data.models) do if type(key)~="number" or key%1~=0 or key<1 then return nil,"Model list must be an array" end; count=count+1 end
        if count>32 then return nil,"Library supports up to 32 saved models" end
        for i=1,count do
            local item=data.models[i]
            if type(item)~="table" or type(item.name)~="string" or #item.name<1 or #item.name>40 or item.name:find("[%c]") or names[item.name:lower()] then return nil,"Invalid or duplicate model name" end
            local source=item.source or "Model"
            if type(item.asset)~="string" then return nil,"Invalid character reference" end
            local ok,reference=pcall(self.validate_character_reference,self,source,item.asset); if not ok then return nil,tostring(reference) end
            local settings,err=Core.validate_module_settings(item.settings or {},library_defaults,self.ranges)
            if not settings then return nil,err end
            if settings.model_style~="Basketball" and settings.model_style~="Original costume" then return nil,"Invalid costume style" end
            local preset=source=="Avatar" and "Avatar" or source=="Outfit" and "Outfit" or "Custom"
            if source=="Model" and type(item.preset)=="string" and model_presets[item.preset]==reference then preset=item.preset end
            names[item.name:lower()]=true; result.models[i]={name=item.name,source=source,asset=reference,preset=preset,settings=settings}
        end
        return result
    end
    function Engine:save_model_library()
        assert(type(writefile)=="function","File saving unavailable; library is kept for this session")
        local data,err=self:validate_model_library(self.model_library); assert(data,err)
        writefile("pivot_models.json",game:GetService("HttpService"):JSONEncode(data)); return true
    end
    function Engine:read_model_library()
        assert(type(readfile)=="function","File loading unavailable")
        local raw=readfile("pivot_models.json"); assert(type(raw)=="string" and #raw<=131072,"Library exceeds 128 KB")
        local value,err=self:validate_model_library(game:GetService("HttpService"):JSONDecode(raw)); assert(value,err)
        self.model_library=value; self:prune_model_cache(); return #value.models
    end
    function Engine:save_current_model(name)
        name=tostring(name or ""):match("^%s*(.-)%s*$"); if name=="" then name=self.settings.model_preset end
        local source,reference=self:character_reference()
        local item={name=name,preset=self.settings.model_preset,source=source,asset=reference,settings={}}
        for key in pairs(library_defaults) do item.settings[key]=self.settings[key] end
        local next_library={version=1,models={}}; local replaced=false
        for i,old in ipairs(self.model_library.models) do if old.name:lower()==name:lower() then next_library.models[i]=item; replaced=true else next_library.models[i]=old end end
        if not replaced then next_library.models[#next_library.models+1]=item end
        local valid,err=self:validate_model_library(next_library); assert(valid,err); self.model_library=valid; self:prune_model_cache()
        local ok=pcall(function() self:save_model_library() end)
        ctx.report(ok and "Saved model: "..name or "Saved model for this session: "..name.." / file saving unavailable")
        return true
    end
    function Engine:equip_saved_model(index)
        local valid,err=self:validate_model_library(self.model_library); assert(valid,err)
        local item=assert(valid.models[index],"Saved model not found")
        local previous={}; for key in pairs(library_defaults) do previous[key]=self.settings[key] end
        previous.model_preset=self.settings.model_preset; previous.model_asset=self.settings.model_asset
        local was_active=registry.active.custom_model~=nil; registry:disable("custom_model")
        for key,value in pairs(item.settings) do self.settings[key]=value end
        self.settings.model_preset=item.preset; self.settings.model_asset=item.asset
        if item.source=="Outfit" then self.settings.model_outfit=item.asset elseif item.source=="Avatar" then self.settings.model_username=item.asset end
        local ok,failure=registry:enable("custom_model",self.settings)
        if not ok then for key,value in pairs(previous) do self.settings[key]=value end; if was_active then registry:enable("custom_model",self.settings) end; error(failure) end
        self.settings.model_save_name=item.name; ctx.report("Equipped "..item.name); return true
    end
    function Engine:remove_saved_model(index)
        assert(self.model_library.models[index],"Saved model not found"); table.remove(self.model_library.models,index)
        self:prune_model_cache(); local ok=pcall(function() self:save_model_library() end); ctx.report(ok and "Removed saved model" or "Removed saved model for this session")
    end
    function Engine:model_objects(asset)
        local cached=self.model_cache[asset]
        if cached then local copies={}; for _,object in ipairs(cached) do copies[#copies+1]=object:Clone() end; return copies end
        return game:GetObjects("rbxassetid://"..asset)
    end
    function Engine:clear_model_cache()
        for _,objects in pairs(self.model_cache) do for _,object in ipairs(objects) do object:Destroy() end end; self.model_cache={}
    end
    function Engine:prune_model_cache()
        local keep={}; for _,item in ipairs(self.model_library.models) do keep[self:source_cache_key(item.source or "Model",item.asset)]=true end
        for asset,objects in pairs(self.model_cache) do if not keep[asset] then for _,object in ipairs(objects) do object:Destroy() end; self.model_cache[asset]=nil end end
    end
    function Engine:preload_model_library()
        assert(not self.model_preload.busy,"Models are already preloading")
        local valid,err=self:validate_model_library(self.model_library); assert(valid,err)
        local progress={busy=true,done=0,total=#valid.models,failed=0}; self.model_preload=progress
        task.spawn(function()
            for _,item in ipairs(valid.models) do
                if self.library_closed then break end
                local cache_key=self:source_cache_key(item.source,item.asset)
                if not self.model_cache[cache_key] then
                    local objects
                    local ok=pcall(function()
                        objects=self:source_objects(item.source,item.asset); local parts=0
                        for _,object in ipairs(objects) do
                            assert(not object:IsDescendantOf(workspace),"Asset must be detached")
                            local all={object}; for _,child in ipairs(object:GetDescendants()) do all[#all+1]=child end
                            for _,child in ipairs(all) do
                                if child:IsA("BasePart") then parts=parts+1; assert(parts<=500,"Asset exceeds 500 parts") end
                                if child:IsA("LuaSourceContainer") or child:IsA("Script") or child:IsA("LocalScript") or child:IsA("ModuleScript") or child:IsA("RemoteEvent") or child:IsA("RemoteFunction") then child:Destroy() end
                            end
                        end
                        assert(parts>0,"Asset contains no model geometry")
                        if self.library_closed then error("Library closed") end
                        self.model_cache[cache_key]=objects
                        local provider=game:GetService("ContentProvider"); if provider then
                            local failures=0; provider:PreloadAsync(objects,function(_,status) if status~=Enum.AssetFetchStatus.Success then failures=failures+1 end end)
                            assert(failures==0,"Some textures could not preload")
                        end
                    end)
                    if not ok then progress.failed=progress.failed+1; self.model_cache[cache_key]=nil; if objects then for _,object in ipairs(objects) do object:Destroy() end end end
                end
                progress.done=progress.done+1; task.wait()
            end
            progress.busy=false; self:prune_model_cache()
            if not self.library_closed then ctx.report("Model preload: "..progress.done.." / "..progress.total.." · "..progress.failed.." failed") end
        end)
    end
    local curated={Sasuke=true,Naruto=true,Sukuna=true,Luffy=true,Saitama=true}
    function Engine:character_choices()
        local result={}
        for _,entry in ipairs(self.characters) do if self.settings.model_catalog=="All" or curated[entry.name] or entry.name=="Custom" or entry.name==self.settings.model_preset then result[#result+1]=entry end end
        return result
    end
    if type(readfile)=="function" then
        local ok,exists=pcall(function() return type(isfile)~="function" or isfile("pivot_models.json") end)
        if ok and exists then pcall(function() Engine:read_model_library() end) end
    end

    function Engine:select_character(name)
        local found=false; for _,entry in ipairs(self.characters) do if entry.name==name then found=true; break end end
        assert(found,"Unknown character")
        local previous=self.settings.model_preset
        self.settings.model_preset=name
        if registry.active.custom_model then
            registry:disable("custom_model")
            if name=="Custom" and not tostring(self.settings.model_asset):match("^%s*%d+%s*$") then ctx.report("Enter a custom model asset ID, then enable Character skin"); return true end
            local ok,err=registry:enable("custom_model",self.settings)
            if not ok then self.settings.model_preset=previous; ctx.report("Character could not load: "..tostring(err)); return false end
        end
        return true
    end
    Engine.settings.model_last_preset=Engine.settings.model_preset
    function Engine:skin_source()
        return self.settings.model_preset=="Custom" and "Roblox model ID" or self.settings.model_preset=="Outfit" and "Outfit ID" or self.settings.model_preset=="Avatar" and "Roblox username" or "Preset character"
    end
    function Engine:set_skin_source(source)
        assert(source=="Preset character" or source=="Roblox model ID" or source=="Outfit ID" or source=="Roblox username","Choose a valid skin source")
        if source==self:skin_source() then return end
        registry:disable("custom_model")
        if model_presets[self.settings.model_preset] then self.settings.model_last_preset=self.settings.model_preset end
        if source=="Roblox model ID" then self.settings.model_preset="Custom"
        elseif source=="Outfit ID" then self.settings.model_preset="Outfit"
        elseif source=="Roblox username" then self.settings.model_preset="Avatar"
        else self.settings.model_preset=model_presets[self.settings.model_last_preset] and self.settings.model_last_preset or "Sasuke" end
        ctx.report("Selected "..source.." / preview or equip when ready")
    end
    function Engine:equip_selected_character()
        registry:disable("custom_model")
        local ok,err=registry:enable("custom_model",self.settings); assert(ok,err)
        return true
    end
    local function rig_key(name) return tostring(name):lower():gsub("mixamorig",""):gsub("[^%w]","") end
    local bone_alias={hips="rootjoint",pelvis="rootjoint",spine="waist",spine1="waist",spine2="waist",head="neck",leftarm="leftshoulder",rightarm="rightshoulder",leftforearm="leftelbow",rightforearm="rightelbow",lefthand="leftwrist",righthand="rightwrist",leftupleg="lefthip",rightupleg="righthip",leftleg="leftknee",rightleg="rightknee",leftfoot="leftankle",rightfoot="rightankle"}
    local function capture_character_rig(objects)
        local joints,bones={},{}
        for _,object in ipairs(objects) do
            if object:IsA("Bone") then bones[#bones+1]=object
            elseif object:IsA("JointInstance") or object:IsA("Motor6D") or object:IsA("Weld") or object:IsA("ManualWeld") then
                if object.Part0 and object.Part1 then joints[#joints+1]={name=rig_key(object.Name),part0=object.Part0,part1=object.Part1,c0=object.C0 or CFrame.new(),c1=object.C1 or CFrame.new(),transform=object:IsA("Motor6D") and object.Transform or CFrame.new(),motor=object:IsA("Motor6D")} end
            elseif object:IsA("WeldConstraint") and object.Part0 and object.Part1 then
                joints[#joints+1]={name=rig_key(object.Name),part0=object.Part0,part1=object.Part1,c0=object.Part0.CFrame:ToObjectSpace(object.Part1.CFrame),c1=CFrame.new(),transform=CFrame.new(),motor=false}
            end
        end
        return joints,bones
    end
    local function scaled_joint(frame,factor) return CFrame.new(frame.Position*factor)*frame.Rotation end
    function Engine:pose_character(state,source)
        if state.pose_source~=source then
            state.pose_source=source; state.source_joints={}
            for _,object in ipairs(source:GetDescendants()) do if object:IsA("Motor6D") then state.source_joints[rig_key(object.Name)]=object end end
        end
        local mapped=state.source_joints
        local function transform_for(name,c0,fallback)
            local key=bone_alias[name] or name
            local joint=mapped[name] or mapped[key] or (key=="rootjoint" and mapped.root)
            if not joint then return fallback end
            local pose=joint.Transform or CFrame.new()
            local source_basis=(joint.C0 or CFrame.new()).Rotation
            local target_basis=c0.Rotation
            return target_basis:Inverse()*source_basis*pose*source_basis:Inverse()*target_basis
        end
        local placed={[state.model.PrimaryPart]=true}; local count=0
        if state.motor_count==0 and #state.bones==0 then
            local aliases={Torso="UpperTorso",["Left Arm"]="LeftUpperArm",["Right Arm"]="RightUpperArm",["Left Leg"]="LeftUpperLeg",["Right Leg"]="RightUpperLeg"}
            for _,cosmetic in ipairs(state.parts) do
                local original=source:FindFirstChild(cosmetic.Name,true) or aliases[cosmetic.Name] and source:FindFirstChild(aliases[cosmetic.Name],true)
                if original and original:IsA("BasePart") and original.Name~="HumanoidRootPart" then cosmetic.CFrame=original.CFrame; placed[cosmetic]=true end
            end
        end
        for _=1,16 do
            local progress=false
            for _,joint in ipairs(state.joints) do
                local p0,p1=joint.part0,joint.part1
                local c0=scaled_joint(joint.c0,state.rig_scale); local c1=scaled_joint(joint.c1,state.rig_scale)
                local transform=joint.motor and transform_for(joint.name,c0,joint.transform or CFrame.new()) or joint.transform
                if placed[p0] and not placed[p1] then p1.CFrame=p0.CFrame*c0*transform*c1:Inverse(); placed[p1]=true; progress=true; count=count+1
                elseif placed[p1] and not placed[p0] then p0.CFrame=p1.CFrame*c1*transform:Inverse()*c0:Inverse(); placed[p0]=true; progress=true; count=count+1 end
            end
            if not progress then break end
        end
        for _,bone in ipairs(state.bones) do bone.Transform=transform_for(rig_key(bone.Name),bone.CFrame,CFrame.new()) end

        state.mapped_parts=count
    end

    local body_names={Head=true,HumanoidRootPart=true,Torso=true,UpperTorso=true,LowerTorso=true,["Left Arm"]=true,["Right Arm"]=true,["Left Leg"]=true,["Right Leg"]=true,LeftUpperArm=true,LeftLowerArm=true,LeftHand=true,RightUpperArm=true,RightLowerArm=true,RightHand=true,LeftUpperLeg=true,LeftLowerLeg=true,LeftFoot=true,RightUpperLeg=true,RightLowerLeg=true,RightFoot=true}
    local r6_body={UpperTorso="Torso",LowerTorso="Torso",LeftUpperArm="Left Arm",LeftLowerArm="Left Arm",LeftHand="Left Arm",RightUpperArm="Right Arm",RightLowerArm="Right Arm",RightHand="Right Arm",LeftUpperLeg="Left Leg",LeftLowerLeg="Left Leg",LeftFoot="Left Leg",RightUpperLeg="Right Leg",RightLowerLeg="Right Leg",RightFoot="Right Leg"}
    local normalized_body={}; for name in pairs(body_names) do normalized_body[rig_key(name)]=name end
    local function canonical_body(name)
        local key=rig_key(name); return normalized_body[key] or normalized_body[key:gsub("%d+$",""):gsub("^mesh",""):gsub("mesh$","")]
    end
    local function clean_wearable(part)
        for _,object in ipairs(part:GetDescendants()) do
            if object:IsA("LuaSourceContainer") or object:IsA("Script") or object:IsA("LocalScript") or object:IsA("ModuleScript") or object:IsA("JointInstance") or object:IsA("Motor6D") or object:IsA("Weld") or object:IsA("WeldConstraint") or object:IsA("Constraint") or object:IsA("BodyMover") or object:IsA("BillboardGui") or object:IsA("SurfaceGui") or object:IsA("Sound") or object:IsA("ParticleEmitter") or object:IsA("Trail") or object:IsA("Beam") or object:IsA("Fire") or object:IsA("Smoke") or object:IsA("Sparkles") or object:IsA("Light") then object:Destroy() end
        end
        part.Anchored=true; part.CanCollide=false; part.CanTouch=false; part.CanQuery=false; part.Massless=true; part.LocalTransparencyModifier=0
    end
    local function accessory_group(part)
        if canonical_body(part.Name) then return nil end
        local names={}; local item=part; local kind
        while item and item~=workspace do
            if item:IsA("Model") and (item:FindFirstChild("Head") or item:FindFirstChild("Torso") or item:FindFirstChild("UpperTorso")) then break end
            names[#names+1]=item.Name:lower()
            if item:IsA("Accessory") then local ok,value=pcall(function() return item.AccessoryType.Name end); if ok then kind=value end end
            item=item.Parent
        end
        local name=table.concat(names," ")
        local function has(words) for word in words:gmatch("%S+") do if name:find(word,1,true) then return true end end end
        if has("sword katana weapon kunai blade gun scythe") then return "weapons" end
        if has("cape cloak coat scarf") then return "capes" end
        if has("mask glasses blindfold bandana") or kind=="Face" then return "masks" end
        if has("hair") or kind=="Hair" then return "hair" end
        if has("hat headband crown helmet") or kind=="Hat" then return "hats" end
        if has("accessory handle") or kind then return "extras" end
    end
    local function build_pb_costume(donor,source,scope,s,captured_joints)
        local basketball=s.model_style=="Basketball"
        local imported=s.model_preset=="Avatar" or s.model_preset=="Outfit"
        local sasuke=basketball and s.model_preset=="Sasuke"
        local authored=sasuke
        local uniform,texture_error
        if authored then uniform,texture_error=Engine:basketball_assets(s.model_preset); if not uniform then ctx.report(texture_error) end end
        local donors={}; local donor_parts={}; local donor_height=donor:GetExtentsSize().Y
        for _,object in ipairs(donor:GetDescendants()) do
            if object:IsA("BasePart") then donor_parts[#donor_parts+1]=object; local name=canonical_body(object.Name); if name then donors[name]=object end end
        end
        local matched=0
        for _,part in ipairs(source:GetChildren()) do if part:IsA("BasePart") and part.Name~="HumanoidRootPart" and (donors[part.Name] or donors[r6_body[part.Name]]) then matched=matched+1 end end
        if matched==0 then return nil end
        local model=Instance.new("Model"); model.Name="PivotPBCostume"; scope:defer(function() model:Destroy() end)
        local parts,bindings,extras,nested={},{},{},{}; local used={}
        local function copy_part(original,body_only)
            local copy=original:Clone(); assert(copy,"Could not copy costume geometry")
            if body_only then for _,child in ipairs(copy:GetDescendants()) do if child:IsA("BasePart") or child:IsA("Accessory") then child:Destroy() end end end
            clean_wearable(copy); copy:SetAttribute("PivotAccessoryGroup",accessory_group(original)); copy.Parent=model; parts[#parts+1]=copy; used[original]=true
            for _,child in ipairs(copy:GetDescendants()) do
                if child:IsA("BasePart") then
                    clean_wearable(child); child:SetAttribute("PivotAccessoryGroup",copy:GetAttribute("PivotAccessoryGroup")); parts[#parts+1]=child
                    nested[#nested+1]={part=child,anchor=copy,offset=copy.CFrame:ToObjectSpace(child.CFrame),base_size=child.Size,anchor_size=copy.Size}
                end
            end
            for _,child in ipairs(original:GetDescendants()) do if child:IsA("BasePart") then used[child]=true end end
            return copy
        end
        for _,real in ipairs(source:GetChildren()) do
            if real:IsA("BasePart") and body_names[real.Name] then
                local look=donors[real.Name] or donors[r6_body[real.Name]]
                local exact=donors[real.Name]
                local imported_head=imported and real.Name=="Head" and exact~=nil
                local copy=copy_part(imported_head and look or not basketball and exact and look or real,basketball and not imported_head); copy.Name=real.Name; copy.CFrame=real.CFrame; copy.Size=real.Size*s.model_fit_scale
                if imported_head then copy:SetAttribute("PivotImportedHead",true) end
                if not imported_head and (basketball and (not authored or uniform) or not basketball and not exact and look) then
                    -- PB mesh textures can cover the selected outfit; keep geometry, replace its appearance.
                    if copy:IsA("MeshPart") then pcall(function() copy.TextureID="" end) end
                    for _,object in ipairs(copy:GetDescendants()) do if object:IsA("SurfaceAppearance") or object:IsA("Decal") or object:IsA("Texture") then object:Destroy() end end
                end
                if look then
                    used[look]=true
                    if exact and not basketball then for _,child in ipairs(look:GetDescendants()) do if child:IsA("BasePart") then used[child]=true end end end
                    copy.Color=look.Color
                    if not basketball then copy.Material=look.Material; copy.Reflectance=look.Reflectance end
                end
                if basketball then
                    copy.Material=Enum.Material.SmoothPlastic; copy.Reflectance=0
                    local skin=donors.Head or donors["Left Arm"] or donors.LeftHand
                    if skin then copy.Color=skin.Color end
                end
                if real.Name=="HumanoidRootPart" then copy.Transparency=1; model.PrimaryPart=copy end
                bindings[#bindings+1]={part=copy,name=real.Name}
            end
        end
        for _,object in ipairs((authored and not uniform and source or donor):GetDescendants()) do
            if object:IsA("Shirt") or object:IsA("Pants") or object:IsA("ShirtGraphic") or object:IsA("BodyColors") then local copy=object:Clone(); copy.Parent=model end
        end
        if authored and uniform then
            for _,object in ipairs(model:GetChildren()) do if object:IsA("Shirt") or object:IsA("Pants") or object:IsA("ShirtGraphic") then object:Destroy() end end
            local shirt=Instance.new("Shirt"); shirt.Name=sasuke and "PivotUchihaJersey" or "PivotGojoJersey"; shirt.ShirtTemplate=uniform.shirt; shirt.Parent=model
            local pants=Instance.new("Pants"); pants.Name=sasuke and "PivotUchihaShorts" or "PivotGojoShorts"; pants.PantsTemplate=uniform.pants; pants.Parent=model
        end
        for _,part in ipairs(donor_parts) do
            local group=accessory_group(part)
            local keep=not authored or group=="hair" or group=="hats"
            if not canonical_body(part.Name) and not used[part] and part.Transparency<.95 and keep then
                local name=part.Name:lower(); local parent=part.Parent; local accessory=false
                while parent and parent~=donor do if parent:IsA("Accessory") or parent.Name:lower()=="accessories" then accessory=true; break end; parent=parent.Parent end
                -- Preserve unnamed costume meshes too: masks and armor often use generic export names.
                if not used[part] then
                    local nearest,distance
                    for donor_name,body in pairs(donors) do
                        if donor_name~="HumanoidRootPart" then local d=(body.Position-part.Position).Magnitude; if not distance or d<distance then nearest=body; distance=d end end
                    end
                    -- Prefer the asset's real attachment over a nearest-body guess.
                    for _,joint in ipairs(captured_joints or {}) do
                        if joint.part1==part and donors[canonical_body(joint.part0.Name)]==joint.part0 then nearest=joint.part0; break end
                        if joint.part0==part and donors[canonical_body(joint.part1.Name)]==joint.part1 then nearest=joint.part1; break end
                    end
                    if nearest and #extras<80 then
                        local nearest_name=canonical_body(nearest.Name)
                        local target=source:FindFirstChild(nearest_name) or nearest_name=="Torso" and source:FindFirstChild("UpperTorso")
                        if target then
                            local copy=copy_part(part)
                            local group=accessory_group(part)
                            if nearest_name=="Head" and group~="hair" and group~="hats" and group~="masks" then copy:SetAttribute("PivotFaceGeometry",true) end
                            if not copy:GetAttribute("PivotAccessoryGroup") then copy:SetAttribute("PivotAccessoryGroup","extras") end
                            local offset=nearest.CFrame:ToObjectSpace(part.CFrame)
                            extras[#extras+1]={part=copy,target=target.Name,offset=offset,donor_size=nearest.Size,base_size=part.Size,group=accessory_group(part)}
                        end
                    end
                end
            end
        end
        if sasuke and uniform then
            local waist=source:FindFirstChild("LowerTorso") or source:FindFirstChild("UpperTorso") or source:FindFirstChild("Torso")
            if waist then
                local function rope(name,size,offset,shape)
                    local part=Instance.new("Part"); part.Name=name; part.Size=size; part.Shape=shape or Enum.PartType.Cylinder; part.Color=Color3.fromRGB(105,66,143); part.Material=Enum.Material.Fabric; part:SetAttribute("PivotAccessoryGroup","extras"); clean_wearable(part); part.Parent=model; parts[#parts+1]=part
                    extras[#extras+1]={part=part,target=waist.Name,offset=offset,donor_size=waist.Size,base_size=size,group="extras"}
                end
                local rx=waist.Size.X*.52; local rz=waist.Size.Z*.54; local y=waist.Size.Y*.23
                for i=1,24 do
                    local a=(i-1)*math.pi/12; local b=i*math.pi/12
                    local x1,z1=math.cos(a)*rx,math.sin(a)*rz; local x2,z2=math.cos(b)*rx,math.sin(b)*rz
                    local dx,dz=x2-x1,z2-z1
                    rope("PivotUchihaRope",Vector3.new(math.sqrt(dx*dx+dz*dz)+.025,.085,.085),CFrame.new((x1+x2)/2,y,(z1+z2)/2)*CFrame.Angles(0,-math.atan2(dz,dx),0))
                end
                rope("PivotUchihaKnot",Vector3.new(.19,.16,.15),CFrame.new(0,y,-rz-.055),Enum.PartType.Ball)
                for _,side in ipairs({-1,1}) do rope("PivotUchihaRopeTie",Vector3.new(.52,.07,.07),CFrame.new(side*.11,y-.25,-rz-.055)*CFrame.Angles(0,0,math.pi/2+side*.25)) end
            end
        end
        if not model.PrimaryPart then model.PrimaryPart=parts[1] end
        return {model=model,parts=parts,bindings=bindings,extras=extras,nested=nested,fit_scale=s.model_fit_scale,matched=matched,basketball=basketball,uniform_ready=uniform~=nil,texture_error=texture_error}
    end
    function Engine:is_head_visual(part,head)
        if head and (part==head or part:IsDescendantOf(head)) then return true end
        local group=accessory_group(part)
        if group=="hair" or group=="hats" or group=="masks" then return true end
        for _,object in ipairs(part:GetDescendants()) do
            if object:IsA("Attachment") and head and head:FindFirstChild(object.Name,true) then return true end
            if (object:IsA("JointInstance") or object:IsA("Weld") or object:IsA("WeldConstraint")) and head and (object.Part0==head or object.Part1==head) then return true end
        end
        return false
    end
    function Engine:apply_headless(state,s)
        for part,transparency in pairs(state.head_parts or {}) do
            local group=part:GetAttribute("PivotAccessoryGroup") or accessory_group(part)
            part.Transparency=s.model_headless and 1 or group and not s["model_show_"..group] and 1 or transparency
        end
        for object,transparency in pairs(state.head_art or {}) do object.Transparency=(s.model_headless or object.Parent and object.Parent:IsA("BasePart") and object.Parent.Transparency>=1) and 1 or transparency end
    end
    function Engine:pose_pb_costume(state,source,s)
        local costume=state.pb_costume
        local root_part=source:FindFirstChild("HumanoidRootPart") or source.PrimaryPart
        local delta=root_part and root_part.CFrame*CFrame.new(0,s.model_offset,0)*CFrame.Angles(0,math.rad(s.model_rotation),0)*root_part.CFrame:Inverse() or CFrame.new()
        for _,binding in ipairs(costume.bindings) do
            local real=source:FindFirstChild(binding.name)
            if real then binding.part.CFrame=delta*real.CFrame; binding.part.Size=real.Size*s.model_fit_scale end
        end
        for _,extra in ipairs(costume.extras) do
            local real=source:FindFirstChild(extra.target)
            if real then
                local d=extra.donor_size; local ratio=Vector3.new(real.Size.X/math.max(.01,d.X),real.Size.Y/math.max(.01,d.Y),real.Size.Z/math.max(.01,d.Z))
                local offset=extra.offset.Position; local size=extra.base_size
                local preserve=extra.target=="Head" or extra.group=="weapons"
                if preserve then
                    -- Preserve the shape of hair, masks and weapons instead of stretching each axis.
                    local uniform=(ratio.X+ratio.Z)/2*(s.model_accessory_scale or 1)
                    local function fit_axis(value,donor_size,real_size,axis_ratio)
                        local absolute=math.abs(value); local half=donor_size/2
                        if absolute>half then return (value<0 and -1 or 1)*(real_size/2+(absolute-half)*uniform) end
                        return value*axis_ratio
                    end
                    extra.part.CFrame=delta*real.CFrame*CFrame.new(fit_axis(offset.X,d.X,real.Size.X,ratio.X),fit_axis(offset.Y,d.Y,real.Size.Y,ratio.Y),fit_axis(offset.Z,d.Z,real.Size.Z,ratio.Z))*extra.offset.Rotation
                    extra.part.Size=size*uniform*s.model_fit_scale
                else
                    extra.part.CFrame=delta*real.CFrame*CFrame.new(offset.X*ratio.X,offset.Y*ratio.Y,offset.Z*ratio.Z)*extra.offset.Rotation
                    extra.part.Size=Vector3.new(size.X*ratio.X,size.Y*ratio.Y,size.Z*ratio.Z)*s.model_fit_scale
                end
            end
        end
        for _,child in ipairs(costume.nested) do
            local a=child.anchor_size; local size=child.anchor.Size
            local ratio=Vector3.new(size.X/math.max(.01,a.X),size.Y/math.max(.01,a.Y),size.Z/math.max(.01,a.Z))
            local offset=child.offset.Position; local base=child.base_size
            child.part.CFrame=child.anchor.CFrame*CFrame.new(offset.X*ratio.X,offset.Y*ratio.Y,offset.Z*ratio.Z)*child.offset.Rotation
            child.part.Size=Vector3.new(base.X*ratio.X,base.Y*ratio.Y,base.Z*ratio.Z)
        end
        costume.fit_scale=s.model_fit_scale
    end

    local function clothing(object) return object:IsA("Shirt") or object:IsA("Pants") or object:IsA("ShirtGraphic") end
    function Engine:apply_native_appearance(scope,state,s)
        if not state.native_body then return end
        for _,entry in ipairs(state.native_body) do
            local real,look=entry.real,entry.look
            if real.Parent then
                for _,property in ipairs({"Color","Material","Reflectance"}) do if look[property]~=nil then scope:set(real,property,look[property]) end end
                if real:IsA("MeshPart") then
                    scope:set(real,"TextureID",look:IsA("MeshPart") and look.TextureID or "")
                    if s.model_high_detail then pcall(function() scope:set(real,"RenderFidelity",Enum.RenderFidelity.Precise) end) else scope:restore(real,"RenderFidelity") end
                end
                for _,object in ipairs(real:GetDescendants()) do
                    if object:IsA("SurfaceAppearance") then scope:set(object,"Parent",nil)
                    elseif object:IsA("SpecialMesh") and real.Name=="Head" then scope:set(object,"TextureId","") end
                end
            end
        end
        for _,object in ipairs(state.source:GetChildren()) do
            if clothing(object) and not state.native_garment_set[object] then scope:set(object,"Parent",nil) end
        end
    end
    function Engine:prepare_native_costume(scope,state,s)
        local source=state.source; local costume=state.pb_costume
        if costume then
            state.native_body={}; state.native_source_parts={}; state.native_garments={}; state.native_garment_set={}
            local appearance=Instance.new("Model"); appearance.Name="PivotAppearanceTemplate"; state.appearance_template=appearance; scope:defer(function() appearance:Destroy() end)
            state.model.PrimaryPart=nil
            for _,binding in ipairs(costume.bindings) do
                local real=source:FindFirstChild(binding.name)
                if binding.part:GetAttribute("PivotImportedHead") and real then
                    state.replaced_head=real
                    scope:set(real,"LocalTransparencyModifier",1)
                else
                    if real then state.native_body[#state.native_body+1]={real=real,look=binding.part}; state.native_source_parts[real]=true end
                    binding.part.Parent=appearance
                end
            end
            for _,object in ipairs(state.model:GetChildren()) do
                if clothing(object) then
                    state.native_garments[#state.native_garments+1]=object; state.native_garment_set[object]=true
                    scope:defer(function() object:Destroy() end)
                end
            end
            -- Existing PB geometry and its existing Humanoid render the local wardrobe.
            -- Only appearance properties are changed; never source transforms, size, joints or physics.
            self:apply_native_appearance(scope,state,s)
            for _,object in ipairs(state.native_garments) do object.Parent=source end
            self:pose_pb_costume(state,source,s)
        else
            for _,object in ipairs(state.model:GetDescendants()) do assert(not clothing(object),"Enable Fit costume to PB body to render this outfit's clothes") end
            state.model:PivotTo(assert(root(),"Character unavailable").CFrame)
        end
        -- Validate the final render tree before a single part enters Workspace.
        for _,object in ipairs(state.model:GetDescendants()) do
            assert(not object:IsA("Humanoid") and not object:IsA("AnimationController") and not object:IsA("Animator"),"Cosmetic controller rejected")
            assert(not object:IsA("LuaSourceContainer") and not object:IsA("Script") and not object:IsA("LocalScript") and not object:IsA("ModuleScript"),"Cosmetic script rejected")
            assert(not object:IsA("JointInstance") and not object:IsA("Motor6D") and not object:IsA("Weld") and not object:IsA("WeldConstraint") and not object:IsA("Constraint") and not object:IsA("BodyMover") and not object:IsA("BodyVelocity") and not object:IsA("BodyForce"),"Cosmetic physics link rejected")
            if object:IsA("BasePart") then
                assert(not object:IsDescendantOf(source),"Live character part rejected")
                object.Anchored=true; object.CanCollide=false; object.CanTouch=false; object.CanQuery=false; object.Massless=true
            end
        end
        local folder=new_local(scope,"Folder",workspace); folder.Name="PivotLocalCosmetics"; state.world=folder
        state.model.Parent=folder
    end

    function Engine:rendering_report()
        local active=registry.active.custom_model; local state=active and active.state
        return {preset=self.settings.model_preset,enabled=active~=nil,renderer="Native world",parts=state and #state.parts,textures_ready=state and state.textures_ready,body=state and state.native_body and "Existing PB body" or "Anchored cosmetic mesh",rig=state and state.rig_label}
    end

    add("custom_model","Character skin","Character","Basketball style preserves PB body meshes; Sasuke includes a custom Uchiha uniform. Original costume keeps the donor appearance",{start=function(scope,s)
        s.model_renderer="Native world"
        assert(model_presets[s.model_preset] or s.model_preset=="Custom" or s.model_preset=="Outfit" or s.model_preset=="Avatar","Unknown character preset")
        local objects=Engine:selected_character_objects(); assert(type(objects)=="table" and #objects>0,"Character source could not be loaded")
        local model=Instance.new("Model"); model.Name="PivotCosmeticModel"; local donor_container=model; scope:defer(function() donor_container:Destroy() end)
        local captured_joints,captured_bones={},{}
        -- Objects remain outside the data model until all executable descendants are removed.
        for _,object in ipairs(objects) do
            scope:defer(function() object:Destroy() end)
            local candidates_to_check={object}; for _,descendant in ipairs(object:GetDescendants()) do candidates_to_check[#candidates_to_check+1]=descendant end
            local joints,bones=capture_character_rig(candidates_to_check)
            for _,joint in ipairs(joints) do captured_joints[#captured_joints+1]=joint end
            for _,bone in ipairs(bones) do captured_bones[#captured_bones+1]=bone end
            for _,descendant in ipairs(candidates_to_check) do
                if descendant:IsA("Sound") or descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") or descendant:IsA("Light") or descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") or descendant:IsA("Fire") or descendant:IsA("Smoke") or descendant:IsA("Sparkles") or descendant:IsA("Weld") or descendant:IsA("ManualWeld") or descendant:IsA("Humanoid") or descendant:IsA("AnimationController") or descendant:IsA("JointInstance") or descendant:IsA("Motor6D") or descendant:IsA("WeldConstraint") or descendant:IsA("Constraint") or descendant:IsA("BodyMover") or descendant:IsA("BodyVelocity") or descendant:IsA("BodyPosition") or descendant:IsA("BodyGyro") or descendant:IsA("BodyForce") or descendant:IsA("LuaSourceContainer") or descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") or descendant:IsA("RemoteEvent") or descendant:IsA("RemoteFunction") or descendant:IsA("ClickDetector") or descendant:IsA("ProximityPrompt") then descendant:Destroy() end
            end
            if object.Parent or object:IsA("BasePart") or object:IsA("Model") or object:IsA("Folder") then
                if not object:IsA("LuaSourceContainer") and not object:IsA("Script") and not object:IsA("LocalScript") and not object:IsA("ModuleScript") then object.Parent=model end
            end
        end
        local parts={}; local first
        for _,part in ipairs(model:GetDescendants()) do
            if part:IsA("BasePart") then
                assert(#parts<500,"Model exceeds 500 cosmetic parts")
                part.Anchored=true; part.CanCollide=false; part.CanTouch=false; part.CanQuery=false; part.Massless=true; parts[#parts+1]=part; first=first or part
            elseif part:IsA("Humanoid") then part.DisplayDistanceType=Enum.HumanoidDisplayDistanceType.None end
        end
        assert(first,"Asset contains no displayable parts"); model.PrimaryPart=model:FindFirstChild("HumanoidRootPart",true) or model:FindFirstChild("Torso",true) or first
        local joints,bones={},{}; local motors=0
        for _,joint in ipairs(captured_joints) do
            if joint.part0:IsDescendantOf(model) and joint.part1:IsDescendantOf(model) then joints[#joints+1]=joint; if joint.motor then motors=motors+1 end end
        end
        for _,bone in ipairs(captured_bones) do if bone:IsDescendantOf(model) then bones[#bones+1]=bone end end
        local pb_costume=s.model_fit_pb and build_pb_costume(model,assert(rig(),"Enter a court first"),scope,s,captured_joints) or nil
        if pb_costume then model=pb_costume.model; parts=pb_costume.parts; joints={}; bones={}; motors=0 end
        local size=model:GetExtentsSize(); assert(size.Y>.01,"Invalid model dimensions")
        local height=s.model_fit_pb and assert(rig(),"Character unavailable"):GetExtentsSize().Y or s.model_height
        local rig_scale=pb_costume and 1 or height/size.Y*(s.model_fit_pb and s.model_fit_scale or 1)
        if not pb_costume then model:ScaleTo(rig_scale) end
        local state
        local binding="PivotCostumeCamera"
        run:BindToRenderStep(binding,Enum.RenderPriority.Last.Value+2,function()
            if state and rig() then if state.pb_costume then Engine:pose_pb_costume(state,rig(),s) elseif s.model_follow_pose then Engine:pose_character(state,rig()) end end
        end)
        scope:defer(function() run:UnbindFromRenderStep(binding) end)
        local current=assert(root(),"Enter a court first"); model:PivotTo(current.CFrame)
        local rig_type=motors>0 and (model:FindFirstChild("UpperTorso",true) and "R15 joint rig" or model:FindFirstChild("Torso",true) and "R6 joint rig" or "Joint rig") or #bones>0 and "Bone rig" or "Static / welded model"
        state={model=model,parts=parts,source=rig(),height=s.model_height,last_position=current.Position,phase=0,speed=0,joints=joints,bones=bones,motor_count=motors,rig_scale=rig_scale,pb_costume=pb_costume,fit_scale=s.model_fit_scale,rig_label=pb_costume and (pb_costume.basketball and (pb_costume.texture_error and "PB basketball · custom textures unavailable" or pb_costume.uniform_ready and "PB basketball · authored textures registered" or "PB basketball · live body geometry") or "PB costume · live body proportions and poses") or s.model_fit_pb and motors==0 and #bones==0 and "Single-piece fitted costume · limited limb animation" or rig_type.." · "..motors.." animated joints / "..#bones.." bones"}
        -- Legacy presets remain faceless; imported avatars retain their authored head and face.
        if s.model_preset~="Avatar" and s.model_preset~="Outfit" then
        for _,part in ipairs(parts) do
            if canonical_body(part.Name)=="Head" then
                if part:IsA("MeshPart") then pcall(function() part.TextureID="" end) end
                for _,object in ipairs(part:GetDescendants()) do
                    if object:IsA("Decal") or object:IsA("Texture") or object:IsA("SurfaceAppearance") then object:Destroy()
                    elseif object:IsA("SpecialMesh") then object.TextureId="" end
                end
            end
            local name=part.Name:lower()
            if part:GetAttribute("PivotFaceGeometry") or not canonical_body(part.Name) and not name:find("glasses",1,true) and not name:find("mask",1,true) and (name:find("face",1,true) or name:find("eyebrow",1,true) or name:find("eyelash",1,true) or name:find("mouth",1,true) or name=="eye" or name=="eyes") then part.Transparency=1 end
        end
        end
        Engine:prepare_native_costume(scope,state,s)
        state.head_parts={}
        local costume_head=model:FindFirstChild("Head",true) or state.appearance_template and state.appearance_template:FindFirstChild("Head")
        for _,part in ipairs(parts) do if Engine:is_head_visual(part,costume_head) then state.head_parts[part]=part.Transparency end end
        if pb_costume then
            for _,extra in ipairs(pb_costume.extras) do if extra.target=="Head" then
                state.head_parts[extra.part]=extra.part.Transparency
                for _,child in ipairs(extra.part:GetDescendants()) do if child:IsA("BasePart") then state.head_parts[child]=child.Transparency end end
            end end
        end
        state.head_art={}
        for part in pairs(state.head_parts) do for _,object in ipairs(part:GetDescendants()) do
            if object:IsA("Decal") or object:IsA("Texture") then state.head_art[object]=object.Transparency end
        end end
        state.accessories={}
        for _,part in ipairs(parts) do
            local group=part:GetAttribute("PivotAccessoryGroup") or accessory_group(part)
            if group then state.accessories[#state.accessories+1]={part=part,group=group,transparency=part.Transparency} end
        end
        Engine:apply_headless(state,s)
        state.mesh_fidelity={}
        for _,part in ipairs(parts) do if part:IsA("MeshPart") then state.mesh_fidelity[part]=part.RenderFidelity; if s.model_high_detail then pcall(function() part.RenderFidelity=Enum.RenderFidelity.Precise end) end end end
        local provider=game:GetService("ContentProvider")
        if provider then
            local active=true; scope:defer(function() active=false end)
            task.spawn(function()
                local failed=0
                local ok=pcall(function() provider:PreloadAsync((function() local targets={model}; for _,garment in ipairs(state.native_garments or {}) do targets[#targets+1]=garment end; return targets end)(),function(_,status) if status~=Enum.AssetFetchStatus.Success then failed=failed+1 end end) end)
                if active then state.textures_ready=ok and failed==0; if not state.textures_ready then ctx.report("Some costume textures could not be preloaded") end end
            end)
        end
        return state
    end,step=function(scope,state,s,dt)
        local source=rig(); local part=root(); assert(source and part,"Character unavailable")
        Engine:apply_native_appearance(scope,state,s)
        for part,original in pairs(state.mesh_fidelity) do pcall(function() part.RenderFidelity=s.model_high_detail and Enum.RenderFidelity.Precise or original end) end
        for _,entry in ipairs(state.accessories) do entry.part.Transparency=s["model_show_"..entry.group] and entry.transparency or 1 end
        Engine:apply_headless(state,s)
        if not s.model_fit_pb and s.model_height~=state.height then local factor=s.model_height/state.height; state.model:ScaleTo(state.model:GetScale()*factor); state.rig_scale=state.rig_scale*factor; state.height=s.model_height end
        if s.model_fit_pb and not state.pb_costume and state.fit_scale~=s.model_fit_scale then local factor=s.model_fit_scale/state.fit_scale; state.model:ScaleTo(state.model:GetScale()*factor); state.rig_scale=state.rig_scale*factor; state.fit_scale=s.model_fit_scale end
        dt=math.max(.001,tonumber(dt) or 1/60)
        local delta=part.Position-state.last_position; state.last_position=part.Position
        local speed=math.min(40,Vector3.new(delta.X,0,delta.Z).Magnitude/dt)
        state.speed=state.speed+(speed-state.speed)*math.min(1,dt*12)
        state.phase=state.phase+dt*(6+state.speed*.4)
        local amount=math.min(1,state.speed/16)
        local airborne=math.abs(delta.Y)/dt>2
        local bob=s.model_motion and not airborne and math.sin(state.phase*2)*.09*amount or 0
        local lean=s.model_motion and -math.min(.12,state.speed*.004) or 0
        state.model:PivotTo(part.CFrame*CFrame.new(0,s.model_offset+bob,0)*CFrame.Angles(lean,math.rad(s.model_rotation),0))
        if state.pb_costume then Engine:pose_pb_costume(state,source,s) elseif s.model_follow_pose then Engine:pose_character(state,source) end
        for _,original in ipairs(source:GetDescendants()) do
            if original:IsA("BasePart") then
                if s.model_headless and Engine:is_head_visual(original,source:FindFirstChild("Head")) or state.replaced_head==original or s.model_hide_avatar and not (state.native_source_parts and state.native_source_parts[original]) then scope:set(original,"LocalTransparencyModifier",1) else scope:restore(original,"LocalTransparencyModifier") end
            elseif original:IsA("Decal") or original:IsA("Texture") then
                local source_head=source:FindFirstChild("Head")
                if s.model_hide_avatar or state.replaced_head and original:IsDescendantOf(state.replaced_head) or s.model_headless and source_head and original:IsDescendantOf(source_head) then scope:set(original,"Transparency",1) else scope:restore(original,"Transparency") end
            end
        end
    end})

    Engine.cosmetic_fields={
        coverage_hud={{"coverage_radius","Defender range / studs"},{"coverage_scale","Display size"},{"coverage_height","Height above head"},{"coverage_response","Response speed"}},
        crosshair={{"crosshair_color","Color / #RRGGBB"},{"crosshair_size","Size"},{"crosshair_gap","Gap"},{"crosshair_thickness","Thickness"},{"crosshair_opacity","Opacity"}},
        ball_trail={{"ball_trail_color","Color / #RRGGBB"},{"ball_trail_lifetime","Lifetime / seconds"},{"ball_trail_width","Width"},{"ball_trail_opacity","Opacity"}},
        player_trail={{"player_trail_color","Color / #RRGGBB"},{"player_trail_lifetime","Lifetime / seconds"},{"player_trail_width","Width"},{"player_trail_opacity","Opacity"}},
        ball_appearance={{"ball_color","Color / #RRGGBB"},{"ball_reflectance","Reflectance"},{"ball_glow_strength","Ball surface glow"},{"ball_bloom","Neon bloom strength"}},
        court_appearance={{"court_color","Floor / #RRGGBB"},{"court_line_color","Other lines / #RRGGBB"},{"court_three_color","Three-point / #RRGGBB"},{"court_free_color","Free throw / #RRGGBB"},{"court_reflectance","Reflectance"},{"court_part_name","Exact surface part name"}},
        self_outline={{"outline_color","Outline / #RRGGBB"},{"outline_fill_color","Fill / #RRGGBB"},{"outline_opacity","Outline opacity"},{"outline_fill_opacity","Fill opacity"}},
        sky={{"sky_asset","Custom sky model asset ID"},{"sky_tint","Sky tint / #RRGGBB"},{"sky_decay","Atmosphere / #RRGGBB"},{"sky_stars","Star count"},{"sky_density","Atmosphere density"},{"sky_haze","Haze"}},
        custom_model={{"model_asset","Custom model asset ID"},{"model_fit_scale","Costume fit"},{"model_accessory_scale","Accessory size"},{"model_height","Model height / studs"},{"model_offset","Height offset"},{"model_rotation","Rotation"}}
    }
    Engine.cosmetic_choices={
        coverage_hud={{"coverage_display","Display",{"Both","Number","Bar"}}},
        crosshair={{"crosshair_shape","Shape",{"Dot","Cross","Ring"}}},
        ball_appearance={{"ball_material","Material",{"SmoothPlastic","Plastic","Neon","Metal","Glass"}}},
        court_appearance={{"court_material","Material",{"SmoothPlastic","Wood","WoodPlanks","Concrete","Neon"}}},
        sky={{"sky_preset","Sky preset",{"Night","Galaxy","Sunset","Day","Custom"}}},
        custom_model={{"model_style","Costume style",{"Basketball","Original costume"}}}
    }
    Engine.cosmetic_toggles={ball_appearance={{"ball_remove_texture","Remove ball texture"},{"ball_glow","Neon glow"}},court_appearance={{"court_color_lines","Customize court markings"},{"court_remove_texture","Remove floor textures"},{"court_three_enabled","Custom three-point color"},{"court_free_enabled","Custom free-throw color"},{"court_rebuild_markings","Rebuild baked markings"}},self_outline={{"outline_through_walls","Show through walls"}},custom_model={{"model_headless","Headless"},{"model_show_hair","Show hair"},{"model_show_hats","Show hats / headbands"},{"model_show_masks","Show masks / glasses"},{"model_show_capes","Show capes / coats"},{"model_show_weapons","Show weapons"},{"model_show_extras","Show other accessories"},{"model_high_detail","High mesh detail"},{"model_fit_pb","Fit costume to PB body"},{"model_motion","Single-piece motion"},{"model_hide_avatar","Hide your normal avatar"},{"model_follow_pose","Follow player pose"}}}

    Engine.dribble_moves={
        {id="cross_left",name="Crossover right → left",code="Z"},{id="cross_right",name="Crossover left → right",code="C"},
        {id="hesi_left",name="Hesitation left",code="Z"},{id="hesi_right",name="Hesitation right",code="C"},
        {id="double_left",name="Double crossover left",code="ZZ"},{id="double_right",name="Double crossover right",code="CC"},
        {id="behind_left",name="Behind the back left",code="CX"},{id="behind_right",name="Behind the back right",code="ZX"},
        {id="double_behind_left",name="Double behind left",code="XC"},{id="double_behind_right",name="Double behind right",code="XZ"},
        {id="stepback",name="Stepback",code="X"},{id="snatchback",name="Snatchback",code="XX"},{id="half_spin",name="Half spin",code="V"},
        {id="spin_left",name="Spin left",code="CXZ"},{id="spin_right",name="Spin right",code="ZXC"},
        {id="tween_left",name="Tween / between left",code="VZ"},{id="tween_right",name="Tween / between right",code="VC"},
        {id="shammgod",name="Shammgod",code="VV"},{id="switch_hand",name="Switch hand",code="H"}}
    local moves={}; for _,move in ipairs(Engine.dribble_moves) do moves[move.id]=move end
    Engine.dribble_library={version=1,bindings={},combos={}}; Engine.dribble_draft={}
    local function reserved(key)
        if key=="F8" then return true end
        for _,value in ipairs(ctx.reserved_keys and ctx.reserved_keys() or {"F6","F7"}) do if key==value then return true end end
    end
    local function valid_key(key)
        if key=="None" then return true end
        if type(key)~="string" then return false end
        local number=tonumber(key:match("^F(%d+)$"))
        return number and number>=1 and number<=12 and key=="F"..tostring(number) and not reserved(key)
    end
    function Engine:validate_dribble_library(data)
        if type(data)~="table" or data.version~=1 or type(data.bindings)~="table" or type(data.combos)~="table" then return nil,"Invalid dribble library" end
        local result={version=1,bindings={},combos={}}; local keys={}; local names={}
        local function bind(key)
            if not valid_key(key) then return false end
            if key~="None" then if keys[key] then return false end; keys[key]=true end
            return true
        end
        for id,key in pairs(data.bindings) do if not moves[id] or not bind(key) then return nil,"Unknown move, reserved key or duplicate binding" end; result.bindings[id]=key end
        local count=0; for key in pairs(data.combos) do if type(key)~="number" or key%1~=0 or key<1 then return nil,"Combos must be a list" end; count=count+1 end
        if count>16 then return nil,"Save up to 16 combos" end
        for i=1,count do
            local combo=data.combos[i]
            if type(combo)~="table" or type(combo.name)~="string" or #combo.name<1 or #combo.name>40 or not combo.name:find("%S") or combo.name:find("[%c]") or names[combo.name:lower()] or not bind(combo.key) then return nil,"Invalid combo name or binding" end
            local gap=Core.bounded(combo.gap,80,1200); if not gap or type(combo.steps)~="table" or #combo.steps<1 or #combo.steps>12 then return nil,"Use 1–12 moves and a gap of 80–1200 ms" end
            local steps={}; for _,step in ipairs(combo.steps) do if type(step)~="table" or not moves[step.move] or type(step.sprint)~="boolean" then return nil,"Invalid combo move" end; steps[#steps+1]={move=step.move,sprint=step.sprint} end
            names[combo.name:lower()]=true; result.combos[i]={name=combo.name,key=combo.key,gap=gap,steps=steps}
        end
        return result
    end
    function Engine:save_dribble_library()
        assert(type(writefile)=="function","File saving unavailable")
        writefile("pivot_dribbles.json",game:GetService("HttpService"):JSONEncode(self.dribble_library))
    end
    local function persist() local ok=pcall(function() Engine:save_dribble_library() end); if not ok then ctx.report("Dribble library kept for this session; file saving unavailable") end end
    function Engine:read_dribble_library()
        assert(type(readfile)=="function","File loading unavailable"); local raw=readfile("pivot_dribbles.json"); assert(#raw<=65536,"Library exceeds 64 KB")
        local value,err=self:validate_dribble_library(game:GetService("HttpService"):JSONDecode(raw)); assert(value,err); self.dribble_library=value
    end
    function Engine:cycle_dribble_binding(id,index)
        local target=index and assert(self.dribble_library.combos[index],"Combo not found") or self.dribble_library.bindings
        assert(index or moves[id],"Move not found")
        local current=index and target.key or target[id] or "None"; local options={"None","F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12"}; local at=1
        for i,key in ipairs(options) do if key==current then at=i end end
        for offset=1,#options do
            local key=options[(at+offset-1)%#options+1]
            if index then target.key=key else target[id]=key end
            if self:validate_dribble_library(self.dribble_library) then persist(); return key end
        end
        if index then target.key=current else target[id]=current end; error("No available key")
    end
    function Engine:add_dribble_move(id)
        assert(moves[id],"Move not found"); assert(#self.dribble_draft<12,"Combo already has 12 moves")
        self.dribble_draft[#self.dribble_draft+1]={move=id,sprint=self.settings.dribble_sprint}
    end
    function Engine:save_dribble_combo(name)
        name=tostring(name or ""):match("^%s*(.-)%s*$"); if name=="" then name="My combo" end
        local combo={name=name,key="None",gap=self.settings.dribble_gap,steps={}}
        for _,step in ipairs(self.dribble_draft) do combo.steps[#combo.steps+1]={move=step.move,sprint=step.sprint} end
        local data={version=1,bindings=self.dribble_library.bindings,combos={}}; local replaced=false
        for i,old in ipairs(self.dribble_library.combos) do if old.name:lower()==name:lower() then combo.key=old.key; data.combos[i]=combo; replaced=true else data.combos[i]=old end end
        if not replaced then data.combos[#data.combos+1]=combo end
        local value,err=self:validate_dribble_library(data); assert(value,err); self.dribble_library=value; persist(); ctx.report("Saved combo: "..name)
    end
    function Engine:remove_dribble_combo(index) table.remove(self.dribble_library.combos,index); persist() end
    function Engine:edit_dribble_combo(index)
        local combo=assert(self.dribble_library.combos[index],"Combo not found"); self.dribble_draft={}
        for _,step in ipairs(combo.steps) do self.dribble_draft[#self.dribble_draft+1]={move=step.move,sprint=step.sprint} end
        self.settings.dribble_combo_name=combo.name; self.settings.dribble_gap=combo.gap
    end
    function Engine:play_dribble_steps(steps,gap)
        assert(registry.active.dribble_library,"Enable Dribble library first")
        assert(not self.dribble_job and not ctx.runner.current,"Another combo is running")
        assert(type(steps)=="table" and #steps>0,"Add a move first")
        local controller,keyboard=client_parts(); local endpoint=assert(keyboard.Services.InputService.Dribble,"Dribble input unavailable")
        local job={cancelled=false}; self.dribble_job=job
        task.spawn(function()
            local ok,err=pcall(function()
                for i,step in ipairs(steps) do
                    if job.cancelled then break end
                    assert(registry.active.dribble_library and not input:GetFocusedTextBox() and not ctx.runner.current,"Dribble combo paused")
                    local character=assert(controller:GetCharacter(),"Enter a court first"); local a=character.data and character.data.Attributes or {}
                    assert(held_ball(rig()) or rig() and rig():GetAttribute("Basketball")==true,"Hold the ball first")
                    assert(a.Action~="Shooting" and a.Action~="Dunking","Finish the shot before dribbling")
                    local move=assert(moves[step.move],"Unknown move")
                    if move.code=="H" then endpoint:Fire("H") else endpoint:Fire(move.code,step.sprint,character.Movement and character.Movement.lastMoveDirection or Vector3.zero) end
                    if i<#steps then task.wait(gap/1000) end
                end
            end)
            if self.dribble_job==job then self.dribble_job=nil end
            if not ok and not job.cancelled then ctx.report(tostring(err)) end
        end)
        return true
    end
    function Engine:play_dribble_move(id) assert(moves[id],"Move not found"); return self:play_dribble_steps({{move=id,sprint=self.settings.dribble_sprint}},self.settings.dribble_gap) end
    add("dribble_library","Dribble library","Dribbling","Named input presets, individual function-key bindings and saved chains. Move outcome depends on ball hand, movement and equipped animations",{start=function(scope)
        local value,err=Engine:validate_dribble_library(Engine.dribble_library); assert(value,err)
        local _,keyboard=client_parts(); assert(keyboard.Services.InputService.Dribble,"Dribble input unavailable")
        scope:defer(function() if Engine.dribble_job then Engine.dribble_job.cancelled=true; Engine.dribble_job=nil end end)
        local connection=input.InputBegan:Connect(function(event,processed)
            if processed or input:GetFocusedTextBox() or ctx.runner.current or Engine.dribble_job then return end
            local key=event.KeyCode.Name; if reserved(key) then return end
            local ok,err=pcall(function()
                for id,binding in pairs(Engine.dribble_library.bindings) do if binding~="None" and binding==key then Engine:play_dribble_move(id); return end end
                for _,combo in ipairs(Engine.dribble_library.combos) do if combo.key~="None" and combo.key==key then Engine:play_dribble_steps(combo.steps,combo.gap); return end end
            end)
            if not ok then ctx.report(tostring(err)) end
        end)
        scope:defer(function() connection:Disconnect() end)
    end,conflicts={"dribble_macros","auto_ankle"}})
    if type(readfile)=="function" then pcall(function() Engine:read_dribble_library() end) end

    Engine.build="2026.11.06.4"
    local s=Engine.settings
    local defaults={ball_finish="Custom",court_preset="Custom",lighting_preset="Warm gym",lighting_intensity=.65,shoe_color="#B79AFF",jersey_color="#FFFFFF",shoe_trail=true,landing_particles=true,effect_strength=.5,indicator_style="Ring",indicator_color="#B79AFF",indicator_radius=2.6,indicator_opacity=.7,green_style="Badge",green_color="#89DEAC",green_duration=.7,outfit_jersey=true,outfit_shoes=true,outfit_accessories=false}
    for key,value in pairs(defaults) do s[key]=value end
    s.court_marking_forward=0; s.court_marking_side=0; s.court_marking_rotation=0
    s.court_native_lines=true
    function Engine:show_cosmetic_control(key)
        return not (self.settings.court_native_lines and (key=="court_remove_texture" or key=="court_rebuild_markings" or key=="court_material" or key=="court_reflectance"))
    end
    Engine.ranges.court_marking_forward={-8,8}; Engine.ranges.court_marking_side={-8,8}; Engine.ranges.court_marking_rotation={-10,10}
    for key,value in pairs({lighting_intensity={0,1},effect_strength={.1,1},indicator_radius={1.5,4},indicator_opacity={.1,1},green_duration={.3,1.5}}) do Engine.ranges[key]=value end
    Engine.ball_finishes={"Custom","Matte","Chrome","Holographic","Galaxy","Neon"}
    Engine.court_presets={"Custom","Clean hardwood","Blacktop","Midnight","Team colors"}
    function Engine:apply_ball_finish(name)
        assert(name=="Custom" or name=="Matte" or name=="Chrome" or name=="Holographic" or name=="Galaxy" or name=="Neon","Unknown ball finish")
        s.ball_finish=name
        if name=="Custom" then return end
        s.ball_material=(name=="Neon" or name=="Galaxy") and "Neon" or name=="Chrome" and "Metal" or "SmoothPlastic"
        s.ball_reflectance=name=="Chrome" and .85 or name=="Holographic" and .35 or 0
        s.ball_color=name=="Galaxy" and "#7061CE" or name=="Neon" and "#9AC9FF" or name=="Matte" and "#323744" or "#D5DCE8"
        s.ball_glow=name=="Neon" or name=="Galaxy"; s.ball_remove_texture=true
    end
    function Engine:apply_court_preset(name)
        assert(name=="Custom" or name=="Clean hardwood" or name=="Blacktop" or name=="Midnight" or name=="Team colors","Unknown court preset")
        s.court_preset=name; if name=="Custom" then return end
        s.court_material=name=="Clean hardwood" and "WoodPlanks" or name=="Blacktop" and "Concrete" or "SmoothPlastic"
        if name~="Team colors" then
            s.court_color=name=="Clean hardwood" and "#B98A59" or name=="Blacktop" and "#383B42" or "#202631"
            s.court_line_color=name=="Midnight" and "#ADBFFF" or "#EEEDE7"
            s.court_three_color=s.court_line_color; s.court_free_color=s.court_line_color
        end
        s.court_color_lines=true
    end
    local function visual_part(scope,parent,name)
        local p=new_local(scope,"Part",parent); p.Name=name; p.Anchored=true; p.CanCollide=false; p.CanTouch=false; p.CanQuery=false; p.CastShadow=false; p.Material=Enum.Material.Neon; return p
    end
    add("player_indicator","Player indicator","Visual+","Local ring, segmented ring or direction arrow; no physics",{start=function(scope)
        local folder=new_local(scope,"Folder",workspace); folder.Name="PivotPlayerIndicator"
        local parts={}; for i=1,40 do parts[i]=visual_part(scope,folder,"Segment") end
        return {parts=parts}
    end,step=function(_,state,settings)
        local r=root(); local color=cosmetic_color(settings.indicator_color)
        for i,p in ipairs(state.parts) do
            local arrow=settings.indicator_style=="Arrow"
            local visible=r~=nil and (arrow and i<=2 or not arrow and (settings.indicator_style~="Segmented" or i%5~=0))
            p.Transparency=visible and 1-settings.indicator_opacity or 1
            if visible then
                p.Color=color
                if arrow then p.Size=Vector3.new(.12,.04,1.1); p.CFrame=r.CFrame*CFrame.new(i==1 and -.36 or .36,-2.95,-settings.indicator_radius)*CFrame.Angles(0,i==1 and -.7 or .7,0)
                else local angle=(i-1)*math.pi*2/40; p.Size=Vector3.new(.09,.04,settings.indicator_radius*.17); p.CFrame=CFrame.new(r.Position.X+math.cos(angle)*settings.indicator_radius,r.Position.Y-2.95,r.Position.Z+math.sin(angle)*settings.indicator_radius)*CFrame.Angles(0,-angle,0) end
            end
        end
    end,interval=.025})
    add("shoe_effects","Shoe effects","Visual+","Foot trails and brief landing particles with adjustable strength",{start=function(scope) return {feet={},previousY=0,lastLanding=-10,scope=scope} end,step=function(scope,state,settings)
        local model=rig(); local r=root(); if not model or not r then return end
        local feet={}
        for _,p in ipairs(model:GetDescendants()) do if p:IsA("BasePart") then local n=p.Name:lower(); if n:find("foot",1,true) or n:find("shoe",1,true) then feet[#feet+1]=p end end end
        if #feet==0 then feet={r} end
        local seen={}
        for _,p in ipairs(feet) do
            seen[p]=true; local item=state.feet[p]
            if not item then
                local a=new_local(scope,"Attachment",p); a.Position=Vector3.new(-.12,p==r and -2.7 or -.2,0)
                local b=new_local(scope,"Attachment",p); b.Position=a.Position+Vector3.new(.24,0,0)
                local trail=new_local(scope,"Trail",p); trail.Name="PivotShoeTrail"; trail.Attachment0=a; trail.Attachment1=b; trail.FaceCamera=true; trail.MinLength=.05
                local particles=new_local(scope,"ParticleEmitter",a); particles.Name="PivotLanding"; particles.Rate=0; particles.Lifetime=NumberRange.new(.2,.4); particles.Speed=NumberRange.new(1,3); particles.SpreadAngle=Vector2.new(80,80); particles.Size=NumberSequence.new(.12); particles.Transparency=NumberSequence.new(.25); particles.LightEmission=.6
                item={a=a,b=b,trail=trail,particles=particles}; state.feet[p]=item
            end
            local color=ColorSequence.new(Engine:reactive_outfit_color(settings.shoe_color))
            item.trail.Color=color; item.trail.Enabled=settings.shoe_trail; item.trail.Lifetime=.12+settings.effect_strength*.25; item.trail.WidthScale=NumberSequence.new(settings.effect_strength*.5); item.trail.Transparency=NumberSequence.new(.35)
            item.particles.Color=color
        end
        for p,item in pairs(state.feet) do if not seen[p] then item.trail:Destroy(); item.particles:Destroy(); item.a:Destroy(); item.b:Destroy(); state.feet[p]=nil end end
        local vy=r.AssemblyLinearVelocity.Y
        if settings.landing_particles and state.previousY< -4 and math.abs(vy)<2 and os.clock()-state.lastLanding>.5 then
            state.lastLanding=os.clock(); for _,item in pairs(state.feet) do item.particles:Emit(math.floor(4+settings.effect_strength*10)) end
        end
        state.previousY=vy
    end,interval=.04})
    add("outfit_tint","Outfit colors","Visual+","Tint existing jerseys, shoes and accessories; preserves clothing textures",{start=function() return {} end,step=function(scope,_,settings)
        local sources={rig(),workspace:FindFirstChild("PivotLocalCosmetics")}
        for _,source in pairs(sources) do if source then for _,object in ipairs(source:GetDescendants()) do
            if object:IsA("Shirt") or object:IsA("Pants") then
                if registry.active.reactive_outfit and settings.reactive_clothes then
                    -- Reactive outfit owns clothing tint until its trigger module is disabled.
                elseif settings.outfit_jersey then scope:set(object,"Color3",cosmetic_color(settings.jersey_color)) else scope:restore(object,"Color3") end
            elseif object:IsA("BasePart") then
                local name=object.Name:lower(); local accessory=object.Parent and object.Parent:IsA("Accessory")
                local shoe=name:find("shoe",1,true) or name:find("foot",1,true)
                if shoe and settings.outfit_shoes then scope:set(object,"Color",cosmetic_color(settings.shoe_color))
                elseif accessory and settings.outfit_accessories then scope:set(object,"Color",cosmetic_color(settings.jersey_color))
                else scope:restore(object,"Color") end
            end
        end end end
    end,interval=.25})
    add("lighting_preset","Lighting preset","Visual+","Warm gym, cool arena, sunset and night with adjustable color grading",{start=function(scope)
        local effect=new_local(scope,"ColorCorrectionEffect",lighting); effect.Name="PivotColorGrade"; return {effect=effect}
    end,step=function(scope,state,settings)
        local preset=settings.lighting_preset; local strength=settings.lighting_intensity
        local tones={['Warm gym']={255,233,211,14},['Cool arena']={211,230,255,13},Sunset={255,207,178,18.1},Night={177,198,245,0}}
        local tone=assert(tones[preset],"Unknown lighting preset")
        state.effect.TintColor=Color3.fromRGB(255+(tone[1]-255)*strength,255+(tone[2]-255)*strength,255+(tone[3]-255)*strength)
        state.effect.Contrast=.08*strength; state.effect.Saturation=.08*strength; state.effect.Brightness=preset=="Night" and -.06*strength or .02*strength
        scope:set(lighting,"ClockTime",tone[4])
    end,interval=.2,conflicts={"sky","time","fullbright"}})
    for _,id in ipairs({"sky","time","fullbright"}) do local definition=registry.definitions[id]; definition.conflicts=definition.conflicts or {}; definition.conflicts[#definition.conflicts+1]="lighting_preset" end
    add("green_effect","Perfect shot effect","Visual+","Brief badge or screen-edge flash after confirmed perfect timing feedback",{start=function(scope)
        local badge=new_local(scope,"TextLabel",ctx.gui); badge.Name="PivotPerfectEffect"; badge.AnchorPoint=Vector2.new(.5,0); badge.Position=UDim2.fromScale(.5,.18); badge.Size=UDim2.fromOffset(180,38); badge.Font=Enum.Font.SourceSansSemibold; badge.TextSize=24; badge.Text="PERFECT"; badge.BorderSizePixel=0; badge.BackgroundColor3=Color3.fromRGB(20,24,30); badge.Visible=false
        local corner=new_local(scope,"UICorner",badge); corner.CornerRadius=UDim.new(0,8)
        local frame=new_local(scope,"Frame",ctx.gui); frame.Name="PivotPerfectFlash"; frame.Size=UDim2.fromScale(1,1); frame.BackgroundTransparency=1; frame.BorderSizePixel=0; frame.Visible=false
        local stroke=new_local(scope,"UIStroke",frame); stroke.Thickness=5
        return {badge=badge,frame=frame,stroke=stroke,untilTime=0}
    end,step=function(_,state,settings)
        local remaining=state.untilTime-os.clock(); local visible=remaining>0; local color=cosmetic_color(settings.green_color)
        state.badge.Visible=visible and settings.green_style=="Badge"; state.frame.Visible=visible and settings.green_style=="Edge flash"
        state.badge.TextColor3=color; state.badge.TextTransparency=1-math.min(1,remaining/.2); state.badge.BackgroundTransparency=.15+(1-math.min(1,remaining/.2))*.85
        state.stroke.Color=color; state.stroke.Transparency=1-math.max(0,math.min(1,remaining/settings.green_duration))*.7
    end,interval=.025})
    function Engine:visual_feedback(event)
        local active=registry.active.green_effect
        if active and event.kind=="feedback" and event.code==5 then active.state.untilTime=os.clock()+s.green_duration end
    end
    function Engine:preview_character(viewport,name)
        local objects=self:selected_character_objects(name)
        if not viewport.Parent then for _,o in ipairs(objects) do o:Destroy() end; return end
        viewport:ClearAllChildren()
        local world=Instance.new("WorldModel")
        local model=Instance.new("Model"); model.Parent=world
        for _,object in ipairs(objects) do object.Parent=model end
        for _,object in ipairs(model:GetDescendants()) do
            if object:IsA("LuaSourceContainer") or object:IsA("Script") or object:IsA("LocalScript") or object:IsA("ModuleScript") or object:IsA("Tool") or object:IsA("BodyMover") or object:IsA("Constraint") then object:Destroy()
            elseif object:IsA("BasePart") then object.Anchored=true; object.CanCollide=false; object.CanTouch=false; object.CanQuery=false end
        end
        if self.settings.model_headless then
            local head=model:FindFirstChild("Head",true)
            for _,part in ipairs(model:GetDescendants()) do if part:IsA("BasePart") and self:is_head_visual(part,head) then
                part.Transparency=1
                for _,object in ipairs(part:GetDescendants()) do if object:IsA("Decal") or object:IsA("Texture") then object.Transparency=1 end end
            end end
        end
        if not viewport.Parent then world:Destroy(); return end
        world.Parent=viewport
        local cf,size=model:GetBoundingBox(); local camera=Instance.new("Camera"); camera.FieldOfView=35; camera.Parent=viewport; viewport.CurrentCamera=camera
        local distance=math.max(size.X,size.Y,size.Z)*1.9
        camera.CFrame=CFrame.lookAt(cf.Position+Vector3.new(0,size.Y*.05,-distance),cf.Position)
    end

    for key,value in pairs({wings_style="Feather",wings_color="#DCE4FF",wings_tip_color="#A28BFF",wings_scale=1,wings_flap=true,wings_speed=1.4,wings_opacity=.9,aura_style="Sparks",aura_color="#B79AFF",aura_density=18,aura_size=1,aura_opacity=.6,impact_style="Both",impact_color="#B79AFF",impact_size=1,impact_strength=.6}) do s[key]=value end
    for key,value in pairs({wings_scale={.5,2},wings_speed={.2,3},wings_opacity={.2,1},aura_density={4,45},aura_size={.5,2},aura_opacity={.1,1},impact_size={.4,2},impact_strength={.1,1}}) do Engine.ranges[key]=value end
    s.wings_fold_idle=true; s.wings_fold=.35; Engine.ranges.wings_fold={0,.8}
    local function effect_part(scope,parent,name,class)
        local p=new_local(scope,class or "Part",parent); p.Name=name; p.Anchored=true; p.CanCollide=false; p.CanTouch=false; p.CanQuery=false; p.CastShadow=false; p.Material=Enum.Material.SmoothPlastic; p.Transparency=1; return p
    end
    add("wings","Wings","Visual+","Animated feather, bat or energy wings with independent colors and scale",{start=function(scope)
        scope:defer(function() registry:disable("wing_trails") end)
        local folder=new_local(scope,"Folder",workspace); folder.Name="PivotWings"
        local feathers,coverts,bones={},{},{}
        for _,side in ipairs({-1,1}) do
            for i=1,9 do
                local p=effect_part(scope,folder,"FlightFeather"); local mesh=new_local(scope,"SpecialMesh",p); mesh.MeshType=Enum.MeshType.Sphere
                feathers[#feathers+1]={part=p,mesh=mesh,side=side,index=i}
                local c=effect_part(scope,folder,"LayeredFeather"); local cm=new_local(scope,"SpecialMesh",c); cm.MeshType=Enum.MeshType.Sphere
                coverts[#coverts+1]={part=c,mesh=cm,side=side,index=i}
            end
            for i=1,2 do local p=effect_part(scope,folder,"WingSpar"); local mesh=new_local(scope,"SpecialMesh",p); mesh.MeshType=Enum.MeshType.Sphere; bones[#bones+1]={part=p,side=side,index=i} end
        end
        return {folder=folder,feathers=feathers,coverts=coverts,bones=bones,openness=1}
    end,step=function(_,state,settings,dt)
        local model=rig(); local torso=model and (model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso") or root())
        local time=os.clock(); local r=root(); local speed=r and r.AssemblyLinearVelocity and r.AssemblyLinearVelocity.Magnitude or 0
        if r and state.last_position and dt and dt>0 then local distance=(r.Position-state.last_position).Magnitude; if distance<8 then speed=math.max(speed,distance/dt) end end
        state.last_position=r and r.Position
        local target=settings.wings_fold_idle and 1-settings.wings_fold*(1-math.min(1,speed/16)) or 1
        state.openness=state.openness+(target-state.openness)*(1-math.exp(-7*(dt or .02)))
        local flap=settings.wings_flap and math.sin(time*settings.wings_speed*math.pi)*(.1+.12*state.openness) or 0
        local color=Engine:reactive_outfit_color(settings.wings_color); local tip=cosmetic_color(settings.wings_tip_color); local scale=settings.wings_scale
        for _,entry in ipairs(state.feathers) do
            local p,i,side=entry.part,entry.index,entry.side
            local visible=torso~=nil and (settings.wings_style~="Bat" or i<=6)
            p.Transparency=visible and 1-settings.wings_opacity or 1
            if visible then
                local bat=settings.wings_style=="Bat"; local energy=settings.wings_style=="Energy"
                local length=bat and (i<=3 and 2.5-i*.18 or 1.25) or 1.35+i*.13
                p.Size=Vector3.new((bat and .9 or energy and .2 or .38)*scale,length*scale,.13*scale)
                entry.mesh.MeshType=bat and Enum.MeshType.Wedge or Enum.MeshType.Sphere
                p.Color=i>=7 and tip or color; p.Material=energy and Enum.Material.Neon or Enum.Material.SmoothPlastic
                local mount=torso.CFrame*CFrame.new(side*.25,.45,.75)*CFrame.Angles(0,side*(.18+flap+(1-state.openness)*.8),0)
                p.CFrame=mount*CFrame.new(side*(.55+i*.25)*scale*state.openness,(.62-i*.075+math.sin(i/9*math.pi)*.2)*scale,.07*i*scale)*CFrame.Angles(0,0,side*(-.95+i*.055))
            end
        end
        for _,entry in ipairs(state.coverts) do
            local p,i,side=entry.part,entry.index,entry.side
            local visible=torso~=nil and settings.wings_style~="Bat"
            p.Transparency=visible and 1-settings.wings_opacity or 1
            if visible then
                local mount=torso.CFrame*CFrame.new(side*.25,.45,.72)*CFrame.Angles(0,side*(.18+flap+(1-state.openness)*.8),0)
                p.Size=Vector3.new(.34*scale,(.6+i*.045)*scale,.16*scale); p.Color=i>=8 and tip or color; p.Material=settings.wings_style=="Energy" and Enum.Material.Neon or Enum.Material.SmoothPlastic
                p.CFrame=mount*CFrame.new(side*(.35+i*.22)*scale*state.openness,(.95-i*.045)*scale,.045*i*scale)*CFrame.Angles(0,0,side*(-.9+i*.045))
            end
        end
        for _,entry in ipairs(state.bones) do
            local p,side=entry.part,entry.side; p.Transparency=torso and 1-settings.wings_opacity or 1
            if torso then
                local mount=torso.CFrame*CFrame.new(side*.25,.45,.7)*CFrame.Angles(0,side*(.18+flap+(1-state.openness)*.8),0)
                local a=(mount*CFrame.new(side*(entry.index-1)*1.2*scale*state.openness,.9*scale,.08)).Position
                local b=(mount*CFrame.new(side*entry.index*1.2*scale*state.openness,(entry.index==1 and 1.15 or .9)*scale,.25)).Position
                p.Size=Vector3.new(.16*scale,.16*scale,(b-a).Magnitude); p.CFrame=CFrame.new((a+b)/2,b); p.Color=tip
            end
        end
    end,interval=.02})
    add("character_aura","Character aura","Visual+","Sparks, mist or orbiting lights with adjustable density, size and opacity",{start=function(scope)
        local folder=new_local(scope,"Folder",workspace); folder.Name="PivotAura"
        local orbs={}; for i=1,8 do local p=effect_part(scope,folder,"AuraOrb"); p.Shape=Enum.PartType.Ball; orbs[i]=p end
        return {orbs=orbs}
    end,step=function(scope,state,settings)
        local r=root(); local color=Engine:reactive_outfit_color(settings.aura_color); local orbit=settings.aura_style=="Orbit"
        if state.root~=r then
            if state.attachment then state.attachment:Destroy(); state.attachment=nil; state.emitter=nil end
            state.root=r
            if r then
                local a=new_local(scope,"Attachment",r); a.Name="PivotAuraAttachment"
                local e=new_local(scope,"ParticleEmitter",a); e.Name="PivotAuraParticles"; e.Texture="rbxasset://textures/particles/sparkles_main.dds"; e.SpreadAngle=Vector2.new(180,180); e.LightEmission=.8; e.LockedToPart=true
                state.attachment=a; state.emitter=e
            end
        end
        if state.emitter then
            local e=state.emitter; local mist=settings.aura_style=="Mist"
            e.Enabled=not orbit; e.Color=ColorSequence.new(color); e.Rate=settings.aura_density
            e.Lifetime=NumberRange.new(mist and .8 or .35,mist and 1.2 or .65)
            e.Speed=NumberRange.new(mist and .25 or .8,mist and .65 or 1.8)
            e.Size=NumberSequence.new(settings.aura_size*(mist and .45 or .12)); e.Transparency=NumberSequence.new(1-settings.aura_opacity)
            e.Rotation=NumberRange.new(0,360); e.RotSpeed=NumberRange.new(-35,35)
        end
        for i,p in ipairs(state.orbs) do
            p.Transparency=r and orbit and 1-settings.aura_opacity or 1
            if r and orbit then
                local angle=os.clock()*1.6+i*math.pi/4; local radius=1.3*settings.aura_size
                p.Size=Vector3.new(.11,.11,.11)*settings.aura_size; p.Color=color; p.Material=Enum.Material.Neon
                p.CFrame=CFrame.new(r.Position+Vector3.new(math.cos(angle)*radius,math.sin(angle*2)*.7,math.sin(angle)*radius))
            end
        end
    end,interval=.03})
    local function destroy_impact(burst) burst.folder:Destroy() end
    local function impact_burst(state,position,settings)
        if #state.bursts>=6 then destroy_impact(table.remove(state.bursts,1)) end
        local folder=Instance.new("Folder"); folder.Name="PivotBounceBurst"; folder.Parent=state.folder
        local parts={}
        if settings.impact_style~="Sparks" then for i=1,20 do
            local p=Instance.new("Part"); p.Name="ImpactRing"; p.Anchored=true; p.CanCollide=false; p.CanTouch=false; p.CanQuery=false; p.CastShadow=false; p.Material=Enum.Material.Neon; p.Size=Vector3.new(.08,.025,.1); p.Parent=folder; parts[i]=p
        end end
        if settings.impact_style~="Ring" then
            local p=Instance.new("Part"); p.Name="BurstOrigin"; p.Anchored=true; p.CanCollide=false; p.CanTouch=false; p.CanQuery=false; p.Transparency=1; p.Size=Vector3.new(.02,.02,.02); p.CFrame=CFrame.new(position); p.Parent=folder
            local a=Instance.new("Attachment"); a.Parent=p
            local e=Instance.new("ParticleEmitter"); e.Texture="rbxasset://textures/particles/sparkles_main.dds"; e.Rate=0; e.Lifetime=NumberRange.new(.15,.35); e.Speed=NumberRange.new(1,3); e.SpreadAngle=Vector2.new(70,70); e.Size=NumberSequence.new(.1*settings.impact_size); e.Transparency=NumberSequence.new(.25); e.Color=ColorSequence.new(cosmetic_color(settings.impact_color)); e.LightEmission=.8; e.Parent=a
            e:Emit(math.floor(4+settings.impact_strength*12))
        end
        state.bursts[#state.bursts+1]={folder=folder,parts=parts,position=position,born=os.clock(),size=settings.impact_size,strength=settings.impact_strength,color=cosmetic_color(settings.impact_color)}
    end
    add("ball_impacts","Ball impact effects","Visual+","Brief rings and sparks on detected floor bounces; does not alter the ball",{start=function(scope)
        local folder=new_local(scope,"Folder",workspace); folder.Name="PivotBallImpacts"
        return {folder=folder,balls={},bursts={}}
    end,step=function(_,state,settings)
        local seen={}
        for _,item in ipairs(candidates("balls")) do
            local ball=item.object
            if ball.Parent and not seen[ball] then
                seen[ball]=true
                local velocity=ball.AssemblyLinearVelocity; local prior=state.balls[ball]
                if velocity then
                    local elapsed=prior and os.clock()-prior.time
                    local sampled=elapsed and elapsed>0 and elapsed<.25 and (ball.Position.Y-prior.position.Y)/elapsed or 0
                    local vertical=math.abs(velocity.Y)<.5 and math.abs(sampled)>1 and sampled or velocity.Y
                    local continuous=prior and elapsed and elapsed<.25 and (ball.Position-prior.position).Magnitude<8
                    if continuous and prior.y< -2 and vertical>1 and os.clock()-prior.last>.18 then
                        local params=RaycastParams.new(); params.FilterType=Enum.RaycastFilterType.Exclude
                        local excludes={ball,state.folder}; local chars=workspace:FindFirstChild("Characters"); if chars then excludes[#excludes+1]=chars end
                        params.FilterDescendantsInstances=excludes; params.IgnoreWater=true
                        local hit=workspace:Raycast(ball.Position,Vector3.new(0,-(ball.Size.Y/2+.8),0),params)
                        if hit and hit.Normal.Y>.7 then impact_burst(state,hit.Position+Vector3.new(0,.025,0),settings); prior.last=os.clock() end
                    end
                    state.balls[ball]={y=vertical,last=prior and prior.last or -10,position=ball.Position,time=os.clock()}
                end
            end
        end
        for ball in pairs(state.balls) do if not seen[ball] then state.balls[ball]=nil end end
        for i=#state.bursts,1,-1 do
            local burst=state.bursts[i]; local age=os.clock()-burst.born
            if age>.45 then destroy_impact(burst); table.remove(state.bursts,i)
            else
                local radius=(.15+age*3.6)*burst.size
                for n,p in ipairs(burst.parts) do
                    local angle=n*math.pi/10; p.Size=Vector3.new(.055,.025,radius*.33)
                    p.CFrame=CFrame.new(burst.position+Vector3.new(math.cos(angle)*radius,0,math.sin(angle)*radius))*CFrame.Angles(0,-angle,0)
                    p.Color=burst.color; p.Transparency=1-(1-age/.45)*burst.strength
                end
            end
        end
    end,interval=.025})
    function Engine:preview_ball_impact()
        local active=assert(registry.active.ball_impacts,"Enable Ball impact effects first")
        local r=assert(root(),"Enter a court first")
        impact_burst(active.state,r.Position+Vector3.new(0,-2.9,-2),self.settings)
    end

    for key,value in pairs({lightning_color="#82CFFF",lightning_core_color="#F0FBFF",lightning_size=1,lightning_intensity=.75,lightning_rate=8,lightning_motion=true,wing_trail_color="#B79AFF",wing_trail_lifetime=.3,wing_trail_width=.25,wing_trail_opacity=.65,rim_color="#B79AFF",rim_animated=false,rim_glow=true,rim_flash=true,rim_flash_duration=.45}) do s[key]=value end
    for key,value in pairs({lightning_size={.5,2},lightning_intensity={.1,1},lightning_rate={2,14},wing_trail_lifetime={.1,1},wing_trail_width={.05,.8},wing_trail_opacity={.1,1},rim_flash_duration={.15,1}}) do Engine.ranges[key]=value end
    s.lightning_branches=true; s.lightning_smoothness=.65; Engine.ranges.lightning_smoothness={0,1}
    add("lightning_aura","Lightning aura","Visual+","Animated branching bolts around your body, with motion streaks while running",{start=function(scope)
        local folder=new_local(scope,"Folder",workspace); folder.Name="PivotLightningAura"
        local bolts={}
        for i=1,6 do
            local segments={}
            for n=1,5 do
                local glow=effect_part(scope,folder,"LightningGlow"); glow.Material=Enum.Material.Neon
                local core=effect_part(scope,folder,"LightningCore"); core.Material=Enum.Material.Neon
                segments[n]={glow=glow,core=core}
            end
            local branches={}
            for n=1,2 do local glow=effect_part(scope,folder,"LightningBranchGlow"); glow.Material=Enum.Material.Neon; local core=effect_part(scope,folder,"LightningBranchCore"); core.Material=Enum.Material.Neon; branches[n]={glow=glow,core=core} end
            bolts[i]={segments=segments,branches=branches,next_shape=0,points={}}
        end
        return {bolts=bolts,folder=folder,speed=0}
    end,step=function(_,state,settings,dt)
        local r=root(); local now=os.clock(); local count=math.floor(2+settings.lightning_intensity*4)
        local color=Engine:reactive_outfit_color(settings.lightning_color); local core_color=cosmetic_color(settings.lightning_core_color)
        local speed=r and r.AssemblyLinearVelocity and r.AssemblyLinearVelocity.Magnitude or 0
        if r and state.last_position and dt and dt>0 then local distance=(r.Position-state.last_position).Magnitude; if distance<8 then speed=math.max(speed,distance/dt) end end
        state.last_position=r and r.Position
        state.speed=state.speed+(speed-state.speed)*(1-math.exp(-9*(dt or .02)))
        if settings.lightning_motion and state.speed>12 then count=math.min(6,count+1) end
        local stretch=settings.lightning_motion and math.min(2.2,state.speed/12) or 0
        for i,bolt in ipairs(state.bolts) do
            if now>=bolt.next_shape then
                bolt.born=now; bolt.lifetime=(.85+(i%3)*.13)/settings.lightning_rate; bolt.next_shape=now+bolt.lifetime
                bolt.previous_points=bolt.points
                local angle=i*math.pi/3+math.random()*.6; local points={}
                for n=0,5 do
                    local phase=angle+n*.22; local radius=(.95+math.random()*.45)*settings.lightning_size
                    local jitter=n==0 or n==5
                    points[n+1]=Vector3.new(math.cos(phase)*radius+(jitter and 0 or (math.random()-.5)*.55), (1.5-n*.57+(math.random()-.5)*.3)*settings.lightning_size,math.sin(phase)*radius+stretch*n/5)
                end
                bolt.points=points
                bolt.branch_tip=points[3]+Vector3.new((i%2==0 and 1 or -1)*(.4+math.random()*.45),-.35,.2)
            end
            local visible=r~=nil and i<=count
            local phase=math.max(0,math.min(1,(now-(bolt.born or now))/(bolt.lifetime or .1)))
            local envelope=math.max(0,math.sin(phase*math.pi))
            local blend=settings.lightning_smoothness>0 and math.min(1,phase/(.05+settings.lightning_smoothness*.3)) or 1
            local display={}
            for n,point in ipairs(bolt.points) do local previous=bolt.previous_points[n]; display[n]=previous and previous+(point-previous)*blend or point end
            for n,segment in ipairs(bolt.segments) do
                segment.glow.Transparency=visible and 1-envelope*.55 or 1; segment.core.Transparency=visible and 1-envelope*.95 or 1
                if visible then
                    local a=(r.CFrame*CFrame.new(display[n])).Position; local b=(r.CFrame*CFrame.new(display[n+1])).Position
                    local length=(b-a).Magnitude; local frame=CFrame.new((a+b)/2,b)
                    local width=(.035+settings.lightning_intensity*.035)*settings.lightning_size
                    segment.glow.Size=Vector3.new(width*2.4,width*2.4,length); segment.core.Size=Vector3.new(width*.5,width*.5,length)
                    segment.glow.CFrame=frame; segment.core.CFrame=frame; segment.glow.Color=color; segment.core.Color=core_color
                end
            end
            local branch_points={display[3],(display[3]+bolt.branch_tip)/2+Vector3.new(.1,-.12,.14),bolt.branch_tip}
            for n,segment in ipairs(bolt.branches) do
                local shown=visible and settings.lightning_branches
                segment.glow.Transparency=shown and 1-envelope*.4 or 1; segment.core.Transparency=shown and 1-envelope*.75 or 1
                if shown then
                    local a=(r.CFrame*CFrame.new(branch_points[n])).Position; local b=(r.CFrame*CFrame.new(branch_points[n+1])).Position
                    local width=.025*settings.lightning_size; local frame=CFrame.new((a+b)/2,b); local length=(b-a).Magnitude
                    segment.glow.Size=Vector3.new(width*2.4,width*2.4,length); segment.core.Size=Vector3.new(width*.6,width*.6,length)
                    segment.glow.CFrame=frame; segment.core.CFrame=frame; segment.glow.Color=color; segment.core.Color=core_color
                end
            end
        end
    end,interval=.02})
    add("wing_trails","Wing-tip trails","Visual+","Short trails following your wings; enable Wings first",{start=function(scope)
        assert(registry.active.wings,"Enable Wings first")
        local state={items={}}
        scope:defer(function() for _,item in pairs(state.items) do item.trail:Destroy(); item.a:Destroy(); item.b:Destroy() end end)
        return state
    end,step=function(_,state,settings)
        local wings=registry.active.wings; local targets={}
        if wings then
            local index=Engine.settings.wings_style=="Bat" and 3 or 8
            targets={wings.state.feathers[index].part,wings.state.feathers[9+index].part}
        end
        local seen={}
        for _,part in ipairs(targets) do if part.Parent then
            seen[part]=true; local item=state.items[part]
            if not item then
                local a=Instance.new("Attachment"); a.Name="PivotWingTrailA"; a.Parent=part
                local b=Instance.new("Attachment"); b.Name="PivotWingTrailB"; b.Parent=part
                local trail=Instance.new("Trail"); trail.Name="PivotWingTipTrail"; trail.Attachment0=a; trail.Attachment1=b; trail.FaceCamera=true; trail.MinLength=.025; trail.LightEmission=.65; trail.Parent=part
                item={a=a,b=b,trail=trail}; state.items[part]=item
            end
            item.a.Position=Vector3.new(0,-part.Size.Y*.4,-settings.wing_trail_width/2); item.b.Position=Vector3.new(0,-part.Size.Y*.4,settings.wing_trail_width/2)
            item.trail.Color=ColorSequence.new(Engine:reactive_outfit_color(settings.wing_trail_color)); item.trail.Lifetime=settings.wing_trail_lifetime; item.trail.WidthScale=NumberSequence.new(1); item.trail.Transparency=NumberSequence.new(1-settings.wing_trail_opacity)
        end end
        for part,item in pairs(state.items) do if not seen[part] then item.trail:Destroy(); item.a:Destroy(); item.b:Destroy(); state.items[part]=nil end end
    end,interval=.04})
    local function collect_effect_rims()
        local result,seen={},{}
        for _,name in ipairs({"Hoops","Map"}) do
            local folder=workspace:FindFirstChild(name)
            if folder then for _,part in ipairs(folder:GetDescendants()) do
                if part:IsA("BasePart") and part.Name=="Rim" and not seen[part] then seen[part]=true; result[#result+1]=part end
            end end
        end
        return result
    end
    add("rim_effects","Rim effects","Visual+","Rim color, neon finish and a brief flash on detected downward ball crossings",{start=function(scope)
        local state={rims={},highlights={},balls={},flashes={},next_scan=0}
        scope:defer(function() for _,highlight in pairs(state.highlights) do highlight:Destroy() end end)
        return state
    end,step=function(scope,state,settings)
        local now=os.clock()
        if now>=state.next_scan then state.rims=collect_effect_rims(); state.next_scan=now+1.5 end
        local color=cosmetic_color(settings.rim_color)
        if settings.rim_animated then color=Color3.fromRGB(170+65*math.sin(now),170+65*math.sin(now+2),190+60*math.sin(now+4)) end
        local seen_balls={}
        for _,item in ipairs(candidates("balls")) do
            local ball=item.object; seen_balls[ball]=true; local prior=state.balls[ball]
            if settings.rim_flash and prior and now-prior.time<.3 and (ball.Position-prior.position).Magnitude<12 then
                for _,rim in ipairs(state.rims) do if rim.Parent then
                    local previous,current=prior.position,ball.Position
                    if previous.Y>rim.Position.Y and current.Y<=rim.Position.Y and current.Y<previous.Y then
                        local alpha=(rim.Position.Y-previous.Y)/(current.Y-previous.Y)
                        local crossing=previous+(current-previous)*alpha
                        local distance=Vector3.new(crossing.X-rim.Position.X,0,crossing.Z-rim.Position.Z).Magnitude
                        local radius=math.max(.45,math.min(1.5,math.max(rim.Size.X,rim.Size.Z)*.5))
                        if distance<radius then state.flashes[rim]=now+settings.rim_flash_duration end
                    end
                end end
            end
            state.balls[ball]={position=ball.Position,time=now}
        end
        for ball in pairs(state.balls) do if not seen_balls[ball] then state.balls[ball]=nil end end
        local seen={}
        for _,rim in ipairs(state.rims) do if rim.Parent then
            seen[rim]=true
            local flashing=(settings.rim_flash or now<(state.preview_until or 0)) and now<(state.flashes[rim] or 0)
            scope:set(rim,"Color",flashing and Color3.fromRGB(244,250,255) or color)
            if settings.rim_glow or flashing then scope:set(rim,"Material",Enum.Material.Neon) else scope:restore(rim,"Material") end
            local h=state.highlights[rim]
            if not h then h=Instance.new("Highlight"); h.Name="PivotRimGlow"; h.Adornee=rim; h.DepthMode=Enum.HighlightDepthMode.Occluded; h.FillTransparency=1; h.Parent=rim; state.highlights[rim]=h end
            h.Enabled=settings.rim_glow or flashing; h.OutlineColor=flashing and Color3.fromRGB(244,250,255) or color; h.OutlineTransparency=flashing and .1 or .5
        end end
        for rim,h in pairs(state.highlights) do if not seen[rim] then h:Destroy(); state.highlights[rim]=nil; state.flashes[rim]=nil end end
    end,interval=.04})
    function Engine:preview_rim_flash()
        local state=assert(registry.active.rim_effects,"Enable Rim effects first").state
        state.rims=collect_effect_rims(); assert(#state.rims>0,"No court rim is visible")
        state.preview_until=os.clock()+self.settings.rim_flash_duration
        for _,rim in ipairs(state.rims) do state.flashes[rim]=os.clock()+self.settings.rim_flash_duration end
    end

    for key,value in pairs({footlight_color="#82CFFF",footlight_duration=.45,footlight_size=1,ball_electric_color="#82CFFF",ball_electric_duration=.25,ball_electric_width=.07,dunk_lightning_color="#82CFFF",dunk_lightning_duration=.45,dunk_lightning_strength=.8}) do s[key]=value end
    for key,value in pairs({footlight_duration={.15,.8},footlight_size={.5,2},ball_electric_duration={.1,.5},ball_electric_width={.03,.18},dunk_lightning_duration={.2,.8},dunk_lightning_strength={.2,1}}) do Engine.ranges[key]=value end
    local function electric_floor(origin,distance,exclude)
        local params=RaycastParams.new(); params.FilterType=Enum.RaycastFilterType.Exclude; params.IgnoreWater=true
        local list=exclude or {}
        for _,name in ipairs({"Characters","Assets","Basketballs","Hoops"}) do local object=workspace:FindFirstChild(name); if object then list[#list+1]=object end end
        local model=rig(); if model then list[#list+1]=model end
        params.FilterDescendantsInstances=list
        local hit=workspace:Raycast(origin,Vector3.new(0,-distance,0),params)
        return hit and hit.Normal.Y>.7 and hit or nil
    end
    local function electric_segment(parent,name)
        local p=Instance.new("Part"); p.Name=name; p.Anchored=true; p.CanCollide=false; p.CanTouch=false; p.CanQuery=false; p.CastShadow=false; p.Material=Enum.Material.Neon; p.Transparency=1; p.Parent=parent; return p
    end
    local function electric_line(p,a,b,width,color,opacity)
        local length=(b-a).Magnitude
        p.Transparency=length>.001 and 1-opacity or 1
        if length>.001 then p.Size=Vector3.new(width,width,length); p.CFrame=CFrame.new((a+b)/2,b); p.Color=color end
    end
    local function electric_burst(state,points,color,duration,strength,width)
        if #state.bursts>=state.limit then table.remove(state.bursts,1).folder:Destroy() end
        local folder=Instance.new("Folder"); folder.Name="ElectricBurst"; folder.Parent=state.folder
        local segments={}
        for i=1,#points-1 do segments[i]={glow=electric_segment(folder,"Glow"),core=electric_segment(folder,"Core")} end
        state.bursts[#state.bursts+1]={folder=folder,segments=segments,points=points,born=os.clock(),duration=duration,color=color,strength=strength,width=width}
    end
    local function step_electric_bursts(state)
        for i=#state.bursts,1,-1 do
            local burst=state.bursts[i]; local age=os.clock()-burst.born
            if age>burst.duration then burst.folder:Destroy(); table.remove(state.bursts,i)
            else
                local fade=(1-age/burst.duration)*burst.strength
                for n,segment in ipairs(burst.segments) do
                    electric_line(segment.glow,burst.points[n],burst.points[n+1],burst.width*2.5,burst.color,fade*.5)
                    electric_line(segment.core,burst.points[n],burst.points[n+1],burst.width*.45,Color3.fromRGB(237,251,255),fade)
                end
            end
        end
    end
    add("lightning_footsteps","Lightning footsteps","Visual+","Brief electric cracks on the floor while your character moves",{start=function(scope)
        local folder=new_local(scope,"Folder",workspace); folder.Name="PivotLightningFootsteps"
        return {folder=folder,bursts={},limit=8,stride=0,side=-1,last=-10}
    end,step=function(_,state,settings)
        local r=root(); local now=os.clock()
        if not r then state.previous=nil; state.stride=0; step_electric_bursts(state); return end
        if state.previous then
            local delta=r.Position-state.previous
            if delta.Magnitude>10 then state.stride=0
            else state.stride=state.stride+Vector3.new(delta.X,0,delta.Z).Magnitude end
            if state.stride>=1.65 and now-state.last>.13 then
                state.stride=0; state.last=now; state.side=-state.side
                local origin=(r.CFrame*CFrame.new(state.side*.48,0,0)).Position
                local hit=electric_floor(origin,5.8,{state.folder})
                if hit then
                    local center=hit.Position+Vector3.new(0,.035,0); local points={}
                    for i=0,5 do points[#points+1]=center+Vector3.new((i/5-.5)*1.3*settings.footlight_size,0,(math.random()-.5)*.65*settings.footlight_size) end
                    electric_burst(state,points,cosmetic_color(settings.footlight_color),settings.footlight_duration,.9,.045*settings.footlight_size)
                end
            end
        end
        state.previous=r.Position; step_electric_bursts(state)
    end,interval=.025})
    add("electric_ball_trail","Electric ball trail","Visual+","Jagged fading bolts behind moving balls, including passes and shots",{start=function(scope)
        local folder=new_local(scope,"Folder",workspace); folder.Name="PivotElectricBallTrails"; return {folder=folder,balls={}}
    end,step=function(_,state,settings)
        local seen={}; local count=0; local now=os.clock(); local color=cosmetic_color(settings.ball_electric_color)
        for _,entry in ipairs(candidates("balls")) do
            local ball=entry.object
            if ball.Parent and not seen[ball] and count<8 then
                count=count+1; seen[ball]=true; local item=state.balls[ball]
                if not item then
                    local folder=Instance.new("Folder"); folder.Name="BallBolts"; folder.Parent=state.folder
                    item={folder=folder,points={},segments={}}; for n=1,7 do item.segments[n]={glow=electric_segment(folder,"TrailGlow"),core=electric_segment(folder,"TrailCore")} end
                    state.balls[ball]=item
                end
                local last=item.last_sample
                if last and (ball.Position-last).Magnitude>12 then item.points={} end
                if not last or (ball.Position-last).Magnitude>.05 then
                    table.insert(item.points,1,{position=ball.Position,time=now}); if #item.points>8 then table.remove(item.points) end
                    item.last_sample=ball.Position
                end
                for n=#item.points,1,-1 do if now-item.points[n].time>settings.ball_electric_duration then table.remove(item.points,n) end end
                for n,segment in ipairs(item.segments) do
                    local a,b=item.points[n],item.points[n+1]
                    if a and b then
                        local jitter=Vector3.new(math.sin(now*35+n)*.07,math.cos(now*29+n)*.07,0)
                        local opacity=math.max(0,1-(now-b.time)/settings.ball_electric_duration)
                        electric_line(segment.glow,a.position+jitter,b.position,settings.ball_electric_width*2.5,color,opacity*.5)
                        electric_line(segment.core,a.position+jitter,b.position,settings.ball_electric_width*.5,Color3.fromRGB(237,251,255),opacity)
                    else segment.glow.Transparency=1; segment.core.Transparency=1 end
                end
            end
        end
        for ball,item in pairs(state.balls) do if not seen[ball] then item.folder:Destroy(); state.balls[ball]=nil end end
    end,interval=.03})
    local function make_dunk_bolt(state,rim,settings)
        local hit=electric_floor(rim.Position,40,{state.folder,rim})
        if not hit then return false end
        local a=rim.Position; local b=hit.Position+Vector3.new(0,.04,0); local points={a}
        for i=1,7 do points[#points+1]=a+(b-a)*(i/8)+Vector3.new((math.random()-.5)*.9,0,(math.random()-.5)*.9) end
        points[#points+1]=b
        electric_burst(state,points,cosmetic_color(settings.dunk_lightning_color),settings.dunk_lightning_duration,settings.dunk_lightning_strength,.1)
        return true
    end
    add("dunk_lightning","Dunk lightning","Visual+","A rim-to-floor bolt on a nearby local dunk release; cosmetic animation detection",{start=function(scope)
        local folder=new_local(scope,"Folder",workspace); folder.Name="PivotDunkLightning"
        return {folder=folder,bursts={},limit=2,last=-10}
    end,step=function(_,state,settings)
        local a=client_attributes(); local r=root(); local now=os.clock()
        if a and r then
            if a.Action=="Dunking" and (not state.attempt or state.attempt.id~=a.ShotStartTime) then state.attempt={id=a.ShotStartTime,born=now,armed=a.ReleasedShot==false} end
            local attempt=state.attempt
            if attempt and attempt.armed and not attempt.done and a.ShotStartTime==attempt.id and a.ReleasedShot==true and now-attempt.born<3 and now-state.last>.6 then
                attempt.done=true
                local target,distance
                for _,rim in ipairs(collect_effect_rims()) do
                    local d=Vector3.new(rim.Position.X-r.Position.X,0,rim.Position.Z-r.Position.Z).Magnitude
                    if d<8 and math.abs(rim.Position.Y-r.Position.Y)<7 and (not distance or d<distance) then target=rim; distance=d end
                end
                if target and make_dunk_bolt(state,target,settings) then state.last=now end
            end
        end
        if state.attempt and now-state.attempt.born>3 then state.attempt=nil end
        step_electric_bursts(state)
    end,interval=.025})
    function Engine:preview_dunk_lightning()
        local state=assert(registry.active.dunk_lightning,"Enable Dunk lightning first").state
        local r=assert(root(),"Enter a court first"); local target,distance
        for _,rim in ipairs(collect_effect_rims()) do local d=(rim.Position-r.Position).Magnitude; if not distance or d<distance then target=rim; distance=d end end
        assert(target,"No rim is visible"); assert(make_dunk_bolt(state,target,self.settings),"No floor detected beneath the rim")
    end

    for key,value in pairs({cape_theme="Galaxy",cape_size=1,cape_length=1,cape_speed=1,cape_opacity=.95,tail_theme="Match cape",tail_shape="Soft",tail_length=3.5,tail_size=1,tail_speed=1.2,tail_sway=.6}) do s[key]=value end
    for key,value in pairs({cape_size={.6,1.5},cape_length={.7,1.5},cape_speed={.2,2},cape_opacity={.3,1},tail_length={2,5},tail_size={.5,1.6},tail_speed={.3,2.5},tail_sway={.1,1}}) do Engine.ranges[key]=value end
    local function fabric_color(theme,time,index)
        if theme=="Snow" then return Color3.fromRGB(175+index%3*15,209+index%3*10,245) end
        if theme=="Rainbow" then return Color3.fromRGB(155+95*math.sin(time+index*.4),155+95*math.sin(time+index*.4+2.1),155+95*math.sin(time+index*.4+4.2)) end
        return Color3.fromRGB(43+18*math.sin(time*.4+index*.3),32+18*math.sin(time*.3+index*.5),95+40*math.sin(time*.4+index*.2))
    end
    local function cape_palette(theme,time,index)
        if theme=="Rainbow" then
            return ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.fromRGB(255,102,138)),ColorSequenceKeypoint.new(.25,Color3.fromRGB(255,214,115)),ColorSequenceKeypoint.new(.5,Color3.fromRGB(111,230,180)),ColorSequenceKeypoint.new(.75,Color3.fromRGB(112,174,255)),ColorSequenceKeypoint.new(1,Color3.fromRGB(190,131,255))})
        end
        return ColorSequence.new({ColorSequenceKeypoint.new(0,fabric_color(theme,time,index)),ColorSequenceKeypoint.new(.5,theme=="Snow" and Color3.fromRGB(235,248,255) or Color3.fromRGB(101,57,147)),ColorSequenceKeypoint.new(1,theme=="Snow" and Color3.fromRGB(140,191,235) or Color3.fromRGB(28,49,94))})
    end
    add("animated_cape","Animated cape","Visual+","Moving Galaxy, Snow and Rainbow capes with layered cloth motion",{start=function(scope)
        local folder=new_local(scope,"Folder",workspace); folder.Name="PivotAnimatedCape"
        local panels={}
        for i=1,10 do
            local part=effect_part(scope,folder,"CapePanel"); local surfaces={}
            for _,face in ipairs({Enum.NormalId.Front,Enum.NormalId.Back}) do
                local surface=new_local(scope,"SurfaceGui",part); surface.Name="CapePattern"; surface.Face=face; surface.CanvasSize=Vector2.new(300,48); surface.LightInfluence=0; surface.AlwaysOnTop=false
                local fill=new_local(scope,"Frame",surface); fill.Size=UDim2.fromScale(1,1); fill.BackgroundColor3=Color3.fromRGB(255,255,255); fill.BorderSizePixel=0
                local gradient=new_local(scope,"UIGradient",fill)
                local particles={}
                for n=1,4 do
                    local dot=new_local(scope,"TextLabel",fill); dot.BackgroundTransparency=1; dot.Size=UDim2.fromOffset(18,18); dot.AnchorPoint=Vector2.new(.5,.5); dot.Font=Enum.Font.SourceSansBold; dot.TextColor3=Color3.fromRGB(234,246,255)
                    particles[n]=dot
                end
                surfaces[#surfaces+1]={gui=surface,fill=fill,gradient=gradient,particles=particles}
            end
            panels[i]={part=part,surfaces=surfaces}
        end
        return {panels=panels,motion=0}
    end,step=function(_,state,settings,dt)
        local model=rig(); local torso=model and (model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso") or root())
        local r=root(); local now=os.clock()*settings.cape_speed
        local speed=r and r.AssemblyLinearVelocity and r.AssemblyLinearVelocity.Magnitude or 0
        if r and state.position and dt and dt>0 then local distance=(r.Position-state.position).Magnitude; if distance<8 then speed=math.max(speed,distance/dt) end end
        state.position=r and r.Position; state.motion=state.motion+(math.min(1,speed/18)-state.motion)*(1-math.exp(-6*(dt or .03)))
        local pattern=state.theme~=settings.cape_theme or os.clock()>=(state.next_pattern or 0)
        if pattern then state.theme=settings.cape_theme; state.next_pattern=os.clock()+.08 end
        for i,panel in ipairs(state.panels) do
            local p=panel.part; local progress=i/10
            p.Transparency=torso and 1-settings.cape_opacity or 1
            if torso then
                local width=(2.25+progress*.7)*settings.cape_size; local length=.37*settings.cape_length
                p.Size=Vector3.new(width,length+.04,.045); p.Color=fabric_color(settings.cape_theme,now,i)
                local sway=math.sin(now*1.8-i*.35)*(.035+.12*progress); local billow=state.motion*progress*progress*.8
                p.CFrame=torso.CFrame*CFrame.new(sway,.75-i*length,.85+progress*.2+billow+math.sin(now*1.6-i*.3)*.06)*CFrame.Angles(-state.motion*progress*.35+math.sin(now*1.8-i*.3)*.045,0,sway*.12)
            end
            local palette=pattern and cape_palette(settings.cape_theme,now,i)
            for _,surface in ipairs(panel.surfaces) do
                surface.gui.Enabled=torso~=nil; surface.fill.BackgroundTransparency=1-settings.cape_opacity
                if pattern then
                surface.gradient.Color=palette; surface.gradient.Rotation=settings.cape_theme=="Rainbow" and 25+math.sin(now*.4)*20 or 35+math.sin(now*.2+i*.1)*15
                surface.gradient.Offset=Vector2.new(math.sin(now*.35)*.25,0)
                for n,dot in ipairs(surface.particles) do
                    local snow=settings.cape_theme=="Snow"; dot.Visible=settings.cape_theme~="Rainbow"
                    dot.Text=snow and "•" or "✦"; dot.TextSize=snow and 14 or 9+n%2*4
                    dot.Position=UDim2.fromScale(((n*.217+i*.173)+(snow and math.sin(now*.6+n)*.03 or now*.005))%1,(n*.28+i*.19+(snow and now*.3 or 0))%1)
                    dot.TextTransparency=snow and .1 or .25+math.sin(now*1.6+n+i)*.25
                end
                end
            end
        end
    end,interval=.03})
    add("animated_tail","Animated tail","Visual+","A smooth tapered tail with movement sway and matching cape themes",{start=function(scope)
        local folder=new_local(scope,"Folder",workspace); folder.Name="PivotAnimatedTail"
        local parts={}
        for i=1,16 do local p=effect_part(scope,folder,"TailSegment"); local mesh=new_local(scope,"SpecialMesh",p); mesh.MeshType=Enum.MeshType.Sphere; parts[i]=p end
        return {parts=parts,motion=0}
    end,step=function(_,state,settings,dt)
        local model=rig(); local torso=model and (model:FindFirstChild("LowerTorso") or model:FindFirstChild("Torso") or root())
        local r=root(); local speed=r and r.AssemblyLinearVelocity and r.AssemblyLinearVelocity.Magnitude or 0
        state.motion=state.motion+(math.min(1,speed/18)-state.motion)*(1-math.exp(-6*(dt or .03)))
        local theme=settings.tail_theme=="Match cape" and settings.cape_theme or settings.tail_theme
        local now=os.clock()*settings.tail_speed
        local function point(t)
            return Vector3.new(math.sin(now*1.8-t*2.6)*settings.tail_sway*t,-math.sin(t*math.pi)*.6+t*.45,t*settings.tail_length+state.motion*t*.25)
        end
        for i,p in ipairs(state.parts) do
            p.Transparency=torso and .02 or 1
            if torso then
                local mount=torso.CFrame*CFrame.new(0,-.8,.7); local a=(mount*CFrame.new(point((i-1)/16))).Position; local b=(mount*CFrame.new(point(i/16))).Position
                local thickness=(settings.tail_shape=="Soft" and .36 or .16)*(1-i/16*.8)*settings.tail_size
                p.Size=Vector3.new(thickness,thickness,(b-a).Magnitude+.07); p.CFrame=CFrame.new((a+b)/2,b); p.Color=fabric_color(theme,now,i)
                if theme=="Snow" and i>=12 then p.Color=Color3.fromRGB(236,248,255) end
                p.Material=theme=="Rainbow" and Enum.Material.Neon or Enum.Material.SmoothPlastic
            end
        end
    end,interval=.03})

    for key,value in pairs({reactive_idle_color="#B8A7F6",reactive_move_color="#82CFFF",reactive_ball_color="#FFCC78",reactive_perfect_color="#87F6BE",reactive_miss_color="#FF8E9B",reactive_speed=14,reactive_response=8,reactive_flash=.8,reactive_tint=.55,reactive_motion=true,reactive_possession=true,reactive_shots=true,reactive_clothes=true,reactive_effects=true}) do s[key]=value end
    for key,value in pairs({reactive_speed={4,30},reactive_response={2,20},reactive_flash={.2,2},reactive_tint={.1,1}}) do Engine.ranges[key]=value end
    local function reaction_mix(a,b,t) return Color3.new(a.R+(b.R-a.R)*t,a.G+(b.G-a.G)*t,a.B+(b.B-a.B)*t) end
    function Engine:reactive_outfit_color(fallback)
        local active=registry.active.reactive_outfit
        return active and s.reactive_effects and active.state.color or cosmetic_color(fallback)
    end
    function Engine:reactive_feedback(event)
        local active=registry.active.reactive_outfit
        if active and s.reactive_shots and event.kind=="feedback" and type(event.code)=="number" then
            active.state.flash_until=os.clock()+s.reactive_flash
            active.state.flash=event.code==5 and "Perfect" or "Feedback"
        end
    end
    add("reactive_outfit","Reactive outfit","Visual+","Clothing, wings, aura and lightning colors react to movement, possession and observed shot feedback",{start=function()
        return {color=cosmetic_color(s.reactive_idle_color),mode="Idle",flash_until=0,garments={}}
    end,step=function(scope,state,settings,dt)
        local model=rig(); local r=root(); local speed=0
        if r then
            local velocity=r.AssemblyLinearVelocity
            if velocity then speed=Vector3.new(velocity.X,0,velocity.Z).Magnitude end
            if state.previous and dt>0 then local delta=r.Position-state.previous; if delta.Magnitude<8 then speed=math.max(speed,Vector3.new(delta.X,0,delta.Z).Magnitude/dt) end end
            state.previous=r.Position
        else state.previous=nil end
        local mode="Idle"; local color=cosmetic_color(settings.reactive_idle_color)
        if settings.reactive_motion and speed>.5 then
            mode="Moving"; color=reaction_mix(color,cosmetic_color(settings.reactive_move_color),math.min(1,speed/settings.reactive_speed))
        end
        if settings.reactive_possession and held_ball(model) then mode="Possession"; color=cosmetic_color(settings.reactive_ball_color) end
        if settings.reactive_shots and os.clock()<state.flash_until then mode=state.flash; color=cosmetic_color(mode=="Perfect" and settings.reactive_perfect_color or settings.reactive_miss_color) end
        state.mode=mode; state.color=reaction_mix(state.color,color,1-math.exp(-settings.reactive_response*dt))
        local found={}
        if model then for _,object in ipairs(model:GetDescendants()) do
            if object:IsA("Shirt") or object:IsA("Pants") then
                local tint=registry.active.outfit_tint
                if settings.reactive_clothes and tint then tint.scope:restore(object,"Color3") end
                found[object]=true; local base=state.garments[object] or object.Color3 or Color3.new(1,1,1); state.garments[object]=base
                if settings.reactive_clothes then scope:set(object,"Color3",reaction_mix(base,state.color,settings.reactive_tint)) else scope:restore(object,"Color3") end
            end
        end end
        for object in pairs(state.garments) do if not found[object] then scope:restore(object,"Color3"); state.garments[object]=nil end end
    end,interval=.04})

    --[[Xbox illustration: NPException/GamePadView/assets/xbox/xbox-controller-clipart-xl.png
    Original art credited by that repository to https://creazilla.com/media/clipart/1631895/xbox-controller
    MIT License
Copyright (c) 2025 NPException
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    ]]
    local controller_image_data="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"
    function Engine:controller_image()
        if self.controller_image_cache then return self.controller_image_cache end
        local load_asset=type(getcustomasset)=="function" and getcustomasset or type(getsynasset)=="function" and getsynasset
        if not load_asset or type(writefile)~="function" then return nil end
        local alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; local values={}
        for i=1,#alphabet do values[alphabet:sub(i,i)]=i-1 end
        local bytes={}; local number,bits=0,0
        for i=1,#controller_image_data do local value=values[controller_image_data:sub(i,i)]; if value then
            number=number*64+value; bits=bits+6
            if bits>=8 then bits=bits-8; local divisor=2^bits; bytes[#bytes+1]=string.char(math.floor(number/divisor)%256); number=number%divisor end
        end end
        local path="Pivot_Xbox_Controller_v1.png"; local ok,asset=pcall(function() writefile(path,table.concat(bytes)); return load_asset(path) end)
        if ok and type(asset)=="string" and asset~="" then self.controller_image_cache=asset; return asset end
        return nil
    end

    s.controller_scale=.85; s.controller_opacity=.95; s.controller_top=12
    Engine.ranges.controller_scale={.6,1.4}; Engine.ranges.controller_opacity={.3,1}; Engine.ranges.controller_top={0,180}
    add("controller_hud","Controller input","Visual+","A live controller at the top of the screen; reads buttons, sticks and trigger pressure without consuming inputs",{start=function(scope)
        local palette={base=Color3.fromRGB(17,17,24),body=Color3.fromRGB(34,34,47),line=Color3.fromRGB(66,62,86),muted=Color3.fromRGB(143,140,163),accent=Color3.fromRGB(184,167,246),text=Color3.fromRGB(235,231,249)}
        local function make(class,props,parent) local object=Instance.new(class); for key,value in pairs(props) do object[key]=value end; object.Parent=parent; return object end
        local function round(object,radius) make("UICorner",{CornerRadius=UDim.new(0,radius)},object); return object end
        local function box(name,x,y,w,h,color,parent)
            return round(make("Frame",{Name=name,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),BackgroundColor3=color or palette.body,BorderSizePixel=0},parent),math.min(w,h)/3)
        end
        local panel=box("PivotControllerInput",0,0,252,196,palette.base,ctx.gui); panel.AnchorPoint=Vector2.new(.5,0); panel.Position=UDim2.new(.5,0,0,s.controller_top); panel.Active=false
        panel.BackgroundTransparency=1
        local scale=make("UIScale",{Scale=s.controller_scale},panel)
        scope:defer(function() panel:Destroy() end)
        local state={panel=panel,scale=scale,values={},buttons={},sticks={},triggers={},connected=false,pad=Enum.UserInputType.Gamepad1}
        local function text(parent,name,value,x,y,w,h,size,color)
            return make("TextLabel",{Name=name,Text=value,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),BackgroundTransparency=1,TextColor3=color or palette.muted,TextSize=size or 12,Font=Enum.Font.SourceSansSemibold},parent)
        end
        local asset=Engine:controller_image()
        if asset then
            state.image=make("ImageLabel",{Name="XboxControllerImage",Image=asset,BackgroundTransparency=1,Position=UDim2.fromOffset(10,16),Size=UDim2.fromOffset(232,159.26),ScaleType=Enum.ScaleType.Stretch},panel)
        else
            box("ControllerBody",25,34,202,86,palette.body,panel)
            local left=box("LeftGrip",26,93,48,65,palette.body,panel); left.Rotation=22
            local right=box("RightGrip",178,93,48,65,palette.body,panel); right.Rotation=-22
        end
        local function button(key,caption,x,y,w,h,color,radius)
            local part=box(key,x,y,w,h,palette.base,panel); round(part,radius or math.min(w,h)/2)
            local label=text(part,"Caption",caption,0,0,w,h,12,palette.text)
            state.buttons[key]={part=part,label=label,color=color}; return part
        end
        button("ButtonL1","LB",43,20,46,10); button("ButtonR1","RB",163,20,46,10)
        for _,entry in ipairs({{"ButtonL2","LT",43},{"ButtonR2","RT",163}}) do
            local track=box(entry[1],entry[3],2,46,12,palette.body,panel)
            local fill=box("Pressure",0,0,0,12,palette.accent,track); text(track,"Caption",entry[2],0,-1,46,14,11,palette.text); state.triggers[entry[1]]=fill
        end
        for _,entry in ipairs({{"ButtonY","Y",176,36,Color3.fromRGB(244,203,57)},{"ButtonX","X",160,52,Color3.fromRGB(69,160,237)},{"ButtonB","B",193,53,Color3.fromRGB(236,79,79)},{"ButtonA","A",176,68,Color3.fromRGB(99,196,89)}}) do button(entry[1],entry[2],entry[3],entry[4],17,17,entry[5]) end
        for _,entry in ipairs({{"DPadUp","",89,83},{"DPadLeft","",78,94},{"DPadRight","",100,94},{"DPadDown","",89,105}}) do button(entry[1],entry[2],entry[3],entry[4],11,11,nil,2) end
        button("ButtonSelect","▢",102,55,11,11); button("ButtonStart","≡",136,55,11,11)
        local guide=box("XboxGuide",115,29,20,20,Color3.fromRGB(207,209,211),panel); round(guide,10)
        text(guide,"Logo","X",0,0,20,20,16,Color3.fromRGB(28,30,31))
        for _,entry in ipairs({{"Thumbstick1","ButtonL3",51,44},{"Thumbstick2","ButtonR3",140,82}}) do
            local well=box(entry[1],entry[3],entry[4],30,30,palette.base,panel); round(well,15)
            local knob=box("Stick",7,7,16,16,palette.muted,well); round(knob,8)
            state.sticks[entry[1]]={knob=knob,click=entry[2]}
        end
        state.caption=text(panel,"Connection","NO CONTROLLER",0,178,252,16,11,palette.muted)
        local function reset() state.values={}; state.connected=false end
        local function receive(event,ended)
            local kind=event.UserInputType and event.UserInputType.Name or ""
            if not kind:match("^Gamepad[1-8]$") then return end
            if event.UserInputType~=state.pad then reset(); state.pad=event.UserInputType end
            state.connected=true
            local key=event.KeyCode and event.KeyCode.Name
            if key=="Thumbstick1" or key=="Thumbstick2" then
                local p=not ended and event.Position or Vector3.zero
                state.values[key]={x=math.max(-1,math.min(1,p and p.X or 0)),y=math.max(-1,math.min(1,p and p.Y or 0))}
            elseif key=="ButtonL2" or key=="ButtonR2" then state.values[key]=ended and 0 or math.max(0,math.min(1,event.Position and event.Position.Z or 1))
            elseif state.buttons[key] or key=="ButtonL3" or key=="ButtonR3" then state.values[key]=not ended end
        end
        local function listen(signal,callback) if signal and signal.Connect then local link=signal:Connect(callback); scope:defer(function() link:Disconnect() end) end end
        listen(input.InputBegan,function(event) receive(event,false) end)
        listen(input.InputChanged,function(event) receive(event,false) end)
        listen(input.InputEnded,function(event) receive(event,true) end)
        listen(input.GamepadDisconnected,function(pad) if pad==state.pad then reset() end end)
        listen(input.GamepadConnected,function(pad) if not state.connected then reset(); state.pad=pad; state.connected=true end end)
        listen(input.WindowFocusReleased,function() state.values={} end)
        pcall(function()
            local pads=input:GetConnectedGamepads(); if #pads>0 then state.pad=pads[1]; state.connected=true
                for _,event in ipairs(input:GetGamepadState(state.pad)) do receive(event,event.UserInputState~=Enum.UserInputState.Begin and event.UserInputState~=Enum.UserInputState.Change) end
            end
        end)
        function state.draw(settings)
            local camera=workspace.CurrentCamera; local width=camera and camera.ViewportSize.X or 800
            scale.Scale=math.min(settings.controller_scale,math.max(.4,(width-16)/252)); panel.Position=UDim2.new(.5,0,0,settings.controller_top); panel.BackgroundTransparency=1; if state.image then state.image.ImageTransparency=1-settings.controller_opacity end
            state.caption.Text=state.connected and "" or "NO CONTROLLER"
            for key,item in pairs(state.buttons) do local on=state.connected and state.values[key]; item.part.BackgroundColor3=on and (item.color or palette.accent) or palette.base; item.label.TextColor3=on and palette.base or item.color or palette.text end
            for key,fill in pairs(state.triggers) do fill.Size=UDim2.new(state.connected and (state.values[key] or 0) or 0,0,1,0) end
            for key,item in pairs(state.sticks) do
                local value=state.connected and state.values[key] or nil; local x,y=value and value.x or 0,value and value.y or 0
                local length=math.sqrt(x*x+y*y); if length>1 then x=x/length; y=y/length end
                item.knob.Position=UDim2.fromOffset(7+x*7,7-y*7); item.knob.BackgroundColor3=state.values[item.click] and palette.accent or palette.muted
            end
        end
        state.draw(s); return state
    end,step=function(_,state,settings) state.draw(settings) end,interval=.02})

    Engine.cosmetic_loadouts={version=1,loadouts={}}
    Engine.settings.cosmetic_loadout_name="My look"
    local look_modules={crosshair=true,ball_trail=true,player_trail=true,ball_appearance=true,court_appearance=true,self_outline=true,sky=true,custom_model=true,coverage_hud=true,player_indicator=true,shoe_effects=true,outfit_tint=true,lighting_preset=true,green_effect=true,wings=true,character_aura=true,ball_impacts=true,wing_trails=true,rim_effects=true,lightning_aura=true,meter_style=true,hide_meters=true}
    local look_defaults={}
    look_modules.lightning_footsteps=true; look_modules.electric_ball_trail=true; look_modules.dunk_lightning=true
    look_modules.animated_cape=true; look_modules.animated_tail=true; look_modules.reactive_outfit=true; look_modules.controller_hud=true
    local prefixes={"ball_","court_","model_","wings_","aura_","lightning_","wing_trail_","rim_","impact_","indicator_","shoe_","jersey_","outfit_","sky_","outline_","player_trail_","crosshair_","coverage_"}
    local look_extra={lighting_preset=true,lighting_intensity=true,effect_strength=true,green_style=true,green_color=true,green_duration=true,meter_style=true,shot_hud=true,shot_hud_compact=true}
    prefixes[#prefixes+1]="footlight_"; prefixes[#prefixes+1]="dunk_lightning_"
    prefixes[#prefixes+1]="cape_"; prefixes[#prefixes+1]="tail_"; prefixes[#prefixes+1]="reactive_"; prefixes[#prefixes+1]="controller_"
    for key,value in pairs(Engine.settings) do
        local include=look_extra[key]
        for _,prefix in ipairs(prefixes) do if key:sub(1,#prefix)==prefix then include=true end end
        if include and key~="ball_handler_only" then look_defaults[key]=value end
    end
    function Engine:validate_cosmetic_loadouts(data)
        assert(type(data)=="table" and data.version==1 and type(data.loadouts)=="table","Invalid cosmetic loadouts")
        local count=0; for key in pairs(data.loadouts) do assert(type(key)=="number" and key>=1 and key%1==0,"Loadouts must be a list"); count=count+1 end
        assert(count<=16,"Up to 16 cosmetic loadouts are supported")
        local result={version=1,loadouts={}}; local names={}
        for i=1,count do
            local item=data.loadouts[i]
            assert(type(item)=="table" and type(item.name)=="string" and #item.name>=1 and #item.name<=40 and item.name:find("%S") and not item.name:find("[%c]") and not names[item.name:lower()],"Invalid or duplicate look name")
            assert(type(item.enabled)=="table","Invalid cosmetic module list")
            local enabled={}; local total=0
            for key,id in pairs(item.enabled) do
                assert(type(key)=="number" and key>=1 and key%1==0 and type(id)=="string" and look_modules[id] and registry.definitions[id] and not enabled[id],"Invalid cosmetic module")
                enabled[id]=true; total=total+1
            end
            assert(total<=32,"Too many cosmetic modules")
            for n=1,total do assert(item.enabled[n],"Cosmetic modules must be a contiguous list") end
            assert(not enabled.wing_trails or enabled.wings,"Wing-tip trails require Wings in this look")
            for id in pairs(enabled) do for _,other in ipairs(registry.definitions[id].conflicts or {}) do assert(not enabled[other],"Conflicting cosmetic modules") end end
            local settings,err=Core.validate_module_settings(item.settings or {},look_defaults,self.ranges); assert(settings,err)
            local ids={}; for _,definition in ipairs(self.definitions) do if enabled[definition.id] then ids[#ids+1]=definition.id end end
            names[item.name:lower()]=true; result.loadouts[i]={name=item.name,enabled=ids,settings=settings}
        end
        return result
    end
    function Engine:write_cosmetic_loadouts()
        assert(type(writefile)=="function" and type(readfile)=="function","Cosmetic file storage unavailable")
        local value=self:validate_cosmetic_loadouts(self.cosmetic_loadouts)
        local raw=game:GetService("HttpService"):JSONEncode(value)
        writefile("pivot_cosmetic_loadouts.json",raw)
        assert(readfile("pivot_cosmetic_loadouts.json")==raw,"Cosmetic loadout file verification failed")
    end
    function Engine:read_cosmetic_loadouts()
        assert(type(readfile)=="function","Cosmetic file reading unavailable")
        local raw=readfile("pivot_cosmetic_loadouts.json"); assert(type(raw)=="string" and #raw<=262144,"Cosmetic loadout file exceeds 256 KB")
        self.cosmetic_loadouts=self:validate_cosmetic_loadouts(game:GetService("HttpService"):JSONDecode(raw))
        return #self.cosmetic_loadouts.loadouts
    end
    function Engine:save_cosmetic_loadout(name)
        name=tostring(name or ""):match("^%s*(.-)%s*$"); if name=="" then name="My look" end
        local item={name=name,enabled={},settings={}}
        for _,definition in ipairs(self.definitions) do if look_modules[definition.id] and registry.active[definition.id] then item.enabled[#item.enabled+1]=definition.id end end
        for key in pairs(look_defaults) do item.settings[key]=self.settings[key] end
        local data={version=1,loadouts={}}; local replaced=false
        for i,old in ipairs(self.cosmetic_loadouts.loadouts) do if old.name:lower()==name:lower() then data.loadouts[i]=item; replaced=true else data.loadouts[i]=old end end
        if not replaced then data.loadouts[#data.loadouts+1]=item end
        self.cosmetic_loadouts=self:validate_cosmetic_loadouts(data)
        local ok,err=pcall(function() self:write_cosmetic_loadouts() end)
        self.cosmetic_loadout_status="Saved "..name.." / "..#item.enabled.." cosmetics"..(ok and " / file verified" or " / session only: "..tostring(err))
        ctx.report(self.cosmetic_loadout_status); return #item.enabled
    end
    function Engine:load_cosmetic_loadout(index)
        local data=self:validate_cosmetic_loadouts(self.cosmetic_loadouts); local item=assert(data.loadouts[index],"Cosmetic loadout not found")
        -- Only cosmetic modules and appearance settings are touched.
        for id in pairs(look_modules) do registry:disable(id) end
        for key,value in pairs(item.settings) do self.settings[key]=value end
        local count,failures=0,{}
        for _,id in ipairs(item.enabled) do
            local ok,err=registry:enable(id,self.settings)
            if ok then count=count+1 else failures[#failures+1]=registry.definitions[id].title..": "..tostring(err) end
        end
        self.settings.cosmetic_loadout_name=item.name
        self.cosmetic_loadout_status="Loaded "..item.name.." / "..count.." of "..#item.enabled.." cosmetics"..(#failures>0 and " / Failed: "..table.concat(failures,"; ") or "")
        ctx.report(self.cosmetic_loadout_status); return count,failures
    end
    function Engine:remove_cosmetic_loadout(index)
        assert(self.cosmetic_loadouts.loadouts[index],"Cosmetic loadout not found"); table.remove(self.cosmetic_loadouts.loadouts,index)
        local ok,err=pcall(function() self:write_cosmetic_loadouts() end)
        self.cosmetic_loadout_status="Removed cosmetic loadout"..(ok and "" or " / session only: "..tostring(err)); ctx.report(self.cosmetic_loadout_status)
    end
    if type(readfile)=="function" then pcall(function() Engine:read_cosmetic_loadouts() end) end

    Engine.shot_stats={total=0,perfect=0,good=0,early=0,late=0,skipped=0,releases=0,unconfirmed=0,last="Waiting for a shot",history={}}
    function Engine:record_shot(event)
        if self.visual_feedback then self:visual_feedback(event) end
        if self.reactive_feedback then self:reactive_feedback(event) end
        local stats=self.shot_stats; local kind=event.kind
        if kind=="feedback" then
            stats.total=stats.total+1
            if event.code==5 then stats.perfect=stats.perfect+1; stats.last="Perfect · timing retained"
            elseif event.code==4 then stats.good=stats.good+1; stats.last=event.locked and "Good · keeping established timing" or self.settings.practice_refinement and "Good · refining nearby timing" or "Good · timing retained"
            elseif event.code<=3 then stats.early=stats.early+1; stats.last="Early · next release later"
            else stats.late=stats.late+1; stats.last="Late · next release earlier" end
            if not self.settings.auto_calibrate and event.code~=5 then stats.last=(event.code<=3 and "Early" or event.code>=6 and "Late" or "Good").." · auto correct off" end
        elseif kind=="skip" then stats.skipped=stats.skipped+1; stats.last=event.reason
        elseif kind=="release" then stats.releases=stats.releases+1; stats.last="Released · awaiting game feedback"
        elseif kind=="unconfirmed" then stats.unconfirmed=stats.unconfirmed+1; stats.last="No feedback received for an auto release"
        elseif kind=="refinement" then stats.last=event.reason end
        local entry={kind=kind,code=event.code,shot=event.shot,name=event.name,reason=event.reason,ratio=event.ratio,position=event.position,speed=event.speed,details=event.details,time=os.clock()}
        stats.history[#stats.history+1]=entry; if #stats.history>100 then table.remove(stats.history,1) end
    end
    function Engine:attach_shot_hud(scope)
        local panel=Instance.new("Frame"); panel.Name="PivotShotStats"; panel.AnchorPoint=Vector2.new(1,0); panel.Position=UDim2.new(1,-18,0,18); panel.Size=UDim2.fromOffset(292,116); panel.BackgroundColor3=Color3.fromRGB(20,24,30); panel.BackgroundTransparency=.06; panel.BorderSizePixel=0; panel.Parent=ctx.gui
        local corner=Instance.new("UICorner"); corner.CornerRadius=UDim.new(0,8); corner.Parent=panel
        local stroke=Instance.new("UIStroke"); stroke.Color=Color3.fromRGB(49,57,69); stroke.Thickness=1; stroke.Parent=panel
        local function text(name,value,x,y,width,height,size,color)
            local label=Instance.new("TextLabel"); label.Name=name; label.Text=value; label.Position=UDim2.fromOffset(x,y); label.Size=UDim2.fromOffset(width,height); label.BackgroundTransparency=1; label.TextColor3=color; label.TextSize=size; label.Font=Enum.Font.SourceSans; label.TextXAlignment=Enum.TextXAlignment.Left; label.TextWrapped=false; label.TextTruncate=Enum.TextTruncate.AtEnd; label.Parent=panel; return label
        end
        local title=text("Title","SHOOTING",14,8,210,18,12,Color3.fromRGB(154,166,183)); title.Font=Enum.Font.SourceSansSemibold
        local rate=text("Rate","--",14,26,120,32,30,Color3.fromRGB(237,242,247)); rate.Font=Enum.Font.SourceSansSemibold
        local count=text("Confirmed","0 / 0 perfect",146,33,130,22,14,Color3.fromRGB(170,182,199))
        local track=Instance.new("Frame"); track.Position=UDim2.fromOffset(14,62); track.Size=UDim2.new(1,-28,0,3); track.BackgroundColor3=Color3.fromRGB(41,48,59); track.BorderSizePixel=0; track.Parent=panel
        local fill=Instance.new("Frame"); fill.Name="PerfectBar"; fill.Size=UDim2.fromScale(0,1); fill.BackgroundColor3=Color3.fromRGB(147,189,165); fill.BorderSizePixel=0; fill.Parent=track
        local result=text("Result","Waiting for a shot",14,72,264,18,14,Color3.fromRGB(218,226,236))
        local details=text("Details","Skipped 0    Unconfirmed 0",14,94,264,16,12,Color3.fromRGB(142,156,176))
        local collapse=Instance.new("TextButton"); collapse.Name="Collapse"; collapse.Position=UDim2.new(1,-32,0,5); collapse.Size=UDim2.fromOffset(25,25); collapse.BackgroundTransparency=1; collapse.Text="−"; collapse.TextColor3=Color3.fromRGB(170,182,199); collapse.TextSize=21; collapse.Font=Enum.Font.SourceSans; collapse.Parent=panel
        scope:defer(function() panel:Destroy() end)
        local function update()
            local stats=self.shot_stats; local ratio=stats.total>0 and stats.perfect/stats.total or 0
            local percentage=stats.total>0 and string.format("%.1f%%",ratio*100) or "--"
            local compact=self.settings.shot_hud_compact
            panel.Visible=self.settings.shot_hud; panel.Size=UDim2.fromOffset(compact and 210 or 292,compact and 36 or 116)
            title.Text=compact and "Shooting  ·  "..percentage or "SHOOTING"; title.Size=UDim2.fromOffset(compact and 166 or 210,18); title.TextSize=compact and 14 or 12
            collapse.Text=compact and "+" or "−"
            for _,object in ipairs({rate,count,track,result,details}) do object.Visible=not compact end
            rate.Text=percentage; count.Text=stats.perfect.." / "..stats.total.." perfect"; fill.Size=UDim2.fromScale(math.max(0,math.min(1,ratio)),1)
            result.Text=stats.last; details.Text="Skipped "..stats.skipped.."    Unconfirmed "..stats.unconfirmed
        end
        local click=collapse.Activated:Connect(function() self.settings.shot_hud_compact=not self.settings.shot_hud_compact; update() end); scope:defer(function() click:Disconnect() end)
        local elapsed=0; local connection=run.Heartbeat:Connect(function(dt) elapsed=elapsed+dt; if elapsed>=.1 then elapsed=0; update() end end)
        scope:defer(function() connection:Disconnect() end); update()
    end

    Engine.emit=emit; Engine.held=held
    function Engine:stop()
        self.registry:stop_all(); for _,owner in pairs(held) do release_owned(owner) end
        self.capturing=false; self.pending_move=nil
        if next(held) then ctx.report("Input release pending / press F8 to retry") end
        return next(held)==nil
    end
    function Engine:close() self.library_closed=true; self:stop(); self.registry:close(); if self.clear_model_cache then self:clear_model_cache() end end
    function Engine:stop_controls()
        -- Auto Green pauses through adapter.paused while typing, retaining its toggle and profiles.
        for _,id in ipairs({"auto_sprint","guard","block","rebound","fly","spin"}) do self.registry:disable(id) end
        for _,owner in pairs(held) do release_owned(owner) end
        self.capturing=false
    end
    local original_start=ctx.runner.start
    function ctx.runner:start(action,done)
        for _,owner in pairs(held) do release_owned(owner) end
        if next(held) then return false,"Module key release pending; press F8" end
        return original_start(self,action,done)
    end
    Engine.saved_modules={version=1,presets={}}
    local preset_defaults={}; for key,value in pairs(Engine.settings) do preset_defaults[key]=value end
    local function capture_modules(name)
        local value={name=name,enabled={},settings={}}
        for _,definition in ipairs(Engine.definitions) do if registry.active[definition.id] then value.enabled[#value.enabled+1]=definition.id end end
        for key in pairs(preset_defaults) do value.settings[key]=Engine.settings[key] end
        return value
    end
    function Engine:capture_enabled_modules() return capture_modules("Favorites") end
    function Engine:validate_saved_modules(data)
        if type(data)~="table" or data.version~=1 or type(data.presets)~="table" then return nil,"Invalid saved modules file" end
        local count=0; for key in pairs(data.presets) do if type(key)~="number" or key<1 or key%1~=0 then return nil,"Presets must be a list" end; count=count+1 end
        if count>16 then return nil,"Up to 16 module presets are supported" end
        local valid={version=1,presets={}}; local names={}
        for i=1,count do
            local item=data.presets[i]
            if type(item)~="table" or type(item.name)~="string" or #item.name<1 or #item.name>40 or not item.name:find("%S") or item.name:find("[%c]") or names[item.name:lower()] then return nil,"Invalid or duplicate preset name" end
            local settings,err=Core.validate_module_settings(item.settings or {},preset_defaults,self.ranges); if not settings then return nil,err end
            if settings.theme_mode~="Graphite" and settings.theme_mode~="Slate" and settings.theme_mode~="Light" then return nil,"Invalid theme" end
            if type(item.enabled)~="table" then return nil,"Enabled modules must be a list" end
            local enabled={}; local total=0
            for key in pairs(item.enabled) do if type(key)~="number" or key<1 or key%1~=0 then return nil,"Enabled modules must be a list" end; total=total+1 end
            if total>#self.definitions then return nil,"Too many enabled modules" end
            for n=1,total do local id=item.enabled[n]; if type(id)~="string" or not registry.definitions[id] or enabled[id] then return nil,"Unknown or duplicate module" end; enabled[id]=true end
            for id in pairs(enabled) do for _,other in ipairs(registry.definitions[id].conflicts or {}) do if enabled[other] then return nil,"Conflicting saved modules: "..id.." / "..other end end end
            local ids={}; for _,definition in ipairs(self.definitions) do if enabled[definition.id] then ids[#ids+1]=definition.id end end
            names[item.name:lower()]=true; valid.presets[i]={name=item.name,enabled=ids,settings=settings}
        end
        return valid
    end
    function Engine:write_saved_modules()
        assert(type(writefile)=="function","File saving unavailable")
        local value,err=self:validate_saved_modules(self.saved_modules); assert(value,err)
        writefile("pivot_saved_modules.json",game:GetService("HttpService"):JSONEncode(value))
        assert(type(readfile)=="function","Cannot verify saved file: readfile unavailable")
        local stored,reason=self:validate_saved_modules(game:GetService("HttpService"):JSONDecode(readfile("pivot_saved_modules.json")))
        assert(stored,reason)
        local function equal(a,b)
            if type(a)~=type(b) then return false end
            if type(a)~="table" then return a==b end
            for key,item in pairs(a) do if not equal(item,b[key]) then return false end end
            for key in pairs(b) do if a[key]==nil then return false end end
            return true
        end
        assert(equal(value,stored),"Saved file did not retain the current presets")
    end
    function Engine:read_saved_modules()
        assert(type(readfile)=="function","File loading unavailable")
        local raw=readfile("pivot_saved_modules.json"); assert(type(raw)=="string" and #raw<=262144,"Saved modules file exceeds 256 KB")
        local value,err=self:validate_saved_modules(game:GetService("HttpService"):JSONDecode(raw)); assert(value,err)
        self.saved_modules=value; return #value.presets
    end
    function Engine:save_enabled_modules(name)
        name=tostring(name or ""):match("^%s*(.-)%s*$"); if name=="" then name="Favorites" end
        local captured=capture_modules(name)
        assert(#captured.enabled>0,"No modules are enabled. Turn on the modules you want, then save again")
        local item={name=name,enabled=captured.enabled,settings=captured.settings}; local value={version=1,presets={}}; local replaced=false
        for i,old in ipairs(self.saved_modules.presets) do if old.name:lower()==name:lower() then value.presets[i]=item; replaced=true else value.presets[i]=old end end
        if not replaced then value.presets[#value.presets+1]=item end
        local valid,err=self:validate_saved_modules(value); assert(valid,err); self.saved_modules=valid
        local ok,failure=pcall(function() self:write_saved_modules() end)
        self.module_preset_status="Saved "..#item.enabled.." modules: "..name..(ok and " / file verified" or " / session only: "..tostring(failure))
        ctx.report(self.module_preset_status); return #item.enabled
    end
    function Engine:load_saved_modules(index)
        local data,err=self:validate_saved_modules(self.saved_modules); assert(data,err)
        local item=assert(data.presets[index],"Saved module preset not found")
        assert(#item.enabled>0,"This preset is empty. Enable the modules you want and save it again")
        return self:load_module_snapshot(item)
    end
    function Engine:load_module_snapshot(snapshot)
        local data,err=self:validate_saved_modules({version=1,presets={snapshot}}); assert(data,err)
        local item=data.presets[1]
        assert(ctx.runner:cancel(),"Input release pending; press F8 and retry")
        assert(self:stop(),"Input release pending; press F8 and retry")
        for key,value in pairs(item.settings) do self.settings[key]=value end
        local loaded,failures=0,{}
        for _,id in ipairs(item.enabled) do
            local ok,failure=registry:enable(id,self.settings)
            if not ok then
                failures[#failures+1]=registry.definitions[id].title..": "..tostring(failure)
            else loaded=loaded+1 end
        end
        self.settings.module_preset_name=item.name
        self.module_preset_status="Loaded "..item.name.." / "..loaded.." of "..#item.enabled.." enabled"..(#failures>0 and " / Failed: "..table.concat(failures,"; ") or "")
        ctx.report(self.module_preset_status); return loaded,failures
    end
    function Engine:remove_saved_modules(index)
        assert(self.saved_modules.presets[index],"Preset not found"); table.remove(self.saved_modules.presets,index)
        local ok=pcall(function() self:write_saved_modules() end); ctx.report(ok and "Removed module preset" or "Removed preset for this session")
    end
    if type(readfile)=="function" then pcall(function() Engine:read_saved_modules() end) end

    local last_rig=rig()
    ctx.connect(run.Heartbeat,function(dt)
        local current=rig(); if current~=last_rig then
            local ids={}; for id in pairs(registry.active) do if id~="meter_release" then ids[#ids+1]=id end end
            for _,id in ipairs(ids) do registry:disable(id) end
            last_rig=current
        end
        registry:step(dt)
    end)
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
local module_profiles = {}
local restored = "Session profiles"
if disk_read then
    local ok, data = pcall(function()
        local raw=readfile(file); assert(#raw<=262144, "Profile file is too large."); return http:JSONDecode(raw)
    end)
    if ok and type(data)=="table" and data.version==2 and type(data.profiles)=="table" then
        for index=1,3 do
            profiles[index]=Core.validate(data.profiles[tostring(index)])
            if type(data.modules)=="table" then module_profiles[index]=data.modules[tostring(index)] end
        end
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
    return make("TextLabel",{Size=UDim2.new(1,-8,0,height or 28),BackgroundTransparency=1,Text=value,TextColor3=color or white,Font=Enum.Font.SourceSans,TextSize=16,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left},owner)
end
local function box(owner, value, height)
    local object=make("TextBox",{Size=UDim2.new(1,-8,0,height or 34),BackgroundColor3=card,BorderSizePixel=0,Text=value,TextColor3=white,Font=Enum.Font.RobotoMono,TextSize=17,ClearTextOnFocus=false,TextWrapped=true},owner)
    make("UICorner",{CornerRadius=UDim.new(0,6)},object); return object
end
local function button(owner,value,callback)
    local object=make("TextButton",{Size=UDim2.new(1,-8,0,34),BackgroundColor3=card,BorderSizePixel=0,Text=value,TextColor3=accent,Font=Enum.Font.SourceSansBold,TextSize=16,AutoButtonColor=true},owner)
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
label(profile_page,"Save profile stores controls, enabled modules and their settings. Load profile restores them. Older profiles need saving again to include modules.",52,muted)
local slot=1
local slot_button
slot_button=button(profile_page,"SLOT 1 / click to cycle",function() slot=slot%3+1; slot_button.Text="SLOT "..slot.." / click to cycle" end)
field(profile_page,"shot","Shot hotkey / F1-F12 or RightShift")
field(profile_page,"combo","Combo hotkey / unique; F8 is reserved")
field(profile_page,"menu","Menu hotkey / unique; F8 is reserved")
button(profile_page,"SAVE SELECTED SLOT",protect(function()
    if not commit() then return end
    profiles[slot]=Core.copy(config)
    if PivotModules then
        module_profiles[slot]=PivotModules:capture_enabled_modules()
        module_profiles[slot].name="Slot "..slot
    end
    if not disk_write then report("Slot "..slot.." saved for this session; disk access unavailable."); return end
    local data={version=2,profiles={},modules={}}
    for index=1,3 do if profiles[index] then data.profiles[tostring(index)]=profiles[index]; data.modules[tostring(index)]=module_profiles[index] end end
    writefile(file,http:JSONEncode(data)); report("Saved slot "..slot.." / "..(module_profiles[slot] and #module_profiles[slot].enabled or 0).." modules / controls and module settings")
end))
button(profile_page,"LOAD SELECTED SLOT",protect(function()
    if not profiles[slot] then report("This slot is empty."); return end
    if not cancel("Loading profile...") then return end
    config=Core.copy(profiles[slot]); sync()
    if PivotModules and module_profiles[slot] then
        PivotModules:load_module_snapshot(module_profiles[slot])
        if PivotUI then PivotUI.set_theme(PivotModules.settings.theme_mode); PivotUI.edit_theme(PivotModules.settings) end
    else report("Loaded controls for slot "..slot.." / older profile has no modules; enable yours and Save profile again") end
end))
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
    local theme={base=rgb(17,17,23),rail=rgb(11,11,16),panel=rgb(25,25,34),input=rgb(20,20,28),line=rgb(43,43,57),
        text=rgb(239,238,248),muted=rgb(151,150,173),accent=rgb(184,167,246),selected=rgb(48,42,68),green=rgb(159,190,170)}
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
    local animation_jobs=setmetatable({},{__mode="k"})
    local function cancel_animation(object)
        local job=animation_jobs[object]; animation_jobs[object]=nil; if job then pcall(function() job:Cancel() end) end
    end
    local function animate(object,properties,duration)
        cancel_animation(object)
        local service=game:GetService("TweenService")
        if service then
            local ok,job=pcall(function() local job=service:Create(object,TweenInfo.new(duration or .16,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),properties); animation_jobs[object]=job; job:Play(); return job end)
            if ok then return job end
        end
        for key,value in pairs(properties) do object[key]=value end
    end
    local hover_states={}
    local function hover_button(button,options)
        if hover_states[button] then return end
        options=options or {}
        local target=options.surface or button; local radius=options.rounding or 6; local inset=options.inset or 0
        local outline=make("Frame",{Name="PivotHoverLift",Position=UDim2.fromOffset(inset,inset),Size=UDim2.new(1,-inset*2,1,-inset*2),BackgroundTransparency=1,BorderSizePixel=0,ZIndex=3},target)
        corner(outline,radius); local edge=border(outline,theme.accent); edge.Transparency=1
        local glow=make("Frame",{Name="PivotHoverGlow",Position=UDim2.fromOffset(inset-2,inset),Size=UDim2.new(1,4-inset*2,1,4-inset*2),BackgroundTransparency=1,BorderSizePixel=0,ZIndex=2},target)
        corner(glow,radius+2); local halo=border(glow,theme.accent); halo.Thickness=4; halo.Transparency=1
        outline:SetAttribute("PivotFixedColor",true); glow:SetAttribute("PivotFixedColor",true)
        local state={surface=target,hover=false,pressed=false,color=target.BackgroundColor3,transparency=target.BackgroundTransparency or 0,z=target.ZIndex or 1,texts={},version=0}
        local links={}
        local function bind(signal,callback) local c=signal:Connect(callback); links[#links+1]=c; return c end
        hover_states[button]=state
        local applying=false
        local function tween(object,properties,instant,duration)
            if instant then
                cancel_animation(object); for key,value in pairs(properties) do object[key]=value end
            else return animate(object,properties,duration) end
        end
        local function paint(instant)
            if not target.Parent then return end
            local raised=state.hover and not state.pressed
            state.version=state.version+1; local version=state.version; state.color_animating=true
            local growth=raised and (options.growth or 3) or state.pressed and -1 or 0
            local lift=raised and 2 or 0
            applying=true
            target.ZIndex=state.hover and state.z+3 or state.z
            local fill=state.hover and not target:GetAttribute("PivotFixedColor") and theme.selected or state.color
            local transparency=state.transparency>=.99 and state.transparency or state.hover and math.min(state.transparency,.15) or state.transparency
            local job=tween(target,{BackgroundColor3=fill,BackgroundTransparency=transparency},instant,state.pressed and .06 or .14)
            tween(outline,{Position=UDim2.fromOffset(inset-growth,inset-growth-lift),Size=UDim2.new(1,growth*2-inset*2,1,growth*2-inset*2)},instant,.14)
            tween(edge,{Color=theme.accent,Thickness=state.pressed and 1.8 or 1.3,Transparency=state.hover and .15 or 1},instant,.12)
            tween(glow,{Position=UDim2.fromOffset(inset-growth-2,inset-growth+2),Size=UDim2.new(1,growth*2+4-inset*2,1,growth*2+4-inset*2)},instant,.16)
            tween(halo,{Color=theme.accent,Transparency=raised and .88 or 1},instant,.16)
            for object,size in pairs(state.texts) do if object.Parent then tween(object,{TextSize=size+(raised and .7 or 0)},instant,.14) end end
            applying=false
            if job and job.Completed then
                local connection
                connection=job.Completed:Connect(function() if state.version==version then state.color_animating=false end; if connection then connection:Disconnect() end end)
            else state.color_animating=false end
        end
        local function restore_texts()
            for object,size in pairs(state.restoring_texts or {}) do if object.Parent then cancel_animation(object); object.TextSize=size end end
            state.restoring_texts=nil
        end
        local function enter()
            if state.hover then return end
            restore_texts()
            state.hover=true; state.texts={}
            if target:IsA("TextButton") and (target.TextTransparency or 0)<1 then state.texts[target]=target.TextSize or 14 end
            for _,child in ipairs(target:GetChildren()) do if child:IsA("TextLabel") then state.texts[child]=child.TextSize end end
            paint()
        end
        local function leave(instant)
            state.hover=false; state.pressed=false; paint(instant); state.restoring_texts=not instant and state.texts or nil; state.texts={}
        end
        state.reset=function() restore_texts(); if state.hover or state.pressed or state.color_animating then leave(true) end end
        bind(button.MouseEnter,enter); bind(button.MouseLeave,function() leave(false) end)
        bind(button.SelectionGained,enter); bind(button.SelectionLost,function() leave(false) end)
        bind(button.InputBegan,function(event)
            if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch or event.KeyCode==Enum.KeyCode.ButtonA then enter(); state.pressed=true; paint() end
        end)
        bind(button.InputEnded,function(event)
            if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch or event.KeyCode==Enum.KeyCode.ButtonA then state.pressed=false; paint() end
        end)
        bind(target:GetPropertyChangedSignal("BackgroundColor3"),function() if not applying and not state.color_animating then state.color=target.BackgroundColor3 end end)
        bind(target:GetPropertyChangedSignal("BackgroundTransparency"),function() if not applying and not state.color_animating then state.transparency=target.BackgroundTransparency end end)
        bind(button.Destroying,function()
            hover_states[button]=nil
            for _,object in ipairs({target,outline,glow,edge,halo}) do cancel_animation(object) end
            for object in pairs(state.texts) do cancel_animation(object) end
            for object in pairs(state.restoring_texts or {}) do cancel_animation(object) end
            for _,connection in ipairs(links) do connection:Disconnect() end; links={}
        end)
    end
    local function reset_hovers()
        for _,state in pairs(hover_states) do state.reset() end
    end
    local function release_hover(target)
        for button,state in pairs(hover_states) do if button==target or state.surface==target then state.reset() end end
    end
    local function style_input(box)
        if box:GetAttribute("PivotInputStyled") then return end; box:SetAttribute("PivotInputStyled",true)
        corner(box,5); local edge=border(box); edge.Transparency=.6
        local focused=false
        local function paint() animate(edge,{Color=focused and theme.accent or theme.line,Transparency=focused and .1 or .6,Thickness=focused and 1.3 or 1},.14) end
        local links={}
        links[1]=box.Focused:Connect(function() focused=true; paint() end); links[2]=box.FocusLost:Connect(function() focused=false; paint() end)
        links[3]=box.Destroying:Connect(function() cancel_animation(edge); for _,connection in ipairs(links) do connection:Disconnect() end end)
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
        elseif kind=="Visual+" then
            ring(3,3,14); ring(7,7,6); line(15,2,15,7); line(12.5,4.5,17.5,4.5)
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
            TextColor3=color or theme.text,Font=Enum.Font.SourceSans,TextSize=math.max(14,(size or 12)+2),TextXAlignment=Enum.TextXAlignment.Left,
            TextYAlignment=Enum.TextYAlignment.Center,TextWrapped=true,BorderSizePixel=0},parent)
    end
    local function small_button(parent,value,callback)
        local b=make("TextButton",{Text=value,Size=UDim2.fromOffset(110,28),BackgroundColor3=theme.panel,BorderSizePixel=0,
            TextColor3=theme.text,TextSize=14,Font=Enum.Font.SourceSans,AutoButtonColor=false},parent)
        corner(b,7)
        border(b).Transparency=.72
        on(b.Activated,callback)
        hover_button(b)
        return b
    end
    local shell=gui:FindFirstChildWhichIsA("Frame")
    on(shell:GetPropertyChangedSignal("Visible"),function() if not shell.Visible then reset_hovers() end end)
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
    shell.BackgroundColor3=theme.base; corner(shell,16); border(shell)
    header.Text=""; header.Position=UDim2.fromOffset(68,0); header.Size=UDim2.new(1,-112,0,42)
    subtitle.Visible=false
    nav.Visible=false
    local rail=frame(shell,0,0,68,548,theme.rail); rail.ZIndex=0; rail.Visible=false; corner(rail,0)
    local rail_line=frame(shell,20,97,660,1,theme.line)
    local top_line=frame(shell,20,54,660,1,theme.line)
    local logo=label(shell,"Pivot",20,12,100,28,19,theme.text); logo.Font=Enum.Font.SourceSansBold; logo.TextXAlignment=Enum.TextXAlignment.Left
    local build_label=label(shell,"BUILD 2026.11.06.4",242,17,150,18,10,theme.muted); build_label.Name="PivotBuild"; build_label.Font=Enum.Font.RobotoMono; build_label.TextWrapped=false
    local heading=label(shell,"Practical Basketball",94,14,240,26,11,theme.muted); heading.Font=Enum.Font.SourceSansSemibold
    close.BackgroundColor3=theme.rail; close.TextColor3=theme.muted; close.TextSize=14; corner(close,4)
    local search=make("TextBox",{Text="",PlaceholderText="Find a control...",PlaceholderColor3=theme.muted,Position=UDim2.fromOffset(484,10),Size=UDim2.fromOffset(166,23),
        ClearTextOnFocus=false,TextSize=14,TextColor3=theme.text,BackgroundColor3=theme.input,BorderSizePixel=0,Font=Enum.Font.SourceSans},shell)
    corner(search,7); border(search).Transparency=.5
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
        hover_button(b)
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
                        local row=frame(page,0,0,0,multi and 116 or 64); row.Size=UDim2.new(1,-6,0,multi and 116 or 64); row.LayoutOrder=child.LayoutOrder; corner(row,8)
                        child.Parent=row; child.Text=d[1]; child.TextSize=14; child.Font=Enum.Font.SourceSans; child.TextColor3=theme.text; child.Position=UDim2.fromOffset(16,10); child.Size=UDim2.new(1,-128,0,20)
                        local helper=label(row,d[2],16,35,220,16,10,theme.muted); helper.Size=UDim2.new(1,-128,0,16)
                        box.Parent=row; box.TextSize=14; box.BackgroundColor3=theme.input; box.TextColor3=theme.text; box.Font=Enum.Font.RobotoMono; corner(box,3)
                        box.Position=multi and UDim2.fromOffset(12,51) or UDim2.new(1,-112,0,18); box.Size=multi and UDim2.new(1,-24,0,44) or UDim2.fromOffset(96,30); box.MultiLine=multi
                        local outline=border(box)
                        if multi then child.Size=UDim2.new(1,-24,0,20); helper.Size=UDim2.new(1,-24,0,16) end
                        style_input(box)
                        fields[d[3]]=box; rows[#rows+1]={name=d[1],description=d[2],page=name,row=row}
                    elseif names[child.Text] or name=="Diagnostics" then child.Visible=false
                    else
                        if child.Text:find("Calibrate against live shot feedback",1,true) then child.Text="Manual shot lab  /  F6 action"; child.Size=UDim2.new(1,-6,0,22) end
                        child.TextSize=14; child.TextColor3=theme.muted; child.TextYAlignment=Enum.TextYAlignment.Top
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
    local account=frame(home,0,0,0,84); account.Size=UDim2.new(1,-6,0,108); corner(account,7)
    local name=player.DisplayName or player.Name
    local kicker=label(account,"SIGNED IN",80,18,420,16,10,theme.muted)
    local display_name=label(account,name,80,39,450,25,22); display_name.Font=Enum.Font.SourceSansBold
    local greeting=label(account,"@"..player.Name,80,69,430,17,11,theme.muted)
    local badge=frame(account,18,27,46,46,theme.selected); corner(badge,14)
    local account_initial=label(badge,tostring(name):sub(1,1):upper(),0,0,46,46,22,theme.accent); account_initial.TextXAlignment=Enum.TextXAlignment.Center; account_initial.Font=Enum.Font.SourceSansBold
    local session_label=label(account,"",0,0,1,1); session_label.Visible=false
    local stats=frame(home,0,94,0,54); stats.Size=UDim2.new(1,-6,0,54); corner(stats,7)
    local stat_values={}
    for index,title in ipairs({"Players","Session","FPS","Ping","Enabled"}) do
        local cell=frame(stats,0,0,0,54); cell.Position=UDim2.new((index-1)/5,0,0,0); cell.Size=UDim2.new(.2,0,1,0); cell.BackgroundTransparency=1
        local caption=label(cell,title,10,8,100,16,10,theme.muted); caption.Size=UDim2.new(1,-14,0,16)
        local value=label(cell,"--",10,26,100,20,15); value.Font=Enum.Font.SourceSansSemibold; value.Size=UDim2.new(1,-14,0,20); stat_values[title]=value
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
    local page_descriptions={Diagnostics="Your session and quick controls",["Shot Lab"]="Shot controls and timing tools",Modules="Browse and configure your modules",["Visual+"]="Characters, court and effects",Combos="Build and manage input sequences",Profiles="Saved profiles and key bindings"}
    local page_description=label(shell,page_descriptions.Diagnostics,208,51,450,20,11,theme.muted)
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
        reset_hovers()
        selected=name; result_page.Visible=false; if PivotUI and PivotUI.hide_extra then PivotUI.hide_extra() end; page_description.Text=page_descriptions[name] or ""
        for key,page in pairs(pages) do page.Visible=key==name end
        heading.Text=({Diagnostics="Dashboard",["Shot Lab"]="Main",Profiles="Profiles"})[name] or name
        for key,item in pairs(rail_items) do
            local active=key==name; item.button.BackgroundColor3=active and theme.selected or theme.rail
            icon_color(item.icon,active and theme.accent or theme.muted); item.label.TextColor3=active and theme.accent or theme.muted
            item.label.Font=active and Enum.Font.SourceSansSemibold or Enum.Font.SourceSans
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
        result_page.Visible=true; heading.Text="Search"; page_description.Text="Find a module or control"
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
    status.TextSize=14; status.TextColor3=theme.muted
    cancel.TextTransparency=1; cancel.BackgroundColor3=theme.selected; corner(cancel,4)
    local cancel_text=label(cancel,"Stop all  ·  F8",0,0,96,28,11); cancel_text.TextXAlignment=Enum.TextXAlignment.Center
    hover_button(close,{rounding=4}); hover_button(cancel,{rounding=4}); style_input(search)
    local scale=shell:FindFirstChildWhichIsA("UIScale")
    local brand_subtitle=label(shell,"Practical Basketball",18,43,130,18,10,theme.muted)
    local nav_caption=label(shell,"NAVIGATION",22,94,140,18,10,theme.muted)
    local function content_width() return shell.Size.X.Offset-(shell.Size.X.Offset>=760 and 152 or 40) end
    local function layout_nav()
        local w=shell.Size.X.Offset
        local desktop=w>=760
        local stacked=w<560
        local left=desktop and 132 or 20
        local top=desktop and 108 or stacked and 152 or 112
        rail.Visible=desktop; rail.Size=UDim2.new(0,104,1,0)
        rail_line.Position=desktop and UDim2.fromOffset(104,0) or UDim2.fromOffset(20,stacked and 137 or 97)
        rail_line.Size=desktop and UDim2.new(0,1,1,0) or UDim2.new(1,-40,0,1)
        top_line.Position=UDim2.fromOffset(left,desktop and 87 or 54); top_line.Size=UDim2.new(1,-left-20,0,1)
        brand_subtitle.Visible=false; nav_caption.Visible=false; page_description.Visible=desktop; page_description.Position=UDim2.fromOffset(left+2,55); page_description.Size=UDim2.new(1,-left-232,0,20)
        logo.Position=UDim2.fromOffset(desktop and 24 or 18,desktop and 21 or 12)
        logo.Size=UDim2.fromOffset(desktop and 56 or 100,desktop and 48 or 28)
        logo.Text=desktop and "P" or "Pivot"; logo.TextSize=desktop and 32 or 21
        logo.TextXAlignment=desktop and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left
        logo.BackgroundTransparency=desktop and 0 or 1; logo.BackgroundColor3=theme.selected; logo.TextColor3=desktop and theme.accent or theme.text; corner(logo,14)
        heading.Position=UDim2.fromOffset(desktop and 134 or 120,desktop and 20 or 14)
        heading.Font=Enum.Font.SourceSansBold; heading.TextSize=desktop and 26 or 16; heading.TextColor3=theme.text
        if desktop then
            search.Position=UDim2.new(1,-292,0,19); search.Size=UDim2.fromOffset(194,30)
            search_symbol.Position=UDim2.new(1,-287,0,24)
            close.Position=UDim2.new(1,-44,0,19); close.Size=UDim2.fromOffset(28,30)
        else search.Size=UDim2.fromOffset(166,23) end
        local minimize_button=shell:FindFirstChild("Minimize")
        if minimize_button then minimize_button.Position=desktop and UDim2.new(1,-78,0,19) or UDim2.new(1,-64,0,10); minimize_button.Size=desktop and UDim2.fromOffset(28,30) or UDim2.fromOffset(23,23) end
        build_label.Position=desktop and UDim2.new(1,-203,0,57) or UDim2.fromOffset(104,17)
        build_label.Size=UDim2.fromOffset(158,18); build_label.Visible=desktop
        for _,page in pairs(pages) do page.Position=UDim2.fromOffset(left,top); page.Size=UDim2.new(1,-left-14,1,-top-62) end
        result_page.Position=UDim2.fromOffset(left,top); result_page.Size=UDim2.new(1,-left-14,1,-top-62)
        footer.Position=UDim2.new(0,left,1,-49); footer.Size=UDim2.new(1,-left-20,0,1)
        status.Position=UDim2.new(0,left,1,-43); status.Size=UDim2.new(1,-left-125,0,34)
        for i,key in ipairs({"Diagnostics","Shot Lab","Modules","Visual+","Combos","Profiles"}) do
            local item=rail_items[key]
            if item then
                local width=(w-40)/(stacked and 3 or 6)
                item.button.Position=desktop and UDim2.fromOffset(18,108+(i-1)*76) or UDim2.fromOffset(20+((i-1)%(stacked and 3 or 6))*width,62+(stacked and math.floor((i-1)/3)*38 or 0))
                item.button.Size=desktop and UDim2.fromOffset(68,64) or UDim2.fromOffset(width-4,30)
                local compact=w<700
                item.icon.Visible=not compact
                item.label.Position=desktop and UDim2.fromOffset(0,35) or UDim2.fromOffset(compact and 0 or 33,0); item.label.Size=desktop and UDim2.new(1,0,0,23) or UDim2.new(1,compact and 0 or -35,1,0)
                item.label.TextSize=desktop and 15 or 14
                item.label.TextXAlignment=(desktop or compact) and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left
                item.label.Font=selected==key and Enum.Font.SourceSansSemibold or Enum.Font.SourceSans
                local stroke=item.button:FindFirstChildWhichIsA("UIStroke"); if stroke then stroke.Transparency=1 end
                item.icon.Position=desktop and UDim2.fromOffset(24,10) or UDim2.fromOffset(9,5)
                if item.indicator then item.indicator.Position=desktop and UDim2.fromOffset(-9,22) or UDim2.new(0,7,1,-1); item.indicator.Size=desktop and UDim2.fromOffset(2,18) or UDim2.new(1,-14,0,2) end
            end
        end
    end
    local minimized=small_button(gui,"Pivot  ·  Restore",function() shell.Visible=true end)
    minimized.Name="PivotMinimized"; minimized.Size=UDim2.fromOffset(164,34); minimized.AnchorPoint=Vector2.new(.5,.5); minimized.Visible=false; border(minimized)
    local minimize=small_button(shell,"−",function()
        minimized.Position=shell.Position; minimized.Visible=true; shell.Visible=false
    end)
    minimize.Name="Minimize"; minimize.Position=UDim2.new(1,-64,0,10); minimize.Size=UDim2.fromOffset(23,23); minimize.TextSize=18
    on(shell:GetPropertyChangedSignal("Visible"),function() if shell.Visible then minimized.Visible=false end end)
    local camera_link
    local function fit()
        local camera=workspace.CurrentCamera; if not camera then return end
        local v=camera.ViewportSize
        local w=math.max(340,math.min(1080,v.X-24)); local h=math.max(430,math.min(740,v.Y-32))
        scale.Scale=math.min(1,(v.X-12)/w,(v.Y-12)/h); shell.Size=UDim2.fromOffset(w,h)
        rail_line.Size=UDim2.new(1,-40,0,1); top_line.Size=UDim2.new(1,-40,0,1)
        layout_nav()
        local narrow=w<560
        build_label.Visible=w>=740 or narrow
        build_label.Position=narrow and UDim2.fromOffset(94,17) or UDim2.fromOffset(258,17)
        build_label.Size=UDim2.fromOffset(narrow and 155 or 150,18)
        search.Visible=not narrow; search.Position=UDim2.new(1,-244,0,10)
        search_symbol.Visible=not narrow; search_symbol.Position=UDim2.new(1,-241,0,12)
        heading.Visible=not narrow; heading.Size=UDim2.fromOffset(158,26)
        close.Position=UDim2.new(1,-35,0,10); close.Size=UDim2.fromOffset(23,23)
        for _,page in pairs(pages) do page.Position=UDim2.fromOffset(20,112); page.Size=UDim2.new(1,-34,1,-174) end
        result_page.Position=UDim2.fromOffset(20,112); result_page.Size=UDim2.new(1,-34,1,-174)
        profile_circle.Position=UDim2.new(0,21,1,-64); rail_name.Position=UDim2.new(0,5,1,-32)
        footer.Position=UDim2.new(0,20,1,-49); footer.Size=UDim2.new(1,-40,0,1)
        status.Position=UDim2.new(0,20,1,-43); status.Size=UDim2.new(1,-145,0,34)
        cancel.Position=UDim2.new(1,-116,1,-39); cancel.Size=UDim2.fromOffset(96,28)
        local compact=w<560
        kicker.Size=UDim2.new(1,-100,0,16)
        display_name.Size=UDim2.new(1,-100,0,25); display_name.TextSize=24; greeting.Size=UDim2.new(1,-100,0,17)
        account.Size=UDim2.new(1,-6,0,108)
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
        stats.Position=UDim2.fromOffset(0,120)
        server.Position=UDim2.fromOffset(0,186)
        runtime.Position=UDim2.fromOffset(0,compact and 346 or 306)
        bottom.Position=UDim2.fromOffset(0,compact and 410 or 370)
        home.CanvasSize=UDim2.fromOffset(0,compact and 548 or 444)
        profile_circle.Visible=w>=760; rail_name.Visible=false
        profile_circle.Position=UDim2.new(0,37,1,-62); profile_circle.Size=UDim2.fromOffset(30,30)
        rail_name.Position=UDim2.new(0,62,1,-90); rail_name.Size=UDim2.fromOffset(105,22); rail_name.TextXAlignment=Enum.TextXAlignment.Left
        if content_width()>=650 then
            server.Position=UDim2.fromOffset(0,186); server.Size=UDim2.new(.6,-10,0,172)
            copy_place.Position=UDim2.fromOffset(14,124); copy_place.Size=UDim2.new(.5,-20,0,30)
            copy_server.Position=UDim2.new(.5,0,0,124); copy_server.Size=UDim2.new(.5,-14,0,30)
            place_text.Size=UDim2.new(1,-28,0,17); server_text.Size=UDim2.new(1,-28,0,16)
            runtime.Position=UDim2.new(.6,2,0,186); runtime.Size=UDim2.new(.4,-8,0,80)
            bottom.Position=UDim2.new(.6,2,0,278); bottom.Size=UDim2.new(.4,-8,0,80)
            storage.Size=UDim2.new(1,0,1,0)
            report_card.Parent=home; report_card.Position=UDim2.fromOffset(0,370); report_card.Size=UDim2.new(1,-6,0,58)
        else
            runtime.Size=UDim2.new(1,-6,0,52); report_card.Parent=bottom
        end
        layout_nav()
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
    local function set_theme(mode)
        reset_hovers()
        local palettes={
            Graphite={base=rgb(17,17,23),rail=rgb(11,11,16),panel=rgb(25,25,34),input=rgb(20,20,28),line=rgb(43,43,57),text=rgb(239,238,248),muted=rgb(151,150,173),accent=rgb(184,167,246),selected=rgb(48,42,68),green=rgb(159,190,170)},
            Slate={base=rgb(23,28,35),rail=rgb(23,28,35),panel=rgb(31,38,47),input=rgb(26,32,40),line=rgb(48,57,70),text=rgb(229,234,242),muted=rgb(151,163,182),accent=rgb(172,193,220),selected=rgb(43,54,69),green=rgb(159,190,170)},
            Light={base=rgb(241,242,244),rail=rgb(241,242,244),panel=rgb(250,250,251),input=rgb(232,234,238),line=rgb(213,216,223),text=rgb(33,37,44),muted=rgb(102,110,124),accent=rgb(67,83,111),selected=rgb(221,227,237),green=rgb(64,124,88)}
        }
        local next_theme=assert(palettes[mode],"Unknown theme")
        for _,object in ipairs(gui:GetDescendants()) do
            for _,property in ipairs({"BackgroundColor3","TextColor3","ScrollBarImageColor3","Color"}) do
                pcall(function()
                    local color=object[property]
                    for key,value in pairs(theme) do if color==value and not object:GetAttribute("PivotFixedColor") then object[property]=next_theme[key]; break end end
                end)
            end
        end
        for key,value in pairs(next_theme) do theme[key]=value end
    end
    local function edit_theme(settings)
        reset_hovers()
        local custom=settings.theme_custom
        if custom then
            local next_accent=assert((function() local h=settings.ui_accent:match("^#?(%x%x%x%x%x%x)$"); if h then return rgb(tonumber(h:sub(1,2),16),tonumber(h:sub(3,4),16),tonumber(h:sub(5,6),16)) end end)(),"Invalid accent color")
            local previous=theme.accent
            for _,object in ipairs(gui:GetDescendants()) do
                for _,property in ipairs({"BackgroundColor3","TextColor3","Color"}) do pcall(function() if object[property]==previous and not object:GetAttribute("PivotFixedColor") then object[property]=next_accent end end) end
            end
            theme.accent=next_accent
        end
        for _,object in ipairs(gui:GetDescendants()) do
            if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
                local base=object:GetAttribute("PivotBaseText")
                if not base then base=object.TextSize or 14; object:SetAttribute("PivotBaseText",base) end
                object.TextSize=base+(custom and settings.ui_font_size-14 or 0)
            elseif object:IsA("UICorner") then
                local owner=object.Parent
                if owner and (owner==shell or owner.Name:sub(1,6)=="Group_" or owner:IsA("TextButton") and owner.BackgroundTransparency==0) then
                    local base=object:GetAttribute("PivotBaseCorner")
                    if not base then base=object.CornerRadius.Offset; object:SetAttribute("PivotBaseCorner",base) end
                    object.CornerRadius=UDim.new(0,custom and settings.ui_rounding or base)
                end
            end
        end
        shell.BackgroundTransparency=custom and 1-settings.ui_opacity or 0
    end
    PivotUI={theme=theme,label=label,button=small_button,pages=pages,rail_items=rail_items,show=show,heading=heading,search=search,cancel=cancel,actions=actions,icon=icon,icon_color=icon_color,animate=animate,hover=hover_button,release_hover=release_hover,input_style=style_input,add_search=add_search,layout_nav=layout_nav,content_width=content_width,set_theme=set_theme,edit_theme=edit_theme}
    on(gui.Destroying,function() for _,c in ipairs(connections) do c:Disconnect() end end)
end

do
    local ui=PivotUI
    local engine=Core.create_pivot_modules({players=players,player=player,input=input,run=run_service,runner=runner,gui=gui,connect=connect,report=report,reserved_keys=function() return {config.shot,config.combo,config.menu,"F8"} end})
    PivotModules=engine
    local theme=ui.theme
    local function paint_switch(button,on)
        if button:GetAttribute("On")==on then return end
        if ui.release_hover then ui.release_hover(button); ui.release_hover(button.Parent) end
        button:SetAttribute("On",on)
        local track=button:FindFirstChild("Track"); local knob=track and track:FindFirstChild("Knob")
        if not knob then return end
        ui.animate(track,{BackgroundColor3=on and theme.accent or theme.line})
        ui.animate(knob,{BackgroundColor3=on and theme.base or theme.muted,Position=UDim2.fromOffset(on and 22 or 2,2)})
        local row=button.Parent
        local marker=row and row:FindFirstChild("StateMark"); if marker then marker.Visible=on end
        if row and row.Name:sub(1,10)=="ModuleRow_" then row.BackgroundColor3=on and theme.selected or theme.panel; row.BackgroundTransparency=on and .4 or 1 end
    end
    local function switch(parent,callback)
        local button=make("TextButton",{Name="Toggle",Text="",AutoButtonColor=false,BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromOffset(44,26)},parent)
        local track=make("Frame",{Name="Track",Position=UDim2.fromOffset(0,2),Size=UDim2.fromOffset(42,22),BorderSizePixel=0},button)
        make("UICorner",{CornerRadius=UDim.new(0,11)},track)
        local knob=make("Frame",{Name="Knob",Size=UDim2.fromOffset(18,18),BorderSizePixel=0},track)
        make("UICorner",{CornerRadius=UDim.new(0,9)},knob)
        connect(button.Activated,callback); paint_switch(button,false)
        ui.hover(button,{rounding=9,inset=4,growth=1})
        return button
    end
    local page=make("ScrollingFrame",{Name="PivotModules",Position=UDim2.fromOffset(20,112),Size=UDim2.new(1,-34,1,-174),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=2,Visible=false,CanvasSize=UDim2.fromOffset(0,0)},window)
    local modules_page=page
    local visual_page=make("ScrollingFrame",{Name="PivotVisualPlus",Position=UDim2.fromOffset(20,112),Size=UDim2.new(1,-34,1,-174),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,Visible=false,CanvasSize=UDim2.fromOffset(0,0)},window)
    local visual_reactive_open=false; local visual_controller_open=false
    local visual_section="Ball"; local visual_character_open=false; local visual_ball_details=false; local visual_trail_details=false
    local visual_wings_open=false; local visual_aura_open=false; local visual_impacts_open=false
    local visual_lightning_open=false; local visual_rim_open=false
    local visual_electric_pack_open=false
    local visual_effect_filter="All"; local visual_effect_cards={}; local visual_status_label
    local visual_preview_open=false; local visual_character_preview
    local tabs={"All","Saved modules","Shooting","Dribbling","Cosmetics","Character","Player","Defense","Visuals","World","Camera","Recorder","Options"}
    local category="All"; local rows={}; local fields={}; local y=0
    local container=page
    local collapsed={}
    local expanded,choosing,section_button,record_tools,court_alignment
    local dribble_editor_open=false; local character_open=false; local library_open=false; local module_selection_label
    local auxiliary={}; local capture_switch; local character_status; local library_status
    local function clear()
        for _,object in ipairs(rows) do object:Destroy() end; rows={}; fields={}; auxiliary={}; character_status=nil; library_status=nil; module_selection_label=nil; visual_status_label=nil; y=46
    end
    local function own(object) rows[#rows+1]=object; return object end
    local function text(value,size,color,height)
        local object=own(ui.label(container,value,2,y,500,height or 22,size or 12,color or theme.text)); object.Size=UDim2.new(1,-12,0,height or 22); y=y+(height or 22)+5; return object
    end
    local function action(value,callback)
        local object=own(ui.button(container,value,function() local ok,err=pcall(callback); if not ok then report(tostring(err)) end end))
        object.Position=UDim2.fromOffset(0,y); object.Size=UDim2.new(1,-6,0,36); y=y+44; object.TextXAlignment=Enum.TextXAlignment.Left; make("UIPadding",{PaddingLeft=UDim.new(0,14),PaddingRight=UDim.new(0,12)},object); return object
    end
    local rebuild,color_expanded
    local function field(key,caption)
        local color_sync
        local row=own(make("Frame",{Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,44),BackgroundColor3=theme.panel,BorderSizePixel=0},container))
        make("UICorner",{CornerRadius=UDim.new(0,6)},row)
        local label=ui.label(row,caption,14,12,220,20,11,theme.muted); label.Size=UDim2.new(.6,-14,0,20)
        local box=make("TextBox",{Name="Module_"..key,Text=tostring(engine.settings[key]),ClearTextOnFocus=false,Font=Enum.Font.RobotoMono,TextSize=14,TextColor3=theme.text,BackgroundColor3=theme.input,BorderSizePixel=0,Position=UDim2.new(.6,0,0,8),Size=UDim2.new(.4,-6,0,28)},row)
        fields[key]=box; y=y+52
        ui.input_style(box)
        local range=engine.ranges[key]
        if range then
            row.Size=UDim2.new(1,-6,0,64); y=y+20
            local slider=make("TextButton",{Name="Slider_"..key,Text="",AutoButtonColor=false,Position=UDim2.fromOffset(14,48),Size=UDim2.new(1,-28,0,5),BackgroundColor3=theme.line,BorderSizePixel=0},row)
            make("UICorner",{CornerRadius=UDim.new(0,3)},slider)
            ui.hover(slider,{rounding=3,growth=1})
            local fill=make("Frame",{BackgroundColor3=theme.accent,BorderSizePixel=0,Size=UDim2.new((engine.settings[key]-range[1])/(range[2]-range[1]),0,1,0)},slider)
            make("UICorner",{CornerRadius=UDim.new(0,3)},fill)
            local dragging
            local function update(position)
                local width=slider.AbsoluteSize.X; if width<=0 then return end
                local fraction=math.max(0,math.min(1,(position.X-slider.AbsolutePosition.X)/width))
                local value=range[1]+fraction*(range[2]-range[1])
                value=(range[2]<=5 or key:match("^court_marking_")) and math.floor(value*100+.5)/100 or math.floor(value+.5)
                engine.settings[key]=value; box.Text=tostring(value); if key:match("^ui_") then ui.edit_theme(engine.settings) end; fill.Size=UDim2.new((value-range[1])/(range[2]-range[1]),0,1,0)
            end
            connect(slider.InputBegan,function(event)
                if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch then dragging=event; update(event.Position) end
            end)
            local move_link=input.InputChanged:Connect(function(event)
                if row.Parent and dragging and (event==dragging or event.UserInputType==Enum.UserInputType.MouseMovement) then update(event.Position) end
            end)
            local end_link=input.InputEnded:Connect(function(event)
                if event==dragging or event.UserInputType==Enum.UserInputType.MouseButton1 then dragging=nil end
            end)
            connect(row.Destroying,function() move_link:Disconnect(); end_link:Disconnect() end)
            connect(box:GetPropertyChangedSignal("Text"),function()
                local value=Core.bounded(box.Text,range[1],range[2]); if value then fill.Size=UDim2.new((value-range[1])/(range[2]-range[1]),0,1,0) end
            end)
        end
        local color_key=key:match("_color$") or key=="ui_accent" or key=="sky_tint" or key=="sky_decay"
        local color=color_key and type(engine.settings[key])=="string" and Core.hex_color(engine.settings[key])
        if color then
            local swatch=make("TextButton",{Name="ColorSwatch_"..key,Text="",AutoButtonColor=false,Size=UDim2.fromOffset(24,24),Position=UDim2.new(1,-140,0,6),BackgroundColor3=color,BorderSizePixel=0},row)
            swatch:SetAttribute("PivotFixedColor",true); make("UICorner",{CornerRadius=UDim.new(0,4)},swatch)
            ui.hover(swatch,{rounding=4,growth=2})
            label.Size=UDim2.new(1,-156,0,20); box.Position=UDim2.new(1,-108,0,4); box.Size=UDim2.fromOffset(102,28)
            connect(swatch.Activated,function() color_expanded=color_expanded==key and nil or key; rebuild() end)
            if color_expanded==key then
                row.Size=UDim2.new(1,-6,0,164); y=y+128
                local hex=engine.settings[key]:gsub("#","")
                local values={tonumber(hex:sub(1,2),16),tonumber(hex:sub(3,4),16),tonumber(hex:sub(5,6),16)}
                local tracks,numbers={},{}
                local function apply()
                    local value=string.format("#%02X%02X%02X",values[1],values[2],values[3])
                    engine.settings[key]=value; box.Text=value; swatch.BackgroundColor3=Core.hex_color(value)
                    for i,fill in ipairs(tracks) do fill.Size=UDim2.new(values[i]/255,0,1,0); numbers[i].Text=tostring(values[i]) end
                    if key=="ui_accent" then ui.edit_theme(engine.settings) end
                end
                local palette={"#FFFFFF","#242830","#FF5050","#FFA04D","#65D99A","#6CA6FF","#B79AFF","#F58BC4"}
                for i,value in ipairs(palette) do
                    local chip=make("TextButton",{Name="ColorPreset_"..key.."_"..i,Text="",AutoButtonColor=false,BackgroundColor3=Core.hex_color(value),BorderSizePixel=0,Position=UDim2.new((i-1)/8,6,0,42),Size=UDim2.new(1/8,-8,0,22)},row)
                    chip:SetAttribute("PivotFixedColor",true); make("UICorner",{CornerRadius=UDim.new(0,4)},chip)
                    ui.hover(chip,{rounding=4,growth=2})
                    connect(chip.Activated,function() local h=value:sub(2); for channel=1,3 do values[channel]=tonumber(h:sub(channel*2-1,channel*2),16) end; apply() end)
                end
                for channel,caption in ipairs({"R","G","B"}) do
                    ui.label(row,caption,10,76+(channel-1)*26,20,20,12,theme.muted)
                    local number=ui.label(row,tostring(values[channel]),0,76+(channel-1)*26,32,20,12,theme.text); number.Position=UDim2.new(1,-40,0,76+(channel-1)*26); numbers[channel]=number
                    local slider=make("TextButton",{Name="ColorRGB_"..key.."_"..caption,Text="",AutoButtonColor=false,Position=UDim2.fromOffset(34,84+(channel-1)*26),Size=UDim2.new(1,-84,0,7),BackgroundColor3=theme.line,BorderSizePixel=0},row)
                    make("UICorner",{CornerRadius=UDim.new(0,3)},slider)
                    local fill=make("Frame",{BackgroundColor3=channel==1 and Color3.fromRGB(234,110,110) or channel==2 and Color3.fromRGB(110,204,150) or Color3.fromRGB(113,158,231),BorderSizePixel=0,Size=UDim2.new(values[channel]/255,0,1,0)},slider)
                    fill:SetAttribute("PivotFixedColor",true); make("UICorner",{CornerRadius=UDim.new(0,3)},fill); tracks[channel]=fill
                    local dragging
                    local function update(position)
                        if slider.AbsoluteSize.X<=0 then return end
                        values[channel]=math.floor(math.max(0,math.min(1,(position.X-slider.AbsolutePosition.X)/slider.AbsoluteSize.X))*255+.5); apply()
                    end
                    connect(slider.InputBegan,function(event) if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch then dragging=event; update(event.Position) end end)
                    local move=input.InputChanged:Connect(function(event) if row.Parent and dragging and (event==dragging or event.UserInputType==Enum.UserInputType.MouseMovement) then update(event.Position) end end)
                    local finish=input.InputEnded:Connect(function(event) if event==dragging or event.UserInputType==Enum.UserInputType.MouseButton1 then dragging=nil end end)
                    connect(row.Destroying,function() move:Disconnect(); finish:Disconnect() end)
                end
                color_sync=function()
                    local h=box.Text:gsub("#",""); if not Core.hex_color(box.Text) then return end
                    for channel=1,3 do values[channel]=tonumber(h:sub(channel*2-1,channel*2),16) end
                    apply()
                end
            end
            connect(box:GetPropertyChangedSignal("Text"),function() local value=Core.hex_color(box.Text); if value then swatch.BackgroundColor3=value end end)
        end

        connect(box.FocusLost,function()
            local original=engine.settings[key]; local value=box.Text
            if type(original)=="number" then local range=engine.ranges[key]; value=Core.bounded(value,range[1],range[2]); if not value then box.Text=tostring(original); report("Value outside allowed range: "..key); return end end
            if #box.Text>100 then box.Text=tostring(original); return end
            if type(value)=="string" and (key:match("_color$") or key=="ui_accent" or key=="sky_tint" or key=="sky_decay") and not Core.hex_color(value) then box.Text=tostring(original); report("Use #RRGGBB for colors"); return end
            engine.settings[key]=value
            if color_sync then color_sync() end
            if key:match("^ui_") then ui.edit_theme(engine.settings) end
            if key=="sky_asset" and engine.settings.sky_preset=="Custom" and engine.registry.active.sky then engine.registry:disable("sky"); local ok,err=engine.registry:enable("sky",engine.settings); if not ok then report(tostring(err)) end end
            if key=="model_asset" and engine.settings.model_preset=="Custom" and engine.registry.active.custom_model then engine.registry:disable("custom_model"); local ok,err=engine.registry:enable("custom_model",engine.settings); if not ok then report(tostring(err)) end end
        end)
    end
    local buttons={}
    local function update_buttons()
        if visual_status_label and visual_status_label.Parent then
            local count=0; for id in pairs(engine.registry.active) do local definition=engine.registry.definitions[id]; if definition.category=="Cosmetics" or definition.category=="Character" or definition.category=="Visual+" then count=count+1 end end
            visual_status_label.Text=count.." active"
        end
        for id,button in pairs(buttons) do
            if button.Parent then paint_switch(button,engine.registry.active[id]~=nil) end
        end
        for _,entry in ipairs(auxiliary) do if entry.button.Parent then paint_switch(entry.button,entry.read()) end end
        if capture_switch then paint_switch(capture_switch,capture) end
        if character_status and character_status.Parent then local active=engine.registry.active.custom_model; character_status.Text="Selected: "..engine.settings.model_preset.." · "..(active and active.state.rig_label or "Enable Character skin to load") end
        if module_selection_label and module_selection_label.Parent then
            local names={}; for _,definition in ipairs(engine.definitions) do if engine.registry.active[definition.id] then names[#names+1]=definition.title end end
            module_selection_label.Text="Selected: "..(#names>0 and table.concat(names,", ") or "None — turn on your modules before saving")
        end
        if library_status and library_status.Parent then
            local progress=engine.model_preload; local cached=0; for _ in pairs(engine.model_cache) do cached=cached+1 end
            library_status.Text=progress.busy and ("Preloading "..progress.done.." / "..progress.total) or (cached.." cached · "..progress.failed.." preload failures")
        end
    end
    local function toggle_action(caption,read,write)
        local row=own(make("Frame",{Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,44),BackgroundColor3=theme.panel,BorderSizePixel=0},container))
        make("UICorner",{CornerRadius=UDim.new(0,6)},row)
        local title=ui.label(row,caption,14,0,300,44,12,theme.text); title.Size=UDim2.new(1,-74,0,44); title.Font=Enum.Font.SourceSansSemibold
        local button=switch(row,function() local ok,err=pcall(write,not read()); if not ok then report(tostring(err)) end; update_buttons() end)
        button.Position=UDim2.new(1,-54,0,9); auxiliary[#auxiliary+1]={button=button,read=read}; y=y+52
        paint_switch(button,read()); return button
    end
    local function choice(key,caption,values)
        action(caption.."  /  "..tostring(engine.settings[key]),function()
            local current=1; for i,value in ipairs(values) do if value==engine.settings[key] then current=i end end
            engine.settings[key]=values[current%#values+1]
            if key=="model_style" and engine.settings[key]=="Basketball" then engine.settings.model_fit_pb=true end
            if key=="theme_mode" then ui.set_theme(engine.settings[key]) end
            if key=="sky_preset" and engine.registry.active.sky then engine.registry:disable("sky"); local ok,err=engine.registry:enable("sky",engine.settings); if not ok then report(tostring(err)) end end
            if (key=="model_preset" or key=="model_renderer" or key=="model_style") and engine.registry.active.custom_model then engine.registry:disable("custom_model"); local ok,err=engine.registry:enable("custom_model",engine.settings); if not ok then report(tostring(err)) end end
            rebuild()
        end)
    end
    local function skin_source_control()
        text("Skin source",13,theme.muted,20)
        local holder=own(make("Frame",{Name="SkinSource",Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,72),BackgroundTransparency=1},container)); y=y+82
        for i,source in ipairs({"Preset character","Roblox model ID","Outfit ID","Roblox username"}) do
            local b=ui.button(holder,source,function()
                engine:set_skin_source(source); character_open=false; visual_character_open=false; visual_preview_open=false; rebuild()
            end)
            b.Name="SkinSource_"..i; b.Position=UDim2.new((i-1)%2/2,0,0,math.floor((i-1)/2)*38); b.Size=UDim2.new(.5,-5,0,34)
            b.BackgroundColor3=engine:skin_source()==source and theme.selected or theme.input
            b.TextColor3=engine:skin_source()==source and theme.accent or theme.muted
        end
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
        assert(validated.theme_mode=="Graphite" or validated.theme_mode=="Slate" or validated.theme_mode=="Light","Unknown theme")
        local meter_valid={Vertical=true,Rocket=true,Bat=true,Funnel=true,Hoop=true,Roblox=true,None=true}
        assert(meter_valid[validated.meter_style],"Unknown meter style")
        engine:stop(); for key,value in pairs(validated) do engine.settings[key]=value end; ui.set_theme(engine.settings.theme_mode)
    end
    rebuild=function()
        page=category=="Visual+" and visual_page or modules_page; container=page
        clear(); buttons={}
        if section_button then section_button.Parent=page; section_button.Visible=category~="Visual+" end
        if section_button then section_button.Text=(category=="All" and "All modules" or category).."  ▾" end
        if choosing then
            for _,name in ipairs(tabs) do action(name,function() category=name; choosing=false; expanded=nil; page.CanvasPosition=Vector2.new(0,0); rebuild() end) end
        elseif category=="Visual+" then
            y=0
            local header=text(visual_section,22,theme.text,30); header.Font=Enum.Font.SourceSansSemibold
            visual_status_label=own(ui.label(container,"0 active",0,5,100,22,12,theme.accent)); visual_status_label.Position=UDim2.new(1,-110,0,5); visual_status_label.TextXAlignment=Enum.TextXAlignment.Right
            local categories={"Ball","Court","Outfit","Effects","Lighting","HUD","Loadouts"}
            local columns=window.Size.X.Offset<560 and 4 or 7; local nav_height=columns==4 and 76 or 38
            local nav=own(make("Frame",{Name="VisualSections",Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,nav_height),BackgroundTransparency=1},container)); y=y+nav_height+10
            for i,name in ipairs(categories) do
                local b=ui.button(nav,name,function() visual_section=name; page.CanvasPosition=Vector2.new(0,0); rebuild() end)
                b.Name="VisualSection_"..name; b.Position=UDim2.new(((i-1)%columns)/columns,0,0,math.floor((i-1)/columns)*38); b.Size=UDim2.new(1/columns,-5,0,34); b.BackgroundColor3=visual_section==name and theme.selected or theme.base
                local outline=b:FindFirstChildWhichIsA("UIStroke"); if outline then outline.Transparency=1 end
                if visual_section==name then make("Frame",{Name="ActiveSection",Position=UDim2.new(0,12,1,-2),Size=UDim2.new(1,-24,0,2),BackgroundColor3=theme.accent,BorderSizePixel=0},b) end
            end
            local function module_toggle(id)
                local definition=engine.registry.definitions[id]
                toggle_action(definition.title,function() return engine.registry.active[id]~=nil end,function(on)
                    if on then
                        if id=="wing_trails" and not engine.registry.active.wings then local ok,err=engine.registry:enable("wings",engine.settings); assert(ok,err) end
                        local ok,err=engine.registry:enable(id,engine.settings); assert(ok,err)
                    else engine.registry:disable(id) end
                end)
            end
            local function controls(id)
                for _,entry in ipairs((engine.cosmetic_choices or {})[id] or {}) do if engine:show_cosmetic_control(entry[1]) then choice(entry[1],entry[2],entry[3]) end end
                for _,entry in ipairs((engine.cosmetic_fields or {})[id] or {}) do if engine:show_cosmetic_control(entry[1]) then field(entry[1],entry[2]) end end
                for _,entry in ipairs((engine.cosmetic_toggles or {})[id] or {}) do local key=entry[1]; if engine:show_cosmetic_control(key) then toggle_action(entry[2],function() return engine.settings[key] end,function(on) engine.settings[key]=on end) end end
            end
            local function preset(key,caption,values,apply)
                action(caption.."  /  "..engine.settings[key],function()
                    local index=1; for i,name in ipairs(values) do if engine.settings[key]==name then index=i end end
                    apply(values[index%#values+1]); rebuild()
                end)
            end
            if visual_section=="Ball" then
                text("FINISH",12,theme.muted,18)
                preset("ball_finish","Finish",engine.ball_finishes,function(name) engine:apply_ball_finish(name) end)
                local preview=own(make("ViewportFrame",{Name="BallFinishPreview",Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,128),BackgroundColor3=theme.panel,BorderSizePixel=0,Ambient=Color3.fromRGB(185,190,205),LightColor=Color3.fromRGB(255,255,255)},container)); y=y+138
                local ball=make("Part",{Name="PreviewBall",Shape=Enum.PartType.Ball,Size=Vector3.new(3,3,3),Position=Vector3.new(0,0,0),Anchored=true,CanCollide=false,Material=Enum.Material[engine.settings.ball_material],Color=Core.hex_color(engine.settings.ball_color),Reflectance=engine.settings.ball_reflectance},preview)
                local camera=make("Camera",{CFrame=CFrame.new(0,0,7),FieldOfView=35},preview); preview.CurrentCamera=camera
                module_toggle("ball_appearance")
                action(visual_ball_details and "Ball controls  −" or "Ball controls  +",function() visual_ball_details=not visual_ball_details; rebuild() end)
                if visual_ball_details then controls("ball_appearance") end
                module_toggle("ball_trail")
                action(visual_trail_details and "Trail controls  −" or "Trail controls  +",function() visual_trail_details=not visual_trail_details; rebuild() end)
                if visual_trail_details then controls("ball_trail") end
            elseif visual_section=="Court" then
                toggle_action("Preserve original court markings",function() return engine.settings.court_native_lines end,function(on) engine.settings.court_native_lines=on; rebuild() end)
                if engine.settings.court_native_lines then text("Original material and line artwork stay intact. Floor tint remains adjustable.",12,theme.muted,38) end
                preset("court_preset","Court preset",engine.court_presets,function(name) engine:apply_court_preset(name) end)
                module_toggle("court_appearance")
                action("Select floor beneath me",function() engine:select_court_under_player() end)
                controls("court_appearance")
                if not engine.settings.court_native_lines then action(court_alignment and "Marking alignment  −" or "Marking alignment  +",function() court_alignment=not court_alignment; rebuild() end) end
                if court_alignment and not engine.settings.court_native_lines then
                    field("court_marking_forward","Forward offset / studs"); field("court_marking_side","Sideways offset / studs"); field("court_marking_rotation","Rotation / degrees")
                    field("court_three_radius","Three-point radius"); field("court_three_angle","Three-point arc angle"); field("court_free_radius","Free-throw radius"); field("court_line_width","Line width")
                    action("Reset marking offsets",function() engine.settings.court_marking_forward=0; engine.settings.court_marking_side=0; engine.settings.court_marking_rotation=0; rebuild() end)
                end
                text("Team colors uses the floor and marking colors you choose above.",12,theme.muted,32)
            elseif visual_section=="Outfit" then
                skin_source_control()
                if engine:skin_source()=="Preset character" then
                action("Character  /  "..engine.settings.model_preset,function() visual_character_open=not visual_character_open; rebuild() end)
                if visual_character_open then
                    local list=own(make("ScrollingFrame",{Name="VisualCharacterList",Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,168),BackgroundColor3=theme.panel,BorderSizePixel=0,ScrollBarThickness=3,CanvasSize=UDim2.fromOffset(0,#engine.characters*32)},container)); y=y+178
                    local n=0; for _,entry in ipairs(engine.characters) do if entry.name~="Custom" then local name=entry.name; local b=ui.button(list,name,function() engine.settings.model_preset=name; visual_character_open=false; visual_preview_open=false; rebuild() end); b.Position=UDim2.fromOffset(0,n*32); b.Size=UDim2.new(1,-8,0,30); n=n+1 end end
                end
                elseif engine:skin_source()=="Outfit ID" then field("model_outfit","Outfit ID")
                elseif engine:skin_source()=="Roblox username" then field("model_username","Username / user ID")
                else field("model_asset","Roblox model ID") end
                if visual_preview_open then
                    visual_character_preview=own(make("ViewportFrame",{Name="CharacterPreview",Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,220),BackgroundColor3=theme.panel,BorderSizePixel=0,Ambient=Color3.fromRGB(180,185,200),LightColor=Color3.fromRGB(255,255,255)},container)); y=y+230
                end
                action("Preview selected character",function()
                    if not visual_preview_open then visual_preview_open=true; rebuild() end
                    local preview=visual_character_preview
                    report("Loading preview…")
                    task.spawn(function() local ok,err=pcall(function() engine:preview_character(preview,engine.settings.model_preset) end); report(ok and "Preview ready / use Equip to apply" or "Preview unavailable: "..tostring(err)) end)
                end)
                action("Equip selected character",function() engine:equip_selected_character(); rebuild() end)
                module_toggle("custom_model")
                toggle_action("Headless",function() return engine.settings.model_headless end,function(on) engine.settings.model_headless=on; visual_preview_open=false; rebuild() end)
                for _,entry in ipairs({{"model_show_hair","Hair"},{"model_show_hats","Hats / headbands"},{"model_show_masks","Masks / glasses"},{"model_show_capes","Capes / coats"},{"model_show_weapons","Weapons"},{"model_show_extras","Other accessories"}}) do
                    local key=entry[1]; toggle_action(entry[2],function() return engine.settings[key] end,function(on)
                        engine.settings[key]=on
                        if engine.registry.active.custom_model then engine.registry:disable("custom_model"); local ok,err=engine.registry:enable("custom_model",engine.settings); assert(ok,err) end
                    end)
                end
                module_toggle("reactive_outfit")
                action(visual_reactive_open and "Reactive outfit controls  −" or "Reactive outfit controls  +",function() visual_reactive_open=not visual_reactive_open; rebuild() end)
                if visual_reactive_open then
                    for _,entry in ipairs({{"reactive_motion","React to movement"},{"reactive_possession","React to possession"},{"reactive_shots","React to shot feedback"},{"reactive_clothes","Tint clothing"},{"reactive_effects","Match active effects"}}) do local key=entry[1]; toggle_action(entry[2],function() return engine.settings[key] end,function(on) engine.settings[key]=on end) end
                    field("reactive_idle_color","Idle color"); field("reactive_move_color","Moving color"); field("reactive_ball_color","Possession color"); field("reactive_perfect_color","Perfect feedback color"); field("reactive_miss_color","Other feedback color")
                    field("reactive_speed","Movement color speed"); field("reactive_response","Transition speed"); field("reactive_flash","Feedback flash duration"); field("reactive_tint","Clothing tint strength")
                end
                module_toggle("outfit_tint"); field("jersey_color","Jersey tint"); field("shoe_color","Shoes / effect color")
                for _,entry in ipairs({{"outfit_jersey","Tint jersey / shorts"},{"outfit_shoes","Tint shoes"},{"outfit_accessories","Tint accessories"}}) do local key=entry[1]; toggle_action(entry[2],function() return engine.settings[key] end,function(on) engine.settings[key]=on end) end
            elseif visual_section=="Effects" then
                local filters={"All","Character","Ball","Court"}
                local filter_row=own(make("Frame",{Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,32),BackgroundTransparency=1},container)); y=y+42
                for i,name in ipairs(filters) do
                    local b=ui.button(filter_row,name,function() visual_effect_filter=name; page.CanvasPosition=Vector2.new(0,0); rebuild() end)
                    b.Name="EffectFilter_"..name; b.Position=UDim2.new((i-1)/4,0,0,0); b.Size=UDim2.new(.25,-5,0,30); b.BackgroundColor3=visual_effect_filter==name and theme.selected or theme.input
                end
                local function effect_card(id,group,caption,description,draw)
                    if visual_effect_filter~="All" and visual_effect_filter~=group then return end
                    local open=visual_effect_cards[id]==true; local outer,top=container,y
                    local card=own(make("Frame",{Name="ModuleRow_"..id,Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,58),BackgroundColor3=theme.panel,BorderSizePixel=0},container))
                    make("UICorner",{CornerRadius=UDim.new(0,8)},card)
                    make("UIStroke",{Color=theme.line,Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},card)
                    make("Frame",{Name="StateMark",Position=UDim2.fromOffset(0,14),Size=UDim2.fromOffset(3,30),BackgroundColor3=theme.accent,BorderSizePixel=0,Visible=false},card)
                    local emblem=make("Frame",{Name="EffectEmblem",Position=UDim2.fromOffset(12,12),Size=UDim2.fromOffset(34,34),BackgroundColor3=theme.input,BorderSizePixel=0},card)
                    make("UICorner",{CornerRadius=UDim.new(0,10)},emblem); ui.icon(emblem,"Visual+",7,7,theme.accent)
                    local title=ui.label(card,engine.registry.definitions[id].title,58,7,300,24,14,theme.text); title.Font=Enum.Font.SourceSansSemibold; title.Size=UDim2.new(1,-156,0,24)
                    local subtitle=ui.label(card,description,58,31,300,18,11,theme.muted); subtitle.Size=UDim2.new(1,-156,0,18); subtitle.TextWrapped=false; subtitle.TextTruncate=Enum.TextTruncate.AtEnd
                    local hit=make("TextButton",{Name="EffectHeaderHit",Text="",TextTransparency=1,BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.new(1,-105,0,58)},card)
                    connect(hit.Activated,function() if engine.registry.active[id] then engine.registry:disable(id) else local ok,err=engine.registry:enable(id,engine.settings); if not ok then report(tostring(err)) end end; update_buttons() end)
                    ui.hover(hit,{surface=card,rounding=8,growth=2})
                    local detail=ui.button(card,caption..(open and "  −" or "  +"),function() visual_effect_cards[id]=not open; rebuild() end)
                    detail.Name="EffectDetails"; detail.Position=UDim2.new(1,-88,0,13); detail.Size=UDim2.fromOffset(30,30); detail.TextTransparency=1; detail.BackgroundColor3=theme.input
                    local symbol=ui.label(detail,open and "−" or "+",0,0,30,30,16,theme.muted); symbol.TextXAlignment=Enum.TextXAlignment.Center
                    buttons[id]=switch(card,function()
                        if engine.registry.active[id] then engine.registry:disable(id)
                        else local ok,err=engine.registry:enable(id,engine.settings); if not ok then report(tostring(err)) end end
                        update_buttons()
                    end); buttons[id].Position=UDim2.new(1,-49,0,16)
                    if open then
                        make("Frame",{Position=UDim2.fromOffset(12,57),Size=UDim2.new(1,-24,0,1),BackgroundColor3=theme.line,BorderSizePixel=0},card)
                        local body=make("Frame",{Position=UDim2.fromOffset(12,70),Size=UDim2.new(1,-24,0,0),BackgroundTransparency=1},card)
                        container=body; y=0; draw(); body.Size=UDim2.new(1,-24,0,y); card.Size=UDim2.new(1,-6,0,y+80)
                    end
                    container=outer; y=top+card.Size.Y.Offset+10
                end
                effect_card("lightning_aura","Character","Lightning controls","Branching bolts with smooth pulses",function()
                    field("lightning_color","Bolt color"); field("lightning_core_color","Bolt core color"); field("lightning_size","Bolt spread"); field("lightning_intensity","Bolt intensity"); field("lightning_rate","Bolt refresh rate"); field("lightning_smoothness","Shape smoothing")
                    toggle_action("Branching bolts",function() return engine.settings.lightning_branches end,function(on) engine.settings.lightning_branches=on end)
                    toggle_action("Motion streaks",function() return engine.settings.lightning_motion end,function(on) engine.settings.lightning_motion=on end)
                end)
                effect_card("wings","Character","Wing controls","Layered feathers and smooth folding",function()
                    choice("wings_style","Wing style",{"Feather","Bat","Energy"}); field("wings_color","Wing color"); field("wings_tip_color","Tip color"); field("wings_scale","Wing size"); field("wings_opacity","Wing opacity")
                    toggle_action("Animate wings",function() return engine.settings.wings_flap end,function(on) engine.settings.wings_flap=on end); field("wings_speed","Flap speed")
                    toggle_action("Fold while idle",function() return engine.settings.wings_fold_idle end,function(on) engine.settings.wings_fold_idle=on end); field("wings_fold","Idle fold amount")
                    module_toggle("wing_trails"); field("wing_trail_color","Wing trail color"); field("wing_trail_lifetime","Wing trail duration"); field("wing_trail_width","Wing trail width"); field("wing_trail_opacity","Wing trail opacity")
                end)
                effect_card("animated_cape","Character","Cape controls","Animated Galaxy, Snow and Rainbow fabric",function()
                    choice("cape_theme","Cape theme",{"Galaxy","Snow","Rainbow"}); field("cape_size","Cape width"); field("cape_length","Cape length"); field("cape_speed","Animation speed"); field("cape_opacity","Cape opacity")
                end)
                effect_card("animated_tail","Character","Tail controls","A swaying tail with matching theme colors",function()
                    choice("tail_theme","Tail theme",{"Match cape","Galaxy","Snow","Rainbow"}); choice("tail_shape","Tail shape",{"Soft","Slim"}); field("tail_length","Tail length"); field("tail_size","Tail thickness"); field("tail_speed","Tail speed"); field("tail_sway","Tail sway")
                end)
                effect_card("lightning_footsteps","Character","Footstep controls","Electric cracks on each grounded stride",function()
                    field("footlight_color","Footstep color"); field("footlight_size","Footstep spread"); field("footlight_duration","Footstep duration")
                end)
                effect_card("electric_ball_trail","Ball","Electric trail controls","Fading bolts behind moving balls",function()
                    field("ball_electric_color","Electric trail color"); field("ball_electric_width","Electric trail width"); field("ball_electric_duration","Electric trail duration")
                end)
                effect_card("dunk_lightning","Court","Dunk lightning controls","Rim-to-floor bolt on a dunk release",function()
                    field("dunk_lightning_color","Dunk bolt color"); field("dunk_lightning_strength","Dunk bolt intensity"); field("dunk_lightning_duration","Dunk bolt duration"); action("Preview dunk lightning",function() engine:preview_dunk_lightning() end)
                end)
                effect_card("rim_effects","Court","Rim controls","Rim glow, animated color and basket flash",function()
                    field("rim_color","Rim color")
                    for _,entry in ipairs({{"rim_glow","Rim glow"},{"rim_animated","Animated rim color"},{"rim_flash","Basket flash"}}) do local key=entry[1]; toggle_action(entry[2],function() return engine.settings[key] end,function(on) engine.settings[key]=on end) end
                    field("rim_flash_duration","Flash duration"); action("Preview rim flash",function() engine:preview_rim_flash() end)
                end)
                effect_card("character_aura","Character","Aura controls","Sparks, mist or orbiting lights",function()
                    choice("aura_style","Aura style",{"Sparks","Mist","Orbit"}); field("aura_color","Aura color"); field("aura_density","Particle density"); field("aura_size","Aura size"); field("aura_opacity","Aura opacity")
                end)
                effect_card("ball_impacts","Ball","Impact controls","Short rings and sparks on floor bounces",function()
                    choice("impact_style","Impact style",{"Ring","Sparks","Both"}); field("impact_color","Impact color"); field("impact_size","Impact size"); field("impact_strength","Impact strength"); action("Preview ball impact",function() engine:preview_ball_impact() end)
                end)
                effect_card("player_indicator","Character","Indicator controls","Ring, segments or a direction arrow",function()
                    choice("indicator_style","Indicator",{"Ring","Segmented","Arrow"}); field("indicator_color","Indicator color"); field("indicator_radius","Indicator size"); field("indicator_opacity","Indicator opacity")
                end)
                effect_card("shoe_effects","Character","Shoe controls","Foot trails and landing particles",function()
                    field("shoe_color","Shoe effect color"); field("effect_strength","Effect strength")
                    toggle_action("Shoe trails",function() return engine.settings.shoe_trail end,function(on) engine.settings.shoe_trail=on end)
                    toggle_action("Landing particles",function() return engine.settings.landing_particles end,function(on) engine.settings.landing_particles=on end)
                end)
                effect_card("green_effect","Court","Perfect effect controls","A short badge or edge flash",function()
                    choice("green_style","Perfect effect",{"Badge","Edge flash"}); field("green_color","Perfect effect color"); field("green_duration","Duration / seconds")
                    action("Preview perfect effect",function() local active=engine.registry.active.green_effect; assert(active,"Enable Perfect shot effect first"); active.state.untilTime=os.clock()+engine.settings.green_duration end)
                end)

            elseif visual_section=="Lighting" then
                module_toggle("lighting_preset"); choice("lighting_preset","Lighting preset",{"Warm gym","Cool arena","Sunset","Night"}); field("lighting_intensity","Color grade intensity")
                text("Disable Sky and other lighting overrides before using Lighting preset.",12,theme.muted,34)
                module_toggle("sky"); controls("sky")
            elseif visual_section=="Loadouts" then
                text("Save your outfit, wings, aura, ball, court and lighting as one look.",12,theme.muted,38)
                if engine.cosmetic_loadout_status then text(engine.cosmetic_loadout_status,12,theme.muted,60) end
                field("cosmetic_loadout_name","Look name")
                action("Save current look",function() engine:save_cosmetic_loadout(fields.cosmetic_loadout_name.Text); rebuild() end)
                action("Refresh looks from disk",function() local count=engine:read_cosmetic_loadouts(); report("Read "..count.." cosmetic loadouts"); rebuild() end)
                for i,item in ipairs(engine.cosmetic_loadouts.loadouts) do
                    local index=i
                    local b=action(item.name.." · "..#item.enabled.." cosmetics · Load",function() engine:load_cosmetic_loadout(index); rebuild() end); b.Size=UDim2.new(1,-50,0,30)
                    local remove=own(ui.button(container,"×",function() local ok,err=pcall(function() engine:remove_cosmetic_loadout(index); rebuild() end); if not ok then report(tostring(err)) end end)); remove.Position=UDim2.new(1,-42,0,y-36); remove.Size=UDim2.fromOffset(34,30)
                    local names={}; for _,id in ipairs(item.enabled) do names[#names+1]=engine.registry.definitions[id].title end
                    text(#names>0 and table.concat(names,", ") or "Original appearance / cosmetic effects off",12,theme.muted,38)
                end
            else
                choice("theme_mode","Menu theme",{"Graphite","Slate","Light"})
                toggle_action("Theme editor",function() return engine.settings.theme_custom end,function(on) engine.settings.theme_custom=on; ui.set_theme(engine.settings.theme_mode); ui.edit_theme(engine.settings); rebuild() end)
                if engine.settings.theme_custom then field("ui_accent","Accent color"); field("ui_font_size","Text size"); field("ui_rounding","Corner radius"); field("ui_opacity","Menu opacity") end
                module_toggle("controller_hud")
                action(visual_controller_open and "Controller controls  −" or "Controller controls  +",function() visual_controller_open=not visual_controller_open; rebuild() end)
                if visual_controller_open then field("controller_scale","Controller size"); field("controller_opacity","Controller opacity"); field("controller_top","Distance from top") end
                module_toggle("coverage_hud"); controls("coverage_hud")
                toggle_action("Shooting HUD",function() return engine.settings.shot_hud end,function(on) engine.settings.shot_hud=on end)
                toggle_action("Compact shooting HUD",function() return engine.settings.shot_hud_compact end,function(on) engine.settings.shot_hud_compact=on end)
                module_toggle("crosshair"); controls("crosshair")
            end

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
            local box=own(make("TextBox",{Name="RecordingImport",Text="",PlaceholderText="Paste recording JSON",ClearTextOnFocus=false,MultiLine=true,Font=Enum.Font.RobotoMono,TextSize=14,TextColor3=theme.text,BackgroundColor3=theme.input,BorderSizePixel=0,Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,76)},container)); y=y+82
            action("Import pasted recording",function() assert(#box.Text<=32768,"JSON exceeds 32 KB"); local value,err=Core.validate_recording(http:JSONDecode(box.Text)); assert(value,err); stop_capture(); engine.recording=value; report("Imported "..#value.steps.." steps") end)
            action("Save recording to disk",function() assert(type(writefile)=="function","Disk write unavailable"); local value,err=Core.validate_recording(engine.recording); assert(value,err); writefile("pivot_recording.json",http:JSONEncode(value)); report("Saved pivot_recording.json") end)
            action("Load recording from disk",function() assert(type(readfile)=="function","Disk read unavailable"); local raw=readfile("pivot_recording.json"); assert(#raw<=32768,"Recording exceeds size limit"); local value,err=Core.validate_recording(http:JSONDecode(raw)); assert(value,err); stop_capture(); engine.recording=value; report("Loaded recording") end)
            end
        elseif category=="Saved modules" then
            if engine.module_preset_status then text(engine.module_preset_status,12,theme.muted,76) end
            module_selection_label=text("Selected: checking enabled modules…",12,theme.muted,38)
            field("module_preset_name","Preset name")
            action("Save enabled modules",function() engine:save_enabled_modules(fields.module_preset_name.Text); rebuild() end)
            action("Refresh preset list from disk",function() local count=engine:read_saved_modules(); report("Read "..count.." presets / click a preset's Load to enable its modules"); rebuild() end)
            for i,item in ipairs(engine.saved_modules.presets) do
                local index=i
                local button=action(item.name.." · "..#item.enabled.." modules · Load",function() engine:load_saved_modules(index); ui.set_theme(engine.settings.theme_mode); ui.edit_theme(engine.settings); rebuild() end)
                button.Size=UDim2.new(1,-50,0,30)
                local remove=own(ui.button(container,"×",function() engine:remove_saved_modules(index); rebuild() end)); remove.Position=UDim2.new(1,-42,0,y-36); remove.Size=UDim2.fromOffset(34,30)
                local names={}; for _,id in ipairs(item.enabled) do names[#names+1]=engine.registry.definitions[id].title end
                text(#names>0 and table.concat(names,", ") or "Empty preset — enable your modules and save again",11,theme.muted,32)
            end
        elseif category=="Options" then
            text("Settings load without enabling modules.",11,theme.muted)
            choice("theme_mode","Theme",{"Graphite","Slate","Light"})
            toggle_action("Theme editor",function() return engine.settings.theme_custom end,function(on) engine.settings.theme_custom=on; if not on then ui.set_theme(engine.settings.theme_mode) end; ui.edit_theme(engine.settings); rebuild() end)
            if engine.settings.theme_custom then
                field("ui_accent","Accent / #RRGGBB"); field("ui_font_size","Text size"); field("ui_rounding","Corner radius"); field("ui_opacity","Menu opacity")
            end
            field("esp_distance","Overlay distance / studs")
            toggle_action("Team filter",function() return engine.settings.team_check end,function(on) engine.settings.team_check=on end)
            action("Copy module settings",function() export(settings_data()) end)
            action("Save module settings",function() assert(type(writefile)=="function","Disk write unavailable"); writefile("pivot_module_settings.json",http:JSONEncode(settings_data())); report("Saved module settings") end)
            action("Load module settings",function() assert(type(readfile)=="function","Disk read unavailable"); local raw=readfile("pivot_module_settings.json"); assert(#raw<=16384,"Settings exceed size limit"); apply_settings(http:JSONDecode(raw)); rebuild(); report("Loaded settings / all modules off") end)
            action("Disable every module / restore values",function() cancel(); engine:stop(); update_buttons(); report("All modules disabled") end)
        else
            local options={auto_shoot={{"shot_range","Shoot range / studs"}},rim_range={{"shot_range","Shoot range / studs"}},dribble_glide={{"glide_speed","Glide speed"}},auto_ankle={{"ankle_range","Ankle break range"},{"ankle_delay","Attempt interval / seconds"},{"ankle_combo","Dribble inputs"}},dribble_macros={{"custom_combo","Custom combo"},{"combo_delay","Combo delay / ms"},{"combo_bind","Combo keybind / F1–F12"}},auto_takeover={{"takeover_threshold","Takeover threshold"}},speed={{"walk_speed","Client walk speed"}},split_speed={{"on_ball_speed","On-ball speed"},{"off_ball_speed","Off-ball speed"}},jump={{"jump_power","Jump power"}},fly={{"fly_speed","Flight speed"}},spin={{"spin_speed","Degrees / second"}},guard={{"guard_target","Target username"},{"guard_distance","Guard spacing"},{"guard_range","Activation range"},{"guard_strength","Guard strength"}},block={{"guard_target","Target username"},{"block_range","Activation range"},{"block_delay","Block delay / seconds"},{"jump_key","Jump / block key"}},rebound={{"rebound_range","Activation range"},{"jump_key","Jump key"}},range_circle={{"range","Range / studs"}},time={{"time","Time / 0-24"}},fov={{"fov","Field of view"}},spectate={{"spectate","Target username"}}}
            local groups=category=="All" and {"Shooting","Defense","Dribbling","Cosmetics","Character","Player","Visuals","Camera","World"} or {category}
            local columns=category=="All" and (ui.content_width and ui.content_width() or window.Size.X.Offset)>=620 and 2 or 1
            local heights={46,46}
            local display_definitions={}; for _,definition in ipairs(engine.definitions) do if definition.id=="dribble_library" then table.insert(display_definitions,1,definition) else display_definitions[#display_definitions+1]=definition end end
            for _,group in ipairs(groups) do
                local column=columns==2 and (heights[1]<=heights[2] and 1 or 2) or 1
                local card=own(make("Frame",{Name="Group_"..group,Position=UDim2.new((column-1)/columns,(column-1)*4,0,heights[column]),Size=UDim2.new(1/columns,columns==2 and -10 or -6,0,40),BackgroundColor3=theme.panel,BorderSizePixel=0},page))
                make("UICorner",{CornerRadius=UDim.new(0,9)},card)
                make("UIStroke",{Color=theme.line,Transparency=.35,Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},card)
                local header=ui.button(card,group..(collapsed[group] and "  +" or "  −"),function() collapsed[group]=not collapsed[group]; rebuild() end)
                header.Size=UDim2.new(1,-28,0,44); header.Position=UDim2.fromOffset(14,0); header.Font=Enum.Font.SourceSansSemibold; header.TextSize=18; header.BackgroundTransparency=1; header.TextXAlignment=Enum.TextXAlignment.Left
                local divider=make("Frame",{Position=UDim2.fromOffset(14,44),Size=UDim2.new(1,-28,0,1),BackgroundColor3=theme.line,BorderSizePixel=0},card)
                divider.Visible=not collapsed[group]
                container=card; y=52
                if not collapsed[group] and group=="Character" then
                    skin_source_control()
                    if engine:skin_source()=="Preset character" then
                    choice("model_catalog","Presets",{"Curated","All"})
                    local choices={}; for _,entry in ipairs(engine:character_choices()) do if entry.name~="Custom" then choices[#choices+1]=entry end end
                    local selector=action("Character  /  "..engine.settings.model_preset..(character_open and "  ▴" or "  ▾"),function() character_open=not character_open; rebuild() end)
                    selector.Name="CharacterDropdown"
                    if character_open then
                        local menu=make("ScrollingFrame",{Name="CharacterOptions",Position=UDim2.fromOffset(6,y),Size=UDim2.new(1,-12,0,168),CanvasSize=UDim2.fromOffset(0,#choices*30),ScrollBarThickness=3,ScrollBarImageColor3=theme.accent,BackgroundColor3=theme.input,BorderSizePixel=0},card)
                        make("UICorner",{CornerRadius=UDim.new(0,4)},menu)
                        for i,entry in ipairs(choices) do
                            local item=ui.button(menu,entry.name,function()
                                local ok,err=pcall(function() engine:select_character(entry.name) end); if not ok then report(tostring(err)) end
                                character_open=false
                                if engine.settings.model_preset=="Custom" then expanded="custom_model" end
                                rebuild()
                            end)
                            item.Name="Character_"..entry.name; item.Position=UDim2.fromOffset(4,(i-1)*30); item.Size=UDim2.new(1,-12,0,28)
                            item.TextXAlignment=Enum.TextXAlignment.Left
                            make("UIPadding",{PaddingLeft=UDim.new(0,8)},item)
                            item.BackgroundColor3=engine.settings.model_preset==entry.name and theme.selected or theme.input
                            item.TextColor3=engine.settings.model_preset==entry.name and theme.accent or theme.text
                        end
                        y=y+176
                    end
                    else
                        if engine:skin_source()=="Outfit ID" then field("model_outfit","Outfit ID")
                        elseif engine:skin_source()=="Roblox username" then field("model_username","Username / user ID")
                        else field("model_asset","Roblox model ID") end
                    end
                    action("Equip selected character",function() engine:equip_selected_character(); rebuild() end)
                    action("Saved models  /  "..#engine.model_library.models..(library_open and "  −" or "  +"),function() library_open=not library_open; rebuild() end)
                    if library_open then
                        library_status=text("Saved models stay in pivot_models.json",11,theme.muted,24)
                        field("model_save_name","Save as")
                        action("Save current model",function() engine:save_current_model(engine.settings.model_save_name); rebuild() end)
                        action("Preload all saved models",function() engine:preload_model_library() end)
                        action("Reload saved library",function() local count=engine:read_model_library(); report("Loaded "..count.." saved models"); rebuild() end)
                        if #engine.model_library.models>0 then
                            local height=math.min(170,#engine.model_library.models*34)
                            local list=make("ScrollingFrame",{Name="SavedModelList",Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,height),CanvasSize=UDim2.fromOffset(0,#engine.model_library.models*34),ScrollBarThickness=3,BackgroundTransparency=1,BorderSizePixel=0},container)
                            for i,item in ipairs(engine.model_library.models) do
                                local index=i
                                local button=ui.button(list,item.name.."  ·  Equip",function() local ok,err=pcall(function() engine:equip_saved_model(index) end); if not ok then report(tostring(err)) end; rebuild() end)
                                button.Position=UDim2.fromOffset(0,(i-1)*34); button.Size=UDim2.new(1,-45,0,30)
                                local remove=ui.button(list,"×",function() engine:remove_saved_model(index); rebuild() end); remove.Position=UDim2.new(1,-40,0,(i-1)*34); remove.Size=UDim2.fromOffset(32,30)
                            end
                            y=y+height+8
                        end
                    end
                    local active=engine.registry.active.custom_model
                    character_status=text("Selected: "..engine.settings.model_preset.." · "..(active and active.state.rig_label or "Enable Character skin to load"),12,theme.muted,38)
                end
                if not collapsed[group] then
            for _,definition in ipairs(display_definitions) do
                if definition.category==group then
                    local id=definition.id
                    local row=own(make("Frame",{Name="ModuleRow_"..id,Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,0,0,60),BackgroundColor3=theme.panel,BackgroundTransparency=1,BorderSizePixel=0},container))
                    make("UICorner",{CornerRadius=UDim.new(0,5)},row)
                    make("Frame",{Name="StateMark",Position=UDim2.fromOffset(3,9),Size=UDim2.fromOffset(2,18),BackgroundColor3=theme.accent,BorderSizePixel=0,Visible=false},row)
                    local symbol=ui.icon(row,definition.category=="Shooting" and "Shot Lab" or definition.category=="Character" and "Visual+" or "Modules",12,17,theme.muted)
                    local title=ui.label(row,definition.title,44,7,300,24,14,theme.text); title.Font=Enum.Font.SourceSansSemibold; title.Size=UDim2.new(1,-130,0,24)
                    local summary=ui.label(row,definition.description,44,32,300,18,11,theme.muted); summary.Size=UDim2.new(1,-130,0,18); summary.TextWrapped=false; summary.TextTruncate=Enum.TextTruncate.AtEnd

                    local detail=ui.button(row,expanded==id and "−" or "+",function() if expanded==id then expanded=nil else expanded=id end; rebuild() end)
                    detail.Name="Details"; detail.Position=UDim2.new(1,-88,0,18); detail.Size=UDim2.fromOffset(24,24); detail.BackgroundTransparency=1
                    buttons[id]=switch(row,function()
                        if engine.registry.active[id] then engine.registry:disable(id) else local ok,err=engine.registry:enable(id,engine.settings); if not ok then report(tostring(err)) end end
                        update_buttons()
                    end)
                    buttons[id].Position=UDim2.new(1,-54,0,17)
                    connect(row.MouseEnter,function() row.BackgroundColor3=theme.panel; row.BackgroundTransparency=.25 end)
                    connect(row.MouseLeave,function() row.BackgroundColor3=engine.registry.active[id] and theme.selected or theme.panel; row.BackgroundTransparency=engine.registry.active[id] and .4 or 1 end)
                    make("Frame",{Name="RowDivider",Position=UDim2.new(0,44,1,-1),Size=UDim2.new(1,-58,0,1),BackgroundColor3=theme.line,BackgroundTransparency=.65,BorderSizePixel=0},row)
                    y=y+64
                    if expanded==id then
                        text(definition.description,12,theme.muted,id=="dribble_library" and 40 or 60).TextWrapped=true
                        for _,entry in ipairs(options[id] or {}) do field(entry[1],entry[2]) end
                        for _,entry in ipairs((engine.cosmetic_choices or {})[id] or {}) do if engine:show_cosmetic_control(entry[1]) then choice(entry[1],entry[2],entry[3]) end end
                        for _,entry in ipairs((engine.cosmetic_fields or {})[id] or {}) do if engine:show_cosmetic_control(entry[1]) and entry[1]~="model_asset" and (entry[1]~="model_height" or not engine.settings.model_fit_pb) then field(entry[1],entry[2]) end end
                        for _,entry in ipairs((engine.cosmetic_toggles or {})[id] or {}) do local key=entry[1]; if (key~="model_follow_pose" or not engine.settings.model_fit_pb) and engine:show_cosmetic_control(key) then toggle_action(entry[2],function() return engine.settings[key] end,function(on) engine.settings[key]=on; if key=="model_fit_pb" then local active=engine.registry.active.custom_model; if active then engine.registry:disable("custom_model"); local ok,err=engine.registry:enable("custom_model",engine.settings); if not ok then report(tostring(err)) end end; rebuild() end end) end end
                        if id=="dribble_library" then
                            toggle_action("Sprint variants",function() return engine.settings.dribble_sprint end,function(on) engine.settings.dribble_sprint=on end)
                            text("Key: bind    +: add to chain    Run: play move",11,theme.muted,24)
                            action("Combo builder / "..#engine.dribble_draft.." moves"..(dribble_editor_open and "  −" or "  +"),function() dribble_editor_open=not dribble_editor_open; rebuild() end)
                            if dribble_editor_open then
                                field("dribble_gap","Gap between moves / ms")
                                local names={}; for _,step in ipairs(engine.dribble_draft) do for _,move in ipairs(engine.dribble_moves) do if move.id==step.move then names[#names+1]=move.name..(step.sprint and " (sprint)" or "") end end end
                                text(#names>0 and table.concat(names," → ") or "Add moves from the library below.",11,theme.muted,48)
                                field("dribble_combo_name","Combo name")
                                action("Save combo",function() engine:save_dribble_combo(engine.settings.dribble_combo_name); rebuild() end)
                                action("Run chain",function() engine:play_dribble_steps(engine.dribble_draft,engine.settings.dribble_gap) end)
                                action("Undo last move",function() table.remove(engine.dribble_draft); rebuild() end)
                                action("Clear chain",function() engine.dribble_draft={}; rebuild() end)
                            end
                            local move_list=make("ScrollingFrame",{Name="DribbleMoveList",Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,220),CanvasSize=UDim2.fromOffset(0,#engine.dribble_moves*44),ScrollBarThickness=3,BackgroundTransparency=1,BorderSizePixel=0},container)
                            for i,move in ipairs(engine.dribble_moves) do
                                local id=move.id
                                local row=make("Frame",{Name="Move_"..id,Position=UDim2.fromOffset(0,(i-1)*44),Size=UDim2.new(1,-5,0,40),BackgroundColor3=theme.input,BorderSizePixel=0},move_list)
                                make("UICorner",{CornerRadius=UDim.new(0,4)},row)
                                local title=ui.label(row,move.name.."  ·  "..move.code,8,0,100,40,11,theme.text); title.Size=UDim2.new(1,-144,1,0)
                                local bind=ui.button(row,engine.dribble_library.bindings[id] or "None",function() local ok,err=pcall(function() engine:cycle_dribble_binding(id) end); if not ok then report(tostring(err)) end; rebuild() end)
                                bind.Name="MoveBind_"..id; bind.Position=UDim2.new(1,-130,0,5); bind.Size=UDim2.fromOffset(58,30)
                                local plus=ui.button(row,"+",function() local ok,err=pcall(function() engine:add_dribble_move(id) end); if not ok then report(tostring(err)) end; dribble_editor_open=true; rebuild() end)
                                plus.Name="MoveAdd_"..id; plus.Position=UDim2.new(1,-66,0,5); plus.Size=UDim2.fromOffset(28,30)
                                local play=ui.button(row,"Run",function() local ok,err=pcall(function() engine:play_dribble_move(id) end); if not ok then report(tostring(err)) end end)
                                play.Name="MoveRun_"..id; play.Position=UDim2.new(1,-34,0,5); play.Size=UDim2.fromOffset(30,30)
                            end
                            y=y+228
                            if #engine.dribble_library.combos>0 then text("Saved combos",12,theme.text,24) end
                            for i,combo in ipairs(engine.dribble_library.combos) do
                                local index=i
                                local row=own(make("Frame",{Name="DribbleCombo_"..i,Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,36),BackgroundColor3=theme.input,BorderSizePixel=0},container)); y=y+42
                                local play=ui.button(row,combo.name,function() local ok,err=pcall(function() local saved=engine.dribble_library.combos[index]; engine:play_dribble_steps(saved.steps,saved.gap) end); if not ok then report(tostring(err)) end end); play.Size=UDim2.new(1,-144,1,0)
                                local bind=ui.button(row,combo.key,function() engine:cycle_dribble_binding(nil,index); rebuild() end); bind.Position=UDim2.new(1,-138,0,3); bind.Size=UDim2.fromOffset(54,30)
                                local edit=ui.button(row,"Edit",function() engine:edit_dribble_combo(index); dribble_editor_open=true; rebuild() end); edit.Position=UDim2.new(1,-80,0,3); edit.Size=UDim2.fromOffset(42,30)
                                local remove=ui.button(row,"×",function() engine:remove_dribble_combo(index); rebuild() end); remove.Position=UDim2.new(1,-34,0,3); remove.Size=UDim2.fromOffset(28,30)
                            end

                        elseif id=="meter_release" then
                            text(engine.release_storage_status,12,theme.muted,38)
                            toggle_action("Auto correct",function() return engine.settings.auto_calibrate end,function(on) engine.settings.auto_calibrate=on end)
                            toggle_action("Refine Good releases",function() return engine.settings.good_correction end,function(on) engine.settings.good_correction=on end)
                            toggle_action("Practice refinement",function() return engine.settings.practice_refinement end,function(on) engine.settings.practice_refinement=on end)
                            toggle_action("Perfect rate HUD",function() return engine.settings.shot_hud end,function(on) engine.settings.shot_hud=on end)
                            action("Copy release diagnostics",function() export(engine.shot_stats) end)
                            toggle_action("Ping compensation",function() return engine.settings.ping_compensation end,function(on) engine.settings.ping_compensation=on end)
                            field("ping_factor","Ping compensation strength")
                        elseif id=="custom_model" then
                            action("Copy rendering report",function() export(engine:rendering_report()) end)
                        elseif id=="meter_style" then choice("meter_style","Meter style",{"Vertical","Rocket","Bat","Funnel","Hoop","Roblox","None"})
                        elseif id=="guard" then
                            toggle_action("Guard sprint",function() return engine.settings.guard_sprint end,function(on) engine.settings.guard_sprint=on end)
                            toggle_action("Ball handler only",function() return engine.settings.ball_handler_only end,function(on) engine.settings.ball_handler_only=on end)
                            toggle_action("Team check",function() return engine.settings.team_check end,function(on) engine.settings.team_check=on end)
                        end
                        if id=="court_appearance" then
                            toggle_action("Preserve original court markings",function() return engine.settings.court_native_lines end,function(on) engine.settings.court_native_lines=on; rebuild() end)
                            action("Select floor beneath me",function() engine:select_court_under_player() end)
                            if not engine.settings.court_native_lines then action(court_alignment and "Marking alignment  −" or "Marking alignment  +",function() court_alignment=not court_alignment; rebuild() end) end
                            if court_alignment and not engine.settings.court_native_lines then
                                field("court_marking_forward","Forward offset / studs"); field("court_marking_side","Sideways offset / studs"); field("court_marking_rotation","Rotation / degrees")
                                field("court_three_radius","Three-point radius"); field("court_three_angle","Three-point arc angle"); field("court_free_radius","Free-throw circle radius"); field("court_free_distance","Free-throw fallback distance"); field("court_corner_depth","Corner line depth"); field("court_line_width","Line width")
                            end
                            action("Check detected markings",function() local active=engine.registry.active.court_appearance; report(active and active.state.marking_summary or "Enable Court appearance first") end)
                        end
                        if id=="dribble_macros" then action("Run custom combo",function() engine:run_combo() end) end
                        if id=="guard" then action("Use nearest rim as defensive goal",function() engine:select_defensive_rim() end) end
                        y=y+7
                    end
                end
            end
                end
                card.Size=UDim2.new(1/columns,columns==2 and -10 or -6,0,y+6)
                heights[column]=heights[column]+y+18
                container=page
            end
            y=math.max(heights[1],columns==2 and heights[2] or 0)

        end
        page.CanvasSize=UDim2.fromOffset(0,y+8); update_buttons(); ui.edit_theme(engine.settings)
    end
    section_button=ui.button(page,"All modules  ▾",function() choosing=not choosing; page.CanvasPosition=Vector2.new(0,0); rebuild() end)
    section_button.Name="ModuleCategory"; section_button.Position=UDim2.fromOffset(0,0); section_button.Size=UDim2.fromOffset(142,28)
    local rail=ui.button(window,"Modules",function()
        if category=="Visual+" then category="All"; expanded=nil end
        ui.search.Text=""; ui.show("Modules"); rebuild()
    end)
    rail.Name="ModulesNav"; rail.Position=UDim2.fromOffset(9,302); rail.Size=UDim2.fromOffset(50,54); rail.TextTransparency=1; rail.BackgroundColor3=theme.rail
    rail:SetAttribute("RailItem",true)
    local glyph=ui.icon(rail,"Modules",15,8,theme.muted)
    local caption=ui.label(rail,"Modules",0,33,50,16,10,theme.muted); caption.TextXAlignment=Enum.TextXAlignment.Center
    local indicator=make("Frame",{Position=UDim2.fromOffset(0,17),Size=UDim2.fromOffset(2,18),BackgroundColor3=theme.accent,BorderSizePixel=0,Visible=false},rail)
    ui.pages.Modules=page; ui.rail_items.Modules={button=rail,icon=glyph,label=caption,indicator=indicator}
    glyph.Position=UDim2.fromOffset(7,5); caption.Position=UDim2.fromOffset(33,0); caption.Size=UDim2.new(1,-35,1,0); caption.TextXAlignment=Enum.TextXAlignment.Left
    local visual_rail=ui.button(window,"Visual+",function() category="Visual+"; choosing=false; ui.search.Text=""; ui.show("Visual+"); rebuild() end)
    visual_rail.Name="VisualPlusNav"; visual_rail.TextTransparency=1; visual_rail:SetAttribute("RailItem",true)
    local visual_icon=ui.icon(visual_rail,"Visual+",7,5,theme.muted)
    local visual_label=ui.label(visual_rail,"Visual+",33,0,70,30,12,theme.muted)
    local visual_indicator=make("Frame",{BackgroundColor3=theme.accent,BorderSizePixel=0,Visible=false},visual_rail)
    ui.pages["Visual+"]=visual_page; ui.rail_items["Visual+"]={button=visual_rail,icon=visual_icon,label=visual_label,indicator=visual_indicator}
    ui.layout_nav()
    connect(rail.MouseLeave,function() rail.BackgroundColor3=page.Visible and theme.selected or theme.rail end)
    ui.hide_extra=function() modules_page.Visible=false; visual_page.Visible=false end
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
    for _,entry in ipairs(engine.characters) do
        ui.add_search(entry.name,"Character skin",function()
            ui.search.Text=""; category="Character"; choosing=false; expanded="custom_model"
            local ok,err=pcall(function() engine:select_character(entry.name) end); if not ok then report(tostring(err)) end
            ui.show("Modules"); page.CanvasPosition=Vector2.new(0,0); rebuild()
        end)
    end
    connect(window:GetPropertyChangedSignal("Size"),function() if page.Visible then rebuild() end end)
    rebuild()
end
