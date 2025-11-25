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
---@field Goal GUIDSTRING The ID of the background goal.
---@field GoalBackgroundId GUIDSTRING The ID of the background to switch to.
---@field Category string The category for the goal
---@field Status QueuedBackgroundGoalStatus The status of the queued goal.

---@class PlayerBackgroundGoalQueue
---@field CurrentBackgroundId GUIDSTRING The ID of the player's current background.
---@field Goals QueuedBackgroundGoal[] The list of queued background goals for the character.

---Mapping of the character's GUID to their queued background goals.
---@type table<GUIDSTRING, PlayerBackgroundGoalQueue>
local queuedBackgroundGoals = {}

---Applies the queued background goal if it isn't already in progress.
---@param characterId GUIDSTRING
---@param goals QueuedBackgroundGoal[]
local function ApplyQueuedBackgroundGoal(characterId, goals)
    for _, goal in ipairs(goals) do
        if goal.Status ~= QueuedBackgroundGoalStatus.Added then
            return
        end

        local player = Ext.Entity.Get(characterId)
        if not player then
            if bDebug then Ext.Log.PrintError("ApplyQueuedBackgroundGoal: Could not find entity for character " .. tostring(characterId)) end
            return
        end

        if bDebug then Ext.Log.Print("Applying queued background goal for character " .. tostring(characterId) .. " goal " .. tostring(goal.Goal)) end
        goal.Status = QueuedBackgroundGoalStatus.Committing
        player.Background.Background = goal.GoalBackgroundId
        Osi.AddBackgroundGoal(characterId, goal.Goal, goal.Category)
        return
    end
end

---Takes the first pending goal in the queued goals to apply if it isn't already in progress.
local function ApplyQueuedBackgroundGoals()
    for characterId, queue in pairs(queuedBackgroundGoals) do
        if bDebug then Ext.Log.Print("Pending background goal count for " .. tostring(characterId) .. ": " .. tostring(#queue.Goals)) end

        ApplyQueuedBackgroundGoal(characterId, queue.Goals)
    end
end

---Finishes the application of any queued background goals by restoring the player's background id.
---@param characterId GUIDSTRING The ID of the character.
---@param status string Whether the goal was "Completed" or "Failed".
---@return boolean True if a queued goal was finished, false otherwise.
local function FinishBackgroundGoalApplication(characterId, status)
    local removeIndex = -1

    ---@type PlayerBackgroundGoalQueue
    local playerQueue = queuedBackgroundGoals[characterId]
    if not playerQueue then
        return false
    end

    for index, goal in ipairs(playerQueue.Goals) do
        if goal.Status == QueuedBackgroundGoalStatus.Committing then
            if bDebug then Ext.Log.Print(status .. " queued background goal for character " .. tostring(characterId) .. " goal " .. tostring(goal.Goal)) end

            removeIndex = index

            local player = Ext.Entity.Get(characterId)
            player.Background.Background = playerQueue.CurrentBackgroundId
        end
    end

    if removeIndex > 0 then
        table.remove(playerQueue.Goals, removeIndex)
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
    if bDebug then Ext.Log.Print("BackgroundGoalFailed called for character " .. tostring(character) .. " goal " .. tostring(goal)) end

    -- Check queued background goals to make sure we don't double queue
    if FinishBackgroundGoalApplication(character, "Failed") then
        return
    end

    local player = Ext.Entity.Get(character)

    if not player then
        if bDebug then Ext.Log.PrintError("BackgroundGoalFailed: Could not find entity for character " .. tostring(character)) end
        return
    end

    if not HasPastLifeRegressionTag(player) then
        if bDebug then Ext.Log.Print(player .. " does not have Past Life Regressions tag, ignoring.") end
        return
    end

    if not player.Background or not player.Background.Background then
        if bDebug then Ext.Log.PrintError("BackgroundGoalFailed: Could not find background component for character " .. tostring(character)) end
        return
    end

    -- Get the corresponding background goal
    ---@type ResourceBackgroundGoal
    local goalResource = Ext.StaticData.Get(goal, Ext.Enums.ExtResourceManagerType.BackgroundGoal)
    if not goalResource then
        if bDebug then Ext.Log.PrintError("BackgroundGoalFailed: Could not find background goal for GUID " .. tostring(goal)) end
        return
    end

    local playerQueue = queuedBackgroundGoals[character]
    if not playerQueue then
        playerQueue = {
            CurrentBackgroundId = player.Background.Background,
            Goals = {}
        }
        queuedBackgroundGoals[character] = playerQueue
    end

    -- Queue applying the background goal
    ---@type QueuedBackgroundGoal
    local queuedGoal = {
        Goal = goal,
        GoalBackgroundId = goalResource.BackgroundUuid,
        Category = "PastLifeRegressions",
        Status = QueuedBackgroundGoalStatus.Added
    }
    
    table.insert(playerQueue.Goals, queuedGoal)
end

--- Example: E6[Server]: BackgroundGoalFailed called for character Elves_Female_Everic_Player_b094fac2-9324-544d-76b2-e2a300399034 goal 92f75626-3bdd-4bb8-b5a5-2750c5e61c0d
---@param character CHARACTER The character the goal was being applied to.
---@param goal GUIDSTRING The id of the goal being rewarded.
local function BackgroundGoalRewarded(character, goal)
    if bDebug then Ext.Log.Print("BackgroundGoalRewarded called for character " .. tostring(character) .. " goal " .. tostring(goal)) end
    FinishBackgroundGoalApplication(character, "Completed")
end

--- If there are pending background goals to apply, moves them along.
local function BackgroundGoalsTick(tickParams)
    ApplyQueuedBackgroundGoals()
end

local function PastLifeToggleDebug()
    bDebug = not bDebug
    Ext.Log.Print("Past Life Regressions debug mode set to " .. tostring(bDebug))
end

function Init_PastLifeRegressions()
    if bDebug then Ext.Log.Print("Initializing Past Life Regressions Script Extender") end

    -- Processes any pending background goals to apply.
    Ext.Events.Tick:Subscribe(BackgroundGoalsTick)

    -- Handles identifying when background goals fail and succeed to refine the queue.
    Ext.Osiris.RegisterListener("BackgroundGoalFailed", 2, "before", BackgroundGoalFailed)
    Ext.Osiris.RegisterListener("BackgroundGoalRewarded", 2, "after", BackgroundGoalRewarded)

    Ext.RegisterConsoleCommand("PastLifeToggleDebug", PastLifeToggleDebug)
end