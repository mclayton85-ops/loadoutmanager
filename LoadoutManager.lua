-- LoadoutManager - WoW TBC Classic Addon
-- Refactored for stability and bug fixes

--table definitions
LoadoutManager = {}
LoadoutManager.db = {}
LoadoutManager.currentLoadout = nil
LoadoutManager.frame = nil
LoadoutManager.isProcessing = false
LoadoutManager.moveQueue = {} -- The new move queue
LoadoutManager.errorLog = {}
LoadoutManager.withdrawalLog = {}
LoadoutManager.guildBankCache = {}
LoadoutManager.bankCache = {}
LoadoutManager.bagUpdateTimer = nil

-- TBC-compatible timer function to replace C_Timer.After
function LoadoutManager:CreateTimer(delay, callback)
    local frame = CreateFrame("Frame")
    local elapsed = 0
    frame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= delay then
            frame:SetScript("OnUpdate", nil)
            callback()
        end
    end)
end

--ui table definitions
LoadoutManagerUI = {}
LoadoutManagerUI.frame = nil
LoadoutManagerUI.minimapButton = nil

-- Safe print function that works in all contexts
function LoadoutManager:Print(msg)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[LoadoutManager]|r " .. tostring(msg))
    end
end

-- Initialize the addon
function LoadoutManager:OnLoad()
    self.frame = CreateFrame("Frame", "LoadoutManagerFrame")
    self.frame:RegisterEvent("ADDON_LOADED")
    self.frame:RegisterEvent("BAG_UPDATE")
    self.frame:RegisterEvent("BANKFRAME_OPENED")
    self.frame:RegisterEvent("BANKFRAME_CLOSED")
    self.frame:RegisterEvent("GUILDBANKFRAME_OPENED")
    self.frame:RegisterEvent("GUILDBANKFRAME_CLOSED")
    self.frame:RegisterEvent("GUILDBANK_UPDATE") -- Add this event for guild bank scanning
	self.frame:RegisterEvent("PLAYER_LOGIN")

    self.frame:SetScript("OnEvent", function(frame, event, ...)
        LoadoutManager:OnEvent(event, ...)
    end)
end

-- Slash command registration
function LoadoutManager:RegisterSlashCommands()
    SLASH_LOADOUT1 = "/loadout"
    SlashCmdList["LOADOUT"] = function(msg)
        self:HandleSlashCommand(msg)
    end
end

-- The HandleSlashCommand function will parse the arguments
function LoadoutManager:HandleSlashCommand(msg)
    local command, rest = msg:match("^(%S+)%s*(.*)$")
    if not command then
        command = ""
    end
    command = command:lower()

    if command == "save" then
        self:SaveCurrentLoadout(rest)
    elseif command == "load" then
        self:LoadLoadout(rest)
    elseif command == "list" then
        self:ListLoadouts()
    elseif command == "delete" then
        self:DeleteLoadout(rest)
    elseif command == "ui" or command == "interface" then
        LoadoutManagerUI:Toggle()
	elseif command == "forcesave" then
        self:Print("DEBUG: Forcing save of LoadoutManagerDB")
        self:Print("DEBUG: Current loadout count: " .. self:CountLoadouts())
        -- Note: In TBC Classic, saved variables are automatically saved on clean logout
        self:Print("DEBUG: SavedVariables will be written on next clean logout")
    elseif command == "help" then
        self:ShowHelp()
    else
        self:Print("Unknown command. Type /loadout help for a list of commands.")
    end
end

-- This is the ShowHelp function you should add.
function LoadoutManager:ShowHelp()
    self:Print("--- LoadoutManager Commands ---")
    self:Print("/loadout help - Show this help message.")
    self:Print("/loadout save <name> - Saves your current bag contents as a loadout.")
    self:Print("/loadout load <name> - Reorganizes your bags to match a saved loadout.")
    self:Print("/loadout list - Lists all of your saved loadouts.")
    self:Print("/loadout delete <name> - Deletes a saved loadout.")
    self:Print("/loadout ui - Opens the graphical interface.")
	self:Print("/loadout forcesave - Force save variables to disk (debug).")
    self:Print("------------------------------")
end

-- This is the ListLoadouts function you should add
function LoadoutManager:ListLoadouts()
    self:Print("--- Saved Loadouts ---")
    local count = 0
    for name, loadout in pairs(self.db.loadouts) do
        local date = date("%Y-%m-%d %H:%M:%S", loadout.timestamp)
        self:Print(string.format("- %s (Saved: %s)", name, date))
        count = count + 1
    end
    if count == 0 then
        self:Print("No loadouts saved yet.")
    end
    self:Print("----------------------")
end



-- Create tab buttons in the button container
function LoadoutManagerUI:CreateTabButtons(mainFrame)
    local buttonContainer = mainFrame.buttonContainer

    -- Create button
    local createButton = CreateFrame("Button", "LoadoutManagerCreateTab", buttonContainer, "UIPanelButtonTemplate")
    createButton:SetPoint("TOPLEFT", buttonContainer, "TOPLEFT", 0, 0)
    createButton:SetWidth(110)
    createButton:SetHeight(30)
    createButton:SetText("Create Loadout")
    createButton.tabType = "create"
    createButton:SetScript("OnClick", function(self)
        LoadoutManagerUI:SetActiveButton(mainFrame, self)
    end)

    -- List button
    local listButton = CreateFrame("Button", "LoadoutManagerListTab", buttonContainer, "UIPanelButtonTemplate")
    listButton:SetPoint("TOPLEFT", createButton, "BOTTOMLEFT", 0, -5)
    listButton:SetWidth(110)
    listButton:SetHeight(30)
    listButton:SetText("View Loadouts")
    listButton.tabType = "list"
    listButton:SetScript("OnClick", function(self)
        LoadoutManagerUI:SetActiveButton(mainFrame, self)
    end)

    -- Delete button
    local deleteButton = CreateFrame("Button", "LoadoutManagerDeleteTab", buttonContainer, "UIPanelButtonTemplate")
    deleteButton:SetPoint("TOPLEFT", listButton, "BOTTOMLEFT", 0, -5)
    deleteButton:SetWidth(110)
    deleteButton:SetHeight(30)
    deleteButton:SetText("Delete Loadout")
    deleteButton.tabType = "delete"
    deleteButton:SetScript("OnClick", function(self)
        LoadoutManagerUI:SetActiveButton(mainFrame, self)
    end)

    -- Store button references
    mainFrame.createButton = createButton
    mainFrame.listButton = listButton
    mainFrame.deleteButton = deleteButton
end


-- Set active button and show corresponding content
function LoadoutManagerUI:SetActiveButton(mainFrame, button)
    -- Reset all button states
    mainFrame.createButton:SetButtonState("NORMAL")
    mainFrame.listButton:SetButtonState("NORMAL")
    mainFrame.deleteButton:SetButtonState("NORMAL")

    -- Hide all content frames
    for _, contentFrame in pairs(mainFrame.contentFrames) do
        if contentFrame then
            contentFrame:Hide()
        end
    end

    -- Set the clicked button as pressed
    button:SetButtonState("PUSHED", true)
    mainFrame.activeButton = button

    -- Show content for the selected tab
    if button.tabType == "create" then
        self:ShowCreateContent(mainFrame)
    elseif button.tabType == "list" then
        self:ShowListContent(mainFrame)
    elseif button.tabType == "delete" then
        self:ShowDeleteContent(mainFrame)
    end
end

-- Show create loadout content in the content area
function LoadoutManagerUI:ShowCreateContent(mainFrame)
    local contentArea = mainFrame.contentArea
    
    -- Create content frame if it doesn't exist
    if not mainFrame.contentFrames.create then
        local createFrame = CreateFrame("Frame", nil, contentArea)
        createFrame:SetAllPoints(contentArea)
        
        -- Title
        local title = createFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetText("Create New Loadout")
        title:SetPoint("TOP", createFrame, "TOP", 0, -20)
        
        -- Input box label
        local label = createFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetText("Enter loadout name:")
        label:SetPoint("CENTER", createFrame, "CENTER", 0, 30)
        
	 -- Input box
		local editBox = CreateFrame("EditBox", nil, createFrame, "InputBoxTemplate")
		editBox:SetWidth(200)
		editBox:SetHeight(20)
		editBox:SetPoint("CENTER", createFrame, "CENTER", 0, 0)
		editBox:SetAutoFocus(false)
		editBox:SetText("")

-- Handle focus events to manage keyboard input
editBox:SetScript("OnEditFocusGained", function(self)
    -- When editbox gains focus, track state but keep frame keyboard enabled
    mainFrame.toggleKeyboard(true)
end)

editBox:SetScript("OnEditFocusLost", function(self)
    -- When editbox loses focus, track state but keep frame keyboard enabled for ESC
    mainFrame.toggleKeyboard(false)
end)      
        -- Save Button
        local saveButton = CreateFrame("Button", nil, createFrame, "UIPanelButtonTemplate")
        saveButton:SetWidth(80)
        saveButton:SetHeight(25)
        saveButton:SetPoint("CENTER", createFrame, "CENTER", 0, -40)
        saveButton:SetText("Save")
        saveButton:SetScript("OnClick", function()
            local name = editBox:GetText()
            if name and name ~= "" then
                LoadoutManager:SaveCurrentLoadout(name)
                editBox:SetText("")
                editBox:ClearFocus()
            else
                LoadoutManager:Print("Please enter a loadout name.")
            end
        end)
        
        -- Allow Enter key to save
        editBox:SetScript("OnEnterPressed", function()
            local name = editBox:GetText()
            if name and name ~= "" then
                LoadoutManager:SaveCurrentLoadout(name)
                editBox:SetText("")
                editBox:ClearFocus()
            else
                LoadoutManager:Print("Please enter a loadout name.")
            end
        end)
        
        mainFrame.contentFrames.create = createFrame
    end
    
    mainFrame.contentFrames.create:Show()
end

-- Show loadout list content in the content area (ENHANCED VERSION)
function LoadoutManagerUI:ShowListContent(mainFrame)
    local contentArea = mainFrame.contentArea
    
    -- Create content frame if it doesn't exist
    if not mainFrame.contentFrames.list then
        local listFrame = CreateFrame("Frame", nil, contentArea)
        listFrame:SetAllPoints(contentArea)
        
        -- Title
        local title = listFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetText("View Loadouts")
        title:SetPoint("TOP", listFrame, "TOP", 0, -20)
        
        mainFrame.contentFrames.list = listFrame
        mainFrame.contentFrames.list.currentPage = 1
    end
    
    -- Get available loadouts
    local loadoutNames = {}
    if LoadoutManager and LoadoutManager.db and LoadoutManager.db.loadouts then
        for name in pairs(LoadoutManager.db.loadouts) do
            table.insert(loadoutNames, name)
        end
    end
    table.sort(loadoutNames)
    
    if #loadoutNames == 0 then
        -- Show "no loadouts" message
        if not mainFrame.contentFrames.list.noLoadoutsText then
            local noLoadoutsText = mainFrame.contentFrames.list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            noLoadoutsText:SetText("No loadouts available to view.")
            noLoadoutsText:SetPoint("CENTER", mainFrame.contentFrames.list, "CENTER", 0, 0)
            mainFrame.contentFrames.list.noLoadoutsText = noLoadoutsText
        end
        mainFrame.contentFrames.list.noLoadoutsText:Show()
    else
        -- Hide "no loadouts" message if it exists
        if mainFrame.contentFrames.list.noLoadoutsText then
            mainFrame.contentFrames.list.noLoadoutsText:Hide()
        end
        
-- Create loadout selection list if it doesn't exist
if not mainFrame.contentFrames.list.loadoutListFrame then
    -- Create scrollable list frame
    local loadoutListFrame = CreateFrame("ScrollFrame", nil, mainFrame.contentFrames.list)
    loadoutListFrame:SetPoint("TOPLEFT", mainFrame.contentFrames.list, "TOPLEFT", 10, -50)
    loadoutListFrame:SetWidth(250)  -- Narrower to leave room for item view
    loadoutListFrame:SetHeight(240)  -- Doubled from 120 to 240
    loadoutListFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    loadoutListFrame:SetBackdropColor(0, 0, 0, 0.8)
    
   -- Create scroll child
    local scrollChild = CreateFrame("Frame", nil, loadoutListFrame)
    loadoutListFrame:SetScrollChild(scrollChild)
    scrollChild:SetWidth(230)  -- Adjusted for narrower list
        
    -- Store references
    mainFrame.contentFrames.list.loadoutListFrame = loadoutListFrame
    mainFrame.contentFrames.list.scrollChild = scrollChild
    mainFrame.contentFrames.list.loadoutButtons = {}
    mainFrame.contentFrames.list.selectedLoadout = nil
end

-- Clear existing buttons
if mainFrame.contentFrames.list.loadoutButtons then
    for _, button in ipairs(mainFrame.contentFrames.list.loadoutButtons) do
        button:Hide()
    end
    mainFrame.contentFrames.list.loadoutButtons = {}
end

-- Create buttons for each loadout
local yOffset = 0
for i, loadoutName in ipairs(loadoutNames) do
    local button = CreateFrame("Button", nil, mainFrame.contentFrames.list.scrollChild)
    button:SetWidth(230)  -- Adjusted to match narrower container
    button:SetHeight(35)
    button:SetPoint("TOPLEFT", mainFrame.contentFrames.list.scrollChild, "TOPLEFT", 5, -10 - yOffset)
    
    -- Button text
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", button, "LEFT", 13, 4)
    text:SetJustifyH("LEFT")
    text:SetText(loadoutName)
    button.text = text
    
    -- Button background
    button:SetNormalTexture("Interface\\Buttons\\UI-Panel-Button-Up")
    button:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")
    button:SetPushedTexture("Interface\\Buttons\\UI-Panel-Button-Down")
    
    -- Click handler
    button:SetScript("OnClick", function(self)
        -- Deselect all other buttons
        for _, otherButton in ipairs(mainFrame.contentFrames.list.loadoutButtons) do
            otherButton.text:SetTextColor(1, 1, 1) -- White
        end
        
        -- Select this button
        self.text:SetTextColor(1, 1, 0) -- Yellow
        mainFrame.contentFrames.list.selectedLoadout = loadoutName
        LoadoutManagerUI:HideItemView(mainFrame)
    end)
    
    table.insert(mainFrame.contentFrames.list.loadoutButtons, button)
    yOffset = yOffset + 40
end

-- Set scroll child height
mainFrame.contentFrames.list.scrollChild:SetHeight(math.max(yOffset, 100))

-- Select first loadout by default
if #loadoutNames > 0 and mainFrame.contentFrames.list.loadoutButtons[1] then
    mainFrame.contentFrames.list.loadoutButtons[1].text:SetTextColor(1, 1, 0) -- Yellow
    mainFrame.contentFrames.list.selectedLoadout = loadoutNames[1]
end

-- Create action buttons if they don't exist
        if not mainFrame.contentFrames.list.loadButton then
            -- Load Button
            local loadButton = CreateFrame("Button", nil, mainFrame.contentFrames.list, "UIPanelButtonTemplate")
            loadButton:SetWidth(100)
            loadButton:SetHeight(25)
            loadButton:SetPoint("CENTER", mainFrame.contentFrames.list, "CENTER", -60, -120)
            loadButton:SetText("Load Loadout")
            
            -- View Items Button
            local viewButton = CreateFrame("Button", nil, mainFrame.contentFrames.list, "UIPanelButtonTemplate")
            viewButton:SetWidth(120)
            viewButton:SetHeight(25)
            viewButton:SetPoint("CENTER", mainFrame.contentFrames.list, "CENTER", 70, -120)
            viewButton:SetText("View Items")
            -- Store references
            mainFrame.contentFrames.list.loadButton = loadButton
            mainFrame.contentFrames.list.viewButton = viewButton
        end
        
        -- Action button handlers
        mainFrame.contentFrames.list.loadButton:SetScript("OnClick", function()
            local selectedLoadout = mainFrame.contentFrames.list.selectedLoadout
            if selectedLoadout then
                LoadoutManager:LoadLoadout(selectedLoadout)
            else
                LoadoutManager:Print("Please select a loadout first.")
            end
        end)
        
        mainFrame.contentFrames.list.viewButton:SetScript("OnClick", function()
            local selectedLoadout = mainFrame.contentFrames.list.selectedLoadout
            if selectedLoadout then
                LoadoutManagerUI:ShowItemView(mainFrame, selectedLoadout)
            else
                LoadoutManager:Print("Please select a loadout first.")
            end
        end)
    end
    mainFrame.contentFrames.list:Show()
end
-- Hide the item view display
function LoadoutManagerUI:HideItemView(mainFrame)
    if mainFrame.contentFrames.list.itemViewFrame then
        mainFrame.contentFrames.list.itemViewFrame:Hide()
    end
end


-- Show items in the selected loadout
function LoadoutManagerUI:ShowItemView(mainFrame, loadoutName)
    local loadout = LoadoutManager.db.loadouts[loadoutName]
    if not loadout then
        LoadoutManager:Print("Error: Loadout not found.")
        return
    end
  
-- Create or reuse the item view frame
    local itemFrame = mainFrame.contentFrames.list.itemViewFrame
    if not itemFrame then
        itemFrame = CreateFrame("ScrollFrame", nil, mainFrame.contentFrames.list)
        itemFrame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        itemFrame:SetBackdropColor(0, 0, 0, 0.8)
    end
    
    -- Create or reuse the scroll child
    local scrollChild = mainFrame.contentFrames.list.scrollChild
    if not scrollChild then
        scrollChild = CreateFrame("Frame", nil, itemFrame)
        itemFrame:SetScrollChild(scrollChild)
    end
    
    -- Position item view on the RIGHT side, to the right of the loadout list
    itemFrame:SetPoint("TOPLEFT", mainFrame.contentFrames.list.loadoutListFrame, "TOPRIGHT", 10, 0)
    itemFrame:SetPoint("BOTTOMRIGHT", mainFrame.contentFrames.list, "BOTTOMRIGHT", -10, 40)
    itemFrame:SetWidth(200) -- Set a fixed width for the right panel
    
    scrollChild:SetWidth(180) -- Narrower to fit in right panel
        
    -- Create scrollbar if it doesn't exist
    local scrollBar = mainFrame.contentFrames.list.scrollBar
    if not scrollBar then
        scrollBar = CreateFrame("Slider", nil, itemFrame, "UIPanelScrollBarTemplate")
        scrollBar:SetPoint("TOPLEFT", itemFrame, "TOPRIGHT", 4, -16)
        scrollBar:SetPoint("BOTTOMLEFT", itemFrame, "BOTTOMRIGHT", 4, 16)
        scrollBar:SetMinMaxValues(0, 100)
        scrollBar:SetValueStep(1)
        scrollBar:SetValue(0)
        
        -- Enable mouse wheel scrolling on the scroll frame
        itemFrame:EnableMouseWheel(true)
        itemFrame:SetScript("OnMouseWheel", function(self, delta)
            local current = scrollBar:GetValue()
            local min, max = scrollBar:GetMinMaxValues()
            if delta > 0 then
                scrollBar:SetValue(math.max(min, current - 20))
            else
                scrollBar:SetValue(math.min(max, current + 20))
            end
        end)
        
        scrollBar:SetScript("OnValueChanged", function(self, value)
            itemFrame:SetVerticalScroll(value)
        end)
    end
		
        -- Store references
        mainFrame.contentFrames.list.itemViewFrame = itemFrame
        mainFrame.contentFrames.list.scrollChild = scrollChild
        mainFrame.contentFrames.list.scrollBar = scrollBar
        mainFrame.contentFrames.list.itemButtons = {}
        
        -- Create top pagination buttons
        local topPrevPage = CreateFrame("Button", nil, mainFrame.contentFrames.list, "UIPanelButtonTemplate")
        topPrevPage:SetWidth(80)
        topPrevPage:SetHeight(20)
        topPrevPage:SetPoint("TOPRIGHT", itemFrame, "TOPRIGHT", -10, 25)
        topPrevPage:SetText("< Prev")
        
        local topNextPage = CreateFrame("Button", nil, mainFrame.contentFrames.list, "UIPanelButtonTemplate")
        topNextPage:SetWidth(80)
        topNextPage:SetHeight(20)
        topNextPage:SetPoint("TOPRIGHT", itemFrame, "TOPRIGHT", -100, 25)
        topNextPage:SetText("Next >")
        
        -- Create bottom pagination buttons
        local bottomPrevPage = CreateFrame("Button", nil, mainFrame.contentFrames.list, "UIPanelButtonTemplate")
        bottomPrevPage:SetWidth(80)
        bottomPrevPage:SetHeight(20)
        bottomPrevPage:SetPoint("BOTTOMRIGHT", itemFrame, "BOTTOMRIGHT", -10, -25)
        bottomPrevPage:SetText("< Prev")
        
        local bottomNextPage = CreateFrame("Button", nil, mainFrame.contentFrames.list, "UIPanelButtonTemplate")
        bottomNextPage:SetWidth(80)
        bottomNextPage:SetHeight(20)
        bottomNextPage:SetPoint("BOTTOMRIGHT", itemFrame, "BOTTOMRIGHT", -100, -25)
        bottomNextPage:SetText("Next >")
		
        -- Store pagination buttons
        mainFrame.contentFrames.list.topPrevPage = topPrevPage
        mainFrame.contentFrames.list.topNextPage = topNextPage
        mainFrame.contentFrames.list.bottomPrevPage = bottomPrevPage
        mainFrame.contentFrames.list.bottomNextPage = bottomNextPage
		
    
    -- Get consolidated item list
    local itemList = LoadoutManagerUI:GetConsolidatedItemList(loadout)
    
    -- Update pagination
    LoadoutManagerUI:UpdateItemView(mainFrame, itemList)
    
    mainFrame.contentFrames.list.itemViewFrame:Show()
	
end

-- Get consolidated list of items (combine stacks of same item)
function LoadoutManagerUI:GetConsolidatedItemList(loadout)
    local itemTotals = {}
    local itemLinks = {}
    
    -- Consolidate items by itemID
    for bag = 0, 4 do
        if loadout.bags[bag] then
            local numSlots = GetContainerNumSlots(bag)
            if numSlots and numSlots > 0 then
                for slot = 1, numSlots do
                    local itemData = loadout.bags[bag][slot]
                    if itemData and itemData.itemID then
                        local itemID = itemData.itemID
                        local count = itemData.itemCount or 1
                        
                        if not itemTotals[itemID] then
                            itemTotals[itemID] = 0
                            itemLinks[itemID] = itemData.itemLink
                        end
                        itemTotals[itemID] = itemTotals[itemID] + count
                    end
                end
            end
        end
    end
    
    -- Convert to sorted list
    local itemList = {}
    for itemID, totalCount in pairs(itemTotals) do
        table.insert(itemList, {
            itemID = itemID,
            itemLink = itemLinks[itemID],
            totalCount = totalCount
        })
    end
    
    -- Sort by item name
    table.sort(itemList, function(a, b)
        local nameA = a.itemLink and a.itemLink:match("%[(.+)%]") or "Unknown"
        local nameB = b.itemLink and b.itemLink:match("%[(.+)%]") or "Unknown"
        return nameA < nameB
    end)
    
    return itemList
end

-- Update item view with pagination
function LoadoutManagerUI:UpdateItemView(mainFrame, itemList)
    local itemViewFrame = mainFrame.contentFrames.list.itemViewFrame
    local scrollChild = mainFrame.contentFrames.list.scrollChild
    local currentPage = mainFrame.contentFrames.list.currentPage or 1
    local itemsPerPage = 50
    
    -- Calculate pagination
    local totalPages = math.max(1, math.ceil(#itemList / itemsPerPage))
    local startIndex = ((currentPage - 1) * itemsPerPage) + 1
    local endIndex = math.min(startIndex + itemsPerPage - 1, #itemList)
    
    -- Hide all existing item buttons
    if mainFrame.contentFrames.list.itemButtons then
        for _, button in ipairs(mainFrame.contentFrames.list.itemButtons) do
            button:Hide()
        end
    else
        mainFrame.contentFrames.list.itemButtons = {}
    end
    
    -- Create/show item buttons for current page
    local yOffset = 0
    for i = startIndex, endIndex do
        local itemData = itemList[i]
        local buttonIndex = i - startIndex + 1
        
        local itemButton = mainFrame.contentFrames.list.itemButtons[buttonIndex]
		if not itemButton then
			itemButton = CreateFrame("Button", nil, scrollChild)
			itemButton:SetWidth(400)
			itemButton:SetHeight(20)
			itemButton:EnableMouse(true)
    
    -- Create icon texture
    local icon = itemButton:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(16)
    icon:SetHeight(16)
    icon:SetPoint("LEFT", itemButton, "LEFT", 2, 0)
    itemButton.icon = icon
    
    -- Create text for the button (positioned after icon)
    local text = itemButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    itemButton.text = text
    
    mainFrame.contentFrames.list.itemButtons[buttonIndex] = itemButton
end
        
      -- Set item info
local itemName = itemData.itemLink and itemData.itemLink:match("%[(.+)%]") or "Unknown Item"
itemButton.text:SetText(itemName .. " x" .. itemData.totalCount)
itemButton:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -yOffset)
itemButton.itemLink = itemData.itemLink

-- Set item icon
if itemData.itemLink then
    local itemTexture = GetItemIcon(itemData.itemID)
    if itemTexture then
        itemButton.icon:SetTexture(itemTexture)
        itemButton.icon:Show()
    else
        itemButton.icon:Hide()
    end
else
    itemButton.icon:Hide()
end
-- Tooltip handlers
itemButton:SetScript("OnEnter", function(self)
    if self.itemLink then
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetHyperlink(self.itemLink)
        GameTooltip:Show()
    end
end)
        
        itemButton:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)
        
        itemButton:Show()
        yOffset = yOffset + 22
    end
    
    -- Update scroll child height
    scrollChild:SetHeight(math.max(yOffset, itemViewFrame:GetHeight()))
    
    -- Update pagination buttons (TBC-compatible)
    local showPagination = totalPages > 1
    if showPagination and currentPage > 1 then
        mainFrame.contentFrames.list.topPrevPage:Show()
        mainFrame.contentFrames.list.bottomPrevPage:Show()
    else
        mainFrame.contentFrames.list.topPrevPage:Hide()
        mainFrame.contentFrames.list.bottomPrevPage:Hide()
    end

    if showPagination and currentPage < totalPages then
        mainFrame.contentFrames.list.topNextPage:Show()
        mainFrame.contentFrames.list.bottomNextPage:Show()
    else
        mainFrame.contentFrames.list.topNextPage:Hide()
        mainFrame.contentFrames.list.bottomNextPage:Hide()
    end
    -- Pagination button handlers
    local function updatePage(newPage)
        mainFrame.contentFrames.list.currentPage = newPage
        LoadoutManagerUI:UpdateItemView(mainFrame, itemList)
    end
    
    mainFrame.contentFrames.list.topPrevPage:SetScript("OnClick", function()
        updatePage(currentPage - 1)
    end)
    
    mainFrame.contentFrames.list.topNextPage:SetScript("OnClick", function()
        updatePage(currentPage + 1)
    end)
    
    mainFrame.contentFrames.list.bottomPrevPage:SetScript("OnClick", function()
        updatePage(currentPage - 1)
    end)
    
    mainFrame.contentFrames.list.bottomNextPage:SetScript("OnClick", function()
        updatePage(currentPage + 1)
    end)
    
    -- Reset scroll position
    itemViewFrame:SetVerticalScroll(0)
    mainFrame.contentFrames.list.scrollBar:SetValue(1)
end


-- Show delete loadout content in the content area
function LoadoutManagerUI:ShowDeleteContent(mainFrame)
    local contentArea = mainFrame.contentArea
    
    -- Create content frame if it doesn't exist
    if not mainFrame.contentFrames.delete then
        local deleteFrame = CreateFrame("Frame", nil, contentArea)
        deleteFrame:SetAllPoints(contentArea)
        
        -- Title
        local title = deleteFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetText("Delete Loadout")
        title:SetPoint("TOP", deleteFrame, "TOP", 0, -20)
        
        mainFrame.contentFrames.delete = deleteFrame
    end
    
    -- Get available loadouts
    local loadoutNames = {}
    if LoadoutManager and LoadoutManager.db and LoadoutManager.db.loadouts then
        for name in pairs(LoadoutManager.db.loadouts) do
            table.insert(loadoutNames, name)
        end
    end
    table.sort(loadoutNames)
    
    if #loadoutNames == 0 then
        -- Show "no loadouts" message
        if not mainFrame.contentFrames.delete.noLoadoutsText then
            local noLoadoutsText = mainFrame.contentFrames.delete:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            noLoadoutsText:SetText("No loadouts available to delete.")
            noLoadoutsText:SetPoint("CENTER", mainFrame.contentFrames.delete, "CENTER", 0, 0)
            mainFrame.contentFrames.delete.noLoadoutsText = noLoadoutsText
        end
        mainFrame.contentFrames.delete.noLoadoutsText:Show()
    else
        -- Hide "no loadouts" message if it exists
        if mainFrame.contentFrames.delete.noLoadoutsText then
            mainFrame.contentFrames.delete.noLoadoutsText:Hide()
        end
        
        -- Create dropdown selection if it doesn't exist
        if not mainFrame.contentFrames.delete.dropdownText then
            -- Label
            local label = mainFrame.contentFrames.delete:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            label:SetText("Select loadout to delete:")
            label:SetPoint("CENTER", mainFrame.contentFrames.delete, "CENTER", 0, 40)
            
            -- Dropdown text
            local dropdownText = mainFrame.contentFrames.delete:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            dropdownText:SetPoint("CENTER", mainFrame.contentFrames.delete, "CENTER", 0, 10)
            
            -- Previous button
            local prevButton = CreateFrame("Button", nil, mainFrame.contentFrames.delete, "UIPanelButtonTemplate")
            prevButton:SetWidth(30)
            prevButton:SetHeight(20)
            prevButton:SetPoint("RIGHT", dropdownText, "LEFT", -10, 0)
            prevButton:SetText("<")
            
            -- Next button
            local nextButton = CreateFrame("Button", nil, mainFrame.contentFrames.delete, "UIPanelButtonTemplate")
            nextButton:SetWidth(30)
            nextButton:SetHeight(20)
            nextButton:SetPoint("LEFT", dropdownText, "RIGHT", 10, 0)
            nextButton:SetText(">")
            
            -- Delete Button
            local deleteButton = CreateFrame("Button", nil, mainFrame.contentFrames.delete, "UIPanelButtonTemplate")
            deleteButton:SetWidth(80)
            deleteButton:SetHeight(25)
            deleteButton:SetPoint("CENTER", mainFrame.contentFrames.delete, "CENTER", 0, -40)
            deleteButton:SetText("Delete")
            
            -- Store references
            mainFrame.contentFrames.delete.dropdownText = dropdownText
            mainFrame.contentFrames.delete.prevButton = prevButton
            mainFrame.contentFrames.delete.nextButton = nextButton
            mainFrame.contentFrames.delete.deleteButton = deleteButton
        end
        
        -- Update dropdown with current loadouts
        local currentIndex = 1
        local selectedLoadout = loadoutNames[currentIndex]
        mainFrame.contentFrames.delete.dropdownText:SetText(selectedLoadout)
        
        mainFrame.contentFrames.delete.prevButton:SetScript("OnClick", function()
            currentIndex = currentIndex - 1
            if currentIndex < 1 then currentIndex = #loadoutNames end
            selectedLoadout = loadoutNames[currentIndex]
            mainFrame.contentFrames.delete.dropdownText:SetText(selectedLoadout)
        end)
        
        mainFrame.contentFrames.delete.nextButton:SetScript("OnClick", function()
            currentIndex = currentIndex + 1
            if currentIndex > #loadoutNames then currentIndex = 1 end
            selectedLoadout = loadoutNames[currentIndex]
            mainFrame.contentFrames.delete.dropdownText:SetText(selectedLoadout)
        end)
        
        mainFrame.contentFrames.delete.deleteButton:SetScript("OnClick", function()
            if selectedLoadout then
                LoadoutManager:DeleteLoadout(selectedLoadout)
                -- Refresh the delete content to update the list
                LoadoutManagerUI:ShowDeleteContent(mainFrame)
            end
        end)
end
    
    mainFrame.contentFrames.delete:Show()
end

-- Create simple UI frame
function LoadoutManagerUI:CreateFrame()
    if self.frame then
        self.frame:Show()
        return
    end

    -- Create the main frame (doubled size)
    local frame = CreateFrame("Frame", "LoadoutManagerUIFrame", UIParent)
    frame:SetWidth(600)
    frame:SetHeight(400)
    frame:SetPoint("CENTER", UIParent, "CENTER")
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 }
    })
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    
-- Keep keyboard disabled by default for key passthrough
frame:EnableKeyboard(false)
frame:SetFrameStrata("DIALOG")
frame.keyboardEnabled = false

-- Create invisible ESC capture button
local escButton = CreateFrame("Button", "LoadoutManagerESCButton", frame)
escButton:SetWidth(1)
escButton:SetHeight(1)
escButton:SetPoint("TOPLEFT", frame, "TOPLEFT", -100, -100) -- Position off-screen
escButton:Hide()
escButton:RegisterForClicks("AnyUp")

-- Function to manage keyboard state
frame.toggleKeyboard = function(enable)
    if enable and not frame.keyboardEnabled then
        frame:EnableKeyboard(true)
        frame.keyboardEnabled = true
        escButton:Hide() -- Hide ESC button when editbox has focus
    elseif not enable and frame.keyboardEnabled then
        frame:EnableKeyboard(false)
        frame.keyboardEnabled = false
        escButton:Show() -- Show ESC button when editbox loses focus
    end
end

-- Handle ESC key when keyboard is enabled (editbox focused)
frame:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then
        self:Hide()
    end
end)

-- Set up ESC key handling for when frame is shown but editbox not focused
frame:SetScript("OnShow", function(self)
    escButton:Show()
    escButton:EnableKeyboard(true)
    escButton:SetScript("OnKeyDown", function(btn, key)
        if key == "ESCAPE" then
            frame:Hide()
        end
    end)
end)

frame:SetScript("OnHide", function(self)
    escButton:Hide()
    escButton:EnableKeyboard(false)
    -- Make sure main frame keyboard is disabled when hiding
    self:EnableKeyboard(false)
    self.keyboardEnabled = false
end)

    -- Add title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetText("Loadout Manager")
    title:SetPoint("TOP", frame, "TOP", 0, -15)

    -- Add close button
    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
    closeButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    -- Create left side button container
    local buttonContainer = CreateFrame("Frame", nil, frame)
    buttonContainer:SetWidth(120)
    buttonContainer:SetHeight(320)
    buttonContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", 15, -40)

    -- Create content area frame
    local contentArea = CreateFrame("Frame", "LoadoutManagerContentArea", frame)
    contentArea:SetPoint("TOPLEFT", buttonContainer, "TOPRIGHT", 10, 0)
    contentArea:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -15, 15)
    contentArea:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    contentArea:SetBackdropColor(0, 0, 0, 0.25)

    -- Store references
    frame.buttonContainer = buttonContainer
    frame.contentArea = contentArea
    frame.activeButton = nil
    frame.contentFrames = {}

    -- Create tab buttons
    self:CreateTabButtons(frame)

    -- Set default active button to "Create" and show its content
    self:SetActiveButton(frame, frame.createButton)

    self.frame = frame
    frame:Show()
end

-- Toggle UI visibility
function LoadoutManagerUI:Toggle()
    if not self.frame then
        self:CreateFrame()
    elseif self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
    end
end

-- Create minimap button
function LoadoutManagerUI:CreateMinimapButton()
    if self.minimapButton then
        return -- Already created
    end
    
    local button = CreateFrame("Button", "LoadoutManagerMinimapButton", Minimap)
    button:SetWidth(31)
    button:SetHeight(31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    
    -- Create the button texture
    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_08") -- Bag icon
    icon:SetPoint("TOPLEFT", 7, -5)
    
    -- Create the border
    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetWidth(53)
    overlay:SetHeight(53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")
    
    -- Position the button
    button:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 100, -100)
    
    -- Click handler
    button:SetScript("OnClick", function(self, clickType)
        if clickType == "LeftButton" then
            LoadoutManagerUI:Toggle()
        end
    end)
    
    -- Tooltip
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("LoadoutManager")
        GameTooltip:AddLine("Left-click: Open interface", 1, 1, 1)
        GameTooltip:Show()
    end)
    
    button:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
    
    self.minimapButton = button
    LoadoutManager:Print("Minimap button created!")
end

-- FIXED: Single function to toggle the loadout list display
function LoadoutManagerUI:ToggleLoadoutList(listButton, parentFrame)


    -- Ensure the loadout list table exists
    if not listButton.loadoutList then
        listButton.loadoutList = {}
    end
    
    -- If the list is currently expanded, collapse it
    if listButton.isExpanded then
        -- Collapse the list
        listButton:SetText("+ View Loadout List")
        for _, text in ipairs(listButton.loadoutList) do
            text:Hide()
        end
        listButton.isExpanded = false
        return
    end

    -- If the list is not expanded, show it
    listButton:SetText("- Hide Loadout List")
    
    -- Get loadout names
    local loadoutNames = {}
    if LoadoutManager.db and LoadoutManager.db.loadouts then
        for name in pairs(LoadoutManager.db.loadouts) do
            table.insert(loadoutNames, name)
        end
    end
    table.sort(loadoutNames)
    
    -- Clear previous list items to prevent duplication
    for _, text in ipairs(listButton.loadoutList) do
        text:Hide()
    end
    
    -- Create or reuse text elements for each loadout
    local lastText
    for i, name in ipairs(loadoutNames) do
        local text = listButton.loadoutList[i]
        if not text then
            -- Create new text element on the parent frame
            text = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            listButton.loadoutList[i] = text
        end
        
        text:SetText(name)
        
        if lastText then
            text:SetPoint("TOPLEFT", lastText, "BOTTOMLEFT", 0, -2)
        else
            text:SetPoint("TOPLEFT", listButton, "BOTTOMLEFT", 10, -5)
        end
        text:Show()
        lastText = text
    end
    
    -- If no loadouts exist, show a message
    if #loadoutNames == 0 then
        local text = listButton.loadoutList[1]
        if not text then
            text = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            listButton.loadoutList[1] = text
        end
        text:SetText("No loadouts saved yet.")
        text:SetPoint("TOPLEFT", listButton, "BOTTOMLEFT", 10, -5)
        text:Show()
    end
    
    listButton.isExpanded = true
end

function LoadoutManager:OnEvent(event, ...)
    local arg1 = select(1, ...)
    if event == "ADDON_LOADED" and arg1 == "LoadoutManager" then
        -- Initialize database IMMEDIATELY when addon loads
        self:InitializeDatabase()
        self:RegisterSlashCommands()
        self:Print("LoadoutManager loaded and database initialized!")
        -- Initialize minimap button
        LoadoutManagerUI:CreateMinimapButton()
	
    elseif event == "PLAYER_LOGIN" then
        -- Just confirm we're ready after login
        self:Print("LoadoutManager ready! Type /loadout help for commands.")
        
    elseif event == "BAG_UPDATE" and self.isProcessing then
        -- This event means a bag or bank update has happened, so we can process the next move.
        self:ProcessNextMoveInQueue()
    elseif event == "BANKFRAME_OPENED" then
        self:Print("Personal bank opened. Caching contents...")
        self:ScanPersonalBank()
    elseif event == "BANKFRAME_CLOSED" then
        self.bankCache = {}
        self:Print("Personal bank closed.")
    elseif event == "GUILDBANKFRAME_CLOSED" then
        self.guildBankCache = {}
        self:Print("Guild bank closed.")
    end
end

-- Save current bag state as a loadout
-- Save current bag state as a loadout
function LoadoutManager:SaveCurrentLoadout(name)
    if not name or name == "" then
        self:Print("Please provide a name for the loadout.")
        return
    end
    
    -- Ensure database is properly initialized
    if not LoadoutManagerDB then
        self:Print("ERROR: SavedVariables not initialized!")
        return
    end
    
    self:Print("DEBUG: Starting to save loadout '" .. name .. "'")
    
    local loadout = {
        name = name,
        bags = {},
        timestamp = time(),
    }
    
    -- Scan all bags (0-4)
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            loadout.bags[bag] = {}
            for slot = 1, numSlots do
                local itemLink = GetContainerItemLink(bag, slot)
                local _, itemCount = GetContainerItemInfo(bag, slot)
                
                if itemLink then
                    local itemID = self:GetItemIDFromLink(itemLink)
                    if itemID then -- Check if itemID is valid
                        loadout.bags[bag][slot] = {
                            itemLink = itemLink,
                            itemCount = itemCount or 1,
                            itemID = itemID
                        }
                    end
                end
            end
        end
    end
    
    -- Save ONLY to LoadoutManagerDB (self.db points to it)
    LoadoutManagerDB.loadouts[name] = loadout
    
    self:Print("DEBUG: Saved to LoadoutManagerDB")
    self:Print("DEBUG: LoadoutManagerDB now has " .. self:CountLoadouts() .. " loadouts")
    self:Print("Loadout '" .. name .. "' saved with " .. self:CountLoadoutItems(loadout) .. " items.")
end

-- Load and apply a loadout
function LoadoutManager:LoadLoadout(name)
    if not name or name == "" then
        self:Print("Please provide a loadout name to load.")
        return
    end

    local loadout = self.db.loadouts[name]
    if not loadout then
        self:Print("Loadout '" .. name .. "' not found.")
        return
    end

    if self.isProcessing then
        self:Print("Already processing a loadout. Please wait.")
        return
    end

    -- Clear previous logs and state
    self.errorLog = {}
    self.withdrawalLog = {}
    self.moveQueue = {}
    self.currentLoadout = loadout

    self:Print("Loading loadout '" .. name .. "'...")

    -- Check for open bank frames and scan them if available
    if BankFrame and BankFrame:IsShown() then
        self:ScanPersonalBank()
    end
    if GuildBankFrame and GuildBankFrame:IsShown() then
        -- This is the new part
        self:ScanGuildBank()
    end

    -- First, build the queue of required moves
    self:BuildMoveQueue()

    if #self.moveQueue == 0 then
        self:Print("Your bags already match the loadout. No action needed.")
        return
    end

    self.isProcessing = true
    self:ProcessNextMoveInQueue()
end

-- New function to build the move queue before starting
function LoadoutManager:BuildMoveQueue()
    -- Step 1: Find items in player's bags that need to be moved out of the way.
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local currentItem = GetContainerItemLink(bag, slot)
                local targetData = self.currentLoadout.bags[bag] and self.currentLoadout.bags[bag][slot]
                
                -- Check if slot is occupied and should be empty, or has the wrong item
                if currentItem and (not targetData or self:GetItemIDFromLink(currentItem) ~= targetData.itemID) then
                    local freeSlot = self:FindFreeSlot()
                    if freeSlot then
                        table.insert(self.moveQueue, {
                            type = "move",
                            source = { bag = bag, slot = slot },
                            target = { bag = freeSlot.bag, slot = freeSlot.slot }
                        })
                    else
                        self:Print("ERROR: Not enough free slots to clear bags for loadout. Aborting.")
                        self.isProcessing = false
                        return
                    end
                end
            end
        end
    end

    -- Step 2: Add required items to the queue
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local targetData = self.currentLoadout.bags[bag] and self.currentLoadout.bags[bag][slot]
                local currentItem = GetContainerItemLink(bag, slot)
                
                if targetData then
                    -- If the slot is empty or has the wrong item, find the right item
                    if not currentItem or self:GetItemIDFromLink(currentItem) ~= targetData.itemID then
                        local sourceInfo = self:FindItem(targetData.itemID, targetData.itemCount)
                        if sourceInfo then
                            table.insert(self.moveQueue, {
                                type = "move",
                                source = sourceInfo,
                                target = { bag = bag, slot = slot },
                                count = targetData.itemCount
                            })
                        else
                            table.insert(self.errorLog, "Could not find " .. targetData.itemCount .. "x " .. targetData.itemLink)
                        end
                    end
                end
            end
        end
    end
end


-- New function to process the queue one item at a time
function LoadoutManager:ProcessNextMoveInQueue()
    if not self.isProcessing then
        return
    end

    -- If the queue is empty, we're done
    if #self.moveQueue == 0 then
        self:GenerateCompletionReport()
        self.isProcessing = false
        self.currentLoadout = nil
        self:Print("Loadout application complete!")
        return
    end

    local move = table.remove(self.moveQueue, 1)

    -- Handle the different move types
if move.type == "split_and_bank" or move.type == "combine_stacks" then
    self:ProcessSpecialMove(move)
elseif move.source.source == "guildbank" then
    self:WithdrawFromGuildBank(move.source, move.target, move.count)
elseif move.source.source == "personalbank" then
    self:MoveItem(move.source.bag, move.source.slot, move.target.bag, move.target.slot, move.count)
else -- Source is a bag
    self:MoveItem(move.source.bag, move.source.slot, move.target.bag, move.target.slot, move.count)
    end
end

-- Handle special move types (excess and stack combining)
function LoadoutManager:ProcessSpecialMove(move)
    if move.type == "split_and_bank" then
        -- Split stack and move excess to bank
        self:Print("Moving excess " .. move.excessCount .. " items to bank...")
        
        -- Pick up the entire stack
        PickupContainerItem(move.source.bag, move.source.slot)
        
        -- Split off the excess amount
        SplitContainerItem(move.source.bag, move.source.slot, move.excessCount)
        
        -- Move excess to bank (requires bank to be open)
        if BankFrame and BankFrame:IsShown() then
            -- Find empty bank slot and place excess there
            local bankSlot = self:FindEmptyBankSlot()
            if bankSlot then
                PickupContainerItem(bankSlot.bag, bankSlot.slot)
            else
                self:Print("ERROR: No empty bank slots for excess items.")
            end
        else
            self:Print("ERROR: Bank must be open to store excess items.")
        end
        
    elseif move.type == "combine_stacks" then
        -- Combine stacks to reach target quantity
        self:Print("Combining stacks to reach target quantity...")
        
        -- Pick up source stack
        if move.source.source == "guildbank" then
            PickupGuildBankItem(move.source.tab, move.source.slot)
        else
            PickupContainerItem(move.source.bag, move.source.slot)
        end
        
        -- Place on target to combine (TBC-compatible timer)
        self:CreateTimer(0.1, function()
            PickupContainerItem(move.target.bag, move.target.slot)
        end)
    end
end


-- Move item from one location to another (with specific pickup/place logic)
function LoadoutManager:MoveItem(sourceBag, sourceSlot, targetBag, targetSlot, count)
    -- This function now just handles bag-to-bag and bank-to-bag moves
    if sourceBag == -1 then -- Personal bank
        self:Print("Withdrawing from personal bank.")
        PickupContainerItem(sourceBag, sourceSlot)
    else -- Bags
        self:Print("Moving item from bag " .. sourceBag .. " slot " .. sourceSlot)
        PickupContainerItem(sourceBag, sourceSlot)
    end
    
    -- Drop the item in the target slot (TBC-compatible timer)
    self:CreateTimer(0.1, function()
        PickupContainerItem(targetBag, targetSlot)
        -- The BAG_UPDATE event will trigger the next move
    end)
end

-- Withdraw from guild bank (simplified without timers)
function LoadoutManager:WithdrawFromGuildBank(sourceInfo, targetInfo, count)
    -- Pick up the item from guild bank
    PickupGuildBankItem(sourceInfo.tab, sourceInfo.slot)
    
    -- Immediately place it in the target bag slot
    PickupContainerItem(targetInfo.bag, targetInfo.slot)
    
    -- Log the withdrawal
    table.insert(self.withdrawalLog, "Withdrew item from guild bank tab " .. sourceInfo.tab .. " slot " .. sourceInfo.slot)
    
    -- The BAG_UPDATE event will trigger ProcessNextMoveInQueue automatically
end

-- Scan guild bank contents (simplified for single tab)
function LoadoutManager:ScanGuildBank()
    self.guildBankCache = {}
    local currentTab = GetCurrentGuildBankTab()
    if not currentTab then
        self:Print("Error: Could not determine current guild bank tab.")
        return
    end

    local tabName = GetGuildBankTabInfo(currentTab)
    self:Print("Scanning current guild bank tab: " .. tabName .. "...")

    -- Scan the current tab's contents (no timers needed)
    for slot = 1, 98 do
        local itemLink = GetGuildBankItemLink(currentTab, slot)
        if itemLink then
            local _, itemCount = GetGuildBankItemInfo(currentTab, slot)
            local itemID = self:GetItemIDFromLink(itemLink)
            if itemID then
                if not self.guildBankCache[itemID] then 
                    self.guildBankCache[itemID] = {} 
                end
                table.insert(self.guildBankCache[itemID], {
                    tab = currentTab,
                    slot = slot,
                    count = itemCount or 1,
                    link = itemLink
                })
            end
        end
    end

    self:Print("Scanned tab: " .. tabName .. ". Found " .. self:CountCachedItems(self.guildBankCache) .. " item stacks.")
end

-- Generate completion report for loadout operation
function LoadoutManager:GenerateCompletionReport()
    local totalErrors = #self.errorLog
    local totalWithdrawals = #self.withdrawalLog
    
    if totalErrors == 0 then
        self:Print("Loadout complete!")
        if totalWithdrawals > 0 then
            self:Print("Withdrew " .. totalWithdrawals .. " items from bank.")
        end
    else
        -- Count successful items vs missing items
        local loadoutItemCount = self:CountLoadoutItems(self.currentLoadout)
        local foundItems = loadoutItemCount - totalErrors
        
        self:Print("Found " .. foundItems .. "/" .. loadoutItemCount .. " items. Unable to locate:")
        
        -- List missing items
        for _, errorMsg in ipairs(self.errorLog) do
            self:Print("  " .. errorMsg)
        end
    end
end

-- Scan personal bank contents
function LoadoutManager:ScanPersonalBank()
    self.bankCache = {}

    -- Scan main bank slots (-1)
    local function scanMainBankSlots(slot)
        if not BankFrame or not BankFrame:IsShown() then return end
        if slot > GetContainerNumSlots(-1) then
            -- Done scanning main bank, now start on bank bags
            LoadoutManager:scanBankBags(5, 1)
            return
        end
        
        local itemLink = GetContainerItemLink(-1, slot)
        if itemLink then
            local _, itemCount = GetContainerItemInfo(-1, slot)
            local itemID = LoadoutManager:GetItemIDFromLink(itemLink)
            if not LoadoutManager.bankCache[itemID] then LoadoutManager.bankCache[itemID] = {} end
            table.insert(LoadoutManager.bankCache[itemID], {
                bag = -1,
                slot = slot,
                count = itemCount or 1,
                link = itemLink
            })
        end
        
        -- TBC-compatible timer
        LoadoutManager:CreateTimer(0.01, function() scanMainBankSlots(slot + 1) end)
    end
    
    -- Scan bank bags (5-11)
    function self:scanBankBags(bag, slot)
        if not BankFrame or not BankFrame:IsShown() then return end
        if bag > 11 then
            -- Done scanning all bank contents
            self:Print("Scanned personal bank: " .. self:CountCachedItems(self.bankCache) .. " item stacks found.")
            return
        end
        
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            local itemLink = GetContainerItemLink(bag, slot)
            if itemLink then
                local _, itemCount = GetContainerItemInfo(bag, slot)
                local itemID = self:GetItemIDFromLink(itemLink)
                if not self.bankCache[itemID] then self.bankCache[itemID] = {} end
                table.insert(self.bankCache[itemID], {
                    bag = bag,
                    slot = slot,
                    count = itemCount or 1,
                    link = itemLink
                })
            end
            
            slot = slot + 1
            if slot > numSlots then
                slot = 1
                bag = bag + 1
            end
        else
            -- Skip to the next bag if the current one is empty
            bag = bag + 1
            slot = 1
        end
        
        -- TBC-compatible timer
        self:CreateTimer(0.01, function() self:scanBankBags(bag, slot) end)
    end
    
    scanMainBankSlots(1) -- Start the scan
end

-- Helper to count cached items
function LoadoutManager:CountCachedItems(cache)
    local count = 0
    for _, stacks in pairs(cache) do
        count = count + #stacks
    end
    return count
end

-- Find item in bags, guild bank, or personal bank
function LoadoutManager:FindItem(itemID, requiredCount)
    -- Bags first
    local bagResult = self:FindItemInBags(itemID, requiredCount)
    if bagResult then return { source = "bag", bag = bagResult.bag, slot = bagResult.slot, count = bagResult.count } end
    
    -- Guild bank
    local guildBankResult = self:FindItemInGuildBank(itemID, requiredCount)
    if guildBankResult then return { source = "guildbank", tab = guildBankResult.tab, slot = guildBankResult.slot, count = guildBankResult.count } end
    
    -- Personal bank
    local personalBankResult = self:FindItemInPersonalBank(itemID, requiredCount)
    if personalBankResult then return { source = "personalbank", bag = personalBankResult.bag, slot = personalBankResult.slot, count = personalBankResult.count } end
    
    return nil
end

-- New function to find a truly empty bag slot
function LoadoutManager:FindFreeSlot()
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                if not GetContainerItemLink(bag, slot) then
                    return { bag = bag, slot = slot }
                end
            end
        end
    end
    return nil
end

-- Find empty bank slot
function LoadoutManager:FindEmptyBankSlot()
    -- Check main bank slots first
    local numBankSlots = GetContainerNumSlots(-1)
    if numBankSlots and numBankSlots > 0 then
        for slot = 1, numBankSlots do
            if not GetContainerItemLink(-1, slot) then
                return { bag = -1, slot = slot }
            end
        end
    end
    
    -- Check bank bags (5-11)
    for bag = 5, 11 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                if not GetContainerItemLink(bag, slot) then
                    return { bag = bag, slot = slot }
                end
            end
        end
    end
    
    return nil
end

-- Helper function to extract item ID from item link
-- Item links in TBC look like: |cff9d9d9d|Hitem:25:0:0:0:0:0:0:0|h[Worn Shortsword]|h|r
-- We need to extract the first number after "Hitem:"
function LoadoutManager:GetItemIDFromLink(itemLink)
    if not itemLink or type(itemLink) ~= "string" then
        return nil
    end
    
    -- Pattern to match item ID from item link
    -- The pattern looks for "Hitem:" followed by digits, then captures those digits
    local itemID = itemLink:match("Hitem:(%d+)")
    
    if itemID then
        return tonumber(itemID)
    end
    
    return nil
end

-- Helper function to count total items in a loadout
function LoadoutManager:CountLoadoutItems(loadout)
    local count = 0
    
    if not loadout or not loadout.bags then
        return count
    end
    
    for bag = 0, 4 do
        if loadout.bags[bag] then
            -- Get the number of slots for this bag to iterate properly
            local numSlots = GetContainerNumSlots(bag)
            if numSlots and numSlots > 0 then
                for slot = 1, numSlots do
                    local itemData = loadout.bags[bag][slot]
                    if itemData and itemData.itemID then
                        count = count + (itemData.itemCount or 1)
                    end
                end
            end
        end
    end
    
    return count
end

-- Helper function to find an item in player's bags
function LoadoutManager:FindItemInBags(itemID, requiredCount)
    if not itemID then
        return nil
    end
    
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local itemLink = GetContainerItemLink(bag, slot)
                if itemLink then
                    local foundItemID = self:GetItemIDFromLink(itemLink)
                    if foundItemID == itemID then
                        local _, itemCount = GetContainerItemInfo(bag, slot)
                        itemCount = itemCount or 1
                        
                        -- If we found enough or more, return this location
                        if itemCount >= (requiredCount or 1) then
                            return { bag = bag, slot = slot, count = itemCount }
                        end
                    end
                end
            end
        end
    end
    
    return nil
end

-- Helper function to find an item in guild bank cache
function LoadoutManager:FindItemInGuildBank(itemID, requiredCount)
    if not itemID or not self.guildBankCache[itemID] then
        return nil
    end
    
    -- Look through cached guild bank items for this itemID
    for _, itemInfo in pairs(self.guildBankCache[itemID]) do
        if itemInfo.count >= (requiredCount or 1) then
            return { tab = itemInfo.tab, slot = itemInfo.slot, count = itemInfo.count }
        end
    end
    
    return nil
end

-- Helper function to find an item in personal bank cache
function LoadoutManager:FindItemInPersonalBank(itemID, requiredCount)
    if not itemID or not self.bankCache[itemID] then
        return nil
    end
    
    -- Look through cached personal bank items for this itemID
    for _, itemInfo in pairs(self.bankCache[itemID]) do
        if itemInfo.count >= (requiredCount or 1) then
            return { bag = itemInfo.bag, slot = itemInfo.slot, count = itemInfo.count }
        end
    end
    
    return nil
end

-- Delete a loadout
function LoadoutManager:DeleteLoadout(name)
    if not name or name == "" then
        self:Print("Please provide a loadout name to delete.")
        return
    end

    if not self.db.loadouts[name] then
        self:Print("Loadout '" .. name .. "' not found.")
        return
    end

    self.db.loadouts[name] = nil
    self:Print("Loadout '" .. name .. "' deleted.")
end

-- -----------------------------------------------------------------------
-- FINAL INITIALIZATION
-- This part must be at the very, very end of the file.
-- -----------------------------------------------------------------------

-- Initialize saved variables immediately upon file load.
-- This ensures the database is set up before any events fire.
--added initialization with debug prints
function LoadoutManager:InitializeDatabase()
    self:Print("DEBUG: Initializing database...")
    
    -- Ensure LoadoutManagerDB exists
    if not LoadoutManagerDB then
        self:Print("DEBUG: Creating new LoadoutManagerDB")
        LoadoutManagerDB = {
            loadouts = {},
            settings = {
                autoSort = true,
                verbose = false,
            }
        }
    else
        self:Print("DEBUG: Found existing LoadoutManagerDB")
        -- Ensure structure exists
        if not LoadoutManagerDB.loadouts then
            LoadoutManagerDB.loadouts = {}
        end
        if not LoadoutManagerDB.settings then
            LoadoutManagerDB.settings = {
                autoSort = true,
                verbose = false,
            }
        end
    end
    
    -- Point self.db directly to the saved variable
    self.db = LoadoutManagerDB
    
    self:Print("DEBUG: Database initialization complete")
    self:Print("DEBUG: Loadouts found: " .. self:CountLoadouts())
end

-- Helper function to count loadouts
function LoadoutManager:CountLoadouts()
    local count = 0
    self:Print("DEBUG: CountLoadouts - checking self.db.loadouts")
    if self.db and self.db.loadouts then
        for name, loadout in pairs(self.db.loadouts) do
            self:Print("DEBUG: Found loadout: " .. name)
            count = count + 1
        end
    else
        self:Print("DEBUG: self.db.loadouts is nil or doesn't exist")
    end
    return count
end

-- The code that runs when the file is parsed by WoW
LoadoutManager:OnLoad()