local folderName, Addon = ...



-- Locals for frequently used global frames and functions.
local C_Map_GetPlayerMapPosition         = _G.C_Map.GetPlayerMapPosition

local Clamp                     = _G.Clamp
local GetTime                   = _G.GetTime
local WorldMapFrame             = _G.WorldMapFrame

local IsShiftKeyDown            = _G.IsShiftKeyDown
local GetScaledCursorPosition   = _G.GetScaledCursorPosition


-- TODO: Make optional.
local DOUBLE_CLICK_TIME = 0.25


-- TODO: Make optional.
local ZOOM_TIME_SECONDS = 0.3


-- TODO: Store in saved variable
Addon.autoCentering = false



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
  -- local zoomElapsed = Clamp(GetTime() - zoomStartTime, 0, ZOOM_TIME_SECONDS)
  -- if zoomElapsed >= ZOOM_TIME_SECONDS then
    -- WorldMapFrame.ScrollContainer:InstantPanAndZoom(currentTargetScale, currentTargetX, currentTargetY, true)
    -- smoothZoomFrame:SetScript("OnUpdate", nil)
    -- return
  -- end
  -- local zoomElapsedNormalized = zoomElapsed / ZOOM_TIME_SECONDS
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

  local zoomElapsed = Clamp(GetTime() - zoomStartTime, 0, ZOOM_TIME_SECONDS)

  -- When we are done, make sure we have the final position.
  if zoomElapsed >= ZOOM_TIME_SECONDS or (
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
    local zoomElapsedNormalized = EaseOutQuart(zoomElapsed / ZOOM_TIME_SECONDS)
    local nextScale = currentStartScale + zoomElapsedNormalized * (currentTargetScale - currentStartScale)
    local xMin, xMax, yMin, yMax = WorldMapFrame.ScrollContainer:CalculateScrollExtentsAtScale(nextScale)
    local nextX = Clamp(currentStartX + zoomElapsedNormalized * (currentTargetX - currentStartX), xMin, xMax)
    local nextY = Clamp(currentStartY + zoomElapsedNormalized * (currentTargetY - currentStartY), yMin, yMax)
    WorldMapFrame.ScrollContainer:InstantPanAndZoom(nextScale, nextX, nextY, true)

  end
end


local function ZoomAndPan(currentScale, targetScale, currentX, targetX, currentY, targetY)

  if ZOOM_TIME_SECONDS == 0 then
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
WorldMapFrame.ScrollContainer:SetScript("OnMouseWheel", function(self, delta)

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
  if Addon.autoCentering then return end

  Addon.autoCentering = true
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

    autoCenterStartTimer = C_Timer.NewTimer(ZOOM_TIME_SECONDS, AutoCenterStartTimerFunction)
  end

end

Addon.DisableCenterOnPlayer = function()
  if autoCenterStartTimer then
    autoCenterStartTimer:Cancel()
    autoCenterStartTimer = nil
  end
  ZoomAndPanStop()

  Addon.autoCentering = false
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
    local currentTime = GetTime()
    if currentTime - lastClickTime < DOUBLE_CLICK_TIME then
      Addon.EnableCenterOnPlayer()
    end
    lastClickTime = currentTime

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
  if Addon.autoCentering and not autoCenterStartTimer then

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
-- Just to be on the save side.
updateMapFrame:RegisterEvent("QUEST_REMOVED")
-- Needed to change flightpoint icon colour after learning a new flightpoint. 
updateMapFrame:RegisterEvent("TAXI_NODE_STATUS_CHANGED")
updateMapFrame:SetScript("OnEvent", function()
  -- Sometimes does not work right away.
  C_Timer.NewTimer(0.2, function()
    if not WorldMapFrame:IsShown() then return end
    WorldMapFrame:OnMapChanged()
    Addon.PlayerPingAnimation(false)
  end)
end)






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

