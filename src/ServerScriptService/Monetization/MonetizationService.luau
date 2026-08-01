--!strict
--[[
	MonetizationService
	Server-side game pass ownership checks (DoubleFans, ExclusivePoseBundle).
	Wraps MarketplaceService:UserOwnsGamePassAsync with a pcall (it's a
	web request and can fail/throttle) and refuses to check any pass whose
	MonetizationConfigs Id is still 0.

	Nothing calls this yet — DoubleFans would gate the fan-deposit payout
	calculation (not implemented, deposit flow is still a stub) and
	ExclusivePoseBundle would gate PoseUIController's pose list (currently
	just fires a single hardcoded "Wave"). Wiring both in is future work.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfigs = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("MonetizationConfigs"))

local MonetizationService = {}

function MonetizationService.PlayerOwnsGamePass(player: Player, passKey: string) : boolean
	local passEntry = MonetizationConfigs.GamePasses[passKey]
	if passEntry == nil or passEntry.Id == 0 then
		return false
	end

	local success, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passEntry.Id)
	end)

	return success and owns == true
end

return MonetizationService
