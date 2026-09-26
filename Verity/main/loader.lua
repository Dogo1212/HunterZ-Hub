--[[
╔══════════════════════════════════════════════════════════════╗
║         HunterZ Hub — Verity Module v4.1                   ║
║         PlaceId: 104526416639079                            ║
║                                                              ║
║  Cambios v4.1:                                               ║
║  • ESP: reutiliza los Drawing existentes en vez de           ║
║    destruirlos y crearlos en cada actualización.             ║
║  • ESP: los recuadros siguen actualizándose al moverte.      ║
║  • ESP: solo elimina Drawing cuando una caja desaparece.     ║
║  • Farm: espera 1.5 segundos después de recoger una caja     ║
║    antes de regresar a RETURN_CFRAME.                       ║
║  • Se mantiene la búsqueda mediante GetDescendants.         ║
║  • Se mantiene la prioridad por Weight.                      ║
╚══════════════════════════════════════════════════════════════╝
--]]

-- ==================== NAMESPACE ====================

getgenv().HunterZ_Verity = getgenv().HunterZ_Verity or {}

local HZ = getgenv().HunterZ_Verity

HZ.Farm = HZ.Farm or {
    Active = false,
    Thread = nil
}

HZ.ESP = HZ.ESP or {
    Active = false,
    Thread = nil,
    Drawings = {}
}


-- ==================== SERVICIOS ====================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera


-- ==================== DATOS DE CAJAS ====================

-- Ordenadas por weight DESC
-- mayor weight = mayor prioridad

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


-- ==================== COLORES ====================

local RARITY_COLOR = {
    Common    = Color3.fromRGB(180, 180, 180),
    Uncommon  = Color3.fromRGB(80,  200, 80),
    Rare      = Color3.fromRGB(80,  140, 255),
    Epic      = Color3.fromRGB(180, 80,  255),
    Legendary = Color3.fromRGB(255, 160, 30),
    Mythic    = Color3.fromRGB(255, 60,  120),
    Secret    = Color3.fromRGB(255, 220, 50),
}


-- ==================== FUENTES DRAWING ====================

local FONT_MAIN = Drawing.Fonts.System
local FONT_SUB = Drawing.Fonts.UI


-- ==================== POSICIÓN DE RETORNO ====================

local RETURN_CFRAME = CFrame.new(
    -120,
    10.4569969,
    -176,
    -1, 0, 0,
     0, 1, 0,
     0, 0, -1
)


-- ==================== TIEMPOS ====================

local RETRY_WAIT = 2
local INSIDE_WAIT = 5
local RETURN_WAIT = 3.5
local PICKUP_HOLD = 1

-- Espera adicional después de recoger
local AFTER_PICKUP_WAIT = 1.5


-- ==================== ESP ====================

local ESP_MAX_DIST = 2500

-- Actualizaciones por segundo
local ESP_UPDATE_RATE = 1 / 30


-- ==================== UTILIDADES ====================

local function getCharacter()
    local char = LocalPlayer.Character

    if not char then
        return nil, nil
    end

    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")

    if not hrp or not hum or hum.Health <= 0 then
        return nil, nil
    end

    return char, hrp
end


local function teleportTo(cf)
    local _, hrp = getCharacter()

    if hrp then
        hrp.CFrame = cf
    end
end


local function getRoot(model)
    if model:IsA("Model") then
        return model.PrimaryPart
            or model:FindFirstChildWhichIsA("BasePart", true)
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


-- ==================== BUSCAR CAJAS ====================

local function scanAllBoxes()
    local boxesFolder = workspace:FindFirstChild("Boxes")

    if not boxesFolder then
        return {}
    end

    local found = {}

    for _, obj in ipairs(boxesFolder:GetDescendants()) do
        if obj:IsA("Model") then
            local info = BOX_LOOKUP[obj.Name]

            if info then
                table.insert(found, {
                    model = obj,
                    info = info
                })
            end
        end
    end

    return found
end


-- ==================== FARM ====================

local function findBestBox()
    local candidates = scanAllBoxes()

    if #candidates == 0 then
        return nil, nil, nil
    end

    -- Mayor Weight primero
    table.sort(candidates, function(a, b)
        return a.info.weight > b.info.weight
    end)


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


-- ==================== RECOGER CAJA ====================

local function collectBox(pickupPart, pickupPrompt)

    pcall(function()
        pickupPrompt.HoldDuration = PICKUP_HOLD
    end)


    -- Teletransportarse a la caja
    teleportTo(
        pickupPart.CFrame + Vector3.new(0, 3, 0)
    )


    -- Esperar dentro
    task.wait(INSIDE_WAIT)


    local fired = false


    -- ProximityPrompt
    if fireproximityprompt then

        pcall(function()
            fireproximityprompt(pickupPrompt)
            fired = true
        end)

    end


    -- Fallback touch
    if not fired and firetouchinterest then

        local _, hrp = getCharacter()

        if hrp then

            pcall(function()
                firetouchinterest(
                    hrp,
                    pickupPart,
                    0
                )
            end)


            task.wait(0.05)


            pcall(function()
                firetouchinterest(
                    hrp,
                    pickupPart,
                    1
                )
            end)

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


            if not hrp then

                task.wait(RETRY_WAIT)

                continue

            end


            local boxModel, pickupPart, pickupPrompt =
                findBestBox()


            if not boxModel then

                warn(
                    "[HunterZ/Verity] No hay cajas listas para recoger, reintentando..."
                )

                task.wait(RETRY_WAIT)

                continue

            end


            local info = BOX_LOOKUP[boxModel.Name]


            print(
                string.format(
                    "[HunterZ/Verity] >> Prioridad: %s | Weight: %s | Rareza: %s",
                    boxModel.Name,
                    info and formatWeight(info.weight) or "?",
                    info and info.rarityType or "?"
                )
            )


            -- Recoger
            collectBox(
                pickupPart,
                pickupPrompt
            )


            if not HZ.Farm.Active then
                break
            end


            -- =================================================
            -- NUEVO:
            -- Esperar 1.5 segundos antes de regresar
            -- =================================================

            task.wait(AFTER_PICKUP_WAIT)


            if not HZ.Farm.Active then
                break
            end


            -- Regresar
            teleportTo(
                RETURN_CFRAME
            )


            task.wait(RETURN_WAIT)

        end


        print("[HunterZ/Verity] Auto Farm detenido")

    end)

end


-- ==================== STOP FARM ====================

local function stopFarmLoop()

    HZ.Farm.Active = false


    if HZ.Farm.Thread then

        task.cancel(HZ.Farm.Thread)

        HZ.Farm.Thread = nil

    end


    print("[HunterZ/Verity] Auto Farm OFF")

end


-- ============================================================
--                         ESP
-- ============================================================


-- ==================== LIMPIAR ESP ====================

local function clearESP()

    for _, bucket in pairs(HZ.ESP.Drawings) do

        if type(bucket) == "table" then

            for _, drawing in ipairs(bucket) do

                pcall(function()
                    drawing:Remove()
                end)

            end

        end

    end


    HZ.ESP.Drawings = {}

end


-- ==================== CREAR DRAWING ====================

local function trackedDrawing(class, bucket)

    local d = Drawing.new(class)

    table.insert(
        bucket,
        d
    )

    return d

end


-- ==================== CREAR BUCKET ====================

local function createESPBucket()

    local bucket = {}


    -- 1 = outline
    local outline = trackedDrawing(
        "Square",
        bucket
    )


    -- 2 = box
    local box = trackedDrawing(
        "Square",
        bucket
    )


    -- 3 = line
    local line = trackedDrawing(
        "Line",
        bucket
    )


    -- 4 = name
    local lblName = trackedDrawing(
        "Text",
        bucket
    )


    -- 5 = rarity
    local lblRarity = trackedDrawing(
        "Text",
        bucket
    )


    -- 6 = weight
    local lblWeight = trackedDrawing(
        "Text",
        bucket
    )


    -- ==================== CONFIGURACIÓN ====================

    -- Outline

    outline.Visible = false
    outline.Filled = false
    outline.Thickness = 3
    outline.Transparency = 1
    outline.Color = Color3.fromRGB(
        0,
        0,
        0
    )


    -- Box

    box.Visible = false
    box.Filled = false
    box.Thickness = 1.5
    box.Transparency = 1


    -- Línea

    line.Visible = false
    line.Thickness = 1
    line.Transparency = 0.5


    -- Nombre

    lblName.Visible = false
    lblName.Font = FONT_MAIN
    lblName.Outline = true
    lblName.OutlineColor = Color3.fromRGB(
        0,
        0,
        0
    )
    lblName.Transparency = 1
    lblName.Center = false


    -- Rareza

    lblRarity.Visible = false
    lblRarity.Font = FONT_SUB
    lblRarity.Outline = true
    lblRarity.OutlineColor = Color3.fromRGB(
        0,
        0,
        0
    )
    lblRarity.Transparency = 1
    lblRarity.Center = false


    -- Weight

    lblWeight.Visible = false
    lblWeight.Font = FONT_SUB
    lblWeight.Outline = true
    lblWeight.OutlineColor = Color3.fromRGB(
        0,
        0,
        0
    )
    lblWeight.Transparency = 1
    lblWeight.Center = false


    return bucket

end


-- ============================================================
--                      ESP LOOP
-- ============================================================

local function startESPLoop()

    -- Evitar dos loops
    if HZ.ESP.Thread then

        task.cancel(
            HZ.ESP.Thread
        )

        HZ.ESP.Thread = nil

    end


    HZ.ESP.Thread = task.spawn(function()

        print(
            "[HunterZ/Verity] ESP Boxes iniciado"
        )


        while HZ.ESP.Active do

            -- Cámara actual
            Camera = workspace.CurrentCamera


            if not Camera then

                task.wait(
                    ESP_UPDATE_RATE
                )

                continue

            end


            -- Obtener cajas actuales
            local boxes = scanAllBoxes()


            -- Jugador
            local _, hrp = getCharacter()


            -- Pantalla
            local vpSize =
                Camera.ViewportSize


            local screenCenter =
                Vector2.new(
                    vpSize.X * 0.5,
                    vpSize.Y
                )


            -- Lista para saber cuáles siguen existiendo
            local activeModels = {}


            -- =================================================
            -- ACTUALIZAR CAJAS
            -- =================================================

            for _, c in ipairs(boxes) do

                local model = c.model
                local info = c.info


                activeModels[model] = true


                pcall(function()

                    if not model.Parent then
                        return
                    end


                    -- Root
                    local rootPart =
                        getRoot(model)


                    if not rootPart then
                        return
                    end


                    -- =================================================
                    -- Crear Drawing SOLO si todavía no existe
                    -- =================================================

                    local bucket =
                        HZ.ESP.Drawings[model]


                    if not bucket then

                        bucket =
                            createESPBucket()


                        HZ.ESP.Drawings[model] =
                            bucket

                    end


                    -- Obtener dibujos

                    local outline =
                        bucket[1]

                    local box =
                        bucket[2]

                    local line =
                        bucket[3]

                    local lblName =
                        bucket[4]

                    local lblRarity =
                        bucket[5]

                    local lblWeight =
                        bucket[6]


                    -- Ocultar antes de comprobar
                    outline.Visible = false
                    box.Visible = false
                    line.Visible = false
                    lblName.Visible = false
                    lblRarity.Visible = false
                    lblWeight.Visible = false


                    -- =================================================
                    -- DISTANCIA
                    -- =================================================

                    if hrp then

                        local dist =
                            (
                                rootPart.Position
                                - hrp.Position
                            ).Magnitude


                        if dist > ESP_MAX_DIST then
                            return
                        end

                    end


                    -- =================================================
                    -- WORLD TO SCREEN
                    -- =================================================

                    local worldPos =
                        rootPart.Position


                    local screenVector,
                          onScreen =
                        Camera:WorldToViewportPoint(
                            worldPos
                        )


                    local screenPos =
                        Vector2.new(
                            screenVector.X,
                            screenVector.Y
                        )


                    local depth =
                        screenVector.Z


                    if not onScreen
                        or depth <= 1 then

                        return

                    end


                    -- =================================================
                    -- DATOS
                    -- =================================================

                    local rarity =
                        info.rarityType


                    local weight =
                        info.weight


                    local boxColor =
                        RARITY_COLOR[rarity]
                        or Color3.fromRGB(
                            0,
                            255,
                            128
                        )


                    -- =================================================
                    -- TAMAÑO DEL BOX
                    -- =================================================

                    local boxH =
                        math.clamp(
                            1600 / depth,
                            18,
                            100
                        )


                    local boxW =
                        boxH * 0.8


                    local halfW =
                        boxW * 0.5


                    local halfH =
                        boxH * 0.5


                    local topY =
                        screenPos.Y - halfH


                    local leftX =
                        screenPos.X - halfW


                    -- =================================================
                    -- OUTLINE
                    -- =================================================

                    outline.Visible = true

                    outline.Size =
                        Vector2.new(
                            boxW + 4,
                            boxH + 4
                        )

                    outline.Position =
                        Vector2.new(
                            leftX - 2,
                            topY - 2
                        )


                    -- =================================================
                    -- BOX
                    -- =================================================

                    box.Visible = true

                    box.Color =
                        boxColor

                    box.Size =
                        Vector2.new(
                            boxW,
                            boxH
                        )

                    box.Position =
                        Vector2.new(
                            leftX,
                            topY
                        )


                    -- =================================================
                    -- LÍNEA
                    -- =================================================

                    line.Visible = true

                    line.Color =
                        boxColor

                    line.From =
                        screenCenter

                    line.To =
                        screenPos


                    -- =================================================
                    -- TEXTO
                    -- =================================================

                    local labelSize =
                        math.clamp(
                            math.floor(
                                1200 / depth
                            ),
                            9,
                            15
                        )


                    local lineH =
                        labelSize + 3


                    local labelX =
                        leftX


                    local labelY =
                        topY + boxH + 4


                    -- Nombre

                    lblName.Visible = true

                    lblName.Text =
                        "[" .. model.Name .. "]"

                    lblName.Size =
                        labelSize

                    lblName.Color =
                        boxColor

                    lblName.Position =
                        Vector2.new(
                            labelX,
                            labelY
                        )


                    -- Rareza

                    lblRarity.Visible = true

                    lblRarity.Text =
                        "[" .. rarity .. "]"

                    lblRarity.Size =
                        labelSize - 1

                    lblRarity.Color =
                        Color3.fromRGB(
                            210,
                            210,
                            210
                        )

                    lblRarity.Position =
                        Vector2.new(
                            labelX,
                            labelY + lineH
                        )


                    -- Weight

                    lblWeight.Visible = true

                    lblWeight.Text =
                        "[Weight: "
                        .. formatWeight(weight)
                        .. "]"

                    lblWeight.Size =
                        labelSize - 1

                    lblWeight.Color =
                        Color3.fromRGB(
                            255,
                            210,
                            60
                        )

                    lblWeight.Position =
                        Vector2.new(
                            labelX,
                            labelY + lineH * 2
                        )

                end)

            end


            -- =================================================
            -- ELIMINAR SOLO CAJAS QUE YA NO EXISTEN
            -- =================================================

            for model, bucket in pairs(
                HZ.ESP.Drawings
            ) do

                if not activeModels[model]
                    or not model.Parent then


                    for _, drawing in ipairs(
                        bucket
                    ) do

                        pcall(function()
                            drawing:Remove()
                        end)

                    end


                    HZ.ESP.Drawings[model] =
                        nil

                end

            end


            -- =================================================
            -- ESP UPDATE
            -- =================================================

            task.wait(
                ESP_UPDATE_RATE
            )

        end


        -- Al apagar el ESP
        clearESP()


        print(
            "[HunterZ/Verity] ESP Boxes detenido"
        )

    end)

end


-- ==================== STOP ESP ====================

local function stopESPLoop()

    HZ.ESP.Active = false


    if HZ.ESP.Thread then

        task.cancel(
            HZ.ESP.Thread
        )

        HZ.ESP.Thread = nil

    end


    clearESP()


    print(
        "[HunterZ/Verity] ESP Boxes OFF"
    )

end


-- ============================================================
--                         MÓDULO
-- ============================================================

return {

    actions = {

        -- =====================================================
        -- AUTO FARM
        -- =====================================================

        ["[Farm] Auto Farm Boxes"] = {

            toggle = true,

            fn = function(state)

                HZ.Farm.Active =
                    (state == nil)
                    and (not HZ.Farm.Active)
                    or state


                if HZ.Farm.Active then

                    startFarmLoop()

                else

                    stopFarmLoop()

                end

            end

        },


        -- =====================================================
        -- ESP
        -- =====================================================

        ["[Visual] ESP Boxes"] = {

            toggle = true,

            fn = function(state)

                HZ.ESP.Active =
                    (state == nil)
                    and (not HZ.ESP.Active)
                    or state


                if HZ.ESP.Active then

                    startESPLoop()

                else

                    stopESPLoop()

                end

            end

        }

    }

}
