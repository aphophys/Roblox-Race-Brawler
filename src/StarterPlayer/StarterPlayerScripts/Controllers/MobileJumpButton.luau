--!strict
--[[
	MobileJumpButton
	A stand-in jump button for touch devices, created ONLY when Roblox's own
	one is genuinely missing.

	## Why this exists

	Reported from a real phone: the native jump button does not appear. It does
	appear in Studio's device emulator, and nothing in this codebase suppresses
	it — there is no SetCoreGuiEnabled call, no UserInputService.ModalEnabled, no
	DevTouchMovementMode override, ContextActionService is bound with
	createTouchButton = false and every handler returns ContextActionResult.Pass,
	and a hit test across the whole of the jump button's rect returns no HUD
	element of ours. The cause could not be reproduced or observed on the device,
	so this is a guarantee rather than a diagnosis: if the platform's button is
	there, we leave it strictly alone; if it is not, the player still gets to
	jump.

	## Why it is conditional rather than always-on

	Two jump buttons stacked on the same spot is a worse bug than one missing
	one — a tap would fire both, and the player would have no way to tell which
	control they were using. So this checks for the real one first and stands
	down if it finds it. The check is deliberately loose (any GuiButton under
	TouchGui whose name mentions "jump") because the button's exact path differs
	between Roblox's touch schemes, and being wrong in the direction of "assume
	it exists" is the safe error: the player keeps the native control.

	It is also re-checked on respawn and re-polled for a few seconds after
	joining, because the control scheme is set up asynchronously — deciding once,
	immediately, would always decide "missing".

	## Position

	Taken from ResponsiveLayoutController.GetJumpButtonRect, the same function
	the skill-button arc uses to decide what to avoid, so this drops exactly into
	the gap the arc leaves. Muscle memory is the whole point of a jump button, so
	it goes where the platform would have put it, at the size the platform would
	have used.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ResponsiveLayoutController = require(script.Parent.Parent:WaitForChild("UI_And_Visuals"):WaitForChild("ResponsiveLayoutController"))

local localPlayer = Players.LocalPlayer

-- The control scheme is built asynchronously after the player joins, so the
-- native button can legitimately be absent for a moment. Poll across this
-- window before concluding it is really missing.
local DETECT_POLL_SECONDS = 1
local DETECT_ATTEMPTS = 8

local MobileJumpButton = {}

local button: TextButton? = nil
local holding = false

local function playerGui() : PlayerGui?
	return localPlayer:FindFirstChild("PlayerGui") :: PlayerGui?
end

-- Any visible GuiButton under TouchGui that calls itself a jump button. Loose
-- on purpose — see the module docstring on why a false positive is the safe
-- direction to be wrong in.
local function findNativeJumpButton() : GuiButton?
	local gui = playerGui()
	local touchGui = gui and gui:FindFirstChild("TouchGui")
	if touchGui == nil then
		return nil
	end
	for _, descendant in touchGui:GetDescendants() do
		if descendant:IsA("GuiButton") and string.find(string.lower(descendant.Name), "jump") ~= nil then
			return descendant
		end
	end
	return nil
end

local function nativeJumpButtonPresent() : boolean
	local native = findNativeJumpButton()
	return native ~= nil and native.Visible
end

local function humanoid() : Humanoid?
	local character = localPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function destroyButton()
	if button ~= nil then
		button:Destroy()
		button = nil
	end
	holding = false
end

-- Styled to read as a platform control rather than one of the game's own
-- capsule buttons: a plain translucent circle. No image asset, deliberately —
-- a missing texture would leave an invisible control, which is the exact
-- failure this module exists to fix.
local function createButton(mainHud: ScreenGui, centre: Vector2, half: number)
	destroyButton()

	local newButton = Instance.new("TextButton")
	newButton.Name = "MobileJumpButton"
	newButton.AnchorPoint = Vector2.new(0.5, 0.5)
	newButton.Size = UDim2.fromOffset(half * 2, half * 2)
	newButton.Position = UDim2.fromOffset(centre.X, centre.Y)
	newButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	newButton.BackgroundTransparency = 0.45
	newButton.BorderSizePixel = 0
	newButton.Text = "JUMP"
	newButton.TextColor3 = Color3.fromRGB(40, 40, 45)
	newButton.Font = Enum.Font.GothamBold
	newButton.TextSize = math.max(12, math.floor(half * 0.42))
	newButton.AutoButtonColor = true
	newButton.ZIndex = 2

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = newButton

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = newButton

	-- Held, not tapped: the native button jumps repeatedly while your thumb is
	-- down, and a control that only fires once per tap feels broken next to it.
	-- Humanoid.Jump is re-set every frame rather than once on press because the
	-- humanoid clears it as soon as the jump starts.
	newButton.MouseButton1Down:Connect(function()
		holding = true
	end)
	newButton.MouseButton1Up:Connect(function()
		holding = false
	end)
	-- A thumb that slides off the button must not leave it stuck held.
	newButton.MouseLeave:Connect(function()
		holding = false
	end)

	newButton.Parent = mainHud
	button = newButton
end

local function refresh()
	local gui = playerGui()
	local mainHud = gui and gui:FindFirstChild("MainHUD") :: ScreenGui?
	if mainHud == nil then
		return
	end

	if not ResponsiveLayoutController.IsMobile() or nativeJumpButtonPresent() then
		destroyButton()
		return
	end

	local viewport = workspace.CurrentCamera.ViewportSize
	local centre, half = ResponsiveLayoutController.GetJumpButtonRect(viewport)
	createButton(mainHud, centre, half)
end

function MobileJumpButton.Init()
	localPlayer:WaitForChild("PlayerGui"):WaitForChild("MainHUD")

	RunService.RenderStepped:Connect(function()
		if not holding then
			return
		end
		local character = localPlayer.Character
		local humanoidInstance = character and character:FindFirstChildOfClass("Humanoid")
		if humanoidInstance ~= nil and humanoidInstance:GetState() ~= Enum.HumanoidStateType.Dead then
			humanoidInstance.Jump = true
		end
	end)

	-- Re-decide whenever anything that could change the answer changes: the
	-- layout verdict, the viewport (the native button's size and position both
	-- depend on it, so ours must move too), and a respawn.
	localPlayer:GetAttributeChangedSignal("ForceMobileLayout"):Connect(refresh)
	localPlayer.CharacterAdded:Connect(function()
		task.wait(1)
		refresh()
	end)
	local camera = workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(refresh)
	end

	-- The control scheme is not up yet at Init; poll briefly rather than
	-- deciding once against a PlayerGui that has not finished populating.
	task.spawn(function()
		for _ = 1, DETECT_ATTEMPTS do
			task.wait(DETECT_POLL_SECONDS)
			refresh()
			if nativeJumpButtonPresent() then
				break
			end
		end
	end)
end

-- Test/diagnostic surface: what the module decided and why. Reading this on a
-- real device is the only way to tell "the native button is missing" apart from
-- "our detection missed it".
function MobileJumpButton.GetStatus() : { [string]: any }
	local native = findNativeJumpButton()
	local gui = playerGui()
	local mainHud = gui and gui:FindFirstChild("MainHUD")
	return {
		IsMobile = ResponsiveLayoutController.IsMobile(),
		NativeFound = native ~= nil,
		NativeName = if native ~= nil then native:GetFullName() else "",
		NativeVisible = native ~= nil and native.Visible,
		-- Read off the DataModel, not the `button` local: requiring this module
		-- from a separate VM (an MCP execute_luau, a test harness) yields a fresh
		-- copy whose locals are nil while the running instance's button is very
		-- much alive, which reads as "the fallback never spawned".
		FallbackActive = mainHud ~= nil and mainHud:FindFirstChild("MobileJumpButton") ~= nil,
	}
end

return MobileJumpButton
