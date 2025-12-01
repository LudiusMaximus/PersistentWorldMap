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

local function HideCustomTooltipDelayed(delay)
  if customTooltipHideTimer then
    customTooltipHideTimer:Cancel()
  end
  customTooltipActive = false
  customTooltipHideTimer = C_Timer.After(delay or 0.33, function()
    customTooltip:Hide()
    customTooltipHideTimer = nil
  end)
end

local function HideCustomTooltipImmediately()
  -- Hide tooltip immediately if another submenu opens
  if customTooltipHideTimer then
    customTooltipHideTimer:Cancel()
    customTooltipHideTimer = nil
  end
  customTooltipActive = false
  customTooltip:Hide()
end

-- Hook into the Menu system to detect when submenus open so we can hide our tooltip immediately
-- (Handled in each submenu's OnEnter handler above)





Addon.OpenOptionsMenu = function()
  
    MenuUtil.CreateContextMenu(UIParent, function(button, mainMenu)
      mainMenu:CreateTitle("Persistent World Map")
      mainMenu:CreateDivider()



      local submenu = mainMenu:CreateButton("Reset closed map")
      submenu:SetOnEnter(function(_, desc) 
        HideCustomTooltipImmediately()
        desc:ForceOpenSubmenu() 
      end) -- Open instantly on hover (no delay, like tooltips).

      submenu:CreateTitle("Reset closed map")
      submenu:CreateRadio("Instantly",        function() return PWM_config.resetMapAfter ==     0 end, function() PWM_config.resetMapAfter =     0; return MenuResponse.Refresh end)
      submenu:CreateRadio("After 5 seconds",  function() return PWM_config.resetMapAfter ==     5 end, function() PWM_config.resetMapAfter =     5; return MenuResponse.Refresh end)
      submenu:CreateRadio("After 15 seconds", function() return PWM_config.resetMapAfter ==    15 end, function() PWM_config.resetMapAfter =    15; return MenuResponse.Refresh end)
      submenu:CreateRadio("After 30 seconds", function() return PWM_config.resetMapAfter ==    30 end, function() PWM_config.resetMapAfter =    30; return MenuResponse.Refresh end)
      submenu:CreateRadio("After 60 seconds", function() return PWM_config.resetMapAfter ==    60 end, function() PWM_config.resetMapAfter =    60; return MenuResponse.Refresh end)
      submenu:CreateRadio("Never",            function() return PWM_config.resetMapAfter == 86400 end, function() PWM_config.resetMapAfter = 86400; return MenuResponse.Refresh end)
      


      submenu = mainMenu:CreateButton("Auto-Center")
      submenu:SetOnEnter(function(_, desc) 
        HideCustomTooltipImmediately()
        desc:ForceOpenSubmenu() 
      end) -- Open instantly on hover (no delay, like tooltips).

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
        desc:ForceOpenSubmenu() -- Open instantly on hover
        local tooltipText = PWM_config.autoCenterEnabled and "Adjust sensitivity for double-click auto-center" or "Enable Auto-Center to change double-click sensitivity"
        ShowCustomTooltip(frame, "Double-click sensitivity", tooltipText)
      end)
      subsubmenu:SetOnLeave(function(frame)
        -- Delay hiding the tooltip so it disappears with the submenu (~0.33s)
        HideCustomTooltipDelayed(0.33)
      end)

      subsubmenu:CreateRadio("Slow",   function() return PWM_config.doubleClickTime == 0.5  end, function() PWM_config.doubleClickTime = 0.5;  return MenuResponse.Refresh end)
      subsubmenu:CreateRadio("Medium", function() return PWM_config.doubleClickTime == 0.25 end, function() PWM_config.doubleClickTime = 0.25; return MenuResponse.Refresh end)
      subsubmenu:CreateRadio("Fast",   function() return PWM_config.doubleClickTime == 0.2  end, function() PWM_config.doubleClickTime = 0.2;  return MenuResponse.Refresh end)
      


      submenu = mainMenu:CreateButton("Smooth zoom")
      submenu:SetOnEnter(function(_, desc) 
        HideCustomTooltipImmediately()
        desc:ForceOpenSubmenu() 
      end) -- Open instantly on hover (no delay, like tooltips).

      submenu:CreateTitle("Smooth zoom")
      submenu:CreateRadio("Slow",     function() return PWM_config.zoomTimeSeconds == 0.6  end, function() PWM_config.zoomTimeSeconds = 0.6;  return MenuResponse.Refresh end)
      submenu:CreateRadio("Medium",   function() return PWM_config.zoomTimeSeconds == 0.3  end, function() PWM_config.zoomTimeSeconds = 0.3;  return MenuResponse.Refresh end)
      submenu:CreateRadio("Fast",     function() return PWM_config.zoomTimeSeconds == 0.15 end, function() PWM_config.zoomTimeSeconds = 0.15; return MenuResponse.Refresh end)
      submenu:CreateRadio("Disabled", function() return PWM_config.zoomTimeSeconds == 0    end, function() PWM_config.zoomTimeSeconds = 0;    return MenuResponse.Refresh end)
      
  end)
end
