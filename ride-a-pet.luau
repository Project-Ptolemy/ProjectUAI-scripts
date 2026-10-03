-- Ride A Pet: full egg pipeline, updated for the Nests update (Oct 2026).
--   COLLECT = stand at a config's Position under ServerData.ActiveEggs and
--             EggPickup:FireServer(<config name>).
--   DROP    = BasketDrop:FireServer() at my plot (bank / satchel).
--   HATCH   = Hatch:FireServer({ EggKey = <egg's EggKey attr> }).
--   PLANT   = hold (equip) a Backpack Tool tagged "Egg", then
--             EggPlaced:FireServer({ NestId = <nest name> }) on one of my
--             plot's Nests (Unlocked=true, not Occupied).
--   UNLOCK  = Remotes.Game.Plot.Nests:FireServer(<nest number>) - costs cash.
-- Growth is weight aware: GameData.General.GrowthTimeFor(GrowthTime, Weight)
-- and DayNight.GrowthElapsed (night grows 10x). Skip Growth is never fired
-- (it costs Robux). Runs off a single Heartbeat loop.

local RS         = game:GetService("ReplicatedStorage")
local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService= game:GetService("HttpService")
local LP         = Players.LocalPlayer

local rank = { Common = 1, Uncommon = 2, Rare = 2, Epic = 3, Legendary = 4, Mythic = 5, Divine = 6, Ethereal = 7, Secret = 8 }
local rankName = { [1] = "all", [2] = "Rare+", [3] = "Epic+", [4] = "Legendary+", [5] = "Mythic+", [6] = "Divine+", [7] = "Ethereal+" }

local Eggs      = require(RS:WaitForChild("GameData"):WaitForChild("Eggs"))
local General2  = require(RS:WaitForChild("GameData"):WaitForChild("General"))
local NestsData = require(RS:WaitForChild("GameData"):WaitForChild("Nests"))
local DayNight  = require(RS:WaitForChild("GameServices"):WaitForChild("DayNight"))

local GameRemotes = RS:WaitForChild("Remotes"):WaitForChild("Game")
local EggPickup   = GameRemotes:WaitForChild("EggPickup")
local BasketDrop  = GameRemotes:WaitForChild("BasketDrop")
local Hatch       = GameRemotes:WaitForChild("Hatch")
local EggPlaced   = GameRemotes:WaitForChild("EggPlaced")
local NestUnlock  = GameRemotes:WaitForChild("Plot"):WaitForChild("Nests")
local ae          = RS:WaitForChild("ServerData"):WaitForChild("ActiveEggs")
local basket      = LP:WaitForChild("Basket")

-- ------------------------------------------------------------------
-- Persistent state (survives re-runs)
-- ------------------------------------------------------------------
local S = rawget(_G, "RideAPetEggFarm")
if type(S) ~= "table" then S = {}; _G.RideAPetEggFarm = S end
S.log       = S.log or {}
S.blocklist = S.blocklist or {}   -- world egg config name -> os.clock() cooldown

-- config with defaults (kept across re-runs)
local cfg = S.cfg or {}
S.cfg = cfg
if cfg.collect        == nil then cfg.collect = true end
if cfg.collectMinRank == nil then cfg.collectMinRank = 6 end      -- Divine+
if cfg.collectWhenFull== nil then cfg.collectWhenFull = false end -- overflow to satchel
if cfg.hatch          == nil then cfg.hatch = true end
if cfg.hatchMinRank   == nil then cfg.hatchMinRank = 1 end        -- hatch anything ready
if cfg.plant          == nil then cfg.plant = false end           -- opt-in backlog drain
if cfg.plantMinRank   == nil then cfg.plantMinRank = 1 end
if cfg.autoUnlock     == nil then cfg.autoUnlock = false end      -- spend cash on nests

-- session counters
local st = S.stats or {}
S.stats = st
st.collected = st.collected or 0
st.hatched   = st.hatched or 0
st.planted   = st.planted or 0

-- ------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------
local function log(...)
  local t = {}
  for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
  table.insert(S.log, 1, string.format("[%.0f] %s", workspace:GetServerTimeNow() % 100000, table.concat(t, " ")))
  while #S.log > 60 do table.remove(S.log) end
end
S.log_fn = log

local function root()
  local ch = LP.Character
  if not ch then return nil end
  local h = ch:FindFirstChildOfClass("Humanoid")
  if not h or h.Health <= 0 then return nil end
  return ch:FindFirstChild("HumanoidRootPart")
end

local function snap(v)
  local r = root()
  if not r then return false end
  r.CFrame = CFrame.new(v)
  r.AssemblyLinearVelocity = Vector3.zero
  return true
end

local function myPlot()
  local plots = workspace:FindFirstChild("Plots")
  if not plots then return nil end
  for _, pl in ipairs(plots:GetChildren()) do
    local d = pl:FindFirstChild("Data")
    local o = d and d:FindFirstChild("Owner")
    if o and o.Value == LP then return pl end
  end
end

local function plotEggFolder()
  local pl = myPlot()
  return pl and pl:FindFirstChild("Eggs")
end

local function plotEggs()
  local ef = plotEggFolder()
  return ef and #ef:GetChildren() or -1
end

local function plotBase()
  local pl = myPlot()
  return pl and pl:FindFirstChild("Baseplate")
end

-- nests: slots on my plot; the server's Unlocked / Occupied attributes are
-- authoritative (a Locked model can linger client-side after unlocking)
local function myNests()
  local pl = myPlot()
  return pl and pl:FindFirstChild("Nests")
end

local function nestsOwned()
  local pl = myPlot()
  return pl ~= nil and pl:GetAttribute("NestsOwnerLoaded") == LP.UserId
end

local function nestFree(nest)
  if not nest then return false end
  if not nestsOwned() then return false end
  if nest:GetAttribute("Unlocked") ~= true then return false end
  if nest:GetAttribute("Occupied") == true then return false end
  return true
end

local function nestCounts()
  local ns = myNests()
  if not ns then return 0, 0 end
  local total, free = 0, 0
  for _, nest in ipairs(ns:GetChildren()) do
    total = total + 1
    if nestFree(nest) then free = free + 1 end
  end
  return free, total
end

local function pickFreeNest()
  local ns = myNests()
  if not ns then return nil end
  local best, bestN
  for _, nest in ipairs(ns:GetChildren()) do
    if nestFree(nest) then
      local n = tonumber(nest.Name) or 99
      if not bestN or n < bestN then best, bestN = nest, n end
    end
  end
  return best
end

-- lowest-numbered nest the server has not unlocked yet, for the unlock action
local function nextLockedNest()
  local ns = myNests()
  if not ns then return nil end
  local best, bestN
  for _, nest in ipairs(ns:GetChildren()) do
    if nest:GetAttribute("Unlocked") ~= true then
      local n = tonumber(nest.Name) or 99
      if not bestN or n < bestN then best, bestN = nest, n end
    end
  end
  return best
end

local function eggPos(egg)
  if egg.PrimaryPart then return egg.PrimaryPart.Position end
  local p = egg:FindFirstChild("RootPart") or egg:FindFirstChild("Handle") or egg:FindFirstChildWhichIsA("BasePart", true)
  return p and p.Position
end

local function eggPlaceTime(egg)
  local ed = egg:FindFirstChild("EggData")
  local pt = ed and ed:FindFirstChild("PlaceTime")
  return pt and tonumber(pt.Value)
end

local function eggWeight(egg)
  local ed = egg:FindFirstChild("EggData")
  local w = ed and ed:FindFirstChild("Weight")
  return (w and tonumber(w.Value)) or 1
end

-- growth requirement mirrors the game's readiness gate (HatchInteraction)
local function growthRequired(egg)
  local def = Eggs[egg.Name]
  if not def then return 0 end
  return General2.GrowthTimeFor(def.GrowthTime, eggWeight(egg))
end

local function growthElapsed(egg, now)
  local pt = eggPlaceTime(egg)
  if not pt then return 0 end
  now = now or workspace:GetServerTimeNow()
  if egg:GetAttribute("FlatGrow") == true then return now - pt end
  return DayNight.GrowthElapsed(pt, now)
end

local function eggReady(egg)
  if egg:GetAttribute("EggBuildComplete") ~= true then return false end
  if egg:HasTag("Hatching") then return false end
  local pt = eggPlaceTime(egg)
  if not pt or pt <= 0 then return false end
  return growthElapsed(egg) >= growthRequired(egg)
end

-- real seconds until the egg finishes growing (inf when unknowable)
local function growthRealLeft(egg)
  local pt = eggPlaceTime(egg)
  if not pt then return math.huge end
  local req = growthRequired(egg)
  if egg:GetAttribute("FlatGrow") == true then
    return math.max(0, req - (workspace:GetServerTimeNow() - pt))
  end
  return DayNight.GrowthRealRemaining(pt, req)
end

-- rarest ready egg on my plot passing the hatch filter; also soonest real time
local function scanPlot()
  local ef = plotEggFolder()
  if not ef then return nil, math.huge, 0 end
  local ready, soonest, count = nil, math.huge, 0
  for _, e in ipairs(ef:GetChildren()) do
    count = count + 1
    local r = rank[tostring((Eggs[e.Name] or {}).Rarity)] or 0
    if eggReady(e) then
      if r >= cfg.hatchMinRank and (not ready or r > (rank[tostring((Eggs[ready.Name] or {}).Rarity)] or 0)) then
        ready = e
      end
    else
      local left = growthRealLeft(e)
      if left < soonest then soonest = left end
    end
  end
  return ready, soonest, count
end

-- satchel egg tools: Backpack / held Tools tagged "Egg"
local function isEggTool(t)
  return t:IsA("Tool") and (t:HasTag("Egg") or t:GetAttribute("EggInventoryId") ~= nil or Eggs[t.Name] ~= nil)
end

local function satchelEggs()
  local list = {}
  local function scan(container)
    if not container then return end
    for _, t in ipairs(container:GetChildren()) do
      if isEggTool(t) then list[#list + 1] = t end
    end
  end
  scan(LP:FindFirstChild("Backpack"))
  scan(LP.Character)
  return list
end

local function satchelCount()
  return #satchelEggs()
end
S.satchelCount = satchelCount
S.plotEggs = plotEggs

local function pickSatchelEgg()
  local best, bestR
  for _, t in ipairs(satchelEggs()) do
    local r = rank[tostring((Eggs[t.Name] or {}).Rarity)] or 0
    if r >= cfg.plantMinRank and (not bestR or r > bestR) then best, bestR = t, r end
  end
  return best
end

-- claim tracking: each egg name can be claimed once per Cycle; the game
-- records that in CollectedEggCycles (JSON) / CollectedEggs / CollectedAdminEggs
local claimCache = { raw = nil, map = {} }
local function claimedCycles()
  local raw = LP:GetAttribute("CollectedEggCycles")
  if claimCache.raw ~= raw then
    claimCache.raw = raw
    local ok, t = pcall(function() return HttpService:JSONDecode(raw) end)
    claimCache.map = (ok and type(t) == "table") and t or {}
  end
  return claimCache.map
end

local function eggClaimed(c)
  local name = tostring(c:GetAttribute("Egg"))
  if c:GetAttribute("AdminSpawn") == true then
    local id = c:GetAttribute("AdminEggId")
    local list = LP:GetAttribute("CollectedAdminEggs")
    if type(id) == "string" and type(list) == "string" then
      return string.find(list, "," .. id .. ",", 1, true) ~= nil
    end
    return false
  end
  local cycle = tonumber(c:GetAttribute("Cycle"))
  local claimed = tonumber(claimedCycles()[name])
  if cycle and claimed then return cycle <= claimed end
  local list = LP:GetAttribute("CollectedEggs")
  if type(list) == "string" and name ~= "" then
    return string.find(list, name .. ",", 1, true) ~= nil
  end
  return false
end

-- rarest claimable world egg passing the collect filter
local function pickTarget()
  local now = workspace:GetServerTimeNow()
  local best, bestScore = nil, -1
  for _, c in ipairs(ae:GetChildren()) do
    local n = tostring(c:GetAttribute("Egg"))
    local def = Eggs[n]
    local r = rank[tostring(def and def.Rarity)] or 0
    if def and r >= cfg.collectMinRank then
      local pos     = c:GetAttribute("Position")
      local dropEnd = tonumber(c:GetAttribute("DropEndsAt")) or 0
      local priv    = c:GetAttribute("PrivateTo")
      local blocked = S.blocklist[c.Name] and S.blocklist[c.Name] > os.clock()
      local privOk  = (priv == nil) or tonumber(priv) == LP.UserId or tostring(priv) == tostring(LP.UserId)
      if typeof(pos) == "Vector3" and dropEnd <= now and privOk and not blocked
         and c:GetAttribute("AdminSpawn") ~= true and not eggClaimed(c) then
        if r > bestScore then bestScore = r; best = c end
      end
    end
  end
  return best
end

local function cashNow()
  local sd = LP:FindFirstChild("SavedData")
  local c = sd and sd:FindFirstChild("Cash")
  return c and c.Value or 0
end

local function incomeNow()
  local ls = LP:FindFirstChild("leaderstats")
  local v = ls and ls:FindFirstChild("Income/s")
  return v and v.Value or 0
end

-- carried eggs in volcano flight must not be dropped normally
local function basketVolcanoLocked(now)
  for _, c in ipairs(basket:GetChildren()) do
    local v = tonumber(c:GetAttribute("VolcanoUntil"))
    if v and now < v then return true end
  end
  return false
end

-- ------------------------------------------------------------------
-- Server reply listener (pickup outcomes: status, eggName, configName)
-- ------------------------------------------------------------------
if not S.evConn then
  S.evConn = EggPickup.OnClientEvent:Connect(function(status, name, id)
    S.lastStatus = { status = tostring(status), name = tostring(name), id = id and tostring(id) or nil, at = os.clock() }
    if tostring(status) ~= "PickedUp" then log("server:", tostring(status), tostring(name)) end
  end)
end

-- ------------------------------------------------------------------
-- State machine
-- ------------------------------------------------------------------
local state, target, targetPos, tState = "scan", nil, nil, os.clock()
local attempt, dropTries, prevEggs = 0, 0, nil
local hatchList, hatchIdx, hatchTries = {}, 0, 0
local plantTool, plantTries, plantBefore, plantSatchelBefore = nil, 0, nil, nil
local prevSatchel = nil

local function setState(s, ...)
  state, tState = s, os.clock()
  local t = { ... }
  if #t > 0 then log(s, table.unpack(t)) else log(s) end
end

-- decide the next job when idle
local function schedule()
  -- 1. finish any carried egg first
  if #basket:GetChildren() > 0 then
    if basketVolcanoLocked(workspace:GetServerTimeNow()) then setState("idle", "volcano carry"); return end
    setState("return", "carrying"); return
  end

  local freeNest = pickFreeNest()
  local ready = select(1, scanPlot())

  -- 2. hatch grown eggs (frees nest slots)
  if cfg.hatch and ready then
    hatchList, hatchIdx, hatchTries = {}, 0, 0
    local ef = plotEggFolder()
    if ef then
      for _, e in ipairs(ef:GetChildren()) do
        local r = rank[tostring((Eggs[e.Name] or {}).Rarity)] or 0
        if eggReady(e) and r >= cfg.hatchMinRank then hatchList[#hatchList + 1] = e end
      end
    end
    if #hatchList > 0 then setState("hatch"); return end
  end

  -- 3. fill free nest slots: collect from the world, else plant from the satchel
  if freeNest then
    if cfg.collect then
      local b = pickTarget()
      if b then
        target, targetPos, attempt, dropTries = b, b:GetAttribute("Position"), 0, 0
        setState("travel", tostring(b:GetAttribute("Egg"))); return
      end
    end
    if cfg.plant then
      local t = pickSatchelEgg()
      if t then plantTool, plantTries = t, 0; setState("goplant", t.Name); return end
    end
  elseif cfg.collect and cfg.collectWhenFull then
    -- every nest taken but the user wants overflow banked in the satchel
    local b = pickTarget()
    if b then
      target, targetPos, attempt, dropTries = b, b:GetAttribute("Position"), 0, 0
      setState("travel", tostring(b:GetAttribute("Egg"))); return
    end
  end

  setState("idle")
end

local function step()
  if state == "scan" then
    schedule()

  elseif state == "idle" then
    if os.clock() - tState >= 1.0 then setState("scan") end

  -- ---- collect: travel to a world egg ----
  elseif state == "travel" then
    if not root() then return end
    if not target or not target.Parent then setState("scan"); return end
    snap(targetPos + Vector3.new(4, 3, 4))
    if os.clock() - tState >= 1.0 then
      snap(targetPos + Vector3.new(4, 3, 4))
      S.lastStatus = nil
      EggPickup:FireServer(target.Name)
      attempt = attempt + 1
      setState("grab")
    end

  elseif state == "grab" then
    local sres = S.lastStatus
    if sres and (os.clock() - sres.at) < 2.5 and (sres.id == nil or (target and sres.id == target.Name)) then
      if sres.status == "PickedUp" then
        st.collected = st.collected + 1
        setState("return"); return
      end
      if sres.status == "BasketFull" then dropTries = 0; setState("return", "basket full"); return end
      if sres.status == "Refused" then
        if target then S.blocklist[target.Name] = os.clock() + 90 end
        setState("scan", "refused:", sres.name)
        return
      end
      if attempt >= 4 then
        if target then S.blocklist[target.Name] = os.clock() + 45 end
        setState("scan", "gave up:", sres.status)
      else
        setState("travel")
      end
      return
    end
    if os.clock() - tState > 3 then
      if target and target.Parent then
        if attempt >= 4 then
          S.blocklist[target.Name] = os.clock() + 45
          setState("scan", "gave up: no answer")
        else setState("travel") end
      else setState("scan", "egg gone") end
    end

  -- ---- collect: return to plot and drop ----
  elseif state == "return" then
    if #basket:GetChildren() == 0 then setState("scan", "basket empty"); return end
    local base = plotBase()
    if not base then setState("scan"); return end
    local v = base.Position + Vector3.new(0, 6, 0)
    snap(v)
    if os.clock() - tState >= 1.2 then
      snap(v)
      prevEggs = plotEggs()
      prevSatchel = satchelCount()
      BasketDrop:FireServer()
      setState("drop")
    end

  elseif state == "drop" then
    if #basket:GetChildren() == 0 then
      local now = plotEggs()
      if prevEggs and now > prevEggs then
        setState("scan", string.format("banked on plot (%d -> %d)", prevEggs, now))
      elseif prevSatchel and satchelCount() > prevSatchel then
        setState("scan", string.format("banked in satchel (%d -> %d)", prevSatchel, satchelCount()))
      elseif os.clock() - tState > 4 then
        setState("scan", string.format("dropped (%d on plot)", now))
      end
    elseif os.clock() - tState > 5 then
      if dropTries < 3 then dropTries = dropTries + 1; setState("return", "retry drop")
      else setState("scan", "drop stuck") end
    end

  -- ---- hatch grown eggs on the plot ----
  elseif state == "hatch" then
    if not root() then return end
    if hatchIdx >= #hatchList then setState("scan"); return end
    local egg = hatchList[hatchIdx + 1]
    if not egg or not egg.Parent or not eggReady(egg) then
      hatchIdx = hatchIdx + 1; hatchTries = 0; return
    end
    local pos = eggPos(egg)
    if pos then snap(pos + Vector3.new(0, 4, 0)) end
    if os.clock() - tState >= 0.5 then
      local key = egg:GetAttribute("EggKey")
      if key then
        Hatch:FireServer({ EggKey = key })
        st.hatched = st.hatched + 1
        log("hatch", egg.Name)
      end
      hatchTries = hatchTries + 1
      -- give the server a moment; advance when the egg is gone or after retries
      task.delay(1.4, function()
        if (not egg.Parent) or hatchTries >= 3 then hatchIdx = hatchIdx + 1; hatchTries = 0 end
        tState = os.clock()
      end)
      setState("hatchwait")
    end

  elseif state == "hatchwait" then
    if os.clock() - tState > 2.6 then setState("hatch") end

  -- ---- plant a satchel egg into a free nest ----
  elseif state == "goplant" then
    if not root() then return end
    if not plantTool or not plantTool.Parent
       or not (plantTool.Parent == LP.Character or plantTool.Parent == LP:FindFirstChild("Backpack")) then
      setState("scan"); return
    end
    local nest = pickFreeNest()
    if not nest then setState("scan", "no free nest"); return end
    local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    if hum and plantTool.Parent ~= LP.Character then pcall(function() hum:EquipTool(plantTool) end) end
    local m = nest:FindFirstChild("Model") or nest
    local ok, bb = pcall(function() return m:GetBoundingBox() end)
    if ok and bb then snap(bb.Position + Vector3.new(0, 7, 0)) end
    if os.clock() - tState >= 0.7 then
      plantBefore = plotEggs()
      plantSatchelBefore = satchelCount()
      EggPlaced:FireServer({ NestId = nest.Name })
      plantTries = plantTries + 1
      setState("plantwait")
    end

  elseif state == "plantwait" then
    if os.clock() - tState >= 1.3 then
      local consumed = (plantTool and not plantTool.Parent) or satchelCount() < (plantSatchelBefore or 0)
      local grew = plotEggs() > (plantBefore or 0)
      if consumed or grew then
        st.planted = st.planted + 1
        log("planted", plantTool and plantTool.Name or "egg")
        setState("scan")
      elseif plantTries >= 3 then
        setState("scan", "plant failed (nest busy or locked)")
      else
        setState("goplant", "retry")
      end
    end
  end
end

function S.start()
  state, target, targetPos, tState = "scan", nil, nil, os.clock()
  attempt, dropTries, prevEggs = 0, 0, nil
  hatchList, hatchIdx, hatchTries = {}, 0, 0
  plantTool, plantTries = nil, 0
  st.startCash   = cashNow()
  st.startIncome = incomeNow()
  st.startTime   = os.clock()
  S.running = true
  S.lastStep = 0
  if S.conn then pcall(function() S.conn:Disconnect() end) end
  S.conn = RunService.Heartbeat:Connect(function()
    if not S.running then return end
    if os.clock() - (S.lastStep or 0) < 0.1 then return end
    S.lastStep = os.clock()
    local ok, err = pcall(step)
    if not ok then log("ERR " .. tostring(err)) end
  end)
  log("started | collect=" .. tostring(cfg.collect) .. " hatch=" .. tostring(cfg.hatch) .. " plant=" .. tostring(cfg.plant))
end

function S.stop()
  S.running = false
  if S.conn then pcall(function() S.conn:Disconnect() end); S.conn = nil end
  log("stopped")
end

S.state = function() return state end
S.pickFreeNest = pickFreeNest
S.nextLockedNest = nextLockedNest
S.nestCounts = nestCounts

-- ------------------------------------------------------------------
-- Interface (Project UAI UI LIB)
-- ------------------------------------------------------------------
local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai-ui.lua"))()
if S.win then pcall(function() S.win:Destroy() end); S.win = nil end
local window = UI:CreateWindow({
  Id = "rideapet-egg-farm",
  Title = "Egg farm",
  Subtitle = "Collect, hatch and plant nests on autopilot",
  GameName = "Ride A Pet",
})
S.win = window

local filterOptions = {
  { Label = "Everything", Value = "1" },
  { Label = "Rare and up", Value = "2" },
  { Label = "Epic and up", Value = "3" },
  { Label = "Legendary and up", Value = "4" },
  { Label = "Mythic and up", Value = "5" },
  { Label = "Divine and up", Value = "6" },
  { Label = "Ethereal only", Value = "7" },
}

local function humanize(n)
  n = tonumber(n) or 0
  local sign = n < 0 and "-" or ""
  n = math.abs(n)
  local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
  for _, u in ipairs(units) do
    if n >= u[1] then return string.format("%s%.2f%s", sign, n / u[1], u[2]) end
  end
  return sign .. string.format("%.0f", n)
end

local function fmtTime(sec)
  if sec == math.huge then return "-" end
  sec = math.max(0, math.floor(sec))
  local h = math.floor(sec / 3600); local m = math.floor((sec % 3600) / 60); local s = sec % 60
  if h > 0 then return string.format("%dh %02dm", h, m) end
  if m > 0 then return string.format("%dm %02ds", m, s) end
  return string.format("%ds", s)
end

-- ===== Farm tab =====
local farmTab = window:Tab({ Title = "Farm" })
local col = farmTab:Section({ Title = "Collector",
  Description = "Teleports to the best claimable egg in the world (rarest first; skips eggs you have already claimed this cycle), picks it up and banks it at your plot." })

local runCtl = col:Toggle({
  Id = "farm_running", Text = "Run farm", Description = "Master switch for the whole pipeline.",
  Default = S.running,
  Callback = function(on) if on then S.start() else S.stop() end
    window:Notify({ Title = "Egg farm", Content = on and "Farm started." or "Farm stopped.", Kind = on and "Success" or "Warning" }) end,
})
col:Divider({ Text = "Collection" })
local collectCtl = col:Toggle({ Id = "farm_collect", Text = "Collect world eggs",
  Default = cfg.collect, Callback = function(v) cfg.collect = v; log("collect ->", v) end })
local filterCtl = col:Dropdown({ Id = "farm_filter", Text = "Collect rarity",
  Description = "Rarest ready egg is always taken first.", Options = filterOptions,
  Default = tostring(cfg.collectMinRank),
  Callback = function(v) cfg.collectMinRank = tonumber(v) or 6; log("collect filter ->", rankName[cfg.collectMinRank]) end })
local overflowCtl = col:Toggle({ Id = "farm_overflow", Text = "Bank extra eggs in satchel",
  Description = "Keep collecting even when every nest is taken; the drop banks into your satchel.",
  Default = cfg.collectWhenFull, Callback = function(v) cfg.collectWhenFull = v end })

local live = farmTab:Section({ Title = "Live" })
local badge = live:Badge({ Id = "farm_badge", Default = "Idle", Kind = "Secondary" })
local fill  = live:Progress({ Id = "nest_fill", Text = "Nests used", Min = 0, Max = 5, Default = 0 })
local activity = live:Paragraph({ Id = "farm_activity", Text = "Recent activity", Content = "-" })

-- ===== Hatch tab =====
local hatchTab = window:Tab({ Title = "Hatch" })
local hs = hatchTab:Section({ Title = "Auto-hatch",
  Description = "Hatches eggs on your plot the moment they finish growing, freeing nest slots. Growth is weight-aware and night grows 10x faster. Skip Growth is never used (it costs Robux)." })
local hatchCtl = hs:Toggle({ Id = "hatch_on", Text = "Auto-hatch grown eggs",
  Default = cfg.hatch, Callback = function(v) cfg.hatch = v; log("hatch ->", v) end })
local hatchFilterCtl = hs:Dropdown({ Id = "hatch_filter", Text = "Only hatch",
  Options = filterOptions, Default = tostring(cfg.hatchMinRank),
  Callback = function(v) cfg.hatchMinRank = tonumber(v) or 1 end })
local hstat = hatchTab:Section({ Title = "Status" })
local hatchBadge = hstat:Badge({ Id = "hatch_badge", Default = "-", Kind = "Secondary" })
hstat:Button({ Id = "hatch_now", Text = "Hatch ready eggs now", ActionText = "Hatch", Style = "Primary",
  Callback = function()
    local ef = plotEggFolder(); local n = 0
    if ef then for _, e in ipairs(ef:GetChildren()) do
      if eggReady(e) then
        local pos = eggPos(e); if pos then snap(pos + Vector3.new(0, 4, 0)); task.wait(0.15) end
        local key = e:GetAttribute("EggKey")
        if key then Hatch:FireServer({ EggKey = key }); st.hatched = st.hatched + 1; n = n + 1 end
      end
    end end
    window:Notify({ Title = "Hatch", Content = n > 0 and ("Hatched " .. n .. " egg(s).") or "No eggs ready yet.", Kind = n > 0 and "Success" or "Secondary" })
  end })

-- ===== Satchel tab =====
local satTab = window:Tab({ Title = "Satchel" })
local ps = satTab:Section({ Title = "Plant backlog",
  Description = "Equips a satchel egg and plants it into a free nest on your plot so the backlog keeps growing into pets. Off by default." })
local plantCtl = ps:Toggle({ Id = "plant_on", Text = "Auto-plant from satchel",
  Default = cfg.plant, Callback = function(v) cfg.plant = v; log("plant ->", v) end })
local plantFilterCtl = ps:Dropdown({ Id = "plant_filter", Text = "Only plant",
  Options = filterOptions, Default = tostring(cfg.plantMinRank),
  Callback = function(v) cfg.plantMinRank = tonumber(v) or 1 end })
local pstat = satTab:Section({ Title = "Status" })
local satBadge = pstat:Badge({ Id = "satchel_badge", Default = "-", Kind = "Secondary" })
pstat:Button({ Id = "plant_now", Text = "Plant one egg now", ActionText = "Plant",
  Callback = function()
    local t = pickSatchelEgg()
    if not t then window:Notify({ Title = "Plant", Content = "No satchel egg matches the filter.", Kind = "Warning" }); return end
    local nest = pickFreeNest()
    if not nest then window:Notify({ Title = "Plant", Content = "No free nest on your plot.", Kind = "Warning" }); return end
    local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    if hum then pcall(function() hum:EquipTool(t) end) end
    local m = nest:FindFirstChild("Model") or nest
    local ok, bb = pcall(function() return m:GetBoundingBox() end)
    if ok and bb then snap(bb.Position + Vector3.new(0, 7, 0)); task.wait(0.4) end
    local before = plotEggs()
    local satBefore = satchelCount()
    EggPlaced:FireServer({ NestId = nest.Name })
    task.wait(1.2)
    local planted = ((t and not t.Parent) or satchelCount() < satBefore) or plotEggs() > before
    if planted then st.planted = st.planted + 1 end
    window:Notify({ Title = "Plant", Content = planted and ("Planted " .. t.Name .. " in nest " .. nest.Name .. ".") or "Plant did not take (nest busy or locked).", Kind = planted and "Success" or "Warning" })
  end })

local ns = satTab:Section({ Title = "Nests",
  Description = "Your plot holds up to 5 nests. Each unlock costs cash (prices rise steeply); the first nest is free." })
local nestBadge = ns:Badge({ Id = "nest_badge", Default = "-", Kind = "Secondary" })
local unlockCtl = ns:Button({ Id = "unlock_nest", Text = "Unlock next locked nest", ActionText = "Unlock",
  Callback = function()
    local nest = nextLockedNest()
    if not nest then window:Notify({ Title = "Nests", Content = "No locked nest left to unlock.", Kind = "Secondary" }); return end
    local num = tonumber(nest.Name) or 0
    local price = (NestsData.Prices or {})[num] or 0
    NestUnlock:FireServer(num)
    st.unlocks = (st.unlocks or 0) + 1
    log("unlock nest", nest.Name, "cost", price)
    window:Notify({ Title = "Nests", Content = string.format("Unlocking nest %d for %s cash.", num, humanize(price)), Kind = "Warning" })
  end })
local autoUnlockCtl = ns:Toggle({ Id = "auto_unlock", Text = "Auto-unlock when affordable",
  Description = "Buys the next locked nest whenever your cash covers its price (checked every ~10s).",
  Default = cfg.autoUnlock, Callback = function(v) cfg.autoUnlock = v; log("auto-unlock ->", v) end })

-- ===== Stats tab =====
local statsTab = window:Tab({ Title = "Stats" })
local sess = statsTab:Section({ Title = "This session" })
local sessPara = sess:Paragraph({ Id = "stats_session", Text = "Session", Content = "-" })
local nowSec = statsTab:Section({ Title = "Right now" })
local nowPara = nowSec:Paragraph({ Id = "stats_now", Text = "Live", Content = "-" })

-- ------------------------------------------------------------------
-- Live updater
-- ------------------------------------------------------------------
local uiTick = 0
window:Give(RunService.Heartbeat:Connect(function()
  if not window.Alive then return end
  local now = os.clock()
  if now - uiTick < 0.5 then return end
  uiTick = now

  local eggs = math.max(plotEggs(), 0)
  local inBasket = #basket:GetChildren()
  local sat = satchelCount()
  local pl = myPlot()
  local pets = pl and pl:FindFirstChild("Pets"); pets = pets and #pets:GetChildren() or 0
  local ready, soonest = scanPlot()
  local freeNests, totalNests = nestCounts()
  local running = S.running == true

  -- Farm badge
  local text, kind
  if not running then text, kind = "Stopped", "Secondary"
  elseif inBasket > 0 then text, kind = "Carrying an egg -> plot", "Warning"
  elseif ready then text, kind = "Hatching ready eggs", "Success"
  elseif freeNests == 0 and not cfg.collectWhenFull then text, kind = "All nests busy - waiting to hatch", "Warning"
  else text, kind = "Running (" .. (S.state and S.state() or "?") .. ")", "Success" end
  badge:Set(text)
  fill:Set(math.max(totalNests - freeNests, 0))

  -- keep toggles/dropdowns in sync (silent)
  if runCtl:Get() ~= running then runCtl:Set(running, true) end
  if collectCtl:Get() ~= cfg.collect then collectCtl:Set(cfg.collect, true) end
  if overflowCtl:Get() ~= cfg.collectWhenFull then overflowCtl:Set(cfg.collectWhenFull, true) end
  if hatchCtl:Get() ~= cfg.hatch then hatchCtl:Set(cfg.hatch, true) end
  if plantCtl:Get() ~= cfg.plant then plantCtl:Set(cfg.plant, true) end
  if autoUnlockCtl:Get() ~= cfg.autoUnlock then autoUnlockCtl:Set(cfg.autoUnlock, true) end
  if filterCtl:Get() ~= tostring(cfg.collectMinRank) then filterCtl:Set(tostring(cfg.collectMinRank), true) end
  if hatchFilterCtl:Get() ~= tostring(cfg.hatchMinRank) then hatchFilterCtl:Set(tostring(cfg.hatchMinRank), true) end
  if plantFilterCtl:Get() ~= tostring(cfg.plantMinRank) then plantFilterCtl:Set(tostring(cfg.plantMinRank), true) end

  -- activity log
  local lines = {}
  for i = 1, math.min(#S.log, 6) do lines[i] = S.log[i] end
  activity:SetDescription(table.concat(lines, "\n"))

  -- hatch status
  local readyCount = 0
  local ef = plotEggFolder()
  if ef then for _, e in ipairs(ef:GetChildren()) do if eggReady(e) then readyCount = readyCount + 1 end end end
  if readyCount > 0 then hatchBadge:Set(readyCount .. " ready to hatch")
  elseif soonest < math.huge then hatchBadge:Set("Next ready in " .. fmtTime(soonest))
  else hatchBadge:Set("No eggs growing on plot") end

  -- satchel / nest status
  satBadge:Set(sat .. " egg(s) in satchel")
  local lockedNest = nextLockedNest()
  nestBadge:Set(string.format("%d free / %d nests", freeNests, totalNests))
  unlockCtl:SetDisabled(lockedNest == nil)

  -- opt-in auto-unlock: buy the next locked nest when cash covers it
  if cfg.autoUnlock and lockedNest and (not S.unlockAt or now - S.unlockAt > 10) then
    local num = tonumber(lockedNest.Name) or 0
    local price = (NestsData.Prices or {})[num] or math.huge
    if cashNow() >= price then
      S.unlockAt = now
      NestUnlock:FireServer(num)
      log("auto-unlock nest", lockedNest.Name, "cost", price)
      window:Notify({ Title = "Nests", Content = string.format("Unlocking nest %d for %s cash.", num, humanize(price)), Kind = "Warning" })
    end
  end

  -- stats
  local runtime = running and (now - (st.startTime or now)) or 0
  local earned = cashNow() - (st.startCash or cashNow())
  sessPara:SetDescription(string.format(
    "Runtime: %s\nCollected: %d    Hatched: %d    Planted: %d\nCash earned: %s",
    fmtTime(runtime), st.collected, st.hatched, st.planted, humanize(earned)))
  nowPara:SetDescription(string.format(
    "Cash: %s\nIncome: %s / s\nPlot eggs: %d    Nests: %d/%d    Pets: %d / %s\nSatchel eggs: %d",
    humanize(cashNow()), humanize(incomeNow()), eggs, totalNests - freeNests, totalNests, pets,
    tostring(LP:GetAttribute("MaxPets") or "?"), sat))
end))

window:OnDestroy(function() S.uiOpen = false end)
S.uiOpen = true

S.start()
return {
  running = S.running, collect = cfg.collect, hatch = cfg.hatch, plant = cfg.plant,
  plotEggs = plotEggs(), satchel = satchelCount(), freeNests = select(1, nestCounts()),
}
