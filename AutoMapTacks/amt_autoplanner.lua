print("[AMT] amt_autoplanner.lua LOAD START v60");
include("civ6common");
include("InstanceManager");
include("MapTacks");
include("dmt_yieldcalculator");
include("dmt_mappinsubjectmanager");
include("amt_wonderplanner");

local ENABLE_VERBOSE_LOGGING = false;
local ENABLE_WONDER_DEBUG = false;
local function Log(msg)
    local text = tostring(msg);
    if ENABLE_VERBOSE_LOGGING
        or string.find(text, "failed", 1, true)
        or string.find(text, "error", 1, true)
        or string.find(text, "WARN", 1, true)
        or string.find(text, "Could not", 1, true) then
        print("[AMT] " .. text);
    end
end

Log("ContextPtr=" .. tostring(ContextPtr));
Log("Includes done. GetBonusYields=" .. tostring(GetBonusYields) .. " CanPlacePin=" .. tostring(CanPlacePin));

local MAP_PIN_TYPE_DISTRICT = "DISTRICT";
local MAP_PIN_TYPE_IMPROVEMENT = "IMPROVEMENT";
local MAP_PIN_TYPE_WONDER = "WONDER";
local CONFIG_KEY_AUTO_PINS = "AMT_AUTO_PINS_V1";
local CONFIG_KEY_LAST_PLAN = "AMT_LAST_PLAN_V1";
local MAX_LINKED_CITIES = 4;
local LINKED_CITY_DISTANCE = 6;
local MAX_CANDIDATES_PER_REQUEST = 12;
local BEAM_WIDTH = 64;
local TILE_YIELD_PENALTY = 0.65;
local MIN_AUTOMATIC_GAIN = 0.001;
local YIELD_LIST = {
    "YIELD_SCIENCE", "YIELD_CULTURE", "YIELD_GOLD",
    "YIELD_FAITH", "YIELD_PRODUCTION", "YIELD_FOOD",
};
local DEFAULT_WEIGHTS = {
    -- Science, culture, faith and gold benefit the whole empire.  Food and
    -- production are local to the planned city, so a small local tile gain
    -- must not displace a strong specialty-district layout.
    YIELD_SCIENCE=1.80, YIELD_CULTURE=1.50, YIELD_GOLD=1.15,
    YIELD_FAITH=1.60, YIELD_PRODUCTION=0.75, YIELD_FOOD=0.55,
};
local GOAL_DISTRICT_ORDER = {
    BALANCED = {
        "DISTRICT_COMMERCIAL_HUB", "DISTRICT_CAMPUS", "DISTRICT_GOVERNMENT",
        "DISTRICT_INDUSTRIAL_ZONE",
        "DISTRICT_THEATER", "DISTRICT_HARBOR", "DISTRICT_HOLY_SITE",
        "DISTRICT_ENCAMPMENT", "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_PRESERVE",
    },
    SCIENCE = {
        "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HARBOR",
        "DISTRICT_GOVERNMENT", "DISTRICT_INDUSTRIAL_ZONE",
        "DISTRICT_THEATER", "DISTRICT_ENCAMPMENT",
        "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_HOLY_SITE", "DISTRICT_PRESERVE",
    },
    CULTURE = {
        "DISTRICT_THEATER", "DISTRICT_GOVERNMENT", "DISTRICT_HOLY_SITE",
        "DISTRICT_COMMERCIAL_HUB",
        "DISTRICT_HARBOR", "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_CAMPUS",
        "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ENCAMPMENT", "DISTRICT_PRESERVE",
    },
    RELIGION = {
        "DISTRICT_HOLY_SITE", "DISTRICT_GOVERNMENT",
        "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HARBOR",
        "DISTRICT_CAMPUS", "DISTRICT_THEATER", "DISTRICT_INDUSTRIAL_ZONE",
        "DISTRICT_ENTERTAINMENT_COMPLEX", "DISTRICT_ENCAMPMENT", "DISTRICT_PRESERVE",
    },
    DOMINATION = {
        "DISTRICT_ENCAMPMENT", "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB",
        "DISTRICT_HARBOR", "DISTRICT_GOVERNMENT",
        "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ENTERTAINMENT_COMPLEX",
        "DISTRICT_THEATER", "DISTRICT_HOLY_SITE", "DISTRICT_PRESERVE",
    },
    DIPLOMACY = {
        "DISTRICT_COMMERCIAL_HUB", "DISTRICT_HARBOR", "DISTRICT_GOVERNMENT",
        "DISTRICT_THEATER",
        "DISTRICT_CAMPUS", "DISTRICT_INDUSTRIAL_ZONE", "DISTRICT_ENTERTAINMENT_COMPLEX",
        "DISTRICT_HOLY_SITE", "DISTRICT_ENCAMPMENT", "DISTRICT_PRESERVE",
    },
};

local function Key(x, y) return x .. "_" .. y; end
local PREVIEW_LENS_LAYER = UILens.CreateLensLayerHash("Hex_Coloring_Placement");

local m_IsOpen = false;
local m_IsPlanning = false;
local m_SuppressPlanningYield = false;
local m_QueuedPlan = nil;
local m_PlanningDelayFrames = 0;
local m_AutoPlanActionId = nil;
local m_CurrentCategory = MAP_PIN_TYPE_DISTRICT;
local m_PlannerOptions = {
    [MAP_PIN_TYPE_DISTRICT] = {},
    [MAP_PIN_TYPE_IMPROVEMENT] = {},
    [MAP_PIN_TYPE_WONDER] = {},
};
local m_SelectedSubjects = {
    [MAP_PIN_TYPE_DISTRICT] = {},
    [MAP_PIN_TYPE_IMPROVEMENT] = {},
    [MAP_PIN_TYPE_WONDER] = {},
};
local m_IconInstances = {};
local m_OverwriteCheck = nil;
local m_ClearCheck = nil;
local m_ClearManualCheck = nil;
local m_MultiCityCheck = nil;
local m_UndoButton = nil;
local m_ResultText = nil;
local m_CityName = nil;
local m_PendingPreview = nil;
local m_DistrictPriorities = {};
local m_SpecialtyOrder = {};
local m_PrioritizeUnique = true;
local m_EnablePreserve = false;
local m_PlanningHorizon = "LONG_TERM";
local m_DistrictReplacementBase = nil;
local DEFAULT_SPECIALTY_SLOT_COUNT = 3;
local MIN_SPECIALTY_SLOT_COUNT = 1;
local MAX_SPECIALTY_SLOT_COUNT = 6;
local POPULATION_BUDGET_RANGE = { minimum = 1, maximum = 50 };
local m_CitySpecialtyPlans = {};
local m_YieldFocusStates = {
    YIELD_SCIENCE=0, YIELD_CULTURE=0, YIELD_GOLD=0,
    YIELD_FAITH=0, YIELD_PRODUCTION=0, YIELD_FOOD=0,
};
local m_YieldFocusButtons = {};
AMT_PlotDirectives = AMT_PlotDirectives or {};

-- A tack's city is determined by the plot assignment shown in Citizen
-- Management, not by whichever city center happens to be closest.  Keep this
-- helper global (and AMT-prefixed) to avoid adding another chunk-level local
-- in this already large UI context.
function AMT_GetPlotPurchaseCity(plot)
    if not plot or not Cities or not Cities.GetPlotPurchaseCity then
        return nil;
    end
    local ok, city = pcall(Cities.GetPlotPurchaseCity, plot);
    if ok then return city; end
    return nil;
end

AMT_AppealProjection = AMT_AppealProjection or {};

function AMT_AppealProjection.GetFeatureType(plot)
    if not plot then return nil; end
    local featureIndex = plot:GetFeatureType();
    local row = featureIndex and featureIndex >= 0
        and GameInfo.Features[featureIndex] or nil;
    return row and row.FeatureType or nil;
end

function AMT_AppealProjection.GetFeatureAppeal(featureType)
    local row = featureType and GameInfo.Features[featureType] or nil;
    return tonumber(row and row.Appeal) or 0;
end

function AMT_AppealProjection.GetSubjectAppeal(subject)
    if not subject then return 0; end
    local row = nil;
    if subject.Type == MAP_PIN_TYPE_DISTRICT then
        row = GameInfo.Districts[subject.Key];
    elseif subject.Type == MAP_PIN_TYPE_IMPROVEMENT then
        row = GameInfo.Improvements[subject.Key];
    elseif subject.Type == MAP_PIN_TYPE_WONDER then
        row = GameInfo.Buildings[subject.Key];
    end
    return tonumber(row and row.Appeal) or 0;
end

function AMT_AppealProjection.RemovesFeature(subject, featureType)
    if not subject or not featureType then return false; end
    if subject.Type == MAP_PIN_TYPE_DISTRICT then
        if WillDistrictRemoveFeature then
            local ok, result = pcall(
                WillDistrictRemoveFeature, subject.Key, featureType
            );
            if ok then return result == true; end
        end
    elseif subject.Type == MAP_PIN_TYPE_WONDER then
        if WillWonderRemoveFeature then
            local ok, result = pcall(
                WillWonderRemoveFeature, subject.Key, featureType
            );
            if ok then return result == true; end
        end
    end
    return false;
end

function AMT_AppealProjection.BuildSubjectMap(items, fixedSubjects)
    local subjects = {};
    for _, subject in ipairs(fixedSubjects or {}) do
        if not subject.isExisting then
            subjects[Key(subject.X, subject.Y)] = subject;
        end
    end
    for _, item in ipairs(items or {}) do
        subjects[Key(item.x, item.y)] = {
            X = item.x,
            Y = item.y,
            Key = item.subjectKey or item.district,
            Type = item.subjectType or MAP_PIN_TYPE_DISTRICT,
        };
    end
    return subjects;
end

function AMT_AppealProjection.GetProjectedFeature(plot, subjects)
    if not plot then return nil; end
    local key = Key(plot:GetX(), plot:GetY());
    local featureType = AMT_AppealProjection.GetFeatureType(plot);
    local directive = AMT_PlotDirectives[key];
    if directive then
        if directive.removeFeature then featureType = nil; end
        if directive.plantForest then featureType = "FEATURE_FOREST"; end
    end
    local subject = subjects and subjects[key] or nil;
    if featureType
        and AMT_AppealProjection.RemovesFeature(subject, featureType) then
        featureType = nil;
    end
    return featureType;
end

function AMT_AppealProjection.GetProjectedAppeal(
    plot, items, fixedSubjects, subjects
)
    if not plot then return 0; end
    local ok, currentAppeal = pcall(function() return plot:GetAppeal(); end);
    local projected = ok and tonumber(currentAppeal) or 0;
    subjects = subjects
        or AMT_AppealProjection.BuildSubjectMap(items, fixedSubjects);
    for _, adjacentPlot in ipairs(
        GetPlotsWithinXTiles(plot:GetX(), plot:GetY(), 1)
    ) do
        if adjacentPlot:GetX() ~= plot:GetX()
            or adjacentPlot:GetY() ~= plot:GetY() then
            local adjacentKey = Key(
                adjacentPlot:GetX(), adjacentPlot:GetY()
            );
            local currentFeature =
                AMT_AppealProjection.GetFeatureType(adjacentPlot);
            local projectedFeature =
                AMT_AppealProjection.GetProjectedFeature(
                    adjacentPlot, subjects
                );
            projected = projected
                - AMT_AppealProjection.GetFeatureAppeal(currentFeature)
                + AMT_AppealProjection.GetFeatureAppeal(projectedFeature);
            projected = projected
                + AMT_AppealProjection.GetSubjectAppeal(
                    subjects[adjacentKey]
                );
        end
    end
    if AMT_WonderPlanner
        and AMT_WonderPlanner.GetSelectedAppealDelta then
        projected = projected + AMT_WonderPlanner.GetSelectedAppealDelta(
            plot, items, fixedSubjects
        );
    end
    return projected;
end
local m_SpecialtySlotInstances = {};
local m_SlotDropTargets = {};
local m_SlotControlToIndex = {};
local m_SelectedSlotDropTarget = nil;
local m_DraggedSpecialtyDistrict = nil;
local m_DragSourceSlot = nil;
local m_PlannerIconIM = InstanceManager:new("PlannerIconEntry", "Top", Controls.ItemGrid);
local m_PriorityEntryIM =
    InstanceManager:new("PriorityEntry", "Top", Controls.WeightStack);
local m_PreviewEntryIM = InstanceManager:new("PreviewEntry", "Top", Controls.PreviewStack);
local m_PreviewSkippedEntryIM =
    InstanceManager:new("SkippedEntry", "Top", Controls.SkippedStack);
local m_PreviewMapIconIM =
    InstanceManager:new("PreviewMapIcon", "Anchor", Controls.PreviewWorldIcons);

local function GetYieldDisplay(yt)
    local y = GameInfo.Yields[yt];
    if y then return (y.IconString or "") .. " " .. Locale.Lookup(y.Name); end
    return yt;
end

local function GetDistrictDisplay(dt)
    local row = GameInfo.Districts[dt];
    if row then
        local name = Locale.Lookup(row.Name);
        return name;
    end
    return dt;
end

local function IsTrue(value)
    return value == true or value == 1;
end

local function IsPopulationDistrict(districtType)
    local row = GameInfo.Districts[districtType];
    return row and IsTrue(row.RequiresPopulation) or false;
end

local function GetDistrictReplacementBase()
    if m_DistrictReplacementBase then return m_DistrictReplacementBase; end
    local replacements = {};
    if GameInfo.DistrictReplaces then
        for row in GameInfo.DistrictReplaces() do
            if row.CivUniqueDistrictType and row.ReplacesDistrictType then
                replacements[row.CivUniqueDistrictType] = row.ReplacesDistrictType;
            end
        end
    end
    m_DistrictReplacementBase = replacements;
    return replacements;
end

local function GetDistrictStrategyType(districtType)
    local baseType = GetDistrictReplacementBase()[districtType]
        or districtType;
    if baseType == "DISTRICT_WATER_ENTERTAINMENT_COMPLEX" then
        return "DISTRICT_ENTERTAINMENT_COMPLEX";
    end
    return baseType;
end

local function IsUniqueDistrict(districtType)
    return GetDistrictReplacementBase()[districtType] ~= nil;
end

local function IsPreserveDistrict(districtType)
    return GetDistrictStrategyType(districtType) == "DISTRICT_PRESERVE";
end

local function IsCoverageDistrict(districtType)
    local baseType = GetDistrictStrategyType(districtType);
    return baseType == "DISTRICT_INDUSTRIAL_ZONE"
        or baseType == "DISTRICT_ENTERTAINMENT_COMPLEX";
end

local function IsEconomicTradeDistrict(districtType)
    local baseType = GetDistrictStrategyType(districtType);
    return baseType == "DISTRICT_COMMERCIAL_HUB"
        or baseType == "DISTRICT_HARBOR";
end

local function AreEconomicTradeAlternatives(firstDistrict, secondDistrict)
    if not IsEconomicTradeDistrict(firstDistrict)
        or not IsEconomicTradeDistrict(secondDistrict) then
        return false;
    end
    return GetDistrictStrategyType(firstDistrict)
        ~= GetDistrictStrategyType(secondDistrict);
end

local function GetSpecialtyOrderIndex(districtType)
    for index, orderedType in ipairs(m_SpecialtyOrder) do
        if orderedType == districtType then return index; end
    end
    return 99;
end

local function GetRequiredPopulationForSpecialtySlot(slotNumber)
    return math.max(1, 1 + (math.max(1, slotNumber) - 1) * 3);
end

function AMT_GetTargetImprovementPlotCount(population)
    return math.max(
        1,
        math.min(12, math.ceil((tonumber(population) or 1) * 0.8))
    );
end

local function GetSubjectRow(subjectType, subjectKey)
    if subjectType == MAP_PIN_TYPE_DISTRICT then
        return GameInfo.Districts[subjectKey];
    elseif subjectType == MAP_PIN_TYPE_IMPROVEMENT then
        return GameInfo.Improvements[subjectKey];
    elseif subjectType == MAP_PIN_TYPE_WONDER then
        return GameInfo.Buildings[subjectKey] or GameInfo.Districts[subjectKey];
    end
    return nil;
end

local function GetSubjectDisplay(subjectType, subjectKey)
    local row = GetSubjectRow(subjectType, subjectKey);
    return row and Locale.Lookup(row.Name) or subjectKey;
end

local function GetSubjectIcon(subjectType, subjectKey)
    local row = GetSubjectRow(subjectType, subjectKey);
    if subjectType == MAP_PIN_TYPE_IMPROVEMENT then
        return row and row.Icon or ("ICON_" .. subjectKey);
    end
    return "ICON_" .. subjectKey;
end

local function GetEraData(eraType)
    local row = eraType and GameInfo.Eras[eraType] or nil;
    if not row then
        row = GameInfo.Eras["ERA_ANCIENT"];
        eraType = row and row.EraType or "ERA_ANCIENT";
    end
    return {
        eraType = eraType or "ERA_ANCIENT",
        eraIndex = row and (tonumber(row.ChronologyIndex)
            or tonumber(row.Index)) or 0,
        eraName = row and Locale.Lookup(row.Name)
            or Locale.Lookup("LOC_ERA_ANCIENT_NAME"),
    };
end

local function GetSubjectUnlockEra(row)
    local latest = GetEraData("ERA_ANCIENT");
    local function ConsiderEra(eraType)
        if not eraType then return; end
        local candidate = GetEraData(eraType);
        if candidate.eraIndex > latest.eraIndex then latest = candidate; end
    end
    if row and row.PrereqTech then
        local technology = GameInfo.Technologies[row.PrereqTech];
        ConsiderEra(technology and technology.EraType);
    end
    if row and row.PrereqCivic then
        local civic = GameInfo.Civics[row.PrereqCivic];
        ConsiderEra(civic and civic.EraType);
    end
    return latest;
end

local function GetDistrictMaxPerPlayer(dt)
    local row = GameInfo.Districts[dt];
    local limit = row and tonumber(row.MaxPerPlayer) or nil;
    if limit and limit >= 0 then return math.floor(limit + 0.0001); end
    return nil;
end

local function IsDistrictOnePerCity(dt)
    local row = GameInfo.Districts[dt];
    return row and row.OnePerCity ~= false and row.OnePerCity ~= 0;
end

local m_MutuallyExclusiveDistricts = nil;

local function GetMutuallyExclusiveDistricts()
    if m_MutuallyExclusiveDistricts then return m_MutuallyExclusiveDistricts; end
    local exclusions = {};
    if GameInfo.MutuallyExclusiveDistricts then
        for row in GameInfo.MutuallyExclusiveDistricts() do
            exclusions[row.District] = exclusions[row.District] or {};
            exclusions[row.MutuallyExclusiveDistrict] =
                exclusions[row.MutuallyExclusiveDistrict] or {};
            exclusions[row.District][row.MutuallyExclusiveDistrict] = true;
            exclusions[row.MutuallyExclusiveDistrict][row.District] = true;
        end
    end
    m_MutuallyExclusiveDistricts = exclusions;
    return exclusions;
end

local function AreDistrictsMutuallyExclusive(firstDistrict, secondDistrict)
    local exclusions = GetMutuallyExclusiveDistricts();
    return exclusions[firstDistrict] and exclusions[firstDistrict][secondDistrict] or false;
end

local function BuildDistrictOptionGroups(selectedDistricts)
    local eligible = {};
    for _, districtType in ipairs(selectedDistricts) do
        if GetDistrictMaxPerPlayer(districtType) == nil then
            eligible[districtType] = true;
        end
    end

    local groups = {};
    local visited = {};
    for districtType in pairs(eligible) do
        if not visited[districtType] then
            local group = {};
            local stack = { districtType };
            visited[districtType] = true;
            while #stack > 0 do
                local current = table.remove(stack);
                table.insert(group, current);
                for otherDistrict in pairs(eligible) do
                    if not visited[otherDistrict]
                        and AreDistrictsMutuallyExclusive(current, otherDistrict) then
                        visited[otherDistrict] = true;
                        table.insert(stack, otherDistrict);
                    end
                end
            end
            table.sort(group);
            table.insert(groups, group);
        end
    end
    table.sort(groups, function(a, b) return a[1] < b[1]; end);
    return groups;
end

local function GetRequestDistrictDisplay(request)
    local labels = {};
    local subjectType = request.subjectType or MAP_PIN_TYPE_DISTRICT;
    local options = request.subjectOptions
        or request.districtOptions
        or { request.subjectKey or request.district };
    for _, subjectKey in ipairs(options) do
        table.insert(labels, GetSubjectDisplay(subjectType, subjectKey));
    end
    return table.concat(labels, " / ");
end

local function CloneRequestForSubject(request, subjectKey)
    local copy = {};
    for key, value in pairs(request) do copy[key] = value; end
    copy.subjectKey = subjectKey;
    copy.subjectOptions = { subjectKey };
    copy.districtOptions = nil;
    if copy.subjectType == MAP_PIN_TYPE_DISTRICT then
        copy.district = subjectKey;
    end
    return copy;
end

local function GetDistrictTooltip(dt)
    local name = GetDistrictDisplay(dt);
    local limit = GetDistrictMaxPerPlayer(dt);
    if limit == 1 then
        return name .. "[NEWLINE]" .. Locale.Lookup("LOC_AMT_LIMIT_ONE_PER_PLAYER");
    elseif limit and limit > 1 then
        return name .. "[NEWLINE]" .. Locale.Lookup("LOC_AMT_LIMIT_PER_PLAYER", limit);
    end
    return name;
end

local function GetSubjectTooltip(option)
    if option.subjectType == MAP_PIN_TYPE_DISTRICT then
        return GetDistrictTooltip(option.subjectKey);
    end
    local row = GetSubjectRow(option.subjectType, option.subjectKey);
    local tooltip = GetSubjectDisplay(option.subjectType, option.subjectKey);
    if row and row.Description then
        local description = Locale.Lookup(row.Description);
        if description and description ~= "" and description ~= row.Description then
            tooltip = tooltip .. "[NEWLINE]" .. description;
        end
    end
    return tooltip;
end

local function LoadConfigTable(cfg, key)
    if not cfg then return nil; end
    local raw = cfg:GetValue(key);
    if type(raw) == "table" then return raw; end
    if type(raw) ~= "string" or raw == "" then return nil; end

    local ok, value = pcall(deserialize, raw);
    if ok and type(value) == "table" then return value; end
    Log("Could not deserialize config table " .. tostring(key));
    return nil;
end

local function SaveConfigTable(cfg, key, value)
    if not cfg then return; end
    if value == nil then
        cfg:SetValue(key, nil);
    else
        cfg:SetValue(key, serialize(value));
    end
end

local function LoadAutoPinRegistry(playerID)
    local cfg = PlayerConfigurations[playerID];
    return LoadConfigTable(cfg, CONFIG_KEY_AUTO_PINS) or {};
end

local function SaveAutoPinRegistry(playerID, registry)
    local cfg = PlayerConfigurations[playerID];
    SaveConfigTable(cfg, CONFIG_KEY_AUTO_PINS, registry or {});
end

local function IsAutoMapPin(pin, registry)
    if not pin or not registry then return false; end
    local key = Key(pin:GetHexX(), pin:GetHexY());
    local record = registry[key];
    if type(record) ~= "table" then return false; end
    if tostring(record.id) == tostring(pin:GetID()) then return true; end

    -- Map-pin IDs are not stable across every save/load and network refresh.
    -- Recover an old registry entry only when the pin still has the recorded
    -- icon on the recorded hex; this keeps manual replacement pins protected.
    local recordedIcon = record.iconName;
    if (not recordedIcon or recordedIcon == "")
        and record.subjectType and (record.subjectKey or record.district) then
        recordedIcon = GetSubjectIcon(
            record.subjectType, record.subjectKey or record.district
        );
    end
    local currentIcon = pin:GetIconName();
    if recordedIcon and recordedIcon ~= ""
        and tostring(recordedIcon) == tostring(currentIcon) then
        record.id = pin:GetID();
        return true;
    end
    return false;
end

local function RegisterAutoMapPin(
    pin, subjectType, subjectKey, iconName, registry, cityID
)
    if not pin or not registry then return; end
    local x, y = pin:GetHexX(), pin:GetHexY();
    registry[Key(x, y)] = {
        id = pin:GetID(),
        subjectType = subjectType,
        subjectKey = subjectKey,
        iconName = iconName,
        district = subjectType == MAP_PIN_TYPE_DISTRICT and subjectKey or nil,
        cityID = cityID,
        x = x,
        y = y,
    };
end

local function UnregisterAutoMapPin(pin, registry)
    if not pin or not registry then return; end
    registry[Key(pin:GetHexX(), pin:GetHexY())] = nil;
end

local function LoadLastPlan(playerID)
    local cfg = PlayerConfigurations[playerID];
    return LoadConfigTable(cfg, CONFIG_KEY_LAST_PLAN);
end

local function SaveLastPlan(playerID, transaction)
    local cfg = PlayerConfigurations[playerID];
    SaveConfigTable(cfg, CONFIG_KEY_LAST_PLAN, transaction);
end

local function HasUndoableTransaction(playerID)
    local transaction = LoadLastPlan(playerID);
    return transaction ~= nil
        and (#(transaction.added or {}) > 0 or #(transaction.removed or {}) > 0);
end

local function RefreshUndoButton(playerID)
    if m_UndoButton then
        m_UndoButton:SetDisabled(not HasUndoableTransaction(playerID));
    end
end

local function RefreshClearManualControl()
    if not m_ClearManualCheck then return; end
    local enabled = m_ClearCheck and m_ClearCheck:IsChecked() or false;
    if not enabled then m_ClearManualCheck:SetCheck(false); end
    m_ClearManualCheck:SetDisabled(not enabled);
end

local function SetPlanButtonPreviewMode(isConfirming)
    if Controls.OkButton then
        Controls.OkButton:SetText(Locale.Lookup("LOC_AMT_PREVIEW_PLAN"));
    end
end

local function ClearPreviewHighlights()
    if UILens and PREVIEW_LENS_LAYER then
        UILens.ClearLayerHexes(PREVIEW_LENS_LAYER);
    end
end

local function ClearPendingPreview(clearDisplay)
    m_PendingPreview = nil;
    SetPlanButtonPreviewMode(false);
    ClearPreviewHighlights();
    if clearDisplay then
        m_PreviewEntryIM:ResetInstances();
        m_PreviewMapIconIM:ResetInstances();
        if Controls.PreviewStack then
            Controls.PreviewStack:CalculateSize();
            Controls.PreviewStack:ReprocessAnchoring();
        end
        if Controls.PreviewScroll then Controls.PreviewScroll:SetHide(true); end
        if Controls.PreviewLabel then Controls.PreviewLabel:SetHide(true); end
        if Controls.PreviewPanel then Controls.PreviewPanel:SetHide(true); end
        if Controls.SettingsBlocker then Controls.SettingsBlocker:SetHide(false); end
    end
end

local function GetCityPurchasedPlots(city)
    local plots = {};
    local seen = {};
    if not city then return plots; end

    -- The CityPlots binding differs slightly between game builds and custom
    -- rulesets.  Prefer the native collection, but never let a signature
    -- mismatch disable foundation detection.
    local cityPlots = Map.GetCityPlots and Map.GetCityPlots() or nil;
    local ok, plotIDs = pcall(function()
        return cityPlots and cityPlots:GetPurchasedPlots(city) or nil;
    end);
    if ok and type(plotIDs) == "table" then
        for _, plotID in pairs(plotIDs) do
            local plot = Map.GetPlotByIndex(plotID);
            if plot then
                local key = Key(plot:GetX(), plot:GetY());
                if not seen[key] then
                    seen[key] = true;
                    table.insert(plots, plot);
                end
            end
        end
    end

    -- Purchased plots are always within the city's workable radius.  This
    -- ownership scan also catches unfinished districts when the native
    -- CityPlots collection is unavailable or temporarily incomplete.
    for _, plot in ipairs(GetPlotsWithinXTiles(city:GetX(), city:GetY(), 3)) do
        local owningCity = AMT_GetPlotPurchaseCity(plot);
        if owningCity
            and owningCity:GetOwner() == city:GetOwner()
            and owningCity:GetID() == city:GetID() then
            local key = Key(plot:GetX(), plot:GetY());
            if not seen[key] then
                seen[key] = true;
                table.insert(plots, plot);
            end
        end
    end
    return plots;
end

local function IsDistrictAlreadyInCity(city, dt)
    if not city then return false; end
    local districtRow = GameInfo.Districts[dt];
    local cityDistricts = city:GetDistricts();
    if not districtRow or not cityDistricts then return false; end
    local targetStrategy = GetDistrictStrategyType(dt);

    -- Scan this city's purchased plots first. GetDistrictType is populated as
    -- soon as a district foundation is placed, so unfinished districts are
    -- treated as irrevocably locked just like completed districts.
    for _, plot in ipairs(GetCityPurchasedPlots(city)) do
        local districtIndex = plot and plot:GetDistrictType() or -1;
        if districtIndex and districtIndex >= 0 then
            local placedRow = GameInfo.Districts[districtIndex];
            if placedRow and (
                placedRow.DistrictType == dt
                or GetDistrictStrategyType(placedRow.DistrictType)
                    == targetStrategy
            ) then
                return true;
            end
        end
    end

    -- Keep the manager query as a fallback for completed districts and for
    -- rulesets whose city-plot collection is temporarily unavailable.
    local ok, hasDistrict = pcall(function()
        return cityDistricts:HasDistrict(districtRow.Index);
    end);
    if ok and hasDistrict then return true; end
    for row in GameInfo.Districts() do
        if GetDistrictStrategyType(row.DistrictType) == targetStrategy then
            local rowOK, hasReplacement = pcall(function()
                return cityDistricts:HasDistrict(row.Index);
            end);
            if rowOK and hasReplacement then return true; end
        end
    end
    return false;
end

local m_PlanningRelevantImprovements = nil;

local function GetPlanningRelevantImprovements()
    if m_PlanningRelevantImprovements then
        return m_PlanningRelevantImprovements;
    end
    local relevant = {};
    for row in GameInfo.Improvement_YieldChanges() do
        relevant[row.ImprovementType] = true;
    end
    for row in GameInfo.Improvement_Adjacencies() do
        relevant[row.ImprovementType] = true;
    end
    for row in GameInfo.Adjacency_YieldChanges() do
        if row.AdjacentImprovement then
            relevant[row.AdjacentImprovement] = true;
        end
    end
    m_PlanningRelevantImprovements = relevant;
    return relevant;
end

local function BuildPlayerPlannerOptions(playerID)
    local traits = MapTacks.PlayerTraits(playerID);
    local options = {
        [MAP_PIN_TYPE_DISTRICT] = {},
        [MAP_PIN_TYPE_IMPROVEMENT] = {},
        [MAP_PIN_TYPE_WONDER] = {},
    };
    for _, districtRow in ipairs(MapTacks.PlayerDistricts(traits)) do
        local dt = districtRow.DistrictType;
        if not districtRow.CityCenter
            and not districtRow.InternalOnly
            and dt ~= "DISTRICT_WONDER" then
            table.insert(options[MAP_PIN_TYPE_DISTRICT], {
                subjectType = MAP_PIN_TYPE_DISTRICT,
                subjectKey = dt,
                iconName = GetSubjectIcon(MAP_PIN_TYPE_DISTRICT, dt),
                requiresPopulation = IsPopulationDistrict(dt),
                baseDistrictType = GetDistrictStrategyType(dt),
                isUnique = IsUniqueDistrict(dt),
                isPreserve = IsPreserveDistrict(dt),
            });
        end
    end

    -- The stock map-tack screen mixes genuine improvements with repair,
    -- harvesting, routes, unit formations and other marker-only actions.
    -- Only the real builder list and the current player's trait-specific
    -- list participate in planning.
    local builder, unique = MapTacks.PlayerImprovements(traits);
    local seenImprovements = {};
    local relevantImprovements = GetPlanningRelevantImprovements();
    for listIndex, improvementList in ipairs({ builder or {}, unique or {} }) do
        for _, improvementRow in ipairs(improvementList) do
            local improvementType = improvementRow.ImprovementType;
            if improvementType
                and (listIndex == 2 or relevantImprovements[improvementType])
                and not seenImprovements[improvementType] then
                seenImprovements[improvementType] = true;
                local era = GetSubjectUnlockEra(improvementRow);
                table.insert(options[MAP_PIN_TYPE_IMPROVEMENT], {
                    subjectType = MAP_PIN_TYPE_IMPROVEMENT,
                    subjectKey = improvementType,
                    iconName = GetSubjectIcon(
                        MAP_PIN_TYPE_IMPROVEMENT, improvementType
                    ),
                    eraType = era.eraType,
                    eraIndex = era.eraIndex,
                    eraName = era.eraName,
                });
            end
        end
    end

    for _, wonderRow in ipairs(MapTacks.PlayerWonders(traits)) do
        local wonderType = wonderRow.BuildingType or wonderRow.DistrictType;
        if wonderType
            and (wonderRow.IsWonder or wonderType == "DISTRICT_WONDER") then
            table.insert(options[MAP_PIN_TYPE_WONDER], {
                subjectType = MAP_PIN_TYPE_WONDER,
                subjectKey = wonderType,
                iconName = GetSubjectIcon(MAP_PIN_TYPE_WONDER, wonderType),
                requiredDistrict = wonderRow.AdjacentDistrict,
            });
        end
    end
    table.sort(options[MAP_PIN_TYPE_IMPROVEMENT], function(a, b)
        if (a.eraIndex or 0) ~= (b.eraIndex or 0) then
            return (a.eraIndex or 0) < (b.eraIndex or 0);
        end
        return GetSubjectDisplay(a.subjectType, a.subjectKey)
            < GetSubjectDisplay(b.subjectType, b.subjectKey);
    end);
    return options;
end

local function GetSelectedCity()
    local playerID = Game.GetLocalPlayer();
    local city = UI.GetHeadSelectedCity();
    if city and city:GetOwner() == playerID then return city; end
    local player = Players[playerID];
    if not player then return nil; end
    local cm = player:GetCities();
    if not cm then return nil; end
    for _, c in cm:Members() do return c; end
    return nil;
end

local function GetCityPlanKey(city)
    if not city then return nil; end
    return tostring(city:GetOwner()) .. ":" .. tostring(city:GetID());
end

local function GetCitySpecialtyPlan(city)
    local key = GetCityPlanKey(city);
    if not key then return nil; end
    if not m_CitySpecialtyPlans[key] then
        local currentPopulation =
            math.max(1, tonumber(city:GetPopulation()) or 1);
        m_CitySpecialtyPlans[key] = {
            slotCount = DEFAULT_SPECIALTY_SLOT_COUNT,
            slots = {},
            populationBudget = math.max(
                currentPopulation,
                GetRequiredPopulationForSpecialtySlot(
                    DEFAULT_SPECIALTY_SLOT_COUNT
                )
            ),
            selectedSubjects = {
                [MAP_PIN_TYPE_DISTRICT] = {},
                [MAP_PIN_TYPE_IMPROVEMENT] = {},
                [MAP_PIN_TYPE_WONDER] = {},
            },
            planningHorizon = "LONG_TERM",
            prioritizeUnique = true,
            enablePreserve = false,
            yieldFocusStates = {
                YIELD_SCIENCE=0, YIELD_CULTURE=0, YIELD_GOLD=0,
                YIELD_FAITH=0, YIELD_PRODUCTION=0, YIELD_FOOD=0,
            },
            overwriteAutoPins = false,
            clearBeforePlan = false,
            clearManualPins = false,
        };
    end
    local plan = m_CitySpecialtyPlans[key];
    plan.slotCount = math.max(
        MIN_SPECIALTY_SLOT_COUNT,
        math.min(MAX_SPECIALTY_SLOT_COUNT,
            tonumber(plan.slotCount) or DEFAULT_SPECIALTY_SLOT_COUNT)
    );
    local currentPopulation =
        math.max(1, tonumber(city:GetPopulation()) or 1);
    plan.populationBudget = math.max(
        currentPopulation,
        math.min(
            POPULATION_BUDGET_RANGE.maximum,
            tonumber(plan.populationBudget)
                or GetRequiredPopulationForSpecialtySlot(plan.slotCount)
        )
    );
    plan.slots = plan.slots or {};
    plan.selectedSubjects = plan.selectedSubjects or {
        [MAP_PIN_TYPE_DISTRICT] = {},
        [MAP_PIN_TYPE_IMPROVEMENT] = {},
        [MAP_PIN_TYPE_WONDER] = {},
    };
    plan.selectedSubjects[MAP_PIN_TYPE_DISTRICT] =
        plan.selectedSubjects[MAP_PIN_TYPE_DISTRICT] or {};
    plan.selectedSubjects[MAP_PIN_TYPE_IMPROVEMENT] =
        plan.selectedSubjects[MAP_PIN_TYPE_IMPROVEMENT] or {};
    plan.selectedSubjects[MAP_PIN_TYPE_WONDER] =
        plan.selectedSubjects[MAP_PIN_TYPE_WONDER] or {};
    plan.planningHorizon = plan.planningHorizon or "LONG_TERM";
    if plan.prioritizeUnique == nil then plan.prioritizeUnique = true; end
    if plan.enablePreserve == nil then plan.enablePreserve = false; end
    plan.yieldFocusStates = plan.yieldFocusStates or {
        YIELD_SCIENCE=0, YIELD_CULTURE=0, YIELD_GOLD=0,
        YIELD_FAITH=0, YIELD_PRODUCTION=0, YIELD_FOOD=0,
    };
    if plan.overwriteAutoPins == nil then plan.overwriteAutoPins = false; end
    if plan.clearBeforePlan == nil then plan.clearBeforePlan = false; end
    if plan.clearManualPins == nil then plan.clearManualPins = false; end
    return plan;
end

local function GetManualDistrictPinsForCity(city)
    local result = {};
    if not city then return result; end
    local playerID = Game.GetLocalPlayer();
    local cfg = PlayerConfigurations[playerID];
    local pins = cfg and cfg:GetMapPins() or {};
    local autoRegistry = LoadAutoPinRegistry(playerID);
    for _, pin in pairs(pins or {}) do
        if pin and not IsAutoMapPin(pin, autoRegistry) then
            local subject = CreateMapPinSubject(pin);
            if subject and subject.Type == MAP_PIN_TYPE_DISTRICT then
                local plot = Map.GetPlot(subject.X, subject.Y);
                local owningCity = AMT_GetPlotPurchaseCity(plot);
                local owningCityID = owningCity and owningCity:GetID() or nil;
                if owningCityID == nil and GetPinPlanningCityID then
                    owningCityID = GetPinPlanningCityID(playerID, pin, nil);
                end
                if owningCityID == city:GetID() then
                    subject.CityID = owningCityID;
                    subject.isManualPlan = true;
                    subject.pin = pin;
                    table.insert(result, subject);
                end
            end
        end
    end
    return result;
end

local function GetLockedSpecialtyDistricts(city, includeManualPins)
    local locked, lockedSet = {}, {};
    if not city then return locked, lockedSet; end
    local lockedStrategies = {};
    for _, option in ipairs(
        (m_PlannerOptions and m_PlannerOptions[MAP_PIN_TYPE_DISTRICT]) or {}
    ) do
        if option.requiresPopulation
            and IsDistrictAlreadyInCity(city, option.subjectKey)
            and not lockedSet[option.subjectKey] then
            lockedSet[option.subjectKey] = true;
            lockedStrategies[GetDistrictStrategyType(option.subjectKey)] = true;
            table.insert(locked, option.subjectKey);
        end
    end
    if includeManualPins == false then return locked, lockedSet; end

    for _, subject in ipairs(GetManualDistrictPinsForCity(city)) do
        local strategy = GetDistrictStrategyType(subject.Key);
        if strategy and IsPopulationDistrict(subject.Key)
            and not lockedStrategies[strategy] then
            lockedSet[subject.Key] = true;
            lockedStrategies[strategy] = true;
            table.insert(locked, subject.Key);
        end
    end
    return locked, lockedSet;
end

local function NormalizeCitySpecialtyPlan(city, plan)
    if not city or not plan then return {}, {}; end
    local locked, lockedSet = GetLockedSpecialtyDistricts(city);
    plan.slotCount = math.min(
        MAX_SPECIALTY_SLOT_COUNT,
        math.max(
            #locked,
            tonumber(plan.slotCount) or DEFAULT_SPECIALTY_SLOT_COUNT,
            MIN_SPECIALTY_SLOT_COUNT
        )
    );

    local future, seen = {}, {};
    for index = 1, tonumber(plan.slotCount) or 0 do
        local districtType = plan.slots and plan.slots[index] or nil;
        if districtType and not lockedSet[districtType]
            and not seen[districtType] then
            seen[districtType] = true;
            table.insert(future, districtType);
        end
    end

    local normalized = {};
    local nextIndex = #locked + 1;
    for _, districtType in ipairs(future) do
        if nextIndex > plan.slotCount then break; end
        normalized[nextIndex] = districtType;
        nextIndex = nextIndex + 1;
    end
    plan.slots = normalized;
    return locked, lockedSet;
end

local function ActivateCityPlannerState(city)
    local plan = GetCitySpecialtyPlan(city);
    if not plan then return nil; end
    m_SelectedSubjects = plan.selectedSubjects;
    m_PlanningHorizon = plan.planningHorizon;
    m_PrioritizeUnique = plan.prioritizeUnique;
    m_EnablePreserve = plan.enablePreserve;
    m_YieldFocusStates = plan.yieldFocusStates;
    return plan;
end

local function FindSpecialtySlot(plan, districtType)
    if not plan then return nil; end
    for index = 1, plan.slotCount do
        if plan.slots[index] == districtType then return index; end
    end
    return nil;
end

local function RebuildSpecialtySelectionUnion()
    local selected = m_SelectedSubjects[MAP_PIN_TYPE_DISTRICT] or {};
    for _, option in ipairs(m_PlannerOptions[MAP_PIN_TYPE_DISTRICT] or {}) do
        if option.requiresPopulation then selected[option.subjectKey] = false; end
    end
    local plan = GetCitySpecialtyPlan(GetSelectedCity());
    if plan then
        for index = 1, tonumber(plan.slotCount) or 0 do
            local districtType = plan.slots and plan.slots[index] or nil;
            if districtType then selected[districtType] = true; end
        end
    end
end

local function ClearSelectionFeedback()
    ClearPendingPreview(true);
    if Controls.WarningText then
        Controls.WarningText:SetHide(true);
        Controls.WarningText:SetText("");
    end
    if m_ResultText then
        m_ResultText:SetHide(false);
        m_ResultText:SetText(Locale.Lookup("LOC_AMT_CALCULATION_HINT"));
        m_ResultText:SetToolTipString("");
    end
end

local function CountSelectedSubjects(subjectType)
    local count = 0;
    if subjectType == MAP_PIN_TYPE_DISTRICT then
        for districtType, selected in pairs(
            m_SelectedSubjects[subjectType] or {}
        ) do
            if selected and not IsPopulationDistrict(districtType) then
                count = count + 1;
            end
        end
        local plan = GetCitySpecialtyPlan(GetSelectedCity());
        for index = 1, plan and plan.slotCount or 0 do
            if plan.slots[index] then count = count + 1; end
        end
    else
        for _, selected in pairs(m_SelectedSubjects[subjectType] or {}) do
            if selected then count = count + 1; end
        end
    end
    return count;
end

local RefreshPlannerItemGrid;

local DISTRICT_YIELD_FOCUS = {
    DISTRICT_CAMPUS = "YIELD_SCIENCE",
    DISTRICT_THEATER = "YIELD_CULTURE",
    DISTRICT_COMMERCIAL_HUB = "YIELD_GOLD",
    DISTRICT_HARBOR = "YIELD_GOLD",
    DISTRICT_HOLY_SITE = "YIELD_FAITH",
    DISTRICT_INDUSTRIAL_ZONE = "YIELD_PRODUCTION",
    DISTRICT_ENCAMPMENT = "YIELD_PRODUCTION",
    DISTRICT_GOVERNMENT = "YIELD_PRODUCTION",
    DISTRICT_ENTERTAINMENT_COMPLEX = "YIELD_CULTURE",
    DISTRICT_WATER_ENTERTAINMENT_COMPLEX = "YIELD_CULTURE",
    DISTRICT_PRESERVE = "YIELD_CULTURE",
};

local function GetDistrictYieldFocus(districtType)
    return DISTRICT_YIELD_FOCUS[GetDistrictStrategyType(districtType)];
end

local function GetYieldFocusStateText(state)
    if state == 1 then return Locale.Lookup("LOC_AMT_YIELD_FOCUS_PRIORITY"); end
    if state == -1 then return Locale.Lookup("LOC_AMT_YIELD_FOCUS_IGNORE"); end
    return Locale.Lookup("LOC_AMT_YIELD_FOCUS_NEUTRAL");
end

local function RefreshYieldFocusButtons()
    for yieldType, entry in pairs(m_YieldFocusButtons) do
        local button = entry and entry.button or entry;
        if button then
            local state = m_YieldFocusStates[yieldType] or 0;
            if button.SetCheck then button:SetCheck(state == 1); end
            button:SetDisabled(state == -1);
            if entry.ignore then entry.ignore:SetHide(state ~= -1); end
            button:SetToolTipString(Locale.Lookup(
                "LOC_AMT_YIELD_FOCUS_TOOLTIP",
                GetYieldDisplay(yieldType),
                GetYieldFocusStateText(state)
            ));
        end
    end
end

local function GetYieldFocusSummary(states)
    states = states or m_YieldFocusStates;
    local prioritized, ignored = {}, {};
    for _, yieldType in ipairs(YIELD_LIST) do
        local state = states[yieldType] or 0;
        if state == 1 then
            table.insert(prioritized, GetYieldDisplay(yieldType));
        elseif state == -1 then
            table.insert(ignored, GetYieldDisplay(yieldType));
        end
    end
    if #prioritized == 0 and #ignored == 0 then
        return Locale.Lookup("LOC_AMT_YIELD_FOCUS_NEUTRAL");
    end
    local parts = {};
    if #prioritized > 0 then
        table.insert(parts, Locale.Lookup("LOC_AMT_YIELD_FOCUS_PRIORITY")
            .. "：" .. table.concat(prioritized, "、"));
    end
    if #ignored > 0 then
        table.insert(parts, Locale.Lookup("LOC_AMT_YIELD_FOCUS_IGNORE")
            .. "：" .. table.concat(ignored, "、"));
    end
    return table.concat(parts, "；");
end

local function GetSpecialtyAutoRank(districtType)
    local baseType = GetDistrictStrategyType(districtType);
    local balancedOrder = GOAL_DISTRICT_ORDER.BALANCED or {};
    local rank = 100;
    for index, presetType in ipairs(balancedOrder) do
        if baseType == presetType then rank = 100 - index * 3; break; end
    end
    local yieldType = GetDistrictYieldFocus(districtType);
    local focus = yieldType and (m_YieldFocusStates[yieldType] or 0) or 0;
    if focus == 1 then rank = rank + 100; end
    if focus == -1 then rank = rank - 1000; end
    if m_PrioritizeUnique and IsUniqueDistrict(districtType) then
        rank = rank + 60;
    end
    return rank;
end

local function ClearSlotHighlights()
    for _, instance in ipairs(m_SpecialtySlotInstances) do
        if instance.DropHighlight then instance.DropHighlight:SetHide(true); end
    end
    m_SelectedSlotDropTarget = nil;
end

local function HighlightSlotTarget(control)
    ClearSlotHighlights();
    if not control then return; end
    local slotIndex = m_SlotControlToIndex[control];
    local instance = slotIndex and m_SpecialtySlotInstances[slotIndex] or nil;
    if instance and instance.DropHighlight then
        instance.DropHighlight:SetHide(false);
        m_SelectedSlotDropTarget = control;
    end
end

local function RefreshSpecialtySelectionsForCurrentCity()
    local city = GetSelectedCity();
    local plan = GetCitySpecialtyPlan(city);
    m_SpecialtyOrder = {};
    if plan then
        NormalizeCitySpecialtyPlan(city, plan);
        for index = 1, plan.slotCount do
            local districtType = plan.slots[index];
            if districtType then
                table.insert(m_SpecialtyOrder, districtType);
                m_DistrictPriorities[districtType] = 100 - math.min(index, 98);
            end
        end
    end
    RebuildSpecialtySelectionUnion();
end

local function AssignDistrictToSpecialtySlot(plan, districtType, targetIndex, sourceIndex)
    if not plan or not districtType or not targetIndex then return false; end
    if targetIndex < 1 or targetIndex > plan.slotCount then return false; end
    local city = GetSelectedCity();
    local locked, lockedSet = NormalizeCitySpecialtyPlan(city, plan);
    if targetIndex <= #locked or lockedSet[districtType]
        or IsDistrictAlreadyInCity(city, districtType) then
        return false;
    end
    local existingIndex = FindSpecialtySlot(plan, districtType);
    local fromIndex = sourceIndex or existingIndex;
    if fromIndex == targetIndex then return false; end
    local displaced = plan.slots[targetIndex];
    plan.slots[targetIndex] = districtType;
    if fromIndex and fromIndex >= 1 and fromIndex <= plan.slotCount then
        plan.slots[fromIndex] = displaced;
    elseif existingIndex and existingIndex ~= targetIndex then
        plan.slots[existingIndex] = nil;
    end
    return true;
end

local function ToggleDistrictInNextSlot(districtType)
    local city = GetSelectedCity();
    local plan = GetCitySpecialtyPlan(city);
    if not plan then return false; end
    local locked, lockedSet = NormalizeCitySpecialtyPlan(city, plan);
    if lockedSet[districtType]
        or IsDistrictAlreadyInCity(city, districtType) then
        return false;
    end
    local existingIndex = FindSpecialtySlot(plan, districtType);
    if existingIndex then
        plan.slots[existingIndex] = nil;
        return true;
    end
    for index = #locked + 1, plan.slotCount do
        if not plan.slots[index] then
            plan.slots[index] = districtType;
            return true;
        end
    end
    if m_ResultText then
        m_ResultText:SetText(Locale.Lookup("LOC_AMT_SLOT_FULL"));
    end
    return false;
end

local function FinishSpecialtyDrag(kDragStruct)
    local city = GetSelectedCity();
    local plan = GetCitySpecialtyPlan(city);
    local dropControl = m_SelectedSlotDropTarget;
    if not dropControl and kDragStruct and kDragStruct.GetControl then
        dropControl = kDragStruct:GetControl():GetBestOverlappingControl(
            m_SlotDropTargets
        );
    end
    local targetIndex = dropControl and m_SlotControlToIndex[dropControl] or nil;
    local changed = false;
    if plan and targetIndex and m_DraggedSpecialtyDistrict then
        changed = AssignDistrictToSpecialtySlot(
            plan, m_DraggedSpecialtyDistrict, targetIndex, m_DragSourceSlot
        );
    elseif plan and m_DraggedSpecialtyDistrict and not m_DragSourceSlot then
        changed = ToggleDistrictInNextSlot(m_DraggedSpecialtyDistrict);
    end
    ClearSlotHighlights();
    m_DraggedSpecialtyDistrict = nil;
    m_DragSourceSlot = nil;
    if changed then
        RefreshSpecialtySelectionsForCurrentCity();
        if RefreshPlannerItemGrid then RefreshPlannerItemGrid(); end
        ClearSelectionFeedback();
    end
end

local function OnSpecialtyDrag(kDragStruct)
    if not kDragStruct then return; end
    local control = kDragStruct:GetControl();
    HighlightSlotTarget(control:GetBestOverlappingControl(m_SlotDropTargets));
end

local function RefreshSpecialtySlotEntries()
    local city = GetSelectedCity();
    local plan = GetCitySpecialtyPlan(city);
    m_PriorityEntryIM:ResetInstances();
    m_SpecialtySlotInstances = {};
    m_SlotDropTargets = {};
    m_SlotControlToIndex = {};
    if not plan then return; end
    local locked = NormalizeCitySpecialtyPlan(city, plan);

    if Controls.SlotCountLabel then
        Controls.SlotCountLabel:SetText(tostring(plan.slotCount));
    end
    if Controls.RemoveSlotButton then
        Controls.RemoveSlotButton:SetDisabled(
            plan.slotCount <= math.max(MIN_SPECIALTY_SLOT_COUNT, #locked)
        );
    end
    if Controls.AddSlotButton then
        Controls.AddSlotButton:SetDisabled(
            plan.slotCount >= MAX_SPECIALTY_SLOT_COUNT
        );
    end
    local currentPopulation =
        math.max(
            POPULATION_BUDGET_RANGE.minimum,
            tonumber(city and city:GetPopulation())
                or POPULATION_BUDGET_RANGE.minimum
        );
    local requiredPopulation =
        GetRequiredPopulationForSpecialtySlot(plan.slotCount);
    if Controls.PopulationBudgetLabel then
        Controls.PopulationBudgetLabel:SetText(
            tostring(plan.populationBudget)
        );
        Controls.PopulationBudgetLabel:SetToolTipString(Locale.Lookup(
            "LOC_AMT_POPULATION_BUDGET_TOOLTIP",
            currentPopulation,
            requiredPopulation
        ));
    end
    if Controls.RemovePopulationButton then
        Controls.RemovePopulationButton:SetDisabled(
            plan.populationBudget <= currentPopulation
        );
    end
    if Controls.AddPopulationButton then
        Controls.AddPopulationButton:SetDisabled(
            plan.populationBudget >= POPULATION_BUDGET_RANGE.maximum
        );
    end
    if Controls.PopulationWarning then
        local isInsufficient =
            plan.populationBudget < requiredPopulation;
        Controls.PopulationWarning:SetHide(not isInsufficient);
        Controls.PopulationWarning:SetText(isInsufficient
            and Locale.Lookup(
                "LOC_AMT_POPULATION_BUDGET_WARNING",
                plan.populationBudget,
                requiredPopulation,
                plan.slotCount
            )
            or "");
        Controls.PopulationWarning:SetToolTipString(isInsufficient
            and Locale.Lookup(
                "LOC_AMT_POPULATION_BUDGET_WARNING_TOOLTIP",
                plan.slotCount,
                requiredPopulation
            )
            or "");
    end

    for index = 1, plan.slotCount do
        local instance = m_PriorityEntryIM:GetInstance();
        m_SpecialtySlotInstances[index] = instance;
        instance.OrderIndex:SetText(tostring(index) .. ".");
        local lockedDistrict = locked[index];
        local districtType = lockedDistrict or plan.slots[index];
        if lockedDistrict then
            instance.SlotIcon:SetHide(false);
            instance.SlotIcon:SetIcon(GetSubjectIcon(
                MAP_PIN_TYPE_DISTRICT, lockedDistrict
            ));
            instance.SlotName:SetText(Locale.Lookup(
                "LOC_AMT_SLOT_LOCKED",
                GetDistrictDisplay(lockedDistrict)
            ));
            instance.ClearSlotButton:SetHide(true);
            instance.SlotDrag:SetHide(true);
            instance.SlotFrame:SetToolTipString(Locale.Lookup(
                "LOC_AMT_SLOT_LOCKED_TOOLTIP",
                GetDistrictDisplay(lockedDistrict)
            ));
        elseif districtType then
            table.insert(m_SlotDropTargets, instance.SlotFrame);
            m_SlotControlToIndex[instance.SlotFrame] = index;
            instance.SlotIcon:SetHide(false);
            instance.SlotIcon:SetIcon(GetSubjectIcon(
                MAP_PIN_TYPE_DISTRICT, districtType
            ));
            instance.SlotName:SetText(GetDistrictDisplay(districtType));
            instance.ClearSlotButton:SetHide(false);
            instance.SlotFrame:SetToolTipString(GetDistrictDisplay(districtType));
            instance.SlotDrag:SetHide(false);
            local slotIndex = index;
            local slotDistrict = districtType;
            instance.SlotDrag:RegisterCallback(Drag.eDown, function()
                m_DraggedSpecialtyDistrict = slotDistrict;
                m_DragSourceSlot = slotIndex;
            end);
            instance.SlotDrag:RegisterCallback(Drag.eDrag, OnSpecialtyDrag);
            instance.SlotDrag:RegisterCallback(Drag.eDrop, FinishSpecialtyDrag);
            instance.ClearSlotButton:RegisterCallback(Mouse.eLClick, function()
                plan.slots[slotIndex] = nil;
                RefreshSpecialtySelectionsForCurrentCity();
                RefreshPlannerItemGrid();
                ClearSelectionFeedback();
            end);
        else
            table.insert(m_SlotDropTargets, instance.SlotFrame);
            m_SlotControlToIndex[instance.SlotFrame] = index;
            instance.SlotIcon:SetHide(true);
            instance.SlotName:SetText(Locale.Lookup("LOC_AMT_SLOT_EMPTY"));
            instance.ClearSlotButton:SetHide(true);
            instance.SlotDrag:SetHide(true);
            instance.SlotFrame:SetToolTipString(Locale.Lookup(
                "LOC_AMT_SPECIALTY_MILESTONE",
                GetRequiredPopulationForSpecialtySlot(index)
            ));
        end
    end
    Controls.WeightStack:CalculateSize();
    Controls.WeightStack:ReprocessAnchoring();
    Controls.PriorityScroll:CalculateInternalSize();
end

local function ReconcileSpecialtyOrder()
    RefreshSpecialtySelectionsForCurrentCity();
end

local function RefreshDistrictPriorityEntries()
    RefreshSpecialtySlotEntries();
end

local function RefreshCategoryTabs()
    local buttons = {
        [MAP_PIN_TYPE_DISTRICT] = Controls.DistrictTabButton,
        [MAP_PIN_TYPE_IMPROVEMENT] = Controls.ImprovementTabButton,
        [MAP_PIN_TYPE_WONDER] = Controls.WonderTabButton,
    };
    local labels = {
        [MAP_PIN_TYPE_DISTRICT] = "LOC_AMT_CATEGORY_DISTRICTS",
        [MAP_PIN_TYPE_IMPROVEMENT] = "LOC_AMT_CATEGORY_IMPROVEMENTS",
        [MAP_PIN_TYPE_WONDER] = "LOC_AMT_CATEGORY_WONDERS",
    };
    for subjectType, button in pairs(buttons) do
        if button then
            button:SetDisabled(subjectType == m_CurrentCategory);
            button:SetText(
                Locale.Lookup(labels[subjectType])
                .. " (" .. CountSelectedSubjects(subjectType) .. ")"
            );
        end
    end
end

RefreshPlannerItemGrid = function()
    m_PlannerIconIM:ResetInstances();
    m_IconInstances = {};
    local selected = m_SelectedSubjects[m_CurrentCategory] or {};
    local city = GetSelectedCity();
    local allOptions = m_PlannerOptions[m_CurrentCategory] or {};
    local options = {};
    for _, option in ipairs(allOptions) do
        local alreadyPlaced = m_CurrentCategory == MAP_PIN_TYPE_DISTRICT
            and IsDistrictAlreadyInCity(city, option.subjectKey);
        if alreadyPlaced then
            selected[option.subjectKey] = false;
        else
            table.insert(options, option);
        end
    end
    local currentPlan = GetCitySpecialtyPlan(city);
    local function AddEraHeader(eraType, eraName, optionCount)
        local instance = m_PlannerIconIM:GetInstance();
        instance.Top:SetSizeX(585);
        instance.Top:SetSizeY(36);
        instance.IconButton:SetHide(true);
        instance.IconDrag:SetHide(true);
        instance.EraGroup:SetHide(false);
        instance.EraSelectButton:SetHide(false);
        instance.EraLabel:SetText(Locale.Lookup(
            "LOC_AMT_ERA_GROUP_LABEL", eraName, optionCount
        ));
        local allSelected = true;
        for _, option in ipairs(options) do
            if option.eraType == eraType
                and not selected[option.subjectKey] then
                allSelected = false;
                break;
            end
        end
        instance.EraSelectButton:SetText(Locale.Lookup(
            allSelected and "LOC_AMT_CLEAR_ERA"
                or "LOC_AMT_SELECT_ERA"
        ));
        local headerEraType = eraType;
        local selectEra = not allSelected;
        instance.EraSelectButton:RegisterCallback(Mouse.eLClick, function()
            for _, option in ipairs(
                m_PlannerOptions[MAP_PIN_TYPE_IMPROVEMENT] or {}
            ) do
                if option.eraType == headerEraType then
                    m_SelectedSubjects[MAP_PIN_TYPE_IMPROVEMENT]
                        [option.subjectKey] = selectEra;
                end
            end
            RefreshPlannerItemGrid();
            ClearSelectionFeedback();
        end);
    end
    local function AddDistrictGroupHeader(labelKey, optionCount)
        local instance = m_PlannerIconIM:GetInstance();
        instance.Top:SetSizeX(585);
        instance.Top:SetSizeY(34);
        instance.IconButton:SetHide(true);
        instance.IconDrag:SetHide(true);
        instance.EraGroup:SetHide(false);
        instance.EraSelectButton:SetHide(true);
        instance.EraLabel:SetText(
            Locale.Lookup(labelKey) .. " (" .. tostring(optionCount) .. ")"
        );
    end
    local function AddSubjectIcon(option)
        local instance = m_PlannerIconIM:GetInstance();
        -- InstanceManager recycles controls across category tabs.  Always
        -- clear old handlers first so a district icon cannot retain the
        -- click callback of a wonder that previously occupied this instance.
        instance.IconButton:ClearCallback(Mouse.eLClick);
        instance.IconDrag:ClearCallback(Drag.eDown);
        instance.IconDrag:ClearCallback(Drag.eDrag);
        instance.IconDrag:ClearCallback(Drag.eDrop);
        instance.Top:SetSizeX(43);
        instance.Top:SetSizeY(43);
        instance.IconButton:SetHide(false);
        instance.EraGroup:SetHide(true);
        local subjectKey = option.subjectKey;
        local isSpecialty = m_CurrentCategory == MAP_PIN_TYPE_DISTRICT
            and option.requiresPopulation;
        local isSelected = isSpecialty
            and FindSpecialtySlot(currentPlan, subjectKey) ~= nil
            or selected[subjectKey];
        instance.Icon:SetIcon(option.iconName);
        local isDisabledPreserve = option.isPreserve and not m_EnablePreserve;
        local tooltip = GetSubjectTooltip(option);
        if isDisabledPreserve then
            tooltip = tooltip .. "[NEWLINE][NEWLINE]"
                .. Locale.Lookup("LOC_AMT_PRESERVE_DISABLED_TOOLTIP");
        elseif option.isUnique then
            tooltip = tooltip .. "[NEWLINE][NEWLINE]"
                .. Locale.Lookup("LOC_AMT_UNIQUE_DISTRICT_BADGE");
        end
        instance.IconButton:SetToolTipString(tooltip);
        instance.IconButton:SetDisabled(isDisabledPreserve);
        instance.SelectedOverlay:SetHide(not isSelected);
        instance.SelectedMark:SetHide(not isSelected);
        -- Catalog icons are ordinary click targets.  Reordering remains a
        -- drag action on the visible numbered slots at the right, where the
        -- destination and highlight are unambiguous.
        instance.IconDrag:SetHide(true);
        if isSpecialty and not isDisabledPreserve then
            instance.IconButton:RegisterCallback(Mouse.eLClick, function()
                if ToggleDistrictInNextSlot(subjectKey) then
                    RefreshSpecialtySelectionsForCurrentCity();
                    RefreshPlannerItemGrid();
                end
                ClearSelectionFeedback();
            end);
        else
            instance.IconButton:RegisterCallback(Mouse.eLClick, function()
                selected[subjectKey] = not selected[subjectKey];
                if m_CurrentCategory == MAP_PIN_TYPE_IMPROVEMENT then
                    -- Rebuild the era header so its select/clear state always
                    -- reflects individual icon changes.
                    RefreshPlannerItemGrid();
                else
                    instance.SelectedOverlay:SetHide(not selected[subjectKey]);
                    instance.SelectedMark:SetHide(not selected[subjectKey]);
                    if Controls.SelectionCount then
                        Controls.SelectionCount:SetText(Locale.Lookup(
                            "LOC_AMT_SELECTION_COUNT",
                            CountSelectedSubjects(m_CurrentCategory)
                        ));
                    end
                    RefreshCategoryTabs();
                    RefreshDistrictPriorityEntries();
                end
                ClearSelectionFeedback();
            end);
        end
        m_IconInstances[subjectKey] = instance;
    end
    if m_CurrentCategory == MAP_PIN_TYPE_DISTRICT then
        local specialtyCount, supportCount = 0, 0;
        for _, option in ipairs(options) do
            if option.requiresPopulation then
                specialtyCount = specialtyCount + 1;
            else
                supportCount = supportCount + 1;
            end
        end
        AddDistrictGroupHeader(
            "LOC_AMT_DISTRICT_GROUP_SPECIALTY", specialtyCount
        );
        for _, option in ipairs(options) do
            if option.requiresPopulation then AddSubjectIcon(option); end
        end
        AddDistrictGroupHeader(
            "LOC_AMT_DISTRICT_GROUP_SUPPORT", supportCount
        );
        for _, option in ipairs(options) do
            if not option.requiresPopulation then AddSubjectIcon(option); end
        end
    else
        local currentEraType = nil;
        for _, option in ipairs(options) do
            if m_CurrentCategory == MAP_PIN_TYPE_IMPROVEMENT
                and option.eraType ~= currentEraType then
                currentEraType = option.eraType;
                local optionCount = 0;
                for _, eraOption in ipairs(options) do
                    if eraOption.eraType == currentEraType then
                        optionCount = optionCount + 1;
                    end
                end
                AddEraHeader(currentEraType, option.eraName, optionCount);
            end
            AddSubjectIcon(option);
        end
    end
    Controls.ItemGrid:CalculateSize();
    Controls.ItemGrid:ReprocessAnchoring();
    Controls.ItemScroll:CalculateInternalSize();

    local hintKey = "LOC_AMT_CATEGORY_DISTRICTS_HINT";
    if m_CurrentCategory == MAP_PIN_TYPE_IMPROVEMENT then
        hintKey = "LOC_AMT_CATEGORY_IMPROVEMENTS_HINT";
    elseif m_CurrentCategory == MAP_PIN_TYPE_WONDER then
        hintKey = "LOC_AMT_CATEGORY_WONDERS_HINT";
    end
    local hideCategoryHint =
        m_CurrentCategory == MAP_PIN_TYPE_IMPROVEMENT;
    Controls.CategoryHint:SetHide(hideCategoryHint);
    Controls.CategoryHint:SetText(
        hideCategoryHint and "" or Locale.Lookup(hintKey)
    );
    local ruleKey = "LOC_AMT_CATEGORY_DISTRICTS_KEY_RULE";
    if m_CurrentCategory == MAP_PIN_TYPE_IMPROVEMENT then
        ruleKey = "LOC_AMT_CATEGORY_IMPROVEMENTS_KEY_RULE";
    elseif m_CurrentCategory == MAP_PIN_TYPE_WONDER then
        ruleKey = "LOC_AMT_CATEGORY_WONDERS_KEY_RULE";
    end
    local hideRuleBanner = m_CurrentCategory == MAP_PIN_TYPE_WONDER;
    Controls.RuleBanner:SetHide(hideRuleBanner);
    if m_CurrentCategory == MAP_PIN_TYPE_IMPROVEMENT then
        local plan = GetCitySpecialtyPlan(GetSelectedCity());
        local population = plan and plan.populationBudget or 1;
        Controls.AutoCountLabel:SetText(Locale.Lookup(
            ruleKey,
            population,
            AMT_GetTargetImprovementPlotCount(population)
        ));
    else
        Controls.AutoCountLabel:SetText(Locale.Lookup(ruleKey));
    end
    Controls.SelectionCount:SetText(Locale.Lookup(
        "LOC_AMT_SELECTION_COUNT", CountSelectedSubjects(m_CurrentCategory)
    ));
    Controls.LongTermButton:SetDisabled(
        m_CurrentCategory == MAP_PIN_TYPE_WONDER
    );
    Controls.CurrentBuildableButton:SetDisabled(
        m_CurrentCategory == MAP_PIN_TYPE_WONDER
    );
    Controls.LongTermButton:SetText(
        Locale.Lookup("LOC_AMT_LONG_TERM")
        .. (m_PlanningHorizon == "LONG_TERM"
            and (" " .. Locale.Lookup("LOC_AMT_ACTIVE_SUFFIX")) or "")
    );
    Controls.CurrentBuildableButton:SetText(
        Locale.Lookup("LOC_AMT_CURRENT_BUILDABLE")
        .. (m_PlanningHorizon == "CURRENT"
            and (" " .. Locale.Lookup("LOC_AMT_ACTIVE_SUFFIX")) or "")
    );
    Controls.LongTermButton:SetToolTipString(
        m_CurrentCategory == MAP_PIN_TYPE_WONDER
            and Locale.Lookup("LOC_AMT_WONDER_NO_SELECT_ALL_TOOLTIP")
            or Locale.Lookup("LOC_AMT_LONG_TERM_TOOLTIP")
    );
    Controls.CurrentBuildableButton:SetToolTipString(
        m_CurrentCategory == MAP_PIN_TYPE_WONDER
            and Locale.Lookup("LOC_AMT_WONDER_NO_SELECT_ALL_TOOLTIP")
            or Locale.Lookup("LOC_AMT_CURRENT_CONDITIONS_TOOLTIP")
    );
    RefreshCategoryTabs();
    RefreshDistrictPriorityEntries();
end

local function SwitchPlannerCategory(subjectType)
    if not m_PlannerOptions[subjectType] then return; end
    m_CurrentCategory = subjectType;
    RefreshPlannerItemGrid();
end

local function SetCurrentCategorySelection(selected)
    if selected and m_CurrentCategory == MAP_PIN_TYPE_WONDER then return; end
    local categorySelection = m_SelectedSubjects[m_CurrentCategory];
    local city = GetSelectedCity();
    for _, option in ipairs(m_PlannerOptions[m_CurrentCategory] or {}) do
        local alreadyPlaced = m_CurrentCategory == MAP_PIN_TYPE_DISTRICT
            and IsDistrictAlreadyInCity(city, option.subjectKey);
        if alreadyPlaced then
            categorySelection[option.subjectKey] = false;
        elseif m_CurrentCategory ~= MAP_PIN_TYPE_DISTRICT
            or not option.requiresPopulation then
            categorySelection[option.subjectKey] = selected;
        end
    end
    if not selected and m_CurrentCategory == MAP_PIN_TYPE_DISTRICT then
        local plan = GetCitySpecialtyPlan(GetSelectedCity());
        if plan then plan.slots = {}; end
        RefreshSpecialtySelectionsForCurrentCity();
    end
    RefreshPlannerItemGrid();
    ClearSelectionFeedback();
end

local function IsSubjectCurrentlyUnlocked(option, playerID)
    local row = GetSubjectRow(option.subjectType, option.subjectKey);
    local player = Players[playerID];
    if not row or not player then return false; end
    if row.PrereqTech then
        local tech = GameInfo.Technologies[row.PrereqTech];
        if tech and not player:GetTechs():HasTech(tech.Index) then return false; end
    end
    if row.PrereqCivic then
        local civic = GameInfo.Civics[row.PrereqCivic];
        if civic and not player:GetCulture():HasCivic(civic.Index) then
            return false;
        end
    end
    return true;
end

local function ApplyCurrentCategoryPreset(currentOnly)
    if m_CurrentCategory == MAP_PIN_TYPE_WONDER then return; end
    m_PlanningHorizon = currentOnly and "CURRENT" or "LONG_TERM";
    local cityPlan = GetCitySpecialtyPlan(GetSelectedCity());
    if cityPlan then cityPlan.planningHorizon = m_PlanningHorizon; end
    local categorySelection = m_SelectedSubjects[m_CurrentCategory];
    local playerID = Game.GetLocalPlayer();
    local city = GetSelectedCity();
    for _, option in ipairs(m_PlannerOptions[m_CurrentCategory] or {}) do
        local alreadyPlaced = m_CurrentCategory == MAP_PIN_TYPE_DISTRICT
            and IsDistrictAlreadyInCity(city, option.subjectKey);
        if alreadyPlaced then
            categorySelection[option.subjectKey] = false;
        elseif m_CurrentCategory ~= MAP_PIN_TYPE_DISTRICT
            or not option.requiresPopulation then
            categorySelection[option.subjectKey] =
                (not option.isPreserve or m_EnablePreserve)
                and (not currentOnly
                    or IsSubjectCurrentlyUnlocked(option, playerID));
        end
    end
    RefreshPlannerItemGrid();
    ClearSelectionFeedback();
end

local function ReconcileSessionSelections()
    local city = GetSelectedCity();
    local subjectTypes = {
        MAP_PIN_TYPE_DISTRICT,
        MAP_PIN_TYPE_IMPROVEMENT,
        MAP_PIN_TYPE_WONDER,
    };
    for _, subjectType in ipairs(subjectTypes) do
        local valid = {};
        for _, option in ipairs(m_PlannerOptions[subjectType] or {}) do
            if subjectType ~= MAP_PIN_TYPE_DISTRICT
                or not IsDistrictAlreadyInCity(city, option.subjectKey) then
                valid[option.subjectKey] = true;
            end
        end
        local selected = m_SelectedSubjects[subjectType] or {};
        for subjectKey in pairs(selected) do
            if not valid[subjectKey] then selected[subjectKey] = nil; end
        end
        m_SelectedSubjects[subjectType] = selected;
    end
    local validSpecialty = {};
    for _, option in ipairs(m_PlannerOptions[MAP_PIN_TYPE_DISTRICT] or {}) do
        if option.requiresPopulation
            and not IsDistrictAlreadyInCity(city, option.subjectKey) then
            validSpecialty[option.subjectKey] = true;
        end
    end
    local plan = GetCitySpecialtyPlan(city);
    if plan then
        NormalizeCitySpecialtyPlan(city, plan);
        for index = 1, tonumber(plan.slotCount) or 0 do
            local districtType = plan.slots and plan.slots[index] or nil;
            if districtType and (not validSpecialty[districtType]
                or (IsPreserveDistrict(districtType) and not m_EnablePreserve)) then
                plan.slots[index] = nil;
            end
        end
    end
    RebuildSpecialtySelectionUnion();
end

local function RepopulatePopup()
    m_IsPlanning = false;
    if Controls.OkButton then Controls.OkButton:SetDisabled(false); end

    local playerID = Game.GetLocalPlayer();
    Log("RepopulatePopup playerID=" .. tostring(playerID));

    local city = GetSelectedCity();
    if city then
        m_CityName = Locale.Lookup(city:GetName());
        Controls.CityName:SetText(m_CityName);
        Log("Selected city: " .. m_CityName);
    else
        Controls.CityName:SetText(Locale.Lookup("LOC_AMT_NO_CITY"));
    end

    local cityPlan = ActivateCityPlannerState(city);
    m_PlannerOptions = BuildPlayerPlannerOptions(playerID);
    ReconcileSessionSelections();
    local uniqueNames = {};
    for _, option in ipairs(m_PlannerOptions[MAP_PIN_TYPE_DISTRICT] or {}) do
        if option.isUnique then
            table.insert(uniqueNames, GetDistrictDisplay(option.subjectKey));
        end
    end
    if Controls.UniqueDirectionCheck then
        Controls.UniqueDirectionCheck:SetCheck(m_PrioritizeUnique);
        -- Civ VI's CheckBox control exposes SetCheck/SetDisabled, but not SetText.
        -- Keep the stable XML label and surface civilization-specific names
        -- through the runtime tooltip instead.
        if type(Controls.UniqueDirectionCheck.SetToolTipString) == "function" then
            Controls.UniqueDirectionCheck:SetToolTipString(Locale.Lookup(
                "LOC_AMT_UNIQUE_DIRECTION_DYNAMIC",
                #uniqueNames > 0 and table.concat(uniqueNames, "、")
                    or Locale.Lookup("LOC_AMT_NO_UNIQUE_DISTRICT")
            ));
        end
        Controls.UniqueDirectionCheck:SetDisabled(#uniqueNames == 0);
    end
    if Controls.PreservePlanningCheck then
        Controls.PreservePlanningCheck:SetCheck(m_EnablePreserve);
    end
    if cityPlan then
        if m_OverwriteCheck then
            m_OverwriteCheck:SetCheck(cityPlan.overwriteAutoPins);
        end
        if m_ClearCheck then
            m_ClearCheck:SetCheck(cityPlan.clearBeforePlan);
        end
        if m_ClearManualCheck then
            m_ClearManualCheck:SetCheck(cityPlan.clearManualPins);
        end
    end
    ReconcileSpecialtyOrder();
    Log(string.format(
        "Planner options districts=%d improvements=%d wonders=%d",
        #m_PlannerOptions[MAP_PIN_TYPE_DISTRICT],
        #m_PlannerOptions[MAP_PIN_TYPE_IMPROVEMENT],
        #m_PlannerOptions[MAP_PIN_TYPE_WONDER]
    ));
    RefreshPlannerItemGrid();

    ClearPendingPreview(true);
    if m_ResultText then
        m_ResultText:SetText(Locale.Lookup("LOC_AMT_CALCULATION_HINT"));
        m_ResultText:SetToolTipString("");
    end
    RefreshUndoButton(playerID);
    RefreshClearManualControl();
end

local function ReadSelectedSubjects()
    local selection = {
        districts = {},
        improvements = {},
        wonders = {},
        districtPriorities = {},
        specialtyOrder = {},
        specialtySlotsByCity = {},
        specialtySlotCountByCity = {},
        populationBudgetByCity = {},
        yieldFocusStates = {},
        prioritizeUnique = m_PrioritizeUnique,
        enablePreserve = m_EnablePreserve,
        planningHorizon = m_PlanningHorizon,
    };
    local targets = {
        [MAP_PIN_TYPE_DISTRICT] = selection.districts,
        [MAP_PIN_TYPE_IMPROVEMENT] = selection.improvements,
        [MAP_PIN_TYPE_WONDER] = selection.wonders,
    };
    for subjectType, selected in pairs(m_SelectedSubjects) do
        for subjectKey, isSelected in pairs(selected) do
            if isSelected
                and (subjectType ~= MAP_PIN_TYPE_DISTRICT
                    or m_EnablePreserve
                    or not IsPreserveDistrict(subjectKey)) then
                table.insert(targets[subjectType], subjectKey);
            end
        end
        table.sort(targets[subjectType]);
    end
    for _, districtType in ipairs(selection.districts) do
        selection.districtPriorities[districtType] =
            IsPopulationDistrict(districtType) and 80 or 40;
    end
    local city = GetSelectedCity();
    local plan = GetCitySpecialtyPlan(city);
    if city and plan then
        local cityID = city:GetID();
        selection.specialtySlotsByCity[cityID] = {};
        selection.specialtySlotCountByCity[cityID] = plan.slotCount;
        selection.populationBudgetByCity[cityID] = plan.populationBudget;
        for index = 1, plan.slotCount do
            local districtType = plan.slots[index];
            if districtType then
                selection.specialtySlotsByCity[cityID][index] = districtType;
                selection.districtPriorities[districtType] = math.max(
                    selection.districtPriorities[districtType] or 0,
                    100 - math.min(index, 98)
                );
            end
        end
    end
    for yieldType, state in pairs(m_YieldFocusStates) do
        selection.yieldFocusStates[yieldType] = state;
    end
    return selection;
end

-- A wonder may depend on an adjacent district, but that dependency must never
-- silently change the player's selection. Use the exact same locked-district
-- state as the specialty-slot UI so the preflight prompt cannot disagree with
-- what the player sees on the right side of the planner.
local function GetMissingSelectedWonderDistrict(selection, city)
    local _, lockedSet = GetLockedSpecialtyDistricts(city);
    local lockedStrategies = {};
    for districtType in pairs(lockedSet or {}) do
        lockedStrategies[GetDistrictStrategyType(districtType)] = true;
    end
    for _, wonderType in ipairs(selection.wonders or {}) do
        local requiredDistrict = nil;
        for _, option in ipairs(
            m_PlannerOptions[MAP_PIN_TYPE_WONDER] or {}
        ) do
            if option.subjectKey == wonderType then
                requiredDistrict = option.requiredDistrict;
                break;
            end
        end
        if not requiredDistrict then
            local row = GameInfo.Buildings and GameInfo.Buildings[wonderType]
                or nil;
            requiredDistrict = row and row.AdjacentDistrict or nil;
        end
        if not requiredDistrict and AMT_WonderPlanner
            and AMT_WonderPlanner.GetPlacementRules then
            local rules = AMT_WonderPlanner.GetPlacementRules(wonderType);
            requiredDistrict = rules and rules.adjacentDistrict or nil;
        end
        if requiredDistrict then
            local requiredStrategy = GetDistrictStrategyType(requiredDistrict);
            local isSelected = false;
            for _, selectedDistrict in ipairs(selection.districts or {}) do
                if selectedDistrict == requiredDistrict
                    or GetDistrictStrategyType(selectedDistrict)
                        == requiredStrategy then
                    isSelected = true;
                    break;
                end
            end
            if not isSelected and not lockedStrategies[requiredStrategy] then
                return wonderType, requiredDistrict;
            end
        end
    end
    return nil, nil;
end

local function GetAdjacencyWeights(selection)
    local w = {};
    local focusStates = selection and selection.yieldFocusStates
        or m_YieldFocusStates;
    for _, yt in ipairs(YIELD_LIST) do
        local state = focusStates and focusStates[yt] or 0;
        local baseWeight = DEFAULT_WEIGHTS[yt] or 1;
        w[yt] = state == 1 and baseWeight * 1.75
            or (state == -1 and 0 or baseWeight);
    end
    return w;
end

local function ScoreYields(yields, weights, multiplier)
    local s = 0;
    multiplier = multiplier or 1;
    for yt, amt in pairs(yields) do
        local wgt = weights[yt] or 1;
        s = s + amt * wgt * multiplier;
    end
    return s;
end

function AMT_GetWeightedYieldScore(cacheEntry, yields, weights, multiplier)
    multiplier = multiplier or 1;
    if cacheEntry then
        cacheEntry.weightedScores = cacheEntry.weightedScores or {};
        local cached = cacheEntry.weightedScores[multiplier];
        if cached ~= nil then
            return cached;
        end
    end
    local score = ScoreYields(yields or {}, weights, multiplier);
    if cacheEntry then
        cacheEntry.weightedScores[multiplier] = score;
    end
    return score;
end

local function CopyArray(source)
    local copy = {};
    for i, value in ipairs(source) do copy[i] = value; end
    return copy;
end

local function CopySet(source)
    local copy = {};
    for key, value in pairs(source) do copy[key] = value; end
    return copy;
end

local function GetPlanningCities(primaryCity, includeLinked)
    local playerID = Game.GetLocalPlayer();
    local player = Players[playerID];
    if not player or not primaryCity then return {}; end

    local entries = {};
    for _, city in player:GetCities():Members() do
        local distance = Map.GetPlotDistance(primaryCity:GetX(), primaryCity:GetY(), city:GetX(), city:GetY());
        if city:GetID() == primaryCity:GetID() or (includeLinked and distance <= LINKED_CITY_DISTANCE) then
            table.insert(entries, { city = city, distance = distance });
        end
    end
    table.sort(entries, function(a, b)
        if a.distance ~= b.distance then return a.distance < b.distance; end
        return a.city:GetID() < b.city:GetID();
    end);

    local cities = {};
    for i = 1, math.min(#entries, MAX_LINKED_CITIES) do
        table.insert(cities, entries[i].city);
    end
    return cities;
end

local function CountPlayerDistricts(player, districtType)
    local districtRow = GameInfo.Districts[districtType];
    local playerDistricts = player and player:GetDistricts() or nil;
    if not districtRow or not playerDistricts then return 0; end

    local count = 0;
    for _, district in playerDistricts:Members() do
        if district and district:GetType() == districtRow.Index then
            count = count + 1;
        end
    end
    return count;
end

local function GetExistingPlannedDistricts(cities, ignoredKeys)
    local byCity = {};
    local playerCounts = {};
    local fixedSubjects = {};
    local fixedSubjectKeys = {};
    AMT_PlotDirectives = {};
    for _, city in ipairs(cities) do byCity[city:GetID()] = {}; end

    local playerID = Game.GetLocalPlayer();
    local cfg = PlayerConfigurations[playerID];
    local pins = cfg and cfg:GetMapPins() or {};
    for _, pin in pairs(pins) do
        local subject = pin and CreateMapPinSubject(pin) or nil;
        local key = pin and Key(pin:GetHexX(), pin:GetHexY()) or nil;
        local iconName = pin and pin:GetIconName() or "";
        local directive = nil;
        if iconName == "ICON_UNITOPERATION_REMOVE_FEATURE" then
            directive = { removeFeature = true };
        elseif iconName == "ICON_UNITOPERATION_HARVEST_RESOURCE" then
            directive = { removeResource = true };
        elseif iconName == "ICON_UNITOPERATION_PLANT_FOREST" then
            directive = { plantForest = true };
        end
        if directive and not (ignoredKeys and ignoredKeys[key]) then
            for _, city in ipairs(cities) do
                if Map.GetPlotDistance(
                    city:GetX(), city:GetY(), pin:GetHexX(), pin:GetHexY()
                ) <= 4 then
                    AMT_PlotDirectives[key] = directive;
                    break;
                end
            end
        end
        if subject and subject.Key
            and subject.Type ~= "UNKNOWN"
            and not (ignoredKeys and ignoredKeys[key]) then
            local subjectPlot = Map.GetPlot(subject.X, subject.Y);
            local owningCity = AMT_GetPlotPurchaseCity(subjectPlot);
            local owningCityID = owningCity and owningCity:GetID() or nil;
            if owningCityID == nil and GetPinPlanningCityID then
                owningCityID = GetPinPlanningCityID(playerID, pin, nil);
            end
            subject.CityID = owningCityID;
            subject.isManualPlan = true;
            local isRelevantAnchor = false;
            for _, city in ipairs(cities) do
                if owningCityID ~= nil and city:GetID() == owningCityID then
                    isRelevantAnchor = true;
                    break;
                end
            end
            if isRelevantAnchor then
                table.insert(fixedSubjects, subject);
                fixedSubjectKeys[key] = true;
            end
            if subject.Type == MAP_PIN_TYPE_DISTRICT then
                playerCounts[subject.Key] =
                    (playerCounts[subject.Key] or 0) + 1;
            end
            if owningCityID and byCity[owningCityID]
                and subject.Type == MAP_PIN_TYPE_DISTRICT then
                local counts = byCity[owningCityID];
                counts[subject.Key] = (counts[subject.Key] or 0) + 1;
            end
        end
    end

    -- Existing districts and improvements can receive adjacency from a new
    -- wonder, district, or improvement even when the player never placed a
    -- map tack for them.  Score those reverse benefits as fixed subjects.
    for _, city in ipairs(cities) do
        for _, plot in ipairs(GetPlotsWithinXTiles(
            city:GetX(), city:GetY(), 4
        )) do
            local key = Key(plot:GetX(), plot:GetY());
            if not fixedSubjectKeys[key]
                and not (ignoredKeys and ignoredKeys[key])
                and plot:IsOwned()
                and plot:GetOwner() == Game.GetLocalPlayer() then
                local districtIndex = plot:GetDistrictType();
                local improvementIndex = plot:GetImprovementType();
                local subject = nil;
                if districtIndex and districtIndex >= 0 then
                    local row = GameInfo.Districts[districtIndex];
                    if row then
                        local owningCity = AMT_GetPlotPurchaseCity(plot);
                        subject = {
                            X = plot:GetX(),
                            Y = plot:GetY(),
                            Key = row.DistrictType,
                            Type = MAP_PIN_TYPE_DISTRICT,
                            CityID = owningCity and owningCity:GetID()
                                or city:GetID(),
                            isExisting = true,
                        };
                    end
                elseif improvementIndex and improvementIndex >= 0 then
                    local row = GameInfo.Improvements[improvementIndex];
                    if row then
                        local owningCity = AMT_GetPlotPurchaseCity(plot);
                        subject = {
                            X = plot:GetX(),
                            Y = plot:GetY(),
                            Key = row.ImprovementType,
                            Type = MAP_PIN_TYPE_IMPROVEMENT,
                            CityID = owningCity and owningCity:GetID()
                                or city:GetID(),
                            isExisting = true,
                        };
                    end
                end
                if subject then
                    fixedSubjectKeys[key] = true;
                    table.insert(fixedSubjects, subject);
                end
            end
        end
    end
    return byCity, playerCounts, fixedSubjects;
end

local function CityHasMutuallyExclusiveDistrict(city, existingCounts, districtType)
    local exclusions = GetMutuallyExclusiveDistricts();
    for otherDistrict in pairs(exclusions[districtType] or {}) do
        if IsDistrictAlreadyInCity(city, otherDistrict)
            or (existingCounts and (existingCounts[otherDistrict] or 0) > 0) then
            return true, otherDistrict;
        end
    end
    return false, nil;
end

local function IsWonderBuilt(wonderType)
    if wonderType == "DISTRICT_WONDER" then return false; end
    local wonderRow = GameInfo.Buildings[wonderType];
    if not wonderRow then return false; end
    for playerID = 0, 63 do
        local player = Players[playerID];
        local cityManager = player and player:GetCities() or nil;
        if cityManager then
            for _, city in cityManager:Members() do
                local buildings = city:GetBuildings();
                if buildings and buildings:HasBuilding(wonderRow.Index) then
                    return true;
                end
            end
        end
    end
    return false;
end

local function SafeDistrictCapacityCall(cityDistricts, methodName)
    if not cityDistricts then return nil; end
    local ok, value = pcall(function()
        if methodName == "GetNumAllowedDistrictsRequiringPopulation" then
            return cityDistricts:GetNumAllowedDistrictsRequiringPopulation();
        elseif methodName == "GetNumZonedDistrictsRequiringPopulation" then
            return cityDistricts:GetNumZonedDistrictsRequiringPopulation();
        end
        return nil;
    end);
    if ok then return tonumber(value); end
    return nil;
end

local function BuildCitySpecialtyBudgets(cities, existingByCity, selection)
    local budgets = {};
    for cityIndex, city in ipairs(cities) do
        local cityDistricts = city:GetDistricts();
        local population = math.max(1, tonumber(city:GetPopulation()) or 1);
        local fallbackAllowed = math.floor((population - 1) / 3) + 1;
        local currentAllowed = SafeDistrictCapacityCall(
            cityDistricts, "GetNumAllowedDistrictsRequiringPopulation"
        ) or fallbackAllowed;
        local zoned = SafeDistrictCapacityCall(
            cityDistricts, "GetNumZonedDistrictsRequiringPopulation"
        ) or 0;
        -- Some rulesets report only completed districts here.  Foundations
        -- are already irrevocable and must consume the same population slot.
        zoned = math.max(
            zoned, #GetLockedSpecialtyDistricts(city, false)
        );
        local pinned = 0;
        for districtType, count in pairs(
            existingByCity[city:GetID()] or {}
        ) do
            if IsPopulationDistrict(districtType)
                and not IsDistrictAlreadyInCity(city, districtType) then
                pinned = pinned + (tonumber(count) or 0);
            end
        end
        local occupied = zoned + pinned;
        local configuredSlots = selection.specialtySlotCountByCity
            and selection.specialtySlotCountByCity[city:GetID()]
            or DEFAULT_SPECIALTY_SLOT_COUNT;
        configuredSlots = math.max(
            MIN_SPECIALTY_SLOT_COUNT,
            math.min(MAX_SPECIALTY_SLOT_COUNT,
                tonumber(configuredSlots) or DEFAULT_SPECIALTY_SLOT_COUNT)
        );
        local planningPopulation = selection.populationBudgetByCity
            and selection.populationBudgetByCity[city:GetID()]
            or GetRequiredPopulationForSpecialtySlot(configuredSlots);
        planningPopulation = math.max(
            population,
            math.min(
                POPULATION_BUDGET_RANGE.maximum,
                tonumber(planningPopulation)
                    or GetRequiredPopulationForSpecialtySlot(configuredSlots)
            )
        );
        local plannedAllowed =
            math.floor((planningPopulation - 1) / 3) + 1;
        local allowedSlots = selection.planningHorizon == "CURRENT"
            and currentAllowed or plannedAllowed;
        local totalSlots = math.max(
            occupied,
            math.min(allowedSlots, configuredSlots)
        );
        budgets[city:GetID()] = {
            cityID = city:GetID(),
            cityName = Locale.Lookup(city:GetName()),
            currentPopulation = population,
            currentAllowed = currentAllowed,
            configuredSlots = configuredSlots,
            existingSlots = occupied,
            available = math.max(0, totalSlots - occupied),
            totalSlots = totalSlots,
            targetPopulation = planningPopulation,
            plannedAllowed = plannedAllowed,
            isPrimary = cityIndex == 1,
        };
        Log(string.format(
            "Specialty budget %s pop=%d currentAllowed=%d planPop=%d plannedAllowed=%d configured=%d occupied=%d usable=%d available=%d horizon=%s",
            budgets[city:GetID()].cityName, population, currentAllowed,
            planningPopulation, plannedAllowed, configuredSlots, occupied,
            totalSlots, budgets[city:GetID()].available,
            tostring(selection.planningHorizon)
        ));
    end
    return budgets;
end

local function BuildPlanRequests(cities, selection, ignoredKeys)
    local player = Players[Game.GetLocalPlayer()];
    local planningCityName = cities and cities[1]
        and Locale.Lookup(cities[1]:GetName())
        or Locale.Lookup("LOC_AMT_LINKED_CITIES");
    local selectedDistricts = selection.districts or {};
    local districtPriorities = selection.districtPriorities or {};
    local requests = {};
    local preSkippedRequests = {};
    local existingByCity = {};
    local existingPlayerCounts = {};
    local fixedSubjects = {};
    existingByCity, existingPlayerCounts, fixedSubjects =
        GetExistingPlannedDistricts(cities, ignoredKeys);
    local citySpecialtyBudgets = BuildCitySpecialtyBudgets(
        cities, existingByCity, selection
    );
    local function CityWantsSpecialty(cityID, districtType)
        if not IsPopulationDistrict(districtType) then return true; end
        local slots = selection.specialtySlotsByCity
            and selection.specialtySlotsByCity[cityID] or {};
        for _, assignedType in pairs(slots or {}) do
            if assignedType == districtType then return true; end
        end
        return false;
    end
    local function GetCitySpecialtyOrder(cityID, districtType)
        local slots = selection.specialtySlotsByCity
            and selection.specialtySlotsByCity[cityID] or {};
        for index, assignedType in pairs(slots or {}) do
            if assignedType == districtType then return tonumber(index) or 99; end
        end
        return 99;
    end
    local function BuildCityOrderMap(eligibleCities, districtType)
        local result = {};
        for _, city in ipairs(eligibleCities or {}) do
            result[city:GetID()] = {
                [districtType] =
                    GetCitySpecialtyOrder(city:GetID(), districtType),
            };
        end
        return result;
    end

    for _, districtType in ipairs(selectedDistricts) do
        local maxPerPlayer = GetDistrictMaxPerPlayer(districtType);
        if maxPerPlayer then
            local builtCount = CountPlayerDistricts(player, districtType);
            local plannedCount = existingPlayerCounts[districtType] or 0;
            local remaining = math.max(0, maxPerPlayer - builtCount - plannedCount);
            local eligibleCities = {};
            for _, city in ipairs(cities) do
                local cityCounts = existingByCity[city:GetID()] or {};
                local existingCount = cityCounts[districtType] or 0;
                local hasMutualConflict = CityHasMutuallyExclusiveDistrict(
                    city, cityCounts, districtType
                );
                if CityWantsSpecialty(city:GetID(), districtType)
                    and not hasMutualConflict
                    and (not IsDistrictOnePerCity(districtType)
                        or (not IsDistrictAlreadyInCity(city, districtType)
                            and existingCount == 0))
                    and (not IsPopulationDistrict(districtType)
                        or (citySpecialtyBudgets[city:GetID()]
                            and citySpecialtyBudgets[city:GetID()].available > 0)) then
                    table.insert(eligibleCities, city);
                end
            end
            if IsDistrictOnePerCity(districtType) then
                remaining = math.min(remaining, #eligibleCities);
            end
            Log(string.format(
                "Player limit %s max=%d built=%d planned=%d remaining=%d",
                districtType, maxPerPlayer, builtCount, plannedCount, remaining
            ));
            if remaining == 0 then
                table.insert(preSkippedRequests, {
                    district = districtType,
                    subjectType = MAP_PIN_TYPE_DISTRICT,
                    subjectKey = districtType,
                    subjectOptions = { districtType },
                    cityName = planningCityName,
                    skipReason = "ALREADY_EXISTS",
                });
            elseif #eligibleCities == 0 then
                local targetPopulation = 1;
                for _, budget in pairs(citySpecialtyBudgets) do
                    targetPopulation = math.max(
                        targetPopulation, budget.targetPopulation or 1
                    );
                end
                table.insert(preSkippedRequests, {
                    district = districtType,
                    subjectType = MAP_PIN_TYPE_DISTRICT,
                    subjectKey = districtType,
                    subjectOptions = { districtType },
                    cityName = planningCityName,
                    skipReason = "POPULATION_LIMIT",
                    targetPopulation = targetPopulation,
                });
                remaining = 0;
            end
            for _ = 1, remaining do
                table.insert(requests, {
                    district = districtType,
                    subjectType = MAP_PIN_TYPE_DISTRICT,
                    subjectKey = districtType,
                    subjectOptions = { districtType },
                    subjectPriorities = {
                        [districtType] = districtPriorities[districtType] or 1,
                    },
                    subjectOrders = {
                        [districtType] = #eligibleCities == 1
                            and GetCitySpecialtyOrder(
                                eligibleCities[1]:GetID(), districtType
                            ) or 99,
                    },
                    subjectOrdersByCity =
                        BuildCityOrderMap(eligibleCities, districtType),
                    cities = eligibleCities,
                    cityName = planningCityName,
                    isGlobal = true,
                    isOptional = true,
                    isSpecialty = IsPopulationDistrict(districtType),
                });
            end
        end
    end

    local perCityDistricts = {};
    for _, districtType in ipairs(selectedDistricts) do
        if not IsCoverageDistrict(districtType) then
            table.insert(perCityDistricts, districtType);
        elseif GetDistrictMaxPerPlayer(districtType) == nil then
            local coveredCities = {};
            for _, subject in ipairs(fixedSubjects) do
                if subject.Type == MAP_PIN_TYPE_DISTRICT
                    and GetDistrictStrategyType(subject.Key)
                        == GetDistrictStrategyType(districtType) then
                    for _, city in ipairs(cities) do
                        if Map.GetPlotDistance(
                            subject.X, subject.Y,
                            city:GetX(), city:GetY()
                        ) <= 6 then
                            coveredCities[city:GetID()] = true;
                        end
                    end
                end
            end
            local allCovered = #cities > 0;
            for _, city in ipairs(cities) do
                if not coveredCities[city:GetID()] then
                    allCovered = false;
                    break;
                end
            end
            if allCovered then
                table.insert(preSkippedRequests, {
                    district = districtType,
                    subjectType = MAP_PIN_TYPE_DISTRICT,
                    subjectKey = districtType,
                    subjectOptions = { districtType },
                    cityName = planningCityName,
                    skipReason = "COVERAGE_SATISFIED",
                });
            else
                local eligibleCities = {};
                for _, city in ipairs(cities) do
                    local budget = citySpecialtyBudgets[city:GetID()];
                    if CityWantsSpecialty(city:GetID(), districtType)
                        and (not IsPopulationDistrict(districtType)
                            or (budget and budget.available > 0)) then
                        table.insert(eligibleCities, city);
                    end
                end
                if #eligibleCities > 0 then
                    table.insert(requests, {
                        district = districtType,
                        subjectType = MAP_PIN_TYPE_DISTRICT,
                        subjectKey = districtType,
                        subjectOptions = { districtType },
                        subjectPriorities = {
                            [districtType] =
                                districtPriorities[districtType] or 1,
                        },
                        subjectOrders = {
                            [districtType] = #eligibleCities == 1
                                and GetCitySpecialtyOrder(
                                    eligibleCities[1]:GetID(), districtType
                                ) or 99,
                        },
                        subjectOrdersByCity =
                            BuildCityOrderMap(eligibleCities, districtType),
                        cities = eligibleCities,
                        cityName = planningCityName,
                        isGlobal = true,
                        isOptional = true,
                        isSpecialty =
                            IsPopulationDistrict(districtType),
                        isCoverageDistrict = true,
                    });
                else
                    local targetPopulation = 1;
                    for _, budget in pairs(citySpecialtyBudgets) do
                        targetPopulation = math.max(
                            targetPopulation,
                            budget.targetPopulation or 1
                        );
                    end
                    table.insert(preSkippedRequests, {
                        district = districtType,
                        subjectType = MAP_PIN_TYPE_DISTRICT,
                        subjectKey = districtType,
                        subjectOptions = { districtType },
                        cityName = planningCityName,
                        skipReason = "POPULATION_LIMIT",
                        targetPopulation = targetPopulation,
                    });
                end
            end
        end
    end

    local optionGroups = BuildDistrictOptionGroups(perCityDistricts);
    local exclusions = GetMutuallyExclusiveDistricts();
    for _, city in ipairs(cities) do
        local cityID = city:GetID();
        local cityName = Locale.Lookup(city:GetName());
        local existingCounts = existingByCity[cityID] or {};
        local specialtyBudget = citySpecialtyBudgets[cityID];
        for _, districtOptions in ipairs(optionGroups) do
            local cityDistrictOptions = {};
            for _, districtType in ipairs(districtOptions) do
                if CityWantsSpecialty(cityID, districtType) then
                    table.insert(cityDistrictOptions, districtType);
                end
            end
            districtOptions = cityDistrictOptions;
            if #districtOptions > 0 then
            local optionSet = {};
            local optionPriorities = {};
            local optionOrders = {};
            local satisfied = false;
            for _, districtType in ipairs(districtOptions) do
                optionSet[districtType] = true;
                optionPriorities[districtType] =
                    districtPriorities[districtType] or 1;
                optionOrders[districtType] =
                    GetCitySpecialtyOrder(cityID, districtType);
                if IsDistrictAlreadyInCity(city, districtType)
                    or (existingCounts[districtType] or 0) > 0 then
                    satisfied = true;
                end
            end

            if satisfied then
                Log(string.format(
                    "Existing district or tack satisfies option group %s for %s",
                    table.concat(districtOptions, "/"), cityName
                ));
                for _, districtType in ipairs(districtOptions) do
                    if IsDistrictAlreadyInCity(city, districtType)
                        or (existingCounts[districtType] or 0) > 0 then
                        table.insert(preSkippedRequests, {
                            district = districtType,
                            subjectType = MAP_PIN_TYPE_DISTRICT,
                            subjectKey = districtType,
                            subjectOptions = { districtType },
                            cityID = cityID,
                            cityName = cityName,
                            skipReason = "ALREADY_EXISTS",
                        });
                    else
                        local hasConflict, conflictingDistrict =
                            CityHasMutuallyExclusiveDistrict(
                                city, existingCounts, districtType
                            );
                        if hasConflict then
                            table.insert(preSkippedRequests, {
                                district = districtType,
                                subjectType = MAP_PIN_TYPE_DISTRICT,
                                subjectKey = districtType,
                                subjectOptions = { districtType },
                                cityID = cityID,
                                cityName = cityName,
                                skipReason = "MUTUALLY_EXCLUSIVE",
                                conflictingDistrict = conflictingDistrict,
                            });
                        end
                    end
                end
            else
                local conflictingDistrict = nil;
                for _, districtType in ipairs(districtOptions) do
                    for otherDistrict in pairs(exclusions[districtType] or {}) do
                        if not optionSet[otherDistrict]
                            and (IsDistrictAlreadyInCity(city, otherDistrict)
                                or (existingCounts[otherDistrict] or 0) > 0) then
                            conflictingDistrict = otherDistrict;
                            break;
                        end
                    end
                    if conflictingDistrict then break; end
                end

                local request = {
                    district = districtOptions[1],
                    districtOptions = #districtOptions > 1 and districtOptions or nil,
                    subjectType = MAP_PIN_TYPE_DISTRICT,
                    subjectKey = districtOptions[1],
                    subjectOptions = districtOptions,
                    subjectPriorities = optionPriorities,
                    subjectOrders = optionOrders,
                    cities = { city },
                    cityID = cityID,
                    cityName = cityName,
                    isGlobal = false,
                    isOptional = true,
                    isSpecialty = false,
                    specialtyBudget = specialtyBudget,
                };
                for _, districtType in ipairs(districtOptions) do
                    if IsPopulationDistrict(districtType) then
                        request.isSpecialty = true;
                        break;
                    end
                end
                local economicAlternative = nil;
                for _, districtType in ipairs(districtOptions) do
                    if IsEconomicTradeDistrict(districtType) then
                        for existingType, count in pairs(existingCounts) do
                            if (tonumber(count) or 0) > 0
                                and AreEconomicTradeAlternatives(
                                    existingType, districtType
                                ) then
                                economicAlternative = existingType;
                                break;
                            end
                        end
                        if not economicAlternative then
                            for _, option in ipairs(
                                m_PlannerOptions[MAP_PIN_TYPE_DISTRICT] or {}
                            ) do
                                if AreEconomicTradeAlternatives(
                                    option.subjectKey, districtType
                                ) and IsDistrictAlreadyInCity(
                                    city, option.subjectKey
                                ) then
                                    economicAlternative = option.subjectKey;
                                    break;
                                end
                            end
                        end
                    end
                    if economicAlternative then break; end
                end
                if conflictingDistrict then
                    request.skipReason = "MUTUALLY_EXCLUSIVE";
                    request.conflictingDistrict = conflictingDistrict;
                    table.insert(preSkippedRequests, request);
                    Log(string.format(
                        "Mutual exclusion skips %s for %s because of %s",
                        table.concat(districtOptions, "/"),
                        cityName, conflictingDistrict
                    ));
                elseif economicAlternative then
                    request.skipReason = "TRADE_ROUTE_REDUNDANCY";
                    request.conflictingDistrict = economicAlternative;
                    table.insert(preSkippedRequests, request);
                elseif request.isSpecialty
                    and specialtyBudget
                    and specialtyBudget.available <= 0 then
                    request.skipReason = "POPULATION_LIMIT";
                    request.targetPopulation =
                        specialtyBudget.targetPopulation;
                    table.insert(preSkippedRequests, request);
                else
                    table.insert(requests, request);
                end
            end
            end
        end
    end

    local function GetImprovementPopulationBudget()
        local totalTargetPopulation = 0;
        local existingImprovements = 0;
        local cityIDs = {};
        for _, city in ipairs(cities) do
            cityIDs[city:GetID()] = true;
            local budget = citySpecialtyBudgets[city:GetID()] or {};
            local population = math.max(
                tonumber(budget.currentPopulation) or 1,
                tonumber(budget.targetPopulation) or 1
            );
            totalTargetPopulation = totalTargetPopulation
                + AMT_GetTargetImprovementPlotCount(population);
        end
        for _, subject in ipairs(fixedSubjects or {}) do
            if subject.Type == MAP_PIN_TYPE_IMPROVEMENT
                and cityIDs[subject.CityID] then
                existingImprovements = existingImprovements + 1;
            end
        end
        return math.max(
            0, totalTargetPopulation - existingImprovements
        ), totalTargetPopulation, existingImprovements;
    end

    local function AddPoolRequests(subjectType, selectedKeys)
        if not selectedKeys or #selectedKeys == 0 then
            return;
        end
        local available = {};
        local pinned = {};
        local cfg = PlayerConfigurations[Game.GetLocalPlayer()];
        local pins = cfg and cfg:GetMapPins() or {};
        for _, pin in pairs(pins) do
            local key = pin and Key(pin:GetHexX(), pin:GetHexY()) or nil;
            local subject = pin and CreateMapPinSubject(pin) or nil;
            if subject and subject.Type == subjectType
                and not (ignoredKeys and ignoredKeys[key]) then
                pinned[subject.Key] = true;
            end
        end
        for _, subjectKey in ipairs(selectedKeys) do
            local unavailableWonder = subjectType == MAP_PIN_TYPE_WONDER
                and subjectKey ~= "DISTRICT_WONDER"
                and (pinned[subjectKey] or IsWonderBuilt(subjectKey));
            if not unavailableWonder then table.insert(available, subjectKey); end
        end
        if #available == 0 then
            table.insert(preSkippedRequests, {
                subjectType = subjectType,
                subjectKey = selectedKeys[1],
                subjectOptions = selectedKeys,
                cityName = planningCityName,
                skipReason = "ALREADY_EXISTS",
            });
            return;
        end
        if subjectType == MAP_PIN_TYPE_IMPROVEMENT then
            local improvementBudget, targetImprovedPlots,
                existingImprovements =
                GetImprovementPopulationBudget();
            table.insert(requests, {
                subjectType = subjectType,
                subjectKey = available[1],
                subjectOptions = available,
                cities = cities,
                cityName = planningCityName,
                isPool = true,
                isAutoQuantity = true,
                isOptional = true,
                improvementBudget = improvementBudget,
                targetImprovedPlots = targetImprovedPlots,
                existingImprovementCount = existingImprovements,
            });
            Log(string.format(
                "Improvement population budget target=%d existing=%d new=%d",
                targetImprovedPlots, existingImprovements,
                improvementBudget
            ));
            return;
        end

        -- Every selected wonder is a separate required request.  Specific
        -- wonders and the generic placeholder can each appear at most once,
        -- and are only skipped when no compatible legal location exists.
        for _, subjectKey in ipairs(available) do
            table.insert(requests, {
                subjectType = subjectType,
                subjectKey = subjectKey,
                subjectOptions = { subjectKey },
                cities = cities,
                cityName = planningCityName,
                isPool = true,
                isOptional = false,
                selectedDistricts = subjectType == MAP_PIN_TYPE_WONDER
                    and selection.districts or nil,
            });
        end
    end

    AddPoolRequests(
        MAP_PIN_TYPE_IMPROVEMENT,
        selection.improvements
    );
    AddPoolRequests(
        MAP_PIN_TYPE_WONDER,
        selection.wonders
    );
    for requestIndex, request in ipairs(requests) do
        request.requestID = "REQUEST_" .. tostring(requestIndex);
    end
    return requests, fixedSubjects, preSkippedRequests,
        citySpecialtyBudgets;
end

local function BuildPlanningRunCache(playerID)
    local cache = {
        playerID = playerID,
        cityOwnedPlotKeys = {},
        cityRangePlots = {},
        pinsByKey = {},
        placementRules = {},
        quickPinChecks = {},
        yieldEvaluations = {},
        yieldEvaluationCount = 0,
        yieldEvaluationLimit = 4096,
        staticFixedYieldEvaluations = {},
        influenceScopes = {},
        influenceIndexesBuilt = false,
    };
    local cfg = PlayerConfigurations[playerID];
    local pins = cfg and cfg:GetMapPins() or {};
    for _, pin in pairs(pins or {}) do
        if pin then
            local key = Key(pin:GetHexX(), pin:GetHexY());
            if not cache.pinsByKey[key] then
                cache.pinsByKey[key] = pin;
            end
        end
    end
    return cache;
end

local function GetCityOwnedPlotKeys(city, runCache)
    local cityID = city and city:GetID();
    if runCache and cityID ~= nil
        and runCache.cityOwnedPlotKeys[cityID] then
        return runCache.cityOwnedPlotKeys[cityID];
    end
    local keys = {};
    for _, plot in ipairs(GetCityPurchasedPlots(city)) do
        if plot then keys[Key(plot:GetX(), plot:GetY())] = true; end
    end
    if runCache and cityID ~= nil then
        runCache.cityOwnedPlotKeys[cityID] = keys;
    end
    return keys;
end

local function GetCityRangePlots(city, runCache)
    local cityID = city and city:GetID();
    if runCache and cityID ~= nil and runCache.cityRangePlots[cityID] then
        return runCache.cityRangePlots[cityID];
    end
    local plots = GetPlotsWithinXTiles(city:GetX(), city:GetY(), 3);
    if runCache and cityID ~= nil then
        runCache.cityRangePlots[cityID] = plots;
    end
    return plots;
end

local function BuildRangeKeys(cities, runCache)
    local keys = {};
    for _, city in ipairs(cities) do
        for _, plot in ipairs(GetCityRangePlots(city, runCache)) do
            keys[Key(plot:GetX(), plot:GetY())] = true;
        end
    end
    return keys;
end

local function BuildCityCenterKeys(cities)
    local keys = {};
    for _, city in ipairs(cities) do
        keys[Key(city:GetX(), city:GetY())] = true;
    end
    return keys;
end

local function MakePinSubject(item)
    return {
        X = item.x,
        Y = item.y,
        Key = item.subjectKey or item.district,
        Type = item.subjectType or MAP_PIN_TYPE_DISTRICT,
        CityID = item.cityID,
    };
end

local ImprovementPlacement = {
    cache = {},
    resourceYieldCache = {},
};

function ImprovementPlacement.GetActualVisibleResource(plot, playerID)
    if not plot then return nil; end
    local resourceIndex = plot:GetResourceType();
    local resource = resourceIndex and resourceIndex >= 0
        and GameInfo.Resources[resourceIndex] or nil;
    if not resource then return nil; end

    local visible = false;
    if IsResourceVisible then
        local ok, result = pcall(
            IsResourceVisible, playerID, resource.ResourceType
        );
        if ok then visible = result == true; end
    else
        local player = Players[playerID];
        local resources = player and player:GetResources() or nil;
        if resources and resource.Hash then
            local ok, result = pcall(
                resources.IsResourceVisible, resources, resource.Hash
            );
            if ok then visible = result == true; end
        end
    end
    return visible and resource or nil;
end

function ImprovementPlacement.GetVisibleResource(plot, playerID)
    if not plot then return nil; end
    local directive = AMT_PlotDirectives[
        Key(plot:GetX(), plot:GetY())
    ];
    if directive and directive.removeResource then return nil; end
    return ImprovementPlacement.GetActualVisibleResource(plot, playerID);
end

function ImprovementPlacement.GetHiddenResourceYield(
    plot, playerID, yieldType
)
    if not plot
        or ImprovementPlacement.GetVisibleResource(plot, playerID) then
        return 0;
    end
    local resourceIndex = plot:GetResourceType();
    local resource = resourceIndex and resourceIndex >= 0
        and GameInfo.Resources[resourceIndex] or nil;
    if not resource then return 0; end
    local resourceType = resource.ResourceType;
    local cached =
        ImprovementPlacement.resourceYieldCache[resourceType];
    if not cached then
        cached = {};
        if GameInfo.Resource_YieldChanges then
            for row in GameInfo.Resource_YieldChanges() do
                if row.ResourceType == resourceType then
                    cached[row.YieldType] =
                        (cached[row.YieldType] or 0)
                        + (tonumber(row.YieldChange) or 0);
                end
            end
        end
        ImprovementPlacement.resourceYieldCache[resourceType] = cached;
    end
    return cached[yieldType] or 0;
end

function ImprovementPlacement.GetRules(improvementType)
    local cached = ImprovementPlacement.cache[improvementType];
    if cached then return cached; end
    local rules = {
        resources = {},
        terrains = {},
        features = {},
        adjacentTerrains = {},
        hasResources = false,
        hasTerrains = false,
        hasFeatures = false,
        hasAdjacentTerrains = false,
    };
    for row in GameInfo.Improvement_ValidResources() do
        if row.ImprovementType == improvementType then
            rules.hasResources = true;
            rules.resources[row.ResourceType] = row;
        end
    end
    for row in GameInfo.Improvement_ValidTerrains() do
        if row.ImprovementType == improvementType then
            rules.hasTerrains = true;
            rules.terrains[row.TerrainType] =
                rules.terrains[row.TerrainType] or {};
            table.insert(rules.terrains[row.TerrainType], row);
        end
    end
    for row in GameInfo.Improvement_ValidFeatures() do
        if row.ImprovementType == improvementType then
            rules.hasFeatures = true;
            rules.features[row.FeatureType] =
                rules.features[row.FeatureType] or {};
            table.insert(rules.features[row.FeatureType], row);
        end
    end
    if GameInfo.Improvement_ValidAdjacentTerrains then
        for row in GameInfo.Improvement_ValidAdjacentTerrains() do
            if row.ImprovementType == improvementType then
                rules.hasAdjacentTerrains = true;
                rules.adjacentTerrains[row.TerrainType] = true;
            end
        end
    end
    ImprovementPlacement.cache[improvementType] = rules;
    return rules;
end

function ImprovementPlacement.IsRuleUnlocked(rule, playerID)
    if m_PlanningHorizon ~= "CURRENT" then return true; end
    local player = Players[playerID];
    if not player then return false; end
    if rule.PrereqTech then
        local tech = GameInfo.Technologies[rule.PrereqTech];
        if tech and not player:GetTechs():HasTech(tech.Index) then return false; end
    end
    if rule.PrereqCivic then
        local civic = GameInfo.Civics[rule.PrereqCivic];
        if civic and not player:GetCulture():HasCivic(civic.Index) then
            return false;
        end
    end
    return true;
end

function ImprovementPlacement.AnyRuleUnlocked(ruleList, playerID)
    for _, rule in ipairs(ruleList or {}) do
        if ImprovementPlacement.IsRuleUnlocked(rule, playerID) then
            return true;
        end
    end
    return false;
end

function ImprovementPlacement.CanPlan(item, playerID)
    if item.subjectType == MAP_PIN_TYPE_DISTRICT then
        local resource = ImprovementPlacement.GetActualVisibleResource(
            item.plot, playerID
        );
        local resourceClass = resource and resource.ResourceClassType or nil;
        -- Detailed Map Tacks does not consistently reject districts projected
        -- over revealed protected resources.  Bonus resources may be removed by
        -- district construction, but luxury and strategic resources may not.
        -- Read the real plot resource here so an invalid manual harvest tack
        -- cannot make a protected resource appear removable in the simulation.
        return resourceClass ~= "RESOURCECLASS_LUXURY"
            and resourceClass ~= "RESOURCECLASS_STRATEGIC";
    end
    if item.subjectType ~= MAP_PIN_TYPE_IMPROVEMENT then return true; end
    local plot = item.plot;
    local row = GameInfo.Improvements[item.subjectKey];
    local directive = plot and AMT_PlotDirectives[
        Key(plot:GetX(), plot:GetY())
    ] or nil;
    if not plot or not row then return false; end
    if plot:GetDistrictType() ~= -1 or plot:GetWonderType() ~= -1
        or plot:GetImprovementType() ~= -1 then
        return false;
    end
    local isWater = plot:IsWater();
    if row.Domain == "DOMAIN_SEA" and not isWater then return false; end
    if row.Domain ~= "DOMAIN_SEA" and isWater then return false; end

    local engineResult = nil;
    if ImprovementBuilder and ImprovementBuilder.CanHaveImprovement then
        local ok, result = pcall(
            ImprovementBuilder.CanHaveImprovement,
            plot, row.Index, -1
        );
        if ok then engineResult = result; end
        -- The engine helper only sees the current plot.  A manual operation
        -- tack can intentionally describe a future cleared/planted state.
        if engineResult == false and not directive then return false; end
    end

    -- Detailed Map Tacks intentionally leaves improvement-specific placement
    -- checks as TODO.  Even when the engine helper accepts a hypothetical
    -- placement, enforce the live database's resource/terrain/feature rules.
    local rules = ImprovementPlacement.GetRules(item.subjectKey);
    local resource =
        ImprovementPlacement.GetVisibleResource(plot, playerID);
    local terrain = GameInfo.Terrains[plot:GetTerrainType()];
    local featureIndex = plot:GetFeatureType();
    local feature = featureIndex and featureIndex >= 0
        and GameInfo.Features[featureIndex] or nil;
    if directive then
        if directive.removeFeature then feature = nil; end
        if directive.plantForest then
            feature = GameInfo.Features["FEATURE_FOREST"];
        end
    end

    if IsTrue(row.RequiresRiver) then
        local ok, isRiver = pcall(function() return plot:IsRiver(); end);
        if not ok or not isRiver then return false; end
    end
    if row.MinimumAppeal ~= nil then
        local ok, appeal = pcall(function() return plot:GetAppeal(); end);
        if not ok
            or (tonumber(appeal) or -999)
                < (tonumber(row.MinimumAppeal) or -999) then
            return false;
        end
    end
    if IsTrue(row.Coast) then
        local ok, isCoastalLand = pcall(
            function() return plot:IsCoastalLand(); end
        );
        if not ok or not isCoastalLand then return false; end
    end

    local requiresAdjacentCheck =
        IsTrue(row.AdjacentSeaResource)
        or IsTrue(row.RequiresAdjacentBonusOrLuxury)
        or IsTrue(row.RequiresAdjacentLuxury)
        or IsTrue(row.AdjacentToLand)
        or (tonumber(row.ValidAdjacentTerrainAmount) or 0) > 0;
    if requiresAdjacentCheck then
        local hasAdjacentLand = false;
        local hasAdjacentSeaResource = false;
        local hasAdjacentBonusOrLuxury = false;
        local hasAdjacentLuxury = false;
        local validAdjacentTerrainCount = 0;
        for _, adjacentPlot in ipairs(GetPlotsWithinXTiles(
            plot:GetX(), plot:GetY(), 1
        )) do
            if adjacentPlot:GetX() ~= plot:GetX()
                or adjacentPlot:GetY() ~= plot:GetY() then
                if not adjacentPlot:IsWater() then
                    hasAdjacentLand = true;
                end
                local adjacentResource =
                    ImprovementPlacement.GetVisibleResource(
                        adjacentPlot, playerID
                    );
                if adjacentResource then
                    local resourceClass =
                        adjacentResource.ResourceClassType;
                    if resourceClass == "RESOURCECLASS_LUXURY" then
                        hasAdjacentLuxury = true;
                        hasAdjacentBonusOrLuxury = true;
                    elseif resourceClass == "RESOURCECLASS_BONUS" then
                        hasAdjacentBonusOrLuxury = true;
                    end
                    if adjacentPlot:IsWater() then
                        hasAdjacentSeaResource = true;
                    end
                end
                local adjacentTerrain =
                    GameInfo.Terrains[adjacentPlot:GetTerrainType()];
                if adjacentTerrain
                    and rules.adjacentTerrains[
                        adjacentTerrain.TerrainType
                    ] then
                    validAdjacentTerrainCount =
                        validAdjacentTerrainCount + 1;
                end
            end
        end
        if IsTrue(row.AdjacentToLand)
            and not hasAdjacentLand then return false; end
        if IsTrue(row.AdjacentSeaResource)
            and not hasAdjacentSeaResource then return false; end
        if IsTrue(row.RequiresAdjacentBonusOrLuxury)
            and not hasAdjacentBonusOrLuxury then return false; end
        if IsTrue(row.RequiresAdjacentLuxury)
            and not hasAdjacentLuxury then return false; end
        if (tonumber(row.ValidAdjacentTerrainAmount) or 0)
            > validAdjacentTerrainCount then return false; end
    end

    local matchesResource = resource
        and rules.resources[resource.ResourceType] ~= nil;
    local matchesTerrain = terrain
        and ImprovementPlacement.AnyRuleUnlocked(
            rules.terrains[terrain.TerrainType], playerID
        ) or false;
    local matchesFeature = feature
        and ImprovementPlacement.AnyRuleUnlocked(
            rules.features[feature.FeatureType], playerID
        ) or false;

    -- Oil wells and offshore oil rigs set EnforceTerrain because their valid
    -- resource and terrain lists are conjunctive: the plot needs visible oil
    -- and must also be in the appropriate land/sea terrain set.  Ordinary
    -- farms and mines intentionally keep the usual resource-or-terrain rules.
    if IsTrue(row.EnforceTerrain) then
        if rules.hasResources and not matchesResource then return false; end
        if rules.hasTerrains and not matchesTerrain then return false; end
        if rules.hasResources or rules.hasTerrains then return true; end
    end

    -- A revealed resource changes what may legally be built on the tile.
    -- Terrain/feature rules are fallback placement rules for empty plots; they
    -- must never allow a farm (or another unrelated improvement) to replace a
    -- revealed iron, luxury, bonus, or other resource.  Explicit Harvest
    -- Resource tacks are handled by GetVisibleResource and intentionally make
    -- the simulated plot resource-free.
    if resource then return matchesResource; end
    if matchesTerrain or matchesFeature then return true; end

    -- Improvements with only a ValidResources list (plantations, pastures,
    -- camps, quarries, fishing boats, etc.) are impossible without
    -- one of those resources.  Likewise a terrain/feature constrained unique
    -- improvement must match at least one currently permitted rule.
    if rules.hasResources or rules.hasTerrains or rules.hasFeatures then
        return false;
    end
    return engineResult ~= false;
end

function ImprovementPlacement.GetStrategicScore(item, playerID)
    if not item or item.subjectType ~= MAP_PIN_TYPE_IMPROVEMENT then
        return 0;
    end
    local resource =
        ImprovementPlacement.GetVisibleResource(item.plot, playerID);
    if not resource then return 0; end
    if resource.ResourceClassType == "RESOURCECLASS_STRATEGIC" then
        -- Strategic resources are empire capabilities, not merely local tile
        -- yields.  Keep a large score as a secondary tie-breaker; the search
        -- also compares the number of developed strategic resources first.
        return 12;
    elseif resource.ResourceClassType == "RESOURCECLASS_LUXURY" then
        return 4;
    elseif resource.ResourceClassType == "RESOURCECLASS_BONUS" then
        return 1.5;
    end
    return 1;
end

function ImprovementPlacement.GetStaleAutoResourcePinKeys(
    playerID, rangeKeys, autoRegistry
)
    local staleKeys = {};
    local cfg = PlayerConfigurations[playerID];
    local pins = cfg and cfg:GetMapPins() or {};
    for _, pin in pairs(pins) do
        local x = pin and pin:GetHexX() or nil;
        local y = pin and pin:GetHexY() or nil;
        local key = x and y and Key(x, y) or nil;
        if key and rangeKeys[key] and IsAutoMapPin(pin, autoRegistry) then
            local subject = CreateMapPinSubject(pin);
            if subject and subject.Type == MAP_PIN_TYPE_IMPROVEMENT then
                local plot = Map.GetPlot(x, y);
                local resource =
                    ImprovementPlacement.GetVisibleResource(plot, playerID);
                if resource then
                    local rules =
                        ImprovementPlacement.GetRules(subject.Key);
                    if not rules.resources[resource.ResourceType] then
                        staleKeys[key] = true;
                        Log(string.format(
                            "Refreshing stale auto improvement %s at %s after revealing %s",
                            tostring(subject.Key), key,
                            tostring(resource.ResourceType)
                        ));
                    end
                end
            end
        end
    end
    return staleKeys;
end

local function WithSimulationOverlay(playerID, overlay, ignoredKeys, callback)
    local originalGetMapPinSubject = GetMapPinSubject;
    local originalUpdateMapPinSubject = UpdateMapPinSubject;
    local originalGetPlotFeatureTypes = GetPlotFeatureTypes;

    GetMapPinSubject = function(checkPlayerID, x, y)
        if checkPlayerID == playerID then
            local key = Key(x, y);
            local simulated = overlay[key];
            if simulated ~= nil then
                if simulated == false then return nil; end
                return simulated;
            end
            if ignoredKeys and ignoredKeys[key] then return nil; end
        end
        return originalGetMapPinSubject(checkPlayerID, x, y);
    end;

    UpdateMapPinSubject = function(checkPlayerID, x, y, subject)
        if checkPlayerID == playerID then
            overlay[Key(x, y)] = subject or false;
            return;
        end
        return originalUpdateMapPinSubject(checkPlayerID, x, y, subject);
    end;

    GetPlotFeatureTypes = function(plot, checkPlayerID)
        local terrainType, featureType, improvementType,
            wonderType, districtType, resourceType =
            originalGetPlotFeatureTypes(plot, checkPlayerID);
        if checkPlayerID == playerID and plot then
            local directive = AMT_PlotDirectives[
                Key(plot:GetX(), plot:GetY())
            ];
            if directive then
                if directive.removeFeature then featureType = nil; end
                if directive.removeResource then resourceType = nil; end
                if directive.plantForest then
                    featureType = "FEATURE_FOREST";
                end
            end
        end
        return terrainType, featureType, improvementType,
            wonderType, districtType, resourceType;
    end;

    -- DMT caches realized plot features by coordinate only.  Clear that cache
    -- after the overlay is installed so every lookup realizes the complete
    -- projected layout rather than a previous real-map or candidate state.
    pcall(UpdatePinYields, playerID, {});
    local ok, resultA, resultB, resultC = pcall(callback);
    GetMapPinSubject = originalGetMapPinSubject;
    UpdateMapPinSubject = originalUpdateMapPinSubject;
    GetPlotFeatureTypes = originalGetPlotFeatureTypes;
    -- Never leave projected districts or wonders in DMT's shared cache after
    -- restoring the real map-pin functions.
    pcall(UpdatePinYields, playerID, {});

    if not ok then
        Log("Simulation error: " .. tostring(resultA));
        return nil, nil, {
            stage = "SIMULATION_ERROR",
            detail = tostring(resultA),
        };
    end
    return resultA, resultB, resultC;
end

function AMT_GetLocalYieldCacheKey(playerID, subject)
    if not subject then return nil; end
    local parts = {
        tostring(playerID or ""),
        tostring(subject.Type or ""),
        tostring(subject.Key or ""),
        tostring(subject.X or ""),
        tostring(subject.Y or ""),
        tostring(subject.CityID or ""),
    };
    for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
        local plot = Map.GetAdjacentPlot(
            subject.X, subject.Y, direction
        );
        local adjacentSubject = plot and GetMapPinSubject(
            playerID, plot:GetX(), plot:GetY()
        ) or nil;
        parts[#parts + 1] = adjacentSubject and table.concat({
            tostring(direction),
            tostring(adjacentSubject.Type or ""),
            tostring(adjacentSubject.Key or ""),
            tostring(adjacentSubject.CityID or ""),
        }, ":") or (tostring(direction) .. ":-");
    end
    return table.concat(parts, "|");
end

function AMT_StoreBoundedRunCache(
    runCache, tableField, countField, limitField, key, value, metricName
)
    if not runCache or not key then return; end
    local storage = runCache[tableField];
    if not storage then
        storage = {};
        runCache[tableField] = storage;
    end
    if storage[key] ~= nil then
        storage[key] = value;
        return;
    end
    local count = tonumber(runCache[countField]) or 0;
    local limit = math.max(1, tonumber(runCache[limitField]) or 1);
    if count >= limit then
        storage = {};
        runCache[tableField] = storage;
        runCache[countField] = 0;
        count = 0;
        if type(collectgarbage) == "function" then
            pcall(collectgarbage, "step", 256);
        end
    end
    storage[key] = value;
    runCache[countField] = count + 1;
end

local function GetTileYieldPenalty(plot, weights, playerID)
    local value = 0;
    for _, yieldType in ipairs(YIELD_LIST) do
        local yieldRow = GameInfo.Yields[yieldType];
        if yieldRow then
            local visibleYield = math.max(
                0,
                plot:GetYield(yieldRow.Index)
                    - ImprovementPlacement.GetHiddenResourceYield(
                        plot, playerID, yieldType
                    )
            );
            value = value
                + visibleYield * (weights[yieldType] or 1);
        end
    end
    local foodRow = GameInfo.Yields["YIELD_FOOD"];
    local productionRow = GameInfo.Yields["YIELD_PRODUCTION"];
    if foodRow then
        value = value + math.max(
            0,
            plot:GetYield(foodRow.Index)
                - ImprovementPlacement.GetHiddenResourceYield(
                    plot, playerID, "YIELD_FOOD"
                )
        ) * 0.45;
    end
    if productionRow then
        value = value + math.max(
            0,
            plot:GetYield(productionRow.Index)
                - ImprovementPlacement.GetHiddenResourceYield(
                    plot, playerID, "YIELD_PRODUCTION"
                )
        ) * 0.65;
    end
    if ImprovementPlacement.GetVisibleResource(plot, playerID) then
        value = value + 2;
    end
    if plot:GetWorkerCount() > 0 then value = value * 1.75; end
    return value * TILE_YIELD_PENALTY;
end

local function GetAdjacentPlots(x, y)
    local adjacent = {};
    for _, plot in ipairs(GetPlotsWithinXTiles(x, y, 1)) do
        if not (plot:GetX() == x and plot:GetY() == y) then
            table.insert(adjacent, plot);
        end
    end
    return adjacent;
end

local function GetPreservePotentialScore(
    item, items, fixedSubjects, playerID
)
    if item.baseDistrictType ~= "DISTRICT_PRESERVE" then return 0; end
    local occupied = {};
    for _, other in ipairs(items or {}) do
        if other ~= item then
            occupied[Key(other.x, other.y)] = other.subjectType;
        end
    end
    for _, subject in ipairs(fixedSubjects or {}) do
        occupied[Key(subject.X, subject.Y)] = subject.Type;
    end

    local score = 0;
    local projectedSubjects =
        AMT_AppealProjection.BuildSubjectMap(items, fixedSubjects);
    for _, plot in ipairs(GetAdjacentPlots(item.x, item.y)) do
        local plotKey = Key(plot:GetX(), plot:GetY());
        if occupied[plotKey]
            or plot:GetDistrictType() >= 0
            or plot:GetWonderType() >= 0
            or plot:GetImprovementType() >= 0 then
            score = score - 9;
        else
            score = score + 1.5;
        end
        local appeal = AMT_AppealProjection.GetProjectedAppeal(
            plot, items, fixedSubjects, projectedSubjects
        );
        score = score + math.max(-2, math.min(6, appeal)) * 0.7;
        if appeal >= 4 then score = score + 1.5; end
        if ImprovementPlacement.GetVisibleResource(plot, playerID) then
            score = score - 2.5;
        end
        local terrain = GameInfo.Terrains[plot:GetTerrainType()];
        local terrainType = terrain and terrain.TerrainType or "";
        if string.find(terrainType, "DESERT")
            or string.find(terrainType, "SNOW") then
            score = score - 1.5;
        end
        local featureType = AMT_AppealProjection.GetProjectedFeature(
            plot, projectedSubjects
        ) or "";
        if string.find(featureType, "FOREST") then
            score = score + 1.25;
        elseif string.find(featureType, "RAINFOREST")
            or string.find(featureType, "MARSH")
            or string.find(featureType, "FLOODPLAINS")
            or string.find(featureType, "VOLCANO") then
            score = score - 1.5;
        end
    end
    return score;
end

local function GetStrategicLayoutScore(items, fixedSubjects)
    local total = 0;
    local coverage = {
        DISTRICT_INDUSTRIAL_ZONE = {},
        DISTRICT_ENTERTAINMENT_COMPLEX = {},
    };
    local cityDistricts = {};
    local player = Players[Game.GetLocalPlayer()];
    for _, item in ipairs(items or {}) do
        if item.subjectType == MAP_PIN_TYPE_DISTRICT then
            local baseType = item.baseDistrictType
                or GetDistrictStrategyType(item.subjectKey);
            local yieldType = GetDistrictYieldFocus(baseType);
            local focusState = yieldType
                and (m_YieldFocusStates[yieldType] or 0) or 0;
            total = total + (focusState == 1 and 5
                or (focusState == -1 and -4 or 0));
            if m_PrioritizeUnique and item.isUniqueDistrict then
                total = total + 3.5;
            end
            total = total + GetPreservePotentialScore(
                item, items, fixedSubjects, Game.GetLocalPlayer()
            );
            cityDistricts[item.cityID] = cityDistricts[item.cityID] or {};
            cityDistricts[item.cityID][baseType] = true;
            if coverage[baseType] and player then
                for _, city in player:GetCities():Members() do
                    if Map.GetPlotDistance(
                        item.x, item.y, city:GetX(), city:GetY()
                    ) <= 6 and not coverage[baseType][city:GetID()] then
                        coverage[baseType][city:GetID()] = true;
                        total = total + 1.4;
                    end
                end
            end
        end
    end
    for _, districts in pairs(cityDistricts) do
        if districts.DISTRICT_COMMERCIAL_HUB
            and districts.DISTRICT_HARBOR then
            -- Both can be useful, but the second normally does not provide
            -- another trade-route capacity. Treat the duplication as an
            -- opportunity cost rather than an illegal combination.
            total = total - 4;
        end
    end
    return total;
end

-- Keep the hard spatial relationship in the main planner.  DMT evaluates an
-- adjacent district tack dynamically, so the optimizer must be able to build
-- the same projected relationship even if the optional wonder helper was not
-- loaded by the UI context.
local function GetMissingWonderSupports(wonderItem, items, fixedSubjects)
    local row = GameInfo.Buildings
        and GameInfo.Buildings[wonderItem.subjectKey] or nil;
    local requiredDistrict = row and row.AdjacentDistrict or nil;
    local requiredImprovement = row and row.AdjacentImprovement or nil;
    if not requiredDistrict and not requiredImprovement then
        return nil, nil;
    end

    local projected = {};
    for _, subject in ipairs(fixedSubjects or {}) do
        projected[Key(subject.X, subject.Y)] = subject;
    end
    for _, item in ipairs(items or {}) do
        projected[Key(item.x, item.y)] = item;
    end
    local foundDistrict = requiredDistrict == nil;
    local foundImprovement = requiredImprovement == nil;
    local requiredStrategy = requiredDistrict
        and GetDistrictStrategyType(requiredDistrict) or nil;
    for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
        local plot = Map.GetAdjacentPlot(
            wonderItem.x, wonderItem.y, direction
        );
        if plot then
            local subject = projected[Key(plot:GetX(), plot:GetY())];
            local subjectType = subject
                and (subject.subjectType or subject.Type) or nil;
            local subjectKey = subject
                and (subject.subjectKey or subject.Key) or nil;
            local subjectCityID = subject
                and (subject.cityID or subject.CityID) or nil;
            if not subject then
                local districtIndex = plot:GetDistrictType();
                if districtIndex and districtIndex >= 0 then
                    local districtRow = GameInfo.Districts[districtIndex];
                    subjectType = MAP_PIN_TYPE_DISTRICT;
                    subjectKey = districtRow and districtRow.DistrictType or nil;
                else
                    local improvementIndex = plot:GetImprovementType();
                    if improvementIndex and improvementIndex >= 0 then
                        local improvementRow =
                            GameInfo.Improvements[improvementIndex];
                        subjectType = MAP_PIN_TYPE_IMPROVEMENT;
                        subjectKey = improvementRow
                            and improvementRow.ImprovementType or nil;
                    end
                end
                local purchaseCity = AMT_GetPlotPurchaseCity(plot);
                subjectCityID = purchaseCity and purchaseCity:GetID() or nil;
            end
            local sameCity = subjectCityID == wonderItem.cityID;
            if sameCity and requiredStrategy
                and subjectType == MAP_PIN_TYPE_DISTRICT
                and GetDistrictStrategyType(subjectKey)
                    == requiredStrategy then
                foundDistrict = true;
            end
            if sameCity and subjectType == MAP_PIN_TYPE_IMPROVEMENT
                and subjectKey == requiredImprovement then
                foundImprovement = true;
            end
        end
    end
    return foundDistrict and nil or requiredDistrict,
        foundImprovement and nil or requiredImprovement;
end

-- Conservative influence-scope reader for the release package.  A planned item
-- always has at least radius-one influence because its presence can change a
-- neighboring district or improvement's adjacency.  Wider, city-wide, and
-- global effects expand that scope; anything we cannot prove falls back to a
-- fully dynamic fixed-yield calculation.
AMT_InfluenceScope = AMT_InfluenceScope or {};

function AMT_InfluenceScope.New(kind, radius, source)
    return {
        kind = kind or "UNKNOWN",
        radius = tonumber(radius),
        source = source or "unspecified",
    };
end

function AMT_InfluenceScope.Merge(current, incoming)
    if not incoming then return current; end
    if not current then return incoming; end
    if current.kind == "UNKNOWN" then return current; end
    if incoming.kind == "UNKNOWN" then return incoming; end
    if current.kind == "GLOBAL" then return current; end
    if incoming.kind == "GLOBAL" then return incoming; end
    if current.kind == "CITY" then return current; end
    if incoming.kind == "CITY" then return incoming; end
    local currentRadius = tonumber(current.radius) or 1;
    local incomingRadius = tonumber(incoming.radius) or 1;
    if incomingRadius > currentRadius then return incoming; end
    return current;
end

function AMT_InfluenceScope.EnsureIndexes(runCache)
    if not runCache or runCache.influenceIndexesBuilt then return; end
    runCache.influenceIndexesBuilt = true;
    runCache.influenceModifierIDs = {
        DISTRICT = {}, IMPROVEMENT = {}, WONDER = {},
    };
    runCache.influenceModifierTableAvailable = {};
    runCache.influenceModifierArguments = {};
    runCache.influenceModifierArgumentsAvailable =
        GameInfo.ModifierArguments ~= nil;
    runCache.influenceRequirementSets = {};
    runCache.influenceRegionalRanges = {};
    runCache.influencePotentialPlanningModifierIDs = {};

    local cfg = PlayerConfigurations[runCache.playerID];
    runCache.influenceLeaderType = nil;
    runCache.influenceCivilizationType = nil;
    if cfg then
        if type(cfg.GetLeaderTypeName) == "function" then
            local ok, value = pcall(function()
                return cfg:GetLeaderTypeName();
            end);
            if ok then runCache.influenceLeaderType = value; end
        end
        if type(cfg.GetCivilizationTypeName) == "function" then
            local ok, value = pcall(function()
                return cfg:GetCivilizationTypeName();
            end);
            if ok then runCache.influenceCivilizationType = value; end
        end
    end

    if GameInfo.ModifierArguments then
        for row in GameInfo.ModifierArguments() do
            local byName = runCache.influenceModifierArguments[
                row.ModifierId
            ] or {};
            byName[row.Name] = row.Value;
            runCache.influenceModifierArguments[row.ModifierId] = byName;
        end
    end

    local requirementArguments = {};
    if GameInfo.RequirementArguments then
        for row in GameInfo.RequirementArguments() do
            requirementArguments[row.RequirementId] =
                requirementArguments[row.RequirementId] or {};
            requirementArguments[row.RequirementId][row.Name] = row.Value;
        end
    end
    if GameInfo.RequirementSets then
        for row in GameInfo.RequirementSets() do
            runCache.influenceRequirementSets[row.RequirementSetId] = {
                setType = row.RequirementSetType,
                requirements = {},
            };
        end
    end
    if GameInfo.RequirementSetRequirements then
        for row in GameInfo.RequirementSetRequirements() do
            local set = runCache.influenceRequirementSets[
                row.RequirementSetId
            ];
            local requirement = GameInfo.Requirements
                and GameInfo.Requirements[row.RequirementId] or nil;
            if set and requirement then
                table.insert(set.requirements, {
                    requirementType = requirement.RequirementType,
                    inverse = IsTrue(requirement.Inverse),
                    arguments = requirementArguments[row.RequirementId]
                        or {},
                });
            end
        end
    end

    local definitions = {
        {
            rows = GameInfo.DistrictModifiers,
            keyColumn = "DistrictType",
            subjectType = MAP_PIN_TYPE_DISTRICT,
        },
        {
            rows = GameInfo.ImprovementModifiers,
            keyColumn = "ImprovementType",
            subjectType = MAP_PIN_TYPE_IMPROVEMENT,
        },
        {
            rows = GameInfo.BuildingModifiers,
            keyColumn = "BuildingType",
            subjectType = MAP_PIN_TYPE_WONDER,
        },
    };
    for _, definition in ipairs(definitions) do
        runCache.influenceModifierTableAvailable[
            definition.subjectType
        ] = definition.rows ~= nil;
        if definition.rows then
            for row in definition.rows() do
                local subjectKey = row[definition.keyColumn];
                local modifierID = row.ModifierId or row.ModifierID;
                if subjectKey and modifierID then
                    local byKey = runCache.influenceModifierIDs[
                        definition.subjectType
                    ];
                    byKey[subjectKey] = byKey[subjectKey] or {};
                    table.insert(byKey[subjectKey], modifierID);
                    local isPlanningCandidate =
                        definition.subjectType ~= MAP_PIN_TYPE_WONDER;
                    if definition.subjectType == MAP_PIN_TYPE_WONDER then
                        local building = GameInfo.Buildings
                            and GameInfo.Buildings[subjectKey] or nil;
                        isPlanningCandidate = building ~= nil
                            and (IsTrue(building.IsWonder)
                                or tonumber(building.MaxWorldInstances) == 1);
                    end
                    if isPlanningCandidate then
                        runCache.influencePotentialPlanningModifierIDs[
                            modifierID
                        ] = true;
                    end
                end
            end
        end
    end

    if GameInfo.Buildings then
        for row in GameInfo.Buildings() do
            local range = tonumber(row.RegionalRange) or 0;
            if row.PrereqDistrict and range > 0 then
                runCache.influenceRegionalRanges[row.PrereqDistrict] =
                    math.max(
                        runCache.influenceRegionalRanges[
                            row.PrereqDistrict
                        ] or 0,
                        range
                    );
            end
        end
    end
    AMT_InfluenceScope.BuildRuntimeModifierRelevance(runCache);
    AMT_InfluenceScope.BuildStateYieldDependencies(runCache);
end

function AMT_InfluenceScope.FromCollection(collectionType, source)
    local collection = string.upper(tostring(collectionType or ""));
    if collection == "" then return nil; end
    if string.find(collection, "PLAYER", 1, true)
        or string.find(collection, "GLOBAL", 1, true)
        or string.find(collection, "ALL_", 1, true)
        or string.find(collection, "MAJOR", 1, true) then
        return AMT_InfluenceScope.New("GLOBAL", nil, source);
    end
    if string.find(collection, "CITY", 1, true) then
        return AMT_InfluenceScope.New("CITY", nil, source);
    end
    if string.find(collection, "ADJACENT", 1, true) then
        return AMT_InfluenceScope.New("ADJACENT", 1, source);
    end
    if string.find(collection, "PLOT", 1, true) then
        return AMT_InfluenceScope.New("ADJACENT", 1, source);
    end
    return nil;
end

function AMT_InfluenceScope.OwnerRequirementResult(runCache, setID)
    if not setID then return "TRUE"; end
    local set = runCache.influenceRequirementSets[setID];
    if not set or #set.requirements == 0 then return "UNKNOWN"; end
    local testAny = set.setType == "REQUIREMENTSET_TEST_ANY";
    local sawUnknown = false;
    for _, requirement in ipairs(set.requirements) do
        local result = nil;
        local args = requirement.arguments or {};
        if requirement.requirementType
            == "REQUIREMENT_PLAYER_LEADER_TYPE_MATCHES"
            and runCache.influenceLeaderType then
            result = runCache.influenceLeaderType == args.LeaderType;
        elseif requirement.requirementType
            == "REQUIREMENT_PLAYER_CIVILIZATION_TYPE_MATCHES"
            and runCache.influenceCivilizationType then
            result = runCache.influenceCivilizationType
                == args.CivilizationType;
        end
        if result ~= nil and requirement.inverse then result = not result; end
        if result == nil then
            sawUnknown = true;
        elseif testAny and result then
            return "TRUE";
        elseif not testAny and not result then
            return "FALSE";
        end
    end
    if sawUnknown then return "UNKNOWN"; end
    return testAny and "FALSE" or "TRUE";
end

AMT_InfluenceScope.NonPlanningEffectStates = {
    EFFECT_ADJUST_IMPROVEMENT_HOUSING = "HOUSING",
    EFFECT_ADJUST_BUILDING_HOUSING = "HOUSING",
    EFFECT_ADJUST_IMPROVEMENT_AMENITY = "AMENITY",
    EFFECT_ADJUST_DISTRICT_AMENITY = "AMENITY",
    EFFECT_ADJUST_CITY_ENTERTAINMENT_FROM_WONDER_ADJACENT_TO_LAKE =
        "AMENITY",
    EFFECT_ADJUST_CITY_FREE_POWER = "POWER",
    EFFECT_ADJUST_MODIFIED_FREE_POWER_IN_CITY = "POWER",
    EFFECT_ADJUST_DISTRICT_WITHIN_ONE_HEX_ESPIONAGE_DEFENSE_BONUS =
        "ESPIONAGE",
    EFFECT_ADJUST_CITY_IDENTITY_PER_TURN = "LOYALTY",
    EFFECT_ADJUST_CITY_ALWAYS_LOYAL = "LOYALTY",
    EFFECT_ADJUST_CITY_RELIGION_PRESSURE = "RELIGION",
    EFFECT_ADJUST_CITY_GROWTH = "POPULATION",
    EFFECT_ADJUST_CITY_POPULATION = "POPULATION",
    EFFECT_ADJUST_TRADE_ROUTE_CAPACITY = "TRADE_ROUTE",
};

AMT_InfluenceScope.StateRequirementTokens = {
    POWER = { "POWER" },
    AMENITY = { "AMENIT" },
    HOUSING = { "HOUSING" },
    ESPIONAGE = { "ESPIONAGE", "SPY" },
    LOYALTY = { "LOYAL", "IDENTITY" },
    RELIGION = { "RELIGION", "FOLLOWER" },
    POPULATION = { "POPULATION" },
    TOURISM = { "TOURISM" },
    TRADE_ROUTE = { "TRADE_ROUTE", "TRADEROUTE" },
};

AMT_InfluenceScope.CacheNeutralEffectFragments = {
    "_UNIT_", "GRANT_UNIT", "GRANT_ABILITY", "GRANT_PROMOTION",
    "GREAT_PERSON", "GREAT_WORK_SLOT", "GOVERNMENT_SLOT",
    "GOVERNOR_POINT", "INFLUENCE_TOKEN", "DIPLOMATIC_VICTORY",
    "FAVOR", "ERA_SCORE", "TECHNOLOGY", "CIVIC",
    "PURCHASE_COST", "PRODUCTION", "HEALING", "MOVEMENT",
    "BUILD_CHARGES", "SPREAD_CHARGES", "EXPERIENCE",
    "PATRONAGE", "TREASURY", "CORPS_ARMY", "MOUNTAIN_PORTAL",
    "EXTRA_UNIT_COPY_TAG",
};

function AMT_InfluenceScope.GetNonPlanningState(effectType)
    local effect = string.upper(tostring(effectType or ""));
    local exact = AMT_InfluenceScope.NonPlanningEffectStates[effect];
    if exact then return exact; end
    if string.find(effect, "TOURISM", 1, true) then return "TOURISM"; end
    return nil;
end

function AMT_InfluenceScope.IsYieldRelevantEffect(effectType)
    local effect = string.upper(tostring(effectType or ""));
    return string.find(effect, "YIELD", 1, true) ~= nil
        or string.find(effect, "ADJACENCY", 1, true) ~= nil
        or string.find(effect, "APPEAL", 1, true) ~= nil
        or effect == "EFFECT_ATTACH_MODIFIER";
end

function AMT_InfluenceScope.IsCacheNeutralEffect(effectType)
    local effect = string.upper(tostring(effectType or ""));
    if AMT_InfluenceScope.IsYieldRelevantEffect(effect) then return false; end
    for _, fragment in ipairs(
        AMT_InfluenceScope.CacheNeutralEffectFragments
    ) do
        if string.find(effect, fragment, 1, true) then return true; end
    end
    return false;
end

function AMT_InfluenceScope.RequirementSetMentionsState(
    runCache, setID, tokens
)
    if not setID then return false; end
    local text = string.upper(tostring(setID));
    local set = runCache.influenceRequirementSets[setID];
    if set then
        for _, requirement in ipairs(set.requirements or {}) do
            text = text .. "|" .. string.upper(tostring(
                requirement.requirementType or ""
            ));
            for name, value in pairs(requirement.arguments or {}) do
                text = text .. "|" .. string.upper(tostring(name))
                    .. "=" .. string.upper(tostring(value));
            end
        end
    end
    for _, token in ipairs(tokens or {}) do
        if string.find(text, token, 1, true) then return true; end
    end
    return false;
end

-- Build a per-run view of modifier definitions that are actually active for
-- the local player.  Unlike the static GameInfo tables, GameEffects only
-- contains instantiated modifier objects, so an unused great person or an
-- uncompleted permanent project no longer disables caches for every city.
-- Planned districts, improvements, and wonders remain potential sources even
-- before they have a runtime object.  If the runtime API is unavailable or a
-- modifier object cannot be interpreted, callers retain the conservative
-- fallback.
function AMT_InfluenceScope.BuildRuntimeModifierRelevance(runCache)
    runCache.influenceRuntimeModifierAPIAvailable = false;
    runCache.influenceRuntimeRelevantModifierIDs = {};
    runCache.influenceRuntimeUncertainModifierIDs = {};
    if type(GameEffects) ~= "table"
        or type(GameEffects.GetModifiers) ~= "function"
        or type(GameEffects.GetModifierActive) ~= "function"
        or type(GameEffects.GetModifierDefinition) ~= "function" then
        return;
    end

    local okModifiers, modifierObjects = pcall(GameEffects.GetModifiers);
    if not okModifiers or type(modifierObjects) ~= "table" then
        return;
    end
    runCache.influenceRuntimeModifierAPIAvailable = true;

    local function GetObjectPlayerID(objectID)
        if objectID == nil
            or type(GameEffects.GetObjectsPlayerId) ~= "function" then
            return nil;
        end
        local ok, value = pcall(GameEffects.GetObjectsPlayerId, objectID);
        if not ok then return nil; end
        value = tonumber(value);
        return value and value >= 0 and value or nil;
    end

    for _, modifierObjectID in ipairs(modifierObjects) do
        local okActive, isActive = pcall(
            GameEffects.GetModifierActive, modifierObjectID
        );
        if okActive and isActive then
            local okDefinition, definition = pcall(
                GameEffects.GetModifierDefinition, modifierObjectID
            );
            local modifierID = okDefinition and definition
                and definition.Id or nil;
            if modifierID then
                local relevant = false;
                local sawScopedObject = false;
                if type(GameEffects.GetModifierOwner) == "function" then
                    local okOwner, ownerObjectID = pcall(
                        GameEffects.GetModifierOwner, modifierObjectID
                    );
                    if okOwner and ownerObjectID ~= nil then
                        local ownerPlayerID = GetObjectPlayerID(ownerObjectID);
                        if ownerPlayerID ~= nil then
                            sawScopedObject = true;
                            relevant = ownerPlayerID == runCache.playerID;
                        end
                    end
                end
                if not relevant
                    and type(GameEffects.GetModifierSubjects) == "function" then
                    local okSubjects, subjects = pcall(
                        GameEffects.GetModifierSubjects, modifierObjectID
                    );
                    if okSubjects and type(subjects) == "table" then
                        for _, subjectObjectID in ipairs(subjects) do
                            local subjectPlayerID =
                                GetObjectPlayerID(subjectObjectID);
                            if subjectPlayerID ~= nil then
                                sawScopedObject = true;
                                if subjectPlayerID == runCache.playerID then
                                    relevant = true;
                                    break;
                                end
                            end
                        end
                    end
                end

                local modifier = GameInfo.Modifiers
                    and GameInfo.Modifiers[modifierID] or nil;
                local dynamic = modifier and GameInfo.DynamicModifiers
                    and GameInfo.DynamicModifiers[
                        modifier.ModifierType
                    ] or nil;
                local collection = string.upper(tostring(
                    dynamic and dynamic.CollectionType or ""
                ));
                if string.find(collection, "ALL_", 1, true)
                    or string.find(collection, "GLOBAL", 1, true) then
                    relevant = true;
                end

                if relevant then
                    runCache.influenceRuntimeRelevantModifierIDs[
                        modifierID
                    ] = true;
                elseif not sawScopedObject then
                    -- Custom modifier owners may not expose a player id.  Do
                    -- not turn that API limitation into a compatibility bug.
                    runCache.influenceRuntimeUncertainModifierIDs[
                        modifierID
                    ] = true;
                end
            else
            end
        end
    end
end

function AMT_InfluenceScope.GetStateDependencyRelevance(
    runCache, modifierID
)
    if not runCache.influenceRuntimeModifierAPIAvailable then
        return true, "runtime_api_unavailable";
    end
    if runCache.influenceRuntimeRelevantModifierIDs[modifierID] then
        return true, "runtime_active_for_player";
    end
    if runCache.influencePotentialPlanningModifierIDs[modifierID] then
        return true, "planning_candidate";
    end
    if runCache.influenceRuntimeUncertainModifierIDs[modifierID] then
        return true, "runtime_scope_uncertain";
    end
    return false, "not_active_for_player";
end

function AMT_InfluenceScope.BuildStateYieldDependencies(runCache)
    runCache.influenceStateYieldDependencies = {};
    runCache.influenceStateYieldDependencySources = {};
    if GameInfo.Modifiers then
        for modifier in GameInfo.Modifiers() do
            local dynamic = GameInfo.DynamicModifiers
                and GameInfo.DynamicModifiers[modifier.ModifierType] or nil;
            if dynamic and AMT_InfluenceScope.IsYieldRelevantEffect(
                dynamic.EffectType
            ) and AMT_InfluenceScope.OwnerRequirementResult(
                runCache, modifier.OwnerRequirementSetId
            ) ~= "FALSE" and AMT_InfluenceScope.OwnerRequirementResult(
                runCache, modifier.SubjectRequirementSetId
            ) ~= "FALSE" then
                for state, tokens in pairs(
                    AMT_InfluenceScope.StateRequirementTokens
                ) do
                    if not runCache.influenceStateYieldDependencies[state] then
                        local matchedSet = nil;
                        if AMT_InfluenceScope.RequirementSetMentionsState(
                            runCache, modifier.OwnerRequirementSetId, tokens
                        ) then
                            matchedSet = modifier.OwnerRequirementSetId;
                        elseif AMT_InfluenceScope.RequirementSetMentionsState(
                            runCache, modifier.SubjectRequirementSetId, tokens
                        ) then
                            matchedSet = modifier.SubjectRequirementSetId;
                        end
                        if matchedSet then
                            local dependencySource =
                                tostring(modifier.ModifierId)
                                .. ":" .. tostring(matchedSet);
                            local relevant, relevanceReason =
                                AMT_InfluenceScope.GetStateDependencyRelevance(
                                    runCache, modifier.ModifierId
                                );
                            if relevant then
                                runCache.influenceStateYieldDependencies[state] =
                                    true;
                                runCache.influenceStateYieldDependencySources[
                                    state
                                ] = dependencySource;
                            else
                            end
                        end
                    end
                end
            end
        end
    end
end

function AMT_InfluenceScope.FromModifier(runCache, modifierID, seen)
    if not modifierID then
        return AMT_InfluenceScope.New("UNKNOWN", nil, "missing_modifier_id");
    end
    seen = seen or {};
    if seen[modifierID] then
        return AMT_InfluenceScope.New(
            "UNKNOWN", nil, "modifier_cycle:" .. tostring(modifierID)
        );
    end
    seen[modifierID] = true;
    local modifier = GameInfo.Modifiers
        and GameInfo.Modifiers[modifierID] or nil;
    local dynamic = modifier and GameInfo.DynamicModifiers
        and GameInfo.DynamicModifiers[modifier.ModifierType] or nil;
    if not modifier or not dynamic then
        return AMT_InfluenceScope.New(
            "UNKNOWN", nil, "unresolved_modifier:" .. tostring(modifierID)
        );
    end
    if not runCache.influenceModifierArgumentsAvailable then
        return AMT_InfluenceScope.New(
            "UNKNOWN", nil, "modifier_arguments_unavailable"
        );
    end
    local args = runCache.influenceModifierArguments[modifierID] or {};
    local effectType = tostring(dynamic.EffectType or "");
    local source = "modifier:" .. tostring(modifierID);
    if AMT_InfluenceScope.OwnerRequirementResult(
        runCache, modifier.OwnerRequirementSetId
    ) == "FALSE" then
        return AMT_InfluenceScope.New(
            "ADJACENT", 1, source .. ":inactive_owner_requirement"
        );
    end
    local nonPlanningState =
        AMT_InfluenceScope.GetNonPlanningState(effectType);
    if nonPlanningState then
        if runCache.influenceStateYieldDependencies[nonPlanningState] then
            return AMT_InfluenceScope.New(
                "CITY", nil,
                source .. ":state_dependency:" .. nonPlanningState
            );
        end
        return AMT_InfluenceScope.New(
            "ADJACENT", 1,
            source .. ":no_yield_dependency:" .. nonPlanningState
        );
    end
    if AMT_InfluenceScope.IsCacheNeutralEffect(effectType) then
        return AMT_InfluenceScope.New(
            "ADJACENT", 1, source .. ":cache_neutral_effect"
        );
    end
    local scope = AMT_InfluenceScope.New("ADJACENT", 1, source);
    local explicitRange = 0;
    for _, name in ipairs({
        "Radius", "Range", "Distance", "MaxDistance",
        "MaximumDistance", "RegionalRange", "GainTileRadius",
        "DistanceChange",
    }) do
        explicitRange = math.max(
            explicitRange, tonumber(args[name]) or 0
        );
    end
    if explicitRange > 1 then
        scope = AMT_InfluenceScope.New(
            "RADIUS", explicitRange, source .. ":explicit_range"
        );
    end

    local collectionScope = AMT_InfluenceScope.FromCollection(
        dynamic.CollectionType, source .. ":collection"
    );
    if collectionScope then
        scope = AMT_InfluenceScope.Merge(scope, collectionScope);
    end

    if effectType == "EFFECT_ATTACH_MODIFIER" then
        local attachedID = args.ModifierId or args.ModifierID;
        if not attachedID then
            return AMT_InfluenceScope.New(
                "UNKNOWN", nil, source .. ":missing_attachment"
            );
        end
        local attachedScope = AMT_InfluenceScope.FromModifier(
            runCache, attachedID, seen
        );
        if not collectionScope
            and dynamic.CollectionType == "COLLECTION_OWNER" then
            if string.find(
                tostring(modifier.ModifierType or ""),
                "SINGLE_CITY", 1, true
            ) then
                return AMT_InfluenceScope.Merge(
                    AMT_InfluenceScope.New(
                        "CITY", nil, source .. ":single_city_attachment"
                    ),
                    attachedScope
                );
            end
            if attachedScope.kind ~= "ADJACENT" then
                return attachedScope;
            end
            return AMT_InfluenceScope.New(
                "UNKNOWN", nil, source .. ":owner_attachment"
            );
        end
        return AMT_InfluenceScope.Merge(scope, attachedScope);
    end

    if string.find(effectType, "ADJACENCY", 1, true) then
        return scope;
    end
    if explicitRange > 0 or collectionScope then
        return scope;
    end
    return AMT_InfluenceScope.New(
        "UNKNOWN", nil, source .. ":unsupported_scope"
    );
end

function AMT_InfluenceScope.Get(runCache, subject)
    if not runCache or not subject then
        return AMT_InfluenceScope.New("UNKNOWN", nil, "missing_context");
    end
    AMT_InfluenceScope.EnsureIndexes(runCache);
    local subjectType = subject.subjectType or subject.Type;
    local subjectKey = subject.subjectKey or subject.Key;
    local cacheKey = tostring(subjectType) .. ":" .. tostring(subjectKey);
    local cached = runCache.influenceScopes[cacheKey];
    if cached then return cached; end

    local scope = AMT_InfluenceScope.New(
        "ADJACENT", 1, "tile_presence"
    );
    if not runCache.influenceModifierTableAvailable[subjectType] then
        scope = AMT_InfluenceScope.New(
            "UNKNOWN", nil, "modifier_table_unavailable"
        );
    end
    local byType = runCache.influenceModifierIDs[subjectType];
    local modifierIDs = byType and byType[subjectKey] or {};
    for _, modifierID in ipairs(modifierIDs or {}) do
        scope = AMT_InfluenceScope.Merge(
            scope,
            AMT_InfluenceScope.FromModifier(runCache, modifierID, {})
        );
    end

    if subjectType == MAP_PIN_TYPE_DISTRICT then
        local strategyType = GetDistrictStrategyType(subjectKey);
        local regionalRange = math.max(
            runCache.influenceRegionalRanges[subjectKey] or 0,
            runCache.influenceRegionalRanges[strategyType] or 0
        );
        if regionalRange > 1 then
            scope = AMT_InfluenceScope.Merge(
                scope,
                AMT_InfluenceScope.New(
                    "RADIUS", regionalRange, "building_regional_range"
                )
            );
        end
    end

    runCache.influenceScopes[cacheKey] = scope;
    if scope.kind == "RADIUS" then
    end
    return scope;
end

function AMT_InfluenceScope.FixedNeedsDynamic(runCache, fixedSubject, items)
    if not runCache then return true, "UNKNOWN", nil; end
    local fixedScope = AMT_InfluenceScope.Get(runCache, fixedSubject);
    if fixedScope.kind == "UNKNOWN" or fixedScope.kind == "GLOBAL" then
        return true, fixedScope.kind, fixedScope.radius;
    elseif fixedScope.kind == "CITY" then
        for _, item in ipairs(items or {}) do
            local itemCityID = item.cityID or item.CityID;
            local fixedCityID = fixedSubject.cityID or fixedSubject.CityID;
            if itemCityID == nil or fixedCityID == nil
                or itemCityID == fixedCityID then
                return true, "CITY", nil;
            end
        end
    elseif (tonumber(fixedScope.radius) or 1) > 1 then
        local fixedRadius = tonumber(fixedScope.radius) or 1;
        for _, item in ipairs(items or {}) do
            if Map.GetPlotDistance(
                item.x or item.X, item.y or item.Y,
                fixedSubject.x or fixedSubject.X,
                fixedSubject.y or fixedSubject.Y
            ) <= fixedRadius then
                return true, "RADIUS", fixedRadius;
            end
        end
    end
    local adjacentTrigger = false;
    for _, item in ipairs(items or {}) do
        local scope = AMT_InfluenceScope.Get(runCache, item);
        local kind = scope.kind or "UNKNOWN";
        if kind == "UNKNOWN" or kind == "GLOBAL" then
            return true, kind, scope.radius;
        elseif kind == "CITY" then
            local itemCityID = item.cityID or item.CityID;
            local fixedCityID = fixedSubject.cityID or fixedSubject.CityID;
            if itemCityID == nil or fixedCityID == nil
                or itemCityID == fixedCityID then
                return true, "CITY", nil;
            end
        else
            local radius = math.max(1, tonumber(scope.radius) or 1);
            if Map.GetPlotDistance(
                item.x or item.X, item.y or item.Y,
                fixedSubject.x or fixedSubject.X,
                fixedSubject.y or fixedSubject.Y
            ) <= radius then
                if radius > 1 then
                    return true, "RADIUS", radius;
                end
                adjacentTrigger = true;
            end
        end
    end
    if adjacentTrigger then
        return true, "ADJACENT", 1;
    end
    return false, "STATIC", nil;
end

function AMT_InfluenceScope.LocalYieldCacheIsSafe(runCache, target, items)
    if not runCache or not target then return false, "missing_context"; end
    local ownScope = AMT_InfluenceScope.Get(runCache, target);
    if ownScope.kind == "UNKNOWN" or ownScope.kind == "CITY"
        or ownScope.kind == "GLOBAL"
        or (tonumber(ownScope.radius) or 1) > 1 then
        return false, "self_" .. tostring(ownScope.kind);
    end
    for _, item in ipairs(items or {}) do
        if item ~= target then
            local scope = AMT_InfluenceScope.Get(runCache, item);
            local kind = scope.kind or "UNKNOWN";
            if kind == "UNKNOWN" or kind == "GLOBAL" then
                return false, "other_" .. kind;
            elseif kind == "CITY" then
                local itemCityID = item.cityID or item.CityID;
                local targetCityID = target.cityID or target.CityID;
                if itemCityID == nil or targetCityID == nil
                    or itemCityID == targetCityID then
                    return false, "other_CITY";
                end
            elseif (tonumber(scope.radius) or 1) > 1
                and Map.GetPlotDistance(
                    item.x or item.X, item.y or item.Y,
                    target.x or target.X, target.y or target.Y
                ) <= (tonumber(scope.radius) or 1) then
                return false, "other_RADIUS";
            end
        end
    end
    return true, "local";
end

local function EvaluatePlan(
    playerID, items, weights, ignoredKeys, fixedSubjects, runCache
)
    -- Full-plan signatures produced almost no reuse (roughly 0.3pct) while
    -- retaining large result graphs.  Recompute those rare duplicates and
    -- reserve caching for the much hotter local-yield path instead.

    local overlay = {};
    local fixedByKey = {};
    for _, subject in ipairs(fixedSubjects or {}) do
        local key = Key(subject.X, subject.Y);
        if not (ignoredKeys and ignoredKeys[key]) then
            overlay[key] = subject;
            fixedByKey[key] = subject;
        end
    end

    local newKeys = {};
    for _, item in ipairs(items) do
        local key = Key(item.x, item.y);
        if newKeys[key] then
            return -math.huge, nil;
        end
        newKeys[key] = true;
        overlay[key] = MakePinSubject(item);
    end

    local score, yieldsByItem, diagnostic = WithSimulationOverlay(playerID, overlay, ignoredKeys, function()
        for _, item in ipairs(items) do
            local subject = overlay[Key(item.x, item.y)];
            local locallyLegal = item.placementLegal
                or ImprovementPlacement.CanPlan(item, playerID);
            if not locallyLegal then
                return -math.huge, nil, {
                    stage = "LOCAL_PLACEMENT_REJECT",
                    subjectType = item.subjectType,
                    subjectKey = item.subjectKey,
                    x = item.x,
                    y = item.y,
                };
            end
            -- The overlay now contains every fixed and projected subject and
            -- DMT's cache was rebuilt under it.  Use DMT itself as the single
            -- final authority for districts, improvements, and wonders.
            local checkOK, canPlace, canPlaceToolTip =
                pcall(CanPlacePin, playerID, subject);
            if not checkOK then
                return -math.huge, nil, {
                    stage = "DMT_ERROR",
                    subjectType = item.subjectType,
                    subjectKey = item.subjectKey,
                    x = item.x,
                    y = item.y,
                    detail = tostring(canPlace),
                };
            end
            if canPlace ~= true then
                return -math.huge, nil, {
                    stage = "DMT_REJECT",
                    subjectType = item.subjectType,
                    subjectKey = item.subjectKey,
                    x = item.x,
                    y = item.y,
                    detail = tostring(canPlaceToolTip or ""),
                };
            end
            -- DMT has now checked the item with every fixed and projected
            -- subject visible in the same simulation overlay.  Do not repeat
            -- wonder adjacency validation with AMT's approximate relationship
            -- model: replacement districts, modded rules, and ownership data
            -- can otherwise make the two validators disagree.
        end

        local total = 0;
        local allYields = {};
        local improvementCounts = {};
        for index, item in ipairs(items) do
            local subject = overlay[Key(item.x, item.y)];
            local scoreMultiplier = 1;
            if item.subjectType == MAP_PIN_TYPE_DISTRICT then
                if item.isSpecialty then
                    -- Slot order is strategic order, not merely an unlock
                    -- label.  Protect the best sites for the earliest
                    -- population-limited districts.
                    local order = tonumber(item.specialtyOrder) or 99;
                    scoreMultiplier = 6
                        + math.max(0, 4 - math.min(order, 4)) * 1.5;
                else
                    scoreMultiplier = 2;
                end
            elseif item.subjectType == MAP_PIN_TYPE_IMPROVEMENT then
                -- Improvements remain useful, but dozens of small local
                -- yields must not outweigh the core district layout.
                scoreMultiplier = 0.30;
                local improvementCount =
                    (improvementCounts[item.subjectKey] or 0) + 1;
                improvementCounts[item.subjectKey] = improvementCount;
                total = total
                    + ImprovementPlacement.GetStrategicScore(
                        item, playerID
                    );
                if not item.hasVisibleResource then
                    total = total
                        - math.max(0, improvementCount - 1) * 0.35;
                end
            elseif item.subjectType == MAP_PIN_TYPE_WONDER then
                scoreMultiplier = 1.25;
            end
            local localCacheIsSafe, localCacheReason =
                AMT_InfluenceScope.LocalYieldCacheIsSafe(
                    runCache, item, items
                );
            local yieldCacheKey = nil;
            if localCacheIsSafe then
                yieldCacheKey = runCache
                    and AMT_GetLocalYieldCacheKey(playerID, subject) or nil;
            else
            end
            local yieldEntry = yieldCacheKey
                and runCache.yieldEvaluations[yieldCacheKey] or nil;
            local yields = yieldEntry and yieldEntry.yields or nil;
            if yields then
            else
                yields = GetBonusYields(playerID, subject);
                yieldEntry = {
                    yields = yields,
                    weightedScores = {},
                };
                AMT_StoreBoundedRunCache(
                    runCache, "yieldEvaluations", "yieldEvaluationCount",
                    "yieldEvaluationLimit", yieldCacheKey, yieldEntry,
                    "yield.cache"
                );
            end
            allYields[index] = yields;
            total = total + AMT_GetWeightedYieldScore(
                yieldEntry, yields, weights, scoreMultiplier
            );
            if item.subjectType ~= MAP_PIN_TYPE_IMPROVEMENT then
                total = total - GetTileYieldPenalty(
                    item.plot, weights, playerID
                );
            end
        end
        for key, subject in pairs(fixedByKey) do
            if not newKeys[key] then
                local needsDynamicYield, dynamicReason, dynamicRadius =
                    AMT_InfluenceScope.FixedNeedsDynamic(
                        runCache, subject, items
                    );
                local yieldEntry = nil;
                local yieldCacheKey = nil;
                if runCache and not needsDynamicYield then
                    yieldEntry = runCache.staticFixedYieldEvaluations[key];
                    if yieldEntry then
                    end
                else
                    local localCacheIsSafe = dynamicReason == "ADJACENT"
                        or (
                            dynamicReason == "RADIUS"
                            and (tonumber(dynamicRadius) or 0) <= 1
                        );
                    if runCache and localCacheIsSafe then
                        yieldCacheKey = AMT_GetLocalYieldCacheKey(
                            playerID, subject
                        );
                    else
                    end
                    yieldEntry = yieldCacheKey
                        and runCache.yieldEvaluations[yieldCacheKey] or nil;
                end
                local yields = yieldEntry and yieldEntry.yields or nil;
                if yields then
                else
                    yields = GetBonusYields(playerID, subject);
                    yieldEntry = {
                        yields = yields,
                        weightedScores = {},
                    };
                    if runCache and not needsDynamicYield then
                        runCache.staticFixedYieldEvaluations[key] = yieldEntry;
                    elseif yieldCacheKey then
                        AMT_StoreBoundedRunCache(
                            runCache, "yieldEvaluations",
                            "yieldEvaluationCount", "yieldEvaluationLimit",
                            yieldCacheKey, yieldEntry, "yield.cache"
                        );
                    end
                end
                local scoreMultiplier = 1;
                if subject.Type == MAP_PIN_TYPE_DISTRICT then
                    scoreMultiplier = IsPopulationDistrict(subject.Key)
                        and 6 or 2;
                elseif subject.Type == MAP_PIN_TYPE_IMPROVEMENT then
                    scoreMultiplier = 0.30;
                elseif subject.Type == MAP_PIN_TYPE_WONDER then
                    scoreMultiplier = 1.25;
                end
                total = total + AMT_GetWeightedYieldScore(
                    yieldEntry, yields, weights, scoreMultiplier
                );
            end
        end
        total = total + GetStrategicLayoutScore(items, fixedSubjects);
        if AMT_WonderPlanner
            and AMT_WonderPlanner.ScoreSelectedSpatialEffects then
            total = total + AMT_WonderPlanner.ScoreSelectedSpatialEffects(
                playerID, items, fixedSubjects, weights,
                GetCityPurchasedPlots
            );
        end
        return total, allYields;
    end);

    if score == nil then score = -math.huge; end
    if score > -math.huge then
    else
    end
    return score, yieldsByItem, diagnostic;
end

local function CopyYields(source)
    local result = {};
    for yieldType, amount in pairs(source or {}) do
        result[yieldType] = amount;
    end
    return result;
end

local function AddYields(target, source, multiplier)
    multiplier = multiplier or 1;
    for yieldType, amount in pairs(source or {}) do
        target[yieldType] = (target[yieldType] or 0) + amount * multiplier;
    end
end

local function CalculateReverseImpactYields(
    playerID, items, targetIndex, ignoredKeys, fixedSubjects
)
    local target = items[targetIndex];
    if not target then return {}; end
    local targetKey = Key(target.x, target.y);
    local overlay = {};
    local affected = {};
    local seen = {};

    for _, subject in ipairs(fixedSubjects or {}) do
        local key = Key(subject.X, subject.Y);
        if key ~= targetKey
            and Map.GetPlotDistance(
                target.x, target.y, subject.X, subject.Y
            ) == 1 then
            overlay[key] = subject;
            affected[#affected + 1] = subject;
            seen[key] = true;
        end
    end
    for index, item in ipairs(items) do
        local key = Key(item.x, item.y);
        overlay[key] = MakePinSubject(item);
        if index ~= targetIndex
            and not seen[key]
            and Map.GetPlotDistance(
                target.x, target.y, item.x, item.y
            ) == 1 then
            affected[#affected + 1] = overlay[key];
            seen[key] = true;
        end
    end
    if #affected == 0 then return {}; end

    local impact = WithSimulationOverlay(
        playerID, overlay, ignoredKeys, function()
            UpdatePinYields(playerID, {});
            local withTarget = {};
            for key, subject in pairs(affected) do
                withTarget[key] = GetBonusYields(playerID, subject);
            end
            overlay[targetKey] = false;
            UpdatePinYields(playerID, {});
            local result = {};
            for key, subject in pairs(affected) do
                AddYields(result, withTarget[key], 1);
                AddYields(result, GetBonusYields(playerID, subject), -1);
            end
            return result;
        end
    );
    UpdatePinYields(playerID, {});
    return impact or {};
end

local function FindMapPinAt(playerID, x, y, runCache)
    if runCache and runCache.pinsByKey then
        return runCache.pinsByKey[Key(x, y)];
    end
    local cfg = PlayerConfigurations[playerID];
    if not cfg then return nil; end
    local pins = cfg:GetMapPins();
    if not pins then return nil; end
    for _, pin in pairs(pins) do
        if pin and pin:GetHexX() == x and pin:GetHexY() == y then
            return pin;
        end
    end
    return nil;
end

function AMT_YieldPlanning(localizationTag, current, total)
    if Controls.PlanningStatus and localizationTag then
        Controls.PlanningStatus:SetText(Locale.Lookup(
            localizationTag, current or 0, total or 0
        ));
    end
    if not m_SuppressPlanningYield
        and coroutine and coroutine.running and coroutine.yield then
        local thread, isMain = coroutine.running();
        if thread and not isMain then coroutine.yield(); end
    end
end

local function BuildWonderSupportItem(
    wonderItem, subjectType, subjectKey, plot, city, playerID,
    reservedKeys, ignoredKeys, overwriteExisting, clearFirst,
    autoRegistry, runCache
)
    if not plot then return nil; end
    local x, y = plot:GetX(), plot:GetY();
    local key = Key(x, y);
    if x == wonderItem.x and y == wonderItem.y then return nil; end
    if not IsPlotRevealedToPlayer(plot, playerID)
        or (reservedKeys and reservedKeys[key])
        or (plot:IsOwned() and plot:GetOwner() ~= playerID) then
        return nil;
    end
    local cityOwnedKeys = GetCityOwnedPlotKeys(city, runCache);
    if plot:IsOwned() and plot:GetOwner() == playerID
        and not cityOwnedKeys[key] then
        return nil;
    end
    local cityRangeKeys = runCache
        and runCache.wonderSupportCityRangeKeys
        and runCache.wonderSupportCityRangeKeys[city:GetID()] or nil;
    if not cityRangeKeys then
        cityRangeKeys = {};
        for _, cityPlot in ipairs(GetCityRangePlots(city, runCache)) do
            cityRangeKeys[Key(cityPlot:GetX(), cityPlot:GetY())] = true;
        end
        if runCache then
            runCache.wonderSupportCityRangeKeys =
                runCache.wonderSupportCityRangeKeys or {};
            runCache.wonderSupportCityRangeKeys[city:GetID()] = cityRangeKeys;
        end
    end
    if not cityRangeKeys[key]
        or (m_PlanningHorizon == "CURRENT" and not cityOwnedKeys[key]) then
        return nil;
    end
    local existingPin = FindMapPinAt(playerID, x, y, runCache);
    local occupiedByAutoPin = IsAutoMapPin(existingPin, autoRegistry);
    local occupiedByManualPin = existingPin ~= nil
        and not occupiedByAutoPin
        and AMT_PlotDirectives[key] == nil;
    local willClearExistingPin = ignoredKeys and ignoredKeys[key] or false;
    if (occupiedByManualPin and not willClearExistingPin)
        or (occupiedByAutoPin and not overwriteExisting and not clearFirst
            and not willClearExistingPin) then
        return nil;
    end
    if subjectType == MAP_PIN_TYPE_DISTRICT
        and IsDistrictAlreadyInCity(city, subjectKey) then
        return nil;
    end

    local item = {
        subjectType = subjectType,
        subjectKey = subjectKey,
        requestID = tostring(wonderItem.requestID or "WONDER")
            .. ":SUPPORT:" .. subjectType,
        districtPriority = subjectType == MAP_PIN_TYPE_DISTRICT and 1 or nil,
        isSpecialty = subjectType == MAP_PIN_TYPE_DISTRICT
            and IsPopulationDistrict(subjectKey) or false,
        specialtyOrder = subjectType == MAP_PIN_TYPE_DISTRICT and 99 or nil,
        baseDistrictType = subjectType == MAP_PIN_TYPE_DISTRICT
            and GetDistrictStrategyType(subjectKey) or nil,
        isUniqueDistrict = subjectType == MAP_PIN_TYPE_DISTRICT
            and IsUniqueDistrict(subjectKey) or false,
        iconName = GetSubjectIcon(subjectType, subjectKey),
        district = subjectType == MAP_PIN_TYPE_DISTRICT and subjectKey or nil,
        cityID = city:GetID(),
        cityName = Locale.Lookup(city:GetName()),
        x = x,
        y = y,
        plot = plot,
        isWonderSupport = true,
    };
    local visibleResource = ImprovementPlacement.GetVisibleResource(
        plot, playerID
    );
    item.hasVisibleResource = visibleResource ~= nil;
    item.resourceClass = visibleResource
        and visibleResource.ResourceClassType or nil;
    if not ImprovementPlacement.CanPlan(item, playerID) then return nil; end
    if not AMT_PlotDirectives[key] then
        local checkOK, canPlace = pcall(
            CanPlacePin, playerID, MakePinSubject(item)
        );
        if checkOK and not canPlace then return nil; end
    end
    item.placementLegal = true;
    return item;
end

local function FixedSubjectsContainDistrict(
    fixedSubjects, cityID, requiredDistrict
)
    local requiredStrategy = GetDistrictStrategyType(requiredDistrict);
    for _, subject in ipairs(fixedSubjects or {}) do
        local subjectType = subject.Type or subject.subjectType;
        local subjectKey = subject.Key or subject.subjectKey;
        local subjectCityID = subject.CityID or subject.cityID;
        if subjectType == MAP_PIN_TYPE_DISTRICT
            and subjectCityID == cityID
            and GetDistrictStrategyType(subjectKey) == requiredStrategy then
            return true;
        end
    end
    return false;
end

local function RequestIncludesDistrict(request, requiredDistrict)
    local requiredStrategy = GetDistrictStrategyType(requiredDistrict);
    for _, districtType in ipairs(request.selectedDistricts or {}) do
        if districtType == requiredDistrict
            or GetDistrictStrategyType(districtType) == requiredStrategy then
            return true;
        end
    end
    return false;
end

local function BuildWonderSupportBundles(
    wonderItem, playerID, fixedSubjects, reservedKeys, ignoredKeys,
    overwriteExisting, clearFirst, autoRegistry, runCache, request
)
    local missingDistrict, missingImprovement =
        GetMissingWonderSupports(
            wonderItem, { wonderItem }, fixedSubjects
        );
    if not missingDistrict and not missingImprovement then return {}; end
    local city = Players[playerID]
        and Players[playerID]:GetCities():FindID(wonderItem.cityID) or nil;
    if not city then return {}; end
    if missingDistrict then
        -- A manual/existing district tack is a fixed anchor. Never invent a
        -- second copy elsewhere; only wonder candidates adjacent to that tack
        -- may survive relational validation.
        if FixedSubjectsContainDistrict(
            fixedSubjects, wonderItem.cityID, missingDistrict
        ) then
            return {};
        end
        -- Selecting a wonder must not silently select its supporting district.
        -- Bundling is allowed only after the player selected that district too.
        if not RequestIncludesDistrict(request or {}, missingDistrict) then
            return {};
        end
    end

    local supportGroups = {};
    local function AddSupportGroup(subjectType, requiredType)
        if not requiredType then return; end
        local subjectKeys = {};
        for _, option in ipairs(m_PlannerOptions[subjectType] or {}) do
            if (subjectType == MAP_PIN_TYPE_DISTRICT
                    and (option.subjectKey == requiredType
                        or GetDistrictStrategyType(option.subjectKey)
                            == GetDistrictStrategyType(requiredType)))
                or (subjectType == MAP_PIN_TYPE_IMPROVEMENT
                    and option.subjectKey == requiredType) then
                table.insert(subjectKeys, option.subjectKey);
            end
        end
        local group = {};
        for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
            local plot = Map.GetAdjacentPlot(
                wonderItem.x, wonderItem.y, direction
            );
            for _, subjectKey in ipairs(subjectKeys) do
                local item = BuildWonderSupportItem(
                    wonderItem, subjectType, subjectKey, plot, city,
                    playerID, reservedKeys, ignoredKeys,
                    overwriteExisting, clearFirst, autoRegistry, runCache
                );
                if item then table.insert(group, item); end
            end
        end
        table.insert(supportGroups, group);
    end
    AddSupportGroup(MAP_PIN_TYPE_DISTRICT, missingDistrict);
    AddSupportGroup(MAP_PIN_TYPE_IMPROVEMENT, missingImprovement);
    for _, group in ipairs(supportGroups) do
        if #group == 0 then return {}; end
    end

    local bundles = { {} };
    for _, group in ipairs(supportGroups) do
        local expanded = {};
        for _, bundle in ipairs(bundles) do
            for _, supportItem in ipairs(group) do
                local conflict = false;
                for _, existing in ipairs(bundle) do
                    if existing.x == supportItem.x
                        and existing.y == supportItem.y then
                        conflict = true;
                    end
                end
                if not conflict then
                    local copy = CopyArray(bundle);
                    table.insert(copy, supportItem);
                    table.insert(expanded, copy);
                end
            end
        end
        bundles = expanded;
    end
    return bundles;
end

-- Candidate diagnostics remain available behind a development-only switch.
-- Public planning reports stay concise and avoid per-tile failure details.
local function GetWonderDiagnostic(request, subjectKey)
    if not ENABLE_WONDER_DEBUG then return nil; end
    if (request.subjectType or MAP_PIN_TYPE_DISTRICT)
        ~= MAP_PIN_TYPE_WONDER then
        return nil;
    end
    request.wonderDiagnostics = request.wonderDiagnostics or {};
    local diagnostic = request.wonderDiagnostics[subjectKey];
    if not diagnostic then
        diagnostic = {
            scanned = 0,
            eligible = 0,
            placementPassed = 0,
            quickPassed = 0,
            supportPairs = 0,
            evaluated = 0,
            dmtPassed = 0,
            accepted = 0,
            noSupportTiles = 0,
            failures = {},
            firstByStage = {},
        };
        request.wonderDiagnostics[subjectKey] = diagnostic;
    end
    return diagnostic;
end

local function NormalizeDiagnosticDetail(detail)
    local text = tostring(detail or "");
    text = string.gsub(text, "%[NEWLINE%]", " / ");
    text = string.gsub(text, "[\r\n]+", " / ");
    if #text > 180 then text = string.sub(text, 1, 177) .. "..."; end
    return text;
end

local function RecordWonderFailure(diagnostic, stage, item, detail)
    if not diagnostic then return; end
    stage = stage or "UNKNOWN_REJECT";
    diagnostic.failures[stage] = (diagnostic.failures[stage] or 0) + 1;
    if not diagnostic.firstByStage[stage] then
        diagnostic.firstByStage[stage] = {
            stage = stage,
            subjectType = item and item.subjectType or nil,
            subjectKey = item and item.subjectKey or nil,
            x = item and item.x or nil,
            y = item and item.y or nil,
            detail = NormalizeDiagnosticDetail(detail),
        };
    end
end

local function RecordWonderEvaluation(diagnostic, items, score, failure)
    if not diagnostic then return; end
    diagnostic.evaluated = diagnostic.evaluated + 1;
    if score and score > -math.huge then
        diagnostic.dmtPassed = diagnostic.dmtPassed + 1;
        diagnostic.accepted = diagnostic.accepted + 1;
        return;
    end
    local stage = failure and failure.stage or "UNKNOWN_REJECT";
    if stage == "RELATION_REJECT" then
        diagnostic.dmtPassed = diagnostic.dmtPassed + 1;
    end
    local failedItem = failure;
    if not failedItem or failedItem.x == nil then
        failedItem = items and items[#items] or nil;
    end
    RecordWonderFailure(
        diagnostic, stage, failedItem, failure and failure.detail
    );
end

local function BuildRawCandidates(
    request, playerID, weights, ignoredKeys, reservedKeys,
    overwriteExisting, clearFirst, fixedSubjects, autoRegistry, runCache
)
    local candidates = {};
    local seen = {};

    local subjectType = request.subjectType or MAP_PIN_TYPE_DISTRICT;
    local subjectOptions = request.subjectOptions
        or request.districtOptions
        or { request.subjectKey or request.district };
    if subjectType == MAP_PIN_TYPE_WONDER then
        request.wonderDiagnostics = ENABLE_WONDER_DEBUG and {} or nil;
    end
    for _, subjectKey in ipairs(subjectOptions) do
        local wonderDiagnostic = GetWonderDiagnostic(request, subjectKey);
        local subjectRow = GetSubjectRow(subjectType, subjectKey);
        for _, city in ipairs(request.cities) do
            local cityOwnedKeys = GetCityOwnedPlotKeys(city, runCache);
            local plots = GetCityRangePlots(city, runCache);
            for plotIndex, plot in ipairs(plots) do
                if wonderDiagnostic then
                    wonderDiagnostic.scanned = wonderDiagnostic.scanned + 1;
                end
                if plotIndex % 12 == 0 then
                    AMT_YieldPlanning(
                        "LOC_AMT_CALCULATION_SCAN",
                        plotIndex, #plots
                    );
                end
                local x, y = plot:GetX(), plot:GetY();
                local key = Key(x, y);
                local candidateKey =
                    subjectType .. ":" .. subjectKey .. "@" .. key;
                local ownedByAnotherPlayer = plot:IsOwned() and plot:GetOwner() ~= playerID;
                local ownedByAnotherCity = plot:IsOwned()
                    and plot:GetOwner() == playerID
                    and not cityOwnedKeys[key];
                local unavailableInCurrentMode =
                    m_PlanningHorizon == "CURRENT"
                    and not cityOwnedKeys[key];
                local existingPin = FindMapPinAt(playerID, x, y, runCache);
                local occupiedByAutoPin = IsAutoMapPin(existingPin, autoRegistry);
                local occupiedByManualPin = existingPin ~= nil
                    and not occupiedByAutoPin
                    and AMT_PlotDirectives[key] == nil;
                local willClearExistingPin = ignoredKeys and ignoredKeys[key] or false;
                local validForAssignedCity =
                    subjectType ~= MAP_PIN_TYPE_DISTRICT
                    or not subjectRow
                    or not subjectRow.Aqueduct
                    or Map.GetPlotDistance(city:GetX(), city:GetY(), x, y) == 1;

                if not seen[candidateKey]
                    and IsPlotRevealedToPlayer(plot, playerID)
                    and not reservedKeys[key]
                    and not ownedByAnotherPlayer
                    and not ownedByAnotherCity
                    and not unavailableInCurrentMode
                    and validForAssignedCity
                    and (not occupiedByManualPin or willClearExistingPin)
                    and (not occupiedByAutoPin
                        or overwriteExisting or clearFirst
                        or willClearExistingPin) then
                    if wonderDiagnostic then
                        wonderDiagnostic.eligible = wonderDiagnostic.eligible + 1;
                    end
                    seen[candidateKey] = true;
                    local item = {
                        subjectType = subjectType,
                        subjectKey = subjectKey,
                        requestID = request.requestID,
                        districtPriority = subjectType == MAP_PIN_TYPE_DISTRICT
                            and ((request.subjectPriorities
                                and request.subjectPriorities[subjectKey]) or 1)
                            or nil,
                        isSpecialty = subjectType == MAP_PIN_TYPE_DISTRICT
                            and IsPopulationDistrict(subjectKey) or false,
                        specialtyOrder = subjectType == MAP_PIN_TYPE_DISTRICT
                            and (((request.subjectOrdersByCity
                                    and request.subjectOrdersByCity[city:GetID()]
                                    and request.subjectOrdersByCity[city:GetID()]
                                        [subjectKey])
                                or (request.subjectOrders
                                    and request.subjectOrders[subjectKey]))
                                or GetSpecialtyOrderIndex(subjectKey))
                            or nil,
                        baseDistrictType = subjectType == MAP_PIN_TYPE_DISTRICT
                            and GetDistrictStrategyType(subjectKey) or nil,
                        isUniqueDistrict = subjectType == MAP_PIN_TYPE_DISTRICT
                            and IsUniqueDistrict(subjectKey) or false,
                        iconName = GetSubjectIcon(subjectType, subjectKey),
                        district = subjectType == MAP_PIN_TYPE_DISTRICT
                            and subjectKey or nil,
                        cityID = city:GetID(),
                        cityName = Locale.Lookup(city:GetName()),
                        x = x,
                        y = y,
                        plot = plot,
                    };
                    local visibleResource =
                        ImprovementPlacement.GetVisibleResource(
                            plot, playerID
                        );
                    item.hasVisibleResource = visibleResource ~= nil;
                    item.resourceClass = visibleResource
                        and visibleResource.ResourceClassType or nil;
                    local placementKey = subjectType .. ":"
                        .. subjectKey .. "@" .. key;
                    local passesPlacementRules = nil;
                    if runCache then
                        passesPlacementRules =
                            runCache.placementRules[placementKey];
                    end
                    if passesPlacementRules == nil then
                        passesPlacementRules =
                            ImprovementPlacement.CanPlan(item, playerID);
                        if runCache then
                            runCache.placementRules[placementKey] =
                                passesPlacementRules;
                        end
                    end
                    local passesQuickPinCheck = true;
                    local hasDeferredWonderRequirement = false;
                    if passesPlacementRules and not existingPin then
                        local cachedQuick = runCache
                            and runCache.quickPinChecks[placementKey] or nil;
                        if cachedQuick ~= nil
                            and subjectType ~= MAP_PIN_TYPE_WONDER then
                            passesQuickPinCheck = cachedQuick;
                        else
                            if subjectType == MAP_PIN_TYPE_WONDER
                                and AMT_WonderPlanner
                                and AMT_WonderPlanner.CanUseRawCandidate then
                                passesQuickPinCheck,
                                    hasDeferredWonderRequirement =
                                    AMT_WonderPlanner.CanUseRawCandidate(
                                        playerID, item
                                    );
                            else
                                local checkOK, canPlace = pcall(
                                    CanPlacePin, playerID,
                                    MakePinSubject(item)
                                );
                                if checkOK then
                                    passesQuickPinCheck = canPlace;
                                end
                            end
                            if subjectType == MAP_PIN_TYPE_WONDER then
                                -- DMT deliberately reports a wonder as illegal
                                -- until its adjacent support tack exists.  Read
                                -- the database fields here, outside the optional
                                -- helper module, and retain the tile for exact
                                -- projected-pair validation below.
                                local wonderRow = GameInfo.Buildings
                                    and GameInfo.Buildings[subjectKey] or nil;
                                local requiredDistrict = wonderRow
                                    and wonderRow.AdjacentDistrict or nil;
                                local requiredImprovement = wonderRow
                                    and wonderRow.AdjacentImprovement or nil;
                                if requiredDistrict or requiredImprovement then
                                    hasDeferredWonderRequirement = true;
                                    -- A relational wonder is not meaningful in
                                    -- isolation.  Retain every locally usable
                                    -- tile here and let the complete DMT overlay
                                    -- below decide whether an existing/manual
                                    -- support or a generated support makes the
                                    -- exact layout legal.
                                    passesQuickPinCheck = true;
                                end
                            end
                            if runCache then
                                runCache.quickPinChecks[placementKey] =
                                    passesQuickPinCheck;
                            end
                        end
                    end
                    if passesPlacementRules and passesQuickPinCheck then
                        if wonderDiagnostic then
                            wonderDiagnostic.placementPassed =
                                wonderDiagnostic.placementPassed + 1;
                            wonderDiagnostic.quickPassed =
                                wonderDiagnostic.quickPassed + 1;
                        end
                        item.placementLegal = true;
                        item.hasDeferredWonderRequirement =
                            hasDeferredWonderRequirement;
                        if hasDeferredWonderRequirement then
                            local fixedMissingDistrict,
                                fixedMissingImprovement =
                                GetMissingWonderSupports(
                                    item, { item }, fixedSubjects
                                );
                            -- First ask DMT whether fixed/real/manual subjects
                            -- already complete this wonder.  This replaces the
                            -- former approximate pre-check and makes a manual
                            -- support tack follow exactly the same path as an
                            -- automatically projected one.
                            if wonderDiagnostic then
                                wonderDiagnostic.supportPairs =
                                    wonderDiagnostic.supportPairs + 1;
                            end
                            local directScore, directYields, directFailure =
                                EvaluatePlan(
                                    playerID, { item }, weights, ignoredKeys,
                                    fixedSubjects, runCache
                                );
                            RecordWonderEvaluation(
                                wonderDiagnostic, { item }, directScore,
                                directFailure
                            );
                            item.hasFixedWonderSupport =
                                directScore > -math.huge;
                            if item.hasFixedWonderSupport then
                                item.baseScore = directScore;
                                item.analysisYields = directYields
                                    and directYields[1] or {};
                                item.linkCount = 0;
                                table.insert(candidates, item);
                            end

                            local supportBundles = {};
                            if not item.hasFixedWonderSupport then
                                supportBundles = BuildWonderSupportBundles(
                                    item, playerID, fixedSubjects,
                                    reservedKeys, ignoredKeys,
                                    overwriteExisting, clearFirst,
                                    autoRegistry, runCache, request
                                );
                            end
                            if not item.hasFixedWonderSupport
                                and #supportBundles == 0 then
                                if wonderDiagnostic then
                                    wonderDiagnostic.noSupportTiles =
                                        wonderDiagnostic.noSupportTiles + 1;
                                end
                                RecordWonderFailure(
                                    wonderDiagnostic, "NO_SUPPORT_PAIR", item,
                                    fixedMissingDistrict
                                        or fixedMissingImprovement
                                );
                            end
                            if wonderDiagnostic then
                                wonderDiagnostic.supportPairs =
                                    wonderDiagnostic.supportPairs
                                        + #supportBundles;
                            end
                            for _, bundle in ipairs(supportBundles) do
                                local variant = {};
                                for field, value in pairs(item) do
                                    variant[field] = value;
                                end
                                variant.supportItems = bundle;
                                local projectedItems = CopyArray(bundle);
                                table.insert(projectedItems, variant);
                                local bundleScore, bundleYields,
                                    bundleFailure = EvaluatePlan(
                                    playerID, projectedItems, weights,
                                    ignoredKeys, fixedSubjects, runCache
                                );
                                RecordWonderEvaluation(
                                    wonderDiagnostic, projectedItems,
                                    bundleScore, bundleFailure
                                );
                                if bundleScore > -math.huge then
                                    variant.baseScore = bundleScore;
                                    variant.analysisYields = bundleYields
                                        and bundleYields[#projectedItems] or {};
                                    variant.linkCount = 0;
                                    variant.hasValidatedWonderSupport = true;
                                    table.insert(candidates, variant);
                                end
                            end
                        else
                            if wonderDiagnostic then
                                wonderDiagnostic.supportPairs =
                                    wonderDiagnostic.supportPairs + 1;
                            end
                            local score, candidateYields,
                                candidateFailure = EvaluatePlan(
                                playerID, { item }, weights, ignoredKeys,
                                fixedSubjects, runCache
                            );
                            RecordWonderEvaluation(
                                wonderDiagnostic, { item }, score,
                                candidateFailure
                            );
                            if score > -math.huge then
                                item.baseScore = score;
                                item.analysisYields = candidateYields
                                    and candidateYields[1] or {};
                                item.linkCount = 0;
                                table.insert(candidates, item);
                            end
                        end
                    elseif wonderDiagnostic then
                        if not passesPlacementRules then
                            RecordWonderFailure(
                                wonderDiagnostic, "LOCAL_PLACEMENT_REJECT",
                                item, nil
                            );
                        else
                            wonderDiagnostic.placementPassed =
                                wonderDiagnostic.placementPassed + 1;
                            RecordWonderFailure(
                                wonderDiagnostic, "QUICK_REJECT", item, nil
                            );
                        end
                    end
                end
            end
        end
    end
    return candidates;
end

-- High-adjacency analysis deliberately uses a different objective from the
-- full planner.  It measures the selected district's own adjacency output,
-- without tile-yield opportunity cost, reverse benefits to neighbours, or
-- the normal multi-item layout weights.
function AMT_GetDistrictAnalysisScore(item, yields)
    local focusYield = GetDistrictYieldFocus(
        item.baseDistrictType or item.subjectKey
    );
    if focusYield then
        return tonumber(yields and yields[focusYield]) or 0;
    end
    local total = 0;
    for _, yieldType in ipairs(YIELD_LIST) do
        total = total + math.max(
            0, tonumber(yields and yields[yieldType]) or 0
        );
    end
    return total;
end

function AMT_GetDistrictAnalysisTieScore(yields)
    local total = 0;
    for _, yieldType in ipairs(YIELD_LIST) do
        total = total + math.max(
            0, tonumber(yields and yields[yieldType]) or 0
        ) * (DEFAULT_WEIGHTS[yieldType] or 1);
    end
    return total;
end

function AMT_EvaluateDistrictWithSupport(
    playerID, target, supportItems, weights, ignoredKeys, fixedSubjects,
    runCache
)
    local items = { target };
    for _, item in ipairs(supportItems or {}) do
        table.insert(items, item);
    end
    local score, yieldsByItem = EvaluatePlan(
        playerID, items, weights, ignoredKeys, fixedSubjects, runCache
    );
    if score <= -math.huge or not yieldsByItem then return nil; end
    return CopyYields(yieldsByItem[1] or {});
end

function AMT_MakeAnalysisImprovementItem(option, plot, city)
    return {
        subjectType = MAP_PIN_TYPE_IMPROVEMENT,
        subjectKey = option.subjectKey,
        requestID = "ANALYSIS_SUPPORT_" .. option.subjectKey,
        iconName = option.iconName
            or GetSubjectIcon(MAP_PIN_TYPE_IMPROVEMENT, option.subjectKey),
        cityID = city:GetID(),
        cityName = Locale.Lookup(city:GetName()),
        x = plot:GetX(),
        y = plot:GetY(),
        plot = plot,
    };
end

-- Try only legal adjacent improvements, and keep one on a plot only when the
-- simulated Detailed Map Tacks result increases this district's own focused
-- adjacency.  This automatically supports civilization-unique and modded
-- improvement adjacency rules without hard-coding their names.
function AMT_FindDirectDistrictSupport(
    playerID, city, target, baseYields, weights, ignoredKeys, fixedSubjects,
    runCache
)
    local cityOwnedKeys = GetCityOwnedPlotKeys(city, runCache);
    local occupied = { [Key(target.x, target.y)] = true };
    for _, subject in ipairs(fixedSubjects or {}) do
        occupied[Key(subject.X, subject.Y)] = true;
    end

    local selected = {};
    local currentYields = CopyYields(baseYields or {});
    local currentScore = AMT_GetDistrictAnalysisScore(
        target, currentYields
    );
    for _, plot in ipairs(GetAdjacentPlots(target.x, target.y)) do
        local plotKey = Key(plot:GetX(), plot:GetY());
        if cityOwnedKeys[plotKey]
            and IsPlotRevealedToPlayer(plot, playerID)
            and not occupied[plotKey]
            and not FindMapPinAt(
                playerID, plot:GetX(), plot:GetY(), runCache
            ) then
            local bestItem = nil;
            local bestYields = nil;
            local bestScore = currentScore;
            local bestTieScore = -math.huge;
            for _, option in ipairs(
                m_PlannerOptions[MAP_PIN_TYPE_IMPROVEMENT] or {}
            ) do
                local support = AMT_MakeAnalysisImprovementItem(
                    option, plot, city
                );
                local placementKey = MAP_PIN_TYPE_IMPROVEMENT .. ":"
                    .. option.subjectKey .. "@" .. plotKey;
                local placementLegal = runCache
                    and runCache.placementRules[placementKey] or nil;
                if placementLegal == nil then
                    placementLegal =
                        ImprovementPlacement.CanPlan(support, playerID);
                    if runCache then
                        runCache.placementRules[placementKey] =
                            placementLegal;
                    end
                end
                if placementLegal then
                    support.placementLegal = true;
                    local trial = {};
                    for _, chosen in ipairs(selected) do
                        table.insert(trial, chosen);
                    end
                    table.insert(trial, support);
                    local yields = AMT_EvaluateDistrictWithSupport(
                        playerID, target, trial, weights,
                        ignoredKeys, fixedSubjects, runCache
                    );
                    local score = yields
                        and AMT_GetDistrictAnalysisScore(target, yields)
                        or -math.huge;
                    local tieScore = yields
                        and AMT_GetDistrictAnalysisTieScore(yields)
                        or -math.huge;
                    if score > bestScore + MIN_AUTOMATIC_GAIN
                        or (math.abs(score - bestScore)
                                <= MIN_AUTOMATIC_GAIN
                            and score > currentScore
                            and tieScore > bestTieScore) then
                        bestItem = support;
                        bestYields = yields;
                        bestScore = score;
                        bestTieScore = tieScore;
                    end
                end
            end
            if bestItem then
                table.insert(selected, bestItem);
                occupied[plotKey] = true;
                currentYields = bestYields;
                currentScore = bestScore;
            end
        end
    end
    return selected, currentYields;
end

function AMT_GetSupportSummary(items)
    if not items or #items == 0 then
        return Locale.Lookup("LOC_AMT_HIGH_ADJACENCY_NO_SUPPORT");
    end
    local names = {};
    for _, item in ipairs(items) do
        table.insert(names, GetSubjectDisplay(
            MAP_PIN_TYPE_IMPROVEMENT, item.subjectKey
        ));
    end
    return Locale.Lookup(
        "LOC_AMT_HIGH_ADJACENCY_SUPPORT", table.concat(names, ", ")
    );
end

local function BuildCandidateShortlists(
    requests, playerID, weights, ignoredKeys, reservedKeys,
    overwriteExisting, clearFirst, fixedSubjects, autoRegistry, runCache
)
    local feasibleRequests = {};
    local skippedRequests = {};
    for _, request in ipairs(requests) do
        request.rawCandidates = BuildRawCandidates(
            request, playerID, weights, ignoredKeys, reservedKeys,
            overwriteExisting, clearFirst, fixedSubjects, autoRegistry,
            runCache
        );
        local candidateSubjects = {};
        for _, candidate in ipairs(request.rawCandidates) do
            candidateSubjects[candidate.subjectKey] = true;
        end
        local feasibleOptions = {};
        local hadDeclaredOptions = #(request.subjectOptions or {}) > 0;
        for _, subjectKey in ipairs(request.subjectOptions or {}) do
            if candidateSubjects[subjectKey] then
                table.insert(feasibleOptions, subjectKey);
            else
                local skipped = CloneRequestForSubject(request, subjectKey);
                skipped.skipReason = "NO_LEGAL_TILE";
                table.insert(skippedRequests, skipped);
                Log("Pre-search prune: no legal tile for "
                    .. GetSubjectDisplay(request.subjectType, subjectKey));
            end
        end
        if hadDeclaredOptions then
            request.subjectOptions = feasibleOptions;
            request.subjectKey = feasibleOptions[1] or request.subjectKey;
            if request.subjectType == MAP_PIN_TYPE_DISTRICT then
                request.districtOptions =
                    #feasibleOptions > 1 and feasibleOptions or nil;
                request.district = feasibleOptions[1] or request.district;
            end
        end
        if #request.rawCandidates > 0 then
            table.insert(feasibleRequests, request);
        else
            Log("No legal candidates for " .. GetRequestDistrictDisplay(request));
            if not hadDeclaredOptions
                and not candidateSubjects[request.subjectKey] then
                request.skipReason = "NO_LEGAL_TILE";
                table.insert(skippedRequests, request);
            end
        end
    end

    local requestIndexesByPlot = {};
    for requestIndex, request in ipairs(feasibleRequests) do
        for _, candidate in ipairs(request.rawCandidates) do
            local plotKey = Key(candidate.x, candidate.y);
            requestIndexesByPlot[plotKey] =
                requestIndexesByPlot[plotKey] or {};
            requestIndexesByPlot[plotKey][requestIndex] = true;
        end
    end

    for requestIndex, request in ipairs(feasibleRequests) do
        for candidateIndex, candidate in ipairs(request.rawCandidates) do
            local linkedRequests = 0;
            if not request.isAutoQuantity then
                local linkedIndexes = {};
                for _, adjacentPlot in ipairs(
                    GetPlotsWithinXTiles(candidate.x, candidate.y, 1)
                ) do
                    if Map.GetPlotDistance(
                        candidate.x, candidate.y,
                        adjacentPlot:GetX(), adjacentPlot:GetY()
                    ) == 1 then
                        local indexes = requestIndexesByPlot[
                            Key(adjacentPlot:GetX(), adjacentPlot:GetY())
                        ];
                        for otherIndex in pairs(indexes or {}) do
                            if otherIndex ~= requestIndex then
                                linkedIndexes[otherIndex] = true;
                            end
                        end
                    end
                end
                for _ in pairs(linkedIndexes) do
                    linkedRequests = linkedRequests + 1;
                end
            end
            candidate.linkCount = linkedRequests;
            candidate.rankScore = candidate.baseScore
                + linkedRequests * 0.5
                + (candidate.hasFixedWonderSupport and 1000 or 0)
                + (candidate.hasValidatedWonderSupport and 1000 or 0)
                + (candidate.resourceClass == "RESOURCECLASS_STRATEGIC"
                    and 12
                    or (candidate.resourceClass == "RESOURCECLASS_LUXURY"
                        and 4 or 0));
            if candidateIndex % 24 == 0 then
                AMT_YieldPlanning(
                    "LOC_AMT_CALCULATION_CANDIDATES",
                    requestIndex, #feasibleRequests
                );
            end
        end

        table.sort(request.rawCandidates, function(a, b)
            if a.rankScore ~= b.rankScore then return a.rankScore > b.rankScore; end
            if a.baseScore ~= b.baseScore then return a.baseScore > b.baseScore; end
            return Key(a.x, a.y) < Key(b.x, b.y);
        end);

        request.candidates = {};
        if request.isAutoQuantity then
            -- Quantity is derived from the complete legal candidate set.
            -- Do not apply the normal per-request shortlist here: that would
            -- silently prevent later placements and make the preview partial.
            for _, candidate in ipairs(request.rawCandidates) do
                table.insert(request.candidates, candidate);
            end
        else
            local chosen = {};
            local bestBySubject = {};
            for _, candidate in ipairs(request.rawCandidates) do
                local diversityKey = candidate.subjectKey
                    .. (candidate.supportItems and ":SUPPORT" or ":DIRECT");
                if not bestBySubject[diversityKey] then
                    bestBySubject[diversityKey] = candidate;
                end
            end
            local diverse = {};
            for _, candidate in pairs(bestBySubject) do
                table.insert(diverse, candidate);
            end
            table.sort(diverse, function(a, b)
                if a.rankScore ~= b.rankScore then
                    return a.rankScore > b.rankScore;
                end
                return a.subjectKey < b.subjectKey;
            end);
            local shortlistLimit = request.subjectType
                == MAP_PIN_TYPE_WONDER
                and MAX_CANDIDATES_PER_REQUEST * 2
                or MAX_CANDIDATES_PER_REQUEST;
            local diverseLimit = math.min(
                #diverse, math.max(2, math.floor(shortlistLimit / 2))
            );
            for i = 1, diverseLimit do
                local candidate = diverse[i];
                table.insert(request.candidates, candidate);
                chosen[candidate] = true;
            end
            for i = 1, #request.rawCandidates do
                local candidate = request.rawCandidates[i];
                if not chosen[candidate]
                    and #request.candidates < shortlistLimit then
                    table.insert(request.candidates, candidate);
                    chosen[candidate] = true;
                end
                if #request.candidates >= shortlistLimit then break; end
            end
        end
        Log(string.format(
            "Candidates %s city=%s raw=%d shortlist=%d",
            GetRequestDistrictDisplay(request),
            request.cityName or "linked",
            #request.rawCandidates,
            #request.candidates
        ));
    end

    local function GetRequestPriority(request)
        local priority = 0;
        for _, value in pairs(request.subjectPriorities or {}) do
            priority = math.max(priority, tonumber(value) or 1);
        end
        return priority;
    end
    table.sort(feasibleRequests, function(a, b)
        local wonderA = a.subjectType == MAP_PIN_TYPE_WONDER;
        local wonderB = b.subjectType == MAP_PIN_TYPE_WONDER;
        -- Wonders are never selected automatically, but once the player has
        -- selected one its required support bundle must be established before
        -- ordinary district requests compete for the same one-per-city slot.
        if wonderA ~= wonderB then return wonderA; end
        if a.isOptional ~= b.isOptional then return not a.isOptional; end
        local priorityA = GetRequestPriority(a);
        local priorityB = GetRequestPriority(b);
        if priorityA ~= priorityB then return priorityA > priorityB; end
        if #a.candidates ~= #b.candidates then
            return #a.candidates < #b.candidates;
        end
        return (a.subjectKey or a.district) < (b.subjectKey or b.district);
    end);

    local expandedRequests = {};
    for _, request in ipairs(feasibleRequests) do
        if request.isAutoQuantity then
            local uniquePlots = {};
            local visibleResourcePlots = {};
            local maximumQuantity = 0;
            for _, candidate in ipairs(request.rawCandidates) do
                local plotKey = Key(candidate.x, candidate.y);
                if not uniquePlots[plotKey] then
                    uniquePlots[plotKey] = true;
                    maximumQuantity = maximumQuantity + 1;
                end
                if candidate.hasVisibleResource then
                    visibleResourcePlots[plotKey] = true;
                end
            end
            local visibleResourceCount = 0;
            for _ in pairs(visibleResourcePlots) do
                visibleResourceCount = visibleResourceCount + 1;
            end
            local populationBudget =
                tonumber(request.improvementBudget) or maximumQuantity;
            maximumQuantity = math.min(
                maximumQuantity,
                math.max(populationBudget, visibleResourceCount)
            );
            Log(string.format(
                "Automatic quantity pool %s uses %d of %d legal plot(s), population budget=%d, visible resources=%d, candidates=%d",
                GetRequestDistrictDisplay(request),
                maximumQuantity,
                (function()
                    local count = 0;
                    for _ in pairs(uniquePlots) do count = count + 1; end
                    return count;
                end)(),
                populationBudget,
                visibleResourceCount,
                #request.candidates
            ));
            if maximumQuantity == 0 then
                for _, subjectKey in ipairs(
                    request.subjectOptions or { request.subjectKey }
                ) do
                    local skipped =
                        CloneRequestForSubject(request, subjectKey);
                    skipped.skipReason = "IMPROVEMENT_BUDGET";
                    table.insert(skippedRequests, skipped);
                end
            end
            for quantityIndex = 1, maximumQuantity do
                local copy = {};
                for key, value in pairs(request) do copy[key] = value; end
                copy.autoQuantityIndex = quantityIndex;
                table.insert(expandedRequests, copy);
            end
        else
            table.insert(expandedRequests, request);
        end
    end
    return expandedRequests, skippedRequests;
end

function GetStateSignature(items)
    local parts = {};
    for _, item in ipairs(items) do
        table.insert(parts, (item.subjectType or MAP_PIN_TYPE_DISTRICT)
            .. ":" .. (item.subjectKey or item.district)
            .. "@" .. Key(item.x, item.y));
    end
    table.sort(parts);
    return table.concat(parts, "|");
end

function CanAddCandidateToState(
    items, candidate, fixedSubjects, specialtyCounts, citySpecialtyBudgets
)
    if candidate.isSpecialty then
        local budget = citySpecialtyBudgets
            and citySpecialtyBudgets[candidate.cityID] or nil;
        local plannedCount = specialtyCounts
            and (specialtyCounts[candidate.cityID] or 0) or 0;
        if budget and plannedCount >= budget.available then
            return false;
        end
    end
    local candidateImprovement = candidate.subjectType == MAP_PIN_TYPE_IMPROVEMENT
        and GameInfo.Improvements[candidate.subjectKey] or nil;
    local onePerCity = candidateImprovement
        and (candidateImprovement.OnePerCity == true
            or candidateImprovement.OnePerCity == 1);
    local sameAdjacentValid = not candidateImprovement
        or candidateImprovement.SameAdjacentValid == nil
        or candidateImprovement.SameAdjacentValid == true
        or candidateImprovement.SameAdjacentValid == 1;

    if candidate.subjectType == MAP_PIN_TYPE_DISTRICT
        and IsEconomicTradeDistrict(candidate.subjectKey) then
        for _, subject in ipairs(fixedSubjects or {}) do
            if subject.Type == MAP_PIN_TYPE_DISTRICT
                and subject.CityID == candidate.cityID
                and AreEconomicTradeAlternatives(
                    subject.Key, candidate.subjectKey
                ) then
                return false;
            end
        end
    end

    if candidateImprovement then
        for _, subject in ipairs(fixedSubjects or {}) do
            if IsTrue(candidateImprovement.NoAdjacentSpecialtyDistrict)
                and subject.Type == MAP_PIN_TYPE_DISTRICT
                and IsPopulationDistrict(subject.Key)
                and Map.GetPlotDistance(
                    subject.X, subject.Y, candidate.x, candidate.y
                ) == 1 then
                return false;
            end
            if subject.Type == MAP_PIN_TYPE_IMPROVEMENT
                and subject.Key == candidate.subjectKey then
                if onePerCity and subject.CityID == candidate.cityID then
                    return false;
                end
                if not sameAdjacentValid
                    and Map.GetPlotDistance(
                        subject.X, subject.Y, candidate.x, candidate.y
                    ) == 1 then
                    return false;
                end
            end
        end
    elseif candidate.isSpecialty then
        for _, subject in ipairs(fixedSubjects or {}) do
            local fixedImprovement =
                subject.Type == MAP_PIN_TYPE_IMPROVEMENT
                and GameInfo.Improvements[subject.Key] or nil;
            if fixedImprovement
                and IsTrue(
                    fixedImprovement.NoAdjacentSpecialtyDistrict
                )
                and Map.GetPlotDistance(
                    subject.X, subject.Y, candidate.x, candidate.y
                ) == 1 then
                return false;
            end
        end
    end

    for _, item in ipairs(items) do
        if candidateImprovement
            and IsTrue(candidateImprovement.NoAdjacentSpecialtyDistrict)
            and item.isSpecialty
            and Map.GetPlotDistance(
                item.x, item.y, candidate.x, candidate.y
            ) == 1 then
            return false;
        end
        if candidate.isSpecialty
            and item.subjectType == MAP_PIN_TYPE_IMPROVEMENT then
            local plannedImprovement =
                GameInfo.Improvements[item.subjectKey];
            if plannedImprovement
                and IsTrue(
                    plannedImprovement.NoAdjacentSpecialtyDistrict
                )
                and Map.GetPlotDistance(
                    item.x, item.y, candidate.x, candidate.y
                ) == 1 then
                return false;
            end
        end
        if candidate.subjectType == MAP_PIN_TYPE_DISTRICT
            and item.subjectType == MAP_PIN_TYPE_DISTRICT
            and item.cityID == candidate.cityID then
            if AreEconomicTradeAlternatives(
                item.subjectKey, candidate.subjectKey
            ) then
                return false;
            end
            if item.subjectKey == candidate.subjectKey
                and IsDistrictOnePerCity(candidate.subjectKey) then
                return false;
            end
            if AreDistrictsMutuallyExclusive(
                item.subjectKey, candidate.subjectKey
            ) then
                return false;
            end
        end
        if candidate.subjectType == MAP_PIN_TYPE_WONDER
            and item.subjectType == MAP_PIN_TYPE_WONDER
            and item.subjectKey == candidate.subjectKey then
            return false;
        end
        if candidate.subjectType == MAP_PIN_TYPE_IMPROVEMENT
            and item.subjectType == MAP_PIN_TYPE_IMPROVEMENT
            and item.subjectKey == candidate.subjectKey then
            if candidateImprovement then
                if onePerCity
                    and item.cityID == candidate.cityID then
                    return false;
                end
                if not sameAdjacentValid
                    and Map.GetPlotDistance(
                        item.x, item.y, candidate.x, candidate.y
                    ) == 1 then
                    return false;
                end
            end
        end
    end
    return true;
end

local function GetCandidateAdditions(
    state, candidate, fixedSubjects, citySpecialtyBudgets
)
    local proposedAdditions = {};
    for _, supportItem in ipairs(candidate.supportItems or {}) do
        table.insert(proposedAdditions, supportItem);
    end
    table.insert(proposedAdditions, candidate);
    local additions = {};
    local workingItems = CopyArray(state.items);
    local workingOccupied = CopySet(state.occupied);
    local workingSpecialtyCounts = CopySet(state.specialtyCounts or {});
    local function CanReuseWonderSupport(addition)
        if not addition.isWonderSupport then return false; end
        for _, item in ipairs(workingItems) do
            if item.x == addition.x
                and item.y == addition.y
                and item.cityID == addition.cityID
                and item.subjectType == addition.subjectType
                and item.subjectKey == addition.subjectKey then
                return true;
            end
        end
        return false;
    end
    for _, addition in ipairs(proposedAdditions) do
        local key = Key(addition.x, addition.y);
        if workingOccupied[key] then
            -- Multiple selected wonders may legally rely on the same adjacent
            -- district or improvement.  Reuse the identical support already in
            -- the state instead of rejecting the later wonder as an occupied
            -- tile or a duplicate one-per-city district.
            if not CanReuseWonderSupport(addition) then return nil; end
        elseif not CanAddCandidateToState(
                workingItems, addition, fixedSubjects,
                workingSpecialtyCounts, citySpecialtyBudgets
            ) then
            return nil;
        else
            table.insert(additions, addition);
            workingOccupied[key] = true;
            table.insert(workingItems, addition);
            if addition.isSpecialty then
                workingSpecialtyCounts[addition.cityID] =
                    (workingSpecialtyCounts[addition.cityID] or 0) + 1;
            end
        end
    end
    return additions;
end

local function WonderSupportCoversDistrictRequest(state, request)
    if not state or request.subjectType ~= MAP_PIN_TYPE_DISTRICT
        or request.isAutoQuantity then
        return false;
    end
    local accepted = {};
    for _, subjectKey in ipairs(
        request.subjectOptions
            or request.districtOptions
            or { request.subjectKey or request.district }
    ) do
        accepted[subjectKey] = true;
    end
    for _, item in ipairs(state.items or {}) do
        if item.isWonderSupport
            and item.subjectType == MAP_PIN_TYPE_DISTRICT
            and (request.cityID == nil or item.cityID == request.cityID) then
            if accepted[item.subjectKey] then return true; end
            local itemBase = GetDistrictStrategyType(item.subjectKey);
            for subjectKey in pairs(accepted) do
                if GetDistrictStrategyType(subjectKey) == itemBase then
                    return true;
                end
            end
        end
    end
    return false;
end

function SearchBestPlan(
    requests, playerID, weights, ignoredKeys, fixedSubjects,
    citySpecialtyBudgets, runCache
)
    local function StateUtility(state)
        return state.score
            - #state.items * MIN_AUTOMATIC_GAIN;
    end
    local function IsBetterState(a, b)
        for priority = 99, 1, -1 do
            local countA = (a.priorityCounts and a.priorityCounts[priority]) or 0;
            local countB = (b.priorityCounts and b.priorityCounts[priority]) or 0;
            if countA ~= countB then return countA > countB; end
        end
        -- Once the population-limited district layout is protected, developing
        -- every feasible revealed strategic resource outranks ordinary local
        -- improvement yield.  Hidden resources never reach candidate metadata,
        -- so this does not reveal future strategic deposits.
        local strategicA = tonumber(a.strategicResourceCount) or 0;
        local strategicB = tonumber(b.strategicResourceCount) or 0;
        if strategicA ~= strategicB then return strategicA > strategicB; end
        local utilityA = StateUtility(a);
        local utilityB = StateUtility(b);
        if utilityA ~= utilityB then return utilityA > utilityB; end
        if a.score ~= b.score then return a.score > b.score; end
        return #a.items < #b.items;
    end

    local baselineScore, baselineYields = EvaluatePlan(
        playerID, {}, weights, ignoredKeys, fixedSubjects, runCache
    );
    if baselineScore == -math.huge then baselineScore = 0; end
    local beam = {
        {
            items = {},
            occupied = {},
            score = baselineScore,
            priorityCounts = {},
            specialtyCounts = {},
            strategicResourceCount = 0,
            yieldsByItem = baselineYields or {},
        },
    };
    local skippedRequests = {};

    for requestIndex, request in ipairs(requests) do
        local expanded = {};
        local addedCandidate = false;
        local evaluatedCandidates = 0;
        for _, state in ipairs(beam) do
            local coveredByWonder =
                WonderSupportCoversDistrictRequest(state, request);
            if request.isOptional or coveredByWonder then
                table.insert(expanded, state);
            end
            if coveredByWonder then
                addedCandidate = true;
            else
                for _, candidate in ipairs(request.candidates) do
                    local additions = GetCandidateAdditions(
                        state, candidate, fixedSubjects, citySpecialtyBudgets
                    );
                    if additions then
                        local items = CopyArray(state.items);
                        for _, addition in ipairs(additions) do
                            table.insert(items, addition);
                        end
                        local score, yieldsByItem = EvaluatePlan(
                            playerID, items, weights, ignoredKeys, fixedSubjects,
                            runCache
                        );
                        evaluatedCandidates = evaluatedCandidates + 1;
                        if evaluatedCandidates % 8 == 0 then
                            AMT_YieldPlanning(
                                "LOC_AMT_CALCULATION_SEARCH",
                                requestIndex, #requests
                            );
                        end
                        if score > -math.huge then
                            local occupied = CopySet(state.occupied);
                            local priorityCounts = CopySet(
                                state.priorityCounts or {}
                            );
                            local specialtyCounts = CopySet(
                                state.specialtyCounts or {}
                            );
                            local strategicResourceCount =
                                tonumber(state.strategicResourceCount) or 0;
                            for _, addition in ipairs(additions) do
                                occupied[Key(addition.x, addition.y)] = true;
                                if addition.subjectType
                                    == MAP_PIN_TYPE_DISTRICT then
                                    local priority = math.max(
                                        1,
                                        math.min(
                                            99,
                                            math.floor(
                                                addition.districtPriority or 1
                                            )
                                        )
                                    );
                                    priorityCounts[priority] =
                                        (priorityCounts[priority] or 0) + 1;
                                    if addition.isSpecialty then
                                        specialtyCounts[addition.cityID] =
                                            (specialtyCounts[
                                                addition.cityID
                                            ] or 0) + 1;
                                    end
                                elseif addition.subjectType
                                    == MAP_PIN_TYPE_IMPROVEMENT
                                    and addition.resourceClass
                                        == "RESOURCECLASS_STRATEGIC" then
                                    strategicResourceCount =
                                        strategicResourceCount + 1;
                                end
                            end
                            table.insert(expanded, {
                                items = items,
                                occupied = occupied,
                                score = score,
                                priorityCounts = priorityCounts,
                                specialtyCounts = specialtyCounts,
                                strategicResourceCount =
                                    strategicResourceCount,
                                yieldsByItem = yieldsByItem,
                            });
                            addedCandidate = true;
                        end
                    end
                end
            end
        end

        if #expanded == 0 then
            Log("Skipping incompatible request " .. GetRequestDistrictDisplay(request));
            request.skipReason = "INCOMPATIBLE";
            table.insert(skippedRequests, request);
        else
            table.sort(expanded, IsBetterState);
            local nextBeam = {};
            local signatures = {};
            for _, state in ipairs(expanded) do
                local signature = GetStateSignature(state.items);
                if not signatures[signature] then
                    signatures[signature] = true;
                    table.insert(nextBeam, state);
                    if #nextBeam >= BEAM_WIDTH then break; end
                end
            end
            beam = nextBeam;
            Log(string.format(
                "Beam step=%d/%d states=%d bestScore=%.2f",
                requestIndex, #requests, #beam, beam[1].score
            ));
            if request.isAutoQuantity and not addedCandidate then
                Log("Automatic quantity search exhausted every legal placement.");
                break;
            end
        end
    end

    table.sort(beam, IsBetterState);
    return beam[1], skippedRequests;
end

function GetPinPlanningCityID(playerID, pin, registryRecord)
    if not pin then return nil; end
    if registryRecord and registryRecord.cityID ~= nil then
        return tonumber(registryRecord.cityID) or registryRecord.cityID;
    end

    local plot = Map.GetPlot(pin:GetHexX(), pin:GetHexY());
    local purchaseCity = AMT_GetPlotPurchaseCity(plot);
    if purchaseCity then
        local ownerMatches = true;
        if purchaseCity.GetOwner then
            local ok, owner = pcall(function()
                return purchaseCity:GetOwner();
            end);
            ownerMatches = not ok or owner == playerID;
        end
        if ownerMatches then return purchaseCity:GetID(); end
    end

    -- Old generated pins do not contain a city identifier.  For unowned plots,
    -- assign them deterministically to the nearest friendly city in workable
    -- range so a per-city refresh can still clean up legacy plans.
    local player = Players[playerID];
    local bestCity = nil;
    local bestDistance = nil;
    if player and player:GetCities() then
        for _, city in player:GetCities():Members() do
            local distance = Map.GetPlotDistance(
                city:GetX(), city:GetY(), pin:GetHexX(), pin:GetHexY()
            );
            if distance <= 3 and (
                bestCity == nil
                or distance < bestDistance
                or (
                    distance == bestDistance
                    and city:GetID() < bestCity:GetID()
                )
            ) then
                bestCity = city;
                bestDistance = distance;
            end
        end
    end
    return bestCity and bestCity:GetID() or nil;
end

function BuildClearPinKeysForCity(
    playerID, city, autoRegistry, includeManualPins
)
    local keys = {};
    if not city then return keys; end
    local targetCityID = city:GetID();
    local cfg = PlayerConfigurations[playerID];
    local pins = cfg and cfg:GetMapPins() or {};
    for _, pin in pairs(pins) do
        local key = pin and Key(pin:GetHexX(), pin:GetHexY()) or nil;
        local isAuto = IsAutoMapPin(pin, autoRegistry);
        local registryRecord = key and autoRegistry[key] or nil;
        local cityID = GetPinPlanningCityID(
            playerID, pin, registryRecord
        );
        if key
            and cityID == targetCityID
            and (isAuto or includeManualPins) then
            keys[key] = true;
        end
    end
    return keys;
end

function CapturePinRecord(pin, autoRegistry)
    if not pin then return nil; end
    local x, y = pin:GetHexX(), pin:GetHexY();
    local registryRecord = autoRegistry[Key(x, y)] or {};
    local subject = CreateMapPinSubject(pin);
    local subjectType = registryRecord.subjectType
        or (subject and subject.Type)
        or (registryRecord.district and MAP_PIN_TYPE_DISTRICT)
        or nil;
    local subjectKey = registryRecord.subjectKey
        or registryRecord.district
        or (subject and subject.Key)
        or nil;
    return {
        id = pin:GetID(),
        x = x,
        y = y,
        subjectType = subjectType,
        subjectKey = subjectKey,
        district = subjectType == MAP_PIN_TYPE_DISTRICT and subjectKey or nil,
        cityID = registryRecord.cityID
            or GetPinPlanningCityID(
                Game.GetLocalPlayer(), pin, registryRecord
            ),
        iconName = pin:GetIconName(),
        name = pin:GetName() or "",
        wasAuto = IsAutoMapPin(pin, autoRegistry),
    };
end

function DeletePinAt(playerID, x, y, autoRegistry, allowManualPin)
    local cfg = PlayerConfigurations[playerID];
    local pin = FindMapPinAt(playerID, x, y);
    if not cfg or not pin then return nil; end
    local isAuto = IsAutoMapPin(pin, autoRegistry);
    if not isAuto and not allowManualPin then return nil; end

    local record = CapturePinRecord(pin, autoRegistry);
    if isAuto then UnregisterAutoMapPin(pin, autoRegistry); end
    LuaEvents.DMT_MapPinRemoved(pin);
    cfg:DeleteMapPin(pin:GetID());
    return record;
end

function PlacePin(playerID, x, y, subjectType, subjectKey, iconName)
    local cfg = PlayerConfigurations[playerID];
    local p = cfg:GetMapPin(x, y);
    if not p then return nil; end
    p:SetIconName(iconName or GetSubjectIcon(subjectType, subjectKey));
    p:SetName("");
    p:SetVisibility(Game.GetLocalPlayer());
    Network.BroadcastPlayerInfo();
    LuaEvents.DMT_MapPinAdded(p);
    return p;
end

function RestorePinRecord(playerID, record, autoRegistry)
    local cfg = PlayerConfigurations[playerID];
    if not cfg or not record then return nil; end
    local pin = cfg:GetMapPin(record.x, record.y);
    if not pin then return nil; end

    local iconName = record.iconName;
    local subjectType = record.subjectType
        or (record.district and MAP_PIN_TYPE_DISTRICT);
    local subjectKey = record.subjectKey or record.district;
    if (not iconName or iconName == "") and subjectType and subjectKey then
        iconName = GetSubjectIcon(subjectType, subjectKey);
    end
    pin:SetIconName(iconName or "ICON_MAP_PIN");
    pin:SetName(record.name or "");
    pin:SetVisibility(Game.GetLocalPlayer());
    LuaEvents.DMT_MapPinAdded(pin);
    if record.wasAuto and subjectType and subjectKey then
        RegisterAutoMapPin(
            pin, subjectType, subjectKey, iconName, autoRegistry,
            record.cityID
        );
    end
    return pin;
end

function OnUndoLastPlan()
    if m_IsPlanning then return; end

    local playerID = Game.GetLocalPlayer();
    local transaction = LoadLastPlan(playerID);
    if not transaction then
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_UNDO_NONE"));
        RefreshUndoButton(playerID);
        return;
    end

    local autoRegistry = LoadAutoPinRegistry(playerID);
    local removedAddedCount = 0;
    local restoredCount = 0;
    local blockedRecords = {};

    for _, record in ipairs(transaction.added or {}) do
        local pin = FindMapPinAt(playerID, record.x, record.y);
        if pin and IsAutoMapPin(pin, autoRegistry) then
            if DeletePinAt(
                playerID, record.x, record.y, autoRegistry, false
            ) then
                removedAddedCount = removedAddedCount + 1;
            end
        end
    end

    for _, record in ipairs(transaction.removed or {}) do
        if FindMapPinAt(playerID, record.x, record.y) == nil then
            local pin = RestorePinRecord(playerID, record, autoRegistry);
            if pin then
                restoredCount = restoredCount + 1;
            else
                table.insert(blockedRecords, record);
            end
        else
            table.insert(blockedRecords, record);
        end
    end

    SaveAutoPinRegistry(playerID, autoRegistry);
    if #blockedRecords > 0 then
        SaveLastPlan(playerID, { added = {}, removed = blockedRecords });
        Controls.ResultText:SetText(Locale.Lookup(
            "LOC_AMT_UNDO_PARTIAL",
            removedAddedCount, restoredCount, #blockedRecords
        ));
    else
        SaveLastPlan(playerID, nil);
        Controls.ResultText:SetText(Locale.Lookup(
            "LOC_AMT_UNDO_RESULT", removedAddedCount, restoredCount
        ));
    end
    Network.BroadcastPlayerInfo();
    RefreshUndoButton(playerID);
    UI.PlaySound("Map_Pin_Remove");
    Log(string.format(
        "Undo completed removedAdded=%d restored=%d blocked=%d",
        removedAddedCount, restoredCount, #blockedRecords
    ));
end

function BuildPlanningStateSignature(playerID)
    local parts = {};
    local cfg = PlayerConfigurations[playerID];
    local pins = cfg and cfg:GetMapPins() or {};
    for _, pin in pairs(pins) do
        if pin then
            table.insert(parts, table.concat({
                tostring(pin:GetID()),
                Key(pin:GetHexX(), pin:GetHexY()),
                tostring(pin:GetIconName() or ""),
                tostring(pin:GetName() or ""),
            }, "@"));
        end
    end
    local registry = LoadAutoPinRegistry(playerID);
    for key, record in pairs(registry) do
        table.insert(parts, table.concat({
            "AUTO", key, tostring(record.id),
            tostring(record.subjectType or MAP_PIN_TYPE_DISTRICT),
            tostring(record.subjectKey or record.district),
            tostring(record.cityID or ""),
        }, "@"));
    end
    table.sort(parts);
    return table.concat(parts, "|");
end

function BuildAutoPlanPreview(
    city, selection, weights, overwriteExisting, clearFirst,
    includeLinkedCities, clearManualPins
)
    local playerID = Game.GetLocalPlayer();
    local cities = GetPlanningCities(city, includeLinkedCities);
    local runCache = BuildPlanningRunCache(playerID);
    local autoRegistry = LoadAutoPinRegistry(playerID);
    local rangeKeys = BuildRangeKeys(cities, runCache);
    local clearPinKeys = clearFirst
        and BuildClearPinKeysForCity(
            playerID, city, autoRegistry, clearManualPins
        )
        or {};
    local ignoredKeys = {};
    for key in pairs(clearPinKeys) do ignoredKeys[key] = true; end
    -- An auto-generated improvement may have been legal when placed while a
    -- strategic resource was still hidden.  Once the player reveals that
    -- resource, ignore the stale auto pin during recalculation so the correct
    -- resource improvement can replace it without requiring a blanket
    -- "replace all generated tacks" operation.
    local staleResourcePinKeys =
        ImprovementPlacement.GetStaleAutoResourcePinKeys(
            playerID, rangeKeys, autoRegistry
        );
    for key in pairs(staleResourcePinKeys) do ignoredKeys[key] = true; end
    local requests, fixedSubjects, preSkippedRequests,
        citySpecialtyBudgets =
        BuildPlanRequests(cities, selection, ignoredKeys);
    preSkippedRequests = preSkippedRequests or {};
    local reservedKeys = BuildCityCenterKeys(cities);

    Log(string.format(
        "Optimizer start cities=%d requests=%d linked=%s",
        #cities, #requests, tostring(includeLinkedCities)
    ));
    if #requests == 0 then
        if #preSkippedRequests > 0 then
            return {
                playerID = playerID,
                skippedRequests = preSkippedRequests,
                status = "UNAVAILABLE",
            };
        end
        return {
            playerID = playerID,
            skippedRequests = {},
            status = "SATISFIED",
        };
    end

    local feasibleRequests, skippedRequests = BuildCandidateShortlists(
        requests, playerID, weights, ignoredKeys, reservedKeys,
        overwriteExisting, clearFirst, fixedSubjects, autoRegistry,
        runCache
    );
    for _, request in ipairs(preSkippedRequests) do
        table.insert(skippedRequests, request);
    end
    if #feasibleRequests == 0 then
        return {
            playerID = playerID,
            skippedRequests = skippedRequests,
            status = "UNAVAILABLE",
        };
    end

    local bestState, incompatibleRequests = SearchBestPlan(
        feasibleRequests, playerID, weights, ignoredKeys, fixedSubjects,
        citySpecialtyBudgets, runCache
    );
    for _, request in ipairs(incompatibleRequests or {}) do
        table.insert(skippedRequests, request);
    end
    local plannedSubjectsByRequestID = {};
    local plannedImprovementSubjects = {};
    if bestState then
        for _, item in ipairs(bestState.items or {}) do
            if item.requestID then
                plannedSubjectsByRequestID[item.requestID] = item.subjectKey;
            end
            if item.subjectType == MAP_PIN_TYPE_IMPROVEMENT then
                plannedImprovementSubjects[item.subjectKey] = true;
            end
        end
    end
    local checkedImprovementRequests = {};
    for _, request in ipairs(feasibleRequests) do
        if request.isAutoQuantity
            and not checkedImprovementRequests[request.requestID] then
            checkedImprovementRequests[request.requestID] = true;
            for _, subjectKey in ipairs(
                request.subjectOptions or { request.subjectKey }
            ) do
                if not plannedImprovementSubjects[subjectKey] then
                    local skipped =
                        CloneRequestForSubject(request, subjectKey);
                    skipped.skipReason = "IMPROVEMENT_BUDGET";
                    table.insert(skippedRequests, skipped);
                end
            end
        end
    end
    local function HasPlannedEconomicAlternative(cityID, subjectKey)
        if not cityID or not IsEconomicTradeDistrict(subjectKey) then
            return false;
        end
        for _, item in ipairs(bestState and bestState.items or {}) do
            if item.cityID == cityID
                and item.subjectType == MAP_PIN_TYPE_DISTRICT
                and AreEconomicTradeAlternatives(
                    item.subjectKey, subjectKey
                ) then
                return true;
            end
        end
        return false;
    end
    for _, request in ipairs(feasibleRequests) do
        if request.subjectType == MAP_PIN_TYPE_DISTRICT
            and request.isOptional
            and request.requestID then
            local plannedSubject =
                plannedSubjectsByRequestID[request.requestID];
            if not plannedSubject then
                local requestedSubjects = {};
                for _, subjectKey in ipairs(request.subjectOptions or {
                    request.subjectKey or request.district
                }) do
                    requestedSubjects[subjectKey] = true;
                end
                for _, item in ipairs(bestState and bestState.items or {}) do
                    if item.cityID == request.cityID
                        and item.subjectType == MAP_PIN_TYPE_DISTRICT
                        and requestedSubjects[item.subjectKey] then
                        plannedSubject = item.subjectKey;
                        break;
                    end
                end
            end
            for _, subjectKey in ipairs(request.subjectOptions or {
                request.subjectKey or request.district
            }) do
                if subjectKey ~= plannedSubject then
                    local skipped =
                        CloneRequestForSubject(request, subjectKey);
                    if plannedSubject then
                        skipped.skipReason = "MUTUALLY_EXCLUSIVE";
                        skipped.conflictingDistrict = plannedSubject;
                    elseif HasPlannedEconomicAlternative(
                        request.cityID, subjectKey
                    ) then
                        skipped.skipReason = "TRADE_ROUTE_REDUNDANCY";
                    elseif request.isSpecialty then
                        skipped.skipReason = "POPULATION_LIMIT";
                        local budget = request.cityID
                            and citySpecialtyBudgets[request.cityID] or nil;
                        if budget then
                            skipped.targetPopulation =
                                budget.targetPopulation;
                        else
                            local targetPopulation = 1;
                            for _, cityBudget in pairs(
                                citySpecialtyBudgets
                            ) do
                                targetPopulation = math.max(
                                    targetPopulation,
                                    cityBudget.targetPopulation or 1
                                );
                            end
                            skipped.targetPopulation = targetPopulation;
                        end
                    else
                        skipped.skipReason = "LOWER_PRIORITY";
                    end
                    table.insert(skippedRequests, skipped);
                end
            end
        end
    end
    -- A selected district can be supplied as the validated support item of a
    -- selected wonder.  In that case the request is satisfied even when the
    -- standalone district branch was pre-skipped or exhausted its specialty
    -- budget; do not report the same district as both planned and unplaced.
    local unresolvedRequests = {};
    for _, request in ipairs(skippedRequests) do
        if not WonderSupportCoversDistrictRequest(bestState, request) then
            table.insert(unresolvedRequests, request);
        end
    end
    skippedRequests = unresolvedRequests;
    if not bestState or #bestState.items == 0 then
        return {
            playerID = playerID,
            skippedRequests = skippedRequests,
            status = #skippedRequests > 0 and "UNAVAILABLE" or "NO_BENEFIT",
        };
    end

    bestState.displayYieldsByItem = {};
    for index, item in ipairs(bestState.items) do
        local displayYields = CopyYields(
            bestState.yieldsByItem and bestState.yieldsByItem[index] or {}
        );
        if item.subjectType == MAP_PIN_TYPE_WONDER then
            AddYields(displayYields, CalculateReverseImpactYields(
                playerID, bestState.items, index, ignoredKeys, fixedSubjects
            ));
        end
        bestState.displayYieldsByItem[index] = displayYields;
    end
    local specialtyByCity = {};
    for _, item in ipairs(bestState.items) do
        if item.isSpecialty then
            specialtyByCity[item.cityID] =
                specialtyByCity[item.cityID] or {};
            table.insert(specialtyByCity[item.cityID], item);
        end
    end
    for cityID, items in pairs(specialtyByCity) do
        table.sort(items, function(a, b)
            if (a.specialtyOrder or 99) ~= (b.specialtyOrder or 99) then
                return (a.specialtyOrder or 99) < (b.specialtyOrder or 99);
            end
            return a.subjectKey < b.subjectKey;
        end);
        local budget = citySpecialtyBudgets[cityID] or {};
        for index, item in ipairs(items) do
            item.specialtySlot =
                (budget.existingSlots or 0) + index;
            item.requiredPopulation =
                GetRequiredPopulationForSpecialtySlot(item.specialtySlot);
        end
    end

    Log(string.format(
        "Optimizer preview finalScore=%.2f items=%d",
        bestState.score, #bestState.items
    ));
    return {
        playerID = playerID,
        cities = cities,
        ignoredKeys = ignoredKeys,
        clearPinKeys = clearPinKeys,
        staleResourcePinKeys = staleResourcePinKeys,
        bestState = bestState,
        weights = weights,
        overwriteExisting = overwriteExisting,
        clearFirst = clearFirst,
        clearManualPins = clearManualPins,
        skippedRequests = skippedRequests,
        citySpecialtyBudgets = citySpecialtyBudgets,
        yieldFocusStates = selection.yieldFocusStates,
        planningHorizon = selection.planningHorizon,
        planningStateSignature = BuildPlanningStateSignature(playerID),
        status = #skippedRequests > 0 and "PARTIAL" or "READY",
    };
end

function ApplyAutoPlanPreview(preview)
    if not preview or not preview.bestState then return {}, "EMPTY"; end
    local playerID = preview.playerID;
    if BuildPlanningStateSignature(playerID) ~= preview.planningStateSignature then
        return {}, "STALE";
    end

    local cities = preview.cities;
    local ignoredKeys = preview.ignoredKeys;
    local staleResourcePinKeys = preview.staleResourcePinKeys or {};
    local bestState = preview.bestState;
    local weights = preview.weights;
    local overwriteExisting = preview.overwriteExisting;
    local clearFirst = preview.clearFirst;
    local clearManualPins = preview.clearManualPins;
    local autoRegistry = LoadAutoPinRegistry(playerID);
    local transaction = { added = {}, removed = {} };
    if clearFirst then
        local clearPinKeys = preview.clearPinKeys or ignoredKeys;
        local cfg = PlayerConfigurations[playerID];
        local pins = cfg and cfg:GetMapPins() or {};
        local targets = {};
        for _, pin in pairs(pins) do
            if pin then
                local key = Key(pin:GetHexX(), pin:GetHexY());
                if clearPinKeys[key] then
                    table.insert(targets, {
                        x = pin:GetHexX(),
                        y = pin:GetHexY(),
                    });
                end
            end
        end
        for _, target in ipairs(targets) do
            local removed = DeletePinAt(
                playerID, target.x, target.y,
                autoRegistry, clearManualPins
            );
            if removed then table.insert(transaction.removed, removed); end
        end
    end

    local placed = {};
    for index, item in ipairs(bestState.items) do
        local itemKey = Key(item.x, item.y);
        local directive = AMT_PlotDirectives[Key(item.x, item.y)];
        if directive then
            -- A future-operation tack and the generated result cannot occupy
            -- the same hex.  Consume only that explicit instruction tack and
            -- keep it in the undo transaction.
            local removed = DeletePinAt(
                playerID, item.x, item.y, autoRegistry, true
            );
            if removed then table.insert(transaction.removed, removed); end
        end
        if staleResourcePinKeys[itemKey] then
            local removed = DeletePinAt(
                playerID, item.x, item.y, autoRegistry, false
            );
            if removed then table.insert(transaction.removed, removed); end
        end
        if overwriteExisting and not clearFirst then
            local removed = DeletePinAt(
                playerID, item.x, item.y, autoRegistry, false
            );
            if removed then table.insert(transaction.removed, removed); end
        end

        local pin = PlacePin(
            playerID, item.x, item.y,
            item.subjectType, item.subjectKey, item.iconName
        );
        if pin then
            local planningCityID = item.cityID
                or GetPinPlanningCityID(playerID, pin, nil);
            RegisterAutoMapPin(
                pin, item.subjectType, item.subjectKey,
                item.iconName, autoRegistry, planningCityID
            );
            table.insert(transaction.added, {
                id = pin:GetID(),
                x = item.x,
                y = item.y,
                subjectType = item.subjectType,
                subjectKey = item.subjectKey,
                iconName = item.iconName,
                cityID = planningCityID,
                district = item.subjectType == MAP_PIN_TYPE_DISTRICT
                    and item.subjectKey or nil,
            });
            local yields = bestState.displayYieldsByItem
                and bestState.displayYieldsByItem[index]
                or (bestState.yieldsByItem and bestState.yieldsByItem[index])
                or {};
            table.insert(placed, {
                subjectType = item.subjectType,
                subjectKey = item.subjectKey,
                iconName = item.iconName,
                district = item.subjectType == MAP_PIN_TYPE_DISTRICT
                    and item.subjectKey or nil,
                cityID = planningCityID,
                cityName = item.cityName,
                x = item.x,
                y = item.y,
                score = ScoreYields(yields, weights),
                yields = yields,
            });
            Log(string.format(
                "Placed %s for %s at (%d,%d)",
                item.subjectKey, item.cityName or "linked cities", item.x, item.y
            ));
        end
    end

    SaveAutoPinRegistry(playerID, autoRegistry);
    if #transaction.added > 0 or #transaction.removed > 0 then
        SaveLastPlan(playerID, transaction);
    end
    Network.BroadcastPlayerInfo();
    Log(string.format("Optimizer finalScore=%.2f placed=%d", bestState.score, #placed));
    return placed, "APPLIED";
end

local function GetWonderDiagnosticDisplay(request)
    if not ENABLE_WONDER_DEBUG then return nil; end
    if (request.subjectType or MAP_PIN_TYPE_DISTRICT)
        ~= MAP_PIN_TYPE_WONDER then
        return nil;
    end
    local diagnostics = request.wonderDiagnostics;
    local subjectKey = request.subjectKey or request.district;
    local diagnostic = diagnostics and diagnostics[subjectKey] or nil;
    if not diagnostic then return nil; end

    local counts = Locale.Lookup(
        "LOC_AMT_DIAG_COUNTS",
        diagnostic.scanned or 0,
        diagnostic.eligible or 0,
        diagnostic.quickPassed or 0,
        diagnostic.supportPairs or 0,
        diagnostic.evaluated or 0,
        diagnostic.dmtPassed or 0,
        diagnostic.accepted or 0
    );
    local priorities = {
        "DMT_ERROR",
        "DMT_REJECT",
        "RELATION_REJECT",
        "SIMULATION_ERROR",
        "NO_SUPPORT_PAIR",
        "QUICK_REJECT",
        "LOCAL_PLACEMENT_REJECT",
        "UNKNOWN_REJECT",
    };
    local first = nil;
    for _, stage in ipairs(priorities) do
        if diagnostic.firstByStage[stage] then
            first = diagnostic.firstByStage[stage];
            break;
        end
    end
    if not first then return counts; end
    local subjectName = first.subjectKey and GetSubjectDisplay(
        first.subjectType or MAP_PIN_TYPE_WONDER,
        first.subjectKey
    ) or "?";
    local detail = first.detail;
    if not detail or detail == "" then
        detail = Locale.Lookup("LOC_AMT_DIAG_NO_DETAIL");
    end
    return counts .. "[NEWLINE]" .. Locale.Lookup(
        "LOC_AMT_DIAG_FIRST_FAILURE",
        first.stage,
        subjectName,
        first.x or "?",
        first.y or "?",
        detail
    );
end

function GetSkipReasonDisplay(request)
    if request.skipReason == "MUTUALLY_EXCLUSIVE" then
        return Locale.Lookup(
            "LOC_AMT_REASON_MUTUALLY_EXCLUSIVE",
            GetDistrictDisplay(request.conflictingDistrict)
        );
    elseif request.skipReason == "INCOMPATIBLE" then
        return Locale.Lookup("LOC_AMT_REASON_INCOMPATIBLE");
    elseif request.skipReason == "ALREADY_EXISTS" then
        return Locale.Lookup("LOC_AMT_REASON_ALREADY_EXISTS");
    elseif request.skipReason == "LOWER_PRIORITY" then
        return Locale.Lookup("LOC_AMT_REASON_LOWER_PRIORITY");
    elseif request.skipReason == "POPULATION_LIMIT" then
        return Locale.Lookup(
            "LOC_AMT_REASON_POPULATION_LIMIT",
            request.targetPopulation or "?"
        );
    elseif request.skipReason == "COVERAGE_SATISFIED" then
        return Locale.Lookup("LOC_AMT_REASON_COVERAGE_SATISFIED");
    elseif request.skipReason == "TRADE_ROUTE_REDUNDANCY" then
        return Locale.Lookup("LOC_AMT_REASON_TRADE_ROUTE_REDUNDANCY");
    elseif request.skipReason == "IMPROVEMENT_BUDGET" then
        return Locale.Lookup(
            "LOC_AMT_REASON_IMPROVEMENT_BUDGET",
            request.targetImprovedPlots or "?",
            request.existingImprovementCount or 0
        );
    end
    local reason = Locale.Lookup("LOC_AMT_REASON_NO_LEGAL_TILE");
    local diagnostic = GetWonderDiagnosticDisplay(request);
    if diagnostic then
        reason = reason .. "[NEWLINE]" .. diagnostic;
    end
    return reason;
end

function GetUniqueSkippedRequests(skippedRequests)
    local entries = {};
    local seen = {};
    for _, request in ipairs(skippedRequests or {}) do
        local cityName = request.cityName or Locale.Lookup("LOC_AMT_LINKED_CITIES");
        local subjectName = GetRequestDistrictDisplay(request);
        local reason = GetSkipReasonDisplay(request);
        local uniqueKey = cityName .. "|" .. subjectName .. "|" .. reason;
        if not seen[uniqueKey] then
            seen[uniqueKey] = true;
            table.insert(entries, {
                request = request,
                cityName = cityName,
                subjectName = subjectName,
                reason = reason,
            });
        end
    end
    return entries;
end

function FormatSkippedRequests(skippedRequests)
    local labels = {};
    for _, entry in ipairs(GetUniqueSkippedRequests(skippedRequests)) do
        table.insert(labels,
            entry.cityName .. " - " .. entry.subjectName
            .. " (" .. entry.reason .. ")"
        );
    end
    return table.concat(labels, "[NEWLINE]");
end

function FormatPreviewNumber(value)
    local rounded = math.floor(value + 0.5);
    if math.abs(value - rounded) < 0.01 then return tostring(rounded); end
    return string.format("%.1f", value);
end

function FormatYieldSummary(yields)
    local parts = {};
    for _, yieldType in ipairs(YIELD_LIST) do
        local amount = tonumber(yields and yields[yieldType]) or 0;
        if math.abs(amount) > 0.001 then
            local yieldRow = GameInfo.Yields[yieldType];
            local icon = yieldRow and yieldRow.IconString or "";
            local prefix = amount > 0 and "+" or "";
            table.insert(parts, icon .. prefix .. FormatPreviewNumber(amount));
        end
    end
    if #parts == 0 then return Locale.Lookup("LOC_AMT_NO_ADJACENCY"); end
    return table.concat(parts, "  ");
end

-- The report occupies the right edge of the screen.  Aim at the centre of
-- the remaining map area instead of the centre of the full viewport.
local REPORT_CAMERA_X = 0.38;

function FocusReportPlot(x, y)
    UI.LookAtPlotScreenPosition(x, y, REPORT_CAMERA_X, 0.5);
end

function ResetReportScrollPositions()
    if Controls.SkippedScroll then
        Controls.SkippedScroll:SetScrollValue(0);
    end
    if Controls.PreviewScroll then
        Controls.PreviewScroll:SetScrollValue(0);
    end
end

function LayoutReportSections(hasSkipped)
    -- Keep the original two-section layout when there are warnings.  When
    -- there are none, reclaim the otherwise empty warning list for results.
    if hasSkipped then
        Controls.PreviewLabel:SetOffsetY(309);
        Controls.PreviewScroll:SetOffsetY(337);
        Controls.PreviewScroll:SetSizeY(205);
    else
        Controls.PreviewLabel:SetOffsetY(178);
        Controls.PreviewScroll:SetOffsetY(206);
        Controls.PreviewScroll:SetSizeY(336);
    end
end

function ShowPreviewHighlights(preview)
    ClearPreviewHighlights();
    local plotIDs = {};
    local items = preview.bestState and preview.bestState.items or {};
    for _, item in ipairs(items) do
        local plot = Map.GetPlot(item.x, item.y);
        if plot then table.insert(plotIDs, plot:GetIndex()); end
    end
    if #plotIDs > 0 then
        local color = UI.GetColorValue("COLOR_BREATHTAKING_APPEAL");
        UILens.SetLayerHexesColoredArea(
            PREVIEW_LENS_LAYER, preview.playerID, plotIDs, color
        );
        local first = items[1];
        FocusReportPlot(first.x, first.y);
    end
end

function ShowPreviewPanel(preview)
    m_PreviewEntryIM:ResetInstances();
    m_PreviewSkippedEntryIM:ResetInstances();
    m_PreviewMapIconIM:ResetInstances();
    local bestState = preview.bestState or { items = {} };
    local plannedItems = bestState.items or {};
    local uniqueSkipped =
        GetUniqueSkippedRequests(preview.skippedRequests);

    for _, entry in ipairs(uniqueSkipped) do
        local request = entry.request;
        local instance = m_PreviewSkippedEntryIM:GetInstance();
        instance.SubjectIcon:SetIcon(GetSubjectIcon(
            request.subjectType or MAP_PIN_TYPE_DISTRICT,
            request.subjectKey or request.district
        ));
        instance.DetailText:SetText(Locale.Lookup(
            "LOC_AMT_REPORT_SKIPPED_ENTRY",
            entry.subjectName,
            entry.cityName,
            entry.reason
        ));
        instance.SelectButton:SetDisabled(true);
        instance.SelectButton:SetToolTipString(entry.reason);
    end

    for index, item in ipairs(plannedItems) do
        local yields = bestState.displayYieldsByItem
            and bestState.displayYieldsByItem[index]
            or (bestState.yieldsByItem
                and bestState.yieldsByItem[index])
            or {};
        local detail = Locale.Lookup(
            "LOC_AMT_PREVIEW_ENTRY",
            index,
            item.cityName or Locale.Lookup("LOC_AMT_LINKED_CITIES"),
            GetSubjectDisplay(item.subjectType, item.subjectKey),
            item.x,
            item.y,
            FormatYieldSummary(yields)
        );
        if item.isSpecialty and item.specialtySlot then
            detail = detail .. "[NEWLINE]" .. Locale.Lookup(
                "LOC_AMT_PREVIEW_SPECIALTY_SLOT",
                item.specialtySlot,
                item.requiredPopulation or
                    GetRequiredPopulationForSpecialtySlot(item.specialtySlot)
            );
        elseif item.baseDistrictType == "DISTRICT_PRESERVE" then
            detail = detail .. "[NEWLINE]"
                .. Locale.Lookup("LOC_AMT_PREVIEW_PRESERVE_SCORE");
        end
        local instance = m_PreviewEntryIM:GetInstance();
        instance.SubjectIcon:SetIcon(item.iconName);
        instance.DetailText:SetText(detail);
        instance.SelectButton:SetToolTipString(Locale.Lookup(
            "LOC_AMT_PREVIEW_FOCUS_TOOLTIP"
        ));
        local x, y = item.x, item.y;
        instance.SelectButton:RegisterCallback(Mouse.eLClick, function()
            FocusReportPlot(x, y);
        end);

        local mapInstance = m_PreviewMapIconIM:GetInstance();
        mapInstance.SubjectIcon:SetIcon(item.iconName);
        mapInstance.YieldText:SetText(FormatYieldSummary(yields));
        local worldX, worldY, worldZ = UI.GridToWorld(item.x, item.y);
        mapInstance.Anchor:SetWorldPositionVal(
            worldX, worldY, (worldZ or 0) + 12
        );
    end
    Controls.SkippedStack:CalculateSize();
    Controls.SkippedStack:ReprocessAnchoring();
    Controls.SkippedScroll:CalculateInternalSize();
    Controls.PreviewStack:CalculateSize();
    Controls.PreviewStack:ReprocessAnchoring();
    Controls.PreviewScroll:CalculateInternalSize();
    LayoutReportSections(#uniqueSkipped > 0);
    ResetReportScrollPositions();

    local primaryBudget = nil;
    for _, budget in pairs(preview.citySpecialtyBudgets or {}) do
        if budget.isPrimary then
            primaryBudget = budget;
            break;
        end
    end
    local planningPopulation = primaryBudget
        and primaryBudget.targetPopulation or "?";
    local horizonName = Locale.Lookup(
        preview.planningHorizon == "CURRENT"
            and "LOC_AMT_CURRENT_BUILDABLE"
            or "LOC_AMT_LONG_TERM"
    );
    Controls.PreviewSummary:SetText(Locale.Lookup(
        "LOC_AMT_REPORT_SUMMARY",
        #plannedItems,
        #uniqueSkipped,
        planningPopulation,
        horizonName
    ));
    Controls.SkippedLabel:SetText(Locale.Lookup(
        "LOC_AMT_REPORT_SKIPPED_SECTION", #uniqueSkipped
    ));
    Controls.PreviewLabel:SetText(Locale.Lookup(
        "LOC_AMT_REPORT_PLANNED_SECTION", #plannedItems
    ));
    Controls.SkippedEmptyLabel:SetHide(#uniqueSkipped > 0);
    Controls.SkippedScroll:SetHide(#uniqueSkipped == 0);

    local skippedFull = FormatSkippedRequests(preview.skippedRequests);
    local contextLine = Locale.Lookup(
        "LOC_AMT_YIELD_FOCUS_SUMMARY",
        GetYieldFocusSummary(preview.yieldFocusStates)
    ) .. "[NEWLINE]" .. horizonName;
    Controls.PreviewSummary:SetToolTipString(
        contextLine
        .. (#uniqueSkipped > 0 and
            ("[NEWLINE][NEWLINE]" .. skippedFull) or "")
    );

    Controls.SettingsBlocker:SetHide(true);
    Controls.PreviewPanel:SetHide(false);
    if Controls.PreviewTitle then
        Controls.PreviewTitle:SetText(Locale.Lookup("LOC_AMT_PREVIEW_TITLE"));
    end
    Controls.PreviewLabel:SetHide(false);
    Controls.PreviewScroll:SetHide(false);
    if Controls.PreviewConfirmButton then
        Controls.PreviewConfirmButton:SetHide(false);
        Controls.PreviewConfirmButton:SetDisabled(#plannedItems == 0);
    end
    ShowPreviewHighlights(preview);
end

function AMT_ShowHighAdjacencySelection(report, entry)
    m_PreviewMapIconIM:ResetInstances();
    ClearPreviewHighlights();
    if not entry or not entry.item then return; end

    local items = { entry.item };
    for _, support in ipairs(entry.supportItems or {}) do
        table.insert(items, support);
    end
    for itemIndex, item in ipairs(items) do
        local mapInstance = m_PreviewMapIconIM:GetInstance();
        mapInstance.SubjectIcon:SetIcon(item.iconName);
        mapInstance.YieldText:SetText(
            itemIndex == 1 and FormatYieldSummary(entry.yields)
                or Locale.Lookup(
                    "LOC_AMT_HIGH_ADJACENCY_SUPPORT_BADGE"
                )
        );
        local worldX, worldY, worldZ = UI.GridToWorld(item.x, item.y);
        mapInstance.Anchor:SetWorldPositionVal(
            worldX, worldY, (worldZ or 0) + 12
        );
    end
    ShowPreviewHighlights({
        playerID = report.playerID,
        bestState = { items = items },
    });
end

function ShowHighAdjacencyAnalysis(report)
    ClearPendingPreview(true);
    m_PreviewEntryIM:ResetInstances();
    m_PreviewSkippedEntryIM:ResetInstances();
    m_PreviewMapIconIM:ResetInstances();
    local results = report.results or {};
    local unavailable = report.unavailable or {};

    for _, entry in ipairs(unavailable) do
        local instance = m_PreviewSkippedEntryIM:GetInstance();
        instance.SubjectIcon:SetIcon(GetSubjectIcon(
            MAP_PIN_TYPE_DISTRICT, entry.subjectKey
        ));
        instance.DetailText:SetText(Locale.Lookup(
            "LOC_AMT_HIGH_ADJACENCY_UNAVAILABLE_ENTRY",
            entry.subjectName,
            entry.reason
        ));
        instance.SelectButton:SetDisabled(true);
        instance.SelectButton:SetToolTipString(entry.reason);
        instance.Top:SetSizeY(84);
        instance.SelectButton:SetSizeY(82);
        instance.DetailText:SetSizeY(76);
    end

    for index, entry in ipairs(results) do
        local item = entry.item;
        local instance = m_PreviewEntryIM:GetInstance();
        instance.SubjectIcon:SetIcon(item.iconName);
        instance.DetailText:SetText(Locale.Lookup(
            "LOC_AMT_HIGH_ADJACENCY_ENTRY",
            index,
            entry.subjectName,
            item.x,
            item.y,
            FormatYieldSummary(entry.yields),
            entry.status,
            AMT_GetSupportSummary(entry.supportItems)
        ));
        instance.SelectButton:SetToolTipString(Locale.Lookup(
            "LOC_AMT_HIGH_ADJACENCY_SELECT_TOOLTIP"
        ));
        -- Analysis entries contain three logical lines and the supporting
        -- improvement summary may wrap to a fourth.  The normal preview row
        -- is intentionally compact, so expand only analysis rows.
        instance.Top:SetSizeY(88);
        instance.SelectButton:SetSizeY(86);
        instance.DetailText:SetSizeY(80);
        local selectedEntry = entry;
        instance.SelectButton:RegisterCallback(Mouse.eLClick, function()
            AMT_ShowHighAdjacencySelection(report, selectedEntry);
        end);
    end

    Controls.SkippedStack:CalculateSize();
    Controls.SkippedStack:ReprocessAnchoring();
    Controls.SkippedScroll:CalculateInternalSize();
    Controls.PreviewStack:CalculateSize();
    Controls.PreviewStack:ReprocessAnchoring();
    Controls.PreviewScroll:CalculateInternalSize();
    LayoutReportSections(#unavailable > 0);
    ResetReportScrollPositions();
    if Controls.PreviewTitle then
        Controls.PreviewTitle:SetText(Locale.Lookup(
            "LOC_AMT_HIGH_ADJACENCY_TITLE"
        ));
    end
    Controls.PreviewSummary:SetText(Locale.Lookup(
        "LOC_AMT_HIGH_ADJACENCY_SUMMARY",
        report.cityName,
        #results,
        #unavailable
    ));
    Controls.SkippedLabel:SetText(Locale.Lookup(
        "LOC_AMT_HIGH_ADJACENCY_UNAVAILABLE_SECTION", #unavailable
    ));
    Controls.PreviewLabel:SetText(Locale.Lookup(
        "LOC_AMT_HIGH_ADJACENCY_AVAILABLE_SECTION", #results
    ));
    Controls.SkippedEmptyLabel:SetHide(true);
    Controls.SkippedScroll:SetHide(#unavailable == 0);
    Controls.PreviewLabel:SetHide(false);
    Controls.PreviewScroll:SetHide(#results == 0);
    Controls.SettingsBlocker:SetHide(true);
    Controls.PreviewPanel:SetHide(false);
    if Controls.PreviewConfirmButton then
        Controls.PreviewConfirmButton:SetHide(true);
    end
    AMT_ShowHighAdjacencySelection(report, results[1]);
end

function OnBackToSettings()
    ClearPendingPreview(true);
    if m_ResultText then
        m_ResultText:SetText(Locale.Lookup("LOC_AMT_PREVIEW_CANCELLED"));
        m_ResultText:SetToolTipString("");
    end
end

function OnConfirmPreview()
    if m_IsPlanning or not m_PendingPreview then return; end
    m_IsPlanning = true;
    if Controls.PreviewConfirmButton then
        Controls.PreviewConfirmButton:SetDisabled(true);
    end
    local preview = m_PendingPreview;
    local ok, placedOrError, applyStatus = pcall(ApplyAutoPlanPreview, preview);
    m_IsPlanning = false;
    if Controls.PreviewConfirmButton then
        Controls.PreviewConfirmButton:SetDisabled(false);
    end

    if not ok then
        Log("Apply preview failed: " .. tostring(placedOrError));
        OnBackToSettings();
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_RESULT_ERROR"));
        return;
    end
    if applyStatus == "STALE" then
        OnBackToSettings();
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_PREVIEW_STALE"));
        return;
    end

    local placed = placedOrError or {};
    if #placed == 0 then
        OnBackToSettings();
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_RESULT_NONE"));
        return;
    end

    UI.PlaySound("Map_Pin_Add");
    RefreshUndoButton(preview.playerID);
    ClearPendingPreview(true);
    UIManager:DequeuePopup(ContextPtr);
    m_IsOpen = false;
    Log(string.format("Confirmed preview and placed %d tack(s).", #placed));
end

function SetPlanningUi(isPlanning)
    if Controls.PlanningOverlay then
        Controls.PlanningOverlay:SetHide(not isPlanning);
    end
    if isPlanning and Controls.PlanningStatus then
        Controls.PlanningStatus:SetText(
            Locale.Lookup("LOC_AMT_CALCULATING_LONG")
        );
    end
    if Controls.OkButton then Controls.OkButton:SetDisabled(isPlanning); end
    if Controls.OneClickButton then
        Controls.OneClickButton:SetDisabled(isPlanning);
    end
end

function FinishPlanningUi()
    ContextPtr:ClearUpdate();
    m_IsPlanning = false;
    m_PlanningDelayFrames = 0;
    SetPlanningUi(false);
end

function ExecuteQueuedPlan()
    local job = m_QueuedPlan;
    if not job or not m_IsOpen then
        m_QueuedPlan = nil;
        FinishPlanningUi();
        return;
    end

    if not coroutine or not coroutine.create
        or not coroutine.resume or not coroutine.status then
        local ok, previewOrError = pcall(
            BuildAutoPlanPreview,
            job.city,
            job.selection,
            job.weights,
            job.overwrite,
            job.clear,
            job.linked,
            job.clearManual
        );
        m_QueuedPlan = nil;
        pcall(UpdatePinYields, job.playerID, {});
        FinishPlanningUi();
        if not ok then
            Controls.ResultText:SetText(
                Locale.Lookup("LOC_AMT_RESULT_ERROR")
            );
            Log("Optimizer failed: " .. tostring(previewOrError));
            return;
        end
        local preview = previewOrError or {};
        local skippedRequests = preview.skippedRequests or {};
        if preview.bestState and #preview.bestState.items > 0 then
            m_PendingPreview = preview;
            ShowPreviewPanel(preview);
        elseif #skippedRequests > 0 then
            preview.bestState = preview.bestState or { items = {} };
            m_PendingPreview = nil;
            ShowPreviewPanel(preview);
        elseif preview.status == "SATISFIED" then
            Controls.ResultText:SetText(
                Locale.Lookup("LOC_AMT_RESULT_SATISFIED")
            );
        elseif preview.status == "NO_BENEFIT" then
            Controls.ResultText:SetText(
                Locale.Lookup("LOC_AMT_RESULT_NO_BENEFIT")
            );
        else
            Controls.ResultText:SetText(
                Locale.Lookup("LOC_AMT_RESULT_NONE")
            );
        end
        Log("Preview calculation done without coroutine support.");
        return;
    end
    if not job.worker then
        job.worker = coroutine.create(function()
            return BuildAutoPlanPreview(
                job.city,
                job.selection,
                job.weights,
                job.overwrite,
                job.clear,
                job.linked,
                job.clearManual
            );
        end);
    end
    local ok, previewOrError = coroutine.resume(job.worker);
    if ok and coroutine.status(job.worker) ~= "dead" then
        return;
    end
    m_QueuedPlan = nil;
    pcall(UpdatePinYields, job.playerID, {});
    FinishPlanningUi();
    if not ok then
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_RESULT_ERROR"));
        Log("Optimizer failed: " .. tostring(previewOrError));
        return;
    end

    local preview = previewOrError or {};
    local skippedRequests = preview.skippedRequests or {};
    if preview.bestState and #preview.bestState.items > 0 then
        m_PendingPreview = preview;
        ShowPreviewPanel(preview);
    elseif #skippedRequests > 0 then
        preview.bestState = preview.bestState or { items = {} };
        m_PendingPreview = nil;
        ShowPreviewPanel(preview);
    elseif preview.status == "SATISFIED" then
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_RESULT_SATISFIED"));
    elseif preview.status == "NO_BENEFIT" then
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_RESULT_NO_BENEFIT"));
    else
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_RESULT_NONE"));
    end
    Log("Preview calculation done.");
end

function OnPlanningUpdate()
    m_PlanningDelayFrames = m_PlanningDelayFrames + 1;
    if m_PlanningDelayFrames < 2 then return; end
    ExecuteQueuedPlan();
end

function OnPlan(selectionOverride)
    if m_IsPlanning then
        Log("Plan click ignored: optimizer is already running.");
        return;
    end

    if Controls.WarningText then
        Controls.WarningText:SetHide(true);
        Controls.WarningText:SetText("");
    end
    Controls.ResultText:SetHide(false);
    local playerID = Game.GetLocalPlayer();
    local city = GetSelectedCity();
    if not city then
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_NO_CITY"));
        return;
    end
    local selection = selectionOverride or ReadSelectedSubjects();
    local selectedCount = #selection.districts
        + #selection.improvements + #selection.wonders;
    if selectedCount == 0 then
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_NO_SUBJECTS"));
        return;
    end
    local dependentWonder, requiredDistrict =
        GetMissingSelectedWonderDistrict(selection, city);
    if dependentWonder and requiredDistrict then
        local warning = Locale.Lookup(
            "LOC_AMT_WONDER_REQUIRES_SELECTED_DISTRICT",
            GetSubjectDisplay(MAP_PIN_TYPE_WONDER, dependentWonder),
            GetDistrictDisplay(requiredDistrict)
        );
        if Controls.WarningText then
            Controls.ResultText:SetHide(true);
            Controls.WarningText:SetText(warning);
            Controls.WarningText:SetHide(false);
        else
            Controls.ResultText:SetText(warning);
            Controls.ResultText:SetToolTipString("");
        end
        return;
    end
    local weights = GetAdjacencyWeights(selection);
    local overwrite = m_OverwriteCheck and m_OverwriteCheck:IsChecked() or false;
    local clear = m_ClearCheck and m_ClearCheck:IsChecked() or false;
    local clearManual = clear
        and m_ClearManualCheck
        and m_ClearManualCheck:IsChecked()
        or false;
    -- Multi-city joint optimization remains an internal experiment.  The
    -- public planner deliberately optimizes only the selected city so its
    -- population budget, ownership rules, and skipped-item report stay clear.
    local linked = false;

    ClearPendingPreview(false);
    Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_CALCULATING"));
    Controls.ResultText:SetToolTipString("");
    Log(string.format(
        "Plan start: city=%s subjects=%d overwrite=%s clear=%s clearManual=%s linked=%s",
        tostring(city:GetName()), selectedCount, tostring(overwrite), tostring(clear),
        tostring(clearManual), tostring(linked)
    ));

    m_QueuedPlan = {
        playerID = playerID,
        city = city,
        selection = selection,
        weights = weights,
        overwrite = overwrite,
        clear = clear,
        clearManual = clearManual,
        linked = linked,
        worker = nil,
    };
    m_IsPlanning = true;
    m_PlanningDelayFrames = 0;
    SetPlanningUi(true);
    ContextPtr:SetUpdate(OnPlanningUpdate);
end

function OnHighAdjacencyAnalysis()
    if m_IsPlanning then return; end
    local playerID = Game.GetLocalPlayer();
    local city = GetSelectedCity();
    if not city then
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_NO_CITY"));
        return;
    end

    m_IsPlanning = true;
    SetPlanningUi(true);
    ClearPendingPreview(true);
    if m_ResultText then
        m_ResultText:SetText(Locale.Lookup(
            "LOC_AMT_HIGH_ADJACENCY_CALCULATING"
        ));
    end

    -- This analysis runs directly from a UI callback instead of the normal
    -- update-driven planning worker. Firaxis may invoke that callback from a
    -- paused coroutine, where coroutine.running() looks yieldable but
    -- coroutine.yield() raises "attempt to yield a paused coroutine".
    m_SuppressPlanningYield = true;
    local ok, reportOrError = pcall(function()
        local selection = ReadSelectedSubjects();
        local weights = GetAdjacencyWeights(selection);
        local runCache = BuildPlanningRunCache(playerID);
        local ignoredKeys = {};
        local reservedKeys = BuildCityCenterKeys({ city });
        local existingByCity, _, fixedSubjects =
            GetExistingPlannedDistricts({ city }, ignoredKeys);
        local autoRegistry = LoadAutoPinRegistry(playerID);
        local results = {};
        local unavailable = {};

        for _, option in ipairs(
            m_PlannerOptions[MAP_PIN_TYPE_DISTRICT] or {}
        ) do
            if option.requiresPopulation then
                local subjectKey = option.subjectKey;
                local subjectName = GetDistrictDisplay(subjectKey);
                local alreadyBuilt =
                    IsDistrictAlreadyInCity(city, subjectKey);
                local alreadyPinned = (existingByCity[city:GetID()]
                    and (existingByCity[city:GetID()][subjectKey] or 0) > 0)
                    or false;
                if alreadyBuilt or alreadyPinned then
                    table.insert(unavailable, {
                        subjectKey = subjectKey,
                        subjectName = subjectName,
                        reason = Locale.Lookup(
                            alreadyBuilt
                                and "LOC_AMT_HIGH_ADJACENCY_ALREADY_BUILT"
                                or "LOC_AMT_HIGH_ADJACENCY_ALREADY_PLANNED"
                        ),
                    });
                else
                    local request = {
                        requestID = "ANALYSIS_" .. subjectKey,
                        subjectType = MAP_PIN_TYPE_DISTRICT,
                        subjectKey = subjectKey,
                        subjectOptions = { subjectKey },
                        cities = { city },
                        cityID = city:GetID(),
                        cityName = Locale.Lookup(city:GetName()),
                        isSpecialty = true,
                        subjectPriorities = { [subjectKey] = 1 },
                        subjectOrders = { [subjectKey] = 1 },
                    };
                    local candidates = BuildRawCandidates(
                        request, playerID, weights, ignoredKeys,
                        reservedKeys, true, false, fixedSubjects,
                        autoRegistry, runCache
                    );
                    for _, candidate in ipairs(candidates) do
                        candidate.analysisScore =
                            AMT_GetDistrictAnalysisScore(
                                candidate, candidate.analysisYields
                            );
                        candidate.analysisTieScore =
                            AMT_GetDistrictAnalysisTieScore(
                                candidate.analysisYields
                            );
                    end
                    table.sort(candidates, function(a, b)
                        if (a.analysisScore or -math.huge)
                            ~= (b.analysisScore or -math.huge) then
                            return (a.analysisScore or -math.huge)
                                > (b.analysisScore or -math.huge);
                        end
                        if (a.analysisTieScore or -math.huge)
                            ~= (b.analysisTieScore or -math.huge) then
                            return (a.analysisTieScore or -math.huge)
                                > (b.analysisTieScore or -math.huge);
                        end
                        if a.y ~= b.y then return a.y < b.y; end
                        return a.x < b.x;
                    end);

                    -- Improvement-assisted analysis is deliberately bounded
                    -- to the four strongest natural sites.  It still tests
                    -- every legal adjacent standard, unique, and modded
                    -- improvement, but avoids multiplying that work across
                    -- every tile in the city.
                    local best = nil;
                    local bestYields = nil;
                    local bestSupportItems = nil;
                    local bestAnalysisScore = -math.huge;
                    local bestTieScore = -math.huge;
                    for candidateIndex = 1,
                        math.min(4, #candidates) do
                        local candidate = candidates[candidateIndex];
                        local supportItems, assistedYields =
                            AMT_FindDirectDistrictSupport(
                                playerID, city, candidate,
                                candidate.analysisYields, weights,
                                ignoredKeys, fixedSubjects, runCache
                            );
                        local analysisScore =
                            AMT_GetDistrictAnalysisScore(
                                candidate, assistedYields
                            );
                        local tieScore =
                            AMT_GetDistrictAnalysisTieScore(
                                assistedYields
                            );
                        if analysisScore > bestAnalysisScore
                            or (analysisScore == bestAnalysisScore
                                and tieScore > bestTieScore)
                            or (analysisScore == bestAnalysisScore
                                and tieScore == bestTieScore
                                and best
                                and (candidate.y < best.y
                                    or (candidate.y == best.y
                                        and candidate.x < best.x))) then
                            best = candidate;
                            bestYields = assistedYields;
                            bestSupportItems = supportItems;
                            bestAnalysisScore = analysisScore;
                            bestTieScore = tieScore;
                        end
                    end
                    if best then
                        table.insert(results, {
                            subjectKey = subjectKey,
                            subjectName = subjectName,
                            item = best,
                            yields = CopyYields(bestYields or {}),
                            supportItems = bestSupportItems or {},
                            analysisScore = bestAnalysisScore,
                            analysisTieScore = bestTieScore,
                            status = Locale.Lookup(
                                IsSubjectCurrentlyUnlocked(option, playerID)
                                    and "LOC_AMT_HIGH_ADJACENCY_CURRENT"
                                    or "LOC_AMT_HIGH_ADJACENCY_FUTURE"
                            ),
                        });
                    else
                        table.insert(unavailable, {
                            subjectKey = subjectKey,
                            subjectName = subjectName,
                            reason = Locale.Lookup(
                                "LOC_AMT_HIGH_ADJACENCY_NO_LEGAL_TILE"
                            ),
                        });
                    end
                end
            end
        end
        table.sort(results, function(a, b)
            if (a.analysisScore or 0) ~= (b.analysisScore or 0) then
                return (a.analysisScore or 0) > (b.analysisScore or 0);
            end
            if (a.analysisTieScore or 0)
                ~= (b.analysisTieScore or 0) then
                return (a.analysisTieScore or 0)
                    > (b.analysisTieScore or 0);
            end
            return a.subjectName < b.subjectName;
        end);
        return {
            playerID = playerID,
            cityName = Locale.Lookup(city:GetName()),
            results = results,
            unavailable = unavailable,
        };
    end);
    m_SuppressPlanningYield = false;

    m_IsPlanning = false;
    SetPlanningUi(false);
    pcall(UpdatePinYields, playerID, {});
    if not ok then
        Log("High-adjacency analysis failed: " .. tostring(reportOrError));
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_RESULT_ERROR"));
        return;
    end
    ShowHighAdjacencyAnalysis(reportOrError);
end

function ShowPopup()
    RepopulatePopup();
    if UIManager:IsInPopupQueue(ContextPtr) then return; end
    UIManager:QueuePopup(ContextPtr, PopupPriority.Low);
    m_IsOpen = true;
    Log("Popup shown.");
end

function HidePopup()
    if m_QueuedPlan then
        ContextPtr:ClearUpdate();
        m_QueuedPlan = nil;
    end
    FinishPlanningUi();
    ClearPendingPreview(true);
    UIManager:DequeuePopup(ContextPtr);
    m_IsOpen = false;
    Log("Popup hidden.");
end

function AMT_OnProgressionChanged(playerID)
    if playerID ~= Game.GetLocalPlayer() or not m_IsOpen or m_IsPlanning then
        return;
    end
    OnBackToSettings();
    RepopulatePopup();
    if m_ResultText then
        m_ResultText:SetText(Locale.Lookup("LOC_AMT_RULES_REFRESHED"));
    end
end

function AMT_OpenPlannerFromEntry()
    if not m_IsOpen then ShowPopup(); end
end

function OnInputHandler(pInputStruct)
    local msg = pInputStruct:GetMessageType();
    local key = pInputStruct:GetKey();
    if msg == KeyEvents.KeyDown then
        if key == Keys.VK_ESCAPE and m_IsOpen then
            HidePopup();
            return true;
        end
    end
    return false;
end

function OnInputActionTriggered(actionId)
    if actionId == m_AutoPlanActionId then
        if m_IsOpen then HidePopup(); else ShowPopup(); end
    end
end

function AMT_Initialize()
    m_AutoPlanActionId = Input.GetActionId("AutoPlanMapTacks");
    Log("AMT_Initialize ActionId=" .. tostring(m_AutoPlanActionId));
    Controls.PopulationIcon:SetIcon("ICON_CITIZEN");

    ContextPtr:SetInputHandler(OnInputHandler, true);

    m_OverwriteCheck = Controls.OverwriteCheck;
    m_ClearCheck = Controls.ClearCheck;
    m_ClearManualCheck = Controls.ClearManualCheck;
    m_MultiCityCheck = Controls.MultiCityCheck;
    m_UndoButton = Controls.UndoButton;
    m_ResultText = Controls.ResultText;
    m_YieldFocusButtons = {
        YIELD_SCIENCE = {
            button = Controls.ScienceFocusButton,
            ignore = Controls.ScienceFocusIgnore,
        },
        YIELD_CULTURE = {
            button = Controls.CultureFocusButton,
            ignore = Controls.CultureFocusIgnore,
        },
        YIELD_GOLD = {
            button = Controls.GoldFocusButton,
            ignore = Controls.GoldFocusIgnore,
        },
        YIELD_FAITH = {
            button = Controls.FaithFocusButton,
            ignore = Controls.FaithFocusIgnore,
        },
        YIELD_PRODUCTION = {
            button = Controls.ProductionFocusButton,
            ignore = Controls.ProductionFocusIgnore,
        },
        YIELD_FOOD = {
            button = Controls.FoodFocusButton,
            ignore = Controls.FoodFocusIgnore,
        },
    };
    for yieldType, entry in pairs(m_YieldFocusButtons) do
        local selectedYield = yieldType;
        local button = entry and entry.button or entry;
        local function CycleYieldFocus()
            local state = m_YieldFocusStates[selectedYield] or 0;
            m_YieldFocusStates[selectedYield] =
                state == 0 and 1 or (state == 1 and -1 or 0);
            RefreshYieldFocusButtons();
            ClearSelectionFeedback();
        end
        if button then
            button:RegisterCallback(Mouse.eLClick, CycleYieldFocus);
        end
        if entry and entry.ignore then
            entry.ignore:RegisterCallback(
                Mouse.eLClick, CycleYieldFocus
            );
        end
    end
    if Controls.UniqueDirectionCheck then
        Controls.UniqueDirectionCheck:SetCheck(m_PrioritizeUnique);
        Controls.UniqueDirectionCheck:RegisterCheckHandler(function()
            m_PrioritizeUnique = Controls.UniqueDirectionCheck:IsChecked();
            local plan = GetCitySpecialtyPlan(GetSelectedCity());
            if plan then plan.prioritizeUnique = m_PrioritizeUnique; end
            RefreshPlannerItemGrid();
            ClearSelectionFeedback();
        end);
    end
    if Controls.PreservePlanningCheck then
        Controls.PreservePlanningCheck:SetCheck(m_EnablePreserve);
        Controls.PreservePlanningCheck:RegisterCheckHandler(function()
            m_EnablePreserve = Controls.PreservePlanningCheck:IsChecked();
            local currentPlan = GetCitySpecialtyPlan(GetSelectedCity());
            if currentPlan then
                currentPlan.enablePreserve = m_EnablePreserve;
            end
            if not m_EnablePreserve then
                for _, option in ipairs(
                    m_PlannerOptions[MAP_PIN_TYPE_DISTRICT] or {}
                ) do
                    if option.isPreserve then
                        m_SelectedSubjects[MAP_PIN_TYPE_DISTRICT]
                            [option.subjectKey] = false;
                        if currentPlan then
                            for index = 1,
                                tonumber(currentPlan.slotCount) or 0 do
                                if currentPlan.slots[index]
                                    == option.subjectKey then
                                    currentPlan.slots[index] = nil;
                                end
                            end
                        end
                    end
                end
            end
            RefreshSpecialtySelectionsForCurrentCity();
            RefreshPlannerItemGrid();
            ClearSelectionFeedback();
        end);
    end
    RefreshYieldFocusButtons();

    if Controls.RemoveSlotButton then
        Controls.RemoveSlotButton:RegisterCallback(Mouse.eLClick, function()
            local city = GetSelectedCity();
            local plan = GetCitySpecialtyPlan(city);
            local locked = plan and GetLockedSpecialtyDistricts(city) or {};
            if plan and plan.slotCount
                > math.max(MIN_SPECIALTY_SLOT_COUNT, #locked) then
                plan.slots[plan.slotCount] = nil;
                plan.slotCount = plan.slotCount - 1;
                RefreshSpecialtySelectionsForCurrentCity();
                RefreshPlannerItemGrid();
                ClearSelectionFeedback();
            end
        end);
    end
    if Controls.AddSlotButton then
        Controls.AddSlotButton:RegisterCallback(Mouse.eLClick, function()
            local plan = GetCitySpecialtyPlan(GetSelectedCity());
            if plan and plan.slotCount < MAX_SPECIALTY_SLOT_COUNT then
                plan.slotCount = plan.slotCount + 1;
                RefreshPlannerItemGrid();
                ClearSelectionFeedback();
            end
        end);
    end
    if Controls.RemovePopulationButton then
        Controls.RemovePopulationButton:RegisterCallback(
            Mouse.eLClick, function()
                local city = GetSelectedCity();
                local plan = GetCitySpecialtyPlan(city);
                local currentPopulation = math.max(
                    POPULATION_BUDGET_RANGE.minimum,
                    tonumber(city and city:GetPopulation())
                        or POPULATION_BUDGET_RANGE.minimum
                );
                if plan and plan.populationBudget > currentPopulation then
                    plan.populationBudget = plan.populationBudget - 1;
                    RefreshPlannerItemGrid();
                    ClearSelectionFeedback();
                end
            end
        );
    end
    if Controls.AddPopulationButton then
        Controls.AddPopulationButton:RegisterCallback(
            Mouse.eLClick, function()
                local plan = GetCitySpecialtyPlan(GetSelectedCity());
                if plan and plan.populationBudget
                    < POPULATION_BUDGET_RANGE.maximum then
                    plan.populationBudget = plan.populationBudget + 1;
                    RefreshPlannerItemGrid();
                    ClearSelectionFeedback();
                end
            end
        );
    end

    Controls.DistrictTabButton:RegisterCallback(Mouse.eLClick, function()
        SwitchPlannerCategory(MAP_PIN_TYPE_DISTRICT);
    end);
    Controls.ImprovementTabButton:RegisterCallback(Mouse.eLClick, function()
        SwitchPlannerCategory(MAP_PIN_TYPE_IMPROVEMENT);
    end);
    Controls.WonderTabButton:RegisterCallback(Mouse.eLClick, function()
        SwitchPlannerCategory(MAP_PIN_TYPE_WONDER);
    end);
    Controls.LongTermButton:RegisterCallback(Mouse.eLClick, function()
        ApplyCurrentCategoryPreset(false);
    end);
    Controls.CurrentBuildableButton:RegisterCallback(Mouse.eLClick, function()
        ApplyCurrentCategoryPreset(true);
    end);
    Controls.ClearCategoryButton:RegisterCallback(Mouse.eLClick, function()
        SetCurrentCategorySelection(false);
    end);
    if m_ClearCheck then
        m_ClearCheck:RegisterCheckHandler(function()
            local plan = GetCitySpecialtyPlan(GetSelectedCity());
            if plan then
                plan.clearBeforePlan = m_ClearCheck:IsChecked();
            end
            RefreshClearManualControl();
            ClearPendingPreview(true);
        end);
    end
    if m_ClearManualCheck then
        m_ClearManualCheck:RegisterCheckHandler(function()
            local plan = GetCitySpecialtyPlan(GetSelectedCity());
            if plan then
                plan.clearManualPins = m_ClearManualCheck:IsChecked();
            end
            ClearPendingPreview(true);
        end);
    end
    if m_OverwriteCheck then
        m_OverwriteCheck:RegisterCheckHandler(function()
            local plan = GetCitySpecialtyPlan(GetSelectedCity());
            if plan then
                plan.overwriteAutoPins = m_OverwriteCheck:IsChecked();
            end
            ClearPendingPreview(true);
        end);
    end
    if m_MultiCityCheck then
        m_MultiCityCheck:RegisterCheckHandler(function()
            ClearPendingPreview(true);
        end);
    end
    if Controls.PlanningCancelButton then
        Controls.PlanningCancelButton:RegisterCallback(
            Mouse.eLClick,
            function()
                if not m_IsPlanning then return; end
                m_QueuedPlan = nil;
                FinishPlanningUi();
                if m_ResultText then
                    m_ResultText:SetText(
                        Locale.Lookup("LOC_AMT_CALCULATION_CANCELLED")
                    );
                end
                Log("Planning cancelled by player.");
            end
        );
    end
    RefreshClearManualControl();

    if Controls.OneClickButton then
        Controls.OneClickButton:RegisterCallback(Mouse.eLClick, function()
            Log("High-adjacency specialty-district analysis requested.");
            OnHighAdjacencyAnalysis();
        end);
    else
        Log("WARN: OneClickButton not found.");
    end
    if Controls.OkButton then
        Controls.OkButton:RegisterCallback(Mouse.eLClick, function()
            Log("OK clicked.");
            OnPlan();
        end);
    else
        Log("WARN: OkButton not found.");
    end
    if Controls.CancelButton then
        Controls.CancelButton:RegisterCallback(Mouse.eLClick, function()
            Log("Cancel clicked.");
            HidePopup();
        end);
    else
        Log("WARN: CancelButton not found.");
    end
    if Controls.UndoButton then
        Controls.UndoButton:RegisterCallback(Mouse.eLClick, function()
            Log("Undo clicked.");
            OnUndoLastPlan();
        end);
        RefreshUndoButton(Game.GetLocalPlayer());
    else
        Log("WARN: UndoButton not found.");
    end
    if Controls.PreviewBackButton then
        Controls.PreviewBackButton:RegisterCallback(Mouse.eLClick, function()
            Log("Preview back clicked.");
            OnBackToSettings();
        end);
    end
    if Controls.PreviewConfirmButton then
        Controls.PreviewConfirmButton:RegisterCallback(Mouse.eLClick, function()
            Log("Preview confirm clicked.");
            OnConfirmPreview();
        end);
    end
    if Controls.PreviewCancelButton then
        Controls.PreviewCancelButton:RegisterCallback(Mouse.eLClick, function()
            Log("Preview cancel clicked.");
            HidePopup();
        end);
    end

    Events.InputActionTriggered.Add(OnInputActionTriggered);
    Events.ResearchCompleted.Add(AMT_OnProgressionChanged);
    Events.CivicCompleted.Add(AMT_OnProgressionChanged);
    LuaEvents.AMT_OpenPlanner.Add(AMT_OpenPlannerFromEntry);

    Log("AMT_Initialize DONE.");
end

print("[AMT] amt_autoplanner.lua LOAD END");
AMT_Initialize();
Log("Post-init sanity check complete.");
