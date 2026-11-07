local Core={}
function Core.bounded(value,lo,hi)
    value=tonumber(value); if not value or value~=value or math.abs(value)==math.huge or value<lo or value>hi then return nil end; return value
end
function Core.alpha(response,dt) return 1-math.exp(-response*math.max(0,math.min(.1,dt))) end
function Core.teammate(config,local_team,other_team,local_neutral,other_neutral,local_attribute,other_attribute)
    if not config.teamCheck or config.ignoreTeams then return false end
    if local_team~=nil and other_team~=nil then return local_neutral~=true and other_neutral~=true and local_team==other_team end
    return local_attribute~=nil and local_attribute~=0 and local_attribute~="" and local_attribute==other_attribute
end
function Core.lead(config,ping) return math.max(0,math.min(.25,config.predictionEnabled and config.prediction+(config.usePing and math.min(.15,math.max(0,ping or 0)) or 0) or 0)) end
function Core.bounds(points,width,height)
    local x0,y0,x1,y1=math.huge,math.huge,-math.huge,-math.huge
    for _,p in ipairs(points) do
        if not p or p.Z<=.05 or p.X~=p.X or p.Y~=p.Y then return nil end
        x0=math.min(x0,p.X); y0=math.min(y0,p.Y); x1=math.max(x1,p.X); y1=math.max(y1,p.Y)
    end
    x0=math.max(0,x0); y0=math.max(0,y0); x1=math.min(width,x1); y1=math.min(height,y1)
    if x1-x0<2 or y1-y0<2 then return nil end
    return math.floor(x0),math.floor(y0),math.ceil(x1-x0),math.ceil(y1-y0)
end
function Core.pick(candidates,current,radius,bias,visible,sticky)
    table.sort(candidates,function(a,b) return a.screenDistance<b.screenDistance end)
    local prior
    for _,entry in ipairs(candidates) do if entry.player==current and (sticky or entry.screenDistance<=radius*1.15) then prior=entry; break end end
    if prior and not visible(prior) then prior=nil end
    if sticky and prior then return prior end
    local tested=0
    for _,entry in ipairs(candidates) do
        if entry.screenDistance<=radius then
            if prior and entry.screenDistance>=prior.screenDistance*(1-bias) then return prior end
            tested=tested+1
            if visible(entry) then return entry end
            if tested>=8 then break end
        end
    end
    return prior
end
if DEEPHAT_REFINED_TEST then return Core end

-- DeepHat Refined 3.2 | standalone client script, native UI, no Drawing dependency.
local Players=game:GetService("Players")
local Run=game:GetService("RunService")
local Input=game:GetService("UserInputService")
local player=assert(Players.LocalPlayer,"Run this on the Roblox client")
local parent=player:WaitForChild("PlayerGui")
local previous=parent:FindFirstChild("DeepHatRefined")
if previous then local stop=previous:FindFirstChild("Unload"); assert(stop,"Remove the existing DeepHatRefined GUI first"); stop:Fire() end
-- Stop the old supplied script's camera callbacks if it is still active.
Run:UnbindFromRenderStep("DeepHat_Aim"); Run:UnbindFromRenderStep("DeepHat_ESP")
local cfg={enabled=true,espEnabled=true,teamCheck=true,ignoreTeams=false,checkLOS=true,espVisibleOnly=false,
    hardLock=true,stickyTarget=true,centerFov=true,
    aimKey="E",aimMouseButton=false,response=10,fov=200,maxDistance=600,predictionEnabled=true,prediction=0,usePing=false,
    targetParts={"Head","UpperTorso","Torso","HumanoidRootPart"},espColor=Color3.fromRGB(235,111,129),espThickness=1.5,showFov=true,names=true,maxVisuals=24,switchBias=.25}
-- Urban Reload's crew relationships are not verified by this generic Teams filter.
-- Start unfiltered here; the user can still explicitly enable Team filter.
local urban_reload=game.PlaceId==84448037861644 or game.GameId==10769552054
if urban_reload then cfg.teamCheck=false end
local ranges={response={1,35},fov={30,500},maxDistance={50,3000},prediction={0,.25},espThickness={1,3},maxVisuals={4,48},switchBias={0,.6}}
local alive=true; local focused=true; local menu_open=true; local error_paused=false; local waiting_key=false
local connections={}; local roster={}; local locked=nil; local selected=nil; local ping=0; local elapsed=1; local ping_elapsed=1
local was_active=false
local theme={base=Color3.fromRGB(17,19,25),panel=Color3.fromRGB(25,29,38),input=Color3.fromRGB(20,23,31),line=Color3.fromRGB(47,53,67),text=Color3.fromRGB(233,239,249),muted=Color3.fromRGB(144,158,181),accent=Color3.fromRGB(159,189,244)}
local function make(class,props,p) local o=Instance.new(class); for key,value in pairs(props) do o[key]=value end; o.Parent=p; return o end
local function corner(o,r) return make("UICorner",{CornerRadius=UDim.new(0,r)},o) end
local function connect(signal,fn) local link=signal:Connect(fn); connections[#connections+1]=link; return link end
local gui=make("ScreenGui",{Name="DeepHatRefined",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=120,ZIndexBehavior=Enum.ZIndexBehavior.Sibling},parent)
pcall(function() gui.ScreenInsets=Enum.ScreenInsets.None end)
local canvas=make("Frame",{Name="Canvas",Size=UDim2.fromScale(1,1),BackgroundTransparency=1,BorderSizePixel=0},gui)
local circle=make("Frame",{Name="AimFOV",AnchorPoint=Vector2.new(.5,.5),BackgroundTransparency=1,Size=UDim2.fromOffset(cfg.fov*2,cfg.fov*2),Visible=false},canvas); corner(circle,10000)
local circle_stroke=make("UIStroke",{Color=theme.accent,Thickness=1,Transparency=.45,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},circle)
local panel=make("Frame",{Name="Settings",Position=UDim2.fromOffset(20,92),Size=UDim2.fromOffset(364,516),BackgroundColor3=theme.base,BorderSizePixel=0,ZIndex=20,Active=true},canvas); corner(panel,12)
make("UIStroke",{Color=theme.line,Thickness=1},panel)
local function text(p,value,x,y,w,h,size,color)
    return make("TextLabel",{Text=value,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),BackgroundTransparency=1,Font=Enum.Font.SourceSans,TextSize=size or 15,TextColor3=color or theme.text,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,ZIndex=21},p)
end
text(panel,"DeepHat",18,12,200,28,24).Font=Enum.Font.SourceSansBold
text(panel,"AIM & VISUALS  /  3.2",18,41,260,18,12,theme.muted)
local status=text(panel,"Hold E to aim",16,474,332,26,13,theme.muted)
status.Position=UDim2.new(0,16,1,-42); status.Size=UDim2.new(1,-32,0,26)
local diagnostic_label=text(panel,"Scanning players…",16,444,332,24,12,theme.muted)
diagnostic_label.Name="Diagnostics"; diagnostic_label.Position=UDim2.new(0,16,1,-72); diagnostic_label.Size=UDim2.new(1,-32,0,24)
local content=make("ScrollingFrame",{Position=UDim2.fromOffset(14,72),Size=UDim2.new(1,-28,1,-150),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=theme.accent,CanvasSize=UDim2.fromOffset(0,0),ZIndex=21},panel)
local badge=make("TextButton",{Name="MenuButton",Text="DeepHat",Position=UDim2.fromOffset(20,44),Size=UDim2.fromOffset(104,32),BackgroundColor3=theme.panel,TextColor3=theme.text,Font=Enum.Font.SourceSansSemibold,TextSize=16,BorderSizePixel=0,AutoButtonColor=false,ZIndex=20},canvas); corner(badge,7)
local live_status=text(canvas,"",136,44,460,32,14,theme.text)
live_status.Name="LiveStatus"; live_status.TextStrokeTransparency=.3
local control={Config=cfg,Version="3.2"}; local bindings={}; local y=0
local diagnostics={}; local character_cache={}; local last_reason="Ready"
local function set_status(value) if status.Text~=value then status.Text=value end; live_status.Text=value end
local function actor_character(who)
    if who.Character and who.Character.Parent then return who.Character end
    local cached=character_cache[who]
    if cached and cached.model and cached.model.Parent then return cached.model end
    if cached and os.clock()<cached.retry then return nil end
    local found=workspace:FindFirstChild(who.Name)
    if not found or not found:IsA("Model") then
        found=nil
        for _,name in ipairs({"Characters","PlayerCharacters","Players","Live","Alive","Entities"}) do
            local folder=workspace:FindFirstChild(name)
            if folder then
                local candidate=folder:FindFirstChild(who.Name,true)
                if not candidate and who.UserId then candidate=folder:FindFirstChild(tostring(who.UserId),true) end
                if candidate and candidate:IsA("Model") then found=candidate; break end
            end
        end
    end
    character_cache[who]={model=found,retry=os.clock()+1}
    return found
end
local function humanoid(character) return character and character:FindFirstChildWhichIsA("Humanoid",true) end
local function root(character)
    if not character then return nil end
    for _,name in ipairs({"HumanoidRootPart","RootPart","Torso","UpperTorso"}) do
        local part=character:FindFirstChild(name,true)
        if part and part:IsA("BasePart") then return part end
    end
    local part=character.PrimaryPart
    if part and part:IsA("BasePart") then return part end
end
local function teammates(who,char)
    local local_char=actor_character(player)
    return Core.teammate(cfg,player.Team,who.Team,player.Neutral,who.Neutral,local_char and local_char:GetAttribute("Team"),char and char:GetAttribute("Team"))
end
local function target_part(char)
    for _,name in ipairs(cfg.targetParts) do local p=char:FindFirstChild(name,true); if p and p:IsA("BasePart") then return p end end
end
local function actor(who)
    local char=actor_character(who); if not char then return nil,nil,nil,nil,"no character" end
    local hum=humanoid(char); if not hum then return nil,nil,nil,nil,"no Humanoid" end
    if hum.Health<=0 then return nil,nil,nil,nil,"dead" end
    local base=root(char); if not base then return nil,nil,nil,nil,"no root" end
    if teammates(who,char) then return nil,nil,nil,nil,"team filtered" end
    return char,hum,base,target_part(char)
end
local params=RaycastParams.new(); params.FilterType=Enum.RaycastFilterType.Exclude; params.IgnoreWater=true
local function clear_line(camera,point,char,force)
    if not cfg.checkLOS and not force then return true end
    local ignore={}; local mine=actor_character(player); if mine then ignore[1]=mine end
    params.FilterDescendantsInstances=ignore
    local delta=point-camera.CFrame.Position; if delta.Magnitude<.01 then return false end
    local hit=workspace:Raycast(camera.CFrame.Position,delta,params)
    return not hit or hit.Instance and hit.Instance:IsDescendantOf(char)
end
local function mouse_point(camera)
    if cfg.centerFov then return camera.ViewportSize/2-canvas.AbsolutePosition end
    return Input:GetMouseLocation()-canvas.AbsolutePosition
end
local function project(camera,point)
    local screen,on_screen=camera:WorldToViewportPoint(point)
    return Vector3.new(screen.X-canvas.AbsolutePosition.X,screen.Y-canvas.AbsolutePosition.Y,screen.Z),on_screen
end
local function dispose_visual(entry)
    if entry.visual then entry.visual.box:Destroy(); entry.visual=nil end
end
local function add_player(who) if who~=player and not roster[who] then roster[who]={player=who} end end
local function create_visual(entry)
    local box=make("Frame",{Name="PlayerBox",BackgroundTransparency=1,BorderSizePixel=0,Visible=false},canvas)
    local stroke=make("UIStroke",{Color=cfg.espColor,Thickness=cfg.espThickness,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},box)
    local label=text(box,"",0,-20,220,18,14); label.AnchorPoint=Vector2.new(.5,0); label.TextXAlignment=Enum.TextXAlignment.Center; label.TextStrokeTransparency=.45; label.ZIndex=3
    entry.visual={box=box,stroke=stroke,label=label}; return entry.visual
end
local function hide_visuals() for _,entry in pairs(roster) do if entry.visual then entry.visual.box.Visible=false end end end
local function reset_lock() locked=nil; selected=nil end
local function aim_held()
    if cfg.aimMouseButton then return Input:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) end
    return Input:IsKeyDown(Enum.KeyCode[cfg.aimKey])
end
local function local_alive()
    local char=actor_character(player); local hum=humanoid(char)
    return hum and hum.Health>0 and root(char)~=nil
end
local function aiming()
    if not cfg.enabled then last_reason="Aim disabled"
    elseif not focused then last_reason="Window unfocused"
    elseif menu_open then last_reason="Close menu with RightShift to aim"
    elseif error_paused then last_reason="Paused after error"
    elseif waiting_key then last_reason="Waiting for hold key"
    elseif Input:GetFocusedTextBox() then last_reason="Typing"
    elseif not local_alive() then last_reason="Local character not ready"
    elseif not aim_held() then last_reason="Hold "..(cfg.aimMouseButton and "RMB" or cfg.aimKey).." to aim"
    else last_reason="No target in FOV / check LOS"; return true end
    return false
end
local function row(caption)
    local frame=make("Frame",{Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,38),BackgroundColor3=theme.panel,BorderSizePixel=0,ZIndex=22},content); corner(frame,6)
    local label=text(frame,caption,12,0,224,38,15); label.Name="Caption"; label.Size=UDim2.new(1,-90,0,38); y=y+44; return frame
end
local function button(p,value,callback)
    local b=make("TextButton",{Text=value,AutoButtonColor=false,BackgroundColor3=theme.input,TextColor3=theme.text,Font=Enum.Font.SourceSansSemibold,TextSize=14,BorderSizePixel=0,ZIndex=23},p); corner(b,5)
    connect(b.Activated,callback); connect(b.MouseEnter,function() b.BackgroundColor3=theme.line end); connect(b.MouseLeave,function() b.BackgroundColor3=theme.input end); return b
end
local function refresh_controls()
    for _,update in ipairs(bindings) do update() end
end
function control:Set(key,value)
    if ranges[key] then value=assert(Core.bounded(value,ranges[key][1],ranges[key][2]),"Value out of range: "..key)
    elseif type(cfg[key])=="boolean" then assert(type(value)=="boolean","Use a boolean for "..key)
    elseif key=="aimKey" then assert(type(value)=="string" and value~="F8" and value~="Delete" and value~="RightShift" and pcall(function() assert(Enum.KeyCode[value]) end),"Invalid or reserved hold key")
    elseif key=="targetParts" then
        assert(type(value)=="table" and #value>=1 and #value<=4,"Use 1–4 target parts")
        for _,name in ipairs(value) do assert(name=="Head" or name=="UpperTorso" or name=="Torso" or name=="HumanoidRootPart","Unsupported target part") end
    else error("Unknown or non-editable setting: "..tostring(key)) end
    cfg[key]=value; error_paused=false; reset_lock(); elapsed=1; refresh_controls(); return true
end
function control:Stop()
    cfg.enabled=false; cfg.espEnabled=false; reset_lock(); circle.Visible=false; hide_visuals(); refresh_controls(); set_status("Stopped · enable controls to resume")
end
local binding_name="DeepHatRefined.Render"
function control:Unload()
    if not alive then return end; alive=false; reset_lock()
    Run:UnbindFromRenderStep(binding_name)
    for _,link in ipairs(connections) do link:Disconnect() end; connections={}
    for _,entry in pairs(roster) do dispose_visual(entry) end; roster={}
    gui:Destroy()
end
local function toggle(caption,key,get,set)
    local r=row(caption); local b
    local function read() if get then return get() end; return cfg[key] end
    b=button(r,"",function() local value=not read(); if set then set(value); elapsed=1; refresh_controls() else control:Set(key,value) end end)
    b.Position=UDim2.new(1,-65,0,7); b.Size=UDim2.fromOffset(54,24)
    bindings[#bindings+1]=function() local on=read(); b.Text=on and "ON" or "OFF"; b.TextColor3=on and theme.accent or theme.muted end
end
local function field(caption,key,format)
    local r=row(caption); r:FindFirstChild("Caption").Size=UDim2.new(1,-112,0,38); local box=make("TextBox",{Text="",ClearTextOnFocus=false,Position=UDim2.new(1,-91,0,6),Size=UDim2.fromOffset(80,26),BackgroundColor3=theme.input,TextColor3=theme.text,BorderSizePixel=0,TextSize=14,Font=Enum.Font.RobotoMono,ZIndex=23},r); corner(box,5)
    bindings[#bindings+1]=function() box.Text=format and string.format(format,cfg[key]) or tostring(cfg[key]) end
    connect(box.FocusLost,function() local ok,err=pcall(function() control:Set(key,box.Text) end); if not ok then set_status(tostring(err)); refresh_controls() end end)
end
toggle("Aim assist","enabled"); toggle("Player ESP","espEnabled")
toggle("Hard lock / no smoothing","hardLock"); toggle("Keep target while held","stickyTarget"); toggle("Center FOV on crosshair","centerFov")
toggle("Team filter","teamCheck",function() return cfg.teamCheck and not cfg.ignoreTeams end,function(value) cfg.teamCheck=value; cfg.ignoreTeams=false; reset_lock() end)
toggle("Line of sight","checkLOS"); toggle("Show FOV","showFov")
toggle("Prediction","predictionEnabled"); toggle("Use ping in lead","usePing")
local key_row=row("Hold key"); local key_button=button(key_row,"E",function() waiting_key=os.clock()+10; set_status("Press a key or right mouse button") end)
key_row:FindFirstChild("Caption").Size=UDim2.new(1,-112,0,38)
key_button.Position=UDim2.new(1,-91,0,6); key_button.Size=UDim2.fromOffset(80,26)
bindings[#bindings+1]=function() key_button.Text=cfg.aimMouseButton and "RMB" or cfg.aimKey end
local part_row=row("Target part"); local part_button
part_row:FindFirstChild("Caption").Size=UDim2.new(1,-160,0,38)
part_button=button(part_row,"Head",function()
    local choices={{"Head","UpperTorso","Torso","HumanoidRootPart"},{"UpperTorso","Torso","Head","HumanoidRootPart"},{"HumanoidRootPart","UpperTorso","Torso","Head"}}
    local at=1; for i,parts in ipairs(choices) do if parts[1]==cfg.targetParts[1] then at=i end end; control:Set("targetParts",choices[at%#choices+1])
end); part_button.Position=UDim2.new(1,-139,0,6); part_button.Size=UDim2.fromOffset(128,26)
bindings[#bindings+1]=function() part_button.Text=cfg.targetParts[1] end
field("FOV radius / pixels","fov"); field("Response / higher is faster","response"); field("Maximum distance / studs","maxDistance"); field("Prediction lead / seconds","prediction","%.3f")
toggle("ESP names & distances","names"); toggle("ESP visible only","espVisibleOnly")
local actions=row("RightShift menu · F8 stop")
local stop_button=button(actions,"Stop",function() control:Stop() end); stop_button.Position=UDim2.new(1,-65,0,7); stop_button.Size=UDim2.fromOffset(54,24)
content.CanvasSize=UDim2.fromOffset(0,y+4)
local close=button(panel,"×",function() control:Unload() end); close.Position=UDim2.new(1,-42,0,14); close.Size=UDim2.fromOffset(26,26)
local function menu(value) menu_open=value; panel.Visible=value; reset_lock(); set_status("Hold "..(cfg.aimMouseButton and "RMB" or cfg.aimKey).." · RightShift menu · F8 stop") end
connect(badge.Activated,function() menu(not menu_open) end)
connect(Input.InputBegan,function(event,processed)
    local key=event.KeyCode and event.KeyCode.Name
    if key=="F8" then control:Stop(); return end
    if key=="Delete" then control:Unload(); return end
    if waiting_key then
        if key=="Escape" then waiting_key=false; set_status("Binding cancelled"); return end
        if event.UserInputType==Enum.UserInputType.MouseButton2 then cfg.aimMouseButton=true; waiting_key=false; refresh_controls(); return end
        if key and key~="Unknown" and key~="RightShift" and event.UserInputType==Enum.UserInputType.Keyboard then
            local ok=pcall(function() control:Set("aimKey",key); cfg.aimMouseButton=false end); if ok then waiting_key=false; refresh_controls() end
        end
        return
    end
    if key=="RightShift" and not processed and not Input:GetFocusedTextBox() then menu(not menu_open) end
end)
connect(Input.WindowFocusReleased,function() focused=false; reset_lock(); circle.Visible=false; hide_visuals() end)
if Input.WindowFocused then connect(Input.WindowFocused,function() focused=true end) end
connect(Players.PlayerAdded,add_player)
connect(Players.PlayerRemoving,function(who) character_cache[who]=nil; local entry=roster[who]; if entry then dispose_visual(entry); roster[who]=nil end; if locked==who then reset_lock() end end)
for _,who in ipairs(Players:GetPlayers()) do add_player(who) end
local function snapshot(camera,mouse)
    local list={}; local mine=root(actor_character(player)); local origin=mine and mine.Position or camera.CFrame.Position
    diagnostics={players=0,eligible=0,onScreen=0,inFov=0,blocked=0,boxes=0,reasons={},actors={}}
    local function excluded(reason) diagnostics.reasons[reason]=(diagnostics.reasons[reason] or 0)+1 end
    for who,entry in pairs(roster) do
        diagnostics.players=diagnostics.players+1
        local char,hum,base,part,reason=actor(who)
        diagnostics.actors[who.Name]={reason=reason or "eligible",character=char and char:GetFullName()}
        entry.character=char; entry.base=base; entry.target=part; entry.distance=nil
        if base then
            local distance=(base.Position-origin).Magnitude
            if distance<=cfg.maxDistance then
                diagnostics.eligible=diagnostics.eligible+1
                entry.distance=distance
                if part then local point,on_screen=project(camera,part.Position); if on_screen and point.Z>.05 then
                    diagnostics.onScreen=diagnostics.onScreen+1
                    entry.screenDistance=(Vector2.new(point.X,point.Y)-mouse).Magnitude
                    if entry.screenDistance<=cfg.fov then diagnostics.inFov=diagnostics.inFov+1 end
                    list[#list+1]=entry
                end else excluded("no target part") end
            else excluded("out of range") end
        else excluded(reason or "unknown") end
        if entry.visual then entry.visual.box.Visible=false end
    end
    return list
end
local function draw_esp(camera,list)
    if not cfg.espEnabled or not focused then return end
    local ordered={}; for _,entry in pairs(roster) do if entry.distance then ordered[#ordered+1]=entry end end
    table.sort(ordered,function(a,b) return a.distance<b.distance end)
    local shown=0
    for _,entry in ipairs(ordered) do
        if shown>=cfg.maxVisuals then break end
        local visible=not cfg.espVisibleOnly or clear_line(camera,(entry.target or entry.base).Position,entry.character,true)
        if visible then
            local ok,frame,size=pcall(entry.character.GetBoundingBox,entry.character)
            if ok then
                local points={}; for _,x in ipairs({-1,1}) do for _,y in ipairs({-1,1}) do for _,z in ipairs({-1,1}) do
                    points[#points+1]=project(camera,(frame*CFrame.new(size.X*x/2,size.Y*y/2,size.Z*z/2)).Position)
                end end end
                local x,y,w,h=Core.bounds(points,canvas.AbsoluteSize.X,canvas.AbsoluteSize.Y)
                if x then
                    local visual=entry.visual or create_visual(entry); local signature=x..":"..y..":"..w..":"..h
                    if visual.signature~=signature then visual.signature=signature; visual.box.Position=UDim2.fromOffset(x,y); visual.box.Size=UDim2.fromOffset(w,h); visual.label.Position=UDim2.fromOffset(w/2,math.max(-20,-y)) end
                    visual.box.Visible=true; visual.stroke.Thickness=cfg.espThickness; visual.stroke.Color=entry.player==locked and theme.accent or cfg.espColor
                    visual.label.Visible=cfg.names; visual.label.Text=(entry.player.DisplayName or entry.player.Name).." · "..math.floor(entry.distance+.5).." studs"; shown=shown+1
                end
            end
        end
    end
    diagnostics.boxes=shown
end
local function render(dt)
    if not alive then return end
    local camera=workspace.CurrentCamera; if not camera then reset_lock(); hide_visuals(); circle.Visible=false; return end
    if waiting_key and os.clock()>waiting_key then waiting_key=false; set_status("Binding timed out") end
    local v=camera.ViewportSize; panel.Size=UDim2.fromOffset(math.max(280,math.min(364,v.X-24)),math.max(260,math.min(516,v.Y-104)))
    live_status.Size=UDim2.fromOffset(math.max(120,v.X-148),32)
    local mouse=mouse_point(camera); circle.Position=UDim2.fromOffset(mouse.X,mouse.Y); circle.Size=UDim2.fromOffset(cfg.fov*2,cfg.fov*2); circle.Visible=cfg.enabled and cfg.showFov and focused and not menu_open and not Input:GetFocusedTextBox() and not error_paused
    elapsed=elapsed+dt; ping_elapsed=ping_elapsed+dt; local active=aiming()
    local began=active and not was_active; was_active=active
    if not active then reset_lock() end
    if ping_elapsed>=1 then ping_elapsed=0; if cfg.usePing then local ok,value=pcall(player.GetNetworkPing,player); ping=ok and value or 0 end end
    if elapsed>=.05 or began then
        elapsed=0; local list=snapshot(camera,mouse)
        if active then selected=Core.pick(list,locked,cfg.fov,cfg.switchBias,function(entry)
            local visible=clear_line(camera,entry.target.Position,entry.character)
            if not visible then diagnostics.blocked=diagnostics.blocked+1 end
            return visible
        end,cfg.stickyTarget); locked=selected and selected.player or nil end
        draw_esp(camera,list)
        circle_stroke.Color=locked and Color3.fromRGB(142,224,182) or theme.accent
        local top_reason=""; local most=0
        for why,count in pairs(diagnostics.reasons) do if count>most then most=count; top_reason=" · "..why..": "..count end end
        diagnostic_label.Text="Players "..diagnostics.players.." · ready "..diagnostics.eligible.." · boxes "..diagnostics.boxes..top_reason
        if active and not locked then
            if diagnostics.eligible==0 then last_reason="No eligible players"..top_reason
            elseif diagnostics.inFov==0 then last_reason="No opponent in FOV · on screen "..diagnostics.onScreen
            elseif diagnostics.blocked>0 then last_reason="Line of sight blocked · "..diagnostics.blocked.." checked"
            else last_reason="Searching for target" end
        end
        if not waiting_key and not error_paused then set_status(locked and (cfg.hardLock and "Locked: " or "Tracking: ")..(locked.DisplayName or locked.Name) or last_reason) end
    end
    if active and locked then
        local char,_,base,part=actor(locked)
        if not part or not base then reset_lock(); return end
        local mine=root(actor_character(player)); if ((mine and mine.Position or camera.CFrame.Position)-base.Position).Magnitude>cfg.maxDistance then reset_lock(); return end
        local screen,on_screen=project(camera,part.Position)
        if not on_screen or screen.Z<=.05 or (not cfg.stickyTarget and (Vector2.new(screen.X,screen.Y)-mouse).Magnitude>cfg.fov*1.15) then reset_lock(); return end
        local velocity=base.AssemblyLinearVelocity or Vector3.zero; if velocity.Magnitude>150 then velocity=velocity.Unit*150 end
        local predicted=part.Position+velocity*Core.lead(cfg,ping)
        -- Check the actual body point; a predicted point can lie beyond a wall
        -- even while the player is visible. Never drop a visible lock just for that.
        if not clear_line(camera,part.Position,char) then reset_lock(); set_status("Line of sight blocked"); return end
        if not clear_line(camera,predicted,char) then predicted=part.Position end
        local origin=camera.CFrame.Position
        if (predicted-origin).Magnitude>.01 then
            local goal=CFrame.lookAt(origin,predicted)
            if cfg.hardLock then camera.CFrame=goal else camera.CFrame=camera.CFrame:Lerp(goal,Core.alpha(cfg.response,dt)) end
        end
    end
end
Run:BindToRenderStep(binding_name,Enum.RenderPriority.Last.Value+1,function(dt)
    if error_paused then return end
    local ok,err=pcall(render,dt)
    if not ok then error_paused=true; reset_lock(); hide_visuals(); circle.Visible=false; set_status("Paused: "..tostring(err)); warn("DeepHat Refined paused: "..tostring(err)) end
end)
local stop_event=make("BindableEvent",{Name="Unload"},gui); connect(stop_event.Event,function() control:Unload() end)
connect(gui.Destroying,function() control:Unload() end)
function control:GetStatus() local count=0; for _ in pairs(roster) do count=count+1 end; return {alive=alive,paused=error_paused,target=locked and locked.Name,players=count,menu=menu_open,reason=last_reason,diagnostics=diagnostics,placeId=game.PlaceId} end
refresh_controls(); menu(true)
print("DeepHat Refined 3.2 loaded · Hold E · RightShift menu · F8 stop · Delete unload")
return control
