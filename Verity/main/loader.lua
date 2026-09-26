--[[
╔══════════════════════════════════════════════════════════════╗
║         HunterZ Hub — Verity Module v4.0                     ║
║         PlaceId: 104526416639079                             ║
║                                                              ║
║  Fixes v4.0:                                                 ║
║  • ESP: Drawing.Fonts.GothamBold NO EXISTE en la API Drawing ║
║    (solo UI/System/Plex/Monospace) — causaba que el hilo     ║
║    del ESP truene a mitad de camino y dejara recuadros       ║
║    pegados en pantalla para siempre. Corregido.              ║
║  • ESP: cada Drawing se registra en la tabla de limpieza      ║
║    INMEDIATAMENTE al crearse, y todo el bloque por caja va    ║
║    envuelto en pcall — un error nunca deja basura huérfana   ║
║  • ESP: búsqueda por GetDescendants (soporta que las cajas    ║
║    estén dentro de subcarpetas, no solo hijos directos)       ║
║  • Farm: búsqueda también por GetDescendants                 ║
║  • Farm: ignora ProximityPrompt.Enabled == false (caja aún    ║
║    en animación de entrada) y cae correctamente a la          ║
║    siguiente mejor disponible — así SIEMPRE prioriza la de    ║
║    mayor weight que esté realmente lista para recoger         ║
║  • Farm: log claro de qué caja eligió y por qué               ║
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
-- Ordenadas por weight DESC — mayor weight = más valiosa = mayor prioridad
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

local BOX_LOOKUP = {}
for _, entry in ipairs(BOX_DATA) do
    BOX_LOOKUP[entry.name] = entry
end

local RARITY_COLOR = {
    Common    = Color3.fromRGB(180, 180, 180),
    Uncommon  = Color3.fromRGB(80,  200, 80 ),
    Rare      = Color3.fromRGB(80,  140, 255),
    Epic      = Color3.fromRGB(180, 80,  255),
    Legendary = Color3.fromRGB(255, 160, 30 ),
    Mythic    = Color3.fromRGB(255, 60,  120),
    Secret    = Color3.fromRGB(255, 220, 50 ),
}

-- Fuentes VÁLIDAS de la API Drawing (GothamBold/Gotham NO EXISTEN y rompían el ESP)
local FONT_MAIN = Drawing.Fonts.System
local FONT_SUB  = Drawing.Fonts.UI

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

-- Distancia máxima para el ESP (studs)
local ESP_MAX_DIST = 2500

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

local function getRoot(model)
    if model:IsA("Model") then
        return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
    end
    return model
end

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

local function worldToScreen(pos)
    local sp, onScreen = Camera:WorldToViewportPoint(pos)
    return Vector2.new(sp.X, sp.Y), onScreen, sp.Z
end

--[[
    Recorre TODOS los descendientes de workspace.Boxes (soporta
    tanto estructura plana como carpetas anidadas por tipo/jugador)
    y devuelve una lista de { model, weight, rarityType, prompt, part }
    de cada caja de tipo conocido que exista ahora mismo en el mapa.
--]]
local function scanAllBoxes()
    local boxesFolder = workspace:FindFirstChild("Boxes")
    if not boxesFolder then return {} end

    local found = {}
    for _, obj in ipairs(boxesFolder:GetDescendants()) do
        if obj:IsA("Model") then
            local info = BOX_LOOKUP[obj.Name]
            if info then
                table.insert(found, { model = obj, info = info })
            end
        end
    end
    return found
end

-- ==================== FARM ====================

--[[
    Elige la mejor caja EN CONDICIONES DE SER RECOGIDA AHORA MISMO:
    - Debe existir en el mapa
    - No debe estar en animación de entrada (atributo Flying)
    - Debe tener un ProximityPrompt habilitado (Enabled == true)
    Entre todas las que cumplen, se queda con la de mayor weight.
--]]
local function findBestBox()
    local candidates = scanAllBoxes()
    if #candidates == 0 then return nil, nil, nil end

    -- Ordenar candidatas por weight descendente
    table.sort(candidates, function(a, b) return a.info.weight > b.info.weight end)

    for _, c in ipairs(candidates) do
        local model = c.model
        if model.Parent and not model:GetAttribute("Flying") then
            for _, desc in ipairs(model:GetDescendants()) do
                if desc:IsA("ProximityPrompt") and desc.Enabled then
                    local part = desc.Parent
                    if part and part:IsA("BasePart") then
                        return model, part, desc
                    end
                end
            end
        end
    end

    return nil, nil, nil
end

local function collectBox(pickupPart, pickupPrompt)
    pcall(function() pickupPrompt.HoldDuration = PICKUP_HOLD end)

    teleportTo(pickupPart.CFrame + Vector3.new(0, 3, 0))
    task.wait(INSIDE_WAIT)

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

            local boxModel, pickupPart, pickupPrompt = findBestBox()

            if not boxModel then
                warn("[HunterZ/Verity] No hay cajas listas para recoger, reintentando...")
                task.wait(RETRY_WAIT)
                continue
            end

            local info = BOX_LOOKUP[boxModel.Name]
            print(string.format("[HunterZ/Verity] >> Prioridad: %s | Weight: %s | Rareza: %s",
                boxModel.Name,
                info and formatWeight(info.weight) or "?",
                info and info.rarityType or "?"))

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

-- Crea un Drawing y lo agrega INMEDIATAMENTE a bucket para que
-- clearESP() siempre pueda encontrarlo, incluso si algo falla después.
local function trackedDrawing(class, bucket)
    local d = Drawing.new(class)
    table.insert(bucket, d)
    return d
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

            local boxes = scanAllBoxes()
            local _, hrp = getCharacter()
            local vpSize       = Camera.ViewportSize
            local screenCenter = Vector2.new(vpSize.X * 0.5, vpSize.Y)

            for _, c in ipairs(boxes) do
                local model = c.model
                local info  = c.info

                -- Todo el trabajo de UNA caja va protegido: si algo falla,
                -- no rompe el resto del ESP ni deja basura sin registrar.
                pcall(function()
                    if not model.Parent then return end

                    local rootPart = getRoot(model)
                    if not rootPart then return end

                    if hrp then
                        local dist = (rootPart.Position - hrp.Position).Magnitude
                        if dist > ESP_MAX_DIST then return end
                    end

                    local worldPos = rootPart.Position
                    local screenPos, onScreen, depth = worldToScreen(worldPos)
                    if not onScreen or depth <= 1 then return end

                    local rarity   = info.rarityType
                    local weight   = info.weight
                    local boxColor = RARITY_COLOR[rarity] or Color3.fromRGB(0, 255, 128)

                    local boxH  = math.clamp(1600 / depth, 18, 100)
                    local boxW  = boxH * 0.8
                    local halfW = boxW * 0.5
                    local halfH = boxH * 0.5
                    local topY  = screenPos.Y - halfH
                    local leftX = screenPos.X - halfW

                    -- Bucket propio de esta caja: se registra en HZ.ESP.Drawings
                    -- ANTES de dibujar nada más, así siempre es limpiable.
                    local bucket = {}
                    HZ.ESP.Drawings[tostring(model)] = bucket

                    -- Outline negro
                    local outline = trackedDrawing("Square", bucket)
                    outline.Visible      = true
                    outline.Filled       = false
                    outline.Thickness    = 3
                    outline.Color        = Color3.fromRGB(0, 0, 0)
                    outline.Transparency = 1
                    outline.Size         = Vector2.new(boxW + 4, boxH + 4)
                    outline.Position     = Vector2.new(leftX - 2, topY - 2)

                    -- Box coloreado
                    local box = trackedDrawing("Square", bucket)
                    box.Visible      = true
                    box.Filled       = false
                    box.Thickness    = 1.5
                    box.Color        = boxColor
                    box.Transparency = 1
                    box.Size         = Vector2.new(boxW, boxH)
                    box.Position     = Vector2.new(leftX, topY)

                    -- Línea desde abajo-centro de pantalla
                    local line = trackedDrawing("Line", bucket)
                    line.Visible      = true
                    line.Thickness    = 1
                    line.Color        = boxColor
                    line.Transparency = 0.5
                    line.From         = screenCenter
                    line.To           = screenPos

                    -- Etiquetas
                    local labelSize = math.clamp(math.floor(1200 / depth), 9, 15)
                    local lineH     = labelSize + 3
                    local labelX    = leftX
                    local labelY    = topY + boxH + 4

                    local lblName = trackedDrawing("Text", bucket)
                    lblName.Visible      = true
                    lblName.Text         = "[" .. model.Name .. "]"
                    lblName.Size         = labelSize
                    lblName.Font         = FONT_MAIN
                    lblName.Color        = boxColor
                    lblName.Outline      = true
                    lblName.OutlineColor = Color3.fromRGB(0, 0, 0)
                    lblName.Transparency = 1
                    lblName.Center       = false
                    lblName.Position     = Vector2.new(labelX, labelY)

                    local lblRarity = trackedDrawing("Text", bucket)
                    lblRarity.Visible      = true
                    lblRarity.Text         = "[" .. rarity .. "]"
                    lblRarity.Size         = labelSize - 1
                    lblRarity.Font         = FONT_SUB
                    lblRarity.Color        = Color3.fromRGB(210, 210, 210)
                    lblRarity.Outline      = true
                    lblRarity.OutlineColor = Color3.fromRGB(0, 0, 0)
                    lblRarity.Transparency = 1
                    lblRarity.Center       = false
                    lblRarity.Position     = Vector2.new(labelX, labelY + lineH)

                    local lblWeight = trackedDrawing("Text", bucket)
                    lblWeight.Visible      = true
                    lblWeight.Text         = "[Weight: " .. formatWeight(weight) .. "]"
                    lblWeight.Size         = labelSize - 1
                    lblWeight.Font         = FONT_SUB
                    lblWeight.Color        = Color3.fromRGB(255, 210, 60)
                    lblWeight.Outline      = true
                    lblWeight.OutlineColor = Color3.fromRGB(0, 0, 0)
                    lblWeight.Transparency = 1
                    lblWeight.Center       = false
                    lblWeight.Position     = Vector2.new(labelX, labelY + lineH * 2)
                end)
            end

            task.wait(1 / 30)
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
