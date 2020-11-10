
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


hooksecurefunc(WorldMapFrame, "SetMapID",
  function(self, mapID)
    -- print("SetMapID", mapID, MapUtil.GetDisplayableMapForPlayer())

    if WorldMapFrame:IsShown() then
      lastViewedMapWasCurrentMap = (mapID == MapUtil.GetDisplayableMapForPlayer())
      if mapID ~= MapUtil.GetDisplayableMapForPlayer() then
        resetButton:Show()
      else
        resetButton:Hide()
      end
    end


    -- During combat, the OnClick functions of the dungeon/boss pins do not manage
    -- to bring up EncounterJournal and hide WorldMapFrame.
    if WorldMapFrame.ScrollContainer.Child then
      local kids = { WorldMapFrame.ScrollContainer.Child:GetChildren() };
      for _, v in ipairs(kids) do
        -- print (v.pinTemplate)

        if v.pinTemplate and (v.pinTemplate == "EncounterJournalPinTemplate" or v.pinTemplate == "DungeonEntrancePinTemplate") then

          -- local instanceID = v.instanceID or v.journalInstanceID
          -- local encounterID = v.encounterID

          local OriginalOnClick = v.OnClick
          v.OnClick = function(...)
            if InCombatLockdown() then
              -- Actually not needed, because OriginalOnClick() will take care of this.
              -- if instanceID then  EncounterJournal_DisplayInstance(instanceID) end
              -- if encounterID then EncounterJournal_DisplayEncounter(encounterID) end

              if not EncounterJournal:IsShown() then
                EncounterJournal:Show()
              end
              EncounterJournal:Raise()

              -- WorldMapFrame:Hide() will lead to ToggleGameMenu() not working any more
              -- because WorldMapFrame will still be listed in UIParent's FramePositionDelegate.
              -- So we only hide it, if WorldMapFrame is not in UIPanelWindows (e.g. Mapster).
              -- TODO: Make mutual exclusiveness optional!
              if WorldMapFrame:IsShown() and not UIPanelWindows["WorldMapFrame"] then
                WorldMapFrame:Hide()
              end

            else

              -- May be prevented by addons like Mapster.
              -- TODO: Make mutual exclusiveness optional! In this case, only raise!
              HideUIPanel(WorldMapFrame)

            end

            OriginalOnClick(...)
          end
        end
      end
    end
  end
)



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




-- If you add quest tracker entries, these are tainted until the next /reload.
-- QuestMapFrame_OpenToQuestDetails is called when clicking on a quest tracker entry
-- or when clicking on the ShowMapButton of QuestLogPopupDetailFrame.
-- During combat, QuestMapFrame_OpenToQuestDetails does not manage
-- to bring up WorldMapFrame and hide QuestLogPopupDetailFrame.
local OriginalQuestMapFrame_OpenToQuestDetails = QuestMapFrame_OpenToQuestDetails
QuestMapFrame_OpenToQuestDetails = function(...)

  if InCombatLockdown() then
    if not WorldMapFrame:IsShown() then
      WorldMapFrame:Show()
    end
    WorldMapFrame:Raise()

    if QuestLogPopupDetailFrame:IsShown() then
      QuestLogPopupDetailFrame:Hide()
    end
  else
    -- May be prevented by addons like Mapster.
    HideUIPanel(QuestLogPopupDetailFrame)
  end

  OriginalQuestMapFrame_OpenToQuestDetails(...)
end



-- Same as above.
-- QuestLogPopupDetailFrame_Show is called when you right click
-- on a quest tracker entry and select "Open Quest Details".
-- During combat, QuestLogPopupDetailFrame_Show does not manage
-- to bring up QuestLogPopupDetailFrame and hide WorldMapFrame.
local OriginalQuestLogPopupDetailFrame_Show = QuestLogPopupDetailFrame_Show
QuestLogPopupDetailFrame_Show = function(...)

  if InCombatLockdown() then
    if not QuestLogPopupDetailFrame:IsShown() then
      QuestLogPopupDetailFrame:Show()

    -- If QuestLogPopupDetailFrame is already open for the quest,
    -- it should be closed, which QuestLogPopupDetailFrame_Show with
    -- its HideUIPanel() also cannot do during combat.
    else
      local questLogIndex = ...
      local questID = C_QuestLog.GetQuestIDForLogIndex(questLogIndex)
      if QuestLogPopupDetailFrame.questID == questID then
        QuestLogPopupDetailFrame:Hide()
        return
      end
    end

    -- WorldMapFrame:Hide() will lead to ToggleGameMenu() not working any more
    -- because WorldMapFrame will still be listed in UIParent's FramePositionDelegate.
    -- So we only hide it, if WorldMapFrame is not in UIPanelWindows (e.g. Mapster).
    if WorldMapFrame:IsShown() then
      if not UIPanelWindows["WorldMapFrame"] then
        WorldMapFrame:Hide()
      else
        -- It seems that either the QuestMapFrame.DetailsFrame (side pane)
        -- or QuestLogPopupDetailFrame can show the quest details.
        -- The other gets emptied, which looks odd if it is not hidden.
        -- Thus, when we cannot hide WorldMapFrame, we can at least
        -- prevent this empty side pane by restoring it to the default.
        QuestMapFrame_ReturnFromQuestDetails()

      end
    end
  else
    -- May be prevented by addons like Mapster.
    HideUIPanel(WorldMapFrame)
  end

  OriginalQuestLogPopupDetailFrame_Show(...)
end



local startupFrame = CreateFrame("Frame")
startupFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
startupFrame:SetScript("OnEvent", function()

  -- Needed for the boss pins to work in combat lockdown.
  if not IsAddOnLoaded("Blizzard_EncounterJournal") then
    EncounterJournal_LoadUI()
  end

  -- Got to call this to bring the frames into the right position.
  -- Otherwise they will be misplaced when frame:Show() is called
  -- before the first ShowUIPanel(frame).
  EncounterJournal:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
  QuestLogPopupDetailFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
  WorldMapFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)

  -- Otherwise closing with ESC may not work during combat.
  tinsert(UISpecialFrames, "EncounterJournal")
  tinsert(UISpecialFrames, "QuestLogPopupDetailFrame")
  tinsert(UISpecialFrames, "WorldMapFrame")

  QuestLogPopupDetailFrame:HookScript("OnShow", function()
    if WorldMapFrame:IsShown() then
      WorldMapFrame:Hide()
    end
  end)

end)



-- Needed for overlapping WorldMapFrame and EncounterJournal.
hooksecurefunc("OpenWorldMap", function(...)

  -- May be prevented by addons like Mapster.
  -- TODO: Make mutual exclusiveness optional!
  if InCombatLockdown() then
    EncounterJournal:Hide()
  else
    HideUIPanel(EncounterJournal)
  end

  WorldMapFrame:Raise()
end)

