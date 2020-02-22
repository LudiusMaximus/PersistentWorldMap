
local lastMapID   = nil
local lastScale   = nil
local lastScrollX = nil
local lastScrollY = nil

-- Store if the last viewed map was the player's current map.
-- If not we shall only reset the lastMapID when changing to
-- a whole new area.
local lastMapWasCurrentMap = true


local function SafeMapState()
  lastMapID   = WorldMapFrame:GetMapID()
  lastScale   = WorldMapFrame.ScrollContainer.currentScale
  lastScrollX = WorldMapFrame.ScrollContainer.currentScrollX
  lastScrollY = WorldMapFrame.ScrollContainer.currentScrollY
  -- print("saving", lastMapID, lastScale, lastScrollX, lastScrollY)

  if lastMapID == MapUtil.GetDisplayableMapForPlayer() then
    lastMapWasCurrentMap = true
  else
    lastMapWasCurrentMap = false
  end
end


local function RestoreMapState()
  -- print("trying", lastMapID, lastScale, lastScrollX, lastScrollY)
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
-- (Cannot do this with HookScript, because it gets called too early.)
hooksecurefunc("ToggleWorldMap", function()
  if WorldMapFrame:IsShown() then
    -- print("Post Hook after showing")
    RestoreMapState()
  end
end)


-- Pre hook for WorldMapFrame.ScrollContainer OnHide to store map before it is hidden.
-- (Cannot do this by overriding ToggleWorldMap, because then the map is not toggled
-- any more during combat.)
local OtherWorldMapFrameOnHideScripts = WorldMapFrame.ScrollContainer:GetScript("OnHide")
WorldMapFrame.ScrollContainer:SetScript("OnHide", function(self, ...)
  -- print("Prehook before Hiding")
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



-- Shift click the map to reset it!
local resetMap = false
WorldMapFrame.ScrollContainer:HookScript("OnMouseDown", function(self)
  if IsShiftKeyDown() then
    WorldMapFrame:SetMapID(MapUtil.GetDisplayableMapForPlayer())
    resetMap = true
  else
    resetMap = false
  end
end)
-- Got to do this here as well because otherwise the map of the cursor position gets
-- loaded when releasing the mouse button.
WorldMapFrame.ScrollContainer:HookScript("OnMouseUp", function(self)
  if resetMap then
    WorldMapFrame:SetMapID(MapUtil.GetDisplayableMapForPlayer())
    resetMap = false
  end
end)


-- Frame to listen to zone change events
-- such that the map gets reset when opened after having
-- changed into an area with a different map.
local zoneChangeFrame = CreateFrame ("Frame")

-- But only do this for areas, not for sub-zone changes.
zoneChangeFrame:RegisterEvent("ZONE_CHANGED")
zoneChangeFrame:RegisterEvent("ZONE_CHANGED_INDOORS")
zoneChangeFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
zoneChangeFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

zoneChangeFrame:SetScript("OnEvent", function(self, event, ...)
  -- print(event, ":", GetZoneText(), GetSubZoneText(), WorldMapFrame:GetMapID(), MapUtil.GetDisplayableMapForPlayer(), lastMapWasCurrentMap)

  -- For small zone changes we are not resetting the map, if the player was previously looking at a different map.
  if not lastMapWasCurrentMap and event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
    return
  else
    -- Only reset the map if this zone's map is a different one.
    if lastMapID ~= MapUtil.GetDisplayableMapForPlayer() then
      lastMapID = nil
    end
  end

end)

