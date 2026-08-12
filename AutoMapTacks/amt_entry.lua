print("[AMT] amt_entry.lua LOAD START v58");

local m_LaunchButtonInstance = {};
local m_IsInjected = false;

local function AMT_OpenFromButton()
    LuaEvents.AMT_OpenPlanner();
end

local function ResizeLaunchBar(buttonStack)
    buttonStack:CalculateSize();

    local stackWidth = buttonStack:GetSizeX();
    local backing = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking");
    if backing ~= nil then
        backing:SetSizeX(stackWidth + 116);
    end

    local backingTile = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile");
    if backingTile ~= nil then
        backingTile:SetSizeX(math.max(0, stackWidth - 20));
    end

    LuaEvents.LaunchBar_Resize(stackWidth);
end

local function InjectLaunchButton()
    if m_IsInjected then
        return true;
    end

    local buttonStack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack");
    if buttonStack == nil then
        return false;
    end

    ContextPtr:BuildInstanceForControl(
        "AMTEntryButtonInstance",
        m_LaunchButtonInstance,
        buttonStack
    );
    if m_LaunchButtonInstance.OpenPlannerButton == nil then
        return false;
    end

    if m_LaunchButtonInstance.OpenPlannerIcon ~= nil then
        local iconReady =
            m_LaunchButtonInstance.OpenPlannerIcon:SetIcon(
                "ICON_MAP_PIN_PLUS"
            );
        if not iconReady then
            m_LaunchButtonInstance.OpenPlannerIcon:SetIcon(
                "ICON_MAP_PIN_DISTRICT"
            );
        end
    end

    m_LaunchButtonInstance.OpenPlannerButton:RegisterCallback(
        Mouse.eLClick,
        AMT_OpenFromButton
    );
    m_LaunchButtonInstance.OpenPlannerButton:RegisterCallback(
        Mouse.eMouseEnter,
        function() UI.PlaySound("Main_Menu_Mouse_Over"); end
    );

    ContextPtr:BuildInstanceForControl("AMTEntryPinInstance", {}, buttonStack);
    ResizeLaunchBar(buttonStack);
    m_IsInjected = true;
    return true;
end

local function OnLoadScreenClose()
    if InjectLaunchButton() then
        Events.LoadScreenClose.Remove(OnLoadScreenClose);
    end
end

local function OnInit(isReload)
    Events.LoadScreenClose.Remove(OnLoadScreenClose);
    if not InjectLaunchButton() then
        Events.LoadScreenClose.Add(OnLoadScreenClose);
    end
end

ContextPtr:SetInitHandler(OnInit);
print("[AMT] amt_entry.lua LOAD END");
