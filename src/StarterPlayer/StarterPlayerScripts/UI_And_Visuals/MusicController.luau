--!strict
--[[
	MusicController
	Owns the single looping music bed and swaps it when the Grand Prix state
	changes. Client-side because music is per-listener by definition: a Sound
	created on the server under SoundService would either play for everyone
	from one shared TimePosition or not replicate at all, and neither is what
	a background bed wants.

	## One bed at a time, cross-faded

	Both tracks exist as Sound instances for the session and are never
	destroyed — recreating a Sound restarts its buffering, which is audible as
	a gap at exactly the moment the countdown starts. Instead the outgoing bed
	fades to 0 and pauses while the incoming one fades up. Pause, not Stop, so
	returning to the Arcade bed after a race resumes the loop mid-phrase
	instead of restarting the same opening bar after every Grand Prix.

	## Why the state alone decides

	`GrandPrixStateChanged` is broadcast to EVERY player, not just entrants
	(GrandPrixManager.broadcastState), so this needs no knowledge of whether
	the local player joined — which is the point. The stadium leaderboards
	switch to the live race for the whole server; the music follows the same
	rule so the two can never disagree about whether a race is happening.

	A track id that fails to load leaves its Sound silent and everything else
	works normally — same contract as SoundEffects.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local MusicTracks = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("MusicTracks"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

-- Long enough not to sound like a hard cut, short enough that the Grand Prix
-- bed is established before the countdown beeps start.
local CROSSFADE_SECONDS = 1.5

local MusicController = {}

local soundByTrackId: { [string]: Sound } = {}
local currentTrackId: string? = nil

local function getSound(trackId: string) : Sound?
	local existing = soundByTrackId[trackId]
	if existing ~= nil then
		return existing
	end

	local definition = MusicTracks[trackId]
	if definition == nil or definition.AssetId == "" then
		return nil
	end

	local sound = Instance.new("Sound")
	sound.SoundId = definition.AssetId
	sound.Looped = true
	-- Starts silent; the fade below is what makes it audible, so a bed can
	-- never blare for one frame at full volume before the tween takes over.
	sound.Volume = 0
	sound.Name = `Music_{trackId}`
	sound.Parent = SoundService
	soundByTrackId[trackId] = sound
	return sound
end

local function fadeTo(sound: Sound, volume: number, thenPause: boolean)
	local tween = TweenService:Create(sound, TweenInfo.new(CROSSFADE_SECONDS), { Volume = volume })
	if thenPause then
		-- Pause only when this fade is still the most recent thing to have
		-- happened to the sound; a fast Waiting -> Countdown -> Waiting bounce
		-- would otherwise pause a bed that has since been faded back up.
		tween.Completed:Once(function()
			if sound.Volume <= 0.001 then
				sound:Pause()
			end
		end)
	end
	tween:Play()
end

-- Switches the bed. Safe to call with the track that is already playing —
-- that is the common case, since the state broadcast repeats on a cycle.
function MusicController.SetTrack(trackId: string)
	if currentTrackId == trackId then
		return
	end

	local incoming = getSound(trackId)
	if incoming == nil then
		return -- unloadable id: leave whatever is playing rather than going silent
	end

	if currentTrackId ~= nil then
		local outgoing = soundByTrackId[currentTrackId]
		if outgoing ~= nil then
			fadeTo(outgoing, 0, true)
		end
	end

	currentTrackId = trackId
	incoming:Resume() -- a no-op on a sound that was never paused
	if not incoming.IsPlaying then
		incoming:Play()
	end
	fadeTo(incoming, MusicTracks[trackId].Volume, false)
end

-- "Ended" keeps the Grand Prix bed running through the winner announcement
-- and the payout, which is the whole point of it being a separate track —
-- the race is not over for the player until they have seen what they won.
local function trackForGrandPrixState(state: string) : string
	if state == "Countdown" or state == "Racing" or state == "Ended" then
		return "GrandPrix"
	end
	return "Arcade"
end

function MusicController.Init()
	MusicController.SetTrack("Arcade")

	Network.Track.GrandPrixStateChanged.OnClientEvent:Connect(function(state: unknown)
		if typeof(state) == "string" then
			MusicController.SetTrack(trackForGrandPrixState(state))
		end
	end)
end

return MusicController
