-- 1. Библиотека
local createWindow = loadstring(game:HttpGet("https://pastebin.com/raw/j48z2Xp3"))()
local window = createWindow("Coin Farm")

-- 2. Логика автофарма (вне тумблера!)
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local rootPart = character:WaitForChild("HumanoidRootPart")
local humanoid = character:WaitForChild("Humanoid")

local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
local gameplayRemotes = remotes and remotes:WaitForChild("Gameplay", 5)

local MAX_DIST = 1000
local TARGET_SPEED = 23
local RESET_DELAY = 5.0
local ROUND_START_DELAY = 1.5

local enabled = false
local afkActive = false
local isLoaded = false
local bagIsFull = false
local isWaitingForCoins = false
local activeCoins = {}
local blacklistedCoins = {}
local currentTarget = nil
local noCoinsStartTime = nil
local hasCollectedThisLife = false

local linearVelocity = nil
local velocityAttachment = nil
local noclipConnection = nil
local heartbeatConnection = nil
local coinAddedConnection = nil
local coinRemovedConnection = nil
local coinsStartedConnection = nil
local coinCollectedConnection = nil
local targetFinderThread = nil
local characterAddedConnection = nil
local characterParts = {}

local function updateCharacterParts()
    characterParts = {}
    if not character then return end
    for _, part in ipairs(character:GetChildren()) do
        if part:IsA("BasePart") then
            table.insert(characterParts, part)
        end
    end
end

local function restoreCollision()
    for _, part in ipairs(characterParts) do
        if part and part.Parent then part.CanCollide = true end
    end
end

local function cleanupConnections()
    if heartbeatConnection then heartbeatConnection:Disconnect() heartbeatConnection = nil end
    if noclipConnection then noclipConnection:Disconnect() noclipConnection = nil end
    if coinAddedConnection then coinAddedConnection:Disconnect() coinAddedConnection = nil end
    if coinRemovedConnection then coinRemovedConnection:Disconnect() coinRemovedConnection = nil end
    if coinsStartedConnection then coinsStartedConnection:Disconnect() coinsStartedConnection = nil end
    if coinCollectedConnection then coinCollectedConnection:Disconnect() coinCollectedConnection = nil end
end

local function stopMovement()
    if linearVelocity then
        linearVelocity.VectorVelocity = Vector3.zero
        linearVelocity.Enabled = false
    end
    if rootPart then
        rootPart.AssemblyLinearVelocity = Vector3.zero
        rootPart.AssemblyAngularVelocity = Vector3.zero
    end
end

local function setupVelocity()
    if not rootPart then return end
    velocityAttachment = rootPart:FindFirstChild("FarmAttachment")
    if not velocityAttachment then
        velocityAttachment = Instance.new("Attachment")
        velocityAttachment.Name = "FarmAttachment"
        velocityAttachment.Parent = rootPart
    end
    linearVelocity = rootPart:FindFirstChild("FarmLinearVelocity")
    if not linearVelocity then
        linearVelocity = Instance.new("LinearVelocity")
        linearVelocity.Name = "FarmLinearVelocity"
        linearVelocity.Attachment0 = velocityAttachment
        linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
        linearVelocity.VectorVelocity = Vector3.zero
        linearVelocity.Enabled = false
        linearVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
        linearVelocity.MaxAxesForce = Vector3.new(100000, 100000, 100000)
        linearVelocity.Parent = rootPart
    end
end

local function removeVelocity()
    if linearVelocity then linearVelocity:Destroy() linearVelocity = nil end
    if velocityAttachment then velocityAttachment:Destroy() velocityAttachment = nil end
end

local function startNoclip()
    if noclipConnection then noclipConnection:Disconnect() end
    updateCharacterParts()
    noclipConnection = RunService.Stepped:Connect(function()
        if character and enabled and humanoid and humanoid.Health > 0 and not bagIsFull and not isWaitingForCoins then
            for i = 1, #characterParts do
                local part = characterParts[i]
                if part and part.Parent and part.CanCollide then
                    part.CanCollide = false
                end
            end
        end
    end)
    if humanoid then
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
    end
end

local function stopNoclip()
    if noclipConnection then
        noclipConnection:Disconnect()
        noclipConnection = nil
    end
    restoreCollision()
end

local function antiAfkLoop()
    while afkActive and enabled do
        task.wait(30)
        if not afkActive or not enabled then break end
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end
end

local function isCoin(part)
    if not part:IsA("BasePart") or blacklistedCoins[part] then return false end
    local name = part.Name:lower()
    return name:find("coin") or name:find("cash") or name:find("money") or name:find("collect")
end

local function checkGuiBagFull()
    local playerGui = player:FindFirstChild("PlayerGui")
    if not playerGui then return false end
    for _, gui in ipairs(playerGui:GetChildren()) do
        if gui:IsA("ScreenGui") and gui.Name ~= "AutoFarmUI" then
            local container = gui:FindFirstChild("Container", true)
            if container then
                for _, frame in ipairs(container:GetChildren()) do
                    if frame:IsA("Frame") and frame.Visible then
                        local fullIcon = frame:FindFirstChild("FullBagIcon", true)
                        local fullText = frame:FindFirstChild("Full", true)
                        if (fullIcon and fullIcon.Visible) or (fullText and fullText.Visible) then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

local function trackCoin(part)
    if isCoin(part) then activeCoins[part] = true end
end

local function untrackCoin(part)
    activeCoins[part] = nil
    if currentTarget == part then currentTarget = nil end
end

local function triggerBagFullReset()
    if bagIsFull then return end
    bagIsFull = true
    stopMovement()
    stopNoclip()
    task.wait(0.2)
    if humanoid and humanoid.Health > 0 then
        humanoid.Health = 0
    end
end

local function initCoinListeners()
    activeCoins = {}
    for _, v in ipairs(Workspace:GetDescendants()) do
        if isCoin(v) then activeCoins[v] = true end
    end
    coinAddedConnection = Workspace.DescendantAdded:Connect(trackCoin)
    coinRemovedConnection = Workspace.DescendantRemoving:Connect(untrackCoin)
    if gameplayRemotes then
        local coinsStartedRemote = gameplayRemotes:WaitForChild("CoinsStarted", 5)
        local coinCollectedRemote = gameplayRemotes:WaitForChild("CoinCollected", 5)
        if coinsStartedRemote then
            coinsStartedConnection = coinsStartedRemote.OnClientEvent:Connect(function()
                isWaitingForCoins = true
                stopMovement()
                currentTarget = nil
                activeCoins = {}
                blacklistedCoins = {}
                noCoinsStartTime = nil
                bagIsFull = false
                task.wait(ROUND_START_DELAY)
                for _, v in ipairs(Workspace:GetDescendants()) do
                    if isCoin(v) then activeCoins[v] = true end
                end
                isWaitingForCoins = false
            end)
        end
        if coinCollectedRemote then
            coinCollectedConnection = coinCollectedRemote.OnClientEvent:Connect(function(coinType, currentAmount, maxAmount)
                local current = tonumber(currentAmount)
                local max = tonumber(maxAmount)
                if current and max and current >= max then
                    triggerBagFullReset()
                end
            end)
        end
    end
end

local function startTargetFinder()
    if targetFinderThread then task.cancel(targetFinderThread) end
    targetFinderThread = task.spawn(function()
        while isLoaded do
            task.wait(0.1)
            if enabled and not bagIsFull and checkGuiBagFull() then
                triggerBagFullReset()
            end
            if enabled and not bagIsFull and not isWaitingForCoins and rootPart then
                local rootPos = rootPart.Position
                local nearest = nil
                local nearestDist = MAX_DIST + 1
                for coin, _ in pairs(activeCoins) do
                    if coin and coin.Parent and not blacklistedCoins[coin] then
                        local dist = (coin.Position - rootPos).Magnitude
                        if dist < nearestDist then
                            nearestDist = dist
                            nearest = coin
                        end
                    else
                        activeCoins[coin] = nil
                    end
                end
                if nearest and not nearest:FindFirstChild("CoinVisual") then
                    activeCoins[nearest] = nil
                    nearest = nil
                end
                currentTarget = nearest
            end
        end
    end)
end

local function startMovementEngine()
    cleanupConnections()
    setupVelocity()
    initCoinListeners()
    noCoinsStartTime = nil
    if enabled and not bagIsFull then startNoclip() end
    heartbeatConnection = RunService.Heartbeat:Connect(function()
        if not enabled or bagIsFull or isWaitingForCoins or not rootPart or not rootPart.Parent or not humanoid or humanoid.Health <= 0 then
            stopMovement()
            return
        end
        if currentTarget and currentTarget.Parent and not blacklistedCoins[currentTarget] then
            noCoinsStartTime = nil
            local targetPos = currentTarget.Position
            local rootPos = rootPart.Position
            local dist = (targetPos - rootPos).Magnitude
            if dist <= 1.2 then
                rootPart.CFrame = CFrame.new(targetPos)
                stopMovement()
                hasCollectedThisLife = true
                blacklistedCoins[currentTarget] = true
                activeCoins[currentTarget] = nil
                currentTarget = nil
            else
                if linearVelocity then
                    linearVelocity.Enabled = true
                    linearVelocity.VectorVelocity = (targetPos - rootPos).Unit * TARGET_SPEED
                end
            end
        else
            stopMovement()
            if hasCollectedThisLife then
                if not noCoinsStartTime then
                    noCoinsStartTime = os.clock()
                elseif os.clock() - noCoinsStartTime >= RESET_DELAY then
                    noCoinsStartTime = nil
                    cleanupConnections()
                    humanoid.Health = 0
                end
            else
                noCoinsStartTime = nil
            end
        end
    end)
end

local function unloadScript()
    isLoaded = false
    enabled = false
    afkActive = false
    bagIsFull = false
    isWaitingForCoins = false
    cleanupConnections()
    stopNoclip()
    removeVelocity()
    if targetFinderThread then
        task.cancel(targetFinderThread)
        targetFinderThread = nil
    end
    if characterAddedConnection then
        characterAddedConnection:Disconnect()
        characterAddedConnection = nil
    end
    activeCoins = {}
    blacklistedCoins = {}
    currentTarget = nil
end

local function loadScript()
    if isLoaded then unloadScript() end
    isLoaded = true
    bagIsFull = false
    isWaitingForCoins = false
    character = player.Character or player.CharacterAdded:Wait()
    rootPart = character:WaitForChild("HumanoidRootPart")
    humanoid = character:WaitForChild("Humanoid")
    blacklistedCoins = {}
    noCoinsStartTime = nil
    hasCollectedThisLife = false
    startTargetFinder()
    startMovementEngine()
    if characterAddedConnection then characterAddedConnection:Disconnect() end
    characterAddedConnection = player.CharacterAdded:Connect(function(newChar)
        cleanupConnections()
        removeVelocity()
        character = newChar
        rootPart = character:WaitForChild("HumanoidRootPart")
        humanoid = character:WaitForChild("Humanoid")
        blacklistedCoins = {}
        noCoinsStartTime = nil
        hasCollectedThisLife = false
        bagIsFull = false
        isWaitingForCoins = false
        task.wait(1.5)
        if isLoaded and enabled then
            startMovementEngine()
        end
    end)
end

-- 3. UI
window.AddSection("Фарм")

window.AddToggle("Auto Farm", false, function(state)
    enabled = state
    if state then
        if not isLoaded then loadScript() end
        startMovementEngine()
        if afkActive then task.spawn(antiAfkLoop) end
    else
        stopMovement()
        stopNoclip()
        noCoinsStartTime = nil
    end
end)

window.AddToggle("Anti-AFK", false, function(state)
    afkActive = state
    if state and enabled then task.spawn(antiAfkLoop) end
end)

-- 4. Подготовка
loadScript()
