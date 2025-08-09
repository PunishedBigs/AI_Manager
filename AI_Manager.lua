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

-- ===================================================================
-- OnUpdate Frame for Safe Message Processing
-- ===================================================================
local updateFrame = CreateFrame("Frame", "AIManagerUpdateFrame")
updateFrame:SetScript("OnUpdate", function(self, elapsed)
    if #messageQueue > 0 then
        local msg = table.remove(messageQueue, 1);
        if string.find(msg, "status=") then
            local _, _, content = string.find(msg, "status=(.+)");
            if content then AIManager_ParseStatus(content) end
        elseif string.find(msg, "host=") then
            local _, _, content = string.find(msg, "(host=.+)");
            if content then AIManager_ParseConfig(content) end
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
    
    if AIManagerNetworkPage:IsShown() then
        dataString = "host=" .. AIManagerNetworkIPBox:GetText() .. ";" ..
                     "port=" .. AIManagerNetworkPortBox:GetText() .. ";";
    elseif AIManagerSamplersPage:IsShown() then
        dataString = "max_context_length=" .. AIManagerContextSizeBox:GetText() .. ";" ..
                     "max_length=" .. AIManagerMaxLengthBox:GetText() .. ";" ..
                     "temperature=" .. AIManagerTempBox:GetText() .. ";" ..
                     "repetition_penalty=" .. AIManagerRepPenBox:GetText() .. ";" ..
                     "top_p=" .. AIManagerTopPBox:GetText() .. ";" ..
                     "top_k=" .. AIManagerTopKBox:GetText() .. ";";
    elseif AIManagerFormatPage:IsShown() then
        local prompt = AIManagerSysPromptBox:GetText();
        prompt = string.gsub(prompt, "\n", "||NL||");
        dataString = "system_prompt=" .. prompt .. ";" ..
                     "system_tag=" .. AIManagerSystemTagBox:GetText() .. ";" ..
                     "user_tag=" .. AIManagerUserTagBox:GetText() .. ";" ..
                     "assistant_tag=" .. AIManagerAssistantTagBox:GetText() .. ";";
    end

    -- FIX: Send the data in chunks to avoid the 255 character limit.
    local chunkSize = 200;
    SendAddonMessage("AIMGR", "SAVE_CONFIG_START", "GUILD");
    for i = 1, math.ceil(string.len(dataString) / chunkSize) do
        local chunk = string.sub(dataString, (i - 1) * chunkSize + 1, i * chunkSize);
        SendAddonMessage("AIMGR", "SAVE_CONFIG_CHUNK " .. chunk, "GUILD");
    end
    SendAddonMessage("AIMGR", "SAVE_CONFIG_END", "GUILD");

    AIManager_RequestConfig(); -- Refresh data after saving
end

function AIManager_ChatFilter(self, event, msg, ...)
    if string.find(msg, "[AIMgr_STATUS]") or string.find(msg, "[AIMgr_CONFIG]") then
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
    for key, value in string.gmatch(configStr, "([^=]+)=([^;]+);") do
        if key == "port" or key == "max_context_length" or key == "max_length" or key == "top_k" then
            currentConfig[key] = tonumber(value);
        elseif key == "temperature" or key == "repetition_penalty" or key == "top_p" then
            currentConfig[key] = tonumber(value);
        elseif key == "system_prompt" then
            currentConfig[key] = string.gsub(value, "||NL||", "\n");
        else
            currentConfig[key] = value;
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
