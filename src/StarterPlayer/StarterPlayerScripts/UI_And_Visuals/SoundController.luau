--!strict
--[[
	SoundController
	Plays the 2D half of the sound system — the ones that belong to one
	player and shouldn't be spatialised or heard by anyone else (gold, fans,
	purchases, a refused cast). The 3D half is created server-side directly
	on the world part it belongs to; see SoundDirector.

	Sounds are parented to SoundService rather than to the PlayerGui so they
	survive a character respawn mid-playback, and are pooled per key: playing
	the same key twice in quick succession restarts the one Sound instead of
	stacking two copies, which is what a double gold payout used to sound
	like.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local SoundEffects = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SoundEffects"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

local SoundController = {}

local pooledByKey: { [string]: Sound } = {}

local function getSound(soundKey: string) : Sound?
	local existing = pooledByKey[soundKey]
	if existing ~= nil then
		return existing
	end

	local definition = SoundEffects[soundKey]
	if definition == nil or definition.AssetId == "" then
		return nil
	end

	local sound = Instance.new("Sound")
	sound.SoundId = definition.AssetId
	sound.Volume = definition.Volume
	sound.Name = `SFX_{soundKey}`
	sound.Parent = SoundService
	pooledByKey[soundKey] = sound
	return sound
end

function SoundController.Play(soundKey: string)
	local sound = getSound(soundKey)
	if sound == nil then
		return
	end
	sound.TimePosition = 0
	sound:Play()
end

function SoundController.Init()
	Network.Track.PlaySound.OnClientEvent:Connect(function(soundKey: unknown)
		if typeof(soundKey) == "string" then
			SoundController.Play(soundKey)
		end
	end)
end

return SoundController
