-- ===================================================================
-- FILE: AI_Manager.lua (with Chunking for large data)
-- ===================================================================
local addonName, addonTable = ...;

local pages = {};
local menuButtons = {};
local selectedButton = nil;
local isInitialized = false;
local currentConfig = {};
local messageQueue = {};

-- C++ Default values for the new Restore Defaults feature
local defaultSettings = {
    Format = {
        system_prompt = "You are a helpful AI assistant roleplaying as a character in the World of Warcraft.\nFollow these rules strictly:\n1. Always stay in character.\n2. Do not use newline characters in your response.\n3. Keep your responses to a single, concise paragraph.\n4. Never speak for the player.",
        system_tag = "{{{SYSTEM}}}",
        user_tag = "{{{INPUT}}}",
        assistant_tag = "{{{OUTPUT}}}",
    },
    Samplers = {
        max_context_length = 8192,
        max_length = 128,
        temperature = 0.8,
        repetition_penalty = 1.1,
        top_p = 0.9,
        top_k = 40,
    }
}

-- ===================================================================
-- OnUpdate Frame for Safe Message Processing
-- ===================================================================
local updateFrame = CreateFrame("Frame", "AIManagerUpdateFrame")
updateFrame:SetScript("OnUpdate", function(self, elapsed)
    if #messageQueue > 0 then
        local msg = table.remove(messageQueue, 1);
        -- Extract the command and content safely
        local command, content = string.match(msg, "%[AIMgr_([A-Z]+)%](.+)");
        if command == "STATUS" then
            local _, _, statusValue = string.find(content, "status=(.+)");
            if statusValue then AIManager_ParseStatus(statusValue) end
        elseif command == "CONFIG" then
            AIManager_ParseConfig(content)
        end
    end
end)

-- ===================================================================
-- Main Addon Functions
-- ===================================================================
function AIManager_OnLoad(self)
    self:RegisterForDrag("LeftButton");
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", AIManager_ChatFilter);

    -- Link sliders to their edit boxes
    AIManager_LinkSliderToEditBox(AIManagerContextSizeSlider, AIManagerContextSizeBox, "%d");
    AIManager_LinkSliderToEditBox(AIManagerMaxLengthSlider, AIManagerMaxLengthBox, "%d");
    AIManager_LinkSliderToEditBox(AIManagerTempSlider, AIManagerTempBox, "%.2f");
    AIManager_LinkSliderToEditBox(AIManagerRepPenSlider, AIManagerRepPenBox, "%.2f");
    AIManager_LinkSliderToEditBox(AIManagerTopPSlider, AIManagerTopPBox, "%.2f");
    AIManager_LinkSliderToEditBox(AIManagerTopKSlider, AIManagerTopKBox, "%d");

    print("|cff3399ffAI Manager:|r AddOn Loaded.");
end

function AIManager_OnShow()
    if not isInitialized then
        pages["Network"] = AIManagerNetworkPage;
        pages["Format"] = AIManagerFormatPage;
        pages["Samplers"] = AIManagerSamplersPage;
        pages["Characters"] = AIManagerCharactersPage;

        menuButtons = { AIManagerMenuButton1, AIManagerMenuButton2, AIManagerMenuButton3, AIManagerMenuButton4 };

        AIManagerMenuButton1.pageName = "Network";
        AIManagerMenuButton2.pageName = "Format";
        AIManagerMenuButton3.pageName = "Samplers";
        AIManagerMenuButton4.pageName = "Characters";
        
        isInitialized = true;
    end

    AIManager_RequestConfig();
    AIManager_ShowPage("Network");
    AIManager_HighlightButton(AIManagerMenuButton1);
end

function AIManager_OnHide()
    -- Optional: Add any cleanup logic needed when the window is hidden
end

SLASH_AIMANAGER1 = "/aimanager";
SLASH_AIMANAGER2 = "/aim";
function SlashCmdList.AIMANAGER(msg, editbox)
    if AIManagerFrame:IsShown() then AIManagerFrame:Hide() else AIManagerFrame:Show() end
end

function AIManager_MenuButton_OnClick(button)
    if button.pageName then
        AIManager_ShowPage(button.pageName);
        AIManager_HighlightButton(button);
    end
end

function AIManager_ShowPage(pageName)
    for name, frame in pairs(pages) do frame:Hide() end
    if pages[pageName] then
        pages[pageName]:Show();
        if pageName == "Characters" then
            AIManager_UpdatePlayerCard();
        end
    end
end

function AIManager_HighlightButton(buttonToHighlight)
    for i, button in ipairs(menuButtons) do
        local text = button:GetFontString();
        if text then
            if button == buttonToHighlight then
                text:SetTextColor(1.0, 1.0, 1.0); -- White
            else
                text:SetTextColor(1.0, 0.82, 0.0); -- Yellow
            end
        end
    end
    selectedButton = buttonToHighlight;
end

-- ===================================================================
-- Data Handling and Communication
-- ===================================================================
function AIManager_RequestConfig()
    SendAddonMessage("AIMGR", "GET_CONFIG", "GUILD");
end

function AIManager_SaveChanges()
    local dataString = "";
    
    -- This function now saves settings for whichever page is currently visible
    if AIManagerFormatPage:IsShown() or AIManagerSamplersPage:IsShown() or AIManagerNetworkPage:IsShown() then
        dataString = "host=" .. AIManagerNetworkIPBox:GetText() .. ";" ..
                     "port=" .. AIManagerNetworkPortBox:GetText() .. ";" ..
                     "max_context_length=" .. AIManagerContextSizeBox:GetText() .. ";" ..
                     "max_length=" .. AIManagerMaxLengthBox:GetText() .. ";" ..
                     "temperature=" .. AIManagerTempBox:GetText() .. ";" ..
                     "repetition_penalty=" .. AIManagerRepPenBox:GetText() .. ";" ..
                     "top_p=" .. AIManagerTopPBox:GetText() .. ";" ..
                     "top_k=" .. AIManagerTopKBox:GetText() .. ";";
        
        local prompt = AIManagerSysPromptBox:GetText();
        prompt = string.gsub(prompt, "\n", "##NL##");
        dataString = dataString .. "system_prompt=" .. prompt .. ";" ..
                     "system_tag=" .. AIManagerSystemTagBox:GetText() .. ";" ..
                     "user_tag=" .. AIManagerUserTagBox:GetText() .. ";" ..
                     "assistant_tag=" .. AIManagerAssistantTagBox:GetText() .. ";";

        local chunkSize = 200;
        SendAddonMessage("AIMGR", "SAVE_CONFIG_START", "GUILD");
        for i = 1, math.ceil(string.len(dataString) / chunkSize) do
            local chunk = string.sub(dataString, (i - 1) * chunkSize + 1, i * chunkSize);
            SendAddonMessage("AIMGR", "SAVE_CONFIG_CHUNK " .. chunk, "GUILD");
        end
        SendAddonMessage("AIMGR", "SAVE_CONFIG_END", "GUILD");

    elseif AIManagerCharactersPage:IsShown() then
        local playerName = AIManagerPlayerNameBox:GetText();
        local playerCard = AIManagerPlayerDescBox:GetText();
        
        playerCard = string.gsub(playerCard, "\n", "##NL##");
        playerCard = string.gsub(playerCard, ";", "##SC##");
        playerCard = string.gsub(playerCard, "=", "##EQ##");
        
        local payload = playerName .. ";" .. playerCard;
        SendAddonMessage("AIMGR", "SAVE_PLAYER_CARD " .. payload, "GUILD");
    end
end

function AIManager_ChatFilter(self, event, msg, ...)
    if string.find(msg, "[AIMgr_STATUS]", 1, true) or string.find(msg, "[AIMgr_CONFIG]", 1, true) then
        table.insert(messageQueue, msg);
        return true;
    end
    return false;
end

function AIManager_ParseStatus(statusStr)
    local isConnected = (statusStr == "true");
    AIManager_SetConnectionStatus(isConnected);
end

function AIManager_ParseConfig(configStr)
    currentConfig = { playerCards = {} }; -- Fully reset the config table

    local remaining_str = configStr
    while string.len(remaining_str) > 0 do
        local end_pos = string.find(remaining_str, ";", 1, true)
        if not end_pos then break end -- No more pairs

        local pair_str = string.sub(remaining_str, 1, end_pos - 1)
        remaining_str = string.sub(remaining_str, end_pos + 1)

        local eq_pos = string.find(pair_str, "=", 1, true)
        if eq_pos then
            local key = string.sub(pair_str, 1, eq_pos - 1)
            local value = string.sub(pair_str, eq_pos + 1)

            -- Process key-value pair
            if key == "port" or key == "max_context_length" or key == "max_length" or key == "top_k" then
                currentConfig[key] = tonumber(value);
            elseif key == "temperature" or key == "repetition_penalty" or key == "top_p" then
                currentConfig[key] = tonumber(value);
            elseif key == "system_prompt" then
                value = string.gsub(value, "##NL##", "\n");
                currentConfig[key] = value;
            elseif key == "player_cards" then
                if value and value ~= "" then
                    local temp_value = value
                    while true do
                        local pc_pos = string.find(temp_value, "##PC##", 1, true)
                        local card_str_part
                        if pc_pos then
                            card_str_part = string.sub(temp_value, 1, pc_pos - 1)
                            temp_value = string.sub(temp_value, pc_pos + #("##PC##"))
                        else
                            card_str_part = temp_value
                            temp_value = ""
                        end

                        local inner_eq_pos = string.find(card_str_part, "##EQ##", 1, true)
                        if inner_eq_pos then
                            local name = string.sub(card_str_part, 1, inner_eq_pos - 1)
                            local card = string.sub(card_str_part, inner_eq_pos + #("##EQ##"))
                            
                            card = string.gsub(card, "##NL##", "\n");
                            card = string.gsub(card, "##SC##", ";");
                            card = string.gsub(card, "##EQ##", "=");
                            currentConfig.playerCards[name] = card;
                        end
                        
                        if temp_value == "" then break end
                    end
                end
            else
                currentConfig[key] = value;
            end
        end
    end
    
    AIManager_PopulateUI();
end


function AIManager_PopulateUI()
    -- Network Page
    if currentConfig.host then AIManagerNetworkIPBox:SetText(currentConfig.host) end
    if currentConfig.port then AIManagerNetworkPortBox:SetText(currentConfig.port) end

    -- Samplers Page
    if currentConfig.max_context_length then 
        AIManagerContextSizeSlider:SetValue(currentConfig.max_context_length);
        AIManagerContextSizeBox:SetText(currentConfig.max_context_length);
    end
    if currentConfig.max_length then 
        AIManagerMaxLengthSlider:SetValue(currentConfig.max_length);
        AIManagerMaxLengthBox:SetText(currentConfig.max_length);
    end
    if currentConfig.temperature then 
        AIManagerTempSlider:SetValue(currentConfig.temperature);
        AIManagerTempBox:SetText(string.format("%.2f", currentConfig.temperature));
    end
    if currentConfig.repetition_penalty then 
        AIManagerRepPenSlider:SetValue(currentConfig.repetition_penalty);
        AIManagerRepPenBox:SetText(string.format("%.2f", currentConfig.repetition_penalty));
    end
    if currentConfig.top_p then 
        AIManagerTopPSlider:SetValue(currentConfig.top_p);
        AIManagerTopPBox:SetText(string.format("%.2f", currentConfig.top_p));
    end
    if currentConfig.top_k then 
        AIManagerTopKSlider:SetValue(currentConfig.top_k);
        AIManagerTopKBox:SetText(currentConfig.top_k);
    end

    -- Format Page
    if currentConfig.system_prompt then AIManagerSysPromptBox:SetText(currentConfig.system_prompt) end
    if currentConfig.system_tag then AIManagerSystemTagBox:SetText(currentConfig.system_tag) end
    if currentConfig.user_tag then AIManagerUserTagBox:SetText(currentConfig.user_tag) end
    if currentConfig.assistant_tag then AIManagerAssistantTagBox:SetText(currentConfig.assistant_tag) end

    -- Characters Page (this will be populated when the page is shown)
    AIManager_UpdatePlayerCard();
end

function AIManager_UpdatePlayerCard()
    -- Set Player Portrait for the current player
    SetPortraitTexture(AIManagerPlayerPortraitTexture, "player");
    
    local playerName = UnitName("player");
    AIManagerPlayerNameBox:SetText(playerName);
    
    -- Find the current player's card and populate the description
    if currentConfig.playerCards and currentConfig.playerCards[playerName] then
        AIManagerPlayerDescBox:SetText(currentConfig.playerCards[playerName]);
    else
        AIManagerPlayerDescBox:SetText(""); -- Clear description if no card exists
    end
end

function AIManager_SetConnectionStatus(isConnected)
    AIManagerStatusIndicator:Show();
    if isConnected then
        AIManagerStatusIndicatorCircle:SetVertexColor(0.1, 0.9, 0.1); -- Green
        AIManagerStatusIndicatorText:SetText("Connected");
    else
        AIManagerStatusIndicatorCircle:SetVertexColor(0.9, 0.1, 0.1); -- Red
        AIManagerStatusIndicatorText:SetText("No Connection");
    end
end

-- Helper function to sync a slider and an editbox
function AIManager_LinkSliderToEditBox(slider, editbox, format)
    slider:SetScript("OnValueChanged", function(self, value)
        editbox:SetText(string.format(format, value));
    end)
    editbox:SetScript("OnEnterPressed", function(self)
        local value = tonumber(self:GetText());
        if value then
            slider:SetValue(value);
        end
        self:ClearFocus();
    end)
end

-- ===================================================================
-- Restore Defaults Feature
-- ===================================================================
StaticPopupDialogs["AIMANAGER_RESTORE_DEFAULTS"] = {
    text = "Are you sure you want to restore the default settings for this page? This action cannot be undone.",
    button1 = "Accept",
    button2 = "Cancel",
    OnAccept = function(self, data)
        AIManager_RestoreDefaults(data);
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    preferredIndex = 3,
};

function AIManager_ShowRestoreDefaultsConfirmation(pageName)
    StaticPopup_Show("AIMANAGER_RESTORE_DEFAULTS", nil, nil, pageName);
end

function AIManager_RestoreDefaults(pageName)
    if pageName == "Format" then
        local defaults = defaultSettings.Format;
        AIManagerSysPromptBox:SetText(defaults.system_prompt);
        AIManagerSystemTagBox:SetText(defaults.system_tag);
        AIManagerUserTagBox:SetText(defaults.user_tag);
        AIManagerAssistantTagBox:SetText(defaults.assistant_tag);
    elseif pageName == "Samplers" then
        local defaults = defaultSettings.Samplers;
        AIManagerContextSizeSlider:SetValue(defaults.max_context_length);
        AIManagerContextSizeBox:SetText(defaults.max_context_length);
        AIManagerMaxLengthSlider:SetValue(defaults.max_length);
        AIManagerMaxLengthBox:SetText(defaults.max_length);
        AIManagerTempSlider:SetValue(defaults.temperature);
        AIManagerTempBox:SetText(string.format("%.2f", defaults.temperature));
        AIManagerRepPenSlider:SetValue(defaults.repetition_penalty);
        AIManagerRepPenBox:SetText(string.format("%.2f", defaults.repetition_penalty));
        AIManagerTopPSlider:SetValue(defaults.top_p);
        AIManagerTopPBox:SetText(string.format("%.2f", defaults.top_p));
        AIManagerTopKSlider:SetValue(defaults.top_k);
        AIManagerTopKBox:SetText(defaults.top_k);
    end
    -- BUGFIX: Immediately save the changes after restoring them in the UI.
    AIManager_SaveChanges();
end
