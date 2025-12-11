local Version = "1.6.53"
local UIsuccess, WindUI = pcall(function()
    -- Try loading specific version first (more stable)
    local success, result = pcall(function()
        return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/download/" .. Version .. "/main.lua"))()
    end)
    
    if success and result then return result end
end)

if not UIsuccess or not WindUI then
    warn("Failed to load WindUI...")
    return
end

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")

local player = Players.LocalPlayer
local MainTrove = {} 
local Modules = {}

local globalState = {
    isTeleporting = false
}

-- Helper Function for Modules
local function customRequire(module)
    if not module then return nil end
    if not module:IsA("ModuleScript") then return nil end

    local success, result = pcall(require, module)
    if success then return result end

    -- Fallback: Clone
    local cloneSuccess, clone = pcall(function() return module:Clone() end)
    if not cloneSuccess then return nil end
    clone.Parent = nil
    local cloneRequireSuccess, cloneResult = pcall(require, clone)
    return cloneRequireSuccess and cloneResult or nil
end

-- Load Game Modules
local success, errorMessage = pcall(function()
    local Controllers = ReplicatedStorage:WaitForChild("Controllers", 20)
    local NetFolder = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("_Index"):WaitForChild(
        "sleitnick_net@0.2.0"):WaitForChild("net", 20)
    local Shared = ReplicatedStorage:WaitForChild("Shared", 20)
    
    if not (Controllers and NetFolder and Shared) then error("Core game folders not found.") end

    Modules.Replion = customRequire(ReplicatedStorage.Packages.Replion)
    Modules.ItemUtility = customRequire(Shared.ItemUtility)
    Modules.FishingController = customRequire(Controllers.FishingController)
    
    -- Remote Events/Functions
    Modules.NetFolder = NetFolder
    Modules.SellAllItemsFunc = NetFolder["RF/SellAllItems"]
    Modules.EquipToolEvent = NetFolder["RE/EquipToolFromHotbar"]
    Modules.ChargeRodFunc = NetFolder["RF/ChargeFishingRod"]
    Modules.StartMinigameFunc = NetFolder["RF/RequestFishingMinigameStarted"]
    Modules.CompleteFishingEvent = NetFolder["RE/FishingCompleted"]
    Modules.CancelFishing = NetFolder["RF/CancelFishingInputs"]
    Modules.ReplicateTextEffect = NetFolder["RE/ReplicateTextEffect"]
end)

if not success then
    warn("FATAL ERROR LOADING MODULES: " .. tostring(errorMessage))
    return
end

task.wait(1)

-- UI Initialization
local Window = WindUI:CreateWindow({
    Title = "Quix",
    Icon = "rbxassetid://136907178324713",
    Author = "Civas",
    Size = UDim2.fromOffset(450, 280),
    Folder = "Civas",
    Transparent = true,
    Theme = "Dark", -- ganti Dark ke Neon
    ToggleKey = Enum.KeyCode.G,
    SideBarWidth = 140
})

if not Window then warn("Failed to create Window") return end

-- UI Sections
local FishingSection = Window:Section({ Title = "Main Course", Opened = true })
local FishingTab = FishingSection:Tab({ Title = "X8 Speed", Icon = "fish", ShowTabTitle = true })
local Config = Window.ConfigManager:CreateConfig("InstantSettings")

-- Variables
local featureState = {
    AutoFish = false,
    AutoFishHighQuality = false,
    AutoSellMode = "Disabled",
    AutoSellDelay = 1800,
    
    -- Instant Settings
    Instant_ChargeDelay = 0.07,
    Instant_SpamCount = 5,
    Instant_WorkerCount = 3,
    Instant_StartDelay = 1.20,
    Instant_CatchTimeout = 0.25,
    Instant_CycleDelay = 0.10,
    Instant_ResetCount = 15,
    Instant_ResetPause = 0.1
}

local fishingTrove = {}
local autoFishThread = nil
local lastSellTime = 0
local lastEventTime = tick()
local fishCaughtBindable = Instance.new("BindableEvent")
local isWaitingForCorrectTier = false

-- Helper: Safe Connect
local function safeConnect(signal, callback)
    local conn = signal:Connect(function(...)
        pcall(callback, ...)
    end)
    table.insert(MainTrove, conn)
    return conn
end

-- Helper: High Quality Filter
local function isLowQualityFish(colorValue)
    if not colorValue then return false end
    local r, g, b
    
    if typeof(colorValue) == "Color3" then
        r, g, b = colorValue.R, colorValue.G, colorValue.B
    elseif typeof(colorValue) == "ColorSequence" and #colorValue.Keypoints > 0 then
        local c = colorValue.Keypoints[1].Value
        r, g, b = c.R, c.G, c.B
    else
        return false
    end
    
    -- Check Common (White/Gray), Rare (Blue), Uncommon (Green)
    if (r > 0.9 and g > 0.9 and b > 0.9) or (b > 0.9 and r < 0.4) or (g > 0.9 and b < 0.4) then
        return true 
    end
    return false
end

-- Helper: Actions
local function sellAllItems()
    if Modules.SellAllItemsFunc then
        pcall(Modules.SellAllItemsFunc.InvokeServer, Modules.SellAllItemsFunc)
    end
end

local function equipFishingRod()
    if Modules.EquipToolEvent then
        pcall(Modules.EquipToolEvent.FireServer, Modules.EquipToolEvent, 1)
    end
end

local function stopAutoFishProcesses()
    featureState.AutoFish = false
    for i, item in ipairs(fishingTrove) do
        if typeof(item) == "RBXScriptConnection" then item:Disconnect()
        elseif typeof(item) == "thread" then task.cancel(item) end
    end
    fishingTrove = {}
    
    pcall(function()
        if Modules.FishingController and Modules.FishingController.RequestClientStopFishing then
            Modules.FishingController:RequestClientStopFishing(true)
        end
    end)
end

-- CORE: Instant Fishing Logic
local function startAutoFishMethod_Instant()
    if not (Modules.ChargeRodFunc and Modules.StartMinigameFunc and Modules.CompleteFishingEvent) then
        warn("Modules missing for Instant Fish.")
        return
    end

    featureState.AutoFish = true
    local chargeCount = 0
    local isCurrentlyResetting = false
    local counterLock = false

    local function worker()
        while featureState.AutoFish and player do
            local currentResetTarget_Worker = featureState.Instant_ResetCount or 15

            if isCurrentlyResetting or chargeCount >= currentResetTarget_Worker then break end

            local success, err = pcall(function()
                -- Auto Sell Check
                if featureState.AutoSellMode ~= "Disabled" and (tick() - lastSellTime > featureState.AutoSellDelay) then
                    sellAllItems(); lastSellTime = tick()
                end

                if not featureState.AutoFish or isCurrentlyResetting or chargeCount >= currentResetTarget_Worker then return end

                -- Counter Logic
                local currentCount = 0
                local lockTimeout = 0
                while counterLock do 
                    task.wait(0.01); lockTimeout = lockTimeout + 0.01
                    if lockTimeout > 5 then counterLock = false; break end
                end
            
                counterLock = true
                if chargeCount < currentResetTarget_Worker then
                    chargeCount = chargeCount + 1
                    currentCount = chargeCount
                else
                    currentCount = chargeCount
                end
                counterLock = false

                if currentCount > currentResetTarget_Worker then return end
                
                -- 1. Charge
                local chargeStartTime = workspace:GetServerTimeNow()
                Modules.ChargeRodFunc:InvokeServer(chargeStartTime)
                task.wait(featureState.Instant_ChargeDelay)

                if not featureState.AutoFish or isCurrentlyResetting then return end
                
                -- 2. Start Minigame (Center Cast)
                Modules.StartMinigameFunc:InvokeServer(-1.25, 1, workspace:GetServerTimeNow())
                task.wait(featureState.Instant_StartDelay)

                if not featureState.AutoFish or isCurrentlyResetting then return end
                
                -- 3. Spam Complete
                for _ = 1, featureState.Instant_SpamCount do
                    if not featureState.AutoFish or isCurrentlyResetting then break end
                    Modules.CompleteFishingEvent:FireServer()
                    task.wait(0.01)
                end

                if not featureState.AutoFish or isCurrentlyResetting then return end

                -- 4. Wait for Signal (Caught or Filtered)
                local signalReceived = false
                local connection
                
                local timeoutThread = task.delay(featureState.Instant_CatchTimeout, function()
                    if not signalReceived and connection and connection.Connected then connection:Disconnect() end
                end)

                Modules.CancelFishing:InvokeServer()

                connection = fishCaughtBindable.Event:Connect(function(status)
                    signalReceived = true
                    if timeoutThread then task.cancel(timeoutThread) end
                    if connection and connection.Connected then connection:Disconnect() end
                    
                    if status == "skipped" then
                        pcall(function()
                            Modules.FishingController:RequestClientStopFishing(true)
                        end)
                    end
                end)

                while not signalReceived and task.wait() do
                    if not featureState.AutoFish or isCurrentlyResetting then break end
                    if timeoutThread and coroutine.status(timeoutThread) == "dead" then break end
                end
                
                if connection and connection.Connected then connection:Disconnect() end
                Modules.CancelFishing:InvokeServer()

                -- Cleanup Client
                pcall(Modules.FishingController.RequestClientStopFishing, Modules.FishingController, true)

                if not isWaitingForCorrectTier then task.wait() else isWaitingForCorrectTier = false end
            end)

            if not success and not tostring(err):find("busy") then warn("Worker Error:", err) end
            if not featureState.AutoFish then break end
            task.wait(featureState.Instant_CycleDelay)
        end
    end

    -- Worker Manager
    autoFishThread = task.spawn(function()
        while featureState.AutoFish do
            local currentResetTarget = featureState.Instant_ResetCount or 15
            local currentPauseTime = featureState.Instant_ResetPause or 0.1

            chargeCount = 0
            isCurrentlyResetting = false
            local batchTrove = {} 

            for i = 1, featureState.Instant_WorkerCount do
                if not featureState.AutoFish then break end
                local workerThread = task.spawn(worker)
                table.insert(batchTrove, workerThread)
                table.insert(fishingTrove, workerThread) 
            end

            while featureState.AutoFish and chargeCount < currentResetTarget do task.wait() end

            isCurrentlyResetting = true 
            if featureState.AutoFish then
                for _, thread in ipairs(batchTrove) do task.cancel(thread) end
                batchTrove = {}
                task.wait(currentPauseTime) 
            end
        end
        stopAutoFishProcesses()
    end)
    table.insert(fishingTrove, autoFishThread)
end

-- Toggle Function
local function startOrStopAutoFish(shouldStart)
    if shouldStart then
        stopAutoFishProcesses()
        featureState.AutoFish = true
        equipFishingRod()
        task.wait(0.2)
        startAutoFishMethod_Instant()
    else
        stopAutoFishProcesses()
    end
end

-- Detect Fish Catch (High Quality Filter)
if Modules.ReplicateTextEffect then
    local replicateTextConn = safeConnect(Modules.ReplicateTextEffect.OnClientEvent, function(data)
        if not featureState.AutoFish then return end
        
        local myHead = player.Character and player.Character:FindFirstChild("Head")
        if not (data and data.TextData and data.TextData.EffectType == "Exclaim" and myHead and data.Container == myHead) then
            return
        end
        
        lastEventTime = tick()
        
        -- Filter Logic
        if featureState.AutoFishHighQuality then
            local colorValue = data.TextData.TextColor
            if colorValue and isLowQualityFish(colorValue) then
                pcall(function()
                    Modules.FishingController:RequestClientStopFishing(true)
                end)
                fishCaughtBindable:Fire("skipped") 
                return 
            end
        end
        
        fishCaughtBindable:Fire("caught")
    end)
    table.insert(MainTrove, replicateTextConn)
end

-- Anti-Stuck Monitor
task.spawn(function()
    while task.wait(1) do
        if featureState.AutoFish and featureState.AutoFishHighQuality then
            if tick() - lastEventTime > 10 then
                pcall(Modules.FishingController.RequestClientStopFishing, Modules.FishingController, true)
                lastEventTime = tick()
            end
        end
    end
end)

-- UI Elements
FishingTab:Section({ Title = "Main Toggle", Opened = true })

local autoFishToggle = FishingTab:Toggle({
    Title = "Enable X8 Speed",
    Desc = "Still in Beta and Under Development",
    Value = false,
    Callback = startOrStopAutoFish
})
Config:Register("AutoFish", autoFishToggle)

local SellingSection = FishingTab:Section({ Title = "Selling", Opened = true })

local autoSellDropdown = SellingSection:Dropdown({
    Title = "Auto Sell",
    Values = { "Disabled", "Auto Sell All" },
    Value = "Disabled",
    Callback = function(v) 
        featureState.AutoSellMode = v
        if v ~= "Disabled" then lastSellTime = tick() end
    end
})
Config:Register("AutoSellMode", autoSellDropdown)

local sellDelayInput = SellingSection:Input({
    Title = "Auto Sell (Minutes)",
    Placeholder = "30",
    Callback = function(v) featureState.AutoSellDelay = (tonumber(v) or 30) * 60 end
})
Config:Register("SellDelay", sellDelayInput)

SellingSection:Button({
    Title = "Sell All",
    Icon = "dollar-sign",
    Callback = function()
        sellAllItems()
        WindUI:Notify({ Title = "Sold", Content = "Items sold successfully.", Duration = 2 })
    end
})

local TuningSection = FishingTab:Section({ Title = "X8 Speed Settings", Opened = true })

TuningSection:Slider({
    Title = "Delay Pantat",
    Value = { Min = 0.01, Max = 5.0, Default = featureState.Instant_StartDelay },
    Precise = 2,
    Step = 0.01,
    Callback = function(v) featureState.Instant_StartDelay = tonumber(v) end
})

TuningSection:Slider({
    Title = "Spam Pantat",
    Value = { Min = 0.01, Max = 5.0, Default = featureState.Instant_CatchTimeout },
    Precise = 2,
    Step = 0.01,
    Callback = function(v) featureState.Instant_CatchTimeout = tonumber(v) end
})

TuningSection:Slider({
    Title = "Cooldown Pantat",
    Value = { Min = 0.01, Max = 5.0, Default = featureState.Instant_CycleDelay },
    Precise = 2,
    Step = 0.01,
    Callback = function(v) featureState.Instant_CycleDelay = tonumber(v) end
})

-- Config Tab
local ConfigTab = Window:Section({ Title = "Settings Menu" }):Tab({ Title = "Config", Icon = "settings" })

ConfigTab:Button({
    Title = "Save Configuration",
    Icon = "save",
    Callback = function()
        Config:Save()
        WindUI:Notify({ Title = "Saved", Content = "Configuration saved.", Duration = 2 })
    end
})

ConfigTab:Button({
    Title = "Load Configuration",
    Icon = "upload",
    Callback = function()
        Config:Load()
        WindUI:Notify({ Title = "Loaded", Content = "Configuration loaded.", Duration = 2 })
    end
})

-- Anti-AFK
if VirtualUser then
    player.Idled:Connect(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end

-- Cleanup on Destroy
Window:OnDestroy(function()
    stopAutoFishProcesses()
    for _, conn in ipairs(MainTrove) do conn:Disconnect() end
end)

WindUI:Notify({
    Title = "X8 Speed Loaded",
    Content = "X8 Speed Ready!",
    Duration = 5,
    Icon = "check"
})