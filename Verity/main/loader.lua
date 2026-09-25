--[[
╔══════════════════════════════════════════════════════════════╗
║         HunterZ Hub — Verity Module v1.0                     ║
║         PlaceId: 104526416639079                             ║
║                                                              ║
║  Features:                                                   ║
║  • [Farm] Auto Farm Boxes — Toggle ON/OFF                    ║
║    - Busca la caja disponible con mayor weight               ║
║    - Teleporta al jugador dentro de la caja                  ║
║    - Fija HoldDuration del PickupPrompt a 0.1                ║
║    - Al terminar, va a las coordenadas de retorno            ║
║    - Repite el ciclo mientras esté ON                        ║
╚══════════════════════════════════════════════════════════════╝
--]]

-- ==================== NAMESPACE ====================
getgenv().HunterZ_Verity = getgenv().HunterZ_Verity or {}
local HZ = getgenv().HunterZ_Verity

HZ.Farm = HZ.Farm or {
    Active      = false,
    Thread      = nil,
}

-- ==================== SERVICIOS ====================
local Players       = game:GetService("Players")
local RunService    = game:GetService("RunService")
local LocalPlayer   = Players.LocalPlayer

-- ==================== DATOS DE CAJAS ====================
-- Ordenadas por weight DESC — la primera disponible en el mapa
-- es la más valiosa que se puede farmear en ese momento.
local BOX_DATA = {
    { name = "1x1x1x1",   weight = 65000000  },
    { name = "Rainbow",    weight = 20000000  },
    { name = "Heaven",     weight = 5200000   },
    { name = "Demon",      weight = 1000000   },
    { name = "Kraken",     weight = 350000    },
    { name = "Toxic",      weight = 150000    },
    { name = "LuckyBlock", weight = 60000     },
    { name = "Neon",       weight = 25000     },
    { name = "Soccer",     weight = 10000     },
    { name = "Diamond",    weight = 5000      },
    { name = "Gold",       weight = 2200      },
    { name = "YinYang",    weight = 800       },
    { name = "Bamboo",     weight = 400       },
    { name = "Backrooms",  weight = 220       },
    { name = "Candy",      weight = 130       },
    { name = "Keyboard",   weight = 60        },
    { name = "Sakura",     weight = 30        },
    { name = "Cardboard",  weight = 10        },
}

-- CFrame de retorno después de recoger cada caja
local RETURN_CFRAME = CFrame.new(
    -120, 10.4569969, -176,
    -1, 0, 0,
     0, 1, 0,
     0, 0, -1
)

-- Tiempo de espera entre intentos si no hay caja disponible (segundos)
local RETRY_WAIT    = 2
-- Tiempo de espera después de teleportarse dentro de la caja
local INSIDE_WAIT   = 0.35
-- Tiempo de espera después de volver al punto de retorno
local RETURN_WAIT   = 0.5
-- HoldDuration forzado en el PickupPrompt
local PICKUP_HOLD   = 0.1

-- ==================== UTILIDADES ====================

-- Obtiene el personaje y HumanoidRootPart del jugador local de forma segura
local function getCharacter()
    local char = LocalPlayer.Character
    if not char then return nil, nil end
    local hrp  = char:FindFirstChild("HumanoidRootPart")
    local hum  = char:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then return nil, nil end
    return char, hrp
end

-- Teleporta el HRP a un CFrame dado
local function teleportTo(cf)
    local _, hrp = getCharacter()
    if hrp then
        hrp.CFrame = cf
    end
end

--[[
    Busca en workspace.Boxes la caja con mayor weight que esté
    físicamente presente en el mapa en este momento.
    Devuelve: boxModel (Model), mainModel (Model), pickupPart (BasePart), pickupPrompt (ProximityPrompt)
    o nil, nil, nil, nil si no se encontró nada válido.
--]]
local function findBestBox()
    local boxesFolder = workspace:FindFirstChild("Boxes")
    if not boxesFolder then
        warn("[HunterZ/Verity] No se encontró workspace.Boxes")
        return nil, nil, nil, nil
    end

    for _, entry in ipairs(BOX_DATA) do
        local boxModel = boxesFolder:FindFirstChild(entry.name)
        if boxModel then
            -- Buscar el modelo "Main" dentro de la caja
            local mainModel = boxModel:FindFirstChild("Main")
            if mainModel then
                -- Buscar una Part que tenga un ProximityPrompt dentro de Main
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

-- Fuerza el HoldDuration del ProximityPrompt y activa la recogida
local function collectBox(pickupPart, pickupPrompt)
    -- Forzar hold duration
    pcall(function()
        pickupPrompt.HoldDuration = PICKUP_HOLD
    end)

    -- Teleportar encima de la part del prompt
    teleportTo(pickupPart.CFrame + Vector3.new(0, 2, 0))

    task.wait(INSIDE_WAIT)

    -- Intentar activar el prompt si la API está disponible
    -- (fireclickdetector / fireproximityprompt según executor)
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

-- ==================== LOOP PRINCIPAL ====================

local function startFarmLoop()
    -- Evitar loops duplicados
    if HZ.Farm.Thread then
        task.cancel(HZ.Farm.Thread)
        HZ.Farm.Thread = nil
    end

    HZ.Farm.Thread = task.spawn(function()
        print("[HunterZ/Verity] Auto Farm iniciado")

        while HZ.Farm.Active do
            local _, hrp = getCharacter()
            if not hrp then
                -- Personaje no disponible, esperar respawn
                task.wait(RETRY_WAIT)
                continue
            end

            local boxModel, mainModel, pickupPart, pickupPrompt = findBestBox()

            if not boxModel then
                -- No hay cajas disponibles en el mapa
                warn("[HunterZ/Verity] No se encontró ninguna caja en workspace.Boxes, reintentando...")
                task.wait(RETRY_WAIT)
                continue
            end

            print(string.format("[HunterZ/Verity] Farmeando caja: %s", boxModel.Name))

            -- 1. Teleportar al interior de la caja (junto al PickupPrompt)
            collectBox(pickupPart, pickupPrompt)

            -- 2. Si el loop sigue activo, volver al punto de retorno
            if not HZ.Farm.Active then break end

            teleportTo(RETURN_CFRAME)
            task.wait(RETURN_WAIT)

            -- 3. Pequeña pausa antes del siguiente ciclo para evitar flood
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

-- ==================== MÓDULO ====================
return {
    actions = {

        ["[Farm] Auto Farm Boxes"] = {
            toggle = true,
            fn = function(state)
                -- state llega como true/false desde el hub
                -- Si llega nil se hace toggle interno
                if state == nil then
                    HZ.Farm.Active = not HZ.Farm.Active
                else
                    HZ.Farm.Active = state
                end

                if HZ.Farm.Active then
                    startFarmLoop()
                else
                    stopFarmLoop()
                end
            end
        },

    }
}
