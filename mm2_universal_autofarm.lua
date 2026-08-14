--[[
    ===================================================================
    MM2 Universal Autofarm (TravHub High-Speed Engine + Exact Stats)
    - Full Round Tracking via Gameplay Remotes (RoundStart / RoundEndFade)
    - High-Speed Hybrid Movement: Proximity Tween + Distant TP
    - Instant CoinCollected Remote Listener (Auto-Reset on 40 Bag Limit)
    - Exact Account Level (61) + Persistent All-Time Coin Tracker
    - Anti-AFK VirtualUser + Stepped Noclip
    - Rate-Limited Discord Webhook Reporter (Anti-Spam Mutex)
    - 100% Compatible with Matcha External LuaVM & All Roblox Executors
    ===================================================================
--]]

local Config = {
    WebhookURL = "https://discord.com/api/webhooks/1537506182548295760/lOkkQ7G6mYbL--4LcsiTbYPeuN7oVeJ2c9GS5Wmn54bO-vCjzLaDFDPwEIhOwVRvvenZ",
    WebhookInterval = 60, -- Интервал отчета в секундах
    FarmSpeed = 25,       -- Скорость перемещения к монетам (25 studs/sec)
    MaxCoins = 40,        -- Лимит монет до сброса в войд
    TeleportDistance = 140, -- Дистанция для мгновенного ТП к дальним монетам
    AutoResetOnFull = true,
}

local VOID_POSITION = Vector3.new(0, -500, 0)
local LOBBY_POSITION = Vector3.new(-4981.51, 308.51, 3.79)

-- Services
local players = game:GetService("Players")
local runservice = game:GetService("RunService")
local replicatedstorage = game:GetService("ReplicatedStorage")
local tweenservice = game:GetService("TweenService")
local httpservice = game:GetService("HttpService")
local virtualuser = game:GetService("VirtualUser")

local localplayer = players.LocalPlayer or players.PlayerAdded:Wait()
local camera = workspace.CurrentCamera

-- Anti-AFK
pcall(function()
    localplayer.Idled:Connect(function()
        if virtualuser then
            virtualuser:CaptureController()
            virtualuser:ClickButton2(Vector2.new(0, 0))
        end
    end)
end)

-- State Variables
local is_round_active = false
local is_resetting = false
local current_bag_coins = 0
local session_start = os.clock()
local session_coins = 0
local last_bag_count = 0
local last_webhook_time = os.clock()
local is_webhook_sending = false
local last_bag_webhook_time = 0

-- HTTP Request resolution
local http_req = (syn and syn.request) 
    or (http and http.request) 
    or http_request 
    or (fluxus and fluxus.request) 
    or request

-- Drawing HUD Overlay
local status = nil
pcall(function()
    status = Drawing.new("Text")
    status.Size = 20
    status.Font = 2
    status.Center = true
    status.Outline = true
    status.Color = Color3.fromRGB(255, 255, 255)
    status.Visible = true
end)

local function set_status(text, color)
    if status then
        pcall(function()
            status.Text = text
            status.Color = color or Color3.fromRGB(255, 255, 255)
            if camera then
                status.Position = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y * 0.05)
            end
        end)
    end
end

-- Persistent Storage on Disk
local STATS_FILE = "mm2_stats_" .. (localplayer and tostring(localplayer.UserId) or "Player") .. ".json"
local total_coins_all_time = 0

local function load_saved_stats()
    pcall(function()
        if type(readfile) == "function" then
            local can_read = true
            if type(isfile) == "function" and not isfile(STATS_FILE) then
                can_read = false
            end
            if can_read then
                local content = readfile(STATS_FILE)
                if content and #content > 0 then
                    local data = httpservice:JSONDecode(content)
                    if type(data) == "table" and data.TotalCoinsAllTime then
                        total_coins_all_time = tonumber(data.TotalCoinsAllTime) or 0
                    end
                end
            end
        end
    end)
end
load_saved_stats()

local function save_stats()
    pcall(function()
        if type(writefile) == "function" then
            local payload = httpservice:JSONEncode({
                TotalCoinsAllTime = (total_coins_all_time + session_coins),
                UserId = localplayer and localplayer.UserId or 0,
                LastUpdated = os.date("!%Y-%m-%dT%H:%M:%SZ")
            })
            writefile(STATS_FILE, payload)
        end
    end)
end

-- Character & RootPart helpers
local function get_character()
    return localplayer.Character
end

local function get_root_part()
    local char = get_character()
    return char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso"))
end

local function get_humanoid()
    local char = get_character()
    return char and char:FindFirstChildOfClass("Humanoid")
end

-- Exact Level Extraction (From Live Server Leaderboard)
local function get_real_level()
    local lvl = 0
    pcall(function()
        local mg = localplayer.PlayerGui:FindFirstChild("MainGUI")
        if not mg then return end
        local gameGui = mg:FindFirstChild("Game")
        if gameGui then
            local lb = gameGui:FindFirstChild("Leaderboard")
            local cont = lb and lb:FindFirstChild("Container")
            local pFrame = cont and cont:FindFirstChild(localplayer.Name)
            if pFrame and pFrame:FindFirstChild("Level") then
                local lvlNode = pFrame.Level:FindFirstChild("Level")
                if lvlNode and lvlNode.Text and lvlNode.Text ~= "failed to fetch text" then
                    local num = tonumber(lvlNode.Text:match("(%d+)"))
                    if num and num > 0 then lvl = num return end
                end
            end
            local g_lvl = gameGui:FindFirstChild("Level")
            if g_lvl and g_lvl:FindFirstChild("LevelText") then
                local t = g_lvl.LevelText.Text
                if t and t ~= "failed to fetch text" then
                    local num = tonumber(t:match("(%d+)"))
                    if num and num > 0 then lvl = num return end
                end
            end
        end
    end)
    return lvl
end

-- Live Round Bag Coins (From CoinBags UI)
local function get_bag_coins()
    local bag_coins = current_bag_coins
    pcall(function()
        local mg = localplayer.PlayerGui:FindFirstChild("MainGUI")
        if not mg then return end
        local gameGui = mg:FindFirstChild("Game")
        local coinBags = gameGui and gameGui:FindFirstChild("CoinBags")
        local container = coinBags and coinBags:FindFirstChild("Container")
        if container then
            local coin = container:FindFirstChild("Coin")
            if coin and coin:FindFirstChild("CurrencyFrame") and coin.CurrencyFrame:FindFirstChild("Icon") and coin.CurrencyFrame.Icon:FindFirstChild("Coins") then
                local t = coin.CurrencyFrame.Icon.Coins.Text
                local num = tonumber(t)
                if num then bag_coins = num end
            end
        end
    end)
    return bag_coins
end

-- Live Total Coins Balance (No Dock.Version Bug)
local function get_account_balance()
    local live_balance = 0
    pcall(function()
        local mg = localplayer.PlayerGui:FindFirstChild("MainGUI")
        if mg then
            local shop = mg:FindFirstChild("Game") and mg.Game:FindFirstChild("Shop")
            local coinsTitle = shop and shop:FindFirstChild("Title") and shop.Title:FindFirstChild("Coins")
            if coinsTitle then
                local cont = coinsTitle:FindFirstChild("Container")
                local amt = cont and cont:FindFirstChild("Amount")
                if amt and amt.ClassName == "TextLabel" and amt.Text and amt.Text ~= "failed to fetch text" then
                    local num = tonumber(amt.Text:gsub(",", ""):match("(%d+)"))
                    if num and num > 0 then live_balance = num return end
                end
            end
        end
    end)
    if live_balance > 0 then
        return live_balance
    end
    return (total_coins_all_time + session_coins)
end

-- Webhook Dispatcher
local function send_webhook(is_bag_full)
    if is_webhook_sending then return end
    if not http_req or not Config.WebhookURL or #Config.WebhookURL < 15 then return end

    is_webhook_sending = true
    last_webhook_time = os.clock()

    task.spawn(function()
        pcall(function()
            local elapsed = os.clock() - session_start
            local hours = math.floor(elapsed / 3600)
            local mins = math.floor((elapsed % 3600) / 60)
            local secs = math.floor(elapsed % 60)
            local time_str = string.format("%02dh %02dm %02ds", hours, mins, secs)

            local cph = 0
            if elapsed > 5 then
                cph = math.floor(session_coins / (elapsed / 3600))
            end

            local lvl = get_real_level()
            local totalBalance = get_account_balance()
            local curBag = get_bag_coins()

            local body = httpservice:JSONEncode({
                username = "MM2 High-Speed Autofarm",
                avatar_url = "https://i.imgur.com/8Q9Z5gX.png",
                embeds = {{
                    title = is_bag_full and "🎒 Сумка Заполнена (40) | Ресет в Войд" or "📊 MM2 Farm Session Status",
                    color = is_bag_full and 16763904 or 4317924,
                    fields = {
                        { name = "👤 Игрок", value = "```" .. localplayer.Name .. "```", inline = true },
                        { name = "⭐ Уровень", value = "```" .. tostring(lvl) .. "```", inline = true },
                        { name = "💰 Баланс монет", value = "```" .. tostring(totalBalance) .. "```", inline = true },
                        { name = "🎒 В сумке", value = "```" .. tostring(curBag) .. " / " .. tostring(Config.MaxCoins) .. "```", inline = true },
                        { name = "🪙 За сессию", value = "```" .. tostring(session_coins) .. "```", inline = true },
                        { name = "📈 Монет / час", value = "```" .. tostring(cph) .. " c/h```", inline = true },
                        { name = "⏱ Время фарма", value = "```" .. time_str .. "```", inline = true }
                    },
                    footer = { text = "TravHub High-Speed Engine • " .. os.date("%H:%M:%S") }
                }}
            })

            http_req({
                Url = Config.WebhookURL,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = body
            })
        end)
        task.wait(1.0)
        is_webhook_sending = false
    end)
end

-- Background Webhook Loop (Strictly 60s)
task.spawn(function()
    while true do
        task.wait(2.0)
        if (os.clock() - last_webhook_time) >= (Config.WebhookInterval or 60) then
            send_webhook(false)
        end
    end
end)

-- Continuous Stepped Noclip
runservice.Stepped:Connect(function()
    local char = get_character()
    if char and char:IsDescendantOf(workspace) then
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then
                part.CanCollide = false
            end
        end
    end
end)

-- Map & Coin Container Detection (TravHub Logic)
local function get_closest_coin()
    local hrp = get_root_part()
    if not hrp then return nil, math.huge end

    local closest_part = nil
    local min_dist = math.huge

    for _, obj in ipairs(workspace:GetChildren()) do
        local container = obj:FindFirstChild("CoinContainer")
        if container then
            for _, coin in ipairs(container:GetChildren()) do
                if coin:IsA("BasePart") and coin:FindFirstChild("TouchInterest") then
                    local dist = (hrp.Position - coin.Position).Magnitude
                    if dist < min_dist then
                        min_dist = dist
                        closest_part = coin
                    end
                end
            end
        end
    end

    if not closest_part then
        for _, descendant in ipairs(workspace:GetDescendants()) do
            if descendant:IsA("BasePart") and (descendant.Name == "Coin_Server" or descendant.Name == "Coin" or descendant.Name == "candy") and descendant:FindFirstChild("TouchInterest") then
                local dist = (hrp.Position - descendant.Position).Magnitude
                if dist < min_dist then
                    min_dist = dist
                    closest_part = descendant
                end
            end
        end
    end

    return closest_part, min_dist
end

-- Reset Character in Void
local function reset_in_void()
    if is_resetting then return end
    is_resetting = true
    set_status("Bag Full (" .. current_bag_coins .. "): Resetting...", Color3.fromRGB(255, 90, 90))

    if (os.clock() - last_bag_webhook_time) >= 15 then
        last_bag_webhook_time = os.clock()
        send_webhook(true)
    end

    local hrp = get_root_part()
    local hum = get_humanoid()
    if hrp then
        hrp.Position = VOID_POSITION
        hrp.Velocity = Vector3.new(0, -500, 0)
    end
    if hum then
        pcall(function() hum.Health = 0 end)
    end
end

-- Remote Event Listeners for Round Tracking (TravHub Architecture)
local gameplayRemotes = replicatedstorage:FindFirstChild("Remotes") and replicatedstorage.Remotes:FindFirstChild("Gameplay")
if gameplayRemotes then
    local roundStart = gameplayRemotes:FindFirstChild("RoundStart")
    local roundEnd = gameplayRemotes:FindFirstChild("RoundEndFade")
    local coinCollected = gameplayRemotes:FindFirstChild("CoinCollected")

    if roundStart then
        roundStart.OnClientEvent:Connect(function()
            is_round_active = true
            is_resetting = false
            current_bag_coins = 0
            set_status("ROUND ACTIVE | Farm Started", Color3.fromRGB(0, 255, 140))
        end)
    end

    if roundEnd then
        roundEnd.OnClientEvent:Connect(function()
            is_round_active = false
            is_resetting = false
            set_status("LOBBY (Round Ended)", Color3.fromRGB(200, 200, 200))
        end)
    end

    if coinCollected then
        coinCollected.OnClientEvent:Connect(function(coinType, amount)
            if amount then
                current_bag_coins = tonumber(amount) or current_bag_coins
            else
                current_bag_coins = current_bag_coins + 1
            end

            session_coins = session_coins + 1
            save_stats()

            if current_bag_coins >= Config.MaxCoins and Config.AutoResetOnFull then
                reset_in_void()
            end
        end)
    end
end

-- Character Respawn Handler
localplayer.CharacterAdded:Connect(function(newChar)
    is_resetting = false
    current_bag_coins = 0
    task.wait(1)
end)

-- Main High-Speed Farming Loop (TravHub Proximity Tween + Distant TP)
task.spawn(function()
    while true do
        local hrp = get_root_part()
        local hum = get_humanoid()

        -- Auto-detect round if map exists with coins
        local coin_target, coin_dist = get_closest_coin()
        if coin_target and not is_round_active then
            is_round_active = true
        end

        if hrp and hum and hum.Health > 0 and not is_resetting then
            local bag_val = get_bag_coins()

            if bag_val >= Config.MaxCoins and Config.AutoResetOnFull then
                reset_in_void()
            elseif coin_target and is_round_active then
                set_status("FARMING | Bag: " .. bag_val .. " / " .. Config.MaxCoins .. " | Session: " .. session_coins, Color3.fromRGB(0, 255, 140))

                if coin_dist > Config.TeleportDistance then
                    -- Instant Teleport for distant coins
                    hrp.CFrame = coin_target.CFrame
                    task.wait(0.05)
                else
                    -- Smooth Linear Tween for proximity coins
                    local duration = math.clamp(coin_dist / Config.FarmSpeed, 0.05, 3.0)
                    local tween = tweenservice:Create(hrp, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
                        CFrame = coin_target.CFrame
                    })
                    tween:Play()

                    local start_t = os.clock()
                    while coin_target and coin_target:FindFirstChild("TouchInterest") and is_round_active and (os.clock() - start_t) < duration do
                        task.wait()
                    end
                    pcall(function() tween:Cancel() end)
                end
            else
                if is_round_active then
                    set_status("Searching Coins... | Bag: " .. bag_val, Color3.fromRGB(255, 210, 80))
                else
                    set_status("LOBBY (Waiting for Round)", Color3.fromRGB(200, 200, 200))
                end
            end
        end
        task.wait(0.1)
    end
end)

print("[MM2 High-Speed Autofarm] Initialized successfully. Level: " .. get_real_level() .. ", Player: " .. localplayer.Name)
