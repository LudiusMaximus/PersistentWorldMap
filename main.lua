local folderName, Addon = ...



-- Locals for frequently used global frames and functions.
local C_Map_GetPlayerMapPosition         = _G.C_Map.GetPlayerMapPosition

local Clamp                     = _G.Clamp
local GetTime                   = _G.GetTime
local WorldMapFrame             = _G.WorldMapFrame

local IsShiftKeyDown            = _G.IsShiftKeyDown
local GetScaledCursorPosition   = _G.GetScaledCursorPosition


-- To prevent player pin pings when we don't need them.
local playerPin = nil
Addon.PlayerPingAnimation = function(start)

  -- If we do not have the player pin yet, search it.
  if not playerPin or not playerPin.ShouldShowUnit or not playerPin:ShouldShowUnit("player") then
    playerPin = nil
    for k, _ in pairs(WorldMapFrame.dataProviders) do
      if type(k) == "table" and k.ShouldShowUnit then
        -- print("Found GroupMembersDataProvider.")
        if k:ShouldShowUnit("player") then
          playerPin = k
          break
        end
      end
    end
  end

  if playerPin then

    -- TOOD: Make PIN size an option.
    -- TODO: Also continuous ping animation.
    -- Default is 27.
    -- playerPin:SetUnitPinSize("player", 100)

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



local function EaseOutQuart(t)
  local invT = 1 - t
  local invT2 = invT * invT     -- (1 - t)^2
  local invT4 = invT2 * invT2   -- ((1 - t)^2)^2 = (1 - t)^4
  return 1 - invT4
end



-- Current target zoom.
local zoomStartTime
local currentStartScale = nil
local currentTargetScale = nil
local currentStartX = nil
local currentTargetX = nil
local currentStartY = nil
local currentTargetY = nil


-- Using an OnUpdate frame did not work without flickering of quest blobs.
-- local smoothZoomFrame = CreateFrame("Frame")
-- local function SmoothZoomOnUpdateFunction(self, elapsed)
  -- local zoomElapsed = Clamp(GetTime() - zoomStartTime, 0, PWM_config.zoomTimeSeconds)
  -- if zoomElapsed >= PWM_config.zoomTimeSeconds then
    -- WorldMapFrame.ScrollContainer:InstantPanAndZoom(currentTargetScale, currentTargetX, currentTargetY, true)
    -- smoothZoomFrame:SetScript("OnUpdate", nil)
    -- return
  -- end
  -- local zoomElapsedNormalized = zoomElapsed / PWM_config.zoomTimeSeconds
  -- WorldMapFrame.ScrollContainer:InstantPanAndZoom(currentStartScale + zoomElapsedNormalized * (currentTargetScale - currentStartScale), currentTargetX, currentTargetY, true)
-- end

-- So instead I use a super-fast ticker.
local zoomTicker


local function ZoomAndPanStop()
  if zoomTicker then
    zoomTicker:Cancel()
    zoomTicker = nil

    zoomStartTime = nil
    currentStartScale = nil
    currentTargetScale = nil
    currentStartX = nil
    currentTargetX = nil
    currentStartY = nil
    currentTargetY = nil
  end
end


local function ZoomTickerFunction(self)

  local zoomElapsed = Clamp(GetTime() - zoomStartTime, 0, PWM_config.zoomTimeSeconds)

  -- When we are done, make sure we have the final position.
  if zoomElapsed >= PWM_config.zoomTimeSeconds or (
      WorldMapFrame.ScrollContainer:GetCanvasScale() == currentTargetScale and
      WorldMapFrame.ScrollContainer:GetCurrentScrollX() == currentTargetX and
      WorldMapFrame.ScrollContainer:GetCurrentScrollY() == currentTargetY ) then
    local xMin, xMax, yMin, yMax = WorldMapFrame.ScrollContainer:CalculateScrollExtentsAtScale(currentTargetScale)
    local nextX = Clamp(currentTargetX, xMin, xMax)
    local nextY = Clamp(currentTargetY, yMin, yMax)
    WorldMapFrame.ScrollContainer:InstantPanAndZoom(currentTargetScale, currentTargetX, currentTargetY, true)
    ZoomAndPanStop()

  -- Otherwise, set the intermediate zoom and pan.
  else
    local zoomElapsedNormalized = EaseOutQuart(zoomElapsed / PWM_config.zoomTimeSeconds)
    local nextScale = currentStartScale + zoomElapsedNormalized * (currentTargetScale - currentStartScale)
    local xMin, xMax, yMin, yMax = WorldMapFrame.ScrollContainer:CalculateScrollExtentsAtScale(nextScale)
    local nextX = Clamp(currentStartX + zoomElapsedNormalized * (currentTargetX - currentStartX), xMin, xMax)
    local nextY = Clamp(currentStartY + zoomElapsedNormalized * (currentTargetY - currentStartY), yMin, yMax)
    WorldMapFrame.ScrollContainer:InstantPanAndZoom(nextScale, nextX, nextY, true)

  end
end


local function ZoomAndPan(currentScale, targetScale, currentX, targetX, currentY, targetY)

  if PWM_config.zoomTimeSeconds == 0 then
    WorldMapFrame.ScrollContainer:InstantPanAndZoom(targetScale, targetX, targetY, true)

  else

    -- Setup variables for the zoom/pan process.
    zoomStartTime = GetTime()
    currentStartScale = currentScale
    currentTargetScale = targetScale
    currentStartX = currentX
    currentTargetX = targetX
    currentStartY = currentY
    currentTargetY = targetY

    -- Using an OnUpdate frame did not work without flickering of quest blobs.
    -- smoothZoomFrame:SetScript("OnUpdate", SmoothZoomOnUpdateFunction)
    -- So instead we use a super-fast ticker.
    if not zoomTicker then
      zoomTicker = C_Timer.NewTicker(0.01, ZoomTickerFunction)
    end

  end
end




-- Disable default zoom.
WorldMapFrame.ScrollContainer:SetMouseWheelZoomMode(MAP_CANVAS_MOUSE_WHEEL_ZOOM_BEHAVIOR_NONE)

-- Override mouse wheel for custom zoom behavior.
WorldMapFrame.ScrollContainer:HookScript("OnMouseWheel", function(self, delta)

  -- If we are currently zooming, we take currentTargetScale as the current scale.
  local currentScale = currentTargetScale or self:GetCanvasScale()

  -- Check if zooming is still possible.
  if (delta < 0 and currentScale == self:GetScaleForMinZoom()) or (delta > 0 and currentScale == self:GetScaleForMaxZoom()) then
    return
  end

  -- We could do it like MapCanvasScrollControllerMixin:OnMouseWheel()
  -- but self.zoomAmountPerMouseWheelDelta behaves differently on different maps.
  -- local targetScale = currentScale + self.zoomAmountPerMouseWheelDelta * delta
  -- Using the predefined zoom levels of each map is better.
  local currentZoomLevelIndex = self:GetZoomLevelIndexForScale(currentScale)
  local targetScale = (self.zoomLevels[currentZoomLevelIndex + delta] or self.zoomLevels[currentZoomLevelIndex]).scale

  local currentX = self:GetCurrentScrollX()
  local currentY = self:GetCurrentScrollY()

  local targetX = currentX
  local targetY = currentY

  -- TODO: Make zoom-panning towards cursor position optional.

  -- The map boundaries are taken care of by the zoom function.
  ZoomAndPan(currentScale, targetScale, currentX, targetX, currentY, targetY)

end)





-- Do a smooth pan before activating auto-centering.
local autoCenterStartTimer
local function AutoCenterStartTimerFunction()
  autoCenterStartTimer = nil
end

Addon.EnableCenterOnPlayer = function()
  if PWM_config.autoCentering then return end

  PWM_config.autoCentering = true
  Addon.UpdateAutoCenterLockButton()

  -- Do a smooth pan before activating auto-centering.
  -- But not when zoomed fully out, because that causes a slight map jerk.
  local currentScale = WorldMapFrame.ScrollContainer:GetCanvasScale()
  if currentScale > WorldMapFrame.ScrollContainer:GetScaleForMinZoom() then

    local currentX = WorldMapFrame.ScrollContainer:GetCurrentScrollX()
    local currentY = WorldMapFrame.ScrollContainer:GetCurrentScrollY()

    local playerPos = C_Map_GetPlayerMapPosition(WorldMapFrame:GetMapID(), "player")
    if playerPos then
      local targetX, targetY = playerPos:GetXY()
      targetX = Clamp(targetX, WorldMapFrame.ScrollContainer.scrollXExtentsMin, WorldMapFrame.ScrollContainer.scrollXExtentsMax)
      targetY = Clamp(targetY, WorldMapFrame.ScrollContainer.scrollYExtentsMin, WorldMapFrame.ScrollContainer.scrollYExtentsMax)

      Addon.PlayerPingAnimation(true)
      ZoomAndPan(currentScale, currentScale, currentX, targetX, currentY, targetY)
    end

    autoCenterStartTimer = C_Timer.NewTimer(PWM_config.zoomTimeSeconds, AutoCenterStartTimerFunction)
  end

end

Addon.DisableCenterOnPlayer = function()
  if autoCenterStartTimer then
    autoCenterStartTimer:Cancel()
    autoCenterStartTimer = nil
  end
  ZoomAndPanStop()

  PWM_config.autoCentering = false
  Addon.UpdateAutoCenterLockButton()
end






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
      -- Stop any zoom animation.
      ZoomAndPanStop()
      -- If currently moving towards auto-centering, interrupt.
      if autoCenterStartTimer then
        Addon.DisableCenterOnPlayer()
      end
    end

    if IsShiftKeyDown() then
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
    if PWM_config.autoCenterEnabled then
      local currentTime = GetTime()
      if currentTime - lastClickTime < PWM_config.doubleClickTime then
        Addon.EnableCenterOnPlayer()
      end
      lastClickTime = currentTime
    end

    if resetMap then
      if IsShiftKeyDown() then
        Addon.ResetMap()
      end
      resetMap = false
    end
  end
end)




WorldMapFrame.ScrollContainer:HookScript("OnUpdate", function(self)

  -- Disable auto-centering and stop zooming when player starts to drag.
  if isMouseDown then
    ZoomAndPanStop()
    local cursorX, cursorY = GetScaledCursorPosition()
    if cursorX ~= lastCursorX or cursorY ~= lastCursorY then
      Addon.DisableCenterOnPlayer()
    end
  end


  -- Auto-centering.
  if PWM_config.autoCentering and not autoCenterStartTimer then

    -- Ensure that targetScale exists. Not checking this sometimes caused an error
    -- when changing into a zone with loading screen (e.g. Ringing Deeps to Dornogal).
    if not self.targetScale then return end

    -- Ensure scroll extents are initialized. Has not caused issues so far, but you never know.
    if not self.scrollXExtentsMin or not self.scrollXExtentsMax or
       not self.scrollYExtentsMin or not self.scrollYExtentsMax then
      return
    end

    local playerPos = C_Map_GetPlayerMapPosition(self:GetParent():GetMapID(), "player")
    if not playerPos then return end

    local targetX, targetY = playerPos:GetXY()
    targetX = Clamp(targetX, self.scrollXExtentsMin, self.scrollXExtentsMax)
    targetY = Clamp(targetY, self.scrollYExtentsMin, self.scrollYExtentsMax)


    -- Use instant pan to correct the position.
    if self.currentScrollX ~= targetX then
      self.currentScrollX = targetX
      self.targetScrollX = targetX
      self:SetNormalizedHorizontalScroll(targetX)
    end
    if self.currentScrollY ~= targetY then
      self.currentScrollY = targetY
      self.targetScrollY = targetY
      self:SetNormalizedVerticalScroll(targetY)
    end

  end

end)




local updateMapFrame = CreateFrame("Frame")
-- Needed to remove tomb stone pin.
updateMapFrame:RegisterEvent("PLAYER_UNGHOST")
-- Sometimes accepting (world) quests does not remove the exlamation mark.
updateMapFrame:RegisterEvent("QUEST_ACCEPTED")
-- Just to be on the safe side.
updateMapFrame:RegisterEvent("QUEST_REMOVED")
-- Needed to change flightpoint icon colour after learning a new flightpoint.
updateMapFrame:RegisterEvent("TAXI_NODE_STATUS_CHANGED")
-- Update map after killing dungeon/raid boss.
updateMapFrame:RegisterEvent("TREASURE_PICKER_CACHE_FLUSH")
-- To refresh map after trader's tenders chest reward collected.
updateMapFrame:RegisterEvent("CHEST_REWARDS_UPDATED_FROM_SERVER")
-- To refresh map when neighborhood house ownerships change.
updateMapFrame:RegisterEvent("NEIGHBORHOOD_INFO_UPDATED")
updateMapFrame:SetScript("OnEvent", function()
  -- Sometimes does not work right away.
  C_Timer.NewTimer(0.5, function()
    if not WorldMapFrame:IsShown() then return end
    WorldMapFrame:OnMapChanged()
    Addon.PlayerPingAnimation(false)
  end)
end)


-- RareScanner integration: refresh RareScanner's map pins after events that
-- change pin state without triggering a world-map refresh.
--
-- Two such events exist:
--
-- (a) FILTER CHANGE via the scanner popup's two buttons. The popup (the
--     global RARESCANNER_BUTTON frame) has a FilterEntityButton (adds to
--     filter) and UnFilterEntityButton (removes from filter). Despite the
--     visual impression of a single Stop/Go toggle, these are two distinct
--     Button frames overlapping pixel-perfect at the same anchor; one is
--     always hidden and the other shown. They share the same WoW global
--     name "FilterEntityButton" (RareScanner passes the same string as the
--     second arg to both CreateFrame calls -- /framestack shows that name
--     regardless of which variant is currently visible), and are only
--     distinguished by their field name on scanner_button. Clicking either
--     calls RSConfigDB.SetNpcFiltered / SetContainerFiltered /
--     SetEventFiltered, but RareScanner does NOT refresh the world map
--     afterwards.
--
-- (b) ENTITY DETECTION via the scanner. When a vignette is detected,
--     RSButtonHandler eventually calls RSRecentlySeenTracker.AddRecentlySeen,
--     which marks the entity recently-seen (this is what flips the map pin
--     to the PINK_*_TEXTURE "just detected" variant and updates the "last
--     seen" timestamp in the pin's tooltip). AddRecentlySeen then forwards
--     to RSRecentlySeenTracker.AddPendingAnimation WITHOUT the
--     refreshWorldMap flag (see Core/Service/RSRecentlySeenTracker.lua line
--     129), so the world map is not refreshed. After detection,
--     scanner_button:ShowButton() surfaces the popup; that method is the
--     closest reliably-hookable point to the detection.
--
-- (Other filter-change entry points already refresh on their own:
-- RareScanner's world-map dropdown button does it via
-- RSWorldMapButtonMixin:NotifyUpdate -> RSProvider.RefreshAllDataProviders.
-- The Shift+Alt+click filter on a map pin -- RSEntityPinMixin:OnMouseDown
-- in RareScanner -- calls RSProvider.RefreshAllDataProviders itself.)
--
-- We CAN'T just call WorldMapFrame:OnMapChanged() here (the way the
-- updateMapFrame handler above does for game events): that only iterates
-- WorldMapFrame.dataProviders, and RareScanner registers its pins on a
-- separate RSWorldMap.dataProviders table that Blizzard's OnMapChanged
-- doesn't touch (see RareScanner/Core/Libs/RSProvider.lua and
-- /Core/Plugins/MapPlugin/MapCanvas/RSWorldMap.lua).
--
-- We also can't hooksecurefunc RSConfigDB.SetXxxFiltered or
-- RSRecentlySeenTracker.AddRecentlySeen directly -- both live in RareScanner's
-- private addon namespace and aren't globals. But two things ARE global and
-- reachable:
--   * RARESCANNER_BUTTON (the scanner popup frame) and its child buttons --
--     hookable via HookScript on OnClick (filter buttons) and
--     hooksecurefunc on its :ShowButton method (detection path).
--   * RSWorldMapButtonMixin (the world-map button mixin) -- its NotifyUpdate
--     method body only references file-local RSMinimap / RSProvider upvalues,
--     not `self`, so we can invoke it from outside the addon: it triggers
--     the same RSMinimap.RefreshAllData + RSProvider.RefreshAllDataProviders
--     pair RareScanner uses for its dropdown.
do
  local function DoRefresh()
    if not WorldMapFrame:IsShown() then return end
    if RSWorldMapButtonMixin and RSWorldMapButtonMixin.NotifyUpdate then
      RSWorldMapButtonMixin.NotifyUpdate(nil)
    end
  end

  -- Deferred variant for the detection path (case (b)): ShowAlert in
  -- RSButtonHandler.lua calls button:ShowButton() at line 494 but only calls
  -- RSRecentlySeenTracker.AddRecentlySeen at line 524 -- so a synchronous
  -- post-hook on ShowButton would rebuild POIs BEFORE the entity is marked
  -- recently-seen, and the pin texture wouldn't pick up the PINK_*_TEXTURE
  -- "recently seen" variant. C_Timer.After(0, ...) defers to next frame, by
  -- which time AddRecentlySeen has populated recently_seen_entities.
  local function DoRefreshDeferred()
    C_Timer.After(0, DoRefresh)
  end

  local rsHookFrame = CreateFrame("Frame")
  rsHookFrame:RegisterEvent("PLAYER_LOGIN")
  rsHookFrame:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    local scanner = _G.RARESCANNER_BUTTON
    if not scanner then return end -- RareScanner not installed; nothing to hook.

    -- (a) Filter buttons. Refresh synchronously: post-hooks fire after the
    -- original OnClick body returns, by which time RSConfigDB.SetXxxFiltered
    -- has committed (same pattern RareScanner's pin Shift+Alt+click uses --
    -- see RSEntityPinMixin.lua:81).
    local function HookFilterButton(button)
      if button and not button.pwm_filter_hooked then
        button.pwm_filter_hooked = true
        button:HookScript("OnClick", DoRefresh)
      end
    end
    HookFilterButton(scanner.FilterEntityButton)
    HookFilterButton(scanner.UnFilterEntityButton)

    -- (b) Detection. hooksecurefunc (not HookScript("OnShow")) because the
    -- popup may already be visible from a previous detection -- the new
    -- ShowButton call updates its content without firing OnShow. We want
    -- to catch every detection.
    if scanner.ShowButton then
      hooksecurefunc(scanner, "ShowButton", DoRefreshDeferred)
    end
  end)
end




-- -- In case you ever need this again.
-- function RedrawBlobs()
  -- for provider, _ in pairs(WorldMapFrame.dataProviders) do
    -- if type(provider) == "table" then

      -- -- if provider.AddQuest then
        -- -- print("Found QuestDataProvider")
        -- -- provider:RefreshAllData()      -- Working!
      -- -- end

      -- -- Minimal alternative to redraw blob. Unfortunately does not fix flicker.
      -- if provider.IsShowingWorldQuests then
        -- -- print("Found QuestBlobDataProvider")

        -- -- provider:OnMapChanged()
        -- -- provider.pin:OnMapChanged()
        -- -- provider.pin:Refresh()

        -- provider.pin:DrawNone()
        -- provider.pin:DrawBlob(provider.pin.questID, true)
      -- end

    -- end
  -- end
-- end

