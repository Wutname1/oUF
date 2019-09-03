local parent, ns = ...
local global = GetAddOnMetadata(parent, 'X-SUF')
local _VERSION = '@project-version@'
if (_VERSION:find('project%-version')) then
	_VERSION = 'devel'
end
ns.oUF = ns.SUF

local SUF = ns.SUF
local Private = SUF.Private

local argcheck = Private.argcheck
local error = Private.error
local print = Private.print
local unitExists = Private.unitExists

local styles, style = {}
local callback, objects, headers = {}, {}, {}

local elements = {}
local activeElements = {}

SUF.IsClassic = select(4, GetBuildInfo()) < 20000

local PetBattleFrameHider =
	CreateFrame('Frame', (global or parent) .. '_PetBattleFrameHider', UIParent, 'SecureHandlerStateTemplate')
PetBattleFrameHider:SetAllPoints()
PetBattleFrameHider:SetFrameStrata('LOW')
RegisterStateDriver(PetBattleFrameHider, 'visibility', '[petbattle] hide; show')

-- updating of "invalid" units.
local function enableTargetUpdate(object)
	object.onUpdateFrequency = object.onUpdateFrequency or .5
	object.__eventless = true

	local total = 0
	object:SetScript(
		'OnUpdate',
		function(self, elapsed)
			if (not self.unit) then
				return
			elseif (total > self.onUpdateFrequency) then
				self:UpdateAllElements('OnUpdate')
				total = 0
			end

			total = total + elapsed
		end
	)
end
Private.enableTargetUpdate = enableTargetUpdate

local function updateActiveUnit(self, event, unit)
	-- Calculate units to work with
	local realUnit, modUnit = SecureButton_GetUnit(self), SecureButton_GetModifiedUnit(self)

	-- _GetUnit() doesn't rewrite playerpet -> pet like _GetModifiedUnit does.
	if (realUnit == 'playerpet') then
		realUnit = 'pet'
	elseif (realUnit == 'playertarget') then
		realUnit = 'target'
	end

	if (modUnit == 'pet' and realUnit ~= 'pet') then
		modUnit = 'vehicle'
	end

	if (not unitExists(modUnit)) then
		return
	end

	-- Change the active unit and run a full update.
	if (Private.UpdateUnits(self, modUnit, realUnit)) then
		self:UpdateAllElements('RefreshUnit')

		return true
	end
end

local function iterateChildren(...)
	for i = 1, select('#', ...) do
		local obj = select(i, ...)

		if (type(obj) == 'table' and obj.isChild) then
			updateActiveUnit(obj, 'iterateChildren')
		end
	end
end

local function onAttributeChanged(self, name, value)
	if (name == 'unit' and value) then
		if (self.hasChildren) then
			iterateChildren(self:GetChildren())
		end

		if (not self:GetAttribute('SUF-onlyProcessChildren')) then
			updateActiveUnit(self, 'OnAttributeChanged')
		end
	end
end

local frame_metatable = {
	__index = CreateFrame('Button')
}
Private.frame_metatable = frame_metatable

for k, v in next, {
	--[[ frame:EnableElement(name, unit)
	Used to activate an element for the given unit frame.

	* self - unit frame for which the element should be enabled
	* name - name of the element to be enabled (string)
	* unit - unit to be passed to the element's Enable function. Defaults to the frame's unit (string?)
	--]]
	EnableElement = function(self, name, unit)
		argcheck(name, 2, 'string')
		argcheck(unit, 3, 'string', 'nil')

		local element = elements[name]
		if (not element or self:IsElementEnabled(name)) then
			return
		end

		if (element.enable(self, unit or self.unit)) then
			activeElements[self][name] = true

			if (element.update) then
				table.insert(self.__elements, element.update)
			end
		end
	end,
	--[[ frame:DisableElement(name)
	Used to deactivate an element for the given unit frame.

	* self - unit frame for which the element should be disabled
	* name - name of the element to be disabled (string)
	--]]
	DisableElement = function(self, name)
		argcheck(name, 2, 'string')

		local enabled = self:IsElementEnabled(name)
		if (not enabled) then
			return
		end

		local update = elements[name].update
		for k, func in next, self.__elements do
			if (func == update) then
				table.remove(self.__elements, k)
				break
			end
		end

		activeElements[self][name] = nil

		return elements[name].disable(self)
	end,
	--[[ frame:IsElementEnabled(name)
	Used to check if an element is enabled on the given frame.

	* self - unit frame
	* name - name of the element (string)
	--]]
	IsElementEnabled = function(self, name)
		argcheck(name, 2, 'string')

		local element = elements[name]
		if (not element) then
			return
		end

		local active = activeElements[self]
		return active and active[name]
	end,
	--[[ frame:Enable(asState)
	Used to toggle the visibility of a unit frame based on the existence of its unit. This is a reference to
	`RegisterUnitWatch`.

	* self    - unit frame
	* asState - if true, the frame's "state-unitexists" attribute will be set to a boolean value denoting whether the
	            unit exists; if false, the frame will be shown if its unit exists, and hidden if it does not (boolean)
	--]]
	Enable = RegisterUnitWatch,
	--[[ frame:Disable()
	Used to UnregisterUnitWatch for the given frame and hide it.

	* self - unit frame
	--]]
	Disable = function(self)
		UnregisterUnitWatch(self)
		self:Hide()
	end,
	--[[ frame:IsEnabled()
	Used to check if a unit frame is registered with the unit existence monitor. This is a reference to
	`UnitWatchRegistered`.

	* self - unit frame
	--]]
	IsEnabled = UnitWatchRegistered,
	--[[ frame:UpdateAllElements(event)
	Used to update all enabled elements on the given frame.

	* self  - unit frame
	* event - event name to pass to the elements' update functions (string)
	--]]
	UpdateAllElements = function(self, event)
		local unit = self.unit
		if (not unitExists(unit)) then
			return
		end

		assert(type(event) == 'string', "Invalid argument 'event' in UpdateAllElements.")

		if (self.PreUpdate) then
			--[[ Callback: frame:PreUpdate(event)
			Fired before the frame is updated.

			* self  - the unit frame
			* event - the event triggering the update (string)
			--]]
			self:PreUpdate(event)
		end

		for _, func in next, self.__elements do
			func(self, event, unit)
		end

		if (self.PostUpdate) then
			--[[ Callback: frame:PostUpdate(event)
			Fired after the frame is updated.

			* self  - the unit frame
			* event - the event triggering the update (string)
			--]]
			self:PostUpdate(event)
		end
	end
} do
	frame_metatable.__index[k] = v
end

local function onShow(self)
	if (not updateActiveUnit(self, 'OnShow')) then
		return self:UpdateAllElements('OnShow')
	end
end

local function updatePet(self, event, unit)
	local petUnit
	if (unit == 'target') then
		return
	elseif (unit == 'player') then
		petUnit = 'pet'
	else
		-- Convert raid26 -> raidpet26
		petUnit = unit:gsub('^(%a+)(%d+)', '%1pet%2')
	end

	if (self.unit ~= petUnit) then
		return
	end
	if (not updateActiveUnit(self, event)) then
		return self:UpdateAllElements(event)
	end
end

local function updateRaid(self, event)
	local unitGUID = UnitGUID(self.unit)
	if (unitGUID and unitGUID ~= self.unitGUID) then
		self.unitGUID = unitGUID

		self:UpdateAllElements(event)
	end
end

local function initObject(unit, style, styleFunc, header, ...)
	local num = select('#', ...)
	for i = 1, num do
		local object = select(i, ...)
		local objectUnit = object:GetAttribute('SUF-guessUnit') or unit
		local suffix = object:GetAttribute('unitsuffix')

		object.__elements = {}
		object.style = style
		object = setmetatable(object, frame_metatable)

		-- Expose the frame through SUF.objects.
		table.insert(objects, object)

		-- We have to force update the frames when PEW fires.
		object:RegisterEvent('PLAYER_ENTERING_WORLD', object.UpdateAllElements, true)

		-- Handle the case where someone has modified the unitsuffix attribute in
		-- SUF-initialConfigFunction.
		if (suffix and not objectUnit:match(suffix)) then
			objectUnit = objectUnit .. suffix
		end

		if (not (suffix == 'target' or objectUnit and objectUnit:match('target'))) then
			if not SUF.IsClassic then
				object:RegisterEvent('UNIT_ENTERED_VEHICLE', updateActiveUnit)
				object:RegisterEvent('UNIT_EXITED_VEHICLE', updateActiveUnit)
			end

			-- We don't need to register UNIT_PET for the player unit. We register it
			-- mainly because UNIT_EXITED_VEHICLE and UNIT_ENTERED_VEHICLE doesn't always
			-- have pet information when they fire for party and raid units.
			if (objectUnit ~= 'player') then
				object:RegisterEvent('UNIT_PET', updatePet)
			end
		end

		if (not header) then
			-- No header means it's a frame created through :Spawn().
			object:SetAttribute('*type1', 'target')
			object:SetAttribute('*type2', 'togglemenu')

			-- No need to enable this for *target frames.
			if (not (unit:match('target') or suffix == 'target')) then
				object:SetAttribute('toggleForVehicle', true)
			end

			-- Other boss and target units are handled by :HandleUnit().
			if (suffix == 'target') then
				enableTargetUpdate(object)
			else
				SUF:HandleUnit(object)
			end
		else
			-- update the frame when its prev unit is replaced with a new one
			-- updateRaid relies on UnitGUID to detect the unit change
			object:RegisterEvent('GROUP_ROSTER_UPDATE', updateRaid, true)

			if (num > 1) then
				if (object:GetParent() == header) then
					object.hasChildren = true
				else
					object.isChild = true
				end
			end

			if (suffix == 'target') then
				enableTargetUpdate(object)
			end
		end

		Private.UpdateUnits(object, objectUnit)

		styleFunc(object, objectUnit, not header)

		object:HookScript('OnAttributeChanged', onAttributeChanged)

		-- NAME_PLATE_UNIT_ADDED fires after the frame is shown, so there's no
		-- need to call UAE multiple times
		if (not object.isNamePlate) then
			object:SetScript('OnShow', onShow)
		end

		activeElements[object] = {}
		for element in next, elements do
			object:EnableElement(element, objectUnit)
		end

		for _, func in next, callback do
			func(object)
		end

		-- Make Clique kinda happy
		if (not object.isNamePlate) then
			_G.ClickCastFrames = ClickCastFrames or {}
			ClickCastFrames[object] = true
		end
	end
end

local function walkObject(object, unit)
	local parent = object:GetParent()
	local style = parent.style or style
	local styleFunc = styles[style]

	local header = parent:GetAttribute('SUF-headerType') and parent

	-- Check if we should leave the main frame blank.
	if (object:GetAttribute('SUF-onlyProcessChildren')) then
		object.hasChildren = true
		object:HookScript('OnAttributeChanged', onAttributeChanged)
		return initObject(unit, style, styleFunc, header, object:GetChildren())
	end

	return initObject(unit, style, styleFunc, header, object, object:GetChildren())
end

--[[ SUF:RegisterInitCallback(func)
Used to add a function to a table to be executed upon unit frame/header initialization.

* self - the global SUF object
* func - function to be added
--]]
function SUF:RegisterInitCallback(func)
	table.insert(callback, func)
end

--[[ SUF:RegisterMetaFunction(name, func)
Used to make a (table of) function(s) available to all unit frames.

* self - the global SUF object
* name - unique name of the function (string)
* func - function or a table of functions (function or table)
--]]
function SUF:RegisterMetaFunction(name, func)
	argcheck(name, 2, 'string')
	argcheck(func, 3, 'function', 'table')

	if (frame_metatable.__index[name]) then
		return
	end

	frame_metatable.__index[name] = func
end

--[[ SUF:RegisterStyle(name, func)
Used to register a style with SUF. This will also set the active style if it hasn't been set yet.

* self - the global SUF object
* name - name of the style
* func - function(s) defining the style (function or table)
--]]
function SUF:RegisterStyle(name, func)
	argcheck(name, 2, 'string')
	argcheck(func, 3, 'function', 'table')

	if (styles[name]) then
		return error('Style [%s] already registered.', name)
	end
	if (not style) then
		style = name
	end

	styles[name] = func
end

--[[ SUF:SetActiveStyle(name)
Used to set the active style.

* self - the global SUF object
* name - name of the style (string)
--]]
function SUF:SetActiveStyle(name)
	argcheck(name, 2, 'string')
	if (not styles[name]) then
		return error('Style [%s] does not exist.', name)
	end

	style = name
end

--[[ SUF:GetActiveStyle()
Used to get the active style.
* self - the global SUF object
--]]
function SUF:GetActiveStyle()
	return style
end

do
	local function iter(_, n)
		-- don't expose the style functions.
		return (next(styles, n))
	end

	--[[ SUF:IterateStyles()
	Returns an iterator over all registered styles.

	* self - the global SUF object
	--]]
	function SUF.IterateStyles()
		return iter, nil, nil
	end
end

local getCondition
do
	local conditions = {
		raid40 = '[@raid26,exists] show;',
		raid25 = '[@raid11,exists] show;',
		raid10 = '[@raid6,exists] show;',
		raid = '[group:raid] show;',
		party = '[group:party,nogroup:raid] show;',
		solo = '[@player,exists,nogroup:party] show;'
	}

	function getCondition(...)
		local cond = ''

		for i = 1, select('#', ...) do
			local short = select(i, ...)

			local condition = conditions[short]
			if (condition) then
				cond = cond .. condition
			end
		end

		return cond .. 'hide'
	end
end

local function generateName(unit, ...)
	local name = 'SUF_' .. style:gsub('^SUF_?', ''):gsub('[^%a%d_]+', '')

	local raid, party, groupFilter, unitsuffix
	for i = 1, select('#', ...), 2 do
		local att, val = select(i, ...)
		if (att == 'SUF-initialConfigFunction') then
			unitsuffix = val:match('unitsuffix[%p%s]+(%a+)')
		elseif (att == 'showRaid') then
			raid = val ~= false and val ~= nil
		elseif (att == 'showParty') then
			party = val ~= false and val ~= nil
		elseif (att == 'groupFilter') then
			groupFilter = val
		end
	end

	local append
	if (raid) then
		if (groupFilter) then
			if (type(groupFilter) == 'number' and groupFilter > 0) then
				append = 'Raid' .. groupFilter
			elseif (groupFilter:match('MAINTANK')) then
				append = 'MainTank'
			elseif (groupFilter:match('MAINASSIST')) then
				append = 'MainAssist'
			else
				local _, count = groupFilter:gsub(',', '')
				if (count == 0) then
					append = 'Raid' .. groupFilter
				else
					append = 'Raid'
				end
			end
		else
			append = 'Raid'
		end
	elseif (party) then
		append = 'Party'
	elseif (unit) then
		append = unit:gsub('^%l', string.upper)
	end

	if (append) then
		name = name .. append .. (unitsuffix or '')
	end

	-- Change SUF_LilyRaidRaid into SUF_LilyRaid
	name = name:gsub('(%u%l+)([%u%l]*)%1', '%1')
	-- Change SUF_LilyTargettarget into SUF_LilyTargetTarget
	name = name:gsub('t(arget)', 'T%1')
	name = name:gsub('p(et)', 'P%1')
	name = name:gsub('f(ocus)', 'F%1')

	local base = name
	local i = 2
	while (_G[name]) do
		name = base .. i
		i = i + 1
	end

	return name
end

do
	local function styleProxy(self, frame, ...)
		return walkObject(_G[frame])
	end

	-- There has to be an easier way to do this.
	local initialConfigFunction =
		[[
		local header = self:GetParent()
		local frames = table.new()
		table.insert(frames, self)
		self:GetChildList(frames)
		for i = 1, #frames do
			local frame = frames[i]
			local unit
			-- There's no need to do anything on frames with onlyProcessChildren
			if(not frame:GetAttribute('SUF-onlyProcessChildren')) then
				RegisterUnitWatch(frame)

				-- Attempt to guess what the header is set to spawn.
				local groupFilter = header:GetAttribute('groupFilter')

				if(type(groupFilter) == 'string' and groupFilter:match('MAIN[AT]')) then
					local role = groupFilter:match('MAIN([AT])')
					if(role == 'T') then
						unit = 'maintank'
					else
						unit = 'mainassist'
					end
				elseif(header:GetAttribute('showRaid')) then
					unit = 'raid'
				elseif(header:GetAttribute('showParty')) then
					unit = 'party'
				end

				local headerType = header:GetAttribute('SUF-headerType')
				local suffix = frame:GetAttribute('unitsuffix')
				if(unit and suffix) then
					if(headerType == 'pet' and suffix == 'target') then
						unit = unit .. headerType .. suffix
					else
						unit = unit .. suffix
					end
				elseif(unit and headerType == 'pet') then
					unit = unit .. headerType
				end

				frame:SetAttribute('*type1', 'target')
				frame:SetAttribute('*type2', 'togglemenu')
				frame:SetAttribute('SUF-guessUnit', unit)
			end

			local body = header:GetAttribute('SUF-initialConfigFunction')
			if(body) then
				frame:Run(body, unit)
			end
		end

		header:CallMethod('styleFunction', self:GetName())

		local clique = header:GetFrameRef('clickcast_header')
		if(clique) then
			clique:SetAttribute('clickcast_button', self)
			clique:RunAttribute('clickcast_register')
		end
	]]

	--[[ SUF:SpawnHeader(overrideName, template, visibility, ...)
	Used to create a group header and apply the currently active style to it.

	* self         - the global SUF object
	* overrideName - unique global name to be used for the header. Defaults to an auto-generated name based on the name
	                 of the active style and other arguments passed to `:SpawnHeader` (string?)
	* template     - name of a template to be used for creating the header. Defaults to `'SecureGroupHeaderTemplate'`
	                 (string?)
	* visibility   - macro conditional(s) which define when to display the header (string).
	* ...          - further argument pairs. Consult [Group Headers](http://wowprogramming.com/docs/secure_template/Group_Headers.html)
	                 for possible values.

	In addition to the standard group headers, SUF implements some of its own attributes. These can be supplied by the
	layout, but are optional.

	* SUF-initialConfigFunction - can contain code that will be securely run at the end of the initial secure
	                              configuration (string?)
	* SUF-onlyProcessChildren   - can be used to force headers to only process children (boolean?)
	--]]
	function SUF:SpawnHeader(overrideName, template, visibility, ...)
		if (not style) then
			return error('Unable to create frame. No styles have been registered.')
		end

		template = (template or 'SecureGroupHeaderTemplate')

		local isPetHeader = template:match('PetHeader')
		local name = overrideName or generateName(nil, ...)
		local header = CreateFrame('Frame', name, PetBattleFrameHider, template)

		header:SetAttribute(
			'template',
			'SecureUnitButtonTemplate, SecureHandlerStateTemplate, SecureHandlerEnterLeaveTemplate'
		)
		for i = 1, select('#', ...), 2 do
			local att, val = select(i, ...)
			if (not att) then
				break
			end
			header:SetAttribute(att, val)
		end

		header.style = style
		header.styleFunction = styleProxy
		header.visibility = visibility

		-- Expose the header through SUF.headers.
		table.insert(headers, header)

		-- We set it here so layouts can't directly override it.
		header:SetAttribute('initialConfigFunction', initialConfigFunction)
		header:SetAttribute('_initialAttributeNames', '_onenter,_onleave,refreshUnitChange,_onstate-vehicleui')
		header:SetAttribute(
			'_initialAttribute-_onenter',
			[[
			local snippet = self:GetAttribute('clickcast_onenter')
			if(snippet) then
				self:Run(snippet)
			end
		]]
		)
		header:SetAttribute(
			'_initialAttribute-_onleave',
			[[
			local snippet = self:GetAttribute('clickcast_onleave')
			if(snippet) then
				self:Run(snippet)
			end
		]]
		)
		header:SetAttribute(
			'_initialAttribute-refreshUnitChange',
			[[
			local unit = self:GetAttribute('unit')
			if(unit) then
				RegisterStateDriver(self, 'vehicleui', '[@' .. unit .. ',unithasvehicleui]vehicle; novehicle')
			else
				UnregisterStateDriver(self, 'vehicleui')
			end
		]]
		)
		header:SetAttribute(
			'_initialAttribute-_onstate-vehicleui',
			[[
			local unit = self:GetAttribute('unit')
			if(newstate == 'vehicle' and unit and UnitPlayerOrPetInRaid(unit) and not UnitTargetsVehicleInRaidUI(unit)) then
				self:SetAttribute('toggleForVehicle', false)
			else
				self:SetAttribute('toggleForVehicle', true)
			end
		]]
		)
		header:SetAttribute('SUF-headerType', isPetHeader and 'pet' or 'group')

		if (Clique) then
			SecureHandlerSetFrameRef(header, 'clickcast_header', Clique.header)
		end

		if (header:GetAttribute('showParty')) then
			self:DisableBlizzard('party')
		end

		if (visibility) then
			local type, list = string.split(' ', visibility, 2)
			if (list and type == 'custom') then
				RegisterAttributeDriver(header, 'state-visibility', list)
				header.visibility = list
			else
				local condition = getCondition(string.split(',', visibility))
				RegisterAttributeDriver(header, 'state-visibility', condition)
				header.visibility = condition
			end
		end

		return header
	end
end

--[[ SUF:Spawn(unit, overrideName)
Used to create a single unit frame and apply the currently active style to it.

* self         - the global SUF object
* unit         - the frame's unit (string)
* overrideName - unique global name to use for the unit frame. Defaults to an auto-generated name based on the unit
                 (string?)

SUF implements some of its own attributes. These can be supplied by the layout, but are optional.

* SUF-enableArenaPrep - can be used to toggle arena prep support. Defaults to true (boolean)
--]]
function SUF:Spawn(unit, overrideName)
	argcheck(unit, 2, 'string')
	if (not style) then
		return error('Unable to create frame. No styles have been registered.')
	end

	unit = unit:lower()

	local name = overrideName or generateName(unit)
	local object = CreateFrame('Button', name, PetBattleFrameHider, 'SecureUnitButtonTemplate')
	Private.UpdateUnits(object, unit)

	self:DisableBlizzard(unit)
	walkObject(object, unit)

	object:SetAttribute('unit', unit)
	RegisterUnitWatch(object)

	return object
end

--[[ SUF:SpawnNamePlates(prefix, callback, variables)
Used to create nameplates and apply the currently active style to them.

* self      - the global SUF object
* prefix    - prefix for the global name of the nameplate. Defaults to an auto-generated prefix (string?)
* callback  - function to be called after a nameplate unit or the player's target has changed. The arguments passed to
              the callback are the updated nameplate, if any, the event that triggered the update, and the new unit
              (function?)
* variables - list of console variable-value pairs to be set when the player logs in (table?)
--]]
function SUF:SpawnNamePlates(namePrefix, nameplateCallback, nameplateCVars)
	argcheck(nameplateCallback, 3, 'function', 'nil')
	argcheck(nameplateCVars, 4, 'table', 'nil')
	if (not style) then
		return error('Unable to create frame. No styles have been registered.')
	end
	if (SUF_NamePlateDriver) then
		return error('SUF nameplate driver has already been initialized.')
	end

	local style = style
	local prefix = namePrefix or generateName()

	-- Because there's no way to prevent nameplate settings updates without tainting UI,
	-- and because forbidden nameplates exist, we have to allow default nameplate
	-- driver to create, update, and remove Blizz nameplates.
	-- Disable only not forbidden nameplates.
	NamePlateDriverFrame:HookScript(
		'OnEvent',
		function(_, event, unit)
			if (event == 'NAME_PLATE_UNIT_ADDED' and unit) then
				self:DisableBlizzard(unit)
			end
		end
	)

	local eventHandler = CreateFrame('Frame', 'SUF_NamePlateDriver')
	eventHandler:RegisterEvent('NAME_PLATE_UNIT_ADDED')
	eventHandler:RegisterEvent('NAME_PLATE_UNIT_REMOVED')
	eventHandler:RegisterEvent('PLAYER_TARGET_CHANGED')

	if (IsLoggedIn()) then
		if (nameplateCVars) then
			for cvar, value in next, nameplateCVars do
				SetCVar(cvar, value)
			end
		end
	else
		eventHandler:RegisterEvent('PLAYER_LOGIN')
	end

	eventHandler:SetScript(
		'OnEvent',
		function(_, event, unit)
			if (event == 'PLAYER_LOGIN') then
				if (nameplateCVars) then
					for cvar, value in next, nameplateCVars do
						SetCVar(cvar, value)
					end
				end
			elseif (event == 'PLAYER_TARGET_CHANGED') then
				local nameplate = C_NamePlate.GetNamePlateForUnit('target')
				if (nameplateCallback) then
					nameplateCallback(nameplate and nameplate.unitFrame, event, 'target')
				end

				-- UAE is called after the callback to reduce the number of
				-- ForceUpdate calls layout devs have to do themselves
				if (nameplate) then
					nameplate.unitFrame:UpdateAllElements(event)
				end
			elseif (event == 'NAME_PLATE_UNIT_ADDED' and unit) then
				local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
				if (not nameplate) then
					return
				end

				if (not nameplate.unitFrame) then
					nameplate.style = style

					nameplate.unitFrame = CreateFrame('Button', prefix .. nameplate:GetName(), nameplate)
					nameplate.unitFrame:EnableMouse(false)
					nameplate.unitFrame.isNamePlate = true

					Private.UpdateUnits(nameplate.unitFrame, unit)

					walkObject(nameplate.unitFrame, unit)
				else
					Private.UpdateUnits(nameplate.unitFrame, unit)
				end

				nameplate.unitFrame:SetAttribute('unit', unit)

				if (nameplateCallback) then
					nameplateCallback(nameplate.unitFrame, event, unit)
				end

				-- UAE is called after the callback to reduce the number of
				-- ForceUpdate calls layout devs have to do themselves
				nameplate.unitFrame:UpdateAllElements(event)
			elseif (event == 'NAME_PLATE_UNIT_REMOVED' and unit) then
				local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
				if (not nameplate) then
					return
				end

				nameplate.unitFrame:SetAttribute('unit', nil)

				if (nameplateCallback) then
					nameplateCallback(nameplate.unitFrame, event, unit)
				end
			end
		end
	)
end

--[[ SUF:AddElement(name, update, enable, disable)
Used to register an element with SUF.

* self    - the global SUF object
* name    - unique name of the element (string)
* update  - used to update the element (function?)
* enable  - used to enable the element for a given unit frame and unit (function?)
* disable - used to disable the element for a given unit frame (function?)
--]]
function SUF:AddElement(name, update, enable, disable)
	argcheck(name, 2, 'string')
	argcheck(update, 3, 'function', 'nil')
	argcheck(enable, 4, 'function', 'nil')
	argcheck(disable, 5, 'function', 'nil')

	if (elements[name]) then
		return error('Element [%s] is already registered.', name)
	end
	elements[name] = {
		update = update,
		enable = enable,
		disable = disable
	}
end

SUF.version = _VERSION
--[[ SUF.objects
Array containing all unit frames created by `SUF:Spawn`.
--]]
SUF.objects = objects
--[[ SUF.headers
Array containing all group headers created by `SUF:SpawnHeader`.
--]]
SUF.headers = headers

if (global) then
	if (parent ~= 'SUF' and global == 'SUF') then
		error('%s is doing it wrong and setting its global to "SUF".', parent)
	elseif (_G[global]) then
		error('%s is setting its global to an existing name "%s".', parent, global)
	else
		_G[global] = SUF
	end
end
