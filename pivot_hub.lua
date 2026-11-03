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
    local state={watched={},sent={},metadata=setmetatable({},{__mode="k"}),profiles=deps.profiles or {},pending={},closed=false}
    local function telemetry(event) if deps.telemetry then pcall(deps.telemetry,event) end end
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
        if deps.calibrate and not deps.calibrate() then return end
        local p=pending.profile; local early=code<=3; local late=code>=6
        if early then p.early=math.max(p.early or .25,pending.ratio)
        elseif late then p.late=math.min(p.late or .85,pending.ratio)
        else
            if code==5 then
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
            state.pending[#state.pending+1]={profile=p,ratio=p.ratio,shot=shot,name=name,time=os.clock()}
        end
        if state.observed and state.observed.id==shot then state.observed.sent=true end
        local event={kind="release",shot=shot,name=name,ratio=entry.release_time and profile(track,name).ratio or nil,position=track.TimePosition,speed=track.Speed}
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
            if pending.time and os.clock()-pending.time>8 then table.remove(self.pending,i); telemetry({kind="unconfirmed",shot=pending.shot,name=pending.name}) end
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

function Core.costume_region(width,height,fov,bounds)
    if width<=0 or height<=0 then return nil end
    local half_w,half_h=width/2,height/2
    if bounds then
        half_w=math.min(half_w,math.max(32,math.abs(bounds[1]-width/2),math.abs(bounds[3]-width/2))+16)
        half_h=math.min(half_h,math.max(32,math.abs(bounds[2]-height/2),math.abs(bounds[4]-height/2))+16)
    end
    local left=math.max(0,math.floor(width/2-half_w)); local top=math.max(0,math.floor(height/2-half_h))
    local cropped_h=height-top*2
    return {x=left,y=top,width=width-left*2,height=cropped_h,fov=math.deg(2*math.atan(math.tan(math.rad(fov)/2)*cropped_h/height))}
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
        model_preset="Sasuke",model_catalog="Curated",model_save_name="",model_render_region="Focused",model_style="Basketball",model_renderer="Viewport",model_high_detail=true,model_show_hair=true,model_show_hats=true,model_show_masks=true,model_show_capes=true,model_show_weapons=true,model_show_extras=true,coverage_radius=12,coverage_display="Both",coverage_scale=1,coverage_height=2.6,coverage_response=12,model_fit_pb=true,model_fit_scale=1.015,model_accessory_scale=1,model_face_size=.86,model_face_width=1,model_face_x=0,model_face_y=0,model_asset="",model_height=6,model_offset=0,model_rotation=0,model_follow_pose=true,model_motion=true,model_hide_avatar=true,
        theme_custom=false,ui_accent="#C0C9DC",ui_font_size=14,ui_rounding=6,ui_opacity=1,refine_good=true,shot_hud=true},ranges={coverage_scale={.75,1.5},coverage_height={1,5},coverage_response={2,25},model_face_size={.5,1.2},model_face_width={.65,1.35},model_face_x={-.3,.3},model_face_y={-.3,.3},model_accessory_scale={.5,1.5},coverage_radius={4,20},model_fit_scale={.95,1.12},court_three_radius={20,45},court_three_angle={90,180},court_free_radius={3,12},court_free_distance={10,30},court_corner_depth={0,12},court_line_width={.05,.8},ball_glow_strength={.05,1},ball_bloom={0,2},crosshair_size={2,24},crosshair_gap={0,20},crosshair_thickness={1,6},crosshair_opacity={.1,1},ball_trail_lifetime={.05,2},ball_trail_width={.1,4},ball_trail_opacity={.05,1},player_trail_lifetime={.05,2},player_trail_width={.1,4},player_trail_opacity={.05,1},ball_reflectance={0,1},court_reflectance={0,1},outline_opacity={0,1},outline_fill_opacity={0,1},sky_stars={0,5000},sky_density={0,.6},sky_haze={0,5},model_height={2,12},model_offset={-6,6},model_rotation={0,360},ui_font_size={14,20},ui_rounding={0,14},ui_opacity={.2,1},guard_strength={.5,2},block_delay={0,.5},shot_range={5,60},glide_speed={4,60},ankle_range={2,20},ankle_delay={.5,5},combo_delay={20,500},ping_factor={0,1},takeover_threshold={1,100},walk_speed={4,60},jump_power={10,120},fly_speed={4,100},spin_speed={10,360},fov={40,110},time={0,24},range={5,60},esp_distance={30,1000},guard_distance={2,10},guard_range={5,60},block_range={3,18},steal_range={2,8},on_ball_speed={4,60},off_ball_speed={4,60},rebound_range={3,15}},definitions={},recording={version=1,steps={}}}
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
            refine_good=function() return Engine.settings.refine_good end,
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
    add("meter_release","Auto Green","Shooting","Earlier animation release with automatic Early/Late correction. Keyboard/controller. Live green timing remains experimental.",{start=function(scope)
        character()
        local adapter=shooting_adapter()
        adapter.paused=function() return input:GetFocusedTextBox()~=nil or ctx.runner.current~=nil end
        adapter.report=ctx.report
        adapter.failed=function(err) registry:disable("meter_release"); ctx.report("Auto release stopped / "..err) end
        adapter.profiles=Engine.release_profiles
        local state=Core.animation_release(scope,adapter)
        if Engine.attach_shot_hud then Engine:attach_shot_hud(scope) end
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
    end})
    add("auto_ankle","Auto ankle breaker","Dribbling","Attempts your dribble combo near an opponent; the game decides ankle breaks",{start=function(scope,s)
        local _,keyboard=client_parts(); assert(keyboard.Services.InputService.Dribble,"Dribble endpoint unavailable")
        assert(s.ankle_combo:match("^[ZXCVH]+$") and #s.ankle_combo<=8,"Use up to 8 Z/X/C/V/H inputs")
        return {keyboard=keyboard,last=-10}
    end,step=function(_,state,s)
        local c=local_state(); local attributes=c.data.Attributes
        if not ctx.runner.current and not input:GetFocusedTextBox() and held_ball(rig()) and attributes.Action=="" and opponent_near(s.ankle_range,false) and os.clock()-state.last>=s.ankle_delay then
            state.last=os.clock(); state.keyboard.Services.InputService.Dribble:Fire(s.ankle_combo,true,c.Movement and c.Movement.lastMoveDirection or Vector3.zero)
        end
    end,interval=.1})
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

    local basketball_texture_data={["Sasuke"]={shirt="iVBORw0KGgoAAAANSUhEUgAABJIAAAReCAYAAACMxxrQAAGdlElEQVR42uy9C7xdRXn3/0yAJCBBTU4I55ILFyFeQESSEFAU2yo3SQK2/n3rFdq+BtRq+/+/Rat4o0rf9+37eQtIEC+11ksVyQUt4gXwUi+5iIiIARQBcw4lBGmJgDknyfy71t5rrZlnnmdm1t4nVMnva0832Xvt2WvNmpm11jO/+T1TCAAAAAAAAAAAAACADKagCgAAAAAAAAAAAABADggkAQAAAAAAAAAAAIAsEEgCAAAAAAAAAAAAAFkgkAQAAAAAAAAAAAAAskAgCQAAAAAAAAAAAABkgUASAAAAAAAAAAAAAMgCgSQAAAAAAAAAAAAAkAUCSQAAAAAAAAAAAAAgCwSSAAAAAAAAAAAAAEAWCCQBAAAAAAAAAAAAgCwQSAIAAAAAAAAAAAAAWSCQBAAAAAAAAAAAAACyQCAJAAAAAAAAAAAAAGSBQBIAAAAAAAAAAAAAyAKBJAAAAAAAAAAAAACQBQJJAAAAAAAAAAAAACALBJIAAAAAAAAAAAAAQBYIJAEAAAAAAAAAAACALBBIAgAAAAAAAAAAAABZIJAEAAAAAAAAAAAAALJAIAkAAAAAAAAAAAAAZIFAEgAAAAAAAAAAAADIAoEkAAAAAAAAAAAAAJAFAkkAAAAAAAAAAAAAIAsEkgAAAAAAAAAAAABAFggkAQAAAAAAAAAAAIAsEEgCAAAAAAAAAAAAAFkgkAQAAAAAAAAAAAAAskAgCQAAAAAAAAAAAABkgUASAAAAAAAAAAAAAMgCgSQAAAAAAAAAAAAAkAUCSQAAAAAAAAAAAAAgCwSSAAAAAAAAAAAAAEAWCCQBAAAAAAAAAAAAgCwQSAIAAAAAAAAAAAAAWSCQBAAAAAAAAAAAAACyQCAJAAAAAAAAAAAAAGSBQBIAAAAAAAAAAAAAyAKBJAAAAAAAAAAAAACQBQJJAAAAAAAAAAAAACALBJIAAAAAAAAAAAAAQBYIJAEAAAAAAAAAAACALBBIAgAAAAAAAAAAAABZIJAEAAAAAAAAAAAAALJAIAkAAAAAAAAAAAAAZIFAEgAAAAAAAAAAAADIAoEkAAAAAAAAAAAAAJAFAkkAAAAAAAAAAAAAIAsEkgAAAAAAAAAAAABAFggkAQAAAAAAAAAAAIAsEEgCAAAAAAAAAAAAAFkgkAQAAAAAAAAAAAAAskAgCQAAAAAAAAAAAABkgUASAAAAAAAAAAAAAMgCgSQAAAAAAAAAAAAAkAUCSQAAAAAAAAAAAAAgCwSSAAAAAAAAAAAAAEAWCCQBAAAAAAAAAAAAgCwQSAIAAAAAAAAAAAAAWSCQBAAAAAAAAAAAAACyQCAJAAAAAAAAAAAAAGSBQBIAAAAAAAAAAAAAyAKBJAAAAAAAAAAAAACQBQJJAAAAAAAAAAAAACALBJIAAAAAAAAAAAAAQBYIJAEAAAAAAAAAAACALBBIAgAAAAAAAAAAAABZIJAEAAAAAAAAAAAAALJAIAkAAAAAAAAAAAAAZIFAEgAAAAAAAAAAAADIAoEkAAAAAAAAAAAAAJAFAkkAAAAAAAAAAAAAIAsEkgAAAAAAAAAAAABAFggkAQAAAAAAAAAAAIAsEEgCAAAAAAAAAAAAAFkgkAQAAAAAAAAAAAAAskAgCQAAAAAAAAAAAABkgUASAAAAAAAAAAAAAMgCgSQAAAAAAAAAAAAAkAUCSQAAAAAAAAAAAAAgCwSSAAAAAAAAAAAAAEAWCCQBAAAAAAAAAAAAgCwQSAIAAAAAAAAAAAAAWSCQBAAAAAAAAAAAAACyQCAJAAAAAAAAAAAAAGSBQBIAAAAAAAAAAAAAyAKBJAAAAAAAAAAAAACQBQJJAAAAAAAAAAAAACALBJIAAAAAAAAAAAAAQBYIJAEAAAAAAAAAAACALBBIAgAAAAAAAAAAAABZIJAEAAAAAAAAAAAAALJAIAkAAAAAAAAAAAAAZIFAEgAAAAAAAAAAAADIAoEkAAAAAAAAAAAAAJAFAkkAAAAAAAAAAAAAIAsEkgAAAAAAAAAAAABAFggkAQAAAAAAAAAAAIAsEEgCAAAAAAAAAAAAAFkgkAQAAAAAAAAAAAAAskAgCQAAAAAAAAAAAABkgUASAAAAAAAAAAAAAMgCgSQAAAAAAAAAAAAAkAUCSQAAAAAAAAAAAAAgCwSSAAAAAAAAAAAAAEAWCCQBAAAAAAAAAAAAgCwQSAIAAAAAAAAAAAAAWSCQBAAAAAAAAAAAAACyQCAJAAAAAAAAAAAAAGSBQBIAAAAAAAAAAAAAyAKBJAAAAAAAAAAAAACQBQJJAAAAAAAAAAAAACALBJIAAAAAAAAAAAAAQBYIJAEAAAAAAAAAAACALBBIAgAAAAAA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IiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiO6cAAAAAgIQdSQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABA5I5TAABws/yDlz7SOwu31y/99sd21gPWA9YDrevhabEjCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiNy5qQ/sG7/hud7Lc3u99fDBznrAesB6oHU9AABwvexIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgMidm/rAXnj+Ra/OLfbWwwfWA9YD1gPN6wEAgOtlRxIAAAAAkRu7I+ne/Te8OlgPWA9YDwAAcIPYkQQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAACROzf1gb3w/ItenVvsrYcPrAesB6wHmtcDAADXy44kAAAAACI3dkfSvftveHWwHrAesB4AAOAGsSMJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIndu6gN74fkXvTq32FsPH1gPWA9YDzSvBwAArpcdSQAAAABEbuyOpHv33/DqYD1gPWA9AADADWJHEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAETu3NQH9sLzL3p1brG3Hj6wHrAesB5oXg8AAFwvO5IAAAAAiNzYHUn37r/h1cF6wHrAegAAgBvEjiQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACI3LmpD+yF51/06txibz18YD1gPWA90LweAAC4XnYkAQAAABC5sTuS7t1/w6uD9YD1gPUAAAA3iB1JAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAELlzUx/YC8+/6NW5xd56+MB6wHrAeqB5PQAAcL3sSAIAAAAgcmN3JN27/4ZXB+sB6wHrgVvp737bP3QSbrFf+u2PWQ9YD1gPNK+Hp8WOJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIjcuakP7IXnX/Tq3GJvPXxgPWA9YD3QvB6+WvyP3/hFLy7WA9YD1gM3kh1JAAAAAER2TgEAAAAACTuSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJCEgAAAAARIQkAAACAiJAEAAAAQERIAgAAACAiJAEAAAAQEZIAAAAAiAhJAAAAAESEJAAAAAAiQhIAAAAAESEJAAAAgIiQBAAAAEBESAIAAAAgIiQBAAAAEBGSAAAAAIgISQAAAABEhCQAAAAAIkISAAAAABEhCQAAAICIkAQAAABAREgCAAAAICIkAQAAABARkgAAAACICEkAAAAARIQkAAAAACJ/Ce1QZS71HGJJAAAAAElFTkSuQmCC",pants="iVBORw0KGgoAAAANSUhEUgAABJIAAAReCAYAAACMxxrQAAEHPElEQVR42uy9S7Ms3XaelUtWSOfynXPC52Y1QJb3FkFY2rKOZCGZoAuS7xc1aBCELxI2xpKxjS3bkrnYf4AGEfwHfoE7BF0a0KVHGBqGNuGwuURgUcS+fLsyK+ec4x2XmVW56nnk433OWrtyZWXOqr3GU2O884cWAAAAAAAAAAAAgR/iEgAAAAAAAAAAgAIiCQAAAAAAAAAAJBBJAAAAAAAAAAAggUgCAAAAAAAAAAAJRBIAAAAAAAAAAEggkgAAAAAAAAAAQAKRBAAAAAAAAAAAEogkAAAAAAAAAACQQCQBAAAAAAAAAIAEIgkAAAAAAAAAACQQSQAAAAAAAAAAIIFIAgAAAAAAAAAACUQSAAAAAAAAAABIIJIAAAAAAAAAAEACkQQAAAAAAAAAABKIJAAAAAAAAAAAkEAkAQAAAAAAAACABCIJAAAAAAAAAAAkEEkAAAAAAAAAACCBSAIAAAAAAAAAAAlEEgAAAAAAAAAASCCSAAAAAAAAAABAApEEAAAAAAAAAAASiCQAAAAAAAAAAJBAJAEAAAAAAAAAgAQiCQAAAAAAAAAAJBBJAAAAAAAAAAAggUgCAAAAAAAAAAAJRBIAAAAAAAAAAEggkgAAAAAAAAAAQAKRBAAAAAAAAAAAEogkAAAAAAAAAACQQCQBAAAAAAAAAIAEIgkAAAAAAAAAACQQSQAAAAAAAAAAIIFIAgAAAAAAAAAACUQSAAAAAAAAAABIIJIAAAAAAAAAAEACkQQAAAAAAAAAABKIJAAAAAAAAAAAkEAkAQAAAAAAAACABCIJAAAAAAAAAAAkEEkAAAAAAAAAACCBSAIAAAAAAAAAAAlEEgAAAAAAAAAASCCSAAAAAAAAAABAApEEAAAAAAAAAAASiCQAAAAAAAAAAJBAJAEAAAAAAAAAgAQiCQAAAAAAAAAAJBBJAAAAAAAAAAAggUgCAAAAAAAAAAAJRBIAAAAAAAAAAEggkgAAAAAAAAAAQAKRBAAAAAAAAAAAEogkAAAAAAAAAACQQCQBAAAAAAAAAIAEIgkAAAAAAAAAACQQSQAAAAAAAAAAIIFIAgAAAAAAAAAACUQSAAAAAAAAAABIIJIAAAAAAAAAAEACkQQAAAAAAAAAABKIJAAAAAAAAAAAkEAkAQAAAAAAAACABCIJAAAAAAAAAAAkEEkAAAAAAAAAACCBSAIAAAAAAAAAAAlEEgAAAAAAAAAASCCSAAAAAAAAAABAApEEAAAAAAAAAAASiCQAAAAAAAAAAJBAJAEAAAAAAAAAgAQiCQAAAAAAAAAAJBBJAAAAAAAAAAAggUgCAAAAAAAAAAAJRBIAAAAAAAAAAEggkgAAAAAAAAAAQAKRBAAAAAAAAAAAEogkAAAAAAAAAACQQCQBAAAAAAAAAIAEIgkAAAAAAAAAACQQSQAAAAAAAAAAIIFIAgAAAAAAAAAACUQSAAAAAAAAAABIIJIAAAAAAAAAAEACkQQAAAAAAAAAABKIJAAAAAAAAAAAkEAkAQAAAAAAAACABCIJAAAAAAAAAAAkEEkAAAAAAAAAACCBSAIAAAAAAAAAAAlEEgAAAAAAAAAASCCSAAAAAAAAAABAApEEAAAAAAAAAAASiCQAAAAAAAAAAJBAJAEAAAAAAAAAgAQiCQAAAAAAAAAAJBBJAAAAAAAAAAAggUgCAAAAAAAAAAAJRBIAAAAAAAAAAEggkgAAAAAAAAAAQAKRBAAAAAAAAAAAEogkAAAAAAAAAACQQCQBAAAAAAAAAIAEIgkAAAAAAAAAACQQSQAAAAAAAAAAIIFIAgAAAAAAAAAACUQSAAAAAAAAAABIIJIAAAAAAAAAAEACkQQAAAAAAAAAABKIJAAAAAAAAAAAkEAkAQAAAAAAAACABCIJAAAAAAAAAAAkEEkAAAAAAAAAACCBSAIAAAAAAAAAAAlEEgAAAAAAAAAASCCSAAAAAAAAAABAApEEAAAAAAAAAAASiCQAAAAAAAAAAJBAJAEAAAAAAAAAgAQiCQAAAAAAAAAAJBBJAAAAAAAAAAAggUgCAAAAAAAAAAAJRBIAAAAAAAAAAEggkgAAAAAAAAAAQAKRBAAAAAAAAAAAEogkAAAAAAAAAACQQCQBAAAAAAAAAIAEIgkAAAAAAAAAACQQSQAAAAAAAAAAIIFIAgAAAAAAAAAACUQSAAAAAAAAAABIIJIAAAAAAAAAAEACkQQAAAAAAAAAABKIJAAAAAAAAAAAkEAkAQAAAAAAAACABCIJAAAAAAAAAAAkEEkAAAAAAAAAACCBSAIAAAAAAAAAAAlEEgAAAAAAAAAASCCSAAAAAAAAAABAApEEAAAAAAAAAAASiCQAAAAA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AACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCqNpwAAAACAGlYkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQAAABAFYMkAAAAAKoYJAEAAABQxSAJAAAAgCoGSQAAAABUMUgCAAAAoIpBEgAAAABVDJIAAAAAqGKQBAAAAEAVgyQAAAAAqhgkAQAAAFDFIAkAAACAKgZJAAAAAFQxSAIAAACgikESAAAAAFUMkgAAAACoYpAEAAAAQBWDJAAAAACqGCQBAAAAUMUgCQAAAIAqBkkAAAAAVDFIAgAAAKCKQRIAAAAAVQySAAAAAKhikAQA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5gTlbgfK7LrFuPOi93WURVi4muvSezeo7c6L5f9PTl5mnRflaOfF6hXqunFi4YzOi/s7UIZdcME8zBde1oEyf+fHe+ehd+JgWjyZW5/ErY+bhxrOQ33yebAf7Af74W33w8N+TnnWH6D+9MtfX71Hkw2//flX1TxgHjAPHJ2HV2GuzbV5wDxgHnjWn4P+zl89AAAAAAlBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAACRn571C/vPf/svjw7mAfOAecBcYx7MA+YB88ATcSIJAAAAgIggCQAAAICIIAkAAACAiCAJAAAAgIggCQAAAICIIAkAAACAiCAJAAAAgIggCQAAAICIIAkAAACASH3WL+xPv/x18vC8r9/+/KtqHjAPmAeOzsOrMNfm2jxgHjAPPOvPQU4kAQAAABARJAEAAAAQESQBAAAAEKn+CgAAAABIOJEEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEDkp2f9wn7z699NHp739ee//LGaB8wD5oGj8/AqzLW5Ng+YB8wDz/pzkBNJAAAAAESe9kTSv/7THzw6b+w//vufzQPmAfPA4Xl4FebaXJsHzAPmgWf9OciJJAAAAAAigiQAAAAAIoIkAAAAACKCJAAAAAAigiQAAAAAIoIkAAAAACKCJAAAAAAi9Vm/sN/8+neTh+d9/fkvf6zmAfOAeeDoPLwKc22uzQPmAfPAs/4c5EQSAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAkZ+e9Qv7/T/+u0fnjf3hf/7FPGAeMA8cnodXYa7NtXnAPGAeeNafg5xIAgAAACAiSAIAAAAgIkgCAAAAICJIAgAAACAiSAIAAAAgIkgCAAAAICJIAgAAACAiSAIAAAAgIkgCAAAAICJIAgAAACAiSAIAAAAgIkgCAAAAICJIAgAAACAiSAIAAAAgIkgCAAAAICJIAgAAACAiSAIAAAAgIkgCAAAAICJIAgAAACAiSAIAAAAgIkgCAAAAIFKf9Qv731/+b/LwvK9/+Pnvq3nAPGAeODoPr8Jcm2vzgHnAPPCsPwc5kQQAAABARJAEAAAAQESQBAAAAEBEkAQAAABARJAEAAAAQESQBAAAAEBEkAQAAABApPorAAAAACDhRBIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAEUESAAAAABFBEgAAAAARQRIAAAAAkf8Hqq70eWn3oFYAAAAASUVORK5CYII="}}

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
        local state={glows={}}
        local bloom=Instance.new("BloomEffect"); bloom.Name="PivotBallBloom"; bloom.Enabled=false; bloom.Parent=lighting; state.bloom=bloom
        scope:defer(function() bloom:Destroy(); for _,glow in pairs(state.glows) do glow:Destroy() end end)
        return state
    end,step=function(scope,state,s)
        local color=cosmetic_color(s.ball_color); local chosen=material(s.ball_material); local parts={}; local seen={}; local glowing=0
        for _,item in ipairs(candidates("balls")) do parts[#parts+1]=item.object end
        local own=held_ball(rig()); if own then parts[#parts+1]=own end
        for _,part in ipairs(parts) do
            if not seen[part] then
                seen[part]=true
                scope:set(part,"Color",color); scope:set(part,"Material",chosen); scope:set(part,"Reflectance",s.ball_reflectance)
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
        state.bloom.Enabled=glowing>0; state.bloom.Intensity=s.ball_bloom; state.bloom.Size=18; state.bloom.Threshold=.9
    end,interval=.1})
    local function court_line_kind(object)
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
                    anchors[#anchors+1]={center=center,forward=toward.Unit,free_distance=marker and toward.Magnitude or nil}
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
        local three=s.court_color_lines and s.court_three_enabled and s.court_rebuild_markings and #groups.three==0
        local free=s.court_color_lines and s.court_free_enabled and s.court_rebuild_markings and #groups.free==0
        local anchors=(three or free) and marking_anchors(state) or {}
        local signature=table.concat({tostring(three),tostring(free),s.court_three_radius,s.court_three_angle,s.court_free_radius,s.court_free_distance,s.court_corner_depth,s.court_line_width},"/")
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
        state.marking_summary="Native markings: "..#groups.three.." three-point / "..#groups.free.." free-throw; "..#(state.marking_parts or {}).." replacement segments"
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
                    if selected or name=="courtfloor" or name=="courtsurface" or name=="playingsurface" or (name=="floor" and in_court) then surfaces[#surfaces+1]=part
                    elseif in_court and court_line_kind(part) then lines[#lines+1]=part end
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
            if part and part:IsA("BasePart") and part.Transparency<.95 and hit.Normal.Y>.8 then break end
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
        for object in pairs(state.appearances) do if not s.court_remove_texture then scope:restore(object,"Parent") end end
        for _,part in ipairs(state.surfaces) do
            if part.Parent then
                scope:set(part,"Color",color); scope:set(part,"Material",chosen); scope:set(part,"Reflectance",s.court_reflectance)
                if s.court_remove_texture then
                    scope:set(part,"MaterialVariant","")
                    if part:IsA("MeshPart") then pcall(function() scope:set(part,"TextureID","") end) end
                else
                    scope:restore(part,"MaterialVariant")
                    if part:IsA("MeshPart") then scope:restore(part,"TextureID") end
                end
                for _,object in ipairs(part:GetDescendants()) do
                    if object:IsA("SurfaceAppearance") then
                        if s.court_remove_texture then state.appearances[object]=true; scope:set(object,"Parent",nil) end
                    elseif object:IsA("Texture") or object:IsA("Decal") then
                        if s.court_remove_texture then scope:set(object,"Transparency",1) else scope:restore(object,"Transparency") end
                    elseif object:IsA("SpecialMesh") then
                        if s.court_remove_texture then scope:set(object,"TextureId","") else scope:restore(object,"TextureId") end
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
    Engine.model_library={version=1,models={}}
    Engine.model_cache={}; Engine.model_preload={busy=false,done=0,total=0,failed=0}
    local library_defaults={}
    for _,key in ipairs({"model_style","model_fit_pb","model_fit_scale","model_accessory_scale","model_height","model_offset","model_rotation","model_follow_pose","model_motion","model_hide_avatar","model_high_detail","model_show_hair","model_show_hats","model_show_masks","model_show_capes","model_show_weapons","model_show_extras","model_render_region"}) do library_defaults[key]=Engine.settings[key] end
    function Engine:validate_model_library(data)
        if type(data)~="table" or data.version~=1 or type(data.models)~="table" then return nil,"Invalid model library" end
        local result={version=1,models={}}; local names={}; local count=0
        for key in pairs(data.models) do if type(key)~="number" or key%1~=0 or key<1 then return nil,"Model list must be an array" end; count=count+1 end
        if count>32 then return nil,"Library supports up to 32 saved models" end
        for i=1,count do
            local item=data.models[i]
            if type(item)~="table" or type(item.name)~="string" or #item.name<1 or #item.name>40 or item.name:find("[%c]") or names[item.name:lower()] then return nil,"Invalid or duplicate model name" end
            if type(item.asset)~="string" or not item.asset:match("^%d+$") or #item.asset>18 or not item.asset:find("[1-9]") then return nil,"Invalid model asset ID" end
            local settings,err=Core.validate_module_settings(item.settings or {},library_defaults,self.ranges)
            if not settings then return nil,err end
            if settings.model_style~="Basketball" and settings.model_style~="Original costume" then return nil,"Invalid costume style" end
            if settings.model_render_region~="Focused" and settings.model_render_region~="Full screen" then return nil,"Invalid rendering region" end
            local preset="Custom"; if type(item.preset)=="string" and model_presets[item.preset]==item.asset then preset=item.preset end
            names[item.name:lower()]=true; result.models[i]={name=item.name,asset=item.asset,preset=preset,settings=settings}
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
        local item={name=name,preset=self.settings.model_preset,asset=model_presets[self.settings.model_preset] or tostring(self.settings.model_asset):match("^%s*(%d+)%s*$"),settings={}}
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
        local keep={}; for _,item in ipairs(self.model_library.models) do keep[item.asset]=true end
        for asset,objects in pairs(self.model_cache) do if not keep[asset] then for _,object in ipairs(objects) do object:Destroy() end; self.model_cache[asset]=nil end end
    end
    function Engine:preload_model_library()
        assert(not self.model_preload.busy,"Models are already preloading")
        local valid,err=self:validate_model_library(self.model_library); assert(valid,err)
        local progress={busy=true,done=0,total=#valid.models,failed=0}; self.model_preload=progress
        task.spawn(function()
            for _,item in ipairs(valid.models) do
                if self.library_closed then break end
                if not self.model_cache[item.asset] then
                    local objects
                    local ok=pcall(function()
                        objects=game:GetObjects("rbxassetid://"..item.asset); local parts=0
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
                        self.model_cache[item.asset]=objects
                        local provider=game:GetService("ContentProvider"); if provider then
                            local failures=0; provider:PreloadAsync(objects,function(_,status) if status~=Enum.AssetFetchStatus.Success then failures=failures+1 end end)
                            assert(failures==0,"Some textures could not preload")
                        end
                    end)
                    if not ok then progress.failed=progress.failed+1; self.model_cache[item.asset]=nil; if objects then for _,object in ipairs(objects) do object:Destroy() end end end
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
                local copy=copy_part(not basketball and exact and look or real,basketball); copy.Name=real.Name; copy.CFrame=real.CFrame; copy.Size=real.Size*s.model_fit_scale
                if basketball and (not authored or uniform) or not basketball and not exact and look then
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
        -- A fresh, state-disabled helper renders clothes without controlling the visual shell.
        local humanoid=Instance.new("Humanoid"); humanoid.Name="PivotAppearanceHumanoid"; humanoid.AutoRotate=false; humanoid.PlatformStand=true; humanoid.RequiresNeck=false; humanoid.BreakJointsOnDeath=false; humanoid.DisplayDistanceType=Enum.HumanoidDisplayDistanceType.None
        pcall(function() humanoid.EvaluateStateMachine=false; humanoid.AutomaticScalingEnabled=false end)
        pcall(function() humanoid.RigType=source:FindFirstChild("UpperTorso") and Enum.HumanoidRigType.R15 or Enum.HumanoidRigType.R6 end)
        humanoid.Parent=model
        return {model=model,parts=parts,bindings=bindings,extras=extras,nested=nested,fit_scale=s.model_fit_scale,matched=matched,basketball=basketball,uniform_ready=uniform~=nil,texture_error=texture_error}
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

    function Engine:rendering_report()
        local active=registry.active.custom_model; local state=active and active.state
        local camera=workspace.CurrentCamera; local size=camera and camera.ViewportSize
        return {preset=self.settings.model_preset,enabled=active~=nil,mode=self.settings.model_render_region,screen=size and {width=size.X,height=size.Y},region=state and state.render_region,parts=state and #state.parts,textures_ready=state and state.textures_ready,rig=state and state.rig_label}
    end
    function Engine:sync_costume_camera(state,s)
        local source=workspace.CurrentCamera; if not source then return end
        local size=source.ViewportSize; local bounds
        if s.model_render_region=="Focused" and source.WorldToViewportPoint then
            local left,top,right,bottom=math.huge,math.huge,-math.huge,-math.huge; local count=0; local near=false
            local boxes={}
            if state.model and state.model.GetBoundingBox then
                local frame,extent=state.model:GetBoundingBox(); boxes[1]={frame=frame,size=extent}
            else
                for _,part in ipairs(state.parts) do if part.Parent and part.Transparency<.95 then boxes[#boxes+1]={frame=part.CFrame,size=part.Size} end end
            end
            for _,box in ipairs(boxes) do
                for _,x in ipairs({-1,1}) do for _,y in ipairs({-1,1}) do for _,z in ipairs({-1,1}) do
                    local p=box.frame*CFrame.new(box.size.X*x/2,box.size.Y*y/2,box.size.Z*z/2)
                    local point=source:WorldToViewportPoint(p.Position)
                    if point.Z<=.2 then near=true else left=math.min(left,point.X); top=math.min(top,point.Y); right=math.max(right,point.X); bottom=math.max(bottom,point.Y); count=count+1 end
                end end end
            end
            if count>0 and not near then bounds={left,top,right,bottom} end
        end
        local region=Core.costume_region(size.X,size.Y,source.FieldOfView,bounds); if not region then return end
        state.viewport.Position=UDim2.fromOffset(region.x,region.y); state.viewport.Size=UDim2.fromOffset(region.width,region.height)
        state.camera.FieldOfViewMode=Enum.FieldOfViewMode.Vertical; state.camera.CFrame=source.CFrame; state.camera.FieldOfView=region.fov; state.render_region=region
    end

    add("custom_model","Character skin","Character","Basketball style preserves PB body meshes; Sasuke includes a custom Uchiha uniform. Original costume keeps the donor appearance",{start=function(scope,s)
        -- World-parented costume Humanoids have caused live-game flings. Never parent this rig to Workspace.
        s.model_renderer="Viewport"
        assert(model_presets[s.model_preset] or s.model_preset=="Custom","Unknown character preset")
        local asset=model_presets[s.model_preset] or s.model_asset
        asset=tostring(asset):match("^%s*(%d+)%s*$"); assert(asset and #asset<=18,"Enter a numeric Roblox model asset ID")
        local objects=Engine:model_objects(asset); assert(type(objects)=="table" and #objects>0,"Model asset could not be loaded")
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
        local appearance_owners={}
        for _,object in ipairs(model:GetDescendants()) do
            if (object:IsA("Shirt") or object:IsA("Pants") or object:IsA("ShirtGraphic") or object:IsA("BodyColors")) and object.Parent and object.Parent:IsA("Model") then appearance_owners[object.Parent]=true end
        end
        for owner in pairs(appearance_owners) do
            local humanoid=Instance.new("Humanoid"); humanoid.Name="PivotAppearanceHumanoid"
            humanoid.AutoRotate=false; humanoid.PlatformStand=true; humanoid.BreakJointsOnDeath=false; humanoid.RequiresNeck=false; humanoid.DisplayDistanceType=Enum.HumanoidDisplayDistanceType.None
            pcall(function() humanoid.EvaluateStateMachine=false end); pcall(function() humanoid.AutomaticScalingEnabled=false end)
            pcall(function() humanoid.RigType=owner:FindFirstChild("UpperTorso") and Enum.HumanoidRigType.R15 or Enum.HumanoidRigType.R6 end)
            humanoid.Parent=owner
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
        local viewport,world,camera
            viewport=new_local(scope,"ViewportFrame",ctx.gui); viewport.Name="PivotModelViewport"; viewport.Size=UDim2.fromScale(1,1); viewport.BackgroundTransparency=1; viewport.BorderSizePixel=0; viewport.ZIndex=0; viewport.Active=false
            viewport.BackgroundColor3=Color3.fromRGB(255,255,255); viewport.Ambient=Color3.fromRGB(110,110,110); viewport.LightColor=Color3.fromRGB(255,255,255); viewport.LightDirection=Vector3.new(-1,-1,-1)
            world=Instance.new("WorldModel"); world.Name="PivotModelWorld"; world.Parent=viewport
            camera=Instance.new("Camera"); camera.Parent=viewport; viewport.CurrentCamera=camera
        model.Parent=world
        local state
        local binding="PivotCostumeCamera"
        run:BindToRenderStep(binding,Enum.RenderPriority.Last.Value+2,function()
            local current_camera=workspace.CurrentCamera
            if state and current_camera then Engine:sync_costume_camera(state,s) end
            if state and rig() then if state.pb_costume then Engine:pose_pb_costume(state,rig(),s) elseif s.model_follow_pose then Engine:pose_character(state,rig()) end end
        end)
        scope:defer(function() run:UnbindFromRenderStep(binding) end)
        local current=assert(root(),"Enter a court first"); model:PivotTo(current.CFrame)
        local rig_type=motors>0 and (model:FindFirstChild("UpperTorso",true) and "R15 joint rig" or model:FindFirstChild("Torso",true) and "R6 joint rig" or "Joint rig") or #bones>0 and "Bone rig" or "Static / welded model"
        state={model=model,parts=parts,source=rig(),height=s.model_height,viewport=viewport,camera=camera,last_position=current.Position,phase=0,speed=0,joints=joints,bones=bones,motor_count=motors,rig_scale=rig_scale,pb_costume=pb_costume,fit_scale=s.model_fit_scale,rig_label=pb_costume and (pb_costume.basketball and (pb_costume.texture_error and "PB basketball · custom textures unavailable" or pb_costume.uniform_ready and "PB basketball · authored textures registered" or "PB basketball · live body geometry") or "PB costume · live body proportions and poses") or s.model_fit_pb and motors==0 and #bones==0 and "Single-piece fitted costume · limited limb animation" or rig_type.." · "..motors.." animated joints / "..#bones.." bones"}
        -- Faceless costumes: remove face art in every style, retaining hair and glasses.
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
        state.accessories={}
        for _,part in ipairs(parts) do
            local group=part:GetAttribute("PivotAccessoryGroup") or accessory_group(part)
            if group then state.accessories[#state.accessories+1]={part=part,group=group,transparency=part.Transparency} end
        end
        state.mesh_fidelity={}
        for _,part in ipairs(parts) do if part:IsA("MeshPart") then state.mesh_fidelity[part]=part.RenderFidelity; if s.model_high_detail then pcall(function() part.RenderFidelity=Enum.RenderFidelity.Precise end) end end end
        local provider=game:GetService("ContentProvider")
        if provider then
            local active=true; scope:defer(function() active=false end)
            task.spawn(function()
                local failed=0
                local ok=pcall(function() provider:PreloadAsync({model},function(_,status) if status~=Enum.AssetFetchStatus.Success then failed=failed+1 end end) end)
                if active then state.textures_ready=ok and failed==0; if not state.textures_ready then ctx.report("Some costume textures could not be preloaded") end end
            end)
        end
        return state
    end,step=function(scope,state,s,dt)
        local source=rig(); local part=root(); assert(source and part,"Character unavailable")
        Engine:sync_costume_camera(state,s)
        if state.viewport then state.viewport.Visible=true end
        for part,original in pairs(state.mesh_fidelity) do pcall(function() part.RenderFidelity=s.model_high_detail and Enum.RenderFidelity.Precise or original end) end
        for _,entry in ipairs(state.accessories) do entry.part.Transparency=s["model_show_"..entry.group] and entry.transparency or 1 end
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
                if s.model_hide_avatar then scope:set(original,"LocalTransparencyModifier",1) else scope:restore(original,"LocalTransparencyModifier") end
            elseif original:IsA("Decal") or original:IsA("Texture") then
                if s.model_hide_avatar then scope:set(original,"Transparency",1) else scope:restore(original,"Transparency") end
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
        custom_model={{"model_style","Costume style",{"Basketball","Original costume"}},{"model_render_region","Render region",{"Focused","Full screen"}}}
    }
    Engine.cosmetic_toggles={ball_appearance={{"ball_remove_texture","Remove ball texture"},{"ball_glow","Neon glow"}},court_appearance={{"court_color_lines","Customize court markings"},{"court_remove_texture","Remove floor textures"},{"court_three_enabled","Custom three-point color"},{"court_free_enabled","Custom free-throw color"},{"court_rebuild_markings","Rebuild baked markings"}},self_outline={{"outline_through_walls","Show through walls"}},custom_model={{"model_show_hair","Show hair"},{"model_show_hats","Show hats / headbands"},{"model_show_masks","Show masks / glasses"},{"model_show_capes","Show capes / coats"},{"model_show_weapons","Show weapons"},{"model_show_extras","Show other accessories"},{"model_high_detail","High mesh detail"},{"model_fit_pb","Fit costume to PB body"},{"model_motion","Single-piece motion"},{"model_hide_avatar","Hide your normal avatar"},{"model_follow_pose","Follow player pose"}}}

    Engine.shot_stats={total=0,perfect=0,good=0,early=0,late=0,skipped=0,releases=0,unconfirmed=0,last="Waiting for a shot",history={}}
    function Engine:record_shot(event)
        local stats=self.shot_stats; local kind=event.kind
        if kind=="feedback" then
            stats.total=stats.total+1
            if event.code==5 then stats.perfect=stats.perfect+1; stats.last="Perfect · timing retained"
            elseif event.code==4 then stats.good=stats.good+1; stats.last=event.locked and "Good · keeping established timing" or self.settings.refine_good and "Good · refining nearby timing" or "Good"
            elseif event.code<=3 then stats.early=stats.early+1; stats.last="Early · next release later"
            else stats.late=stats.late+1; stats.last="Late · next release earlier" end
            if not self.settings.auto_calibrate and event.code~=5 then stats.last=(event.code<=3 and "Early" or event.code>=6 and "Late" or "Good").." · auto correct off" end
        elseif kind=="skip" then stats.skipped=stats.skipped+1; stats.last=event.reason
        elseif kind=="release" then stats.releases=stats.releases+1; stats.last="Released · awaiting game feedback"
        elseif kind=="unconfirmed" then stats.unconfirmed=stats.unconfirmed+1; stats.last="No feedback received for an auto release" end
        local entry={kind=kind,code=event.code,shot=event.shot,name=event.name,reason=event.reason,ratio=event.ratio,position=event.position,speed=event.speed,details=event.details,time=os.clock()}
        stats.history[#stats.history+1]=entry; if #stats.history>100 then table.remove(stats.history,1) end
    end
    function Engine:attach_shot_hud(scope)
        local label=Instance.new("TextLabel"); label.Name="PivotShotStats"; label.AnchorPoint=Vector2.new(1,0); label.Position=UDim2.new(1,-20,0,20); label.Size=UDim2.fromOffset(290,84)
        label.BackgroundColor3=Color3.fromRGB(24,26,30); label.BackgroundTransparency=.15; label.BorderSizePixel=0; label.TextColor3=Color3.fromRGB(230,232,237); label.Font=Enum.Font.SourceSans; label.TextSize=18; label.TextWrapped=true; label.Parent=ctx.gui
        local corner=Instance.new("UICorner"); corner.CornerRadius=UDim.new(0,6); corner.Parent=label
        scope:defer(function() label:Destroy() end)
        local function update()
            local stats=self.shot_stats; local rate=stats.total>0 and string.format("%.1f%%",stats.perfect/stats.total*100) or "--"
            label.Visible=self.settings.shot_hud
            label.Text="Perfect rate: "..rate.."  ("..stats.perfect.."/"..stats.total..")\n"..stats.last.."\nSkipped: "..stats.skipped.." · Unconfirmed: "..stats.unconfirmed
        end
        update(); local connection=run.Heartbeat:Connect(update); scope:defer(function() connection:Disconnect() end)
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
            TextColor3=color or theme.text,Font=Enum.Font.SourceSans,TextSize=math.max(14,(size or 12)+2),TextXAlignment=Enum.TextXAlignment.Left,
            TextYAlignment=Enum.TextYAlignment.Center,TextWrapped=true,BorderSizePixel=0},parent)
    end
    local function small_button(parent,value,callback)
        local b=make("TextButton",{Text=value,Size=UDim2.fromOffset(110,28),BackgroundColor3=theme.panel,BorderSizePixel=0,
            TextColor3=theme.text,TextSize=14,Font=Enum.Font.SourceSans,AutoButtonColor=false},parent)
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
    local logo=label(shell,"Pivot",20,12,100,28,19,theme.text); logo.Font=Enum.Font.SourceSansBold; logo.TextXAlignment=Enum.TextXAlignment.Left
    local heading=label(shell,"Practical Basketball",94,14,240,26,11,theme.muted); heading.Font=Enum.Font.SourceSansSemibold
    close.BackgroundColor3=theme.rail; close.TextColor3=theme.muted; close.TextSize=14; corner(close,4)
    local search=make("TextBox",{Text="",PlaceholderText="Find a control...",PlaceholderColor3=theme.muted,Position=UDim2.fromOffset(484,10),Size=UDim2.fromOffset(166,23),
        ClearTextOnFocus=false,TextSize=14,TextColor3=theme.text,BackgroundColor3=theme.input,BorderSizePixel=0,Font=Enum.Font.SourceSans},shell)
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
                        child.Parent=row; child.Text=d[1]; child.TextSize=14; child.Font=Enum.Font.SourceSans; child.TextColor3=theme.text; child.Position=UDim2.fromOffset(12,6); child.Size=UDim2.new(1,-128,0,20)
                        local helper=label(row,d[2],12,27,220,16,10,theme.muted); helper.Size=UDim2.new(1,-128,0,16)
                        box.Parent=row; box.TextSize=14; box.BackgroundColor3=theme.input; box.TextColor3=theme.text; box.Font=Enum.Font.RobotoMono; corner(box,3)
                        box.Position=multi and UDim2.fromOffset(12,51) or UDim2.new(1,-104,0,12); box.Size=multi and UDim2.new(1,-24,0,44) or UDim2.fromOffset(92,28); box.MultiLine=multi
                        local outline=border(box)
                        if multi then child.Size=UDim2.new(1,-24,0,20); helper.Size=UDim2.new(1,-24,0,16) end
                        on(box.Focused,function() outline.Color=theme.accent end); on(box.FocusLost,function() outline.Color=theme.line end)
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
    local account=frame(home,0,0,0,84); account.Size=UDim2.new(1,-6,0,84); corner(account,7)
    local name=player.DisplayName or player.Name
    local kicker=label(account,"Account",16,10,420,16,10,theme.muted)
    local display_name=label(account,name,16,28,450,25,18); display_name.Font=Enum.Font.SourceSansBold
    local greeting=label(account,"@"..player.Name,16,55,430,17,11,theme.muted)
    local badge=frame(account,0,0,1,1); badge.Visible=false
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
    status.TextSize=14; status.TextColor3=theme.muted
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
        local w=math.max(340,math.min(760,v.X-24)); local h=math.max(430,math.min(580,v.Y-32))
        scale.Scale=math.min(1,(v.X-12)/w,(v.Y-12)/h); shell.Size=UDim2.fromOffset(w,h)
        rail_line.Size=UDim2.new(1,-40,0,1); top_line.Size=UDim2.new(1,-40,0,1)
        layout_nav()
        local narrow=w<560
        search.Visible=not narrow; search.Position=UDim2.new(1,-244,0,10)
        search_symbol.Visible=not narrow; search_symbol.Position=UDim2.new(1,-241,0,12)
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
        display_name.Size=UDim2.new(1,-30,0,25); display_name.TextSize=20; greeting.Size=UDim2.new(1,-30,0,17)
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
    local function set_theme(mode)
        local palettes={
            Graphite={base=rgb(20,21,24),rail=rgb(20,21,24),panel=rgb(28,30,34),input=rgb(24,26,30),line=rgb(43,46,52),text=rgb(230,232,237),muted=rgb(145,151,163),accent=rgb(192,201,220),selected=rgb(39,44,54),green=rgb(159,190,170)},
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
    PivotUI={theme=theme,label=label,button=small_button,pages=pages,rail_items=rail_items,show=show,heading=heading,search=search,cancel=cancel,actions=actions,icon=icon,icon_color=icon_color,animate=animate,add_search=add_search,layout_nav=layout_nav,set_theme=set_theme,edit_theme=edit_theme}
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
        if row and row.Name:sub(1,10)=="ModuleRow_" then row.BackgroundColor3=on and theme.selected or theme.panel; row.BackgroundTransparency=on and .4 or 1 end
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
    local tabs={"All","Shooting","Dribbling","Cosmetics","Character","Player","Defense","Visuals","World","Camera","Recorder","Options"}
    local category="All"; local rows={}; local fields={}; local y=0
    local container=page
    local collapsed={}
    local expanded,choosing,section_button,record_tools,court_alignment
    local character_open=false; local library_open=false
    local auxiliary={}; local capture_switch; local character_status; local library_status
    local function clear()
        for _,object in ipairs(rows) do object:Destroy() end; rows={}; fields={}; auxiliary={}; character_status=nil; library_status=nil; y=46
    end
    local function own(object) rows[#rows+1]=object; return object end
    local function text(value,size,color,height)
        local object=own(ui.label(container,value,2,y,500,height or 22,size or 12,color or theme.text)); object.Size=UDim2.new(1,-12,0,height or 22); y=y+(height or 22)+5; return object
    end
    local function action(value,callback)
        local object=own(ui.button(container,value,function() local ok,err=pcall(callback); if not ok then report(tostring(err)) end end))
        object.Position=UDim2.fromOffset(0,y); object.Size=UDim2.new(1,-6,0,30); y=y+36; return object
    end
    local rebuild,color_expanded
    local function field(key,caption)
        local color_sync
        local row=own(make("Frame",{Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,36),BackgroundColor3=theme.panel,BorderSizePixel=0},container))
        local label=ui.label(row,caption,10,8,220,20,11,theme.muted); label.Size=UDim2.new(.6,-14,0,20)
        local box=make("TextBox",{Name="Module_"..key,Text=tostring(engine.settings[key]),ClearTextOnFocus=false,Font=Enum.Font.RobotoMono,TextSize=14,TextColor3=theme.text,BackgroundColor3=theme.input,BorderSizePixel=0,Position=UDim2.new(.6,0,0,4),Size=UDim2.new(.4,-6,0,28)},row)
        fields[key]=box; y=y+42
        local range=engine.ranges[key]
        if range then
            row.Size=UDim2.new(1,-6,0,50); y=y+14
            local slider=make("TextButton",{Name="Slider_"..key,Text="",AutoButtonColor=false,Position=UDim2.fromOffset(10,37),Size=UDim2.new(1,-20,0,6),BackgroundColor3=theme.line,BorderSizePixel=0},row)
            make("UICorner",{CornerRadius=UDim.new(0,3)},slider)
            local fill=make("Frame",{BackgroundColor3=theme.accent,BorderSizePixel=0,Size=UDim2.new((engine.settings[key]-range[1])/(range[2]-range[1]),0,1,0)},slider)
            make("UICorner",{CornerRadius=UDim.new(0,3)},fill)
            local dragging
            local function update(position)
                local width=slider.AbsoluteSize.X; if width<=0 then return end
                local fraction=math.max(0,math.min(1,(position.X-slider.AbsolutePosition.X)/width))
                local value=range[1]+fraction*(range[2]-range[1])
                value=range[2]<=5 and math.floor(value*100+.5)/100 or math.floor(value+.5)
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
        for id,button in pairs(buttons) do
            if button.Parent then paint_switch(button,engine.registry.active[id]~=nil) end
        end
        for _,entry in ipairs(auxiliary) do if entry.button.Parent then paint_switch(entry.button,entry.read()) end end
        if capture_switch then paint_switch(capture_switch,capture) end
        if character_status and character_status.Parent then local active=engine.registry.active.custom_model; character_status.Text="Selected: "..engine.settings.model_preset.." · "..(active and active.state.rig_label or "Enable Character skin to load") end
        if library_status and library_status.Parent then
            local progress=engine.model_preload; local cached=0; for _ in pairs(engine.model_cache) do cached=cached+1 end
            library_status.Text=progress.busy and ("Preloading "..progress.done.." / "..progress.total) or (cached.." cached · "..progress.failed.." preload failures")
        end
    end
    local function toggle_action(caption,read,write)
        local row=own(make("Frame",{Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,32),BackgroundTransparency=1},container))
        local title=ui.label(row,caption,4,0,300,30,11,theme.text); title.Size=UDim2.new(1,-60,0,30)
        local button=switch(row,function() local ok,err=pcall(write,not read()); if not ok then report(tostring(err)) end; update_buttons() end)
        button.Position=UDim2.new(1,-48,0,3); auxiliary[#auxiliary+1]={button=button,read=read}; y=y+36
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
        clear(); buttons={}
        if section_button then section_button.Text=(category=="All" and "All modules" or category).."  ▾" end
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
            local box=own(make("TextBox",{Name="RecordingImport",Text="",PlaceholderText="Paste recording JSON",ClearTextOnFocus=false,MultiLine=true,Font=Enum.Font.RobotoMono,TextSize=14,TextColor3=theme.text,BackgroundColor3=theme.input,BorderSizePixel=0,Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,76)},container)); y=y+82
            action("Import pasted recording",function() assert(#box.Text<=32768,"JSON exceeds 32 KB"); local value,err=Core.validate_recording(http:JSONDecode(box.Text)); assert(value,err); stop_capture(); engine.recording=value; report("Imported "..#value.steps.." steps") end)
            action("Save recording to disk",function() assert(type(writefile)=="function","Disk write unavailable"); local value,err=Core.validate_recording(engine.recording); assert(value,err); writefile("pivot_recording.json",http:JSONEncode(value)); report("Saved pivot_recording.json") end)
            action("Load recording from disk",function() assert(type(readfile)=="function","Disk read unavailable"); local raw=readfile("pivot_recording.json"); assert(#raw<=32768,"Recording exceeds size limit"); local value,err=Core.validate_recording(http:JSONDecode(raw)); assert(value,err); stop_capture(); engine.recording=value; report("Loaded recording") end)
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
            local columns=category=="All" and window.Size.X.Offset>=620 and 2 or 1
            local heights={46,46}
            for _,group in ipairs(groups) do
                local column=columns==2 and (heights[1]<=heights[2] and 1 or 2) or 1
                local card=own(make("Frame",{Name="Group_"..group,Position=UDim2.new((column-1)/columns,(column-1)*4,0,heights[column]),Size=UDim2.new(1/columns,columns==2 and -10 or -6,0,40),BackgroundColor3=theme.panel,BorderSizePixel=0},page))
                make("UICorner",{CornerRadius=UDim.new(0,6)},card)
                make("UIStroke",{Color=theme.line,Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},card)
                local header=ui.button(card,group..(collapsed[group] and "  +" or "  −"),function() collapsed[group]=not collapsed[group]; rebuild() end)
                header.Size=UDim2.new(1,-20,0,32); header.Position=UDim2.fromOffset(10,0); header.BackgroundTransparency=1; header.TextXAlignment=Enum.TextXAlignment.Left
                local divider=make("Frame",{Position=UDim2.fromOffset(0,32),Size=UDim2.new(1,0,0,1),BackgroundColor3=theme.line,BorderSizePixel=0},card)
                divider.Visible=not collapsed[group]
                container=card; y=38
                if not collapsed[group] and group=="Character" then
                    choice("model_catalog","Presets",{"Curated","All"})
                    local choices=engine:character_choices()
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
            for _,definition in ipairs(engine.definitions) do
                if definition.category==group then
                    local id=definition.id
                    local row=own(make("Frame",{Name="ModuleRow_"..id,Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,0,0,30),BackgroundColor3=theme.panel,BackgroundTransparency=1,BorderSizePixel=0},container))
                    make("UICorner",{CornerRadius=UDim.new(0,5)},row)
                    local title=ui.label(row,definition.title,12,0,300,30,12,theme.text); title.Size=UDim2.new(1,-89,0,30)

                    local detail=ui.button(row,expanded==id and "−" or "+",function() if expanded==id then expanded=nil else expanded=id end; rebuild() end)
                    detail.Name="Details"; detail.Position=UDim2.new(1,-76,0,3); detail.Size=UDim2.fromOffset(24,24); detail.BackgroundTransparency=1
                    buttons[id]=switch(row,function()
                        if engine.registry.active[id] then engine.registry:disable(id) else local ok,err=engine.registry:enable(id,engine.settings); if not ok then report(tostring(err)) end end
                        update_buttons()
                    end)
                    buttons[id].Position=UDim2.new(1,-48,0,2)
                    connect(row.MouseEnter,function() row.BackgroundColor3=theme.panel; row.BackgroundTransparency=.25 end)
                    connect(row.MouseLeave,function() row.BackgroundColor3=engine.registry.active[id] and theme.selected or theme.panel; row.BackgroundTransparency=engine.registry.active[id] and .4 or 1 end)
                    y=y+32
                    if expanded==id then
                        text(definition.description,12,theme.muted,60).TextWrapped=true
                        for _,entry in ipairs(options[id] or {}) do field(entry[1],entry[2]) end
                        for _,entry in ipairs((engine.cosmetic_choices or {})[id] or {}) do choice(entry[1],entry[2],entry[3]) end
                        for _,entry in ipairs((engine.cosmetic_fields or {})[id] or {}) do if (entry[1]~="model_asset" or engine.settings.model_preset=="Custom") and (entry[1]~="model_height" or not engine.settings.model_fit_pb) then field(entry[1],entry[2]) end end
                        for _,entry in ipairs((engine.cosmetic_toggles or {})[id] or {}) do local key=entry[1]; if key~="model_follow_pose" or not engine.settings.model_fit_pb then toggle_action(entry[2],function() return engine.settings[key] end,function(on) engine.settings[key]=on; if key=="model_fit_pb" then local active=engine.registry.active.custom_model; if active then engine.registry:disable("custom_model"); local ok,err=engine.registry:enable("custom_model",engine.settings); if not ok then report(tostring(err)) end end; rebuild() end end) end end
                        if id=="meter_release" then
                            toggle_action("Auto correct",function() return engine.settings.auto_calibrate end,function(on) engine.settings.auto_calibrate=on end)
                            toggle_action("Refine Good results",function() return engine.settings.refine_good end,function(on) engine.settings.refine_good=on end)
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
                            action("Select floor beneath me",function() engine:select_court_under_player() end)
                            action(court_alignment and "Marking alignment  −" or "Marking alignment  +",function() court_alignment=not court_alignment; rebuild() end)
                            if court_alignment then
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
