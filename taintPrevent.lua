local folderName, Addon = ...

-- ============================================================================
-- ============================================================================
--
--  taintPrevent.lua -- OVERVIEW
--
--  PersistentWorldMap writes to WorldMapFrame.mapID (to persist the user's
--  last-viewed map across opens). That write permanently taints mapID; from
--  then on, ANY Blizzard code reading mapID inherits PWM-origin taint, and
--  protected calls or measurement-protected reads downstream of that taint
--  fail. WoW provides no API for an addon to assign mapID cleanly, so this
--  file is the workaround layer: defensive patches that keep PWM functional
--  in the presence of its own permanent taint.
--
--  Sections (each is a self-contained `do` block or labelled region):
--
--    (1) ADDON_ACTION_FORBIDDEN popup customization
--        Add a "Reload UI" button so we can offer a graceful recovery from
--        a residual taint trip without forcing the user to disable PWM.
--
--    (2) PerformEmote / CancelEmote guards
--        In PvP instances, the WorldMap "READ" emote becomes a protected
--        call and trips ADDON_ACTION_FORBIDDEN once mapID is tainted.
--        Wrap the two API functions to skip the emote in PvP.
--
--    (3) Reading-emote opt-out
--        OnShow hook that cancels the emote when the user has disabled it.
--
--    (4) Combat-end refresh
--        Declares Addon.reloadAfterCombat (set by section 5's protected-call
--        shadows) and the PLAYER_REGEN_ENABLED handler that refreshes the
--        map once combat ends.
--
--    (5) Custom-tooltip system for map pins
--        PWM-owned tooltip frame + PWM-local copies of the Blizzard tooltip-
--        builder functions that hardcode the global GameTooltip. Routes pin
--        hover tooltips through our frame to dodge the "secret value"
--        measurement-arithmetic trap that fires on the canonical GameTooltip
--        when execution carries PWM-origin taint.
--
--        >>> CONTAINS BLIZZARD-SOURCE COPIES THAT MUST BE AUDITED ON EVERY
--            RETAIL PATCH. See the maintenance banner inside that section. <<<
--
--    (6) Per-pin protected-call shadowing + pool-acquire hook
--        Shadow SetPassThroughButtons / SetPropagateMouseClicks on each pin
--        to skip during combat. The pool-acquire wrapper also dispatches to
--        the custom-tooltip installer from section (5).
--
--    (7) HookPins
--        Manual OnClick emulation for boss / dungeon pins during combat
--        (their normal OnClick is tainted-blocked).
--
--    (8) Quest tracker hooks
--        QuestMapFrame_OpenToQuestDetails and QuestLogPopupDetailFrame_Show
--        don't bring up the right frames during combat -- we do it manually.
--
--    (9) Frame mutual-exclusion helpers
--        Close-X functions that respect combat lockdown.
--
--    (10) PLAYER_LOGIN startup
--         Preload EncounterJournal, fix initial frame anchors, register
--         UISpecialFrames, install the mutual-exclusion HookScripts.
--
-- ============================================================================
-- ============================================================================


-- ============================================================================
-- Locals
-- ============================================================================

local InCombatLockdown              = _G.InCombatLockdown
local C_Map_GetMapInfo              = _G.C_Map.GetMapInfo
local QuestLogPopupDetailFrame      = _G.QuestLogPopupDetailFrame
local WorldMapFrame                 = _G.WorldMapFrame


-- ============================================================================
-- (1) ADDON_ACTION_FORBIDDEN popup -- add a "Reload UI" button
-- ============================================================================
--
-- Blizzard's default popup only offers "Disable [addon] and reload" or
-- "Ignore". We add a third button that reloads without disabling, since the
-- residual taint trips we get are typically transient and a clean reload
-- recovers without sacrificing PWM.
--
do
  local addonForbiddenFrame = CreateFrame("Frame")
  addonForbiddenFrame:RegisterEvent("PLAYER_LOGIN")
  addonForbiddenFrame:SetScript("OnEvent", function()
    if StaticPopupDialogs and StaticPopupDialogs["ADDON_ACTION_FORBIDDEN"] then
      local popup = StaticPopupDialogs["ADDON_ACTION_FORBIDDEN"]
      -- A modified variant of the stock string:
      -- ADDON_ACTION_FORBIDDEN = "%s has been blocked from an action only available to the Blizzard UI.\nYou can disable this addon and reload the UI."
      popup.text = "%s has been blocked from an action only available to the Blizzard UI.\n\nIf this happens rarely, try reloading the UI first. Only if this issue keeps repeating unacceptably, consider disabling the addon."
      popup.button3 = RELOADUI or "Reload UI"
      popup.OnAlt = function()
        C_UI.Reload()
      end
    end
  end)
end


-- ============================================================================
-- (2) Prevent PerformEmote/CancelEmote taint in PvP instances
-- ============================================================================
--
-- WorldMapMixin:OnShow calls C_ChatInfo.PerformEmote("READ", nil, true) and
-- :OnHide calls C_ChatInfo.CancelEmote(). Both are protected in PvP
-- instances. Because our addon taints WorldMapFrame.mapID, Blizzard's OnShow
-- reads the tainted value and the call to PerformEmote runs in insecure
-- execution -- triggering ADDON_ACTION_FORBIDDEN in PvP.
--
-- Fix: wrap both API functions to skip the "READ" emote in PvP instances.
-- We avoid SetScript on OnShow itself because that would make all of OnShow
-- addon-originated, causing MoneyFrame "secret number" errors downstream.
--
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


-- ============================================================================
-- (3) Reading-emote opt-out
-- ============================================================================
--
-- Outside PvP, cancel the reading emote when the user has it disabled.
-- HookScript (not SetScript) so the OnShow handler stays Blizzard-originated.
--
WorldMapFrame:HookScript("OnShow", function(self)
  if not PWM_config.showReadingEmote then
    C_ChatInfo.CancelEmote()
  end
end)


-- ============================================================================
-- (4) Combat-end refresh
-- ============================================================================
--
-- Section (6)'s per-pin protected-call shadows skip protected calls during
-- combat and set this flag so we know a refresh is needed when combat ends.
-- Exposed on Addon because main.lua / restoreAndReset.lua also set it (for
-- their own deferred-refresh paths).
--
Addon.reloadAfterCombat = false

do
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
end


-- ============================================================================
-- ============================================================================
-- ==                                                                        ==
-- ==  (5)  CUSTOM-TOOLTIP SYSTEM FOR MAP PINS                               ==
-- ==                                                                        ==
-- ==  Routes pin hover tooltips through a PWM-owned PWMTooltip frame so     ==
-- ==  that the "secret value" measurement-arithmetic trap that fires on    ==
-- ==  the canonical GameTooltip under PWM-origin taint doesn't trigger.    ==
-- ==                                                                        ==
-- ==  Why this works: the secret-value protection applies to specific       ==
-- ==  Blizzard canonical frames (the global GameTooltip and its built-in    ==
-- ==  child frames). Addon-created instances built from GameTooltipTemplate ==
-- ==  return real numbers from measurement getters even under tainted       ==
-- ==  execution. Routing tooltip builds through PWMTooltip dodges the trap. ==
-- ==                                                                        ==
-- ==  Why we DON'T just swap _G.GameTooltip: writes to a global from        ==
-- ==  tainted execution permanently taint the _G FIELD ENTRY. Subsequent    ==
-- ==  Blizzard reads of `GameTooltip` (BuffFrame, ActionButton,             ==
-- ==  PetActionBar, ...) cascade into ADDON_ACTION_BLOCKED and unit-aura    ==
-- ==  secret-number errors during combat. So this section makes NO _G       ==
-- ==  writes anywhere.                                                      ==
-- ==                                                                        ==
-- ==  Why per-instance, not mixin-level: Blizzard's sub-mixin pattern --    ==
-- ==  e.g. AreaPOIEventPinMixin built via AreaPOIPinMixin:CreateSubPin(...) ==
-- ==  -- snapshot-copies methods at Blizzard load time, BEFORE our addon    ==
-- ==  can edit the parent mixin. Per-instance replacement (driven by the    ==
-- ==  pool-acquire hook in section 6) is mixin-chain-agnostic.              ==
-- ==                                                                        ==
-- ==  Why pin.OnMouseEnter = X (field replacement) instead of               ==
-- ==  pin:SetScript("OnEnter", X): MapCanvasMixin:AcquirePin runs           ==
-- ==  `assert(pin:GetScript("OnEnter") == nil)` at Blizzard_MapCanvas.lua   ==
-- ==  :280, AFTER our pool wrapper returns. SetScript-ing inside our        ==
-- ==  wrapper trips that assertion. By replacing the mixin-copied method    ==
-- ==  fields while OnEnter/OnLeave scripts are still unbound, Blizzard's    ==
-- ==  own subsequent SetScript at lines 283-284 picks up our functions.    ==
-- ==                                                                        ==
-- ==  +---------------------------------------------------------------+    ==
-- ==  |  MAINTENANCE WARNING -- READ BEFORE EVERY RETAIL PATCH        |    ==
-- ==  +---------------------------------------------------------------+    ==
-- ==                                                                        ==
-- ==  The functions in the BLIZZARD-SOURCE COPIES region below are          ==
-- ==  MECHANICALLY copied from Blizzard source code, with GameTooltip       ==
-- ==  references rewritten to the local tooltip = PWMTooltip binding.       ==
-- ==  After EVERY Retail patch, diff each Blizzard original against the     ==
-- ==  PWM copy here and mirror any change. If you skip this audit,          ==
-- ==  tooltip content silently diverges from Blizzard's intent.             ==
-- ==                                                                        ==
-- ==  AUDIT CHECKLIST  (last audited: 2026-06-05 vs Midnight 12.0.5)        ==
-- ==                                                                        ==
-- ==    Blizzard_FrameXMLUtil/AreaPoiUtil.lua                               ==
-- ==        AreaPoiUtil.TryShowTooltip                lines 3-72            ==
-- ==                                                                        ==
-- ==    Blizzard_GameTooltip/Mainline/GameTooltip.lua                       ==
-- ==        (local) AddFloorLocationLine              lines 619-625         ==
-- ==        GameTooltip_AddQuest                      lines 627-745         ==
-- ==                                                                        ==
-- ==    Blizzard_UIPanels_Game/Mainline/WorldMapFrame.lua                   ==
-- ==        TaskPOI_OnEnter                           lines 159-179         ==
-- ==                                                                        ==
-- ==    Blizzard_SharedMapDataProviders/AreaPOIDataProvider.lua             ==
-- ==        AreaPOIPinMixin:OnMouseEnter              lines 159-181         ==
-- ==                                                                        ==
-- ==    Blizzard_SharedMapDataProviders/WorldQuestDataProvider.lua          ==
-- ==        WorldQuestPinMixin:OnMouseEnter           lines 420-424         ==
-- ==        WorldQuestPinMixin:OnMouseLeave           lines 426-430         ==
-- ==                                                                        ==
-- ==    Blizzard_SharedMapDataProviders/BonusObjectiveDataProvider.lua      ==
-- ==        BonusObjectivePinMixin:OnMouseEnter       lines 162-166         ==
-- ==        BonusObjectivePinMixin:OnMouseLeave       lines 168-172         ==
-- ==        (ThreatObjectivePinMixin inherits BonusObjectivePinMixin via    ==
-- ==         CreateFromMixins and uses the same handler structure.)         ==
-- ==                                                                        ==
-- ==    Blizzard_SharedMapDataProviders/QuestOfferDataProvider.lua          ==
-- ==        QuestOfferPinMixin:OnMouseEnter           lines 424-426         ==
-- ==        QuestOfferPinMixin:OnMouseLeave           lines 428-430         ==
-- ==                                                                        ==
-- ==    Blizzard_SharedMapDataProviders/InvasionDataProvider.lua            ==
-- ==        InvasionPinMixin:OnMouseEnter             lines 44-67           ==
-- ==        InvasionPinMixin:OnMouseLeave             lines 69-71           ==
-- ==                                                                        ==
-- ==    Blizzard_SharedMapDataProviders/VignetteDataProvider.lua            ==
-- ==        VignettePinBaseMixin:OnMouseEnter         lines 453-487         ==
-- ==        VignettePinBaseMixin:OnMouseLeave         lines 489-492         ==
-- ==        VignettePinBaseMixin:DisplayNormalTooltip lines 494-514         ==
-- ==        VignettePinBaseMixin:DisplayPvpBountyTooltip lines 516-537      ==
-- ==        VignettePinBaseMixin:DisplayTorghastTooltip lines 539-542       ==
-- ==                                                                        ==
-- ==    Blizzard_SharedMapDataProviders/QuestBlobDataProvider.lua           ==
-- ==        QuestBlobPinMixin:UpdateTooltip           lines 182-229         ==
-- ==        QuestBlobPinMixin:OnMouseEnter            lines 231-233         ==
-- ==                                                                        ==
-- ==  Reference points (no copies, but our code relies on these line        ==
-- ==  numbers being correct -- spot-check on patch days):                   ==
-- ==                                                                        ==
-- ==    Blizzard_MapCanvas/Blizzard_MapCanvas.lua                           ==
-- ==        AcquirePin pin.pinTemplate assignment       line 259            ==
-- ==        OnEnter/OnLeave nil-assertion + SetScript   lines 280-284       ==
-- ==                                                                        ==
-- ==    Blizzard_GameTooltip/Mainline/GameTooltip.xml                       ==
-- ==        ItemTooltip child of canonical GameTooltip  lines 249-274       ==
-- ==                                                                        ==
-- ==  When you update the audit date above, also update the per-function    ==
-- ==  "Source lines" comments inline below if any line ranges shifted.      ==
-- ==                                                                        ==
-- ============================================================================
-- ============================================================================


-- Diagnostic toggle. When true, every patched pin hover prints to chat and
-- we also log when a pin instance gets patched. Set false for silent play.
-- (We do NOT use issecure() as a proxy for "will the trap fire" -- inside
-- our own addon code it returns false regardless of whether the shared-
-- state taint that actually fires the secret-number protection is present.)
Addon.PWM_DEBUG_TOOLTIPS = false


-- The custom tooltip frame, plus a manually-installed ItemTooltip child
-- because GameTooltipTemplate alone doesn't include the children that the
-- canonical GameTooltip element in GameTooltip.xml declares inline (see
-- the reference to GameTooltip.xml:249-274 in the audit checklist).
-- Without ItemTooltip, helpers that read tooltip.ItemTooltip crash with
-- nil indexing.
local PWMTooltip = CreateFrame("GameTooltip", "PWMTooltip", UIParent, "GameTooltipTemplate")
PWMTooltip:SetFrameStrata("TOOLTIP")
PWMTooltip:Hide()
PWMTooltip.supportsItemComparison = true

do
  local itemTooltip = CreateFrame("Frame", nil, PWMTooltip, "InternalEmbeddedItemTooltipTemplate")
  itemTooltip:SetSize(100, 100)
  itemTooltip:SetPoint("BOTTOMLEFT", PWMTooltip, "BOTTOMLEFT", 10, 13)
  itemTooltip:Hide()
  itemTooltip.yspacing = 13
  PWMTooltip.ItemTooltip = itemTooltip
  -- Wire shopping tooltips for item-comparison (mirrors the inline OnLoad on
  -- the canonical ItemTooltip child in GameTooltip.xml).
  if itemTooltip.Tooltip and ShoppingTooltip1 and ShoppingTooltip2 then
    itemTooltip.Tooltip.shoppingTooltips = { ShoppingTooltip1, ShoppingTooltip2 }
  end
end


-- DebugLog: small helper to consolidate the diagnostic chat-print boilerplate
-- that would otherwise be repeated in every PWM_*_OnMouseEnter handler.
local function DebugLog(fmt, ...)
  if Addon.PWM_DEBUG_TOOLTIPS then
    print(string.format("|cFF60FF60[PWM]|r " .. fmt, ...))
  end
end


-- Shared OnMouseLeave for pin types whose only cleanup is hiding our tooltip.
-- (WorldQuest, Vignette, and AreaPOI need extra cleanup -- they have their
-- own handlers below.)
local function PWM_OnMouseLeave_HideOnly(self)
  PWMTooltip:Hide()
end


-- ============================================================================
-- ====  BLIZZARD-SOURCE COPIES  --  AUDIT ON EVERY RETAIL PATCH  =============
-- ============================================================================
--
-- Each function below carries a "COPY OF" header citing the Blizzard source
-- file, function name, line range, and the exact adaptation applied. To
-- audit on a patch day: open the cited Blizzard file, navigate to the line
-- range, diff against the PWM copy here, and mirror any change. Update the
-- "Source lines" header if a range shifted, and the "last audited" date in
-- the top-of-section banner.


-- ----------------------------------------------------------------------------
-- COPY OF: Blizzard_FrameXMLUtil/AreaPoiUtil.lua :: AreaPoiUtil.TryShowTooltip
-- Source lines: 3-72
-- Adaptation: `local tooltip = GetAppropriateTooltip()` -> PWMTooltip.
-- ----------------------------------------------------------------------------
local function PWM_AreaPoiUtil_TryShowTooltip(region, anchor, poiInfo, customFn)
  local hasDescription = poiInfo.description and poiInfo.description ~= ""
  local isTimed, hideTimer = C_AreaPoiInfo.IsAreaPOITimed(poiInfo.areaPoiID)
  local showTimer = not poiInfo.forceHideTimer and (poiInfo.secondsLeft or (isTimed and not hideTimer))
  local hasWidgetSet = poiInfo.tooltipWidgetSet ~= nil

  local hasTooltip = hasDescription or showTimer or hasWidgetSet
  local addedTooltipLine = false

  if hasTooltip then
    local tooltip = PWMTooltip  -- ADAPTED
    local verticalPadding = nil

    tooltip:SetOwner(region, anchor)
    if region:HasDisplayName() then
      GameTooltip_SetTitle(tooltip, region:GetDisplayName(), HIGHLIGHT_FONT_COLOR)
      addedTooltipLine = true
    end

    if hasDescription then
      GameTooltip_AddNormalLine(tooltip, poiInfo.description)
      addedTooltipLine = true
    end

    if showTimer then
      local secondsLeft = poiInfo.secondsLeft or C_AreaPoiInfo.GetAreaPOISecondsLeft(poiInfo.areaPoiID)
      if secondsLeft and secondsLeft > 0 then
        local timeString = SecondsToTime(secondsLeft)
        timeString = HIGHLIGHT_FONT_COLOR:WrapTextInColorCode(timeString)
        GameTooltip_AddNormalLine(tooltip, MAP_TOOLTIP_TIME_LEFT:format(timeString))
        addedTooltipLine = true
      end
    end

    if poiInfo.textureKit == "OribosGreatVault" then
      GameTooltip_AddBlankLineToTooltip(tooltip)
      GameTooltip_AddInstructionLine(tooltip, ORIBOS_GREAT_VAULT_POI_TOOLTIP_INSTRUCTIONS, false)
      addedTooltipLine = true
    end

    if hasWidgetSet then
      local overflow = GameTooltip_AddWidgetSet(tooltip, poiInfo.tooltipWidgetSet, addedTooltipLine and poiInfo.addPaddingAboveTooltipWidgets and 10)
      if overflow then
        verticalPadding = -overflow
      end
    end

    if poiInfo.textureKit then
      local backdropStyle = GAME_TOOLTIP_TEXTUREKIT_BACKDROP_STYLES[poiInfo.textureKit]
      if (backdropStyle) then
        SharedTooltip_SetBackdropStyle(tooltip, backdropStyle)
      end
    end

    if customFn then
      customFn(tooltip)
    end

    tooltip:Show()

    -- need to set padding after Show or else there will be a flicker
    if verticalPadding then
      tooltip:SetPadding(0, verticalPadding)
    end

    return true
  end

  return false
end


-- ----------------------------------------------------------------------------
-- COPY OF: Blizzard_GameTooltip/Mainline/GameTooltip.lua :: AddFloorLocationLine
-- Source lines: 619-625 (file-local helper used by GameTooltip_AddQuest)
-- Adaptation: none -- already parameterized -- but we duplicate the body
-- because Blizzard's version is `local` and unreachable from outside.
-- ----------------------------------------------------------------------------
local function PWM_AddFloorLocationLine(tooltip, floorLocation, aboveString, belowString)
  if floorLocation == Enum.QuestLineFloorLocation.Below then
    tooltip:AddLine(belowString, 0.5, 0.5, 0.5, true)
  elseif floorLocation == Enum.QuestLineFloorLocation.Above then
    tooltip:AddLine(aboveString, 0.5, 0.5, 0.5, true)
  end
end


-- ----------------------------------------------------------------------------
-- COPY OF: Blizzard_GameTooltip/Mainline/GameTooltip.lua :: GameTooltip_AddQuest
-- Source lines: 627-745
-- Adaptation: every reference to the `GameTooltip` global rewritten to the
-- local `tooltip = PWMTooltip`. The function's `self` argument still refers
-- to the PIN, as in Blizzard's source.
-- ----------------------------------------------------------------------------
local function PWM_GameTooltip_AddQuest(self)
  local tooltip = PWMTooltip  -- ADAPTED

  local questID = self.questID
  if not HaveQuestData(questID) then
    GameTooltip_SetTitle(tooltip, RETRIEVING_DATA, RED_FONT_COLOR)
    GameTooltip_SetTooltipWaitingForData(tooltip, true)
    tooltip:Show()
    return
  end

  local widgetSetAdded = false
  local widgetSetID = C_TaskQuest.GetQuestUIWidgetSetByType(questID, Enum.MapIconUIWidgetSetType.Tooltip)
  local isThreat = C_QuestLog.IsThreatQuest(questID)

  local title, factionID, capped = C_TaskQuest.GetQuestInfoByQuestID(questID)
  title = title or self.questName
  if self.worldQuest or C_QuestLog.IsWorldQuest(questID) then
    self.worldQuest = true
    local tagInfo = C_QuestLog.GetQuestTagInfo(self.questID)
    local quality = tagInfo and tagInfo.quality or Enum.WorldQuestQuality.Common

    local colorData = ColorManager.GetColorDataForWorldQuestQuality(quality)
    if colorData then
      GameTooltip_SetTitle(tooltip, title, colorData.color)
    else
      GameTooltip_SetTitle(tooltip, title)
    end

    if C_QuestLog.IsAccountQuest(questID) then
      GameTooltip_AddColoredLine(tooltip, ACCOUNT_QUEST_LABEL, ACCOUNT_WIDE_FONT_COLOR)
    end

    QuestUtils_AddQuestTypeToTooltip(tooltip, questID, NORMAL_FONT_COLOR)

    local factionData = factionID and C_Reputation.GetFactionDataByID(factionID)
    if factionData then
      local questAwardsReputationWithFaction = C_QuestLog.DoesQuestAwardReputationWithFaction(questID, factionID)
      local reputationYieldsRewards = (not capped) or C_Reputation.IsFactionParagonForCurrentPlayer(factionID)
      if questAwardsReputationWithFaction and reputationYieldsRewards then
        tooltip:AddLine(factionData.name)
      else
        tooltip:AddLine(factionData.name, GRAY_FONT_COLOR:GetRGB())
      end
    end

    GameTooltip_AddQuestTimeToTooltip(tooltip, questID)
  elseif isThreat then
    GameTooltip_SetTitle(tooltip, title)
    GameTooltip_AddQuestTimeToTooltip(tooltip, questID)
  else
    GameTooltip_SetTitle(tooltip, title, NORMAL_FONT_COLOR)
  end

  if self.isCombatAllyQuest or (C_QuestLog.GetQuestType(questID) == Enum.QuestTag.CombatAlly) then
    GameTooltip_AddColoredLine(tooltip, AVAILABLE_FOLLOWER_QUEST, HIGHLIGHT_FONT_COLOR, true)
    GameTooltip_AddColoredLine(tooltip, GRANTS_FOLLOWER_XP, GREEN_FONT_COLOR, true)
  elseif self.isQuestStart then
    GameTooltip_AddColoredLine(tooltip, AVAILABLE_QUEST, HIGHLIGHT_FONT_COLOR, true)
    PWM_AddFloorLocationLine(tooltip, self.floorLocation, QUESTLINE_LOCATED_ABOVE, QUESTLINE_LOCATED_BELOW)
  else
    local questDescription = ""
    local questCompleted = C_QuestLog.IsComplete(questID)

    if questCompleted and self.shouldShowObjectivesAsStatusBar then
      questDescription = QUEST_WATCH_QUEST_READY
      GameTooltip_AddColoredLine(tooltip, QUEST_DASH .. questDescription, HIGHLIGHT_FONT_COLOR)
    elseif not questCompleted and self.shouldShowObjectivesAsStatusBar then
      local questLogIndex = C_QuestLog.GetLogIndexForQuestID(questID)
      if questLogIndex then
        questDescription = select(2, GetQuestLogQuestText(questLogIndex))
        GameTooltip_AddColoredLine(tooltip, QUEST_DASH .. questDescription, HIGHLIGHT_FONT_COLOR)
      end
    end
    local numObjectives = self.numbObjectives or C_QuestLog.GetNumQuestObjectives(questID)
    for objectiveIndex = 1, numObjectives do
      local objectiveText, objectiveType, finished, numFulfilled, numRequired = GetQuestObjectiveInfo(questID, objectiveIndex, false)
      local showObjective = not (finished and isThreat)
      if showObjective then
        if self.shouldShowObjectivesAsStatusBar then
          local percent = math.floor((numFulfilled / numRequired) * 100)
          GameTooltip_ShowProgressBar(tooltip, 0, numRequired, numFulfilled, PERCENTAGE_STRING:format(percent))
        elseif objectiveText and (#objectiveText > 0) then
          local color = finished and GRAY_FONT_COLOR or HIGHLIGHT_FONT_COLOR
          tooltip:AddLine(QUEST_DASH .. objectiveText, color.r, color.g, color.b, true)
        end
      end
    end
    local objectiveText, objectiveType, finished, numFulfilled, numRequired = GetQuestObjectiveInfo(questID, 1, false)
    if objectiveType == "progressbar" then
      local percent = C_TaskQuest.GetQuestProgressBarInfo(questID)
      local showObjective = not (finished and isThreat)
      if percent and showObjective then
        GameTooltip_ShowProgressBar(tooltip, 0, 100, percent, PERCENTAGE_STRING:format(percent))
      end
    end

    if widgetSetID then
      widgetSetAdded = true
      GameTooltip_AddWidgetSet(tooltip, widgetSetID)
    end

    GameTooltip_AddQuestRewardsToTooltip(tooltip, questID, self.questRewardTooltipStyle or TOOLTIP_QUEST_REWARDS_STYLE_DEFAULT)

    if self.worldQuest and C_TooltipInfo.GM then
      local tooltipData = C_TooltipInfo.GM.GetDebugWorldQuestInfo(questID)
      if tooltipData then
        local tooltipInfo = { tooltipData = tooltipData, append = true }
        tooltip:ProcessInfo(tooltipInfo)
        tooltip:Show()
      end
    end
  end

  if not widgetSetAdded and widgetSetID then
    GameTooltip_AddWidgetSet(tooltip, widgetSetID)
  end

  tooltip:Show()
end


-- ----------------------------------------------------------------------------
-- COPY OF: Blizzard_UIPanels_Game/Mainline/WorldMapFrame.lua :: TaskPOI_OnEnter
-- Source lines: 159-179
-- Adaptation: GameTooltip -> local tooltip = PWMTooltip;
-- GameTooltip_AddQuest -> PWM_GameTooltip_AddQuest. The calling-quest
-- branch still delegates to Blizzard's CallingPOI_OnEnter (calling quests
-- are rare and that path uses the canonical GameTooltip).
-- ----------------------------------------------------------------------------
local function PWM_TaskPOI_OnEnter(self, skipSetOwner)
  local tooltip = PWMTooltip  -- ADAPTED

  if not skipSetOwner then
    tooltip:SetOwner(self, "ANCHOR_RIGHT")
  end

  if not HaveQuestData(self.questID) then
    GameTooltip_SetTitle(tooltip, RETRIEVING_DATA, RED_FONT_COLOR)
    GameTooltip_SetTooltipWaitingForData(tooltip, true)
    tooltip:Show()
    return
  end

  if C_QuestLog.IsQuestCalling(self.questID) then
    CallingPOI_OnEnter(self)  -- UNADAPTED: writes to global GameTooltip; rare path
    return
  end

  PWM_GameTooltip_AddQuest(self)
  EventRegistry:TriggerEvent("TaskPOI.TooltipShown", self, self.questID, self)
  self:OnLegendPinMouseEnter()
end


-- ----------------------------------------------------------------------------
-- COPY OF: AreaPOIDataProvider.lua :: AreaPOIPinMixin:OnMouseEnter
-- Source lines: 159-181
-- Adaptation:
--   * self:TryShowTooltip()  ->  PWM_AreaPoiUtil_TryShowTooltip(self, ...)
--   * self.UpdateTooltip points at OUR handler so timer-driven refreshes
--     also use PWMTooltip.
-- AreaPOIEventPinTemplate also routes through this handler -- its mixin's
-- OnMouseEnter delegates to AreaPOIPinMixin.OnMouseEnter(self) as a live
-- table lookup, and the per-instance replacement we do at acquire time
-- catches it for both pin templates.
-- ----------------------------------------------------------------------------
local function PWM_AreaPOIPin_OnMouseEnter(self)
  DebugLog("AreaPOI hover: areaPoiID=%s pinTemplate=%s",
    tostring(self.poiInfo and self.poiInfo.areaPoiID),
    tostring(self.pinTemplate or "?"))

  if not self:HasDisplayName() then
    return
  end

  -- ADAPTED: was `self.UpdateTooltip = function() self:OnMouseEnter() end`
  self.UpdateTooltip = function() PWM_AreaPOIPin_OnMouseEnter(self) end

  local function customFn(tooltip) self:AddCustomTooltipData(tooltip) end
  local tooltipShown = PWM_AreaPoiUtil_TryShowTooltip(self, "ANCHOR_RIGHT", self.poiInfo, customFn)

  if not tooltipShown then
    self:GetMap():TriggerEvent("SetAreaLabel", MAP_AREA_LABEL_TYPE.POI, self:GetDisplayName(), self.description)
  end

  EventRegistry:TriggerEvent("AreaPOIPin.MouseOver", self, tooltipShown, self.poiInfo.areaPoiID, self:GetDisplayName())
  self:OnLegendPinMouseEnter()

  if self.highlightWorldQuestsOnHover then
    self:GetMap():TriggerEvent("HighlightMapPins.WorldQuests", self.pinHoverHighlightType)
  end

  if self.highlightVignettesOnHover then
    self:GetMap():TriggerEvent("HighlightMapPins.Vignettes", self.pinHoverHighlightType)
  end
end


-- AreaPOI OnMouseLeave intentionally has no module-level function: Blizzard's
-- source doesn't hide the tooltip there (it relies on GameTooltip's owner-
-- tracking), but our PWMTooltip needs an explicit hide AND we want to keep
-- forwarding to the per-pin original (which fires map TriggerEvents). The
-- per-instance closure is built inside PatchPinForCustomTooltip below.


-- ----------------------------------------------------------------------------
-- COPY OF: WorldQuestDataProvider.lua :: WorldQuestPinMixin:OnMouseEnter / :OnMouseLeave
-- Source lines: 420-424 (OnMouseEnter), 426-430 (OnMouseLeave)
-- Adaptation: TaskPOI_OnEnter -> PWM_TaskPOI_OnEnter; TaskPOI_OnLeave (which
-- does GameTooltip:Hide()) -> PWMTooltip:Hide(). The other two original
-- calls (POIButtonMixin.OnEnter/Leave, OnLegendPinMouseEnter/Leave) stay.
--
-- These handlers are ALSO REUSED for BonusObjective and ThreatObjective pin
-- templates. Per the audit checklist, BonusObjectivePinMixin:OnMouseEnter /
-- :OnMouseLeave (BonusObjectiveDataProvider.lua:162-172) have identical
-- structure to WorldQuest's, and ThreatObjectivePinMixin inherits from
-- BonusObjectivePinMixin via CreateFromMixins -- so the same PWM handlers
-- are correct for all three. When auditing, check that the three Blizzard
-- handlers remain structurally identical.
-- ----------------------------------------------------------------------------
local function PWM_WorldQuestPin_OnMouseEnter(self)
  DebugLog("WorldQuest hover: questID=%s pinTemplate=%s",
    tostring(self.questID), tostring(self.pinTemplate or "?"))

  PWM_TaskPOI_OnEnter(self)
  POIButtonMixin.OnEnter(self)
  self:OnLegendPinMouseEnter()
end

local function PWM_WorldQuestPin_OnMouseLeave(self)
  PWMTooltip:Hide()
  POIButtonMixin.OnLeave(self)
  self:OnLegendPinMouseLeave()
end


-- ----------------------------------------------------------------------------
-- COPY OF: QuestOfferDataProvider.lua :: QuestOfferPinMixin:OnMouseEnter
-- Source lines: 424-426 (OnMouseEnter; OnMouseLeave is just a TaskPOI_OnLeave
-- call which we replace with PWM_OnMouseLeave_HideOnly in the dispatch).
-- Adaptation: TaskPOI_OnEnter -> PWM_TaskPOI_OnEnter.
-- ----------------------------------------------------------------------------
local function PWM_QuestOfferPin_OnMouseEnter(self)
  DebugLog("QuestOffer hover: questID=%s pinTemplate=%s",
    tostring(self.questID), tostring(self.pinTemplate or "?"))
  PWM_TaskPOI_OnEnter(self)
end


-- ----------------------------------------------------------------------------
-- COPY OF: InvasionDataProvider.lua :: InvasionPinMixin:OnMouseEnter
-- Source lines: 44-67 (OnMouseEnter; OnMouseLeave is one line and uses
-- PWM_OnMouseLeave_HideOnly via the dispatch).
-- Adaptation: GameTooltip -> local tooltip = PWMTooltip.
-- ----------------------------------------------------------------------------
local function PWM_InvasionPin_OnMouseEnter(self)
  DebugLog("Invasion hover: invasionID=%s pinTemplate=%s",
    tostring(self.invasionID), tostring(self.pinTemplate or "?"))

  local tooltip = PWMTooltip  -- ADAPTED
  local invasionInfo = C_InvasionInfo.GetInvasionInfo(self.invasionID)
  local timeLeftMinutes = C_InvasionInfo.GetInvasionTimeLeft(self.invasionID)

  tooltip:SetOwner(self, "ANCHOR_RIGHT")
  tooltip:SetText(invasionInfo.name, HIGHLIGHT_FONT_COLOR:GetRGB())

  if timeLeftMinutes and timeLeftMinutes > 0 then
    local timeString = SecondsToTime(timeLeftMinutes * 60)
    tooltip:AddLine(BONUS_OBJECTIVE_TIME_LEFT:format(timeString), NORMAL_FONT_COLOR:GetRGB())
  end

  if invasionInfo.rewardQuestID then
    if not HaveQuestData(invasionInfo.rewardQuestID) then
      tooltip:AddLine(RETRIEVING_DATA, RED_FONT_COLOR:GetRGB())
      GameTooltip_SetTooltipWaitingForData(tooltip, true)
    else
      GameTooltip_AddQuestRewardsToTooltip(tooltip, invasionInfo.rewardQuestID)
      GameTooltip_SetTooltipWaitingForData(tooltip, false)
    end
  end

  tooltip:Show()
end


-- ----------------------------------------------------------------------------
-- COPY OF: VignetteDataProvider.lua :: VignettePinBaseMixin:Display{Normal,PvpBounty,Torghast}Tooltip
-- Source lines: 494-514, 516-537, 539-542
-- Adaptation: instance methods turned into module-local functions taking
-- (pin, tooltip), so the caller controls which tooltip frame the build
-- happens on. Every `GameTooltip` reference -> the passed `tooltip` arg.
-- ----------------------------------------------------------------------------
local function PWM_Vignette_DisplayNormalTooltip(pin, tooltip)
  local vignetteName = pin:GetVignetteName()
  if vignetteName ~= "" then
    GameTooltip_SetTitle(tooltip, vignetteName)

    local groupSizeString = pin:GetRecommendedGroupSizeString()
    if groupSizeString then
      GameTooltip_AddInstructionLine(tooltip, groupSizeString)
    end

    local objectiveString = pin:GetObjectiveString()
    if objectiveString then
      local noWrap = false
      GameTooltip_AddHighlightLine(tooltip, objectiveString, noWrap)
    end

    return true
  end
  return false
end

local function PWM_Vignette_DisplayPvpBountyTooltip(pin, tooltip)
  local player = PlayerLocation:CreateFromGUID(pin:GetObjectGUID())
  local class = select(3, C_PlayerInfo.GetClass(player))
  local race = C_PlayerInfo.GetRace(player)
  local name = C_PlayerInfo.GetName(player)

  if race and class and name then
    local classInfo = C_CreatureInfo.GetClassInfo(class)
    local factionInfo = C_CreatureInfo.GetFactionInfo(race)

    GameTooltip_SetTitle(tooltip, name, GetClassColorObj(classInfo.classFile))
    GameTooltip_AddColoredLine(tooltip, factionInfo.name, GetFactionColor(factionInfo.groupTag))
    local rewardQuestID = pin:GetRewardQuestID()
    if rewardQuestID then
      GameTooltip_AddQuestRewardsToTooltip(tooltip, pin:GetRewardQuestID(), TOOLTIP_QUEST_REWARDS_STYLE_PVP_BOUNTY)
    end

    return true
  end

  return false
end

local function PWM_Vignette_DisplayTorghastTooltip(pin, tooltip)
  SharedTooltip_SetBackdropStyle(tooltip, GAME_TOOLTIP_BACKDROP_STYLE_RUNEFORGE_LEGENDARY)
  return PWM_Vignette_DisplayNormalTooltip(pin, tooltip)
end


-- ----------------------------------------------------------------------------
-- COPY OF: VignetteDataProvider.lua :: VignettePinBaseMixin:OnMouseEnter / :OnMouseLeave
-- Source lines: 453-487 (OnMouseEnter), 489-492 (OnMouseLeave)
-- Adaptation: GameTooltip -> local tooltip = PWMTooltip; Display* methods
-- replaced with the PWM_Vignette_Display* helpers above.
-- Covers VignettePinMixin (CreateFromMixins(SuperTrackableVignettePinMixin,
-- VignettePinBaseMixin)), VignettePinPOIButtonMixin, and
-- FyrakkFlightVignettePinMixin via per-instance replacement at acquire time.
-- ----------------------------------------------------------------------------
local function PWM_VignettePin_OnMouseEnter(self)
  DebugLog("Vignette hover: pinTemplate=%s vignetteGUID=%s",
    tostring(self.pinTemplate or "?"),
    tostring(self.vignetteGUID or "?"))

  if self.hasTooltip then
    local verticalPadding = nil

    local tooltip = PWMTooltip  -- ADAPTED
    tooltip:SetOwner(self, "ANCHOR_RIGHT")
    -- ADAPTED: was `self.UpdateTooltip = self.OnMouseEnter`. self.OnMouseEnter
    -- has been replaced with this function via per-instance replacement, so
    -- the original form would still resolve to us -- but be explicit.
    self.UpdateTooltip = function() PWM_VignettePin_OnMouseEnter(self) end

    local waitingForData, titleAdded = false, false

    if self:GetVignetteType() == Enum.VignetteType.Normal or self:GetVignetteType() == Enum.VignetteType.Treasure then
      titleAdded = PWM_Vignette_DisplayNormalTooltip(self, tooltip)
    elseif self:GetVignetteType() == Enum.VignetteType.PvPBounty then
      titleAdded = PWM_Vignette_DisplayPvpBountyTooltip(self, tooltip)
      waitingForData = not titleAdded
    elseif self:GetVignetteType() == Enum.VignetteType.Torghast then
      titleAdded = PWM_Vignette_DisplayTorghastTooltip(self, tooltip)
    end

    if not waitingForData and self.tooltipWidgetSet then
      local overflow = GameTooltip_AddWidgetSet(tooltip, self.tooltipWidgetSet, titleAdded and self.vignetteInfo.addPaddingAboveTooltipWidgets and 10)
      if overflow then
        verticalPadding = -overflow
      end
    elseif waitingForData then
      GameTooltip_SetTitle(tooltip, RETRIEVING_DATA)
    end

    tooltip:Show()
    if verticalPadding then
      tooltip:SetPadding(0, verticalPadding)
    end
  end
  self:OnLegendPinMouseEnter()
end

local function PWM_VignettePin_OnMouseLeave(self)
  PWMTooltip:Hide()
  self:OnLegendPinMouseLeave()
end


-- ----------------------------------------------------------------------------
-- COPY OF: QuestBlobDataProvider.lua :: QuestBlobPinMixin:UpdateTooltip / :OnMouseEnter
-- Source lines: 182-229 (UpdateTooltip), 231-233 (OnMouseEnter)
-- Adaptation: GameTooltip -> local tooltip = PWMTooltip;
-- TaskPOI_OnEnter -> PWM_TaskPOI_OnEnter;
-- GameTooltip:GetOwner() -> tooltip:GetOwner().
-- We also assign pin.UpdateTooltip to our PWM version in the dispatch so
-- other callers (cursor updates etc.) route through PWMTooltip too.
-- ----------------------------------------------------------------------------
local function PWM_QuestBlobPin_UpdateTooltip(self)
  if POIButtonHighlightManager:HasHighlight() then
    return
  end

  local mouseX, mouseY = self:GetMap():GetNormalizedCursorPosition()
  local questID, numPOITooltips = self:UpdateMouseOverTooltip(mouseX, mouseY)
  local questLogIndex = questID and C_QuestLog.GetLogIndexForQuestID(questID)
  if not questLogIndex then
    self:OnMouseLeave()
    return
  end

  local tooltip = PWMTooltip  -- ADAPTED
  local tooltipOwner = tooltip:GetOwner()  -- ADAPTED
  if tooltipOwner and tooltipOwner ~= self then
    return
  end

  tooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT", 5, 2)

  local title = C_QuestLog.GetTitleForQuestID(questID)
  local numObjectives = GetNumQuestLeaderBoards(questLogIndex)

  if C_QuestLog.IsThreatQuest(questID) then
    local skipSetOwner = true
    PWM_TaskPOI_OnEnter(self, skipSetOwner)  -- ADAPTED
    return
  end

  tooltip:SetText(title)
  QuestUtils_AddQuestTypeToTooltip(tooltip, questID, NORMAL_FONT_COLOR)

  for i = 1, numObjectives do
    local text, objectiveType, finished

    if numPOITooltips == numObjectives then
      local questPOIIndex = self:GetTooltipIndex(i)
      text, objectiveType, finished = GetQuestPOILeaderBoard(questPOIIndex, questLogIndex)
    else
      text, objectiveType, finished = GetQuestLogLeaderBoard(i, questLogIndex)
    end

    if text and not finished then
      tooltip:AddLine(QUEST_DASH .. text, 1, 1, 1, true)
    end
  end
  tooltip:Show()
end

local function PWM_QuestBlobPin_OnMouseEnter(self)
  DebugLog("QuestBlob hover: pinTemplate=%s",
    tostring(self.pinTemplate or "?"))
  PWM_QuestBlobPin_UpdateTooltip(self)
end


-- ============================================================================
-- ====  END OF BLIZZARD-SOURCE COPIES  =======================================
-- ============================================================================


-- Per-instance handler installer. Called from the pool-acquire hook in
-- section (6), once per new pin instance. Dispatches on pinTemplate
-- (threaded down because pin.pinTemplate isn't assigned yet at our call
-- site -- AcquirePin sets it AFTER pool:Acquire returns).
--
-- We replace pin.OnMouseEnter / pin.OnMouseLeave as TABLE FIELDS, NOT via
-- pin:SetScript. Blizzard's MapCanvasMixin:AcquirePin runs
-- `assert(pin:GetScript("OnEnter") == nil)` at Blizzard_MapCanvas.lua:280
-- after our wrapper returns; SetScript-ing inside the wrapper trips that
-- assertion. Replacing the mixin-copied methods while OnEnter/OnLeave
-- scripts are still unbound lets Blizzard's own SetScript at lines 283-284
-- bind our functions for us.
local function PatchPinForCustomTooltip(pin, pinTemplate)
  if pin.pwm_custom_tooltip_patched then return end
  pin.pwm_custom_tooltip_patched = true

  if pinTemplate == "WorldQuestPinTemplate"
      or pinTemplate == "BonusObjectivePinTemplate"
      or pinTemplate == "ThreatObjectivePinTemplate" then
    -- All three pin types have identical OnMouseEnter/OnMouseLeave structure
    -- (see the audit-checklist note on the WorldQuest copy block above).
    pin.OnMouseEnter = PWM_WorldQuestPin_OnMouseEnter
    pin.OnMouseLeave = PWM_WorldQuestPin_OnMouseLeave

  elseif pinTemplate == "AreaPOIPinTemplate" or pinTemplate == "AreaPOIEventPinTemplate" then
    -- Capture THIS pin's mixin-copied OnMouseLeave (Blizzard's original)
    -- so our wrapper can forward the map TriggerEvents in it. Using the
    -- per-instance copy is mixin-chain-agnostic across the AreaPOI variants.
    local origLeave = pin.OnMouseLeave
    pin.OnMouseEnter = PWM_AreaPOIPin_OnMouseEnter
    pin.OnMouseLeave = function(self, ...)
      PWMTooltip:Hide()
      if origLeave then return origLeave(self, ...) end
    end

  elseif pinTemplate == "QuestOfferPinTemplate" then
    pin.OnMouseEnter = PWM_QuestOfferPin_OnMouseEnter
    pin.OnMouseLeave = PWM_OnMouseLeave_HideOnly

  elseif pinTemplate == "InvasionPinTemplate" then
    pin.OnMouseEnter = PWM_InvasionPin_OnMouseEnter
    pin.OnMouseLeave = PWM_OnMouseLeave_HideOnly

  elseif pinTemplate == "VignettePinTemplate"
      or pinTemplate == "VignettePinPOIButtonTemplate"
      or pinTemplate == "FyrakkFlightVignettePinTemplate" then
    pin.OnMouseEnter = PWM_VignettePin_OnMouseEnter
    pin.OnMouseLeave = PWM_VignettePin_OnMouseLeave

  elseif pinTemplate == "QuestBlobPinTemplate" then
    -- QuestBlob exposes a public UpdateTooltip invoked separately from
    -- OnMouseEnter (cursor tracking). Override that too so every entry
    -- point routes through PWMTooltip.
    pin.OnMouseEnter = PWM_QuestBlobPin_OnMouseEnter
    pin.OnMouseLeave = PWM_OnMouseLeave_HideOnly
    pin.UpdateTooltip = PWM_QuestBlobPin_UpdateTooltip

  else
    -- Pin templates not in the list above don't use measured-widget tooltip
    -- builders, so the secret-number trap doesn't apply to them. Leave their
    -- handlers alone.
    return
  end

  if Addon.PWM_DEBUG_TOOLTIPS then
    print(string.format("|cFF60FFFF[PWM]|r installed custom-tooltip handlers on %s", pinTemplate))
  end
end


-- ============================================================================
-- (6) Per-pin protected-call shadowing + pool-acquire hook
-- ============================================================================
--
-- Blizzard's MapCanvasMixin:AcquirePin calls SetPassThroughButtons and
-- SetPropagateMouseClicks on each new pin (via CheckMouseButtonPassthrough).
-- These are protected calls; under PWM-origin taint they fail with
-- ADDON_ACTION_BLOCKED during combat. Shadow them on each pin instance to
-- skip during combat. The skipped pin won't have correct passthrough until
-- the next post-combat refresh -- Addon.reloadAfterCombat (set here, acted
-- on by section (4)) covers that.
--
-- The pool-acquire wrapper ALSO calls PatchPinForCustomTooltip (defined in
-- section (5)) to install the custom-tooltip handlers on the same pin.
--
-- pinTemplate is threaded through the wrappers explicitly because
-- pin.pinTemplate isn't assigned until AFTER pool:Acquire returns (the
-- assignment happens at MapCanvas.lua:259, AFTER our wrapper runs at :257).
-- Reading pin.pinTemplate inside our wrapper would yield nil.
--
-- A __newindex metatable on WorldMapFrame.pinPools catches future pool
-- creation. Patches are on the pin INSTANCE, so they survive pool recycling
-- across map opens.
--
do
  local function PatchPin(pin, pinTemplate)
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

    PatchPinForCustomTooltip(pin, pinTemplate)
  end

  local function WrapPoolAcquire(pool, pinTemplate)
    if pool.pwm_acquire_wrapped then return end
    pool.pwm_acquire_wrapped = true

    local origAcquire = pool.Acquire
    pool.Acquire = function(self, ...)
      local pin, isNew = origAcquire(self, ...)
      if pin and isNew then
        PatchPin(pin, pinTemplate)
      end
      return pin, isNew
    end
  end

  -- Wrap pools that already exist at our load time (if any).
  for pinTemplate, pool in pairs(WorldMapFrame.pinPools) do
    WrapPoolAcquire(pool, pinTemplate)
  end

  -- Catch future pool creation via a __newindex on the pinPools table.
  setmetatable(WorldMapFrame.pinPools, {
    __newindex = function(t, pinTemplate, pool)
      rawset(t, pinTemplate, pool)
      WrapPoolAcquire(pool, pinTemplate)
    end
  })
end


-- ============================================================================
-- (7) HookPins -- boss/dungeon pin OnClick during combat
-- ============================================================================
--
-- The OnClick handlers on EncounterJournalPinTemplate and
-- DungeonEntrancePinTemplate don't work during combat due to taint, so we
-- emulate their behavior manually. Called from restoreAndReset.lua's
-- hooksecurefunc on WorldMapFrame.SetMapID and .RefreshAllDataProviders.
--
Addon.HookPins = function()
  if not WorldMapFrame.ScrollContainer.Child then return end

  local kids = { WorldMapFrame.ScrollContainer.Child:GetChildren() }
  for _, v in ipairs(kids) do
    if v.pinTemplate and not v.pwm_alreadyHooked
        and (v.pinTemplate == "EncounterJournalPinTemplate" or v.pinTemplate == "DungeonEntrancePinTemplate") then

      local OriginalOnClick = v.OnClick
      v.OnClick = function(...)

        local _, button = ...
        -- Save pinTemplate locally, because the SetMapID call below may
        -- release the pin and clear v.pinTemplate.
        local pinTemplate = v.pinTemplate

        if InCombatLockdown() then

          -- For EncounterJournalPinTemplate, only the left button opens
          -- EncounterJournal. For DungeonEntrancePinTemplate, only the right.
          if (pinTemplate == "EncounterJournalPinTemplate" and button == "LeftButton")
              or (pinTemplate == "DungeonEntrancePinTemplate" and button == "RightButton") then
            if not EncounterJournal:IsShown() then
              EncounterJournal:Show()
            else
              EncounterJournal:Raise()
            end

          -- EncounterJournalPinTemplate's right click changes the map to
          -- the parent map. Tainted during combat, so do it manually.
          elseif (pinTemplate == "EncounterJournalPinTemplate" and button == "RightButton") then
            local mapInfo = C_Map_GetMapInfo(WorldMapFrame:GetMapID())
            if mapInfo.parentMapID then
              WorldMapFrame:SetMapID(mapInfo.parentMapID)
            end
          end

          -- Run the original click for everything except the case we
          -- handled manually above.
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


-- ============================================================================
-- (8) Quest tracker hooks
-- ============================================================================
--
-- QuestMapFrame_OpenToQuestDetails is called when clicking a quest tracker
-- entry, or the ShowMapButton of QuestLogPopupDetailFrame. During combat it
-- doesn't manage to bring up WorldMapFrame and hide
-- EncounterJournal/QuestLogPopupDetailFrame, so we do that here.
--
-- We use hooksecurefunc (not direct override) to avoid tainting the global,
-- which would spread to UseQuestLogSpecialItem and other protected quest
-- functions.
--
hooksecurefunc("QuestMapFrame_OpenToQuestDetails", function(...)

  if InCombatLockdown() then
    if not WorldMapFrame:IsShown() then
      WorldMapFrame:Show()
    else
      WorldMapFrame:Raise()
    end
  end

  -- Mapster prevents the quest frame from being closed, which results in an
  -- empty quest frame. Close it explicitly.
  if QuestFrame:IsShown() then
    QuestFrame_OnHide()
  end
end)


-- QuestLogPopupDetailFrame_Show is called when right-clicking a quest
-- tracker entry and selecting "Open Quest Details". During combat it
-- doesn't bring up the frame, so we do it manually. Also handle the
-- toggle-off case: if the user clicks the same quest a second time,
-- hide the frame.
--
do
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

      if lastShownQuestID and lastShownQuestID == questID then
        QuestLogPopupDetailFrame:Hide()
        return
      end

      if not QuestLogPopupDetailFrame:IsShown() then
        QuestLogPopupDetailFrame:Show()
      else
        QuestLogPopupDetailFrame:Raise()
      end
    end
  end)
end


-- ============================================================================
-- (9) Frame mutual-exclusion helpers
-- ============================================================================
--
-- Closing frames during combat is restricted: HideUIPanel is protected. The
-- helpers below pick the right Hide path based on combat state, with one
-- WorldMapFrame-specific subtlety (see CloseWorldMapFrame's comments).
--

local function CloseWorldMapFrame(orReset)
  if not WorldMapFrame:IsShown() then return end

  if InCombatLockdown() then
    -- WorldMapFrame:Hide() will leave WorldMapFrame in UIParent's
    -- FramePositionDelegate (see Blizzard_UIParentPanelManager/Mainline
    -- /UIParentPanelManager.lua L871), which then breaks ToggleGameMenu.
    -- Only hide if WorldMapFrame is not in UIPanelWindows (e.g. Mapster
    -- removes it from UIPanelWindows, in which case hiding is safe).
    if not UIPanelWindows["WorldMapFrame"] then
      WorldMapFrame:Hide()
    elseif orReset then
      -- We can't hide WorldMapFrame, so at least restore the side panel
      -- to its default. Otherwise either QuestMapFrame.DetailsFrame or
      -- QuestLogPopupDetailFrame is empty and looks odd.
      QuestMapFrame_ReturnFromQuestDetails()
    end

  else
    HideUIPanel(WorldMapFrame)
  end
end

local function CloseEncounterJournal()
  if not EncounterJournal:IsShown() then return end
  if InCombatLockdown() then
    EncounterJournal:Hide()
  else
    HideUIPanel(EncounterJournal)
  end
end

local function CloseQuestLogPopupDetailFrame()
  if not QuestLogPopupDetailFrame:IsShown() then return end
  if InCombatLockdown() then
    QuestLogPopupDetailFrame:Hide()
  else
    HideUIPanel(QuestLogPopupDetailFrame)
  end
end


-- ============================================================================
-- (10) PLAYER_LOGIN startup
-- ============================================================================
--
-- One-shot setup that needs the UI to be ready:
--   * Preload EncounterJournal (so boss-pin OnClick works in combat).
--   * Pre-anchor the three frames so the first Show() doesn't misplace them.
--   * Register UISpecialFrames so ESC can close them during combat.
--   * Install mutual-exclusion HookScripts (open one of the three frames =>
--     close the others) plus the OpenWorldMap raise hook.
--
do
  local startupFrame = CreateFrame("Frame")
  startupFrame:RegisterEvent("PLAYER_LOGIN")
  startupFrame:SetScript("OnEvent", function()

    if not C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal") then
      EncounterJournal_LoadUI()
    end

    -- Bring frames into the right position once, otherwise the first
    -- frame:Show() (used during combat to bypass HideUIPanel restrictions)
    -- can leave them off-screen.
    WorldMapFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
    EncounterJournal:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
    QuestLogPopupDetailFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)

    -- Make ESC work for these frames even during combat.
    tinsert(UISpecialFrames, "WorldMapFrame")
    tinsert(UISpecialFrames, "EncounterJournal")
    tinsert(UISpecialFrames, "QuestLogPopupDetailFrame")

    -- Mutual exclusion: opening any one of the three closes the other two.
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

    -- Showing WorldMapFrame during combat isn't always enough (it can be
    -- behind other panels); raise it too.
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
end
