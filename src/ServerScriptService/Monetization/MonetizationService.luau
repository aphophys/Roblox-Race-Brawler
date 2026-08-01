--!strict
--[[
	MonetizationService
	Server-side game pass ownership checks (DoubleFans, a.k.a. "Rocket Fans
	and Gold" in the shop UI). Wraps MarketplaceService:
	UserOwnsGamePassAsync with a pcall (it's a web request and can fail/
	throttle) and refuses to check any pass whose MonetizationConfigs Id is
	still 0.

	Nothing calls this yet — DoubleFans would gate the fan-deposit payout
	calculation (not implemented, deposit flow is still a stub). The
	pose-unlock pass (ExclusivePoseBundle) is intentionally not in
	MonetizationConfigs right now — see that file's docstring.
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
