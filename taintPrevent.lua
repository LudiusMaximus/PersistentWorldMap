local folderName, Addon = ...

-- Locals for frequently used global frames and functions.
local InCombatLockdown              = _G.InCombatLockdown
local C_Map_GetMapInfo                   = _G.C_Map.GetMapInfo
local QuestLogPopupDetailFrame      = _G.QuestLogPopupDetailFrame
local WorldMapFrame                 = _G.WorldMapFrame


-- ######################################################################################
-- ### Preventing taint, which would otherwise lead to errors during combat lockdown. ###
-- ######################################################################################


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
    Addon.PlayerPingAnimation(false)
  end
  reloadAfterCombat = false
end)










-- During combat, the OnClick functions of the dungeon/boss pins do not work due to taint,
-- which is why we are emulating their behaviour manually.
Addon.HookPins = function()

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



  -- TODO: Try if this allows us to hide the world map during combat lockdown:
  -- purgeKey(UIPanelWindows, "WorldMapFrame")
  -- table.insert(UISpecialFrames, "WorldMapFrame")

end)