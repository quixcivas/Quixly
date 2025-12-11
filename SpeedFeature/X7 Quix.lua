local UIsuccess, WindUI = pcall(function()
    return loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()
end)

if not UIsuccess or not WindUI then
    warn("Failed to load WindUI...")
    return
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local Modules = {}
local function customRequire(module)
    if not module then return nil end
    local success, result = pcall(require, module)
    if success then
        return result
    else
        local clone = module:Clone()
        clone.Parent = nil
        local cloneSuccess, cloneResult = pcall(require, clone)
        if cloneSuccess then
            return cloneResult
        else
            warn("Failed to load module: " .. module:GetFullName())
            return nil
        end
    end
end

local success, errorMessage = pcall(function()
    local Controllers = ReplicatedStorage:WaitForChild("Controllers", 20)
    local NetFolder = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("_Index"):WaitForChild(
        "sleitnick_net@0.2.0"):WaitForChild("net", 20)
    local Shared = ReplicatedStorage:WaitForChild("Shared", 20)
    
    if not (Controllers and NetFolder and Shared) then error("Core game folders not found.") end

    Modules.Replion = customRequire(ReplicatedStorage.Packages.Replion)
    Modules.ItemUtility = customRequire(Shared.ItemUtility)
    Modules.FishingController = customRequire(Controllers.FishingController)
    
    Modules.EquipToolEvent = NetFolder["RE/EquipToolFromHotbar"]
    Modules.ChargeRodFunc = NetFolder["RF/ChargeFishingRod"]
    Modules.StartMinigameFunc = NetFolder["RF/RequestFishingMinigameStarted"]
    Modules.CompleteFishingEvent = NetFolder["RE/FishingCompleted"]
end)

if not success then
    warn("FATAL ERROR DURING MODULE LOADING: " .. tostring(errorMessage))
    return
end

task.wait(1)

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

if not Window then
    warn("Failed to create UI Window.")
    return
end

local FishingSection = Window:Section({ Title = "X7 Speed Auto Fishing", Opened = true })
local FishingTab = FishingSection:Tab({ Title = "Fish Menu", Icon = "fish", ShowTabTitle = true })

local Config = Window.ConfigManager:CreateConfig("InstantFishingSettings")

local featureState = {
    AutoFish = false,
    Instant_ChargeDelay = 0.07,
    Instant_SpamCount = 5,
    Instant_WorkerCount = 2,
    Instant_StartDelay = 1.20,
    Instant_CatchTimeout = 0.01,
    Instant_CycleDelay = 0.01,
    Instant_ResetCount = Config:Get("Instant_ResetCount") or 10,
    Instant_ResetPause = Config:Get("Instant_ResetPause") or 0.01
}

local fishingTrove = {}
local autoFishThread = nil
local isWaitingForCorrectTier = false
local fishCaughtBindable = Instance.new("BindableEvent")


local function equipFishingRod()
    if Modules.EquipToolEvent then
        pcall(Modules.EquipToolEvent.FireServer, Modules.EquipToolEvent, 1)
    end
end

task.spawn(function()
    local lastFishName = ""
    while task.wait(0.25) do
        local playerGui = player:findFirstChild("PlayerGui")
        if playerGui then
            local notificationGui = playerGui:FindFirstChild("Small Notification")
            if notificationGui and notificationGui.Enabled then
                local container = notificationGui:FindFirstChild("Display", true) and
                    notificationGui.Display:FindFirstChild("Container", true)
                if container then
                    local itemNameLabel = container:FindFirstChild("ItemName")
                    if itemNameLabel and itemNameLabel.Text ~= "" and itemNameLabel.Text ~= lastFishName then
                        lastFishName = itemNameLabel.Text
                        fishCaughtBindable:Fire()
                    end
                end
            else
                lastFishName = ""
            end
        end
    end
end)

local function stopAutoFishProcesses()
    featureState.AutoFish = false
    
    for i, item in ipairs(fishingTrove) do
        if typeof(item) == "RBXScriptConnection" then
            item:Disconnect()
        elseif typeof(item) == "thread" then
            task.cancel(item)
        end
    end
    fishingTrove = {}
    
    pcall(function()
        if Modules.FishingController and Modules.FishingController.RequestClientStopFishing then
            Modules.FishingController:RequestClientStopFishing(true)
        end
    end)
end

local function startAutoFishMethod_Instant()
    if not (Modules.ChargeRodFunc and Modules.StartMinigameFunc and Modules.CompleteFishingEvent and Modules.FishingController) then
        return
    end

    featureState.AutoFish = true

    local chargeCount = 0
    local isCurrentlyResetting = false
    local counterLock = false

    local function worker()
        while featureState.AutoFish and player do
            local currentResetTarget_Worker = featureState.Instant_ResetCount or 10

            if isCurrentlyResetting or chargeCount >= currentResetTarget_Worker then
                break
            end

            local success, err = pcall(function()
                while counterLock do task.wait() end
                counterLock = true

                if chargeCount < currentResetTarget_Worker then
                    chargeCount = chargeCount + 1
                else
                    counterLock = false
                    return
                end
                counterLock = false

                Modules.ChargeRodFunc:InvokeServer(nil, nil, nil, workspace:GetServerTimeNow())
                task.wait(featureState.Instant_ChargeDelay)
                Modules.StartMinigameFunc:InvokeServer(-139, 1, workspace:GetServerTimeNow())
                task.wait(featureState.Instant_StartDelay)

                if not featureState.AutoFish or isCurrentlyResetting then return end

                for _ = 1, featureState.Instant_SpamCount do
                    if not featureState.AutoFish or isCurrentlyResetting then break end
                    Modules.CompleteFishingEvent:FireServer()
                    task.wait(0.05)
                end

                if not featureState.AutoFish or isCurrentlyResetting then return end

                local gotFishSignal = false
                local connection
                local timeoutThread = task.delay(featureState.Instant_CatchTimeout, function()
                    if not gotFishSignal and connection and connection.Connected then
                        connection:Disconnect()
                    end
                end)

                connection = fishCaughtBindable.Event:Connect(function()
                    if gotFishSignal then return end
                    gotFishSignal = true
                    task.cancel(timeoutThread)
                    if connection and connection.Connected then
                        connection:Disconnect()
                    end
                end)

                while not gotFishSignal and task.wait() do
                    if not featureState.AutoFish or isCurrentlyResetting then break end
                    if timeoutThread and coroutine.status(timeoutThread) == "dead" then break end
                end

                if connection and connection.Connected then connection:Disconnect() end

                if Modules.FishingController and Modules.FishingController.RequestClientStopFishing then
                    pcall(Modules.FishingController.RequestClientStopFishing, Modules.FishingController, true)
                end

                task.wait()
            end)

            if not success then
                warn("GLua Auto Instant Fish Error: ", err)
                task.wait(1)
            end

            if not featureState.AutoFish then break end
            task.wait(featureState.Instant_CycleDelay)
        end
    end

    autoFishThread = task.spawn(function()
        while featureState.AutoFish do
            local currentResetTarget = featureState.Instant_ResetCount or 10
            local currentPauseTime = featureState.Instant_ResetPause or 0.01

            chargeCount = 0
            isCurrentlyResetting = false

            local batchTrove = {}

            for i = 1, featureState.Instant_WorkerCount do
                if not featureState.AutoFish then break end
                local workerThread = task.spawn(worker)
                table.insert(batchTrove, workerThread)
                table.insert(fishingTrove, workerThread)
            end

            while featureState.AutoFish and chargeCount < currentResetTarget do
                task.wait()
            end

            isCurrentlyResetting = true

            if featureState.AutoFish then
                for _, thread in ipairs(batchTrove) do
                    task.cancel(thread)
                end
                batchTrove = {}

                task.wait(currentPauseTime)
            end
        end
        stopAutoFishProcesses()
    end)

    table.insert(fishingTrove, autoFishThread)
end

local function startOrStopAutoFish(shouldStart)
    if shouldStart then
        stopAutoFishProcesses()
        featureState.AutoFish = true
        equipFishingRod()
        task.wait(0.01)
        startAutoFishMethod_Instant()
    else
        stopAutoFishProcesses()
    end
end

FishingTab:Section({ Title = "Settings", Opened = true })

local startDelaySlider = FishingTab:Slider({
    Title = "Delay Recast",
    Desc = "(Default: 1.20)",
    Value = { Min = 0.00, Max = 5.0, Default = featureState.Instant_StartDelay },
    Precise = 2,
    Step = 0.01,
    Callback = function(v)
        featureState.Instant_StartDelay = tonumber(v)
    end
})
Config:Register("Instant_StartDelay", startDelaySlider)

local resetCountSlider = FishingTab:Slider({
    Title = "Spam Finish",
    Desc = "(Default: 10)",
    Value = { Min = 5, Max = 50, Default = featureState.Instant_ResetCount },
    Precise = 0,
    Step = 1,
    Callback = function(v)
        local num = math.floor(tonumber(v) or 10)
        featureState.Instant_ResetCount = num
        Config:Set("Instant_ResetCount", num)
    end
})
Config:Register("Instant_ResetCount", resetCountSlider)

local resetPauseSlider = FishingTab:Slider({
    Title = "Cooldown Recast",
    Desc = "(Default: 0.01)",
    Value = { Min = 0.01, Max = 5, Default = featureState.Instant_ResetPause },
    Precise = 2,
    Step = 0.01,
    Callback = function(v)
        local num = tonumber(v) or 2.0
        featureState.Instant_ResetPause = num
        Config:Set("Instant_ResetPause", num)
    end
})
Config:Register("Instant_ResetPause", resetPauseSlider)

FishingTab:Section({ Title = "AutoFish X7 Speed", Opened = true })

local autoFishToggle = FishingTab:Toggle({
    Title = "AutoFish",
    Desc = "still unstable and lots of bugs.",
    Value = false,
    Callback = startOrStopAutoFish
})
Config:Register("AutoFish", autoFishToggle)

-- Matikan semua animasi aktif di Humanoid
local stopAnimConnections = {}
local function setGameAnimationsEnabled(state)
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end

    -- Bersihin koneksi lama
    for _, conn in pairs(stopAnimConnections) do
        conn:Disconnect()
    end
    stopAnimConnections = {}

    if state then
        -- Hentikan semua animasi yang lagi jalan
        for _, track in ipairs(humanoid:FindFirstChildOfClass("Animator"):GetPlayingAnimationTracks()) do
            track:Stop(0)
        end

        -- Cegah animasi baru dimainkan
        local conn = humanoid:FindFirstChildOfClass("Animator").AnimationPlayed:Connect(function(track)
            task.defer(function()
                track:Stop(0)
            end)
        end)
        table.insert(stopAnimConnections, conn)

        WindUI:Notify({
            Title = "Animation Disabled",
            Content = "All animations from the game have been disabled..",
            Duration = 4,
            Icon = "pause-circle"
        })
    else
        -- Kembalikan normal
        for _, conn in pairs(stopAnimConnections) do
            conn:Disconnect()
        end
        stopAnimConnections = {}

        WindUI:Notify({
            Title = "Animation Enabled",
            Content = "Animations from the game are reactivated.",
            Duration = 4,
            Icon = "play-circle"
        })
    end
end

-- Toggle baru untuk matikan animasi dari game
local gameAnimToggle = FishingTab:Toggle({
    Title = "No Animation",
    Desc = "Stop all animations from the game.",
    Value = false,
    Callback = function(v)
        setGameAnimationsEnabled(v)
    end
})
Config:Register("DisableGameAnimations", gameAnimToggle)

local ConfigSection = Window:Section({ Title = "Settings", Opened = true })
local ConfigTab = ConfigSection:Tab({ Title = "Config Menu", Icon = "save", ShowTabTitle = true })

ConfigTab:Button({
    Title = "Save Config",
    Desc = "Saves current settings.",
    Icon = "save",
    Callback = function()
        local success, err = pcall(Config.Save, Config)
        if success then
            WindUI:Notify({ Title = "Success", Content = "Configuration saved.", Duration = 3, Icon = "check-circle" })
        else
            WindUI:Notify({ Title = "Error", Content = "Failed to save: " .. tostring(err), Duration = 5, Icon = "x-circle" })
        end
    end
})

ConfigTab:Button({
    Title = "Load Config",
    Desc = "Loads saved settings.",
    Icon = "upload-cloud",
    Callback = function()
        local success, err = pcall(Config.Load, Config)
        if success then
            WindUI:Notify({ Title = "Success", Content = "Configuration loaded.", Duration = 3, Icon = "check-circle" })
        else
            WindUI:Notify({ Title = "Error", Content = "No saved config found.", Duration = 5, Icon = "x-circle" })
        end
    end
})

if Window then
    Window:SelectTab(1)
    WindUI:Notify({
        Title = "X7 Speed Ready",
        Content = "X7 speed loaded successfully!",
        Duration = 5,
        Icon = "check-circle"
    })
end