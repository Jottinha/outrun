Spectator = {}

local spectatorCam  = nil
local targetVehicle = nil
local orbitAngle    = 0.0
local orbitDist     = 6.0
local orbitHeight   = 2.5
local active        = false

function Spectator.Start(leaderVeh, leaderPed)
    if active then Spectator.Stop() end

    targetVehicle = leaderVeh
    active        = true

    FreezeEntityPosition(PlayerPedId(), true)
    SetEntityVisible(PlayerPedId(), false, false)

    -- Força o carregamento do mapa/texturas em volta do alvo
    SetFocusEntity(targetVehicle) 

    spectatorCam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamActive(spectatorCam, true)
    RenderScriptCams(true, false, 0, true, true)

    Citizen.CreateThread(function()
        while active do
            -- Se a entidade sumir temporariamente (culling), não quebramos o loop imediatamente.
            -- Apenas paramos de atualizar a câmera até ela voltar.
            if DoesEntityExist(targetVehicle) then
                local center = GetEntityCoords(targetVehicle)
                
                -- Controle 1 = INPUT_LOOK_LR (Funciona no Mouse e no Controle nativamente)
                local rightX = GetControlNormal(0, 1) 
                
                -- Multiplicador aumentado levemente para não ficar muito lento no mouse
                orbitAngle = orbitAngle + (rightX * 4.0) 

                local rad = math.rad(orbitAngle)
                SetCamCoord(spectatorCam,
                    center.x + math.cos(rad) * orbitDist,
                    center.y + math.sin(rad) * orbitDist,
                    center.z + orbitHeight)
                
                PointCamAtEntity(spectatorCam, targetVehicle, 0.0, 0.0, 0.0, true)
            end

            Citizen.Wait(0)
        end
    end)
end

function Spectator.Stop()
    active = false
    if spectatorCam then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(spectatorCam, false)
        spectatorCam = nil
    end
    
    ClearFocus() -- Limpa o foco do mapa para voltar ao seu personagem
    NetworkSetInSpectatorMode(false, PlayerPedId()) -- Desliga o espectador nativo da rede
    
    FreezeEntityPosition(PlayerPedId(), false)
    SetEntityVisible(PlayerPedId(), true, false)
    targetVehicle = nil
end

RegisterNetEvent(Config.Events.Client.BE_SPECTATOR, function(leaderId)
    RaceState.eliminated = true

    if not leaderId then 
        print("Erro: ID do líder veio nulo do servidor.")
        return 
    end

    local targetPlayer = GetPlayerFromServerId(leaderId)
    
    if targetPlayer ~= -1 then
        local leaderPed = GetPlayerPed(targetPlayer)
        -- Avisa a engine do GTA: "Comece a baixar esse jogador pela rede urgente"
        NetworkSetInSpectatorMode(true, leaderPed)
    end

    -- Cria uma thread para tentar achar o carro repetidas vezes (até 5 segundos)
    Citizen.CreateThread(function()
        local leaderVeh = nil
        local leaderPed = nil
        local attempts = 0

        -- Tenta 50 vezes, a cada 100 milissegundos
        while attempts < 50 do
            -- Tenta achar o veículo usando a entidade do Ped (se já carregou)
            if targetPlayer ~= -1 then
                leaderPed = GetPlayerPed(targetPlayer)
                local veh = GetVehiclePedIsIn(leaderPed, false)
                if veh and DoesEntityExist(veh) then
                    leaderVeh = veh
                    break
                end
            end

            -- Plano B: Se o Ped não carregou, tenta achar puxando pelo netId salvo na RaceState
            if not leaderVeh then
                for _, p in ipairs(RaceState.participants) do
                    if tostring(p.id) == tostring(leaderId) and p.netId then
                        local veh = NetToVeh(p.netId)
                        if DoesEntityExist(veh) then
                            leaderVeh = veh
                            -- Se achou pelo netId, tenta descobrir quem é o motorista
                            leaderPed = GetPedInVehicleSeat(veh, -1)
                            break
                        end
                    end
                end
            end

            attempts = attempts + 1
            Citizen.Wait(100) -- Espera 0.1s antes de tentar olhar de novo
        end

        -- Fim do loop. Avalia se conseguimos pegar o carro a tempo
        if leaderVeh and DoesEntityExist(leaderVeh) then
            -- Se por acaso o ped não foi pego no loop, garante pegar quem tá no banco do motorista
            if not leaderPed or not DoesEntityExist(leaderPed) then
                leaderPed = GetPedInVehicleSeat(leaderVeh, -1)
            end
            
            -- Inicia a câmera orbital!
            Spectator.Start(leaderVeh, leaderPed)
        else
            print("Erro: O veículo do líder demorou mais de 5s para streamar. Câmera abortada.")
            -- Se falhou, desliga o espectador nativo para não bugar a câmera do jogador
            NetworkSetInSpectatorMode(false, PlayerPedId())
        end
    end)
end)