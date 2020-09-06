

local WorldMapFrame = _G.WorldMapFrame
local MapUtil = _G.MapUtil
local GetTime = _G.GetTime


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


local function SafeMapState()
  lastMapID   = WorldMapFrame:GetMapID()
  lastScale   = WorldMapFrame.ScrollContainer.currentScale
  lastScrollX = WorldMapFrame.ScrollContainer.currentScrollX
  lastScrollY = WorldMapFrame.ScrollContainer.currentScrollY
  -- print("saving", lastMapID, lastScale, lastScrollX, lastScrollY)
end


-- Called when reopenning the map.
local function RestoreMapState()
  -- print("RestoreMapState", lastMapID, lastScale, lastScrollX, lastScrollY)
  if lastMapID and lastScale and lastScrollX and lastScrollY then
    -- print("restoring", lastMapID, lastScale, lastScrollX, lastScrollY)

    WorldMapFrame:SetMapID(lastMapID)

    WorldMapFrame.ScrollContainer.currentScale = lastScale
    WorldMapFrame.ScrollContainer.targetScale = lastScale

    WorldMapFrame.ScrollContainer.currentScrollX = lastScrollX
    WorldMapFrame.ScrollContainer.targetScrollX = lastScrollX

    WorldMapFrame.ScrollContainer.currentScrollY = lastScrollY
    WorldMapFrame.ScrollContainer.targetScrollY = lastScrollY

    WorldMapFrame:OnMapChanged()
  end
end




-- Post hook for ToggleWorldMap to restore map after it is shown.
-- (Cannot do this with WorldMapFrame.ScrollContainer:HookScript("OnShow"),
-- because it gets called too early.)
hooksecurefunc("ToggleWorldMap", function()
  if WorldMapFrame:IsShown() then
    -- print("Post Hook after showing", GetTime(), lastMapCloseTime, GetTime() - lastMapCloseTime, resetMapAfter)
    if GetTime() - lastMapCloseTime > resetMapAfter then
      lastMapID = nil
    else
      RestoreMapState()
    end
  end
end)


-- Pre hook for WorldMapFrame.ScrollContainer OnHide to store map before it is hidden.
-- (Cannot do this with HookScript, because then it is called too late.
-- Also cannot do this in hooksecurefunc of ToggleWorldMap, because then it is not called when
-- closing the map manually.)
local OtherWorldMapFrameOnHideScripts = WorldMapFrame.ScrollContainer:GetScript("OnHide")
WorldMapFrame.ScrollContainer:SetScript("OnHide", function(self, ...)
  -- print("Prehook before Hiding")
  lastMapCloseTime = GetTime()
  SafeMapState()
  OtherWorldMapFrameOnHideScripts(self, ...)
end)

-- Also got to store and restore when the SidePanelToggle is shown or hidden.
local OtherCloseButtonScripts = WorldMapFrame.SidePanelToggle.CloseButton:GetScript("OnClick")
WorldMapFrame.SidePanelToggle.CloseButton:SetScript("OnClick", function(self, ...)
  SafeMapState()
  OtherCloseButtonScripts(self, ...)
  RestoreMapState()
end)
local OtherOpenButtonScripts = WorldMapFrame.SidePanelToggle.OpenButton:GetScript("OnClick")
WorldMapFrame.SidePanelToggle.OpenButton:SetScript("OnClick", function(self, ...)
  SafeMapState()
  OtherOpenButtonScripts(self, ...)
  RestoreMapState()
end)



local function ResetMap()
  WorldMapFrame:SetMapID(MapUtil.GetDisplayableMapForPlayer())
  local currentScale = WorldMapFrame.ScrollContainer:GetCanvasScale()
  local currentZoomLevel = WorldMapFrame.ScrollContainer:GetZoomLevelIndexForScale(currentScale)

  -- Got to do this to avoid funny shift of the map by 1 pixel...
  if currentZoomLevel ~= 1 then
    WorldMapFrame:ResetZoom()
  end

  SafeMapState()

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




resetButton = CreateFrame("Button", nil, WorldMapFrame.ScrollContainer, "UIPanelButtonTemplate")
resetButton:SetPoint("BOTTOMRIGHT", WorldMapFrame.SidePanelToggle.CloseButton, "BOTTOMLEFT", 1, 1)
resetButton:SetText("Reset View")
resetButton:SetWidth(120)
resetButton:SetScript("OnClick", function()
    ResetMap()
	end)
resetButton:Hide()



local startupFrame = CreateFrame("Frame")
startupFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
startupFrame:SetScript("OnEvent", function()

  -- Needed for the boss pins to work in combat lockdown.
  if not IsAddOnLoaded("Blizzard_EncounterJournal") then
    EncounterJournal_LoadUI()
  end
  -- Open once to initialise.
  EncounterJournal_OpenJournal()

  -- If you just do EncounterJournal:Hide(), ESC to open the menu will not
  -- work right after login.
  EncounterJournalCloseButton:Click()

  -- Otherwise closing EncounterJournal with ESC may not work during combat.
  tinsert(UISpecialFrames, "EncounterJournal")
end)


hooksecurefunc(WorldMapFrame, "SetMapID", function(self, mapID)
    -- print("SetMapID", mapID, MapUtil.GetDisplayableMapForPlayer())

    if WorldMapFrame:IsShown() then
      lastViewedMapWasCurrentMap = (mapID == MapUtil.GetDisplayableMapForPlayer())
      if mapID ~= MapUtil.GetDisplayableMapForPlayer() then
        resetButton:Show()
      else
        resetButton:Hide()
      end
    end


    -- Needed for the boss pins to work in combat lockdown.
    if WorldMapFrame.ScrollContainer.Child then
      local kids = { WorldMapFrame.ScrollContainer.Child:GetChildren() };
      for _, v in ipairs(kids) do
        -- print (v.pinTemplate)

        if v.pinTemplate and (v.pinTemplate == "EncounterJournalPinTemplate" or v.pinTemplate == "DungeonEntrancePinTemplate") then
          local instanceID = v.instanceID or v.journalInstanceID
          local encounterID = v.encounterID
          -- print (instanceID, encounterID)

          local OriginalOnClick = v.OnClick
          v.OnClick = function(...)
            if InCombatLockdown() then
              EncounterJournal_DisplayInstance(instanceID)
              if encounterID then EncounterJournal_DisplayEncounter(encounterID) end
              EncounterJournal:Show()
            else
              OriginalOnClick(...)
            end

            -- Mapster prevents the map from closing. Default behaviour is closing though...
            WorldMapFrame:Hide()
          end
        end
      end
    end
  end)


-- Frame to listen to zone change events
-- such that the map gets reset when opened after having
-- changed into an area with a different map.
local zoneChangeFrame = CreateFrame ("Frame")

-- But only do this for areas, not for sub-zone changes.
zoneChangeFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
zoneChangeFrame:RegisterEvent("ZONE_CHANGED")
zoneChangeFrame:RegisterEvent("ZONE_CHANGED_INDOORS")
zoneChangeFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
-- Needed for map changes in dungeons.
zoneChangeFrame:RegisterEvent("AREA_POIS_UPDATED")

zoneChangeFrame:SetScript("OnEvent", function(self, event, ...)
  -- print(event, ":", GetZoneText(), GetSubZoneText(), WorldMapFrame:GetMapID(), MapUtil.GetDisplayableMapForPlayer(), lastViewedMapWasCurrentMap)

  if WorldMapFrame:GetMapID() ~= MapUtil.GetDisplayableMapForPlayer() then
    if lastViewedMapWasCurrentMap then
      ResetMap()
    else
      resetButton:Show()
    end
  else
    resetButton:Hide()
  end

end)



-- Needed to fix taint of newly added quest tracker entries.
-- Otherwise the map does not open when clicking on these.
local originalObjectiveTrackerBlockHeader_OnClick = ObjectiveTrackerBlockHeader_OnClick
ObjectiveTrackerBlockHeader_OnClick = function(...)
  local _, mouseButton = ...

  -- Only for non-shift left button when in combat lockdown.
  if not InCombatLockdown() or IsShiftKeyDown() or mouseButton ~= "LeftButton" then
    return originalObjectiveTrackerBlockHeader_OnClick(...)
  end

  WorldMapFrame:Show()
  originalObjectiveTrackerBlockHeader_OnClick(...)
end

