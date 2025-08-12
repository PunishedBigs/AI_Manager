-- ===================================================================
-- FILE: AI_Manager.lua (Hybrid Config Model)
-- ===================================================================
local addonName, addonTable = ...;

-- This table will be saved in the WTF folder by the WoW client.
AIManagerDB = nil; 

-- Default settings for first-time users or for resetting.
local defaults = {
    samplers = {
        max_context_length = 8192,
        max_length = 128,
        temperature = 0.8,
        repetition_penalty = 1.1,
        top_p = 0.9,
        top_k = 40,
    },
    format = {
        system_prompt = "You are a helpful AI assistant roleplaying as a character in the World of Warcraft.\nFollow these rules strictly:\n1. Always stay in character.\n2. Do not use newline characters in your response.\n3. Keep your responses to a single, concise paragraph.\n4. Never speak for the player.",
        system_tag = "{{{SYSTEM}}}",
        user_tag = "{{{INPUT}}}",
        assistant_tag = "{{{OUTPUT}}}",
    },
    player_card = {
        name = "",
        description = "",
    },
    -- Using an indexed table of character objects, each with a unique ID.
    character_cards = {}, 
    nextCharacterId = 1,
}

-- Conversation state (cleared on target change or reload)
local conversationHistory = {};
local currentTargetGUID = nil;
local messageQueue = {};
local isInitialized = false;
local characterCardFrames = {}; -- To keep track of dynamically created frames

-- ===================================================================
-- Initialization & Event Handling
-- ===================================================================
local frame = CreateFrame("Frame", "AIManagerEventHandler");
frame:RegisterEvent("ADDON_LOADED");
frame:RegisterEvent("PLAYER_LOGIN");
frame:RegisterEvent("PLAYER_TARGET_CHANGED");
frame:RegisterEvent("PLAYER_LOGOUT");

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" and ... == addonName then
        AIManagerDB = AIManagerDB or CopyTable(defaults);
        
        -- Data migration for users from older versions
        if not AIManagerDB.nextCharacterId then
            print("|cff3399ffAI Manager:|r Migrating old character data format...");
            local newCards = {}
            local idCounter = 1
            for name, desc in pairs(AIManagerDB.character_cards) do
                table.insert(newCards, { id = idCounter, name = name, description = desc })
                idCounter = idCounter + 1
            end
            AIManagerDB.character_cards = newCards
            AIManagerDB.nextCharacterId = idCounter
        end
        if not AIManagerDB.player_card then
            AIManagerDB.player_card = CopyTable(defaults.player_card);
            AIManagerDB.player_card.name = UnitName("player");
        end

        print("|cff3399ffAI Manager:|r AddOn Loaded. Use /aim to open.");
    
    elseif event == "PLAYER_LOGIN" then
        AIManager_RequestConfig();
        AIManager_RequestStatus();

    elseif event == "PLAYER_TARGET_CHANGED" or (event == "PLAYER_LOGOUT" and currentTargetGUID) then
        conversationHistory = {};
        currentTargetGUID = nil;
    end
end);

-- ===================================================================
-- Main Addon UI Functions
-- ===================================================================
function AIManager_OnLoad(self)
    self:RegisterForDrag("LeftButton");
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", AIManager_ChatFilter);
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SAY", AIManager_ChatSayFilter);

    AIManager_LinkSliderToEditBox(AIManagerContextSizeSlider, AIManagerContextSizeBox, "%d");
    AIManager_LinkSliderToEditBox(AIManagerMaxLengthSlider, AIManagerMaxLengthBox, "%d");
    AIManager_LinkSliderToEditBox(AIManagerTempSlider, AIManagerTempBox, "%.2f");
    AIManager_LinkSliderToEditBox(AIManagerRepPenSlider, AIManagerRepPenBox, "%.2f");
    AIManager_LinkSliderToEditBox(AIManagerTopPSlider, AIManagerTopPBox, "%.2f");
    AIManager_LinkSliderToEditBox(AIManagerTopKSlider, AIManagerTopKBox, "%d");
end

function AIManager_OnShow()
    if not isInitialized then
        AIManagerMenuButton1.pageName = "Network";
        AIManagerMenuButton2.pageName = "Format";
        AIManagerMenuButton3.pageName = "Samplers";
        AIManagerMenuButton4.pageName = "Characters";
        isInitialized = true;
    end

    AIManager_PopulateUI();
    AIManager_RequestConfig();
    AIManager_ShowPage("Network");
    AIManager_HighlightButton(AIManagerMenuButton1);
end

SLASH_AIMANAGER1 = "/aimanager";
SLASH_AIMANAGER2 = "/aim";
function SlashCmdList.AIMANAGER(msg, editbox)
    if AIManagerFrame:IsShown() then AIManagerFrame:Hide() else AIManagerFrame:Show() end
end

-- ===================================================================
-- Data Handling & Communication
-- ===================================================================

-- Helper to find a character card by name
function AIManager_GetCharacterCardByName(name)
    for _, card in ipairs(AIManagerDB.character_cards) do
        if card.name == name then
            return card;
        end
    end
    return nil;
end

function AIManager_RequestConfig()
    SendChatMessage("AIMGR GET_CONFIG", "SAY");
end

function AIManager_RequestStatus()
    SendChatMessage("AIMGR GET_STATUS", "SAY");
    print("|cff3399ffAI Manager:|r Refreshing connection status...");
end

function AIManager_ChatSayFilter(self, event, msg, ...)
    if string.find(msg, "AIMGR", 1, true) then return false end

    local target = "target";
    if UnitExists(target) and not UnitIsPlayer(target) and UnitCanCooperate("player", target) then
        local npcName = UnitName(target);
        local npcGUID = UnitGUID(target);

        if npcGUID ~= currentTargetGUID then
            conversationHistory = {};
            currentTargetGUID = npcGUID;
        end

        local playerCard = "Name: " .. AIManagerDB.player_card.name .. "\nDescription: " .. AIManagerDB.player_card.description;
        local npcCardData = AIManager_GetCharacterCardByName(npcName);
        local npcCard = npcCardData and npcCardData.description or "";
        
        local prompt = AIManagerDB.format.system_prompt .. "\n" .. playerCard .. "\n" .. npcCard .. table.concat(conversationHistory, "") .. "\nPlayer: " .. msg .. "\n" .. npcName .. ":";
        table.insert(conversationHistory, "\nPlayer: " .. msg);

        local samplerString = ""
        for k, v in pairs(AIManagerDB.samplers) do
            samplerString = samplerString .. "\"" .. k .. "\":" .. tostring(v) .. ","
        end
        samplerString = "{" .. string.sub(samplerString, 1, -2) .. "}";

        local safe_prompt = string.gsub(prompt, ";", "##SC##");
        safe_prompt = string.gsub(safe_prompt, "\n", "##NL##");
        
        local dataString = safe_prompt .. ";" .. samplerString;

        local chunkSize = 200;
        SendChatMessage("AIMGR PROMPT_START", "SAY");
        for i = 1, math.ceil(string.len(dataString) / chunkSize) do
            local chunk = string.sub(dataString, (i - 1) * chunkSize + 1, i * chunkSize);
            SendChatMessage("AIMGR PROMPT_CHUNK " .. chunk, "SAY");
        end
        SendChatMessage("AIMGR PROMPT_END", "SAY");
    end
    return false;
end

function AIManager_ChatFilter(self, event, msg, ...)
    if string.find(msg, "[AIMgr_STATUS]", 1, true) or string.find(msg, "[AIMgr_RESPONSE]", 1, true) or string.find(msg, "[AIMgr_CONFIG]", 1, true) then
        table.insert(messageQueue, msg);
        return true;
    end
    return false;
end

local updateFrame = CreateFrame("Frame", "AIManagerUpdateFrame")
updateFrame:SetScript("OnUpdate", function(self, elapsed)
    if #messageQueue > 0 then
        local msg = table.remove(messageQueue, 1);
        if string.find(msg, "[AIMgr_CONFIG]", 1, true) then
            local _, _, configData = string.find(msg, "%[AIMgr_CONFIG%](.+)");
            local host, port = string.match(configData, "host=([^;]+);port=([^;]+);");
            if host and port then
                AIManagerNetworkIPBox:SetText(host);
                AIManagerNetworkPortBox:SetText(port);
            end
        elseif string.find(msg, "[AIMgr_STATUS]", 1, true) then
            local _, _, statusValue = string.find(msg, "status=(.+)");
            if statusValue then AIManager_SetConnectionStatus(statusValue == "true") end
        elseif string.find(msg, "[AIMgr_RESPONSE]", 1, true) then
            local _, _, responseText = string.find(msg, "%[AIMgr_RESPONSE%](.+)");
            if responseText and currentTargetGUID then
                 table.insert(conversationHistory, " " .. responseText);
            end
        end
    end
end)

function AIManager_SaveChanges()
    if AIManagerNetworkPage:IsShown() then
        local host = AIManagerNetworkIPBox:GetText();
        local port = AIManagerNetworkPortBox:GetText();
        SendChatMessage("AIMGR SAVE_NETWORK_CONFIG " .. host .. " " .. port, "SAY");
        print("|cff3399ffAI Manager:|r Network settings sent to server.");
    end

    AIManagerDB.samplers.max_context_length = AIManagerContextSizeSlider:GetValue();
    AIManagerDB.samplers.max_length = AIManagerMaxLengthSlider:GetValue();
    AIManagerDB.samplers.temperature = AIManagerTempSlider:GetValue();
    AIManagerDB.samplers.repetition_penalty = AIManagerRepPenSlider:GetValue();
    AIManagerDB.samplers.top_p = AIManagerTopPSlider:GetValue();
    AIManagerDB.samplers.top_k = AIManagerTopKSlider:GetValue();
    AIManagerDB.format.system_prompt = AIManagerSysPromptBox:GetText();
    AIManagerDB.format.system_tag = AIManagerSystemTagBox:GetText();
    AIManagerDB.format.user_tag = AIManagerUserTagBox:GetText();
    AIManagerDB.format.assistant_tag = AIManagerAssistantTagBox:GetText();
    
    AIManagerDB.player_card.name = AIManagerPlayerNameBox:GetText();
    AIManagerDB.player_card.description = AIManagerPlayerDescBox:GetText();

    -- Save NPC Cards by updating them based on their ID
    for _, frame in ipairs(characterCardFrames) do
        local cardId = frame.characterId;
        for i, card in ipairs(AIManagerDB.character_cards) do
            if card.id == cardId then
                card.name = _G[frame:GetName() .. "NameBox"]:GetText();
                card.description = _G[frame:GetName() .. "DescBox"]:GetText();
                break; -- Found the card, no need to keep looping
            end
        end
    end
    
    print("|cff3399ffAI Manager:|r Local settings saved.");
    AIManager_UpdateCharacterCards();
end

function AIManager_PopulateUI()
    if not AIManagerDB then return end
    AIManagerContextSizeSlider:SetValue(AIManagerDB.samplers.max_context_length);
    AIManagerMaxLengthSlider:SetValue(AIManagerDB.samplers.max_length);
    AIManagerTempSlider:SetValue(AIManagerDB.samplers.temperature);
    AIManagerRepPenSlider:SetValue(AIManagerDB.samplers.repetition_penalty);
    AIManagerTopPSlider:SetValue(AIManagerDB.samplers.top_p);
    AIManagerTopKSlider:SetValue(AIManagerDB.samplers.top_k);
    AIManagerSysPromptBox:SetText(AIManagerDB.format.system_prompt);
    AIManagerSystemTagBox:SetText(AIManagerDB.format.system_tag);
    AIManagerUserTagBox:SetText(AIManagerDB.format.user_tag);
    AIManagerAssistantTagBox:SetText(AIManagerDB.format.assistant_tag);
    AIManager_UpdateCharacterCards();
end

-- ===================================================================
-- Character Page Functions
-- ===================================================================

function AIManager_AddCharacterCard()
    local newId = AIManagerDB.nextCharacterId;
    local newCard = {
        id = newId,
        name = "NewCharacter" .. newId,
        description = "",
    }
    table.insert(AIManagerDB.character_cards, newCard);
    AIManagerDB.nextCharacterId = newId + 1;
    AIManager_UpdateCharacterCards();
end

function AIManager_UpdateCharacterCards()
    -- Hide and clear all existing card frames before redrawing
    for _, frame in ipairs(characterCardFrames) do
        frame:Hide();
    end
    characterCardFrames = {};

    -- Populate the player card
    AIManagerPlayerNameBox:SetText(AIManagerDB.player_card.name or UnitName("player"));
    AIManagerPlayerDescBox:SetText(AIManagerDB.player_card.description or "");
    SetPortraitTexture(AIManagerPlayerPortraitTexture, "player");
    
    local lastAnchor = AIManagerPlayerCardFrame;

    -- Create and populate a frame for each NPC character card
    for _, cardData in ipairs(AIManagerDB.character_cards) do
        local cardFrame = CreateFrame("Frame", "AIManagerNPC_Card" .. cardData.id, AIManagerCharactersPage, "AIManagerCharacterCardTemplate");
        cardFrame:SetPoint("TOP", lastAnchor, "BOTTOM", 0, -20);
        
        cardFrame.characterId = cardData.id;
        
        _G[cardFrame:GetName() .. "NameBox"]:SetText(cardData.name);
        _G[cardFrame:GetName() .. "DescBox"]:SetText(cardData.description);
        _G[cardFrame:GetName() .. "PortraitTexture"]:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark");
        
        table.insert(characterCardFrames, cardFrame);
        lastAnchor = cardFrame;
        cardFrame:Show();
    end
    
    -- Anchor the "Add Character" button below the last card
    AIManagerAddCharacterButton:SetPoint("TOP", lastAnchor, "BOTTOM", 0, -20);
end


function AIManager_SetConnectionStatus(isConnected)
    AIManagerStatusIndicator:Show();
    if isConnected then
        AIManagerStatusIndicatorCircle:SetVertexColor(0.1, 0.9, 0.1);
        AIManagerStatusIndicatorText:SetText("Connected");
    else
        AIManagerStatusIndicatorCircle:SetVertexColor(0.9, 0.1, 0.1);
        AIManagerStatusIndicatorText:SetText("No Connection");
    end
end

function AIManager_LinkSliderToEditBox(slider, editbox, format)
    slider:SetScript("OnValueChanged", function(self, value) editbox:SetText(string.format(format, value)) end);
    editbox:SetScript("OnEnterPressed", function(self) slider:SetValue(tonumber(self:GetText()) or 0); self:ClearFocus() end);
end

-- ===================================================================
-- Page Switching & Highlighting
-- ===================================================================
function AIManager_MenuButton_OnClick(button)
    if button.pageName then
        AIManager_HighlightButton(button);
        AIManager_ShowPage(button.pageName);
    end
end

function AIManager_ShowPage(pageName)
    local pages = {Network=AIManagerNetworkPage, Format=AIManagerFormatPage, Samplers=AIManagerSamplersPage, Characters=AIManagerCharactersPage};
    for name, frame in pairs(pages) do frame:Hide() end
    if pages[pageName] then pages[pageName]:Show() end
    if pageName == "Characters" then 
        AIManager_UpdateCharacterCards();
    end
end

function AIManager_HighlightButton(buttonToHighlight)
    local menuButtons = {AIManagerMenuButton1, AIManagerMenuButton2, AIManagerMenuButton3, AIManagerMenuButton4};
    for _, button in ipairs(menuButtons) do
        if button == buttonToHighlight then
            button:GetFontString():SetTextColor(1, 1, 1)
        else
            button:GetFontString():SetTextColor(1, 0.82, 0)
        end
    end
end

-- ===================================================================
-- Restore & Delete Defaults Feature
-- ===================================================================
function AIManager_ShowRestoreDefaultsConfirmation(pageName)
    -- This would need a custom dialog as well, if we want to keep it.
end

function AIManager_RestoreDefaults(pageName)
    if pageName == "Format" then
        AIManagerDB.format = CopyTable(defaults.format);
    elseif pageName == "Samplers" then
        AIManagerDB.samplers = CopyTable(defaults.samplers);
    end
    
    AIManager_PopulateUI();
    print("|cff3399ffAI Manager:|r " .. pageName .. " settings restored to default.");
end
