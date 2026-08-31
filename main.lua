-- ============================================
-- CONFIGURATION
-- ============================================
local CONFIG = {
    URLs = {
        crazyRewards = "https://raw.githubusercontent.com/OllieIOW/hcr2eventdata/refs/heads/main/crazyRewards.json",
        freeRewards = "https://raw.githubusercontent.com/OllieIOW/hcr2eventdata/refs/heads/main/freeRewards.json",
        carRewards = "https://raw.githubusercontent.com/OllieIOW/hcr2eventdata/refs/heads/main/carRewards.json"
    },
    patches = {
        patchCrazyRewards = true,
        patchFreeRewards = false,
        patchFixed = false,
        patchCarRewards = false,
    },
    pivotDownloadURL = "https://github.com/vekendianorg/pivot/releases/tag/v1.4"
}

-- ============================================
-- INITIALIZATION
-- ============================================
local Shell = nil
local Crypto = nil

local function showPivotGGRequiredError(msg)
    local text =
        "This script requires Pivot GG by Vekendian.\n\n" ..
        msg .. "\n\n" ..
        "How to use:\n" ..
        "1. Download Pivot GG from the link.\n" ..
        "2. Install and open Pivot GG.\n" ..
        "3. Run this script inside Pivot GG.\n" ..
        "4. Grant it root access when prompted.\n\n" ..
        "Press the button below to copy the download link."

    if gg.alert(text, "Copy Download Link", "OK") == 1 then
        gg.copyText(CONFIG.pivotDownloadURL)
    end
end

-- Check For PivotGG
if type(luajava) ~= "table" then
    showPivotGGRequiredError("LuaJava was not detected. Are you using Pivot GG?")
    return
end

-- Load Shell + Crypto
Shell = import("org.vekendian.Shell")
Crypto = import("org.vekendian.Crypto")

local function checkRootAccess()
    local result = Shell.su("id")
    if not result then
        return false, "Shell.su() failed."
    end
    return result:find("uid=0") ~= nil, result
end

-- Check For Root
local hasRootAccess = checkRootAccess()
if not hasRootAccess then
    gg.alert("This script requires root. You are currently not running as root!")
    return true
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function executeInGameNamespace(command)
    local info = gg.getTargetInfo()
    if not info or not info.pid then
        return nil
    end
    return Shell.su("nsenter -t " .. info.pid .. " -m -- " .. command)
end

local function checkFileExists(path)
    local result = executeInGameNamespace(
        '[ -f "' .. path .. '" ] && echo yes || echo no'
    )
    return result and result:match("^%s*yes%s*$") ~= nil
end

local function findJsonArrayBounds(data, startPos)
    local depth = 0
    local inString = false
    local escaped = false
    
    for i = startPos, #data do
        local c = data:sub(i, i)
        
        if inString then
            if escaped then
                escaped = false
            elseif c == "\\" then
                escaped = true
            elseif c == '"' then
                inString = false
            end
        else
            if c == '"' then
                inString = true
            elseif c == "[" then
                depth = depth + 1
            elseif c == "]" then
                depth = depth - 1
                if depth == 0 then
                    return i
                end
            end
        end
    end
    return nil
end

local function findJsonObjectBounds(data, startPos)
    local depth = 0
    local inString = false
    local escaped = false
    
    for i = startPos, #data do
        local c = data:sub(i, i)
        
        if inString then
            if escaped then
                escaped = false
            elseif c == "\\" then
                escaped = true
            elseif c == '"' then
                inString = false
            end
        else
            if c == '"' then
                inString = true
            elseif c == "{" then
                depth = depth + 1
            elseif c == "}" then
                depth = depth - 1
                if depth == 0 then
                    return i
                end
            end
        end
    end
    return nil
end

local function findJsonValueBounds(data, keyStart)
    -- Try to find array value
    local valueStart = data:find("[", keyStart, true)
    local valueEnd = nil
    
    if valueStart then
        valueEnd = findJsonArrayBounds(data, valueStart)
    end
    
    -- Try object if array not found
    if not valueEnd then
        valueStart = data:find("{", keyStart, true)
        if valueStart then
            valueEnd = findJsonObjectBounds(data, valueStart)
        end
    end
    
    return valueStart, valueEnd
end

local function removeKeyValuePair(data, keyStart, valueEnd)
    local removeStart = keyStart
    local removeEnd = valueEnd
    
    -- Include whitespace after the value
    while data:sub(removeEnd + 1, removeEnd + 1):match("%s") do
        removeEnd = removeEnd + 1
    end
    
    -- Prefer removing the comma AFTER the value
    if data:sub(removeEnd + 1, removeEnd + 1) == "," then
        removeEnd = removeEnd + 1
    else
        -- Otherwise remove the comma BEFORE the key
        local beforeKey = removeStart - 1
        while data:sub(beforeKey, beforeKey):match("%s") do
            beforeKey = beforeKey - 1
        end
        if data:sub(beforeKey, beforeKey) == "," then
            removeStart = beforeKey
        end
    end
    
    return data:sub(1, removeStart - 1) .. data:sub(removeEnd + 1)
end

local function replaceJsonValues(data, replacements)
    for _, replacement in ipairs(replacements) do
        local key = replacement.key
        local replacementData = replacement.data
        
        -- Find target key
        local targetKeyStart = data:find('"' .. key .. '"')
        if not targetKeyStart then
            return nil, key .. " not found in target data"
        end
        
        -- Find target value bounds
        local targetValueStart, targetValueEnd = findJsonValueBounds(data, targetKeyStart)
        if not targetValueStart or not targetValueEnd then
            return nil, key .. " value not found in target data"
        end
        
        -- If replacement is nil, remove the entire key/value
        if replacementData == nil then
            data = removeKeyValuePair(data, targetKeyStart, targetValueEnd)
        else
            -- Get replacement value from replacementData
            local replacementStart = replacementData:find('"' .. key .. '"')
            if not replacementStart then
                return nil, key .. " not found in replacement data"
            end
            
            local replacementValueStart, replacementValueEnd = findJsonValueBounds(replacementData, replacementStart)
            if not replacementValueStart or not replacementValueEnd then
                return nil, key .. " value not found in replacement data"
            end
            
            local replacementValue = replacementData:sub(replacementValueStart, replacementValueEnd)
            
            -- Replace the entire old value
            data = data:sub(1, targetValueStart - 1) .. replacementValue .. data:sub(targetValueEnd + 1)
        end
    end
    
    return data
end

-- ============================================
-- JSON MERGE FUNCTIONALITY
-- ============================================

local function extractJsonValue(data, key)
    local keyStart = data:find('"' .. key .. '"')
    if not keyStart then
        return nil
    end
    
    local valueStart, valueEnd = findJsonValueBounds(data, keyStart)
    if not valueStart or not valueEnd then
        return nil
    end
    
    return data:sub(valueStart, valueEnd)
end

local function mergeJsonArrays(array1, array2)
    -- Extract array contents (remove brackets)
    local content1 = array1:sub(2, -2)
    local content2 = array2:sub(2, -2)
    
    -- Check if both are empty
    if content1:match("^%s*$") and content2:match("^%s*$") then
        return "[]"
    end
    
    -- Check if one is empty
    if content1:match("^%s*$") then
        return array2
    end
    if content2:match("^%s*$") then
        return array1
    end
    
    -- Merge arrays by concatenating contents
    local mergedContent = content1 .. "," .. content2
    return "[" .. mergedContent .. "]"
end

local function mergeJsonObjects(obj1, obj2)
    -- Extract object contents (remove braces)
    local content1 = obj1:sub(2, -2)
    local content2 = obj2:sub(2, -2)
    
    -- Check if both are empty
    if content1:match("^%s*$") and content2:match("^%s*$") then
        return "{}"
    end
    
    -- Check if one is empty
    if content1:match("^%s*$") then
        return obj2
    end
    if content2:match("^%s*$") then
        return obj1
    end
    
    -- Parse objects to find duplicate keys
    local keys1 = {}
    local keys2 = {}
    
    -- Extract keys from first object
    for key in content1:gmatch('"([^"]+)"%s*:') do
        keys1[key] = true
    end
    
    -- Extract keys from second object
    for key in content2:gmatch('"([^"]+)"%s*:') do
        keys2[key] = true
    end
    
    -- Find duplicate keys
    local duplicateKeys = {}
    for key in pairs(keys1) do
        if keys2[key] then
            table.insert(duplicateKeys, key)
        end
    end
    
    -- If no duplicates, simple concatenation
    if #duplicateKeys == 0 then
        local mergedContent = content1 .. "," .. content2
        return "{" .. mergedContent .. "}"
    end
    
    -- Handle duplicates by merging their values
    local mergedContent = content2
    for _, dupKey in ipairs(duplicateKeys) do
        local value1 = extractJsonValue(obj1, dupKey)
        local value2 = extractJsonValue(obj2, dupKey)
        
        if value1 and value2 then
            local mergedValue = nil
            
            -- Merge based on type
            if value1:sub(1,1) == "[" and value2:sub(1,1) == "[" then
                mergedValue = mergeJsonArrays(value1, value2)
            elseif value1:sub(1,1) == "{" and value2:sub(1,1) == "{" then
                mergedValue = mergeJsonObjects(value1, value2)
            else
                -- For primitive values, prefer the second one
                mergedValue = value2
            end
            
            if mergedValue then
                -- Replace value in merged content
                local keyPattern = '"' .. dupKey .. '"%s*:%s*%b[]'
                if not mergedContent:find(keyPattern) then
                    keyPattern = '"' .. dupKey .. '"%s*:%s*%b{}'
                end
                mergedContent = mergedContent:gsub(keyPattern, '"' .. dupKey .. '":' .. mergedValue, 1)
            end
        end
    end
    
    return "{" .. mergedContent .. "}"
end

local function mergeJsonData(data1, data2)
    -- Simple merge for when both are arrays
    if data1:sub(1,1) == "[" and data2:sub(1,1) == "[" then
        return mergeJsonArrays(data1, data2)
    end
    
    -- Merge for objects
    if data1:sub(1,1) == "{" and data2:sub(1,1) == "{" then
        return mergeJsonObjects(data1, data2)
    end
    
    -- If types don't match, prefer the second one
    return data2
end

local function getCurrentUserId()
    local result = Shell.su("cmd activity get-current-user")
    if not result then
        return nil
    end
    return tonumber(result:match("(%d+)"))
end

local function getEventsDirectoryPath()
    local info = gg.getTargetInfo()
    if not info or not info.dataDir then
        return nil
    end
    return info.dataDir .. "/files/content_cache/json/events/"
end

local function getActiveEventFileName()
    local filePath = getEventsDirectoryPath() .. "active_events.json"
    local tempPath = gg.EXT_FILES_DIR .. "/temp/active_events.json"
    local outputPath = gg.EXT_FILES_DIR .. "/temp/active_events_decrypted.json"
    
    executeInGameNamespace('mkdir -p "' .. gg.EXT_FILES_DIR .. '/temp"')
    
    -- Copy the original file to a temporary location
    local copySuccess = executeInGameNamespace('cp "' .. filePath .. '" "' .. tempPath .. '"')
    if not copySuccess then
        gg.alert("Failed to copy active_events.json")
        return nil
    end
    
    -- Decrypt the temporary copy
    local decryptedContents = Crypto.decrypt(tempPath, outputPath)
    
    -- Remove the temporary copy
    os.remove(tempPath)
    
    if not decryptedContents then
        gg.alert("Decryption failed")
        return nil
    end
    
    gg.toast("Decrypted JSON saved to:\n" .. outputPath)
    
    local file = io.open(outputPath, "r")
    if not file then
        gg.alert("Failed to open decrypted file")
        return nil
    end
    
    local data = file:read("*a")
    file:close()
    os.remove(outputPath)
    
    local lastEvent = nil
    local gameEvents = data:match('"gameEvents"%s*:%s*(%b[])')
    if gameEvents then
        for event in gameEvents:gmatch('"([^"]*)"') do
            lastEvent = event
        end
    else
        gg.alert("gameEvents not found")
        return nil
    end
    
    return lastEvent .. ".json"
end

local function getAvailableEventFiles()
    local eventsPath = getEventsDirectoryPath()
    local files = {}
    
    if not eventsPath then
        return files
    end
    
    -- Get all JSON files in events folder
    local result = executeInGameNamespace(
        'find "' .. eventsPath .. '" -maxdepth 1 -type f -name "*.json" ! -name "active_events.json" -printf "%f\\n"'
    )
    
    if result and result ~= "" then
        for file in result:gmatch("[^\r\n]+") do
            table.insert(files, file)
        end
    end
    
    table.sort(files)
    return files
end

local function selectEventFile()
    local files = getAvailableEventFiles()
    
    if #files == 0 then
        gg.alert("No event files found.")
        return nil
    end
    
    local choice = gg.choice(files, nil, "Select event to patch")
    if not choice then
        return nil
    end
    
    return files[choice]
end

local function downloadJsonFromURL(url)
    local response = gg.makeRequest(url)
    if not response or not response.content then
        gg.alert("Failed to download json from URL:\n" .. url)
        return nil
    end
    return response.content
end

-- ============================================
-- EVENT OPERATIONS
-- ============================================

local function restoreEventFile()
    local activeEvent = getActiveEventFileName()
    if not activeEvent then
        gg.alert("Failed to get active event")
        return
    end
    
    local eventJsonPath = getEventsDirectoryPath() .. activeEvent
    executeInGameNamespace('rm -f "' .. eventJsonPath .. '"')
    
    if checkFileExists(eventJsonPath) then
        gg.alert("Restore failed.")
    else
        gg.alert(
            "Event restored successfully!\n\n" ..
            "Version: " .. activeEvent ..
            "\n\nRestart your game to apply changes."
        )
    end
end

local function restoreSpecificEventFile()
    local selectedEvent = selectEventFile()
    if not selectedEvent then
        return
    end
    
    local eventJsonPath = getEventsDirectoryPath() .. selectedEvent
    executeInGameNamespace('rm -f "' .. eventJsonPath .. '"')
    
    if checkFileExists(eventJsonPath) then
        gg.alert("Restore failed.")
    else
        gg.alert(
            "Event restored successfully!\n\n" ..
            "File: " .. selectedEvent ..
            "\n\nRestart your game to apply changes."
        )
    end
end

local function dumpEventFile()
    local eventsPath = getEventsDirectoryPath()
    local tempPath = gg.EXT_FILES_DIR .. "/temp"
    local files = {}
    
    executeInGameNamespace('mkdir -p "' .. tempPath .. '"')
    
    -- Get JSON files in events folder
    local result = executeInGameNamespace(
        'find "' .. eventsPath .. '" -maxdepth 1 -type f -name "*.json" -printf "%f\\n"'
    )
    
    if not result or result == "" then
        gg.alert("No JSON files found.")
        return
    end
    
    -- Build file list
    for file in result:gmatch("[^\r\n]+") do
        table.insert(files, file)
    end
    
    table.sort(files)
    
    -- Let user select file
    local choice = gg.choice(files, nil, "Select event to decrypt")
    if not choice then
        return
    end
    
    local selectedFile = files[choice]
    local inputPath = eventsPath .. selectedFile
    local encryptedPath = tempPath .. "/" .. selectedFile
    local outputPath = "/sdcard/Download/" .. selectedFile
    
    -- Copy encrypted file
    local copySuccess = executeInGameNamespace(
        'cp "' .. inputPath .. '" "' .. encryptedPath .. '"'
    )
    
    if not copySuccess then
        gg.alert("Failed to copy " .. selectedFile)
        return
    end
    
    -- Decrypt
    local decryptedContents = Crypto.decrypt(encryptedPath, outputPath)
    os.remove(encryptedPath)
    
    if not decryptedContents then
        gg.alert("Decryption failed.")
        return
    end
    
    gg.alert("Decrypted to:\n" .. outputPath)
end

local function applyPatchesToEventData(eventData)
    local patchedData = eventData
    local patchError = nil
    
    if CONFIG.patches.patchFixed then
        patchedData, patchError = replaceJsonValues(patchedData, {
            {
                key = "fixedVehicles",
                data = nil
            }
        })
        if patchError then
            return nil, "Failed to patch fixedVehicles:\n\n" .. patchError
        end
    end
    
    -- Handle event rewards patching with merge support
    local crazyRewardsData = nil
    local freeRewardsData = nil
    local carRewardsData = nil
    
    if CONFIG.patches.patchCrazyRewards then
        crazyRewardsData = downloadJsonFromURL(CONFIG.URLs.crazyRewards)
        if crazyRewardsData == nil then
            return nil, "Failed to download crazy rewards data"
        end
    end
    
    if CONFIG.patches.patchFreeRewards then
        freeRewardsData = downloadJsonFromURL(CONFIG.URLs.freeRewards)
        if freeRewardsData == nil then
            return nil, "Failed to download free rewards data"
        end
    end

    if CONFIG.patches.patchCarRewards then
        carRewardsData = downloadJsonFromURL(CONFIG.URLs.carRewards)
        if carRewardsData == nil then
            return nil, "Failed to download car rewards data"
        end
    end
    
    -- Apply event rewards patches
    local enabledRewardPatches = {}
    if crazyRewardsData then
        table.insert(enabledRewardPatches, crazyRewardsData)
    end
    if freeRewardsData then
        table.insert(enabledRewardPatches, freeRewardsData)
    end
    if carRewardsData then
        table.insert(enabledRewardPatches, carRewardsData)
    end
    
    if #enabledRewardPatches > 0 then
        local mergedEventRewards = nil
        
        for _, rewardData in ipairs(enabledRewardPatches) do
            local eventRewards = extractJsonValue(rewardData, "eventRewards")
            if eventRewards then
                if not mergedEventRewards then
                    mergedEventRewards = eventRewards
                else
                    mergedEventRewards = mergeJsonData(mergedEventRewards, eventRewards)
                end
            end
        end
        
        if mergedEventRewards then
            -- Create merged data structure
            local mergedData = '{"eventRewards":' .. mergedEventRewards .. '}'
            
            patchedData, patchError = replaceJsonValues(patchedData, {
                {
                    key = "eventRewards",
                    data = mergedData
                }
            })
            
            if patchError then
                return nil, "Failed to patch eventRewards:\n\n" .. patchError
            end
        else
            return nil, "Failed to extract eventRewards from downloaded data"
        end
    end
    
    return patchedData, nil
end

local function patchEventFile(dumpOnly, specificEventFile)
    local activeEvent = specificEventFile or getActiveEventFileName()
    if not activeEvent then
        gg.alert("Failed to get event file")
        return
    end
    
    local eventJsonPath = getEventsDirectoryPath() .. activeEvent
    local outputDumpPath = "/sdcard/Download/"
    local encryptedTempPath = gg.EXT_FILES_DIR .. "/temp/" .. activeEvent
    local decryptedTempPath = gg.EXT_FILES_DIR .. "/temp/decrypted_" .. activeEvent
    
    -- Make sure temp directory exists
    executeInGameNamespace('mkdir -p "' .. gg.EXT_FILES_DIR .. '/temp"')
    
    -- Copy encrypted event file to temporary location
    local copySuccess = executeInGameNamespace(
        'cp "' .. eventJsonPath .. '" "' .. encryptedTempPath .. '"'
    )
    if not copySuccess then
        gg.alert("Failed to copy " .. eventJsonPath)
        return
    end
    
    -- Decrypt
    local encryptionMetadata = Crypto.decrypt(encryptedTempPath, decryptedTempPath)
    if not encryptionMetadata then
        os.remove(encryptedTempPath)
        gg.alert("Decryption failed")
        return
    end
    
    -- Remove encrypted temporary copy
    os.remove(encryptedTempPath)
    
    -- Read decrypted event
    local file = io.open(decryptedTempPath, "r")
    if not file then
        gg.alert("Failed to open decrypted event")
        return
    end
    
    local eventData = file:read("*a")
    file:close()
    
    -- Dump decrypted event instead of patching
    if dumpOnly then
        local dumpPath = outputDumpPath .. activeEvent
        local dumpFile = io.open(dumpPath, "w")
        if not dumpFile then
            os.remove(decryptedTempPath)
            gg.alert("Failed to create dump file")
            return
        end
        
        dumpFile:write(eventData)
        dumpFile:close()
        os.remove(decryptedTempPath)
        gg.alert("Event data dumped to:\n" .. dumpPath)
        return
    end
    
    -- Apply patches
    local patchedData, patchError = applyPatchesToEventData(eventData)
    
    if not patchedData then
        os.remove(decryptedTempPath)
        gg.alert("Failed to patch event:\n\n" .. patchError)
        return
    end
    
    eventData = patchedData
    
    -- Append "(Ollies Patch)" to name.value
    local modifiedData, replacementCount = eventData:gsub(
        '("name"%s*:%s*{%s*"value"%s*:%s*")([^"]*)(")',
        '%1%2 (Ollies Patch)%3',
        1
    )
    
    if replacementCount == 0 then
        os.remove(decryptedTempPath)
        gg.alert("name.value not found")
        return
    end
    
    -- Write patched decrypted JSON
    file = io.open(decryptedTempPath, "w")
    if not file then
        gg.alert("Failed to write patched event")
        return
    end
    
    file:write(modifiedData)
    file:close()
    
    -- Encrypt patched JSON
    Crypto.encrypt(decryptedTempPath, encryptedTempPath, encryptionMetadata)
    
    -- Replace original event file
    copySuccess = executeInGameNamespace(
        'cp "' .. encryptedTempPath .. '" "' .. eventJsonPath .. '"'
    )
    if not copySuccess then
        os.remove(decryptedTempPath)
        os.remove(encryptedTempPath)
        gg.alert("Failed to replace " .. eventJsonPath)
        return
    end
    
    -- Cleanup
    os.remove(decryptedTempPath)
    os.remove(encryptedTempPath)
    
    gg.alert(
        "Event patched successfully!\n\n" ..
        "Version: " .. activeEvent ..
        "\n\nRestart your game to apply changes."
    )
end

-- ============================================
-- MENU FUNCTIONS
-- ============================================

local function getEnabledPatchesList()
    local enabledPatches = {}
    if CONFIG.patches.patchCrazyRewards then
        table.insert(enabledPatches, "Crazy Shop Rewards")
    end
    if CONFIG.patches.patchFreeRewards then
        table.insert(enabledPatches, "Free Shop Rewards")
    end
    if CONFIG.patches.patchFixed then
        table.insert(enabledPatches, "Use All Vehicles")
    end
    if CONFIG.patches.patchCarRewards then
        table.insert(enabledPatches, "Car Unlocker")
    end
    return enabledPatches
end

local function showPreferencesMenu()
    local choice = gg.choice({
        "Crazy shop rewards (" .. tostring(CONFIG.patches.patchCrazyRewards) .. ")",
        "Free shop rewards (" .. tostring(CONFIG.patches.patchFreeRewards) .. ")",
        "Use all vehicles (" .. tostring(CONFIG.patches.patchFixed) .. ")",
        "Car unlocker (" .. tostring(CONFIG.patches.patchCarRewards) .. ")",
        "Back"
    }, nil, "Patch preferences")
    
    if choice == nil then
        return true -- User pressed Android back button, return to main menu
    elseif choice == 1 then
        CONFIG.patches.patchCrazyRewards = not CONFIG.patches.patchCrazyRewards
        gg.toast("Crazy shop rewards is now: " .. tostring(CONFIG.patches.patchCrazyRewards))
        return false -- Stay in preferences menu
    elseif choice == 2 then
        CONFIG.patches.patchFreeRewards = not CONFIG.patches.patchFreeRewards
        gg.toast("Free shop rewards is now: " .. tostring(CONFIG.patches.patchFreeRewards))
        return false -- Stay in preferences menu
    elseif choice == 3 then
        CONFIG.patches.patchFixed = not CONFIG.patches.patchFixed
        gg.toast("Use all vehicles is now: " .. tostring(CONFIG.patches.patchFixed))
        return false -- Stay in preferences menu
    elseif choice == 4 then
        CONFIG.patches.patchCarRewards = not CONFIG.patches.patchCarRewards
        gg.toast("Car unlocker is now: " .. tostring(CONFIG.patches.patchCarRewards))
        return false -- Stay in preferences menu
    elseif choice == 5 then
        return true -- Return to main menu
    end
    
    return true -- Return to main menu as fallback
end

local function showDevToolsMenu()
    local choice = gg.choice({
        "Patch specific event",
        "Restore specific event",
        "Dump event file",
        "Back"
    }, nil, "Dev Tools")
    
    if choice == nil then
        return true -- User pressed Android back button, return to main menu
    elseif choice == 1 then
        local enabledPatches = getEnabledPatchesList()
        
        local message = "Are you sure you want to patch the event?\n\n"
        if #enabledPatches > 0 then
            message = message .. "Enabled patches:\n"
            for _, patchName in ipairs(enabledPatches) do
                message = message .. "• " .. patchName .. "\n"
            end
            if #enabledPatches > 1 then
                message = message .. "\nNote: Multiple reward patches will be merged together."
            end
        else
            gg.alert("Unable to patch event: No patches are currently enabled.")
            return false -- Stay in dev tools menu
        end
        
        local confirm = gg.alert(message, "Patch Event", "Cancel")
        if confirm == 1 then
            local selectedEvent = selectEventFile()
            if selectedEvent then
                patchEventFile(false, selectedEvent)
            end
        end
        return false -- Stay in dev tools menu
    elseif choice == 2 then
        restoreSpecificEventFile()
        return false -- Stay in dev tools menu
    elseif choice == 3 then
        dumpEventFile()
        return false -- Stay in dev tools menu
    elseif choice == 4 then
        return true -- Return to main menu
    end
    
    return true -- Return to main menu as fallback
end

local function showMainMenu()
    local choice = gg.choice({
        "Patch active event",
        "Restore active event",
        "Preferences",
        "Dev Tools",
        "Exit"
    }, nil, "Public Event Patcher")
    
    if choice == nil then
        return false -- User pressed Android back button, stay in main menu
    elseif choice == 1 then
        local enabledPatches = getEnabledPatchesList()
        
        local message = "Are you sure you want to patch the event?\n\n"
        if #enabledPatches > 0 then
            message = message .. "Enabled patches:\n"
            for _, patchName in ipairs(enabledPatches) do
                message = message .. "• " .. patchName .. "\n"
            end
            if #enabledPatches > 1 then
                message = message .. "\nNote: Multiple reward patches will be merged together."
            end
        else
            gg.alert("Unable to patch event: No patches are currently enabled.")
            return false -- Stay in main menu
        end
        
        local confirm = gg.alert(message, "Patch Event", "Cancel")
        if confirm == 1 then
            patchEventFile(false)
        end
        return false -- Stay in main menu
    elseif choice == 2 then
        restoreEventFile()
        return false -- Stay in main menu
    elseif choice == 3 then
        -- Show preferences menu in a loop until user chooses to go back
        local returnToMain = false
        while not returnToMain do
            returnToMain = showPreferencesMenu()
        end
        return false -- Stay in main menu
    elseif choice == 4 then
        -- Show dev tools menu in a loop until user chooses to go back
        local returnToMain = false
        while not returnToMain do
            returnToMain = showDevToolsMenu()
        end
        return false -- Stay in main menu
    elseif choice == 5 then
        return true -- Exit script
    end
    
    return false -- Stay in main menu as fallback
end

-- ============================================
-- MAIN LOOP
-- ============================================

while true do
    if gg.isVisible(true) then
        gg.setVisible(false)
        local success, shouldExit = pcall(showMainMenu)
        if not success then
            gg.alert("Script error:\n\n" .. tostring(shouldExit))
            break
        end
        if shouldExit then
            break
        end
    end
    gg.sleep(100)
end