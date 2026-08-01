--!strict
--[[
	TrackPieceTemplates
	Builds ONE Straight and ONE Curve track-piece model once, at
	CFrame.new(0, 0, 0), and stores them under ReplicatedStorage.Assets.
	TrackPieceTemplates — TrackGenerator clones + repositions
	(Model:PivotTo) one of these per oval segment instead of instantiating
	fresh Road/Barrier Parts from scratch on every GenerateOval/Regenerate()
	call.

	Unlike FanBoxCrowdTemplates, this isn't fixing an expensive-CSG problem
	— TrackPieceBuilder never used UnionAsync; plain Part creation was
	already cheap. This exists because it was explicitly requested
	("generate and save curve and straight segments first, save in assets,
	call as needed"), and it does have real benefits: one source-of-truth
	piece per shape, and TrackGenerator.Regenerate() (which runs after
	every Grand Prix) no longer re-derives road/barrier geometry from
	scratch each time, just clones + recolors.

	Each template gets an invisible "EntryPivot" Part at CFrame.new(0,0,0)
	(where the piece's ENTRY point was when the template was built) set as
	the model's PrimaryPart, specifically so Model:PivotTo(actualEntryCFrame)
	repositions the WHOLE piece (however many Road/Barrier/RoadChord parts
	it has) as one rigid group, correctly reproducing what building it
	fresh at that CFrame would have looked like. Without an explicit
	pivot part at the exact entry point, PivotTo would fall back to the
	model's bounding-box-derived default pivot, which does NOT line up
	with the entry point TrackGenerator's chaining math expects — the
	whole piece would land offset from where it should be.

	Templates carry no theme — they're built with TrackPieceBuilder's own
	plain default Color/Material. TrackGenerator applies a theme to a clone
	after PivotTo by recoloring its Road/RoadChord_*/Barrier descendants
	directly (a property set, not a rebuild).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrackPieceBuilder = require(script.Parent:WaitForChild("TrackPieceBuilder"))

local TrackPieceTemplates = {}

local function addEntryPivot(model: Model) : Part
	local pivot = Instance.new("Part")
	pivot.Anchored = true
	pivot.CanCollide = false
	pivot.CanQuery = false
	pivot.Transparency = 1
	pivot.Size = Vector3.new(1, 1, 1)
	pivot.CFrame = CFrame.new(0, 0, 0) -- templates are always built at the world origin
	pivot.Name = "EntryPivot"
	pivot.Parent = model
	model.PrimaryPart = pivot
	return pivot
end

local templatesFolder: Folder? = nil

-- Builds both templates and stores them under ReplicatedStorage.Assets.
-- TrackPieceTemplates. Cheap (plain Part creation, no yielding) — meant to
-- be called once, at server start, before TrackGenerator's first
-- GenerateOval.
function TrackPieceTemplates.BuildAll() : Folder
	local folder = Instance.new("Folder")
	folder.Name = "TrackPieceTemplates"

	local straightModel = TrackPieceBuilder.BuildStraight(CFrame.new(0, 0, 0), nil, nil)
	addEntryPivot(straightModel)
	straightModel.Name = "Straight"
	straightModel.Parent = folder

	local curveModel = TrackPieceBuilder.BuildCurve(CFrame.new(0, 0, 0), nil, nil, nil, nil)
	addEntryPivot(curveModel)
	curveModel.Name = "Curve"
	curveModel.Parent = folder

	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets") :: Folder?
	if assetsFolder == nil then
		local newAssetsFolder = Instance.new("Folder")
		newAssetsFolder.Name = "Assets"
		newAssetsFolder.Parent = ReplicatedStorage
		assetsFolder = newAssetsFolder
	end
	folder.Parent = assetsFolder

	templatesFolder = folder
	return folder
end

function TrackPieceTemplates.GetTemplate(shape: "Straight" | "Curve") : Model?
	if templatesFolder == nil then
		return nil
	end
	local template = templatesFolder:FindFirstChild(shape)
	if template ~= nil and template:IsA("Model") then
		return template
	end
	return nil
end

return TrackPieceTemplates
