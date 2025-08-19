-- ===================================================================
-- FILE: AI_Manager.lua (Hybrid Config Model)
-- ===================================================================
-- Use a global guard to prevent the entire file from being loaded and executed twice.
if AIManager_Initialized then return end
AIManager_Initialized = true

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
        stop_sequence = "Player:|</s>|\\n",
    },
    player_cards = {},
    character_cards = {}, 
    log = {}
}

-- Conversation state (cleared on target change or reload)
local conversationHistory = {};
local currentTargetGUID = nil;
local messageQueue = {};
local isInitialized = false;

-- Queue for sending prompt messages with a delay
local promptMessageQueue = {};
local timeSinceLastSend = 0;
local SEND_DELAY = 0.1; -- seconds

-- Variables for the thinking indicator UI
local isThinking = false;
local thinkingDots = ".";
local thinkingTimer = 0;

-- ===================================================================
-- Debug Logging System
-- ===================================================================
local function AIManager_Log(message)
    table.insert(AIManagerDB.log, date("[%H:%M:%S] ") .. message);
end

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
        AIManagerDB.log = AIManagerDB.log or {};
        
        AIManagerDB.indicatorPosition = AIManagerDB.indicatorPosition or { point = "TOP", x = 0, y = -20 };
        AIManagerThinkingIndicatorFrame:SetPoint(
            AIManagerDB.indicatorPosition.point,
            UIParent,
            AIManagerDB.indicatorPosition.point,
            AIManagerDB.indicatorPosition.x,
            AIManagerDB.indicatorPosition.y
        );
        AIManagerThinkingIndicatorFrame:RegisterForDrag("LeftButton");

        local characterKey = UnitName("player") .. "-" .. GetRealmName();
        
        if AIManagerDB.player_card and not AIManagerDB.player_cards then
            AIManager_Log("Migrating old player_card format...");
            AIManagerDB.player_cards = {}
            AIManagerDB.player_cards[characterKey] = AIManagerDB.player_card
            AIManagerDB.player_card = nil 
        end

        AIManagerDB.player_cards = AIManagerDB.player_cards or {};
        if not AIManagerDB.player_cards[characterKey] then
            AIManager_Log("Creating new player card for " .. characterKey);
            AIManagerDB.player_cards[characterKey] = {
                name = UnitName("player"),
                description = "",
            }
        end
        
        if AIManagerDB.character_cards and AIManagerDB.character_cards[1] and AIManagerDB.character_cards[1].id then
             AIManager_Log("Migrating NPC character cards to new name-keyed format...");
             local newCards = {}
             for _, cardData in ipairs(AIManagerDB.character_cards) do
                 if cardData.name and cardData.description then
                     newCards[cardData.name] = { description = cardData.description }
                 end
             end
             AIManagerDB.character_cards = newCards
             AIManagerDB.nextCharacterId = nil 
        end

        ChatFrame1EditBox:SetScript("OnEnterPressed", function(self)
            local messageText = self:GetText();
            local chatType = self:GetAttribute("chatType");

            if chatType == "SAY" and messageText and messageText ~= "" and messageText:sub(1,1) ~= "/" and UnitExists("target") and not UnitIsPlayer("target") then
                AIManager_ProcessChatMessage(messageText);
            end

            ChatEdit_OnEnterPressed(self);
        end);

        print("|cff3399ffAI Manager:|r AddOn Loaded. Use /aim to open. Use /aimlog for debug info.");
    
    elseif event == "PLAYER_LOGIN" then
        AIManager_RequestConfig();
        AIManager_RequestStatus();

    elseif event == "PLAYER_TARGET_CHANGED" then
        if AIManagerFrame:IsShown() and AIManagerCharactersPage:IsShown() then
            AIManager_UpdateTargetCard();
        end
        conversationHistory = {};
        currentTargetGUID = nil;
    
    elseif event == "PLAYER_LOGOUT" then
        conversationHistory = {};
        currentTargetGUID = nil;
        AIManager_ShowThinkingIndicator(false);
    end
end);

-- ===================================================================
-- Main Addon UI Functions
-- ===================================================================
function AIManager_OnLoad(self)
    self:RegisterForDrag("LeftButton");
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", AIManager_ChatFilter);
    
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
    if msg == "log" then
        SlashCmdList.AIMLOG("");
    else
        if AIManagerFrame:IsShown() then AIManagerFrame:Hide() else AIManagerFrame:Show() end
    end
end

SLASH_AIMLOG1 = "/aimlog";
function SlashCmdList.AIMLOG(msg, editbox)
    if msg == "clear" then
        AIManagerDB.log = {};
        print("|cff3399ffAI Manager:|r Debug log has been cleared.");
    else
        print("|cff3399ffAI Manager:|r Your debug log file can be found at:");
        print("|cffffd100World of Warcraft/_classic_/WTF/Account/<ACCOUNT_NAME>/SavedVariables/AI_Manager.lua|r");
    end
end

-- ===================================================================
-- Data Handling & Communication
-- ===================================================================
function AIManager_GetCharacterCardByName(name)
    if name and AIManagerDB.character_cards then
        return AIManagerDB.character_cards[name];
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

function AIManager_Indicator_OnDragStop(frame)
    local point, _, relativePoint, x, y = frame:GetPoint();
    AIManagerDB.indicatorPosition = {
        point = point,
        x = x,
        y = y
    };
    AIManager_Log("Indicator position saved.");
end

function AIManager_ShowThinkingIndicator(show)
    isThinking = show;
    if show then
        AIManagerThinkingIndicatorFrame:Show();
    else
        AIManagerThinkingIndicatorFrame:Hide();
    end
end

function AIManager_ProcessChatMessage(messageText)
    local target = "target";
    local npcName = UnitName(target);
    local npcGUID = UnitGUID(target);

    if npcGUID ~= currentTargetGUID then
        conversationHistory = {};
        currentTargetGUID = npcGUID;
    end

    if not AIManagerDB.format or not AIManagerDB.format.system_prompt or AIManagerDB.format.system_prompt == "" then
        print("|cff3399ff[AI MANAGER ERROR]|r System prompt is nil or empty! Aborting.");
        return;
    end

    local characterKey = UnitName("player") .. "-" .. GetRealmName();
    local playerCardData = AIManagerDB.player_cards[characterKey] or { name = UnitName("player"), description = "" };
    local playerCard = "Name: " .. playerCardData.name .. "\nDescription: " .. playerCardData.description;

    local npcCardData = AIManager_GetCharacterCardByName(npcName);
    local npcDescription = (npcCardData and npcCardData.description) or "";
    local npcCard = "Name: " .. npcName .. "\nDescription: " .. npcDescription;
    
    local prompt = AIManagerDB.format.system_prompt .. "\n" .. playerCard .. "\n" .. npcCard .. table.concat(conversationHistory, "") .. "\nPlayer: " .. messageText .. "\n" .. npcName .. ":";
    table.insert(conversationHistory, "\nPlayer: " .. messageText);

    -- Build the JSON string for samplers and stop sequences
    local samplerParts = {}
    for k, v in pairs(AIManagerDB.samplers) do
        table.insert(samplerParts, "\"" .. k .. "\":" .. tostring(v))
    end

    local stopSequence = AIManagerDB.format.stop_sequence or ""
    local stopSequenceTable = {}
    for word in string.gmatch(stopSequence, "([^|]+)") do
        word = string.gsub(word, "^%s*(.-)%s*$", "%1") -- Trim whitespace
        if word ~= "" then
            if word == "\\n" then
                table.insert(stopSequenceTable, "\"\\n\"")
            else
                word = string.gsub(word, "\\", "\\\\")
                word = string.gsub(word, "\"", "\\\"")
                table.insert(stopSequenceTable, "\"" .. word .. "\"")
            end
        end
    end

    if #stopSequenceTable > 0 then
        local stopSequenceJsonArray = "[" .. table.concat(stopSequenceTable, ",") .. "]"
        table.insert(samplerParts, "\"stop_sequence\":" .. stopSequenceJsonArray)
    end

    local finalSamplerString = "{" .. table.concat(samplerParts, ",") .. "}"
    
    local safe_prompt = string.gsub(prompt, ";", "##SC##");
    safe_prompt = string.gsub(safe_prompt, "\n", "##NL##");
    
    local dataString = safe_prompt .. ";" .. finalSamplerString;

    table.insert(promptMessageQueue, "AIMGR PROMPT_START ");
    local chunkSize = 200;
    for i = 1, math.ceil(string.len(dataString) / chunkSize) do
        local chunk = string.sub(dataString, (i - 1) * chunkSize + 1, i * chunkSize);
        table.insert(promptMessageQueue, "AIMGR PROMPT_CHUNK " .. chunk);
    end
    table.insert(promptMessageQueue, "AIMGR PROMPT_END " .. npcGUID);
end

function AIManager_ChatFilter(self, event, msg, ...)
    if string.find(msg, "[AIMgr_STATUS]", 1, true) or string.find(msg, "[AIMgr_RESPONSE]", 1, true) or string.find(msg, "[AIMgr_CONFIG]", 1, true) or string.find(msg, "[AIMgr_THINKING]", 1, true) then
        table.insert(messageQueue, msg);
        return true;
    end
    return false;
end

local updateFrame = CreateFrame("Frame", "AIManagerUpdateFrame")
updateFrame:SetScript("OnUpdate", function(self, elapsed)
    -- Process server response queue
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
        elseif string.find(msg, "[AIMgr_THINKING]", 1, true) then
            AIManager_ShowThinkingIndicator(true);
        elseif string.find(msg, "[AIMgr_RESPONSE]", 1, true) then
            AIManager_ShowThinkingIndicator(false);
            local _, _, responseText = string.find(msg, "%[AIMgr_RESPONSE%](.+)");
            if responseText and currentTargetGUID then
                 table.insert(conversationHistory, " " .. responseText);
            end
        end
    end

    -- Process prompt sending queue
    timeSinceLastSend = timeSinceLastSend + elapsed;
    if timeSinceLastSend > SEND_DELAY then
        if #promptMessageQueue > 0 then
            local messageToSend = table.remove(promptMessageQueue, 1);
            SendChatMessage(messageToSend, "SAY");
            timeSinceLastSend = 0;
        end
    end

    -- Animate thinking indicator text
    if isThinking then
        thinkingTimer = thinkingTimer + elapsed;
        if thinkingTimer > 0.5 then
            thinkingTimer = 0;
            if thinkingDots == "." then
                thinkingDots = "..";
            elseif thinkingDots == ".." then
                thinkingDots = "...";
            else
                thinkingDots = ".";
            end
            AIManagerThinkingIndicatorFrameText:SetText("Generating Response" .. thinkingDots);
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

    AIManagerDB.samplers.max_context_length = tonumber(AIManagerContextSizeBox:GetText()) or defaults.samplers.max_context_length;
    AIManagerDB.samplers.max_length = tonumber(AIManagerMaxLengthBox:GetText()) or defaults.samplers.max_length;
    AIManagerDB.samplers.temperature = tonumber(AIManagerTempBox:GetText()) or defaults.samplers.temperature;
    AIManagerDB.samplers.repetition_penalty = tonumber(AIManagerRepPenBox:GetText()) or defaults.samplers.repetition_penalty;
    AIManagerDB.samplers.top_p = tonumber(AIManagerTopPBox:GetText()) or defaults.samplers.top_p;
    AIManagerDB.samplers.top_k = tonumber(AIManagerTopKBox:GetText()) or defaults.samplers.top_k;
    
    AIManagerDB.format.system_prompt = AIManagerSysPromptBox:GetText();
    AIManagerDB.format.system_tag = AIManagerSystemTagBox:GetText();
    AIManagerDB.format.user_tag = AIManagerUserTagBox:GetText();
    AIManagerDB.format.assistant_tag = AIManagerAssistantTagBox:GetText();
    AIManagerDB.format.stop_sequence = AIManagerStopSequenceBox:GetText();
    
    local characterKey = UnitName("player") .. "-" .. GetRealmName();
    if AIManagerDB.player_cards[characterKey] then
        AIManagerDB.player_cards[characterKey].name = AIManagerPlayerNameBox:GetText();
        AIManagerDB.player_cards[characterKey].description = AIManagerPlayerDescBox:GetText();
    end

    if UnitExists("target") then
        local npcName = UnitName("target");
        local newDescription = AIManagerTargetCardFrameDescBox:GetText();

        if newDescription and newDescription ~= "" then
            AIManagerDB.character_cards[npcName] = { description = newDescription };
            AIManager_Log("Saved description for NPC: " .. npcName);
        else
            AIManagerDB.character_cards[npcName] = nil;
            AIManager_Log("Removed description for NPC: " .. npcName);
        end
    end
    
    AIManager_Log("Local settings saved.");
    AIManager_PopulateUI();
end

function AIManager_PopulateUI()
    if not AIManagerDB then return end
    
    AIManagerContextSizeSlider:SetValue(AIManagerDB.samplers.max_context_length);
    AIManagerMaxLengthSlider:SetValue(AIManagerDB.samplers.max_length);
    AIManagerTempSlider:SetValue(AIManagerDB.samplers.temperature);
    AIManagerRepPenSlider:SetValue(AIManagerDB.samplers.repetition_penalty);
    AIManagerTopPSlider:SetValue(AIManagerDB.samplers.top_p);
    AIManagerTopKSlider:SetValue(AIManagerDB.samplers.top_k);

    AIManagerContextSizeBox:SetText(string.format("%d", AIManagerDB.samplers.max_context_length));
    AIManagerMaxLengthBox:SetText(string.format("%d", AIManagerDB.samplers.max_length));
    AIManagerTempBox:SetText(string.format("%.2f", AIManagerDB.samplers.temperature));
    AIManagerRepPenBox:SetText(string.format("%.2f", AIManagerDB.samplers.repetition_penalty));
    AIManagerTopPBox:SetText(string.format("%.2f", AIManagerDB.samplers.top_p));
    AIManagerTopKBox:SetText(string.format("%d", AIManagerDB.samplers.top_k));

    AIManagerSysPromptBox:SetText(AIManagerDB.format.system_prompt);
    AIManagerSystemTagBox:SetText(AIManagerDB.format.system_tag);
    AIManagerUserTagBox:SetText(AIManagerDB.format.user_tag);
    AIManagerAssistantTagBox:SetText(AIManagerDB.format.assistant_tag);
    AIManagerStopSequenceBox:SetText(AIManagerDB.format.stop_sequence or defaults.format.stop_sequence);
    
    AIManager_UpdateCharacterCards();
end

-- ===================================================================
-- Character Page Functions
-- ===================================================================

function AIManager_UpdateTargetCard()
    if UnitExists("target") and not UnitIsPlayer("target") then
        local npcName = UnitName("target");

        AIManagerTargetHintText:Hide();
        AIManagerTargetCardFramePortraitFrame:Show();
        AIManagerTargetCardFrameNameBox:Show();
        AIManagerTargetCardFrameDescScrollFrame:Show();
        
        AIManagerTargetCardFrameNameBox:SetText(npcName);
        
        SetPortraitTexture(AIManagerTargetCardFramePortraitTexture, "target");

        local card = AIManager_GetCharacterCardByName(npcName);
        if card and card.description then
            AIManagerTargetCardFrameDescBox:SetText(card.description);
        else
            AIManagerTargetCardFrameDescBox:SetText("");
        end

    else
        AIManagerTargetHintText:Show();
        AIManagerTargetCardFramePortraitFrame:Hide();
        AIManagerTargetCardFrameNameBox:Hide();
        AIManagerTargetCardFrameDescScrollFrame:Hide();
        AIManagerTargetCardFrameNameBox:SetText("");
        AIManagerTargetCardFrameDescBox:SetText("");
        AIManagerTargetCardFramePortraitTexture:SetTexture(nil);
    end
end

function AIManager_UpdateCharacterCards()
    AIManager_Log("\n--- UpdateCharacterCards ---")

    local characterKey = UnitName("player") .. "-" .. GetRealmName();
    local playerCard = AIManagerDB.player_cards[characterKey];

    if playerCard then
        AIManagerPlayerNameBox:SetText(playerCard.name or UnitName("player"));
        AIManagerPlayerDescBox:SetText(playerCard.description or "");
    else
        AIManagerPlayerNameBox:SetText(UnitName("player"));
        AIManagerPlayerDescBox:SetText("");
    end
    SetPortraitTexture(AIManagerPlayerPortraitTexture, "player");
    
    AIManager_UpdateTargetCard();
    AIManager_Log("--- Character Page Update Finished ---\n")
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
    AIManager_RestoreDefaults(pageName);
end

function AIManager_RestoreDefaults(pageName)
    if pageName == "Format" then
        AIManagerDB.format = CopyTable(defaults.format);
    elseif pageName == "Samplers" then
        AIManagerDB.samplers = CopyTable(defaults.samplers);
    end
    
    AIManager_Log("Settings restored to default for page: " .. pageName);
    
    AIManager_PopulateUI();
end
