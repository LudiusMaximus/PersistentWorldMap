local folderName, Addon = ...


local CONFIG_DEFAULTS = {
  resetMapAfter     = 15,
  autoCentering     = false,
  zoomTimeSeconds   = 0.3,
  autoCenterEnabled = true,
  doubleClickTime   = 0.25,
}


local addonLoadedFrame = CreateFrame("Frame")
addonLoadedFrame:RegisterEvent("ADDON_LOADED")
addonLoadedFrame:SetScript("OnEvent", function(self, event, arg1)
  if arg1 ~= folderName then return end

  PWM_config = PWM_config or {}

  -- Remove obsolete values from saved variables.
  for k in pairs(PWM_config) do
    if CONFIG_DEFAULTS[k] == nil then
      PWM_config[k] = nil
    end
  end

  -- Fill missing values. Use an explicit nil check so boolean false values from
  -- the saved variables are preserved and not treated as "missing".
  for k, v in pairs(CONFIG_DEFAULTS) do
    if PWM_config[k] == nil then
      PWM_config[k] = v
    end
  end

end)



-- Create a custom tooltip frame that we control
local customTooltip = CreateFrame("GameTooltip", "PWM_CustomTooltip", UIParent, "GameTooltipTemplate")
customTooltip:SetFrameStrata("TOOLTIP")
customTooltip:Hide()

local customTooltipHideTimer = nil
local customTooltipActive = false

local function ShowCustomTooltip(anchorFrame, title, text)
  if customTooltipHideTimer then
    customTooltipHideTimer:Cancel()
    customTooltipHideTimer = nil
  end

  customTooltip:SetOwner(anchorFrame, "ANCHOR_RIGHT")
  customTooltip:ClearLines()
  GameTooltip_SetTitle(customTooltip, title)
  GameTooltip_AddNormalLine(customTooltip, text)
  customTooltip:Show()
  customTooltipActive = true
end

-- Hide tooltip after a delay, so it closes simultaneously with the submenu.
local function HideCustomTooltipDelayed(delay)
  if customTooltipHideTimer then
    customTooltipHideTimer:Cancel()
  end
  customTooltipHideTimer = C_Timer.NewTimer(delay or 0.33, function()
    customTooltip:Hide()
    customTooltipActive = false
    customTooltipHideTimer = nil
  end)
end

-- Hide tooltip immediately if another submenu opens
local function HideCustomTooltipImmediately()
  if customTooltipHideTimer then
    customTooltipHideTimer:Cancel()
    customTooltipHideTimer = nil
  end
  customTooltipActive = false
  customTooltip:Hide()
end

-- Function to call in the OnEnter handler of each submenu button.
local function OnEnterSubmenuFunction(frame, desc, title, tooltipText)
  HideCustomTooltipImmediately()
  desc:ForceOpenSubmenu()
  ShowCustomTooltip(frame, title, tooltipText)
end



Addon.OpenOptionsMenu = function()

  MenuUtil.CreateContextMenu(UIParent, function(button, mainMenu)
    mainMenu:CreateTitle("Persistent World Map")
    mainMenu:CreateDivider()


    local submenu = mainMenu:CreateButton("Reset closed map")
    submenu:SetOnEnter(function(frame, desc)
      OnEnterSubmenuFunction(frame, desc, "Reset closed map", "How long the map should remember its zoom and position after closing. Set to 'Never' to always restore the last used map state.")
    end)
    submenu:SetOnLeave(function(frame)
      HideCustomTooltipDelayed(0.33)
    end)

    submenu:CreateTitle("Reset closed map")
    submenu:CreateRadio("Instantly",        function() return PWM_config.resetMapAfter ==     0 end, function() PWM_config.resetMapAfter =     0; return MenuResponse.Refresh end)
    submenu:CreateRadio("After 5 seconds",  function() return PWM_config.resetMapAfter ==     5 end, function() PWM_config.resetMapAfter =     5; return MenuResponse.Refresh end)
    submenu:CreateRadio("After 15 seconds", function() return PWM_config.resetMapAfter ==    15 end, function() PWM_config.resetMapAfter =    15; return MenuResponse.Refresh end)
    submenu:CreateRadio("After 30 seconds", function() return PWM_config.resetMapAfter ==    30 end, function() PWM_config.resetMapAfter =    30; return MenuResponse.Refresh end)
    submenu:CreateRadio("After 60 seconds", function() return PWM_config.resetMapAfter ==    60 end, function() PWM_config.resetMapAfter =    60; return MenuResponse.Refresh end)
    submenu:CreateRadio("Never",            function() return PWM_config.resetMapAfter == 86400 end, function() PWM_config.resetMapAfter = 86400; return MenuResponse.Refresh end)



    submenu = mainMenu:CreateButton("Auto-Center")
    submenu:SetOnEnter(function(frame, desc)
      OnEnterSubmenuFunction(frame, desc, "Auto-Center", "When enabled, the map automatically keeps your character centered while zoomed in. Activate by double-clicking the map or clicking the lock button.")
    end)
    submenu:SetOnLeave(function(frame)
      HideCustomTooltipDelayed(0.33)
    end)

    submenu:CreateTitle("Auto-Center")
    submenu:CreateCheckbox(
      "Enabled",
      function()
        return PWM_config.autoCenterEnabled
      end,
      function()
        PWM_config.autoCenterEnabled = not PWM_config.autoCenterEnabled
        Addon.UpdateAutoCenterLockButton()
      end
    )


    local subsubmenu = submenu:CreateButton("Double-click sensitivity")
    subsubmenu:SetEnabled(function() return PWM_config.autoCenterEnabled end) -- Disable (grey out) this submenu when auto-centering is disabled.
    subsubmenu:SetOnEnter(function(frame, desc)
      local tooltipText = PWM_config.autoCenterEnabled and "Adjust sensitivity for double-click auto-center" or "Enable Auto-Center to change double-click sensitivity"
      OnEnterSubmenuFunction(frame, desc, "Double-click sensitivity", tooltipText)
    end)
    subsubmenu:SetOnLeave(function(frame)
      HideCustomTooltipDelayed(0.33)
    end)

    subsubmenu:CreateRadio("Slow",   function() return PWM_config.doubleClickTime == 0.5  end, function() PWM_config.doubleClickTime = 0.5;  return MenuResponse.Refresh end)
    subsubmenu:CreateRadio("Medium", function() return PWM_config.doubleClickTime == 0.25 end, function() PWM_config.doubleClickTime = 0.25; return MenuResponse.Refresh end)
    subsubmenu:CreateRadio("Fast",   function() return PWM_config.doubleClickTime == 0.2  end, function() PWM_config.doubleClickTime = 0.2;  return MenuResponse.Refresh end)



    submenu = mainMenu:CreateButton("Smooth zoom")
    submenu:SetOnEnter(function(frame, desc)
      OnEnterSubmenuFunction(frame, desc, "Smooth zoom", "Controls the animation speed when zooming in or out with the mouse wheel. Set to 'Disabled' for instant zoom without animation.")
    end)
    submenu:SetOnLeave(function(frame)
      HideCustomTooltipDelayed(0.33)
    end)

    submenu:CreateTitle("Smooth zoom")
    submenu:CreateRadio("Slow",     function() return PWM_config.zoomTimeSeconds == 0.6  end, function() PWM_config.zoomTimeSeconds = 0.6;  return MenuResponse.Refresh end)
    submenu:CreateRadio("Medium",   function() return PWM_config.zoomTimeSeconds == 0.3  end, function() PWM_config.zoomTimeSeconds = 0.3;  return MenuResponse.Refresh end)
    submenu:CreateRadio("Fast",     function() return PWM_config.zoomTimeSeconds == 0.15 end, function() PWM_config.zoomTimeSeconds = 0.15; return MenuResponse.Refresh end)
    submenu:CreateRadio("Disabled", function() return PWM_config.zoomTimeSeconds == 0    end, function() PWM_config.zoomTimeSeconds = 0;    return MenuResponse.Refresh end)

  end)
end
