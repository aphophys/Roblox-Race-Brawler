--!strict
--[[
	ReservedServerTokens
	In-memory registry of TeleportService reserved-server access codes used
	to route players into dedicated Grand Prix server instances.
]]

export type ReservedServerToken = {
	AccessCode: string,
	CreatedAt: number, -- os.time()
	GrandPrixId: string,
}

local ReservedServerTokens = {}

local activeTokens: { [string]: ReservedServerToken } = {}

function ReservedServerTokens.Register(token: ReservedServerToken)
	activeTokens[token.AccessCode] = token
end

function ReservedServerTokens.Get(accessCode: string) : ReservedServerToken?
	return activeTokens[accessCode]
end

return ReservedServerTokens
