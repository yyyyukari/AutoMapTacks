print("[AMT] amt_wonderplanner.lua LOAD START v58");

AMT_WonderPlanner = AMT_WonderPlanner or {};

local MAP_PIN_TYPE_DISTRICT = "DISTRICT";
local MAP_PIN_TYPE_IMPROVEMENT = "IMPROVEMENT";
local MAP_PIN_TYPE_WONDER = "WONDER";

local m_PlacementRules = {};
local m_ModifierArguments = nil;
local m_RequirementSets = nil;
local m_SpatialEffects = {};
local m_TerrainClasses = nil;
local m_DistrictReplacementBase = nil;

local function IsTrue(value)
    return value == true or value == 1 or value == "1";
end

local function PlotKey(x, y)
    return tostring(x) .. "_" .. tostring(y);
end

local function SplitCSV(value)
    local values = {};
    if value == nil then return values; end
    for part in string.gmatch(tostring(value), "[^,]+") do
        table.insert(values, part);
    end
    return values;
end

local function GetArguments(modifierId)
    if not m_ModifierArguments then
        m_ModifierArguments = {};
        if GameInfo.ModifierArguments then
            for row in GameInfo.ModifierArguments() do
                m_ModifierArguments[row.ModifierId] =
                    m_ModifierArguments[row.ModifierId] or {};
                m_ModifierArguments[row.ModifierId][row.Name] = row.Value;
            end
        end
    end
    return m_ModifierArguments[modifierId] or {};
end

local function GetRequirementSet(requirementSetId)
    if not requirementSetId then return nil; end
    if not m_RequirementSets then
        m_RequirementSets = {};
        local arguments = {};
        if GameInfo.RequirementArguments then
            for row in GameInfo.RequirementArguments() do
                arguments[row.RequirementId] =
                    arguments[row.RequirementId] or {};
                arguments[row.RequirementId][row.Name] = row.Value;
            end
        end
        local setTypes = {};
        if GameInfo.RequirementSets then
            for row in GameInfo.RequirementSets() do
                setTypes[row.RequirementSetId] = row.RequirementSetType;
            end
        end
        if GameInfo.RequirementSetRequirements then
            for row in GameInfo.RequirementSetRequirements() do
                local requirement = GameInfo.Requirements
                    and GameInfo.Requirements[row.RequirementId] or nil;
                if requirement then
                    local set = m_RequirementSets[row.RequirementSetId] or {
                        setType = setTypes[row.RequirementSetId],
                        requirements = {},
                    };
                    table.insert(set.requirements, {
                        requirementType = requirement.RequirementType,
                        inverse = IsTrue(requirement.Inverse),
                        arguments = arguments[row.RequirementId] or {},
                    });
                    m_RequirementSets[row.RequirementSetId] = set;
                end
            end
        end
    end
    return m_RequirementSets[requirementSetId];
end

local function GetPlotTypes(plot, projectedSubjects)
    local terrain = plot and GameInfo.Terrains[plot:GetTerrainType()] or nil;
    local featureIndex = plot and plot:GetFeatureType() or -1;
    local feature = featureIndex and featureIndex >= 0
        and GameInfo.Features[featureIndex] or nil;
    local improvementIndex = plot and plot:GetImprovementType() or -1;
    local improvement = improvementIndex and improvementIndex >= 0
        and GameInfo.Improvements[improvementIndex] or nil;
    local resourceIndex = plot and plot:GetResourceType() or -1;
    local resource = resourceIndex and resourceIndex >= 0
        and GameInfo.Resources[resourceIndex] or nil;
    local subject = plot and projectedSubjects
        and projectedSubjects[PlotKey(plot:GetX(), plot:GetY())] or nil;
    if subject then
        if subject.subjectType == MAP_PIN_TYPE_IMPROVEMENT
            or subject.Type == MAP_PIN_TYPE_IMPROVEMENT then
            improvement = GameInfo.Improvements[
                subject.subjectKey or subject.Key
            ];
        elseif subject.subjectType == MAP_PIN_TYPE_DISTRICT
            or subject.subjectType == MAP_PIN_TYPE_WONDER
            or subject.Type == MAP_PIN_TYPE_DISTRICT
            or subject.Type == MAP_PIN_TYPE_WONDER then
            feature = nil;
            improvement = nil;
        end
    end
    return terrain, feature, improvement, resource;
end

local function TerrainMatchesClass(terrain, terrainClassType)
    if not terrain or not terrainClassType then return false; end
    if not m_TerrainClasses then
        m_TerrainClasses = {};
        if GameInfo.TerrainClass_Terrains then
            for row in GameInfo.TerrainClass_Terrains() do
                m_TerrainClasses[row.TerrainClassType] =
                    m_TerrainClasses[row.TerrainClassType] or {};
                m_TerrainClasses[row.TerrainClassType][row.TerrainType] = true;
            end
        end
    end
    return m_TerrainClasses[terrainClassType]
        and m_TerrainClasses[terrainClassType][terrain.TerrainType] == true;
end

local function RequirementMatches(requirement, plot, projectedSubjects)
    local requirementType = requirement.requirementType;
    local arguments = requirement.arguments or {};
    local terrain, feature, improvement, resource =
        GetPlotTypes(plot, projectedSubjects);
    local result = nil;
    if requirementType == "REQUIREMENT_PLOT_TERRAIN_TYPE_MATCHES" then
        result = terrain and terrain.TerrainType == arguments.TerrainType;
    elseif requirementType == "REQUIREMENT_PLOT_TERRAIN_CLASS_MATCHES" then
        result = TerrainMatchesClass(terrain, arguments.TerrainClass);
    elseif requirementType == "REQUIREMENT_PLOT_FEATURE_TYPE_MATCHES" then
        result = feature and feature.FeatureType == arguments.FeatureType;
    elseif requirementType == "REQUIREMENT_PLOT_IMPROVEMENT_TYPE_MATCHES" then
        result = improvement
            and improvement.ImprovementType == arguments.ImprovementType;
    elseif requirementType == "REQUIREMENT_PLOT_RESOURCE_TYPE_MATCHES" then
        result = resource and resource.ResourceType == arguments.ResourceType;
    elseif requirementType == "REQUIREMENT_PLOT_RESOURCE_CLASS_TYPE_MATCHES" then
        result = resource
            and resource.ResourceClassType == arguments.ResourceClassType;
    elseif requirementType == "REQUIREMENT_PLOT_IS_HILLS" then
        result = plot and plot:IsHills();
    elseif requirementType == "REQUIREMENT_PLOT_ADJACENT_TO_RIVER" then
        result = plot and plot:IsRiver();
    elseif requirementType == "REQUIREMENT_DISTRICT_TYPE_MATCHES" then
        local subject = plot and projectedSubjects
            and projectedSubjects[PlotKey(plot:GetX(), plot:GetY())] or nil;
        local districtType = subject
            and (subject.subjectKey or subject.Key) or nil;
        if not districtType and plot then
            local districtIndex = plot:GetDistrictType();
            local district = districtIndex and districtIndex >= 0
                and GameInfo.Districts[districtIndex] or nil;
            districtType = district and district.DistrictType or nil;
        end
        result = districtType == arguments.DistrictType;
    elseif requirementType == "REQUIREMENT_CITY_HAS_BUILDING" then
        -- A selected wonder is evaluated as hypothetically completed.
        result = true;
    else
        -- Unknown requirements are deliberately conservative: their effect is
        -- not scored, while the wonder may still be planned by standard rules.
        result = false;
    end
    if requirement.inverse then result = not result; end
    return result == true;
end

local function RequirementSetMatches(requirementSetId, plot, projectedSubjects)
    if not requirementSetId then return true; end
    local set = GetRequirementSet(requirementSetId);
    if not set or #set.requirements == 0 then return false; end
    local testAny = set.setType == "REQUIREMENTSET_TEST_ANY";
    for _, requirement in ipairs(set.requirements) do
        local matches = RequirementMatches(
            requirement, plot, projectedSubjects
        );
        if testAny and matches then return true; end
        if not testAny and not matches then return false; end
    end
    return not testAny;
end

local function ExpandModifier(modifierId, effects, seen, cityScoped)
    if not modifierId or seen[modifierId] then return; end
    seen[modifierId] = true;
    local modifier = GameInfo.Modifiers and GameInfo.Modifiers[modifierId] or nil;
    if not modifier then return; end
    local dynamic = GameInfo.DynamicModifiers
        and GameInfo.DynamicModifiers[modifier.ModifierType] or nil;
    if not dynamic then return; end
    local args = GetArguments(modifierId);
    if dynamic.EffectType == "EFFECT_ATTACH_MODIFIER" then
        ExpandModifier(args.ModifierId, effects, seen, true);
        return;
    end
    local supported = dynamic.EffectType == "EFFECT_ADJUST_PLOT_YIELD"
        or dynamic.EffectType == "EFFECT_ADJUST_CITY_APPEAL"
        or dynamic.EffectType == "EFFECT_ADJUST_CITY_YIELD_MODIFIER"
        or dynamic.EffectType == "EFFECT_DISTRICT_ADJACENCY"
        or dynamic.EffectType == "EFFECT_FEATURE_ADJACENCY"
        or dynamic.EffectType == "EFFECT_IMPROVEMENT_ADJACENCY"
        or dynamic.EffectType == "EFFECT_TERRAIN_ADJACENCY"
        or dynamic.EffectType == "EFFECT_RIVER_ADJACENCY";
    if supported then
        table.insert(effects, {
            modifierId = modifierId,
            effectType = dynamic.EffectType,
            collectionType = dynamic.CollectionType,
            arguments = args,
            requirementSetId = modifier.SubjectRequirementSetId,
            cityScoped = cityScoped == true
                or dynamic.CollectionType == "COLLECTION_OWNER"
                or dynamic.CollectionType == "COLLECTION_CITY_PLOT_YIELDS",
        });
    end
end

function AMT_WonderPlanner.Reset()
    m_PlacementRules = {};
    m_ModifierArguments = nil;
    m_RequirementSets = nil;
    m_SpatialEffects = {};
    m_TerrainClasses = nil;
    m_DistrictReplacementBase = nil;
end

function AMT_WonderPlanner.GetPlacementRules(wonderType)
    if m_PlacementRules[wonderType] then
        return m_PlacementRules[wonderType];
    end
    local row = GameInfo.Buildings and GameInfo.Buildings[wonderType] or nil;
    local rules = {
        row = row,
        adjacentDistrict = row and row.AdjacentDistrict or nil,
        adjacentImprovement = row and row.AdjacentImprovement or nil,
    };
    rules.hasDeferredRequirement = rules.adjacentDistrict ~= nil
        or rules.adjacentImprovement ~= nil;
    m_PlacementRules[wonderType] = rules;
    return rules;
end

function AMT_WonderPlanner.GetSpatialEffects(wonderType)
    if m_SpatialEffects[wonderType] then
        return m_SpatialEffects[wonderType];
    end
    local effects = {};
    if GameInfo.BuildingModifiers then
        for row in GameInfo.BuildingModifiers() do
            if row.BuildingType == wonderType then
                ExpandModifier(row.ModifierId, effects, {}, false);
            end
        end
    end
    m_SpatialEffects[wonderType] = effects;
    return effects;
end

function AMT_WonderPlanner.CanUseRawCandidate(playerID, item)
    local rules = AMT_WonderPlanner.GetPlacementRules(item.subjectKey);
    local subject = {
        X = item.x,
        Y = item.y,
        Key = item.subjectKey,
        Type = MAP_PIN_TYPE_WONDER,
    };
    -- Wonders without relational requirements can be checked directly.  A
    -- wonder requiring an adjacent district/improvement must keep candidates
    -- whose base tile is legal; the complete pair is checked later by DMT in
    -- the planner's simulation overlay.
    if not rules.hasDeferredRequirement then
        local ok, canPlace = pcall(CanPlacePin, playerID, subject);
        return ok and canPlace == true, false;
    end
    if not rules.row or not item.plot then
        return false, false;
    end

    local plot = item.plot;
    local terrainType, featureType, _, wonderType, districtType, resourceType =
        GetPlotFeatureTypes(plot, playerID);
    local directive = AMT_PlotDirectives
        and AMT_PlotDirectives[PlotKey(item.x, item.y)] or nil;
    if directive then
        if directive.removeFeature then featureType = nil; end
        if directive.plantForest then featureType = "FEATURE_FOREST"; end
        if directive.removeResource then resourceType = nil; end
    end
    if districtType or wonderType then return false, false; end
    if resourceType and IsResourceVisible(playerID, resourceType)
        and not CanHarvestResource(resourceType) then
        return false, false;
    end
    local featureOK, validFeature = pcall(
        CanPlaceOnFeature, MAP_PIN_TYPE_WONDER,
        item.subjectKey, featureType
    );
    if featureOK and not validFeature then return false, false; end
    local terrainOK, validTerrain = pcall(
        CanPlaceOnTerrain, MAP_PIN_TYPE_WONDER,
        item.subjectKey, terrainType
    );
    if terrainOK and not validTerrain then return false, false; end

    local row = rules.row;
    if IsTrue(row.RequiresRiver)
        and not IsAdjacentToRiver(playerID, item.x, item.y) then
        return false, false;
    end
    if row.AdjacentResource
        and not IsAdjacentToResource(
            playerID, item.x, item.y, row.AdjacentResource
        ) then
        return false, false;
    end
    if IsTrue(row.Coast)
        and (IsTerrainWater(terrainType)
            or not IsAdjacentToCoast(playerID, item.x, item.y)) then
        return false, false;
    end
    if IsTrue(row.MustBeAdjacentLand)
        and not (terrainType == "TERRAIN_COAST"
            and IsAdjacentToLandPlot(playerID, item.x, item.y)) then
        return false, false;
    end
    if IsTrue(row.MustBeLake)
        and not IsOnLake(playerID, item.x, item.y) then
        return false, false;
    end
    if IsTrue(row.MustNotBeLake)
        and IsOnLake(playerID, item.x, item.y) then
        return false, false;
    end
    if IsTrue(row.AdjacentToMountain)
        and not IsAdjacentToMountain(playerID, item.x, item.y) then
        return false, false;
    end
    if IsTrue(row.AdjacentCapital)
        and not IsAdjacentToCapital(playerID, item.x, item.y) then
        return false, false;
    end
    if row.BuildingType == "BUILDING_HALICARNASSUS_MAUSOLEUM"
        and IsTerrainWater(terrainType) then
        return false, false;
    end
    if row.BuildingType == "BUILDING_GOLDEN_GATE_BRIDGE"
        or row.BuildingType == "BUILDING_TOWER_BRIDGE" then
        if not IsValidBridgePosition(playerID, item.x, item.y) then
            return false, false;
        end
    end
    return true, rules.hasDeferredRequirement;
end

local function GetDistrictReplacementBase(districtType)
    if not districtType then return nil; end
    if not m_DistrictReplacementBase then
        m_DistrictReplacementBase = {};
        if GameInfo.DistrictReplaces then
            for row in GameInfo.DistrictReplaces() do
                if row.CivUniqueDistrictType
                    and row.ReplacesDistrictType then
                    m_DistrictReplacementBase[row.CivUniqueDistrictType] =
                        row.ReplacesDistrictType;
                end
            end
        end
    end
    return m_DistrictReplacementBase[districtType];
end

local function DistrictMatches(districtType, targetType)
    return districtType == targetType
        or GetDistrictReplacementBase(districtType) == targetType;
end

local function GetSubjectCityID(subject, plot)
    local cityID = subject
        and (subject.cityID or subject.CityID) or nil;
    if cityID ~= nil then return cityID; end
    if plot and Cities and Cities.GetPlotPurchaseCity then
        local ok, city = pcall(Cities.GetPlotPurchaseCity, plot);
        if ok and city then return city:GetID(); end
    end
    return nil;
end

local function BuildProjectedSubjects(items, fixedSubjects)
    local subjects = {};
    for _, subject in ipairs(fixedSubjects or {}) do
        subjects[PlotKey(subject.X, subject.Y)] = subject;
    end
    for _, item in ipairs(items or {}) do
        subjects[PlotKey(item.x, item.y)] = item;
    end
    return subjects;
end

function AMT_WonderPlanner.RelationalRequirementsMet(
    wonderItem, items, fixedSubjects
)
    local rules = AMT_WonderPlanner.GetPlacementRules(
        wonderItem.subjectKey
    );
    if not rules.hasDeferredRequirement then return true; end
    local subjects = BuildProjectedSubjects(items, fixedSubjects);
    local foundDistrict = rules.adjacentDistrict == nil;
    local foundImprovement = rules.adjacentImprovement == nil;
    for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
        local plot = Map.GetAdjacentPlot(
            wonderItem.x, wonderItem.y, direction
        );
        if plot then
            local subject = subjects[PlotKey(plot:GetX(), plot:GetY())];
            local subjectType = subject
                and (subject.subjectType or subject.Type) or nil;
            local subjectKey = subject
                and (subject.subjectKey or subject.Key) or nil;
            if not subject then
                local districtIndex = plot:GetDistrictType();
                if districtIndex and districtIndex >= 0 then
                    local row = GameInfo.Districts[districtIndex];
                    subjectType = MAP_PIN_TYPE_DISTRICT;
                    subjectKey = row and row.DistrictType or nil;
                else
                    local improvementIndex = plot:GetImprovementType();
                    if improvementIndex and improvementIndex >= 0 then
                        local row = GameInfo.Improvements[improvementIndex];
                    subjectType = MAP_PIN_TYPE_IMPROVEMENT;
                        subjectKey = row and row.ImprovementType or nil;
                    end
                end
            end
            local sameCity = GetSubjectCityID(subject, plot)
                == wonderItem.cityID;
            if sameCity and subjectType == MAP_PIN_TYPE_DISTRICT
                and DistrictMatches(subjectKey, rules.adjacentDistrict) then
                foundDistrict = true;
            end
            if sameCity and subjectType == MAP_PIN_TYPE_IMPROVEMENT
                and subjectKey == rules.adjacentImprovement then
                foundImprovement = true;
            end
        end
    end
    return foundDistrict and foundImprovement;
end

function AMT_WonderPlanner.GetMissingSupports(
    wonderItem, items, fixedSubjects
)
    local rules = AMT_WonderPlanner.GetPlacementRules(
        wonderItem.subjectKey
    );
    if not rules.hasDeferredRequirement then return nil, nil; end
    local subjects = BuildProjectedSubjects(items, fixedSubjects);
    local foundDistrict = rules.adjacentDistrict == nil;
    local foundImprovement = rules.adjacentImprovement == nil;
    for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
        local plot = Map.GetAdjacentPlot(
            wonderItem.x, wonderItem.y, direction
        );
        if plot then
            local subject = subjects[PlotKey(plot:GetX(), plot:GetY())];
            local subjectType = subject
                and (subject.subjectType or subject.Type) or nil;
            local subjectKey = subject
                and (subject.subjectKey or subject.Key) or nil;
            if not subject then
                local districtIndex = plot:GetDistrictType();
                if districtIndex and districtIndex >= 0 then
                    local row = GameInfo.Districts[districtIndex];
                    subjectType = MAP_PIN_TYPE_DISTRICT;
                    subjectKey = row and row.DistrictType or nil;
                else
                    local improvementIndex = plot:GetImprovementType();
                    if improvementIndex and improvementIndex >= 0 then
                        local row = GameInfo.Improvements[improvementIndex];
                    subjectType = MAP_PIN_TYPE_IMPROVEMENT;
                        subjectKey = row and row.ImprovementType or nil;
                    end
                end
            end
            local sameCity = GetSubjectCityID(subject, plot)
                == wonderItem.cityID;
            if sameCity and subjectType == MAP_PIN_TYPE_DISTRICT
                and DistrictMatches(subjectKey, rules.adjacentDistrict) then
                foundDistrict = true;
            end
            if sameCity and subjectType == MAP_PIN_TYPE_IMPROVEMENT
                and subjectKey == rules.adjacentImprovement then
                foundImprovement = true;
            end
        end
    end
    return foundDistrict and nil or rules.adjacentDistrict,
        foundImprovement and nil or rules.adjacentImprovement;
end

local function EffectAppliesToCity(effect, wonderItem, cityID)
    if effect.cityScoped then return cityID == wonderItem.cityID; end
    return true;
end

function AMT_WonderPlanner.GetSelectedAppealDelta(
    plot, items, fixedSubjects
)
    if not plot then return 0; end
    local cityID = GetSubjectCityID(nil, plot);
    if cityID == nil then return 0; end
    local delta = 0;
    for _, item in ipairs(items or {}) do
        if item.subjectType == MAP_PIN_TYPE_WONDER then
            for _, effect in ipairs(
                AMT_WonderPlanner.GetSpatialEffects(item.subjectKey)
            ) do
                if effect.effectType == "EFFECT_ADJUST_CITY_APPEAL"
                    and EffectAppliesToCity(effect, item, cityID) then
                    delta = delta
                        + (tonumber(effect.arguments.Amount) or 0);
                end
            end
        end
    end
    return delta;
end

local function AddEffectYields(effect, target)
    local yieldTypes = SplitCSV(effect.arguments.YieldType);
    local amounts = SplitCSV(effect.arguments.Amount);
    for index, yieldType in ipairs(yieldTypes) do
        target[yieldType] = (target[yieldType] or 0)
            + (tonumber(amounts[index] or amounts[1]) or 0);
    end
end

local function ScoreAdjacencyEffect(
    effect, wonderItem, subject, projectedSubjects, weights
)
    local subjectType = subject.subjectType or subject.Type;
    local subjectKey = subject.subjectKey or subject.Key;
    if subjectType ~= MAP_PIN_TYPE_DISTRICT
        or not DistrictMatches(
            subjectKey, effect.arguments.DistrictType
        ) then
        return 0;
    end
    local x = subject.x or subject.X;
    local y = subject.y or subject.Y;
    local plot = x and y and Map.GetPlot(x, y) or nil;
    local cityID = GetSubjectCityID(subject, plot);
    if not plot or not EffectAppliesToCity(
        effect, wonderItem, cityID
    ) or not RequirementSetMatches(
        effect.requirementSetId, plot, projectedSubjects
    ) then
        return 0;
    end
    local matches = 0;
    if effect.effectType == "EFFECT_RIVER_ADJACENCY" then
        matches = plot:IsRiver() and 1 or 0;
    else
        for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
            local adjacentPlot = Map.GetAdjacentPlot(x, y, direction);
            if adjacentPlot then
                local adjacentSubject = projectedSubjects[
                    PlotKey(adjacentPlot:GetX(), adjacentPlot:GetY())
                ];
                local adjacentType = adjacentSubject and (
                    adjacentSubject.subjectType or adjacentSubject.Type
                ) or nil;
                local terrain, feature, improvement = GetPlotTypes(
                    adjacentPlot, projectedSubjects
                );
                if effect.effectType == "EFFECT_DISTRICT_ADJACENCY"
                    and (adjacentType == MAP_PIN_TYPE_DISTRICT
                        or adjacentType == MAP_PIN_TYPE_WONDER
                        or (not adjacentSubject
                            and adjacentPlot:GetDistrictType() >= 0)) then
                    matches = matches + 1;
                elseif effect.effectType == "EFFECT_FEATURE_ADJACENCY"
                    and feature and feature.FeatureType
                        == effect.arguments.FeatureType then
                    matches = matches + 1;
                elseif effect.effectType == "EFFECT_IMPROVEMENT_ADJACENCY"
                    and improvement and improvement.ImprovementType
                        == effect.arguments.ImprovementType then
                    matches = matches + 1;
                elseif effect.effectType == "EFFECT_TERRAIN_ADJACENCY"
                    and terrain and terrain.TerrainType
                        == effect.arguments.TerrainType then
                    matches = matches + 1;
                end
            end
        end
    end
    local tilesRequired = math.max(
        1, tonumber(effect.arguments.TilesRequired) or 1
    );
    local amount = tonumber(effect.arguments.Amount) or 0;
    local yieldType = effect.arguments.YieldType;
    return math.floor(matches / tilesRequired) * amount
        * (weights[yieldType] or 1);
end

function AMT_WonderPlanner.ScoreSelectedSpatialEffects(
    playerID, items, fixedSubjects, weights, getCityPlots
)
    local player = Players[playerID];
    if not player then return 0; end
    local projectedSubjects = BuildProjectedSubjects(items, fixedSubjects);
    local total = 0;
    for _, wonderItem in ipairs(items or {}) do
        if wonderItem.subjectType == MAP_PIN_TYPE_WONDER
            and wonderItem.subjectKey ~= "DISTRICT_WONDER" then
            local wonderCity = player:GetCities():FindID(wonderItem.cityID);
            if wonderCity then
                for _, effect in ipairs(
                    AMT_WonderPlanner.GetSpatialEffects(wonderItem.subjectKey)
                ) do
                    if effect.effectType == "EFFECT_ADJUST_PLOT_YIELD" then
                        local effectYields = {};
                        AddEffectYields(effect, effectYields);
                        local plots = getCityPlots and getCityPlots(wonderCity)
                            or {};
                        for _, plot in ipairs(plots) do
                            if RequirementSetMatches(
                                effect.requirementSetId,
                                plot,
                                projectedSubjects
                            ) then
                                local subject = projectedSubjects[
                                    PlotKey(plot:GetX(), plot:GetY())
                                ];
                                local occupied = subject and (
                                    subject.subjectType == MAP_PIN_TYPE_DISTRICT
                                    or subject.subjectType == MAP_PIN_TYPE_WONDER
                                    or subject.Type == MAP_PIN_TYPE_DISTRICT
                                    or subject.Type == MAP_PIN_TYPE_WONDER
                                );
                                if not occupied then
                                    local workFactor = plot:GetWorkerCount() > 0
                                        and 1 or 0.35;
                                    for yieldType, amount in pairs(effectYields) do
                                        total = total + amount
                                            * (weights[yieldType] or 1)
                                            * workFactor;
                                    end
                                end
                            end
                        end
                    elseif effect.effectType
                        == "EFFECT_ADJUST_CITY_YIELD_MODIFIER" then
                        local yieldType = effect.arguments.YieldType;
                        local yieldRow = yieldType
                            and GameInfo.Yields[yieldType] or nil;
                        if yieldRow then
                            local currentYield = wonderCity:GetYield(
                                yieldRow.Index
                            );
                            total = total + (tonumber(currentYield) or 0)
                                * (tonumber(effect.arguments.Amount) or 0)
                                / 100
                                * (weights[yieldType] or 1);
                        end
                    elseif effect.effectType == "EFFECT_DISTRICT_ADJACENCY"
                        or effect.effectType == "EFFECT_FEATURE_ADJACENCY"
                        or effect.effectType
                            == "EFFECT_IMPROVEMENT_ADJACENCY"
                        or effect.effectType == "EFFECT_TERRAIN_ADJACENCY"
                        or effect.effectType == "EFFECT_RIVER_ADJACENCY" then
                        for _, subject in pairs(projectedSubjects) do
                            total = total + ScoreAdjacencyEffect(
                                effect, wonderItem, subject,
                                projectedSubjects, weights
                            );
                        end
                    end
                end
            end
        end
    end
    return total;
end
