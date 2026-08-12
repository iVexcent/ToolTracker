--!strict
--[[

	ToolTracker monitors a player's Backpack and Character for Tool state changes.
	It emits events for ToolAdded, ToolEquipped, ToolUnequipped, and ToolRemoved.

	The tracker treats a Tool's location as its state:
		Backpack, Character, or Other.
	
--]]

const ToolParentState = table.freeze({
	Backpack  = 1,
	Character = 2,
	Other     = 3,
})

type ToolParentState = index<typeof(ToolParentState), keyof<typeof(ToolParentState)>>

--[[
    ----------------------------------------------------------------------------
	-<[ HELPERS ]>--------------------------------------------------------------
	----------------------------------------------------------------------------
--]]

local function connectAndTrack(self: ToolTracker, signal: RBXScriptSignal, callback: (...any) -> ...any)
	local conn = signal:Connect(callback)
	table.insert(self._connections, conn)
end

local function clearConnections(self: ToolTracker)
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
end

--[[
    ----------------------------------------------------------------------------
	-<[ PRIVATE ]>--------------------------------------------------------------
	----------------------------------------------------------------------------
--]]

local function onStateChanged(self: ToolTracker, tool: Tool, prevState: ToolParentState, currState: ToolParentState)
	--[[
	    State Transition Table (Previous -> Current):
	    States: Backpack (B), Character (C), Other (O)

	    FROM BACKPACK (B)
	        B -> B : None
	        B -> C : Equip
	        B -> O : Remove

	    FROM CHARACTER (C)
	        C -> B : Unequip
	        C -> C : None
	        C -> O : Unequip -> Remove

	    FROM OTHER (O)
	        O -> B : Add
	        O -> C : Add -> Equip
	        O -> O : None
	--]]

	if prevState == ToolParentState.Backpack then
		if currState == ToolParentState.Character then
			self._toolEquippedEvent:Fire(tool)
		elseif currState == ToolParentState.Other then
			self._toolRemovedEvent:Fire(tool)
		end

	elseif prevState == ToolParentState.Character then
		if currState == ToolParentState.Backpack then
			self._toolUnequippedEvent:Fire(tool)
		elseif currState == ToolParentState.Other then
			self._toolUnequippedEvent:Fire(tool)
			self._toolRemovedEvent:Fire(tool)
		end

	elseif prevState == ToolParentState.Other then
		if currState == ToolParentState.Backpack then
			self._toolAddedEvent:Fire(tool)
		elseif currState == ToolParentState.Character then
			self._toolAddedEvent:Fire(tool)
			self._toolEquippedEvent:Fire(tool)
		end
	end
end

local function onParentChanged(self: ToolTracker, tool: Instance)
	if not tool:IsA("Tool") then
		return
	end
	
	-- tools not present in the state map are treated as originating from Other
	local prevState = self._toolStateMap[tool] or ToolParentState.Other

	local currState = if tool.Parent == self._backpack then ToolParentState.Backpack
		elseif tool.Parent == self._character then ToolParentState.Character
		else ToolParentState.Other

	if prevState == currState then
		return
	end

	onStateChanged(self, tool, prevState, currState)

	-- only retain Tools currently inside a tracked container.
	-- removing the entry makes a later re-entry start from Other again.
	self._toolStateMap[tool] = if currState == ToolParentState.Other then nil else currState
end

local function observeContainer(self: ToolTracker, container: Backpack | Model)
	connectAndTrack(self, container.ChildAdded, function(child: Instance)
		onParentChanged(self, child)
	end)

	connectAndTrack(self, container.ChildRemoved, function(child: Instance)
		onParentChanged(self, child)
	end)
	
	-- process existing children so tracking starts in sync with the container
	for _, child in container:GetChildren() do
		onParentChanged(self, child)
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
	
	-- flush all tracked Tools through the normal exit transition before clearing state.
	-- this guarantees listeners receive Unequipped/Removed events when
	-- tracking is stopped or switched to another container pair.
	for tool, state in self._toolStateMap do
		onStateChanged(self, tool, state, ToolParentState.Other)
	end
	table.clear(self._toolStateMap)

	self._backpack = nil
	self._character = nil
end

--[[
    ----------------------------------------------------------------------------
	-<[ PUBLIC ]>---------------------------------------------------------------
	----------------------------------------------------------------------------
--]]

local ToolTracker = {}
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

		_toolStateMap = {} :: {[Tool]: ToolParentState},
		_connections  = {} :: {RBXScriptConnection},
		_destroyed    = false,

		_toolAddedEvent = toolAddedEvent,
		ToolAdded = toolAddedEvent.Event,

		_toolRemovedEvent = toolRemovedEvent,
		ToolRemoved = toolRemovedEvent.Event,

		_toolEquippedEvent = toolEquippedEvent,
		ToolEquipped = toolEquippedEvent.Event,

		_toolUnequippedEvent = toolUnequippedEvent,
		ToolUnequipped = toolUnequippedEvent.Event,

	}, ToolTracker)

	return self	
end

function ToolTracker.Track(self: ToolTracker, backpack: Backpack, character: Model)
	if self._destroyed then
		error("ToolTracker:Track() cannot be called after Destroy()", 2)
	end

	if not backpack:IsA("Backpack") then
		error(`expected Backpack, got {backpack.ClassName}`, 2)
	end

	if not character:IsA("Model") then
		error(`expected Model, got {character.ClassName}`, 2)
	end

	if self._backpack == backpack and self._character == character then
		-- re-tracking the same containers would reprocess their existing children
		-- and emit duplicate Added/Equipped events.
		return
	end
	
	detachContainers(self)
	attachContainers(self, backpack, character)
end

function ToolTracker.GetTools(self: ToolTracker): {Tool}
	if self._destroyed then
		error("ToolTracker:GetTools() cannot be called after Destroy()", 2)
	end

	local tools = {}
	for tool in self._toolStateMap do
		tools[#tools + 1] = tool
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
