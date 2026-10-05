local pastLifeRegressionsTagId = "238c5177-836f-4167-8ea8-9df39ee5f4ba"

local bDebug = false

--- @enum QueuedBackgroundGoalStatus
local QueuedBackgroundGoalStatus = {
    Added = 0,
    Committing = 1,
    [0] = "Added",
    [1] = "Committing",
}

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

---Prints the number of feats that can be granted for the given XP.
---@param _ string The command
local function ListBackgrounds(_)
    ---@type GUIDSTRING[]
    local backgroundGuids = Ext.StaticData.GetAll(Ext.Enums.ExtResourceManagerType.Background)
    if not backgroundGuids then
        Ext.Log.PrintError("ListBackgrounds: Could not retrieve backgrounds!")
        return
    end

    for _, backgroundGuid in pairs(backgroundGuids) do
        ---@type ResourceBackground
        local background = Ext.StaticData.Get(backgroundGuid, Ext.Enums.ExtResourceManagerType.Background)
        local displayName = background.DisplayName
        local displayHandle = displayName.Handle.Handle
        local displayString = Ext.Loca.GetTranslatedString(displayHandle)
        Ext.Log.Print("Background: " .. displayString .. " (" .. tostring(backgroundGuid) .. ")")
    end
end

---Prints the number of feats that can be granted for the given XP.
---@param _ string The command
---@param character GUIDSTRING The character set the background for.
---@param background GUIDSTRING The background to set for the character.
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

    ---@type ResourceBackground
    local background = Ext.StaticData.Get(backgroundGuid, Ext.Enums.ExtResourceManagerType.Background)
    Ext.Log.Print("Background: " ..
        Ext.Loca.GetTranslatedString(background.DisplayName.Handle.Handle) .. " (" .. tostring(backgroundGuid) .. ")")

    if not background then
        Ext.Log.PrintError("SetBackground: Could not find background for GUID " .. tostring(background))
        return
    end

    player.Background.Background = backgroundGuid
end

function Init_PastLifeRegressions()
    if bDebug then Ext.Log.Print("Initializing Past Life Regressions Script Extender") end

    -- Processes any pending background goals to apply.
    Ext.Events.Tick:Subscribe(BackgroundGoalsTick)

    -- Handles identifying when background goals fail and succeed to refine the queue.
    Ext.Osiris.RegisterListener("BackgroundGoalFailed", 2, "before", BackgroundGoalFailed)
    Ext.Osiris.RegisterListener("BackgroundGoalRewarded", 2, "after", BackgroundGoalRewarded)

    Ext.RegisterConsoleCommand("PastLifeToggleDebug", PastLifeToggleDebug)

    Ext.RegisterConsoleCommand("SetBackground", SetBackground)
    Ext.RegisterConsoleCommand("ListBackgrounds", ListBackgrounds)
end
