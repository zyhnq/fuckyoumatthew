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
function Core.bounds(points,width,height,precise)
    local x0,y0,x1,y1=math.huge,math.huge,-math.huge,-math.huge
    for _,p in ipairs(points) do
        if not p or p.Z<=.05 or p.X~=p.X or p.Y~=p.Y then return nil end
        x0=math.min(x0,p.X); y0=math.min(y0,p.Y); x1=math.max(x1,p.X); y1=math.max(y1,p.Y)
    end
    x0=math.max(0,x0); y0=math.max(0,y0); x1=math.min(width,x1); y1=math.min(height,y1)
    if x1-x0<2 or y1-y0<2 then return nil end
    if precise then return x0,y0,x1-x0,y1-y0 end
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
-- Numeric client recoil states only: never run or replace another script.
function Core.recoil_adapter(discover)
    local self={enabled=false,records={},next_scan=0,reason="Off",count=0}
    local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
    function self:scan()
        if type(discover)~="function" then self.reason="Client table access unavailable"; return end
        local ok,objects=pcall(discover)
        if not ok or type(objects)~="table" then self.reason="Client state scan unavailable"; return end
        for _,object in pairs(objects) do
            if type(object)=="table" and not self.records[object] and self.count<128 then
                local pitch,yaw=rawget(object,"RecoilPitch"),rawget(object,"RecoilYaw")
                if finite(pitch) and finite(yaw) then
                    -- Keep backups as arrays so a later GC scan cannot mistake
                    -- our own backup records for game recoil state.
                    self.records[object]={pitch,yaw}; self.count=self.count+1
                end
            end
        end
        self.reason=self.count>0 and "Active" or "Waiting for supported weapon state"
    end
    function self:step(now)
        if not self.enabled then return end
        if now>=self.next_scan then self.next_scan=now+2; self:scan() end
        for object in pairs(self.records) do
            local writable=true
            for _,key in ipairs({"RecoilPitch","RecoilYaw"}) do
                local value=rawget(object,key)
                if finite(value) and value~=0 then local ok=pcall(rawset,object,key,0); if not ok then writable=false; break end end
            end
            if not writable then self.records[object]=nil; self.count=self.count-1 end
        end
        if self.count==0 and self.reason=="Active" then self.reason="No writable recoil state found" end
    end
    function self:disable()
        for object,values in pairs(self.records) do
            for index,key in ipairs({"RecoilPitch","RecoilYaw"}) do if rawget(object,key)==0 then pcall(rawset,object,key,values[index]) end end
        end
        self.enabled=false; self.records={}; self.count=0; self.next_scan=0; self.reason="Off"
    end
    function self:enable(now) self.enabled=true; self.next_scan=0; self:step(now or 0) end
    return self
end
if DEEPHAT_REFINED_TEST then return Core end

-- Vanta Urban 3.6 | standalone client script, native UI, no Drawing dependency.
local Players=game:GetService("Players")
local Run=game:GetService("RunService")
local Input=game:GetService("UserInputService")
local player=assert(Players.LocalPlayer,"Run this on the Roblox client")
local parent=player:WaitForChild("PlayerGui")
local previous=parent:FindFirstChild("VantaUrban") or parent:FindFirstChild("DeepHatRefined")
if previous then local stop=previous:FindFirstChild("Unload"); assert(stop,"Close the existing Urban GUI first"); stop:Fire() end
-- Stop the old supplied script's camera callbacks if it is still active.
Run:UnbindFromRenderStep("DeepHatRefined.Render"); Run:UnbindFromRenderStep("DeepHat_Aim"); Run:UnbindFromRenderStep("DeepHat_ESP")
local cfg={enabled=true,espEnabled=true,teamCheck=true,ignoreTeams=false,checkLOS=true,espVisibleOnly=false,
    hardLock=true,stickyTarget=true,centerFov=true,noRecoil=false,vehicleTargets=true,
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
local esp_entries={}
local theme={base=Color3.fromRGB(9,8,12),panel=Color3.fromRGB(16,13,22),input=Color3.fromRGB(19,15,26),line=Color3.fromRGB(37,29,46),text=Color3.fromRGB(240,236,246),muted=Color3.fromRGB(153,143,169),accent=Color3.fromRGB(182,66,235)}
local function make(class,props,p) local o=Instance.new(class); for key,value in pairs(props) do o[key]=value end; o.Parent=p; return o end
local function corner(o,r) return make("UICorner",{CornerRadius=UDim.new(0,r)},o) end
local function connect(signal,fn) local link=signal:Connect(fn); connections[#connections+1]=link; return link end
local gui=make("ScreenGui",{Name="VantaUrban",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=120,ZIndexBehavior=Enum.ZIndexBehavior.Sibling},parent)
pcall(function() gui.ScreenInsets=Enum.ScreenInsets.None end)
local canvas=make("Frame",{Name="Canvas",Size=UDim2.fromScale(1,1),BackgroundTransparency=1,BorderSizePixel=0},gui)
local circle=make("Frame",{Name="AimFOV",AnchorPoint=Vector2.new(.5,.5),BackgroundTransparency=1,Size=UDim2.fromOffset(cfg.fov*2,cfg.fov*2),Visible=false},canvas); corner(circle,10000)
local circle_stroke=make("UIStroke",{Color=theme.accent,Thickness=1,Transparency=.45,ApplyStrokeMode=Enum.ApplyStrokeMode.Border},circle)
local panel=make("Frame",{Name="Settings",AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.fromOffset(980,680),BackgroundColor3=theme.base,BorderSizePixel=0,ZIndex=20,Active=true},canvas); corner(panel,7)
make("UIStroke",{Color=theme.line,Thickness=1},panel)
local function text(p,value,x,y,w,h,size,color)
    return make("TextLabel",{Text=value,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),BackgroundTransparency=1,Font=Enum.Font.Gotham,TextSize=size or 15,TextColor3=color or theme.text,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,ZIndex=21},p)
end
text(panel,"VANTA",24,13,180,29,23).Font=Enum.Font.GothamBold
text(panel,"●  URBAN RELOAD",25,44,260,18,11,theme.accent)
local status=text(panel,"Hold E to aim",16,474,332,26,13,theme.muted)
status.Position=UDim2.new(0,198,1,-40); status.Size=UDim2.new(1,-218,0,26)
local diagnostic_label=text(panel,"Scanning players…",16,444,332,24,12,theme.muted)
diagnostic_label.Name="Diagnostics"; diagnostic_label.Position=UDim2.new(0,198,1,-68); diagnostic_label.Size=UDim2.new(1,-218,0,24)
local content=make("ScrollingFrame",{Position=UDim2.fromOffset(198,128),Size=UDim2.new(1,-218,1,-208),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=theme.accent,CanvasSize=UDim2.fromOffset(0,0),ZIndex=21},panel)
local badge=make("TextButton",{Name="MenuButton",Text="Vanta",Position=UDim2.fromOffset(20,44),Size=UDim2.fromOffset(104,32),BackgroundColor3=theme.panel,TextColor3=theme.text,Font=Enum.Font.GothamMedium,TextSize=16,BorderSizePixel=0,AutoButtonColor=false,ZIndex=20},canvas); corner(badge,7)
local live_status=text(canvas,"",136,44,460,32,14,theme.text)
live_status.Name="LiveStatus"; live_status.TextStrokeTransparency=.3
local control={Config=cfg,Version="3.6"}; local bindings={}; local y=0
local recoil=Core.recoil_adapter(type(getgc)=="function" and function() return getgc(true) end or nil)
local recoil_label
local panel_scale=make("UIScale",{Scale=1},panel)
local saved_position=nil; local minimized=false
make("Frame",{Position=UDim2.fromOffset(0,74),Size=UDim2.new(1,0,0,1),BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=21},panel)
local sidebar=make("Frame",{Position=UDim2.fromOffset(0,75),Size=UDim2.new(0,172,1,-75),BackgroundColor3=Color3.fromRGB(13,10,18),BorderSizePixel=0,ZIndex=20},panel)
local sidebar_line=make("Frame",{Position=UDim2.fromOffset(176,75),Size=UDim2.new(0,1,1,-75),BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=21},panel)
local section_title=text(panel,"Aim",202,88,400,30,21); section_title.Font=Enum.Font.GothamBold
local build_label=text(panel,"BUILD 2026.11.06.14",0,0,140,18,10,theme.muted); build_label.Font=Enum.Font.RobotoMono
local search=make("TextBox",{Name="VantaSearch",Text="",PlaceholderText="Find a control...",ClearTextOnFocus=false,Position=UDim2.new(1,-280,0,23),Size=UDim2.fromOffset(192,27),BackgroundColor3=theme.input,TextColor3=theme.text,PlaceholderColor3=theme.muted,Font=Enum.Font.Gotham,TextSize=13,BorderSizePixel=0,ZIndex=24},panel); corner(search,7)
make("UIPadding",{PaddingLeft=UDim.new(0,12),PaddingRight=UDim.new(0,8)},search)
local group=make("Frame",{Name="VantaUrbanGroup",Size=UDim2.new(1,-6,0,52),BackgroundColor3=theme.panel,BorderSizePixel=0,ZIndex=22},content); corner(group,9)
make("UIStroke",{Color=theme.line,Transparency=.35,Thickness=1},group)
local group_title=text(group,"Aim  −",14,0,500,44,18); group_title.Font=Enum.Font.GothamMedium; group_title.ZIndex=24
make("Frame",{Position=UDim2.fromOffset(14,44),Size=UDim2.new(1,-28,0,1),BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=23},group)
local ui_rows={}; local nav_buttons={}; local current_section="Aim"
local section_map={["Player ESP"]="ESP",["Show FOV"]="ESP",["ESP names & distances"]="ESP",["ESP visible only"]="ESP",["Prediction"]="Prediction",["Use ping in lead"]="Prediction",["Prediction lead / seconds"]="Prediction",["Hold key"]="Settings",["RightShift menu · F8 stop"]="Settings"}
local function show_section(name,keep_scroll)
    current_section=name; local query=search.Text:lower(); local title=query~="" and "Search" or name
    section_title.Text=title; group_title.Text=title.."  −"; local offset=52
    for _,entry in ipairs(ui_rows) do
        entry.frame.Visible=query~="" and entry.caption:lower():find(query,1,true)~=nil or query=="" and entry.section==name
        if entry.frame.Visible then entry.frame.Position=UDim2.fromOffset(0,offset); offset=offset+entry.height end
    end
    group.Size=UDim2.new(1,-6,0,offset+8); content.CanvasSize=UDim2.fromOffset(0,offset+16)
    if not keep_scroll then content.CanvasPosition=Vector2.new(0,0) end
    for key,item in pairs(nav_buttons) do
        local on=key==name; item.button.BackgroundColor3=on and Color3.fromRGB(39,20,53) or Color3.fromRGB(13,10,18)
        item.label.TextColor3=on and theme.accent or theme.muted; item.marker.Visible=on
    end
end
local function nav_icon(owner,kind)
    local root=make("Frame",{Name="LineIcon",Position=UDim2.fromOffset(10,9),Size=UDim2.fromOffset(20,20),BackgroundTransparency=1,ZIndex=24},owner)
    local function line(x0,y0,x1,y1)
        local dx,dy=x1-x0,y1-y0
        local p=make("Frame",{Position=UDim2.fromOffset((x0+x1)/2,(y0+y1)/2),AnchorPoint=Vector2.new(.5,.5),Size=UDim2.fromOffset(math.sqrt(dx*dx+dy*dy),1.4),Rotation=math.deg(math.atan2(dy,dx)),BackgroundColor3=theme.muted,BorderSizePixel=0,ZIndex=24},root); corner(p,1)
    end
    if kind=="ESP" then
        for _,p in ipairs({{3,3},{12,3},{3,12},{12,12}}) do local box=make("Frame",{Position=UDim2.fromOffset(p[1],p[2]),Size=UDim2.fromOffset(5,5),BackgroundTransparency=1,ZIndex=24},root); make("UIStroke",{Color=theme.muted,Thickness=1},box) end
    elseif kind=="Settings" then
        for _,y in ipairs({5,10,15}) do line(3,y,17,y) end; line(7,3,7,7); line(13,8,13,12); line(6,13,6,17)
    elseif kind=="Prediction" then line(3,15,8,10); line(8,10,12,12); line(12,12,17,4); line(12,4,17,4); line(17,4,17,9)
    else
        local ring=make("Frame",{Position=UDim2.fromOffset(4,4),Size=UDim2.fromOffset(12,12),BackgroundTransparency=1,ZIndex=24},root); corner(ring,8); make("UIStroke",{Color=theme.muted,Thickness=1},ring)
        line(10,1,10,5); line(10,15,10,19); line(1,10,5,10); line(15,10,19,10)
    end
    return root
end
for i,name in ipairs({"Aim","ESP","Prediction","Settings"}) do
    local b=make("TextButton",{Name="VantaTab_"..name,Text="",AutoButtonColor=false,Position=UDim2.fromOffset(10,90+(i-1)*43),Size=UDim2.fromOffset(156,38),BackgroundColor3=theme.panel,BorderSizePixel=0,ZIndex=22},panel); corner(b,5)
    local symbol=nav_icon(b,name)
    local caption=text(b,name,40,0,112,38,13,theme.muted); caption.ZIndex=24
    local marker=make("Frame",{Position=UDim2.fromOffset(-4,8),Size=UDim2.fromOffset(3,22),BackgroundColor3=theme.accent,BorderSizePixel=0,ZIndex=24},b)
    nav_buttons[name]={button=b,label=caption,marker=marker,icon=symbol}
    connect(b.Activated,function() search.Text=""; show_section(name) end)
    connect(b.MouseEnter,function() b.BackgroundColor3=Color3.fromRGB(39,20,53) end)
    connect(b.MouseLeave,function() b.BackgroundColor3=current_section==name and Color3.fromRGB(39,20,53) or Color3.fromRGB(13,10,18) end)
end
connect(search:GetPropertyChangedSignal("Text"),function() show_section(current_section) end)

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
        for _,name in ipairs({"Characters","PlayerCharacters","Players","Live","Alive","Entities","Vehicles","Cars"}) do
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
local vehicle_cache=setmetatable({},{__mode="k"})
local function vehicle_for(character)
    if not character then return nil end
    local hum=humanoid(character); local seat=hum and hum.SeatPart
    if not seat or not seat.Parent then vehicle_cache[character]=nil; return nil end
    local assembly=seat.AssemblyRootPart or seat
    local raw_assembly=assembly
    local cached=vehicle_cache[character]
    if cached and cached.seat==seat and cached.raw_assembly==raw_assembly and os.clock()<cached.expires and cached.model and cached.model.Parent then return cached.model end
    local characters={character}
    local mine=actor_character(player); if mine and mine~=character then characters[#characters+1]=mine end
    for who in pairs(roster) do local other=actor_character(who); if other and other~=character and other~=mine then characters[#characters+1]=other end end
    local function belongs_to_character(part)
        for _,model in ipairs(characters) do if part==model or part:IsDescendantOf(model) then return true end end
        return false
    end
    if belongs_to_character(assembly) then assembly=seat end
    -- Find the smallest model that contains this seat's connected assembly.
    -- Never exclude a shared Vehicles folder or the entire Workspace.
    local connected={seat,assembly}
    local ok,parts=pcall(function() return seat:GetConnectedParts(true) end)
    if ok and type(parts)=="table" then for i=1,math.min(256,#parts) do if not belongs_to_character(parts[i]) then connected[#connected+1]=parts[i] end end end
    local candidate=seat.Parent; local model
    while candidate and candidate~=workspace do
        if candidate:IsA("Model") and candidate~=character and candidate.Name~="Characters" and candidate.Name~="Players" and candidate.Name~="Vehicles" and candidate.Name~="Cars" then
            local contains=true
            for _,part in ipairs(connected) do if part~=candidate and not part:IsDescendantOf(candidate) then contains=false; break end end
            -- Do not treat an ancestor that holds multiple vehicles/characters as a car.
            if contains then model=candidate; break end
        end
        candidate=candidate.Parent
    end
    vehicle_cache[character]={seat=seat,raw_assembly=raw_assembly,model=model,expires=os.clock()+1}
    return model
end
local function clear_line(camera,point,char,force)
    if not cfg.checkLOS and not force then return true end
    local ignore={}; local mine=actor_character(player); if mine then ignore[1]=mine end
    local own_vehicle=vehicle_for(mine); if own_vehicle then ignore[#ignore+1]=own_vehicle end
    if cfg.vehicleTargets then local target_vehicle=vehicle_for(char); if target_vehicle and target_vehicle~=own_vehicle then ignore[#ignore+1]=target_vehicle end end
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
    if minimized then last_reason="Menu minimized"; return false end
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
    local frame=make("Frame",{Position=UDim2.fromOffset(0,y),Size=UDim2.new(1,-6,0,52),BackgroundTransparency=1,BackgroundColor3=theme.panel,BorderSizePixel=0,ZIndex=22},group)
    local label=text(frame,caption,10,0,224,46,15); label.Name="Caption"; label.Size=UDim2.new(1,-110,0,46); label.ZIndex=24
    make("Frame",{Position=UDim2.new(0,10,1,-1),Size=UDim2.new(1,-20,0,1),BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=23},frame)
    ui_rows[#ui_rows+1]={frame=frame,caption=caption,section=section_map[caption] or "Aim",height=52}; y=y+52; return frame
end
local function button(p,value,callback)
    local b=make("TextButton",{Text=value,AutoButtonColor=false,BackgroundColor3=theme.input,TextColor3=theme.text,Font=Enum.Font.GothamMedium,TextSize=14,BorderSizePixel=0,ZIndex=23},p); corner(b,5)
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
    cfg[key]=value
    if key=="noRecoil" then if value then recoil:enable(os.clock()) else recoil:disable() end end
    error_paused=false; reset_lock(); elapsed=1; refresh_controls(); return true
end
function control:Stop()
    cfg.enabled=false; cfg.espEnabled=false; cfg.noRecoil=false; recoil:disable(); reset_lock(); circle.Visible=false; hide_visuals(); refresh_controls(); set_status("Stopped · enable controls to resume")
end
local binding_name="VantaUrban.Render"
function control:Unload()
    if not alive then return end; alive=false; reset_lock()
    Run:UnbindFromRenderStep(binding_name)
    Run:UnbindFromRenderStep("VantaUrban.Recoil"); recoil:disable()
    for _,link in ipairs(connections) do link:Disconnect() end; connections={}
    for _,entry in pairs(roster) do dispose_visual(entry) end; roster={}
    gui:Destroy()
end
local function toggle(caption,key,get,set)
    local r=row(caption); local b
    if key=="noRecoil" then r:FindFirstChild("Caption").Size=UDim2.new(1,-110,0,28); recoil_label=text(r,"Off",10,29,400,18,11,theme.muted); recoil_label.Size=UDim2.new(1,-84,0,18); recoil_label.Name="RecoilStatus" end
    local function read() if get then return get() end; return cfg[key] end
    b=button(r,"",function() local value=not read(); if set then set(value); elapsed=1; refresh_controls() else control:Set(key,value) end end)
    b.Position=UDim2.new(1,-64,0,12); b.Size=UDim2.fromOffset(44,24); b.TextTransparency=1; b.BackgroundTransparency=1
    local track=make("Frame",{Name="Track",Size=UDim2.fromOffset(44,22),BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=24},b); corner(track,12)
    local knob=make("Frame",{Name="Knob",Position=UDim2.fromOffset(3,3),Size=UDim2.fromOffset(16,16),BackgroundColor3=theme.text,BorderSizePixel=0,ZIndex=25},track); corner(knob,10)
    bindings[#bindings+1]=function() local on=read(); b.Text=on and "ON" or "OFF"; b.TextColor3=on and theme.accent or theme.muted; track.BackgroundColor3=on and theme.accent or theme.line; knob.Position=UDim2.fromOffset(on and 25 or 3,3) end
end
local function field(caption,key,format)
    local r=row(caption); r:FindFirstChild("Caption").Size=UDim2.new(1,-112,0,38); local box=make("TextBox",{Text="",ClearTextOnFocus=false,Position=UDim2.new(1,-91,0,6),Size=UDim2.fromOffset(80,26),BackgroundColor3=theme.input,TextColor3=theme.text,BorderSizePixel=0,TextSize=14,Font=Enum.Font.RobotoMono,ZIndex=23},r); corner(box,5)
    bindings[#bindings+1]=function() box.Text=format and string.format(format,cfg[key]) or tostring(cfg[key]) end
    connect(box.FocusLost,function() local ok,err=pcall(function() control:Set(key,box.Text) end); if not ok then set_status(tostring(err)); refresh_controls() end end)
    r.Size=UDim2.new(1,-6,0,82); ui_rows[#ui_rows].height=82; y=y+30
    local slider=make("TextButton",{Name="VantaSlider_"..key,Text="",AutoButtonColor=false,Position=UDim2.fromOffset(12,52),Size=UDim2.new(1,-26,0,18),BackgroundTransparency=1,ZIndex=24},r)
    local track=make("Frame",{Position=UDim2.fromOffset(0,7),Size=UDim2.new(1,0,0,4),BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=24},slider); corner(track,2)
    local fill=make("Frame",{Size=UDim2.fromScale(0,1),BackgroundColor3=theme.accent,BorderSizePixel=0,ZIndex=25},track); corner(fill,2)
    local dot=make("Frame",{Size=UDim2.fromOffset(12,12),AnchorPoint=Vector2.new(.5,.5),BackgroundColor3=theme.text,BorderSizePixel=0,ZIndex=26},track); corner(dot,7)
    bindings[#bindings+1]=function() local range=ranges[key]; local amount=(cfg[key]-range[1])/(range[2]-range[1]); fill.Size=UDim2.fromScale(amount,1); dot.Position=UDim2.new(amount,0,.5,0) end
    local dragging
    local function move(position)
        if slider.AbsoluteSize.X<=0 then return end
        local range=ranges[key]; local amount=math.max(0,math.min(1,(position.X-slider.AbsolutePosition.X)/slider.AbsoluteSize.X))
        local value=range[1]+(range[2]-range[1])*amount
        if key~="prediction" then value=math.floor(value+.5) else value=math.floor(value*1000+.5)/1000 end
        control:Set(key,value)
    end
    connect(slider.InputBegan,function(event) if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch then dragging=event; move(event.Position) end end)
    connect(Input.InputChanged,function(event) if dragging and (event==dragging or event.UserInputType==Enum.UserInputType.MouseMovement) then move(event.Position) end end)
    connect(Input.InputEnded,function(event) if event==dragging or event.UserInputType==Enum.UserInputType.MouseButton1 then dragging=nil end end)

end
toggle("Aim assist","enabled"); toggle("Player ESP","espEnabled")
toggle("No recoil","noRecoil"); toggle("Target vehicle occupants","vehicleTargets")
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
show_section("Aim")
local close=button(panel,"X",function() control:Unload() end); close.Position=UDim2.new(1,-40,0,24); close.Size=UDim2.fromOffset(24,26)
local restore; restore=button(canvas,"Vanta  ·  Restore",function() minimized=false; panel.Visible=true; restore.Visible=false end)
restore.Name="VantaRestore"; restore.Size=UDim2.fromOffset(164,34); restore.Position=UDim2.fromOffset(20,88); restore.Visible=false
local minimize=button(panel,"−",function() minimized=true; panel.Visible=false; restore.Visible=true end)
minimize.Name="Minimize"; minimize.Position=UDim2.new(1,-72,0,24); minimize.Size=UDim2.fromOffset(24,26)
local footer_stop=button(panel,"Stop all  ·  F8",function() control:Stop() end)
footer_stop.Position=UDim2.new(1,-116,1,-39); footer_stop.Size=UDim2.fromOffset(96,28)
local footer_line=make("Frame",{BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=21},panel)
local drag_handle=make("Frame",{Name="VantaDragHandle",Size=UDim2.new(1,-300,0,74),BackgroundTransparency=1,Active=true,ZIndex=21},panel)
local drag_start,drag_position
connect(drag_handle.InputBegan,function(event)
    if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch then drag_start=event.Position; drag_position=panel.Position end
end)
connect(Input.InputChanged,function(event)
    if drag_start and (event.UserInputType==Enum.UserInputType.MouseMovement or event.UserInputType==Enum.UserInputType.Touch) then
        local camera=workspace.CurrentCamera; if not camera then return end
        local v=camera.ViewportSize; local delta=event.Position-drag_start
        local hw=panel.Size.X.Offset*panel_scale.Scale/2; local hh=panel.Size.Y.Offset*panel_scale.Scale/2
        local x=drag_position.X.Scale*v.X+drag_position.X.Offset+delta.X; local y=drag_position.Y.Scale*v.Y+drag_position.Y.Offset+delta.Y
        saved_position=Vector2.new(math.max(hw+6,math.min(v.X-hw-6,x)),math.max(hh+6,math.min(v.Y-hh-6,y)))
    end
end)
connect(Input.InputEnded,function(event) if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch then drag_start=nil; drag_position=nil end end)

local function menu(value) menu_open=value; panel.Visible=value; minimized=false; restore.Visible=false; reset_lock(); set_status("Hold "..(cfg.aimMouseButton and "RMB" or cfg.aimKey).." · RightShift menu · F8 stop") end
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
    diagnostics={players=0,eligible=0,onScreen=0,inFov=0,blocked=0,boxes=diagnostics.boxes or 0,reasons={},actors={}}
    local function excluded(reason) diagnostics.reasons[reason]=(diagnostics.reasons[reason] or 0)+1 end
    for who,entry in pairs(roster) do
        diagnostics.players=diagnostics.players+1
        local char,hum,base,part,reason=actor(who)
        diagnostics.actors[who.Name]={reason=reason or "eligible",character=char and char:GetFullName(),seated=hum and hum.SeatPart~=nil or false}
        entry.character=char; entry.humanoid=hum; entry.base=base; entry.target=part; entry.distance=nil
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
local function refresh_esp(camera)
    esp_entries={}
    if not cfg.espEnabled or not focused then return end
    local ordered={}; for _,entry in pairs(roster) do if entry.distance then ordered[#ordered+1]=entry end end
    table.sort(ordered,function(a,b) return a.distance<b.distance end)
    for _,entry in ipairs(ordered) do
        if #esp_entries>=cfg.maxVisuals then break end
        local visible=not cfg.espVisibleOnly or clear_line(camera,(entry.target or entry.base).Position,entry.character,true)
        if visible then
            local ok,frame,size=pcall(entry.character.GetBoundingBox,entry.character)
            if ok then
                entry.boundsOffset=entry.base.CFrame:ToObjectSpace(frame); entry.boundsSize=size
                esp_entries[#esp_entries+1]=entry
            end
        end
    end
end
local function draw_esp(camera)
    if not cfg.espEnabled or not focused then hide_visuals(); diagnostics.boxes=0; return end
    local shown=0
    for _,entry in ipairs(esp_entries) do
        local visual=entry.visual
        if visual then visual.box.Visible=false end
        if roster[entry.player]==entry and entry.base and entry.base.Parent and entry.character and entry.character.Parent and entry.humanoid and entry.humanoid.Health>0 then
            local frame=entry.base.CFrame*entry.boundsOffset; local size=entry.boundsSize
                local points={}; for _,x in ipairs({-1,1}) do for _,y in ipairs({-1,1}) do for _,z in ipairs({-1,1}) do
                    points[#points+1]=project(camera,(frame*CFrame.new(size.X*x/2,size.Y*y/2,size.Z*z/2)).Position)
                end end end
                local x,y,w,h=Core.bounds(points,canvas.AbsoluteSize.X,canvas.AbsoluteSize.Y,true)
                if x then
                    local visual=entry.visual or create_visual(entry); local signature=x..":"..y..":"..w..":"..h
                    if visual.signature~=signature then visual.signature=signature; visual.box.Position=UDim2.fromOffset(x,y); visual.box.Size=UDim2.fromOffset(w,h); visual.label.Position=UDim2.fromOffset(w/2,math.max(-20,-y)) end
                    visual.box.Visible=true; visual.stroke.Thickness=cfg.espThickness; visual.stroke.Color=entry.player==locked and theme.accent or cfg.espColor
                    visual.label.Visible=cfg.names; visual.label.Text=(entry.player.DisplayName or entry.player.Name).." · "..math.floor(entry.distance+.5).." studs"; shown=shown+1
                end
        end
    end
    diagnostics.boxes=shown
end
local function render(dt)
    if not alive then return end
    local camera=workspace.CurrentCamera; if not camera then reset_lock(); hide_visuals(); circle.Visible=false; return end
    if waiting_key and os.clock()>waiting_key then waiting_key=false; set_status("Binding timed out") end
    local v=camera.ViewportSize; local w=math.max(340,math.min(980,v.X-24)); local h=math.max(430,math.min(680,v.Y-32))
    panel.Size=UDim2.fromOffset(w,h); panel_scale.Scale=math.min(1,(v.X-12)/w,(v.Y-12)/h)
    if saved_position then panel.Position=UDim2.fromOffset(saved_position.X,saved_position.Y) else panel.Position=UDim2.fromScale(.5,.5) end
    local desktop=w>=600; local left=desktop and 202 or 18; local top=desktop and 132 or 174
    sidebar.Visible=desktop; sidebar_line.Visible=desktop; sidebar.Size=UDim2.new(0,176,1,-75)
    badge.Visible=not menu_open; live_status.Visible=not menu_open
    content.Position=UDim2.fromOffset(left,top); content.Size=UDim2.new(1,-left-18,1,-top-64)
    section_title.Visible=desktop; section_title.Position=UDim2.fromOffset(left,88)
    group_title.Size=UDim2.new(1,-28,0,44)
    search.Visible=desktop
    status.Position=UDim2.new(0,left,1,-42); status.Size=UDim2.new(1,-left-276,0,32)
    diagnostic_label.Visible=false
    footer_line.Position=UDim2.new(0,left,1,-49); footer_line.Size=UDim2.new(1,-left-18,0,1)
    build_label.Visible=desktop; build_label.Position=UDim2.new(1,-256,1,-31)
    for i,name in ipairs({"Aim","ESP","Prediction","Settings"}) do
        local item=nav_buttons[name]
        item.button.Position=desktop and UDim2.fromOffset(10,90+(i-1)*43) or UDim2.fromOffset(18+(i-1)*(w-36)/4,98)
        item.button.Size=desktop and UDim2.fromOffset(156,38) or UDim2.fromOffset((w-36)/4-3,30)
        item.icon.Visible=desktop; item.label.Position=UDim2.fromOffset(desktop and 40 or 0,0); item.label.Size=UDim2.new(1,desktop and -44 or 0,1,0)
        item.label.TextSize=desktop and 13 or 11; item.label.TextXAlignment=desktop and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center
    end
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
        refresh_esp(camera)
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
    local ok,err=pcall(function()
        render(dt)
        local camera=workspace.CurrentCamera
        if camera then draw_esp(camera) end
    end)
    if not ok then error_paused=true; cfg.noRecoil=false; recoil:disable(); reset_lock(); hide_visuals(); circle.Visible=false; set_status("Paused: "..tostring(err)); warn("Vanta Urban paused: "..tostring(err)) end
end)
Run:BindToRenderStep("VantaUrban.Recoil",Enum.RenderPriority.Camera.Value-1,function()
    local ok,err=pcall(function() recoil:step(os.clock()) end)
    if not ok then recoil:disable(); cfg.noRecoil=false; recoil.reason="Client state update failed"; warn("Vanta Urban recoil: "..tostring(err)) end
    if recoil_label then recoil_label.Text=recoil.reason..(recoil.count>0 and " · "..recoil.count.." states" or "") end
end)
local stop_event=make("BindableEvent",{Name="Unload"},gui); connect(stop_event.Event,function() control:Unload() end)
connect(gui.Destroying,function() control:Unload() end)
function control:GetStatus() local count=0; for _ in pairs(roster) do count=count+1 end; return {alive=alive,paused=error_paused,target=locked and locked.Name,players=count,menu=menu_open,reason=last_reason,diagnostics=diagnostics,placeId=game.PlaceId,recoil={enabled=recoil.enabled,states=recoil.count,reason=recoil.reason}} end
refresh_controls(); menu(true)
print("Vanta Urban 3.6 loaded · Hold E · RightShift menu · F8 stop · Delete unload")
return control
