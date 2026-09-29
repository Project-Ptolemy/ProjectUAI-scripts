-- Ride A Pet: egg collector that keeps farming on a full plot (eggs go to the satchel)
local RS = game:GetService("ReplicatedStorage")
local LP = game:GetService("Players").LocalPlayer
local RunService = game:GetService("RunService")

local rank = { Common = 1, Uncommon = 2, Rare = 2, Epic = 3, Legendary = 4, Mythic = 5, Divine = 6, Ethereal = 7, Secret = 8 }
local rankName = { [1] = "all", [2] = "Rare+", [3] = "Epic+", [4] = "Legendary+", [5] = "Mythic+", [6] = "Divine+", [7] = "Ethereal" }
local Eggs = require(RS.GameData.Eggs)
local EggPickup = RS.Remotes.Game.EggPickup
local BasketDrop = RS.Remotes.Game.BasketDrop
local ae = RS.ServerData.ActiveEggs
local basket = LP.Basket

local S = rawget(_G, "RideAPetEggFarm")
if type(S) ~= "table" then S = {}; _G.RideAPetEggFarm = S end
S.minRank = S.minRank or 6
S.blocklist = S.blocklist or {}
S.log = S.log or {}
S.collected = S.collected or 0

local function log(...)
  local t = {}
  for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
  table.insert(S.log, 1, string.format("[%.0f] %s", workspace:GetServerTimeNow() % 100000, table.concat(t, " ")))
  while #S.log > 40 do table.remove(S.log) end
end

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
  r.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
  return true
end

local function myPlot()
  for _, pl in ipairs(workspace.Plots:GetChildren()) do
    local d = pl:FindFirstChild("Data")
    local o = d and d:FindFirstChild("Owner")
    if o and o.Value == LP then return pl end
  end
end

local function plotEggs()
  local pl = myPlot()
  local ef = pl and pl:FindFirstChild("Eggs")
  return ef and #ef:GetChildren() or -1
end

if not S.evConn then
  S.evConn = EggPickup.OnClientEvent:Connect(function(status, name)
    S.lastStatus = { status = tostring(status), name = tostring(name), at = os.clock() }
    if tostring(status) ~= "Deposited" then log("server:", tostring(status), tostring(name)) end
  end)
end

local state, target, targetPos, tState = "scan", nil, nil, os.clock()
local attempt, dropTries, prevEggs = 0, 0, nil

local function setState(s, ...)
  state = s
  tState = os.clock()
  local t = { ... }
  if #t > 0 then log(s, table.unpack(t)) else log(s) end
end

local function pickTarget()
  local now = workspace:GetServerTimeNow()
  local onPlot = {}
  local pl = myPlot()
  local ef = pl and pl:FindFirstChild("Eggs")
  if ef then for _, e in ipairs(ef:GetChildren()) do onPlot[e.Name] = true end end
  local best, bestScore = nil, -1
  for _, c in ipairs(ae:GetChildren()) do
    local n = tostring(c:GetAttribute("Egg"))
    local d = Eggs[n] or {}
    local r = rank[tostring(d.Rarity)] or 0
    if r >= S.minRank then
      local dropEnd = tonumber(c:GetAttribute("DropEndsAt")) or 0
      local priv = c:GetAttribute("PrivateTo")
      local blocked = S.blocklist[c.Name] and S.blocklist[c.Name] > os.clock()
      local privOk = (priv == nil) or tostring(priv) == tostring(LP.UserId)
      if dropEnd <= now and privOk and not blocked and c:GetAttribute("AdminSpawn") ~= true then
        local score = r + (onPlot[n] and 0 or 0.5)
        if score > bestScore then bestScore = score; best = c end
      end
    end
  end
  return best
end

local function step()
  if state == "scan" then
    if #basket:GetChildren() > 0 then setState("return", "carrying") return end
    local b = pickTarget()
    if b then
      target = b
      targetPos = b:GetAttribute("Position")
      attempt, dropTries = 0, 0
      setState("travel", tostring(b:GetAttribute("Egg")))
    end
  elseif state == "travel" then
    if not root() then return end
    if not target or not target.Parent then setState("scan") return end
    snap(targetPos + Vector3.new(4, 3, 4))
    if os.clock() - tState >= 1.0 then
      snap(targetPos + Vector3.new(4, 3, 4))
      S.lastStatus = nil
      EggPickup:FireServer(target.Name)
      attempt = attempt + 1
      setState("grab")
    end
  elseif state == "grab" then
    local st = S.lastStatus
    if st and (os.clock() - st.at) < 2.5 then
      if st.status == "PickedUp" then
        S.collected = S.collected + 1
        setState("return")
        return
      end
      if st.status == "BasketFull" then
        dropTries = 0
        setState("return", "basket full")
        return
      end
      if attempt >= 4 then
        if target then S.blocklist[target.Name] = os.clock() + 45 end
        setState("scan", "gave up:", st.status)
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
        else
          setState("travel")
        end
      else
        setState("scan", "egg gone")
      end
    end
  elseif state == "return" then
    local pl = myPlot()
    if not pl then setState("scan") return end
    local base = pl:FindFirstChild("Baseplate")
    if not base then setState("scan") return end
    local v = base.Position + Vector3.new(0, 6, 0)
    snap(v)
    if os.clock() - tState >= 1.2 then
      snap(v)
      prevEggs = plotEggs()
      BasketDrop:FireServer()
      setState("drop")
    end
  elseif state == "drop" then
    if #basket:GetChildren() == 0 then
      local now = plotEggs()
      if prevEggs and now <= prevEggs then
        setState("scan", string.format("plot full - egg stored in satchel (%d on plot)", now))
      else
        setState("scan", string.format("planted (plot eggs %s -> %s)", tostring(prevEggs), tostring(now)))
      end
    elseif os.clock() - tState > 5 then
      if dropTries < 3 then
        dropTries = dropTries + 1
        setState("return", "retry drop")
      else
        setState("scan", "drop stuck")
      end
    end
  end
end

function S.start()
  if S.conn then pcall(function() S.conn:Disconnect() end); S.conn = nil end
  state, target, targetPos, tState = "scan", nil, nil, os.clock()
  attempt, dropTries, prevEggs = 0, 0, nil
  S.running = true
  S.lastStep = 0
  S.conn = RunService.Heartbeat:Connect(function()
    if not S.running then S.stop() return end
    if os.clock() - (S.lastStep or 0) < 0.1 then return end
    S.lastStep = os.clock()
    local ok, err = pcall(step)
    if not ok then log("ERR " .. tostring(err)) end
  end)
  log("started | filter=" .. (rankName[S.minRank] or tostring(S.minRank)))
end

function S.stop()
  S.running = false
  if S.conn then pcall(function() S.conn:Disconnect() end); S.conn = nil end
  log("stopped")
end

-- ------------------------------------------------------------------
-- Window (same Id, same controls)
-- ------------------------------------------------------------------
local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai-ui.lua"))()
local window = UI:CreateWindow({
  Id = "rideapet-egg-farm",
  Title = "Egg farm",
  Subtitle = "Auto-collect rare eggs, plant them at your plot",
  GameName = "Ride A Pet",
})
S.win = window

local main = window:Tab({ Title = "Farm" })
local collector = main:Section({
  Title = "Collector",
  Description = "Teleports to the rarest ready egg, picks it up, and plants it at your plot. A full plot stores eggs in your satchel instead.",
})

local syncing = false

local runningCtl = collector:Toggle({
  Id = "farm_running",
  Text = "Auto-collect eggs",
  Description = "One egg per trip (basket is small).",
  Default = S.running,
  Callback = function(on)
    if syncing then return end
    if on then S.start() else S.stop() end
    window:Notify({ Title = "Egg farm", Content = on and "Collector started." or "Collector stopped.", Kind = on and "Success" or "Warning" })
  end,
})

local filterCtl = collector:Dropdown({
  Id = "farm_filter",
  Text = "Rarity filter",
  Description = "Rarest ready egg is always taken first.",
  Options = {
    { Label = "Ethereal only", Value = "7" },
    { Label = "Divine and up", Value = "6" },
    { Label = "Mythic and up", Value = "5" },
    { Label = "Legendary and up", Value = "4" },
    { Label = "Epic and up", Value = "3" },
    { Label = "Rare and up", Value = "2" },
    { Label = "Everything", Value = "1" },
  },
  Default = tostring(S.minRank),
  Callback = function(v)
    if syncing then return end
    S.minRank = tonumber(v) or 6
    log("filter -> " .. (rankName[S.minRank] or tostring(S.minRank)))
  end,
})

local status = main:Section({ Title = "Status" })
local badge = status:Badge({ Id = "farm_badge", Default = "Starting...", Kind = "Secondary" })
local fill = status:Progress({ Id = "plot_fill", Text = "Plot eggs", Min = 0, Max = 10, Default = math.max(plotEggs(), 0) })
local activity = status:Paragraph({ Id = "farm_activity", Text = "Recent activity", Description = "-" })

local uiTick = 0
window:Give(RunService.Heartbeat:Connect(function()
  if not window.Alive then return end
  local now = os.clock()
  if now - uiTick < 0.5 then return end
  uiTick = now
  local n = plotEggs()
  local inBasket = #basket:GetChildren()
  local stored = 0
  for _, t in ipairs(LP.Backpack:GetChildren()) do
    if t:IsA("Tool") and t.Name:match("Egg") then stored = stored + 1 end
  end
  local alive = S.running and S.conn ~= nil
  local text, kind
  if not alive then
    text, kind = "Stopped", "Secondary"
  elseif inBasket > 0 then
    text, kind = "Carrying an egg - heading to the plot", "Warning"
  elseif n >= 10 then
    text, kind = string.format("Plot full - storing eggs in satchel (%d stored)", stored), "Warning"
  else
    text, kind = "Running - watching for " .. (rankName[S.minRank] or "?") .. " eggs", "Success"
  end
  badge:Set(text)
  fill:Set(math.max(n, 0))
  if runningCtl:Get() ~= alive then
    syncing = true
    runningCtl:Set(alive, true)
    syncing = false
  end
  if filterCtl:Get() ~= tostring(S.minRank) then
    syncing = true
    filterCtl:Set(tostring(S.minRank), true)
    syncing = false
  end
  local lines = {}
  for i = 1, math.min(#S.log, 5) do lines[i] = S.log[i] end
  activity:SetDescription(table.concat(lines, "\n"))
end))

window:OnDestroy(function()
  S.uiOpen = false
end)
S.uiOpen = true

S.start()
return { running = S.running, minRank = S.minRank, plotEggs = plotEggs(), satchelEggs = (function() local n = 0 for _, t in ipairs(LP.Backpack:GetChildren()) do if t:IsA("Tool") and t.Name:match("Egg") then n = n + 1 end end return n end)() }
