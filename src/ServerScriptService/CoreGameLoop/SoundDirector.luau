--!strict
--[[
	SoundDirector
	Server-side entry point for playing a sound from SoundEffects, in the two
	shapes this game actually needs:

	  PlayAtPart(part, key)      -- 3D, heard by everyone nearby
	  PlayForPlayer(player, key) -- 2D, heard only by that player

	Why the split: a skill cast is an event in the world, so other racers
	should hear where it came from — creating the Sound on the server under
	the caster's own part gets spatialisation and replication for free, no
	remote needed. A cash-register ding for gold you just earned is not a
	world event; nobody else has any business hearing it, so that one goes
	over a remote and plays flat on the one client it belongs to.

	3D sounds are self-cleaning: Sound.Ended fires once and the instance is
	destroyed, so casts can't accumulate hundreds of dead Sound objects on a
	character over a long race. A hard task.delay fallback covers the case
	where Ended never fires because the asset failed to load.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundEffects = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SoundEffects"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

-- Nothing here is load-bearing, so an id that won't load must degrade to
-- silence rather than to an error — see SoundEffects' note on permissions.
local SOUND_CLEANUP_SECONDS = 10

local SoundDirector = {}

function SoundDirector.PlayAtPart(part: BasePart?, soundKey: string)
	if part == nil then
		return
	end

	local definition = SoundEffects[soundKey]
	if definition == nil or definition.AssetId == "" then
		return
	end

	local sound = Instance.new("Sound")
	sound.SoundId = definition.AssetId
	sound.Volume = definition.Volume
	sound.RollOffMaxDistance = definition.RollOffMaxDistance or 100
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.Name = `SFX_{soundKey}`
	sound.Parent = part
	sound:Play()

	sound.Ended:Once(function()
		sound:Destroy()
	end)
	-- Ended never fires for an asset that failed to load, so this is the
	-- backstop that stops those leaking.
	task.delay(SOUND_CLEANUP_SECONDS, function()
		if sound.Parent ~= nil then
			sound:Destroy()
		end
	end)
end

function SoundDirector.PlayForPlayer(player: Player, soundKey: string)
	local definition = SoundEffects[soundKey]
	if definition == nil or definition.AssetId == "" then
		return
	end
	Network.Track.PlaySound:FireClient(player, soundKey)
end

-- Convenience for the common "sound the caster and everyone near them"
-- case, since every skill manager needs exactly this.
function SoundDirector.PlayAtCharacter(player: Player, soundKey: string)
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	SoundDirector.PlayAtPart(rootPart, soundKey)
end

return SoundDirector
