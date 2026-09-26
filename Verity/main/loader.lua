--[[
╔══════════════════════════════════════════════════════════════╗
║         HunterZ Hub — Verity Module v3.0                     ║
║         PlaceId: 104526416639079                             ║
║                                                              ║
║  Fixes v3.0:                                                 ║
║  • ESP: filtrar cajas fuera de pantalla correctamente        ║
║  • ESP: buscar PrimaryPart o primera BasePart del modelo     ║
║  • ESP: etiquetas con outline negro siempre visibles         ║
║  • ESP: distancia máxima configurable para no spamear        ║
║  • Farm: busca ProximityPrompt en el modelo directamente     ║
║    (no dentro de subcarpeta Main)                            ║
║  • Farm: prioridad por weight correcta                       ║
╚══════════════════════════════════════════════════════════════╝
--]]

-- ==================== NAMESPACE ====================
getgenv().HunterZ_Verity = getgenv().HunterZ_Verity or {}
local HZ = getgenv().HunterZ_Verity

HZ.Farm = HZ.Farm or { Active = false, Thread = nil }
HZ.ESP  = HZ.ESP  or { Active = false, Thread = nil, Drawings = {} }

-- ==================== SERVICIOS ====================
local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local Camera      = workspace.CurrentCamera

-- ==================== DATOS DE CAJAS ====================
-- Ordenadas por weight DESC — mayor weight = más valiosa
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

-- Lookup rápido nombre → datos
local BOX_LOOKUP = {}
for _, entry in ipairs(BOX_DATA) do
    BOX_LOOKUP[entry.name] = entry
end

-- Color por rareza
local RARITY_COLOR = {
    Common    = Color3.fromRGB(180, 180, 180),
    Uncommon  = Color3.fromRGB(80,  200, 80 ),
    Rare      = Color3.fromRGB(80,  140, 255),
    Epic      = Color3.fromRGB(180, 80,  255),
    Legendary = Color3.fromRGB(255, 160, 30 ),
    Mythic    = Color3.fromRGB(255, 60,  120),
    Secret    = Color3.fromRGB(255, 220, 50 ),
}

-- CFrame de retorno
local RETURN_CFRAME = CFrame.new(
    -120, 10.4569969, -176,
    -1, 0, 0,
     0, 1, 0,
     0, 0, -1
)

-- Tiempos (valores que funcionaron)
local RETRY_WAIT  = 3
local INSIDE_WAIT = 5
local RETURN_WAIT = 4
local PICKUP_HOLD = 1

-- Distancia máxima para mostrar en ESP (studs). Evita ruido visual de cajas lejanas.
local ESP_MAX_DIST = 500

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

-- Obtiene la BasePart raíz de un modelo (igual que getRoot del juego)
local function getRoot(model)
    if model:IsA("Model") then
        return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
    end
    return model
end

-- Formatea número con comas (65000000 → "65,000,000")
local function formatWeight(w)
    local s = tostring(math.floor(w))
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

-- World → Screen, devuelve pos2D, onScreen, depth
local function worldToScreen(pos)
    local sp, onScreen = Camera:WorldToViewportPoint(pos)
    return Vector2.new(sp.X, sp.Y), onScreen, sp.Z
end

-- ==================== FARM ====================

--[[
    Busca la caja de mayor weight disponible en workspace.Boxes.
    Busca el ProximityPrompt directamente en los descendientes del modelo
    (el juego no usa subcarpeta Main para los prompts).
    Devuelve: boxModel, rootPart, pickupPart, pickupPrompt
--]]
local function findBestBox()
    local boxesFolder = workspace:FindFirstChild("Boxes")
    if not boxesFolder then
        warn("[HunterZ/Verity] No se encontró workspace.Boxes")
        return nil, nil, nil, nil
    end

    for _, entry in ipairs(BOX_DATA) do
        -- Buscar todas las instancias de esta caja (puede haber varias en el mapa)
        -- Nos quedamos con la primera que tenga ProximityPrompt
        for _, child in ipairs(boxesFolder:GetChildren()) do
            if child.Name == entry.name and child:IsA("Model") then
                -- Verificar que no esté siendo cargada (atributo Flying)
                if child:GetAttribute("Flying") then continue end

                local rootPart = getRoot(child)
                if not rootPart then continue end

                -- Buscar ProximityPrompt en cualquier descendiente
                for _, desc in ipairs(child:GetDescendants()) do
                    if desc:IsA("ProximityPrompt") then
                        local part = desc.Parent
                        if part and part:IsA("BasePart") then
                            return child, rootPart, part, desc
                        end
                    end
                end
            end
        end
    end

    return nil, nil, nil, nil
end

local function collectBox(pickupPart, pickupPrompt)
    -- Forzar hold duration mínimo
    pcall(function() pickupPrompt.HoldDuration = PICKUP_HOLD end)

    -- Teleportar encima del part con el prompt
    teleportTo(pickupPart.CFrame + Vector3.new(0, 3, 0))
    task.wait(INSIDE_WAIT)

    -- Intentar disparar el prompt
    local fired = false
    if fireproximityprompt then
        pcall(function()
            fireproximityprompt(pickupPrompt)
            fired = true
        end)
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

local function startFarmLoop()
    if HZ.Farm.Thread then
        task.cancel(HZ.Farm.Thread)
        HZ.Farm.Thread = nil
    end

    HZ.Farm.Thread = task.spawn(function()
        print("[HunterZ/Verity] Auto Farm iniciado")

        while HZ.Farm.Active do
            local _, hrp = getCharacter()
            if not hrp then
                task.wait(RETRY_WAIT)
                continue
            end

            local boxModel, rootPart, pickupPart, pickupPrompt = findBestBox()

            if not boxModel then
                warn("[HunterZ/Verity] No hay cajas disponibles, reintentando...")
                task.wait(RETRY_WAIT)
                continue
            end

            local info = BOX_LOOKUP[boxModel.Name]
            print(string.format("[HunterZ/Verity] Farmeando: %s (weight: %s)",
                boxModel.Name,
                info and formatWeight(info.weight) or "?"))

            collectBox(pickupPart, pickupPrompt)

            if not HZ.Farm.Active then break end

            teleportTo(RETURN_CFRAME)
            task.wait(RETURN_WAIT)
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

-- ==================== ESP ====================

local function clearESP()
    for _, group in pairs(HZ.ESP.Drawings) do
        for _, d in pairs(group) do
            pcall(function() d:Remove() end)
        end
    end
    HZ.ESP.Drawings = {}
end

-- Crea un Drawing.Text con outline negro automático
local function makeText(text, size, color, pos)
    local t = Drawing.new("Text")
    t.Visible      = true
    t.Text         = text
    t.Size         = size
    t.Font         = Drawing.Fonts.GothamBold
    t.Color        = color
    t.Outline      = true
    t.OutlineColor = Color3.fromRGB(0, 0, 0)
    t.Transparency = 1
    t.Position     = pos
    return t
end

local function startESPLoop()
    if HZ.ESP.Thread then
        task.cancel(HZ.ESP.Thread)
        HZ.ESP.Thread = nil
    end

    HZ.ESP.Thread = task.spawn(function()
        print("[HunterZ/Verity] ESP Boxes iniciado")

        while HZ.ESP.Active do
            clearESP()

            local boxesFolder = workspace:FindFirstChild("Boxes")
            if not boxesFolder then
                task.wait(0.5)
                continue
            end

            local _, hrp = getCharacter()
            local vpSize       = Camera.ViewportSize
            local screenCenter = Vector2.new(vpSize.X * 0.5, vpSize.Y)  -- líneas desde abajo centro

            -- Iterar los hijos reales de workspace.Boxes
            for _, child in ipairs(boxesFolder:GetChildren()) do
                if not child:IsA("Model") then continue end

                local info = BOX_LOOKUP[child.Name]
                if not info then continue end  -- ignorar cajas legacy o desconocidas

                local rootPart = getRoot(child)
                if not rootPart then continue end

                -- Filtrar por distancia
                if hrp then
                    local dist = (rootPart.Position - hrp.Position).Magnitude
                    if dist > ESP_MAX_DIST then continue end
                end

                local worldPos            = rootPart.Position
                local screenPos, onScreen, depth = worldToScreen(worldPos)

                -- Solo dibujar si está en pantalla y delante de la cámara
                if not onScreen or depth <= 0 then continue end

                local rarity   = info.rarityType
                local weight   = info.weight
                local boxColor = RARITY_COLOR[rarity] or Color3.fromRGB(0, 255, 128)

                -- Tamaño del recuadro adaptado a la distancia
                local boxH  = math.clamp(1600 / depth, 18, 100)
                local boxW  = boxH * 0.8
                local halfW = boxW * 0.5
                local halfH = boxH * 0.5
                local topY  = screenPos.Y - halfH
                local leftX = screenPos.X - halfW

                local drawings = {}

                -- ── Outline negro ─────────────────────────────────────
                local outline = Drawing.new("Square")
                outline.Visible      = true
                outline.Filled       = false
                outline.Thickness    = 3
                outline.Color        = Color3.fromRGB(0, 0, 0)
                outline.Transparency = 1
                outline.Size         = Vector2.new(boxW + 4, boxH + 4)
                outline.Position     = Vector2.new(leftX - 2, topY - 2)
                table.insert(drawings, outline)

                -- ── Box coloreado ─────────────────────────────────────
                local box = Drawing.new("Square")
                box.Visible      = true
                box.Filled       = false
                box.Thickness    = 1.5
                box.Color        = boxColor
                box.Transparency = 1
                box.Size         = Vector2.new(boxW, boxH)
                box.Position     = Vector2.new(leftX, topY)
                table.insert(drawings, box)

                -- ── Línea desde borde inferior centro al box ──────────
                local line = Drawing.new("Line")
                line.Visible      = true
                line.Thickness    = 1
                line.Color        = boxColor
                line.Transparency = 0.5
                line.From         = screenCenter
                line.To           = screenPos
                table.insert(drawings, line)

                -- ── Etiquetas debajo del box ──────────────────────────
                local labelSize = math.clamp(math.floor(1200 / depth), 9, 15)
                local lineH     = labelSize + 2
                local labelX    = leftX
                local labelY    = topY + boxH + 4

                table.insert(drawings, makeText(
                    "[" .. child.Name .. "]",
                    labelSize,
                    boxColor,
                    Vector2.new(labelX, labelY)
                ))
                table.insert(drawings, makeText(
                    "[" .. rarity .. "]",
                    labelSize - 1,
                    Color3.fromRGB(210, 210, 210),
                    Vector2.new(labelX, labelY + lineH)
                ))
                table.insert(drawings, makeText(
                    "[Weight: " .. formatWeight(weight) .. "]",
                    labelSize - 1,
                    Color3.fromRGB(255, 210, 60),
                    Vector2.new(labelX, labelY + lineH * 2)
                ))

                -- Guardar con clave única (nombre + id de la instancia)
                HZ.ESP.Drawings[tostring(child)] = drawings
            end

            task.wait(1 / 30)  -- ~30 FPS
        end

        clearESP()
        print("[HunterZ/Verity] ESP Boxes detenido")
    end)
end

local function stopESPLoop()
    HZ.ESP.Active = false
    if HZ.ESP.Thread then
        task.cancel(HZ.ESP.Thread)
        HZ.ESP.Thread = nil
    end
    clearESP()
    print("[HunterZ/Verity] ESP Boxes OFF")
end

-- ==================== MÓDULO ====================
return {
    actions = {

        ["[Farm] Auto Farm Boxes"] = {
            toggle = true,
            fn = function(state)
                HZ.Farm.Active = (state == nil) and (not HZ.Farm.Active) or state
                if HZ.Farm.Active then startFarmLoop() else stopFarmLoop() end
            end
        },

        ["[Visual] ESP Boxes"] = {
            toggle = true,
            fn = function(state)
                HZ.ESP.Active = (state == nil) and (not HZ.ESP.Active) or state
                if HZ.ESP.Active then startESPLoop() else stopESPLoop() end
            end
        },

    }
}
