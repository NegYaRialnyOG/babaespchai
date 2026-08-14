--[[
    ===================================================================
    MM2 Clean Standalone Autofarm + Discord Webhooks
    Based directly on original mm2 autofarm.lua engine
    100% Compatible with all standard Roblox Executors (Solara, Wave, etc.)
    ===================================================================
--]]

local Config = {
    WebhookURL = "https://discord.com/api/webhooks/1537506182548295760/lOkkQ7G6mYbL--4LcsiTbYPeuN7oVeJ2c9GS5Wmn54bO-vCjzLaDFDPwEIhOwVRvvenZ",
    WebhookInterval = 60, -- секунд между отчетами
    TweenSpeed = 30,
    MapOffset = 15,
    MinSafeDistance = 80,
    SafezoneTweenDuration = 2.5,
    MaxCoins = 40,
    NoUndergroundMaps = {"Yacht", "Pier2", "Pier"}
}

local FLING_TIMEOUT = 8.0
local FLING_VELOCITY = Vector3.new(9999, 9999, 9999)
local VOID_POSITION = Vector3.new(0, -500, 0)
local LOBBY_POSITION = Vector3.new(-4981.51, 308.51, 3.79)

local map
local last_map_name
local last_coin
local is_resetting_in_void = false
local has_flung_all_this_bag = false
local is_flinging_all = false
local can_tween = true

local players = game:GetService("Players")
local localplayer = players.LocalPlayer
local camera = workspace.CurrentCamera
local resetting_character = nil
local has_reset_for_bag = false
local has_flung_murderer = false
local round_start_time = 0

-- Статистика для вебхуков
local session_start = os.clock()
local session_coins = 0
local last_coin_count = 0
local last_webhook_time = os.clock()

local http_req = (syn and syn.request) 
    or (http and http.request) 
    or http_request 
    or (fluxus and fluxus.request) 
    or request

-- Drawing UI
local status = nil
pcall(function()
    status = Drawing.new("Text")
    status.Size = 22
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

local function is_valid(obj)
    return obj and obj.Parent ~= nil
end

local function magnitude(point1, point2)
    local dx = point2.X - point1.X
    local dy = point2.Y - point1.Y
    local dz = point2.Z - point1.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function set_noclip()
    local character = localplayer.Character
    if not character then return end
    for _, v in ipairs(character:GetDescendants()) do
        if v:IsA("BasePart") then
            v.CanCollide = false
        end
    end
end

local function enable_full_collision()
    local character = localplayer.Character
    if not character then return end
    for _, v in ipairs(character:GetDescendants()) do
        if v:IsA("BasePart") then
            v.CanCollide = true
        end
    end
end

local function find_map()
    for _, v in ipairs(workspace:GetChildren()) do
        if v:FindFirstChild("Spawns") and v.Name ~= "Lobby" then
            return v
        end
    end
    return nil
end

local function reset_round_state()
    is_resetting_in_void = false
    has_flung_all_this_bag = false
    is_flinging_all = false
    has_reset_for_bag = false
    has_flung_murderer = false
    resetting_character = nil
    last_coin = nil
    can_tween = true
    round_start_time = os.clock()
end

local function get_safezone_position()
    if is_valid(map) then
        local spawns = map:FindFirstChild("Spawns")
        if spawns then
            for _, child in ipairs(spawns:GetChildren()) do
                if child:IsA("BasePart") and child.Position then
                    return child.Position + Vector3.new(250, 350, 250)
                end
            end
        end
    end
    return LOBBY_POSITION
end

local function get_player_level()
    local lvl = 0
    pcall(function()
        local leaderstats = localplayer:FindFirstChild("leaderstats")
        if leaderstats and leaderstats:FindFirstChild("Level") then
            lvl = tonumber(leaderstats.Level.Value) or 0
        end
        if lvl == 0 then
            local mainGui = localplayer.PlayerGui:FindFirstChild("MainGUI")
            if mainGui then
                local l = mainGui:FindFirstChild("Level", true)
                if l and l:IsA("TextLabel") and l.Text then
                    lvl = tonumber(l.Text:match("%d+")) or 0
                end
            end
        end
    end)
    return lvl
end

local function get_coin_info()
    local total_coins = 0
    pcall(function()
        local coin_bags = localplayer.PlayerGui.MainGUI.Game.CoinBags
        local container = coin_bags:FindFirstChild("Container")
        if not container then return end
        for _, child in ipairs(container:GetChildren()) do
            if child.ClassName == "Frame" then
                local currency = child:FindFirstChild("CurrencyFrame")
                local icon = currency and currency:FindFirstChild("Icon")
                local text_label = icon and icon:FindFirstChild("Coins")
                if text_label and text_label.Text then
                    local num = tonumber(text_label.Text:match("%d+"))
                    if num then
                        total_coins = total_coins + num
                    end
                end
            end
        end
    end)
    local is_full = (total_coins >= Config.MaxCoins)
    return total_coins, is_full
end

local function send_webhook(is_bag_full)
    if not http_req or not Config.WebhookURL or #Config.WebhookURL < 15 then return end

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

            local lvl = get_player_level()
            local cur_coins, _ = get_coin_info()

            local body = game:GetService("HttpService"):JSONEncode({
                username = "MM2 Autofarm",
                avatar_url = "https://i.imgur.com/8Q9Z5gX.png",
                embeds = {{
                    title = is_bag_full and "🎒 Сумка заполнена | Ресет в войд" or "📊 Статистика фарма MM2",
                    color = is_bag_full and 16763904 or 4317924,
                    fields = {
                        { name = "👤 Игрок", value = "```" .. localplayer.Name .. "```", inline = true },
                        { name = "⭐ Уровень", value = "```" .. tostring(lvl) .. "```", inline = true },
                        { name = "💰 В сумке", value = "```" .. tostring(cur_coins) .. " / " .. tostring(Config.MaxCoins) .. "```", inline = true },
                        { name = "🪙 За сессию", value = "```" .. tostring(session_coins) .. "```", inline = true },
                        { name = "📈 Монет / час", value = "```" .. tostring(cph) .. " c/h```", inline = true },
                        { name = "⏱ Время фарма", value = "```" .. time_str .. "```", inline = true }
                    },
                    footer = { text = "MM2 Executor Engine • " .. os.date("%H:%M:%S") }
                }}
            })

            http_req({
                Url = Config.WebhookURL,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = body
            })
            last_webhook_time = os.clock()
        end)
    end)
end

local function get_knife_tool()
    local character = localplayer.Character
    local backpack = localplayer:FindFirstChild("Backpack")
    if character then
        local knife = character:FindFirstChild("Knife")
        if knife and knife.ClassName == "Tool" then
            return knife
        end
    end
    if backpack then
        local knife = backpack:FindFirstChild("Knife")
        if knife and knife.ClassName == "Tool" then
            return knife
        end
    end
    return nil
end

local function am_i_murderer()
    return get_knife_tool() ~= nil
end

local function get_threat()
    local is_me_murderer = am_i_murderer()
    for _, plr in ipairs(players:GetPlayers()) do
        if plr ~= localplayer then
            local character = plr.Character
            local backpack = plr:FindFirstChild("Backpack")
            local function check_inventory(inv)
                if not inv then return false end
                for _, child in ipairs(inv:GetChildren()) do
                    if child.ClassName == "Tool" then
                        local name = child.Name:lower()
                        if is_me_murderer then
                            if name:find("gun") then return true end
                        else
                            if name:find("knife") then return true end
                        end
                    end
                end
                return false
            end
            if check_inventory(character) or check_inventory(backpack) then
                return plr, is_me_murderer and "Sheriff" or "Murderer"
            end
        end
    end
    return nil, is_me_murderer and "No Sheriff" or "No Murderer"
end

local function get_closest_coin()
    local character = localplayer.Character
    if not character then return nil, math.huge, nil, "" end
    local humanoidrootpart = character:FindFirstChild("HumanoidRootPart")
    if not humanoidrootpart then return nil, math.huge, nil, "" end
    local coin_container = map and map:FindFirstChild("CoinContainer")
    if not coin_container then return nil, math.huge, nil, "" end
    local threat, threat_role = get_threat()
    local threat_root = threat and threat.Character and threat.Character:FindFirstChild("HumanoidRootPart")
    local safe_coins = {}

    for _, coin in ipairs(coin_container:GetChildren()) do
        if is_valid(coin) and coin:FindFirstChild("TouchInterest") then
            local coin_pos = coin.Position
            if coin_pos then
                local dist_to_player = magnitude(coin_pos, humanoidrootpart.Position)
                local dist_to_threat = math.huge
                if threat_root and threat_root.Position then
                    dist_to_threat = magnitude(coin_pos, threat_root.Position)
                end
                if dist_to_threat >= Config.MinSafeDistance then
                    table.insert(safe_coins, {
                        coin = coin,
                        dist_player = dist_to_player,
                        dist_threat = dist_to_threat
                    })
                end
            end
        end
    end

    local best_coin = nil
    if #safe_coins > 0 then
        best_coin = safe_coins[1]
        for i = 2, #safe_coins do
            if safe_coins[i].dist_player < best_coin.dist_player then
                best_coin = safe_coins[i]
            end
        end
    end

    if best_coin then
        return best_coin.coin, best_coin.dist_player, threat, threat_role
    end
    return nil, math.huge, threat, threat_role
end

local function get_dynamic_underground_y()
    local min_y = 9999
    if is_valid(map) then
        local spawns = map:FindFirstChild("Spawns")
        if spawns then
            for _, child in ipairs(spawns:GetChildren()) do
                if child:IsA("BasePart") then
                    local pos = child.Position
                    if pos and pos.Y < min_y then
                        min_y = pos.Y
                    end
                end
            end
        end
    end
    if min_y == 9999 then min_y = 0 end
    return min_y - Config.MapOffset
end

local function is_water_map()
    if not is_valid(map) then return false end
    for _, name in ipairs(Config.NoUndergroundMaps) do
        if map.Name == name then return true end
    end
    return false
end

local function tween_position(object, target, duration, threat)
    if not duration or duration <= 0 then duration = 1 end
    can_tween = false
    local function cleanup()
        can_tween = true
    end

    pcall(function()
        local function move_to(end_pos, time_sec)
            local start_time = os.clock()
            local start_pos = object.Position
            if not start_pos or not end_pos then return true end
            local end_time = start_time + time_sec
            local aborted = false
            while os.clock() < end_time do
                if not is_valid(object) or not is_valid(target) or not is_valid(map) then
                    aborted = true
                    break
                end
                if threat and threat.Character then
                    local root = threat.Character:FindFirstChild("HumanoidRootPart")
                    if root and root.Position and object.Position then
                        if magnitude(object.Position, root.Position) < Config.MinSafeDistance then
                            aborted = true
                            break
                        end
                    end
                end
                local alpha = (os.clock() - start_time) / time_sec
                if alpha > 1 then alpha = 1 end
                local sx, sy, sz = start_pos.X, start_pos.Y, start_pos.Z
                local tx, ty, tz = end_pos.X, end_pos.Y, end_pos.Z
                object.Position = Vector3.new(
                    sx + (tx - sx) * alpha,
                    sy + (ty - sy) * alpha,
                    sz + (tz - sz) * alpha
                )
                object.Velocity = Vector3.new(0, 0, 0)
                pcall(function() object.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
                task.wait()
            end
            return aborted
        end

        if not is_valid(target) then return end
        local obj_pos = object.Position
        local tgt_pos = target.Position
        if not obj_pos or not tgt_pos then return end

        if is_water_map() then
            move_to(tgt_pos, duration)
            if is_valid(target) and is_valid(object) then
                object.Position = target.Position
            end
        else
            local underground_y = get_dynamic_underground_y()
            local target_under_pos = Vector3.new(tgt_pos.X, underground_y, tgt_pos.Z)
            local current_under_pos = Vector3.new(obj_pos.X, underground_y, obj_pos.Z)
            if math.abs(obj_pos.Y - underground_y) > 2 then
                move_to(current_under_pos, 0.04)
            end
            if not move_to(target_under_pos, duration) then
                if is_valid(target) and is_valid(object) then
                    object.Position = target.Position
                    if type(firetouchinterest) == "function" then
                        pcall(function()
                            firetouchinterest(object, target, 0)
                            task.wait(0.01)
                            firetouchinterest(object, target, 1)
                        end)
                    end
                    task.wait()
                    if is_valid(object) then
                        object.Position = Vector3.new(object.Position.X, underground_y, object.Position.Z)
                    end
                end
            end
        end
    end)
    cleanup()
end

local function run_fling_murderer_sequence()
    local character = localplayer.Character
    if not character then return end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:FindFirstChild("Humanoid")
    if not hrp or not humanoid then return end
    is_flinging_all = true
    local threat_plr, _ = get_threat()
    if threat_plr and threat_plr.Character and threat_plr.Character:FindFirstChild("HumanoidRootPart") then
        local threat_hrp = threat_plr.Character.HumanoidRootPart
        local threat_hum = threat_plr.Character:FindFirstChildOfClass("Humanoid") or threat_plr.Character:FindFirstChild("Humanoid")
        set_status("Flinging Murderer: " .. threat_plr.Name, Color3.fromRGB(255, 150, 0))
        local fling_start = os.clock()
        while is_valid(character) and is_valid(hrp) and (humanoid and humanoid.Health > 0) and is_valid(threat_hrp) and (threat_hum and threat_hum.Health > 0) and threat_hrp.Position.Y > -100 do
            if (os.clock() - fling_start) > FLING_TIMEOUT then
                break
            end
            enable_full_collision()
            local rot_angle = (os.clock() * 60) % 360
            local rot_offset = Vector3.new(math.sin(rot_angle) * 0.1, 0, math.cos(rot_angle) * 0.1)
            local threat_pos = threat_hrp.Position
            if threat_pos then
                hrp.Position = Vector3.new(
                    threat_pos.X + rot_offset.X,
                    threat_pos.Y + rot_offset.Y,
                    threat_pos.Z + rot_offset.Z
                )
            end
            hrp.Velocity = FLING_VELOCITY
            pcall(function() hrp.AssemblyLinearVelocity = FLING_VELOCITY end)
            task.wait(0.02)
        end
        if is_valid(hrp) then
            hrp.Velocity = Vector3.new(0, 0, 0)
            pcall(function() hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
        end
    end
    has_flung_all_this_bag = true
    is_flinging_all = false
end

local function update_auto_farm()
    map = find_map()
    local current_map_name = map and map.Name or nil
    if current_map_name ~= last_map_name then
        reset_round_state()
        last_map_name = current_map_name
    end
    local character = localplayer.Character
    if not character then
        set_status("Character missing", Color3.fromRGB(200, 200, 200))
        return
    end
    local humanoidrootpart = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:FindFirstChild("Humanoid")
    if not humanoidrootpart then
        set_status("RootPart missing", Color3.fromRGB(200, 200, 200))
        return
    end

    if resetting_character and resetting_character ~= character then
        if humanoid and humanoid.Health > 0 then
            resetting_character = nil
            is_resetting_in_void = false
            has_reset_for_bag = true
        end
    end

    if is_resetting_in_void then
        set_status("Bag Full: Resetting...", Color3.fromRGB(255, 90, 90))
        humanoidrootpart.Position = VOID_POSITION
        humanoidrootpart.Velocity = Vector3.new(0, -500, 0)
        pcall(function() humanoid.Health = 0 end)
        return
    end

    if humanoid and humanoid.Health <= 0 then
        return
    end

    if is_flinging_all then
        return
    end

    if has_reset_for_bag and not has_flung_murderer then
        local is_murderer = am_i_murderer()
        if not is_murderer then
            has_flung_murderer = true
            run_fling_murderer_sequence()
            return
        else
            has_flung_murderer = true
        end
    end

    set_noclip()
    local coin_val, is_bag_full = get_coin_info()

    if not is_bag_full and coin_val < Config.MaxCoins then
        has_reset_for_bag = false
    end

    -- Статистика монет
    if coin_val > last_coin_count then
        local diff = coin_val - last_coin_count
        if diff <= 50 then
            session_coins = session_coins + diff
        end
    end
    last_coin_count = coin_val

    -- Периодический вебхук
    if (os.clock() - last_webhook_time) >= Config.WebhookInterval then
        send_webhook(false)
    end

    if is_bag_full and not has_reset_for_bag then
        is_resetting_in_void = true
        resetting_character = character
        set_status("Bag Full (" .. coin_val .. "): Resetting...", Color3.fromRGB(255, 90, 90))
        send_webhook(true)
        humanoidrootpart.Position = VOID_POSITION
        humanoidrootpart.Velocity = Vector3.new(0, -500, 0)
        pcall(function() humanoid.Health = 0 end)
        return
    end

    if is_valid(map) then
        if (os.clock() - round_start_time) < 3.5 then
            local safezone = get_safezone_position()
            set_status("Round Start: Staying in Safezone...", Color3.fromRGB(100, 230, 255))
            humanoidrootpart.Velocity = Vector3.new(0, 0, 0)
            humanoidrootpart.Position = safezone
            can_tween = true
            return
        end

        local closest_coin, coin_distance, threat, threat_role = get_closest_coin()

        if threat and threat.Character then
            local threat_root = threat.Character:FindFirstChild("HumanoidRootPart")
            if threat_root and threat_root.Position then
                local threat_pos = threat_root.Position
                local my_pos = humanoidrootpart.Position
                if threat_pos and my_pos and magnitude(my_pos, threat_pos) < Config.MinSafeDistance then
                    local safezone = get_safezone_position()
                    set_status("FLEEING " .. threat_role .. ": " .. threat.Name, Color3.fromRGB(255, 60, 60))
                    humanoidrootpart.Velocity = Vector3.new(0, 0, 0)
                    humanoidrootpart.Position = safezone
                    can_tween = true
                    return
                end
            end
        end

        if is_valid(closest_coin) then
            last_coin = closest_coin
            humanoidrootpart.Velocity = Vector3.new(0, 0, 0)
            local threat_info = threat and ("Evading " .. threat_role .. ": " .. threat.Name) or "Safe"
            local color = Color3.fromRGB(80, 230, 130)
            if threat then
                if threat_role == "Sheriff" then
                    color = Color3.fromRGB(100, 160, 255)
                else
                    color = Color3.fromRGB(255, 80, 80)
                end
            end
            set_status(threat_info .. " | Bag: " .. coin_val .. " | Total: " .. session_coins, color)
            if can_tween then
                local dur = coin_distance / Config.TweenSpeed
                if coin_distance > 500 then
                    dur = Config.SafezoneTweenDuration
                end
                task.spawn(function()
                    tween_position(humanoidrootpart, closest_coin, dur, threat)
                end)
            end
        else
            local safezone = get_safezone_position()
            set_status("Waiting... | Coins: " .. coin_val, Color3.fromRGB(255, 210, 80))
            humanoidrootpart.Velocity = Vector3.new(0, 0, 0)
            humanoidrootpart.Position = safezone
        end
    else
        set_status("IDLE (Lobby)", Color3.fromRGB(200, 200, 200))
    end
end

-- Отправка стартового вебхука
send_webhook(false)

-- Главный цикл
while true do
    pcall(function()
        update_auto_farm()
    end)
    task.wait()
end
