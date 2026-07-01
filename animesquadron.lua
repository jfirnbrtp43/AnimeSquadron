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
    customAutoPlay      = false,
    customAutoPlaySlot1 = false,
    customAutoPlaySlot2 = false,
    customAutoPlaySlot3 = false,
    customAutoPlaySlot4 = false,
    customAutoPlaySlot5 = false,
    customAutoPlaySlot6 = false,
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
    raidShopItems     = {},      -- array of item names to buy from raid shop
    raidKnownItems    = {},      -- accumulated list of all raid shop items ever seen
    autoMerchant      = false,
    merchantItems     = {},      -- array of item names to buy from merchant
    merchantKnownItems = {},     -- accumulated list of all merchant items ever seen
    autoEvo           = false,
    evoTargets        = {},    -- unit names to awaken in priority order: {"Goki (SSJ4)", "Caska"}
    autoGear          = false,
    autoCraft         = false,
    gearTargets       = {},    -- gear piece names to farm materials for
    autoPermanent     = false,
    permanentDiff     = "Normal",
    autoBounty        = false,
    bountyDiff        = "Normal",
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
    local t = os.time()
    local ts = string.format("<t:%d:T>", t)  -- Discord timestamp tag, renders in viewer's timezone
    _webhookPost({ username = "Anime Squadron", content = msg .. "  " .. ts })
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
    -- ISO 8601 timestamp — Discord renders it in the viewer's local timezone
    local t = os.time()
    local ts = string.format("%04d-%02d-%02dT%02d:%02d:%02dZ",
        os.date("!*t", t).year, os.date("!*t", t).month,  os.date("!*t", t).day,
        os.date("!*t", t).hour, os.date("!*t", t).min,    os.date("!*t", t).sec)
    return {
        title     = titlePrefix .. " — " .. tostring(stage or "?"),
        color     = isVictory and 3066993 or 15158332,
        fields    = fields,
        timestamp = ts,
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
    if not entry.best or elapsed < entry.best then entry.best = elapsed end

    _data.clearTimes[key] = entry
    State.save()

    log(string.format("Clear time: %ds | EMA %.1fs | n=%d%s",
        elapsed, entry.avg, entry.count,
        entry.count < EMA_MIN_COUNT and " (cold)" or ""))
end

function ClearTime.get(stageName, act)
    return _data.clearTimes[stageKey(stageName, act)]
end

function ClearTime.getAll()
    return _data.clearTimes
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
        spawn       = chars:WaitForChild("spawn",        10),  -- RemoteFunction(unitName) → bool, msg
        charsGet    = chars:WaitForChild("get",          10),  -- RemoteFunction() → {characters, autoplay, stats}
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
local function computeMissing(cost, inventory, stats)
    local missing = {}
    for mat, needed in pairs(cost) do
        local have = (inventory[mat] or 0) + (stats and (stats[mat] or 0) or 0)
        if have < needed then
            missing[mat] = needed - have
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
                or NS.permCapKey ~= nil
            ))
            or (resultText == "Defeat!" and NS.settings.webhookOnDefeat)
        if needPd then
            local ok2, result = pcall(function() return remotes.playersGet:InvokeServer() end)
            if ok2 and result then pd = result; NS.lastPlayerData = result
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
                local missing = computeMissing(gData.cost, pd.items or {}, pd.stats or {})
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

        -- Permanent cap check: leave when daily Trait Shard cap is reached
        if resultText == "Victory!" and NS.permCapKey and pd then
            local current = (pd.caps or {})[NS.permCapKey] or 0
            log("Permanent: " .. current .. "/" .. NS.permCapMax .. " Trait Shards today")
            if current >= NS.permCapMax then
                log("Permanent: daily cap reached — returning to lobby")
                NS.permCapKey = nil
                NS.permCapMax = nil
                remotes.teleport:FireServer()
                return
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
        -- Evo / Gear
        playerGet     = rem  :WaitForChild("Player",          10):WaitForChild("get",    10),  -- () → full playerData incl. items + characters
        craftGear     = rem  :WaitForChild("Crafting",        10):WaitForChild("craft",  10),  -- (gearName, qty) → bool, playerData
        -- Bounties
        bountiesAccept    = rem:WaitForChild("Bounties", 10):WaitForChild("accept",     10),  -- (index) → bool
        bountiesClaim     = rem:WaitForChild("Bounties", 10):WaitForChild("claim",      10),  -- (index) → bool
        bountiesUseTicket = rem:WaitForChild("Bounties", 10):WaitForChild("use_ticket", 10),  -- () → bool
    }
end

-- ── Permanent challenge metadata ────────────────────────────────
local PERMANENT_CHALLENGES = {
    { world = "The Hero Hunter", cap = 30  },
    { world = "Katakara Bridge", cap = 100 },
}
local function permCapKey(world)
    return "challenge_" .. world:lower():gsub(" ", "_") .. "_1_trait_shards"
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
    elseif cfg.mode == "Permanent" then
        if NS.settings.autoPermanent then
            -- Adv Farm mode: auto-detect which stage still has daily Trait Shard cap remaining
            local ok0, pdata = pcall(function() return lobbyRemotes.playerGet:InvokeServer() end)
            if not ok0 or not pdata then
                log("Auto Join: failed to fetch player data for permanent cap check")
                return false
            end
            local pcaps = pdata.caps or {}
            local chosen, chosenCap = nil, 0
            for _, pc in ipairs(PERMANENT_CHALLENGES) do
                local key = permCapKey(pc.world)
                local current = pcaps[key] or 0
                if current < pc.cap then
                    chosen    = pc.world
                    chosenCap = pc.cap
                    log("Auto Join: Permanent → " .. pc.world .. " (" .. current .. "/" .. pc.cap .. " Trait Shards today)")
                    break
                else
                    log("Auto Join: Permanent → " .. pc.world .. " cap full (" .. current .. "/" .. pc.cap .. ")")
                end
            end
            if not chosen then
                log("Auto Join: Permanent → all daily caps full")
                return false
            end
            NS.permCapKey = permCapKey(chosen)
            NS.permCapMax = chosenCap
            config = { world=chosen, act=1, mode="Challenge", difficulty=NS.settings.permanentDiff or "Normal", boosted=true, only_friends=false }
        else
            -- Normal mode: just join the configured world
            NS.permCapKey = nil
            NS.permCapMax = nil
            config = { world=cfg.world, act=cfg.act or 1, mode="Challenge", difficulty=cfg.difficulty or "Normal", boosted=true, only_friends=false }
        end
    else
        -- Story, Squadron, Raid
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
    NS.currentStage = { world=config.world, mode=config.mode, diff=config.difficulty or "Hard", act=config.act }
    return true
end

local function attemptAutoJoin(lobbyRemotes)
    local enabled = {}
    for _, cfg in ipairs(NS.settings.joinModes) do
        if cfg.enabled then table.insert(enabled, cfg) end
    end
    -- Auto Permanent injects itself independently of the Lobby Permanent toggle
    if NS.settings.autoPermanent then
        table.insert(enabled, { mode="Permanent", priority=6 })
    end
    -- Auto Bounty injects the active bounty's world as a Story mode join
    if NS.settings.autoBounty and NS.activeBounty and NS.activeBounty.progress < NS.activeBounty.required then
        table.insert(enabled, {
            mode       = "Story",
            world      = NS.activeBounty.world,
            act        = 1,
            difficulty = NS.settings.bountyDiff or "Normal",
            priority   = 7,
        })
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
    -- Fetch current server state so we only toggle rarities that need to change.
    local ok0, pdata = pcall(function() return lr.playerGet:InvokeServer() end)
    if not ok0 or not pdata then return end
    local current = {}
    for _, t in ipairs(pdata.auto_sell or {}) do current[t] = true end
    for _, t in ipairs(SELL_TYPES) do
        local want = desired[t] == true
        if want ~= (current[t] == true) then
            pcall(function() lr.autoSell:InvokeServer(t) end)
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

local function runShopBuy(lr, shopId, selectedItems)
    if not selectedItems or #selectedItems == 0 then return end
    local ok, shopData = pcall(function() return lr.shopsGet:InvokeServer(shopId) end)
    if not ok or not shopData then
        log("Shop " .. shopId .. ": failed to fetch data")
        return
    end
    for _, itemName in ipairs(selectedItems) do
        local item = shopData[itemName]
        if not item then
            log("Shop " .. shopId .. ": " .. itemName .. " not available")
        else
            local bought = 0
            while bought < (item.max or 1) do
                local ok2, success = pcall(function()
                    return lr.shopsBuy:InvokeServer(itemName, shopId, 1)
                end)
                if ok2 and success then
                    bought = bought + 1
                    task.wait(0.2)
                else
                    break
                end
            end
            if bought > 0 then
                log("Shop " .. shopId .. ": bought x" .. bought .. " " .. itemName)
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
    if not NS.gearData then return end
    if not NS.settings.gearTargets or #NS.settings.gearTargets == 0 then return end

    local ok, playerData = pcall(function() return lr.playerGet:InvokeServer() end)
    if not ok or not playerData then log("Gear: failed to get player data"); return end

    NS.lastPlayerData = playerData
    local inventory = playerData.items or {}
    local stats     = playerData.stats or {}

    NS.gearFarmStage = nil

    for _, targetName in ipairs(NS.settings.gearTargets) do
        local gData = NS.gearData[targetName]
        if not gData then
            log("Gear: no data for " .. targetName)
        else
            local missing = computeMissing(gData.cost, inventory, stats)
            if not next(missing) then
                if NS.settings.autoCraft then
                    log("Gear: crafting " .. targetName .. "…")
                    local cOk, cRes = pcall(function() return lr.craftGear:InvokeServer(targetName, 1) end)
                    if cOk and cRes then
                        log("Gear: crafted " .. targetName .. "! Continuing to farm…")
                        if NS.settings.webhookOnEvoReady then
                            sendWebhook(evoPing() .. "🔨 **" .. targetName .. "** crafted!")
                        end
                        NS.gearNotifiedMats = nil  -- reset mat pings for next cycle
                    else
                        log("Gear: craft failed")
                    end
                else
                    log("Gear: " .. targetName .. " ready to craft!")
                end
            else
                local parts = {}
                for mat, amt in pairs(missing) do table.insert(parts, mat .. " x" .. amt) end
                log("Gear: " .. targetName .. " needs: " .. table.concat(parts, ", "))
                -- Only route to stages for mats that have a known drop location
                local farmable = {}
                for mat, amt in pairs(missing) do
                    if NS.data.matmap[mat] then farmable[mat] = amt end
                end
                local best = bestFarmStage(farmable)
                if best then
                    NS.gearFarmStage = best
                    log("Gear: farm → " .. best.world .. " " .. best.mode .. " " .. best.diff .. " act " .. best.act .. " [" .. table.concat(best.mats, ", ") .. "]")
                else
                    log("Gear: no farmable stage found")
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

    NS.lastPlayerData = playerData
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

local function updatePermStatus(lr)
    if not NS.lblPermStatus then return end
    local ok, pdata = pcall(function() return lr.playerGet:InvokeServer() end)
    if not ok or not pdata then
        NS.lblPermStatus:SetText("Status: failed to fetch")
        return
    end
    local pcaps = pdata.caps or {}
    local parts = {}
    for _, pc in ipairs(PERMANENT_CHALLENGES) do
        local current = pcaps[permCapKey(pc.world)] or 0
        table.insert(parts, pc.world .. ": " .. current .. "/" .. pc.cap)
    end
    NS.lblPermStatus:SetText(table.concat(parts, "  |  "))
end

local function runBountyLobby(lr)
    local ok, pdata = pcall(function() return lr.playerGet:InvokeServer() end)
    if not ok or not pdata then return end
    local blist = pdata.bounties or {}

    -- Claim any completed active bounty
    for i, b in ipairs(blist) do
        if b.active and b.progress >= b.required then
            local ok2, res = pcall(function() return lr.bountiesClaim:InvokeServer(i) end)
            if ok2 and res then
                log("Bounty: claimed " .. b.enemy .. " (" .. b.difficulty .. ")")
            end
        end
    end

    -- Re-fetch after claiming
    ok, pdata = pcall(function() return lr.playerGet:InvokeServer() end)
    if not ok or not pdata then return end
    blist = pdata.bounties or {}

    -- Use a ticket if no bounties remain
    if #blist == 0 then
        local ok2, res = pcall(function() return lr.bountiesUseTicket:InvokeServer() end)
        if ok2 and res then
            log("Bounty: used a ticket to generate new bounty")
            ok, pdata = pcall(function() return lr.playerGet:InvokeServer() end)
            if ok and pdata then blist = pdata.bounties or {} end
        else
            log("Bounty: no tickets remaining")
        end
    end

    -- Accept first available if none are active
    local activeBounty = nil
    for _, b in ipairs(blist) do
        if b.active then activeBounty = b break end
    end
    if not activeBounty and #blist > 0 then
        local ok2, res = pcall(function() return lr.bountiesAccept:InvokeServer(1) end)
        if ok2 and res then
            activeBounty = blist[1]
            log("Bounty: accepted " .. activeBounty.enemy .. " in " .. activeBounty.world)
        end
    end

    -- Cache active bounty for attemptAutoJoin
    NS.activeBounty = activeBounty
    if NS.lblBountyStatus then
        if activeBounty then
            NS.lblBountyStatus:SetText(activeBounty.enemy .. " " .. activeBounty.progress .. "/" .. activeBounty.required .. " (" .. activeBounty.world .. ")")
        else
            NS.lblBountyStatus:SetText("No bounties available")
        end
    end
    if activeBounty then
        log("Bounty: " .. activeBounty.enemy .. " " .. activeBounty.progress .. "/" .. activeBounty.required .. " — " .. activeBounty.world)
    else
        log("Bounty: no bounties available")
    end
end

local function runLobbyActions(lr)
    runEvoOrchestrator(lr)
    runGearOrchestrator(lr)  -- set farm stages before auto-join loop starts
    task.wait(1.5)
    runClaim(lr)
    runAutoSell(lr)
    if NS.settings.autoRaidShop then runShopBuy(lr, "gt_city_raid", NS.settings.raidShopItems) end
    if NS.settings.autoMerchant then runShopBuy(lr, "merchant",     NS.settings.merchantItems)  end
    if NS.settings.autoBounty   then runBountyLobby(lr) end
    updatePermStatus(lr)
end

-- ── Lobby setup ──────────────────────────────────────────────────
local function setupLobby()
    local ok, err = pcall(function()
        local lobbyRemotes = getLobbyRemotes()

        NS.autoJoinGen = (NS.autoJoinGen or 0) + 1
        local myGen = NS.autoJoinGen

        runLobbyActions(lobbyRemotes)

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

local function runBountyWatch(remotes)
    if not NS.settings.autoBounty then return end
    NS.bountyWatchGen = (NS.bountyWatchGen or 0) + 1
    local myGen = NS.bountyWatchGen

    -- Fetch active bounty directly in case we re-executed in-game
    local bounty = NS.activeBounty
    if not bounty then
        local ok, pdata = pcall(function() return remotes.playersGet:InvokeServer() end)
        if ok and pdata then
            for _, b in ipairs(pdata.bounties or {}) do
                if b.active then bounty = b; break end
            end
        end
    end
    if not bounty then return end
    NS.activeBounty = bounty
    local lastProgress = bounty.progress
    local firstCheck = true

    while NS.bountyWatchGen == myGen and NS.settings.autoBounty do
        if firstCheck then firstCheck = false else task.wait(3) end
        local ok, pdata = pcall(function() return remotes.playersGet:InvokeServer() end)
        if ok and pdata then
            for _, b in ipairs(pdata.bounties or {}) do
                if b.active and b.enemy == bounty.enemy then
                    if b.progress ~= lastProgress then
                        lastProgress = b.progress
                        if NS.lblBountyStatus then
                            NS.lblBountyStatus:SetText(b.enemy .. " " .. b.progress .. "/" .. b.required .. " (" .. b.world .. ")")
                        end
                        log("Bounty: " .. b.progress .. "/" .. b.required)
                    end
                    if b.progress >= b.required then
                        log("Bounty: kill count reached — returning to lobby")
                        pcall(function() remotes.teleport:FireServer() end)
                        return
                    end
                    break
                end
            end
        end
    end
end

local function runCustomAutoPlay(remotes)
    NS.customPlayGen = (NS.customPlayGen or 0) + 1
    local myGen = NS.customPlayGen

    local ok, pdata = pcall(function() return remotes.playersGet:InvokeServer() end)
    if not ok or not pdata then return end
    local slotUnits = {}
    for _, char in pairs(pdata.characters or {}) do
        if char.equipped and char.index then
            slotUnits[char.index] = char.name
        end
    end

    while NS.customPlayGen == myGen and NS.settings.customAutoPlay do
        for slot = 1, 6 do
            if NS.settings["customAutoPlaySlot" .. slot] and slotUnits[slot] then
                pcall(function() remotes.spawn:InvokeServer(slotUnits[slot]) end)
                task.wait(0.1)
            end
        end
        task.wait(0.3)
    end
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
        task.spawn(function() runBountyWatch(remotes) end)
        task.spawn(function() runCustomAutoPlay(remotes) end)
    end)

    if not ok then
        log("Ingame setup error: " .. tostring(err))
    end
end

-- ── GUI ──────────────────────────────────────────────────────────
local function setupGUI()
    -- Destroy any existing GUI from a previous execute
    if NS.guiLibrary then
        pcall(function() NS.guiLibrary:Unload() end)
        NS.guiLibrary = nil
    end
    NS.guiWindow = nil

    local ok, Library = pcall(function()
        return loadstring(game:HttpGet(
            "https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/Library.lua"
        ))()
    end)
    if not ok or not Library then
        log("GUI: failed to load Linoria — " .. tostring(Library))
        return
    end

    local Window = Library:CreateWindow({
        Title        = "Anime Squadron",
        Center       = true,
        AutoShow     = true,
        TabPadding   = 8,
        MenuFadeTime = 0.2,
    })

    local Tabs = {
        Lobby   = Window:AddTab("Lobby"),
        Play    = Window:AddTab("Play"),
        AdvFarm = Window:AddTab("Adv Farm"),
        Webhook = Window:AddTab("Webhook"),
        Info    = Window:AddTab("Info"),
    }

    local function addToggle(groupbox, key, text, tooltip)
        groupbox:AddToggle(key, {
            Text     = text,
            Default  = NS.settings[key] == true,
            Tooltip  = tooltip,
            Callback = function(Value)
                NS.settings[key] = Value
                State.saveSettings()
            end,
        })
    end

    -- ── Farm ─────────────────────────────────────────────────────
    local FarmBox = Tabs.Play:AddLeftGroupbox("Auto Play")
    addToggle(FarmBox, "autoStart",    "Auto Start",    "Fire start when the ready screen appears")
    addToggle(FarmBox, "autoMaxSpeed", "Auto Max Speed","Set highest available speed on game start")
    addToggle(FarmBox, "autoNext",     "Auto Next",     "Advance to next act on victory")
    addToggle(FarmBox, "autoReplay",   "Auto Replay",   "Replay the same act on victory")
    addToggle(FarmBox, "autoLeave",    "Auto Leave",    "Teleport to lobby if no other action fires")

    -- ── Custom Auto Play ─────────────────────────────────────────────
    local CapBox = Tabs.Play:AddRightGroupbox("Custom Auto Play")
    addToggle(CapBox, "customAutoPlay", "Enable", "Spawn only selected hotbar slots instead of using game autoplay")
    for i = 1, 6 do
        addToggle(CapBox, "customAutoPlaySlot" .. i, "Slot " .. i, "Include hotbar slot " .. i .. " in custom auto play")
    end

    local FarmMiscBox = Tabs.Play:AddRightGroupbox("Misc")
    addToggle(FarmMiscBox, "challengeReturn30", "30-min Challenge Return", "Leave to lobby at XX:00 and XX:30 for challenge reset")

    -- ── Evo ──────────────────────────────────────────────────────
    local EvoBox = Tabs.AdvFarm:AddLeftGroupbox("Auto Evo")
    addToggle(EvoBox, "autoEvo", "Auto Evo", "Farm materials for the target unit, then notify when ready to awaken")

    local _evoUnitList = {}
    if NS.data and NS.data.awaken then
        for unitName in pairs(NS.data.awaken) do
            table.insert(_evoUnitList, unitName)
        end
        table.sort(_evoUnitList)
    end

    EvoBox:AddDropdown("evoTarget1", {
        Values     = _evoUnitList,
        Default    = (NS.settings.evoTargets and NS.settings.evoTargets[1]) or (_evoUnitList[1] or ""),
        Multi      = false,
        Text       = "Evo Target",
        Searchable = true,
        Callback   = function(Value)
            NS.settings.evoTargets = (Value and Value ~= "") and { Value } or {}
            State.saveSettings()
        end,
    })

    -- ── Gear ──────────────────────────────────────────────────────
    local GearBox = Tabs.AdvFarm:AddLeftGroupbox("Auto Gear")
    addToggle(GearBox, "autoGear",  "Auto Gear",  "Farm materials for the selected gear piece")
    addToggle(GearBox, "autoCraft", "Auto Craft", "Automatically craft when all materials are collected, then keep farming")

    local _gearList = {}
    if NS.gearData then
        for gearName in pairs(NS.gearData) do
            table.insert(_gearList, gearName)
        end
        table.sort(_gearList)
    end

    GearBox:AddDropdown("gearTarget1", {
        Values     = _gearList,
        Default    = (NS.settings.gearTargets and NS.settings.gearTargets[1]) or (_gearList[1] or ""),
        Multi      = false,
        Text       = "Gear Target",
        Searchable = true,
        Callback   = function(Value)
            NS.settings.gearTargets = (Value and Value ~= "") and { Value } or {}
            State.saveSettings()
        end,
    })

    -- ── Permanent Challenges ──────────────────────────────────────
    local PermBox = Tabs.AdvFarm:AddRightGroupbox("Permanent Challenges")
    addToggle(PermBox, "autoPermanent", "Auto Permanent",
        "Auto-farm permanent challenges (Hero Hunter → Katakara Bridge) until daily Trait Shard caps are full")
    PermBox:AddDropdown("permanentDiff", {
        Values   = { "Normal", "Hard" },
        Default  = NS.settings.permanentDiff or "Normal",
        Multi    = false,
        Text     = "Difficulty",
        Callback = function(Value)
            NS.settings.permanentDiff = Value
            State.saveSettings()
        end,
    })
    NS.lblPermStatus = PermBox:AddLabel("Status: —", true)

    -- ── Bounty ────────────────────────────────────────────────────
    local BountyBox = Tabs.AdvFarm:AddLeftGroupbox("Auto Bounty")
    addToggle(BountyBox, "autoBounty", "Auto Bounty",
        "Auto-accept, farm, and claim bounties. Joins the bounty's world in Normal mode until kills are complete.")
    BountyBox:AddDropdown("bountyDiff", {
        Values   = { "Normal", "Hard" },
        Default  = NS.settings.bountyDiff or "Normal",
        Multi    = false,
        Text     = "Difficulty",
        Callback = function(Value)
            NS.settings.bountyDiff = Value
            State.saveSettings()
        end,
    })
    NS.lblBountyStatus = BountyBox:AddLabel("Status: —", true)

    -- ── Upgrade ───────────────────────────────────────────────────
    local UpgradeBox = Tabs.Play:AddLeftGroupbox("Auto Upgrade")
    addToggle(UpgradeBox, "autoUpgrade", "Auto Upgrade", "Automatically spend Yen to upgrade equipped units")
    UpgradeBox:AddDropdown("upgradeMode", {
        Values   = { "max", "cheapest" },
        Default  = NS.settings.upgradeMode or "max",
        Multi    = false,
        Text     = "Upgrade Mode",
        Tooltip  = "Max: fully upgrade one slot before moving on. Cheapest: one upgrade per slot in rotation.",
        Callback = function(Value)
            NS.settings.upgradeMode = Value
            State.saveSettings()
        end,
    })

    local SlotsBox = Tabs.Play:AddRightGroupbox("Slot Priority")
    for i = 1, 6 do
        local slotIdx = i
        local curPriority = 0
        for _, s in ipairs(NS.settings.upgradeSlots) do
            if s.slot == slotIdx then curPriority = s.priority; break end
        end
        SlotsBox:AddSlider("upgradeSlot" .. slotIdx, {
            Text     = "Slot " .. slotIdx,
            Default  = curPriority,
            Min      = 0,
            Max      = 6,
            Rounding = 0,
            Tooltip  = "0 = disabled. Lower number upgraded first.",
            Callback = function(Value)
                for _, s in ipairs(NS.settings.upgradeSlots) do
                    if s.slot == slotIdx then s.priority = Value; break end
                end
                State.saveSettings()
            end,
        })
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

local _JOIN_STORY_WORLDS     = {"GT City","Marine Lobby","Ninja Village","Eclipse (Before)"}
    local _JOIN_RAID_WORLDS      = {"GT City","Eclipse (Before)"}
    local _JOIN_PERMANENT_WORLDS = {"Katakara Bridge","The Hero Hunter"}
    local _JOIN_DIFFS            = {"Normal","Hard"}

    local _JOIN_MODE_DEFS = {
        { mode="Story",     worlds=_JOIN_STORY_WORLDS,     hasAct=true,  hasDiff=true,  hasBoost=false, col="left"  },
        { mode="Squadron",  worlds=_JOIN_STORY_WORLDS,     hasAct=true,  hasDiff=true,  hasBoost=false, col="left"  },
        { mode="Raid",      worlds=_JOIN_RAID_WORLDS,      hasAct=true,  hasDiff=true,  hasBoost=false, col="left"  },
        { mode="Challenge", worlds=nil,                    hasAct=false, hasDiff=false, hasBoost=false, col="right" },
        { mode="Infinite",  worlds=nil,                    hasAct=false, hasDiff=false, hasBoost=true,  col="right" },
        { mode="Permanent", worlds=_JOIN_PERMANENT_WORLDS, hasAct=false, hasDiff=true,  hasBoost=false, col="right" },
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
            local modeBox
            if def.col == "left" then
                modeBox = Tabs.Lobby:AddLeftGroupbox(mn)
            else
                modeBox = Tabs.Lobby:AddRightGroupbox(mn)
            end

            if def.worlds then
                modeBox:AddDropdown("join_world_" .. mn, {
                    Values   = def.worlds,
                    Default  = entry.world or def.worlds[1],
                    Multi    = false,
                    Text     = "World",
                    Callback = function(Value)
                        entry.world = Value
                        local d = _JOIN_ACT_DATA[_MODE_DATA_KEY[mn:lower()] or mn:lower()]
                        local newMax = (d and d[Value]) or 10
                        if (entry.act or 1) > newMax then entry.act = newMax end
                        State.saveSettings()
                    end,
                })
            end

            if def.hasAct then
                local _modeKey  = _MODE_DATA_KEY[mn:lower()] or mn:lower()
                local _modeData = _JOIN_ACT_DATA[_modeKey]
                local _maxActs  = 0
                if _modeData and def.worlds then
                    for _, w in ipairs(def.worlds) do
                        local n = _modeData[w] or 0
                        if n > _maxActs then _maxActs = n end
                    end
                end
                if _maxActs == 0 then _maxActs = 10 end
                local actList = {}
                for i = 1, _maxActs do actList[i] = tostring(i) end
                modeBox:AddDropdown("join_act_" .. mn, {
                    Values   = actList,
                    Default  = tostring(math.min(entry.act or 1, _maxActs)),
                    Multi    = false,
                    Text     = "Act",
                    Callback = function(Value)
                        entry.act = tonumber(Value)
                        State.saveSettings()
                    end,
                })
            end

            if def.hasDiff then
                local curDiff = entry.difficulty or "Normal"
                if curDiff ~= "Normal" and curDiff ~= "Hard" then curDiff = "Normal" end
                modeBox:AddDropdown("join_diff_" .. mn, {
                    Values   = _JOIN_DIFFS,
                    Default  = curDiff,
                    Multi    = false,
                    Text     = "Difficulty",
                    Callback = function(Value)
                        entry.difficulty = Value
                        State.saveSettings()
                    end,
                })
            end

            if mn == "Challenge" then
                modeBox:AddDropdown("join_ctype", {
                    Values   = {"30m","Daily"},
                    Default  = (entry.challengeType == "1d") and "Daily" or "30m",
                    Multi    = false,
                    Text     = "Type",
                    Callback = function(Value)
                        entry.challengeType = (Value == "Daily") and "1d" or "30m"
                        State.saveSettings()
                    end,
                })
            end

            if def.hasBoost then
                modeBox:AddToggle("join_boost_" .. mn, {
                    Text     = "Boost",
                    Default  = entry.boosted == true,
                    Callback = function(Value)
                        entry.boosted = Value
                        State.saveSettings()
                    end,
                })
            end

            modeBox:AddToggle("join_en_" .. mn, {
                Text     = "Enable",
                Default  = entry.enabled == true,
                Callback = function(Value)
                    entry.enabled = Value
                    State.saveSettings()
                end,
            })
        end
    end

    local PriorityBox = Tabs.Lobby:AddRightGroupbox("Mode Priority")
    for _, modeName in ipairs({ "Story", "Squadron", "Raid", "Challenge", "Infinite", "Permanent" }) do
        local mn = modeName
        local curPriority = 99
        for _, m in ipairs(NS.settings.joinModes) do
            if m.mode == mn then curPriority = m.priority or 99; break end
        end
        PriorityBox:AddSlider("pri_" .. mn, {
            Text     = mn,
            Default  = curPriority,
            Min      = 1,
            Max      = 6,
            Rounding = 0,
            Tooltip  = "Lower number = tried first when multiple modes are enabled",
            Callback = function(Value)
                for _, m in ipairs(NS.settings.joinModes) do
                    if m.mode == mn then m.priority = Value; break end
                end
                State.saveSettings()
            end,
        })
    end

    -- ── Lobby ─────────────────────────────────────────────────────
    local QuestsBox = Tabs.Lobby:AddLeftGroupbox("Quests & Summon")
    addToggle(QuestsBox, "autoClaimQuests",  "Auto Claim Quests",  "Claim all completed quests on lobby load")
    addToggle(QuestsBox, "autoClaimSpecial", "Auto Claim Special", "Claim special quest rewards on lobby load")
    addToggle(QuestsBox, "autoSummon",       "Auto Summon",        "Summon on the selected banner on lobby load")
    QuestsBox:AddDropdown("summonBanner", {
        Values   = { "Basic Banner", "Selection Banner" },
        Default  = NS.settings.summonBanner or "Basic Banner",
        Multi    = false,
        Text     = "Banner",
        Callback = function(Value)
            NS.settings.summonBanner = Value
            State.saveSettings()
        end,
    })
    QuestsBox:AddDropdown("summonAmount", {
        Values   = { "1", "10" },
        Default  = tostring(NS.settings.summonAmount or 1),
        Multi    = false,
        Text     = "Summon Amount",
        Callback = function(Value)
            NS.settings.summonAmount = tonumber(Value)
            State.saveSettings()
        end,
    })
    QuestsBox:AddDropdown("autoSell", {
        Values   = { "Rare", "Epic", "Legendary", "Mythic" },
        Default  = NS.settings.autoSell or {},
        Multi    = true,
        Text     = "Auto Sell",
        Tooltip  = "Automatically sell units of selected rarities after summoning",
        Callback = function(Value)
            local selected = {}
            for v, state in pairs(Value) do
                if state then table.insert(selected, v) end
            end
            NS.settings.autoSell = selected
            State.saveSettings()
        end,
    })

    -- Fetch current shop items and merge into saved accumulated lists
    do
        local shopsGetR = RS:FindFirstChild("Remotes") and RS.Remotes:FindFirstChild("Shops") and RS.Remotes.Shops:FindFirstChild("get")
        if shopsGetR then
            local function mergeShop(savedKey, shopId)
                local ok, data = pcall(function() return shopsGetR:InvokeServer(shopId) end)
                if not ok or not data then return end
                local seen = {}
                for _, v in ipairs(NS.settings[savedKey] or {}) do seen[v] = true end
                for name in pairs(data) do seen[name] = true end
                local list = {}
                for name in pairs(seen) do table.insert(list, name) end
                table.sort(list)
                NS.settings[savedKey] = list
            end
            mergeShop("merchantKnownItems", "merchant")
            mergeShop("raidKnownItems",     "gt_city_raid")
            State.saveSettings()
        end
    end

    local ShopsBox = Tabs.Lobby:AddRightGroupbox("Shops")

    addToggle(ShopsBox, "autoRaidShop", "Auto Raid Shop", "Buy selected items from the GT City raid shop on lobby load")
    local _raidDefault = {}
    for _, v in ipairs(NS.settings.raidShopItems or {}) do _raidDefault[v] = true end
    ShopsBox:AddDropdown("raidShopItemsDrop", {
        Values   = NS.settings.raidKnownItems,
        Default  = _raidDefault,
        Multi    = true,
        Text     = "Raid Shop Items",
        Callback = function(Value)
            local sel = {}
            for item, on in pairs(Value) do if on then table.insert(sel, item) end end
            NS.settings.raidShopItems = sel
            State.saveSettings()
        end,
    })

    addToggle(ShopsBox, "autoMerchant", "Auto Merchant", "Buy selected items from the merchant on lobby load")
    local _merchantDefault = {}
    for _, v in ipairs(NS.settings.merchantItems or {}) do _merchantDefault[v] = true end
    ShopsBox:AddDropdown("merchantItemsDrop", {
        Values   = NS.settings.merchantKnownItems,
        Default  = _merchantDefault,
        Multi    = true,
        Text     = "Merchant Items",
        Callback = function(Value)
            local sel = {}
            for item, on in pairs(Value) do if on then table.insert(sel, item) end end
            NS.settings.merchantItems = sel
            State.saveSettings()
        end,
    })

    -- ── Webhook ───────────────────────────────────────────────────
    local WebhookConfigBox = Tabs.Webhook:AddLeftGroupbox("Config")
    WebhookConfigBox:AddInput("webhookUrl", {
        Default     = NS.settings.webhookUrl or "",
        Numeric     = false,
        Finished    = true,
        Text        = "Webhook URL",
        Placeholder = "https://discord.com/api/webhooks/...",
        Callback    = function(Value)
            NS.settings.webhookUrl = Value
            State.saveSettings()
        end,
    })
    WebhookConfigBox:AddInput("webhookUserId", {
        Default     = NS.settings.webhookUserId or "",
        Numeric     = false,
        Finished    = true,
        Text        = "Ping User ID",
        Tooltip     = "Your Discord User ID — leave empty to send without a ping",
        Placeholder = "123456789012345678",
        Callback    = function(Value)
            NS.settings.webhookUserId = Value
            State.saveSettings()
        end,
    })

    local WebhookNotifBox = Tabs.Webhook:AddRightGroupbox("Notifications")
    addToggle(WebhookNotifBox, "webhookOnVictory",  "On Victory",  "Send a stage summary embed to Discord on victory")
    addToggle(WebhookNotifBox, "webhookOnDefeat",   "On Defeat",   "Ping Discord on defeat")
    addToggle(WebhookNotifBox, "webhookOnEvoReady", "On Evo Ready","Ping you when a mat is done or all mats are collected")
    WebhookNotifBox:AddButton({
        Text    = "Test Webhook",
        Func    = function()
            sendWebhook("🔔 Test ping from Anime Squadron — webhook is working!")
        end,
        Tooltip = "Send a test ping to verify the URL is working",
    })

    -- ── Info ──────────────────────────────────────────────────────
    local _infoStageFilter = "Current"

    local ActivityBox    = Tabs.Info:AddLeftGroupbox("Activity")
    local lblActivity    = ActivityBox:AddLabel("—", true)

    local EvoProgBox     = Tabs.Info:AddLeftGroupbox("Evo Progress")
    local lblEvo         = EvoProgBox:AddLabel("Disabled", true)

    local GearProgBox    = Tabs.Info:AddRightGroupbox("Gear Progress")
    local lblGear        = GearProgBox:AddLabel("Disabled", true)

    local PlayerBox      = Tabs.Info:AddRightGroupbox("Player")
    local lblPlayer      = PlayerBox:AddLabel("—", true)

    local StageBox       = Tabs.Info:AddRightGroupbox("Stage Records")
    StageBox:AddDropdown("infoStageFilter", {
        Values   = { "Current", "All" },
        Default  = "Current",
        Multi    = false,
        Text     = "View",
        Callback = function(v) _infoStageFilter = v end,
    })
    local lblStages = StageBox:AddLabel("—", true)

    NS.infoGen = (NS.infoGen or 0) + 1
    local myInfoGen = NS.infoGen
    task.spawn(function()
        while NS.infoGen == myInfoGen do
            local inLobby = (game.PlaceId == LOBBY_PLACE_ID)

            -- Activity
            local actLines = {}
            if NS.settings.autoGear and NS.gearFarmStage then
                local fs = NS.gearFarmStage
                local target = NS.settings.gearTargets and NS.settings.gearTargets[1]
                table.insert(actLines, "Gear: farming " .. fs.world .. " Act " .. fs.act .. " (" .. fs.mode .. " " .. fs.diff .. ")")
                if target then
                    table.insert(actLines, "For: " .. target)
                    local gData = NS.gearData and NS.gearData[target]
                    if gData then
                        local pd  = NS.lastPlayerData
                        local inv = pd and pd.items or {}
                        local st  = pd and pd.stats or {}
                        local missing = computeMissing(gData.cost, inv, st)
                        local parts = {}
                        for mat, amt in pairs(missing) do table.insert(parts, mat .. " x" .. amt) end
                        if #parts > 0 then
                            table.sort(parts)
                            table.insert(actLines, "Need: " .. table.concat(parts, " · "))
                        end
                    end
                end
            elseif NS.settings.autoEvo and NS.evoFarmStage then
                local fs = NS.evoFarmStage
                local target = NS.settings.evoTargets and NS.settings.evoTargets[1]
                table.insert(actLines, "Evo: farming " .. fs.world .. " Act " .. fs.act .. " (" .. fs.mode .. " " .. fs.diff .. ")")
                if target then
                    local awData = NS.data and NS.data.awaken and NS.data.awaken[target]
                    table.insert(actLines, "For: " .. target .. (awData and (" → " .. (awData.awakensTo or "?")) or ""))
                    if awData then
                        local pd  = NS.lastPlayerData
                        local inv = pd and pd.items or {}
                        local st  = pd and pd.stats or {}
                        local missing = computeMissing(awData.cost, inv, st)
                        local parts = {}
                        for mat, amt in pairs(missing) do table.insert(parts, mat .. " x" .. amt) end
                        if #parts > 0 then
                            table.sort(parts)
                            table.insert(actLines, "Need: " .. table.concat(parts, " · "))
                        end
                    end
                end
            elseif inLobby then
                if NS.settings.autoGear and not NS.gearFarmStage then
                    table.insert(actLines, "Gear: waiting in lobby (nothing farmable)")
                elseif NS.settings.autoEvo and not NS.evoFarmStage then
                    table.insert(actLines, "Evo: waiting in lobby (nothing farmable)")
                else
                    table.insert(actLines, "In Lobby")
                end
            else
                local stageName = NS.currentStage and NS.currentStage.world or _data.stage
                local act       = NS.currentStage and NS.currentStage.act   or _data.act
                if stageName and act then
                    table.insert(actLines, "In Stage: " .. stageName .. " Act " .. act)
                else
                    table.insert(actLines, "In Stage")
                end
            end
            pcall(function() lblActivity:SetText(table.concat(actLines, "\n")) end)

            -- Evo
            local evoText
            if not NS.settings.autoEvo then
                evoText = "Disabled"
            elseif not NS.settings.evoTargets or #NS.settings.evoTargets == 0 then
                evoText = "No target selected"
            else
                local targetName = NS.settings.evoTargets[1]
                local awData = NS.data and NS.data.awaken and NS.data.awaken[targetName]
                if not awData then
                    evoText = targetName .. " — no data"
                else
                    local pd   = NS.lastPlayerData
                    local inv  = pd and pd.items or {}
                    local stat = pd and pd.stats or {}
                    local mats = {}
                    for mat in pairs(awData.cost) do table.insert(mats, mat) end
                    table.sort(mats)
                    local parts = { targetName .. " → " .. (awData.awakensTo or "?") }
                    for _, mat in ipairs(mats) do
                        local needed = awData.cost[mat]
                        local have   = (inv[mat] or 0) + (stat[mat] or 0)
                        table.insert(parts, (have >= needed and "✓ " or "· ") .. mat .. " " .. have .. "/" .. needed)
                    end
                    evoText = table.concat(parts, "\n")
                end
            end
            pcall(function() lblEvo:SetText(evoText) end)

            -- Gear
            local gearText
            if not NS.settings.autoGear then
                gearText = "Disabled"
            elseif not NS.settings.gearTargets or #NS.settings.gearTargets == 0 then
                gearText = "No target selected"
            else
                local targetName = NS.settings.gearTargets[1]
                local gData = NS.gearData and NS.gearData[targetName]
                if not gData then
                    gearText = targetName .. " — no data"
                else
                    local pd   = NS.lastPlayerData
                    local inv  = pd and pd.items or {}
                    local stat = pd and pd.stats or {}
                    local mats = {}
                    for mat in pairs(gData.cost) do table.insert(mats, mat) end
                    table.sort(mats)
                    local parts = { targetName }
                    for _, mat in ipairs(mats) do
                        local needed = gData.cost[mat]
                        local have   = (inv[mat] or 0) + (stat[mat] or 0)
                        table.insert(parts, (have >= needed and "✓ " or "· ") .. mat .. " " .. have .. "/" .. needed)
                    end
                    gearText = table.concat(parts, "\n")
                end
            end
            pcall(function() lblGear:SetText(gearText) end)

            -- Player
            local playerText
            local pd = NS.lastPlayerData
            if pd and pd.stats then
                local s = pd.stats
                playerText = "Level " .. (s.level or "?")
                    .. "  ·  Gold " .. (s.Gold or 0)
                    .. "  ·  Gems " .. (s.Gems or 0)
                    .. "\nXP " .. (s.XP or 0)
                    .. "  ·  Bounty Tickets " .. (s["Bounty Tickets"] or 0)
                    .. "  ·  Trait Shards " .. (s["Trait Shards"] or 0)
            else
                playerText = "Loading…"
            end
            pcall(function() lblPlayer:SetText(playerText) end)

            -- Stage Records
            local stageText
            local allRecords = ClearTime.getAll()
            if _infoStageFilter == "Current" then
                if inLobby then
                    stageText = "In Lobby"
                else
                    local cs = NS.currentStage
                    local stageName = cs and cs.world or _data.stage
                    local act       = cs and cs.act   or _data.act
                    if stageName and act then
                        local key   = stageName .. "|" .. tostring(act)
                        local entry = allRecords[key]
                        local header
                        if cs then
                            header = cs.world .. " · " .. cs.mode .. " " .. cs.diff .. " Act " .. cs.act
                        else
                            header = stageName .. " Act " .. act
                        end
                        if entry then
                            local cold = entry.count < 3 and "  (cold)" or ""
                            local best = entry.best or entry.avg
                            stageText = header
                                .. "\nBest " .. string.format("%d:%02d", math.floor(best/60), best%60)
                                .. "  ·  Avg "  .. string.format("%d:%02d", math.floor(entry.avg/60), entry.avg%60)
                                .. "  ·  Runs " .. entry.count .. cold
                        else
                            stageText = header .. "\nNo records yet"
                        end
                    else
                        stageText = "No stage active"
                    end
                end
            else
                if not next(allRecords) then
                    stageText = "No records yet"
                else
                    local lines = {}
                    for key, entry in pairs(allRecords) do
                        -- key format: "World Name|act"
                        local world, act = key:match("^(.+)|(%d+)$")
                        local b = entry.best or entry.avg
                        local best = string.format("%d:%02d", math.floor(b/60), b%60)
                        local label = (world or key) .. " Act " .. (act or "?")
                        table.insert(lines, label .. "  —  Best " .. best .. " (" .. entry.count .. " runs)")
                    end
                    table.sort(lines)
                    stageText = table.concat(lines, "\n")
                end
            end
            pcall(function() lblStages:SetText(stageText) end)

            task.wait(5)
        end
    end)

    NS.guiLibrary = Library
    NS.guiWindow  = Window

    pcall(function()
        Library:Notify("Script loaded.", 4)
    end)

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

-- Anti-AFK: 1px alternating mouse nudge resets Roblox's input timer (nets to zero drift),
-- plus game remote for any game-level AFK system.
NS.afkGen = (NS.afkGen or 0) + 1
local _afkGen = NS.afkGen
task.spawn(function()
    local VIM = game:GetService("VirtualInputManager")
    local afkRemote
    pcall(function()
        afkRemote = game:GetService("ReplicatedStorage"):WaitForChild("Remotes",10)
            :WaitForChild("Players",10):WaitForChild("prevent_afk",10)
    end)
    local _tick = 0
    while NS.afkGen == _afkGen do
        _tick = _tick + 1
        pcall(function()
            VIM:SendMouseMoveEvent(_tick % 2 == 0 and 1 or -1, 0, workspace.CurrentCamera)
        end)
        if afkRemote then pcall(function() afkRemote:FireServer() end) end
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
