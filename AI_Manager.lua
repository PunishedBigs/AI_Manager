-- ===================================================================
-- FILE: AI_Manager.lua (with Robust Message Queue and Final Fix)
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

        -- The definitive fix: We now look for the start of the data itself,
        -- ignoring any leading characters or tags.
        if string.find(msg, "status=") then
            local _, _, content = string.find(msg, "status=(.+)");
            if content then AIManager_ParseStatus(content) end
        elseif string.find(msg, "host=") then
            -- We need to reconstruct the full data string for the parser.
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
    print("|cff3 indossffAI Manager:|r AddOn Loaded.");
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
                text:SetTextColor(1.0, 1.0, 1.0); -- White for selected
            else
                text:SetTextColor(1.0, 0.82, 0.0); -- Yellow for unselected
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
    local newConfig = {
        host = AIManagerNetworkIPBox:GetText(),
        port = AIManagerNetworkPortBox:GetText()
    };

    local dataString = "";
    for key, value in pairs(newConfig) do
        dataString = dataString .. key .. "=" .. tostring(value) .. ";";
    end
    
    -- Send the save command and the data string to the server.
    SendAddonMessage("AIMGR", "SAVE_CONFIG " .. dataString, "GUILD");
    
    -- After saving, immediately request a refresh of the status and config.
    AIManager_RequestConfig();
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
        currentConfig[key] = value;
    end
    AIManager_PopulateUI();
end

function AIManager_PopulateUI()
    if currentConfig.host then
        AIManagerNetworkIPBox:SetText(currentConfig.host);
    end
    if currentConfig.port then
        AIManagerNetworkPortBox:SetText(currentConfig.port);
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
