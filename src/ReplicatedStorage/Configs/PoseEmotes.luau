--!strict
--[[
	PoseEmotes
	The emotes the Fan Box POSE button can play, and the order it cycles
	them in.

	## Why these specific names

	Every entry is one of Roblox's BUILT-IN emotes, played through
	`Humanoid:PlayEmote(name)`. That matters for two reasons:

	  - they are free and always available, with no catalog asset to load, no
	    permissions to lose, and nothing to moderate away — the same failure
	    mode SoundEffects documents for audio would otherwise apply here;
	  - PlayEmote is a HUMANOID call made on the server, so the animation
	    replicates to everyone watching from the stands without a remote of
	    our own.

	PlayEmote only works on R15 rigs and can refuse for reasons outside this
	game's control, so every caller must treat it as best-effort — see
	TeleportPoseService.PerformPose, where a refused emote still pays the
	player and still fires the crowd reaction. A pose that silently plays no
	animation is a disappointment; a pose that eats the player's ten-minute
	reward because an animation would not load is a bug.

	## Shared, and validated server-side anyway

	In ReplicatedStorage because the client cycles through the list to decide
	what to ASK for. The server re-reads this same module and refuses anything
	not in it, so the client choosing the id is a convenience, not authority —
	the same split QuestDefinitions uses.
]]

export type PoseEmote = {
	Id: string,
	DisplayName: string,
	-- Name passed to Humanoid:PlayEmote. Lowercase because that is what
	-- Roblox's built-in emote table is keyed by.
	EmoteName: string,
}

export type PoseEmotesType = {
	Ordered: { PoseEmote },
	ById: { [string]: PoseEmote },
}

local ordered: { PoseEmote } = {
	-- Wave leads because it is what the button already sent before there was
	-- a list, so an old client that still asks for "Wave" by name keeps
	-- working rather than being refused.
	{ Id = "Wave", DisplayName = "Wave", EmoteName = "wave" },
	{ Id = "Cheer", DisplayName = "Cheer", EmoteName = "cheer" },
	{ Id = "Point", DisplayName = "Point", EmoteName = "point" },
	{ Id = "Laugh", DisplayName = "Laugh", EmoteName = "laugh" },
	{ Id = "Dance", DisplayName = "Dance", EmoteName = "dance" },
	{ Id = "Dance2", DisplayName = "Dance II", EmoteName = "dance2" },
	{ Id = "Dance3", DisplayName = "Dance III", EmoteName = "dance3" },
}

local byId: { [string]: PoseEmote } = {}
for _, emote in ordered do
	byId[emote.Id] = emote
end

local PoseEmotes: PoseEmotesType = {
	Ordered = ordered,
	ById = byId,
}

return PoseEmotes
