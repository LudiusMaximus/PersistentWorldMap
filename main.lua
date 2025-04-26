
-- Forward declaration
local CheckMap
local PlayerPingAnimation


-- #####################################################
-- Preventing taint!
-- #####################################################

-- To do a WorldMapFrame:OnMapChanged() again when combat ends.
-- Just in case this might be important.
local reloadAfterCombat = false


-- Overriding Blizzard_SharedMapDataProviders/SharedMapPoiTemplates.lua, L518
function SuperTrackablePinMixin:OnAcquired(...)
  if not self:IsSuperTrackingExternallyHandled() then

    -- Ludius change to prevnt taint:
    if not InCombatLockdown() then
      self:UpdateMousePropagation();
    else
      reloadAfterCombat = true
    end

    self:UpdateSuperTrackedState(C_SuperTrack[self:GetSuperTrackAccessorAPIName()]());
  end
end

-- Overriding Blizzard_MapCanvas/Blizzard_MapCanvas.lua, L230
do
  local function OnPinReleased(pinPool, pin)
    local map = pin:GetMap();
    if map then
      map:UnregisterPin(pin);
    end

    Pool_HideAndClearAnchors(pinPool, pin);
    pin:OnReleased();

    pin.pinTemplate = nil;
    pin.owningMap = nil;
  end

  local function OnPinMouseUp(pin, button, upInside)
    pin:OnMouseUp(button, upInside);
    if upInside then
      pin:OnClick(button);
    end
  end

  function WorldMapFrame:AcquirePin(pinTemplate, ...)

    if not self.pinPools[pinTemplate] then
      local pinTemplateType = self:GetPinTemplateType(pinTemplate);
      self.pinPools[pinTemplate] = CreateFramePool(pinTemplateType, self:GetCanvas(), pinTemplate, OnPinReleased);
    end

    local pin, newPin = self.pinPools[pinTemplate]:Acquire();

    pin.pinTemplate = pinTemplate;
    pin.owningMap = self;

    if newPin then
      local isMouseClickEnabled = pin:IsMouseClickEnabled();
      local isMouseMotionEnabled = pin:IsMouseMotionEnabled();

      if isMouseClickEnabled then
        pin:SetScript("OnMouseUp", OnPinMouseUp);
        pin:SetScript("OnMouseDown", pin.OnMouseDown);

        if pin:IsObjectType("Button") then
          pin:SetScript("OnClick", nil);
        end
      end

      if isMouseMotionEnabled then
        if newPin and not pin:DisableInheritedMotionScriptsWarning() then
          assert(pin:GetScript("OnEnter") == nil);
          assert(pin:GetScript("OnLeave") == nil);
        end
        pin:SetScript("OnEnter", pin.OnMouseEnter);
        pin:SetScript("OnLeave", pin.OnMouseLeave);
      end

      pin:SetMouseClickEnabled(isMouseClickEnabled);
      pin:SetMouseMotionEnabled(isMouseMotionEnabled);
    end

    if newPin then
      pin:OnLoad();
    end

    self.ScrollContainer:MarkCanvasDirty();
    pin:Show();

    pin:OnAcquired(...);

    -- Ludius change to prevnt taint:
    if not InCombatLockdown() then
      pin:CheckMouseButtonPassthrough("RightButton");
    else
      reloadAfterCombat = true
    end

    self:RegisterPin(pin);

    return pin;
  end
end


-- No idea if we need this. But better be on the safe side.
local leaveCombatFrame = CreateFrame("Frame")
leaveCombatFrame:RegisterEvent("PLAYER_LEAVE_COMBAT")
leaveCombatFrame:SetScript("OnEvent", function()
  if reloadAfterCombat and WorldMapFrame:IsShown() then
    WorldMapFrame:OnMapChanged()
    PlayerPingAnimation(false)
  end
  reloadAfterCombat = false
end)





-- Locals for frequently used global functions.
local C_Map_GetMapArtID                  = _G.C_Map.GetMapArtID
local C_Map_GetMapInfo                   = _G.C_Map.GetMapInfo
local C_Map_GetPlayerMapPosition         = _G.C_Map.GetPlayerMapPosition
local MapUtil_GetDisplayableMapForPlayer = _G.MapUtil.GetDisplayableMapForPlayer

local Clamp                     = _G.Clamp
local GetTime                   = _G.GetTime
local WorldMapFrame             = _G.WorldMapFrame

local IsShiftKeyDown            = _G.IsShiftKeyDown
local GameTooltip_SetTitle      = _G.GameTooltip_SetTitle
local GameTooltip_AddNormalLine = _G.GameTooltip_AddNormalLine
local GameTooltip_AddErrorLine  = _G.GameTooltip_AddErrorLine
local GetScaledCursorPosition   = _G.GetScaledCursorPosition

local math_floor = _G.math.floor
local function Round(num, numDecimalPlaces)
  local mult = 10^(numDecimalPlaces or 0)
  return math_floor(num * mult + 0.5) / mult
end


-- TODO: Make optional.
local RESET_MAP_AFTER = 15
local DOUBLE_CLICK_TIME = 0.25


-- TODO: Store in saved variable
local autoCentering = false



-- Flag to prevent saving before map was first shown.
local firstShownAfterLogin = false

local lastMapID   = nil
local lastScale   = nil
local lastScrollX = nil
local lastScrollY = nil

-- Only store the last map for a short time.
local lastMapCloseTime = GetTime()


-- If the last viewed map was the map in which the player was,
-- we want the map to automatically change to the new map;
-- both if the map is visible or not.
local lastViewedMapWasCurrentMap = false



-- To prevent player pin pings when we don't need them.
-- Forward declaration above.
local playerPin = nil
PlayerPingAnimation = function(start)

  -- If we do not have the player pin yet, search it.
  if not playerPin or not playerPin.ShouldShowUnit or not playerPin:ShouldShowUnit("player") then
    playerPin = nil
    for k, _ in pairs(WorldMapFrame.dataProviders) do
      if type(k) == "table" and k.GetMap and k.ShouldShowUnit then
        -- print("Found GroupMembersDataProvider.")
        if k:ShouldShowUnit("player") then
          playerPin = k
          break
        end
      end
    end
  end

  if playerPin then
    if start then
      -- Arguments are duration and fade-out duration.
      playerPin.pin:StartPlayerPing(2, .25)
    else
      playerPin.pin:StopPlayerPing(2, .25)
    end
    -- Got to call this to prevent pin size flicker.
    playerPin.pin:SynchronizePinSizes()
  end
end



local function SaveMapState()
  if not firstShownAfterLogin then return end

  local mapID = WorldMapFrame:GetMapID()
  if not mapID then
    lastMapID   = nil
    lastScale   = nil
    lastScrollX = nil
    lastScrollY = nil
    return
  end

  lastMapID   = WorldMapFrame:GetMapID()
  lastScale   = WorldMapFrame.ScrollContainer.currentScale
  lastScrollX = WorldMapFrame.ScrollContainer.currentScrollX
  lastScrollY = WorldMapFrame.ScrollContainer.currentScrollY
  -- print("saving", lastMapID, lastScale, lastScrollX, lastScrollY)

  -- These values are the same as obtained by these functions.
  -- see \Interface\AddOns\Blizzard_MapCanvas\MapCanvas_ScrollContainerMixin.lua
  -- WorldMapFrame.ScrollContainer.currentScale   == WorldMapFrame.ScrollContainer:GetCanvasScale()
  -- WorldMapFrame.ScrollContainer.currentScrollX == WorldMapFrame.ScrollContainer:GetNormalizedHorizontalScroll()
  -- WorldMapFrame.ScrollContainer.currentScrollY == WorldMapFrame.ScrollContainer:GetNormalizedVerticalScroll()

end


-- Called when reopenning the map.
local function RestoreMapState()
  if lastMapID and lastScale and lastScrollX and lastScrollY then
    -- print("restoring", lastMapID, lastScale, lastScrollX, lastScrollY)

    -- WorldMapFrame:SetMapID(lastMapID)
    -- Content of WorldMapFrame:SetMapID(lastMapID) separated:
    local mapArtID = C_Map_GetMapArtID(lastMapID)
    if WorldMapFrame.mapID ~= lastMapID or WorldMapFrame.mapArtID ~= mapArtID then
      WorldMapFrame.areDetailLayersDirty = true
      WorldMapFrame.mapID = lastMapID
      WorldMapFrame.mapArtID = mapArtID
      WorldMapFrame.expandedMapInsetsByMapID = {}
      WorldMapFrame.ScrollContainer:SetMapID(lastMapID)
      if WorldMapFrame:IsShown() then
        WorldMapFrame:RefreshDetailLayers()
      end
    end

    lastViewedMapWasCurrentMap = (lastMapID == MapUtil_GetDisplayableMapForPlayer())


    WorldMapFrame.ScrollContainer:InstantPanAndZoom(lastScale, lastScrollX, lastScrollY, true)
    -- -- Alternative:
    -- WorldMapFrame.ScrollContainer.currentScale = lastScale
    -- WorldMapFrame.ScrollContainer.targetScale = lastScale
    -- WorldMapFrame.ScrollContainer.currentScrollX = lastScrollX
    -- WorldMapFrame.ScrollContainer.targetScrollX = lastScrollX
    -- WorldMapFrame.ScrollContainer.currentScrollY = lastScrollY
    -- WorldMapFrame.ScrollContainer.targetScrollY = lastScrollY

    WorldMapFrame:OnMapChanged()

    CheckMap()
  end
end



-- Post hook for ToggleWorldMap to restore map after it is shown.
-- (Cannot do this with WorldMapFrame.ScrollContainer:HookScript("OnShow"),
-- because it gets called too early.)
local function RestoreMap()
  if WorldMapFrame:IsShown() then

    if not firstShownAfterLogin then
      firstShownAfterLogin = true
    end

    -- print("Post Hook after showing", GetTime(), lastMapCloseTime, GetTime() - lastMapCloseTime, RESET_MAP_AFTER)
    if GetTime() - lastMapCloseTime > RESET_MAP_AFTER then
      lastMapID = nil
    else
      RestoreMapState()
    end

    -- To refresh buttons.
    CheckMap()
  end
end

hooksecurefunc("ToggleWorldMap", RestoreMap)
hooksecurefunc("ToggleQuestLog", RestoreMap)



-- Pre hook for WorldMapFrame.ScrollContainer OnHide to store map before it is hidden.
-- (Cannot do this with HookScript, because then it is called too late.
-- Also cannot do this in hooksecurefunc of ToggleWorldMap, because then it is not called when
-- closing the map manually.)
local OtherWorldMapFrameOnHideScripts = WorldMapFrame.ScrollContainer:GetScript("OnHide")
WorldMapFrame.ScrollContainer:SetScript("OnHide", function(self, ...)
  -- print("Prehook before Hiding")
  lastMapCloseTime = GetTime()
  SaveMapState()
  OtherWorldMapFrameOnHideScripts(self, ...)
end)

-- Also got to store and restore when the SidePanelToggle is shown or hidden.
local OtherCloseButtonScripts = WorldMapFrame.SidePanelToggle.CloseButton:GetScript("OnClick")
WorldMapFrame.SidePanelToggle.CloseButton:SetScript("OnClick", function(...)
  SaveMapState()
  OtherCloseButtonScripts(...)
  RestoreMapState()
  PlayerPingAnimation(false)
end)
local OtherOpenButtonScripts = WorldMapFrame.SidePanelToggle.OpenButton:GetScript("OnClick")
WorldMapFrame.SidePanelToggle.OpenButton:SetScript("OnClick", function(...)
  SaveMapState()
  OtherOpenButtonScripts(...)
  RestoreMapState()
  PlayerPingAnimation(false)
end)



local function ResetMap(preserveZoom)

  local previousScale = WorldMapFrame.ScrollContainer.currentScale

  -- print("ResetMap", MapUtil_GetDisplayableMapForPlayer())
  WorldMapFrame:SetMapID(MapUtil_GetDisplayableMapForPlayer())

  if preserveZoom then
    -- print("restoring", previousScale)
    WorldMapFrame.ScrollContainer.currentScale = previousScale
    WorldMapFrame.ScrollContainer.targetScale = previousScale
    WorldMapFrame:OnMapChanged()
    PlayerPingAnimation(false)
  else
    WorldMapFrame:OnMapChanged()
  end


  -- TODO Cannot reproduce this any more (April 2025). Remove if it does not come back!
  -- -- Got to do this to avoid funny shift of the map by 1 pixel...
  -- local currentScale = WorldMapFrame.ScrollContainer:GetCanvasScale()
  -- local currentZoomLevel = WorldMapFrame.ScrollContainer:GetZoomLevelIndexForScale(currentScale)
  -- print(currentScale, currentZoomLevel)
  -- if currentZoomLevel ~= 1 then
    -- WorldMapFrame:ResetZoom()
  -- end

  SaveMapState()
end






local recenterButton = nil

local RecenterButtonEnterFunction = function(button)
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  GameTooltip_SetTitle(GameTooltip, "Persistent World Map")
  GameTooltip_AddNormalLine(GameTooltip, "Restores the map to its previous state when closing and reopenning it.")
  GameTooltip_AddNormalLine(GameTooltip, "Automatically switches to the map of a newly entered zone.")
  GameTooltip_AddBlankLineToTooltip(GameTooltip)
  GameTooltip_AddInstructionLine(GameTooltip, "Click here to show the map of the current zone or just shift-click on the map.")
  if not button:IsEnabled() then
    GameTooltip_AddErrorLine(GameTooltip, "Already showing the map of the current zone.")
  end
  GameTooltip:Show()
end

local function EnableRecenterButton()
  if not recenterButton or recenterButton:IsEnabled() then return end
  recenterButton.centerDot.t:SetVertexColor(0, 0, 0, 1)
  recenterButton:SetEnabled(true)
  if GameTooltip:GetOwner() == recenterButton then
    RecenterButtonEnterFunction(recenterButton)
  end
end

local function DisableRecenterButton()
  if not recenterButton or not recenterButton:IsEnabled() then return end
  recenterButton.centerDot.t:SetVertexColor(1, 0.9, 0, 1)
  recenterButton:SetEnabled(false)
  if GameTooltip:GetOwner() == recenterButton then
    RecenterButtonEnterFunction(recenterButton)
  end
end




local autoCenterLockButton

local AutoCenterLockButtonEnterFunction = function(button)
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  GameTooltip_SetTitle(GameTooltip, "Lock map to player")
  GameTooltip_AddNormalLine(GameTooltip, "Automatically keep the player pin closest to the center of the map when the map is zoomed in. (Not possible in dungeons, raids, battlegrounds and arenas.)")
  GameTooltip_AddBlankLineToTooltip(GameTooltip)
  if button:IsEnabled() then
    if autoCentering then
      GameTooltip_AddInstructionLine(GameTooltip, "Click here to turn OFF\nor just drag the map.")
    else
      GameTooltip_AddInstructionLine(GameTooltip, "Click here to turn ON\nor just double-click on the map.")
    end
  else
    GameTooltip_AddErrorLine(GameTooltip, "Not possible in this zone.")
  end
  GameTooltip:Show()
end

local function EnableCenterOnPlayer()
  if autoCentering then return end
  autoCentering = true
  if not autoCenterLockButton then return end
  autoCenterLockButton:GetNormalTexture():SetDesaturated(false)
  if GameTooltip:GetOwner() == autoCenterLockButton then
    AutoCenterLockButtonEnterFunction(autoCenterLockButton)
  end
  PlayerPingAnimation(true)
end

local function DisableCenterOnPlayer()
  if not autoCentering then return end
  autoCentering = false
  if not autoCenterLockButton then return end
  autoCenterLockButton:GetNormalTexture():SetDesaturated(true)
  if GameTooltip:GetOwner() == autoCenterLockButton then
    AutoCenterLockButtonEnterFunction(autoCenterLockButton)
  end
end



local function CreateMapButtons(anchorButton)

  -- Template in RecenterButtonTemplate.xml copied from WorldMapTrackingPinButtonTemplate
  -- in Blizzard's \Interface\AddOns\Blizzard_WorldMap\Blizzard_WorldMapTemplates.xml
  recenterButton = CreateFrame("Button", nil, WorldMapFrame.ScrollContainer, "RecenterButtonTemplate")
  recenterButton:SetPoint("TOPRIGHT", anchorButton, "BOTTOMRIGHT", 0, 0)

  recenterButton:SetScript("OnClick", function()
      PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
      ResetMap()
      DisableRecenterButton()
    end)

  recenterButton:SetScript("OnEnter", function(self)
      RecenterButtonEnterFunction(self)
    end)
  recenterButton:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)

  recenterButton.Icon:SetAtlas("TargetCrosshairs")
  recenterButton.Icon:SetTexCoord(0.1, 0.5, 0.1, 0.5)

  recenterButton.centerDot = CreateFrame("Frame", nil, recenterButton)
  local t = recenterButton.centerDot:CreateTexture(nil, "OVERLAY")
  t:SetTexture("Interface\\AddOns\\PersistentWorldMap\\dot.tga")
  t:SetPoint("CENTER", recenterButton, "CENTER", 0.3, 0.5)
  t:SetSize(10, 10)
  recenterButton.centerDot.t = t

  DisableRecenterButton()





  -- Add the "lock to player position" button.
  autoCenterLockButton = CreateFrame("Button", nil, recenterButton)
  autoCenterLockButton:SetSize(18, 21)
  autoCenterLockButton:SetPoint("CENTER", recenterButton, "BOTTOMRIGHT", -4, 7)

  -- To get an OnEnter tooltip while disabled.
  autoCenterLockButton:SetMotionScriptsWhileDisabled(true)

  autoCenterLockButton:SetNormalAtlas("Monuments-Lock")
  autoCenterLockButton:SetPushedAtlas("Monuments-Lock")
  autoCenterLockButton:SetHighlightAtlas("bountiful-glow", "BLEND")

  if not autoCentering then
    autoCenterLockButton:GetNormalTexture():SetDesaturated(true)
  end

  -- Create the disabled overlay texture that will be layered on top.
  autoCenterLockButton.disabledTexture = autoCenterLockButton:CreateTexture(nil, "OVERLAY")
  autoCenterLockButton.disabledTexture:SetAtlas("talents-button-reset", "BLEND")
  autoCenterLockButton.disabledTexture:SetPoint("CENTER", autoCenterLockButton, "CENTER", 0, -3)
  autoCenterLockButton.disabledTexture:SetSize(16, 16)
  autoCenterLockButton.disabledTexture:SetAlpha(0.7)
  autoCenterLockButton.disabledTexture:Hide()

  -- Override the default disabled state.
  autoCenterLockButton:SetScript("OnDisable", function(self)
    self:GetNormalTexture():SetDesaturated(true)
    self.disabledTexture:Show()
    if GameTooltip:GetOwner() == self then
      AutoCenterLockButtonEnterFunction(self)
    end
  end)

  autoCenterLockButton:SetScript("OnEnable", function(self)
    self.disabledTexture:Hide()
    if autoCentering then
      self:GetNormalTexture():SetDesaturated(false)
    end
    if GameTooltip:GetOwner() == self then
      AutoCenterLockButtonEnterFunction(self)
    end
  end)

  -- Handle clicks
  autoCenterLockButton:SetScript("OnClick", function()
    if autoCentering then
      PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
      DisableCenterOnPlayer()
    else
      PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
      EnableCenterOnPlayer()
    end
  end)

  -- For tooltips.
  autoCenterLockButton:SetScript("OnEnter", function(self)
      AutoCenterLockButtonEnterFunction(self)
    end)
  autoCenterLockButton:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)

end




-- Forward declaration above.
CheckMap = function()

  local currentMap = MapUtil_GetDisplayableMapForPlayer()

  if WorldMapFrame:GetMapID() ~= currentMap then
    if lastViewedMapWasCurrentMap then
      -- If autoCentering is active, we want to preserve the zoom level.
      ResetMap(autoCentering)
    else
      EnableRecenterButton()
    end
  else
    DisableRecenterButton()
  end

  if not C_Map_GetPlayerMapPosition(currentMap, "player") then
    if autoCenterLockButton:IsEnabled() then
      autoCenterLockButton:SetEnabled(false)
    end
  else
    if not autoCenterLockButton:IsEnabled() then
      autoCenterLockButton:SetEnabled(true)
    end
  end
end


-- Frame to listen to zone change events such that the map gets reset when opened after having
-- changed into an area with a different map.
local zoneChangeFrame = CreateFrame ("Frame")
-- But only do this for areas, not for sub-zone changes.
zoneChangeFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
zoneChangeFrame:RegisterEvent("ZONE_CHANGED")
zoneChangeFrame:RegisterEvent("ZONE_CHANGED_INDOORS")
zoneChangeFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
-- Needed for map changes in dungeons.
zoneChangeFrame:RegisterEvent("AREA_POIS_UPDATED")
zoneChangeFrame:SetScript("OnEvent",
  function(_, event, ...)
    if WorldMapFrame:IsShown() then
      -- print(event, ":", GetZoneText(), GetSubZoneText(), WorldMapFrame:GetMapID(), MapUtil_GetDisplayableMapForPlayer(), lastViewedMapWasCurrentMap)
      CheckMap()
    end
  end
)

-- Some map changes (especially when moving out of any zone, so the map shows the whole continent)
-- are not accompanied by any event. So we just check repeatedly.
local function TimedUpdate()
  if WorldMapFrame:IsShown() then
    CheckMap()
  end
end

local updateTimer
local function StartMapUpdates()
  if updateTimer then return end
  updateTimer = C_Timer.NewTicker(1, TimedUpdate)
end

local function StopMapUpdates()
  if updateTimer then
    updateTimer:Cancel()
    updateTimer = nil
  end
end

-- Use in OnShow/OnHide
WorldMapFrame:HookScript("OnShow", StartMapUpdates)
WorldMapFrame:HookScript("OnHide", StopMapUpdates)





-- During combat, the OnClick functions of the dungeon/boss pins do not work due to taint,
-- which is why we are emulating their behaviour manually.
local function HookPins()

  if WorldMapFrame.ScrollContainer.Child then
    local kids = { WorldMapFrame.ScrollContainer.Child:GetChildren() }
    for _, v in ipairs(kids) do
      -- print("pinTemplate", v.pinTemplate, v.instanceID, v.journalInstanceID)

      if v.pinTemplate and not v.pwm_alreadyHooked and (v.pinTemplate == "EncounterJournalPinTemplate" or v.pinTemplate == "DungeonEntrancePinTemplate") then

        -- local instanceID = v.instanceID or v.journalInstanceID
        -- local encounterID = v.encounterID

        local OriginalOnClick = v.OnClick
        v.OnClick = function(...)

          local _, button = ...
          -- Got to save pinTemplate, because it might be gone after we do SetMapID() below.
          local pinTemplate = v.pinTemplate

          if InCombatLockdown() then

            -- Actually not needed, because OriginalOnClick() will take care of this.
            -- if instanceID then  EncounterJournal_DisplayInstance(instanceID) end
            -- if encounterID then EncounterJournal_DisplayEncounter(encounterID) end

            -- For EncounterJournalPinTemplate, only the left button opens EncounterJournal.
            -- For DungeonEntrancePinTemplate, only the right button opens EncounterJournal.
            if (pinTemplate == "EncounterJournalPinTemplate" and button == "LeftButton") or (pinTemplate == "DungeonEntrancePinTemplate" and button == "RightButton") then
              if not EncounterJournal:IsShown() then
                EncounterJournal:Show()
              else
                EncounterJournal:Raise()
              end

            -- For EncounterJournalPinTemplate the right click changes the map to the parent map.
            -- As this is tainted during combat lockdown, we have to do it manually.
            elseif (pinTemplate == "EncounterJournalPinTemplate" and button == "RightButton") then
              local mapInfo = C_Map_GetMapInfo(WorldMapFrame:GetMapID())
              if mapInfo.parentMapID then
                WorldMapFrame:SetMapID(mapInfo.parentMapID)
              end
            end

            -- Only original-click for the un-tainted clicks.
            if (pinTemplate ~= "EncounterJournalPinTemplate" or button ~= "RightButton") then
              OriginalOnClick(...)
            end

          else
            OriginalOnClick(...)
          end

        end

        v.pwm_alreadyHooked = true
      end
    end
  end
end


hooksecurefunc(WorldMapFrame, "SetMapID",
  function(self, mapID)
    -- print("SetMapID", mapID, MapUtil_GetDisplayableMapForPlayer())

    if WorldMapFrame:IsShown() then
      lastViewedMapWasCurrentMap = (mapID == MapUtil_GetDisplayableMapForPlayer())
      if not lastViewedMapWasCurrentMap then
        EnableRecenterButton()
      else
        DisableRecenterButton()
      end
    end

    HookPins()
  end
)


-- If the dungeon pins were not activated when the map was first changed,
-- we need to execute the hooks again, when the user activates them.
hooksecurefunc(WorldMapFrame, "RefreshAllDataProviders",
  function(...)
    HookPins()
  end
)








-- If you add quest tracker entries, these are tainted until the next /reload.
-- QuestMapFrame_OpenToQuestDetails is called when clicking on a quest tracker entry
-- or when clicking on the ShowMapButton of QuestLogPopupDetailFrame.
-- During combat, QuestMapFrame_OpenToQuestDetails does not manage
-- to bring up WorldMapFrame and hide EncounterJournal and QuestLogPopupDetailFrame.
local OriginalQuestMapFrame_OpenToQuestDetails = QuestMapFrame_OpenToQuestDetails
QuestMapFrame_OpenToQuestDetails = function(...)

  if InCombatLockdown() then
    if not WorldMapFrame:IsShown() then
      WorldMapFrame:Show()
    else
      WorldMapFrame:Raise()
    end
  end

  -- Mapster prevents the quest frame from being closed, which results in an empty quest frame.
  if QuestFrame:IsShown() then
    QuestFrame_OnHide()
  end

  OriginalQuestMapFrame_OpenToQuestDetails(...)
end




-- QuestLogPopupDetailFrame_Show is called when you right click
-- on a quest tracker entry and select "Open Quest Details".
-- During combat, QuestLogPopupDetailFrame_Show does not manage to
-- bring up QuestLogPopupDetailFrame, so we have to show it manually.
local OriginalQuestLogPopupDetailFrame_Show = QuestLogPopupDetailFrame_Show
QuestLogPopupDetailFrame_Show = function(...)

  if InCombatLockdown() then

    if not QuestLogPopupDetailFrame:IsShown() then
      QuestLogPopupDetailFrame:Show()

    else
      -- If QuestLogPopupDetailFrame is already shown for the clicked quest,
      -- it should be closed, which QuestLogPopupDetailFrame_Show with
      -- its HideUIPanel() also cannot do during combat.
      local questLogIndex = ...
      local questID = C_QuestLog.GetQuestIDForLogIndex(questLogIndex)
      if QuestLogPopupDetailFrame.questID == questID then
        QuestLogPopupDetailFrame:Hide()
        return
      else
        QuestLogPopupDetailFrame:Raise()
      end
    end
  end

  OriginalQuestLogPopupDetailFrame_Show(...)
end





local function CloseWorldMapFrame(orReset)
  if WorldMapFrame:IsShown() then

    -- During combat, we cannot use HideUIPanel(WorldMapFrame).
    if InCombatLockdown() then

      -- WorldMapFrame:Hide() will lead to ToggleGameMenu() not working any more
      -- because WorldMapFrame will still be listed in UIParent's FramePositionDelegate.
      -- Blizzard_UIParentPanelManager/Mainline\UIParentPanelManager.lua, L871
      -- So we only hide it, if WorldMapFrame is not in UIPanelWindows (e.g. Mapster).
      if not UIPanelWindows["WorldMapFrame"] then
        WorldMapFrame:Hide()

      -- Only QuestMapFrame.DetailsFrame (side pane) or QuestLogPopupDetailFrame
      -- can show the quest details; but not both at the same time.
      -- The other gets emptied, which looks odd if it is not hidden.
      -- Thus, when we cannot hide WorldMapFrame, we can at least
      -- prevent the empty side pane by restoring it to the default.
      elseif orReset then
        QuestMapFrame_ReturnFromQuestDetails()
      end

    else
      HideUIPanel(WorldMapFrame)
    end
  end
end

local function CloseEncounterJournal()
  if EncounterJournal:IsShown() then
    if InCombatLockdown() then
      EncounterJournal:Hide()
    else
      HideUIPanel(EncounterJournal)
    end
  end
end

local function CloseQuestLogPopupDetailFrame()
  if QuestLogPopupDetailFrame:IsShown() then
    if InCombatLockdown() then
      QuestLogPopupDetailFrame:Hide()
    else
      HideUIPanel(QuestLogPopupDetailFrame)
    end
  end
end




local startupFrame = CreateFrame("Frame")
startupFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
startupFrame:SetScript("OnEvent", function(_, _, isLogin, isReload)

  if not isLogin and not isReload then
    lastMapID = nil
    return
  end

  -- Needed for the boss pins to work in combat lockdown.
  if not C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal") then
    EncounterJournal_LoadUI()
  end

  -- Got to call this to bring the frames into the right position.
  -- Otherwise they will be misplaced when frame:Show() is called
  -- before the first ShowUIPanel(frame).
  WorldMapFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
  EncounterJournal:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
  QuestLogPopupDetailFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)


  -- Otherwise closing with ESC may not work during combat.
  tinsert(UISpecialFrames, "WorldMapFrame")
  tinsert(UISpecialFrames, "EncounterJournal")
  tinsert(UISpecialFrames, "QuestLogPopupDetailFrame")


  -- May be prevented by other addons.
  -- TODO: Make mutual exclusiveness optional!
  EncounterJournal:HookScript("OnShow", function()
    CloseWorldMapFrame()
    CloseQuestLogPopupDetailFrame()
  end)

  QuestLogPopupDetailFrame:HookScript("OnShow", function()
    CloseWorldMapFrame(true)
    CloseEncounterJournal()
  end)


  -- We should not hide WorldMapFrame during combat,
  -- because this prevents ESC from working afterwards.
  -- Hence, showing WorldMapFrame is sometimes not enough.
  -- We also need to raise it.
  hooksecurefunc("OpenWorldMap", function(...)
    WorldMapFrame:Raise()
  end)

  WorldMapFrame:HookScript("OnShow", function()
    CloseEncounterJournal()
    CloseQuestLogPopupDetailFrame()
  end)

  hooksecurefunc(WorldMapFrame, "Raise", function(...)
    CloseEncounterJournal()
    CloseQuestLogPopupDetailFrame()
  end)


  -- Put the recenter button below the map pin button.
  local mapPinButton
  for i, child in pairs({WorldMapFrame:GetChildren()}) do
    -- print(i, child, child.Icon, child.Icon and child.Icon:GetAtlas() or "")
    if child.Icon and child.Icon:GetAtlas() == "Waypoint-MapPin-Untracked" then
      -- print("Found legend button:" , child:GetObjectType(), child:GetDebugName(), child.Icon:GetAtlas())
      mapPinButton = child
    end
  end
  CreateMapButtons(mapPinButton)

  -- TODO: Try if this allows us to hide the world map during combat lockdown:
  -- purgeKey(UIPanelWindows, "WorldMapFrame")
  -- table.insert(UISpecialFrames, "WorldMapFrame")

end)





-- Disable center on player when trying to drag the map.
-- Enable when double-clicking the map.

local isMouseDown = false
local lastCursorX = nil
local lastCursorY = nil

-- For double click detection
local lastClickTime = 0

-- Shift click the map to reset it!
local resetMap = false


WorldMapFrame.ScrollContainer:HookScript("OnMouseDown", function(self, button)
  if button == "LeftButton" then
    isMouseDown = true
    lastCursorX, lastCursorY = GetScaledCursorPosition()


    if self:CanPan() then
      -- Immediately set target scale to current scale to stop any zoom animation.
      self.targetScale = self:GetCanvasScale()
      self.currentScale = self.targetScale
    end


    if IsShiftKeyDown() then
      ResetMap()
      resetMap = true
    else
      resetMap = false
    end

  end
end)

WorldMapFrame.ScrollContainer:HookScript("OnMouseUp", function(self, button)
  if button == "LeftButton" then
    isMouseDown = false

    -- Check for double click
    local currentTime = GetTime()
    if currentTime - lastClickTime < DOUBLE_CLICK_TIME then
      EnableCenterOnPlayer()
    end
    lastClickTime = currentTime

    -- Got to do this because otherwise the map of the cursor position gets
    -- loaded when releasing the mouse button.
    if resetMap then
      ResetMap()
      PlayerPingAnimation(false)
      resetMap = false
    end
  end
end)



WorldMapFrame.ScrollContainer:HookScript("OnUpdate", function(self)
  -- Disable auto-centering when player starts to drag.
  if isMouseDown then
    local cursorX, cursorY = GetScaledCursorPosition()
    if cursorX ~= lastCursorX or cursorY ~= lastCursorY then
      DisableCenterOnPlayer()
    end
  end

  -- Ensure that targetScale exists. Not checking this sometimes caused an error when changing into a zone with loading screen.
  if not self.targetScale then return end

  -- Ensure scroll extents are initialized. Has not caused issues so far, but you never know.
  if not self.scrollXExtentsMin or not self.scrollXExtentsMax or
     not self.scrollYExtentsMin or not self.scrollYExtentsMax then
    return
  end

  -- Auto Centering.
  if autoCentering then

    local playerPos = C_Map_GetPlayerMapPosition(self:GetParent():GetMapID(), "player")
    if not playerPos then return end

    local newScrollX, newScrollY = playerPos:GetXY()
    newScrollX = Round(Clamp(newScrollX, self.scrollXExtentsMin, self.scrollXExtentsMax), 3)
    newScrollY = Round(Clamp(newScrollY, self.scrollYExtentsMin, self.scrollYExtentsMax), 3)

    -- Do instant pan while zooming to keep borders of map and frame aligned.
    if self:GetCanvasScale() ~= self.targetScale then
      -- currentScrollX and targetScrollX are not set by SetNormalizedHorizontalScroll()
      -- so we have to set them manually to prevent the map jumping back after auto-centering was disabled.
      if self.currentScrollX ~= newScrollX then
        self.currentScrollX = newScrollX
        self.targetScrollX = newScrollX
        self:SetNormalizedHorizontalScroll(newScrollX)
      end
      if self.currentScrollY ~= newScrollY then
        self.currentScrollY = newScrollY
        self.targetScrollY = newScrollY
        self:SetNormalizedVerticalScroll(newScrollY)
      end
    -- Do smooth pan while not zooming to smoothly move to the player's position.
    else
      if self.currentScrollX ~= newScrollX or self.currentScrollY ~= newScrollY then
        self:SetPanTarget(newScrollX, newScrollY)
      end
    end

  -- If not auto-centering, we just want to make sure that zooming out does not go beyond the map boundaries.
  else

    -- Only needed for zooming out.
    if self:GetCanvasScale() > self.targetScale then
      local newScrollX = Clamp(self:GetCurrentScrollX(), self.scrollXExtentsMin, self.scrollXExtentsMax)
      local newScrollY = Clamp(self:GetCurrentScrollY(), self.scrollYExtentsMin, self.scrollYExtentsMax)
      if self.currentScrollX ~= newScrollX then
        self.currentScrollX = newScrollX
        self.targetScrollX = newScrollX
        self:SetNormalizedHorizontalScroll(newScrollX)
      end
      if self.currentScrollY ~= newScrollY then
        self.currentScrollY = newScrollY
        self.targetScrollY = newScrollY
        self:SetNormalizedVerticalScroll(newScrollY)
      end
    end

  end

end)





-- Enable smooth zoom mode.
WorldMapFrame.ScrollContainer:SetMouseWheelZoomMode(MAP_CANVAS_MOUSE_WHEEL_ZOOM_BEHAVIOR_SMOOTH)

-- Could be used to customize zoom speed (default 0.15)
WorldMapFrame.ScrollContainer.normalizedZoomLerpAmount = 0.25


-- Hook mouse wheel for custom zoom behavior.
WorldMapFrame.ScrollContainer:HookScript("OnMouseWheel", function(self, delta)

  -- If already zoomed out, we stay at the center and are done!
  if delta < 0 and self:IsAtMinZoom() then
    self:SetPanTarget(0.5, 0.5)
    return
  end
  -- For all other cases we have to dynamically calcualte the pan boundaries based on the target scale.

  -- We could do it like MapCanvasScrollControllerMixin:OnMouseWheel()
  -- but this behaves differently on different maps.
  -- local targetScale = currentScale + self.zoomAmountPerMouseWheelDelta * delta

  -- So instead, we use the ScrollContainer's zoom levels to determine the target scale.
  local currentScale = self:GetCanvasScale()
  local currentZoomLevelScale = self.zoomLevels[self:GetZoomLevelIndexForScale(currentScale)].scale
  local nextZoomOutLevelScale, nextZoomInLevelScale = self:GetCurrentZoomRange()
  -- print(nextZoomOutLevelScale, currentZoomLevelScale, nextZoomInLevelScale)

  local scaleStep
  if currentZoomLevelScale == nextZoomOutLevelScale then
    scaleStep = math.abs(currentZoomLevelScale - nextZoomInLevelScale)
  elseif currentZoomLevelScale == nextZoomInLevelScale then
    scaleStep = math.abs(currentZoomLevelScale - nextZoomOutLevelScale)
  elseif currentScale < currentZoomLevelScale then
    scaleStep = math.abs(currentZoomLevelScale - nextZoomOutLevelScale)
  else
    scaleStep = math.abs(currentZoomLevelScale - nextZoomInLevelScale)
  end
  -- TODO: Use self.zoomAmountPerMouseWheelDelta (default 0.075) or your own variable as a factor for targetScale.
  local targetScale = currentScale + scaleStep * delta
  targetScale = Clamp(
    targetScale,
    self:GetScaleForMinZoom(),
    self:GetScaleForMaxZoom()
  )
  -- Override the zoom target set by the original OnMouseWheel.
  self:SetZoomTarget(targetScale)



  -- We want to keep the current pan position, unless it would go beyond the pan boundaries.
  -- TODO: Make zoom-panning towards cursor position optional.
  local currentX = self:GetCurrentScrollX()
  local currentY = self:GetCurrentScrollY()
  -- We only need to check for pan boundaries if we are zooming out.
  if delta < 0 then
    -- Calculate scroll extents for the new scale
    -- to prevent zoom out from going beyond the border.
    local xMin, xMax, yMin, yMax = self:CalculateScrollExtentsAtScale(targetScale)
    currentX = Clamp(currentX, xMin, xMax)
    currentY = Clamp(currentY, yMin, yMax)
  end
  -- Prevent the undesired panning of MAP_CANVAS_MOUSE_WHEEL_ZOOM_BEHAVIOR_SMOOTH.
  self:SetPanTarget(currentX, currentY)
end)




-- -- For debugging.
-- local monitoringFrame = CreateFrame("Frame")
-- local lastScale = nil
-- local function MonitoringFrameOnUpdateFunction(self, elapsed)
  -- local currentScale = WorldMapFrame.ScrollContainer:GetCanvasScale()
  -- print("----", currentScale)
  -- if lastScale == currentScale then
    -- print("++++ Stopping")
    -- monitoringFrame:SetScript("OnUpdate", nil)
    -- lastScale = nil
    -- return
  -- end
  -- lastScale = currentScale
-- end
-- hooksecurefunc(WorldMapFrame.ScrollContainer , "SetZoomTarget", function(self, targetScale)
  -- print("SetZoomTarget", WorldMapFrame.ScrollContainer:GetCanvasScale(), "to", targetScale)
  -- monitoringFrame:SetScript("OnUpdate", MonitoringFrameOnUpdateFunction)
-- end)
