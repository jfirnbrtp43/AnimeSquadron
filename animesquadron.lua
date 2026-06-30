-- AnimeSquadron | Foundation + EndScreen + Gameplay Toggles
-- Drop this file in your executor's autoexec folder.
-- State is persisted to AnimeSquadron/state.json in the executor workspace.

local LOBBY_PLACE_ID  = 71132543521245
local INGAME_PLACE_ID = 91255392593879
local LOG_PREFIX      = "[AS]"

local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")

-- Wait for LocalPlayer before anything else (autoexec can fire before it's ready)
if not Players.LocalPlayer then
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
end
local _playerName = Players.LocalPlayer.Name
local STATE_PATH    = "AnimeSquadron/" .. _playerName .. "_state.json"
local SETTINGS_PATH = "AnimeSquadron/" .. _playerName .. "_settings.json"

-- ── Global namespace ─────────────────────────────────────────────
_G.AnimeSquadron = _G.AnimeSquadron or {}
local NS = _G.AnimeSquadron

-- Settings flags — will be replaced by UI toggles in a later step.
-- challengeReturn30: leave to lobby at XX:00 and XX:30 to catch the 30-min challenge reset.
-- autoJoin: unused legacy key (kept for backwards compat); per-mode enabled flag controls joining.
-- joinModes: one entry per mode; enabled=true means it will be tried in lobby.
--   mode values: "Story", "Squadron", "Raid", "Challenge", "Infinite", "Permanent"
--   Challenge extra field: challengeType = "30m" | "1d"
NS.settings = NS.settings or {}
local _defaults = {
    autoStart         = false,
    autoMaxSpeed      = false,
    autoNext          = false,
    autoReplay        = false,
    autoLeave         = false,
    challengeReturn30 = false,
    autoUpgrade       = false,
    upgradeMode       = "max",   -- "max" | "cheapest"
    upgradeSlots      = {
        { slot=1, priority=0 },
        { slot=2, priority=0 },
        { slot=3, priority=0 },
        { slot=4, priority=0 },
        { slot=5, priority=0 },
        { slot=6, priority=0 },
    },
    autoClaimQuests   = false,  -- claim_all on lobby load
    autoClaimSpecial  = false,  -- try claiming each special quest on lobby load
    autoSell          = {},     -- array of rarity names to auto-sell: "Rare","Epic","Legendary","Mythic"
    autoSummon        = false,
    summonBanner      = "Basic Banner",  -- "Basic Banner" | "Selection Banner"
    summonAmount      = 1,       -- 1 or 10
    autoRaidShop      = false,
    raidShopBuy       = {},      -- { ["Item Name"] = maxAmount }
    autoMerchant      = false,
    merchantBuy       = {},      -- { ["Item Name"] = maxAmount }
    autoEvo           = false,
    evoTargets        = {},    -- unit names to awaken in priority order: {"Goki (SSJ4)", "Caska"}
    autoGear          = false,
    gearTargets       = {},    -- gear piece names to farm materials for
    webhookUrl        = "",    -- Discord webhook URL; empty = disabled
    webhookUserId     = "",    -- Discord User ID to ping on evo notifications; empty = no ping
    webhookOnVictory  = false,
    webhookOnDefeat   = false,
    webhookOnEvoReady = false,
    autoJoin          = false,
    joinModes         = {
        { mode="Story",     enabled=false, priority=1, world="GT City",            act=1, difficulty="Normal" },
        { mode="Squadron",  enabled=false, priority=2, world="GT City",            act=1, difficulty="Normal" },
        { mode="Raid",      enabled=false, priority=3, world="GT City",            act=1, difficulty="Normal" },
        { mode="Challenge", enabled=false, priority=4, challengeType="30m" },
        { mode="Infinite",  enabled=false, priority=5, boosted=false },
        { mode="Permanent", enabled=false, priority=6, world="Katakara Bridge",    act=1, difficulty="Normal" },
    },
}
for k, v in pairs(_defaults) do
    if NS.settings[k] == nil then NS.settings[k] = v end
end

-- Settings are restored from state file inside State.load() below

local function log(msg)
    print(LOG_PREFIX .. " " .. tostring(msg))
end

-- ── Webhook ──────────────────────────────────────────────────────
local function _webhookPost(body)
    if not NS.settings.webhookUrl or NS.settings.webhookUrl == "" then return end
    task.spawn(function()
        pcall(function()
            request({
                Url     = NS.settings.webhookUrl,
                Method  = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body    = HttpService:JSONEncode(body),
            })
        end)
    end)
end

local function sendWebhook(msg)
    _webhookPost({ username = "Anime Squadron", content = msg })
end

local function sendWebhookEmbed(embed)
    _webhookPost({ username = "Anime Squadron", embeds = { embed } })
end

local function buildStageEmbed(resultText, stage, act, elapsed, pd, runCount)
    local isVictory = resultText == "Victory!"
    local fields = {}

    local function addField(name, value, inline)
        table.insert(fields, { name = name, value = tostring(value), inline = inline or false })
    end

    local playerLevel = pd and pd.stats and pd.stats.level
    local difficulty  = NS.currentDifficulty
        or (NS.evoFarmStage and NS.evoFarmStage.diff)
        or "?"
    addField("Player",     "||" .. _playerName .. "||",              true)
    addField("Level",      playerLevel and tostring(playerLevel) or "?", true)
    addField("Act",        "Act " .. tostring(act or "?"),            true)
    addField("Difficulty", difficulty,                                 true)

    if elapsed then
        addField("Clear Time", string.format("%d:%02d", math.floor(elapsed/60), elapsed%60), true)
    end
    if runCount then
        addField("Matches Played", tostring(runCount), true)
    end

    -- Equipped units sorted by slot index
    if pd and pd.characters then
        local equipped = {}
        for _, c in pairs(pd.characters) do
            if c.equipped then table.insert(equipped, c) end
        end
        table.sort(equipped, function(a, b) return (a.index or 0) < (b.index or 0) end)
        if #equipped > 0 then
            local lines = {}
            for _, c in ipairs(equipped) do
                local lvl = c.level or "?"
                table.insert(lines, (c.name or "?") .. " (Lv. " .. tostring(lvl) .. ")")
            end
            addField("Units", table.concat(lines, "\n"), false)
        end
    end

    -- Materials gained (diff against pre-stage snapshot)
    if pd and pd.items then
        local pre   = NS.preStageInventory or {}
        local lines = {}
        for mat, total in pairs(pd.items) do
            local gained = total - (pre[mat] or 0)
            if gained > 0 then
                table.insert(lines, string.format("**%s** +%d (%d total)", mat, gained, total))
            end
        end
        table.sort(lines)
        local matVal = #lines > 0 and table.concat(lines, "\n") or "None detected"
        if #matVal > 1024 then matVal = matVal:sub(1, 1021) .. "..." end
        addField("Materials Gained", matVal, false)
    end

    local titlePrefix = isVictory and "✅ Victory" or "❌ Defeat"
    return {
        title  = titlePrefix .. " — " .. tostring(stage or "?"),
        color  = isVictory and 3066993 or 15158332,
        fields = fields,
    }
end

local function evoPing()
    local id = NS.settings.webhookUserId
    return (id and id ~= "") and ("<@" .. id .. "> ") or ""
end

NS.webhookTest = function()
    sendWebhook("🔔 Test ping from Anime Squadron — webhook is working!")
end

-- ── State ────────────────────────────────────────────────────────
local State = {}
local _data = {}

function State.load()
    -- Load game state
    if isfile(STATE_PATH) then
        local ok, decoded = pcall(function()
            return HttpService:JSONDecode(readfile(STATE_PATH))
        end)
        if ok and type(decoded) == "table" then
            _data = decoded
            if type(_data.clearTimes) ~= "table" then _data.clearTimes = {} end
            log("State loaded")
        else
            log("State file unreadable — resetting")
            _data = { version = 1, lastPlaceId = nil, stage = nil, act = nil, clearTimes = {} }
            State.save()
        end
    else
        _data = { version = 1, lastPlaceId = nil, stage = nil, act = nil, clearTimes = {} }
        State.save()
    end

    -- Load settings separately (never overwritten by gameplay saves)
    if isfile(SETTINGS_PATH) then
        local ok, saved = pcall(function()
            return HttpService:JSONDecode(readfile(SETTINGS_PATH))
        end)
        if ok and type(saved) == "table" then
            for k, v in pairs(saved) do
                NS.settings[k] = v
            end
        end
    end
    -- Migrate joinModes from priority → enabled (one-time upgrade)
    if type(NS.settings.joinModes) == "table" then
        for _, m in ipairs(NS.settings.joinModes) do
            if m.enabled == nil then
                m.enabled = (m.priority ~= nil and m.priority > 0)
                m.priority = nil
            end
        end
    end
end

function State.saveSettings()
    if not isfolder("AnimeSquadron") then makefolder("AnimeSquadron") end
    pcall(function()
        writefile(SETTINGS_PATH, HttpService:JSONEncode(NS.settings))
    end)
end

function State.save()
    if not isfolder("AnimeSquadron") then
        makefolder("AnimeSquadron")
    end
    local ok, err = pcall(function()
        writefile(STATE_PATH, HttpService:JSONEncode(_data))
    end)
    if not ok then
        log("State save failed: " .. tostring(err))
    end
end

function State.get(key) return _data[key] end

function State.set(key, value)
    _data[key] = value
    State.save()
end

-- ── Parser ───────────────────────────────────────────────────────
local Parser = {}

function Parser.parse(text)
    if not text or text == "" then return nil end
    local stripped = text:gsub("</?font[^>]*>", "")
    -- Period after "Act" is optional — seen both "Act. 2" and "Act 1" in the wild
    local stageName, actStr = stripped:match("^(.-)%s*%-%s*Act%.?%s+(%d+)%s*$")
    if not stageName or not actStr then return nil end
    return { stageName = stageName, act = tonumber(actStr) }
end

-- ── Clear-time EMA ───────────────────────────────────────────────
local ClearTime = {}
local EMA_ALPHA     = 0.25
local EMA_MIN_COUNT = 3  -- samples before the average is considered reliable

local function stageKey(stageName, act)
    return stageName .. "|" .. tostring(act)
end

-- Parses "M:SS" or "MM:SS" from the EndScreen Play Time label into seconds.
function ClearTime.parseLabel(text)
    local m, s = text:match("^(%d+):(%d+)$")
    if m and s then return tonumber(m) * 60 + tonumber(s) end
    return nil
end

function ClearTime.update(stageName, act, elapsed)
    local key   = stageKey(stageName, act)
    local entry = _data.clearTimes[key] or { avg = elapsed, count = 0 }

    entry.count = entry.count + 1
    if entry.count == 1 then
        entry.avg = elapsed
    else
        entry.avg = entry.avg + EMA_ALPHA * (elapsed - entry.avg)
    end

    _data.clearTimes[key] = entry
    State.save()

    log(string.format("Clear time: %ds | EMA %.1fs | n=%d%s",
        elapsed, entry.avg, entry.count,
        entry.count < EMA_MIN_COUNT and " (cold)" or ""))
end

function ClearTime.get(stageName, act)
    return _data.clearTimes[stageKey(stageName, act)]
end

-- ── Static data ───────────────────────────────────────────────────
NS.data = {
    awaken = {
        ["Shinks"]                 = { awakensTo="Shinks (Emperor)",              cost={["Pelli"]=100,["Beastblood Catalyst"]=20,["King's Haki Residue"]=3,["Stormwake Sailcloth"]=40,["Meat"]=200,["Gryphon"]=1} },
        ["Big Beard"]              = { awakensTo="Big Beard (Father)",            cost={["Pelli"]=100,["Beastblood Catalyst"]=10,["Depthglass Bottle"]=50,["Bisento"]=1,["Meat"]=200,["Stormwake Sailcloth"]=100} },
        ["Vegata (SSJ4)"]          = { awakensTo="Vegata (SSJ4 Full Power)",      cost={["Stellar Ki Quartz"]=50,["Limitbreak Obsidian"]=30,["Zeni"]=100,["Scouter"]=1,["Ki Resonant Crystal"]=70,["Senzu"]=200} },
        ["Rizzuto"]                = { awakensTo="Rizzuto (Sage)",                cost={["Shuriken"]=1,["Narutomaki"]=200,["Genjutsu Fog Vial"]=30,["Headband"]=100,["Binding Cloth"]=50,["Shinobi Bone"]=100} },
        ["Woo"]                    = { awakensTo="Woo (Shadow)",                  cost={["Eclipse Godstone"]=5,["Pelli"]=100,["Chakra Fragment"]=5,["King's Haki Residue"]=5,["Monarch Daggers"]=1,["Zeni"]=100,["Headband"]=100} },
        ["Super Beby 2"]           = { awakensTo="Big Beard (Father)",            cost={["Beastblood Catalyst"]=5,["Depthglass Bottle"]=25,["Bisento"]=1,["Meat"]=100,["Stormwake Sailcloth"]=50} },
        ["Madora"]                 = { awakensTo="Madora (Gunbai)",               cost={["Gunbai"]=1,["Narutomaki"]=200,["Genjutsu Fog Vial"]=50,["Headband"]=200,["Chakra Fragment"]=6,["Fuin Script Paper"]=30} },
        ["Karashi"]                = { awakensTo="Karashi (Sharingan)",           cost={["Chakra Fragment"]=3,["Karashi's Book"]=1,["Fuin Script Paper"]=20,["Headband"]=100,["Shinobi Bone"]=100,["Narutomaki"]=200} },
        ["Goki (SSJ4 Full Power)"] = { awakensTo="Gometa (SSJ4)",                cost={["Eclipse Godstone"]=10,["King's Haki Residue"]=10,["Chakra Fragment"]=10,["Zeni"]=200,["Primal Core"]=1} },
        ["Goki (SSJ4)"]            = { awakensTo="Goki (SSJ4 Full Power)",        cost={["Eclipse Godstone"]=3,["Zenkai Ore"]=100,["Limitbreak Obsidian"]=20,["Zeni"]=100,["Power Pole"]=1,["Senzu"]=200} },
        ["Shanron"]                = { awakensTo="Shanron (Omega)",               cost={["Eclipse Godstone"]=10,["King's Haki Residue"]=10,["Chakra Fragment"]=10,["Dragonballs"]=1,["Zeni"]=200} },
        ["Puppeteer"]              = { awakensTo="Puppeteer (Transcendent)",      cost={["Eclipse Godstone"]=10,["Pelli"]=100,["Chakra Fragment"]=10,["King's Haki Residue"]=10,["Headband"]=100,["Hogyoku Orb"]=1,["Zeni"]=100} },
        ["Berserker"]              = { awakensTo="Berserker (Enraged)",           cost={["Moonlit Silver"]=30,["Dragon Slayer (Evo)"]=1,["Black Sun Amber"]=15,["Apostle Iron"]=100,["Eclipse Stone"]=75,["Brand Ash"]=50,["Behelit"]=200,["White Behelit"]=50} },
        ["Caska"]                  = { awakensTo="Caska (Resiliance)",            cost={["Moonlit Silver"]=20,["Behelit"]=100,["Black Sun Amber"]=5,["Apostle Iron"]=75,["Eclipse Stone"]=50,["Brand Ash"]=30,["Caskas Sword"]=1,["White Behelit"]=25} },
        ["Skeleton Knight"]        = { awakensTo="Skeleton Knight (Resonance)",   cost={["Sword Of Resonance"]=1,["Behelit"]=200,["Black Sun Amber"]=15,["Apostle Iron"]=100,["Eclipse Stone"]=75,["Brand Ash"]=50,["Moonlit Silver"]=30,["White Behelit"]=25} },
        ["Falcon"]                 = { awakensTo="Falcon (Dark)",                 cost={["Moonlit Silver"]=30,["Behelit"]=200,["Black Sun Amber"]=15,["Cavalry Saber"]=1,["Apostle Iron"]=100,["Eclipse Stone"]=75,["Brand Ash"]=50,["White Behelit"]=50} },
        ["Baras"]                  = { awakensTo="Baras (Meteoric Burst)",        cost={["Black Sun Amber"]=10,["Pelli"]=100,["Chakra Fragment"]=10,["King's Haki Residue"]=10,["Headband"]=100,["Behelit"]=100,["Baras Eye"]=1} },
        ["Garu"]                   = { awakensTo="Garu (Half Monster)",           cost={["Black Sun Amber"]=10,["Pelli"]=100,["Chakra Fragment"]=10,["King's Haki Residue"]=10,["Headband"]=100,["Behelit"]=100,["Hunters Cloth"]=1} },
    },
    unknownSource = {
        "Monarch Daggers", "Primal Core", "Hogyoku Orb", "Baras Eye", "Hunters Cloth", "Gold",
    },
    matmap = {
        ["Apostle Iron"]        = { {world="Eclipse (Before)",mode="Story",diff="Normal",act=1,amount="2-4x",chance="100%"},{world="Eclipse (Before)",mode="Story",diff="Normal",act=2,amount="2-4x",chance="100%"},{world="Eclipse (Before)",mode="Story",diff="Hard",act=1,amount="4-8x",chance="100%"},{world="Eclipse (Before)",mode="Story",diff="Hard",act=2,amount="4-8x",chance="100%"} },
        ["Zenkai Ore"]          = { {world="GT City",mode="Story",diff="Normal",act=1,amount="2-4x",chance="100%"},{world="GT City",mode="Story",diff="Normal",act=2,amount="2-4x",chance="100%"},{world="GT City",mode="Story",diff="Hard",act=1,amount="4-8x",chance="100%"},{world="GT City",mode="Story",diff="Hard",act=2,amount="4-8x",chance="100%"} },
        ["Ki Resonant Crystal"] = { {world="GT City",mode="Story",diff="Normal",act=3,amount="1-2x",chance="100%"},{world="GT City",mode="Story",diff="Normal",act=4,amount="1-2x",chance="100%"},{world="GT City",mode="Story",diff="Hard",act=3,amount="2-4x",chance="100%"},{world="GT City",mode="Story",diff="Hard",act=4,amount="2-4x",chance="100%"} },
        ["Stellar Ki Quartz"]   = { {world="GT City",mode="Story",diff="Normal",act=5,amount="1x",chance="100%"},{world="GT City",mode="Story",diff="Normal",act=6,amount="1x",chance="100%"},{world="GT City",mode="Story",diff="Hard",act=5,amount="2x",chance="100%"},{world="GT City",mode="Story",diff="Hard",act=6,amount="2x",chance="100%"} },
        ["Limitbreak Obsidian"] = { {world="GT City",mode="Story",diff="Normal",act=7,amount="1x",chance="30%"},{world="GT City",mode="Story",diff="Normal",act=8,amount="1x",chance="30%"},{world="GT City",mode="Story",diff="Hard",act=7,amount="1x",chance="60%"},{world="GT City",mode="Story",diff="Hard",act=8,amount="1x",chance="60%"} },
        ["Eclipse Godstone"]    = { {world="GT City",mode="Story",diff="Normal",act=9,amount="1x",chance="3%",pity=30},{world="GT City",mode="Story",diff="Normal",act=10,amount="1x",chance="3%",pity=30},{world="GT City",mode="Story",diff="Hard",act=9,amount="1x",chance="6%",pity=15},{world="GT City",mode="Story",diff="Hard",act=10,amount="1x",chance="6%",pity=15} },
        ["Currentbinder Rope"]  = { {world="Marine Lobby",mode="Story",diff="Normal",act=1,amount="2-4x",chance="100%"},{world="Marine Lobby",mode="Story",diff="Normal",act=2,amount="2-4x",chance="100%"},{world="Marine Lobby",mode="Story",diff="Hard",act=1,amount="4-8x",chance="100%"},{world="Marine Lobby",mode="Story",diff="Hard",act=2,amount="4-8x",chance="100%"} },
        ["Depthglass Bottle"]   = { {world="Marine Lobby",mode="Story",diff="Normal",act=3,amount="1-2x",chance="100%"},{world="Marine Lobby",mode="Story",diff="Normal",act=4,amount="1-2x",chance="100%"},{world="Marine Lobby",mode="Story",diff="Hard",act=3,amount="2-4x",chance="100%"},{world="Marine Lobby",mode="Story",diff="Hard",act=4,amount="2-4x",chance="100%"} },
        ["Stormwake Sailcloth"] = { {world="Marine Lobby",mode="Story",diff="Normal",act=5,amount="1x",chance="100%"},{world="Marine Lobby",mode="Story",diff="Normal",act=6,amount="1x",chance="100%"},{world="Marine Lobby",mode="Story",diff="Hard",act=5,amount="2x",chance="100%"},{world="Marine Lobby",mode="Story",diff="Hard",act=6,amount="2x",chance="100%"} },
        ["Beastblood Catalyst"] = { {world="Marine Lobby",mode="Story",diff="Normal",act=7,amount="1x",chance="30%"},{world="Marine Lobby",mode="Story",diff="Normal",act=8,amount="1x",chance="30%"},{world="Marine Lobby",mode="Story",diff="Hard",act=7,amount="1x",chance="60%"},{world="Marine Lobby",mode="Story",diff="Hard",act=8,amount="1x",chance="60%"} },
        ["King's Haki Residue"] = { {world="Marine Lobby",mode="Story",diff="Normal",act=9,amount="1x",chance="3%",pity=30},{world="Marine Lobby",mode="Story",diff="Normal",act=10,amount="1x",chance="3%",pity=30},{world="Marine Lobby",mode="Story",diff="Hard",act=9,amount="1x",chance="6%",pity=15},{world="Marine Lobby",mode="Story",diff="Hard",act=10,amount="1x",chance="6%",pity=15} },
        ["Shinobi Bone"]        = { {world="Ninja Village",mode="Story",diff="Normal",act=1,amount="2-4x",chance="100%"},{world="Ninja Village",mode="Story",diff="Normal",act=2,amount="2-4x",chance="100%"},{world="Ninja Village",mode="Story",diff="Hard",act=1,amount="4-8x",chance="100%"},{world="Ninja Village",mode="Story",diff="Hard",act=2,amount="4-8x",chance="100%"} },
        ["Binding Cloth"]       = { {world="Ninja Village",mode="Story",diff="Normal",act=3,amount="1-2x",chance="100%"},{world="Ninja Village",mode="Story",diff="Normal",act=4,amount="1-2x",chance="100%"},{world="Ninja Village",mode="Story",diff="Hard",act=3,amount="2-4x",chance="100%"},{world="Ninja Village",mode="Story",diff="Hard",act=4,amount="2-4x",chance="100%"} },
        ["Genjutsu Fog Vial"]   = { {world="Ninja Village",mode="Story",diff="Normal",act=5,amount="1x",chance="100%"},{world="Ninja Village",mode="Story",diff="Normal",act=6,amount="1x",chance="100%"},{world="Ninja Village",mode="Story",diff="Hard",act=5,amount="2x",chance="100%"},{world="Ninja Village",mode="Story",diff="Hard",act=6,amount="2x",chance="100%"} },
        ["Fuin Script Paper"]   = { {world="Ninja Village",mode="Story",diff="Normal",act=7,amount="1x",chance="30%"},{world="Ninja Village",mode="Story",diff="Normal",act=8,amount="1x",chance="30%"},{world="Ninja Village",mode="Story",diff="Hard",act=7,amount="1x",chance="60%"},{world="Ninja Village",mode="Story",diff="Hard",act=8,amount="1x",chance="60%"} },
        ["Chakra Fragment"]     = { {world="Ninja Village",mode="Story",diff="Normal",act=9,amount="1x",chance="3%",pity=30},{world="Ninja Village",mode="Story",diff="Normal",act=10,amount="1x",chance="3%",pity=30},{world="Ninja Village",mode="Story",diff="Hard",act=9,amount="1x",chance="6%",pity=15},{world="Ninja Village",mode="Story",diff="Hard",act=10,amount="1x",chance="6%",pity=15} },
        ["Brand Ash"]           = { {world="Eclipse (Before)",mode="Story",diff="Normal",act=5,amount="1x",chance="100%"},{world="Eclipse (Before)",mode="Story",diff="Normal",act=6,amount="1x",chance="100%"},{world="Eclipse (Before)",mode="Story",diff="Hard",act=5,amount="2x",chance="100%"},{world="Eclipse (Before)",mode="Story",diff="Hard",act=6,amount="2x",chance="100%"} },
        ["Moonlit Silver"]      = { {world="Eclipse (Before)",mode="Story",diff="Normal",act=7,amount="1x",chance="30%"},{world="Eclipse (Before)",mode="Story",diff="Normal",act=8,amount="1x",chance="30%"},{world="Eclipse (Before)",mode="Story",diff="Hard",act=7,amount="1x",chance="60%"},{world="Eclipse (Before)",mode="Story",diff="Hard",act=8,amount="1x",chance="60%"} },
        ["Black Sun Amber"]     = { {world="Eclipse (Before)",mode="Story",diff="Normal",act=9,amount="1x",chance="3%",pity=30},{world="Eclipse (Before)",mode="Story",diff="Normal",act=10,amount="1x",chance="3%",pity=30},{world="Eclipse (Before)",mode="Story",diff="Hard",act=9,amount="1x",chance="6%",pity=15},{world="Eclipse (Before)",mode="Story",diff="Hard",act=10,amount="1x",chance="6%",pity=15} },
        ["Zeni"]                = { {world="GT City",mode="Squadron",diff="Normal",act=1,amount="1-2x",chance="50%"},{world="GT City",mode="Squadron",diff="Hard",act=1,amount="1-2x",chance="100%"} },
        ["Scouter"]             = { {world="GT City",mode="Squadron",diff="Normal",act=2,amount="1x",chance="2.5%",pity=50},{world="GT City",mode="Squadron",diff="Hard",act=2,amount="1x",chance="5%",pity=30} },
        ["Power Pole"]          = { {world="GT City",mode="Squadron",diff="Normal",act=3,amount="1x",chance="2.5%",pity=50},{world="GT City",mode="Squadron",diff="Hard",act=3,amount="1x",chance="5%",pity=30} },
        ["Pelli"]               = { {world="Marine Lobby",mode="Squadron",diff="Normal",act=1,amount="1-2x",chance="50%"},{world="Marine Lobby",mode="Squadron",diff="Hard",act=1,amount="1-2x",chance="100%"} },
        ["Bisento"]             = { {world="Marine Lobby",mode="Squadron",diff="Normal",act=2,amount="1x",chance="2.5%",pity=50},{world="Marine Lobby",mode="Squadron",diff="Hard",act=2,amount="1x",chance="5%",pity=30} },
        ["Gryphon"]             = { {world="Marine Lobby",mode="Squadron",diff="Normal",act=3,amount="1x",chance="2.5%",pity=50},{world="Marine Lobby",mode="Squadron",diff="Hard",act=3,amount="1x",chance="5%",pity=30} },
        ["Headband"]            = { {world="Ninja Village",mode="Squadron",diff="Normal",act=1,amount="1-2x",chance="50%"},{world="Ninja Village",mode="Squadron",diff="Hard",act=1,amount="1-2x",chance="100%"} },
        ["Karashi's Book"]      = { {world="Ninja Village",mode="Squadron",diff="Normal",act=2,amount="1x",chance="2.5%",pity=50},{world="Ninja Village",mode="Squadron",diff="Hard",act=2,amount="1x",chance="5%",pity=30} },
        ["Shuriken"]            = { {world="Ninja Village",mode="Squadron",diff="Normal",act=3,amount="1x",chance="2.5%",pity=50},{world="Ninja Village",mode="Squadron",diff="Hard",act=3,amount="1x",chance="5%",pity=30} },
        ["Gunbai"]              = { {world="Ninja Village",mode="Squadron",diff="Normal",act=4,amount="1x",chance="0.5%",pity=200},{world="Ninja Village",mode="Squadron",diff="Hard",act=4,amount="1x",chance="2%",pity=100} },
        ["Madora"]              = { {world="Ninja Village",mode="Squadron",diff="Normal",act=4,amount="1x",chance="0.25%",pity=300},{world="Ninja Village",mode="Squadron",diff="Hard",act=4,amount="1x",chance="0.5%",pity=200} },
        ["Caskas Sword"]        = { {world="Eclipse (Before)",mode="Squadron",diff="Normal",act=2,amount="1x",chance="2.5%",pity=50},{world="Eclipse (Before)",mode="Squadron",diff="Hard",act=2,amount="1x",chance="5%",pity=30} },
        ["Cavalry Saber"]       = { {world="Eclipse (Before)",mode="Squadron",diff="Normal",act=3,amount="1x",chance="2.5%",pity=50},{world="Eclipse (Before)",mode="Squadron",diff="Hard",act=3,amount="1x",chance="5%",pity=30} },
        ["Dragon Slayer (Evo)"] = { {world="Eclipse (Before)",mode="Squadron",diff="Hard",act=4,amount="1x",chance="2%",pity=100} },
        ["Berserker"]           = { {world="Eclipse (Before)",mode="Squadron",diff="Normal",act=4,amount="1x",chance="0.25%",pity=300},{world="Eclipse (Before)",mode="Squadron",diff="Hard",act=4,amount="1x",chance="0.5%",pity=200} },
        ["Behelit"]             = { {world="Eclipse (Before)",mode="Squadron",diff="Normal",act=1,amount="1-2x",chance="50%"},{world="Eclipse (Before)",mode="Squadron",diff="Hard",act=1,amount="1-2x",chance="100%"} },
        ["Dragonballs"]         = { {world="GT City",mode="Raid",diff="Normal",act=4,amount="1x",chance="0.5%",pity=200},{world="GT City",mode="Raid",diff="Hard",act=4,amount="1x",chance="1%",pity=100} },
        ["Shanron"]             = { {world="GT City",mode="Raid",diff="Normal",act=4,amount="1x",chance="0.25%",pity=400},{world="GT City",mode="Raid",diff="Hard",act=4,amount="1x",chance="0.5%",pity=200} },
        ["White Behelit"]       = { {world="Eclipse (Before)",mode="Raid",diff="Normal",act=1,amount="1-2x",chance="50%"},{world="Eclipse (Before)",mode="Raid",diff="Normal",act=2,amount="1-2x",chance="50%"},{world="Eclipse (Before)",mode="Raid",diff="Normal",act=3,amount="1-2x",chance="50%"},{world="Eclipse (Before)",mode="Raid",diff="Normal",act=4,amount="1-2x",chance="50%"},{world="Eclipse (Before)",mode="Raid",diff="Hard",act=1,amount="1-2x",chance="100%"},{world="Eclipse (Before)",mode="Raid",diff="Hard",act=2,amount="1-2x",chance="100%"},{world="Eclipse (Before)",mode="Raid",diff="Hard",act=3,amount="1-2x",chance="100%"},{world="Eclipse (Before)",mode="Raid",diff="Hard",act=4,amount="1-2x",chance="100%"} },
        ["Sword Of Resonance"]  = { {world="Eclipse (Before)",mode="Raid",diff="Normal",act=4,amount="1x",chance="0.5%",pity=200},{world="Eclipse (Before)",mode="Raid",diff="Hard",act=4,amount="1x",chance="1%",pity=100} },
        ["Skeleton Knight"]     = { {world="Eclipse (Before)",mode="Raid",diff="Normal",act=4,amount="1x",chance="0.25%",pity=400},{world="Eclipse (Before)",mode="Raid",diff="Hard",act=4,amount="1x",chance="0.5%",pity=200} },
        ["Narutomaki"]          = { {world="Ninja Village",mode="Squadron",diff="Normal",act=1,amount="4-6x",chance="100%"},{world="Ninja Village",mode="Squadron",diff="Normal",act=2,amount="4-6x",chance="100%"},{world="Ninja Village",mode="Squadron",diff="Normal",act=3,amount="4-6x",chance="100%"},{world="Ninja Village",mode="Squadron",diff="Normal",act=4,amount="4-6x",chance="100%"},{world="Ninja Village",mode="Squadron",diff="Hard",act=1,amount="4-6x",chance="100%"},{world="Ninja Village",mode="Squadron",diff="Hard",act=2,amount="4-6x",chance="100%"},{world="Ninja Village",mode="Squadron",diff="Hard",act=3,amount="4-6x",chance="100%"},{world="Ninja Village",mode="Squadron",diff="Hard",act=4,amount="4-6x",chance="100%"} },
        ["Meat"]                = { {world="Marine Lobby",mode="Squadron",diff="Normal",act=1,amount="4-6x",chance="100%"},{world="Marine Lobby",mode="Squadron",diff="Normal",act=2,amount="4-6x",chance="100%"},{world="Marine Lobby",mode="Squadron",diff="Normal",act=3,amount="4-6x",chance="100%"},{world="Marine Lobby",mode="Squadron",diff="Hard",act=1,amount="4-6x",chance="100%"},{world="Marine Lobby",mode="Squadron",diff="Hard",act=2,amount="4-6x",chance="100%"},{world="Marine Lobby",mode="Squadron",diff="Hard",act=3,amount="4-6x",chance="100%"} },
        ["Senzu"]               = { {world="GT City",mode="Squadron",diff="Normal",act=1,amount="4-6x",chance="100%"},{world="GT City",mode="Squadron",diff="Normal",act=2,amount="4-6x",chance="100%"},{world="GT City",mode="Squadron",diff="Normal",act=3,amount="4-6x",chance="100%"},{world="GT City",mode="Squadron",diff="Hard",act=1,amount="4-6x",chance="100%"},{world="GT City",mode="Squadron",diff="Hard",act=2,amount="4-6x",chance="100%"},{world="GT City",mode="Squadron",diff="Hard",act=3,amount="4-6x",chance="100%"} },
        ["Brand of Sacrifice"]  = { {world="Eclipse (Before)",mode="Squadron",diff="Normal",act=1,amount="4-6x",chance="100%"},{world="Eclipse (Before)",mode="Squadron",diff="Normal",act=2,amount="4-6x",chance="100%"},{world="Eclipse (Before)",mode="Squadron",diff="Normal",act=3,amount="4-6x",chance="100%"},{world="Eclipse (Before)",mode="Squadron",diff="Normal",act=4,amount="4-6x",chance="100%"},{world="Eclipse (Before)",mode="Squadron",diff="Hard",act=1,amount="4-6x",chance="100%"},{world="Eclipse (Before)",mode="Squadron",diff="Hard",act=2,amount="4-6x",chance="100%"},{world="Eclipse (Before)",mode="Squadron",diff="Hard",act=3,amount="4-6x",chance="100%"},{world="Eclipse (Before)",mode="Squadron",diff="Hard",act=4,amount="4-6x",chance="100%"} },
        ["Eclipse Stone"]       = { {world="Eclipse (Before)",mode="Story",diff="Normal",act=3,amount="1-2x",chance="100%"},{world="Eclipse (Before)",mode="Story",diff="Normal",act=4,amount="1-2x",chance="100%"},{world="Eclipse (Before)",mode="Story",diff="Hard",act=3,amount="2-4x",chance="100%"},{world="Eclipse (Before)",mode="Story",diff="Hard",act=4,amount="2-4x",chance="100%"} },
    },
}

NS.gearData = {
    ["Berserker Chestplate"] = { cost={["Eclipse Godstone"]=10,["King's Haki Residue"]=10,["Black Sun Amber"]=10,Gold=5000} },
    ["Berserker Helmet"]     = { cost={["King's Haki Residue"]=10,["Black Sun Amber"]=10,["Chakra Fragment"]=10,Gold=5000} },
    ["Berserker Legs"]       = { cost={["Eclipse Godstone"]=10,["Black Sun Amber"]=10,["Chakra Fragment"]=10,Gold=5000} },
    ["Devil Amulet"]         = { cost={["Fuin Script Paper"]=10,["Limitbreak Obsidian"]=15,["Beastblood Catalyst"]=25,Gold=2500} },
    ["Devil Sword"]          = { cost={["Fuin Script Paper"]=25,["Limitbreak Obsidian"]=15,["Beastblood Catalyst"]=10,Gold=2500} },
    ["Dragon Slayer"]        = { cost={["Eclipse Godstone"]=8,["Black Sun Amber"]=15,["Chakra Fragment"]=8,Gold=5000} },
    ["Hogyoku"]              = { cost={["Fuin Script Paper"]=15,["Limitbreak Obsidian"]=25,["Beastblood Catalyst"]=10,Gold=2500} },
    ["Monarch Daggers"]      = { cost={["Eclipse Godstone"]=10,["King's Haki Residue"]=10,["Chakra Fragment"]=10,Gold=5000} },
    ["Ninja Headband"]       = { cost={["Genjutsu Fog Vial"]=35,["Stormwake Sailcloth"]=50,["Stellar Ki Quartz"]=15,Gold=750} },
    ["Ninja Hoodie"]         = { cost={["Genjutsu Fog Vial"]=50,["Stormwake Sailcloth"]=15,["Stellar Ki Quartz"]=35,Gold=750} },
    ["Ninja Shoes"]          = { cost={["Genjutsu Fog Vial"]=15,["Stormwake Sailcloth"]=35,["Stellar Ki Quartz"]=50,Gold=750} },
    ["Pirate Sandals"]       = { cost={["Depthglass Bottle"]=35,["Binding Cloth"]=15,["Ki Resonant Crystal"]=50,Gold=500} },
    ["Pirate Shirt"]         = { cost={["Depthglass Bottle"]=15,["Binding Cloth"]=50,["Ki Resonant Crystal"]=35,Gold=500} },
    ["Pirate Straw Hat"]     = { cost={["Depthglass Bottle"]=50,["Binding Cloth"]=35,["Ki Resonant Crystal"]=15,Gold=500} },
    ["Puppeteer Coat"]       = { cost={["Fuin Script Paper"]=10,["Limitbreak Obsidian"]=15,["Beastblood Catalyst"]=25,Gold=2500} },
    ["Puppeteer Hair"]       = { cost={["Fuin Script Paper"]=15,["Limitbreak Obsidian"]=25,["Beastblood Catalyst"]=10,Gold=2500} },
    ["Puppeteer Pants"]      = { cost={["Fuin Script Paper"]=25,["Limitbreak Obsidian"]=10,["Beastblood Catalyst"]=15,Gold=2500} },
    ["Saiyan Gi"]            = { cost={["Currentbinder Rope"]=50,["Zenkai Ore"]=35,["Shinobi Bone"]=15,Gold=250} },
    ["Saiyan Hat"]           = { cost={["Currentbinder Rope"]=15,["Zenkai Ore"]=50,["Shinobi Bone"]=35,Gold=250} },
    ["Saiyan Shoes"]         = { cost={["Currentbinder Rope"]=35,["Zenkai Ore"]=15,["Shinobi Bone"]=50,Gold=250} },
}

-- ── Remotes ──────────────────────────────────────────────────────
local function getRemotes()
    local rem   = RS:WaitForChild("Remotes",    10)
    local game_ = rem:WaitForChild("Game",       10)
    local chars = rem:WaitForChild("Characters", 10)
    local plrs  = rem:WaitForChild("Players",    10)
    return {
        next        = game_:WaitForChild("next",         10),  -- RemoteEvent, no args
        replay      = game_:WaitForChild("replay",       10),  -- RemoteEvent, no args
        teleport    = plrs :WaitForChild("teleport",     10),  -- RemoteEvent, no args
        start       = plrs :WaitForChild("start",        10),  -- RemoteEvent, no args
        changeSpeed = game_:WaitForChild("change_speed", 10),  -- RemoteFunction(number) → bool, msg
        autoplay    = chars:WaitForChild("autoplay",     10),  -- RemoteFunction() → bool new-state
        upgrade     = chars:WaitForChild("upgrade",      10),  -- RemoteFunction(name) → bool, newLevel, data
        playersGet  = RS:WaitForChild("Remotes",10):WaitForChild("Players",10):WaitForChild("get",10),  -- RemoteFunction() → playerData
    }
end

-- ── Stage label hook ─────────────────────────────────────────────
local function setupStageLabelHook(player)
    if NS.stageLabelConn then
        NS.stageLabelConn:Disconnect()
        NS.stageLabelConn = nil
        log("Old stage label connection removed")
    end

    local node = player
    for _, name in ipairs({ "PlayerGui", "Hotbar", "Info", "World", "TextLabel" }) do
        local child = node:WaitForChild(name, 15)
        if not child then
            log("Stage label path missing at: " .. name)
            return
        end
        node = child
    end

    local label = node

    local function parseLabel()
        local result = Parser.parse(label.Text)
        if result then
            State.set("stage", result.stageName)
            State.set("act",   result.act)
            log("Stage → " .. result.stageName .. " | Act " .. result.act)
        else
            log("Stage label parse failed (raw: " .. tostring(label.Text) .. ")")
        end
    end

    parseLabel()
    NS.stageLabelConn = label:GetPropertyChangedSignal("Text"):Connect(parseLabel)
    log("Stage label hook active")
end

-- ── Evo helpers (defined early so setupEndScreenHook can use them) ─
local function computeMissing(cost, inventory)
    local missing = {}
    for mat, needed in pairs(cost) do
        if (inventory[mat] or 0) < needed then
            missing[mat] = needed - (inventory[mat] or 0)
        end
    end
    return missing
end

-- ── EndScreen hook ───────────────────────────────────────────────
local function setupEndScreenHook(player, remotes)
    if NS.endScreenConn then
        NS.endScreenConn:Disconnect()
        NS.endScreenConn = nil
        log("Old EndScreen connection removed")
    end

    local endScreen = player
        :WaitForChild("PlayerGui", 15)
        :WaitForChild("Menus",     15)
        :WaitForChild("EndScreen", 15)

    if not endScreen then
        log("EndScreen not found — hook aborted")
        return
    end

    NS.endScreenConn = endScreen:GetPropertyChangedSignal("Visible"):Connect(function()
        if not endScreen.Visible then return end

        task.wait(0.15)

        local header     = endScreen:FindFirstChild("Header1")
        local resultText = header and header:FindFirstChild("TextLabel") and header.TextLabel.Text or ""
        local stage      = State.get("stage")
        local act        = State.get("act")
        local elapsed    = nil

        if resultText == "Victory!" then
            log("Result: VICTORY")
            local playTimeLbl = endScreen:FindFirstChild("Left")
                and endScreen.Left:FindFirstChild("PlayTime")
                and endScreen.Left.PlayTime:FindFirstChild("Amount")
            elapsed = playTimeLbl and ClearTime.parseLabel(playTimeLbl.Text)
            if stage and act and elapsed then
                ClearTime.update(stage, act, elapsed)
            elseif stage and act then
                log("Clear time: could not read Play Time label")
            end
        elseif resultText == "Defeat!" then
            log("Result: DEFEAT")
        else
            log("Result: UNKNOWN ('" .. resultText .. "')")
        end

        -- Pull player data once — reused by both webhook and evo check
        local pd = nil
        local needPd = (resultText == "Victory!" and (
                NS.settings.webhookOnVictory
                or (NS.settings.autoEvo and NS.settings.evoTargets and #NS.settings.evoTargets > 0)
            ))
            or (resultText == "Defeat!" and NS.settings.webhookOnDefeat)
        if needPd then
            local ok2, result = pcall(function() return remotes.playersGet:InvokeServer() end)
            if ok2 and result then pd = result
            else log("Webhook/Evo: player data fetch failed") end
        end

        -- Stage summary webhook (Victory or Defeat)
        if (resultText == "Victory!" and NS.settings.webhookOnVictory)
            or (resultText == "Defeat!" and NS.settings.webhookOnDefeat) then
            local ok3, matchesText = pcall(function()
                return player.PlayerGui.Hotbar.Menus.Stage.Stats.Played.Amount.Text
            end)
            local runCount = ok3 and matchesText or "?"
            sendWebhookEmbed(buildStageEmbed(resultText, stage, act, elapsed, pd, runCount))
        end

        -- Evo check: return to lobby if all mats collected
        if resultText == "Victory!"
            and NS.settings.autoEvo
            and NS.settings.evoTargets and #NS.settings.evoTargets > 0
            and NS.data and NS.data.awaken then
            local targetName = NS.settings.evoTargets[1]
            local awData = NS.data.awaken[targetName]
            if awData and pd then
                local missing = computeMissing(awData.cost, pd.items or {})
                -- Check for newly completed mats this run and ping once per mat
                NS.evoNotifiedMats = NS.evoNotifiedMats or {}
                local inv = pd.items or {}
                for mat, needed in pairs(awData.cost) do
                    if (inv[mat] or 0) >= needed and not NS.evoNotifiedMats[mat] then
                        NS.evoNotifiedMats[mat] = true
                        if NS.settings.webhookOnEvoReady then
                            sendWebhook(evoPing() .. "✅ **" .. mat .. "** x" .. needed .. " collected for **" .. targetName .. "**!")
                        end
                    end
                end

                if not next(missing) then
                    log("Evo: all materials for " .. targetName .. " collected! Returning to lobby.")
                    if NS.settings.webhookOnEvoReady then
                        sendWebhook(evoPing() .. "🎉 Evo ready! **" .. targetName .. "** has all materials — ready to awaken!")
                    end
                    NS.evoFarmStage = nil
                    NS.evoNotifiedMats = nil
                    remotes.teleport:FireServer()
                    return
                else
                    local parts = {}
                    for mat, amt in pairs(missing) do table.insert(parts, mat .. " x" .. amt) end
                    log("Evo: still need: " .. table.concat(parts, ", "))

                    -- Check if current stage drops ANY remaining mat; leave if not so lobby can re-route
                    local currentWorld = State.get("stage")
                    local currentAct   = State.get("act")
                    local stillUseful  = false
                    if currentWorld and currentAct and NS.data.matmap then
                        for mat in pairs(missing) do
                            local locs = NS.data.matmap[mat]
                            if locs then
                                for _, loc in ipairs(locs) do
                                    if loc.world == currentWorld and loc.act == currentAct then
                                        stillUseful = true
                                        break
                                    end
                                end
                            end
                            if stillUseful then break end
                        end
                    end
                    if not stillUseful then
                        log("Evo: current stage drops nothing needed — returning to lobby to re-route")
                        remotes.teleport:FireServer()
                        return
                    end
                end
            elseif not pd then
                log("Evo: inventory check failed")
            end
        end

        -- Gear check (same logic as evo)
        if resultText == "Victory!"
            and NS.settings.autoGear
            and NS.settings.gearTargets and #NS.settings.gearTargets > 0
            and NS.gearData and pd then
            local targetName = NS.settings.gearTargets[1]
            local gData = NS.gearData[targetName]
            if gData then
                local missing = computeMissing(gData.cost, pd.items or {})
                -- Ping for newly completed mats
                NS.gearNotifiedMats = NS.gearNotifiedMats or {}
                for mat, needed in pairs(gData.cost) do
                    if (pd.items[mat] or 0) >= needed and not NS.gearNotifiedMats[mat] then
                        NS.gearNotifiedMats[mat] = true
                        if NS.settings.webhookOnEvoReady then
                            sendWebhook(evoPing() .. "✅ **" .. mat .. "** x" .. needed .. " collected for **" .. targetName .. "**!")
                        end
                    end
                end
                if not next(missing) then
                    log("Gear: all materials for " .. targetName .. " collected — ready to craft!")
                    if NS.settings.webhookOnEvoReady then
                        sendWebhook(evoPing() .. "🎉 **" .. targetName .. "** has all materials — ready to craft!")
                    end
                    NS.gearFarmStage  = nil
                    NS.gearNotifiedMats = nil
                    remotes.teleport:FireServer()
                    return
                else
                    local currentWorld = State.get("stage")
                    local currentAct   = State.get("act")
                    local stillUseful  = false
                    if currentWorld and currentAct and NS.data and NS.data.matmap then
                        for mat in pairs(missing) do
                            local locs = NS.data.matmap[mat]
                            if locs then
                                for _, loc in ipairs(locs) do
                                    if loc.world == currentWorld and loc.act == currentAct then
                                        stillUseful = true; break
                                    end
                                end
                            end
                            if stillUseful then break end
                        end
                    end
                    if not stillUseful then
                        log("Gear: current stage drops nothing needed — returning to lobby to re-route")
                        remotes.teleport:FireServer()
                        return
                    end
                end
            end
        end

        -- Re-snapshot inventory so next stage's diff only shows that run's gains
        task.spawn(function()
            local snapOk, snap = pcall(function() return remotes.playersGet:InvokeServer() end)
            if snapOk and snap then NS.preStageInventory = snap.items or {} end
        end)

    end)

    log("EndScreen hook active")
end

-- ── Farm loop ────────────────────────────────────────────────────
-- Loops all farm remotes at a fixed rate. Server-side validation means each remote
-- is a no-op when the game state doesn't allow it.
local function setupFarmLoop(player, remotes)
    NS.farmLoopGen = (NS.farmLoopGen or 0) + 1
    local myGen = NS.farmLoopGen

    task.spawn(function()
        while NS.farmLoopGen == myGen do
            -- Auto Start: server no-ops if not on the ready screen
            if NS.settings.autoStart then
                pcall(function() remotes.start:FireServer() end)
            end

            -- Auto Max Speed: try highest speed; server rejects if game not started yet
            if NS.settings.autoMaxSpeed then
                pcall(function()
                    local speedFrame = player.PlayerGui.Menus.Speed.Speed
                    local speeds = {}
                    for _, b in ipairs(speedFrame:GetChildren()) do
                        local n = tonumber(b.Name)
                        if n then table.insert(speeds, n) end
                    end
                    table.sort(speeds, function(a, b) return a > b end)
                    for _, speed in ipairs(speeds) do
                        local ok, msg = remotes.changeSpeed:InvokeServer(speed)
                        if ok then log("Speed → " .. speed .. "x"); break end
                    end
                end)
            end

            -- End-screen actions: next → replay → leave
            if NS.settings.autoNext then
                pcall(function() remotes.next:FireServer() end)
            elseif NS.settings.autoReplay then
                pcall(function()
                    local endScreen = player.PlayerGui.Menus:FindFirstChild("EndScreen")
                    if endScreen and endScreen.Visible then
                        remotes.replay:FireServer()
                    end
                end)
            elseif NS.settings.autoLeave then
                -- teleport goes to lobby at any time, so only fire when the end screen is up
                pcall(function()
                    local endScreen = player.PlayerGui.Menus:FindFirstChild("EndScreen")
                    if endScreen and endScreen.Visible then
                        remotes.teleport:FireServer()
                    end
                end)
            end

            task.wait(0.5)
        end
    end)

    log("Farm loop active")
end

-- ── 30-min challenge return timer ────────────────────────────────
-- Fires teleport at XX:00 and XX:30 so you can catch the challenge reset.
-- Uses a generation counter so re-running the script kills the old loop.
local function startChallengeReturnTimer(remotes)
    NS.challengeTimerGen = (NS.challengeTimerGen or 0) + 1
    local myGen   = NS.challengeTimerGen
    local lastFired = 0

    task.spawn(function()
        while NS.challengeTimerGen == myGen do
            task.wait(1)
            if not NS.settings.challengeReturn30 then continue end

            local t = os.time()
            -- secondsIntoHalfHour: 0-1799; fire within the first 8s of each 30-min window
            local secondsIntoHalfHour = t % 1800
            if secondsIntoHalfHour < 8 and (t - lastFired) > 60 then
                lastFired = t
                log("30-min reset — leaving to lobby for challenge")
                pcall(function() remotes.teleport:FireServer() end)
            end
        end
    end)

    log("30-min challenge return timer active")
end

-- ── Lobby remotes ────────────────────────────────────────────────
local function getLobbyRemotes()
    local rem    = RS:WaitForChild("Remotes", 10)
    local play   = rem:WaitForChild("Play",          10)
    local quests = rem:WaitForChild("Quests",        10)
    local summon = rem:WaitForChild("Summon",        10)
    local shops  = rem:WaitForChild("Shops",         10)
    return {
        -- Auto Join
        createRoom    = play  :WaitForChild("create_room",    10),
        start         = play  :WaitForChild("start",          10),
        getChallenges = play  :WaitForChild("get_challenges", 10),
        -- Claim
        claimAll      = quests:WaitForChild("claim_all",      10),  -- () → bool, data
        getSpecials   = quests:WaitForChild("get_specials",   10),  -- () → {packName→{quests}}
        claimSpecial  = quests:WaitForChild("claim_special",  10),  -- (packName, idx) → bool, data
        -- Summon / Auto Sell
        summonStart   = summon:WaitForChild("start",          10),  -- (banner, count) → bool, data
        autoSell      = summon:WaitForChild("auto_sell",      10),  -- (typeName) → bool, enabledList
        -- Shops
        shopsGet      = shops :WaitForChild("get",            10),  -- (shopId) → itemTable
        shopsBuy      = shops :WaitForChild("buy",            10),  -- (item, shopId, amount) → bool, data
        -- Evo
        playerGet     = rem  :WaitForChild("Player",          10):WaitForChild("get",    10),  -- () → full playerData incl. items + characters
    }
end

-- ── Auto Join ────────────────────────────────────────────────────
local function tryJoinMode(lobbyRemotes, cfg)
    -- Build the config table the server expects
    local config
    if cfg.mode == "Challenge" then
        local ok0, challenges = pcall(function() return lobbyRemotes.getChallenges:InvokeServer() end)
        if not ok0 or not challenges then
            log("Auto Join: get_challenges failed")
            return false
        end
        local key = (cfg.challengeType == "daily") and "1d" or "30m"
        local c   = challenges[key]
        if not c then
            log("Auto Join: no " .. key .. " challenge available")
            return false
        end
        config = { world=c.world, act=c.act, mode="Challenge", difficulty=key }
    elseif cfg.mode == "Infinite" then
        config = { world="Katakara Wasteland", act=1, mode="Infinite", difficulty="Hard", boosted=cfg.boosted or false }
    else
        -- Story, Squadron, Raid, Permanent
        config = { world=cfg.world, act=cfg.act, mode=cfg.mode, difficulty=cfg.difficulty or "Normal" }
    end

    -- Step 1: create room
    local ok1, success1, serverErr = pcall(function()
        return lobbyRemotes.createRoom:InvokeServer(config)
    end)
    if not ok1 then
        log("Auto Join: create_room threw — " .. tostring(success1))
        return false
    end
    if not success1 then
        log("Auto Join: " .. cfg.mode .. " create_room rejected — " .. tostring(serverErr))
        return false
    end

    -- Step 2: start solo
    task.wait(0.5)
    local ok2, started, startErr = pcall(function()
        return lobbyRemotes.start:InvokeServer()
    end)
    if not ok2 then
        log("Auto Join: start threw — " .. tostring(started))
        return false
    end
    if not started then
        log("Auto Join: start rejected — " .. tostring(startErr))
        return false
    end

    log("Auto Join: " .. cfg.mode .. " started")
    NS.currentDifficulty = (cfg.mode == "Infinite") and "Hard" or (cfg.difficulty or "Normal")
    return true
end

local function attemptAutoJoin(lobbyRemotes)
    local enabled = {}
    for _, cfg in ipairs(NS.settings.joinModes) do
        if cfg.enabled then table.insert(enabled, cfg) end
    end
    if #enabled == 0 then
        log("Auto Join: no modes enabled")
        return false
    end
    table.sort(enabled, function(a, b) return (a.priority or 99) < (b.priority or 99) end)
    for _, cfg in ipairs(enabled) do
        log("Auto Join: trying " .. cfg.mode)
        if tryJoinMode(lobbyRemotes, cfg) then
            log("Auto Join: queued for " .. cfg.mode)
            return true
        end
        log("Auto Join: " .. cfg.mode .. " rejected — trying next")
    end
    log("Auto Join: all enabled modes rejected")
    return false
end

-- ── Lobby actions (run once on lobby load) ───────────────────────
local SELL_TYPES = {"Rare", "Epic", "Legendary", "Mythic"}

local function runClaim(lr)
    if NS.settings.autoClaimQuests then
        local ok, success, msg = pcall(function() return lr.claimAll:InvokeServer() end)
        if ok and success then log("Claim: quests claimed")
        elseif ok then log("Claim: " .. tostring(msg)) end
    end

    if NS.settings.autoClaimSpecial then
        local ok, specials = pcall(function() return lr.getSpecials:InvokeServer() end)
        if ok and specials then
            for packName, pack in pairs(specials) do
                for idx, _ in pairs(pack.quests or {}) do
                    local ok2, success2 = pcall(function()
                        return lr.claimSpecial:InvokeServer(packName, tostring(idx))
                    end)
                    if ok2 and success2 then
                        log("Claim special: " .. packName .. " #" .. idx)
                    end
                end
            end
        end
    end
end

local function runAutoSell(lr)
    if not NS.settings.autoSell or #NS.settings.autoSell == 0 then return end
    local desired = {}
    for _, t in ipairs(NS.settings.autoSell) do desired[t] = true end
    -- Each InvokeServer(type) toggles that rarity and returns the new state (bool).
    -- Toggle until the returned state matches what we want (max 2 attempts).
    for _, t in ipairs(SELL_TYPES) do
        local want = desired[t] == true
        for _ = 1, 2 do
            local ok, state = pcall(function() return lr.autoSell:InvokeServer(t) end)
            if ok and state == want then break end
        end
    end
end

local function runAutoSummon(lr)
    if not NS.settings.autoSummon then return end
    local banner = NS.settings.summonBanner
    local amount = NS.settings.summonAmount
    local total  = 0
    local SAFETY = 500
    while NS.settings.autoSummon and total < SAFETY do
        local ok, success = pcall(function() return lr.summonStart:InvokeServer(banner, amount) end)
        if ok and success then
            total = total + amount
            task.wait(0.3)
        else
            break
        end
    end
    if total > 0 then log("Summon: " .. total .. "x on " .. banner) end
end

local function runShopBuy(lr, shopId, itemTable)
    if not itemTable or not next(itemTable) then return end
    local ok, shopData = pcall(function() return lr.shopsGet:InvokeServer(shopId) end)
    if not ok or not shopData then return end
    for itemName, wantAmt in pairs(itemTable) do
        if wantAmt > 0 and shopData[itemName] then
            local ok2, success, msg = pcall(function()
                return lr.shopsBuy:InvokeServer(itemName, shopId, wantAmt)
            end)
            if ok2 and success then
                log("Shop " .. shopId .. ": bought " .. wantAmt .. "x " .. itemName)
            elseif ok2 then
                log("Shop " .. shopId .. ": " .. itemName .. " — " .. tostring(msg))
            end
        end
    end
end

-- ── Evo Mats Orchestrator ────────────────────────────────────────
local function bestFarmStage(missing)
    local stageMap = {}
    for mat in pairs(missing) do
        local locs = NS.data and NS.data.matmap and NS.data.matmap[mat]
        if locs then
            for _, loc in ipairs(locs) do
                local key = loc.world.."|"..loc.mode.."|"..loc.diff.."|"..tostring(loc.act)
                if not stageMap[key] then
                    stageMap[key] = {world=loc.world, mode=loc.mode, diff=loc.diff, act=loc.act, score=0, mats={}}
                end
                local diffBonus = loc.diff == "Hard" and 2 or 1
                local chanceNum = tonumber(tostring(loc.chance):match("^(%d+)")) or 1
                stageMap[key].score = stageMap[key].score + diffBonus * chanceNum
                table.insert(stageMap[key].mats, mat)
            end
        end
    end
    local best = nil
    for _, s in pairs(stageMap) do
        if not best or s.score > best.score then best = s end
    end
    return best
end

local function runGearOrchestrator(lr)
    if not NS.settings.autoGear then return end
    if not NS.gearData then log("Gear: data not loaded"); return end
    if not NS.settings.gearTargets or #NS.settings.gearTargets == 0 then return end

    local ok, playerData = pcall(function() return lr.playerGet:InvokeServer() end)
    if not ok or not playerData then log("Gear: failed to get player data"); return end

    local inventory = playerData.items or {}

    NS.gearFarmStage = nil

    for _, targetName in ipairs(NS.settings.gearTargets) do
        local gData = NS.gearData[targetName]
        if not gData then
            log("Gear: no data for " .. targetName)
        else
            local missing = computeMissing(gData.cost, inventory)
            if not next(missing) then
                log("Gear: " .. targetName .. " has all materials — ready to craft!")
            else
                local parts = {}
                for mat, amt in pairs(missing) do table.insert(parts, mat .. " x" .. amt) end
                log("Gear: " .. targetName .. " needs: " .. table.concat(parts, ", "))
                local best = bestFarmStage(missing)
                if best then
                    NS.gearFarmStage = best
                    local matList = table.concat(best.mats, ", ")
                    log("Gear: farm → " .. best.world .. " " .. best.mode .. " " .. best.diff .. " act " .. best.act .. " [" .. matList .. "]")
                else
                    log("Gear: no farmable stage for missing mats")
                end
                break
            end
        end
    end
end

local function runEvoOrchestrator(lr)
    if not NS.settings.autoEvo then return end
    if not NS.data then log("Evo: data not loaded"); return end
    if not NS.settings.evoTargets or #NS.settings.evoTargets == 0 then return end

    local ok, playerData = pcall(function() return lr.playerGet:InvokeServer() end)
    if not ok or not playerData then log("Evo: failed to get player data"); return end

    local inventory = playerData.items or {}

    NS.evoFarmStage = nil

    for _, targetName in ipairs(NS.settings.evoTargets) do
        local awData = NS.data.awaken[targetName]
        if not awData then
            log("Evo: no awaken data for " .. targetName)
        else
            local missing = computeMissing(awData.cost, inventory)
            if not next(missing) then
                log("Evo: " .. targetName .. " has all materials — ready to awaken manually!")
            else
                local parts = {}
                for mat, amt in pairs(missing) do table.insert(parts, mat .. " x" .. amt) end
                log("Evo: " .. targetName .. " needs: " .. table.concat(parts, ", "))
                local best = bestFarmStage(missing)
                if best then
                    NS.evoFarmStage = best
                    local matList = table.concat(best.mats, ", ")
                    log("Evo: farm → " .. best.world .. " " .. best.mode .. " " .. best.diff .. " act " .. best.act .. " [" .. matList .. "]")
                else
                    log("Evo: no farmable stage for missing mats — may need event/unknown-source items")
                end
                break
            end
        end
    end
end

local function runLobbyActions(lr)
    runEvoOrchestrator(lr)
    runGearOrchestrator(lr)  -- run first so farm stages are set before autoJoin loop starts
    task.wait(1.5)
    runClaim(lr)
    runAutoSell(lr)
    if NS.settings.autoRaidShop  then runShopBuy(lr, "gt_city_raid", NS.settings.raidShopBuy)  end
    if NS.settings.autoMerchant  then runShopBuy(lr, "merchant",     NS.settings.merchantBuy)   end
end

-- ── Lobby setup ──────────────────────────────────────────────────
local function setupLobby()
    local ok, err = pcall(function()
        local lobbyRemotes = getLobbyRemotes()

        NS.autoJoinGen = (NS.autoJoinGen or 0) + 1
        local myGen = NS.autoJoinGen

        task.spawn(function() runLobbyActions(lobbyRemotes) end)

        -- Summon loop: runs continuously while autoSummon is enabled
        NS.summonGen = (NS.summonGen or 0) + 1
        local mySummonGen = NS.summonGen
        task.spawn(function()
            while NS.summonGen == mySummonGen do
                if NS.settings.autoSummon then
                    runAutoSummon(lobbyRemotes)
                end
                task.wait(2)
            end
        end)

        task.spawn(function()
            task.wait(3)  -- let runLobbyActions finish before first join attempt
            while NS.autoJoinGen == myGen do
                -- Re-run orchestrators every loop so enabling toggles mid-session works
                runEvoOrchestrator(lobbyRemotes)
                runGearOrchestrator(lobbyRemotes)
                if NS.settings.autoEvo and NS.evoFarmStage then
                    local fs = NS.evoFarmStage
                    if tryJoinMode(lobbyRemotes, { mode=fs.mode, world=fs.world, act=fs.act, difficulty=fs.diff }) then break end
                elseif NS.settings.autoGear and NS.gearFarmStage then
                    local fs = NS.gearFarmStage
                    if tryJoinMode(lobbyRemotes, { mode=fs.mode, world=fs.world, act=fs.act, difficulty=fs.diff }) then break end
                else
                    if attemptAutoJoin(lobbyRemotes) then break end
                end
                task.wait(10)
            end
        end)
    end)
    if not ok then log("Lobby setup error: " .. tostring(err)) end
end

-- ── Auto Upgrade ─────────────────────────────────────────────────
local function setupAutoUpgrade(remotes)
    NS.autoUpgradeGen = (NS.autoUpgradeGen or 0) + 1
    local myGen = NS.autoUpgradeGen

    task.spawn(function()
        while NS.autoUpgradeGen == myGen do
            if NS.settings.autoUpgrade then
                local ok, data = pcall(function() return remotes.playersGet:InvokeServer() end)
                if ok and data then
                    -- Build slot→name map from equipped characters
                    local slotToName = {}
                    for _, c in pairs(data.characters or {}) do
                        if c.equipped then slotToName[c.index] = c.name end
                    end

                    -- Collect enabled slots sorted by priority
                    local slots = {}
                    for _, s in ipairs(NS.settings.upgradeSlots) do
                        if s.priority > 0 and slotToName[s.slot] then
                            table.insert(slots, { slot=s.slot, priority=s.priority, name=slotToName[s.slot] })
                        end
                    end
                    table.sort(slots, function(a, b) return a.priority < b.priority end)

                    local anyUpgraded = false
                    if NS.settings.upgradeMode == "max" then
                        -- Fully upgrade highest-priority slot before moving to next
                        for _, s in ipairs(slots) do
                            if NS.autoUpgradeGen ~= myGen then break end
                            local didUpgrade = true
                            while didUpgrade and NS.autoUpgradeGen == myGen and NS.settings.autoUpgrade do
                                local ok2, success = pcall(function() return remotes.upgrade:InvokeServer(s.name) end)
                                if ok2 and success then
                                    anyUpgraded = true
                                    task.wait(0.5)
                                else
                                    didUpgrade = false
                                end
                            end
                        end
                    else
                        -- "cheapest": one upgrade per slot per pass in priority order
                        for _, s in ipairs(slots) do
                            if NS.autoUpgradeGen ~= myGen then break end
                            local ok2, success = pcall(function() return remotes.upgrade:InvokeServer(s.name) end)
                            if ok2 and success then anyUpgraded = true end
                            task.wait(0.5)
                        end
                    end
                end
            end
            task.wait(0.1)
        end
    end)
    log("Auto Upgrade loop active")
end

-- ── Ingame setup ─────────────────────────────────────────────────
local function setupIngame()
    local player = Players.LocalPlayer
    if not player then
        log("Waiting for LocalPlayer...")
        player = Players.PlayerAdded:Wait()
    end

    local ok, err = pcall(function()
        local remotes = getRemotes()
        -- Snapshot inventory immediately on ingame load (before any drops occur)
        task.spawn(function()
            local snapOk, snap = pcall(function() return remotes.playersGet:InvokeServer() end)
            NS.preStageInventory = (snapOk and snap and snap.items) or {}
            log("Inventory snapshot taken (" .. tostring(snapOk) .. ")")
        end)
        setupStageLabelHook(player)
        setupEndScreenHook(player, remotes)
        setupFarmLoop(player, remotes)
        startChallengeReturnTimer(remotes)
        setupAutoUpgrade(remotes)
    end)

    if not ok then
        log("Ingame setup error: " .. tostring(err))
    end
end

-- ── GUI ──────────────────────────────────────────────────────────
local function setupGUI()
    -- Destroy any existing GUI from a previous execute
    if NS.guiWindow then
        pcall(function() NS.guiWindow:Destroy() end)
        NS.guiWindow = nil
    end

    local ok, Fluent = pcall(function()
        return loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
    end)
    if not ok or not Fluent then
        log("GUI: failed to load Fluent — " .. tostring(Fluent))
        return
    end

    local Window = Fluent:CreateWindow({
        Title       = "Anime Squadron",
        SubTitle    = "auto-farm",
        TabWidth    = 160,
        Size        = UDim2.fromOffset(580, 460),
        Acrylic     = true,
        Theme       = "Dark",
        MinimizeKey = Enum.KeyCode.RightControl,
    })

    local Tabs = {
        Farm    = Window:AddTab({ Title = "Farm",    Icon = "swords"        }),
        Evo     = Window:AddTab({ Title = "Evo",     Icon = "star"          }),
        Gear    = Window:AddTab({ Title = "Gear",    Icon = "hammer"        }),
        Units   = Window:AddTab({ Title = "Units",   Icon = "shield"        }),
        Join    = Window:AddTab({ Title = "Join",    Icon = "map-pin"       }),
        Loot    = Window:AddTab({ Title = "Loot",    Icon = "package"       }),
        Shops    = Window:AddTab({ Title = "Shops",    Icon = "shopping-cart" }),
        Webhook  = Window:AddTab({ Title = "Webhook",  Icon = "bell"          }),
        Priority = Window:AddTab({ Title = "Priority", Icon = "list"          }),
    }

    local function addToggle(tab, key, title, desc)
        local t = tab:AddToggle(key, { Title = title, Description = desc, Default = NS.settings[key] == true })
        t:OnChanged(function()
            NS.settings[key] = t.Value
            State.saveSettings()
        end)
        return t
    end

    -- ── Farm ─────────────────────────────────────────────────────
    addToggle(Tabs.Farm, "autoStart",         "Auto Start",              "Fire start when the ready screen appears")
    addToggle(Tabs.Farm, "autoMaxSpeed",      "Auto Max Speed",          "Set highest available speed on game start")
    addToggle(Tabs.Farm, "autoNext",          "Auto Next",               "Advance to next act on victory")
    addToggle(Tabs.Farm, "autoReplay",        "Auto Replay",             "Replay the same act on victory")
    addToggle(Tabs.Farm, "autoLeave",         "Auto Leave",              "Teleport to lobby if no other action fires")
    addToggle(Tabs.Farm, "challengeReturn30", "30-min Challenge Return", "Leave to lobby at XX:00 and XX:30 for challenge reset")

    -- ── Evo ──────────────────────────────────────────────────────
    addToggle(Tabs.Evo, "autoEvo", "Auto Evo", "Farm materials for the target unit, then notify when ready to awaken")

    local _evoUnitList = {}
    if NS.data and NS.data.awaken then
        for unitName in pairs(NS.data.awaken) do
            table.insert(_evoUnitList, unitName)
        end
        table.sort(_evoUnitList)
    end

    local _evoCurTarget = NS.settings.evoTargets and NS.settings.evoTargets[1] or (_evoUnitList[1] or "")
    local evoDd = Tabs.Evo:AddDropdown("evoTarget1", {
        Title      = "Evo Target",
        Values     = _evoUnitList,
        Default    = _evoCurTarget,
        Multi      = false,
        Searchable = true,
    })
    evoDd:OnChanged(function(Value)
        NS.settings.evoTargets = Value and Value ~= "" and { Value } or {}
        State.saveSettings()
    end)

    -- ── Gear ──────────────────────────────────────────────────────
    addToggle(Tabs.Gear, "autoGear", "Auto Gear", "Farm materials for the target gear piece, then notify when ready to craft")

    local _gearList = {}
    if NS.gearData then
        for gearName in pairs(NS.gearData) do
            table.insert(_gearList, gearName)
        end
        table.sort(_gearList)
    end

    local _gearCurTarget = NS.settings.gearTargets and NS.settings.gearTargets[1] or (_gearList[1] or "")
    local gearDd = Tabs.Gear:AddDropdown("gearTarget1", {
        Title      = "Gear Target",
        Values     = _gearList,
        Default    = _gearCurTarget,
        Multi      = false,
        Searchable = true,
    })
    gearDd:OnChanged(function(Value)
        NS.settings.gearTargets = Value and Value ~= "" and { Value } or {}
        State.saveSettings()
    end)

    -- ── Units ─────────────────────────────────────────────────────
    addToggle(Tabs.Units, "autoUpgrade", "Auto Upgrade", "Automatically spend Yen to upgrade equipped units")

    local upgradeModeDd = Tabs.Units:AddDropdown("upgradeMode", {
        Title       = "Upgrade Mode",
        Description = "Max: fully upgrade one slot before moving on. Cheapest: one upgrade per slot in rotation.",
        Values      = { "max", "cheapest" },
        Multi       = false,
        Default     = NS.settings.upgradeMode or "max",
    })
    upgradeModeDd:OnChanged(function(Value)
        NS.settings.upgradeMode = Value
        State.saveSettings()
    end)

    for i = 1, 6 do
        local slotIdx = i
        local curPriority = 0
        for _, s in ipairs(NS.settings.upgradeSlots) do
            if s.slot == slotIdx then curPriority = s.priority; break end
        end
        local sl = Tabs.Units:AddSlider("upgradeSlot" .. slotIdx, {
            Title       = "Slot " .. slotIdx .. " Priority",
            Description = "0 = disabled. Lower number upgraded first.",
            Default     = curPriority,
            Min         = 0,
            Max         = 6,
            Rounding    = 0,
        })
        sl:OnChanged(function(Value)
            for _, s in ipairs(NS.settings.upgradeSlots) do
                if s.slot == slotIdx then s.priority = Value; break end
            end
            State.saveSettings()
        end)
    end

    -- ── Join ──────────────────────────────────────────────────────
    -- Load act counts per mode+world from RS data modules
    local _JOIN_ACT_DATA = {}
    pcall(function()
        local WD = game:GetService("ReplicatedStorage").Shared.Worlds_Data
        for _, mod in ipairs(WD:GetChildren()) do
            if mod.ClassName == "ModuleScript" and mod.Name ~= "Challenge Data" then
                local ok, data = pcall(require, mod)
                if ok and data and data.bosses then
                    local worldName = mod.Name:gsub(" Data$", "")
                    for modeName, bossTable in pairs(data.bosses) do
                        local maxAct = 0
                        for _, actNums in pairs(bossTable) do
                            if type(actNums) == "table" then
                                for _, n in pairs(actNums) do
                                    if type(n) == "number" and n > maxAct then maxAct = n end
                                end
                            end
                        end
                        _JOIN_ACT_DATA[modeName] = _JOIN_ACT_DATA[modeName] or {}
                        _JOIN_ACT_DATA[modeName][worldName] = maxAct
                    end
                end
            end
        end
    end)

    -- Permanent worlds are keyed as "challenge" in the RS data modules
    local _MODE_DATA_KEY = {
        story="story", squadron="squadron", raid="raid",
        infinite="infinite", permanent="challenge",
    }

    local function buildActList(modeName, worldName)
        local key = _MODE_DATA_KEY[modeName:lower()] or modeName:lower()
        local d   = _JOIN_ACT_DATA[key]
        local max = (d and worldName and d[worldName]) or 10
        local t   = {}
        for i = 1, max do t[i] = tostring(i) end
        return t
    end

    local _JOIN_STORY_WORLDS     = {"GT City","Marine Lobby","Ninja Village","Eclipse (Before)"}
    local _JOIN_RAID_WORLDS      = {"GT City","Eclipse (Before)"}
    local _JOIN_INFINITE_WORLDS  = {"Katakara Wasteland"}
    local _JOIN_PERMANENT_WORLDS = {"Katakara Bridge","The Hero Hunter"}
    local _JOIN_DIFFS            = {"Normal","Hard"}

    local _JOIN_MODE_DEFS = {
        { mode="Story",     worlds=_JOIN_STORY_WORLDS,     hasAct=true,  hasDiff=true,  hasBoost=false },
        { mode="Squadron",  worlds=_JOIN_STORY_WORLDS,     hasAct=true,  hasDiff=true,  hasBoost=false },
        { mode="Raid",      worlds=_JOIN_RAID_WORLDS,      hasAct=true,  hasDiff=true,  hasBoost=false },
        { mode="Challenge", worlds=nil,                    hasAct=false, hasDiff=false, hasBoost=false },
        { mode="Infinite",  worlds=nil,                    hasAct=false, hasDiff=false, hasBoost=true  },
        { mode="Permanent", worlds=_JOIN_PERMANENT_WORLDS, hasAct=false, hasDiff=true,  hasBoost=false },
    }

    local function getJoinEntry(modeName)
        for _, m in ipairs(NS.settings.joinModes) do
            if m.mode == modeName then return m end
        end
    end

    for _, def in ipairs(_JOIN_MODE_DEFS) do
        local mn    = def.mode
        local entry = getJoinEntry(mn)
        if entry then
            Tabs.Join:AddSection(mn)

            if def.worlds then
                local curWorld = entry.world or def.worlds[1]
                local worldDd = Tabs.Join:AddDropdown("join_world_" .. mn, {
                    Title   = "World",
                    Values  = def.worlds,
                    Default = curWorld,
                    Multi   = false,
                })
                worldDd:OnChanged(function(Value)
                    entry.world = Value
                    -- clamp act to new world's max
                    local d = _JOIN_ACT_DATA[_MODE_DATA_KEY[mn:lower()] or mn:lower()]
                    local newMax = (d and d[Value]) or 10
                    if (entry.act or 1) > newMax then entry.act = newMax end
                    State.saveSettings()
                end)
            end

            if def.hasAct then
                local curWorld = entry.world or (def.worlds and def.worlds[1])
                local actList  = buildActList(mn, curWorld)
                local curAct   = tostring(math.min(entry.act or 1, #actList))
                local actDd = Tabs.Join:AddDropdown("join_act_" .. mn, {
                    Title   = "Act",
                    Values  = actList,
                    Default = curAct,
                    Multi   = false,
                })
                actDd:OnChanged(function(Value)
                    entry.act = tonumber(Value)
                    State.saveSettings()
                end)
            end

            if def.hasDiff then
                local curDiff = entry.difficulty or "Normal"
                if curDiff ~= "Normal" and curDiff ~= "Hard" then curDiff = "Normal" end
                local diffDd = Tabs.Join:AddDropdown("join_diff_" .. mn, {
                    Title   = "Difficulty",
                    Values  = _JOIN_DIFFS,
                    Default = curDiff,
                    Multi   = false,
                })
                diffDd:OnChanged(function(Value)
                    entry.difficulty = Value
                    State.saveSettings()
                end)
            end

            if mn == "Challenge" then
                local typeDd = Tabs.Join:AddDropdown("join_ctype", {
                    Title   = "Type",
                    Values  = {"30m","Daily"},
                    Default = (entry.challengeType == "1d") and "Daily" or "30m",
                    Multi   = false,
                })
                typeDd:OnChanged(function(Value)
                    entry.challengeType = (Value == "Daily") and "1d" or "30m"
                    State.saveSettings()
                end)
            end

            if def.hasBoost then
                local boostTog = Tabs.Join:AddToggle("join_boost_" .. mn, {
                    Title   = "Boost",
                    Default = entry.boosted == true,
                })
                boostTog:OnChanged(function()
                    entry.boosted = boostTog.Value
                    State.saveSettings()
                end)
            end

            local tog = Tabs.Join:AddToggle("join_en_" .. mn, {
                Title   = "Enable",
                Default = entry.enabled == true,
            })
            tog:OnChanged(function()
                entry.enabled = tog.Value
                State.saveSettings()
            end)
        end
    end

    -- ── Loot ──────────────────────────────────────────────────────
    addToggle(Tabs.Loot, "autoClaimQuests",  "Auto Claim Quests",  "Claim all completed quests on lobby load")
    addToggle(Tabs.Loot, "autoClaimSpecial", "Auto Claim Special", "Claim special quest rewards on lobby load")

    local autoSellDd = Tabs.Loot:AddDropdown("autoSell", {
        Title       = "Auto Sell",
        Description = "Automatically sell units of selected rarities after summoning",
        Values      = { "Rare", "Epic", "Legendary", "Mythic" },
        Multi       = true,
        Default     = NS.settings.autoSell or {},
    })
    autoSellDd:OnChanged(function(Value)
        local selected = {}
        for v, state in pairs(Value) do
            if state then table.insert(selected, v) end
        end
        NS.settings.autoSell = selected
        State.saveSettings()
    end)

    addToggle(Tabs.Loot, "autoSummon", "Auto Summon", "Summon on the selected banner on lobby load")

    local bannerDd = Tabs.Loot:AddDropdown("summonBanner", {
        Title   = "Banner",
        Values  = { "Basic Banner", "Selection Banner" },
        Multi   = false,
        Default = NS.settings.summonBanner or "Basic Banner",
    })
    bannerDd:OnChanged(function(Value)
        NS.settings.summonBanner = Value
        State.saveSettings()
    end)

    local amountDd = Tabs.Loot:AddDropdown("summonAmount", {
        Title   = "Summon Amount",
        Values  = { "1", "10" },
        Multi   = false,
        Default = tostring(NS.settings.summonAmount or 1),
    })
    amountDd:OnChanged(function(Value)
        NS.settings.summonAmount = tonumber(Value)
        State.saveSettings()
    end)

    -- ── Shops ─────────────────────────────────────────────────────
    addToggle(Tabs.Shops, "autoRaidShop", "Auto Raid Shop", "Buy configured items from the raid shop on lobby load")
    addToggle(Tabs.Shops, "autoMerchant", "Auto Merchant",  "Buy configured items from the merchant on lobby load")

    -- ── Webhook ───────────────────────────────────────────────────
    Tabs.Webhook:AddInput("webhookUrl", {
        Title       = "Webhook URL",
        Default     = NS.settings.webhookUrl or "",
        Placeholder = "https://discord.com/api/webhooks/...",
        Numeric     = false,
        Finished    = true,
        Callback    = function(Value)
            NS.settings.webhookUrl = Value
            State.saveSettings()
        end
    })

    Tabs.Webhook:AddInput("webhookUserId", {
        Title       = "Ping User ID",
        Description = "Your Discord User ID — leave empty to send without a ping",
        Default     = NS.settings.webhookUserId or "",
        Placeholder = "123456789012345678",
        Numeric     = false,
        Finished    = true,
        Callback    = function(Value)
            NS.settings.webhookUserId = Value
            State.saveSettings()
        end
    })

    addToggle(Tabs.Webhook, "webhookOnVictory",  "Notify on Victory",      "Send a stage summary embed to Discord on victory")
    addToggle(Tabs.Webhook, "webhookOnDefeat",   "Notify on Defeat",       "Ping Discord on defeat")
    addToggle(Tabs.Webhook, "webhookOnEvoReady", "Notify when Evo Ready",  "Ping you when a mat is done or all mats are collected")

    Tabs.Webhook:AddButton({
        Title       = "Test Webhook",
        Description = "Send a test ping to verify the URL is working",
        Callback    = function()
            sendWebhook("🔔 Test ping from Anime Squadron — webhook is working!")
        end
    })

    -- ── Priority ──────────────────────────────────────────────────
    Tabs.Priority:AddSection("Join Mode Order")
    for _, modeName in ipairs({ "Story", "Squadron", "Raid", "Challenge", "Infinite", "Permanent" }) do
        local mn = modeName
        local curPriority = 99
        for _, m in ipairs(NS.settings.joinModes) do
            if m.mode == mn then curPriority = m.priority or 99; break end
        end
        local sl = Tabs.Priority:AddSlider("pri_" .. mn, {
            Title       = mn,
            Description = "Lower number = tried first when multiple modes are enabled",
            Default     = curPriority,
            Min         = 1,
            Max         = 6,
            Rounding    = 0,
        })
        sl:OnChanged(function(Value)
            for _, m in ipairs(NS.settings.joinModes) do
                if m.mode == mn then m.priority = Value; break end
            end
            State.saveSettings()
        end)
    end

    NS.guiWindow = Window
    Window:SelectTab(1)

    Fluent:Notify({
        Title    = "Anime Squadron",
        Content  = "Script loaded.",
        Duration = 4,
    })

    log("GUI loaded")
end

-- ── Entry point ──────────────────────────────────────────────────
log("Loading | PlaceId: " .. game.PlaceId)
State.load()
State.set("lastPlaceId", game.PlaceId)

-- Auto-reconnect: teleports back when kicked or server shuts down
game:GetService("Players").LocalPlayer.AncestryChanged:Connect(function(_, parent)
    if parent == nil then
        task.wait(5)
        pcall(function()
            game:GetService("TeleportService"):Teleport(game.PlaceId)
        end)
    end
end)

-- Anti-AFK: fires prevent_afk every 60s regardless of place
NS.afkGen = (NS.afkGen or 0) + 1
local _afkGen = NS.afkGen
task.spawn(function()
    local afkRemote = game:GetService("ReplicatedStorage"):WaitForChild("Remotes",10)
        :WaitForChild("Players",10):WaitForChild("prevent_afk",10)
    while NS.afkGen == _afkGen do
        pcall(function() afkRemote:FireServer() end)
        task.wait(60)
    end
end)

task.spawn(setupGUI)

if game.PlaceId == LOBBY_PLACE_ID then
    log("Context: LOBBY")
    task.spawn(setupLobby)

elseif game.PlaceId == INGAME_PLACE_ID then
    log("Context: INGAME")
    task.spawn(setupIngame)

else
    log("Context: UNKNOWN PlaceId " .. game.PlaceId .. " — aborting")
end
