------------ CONFIGURATION -----------
local LIMIT = 10					-- number of deaths to report per combat session (default: 10)
local OVERKILL = true				-- toggle overkill (default: true)
local RAID_ICONS = true				-- toggle raid icons (default: true)
local SHORT_NUMBERS = true			-- toggle short numbers [i.e. 9431 = 9.4k] (default: true)
local EVENT_HISTORY = 1				-- number of damage events to report per person (default: 1)

-- Chat Parameters
local maxMessagesSent             = 3     -- Max messages that can be send at once before getting muted by the server
local gracePeriodForSendMessages  = 1.3   -- Assuming that we can send at most 'maxMessagesSent' every 'gracePeriodForSendMessages' seconds
-- Chat Variables
local timeMessagesSent            = {}
local queuedMessages
local playersUnableToSpeak        = {}
local MAX_PRIORITY                = 1000000
local METAMORPHOSIS = 47241

local Fatality = CreateFrame("frame")
local status, death, unknown = "|cff39d7e5Fatality: %s|r", "Fatality: %s > %s", "Fatality: %s%s > Unknown"
local limit = "|cffffff00(%s) Report cannot be sent because it exceeds the maximum character limit of 255. To fix this, decrease EVENT_HISTORY in Fatality.lua and /reload your UI.|r"
local special = { ["SPELL_DAMAGE"] = true, ["SPELL_PERIODIC_DAMAGE"] = true, ["RANGE_DAMAGE"] = true }
local instances = {	["The Ruby Sanctum"] = true, ["The Obsidian Sanctum"] = true }
local spiritOfRedemption, candidates, units = GetSpellInfo(27827), {}, {}
local countMsgsSent, history = 0, 0
local unit_health, channel_id

local raid = {}
local raidOrdered = {}
local topPriority = true
local faDebug = false

-- Upvalues
local GetInstanceDifficulty, GetRaidRosterInfo = GetInstanceDifficulty, GetRaidRosterInfo
local UnitInRaid, UnitIsDead, UnitIsFeignDeath = UnitInRaid, UnitIsDead, UnitIsFeignDeath
local UnitClass, UnitGUID, UnitExists, UnitBuff = UnitClass, UnitGUID, UnitExists, UnitBuff
local GetTime, format, wipe, type, band = GetTime, string.format, wipe, type, bit.band

Fatality:SetScript("OnEvent", function(self, event, ...)
	self[event](self, ...)
end)

local rt, path = "{rt%d}", "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%d.blp:0|t"
local rt1, rtmask = COMBATLOG_OBJECT_RAIDTARGET1, COMBATLOG_OBJECT_SPECIAL_MASK

local function icon(flag)
	if not RAID_ICONS then return "" end
	local number, mask, mark
	if band(flag, rtmask) ~= 0 then
		for i=1,8 do
			mask = rt1 * (2 ^ (i - 1))
			mark = band(flag, mask) == mask
			if mark then number = i break end
		end
	end
	return number and (OUTPUT == "SELF" and format(path, number) or format(rt, number)) or ""
end

local function shorten(n)
	if not (SHORT_NUMBERS and type(n) == "number") then return n end
	if n >= 10000000 then
		return format("%.1fM", n/1000000)
	elseif n >= 1000000 then
		return format("%.2fM", n/1000000)
	elseif n >= 100000 then
		return format("%.fk", n/1000)
	elseif n >= 1000 then
		return format("%.1fk", n/1000)
	else
		return n
	end
end

local function color(name)
	if OUTPUT ~= "SELF" then return name end
	if not UnitExists(name) then return format("|cffff0000%s|r", name) end
	local _, class = UnitClass(name)
	local color = _G["RAID_CLASS_COLORS"][class]
	return format("|cff%02x%02x%02x%s|r", color.r*255, color.g*255, color.b*255, name)
end

local function send(msg)
	if(msg~=nil) then print("|cfffb2c2cFatality:|r " .. msg) end
end

local function debug(msg)
	if(faDebug) then send(msg) end
end

local function tableHasThisEntry(table, entry)
	assert(table~=nil, "bad argument #1: 'table' cannot be nil")
	assert(type(table) == "table", "bad argument #1: 'table' needs to be a table; instead what came was " .. tostring(type(table)))
	assert(entry~=nil, "bad argument #2: 'entry' cannot be nil")

	for _, value in ipairs(table) do
		if value == entry then
			return true
		end
	end
	return false
end

local function getTableLength(table)
	table = table or {}
	assert(type(table) == "table", "bad argument #1: 'table' needs to be a table; instead what came was " .. tostring(type(table)))
	local count = 0
	for _ in pairs(table) do count = count + 1 end
	return count
end

-- Remove spaces on start and end of string
local function trim(s)
	if s==nil then return "" end
	assert(type(s) == "string", "bad argument #1: 's' needs to be a string; instead what came was " .. tostring(type(s)))
	return string.match(s,'^()%s*$') and '' or string.match(s,'^%s*(.*%S)')
end

local function removeWords(myString, howMany)
	if (myString~=nil and howMany~=nil) then
		assert(type(myString) == "string", "bad argument #1: 'myString' needs to be a string; instead what came was " .. tostring(type(myString)))
		assert(type(howMany) == "number", "bad argument #2: 'howMany' needs to be a number; instead what came was " .. tostring(type(howMany)))
		assert(math.floor(howMany) == howMany, "bad argument #2: 'howMany' needs to be an integer")

		for i=1, howMany do
			myString = string.gsub(myString,"^(%s*%a+)","",1)
		end
		return trim(myString)
	end
	return ""
end
-- end of [string utils]

-- automatically sends an addon message to the appropriate channel (BATTLEGROUND, RAID or PARTY)
local function sendSync(prefix, msg)
	assert(prefix~=nil, "bad argument #1: 'prefix' cannot be nil")
	assert(type(prefix) == "string", "bad argument #1: 'prefix' needs to be a string; instead what came was " .. tostring(type(prefix)))
	local zoneType = select(2, IsInInstance())
	if zoneType == "pvp" or zoneType == "arena" then
		SendAddonMessage(prefix, msg, "BATTLEGROUND")
	elseif GetRealNumRaidMembers() > 0 then
		SendAddonMessage(prefix, msg, "RAID")
	elseif GetRealNumPartyMembers() > 0 then
		SendAddonMessage(prefix, msg, "PARTY")
	end
end

local function GetPartyType()
	if UnitInBattleground("player") then
		return "BATTLEGROUND"
	elseif UnitInRaid("player") then
		return "RAID"
	elseif UnitInParty("player") then
		return "PARTY"
	else
		return nil
	end
end

local function say(message)
	if OUTPUT == "SELF" then
		print(message)
	else
		SendChatMessage(message, GetPartyType())
	end
end

-- Addon is going to check how many messages got sent in the last 'gracePeriodForSendMessages', and if its equal or maxMessageSent then this function will return true, indicating that player cannot send more messages for now
local function isSendMessageGoingToMute()
	local now = GetTime()
	local count = 0

	for index, string in pairs(timeMessagesSent) do
		if (now <= (tonumber(string) + gracePeriodForSendMessages)) then
			count = count + 1
		else
			table.remove(timeMessagesSent,index)
		end
	end
	if count >= maxMessagesSent then return true
	else return false end
end

-- Frame update handler
local function onUpdate(this)
	if not Fatality.db.enabled then return end
	if not queuedMessages then
		this:SetScript("OnUpdate", nil)
		return
	end
	if isSendMessageGoingToMute() then return end

	table.insert(timeMessagesSent, GetTime())
	say(queuedMessages[1])
	table.remove(queuedMessages,1)
	if getTableLength(queuedMessages)==0 then queuedMessages = nil end
end

local function queueMsg(msg)
	if(msg~=nil) then
		queuedMessages = queuedMessages or {}
		table.insert(queuedMessages, msg)
		Fatality:SetScript("OnUpdate", onUpdate)
	end
end

function Fatality:CHAT_MSG_WHISPER(_, srcName)
	if srcName == UnitName("player") then table.insert(timeMessagesSent, GetTime()) end
end

function Fatality:CHAT_MSG_SAY(_, srcName)
	if srcName == UnitName("player") then table.insert(timeMessagesSent, GetTime()) end
end

function Fatality:CHAT_MSG_PARTY(_, srcName)
	if srcName == UnitName("player") then table.insert(timeMessagesSent, GetTime()) end
end

function Fatality:CHAT_MSG_RAID(_, srcName)
	if srcName == UnitName("player") then table.insert(timeMessagesSent, GetTime()) end
end

function Fatality:CHAT_MSG_RAID_LEADER(_, srcName)
	if srcName == UnitName("player") then table.insert(timeMessagesSent, GetTime()) end
end

function Fatality:CHAT_MSG_RAID_WARNING(_, srcName)
	if srcName == UnitName("player") then table.insert(timeMessagesSent, GetTime()) end
end

local function shuffle(t)
    for i=1,#t-1 do
	    t[i].time = t[i+1].time
		t[i].srcGUID = t[i+1].srcGUID
		t[i].srcName = t[i+1].srcName
		t[i].srcFlags = t[i+1].srcFlags
		t[i].destGUID = t[i+1].destGUID 	
		t[i].destName = t[i+1].destName 	
		t[i].destFlags = t[i+1].destFlags 	
		t[i].spellID = t[i+1].spellID 	
		t[i].spellName = t[i+1].spellName 	
		t[i].environment = t[i+1].environment
		t[i].amount = t[i+1].amount 	
		t[i].overkill = t[i+1].overkill 	
		t[i].crit = t[i+1].crit 		
		t[i].crush = t[i+1].crush 		
    end
end

function Fatality:FormatOutput(guid, known)
	
	local c = candidates[guid]
	local destName, destFlags = c[#c].destName, c[#c].destFlags
		
	local destIcon = icon(destFlags)
	
	if not known then
		return unknown:format(destIcon, destName)
	end
	
	local dest = format("%s%s", destIcon, color(c[1].destName))
	
	local source, info, full
	
	for i=1,EVENT_HISTORY do
	
		local e = c[i]
		if not e then break end
		
		if e.srcName then
			local srcIcon = icon(e.srcFlags)
			source = format("%s%s", srcIcon, color(e.srcName))
		else
			source = color("Unknown")
		end
		
		local ability = (e.spellID and GetSpellLink(e.spellID)) or e.environment or "Melee"
		
		if e.amount > 0 then 
			local amount = (OVERKILL and (e.amount - e.overkill)) or e.amount
			local overkill = (OVERKILL and e.overkill > 0) and format(" (O: %s)", shorten(e.overkill)) or ""
			amount = shorten(amount)
			if not e.environment then
				local crit_crush = (e.crit and " (Critical)") or (e.crush and " (Crushing)") or ""
				-- SPELL_DAMAGE, SPELL_PERIODIC_DAMAGE, RANGE_DAMAGE, SWING_DAMAGE
				info = format("%s %s%s%s [%s]", amount, ability, overkill, crit_crush, source)
			else
				-- ENVIRONMENTAL_DAMAGE
				info = format("%s %s [%s]", amount, ability, source)
			end
		else
			-- SPELL_INSTAKILL
			info = format("%s [%s]", ability, color("Unknown"))
		end
		
		full = format("%s%s%s", full or "", info, c[i + 1] and " + " or "")
		
	end
	
	local msg = format(death, dest, full)

	if msg:len() > 255 and OUTPUT ~= "SELF" then
		local err = format(limit, destName)
		print(format(status, err))
		return
	end
	
	return msg
end

function Fatality:RecordDamage(now, srcGUID, srcName, srcFlags, destGUID, destName, destFlags, spellID, spellName, environment, amount, overkill, crit, crush)

	-- If the table doesn't already exist, create it
	if not candidates[destGUID] then
		candidates[destGUID] = {}
	end
	
	-- Store the table in a temporary variable
	local t = candidates[destGUID]

	if EVENT_HISTORY == 1 then
		history = 1
	elseif #t < EVENT_HISTORY then
        history = #t + 1
    else
        shuffle(t)
        history = EVENT_HISTORY
    end
	
	if not t[history] then
		t[history] = {}
	end
	
	t[history].time = now
    t[history].srcGUID = srcGUID
	t[history].srcName = srcName
	t[history].srcFlags = srcFlags
	t[history].destGUID = destGUID
	t[history].destName = destName
	t[history].destFlags = destFlags
	t[history].spellID = spellID
	t[history].spellName = spellName
	t[history].environment = environment
	t[history].amount = amount
	t[history].overkill = overkill
	t[history].crit = crit
	t[history].crush = crush
end

function Fatality:ReportDeath(guid)
	if not candidates[guid] then return end

	if not topPriority or tableHasThisEntry(playersUnableToSpeak, UnitName("player")) then return end

	local report, now, candidate = "", GetTime(), candidates[guid]
	local id = candidate[1].destGUID
	if candidate and countMsgsSent < LIMIT then
		-- If the last damage event is more than 2 seconds before
		-- UNIT_DIED fired, assume the cause of death is unknown
		if (now - candidate[#candidate].time) < 2 then
			report = self:FormatOutput(id, true)
		else
			report = self:FormatOutput(id)
		end
		queueMsg(report)
		countMsgsSent = countMsgsSent + 1
		candidates[guid] = nil
	end
end

function Fatality:COMBAT_LOG_EVENT_UNFILTERED(timestamp, event, srcGUID, srcName, srcFlags, destGUID, destName, destFlags, ...)
	if not UnitInRaid(destName) then return end

	local spellID, spellName, amount, overkill, environment, crit, crush

	if special[event] then
		spellID, spellName, spellSchool, amount, overkill, _, _, _, _, crit, _, crush = ...
	elseif event == "SWING_DAMAGE" then
		amount, overkill, _, _, _, _, crit, _, crush = ...
	elseif event == "SPELL_INSTAKILL" then
		spellID = ...
		amount = -1
	elseif event == "ENVIRONMENTAL_DAMAGE" then
		environment, amount, overkill = ...
	end

	-- Track Demon Form and prevent player from trying to speak if transformed, temporarily assigning his role to somebody else
	if srcName and (event == "SPELL_CAST_SUCCESS" or event == "SPELL_AURA_APPLIED") then
		if spellID == METAMORPHOSIS then
			if not tableHasThisEntry(playersUnableToSpeak,srcName) then table.insert(playersUnableToSpeak, srcName) end
			if srcName == UnitName("player") then
				if faDebug and event == "SPELL_AURA_APPLIED" then send("Meta cast") end
			else
				topPriority = false
				for i,name in ipairs(raidOrdered) do
					if name and raid[name].priority and not tableHasThisEntry(playersUnableToSpeak, name) then
						if faDebug and name == UnitName("player") then send(srcName .. " cast meta and you are the top priority after him, changing the prio to you temporarily.") end
						topPriority = name==UnitName("player")
						break
					end
				end
			end
		end
	elseif event == "SPELL_AURA_REMOVED" then
		if spellID == METAMORPHOSIS then
			for i,v in ipairs(playersUnableToSpeak) do
				if v==srcName then table.remove(playersUnableToSpeak, i) end
			end
			if srcName == UnitName("player") then
				if faDebug then send("Meta fade") end
			else
				topPriority = false
				for i,name in ipairs(raidOrdered) do
					if name and raid[name].priority and not tableHasThisEntry(playersUnableToSpeak, name) then
						if faDebug then
							if name==UnitName("player") then send("You are the top priority again!")
							else send(send(srcName .. " meta faded, so he can speak again, reassigning priorities back to him.")) end
						end
						topPriority = name==UnitName("player")
						break
					end
				end
			end
		end
	end

	if amount then
		self:RecordDamage(GetTime(), srcGUID, srcName, srcFlags, destGUID, destName, destFlags, spellID, spellName, environment, amount, overkill, crit, crush)
	end

	if event == "UNIT_DIED" and not UnitIsFeignDeath(destName) then
		self:ReportDeath(destGUID)
	end

end

function Fatality:ClearData()
	countMsgsSent = 0
	wipe(candidates)
end

function Fatality:RegisterAddonEvents()
	debug("Registering \"only if inside instance\" addon events")
	self:RegisterEvents(
		"PLAYER_REGEN_DISABLED",
		"PLAYER_REGEN_ENABLED",
		"COMBAT_LOG_EVENT_UNFILTERED",
		"CHAT_MSG_WHISPER",
		"CHAT_MSG_SAY",
		"CHAT_MSG_PARTY",
		"CHAT_MSG_RAID",
		"CHAT_MSG_RAID_LEADER",
		"CHAT_MSG_RAID_WARNING"
	)
	if unit_health then
		self:RegisterEvent("UNIT_HEALTH")
	end
end

function Fatality:UnregisterAddonEvents()
	debug("Unregistering \"only if inside instance\" addon events")
	self:UnregisterEvents(
		"PLAYER_REGEN_DISABLED",
		"PLAYER_REGEN_ENABLED",
		"COMBAT_LOG_EVENT_UNFILTERED",
		"CHAT_MSG_WHISPER",
		"CHAT_MSG_SAY",
		"CHAT_MSG_PARTY",
		"CHAT_MSG_RAID",
		"CHAT_MSG_RAID_LEADER",
		"CHAT_MSG_RAID_WARNING"
	)
	if unit_health then
		self:UnregisterEvent("UNIT_HEALTH")
	end
end

function Fatality:CheckEnable()
	if not self.db.enabled then return end
	local _, instance = IsInInstance()
	if instance == "raid" then
		unit_health = instances[GetRealZoneText()] -- Only use UNIT_HEALTH to determine deaths in predefined instances
		self:ClearData()
		self:RegisterAddonEvents()
	else
		self:UnregisterAddonEvents()
	end
end

function Fatality:UNIT_HEALTH(unit)
	--if not units[unit] then return end
	if not Fatality:IsInRaid(GetUnitName(unit)) then return end
	if UnitIsDead(unit) or UnitBuff(unit, spiritOfRedemption) then
		self:ReportDeath(UnitGUID(unit))
	end
end

local function splitVersion(version, delimiter)
	if delimiter == nil then
		delimiter = "%s"
	end
	local t={}
	for str in string.gmatch(version, "([^"..delimiter.."]+)") do
		table.insert(t, tonumber(str or 0))
	end
	return t
end

-----------------------------
--  Ordering Raid Members  --
-----------------------------
do
	local function compareVersions(v1,v2)
		if not v1 then return false end
		if not v2 then return true end

		local a = splitVersion(v1,".")
		local b = splitVersion(v2,".")

		local max = math.max(getTableLength(a), getTableLength(b), 1)
		for i=1, max do
			if not a[i] or not b[i] then return a[i]~=nil end
			if a[i]~=b[i] then return a[i] > b[i] end
		end
		return true
	end
	local function comparePriorities(a1,b2)
		local a = raid[a1]
		local b = raid[b2]

		if not a then return false end
		if not b then return true end
		if not a.name then return false end
		if not b.name then return true end
		if not UnitIsConnected(a.name) then return false end
		if not UnitIsConnected(b.name) then return true end

		if a.priority and b.priority then
			if a.version and b.version and a.version~=b.version then return compareVersions(a.version,b.version) end
			if a.rank and b.rank and a.rank~=b.rank then return a.rank > b.rank end
			if a.priority and b.priority and a.priority~=b.priority then return a.priority > b.priority end
			if a.id and b.id and a.id~=b.id then return a.id > b.id end
		end
		return a.priority~=nil
	end
	function Fatality:ReorderPriorities()
		if not raid then return end
		raidOrdered = {}

		for k,v in pairs(raid) do
			if v~=nil and v.id then table.insert(raidOrdered,k) end
		end
		local length = getTableLength(raidOrdered)
		if length == 0 then return end
		if length > 1 then table.sort(raidOrdered,comparePriorities) end

		if faDebug then
			debug("Table of priorities")
			for i,n in ipairs(raidOrdered) do send(format("%s. %s (%s - %s)",i,n,(raid[n].priority or 0),(raid[n].version or 0))) end
		end

		if raidOrdered[1] == UnitName("player") then
			topPriority = true
		else
			topPriority = false
		end
	end
end

-----------------------------
--  Handle Incoming Syncs  --
-----------------------------
do
	local syncHandlers = {}

	syncHandlers["Fatality-Prio"] = function(msg, channel, sender)
		if msg == "Hi!" and Fatality.db.enabled then
			sendSync("Fatality-Prio", Fatality.Priority)
		else
			local priority = tonumber(msg)
			if sender and sender~="" and (priority==nil or type(priority) == "number") then
				--debug(format("%s sent you his priority (%s)",sender,(priority or 0))) end
				raid[sender] = raid[sender] or {}
				raid[sender].priority = priority
				if sender~=UnitName("player") and priority == Fatality.Priority then
					Fatality.Priority = math.random(MAX_PRIORITY)
					if Fatality.db.enabled then sendSync("Fatality-Prio", Fatality.Priority) end
				end
				Fatality:ReorderPriorities()
			end
		end
	end

	syncHandlers["Fatality-Ver"] = function(msg, channel, sender)
		if msg == "Hi!" then
			sendSync("Fatality-Ver", Fatality.Version)
		else
			--debug("Received from player " .. (sender or "unknown") .. " version " .. (msg or "unknown"))
			if msg and msg~="" and sender and sender~="" and raid and raid[sender] then
				raid[sender].version = msg
			end
		end
	end

	function Fatality:CHAT_MSG_ADDON(prefix, msg, channel, sender)
		if msg and channel ~= "WHISPER" and channel ~= "GUILD" then
			local handler = syncHandlers[prefix]
			if handler then handler(msg, channel, sender) end
			--elseif msg and channel == "WHISPER" and self:GetRaidUnitId(sender) ~= "none" then
			--   local handler = whisperSyncHandlers[prefix]
			--   if handler then handler(msg, channel, sender) end
		end
	end
end

---------------------------
--  Raid/Party Handling  --
---------------------------
do
	local inRaid = false

	function Fatality:RAID_ROSTER_UPDATE()
		if GetNumRaidMembers() >= 1 then
			if not inRaid then
				inRaid = true
				sendSync("Fatality-Ver", "Hi!")
				sendSync("Fatality-Prio", "Hi!")
			end
			for i = 1, GetNumRaidMembers() do
				local name, rank, subgroup, _, _, fileName,_,online = GetRaidRosterInfo(i)
				if name and inRaid then
					raid[name] = raid[name] or {}
					raid[name].name = name
					raid[name].rank = rank
					raid[name].subgroup = subgroup
					raid[name].class = fileName
					raid[name].id = "raid"..i
					if raid[name].priority~=nil and not online then raid[name].priority=nil end
					raid[name].updated = true
				end
			end
			-- removing players that left pt
			for i, v in pairs(raid) do
				if not v.updated then
					raid[i] = nil
				else
					v.updated = nil
				end
			end
			Fatality:ReorderPriorities()
		else
			inRaid = false
			topPriority = true
			for i,_ in pairs(raid) do raid[i] = nil end
			raid = {}
		end
	end

	function Fatality:PARTY_MEMBERS_CHANGED()
		if GetNumRaidMembers() > 0 then return end
		if GetNumPartyMembers() >= 1 then
			if not inRaid then
				inRaid = true
				sendSync("Fatality-Ver", "Hi!")
				sendSync("Fatality-Prio", "Hi!")
			end
			for i = 0, GetNumPartyMembers() do
				local id
				if (i == 0) then
					id = "player"
				else
					id = "party"..i
				end
				local name, server = UnitName(id)
				local rank, _, fileName = UnitIsPartyLeader(id), UnitClass(id)
				if server and server ~= ""  then
					name = name.."-"..server
				end
				local online = UnitIsConnected(name) and true or false
				raid[name] = raid[name] or {}
				raid[name].name = name
				if rank then
					raid[name].rank = 2
				else
					raid[name].rank = 0
				end
				raid[name].class = fileName
				raid[name].id = id
				if raid[name].priority~=nil and not online then raid[name].priority=nil end
				raid[name].updated = true
			end
			-- removing players that left pt
			for i, v in pairs(raid) do
				if not v.updated then
					raid[i] = nil
				else
					v.updated = nil
				end
			end
			Fatality:ReorderPriorities()
		else
			inRaid = false
			topPriority = true
			for i,_ in pairs(raid) do raid[i] = nil end
			raid = {}
		end
	end

	function Fatality:IsInRaid(name)
		return name==UnitName("player") and inRaid or (raid[name] and raid[name].id~=nil)
	end

	function Fatality:GetRaidRank(name)
		name = name or UnitName("player")
		return (raid[name] and raid[name].rank) or 0
	end

	function Fatality:GetRaidSubgroup(name)
		name = name or UnitName("player")
		return (raid[name] and raid[name].subgroup) or 0
	end

	function Fatality:GetRaidClass(name)
		name = name or UnitName("player")
		return (raid[name] and raid[name].class) or "UNKNOWN"
	end

	function Fatality:GetRaidUnitId(name)
		name = name or UnitName("player")
		return (raid[name] and raid[name].id) or "none"
	end

	function Fatality:ResetRaid()
		for i, v in pairs(raid) do
			raid[i] = nil
		end
		raid = {}
		inRaid = false
	end
end

--function Fatality:RAID_ROSTER_UPDATE()
--	wipe(units)
--	local name, group
--	local max_group = 6 - (GetInstanceDifficulty() % 2) * 3
--	for i=1,40 do
--		name, _, group = GetRaidRosterInfo(i)
--		if name and group < max_group then
--			units["raid" .. i] = true
--		end
--	end
--end

function Fatality:PLAYER_REGEN_DISABLED()
	self:ClearData()
end

function Fatality:ZONE_CHANGED()
	self:CheckEnable()
end

function Fatality:ZONE_CHANGED_NEW_AREA()
	self:CheckEnable()
end

function Fatality:PLAYER_ENTERING_WORLD()
	if not unit_health then -- Just in case Z_C or Z_C_N_A fire before P_E_W
		self:CheckEnable()
	end
end

function Fatality:PLAYER_LOGIN()
	self:CheckEnable()
end

function Fatality:PLAYER_REGEN_ENABLED()
	playersUnableToSpeak = {}
end

do
	local function sortVersion(v1, v2)
		if not v1 then return false end
		if not v2 then return true end
		if not v1.version then return false end
		if not v2.version then return true end

		local a = splitVersion(v1.version,".")
		local b = splitVersion(v2.version,".")

		local max = math.max(getTableLength(a), getTableLength(b), 1)
		for i=1, max do
			if not a[i] or not b[i] then return a[i]~=nil end
			if a[i]~=b[i] then return a[i] > b[i] end
		end
		return true
	end

	function Fatality:ShowVersions()
		local sortedTable = {}
		for i, v in pairs(raid) do
			if v~=nil then table.insert(sortedTable, v) end
		end
		debug("Raid size is " .. getTableLength(raid))
		print("|cffff533f<|r|cfffb2c2cFatality|r|cffff533f>|r |cffff9e9eFatality - Versions|r")
		if getTableLength(sortedTable) > 1 then table.sort(sortedTable, sortVersion) end
		if getTableLength(sortedTable) == 0 then
			if Fatality.Version and Fatality.db.enabled then
				print(format("|cffff533f<|r|cfffb2c2cFatality|r|cffff533f>|r |cffff9e9e%s:|r %s", UnitName("player"), Fatality.Version))
			else
				print(format("|cffff533f<|r|cfffb2c2cFatality|r|cffff533f>|r |cffff9e9e%s:|r %s (disabled)", UnitName("player"), Fatality.Version))
			end
		else
			for i, v in ipairs(sortedTable) do
				local msg
				if v.version then
					msg = format("|cffff533f<|r|cfffb2c2cFatality|r|cffff533f>|r |cffff9e9e%s:|r %s", v.name, v.version)
					if not v.priority and UnitIsConnected(v.name) then
						msg = msg .. " (disabled)"
					elseif not UnitIsConnected(v.name) then
						msg = msg .. " (offline)"
					end
				else
					msg = format("|cffff533f<|r|cfffb2c2cFatality|r|cffff533f>|r |cffff9e9e%s:|r Fatality not installed", v.name)
				end
				print(msg)
			end
			for i = #sortedTable, 1, -1 do
				if not sortedTable[i].version then
					table.remove(sortedTable, i)
				end
			end
		end
		print(format("|cffff533f<|r|cfffb2c2cFatality|r|cffff533f>|r |cffff9e9eFound|r |cfff0a71f%s|r |cffff9e9eplayer%s with Fatality|r",(#sortedTable > 1 and #sortedTable or 1),(#sortedTable > 1 and "s" or "")))
		for i = #sortedTable, 1, -1 do
			sortedTable[i] = nil
		end
	end
end

local function slashCommand(typed)
	local cmd = string.match(typed,"^(%w+)") -- Gets the first word the user has typed
	if cmd~=nil then cmd = cmd:lower() end   -- And makes it lower case
	local extra = removeWords(typed, 1)
	if(cmd=="debug") then
		faDebug = not faDebug
		Fatality.db.debug = faDebug
		send("debug mode turned " .. (faDebug and "|cff00ff00on|r" or "|cffff0000off|r"))
	elseif (cmd=="prio" or cmd=="priority" or cmd=="p") then
		send("my priority is " .. Fatality.Priority)
	elseif (cmd=="setprio" or cmd=="setpriority" or cmd=="sp") and faDebug then
		if extra~=nil and tonumber(extra)~=nil then
			Fatality.Priority = tonumber(extra)
			send("priority set to " .. extra)
			sendSync("Fatality-Prio", Fatality.Priority)
		end
	elseif (cmd=="ver" or cmd=="version") then
		Fatality:ShowVersions()
	elseif (cmd=="priotable" or cmd=="pt" or cmd=="tp") and faDebug then
		send("Table of priorities (TP)")
		for i,n in ipairs(raidOrdered) do send(format("%s. %s (%s - %s)",i,n,(raid[n].priority or 0),(raid[n].version or 0))) end
	elseif Fatality.db.enabled then
		Fatality.db.enabled = false
	    Fatality:UnregisterAddonEvents()
		Fatality:ClearData()
		Fatality:UnregisterEvents(
			"ZONE_CHANGED",
			"ZONE_CHANGED_NEW_AREA",
			"PLAYER_ENTERING_WORLD"
		)
		sendSync("Fatality-Prio", nil)
		print(format(status, "|cffff0000off|r"))
	else
		Fatality.db.enabled = true
		topPriority = true
		Fatality:RegisterAddonEvents()
		Fatality:RegisterEvents(
			"ZONE_CHANGED",
			"ZONE_CHANGED_NEW_AREA",
			"PLAYER_ENTERING_WORLD"
		)
		Fatality:ResetRaid()
		Fatality:RAID_ROSTER_UPDATE()
		Fatality:PARTY_MEMBERS_CHANGED()
		print(format(status, "|cff00ff00on|r"))
	end
end

--------------
--  OnLoad  --
--------------

function Fatality:RegisterEvents(...)
	for i = 1, select("#", ...) do
		local ev = select(i, ...)
		Fatality:RegisterEvent(ev)
	end
end

function Fatality:UnregisterEvents(...)
	for i = 1, select("#", ...) do
		local ev = select(i, ...)
		Fatality:UnregisterEvent(ev)
	end
end

function Fatality:ADDON_LOADED(addon)
	if addon ~= "Fatality" then return end
	Fatality.Priority = math.random(MAX_PRIORITY)

	FatalityDB = FatalityDB or { enabled = true }
	self.db = FatalityDB
	faDebug = self.db.debug or faDebug
	Fatality.Version = GetAddOnMetadata("Fatality", "Version")

	SLASH_FATALITY1, SLASH_FATALITY2 = "/fatality", "/fat"
	SlashCmdList.FATALITY = function(cmd) slashCommand(cmd) end
	debug("remember that debug mode is |cff00ff00ON|r.")

	self:RegisterEvents(
		"CHAT_MSG_ADDON",
		"RAID_ROSTER_UPDATE",
		"PARTY_MEMBERS_CHANGED"
	)
	if self.db.enabled then
		self:RegisterEvents(
			"ZONE_CHANGED",
			"ZONE_CHANGED_NEW_AREA",
			"PLAYER_ENTERING_WORLD",
			"PLAYER_LOGIN"
		)
	end
	self:RAID_ROSTER_UPDATE()
	self:PARTY_MEMBERS_CHANGED()
end

Fatality:RegisterEvent("ADDON_LOADED")