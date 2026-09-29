--[[
	ANIME DICE HUB  —  place 113290951185459  ("[UPD 5] Anime Dice")
	Built with Project UAI  ·  model deepseek-v4-flash
	Built from the decompiled server source (all Framework.Features services are
	replicated to the client, so every remote, arg shape and server check is known).

	Everything here is automation of the game's own API. The server is authoritative:
	it re-rolls every rarity/grade/trait server-side, recomputes prices and holds the
	profile. Nothing here can forge a reward — the hub just drives the normal calls
	faster than a human can and never lets the inventory back up.

	Toggle UI: RightShift.  Panic stop: the UI "STOP ALL" button, or
	getgenv().__ANIME_DICE_HUB.stop()

	API: getgenv().__ANIME_DICE_HUB
	  .cfg            config table (enabled flags + tunables)
	  .stats          live counters
	  .set(k, v)      set a config value
	  .toggle(k)      flip an enabled flag
	  .sellNow() .collectNow() .equipBest() .claimNow() .redeemAll()
	  .stop()         stop everything and disconnect
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local plr = Players.LocalPlayer

-- one instance only ---------------------------------------------------------
if getgenv().__ANIME_DICE_HUB then
	pcall(function() getgenv().__ANIME_DICE_HUB.stop() end)
end
local HUB_VER = "1.0"

local function waitFor(parent, name, t)
	return parent and parent:WaitForChild(name, t or 15)
end

local Net = waitFor(RS, "Network")
if not Net then
	return warn("[ADH] no Network folder - wrong game?")
end

local function rem(folder, class, name)
	local f = waitFor(Net, folder)
	local c = f and waitFor(f, class)
	local r = c and waitFor(c, name)
	if not r then warn("[ADH] missing remote: " .. folder .. "." .. class .. "." .. name) end
	return r
end

-- exact remote map (verified against the decompiled services) ----------------
local R = {
	Roll           = rem("RollService", "RF", "RollDice"),
	SetAutoRoll    = rem("RollService", "RE", "SetAutoRoll"),
	SellInventory  = rem("SellService", "RF", "SellInventory"),
	SellEquipped   = rem("SellService", "RF", "SellEquipped"),
	UpdateAutoSell = rem("SellService", "RE", "UpdateAutoSell"),
	SetSetting     = rem("SettingsService", "RE", "SetSetting"),
	CollectBalance = rem("PlotService", "RE", "CollectBalance"),
	EquipBest      = rem("PlotService", "RE", "EquipBest"),
	LevelUpSlot    = rem("PlotService", "RE", "LevelUpSlot"),
	QuestClaim     = rem("QuestService", "RE", "Claim"),
	QuestBuy       = rem("QuestService", "RE", "Buy"),
	DailyClaim     = rem("DailyRewardService", "RE", "Claim"),
	GroupClaim     = rem("GroupRewardService", "RE", "Claim"),
	OfflineClaim   = rem("OfflineEarningsService", "RE", "Claim"),
	Rebirth        = rem("RebirthService", "RE", "Rebirth"),
	BuyDice        = rem("DiceShopService", "RE", "BuyDice"),
	EquipDice      = rem("DiceShopService", "RE", "EquipDice"),
	GradeRoll      = rem("GradeService", "RE", "Roll"),
	GradeProtect   = rem("GradeService", "RE", "SetGradeProtected"),
	TraitRoll      = rem("TraitService", "RE", "Roll"),
	TraitProtect   = rem("TraitService", "RE", "SetTraitProtected"),
	Equip          = rem("UnitService", "RF", "Equip"),
	Unequip        = rem("UnitService", "RF", "Unequip"),
	SetLocked      = rem("UnitService", "RE", "SetLocked"),
	BoostUse       = rem("BoostService", "RE", "Use"),
	SpinUse        = rem("SpinService", "RE", "Use"),
	Fuse           = rem("FusingService", "RE", "Fuse"),
	TowerPlay      = rem("Towers", "RF", "PlayTower"),
	TowerFloor     = rem("Towers", "RF", "CompleteTowerFloor"),
	TowerCancel    = rem("Towers", "RF", "CancelTower"),
	TowerEquipBest = rem("Towers", "RE", "EquipBestTowerTeam"),
	FuseResult     = rem("FusingService", "RE", "Result"),
	Redeem         = rem("MonetizationService", "RE", "RedeemCode"),
}
R.BuyUpgrade = waitFor(Net, "RE") and waitFor(Net.RE, "BuyUpgrade")

-- game config tables (all replicated to the client) --------------------------
local function mod(path)
	local node = RS
	for seg in string.gmatch(path, "[^%.]+") do
		node = node and node:FindFirstChild(seg)
	end
	if not node then
		warn("[ADH] missing module " .. path)
		return nil
	end
	local ok, m = pcall(require, node)
	if not ok then
		warn("[ADH] require failed " .. path .. ": " .. tostring(m))
		return nil
	end
	return m
end

local ER        = mod("Framework.Features.Inventory.EntryRegistry")
local Rar       = mod("Framework.Other.Rarities")
local DiceCfg   = mod("Framework.Features.Rolling.Dice")
local Grades    = mod("Framework.Features.Grades.Grades")
local Traits    = mod("Framework.Features.Traits.Traits")
local Rebirths  = mod("Framework.Features.Rebirth.Rebirths")
local Upgrades  = mod("Framework.Features.Upgrades.Upgrades")
local Tree      = mod("Framework.Features.Upgrades.TreeStructure")
local QuestCfg  = mod("Framework.Features.Quests.QuestConfig")
local PlotCfg   = mod("Framework.Features.Plot.PlotConfig")
local MonetCfg  = mod("Framework.Features.Monetization.MonetizationConfig")
local TowersCfg = mod("Framework.Features.Towers.Towers")
local FusingCfg = mod("Framework.Features.Fusing.FusingConfig")
local UIRefs    = mod("Framework.Features.UI.UIReferences")
local D         = mod("Framework.Features.Data.DataController")
local BuffC     = mod("Framework.Features.Buffs.BuffController")

if not (ER and D) then
	return warn("[ADH] core modules unavailable, aborting")
end

-- config ---------------------------------------------------------------------
local Cfg = {
	enabled = {
		autoRoll       = true,
		autoCollect    = true,
		autoSell       = true,
		autoEquipBest  = true,
		autoUpgrades   = true,
		autoQuests     = true,
		autoQuestShop  = true,
		autoClaims     = true,
		autoGrade      = true,
		autoTrait      = true,
		autoDice       = true,
		autoBoostSpins = true,
		autoRedeem     = true,
		autoRebirth    = true,
		autoTower      = false,
		autoFuse       = true,
		killShowcase   = true,
		killAutoRoll   = false,
		serverAutoSell = false,
	},
	rollInterval    = 2.9,
	collectInterval = 5,
	sellInterval    = 8,
	upgradeInterval = 3,
	diceInterval    = 30,
	claimInterval   = 45,
	questInterval   = 15,
	gradeInterval   = 0.45,
	fuseInterval    = 5,
	fuseMaxChance   = 50000,
	fuseFloorUnits  = 25,
	fuseMoneyMultiple = 5,
	-- selling
	sellChance      = 1000,
	keepRarity      = 4,
	keepTop         = 8,
	keepMutated     = false,
	maxUnits        = 70,
	reserveUnits    = 20,
	sellBatch       = 60,
	-- targets
	gradeTarget     = 3,
	traitTarget     = 2,
	moneyReserve    = 0,
	diceSpendFrac   = 0.5,
	questShopPriority = { "Roll Speed", "More Cash", "Luck", "Ultra Luck", "Trait Reroll", "Gems", "Lucky Spin" },
	priorityUpgrades = { "Roll Speed", "Unit Storage" },
	questShopPerTick = 2,
	rareLogChance   = 1000,
	fuseMinMoney    = 1e6,
	towerName       = nil,
	serverAutoSellValue = 0,
	uiKey           = Enum.KeyCode.RightShift,
}

-- runtime state --------------------------------------------------------------
local State = {
	connections = {},
	tasks = {},
	running = true,
	fuseActive = false,
	towerActive = false,
	towerStalls = 0,
}

local Stats = {
	rolls = 0, soldUnits = 0, soldMoney = 0,
	money = 0, moneyPerMin = 0, rollsPerMin = 0,
	startClock = os.clock(), lastRollClock = os.clock(),
	rares = {}, log = {}, earned = 0,
}

local function log(msg, colour)
	table.insert(Stats.log, 1, {
		text = os.date("[%H:%M:%S] ") .. msg,
		colour = colour or Color3.fromRGB(220, 220, 220),
	})
	while #Stats.log > 40 do
		table.remove(Stats.log)
	end
end
-- data helpers ---------------------------------------------------------------
local function pv(fn, ...)
	local ok, v = pcall(fn, ...)
	if ok then return v end
	return nil
end

local function money()
	local v = pv(function() return D.Money() end)
	return typeof(v) == "number" and v or 0
end

local function inventory()
	local v = pv(function() return D.Inventory() end)
	return typeof(v) == "table" and v or {}
end

local function slots()
	local v = pv(function() return D.Slots() end)
	return typeof(v) == "table" and v or {}
end

local function amountOf(name)
	local total = 0
	for _, e in pairs(inventory()) do
		if e.name == name then total = total + (tonumber(e.amount) or 0) end
	end
	return total
end

local function buff(name)
	if not BuffC then return nil end
	local v = pv(BuffC.GetBuff, name)
	return tonumber(v)
end

local function inventoryCap()
	return buff("Unit Storage") or 100
end

local function unitEntries()
	local out = {}
	for key, e in pairs(inventory()) do
		local cfg = ER.getEntryConfig(e.name)
		if cfg and cfg.kind == "Unit" then
			local attrs = e.attributes or {}
			local inc = tonumber(pv(cfg.income, attrs)) or 0
			local ch = tonumber(pv(cfg.chance, attrs)) or 0
			table.insert(out, {
				key = key, name = e.name, attrs = attrs, cfg = cfg,
				income = inc, chance = ch, amount = tonumber(e.amount) or 1,
			})
		end
	end
	return out
end

local function rarityOrder(name)
	if Rar and Rar.Get and name then
		local r = pv(Rar.Get, name)
		if typeof(r) == "table" and tonumber(r.sortOrder) then return tonumber(r.sortOrder) end
	end
	return 1
end

local function fmt(n)
	n = tonumber(n) or 0
	if n >= 1e15 then return string.format("%.2fQa", n / 1e15) end
	if n >= 1e12 then return string.format("%.2fT", n / 1e12) end
	if n >= 1e9 then return string.format("%.2fB", n / 1e9) end
	if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
	if n >= 1e3 then return string.format("%.1fK", n / 1e3) end
	return string.format("%d", n)
end

local function chanceOf(cfg, attrs)
	return tonumber(pv(cfg.chance, attrs)) or 0
end

local function plottedKeys()
	local set = {}
	for _, s in pairs(slots()) do
		if typeof(s) == "table" and s.unitId then set[s.unitId] = true end
	end
	return set
end
-- actions --------------------------------------------------------------------
local A = {}

function A.roll()
	if not R.Roll then return false end
	if os.clock() < (State.nextRollAt or 0) then return false end
	local res = R.Roll:InvokeServer()
	if typeof(res) ~= "table" then
		State.nextRollAt = os.clock() + 0.4
		local cap = inventoryCap()
		local n = #unitEntries()
		if n >= cap and os.clock() - (Stats.lastFullWarn or 0) > 15 then
			Stats.lastFullWarn = os.clock()
			log("roll blocked: " .. n .. "/" .. cap .. " units - freeing space", Color3.fromRGB(255, 200, 120))
		end
		if n >= cap - 5 and os.clock() - (State.lastEmergencySell or 0) > 4 then
			State.lastEmergencySell = os.clock()
			task.spawn(A.sell)
		end
		return false
	end
	State.nextRollAt = os.clock() + Cfg.rollInterval
	Stats.rolls = Stats.rolls + 1
	Stats.rolls = Stats.rolls + 1
	Stats.lastRollClock = os.clock()
	for _, r in ipairs(res) do
		if typeof(r) == "table" and r.result then
			local cfg = ER.getEntryConfig(r.result)
			local ch = cfg and chanceOf(cfg, { mutation = r.mutation }) or 0
			if ch >= Cfg.rareLogChance then
				local label = tostring(r.result)
				if r.mutation then label = tostring(r.mutation) .. " " .. label end
				table.insert(Stats.rares, 1, label .. " (1/" .. fmt(ch) .. ")")
				while #Stats.rares > 8 do table.remove(Stats.rares) end
				log("ROLLED " .. label .. "  1 in " .. fmt(ch), Color3.fromRGB(255, 105, 220))
			end
		end
	end
	return true
end

function A.sellList()
	local plotted = plottedKeys()
	local units = unitEntries()
	table.sort(units, function(a, b) return a.income > b.income end)
	local seen, list = {}, {}
	local function add(u)
		if not seen[u.key] then
			seen[u.key] = true
			table.insert(list, u.key)
		end
	end

	-- tier 1: junk pass - anything commoner than the sell threshold
	for i, u in ipairs(units) do
		if i > Cfg.keepTop and u.chance < Cfg.sellChance
			and not u.attrs.locked and not plotted[u.key]
			and not (Cfg.keepMutated and u.attrs.mutation) then
			add(u)
		end
	end

	local cap = inventoryCap()
	local remaining = #units - #list

	-- tier 2: compaction - hold the inventory down to the unit target
	if Cfg.maxUnits > 0 and remaining > Cfg.maxUnits then
		for i = #units, 1, -1 do
			if remaining <= Cfg.maxUnits then break end
			local u = units[i]
			if i > Cfg.keepTop and not u.attrs.locked and not plotted[u.key] and not seen[u.key] then
				add(u)
				remaining = remaining - 1
			end
		end
	end

	-- tier 3: keep free space (hard protection: locked, plotted, top-keep)
	if remaining > cap - Cfg.reserveUnits then
		for i = #units, 1, -1 do
			if remaining <= cap - Cfg.reserveUnits then break end
			local u = units[i]
			if i > Cfg.keepTop and not u.attrs.locked and not plotted[u.key]
				and rarityOrder(u.cfg.rarity) < Cfg.keepRarity and not seen[u.key] then
				add(u)
				remaining = remaining - 1
			end
		end
	end

	-- tier 4: emergency - the server is about to refuse every roll
	if remaining > cap - 5 then
		for i = #units, 1, -1 do
			if remaining <= cap - 10 then break end
			local u = units[i]
			if i > 3 and not u.attrs.locked and not plotted[u.key] and not seen[u.key] then
				add(u)
				remaining = remaining - 1
			end
		end
	end

	return list, #units, cap
end

function A.sell()
	if not R.SellInventory then return 0 end
	local list, unitCount, cap = A.sellList()
	if #list == 0 then
		if unitCount >= cap - 5 then
			log("nothing sellable but " .. unitCount .. "/" .. cap .. " units", Color3.fromRGB(255, 160, 120))
		end
		return 0
	end
	local sold, gained, i = 0, 0, 1
	while i <= #list do
		local batch = {}
		for j = i, math.min(i + Cfg.sellBatch - 1, #list) do
			table.insert(batch, list[j])
		end
		local moneyGained, unitsSold = R.SellInventory:InvokeServer(batch)
		if typeof(unitsSold) == "number" then sold = sold + unitsSold end
		if typeof(moneyGained) == "number" then gained = gained + moneyGained end
		i = i + Cfg.sellBatch
		if i <= #list then task.wait(0.15) end
	end
	if sold > 0 and (sold >= 3 or unitCount - sold > Cfg.maxUnits + 10) then
		Stats.soldUnits = Stats.soldUnits + sold
		Stats.soldMoney = Stats.soldMoney + gained
		log(string.format("sold %d units for %s  (%d/%d left)", sold, fmt(gained), unitCount - sold, cap), Color3.fromRGB(130, 255, 160))
	end
	return sold
end

function A.collect()
	if not R.CollectBalance then return 0 end
	local n = 0
	for i, s in pairs(slots()) do
		local idx = tonumber(i)
		if idx and typeof(s) == "table" and (tonumber(s.balance) or 0) > 0 then
			R.CollectBalance:FireServer(idx)
			n = n + 1
		end
	end
	return n
end

function A.equipBest()
	if R.EquipBest then R.EquipBest:FireServer() end
	if R.TowerEquipBest then R.TowerEquipBest:FireServer() end
end

local function isPriorityUpgrade(name)
	for _, pat in ipairs(Cfg.priorityUpgrades) do
		if string.find(name, pat, 1, true) then return true end
	end
	return false
end

function A.upgrades()
	if not (Upgrades and R.BuyUpgrade) then return 0 end
	local owned = pv(function() return D.Upgrades() end) or {}
	local cash = money()
	local cands = {}
	for name, u in pairs(Upgrades) do
		local price = tonumber(u.price)
		if not owned[name] and price then
			local parent = Tree and Tree.GetParent and pv(Tree.GetParent, name)
			if parent == nil or parent == "Start" or owned[parent] == true then
				table.insert(cands, { name = name, price = price })
			end
		end
	end
	table.sort(cands, function(a, b)
		local pa, pb = isPriorityUpgrade(a.name), isPriorityUpgrade(b.name)
		if pa ~= pb then return pa end
		return a.price < b.price
	end)
	local bought = 0
	for _, c in ipairs(cands) do
		if cash - c.price >= Cfg.moneyReserve then
			R.BuyUpgrade:FireServer(c.name)
			cash = cash - c.price
			bought = bought + 1
			if bought >= 3 then break end
			task.wait(0.05)
		else
			break
		end
	end
	if bought > 0 then log("bought " .. bought .. " upgrade(s)") end
	return bought
end
function A.quests()
	if not (QuestCfg and R.QuestClaim) then return 0 end
	local claimed = 0
	local state = pv(function() return D.Quests end)
	for pname, pcfg in pairs(QuestCfg.Periods or {}) do
		local snap
		if state and state[pname] then snap = pv(state[pname]) end
		if typeof(snap) == "table" then
			for _, quest in ipairs(pcfg.quests or {}) do
				local prog = (snap.progress or {})[quest.id] or 0
				if prog >= quest.target and not (snap.claimed or {})[quest.id] then
					R.QuestClaim:FireServer(pname, quest.id, snap.expiresAt)
					claimed = claimed + 1
					log("quest claimed: " .. pname .. " / " .. quest.id .. " (+" .. tostring(quest.tickets) .. " tickets)",
						Color3.fromRGB(150, 220, 255))
					task.wait(0.3)
				end
			end
		end
	end
	return claimed
end

function A.questShop()
	if not (QuestCfg and R.QuestBuy) then return 0 end
	local priority = {}
	for i, n in ipairs(Cfg.questShopPriority) do priority[n] = i end
	local items = {}
	for _, item in ipairs(QuestCfg.Shop or {}) do
		if not item.gamepass and priority[item.name] then
			table.insert(items, item)
		end
	end
	table.sort(items, function(a, b) return priority[a.name] < priority[b.name] end)
	local tickets = amountOf("Tickets")
	local bought, names = 0, {}
	for i = 1, Cfg.questShopPerTick do
		local did = false
		for _, item in ipairs(items) do
			if tickets >= item.tickets then
				R.QuestBuy:FireServer(item.name)
				tickets = tickets - item.tickets
				bought = bought + 1
				table.insert(names, item.name)
				did = true
				task.wait(0.3)
				break
			end
		end
		if not did then break end
	end
	if bought > 0 then log("quest shop: " .. table.concat(names, ", "), Color3.fromRGB(255, 220, 140)) end
	return bought
end

function A.claims()
	if R.DailyClaim then
		local last = tonumber(pv(function() return D.LastDailyRewardClaim() end)) or 0
		if os.time() - last >= 82800 then
			R.DailyClaim:FireServer()
			log("daily reward claimed")
		end
	end
	if R.GroupClaim and not pv(function() return D.ClaimedGroupReward() end) then
		R.GroupClaim:FireServer()
	end
	if R.OfflineClaim and (tonumber(pv(function() return D.PendingOfflineEarnings() end)) or 0) > 0 then
		R.OfflineClaim:FireServer()
		log("offline earnings claimed")
	end
end

function A.gradeTrait()
	local gems = amountOf("Gems")
	local rerolls = amountOf("Trait Reroll")
	if (not Cfg.enabled.autoGrade or gems < 1) and (not Cfg.enabled.autoTrait or rerolls < 1) then return false end
	local units = unitEntries()
	table.sort(units, function(a, b) return a.income > b.income end)
	for _, u in ipairs(units) do
		if Cfg.enabled.autoGrade and gems >= 1 then
			local g = Grades and u.attrs.grade and Grades[u.attrs.grade]
			local mult = (g and tonumber(g.incomeMultiplier)) or 1
			if mult < Cfg.gradeTarget then
				R.GradeRoll:FireServer(u.key, false)
				gems = gems - 1
				return true
			end
		end
		if Cfg.enabled.autoTrait and rerolls >= 1 then
			local t = Traits and u.attrs.trait and Traits[u.attrs.trait]
			local mult = (t and tonumber(t.incomeMultiplier)) or 0
			if mult < Cfg.traitTarget then
				R.TraitRoll:FireServer(u.key, false)
				rerolls = rerolls - 1
				return true
			end
		end
	end
	return false
end

function A.dice()
	if not (DiceCfg and R.BuyDice) then return end
	local all = pv(DiceCfg.GetAll) or {}
	local owned = pv(function() return D.OwnedDice() end) or {}
	local cash = money()
	local bestOwned, bestLuck = nil, -1
	local bestBuy, bestBuyLuck = nil, -1
	for name, cfg in pairs(all) do
		local luck = tonumber(cfg.luck) or 0
		if owned[name] then
			if luck > bestLuck then bestLuck, bestOwned = luck, name end
		else
			local price = tonumber(cfg.price)
			if price and price <= cash * Cfg.diceSpendFrac and luck > bestBuyLuck then
				bestBuyLuck, bestBuy = luck, name
			end
		end
	end
	if bestBuy and bestBuyLuck > math.max(bestLuck, 0) * 1.3 then
		R.BuyDice:FireServer(bestBuy)
		log("bought dice " .. bestBuy .. " (luck x" .. tostring(bestBuyLuck) .. ")")
		task.wait(0.5)
		return
	end
	local equipped = pv(function() return D.Dice() end)
	if bestOwned and equipped ~= bestOwned and R.EquipDice then
		R.EquipDice:FireServer(bestOwned)
		log("equipped dice " .. bestOwned .. " (luck x" .. tostring(bestLuck) .. ")")
	end
end

function A.boostSpins()
	local done = 0
	for key, e in pairs(inventory()) do
		local cfg = ER.getEntryConfig(e.name)
		if cfg and cfg.kind == "Spin" and R.SpinUse then
			R.SpinUse:FireServer(key)
			done = done + 1
		elseif cfg and cfg.kind == "Boost" and R.BoostUse then
			R.BoostUse:FireServer(key)
			done = done + 1
		end
		if done >= 3 then break end
		task.wait(0.05)
	end
	if done > 0 then log("used " .. done .. " boost/spin") end
	return done
end

function A.rebirth()
	if not (Rebirths and R.Rebirth) then return end
	local cur = tonumber(pv(function() return D.Rebirth() end)) or 0
	local next_ = pv(Rebirths.GetNext, cur)
	if next_ and money() >= (tonumber(next_.cost) or math.huge) then
		R.Rebirth:FireServer()
		log("REBIRTH -> " .. tostring(cur + 1) .. "  (luck x" .. tostring(next_.luckMultiplier) .. ")", Color3.fromRGB(255, 205, 90))
	end
end

function A.fuse()
	if State.fuseActive or not R.Fuse then return end
	local plotted = plottedKeys()
	local units = unitEntries()
	if #units < Cfg.fuseFloorUnits then return end
	table.sort(units, function(a, b) return a.income > b.income end)
	local pool = {}
	for i, u in ipairs(units) do
		if i > Cfg.keepTop and u.amount == 1 and not u.cfg.limited and not u.attrs.locked
			and not plotted[u.key] and u.chance <= Cfg.fuseMaxChance then
			table.insert(pool, u)
		end
	end
	if #pool < 3 then return end
	table.sort(pool, function(a, b) return a.income < b.income end)
	local a1, a2, a3 = pool[1], pool[2], pool[3]
	local cost = (FusingCfg and FusingCfg.GetCost(a1.chance + a2.chance + a3.chance)) or math.huge
	if money() < math.max(Cfg.fuseMinMoney, cost * Cfg.fuseMoneyMultiple) then return end
	State.fuseActive = true
	State.lastFuse = { a1.name, a2.name, a3.name }
	R.Fuse:FireServer(a1.key, a2.key, a3.key)
	task.delay(5, function() State.fuseActive = false end)
end

if R.FuseResult then
	State.fuseConn = R.FuseResult.OnClientEvent:Connect(function(unit, err)
		if err ~= nil then
			local msg = tostring(err)
			local colour = Color3.fromRGB(255, 120, 120)
			if string.find(msg, "Please wait", 1, true) then
				colour = Color3.fromRGB(150, 150, 160)
			end
			log("fuse: " .. msg, colour)
			return
		end
		if typeof(unit) ~= "table" then return end
		local cfg = ER.getEntryConfig(unit.name)
		local ch = cfg and chanceOf(cfg, unit.attributes) or 0
		local label = tostring(unit.name)
		if unit.attributes and unit.attributes.mutation then
			label = tostring(unit.attributes.mutation) .. " " .. label
		end
		local consumed = State.lastFuse and table.concat(State.lastFuse, " + ") or "3 units"
		log(string.format("FUSED %s -> %s  (1 in %s)", consumed, label, fmt(ch)), Color3.fromRGB(255, 200, 120))
	end)
end
function A.tower()
	if not (TowersCfg and R.TowerPlay) then return end
	if State.towerActive then
		local res = R.TowerFloor:InvokeServer()
		if res == nil then
			State.towerStalls = State.towerStalls + 1
			if State.towerStalls >= 5 then
				R.TowerCancel:InvokeServer()
				State.towerActive = false
				State.towerStalls = 0
				State.towerCooldown = os.clock() + 8
			end
		else
			State.towerStalls = 0
		end
		return
	end
	if (State.towerCooldown or 0) > os.clock() then return end
	local team = pv(function() return D.TowerTeam() end)
	local hasTeam = false
	if typeof(team) == "table" then
		for _, v in pairs(team) do
			if v then hasTeam = true break end
		end
	end
	if not hasTeam then
		if R.TowerEquipBest then R.TowerEquipBest:FireServer() end
		State.towerCooldown = os.clock() + 3
		return
	end
	local name = Cfg.towerName
	if not name then
		local all = pv(TowersCfg.GetAll)
		local best, order = nil, -1
		if typeof(all) == "table" then
			for tname, tcfg in pairs(all) do
				local o = tonumber(tcfg.order) or 0
				if o > order then order, best = o, tname end
			end
		end
		name = best
	end
	if not name then return end
	if R.TowerPlay:InvokeServer(name) then
		State.towerActive = true
		State.towerStalls = 0
		log("tower started: " .. name, Color3.fromRGB(255, 180, 120))
	end
end

function A.redeem(silent)
	if not (MonetCfg and MonetCfg.Codes and R.Redeem) then return 0 end
	local done = pv(function() return D.RedeemedCodes() end) or {}
	local n = 0
	for code in pairs(MonetCfg.Codes) do
		if not done[code] then
			R.Redeem:FireServer(code)
			n = n + 1
			task.wait(0.6)
		end
	end
	if n > 0 and not silent then
		log("redeemed " .. n .. " code(s)", Color3.fromRGB(180, 255, 140))
	end
	return n
end
-- scheduler (Heartbeat driven: every action is a cheap state check, real work
-- runs in its own thread so a blocking InvokeServer never stalls the frame) ---
local Tasks = {}
local function register(name, interval, fn, gate)
	Tasks[name] = { interval = interval, fn = fn, gate = gate, last = 0, running = false }
end

local moneySamples, rollSamples = {}, {}
local function updateStats()
	Stats.money = money()
	local now = os.clock()
	local prev = State.lastMoney
	if prev and Stats.money > prev then
		Stats.earned = Stats.earned + (Stats.money - prev)
	end
	State.lastMoney = Stats.money
	table.insert(moneySamples, { t = now, m = Stats.earned })
	while #moneySamples > 2 and now - moneySamples[1].t > 60 do table.remove(moneySamples, 1) end
	local a, b = moneySamples[1], moneySamples[#moneySamples]
	if b.t - a.t > 5 then Stats.moneyPerMin = (b.m - a.m) / (b.t - a.t) * 60 end

	table.insert(rollSamples, { t = now, n = Stats.rolls })
	while #rollSamples > 2 and now - rollSamples[1].t > 60 do table.remove(rollSamples, 1) end
	local ra, rb = rollSamples[1], rollSamples[#rollSamples]
	if rb.t - ra.t > 5 then Stats.rollsPerMin = (rb.n - ra.n) / (rb.t - ra.t) * 60 end
end

register("roll",      function() return 0.4 end, function() A.roll() end, "autoRoll")
register("collect",   function() return Cfg.collectInterval end, A.collect, "autoCollect")
register("sell",      function() return (#unitEntries() >= inventoryCap() - Cfg.reserveUnits) and 2 or Cfg.sellInterval end, A.sell, "autoSell")
register("equipBest", 20, A.equipBest, "autoEquipBest")
register("upgrades",  function() return Cfg.upgradeInterval end, A.upgrades, "autoUpgrades")
register("quests",    function() return Cfg.questInterval end, A.quests, "autoQuests")
register("questShop", function() return Cfg.questInterval end, A.questShop, "autoQuestShop")
register("claims",    function() return Cfg.claimInterval end, A.claims, "autoClaims")
register("gradeTrait",function() return Cfg.gradeInterval end, A.gradeTrait, function() return Cfg.enabled.autoGrade or Cfg.enabled.autoTrait end)
register("dice",      function() return Cfg.diceInterval end, A.dice, "autoDice")
register("boostSpins",30, A.boostSpins, "autoBoostSpins")
register("redeem",    5, A.redeem, "autoRedeem")
register("rebirth",   10, A.rebirth, "autoRebirth")
register("fuse",      function() return Cfg.fuseInterval end, A.fuse, "autoFuse")
register("tower",     function() return Cfg.towerInterval end, A.tower, "autoTower")
register("killAutoRoll", 10, function()
	if pv(function() return D.AutoRoll() end) then
		R.SetAutoRoll:FireServer(false)
		log("game AutoRoll switched off", Color3.fromRGB(160, 200, 255))
	end
end, "killAutoRoll")
register("stats",     1, updateStats, nil)

local function runTask(name, t)
	local iv = typeof(t.interval) == "function" and t.interval() or t.interval
	if os.clock() - t.last < iv then return end
	t.last = os.clock()
	t.running = true
	task.spawn(function()
		local ok, err = pcall(t.fn)
		t.running = false
		if not ok then
			log(name .. ": " .. tostring(err), Color3.fromRGB(255, 120, 120))
		end
	end)
end

local function schedulerTick()
	for name, t in pairs(Tasks) do
		local gate = t.gate
		local on
		if gate == nil then
			on = true
		elseif typeof(gate) == "function" then
			on = gate()
		else
			on = Cfg.enabled[gate]
		end
		if on and not t.running then
			runTask(name, t)
		end
	end
end

State.scheduler = RunService.Heartbeat:Connect(function()
	if not State.running then return end
	local ok, err = pcall(schedulerTick)
	if not ok then
		warn("[ADH] scheduler: " .. tostring(err))
	end
end)
-- UI -------------------------------------------------------------------------
local Theme = {
	bg     = Color3.fromRGB(16, 16, 20),
	panel  = Color3.fromRGB(26, 26, 34),
	row    = Color3.fromRGB(36, 36, 46),
	accent = Color3.fromRGB(255, 92, 172),
	text   = Color3.fromRGB(236, 236, 242),
	dim    = Color3.fromRGB(152, 152, 166),
	good   = Color3.fromRGB(122, 255, 152),
	bad    = Color3.fromRGB(255, 118, 118),
}

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do
		o[k] = v
	end
	o.Parent = parent
	return o
end

local playerGui = plr:WaitForChild("PlayerGui")
local stale = playerGui:FindFirstChild("AnimeDiceHub")
if stale then stale:Destroy() end

local gui = new("ScreenGui", {
	Name = "AnimeDiceHub", ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999,
}, playerGui)

local main = new("Frame", {
	Name = "Main", Size = UDim2.new(0, 334, 0, 476),
	Position = UDim2.new(0, 18, 0.5, -238), BackgroundColor3 = Theme.bg,
	BorderSizePixel = 0, Active = true,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, main)
new("UIStroke", { Color = Theme.accent, Transparency = 0.55, Thickness = 1 }, main)

local header = new("Frame", {
	Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = Theme.panel, BorderSizePixel = 0,
}, main)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, header)
new("TextLabel", {
	Size = UDim2.new(1, -180, 1, 0), Position = UDim2.new(0, 10, 0, 0),
	BackgroundTransparency = 1, Text = "ANIME DICE HUB  v" .. HUB_VER,
	Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Theme.accent,
	TextXAlignment = Enum.TextXAlignment.Left,
}, header)
local closeBtn = new("TextButton", {
	Size = UDim2.new(0, 24, 0, 22), Position = UDim2.new(1, -30, 0, 6),
	BackgroundColor3 = Theme.bad, Text = "X", Font = Enum.Font.GothamBold,
	TextSize = 12, TextColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0,
}, header)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, closeBtn)
local stopBtn = new("TextButton", {
	Size = UDim2.new(0, 66, 0, 22), Position = UDim2.new(1, -102, 0, 6),
	BackgroundColor3 = Theme.accent, Text = "STOP ALL", Font = Enum.Font.GothamBold,
	TextSize = 10, TextColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0,
}, header)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, stopBtn)

local statsLabel = new("TextLabel", {
	Size = UDim2.new(1, -16, 0, 78), Position = UDim2.new(0, 8, 0, 40),
	BackgroundColor3 = Theme.panel, BorderSizePixel = 0, Text = "", Font = Enum.Font.Code,
	TextSize = 12, TextColor3 = Theme.text, TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
}, main)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, statsLabel)
new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingTop = UDim.new(0, 5) }, statsLabel)

local scroll = new("ScrollingFrame", {
	Size = UDim2.new(1, -16, 1, -246), Position = UDim2.new(0, 8, 0, 124),
	BackgroundTransparency = 1, BorderSizePixel = 0, CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
	ScrollBarThickness = 5, ScrollBarImageColor3 = Theme.accent,
}, main)
new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)
new("UIPadding", { PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6) }, scroll)

local logLabel = new("TextLabel", {
	Size = UDim2.new(1, -16, 0, 100), Position = UDim2.new(0, 8, 1, -118),
	BackgroundColor3 = Theme.panel, BorderSizePixel = 0, Text = "", Font = Enum.Font.Code,
	TextSize = 11, TextColor3 = Theme.dim, TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top, RichText = true,
}, main)
new("UICorner", { CornerRadius = UDim.new(0, 8) }, logLabel)
new("UIPadding", { PaddingLeft = UDim.new(0, 7), PaddingTop = UDim.new(0, 4) }, logLabel)

new("TextLabel", {
	Size = UDim2.new(1, -16, 0, 12), Position = UDim2.new(0, 8, 1, -16),
	BackgroundTransparency = 1, Text = "made with Project UAI  ·  model deepseek-v4-flash",
	Font = Enum.Font.Gotham, TextSize = 9, TextColor3 = Theme.dim,
	TextXAlignment = Enum.TextXAlignment.Center,
}, main)

local order = 0
local function nextOrder()
	order = order + 1
	return order
end

local refreshers = {}

local function toggleRow(key, label)
	local row = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 24), BackgroundColor3 = Theme.row, Text = "",
		AutoButtonColor = true, BorderSizePixel = 0, LayoutOrder = nextOrder(),
	}, scroll)
	new("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
	new("TextLabel", {
		Size = UDim2.new(1, -70, 1, 0), Position = UDim2.new(0, 8, 0, 0), BackgroundTransparency = 1,
		Text = label, Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = Theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)
	local state = new("TextLabel", {
		Size = UDim2.new(0, 54, 1, 0), Position = UDim2.new(1, -58, 0, 0), BackgroundTransparency = 1,
		Text = "", Font = Enum.Font.GothamBold, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
	}, row)
	local function refresh()
		local on = Cfg.enabled[key]
		state.Text = on and "ON" or "OFF"
		state.TextColor3 = on and Theme.good or Theme.bad
		row.BackgroundColor3 = on and Color3.fromRGB(30, 48, 36) or Theme.row
	end
	row.MouseButton1Click:Connect(function()
		Cfg.enabled[key] = not Cfg.enabled[key]
		refresh()
		if key == "serverAutoSell" and R.SetSetting then
			R.SetSetting:FireServer("AutoSell", Cfg.enabled[key] and Cfg.serverAutoSellValue or 0)
			log("server AutoSell = " .. tostring(Cfg.enabled[key] and Cfg.serverAutoSellValue or 0))
		end
	end)
	refresh()
	refreshers[key] = refresh
	return row
end

local function numberRow(cfgKey, label, suffix)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 24), BackgroundColor3 = Theme.row,
		BorderSizePixel = 0, LayoutOrder = nextOrder(),
	}, scroll)
	new("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
	new("TextLabel", {
		Size = UDim2.new(1, -100, 1, 0), Position = UDim2.new(0, 8, 0, 0), BackgroundTransparency = 1,
		Text = label .. (suffix and ("  (" .. suffix .. ")") or ""), Font = Enum.Font.Gotham,
		TextSize = 12, TextColor3 = Theme.dim, TextXAlignment = Enum.TextXAlignment.Left,
	}, row)
	local box = new("TextBox", {
		Size = UDim2.new(0, 84, 0, 18), Position = UDim2.new(1, -92, 0, 3),
		BackgroundColor3 = Theme.panel, Text = tostring(Cfg[cfgKey]), Font = Enum.Font.Code,
		TextSize = 12, TextColor3 = Theme.text, ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Center, BorderSizePixel = 0,
	}, row)
	new("UICorner", { CornerRadius = UDim.new(0, 5) }, box)
	box.FocusLost:Connect(function()
		local n = tonumber(box.Text)
		if n then
			Cfg[cfgKey] = n
			box.Text = tostring(n)
			if cfgKey == "serverAutoSellValue" and Cfg.enabled.serverAutoSell and R.SetSetting then
				R.SetSetting:FireServer("AutoSell", n)
			end
			log(cfgKey .. " = " .. tostring(n))
		else
			box.Text = tostring(Cfg[cfgKey])
		end
	end)
	return row
end

local function buttonRow(label, colour, fn)
	local row = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = colour, Text = label,
		Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Color3.new(0, 0, 0),
		BorderSizePixel = 0, LayoutOrder = nextOrder(),
	}, scroll)
	new("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
	row.MouseButton1Click:Connect(function()
		task.spawn(function()
			local ok, err = pcall(fn)
			if not ok then log("action failed: " .. tostring(err), Theme.bad) end
		end)
	end)
	return row
end
-- roll-showcase suppressor --------------------------------------------------
-- The rare-roll showcase is client-only (RollCutscene): it parents a ScreenGui
-- named "CutsceneBlackFade", clones Assets/.../CameraModel + lines into Workspace,
-- anchors your character, sets the camera to Scriptable and drives it from
-- CamPart, then reveals a "1 in X" counter behind black bars for ~5s.
-- This kills that, and only that: the dice roll animation / roll UI are untouched,
-- and nothing here talks to the server.
local function killShowcase()
	for _, g in ipairs(playerGui:GetChildren()) do
		if g:IsA("ScreenGui") and g.Name ~= "AnimeDiceHub" and string.find(g.Name, "Cutscene", 1, true) then
			pcall(function() g:Destroy() end)
		end
	end

	local cut = UIRefs and UIRefs.Root and UIRefs.Root:FindFirstChild("Cutscene")
	if cut then
		for _, c in ipairs(cut:GetChildren()) do
			if c:IsA("GuiObject") then c.Visible = false end
		end
	end

	for _, m in ipairs(workspace:GetChildren()) do
		if m.Name == "CameraModel" or m.Name == "lines" then
			for _, d in ipairs(m:GetDescendants()) do
				if d.Name == "CamPart" then pcall(function() d:Destroy() end) end
			end
			if m.Name == "lines" then pcall(function() m:Destroy() end) end
		end
	end

	local cam = workspace.CurrentCamera
	local char = plr.Character
	if char then
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if hrp then hrp.Anchored = false end
		for _, d in ipairs(char:GetDescendants()) do
			if d:IsA("BasePart") then d.LocalTransparencyModifier = 0 end
		end
	end
	if cam then
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if cam.CameraType == Enum.CameraType.Scriptable then
			cam.CameraType = Enum.CameraType.Custom
		end
		if hum then cam.CameraSubject = hum end
	end
end

State.cutsceneConn = playerGui.DescendantAdded:Connect(function(inst)
	if not Cfg.enabled.killShowcase then return end
	if not inst:IsA("ScreenGui") then return end
	local isCutscene = inst.Name == "CutsceneBlackFade"
	if isCutscene then
		State.suppressUntil = os.clock() + 6
	end
	if isCutscene or os.clock() < (State.suppressUntil or 0) then
		pcall(function() inst:Destroy() end)
		if isCutscene then
			-- the showcase sets Scriptable ~0.5s in, so sweep the whole window
			task.spawn(killShowcase)
			for _, d in ipairs({ 0.35, 0.7, 1.2, 2.5, 4.2 }) do
				task.delay(d, killShowcase)
			end
			if os.clock() - (State.lastShowcaseLog or 0) > 5 then
				State.lastShowcaseLog = os.clock()
				log("roll showcase suppressed", Color3.fromRGB(160, 200, 255))
			end
		end
	end
end)

-- clear one that is already mid-flight when the hub loads
task.spawn(function()
	if Cfg.enabled.killShowcase then pcall(killShowcase) end
end)
toggleRow("autoRoll", "Auto Roll")
toggleRow("autoSell", "Auto Sell Junk")
toggleRow("autoCollect", "Auto Collect Plot")
toggleRow("autoEquipBest", "Auto Equip Best")
toggleRow("autoUpgrades", "Auto Buy Upgrades")
toggleRow("autoDice", "Auto Dice (buy / equip best)")
toggleRow("autoQuests", "Auto Claim Quests")
toggleRow("autoQuestShop", "Auto Spend Tickets")
toggleRow("autoClaims", "Auto Daily / Group / Offline")
toggleRow("autoGrade", "Auto Grade  (1 Gem)")
toggleRow("autoTrait", "Auto Trait  (1 Reroll)")
toggleRow("autoBoostSpins", "Auto Use Boosts / Spins")
toggleRow("autoRedeem", "Auto Redeem Codes")
toggleRow("autoRebirth", "Auto Rebirth")
toggleRow("autoTower", "Auto Tower")
toggleRow("autoFuse", "Auto Fuse Junk -> Rare")
toggleRow("killShowcase", "Kill Roll Showcase")
toggleRow("killAutoRoll", "Kill In-Game AutoRoll")
toggleRow("serverAutoSell", "Server AutoSell (profile)")

numberRow("rollInterval", "Roll interval", "s")
numberRow("collectInterval", "Collect interval", "s")
numberRow("sellInterval", "Sell interval", "s")
numberRow("sellChance", "Sell below 1-in-X", "chance")
numberRow("keepTop", "Keep best units", "count")
numberRow("maxUnits", "Sell above N units", "count")
numberRow("reserveUnits", "Free space reserve", "count")
numberRow("fuseMaxChance", "Fuse below 1-in-X", "chance")
numberRow("gradeTarget", "Grade target", "income x")
numberRow("traitTarget", "Trait target", "income x")
numberRow("serverAutoSellValue", "Server AutoSell value", "1-in-X")

buttonRow("SELL JUNK NOW", Theme.accent, function() A.sell() end)
buttonRow("COLLECT NOW", Color3.fromRGB(150, 220, 255), function()
	local n = A.collect()
	log("collected " .. tostring(n) .. " slot(s)", Color3.fromRGB(150, 220, 255))
end)
buttonRow("EQUIP BEST + TOWER TEAM", Color3.fromRGB(180, 255, 160), function() A.equipBest() end)
buttonRow("CLAIM QUESTS + REWARDS", Color3.fromRGB(255, 220, 140), function()
	A.quests()
	A.claims()
end)
buttonRow("REDEEM ALL CODES", Color3.fromRGB(200, 180, 255), function() A.redeem() end)
buttonRow("USE BOOSTS / SPINS", Color3.fromRGB(255, 170, 200), function() A.boostSpins() end)
buttonRow("FUSE 3 COMMONS", Color3.fromRGB(255, 200, 120), function() A.fuse() end)

-- live UI refresh ------------------------------------------------------------
local function hex(c)
	return string.format("#%02X%02X%02X", math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255))
end

local uiAcc = 0
State.uiConn = RunService.Heartbeat:Connect(function(dt)
	if not State.running then return end
	local ok, err = pcall(function()
	uiAcc = uiAcc + dt
	if uiAcc < 0.5 then return end
	uiAcc = 0

	local units, gems, rerolls, tickets, invCount = 0, 0, 0, 0, 0
	for _, e in pairs(inventory()) do
		invCount = invCount + 1
		if e.name == "Gems" then gems = gems + (tonumber(e.amount) or 0)
		elseif e.name == "Trait Reroll" then rerolls = rerolls + (tonumber(e.amount) or 0)
		elseif e.name == "Tickets" then tickets = tickets + (tonumber(e.amount) or 0)
		else
			local cfg = ER.getEntryConfig(e.name)
			if cfg and cfg.kind == "Unit" then units = units + 1 end
		end
	end

	statsLabel.Text = table.concat({
		string.format("Money    %-9s  +%s/min", fmt(Stats.money), fmt(Stats.moneyPerMin)),
		string.format("Rolls    %-9d  %.0f/min   sold %d (%s)", Stats.rolls, Stats.rollsPerMin, Stats.soldUnits, fmt(Stats.soldMoney)),
		string.format("Units    %d/%d   rebirth %s   dice %s", units, inventoryCap(),
			tostring(pv(function() return D.Rebirth() end)), tostring(pv(function() return D.Dice() end))),
		string.format("Buffs    Luck x%s  Money x%s  Roll %ss", tostring(buff("Luck")), tostring(buff("Money Multiplier")), tostring(buff("Roll Duration"))),
		string.format("Gems %-6d Rerolls %-6d Tickets %-6d", gems, rerolls, tickets),
		string.format("Rares: %s", #Stats.rares > 0 and Stats.rares[1] or "-"),
	}, "\n")

	local lines = {}
	for i = 1, math.min(7, #Stats.log) do
		local e = Stats.log[i]
		table.insert(lines, "<font color='" .. hex(e.colour) .. "'>" .. e.text .. "</font>")
	end
	logLabel.Text = table.concat(lines, "\n")
	end)
	if not ok then warn("[ADH] ui: " .. tostring(err)) end
end)

-- dragging -------------------------------------------------------------------
local dragging, dragStart, startPos = false, nil, nil
header.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = main.Position
		local conn
		conn = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
				conn:Disconnect()
			end
		end)
	end
end)
State.dragConn = UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - dragStart
		main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)
State.keyConn = UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Cfg.uiKey then
		main.Visible = not main.Visible
	end
end)
closeBtn.MouseButton1Click:Connect(function()
	main.Visible = false
end)

-- API ------------------------------------------------------------------------
local API = {}
API.version = HUB_VER
API.cfg = Cfg
API.stats = Stats
API.actions = A
API.tasks = Tasks

function API.set(k, v)
	Cfg[k] = v
	if refreshers[k] then refreshers[k]() end
end

function API.toggle(k)
	Cfg.enabled[k] = not Cfg.enabled[k]
	if refreshers[k] then refreshers[k]() end
	if k == "serverAutoSell" and R.SetSetting then
		R.SetSetting:FireServer("AutoSell", Cfg.enabled[k] and Cfg.serverAutoSellValue or 0)
	end
	return Cfg.enabled[k]
end

API.sellNow = A.sell
API.collectNow = A.collect
API.equipBest = A.equipBest
API.claimNow = A.claims
API.redeemAll = A.redeem
API.log = log

function API.stop()
	getgenv().__ADH_STOP = debug.traceback("[ADH] stop called", 2)
	State.running = false
	for _, key in ipairs({ "scheduler", "uiConn", "dragConn", "keyConn", "fuseConn", "cutsceneConn" }) do
		local c = State[key]
		if typeof(c) == "RBXScriptConnection" then pcall(function() c:Disconnect() end) end
		State[key] = nil
	end
	if gui then gui:Destroy() end
	getgenv().__ANIME_DICE_HUB = nil
	warn("[ADH] stopped")
end

stopBtn.MouseButton1Click:Connect(function() API.stop() end)
getgenv().__ANIME_DICE_HUB = API

-- startup --------------------------------------------------------------------
task.spawn(function()
	log("ANIME DICE HUB v" .. HUB_VER .. " online  ·  Project UAI / deepseek-v4-flash")
	print(string.format("[ADH] hub loaded: %d tasks, %d remotes", (function() local n = 0 for _ in pairs(Tasks) do n = n + 1 end return n end)(), 33))
	pcall(A.claims)
	pcall(A.collect)
	pcall(A.equipBest)
	pcall(A.quests)
	pcall(A.redeem)
	pcall(A.boostSpins)
	warn("[ADH] ready - RightShift toggles the UI")
end)

return API
