--[[
╔══════════════════════════════════════════════════════════════╗
║         HunterZ Hub — Verity Module v2.0                     ║
║         PlaceId: 104526416639079                             ║
║                                                              ║
║  Features:                                                   ║
║  • [Farm] Auto Farm Boxes — Toggle ON/OFF                    ║
║    - Busca la caja disponible con mayor weight               ║
║    - Teleporta al jugador dentro de la caja                  ║
║    - Fija HoldDuration del PickupPrompt a 1                  ║
║    - Al terminar, va a las coordenadas de retorno            ║
║    - Repite el ciclo mientras esté ON                        ║
║  • [Visual] ESP Boxes — Toggle ON/OFF                        ║
║    - Box verde por cada caja presente en el mapa             ║
║    - Línea desde el centro de pantalla hasta la caja         ║
║    - Etiqueta con nombre, rareza y weight                    ║
╚══════════════════════════════════════════════════════════════╝
--]]

-- ==================== NAMESPACE ====================
getgenv().HunterZ_Verity = getgenv().HunterZ_Verity or {}
local HZ = getgenv().HunterZ_Verity

HZ.Farm = HZ.Farm or { Active = false, Thread = nil }
HZ.ESP  = HZ.ESP  or { Active = false, Thread = nil, Drawings = {} }

-- ==================== SERVICIOS ====================
local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local Camera     = workspace.CurrentCamera

-- ==================== DATOS DE CAJAS ====================
local BOX_DATA = {
    { name = "1x1x1x1",   weight = 65000000, rarityType = "Secret"    },
    { name = "Rainbow",    weight = 20000000, rarityType = "Mythic"    },
    { name = "Heaven",     weight = 5200000,  rarityType = "Mythic"    },
    { name = "Demon",      weight = 1000000,  rarityType = "Legendary" },
    { name = "Kraken",     weight = 350000,   rarityType = "Legendary" },
    { name = "Toxic",      weight = 150000,   rarityType = "Epic"      },
    { name = "LuckyBlock", weight = 60000,    rarityType = "Epic"      },
    { name = "Neon",       weight = 25000,    rarityType = "Epic"      },
    { name = "Soccer",     weight = 10000,    rarityType = "Rare"      },
    { name = "Diamond",    weight = 5000,     rarityType = "Rare"      },
    { name = "Gold",       weight = 2200,     rarityType = "Rare"      },
    { name = "YinYang",    weight = 800,      rarityType = "Uncommon"  },
    { name = "Bamboo",     weight = 400,      rarityType = "Uncommon"  },
    { name = "Backrooms",  weight = 220,      rarityType = "Uncommon"  },
    { name = "Candy",      weight = 130,      rarityType = "Uncommon"  },
    { name = "Keyboard",   weight = 60,       rarityType = "Common"    },
    { name = "Sakura",     weight = 30,       rarityType = "Common"    },
    { name = "Cardboard",  weight = 10,       rarityType = "Common"    },
}

-- Lookup rápido por nombre
local BOX_LOOKUP = {}
for _, entry in ipairs(BOX_DATA) do
    BOX_LOOKUP[entry.name] = entry
end

-- Color por rareza para el ESP
local RARITY_COLOR = {
    Common    = Color3.fromRGB(180, 180, 180),
    Uncommon  = Color3.fromRGB(80,  200, 80 ),
    Rare      = Color3.fromRGB(80,  140, 255),
    Epic      = Color3.fromRGB(180, 80,  255),
    Legendary = Color3.fromRGB(255, 160, 30 ),
    Mythic    = Color3.fromRGB(255, 60,  120),
    Secret    = Color3.fromRGB(255, 255, 80 ),
}

-- CFrame de retorno
local RETURN_CFRAME = CFrame.new(
    -120, 10.4569969, -176,
    -1, 0, 0,
     0, 1, 0,
     0, 0, -1
)

-- Tiempos
local RETRY_WAIT  = 2
local INSIDE_WAIT = 5
local RETURN_WAIT = 3.5
local PICKUP_HOLD = 1

-- ==================== UTILIDADES ====================

local function getCharacter()
    local char = LocalPlayer.Character
    if not char then return nil, nil end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then return nil, nil end
    return char, hrp
end

local function teleportTo(cf)
    local _, hrp = getCharacter()
    if hrp then hrp.CFrame = cf end
end

local function findBestBox()
    local boxesFolder = workspace:FindFirstChild("Boxes")
    if not boxesFolder then
        warn("[HunterZ/Verity] No se encontró workspace.Boxes")
        return nil, nil, nil, nil
    end
    for _, entry in ipairs(BOX_DATA) do
        local boxModel = boxesFolder:FindFirstChild(entry.name)
        if boxModel then
            local mainModel = boxModel:FindFirstChild("Main")
            if mainModel then
                for _, child in ipairs(mainModel:GetDescendants()) do
                    if child:IsA("ProximityPrompt") then
                        local part = child.Parent
                        if part and part:IsA("BasePart") then
                            return boxModel, mainModel, part, child
                        end
                    end
                end
            end
        end
    end
    return nil, nil, nil, nil
end

local function collectBox(pickupPart, pickupPrompt)
    pcall(function() pickupPrompt.HoldDuration = PICKUP_HOLD end)
    teleportTo(pickupPart.CFrame + Vector3.new(0, 2, 0))
    task.wait(INSIDE_WAIT)
    local fired = false
    if fireproximityprompt then
        pcall(function() fireproximityprompt(pickupPrompt); fired = true end)
    end
    if not fired and firetouchinterest then
        local _, hrp = getCharacter()
        if hrp then
            pcall(function() firetouchinterest(hrp, pickupPart, 0) end)
            task.wait(0.05)
            pcall(function() firetouchinterest(hrp, pickupPart, 1) end)
        end
    end
    task.wait(0.1)
end

-- ==================== FARM LOOP ====================

local function startFarmLoop()
    if HZ.Farm.Thread then
        task.cancel(HZ.Farm.Thread)
        HZ.Farm.Thread = nil
    end
    HZ.Farm.Thread = task.spawn(function()
        print("[HunterZ/Verity] Auto Farm iniciado")
        while HZ.Farm.Active do
            local _, hrp = getCharacter()
            if not hrp then task.wait(RETRY_WAIT); continue end

            local boxModel, _, pickupPart, pickupPrompt = findBestBox()
            if not boxModel then
                warn("[HunterZ/Verity] No hay cajas disponibles, reintentando...")
                task.wait(RETRY_WAIT)
                continue
            end

            print(string.format("[HunterZ/Verity] Farmeando: %s", boxModel.Name))
            collectBox(pickupPart, pickupPrompt)
            if not HZ.Farm.Active then break end
            teleportTo(RETURN_CFRAME)
            task.wait(RETURN_WAIT)
            task.wait(0.2)
        end
        print("[HunterZ/Verity] Auto Farm detenido")
    end)
end

local function stopFarmLoop()
    HZ.Farm.Active = false
    if HZ.Farm.Thread then
        task.cancel(HZ.Farm.Thread)
        HZ.Farm.Thread = nil
    end
    print("[HunterZ/Verity] Auto Farm OFF")
end

-- ==================== ESP BOXES ====================

-- Limpia todos los drawings del ESP
local function clearESPDrawings()
    for key, group in pairs(HZ.ESP.Drawings) do
        for _, d in pairs(group) do
            pcall(function() d:Remove() end)
        end
    end
    HZ.ESP.Drawings = {}
end

-- Convierte posición 3D a pantalla
local function worldToScreen(pos)
    local screenPos, onScreen = Camera:WorldToViewportPoint(pos)
    return Vector2.new(screenPos.X, screenPos.Y), onScreen, screenPos.Z
end

-- Formatea el weight con separadores de miles  (65000000 → "65,000,000")
local function formatWeight(w)
    local s = tostring(w)
    local result = ""
    local len = #s
    for i = 1, len do
        if i > 1 and (len - i + 1) % 3 == 0 then
            result = result .. ","
        end
        result = result .. s:sub(i, i)
    end
    return result
end

local function startESPLoop()
    if HZ.ESP.Thread then
        task.cancel(HZ.ESP.Thread)
        HZ.ESP.Thread = nil
    end

    HZ.ESP.Thread = task.spawn(function()
        print("[HunterZ/Verity] ESP Boxes iniciado")

        while HZ.ESP.Active do
            -- Limpiar drawings del frame anterior
            clearESPDrawings()

            local boxesFolder = workspace:FindFirstChild("Boxes")
            if not boxesFolder then
                task.wait(0.5)
                continue
            end

            -- Centro de la pantalla para las líneas
            local vpSize      = Camera.ViewportSize
            local screenCenter = Vector2.new(vpSize.X / 2, vpSize.Y / 2)

            for _, entry in ipairs(BOX_DATA) do
                local boxModel = boxesFolder:FindFirstChild(entry.name)
                if not boxModel then continue end

                -- Obtener posición del modelo (PrimaryPart o primera BasePart)
                local rootPart = boxModel.PrimaryPart
                if not rootPart then
                    for _, d in ipairs(boxModel:GetDescendants()) do
                        if d:IsA("BasePart") then rootPart = d; break end
                    end
                end
                if not rootPart then continue end

                local worldPos          = rootPart.Position
                local screenPos, onScreen, depth = worldToScreen(worldPos)

                -- Solo dibujar si está en pantalla y delante de la cámara
                if not onScreen or depth <= 0 then continue end

                local boxInfo  = BOX_LOOKUP[entry.name]
                local rarity   = boxInfo and boxInfo.rarityType or "Common"
                local weight   = boxInfo and boxInfo.weight     or 0
                local boxColor = RARITY_COLOR[rarity] or Color3.fromRGB(0, 255, 128)

                -- Tamaño del recuadro (se hace más pequeño a más distancia)
                local boxSize = math.clamp(2000 / depth, 20, 120)
                local halfW   = boxSize * 0.5
                local halfH   = boxSize * 0.6

                local drawings = {}

                -- ── Outline (negro, más grueso) ──────────────────────
                local outline = Drawing.new("Square")
                outline.Visible      = true
                outline.Filled       = false
                outline.Thickness    = 3
                outline.Color        = Color3.fromRGB(0, 0, 0)
                outline.Transparency = 1
                outline.Size         = Vector2.new(boxSize + 4, boxSize * 1.2 + 4)
                outline.Position     = Vector2.new(screenPos.X - halfW - 2, screenPos.Y - halfH - 2)
                table.insert(drawings, outline)

                -- ── Box principal (color por rareza) ─────────────────
                local box = Drawing.new("Square")
                box.Visible      = true
                box.Filled       = false
                box.Thickness    = 1.5
                box.Color        = boxColor
                box.Transparency = 1
                box.Size         = Vector2.new(boxSize, boxSize * 1.2)
                box.Position     = Vector2.new(screenPos.X - halfW, screenPos.Y - halfH)
                table.insert(drawings, box)

                -- ── Línea desde centro de pantalla hasta la caja ─────
                local line = Drawing.new("Line")
                line.Visible      = true
                line.Thickness    = 1
                line.Color        = boxColor
                line.Transparency = 0.4
                line.From         = screenCenter
                line.To           = screenPos
                table.insert(drawings, line)

                -- ── Etiqueta: nombre ──────────────────────────────────
                local lblName = Drawing.new("Text")
                lblName.Visible      = true
                lblName.Text         = "[" .. entry.name .. "]"
                lblName.Size         = math.clamp(13 * (200 / math.max(depth, 1)), 9, 16)
                lblName.Font         = Drawing.Fonts.GothamBold
                lblName.Color        = boxColor
                lblName.Outline      = true
                lblName.OutlineColor = Color3.fromRGB(0, 0, 0)
                lblName.Transparency = 1
                lblName.Position     = Vector2.new(screenPos.X - halfW, screenPos.Y + halfH + 2)
                table.insert(drawings, lblName)

                -- ── Etiqueta: rareza ──────────────────────────────────
                local lblRarity = Drawing.new("Text")
                lblRarity.Visible      = true
                lblRarity.Text         = "[" .. rarity .. "]"
                lblRarity.Size         = lblName.Size - 1
                lblRarity.Font         = Drawing.Fonts.Gotham
                lblRarity.Color        = Color3.fromRGB(200, 200, 200)
                lblRarity.Outline      = true
                lblRarity.OutlineColor = Color3.fromRGB(0, 0, 0)
                lblRarity.Transparency = 1
                lblRarity.Position     = Vector2.new(screenPos.X - halfW, screenPos.Y + halfH + 2 + lblName.Size + 1)
                table.insert(drawings, lblRarity)

                -- ── Etiqueta: weight ──────────────────────────────────
                local lblWeight = Drawing.new("Text")
                lblWeight.Visible      = true
                lblWeight.Text         = "[Weight: " .. formatWeight(weight) .. "]"
                lblWeight.Size         = lblName.Size - 1
                lblWeight.Font         = Drawing.Fonts.Gotham
                lblWeight.Color        = Color3.fromRGB(255, 210, 60)
                lblWeight.Outline      = true
                lblWeight.OutlineColor = Color3.fromRGB(0, 0, 0)
                lblWeight.Transparency = 1
                lblWeight.Position     = Vector2.new(screenPos.X - halfW, screenPos.Y + halfH + 2 + (lblName.Size + 1) * 2)
                table.insert(drawings, lblWeight)

                -- Guardar drawings de esta caja para limpiarlos en el próximo frame
                HZ.ESP.Drawings[entry.name] = drawings
            end

            -- ~30 FPS para el ESP (suficiente y eficiente)
            task.wait(1 / 30)
        end

        clearESPDrawings()
        print("[HunterZ/Verity] ESP Boxes detenido")
    end)
end

local function stopESPLoop()
    HZ.ESP.Active = false
    if HZ.ESP.Thread then
        task.cancel(HZ.ESP.Thread)
        HZ.ESP.Thread = nil
    end
    clearESPDrawings()
    print("[HunterZ/Verity] ESP Boxes OFF")
end

-- ==================== MÓDULO ====================
return {
    actions = {

        ["[Farm] Auto Farm Boxes"] = {
            toggle = true,
            fn = function(state)
                if state == nil then
                    HZ.Farm.Active = not HZ.Farm.Active
                else
                    HZ.Farm.Active = state
                end
                if HZ.Farm.Active then startFarmLoop() else stopFarmLoop() end
            end
        },

        ["[Visual] ESP Boxes"] = {
            toggle = true,
            fn = function(state)
                if state == nil then
                    HZ.ESP.Active = not HZ.ESP.Active
                else
                    HZ.ESP.Active = state
                end
                if HZ.ESP.Active then startESPLoop() else stopESPLoop() end
            end
        },

    }
}
