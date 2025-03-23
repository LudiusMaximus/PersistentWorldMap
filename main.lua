

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
  end
  reloadAfterCombat = false
end)






local C_Map         = _G.C_Map
local GetTime       = _G.GetTime
local MapUtil       = _G.MapUtil
local WorldMapFrame = _G.WorldMapFrame



-- Forward declaration
local CheckMap

-- Flag to prevent saving before map was first shown.
local firstShownAfterLogin = false

local lastMapID   = nil
local lastScale   = nil
local lastScrollX = nil
local lastScrollY = nil

-- Only store the last map for a short time.
local lastMapCloseTime = GetTime()
local resetMapAfter = 15

-- If the last viewed map was the map in which the player was,
-- we want the map to automatically change to the new map;
-- both if the map is visible or not.
local lastViewedMapWasCurrentMap = false


local function SaveMapState()
  if not firstShownAfterLogin then return end

  lastMapID   = WorldMapFrame:GetMapID()
  lastScale   = WorldMapFrame.ScrollContainer.currentScale
  lastScrollX = WorldMapFrame.ScrollContainer.currentScrollX
  lastScrollY = WorldMapFrame.ScrollContainer.currentScrollY
  -- print("saving", lastMapID, lastScale, lastScrollX, lastScrollY)
end


-- Called when reopenning the map.
local function RestoreMapState()
  if lastMapID and lastScale and lastScrollX and lastScrollY then
    -- print("restoring", lastMapID, lastScale, lastScrollX, lastScrollY)

    -- Content of WorldMapFrame:SetMapID(lastMapID) separated:
    local mapArtID = C_Map.GetMapArtID(lastMapID)
    if WorldMapFrame.mapID ~= lastMapID or WorldMapFrame.mapArtID ~= mapArtID then
      WorldMapFrame.areDetailLayersDirty = true;
      WorldMapFrame.mapID = lastMapID;
      WorldMapFrame.mapArtID = mapArtID;
      WorldMapFrame.expandedMapInsetsByMapID = {};
      WorldMapFrame.ScrollContainer:SetMapID(lastMapID);
      if WorldMapFrame:IsShown() then
        WorldMapFrame:RefreshDetailLayers();
      end
    end

    lastViewedMapWasCurrentMap = (lastMapID == MapUtil.GetDisplayableMapForPlayer())

    WorldMapFrame.ScrollContainer.currentScale = lastScale
    WorldMapFrame.ScrollContainer.targetScale = lastScale

    WorldMapFrame.ScrollContainer.currentScrollX = lastScrollX
    WorldMapFrame.ScrollContainer.targetScrollX = lastScrollX

    WorldMapFrame.ScrollContainer.currentScrollY = lastScrollY
    WorldMapFrame.ScrollContainer.targetScrollY = lastScrollY

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
  
    -- print("Post Hook after showing", GetTime(), lastMapCloseTime, GetTime() - lastMapCloseTime, resetMapAfter)
    if GetTime() - lastMapCloseTime > resetMapAfter then
      lastMapID = nil
    else
      RestoreMapState()
    end
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
WorldMapFrame.SidePanelToggle.CloseButton:SetScript("OnClick", function(self, ...)
  SaveMapState()
  OtherCloseButtonScripts(self, ...)
  RestoreMapState()
end)
local OtherOpenButtonScripts = WorldMapFrame.SidePanelToggle.OpenButton:GetScript("OnClick")
WorldMapFrame.SidePanelToggle.OpenButton:SetScript("OnClick", function(self, ...)
  SaveMapState()
  OtherOpenButtonScripts(self, ...)
  RestoreMapState()
end)



local function ResetMap()

  -- print("ResetMap", MapUtil.GetDisplayableMapForPlayer())
  WorldMapFrame:SetMapID(MapUtil.GetDisplayableMapForPlayer())
  local currentScale = WorldMapFrame.ScrollContainer:GetCanvasScale()
  local currentZoomLevel = WorldMapFrame.ScrollContainer:GetZoomLevelIndexForScale(currentScale)

  -- Got to do this to avoid funny shift of the map by 1 pixel...
  if currentZoomLevel ~= 1 then
    WorldMapFrame:ResetZoom()
  end

  SaveMapState()

  WorldMapFrame:OnMapChanged()
end


-- Shift click the map to reset it!
local resetMap = false
WorldMapFrame.ScrollContainer:HookScript("OnMouseDown", function(self)
  if IsShiftKeyDown() then
    ResetMap()
    resetMap = true
  else
    resetMap = false
  end
end)
-- Got to do this because otherwise the map of the cursor position gets
-- loaded when releasing the mouse button.
WorldMapFrame.ScrollContainer:HookScript("OnMouseUp", function(self)
  if resetMap then
    ResetMap()
    resetMap = false
  end
end)







local recenterButton = nil

local RecenterButtonEnterFunction = function(button)
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")

  if button:IsEnabled() then
    GameTooltip:SetText("|cffffffffClick to re-center map\n(or shift-click on map)|r")
  else
    GameTooltip:SetText("|cffffffffMap already centered|r")
  end
end

local function EnableRecenterButton()
  if not recenterButton then return end
  recenterButton.centerDot.t:SetVertexColor(0, 0, 0, 1)
  recenterButton:SetEnabled(true)
  if GameTooltip:GetOwner() == recenterButton then
    RecenterButtonEnterFunction(recenterButton)
  end
end

local function DisableRecenterButton()
  if not recenterButton then return end
  recenterButton.centerDot.t:SetVertexColor(1, 0.9, 0, 1)
  recenterButton:SetEnabled(false)
  if GameTooltip:GetOwner() == recenterButton then
    RecenterButtonEnterFunction(recenterButton)
  end
end


local function CreateRecenterButton(anchorButton)
  -- Template in RecenterButtonTemplate.xml copied from WorldMapTrackingPinButtonTemplate
  -- in Blizzard's \Interface\AddOns\Blizzard_WorldMap\Blizzard_WorldMapTemplates.xml
  recenterButton = CreateFrame("Button", nil, WorldMapFrame.ScrollContainer, "RecenterButtonTemplate")
  recenterButton:SetPoint("TOPRIGHT", anchorButton, "BOTTOMRIGHT", 0, 0)

  recenterButton:SetScript("OnClick", function()
      ResetMap()
      DisableRecenterButton()
    end)

  recenterButton:SetScript("OnEnter", function(self)
      RecenterButtonEnterFunction(self)
    end)

  recenterButton:SetScript("OnLeave", function(self)
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
end




-- Forward declaration above.
CheckMap = function()
  if WorldMapFrame:GetMapID() ~= MapUtil.GetDisplayableMapForPlayer() then
    if lastViewedMapWasCurrentMap then
      ResetMap()
    else
      EnableRecenterButton()
    end
  else
    DisableRecenterButton()
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
      -- print(event, ":", GetZoneText(), GetSubZoneText(), WorldMapFrame:GetMapID(), MapUtil.GetDisplayableMapForPlayer(), lastViewedMapWasCurrentMap)
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
C_Timer.NewTicker(1, TimedUpdate)







-- During combat, the OnClick functions of the dungeon/boss pins do not work due to taint,
-- which is why we are emulating their behaviour manually.
local function HookPins()

  if WorldMapFrame.ScrollContainer.Child then
    local kids = { WorldMapFrame.ScrollContainer.Child:GetChildren() };
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
              local mapInfo = C_Map.GetMapInfo(WorldMapFrame:GetMapID())
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
    -- print("SetMapID", mapID, MapUtil.GetDisplayableMapForPlayer())

    if WorldMapFrame:IsShown() then
      lastViewedMapWasCurrentMap = (mapID == MapUtil.GetDisplayableMapForPlayer())
      if mapID ~= MapUtil.GetDisplayableMapForPlayer() then
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
  if not isLogin and not isReload then return end

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
  CreateRecenterButton(mapPinButton)

  -- TODO: Try if this allows us to hide the world map during combat lockdown:
  -- purgeKey(UIPanelWindows, "WorldMapFrame")
  -- table.insert(UISpecialFrames, "WorldMapFrame")

end)
