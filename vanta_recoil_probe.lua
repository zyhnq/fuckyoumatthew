-- Vanta Urban: read-only recoil diagnosis. No requires, hooks, remotes or inputs.
local player=assert(game:GetService("Players").LocalPlayer,"Run on the client")
local http=game:GetService("HttpService")
assert(type(writefile)=="function","This capture needs executor writefile support")
local output="vanta_urban_recoil_probe.json"
local report={version=1,placeId=game.PlaceId,gameId=game.GameId,capabilities={},errors={},modules={},tables={},functions={},samples={}}
local constants_api=(debug and debug.getconstants) or getconstants
local upvalues_api=(debug and debug.getupvalues) or getupvalues
for key,fn in pairs({getgc=getgc,getloadedmodules=getloadedmodules,decompile=decompile,constants=constants_api,upvalues=upvalues_api}) do report.capabilities[key]=type(fn)=="function" end
local function safe_path(obj)
    local ok,path=pcall(function() return obj:GetFullName() end)
    return ok and path or nil
end
local function relevant(key)
    if type(key)~="string" then return false end
    local s=key:lower()
    return s:find("recoil",1,true) or s:find("kick",1,true) or s:find("spring",1,true) or s:find("bloom",1,true) or s:find("spread",1,true) or s=="clientstate"
end
local function numeric(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function brief(value,depth,seen)
    local t=type(value)
    if t=="number" then return numeric(value) and value or tostring(value) end
    if t=="boolean" or t=="nil" then return value end
    if t=="string" then return value:sub(1,160) end
    if t=="function" then return "<function>" end
    if t~="table" then
        local path=safe_path(value); if path then return {type="Instance",path=path} end
        return tostring(value):sub(1,160)
    end
    if seen[value] then return "<cycle>" end
    if depth<=0 then return "<table>" end
    seen[value]=true; local result={}; local count=0
    for k,v in next,value do
        if (type(k)=="string" or type(k)=="number") and count<24 then result[tostring(k)]=brief(v,depth-1,seen); count=count+1 end
    end
    seen[value]=nil; return result
end
local function state_fields(object)
    local fields={}; local count=0
    for key,value in next,object do
        if relevant(key) and count<24 then fields[key]=brief(value,3,{}); count=count+1 end
    end
    return fields,count
end
local function key_list(object)
    local keys={}; for key in next,object do if #keys>=48 then break end; if type(key)=="string" or type(key)=="number" then keys[#keys+1]=tostring(key) end end
    table.sort(keys); return keys
end
local tracked={}; local seen_tables=setmetatable({},{__mode="k"}); local owned=setmetatable({},{__mode="k"})
local function mark_report(value)
    if type(value)~="table" or owned[value] then return end
    owned[value]=true; for _,item in next,value do mark_report(item) end
end
local function consider(object,origin)
    if type(object)~="table" or owned[object] or seen_tables[object] or #tracked>=96 then return end
    local fields,count=state_fields(object)
    if count>0 then
        seen_tables[object]=true; local id=#tracked+1; tracked[id]=object
        report.tables[id]={id=id,origin=origin,keys=key_list(object),fields=fields}
    end
end
local sources={}; local seen_modules={}
if type(getloadedmodules)=="function" then
    local ok,modules=pcall(getloadedmodules)
    if ok and type(modules)=="table" then
        for _,module in pairs(modules) do
            local path=safe_path(module)
            if path then
                local lower=path:lower()
                if lower:find("weapon",1,true) or lower:find("gun",1,true) or lower:find("recoil",1,true) or lower:find("clientstate",1,true) or lower:find("firearm",1,true) then
                    if #report.modules<120 then report.modules[#report.modules+1]=path end
                    local score=lower:find("clientstate",1,true) and 100 or lower:find("recoil",1,true) and 90 or lower:find("weapon",1,true) and 40 or 20
                    if not seen_modules[module] then seen_modules[module]=true; sources[#sources+1]={module=module,path=path,score=score} end
                end
            end
        end
    else report.errors[#report.errors+1]="getloadedmodules: "..tostring(modules) end
end
local function scan()
    -- Captured copies are diagnostic data, never new game-state candidates.
    -- Traverse again because report arrays acquire new items between scans.
    local visited={}
    local function protect(value)
        if type(value)~="table" or visited[value] then return end
        visited[value]=true; owned[value]=true; for _,item in next,value do protect(item) end
    end
    protect(report); owned[tracked]=true; owned[seen_tables]=true; owned[owned]=true
    if type(getgc)~="function" then report.errors[#report.errors+1]="getgc unavailable"; return end
    local ok,objects=pcall(function() return getgc(true) end)
    if not ok or type(objects)~="table" then report.errors[#report.errors+1]="getgc: "..tostring(objects); return end
    local checked=0; local functions_checked=0
    for _,object in pairs(objects) do
        if type(object)=="table" then consider(object,"getgc")
        elseif type(object)=="function" and #report.functions<48 and functions_checked<750 and type(constants_api)=="function" then
            functions_checked=functions_checked+1
            local good,constants=pcall(constants_api,object)
            if good and type(constants)=="table" then
                local matches={}
                for _,constant in pairs(constants) do if relevant(constant) and #matches<24 then matches[#matches+1]=constant:sub(1,160) end end
                if #matches>0 then
                    local entry={constants=matches}
                    if type(getfenv)=="function" then local env_ok,env=pcall(getfenv,object); if env_ok and type(env)=="table" then entry.script=safe_path(rawget(env,"script")) end end
                    if type(upvalues_api)=="function" then
                        local uv_ok,values=pcall(upvalues_api,object)
                        if uv_ok and type(values)=="table" then
                            entry.upvalues={}
                            for key,value in pairs(values) do
                                if type(value)=="table" then
                                    local fields,n=state_fields(value)
                                    if n>0 then entry.upvalues[tostring(key)]=fields; consider(value,"upvalue of "..(entry.script or "matched function")) end
                                end
                            end
                        end
                    end
                    report.functions[#report.functions+1]=entry
                end
            end
        end
        checked=checked+1; if checked%4000==0 then task.wait() end
    end
    report.lastScan={objects=checked,functionsChecked=functions_checked,tablesFound=#tracked}
end
local function sample()
    local s={time=os.clock(),tables={},tools={}}
    for id,object in ipairs(tracked) do s.tables[tostring(id)]=state_fields(object) end
    local character=player.Character
    if character then
        for _,child in ipairs(character:GetChildren()) do if child:IsA("Tool") then s.tools[#s.tools+1]=child.Name end end
    end
    report.samples[#report.samples+1]=s
end
print("Vanta capture started. Equip your gun and fire normally for 12 seconds.")
scan(); sample()
for i=1,6 do task.wait(2); if i==3 or i==6 then scan() end; sample() end
-- Read a small number of already-loaded modules; never require or execute them.
table.sort(sources,function(a,b) return a.score>b.score end)
report.sourceExcerpts={}
for i=1,math.min(8,#sources) do
    local entry=sources[i]; local ok,source=pcall(function() return entry.module.Source end)
    if (not ok or type(source)~="string" or #source<1) and type(decompile)=="function" then ok,source=pcall(decompile,entry.module) end
    if ok and type(source)=="string" then
        local lines={}; for line in (source.."\n"):gmatch("(.-)\n") do lines[#lines+1]=line end
        local excerpts={}; local last=-100; local chars=0
        for index,line in ipairs(lines) do
            if relevant(line) and index>last+3 and #excerpts<6 and chars<16000 then
                local chunk={}; for j=math.max(1,index-4),math.min(#lines,index+8) do chunk[#chunk+1]=lines[j]:sub(1,500) end
                local text=table.concat(chunk,"\n"); excerpts[#excerpts+1]={line=index,text=text}; chars=chars+#text; last=index+8
            end
        end
        report.sourceExcerpts[#report.sourceExcerpts+1]={path=entry.path,excerpts=excerpts}
    else report.sourceExcerpts[#report.sourceExcerpts+1]={path=entry.path,error=tostring(source):sub(1,160)} end
end
writefile(output,http:JSONEncode(report))
print("Saved "..output.." · tables "..#tracked.." · modules "..#report.modules)
