local folderName, Addon = ...

-- Locals for frequently used global frames and functions.
local MapUtil_GetDisplayableMapForPlayer = _G.MapUtil.GetDisplayableMapForPlayer
local C_Map_GetPlayerMapPosition         = _G.C_Map.GetPlayerMapPosition
local C_Map_GetMapArtID                  = _G.C_Map.GetMapArtID

local Clamp                     = _G.Clamp
local GetTime                   = _G.GetTime
local WorldMapFrame             = _G.WorldMapFrame


-- #######################################################################
-- ### - Storing and restoring the map when closing and re-opening it. ###
-- ### - Automatically switching to current map when changing zones    ###
-- #######################################################################


-- To store map status when closing it.
local lastMapID   = nil
local lastScale   = nil
local lastScrollX = nil
local lastScrollY = nil

-- Flag to prevent saving before map was first shown.
local firstShownAfterLogin = false

-- Only store the last map for RESET_MAP_AFTER seconds.
local lastMapCloseTime = GetTime()
-- TODO: Make optional.
local RESET_MAP_AFTER = 15

-- If the last viewed map was the map in which the player was,
-- we want the map to automatically change to the new map;
-- both if the map is visible or not.
local lastViewedMapWasCurrentMap = false




local function CheckMap()

  local currentMap = MapUtil_GetDisplayableMapForPlayer()

  if WorldMapFrame:GetMapID() ~= currentMap then
    if lastViewedMapWasCurrentMap then
      -- If auto-centering is active, we want to preserve the zoom level.
      Addon.ResetMap(Addon.autoCentering)
    else
      Addon.RecenterButtonSetEnabled(true)
    end
  else
    Addon.RecenterButtonSetEnabled(false)
  end

  if C_Map_GetPlayerMapPosition(currentMap, "player") then
    Addon.AutoCenterLockButtonSetEnabled(true)
  else
    Addon.AutoCenterLockButtonSetEnabled(false)
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

    -- Selected content of WorldMapFrame:SetMapID(lastMapID):
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

    
    WorldMapFrame.ScrollContainer:InstantPanAndZoom(lastScale, lastScrollX, lastScrollY, true)
    WorldMapFrame:OnMapChanged()

    lastViewedMapWasCurrentMap = (lastMapID == MapUtil_GetDisplayableMapForPlayer())
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
  Addon.PlayerPingAnimation(false)
end)
local OtherOpenButtonScripts = WorldMapFrame.SidePanelToggle.OpenButton:GetScript("OnClick")
WorldMapFrame.SidePanelToggle.OpenButton:SetScript("OnClick", function(...)
  SaveMapState()
  OtherOpenButtonScripts(...)
  RestoreMapState()
  Addon.PlayerPingAnimation(false)
end)





Addon.ResetMap = function(preserveZoom)

  local previousScale = WorldMapFrame.ScrollContainer.currentScale

  -- print("ResetMap", MapUtil_GetDisplayableMapForPlayer())
  WorldMapFrame:SetMapID(MapUtil_GetDisplayableMapForPlayer())

  previousScale = Clamp(previousScale, WorldMapFrame.ScrollContainer:GetScaleForMinZoom(), WorldMapFrame.ScrollContainer:GetScaleForMaxZoom())

  if preserveZoom then
    print("restoring", previousScale)
    WorldMapFrame.ScrollContainer.currentScale = previousScale
    WorldMapFrame.ScrollContainer.targetScale = previousScale
    WorldMapFrame:OnMapChanged()
    
    -- TODO: Find out if the player pin has changed its absolute position and only ping then.
    -- Addon.PlayerPingAnimation(false)
  else
    WorldMapFrame:OnMapChanged()
  end

  SaveMapState()
end





hooksecurefunc(WorldMapFrame, "SetMapID",
  function(self, mapID)
    -- print("SetMapID", mapID, MapUtil_GetDisplayableMapForPlayer())

    if WorldMapFrame:IsShown() then
      lastViewedMapWasCurrentMap = (mapID == MapUtil_GetDisplayableMapForPlayer())
      if not lastViewedMapWasCurrentMap then
        Addon.RecenterButtonSetEnabled(true)
      else
        Addon.RecenterButtonSetEnabled(false)
      end
    end

    Addon.HookPins()
  end
)


-- If the dungeon pins were not activated when the map was first changed,
-- we need to execute the hooks again, when the user activates them.
hooksecurefunc(WorldMapFrame, "RefreshAllDataProviders",
  function(...)
    Addon.HookPins()
  end
)



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




-- Some map changes (especially when moving out of any zone, so that the map shows the whole continent)
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





local startupFrame = CreateFrame("Frame")
startupFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
startupFrame:SetScript("OnEvent", function(_, _, isLogin, isReload)
  -- After each loading screen, reset the map memory.
  lastMapID = nil
end)