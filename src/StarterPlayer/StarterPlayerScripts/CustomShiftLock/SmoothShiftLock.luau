local SmoothShiftLock = {}
SmoothShiftLock.__index = SmoothShiftLock;
-- The shoulder offset (character space), applied as Humanoid.CameraOffset by HeadRotation (Midori,
-- 2026-10-18): moving Camera.CFrame after the camera's occlusion check put it inside walls on mobile
-- (black screen); CameraOffset is part of the camera's own focus, so occlusion accounts for it.
SmoothShiftLock.Offset = Vector3.zero;
-- Midori rework (2026-10-22, user: "improve smooth shiftlock" / "jittery when turning, mostly the
-- character"): the body turn is the ENGINE's, like Roblox's own shift lock: UserGameSettings.RotationType
-- = CameraRelative, so the Humanoid faces the camera inside its own physics step. Scripted turns were
-- tried the same day and both jittered: an AlignOrientation (camera shook) and a per-frame CFrame write
-- before the camera (the character shook). It is set every frame right after the camera module (which
-- writes its own RotationType) and handed back to MovementRelative when shift lock goes off. It stands
-- down while anything else steers the body (an AlignOrientation on the root: dashes, rushes, the
-- board), while ragdolled / knocked / carried / gripped / sitting, or when the root is anchored. The
-- shoulder-offset slide stays smooth (camOffsetSpring). One loop per character.

local Players = game:GetService("Players");
local WorkspaceService = game:GetService("Workspace");
local RunService = game:GetService("RunService");
local UserInputService = game:GetService("UserInputService");
local UserGameSettings = UserSettings():GetService("UserGameSettings");

local UtilsFolder = script:WaitForChild("Utils");

local Maid = require(UtilsFolder:WaitForChild("Maid"));
local Signal = require(UtilsFolder:WaitForChild("Signal"));
local Spring = require(UtilsFolder:WaitForChild("Spring"));

local LocalPlayer = Players.LocalPlayer;

local ToggleEvent = script:WaitForChild("ToggleShiftLock");
local EditConfig = script:WaitForChild("EditConfig");

local STEP_NAME = "MidoriShiftLockTurn";
-- Character attributes that mean something else owns the body's rotation.
local HANDS_OFF = { "Ragdolled", "Knocked", "Carried", "Gripped", "Cutscene" };

local config = {
	["MANUALLY_TOGGLEABLE"]         = true,
	["TRANSITION_SPRING_DAMPER"]    = 0.85,
	["CAMERA_TRANSITION_IN_SPEED"]  = 12,
	["CAMERA_TRANSITION_OUT_SPEED"] = 16,
	["LOCKED_CAMERA_OFFSET"]        = Vector3.new(1.75, 0.25, 0),
	["LOCKED_MOUSE_ICON"]           = "rbxasset://textures/MouseLockedCursor.png",
	["SHIFT_LOCK_KEYBINDS"]         = {Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl, Enum.KeyCode.DPadLeft} -- D-pad left = console (user, 2026-10-30; was L1)
}

local ENABLED = false;

function SmoothShiftLock:Init()
	local _managerMaid = Maid.new();
	SmoothShiftLock.ShiftLockToggled = Signal.new();

	if LocalPlayer.Character then
		coroutine.wrap(function()
			self:CharacterAdded();
		end)();
	end;

	_managerMaid:GiveTask(LocalPlayer.CharacterAdded:Connect(function()
		coroutine.wrap(function()
			self:CharacterAdded();
		end)();
	end));
end;

-- Is something else turning the body right now?
function SmoothShiftLock:_handsOff(): boolean
	if self.Humanoid.Sit or self.Humanoid.PlatformStand or self.RootPart.Anchored then
		return true;
	end;
	for _, attr in HANDS_OFF do
		if self.Character:GetAttribute(attr) then
			return true;
		end;
	end;
	for _, child in self.RootPart:GetChildren() do
		if child:IsA("AlignOrientation") and child.Enabled then
			return true;
		end;
	end;
	return false;
end;

function SmoothShiftLock:CharacterAdded()
	local self = setmetatable({}, SmoothShiftLock);
	self.Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait();
	self.RootPart = self.Character:WaitForChild("HumanoidRootPart");
	self.Humanoid = self.Character:WaitForChild("Humanoid");
	self.Head = self.Character:WaitForChild("Head");
	self.Camera = WorkspaceService.CurrentCamera;
	self._connectionsMaid = Maid.new();
	self.camOffsetSpring = Spring.new(Vector3.new(0, 0, 0));
	self.camOffsetSpring.Damper = config.TRANSITION_SPRING_DAMPER;

	self._steering = false;

	self._connectionsMaid:GiveTask(UserInputService.InputBegan:Connect(function(input, gpe)
		if (gpe) or not config.MANUALLY_TOGGLEABLE then return end;

		for _, keyBind in pairs(config.SHIFT_LOCK_KEYBINDS) do
			if (input.KeyCode == keyBind) and (self.Humanoid and self.Humanoid.Health ~= 0) then
				self:ToggleShiftLock(not ENABLED);
			end;
		end;
	end));

	self._connectionsMaid:GiveTask(RunService.RenderStepped:Connect(function()
		-- No shoulder offset in first person (the head fades out).
		SmoothShiftLock.Offset = if self.Head.LocalTransparencyModifier > 0.6 then Vector3.zero else self.camOffsetSpring.Position;

		if (ENABLED) and (UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter) then
			self:SetMouseState(ENABLED);
		end;

	end));

	-- The Humanoid faces the camera (engine-side) while on; after the camera module, which writes its own.
	RunService:BindToRenderStep(STEP_NAME, Enum.RenderPriority.Camera.Value + 1, function()
		local steer = ENABLED and not self:_handsOff();
		if steer then
			self.Humanoid.AutoRotate = true; -- the engine only turns the body with AutoRotate on
			UserGameSettings.RotationType = Enum.RotationType.CameraRelative;
		elseif self._steering and self.Head.LocalTransparencyModifier <= 0.6 then
			UserGameSettings.RotationType = Enum.RotationType.MovementRelative; -- first person keeps its own
		end;
		self._steering = steer;
	end);
	self._connectionsMaid:GiveTask(function()
		RunService:UnbindFromRenderStep(STEP_NAME);
		if self._steering then
			UserGameSettings.RotationType = Enum.RotationType.MovementRelative;
		end;
	end);

	self._connectionsMaid:GiveTask(ToggleEvent.Event:Connect(function(toggle: boolean)
		if (self.Humanoid and self.Humanoid.Health ~= 0) then
			self:ToggleShiftLock(toggle);
		end;
	end));

	self._connectionsMaid:GiveTask(EditConfig.Event:Connect(function(toChange, value)
		if config[toChange] ~= nil then
			config[toChange] = value;
		end;
	end));

	self._connectionsMaid:GiveTask(self.Humanoid.Died:Connect(function()
		self:CharacterDiedOrRemoved();
		return;
	end));

	self._connectionsMaid:GiveTask(LocalPlayer.CharacterRemoving:Connect(function()
		self:CharacterDiedOrRemoved();
		return;
	end));

	return self;
end;

function SmoothShiftLock:CharacterDiedOrRemoved()
	self:ToggleShiftLock(false);
	SmoothShiftLock.Offset = Vector3.zero;

	if self._connectionsMaid ~= nil then
		self._connectionsMaid:Destroy();
	end;
end;

function SmoothShiftLock:IsEnabled(): boolean
	return ENABLED;
end;

function SmoothShiftLock:SetMouseState(enable : boolean)
	UserInputService.MouseBehavior = (enable and Enum.MouseBehavior.LockCenter) or (Enum.MouseBehavior.Default);
end;

function SmoothShiftLock:SetMouseIcon(enable : boolean)
	UserInputService.MouseIcon = (enable and config.LOCKED_MOUSE_ICON :: string) or "";
end;

function SmoothShiftLock:TransitionLockOffset(enable : boolean)
	if (enable) then
		self.camOffsetSpring.Speed = config.CAMERA_TRANSITION_IN_SPEED;
		self.camOffsetSpring.Target = config.LOCKED_CAMERA_OFFSET;
	else
		self.camOffsetSpring.Speed = config.CAMERA_TRANSITION_OUT_SPEED;
		self.camOffsetSpring.Target = Vector3.new(0, 0, 0);
	end;
end;

-- The rotation itself runs in the character's RenderStepped (above); this only flips the state, so
-- calling it with the same value twice is harmless.
function SmoothShiftLock:ToggleShiftLock(enable : boolean)
	assert(typeof(enable) == typeof(false), "Enable value is not a boolean.");
	local changed = ENABLED ~= enable;
	ENABLED = enable;

	self:SetMouseState(ENABLED);
	self:SetMouseIcon(ENABLED);
	if self.camOffsetSpring then
		self:TransitionLockOffset(ENABLED);
	end;

	if changed then
		SmoothShiftLock.ShiftLockToggled:Fire(ENABLED);
	end;

	return self;
end;

return SmoothShiftLock;
