

local m_LaunchButtonInstance = {};
local m_IsInjected = false;
local m_PlannerReady = false;
local m_ContextInitialized = false;
local m_Shutdown = false;

-- r39 supersedes r33 direct-open: the planner owns the native chooser and all
-- mode/capability checks.  This context never loads multi-city dependencies;
-- a failed optional multi-city load must not remove the single-city entry.
local function AMT_OpenFromButton()
    if m_Shutdown or not m_PlannerReady then return; end
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
        "AMTMCEntryButtonInstance",
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

    ContextPtr:BuildInstanceForControl("AMTMCEntryPinInstance", {}, buttonStack);
    ResizeLaunchBar(buttonStack);
    m_IsInjected = true;
    return true;
end

local function OnLoadScreenClose()
    if m_Shutdown or not m_PlannerReady or InjectLaunchButton() then
        Events.LoadScreenClose.Remove(OnLoadScreenClose);
    end
end

local function AMT_MC_OnPlannerReady(ready)
    if m_Shutdown then return; end
    m_PlannerReady = ready == true;
    Events.LoadScreenClose.Remove(OnLoadScreenClose);
    if m_LaunchButtonInstance.OpenPlannerButton then
        m_LaunchButtonInstance.OpenPlannerButton:SetDisabled(not m_PlannerReady);
    end
    if m_ContextInitialized and m_PlannerReady
        and not InjectLaunchButton() then
        Events.LoadScreenClose.Add(OnLoadScreenClose);
    end
end

local function OnInit(isReload)
    if m_Shutdown then return; end
    m_ContextInitialized = true;
    AMT_MC_OnPlannerReady(m_PlannerReady);
    LuaEvents.AMT_RequestPlannerReady();
end

local function OnShutdown()
    m_Shutdown = true;
    m_PlannerReady = false;
    Events.LoadScreenClose.Remove(OnLoadScreenClose);
    LuaEvents.AMT_PlannerReady.Remove(AMT_MC_OnPlannerReady);
    if m_LaunchButtonInstance.OpenPlannerButton then
        m_LaunchButtonInstance.OpenPlannerButton:SetDisabled(true);
    end
end

ContextPtr:SetInitHandler(OnInit);
ContextPtr:SetShutdown(OnShutdown);
LuaEvents.AMT_PlannerReady.Add(AMT_MC_OnPlannerReady);
LuaEvents.AMT_RequestPlannerReady();
