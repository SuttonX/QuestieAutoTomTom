local frame = CreateFrame('Frame')
local status
local owned = {}
local displayNames = {}
local arrowWrapped = false
local activeArrow
local manualWaypoint
local resumeAuto = false
local liveQuests
local mapToCZ
local cache, signature, modules = {}, nil, nil
local dirty, force, due, clock, movementClock = true, true, 5, 0, 0
local installedHooks = false
status = 'Waiting for Questie and TomTom'

local function Print(text)
    DEFAULT_CHAT_FRAME:AddMessage('|cff54e33bQuestie Auto TomTom:|r ' .. text)
end
local function Remove(entry)
    if entry and TomTom and TomTom.RemoveWaypoint then
        if activeArrow == entry.uid and TomTom.SetCrazyArrow then
            pcall(TomTom.SetCrazyArrow, TomTom, nil, 15, nil)
        end
        pcall(TomTom.RemoveWaypoint, TomTom, entry.uid)
        displayNames[entry.uid] = nil
    end
end
local function Clear()
    for _, entry in pairs(owned) do Remove(entry) end
    owned = {}
end
local function Mark(rebuild)
    if not dirty then due = clock + 0.4 end
    dirty = true
    force = force or rebuild
end
local function Module(name)
    if not QuestieLoader or not QuestieLoader.ImportModule then return end
    local ok, value = pcall(QuestieLoader.ImportModule, QuestieLoader, name)
    if ok then return value end
end
local function InstallTomTomHooks()
    if arrowWrapped or not TomTom or not TomTom.SetCrazyArrow then return end
    local original = TomTom.SetCrazyArrow
    TomTom.SetCrazyArrow = function(self, waypoint, distance, title, ...)
        activeArrow = waypoint
        if waypoint and not displayNames[waypoint] then
            manualWaypoint = waypoint
        end
        return original(self, waypoint, distance, displayNames[waypoint] or title, ...)
    end
    if hooksecurefunc and TomTom.RemoveWaypoint then
        hooksecurefunc(TomTom, 'RemoveWaypoint', function(self, waypoint)
            if waypoint and waypoint == manualWaypoint then
                manualWaypoint = nil
                Mark(true)
            end
        end)
    end
    arrowWrapped = true
end
local function Ready()
    if not Questie or not Questie.db or not Questie.db.profile or not Questie.db.char
        or not TomTom or not TomTom.AddZWaypoint or not TomTom.SetCrazyArrow
        or not TomTom.SetClosestWaypoint or not TomTom.GetClosestWaypoint
        or not QuestieCompat or not QuestieCompat.TomTom_AddWaypoint
        or not QuestieCompat.HBD then return false end
    InstallTomTomHooks()
    if not modules then
        local p, d, z = Module('QuestiePlayer'), Module('QuestieMap'), Module('ZoneDB')
        if not p or not p.currentQuestlog or not d or not z then return false end
        modules = {player=p, map=d, zones=z, hbd=QuestieCompat.HBD}
    end
    if not installedHooks and hooksecurefunc then
        local tracker = Module('QuestieTracker')
        if tracker and type(tracker.Update) == 'function' then
            -- Includes Questie's own track/untrack and settings changes.
            hooksecurefunc(tracker, 'Update', function() Mark(false) end)
            installedHooks = true
        end
    end
    return true
end
local function Tracked(id)
    if liveQuests and not liveQuests[id] then return false end
    local profile, char = Questie.db.profile, Questie.db.char
    if profile.autoTrackQuests then return not (char.AutoUntrackedQuests or {})[id] end
    return (char.TrackedQuests or {})[id]
end
local function ObjectiveDone(o)
    return o.Completed or o.IsComplete == true or
        (type(o.Needed) == 'number' and type(o.Collected) == 'number' and o.Collected >= o.Needed)
end
-- This inexpensive signature avoids rebuilding location data for duplicate
-- QUEST_LOG_UPDATE events or unrelated tracker redraws.
local function Signature()
    local entries = {}
    for id, q in pairs(modules.player.currentQuestlog) do
        if type(q) == 'table' and Tracked(id) then
            local parts = {tostring(id), tostring(q:IsComplete())}
            for _, group in ipairs({q.Objectives or {}, q.SpecialObjectives or {}}) do
                local objectives = {}
                for k, o in pairs(group) do
                    objectives[#objectives+1] = tostring(k) .. ':' .. tostring(o.Collected) .. ':' ..
                        tostring(o.Needed) .. ':' .. tostring(ObjectiveDone(o)) .. ':' .. tostring(o.spawnList)
                end
                table.sort(objectives)
                parts[#parts+1] = table.concat(objectives, ',')
            end
            entries[#entries+1] = table.concat(parts, '|')
        end
    end
    table.sort(entries)
    return table.concat(entries, ';')
end
-- Build the legacy continent/zone lookup once; preserve the user's map view.
local function BuildMapLookup()
    local previous, level = GetCurrentMapAreaID(), GetCurrentMapDungeonLevel()
    local result = {}
    local ok, err = pcall(function()
        for c in ipairs({GetMapContinents()}) do
            for z in ipairs({GetMapZones(c)}) do
                SetMapZoom(c, z)
                result[GetCurrentMapAreaID()] = {c,z}
            end
        end
    end)
    if previous and previous > 0 then SetMapByID(previous) else SetMapToCurrentZone() end
    if level and level > 0 and SetDungeonMapLevel then SetDungeonMapLevel(level) end
    if not ok then error(err) end
    mapToCZ = result
end
local function Rebuild()
    local nextCache, seen = {}, {}
    local function Add(id, objective, spawn, zone, name, distance)
        if not spawn or not zone then return end
        local uiMap = modules.zones:GetUiMapIdByAreaId(zone)
        local data = uiMap and QuestieCompat.UiMapData[uiMap]
        local cz = data and mapToCZ[data.mapID]
        if not cz then return end
        local x,y = spawn[1],spawn[2]
        if type(x) ~= 'number' or type(y) ~= 'number' or x < 0 or x > 100 or y < 0 or y > 100 then return end
        if type(distance) ~= 'number' or distance >= 500000 then return end
        -- One location per unfinished objective, not every possible mob spawn.
        local key = tostring(id)..':'..tostring(objective)..':'..tostring(zone)..':'..tostring(x)..':'..tostring(y)
        if seen[key] then return end
        seen[key] = true
        nextCache[#nextCache+1] = {key=key, c=cz[1], z=cz[2], x=x,y=y,distance=distance,
            name='[QAT '..tostring(id)..'] '..tostring(name or 'Quest objective'),
            displayName=tostring(name or 'Quest objective')}
    end
    for id,q in pairs(modules.player.currentQuestlog) do
        if type(q) == 'table' and Tracked(id) then
            if q:IsComplete() == 1 then
                local spawn,zone,name,kind,distance = modules.map:GetNearestQuestSpawn(q)
                Add(id,'turnin',spawn,zone,name,distance)
            else
                for groupIndex,group in ipairs({q.Objectives or {},q.SpecialObjectives or {}}) do
                    for index,o in pairs(group) do
                        if not ObjectiveDone(o) then
                            local spawn,zone,name,spawnID,kind,distance = modules.map:GetNearestSpawn(o)
                            Add(id,tostring(groupIndex)..':'..tostring(index),spawn,zone,name,distance)
                        end
                    end
                end
            end
        end
    end
    table.sort(nextCache,function(a,b) return a.key < b.key end)
    cache = nextCache
end
local function AddWaypoint(c)
    local persistence = TomTom.profile and TomTom.profile.persistence
    local arrow = TomTom.profile and TomTom.profile.arrow
    if not persistence or not arrow then return nil end
    -- Legacy TomTom injects arrival deletion even into custom callbacks.
    -- Suppress it for this synchronous creation only, then restore immediately.
    local oldClear,oldArrival = persistence.cleardistance,arrow.arrival
    persistence.cleardistance,arrow.arrival = 0,0
    local ok,result = pcall(TomTom.AddZWaypoint,TomTom,c.c,c.z,c.x,c.y,c.name,
        false,false,false,{distance={}},true,false)
    persistence.cleardistance,arrow.arrival = oldClear,oldArrival
    if ok then return result end
    error(result)
end
local function Sync()
    local wanted, changed, fallback, count = {},false,nil,0
    for i=1,#cache do wanted[cache[i].key] = true end
    for key,entry in pairs(owned) do
        if not wanted[key] then Remove(entry);owned[key]=nil;changed=true end
    end
    for i=1,#cache do
        local c = cache[i]
        if not owned[c.key] then
            local newUID = AddWaypoint(c)
            if not newUID then error('TomTom could not create an objective waypoint') end
            owned[c.key] = {uid=newUID,name=c.name,distance=c.distance}
            displayNames[newUID] = c.displayName
            changed = true
        end
        count = count+1
        if not fallback or c.distance < fallback.distance then
            fallback = {uid=owned[c.key].uid,name=c.name,distance=c.distance}
        end
    end
    -- Legacy TomTom selects the closest waypoint in the current zone only.
    -- If none exists there, use Questie's nearest destination from this refresh.
    if manualWaypoint and TomTom.IsValidWaypoint and not TomTom:IsValidWaypoint(manualWaypoint) then
        manualWaypoint = nil
    end
    if manualWaypoint then
        status = 'Manual target takes priority; '..tostring(count)..' quest waypoints synced'
        return
    end
    if changed or force then
        if resumeAuto and fallback then
            TomTom:SetCrazyArrow(fallback.uid,TomTom.profile.arrow.arrival,fallback.name)
        elseif TomTom:GetClosestWaypoint() then TomTom:SetClosestWaypoint()
        elseif fallback then TomTom:SetCrazyArrow(fallback.uid,TomTom.profile.arrow.arrival,fallback.name) end
    end
    resumeAuto = false
    status = tostring(count)..' objective/turn-in waypoints synced'
end
local function Tick()
    if not QuestieAutoTomTomDB or not QuestieAutoTomTomDB.enabled or not dirty or clock < due then return end
    if not Ready() then status='Waiting for Questie 3.3.5 and TomTom';due=clock+2;return end
    if WorldMapFrame and WorldMapFrame:IsShown() then return end
    if not mapToCZ then BuildMapLookup() end
    -- Blizzard's quest log is authoritative for abandoned quests; Questie's
    -- currentQuestlog can retain a removed entry until its queued update runs.
    if GetNumQuestLogEntries and GetQuestLogTitle then
        liveQuests = {}
        for index=1,GetNumQuestLogEntries() do
            local _,_,_,_,header,_,_,_,id = GetQuestLogTitle(index)
            if not header and id and id > 0 then liveQuests[id] = true end
        end
    end
    local newSignature = Signature()
    if force or signature ~= newSignature then
        Rebuild()
        Sync()
        signature = newSignature
    end
    dirty,force = false,false
end
for _, event in ipairs({'PLAYER_LOGIN','PLAYER_LOGOUT','PLAYER_ENTERING_WORLD',
    'QUEST_LOG_UPDATE','UNIT_QUEST_LOG_CHANGED','QUEST_ACCEPTED','QUEST_REMOVED',
    'QUEST_TURNED_IN','ADDON_LOADED','ZONE_CHANGED_NEW_AREA','ZONE_CHANGED','ZONE_CHANGED_INDOORS'}) do
    -- Some later quest events are not exposed by every 3.3.5 client.
    pcall(frame.RegisterEvent, frame, event)
end
frame:SetScript('OnEvent', function(self, event, unit)
    InstallTomTomHooks()
    if event == 'PLAYER_LOGIN' then
        QuestieAutoTomTomDB = QuestieAutoTomTomDB or {}
        if QuestieAutoTomTomDB.enabled == nil then QuestieAutoTomTomDB.enabled = true end
        dirty, force, due = true, true, clock+5
    elseif event == 'PLAYER_LOGOUT' then Clear()
    elseif event == 'UNIT_QUEST_LOG_CHANGED' then
        if unit == 'player' then Mark(false) end
    else Mark(event ~= 'QUEST_LOG_UPDATE') end
end)
frame:SetScript('OnUpdate', function(self, delta)
    clock, movementClock = clock+delta, movementClock+delta
    if movementClock < 0.5 then return end
    movementClock = 0
    local ok, err = pcall(Tick)
    if not ok then status = 'Update failed: ' .. tostring(err); dirty, force, due = true, true, clock+3 end
end)
SLASH_QUESTIEAUTOTOMTOM1 = '/qat'
SlashCmdList.QUESTIEAUTOTOMTOM = function(message)
    local command = string.lower((message or ''):match('^%s*(.-)%s*$'))
    QuestieAutoTomTomDB = QuestieAutoTomTomDB or {enabled=true}
    if command == 'off' then QuestieAutoTomTomDB.enabled=false; Clear(); Print('Disabled.')
    elseif command == 'on' then
        QuestieAutoTomTomDB.enabled=true; Mark(true); Print('Enabled.')
    elseif command == 'auto' then
        manualWaypoint = nil; resumeAuto = true; Mark(true); Print('Automatic quest targeting resumed.')
    elseif command == 'refresh' then Clear(); Mark(true)
    else
        Print((QuestieAutoTomTomDB.enabled and 'Enabled. ' or 'Disabled. ') .. status)
        Print('/qat on | off | refresh | auto')
    end
end

InstallTomTomHooks()
