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

-- First saved loadout for this spec whose name matches a keyword
local function FindMatchingLoadout(specID, keywords)
    for _, configID in ipairs(C_ClassTalents.GetConfigIDsBySpecID(specID) or {}) do
        local info = C_Traits.GetConfigInfo(configID)
        if info and info.name and NameMatches(info.name, keywords) then
            return configID, info.name
        end
    end
end

---------------------------------------------------------------------------
-- Switching
---------------------------------------------------------------------------

local pendingSwitchName

local function SwitchToLoadout(configID, specID)
    if InCombatLockdown() then
        Print("Can't change talents in combat.")
        return
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
end

local POPUP_DEFAULTS = {
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- No matching loadout saved: can only tell the player what to look for
StaticPopupDialogs["LOADOUTCHECKER_MISMATCH"] = CreateFromMixins(POPUP_DEFAULTS, {
    text = "|cFFFF0000Loadout Mismatch!|r\nYou are on '%s'.\nPlease switch to a '%s' loadout.",
    button1 = "Close",
    OnAccept = StopGlow,
    OnCancel = StopGlow,
})

-- A matching loadout exists: offer to switch to it
StaticPopupDialogs["LOADOUTCHECKER_SWITCH"] = CreateFromMixins(POPUP_DEFAULTS, {
    text = "|cFFFF0000Loadout Mismatch!|r\nYou are on '%s'.\nSwitch to '%s'?",
    button1 = "Switch",
    button2 = "Ignore",
    OnAccept = function(_, data)
        StopGlow()
        SwitchToLoadout(data.configID, data.specID)
    end,
    OnCancel = StopGlow,
})

local function HidePopups()
    StaticPopup_Hide("LOADOUTCHECKER_MISMATCH")
    StaticPopup_Hide("LOADOUTCHECKER_SWITCH")
end

local function ValidateLoadout()
    local rule = db.content[GetContentType()]
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
    local matchID, matchName = FindMatchingLoadout(specID, keywords)

    if db.playSound then PlaySound(8959) end
    if db.showPopup then
        HidePopups()
        if matchID then
            StaticPopup_Show("LOADOUTCHECKER_SWITCH", currentName, matchName, { configID = matchID, specID = specID })
        else
            StaticPopup_Show("LOADOUTCHECKER_MISMATCH", currentName, wanted)
        end
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
