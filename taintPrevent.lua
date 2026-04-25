local folderName, Addon = ...

-- Locals for frequently used global frames and functions.
local InCombatLockdown              = _G.InCombatLockdown
local C_Map_GetMapInfo              = _G.C_Map.GetMapInfo
local QuestLogPopupDetailFrame      = _G.QuestLogPopupDetailFrame
local WorldMapFrame                 = _G.WorldMapFrame


-- ######################################################################################
-- ### Modify ADDON_ACTION_FORBIDDEN popup to add a "Reload UI" button.               ###
-- ######################################################################################

-- The default popup has:
--   button1 = "Disable" (disables addon and reloads)
--   button2 = "Ignore" (dismisses popup)
-- We add a third button to reload without disabling.
local addonForbiddenFrame = CreateFrame("Frame")
addonForbiddenFrame:RegisterEvent("PLAYER_LOGIN")
addonForbiddenFrame:SetScript("OnEvent", function()
  if StaticPopupDialogs and StaticPopupDialogs["ADDON_ACTION_FORBIDDEN"] then
    local popup = StaticPopupDialogs["ADDON_ACTION_FORBIDDEN"]
    -- A modified variant of
    -- ADDON_ACTION_FORBIDDEN = "%s has been blocked from an action only available to the Blizzard UI.\nYou can disable this addon and reload the UI."
    popup.text = "%s has been blocked from an action only available to the Blizzard UI.\n\nIf this happens rarely, try reloading the UI first. Only if this issue keeps repeating unacceptably, consider disabling the addon."
    popup.button3 = RELOADUI or "Reload UI"
    popup.OnAlt = function()
      C_UI.Reload()
    end
  end
end)


-- ######################################################################################
-- ### Prevent PerformEmote/CancelEmote taint.                                        ###
-- ### WorldMapMixin:OnShow() calls C_ChatInfo.PerformEmote("READ", nil, true) and    ###
-- ### WorldMapMixin:OnHide() calls C_ChatInfo.CancelEmote(). Both are protected      ###
-- ### in PvP instances. Because our addon taints WorldMapFrame.mapID, Blizzard's     ###
-- ### OnShow reads the tainted value and the execution context becomes insecure -    ###
-- ### causing ADDON_ACTION_FORBIDDEN for PerformEmote/CancelEmote in PvP.            ###
-- ###                                                                                ###
-- ### Fix: wrap both API functions to skip the "READ" emote in PvP instances.        ###
-- ### This avoids the error without SetScript (which would make all of OnShow        ###
-- ### addon-originated, causing MoneyFrame taint and "secret number" errors).        ###
-- ###                                                                                ###
-- ### Additionally, a HookScript post-hook cancels the emote outside PvP when        ###
-- ### the user has disabled the reading emote in the options.                        ###
-- ######################################################################################
do
  local function IsInPvPInstance()
    local isInstance, instanceType = IsInInstance()
    return isInstance and instanceType == "pvp"
  end

  local origPerformEmote = C_ChatInfo.PerformEmote
  C_ChatInfo.PerformEmote = function(emote, ...)
    if IsInPvPInstance() and emote == "READ" then return end
    return origPerformEmote(emote, ...)
  end

  local origCancelEmote = C_ChatInfo.CancelEmote
  C_ChatInfo.CancelEmote = function(...)
    if IsInPvPInstance() then return end
    return origCancelEmote(...)
  end
end

WorldMapFrame:HookScript("OnShow", function(self)
  if not PWM_config.showReadingEmote then
    C_ChatInfo.CancelEmote()
  end
end)


-- ######################################################################################
-- ### Preventing taint, which would otherwise lead to errors during combat lockdown. ###
-- ######################################################################################

-- Our addon writes to WorldMapFrame.mapID, permanently tainting that property.
-- When Blizzard's secure OnShow -> SetMapID reads the tainted mapID during
-- combat, the execution context becomes insecure, and ALL protected calls
-- in the AcquirePin chain (SetPassThroughButtons, SetPropagateMouseClicks)
-- fail with ADDON_ACTION_BLOCKED. securecallfunction does NOT help - WoW
-- tracks the original writer, not the execution wrapper.
--
-- Fix: we patch SetPassThroughButtons and SetPropagateMouseClicks directly
-- on every pin INSTANCE (shadowing the C widget metatable methods) to skip
-- during combat. We wrap each pin pool's Acquire method so pins are patched
-- at creation time, BEFORE AcquirePin calls them. See the do-block below.
--
-- We intentionally do NOT override AcquirePin itself - doing so would make
-- pin:SetScript("OnEnter"/...) calls register handlers as addon-originated,
-- causing "secret number" taint errors on pin hover during combat. Our
-- pool.Acquire wrapper returns before AcquirePin's SetScript calls, so
-- handler origins stay Blizzard-originated.


-- To do a WorldMapFrame:OnMapChanged() again when combat ends.
-- Just in case this might be important.
Addon.reloadAfterCombat = false


-- Refresh map state once combat ends.
local leaveCombatFrame = CreateFrame("Frame")
leaveCombatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
leaveCombatFrame:SetScript("OnEvent", function()
  if InCombatLockdown() then return end

  if Addon.reloadAfterCombat and WorldMapFrame:IsShown() then
    WorldMapFrame:OnMapChanged()
    Addon.PlayerPingAnimation(false)
  end
  Addon.reloadAfterCombat = false
end)


-- Patch every map pin INSTANCE to prevent taint errors during combat.
-- Our addon writes to WorldMapFrame.mapID, permanently tainting it; during combat
-- the tainted execution context causes:
--  (1) ADDON_ACTION_BLOCKED on SetPassThroughButtons/SetPropagateMouseClicks
--      (called by AcquirePin -> CheckMouseButtonPassthrough).
--  (2) "secret number" errors in tooltip code when hovering pins - data
--      providers set pin properties (poiInfo, questID, etc.) during the
--      tainted OnShow context, so reading those properties in OnMouseEnter
--      taints the tooltip chain, making GetWidth() return secret numbers.
--
-- Fix (1): shadow SetPassThroughButtons/SetPropagateMouseClicks on each
-- pin instance to skip during combat.
-- Fix (2): shadow OnMouseEnter/OnMouseLeave on each pin instance to wrap
-- in pcall during combat - the tooltip may not display perfectly but no
-- errors get reported.
--
-- PatchPin runs inside each pool's Acquire wrapper (before AcquirePin
-- sets OnEnter to pin.OnMouseEnter), so AcquirePin picks up
-- our wrappers automatically. A __newindex metatable on pinPools catches
-- new pools as Blizzard creates them. Because patches are on the pin
-- instance, they survive pool recycling across map opens.
do
  local function PatchPin(pin)
    if pin.pwm_protected_patched then return end
    pin.pwm_protected_patched = true

    local origSetPassThroughButtons = pin.SetPassThroughButtons
    pin.SetPassThroughButtons = function(self, ...)
      if InCombatLockdown() then Addon.reloadAfterCombat = true; return end
      return origSetPassThroughButtons(self, ...)
    end

    local origSetPropagateMouseClicks = pin.SetPropagateMouseClicks
    pin.SetPropagateMouseClicks = function(self, ...)
      if InCombatLockdown() then Addon.reloadAfterCombat = true; return end
      return origSetPropagateMouseClicks(self, ...)
    end

    local origOnMouseEnter = pin.OnMouseEnter
    if origOnMouseEnter then
      pin.OnMouseEnter = function(self, ...)
        if InCombatLockdown() then
          pcall(origOnMouseEnter, self, ...)
          return
        end
        return origOnMouseEnter(self, ...)
      end
    end

    local origOnMouseLeave = pin.OnMouseLeave
    if origOnMouseLeave then
      pin.OnMouseLeave = function(self, ...)
        if InCombatLockdown() then
          pcall(origOnMouseLeave, self, ...)
          return
        end
        return origOnMouseLeave(self, ...)
      end
    end
  end

  local function WrapPoolAcquire(pool)
    if pool.pwm_acquire_wrapped then return end
    pool.pwm_acquire_wrapped = true

    local origAcquire = pool.Acquire
    pool.Acquire = function(self, ...)
      local pin, isNew = origAcquire(self, ...)
      if pin and isNew then
        PatchPin(pin)
      end
      return pin, isNew
    end
  end

  -- Wrap existing pools (created before our addon loaded, if any).
  for pinTemplate, pool in pairs(WorldMapFrame.pinPools) do
    WrapPoolAcquire(pool)
  end

  -- Catch future pool creation via __newindex on the pinPools table.
  setmetatable(WorldMapFrame.pinPools, {
    __newindex = function(t, pinTemplate, pool)
      rawset(t, pinTemplate, pool)
      WrapPoolAcquire(pool)
    end
  })
end






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
-- Using hooksecurefunc to avoid tainting the global function, which would spread
-- to UseQuestLogSpecialItem() and other protected quest functions.
hooksecurefunc("QuestMapFrame_OpenToQuestDetails", function(...)

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
end)




-- QuestLogPopupDetailFrame_Show is called when you right click
-- on a quest tracker entry and select "Open Quest Details".
-- During combat, QuestLogPopupDetailFrame_Show does not manage to
-- bring up QuestLogPopupDetailFrame, so we have to show it manually.
-- Using hooksecurefunc to avoid tainting the global function, which would spread
-- to UseQuestLogSpecialItem() and other protected quest functions.

-- Track the last quest ID shown before the function runs, to detect toggle requests
local lastShownQuestID = nil
QuestLogPopupDetailFrame:HookScript("OnShow", function(self)
  lastShownQuestID = self.questID
end)
QuestLogPopupDetailFrame:HookScript("OnHide", function(self)
  lastShownQuestID = nil
end)

hooksecurefunc("QuestLogPopupDetailFrame_Show", function(questLogIndex)
  if InCombatLockdown() then
    local questID = C_QuestLog.GetQuestIDForLogIndex(questLogIndex)

    -- If the frame was already showing this quest, the user wants to toggle it off
    if lastShownQuestID and lastShownQuestID == questID then
      QuestLogPopupDetailFrame:Hide()
      return
    end

    -- Otherwise, ensure the frame is visible and raised
    if not QuestLogPopupDetailFrame:IsShown() then
      QuestLogPopupDetailFrame:Show()
    else
      QuestLogPopupDetailFrame:Raise()
    end
  end
end)





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
startupFrame:RegisterEvent("PLAYER_LOGIN")
startupFrame:SetScript("OnEvent", function()

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