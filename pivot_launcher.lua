-- Pivot Launcher 1.0 | choose a game; only its matching module is downloaded.
local Players=game:GetService("Players")
local Input=game:GetService("UserInputService")
local player=assert(Players.LocalPlayer,"Run Pivot Launcher on the client")
local parent=player:WaitForChild("PlayerGui")
local prior=parent:FindFirstChild("PivotLauncher")
if prior then
    local unload=prior:FindFirstChild("Unload")
    if unload then unload:Fire() else prior:Destroy() end
end
local base="https://raw.githubusercontent.com/zyhnq/fuckyoumatthew/main/"
local games={
    {id="basketball",name="Practical Basketball",module="Pivot",file="pivot_hub.lua",universe=7529591378,place=80681221431821,description="Shooting, modules, outfits & court visuals",color=Color3.fromRGB(173,194,241)},
    {id="urban",name="Urban Reload",module="DeepHat",file="deephat_refined.lua",universe=10769552054,place=84448037861644,description="Aim settings, player ESP & visibility controls",color=Color3.fromRGB(149,217,194)}
}
local function matches(entry) return game.GameId==entry.universe or game.PlaceId==entry.place end
local detected="Unsupported game"
for _,entry in ipairs(games) do if matches(entry) then detected=entry.name end end
local links={}; local alive=true; local loading=false
local function connect(event,fn) local link=event:Connect(fn); links[#links+1]=link; return link end
local function make(class,props,p) local obj=Instance.new(class); for key,value in pairs(props) do obj[key]=value end; obj.Parent=p; return obj end
local function round(obj,r) make("UICorner",{CornerRadius=UDim.new(0,r)},obj) end
local gui=make("ScreenGui",{Name="PivotLauncher",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=150,ZIndexBehavior=Enum.ZIndexBehavior.Sibling},parent)
local panel=make("Frame",{Name="Window",AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.new(1,-32,0,384),BackgroundColor3=Color3.fromRGB(17,20,27),BorderSizePixel=0},gui)
make("UISizeConstraint",{MaxSize=Vector2.new(480,384),MinSize=Vector2.new(280,360)},panel); round(panel,14)
make("UIStroke",{Color=Color3.fromRGB(48,55,70),Thickness=1},panel)
local function label(p,name,value,x,y,w,h,size,color)
    return make("TextLabel",{Name=name,Text=value,Position=UDim2.fromOffset(x,y),Size=UDim2.new(1,w,0,h),BackgroundTransparency=1,Font=Enum.Font.SourceSans,TextSize=size,TextColor3=color or Color3.fromRGB(233,239,249),TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd},p)
end
label(panel,"Title","Pivot",22,17,-80,34,29).Font=Enum.Font.SourceSansBold
label(panel,"Subtitle","Choose your game",23,54,-46,22,16,Color3.fromRGB(152,165,186))
label(panel,"Detected","Detected: "..detected,23,84,-46,22,13,Color3.fromRGB(159,189,244))
local status=label(panel,"Status","Select a game to load its script.",23,333,-46,30,13,Color3.fromRGB(152,165,186))
local close=make("TextButton",{Name="Close",Text="×",Position=UDim2.new(1,-50,0,20),Size=UDim2.fromOffset(28,28),BackgroundColor3=Color3.fromRGB(27,32,43),TextColor3=Color3.fromRGB(184,197,218),Font=Enum.Font.SourceSans,TextSize=23,BorderSizePixel=0},panel); round(close,6)
local control={Version="1.0"}
function control:Unload()
    if not alive then return end
    alive=false
    for _,link in ipairs(links) do link:Disconnect() end
    links={}; gui:Destroy()
end
local function load_game(entry)
    if not alive or loading then return end
    if not matches(entry) then status.Text="Join "..entry.name..", then run this launcher."; return end
    loading=true; status.Text="Loading "..entry.name.."…"
    task.spawn(function()
        -- Fetch/compile first; network or syntax failures keep the chooser open.
        local ok,result=pcall(function()
            local source=game:HttpGet(base..entry.file)
            assert(type(source)=="string" and #source>100,"Empty script response")
            local run,err=loadstring(source,"@Pivot/"..entry.file)
            assert(run,err)
            if not alive then return nil end
            return run()
        end)
        if not alive then return end
        loading=false
        if ok then control:Unload()
        else status.Text="Load failed — click to retry."; warn("Pivot Launcher: "..tostring(result)) end
    end)
end
for i,entry in ipairs(games) do
    local ready=matches(entry)
    local card=make("TextButton",{Name="Game_"..entry.id,Text="",Position=UDim2.fromOffset(20,122+(i-1)*102),Size=UDim2.new(1,-40,0,90),BackgroundColor3=Color3.fromRGB(25,30,40),BorderSizePixel=0,AutoButtonColor=false},panel); round(card,9)
    make("UIStroke",{Color=ready and entry.color or Color3.fromRGB(45,52,67),Thickness=1,Transparency=ready and .3 or .5},card)
    local bar=make("Frame",{Position=UDim2.fromOffset(0,17),Size=UDim2.fromOffset(3,56),BackgroundColor3=entry.color,BorderSizePixel=0},card); round(bar,2)
    label(card,"GameName",entry.name,15,9,-30,25,20).Font=Enum.Font.SourceSansSemibold
    label(card,"Description",entry.description,15,35,-30,19,13,Color3.fromRGB(152,165,186))
    label(card,"Action",ready and "Load "..entry.module.."  →" or "Join game first",15,59,-30,20,14,ready and entry.color or Color3.fromRGB(112,125,147))
    connect(card.Activated,function() load_game(entry) end)
    connect(card.MouseEnter,function() card.BackgroundColor3=Color3.fromRGB(33,40,54) end)
    connect(card.MouseLeave,function() card.BackgroundColor3=Color3.fromRGB(25,30,40) end)
end
connect(close.Activated,function() control:Unload() end)
connect(Input.InputBegan,function(event,processed) if not processed and event.KeyCode==Enum.KeyCode.Escape and not loading then control:Unload() end end)
local unload=make("BindableEvent",{Name="Unload"},gui); connect(unload.Event,function() control:Unload() end)
connect(gui.Destroying,function() control:Unload() end)
return control
