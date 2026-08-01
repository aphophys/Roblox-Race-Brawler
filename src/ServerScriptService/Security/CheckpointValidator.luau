--!strict
--[[
	CheckpointValidator
	Full-width wall checkpoint detection. Deliberately spatial-query based
	(workspace:GetPartsInPart against each checkpoint's trigger volume),
	never .Touched, so a fast-moving/high-ping character can't skip through
	a thin trigger without registering. Also rejects out-of-order ordinals
	to block checkpoint-skip exploits.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))

local CheckpointValidator = {}

-- Called on a fixed interval (not per-frame) for each racer's HRP.
-- Iterates checkpoint trigger parts and uses workspace:GetPartsInPart to
-- test overlap against the character's bounding parts.
function CheckpointValidator.PollRacer(player: Player, characterRootPart: BasePart, lastOrdinal: number) : number?
	-- TODO: for each segment in TrackBlueprints.OvalSegments with
	-- IsCheckpoint, workspace:GetPartsInPart(segment trigger part) and
	-- check if characterRootPart is among the results. Only accept an
	-- ordinal == lastOrdinal + 1 (or wraps back to 1 after the final one).
	return nil
end

function CheckpointValidator.Init()
	-- TODO: drive PollRacer from GrandPrixManager's per-racer loop.
end

return CheckpointValidator
