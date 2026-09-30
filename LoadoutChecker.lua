local ADDON_NAME = ...

-- Content types, in the order they appear in the settings panel
local CONTENT_TYPES = {
    { key = "mplus", label = "Dungeons / M+" },
    { key = "raid",  label = "Raids" },
    { key = "pvp",   label = "PvP (Arena & BGs)" },
    { key = "delve", label = "Delves & Scenarios" },
}

-- IsInInstance() type -> content type
local INSTANCE_TO_CONTENT = {
    party    = "mplus",
    raid     = "raid",
    pvp      = "pvp",
    arena    = "pvp",
    scenario = "delve",
}

local DEFAULTS = {
    playSound      = true,
    showPopup      = true,
    showGlow       = true,
    chatOnMismatch = true,
    chatOnValid    = false,
    content = {
        mplus = { enabled = true, keywords = "m+" },
        raid  = { enabled = true, keywords = "raid" },
        pvp   = { enabled = true, keywords = "pvp" },
        delve = { enabled = true, keywords = "delve" },
    },
}

local db

local function ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            ApplyDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
end

local function Print(msg)
    print("|cFF33CCFF[Loadout Checker]:|r " .. msg)
end

---------------------------------------------------------------------------
-- Glow
---------------------------------------------------------------------------

local glowFrame

local function StopGlow()
    if glowFrame then
        UIFrameFlashStop(glowFrame)
        glowFrame:Hide()
    end
end

local function GetMicroBar()
    return MicroMenu or MicroMenuContainer or (StatusTrackingBarManager and StatusTrackingBarManager.MainBar) or (CharacterMicroButton and CharacterMicroButton:GetParent())
end

local function TriggerGlow()
    local target = GetMicroBar()
    if not target then return end

    if not glowFrame then
        glowFrame = CreateFrame("Frame", nil, target)
        glowFrame:SetFrameStrata("TOOLTIP")
        local tex = glowFrame:CreateTexture(nil, "OVERLAY")
        tex:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        tex:SetBlendMode("ADD")
        tex:SetAllPoints(glowFrame)
    end

    glowFrame:SetParent(target)
    glowFrame:SetAllPoints(target)
    glowFrame:Show()
    UIFrameFlash(glowFrame, 0.5, 0.5, -1, true, 0, 0)
end

---------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------

local function GetContentType()
    local inInstance, instanceType = IsInInstance()
    if inInstance and INSTANCE_TO_CONTENT[instanceType] then
        return INSTANCE_TO_CONTENT[instanceType]
    end
    -- Not inside an instance (e.g. forming up in a city): guess from group type
    if IsInRaid() then return "raid" end
    return "mplus"
end

-- Returns the active loadout name and specID, or nil if talents aren't available yet
local function GetCurrentLoadout()
    local specIndex = GetSpecialization()
    if not specIndex then return nil end
    local specID = GetSpecializationInfo(specIndex)
    if not specID then return nil end

    if C_ClassTalents.GetStarterBuildActive and C_ClassTalents.GetStarterBuildActive() then
        return "Starter Build", specID
    end

    local configID = C_ClassTalents.GetLastSelectedSavedConfigID(specID)
    local info = configID and C_Traits.GetConfigInfo(configID)
    return info and info.name or "(unsaved loadout)", specID
end

local function ParseKeywords(str)
    local list = {}
    for word in (str or ""):gmatch("[^,]+") do
        word = strtrim(word):lower()
        if word ~= "" then table.insert(list, word) end
    end
    return list
end

local function NameMatches(name, keywords)
    local lower = name:lower()
    for _, word in ipairs(keywords) do
        if lower:find(word, 1, true) then return true end
    end
    return false
end

-- Saved loadouts for this spec whose names match a keyword, in Blizzard's order
local function FindMatchingLoadouts(specID, keywords)
    local matches = {}
    for _, configID in ipairs(C_ClassTalents.GetConfigIDsBySpecID(specID) or {}) do
        local info = C_Traits.GetConfigInfo(configID)
        if info and info.name and NameMatches(info.name, keywords) then
            table.insert(matches, { configID = configID, name = info.name })
        end
    end
    return matches
end

---------------------------------------------------------------------------
-- Switching
---------------------------------------------------------------------------

local pendingSwitchName

-- Returns true if the switch was started
local function SwitchToLoadout(configID, specID)
    if InCombatLockdown() then
        Print("Can't change talents in combat.")
        return false
    end

    local info = C_Traits.GetConfigInfo(configID)
    pendingSwitchName = info and info.name

    -- Load through Blizzard's talent UI (same approach as ElvUI) so its loadout
    -- dropdown stays in sync. Calling C_ClassTalents.LoadConfig directly swaps
    -- the talents but leaves the dropdown showing the old loadout name.
    if not PlayerSpellsFrame and PlayerSpellsFrame_LoadUI then
        PlayerSpellsFrame_LoadUI()
    end
    local talentsFrame = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
    if talentsFrame and talentsFrame.LoadConfigByPredicate then
        talentsFrame:LoadConfigByPredicate(function(_, id) return id == configID end)
    else
        C_ClassTalents.LoadConfig(configID, true)
        C_ClassTalents.UpdateLastSelectedSavedConfigID(specID, configID)
    end
    return true
end

---------------------------------------------------------------------------
-- Mismatch popup (one button per matching loadout)
---------------------------------------------------------------------------

local POPUP_WIDTH = 300
local PADDING = 16
local ICON_SIZE = 32
local BUTTON_HEIGHT = 28
local BUTTON_SPACING = 6
local WHITE = "Interface\\Buttons\\WHITE8x8"
local ACCENT = { 1, 0.35, 0.2 }
local BUTTON_BG = { 1, 1, 1, 0.06 }
local BUTTON_BORDER = { 1, 1, 1, 0.15 }

local popup

local function ApplyFlatBackdrop(frame, bg, border)
    frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    frame:SetBackdropColor(unpack(bg))
    frame:SetBackdropBorderColor(unpack(border))
end

local function GetPlayerClassColor()
    local _, class = UnitClass("player")
    local color = (C_ClassColor and C_ClassColor.GetClassColor(class)) or RAID_CLASS_COLORS[class]
    if color then return color.r, color.g, color.b end
    return 1, 0.82, 0
end

-- Flat button that lights up in the player's class color on hover
local function CreateFlatButton(parent)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetHeight(BUTTON_HEIGHT)
    ApplyFlatBackdrop(button, BUTTON_BG, BUTTON_BORDER)

    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    button.label:SetPoint("LEFT", 10, 0)
    button.label:SetPoint("RIGHT", -10, 0)
    button.label:SetWordWrap(false)

    button:SetScript("OnEnter", function(self)
        local r, g, b = GetPlayerClassColor()
        self:SetBackdropColor(r, g, b, 0.25)
        self:SetBackdropBorderColor(r, g, b, 1)
    end)
    button:SetScript("OnLeave", function(self)
        self:SetBackdropColor(unpack(BUTTON_BG))
        self:SetBackdropBorderColor(unpack(BUTTON_BORDER))
    end)
    return button
end

local function OpenTalents()
    if PlayerSpellsUtil and PlayerSpellsUtil.OpenToClassTalentsTab then
        PlayerSpellsUtil.OpenToClassTalentsTab()
        return true
    end
    return false
end

local function GetPopup()
    if popup then return popup end

    popup = CreateFrame("Frame", "LoadoutCheckerPopup", UIParent, "BackdropTemplate")
    popup:SetWidth(POPUP_WIDTH)
    popup:SetPoint("TOP", 0, -135)
    popup:SetFrameStrata("DIALOG")
    popup:SetToplevel(true)
    popup:SetClampedToScreen(true)
    ApplyFlatBackdrop(popup, { 0.05, 0.05, 0.07, 0.95 }, { 0, 0, 0, 1 })

    -- Draggable, in case it covers something
    popup:EnableMouse(true)
    popup:SetMovable(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)

    local accent = popup:CreateTexture(nil, "ARTWORK")
    accent:SetColorTexture(unpack(ACCENT))
    accent:SetPoint("TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", -1, -1)
    accent:SetHeight(2)

    popup.icon = popup:CreateTexture(nil, "ARTWORK")
    popup.icon:SetSize(ICON_SIZE, ICON_SIZE)
    popup.icon:SetPoint("TOPLEFT", PADDING, -PADDING)
    popup.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    popup.title = popup:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    popup.title:SetPoint("TOPLEFT", popup.icon, "TOPRIGHT", 10, -1)
    popup.title:SetText("Loadout Mismatch")
    popup.title:SetTextColor(unpack(ACCENT))

    popup.subtitle = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    popup.subtitle:SetPoint("TOPLEFT", popup.title, "BOTTOMLEFT", 0, -4)
    popup.subtitle:SetWidth(POPUP_WIDTH - PADDING * 2 - ICON_SIZE - 10)
    popup.subtitle:SetJustifyH("LEFT")
    popup.subtitle:SetTextColor(0.75, 0.75, 0.75)

    local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -4)
    close:SetScript("OnClick", function() popup:Hide() end)

    popup.prompt = popup:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    popup.prompt:SetWidth(POPUP_WIDTH - PADDING * 2)
    popup.prompt:SetJustifyH("LEFT")
    popup.prompt:SetTextColor(0.6, 0.6, 0.6)

    popup.loadoutButtons = {}

    popup.talentsButton = CreateFlatButton(popup)
    popup.talentsButton.label:SetText("Open Talents")
    popup.talentsButton:SetScript("OnClick", function()
        popup:Hide()
        OpenTalents()
    end)

    -- Low-key text button, so the loadouts are the obvious choice
    popup.dismissButton = CreateFrame("Button", nil, popup)
    popup.dismissButton:SetSize(80, 20)
    popup.dismissButton.label = popup.dismissButton:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    popup.dismissButton.label:SetPoint("RIGHT")
    popup.dismissButton:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 1, 1) end)
    popup.dismissButton:SetScript("OnLeave", function(self) self.label:SetTextColor(0.5, 0.5, 0.5) end)
    popup.dismissButton:SetScript("OnClick", function() popup:Hide() end)

    popup.fadeIn = popup:CreateAnimationGroup()
    local fade = popup.fadeIn:CreateAnimation("Alpha")
    fade:SetFromAlpha(0)
    fade:SetToAlpha(1)
    fade:SetDuration(0.15)

    -- Escape closes it; closing it any way stops the glow
    table.insert(UISpecialFrames, "LoadoutCheckerPopup")
    popup:SetScript("OnHide", StopGlow)

    popup:Hide()
    return popup
end

local function ShowPopup(currentName, contentLabel, wanted, matches, specID)
    local p = GetPopup()

    local specIcon = select(4, GetSpecializationInfo(GetSpecialization() or 0))
    p.icon:SetTexture(specIcon or 134400) -- question mark icon fallback
    p.subtitle:SetFormattedText("Current loadout: |cFFFFFFFF%s|r", currentName)

    -- Header height depends on whether the subtitle wraps
    local headerHeight = math.max(ICON_SIZE, 1 + p.title:GetStringHeight() + 4 + p.subtitle:GetStringHeight())
    local y = -PADDING - headerHeight - 14

    if #matches > 0 then
        p.prompt:SetFormattedText("Pick a loadout for %s:", contentLabel)
    else
        p.prompt:SetFormattedText("None of your saved loadouts match %s ('%s'). Rename one or save a new one.", contentLabel, wanted)
    end
    p.prompt:ClearAllPoints()
    p.prompt:SetPoint("TOPLEFT", PADDING, y)
    y = y - p.prompt:GetStringHeight() - 8

    local function PlaceButton(button)
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", PADDING, y)
        button:SetPoint("TOPRIGHT", -PADDING, y)
        button:Show()
        y = y - BUTTON_HEIGHT - BUTTON_SPACING
    end

    for i, match in ipairs(matches) do
        local button = p.loadoutButtons[i]
        if not button then
            button = CreateFlatButton(p)
            p.loadoutButtons[i] = button
        end
        button.label:SetText(match.name)
        button:SetScript("OnClick", function()
            if SwitchToLoadout(match.configID, specID) then
                p:Hide()
            end
        end)
        PlaceButton(button)
    end
    for i = #matches + 1, #p.loadoutButtons do
        p.loadoutButtons[i]:Hide()
    end

    if #matches == 0 and PlayerSpellsUtil and PlayerSpellsUtil.OpenToClassTalentsTab then
        PlaceButton(p.talentsButton)
    else
        p.talentsButton:Hide()
    end

    p.dismissButton.label:SetText(#matches > 0 and "Not now" or "Close")
    p.dismissButton.label:SetTextColor(0.5, 0.5, 0.5)
    p.dismissButton:ClearAllPoints()
    p.dismissButton:SetPoint("TOPRIGHT", -PADDING, y - 2)
    y = y - 2 - p.dismissButton:GetHeight() - PADDING + 4

    p:SetHeight(-y)
    if not p:IsShown() then
        p:Show()
        p.fadeIn:Play()
    end
end

local function HidePopups()
    if popup then popup:Hide() end
end

local function GetContentLabel(key)
    for _, ct in ipairs(CONTENT_TYPES) do
        if ct.key == key then return ct.label end
    end
    return key
end

local function ValidateLoadout()
    local contentType = GetContentType()
    local rule = db.content[contentType]
    if not rule or not rule.enabled then return end

    local keywords = ParseKeywords(rule.keywords)
    if #keywords == 0 then return end

    local currentName, specID = GetCurrentLoadout()
    if not currentName then return end

    if NameMatches(currentName, keywords) then
        StopGlow()
        if db.chatOnValid then
            Print("|cFF00FF00Valid loadout:|r " .. currentName)
        end
        return
    end

    local wanted = table.concat(keywords, "' / '")

    if db.playSound then PlaySound(8959) end
    if db.showPopup then
        ShowPopup(currentName, GetContentLabel(contentType), wanted, FindMatchingLoadouts(specID, keywords), specID)
    end
    if db.showGlow then TriggerGlow() end
    if db.chatOnMismatch then
        Print("|cFFFF0000Mismatch!|r You are on '" .. currentName .. "', expected '" .. wanted .. "'.")
    end
end

---------------------------------------------------------------------------
-- Settings panel
---------------------------------------------------------------------------

local settingsCategory

local function CreateCheckbox(parent, label, tooltip, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    text:SetText(label)
    cb:SetScript("OnClick", function(self) set(self:GetChecked()) end)
    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label, 1, 1, 1)
            GameTooltip:AddLine(tooltip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", GameTooltip_Hide)
    end
    cb.Refresh = function(self) self:SetChecked(get()) end
    return cb
end

local function CreateKeywordBox(parent, get, set)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(240, 20)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self)
        self:SetText(get())
        self:ClearFocus()
    end)
    eb:SetScript("OnEditFocusLost", function(self) set(self:GetText()) end)
    eb.Refresh = function(self) self:SetText(get()) end
    return eb
end

local function BuildSettingsPanel()
    local panel = CreateFrame("Frame")
    local widgets = {}

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Loadout Checker")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("Warns you on ready check if your talent loadout doesn't match the content you're doing.")

    -- Alert options
    local alertHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    alertHeader:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -20)
    alertHeader:SetText("Alerts")

    local alertOptions = {
        { "playSound",      "Play sound",              "Play a warning sound on mismatch." },
        { "showPopup",      "Show popup",              "Show a popup dialog on mismatch." },
        { "showGlow",       "Flash the micro menu",    "Flash the micro menu bar until you close the popup, change talents or enter combat." },
        { "chatOnMismatch", "Chat message on mismatch", nil },
        { "chatOnValid",    "Chat message when valid", "Print a confirmation in chat when your loadout matches." },
    }

    local anchor = alertHeader
    for i, opt in ipairs(alertOptions) do
        local key = opt[1]
        local cb = CreateCheckbox(panel, opt[2], opt[3],
            function() return db[key] end,
            function(v) db[key] = v end)
        cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", i == 1 and -2 or 0, i == 1 and -6 or -2)
        table.insert(widgets, cb)
        anchor = cb
    end

    -- Keyword rules
    local rulesHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    rulesHeader:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 2, -20)
    rulesHeader:SetText("Loadout keywords")

    local rulesHint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    rulesHint:SetPoint("TOPLEFT", rulesHeader, "BOTTOMLEFT", 0, -6)
    rulesHint:SetText("Comma-separated. A loadout matches if its name contains any keyword (not case-sensitive).")

    anchor = rulesHint
    for i, ct in ipairs(CONTENT_TYPES) do
        local rule = function() return db.content[ct.key] end
        local cb = CreateCheckbox(panel, ct.label, "Check your loadout for this content.",
            function() return rule().enabled end,
            function(v) rule().enabled = v end)
        cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", i == 1 and -2 or 0, i == 1 and -8 or -4)

        local eb = CreateKeywordBox(panel,
            function() return rule().keywords end,
            function(v) rule().keywords = v end)
        eb:SetPoint("LEFT", cb, "LEFT", 190, 0)

        table.insert(widgets, cb)
        table.insert(widgets, eb)
        anchor = cb
    end

    local resetButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetButton:SetSize(140, 22)
    resetButton:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 2, -24)
    resetButton:SetText("Reset to defaults")
    resetButton:SetScript("OnClick", function()
        wipe(db)
        ApplyDefaults(db, DEFAULTS)
        for _, w in ipairs(widgets) do w:Refresh() end
    end)

    local testButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testButton:SetSize(140, 22)
    testButton:SetPoint("LEFT", resetButton, "RIGHT", 8, 0)
    testButton:SetText("Check now")
    testButton:SetScript("OnClick", ValidateLoadout)

    panel:SetScript("OnShow", function()
        for _, w in ipairs(widgets) do w:Refresh() end
    end)

    settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, "Loadout Checker")
    Settings.RegisterAddOnCategory(settingsCategory)
end

SLASH_LOADOUTCHECKER1 = "/loadoutchecker"
SLASH_LOADOUTCHECKER2 = "/lc"
SlashCmdList.LOADOUTCHECKER = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "check" then
        ValidateLoadout()
    elseif settingsCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("READY_CHECK")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("TRAIT_CONFIG_UPDATED") -- Fires when you actually change talents

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        LoadoutCheckerDB = LoadoutCheckerDB or {}
        db = LoadoutCheckerDB
        ApplyDefaults(db, DEFAULTS)
        BuildSettingsPanel()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "READY_CHECK" then
        C_Timer.After(0.6, ValidateLoadout)
    elseif event == "PLAYER_REGEN_DISABLED" then
        StopGlow()
    elseif event == "TRAIT_CONFIG_UPDATED" then
        -- Talents changed, so any open mismatch warning is out of date
        StopGlow()
        HidePopups()
        if pendingSwitchName then
            Print("|cFF00FF00Switched to|r " .. pendingSwitchName)
            pendingSwitchName = nil
        end
    end
end)
