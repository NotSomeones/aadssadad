-- ============================================================================
-- 🔁 FULL TRADE LOGGER – tracks items given by each player (local file)
-- Compares inventories in a fast loop → logs both sides of a trade
-- ============================================================================

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local RemoteFunction = ReplicatedStorage:WaitForChild("Events"):WaitForChild("RemoteFunction")
local LOG_FILE = "trades.json"

-- ============================================================================
-- UTILS
-- ============================================================================

local function randomTinyDelay()
    task.wait(0.15 + math.random() * 0.25)   -- fast stagger, safe for most games
end

-- ============================================================================
-- INVENTORY FETCHING (unchanged from your script)
-- ============================================================================

local function getInventory(player)
    local ok, r1, r2 = pcall(function()
        return RemoteFunction:InvokeServer("GetInventory", player)
    end)
    if not ok or r1 == "Private" or not r2 then
        return nil
    end
    return r2
end

local function buildInventoryMap(inv)
    local map = {}
    if type(inv) ~= "table" then return map end
    for category, items in pairs(inv) do
        if type(items) == "table" then
            for _, item in pairs(items) do
                if type(item) == "table" and item.Name and item.Amount then
                    map[category .. ":" .. item.Name] = tonumber(item.Amount) or 0
                end
            end
        end
    end
    return map
end

-- ============================================================================
-- LOCAL TRADE LOG FILE HANDLING
-- ============================================================================

local function loadTradeLog()
    local ok, content = pcall(readfile, LOG_FILE)
    if ok and content and #content > 0 then
        return HttpService:JSONDecode(content)
    end
    return {}
end

local tradeLog = loadTradeLog()

local function saveTradeLog()
    writefile(LOG_FILE, HttpService:JSONEncode(tradeLog))
end

-- ============================================================================
-- DETECTION ENGINE (instant grouping of exchanges)
-- ============================================================================

local previousInventories = {}          -- [userId] = inventoryMap
local cycleChanges = {}                -- net changes in current scan cycle: [userId] = { [item] = delta }

-- Record differences for one player into the current cycle
local function recordChanges(player, currentMap)
    local userId = tostring(player.UserId)
    local prevMap = previousInventories[userId] or {}
    local changes = cycleChanges[userId]
    if not changes then
        changes = {}
        cycleChanges[userId] = changes
    end

    for item, curAmt in pairs(currentMap) do
        local prevAmt = prevMap[item] or 0
        local delta = curAmt - prevAmt
        if delta ~= 0 then
            changes[item] = (changes[item] or 0) + delta
        end
    end

    -- Items completely gone
    for item, prevAmt in pairs(prevMap) do
        if currentMap[item] == nil then
            changes[item] = (changes[item] or 0) - prevAmt
        end
    end

    -- Update baseline for next cycle
    previousInventories[userId] = currentMap
end

-- After scanning all players, try to find pairs that swapped items
local function matchTradesInCycle()
    -- Build lists of players who had any net changes
    local playersWithChanges = {}
    for userId, changes in pairs(cycleChanges) do
        -- Filter out zero net changes
        local hasNonZero = false
        for _, delta in pairs(changes) do
            if delta ~= 0 then
                hasNonZero = true
                break
            end
        end
        if hasNonZero then
            table.insert(playersWithChanges, userId)
        end
    end

    if #playersWithChanges < 2 then return end

    -- Attempt to match pairs greedily
    local matched = {}
    for i = 1, #playersWithChanges do
        local idA = playersWithChanges[i]
        if not matched[idA] then
            for j = i + 1, #playersWithChanges do
                local idB = playersWithChanges[j]
                if not matched[idB] then
                    -- Check if A's losses == B's gains AND B's losses == A's gains
                    local changesA = cycleChanges[idA]
                    local changesB = cycleChanges[idB]

                    -- Build gain/loss maps (losses stored as positive amounts)
                    local aGave, aGot = {}, {}   -- what A gave away (negative deltas), what A received (positive)
                    local bGave, bGot = {}, {}

                    for item, delta in pairs(changesA) do
                        if delta < 0 then aGave[item] = math.abs(delta) end
                        if delta > 0 then aGot[item] = delta end
                    end
                    for item, delta in pairs(changesB) do
                        if delta < 0 then bGave[item] = math.abs(delta) end
                        if delta > 0 then bGot[item] = delta end
                    end

                    -- Check if the two sets match exactly
                    local function mapsEqual(m1, m2)
                        if #next(m1) ~= #next(m2) then return false end
                        for k, v in pairs(m1) do
                            if m2[k] ~= v then return false end
                        end
                        return true
                    end

                    if mapsEqual(aGave, bGot) and mapsEqual(bGave, aGot) then
                        -- Trade detected! Both sides match perfectly.
                        local playerA = Players:GetPlayerByUserId(tonumber(idA))
                        local playerB = Players:GetPlayerByUserId(tonumber(idB))
                        if playerA and playerB then
                            local trade = {
                                id = HttpService:GenerateGUID(false),
                                timestamp = os.time(),
                                players = {playerA.Name, playerB.Name},
                                player1 = playerA.Name,
                                player2 = playerB.Name,
                                player1_gave = aGave,   -- items player1 gave away
                                player2_gave = bGave    -- items player2 gave away
                            }
                            table.insert(tradeLog, trade)
                            saveTradeLog()

                            print(string.format("💱 TRADE: %s gave %s | %s gave %s",
                                playerA.Name,
                                HttpService:JSONEncode(aGave),
                                playerB.Name,
                                HttpService:JSONEncode(bGave)))

                            -- Mark both as matched and clear their changes from the cycle
                            matched[idA] = true
                            matched[idB] = true
                            -- Remove their changes so they don't interfere with other matches
                            cycleChanges[idA] = nil
                            cycleChanges[idB] = nil
                            break
                        end
                    end
                end
            end
        end
    end

    -- Any remaining unpaired changes are likely not trades (drops, crafting, etc.), we just discard them.
    cycleChanges = {}   -- clear for next cycle
end

-- ============================================================================
-- MAIN FAST SCANNING LOOP
-- ============================================================================

print("📡 Building initial inventory baseline...")

-- First scan sets the baseline (no trades logged)
for _, player in ipairs(Players:GetPlayers()) do
    if player ~= Players.LocalPlayer then
        local inv = getInventory(player)
        if inv then
            previousInventories[tostring(player.UserId)] = buildInventoryMap(inv)
        end
        randomTinyDelay()
    end
end

print("✅ Baseline ready. Monitoring for trades (refresh every 0.5s)...")

-- Continuous instant monitoring
while true do
    cycleChanges = {}   -- start a fresh cycle

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= Players.LocalPlayer then
            local inv = getInventory(player)
            if inv then
                local currentMap = buildInventoryMap(inv)
                recordChanges(player, currentMap)
            end
            randomTinyDelay()
        end
    end

    matchTradesInCycle()

    task.wait(0.5)   -- full scan every ~0.5 seconds (practically instant)
end
