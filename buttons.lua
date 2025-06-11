local folderName, Addon = ...

-- Locals for frequently used global frames and functions.
local GameTooltip_AddBlankLineToTooltip  = _G.GameTooltip_AddBlankLineToTooltip
local GameTooltip_AddErrorLine           = _G.GameTooltip_AddErrorLine
local GameTooltip_AddInstructionLine     = _G.GameTooltip_AddInstructionLine
local GameTooltip_AddNormalLine          = _G.GameTooltip_AddNormalLine
local GameTooltip_SetTitle               = _G.GameTooltip_SetTitle
local PlaySound                          = _G.PlaySound


-- ###############################
-- ### Setting up the buttons. ###
-- ###############################



local recenterButton = nil
local autoCenterLockButton = nil


local function RecenterButtonEnterFunction(button)
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  GameTooltip_SetTitle(GameTooltip, "Persistent World Map")
  GameTooltip_AddNormalLine(GameTooltip, "Restores the map to its previous state when closing and reopenning it.")
  GameTooltip_AddNormalLine(GameTooltip, "Automatically switches to the map of a newly entered zone.")
  GameTooltip_AddBlankLineToTooltip(GameTooltip)
  GameTooltip_AddInstructionLine(GameTooltip, "Click here to show the map of the current zone or just shift-click on the map.")
  if not button:IsEnabled() then
    GameTooltip_AddErrorLine(GameTooltip, "Already showing the map of the current zone.")
  end
  GameTooltip:Show()
end


-- Needs to be called by CheckMap().
Addon.RecenterButtonSetEnabled = function(enable)
  if not recenterButton then return end

  if enable then
    if recenterButton:IsEnabled() then return end
    recenterButton.centerDot.t:SetVertexColor(0, 0, 0, 1)
  else
    if not recenterButton:IsEnabled() then return end
    recenterButton.centerDot.t:SetVertexColor(1, 0.9, 0, 1)
  end

  recenterButton:SetEnabled(enable)
  if GameTooltip:GetOwner() == recenterButton then
    RecenterButtonEnterFunction(recenterButton)
  end
end




local function AutoCenterLockButtonEnterFunction(button)
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  GameTooltip_SetTitle(GameTooltip, "Lock map to player")
  GameTooltip_AddNormalLine(GameTooltip, "Automatically keep the player pin closest to the center of the map when the map is zoomed in. (Not possible in dungeons, raids, battlegrounds and arenas.)")
  GameTooltip_AddBlankLineToTooltip(GameTooltip)
  if button:IsEnabled() then
    if Addon.autoCentering then
      GameTooltip_AddInstructionLine(GameTooltip, "Click here to turn OFF\nor just drag the map.")
    else
      GameTooltip_AddInstructionLine(GameTooltip, "Click here to turn ON\nor just double-click on the map.")
    end
  else
    GameTooltip_AddErrorLine(GameTooltip, "Not possible in this zone.")
  end
  GameTooltip:Show()
end


-- Needs to be called by EnableCenterOnPlayer() and DisableCenterOnPlayer().
Addon.UpdateAutoCenterLockButton = function()
  if not autoCenterLockButton then return end
  autoCenterLockButton:GetNormalTexture():SetDesaturated(not Addon.autoCentering)
  if GameTooltip:GetOwner() == autoCenterLockButton then
    AutoCenterLockButtonEnterFunction(autoCenterLockButton)
  end
end

-- Needs to be called by CheckMap().
Addon.AutoCenterLockButtonSetEnabled = function(enable)
  if enable then
    if not autoCenterLockButton:IsEnabled() then
      autoCenterLockButton:SetEnabled(true)
    end
  else
    if autoCenterLockButton:IsEnabled() then
      autoCenterLockButton:SetEnabled(false)
    end
  end
  if GameTooltip:GetOwner() == autoCenterLockButton then
    AutoCenterLockButtonEnterFunction(autoCenterLockButton)
  end
end




-- Got to create a global button mixin to refer in my RecenterButtonTemplate, so it works with Krowi_WorldMapButtons.
PersistentWorldMapRecenterButtonMixin = {}

function PersistentWorldMapRecenterButtonMixin:OnClick()
  PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
  Addon.ResetMap()
  Addon.RecenterButtonSetEnabled(false)
end

function PersistentWorldMapRecenterButtonMixin:OnEnter()
  RecenterButtonEnterFunction(self)
end

function PersistentWorldMapRecenterButtonMixin:OnLeave()
  GameTooltip:Hide()
end

-- Function expected to exist by Krowi_WorldMapButtons.
function PersistentWorldMapRecenterButtonMixin:Refresh() end



-- Call on startup.
local function CreateMapButtons()

  -- #####################################################
  -- ### Persistent World Mape ("Recenter Map") button ###
  -- #####################################################
  
  -- Template in RecenterButtonTemplate.xml copied from WorldMapTrackingPinButtonTemplate
  -- in Blizzard's \Interface\AddOns\Blizzard_WorldMap\Blizzard_WorldMapTemplates.xml
  recenterButton = LibStub("Krowi_WorldMapButtons-1.4"):Add("RecenterButtonTemplate", "BUTTON")

  recenterButton.Icon:SetAtlas("TargetCrosshairs")
  recenterButton.Icon:SetTexCoord(0.1, 0.5, 0.1, 0.5)

  recenterButton.centerDot = CreateFrame("Frame", nil, recenterButton)
  local t = recenterButton.centerDot:CreateTexture(nil, "OVERLAY")
  t:SetTexture("Interface\\AddOns\\PersistentWorldMap\\dot.tga")
  t:SetPoint("CENTER", recenterButton, "CENTER", 0.3, 0.5)
  t:SetSize(10, 10)
  recenterButton.centerDot.t = t

  Addon.RecenterButtonSetEnabled(false)




  -- ###################################
  -- ### "Lock map to player" button ###
  -- ###################################

  autoCenterLockButton = CreateFrame("Button", nil, recenterButton)

  autoCenterLockButton:SetSize(18, 21)
  autoCenterLockButton:SetPoint("CENTER", recenterButton, "BOTTOMRIGHT", -4, 7)

  -- To get an OnEnter tooltip while disabled.
  autoCenterLockButton:SetMotionScriptsWhileDisabled(true)

  autoCenterLockButton:SetNormalAtlas("Monuments-Lock")
  autoCenterLockButton:SetPushedAtlas("Monuments-Lock")
  autoCenterLockButton:SetHighlightAtlas("bountiful-glow", "BLEND")

  if not Addon.autoCentering then
    autoCenterLockButton:GetNormalTexture():SetDesaturated(true)
  end

  -- Create the disabled overlay texture that will be layered on top.
  autoCenterLockButton.disabledTexture = autoCenterLockButton:CreateTexture(nil, "OVERLAY")
  autoCenterLockButton.disabledTexture:SetAtlas("talents-button-reset", "BLEND")
  autoCenterLockButton.disabledTexture:SetPoint("CENTER", autoCenterLockButton, "CENTER", 0, -3)
  autoCenterLockButton.disabledTexture:SetSize(16, 16)
  autoCenterLockButton.disabledTexture:SetAlpha(0.7)
  autoCenterLockButton.disabledTexture:Hide()

  -- Override the default disabled state.
  autoCenterLockButton:SetScript("OnDisable", function(self)
    self:GetNormalTexture():SetDesaturated(true)
    self.disabledTexture:Show()
    if GameTooltip:GetOwner() == self then
      AutoCenterLockButtonEnterFunction(self)
    end
  end)

  autoCenterLockButton:SetScript("OnEnable", function(self)
    self.disabledTexture:Hide()
    Addon.UpdateAutoCenterLockButton()
  end)

  -- Handle clicks
  autoCenterLockButton:SetScript("OnClick", function()
    if Addon.autoCentering then
      PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
      Addon.DisableCenterOnPlayer()
    else
      PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
      Addon.EnableCenterOnPlayer()
    end
  end)

  -- For tooltips.
  autoCenterLockButton:SetScript("OnEnter", function(self)
    AutoCenterLockButtonEnterFunction(self)
  end)
  autoCenterLockButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

end


local startupFrame = CreateFrame("Frame")
startupFrame:RegisterEvent("PLAYER_LOGIN")
startupFrame:SetScript("OnEvent", function()
  CreateMapButtons()
end)