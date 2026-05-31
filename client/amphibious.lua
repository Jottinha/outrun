-- ============================================================
--  OUTRUN — Client: Amphibious (swap carro <-> jetski na água)
--
--  Feature ISOLADA e opcional (Config.Amphibious.ENABLED). Foco 100%
--  multiplayer. Quando o carro DO JOGADOR entra na água durante uma corrida
--  MP, ele é trocado por um jetski; ao voltar pra terra, vira carro de novo.
--
--  Por que é isolado (não atrapalha o que já funciona):
--   * Não edita spawn / orchestrator / race_logic / race_state. Apenas LÊ
--     RaceState (global) e ajusta RaceState.myVehicle / participants —
--     exatamente como spawn.lua já faz.
--   * Re-aponta o snapshot de posição reusando RaceLogic.StartSnapshotLoop():
--     esse loop captura RaceState.myVehicle UMA vez, então re-chamamos depois
--     do swap para ele recapturar o veículo novo.
--   * Outros clients me re-resolvem pelo netId: ao trocar, avisamos o server
--     (UPDATE_VEHICLE_NETID), que rebroadcasta VEHICLE_NETID_CHANGED para a
--     sala atualizar participants[].netId/vehicle.
--
--  Ownership/limpeza: este módulo é DONO de qualquer entidade que cria
--  (jetski ou carro restaurado) e a deleta no fim da corrida / reset / stop,
--  porque o cleanup do orchestrator só conhece o carro original do Spawn.
-- ============================================================

Amphibious = {}

if not (Config.Amphibious and Config.Amphibious.ENABLED) then
    return
end

local CFG = Config.Amphibious
local SE  = Config.Events.Server
local CE  = Config.Events.Client

-- Estado privado do módulo
local mode         = "car"   -- "car" | "jetski"
local ownedVehicle = nil     -- entidade criada por ESTE módulo (a limpar)
local savedModel   = nil     -- hash do carro para restaurar na volta
local savedProps   = nil     -- propriedades QBCore do carro (mods/placa/cor)
local landSince    = 0       -- ms desde que o jetski saiu da água (debounce)


-- ------------------------------------------------------------
-- Helpers de baixo nível
-- ------------------------------------------------------------

local function loadModel(hash)
    if HasModelLoaded(hash) then return true end
    if not IsModelInCdimage(hash) then return false end
    RequestModel(hash)
    local elapsed = 0
    while not HasModelLoaded(hash) and elapsed < 5000 do
        Citizen.Wait(50)
        elapsed = elapsed + 50
    end
    return HasModelLoaded(hash)
end

local function getVehicleProps(veh)
    local ok, props = pcall(function()
        return exports['qb-core']:GetCoreObject().Functions.GetVehicleProperties(veh)
    end)
    if ok then return props end
    return nil
end

local function setVehicleProps(veh, props)
    if not props then return end
    pcall(function()
        exports['qb-core']:GetCoreObject().Functions.SetVehicleProperties(veh, props)
    end)
end

-- Cria um veículo já registrado em rede e sem migração de ownership,
-- espelhando o que Spawn.runMyVehicle faz com o carro de corrida.
local function createNetworkedVehicle(hash, coords, heading)
    if not loadModel(hash) then
        Logger.warn("AMPHIB", "modelo nao carregou: " .. tostring(hash))
        return nil
    end
    local veh = CreateVehicle(hash, coords.x, coords.y, coords.z, heading, true, false)
    SetEntityAsMissionEntity(veh, true, true)
    NetworkRegisterEntityAsNetworked(veh)
    SetNetworkIdCanMigrate(VehToNet(veh), false)
    SetVehicleEngineOn(veh, true, true, false)
    SetModelAsNoLongerNeeded(hash)
    return veh
end

-- Senta o jogador no banco do motorista INSTANTANEAMENTE. SetPedIntoVehicle
-- é síncrono (ao contrário de TaskWarpPedIntoVehicle, que é uma task e pode
-- não concluir antes de deletarmos o veículo antigo). Retorna se sentou.
local function putMeInVehicle(veh)
    local ped = PlayerPedId()
    SetPedIntoVehicle(ped, veh, -1)
    return GetPedInVehicleSeat(veh, -1) == ped
end

-- Mantém a velocidade horizontal; zera a vertical para o veículo novo não
-- mergulhar/saltar no instante da troca.
local function carryMomentum(veh, vel)
    SetEntityVelocity(veh, vel.x, vel.y, 0.0)
end

-- Re-aponta o snapshot loop (MP) para o novo veículo e avisa o server o netId.
local function afterSwap(veh)
    -- StartSnapshotLoop só existe no fluxo MP; em solo seria o loop errado.
    if RaceState.isActive() and RaceState.isMultiplayer then
        RaceLogic.StartSnapshotLoop() -- recaptura RaceState.myVehicle
    end
    local netId = VehToNet(veh)
    TriggerServerEvent(SE.UPDATE_VEHICLE_NETID, netId)
    Logger.debug("AMPHIB", ("swap -> %s (netId=%d)"):format(mode, netId))
end


-- ------------------------------------------------------------
-- Trocas
-- ------------------------------------------------------------

local function swapToJetski(car)
    local coords  = GetEntityCoords(car)
    local heading = GetEntityHeading(car)
    local vel     = GetEntityVelocity(car)

    -- guarda o carro para restaurar idêntico na volta
    savedModel = GetEntityModel(car)
    savedProps = getVehicleProps(car)

    local jet = createNetworkedVehicle(
        GetHashKey(CFG.JETSKI_MODEL),
        vector3(coords.x, coords.y, coords.z + 0.5),
        heading)
    if not jet then return end

    local seated = putMeInVehicle(jet)         -- senta ANTES de deletar o carro
    if DoesEntityExist(car) then DeleteVehicle(car) end
    if seated then carryMomentum(jet, vel) end -- só dá momentum se eu entrei

    RaceState.myVehicle = jet
    ownedVehicle = jet
    mode         = "jetski"
    landSince    = 0
    afterSwap(jet)
end

local function swapToCar(jet)
    if not savedModel then return end
    local coords  = GetEntityCoords(jet)
    local heading = GetEntityHeading(jet)
    local vel     = GetEntityVelocity(jet)

    local car = createNetworkedVehicle(
        savedModel,
        vector3(coords.x, coords.y, coords.z),
        heading)
    if not car then return end

    SetVehicleOnGroundProperly(car)
    setVehicleProps(car, savedProps) -- restaura mods/placa/cor originais

    local seated = putMeInVehicle(car)         -- senta ANTES de deletar o jetski
    if DoesEntityExist(jet) then DeleteVehicle(jet) end
    if seated then carryMomentum(car, vel) end

    RaceState.myVehicle = car
    ownedVehicle = car
    mode         = "car"
    landSince    = 0
    afterSwap(car)
end


-- ------------------------------------------------------------
-- Detecção
-- ------------------------------------------------------------

local function tick()
    local veh = RaceState.myVehicle
    if not veh or not DoesEntityExist(veh) then return end
    if RaceState.eliminated then return end
    -- só age se EU for o motorista do MEU veículo
    if GetPedInVehicleSeat(veh, -1) ~= PlayerPedId() then return end

    local submerged = GetEntitySubmergedLevel(veh)

    if mode == "car" then
        if submerged >= CFG.ENTER_SUBMERGE then
            swapToJetski(veh)
        end
    else -- jetski
        if (not IsEntityInWater(veh)) and submerged < CFG.EXIT_SUBMERGE then
            if IsEntityInAir(veh) then
                landSince = 0
            else
                if landSince == 0 then landSince = GetGameTimer() end
                if GetGameTimer() - landSince >= CFG.LAND_DEBOUNCE_MS then
                    swapToCar(veh)
                end
            end
        else
            landSince = 0
        end
    end
end

local function currentInterval()
    if mode == "jetski" then return CFG.CHECK_INTERVAL_WET end
    local veh = RaceState.myVehicle
    if veh and DoesEntityExist(veh) and GetEntitySubmergedLevel(veh) > 0.0 then
        return CFG.CHECK_INTERVAL_WET
    end
    return CFG.CHECK_INTERVAL_DRY
end


-- ------------------------------------------------------------
-- Limpeza do que ESTE módulo criou
-- ------------------------------------------------------------

local function cleanupOwned()
    if ownedVehicle and DoesEntityExist(ownedVehicle) then
        if RaceState.myVehicle == ownedVehicle then
            RaceState.myVehicle = nil
        end
        DeleteVehicle(ownedVehicle)
    end
    ownedVehicle = nil
    savedModel   = nil
    savedProps   = nil
    mode         = "car"
    landSince    = 0
end


-- ------------------------------------------------------------
-- Supervisor: roda sempre, mas só atua durante corrida (MP)
-- ------------------------------------------------------------

Citizen.CreateThread(function()
    local wasActive = false
    while true do
        local active = RaceState.isActive()
            and (not CFG.ONLY_MULTIPLAYER or RaceState.isMultiplayer == true)

        if active and not wasActive then
            -- nova corrida: o carro inicial é do Spawn (não nosso ainda)
            ownedVehicle = nil
            savedModel   = nil
            savedProps   = nil
            mode         = "car"
            landSince    = 0
        elseif wasActive and not active then
            -- corrida acabou: limpa qualquer jetski/carro que criamos
            cleanupOwned()
        end
        wasActive = active

        if active then tick() end
        Citizen.Wait(active and currentInterval() or 750)
    end
end)


-- ------------------------------------------------------------
-- Rede: outro participante (ou eu) trocou de veículo -> re-resolver netId
-- ------------------------------------------------------------

RegisterNetEvent(CE.VEHICLE_NETID_CHANGED, function(participantId, netId)
    local p = RaceState.findParticipant(participantId)
    if not p then return end
    p.netId = netId
    local v = NetToVeh(netId)
    p.vehicle = (v ~= 0 and DoesEntityExist(v)) and v or nil
end)


-- ------------------------------------------------------------
-- Stop do resource: nunca deixar jetski/carro órfão no mapa
-- ------------------------------------------------------------

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    cleanupOwned()
end)
