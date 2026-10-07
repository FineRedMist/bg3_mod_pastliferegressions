local pastLifeRegressionsTagId = "238c5177-836f-4167-8ea8-9df39ee5f4ba"

local bDebug = false
local bCanTick = false

--- @enum QueuedBackgroundGoalStatus
local QueuedBackgroundGoalStatus = {
    Added = 0,
    Committing = 1,
    [0] = "Added",
    [1] = "Committing",
}

---@type table<GUIDSTRING, string> A mapping of background tag GUIDs to their names.
local backgroundTags = {}
---@type table<string, boolean> A mapping of background tag names to their public status.
local publicBackgroundTags = {}

---@type table<integer, GUIDSTRING> Tracks the players that have last been validated in order. They all get validated on loading, then one at a time each tick.
local validatedPlayers = {}

-- Retries the gathering of background tags every 10 ticks in case the first gather was while mods were still loading and some backgrounds weren't available yet.
local retryGatherRate = 10
local retryGatherCounter = 0

---Gathers the list of background tags (one time only).
---@return boolean? True if the background tags were gathered, false if they were already gathered, nil on error
local function GatherBackgroundTags()
    if #backgroundTags > 0 and retryGatherCounter < retryGatherRate then
        retryGatherCounter = retryGatherCounter + 1
        return false
    end
    local backgroundGuids = Ext.StaticData.GetAll(Ext.Enums.ExtResourceManagerType.Background)
    if not backgroundGuids then
        Ext.Log.PrintError("GatherBackgroundInfo: Could not retrieve backgrounds!")
        return nil
    end

    retryGatherCounter = 0
    local oldBackgroundTags = backgroundTags
    local oldPublicBackgroundTags = publicBackgroundTags
    backgroundTags = {}
    publicBackgroundTags = {}

    for _, backgroundGuid in pairs(backgroundGuids) do
        local background = Ext.StaticData.Get(backgroundGuid, Ext.Enums.ExtResourceManagerType.Background)
        if background then
            for _, tag in ipairs(background.Tags) do
                local tagName = nil
                if not backgroundTags[tag] then
                    local tagResource = Ext.StaticData.Get(tag, Ext.Enums.ExtResourceManagerType.Tag)
                    tagName = tagResource.Name .. "_" .. tag
                    backgroundTags[tag] = tagName
                    if not background.Hidden then
                        publicBackgroundTags[tagName] = true
                    end
                end
            end
        end
    end

    if #backgroundTags ~= #oldBackgroundTags or #publicBackgroundTags ~= #oldPublicBackgroundTags then
        Ext.Log.Print("GatherBackgroundInfo: Gathered " .. tostring(#backgroundTags) .. " background tags, " ..
            tostring(#publicBackgroundTags) .. " public background tags.")
        return true
    end
    return false
end

---Gets the map of tagnames to whether the player has them or not.
---@param player EntityHandle The player entity to get the tag map for.
---@return table<string, boolean> A mapping of background tag names to them being used by the current player.
local function GetPlayerTagMap(player)
    if not player or not player.Tag or not player.Tag.Tags then
        return {}
    end

    local playerTags = {}
    for _, tag in ipairs(player.Tag.Tags) do
        local tagName = backgroundTags[tag]
        if tagName then
            playerTags[tagName] = true
        end
    end
    if playerTags[pastLifeRegressionsTagId] then
        -- Merge tags, as they may have taken a feat or something else that grants background tags that are hidden along with the public one.
        for tagName, _ in pairs(publicBackgroundTags) do
            if not playerTags[tagName] then
                playerTags[tagName] = true
            end
        end
    end
    return playerTags
end

---Fix up the DB_GLO_Backgrounds_Players table to ensure that the Past Life Regressions background is applied to all players with the Past Life Regressions tag.
---@param playerId GUIDSTRING The player id, it needs to be of the form <name>_<guid>
---@param playerTags table<string, boolean> A mapping of background tag names to them being used by the current player.
local function FixupPlayerBackgroundTable(playerId, playerTags)
    -- Get the current list of tags.
    local currentPlayerTags = {}
    local currentPlayerTagRows = Osi.DB_GLO_Backgrounds_Players:Get(playerId, nil)
    for _, row in ipairs(currentPlayerTagRows) do
        local tagName = row[2]
        currentPlayerTags[tagName] = true
    end

    for tagName, _ in pairs(playerTags) do
        if not currentPlayerTags[tagName] then
            Ext.Log.Print("FixupBackgroundTables: Adding missing background tag " .. tagName ..
                " for player " .. tostring(playerId))
            Osi.DB_GLO_Backgrounds_Players(playerId, tagName)
        end
    end

    for tagName, _ in pairs(currentPlayerTags) do
        if not playerTags[tagName] then
            Ext.Log.Print("FixupBackgroundTables: Removing unused background tag " .. tagName ..
                " for player " .. tostring(playerId))
            Osi.DB_GLO_Backgrounds_Players:Delete(playerId, tagName)
        end
    end
end

---Fixes the background tag tables for a specific player.
---@param playerId GUIDSTRING The player id, it needs to be of the form <name>_<guid>
local function FixTableForPlayer(playerId)
    local player = Ext.Entity.Get(playerId)
    ---@type table<string, boolean> A mapping of background tag names to them being used by the current player.
    local playerTags = GetPlayerTagMap(player)
    FixupPlayerBackgroundTable(playerId, playerTags)

    -- Insert the player at the top of the list. They get removed at the end.
    table.insert(validatedPlayers, 1, playerId)
end

local function FixupBackgroundTables()
    -- Reset when processing all players.
    validatedPlayers = {}
    -- Go through each player looking for their tags.
    local players = Osi.DB_Players:Get(nil)
    for _, row in ipairs(players) do
        local playerId = row[1]
        FixTableForPlayer(playerId)
    end
end

---@param e EclLuaGameStateChangedEvent
local function GatherBackgroundInfo(e)
    if e.FromState == Ext.Enums.ServerGameState.Running then
        bCanTick = false
    end
    if e.ToState == Ext.Enums.ServerGameState.Running then
        bCanTick = true
    end
end

---Checks one player at a time that is not in the update list.
---@param tickParams any
local function OnTickUpdateBackgrounds(tickParams)
    if not bCanTick then
        return
    end

    local firstGather = GatherBackgroundTags()
    if firstGather == nil then
        return
    end

    if firstGather then
        FixupBackgroundTables()
        return
    end

    -- Grab the first player in the DB_Players list that is not in the validatedPlayers list and validate them.
    local players = Osi.DB_Players:Get(nil)
    local playerId = nil
    for _, row in ipairs(players) do
        playerId = row[1]
        local bFound = false
        for _, validatedPlayerId in ipairs(validatedPlayers) do
            if validatedPlayerId == playerId then
                bFound = true
                break
            end
        end
        if not bFound then
            break
        end
        playerId = nil
    end

    -- If we found a player id, validate them
    if playerId then
        FixTableForPlayer(playerId)
    end

    -- Remove the last element in the validatedPlayers list so we don't keep validating the same players over and over.
    if #validatedPlayers > 0 then
        table.remove(validatedPlayers)
    end
end

---@class QueuedBackgroundGoal
---@field Character GUIDSTRING The ID of the character.
---@field Goal GUIDSTRING The ID of the background goal.
---@field GoalBackgroundId GUIDSTRING The ID of the background to switch to.
---@field CurrentBackgroundId GUIDSTRING The ID of the player's current background.
---@field Category string The category for the goal
---@field Status QueuedBackgroundGoalStatus The status of the queued goal.

---@type QueuedBackgroundGoal[]
local queuedBackgroundGoals = {}

---Takes the first pending goal in the queued goals to apply if it isn't already in progress.
local function ApplyQueuedBackgroundGoals()
    -- We don't want to update backgrounds while we are messing with them for missed goals.
    if #queuedBackgroundGoals == 0 then
        OnTickUpdateBackgrounds()
    end
    for _, goal in ipairs(queuedBackgroundGoals) do
        if bDebug then Ext.Log.Print("Pending background goal count: " .. tostring(#queuedBackgroundGoals)) end
        if goal.Status ~= QueuedBackgroundGoalStatus.Added then
            return
        end
        if bDebug then
            Ext.Log.Print("Applying queued background goal for character " ..
                tostring(goal.Character) .. " goal " .. tostring(goal.Goal))
        end
        goal.Status = QueuedBackgroundGoalStatus.Committing

        local player = Ext.Entity.Get(goal.Character)
        player.Background.Background = goal.GoalBackgroundId
        Osi.AddBackgroundGoal(goal.Character, goal.Goal, goal.Category)
        return
    end
end

---Finishes the application of any queued background goals by restoring the player's background id.
---@param status string Whether the goal was "Completed" or "Failed".
---@return boolean True if a queued goal was finished, false otherwise.
local function FinishBackgroundGoalApplication(status)
    local removeIndex = -1
    for index, goal in ipairs(queuedBackgroundGoals) do
        if goal.Status == QueuedBackgroundGoalStatus.Committing then
            if bDebug then
                Ext.Log.Print(status ..
                    " queued background goal for character " ..
                    tostring(goal.Character) .. " goal " .. tostring(goal.Goal))
            end

            removeIndex = index

            local player = Ext.Entity.Get(goal.Character)
            player.Background.Background = goal.CurrentBackgroundId
        end
    end

    if removeIndex > 0 then
        table.remove(queuedBackgroundGoals, removeIndex)
        return true
    end
    return false
end


---Determines if the player is tagged with the Past Life Regressions tag.
---@param player EntityHandle The player entity to check.
---@return boolean True if the player has the tag, false otherwise.
local function HasPastLifeRegressionTag(player)
    -- No tags
    if not player.Tag or not player.Tag.Tags then
        return false
    end

    for _, tag in ipairs(player.Tag.Tags) do
        if tag == pastLifeRegressionsTagId then
            -- This character has the Past Life Regressions tag, proceed
            return true
        end
    end
    return false
end

--- Example: E6[Server]: BackgroundGoalFailed called for character Elves_Female_Everic_Player_b094fac2-9324-544d-76b2-e2a300399034 goal 92f75626-3bdd-4bb8-b5a5-2750c5e61c0d
---@param character CHARACTER The character the goal was being applied to.
---@param goal GUIDSTRING The id of the goal being rewarded.
local function BackgroundGoalFailed(character, goal)
    if bDebug then
        Ext.Log.Print("BackgroundGoalFailed called for character " ..
            tostring(character) .. " goal " .. tostring(goal))
    end

    -- Check queued background goals to make sure we don't double queue
    if FinishBackgroundGoalApplication("Failed") then
        return
    end

    local player = Ext.Entity.Get(character)

    if not player then
        if bDebug then
            Ext.Log.PrintError("BackgroundGoalFailed: Could not find entity for character " ..
                tostring(character))
        end
        return
    end

    if not HasPastLifeRegressionTag(player) then
        if bDebug then Ext.Log.Print(player .. " does not have Past Life Regressions tag, ignoring.") end
        return
    end

    if not player.Background or not player.Background.Background then
        if bDebug then
            Ext.Log.PrintError("BackgroundGoalFailed: Could not find background component for character " ..
                tostring(character))
        end
        return
    end

    -- Get the corresponding background goal
    ---@type ResourceBackgroundGoal
    local goalResource = Ext.StaticData.Get(goal, Ext.Enums.ExtResourceManagerType.BackgroundGoal)
    if not goalResource then
        if bDebug then
            Ext.Log.PrintError("BackgroundGoalFailed: Could not find background goal for GUID " ..
                tostring(goal))
        end
        return
    end

    -- Queue applying the background goal
    ---@type QueuedBackgroundGoal
    local queuedGoal = {
        Character = character,
        Goal = goal,
        GoalBackgroundId = goalResource.BackgroundUuid,
        CurrentBackgroundId = player.Background.Background,
        Category = "PastLifeRegressions",
        Status = QueuedBackgroundGoalStatus.Added
    }
    table.insert(queuedBackgroundGoals, queuedGoal)
end

--- Example: E6[Server]: BackgroundGoalFailed called for character Elves_Female_Everic_Player_b094fac2-9324-544d-76b2-e2a300399034 goal 92f75626-3bdd-4bb8-b5a5-2750c5e61c0d
---@param character CHARACTER The character the goal was being applied to.
---@param goal GUIDSTRING The id of the goal being rewarded.
local function BackgroundGoalRewarded(character, goal)
    if bDebug then
        Ext.Log.Print("BackgroundGoalRewarded called for character " ..
            tostring(character) .. " goal " .. tostring(goal))
    end
    FinishBackgroundGoalApplication("Completed")
end

--- If there are pending background goals to apply, moves them along.
local function BackgroundGoalsTick(tickParams)
    ApplyQueuedBackgroundGoals()
end

local function PastLifeToggleDebug()
    bDebug = not bDebug
    Ext.Log.Print("Past Life Regressions debug mode set to " .. tostring(bDebug))
end

---Creates a string representing the string version of teh TAGCATEGORY
---@param categories uint32 The bitfield of categories to convert to a string.
---@return string A string representing the TAGCATEGORY
local function GetTagCategories(categories)
    local result = {}
    local categoryStrings = {
        "Undefined",
        "Code",
        "Dialog",
        "Origin",
        "Identity",
        "Profession",
        "Race",
        "Race_Meta",
        "Story",
        "Voice",
        "Background",
        "Class",
        "DialogHidden",
        "Deity",
        "Class_Deity",
        "PlayerRace",
        "CharacterSheet",
        "SpellCondition"
    }
    if categories == 0 then
        return categoryStrings[1]
    end
    local curbit = 1
    for i = 0, 17 do
        if (categories & curbit) ~= 0 then
            table.insert(result, categoryStrings[i + 2])
        end
        curbit = curbit * 2
    end
    return table.concat(result, ", ")
end

local function DumpTagInfo(tagId)
    local tagResource = Ext.StaticData.Get(tagId, Ext.Enums.ExtResourceManagerType.Tag)
    if tagResource then
        local displayName = tagResource.DisplayName
        local displayHandle = displayName.Handle.Handle
        local displayString = Ext.Loca.GetTranslatedString(displayHandle)
        Ext.Log.Print("  - " .. tagResource.Name .. " " .. tagId .. " (" .. displayString .. "): " ..
            GetTagCategories(tagResource.Categories))
    else
        Ext.Log.Print("  - " .. tostring(tag) .. " (No resource found)")
    end
end

---Dumps a collection of tags.
---@param func string Name of the function
---@param thingWithTags string The thing that has the tags (character, background, etc.)
---@param tagIds GUIDSTRING[] The list of tag ids to dump.
local function DumpTagsInfo(func, thingWithTags, tagIds)
    Ext.Log.Print(func .. ": Tags for " .. tostring(thingWithTags) .. ":")
    for _, tag in ipairs(tagIds) do
        DumpTagInfo(tag)
    end
end

---Dumps the tag list for the character
---@param _ string The command
---@param character GUIDSTRING The character set the background for.
local function DumpTags(_, character)
    if not character then
        Ext.Log.PrintError("DumpTags: Missing character id.")
        return
    end
    local player = Ext.Entity.Get(character)
    if not player then
        Ext.Log.PrintError("DumpTags: Could not find entity for character " .. tostring(character))
        return
    end

    if not player.Tag or not player.Tag.Tags then
        Ext.Log.Print("DumpTags: No tags found for character " .. tostring(character))
        return
    end

    DumpTagsInfo("DumpTags", character, player.Tag.Tags)
end

---Dumps the background entry and returns if it is valid
---@param func str name of the calling function
---@param backgroundGuid GUIDSTRING id of the background to dump
---@return boolean whether the background was found and dumped successfully
local function DumpBackgroundEntry(func, backgroundGuid)
    if not backgroundGuid then
        Ext.Log.PrintError(func .. ": Missing background id.")
        return false
    end
    ---@type ResourceBackground
    local background = Ext.StaticData.Get(backgroundGuid, Ext.Enums.ExtResourceManagerType.Background)
    if not background then
        Ext.Log.PrintError(func .. ": Could not find background for GUID " .. tostring(backgroundGuid))
        return false
    end

    local displayName = background.DisplayName
    local displayHandle = displayName.Handle.Handle
    local displayString = Ext.Loca.GetTranslatedString(displayHandle)
    local isHidden = background.Hidden and "Hidden " or ""
    Ext.Log.Print(func .. ": " .. isHidden .. "Background: " .. tostring(backgroundGuid) .. ": " .. displayString)
    DumpTagsInfo("DumpBackgroundEntry", backgroundGuid, background.Tags)
    return true
end

---Lists the backgrounds available in the game
---@param _ string The command
local function ListBackgrounds(_)
    ---@type GUIDSTRING[]
    local backgroundGuids = Ext.StaticData.GetAll(Ext.Enums.ExtResourceManagerType.Background)
    if not backgroundGuids then
        Ext.Log.PrintError("ListBackgrounds: Could not retrieve backgrounds!")
        return
    end

    for _, backgroundGuid in pairs(backgroundGuids) do
        DumpBackgroundEntry("ListBackgrounds", backgroundGuid)
    end
end

---Sets the background of the character to the new background guid. May require a save/load to take full effect.
---@param _ string The command
---@param character GUIDSTRING The character set the background for.
---@param backgroundGuid GUIDSTRING The background to set for the character.
local function SetBackground(_, character, backgroundGuid)
    if not character or not backgroundGuid then
        Ext.Log.PrintError("SetBackground: Missing character id and/or background id arguments.")
        return
    end
    local player = Ext.Entity.Get(character)
    if not player then
        Ext.Log.PrintError("SetBackground: Could not find entity for character " .. tostring(character))
        return
    end

    if DumpBackgroundEntry("SetBackground", backgroundGuid) then
        player.Background.Background = backgroundGuid
    end

    FixupBackgroundTables() -- Do a full pass to fixup tables.
end

---Dumps the tag list for the character
---@param _ string The command
---@param character GUIDSTRING The character set the background for.
local function DumpBackgroundInfo(_, character)
    if not character then
        Ext.Log.PrintError("DumpBackgroundInfo: Missing character id.")
        return
    end
    local player = Ext.Entity.Get(character)
    if not player then
        Ext.Log.PrintError("DumpBackgroundInfo: Could not find entity for character " .. tostring(character))
        return
    end

    if player.Background then
        local backgroundGuid = player.Background.Background
        if backgroundGuid then
            DumpBackgroundEntry("DumpBackgroundInfo", backgroundGuid)
        else
            Ext.Log.Print("DumpBackgroundInfo: No background set for character " .. tostring(character))
        end
    else
        Ext.Log.Print("DumpBackgroundInfo: No background component found for character " .. tostring(character))
    end

    if player.BackgroundTag then
        DumpTagsInfo("DumpBackgroundInfo", character, player.BackgroundTag.Tags)
    else
        Ext.Log.Print("DumpBackgroundInfo: No background tag set for character " .. tostring(character))
    end

    if player.BackgroundPassives then
        Ext.Log.Print("DumpBackgroundInfo: dumping background passives for " .. tostring(character) .. ":")
        for _, passive in ipairs(player.BackgroundPassives.field_18) do
            Ext.Log.Print(" - " .. passive.Name)
        end
    else
        Ext.Log.Print("DumpBackgroundInfo: No background passives component found for character " .. tostring(character))
    end

    if player.BackgroundGoals then
        Ext.Log.Print("DumpBackgroundInfo: dumping background goals for " .. tostring(character) .. ":")
        for id, goals in pairs(player.BackgroundGoals.Goals) do
            Ext.Log.Print(" - " .. tostring(id) .. ": ")
            for _, goal in ipairs(goals) do
                Ext.Log.Print("    - Goal: " ..
                    tostring(goal.Goal) ..
                    ", entity: " .. tostring(goal.Entity) .. ", category: " .. tostring(goal.Category))
            end
        end
    else
        Ext.Log.Print("DumpBackgroundInfo: No background goals component found for character " .. tostring(character))
    end

    Ext.Log.Print("DumpBackgroundInfo: dumping DB_GLO_Backgrounds_Players")
    -- Tracks player and background tags
    local rows = Osi.DB_GLO_Backgrounds_Players:Get(nil, nil)
    for _, row in ipairs(rows) do
        local playerId = row[1]
        local backgroundId = row[2]
        Ext.Log.Print(" - Player: " .. tostring(playerId) .. ", Background: " .. tostring(backgroundId))
    end

    Ext.Log.Print("DumpBackgroundInfo: dumping DB_GLO_Backgrounds_Tags")
    -- Tracks active background tags
    local rows = Osi.DB_GLO_Backgrounds_Tags:Get(nil)
    for _, row in ipairs(rows) do
        local backgroundId = row[1]
        Ext.Log.Print(" - Background: " .. tostring(backgroundId))
    end
end

function Init_PastLifeRegressions()
    if bDebug then Ext.Log.Print("Initializing Past Life Regressions Script Extender") end

    Ext.Events.GameStateChanged:Subscribe(GatherBackgroundInfo)

    -- Processes any pending background goals to apply.
    Ext.Events.Tick:Subscribe(BackgroundGoalsTick)

    -- Handles identifying when background goals fail and succeed to refine the queue.
    Ext.Osiris.RegisterListener("BackgroundGoalFailed", 2, "before", BackgroundGoalFailed)
    Ext.Osiris.RegisterListener("BackgroundGoalRewarded", 2, "after", BackgroundGoalRewarded)

    Ext.RegisterConsoleCommand("PastLifeToggleDebug", PastLifeToggleDebug)

    Ext.RegisterConsoleCommand("SetBackground", SetBackground)
    Ext.RegisterConsoleCommand("ListBackgrounds", ListBackgrounds)
    Ext.RegisterConsoleCommand("DumpTags", DumpTags)
    Ext.RegisterConsoleCommand("DumpBackgroundInfo", DumpBackgroundInfo)
    Ext.RegisterConsoleCommand("FixupBackgroundTables", FixupBackgroundTables)
end
