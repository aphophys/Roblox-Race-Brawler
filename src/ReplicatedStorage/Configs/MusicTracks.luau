--!strict
--[[
	MusicTracks
	The looping background music beds, kept separate from SoundEffects
	because they are a different KIND of sound and the difference is
	load-bearing rather than cosmetic:

	  - a music bed loops forever and there is exactly one playing at a time,
	    so it is owned and swapped, not fired and forgotten;
	  - it is deliberately quiet enough to sit under every effect in
	    SoundEffects (whose volumes run 0.4-0.7), because music that competes
	    with the countdown beeps or a hazard cue is actively harmful — a racer
	    needs to hear the thing that costs them a life.

	Which bed plays is decided by the Grand Prix state alone, not by whether
	the local player entered the race: a Grand Prix is a server-wide event
	that takes over the stadium leaderboards for everyone (see
	LeaderboardBuilder), so the room should sound like it too. One rule drives
	both, instead of the music and the boards disagreeing about whether a race
	is happening.

	Same permissions caveat as SoundEffects: an id that will not load must
	degrade to silence, never to an error.
]]

export type MusicTrack = {
	AssetId: string,
	Volume: number,
}

export type MusicTracksType = { [string]: MusicTrack }

-- 0.12 against effects at 0.4-0.7 — audible as a bed, roughly a third of the
-- quietest effect, which is what "low volume only" has to mean if the
-- countdown and hazard cues are to stay legible over it.
local BED_VOLUME = 0.12

local MusicTracks: MusicTracksType = {
	-- Plays whenever no Grand Prix is running: the Hub, free-play laps,
	-- everything that is not the main event.
	Arcade = { AssetId = "rbxassetid://110662907164248", Volume = BED_VOLUME },
	-- Countdown through to the winner announcement.
	GrandPrix = { AssetId = "rbxassetid://114882049925780", Volume = BED_VOLUME },
}

return MusicTracks
