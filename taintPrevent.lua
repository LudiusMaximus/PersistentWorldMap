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
--    (2) In-instance OnShow replacement to skip the READ emote
--        On entering any instance (BG, arena, 5-man, raid, scenario),
--        SetScript WorldMapFrame:OnShow to a manually-inlined copy of
--        WorldMapMixin:OnShow with the C_ChatInfo.PerformEmote("READ", ...)
--        line at Blizzard_WorldMap.lua:352 omitted. On leaving, restore
--        the raw Blizzard handler. This has a patch-day maintenance cost
--        -- diff Blizzard's OnShow against the local copy every retail
--        patch. Also installs the reading-emote opt-out HookScript
--        (formerly section (3)).
--
--    (3) [reserved] -- see section (2)
--        The reading-emote opt-out HookScript that used to live here moved
--        into section (2) so its lifecycle stays tied to (2)'s SetScript /
--        restore cycle. Numbering preserved to keep (4)-(10) stable.
--
--    (4) Combat-end refresh
--        Declares Addon.reloadAfterCombat (set by section (6)'s protected-
--        call shadows) and the PLAYER_REGEN_ENABLED handler that refreshes
--        the map once combat ends.
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
--        the custom-tooltip installer from section (5). Installed on
--        WorldMapFrame at load and on FlightMapFrame lazily when
--        Blizzard_FlightMap loads.
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
--
--
-- ============================================================================
-- ============================================================================
-- ==                                                                        ==
-- ==   PATCH-DAY MAINTENANCE MANUAL                                         ==
-- ==   Read this on EVERY retail patch before shipping a compatible build.  ==
-- ==                                                                        ==
-- ============================================================================
-- ============================================================================
--
-- Three separate audits, each with its own last-synced date recorded inline.
-- Skipping any of them lets a Blizzard change silently break PWM: either the
-- taint dam fails and errors surface, or our copy of Blizzard code diverges
-- from the current behavior and features silently regress.
--
-- ----------------------------------------------------------------------------
-- AUDIT (A) -- Section (2)'s InstanceOnShow copy of WorldMapMixin:OnShow
-- ----------------------------------------------------------------------------
--
--   Blizzard source:  Blizzard_WorldMap/Blizzard_WorldMap.lua
--   Blizzard symbol:  WorldMapMixin:OnShow           (lines 342-376 as of 12.1.0)
--   Our copy:         local function InstanceOnShow(self) in section (2).
--   Deviation:        omit the C_ChatInfo.PerformEmote("READ", nil, true)
--                     call at line :352. Every other line must match.
--
--   Procedure:
--     1. Open the Blizzard source at the cited symbol.
--     2. Diff line-by-line against InstanceOnShow.
--     3. Mirror ANY change (added line, reordered call, new local, ...).
--     4. Keep the omitted-line comment where the PerformEmote call would be.
--     5. Update the "Last synced" date in InstanceOnShow's header comment.
--
--   Symptoms of a stale copy:
--     * In-instance map open error resurfaces (Blizzard moved the emote
--       to a different line and our copy still runs the old version).
--     * Missing UI behaviors in in-instance map open (Blizzard added a
--       line we don't replicate: minimap sync, side panel state, etc.).
--
-- ----------------------------------------------------------------------------
-- AUDIT (B) -- Section (5)'s Blizzard-source tooltip-builder copies
-- ----------------------------------------------------------------------------
--
--   Blizzard sources (multiple files -- see the audit checklist banner
--   inside section (5) for the exact list of functions, files, and line
--   ranges).
--   Our copies:      the PWM_* functions inside the "BLIZZARD-SOURCE COPIES"
--                    block of section (5). Each one has its own inline
--                    "COPY OF" / "Source lines" / "Adaptation" header.
--   Deviation:       every reference to the canonical `GameTooltip` global
--                    rewritten to a local `tooltip = PWMTooltip` binding.
--                    Everything else must match.
--
--   Procedure:
--     1. Open each cited Blizzard source at the cited function.
--     2. Diff line-by-line against the PWM copy.
--     3. Mirror ANY change; keep the GameTooltip -> PWMTooltip rewrite.
--     4. Update the "Source lines" line-range in each COPY OF header if
--        Blizzard shifted things.
--     5. Update the "AUDIT CHECKLIST" date in section (5)'s banner.
--
--   Symptoms of a stale copy:
--     * Wrong / missing tooltip content on world map pin hover (fields
--       added by Blizzard we don't render, format changes we don't mirror,
--       etc.).
--     * Silent tooltip errors under PWM taint that the canonical Blizzard
--       code would have handled.
--
-- ----------------------------------------------------------------------------
-- AUDIT (C) -- Section (5)'s pin-template dispatch coverage
-- ----------------------------------------------------------------------------
--
--   Blizzard sources: Blizzard_SharedMapDataProviders/, Blizzard_WorldMap/,
--                     Blizzard_FlightMap/, Blizzard_AnimaDiversionUI/,
--                     Blizzard_BattlefieldMap/ -- any addon that adds a
--                     data provider to a map canvas.
--   Our coverage:     the pinTemplate branches in PatchPinForCustomTooltip
--                     (section (5)) and the canvas hooks in section (6).
--
--   Procedure:
--     Run the four greps documented in the "HOW TO RE-AUDIT" block inside
--     section (5)'s banner. Cross-reference each hit against the covered
--     mixins / templates. Add any newly-created derivatives to the
--     appropriate dispatch branch. Update the audit-checklist date and
--     the per-function line ranges in section (5)'s banner.
--
--   Symptoms of a stale audit:
--     * "attempt to perform arithmetic on a secret number value" errors
--       on hover of a specific pin type that isn't in our dispatch.
--     * Silent PWM-taint blame on tooltip functions the trap widened to
--       cover after our previous audit.
--
-- ----------------------------------------------------------------------------
-- Not part of the retail-patch cadence but worth re-checking when Blizzard
-- ships significant UI infrastructure changes:
--
--   * Blizzard_MapCanvas/Blizzard_MapCanvas.lua -- AcquirePin at :251,
--     particularly the OnEnter/OnLeave nil-assertion + SetScript block at
--     :262-289. Section (6)'s WrapPoolAcquire relies on these line numbers
--     being correct for its "fresh vs reused pin" branching.
--
--   * Blizzard_GameTooltip/Mainline/GameTooltip.xml -- the ItemTooltip
--     child of the canonical GameTooltip (lines 249-274 as of 12.0.5).
--     Section (5)'s PWMTooltip manually creates an
--     InternalEmbeddedItemTooltipTemplate child to mirror this; if
--     Blizzard restructures the tooltip template composition, the manual
--     child creation may need to change.
--
-- ============================================================================
-- ============================================================================


-- ============================================================================
-- Locals
-- ============================================================================

local InCombatLockdown              = _G.InCombatLockdown
local IsInInstance                  = _G.IsInInstance
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
-- (2) In-instance OnShow replacement to skip the READ emote
-- ============================================================================
--
-- HISTORICAL CONTEXT (do NOT reintroduce these approaches):
--
--   b5af17d, 20ab7b1, 16afd8f: wrapped C_ChatInfo.PerformEmote /
--   .CancelEmote to filter the READ emote. The wrapper WRITE from
--   tainted addon-load context permanently tainted the FIELD ENTRY on
--   C_ChatInfo.PerformEmote for the session; every subsequent secure read
--   (any /sorry, /wave, etc. typed by the user) inherited PWM taint and
--   blamed us for ADDON_ACTION_BLOCKED once Blizzard tightened a
--   downstream C protection in raid boss fights. Same trap the section
--   (5) banner spells out for _G.GameTooltip: writes to a globally-
--   visible function field from tainted execution taint the field entry
--   permanently.
--
--   Direct field WRITES to C_ChatInfo.* are OFF LIMITS, forever.
--
-- CURRENT APPROACH:
--
-- The error stems from OnShow's `C_ChatInfo.PerformEmote("READ", ...)` at
-- Blizzard_WorldMap.lua:352 reaching a protected C downstream when
-- OnShow's execution has any PWM taint. Since PWM-taint on WorldMapFrame
-- .mapID is inevitable during normal use (writing to mapID is PWM's
-- reason to exist), we must stop the emote line from being called at all
-- inside any instance where the downstream is protected. Observed to
-- trip in PvP instances (BG/arena), 5-man dungeons, and raids -- so we
-- gate on IsInInstance() rather than any narrower instanceType check.
--
--   * On entering an instance (PLAYER_ENTERING_WORLD), SetScript
--     WorldMapFrame's OnShow to InstanceOnShow: a MANUALLY-INLINED copy
--     of Blizzard's WorldMapMixin:OnShow (Blizzard_WorldMap.lua:342-376)
--     with the C_ChatInfo.PerformEmote line at :352 omitted. The emote
--     never fires while in an instance, so no protected downstream is
--     reached.
--   * On leaving an instance, SetScript back to the raw Blizzard handler
--     captured at addon load, and re-add the reading-emote-opt-out
--     HookScript that SetScript wipes.
--
-- Why not always SetScript (both in and out of instances): our wrapper's
-- execution is PWM-tainted (we're addon-defined). When Blizzard's OnShow
-- code runs UNDER that taint, downstream MoneyFrame widgets and other
-- tooltip machinery inherit taint and emit "secret number" arithmetic
-- errors on the map's own header. Empirically observed on 2026-04-01
-- (commit 20ab7b1 moved away from SetScript for exactly this reason).
-- By SetScript'ing only inside instances and reverting on exit, open-
-- world OnShow runs on Blizzard's raw handler with no PWM taint at all.
--
-- MAINTENANCE: see the PATCH-DAY MAINTENANCE MANUAL at the top of this
-- file (Audit (A)). "Last synced" date lives inline in the InstanceOnShow
-- copy below and is the single source of truth.
--
-- OWN OnShow HOOKS: SetScript wipes HookScript-wrappers, so if PWM's own
-- OnShow logic lived as HookScripts, entering an instance would wipe them
-- and (a) InstanceOnShow wouldn't call them either, so they'd stop firing
-- until the next map close-and-reopen after exit; (b) on instance exit
-- we'd have to re-add them all manually. To avoid both problems, PWM's
-- own OnShow work is registered via Addon.RegisterWorldMapOnShow (defined
-- below) and dispatched from a single point that both the plain HookScript
-- (outside instances) and InstanceOnShow (inside instances) call. Other
-- PWM files (restoreAndReset.lua) and other sections (section (10)) use
-- this registration instead of HookScript for the same reason.
--
-- THIRD-PARTY OnShow HOOKS -- KNOWN LIMITATION:
-- SetScript replaces the whole OnShow hook chain with InstanceOnShow, so
-- any HookScripts other addons attached to WorldMapFrame:OnShow do NOT
-- fire while the player is inside an instance. Popular map addons that
-- HookScript OnShow (Mapster, Leatrix_Maps, and similar) therefore skip
-- their in-instance customizations. Their hooks resume automatically on
-- instance exit -- see the restore path below, which SetScripts the frame
-- back to the captured pre-transition wrapper (Blizzard's OnShow + every
-- HookScript that was on it at the moment we transitioned in, ours and
-- third-party alike).
--
-- Third-party hooks added DURING an instance wrap InstanceOnShow and do
-- fire in-instance, but are then dropped on exit for the symmetric
-- reason (our restore doesn't know about them). This mainly affects the
-- /reload-during-an-instance case.
--
-- Why we accept this: the alternatives are worse. Calling the captured
-- pre-transition wrapper from InstanceOnShow to fan out third-party
-- hooks in-instance would re-run Blizzard's OnShow first (that's how
-- HookScript composition works -- the original is embedded, not
-- separable), which fires the PerformEmote we're specifically avoiding.
-- WoW doesn't expose an API to iterate a frame's HookScripts
-- individually, so we can't call "just the hooks" without also calling
-- Blizzard's OnShow. Temporarily swapping C_ChatInfo.PerformEmote around
-- the call would work mechanically but re-opens the field-entry taint
-- trap that broke /sorry (see HISTORICAL CONTEXT above).
--
-- Post-hooks on C_ChatInfo.PerformEmote itself (Leatrix_Maps's approach)
-- are POST-only -- they cancel the emote animation AFTER PerformEmote has
-- already fired ADDON_ACTION_BLOCKED from tainted execution. Fine for a
-- cosmetic emote toggle on an addon that doesn't taint mapID; useless
-- for suppressing the underlying error PWM has to deal with.
--
do
  -- Callback list used by both the HookScript below (outside instances)
  -- and by InstanceOnShow (inside instances). Forward-declared so
  -- InstanceOnShow can close over it.
  local onShowCallbacks = {}
  Addon.RegisterWorldMapOnShow = function(fn)
    table.insert(onShowCallbacks, fn)
  end

  -- ------------------------------------------------------------------------
  -- MANUAL COPY of WorldMapMixin:OnShow (Blizzard_WorldMap.lua:342-376).
  -- Last synced 2026-08-04 vs Midnight 12.1.0. See PATCH-DAY MANUAL,
  -- Audit (A) at top of file for the sync procedure.
  -- Deviation from source: the C_ChatInfo.PerformEmote("READ", nil, true)
  -- call at line :352 is intentionally OMITTED here.
  -- ------------------------------------------------------------------------
  local function InstanceOnShow(self)
    if self.needUpdateDisplayState then
      local displayState = self:GetOpenDisplayState()
      self:SetDisplayState(displayState)
      self.needUpdateDisplayState = nil
    end

    local frameStrata = C_GameRules.GetGameRuleAsFrameStrata(Enum.GameRule.WorldMapFrameStrata)
    if frameStrata and frameStrata ~= "UNKNOWN" then
      self:SetFrameStrata(frameStrata)
    end

    local mapID = MapUtil.GetDisplayableMapForPlayer()
    self:SetMapID(mapID)
    MapCanvasMixin.OnShow(self)
    self:ResetZoom()

    -- OMITTED: C_ChatInfo.PerformEmote("READ", nil, true) -- see section (2) header.
    PlaySound(SOUNDKIT.IG_QUEST_LOG_OPEN)

    PlayerMovementFrameFader.AddDeferredFrame(self, .5, 1.0, .5, function()
      return GetCVarBool("mapFade") and not self:IsMouseOver()
    end)
    self:CheckAndShowTutorialTooltip()

    local miniWorldMap = GetCVarBool("miniWorldMap")
    local maximized = self:IsMaximized()
    if miniWorldMap ~= maximized then
      if miniWorldMap then
        self.BorderFrame.MaximizeMinimizeFrame:Minimize()
      else
        self.BorderFrame.MaximizeMinimizeFrame:Maximize()
      end
    end

    EventRegistry:TriggerEvent("WorldMapOnShow")

    -- Run PWM's own registered OnShow callbacks (see the OWN OnShow HOOKS
    -- note in the section (2) header).
    for _, fn in ipairs(onShowCallbacks) do fn(self) end
  end

  -- Dispatch HookScript: runs the callbacks after Blizzard's original
  -- OnShow when we're NOT inside an instance. Inside instances,
  -- InstanceOnShow calls the same callbacks directly at its tail.
  WorldMapFrame:HookScript("OnShow", function(self)
    for _, fn in ipairs(onShowCallbacks) do fn(self) end
  end)

  -- Reading-emote opt-out. Cancels the emote after Blizzard's OnShow fired
  -- it, if the user has disabled it in PWM options. Only meaningful outside
  -- instances (inside, InstanceOnShow doesn't fire the emote in the first
  -- place). Cheap call, no field write.
  Addon.RegisterWorldMapOnShow(function(self)
    if not PWM_config.showReadingEmote and not IsInInstance() then
      C_ChatInfo.CancelEmote()
    end
  end)

  local instanceActive = false
  local preInstanceOnShow = nil  -- Blizzard OnShow + accumulated HookScripts

  local instanceTransitionFrame = CreateFrame("Frame")
  instanceTransitionFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
  instanceTransitionFrame:SetScript("OnEvent", function()
    if IsInInstance() then
      if not instanceActive then
        instanceActive = true
        -- Snapshot the full current OnShow (Blizzard's + all HookScripts,
        -- including our callback dispatch) so we can restore it verbatim
        -- on exit.
        preInstanceOnShow = WorldMapFrame:GetScript("OnShow")
        WorldMapFrame:SetScript("OnShow", InstanceOnShow)
      end
    else
      if instanceActive then
        instanceActive = false
        WorldMapFrame:SetScript("OnShow", preInstanceOnShow)
        preInstanceOnShow = nil
      end
    end
  end)
end


-- ============================================================================
-- (3) [reserved] -- see section (2)
-- ============================================================================
--
-- The reading-emote opt-out that used to live here is now installed inside
-- section (2) as ReadingEmoteOptOutHook because its lifecycle must be tied
-- to section (2)'s SetScript / restore cycle. Numbering preserved to keep
-- sections (4)-(10) stable.


-- ============================================================================
-- (4) Combat-end refresh
-- ============================================================================
--
-- Section (6)'s per-pin protected-call shadows skip protected calls during
-- combat and set this flag so we know a refresh is needed when combat ends.
-- Exposed on Addon because restoreAndReset.lua's RestoreMapState / ResetMap
-- also set it when they hit InCombatLockdown().
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
-- ==  that the "secret value" measurement-arithmetic trap that fires on     ==
-- ==  the canonical GameTooltip under PWM-origin taint doesn't trigger.     ==
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
-- ==  pool-acquire hook in section (6)) is mixin-chain-agnostic.            ==
-- ==                                                                        ==
-- ==  How OnMouseEnter / OnMouseLeave get installed (two paths):            ==
-- ==                                                                        ==
-- ==  Fresh pins (newPin == true): we set pin.OnMouseEnter as a TABLE       ==
-- ==  FIELD only. Blizzard's MapCanvasMixin:AcquirePin then runs            ==
-- ==  `assert(pin:GetScript("OnEnter") == nil)` at Blizzard_MapCanvas.lua   ==
-- ==  :280 (inside `if newPin then`) and binds the field as the script at   ==
-- ==  :283-284. Calling SetScript ourselves on a new pin would trip the     ==
-- ==  assert, so we must not.                                               ==
-- ==                                                                        ==
-- ==  Reused pins (newPin == false): Blizzard SKIPS the :262-289 SetScript  ==
-- ==  block entirely; whatever OnEnter/OnLeave scripts were bound at the    ==
-- ==  pin's first creation persist. If that first creation happened before  ==
-- ==  our pool wrapper was installed (e.g. another addon triggered an       ==
-- ==  AcquirePin during load before us), the original Blizzard handler is   ==
-- ==  permanently bound and table-field replacement alone has no effect --  ==
-- ==  the secret-number trap fires on every hover. Detect that case (first  ==
-- ==  time we see this pin AND newPin is false) in the pool wrapper and     ==
-- ==  rebind via SetScript explicitly. The :280 assert is inside `if newPin ==
-- ==  then` and does not fire on the reuse path, so SetScript is safe.      ==
-- ==                                                                        ==
-- ==  +---------------------------------------------------------------+     ==
-- ==  |  MAINTENANCE WARNING -- READ BEFORE EVERY RETAIL PATCH        |     ==
-- ==  +---------------------------------------------------------------+     ==
-- ==                                                                        ==
-- ==  The functions in the BLIZZARD-SOURCE COPIES region below are          ==
-- ==  MECHANICALLY copied from Blizzard source code, with GameTooltip       ==
-- ==  references rewritten to the local tooltip = PWMTooltip binding.       ==
-- ==  After EVERY Retail patch, diff each Blizzard original against the     ==
-- ==  PWM copy here and mirror any change. If you skip this audit,          ==
-- ==  tooltip content silently diverges from Blizzard's intent.             ==
-- ==                                                                        ==
-- ==  AUDIT CHECKLIST  (last audited: 2026-08-04 vs Midnight 12.1.0)        ==
-- ==                                                                        ==
-- ==    Blizzard_FrameXMLUtil/AreaPoiUtil.lua                               ==
-- ==        AreaPoiUtil.TryShowTooltip                lines 3-72            ==
-- ==                                                                        ==
-- ==    Blizzard_GameTooltip/Mainline/GameTooltip.lua                       ==
-- ==        (local) AddFloorLocationLine              lines 633-639         ==
-- ==        GameTooltip_AddQuest                      lines 641-759         ==
-- ==                                                                        ==
-- ==    Blizzard_UIPanels_Game/Mainline/WorldMapFrame.lua                   ==
-- ==        TaskPOI_OnEnter                           lines 167-187         ==
-- ==                                                                        ==
-- ==    Blizzard_SharedMapDataProviders/AreaPOIDataProvider.lua             ==
-- ==        AreaPOIPinMixin:OnMouseEnter              lines 159-181         ==
-- ==        (AreaPOIEventPinMixin, DelveEntrancePinMixin, QuestHubPin-      ==
-- ==         GlowMixin all inherit/delegate to AreaPOIPinMixin:OnMouseEnter ==
-- ==         -- see file pointers under their own dispatch branches.)       ==
-- ==        Canvas-specific XML inheritance:                                ==
-- ==          Blizzard_FlightMap/FM_AreaPOIDataProvider.xml:5               ==
-- ==            "FlightMap_AreaPOIPinTemplate" inherits AreaPOIPinTemplate  ==
-- ==            (mixin: FlightMap_AreaPOIPinMixin =                         ==
-- ==             CreateFromMixins(AreaPOIPinMixin), no OnMouseEnter         ==
-- ==             override.)                                                 ==
-- ==                                                                        ==
-- ==    Blizzard_SharedMapDataProviders/DelveEntranceDataProvider.lua       ==
-- ==        DelveEntrancePinMixin = AreaPOIPinMixin:CreateSubPin(...) :42   ==
-- ==        (snapshot-copies AreaPOIPinMixin's OnMouseEnter at Blizzard     ==
-- ==         load; no DelveEntrance-specific OnMouseEnter to mirror.)       ==
-- ==                                                                        ==
-- ==    Blizzard_SharedMapDataProviders/QuestOfferDataProvider.lua          ==
-- ==        QuestHubPinGlowMixin:OnMouseEnter         lines 884-887         ==
-- ==        (calls AreaPOIPinMixin.OnMouseEnter(self) + self:AcknowledgeGlow =
-- ==         -- our dispatch branch preserves the AcknowledgeGlow call.)    ==
-- ==                                                                        ==
-- ==    Blizzard_SharedMapDataProviders/WorldQuestDataProvider.lua          ==
-- ==        WorldQuestPinMixin:OnMouseEnter           lines 420-424         ==
-- ==        WorldQuestPinMixin:OnMouseLeave           lines 426-430         ==
-- ==        The base "WorldQuestPinTemplate" itself is virtual only --      ==
-- ==        every canvas overrides GetPinTemplate to return a derivative:   ==
-- ==          Blizzard_WorldMap/WM_WorldQuestDataProvider.lua:4             ==
-- ==            -> "WorldMap_WorldQuestPinTemplate"                         ==
-- ==            (mixin: WorldMap_WorldQuestPinMixin =                       ==
-- ==             CreateFromMixins(WorldQuestPinMixin), no OnMouseEnter      ==
-- ==             override -- snapshot preserves the base's tooltip path.)   ==
-- ==          Blizzard_FlightMap/FM_WorldQuestDataProvider.lua:4            ==
-- ==            -> "FlightMap_WorldQuestPinTemplate"                        ==
-- ==          Blizzard_AnimaDiversionUI/AD_WorldQuestDataProvider.lua:4     ==
-- ==            -> "AnimaDiversion_WorldQuestPinTemplate"                   ==
-- ==        All three derivatives snapshot WorldQuestPinMixin's handlers    ==
-- ==        verbatim; PWM's WorldQuest branch dispatches on all four        ==
-- ==        template names.                                                 ==
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
-- ==        Canvas-specific XML inheritance:                                ==
-- ==          Blizzard_FlightMap/FM_VignetteDataProvider.xml:5              ==
-- ==            "FlightMap_VignettePinTemplate" inherits VignettePinTemplate =
-- ==            (mixin: FlightMap_VignettePinMixin =                        ==
-- ==             CreateFromMixins(VignettePinMixin), no OnMouseEnter        ==
-- ==             override.)                                                 ==
-- ==                                                                        ==
-- ==    Blizzard_SharedMapDataProviders/QuestBlobDataProvider.lua           ==
-- ==        QuestBlobPinMixin:UpdateTooltip           lines 182-229         ==
-- ==        QuestBlobPinMixin:OnMouseEnter            lines 231-233         ==
-- ==        QuestBlobPinMixin:OnMouseLeave            lines 235-239         ==
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
-- ==  HOW TO RE-AUDIT FOR NEWLY ADDED PIN TEMPLATES                         ==
-- ==                                                                        ==
-- ==  IMPORTANT: run the queries below across ALL Blizzard_* addons that    ==
-- ==  add data providers to a map canvas -- NOT just the "shared" folder.   ==
-- ==  Canvas-specific addons routinely OVERRIDE GetPinTemplate to return    ==
-- ==  their own derivative template name (e.g. WorldMap_WorldQuestPin-      ==
-- ==  Template) while snapshot-copying the base mixin's OnMouseEnter via    ==
-- ==  CreateFromMixins -- so the base pin template is never actually        ==
-- ==  created on that canvas, and matching only on the base template name   ==
-- ==  is a silent miss. This bit us on 2026-06-10: our WorldQuestPin-       ==
-- ==  Template dispatch entry was never hit on WorldMapFrame because        ==
-- ==  Blizzard uses WorldMap_WorldQuestPinTemplate there.                   ==
-- ==                                                                        ==
-- ==  Folders to audit (retail):                                            ==
-- ==    Blizzard_SharedMapDataProviders/  -- base mixins and shared         ==
-- ==    Blizzard_WorldMap/                -- WM_* derivatives               ==
-- ==    Blizzard_FlightMap/               -- FM_* derivatives               ==
-- ==    Blizzard_AnimaDiversionUI/        -- AnimaDiversion_* derivatives   ==
-- ==    Blizzard_BattlefieldMap/          -- uses base AreaPOI etc.         ==
-- ==                                                                        ==
-- ==  Four queries together cover the full surface:                         ==
-- ==                                                                        ==
-- ==  (1) Direct calls to risky tooltip builders                            ==
-- ==      pattern: TaskPOI_OnEnter | AreaPoiUtil.TryShowTooltip             ==
-- ==             | GameTooltip_AddWidgetSet | GameTooltip_AddQuestRewards-  ==
-- ==             ToTooltip | EmbeddedItemTooltip_ | SetTooltipMoney         ==
-- ==                                                                        ==
-- ==  (2) Templates inheriting OnMouseEnter from a covered template via     ==
-- ==      XML or via CreateSubPin / CreateFromMixins:                       ==
-- ==      pattern: CreateSubPin | inherits=".*PinTemplate"                  ==
-- ==             | CreateFromMixins\((WorldQuest|BonusObjective|AreaPOI|    ==
-- ==               QuestOffer|Invasion|Vignette|QuestBlob)PinMixin\)        ==
-- ==      Then cross-reference each hit against the covered mixins above.   ==
-- ==                                                                        ==
-- ==  (3) Templates that delegate to a covered OnMouseEnter via a live      ==
-- ==      table lookup inside their own OnMouseEnter body:                  ==
-- ==      pattern: \.OnMouseEnter\(self\)                                   ==
-- ==      Cross-reference the target mixin against the covered list.        ==
-- ==                                                                        ==
-- ==  (4) All GetPinTemplate return values ACROSS every audited folder:     ==
-- ==      pattern: return "([A-Za-z_]+PinTemplate)"                         ==
-- ==      Every template name that appears here MUST match one of the       ==
-- ==      dispatch branches in PatchPinForCustomTooltip. If a template      ==
-- ==      isn't matched but its mixin chain uses a covered mixin, add it    ==
-- ==      to the appropriate branch. Silent misses live here.               ==
-- ==                                                                        ==
-- ==  Negative-result reference: BaseMapPoiPinMixin:OnMouseEnter (Shared-   ==
-- ==  MapPoiTemplates.lua:163) calls only CheckShowTooltip, which uses      ==
-- ==  GameTooltip_SetTitle / AddNormalLine / AddInstructionLine -- pure     ==
-- ==  text, no measured widgets, no secret-number trap. So every template   ==
-- ==  whose only OnMouseEnter source is BaseMapPoiPinMixin:CreateSubPin     ==
-- ==  is safe to skip.                                                      ==
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


-- Shared OnMouseLeave for pin types whose only cleanup is hiding our
-- tooltip. Pins that need extra cleanup or an owner-check guard
-- (WorldQuest, Vignette, AreaPOI, QuestBlob) define their own below.
local function PWM_OnMouseLeave_HideOnly(self)
  PWMTooltip:Hide()
end


-- ----------------------------------------------------------------------------
-- PWMTooltip cross-frame lifecycle hooks
-- ----------------------------------------------------------------------------
-- Cleanup handlers that fire from events NOT driven by our own pin handlers:
-- map close, and another tooltip frame becoming visible. The pin-side
-- OnMouseEnter / OnMouseLeave handlers below cover the normal hover path.


-- Hide PWMTooltip when the map closes. Without this, closing the map via
-- hotkey while a pin tooltip is visible leaves the tooltip stuck to the
-- cursor (OnMouseLeave never fires because the mouse never physically left
-- the pin -- the pin was hidden underneath it). PWMTooltip is parented to
-- UIParent, not WorldMapFrame, so it doesn't inherit the hide.
WorldMapFrame:HookScript("OnHide", function()
  PWMTooltip:Hide()
end)


-- Hide PWMTooltip atomically when GameTooltip becomes visible on a QuestBlob
-- region (via an unpatched pin like OccupiedPlotPinTemplate). Without this
-- the QuestBlobPin_UpdateTooltip's gtOwner deferral only kicks in on the
-- NEXT OnUpdate frame, leaving a one-frame visual overlap of the blob's
-- PWMTooltip and the pin's GameTooltip. Blob-side deferral remains as the
-- steady-state guard; this hook just closes the transition-frame gap.
GameTooltip:HookScript("OnShow", function()
  if PWMTooltip:IsShown() then
    local o = PWMTooltip:GetOwner()
    if o and o.pinTemplate == "QuestBlobPinTemplate" then
      PWMTooltip:Hide()
    end
  end
end)


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
-- Source lines: 633-639 (file-local helper used by GameTooltip_AddQuest)
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
-- Source lines: 641-759
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
-- Source lines: 167-187
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
-- This handler also serves the templates whose OnMouseEnter is (or
-- delegates to) AreaPOIPinMixin's. Per-instance replacement catches them
-- all because we install on pin.OnMouseEnter directly:
--   * AreaPOIPinTemplate                 -- direct match
--   * AreaPOIEventPinTemplate            -- mixin delegates via live lookup
--                                          (AreaPOIEventDataProvider.lua:76)
--   * DelveEntrancePinTemplate           -- AreaPOIPinMixin:CreateSubPin
--                                          (DelveEntranceDataProvider.lua:42)
--   * QuestHubPinTemplate                -- XML inherits AreaPOIPinTemplate;
--                                          its mixin's OnMouseEnter delegates
--                                          to AreaPOIPinMixin.OnMouseEnter
--                                          (QuestOfferDataProvider.lua:884-887)
--                                          and additionally calls
--                                          self:AcknowledgeGlow() -- preserved
--                                          by the QuestHub branch in
--                                          PatchPinForCustomTooltip below.
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
-- COPY OF: QuestBlobDataProvider.lua :: QuestBlobPinMixin:UpdateTooltip / :OnMouseEnter / :OnMouseLeave
-- Source lines: 182-229 (UpdateTooltip), 231-233 (OnMouseEnter), 235-239 (OnMouseLeave)
--
-- Adaptations from Blizzard's source:
--   * GameTooltip -> local tooltip = PWMTooltip everywhere the blob writes.
--   * GameTooltip:GetOwner() -> tooltip:GetOwner() for the "another pin
--     already owns the tooltip" deferral check.
--   * TaskPOI_OnEnter -> PWM_TaskPOI_OnEnter for the threat-quest branch.
--   * OnMouseEnter wraps UpdateTooltip in a DebugLog line (matches the
--     pattern the other PWM_*_OnMouseEnter handlers use).
--   * OnMouseLeave keeps its `owner == self` guard. This is LOAD-BEARING:
--     UpdateTooltip calls self:OnMouseLeave() every frame when the cursor
--     isn't over a quest area, and without the guard any patched pin's
--     tooltip currently on PWMTooltip would be wiped by the blob's
--     OnUpdate. That's why QuestBlob can't share PWM_OnMouseLeave_HideOnly.
--
-- Not in Blizzard's source (PWM-specific additions inside UpdateTooltip):
--   * A second deferral check against GameTooltip. Blizzard's one check on
--     GameTooltip alone was sufficient because every stock pin uses
--     GameTooltip. PWM splits tooltips across two frames -- patched pins
--     on PWMTooltip (caught by the first check), unpatched pins (dungeon
--     entrance, quest pin, content tracking, ...) still on GameTooltip.
--     Without the second check the blob's PWMTooltip would render on top
--     of the pin's GameTooltip whenever the cursor is on such a pin
--     inside the blob region.
--   * Both deferral checks go through PWM_ShouldDeferToTooltip, which
--     only defers when the other tooltip is ACTIVELY displayed for
--     something the cursor is still on. A plain "owner ~= self" check
--     (as Blizzard uses) defers indefinitely to a stale-owner tooltip,
--     because neither Hide() nor FadeOut() clears GetOwner() -- for the
--     FadeOut() case (unit frames) that's the full fade duration (several
--     seconds -- this is the visible "blob tooltip is delayed" quirk in
--     the stock Blizzard map), for a PWMTooltip owned by a previously-
--     hovered patched pin that's forever until something else calls
--     SetOwner, and for a UIParent-anchored world tooltip that's both
--     the pre-fade linger AND the fade combined. See PWM_ShouldDeferTo-
--     Tooltip's own header for the complete rule set and per-flavor
--     rationale.
--
-- pin.UpdateTooltip is assigned to PWM_QuestBlobPin_UpdateTooltip via the
-- dispatch below, so callers other than OnMouseEnter (OnUpdate cursor
-- tracking, etc.) also route through PWMTooltip.
-- ----------------------------------------------------------------------------
-- Should the blob defer to `tt` (already displaying something owned by
-- another frame)? Yes only if the other tooltip is ACTIVELY, LEGITIMATELY
-- displayed for something the cursor is still on. Rules out, in order:
--   * no owner, or owner is the blob itself -- nothing to defer to;
--   * not shown -- stale owner from Hide() (neither Hide() nor FadeOut()
--     clears GetOwner());
--   * alpha < 1 -- fading out, will complete on its own;
--   * owner == UIParent -- screen-anchored floating tooltip (world-unit
--     hover, world-object hover, cinematic text, ...). Lingers at alpha=1
--     for a while after the cursor leaves the source before the fade even
--     starts. The blob's UpdateTooltip only runs when cursor is over the
--     map, and UIParent is a screen-covering anchor frame with no direct
--     relationship to any specific point the cursor is on, so any such
--     tooltip is by definition stale from the blob's perspective;
--   * owner:IsMouseOver()==false -- frame-anchored owner (PlayerFrame etc.)
--     that the cursor has left; catches the linger period for those too.
-- Together these fix Blizzard's "delayed blob tooltip after hovering
-- another tooltip source" quirk in every flavor observed so far.
local function PWM_ShouldDeferToTooltip(tt, ownerSelf)
  local owner = tt:GetOwner()
  if not owner or owner == ownerSelf then return false end
  if not tt:IsShown() then return false end
  if tt:GetAlpha() < 1 then return false end
  if owner == UIParent then return false end
  if owner.IsMouseOver and not owner:IsMouseOver() then return false end
  return true
end

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

  -- Both owner-deferral checks below go through PWM_ShouldDeferToTooltip
  -- so they skip stale / fading / floating bindings -- see the COPY OF
  -- header above.
  local tooltip = PWMTooltip  -- ADAPTED
  if PWM_ShouldDeferToTooltip(tooltip, self) then
    return
  end

  -- ADDED: also defer to any pin currently owning GameTooltip -- see the
  -- COPY OF header above.
  if PWM_ShouldDeferToTooltip(GameTooltip, self) then
    if tooltip:IsShown() then tooltip:Hide() end
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

local function PWM_QuestBlobPin_OnMouseLeave(self)
  if PWMTooltip:GetOwner() == self then
    PWMTooltip:Hide()
  end
end


-- ============================================================================
-- ====  END OF BLIZZARD-SOURCE COPIES  =======================================
-- ============================================================================


-- Per-instance handler installer. Called from the pool-acquire hook in
-- section (6), once per new pin instance. Dispatches on pinTemplate
-- (threaded down because pin.pinTemplate isn't assigned yet at our call
-- site -- AcquirePin sets it AFTER pool:Acquire returns).
--
-- This function ONLY updates the OnMouseEnter / OnMouseLeave TABLE FIELDS.
-- The script-binding side is handled by the caller in section (6) because
-- it differs between fresh and reused pins: on a fresh pin Blizzard binds
-- the script for us at Blizzard_MapCanvas.lua:283-284 (so we must NOT
-- SetScript here -- the :280 assert would trip); on a reused pin Blizzard
-- skips that block entirely and the caller does an explicit SetScript.
-- See the section (5) banner above for the full reasoning.
local function PatchPinForCustomTooltip(pin, pinTemplate)
  if pin.pwm_custom_tooltip_patched then return end
  pin.pwm_custom_tooltip_patched = true

  if pinTemplate == "WorldQuestPinTemplate"
      or pinTemplate == "WorldMap_WorldQuestPinTemplate"       -- Blizzard_WorldMap/WM_WorldQuestDataProvider.xml
      or pinTemplate == "FlightMap_WorldQuestPinTemplate"      -- Blizzard_FlightMap/FM_WorldQuestDataProvider.xml
      or pinTemplate == "AnimaDiversion_WorldQuestPinTemplate" -- Blizzard_AnimaDiversionUI/AD_WorldQuestDataProvider.xml
      or pinTemplate == "BonusObjectivePinTemplate"
      or pinTemplate == "ThreatObjectivePinTemplate" then
    -- WorldQuest family: the three canvas-specific derivatives all use
    -- CreateFromMixins(WorldQuestPinMixin) which snapshot-copies OnMouseEnter
    -- verbatim -- their per-canvas subclasses only override RefreshVisuals /
    -- OnLoad, never the hover handlers. The base "WorldQuestPinTemplate"
    -- itself is a virtual XML template that no canvas creates directly (all
    -- three canvases override GetPinTemplate to return their derivative) --
    -- we still list it for defensive matching.
    -- BonusObjective / ThreatObjective have identical OnMouseEnter/OnMouseLeave
    -- structure to WorldQuest (see the audit-checklist note on the WorldQuest
    -- copy block above).
    pin.OnMouseEnter = PWM_WorldQuestPin_OnMouseEnter
    pin.OnMouseLeave = PWM_WorldQuestPin_OnMouseLeave

  elseif pinTemplate == "AreaPOIPinTemplate"
      or pinTemplate == "AreaPOIEventPinTemplate"
      or pinTemplate == "DelveEntrancePinTemplate"
      or pinTemplate == "FlightMap_AreaPOIPinTemplate" then    -- Blizzard_FlightMap/FM_AreaPOIDataProvider.xml
    -- All four share the AreaPOIPinMixin OnMouseEnter (directly, via live
    -- table-lookup delegation, via CreateSubPin snapshot copy, or via XML
    -- inheritance -- see the comment above PWM_AreaPOIPin_OnMouseEnter).
    -- FlightMap_AreaPOIPinMixin = CreateFromMixins(AreaPOIPinMixin) with no
    -- OnMouseEnter override. Capture THIS pin's mixin-copied OnMouseLeave
    -- (Blizzard's original) so our wrapper can forward the map TriggerEvents
    -- in it. Using the per-instance copy is mixin-chain-agnostic.
    local origLeave = pin.OnMouseLeave
    pin.OnMouseEnter = PWM_AreaPOIPin_OnMouseEnter
    pin.OnMouseLeave = function(self, ...)
      PWMTooltip:Hide()
      if origLeave then return origLeave(self, ...) end
    end

  elseif pinTemplate == "QuestHubPinTemplate" then
    -- QuestHubPinTemplate's mixin (QuestHubPinGlowMixin:OnMouseEnter at
    -- QuestOfferDataProvider.lua:884-887) calls AreaPOIPinMixin.OnMouseEnter
    -- AND then self:AcknowledgeGlow(). If we just installed
    -- PWM_AreaPOIPin_OnMouseEnter we'd lose the AcknowledgeGlow call, so we
    -- wrap to preserve it. AcknowledgeGlow is on the pin instance via the
    -- glow mixin; guard with a nil-check in case future patches remove it.
    local origLeave = pin.OnMouseLeave
    pin.OnMouseEnter = function(self, ...)
      PWM_AreaPOIPin_OnMouseEnter(self)
      if self.AcknowledgeGlow then self:AcknowledgeGlow() end
    end
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
      or pinTemplate == "FyrakkFlightVignettePinTemplate"
      or pinTemplate == "FlightMap_VignettePinTemplate" then   -- Blizzard_FlightMap/FM_VignetteDataProvider.xml
    -- FlightMap_VignettePinMixin = CreateFromMixins(VignettePinMixin) with
    -- no OnMouseEnter override (only OnLoad tweaks alpha/nudge).
    pin.OnMouseEnter = PWM_VignettePin_OnMouseEnter
    pin.OnMouseLeave = PWM_VignettePin_OnMouseLeave

  elseif pinTemplate == "QuestBlobPinTemplate" then
    -- Three fields to patch instead of two: pin.UpdateTooltip is public and
    -- gets called from OnUpdate cursor tracking, so it must route through
    -- PWMTooltip too. See the QuestBlobPin COPY OF block above for the full
    -- rationale, including why OnMouseLeave uses its own owner-check
    -- variant instead of the shared PWM_OnMouseLeave_HideOnly.
    pin.OnMouseEnter = PWM_QuestBlobPin_OnMouseEnter
    pin.OnMouseLeave = PWM_QuestBlobPin_OnMouseLeave
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
-- A __newindex metatable on <canvas>.pinPools catches future pool creation;
-- existing pools at install time are wrapped in a one-shot loop. Patches
-- are on the pin INSTANCE, so they survive pool recycling across map opens.
--
-- The wrapper handles two cases:
--   * Fresh pin (isNew == true): set pin.OnMouseEnter / .OnMouseLeave as
--     table fields only; Blizzard's AcquirePin then SetScripts them for us.
--   * Reused pin (isNew == false) seen for the first time: set the table
--     fields AND explicitly SetScript. Without the second step, the OnEnter
--     binding from the pin's original creation (potentially before our
--     wrapper was installed, with Blizzard's original tooltip-trap-prone
--     handler) would persist forever. See section (5) banner for the full
--     reasoning behind the two paths.
--
-- Canvas coverage: WorldMapFrame is installed unconditionally at file load;
-- FlightMapFrame is installed when Blizzard_FlightMap loads (LoD addon, only
-- loads on flight-master interaction). Any canvas we don't cover lets the
-- ORIGINAL Blizzard OnMouseEnter run on its pins, which for WorldQuest-
-- family pins hits the "secret number" trap under PWM taint. Historically
-- this section only covered WorldMapFrame -- the FlightMap coverage was
-- added 2026-06-10 after a WorldQuest-tooltip error surfaced from a pin
-- template we didn't dispatch (WorldMap_WorldQuestPinTemplate) and a
-- follow-up audit uncovered FlightMap / AnimaDiversion siblings too.
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
      if pin then
        -- Fresh pin: field-write only; Blizzard SetScripts it for us.
        -- Reused pin we've never patched: field-write + explicit SetScript,
        -- because Blizzard skips the SetScript block on reuse and any stale
        -- binding from the pin's original creation would persist.
        -- See section (6) header for the full rationale.
        local needsScriptRebind = (not isNew) and (not pin.pwm_custom_tooltip_patched)
        PatchPin(pin, pinTemplate)
        if needsScriptRebind then
          pin:SetScript("OnEnter", pin.OnMouseEnter)
          pin:SetScript("OnLeave", pin.OnMouseLeave)
        end
      end
      return pin, isNew
    end
  end

  local function InstallOnCanvas(canvas)
    if not canvas or not canvas.pinPools or canvas.pwm_canvas_installed then return end
    canvas.pwm_canvas_installed = true

    -- Wrap pools that already exist on this canvas (if any).
    for pinTemplate, pool in pairs(canvas.pinPools) do
      WrapPoolAcquire(pool, pinTemplate)
    end

    -- QuestBlobPin is acquired ONCE at data-provider registration time
    -- (before our addon loads) and never released -- QuestBlobDataProvider-
    -- Mixin:OnAdded calls this out as "a single permanent pin". Since it
    -- never comes back through Acquire, the pool wrapper above catches
    -- nothing for it. Patch it directly. No SetScript needed: QuestBlobPin
    -- drives its tooltip from OnUpdate via self:UpdateTooltip() (see
    -- QuestBlobDataProvider.lua:114-121), which resolves the method
    -- dynamically on the pin instance each call, so writing the field via
    -- PatchPin -> PatchPinForCustomTooltip is enough.
    local blobPool = canvas.pinPools["QuestBlobPinTemplate"]
    if blobPool then
      for pin in blobPool:EnumerateActive() do
        if not pin.pwm_custom_tooltip_patched then
          PatchPin(pin, "QuestBlobPinTemplate")
        end
      end
    end

    -- Catch future pool creation via a __newindex on the pinPools table.
    -- (Note: this replaces any existing metatable on pinPools. Blizzard
    -- doesn't set one, so this is fine today; if a future patch does, we'd
    -- need to chain.)
    setmetatable(canvas.pinPools, {
      __newindex = function(t, pinTemplate, pool)
        rawset(t, pinTemplate, pool)
        WrapPoolAcquire(pool, pinTemplate)
      end
    })
  end

  -- Main map: always available at addon load.
  InstallOnCanvas(WorldMapFrame)

  -- Flight map: load-on-demand. Blizzard_FlightMap loads when the player
  -- interacts with a flight master; FlightMapFrame is a global after that.
  -- If it's already loaded (edge case: /reload while at a flight master),
  -- install immediately; otherwise wait for ADDON_LOADED.
  if _G.FlightMapFrame then
    InstallOnCanvas(FlightMapFrame)
  else
    local flightWatcher = CreateFrame("Frame")
    flightWatcher:RegisterEvent("ADDON_LOADED")
    flightWatcher:SetScript("OnEvent", function(self, _, addonName)
      if addonName == "Blizzard_FlightMap" then
        InstallOnCanvas(_G.FlightMapFrame)
        self:UnregisterAllEvents()
      end
    end)
  end
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

    -- Goes through section (2)'s RegisterWorldMapOnShow so it still fires
    -- while section (2) SetScripts OnShow to InstanceOnShow inside an
    -- instance -- see the section (2) "OWN OnShow HOOKS" note.
    Addon.RegisterWorldMapOnShow(function()
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
