--!strict
--[[

	Monitors a player's Backpack and Character to provide a unified Tool state model.

	Guarantees consistent logical transitions (Added -> Equipped -> Unequipped -> Removed)
	based purely on physical parent changes. Tools entering from outside are treated
	as 'Added', and Tools leaving both tracked containers are treated as 'Removed'.

--]]

const ParentState = table.freeze({
	Backpack  = "Backpack"  :: "Backpack",
	Character = "Character" :: "Character",
	Other     = "Other"     :: "Other",
})

type ParentState = "Backpack" | "Character" | "Other"

--[[
	----------------------------------------------------------------------------
	-<[ HELPERS ]>--------------------------------------------------------------
	----------------------------------------------------------------------------
--]]

local function connectAndTrack(self: ToolTracker, signal: RBXScriptSignal, callback: (...any) -> ...any)
	local conn = signal:Connect(callback)
	table.insert(self._connList, conn)
end

local function clearConnections(self: ToolTracker)
	for _, conn in self._connList do
		conn:Disconnect()
	end
	table.clear(self._connList)
end

--[[
	----------------------------------------------------------------------------
	-<[ PRIVATE ]>--------------------------------------------------------------
	----------------------------------------------------------------------------
--]]

local function onStateChanged(self: ToolTracker, tool: Tool, prevState: ParentState, currState: ParentState)
	if prevState == ParentState.Backpack then
		if currState == ParentState.Character then
			self._toolEquippedEvent:Fire(tool)
		elseif currState == ParentState.Other then
			self._toolRemovedEvent:Fire(tool)
		end

	elseif prevState == ParentState.Character then
		if currState == ParentState.Backpack then
			self._toolUnequippedEvent:Fire(tool)
		elseif currState == ParentState.Other then
			self._toolUnequippedEvent:Fire(tool)
			self._toolRemovedEvent:Fire(tool)
		end

	elseif prevState == ParentState.Other then
		if currState == ParentState.Backpack then
			self._toolAddedEvent:Fire(tool)
		elseif currState == ParentState.Character then
			self._toolAddedEvent:Fire(tool)
			self._toolEquippedEvent:Fire(tool)
		end
	end
end

local function onParentChanged(self: ToolTracker, tool: Instance, parent: Instance?)
	if not tool:IsA("Tool") then
		return
	end

	-- tools not present in the state map are treated as originating from Other
	local prevState = self._toolMap[tool] or ParentState.Other
	local currState = if parent == self._backpack then ParentState.Backpack
		elseif parent == self._character then ParentState.Character
		else ParentState.Other

	if currState == prevState then
		return
	end

	-- only retain tools currently inside a tracked container
	-- removing the entry makes a later re-entry start from Other again
	self._toolMap[tool] = if currState == ParentState.Other then nil
		else currState

	onStateChanged(self, tool, prevState, currState)
end

local function observeContainer(self: ToolTracker, container: Backpack | Model)
	connectAndTrack(self, container.ChildAdded, function(child: Instance)
		onParentChanged(self, child, child.Parent)
	end)

	connectAndTrack(self, container.ChildRemoved, function(child: Instance)
		onParentChanged(self, child, child.Parent)
	end)

	for _, child in container:GetChildren() do
		onParentChanged(self, child, child.Parent)
	end
end

local function attachContainers(self: ToolTracker, backpack: Backpack, character: Model)
	self._backpack = backpack
	self._character = character

	observeContainer(self, backpack)
	observeContainer(self, character)
end

local function detachContainers(self: ToolTracker)
	clearConnections(self)

	self._backpack = nil
	self._character = nil

	-- flush all tracked tools through the exit transition
	-- this guarantees listeners receive Unequipped/Removed events
	for tool, state in self._toolMap do
		onStateChanged(self, tool, state, ParentState.Other)
	end
	table.clear(self._toolMap)
end

--[[
	----------------------------------------------------------------------------
	-<[ PUBLIC ]>---------------------------------------------------------------
	----------------------------------------------------------------------------
--]]

local ToolTracker = { ClassName = "ToolTracker" }
ToolTracker.__index = ToolTracker

export type ToolTracker = typeof(ToolTracker.new())

function ToolTracker.new()

	local toolAddedEvent = Instance.new("BindableEvent")
	local toolRemovedEvent = Instance.new("BindableEvent")
	local toolEquippedEvent = Instance.new("BindableEvent")
	local toolUnequippedEvent = Instance.new("BindableEvent")

	local self = setmetatable({

		_backpack  = nil :: Backpack?,
		_character = nil :: Model?,

		_toolMap  = {} :: {[Tool]: ParentState},
		_connList = {} :: {RBXScriptConnection},

		_toolAddedEvent = toolAddedEvent,
		ToolAdded = toolAddedEvent.Event,

		_toolRemovedEvent = toolRemovedEvent,
		ToolRemoved = toolRemovedEvent.Event,

		_toolEquippedEvent = toolEquippedEvent,
		ToolEquipped = toolEquippedEvent.Event,

		_toolUnequippedEvent = toolUnequippedEvent,
		ToolUnequipped = toolUnequippedEvent.Event,

		_destroyed = false,

	}, ToolTracker)

	return self
end

function ToolTracker.Track(self: ToolTracker, backpack: Backpack, character: Model)
	if self._destroyed then
		error(`[{self.ClassName}] call attempt after destroyed`, 2)
	end

	if not backpack:IsA("Backpack") then
		error(`[{self.ClassName}] expected Backpack, got {backpack.ClassName}`, 2)
	end

	if not character:IsA("Model") then
		error(`[{self.ClassName}] expected Model, got {character.ClassName}`, 2)
	end

	if self._backpack == backpack and self._character == character then
		-- re-tracking the same containers would reprocess their existing children
		-- and emit duplicate Added/Equipped events.
		return
	end

	detachContainers(self)
	attachContainers(self, backpack, character)
end

function ToolTracker.GetTools(self: ToolTracker)
	local tools = {}
	for tool in self._toolMap do
		table.insert(tools, tool)
	end

	return tools
end

function ToolTracker.Destroy(self: ToolTracker)
	if self._destroyed then
		return
	end

	self._destroyed = true
	detachContainers(self)

	self._toolAddedEvent:Destroy()
	self._toolRemovedEvent:Destroy()
	self._toolEquippedEvent:Destroy()
	self._toolUnequippedEvent:Destroy()
end

return ToolTracker
