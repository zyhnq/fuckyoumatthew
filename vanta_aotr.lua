-- Vanta AOTR | independently implemented mission automation.
local Core={}
function Core.bounded(value,lo,hi)
    value=tonumber(value); if not value or value~=value or math.abs(value)==math.huge or value<lo or value>hi then return nil end; return value
end
function Core.path(object,names) for _,name in ipairs(names) do object=object and object:FindFirstChild(name) end; return object end
function Core.visible(object)
    if not object or not object.Parent then return false end
    while object do
        if object:IsA("GuiObject") and not object.Visible then return false end
        if object:IsA("ScreenGui") and not object.Enabled then return false end
        object=object.Parent
    end
    return true
end
function Core.target(titans,origin,current,options)
    if not titans then return nil end
    local best,distance=nil,math.huge
    for _,model in ipairs(titans:GetChildren()) do
        if model:IsA("Model") then
            local hum=model:FindFirstChildOfClass("Humanoid")
            local nape=Core.path(model,{"Hitboxes","Hit","Nape"})
            local marker=model:FindFirstChild("Marker")
            if options.bossWeakpoint and marker then
                local ok,part=pcall(function() return marker.Adornee end)
                if ok and part and part:IsA("BasePart") and part:IsDescendantOf(model) then nape=part end
            end
            if hum and hum.Health>0 and nape and nape:IsA("BasePart") then
                local d=(nape.Position-origin).Magnitude
                if d<=options.range then
                    local candidate={model=model,part=nape,humanoid=hum,distance=d}
                    if current==model then return candidate end
                    if d<distance then best=candidate; distance=d end
                end
            end
        end
    end
    return best
end
function Core.engine(ctx)
    local self={config={farm=false,attack=true,aim=true,reload=true,retry=false,noclip=true,esp=false,bossWeakpoint=true,
        speed=110,range=6000,distance=7,height=1,attackInterval=.55,reloadKey="R"},
        alive=true,phase="Idle",message="Join a mission, then enable Auto farm",target=nil,swings=0,eliminations=0,reloads=0,retries=0,lastError=nil}
    local ranges={speed={30,220},range={100,12000},distance={3,16},height={-5,12},attackInterval={.25,2}}
    local nextAttack,nextReload,nextRetry=0,0,0
    local retrySeen=nil; local retriesForPanel=0; local paused=false
    local function release() if ctx.release then ctx.release() end; if ctx.halt then ctx.halt() end end
    local function status(phase,message) self.phase=phase; self.message=message end
    function self:set(key,value)
        if ranges[key] then value=assert(Core.bounded(value,ranges[key][1],ranges[key][2]),"Value outside allowed range")
        elseif type(self.config[key])=="boolean" then assert(type(value)=="boolean","Use true/false")
        elseif key=="reloadKey" then assert(type(value)=="string" and #value==1 and value:match("^[A-Z]$"),"Use one letter A–Z")
        else error("Unknown setting: "..tostring(key)) end
        self.config[key]=value
        if key=="farm" then self.target=nil; nextAttack=0; paused=false; if not value then release(); status("Idle","Auto farm off") end end
        if key=="noclip" and not value and ctx.restore_collision then ctx.restore_collision() end
    end
    function self:stop()
        self.config.farm=false; self.config.retry=false; self.config.esp=false; self.target=nil; release(); status("Stopped","Stopped · all farm input and movement released")
    end
    function self:close() if not self.alive then return end; self:stop(); self.alive=false end
    function self:step(dt)
        if not self.alive then return end
        local now=ctx.now(); local character,root,hum,gear=ctx.character()
        if self.target and (not self.target.model.Parent or self.target.humanoid.Health<=0) then
            if self.target.humanoid.Health<=0 then self.eliminations=self.eliminations+1 end
            self.target=nil
        end
        if ctx.paused() then
            if not paused then release(); paused=true end
            status("Paused","Paused while the menu is open, typing, or the window is unfocused"); return
        end
        paused=false
        local retry=ctx.retry_button and ctx.retry_button()
        if not retry then retrySeen=nil; retriesForPanel=0 end
        if retry and self.config.retry then
            release(); self.target=nil
            if retrySeen~=retry then retrySeen=retry; retriesForPanel=0 end
            if now>=nextRetry and retriesForPanel<3 then
                ctx.click_button(retry); nextRetry=now+5; retriesForPanel=retriesForPanel+1; self.retries=self.retries+1
            end
            status("Rewards","Mission complete · retry requested"); return
        end
        if not self.config.farm then status("Idle","Enable Auto farm to start"); return end
        if not character or not root or not hum or hum.Health<=0 then release(); self.target=nil; status("Waiting","Waiting for a living character"); return end
        if not gear then release(); self.target=nil; status("Lobby","Enter a mission and equip your ODM gear"); return end
        local titans=ctx.titans()
        if not titans then release(); self.target=nil; status("Waiting","Waiting for the mission titan container"); return end
        local target=Core.target(titans,root.Position,self.target and self.target.model,self.config)
        self.target=target
        if not target then release(); status("Waiting","No living titan within search range"); return end
        if self.config.reload and ctx.broken_blade and ctx.broken_blade(character) and now>=nextReload then
            release(); ctx.key(self.config.reloadKey); self.reloads=self.reloads+1; nextReload=now+3; nextAttack=now+1.5
            status("Reloading","Reload requested · waiting for blades"); return
        end
        local goal=target.part.CFrame.Position+target.part.CFrame.LookVector*self.config.distance+Vector3.new(0,self.config.height,0)
        ctx.move(character,root,goal,target.part.Position,self.config,dt)
        local d=(target.part.Position-root.Position).Magnitude
        if d<=math.max(12,self.config.distance+5) then
            status("Farming","Target in reach · normal attack input")
            if self.config.attack and now>=nextAttack then ctx.attack(); self.swings=self.swings+1; nextAttack=now+self.config.attackInterval end
        else status("Approaching","Approaching nearest nape · "..math.floor(d).." studs") end
    end
    function self:tick(dt)
        local ok,err=pcall(function() self:step(dt) end)
        if not ok then self:stop(); self.lastError=tostring(err); status("Error",tostring(err)); if ctx.error then ctx.error(err) end end
    end
    return self
end
if VANTA_AOTR_TEST then return Core end

-- Vanta AOTR 1.0 | mission bindings validated against supplied capture.
local Players=game:GetService("Players")
local Run=game:GetService("RunService")
local Input=game:GetService("UserInputService")
local player=assert(Players.LocalPlayer,"Run Vanta on the client")
assert(game.GameId==4658598196 or game.PlaceId==13379208636,"Join Attack on Titan Revolution first")
local parent=player:WaitForChild("PlayerGui")
local previous=parent:FindFirstChild("VantaAOTR")
if previous then local unload=previous:FindFirstChild("Unload"); assert(unload,"Close the old Vanta AOTR first"); unload:Fire() end
local connections={}; local alive=true; local menu_open=true; local focused=true
local function connect(signal,fn) local c=signal:Connect(fn); connections[#connections+1]=c; return c end
local function make(class,properties,p) local obj=Instance.new(class); for k,v in pairs(properties) do obj[k]=v end; obj.Parent=p; return obj end
local function round(obj,size) make("UICorner",{CornerRadius=UDim.new(0,size)},obj) end
local theme={base=Color3.fromRGB(9,8,12),rail=Color3.fromRGB(13,10,18),panel=Color3.fromRGB(16,13,22),input=Color3.fromRGB(19,15,26),
    line=Color3.fromRGB(37,29,46),text=Color3.fromRGB(240,236,246),muted=Color3.fromRGB(153,143,169),accent=Color3.fromRGB(182,66,235),selected=Color3.fromRGB(39,20,53)}
local virtual; pcall(function() virtual=game:GetService("VirtualInputManager") end)
local mouse_down=false; local held_key; local input_release_at; local mouse_x,mouse_y=0,0
local function release_input()
    if mouse_down then pcall(function() virtual:SendMouseButtonEvent(mouse_x,mouse_y,0,false,game,0) end); mouse_down=false end
    if held_key then local key=held_key; pcall(function() virtual:SendKeyEvent(false,key,false,game) end); held_key=nil end
    input_release_at=nil
end
local function click_at(x,y)
    assert(virtual,"Mouse input simulation is unavailable in this executor")
    mouse_down=true; mouse_x=x; mouse_y=y
    local ok,err=pcall(function() virtual:SendMouseButtonEvent(x,y,0,true,game,0) end)
    local released,release_error=pcall(function() virtual:SendMouseButtonEvent(x,y,0,false,game,0) end)
    if released then mouse_down=false end
    assert(ok and released,tostring(err or release_error))
end
local function key_press(name)
    assert(virtual,"Keyboard simulation is unavailable in this executor")
    held_key=Enum.KeyCode[name]
    local ok,err=pcall(function() virtual:SendKeyEvent(true,held_key,false,game) end)
    assert(ok,tostring(err)); input_release_at=os.clock()+.12
end
local collision={}; local physics={}; local current_root; local current_humanoid; local original_auto_rotate
local function restore_collision()
    for part,old in pairs(collision) do if part.Parent and part.CanCollide==false then pcall(function() part.CanCollide=old end) end end
    collision={}
end
local function halt()
    for _,object in pairs(physics) do if object and object.Parent then object:Destroy() end end
    physics={}
    if current_humanoid and current_humanoid.Parent and current_humanoid.AutoRotate==false then pcall(function() current_humanoid.AutoRotate=original_auto_rotate end) end
    if current_root and current_root.Parent then pcall(function() current_root.AssemblyLinearVelocity=Vector3.new(0,0,0) end) end
    current_root=nil; current_humanoid=nil; original_auto_rotate=nil; restore_collision()
end
local next_collision_scan=0
local function move(character,root,goal,look,settings)
    if root~=current_root then
        halt(); current_root=root; current_humanoid=character:FindFirstChildOfClass("Humanoid")
        if current_humanoid then original_auto_rotate=current_humanoid.AutoRotate; current_humanoid.AutoRotate=false end
        physics.velocity=make("BodyVelocity",{Name="VantaFarmVelocity",MaxForce=Vector3.new(1000000,1000000,1000000),P=18000,Velocity=Vector3.new(0,0,0)},root)
        physics.facing=make("BodyGyro",{Name="VantaFarmFacing",MaxTorque=Vector3.new(1000000,1000000,1000000),P=14000,D=650,CFrame=root.CFrame},root)
    end
    local delta=goal-root.Position
    physics.velocity.Velocity=delta.Magnitude>.3 and delta.Unit*math.min(settings.speed,delta.Magnitude*7) or Vector3.new(0,0,0)
    if (look-root.Position).Magnitude>.05 then physics.facing.CFrame=CFrame.lookAt(root.Position,look) end
    if settings.noclip and os.clock()>=next_collision_scan then
        next_collision_scan=os.clock()+.4
        for _,part in ipairs(character:GetDescendants()) do if part:IsA("BasePart") then
            if collision[part]==nil then collision[part]=part.CanCollide end
            part.CanCollide=false
        end end
    end
end
local function character()
    local char=player.Character; local root=char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
    local hum=char and char:FindFirstChildOfClass("Humanoid")
    -- In the supplied capture Main.W is a Weld, not a weapon Value object.
    return char,root,hum,Core.path(char,{"Main","W"})~=nil
end
local function retry_button()
    local button=Core.path(parent,{"Interface","Rewards","Main","Info","Main","Buttons","Retry"})
    if not Core.visible(button) then return nil end
    local title=button:FindFirstChild("Title")
    if title and title.Text:upper():find("STARTING",1,true) then return nil end
    return button
end
local blade_next_scan=0; local blade_character; local blades={}
local function broken_blade(char)
    if char~=blade_character or os.clock()>=blade_next_scan then
        blade_character=char; blade_next_scan=os.clock()+1; blades={}
        local rig=char:FindFirstChild("Rig_"..player.Name)
        if rig then for _,obj in ipairs(rig:GetDescendants()) do if obj.Name:match("^Blade_") and obj:IsA("BasePart") then blades[#blades+1]=obj end end end
    end
    for _,blade in ipairs(blades) do if blade.Parent and blade:GetAttribute("Broken")==true then return true end end
    return false
end
local engine=Core.engine({now=os.clock,character=character,titans=function() return workspace:FindFirstChild("Titans") end,
    paused=function() return menu_open or not focused or Input:GetFocusedTextBox()~=nil end,
    move=move,halt=halt,restore_collision=restore_collision,release=release_input,key=key_press,broken_blade=broken_blade,retry_button=retry_button,
    click_button=function(b) click_at(b.AbsolutePosition.X+b.AbsoluteSize.X/2,b.AbsolutePosition.Y+b.AbsoluteSize.Y/2) end,
    attack=function()
        local camera=workspace.CurrentCamera; assert(camera and virtual,"Mouse input simulation unavailable")
        if mouse_down then return end
        mouse_x=camera.ViewportSize.X/2; mouse_y=camera.ViewportSize.Y/2; mouse_down=true
        virtual:SendMouseButtonEvent(mouse_x,mouse_y,0,true,game,0); input_release_at=os.clock()+.12
    end,
    error=function(err) warn("Vanta AOTR: "..tostring(err)) end})
local gui=make("ScreenGui",{Name="VantaAOTR",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=120,ZIndexBehavior=Enum.ZIndexBehavior.Sibling},parent)
local canvas=make("Frame",{Name="Canvas",Size=UDim2.fromScale(1,1),BackgroundTransparency=1,BorderSizePixel=0},gui)
local window=make("Frame",{Name="Window",AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.fromOffset(980,680),BackgroundColor3=theme.base,BorderSizePixel=0,ZIndex=20},canvas); round(window,7)
make("UIStroke",{Color=theme.line,Thickness=1},window)
local scale=make("UIScale",{Scale=1},window)
local function label(p,value,x,y,w,h,size,color)
    return make("TextLabel",{Text=value,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),BackgroundTransparency=1,TextColor3=color or theme.text,
        TextSize=size or 14,Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,ZIndex=24},p)
end
local function button(p,value,fn)
    local b=make("TextButton",{Text=value,BackgroundColor3=theme.input,TextColor3=theme.text,Font=Enum.Font.GothamMedium,TextSize=13,AutoButtonColor=false,BorderSizePixel=0,ZIndex=25},p); round(b,5)
    connect(b.Activated,fn); connect(b.MouseEnter,function() b.BackgroundColor3=theme.selected end); connect(b.MouseLeave,function() b.BackgroundColor3=theme.input end); return b
end
label(window,"VANTA",24,13,170,29,23).Font=Enum.Font.GothamBold
label(window,"●  TITAN REVOLUTION",25,44,220,18,11,theme.accent)
make("Frame",{Position=UDim2.fromOffset(0,74),Size=UDim2.new(1,0,0,1),BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=21},window)
local rail=make("Frame",{Position=UDim2.fromOffset(0,75),Size=UDim2.new(0,176,1,-75),BackgroundColor3=theme.rail,BorderSizePixel=0,ZIndex=21},window)
local rail_line=make("Frame",{Position=UDim2.fromOffset(176,75),Size=UDim2.new(0,1,1,-75),BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=22},window)
local heading=label(window,"Farm",202,88,500,30,21); heading.Font=Enum.Font.GothamBold
local search=make("TextBox",{Name="VantaSearch",Text="",PlaceholderText="Find a control...",ClearTextOnFocus=false,Position=UDim2.new(1,-280,0,23),Size=UDim2.fromOffset(192,27),BackgroundColor3=theme.input,TextColor3=theme.text,PlaceholderColor3=theme.muted,TextSize=13,Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left,BorderSizePixel=0,ZIndex=25},window); round(search,7)
make("UIPadding",{PaddingLeft=UDim.new(0,12)},search)
local content=make("ScrollingFrame",{Name="Controls",Position=UDim2.fromOffset(202,132),Size=UDim2.new(1,-220,1,-196),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=theme.accent,CanvasSize=UDim2.new(),ZIndex=22},window)
local group=make("Frame",{Name="VantaGroup",Size=UDim2.new(1,-6,0,52),BackgroundColor3=theme.panel,BorderSizePixel=0,ZIndex=23},content); round(group,9)
make("UIStroke",{Color=theme.line,Transparency=.35,Thickness=1},group)
local group_title=label(group,"Farm  −",14,0,500,44,18); group_title.Font=Enum.Font.GothamMedium
make("Frame",{Position=UDim2.fromOffset(14,44),Size=UDim2.new(1,-28,0,1),BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=24},group)
local footer=make("Frame",{BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=21},window)
local status=label(window,"Ready",202,630,440,32,12,theme.muted); status.Name="Status"
local build=label(window,"BUILD 2026.11.06.17",0,0,140,18,10,theme.muted); build.Font=Enum.Font.RobotoMono
local live=label(canvas,"",136,10,700,32,13); live.Name="LiveStatus"
local open=button(canvas,"Vanta AOTR",function() menu_open=not menu_open; window.Visible=menu_open end); open.Position=UDim2.fromOffset(20,10); open.Size=UDim2.fromOffset(104,32)
local rows,nav,refreshers={},{},{}; local section="Farm"
local function layout_rows()
    local query=search.Text:lower(); local title=query~="" and "Search" or section
    heading.Text=title; group_title.Text=title.."  −"; local y=52
    for _,item in ipairs(rows) do
        item.frame.Visible=query~="" and item.caption:lower():find(query,1,true)~=nil or query=="" and item.section==section
        if item.frame.Visible then item.frame.Position=UDim2.fromOffset(0,y); y=y+item.height end
    end
    group.Size=UDim2.new(1,-6,0,y+8); group_title.Size=UDim2.new(1,-28,0,44); content.CanvasSize=UDim2.fromOffset(0,y+16)
    for name,item in pairs(nav) do local selected=name==section; item.b.BackgroundColor3=selected and theme.selected or theme.rail; item.caption.TextColor3=selected and theme.accent or theme.muted; item.mark.Visible=selected end
end
local function refresh() for _,fn in ipairs(refreshers) do fn() end end
local function apply(key,value)
    local ok,err=pcall(function() engine:set(key,value) end)
    if not ok then engine.message=tostring(err) end; refresh()
end
local function row(category,caption,height,description)
    local f=make("Frame",{Name="Control_"..caption,Size=UDim2.new(1,-6,0,height),BackgroundTransparency=1,BorderSizePixel=0,ZIndex=24},group)
    local title=label(f,caption,12,6,420,28,14); title.Size=UDim2.new(1,-122,0,28)
    if description then local text=label(f,description,12,33,500,18,11,theme.muted); text.Size=UDim2.new(1,-26,0,18) end
    make("Frame",{Position=UDim2.new(0,12,1,-1),Size=UDim2.new(1,-24,0,1),BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=24},f)
    rows[#rows+1]={frame=f,section=category,caption=caption,height=height}; return f
end
local function toggle(category,caption,key,description)
    local r=row(category,caption,description and 64 or 52,description)
    local b=button(r,"",function() apply(key,not engine.config[key]) end); b.Name="Toggle_"..key; b.Size=UDim2.fromOffset(44,22); b.Position=UDim2.new(1,-60,0,13); round(b,12)
    local knob=make("Frame",{Size=UDim2.fromOffset(16,16),Position=UDim2.fromOffset(3,3),BackgroundColor3=theme.text,BorderSizePixel=0,ZIndex=26},b); round(knob,9)
    refreshers[#refreshers+1]=function() b.BackgroundColor3=engine.config[key] and theme.accent or theme.line; knob.Position=UDim2.fromOffset(engine.config[key] and 25 or 3,3) end
end
local function field(category,caption,key,lo,hi,precision)
    local r=row(category,caption,82)
    local box=make("TextBox",{Name="Field_"..key,Size=UDim2.fromOffset(86,26),Position=UDim2.new(1,-102,0,8),BackgroundColor3=theme.input,TextColor3=theme.text,Font=Enum.Font.RobotoMono,TextSize=13,ClearTextOnFocus=false,BorderSizePixel=0,ZIndex=26},r); round(box,5)
    local slider=button(r,"",function() end); slider.Name="Slider_"..key; slider.Position=UDim2.fromOffset(14,50); slider.Size=UDim2.new(1,-30,0,20); slider.BackgroundTransparency=1
    local track=make("Frame",{Position=UDim2.fromOffset(0,8),Size=UDim2.new(1,0,0,4),BackgroundColor3=theme.line,BorderSizePixel=0,ZIndex=25},slider); round(track,2)
    local fill=make("Frame",{BackgroundColor3=theme.accent,BorderSizePixel=0,ZIndex=26},track); round(fill,2)
    local dot=make("Frame",{AnchorPoint=Vector2.new(.5,.5),Size=UDim2.fromOffset(12,12),BackgroundColor3=theme.text,BorderSizePixel=0,ZIndex=27},track); round(dot,7)
    refreshers[#refreshers+1]=function() box.Text=tostring(engine.config[key]); local amount=(engine.config[key]-lo)/(hi-lo); fill.Size=UDim2.fromScale(amount,1); dot.Position=UDim2.new(amount,0,.5,0) end
    connect(box.FocusLost,function() apply(key,box.Text) end)
    local dragging
    local function change(position) if slider.AbsoluteSize.X<=0 then return end; local a=math.max(0,math.min(1,(position.X-slider.AbsolutePosition.X)/slider.AbsoluteSize.X)); local n=lo+(hi-lo)*a; local p=precision or 1; apply(key,math.floor(n/p+.5)*p) end
    connect(slider.InputBegan,function(event) if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch then dragging=event; change(event.Position) end end)
    connect(Input.InputChanged,function(event) if dragging and (event==dragging or event.UserInputType==Enum.UserInputType.MouseMovement) then change(event.Position) end end)
    connect(Input.InputEnded,function(event) if event==dragging or event.UserInputType==Enum.UserInputType.MouseButton1 then dragging=nil end end)
end
toggle("Farm","Auto farm","farm","Close the menu with RightShift to begin movement")
toggle("Farm","Keep collisions off while farming","noclip","Original collision settings restore when farming stops")
toggle("Farm","Follow marked boss weakpoint","bossWeakpoint")
field("Farm","Travel speed / studs per second","speed",30,220)
field("Farm","Search range / studs","range",100,12000)
field("Farm","Nape approach distance","distance",3,16)
field("Farm","Nape height offset","height",-5,12)
toggle("Combat","Auto attack","attack","Uses the game's normal mouse attack input")
toggle("Combat","Aim camera at weakpoint","aim")
toggle("Combat","Reload broken blades","reload","Reloads when a blade reports its Broken attribute")
field("Combat","Attack interval / seconds","attackInterval",.25,2,.05)
toggle("Farm","Retry completed mission","retry","Requires the visible mission-reward Retry button")
toggle("Visuals","Titan outlines","esp")
local statistics=row("Settings","Session",118)
local stats=label(statistics,"",12,36,600,70,12,theme.muted); stats.Size=UDim2.new(1,-24,0,70); stats.TextWrapped=true
local keyrow=row("Settings","Reload key",52)
local keybox=make("TextBox",{Name="ReloadKey",Position=UDim2.new(1,-102,0,8),Size=UDim2.fromOffset(86,26),Text="R",ClearTextOnFocus=false,BackgroundColor3=theme.input,TextColor3=theme.text,TextSize=13,Font=Enum.Font.RobotoMono,BorderSizePixel=0,ZIndex=26},keyrow); round(keybox,5)
connect(keybox.FocusLost,function() apply("reloadKey",keybox.Text:upper()); keybox.Text=engine.config.reloadKey end)
local diagnostic=row("Settings","Mission diagnostics",60)
local inspect=button(diagnostic,"Save",function()
    local ok,err=pcall(function()
        assert(type(writefile)=="function","Executor file access unavailable")
        local char,root,hum,gear=character()
        local titan_container=workspace:FindFirstChild("Titans")
        local data={version="1.0",placeId=game.PlaceId,gameId=game.GameId,phase=engine.phase,error=engine.lastError,gear=gear,root=root~=nil,health=hum and hum.Health,
            titans=titan_container and #titan_container:GetChildren() or 0,bladeParts=#blades,input=virtual~=nil,config=engine.config}
        writefile("vanta_aotr_runtime.json",game:GetService("HttpService"):JSONEncode(data))
    end)
    engine.message=ok and "Saved vanta_aotr_runtime.json" or tostring(err)
end); inspect.Size=UDim2.fromOffset(86,26); inspect.Position=UDim2.new(1,-102,0,10)
local control={Version="1.0",Engine=engine}
local highlights={}
function control:Unload()
    if not alive then return end; alive=false; engine:close(); release_input(); halt()
    Run:UnbindFromRenderStep("VantaAOTR.Camera")
    for _,link in ipairs(connections) do link:Disconnect() end; connections={}
    for _,h in pairs(highlights) do h:Destroy() end; highlights={}; gui:Destroy()
end
function control:Set(key,value) engine:set(key,value); refresh() end
function control:GetStatus() return {version=self.Version,alive=alive,phase=engine.phase,message=engine.message,target=engine.target and engine.target.model.Name,swings=engine.swings,observedDefeats=engine.eliminations,error=engine.lastError} end
local close=button(window,"X",function() control:Unload() end); close.Size=UDim2.fromOffset(24,26); close.Position=UDim2.new(1,-40,0,24)
local restore; restore=button(canvas,"Vanta  ·  Restore",function() menu_open=true; window.Visible=true; restore.Visible=false end); restore.Name="Restore"; restore.Position=UDim2.fromOffset(20,50); restore.Size=UDim2.fromOffset(164,34); restore.Visible=false
local minimize=button(window,"−",function() menu_open=false; window.Visible=false; restore.Visible=true end); minimize.Name="Minimize"; minimize.Position=UDim2.new(1,-72,0,24); minimize.Size=UDim2.fromOffset(24,26)
local stop=button(window,"Stop all  ·  F8",function() engine:stop(); refresh() end); stop.Size=UDim2.fromOffset(96,28); stop.Position=UDim2.new(1,-116,1,-39)
for index,name in ipairs({"Farm","Combat","Visuals","Settings"}) do
    local b=button(window,"",function() search.Text=""; section=name; content.CanvasPosition=Vector2.new(0,0); layout_rows() end); b.Name="Tab_"..name
    local symbol=label(b,index==1 and "◎" or index==2 and "⊕" or index==3 and "▦" or "☷",10,0,24,38,19,theme.muted)
    local text=label(b,name,40,0,112,38,13,theme.muted)
    local mark=make("Frame",{Size=UDim2.fromOffset(3,22),Position=UDim2.fromOffset(-4,8),BackgroundColor3=theme.accent,BorderSizePixel=0,ZIndex=26},b)
    nav[name]={b=b,caption=text,mark=mark,symbol=symbol,index=index}
end
connect(search:GetPropertyChangedSignal("Text"),layout_rows)
local drag,drag_origin; local saved_position
local handle=make("Frame",{Name="DragHandle",Size=UDim2.new(1,-300,0,74),BackgroundTransparency=1,Active=true,ZIndex=23},window)
connect(handle.InputBegan,function(event) if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch then drag=event.Position; drag_origin=window.Position end end)
connect(Input.InputChanged,function(event) if drag and (event.UserInputType==Enum.UserInputType.MouseMovement or event.UserInputType==Enum.UserInputType.Touch) then local cam=workspace.CurrentCamera; if cam then local v=cam.ViewportSize; local d=event.Position-drag; saved_position=Vector2.new(drag_origin.X.Scale*v.X+drag_origin.X.Offset+d.X,drag_origin.Y.Scale*v.Y+drag_origin.Y.Offset+d.Y) end end end)
connect(Input.InputEnded,function(event) if event.UserInputType==Enum.UserInputType.MouseButton1 or event.UserInputType==Enum.UserInputType.Touch then drag=nil end end)
connect(Input.InputBegan,function(event,processed)
    if event.KeyCode==Enum.KeyCode.F8 then engine:stop(); refresh()
    elseif event.KeyCode==Enum.KeyCode.Delete then control:Unload()
    elseif event.KeyCode==Enum.KeyCode.RightShift and not processed and not Input:GetFocusedTextBox() then menu_open=not menu_open; window.Visible=menu_open; if menu_open then restore.Visible=false end end
end)
connect(Input.WindowFocusReleased,function() focused=false; release_input(); halt() end)
if Input.WindowFocused then connect(Input.WindowFocused,function() focused=true end) end
local esp_elapsed,ui_elapsed=1,1
local function fit()
    local cam=workspace.CurrentCamera; if not cam then return end
    local v=cam.ViewportSize; local w=math.max(340,math.min(980,v.X-24)); local h=math.max(430,math.min(680,v.Y-32))
    scale.Scale=math.min(1,(v.X-12)/w,(v.Y-12)/h); window.Size=UDim2.fromOffset(w,h)
    if saved_position then local hw=w*scale.Scale/2; local hh=h*scale.Scale/2; saved_position=Vector2.new(math.max(hw+6,math.min(v.X-hw-6,saved_position.X)),math.max(hh+6,math.min(v.Y-hh-6,saved_position.Y))); window.Position=UDim2.fromOffset(saved_position.X,saved_position.Y) end
    local wide=w>=600; local left=wide and 202 or 18; local top=wide and 132 or 174
    rail.Visible=wide; rail_line.Visible=wide; heading.Visible=wide; search.Visible=wide
    content.Position=UDim2.fromOffset(left,top); content.Size=UDim2.new(1,-left-18,1,-top-64)
    footer.Position=UDim2.new(0,left,1,-49); footer.Size=UDim2.new(1,-left-18,0,1)
    status.Position=UDim2.new(0,left,1,-42); status.Size=UDim2.new(1,-left-(wide and 276 or 124),0,32)
    build.Visible=wide; build.Position=UDim2.new(1,-256,1,-31)
    open.Visible=not menu_open; live.Visible=not menu_open; live.Size=UDim2.fromOffset(math.max(120,v.X-148),32)
    for _,item in pairs(nav) do
        local i=item.index-1; item.b.Position=wide and UDim2.fromOffset(10,90+i*43) or UDim2.fromOffset(18+i*(w-36)/4,98)
        item.b.Size=wide and UDim2.fromOffset(156,38) or UDim2.fromOffset((w-36)/4-3,30)
        item.symbol.Visible=wide; item.caption.Position=UDim2.fromOffset(wide and 40 or 0,0); item.caption.Size=UDim2.new(1,wide and -44 or 0,1,0); item.caption.TextSize=wide and 13 or 11
    end
end
local function update_esp()
    local container=workspace:FindFirstChild("Titans"); local kept={}; local count=0
    if engine.config.esp and container then for _,titan in ipairs(container:GetChildren()) do
        local hum=titan:FindFirstChildOfClass("Humanoid")
        if titan:IsA("Model") and hum and hum.Health>0 and count<64 then
            local h=highlights[titan]
            if not h then h=make("Highlight",{Name="VantaTitanOutline",Adornee=titan,FillTransparency=1,OutlineColor=theme.accent,OutlineTransparency=.1,DepthMode=Enum.HighlightDepthMode.Occluded},titan); highlights[titan]=h end
            kept[titan]=true; count=count+1
        end
    end end
    for titan,h in pairs(highlights) do if not kept[titan] then h:Destroy(); highlights[titan]=nil end end
end
connect(Run.Heartbeat,function(dt)
    if not alive then return end
    if input_release_at and os.clock()>=input_release_at then release_input() end
    engine:tick(dt); ui_elapsed=ui_elapsed+dt; esp_elapsed=esp_elapsed+dt
    if ui_elapsed>=.1 then ui_elapsed=0; fit(); status.Text=engine.phase.." · "..engine.message; live.Text=status.Text
        stats.Text="Attack inputs: "..engine.swings.."   Observed defeats: "..engine.eliminations.."\nReload requests: "..engine.reloads.."   Retry requests: "..engine.retries.."\nInput backend: "..(virtual and "Virtual input" or "Unavailable"); refresh()
    end
    if esp_elapsed>=.5 then esp_elapsed=0; update_esp() end
end)
Run:BindToRenderStep("VantaAOTR.Camera",Enum.RenderPriority.Last.Value+1,function()
    if not alive or not engine.config.farm or not engine.config.aim or menu_open or not focused or Input:GetFocusedTextBox() then return end
    local target=engine.target; local camera=workspace.CurrentCamera
    if target and target.part.Parent and target.humanoid.Health>0 and camera and (target.part.Position-camera.CFrame.Position).Magnitude>.05 then
        camera.CFrame=CFrame.lookAt(camera.CFrame.Position,target.part.Position)
    end
end)
local unload=make("BindableEvent",{Name="Unload"},gui); connect(unload.Event,function() control:Unload() end)
connect(gui.Destroying,function() control:Unload() end)
refresh(); layout_rows(); fit()
print("Vanta AOTR 1.0 loaded · enable Auto farm in a mission · RightShift menu · F8 stop · Delete unload")
return control
