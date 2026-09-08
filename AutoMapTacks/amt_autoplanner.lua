-- Production modules retain separate lexical scopes and protected loading.
AMT_BundledModules = {};
AMT_BundledModules["amt_mc_bootstrap"] = function()


    -- Multi-city bootstrap module.
    --
    -- This module declares the AMT_MultiCity contract and the isolated state key
    -- names.  M2 capabilities: the entry button and the dry-run snapshot panel
    -- are enabled; apply remains disabled (no pin placement before M3 review).
    -- The single-city path stays the only path that places or removes pins.

    AMT_MultiCity = AMT_MultiCity or {};

    AMT_MultiCity.schemaVersion = 1;

    -- Isolated state key contract.  The first two keys are owned by the existing
    -- single-city path inside the test package; CLUSTER_STATE is reserved for
    -- later milestones; SETTINGS stores only player-confirmed per-city profiles.
    -- Drafts remain session-only; M2 never writes cluster or transaction state.
    AMT_MultiCity.StateKeys = {
        AUTO_PINS = "AMT_AUTO_PINS_V1",
        LAST_TRANSACTION = "AMT_LAST_PLAN_V1",
        CLUSTER_STATE = "AMT_LINKED_CLUSTER_STATE_V1",
        SETTINGS = "AMT_LINKED_SETTINGS_V1",
    };

    -- M7 capability contract: entry, dry-run snapshots, the joint preview
    -- solver, and the atomic multi-city apply/undo are enabled.  Apply only
    -- activates from the selected-plan PlanDiff confirmation.
    AMT_MultiCity.CURRENT_CAPABILITIES = {
        entryEnabled = true,
        dryRunEnabled = true,
        applyEnabled = true,
        selectionEnabled = true,
        perCitySettingsEnabled = true,
        scopeConfirmationEnabled = true,
        jointPreviewEnabled = true,
    };

    function AMT_MultiCity.GetCapabilities()
        return {
            schemaVersion = AMT_MultiCity.schemaVersion,
            entryEnabled = AMT_MultiCity.CURRENT_CAPABILITIES.entryEnabled,
            dryRunEnabled = AMT_MultiCity.CURRENT_CAPABILITIES.dryRunEnabled,
            applyEnabled = AMT_MultiCity.CURRENT_CAPABILITIES.applyEnabled,
            selectionEnabled = AMT_MultiCity.CURRENT_CAPABILITIES.selectionEnabled,
            perCitySettingsEnabled =
                AMT_MultiCity.CURRENT_CAPABILITIES.perCitySettingsEnabled,
            scopeConfirmationEnabled =
                AMT_MultiCity.CURRENT_CAPABILITIES.scopeConfirmationEnabled,
            jointPreviewEnabled =
                AMT_MultiCity.CURRENT_CAPABILITIES.jointPreviewEnabled,
        };
    end

    -- Multi-city is never routed to through the legacy OnPlan gate: M3 solves
    -- from the scope-confirmation branch (AMT_MC_ConfirmScope).  This gate must
    -- keep returning false so the original single-city path stays byte-identical.
    function AMT_MultiCity.ShouldRoutePreview(isChecked)
        return false;
    end

    -- Protected-load handshake: the entry file calls this after a successful
    -- include.  Returning false marks the module unavailable; the entry must then
    -- hide the multi-city button while the single-city path stays available.
    function AMT_MultiCity.Initialize()
        local capabilities = AMT_MultiCity.GetCapabilities();
        if capabilities == nil
            or capabilities.schemaVersion ~= AMT_MultiCity.schemaVersion then
            return false;
        end
        return true;
    end



end;
AMT_BundledModules["amt_mc_contract"] = function()



    -- M2 data contract module (pure logic, no game API).
    --
    -- Provides:
    --   * ClusterSnapshot schema constants and validation
    --   * deterministic serialization + stable signatures (arrays/sets sorted
    --     before hashing)
    --   * assertions for debugging (disabled in release profiles)
    --
    -- City names are display-only and never participate in identity or hashing.
    -- Every collection is sorted into a stable order before it is serialized.

    AMT_MultiCity = AMT_MultiCity or {};
    AMT_MultiCity.Contract = AMT_MultiCity.Contract or {};

    local Contract = AMT_MultiCity.Contract;

    Contract.SCHEMA_VERSION = 3;
    Contract.RUN_ID_LENGTH = 8;

    -- ---------------------------------------------------------------------------
    -- Deterministic string hashing (FNV-1a 32-bit).  Lua 5.1 has no native
    -- hashing; this is stable across runs and platforms.  XOR is implemented
    -- arithmetically so it works without the optional `bit` library.
    -- ---------------------------------------------------------------------------
    local function Bxor32(a, b)
        local result = 0;
        local bitval = 1;
        a = math.floor(a);
        b = math.floor(b);
        while a > 0 or b > 0 do
            if (a % 2) ~= (b % 2) then
                result = result + bitval;
            end
            bitval = bitval * 2;
            a = math.floor(a / 2);
            b = math.floor(b / 2);
        end
        return result;
    end

    -- FNV-1a multiply by 0x01000193 mod 2^32.  A direct `hash * 16777619`
    -- exceeds the exact double range (2^53) once hash is large, which collapsed
    -- candidate IDs to 0x80000000 in real saves; split both factors into 16-bit
    -- halves so every intermediate stays exactly representable.
    local FNV_PRIME_LOW = 0x0193;   -- 403
    local FNV_PRIME_HIGH = 0x0100;  -- 256

    local function FnvPrimeMod(hash)
        local low = hash % 65536;
        local high = math.floor(hash / 65536);
        local termLow = (low * FNV_PRIME_LOW) % 4294967296;
        local termCrossLow = ((low * FNV_PRIME_HIGH) % 65536) * 65536;
        local termCrossHigh = ((high * FNV_PRIME_LOW) % 65536) * 65536;
        return (termLow + termCrossLow + termCrossHigh) % 4294967296;
    end

    -- FNV-1a performance path (PERFORMANCE_UX_EXECUTION_PLAN 搜索等待批次).
    -- Profiling the r34 sample showed the per-byte Bxor32 loop dominating the
    -- solve (~90% of replay time): each hash step XORs the full 32-bit state
    -- with a single byte, so only the low 8 bits of the hash ever change.  Two
    -- 4-bit lookup tables (256 entries, built once) resolve that byte XOR with
    -- four table reads instead of a 32-iteration arithmetic loop, and the byte
    -- chain is fetched four bytes per iteration.  Byte order and every multiply
    -- stay exactly FNV-1a; results are identical to Bxor32 for byte-sized
    -- operands, cross-checked against the independent Python reference in the
    -- offline tests.
    local NIBBLE_XOR = {};
    do
        for a = 0, 15 do
            local row = {};
            for b = 0, 15 do
                local result = 0;
                local bitval = 1;
                local x, y = a, b;
                for _ = 1, 4 do
                    if (x % 2) ~= (y % 2) then
                        result = result + bitval;
                    end
                    bitval = bitval * 2;
                    x = (x - x % 2) / 2;
                    y = (y - y % 2) / 2;
                end
                row[b + 1] = result;
            end
            NIBBLE_XOR[a + 1] = row;
        end
    end

    local function BxorHashLowByte(hash, byte)
        -- hash is any exact 32-bit value; byte is 0..255.  Only the low 8 bits
        -- of the hash participate in the XOR.
        local low = hash % 256;
        return hash - low
            + NIBBLE_XOR[low % 16 + 1][byte % 16 + 1]
            + NIBBLE_XOR[(low - low % 16) / 16 + 1]
                [(byte - byte % 16) / 16 + 1] * 16;
    end

    local function Fnv1a(text)
        -- Same byte chain as the reference loop below (XOR byte, then multiply
        -- by the FNV prime), fetched four bytes per iteration.  Values are
        -- identical to Bxor32/hash semantics; only the call structure changed.
        local hash = 2166136261;
        local length = #text;
        local index = 1;
        while index + 3 <= length do
            local b1, b2, b3, b4 = string.byte(text, index, index + 3);
            hash = FnvPrimeMod(BxorHashLowByte(hash, b1));
            hash = FnvPrimeMod(BxorHashLowByte(hash, b2));
            hash = FnvPrimeMod(BxorHashLowByte(hash, b3));
            hash = FnvPrimeMod(BxorHashLowByte(hash, b4));
            index = index + 4;
        end
        while index <= length do
            hash = FnvPrimeMod(
                BxorHashLowByte(hash, string.byte(text, index)));
            index = index + 1;
        end
        return hash;
    end

    local HEX_DIGITS = "0123456789ABCDEF";

    local function ToHex(value)
        -- Civ VI's string.format mishandles %x/%X for values with the high bit
        -- set (observed: every such hash printed as "80000000"), so format the
        -- eight hex digits arithmetically.  All intermediates stay below 2^53.
        value = math.floor(value) % 4294967296;
        local chars = {};
        local divisor = 268435456;
        for index = 1, 8 do
            local digit = math.floor(value / divisor) % 16;
            chars[index] = string.sub(HEX_DIGITS, digit + 1, digit + 1);
            divisor = divisor / 16;
        end
        return table.concat(chars);
    end

    -- Pure primitives exported for offline tests (same exact FNV as the debug
    -- export checksum; keep them in sync).
    Contract.Fnv1a = Fnv1a;
    Contract.ToHex = ToHex;

    -- ---------------------------------------------------------------------------
    -- Stable ordering helpers.
    -- ---------------------------------------------------------------------------
    local function CompareStrings(a, b)
        if a == b then return false; end
        if a == nil then return true; end
        if b == nil then return false; end
        if type(a) ~= type(b) then return type(a) < type(b); end
        return a < b;
    end

    function Contract.SortedKeys(tableValue)
        local keys = {};
        for k in pairs(tableValue or {}) do
            table.insert(keys, k);
        end
        table.sort(keys, CompareStrings);
        return keys;
    end

    -- Copies an array and sorts a copy (never mutates the input).
    function Contract.SortedArray(values, comparator)
        local copy = {};
        for i = 1, #(values or {}) do
            copy[i] = values[i];
        end
        table.sort(copy, comparator or CompareStrings);
        return copy;
    end

    -- ---------------------------------------------------------------------------
    -- Serialization: deterministic, unambiguous, no pretty-printing.
    -- ---------------------------------------------------------------------------
    local function Serialize(value)
        local t = type(value);
        if t == "nil" then
            return "n";
        elseif t == "boolean" then
            return value and "b1" or "b0";
        elseif t == "number" then
            if value == math.floor(value) then
                return "d" .. tostring(math.floor(value));
            end
            return "d" .. string.format("%.4f", value);
        elseif t == "string" then
            return "s" .. #value .. ":" .. value;
        elseif t == "table" then
            -- Arrays: ordered list.  Maps: sorted keys.
            local isArray = true;
            local count = 0;
            for k in pairs(value) do
                if type(k) ~= "number" or k < 1 or k > #value
                    or math.floor(k) ~= k then
                    isArray = false;
                end
                count = count + 1;
            end
            local parts = {};
            if isArray and count == #value then
                for i = 1, #value do
                    table.insert(parts, Serialize(value[i]));
                end
                return "a" .. count .. "{" .. table.concat(parts, ",") .. "}";
            end
            local keys = Contract.SortedKeys(value);
            for _, k in ipairs(keys) do
                table.insert(parts,
                    "k" .. Serialize(k) .. "=" .. Serialize(value[k]));
            end
            return "m" .. count .. "{" .. table.concat(parts, ",") .. "}";
        end
        return "?" .. t;
    end

    function Contract.Hash(value)
        return ToHex(Fnv1a(Serialize(value)));
    end

    -- Runtime self-test: this 64-byte string distinguishes the exact 16-bit
    -- split FNV (89f341ef) from the old double-multiply FNV (cdf54590).
    local AMT_MC_FNV_SELFTEST = [[ U+`6kAvL"W-b8mCxN$Y/d:oEzP&[1f<qG|R(]3h>sI~T*_5j@uK!V,a7lBwM#X.]];


    -- ---------------------------------------------------------------------------
    -- ClusterSnapshot schema (MULTICITY_UPGRADE_PLAN section 5.1).
    -- ---------------------------------------------------------------------------
    Contract.CLUSTER_SNAPSHOT_FIELDS = {
        "schemaVersion", "runID", "playerID",
        "orderedParticipantIDs", "realCityIDs", "futureSiteIDs",
        "selectionSource", "participants", "clearPolicy", "signatures",
        "uniqueDistrictSaved",
    };

    Contract.PARTICIPANT_SNAPSHOT_FIELDS = {
        "participantID", "participantKind", "playerID", "name",
        "centerX", "centerY", "currentPopulation", "futurePopulation",
        "currentSpecialtyAllowed",
        "existingSpecialtySlots", "normalizedSlots",
        "foundedSpecialtyTypes", "manualPinnedSpecialtyTypes",
        "savedRevision", "savedIntent", "resolvedPlan",
        "normalizedSlotTypes", "ownedPlotHash", "districtStateHash",
    };

    Contract.SIGNATURE_FIELDS = {
        "settings", "mapPins", "revealedResources", "plotOwnership",
        "technologyCivics", "cityState", "ruleSchema",
        "policies", "religion", "identity", "ruleEffects",
    };

    -- Validates a snapshot against the schema.  Returns true, or false plus a
    -- reason string.
    function Contract.ValidateSnapshot(snapshot)
        if type(snapshot) ~= "table" then
            return false, "snapshot is not a table";
        end
        for _, field in ipairs(Contract.CLUSTER_SNAPSHOT_FIELDS) do
            if snapshot[field] == nil then
                return false, "missing field: " .. field;
            end
        end
        if snapshot.schemaVersion ~= Contract.SCHEMA_VERSION then
            return false, "schemaVersion mismatch: "
                .. tostring(snapshot.schemaVersion);
        end
        if type(snapshot.orderedParticipantIDs) ~= "table"
            or #snapshot.orderedParticipantIDs < 1
            or #snapshot.orderedParticipantIDs > 6 then
            return false, "orderedParticipantIDs must hold 1-6 ids";
        end
        if type(snapshot.realCityIDs) ~= "table"
            or #snapshot.realCityIDs < 1
            or #snapshot.realCityIDs > 4 then
            return false, "realCityIDs must hold 1-4 city ids";
        end
        if type(snapshot.futureSiteIDs) ~= "table"
            or #snapshot.futureSiteIDs > 2 then
            return false, "futureSiteIDs must hold 0-2 site ids";
        end
        if type(snapshot.participants) ~= "table" then
            return false, "participants is not a table";
        end
        local seenParticipantIDs = {};
        local seenCityIDs = {};
        for _, participantID in ipairs(snapshot.orderedParticipantIDs) do
            if seenParticipantIDs[participantID] then
                return false, "duplicate participant id: "
                    .. tostring(participantID);
            end
            seenParticipantIDs[participantID] = true;
            local participant = snapshot.participants[participantID];
            if type(participant) ~= "table" then
                return false, "participant snapshot missing for id "
                    .. tostring(participantID);
            end
            for _, field in ipairs(Contract.PARTICIPANT_SNAPSHOT_FIELDS) do
                if participant[field] == nil then
                    return false, "participant " .. tostring(participantID)
                        .. " missing field: " .. field;
                end
            end
            if participant.participantID ~= participantID then
                return false, "participant id mismatch under key "
                    .. tostring(participantID);
            end
            if participant.playerID ~= snapshot.playerID then
                return false, "participant owner mismatch under key "
                    .. tostring(participantID);
            end
            if participant.participantKind == "REAL_CITY" then
                if participant.cityID == nil then
                    return false, "real participant missing cityID";
                end
                if seenCityIDs[participant.cityID] then
                    return false, "duplicate city id: "
                        .. tostring(participant.cityID);
                end
                seenCityIDs[participant.cityID] = true;
            elseif participant.participantKind == "FUTURE_CITY" then
                if participant.siteID == nil then
                    return false, "future participant missing siteID";
                end
            else
                return false, "unknown participant kind";
            end
            for _, arrayField in ipairs({
                "foundedSpecialtyTypes",
                "manualPinnedSpecialtyTypes",
                "normalizedSlotTypes",
            }) do
                if type(participant[arrayField]) ~= "table" then
                    return false, "participant " .. tostring(participantID)
                        .. " field is not an array: " .. arrayField;
                end
            end
        end
        local clearPolicy = snapshot.clearPolicy;
        if type(clearPolicy) ~= "table"
            or type(clearPolicy.clearParticipantIDs) ~= "table"
            or type(clearPolicy.removeByCity) ~= "table" then
            return false, "clearPolicy is incomplete";
        end
        if type(snapshot.uniqueDistrictSaved) ~= "table" then
            return false, "uniqueDistrictSaved is not a table";
        end
        for subjectKey, entry in pairs(snapshot.uniqueDistrictSaved) do
            if type(entry) ~= "table" or type(entry.mode) ~= "string" then
                return false, "uniqueDistrictSaved entry invalid: "
                    .. tostring(subjectKey);
            end
            if entry.mode == "LOCKED_CITY"
                and tonumber(entry.lockedCityID) == nil then
                return false, "uniqueDistrictSaved lock missing cityID: "
                    .. tostring(subjectKey);
            end
        end
        for _, field in ipairs(Contract.SIGNATURE_FIELDS) do
            if snapshot.signatures[field] == nil then
                return false, "signatures missing field: " .. field;
            end
        end
        return true;
    end

    -- Full snapshot signature: everything that affects a later plan is hashed.
    -- Callers normalize unordered collections before constructing the snapshot;
    -- orderedCityIDs and specialtyOrder remain order-sensitive by design.
    function Contract.SnapshotSignature(snapshot)
        local participants = {};
        for _, participantID in ipairs(snapshot.orderedParticipantIDs or {}) do
            local source = snapshot.participants
                and snapshot.participants[participantID] or nil;
            if source then
                participants[participantID] = {};
                for key, value in pairs(source) do
                    if key ~= "name" then
                        participants[participantID][key] = value;
                    end
                end
            end
        end
        return Contract.Hash({
            schemaVersion = snapshot.schemaVersion,
            playerID = snapshot.playerID,
            orderedParticipantIDs = snapshot.orderedParticipantIDs,
            realCityIDs = snapshot.realCityIDs,
            futureSiteIDs = snapshot.futureSiteIDs,
            participants = participants,
            clearPolicy = snapshot.clearPolicy,
            signatures = snapshot.signatures,
            uniqueDistrictSaved = snapshot.uniqueDistrictSaved,
        });
    end

    -- Stable sort of city ids: primary first, then (distance, cityID).
    function Contract.SortCityIDs(primaryCityID, entries)
        local copy = {};
        for _, entry in ipairs(entries or {}) do
            table.insert(copy, entry);
        end
        table.sort(copy, function(a, b)
            if a.cityID == primaryCityID then return true; end
            if b.cityID == primaryCityID then return false; end
            if a.distanceFromPrimary ~= b.distanceFromPrimary then
                return a.distanceFromPrimary < b.distanceFromPrimary;
            end
            return a.cityID < b.cityID;
        end);
        return copy;
    end

    -- Trace run id (not part of the stable snapshot signature and not a security
    -- token).  pcall returns the clock value directly; never call it a second
    -- time.  A local sequence disambiguates calls made in the same clock tick.
    local m_RunSequence = 0;

    function Contract.NewRunID(seed)
        local clockValue = 0;
        if os and type(os.clock) == "function" then
            local ok, value = pcall(os.clock);
            if ok then clockValue = tonumber(value) or 0; end
        end
        m_RunSequence = m_RunSequence + 1;
        return ToHex(Fnv1a(tostring(seed or 0)
            .. ":" .. tostring(clockValue)
            .. ":" .. tostring(m_RunSequence)));
    end

    -- Debug assertions.  Never throw in production paths.
    Contract.ASSERT_ENABLED = true;

    function Contract.Assert(condition, message)
        if not Contract.ASSERT_ENABLED then return condition; end
        if not condition then

        end
        return condition;
    end



end;
AMT_BundledModules["amt_mc_cluster"] = function()


    -- M2 cluster snapshot module.
    --
    -- Pure functions (offline-testable) are kept free of game API: distances,
    -- populations and district states are passed in as plain data.  The adapter
    -- layer below extracts that data from Civ VI objects and assembles the
    -- ClusterSnapshot (MULTICITY_UPGRADE_PLAN section 5.1).
    --
    -- M2 scope: snapshots and dry-run reports only.  This module must never
    -- place or remove map pins, never modify GameConfiguration state, and never
    -- run the joint solver.

    AMT_MultiCity = AMT_MultiCity or {};
    AMT_MultiCity.Cluster = AMT_MultiCity.Cluster or {};

    local Cluster = AMT_MultiCity.Cluster;
    local Contract = AMT_MultiCity.Contract;

    Cluster.MAX_CITIES = 4;
    Cluster.LINKED_CITY_DISTANCE = 6;
    Cluster.MIN_CITIES = 1;
    Cluster.MAX_SPECIALTY_SLOT_COUNT = 6;
    Cluster.MIN_SPECIALTY_SLOT_COUNT = 1;
    Cluster.DEFAULT_SPECIALTY_SLOT_COUNT = 3;
    -- Keep this identical to the v60 single-city planner's
    -- POPULATION_BUDGET_RANGE.maximum.
    Cluster.POPULATION_BUDGET_MAXIMUM = 50;

    -- ---------------------------------------------------------------------------
    -- Pure functions (no game API).
    -- ---------------------------------------------------------------------------

    -- Sorts candidate entries (primary first, then distance, then cityID).
    -- Entries: { cityID = n, distanceFromPrimary = n }.
    function Cluster.SortCities(primaryCityID, entries)
        local copy = {};
        for i = 1, #(entries or {}) do
            copy[i] = entries[i];
        end
        table.sort(copy, function(a, b)
            if a.cityID == b.cityID then return false; end
            if a.cityID == primaryCityID then return true; end
            if b.cityID == primaryCityID then return false; end
            if a.distanceFromPrimary ~= b.distanceFromPrimary then
                return a.distanceFromPrimary < b.distanceFromPrimary;
            end
            return a.cityID < b.cityID;
        end);
        return copy;
    end

    -- Default recommendation helper.  Discovery itself returns every eligible
    -- city so the player can replace one of the first four recommendations.
    function Cluster.SortAndLimit(primaryCityID, entries)
        local sorted = Cluster.SortCities(primaryCityID, entries);
        local limited = {};
        for i = 1, math.min(#sorted, Cluster.MAX_CITIES) do
            table.insert(limited, sorted[i]);
        end
        return limited;
    end

    -- Filters entries by maximum distance (primary always passes).
    function Cluster.FilterByDistance(primaryCityID, entries, maxDistance)
        local result = {};
        for _, entry in ipairs(entries or {}) do
            if entry.cityID == primaryCityID
                or entry.distanceFromPrimary <= maxDistance then
                table.insert(result, entry);
            end
        end
        return result;
    end

    -- Pure normalization of a single city against the shared template.
    -- Input (all plain data):
    --   population         current population
    --   currentAllowed     GetNumAllowedDistrictsRequiringPopulation
    --   zonedCount         GetNumZonedDistrictsRequiringPopulation
    --   lockedSpecialty    founded specialty districts (irrevocable slots)
    --   pinnedSpecialty    planned (pinned) population districts
    --   templateSlots      configured specialty slot count from the template
    --   templatePopulation planning population from the template
    --   horizon            "CURRENT" or "LONG_TERM"
    -- Output:
    --   currentSpecialtyAllowed, targetPopulation, existingSpecialtySlots,
    --   normalizedSlots
    function Cluster.NormalizeCityBudget(input)
        local population = math.max(
            1, tonumber(input.population) or 1
        );
        local currentAllowed = tonumber(input.currentAllowed);
        if not currentAllowed then
            currentAllowed = math.floor((population - 1) / 3) + 1;
        end
        local zoned = math.max(tonumber(input.zonedCount) or 0,
            tonumber(input.lockedSpecialty) or 0);
        local pinned = tonumber(input.pinnedSpecialty) or 0;
        local occupied = zoned + pinned;

        local configuredSlots = math.max(
            Cluster.MIN_SPECIALTY_SLOT_COUNT,
            math.min(
                Cluster.MAX_SPECIALTY_SLOT_COUNT,
                tonumber(input.templateSlots)
                    or Cluster.DEFAULT_SPECIALTY_SLOT_COUNT
            )
        );
        local planningPopulation = math.max(
            population,
            math.min(
                Cluster.POPULATION_BUDGET_MAXIMUM,
                tonumber(input.templatePopulation)
                    or Cluster.RequiredPopulationForSlots(configuredSlots)
            )
        );
        local plannedAllowed = math.floor((planningPopulation - 1) / 3) + 1;
        local allowedSlots = input.horizon == "CURRENT"
            and currentAllowed or plannedAllowed;
        local totalSlots = math.max(
            occupied,
            math.min(allowedSlots, configuredSlots)
        );
        return {
            currentSpecialtyAllowed = currentAllowed,
            targetPopulation = planningPopulation,
            existingSpecialtySlots = occupied,
            normalizedSlots = totalSlots,
        };
    end

    function Cluster.RequiredPopulationForSlots(slotCount)
        return math.max(1, (slotCount - 1) * 3 + 1);
    end

    -- Produces the visible per-city slot order: founded and manual-pinned
    -- specialty districts are irrevocable, then the primary-city template fills
    -- remaining slots without duplicating a district type.
    function Cluster.NormalizeSlotTypes(
        foundedTypes, pinnedTypes, templateOrder, slotCount
    )
        local result = {};
        local seen = {};
        local function Append(values)
            for _, districtType in ipairs(values or {}) do
                if districtType and not seen[districtType]
                    and #result < (tonumber(slotCount) or 0) then
                    seen[districtType] = true;
                    table.insert(result, districtType);
                end
            end
        end
        Append(Contract.SortedArray(foundedTypes or {}));
        Append(Contract.SortedArray(pinnedTypes or {}));
        Append(templateOrder or {});
        return result;
    end

    -- Stable hash of owned plot keys (array of "x,y" strings) — order-insensitive.
    function Cluster.HashPlotKeys(plotKeys)
        local copy = Contract.SortedArray(plotKeys);
        return Contract.Hash(copy);
    end

    -- Stable hash of district state entries { type, completed, founded }.
    function Cluster.HashDistrictState(districtStates)
        local copy = Contract.SortedArray(
            districtStates or {},
            function(a, b)
                if a.type ~= b.type then return a.type < b.type; end
                if (a.completed ~= b.completed) then
                    return (a.completed or false)
                        and not (b.completed or false);
                end
                return (a.founded or false) and not (b.founded or false);
            end
        );
        return Contract.Hash(copy);
    end

    -- ---------------------------------------------------------------------------
    -- Game adapter layer (Civ VI objects only below this line).
    -- ---------------------------------------------------------------------------

    local function PlotKey(x, y)
        return tostring(x) .. "," .. tostring(y);
    end

    -- Extracts plain-data city entry for discovery.  Returns nil on any engine
    -- hiccup; the caller treats that as "city unusable" without errors.
    local function ExtractCityEntry(playerID, city, primaryX, primaryY)
        local ok, entry = pcall(function()
            local distance = Map.GetPlotDistance(
                primaryX, primaryY, city:GetX(), city:GetY()
            );
            return {
                cityID = city:GetID(),
                distanceFromPrimary = distance,
                name = Locale.Lookup(city:GetName()) or "?",
                centerX = city:GetX(),
                centerY = city:GetY(),
                population = math.max(1, tonumber(city:GetPopulation()) or 1),
                cityObject = city,
            };
        end);
        if not ok then

            return nil;
        end
        return entry;
    end

    -- Discovers every own city within LINKED_CITY_DISTANCE of the primary city,
    -- sorted primary-first then (distance, cityID).  The UI recommends at most
    -- MAX_CITIES but keeps the remaining eligible rows available as alternatives.
    function Cluster.DiscoverCities(playerID, primaryCityID)
        local player = Players[playerID];
        if not player then return {}; end
        local cities = player:GetCities();
        if not cities then return {}; end
        local primaryCity = cities:FindID(primaryCityID);
        if not primaryCity then return {}; end

        local entries = {};
        for _, city in cities:Members() do
            if city then
                local entry = ExtractCityEntry(
                    playerID, city, primaryCity:GetX(), primaryCity:GetY()
                );
                if entry then
                    table.insert(entries, entry);
                end
            end
        end
        entries = Cluster.FilterByDistance(
            primaryCityID, entries, Cluster.LINKED_CITY_DISTANCE
        );
        return Cluster.SortCities(primaryCityID, entries);
    end

    local function SafePlotPurchaseCity(plot)
        if not plot or not Cities or not Cities.GetPlotPurchaseCity then
            return nil;
        end
        local ok, city = pcall(Cities.GetPlotPurchaseCity, plot);
        if ok then return city; end
        return nil;
    end

    -- Civ VI exposes purchased plots through Map.GetCityPlots(), returning plot
    -- indices rather than plot objects.  A purchase-city scan is retained as a
    -- compatibility fallback for custom rulesets and unfinished districts.
    function Cluster.CollectOwnedPlots(city)
        local plots = {};
        local seen = {};
        if not city then return plots; end

        local function AddPlot(plot, requireOwnershipCheck)
            if not plot then return; end
            if requireOwnershipCheck then
                local ownerCity = SafePlotPurchaseCity(plot);
                if not ownerCity
                    or ownerCity:GetOwner() ~= city:GetOwner()
                    or ownerCity:GetID() ~= city:GetID() then
                    return;
                end
            end
            local key = PlotKey(plot:GetX(), plot:GetY());
            if not seen[key] then
                seen[key] = true;
                table.insert(plots, plot);
            end
        end

        local ok, plotIDs = pcall(function()
            local cityPlots = Map.GetCityPlots and Map.GetCityPlots() or nil;
            return cityPlots and cityPlots:GetPurchasedPlots(city) or nil;
        end);
        if ok and type(plotIDs) == "table" then
            for _, plotID in pairs(plotIDs) do
                AddPlot(Map.GetPlotByIndex(plotID), false);
            end
        end

        local rangeOK, rangePlots = pcall(function()
            if type(GetPlotsWithinXTiles) == "function" then
                return GetPlotsWithinXTiles(city:GetX(), city:GetY(), 3);
            end
            return nil;
        end);
        if rangeOK and type(rangePlots) == "table" then
            for _, plot in ipairs(rangePlots) do AddPlot(plot, true); end
        else
            for dx = -3, 3 do
                for dy = -3, 3 do
                    local plot = Map.GetPlot(city:GetX() + dx, city:GetY() + dy);
                    if plot and Map.GetPlotDistance(
                        city:GetX(), city:GetY(), plot:GetX(), plot:GetY()
                    ) <= 3 then
                        AddPlot(plot, true);
                    end
                end
            end
        end
        return plots;
    end

    -- Owned plot keys for a city ("x,y" strings, sorted before hashing).
    function Cluster.CollectOwnedPlotKeys(city)
        local keys = {};
        for _, plot in ipairs(Cluster.CollectOwnedPlots(city)) do
            table.insert(keys, PlotKey(plot:GetX(), plot:GetY()));
        end
        return keys;
    end

    local function SafeHasDistrict(cityDistricts, districtIndex)
        if not cityDistricts then return false; end
        local ok, has = pcall(function()
            return cityDistricts:HasDistrict(districtIndex);
        end);
        return ok and has == true;
    end

    -- District state entries for a city: { type, completed, founded }.  Plot
    -- state identifies foundations immediately; the district manager identifies
    -- completed districts and serves as a compatibility fallback.
    function Cluster.CollectDistrictStates(city)
        local byType = {};
        local cityDistricts = city and city:GetDistricts() or nil;
        if not city or not cityDistricts then return {}; end

        for _, plot in ipairs(Cluster.CollectOwnedPlots(city)) do
            local ok, districtIndex = pcall(function()
                return plot:GetDistrictType();
            end);
            if ok and districtIndex and districtIndex >= 0 then
                local row = GameInfo.Districts[districtIndex];
                if row then
                    byType[row.DistrictType] = {
                        type = row.DistrictType,
                        completed = SafeHasDistrict(cityDistricts, row.Index),
                        founded = true,
                    };
                end
            end
        end

        for row in GameInfo.Districts() do
            if SafeHasDistrict(cityDistricts, row.Index) then
                local state = byType[row.DistrictType] or {
                    type = row.DistrictType,
                    founded = true,
                };
                state.completed = true;
                byType[row.DistrictType] = state;
            end
        end

        local states = {};
        for _, districtType in ipairs(Contract.SortedKeys(byType)) do
            table.insert(states, byType[districtType]);
        end
        return states;
    end

    local function SpecialtyTypesFromDistrictStates(states)
        local types = {};
        for _, state in ipairs(states or {}) do
            local row = GameInfo.Districts[state.type];
            if row and row.RequiresPopulation and state.founded then
                table.insert(types, state.type);
            end
        end
        return Contract.SortedArray(types);
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

    local function CopyPlain(value)
        if type(value) ~= "table" then return value; end
        local copy = {};
        for key, item in pairs(value) do
            copy[CopyPlain(key)] = CopyPlain(item);
        end
        return copy;
    end

    local function UniqueTypesExcluding(values, excludedValues)
        local excluded = {};
        for _, districtType in ipairs(excludedValues or {}) do
            excluded[districtType] = true;
        end
        local result = {};
        for _, districtType in ipairs(values or {}) do
            if districtType and not excluded[districtType] then
                excluded[districtType] = true;
                table.insert(result, districtType);
            end
        end
        return Contract.SortedArray(result);
    end

    -- Builds the ClusterSnapshot for the selected cities.  planningConfig is the
    -- shared template from the primary city settings; selectionSource records how
    -- the city list was chosen ("auto" or "user").
    function Cluster.BuildSnapshot(
        playerID, primaryCityID, selectedCityIDs, planningConfig,
        selectionSource
    )
        if type(planningConfig) ~= "table" then
            return nil, "planning config missing";
        end
        local profiles = {};
        for index, cityID in ipairs(selectedCityIDs or {}) do
            local participantID = "CITY:" .. tostring(playerID)
                .. ":" .. tostring(cityID);
            table.insert(profiles, {
                participantID = participantID,
                participantKind = "REAL_CITY",
                cityID = cityID,
                name = tostring(cityID),
                savedRevision = 1,
                savedIntent = {
                    futurePopulation = planningConfig.populationBudget,
                    specialtySlotCount = planningConfig.specialtySlotCount,
                    horizon = planningConfig.horizon,
                    selectedSubjects = CopyPlain(
                        planningConfig.selectedSubjects or {}
                    ),
                    specialtyOrder = CopyPlain(
                        planningConfig.specialtyOrder or {}
                    ),
                    yieldWeights = CopyPlain(planningConfig.yieldWeights or {}),
                    prioritizeUnique = planningConfig.prioritizeUnique,
                    preserveEnabled = planningConfig.preserveEnabled,
                    clearPolicy = CopyPlain(planningConfig.clearPolicy or {}),
                },
                cityInput = planningConfig.cityInputs
                    and CopyPlain(planningConfig.cityInputs[cityID]) or {},
                clearPreview = planningConfig.clearPreviewByCity
                    and CopyPlain(planningConfig.clearPreviewByCity[cityID]) or {},
                sortIndex = index,
            });
        end
        return Cluster.BuildSnapshotFromProfiles(
            playerID, profiles, nil,
            selectionSource or "SAVED_SETTINGS_CONFIRMATION"
        );
    end

    local function SortMapPinParts(parts)
        table.sort(parts, function(a, b)
            if a.x ~= b.x then return a.x < b.x; end
            if a.y ~= b.y then return a.y < b.y; end
            if a.icon ~= b.icon then return a.icon < b.icon; end
            return a.name < b.name;
        end);
        return parts;
    end

    function Cluster.HashMapPinParts(parts)
        return Contract.Hash(SortMapPinParts(CopyPlain(parts or {})));
    end

    local function BuildCityStateParts(cities, orderedCityIDs)
        local parts = {};
        for _, cityID in ipairs(orderedCityIDs or {}) do
            local cityEntry = cities and cities[cityID] or nil;
            if not cityEntry then return nil; end
            table.insert(parts, {
                ownerID = cityEntry.ownerID,
                cityID = cityID,
                x = cityEntry.centerX,
                y = cityEntry.centerY,
                population = cityEntry.currentPopulation,
                currentSpecialtyAllowed = cityEntry.currentSpecialtyAllowed,
                ownedPlotHash = cityEntry.ownedPlotHash,
                districtStateHash = cityEntry.districtStateHash,
            });
        end
        return parts;
    end

    -- Re-reads the live state for exactly the frozen city IDs.  It never scans
    -- for replacement participants; a missing or captured city invalidates the
    -- snapshot instead.
    function Cluster.CaptureLiveCityStates(playerID, orderedCityIDs)
        local player = Players[playerID];
        local cityManager = player and player:GetCities() or nil;
        if not cityManager then return nil; end
        local live = {};
        for _, cityID in ipairs(orderedCityIDs or {}) do
            local city = cityManager:FindID(cityID);
            if not city or city:GetOwner() ~= playerID then return nil; end
            local cityDistricts = city:GetDistricts();
            local population = math.max(
                1, tonumber(city:GetPopulation()) or 1
            );
            local currentAllowed = SafeDistrictCapacityCall(
                cityDistricts,
                "GetNumAllowedDistrictsRequiringPopulation"
            ) or math.floor((population - 1) / 3) + 1;
            live[cityID] = {
                ownerID = playerID,
                cityID = cityID,
                centerX = city:GetX(),
                centerY = city:GetY(),
                currentPopulation = population,
                currentSpecialtyAllowed = currentAllowed,
                ownedPlotHash = Cluster.HashPlotKeys(
                    Cluster.CollectOwnedPlotKeys(city)
                ),
                districtStateHash = Cluster.HashDistrictState(
                    Cluster.CollectDistrictStates(city)
                ),
            };
        end
        return live;
    end

    -- Invalidation signatures over the game state that a later plan depends on.
    -- Every collection is explicitly ordered before hashing.
    function Cluster.BuildInvalidationSignatures(
        playerID, cities, orderedCityIDs
    )
        local mapPinsParts = {};
        local cfg = PlayerConfigurations[playerID];
        local pins = cfg and cfg:GetMapPins() or {};
        for _, pin in pairs(pins or {}) do
            if pin then
                table.insert(mapPinsParts, {
                    x = pin:GetHexX(),
                    y = pin:GetHexY(),
                    icon = pin:GetIconName() or "",
                    name = pin:GetName() or "",
                });
            end
        end
        SortMapPinParts(mapPinsParts);

        local techParts = { technologies = {}, civics = {} };
        local techs = playerID and Players[playerID]
            and Players[playerID]:GetTechs() or nil;
        if techs and techs.HasTech and GameInfo and GameInfo.Technologies then
            for row in GameInfo.Technologies() do
                if row and techs:HasTech(row.Index) then
                    table.insert(
                        techParts.technologies,
                        row.TechnologyType or tostring(row.Index)
                    );
                end
            end
        end
        local civics = playerID and Players[playerID]
            and Players[playerID]:GetCulture() or nil;
        if civics and civics.HasCivic and GameInfo and GameInfo.Civics then
            for row in GameInfo.Civics() do
                if row and civics:HasCivic(row.Index) then
                    table.insert(
                        techParts.civics,
                        row.CivicType or tostring(row.Index)
                    );
                end
            end
        end
        table.sort(techParts.technologies);
        table.sort(techParts.civics);

        -- C0 rule fingerprint: active policy cards, pantheon, religious beliefs,
        -- civilization/leader identity, and the base-game effect tables that feed
        -- yield and placement modifiers.  All reads are guarded; an unavailable
        -- API contributes an explicit "unavailable" marker instead of crashing
        -- the snapshot.
        local policyParts = {};
        if civics and type(civics.GetNumPolicySlots) == "function" then
            local okSlots, numSlots = pcall(function()
                return civics:GetNumPolicySlots();
            end);
            if okSlots and type(numSlots) == "number" then
                for index = 0, numSlots - 1 do
                    local okType, slotType = pcall(function()
                        return civics:GetSlotType(index);
                    end);
                    local okPolicy, policyIndex = pcall(function()
                        return civics:GetSlotPolicy(index);
                    end);
                    if okType and okPolicy then
                        local slotName = GameInfo.GovernmentSlots
                            and GameInfo.GovernmentSlots[slotType]
                            and GameInfo.GovernmentSlots[slotType]
                                .GovernmentSlotType
                            or tostring(slotType);
                        local policyName = "EMPTY";
                        if type(policyIndex) == "number" and policyIndex >= 0
                            and GameInfo.Policies
                            and GameInfo.Policies[policyIndex] then
                            policyName = GameInfo.Policies[policyIndex].PolicyType
                                or "EMPTY";
                        end
                        table.insert(policyParts, slotName .. "=" .. policyName);
                    end
                end
            end
        end
        table.sort(policyParts);

        local religionParts = {};
        local playerObject = playerID and Players[playerID] or nil;
        local playerReligion = nil;
        if playerObject and type(playerObject.GetReligion) == "function" then
            local okReligion, religionObject = pcall(function()
                return playerObject:GetReligion();
            end);
            if okReligion then
                playerReligion = religionObject;
            end
        end
        if playerReligion
            and type(playerReligion.GetPantheon) == "function" then
            local okPantheon, pantheonIndex = pcall(function()
                return playerReligion:GetPantheon();
            end);
            if okPantheon and type(pantheonIndex) == "number" then
                local row = GameInfo.Beliefs and GameInfo.Beliefs[pantheonIndex];
                table.insert(religionParts, "pantheon="
                    .. tostring(row and row.BeliefType or pantheonIndex));
            end
        end
        if Game and Game.GetReligion then
            local gameReligion = Game.GetReligion();
            if gameReligion
                and type(gameReligion.GetReligions) == "function" then
                local okReligions, religions = pcall(function()
                    return gameReligion:GetReligions();
                end);
                if okReligions and type(religions) == "table" then
                    for _, religion in ipairs(religions) do
                        if religion and religion.Founder == playerID
                            and type(religion.Beliefs) == "table" then
                            for beliefKey, enabled in pairs(religion.Beliefs) do
                                local row = GameInfo.Beliefs
                                    and GameInfo.Beliefs[beliefKey];
                                table.insert(religionParts,
                                    tostring(beliefKey) .. "="
                                    .. tostring(row and row.BeliefType or "?")
                                    .. ":" .. tostring(enabled));
                            end
                        end
                    end
                end
            end
        end
        table.sort(religionParts);

        local identityParts = {};
        local cfg = playerID and PlayerConfigurations
            and PlayerConfigurations[playerID] or nil;
        if cfg then
            if type(cfg.GetCivilizationTypeName) == "function" then
                local okCiv, civName = pcall(function()
                    return cfg:GetCivilizationTypeName();
                end);
                if okCiv then
                    table.insert(identityParts, "civ=" .. tostring(civName));
                end
            end
            if type(cfg.GetLeaderTypeName) == "function" then
                local okLeader, leaderName = pcall(function()
                    return cfg:GetLeaderTypeName();
                end);
                if okLeader then
                    table.insert(identityParts, "leader=" .. tostring(leaderName));
                end
            end
        end
        table.sort(identityParts);

        local effectRows = {};
        local effectOK = true;
        local effectError = nil;
        local okEffectScan, effectScanError = pcall(function()
            local function AddRows(tableName, fields)
                if not GameInfo or not GameInfo[tableName] then
                    return;
                end
                for row in GameInfo[tableName]() do
                    local values = {};
                    for _, field in ipairs(fields) do
                        table.insert(values, tostring(row[field]));
                    end
                    table.insert(effectRows, table.concat(values, "|"));
                end
            end
            AddRows("PolicyModifiers", { "PolicyType", "ModifierId" });
            AddRows("BeliefModifiers", { "BeliefType", "ModifierId" });
            AddRows("TraitModifiers", { "TraitType", "ModifierId" });
            AddRows("ModifierArguments",
                { "ModifierId", "Name", "Value" });
        end);
        if not okEffectScan then
            effectOK = false;
            effectError = effectScanError;
        end
        table.sort(effectRows);

        local cityStateParts = BuildCityStateParts(cities, orderedCityIDs)
            or { missing = true };

        return {
            mapPins = Cluster.HashMapPinParts(mapPinsParts),
            technologyCivics = Contract.Hash(techParts),
            policies = Contract.Hash(policyParts),
            religion = Contract.Hash(religionParts),
            identity = Contract.Hash(identityParts),
            ruleEffects = effectOK and Contract.Hash(effectRows)
                or ("UNAVAILABLE:" .. tostring(effectError)),
            cityState = Contract.Hash(cityStateParts),
            ruleSchema = Contract.Hash({
                snapshotSchema = Contract.SCHEMA_VERSION,
                maxCities = Cluster.MAX_CITIES,
                distance = Cluster.LINKED_CITY_DISTANCE,
            }),
        };
    end

    -- Builds the revised M2 snapshot from independently saved city profiles.
    -- Profiles are already frozen by the UI scope-confirmation state and must be
    -- ordered stably.  No profile is inferred, replaced, or template-propagated.
    function Cluster.BuildSnapshotFromProfiles(
        playerID, profiles, signatureInputs, selectionSource
    )
        if type(profiles) ~= "table"
            or #profiles < Cluster.MIN_CITIES
            or #profiles > Cluster.MAX_CITIES then
            return nil, "saved profiles must contain 1-4 real cities";
        end
        local player = Players[playerID];
        local cityManager = player and player:GetCities() or nil;
        if not cityManager then return nil, "player cities unavailable"; end

        local orderedParticipantIDs = {};
        local realCityIDs = {};
        local participants = {};
        local legacyCities = {};
        local seen = {};
        local settingsParts = {};
        local clearPolicy = {
            clearScope = "PARTICIPANTS",
            clearAutoPins = false,
            clearManualPins = false,
            clearParticipantIDs = {},
            clearCityIDs = {},
            removeByCity = {},
        };

        for _, profile in ipairs(profiles) do
            local participantID = profile.participantID;
            local cityID = tonumber(profile.cityID);
            if type(participantID) ~= "string" or cityID == nil then
                return nil, "profile identity incomplete";
            end
            if seen[participantID] or seen[cityID] then
                return nil, "duplicate saved profile identity";
            end
            seen[participantID] = true;
            seen[cityID] = true;
            local city = cityManager:FindID(cityID);
            if not city or city:GetOwner() ~= playerID then
                return nil, "saved city unavailable: " .. tostring(cityID);
            end
            local intent = CopyPlain(profile.savedIntent or {});
            local cityDistricts = city:GetDistricts();
            local districtStates = Cluster.CollectDistrictStates(city);
            local foundedTypes = SpecialtyTypesFromDistrictStates(districtStates);
            local cityInput = profile.cityInput or {};
            local pinnedTypes = UniqueTypesExcluding(
                cityInput.manualPinnedSpecialtyTypes or {}, foundedTypes
            );
            local currentPopulation = math.max(
                1, tonumber(city:GetPopulation()) or 1
            );
            local budget = Cluster.NormalizeCityBudget({
                population = currentPopulation,
                currentAllowed = SafeDistrictCapacityCall(
                    cityDistricts, "GetNumAllowedDistrictsRequiringPopulation"
                ),
                zonedCount = SafeDistrictCapacityCall(
                    cityDistricts, "GetNumZonedDistrictsRequiringPopulation"
                ),
                lockedSpecialty = #foundedTypes,
                pinnedSpecialty = #pinnedTypes,
                templateSlots = intent.specialtySlotCount,
                templatePopulation = intent.futurePopulation,
                horizon = intent.horizon,
            });
            local normalizedOrder = Cluster.NormalizeSlotTypes(
                foundedTypes, pinnedTypes, intent.specialtyOrder or {},
                budget.normalizedSlots
            );
            local resolvedPlan = CopyPlain(profile.resolvedPlan or intent);
            resolvedPlan.futurePopulation = budget.targetPopulation;
            resolvedPlan.specialtySlotCount = budget.normalizedSlots;
            resolvedPlan.normalizedSlotTypes = CopyPlain(normalizedOrder);
            resolvedPlan.currentPopulation = currentPopulation;
            resolvedPlan.currentSpecialtyAllowed = budget.currentSpecialtyAllowed;

            local participant = {
                participantID = participantID,
                participantKind = "REAL_CITY",
                playerID = playerID,
                cityID = cityID,
                name = Locale.Lookup(city:GetName()) or tostring(profile.name or "?"),
                centerX = city:GetX(),
                centerY = city:GetY(),
                currentPopulation = currentPopulation,
                futurePopulation = budget.targetPopulation,
                currentSpecialtyAllowed = budget.currentSpecialtyAllowed,
                existingSpecialtySlots = budget.existingSpecialtySlots,
                normalizedSlots = budget.normalizedSlots,
                foundedSpecialtyTypes = foundedTypes,
                manualPinnedSpecialtyTypes = pinnedTypes,
                savedRevision = tonumber(profile.savedRevision) or 0,
                savedIntent = intent,
                resolvedPlan = resolvedPlan,
                normalizedSlotTypes = normalizedOrder,
                ownedPlotHash = Cluster.HashPlotKeys(
                    Cluster.CollectOwnedPlotKeys(city)
                ),
                districtStateHash = Cluster.HashDistrictState(districtStates),
            };
            participants[participantID] = participant;
            table.insert(orderedParticipantIDs, participantID);
            table.insert(realCityIDs, cityID);
            table.insert(clearPolicy.clearParticipantIDs, participantID);
            table.insert(clearPolicy.clearCityIDs, cityID);
            clearPolicy.removeByCity[cityID] = CopyPlain(
                profile.clearPreview or {}
            );
            local intentClear = intent.clearPolicy or {};
            clearPolicy.clearAutoPins = clearPolicy.clearAutoPins
                or intentClear.clearAutoPins == true;
            clearPolicy.clearManualPins = clearPolicy.clearManualPins
                or intentClear.clearManualPins == true;
            table.insert(settingsParts, {
                participantID = participantID,
                savedRevision = participant.savedRevision,
                savedIntent = intent,
            });
            legacyCities[cityID] = {
                ownerID = playerID,
                cityID = cityID,
                centerX = participant.centerX,
                centerY = participant.centerY,
                currentPopulation = currentPopulation,
                currentSpecialtyAllowed = participant.currentSpecialtyAllowed,
                ownedPlotHash = participant.ownedPlotHash,
                districtStateHash = participant.districtStateHash,
            };
        end

        local legacySignatures = Cluster.BuildInvalidationSignatures(
            playerID, legacyCities, realCityIDs
        );
        signatureInputs = signatureInputs or {};
        local uniqueDistrictSaved = CopyPlain(
            signatureInputs.uniqueDistrictSaved or {}
        );
        table.insert(settingsParts, {
            uniqueDistrictSaved = uniqueDistrictSaved,
        });
        local snapshot = {
            schemaVersion = Contract.SCHEMA_VERSION,
            runID = Contract.NewRunID(realCityIDs[1]),
            playerID = playerID,
            orderedParticipantIDs = orderedParticipantIDs,
            realCityIDs = realCityIDs,
            futureSiteIDs = {},
            selectionSource = selectionSource
                or "SAVED_SETTINGS_CONFIRMATION",
            participants = participants,
            clearPolicy = clearPolicy,
            uniqueDistrictSaved = uniqueDistrictSaved,
            signatures = {
                settings = Contract.Hash(settingsParts),
                mapPins = legacySignatures.mapPins,
                revealedResources = Contract.Hash(
                    signatureInputs.revealedResources or {}
                ),
                plotOwnership = Contract.Hash(
                    signatureInputs.plotOwnership or {}
                ),
                technologyCivics = legacySignatures.technologyCivics,
                cityState = legacySignatures.cityState,
                policies = legacySignatures.policies,
                religion = legacySignatures.religion,
                identity = legacySignatures.identity,
                ruleEffects = legacySignatures.ruleEffects,
                ruleSchema = Contract.Hash({
                    snapshotSchema = Contract.SCHEMA_VERSION,
                    maxRealCities = Cluster.MAX_CITIES,
                    maxFutureCities = 2,
                }),
            },
        };
        local ok, reason = Contract.ValidateSnapshot(snapshot);
        if not ok then
            return nil, "snapshot validation failed: " .. tostring(reason);
        end
        snapshot.runSignature = Contract.SnapshotSignature(snapshot);
        return snapshot;
    end

    -- Recomputes invalidation signatures for a snapshot's cities and compares
    -- them against the snapshot.  Returns true when still valid.
    function Cluster.SnapshotStillValid(snapshot)
        if snapshot and snapshot.schemaVersion == Contract.SCHEMA_VERSION
            and snapshot.orderedParticipantIDs then
            local liveCities = Cluster.CaptureLiveCityStates(
                snapshot.playerID, snapshot.realCityIDs
            );
            if not liveCities then

                return false;
            end
            local signatures = Cluster.BuildInvalidationSignatures(
                snapshot.playerID, liveCities, snapshot.realCityIDs
            );
            for _, field in ipairs({
                "mapPins", "technologyCivics", "cityState",
                "policies", "religion", "identity", "ruleEffects",
            }) do
                if signatures[field] ~= snapshot.signatures[field] then

                    return false;
                end
            end
            return true;
        end
        if not snapshot or not snapshot.cities then return false; end
        local liveCities = Cluster.CaptureLiveCityStates(
            snapshot.playerID, snapshot.orderedCityIDs
        );
        if not liveCities then

            return false;
        end
        local signatures = Cluster.BuildInvalidationSignatures(
            snapshot.playerID, liveCities, snapshot.orderedCityIDs
        );
        for _, field in ipairs(Contract.SIGNATURE_FIELDS) do
            if signatures[field] ~= snapshot.signatures[field] then

                return false;
            end
        end
        return true;
    end



end;
AMT_BundledModules["amt_mc_ui"] = function()


    -- Pure M2 planning-city editor state.  This module deliberately has no game
    -- API dependencies: the main planner owns controls/camera/persistence while
    -- this module owns stable participant identity, draft/saved separation,
    -- revisions, solve eligibility, and scope-confirmation data.

    AMT_MultiCity = AMT_MultiCity or {};
    AMT_MultiCity.UIState = AMT_MultiCity.UIState or {};

    local UIState = AMT_MultiCity.UIState;

    UIState.SCHEMA_VERSION = 1;
    UIState.MAX_REAL_CITIES = 4;

    UIState.STATUS_UNSET = "UNSET";
    UIState.STATUS_DIRTY = "DIRTY";
    UIState.STATUS_SAVED = "SAVED";
    UIState.STATUS_REOPTIMIZE = "REOPTIMIZE";
    UIState.STATUS_REVIEW = "REVIEW";

    local function Copy(value, seen)
        if type(value) ~= "table" then return value; end
        seen = seen or {};
        if seen[value] then return seen[value]; end
        local result = {};
        seen[value] = result;
        for key, item in pairs(value) do
            result[Copy(key, seen)] = Copy(item, seen);
        end
        return result;
    end

    local function Equal(first, second, seen)
        if type(first) ~= type(second) then return false; end
        if type(first) ~= "table" then return first == second; end
        seen = seen or {};
        if seen[first] == second then return true; end
        seen[first] = second;
        for key, value in pairs(first) do
            if not Equal(value, second[key], seen) then return false; end
        end
        for key in pairs(second) do
            if first[key] == nil then return false; end
        end
        return true;
    end

    UIState.Copy = Copy;
    UIState.Equal = Equal;

    function UIState.RealCityParticipantID(playerID, cityID)
        return "CITY:" .. tostring(playerID) .. ":" .. tostring(cityID);
    end

    function UIState.FutureCityParticipantID(playerID, siteID)
        return "SITE:" .. tostring(playerID) .. ":" .. tostring(siteID);
    end

    local function SortParticipants(participants)
        table.sort(participants, function(a, b)
            if a.participantKind ~= b.participantKind then
                return a.participantKind == "REAL_CITY";
            end
            if a.participantKind == "REAL_CITY" then
                return tonumber(a.cityID) < tonumber(b.cityID);
            end
            return tostring(a.siteID) < tostring(b.siteID);
        end);
        return participants;
    end

    function UIState.NewSession(playerID, participants, stored)
        local session = {
            schemaVersion = UIState.SCHEMA_VERSION,
            playerID = playerID,
            orderedParticipantIDs = {},
            participants = {},
            profiles = {},
            -- Runtime-only solve selection.  Persisted settings are reusable
            -- templates, not an instruction to re-plan that city forever.
            includedParticipantIDs = {},
            activeIndex = 1,
        };
        local ordered = {};
        for _, source in ipairs(participants or {}) do
            local participant = Copy(source);
            participant.participantKind = participant.participantKind
                or "REAL_CITY";
            participant.participantID = participant.participantID
                or (participant.participantKind == "REAL_CITY"
                    and UIState.RealCityParticipantID(playerID, participant.cityID)
                    or UIState.FutureCityParticipantID(playerID, participant.siteID));
            table.insert(ordered, participant);
        end
        SortParticipants(ordered);

        local storedProfiles = type(stored) == "table"
            and stored.profiles or {};
        local storedUnique = type(stored) == "table"
            and type(stored.uniqueDistrictSaved) == "table"
            and stored.uniqueDistrictSaved or {};
        session.uniqueDistrictSaved = Copy(storedUnique);
        session.uniqueDistrictDraft = Copy(storedUnique);
        for _, participant in ipairs(ordered) do
            local participantID = participant.participantID;
            table.insert(session.orderedParticipantIDs, participantID);
            session.participants[participantID] = participant;
            local persisted = storedProfiles
                and storedProfiles[participantID] or nil;
            local savedIntent = persisted
                and Copy(persisted.savedIntent) or nil;
            session.profiles[participantID] = {
                schemaVersion = UIState.SCHEMA_VERSION,
                participantID = participantID,
                participantKind = participant.participantKind,
                playerID = playerID,
                cityID = participant.cityID,
                siteID = participant.siteID,
                anchorPlotIndex = participant.anchorPlotIndex,
                savedRevision = tonumber(persisted
                    and persisted.savedRevision) or 0,
                savedIntent = savedIntent,
                savedIntentHash = persisted
                    and persisted.savedIntentHash or nil,
                resolvedPlan = persisted
                    and Copy(persisted.resolvedPlan) or nil,
                reviewState = persisted
                    and persisted.reviewState or nil,
                draftIntent = savedIntent and Copy(savedIntent) or nil,
                draftTouched = false,
            };
        end
        return session;
    end

    function UIState.SetActiveByID(session, participantID)
        for index, value in ipairs(session.orderedParticipantIDs or {}) do
            if value == participantID then
                session.activeIndex = index;
                return true;
            end
        end
        return false;
    end

    function UIState.GetActiveID(session)
        return session.orderedParticipantIDs
            and session.orderedParticipantIDs[session.activeIndex] or nil;
    end

    function UIState.Cycle(session, delta)
        local count = #(session.orderedParticipantIDs or {});
        if count == 0 then return nil; end
        session.activeIndex = ((session.activeIndex - 1 + delta) % count) + 1;
        return UIState.GetActiveID(session);
    end

    function UIState.SetDraft(session, participantID, intent, touched)
        local profile = session.profiles[participantID];
        if not profile then return false, "unknown participant"; end
        profile.draftIntent = Copy(intent);
        if touched then profile.draftTouched = true; end
        return true;
    end

    function UIState.GetStatus(profile)
        if profile.reviewState == UIState.STATUS_REVIEW then
            return UIState.STATUS_REVIEW;
        end
        if profile.savedIntent ~= nil then
            if profile.draftTouched
                and not Equal(profile.draftIntent, profile.savedIntent) then
                return UIState.STATUS_DIRTY;
            end
            if profile.reviewState == UIState.STATUS_REOPTIMIZE then
                return UIState.STATUS_REOPTIMIZE;
            end
            return UIState.STATUS_SAVED;
        end
        if profile.draftTouched then return UIState.STATUS_DIRTY; end
        return UIState.STATUS_UNSET;
    end

    function UIState.CountSavedRealCities(session)
        local count = 0;
        for participantID, profile in pairs(session.profiles or {}) do
            if profile.participantKind == "REAL_CITY"
                and profile.savedIntent ~= nil then
                count = count + 1;
            end
        end
        return count;
    end

    function UIState.CountIncludedRealCities(session)
        local count = 0;
        for participantID, included in pairs(
            session.includedParticipantIDs or {}
        ) do
            local profile = session.profiles[participantID];
            if included == true and profile
                and profile.participantKind == "REAL_CITY" then
                count = count + 1;
            end
        end
        return count;
    end

    function UIState.IncludeInScope(session, participantID)
        local profile = session.profiles[participantID];
        if not profile or profile.savedIntent == nil then
            return false, "participant has no saved settings";
        end
        session.includedParticipantIDs = session.includedParticipantIDs or {};
        if session.includedParticipantIDs[participantID] == true then
            return true;
        end
        if profile.participantKind == "REAL_CITY"
            and UIState.CountIncludedRealCities(session)
                >= UIState.MAX_REAL_CITIES then
            return false, "real city limit";
        end
        session.includedParticipantIDs[participantID] = true;
        return true;
    end

    function UIState.Save(session, participantID, intent, resolvedPlan, intentHash)
        local profile = session.profiles[participantID];
        if not profile then return false, "unknown participant"; end
        if profile.participantKind == "REAL_CITY"
            and not (session.includedParticipantIDs
                and session.includedParticipantIDs[participantID])
            and UIState.CountIncludedRealCities(session)
                >= UIState.MAX_REAL_CITIES then
            return false, "real city limit";
        end
        profile.savedRevision = (tonumber(profile.savedRevision) or 0) + 1;
        profile.savedIntent = Copy(intent);
        profile.draftIntent = Copy(intent);
        profile.resolvedPlan = Copy(resolvedPlan);
        profile.savedIntentHash = intentHash;
        profile.reviewState = nil;
        profile.draftTouched = false;
        session.includedParticipantIDs = session.includedParticipantIDs or {};
        session.includedParticipantIDs[participantID] = true;
        return true, profile.savedRevision;
    end

    function UIState.Clear(session, participantID, defaultIntent)
        local profile = session.profiles[participantID];
        if not profile then return false, "unknown participant"; end
        profile.savedRevision = 0;
        profile.savedIntent = nil;
        profile.savedIntentHash = nil;
        profile.resolvedPlan = nil;
        profile.reviewState = nil;
        profile.draftIntent = Copy(defaultIntent);
        profile.draftTouched = false;
        if session.includedParticipantIDs then
            session.includedParticipantIDs[participantID] = nil;
        end
        return true;
    end

    function UIState.BuildScope(session)
        local scope = {
            included = {},
            excluded = {},
        };
        for _, participantID in ipairs(session.orderedParticipantIDs or {}) do
            local participant = session.participants[participantID];
            local profile = session.profiles[participantID];
            local status = UIState.GetStatus(profile);
            local selected = session.includedParticipantIDs
                and session.includedParticipantIDs[participantID] == true;
            if selected and profile.savedIntent ~= nil
                and status ~= UIState.STATUS_REVIEW then
                table.insert(scope.included, {
                    participantID = participantID,
                    participantKind = participant.participantKind,
                    cityID = participant.cityID,
                    siteID = participant.siteID,
                    name = participant.name,
                    savedRevision = profile.savedRevision,
                    savedIntent = Copy(profile.savedIntent),
                    resolvedPlan = Copy(profile.resolvedPlan),
                    hasUnsavedDraft = status == UIState.STATUS_DIRTY,
                });
            else
                table.insert(scope.excluded, {
                    participantID = participantID,
                    participantKind = participant.participantKind,
                    cityID = participant.cityID,
                    siteID = participant.siteID,
                    name = participant.name,
                    reason = status == UIState.STATUS_REVIEW
                        and "NEEDS_REVIEW"
                        or (profile.savedIntent ~= nil
                            and "NOT_SELECTED" or "NOT_SAVED"),
                });
            end
        end
        return scope;
    end

    function UIState.HasUnsavedSharedDrafts(session)
        return not Equal(
            session.uniqueDistrictDraft or {},
            session.uniqueDistrictSaved or {}
        );
    end

    function UIState.HasUnsavedDrafts(session)
        for _, profile in pairs(session.profiles or {}) do
            if UIState.GetStatus(profile) == UIState.STATUS_DIRTY then
                return true;
            end
        end
        return UIState.HasUnsavedSharedDrafts(session);
    end

    function UIState.Export(session)
        local result = {
            schemaVersion = UIState.SCHEMA_VERSION,
            profiles = {},
            uniqueDistrictSaved = Copy(session.uniqueDistrictSaved or {}),
        };
        for participantID, profile in pairs(session.profiles or {}) do
            if profile.savedIntent ~= nil then
                result.profiles[participantID] = {
                    schemaVersion = UIState.SCHEMA_VERSION,
                    participantID = participantID,
                    participantKind = profile.participantKind,
                    playerID = profile.playerID,
                    cityID = profile.cityID,
                    siteID = profile.siteID,
                    anchorPlotIndex = profile.anchorPlotIndex,
                    savedRevision = profile.savedRevision,
                    savedIntent = Copy(profile.savedIntent),
                    savedIntentHash = profile.savedIntentHash,
                    resolvedPlan = Copy(profile.resolvedPlan),
                    reviewState = profile.reviewState,
                };
            end
        end
        return result;
    end



end;
AMT_BundledModules["amt_mc_requests"] = function()


    -- M3 request model module (pure logic, no game API).
    --
    -- Implements PlanRequest per MULTICITY_UPGRADE_PLAN section 5.3 and the
    -- request interaction rules of section 7.1.  Requests are produced by the
    -- adapter layer from per-city resolvedPlans; this module only validates,
    -- identifies, and links them.
    --
    -- Extensions beyond section 5.3 are derived, documented fields that the
    -- adapter fills in: limitGroup (player/world limited subject grouping),
    -- mutualExclusionGroup (districts that cannot both be planned for the same
    -- city), and influenceScope (LOCAL/CITY/GLOBAL/UNKNOWN, section 7.1).

    AMT_MultiCity = AMT_MultiCity or {};
    AMT_MultiCity.Requests = AMT_MultiCity.Requests or {};

    local Requests = AMT_MultiCity.Requests;
    local Contract = AMT_MultiCity.Contract;

    Requests.SCHEMA_VERSION = 1;

    Requests.SCOPE_CITY = "CITY";
    Requests.SCOPE_CLUSTER = "CLUSTER";
    Requests.SCOPE_PLAYER = "PLAYER";
    Requests.SCOPE_WORLD = "WORLD";

    Requests.SCOPES = {
        [Requests.SCOPE_CITY] = true,
        [Requests.SCOPE_CLUSTER] = true,
        [Requests.SCOPE_PLAYER] = true,
        [Requests.SCOPE_WORLD] = true,
    };

    Requests.INFLUENCE_LOCAL = "LOCAL";
    Requests.INFLUENCE_CITY = "CITY";
    Requests.INFLUENCE_GLOBAL = "GLOBAL";
    Requests.INFLUENCE_UNKNOWN = "UNKNOWN";

    -- Global/unknown influence forces a single interaction component (plan
    -- section 7.2 step 3-4 and rule 7).
    Requests.GLOBAL_INFLUENCE = {
        [Requests.INFLUENCE_CITY] = true,
        [Requests.INFLUENCE_GLOBAL] = true,
        [Requests.INFLUENCE_UNKNOWN] = true,
    };

    Requests.PLAN_REQUEST_FIELDS = {
        "requestID", "scope", "eligibleParticipantIDs", "eligibleCityIDs",
        "subjectType", "subjectOptions", "cardinalityMin", "cardinalityMax",
        "optional", "slotCost", "priorityByParticipant",
        "satisfactionPredicate", "coverageTarget", "supportPolicy",
    };

    -- Validates a request against the section 5.3 contract.  Returns true, or
    -- false plus a reason string.  Derived fields (limitGroup,
    -- mutualExclusionGroup, influenceScope) are optional and defaulted.
    function Requests.Validate(request)
        if type(request) ~= "table" then
            return false, "request is not a table";
        end
        for _, field in ipairs(Requests.PLAN_REQUEST_FIELDS) do
            if request[field] == nil then
                return false, "missing field: " .. field;
            end
        end
        if type(request.requestID) ~= "string" or request.requestID == "" then
            return false, "requestID must be a non-empty string";
        end
        if not Requests.SCOPES[request.scope] then
            return false, "unknown scope: " .. tostring(request.scope);
        end
        if type(request.eligibleParticipantIDs) ~= "table" then
            return false, "eligibleParticipantIDs is not an array";
        end
        for _, participantID in ipairs(request.eligibleParticipantIDs) do
            if type(participantID) ~= "string"
                or not string.find(participantID, ":", 1, true) then
                return false, "bad participant id: " .. tostring(participantID);
            end
        end
        if request.eligibleCityIDs ~= nil
            and type(request.eligibleCityIDs) ~= "table" then
            return false, "eligibleCityIDs is not an array";
        end
        local cardinalityMin = tonumber(request.cardinalityMin);
        local cardinalityMax = tonumber(request.cardinalityMax);
        if not cardinalityMin or not cardinalityMax
            or cardinalityMin < 0 or cardinalityMax < 0
            or cardinalityMin > cardinalityMax
            or cardinalityMin ~= math.floor(cardinalityMin)
            or cardinalityMax ~= math.floor(cardinalityMax) then
            return false, "bad cardinality bounds";
        end
        if tonumber(request.slotCost) == nil or request.slotCost < 0 then
            return false, "bad slotCost";
        end
        if type(request.priorityByParticipant) ~= "table" then
            return false, "priorityByParticipant is not a table";
        end
        return true;
    end

    -- Defaults derived fields on a copy (never mutates the input).
    function Requests.Normalize(request)
        local copy = {};
        -- Deep-ish copy through pairs; arrays are rebuilt in place.
        for key, value in pairs(request) do
            if type(value) == "table" then
                local inner = {};
                for innerKey, innerValue in pairs(value) do
                    inner[innerKey] = innerValue;
                end
                copy[key] = inner;
            else
                copy[key] = value;
            end
        end
        copy.eligibleParticipantIDs = Contract.SortedArray(
            copy.eligibleParticipantIDs or {}
        );
        if copy.eligibleCityIDs then
            copy.eligibleCityIDs = Contract.SortedArray(copy.eligibleCityIDs);
        end
        copy.slotCost = tonumber(copy.slotCost) or 0;
        copy.cardinalityMin = tonumber(copy.cardinalityMin) or 0;
        copy.cardinalityMax = tonumber(copy.cardinalityMax) or 0;
        copy.influenceScope = copy.influenceScope or Requests.INFLUENCE_LOCAL;
        copy.limitGroup = copy.limitGroup or nil;
        copy.mutualExclusionGroup = copy.mutualExclusionGroup or nil;
        return copy;
    end

    -- Stable request identity (plan section 5.3: requestID).  The ID covers
    -- every field that changes what the request asks for; display names never
    -- participate.
    function Requests.RequestID(request)
        return Contract.Hash({
            scope = request.scope,
            subjectType = request.subjectType,
            subjectOptions = request.subjectOptions,
            eligibleParticipantIDs = Contract.SortedArray(
                request.eligibleParticipantIDs or {}
            ),
            eligibleCityIDs = Contract.SortedArray(
                request.eligibleCityIDs or {}
            ),
            supportPolicy = request.supportPolicy,
            coverageTarget = request.coverageTarget,
        });
    end

    -- True when the request targets exactly one real city (CITY scope).
    function Requests.IsCityScoped(request)
        return request.scope == Requests.SCOPE_CITY;
    end

    -- True when the request consumes population slots of its eligible city.
    function Requests.ConsumesSpecialtySlot(request)
        return request.scope == Requests.SCOPE_CITY
            and (tonumber(request.slotCost) or 0) > 0;
    end

    function Requests.IsPlayerLimited(request)
        return request.scope == Requests.SCOPE_PLAYER;
    end

    function Requests.IsWorldLimited(request)
        return request.scope == Requests.SCOPE_WORLD;
    end

    function Requests.HasGlobalInfluence(request)
        return Requests.GLOBAL_INFLUENCE[
            request.influenceScope or Requests.INFLUENCE_LOCAL
        ] == true;
    end

    -- Which participants may satisfy this request (section 5.3).
    function Requests.EligibleForParticipant(request, participantID)
        for _, eligibleID in ipairs(request.eligibleParticipantIDs or {}) do
            if eligibleID == participantID then return true; end
        end
        return false;
    end

    -- Which cities may satisfy a CITY-scope request.  Future city siteIDs are
    -- never valid here (rule 7: no forged cityIDs).
    function Requests.EligibleForCity(request, cityID)
        if not Requests.IsCityScoped(request) then return false; end
        for _, eligibleID in ipairs(request.eligibleCityIDs or {}) do
            if eligibleID == cityID then return true; end
        end
        return false;
    end

    -- ---------------------------------------------------------------------------
    -- Request interaction rules (plan section 7.1), metadata part.
    -- ---------------------------------------------------------------------------

    -- Two requests interact purely through their metadata when any of these
    -- holds:
    --   * both consume slots of the same eligible city (population slots);
    --   * they share a mutual-exclusion group and share an eligible city
    --     (one-per-city / exclusive districts);
    --   * both are player- or world-limited and share a limit group;
    --   * one is listed as a support request of the other's support policy
    --     (wonder support chains).
    function Requests.InteractByMetadata(first, second)
        if first.requestID == second.requestID then return false; end
        if Requests.ConsumesSpecialtySlot(first)
            and Requests.ConsumesSpecialtySlot(second)
            and Requests.ShareEligibleCity(first, second) then
            return true;
        end
        if first.mutualExclusionGroup
            and first.mutualExclusionGroup == second.mutualExclusionGroup
            and Requests.ShareEligibleCity(first, second) then
            return true;
        end
        local firstLimited = Requests.IsPlayerLimited(first)
            or Requests.IsWorldLimited(first);
        local secondLimited = Requests.IsPlayerLimited(second)
            or Requests.IsWorldLimited(second);
        if firstLimited and secondLimited
            and first.limitGroup and first.limitGroup == second.limitGroup then
            return true;
        end
        if Requests.Supports(first, second.requestID)
            or Requests.Supports(second, first.requestID) then
            return true;
        end
        return false;
    end

    function Requests.ShareEligibleCity(first, second)
        if not first.eligibleCityIDs or not second.eligibleCityIDs then
            return false;
        end
        local citySet = {};
        for _, cityID in ipairs(first.eligibleCityIDs) do
            citySet[cityID] = true;
        end
        for _, cityID in ipairs(second.eligibleCityIDs) do
            if citySet[cityID] then return true; end
        end
        return false;
    end

    -- True when `request` lists `targetRequestID` in its support policy.
    function Requests.Supports(request, targetRequestID)
        local policy = request.supportPolicy;
        if type(policy) ~= "table" then return false; end
        local supportIDs = policy.supportRequestIDs;
        if type(supportIDs) ~= "table" then return false; end
        for _, supportID in ipairs(supportIDs) do
            if supportID == targetRequestID then return true; end
        end
        return false;
    end

    -- ---------------------------------------------------------------------------
    -- Candidate-based interaction (plan section 7.1, plot part).
    -- ---------------------------------------------------------------------------

    -- candidatesFor[requestID] = array of candidate tables.  A candidate is the
    -- section 5.4 shape; only plotKey, adjacentPlotKeys, coveredParticipantIDs
    -- and influenceScope are read here.
    -- Two requests interact when any candidate of one shares a plot key, an
    -- adjacent plot key, or a covered participant with any candidate of the
    -- other.  UNKNOWN/CITY/GLOBAL influence makes the request connect to every
    -- other request (conservative, rule 7).
    function Requests.InteractByCandidates(
        first, second, candidatesForFirst, candidatesForSecond
    )
        return Requests.InteractByCandidateSets(
            first, second,
            Requests.CandidatePlotKeySet(candidatesForFirst),
            Requests.CandidatePlotKeySet(candidatesForSecond)
        );
    end

    function Requests.InteractByCandidateSets(first, second, firstKeys, secondKeys)
        if Requests.HasGlobalInfluence(first)
            or Requests.HasGlobalInfluence(second) then
            return true;
        end
        for key in pairs(firstKeys.plots or {}) do
            if secondKeys.plots[key] or secondKeys.adjacent[key] then
                return true;
            end
        end
        for key in pairs(firstKeys.adjacent or {}) do
            if secondKeys.plots[key] then return true; end
        end
        for participantID in pairs(firstKeys.covered or {}) do
            if secondKeys.covered[participantID] then return true; end
        end
        return false;
    end

    -- Collects { plots, adjacent, covered } sets from a candidate list.
    function Requests.CandidatePlotKeySet(candidates)
        local result = { plots = {}, adjacent = {}, covered = {} };
        for _, candidate in ipairs(candidates or {}) do
            if candidate.plotKey then
                result.plots[candidate.plotKey] = true;
            end
            for _, adjacentKey in ipairs(candidate.adjacentPlotKeys or {}) do
                result.adjacent[adjacentKey] = true;
            end
            for _, participantID in ipairs(
                candidate.coveredParticipantIDs or {}
            ) do
                result.covered[participantID] = true;
            end
        end
        return result;
    end

    -- ---------------------------------------------------------------------------
    -- Interaction graph (plan section 7.2 step 3).
    -- ---------------------------------------------------------------------------

    -- requests: array of normalized requests (requestID unique).
    -- candidatesFor: map requestID -> candidate array (may be empty).
    -- Returns { adjacency, components }:
    --   adjacency[requestID] = sorted array of interacting request ids
    --   components = array of maps { requestID = true }, deterministically
    --   discovered in request order (BFS from the first unseen request).
    function Requests.BuildInteractionGraph(requests, candidatesFor)
        local order = {};
        local byID = {};
        for _, request in ipairs(requests or {}) do
            if byID[request.requestID] == nil then
                byID[request.requestID] = request;
                table.insert(order, request.requestID);
            end
        end
        local adjacency = {};
        for _, requestID in ipairs(order) do
            adjacency[requestID] = {};
        end
        -- Candidate key sets are built once per request; the pairwise loop
        -- below would otherwise rebuild the same plot/adjacent/covered sets
        -- O(requestCount) times each.
        local candidateSets = {};
        for _, requestID in ipairs(order) do
            candidateSets[requestID] = Requests.CandidatePlotKeySet(
                candidatesFor and candidatesFor[requestID] or {}
            );
        end
        for firstIndex = 1, #order do
            for secondIndex = firstIndex + 1, #order do
                local firstID = order[firstIndex];
                local secondID = order[secondIndex];
                local first = byID[firstID];
                local second = byID[secondID];
                local linked = Requests.InteractByMetadata(first, second)
                    or Requests.InteractByCandidateSets(
                        first, second,
                        candidateSets[firstID], candidateSets[secondID]
                    );
                if linked then
                    adjacency[firstID][secondID] = true;
                    adjacency[secondID][firstID] = true;
                end
            end
        end
        local components = {};
        local seen = {};
        for _, startID in ipairs(order) do
            if not seen[startID] then
                local component = {};
                local queue = { startID };
                seen[startID] = true;
                local head = 1;
                while head <= #queue do
                    local currentID = queue[head];
                    head = head + 1;
                    component[currentID] = true;
                    for neighborID in pairs(adjacency[currentID] or {}) do
                        if not seen[neighborID] then
                            seen[neighborID] = true;
                            table.insert(queue, neighborID);
                        end
                    end
                end
                table.insert(components, component);
            end
        end
        -- Deterministic adjacency lists.
        local sortedAdjacency = {};
        for _, requestID in ipairs(order) do
            sortedAdjacency[requestID] = Contract.SortedKeys(
                adjacency[requestID]
            );
        end
        return { adjacency = sortedAdjacency, components = components };
    end



end;
AMT_BundledModules["amt_mc_solver"] = function()


    -- M3 joint solver core (pure logic, no game API).
    --
    -- Implements the candidate contract (plan section 5.4), search-state
    -- contract (5.5), lexicographic objective (section 6), and the deterministic
    -- beam search over request interaction components (7.2).  The adapter layer
    -- supplies contract-shaped candidates and an evaluator callback; DMT final
    -- legality is the evaluator's job, and this module never bypasses it.
    --
    -- Budget rule (section 10): exceeding the evaluation budget returns an
    -- explicit failure status and never silently applies a partial plan.

    AMT_MultiCity = AMT_MultiCity or {};
    AMT_MultiCity.Solver = AMT_MultiCity.Solver or {};

    local Solver = AMT_MultiCity.Solver;
    local Contract = AMT_MultiCity.Contract;

    -- Runtime self-test: the solver must capture the exact-FNV contract that
    -- loaded before it.  same=true, fnvType=function and fnv=89f341ef mean the
    -- fresh module chain is in effect.


    Solver.SCHEMA_VERSION = 1;
    Solver.DEFAULT_BEAM_WIDTH = 64;
    Solver.DEFAULT_MAX_PLANS = 3;
    Solver.DEFAULT_GOVERNMENT_HUB_WEIGHT = 0.20;
    Solver.DEFAULT_GOVERNMENT_HUB_FREE_NEIGHBORS = 1;
    Solver.DEFAULT_GOVERNMENT_HUB_CAP = 1.00;
    -- Sort strategy contract (PERFORMANCE_UX_EXECUTION_PLAN P0).  V2: every
    -- state-sort call site resolves rank ties through the layout tieBreaker,
    -- which returns nil for equal layouts so the per-state signature total
    -- order always decides.  Without a total order, layout-tied states fall
    -- into one table.sort equivalence class and their relative order becomes
    -- Lua-runtime defined, which broke cross-runtime strict replay.
    Solver.SORT_STRATEGY = "AMT_MC_SORT_TIEBREAK_V2";

    -- ---------------------------------------------------------------------------
    -- Candidate contract (plan section 5.4).
    -- ---------------------------------------------------------------------------
    Solver.CANDIDATE_FIELDS = {
        "subjectType", "subjectKey", "plotIndex", "plotKey",
        "planningParticipantID", "requestID", "supportBundleSignature",
        "slotIndex", "priorityTuple",
        "coveredParticipantIDs", "resourceVisibilityClass",
        "influenceScope", "supportRequestIDs",
    };

    -- Stable candidate identity.  The same unpurchased border plot planned by
    -- two different cities yields two different candidates (rule 7).
    function Solver.CandidateID(candidate)
        local cached = candidate.cachedCandidateID;
        if cached then return cached; end
        cached = Contract.Hash({
            subjectType = candidate.subjectType,
            subjectKey = candidate.subjectKey,
            plotIndex = candidate.plotIndex,
            planningParticipantID = candidate.planningParticipantID,
            planningCityID = candidate.planningCityID or nil,
            planningSiteID = candidate.planningSiteID or nil,
            requestID = candidate.requestID,
            supportBundleSignature = candidate.supportBundleSignature or nil,
        });
        candidate.cachedCandidateID = cached;
        return cached;
    end

    function Solver.ValidateCandidate(candidate, request)
        if type(candidate) ~= "table" then
            return false, "candidate is not a table";
        end
        for _, field in ipairs(Solver.CANDIDATE_FIELDS) do
            if candidate[field] == nil then
                return false, "candidate missing field: " .. field;
            end
        end
        if candidate.plotIndex == nil
            or tonumber(candidate.plotIndex) == nil then
            return false, "candidate plotIndex must be numeric";
        end
        if type(candidate.plotKey) ~= "string"
            or candidate.plotKey == "" then
            return false, "candidate plotKey must be a string";
        end
        if type(candidate.planningParticipantID) ~= "string" then
            return false, "candidate planningParticipantID must be a string";
        end
        if request and candidate.requestID ~= request.requestID then
            return false, "candidate request mismatch";
        end
        if request and not RequestEligible(request, candidate) then
            return false, "candidate participant not eligible for request";
        end
        return true;
    end

    -- Real-city candidates must carry a real cityID; future cities must use a
    -- siteID and never forge a cityID (rule 7).
    function Solver.CheckCityIdentity(candidate, participantKind)
        if participantKind == "REAL_CITY" then
            if candidate.planningCityID == nil then
                return false, "real city candidate missing planningCityID";
            end
            if candidate.planningSiteID ~= nil then
                return false, "real city candidate must not carry siteID";
            end
        elseif participantKind == "FUTURE_CITY" then
            if candidate.planningSiteID == nil then
                return false, "future city candidate missing planningSiteID";
            end
            if candidate.planningCityID ~= nil then
                return false, "future city candidate must not forge cityID";
            end
        end
        return true;
    end

    function RequestEligible(request, candidate)
        local eligible = false;
        for _, participantID in ipairs(request.eligibleParticipantIDs or {}) do
            if participantID == candidate.planningParticipantID then
                eligible = true;
            end
        end
        if not eligible then return false; end
        if request.scope == "CITY" and request.eligibleCityIDs then
            local cityEligible = false;
            for _, cityID in ipairs(request.eligibleCityIDs) do
                if cityID == candidate.planningCityID then
                    cityEligible = true;
                end
            end
            return cityEligible;
        end
        return true;
    end

    -- Deterministic candidate ordering: priorityTuple descending, then
    -- candidateID ascending (stable, no random tie-breaking).
    function Solver.CompareCandidates(first, second)
        local firstTuple = first.priorityTuple or {};
        local secondTuple = second.priorityTuple or {};
        local length = math.max(#firstTuple, #secondTuple);
        for index = 1, length do
            local firstValue = tonumber(firstTuple[index]) or 0;
            local secondValue = tonumber(secondTuple[index]) or 0;
            if firstValue ~= secondValue then
                return firstValue > secondValue;
            end
        end
        return Solver.CandidateID(first) < Solver.CandidateID(second);
    end

    function Solver.SortCandidates(candidates)
        local copy = {};
        for index = 1, #(candidates or {}) do
            copy[index] = candidates[index];
        end
        table.sort(copy, Solver.CompareCandidates);
        return copy;
    end

    -- Build a cheap, intent-local estimate of how much room each Government
    -- Plaza candidate leaves for the other districts requested by the same
    -- participant.  This is deliberately not a legality oracle: the adapter has
    -- already produced the DMT-approved candidate lists, and full projected DMT
    -- evaluation remains the primary score and final judgement.
    function Solver.BuildGovernmentHubPotentials(candidatesFor)
        local districtPlotsByParticipant = {};
        local governmentCandidates = {};
        for _, candidates in pairs(candidatesFor or {}) do
            for _, candidate in ipairs(candidates or {}) do
                local subjectKey = tostring(candidate.subjectKey or "");
                local isDistrict = string.sub(subjectKey, 1, 9) == "DISTRICT_";
                if isDistrict and subjectKey == "DISTRICT_GOVERNMENT" then
                    governmentCandidates[#governmentCandidates + 1] = candidate;
                elseif isDistrict then
                    local participantID = candidate.planningParticipantID;
                    if participantID ~= nil and candidate.plotKey ~= nil then
                        local plots = districtPlotsByParticipant[participantID];
                        if plots == nil then
                            plots = {};
                            districtPlotsByParticipant[participantID] = plots;
                        end
                        plots[candidate.plotKey] = true;
                    end
                end
            end
        end

        local potentials = {};
        for _, candidate in ipairs(governmentCandidates) do
            local plots = districtPlotsByParticipant[
                candidate.planningParticipantID
            ] or {};
            local seen = {};
            local count = 0;
            for _, plotKey in ipairs(candidate.adjacentPlotKeys or {}) do
                if plots[plotKey] and not seen[plotKey] then
                    seen[plotKey] = true;
                    count = count + 1;
                end
            end
            potentials[Solver.CandidateID(candidate)] = count;
        end
        return potentials;
    end

    -- A bounded secondary preference only.  One feasible neighbouring district
    -- is free, every additional option contributes a small amount, and the total
    -- is capped at one point by default.  Consequently a central site can break
    -- a close score but cannot override a material DMT adjacency or tile-value
    -- advantage.
    function Solver.GovernmentHubPreference(state, potentials, options)
        options = options or {};
        local weight = tonumber(options.weight)
            or Solver.DEFAULT_GOVERNMENT_HUB_WEIGHT;
        local freeNeighbors = tonumber(options.freeNeighbors)
            or Solver.DEFAULT_GOVERNMENT_HUB_FREE_NEIGHBORS;
        local cap = tonumber(options.cap)
            or Solver.DEFAULT_GOVERNMENT_HUB_CAP;
        weight = math.max(0, weight);
        freeNeighbors = math.max(0, freeNeighbors);
        cap = math.max(0, cap);

        local totalBonus = 0;
        local bestPotential = 0;
        for _, item in ipairs(state and state.items or {}) do
            local candidate = item and item.candidate or nil;
            if candidate
                and candidate.subjectKey == "DISTRICT_GOVERNMENT" then
                local potential = tonumber(
                    potentials and potentials[Solver.CandidateID(candidate)]
                ) or 0;
                bestPotential = math.max(bestPotential, potential);
                totalBonus = totalBonus + math.min(
                    cap,
                    math.max(0, potential - freeNeighbors) * weight
                );
            end
        end
        return totalBonus, bestPotential;
    end

    -- ---------------------------------------------------------------------------
    -- Deep copy for ordinary solver-owned tables.
    -- ---------------------------------------------------------------------------
    local function Copy(value, seen)
        if type(value) ~= "table" then return value; end
        -- Civ VI exposes plots as table-like engine proxies.  Recursing through
        -- one strips its runtime methods and forces the adapter to call
        -- Map.GetPlot again for every evaluated branch.  Plots are read-only
        -- during search, so preserve the opaque engine reference.
        if type(value.GetX) == "function"
            and type(value.GetY) == "function"
            and type(value.GetYield) == "function"
            and type(value.GetResourceType) == "function" then
            return value;
        end
        seen = seen or {};
        if seen[value] then return seen[value]; end
        local result = {};
        seen[value] = result;
        for key, item in pairs(value) do
            result[Copy(key, seen)] = Copy(item, seen);
        end
        return result;
    end

    -- ---------------------------------------------------------------------------
    -- Search state contract (plan section 5.5).
    -- ---------------------------------------------------------------------------
    function Solver.NewSearchState(participantSlots)
        return {
            schemaVersion = Solver.SCHEMA_VERSION,
            items = {},
            occupiedPlotKeys = {},
            fulfilledRequestIDs = {},
            specialtyUsedByParticipant = {},
            districtStrategyCountsByParticipant = {},
            exclusionByParticipant = {},
            playerLimitedCounts = {},
            globalLimitedCounts = {},
            coverageByServiceAndParticipant = {},
            strategicResourceCountsByParticipant = {},
            perParticipantSlotFulfillment = {},
            improvementUsedByParticipant = {},
            score = 0,
            legal = false,
            evaluatorFields = {},
            participantSlots = Copy(participantSlots or {}),
        };
    end

    function Solver.CopyState(state)
        return Copy(state);
    end

    -- Pure constraint check for adding one candidate to a state.
    -- Returns true, or false plus a reason string.
    function Solver.CanAddSingle(state, candidate, request)
        if state.occupiedPlotKeys[candidate.plotKey] then
            return false, "plot occupied";
        end
        local fulfilled = (state.fulfilledRequestIDs[request.requestID] or 0);
        if fulfilled >= (tonumber(request.cardinalityMax) or 0) then
            return false, "request already fulfilled to max";
        end
        local slotCost = tonumber(request.slotCost) or 0;
        local participantID = candidate.planningParticipantID;
        if slotCost > 0 then
            local used = state.specialtyUsedByParticipant[participantID] or 0;
            local slots = tonumber(state.participantSlots[participantID]) or 0;
            if used + slotCost > slots then
                return false, "specialty slots exhausted";
            end
            local slotIndex = tonumber(candidate.slotIndex) or 0;
            if slotIndex > 0 then
                local fulfillment =
                    state.perParticipantSlotFulfillment[participantID] or {};
                if fulfillment[slotIndex] ~= nil then
                    return false, "slot index already fulfilled";
                end
            end
        end
        if candidate.districtStrategy then
            local strategyCounts =
                state.districtStrategyCountsByParticipant[participantID] or {};
            local strategyLimit = tonumber(candidate.strategyLimitByParticipant)
                or 0;
            if strategyLimit > 0
                and (strategyCounts[candidate.districtStrategy] or 0)
                    >= strategyLimit then
                return false, "one-per-city strategy limit";
            end
        end
        local exclusionGroup = request.mutualExclusionGroup;
        if exclusionGroup and candidate.subjectKey then
            local exclusions = state.exclusionByParticipant[participantID] or {};
            local existing = exclusions[exclusionGroup];
            if existing ~= nil and existing ~= candidate.subjectKey then
                return false, "mutual exclusion with " .. tostring(existing);
            end
        end
        if request.limitGroup then
            local limit = tonumber(request.limitMax)
                or tonumber(request.cardinalityMax) or 0;
            local counter = request.limitScope == "WORLD"
                and state.globalLimitedCounts
                or state.playerLimitedCounts;
            if (counter[request.limitGroup] or 0) >= limit then
                return false, "player/world limit reached";
            end
        end
        if request.budgetByParticipant then
            local budget = tonumber(
                request.budgetByParticipant[participantID]
            );
            if budget ~= nil then
                local used = state.improvementUsedByParticipant[
                    participantID
                ] or 0;
                if used >= budget then
                    return false, "improvement budget exhausted";
                end
            end
        end
        return true;
    end

    -- Applies one candidate to a state (caller already checked CanAddSingle).
    function Solver.ApplySingle(state, candidate, request)
        table.insert(state.items, { candidate = candidate, request = request });
        state.occupiedPlotKeys[candidate.plotKey] = true;
        state.fulfilledRequestIDs[request.requestID] =
            (state.fulfilledRequestIDs[request.requestID] or 0) + 1;

        local participantID = candidate.planningParticipantID;
        local slotCost = tonumber(request.slotCost) or 0;
        if slotCost > 0 then
            state.specialtyUsedByParticipant[participantID] =
                (state.specialtyUsedByParticipant[participantID] or 0) + slotCost;
            local slotIndex = tonumber(candidate.slotIndex) or 0;
            if slotIndex > 0 then
                local fulfillment =
                    state.perParticipantSlotFulfillment[participantID] or {};
                if fulfillment[slotIndex] == nil then
                    state.perParticipantSlotFulfillment[participantID]
                        = fulfillment;
                end
                fulfillment[slotIndex] = candidate.candidateID
                    or Solver.CandidateID(candidate);
            end
        end
        if candidate.districtStrategy then
            local strategyCounts =
                state.districtStrategyCountsByParticipant[participantID] or {};
            strategyCounts[candidate.districtStrategy] =
                (strategyCounts[candidate.districtStrategy] or 0) + 1;
            state.districtStrategyCountsByParticipant[participantID]
                = strategyCounts;
        end
        local exclusionGroup = request.mutualExclusionGroup;
        if exclusionGroup and candidate.subjectKey then
            local exclusions = state.exclusionByParticipant[participantID] or {};
            if exclusions[exclusionGroup] == nil then
                state.exclusionByParticipant[participantID] = exclusions;
            end
            exclusions[exclusionGroup] = candidate.subjectKey;
        end
        if request.limitGroup then
            local counter = request.limitScope == "WORLD"
                and state.globalLimitedCounts
                or state.playerLimitedCounts;
            counter[request.limitGroup] =
                (counter[request.limitGroup] or 0) + 1;
        end
        for _, participantCovered in ipairs(
            candidate.coveredParticipantIDs or {}
        ) do
            local service = candidate.coverageService or "DEFAULT";
            local byParticipant =
                state.coverageByServiceAndParticipant[service] or {};
            byParticipant[participantCovered] =
                (byParticipant[participantCovered] or 0) + 1;
            state.coverageByServiceAndParticipant[service] = byParticipant;
        end
        if candidate.strategicResourceType then
            local counts =
                state.strategicResourceCountsByParticipant[participantID] or {};
            counts[candidate.strategicResourceType] =
                (counts[candidate.strategicResourceType] or 0) + 1;
            state.strategicResourceCountsByParticipant[participantID] = counts;
        end
        if request.budgetByParticipant
            and request.budgetByParticipant[participantID] ~= nil then
            state.improvementUsedByParticipant[participantID] =
                (state.improvementUsedByParticipant[participantID] or 0) + 1;
        end
        state.cachedSignature = nil;
        state.cachedLayoutSignature = nil;
        return state;
    end

    -- ---------------------------------------------------------------------------
    -- Wonder support bundles (plan section 8.2): a candidate may carry
    -- supportCandidates = { { candidate = ..., request = ... }, ... } that are
    -- applied atomically together with the main candidate.  Supports must be
    -- same-city (rule 7): the adapter asserts this before solving.
    -- ---------------------------------------------------------------------------

    function Solver.ValidateBundleCityIdentity(candidate)
        local cityID = candidate.planningCityID;
        local participantID = candidate.planningParticipantID;
        for _, supportEntry in ipairs(candidate.supportCandidates or {}) do
            local support = supportEntry.candidate;
            if support.planningCityID ~= cityID then
                return false, "support city differs from wonder city";
            end
            if support.planningParticipantID ~= participantID then
                return false, "support participant differs from wonder";
            end
        end
        return true;
    end

    function Solver.CanAddCandidate(state, candidate, request)
        local supports = candidate.supportCandidates;
        if not supports or #supports == 0 then
            -- Hot path: ordinary candidates never need a scratch state copy.
            return Solver.CanAddSingle(state, candidate, request);
        end
        local scratch = Solver.CopyState(state);
        for _, supportEntry in ipairs(supports) do
            local ok, reason = Solver.CanAddSingle(
                scratch, supportEntry.candidate, supportEntry.request
            );
            if not ok then
                return false, "support " .. reason;
            end
            Solver.ApplySingle(
                scratch, supportEntry.candidate, supportEntry.request
            );
        end
        return Solver.CanAddSingle(scratch, candidate, request);
    end

    function Solver.ApplyCandidate(state, candidate, request)
        for _, supportEntry in ipairs(candidate.supportCandidates or {}) do
            Solver.ApplySingle(
                state, supportEntry.candidate, supportEntry.request
            );
        end
        return Solver.ApplySingle(state, candidate, request);
    end

    -- Stable search-state signature (plan section 5.5): every field that can
    -- affect future expansion is hashed.  Items are ordered by candidateID so
    -- equivalent sets produce one signature.
    function Solver.StateSignature(state)
        local itemParts = {};
        for _, item in ipairs(state.items or {}) do
            table.insert(itemParts, {
                candidateID = item.candidate.candidateID
                    or Solver.CandidateID(item.candidate),
                requestID = item.request.requestID,
            });
        end
        table.sort(itemParts, function(first, second)
            if first.candidateID ~= second.candidateID then
                return first.candidateID < second.candidateID;
            end
            return first.requestID < second.requestID;
        end);
        local signature = {
            schemaVersion = state.schemaVersion,
            items = itemParts,
            fulfilledRequestIDs = state.fulfilledRequestIDs,
            specialtyUsedByParticipant = state.specialtyUsedByParticipant,
            districtStrategyCountsByParticipant =
                state.districtStrategyCountsByParticipant,
            exclusionByParticipant = state.exclusionByParticipant,
            playerLimitedCounts = state.playerLimitedCounts,
            globalLimitedCounts = state.globalLimitedCounts,
            coverageByServiceAndParticipant =
                state.coverageByServiceAndParticipant,
            strategicResourceCountsByParticipant =
                state.strategicResourceCountsByParticipant,
            perParticipantSlotFulfillment =
                state.perParticipantSlotFulfillment,
            improvementUsedByParticipant =
                state.improvementUsedByParticipant,
            participantSlots = state.participantSlots,
        };
        return Contract.Hash(signature);
    end

    -- Layout signature: distinct layouts (plan section 4.3).  Same layout
    -- content with different city ownership already differs through candidateID.
    function Solver.LayoutSignature(state)
        local plotKeys = {};
        for _, item in ipairs(state.items or {}) do
            table.insert(plotKeys, item.candidate.plotKey);
        end
        return Contract.Hash(Contract.SortedArray(plotKeys));
    end

    -- Memoized signatures.  Signatures only change when a candidate is applied
    -- or states are merged, so ApplySingle/ApplyCandidate/MergeStates clear the
    -- caches.  The cached values never enter StateSignature themselves, so the
    -- stable hashes are byte-identical to the uncached implementation.
    function Solver.SignatureOf(state)
        local cached = state.cachedSignature;
        if cached then return cached; end
        cached = Solver.StateSignature(state);
        state.cachedSignature = cached;
        return cached;
    end

    function Solver.LayoutSignatureOf(state)
        local cached = state.cachedLayoutSignature;
        if cached then return cached; end
        cached = Solver.LayoutSignature(state);
        state.cachedLayoutSignature = cached;
        return cached;
    end

    -- Deterministic state sort with per-state rank/signature caching.  The
    -- optional tieBreaker preserves the exact call-site tie semantics; ranks and
    -- signatures are computed once per state instead of once per comparison.
    -- tieBreaker must return nil when its keys are equal; false is a final
    -- ordering decision and deliberately does not fall through to signatures.
    function Solver.SortStates(states, participantOrder, slotLevels, requests,
                               tieBreaker)
        local ranks = {};
        local signatures = {};
        local layouts = {};
        for _, state in ipairs(states or {}) do
            ranks[state] = Solver.BuildRank(
                state, participantOrder, slotLevels, requests
            );
            signatures[state] = Solver.SignatureOf(state);
            -- Beam truncation has no layout tie-break.  Most of its states are
            -- discarded, so leave their layout hashes uncomputed until needed.
            if tieBreaker then
                layouts[state] = Solver.LayoutSignatureOf(state);
            end
        end
        table.sort(states, function(first, second)
            local order = CompareArrays(ranks[first], ranks[second]);
            if order ~= 0 then return order == -1; end
            if tieBreaker then
                local tie = tieBreaker(first, second, layouts, signatures);
                if tie ~= nil then return tie; end
            end
            return signatures[first] < signatures[second];
        end);
        return states;
    end

    -- ---------------------------------------------------------------------------
    -- Completeness and lexicographic objective (plan section 6).
    -- ---------------------------------------------------------------------------
    function Solver.IsComplete(state, requests)
        for _, request in ipairs(requests or {}) do
            if not request.optional then
                local fulfilled =
                    state.fulfilledRequestIDs[request.requestID] or 0;
                if fulfilled < (tonumber(request.cardinalityMin) or 0) then
                    return false;
                end
            end
        end
        for _, item in ipairs(state.items or {}) do
            for _, supportID in ipairs(
                item.candidate.supportRequestIDs or {}
            ) do
                if (state.fulfilledRequestIDs[supportID] or 0) == 0 then
                    return false;
                end
            end
        end
        return true;
    end

    -- Per-slot fulfillment vector across participants (plan section 6 items
    -- 3-5): vector[index] = number of participants whose slot `index` is
    -- fulfilled.  slotLevels bounds the vector so every state compares with the
    -- same length.
    function Solver.SlotFulfillmentVector(state, participantOrder, slotLevels)
        local vector = {};
        for level = 1, (tonumber(slotLevels) or 0) do
            vector[level] = 0;
        end
        for _, participantID in ipairs(participantOrder or {}) do
            local fulfillment =
                state.perParticipantSlotFulfillment[participantID] or {};
            for level = 1, (tonumber(slotLevels) or 0) do
                if fulfillment[level] ~= nil then
                    vector[level] = vector[level] + 1;
                end
            end
        end
        return vector;
    end

    function Solver.RequiredWonderFulfillment(state, requests)
        local count = 0;
        for _, request in ipairs(requests or {}) do
            if not request.optional and request.subjectType == "WONDER" then
                if (state.fulfilledRequestIDs[request.requestID] or 0)
                    >= (tonumber(request.cardinalityMin) or 0) then
                    count = count + 1;
                end
            end
        end
        return count;
    end

    -- Full lexicographic rank.  Lower gap and redundancy are better; the rank
    -- stores negated values so a plain ascending compare works.
    function Solver.BuildRank(state, participantOrder, slotLevels, requests)
        local evaluatorFields = state.evaluatorFields or {};
        local rank = {};
        rank[1] = state.legal and 1 or 0;
        rank[2] = Solver.RequiredWonderFulfillment(state, requests);
        local vector = Solver.SlotFulfillmentVector(
            state, participantOrder, slotLevels
        );
        for level = 1, #vector do
            rank[2 + level] = vector[level];
        end
        rank[#rank + 1] = tonumber(evaluatorFields.strategicDeveloped) or 0;
        rank[#rank + 1] = -1 * (
            tonumber(evaluatorFields.coverageGap) or 0
        );
        rank[#rank + 1] = tonumber(state.score) or 0;
        rank[#rank + 1] = -1 * (
            tonumber(evaluatorFields.redundantItemCount) or 0
        );
        return rank;
    end

    function CompareArrays(first, second)
        local length = math.max(#first, #second);
        for index = 1, length do
            local firstValue = first[index] or 0;
            local secondValue = second[index] or 0;
            if firstValue ~= secondValue then
                -- Every rank tier is encoded higher-is-better (gaps and
                -- redundancy are negated by BuildRank).
                return firstValue > secondValue and -1 or 1;
            end
        end
        return 0;
    end

    -- Lexicographic comparison: returns -1 when `first` ranks better, 1 when
    -- `second` ranks better, 0 on a tie.
    function Solver.CompareStates(first, second, participantOrder, slotLevels,
                                  requests)
        local firstRank = Solver.BuildRank(
            first, participantOrder, slotLevels, requests
        );
        local secondRank = Solver.BuildRank(
            second, participantOrder, slotLevels, requests
        );
        return CompareArrays(firstRank, secondRank);
    end

    -- ---------------------------------------------------------------------------
    -- Plan pool (plan section 4.3): best plan always kept; up to maxPlans
    -- additional plans only when they are close enough AND layout-distinct.
    -- ---------------------------------------------------------------------------
    function Solver.NewPlanPool(options)
        options = options or {};
        return {
            maxPlans = tonumber(options.maxPlans)
                or Solver.DEFAULT_MAX_PLANS,
            closeGap = tonumber(options.closeGap) or 0.02,
            seedDiversity = options.seedDiversity == true,
            list = {},
            bestScore = nil,
            layoutSignatures = {},
        };
    end

    -- r29 pool policy: any legal, complete, layout-distinct plan is accepted;
    -- the pool always keeps the top `maxPlans` entries by the lexicographic
    -- rank (score is its final tier), so large score gaps no longer hide useful
    -- alternative layouts.  Players judge plan quality themselves.
    -- Seeded stage-two runs (seedDiversity=true) treat each stage-one skeleton
    -- as one diversity slot: improvement variations inside the same skeleton
    -- cannot crowd out the alternative district layouts the player asked for.
    function Solver.PlanPoolAdd(pool, state, participantOrder, slotLevels,
                                requests)
        if not state.legal or not Solver.IsComplete(state, requests) then
            return false;
        end
        local distinctKey = pool.seedDiversity and state.seedGroup
            and ("SEED:" .. tostring(state.seedGroup)) or nil;
        local layout = distinctKey or Solver.LayoutSignatureOf(state);
        if pool.layoutSignatures[layout] then
            return false;
        end
        pool.layoutSignatures[layout] = true;
        table.insert(pool.list, { state = state, relativeGap = 0 });

        local function SortPool()
            local ranks = {};
            for _, entry in ipairs(pool.list) do
                ranks[entry.state] = Solver.BuildRank(
                    entry.state, participantOrder, slotLevels, requests
                );
            end
            table.sort(pool.list, function(first, second)
                local order = CompareArrays(
                    ranks[first.state], ranks[second.state]
                );
                if order ~= 0 then
                    return order == -1;
                end
                local firstKey = pool.seedDiversity
                    and first.state.seedGroup
                    and ("SEED:" .. tostring(first.state.seedGroup))
                    or Solver.LayoutSignatureOf(first.state);
                local secondKey = pool.seedDiversity
                    and second.state.seedGroup
                    and ("SEED:" .. tostring(second.state.seedGroup))
                    or Solver.LayoutSignatureOf(second.state);
                if firstKey ~= secondKey then
                    return firstKey < secondKey;
                end
                -- Layouts can tie when the same occupied plot set carries
                -- different subjects.  The signature tie-break gives table.sort
                -- a total order, keeping cross-run / cross-runtime pruning
                -- deterministic.
                return Solver.SignatureOf(first.state)
                    < Solver.SignatureOf(second.state);
            end);
        end

        SortPool();
        local maxPlans = tonumber(pool.maxPlans) or 0;
        while #pool.list > maxPlans do
            local removed = table.remove(pool.list);
            local removedKey = pool.seedDiversity
                and removed.state.seedGroup
                and ("SEED:" .. tostring(removed.state.seedGroup)) or nil;
            pool.layoutSignatures[
                removedKey or Solver.LayoutSignatureOf(removed.state)
            ] = nil;
        end
        local bestState = pool.list[1] and pool.list[1].state;
        pool.bestScore = bestState and bestState.score or nil;
        for _, entry in ipairs(pool.list) do
            local score = tonumber(entry.state.score) or 0;
            entry.relativeGap = pool.bestScore and pool.bestScore > 0
                and math.max(0, (pool.bestScore - score) / pool.bestScore)
                or 0;
        end
        return true;
    end

    -- Apply the bounded Government Plaza preference only after the ordinary
    -- solver has finished constructing its small, DMT-validated plan pool.  The
    -- preference therefore cannot redirect beam search or admit a lower-quality
    -- layout that the normal score did not already select as an alternative.
    function Solver.ApplyGovernmentHubPoolPreference(
        result, potentials, options, participantOrder, slotLevels, requests
    )
        local pool = result and result.pool or nil;
        if type(pool) ~= "table" or type(pool.list) ~= "table"
            or #pool.list == 0 then
            return false;
        end
        for _, entry in ipairs(pool.list) do
            local state = entry and entry.state or nil;
            if type(state) == "table" then
                local bonus, potential = Solver.GovernmentHubPreference(
                    state, potentials, options
                );
                state.governmentHubBaseScore = tonumber(state.score) or 0;
                state.governmentHubBonus = bonus;
                state.governmentHubPotential = potential;
                state.score = state.governmentHubBaseScore + bonus;
                state.evaluatorFields = state.evaluatorFields or {};
                state.evaluatorFields.governmentHubBonus = bonus;
                state.evaluatorFields.governmentHubPotential = potential;
            end
        end
        table.sort(pool.list, function(first, second)
            local order = Solver.CompareStates(
                first.state, second.state,
                participantOrder, slotLevels, requests
            );
            if order ~= 0 then return order == -1; end
            local firstLayout = Solver.LayoutSignatureOf(first.state);
            local secondLayout = Solver.LayoutSignatureOf(second.state);
            if firstLayout ~= secondLayout then
                return firstLayout < secondLayout;
            end
            return Solver.SignatureOf(first.state)
                < Solver.SignatureOf(second.state);
        end);
        result.best = pool.list[1].state;
        pool.bestScore = result.best.score;
        for _, entry in ipairs(pool.list) do
            local score = tonumber(entry.state.score) or 0;
            entry.relativeGap = pool.bestScore > 0
                and math.max(0, (pool.bestScore - score) / pool.bestScore)
                or 0;
        end
        result.governmentHubPreferenceApplied = true;
        return true;
    end

    -- ---------------------------------------------------------------------------
    -- Deterministic beam search (plan section 7.2).
    -- ---------------------------------------------------------------------------
    -- config: {
    --   beamWidth = 64,
    --   maxEvaluations = number (hard budget),
    --   participantOrder = { participantID... },
    --   slotLevels = number,
    --   poolOptions = { maxPlans = 3, closeGap = 0.02 },
    --   componentPlans = number (frontier size per component),
    --   maxCombine = number (component combination budget),
    -- }
    -- evaluator: function(state, requests) -> { legal = bool, score = number,
    --   redundantItemCount = number, coverageGap = number,
    --   strategicDeveloped = number }.  DMT final legality is asserted inside
    -- this callback by the adapter; the solver only consumes its verdict.
    -- Returns { status, best, pool, evaluations, components }.
    function Solver.Solve(requests, candidatesFor, config, evaluator)
        if type(evaluator) ~= "function" then
            return { status = "NO_EVALUATOR" };
        end
        config = config or {};
        local beamWidth = tonumber(config.beamWidth)
            or Solver.DEFAULT_BEAM_WIDTH;
        local maxEvaluations = tonumber(config.maxEvaluations) or 0;
        local run = {
            evaluations = 0,
            cache = config.evaluationCache or {},
            reasonCounts = {},
            rejectionExamples = {},
            bestPartial = nil,
        };
        local requestsForPartial = requests or {};
        -- Candidate order is request-local and immutable during one solve.  A
        -- beam may visit the same request from dozens of states, so sort once and
        -- reuse the ordered array instead of allocating/sorting on every branch.
        local sortedCandidatesFor = {};
        local function SortedCandidates(requestID)
            local cached = sortedCandidatesFor[requestID];
            if cached == nil then
                cached = Solver.SortCandidates(
                    candidatesFor and candidatesFor[requestID] or {}
                );
                sortedCandidatesFor[requestID] = cached;
            end
            return cached;
        end
        local function CountFulfilledRequired(state)
            local count = 0;
            for _, request in ipairs(requestsForPartial) do
                if not request.optional
                    and (state.fulfilledRequestIDs[request.requestID] or 0)
                        >= (tonumber(request.cardinalityMin) or 0) then
                    count = count + 1;
                end
            end
            return count;
        end
        local function PartialBetter(candidate, current)
            if current == nil then
                return true;
            end
            local candidateFulfilled = CountFulfilledRequired(candidate);
            local currentFulfilled = CountFulfilledRequired(current);
            if candidateFulfilled ~= currentFulfilled then
                return candidateFulfilled > currentFulfilled;
            end
            local candidateRank = Solver.BuildRank(
                candidate, config.participantOrder,
                config.slotLevels, requestsForPartial
            );
            local currentRank = Solver.BuildRank(
                current, config.participantOrder,
                config.slotLevels, requestsForPartial
            );
            local order = CompareArrays(candidateRank, currentRank);
            if order ~= 0 then
                return order == -1;
            end
            return (candidate.score or 0) > (current.score or 0);
        end
        local function MaybeRememberPartial(state)
            if state.legal and PartialBetter(state, run.bestPartial) then
                run.bestPartial = Solver.CopyState(state);
            end
        end
        local function PartialFields()
            return {
                partialBest = run.bestPartial,
                partial = run.bestPartial ~= nil,
            };
        end
        local function WithPartial(resultFields)
            local partialFields = PartialFields();
            for key, value in pairs(partialFields) do
                resultFields[key] = value;
            end
            return resultFields;
        end
        local function Evaluate(state, requestsForState)
            local signature = Solver.SignatureOf(state);
            local cached = run.cache[signature];
            if cached then
                -- Cache hits must still restore the verdict onto the (possibly
                -- rebuilt) state object: merged states reuse cached evaluations.
                state.legal = cached.legal == true;
                state.score = tonumber(cached.score) or 0;
                state.evaluatorFields = {
                    redundantItemCount = tonumber(
                        cached.redundantItemCount
                    ) or 0,
                    coverageGap = tonumber(cached.coverageGap) or 0,
                    strategicDeveloped = tonumber(
                        cached.strategicDeveloped
                    ) or 0,
                    governmentHubBonus = tonumber(
                        cached.governmentHubBonus
                    ) or 0,
                    governmentHubPotential = tonumber(
                        cached.governmentHubPotential
                    ) or 0,
                };
                MaybeRememberPartial(state);
                return cached;
            end
            if maxEvaluations > 0 and run.evaluations >= maxEvaluations then
                return nil;
            end
            run.evaluations = run.evaluations + 1;
            local progressInterval = math.max(
                1, tonumber(config.progressInterval) or 64
            );
            if type(config.onProgress) == "function"
                and run.evaluations % progressInterval == 0 then
                config.onProgress(run.evaluations);
            end
            local verdict = evaluator(state, requestsForState);
            if type(verdict) ~= "table" then
                verdict = {};
            end
            state.legal = verdict.legal == true;
            state.score = tonumber(verdict.score) or 0;
            state.evaluatorFields = {
                redundantItemCount = tonumber(verdict.redundantItemCount) or 0,
                coverageGap = tonumber(verdict.coverageGap) or 0,
                strategicDeveloped = tonumber(verdict.strategicDeveloped) or 0,
                governmentHubBonus = tonumber(
                    verdict.governmentHubBonus
                ) or 0,
                governmentHubPotential = tonumber(
                    verdict.governmentHubPotential
                ) or 0,
            };
            run.cache[signature] = verdict;
            MaybeRememberPartial(state);
            return verdict;
        end

        local requestsForGraph = requests or {};
        local requestsModule = AMT_MultiCity.Requests;
        local components = {};
        local seeded = (type(config.seedState) == "table")
            or (type(config.seedStates) == "table"
                and #config.seedStates > 0);
        if seeded then
            -- A seeded run (plan 8.3 stage two) always solves as one component:
            -- every frontier state already carries the seed layout, so merging
            -- component states would double it.  Multiple seeds share one
            -- component: suboptimal stage-one layouts advance inside the SAME
            -- beam instead of re-running the whole stage-two search per seed.
            local all = {};
            for _, request in ipairs(requestsForGraph) do
                all[request.requestID] = true;
            end
            components = { all };
        elseif requestsModule and requestsModule.BuildInteractionGraph then
            components = requestsModule.BuildInteractionGraph(
                requestsForGraph, candidatesFor
            ).components;
        else
            local all = {};
            for _, request in ipairs(requestsForGraph) do
                all[request.requestID] = true;
            end
            components = { all };
        end

        local function SolveComponent(component)
            local componentRequests = {};
            for _, request in ipairs(requestsForGraph) do
                if component[request.requestID] then
                    table.insert(componentRequests, request);
                end
            end
            local participantSlots = {};
            for _, request in ipairs(componentRequests) do
                for _, participantID in ipairs(
                    request.eligibleParticipantIDs or {}
                ) do
                    if request.slotCost and tonumber(request.slotCost) > 0
                        and request.slotLimitByParticipant then
                        participantSlots[participantID] =
                            tonumber(request.slotLimitByParticipant[
                                participantID
                            ]) or 0;
                    end
                end
            end
            -- Bundle support requests are embedded in candidates and never
            -- appear in the request list; their slot limits still bind the
            -- city's real slot budget (plan section 8.2).
            for _, request in ipairs(componentRequests) do
                for _, candidate in ipairs(
                    candidatesFor[request.requestID] or {}
                ) do
                    for _, supportEntry in ipairs(
                        candidate.supportCandidates or {}
                    ) do
                        local supportRequest = supportEntry.request;
                        if supportRequest
                            and supportRequest.slotLimitByParticipant then
                            for participantID, limit in pairs(
                                supportRequest.slotLimitByParticipant
                            ) do
                                if (participantSlots[participantID] or 0)
                                    < (tonumber(limit) or 0) then
                                    participantSlots[participantID] =
                                        tonumber(limit) or 0;
                                end
                            end
                        end
                    end
                end
            end
            local seedList = nil;
            if type(config.seedStates) == "table"
                and #config.seedStates > 0 then
                seedList = config.seedStates;
            elseif type(config.seedState) == "table" then
                seedList = { config.seedState };
            end
            local initialStates = {};
            if seedList then
                for _, seed in ipairs(seedList) do
                    local seededState = Solver.CopyState(seed);
                    if next(participantSlots) ~= nil then
                        seededState.participantSlots = Copy(participantSlots);
                        -- CopyState also carries the seed's memoized signatures;
                        -- participantSlots changed above, so both must be
                        -- cleared before this seeded state is evaluated or
                        -- expanded.
                        seededState.cachedSignature = nil;
                        seededState.cachedLayoutSignature = nil;
                    end
                    -- Every descendant of this seed carries the same stage-one
                    -- skeleton identity; the seeded pool uses it for diversity.
                    seededState.seedGroup = Solver.LayoutSignatureOf(seed);
                    table.insert(initialStates, seededState);
                end
            else
                table.insert(initialStates, Solver.NewSearchState(
                    participantSlots
                ));
            end
            for _, initial in ipairs(initialStates) do
                if Evaluate(initial, componentRequests) == nil then
                    return nil, "BUDGET_EXCEEDED";
                end
            end
            local beam = initialStates;
            for _, request in ipairs(componentRequests) do
                local nextBeam = {};
                for _, state in ipairs(beam) do
                    local candidates = SortedCandidates(request.requestID);
                    for _, candidate in ipairs(candidates) do
                        local canAdd, reason = Solver.CanAddCandidate(
                            state, candidate, request
                        );
                        if not canAdd then
                            state.lastSkipReason = reason;
                            run.reasonCounts[reason] =
                                (run.reasonCounts[reason] or 0) + 1;
                            if #run.rejectionExamples < 20 then
                                table.insert(run.rejectionExamples, {
                                    reason = reason,
                                    plotKey = candidate.plotKey,
                                    subjectType = candidate.subjectType,
                                    subjectKey = candidate.subjectKey,
                                    requestID = request.requestID,
                                    planningCityID = candidate.planningCityID,
                                });
                            end
                        else
                            local nextState = Solver.CopyState(state);
                            Solver.ApplyCandidate(nextState, candidate, request);
                            local verdict = Evaluate(
                                nextState, componentRequests
                            );
                            if verdict == nil then
                                return nil, "BUDGET_EXCEEDED";
                            end
                            if nextState.legal then
                                table.insert(nextBeam, nextState);
                            end
                        end
                    end
                    -- Optional requests may be left unsatisfied, and requests
                    -- already satisfied through a wonder support bundle must
                    -- not empty the beam: carry the parent state forward
                    -- (plan 5.3 optional semantics + 8.2 explicit support).
                    if (tonumber(request.cardinalityMin) or 0) == 0
                        or (state.fulfilledRequestIDs[request.requestID] or 0)
                            >= (tonumber(request.cardinalityMax) or 0) then
                        table.insert(nextBeam, state);
                    end
                end
                if #nextBeam == 0 then
                    break;
                end
                -- Deterministic beam truncation: best first, signature
                -- tie-break, no duplicates.  A seeded stage-two run gives every
                -- stage-one skeleton its own width slice so the strongest seed
                -- cannot crowd the alternatives out of the beam early.
                Solver.SortStates(
                    nextBeam, config.participantOrder,
                    config.slotLevels, componentRequests, nil
                );
                local seedQuota = nil;
                if type(config.seedStates) == "table"
                    and #config.seedStates > 0 then
                    seedQuota = math.max(
                        1, math.floor(beamWidth / #config.seedStates)
                    );
                end
                local deduped = {};
                local seen = {};
                local groupCounts = {};
                for _, state in ipairs(nextBeam) do
                    local signature = Solver.SignatureOf(state);
                    if not seen[signature] and #deduped < beamWidth then
                        local group = seedQuota
                            and (state.seedGroup or "__SEED_NONE__") or nil;
                        local groupCount = group
                            and (groupCounts[group] or 0) or 0;
                        if not seedQuota or groupCount < seedQuota then
                            seen[signature] = true;
                            if group then
                                groupCounts[group] = groupCount + 1;
                            end
                            table.insert(deduped, state);
                        end
                    end
                end
                beam = deduped;
            end
            local frontier = {};
            for _, state in ipairs(beam) do
                if state.legal and Solver.IsComplete(state, componentRequests) then
                    table.insert(frontier, state);
                end
            end
            Solver.SortStates(
                frontier, config.participantOrder,
                config.slotLevels, componentRequests,
                function(first, second, layouts)
                    if layouts[first] ~= layouts[second] then
                        return layouts[first] < layouts[second];
                    end
                    return nil; -- Equal layouts fall through to state signatures.
                end
            );
            local limited = {};
            local seenLayouts = {};
            local limit = tonumber(config.componentPlans) or 8;
            local frontierQuota = nil;
            if type(config.seedStates) == "table"
                and #config.seedStates > 0 then
                frontierQuota = math.max(
                    1, math.floor(limit / #config.seedStates)
                );
            end
            local frontierGroups = {};
            for _, state in ipairs(frontier) do
                local layout = Solver.LayoutSignatureOf(state);
                if not seenLayouts[layout] and #limited < limit then
                    local group = frontierQuota
                        and (state.seedGroup or "__SEED_NONE__") or nil;
                    local groupCount = group
                        and (frontierGroups[group] or 0) or 0;
                    if not frontierQuota or groupCount < frontierQuota then
                        seenLayouts[layout] = true;
                        if group then
                            frontierGroups[group] = groupCount + 1;
                        end
                        table.insert(limited, state);
                    end
                end
            end
            return limited;
        end

        local frontiers = {};
        for _, component in ipairs(components) do
            local frontier, failure = SolveComponent(component);
            if failure then
                return WithPartial({
                    status = failure,
                    best = nil,
                    pool = Solver.NewPlanPool(config.poolOptions),
                    evaluations = run.evaluations,
                    components = #components,
                });
            end
            table.insert(frontiers, frontier);
        end

        -- Combine component frontiers (plan section 7.2 step 5): bounded,
        -- deterministic combination of the per-component Pareto frontiers into
        -- joint states, re-evaluated against the full request set.
        local jointBeam = {};
        local combineBudget = tonumber(config.maxCombine) or 512;
        local frontierSizes = {};
        for _, frontier in ipairs(frontiers) do
            table.insert(frontierSizes, #frontier);
        end
        local baseState = Solver.NewSearchState(
            Solver.CollectParticipantSlots(requestsForGraph, candidatesFor)
        );
        local combinations = { { state = baseState } };
        for _, frontier in ipairs(frontiers) do
            local nextCombinations = {};
            for _, combo in ipairs(combinations) do
                for _, componentState in ipairs(frontier) do
                    if #nextCombinations < combineBudget then
                        local merged = Solver.MergeStates(
                            combo.state, componentState
                        );
                        if merged then
                            table.insert(nextCombinations, {
                                state = merged,
                            });
                        end
                    end
                end
            end
            combinations = nextCombinations;
        end
        for _, combo in ipairs(combinations) do
            local verdict = Evaluate(combo.state, requestsForGraph);
            if verdict == nil then
                return WithPartial({
                    status = "BUDGET_EXCEEDED",
                    best = nil,
                    pool = Solver.NewPlanPool(config.poolOptions),
                    evaluations = run.evaluations,
                    components = #components,
                });
            end
            if combo.state.legal
                and Solver.IsComplete(combo.state, requestsForGraph) then
                table.insert(jointBeam, combo.state);
            end
        end
        Solver.SortStates(
            jointBeam, config.participantOrder,
            config.slotLevels, requestsForGraph,
            function(first, second, layouts)
                if layouts[first] ~= layouts[second] then
                    return layouts[first] < layouts[second];
                end
                return nil; -- Equal layouts fall through to state signatures.
            end
        );
        local deduped = {};
        local seen = {};
        for _, state in ipairs(jointBeam) do
            local signature = Solver.SignatureOf(state);
            if not seen[signature] and #deduped < beamWidth then
                seen[signature] = true;
                table.insert(deduped, state);
            end
        end

        local pool = Solver.NewPlanPool(config.poolOptions);
        local best = nil;
        for _, state in ipairs(deduped) do
            if best == nil then
                best = state;
            end
            Solver.PlanPoolAdd(pool, state, config.participantOrder,
                config.slotLevels, requestsForGraph);
        end
        -- Diagnostics: required requests that could not be satisfied and the
        -- most frequent rejection reasons (shown on the no-plan page).  When no
        -- complete plan exists, report against the best partial state instead.
        local diagnosticReference = best or run.bestPartial;
        local unfulfilledRequired = {};
        for _, request in ipairs(requestsForGraph) do
            if not request.optional
                and ((diagnosticReference
                    and diagnosticReference.fulfilledRequestIDs[request.requestID])
                    or 0) < (tonumber(request.cardinalityMin) or 1) then
                table.insert(unfulfilledRequired, {
                    requestID = request.requestID,
                    scope = request.scope, -- nil remains valid for legacy replays.
                    subjectType = request.subjectType,
                    subjectOptions = request.subjectOptions,
                    eligibleCityIDs = request.eligibleCityIDs,
                    eligibleParticipantIDs = request.eligibleParticipantIDs,
                });
            end
        end
        local reasonList = {};
        for reason, count in pairs(run.reasonCounts) do
            table.insert(reasonList, { reason = reason, count = count });
        end
        table.sort(reasonList, function(a, b)
            if a.count ~= b.count then return a.count > b.count; end
            return a.reason < b.reason;
        end);
        return WithPartial({
            status = best ~= nil and "OK" or "NO_PLAN",
            best = best,
            pool = pool,
            evaluations = run.evaluations,
            components = #components,
            diagnostics = {
                reasonCounts = reasonList,
                unfulfilledRequired = unfulfilledRequired,
                rejectionExamples = run.rejectionExamples,
            },
        });
    end

    -- ---------------------------------------------------------------------------
    -- Two-stage solve (plan section 8.3): districts/coverage/wonders first,
    -- then per-city improvements seeded on each stage-one plan.  Both stages
    -- share one hard evaluation budget; exceeding it is an explicit failure.
    -- ---------------------------------------------------------------------------
    function Solver.TwoStageSolve(stage1Requests, stage2Requests, candidatesFor,
                                  config, evaluator)
        if type(evaluator) ~= "function" then
            return { status = "NO_EVALUATOR" };
        end
        local sharedEvaluationCache = config.evaluationCache or {};
        local stage1Config = Copy(config) or {};
        stage1Config.seedState = nil;
        stage1Config.evaluationCache = sharedEvaluationCache;
        -- UI stages: 1 prepares inputs, 2 solves districts, 3 improvements,
        -- 4 verifies/previews.  Notify actual boundaries, not evaluation guesses.
        -- Call directly: a worker callback may cooperatively yield here.
        if type(config.onStage) == "function" then config.onStage(2); end
        local stage1 = Solver.Solve(
            stage1Requests, candidatesFor, stage1Config, evaluator
        );
        if stage1.status ~= "OK" or not stage1.best then
            return stage1;
        end
        local seeds = {};
        for _, entry in ipairs(stage1.pool and stage1.pool.list or {}) do
            table.insert(seeds, entry.state);
        end
        if #seeds == 0 then
            table.insert(seeds, stage1.best);
        end

        local stage2Config = Copy(config) or {};
        stage2Config.evaluationCache = sharedEvaluationCache;
        -- Both stages share ONE hard evaluation budget.  r29 pool design: do not
        -- re-run stage two once per seed.  All suboptimal stage-one layouts are
        -- seeded into the SAME stage-two beam, so one pass improves them all and
        -- the final pool selects layout-distinct alternatives from that pass.
        stage2Config.maxEvaluations = math.max(
            1,
            (tonumber(config.maxEvaluations) or 0)
                - (tonumber(stage1.evaluations) or 0)
        );
        stage2Config.seedStates = seeds;
        stage2Config.seedState = nil;
        -- All seeds share one stage-two beam, and each seed receives its own
        -- width slice inside that shared beam (r29 pool design: alternatives
        -- advance together instead of re-running stage two per seed).
        -- Optional improvement placement tolerates a thinner beam than the
        -- district skeleton search, which keeps the multi-plan pass fast.
        local stage1Beam = tonumber(config.beamWidth) or Solver.DEFAULT_BEAM_WIDTH;
        stage2Config.beamWidth = tonumber(config.stage2BeamWidth) or math.max(
            16, math.min(stage1Beam, math.floor(stage1Beam * 0.65))
        );
        local stage2PoolOptions = Copy(config.poolOptions) or {};
        stage2PoolOptions.seedDiversity = true;
        stage2Config.poolOptions = stage2PoolOptions;
        if type(config.onStage) == "function" then config.onStage(3); end
        local stage2 = Solver.Solve(
            stage2Requests, candidatesFor, stage2Config, evaluator
        );
        local totalEvaluations = (stage1.evaluations or 0)
            + (stage2.evaluations or 0);

        if stage2.status == "BUDGET_EXCEEDED" then
            local partialBest = stage1.best or stage1.partialBest;
            return {
                status = "BUDGET_EXCEEDED",
                best = nil,
                pool = Solver.NewPlanPool(config.poolOptions),
                evaluations = totalEvaluations,
                components = stage1.components,
                partialBest = partialBest,
                partial = partialBest ~= nil,
            };
        end
        if stage2.status == "OK" and stage2.best then
            return {
                status = "OK",
                best = stage2.best,
                pool = stage2.pool,
                evaluations = totalEvaluations,
                components = stage1.components,
                partialBest = stage2.partialBest or stage1.best,
                partial = false,
            };
        end
        local partialBest = stage1.best or stage1.partialBest;
        return {
            status = "NO_PLAN",
            best = nil,
            pool = Solver.NewPlanPool(config.poolOptions),
            evaluations = totalEvaluations,
            components = stage1.components,
            partialBest = partialBest,
            partial = partialBest ~= nil,
        };
    end

    -- Participant slot map derived from requests carrying slotLimitByParticipant
    -- plus bundle support requests embedded in candidates.
    function Solver.CollectParticipantSlots(requests, candidatesFor)
        local slots = {};
        for _, request in ipairs(requests or {}) do
            if request.slotCost and tonumber(request.slotCost) > 0
                and request.slotLimitByParticipant then
                for participantID, limit in pairs(
                    request.slotLimitByParticipant
                ) do
                    if (slots[participantID] or 0)
                        < (tonumber(limit) or 0) then
                        slots[participantID] = tonumber(limit) or 0;
                    end
                end
            end
        end
        for _, request in ipairs(requests or {}) do
            for _, candidate in ipairs(candidatesFor
                and candidatesFor[request.requestID] or {}) do
                for _, supportEntry in ipairs(
                    candidate.supportCandidates or {}
                ) do
                    local supportRequest = supportEntry.request;
                    if supportRequest
                        and supportRequest.slotLimitByParticipant then
                        for participantID, limit in pairs(
                            supportRequest.slotLimitByParticipant
                        ) do
                            if (slots[participantID] or 0)
                                < (tonumber(limit) or 0) then
                                slots[participantID] = tonumber(limit) or 0;
                            end
                        end
                    end
                end
            end
        end
        return slots;
    end

    -- Merges two states that share no occupied plots; component frontiers are
    -- disjoint by construction, so conflicts indicate an adapter bug and abort.
    function Solver.MergeStates(first, second)
        for plotKey in pairs(second.occupiedPlotKeys or {}) do
            if first.occupiedPlotKeys[plotKey] then
                return nil;
            end
        end
        local merged = Solver.CopyState(first);
        merged.items = Copy(first.items);
        for _, item in ipairs(second.items or {}) do
            table.insert(merged.items, Copy(item));
        end
        if merged.seedGroup == nil and second.seedGroup ~= nil then
            merged.seedGroup = second.seedGroup;
        end
        for plotKey in pairs(second.occupiedPlotKeys or {}) do
            merged.occupiedPlotKeys[plotKey] = true;
        end
        for requestID, count in pairs(second.fulfilledRequestIDs or {}) do
            merged.fulfilledRequestIDs[requestID] =
                (merged.fulfilledRequestIDs[requestID] or 0) + count;
        end
        Solver.MergeCounterMap(merged.specialtyUsedByParticipant,
            second.specialtyUsedByParticipant);
        Solver.MergeNestedCounterMap(merged.districtStrategyCountsByParticipant,
            second.districtStrategyCountsByParticipant);
        Solver.MergeNestedCounterMap(merged.coverageByServiceAndParticipant,
            second.coverageByServiceAndParticipant);
        Solver.MergeNestedCounterMap(
            merged.strategicResourceCountsByParticipant,
            second.strategicResourceCountsByParticipant);
        -- Slot fulfillment stores candidate identities, not counts: union the
        -- maps and abort on a conflicting identity at the same slot.
        for participantID, fulfillment in pairs(
            second.perParticipantSlotFulfillment or {}
        ) do
            local target =
                merged.perParticipantSlotFulfillment[participantID] or {};
            for slotIndex, value in pairs(fulfillment or {}) do
                if target[slotIndex] ~= nil
                    and target[slotIndex] ~= value then
                    return nil;
                end
                if target[slotIndex] == nil then
                    target[slotIndex] = value;
                end
            end
            merged.perParticipantSlotFulfillment[participantID] = target;
        end
        Solver.MergeCounterMap(merged.playerLimitedCounts,
            second.playerLimitedCounts);
        Solver.MergeCounterMap(merged.globalLimitedCounts,
            second.globalLimitedCounts);
        Solver.MergeCounterMap(merged.improvementUsedByParticipant,
            second.improvementUsedByParticipant);
        -- Slot LIMITS are maxima, not counters: merge the higher bound per
        -- participant so a seeded component's limits survive a merge with an
        -- empty base state (one-pass stage two relies on this).
        for participantID, limit in pairs(second.participantSlots or {}) do
            merged.participantSlots[participantID] = math.max(
                tonumber(merged.participantSlots[participantID]) or 0,
                tonumber(limit) or 0
            );
        end
        for participantID, exclusions in pairs(
            second.exclusionByParticipant or {}
        ) do
            local target = merged.exclusionByParticipant[participantID] or {};
            for group, subjectKey in pairs(exclusions) do
                if target[group] ~= nil and target[group] ~= subjectKey then
                    return nil;
                end
                if target[group] == nil then target[group] = subjectKey; end
            end
            merged.exclusionByParticipant[participantID] = target;
        end
        merged.legal = false;
        merged.score = 0;
        merged.evaluatorFields = {};
        merged.cachedSignature = nil;
        merged.cachedLayoutSignature = nil;
        return merged;
    end

    function Solver.MergeCounterMap(target, source)
        for key, count in pairs(source or {}) do
            target[key] = (target[key] or 0) + (tonumber(count) or 0);
        end
        return target;
    end

    function Solver.MergeNestedCounterMap(target, source)
        for outerKey, inner in pairs(source or {}) do
            local innerTarget = target[outerKey] or {};
            for innerKey, count in pairs(inner or {}) do
                innerTarget[innerKey] =
                    (innerTarget[innerKey] or 0) + (tonumber(count) or 0);
            end
            target[outerKey] = innerTarget;
        end
        return target;
    end

    -- ---------------------------------------------------------------------------
    -- Coverage helpers (plan section 8.1; used from M4 on).
    -- ---------------------------------------------------------------------------

    -- Diminishing marginal benefit of the (existingCount+1)-th coverage of one
    -- participant city by one service.  Pure and testable; the game-aware
    -- adapter applies it inside the scoring path.
    function Solver.CoverageMarginalBenefit(existingCount)
        local count = tonumber(existingCount) or 0;
        if count <= 0 then return 1.4; end
        if count == 1 then return 0.35; end
        if count == 2 then return 0.05; end
        return 0;
    end

    -- Coverage gap across participant cities for the requested services
    -- (plan section 6 tier 7): a participant city counts as uncovered when
    -- neither the fixed baseline nor the current state covers it.
    --   state             search state (coverageByServiceAndParticipant)
    --   coverageServices  map service -> true
    --   participants      map participantID -> { cityID = n }
    --   baselineCovered   map service -> map cityID -> true
    function Solver.CoverageGap(state, coverageServices, participants,
                                baselineCovered)
        local gap = 0;
        for service in pairs(coverageServices or {}) do
            local baseline = (baselineCovered or {})[service] or {};
            for participantID in pairs(participants or {}) do
                local cityID = participants[participantID].cityID;
                if not baseline[cityID] then
                    local byParticipant =
                        (state.coverageByServiceAndParticipant or {})[service]
                        or {};
                    if (byParticipant[participantID] or 0) == 0 then
                        gap = gap + 1;
                    end
                end
            end
        end
        return gap;
    end



end;
AMT_BundledModules["amt_mc_unique_district"] = function()


    -- M6U player-unique district module (pure logic, no game API).
    --
    -- Implements the shared OFF / AUTO / LOCKED_CITY(cityID) intent model of
    -- docs/UNIQUE_DISTRICT_UI_PLAN.md section 5 together with the pure helpers
    -- needed by the editor glue:
    --   * shared draft/saved separation with revisions
    --   * atomic plan-list transitions (append / remove) used by the glue to
    --     synchronize a city's selectedSubjects and specialtyOrder in the same
    --     draft conversion
    --   * deterministic conditional-slot assignment for AUTO requests: each
    --     eligible city keeps its real slot budget, the winning city consumes
    --     exactly one real slot, and no candidate city is pre-reserved
    --   * effective-source classification (BUILT/FOUNDED/MANUAL_PIN/AUTO_PIN)
    --
    -- The module never touches map pins, GameConfiguration, or the single-city
    -- planner state.  It must stay free of game API so it can run under LuaJIT
    -- in the offline test suite.

    AMT_MultiCity = AMT_MultiCity or {};
    AMT_MultiCity.UniqueDistrict = AMT_MultiCity.UniqueDistrict or {};

    local UD = AMT_MultiCity.UniqueDistrict;

    UD.SCHEMA_VERSION = 1;

    UD.MODE_OFF = "OFF";
    UD.MODE_AUTO = "AUTO";
    UD.MODE_LOCKED_CITY = "LOCKED_CITY";
    UD.DEFAULT_MODE = UD.MODE_OFF;

    -- First-version support is explicitly the two player-unique base-game /
    -- Gathering Storm districts.  New subjects may only be added when the
    -- runtime rules conservatively prove "max one per player" semantics.
    UD.SUBJECT_KEYS = {
        "DISTRICT_GOVERNMENT",
        "DISTRICT_DIPLOMATIC_QUARTER",
    };

    UD.EFFECTIVE_BUILT = "BUILT";
    UD.EFFECTIVE_FOUNDED = "FOUNDED";
    UD.EFFECTIVE_MANUAL_PIN = "MANUAL_PIN";
    UD.EFFECTIVE_MANUAL_CONFLICT = "MANUAL_CONFLICT";
    UD.EFFECTIVE_MANUAL_INVALID = "MANUAL_INVALID";
    UD.EFFECTIVE_AUTO_PIN = "AUTO_PIN";
    UD.EFFECTIVE_INTENT = "SAVED_INTENT";

    -- ---------------------------------------------------------------------------
    -- Small safe-copy helpers.  When the UI state module is already loaded its
    -- cycle-safe Copy/Equal are reused; otherwise a local fallback keeps this
    -- module self-contained for isolated unit tests.
    -- ---------------------------------------------------------------------------
    local function Copy(value, seen)
        local uiState = AMT_MultiCity.UIState;
        if uiState and type(uiState.Copy) == "function" then
            return uiState.Copy(value);
        end
        if type(value) ~= "table" then return value; end
        seen = seen or {};
        if seen[value] then return seen[value]; end
        local result = {};
        seen[value] = result;
        for key, item in pairs(value) do
            result[Copy(key, seen)] = Copy(item, seen);
        end
        return result;
    end

    local function Equal(first, second, seen)
        local uiState = AMT_MultiCity.UIState;
        if uiState and type(uiState.Equal) == "function" then
            return uiState.Equal(first, second);
        end
        if type(first) ~= type(second) then return false; end
        if type(first) ~= "table" then return first == second; end
        seen = seen or {};
        if seen[first] == second then return true; end
        seen[first] = second;
        for key, value in pairs(first) do
            if not Equal(value, second[key], seen) then return false; end
        end
        for key in pairs(second) do
            if first[key] == nil then return false; end
        end
        return true;
    end

    UD.Copy = Copy;
    UD.Equal = Equal;

    -- ---------------------------------------------------------------------------
    -- Shared intent model (UNIQUE_DISTRICT_UI_PLAN section 5).
    -- ---------------------------------------------------------------------------

    function UD.NewDraft(subjectKey)
        return { mode = UD.DEFAULT_MODE, lockedCityID = nil };
    end

    -- Validates and normalizes a draft/saved entry.  When validCityIDs is
    -- supplied, LOCKED_CITY must reference one of those stable city IDs (never
    -- a name or a navigation index).
    function UD.NormalizeEntry(subjectKey, entry, validCityIDs)
        if type(entry) ~= "table" then
            return nil, "unique district entry must be a table";
        end
        local mode = entry.mode or UD.DEFAULT_MODE;
        if mode ~= UD.MODE_OFF
            and mode ~= UD.MODE_AUTO
            and mode ~= UD.MODE_LOCKED_CITY then
            return nil, "unknown unique district mode: " .. tostring(mode);
        end
        local lockedCityID = nil;
        if mode == UD.MODE_LOCKED_CITY then
            lockedCityID = tonumber(entry.lockedCityID);
            if lockedCityID == nil then
                return nil, "LOCKED_CITY requires lockedCityID";
            end
            if validCityIDs then
                local found = false;
                for _, cityID in ipairs(validCityIDs) do
                    if cityID == lockedCityID then found = true; break; end
                end
                if not found then
                    return nil, "locked city is not a saved participant";
                end
            end
        end
        return {
            mode = mode,
            lockedCityID = lockedCityID,
            revision = tonumber(entry.revision) or 0,
        };
    end

    function UD.GetDraft(session, subjectKey)
        local draft = session and session.uniqueDistrictDraft;
        local entry = draft and draft[subjectKey];
        if entry == nil then return UD.NewDraft(subjectKey); end
        return Copy(entry);
    end

    function UD.GetSaved(session, subjectKey)
        local saved = session and session.uniqueDistrictSaved;
        local entry = saved and saved[subjectKey];
        if entry == nil then return UD.NewDraft(subjectKey); end
        return Copy(entry);
    end

    function UD.SetDraft(session, subjectKey, entry, validCityIDs)
        local normalized, reason = UD.NormalizeEntry(
            subjectKey, entry, validCityIDs
        );
        if not normalized then return false, reason; end
        session.uniqueDistrictDraft = session.uniqueDistrictDraft or {};
        session.uniqueDistrictDraft[subjectKey] = normalized;
        return true;
    end

    function UD.IsDirty(session, subjectKey)
        return not Equal(
            UD.GetDraft(session, subjectKey), UD.GetSaved(session, subjectKey)
        );
    end

    function UD.HasDirty(session, subjectKeys)
        local draft = session and session.uniqueDistrictDraft or {};
        local saved = session and session.uniqueDistrictSaved or {};
        if not Equal(draft, saved) then
            return true;
        end
        for _, subjectKey in ipairs(subjectKeys or {}) do
            if UD.IsDirty(session, subjectKey) then return true; end
        end
        return false;
    end

    function UD.DirtySubjectKeys(session, subjectKeys)
        local dirty = {};
        for _, subjectKey in ipairs(subjectKeys or {}) do
            if UD.IsDirty(session, subjectKey) then
                table.insert(dirty, subjectKey);
            end
        end
        return dirty;
    end

    -- Commits one shared draft to the saved side and bumps its revision.
    function UD.SaveDraft(session, subjectKey)
        session.uniqueDistrictSaved = session.uniqueDistrictSaved or {};
        local draft = UD.GetDraft(session, subjectKey);
        local previous = session.uniqueDistrictSaved[subjectKey];
        local revision = (previous and tonumber(previous.revision) or 0) + 1;
        local saved = {
            mode = draft.mode,
            lockedCityID = draft.lockedCityID,
            revision = revision,
        };
        session.uniqueDistrictSaved[subjectKey] = saved;
        session.uniqueDistrictDraft = session.uniqueDistrictDraft or {};
        session.uniqueDistrictDraft[subjectKey] = Copy(saved);
        return true, revision;
    end

    function UD.SaveAllDirty(session, subjectKeys)
        local savedCount = 0;
        for _, subjectKey in ipairs(subjectKeys or {}) do
            if UD.IsDirty(session, subjectKey) then
                local ok = UD.SaveDraft(session, subjectKey);
                if ok then savedCount = savedCount + 1; end
            end
        end
        return savedCount;
    end

    function UD.DiscardDrafts(session)
        session.uniqueDistrictDraft = Copy(session.uniqueDistrictSaved or {});
        return true;
    end

    -- Validates saved LOCKED_CITY entries against the actually included
    -- participants.  Returns ok, plus a sorted array of offending subject keys.
    function UD.ValidateSavedLocks(session, subjectKeys, includedCityIDs)
        local missing = {};
        local citySet = {};
        for _, cityID in ipairs(includedCityIDs or {}) do
            citySet[cityID] = true;
        end
        for _, subjectKey in ipairs(subjectKeys or {}) do
            local entry = UD.GetSaved(session, subjectKey);
            local normalized, reason = UD.NormalizeEntry(
                subjectKey, entry, includedCityIDs
            );
            if not normalized then
                if reason == "locked city is not a saved participant"
                    or (entry and entry.mode == UD.MODE_LOCKED_CITY) then
                    table.insert(missing, subjectKey);
                end
            elseif entry.mode == UD.MODE_LOCKED_CITY
                and not citySet[entry.lockedCityID] then
                table.insert(missing, subjectKey);
            end
        end
        table.sort(missing);
        return #missing == 0, missing;
    end

    -- ---------------------------------------------------------------------------
    -- Effective source (UNIQUE_DISTRICT_UI_PLAN section 4): manual pins are a
    -- derived runtime state, never a fourth player choice.
    -- ---------------------------------------------------------------------------
    function UD.EffectiveSource(env)
        env = env or {};
        if env.builtCityID ~= nil then return UD.EFFECTIVE_BUILT; end
        if env.foundedCityID ~= nil then return UD.EFFECTIVE_FOUNDED; end
        local manualCount = tonumber(env.manualCount) or 0;
        if manualCount > 1 then return UD.EFFECTIVE_MANUAL_CONFLICT; end
        if manualCount == 1 then
            if env.manualLegal == false then
                return UD.EFFECTIVE_MANUAL_INVALID;
            end
            return UD.EFFECTIVE_MANUAL_PIN;
        end
        if tonumber(env.autoCount) or 0 > 0 then
            return UD.EFFECTIVE_AUTO_PIN;
        end
        return UD.EFFECTIVE_INTENT;
    end

    -- ---------------------------------------------------------------------------
    -- Plan-list transitions (UNIQUE_DISTRICT_UI_PLAN section 6).  The glue must
    -- apply the returned list changes to BOTH the city's selectedSubjects and
    -- specialtyOrder in one draft conversion; these pure helpers keep the list
    -- math deterministic and testable.
    -- ---------------------------------------------------------------------------

    -- Compacts an ordered list, preserving order and removing nils.
    function UD.CompactList(list)
        local compact = {};
        for _, value in ipairs(list or {}) do
            if value ~= nil then table.insert(compact, value); end
        end
        return compact;
    end

    -- Appends subjectKey at the end when absent; never moves existing entries.
    function UD.AppendSubject(list, subjectKey)
        local compact = UD.CompactList(list);
        for _, value in ipairs(compact) do
            if value == subjectKey then return compact, false; end
        end
        table.insert(compact, subjectKey);
        return compact, true;
    end

    -- Removes every occurrence of subjectKey; other entries keep relative order.
    function UD.RemoveSubject(list, subjectKey)
        local compact = {};
        local changed = false;
        for _, value in ipairs(UD.CompactList(list or {})) do
            if value == subjectKey then
                changed = true;
            else
                table.insert(compact, value);
            end
        end
        return compact, changed;
    end

    -- ---------------------------------------------------------------------------
    -- Deterministic conditional-slot assignment (UNIQUE_DISTRICT_UI_PLAN
    -- section 8): AUTO subjects get the smallest free real slot of each
    -- eligible city; LOCKED subjects already own the index passed in
    -- occupiedIndicesByParticipant.  Two AUTO subjects in the same city always
    -- receive two different slots, so they can never borrow across cities.
    -- ---------------------------------------------------------------------------
    function UD.AssignAutoSlotIndices(
        subjectKeys, orderedParticipantIDs,
        occupiedIndicesByParticipant, slotsByParticipant
    )
        local assignment = {};
        local subjectList = {};
        for _, subjectKey in ipairs(subjectKeys or {}) do
            table.insert(subjectList, subjectKey);
        end
        table.sort(subjectList);

        local occupied = {};
        for _, participantID in ipairs(orderedParticipantIDs or {}) do
            occupied[participantID] = {};
            for index in pairs(
                (occupiedIndicesByParticipant or {})[participantID] or {}
            ) do
                if index ~= nil and tonumber(index) ~= nil then
                    occupied[participantID][tonumber(index)] = true;
                end
            end
        end

        for _, subjectKey in ipairs(subjectList) do
            assignment[subjectKey] = {};
            for _, participantID in ipairs(orderedParticipantIDs or {}) do
                local slots = math.max(
                    1, tonumber(
                        (slotsByParticipant or {})[participantID]
                    ) or 1
                );
                local found = nil;
                for index = 1, slots do
                    if not occupied[participantID][index] then
                        found = index;
                        break;
                    end
                end
                if found == nil then
                    -- Every real index is marked occupied.  Assign pseudo-slots
                    -- above the budget so each AUTO subject keeps a distinct
                    -- slot identity; CanAddSingle still enforces the real slot
                    -- budget, so an overfull city simply has no legal layout.
                    local pseudo = slots + 1;
                    while occupied[participantID][pseudo] do
                        pseudo = pseudo + 1;
                    end
                    found = pseudo;
                end
                assignment[subjectKey][participantID] = found;
                occupied[participantID][found] = true;
            end
        end
        return assignment;
    end

    -- ---------------------------------------------------------------------------
    -- Legacy migration helper: removes supported player-unique subjects from a
    -- per-city saved intent (r21 compiled them as independent per-city CITY
    -- requests) and reports which subjects were found.  The caller decides the
    -- migrated shared mode; this module never invents one silently.
    -- ---------------------------------------------------------------------------
    function UD.FilterLegacyIntent(intent, subjectKeys)
        local copy = Copy(intent or {});
        local found = {};
        local subjectSet = {};
        for _, subjectKey in ipairs(subjectKeys or {}) do
            subjectSet[subjectKey] = true;
        end
        local selected = copy.selectedSubjects
            and copy.selectedSubjects["DISTRICT"] or nil;
        if selected then
            for subjectKey in pairs(selected) do
                if subjectSet[subjectKey] then
                    found[subjectKey] = true;
                    selected[subjectKey] = nil;
                end
            end
            copy.selectedSubjects["DISTRICT"] = selected;
        end
        local order = {};
        for _, subjectKey in ipairs(copy.specialtyOrder or {}) do
            if subjectSet[subjectKey] then
                found[subjectKey] = true;
            else
                table.insert(order, subjectKey);
            end
        end
        copy.specialtyOrder = order;
        return copy, found;
    end

    -- Stable serialization of the shared saved map for snapshot signatures.
    function UD.SnapshotData(saved)
        local contract = AMT_MultiCity.Contract;
        if contract and type(contract.Hash) == "function" then
            local entries = {};
            local keys = contract.SortedKeys(saved or {});
            for _, subjectKey in ipairs(keys) do
                local entry = (saved or {})[subjectKey];
                table.insert(entries, {
                    subjectKey = subjectKey,
                    mode = entry and entry.mode or UD.DEFAULT_MODE,
                    lockedCityID = entry and entry.lockedCityID or nil,
                    revision = entry and tonumber(entry.revision) or 0,
                });
            end
            return contract.Hash(entries);
        end
        return "no-contract";
    end



end;
AMT_BundledModules["amt_mc_transaction"] = function()


    -- Pure M7 transaction model (no game API).  The glue layer captures real
    -- map pins into the abstract pin records defined here, feeds them to
    -- BuildDiff, and then executes the resulting diff through the existing
    -- pin helpers with the rollback records kept in memory until commit.
    AMT_MultiCity = AMT_MultiCity or {};
    AMT_MultiCity.Transaction = AMT_MultiCity.Transaction or {};

    local Transaction = AMT_MultiCity.Transaction;

    Transaction.SCHEMA_VERSION = 1;
    Transaction.KIND = "MULTICITY";

    local function Copy(value, seen)
        if type(value) ~= "table" then return value; end
        seen = seen or {};
        if seen[value] then return seen[value]; end
        local result = {};
        seen[value] = result;
        for key, item in pairs(value) do
            result[Copy(key, seen)] = Copy(item, seen);
        end
        return result;
    end
    Transaction.Copy = Copy;

    local function Key(x, y)
        return tostring(x) .. "_" .. tostring(y);
    end
    Transaction.Key = Key;

    function Transaction.NewDiff()
        return {
            schemaVersion = Transaction.SCHEMA_VERSION,
            snapshotSignature = "",
            participantIDs = {},
            realCityIDs = {},
            removeByParticipant = {},
            addByParticipant = {},
            manualRemovalConfirmation = {},
            staleResourcePins = {},
            blockedPlots = {},
            rollbackRecords = {
                removed = {},
                added = {},
            },
        };
    end

    -- existingPins: array of captured pin records.  Each record must carry
    -- x, y, participantID and isAuto; subjectType/subjectKey/iconName/name/cityID
    -- are copied into rollback records.
    -- desiredItems: array of selected-plan items with x, y and participantID.
    -- participants: map participantID -> true (participant scope).
    -- clearAutoPins: remove participant auto pins even when no replacement.
    -- clearManualPins: remove participant manual pins (listed in
    --   manualRemovalConfirmation for the confirm page).
    -- staleResourceKeys: map key -> true for stale auto resource pins.
    -- Returns a diff or nil plus reason.
    function Transaction.BuildDiff(params)
        params = params or {};
        local diff = Transaction.NewDiff();
        diff.snapshotSignature = tostring(params.snapshotSignature or "");
        local participants = params.participants or {};
        local clearAutoPins = params.clearAutoPins == true;
        local clearManualPins = params.clearManualPins == true;
        local stale = params.staleResourceKeys or {};

        for participantID in pairs(participants) do
            table.insert(diff.participantIDs, participantID);
            diff.removeByParticipant[participantID] = {};
            diff.addByParticipant[participantID] = {};
        end
        table.sort(diff.participantIDs);

        local participantCity = {};
        for _, item in ipairs(params.participantList or {}) do
            if item and item.participantID then
                participantCity[item.participantID] = tonumber(item.cityID)
                    or nil;
            end
        end
        for _, participantID in ipairs(diff.participantIDs) do
            if participantCity[participantID] ~= nil then
                table.insert(diff.realCityIDs, participantCity[participantID]);
            end
        end

        local removalByKey = {};
        local existingByKey = {};
        for _, pin in ipairs(params.existingPins or {}) do
            local participantID = pin and pin.participantID;
            if participantID and participants[participantID] then
                existingByKey[Key(pin.x, pin.y)] = pin;
            end
        end

        for _, pin in ipairs(params.existingPins or {}) do
            local participantID = pin and pin.participantID;
            if participantID and participants[participantID] then
                local key = Key(pin.x, pin.y);
                local remove = false;
                local staleResource = stale[key] == true and pin.isAuto == true;
                if pin.isAuto then
                    remove = clearAutoPins or staleResource
                        or false;
                elseif clearManualPins then
                    remove = true;
                end
                if remove then
                    local record = Copy(pin);
                    record.id = nil;
                    diff.removeByParticipant[participantID] =
                        diff.removeByParticipant[participantID] or {};
                    table.insert(
                        diff.removeByParticipant[participantID], record
                    );
                    table.insert(diff.rollbackRecords.removed, Copy(record));
                    if pin.isAuto then
                        if staleResource then
                            table.insert(diff.staleResourcePins, record);
                        end
                    else
                        table.insert(
                            diff.manualRemovalConfirmation, Copy(record)
                        );
                    end
                    removalByKey[key] = true;
                end
            end
        end

        local addByKey = {};
        for _, item in ipairs(params.desiredItems or {}) do
            local participantID = item and item.participantID;
            if participantID and participants[participantID] then
                local key = Key(item.x, item.y);
                if addByKey[key] then
                    return nil, "duplicate desired plot: " .. key;
                end
                addByKey[key] = true;
                local existing = existingByKey[key];
                if existing and not removalByKey[key] then
                    if not existing.isAuto then
                        diff.blockedPlots[key] = {
                            x = existing.x,
                            y = existing.y,
                            reason = "MANUAL_PIN",
                        };
                    end
                else
                    local record = {
                        x = item.x,
                        y = item.y,
                        subjectType = item.subjectType,
                        subjectKey = item.subjectKey,
                        iconName = item.iconName,
                        cityID = item.cityID,
                        participantID = participantID,
                        district = item.subjectType == "DISTRICT"
                            and item.subjectKey or nil,
                    };
                    diff.addByParticipant[participantID] =
                        diff.addByParticipant[participantID] or {};
                    table.insert(diff.addByParticipant[participantID], record);
                    table.insert(diff.rollbackRecords.added, Copy(record));
                end
            end
        end

        local function SortRecords(list)
            table.sort(list, function(first, second)
                if first.participantID ~= second.participantID then
                    return first.participantID < second.participantID;
                end
                if first.y ~= second.y then return first.y < second.y; end
                return first.x < second.x;
            end);
        end
        for participantID in pairs(diff.removeByParticipant) do
            SortRecords(diff.removeByParticipant[participantID]);
        end
        for participantID in pairs(diff.addByParticipant) do
            SortRecords(diff.addByParticipant[participantID]);
        end
        table.sort(diff.realCityIDs);
        return diff;
    end

    -- Replaces a pin in a simulated pin map only when the rollback record says
    -- the pin was auto; manual restoration is always allowed because the user
    -- explicitly confirmed it.
    function Transaction.RestoreRecord(pins, record)
        if not pins or not record then return false; end
        pins[Key(record.x, record.y)] = Copy(record);
        return true;
    end

    function Transaction.RemoveRecord(pins, record)
        if not pins or not record then return false; end
        local key = Key(record.x, record.y);
        if pins[key] == nil then return false; end
        pins[key] = nil;
        return true;
    end

    -- Deterministic summary counts for the confirm page.
    function Transaction.Summary(diff)
        local added, removed, manual, blocked = 0, 0, 0, 0;
        for _, records in pairs(diff.addByParticipant or {}) do
            added = added + #records;
        end
        for _, records in pairs(diff.removeByParticipant or {}) do
            removed = removed + #records;
        end
        manual = #(diff.manualRemovalConfirmation or {});
        for _ in pairs(diff.blockedPlots or {}) do
            blocked = blocked + 1;
        end
        return {
            added = added,
            removed = removed,
            manualRemovals = manual,
            blocked = blocked,
            staleResources = #(diff.staleResourcePins or {}),
        };
    end

    -- Runtime safety orchestration. All engine/storage access stays in the adapter.
    -- The write-ahead journal is separate from the user's previous undo record.
    function Transaction.Equal(first, second)
        if type(first) ~= type(second) then return false; end
        if type(first) ~= "table" then return first == second; end
        for key, value in pairs(first) do
            if not Transaction.Equal(value, second[key]) then return false; end
        end
        for key in pairs(second) do if first[key] == nil then return false; end end
        return true;
    end

    function Transaction.SamePin(first, second)
        if not first or not second then return not first and not second; end
        -- Pin IDs change on restoration. Planning city/auto ownership is retained
        -- in (and verified against) the exact saved registry, not inferred from IDs.
        for _, field in ipairs({ "x", "y", "ownerID", "subjectType",
            "subjectKey", "iconName", "name" }) do
            if first[field] ~= second[field] then return false; end
        end
        return true;
    end

    -- A partially initialized restoration pin needs both its newly allocated
    -- identity and an exact recorded field image. A replacement pin is not ours.
    function Transaction.SameRestorePin(first, second)
        return type(first) == "table" and type(second) == "table"
            and first.id ~= nil and first.id == second.id
            and Transaction.SamePin(first, second)
            and first.visibility == second.visibility;
    end

    Transaction.RECOVERY_SCHEMA_VERSION = 2;

    -- Fail closed before ANY recovery effect. Explicit nil flags distinguish an
    -- absent original config value from a truncated/corrupt backup field.
    function Transaction.ValidateJournal(journal, playerID)
        local function Integer(value)
            return type(value) == "number" and value >= 0 and value % 1 == 0;
        end
        local function Array(value)
            if type(value) ~= "table" then return false; end
            local count = 0;
            for key in pairs(value) do
                if not Integer(key) or key < 1 or key > #value then return false; end
                count = count + 1;
            end
            return count == #value;
        end
        local function Backup(value, wasNil)
            return type(wasNil) == "boolean" and ((wasNil and value == nil)
                or (not wasNil and (type(value) == "string" or type(value) == "table")));
        end
        if type(journal) ~= "table"
            or journal.schemaVersion ~= Transaction.RECOVERY_SCHEMA_VERSION
            or not Integer(journal.playerID)
            or (playerID ~= nil and journal.playerID ~= playerID)
            or (journal.mode ~= "APPLY" and journal.mode ~= "UNDO")
            or not Backup(journal.rawRegistry, journal.rawRegistryWasNil)
            or not Backup(journal.rawUndo, journal.rawUndoWasNil)
            or not Array(journal.plots) or not Array(journal.operations)
            or not Array(journal.participantIDs)
            or type(journal.snapshotSignature) ~= "string" then return false; end
        if journal.intent ~= nil and (not Integer(journal.intent)
            or journal.intent < 1 or journal.intent > #journal.operations) then return false; end
        local function Pin(pin, x, y)
            if pin == false then return true; end
            return type(pin) == "table" and pin.x == x and pin.y == y
                and pin.ownerID == journal.playerID
                and type(pin.iconName) == "string" and type(pin.name) == "string"
                and (pin.subjectType == nil or type(pin.subjectType) == "string")
                and (pin.subjectKey == nil or type(pin.subjectKey) == "string");
        end
        local plots, expected, used = {}, {}, {};
        for _, plot in ipairs(journal.plots) do
            if type(plot) ~= "table" or not Integer(plot.x) or not Integer(plot.y)
                or not Pin(plot.before, plot.x, plot.y) then return false; end
            local key = Key(plot.x, plot.y);
            if plots[key] then return false; end
            plots[key] = plot;
            if plot.observed ~= nil and not Pin(plot.observed, plot.x, plot.y) then return false; end
        end
        for index, operation in ipairs(journal.operations) do
            if type(operation) ~= "table" or type(operation.record) ~= "table" then return false; end
            local record = operation.record;
            if not Integer(record.x) or not Integer(record.y) then return false; end
            local key = Key(record.x, record.y);
            if not plots[key] or not Pin(operation.after, record.x, record.y) then return false; end
            if operation.kind == "remove" then
                if operation.after ~= false then return false; end
            elseif operation.kind == "add" or (journal.mode == "UNDO" and operation.kind == "restore") then
                if operation.after == false then return false; end
                for _, field in ipairs({ "subjectType", "subjectKey", "iconName" }) do
                    if record[field] ~= nil and record[field] ~= operation.after[field] then return false; end
                end
            else return false; end
            used[key] = true;
            if index <= (journal.intent or 0) then expected[key] = operation.after; end
        end
        for key, plot in pairs(plots) do
            if not used[key] or not Transaction.Equal(plot.expected, expected[key]) then return false; end
            local recovery = plot.recovery;
            if recovery then
                if type(recovery) ~= "table" or not Pin(recovery.from, plot.x, plot.y)
                    or not Pin(recovery.after, plot.x, plot.y) then return false; end
                if recovery.phase == "DELETE" then
                    if recovery.from == false or recovery.after ~= false then return false; end
                    local prior = plot.observed;
                    if prior == nil then prior = plot.expected; end
                    if not Transaction.SamePin(recovery.from, prior) then return false; end
                elseif recovery.phase == "RESTORE" then
                    if recovery.from ~= false or plot.before == false
                        or not Transaction.Equal(recovery.after, plot.before) then return false; end
                elseif recovery.phase == "DONE" then
                    if not Transaction.SamePin(recovery.from, plot.before)
                        or not Transaction.Equal(recovery.after, plot.before) then return false; end
                else return false; end
                local build = recovery.build;
                if build ~= nil then
                    if recovery.phase ~= "RESTORE" or type(build) ~= "table" then return false; end
                    if build.step == "CREATE" then
                        if build.pinID ~= nil or build.from ~= false or build.after ~= false
                            or build.checkpoint ~= nil then return false; end
                    else
                        local steps = { CREATED = true, ICON = true, NAME = true,
                            VISIBILITY = true, NOTIFY = true, REGISTER = true };
                        if not steps[build.step] or not (Integer(build.pinID)
                            or (type(build.pinID) == "string" and build.pinID ~= "")) then return false; end
                        local function Partial(pin)
                            return type(pin) == "table" and pin.x == plot.x and pin.y == plot.y
                                and pin.ownerID == journal.playerID and pin.id == build.pinID
                                and type(pin.name) == "string" and type(pin.iconNameWasNil) == "boolean"
                                and ((pin.iconNameWasNil and pin.iconName == nil)
                                    or (not pin.iconNameWasNil and type(pin.iconName) == "string"))
                                and (pin.subjectType == nil or type(pin.subjectType) == "string")
                                and (pin.subjectKey == nil or type(pin.subjectKey) == "string")
                                and (pin.visibility == nil or type(pin.visibility) == "number"
                                    or type(pin.visibility) == "boolean");
                        end
                        if not Partial(build.from) or not Partial(build.after)
                            or (build.checkpoint ~= nil and not Partial(build.checkpoint)) then return false; end
                        local after = Copy(build.from);
                        if build.step == "ICON" then
                            after.iconName = plot.before.iconName;
                            after.iconNameWasNil = false;
                            after.subjectType, after.subjectKey = plot.before.subjectType, plot.before.subjectKey;
                        elseif build.step == "NAME" then after.name = plot.before.name; end
                        if not Transaction.Equal(after, build.after) then return false; end
                        if build.checkpoint ~= nil then
                            local known = Transaction.SameRestorePin(build.checkpoint, build.from)
                                or Transaction.SameRestorePin(build.checkpoint, build.after)
                                or (build.step == "VISIBILITY"
                                    and Transaction.SamePin(build.checkpoint, build.from));
                            if not known then return false; end
                        elseif build.step == "CREATED" then return false; end
                    end
                end
            end
        end
        return true;
    end

    function Transaction.Recover(journal, adapter)
        if not Transaction.ValidateJournal(journal) then
            return false, "RECOVERY_REQUIRED";
        end
        local errors = {};
        local function Attempt(label, action)
            local ok, value = pcall(action);
            if not ok or value == false then
                errors[#errors + 1] = label .. ":" .. tostring(value);
            end
        end
        -- Never discard evidence on any restoration/readback/broadcast failure.
        for index = #journal.plots, 1, -1 do
            local plot = journal.plots[index];
            Attempt(Key(plot.x, plot.y), function()
                return adapter.restore(plot, journal);
            end);
        end
        Attempt("storage", function() return adapter.restoreStorage(journal); end);
        Attempt("broadcast", adapter.broadcast);
        if #errors == 0 then
            Attempt("clear journal", function() return adapter.saveRecovery(nil); end);
        end
        if #errors > 0 then
            journal.recoveryErrors = errors;
            pcall(function() adapter.saveRecovery(journal); end);
            return false, "RECOVERY_REQUIRED", journal;
        end
        return true, "ROLLED_BACK";
    end

    function Transaction.ApplyAtomic(journal, adapter)
        if not Transaction.ValidateJournal(journal) then
            return false, "RECOVERY_REQUIRED", journal;
        end
        local prepared, prepareError = pcall(function()
            adapter.saveRecovery(journal);
        end);
        if not prepared then
            journal.failure = "journal:" .. tostring(prepareError);
            return false, "RECOVERY_REQUIRED", journal;
        end
        local ok, failure = pcall(function()
            for index, operation in ipairs(journal.operations) do
                journal.intent = index; -- persisted BEFORE the possibly throwing call
                for _, plot in ipairs(journal.plots) do
                    if plot.x == operation.record.x and plot.y == operation.record.y then
                        plot.expected = operation.after;
                        break;
                    end
                end
                adapter.saveRecovery(journal);
                adapter.apply(operation, journal);
            end
            adapter.commit(journal);
            adapter.broadcast();
            adapter.saveRecovery(nil);
        end);
        if ok then return true, "APPLIED"; end
        journal.failure = tostring(failure);
        -- Capture partial mutations, including calls that changed state then threw.
        -- Persist them before compensation so retry after reload does not touch a
        -- later user edit. If capture fails, the original intent remains evidence.
        for _, plot in ipairs(journal.plots) do
            local captured, current = pcall(function()
                return adapter.capture(plot.x, plot.y);
            end);
            if captured then plot.observed = current or false; end
        end
        pcall(function() adapter.saveRecovery(journal); end);
        local restored, status = Transaction.Recover(journal, adapter);
        if restored then return false, status; end
        return false, "RECOVERY_REQUIRED", journal;
    end



end;
AMT_BundledModules["amt_mc_quick_setup"] = function()


    -- Quick cluster setup module (pure logic, no game API).
    --
    -- Builds per-city DRAFT profiles (never saved, never applied automatically)
    -- for the beginner one-click flow.  The current city receives the selected
    -- victory template; nearby linked cities receive role templates:
    --   role 1 ECONOMY   (trade backbone)
    --   role 2 SCIENCE   (science/production support)
    --   role 3 CULTURE   (faith/culture support)
    -- District orders are filtered against the caller-provided `available` set
    -- so unavailable mod/expansion districts are skipped.

    AMT_MultiCity = AMT_MultiCity or {};
    AMT_MultiCity.QuickSetup = AMT_MultiCity.QuickSetup or {};

    local QuickSetup = AMT_MultiCity.QuickSetup;

    QuickSetup.SCHEMA_VERSION = 1;

    QuickSetup.DEFAULT_HORIZON = "LONG_TERM";
    QuickSetup.DEFAULT_FUTURE_POPULATION = 10;

    QuickSetup.TEMPLATES = {
        DEFAULT = { "DISTRICT_COMMERCIAL_HUB", "DISTRICT_CAMPUS",
                    "DISTRICT_INDUSTRIAL_ZONE" },
        SCIENCE = { "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB",
                    "DISTRICT_INDUSTRIAL_ZONE" },
        CULTURE = { "DISTRICT_HOLY_SITE", "DISTRICT_THEATER",
                    "DISTRICT_COMMERCIAL_HUB" },
        RELIGION = { "DISTRICT_HOLY_SITE", "DISTRICT_COMMERCIAL_HUB",
                     "DISTRICT_CAMPUS" },
        NAVAL = { "DISTRICT_HARBOR", "DISTRICT_CAMPUS",
                  "DISTRICT_COMMERCIAL_HUB" },
        MILITARY = { "DISTRICT_ENCAMPMENT", "DISTRICT_CAMPUS",
                     "DISTRICT_COMMERCIAL_HUB" },
    };

    QuickSetup.LINKED_ROLES = {
        ECONOMY = { "DISTRICT_COMMERCIAL_HUB", "DISTRICT_CAMPUS",
                    "DISTRICT_INDUSTRIAL_ZONE" },
        SCIENCE = { "DISTRICT_CAMPUS", "DISTRICT_COMMERCIAL_HUB",
                    "DISTRICT_INDUSTRIAL_ZONE" },
        CULTURE = { "DISTRICT_HOLY_SITE", "DISTRICT_THEATER",
                    "DISTRICT_COMMERCIAL_HUB" },
    };

    local function IsAvailable(available, districtType)
        if type(available) == "table" and next(available) ~= nil then
            return available[districtType] == true;
        end
        return true;
    end

    -- Coastal substitution: commercial hub role prefers harbor only when the
    -- city has coast and the district exists in the current rule set.
    local function ResolveTradeDistrict(order, hasCoast, available)
        local preferred = order[1];
        if preferred == "DISTRICT_COMMERCIAL_HUB" and hasCoast
            and IsAvailable(available, "DISTRICT_HARBOR") then
            return "DISTRICT_HARBOR";
        end
        return preferred;
    end

    function QuickSetup.BuildDistrictOrder(templateKey, roleKey, hasCoast,
                                           available)
        local template = nil;
        if roleKey then
            template = QuickSetup.LINKED_ROLES[roleKey];
        end
        template = template or QuickSetup.TEMPLATES[templateKey]
            or QuickSetup.TEMPLATES.DEFAULT;
        local order = {};
        local seen = {};
        for index, districtType in ipairs(template or {}) do
            if index == 1 then
                districtType = ResolveTradeDistrict(
                    template, hasCoast, available
                );
            end
            if not seen[districtType]
                and IsAvailable(available, districtType) then
                seen[districtType] = true;
                table.insert(order, districtType);
            end
        end
        return order;
    end

    function QuickSetup.BuildCityDraft(templateKey, roleKey, hasCoast,
                                      available)
        local order = QuickSetup.BuildDistrictOrder(
            templateKey, roleKey, hasCoast, available
        );
        local selected = {};
        for _, districtType in ipairs(order) do
            selected[districtType] = true;
        end
        local primary = roleKey == nil;
        return {
            specialtyOrder = order,
            selectedSubjects = { DISTRICT = selected },
            futurePopulation = QuickSetup.DEFAULT_FUTURE_POPULATION,
            -- The anchor city keeps one extra specialty slot for the
            -- Government Plaza (player-unique, drafted through M6U).
            -- Population 10 is exactly the requirement for the fourth slot.
            specialtySlotCount = primary and 4 or nil,
            horizon = QuickSetup.DEFAULT_HORIZON,
            improvementSelections = {},
            preserveEnabled = false,
            prioritizeUnique = true,
            -- The anchor (primary) city keeps the Government Plaza locked to
            -- itself; linked role cities leave player-unique districts OFF.
            governmentPlazaLockedToPrimary = primary,
            autoSelectImprovements = true,
        };
    end

    -- linkedFlags: array of { hasCoast = bool, available = set } in linked-city
    -- order.  Returns one draft per entry, roles cycling ECONOMY/SCIENCE/CULTURE.
    function QuickSetup.BuildClusterDrafts(templateKey, linkedFlags)
        local drafts = {};
        for index, flags in ipairs(linkedFlags or {}) do
            local roles = QuickSetup.LINKED_ROLES;
            local roleKeys = { "ECONOMY", "SCIENCE", "CULTURE" };
            local roleKey = roleKeys[((index - 1) % #roleKeys) + 1];
            drafts[index] = QuickSetup.BuildCityDraft(
                nil, roleKey, flags.hasCoast, flags.available
            );
        end
        return drafts;
    end



end;

include("civ6common");
include("InstanceManager");
include("MapTacks");
include("dmt_yieldcalculator");
include("dmt_mappinsubjectmanager");
include("amt_wonderplanner");

AMT_MC_ModulesReady = false;
function AMT_MC_IncludeEditorModules()
    -- Civ6 runs every UI context in its own Lua state.  The planner owns
    -- capabilities and protected module loading; the launch-bar context
    -- only waits for base planner readiness, independently of multi-city.
    AMT_BundledModules["amt_mc_bootstrap"]();
    AMT_BundledModules["amt_mc_contract"]();
    AMT_BundledModules["amt_mc_cluster"]();
    AMT_BundledModules["amt_mc_ui"]();
    AMT_BundledModules["amt_mc_requests"]();
    AMT_BundledModules["amt_mc_solver"]();
    AMT_BundledModules["amt_mc_unique_district"]();
    AMT_BundledModules["amt_mc_transaction"]();
end
AMT_MC_ModuleLoadOK, AMT_MC_ModuleLoadError = pcall(
    AMT_MC_IncludeEditorModules
);
if AMT_MC_ModuleLoadOK and AMT_MultiCity
    and AMT_MultiCity.GetCapabilities
    and AMT_MultiCity.Contract and AMT_MultiCity.Cluster
    and AMT_MultiCity.UIState
    and AMT_MultiCity.Requests and AMT_MultiCity.Solver
    and AMT_MultiCity.UniqueDistrict
    and AMT_MultiCity.Transaction then
    AMT_MC_ModulesReady = true;
else

end

-- Quick setup is an optional beginner helper module; a missing or broken
-- module must never disable the unified editor or the single-city path.
function AMT_MC_IncludeQuickSetupModule()
    AMT_BundledModules["amt_mc_quick_setup"]();
end
AMT_MC_QuickSetupState = {};
AMT_MC_QuickSetupState.loadOK, AMT_MC_QuickSetupState.loadError = pcall(
    AMT_MC_IncludeQuickSetupModule
);
if not AMT_MC_QuickSetupState.loadOK then

end

local ENABLE_VERBOSE_LOGGING = false;
local ENABLE_WONDER_DEBUG = false;
local function Log(msg)
    local text = tostring(msg);
    if ENABLE_VERBOSE_LOGGING
        or string.find(text, "failed", 1, true)
        or string.find(text, "error", 1, true)
        or string.find(text, "WARN", 1, true)
        or string.find(text, "Could not", 1, true) then

    end
end

Log("ContextPtr=" .. tostring(ContextPtr));
Log("Includes done. GetBonusYields=" .. tostring(GetBonusYields) .. " CanPlacePin=" .. tostring(CanPlacePin));

local MAP_PIN_TYPE_DISTRICT = "DISTRICT";
local MAP_PIN_TYPE_IMPROVEMENT = "IMPROVEMENT";
local MAP_PIN_TYPE_WONDER = "WONDER";
local CONFIG_KEY_AUTO_PINS = "AMT_AUTO_PINS_V1";
local CONFIG_KEY_LAST_PLAN = "AMT_LAST_PLAN_V1";
AMT_MC_CONFIG_KEY_SETTINGS = "AMT_LINKED_SETTINGS_V1";
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
-- Keep this context-private-by-name but not as another chunk local: the Civ VI
-- Lua compiler is already at its 200-register ceiling in this legacy file.
m_MCSettingsPanelHidden = false;
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
m_MCMode = false;
-- Context-owned UI glue only; no extra chunk locals near Lua's 200-local limit.
AMT_MC_ModeSelector = { ready = false, open = false, shutdown = false };
m_MCSession = nil;
m_MCPendingScope = nil;
m_MCAutoSelectUndo = {};
m_MCSuppressDraftTracking = false;
m_MCNavHighlightActive = false;
m_MCNavHighlightRemaining = 0;
m_MCUIPhase = 1;
m_MCUICardParticipantIDs = {};
m_MCUIQuickTemplateKey = nil;
m_MCUIQuickCityCount = 0;
m_MCUIQuickUndo = nil;
m_MCUISolveStage = 0;
m_MCApplyDetailsVisible = false;
AMT_MC_MarkCurrentDraftChanged = nil;
AMT_MC_RefreshHeader = nil;
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
    if AMT_MC_M7_LoadRecovery then
        local ok, recovery = pcall(AMT_MC_M7_LoadRecovery);
        if not ok or recovery then return true; end
    end
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
    if m_MCMode and m_MCSession and AMT_MultiCity
        and AMT_MultiCity.UIState then
        local participantID = AMT_MultiCity.UIState.GetActiveID(m_MCSession);
        local participant = participantID
            and m_MCSession.participants[participantID] or nil;
        if participant and participant.participantKind == "REAL_CITY" then
            local player = Players[playerID];
            local cities = player and player:GetCities() or nil;
            local city = cities and cities:FindID(participant.cityID) or nil;
            if city and city:GetOwner() == playerID then return city; end
        end
    end
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
        local strategy = GetDistrictStrategyType(option.subjectKey);
        if option.requiresPopulation
            and IsDistrictAlreadyInCity(city, option.subjectKey)
            and strategy
            and not lockedStrategies[strategy] then
            lockedSet[option.subjectKey] = true;
            lockedStrategies[strategy] = true;
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

    -- Existing/founded districts are de-duplicated by strategy family in
    -- GetLockedSpecialtyDistricts.  Future choices are different: preserve
    -- their exact district identity and apply only the rules explicitly
    -- declared in MutuallyExclusiveDistricts.  This keeps the slot-count fix
    -- from silently turning a strategic scoring family into a UI ban.
    local future, seen = {}, {};
    for index = 1, tonumber(plan.slotCount) or 0 do
        local districtType = plan.slots and plan.slots[index] or nil;
        local conflicts = false;
        if districtType then
            for _, lockedType in ipairs(locked) do
                if AreDistrictsMutuallyExclusive(
                    districtType, lockedType
                ) then
                    conflicts = true;
                    break;
                end
            end
        end
        if districtType and not conflicts then
            for _, futureType in ipairs(future) do
                if AreDistrictsMutuallyExclusive(
                    districtType, futureType
                ) then
                    conflicts = true;
                    break;
                end
            end
        end
        if districtType and not conflicts
            and not lockedSet[districtType]
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

function FindMutuallyExclusiveSpecialtySlot(plan, districtType)
    if not plan then return nil; end
    for index = 1, plan.slotCount do
        local plannedType = plan.slots[index];
        if plannedType and AreDistrictsMutuallyExclusive(
            districtType, plannedType
        ) then
            return index;
        end
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
    if AMT_MC_MarkCurrentDraftChanged then
        AMT_MC_MarkCurrentDraftChanged();
    end
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
        local lockedNormalized = NormalizeCitySpecialtyPlan(city, plan);
        if plan.mcDeferredOrder then
            -- M6U deferred tail: items beyond the city's visible slot count
            -- move back into the first free real slot automatically, so a
            -- locked player-unique district keeps its place without the
            -- single-city path ever seeing this branch.
            local deferred = {};
            for _, districtType in ipairs(plan.mcDeferredOrder) do
                local placed = false;
                for index = #lockedNormalized + 1, plan.slotCount do
                    if not plan.slots[index] then
                        plan.slots[index] = districtType;
                        placed = true;
                        break;
                    end
                end
                if not placed then table.insert(deferred, districtType); end
            end
            plan.mcDeferredOrder = deferred;
        end
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
    -- Mutually exclusive districts remain separate player choices.  Within
    -- one city the game permits only one, so choosing the alternative replaces
    -- the prior choice in-place instead of treating both icons as the same
    -- selection or consuming a second population slot.  Other cities keep
    -- independent plans and may choose the other district normally.
    local alternativeIndex = FindMutuallyExclusiveSpecialtySlot(
        plan, districtType
    );
    if alternativeIndex and alternativeIndex > #locked then
        plan.slots[alternativeIndex] = districtType;
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
        -- Reused controls keep every old callback otherwise; a stale drag
        -- handler can reorder the previous city's slot.  Clear all of them
        -- before wiring this row.
        instance.SlotDrag:ClearCallback(Drag.eDown);
        instance.SlotDrag:ClearCallback(Drag.eDrag);
        instance.SlotDrag:ClearCallback(Drag.eDrop);
        instance.ClearSlotButton:ClearCallback(Mouse.eLClick);
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
                if m_MCMode and AMT_MC_M6U_IsSupported(slotDistrict) then
                    AMT_MC_M6U_SetMode(
                        slotDistrict,
                        AMT_MultiCity.UniqueDistrict.MODE_OFF
                    );
                end
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
    for _, districtType in ipairs(plan.mcDeferredOrder or {}) do
        -- M6U: tail items pushed past the visible specialty slot count stay
        -- visible as deferred rows (UNIQUE_DISTRICT_UI_PLAN section 6.2).
        local instance = m_PriorityEntryIM:GetInstance();
        instance.SlotDrag:ClearCallback(Drag.eDown);
        instance.SlotDrag:ClearCallback(Drag.eDrag);
        instance.SlotDrag:ClearCallback(Drag.eDrop);
        instance.ClearSlotButton:ClearCallback(Mouse.eLClick);
        instance.OrderIndex:SetText(Locale.Lookup(
            "LOC_AMT_MC_UNIQUE_DEFERRED_MARK"
        ));
        instance.SlotIcon:SetHide(false);
        instance.SlotIcon:SetIcon(GetSubjectIcon(
            MAP_PIN_TYPE_DISTRICT, districtType
        ));
        instance.SlotName:SetText(Locale.Lookup(
            "LOC_AMT_MC_UNIQUE_DEFERRED_ROW",
            GetDistrictDisplay(districtType)
        ));
        instance.ClearSlotButton:SetHide(true);
        instance.SlotDrag:SetHide(true);
        instance.SlotFrame:SetToolTipString(Locale.Lookup(
            "LOC_AMT_MC_UNIQUE_DEFERRED_TOOLTIP"
        ));
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
            local selectedCount = CountSelectedSubjects(subjectType);
            local prefix = selectedCount > 0 and "✓ " or "";
            button:SetText(prefix .. Locale.Lookup(labels[subjectType])
                .. "  ·  " .. tostring(selectedCount));
        end
    end
    local showAuto = m_MCMode
        and m_CurrentCategory == MAP_PIN_TYPE_IMPROVEMENT;
    if Controls.MCAutoSelectImprovementsButton then
        Controls.MCAutoSelectImprovementsButton:SetHide(not showAuto);
    end
    if Controls.MCUndoAutoSelectButton then
        local participantID = m_MCSession
            and AMT_MultiCity.UIState.GetActiveID(m_MCSession) or nil;
        Controls.MCUndoAutoSelectButton:SetHide(
            not showAuto or not participantID
                or m_MCAutoSelectUndo[participantID] == nil
        );
    end
    if Controls.CategoryActions then
        Controls.CategoryActions:CalculateSize();
        Controls.CategoryActions:ReprocessAnchoring();
    end
end

RefreshPlannerItemGrid = function()
    m_PlannerIconIM:ResetInstances();
    -- M6U rows live in the same ItemGrid stack as ordinary icons; reset them
    -- on EVERY category render so they can never leak into improvement or
    -- wonder pages.
    AMT_MC_M6U_ResetUniqueRows();
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
        local uniqueSubjects = {};
        if m_MCMode then
            uniqueSubjects = AMT_MC_M6U_SubjectList();
        end
        if #uniqueSubjects > 0 then
            AddDistrictGroupHeader(
                "LOC_AMT_MC_UNIQUE_GROUP_HEADER", #uniqueSubjects
            );
            AMT_MC_M6U_PopulateUniqueRows(uniqueSubjects);
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
            local keepSharedUnique = m_MCMode
                and subjectType == MAP_PIN_TYPE_DISTRICT
                and AMT_MC_M6U_IsSupported(subjectKey);
            if not valid[subjectKey] and not keepSharedUnique then
                selected[subjectKey] = nil;
            end
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
            local keepSharedUnique = districtType and m_MCMode
                and AMT_MC_M6U_IsSupported(districtType);
            if districtType and not keepSharedUnique
                and (not validSpecialty[districtType]
                or (IsPreserveDistrict(districtType) and not m_EnablePreserve)) then
                plan.slots[index] = nil;
            end
        end
    end
    RebuildSpecialtySelectionUnion();
end

local function RepopulatePopup()
    m_MCSuppressDraftTracking = true;
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

    -- The shared unique-district draft is authoritative across city switches.
    if m_MCMode and AMT_MC_M6U_ReconcileDraftPlans then
        AMT_MC_M6U_ReconcileDraftPlans();
    end
    local cityPlan = ActivateCityPlannerState(city);
    m_PlannerOptions = BuildPlayerPlannerOptions(playerID);
    if m_MCMode and AMT_MC_M6U_FilterDistrictOptions then
        -- M6U: supported player-unique districts leave the ordinary district
        -- page so their per-city legacy selections cannot be compiled again.
        AMT_MC_M6U_FilterDistrictOptions();
    end
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
    m_MCSuppressDraftTracking = false;
    if AMT_MC_RefreshHeader then AMT_MC_RefreshHeader(); end
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
            local isAlreadyPresent = IsDistrictAlreadyInCity(
                city, requiredDistrict
            );
            if not isSelected
                and not lockedStrategies[requiredStrategy]
                and not isAlreadyPresent then
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

function ImprovementPlacement.CanPlan(item, playerID, runCache)
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

    local runtimeTerrainMatch = false;
    if AMT_RuntimeImprovementRules
        and AMT_RuntimeImprovementRules.CanUseTerrain then
        runtimeTerrainMatch = AMT_RuntimeImprovementRules.CanUseTerrain(
            runCache, item, playerID
        );
    end

    local engineResult = nil;
    if ImprovementBuilder and ImprovementBuilder.CanHaveImprovement then
        local ok, result = pcall(
            ImprovementBuilder.CanHaveImprovement,
            plot, row.Index, -1
        );
        if ok then engineResult = result; end
        -- The engine helper only sees the current plot.  A manual operation
        -- tack can intentionally describe a future cleared/planted state.
        if engineResult == false and not directive
            and not runtimeTerrainMatch then return false; end
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
    matchesTerrain = matchesTerrain or runtimeTerrainMatch;
    local matchesFeature = feature
        and ImprovementPlacement.AnyRuleUnlocked(
            rules.features[feature.FeatureType], playerID
        ) or false;

    -- Oil wells and offshore oil rigs set EnforceTerrain because their valid
    -- resource and terrain lists are conjunctive: the plot needs visible oil
    -- and must also be in the appropriate land/sea terrain set.  Ordinary
    -- farms and mines intentionally keep the usual resource-or-terrain rules.
    if IsTrue(row.EnforceTerrain) then
        if rules.hasResources and not matchesResource then
            return false;
        end
        if rules.hasTerrains and not matchesTerrain then
            return false;
        end
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

local function GetStrategicLayoutScore(items, fixedSubjects, options)
    local total = 0;
    local coverage = {
        DISTRICT_INDUSTRIAL_ZONE = {},
        DISTRICT_ENTERTAINMENT_COMPLEX = {},
    };
    local cityDistricts = {};
    local player = Players[Game.GetLocalPlayer()];
    -- M4 joint path (plan 8.1): optional scope narrows coverage scoring to
    -- the participant set with a fixed baseline and diminishing returns.
    -- Legacy callers pass nothing and keep the original behavior verbatim.
    local scoped = type(options) == "table"
        and options.scopeCities or nil;
    local baselineCovered = type(options) == "table"
        and options.baselineCovered or nil;
    local scopeCityIDs = nil;
    if scoped then
        scopeCityIDs = {};
        for _, city in ipairs(scoped) do
            scopeCityIDs[city:GetID()] = true;
        end
    end
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
                if scoped then
                    local base = baselineCovered
                        and baselineCovered[baseType] or nil;
                    for _, city in ipairs(scoped) do
                        local cityID = city:GetID();
                        if not (base and base[cityID]) then
                            if Map.GetPlotDistance(
                                item.x, item.y, city:GetX(), city:GetY()
                            ) <= 6 then
                                coverage[baseType][cityID] =
                                    (coverage[baseType][cityID] or 0) + 1;
                            end
                        end
                    end
                else
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
    end
    if scoped then
        local marginal = (AMT_MultiCity and AMT_MultiCity.Solver
            and AMT_MultiCity.Solver.CoverageMarginalBenefit)
            or function(count) return 1.4; end;
        local participantUncovered = false;
        for baseType, cityCounts in pairs(coverage) do
            local base = baselineCovered
                and baselineCovered[baseType] or nil;
            for _, city in ipairs(scoped) do
                local cityID = city:GetID();
                if not (base and base[cityID])
                    and (cityCounts[cityID] or 0) == 0 then
                    participantUncovered = true;
                end
            end
        end
        for baseType, cityCounts in pairs(coverage) do
            for cityID, count in pairs(cityCounts) do
                local benefit = 0;
                for step = 1, count do
                    benefit = benefit + marginal(step - 1);
                end
                total = total + benefit;
            end
        end
        -- Non-participant cities: low-weight extra only after participant
        -- targets are met (plan 8.1).
        if not participantUncovered then
            local bonusCovered = {};
            local bonusCities = 0;
            for _, item in ipairs(items or {}) do
                if item.subjectType == MAP_PIN_TYPE_DISTRICT then
                    local baseType = item.baseDistrictType
                        or GetDistrictStrategyType(item.subjectKey);
                    if coverage[baseType] then
                        for _, city in player:GetCities():Members() do
                            local cityID = city:GetID();
                            if not scopeCityIDs[cityID]
                                and not bonusCovered[cityID]
                                and Map.GetPlotDistance(
                                    item.x, item.y,
                                    city:GetX(), city:GetY()
                                ) <= 6 then
                                bonusCovered[cityID] = true;
                                bonusCities = bonusCities + 1;
                            end
                        end
                    end
                end
            end
            total = total + math.min(bonusCities, 3) * 0.1;
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

-- Runtime improvement rules are used by both the base game and balance mods.
-- The static Improvement_Valid* and Improvement_Yield* tables do not contain
-- abilities such as Canada's tundra farms or BBG Mali's desert farms.  Compile
-- the small active subset once per planning run, then keep candidate checks at
-- indexed-table cost.  Unknown requirement types never grant legality or
-- yields; they retain the existing conservative behavior.
AMT_RuntimeImprovementRules = AMT_RuntimeImprovementRules or {};

function AMT_RuntimeImprovementRules.AddRequirementSet(
    target, seen, setID
)
    if setID and not seen[setID] then
        seen[setID] = true;
        table.insert(target, setID);
    end
end

function AMT_RuntimeImprovementRules.ExtractImprovementTypes(
    runCache, setID, result, seen
)
    result = result or {};
    seen = seen or {};
    if not setID or seen[setID] then return result; end
    seen[setID] = true;
    local set = runCache.influenceRequirementSets
        and runCache.influenceRequirementSets[setID] or nil;
    if not set then return result; end
    for _, requirement in ipairs(set.requirements or {}) do
        local requirementType = requirement.requirementType;
        local args = requirement.arguments or {};
        if requirementType == "REQUIREMENT_PLOT_IMPROVEMENT_TYPE_MATCHES"
            and args.ImprovementType then
            result[args.ImprovementType] = true;
        elseif requirementType == "REQUIREMENT_REQUIREMENTSET_IS_MET" then
            AMT_RuntimeImprovementRules.ExtractImprovementTypes(
                runCache,
                args.RequirementSetId or args.RequirementSet,
                result, seen
            );
        end
    end
    return result;
end

function AMT_RuntimeImprovementRules.BuildIndexes(runCache)
    if not runCache then return nil; end
    if runCache.runtimeImprovementRules then
        return runCache.runtimeImprovementRules;
    end
    if AMT_InfluenceScope and AMT_InfluenceScope.EnsureIndexes then
        AMT_InfluenceScope.EnsureIndexes(runCache);
    end
    local index = {
        terrain = {},
        terrainDedupe = {},
        yields = {},
        yieldDedupe = {},
        unknownRequirementTypes = {},
        terrainRuleCount = 0,
        yieldRuleCount = 0,
    };
    runCache.runtimeImprovementRules = index;

    local function AddTerrainRule(
        modifierID, modifier, args, activeRuntime
    )
        local improvementType = args.ImprovementType;
        local terrainType = args.TerrainType;
        if not improvementType or not terrainType then return; end
        local dedupeKey = improvementType .. "@" .. terrainType;
        index.terrainDedupe[dedupeKey] =
            index.terrainDedupe[dedupeKey] or {};
        if index.terrainDedupe[dedupeKey][modifierID] then return; end
        index.terrainDedupe[dedupeKey][modifierID] = true;
        index.terrain[improvementType] =
            index.terrain[improvementType] or {};
        index.terrain[improvementType][terrainType] =
            index.terrain[improvementType][terrainType] or {};
        local sets = {};
        if not activeRuntime and modifier.OwnerRequirementSetId then
            table.insert(sets, modifier.OwnerRequirementSetId);
        end
        if modifier.SubjectRequirementSetId then
            table.insert(sets, modifier.SubjectRequirementSetId);
        end
        table.insert(index.terrain[improvementType][terrainType], {
            modifierID = modifierID,
            requirementSetIDs = sets,
            activeRuntime = activeRuntime == true,
        });
        index.terrainRuleCount = index.terrainRuleCount + 1;
    end

    local function AddYieldRule(
        improvementType, modifierID, modifier, args, requirementSetIDs,
        activeRuntime
    )
        local yieldType = args.YieldType;
        local amount = tonumber(args.Amount);
        if not improvementType or not yieldType or amount == nil then return; end
        index.yieldDedupe[improvementType] =
            index.yieldDedupe[improvementType] or {};
        if index.yieldDedupe[improvementType][modifierID] then return; end
        index.yieldDedupe[improvementType][modifierID] = true;
        index.yields[improvementType] = index.yields[improvementType] or {};
        table.insert(index.yields[improvementType], {
            modifierID = modifierID,
            yieldType = yieldType,
            amount = amount,
            requirementSetIDs = requirementSetIDs or {},
            activeRuntime = activeRuntime == true,
        });
        index.yieldRuleCount = index.yieldRuleCount + 1;
    end

    -- A modifier owned by the planned improvement is a potential rule even
    -- before the improvement has a runtime GameEffects object.
    local function AddImprovementModifier(
        improvementType, modifierID, inheritedSets, seen
    )
        if not improvementType or not modifierID then return; end
        seen = seen or {};
        if seen[modifierID] then return; end
        seen[modifierID] = true;
        local modifier = GameInfo.Modifiers
            and GameInfo.Modifiers[modifierID] or nil;
        local dynamic = modifier and GameInfo.DynamicModifiers
            and GameInfo.DynamicModifiers[modifier.ModifierType] or nil;
        if not modifier or not dynamic then return; end
        local sets = {};
        local setSeen = {};
        for _, setID in ipairs(inheritedSets or {}) do
            AMT_RuntimeImprovementRules.AddRequirementSet(
                sets, setSeen, setID
            );
        end
        AMT_RuntimeImprovementRules.AddRequirementSet(
            sets, setSeen, modifier.OwnerRequirementSetId
        );
        AMT_RuntimeImprovementRules.AddRequirementSet(
            sets, setSeen, modifier.SubjectRequirementSetId
        );
        local args = runCache.influenceModifierArguments[modifierID] or {};
        if dynamic.EffectType == "EFFECT_ATTACH_MODIFIER" then
            AddImprovementModifier(
                improvementType,
                args.ModifierId or args.ModifierID,
                sets, seen
            );
        elseif dynamic.EffectType == "EFFECT_ADJUST_PLOT_YIELD" then
            AddYieldRule(
                improvementType, modifierID, modifier, args, sets, false
            );
        end
    end

    if GameInfo.ImprovementModifiers then
        for row in GameInfo.ImprovementModifiers() do
            AddImprovementModifier(
                row.ImprovementType,
                row.ModifierId or row.ModifierID,
                {}, {}
            );
        end
    end

    -- Player traits are known without consulting runtime objects.  Indexing
    -- their rules also preserves long-term planning for civic/technology-gated
    -- abilities whose GameEffects object has no current subjects yet.
    local playerTraits = MapTacks.PlayerTraits(runCache.playerID);
    if GameInfo.TraitModifiers then
        for row in GameInfo.TraitModifiers() do
            if playerTraits[row.TraitType] then
                local modifierID = row.ModifierId or row.ModifierID;
                local modifier = modifierID and GameInfo.Modifiers
                    and GameInfo.Modifiers[modifierID] or nil;
                local dynamic = modifier and GameInfo.DynamicModifiers
                    and GameInfo.DynamicModifiers[modifier.ModifierType] or nil;
                local args = modifierID
                    and runCache.influenceModifierArguments[modifierID] or {};
                if modifier and dynamic then
                    if dynamic.EffectType
                        == "EFFECT_ADJUST_IMPROVEMENT_VALID_TERRAIN" then
                        AddTerrainRule(
                            modifierID, modifier, args, false
                        );
                    elseif dynamic.EffectType
                        == "EFFECT_ADJUST_PLOT_YIELD" then
                        local improvementTypes =
                            AMT_RuntimeImprovementRules.ExtractImprovementTypes(
                                runCache, modifier.SubjectRequirementSetId,
                                {}, {}
                            );
                        for improvementType in pairs(improvementTypes) do
                            local sets = {};
                            if modifier.OwnerRequirementSetId then
                                table.insert(
                                    sets, modifier.OwnerRequirementSetId
                                );
                            end
                            if modifier.SubjectRequirementSetId then
                                table.insert(
                                    sets, modifier.SubjectRequirementSetId
                                );
                            end
                            AddYieldRule(
                                improvementType, modifierID, modifier, args,
                                sets, false
                            );
                        end
                    end
                end
            end
        end
    end

    -- Active player/leader/belief/building modifiers can grant valid terrain
    -- or extra yields to a matching hypothetical improvement.
    for modifierID in pairs(
        runCache.influenceRuntimeRelevantModifierIDs or {}
    ) do
        local modifier = GameInfo.Modifiers
            and GameInfo.Modifiers[modifierID] or nil;
        local dynamic = modifier and GameInfo.DynamicModifiers
            and GameInfo.DynamicModifiers[modifier.ModifierType] or nil;
        local args = runCache.influenceModifierArguments[modifierID] or {};
        if modifier and dynamic then
            if dynamic.EffectType
                == "EFFECT_ADJUST_IMPROVEMENT_VALID_TERRAIN" then
                AddTerrainRule(modifierID, modifier, args, true);
            elseif dynamic.EffectType == "EFFECT_ADJUST_PLOT_YIELD" then
                local improvementTypes =
                    AMT_RuntimeImprovementRules.ExtractImprovementTypes(
                        runCache, modifier.SubjectRequirementSetId, {}, {}
                    );
                for improvementType in pairs(improvementTypes) do
                    local sets = {};
                    if modifier.SubjectRequirementSetId then
                        table.insert(sets, modifier.SubjectRequirementSetId);
                    end
                    AddYieldRule(
                        improvementType, modifierID, modifier, args,
                        sets, true
                    );
                end
            end
        end
    end

    return index;
end

function AMT_RuntimeImprovementRules.GetContext(
    runCache, subject, playerID
)
    local x = subject.x or subject.X;
    local y = subject.y or subject.Y;
    local plot = subject.plot or (x and y and Map.GetPlot(x, y)) or nil;
    if not plot then return nil; end
    local terrain = GameInfo.Terrains[plot:GetTerrainType()];
    local terrainType = terrain and terrain.TerrainType or nil;
    local featureType = nil;
    local resourceType = nil;
    if GetPlotFeatureTypes then
        local _, realizedFeature, _, _, _, realizedResource =
            GetPlotFeatureTypes(plot, playerID);
        featureType = realizedFeature;
        resourceType = realizedResource;
    else
        local featureIndex = plot:GetFeatureType();
        local feature = featureIndex and featureIndex >= 0
            and GameInfo.Features[featureIndex] or nil;
        featureType = feature and feature.FeatureType or nil;
        local resource = ImprovementPlacement.GetVisibleResource(
            plot, playerID
        );
        resourceType = resource and resource.ResourceType or nil;
    end
    local cityID = subject.cityID or subject.CityID;
    local player = Players[playerID];
    local city = player and cityID ~= nil
        and player:GetCities():FindID(cityID) or nil;
    if not city then city = AMT_GetPlotPurchaseCity(plot); end
    return {
        runCache = runCache,
        playerID = playerID,
        player = player,
        city = city,
        plot = plot,
        x = x,
        y = y,
        improvementType = subject.subjectKey or subject.Key,
        terrainType = terrainType,
        featureType = featureType,
        resourceType = resourceType,
    };
end

function AMT_RuntimeImprovementRules.GetResourceClass(context)
    local resource = context.resourceType and GameInfo.Resources[
        context.resourceType
    ] or nil;
    return resource and resource.ResourceClassType or nil;
end

function AMT_RuntimeImprovementRules.HasAdjacent(context, kind, target)
    if not context.plot or target == nil then return nil; end
    for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
        local plot = Map.GetAdjacentPlot(
            context.x, context.y, direction
        );
        if plot then
            local terrainType, featureType, improvementType,
                wonderType, districtType, resourceType;
            if GetPlotFeatureTypes then
                terrainType, featureType, improvementType,
                    wonderType, districtType, resourceType =
                    GetPlotFeatureTypes(plot, context.playerID);
            else
                local terrain = GameInfo.Terrains[plot:GetTerrainType()];
                terrainType = terrain and terrain.TerrainType or nil;
                local featureIndex = plot:GetFeatureType();
                local feature = featureIndex and featureIndex >= 0
                    and GameInfo.Features[featureIndex] or nil;
                featureType = feature and feature.FeatureType or nil;
                local improvementIndex = plot:GetImprovementType();
                local improvement = improvementIndex
                    and improvementIndex >= 0
                    and GameInfo.Improvements[improvementIndex] or nil;
                improvementType = improvement
                    and improvement.ImprovementType or nil;
                local districtIndex = plot:GetDistrictType();
                local district = districtIndex and districtIndex >= 0
                    and GameInfo.Districts[districtIndex] or nil;
                districtType = district and district.DistrictType or nil;
                local resource = ImprovementPlacement.GetVisibleResource(
                    plot, context.playerID
                );
                resourceType = resource and resource.ResourceType or nil;
            end
            local value = kind == "TERRAIN" and terrainType
                or (kind == "FEATURE" and featureType)
                or (kind == "IMPROVEMENT" and improvementType)
                or (kind == "WONDER" and wonderType)
                or (kind == "DISTRICT" and districtType)
                or (kind == "RESOURCE" and resourceType)
                or nil;
            if value == target then return true; end
        end
    end
    return false;
end

function AMT_RuntimeImprovementRules.EvaluateRequirement(
    context, requirement, setSeen
)
    local requirementType = requirement.requirementType;
    local args = requirement.arguments or {};
    local result = nil;
    if requirementType == "REQUIREMENT_PLAYER_HAS_CIVIC" then
        local civic = args.CivicType
            and GameInfo.Civics[args.CivicType] or nil;
        if m_PlanningHorizon ~= "CURRENT" then
            result = civic ~= nil;
        elseif civic and context.player then
            result = context.player:GetCulture():HasCivic(civic.Index);
        end
    elseif requirementType == "REQUIREMENT_PLAYER_HAS_TECHNOLOGY" then
        local technology = args.TechnologyType
            and GameInfo.Technologies[args.TechnologyType] or nil;
        if m_PlanningHorizon ~= "CURRENT" then
            result = technology ~= nil;
        elseif technology and context.player then
            result = context.player:GetTechs():HasTech(technology.Index);
        end
    elseif requirementType == "REQUIREMENT_PLOT_TERRAIN_TYPE_MATCHES" then
        result = context.terrainType == args.TerrainType;
    elseif requirementType == "REQUIREMENT_PLOT_FEATURE_TYPE_MATCHES" then
        result = context.featureType == args.FeatureType;
    elseif requirementType == "REQUIREMENT_PLOT_IMPROVEMENT_TYPE_MATCHES" then
        result = context.improvementType == args.ImprovementType;
    elseif requirementType == "REQUIREMENT_PLOT_RESOURCE_TYPE_MATCHES" then
        result = context.resourceType == args.ResourceType;
    elseif requirementType
        == "REQUIREMENT_PLOT_RESOURCE_CLASS_TYPE_MATCHES" then
        result = AMT_RuntimeImprovementRules.GetResourceClass(context)
            == args.ResourceClassType;
    elseif requirementType
        == "REQUIREMENT_PLOT_IMPROVED_RESOURCE_CLASS_TYPE_MATCHES" then
        result = context.improvementType ~= nil
            and AMT_RuntimeImprovementRules.GetResourceClass(context)
                == args.ResourceClassType;
    elseif requirementType == "REQUIREMENT_PLOT_HAS_ANY_IMPROVEMENT" then
        result = context.improvementType ~= nil;
    elseif requirementType
        == "REQUIREMENT_PLOT_ADJACENT_IMPROVEMENT_TYPE_MATCHES" then
        result = AMT_RuntimeImprovementRules.HasAdjacent(
            context, "IMPROVEMENT", args.ImprovementType
        );
    elseif requirementType
        == "REQUIREMENT_PLOT_ADJACENT_FEATURE_TYPE_MATCHES" then
        result = AMT_RuntimeImprovementRules.HasAdjacent(
            context, "FEATURE", args.FeatureType
        );
    elseif requirementType
        == "REQUIREMENT_PLOT_ADJACENT_DISTRICT_TYPE_MATCHES" then
        result = AMT_RuntimeImprovementRules.HasAdjacent(
            context, "DISTRICT", args.DistrictType
        );
    elseif requirementType
        == "REQUIREMENT_PLOT_ADJACENT_RESOURCE_TYPE_MATCHES" then
        result = AMT_RuntimeImprovementRules.HasAdjacent(
            context, "RESOURCE", args.ResourceType
        );
    elseif requirementType == "REQUIREMENT_PLOT_ADJACENT_TO_RIVER"
        or requirementType == "REQUIREMENT_PLOT_IS_RIVER" then
        local ok, value = pcall(function()
            return context.plot:IsRiver();
        end);
        if ok then result = value == true; end
    elseif requirementType == "REQUIREMENT_PLOT_IS_FRESH_WATER" then
        local ok, value = pcall(function()
            return context.plot:IsFreshWater();
        end);
        if ok then result = value == true; end
    elseif requirementType == "REQUIREMENT_CITY_HAS_BUILDING" then
        local building = args.BuildingType
            and GameInfo.Buildings[args.BuildingType] or nil;
        local buildings = context.city and context.city:GetBuildings() or nil;
        if building and buildings then
            local ok, value = pcall(
                buildings.HasBuilding, buildings, building.Index
            );
            if ok then result = value == true; end
        end
    elseif requirementType == "REQUIREMENT_CITY_HAS_DISTRICT" then
        local district = args.DistrictType
            and GameInfo.Districts[args.DistrictType] or nil;
        local districts = context.city and context.city:GetDistricts() or nil;
        if district and districts then
            local ok, value = pcall(
                districts.HasDistrict, districts, district.Index
            );
            if ok then result = value == true; end
        end
    elseif requirementType == "REQUIREMENT_REQUIREMENTSET_IS_MET" then
        result = AMT_RuntimeImprovementRules.EvaluateSet(
            context,
            args.RequirementSetId or args.RequirementSet,
            setSeen
        );
    end
    if result == nil then
        local index = context.runCache.runtimeImprovementRules;
        local unknownType = tostring(requirementType or "UNKNOWN");
        if not index.unknownRequirementTypes[unknownType] then
            index.unknownRequirementTypes[unknownType] = true;
        end
        return nil;
    end
    if requirement.inverse then result = not result; end
    return result;
end

function AMT_RuntimeImprovementRules.EvaluateSet(context, setID, seen)
    if not setID then return true; end
    seen = seen or {};
    if seen[setID] then return nil; end
    seen[setID] = true;
    local set = context.runCache.influenceRequirementSets
        and context.runCache.influenceRequirementSets[setID] or nil;
    if not set then
        seen[setID] = nil;
        return nil;
    end
    local testAny = set.setType == "REQUIREMENTSET_TEST_ANY";
    local sawUnknown = false;
    for _, requirement in ipairs(set.requirements or {}) do
        local result = AMT_RuntimeImprovementRules.EvaluateRequirement(
            context, requirement, seen
        );
        if result == nil then
            sawUnknown = true;
        elseif testAny and result then
            seen[setID] = nil;
            return true;
        elseif not testAny and not result then
            seen[setID] = nil;
            return false;
        end
    end
    seen[setID] = nil;
    if sawUnknown then return nil; end
    return testAny and false or true;
end

function AMT_RuntimeImprovementRules.RuleApplies(context, rule)
    for _, setID in ipairs(rule.requirementSetIDs or {}) do
        local result = AMT_RuntimeImprovementRules.EvaluateSet(
            context, setID, {}
        );
        if result ~= true then return false, result == nil; end
    end
    return true, false;
end

function AMT_RuntimeImprovementRules.CanUseTerrain(
    runCache, item, playerID
)
    if not runCache then return false; end
    local index = AMT_RuntimeImprovementRules.BuildIndexes(runCache);
    local terrain = item.plot
        and GameInfo.Terrains[item.plot:GetTerrainType()] or nil;
    local rules = terrain and index.terrain[item.subjectKey]
        and index.terrain[item.subjectKey][terrain.TerrainType] or nil;
    if not rules then return false; end
    local context = AMT_RuntimeImprovementRules.GetContext(
        runCache, item, playerID
    );
    if not context then return false; end
    for _, rule in ipairs(rules) do
        local applies, unknown =
            AMT_RuntimeImprovementRules.RuleApplies(context, rule);
        if applies then
            return true;
        elseif unknown then
        end
    end
    return false;
end

function AMT_RuntimeImprovementRules.AddYieldChanges(
    runCache, playerID, subject, yields
)
    if not runCache or not subject then return yields; end
    local subjectType = subject.subjectType or subject.Type;
    if subjectType ~= MAP_PIN_TYPE_IMPROVEMENT then return yields; end
    local improvementType = subject.subjectKey or subject.Key;
    local index = AMT_RuntimeImprovementRules.BuildIndexes(runCache);
    local rules = index.yields[improvementType];
    if not rules then return yields; end
    local context = AMT_RuntimeImprovementRules.GetContext(
        runCache, subject, playerID
    );
    if not context then return yields; end
    for _, rule in ipairs(rules) do
        local applies, unknown =
            AMT_RuntimeImprovementRules.RuleApplies(context, rule);
        if applies then
            yields[rule.yieldType] = (yields[rule.yieldType] or 0)
                + rule.amount;
        elseif unknown then
        end
    end
    return yields;
end

function AMT_GetPlannerBonusYields(playerID, subject, runCache)
    local yields = GetBonusYields(playerID, subject) or {};
    return AMT_RuntimeImprovementRules.AddYieldChanges(
        runCache, playerID, subject, yields
    );
end

local function EvaluatePlan(
    playerID, items, weights, ignoredKeys, fixedSubjects, runCache, options
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
                or ImprovementPlacement.CanPlan(item, playerID, runCache);
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
                yields = AMT_GetPlannerBonusYields(
                    playerID, subject, runCache
                );
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
                if item.plot then
                    if m_MCMode then
                        -- Multi-city candidate tables can carry a plot-like
                        -- object whose GetYield method is missing; one bad
                        -- penalty call must not void the whole DMT
                        -- projection.  The lenient evaluator remains the
                        -- final fallback.
                        local penaltyOK, penalty = pcall(
                            GetTileYieldPenalty,
                            item.plot, weights, playerID
                        );
                        if penaltyOK then
                            total = total - penalty;
                        else
                            AMT_MC_M3State.penaltySkipCount =
                                (AMT_MC_M3State.penaltySkipCount or 0) + 1;
                            if AMT_MC_M3State.penaltySkipCount <= 3 then

                            end
                        end
                    else
                        total = total - GetTileYieldPenalty(
                            item.plot, weights, playerID
                        );
                    end
                else
                    -- A few multi-city candidate tables lost their plot
                    -- object on the way into the solver.  Repair from
                    -- coordinates and, only for this rare path, guard the
                    -- penalty call so one bad entry cannot void the whole
                    -- DMT projection (the lenient evaluator is the final
                    -- fallback).
                    local penaltyPlot = item.x ~= nil and item.y ~= nil
                        and Map.GetPlot(item.x, item.y) or nil;
                    item.plot = penaltyPlot;
                    if penaltyPlot then
                        local penaltyOK, penalty = pcall(
                            GetTileYieldPenalty,
                            penaltyPlot, weights, playerID
                        );
                        if penaltyOK then
                            total = total - penalty;
                        end
                    end
                end
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
                    yields = AMT_GetPlannerBonusYields(
                        playerID, subject, runCache
                    );
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
        total = total + GetStrategicLayoutScore(
            items, fixedSubjects, options
        );
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
    if not ImprovementPlacement.CanPlan(item, playerID, runCache) then
        return nil;
    end
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
                            ImprovementPlacement.CanPlan(
                                item, playerID, runCache
                            );
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
                        ImprovementPlacement.CanPlan(
                            support, playerID, runCache
                        );
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
    local recoveryOK, recovery = pcall(AMT_MC_M7_LoadRecovery);
    if not recoveryOK or recovery then
        local restored = AMT_MC_M7_RetryRecovery();
        Controls.ResultText:SetText(Locale.Lookup(restored
            and "LOC_AMT_MC_M7_RECOVERY_OK" or "LOC_AMT_MC_M7_RECOVERY_REQUIRED"));
        RefreshUndoButton(Game.GetLocalPlayer());
        return; -- the previous undo transaction belongs to a DIFFERENT action
    end

    local playerID = Game.GetLocalPlayer();
    local transaction = LoadLastPlan(playerID);
    local isMultiCity = transaction ~= nil
        and transaction.kind == "MULTICITY";
    if not transaction then
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_UNDO_NONE"));
        RefreshUndoButton(playerID);
        return;
    end
    if isMultiCity then
        local undone, status, removedCount, restoredCount = AMT_MC_M7_UndoTransaction(transaction);
        local key = undone and "LOC_AMT_MC_M7_UNDO_OK"
            or (status == "RECOVERY_REQUIRED" and "LOC_AMT_MC_M7_RECOVERY_REQUIRED"
                or (status == "UNDO_BLOCKED" and "LOC_AMT_MC_M7_UNDO_BLOCKED"
                    or "LOC_AMT_MC_M7_UNDO_FAILED"));
        Controls.ResultText:SetText(Locale.Lookup(key, removedCount, restoredCount));
        RefreshUndoButton(playerID);
        if undone then UI.PlaySound("Map_Pin_Remove"); end
        Log("M7 atomic undo status=" .. tostring(status));
        return;
    end

    -- Non-multicity transactions retain the inherited single-city path.
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
            isMultiCity and "LOC_AMT_MC_M7_UNDO_PARTIAL"
                or "LOC_AMT_UNDO_PARTIAL",
            removedAddedCount, restoredCount, #blockedRecords
        ));
    else
        SaveLastPlan(playerID, nil);
        Controls.ResultText:SetText(Locale.Lookup(
            isMultiCity and "LOC_AMT_MC_M7_UNDO_OK"
                or "LOC_AMT_UNDO_RESULT",
            removedAddedCount, restoredCount
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
    local recoveryOK, recovery = pcall(AMT_MC_M7_LoadRecovery);
    if not recoveryOK or recovery then
        Controls.ResultText:SetText(Locale.Lookup("LOC_AMT_MC_M7_RECOVERY_REQUIRED"));
        return;
    end
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
    -- A single saved city in the multi editor also uses this inherited result
    -- route. Release its UI session before the next explicit mode selection.
    HidePopup();
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
    -- M1 capability gate: the multi-city coordinator is never routed to
    -- while the bootstrap reports entryEnabled=false (ShouldRoutePreview
    -- always returns false in M1).  The original single-city path below,
    -- including the linked=false call, stays unchanged.
    if AMT_MultiCity and AMT_MultiCity.ShouldRoutePreview
        and AMT_MultiCity.ShouldRoutePreview(false) then

    end
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

-- ---------------------------------------------------------------------------
-- M2 planning-city editor integration (new r15 UI).
-- ---------------------------------------------------------------------------

function AMT_MC_Copy(value)
    return AMT_MultiCity.UIState.Copy(value);
end

function AMT_MC_IntentFromPlan(city, plan)
    local order = {};
    for index = 1, tonumber(plan and plan.slotCount) or 0 do
        if plan.slots and plan.slots[index] then
            table.insert(order, plan.slots[index]);
        end
    end
    for _, districtType in ipairs(
        plan and plan.mcDeferredOrder or {}
    ) do
        table.insert(order, districtType);
    end
    local selected = AMT_MC_Copy(plan and plan.selectedSubjects or {});
    local improvementSelections = AMT_MC_Copy(
        selected[MAP_PIN_TYPE_IMPROVEMENT] or {}
    );
    local recommendationEvidence = {};
    for _, evidence in ipairs(
        plan and plan.mcImprovementRecommendationEvidence or {}
    ) do
        local improvementTypes = {};
        for _, improvementType in ipairs(evidence.improvementTypes or {}) do
            if improvementSelections[improvementType] == true then
                table.insert(improvementTypes, improvementType);
            end
        end
        if #improvementTypes > 0 then
            table.insert(recommendationEvidence, {
                resourceType = evidence.resourceType,
                improvementTypes = improvementTypes,
            });
        end
    end
    return {
        futurePopulation = tonumber(plan and plan.populationBudget) or 1,
        specialtySlotCount = tonumber(plan and plan.slotCount) or 1,
        horizon = plan and plan.planningHorizon or "LONG_TERM",
        selectedSubjects = selected,
        specialtyOrder = order,
        yieldWeights = AMT_MC_Copy(plan and plan.yieldFocusStates or {}),
        prioritizeUnique = plan and plan.prioritizeUnique == true,
        preserveEnabled = plan and plan.enablePreserve == true,
        improvementSelections = improvementSelections,
        improvementRecommendationEvidence = recommendationEvidence,
        clearPolicy = {
            clearScope = "PARTICIPANTS",
            clearAutoPins = plan and plan.clearBeforePlan == true,
            clearManualPins = plan and plan.clearBeforePlan == true
                and plan.clearManualPins == true,
            overwriteAutoPins = plan and plan.overwriteAutoPins == true,
        },
    };
end

function AMT_MC_ApplyIntentToPlan(plan, intent)
    if not plan or not intent then return; end
    plan.populationBudget = tonumber(intent.futurePopulation)
        or plan.populationBudget;
    plan.slotCount = tonumber(intent.specialtySlotCount) or plan.slotCount;
    plan.slots = {};
    plan.mcDeferredOrder = nil;
    if m_MCMode then
        -- M6U: saved specialtyOrder entries beyond the visible slot count
        -- are kept as visible deferred rows instead of being lost.
        for index, districtType in ipairs(intent.specialtyOrder or {}) do
            if index <= (tonumber(plan.slotCount) or 0) then
                plan.slots[index] = districtType;
            else
                plan.mcDeferredOrder = plan.mcDeferredOrder or {};
                table.insert(plan.mcDeferredOrder, districtType);
            end
        end
    else
        for index, districtType in ipairs(intent.specialtyOrder or {}) do
            plan.slots[index] = districtType;
        end
    end
    plan.selectedSubjects = AMT_MC_Copy(intent.selectedSubjects or {});
    plan.selectedSubjects[MAP_PIN_TYPE_DISTRICT] =
        plan.selectedSubjects[MAP_PIN_TYPE_DISTRICT] or {};
    plan.selectedSubjects[MAP_PIN_TYPE_IMPROVEMENT] =
        plan.selectedSubjects[MAP_PIN_TYPE_IMPROVEMENT] or {};
    plan.selectedSubjects[MAP_PIN_TYPE_WONDER] =
        plan.selectedSubjects[MAP_PIN_TYPE_WONDER] or {};
    plan.planningHorizon = intent.horizon or "LONG_TERM";
    plan.yieldFocusStates = AMT_MC_Copy(intent.yieldWeights or {});
    plan.prioritizeUnique = intent.prioritizeUnique ~= false;
    plan.enablePreserve = intent.preserveEnabled == true;
    plan.mcImprovementRecommendationEvidence = AMT_MC_Copy(
        intent.improvementRecommendationEvidence or {}
    );
    local clearPolicy = intent.clearPolicy or {};
    plan.clearBeforePlan = clearPolicy.clearAutoPins == true;
    plan.clearManualPins = clearPolicy.clearManualPins == true;
    plan.overwriteAutoPins = clearPolicy.overwriteAutoPins == true;
end

function AMT_MC_SetAdvancedVisible(show)
    show = m_MCMode and show == true;
    if Controls.MCAdvancedPanel then
        Controls.MCAdvancedPanel:SetHide(not show);
    end
    local sharedControls = {
        Controls.YieldFocusLabel, Controls.YieldFocusButtons,
        Controls.UniqueDirectionCheck, Controls.PreservePlanningCheck,
    };
    for _, control in ipairs(sharedControls) do
        if control then control:SetHide(m_MCMode and not show); end
    end
    if m_MCMode then
        if Controls.YieldFocusLabel then
            Controls.YieldFocusLabel:SetOffsetX(274);
            Controls.YieldFocusLabel:SetOffsetY(248);
        end
        if Controls.YieldFocusButtons then
            Controls.YieldFocusButtons:SetOffsetX(274);
            Controls.YieldFocusButtons:SetOffsetY(272);
        end
        if Controls.UniqueDirectionCheck then
            Controls.UniqueDirectionCheck:SetOffsetX(42);
            Controls.UniqueDirectionCheck:SetOffsetY(256);
        end
        if Controls.PreservePlanningCheck then
            Controls.PreservePlanningCheck:SetOffsetX(42);
            Controls.PreservePlanningCheck:SetOffsetY(294);
        end
    else
        if Controls.YieldFocusLabel then
            Controls.YieldFocusLabel:SetOffsetX(24);
            Controls.YieldFocusLabel:SetOffsetY(78);
        end
        if Controls.YieldFocusButtons then
            Controls.YieldFocusButtons:SetOffsetX(24);
            Controls.YieldFocusButtons:SetOffsetY(101);
        end
        if Controls.UniqueDirectionCheck then
            Controls.UniqueDirectionCheck:SetOffsetX(24);
            Controls.UniqueDirectionCheck:SetOffsetY(79);
        end
        if Controls.PreservePlanningCheck then
            Controls.PreservePlanningCheck:SetOffsetX(24);
            Controls.PreservePlanningCheck:SetOffsetY(111);
        end
    end
end

function AMT_MC_SetSettingsPanelHidden(hidden)
    m_MCSettingsPanelHidden = hidden == true and m_MCMode and m_IsOpen;
    if Controls.SettingsBlocker then
        Controls.SettingsBlocker:SetHide(m_MCSettingsPanelHidden);
    end
    if Controls.MCSettingsRestoreButton then
        Controls.MCSettingsRestoreButton:SetHide(
            not m_MCSettingsPanelHidden
        );
    end
    if Controls.MCSettingsHideButton then
        Controls.MCSettingsHideButton:SetHide(
            m_MCSettingsPanelHidden or not m_MCMode
        );
    end
    Log(m_MCSettingsPanelHidden and "Settings panel hidden for map review."
        or "Settings panel restored.");
end

function AMT_MC_SetChromeVisible(visible)
    for _, control in ipairs({
        Controls.MCQuickSetupLabel, Controls.MCQuickSetupPull,
        Controls.MCStepBar, Controls.MCCityCards,
        Controls.MCPreviousCityButton, Controls.MCNextCityButton,
        Controls.MCSettingsStatus, Controls.MCAdvancedToggleButton,
        Controls.MCSettingsHideButton,
        Controls.MCClearSettingsButton, Controls.MCCloseButton,
        Controls.MCPrimaryActionButton,
    }) do
        if control then control:SetHide(not visible); end
    end
    -- Legacy multi-city buttons and the old banner remain available to the
    -- Lua context but are never shown by the refreshed UI.
    for _, control in ipairs({
        Controls.MCCityHeader, Controls.MCCityPosition,
        Controls.MCCityNavigator, Controls.MCCityType,
        Controls.MCSaveSettingsButton, Controls.MCSolveButton,
    }) do
        if control then control:SetHide(true); end
    end
    if Controls.CityName then Controls.CityName:SetHide(visible); end
    AMT_MC_SetAdvancedVisible(false);
    for _, control in ipairs({
        Controls.UndoButton, Controls.OkButton, Controls.CancelButton,
    }) do
        if control then control:SetHide(visible); end
    end
    if Controls.OneClickButton then
        Controls.OneClickButton:SetHide(visible);
        Controls.OneClickButton:SetOffsetX(320);
        Controls.OneClickButton:SetSizeX(180);
    end
    if Controls.AMTBackground then
        Controls.AMTBackground:SetSizeY(visible and 790 or 720);
    end
    local verticalLayout = {
        { Controls.CategoryTabs, 148, 204 },
        { Controls.CategoryHint, 195, 251 },
        { Controls.RuleBanner, 233, 289 },
        { Controls.CategoryActions, 273, 329 },
        { Controls.ItemScroll, 312, 368 },
        { Controls.SelectionHint, 544, 600 },
        { Controls.SpecialtySlotsLabel, 154, 210 },
        { Controls.SpecialtySlotsHint, 181, 237 },
        { Controls.PriorityScroll, 253, 309 },
        { Controls.SpecialtySlotControls, 536, 592 },
        { Controls.PopulationControls, 574, 630 },
        { Controls.PopulationWarning, 605, 661 },
    };
    for _, item in ipairs(verticalLayout) do
        if item[1] then item[1]:SetOffsetY(visible and item[3] or item[2]); end
    end
end

function AMT_MC_SetPhase(phase)
    m_MCUIPhase = math.max(1, math.min(4, tonumber(phase) or 1));
    local keys = {
        "LOC_AMT_MC_UI_STEP_SETTINGS", "LOC_AMT_MC_UI_STEP_SCOPE",
        "LOC_AMT_MC_UI_STEP_COMPARE", "LOC_AMT_MC_UI_STEP_APPLY",
    };
    for index, key in ipairs(keys) do
        local control = Controls["MCStep" .. tostring(index)];
        if control then
            local marker = index < m_MCUIPhase and "✓ "
                or (index == m_MCUIPhase and "● " or "");
            control:SetText(marker .. Locale.Lookup(key));
        end
    end
end

function AMT_MC_CardStatusKey(status)
    local keys = {
        UNSET = "LOC_AMT_MC_UI_CARD_UNSET",
        DIRTY = "LOC_AMT_MC_UI_CARD_DIRTY",
        SAVED = "LOC_AMT_MC_UI_CARD_SAVED",
        REOPTIMIZE = "LOC_AMT_MC_UI_CARD_REOPTIMIZE",
        REVIEW = "LOC_AMT_MC_UI_CARD_REVIEW",
    };
    return keys[status] or keys.UNSET;
end

function AMT_MC_RefreshCityCards()
    if not m_MCSession then return; end
    local ordered = m_MCSession.orderedParticipantIDs or {};
    local activeIndex = tonumber(m_MCSession.activeIndex) or 1;
    local pageStart = math.floor((activeIndex - 1) / 4) * 4 + 1;
    local pageCount = math.max(0, math.min(4, #ordered - pageStart + 1));
    if Controls.MCCityCards and pageCount > 0 then
        local pageWidth = pageCount * 184 + math.max(0, pageCount - 1) * 6;
        Controls.MCCityCards:SetOffsetX(math.floor((930 - pageWidth) / 2));
    end
    m_MCUICardParticipantIDs = {};
    for slot = 1, 4 do
        local participantID = ordered[pageStart + slot - 1];
        local button = Controls["MCCityCard" .. tostring(slot)];
        local name = Controls["MCCityCard" .. tostring(slot) .. "Name"];
        local status = Controls["MCCityCard" .. tostring(slot) .. "Status"];
        m_MCUICardParticipantIDs[slot] = participantID;
        if button then
            button:SetHide(participantID == nil);
            button:SetDisabled(participantID ~= nil
                and participantID == AMT_MultiCity.UIState.GetActiveID(
                    m_MCSession));
        end
        if participantID then
            local participant = m_MCSession.participants[participantID];
            local profile = m_MCSession.profiles[participantID];
            local participantName = tostring(participant and participant.name
                or "?");
            if name then name:SetText(participantName); end
            if button then button:SetToolTipString(participantName); end
            if status then status:SetText(Locale.Lookup(AMT_MC_CardStatusKey(
                AMT_MultiCity.UIState.GetStatus(profile)))); end
        end
    end
    if Controls.MCPreviousCityButton then
        Controls.MCPreviousCityButton:SetHide(#ordered <= 4);
    end
    if Controls.MCNextCityButton then
        Controls.MCNextCityButton:SetHide(#ordered <= 4);
    end
end

function AMT_MC_SelectCityCard(slot)
    local participantID = m_MCUICardParticipantIDs[slot];
    if not participantID or not m_MCSession then return; end
    AMT_MC_MarkCurrentDraftChanged();
    AMT_MultiCity.UIState.SetActiveByID(m_MCSession, participantID);
    RepopulatePopup();
    AMT_MC_FocusCity(GetSelectedCity());
end

function AMT_MC_RefreshPrimaryAction()
    if not Controls.MCPrimaryActionButton or not m_MCSession then return; end
    local dirty = AMT_MultiCity.UIState.HasUnsavedDrafts(m_MCSession);
    local hasAny = false;
    for _, participantID in ipairs(m_MCSession.orderedParticipantIDs or {}) do
        local profile = m_MCSession.profiles[participantID];
        local intent = profile and (profile.draftIntent or profile.savedIntent);
        if intent and AMT_MC_HasSelectedSubject(intent) then
            hasAny = true;
            break;
        end
    end
    Controls.MCPrimaryActionButton:SetText(Locale.Lookup(dirty
        and "LOC_AMT_MC_UI_SAVE_ALL_CONTINUE"
        or "LOC_AMT_MC_UI_CONFIRM_SCOPE"));
    Controls.MCPrimaryActionButton:SetDisabled(not hasAny);
end

function AMT_MC_PersistSettings()
    if not m_MCSession then return; end
    SaveConfigTable(
        PlayerConfigurations[Game.GetLocalPlayer()],
        AMT_MC_CONFIG_KEY_SETTINGS,
        AMT_MultiCity.UIState.Export(m_MCSession)
    );
end

function AMT_MC_StatusKey(status)
    local keys = {
        UNSET = "LOC_AMT_MC_STATUS_UNSET",
        DIRTY = "LOC_AMT_MC_STATUS_DIRTY",
        SAVED = "LOC_AMT_MC_STATUS_SAVED",
        REOPTIMIZE = "LOC_AMT_MC_STATUS_REOPTIMIZE",
        REVIEW = "LOC_AMT_MC_STATUS_REVIEW",
    };
    return keys[status] or keys.UNSET;
end

AMT_MC_RefreshHeader = function()
    if not m_MCMode or not m_MCSession then return; end
    local participantID = AMT_MultiCity.UIState.GetActiveID(m_MCSession);
    local participant = participantID
        and m_MCSession.participants[participantID] or nil;
    local profile = participantID and m_MCSession.profiles[participantID] or nil;
    if not participant or not profile then return; end
    Controls.CityName:SetText(tostring(participant.name or "?"));
    Controls.MCCityType:SetText(Locale.Lookup(
        participant.participantKind == "REAL_CITY"
            and "LOC_AMT_MC_REAL_CITY" or "LOC_AMT_MC_FUTURE_CITY"
    ));
    Controls.MCCityPosition:SetText(tostring(m_MCSession.activeIndex)
        .. " / " .. tostring(#m_MCSession.orderedParticipantIDs));
    local cityStatus = AMT_MultiCity.UIState.GetStatus(profile);
    local sharedDirty = AMT_MultiCity.UIState.HasUnsavedSharedDrafts
        and AMT_MultiCity.UIState.HasUnsavedSharedDrafts(m_MCSession)
        or false;
    local statusKey = AMT_MC_StatusKey(cityStatus);
    if cityStatus == AMT_MultiCity.UIState.STATUS_DIRTY
        and sharedDirty then
        statusKey = "LOC_AMT_MC_STATUS_BOTH_DIRTY";
    elseif sharedDirty then
        statusKey = "LOC_AMT_MC_STATUS_SHARED_DIRTY";
    end
    Controls.MCSettingsStatus:SetText(Locale.Lookup(statusKey));
    AMT_MC_SetPhase(1);
    AMT_MC_RefreshCityCards();
    AMT_MC_RefreshPrimaryAction();
end

AMT_MC_MarkCurrentDraftChanged = function()
    if not m_MCMode or not m_MCSession or m_MCSuppressDraftTracking then
        return;
    end
    local participantID = AMT_MultiCity.UIState.GetActiveID(m_MCSession);
    local city = GetSelectedCity();
    local plan = GetCitySpecialtyPlan(city);
    if participantID and city and plan then
        local intent = AMT_MC_IntentFromPlan(city, plan);
        local profile = m_MCSession.profiles[participantID];
        local changed = profile == nil
            or not AMT_MultiCity.UIState.Equal(
                intent, profile.draftIntent
            );
        AMT_MultiCity.UIState.SetDraft(
            m_MCSession, participantID, intent, changed
        );
        AMT_MC_RefreshHeader();
    end
end

function AMT_MC_BeginSession()
    local playerID = Game.GetLocalPlayer();
    local player = Players[playerID];
    local cityManager = player and player:GetCities() or nil;
    local participants = {};
    if cityManager then
        for _, city in cityManager:Members() do
            table.insert(participants, {
                participantKind = "REAL_CITY",
                cityID = city:GetID(),
                name = Locale.Lookup(city:GetName()),
                anchorPlotIndex = -1,
            });
        end
    end
    local stored = LoadConfigTable(
        PlayerConfigurations[playerID], AMT_MC_CONFIG_KEY_SETTINGS
    );
    m_MCSession = AMT_MultiCity.UIState.NewSession(
        playerID, participants, stored
    );
    AMT_MC_M6U_MigrateLegacySelections();
    local discovered = AMT_MC_M6U_SubjectList();
    local discoveredKeys = {};
    for _, subject in ipairs(discovered) do
        table.insert(discoveredKeys, subject.subjectKey);
    end

    local selected = UI.GetHeadSelectedCity();
    if selected and selected:GetOwner() == playerID then
        AMT_MultiCity.UIState.SetActiveByID(
            m_MCSession,
            AMT_MultiCity.UIState.RealCityParticipantID(
                playerID, selected:GetID()
            )
        );
    end
    for slot = 1, 4 do
        local card = Controls["MCCityCard" .. tostring(slot)];
        if card then
            local selectedSlot = slot;
            card:RegisterCallback(Mouse.eLClick, function()
                AMT_MC_SelectCityCard(selectedSlot);
            end);
        end
    end
    if Controls.MCAdvancedToggleButton then
        Controls.MCAdvancedToggleButton:RegisterCallback(
            Mouse.eLClick, function()
                AMT_MC_SetAdvancedVisible(
                    Controls.MCAdvancedPanel:IsHidden()
                );
            end
        );
    end
    if Controls.MCAdvancedCloseButton then
        Controls.MCAdvancedCloseButton:RegisterCallback(
            Mouse.eLClick, function()
                AMT_MC_SetAdvancedVisible(false);
            end
        );
    end
    for participantID, profile in pairs(m_MCSession.profiles) do
        local participant = m_MCSession.participants[participantID];
        local city = cityManager and cityManager:FindID(participant.cityID) or nil;
        local plan = city and GetCitySpecialtyPlan(city) or nil;
        if plan and profile.savedIntent then
            AMT_MC_ApplyIntentToPlan(plan, profile.savedIntent);
        end
        if plan and not profile.draftIntent then
            profile.draftIntent = AMT_MC_IntentFromPlan(city, plan);
        end
    end
    m_MCPendingScope = nil;
    m_MCAutoSelectUndo = {};
    m_MCUIQuickUndo = nil;
    m_MCUIQuickTemplateKey = nil;
    m_MCUIQuickCityCount = 0;
    AMT_MC_SetChromeVisible(true);
    -- Populate after SetChromeVisible so a missing quick-setup module wins
    -- and keeps both label and pull-down hidden.
    AMT_MC_PopulateQuickSetupPull();
end

function AMT_MC_ClearNavHighlight()
    if m_MCNavHighlightActive then
        m_PreviewMapIconIM:ResetInstances();
        m_MCNavHighlightActive = false;
    end
end

function AMT_MC_NavHighlightUpdate(deltaTime)
    m_MCNavHighlightRemaining = m_MCNavHighlightRemaining
        - (tonumber(deltaTime) or 0.016);
    if m_MCNavHighlightRemaining <= 0 then
        AMT_MC_ClearNavHighlight();
        ContextPtr:ClearUpdate();
    end
end

function AMT_MC_FocusCity(city)
    if not city then return; end
    UI.LookAtPlotScreenPosition(city:GetX(), city:GetY(), 0.5, 0.5);
    m_PreviewMapIconIM:ResetInstances();
    local instance = m_PreviewMapIconIM:GetInstance();
    instance.SubjectIcon:SetIcon("ICON_DISTRICT_CITY_CENTER");
    instance.YieldText:SetText("");
    local x, y, z = UI.GridToWorld(city:GetX(), city:GetY());
    instance.Anchor:SetWorldPositionVal(x, y, (z or 0) + 12);
    m_MCNavHighlightActive = true;
    m_MCNavHighlightRemaining = 1.2;
    ContextPtr:SetUpdate(AMT_MC_NavHighlightUpdate);
end

function AMT_MC_CycleCity(delta)
    if not m_MCSession then return; end
    AMT_MC_MarkCurrentDraftChanged();
    AMT_MultiCity.UIState.Cycle(m_MCSession, delta);
    RepopulatePopup();
    AMT_MC_FocusCity(GetSelectedCity());
end

function AMT_MC_HasSelectedSubject(intent)
    for _, selected in pairs(intent.selectedSubjects or {}) do
        for _, value in pairs(selected) do
            if value == true then return true; end
        end
    end
    return #(intent.specialtyOrder or {}) > 0;
end

function AMT_MC_SaveParticipant(participantID)
    local participant = m_MCSession and m_MCSession.participants[participantID];
    local player = Players[Game.GetLocalPlayer()];
    local city = participant and player:GetCities():FindID(participant.cityID);
    local plan = city and GetCitySpecialtyPlan(city) or nil;
    if not plan then return false, "city unavailable"; end
    local intent = AMT_MC_IntentFromPlan(city, plan);
    if not AMT_MC_HasSelectedSubject(intent) then
        return false, Locale.Lookup("LOC_AMT_NO_SUBJECTS");
    end
    local normalizedPlan = AMT_MC_Copy(plan);
    NormalizeCitySpecialtyPlan(city, normalizedPlan);
    local resolved = AMT_MC_IntentFromPlan(city, normalizedPlan);
    local ok, revisionOrReason = AMT_MultiCity.UIState.Save(
        m_MCSession, participantID, intent, resolved,
        AMT_MultiCity.Contract.Hash(intent)
    );
    if not ok then
        return false, revisionOrReason == "real city limit"
            and Locale.Lookup("LOC_AMT_MC_SAVE_LIMIT")
            or tostring(revisionOrReason);
    end
    return true, revisionOrReason;
end

function AMT_MC_SaveCurrent()
    local participantID = AMT_MultiCity.UIState.GetActiveID(m_MCSession);
    AMT_MC_MarkCurrentDraftChanged();
    -- Shared validation happens before the city save so a bad unique lock
    -- can never leave the city revision committed alone.
    local locksOK, lockSubjects = AMT_MC_M6U_ValidateDraftLocks();
    if not locksOK then
        if m_ResultText then
            m_ResultText:SetText(Locale.Lookup(
                "LOC_AMT_MC_UNIQUE_LOCK_INVALID_SAVE",
                AMT_MC_M6U_SubjectNames(lockSubjects)
            ));
        end
        return;
    end
    local ok, result = AMT_MC_SaveParticipant(participantID);
    if not ok then
        if m_ResultText then
            m_ResultText:SetText(tostring(result));
        end
        AMT_MC_RefreshHeader();
        return;
    end
    -- One save click commits the current city draft and the involved shared
    -- unique-district drafts, then persists both in the same settings write.
    local sharedSaved = AMT_MC_M6U_SaveSharedDrafts();
    AMT_MC_PersistSettings();
    if m_ResultText then
        m_ResultText:SetText(Locale.Lookup(
            "LOC_AMT_MC_SAVE_OK_WITH_SHARED", result, sharedSaved
        ));
    end
    AMT_MC_RefreshHeader();
    if m_CurrentCategory == MAP_PIN_TYPE_DISTRICT then
        RefreshPlannerItemGrid();
    end
end

function AMT_MC_SaveAllAndContinue()
    if not m_MCSession then return; end
    AMT_MC_MarkCurrentDraftChanged();
    local locksOK, lockSubjects = AMT_MC_M6U_ValidateDraftLocks();
    if not locksOK then
        if m_ResultText then
            m_ResultText:SetText(Locale.Lookup(
                "LOC_AMT_MC_UNIQUE_LOCK_INVALID_SAVE",
                AMT_MC_M6U_SubjectNames(lockSubjects)
            ));
        end
        return;
    end
    local savedCount = 0;
    for _, participantID in ipairs(m_MCSession.orderedParticipantIDs or {}) do
        local profile = m_MCSession.profiles[participantID];
        local intent = profile and (profile.draftIntent or profile.savedIntent);
        local status = AMT_MultiCity.UIState.GetStatus(profile);
        if intent and AMT_MC_HasSelectedSubject(intent)
            and status ~= AMT_MultiCity.UIState.STATUS_SAVED then
            local ok, reason = AMT_MC_SaveParticipant(participantID);
            if not ok then
                if m_ResultText then m_ResultText:SetText(tostring(reason)); end
                AMT_MC_RefreshHeader();
                return;
            end
            savedCount = savedCount + 1;
        end
    end
    AMT_MC_M6U_SaveSharedDrafts();
    AMT_MC_PersistSettings();
    AMT_MC_RefreshHeader();
    if m_ResultText and savedCount > 0 then
        m_ResultText:SetText(Locale.Lookup(
            "LOC_AMT_MC_UI_SAVE_ALL_OK", savedCount
        ));
    end
    AMT_MC_OpenScope();
end

function AMT_MC_HandlePrimaryAction()
    if not m_MCSession then return; end
    if AMT_MultiCity.UIState.HasUnsavedDrafts(m_MCSession) then
        AMT_MC_SaveAllAndContinue();
    else
        AMT_MC_OpenScope();
    end
end

function AMT_MC_M6U_DoClearCurrent(participantID)
    local city = GetSelectedCity();
    local planKey = GetCityPlanKey(city);
    if planKey then m_CitySpecialtyPlans[planKey] = nil; end
    local defaultPlan = GetCitySpecialtyPlan(city);
    AMT_MultiCity.UIState.Clear(
        m_MCSession, participantID,
        AMT_MC_IntentFromPlan(city, defaultPlan)
    );
    m_MCAutoSelectUndo[participantID] = nil;
    -- Clearing a city cancels every player-unique lock on it; the confirm
    -- overlay said so explicitly (UNIQUE_DISTRICT_UI_PLAN section 6.5).
    AMT_MC_M6U_CancelLocksOnCity(city and city:GetID());
    AMT_MC_PersistSettings();
    RepopulatePopup();
    m_ResultText:SetText(Locale.Lookup("LOC_AMT_MC_CLEAR_OK"));
end

function AMT_MC_ClearCurrent()
    if not m_MCSession then return; end
    local participantID = AMT_MultiCity.UIState.GetActiveID(m_MCSession);
    local city = GetSelectedCity();
    local locks = AMT_MC_M6U_LocksOnCity(city and city:GetID());
    if #locks > 0 then
        AMT_MC_M6U.PendingClear = participantID;
        Controls.MCUniqueClearBody:SetText(Locale.Lookup(
            "LOC_AMT_MC_CLEAR_UNIQUE_CONFIRM_BODY",
            AMT_MC_M6U_SubjectNames(locks)
        ));
        Controls.MCUniqueClearOverlay:SetHide(false);
        return;
    end
    AMT_MC_M6U_DoClearCurrent(participantID);
end

-- Scans the visible bonus/strategic resources in one city's range and
-- enables every currently unlocked improvement option that can develop them.
-- Returns resourceCount, addedCount.  The caller owns the undo snapshot,
-- draft marking and UI refresh so the same scan can be reused for quick
-- setup across every drafted city.
function AMT_MC_SelectImprovementsForCity(city)
    local started = os and os.clock and os.clock() or 0;
    local plan = GetCitySpecialtyPlan(city);
    if not city or not plan then return 0, 0; end
    local selected = plan.selectedSubjects[MAP_PIN_TYPE_IMPROVEMENT];
    local playerID = Game.GetLocalPlayer();
    local resourceCount, addedCount = 0, 0;
    local resourcesSeen = {};
    local recommendationsByResource = {};
    for _, plot in ipairs(GetCityRangePlots(city, nil)) do
        local owner = plot:GetOwner();
        if owner == -1 or owner == playerID then
            local resource = ImprovementPlacement.GetActualVisibleResource(
                plot, playerID
            );
            if resource and (resource.ResourceClassType == "RESOURCECLASS_BONUS"
                or resource.ResourceClassType == "RESOURCECLASS_STRATEGIC") then
                local resourceType = resource.ResourceType;
                if not resourcesSeen[resourceType] then
                    resourcesSeen[resourceType] = true;
                    resourceCount = resourceCount + 1;
                end
                for _, option in ipairs(
                    m_PlannerOptions[MAP_PIN_TYPE_IMPROVEMENT] or {}
                ) do
                    local rule = ImprovementPlacement.GetRules(
                        option.subjectKey
                    ).resources[resourceType];
                    if rule
                        and ImprovementPlacement.IsRuleUnlocked(rule, playerID)
                        and (m_PlanningHorizon ~= "CURRENT"
                            or IsSubjectCurrentlyUnlocked(option, playerID)) then
                        recommendationsByResource[resourceType] =
                            recommendationsByResource[resourceType] or {};
                        recommendationsByResource[resourceType][
                            option.subjectKey
                        ] = true;
                        if not selected[option.subjectKey] then
                            selected[option.subjectKey] = true;
                            addedCount = addedCount + 1;
                        end
                    end
                end
            end
        end
    end
    if addedCount > 0 then
        local evidence = {};
        local resourceTypes = {};
        for resourceType in pairs(recommendationsByResource) do
            table.insert(resourceTypes, resourceType);
        end
        table.sort(resourceTypes);
        for _, resourceType in ipairs(resourceTypes) do
            local improvementTypes = {};
            for improvementType in pairs(
                recommendationsByResource[resourceType]
            ) do
                table.insert(improvementTypes, improvementType);
            end
            table.sort(improvementTypes);
            table.insert(evidence, {
                resourceType = resourceType,
                improvementTypes = improvementTypes,
            });
        end
        plan.mcImprovementRecommendationEvidence = evidence;
    end
    local elapsed = (os and os.clock and os.clock() or started) - started;
    if elapsed > 0.2 then

    end
    return resourceCount, addedCount;
end

function AMT_MC_AutoSelectImprovements()
    local participantID = AMT_MultiCity.UIState.GetActiveID(m_MCSession);
    local city = GetSelectedCity();
    local plan = GetCitySpecialtyPlan(city);
    if not city or not plan then return; end
    local selected = plan.selectedSubjects[MAP_PIN_TYPE_IMPROVEMENT];
    m_MCAutoSelectUndo[participantID] = {
        selections = AMT_MC_Copy(selected),
        evidence = AMT_MC_Copy(
            plan.mcImprovementRecommendationEvidence or {}
        ),
    };
    local resourceCount, addedCount =
        AMT_MC_SelectImprovementsForCity(city);
    if addedCount > 0 then
        AMT_MC_MarkCurrentDraftChanged();
        RefreshPlannerItemGrid();
    else
        m_MCAutoSelectUndo[participantID] = nil;
    end
    RefreshCategoryTabs();
    m_ResultText:SetText(Locale.Lookup(
        "LOC_AMT_MC_AUTO_SELECT_RESULT", resourceCount, addedCount
    ));
end

function AMT_MC_UndoAutoSelect()
    local participantID = AMT_MultiCity.UIState.GetActiveID(m_MCSession);
    local previous = m_MCAutoSelectUndo[participantID];
    local plan = GetCitySpecialtyPlan(GetSelectedCity());
    if not previous or not plan then return; end
    plan.selectedSubjects[MAP_PIN_TYPE_IMPROVEMENT] = AMT_MC_Copy(
        previous.selections or {}
    );
    plan.mcImprovementRecommendationEvidence = AMT_MC_Copy(
        previous.evidence or {}
    );
    m_SelectedSubjects = plan.selectedSubjects;
    m_MCAutoSelectUndo[participantID] = nil;
    AMT_MC_MarkCurrentDraftChanged();
    RefreshPlannerItemGrid();
    m_ResultText:SetText(Locale.Lookup("LOC_AMT_MC_AUTO_SELECT_UNDONE"));
end

-- ---------------------------------------------------------------------------
-- One-click quick setup (beginner helper).  Anchors on the selected city and
-- drafts the linked city cluster; nothing is saved automatically.
-- ---------------------------------------------------------------------------
function AMT_MC_QuickSetupAvailableDistricts()
    local available = {};
    local options = m_PlannerOptions[MAP_PIN_TYPE_DISTRICT] or {};
    if #options > 0 then
        for _, option in ipairs(options) do
            if option and option.subjectKey then
                available[option.subjectKey] = true;
            end
        end
    elseif GameInfo and GameInfo.Districts then
        for row in GameInfo.Districts() do
            if row and row.DistrictType then
                available[row.DistrictType] = true;
            end
        end
    end
    return available;
end

function AMT_MC_QuickSetupCityHasCoast(city)
    if not city or type(city.IsCoastal) ~= "function" then
        return false;
    end
    local ok, value = pcall(function()
        return city:IsCoastal();
    end);
    return ok and value == true;
end

function AMT_MC_QuickSetupFindParticipant(cityID)
    if not m_MCSession or not m_MCSession.participants then
        return nil;
    end
    for participantID, participant in pairs(m_MCSession.participants) do
        if participant and participant.cityID == cityID then
            return participantID;
        end
    end
    return nil;
end

function AMT_MC_QuickSetupApplyDraft(city, draft)
    if not city or not draft then
        return false;
    end
    local plan = GetCitySpecialtyPlan(city);
    if not plan then
        return false;
    end
    AMT_MC_ApplyIntentToPlan(plan, draft);
    local participantID = AMT_MC_QuickSetupFindParticipant(city:GetID());
    if participantID then
        local intent = AMT_MC_IntentFromPlan(city, plan);
        local profile = m_MCSession.profiles[participantID];
        local changed = profile == nil
            or not AMT_MultiCity.UIState.Equal(intent, profile.draftIntent);
        AMT_MultiCity.UIState.SetDraft(
            m_MCSession, participantID, intent, changed
        );
    end
    return true;
end

function AMT_MC_ApplyQuickSetup(templateKey)
    local quick = AMT_MultiCity and AMT_MultiCity.QuickSetup or nil;
    if not quick or type(quick.BuildCityDraft) ~= "function" then
        if m_ResultText then
            m_ResultText:SetText(Locale.Lookup(
                "LOC_AMT_MC_QUICK_SETUP_UNAVAILABLE"
            ));
        end
        return;
    end
    local primary = GetSelectedCity();
    if not primary then
        if m_ResultText then
            m_ResultText:SetText(Locale.Lookup(
                "LOC_AMT_MC_QUICK_SETUP_NO_CITY"
            ));
        end
        return;
    end
    -- Preserve the state from before the first beginner template.  Changing
    -- templates always starts from that same state and can be undone.
    if m_MCUIQuickUndo == nil then
        m_MCUIQuickUndo = {
            cityPlans = AMT_MC_Copy(m_CitySpecialtyPlans),
            profiles = AMT_MC_Copy(m_MCSession.profiles),
            uniqueDraft = AMT_MC_Copy(m_MCSession.uniqueDistrictDraft or {}),
            autoSelectUndo = AMT_MC_Copy(m_MCAutoSelectUndo),
        };
    else
        m_CitySpecialtyPlans = AMT_MC_Copy(m_MCUIQuickUndo.cityPlans);
        m_MCSession.profiles = AMT_MC_Copy(m_MCUIQuickUndo.profiles);
        m_MCSession.uniqueDistrictDraft = AMT_MC_Copy(
            m_MCUIQuickUndo.uniqueDraft
        );
        m_MCAutoSelectUndo = AMT_MC_Copy(m_MCUIQuickUndo.autoSelectUndo);
    end
    local cities = GetPlanningCities(primary, true) or {};
    if #cities == 0 then
        table.insert(cities, primary);
    end
    local available = AMT_MC_QuickSetupAvailableDistricts();
    local primaryDraft = quick.BuildCityDraft(
        templateKey, nil,
        AMT_MC_QuickSetupCityHasCoast(primary), available
    );
    AMT_MC_QuickSetupApplyDraft(primary, primaryDraft);
    -- Beginner templates anchor the Government Plaza on the primary city.
    -- It is a player-unique district, so it is drafted through the shared
    -- M6U lock instead of the ordinary per-city district order.
    local uniqueError = nil;
    if primaryDraft.governmentPlazaLockedToPrimary
        and AMT_MultiCity and AMT_MultiCity.UniqueDistrict
        and AMT_MC_M6U_IsSupported("DISTRICT_GOVERNMENT") then
        local uniqueOK, uniqueReason = AMT_MC_M6U_SetMode(
            "DISTRICT_GOVERNMENT",
            AMT_MultiCity.UniqueDistrict.MODE_LOCKED_CITY,
            primary:GetID()
        );
        if uniqueOK then
            -- The template fills the first three specialty slots, so the
            -- lock lands in the fourth slot.  Promote the Government Plaza
            -- to slot one: the beginner setup is meant to anchor the
            -- cluster around it, and the solver explores lower slot indexes
            -- first.
            local plan = GetCitySpecialtyPlan(primary);
            if plan then
                local subjectKey = "DISTRICT_GOVERNMENT";
                local slotCount = tonumber(plan.slotCount) or 1;
                local ordered, seen = { subjectKey }, { [subjectKey] = true };
                for index = 1, slotCount do
                    local districtType = plan.slots
                        and plan.slots[index] or nil;
                    if districtType and not seen[districtType] then
                        seen[districtType] = true;
                        table.insert(ordered, districtType);
                    end
                end
                for _, districtType in ipairs(
                    plan.mcDeferredOrder or {}
                ) do
                    if districtType and not seen[districtType] then
                        seen[districtType] = true;
                        table.insert(ordered, districtType);
                    end
                end
                local locked = GetLockedSpecialtyDistricts(primary);
                plan.slots = {};
                plan.mcDeferredOrder = {};
                local nextIndex = #locked + 1;
                for _, districtType in ipairs(ordered) do
                    if nextIndex <= slotCount then
                        plan.slots[nextIndex] = districtType;
                        nextIndex = nextIndex + 1;
                    else
                        table.insert(plan.mcDeferredOrder, districtType);
                    end
                end
            end
        else
            uniqueError = tostring(uniqueReason);
        end
    end
    local flags = {};
    for index = 2, #cities do
        table.insert(flags, {
            hasCoast = AMT_MC_QuickSetupCityHasCoast(cities[index]),
            available = available,
        });
    end
    local linkedDrafts = quick.BuildClusterDrafts(templateKey, flags);
    for index = 1, #linkedDrafts do
        AMT_MC_QuickSetupApplyDraft(cities[index + 1], linkedDrafts[index]);
    end
    -- Quick setup also runs the visible-resource improvement auto-select for
    -- every drafted city, with one undo snapshot per participant so the
    -- existing per-city undo button keeps working.
    local totalResources, totalAdded = 0, 0;
    for _, city in ipairs(cities) do
        local plan = GetCitySpecialtyPlan(city);
        if plan then
            local participantID = AMT_MC_QuickSetupFindParticipant(
                city:GetID()
            );
            local previousSelections = AMT_MC_Copy(
                plan.selectedSubjects[MAP_PIN_TYPE_IMPROVEMENT]
            );
            local previousEvidence = AMT_MC_Copy(
                plan.mcImprovementRecommendationEvidence or {}
            );
            local resourceCount, addedCount =
                AMT_MC_SelectImprovementsForCity(city);
            totalResources = totalResources + resourceCount;
            totalAdded = totalAdded + addedCount;
            if participantID and addedCount > 0 then
                m_MCAutoSelectUndo[participantID] = {
                    selections = previousSelections,
                    evidence = previousEvidence,
                };
            end
        end
    end
    -- Re-sync every drafted profile after the Government Plaza promotion and
    -- improvement auto-select.  Switching cities must never reload a
    -- pre-auto-select intent and silently drop the new selections/order.
    for _, city in ipairs(cities) do
        local participantID = AMT_MC_QuickSetupFindParticipant(
            city:GetID()
        );
        if participantID then
            local plan = GetCitySpecialtyPlan(city);
            local intent = AMT_MC_IntentFromPlan(city, plan);
            local profile = m_MCSession.profiles[participantID];
            local changed = profile == nil
                or not AMT_MultiCity.UIState.Equal(
                    intent, profile.draftIntent
                );
            AMT_MultiCity.UIState.SetDraft(
                m_MCSession, participantID, intent, changed
            );
        end
    end
    AMT_MC_MarkCurrentDraftChanged();
    m_MCUIQuickTemplateKey = templateKey;
    m_MCUIQuickCityCount = #cities;
    -- The draft application replaced plan.selectedSubjects with a new table;
    -- re-anchor the UI state to the primary plan so the visible item grid,
    -- horizon and yield-focus globals reflect the freshly drafted settings.
    ActivateCityPlannerState(primary);
    AMT_MC_RefreshHeader();
    RefreshPlannerItemGrid();
    RefreshCategoryTabs();
    AMT_MC_PopulateQuickSetupPull();
    if m_ResultText then
        if uniqueError then
            m_ResultText:SetText(uniqueError);
        elseif totalAdded > 0 then
            m_ResultText:SetText(Locale.Lookup(
                "LOC_AMT_MC_QUICK_SETUP_DONE_FULL",
                #cities, totalResources, totalAdded
            ));
        else
            m_ResultText:SetText(Locale.Lookup(
                "LOC_AMT_MC_QUICK_SETUP_DONE", #cities
            ));
        end
    end

end

function AMT_MC_CancelQuickSetup()
    if not m_MCSession then return; end
    local restored = m_MCUIQuickUndo ~= nil;
    if restored then
        m_CitySpecialtyPlans = AMT_MC_Copy(m_MCUIQuickUndo.cityPlans);
        m_MCSession.profiles = AMT_MC_Copy(m_MCUIQuickUndo.profiles);
        m_MCSession.uniqueDistrictDraft = AMT_MC_Copy(
            m_MCUIQuickUndo.uniqueDraft
        );
        m_MCAutoSelectUndo = AMT_MC_Copy(m_MCUIQuickUndo.autoSelectUndo);
    end
    m_MCUIQuickUndo = nil;
    m_MCUIQuickTemplateKey = nil;
    m_MCUIQuickCityCount = 0;
    RepopulatePopup();
    AMT_MC_RefreshQuickSetupButton();
    if m_ResultText and restored then
        m_ResultText:SetText(Locale.Lookup("LOC_AMT_MC_UI_QUICK_CANCELLED"));
    end
end

function AMT_MC_QuickTemplateLocKey(templateKey)
    local keys = {
        DEFAULT = "LOC_AMT_MC_QUICK_TEMPLATE_DEFAULT",
        SCIENCE = "LOC_AMT_MC_QUICK_TEMPLATE_SCIENCE",
        CULTURE = "LOC_AMT_MC_QUICK_TEMPLATE_CULTURE",
        RELIGION = "LOC_AMT_MC_QUICK_TEMPLATE_RELIGION",
        NAVAL = "LOC_AMT_MC_QUICK_TEMPLATE_NAVAL",
        MILITARY = "LOC_AMT_MC_QUICK_TEMPLATE_MILITARY",
    };
    return keys[templateKey];
end

function AMT_MC_RefreshQuickSetupButton()
    local pull = Controls.MCQuickSetupPull;
    if not pull then return; end
    pcall(function()
        local button = pull:GetButton();
        if m_MCUIQuickTemplateKey then
            local templateKey = AMT_MC_QuickTemplateLocKey(
                m_MCUIQuickTemplateKey);
            button:SetText(Locale.Lookup(
                "LOC_AMT_MC_UI_QUICK_APPLIED",
                Locale.Lookup(templateKey), m_MCUIQuickCityCount
            ));
        else
            button:SetText(Locale.Lookup("LOC_AMT_MC_UI_QUICK_OFF"));
        end
    end);
end

function AMT_MC_PopulateQuickSetupPull()
    local pull = Controls.MCQuickSetupPull;
    if not pull then
        return;
    end
    if not AMT_MultiCity or not AMT_MultiCity.QuickSetup then
        pull:SetHide(true);
        if Controls.MCQuickSetupLabel then
            Controls.MCQuickSetupLabel:SetHide(true);
        end
        return;
    end
    pull:SetHide(false);
    if Controls.MCQuickSetupLabel then
        Controls.MCQuickSetupLabel:SetHide(false);
    end
    local okClear = pcall(function()
        pull:ClearEntries();
    end);
    if not okClear or not pull.BuildEntry then
        return;
    end
    local templates = {
        { "DEFAULT", "LOC_AMT_MC_QUICK_TEMPLATE_DEFAULT" },
        { "SCIENCE", "LOC_AMT_MC_QUICK_TEMPLATE_SCIENCE" },
        { "CULTURE", "LOC_AMT_MC_QUICK_TEMPLATE_CULTURE" },
        { "RELIGION", "LOC_AMT_MC_QUICK_TEMPLATE_RELIGION" },
        { "NAVAL", "LOC_AMT_MC_QUICK_TEMPLATE_NAVAL" },
        { "MILITARY", "LOC_AMT_MC_QUICK_TEMPLATE_MILITARY" },
    };
    local offControl = {};
    pull:BuildEntry("InstanceOne", offControl);
    if offControl.Button then
        offControl.Button:SetText(Locale.Lookup("LOC_AMT_MC_UI_QUICK_OFF"));
        offControl.Button:RegisterCallback(
            Mouse.eLClick, AMT_MC_CancelQuickSetup
        );
    end
    for _, template in ipairs(templates) do
        local key = template[1];
        local control = {};
        pull:BuildEntry("InstanceOne", control);
        if control.Button then
            control.Button:SetText(Locale.Lookup(template[2]));
            control.Button:RegisterCallback(Mouse.eLClick, function()
                AMT_MC_ApplyQuickSetup(key);
            end);
        end
    end
    pull:CalculateInternals();
    AMT_MC_RefreshQuickSetupButton();
end

function AMT_MC_GetScopeSubjectNames(intent, subjectType, orderedKeys)
    local names, seen = {}, {};
    for _, subjectKey in ipairs(orderedKeys or {}) do
        if not seen[subjectKey] then
            seen[subjectKey] = true;
            if m_MCMode and subjectType == MAP_PIN_TYPE_DISTRICT
                and AMT_MC_M6U_IsSupported(subjectKey) then
                -- Locked player-unique subjects are reported in the shared
                -- "player unique" summary, not as ordinary districts.
            else
                table.insert(names, GetSubjectDisplay(
                    subjectType, subjectKey
                ));
            end
        end
    end
    local remaining = {};
    for subjectKey, selected in pairs(
        (intent.selectedSubjects or {})[subjectType] or {}
    ) do
        if selected == true and not seen[subjectKey] then
            table.insert(remaining, subjectKey);
        end
    end
    table.sort(remaining);
    for _, subjectKey in ipairs(remaining) do
        if not (m_MCMode and subjectType == MAP_PIN_TYPE_DISTRICT
            and AMT_MC_M6U_IsSupported(subjectKey)) then
            table.insert(names, GetSubjectDisplay(subjectType, subjectKey));
        end
    end
    return names;
end

function AMT_MC_FormatScope(scope)
    local includedLines = {};
    if m_MCMode and AMT_MC_M6U_FormatUniqueScope then
        for _, line in ipairs(AMT_MC_M6U_FormatUniqueScope(scope)) do
            table.insert(includedLines, line);
        end
    end
    for _, item in ipairs(scope.included) do
        local intent = item.savedIntent or {};
        local districtNames = AMT_MC_GetScopeSubjectNames(
            intent, MAP_PIN_TYPE_DISTRICT, intent.specialtyOrder
        );
        local improvementNames = AMT_MC_GetScopeSubjectNames(
            intent, MAP_PIN_TYPE_IMPROVEMENT
        );
        local wonderNames = AMT_MC_GetScopeSubjectNames(
            intent, MAP_PIN_TYPE_WONDER
        );
        table.insert(includedLines, "[ICON_Capital] "
            .. Locale.Lookup(
                "LOC_AMT_MC_SCOPE_CITY_HEADER", tostring(item.name)
            ));
        table.insert(includedLines, "    " .. Locale.Lookup(
            "LOC_AMT_MC_SCOPE_PROFILE",
            intent.futurePopulation or "?",
            intent.specialtySlotCount or "?"
        ));
        table.insert(includedLines, "    " .. Locale.Lookup(
            "LOC_AMT_MC_SCOPE_DISTRICTS",
            #districtNames > 0 and table.concat(districtNames, " → ")
                or Locale.Lookup("LOC_AMT_MC_REPORT_NONE")
        ));
        table.insert(includedLines, "    " .. Locale.Lookup(
            "LOC_AMT_MC_SCOPE_IMPROVEMENTS", #improvementNames,
            #improvementNames > 0 and table.concat(improvementNames, "、")
                or Locale.Lookup("LOC_AMT_MC_REPORT_NONE")
        ));
        if #wonderNames > 0 then
            table.insert(includedLines, "    " .. Locale.Lookup(
                "LOC_AMT_MC_SCOPE_WONDERS",
                table.concat(wonderNames, "、")
            ));
        end
        table.insert(includedLines, "    " .. Locale.Lookup(
            "LOC_AMT_MC_SCOPE_HORIZON",
            Locale.Lookup(intent.horizon == "CURRENT"
                and "LOC_AMT_CURRENT_BUILDABLE" or "LOC_AMT_LONG_TERM")
        ));
        if item.hasUnsavedDraft then
            table.insert(includedLines, "    [ICON_Exclamation] "
                .. Locale.Lookup("LOC_AMT_MC_SCOPE_USES_SAVED"));
        end
        table.insert(includedLines, "");
    end
    local excludedLines = {};
    if #scope.excluded == 0 then
        table.insert(excludedLines, Locale.Lookup("LOC_AMT_MC_SCOPE_NONE"));
    else
        for _, item in ipairs(scope.excluded) do
            table.insert(excludedLines, "[ICON_Bullet] " .. tostring(item.name));
            table.insert(excludedLines, "    " .. Locale.Lookup(
                item.reason == "NEEDS_REVIEW"
                    and "LOC_AMT_MC_SCOPE_REASON_REVIEW"
                    or (item.reason == "NOT_SELECTED"
                        and "LOC_AMT_MC_SCOPE_REASON_UNSELECTED"
                        or "LOC_AMT_MC_SCOPE_REASON_UNSET")
            ));
            table.insert(excludedLines, "");
        end
    end
    return table.concat(includedLines, "[NEWLINE]"),
        table.concat(excludedLines, "[NEWLINE]");
end

function AMT_MC_OpenScope()
    if m_IsPlanning then return; end
    AMT_MC_MarkCurrentDraftChanged();
    -- Persisted profiles are not automatically re-planned on every later
    -- run.  A save during this editor session selects that city.  For the
    -- convenient one-city case, pressing the primary action with no current
    -- selection explicitly selects the active saved city.
    if AMT_MultiCity.UIState.CountIncludedRealCities(m_MCSession) == 0 then
        local activeID = AMT_MultiCity.UIState.GetActiveID(m_MCSession);
        local activeProfile = activeID
            and m_MCSession.profiles[activeID] or nil;
        if activeProfile and activeProfile.savedIntent ~= nil
            and AMT_MultiCity.UIState.GetStatus(activeProfile)
                ~= AMT_MultiCity.UIState.STATUS_REVIEW then
            AMT_MultiCity.UIState.IncludeInScope(m_MCSession, activeID);
        end
    end
    local scope = AMT_MultiCity.UIState.BuildScope(m_MCSession);
    if #scope.included == 0 then
        local message = Locale.Lookup("LOC_AMT_MC_SCOPE_EMPTY");
        if m_ResultText then
            m_ResultText:SetHide(false);
            m_ResultText:SetText(message);
        end
        if Controls.WarningText then
            Controls.WarningText:SetText(message);
            Controls.WarningText:SetHide(false);
        end
        return;
    end
    local locksOK, lockSubjects = AMT_MC_M6U_ValidateSavedLocks(scope);
    if not locksOK then
        m_ResultText:SetText(Locale.Lookup(
            "LOC_AMT_MC_UNIQUE_LOCK_UNSAVED_CITY",
            AMT_MC_M6U_SubjectNames(lockSubjects)
        ));
        return;
    end
    if Controls.WarningText then
        Controls.WarningText:SetText("");
        Controls.WarningText:SetHide(true);
    end
    m_MCPendingScope = scope;
    AMT_MC_SetPhase(2);
    local includedText, excludedText = AMT_MC_FormatScope(scope);
    Controls.MCScopeFrame:SetSizeY(405);
    Controls.MCScopeTitle:SetText(Locale.Lookup("LOC_AMT_MC_SCOPE_TITLE"));
    Controls.MCScopeNotice:SetText(Locale.Lookup(
        "LOC_AMT_MC_SCOPE_NOTICE"
    ) .. "[NEWLINE]" .. Locale.Lookup("LOC_AMT_MC_SCOPE_CITY_HINT"));
    Controls.MCScopeIncludedText:SetText(includedText);
    Controls.MCScopeExcludedText:SetText(excludedText);
    Controls.MCScopeIncludedText:SetSizeY(math.max(
        188, #scope.included * 190
    ));
    Controls.MCScopeExcludedText:SetSizeY(math.max(
        188, #scope.excluded * 68
    ));
    Controls.MCScopeIncludedPanel:SetHide(false);
    Controls.MCScopeExcludedPanel:SetHide(false);
    Controls.MCScopeScroll:SetHide(true);
    Controls.MCScopeIncludedScroll:CalculateInternalSize();
    Controls.MCScopeIncludedScroll:SetScrollValue(0);
    Controls.MCScopeExcludedScroll:CalculateInternalSize();
    Controls.MCScopeExcludedScroll:SetScrollValue(0);
    Controls.MCScopeBackButton:SetHide(false);
    Controls.MCScopeConfirmButton:SetHide(false);
    Controls.MCScopeCloseButton:SetHide(true);
    Controls.MCScopeOverlay:SetHide(false);
end

function AMT_MC_BuildProfileInput(item)
    local playerID = Game.GetLocalPlayer();
    local player = Players[playerID];
    local city = player:GetCities():FindID(item.cityID);
    local foundedTypes = GetLockedSpecialtyDistricts(city, false);
    local allLocked = GetLockedSpecialtyDistricts(city, true);
    local foundedSet, manualTypes = {}, {};
    for _, districtType in ipairs(foundedTypes or {}) do
        foundedSet[districtType] = true;
    end
    for _, districtType in ipairs(allLocked or {}) do
        if not foundedSet[districtType] then
            table.insert(manualTypes, districtType);
        end
    end
    table.sort(foundedTypes);
    table.sort(manualTypes);
    local removals = {};
    local clear = item.savedIntent.clearPolicy or {};
    if clear.clearAutoPins then
        local registry = LoadAutoPinRegistry(playerID);
        local keys = BuildClearPinKeysForCity(
            playerID, city, registry, clear.clearManualPins == true
        );
        local pins = PlayerConfigurations[playerID]:GetMapPins() or {};
        for _, pin in pairs(pins) do
            local key = Key(pin:GetHexX(), pin:GetHexY());
            if keys[key] then
                local record = CapturePinRecord(pin, registry);
                if record then record.id = nil; table.insert(removals, record); end
            end
        end
    end
    return {
        participantID = item.participantID,
        participantKind = "REAL_CITY",
        cityID = item.cityID,
        name = item.name,
        savedRevision = item.savedRevision,
        savedIntent = AMT_MC_Copy(item.savedIntent),
        resolvedPlan = AMT_MC_Copy(item.resolvedPlan),
        cityInput = {
            foundedSpecialtyTypes = foundedTypes,
            manualPinnedSpecialtyTypes = manualTypes,
        },
        clearPreview = removals,
    };
end

function AMT_MC_BuildSignatureInputs(items)
    local playerID = Game.GetLocalPlayer();
    local player = Players[playerID];
    local ownership, resources, seen = {}, {}, {};
    for _, item in ipairs(items) do
        local city = player:GetCities():FindID(item.cityID);
        for _, plot in ipairs(GetCityRangePlots(city, nil)) do
            local key = Key(plot:GetX(), plot:GetY());
            if not seen[key] then
                seen[key] = true;
                local ownerCity = AMT_GetPlotPurchaseCity(plot);
                table.insert(ownership, {
                    x = plot:GetX(), y = plot:GetY(), owner = plot:GetOwner(),
                    cityID = ownerCity and ownerCity:GetID() or -1,
                });
                local resource = ImprovementPlacement.GetActualVisibleResource(
                    plot, playerID
                );
                if resource then
                    table.insert(resources, {
                        x = plot:GetX(), y = plot:GetY(),
                        resourceType = resource.ResourceType,
                    });
                end
            end
        end
    end
    local function SortParts(values)
        table.sort(values, function(a, b)
            if a.x ~= b.x then return a.x < b.x; end
            return a.y < b.y;
        end);
    end
    SortParts(ownership); SortParts(resources);
    return { plotOwnership = ownership, revealedResources = resources };
end

function AMT_MC_FormatSavedSubjects(intent)
    local labels, seen = {}, {};
    for _, subjectType in ipairs({
        MAP_PIN_TYPE_DISTRICT,
        MAP_PIN_TYPE_IMPROVEMENT,
        MAP_PIN_TYPE_WONDER,
    }) do
        for subjectKey, selected in pairs(
            (intent.selectedSubjects or {})[subjectType] or {}
        ) do
            if selected == true then
                local label = GetSubjectDisplay(subjectType, subjectKey);
                if not seen[label] then
                    seen[label] = true;
                    table.insert(labels, label);
                end
            end
        end
    end
    table.sort(labels);
    return #labels > 0 and table.concat(labels, "、")
        or Locale.Lookup("LOC_AMT_MC_REPORT_NONE");
end

function AMT_MC_FormatRecommendationEvidence(intent)
    local lines = {};
    for _, evidence in ipairs(
        intent.improvementRecommendationEvidence or {}
    ) do
        local resource = GameInfo.Resources[evidence.resourceType];
        local resourceName = resource and Locale.Lookup(resource.Name)
            or tostring(evidence.resourceType);
        local improvementNames = {};
        for _, improvementType in ipairs(evidence.improvementTypes or {}) do
            table.insert(improvementNames, GetSubjectDisplay(
                MAP_PIN_TYPE_IMPROVEMENT, improvementType
            ));
        end
        table.sort(improvementNames);
        if #improvementNames > 0 then
            table.insert(lines, "      " .. resourceName .. " → "
                .. table.concat(improvementNames, "、"));
        end
    end
    if #lines == 0 then
        table.insert(lines, "      "
            .. Locale.Lookup("LOC_AMT_MC_REPORT_NO_RECOMMENDATIONS"));
    end
    return lines;
end

function AMT_MC_FormatSnapshot(snapshot)
    local lines = {
        Locale.Lookup("LOC_AMT_MC_REPORT_SUMMARY"),
        "  " .. Locale.Lookup("LOC_AMT_MC_REPORT_PARTICIPANTS") .. ": "
            .. tostring(#snapshot.realCityIDs),
        "",
        Locale.Lookup("LOC_AMT_MC_REPORT_PER_CITY"),
    };
    for _, participantID in ipairs(snapshot.orderedParticipantIDs) do
        local city = snapshot.participants[participantID];
        table.insert(lines, "  [ICON_Capital] " .. tostring(city.name)
            .. "  [ID " .. tostring(city.cityID) .. "]  · r"
            .. tostring(city.savedRevision));
        table.insert(lines, "    "
            .. Locale.Lookup("LOC_AMT_MC_REPORT_FUTURE_POP") .. " "
            .. tostring(city.futurePopulation)
            .. "  · " .. Locale.Lookup("LOC_AMT_MC_REPORT_INTERNAL_POP")
            .. " " .. tostring(city.currentPopulation));
        table.insert(lines, "    "
            .. Locale.Lookup("LOC_AMT_MC_REPORT_SLOTS") .. " "
            .. tostring(city.existingSpecialtySlots) .. " / "
            .. tostring(city.normalizedSlots));
        table.insert(lines, "    "
            .. Locale.Lookup("LOC_AMT_MC_REPORT_SAVED_PROJECTS") .. " "
            .. AMT_MC_FormatSavedSubjects(city.savedIntent));
        local orderNames = {};
        for _, districtType in ipairs(city.normalizedSlotTypes or {}) do
            table.insert(orderNames, GetDistrictDisplay(districtType));
        end
        table.insert(lines, "    "
            .. Locale.Lookup("LOC_AMT_MC_REPORT_ORDER") .. " "
            .. (#orderNames > 0 and table.concat(orderNames, " → ")
                or Locale.Lookup("LOC_AMT_MC_REPORT_NONE")));
        table.insert(lines, "    "
            .. Locale.Lookup("LOC_AMT_MC_REPORT_RECOMMENDATIONS"));
        for _, line in ipairs(AMT_MC_FormatRecommendationEvidence(
            city.savedIntent
        )) do
            table.insert(lines, line);
        end
    end
    table.insert(lines, "");
    table.insert(lines, Locale.Lookup("LOC_AMT_MC_REPORT_CLEAR"));
    for _, participantID in ipairs(snapshot.orderedParticipantIDs) do
        local city = snapshot.participants[participantID];
        local removalCount = #(
            snapshot.clearPolicy.removeByCity[city.cityID] or {}
        );
        table.insert(lines, "  " .. tostring(city.name) .. "："
            .. Locale.Lookup("LOC_AMT_MC_REPORT_CLEAR_COUNT", removalCount));
    end
    table.insert(lines, "");
    table.insert(lines, Locale.Lookup("LOC_AMT_MC_REPORT_NO_PLACEMENT"));
    return table.concat(lines, "[NEWLINE]");
end

function AMT_MC_ConfirmScope()
    if not m_MCPendingScope then return; end
    for _, item in ipairs(m_MCPendingScope.included) do
        local profile = m_MCSession.profiles[item.participantID];
        if not profile or profile.savedRevision ~= item.savedRevision
            or not AMT_MultiCity.UIState.Equal(
                profile.savedIntent, item.savedIntent
            ) then
            Controls.MCScopeNotice:SetText(Locale.Lookup(
                "LOC_AMT_MC_SCOPE_STALE"
            ));
            return;
        end
    end
    local profiles = {};
    for _, item in ipairs(m_MCPendingScope.included) do
        table.insert(profiles, AMT_MC_BuildProfileInput(item));
    end
    local locksOK, lockSubjects = AMT_MC_M6U_ValidateSavedLocks(
        m_MCPendingScope
    );
    if not locksOK then
        Controls.MCScopeNotice:SetText(Locale.Lookup(
            "LOC_AMT_MC_UNIQUE_LOCK_UNSAVED_CITY",
            AMT_MC_M6U_SubjectNames(lockSubjects)
        ));
        return;
    end
    local signatureInputs = AMT_MC_BuildSignatureInputs(
        m_MCPendingScope.included
    );
    signatureInputs.uniqueDistrictSaved = AMT_MC_M6U_ScopeUniqueSaved(
        m_MCPendingScope
    );
    local buildOK, snapshot, reason = pcall(
        AMT_MultiCity.Cluster.BuildSnapshotFromProfiles,
        Game.GetLocalPlayer(), profiles,
        signatureInputs,
        "SAVED_SETTINGS_CONFIRMATION"
    );
    if not buildOK then
        reason = snapshot;
        snapshot = nil;
        Log("error: M2 snapshot build failed: " .. tostring(reason));
    end
    if not snapshot then
        Controls.MCScopeNotice:SetText(Locale.Lookup(
            "LOC_AMT_MC_SNAPSHOT_FAILED", tostring(reason)
        ));
        return;
    end
    local capabilities = AMT_MultiCity and AMT_MultiCity.GetCapabilities
        and AMT_MultiCity.GetCapabilities() or {};
    local jointReady = capabilities.jointPreviewEnabled == true
        and AMT_MultiCity.Solver ~= nil
        and AMT_MultiCity.Requests ~= nil;
    if #snapshot.realCityIDs >= 2 and jointReady then

        AMT_MC_M3_BeginJointSolve(snapshot);
        return;
    end
    if #snapshot.realCityIDs == 1 then
        -- Single saved city keeps the original single-city path: apply the
        -- confirmed saved intent, then reuse OnPlan unchanged (plan 3.1).
        local onlyID = snapshot.orderedParticipantIDs[1];
        local only = snapshot.participants[onlyID];
        AMT_MultiCity.UIState.SetActiveByID(m_MCSession, onlyID);
        local city = GetSelectedCity();
        local plan = city and GetCitySpecialtyPlan(city) or nil;
        if plan and only and only.savedIntent then
            AMT_MC_ApplyIntentToPlan(plan, only.savedIntent);
        end
        Controls.MCScopeOverlay:SetHide(true);
        m_MCPendingScope = nil;
        RepopulatePopup();

        OnPlan();
        return;
    end
    -- Fallback: keep the M2 dry-run report when joint preview is
    -- unavailable (module failure must degrade, never block).

    Controls.MCScopeTitle:SetText(Locale.Lookup(
        "LOC_AMT_MC_DRY_RUN_REPORT_TITLE"
    ));
    Controls.MCScopeNotice:SetText(Locale.Lookup(
        "LOC_AMT_MC_REPORT_NO_PLACEMENT"
    ));
    Controls.MCScopeFrame:SetSizeY(650);
    Controls.MCScopeIncludedPanel:SetHide(true);
    Controls.MCScopeExcludedPanel:SetHide(true);
    Controls.MCScopeScroll:SetHide(false);
    Controls.MCScopeText:SetText(AMT_MC_FormatSnapshot(snapshot));
    Controls.MCScopeText:SetSizeY(math.max(
        460, 300 + #snapshot.realCityIDs * 220
    ));
    Controls.MCScopeScroll:CalculateInternalSize();
    Controls.MCScopeScroll:SetScrollValue(0);
    Controls.MCScopeBackButton:SetHide(false);
    Controls.MCScopeConfirmButton:SetHide(true);
    Controls.MCScopeCloseButton:SetHide(false);

end

-- ---------------------------------------------------------------------------
-- M6U player-unique district adapter (docs/UNIQUE_DISTRICT_UI_PLAN.md).
-- Every entry below is a GLOBAL function or global table field so the
-- planner chunk keeps its Civ VI top-level register headroom.  The pure
-- intent model lives in amt_mc_unique_district.lua; this block is only the
-- game-aware glue (subject eligibility, manual-pin detection, shared
-- draft/saved persistence, atomic city-list transitions, request compile
-- hooks and player-readable reports).  It never places or removes pins.
-- ---------------------------------------------------------------------------
AMT_MC_M6U = AMT_MC_M6U or {};
AMT_MC_M6U.PendingClear = nil;

function AMT_MC_M6U_SubjectKeys()
    -- Dynamic discovery: every district the current player's rule set offers
    -- that is conservatively provable as "one per city AND max one per
    -- player" joins the group.  This adapts to mod environments instead of
    -- hard-coding the two base-game subjects.
    local keys = {};
    local seen = {};
    local traits = MapTacks.PlayerTraits(Game.GetLocalPlayer());
    local districts = MapTacks.PlayerDistricts(traits);
    for _, districtRow in ipairs(districts or {}) do
        local districtType = districtRow.DistrictType;
        if districtType and not seen[districtType]
            and not districtRow.CityCenter
            and not districtRow.InternalOnly
            and districtType ~= "DISTRICT_WONDER" then
            local gameRow = GameInfo.Districts[districtType];
            if gameRow and GetDistrictMaxPerPlayer(districtType) == 1
                and IsDistrictOnePerCity(districtType) then
                seen[districtType] = true;
                table.insert(keys, districtType);
            end
        end
    end
    table.sort(keys);
    return keys;
end

function AMT_MC_M6U_IsSupported(subjectKey)
    local row = GameInfo.Districts[subjectKey];
    if not row or row.CityCenter or row.InternalOnly then return false; end
    -- Conservative proof of "max one per player + one per city"; nothing
    -- else joins the group.
    if GetDistrictMaxPerPlayer(subjectKey) ~= 1 then return false; end
    if not IsDistrictOnePerCity(subjectKey) then return false; end
    for _, key in ipairs(AMT_MC_M6U_SubjectKeys()) do
        if key == subjectKey then return true; end
    end
    return false;
end

function AMT_MC_M6U_SubjectList()
    local list = {};
    for _, subjectKey in ipairs(AMT_MC_M6U_SubjectKeys()) do
        table.insert(list, {
            subjectKey = subjectKey,
            display = GetSubjectDisplay(
                MAP_PIN_TYPE_DISTRICT, subjectKey
            ),
            iconName = GetSubjectIcon(
                MAP_PIN_TYPE_DISTRICT, subjectKey
            ),
        });
    end
    return list;
end

function AMT_MC_M6U_FilterDistrictOptions()
    local keep = {};
    for _, option in ipairs(
        m_PlannerOptions[MAP_PIN_TYPE_DISTRICT] or {}
    ) do
        if not AMT_MC_M6U_IsSupported(option.subjectKey) then
            table.insert(keep, option);
        end
    end
    m_PlannerOptions[MAP_PIN_TYPE_DISTRICT] = keep;
end

function AMT_MC_M6U_SubjectNames(subjectKeys)
    local names = {};
    for _, subjectKey in ipairs(subjectKeys or {}) do
        table.insert(names, GetSubjectDisplay(
            MAP_PIN_TYPE_DISTRICT, subjectKey
        ));
    end
    table.sort(names);
    return table.concat(names, "、");
end

function AMT_MC_M6U_FilterIntentUnique(intent)
    local copy = AMT_MC_Copy(intent or {});
    local found = {};
    local supported = {};
    for _, subjectKey in ipairs(AMT_MC_M6U_SubjectKeys()) do
        supported[subjectKey] = true;
    end
    local selected = copy.selectedSubjects
        and copy.selectedSubjects[MAP_PIN_TYPE_DISTRICT] or nil;
    if selected then
        for subjectKey in pairs(selected) do
            if supported[subjectKey] then
                found[subjectKey] = true;
                selected[subjectKey] = nil;
            end
        end
        copy.selectedSubjects[MAP_PIN_TYPE_DISTRICT] = selected;
    end
    local order = {};
    for _, subjectKey in ipairs(copy.specialtyOrder or {}) do
        if supported[subjectKey] then
            found[subjectKey] = true;
        else
            table.insert(order, subjectKey);
        end
    end
    copy.specialtyOrder = order;
    return copy, found;
end

-- One-time migration from r21 per-city unique selections to the shared
-- AUTO intent (the old UI had no lock semantics; AUTO preserves the player's
-- "build it somewhere" wish without fabricating a city lock).
function AMT_MC_M6U_MigrateLegacySelections()
    if not m_MCSession then return false; end
    local migrated = {};
    for participantID, profile in pairs(m_MCSession.profiles) do
        if profile.savedIntent ~= nil then
            local filtered, found = AMT_MC_M6U_FilterIntentUnique(
                profile.savedIntent
            );
            for subjectKey in pairs(found) do migrated[subjectKey] = true; end
            profile.savedIntent = filtered;
            profile.savedIntentHash = AMT_MultiCity.Contract.Hash(filtered);
        end
        if profile.draftIntent ~= nil then
            local filtered = AMT_MC_M6U_FilterIntentUnique(
                profile.draftIntent
            );
            profile.draftIntent = filtered;
        end
    end
    if next(migrated) ~= nil then
        for subjectKey in pairs(migrated) do
            local existing = m_MCSession.uniqueDistrictSaved[subjectKey];
            if existing == nil or type(existing) ~= "table" then
                m_MCSession.uniqueDistrictSaved[subjectKey] = {
                    mode = AMT_MultiCity.UniqueDistrict.MODE_AUTO,
                    lockedCityID = nil,
                    revision = 1,
                };
            end
        end
        m_MCSession.uniqueDistrictDraft = AMT_MC_Copy(
            m_MCSession.uniqueDistrictSaved
        );
        AMT_MC_PersistSettings();

        return true;
    end
    return false;
end

function AMT_MC_M6U_ManualPinLegal(subject, pin, cityID)
    local playerID = Game.GetLocalPlayer();
    local plot = Map.GetPlot(subject.X, subject.Y);
    if not plot then return false; end
    local item = {
        subjectType = MAP_PIN_TYPE_DISTRICT,
        subjectKey = subject.Key,
        requestID = "MCU:MANUAL_CHECK:" .. tostring(subject.Key),
        districtPriority = 1,
        isSpecialty = IsPopulationDistrict(subject.Key),
        specialtyOrder = 1,
        baseDistrictType = GetDistrictStrategyType(subject.Key),
        isUniqueDistrict = IsUniqueDistrict(subject.Key),
        iconName = GetSubjectIcon(MAP_PIN_TYPE_DISTRICT, subject.Key),
        district = subject.Key,
        cityID = cityID,
        x = subject.X,
        y = subject.Y,
        plot = plot,
        hasVisibleResource = false,
        resourceClass = nil,
    };
    local ok, canPlace = pcall(
        CanPlacePin, playerID, MakePinSubject(item)
    );
    if not ok or canPlace ~= true then return false; end
    local okPlan, planOK = pcall(
        ImprovementPlacement.CanPlan, item, playerID,
        BuildPlanningRunCache(playerID)
    );
    if not okPlan or planOK ~= true then return false; end
    return true;
end

function AMT_MC_M6U_ScanUniquePins(subjectKey)
    local playerID = Game.GetLocalPlayer();
    local autoRegistry = LoadAutoPinRegistry(playerID);
    local manual = {};
    local autoCount = 0;
    local cfg = PlayerConfigurations[playerID];
    local pins = cfg and cfg:GetMapPins() or {};
    for _, pin in pairs(pins or {}) do
        if pin then
            local subject = CreateMapPinSubject(pin);
            if subject and subject.Type == MAP_PIN_TYPE_DISTRICT
                and subject.Key == subjectKey then
                if IsAutoMapPin(pin, autoRegistry) then
                    autoCount = autoCount + 1;
                else
                    local plot = Map.GetPlot(subject.X, subject.Y);
                    local ownerCity = AMT_GetPlotPurchaseCity(plot);
                    local cityID = ownerCity and ownerCity:GetID() or nil;
                    if cityID == nil and GetPinPlanningCityID then
                        cityID = GetPinPlanningCityID(
                            playerID, pin, nil
                        );
                    end
                    table.insert(manual, {
                        pin = pin,
                        subject = subject,
                        cityID = cityID,
                        legal = AMT_MC_M6U_ManualPinLegal(
                            subject, pin, cityID
                        ),
                    });
                end
            end
        end
    end
    return manual, autoCount;
end

function AMT_MC_M6U_ScanBuiltSubject(subjectKey)
    local playerID = Game.GetLocalPlayer();
    local player = Players[playerID];
    local cities = player and player:GetCities() or nil;
    if not cities then return nil, nil; end
    local strategy = GetDistrictStrategyType(subjectKey);
    local builtCityID = nil;
    local foundedCityID = nil;
    for _, city in cities:Members() do
        local ok, states = pcall(
            AMT_MultiCity.Cluster.CollectDistrictStates, city
        );
        if ok and type(states) == "table" then
            for _, state in ipairs(states) do
                if state.type == subjectKey
                    or GetDistrictStrategyType(state.type) == strategy then
                    if state.founded then foundedCityID = city:GetID(); end
                    if state.completed then builtCityID = city:GetID(); end
                end
            end
        end
    end
    return builtCityID, foundedCityID;
end

function AMT_MC_M6U_GetEffective(subjectKey)
    local ok, builtCityID, foundedCityID = pcall(
        AMT_MC_M6U_ScanBuiltSubject, subjectKey
    );
    if not ok then
        builtCityID = nil;
        foundedCityID = nil;
    end
    local manual, autoCount = AMT_MC_M6U_ScanUniquePins(subjectKey);
    local source = AMT_MultiCity.UniqueDistrict.EffectiveSource({
        builtCityID = builtCityID,
        foundedCityID = foundedCityID,
        manualCount = #manual,
        manualLegal = #manual == 1 and manual[1].legal == true or nil,
        autoCount = autoCount,
    });
    return {
        source = source,
        builtCityID = builtCityID,
        foundedCityID = foundedCityID,
        manual = manual,
        autoCount = autoCount,
    };
end

function AMT_MC_M6U_EnsureUniqueIM()
    if AMT_MC_M6U.UniqueRowIM == nil and Controls.ItemGrid then
        AMT_MC_M6U.UniqueRowIM = InstanceManager:new(
            "UniqueDistrictEntry", "Top", Controls.ItemGrid
        );
    end
    return AMT_MC_M6U.UniqueRowIM;
end

function AMT_MC_M6U_ResetUniqueRows()
    local im = AMT_MC_M6U_EnsureUniqueIM();
    if im then im:ResetInstances(); end
end

function AMT_MC_M6U_ApplyDropdownValue(subjectKey, value)
    local UD = AMT_MultiCity.UniqueDistrict;
    local mode = nil;
    if value == "OFF" then
        mode = UD.MODE_OFF;
    elseif value == "AUTO" then
        mode = UD.MODE_AUTO;
    elseif value == "LOCKED" or value == "RELOCK" then
        mode = UD.MODE_LOCKED_CITY;
    end
    if mode == nil then return; end
    if AMT_MC_M6U_SetMode(subjectKey, mode) and m_ResultText then
        m_ResultText:SetText(Locale.Lookup(
            "LOC_AMT_MC_UNIQUE_DRAFT_CHANGED"
        ));
    end
end

-- The unique district group lives INSIDE the ordinary district category
-- (user-confirmed design): one icon row per subject, with the native
-- Civ VI PullDown (Style="PullDownBlue", entry instance "InstanceOne").
-- Lock state is shown as a hint BELOW the icon, never as a dead menu entry.
function AMT_MC_M6U_PopulateUniqueRows(subjects)
    local im = AMT_MC_M6U_EnsureUniqueIM();
    if not im then return; end
    local UD = AMT_MultiCity.UniqueDistrict;
    local activeID = AMT_MultiCity.UIState.GetActiveID(m_MCSession);
    local active = activeID and m_MCSession.participants[activeID] or nil;
    local activeCityID = active
        and active.participantKind == "REAL_CITY" and active.cityID or nil;
    for _, subject in ipairs(subjects or {}) do
        local row = im:GetInstance();
        if row then
            local subjectKey = subject.subjectKey;
            local effective = AMT_MC_M6U_GetEffective(subjectKey);
            -- The shared draft state is reported by the top status line;
            -- per-row "unsaved" suffixes were confusing and are gone.
            local nameText = subject.display;
            row.SubjectIcon:SetIcon(subject.iconName);
            row.SubjectName:SetText(nameText);
            row.StatusHint:SetText("");
            row.StatusHint:SetHide(true);
            local readOnlyKey = nil;
            local readOnlyArgs = {};
            local readOnlyTooltip = nil;
            if effective.source == UD.EFFECTIVE_BUILT then
                readOnlyKey = "LOC_AMT_MC_UNIQUE_BUILT";
                readOnlyArgs = {
                    AMT_MC_M6U_CityName(effective.builtCityID),
                };
            elseif effective.source == UD.EFFECTIVE_FOUNDED then
                readOnlyKey = "LOC_AMT_MC_UNIQUE_FOUNDED";
                readOnlyArgs = {
                    AMT_MC_M6U_CityName(effective.foundedCityID),
                };
            elseif effective.source == UD.EFFECTIVE_MANUAL_PIN then
                -- A valid manual pin locks the row: the dropdown is hidden,
                -- switching is disabled, and the row says exactly that a pin
                -- already exists.  The detailed city/plot stays in tooltip.
                local manual = effective.manual[1];
                readOnlyKey = "LOC_AMT_MC_UNIQUE_MANUAL_PIN_EXISTS";
                readOnlyArgs = {};
                readOnlyTooltip = Locale.Lookup(
                    "LOC_AMT_MC_UNIQUE_MANUAL_PIN_DETAIL",
                    AMT_MC_M6U_CityName(manual.cityID),
                    tostring(manual.subject.X),
                    tostring(manual.subject.Y)
                );
            elseif effective.source == UD.EFFECTIVE_MANUAL_CONFLICT then
                readOnlyKey = "LOC_AMT_MC_UNIQUE_MANUAL_CONFLICT";
                readOnlyArgs = { tostring(#effective.manual) };
            elseif effective.source == UD.EFFECTIVE_MANUAL_INVALID then
                readOnlyKey = "LOC_AMT_MC_UNIQUE_MANUAL_INVALID";
            end
            if readOnlyKey then
                row.ReadOnlyState:SetText(Locale.Lookup(
                    readOnlyKey, unpack(readOnlyArgs)
                ));
                row.ReadOnlyState:SetToolTipString(
                    readOnlyTooltip or ""
                );
                row.ReadOnlyState:SetHide(false);
                row.ModePull:SetHide(true);
            else
                row.ReadOnlyState:SetHide(true);
                row.ReadOnlyState:SetToolTipString("");
                row.ModePull:SetHide(false);
                local entry = UD.GetDraft(m_MCSession, subjectKey);
                local pull = row.ModePull;
                local okClear = pcall(function()
                    pull:ClearEntries();
                end);
                if not okClear or not pull.BuildEntry
                    or not pull.GetButton then
                    row.ReadOnlyState:SetText(Locale.Lookup(
                        "LOC_AMT_MC_UNIQUE_DROPDOWN_UNAVAILABLE"
                    ));
                    row.ReadOnlyState:SetHide(false);
                    row.ModePull:SetHide(true);
                else
                    local function AddEntry(label, value)
                        local entryControl = {};
                        pull:BuildEntry("InstanceOne", entryControl);
                        entryControl.Button:SetText(label);
                        entryControl.Button:RegisterCallback(
                            Mouse.eLClick, function()
                                AMT_MC_M6U_ApplyDropdownValue(
                                    subjectKey, value
                                );
                            end
                        );
                    end
                    AddEntry(Locale.Lookup(
                        "LOC_AMT_MC_UNIQUE_OFF"
                    ), "OFF");
                    AddEntry(Locale.Lookup(
                        "LOC_AMT_MC_UNIQUE_AUTO"
                    ), "AUTO");
                    local selectedLabel = nil;
                    if entry.mode == UD.MODE_LOCKED_CITY then
                        selectedLabel = Locale.Lookup(
                            activeCityID == tonumber(entry.lockedCityID)
                                and "LOC_AMT_MC_UNIQUE_LOCKED_HERE"
                                or "LOC_AMT_MC_UNIQUE_LOCKED_OTHER",
                            AMT_MC_M6U_CityName(entry.lockedCityID)
                        );
                        row.StatusHint:SetText(Locale.Lookup(
                            "LOC_AMT_MC_UNIQUE_LOCKED_CITY",
                            AMT_MC_M6U_CityName(entry.lockedCityID)
                        ));
                        row.StatusHint:SetHide(false);
                        if activeCityID
                            and entry.lockedCityID ~= activeCityID then
                            AddEntry(Locale.Lookup(
                                "LOC_AMT_MC_UNIQUE_RELOCK",
                                AMT_MC_M6U_CityName(activeCityID)
                            ), "RELOCK");
                        end
                    elseif activeCityID ~= nil then
                        AddEntry(Locale.Lookup(
                            "LOC_AMT_MC_UNIQUE_LOCK"
                        ), "LOCKED");
                        selectedLabel = entry.mode == UD.MODE_AUTO
                            and Locale.Lookup("LOC_AMT_MC_UNIQUE_AUTO")
                            or Locale.Lookup("LOC_AMT_MC_UNIQUE_OFF");
                    else
                        selectedLabel = entry.mode == UD.MODE_AUTO
                            and Locale.Lookup("LOC_AMT_MC_UNIQUE_AUTO")
                            or Locale.Lookup("LOC_AMT_MC_UNIQUE_OFF");
                    end
                    pull:GetButton():SetText(selectedLabel or "");
                    pull:CalculateInternals();
                    if type(pull.SetToolTipString) == "function" then
                        pull:SetToolTipString(Locale.Lookup(
                            entry.mode == UD.MODE_LOCKED_CITY
                                and "LOC_AMT_MC_UNIQUE_RELOCK_TOOLTIP"
                                or "LOC_AMT_MC_UNIQUE_LOCK_TOOLTIP"
                        ));
                    end
                end
            end
        end
    end
end

function AMT_MC_M6U_CityName(cityID)
    if cityID == nil then return "?"; end
    local player = Players[Game.GetLocalPlayer()];
    local cities = player and player:GetCities() or nil;
    local city = cities and cities:FindID(cityID) or nil;
    if city then return Locale.Lookup(city:GetName()) or "?"; end
    for participantID, participant in pairs(
        m_MCSession and m_MCSession.participants or {}
    ) do
        if participant.cityID == cityID then
            return tostring(participant.name or "?");
        end
    end
    return tostring(cityID);
end

function AMT_MC_M6U_GetCityPlanByID(cityID)
    local player = Players[Game.GetLocalPlayer()];
    local cities = player and player:GetCities() or nil;
    local city = cities and cities:FindID(cityID) or nil;
    local plan = city and GetCitySpecialtyPlan(city) or nil;
    return city, plan;
end

function AMT_MC_M6U_AddToCityPlan(cityID, subjectKey)
    local city, plan = AMT_MC_M6U_GetCityPlanByID(cityID);
    if not city or not plan then
        return false, Locale.Lookup("LOC_AMT_MC_UNIQUE_CITY_UNAVAILABLE");
    end
    plan.selectedSubjects = plan.selectedSubjects or {};
    plan.selectedSubjects[MAP_PIN_TYPE_DISTRICT] =
        plan.selectedSubjects[MAP_PIN_TYPE_DISTRICT] or {};
    plan.selectedSubjects[MAP_PIN_TYPE_DISTRICT][subjectKey] = true;
    local slotCount = tonumber(plan.slotCount) or DEFAULT_SPECIALTY_SLOT_COUNT;
    local ordered, seen = {}, {};
    for index = 1, slotCount do
        local districtType = plan.slots and plan.slots[index] or nil;
        if districtType and not seen[districtType] then
            seen[districtType] = true;
            table.insert(ordered, districtType);
        end
    end
    for _, districtType in ipairs(plan.mcDeferredOrder or {}) do
        if districtType and not seen[districtType] then
            seen[districtType] = true;
            table.insert(ordered, districtType);
        end
    end
    if not seen[subjectKey] then table.insert(ordered, subjectKey); end

    -- plan.slots uses physical row indexes after already-built/manual locked
    -- districts.  Never compact it to index 1: doing so makes Normalize drop
    -- valid future districts when a city has locked rows at the front.
    local locked = GetLockedSpecialtyDistricts(city);
    plan.slots = {};
    plan.mcDeferredOrder = {};
    local nextIndex = #locked + 1;
    for _, districtType in ipairs(ordered) do
        if nextIndex <= slotCount then
            plan.slots[nextIndex] = districtType;
            nextIndex = nextIndex + 1;
        else
            table.insert(plan.mcDeferredOrder, districtType);
        end
    end
    return true;
end

function AMT_MC_M6U_RemoveFromCityPlan(cityID, subjectKey)
    local city, plan = AMT_MC_M6U_GetCityPlanByID(cityID);
    if not plan then return true; end
    local slotCount = tonumber(plan.slotCount) or DEFAULT_SPECIALTY_SLOT_COUNT;
    local ordered, seen = {}, {};
    for index = 1, slotCount do
        local districtType = plan.slots and plan.slots[index] or nil;
        if districtType and districtType ~= subjectKey
            and not seen[districtType] then
            seen[districtType] = true;
            table.insert(ordered, districtType);
        end
    end
    for _, districtType in ipairs(plan.mcDeferredOrder or {}) do
        if districtType and districtType ~= subjectKey
            and not seen[districtType] then
            seen[districtType] = true;
            table.insert(ordered, districtType);
        end
    end
    local locked = GetLockedSpecialtyDistricts(city);
    plan.slots = {};
    plan.mcDeferredOrder = {};
    local nextIndex = #locked + 1;
    for _, districtType in ipairs(ordered) do
        if nextIndex <= slotCount then
            plan.slots[nextIndex] = districtType;
            nextIndex = nextIndex + 1;
        else
            table.insert(plan.mcDeferredOrder, districtType);
        end
    end
    if plan.selectedSubjects
        and plan.selectedSubjects[MAP_PIN_TYPE_DISTRICT] then
        plan.selectedSubjects[MAP_PIN_TYPE_DISTRICT][subjectKey] = nil;
    end
    return true;
end

function AMT_MC_M6U_MarkParticipantDraft(participantID)
    local profile = m_MCSession
        and m_MCSession.profiles[participantID] or nil;
    local participant = m_MCSession
        and m_MCSession.participants[participantID] or nil;
    if not profile or not participant then return; end
    local city, plan = AMT_MC_M6U_GetCityPlanByID(participant.cityID);
    if city and plan then
        local intent = AMT_MC_IntentFromPlan(city, plan);
        local changed = not AMT_MultiCity.UIState.Equal(
            intent, profile.draftIntent
        );
        AMT_MultiCity.UIState.SetDraft(
            m_MCSession, participantID, intent, changed
        );
    end
end

function AMT_MC_M6U_SetMode(subjectKey, mode, lockedCityIDOverride)
    if not m_MCSession or not AMT_MC_M6U_IsSupported(subjectKey) then
        return false;
    end
    local UD = AMT_MultiCity.UniqueDistrict;
    local oldEntry = UD.GetDraft(m_MCSession, subjectKey);
    local oldCityID = oldEntry.mode == UD.MODE_LOCKED_CITY
        and tonumber(oldEntry.lockedCityID) or nil;
    local newCityID = nil;
    local newParticipantID = nil;
    if mode == UD.MODE_LOCKED_CITY then
        if lockedCityIDOverride ~= nil then
            -- Programmatic lock (e.g. quick setup) targets an explicit
            -- stable city ID instead of the currently selected city.
            newCityID = tonumber(lockedCityIDOverride);
            newParticipantID = AMT_MultiCity.UIState.RealCityParticipantID(
                Game.GetLocalPlayer(), newCityID
            );
            local candidate = newParticipantID
                and m_MCSession.participants[newParticipantID] or nil;
            if not candidate
                or candidate.participantKind ~= "REAL_CITY" then
                if m_ResultText then
                    m_ResultText:SetText(Locale.Lookup(
                        "LOC_AMT_MC_UNIQUE_LOCK_NEEDS_CITY"
                    ));
                end
                return false;
            end
        else
            local activeID = AMT_MultiCity.UIState.GetActiveID(m_MCSession);
            local active = activeID
                and m_MCSession.participants[activeID] or nil;
            if not active or active.participantKind ~= "REAL_CITY" then
                if m_ResultText then
                    m_ResultText:SetText(Locale.Lookup(
                        "LOC_AMT_MC_UNIQUE_LOCK_NEEDS_CITY"
                    ));
                end
                return false;
            end
            newCityID = active.cityID;
            newParticipantID = activeID;
        end
    end
    if oldEntry.mode == mode
        and (mode ~= UD.MODE_LOCKED_CITY
            or oldCityID == newCityID) then
        -- The shared state may already match while a quick template has just
        -- replaced the per-city plan.  Reassert the plan-side copy instead of
        -- returning with a lock that has no visible/solvable slot.
        if mode == UD.MODE_LOCKED_CITY and newCityID then
            local addedOK, reason = AMT_MC_M6U_AddToCityPlan(
                newCityID, subjectKey
            );
            if not addedOK then return false, reason; end
            if newParticipantID then
                AMT_MC_M6U_MarkParticipantDraft(newParticipantID);
            end
        end
        return true;
    end

    -- Atomic draft conversion: apply old-city removal and new-city insertion
    -- to BOTH plan sides, then commit the shared draft.  Any plan failure
    -- rolls the city lists back before the shared state changes.
    local removedOK = true;
    if oldCityID and oldCityID ~= newCityID then
        removedOK = AMT_MC_M6U_RemoveFromCityPlan(oldCityID, subjectKey);
    end
    if removedOK and newCityID then
        local addedOK, reason = AMT_MC_M6U_AddToCityPlan(
            newCityID, subjectKey
        );
        if not addedOK then
            if oldCityID and oldCityID ~= newCityID then
                AMT_MC_M6U_AddToCityPlan(oldCityID, subjectKey);
            end
            if m_ResultText then
                m_ResultText:SetText(tostring(reason));
            end
            return false;
        end
    end

    local ok, reason = UD.SetDraft(m_MCSession, subjectKey, {
        mode = mode,
        lockedCityID = newCityID or nil,
    });
    if not ok then
        if newCityID then
            AMT_MC_M6U_RemoveFromCityPlan(newCityID, subjectKey);
        end
        if oldCityID and oldCityID ~= newCityID then
            AMT_MC_M6U_AddToCityPlan(oldCityID, subjectKey);
        end
        if m_ResultText then m_ResultText:SetText(tostring(reason)); end
        return false;
    end

    for _, participantID in ipairs({
        oldCityID and AMT_MultiCity.UIState.RealCityParticipantID(
            Game.GetLocalPlayer(), oldCityID
        ) or nil,
        newParticipantID,
    }) do
        if participantID then
            AMT_MC_M6U_MarkParticipantDraft(participantID);
        end
    end
    ClearPendingPreview(true);
    if m_CurrentCategory == MAP_PIN_TYPE_DISTRICT then
        RefreshSpecialtySelectionsForCurrentCity();
        RefreshPlannerItemGrid();
    end
    AMT_MC_RefreshHeader();
    return true;
end

function AMT_MC_M6U_ReconcileDraftPlans()
    if not m_MCSession or not AMT_MultiCity
        or not AMT_MultiCity.UniqueDistrict then return; end
    local UD = AMT_MultiCity.UniqueDistrict;
    for _, subjectKey in ipairs(AMT_MC_M6U_SubjectKeys()) do
        local entry = UD.GetDraft(m_MCSession, subjectKey);
        local targetCityID = entry.mode == UD.MODE_LOCKED_CITY
            and tonumber(entry.lockedCityID) or nil;
        for _, participantID in ipairs(
            m_MCSession.orderedParticipantIDs or {}
        ) do
            local participant = m_MCSession.participants[participantID];
            if participant and participant.participantKind == "REAL_CITY" then
                if participant.cityID == targetCityID then
                    AMT_MC_M6U_AddToCityPlan(
                        participant.cityID, subjectKey
                    );
                else
                    AMT_MC_M6U_RemoveFromCityPlan(
                        participant.cityID, subjectKey
                    );
                end
            end
        end
    end
end

function AMT_MC_M6U_SyncLocksAfterSlotEdit()
    if not m_MCSession or not m_MCMode then return; end
    local activeID = AMT_MultiCity.UIState.GetActiveID(m_MCSession);
    local active = activeID and m_MCSession.participants[activeID] or nil;
    if not active or active.participantKind ~= "REAL_CITY" then
        return;
    end
    local city, plan = AMT_MC_M6U_GetCityPlanByID(active.cityID);
    if not city or not plan then return; end
    local present = {};
    for index = 1, tonumber(plan.slotCount) or 0 do
        local districtType = plan.slots and plan.slots[index] or nil;
        if districtType then present[districtType] = true; end
    end
    for _, districtType in ipairs(plan.mcDeferredOrder or {}) do
        if districtType then present[districtType] = true; end
    end
    local UD = AMT_MultiCity.UniqueDistrict;
    for _, subjectKey in ipairs(AMT_MC_M6U_SubjectKeys()) do
        local entry = UD.GetDraft(m_MCSession, subjectKey);
        if entry.mode == UD.MODE_LOCKED_CITY
            and tonumber(entry.lockedCityID) == active.cityID
            and not present[subjectKey] then
            -- Removal from the slot list cancels the lock; never leave the
            -- left row displaying a lock the plan no longer contains.
            UD.SetDraft(m_MCSession, subjectKey, {
                mode = UD.MODE_OFF,
                lockedCityID = nil,
            });
        end
    end
end

function AMT_MC_M6U_LocksOnCity(cityID)
    local UD = AMT_MultiCity.UniqueDistrict;
    local locks = {};
    for _, subjectKey in ipairs(AMT_MC_M6U_SubjectKeys()) do
        local entry = UD.GetDraft(m_MCSession, subjectKey);
        if entry.mode == UD.MODE_LOCKED_CITY
            and tonumber(entry.lockedCityID) == cityID then
            table.insert(locks, subjectKey);
        end
    end
    table.sort(locks);
    return locks;
end

function AMT_MC_M6U_CancelLocksOnCity(cityID)
    if not m_MCSession then return; end
    local UD = AMT_MultiCity.UniqueDistrict;
    for _, subjectKey in ipairs(AMT_MC_M6U_SubjectKeys()) do
        local entry = UD.GetDraft(m_MCSession, subjectKey);
        if entry.mode == UD.MODE_LOCKED_CITY
            and tonumber(entry.lockedCityID) == cityID then
            AMT_MC_M6U_RemoveFromCityPlan(cityID, subjectKey);
            UD.SetDraft(m_MCSession, subjectKey, {
                mode = UD.MODE_OFF,
                lockedCityID = nil,
            });
        end
    end
end

function AMT_MC_M6U_ValidateDraftLocks()
    local UD = AMT_MultiCity.UniqueDistrict;
    local missing = {};
    for _, subjectKey in ipairs(AMT_MC_M6U_SubjectKeys()) do
        local entry = UD.GetDraft(m_MCSession, subjectKey);
        if entry.mode == UD.MODE_LOCKED_CITY then
            local found = false;
            for participantID, participant in pairs(
                m_MCSession.participants or {}
            ) do
                if participant.participantKind == "REAL_CITY"
                    and participant.cityID == entry.lockedCityID then
                    found = true;
                    break;
                end
            end
            if not found then table.insert(missing, subjectKey); end
        end
    end
    table.sort(missing);
    return #missing == 0, missing;
end

function AMT_MC_M6U_ValidateSavedLocks(scope)
    local includedCityIDs = {};
    for _, item in ipairs(scope and scope.included or {}) do
        table.insert(includedCityIDs, item.cityID);
    end
    local scopedSession = {
        uniqueDistrictSaved = AMT_MC_M6U_ScopeUniqueSaved(scope),
    };
    return AMT_MultiCity.UniqueDistrict.ValidateSavedLocks(
        scopedSession, AMT_MC_M6U_SubjectKeys(), includedCityIDs
    );
end

function AMT_MC_M6U_ScopeUniqueSaved(scope)
    local includedCityIDs = {};
    for _, item in ipairs(scope and scope.included or {}) do
        includedCityIDs[item.cityID] = true;
    end
    local result = AMT_MC_Copy(m_MCSession.uniqueDistrictSaved or {});
    for subjectKey, entry in pairs(result) do
        if entry.mode == AMT_MultiCity.UniqueDistrict.MODE_LOCKED_CITY
            and not includedCityIDs[entry.lockedCityID] then
            -- A lock belonging to an untouched city remains persisted and
            -- its existing pin remains fixed, but it is not a request for
            -- this solve.
            result[subjectKey] = {
                mode = AMT_MultiCity.UniqueDistrict.MODE_OFF,
                lockedCityID = nil,
                revision = entry.revision,
            };
        end
    end
    return result;
end

function AMT_MC_M6U_SaveSharedDrafts()
    return AMT_MultiCity.UniqueDistrict.SaveAllDirty(
        m_MCSession, AMT_MC_M6U_SubjectKeys()
    );
end

function AMT_MC_M6U_DiscardSharedDrafts()
    return AMT_MultiCity.UniqueDistrict.DiscardDrafts(m_MCSession);
end

function AMT_MC_M6U_FormatUniqueScope(scope)
    local UD = AMT_MultiCity.UniqueDistrict;
    local lines = {};
    local scopedSaved = AMT_MC_M6U_ScopeUniqueSaved(scope);
    local includedByCity = {};
    local includedOrder = {};
    for _, item in ipairs(scope and scope.included or {}) do
        includedByCity[item.cityID] = item.name;
        table.insert(includedOrder, item);
    end
    table.insert(lines, Locale.Lookup("LOC_AMT_MC_SCOPE_UNIQUE_HEADER"));
    local shown = false;
    for _, subjectKey in ipairs(AMT_MC_M6U_SubjectKeys()) do
        if AMT_MC_M6U_IsSupported(subjectKey) then
            shown = true;
            local entry = scopedSaved[subjectKey]
                or { mode = UD.MODE_OFF, lockedCityID = nil };
            local display = GetSubjectDisplay(
                MAP_PIN_TYPE_DISTRICT, subjectKey
            );
            if entry.mode == UD.MODE_AUTO then
                local names = {};
                for _, item in ipairs(includedOrder) do
                    table.insert(names, item.name);
                end
                table.insert(lines, "  " .. Locale.Lookup(
                    "LOC_AMT_MC_SCOPE_UNIQUE_AUTO",
                    display,
                    #names > 0 and table.concat(names, "、")
                        or Locale.Lookup("LOC_AMT_MC_REPORT_NONE")
                ));
            elseif entry.mode == UD.MODE_LOCKED_CITY then
                table.insert(lines, "  " .. Locale.Lookup(
                    "LOC_AMT_MC_SCOPE_UNIQUE_LOCKED",
                    display,
                    includedByCity[entry.lockedCityID]
                        or AMT_MC_M6U_CityName(entry.lockedCityID)
                ));
            else
                table.insert(lines, "  " .. Locale.Lookup(
                    "LOC_AMT_MC_SCOPE_UNIQUE_OFF", display
                ));
            end
        end
    end
    if not shown then
        table.insert(lines, "  " .. Locale.Lookup(
            "LOC_AMT_MC_REPORT_NONE"
        ));
    end
    table.insert(lines, "");
    return lines;
end

function AMT_MC_M6U_FormatResultUnique(snapshot, result, state)
    local lines = {};
    local requests = result.inputs
        and result.inputs.uniqueRequests or {};
    if #requests == 0 then return lines; end
    table.insert(lines, Locale.Lookup("LOC_AMT_MC_M6U_REPORT_HEADER"));
    for _, entry in ipairs(requests) do
        local display = GetSubjectDisplay(
            MAP_PIN_TYPE_DISTRICT, entry.subjectKey
        );
        local fulfilled = state
            and state.fulfilledRequestIDs[entry.requestID] or 0;
        if (tonumber(fulfilled) or 0) > 0 then
            local chosenCityID = nil;
            local slotIndex = 0;
            for _, item in ipairs(state.items or {}) do
                if item.candidate.requestID == entry.requestID then
                    chosenCityID = item.candidate.planningCityID;
                    slotIndex = tonumber(item.candidate.slotIndex) or 0;
                    break;
                end
            end
            table.insert(lines, "  " .. Locale.Lookup(
                "LOC_AMT_MC_M6U_REPORT_ITEM",
                display,
                AMT_MC_M6U_CityName(chosenCityID),
                tostring(slotIndex)
            ));
        else
            table.insert(lines, "  " .. Locale.Lookup(
                "LOC_AMT_MC_M6U_REPORT_UNPLACED",
                display,
                entry.mode == "LOCKED_CITY"
                    and AMT_MC_M6U_CityName(entry.lockedCityID)
                    or Locale.Lookup("LOC_AMT_MC_REPORT_NONE")
            ));
        end
    end
    table.insert(lines, "");
    return lines;
end

-- Conditional slot assignment used by the request compiler.  Locked
-- subjects already own their real order index; AUTO subjects receive the
-- smallest free index per city in deterministic subject order.
function AMT_MC_M6U_AssignAutoSlots(
    autoSubjects, snapshot, slotIndexByCity, slotsByParticipant
)
    local occupied = {};
    local lockedSubjects = {};
    for _, subjectKey in ipairs(AMT_MC_M6U_SubjectKeys()) do
        local entry = snapshot.uniqueDistrictSaved
            and snapshot.uniqueDistrictSaved[subjectKey] or nil;
        if entry and entry.mode == "LOCKED_CITY"
            and entry.lockedCityID then
            lockedSubjects[subjectKey] = entry.lockedCityID;
        end
    end
    for _, participantID in ipairs(
        snapshot.orderedParticipantIDs or {}
    ) do
        local participant = snapshot.participants[participantID];
        occupied[participantID] = {};
        for districtType, slotIndex in pairs(
            slotIndexByCity[participant.cityID] or {}
        ) do
            if slotIndex then occupied[participantID][slotIndex] = true; end
        end
        for subjectKey, cityID in pairs(lockedSubjects) do
            if cityID == participant.cityID then
                local slotIndex = (slotIndexByCity[cityID] or {})[
                    subjectKey
                ];
                if slotIndex then
                    occupied[participantID][slotIndex] = true;
                end
            end
        end
    end
    return AMT_MultiCity.UniqueDistrict.AssignAutoSlotIndices(
        autoSubjects,
        snapshot.orderedParticipantIDs,
        occupied,
        slotsByParticipant
    );
end

-- ---------------------------------------------------------------------------
-- M3 joint preview adapter.  Every entry below is a GLOBAL function or a
-- global table field: the planner chunk is already at the Civ VI register
-- ceiling (190 top-level locals), so M3 adds zero top-level locals.  The
-- pure algorithm lives in amt_mc_requests.lua / amt_mc_solver.lua; this
-- block is only the game-aware glue (snapshot -> requests -> candidates ->
-- solve -> preview).  M3 previews must never place or remove map pins: the
-- single-city apply chain is unreachable from here.
-- ---------------------------------------------------------------------------
AMT_MC_M3State = AMT_MC_M3State or {};
AMT_MC_M3State.maxEvaluations = 200000;
-- AMT_MC_M3State.beamWidth is intentionally unset: the solver uses the
-- cost-control adaptive beam (target ~20k evaluations, clamped 16..64).
-- Set this field to a number to override the heuristic.
AMT_MC_M3State.job = nil;
AMT_MC_M3State.pending = nil;
AMT_MC_M3State.lastInputs = nil;

function AMT_MC_M3_GetAdjacentPlotKeys(x, y)
    local keys = {};
    local ok, ringPlots = pcall(GetPlotsWithinXTiles, x, y, 1);
    if not ok or type(ringPlots) ~= "table" then return keys; end
    for _, ringPlot in ipairs(ringPlots) do
        if ringPlot then
            local rx, ry = ringPlot:GetX(), ringPlot:GetY();
            if not (rx == x and ry == y) then
                keys[Key(rx, ry)] = true;
            end
        end
    end
    local list = {};
    for key in pairs(keys) do table.insert(list, key); end
    return list;
end

-- Stable support-bundle signature for wonder variants (plan section 5.4).
function AMT_MC_M5_HashSupportParts(parts)
    table.sort(parts, function(a, b)
        if a.plotKey ~= b.plotKey then return a.plotKey < b.plotKey; end
        if a.subjectType ~= b.subjectType then
            return a.subjectType < b.subjectType;
        end
        return a.subjectKey < b.subjectKey;
    end);
    return AMT_MultiCity.Contract.Hash(parts);
end

-- Merges per-city yield focus states into one evaluation weight table.
-- State +1 multiplies the base weight by 1.75, -1 zeroes it, 0 keeps it;
-- merged values are averaged across participants (M3 approximation).
function AMT_MC_M3_MergeWeights(snapshot)
    local sums = {};
    local counts = {};
    local saw = false;
    for _, participantID in ipairs(snapshot.orderedParticipantIDs or {}) do
        local participant = snapshot.participants
            and snapshot.participants[participantID] or nil;
        local intent = participant and participant.savedIntent or {};
        local focusStates = intent.yieldWeights or {};
        for _, yieldType in ipairs(YIELD_LIST) do
            local state = tonumber(focusStates[yieldType]) or 0;
            local base = DEFAULT_WEIGHTS[yieldType] or 1;
            local value = state == 1 and base * 1.75
                or (state == -1 and 0 or base);
            sums[yieldType] = (sums[yieldType] or 0) + value;
            counts[yieldType] = (counts[yieldType] or 0) + 1;
            saw = true;
        end
    end
    if not saw then return AMT_MC_Copy(DEFAULT_WEIGHTS); end
    local weights = {};
    for _, yieldType in ipairs(YIELD_LIST) do
        weights[yieldType] = (sums[yieldType]
            or DEFAULT_WEIGHTS[yieldType] or 1)
            / (counts[yieldType] or 1);
    end
    return weights;
end

-- Connected mutual-exclusion groups over the selected district set.
-- Returns map districtType -> "EXCL:<first member>" (only for groups with
-- more than one member).
function AMT_MC_M3_BuildExclusionGroups(districtTypes)
    local selected = {};
    for _, districtType in ipairs(districtTypes or {}) do
        selected[districtType] = true;
    end
    local visited = {};
    local result = {};
    for _, districtType in ipairs(districtTypes or {}) do
        if not visited[districtType] then
            local group = {};
            local stack = { districtType };
            visited[districtType] = true;
            local head = 1;
            local exclusions = GetMutuallyExclusiveDistricts();
            while head <= #stack do
                local current = stack[head];
                head = head + 1;
                table.insert(group, current);
                for otherType, value in pairs(exclusions[current] or {}) do
                    if value and selected[otherType]
                        and not visited[otherType] then
                        visited[otherType] = true;
                        table.insert(stack, otherType);
                    end
                end
            end
            if #group > 1 then
                table.sort(group);
                for _, member in ipairs(group) do
                    result[member] = "EXCL:" .. group[1];
                end
            end
        end
    end
    return result;
end

-- Builds contract requests and candidates for the frozen snapshot.
-- Returns inputs table or nil plus a reason.
function AMT_MC_M3_BuildJointInputs(snapshot)
    local playerID = Game.GetLocalPlayer();
    local player = Players[playerID];
    local cityManager = player and player:GetCities() or nil;
    if not cityManager then return nil, "cities unavailable"; end

    local cityObjects = {};
    local slotIndexByCity = {};
    local allDistrictTypes = {};
    for _, participantID in ipairs(snapshot.orderedParticipantIDs or {}) do
        local participant = snapshot.participants[participantID];
        local city = cityManager:FindID(participant.cityID);
        if not city or city:GetOwner() ~= playerID then
            return nil, "participant city unavailable (stale snapshot)";
        end
        cityObjects[participant.cityID] = city;
        local indexMap = {};
        for index, districtType in ipairs(
            participant.normalizedSlotTypes or {}
        ) do
            indexMap[districtType] = index;
        end
        slotIndexByCity[participant.cityID] = indexMap;
        local intent = participant.savedIntent or {};
        for _, districtType in ipairs(intent.specialtyOrder or {}) do
            if not allDistrictTypes[districtType] then
                allDistrictTypes[districtType] = true;
            end
        end
        for districtType, selected in pairs(
            (intent.selectedSubjects or {})[MAP_PIN_TYPE_DISTRICT] or {}
        ) do
            if selected == true and not allDistrictTypes[districtType] then
                allDistrictTypes[districtType] = true;
            end
        end
    end
    local districtTypeList = {};
    for districtType in pairs(allDistrictTypes) do
        table.insert(districtTypeList, districtType);
    end
    table.sort(districtTypeList);
    local exclusionGroups = AMT_MC_M3_BuildExclusionGroups(
        districtTypeList
    );

    local autoRegistry = LoadAutoPinRegistry(playerID);
    local runCache = BuildPlanningRunCache(playerID);
    local cityList = {};
    for _, city in pairs(cityObjects) do table.insert(cityList, city); end
    local _, _, fixedSubjects = GetExistingPlannedDistricts(cityList, {});
    local weights = AMT_MC_M3_MergeWeights(snapshot);

    -- M4 coverage baseline (plan 8.1): built/founded districts and valid
    -- map pins of participant cities form the fixed baseline.  Only the
    -- marginal new coverage of the current plan is rewarded.
    local participantsMap = {};
    local cityIDToParticipant = {};
    for _, participantID in ipairs(snapshot.orderedParticipantIDs or {}) do
        local participant = snapshot.participants[participantID];
        participantsMap[participantID] = { cityID = participant.cityID };
        cityIDToParticipant[participant.cityID] = participantID;
    end
    local baselineCovered = {};
    for _, subject in ipairs(fixedSubjects or {}) do
        if subject.Type == MAP_PIN_TYPE_DISTRICT
            and IsCoverageDistrict(subject.Key) then
            local service = GetDistrictStrategyType(subject.Key);
            local cityID = subject.CityID;
            if cityIDToParticipant[cityID] then
                baselineCovered[service] = baselineCovered[service] or {};
                baselineCovered[service][cityID] = true;
            end
        end
    end
    local coverageServices = {};

    local requests = {};
    local candidatesFor = {};
    local skippedNotes = {};
    local slotLevels = 1;
    local savedHorizon = m_PlanningHorizon;

    -- -----------------------------------------------------------------------
    -- M5 wonder requests (plan 8.2): WORLD scope, required, world-unique.
    -- Built FIRST so the beam never exhausts its width before the required
    -- wonder can enter (legacy searches wonders first).  Supports are
    -- bundled atomically and must be same-city (asserted at conversion).
    -- -----------------------------------------------------------------------
    local wonderTypes = {};
    for _, participantID in ipairs(snapshot.orderedParticipantIDs or {}) do
        local participant = snapshot.participants[participantID];
        local intent = participant.savedIntent or {};
        for wonderType, selected in pairs(
            (intent.selectedSubjects or {})[MAP_PIN_TYPE_WONDER] or {}
        ) do
            if selected == true then wonderTypes[wonderType] = true; end
        end
    end
    local wonderTypeList = {};
    for wonderType in pairs(wonderTypes) do
        table.insert(wonderTypeList, wonderType);
    end
    table.sort(wonderTypeList);
    for _, wonderType in ipairs(wonderTypeList) do
        local wonderDisplay = GetSubjectDisplay(
            MAP_PIN_TYPE_WONDER, wonderType
        );
        local alreadyFixed = false;
        for _, subject in ipairs(fixedSubjects or {}) do
            if subject.Type == MAP_PIN_TYPE_WONDER
                and subject.Key == wonderType then
                alreadyFixed = true;
            end
        end
        if alreadyFixed then
            table.insert(skippedNotes, Locale.Lookup(
                "LOC_AMT_MC_M5_SKIP_PINNED", wonderDisplay
            ));
        elseif IsWonderBuilt(wonderType) then
            table.insert(skippedNotes, Locale.Lookup(
                "LOC_AMT_MC_M5_SKIP_BUILT", wonderDisplay
            ));
        else
            local wonderRequest = {
                requestID = "MC5:WONDER:" .. wonderType,
                scope = "WORLD",
                eligibleParticipantIDs = CopyArray(
                    snapshot.orderedParticipantIDs or {}
                ),
                eligibleCityIDs = CopyArray(snapshot.realCityIDs or {}),
                subjectType = MAP_PIN_TYPE_WONDER,
                subjectOptions = { wonderType },
                cardinalityMin = 1,
                cardinalityMax = 1,
                optional = false,
                slotCost = 0,
                priorityByParticipant = {},
                satisfactionPredicate = "SELF",
                coverageTarget = {},
                supportPolicy = {},
                limitGroup = "WORLD:" .. wonderType,
                limitMax = 1,
                limitScope = "WORLD",
                influenceScope = "LOCAL",
                subjectPriorities = { [wonderType] = 9 },
                subjectOrdersByCity = {},
                cities = cityList,
                selectedDistricts = districtTypeList,
            };
            for _, participantID in ipairs(
                snapshot.orderedParticipantIDs or {}
            ) do
                wonderRequest.priorityByParticipant[participantID] = 9;
            end
            local contractList = {};
            for _, participantID in ipairs(
                snapshot.orderedParticipantIDs or {}
            ) do
                local participant = snapshot.participants[participantID];
                local city = cityObjects[participant.cityID];
                local savedCityHorizon = m_PlanningHorizon;
                m_PlanningHorizon = participant.savedIntent
                    and participant.savedIntent.horizon
                    or m_PlanningHorizon;
                local citySelectedDistricts = {};
                for districtType, selected in pairs(
                    (participant.savedIntent.selectedSubjects or {})[
                        MAP_PIN_TYPE_DISTRICT
                    ] or {}
                ) do
                    if selected == true then
                        table.insert(citySelectedDistricts, districtType);
                    end
                end
                table.sort(citySelectedDistricts);
                wonderRequest.selectedDistricts = citySelectedDistricts;
                wonderRequest.cities = { city };
                local rawCandidates = BuildRawCandidates(
                    wonderRequest, playerID, weights, {}, {}, false, false,
                    fixedSubjects, autoRegistry, runCache
                );
                wonderRequest.cities = cityList;
                wonderRequest.selectedDistricts = districtTypeList;
                m_PlanningHorizon = savedCityHorizon;
                for _, variant in ipairs(rawCandidates or {}) do
                    local supports = {};
                    local supportRequestIDs = {};
                    local supportParts = {};
                    local sameCityOK = true;
                    for _, supportItem in ipairs(
                        variant.supportItems or {}
                    ) do
                        if supportItem.cityID ~= participant.cityID then
                            sameCityOK = false;
                        end
                        local isDistrictSupport = supportItem.subjectType
                            == MAP_PIN_TYPE_DISTRICT;
                        local supportRequestID = nil;
                        local supportRequestTable = nil;
                        if isDistrictSupport then
                            -- District supports explicitly satisfy the
                            -- city's own district request (plan 8.2).
                            supportRequestID = "MC3:" .. participantID
                                .. ":DISTRICT:" .. supportItem.subjectKey;
                            local supportExclusionGroup =
                                exclusionGroups[supportItem.subjectKey];
                            local supportLimitGroup = nil;
                            local supportLimitMax = nil;
                            local supportMaxPerPlayer =
                                GetDistrictMaxPerPlayer(
                                    supportItem.subjectKey
                                );
                            if supportMaxPerPlayer then
                                supportLimitGroup = "PL:"
                                    .. supportItem.subjectKey;
                                supportLimitMax = math.max(
                                    0, supportMaxPerPlayer
                                        - CountPlayerDistricts(
                                            player,
                                            supportItem.subjectKey
                                        )
                                );
                            end
                            supportRequestTable = {
                                requestID = supportRequestID,
                                scope = "CITY",
                                eligibleParticipantIDs = { participantID },
                                eligibleCityIDs = { participant.cityID },
                                subjectType = MAP_PIN_TYPE_DISTRICT,
                                subjectOptions = {
                                    supportItem.subjectKey,
                                },
                                cardinalityMin = 1,
                                cardinalityMax = 1,
                                optional = true,
                                slotCost = IsPopulationDistrict(
                                    supportItem.subjectKey
                                ) and 1 or 0,
                                slotLimitByParticipant = {
                                    [participantID] = math.max(
                                        1, tonumber(
                                            participant.normalizedSlots
                                        ) or 1
                                    ),
                                },
                                priorityByParticipant = {
                                    [participantID] = 99,
                                },
                                satisfactionPredicate = "SELF",
                                coverageTarget = {},
                                supportPolicy = {},
                                mutualExclusionGroup =
                                    supportExclusionGroup,
                                limitGroup = supportLimitGroup,
                                limitMax = supportLimitMax,
                                limitScope = "PLAYER",
                            };
                        else
                            supportRequestID = "MC5:SUPPORT:"
                                .. tostring(participant.cityID) .. ":"
                                .. tostring(supportItem.subjectType) .. ":"
                                .. Key(supportItem.x, supportItem.y);
                            supportRequestTable = {
                                requestID = supportRequestID,
                                scope = "CITY",
                                eligibleParticipantIDs = { participantID },
                                eligibleCityIDs = { participant.cityID },
                                subjectType = supportItem.subjectType,
                                subjectOptions = {
                                    supportItem.subjectKey,
                                },
                                cardinalityMin = 1,
                                cardinalityMax = 1,
                                optional = true,
                                slotCost = 0,
                                slotLimitByParticipant = {
                                    [participantID] = math.max(
                                        1, tonumber(
                                            participant.normalizedSlots
                                        ) or 1
                                    ),
                                },
                                priorityByParticipant = {
                                    [participantID] = 99,
                                },
                                satisfactionPredicate = "SELF",
                                coverageTarget = {},
                                supportPolicy = {},
                            };
                        end
                        table.insert(supportRequestIDs, supportRequestID);
                        table.insert(supportParts, {
                            subjectType = supportItem.subjectType,
                            subjectKey = supportItem.subjectKey,
                            plotKey = Key(supportItem.x, supportItem.y),
                        });
                        local supportStrategy = nil;
                        if isDistrictSupport
                            and (IsDistrictOnePerCity(
                                supportItem.subjectKey
                            ) or IsUniqueDistrict(supportItem.subjectKey)) then
                            supportStrategy = supportItem.subjectKey;
                        end
                        table.insert(supports, {
                            candidate = {
                                subjectType = supportItem.subjectType,
                                subjectKey = supportItem.subjectKey,
                                plotIndex = supportItem.plot
                                    and supportItem.plot:GetIndex() or -1,
                                plotKey = Key(
                                    supportItem.x, supportItem.y
                                ),
                                planningParticipantID = participantID,
                                planningCityID = participant.cityID,
                                requestID = supportRequestID,
                                supportBundleSignature = "",
                                slotIndex = isDistrictSupport
                                    and (tonumber(
                                        (slotIndexByCity[
                                            participant.cityID
                                        ] or {})[supportItem.subjectKey]
                                    ) or 0) or 0,
                                priorityTuple = {
                                    tonumber(supportItem.districtPriority)
                                        or 1,
                                },
                                coveredParticipantIDs = {},
                                resourceVisibilityClass =
                                    supportItem.resourceClass or "NONE",
                                influenceScope = "LOCAL",
                                supportRequestIDs = {},
                                adjacentPlotKeys =
                                    AMT_MC_M3_GetAdjacentPlotKeys(
                                        supportItem.x, supportItem.y
                                    ),
                                districtStrategy = supportStrategy or nil,
                                strategyLimitByParticipant =
                                    supportStrategy and 1 or nil,
                                isSupport = true,
                                legacy = supportItem,
                            },
                            request = supportRequestTable,
                        });
                    end
                    if not sameCityOK then
                        table.insert(skippedNotes, Locale.Lookup(
                            "LOC_AMT_MC_M5_SKIP_CROSS_CITY",
                            wonderDisplay,
                            tostring(participant.name)
                        ));
                    else
                        table.insert(contractList, {
                            subjectType = MAP_PIN_TYPE_WONDER,
                            subjectKey = wonderType,
                            plotIndex = variant.plot
                                and variant.plot:GetIndex() or -1,
                            plotKey = Key(variant.x, variant.y),
                            planningParticipantID = participantID,
                            planningCityID = participant.cityID,
                            requestID = wonderRequest.requestID,
                            supportBundleSignature =
                                AMT_MC_M5_HashSupportParts(supportParts),
                            slotIndex = 0,
                            priorityTuple = { 9 },
                            coveredParticipantIDs = {},
                            resourceVisibilityClass =
                                variant.resourceClass or "NONE",
                            influenceScope = "LOCAL",
                            supportRequestIDs = supportRequestIDs,
                            adjacentPlotKeys =
                                AMT_MC_M3_GetAdjacentPlotKeys(
                                    variant.x, variant.y
                                ),
                            supportCandidates = supports,
                            legacy = variant,
                        });
                    end
                end
            end
            if #contractList > 0 then
                table.insert(requests, wonderRequest);
                candidatesFor[wonderRequest.requestID] = contractList;
            else
                table.insert(skippedNotes, Locale.Lookup(
                    "LOC_AMT_MC_M5_SKIP_NO_SUPPORT", wonderDisplay
                ));
            end
        end
    end

    local slotsByParticipant = {};
    local deferredByParticipant = {};
    for _, participantID in ipairs(snapshot.orderedParticipantIDs or {}) do
        local participant = snapshot.participants[participantID];
        local normalizedSlots = math.max(
            1, tonumber(participant.normalizedSlots) or 1
        );
        slotsByParticipant[participantID] = normalizedSlots;
        local intent = participant.savedIntent or {};
        local deferred = {};
        for orderIndex, districtType in ipairs(
            intent.specialtyOrder or {}
        ) do
            if orderIndex > normalizedSlots
                and not AMT_MC_M6U_IsSupported(districtType) then
                table.insert(deferred, districtType);
            end
        end
        if #deferred > 0 then
            deferredByParticipant[participantID] = deferred;
        end
    end

    -- -----------------------------------------------------------------------
    -- M6U player-unique district requests (UNIQUE_DISTRICT_UI_PLAN section 8).
    -- AUTO compiles to ONE required PLAYER-scope request with every frozen
    -- participant as a candidate city; no candidate city is pre-reserved and
    -- only the winning city deducts one real specialty slot.  LOCKED_CITY
    -- compiles to the same PLAYER-scope request with a single eligible city
    -- and the real order index the glue inserted into specialtyOrder.
    -- -----------------------------------------------------------------------
    local uniqueRequests = {};
    local autoSubjects = {};
    local uniqueSubjectList = {};
    for _, subjectKey in ipairs(AMT_MC_M6U_SubjectKeys()) do
        if AMT_MC_M6U_IsSupported(subjectKey) then
            table.insert(uniqueSubjectList, subjectKey);
        end
    end
    for _, subjectKey in ipairs(uniqueSubjectList) do
        local entry = snapshot.uniqueDistrictSaved
            and snapshot.uniqueDistrictSaved[subjectKey] or nil;
        if entry and entry.mode == "AUTO" then
            table.insert(autoSubjects, subjectKey);
        end
    end
    local autoSlotIndex = AMT_MC_M6U_AssignAutoSlots(
        autoSubjects, snapshot, slotIndexByCity, slotsByParticipant
    );
    for _, subjectKey in ipairs(uniqueSubjectList) do
        local entry = snapshot.uniqueDistrictSaved
            and snapshot.uniqueDistrictSaved[subjectKey] or nil;
        local mode = entry and entry.mode or "OFF";
        if mode ~= "OFF" then
            local display = GetSubjectDisplay(
                MAP_PIN_TYPE_DISTRICT, subjectKey
            );
            local effective = AMT_MC_M6U_GetEffective(subjectKey);
            local skipKey = nil;
            if effective.source == "BUILT" then
                skipKey = "LOC_AMT_MC_M6U_SKIP_BUILT";
            elseif effective.source == "FOUNDED" then
                skipKey = "LOC_AMT_MC_M6U_SKIP_FOUNDED";
            elseif effective.source == "MANUAL_PIN" then
                skipKey = "LOC_AMT_MC_M6U_SKIP_MANUAL";
            elseif effective.source == "MANUAL_CONFLICT" then
                skipKey = "LOC_AMT_MC_M6U_SKIP_MANUAL_CONFLICT";
            elseif effective.source == "MANUAL_INVALID" then
                skipKey = "LOC_AMT_MC_M6U_SKIP_MANUAL_INVALID";
            end
            if skipKey then
                table.insert(skippedNotes, Locale.Lookup(
                    skipKey, display
                ));
            else
                local eligibleParticipants = {};
                local eligibleCities = {};
                local lockedCityID = nil;
                if mode == "LOCKED_CITY" then
                    lockedCityID = tonumber(entry.lockedCityID);
                    local foundParticipantID = nil;
                    for _, participantID in ipairs(
                        snapshot.orderedParticipantIDs or {}
                    ) do
                        local participant =
                            snapshot.participants[participantID];
                        if participant.cityID == lockedCityID then
                            foundParticipantID = participantID;
                            break;
                        end
                    end
                    if not foundParticipantID then
                        table.insert(skippedNotes, Locale.Lookup(
                            "LOC_AMT_MC_M6U_SKIP_LOCKED_MISSING",
                            display
                        ));
                    else
                        table.insert(eligibleParticipants,
                            foundParticipantID);
                        table.insert(eligibleCities, lockedCityID);
                    end
                else
                    eligibleParticipants = CopyArray(
                        snapshot.orderedParticipantIDs or {}
                    );
                    eligibleCities = CopyArray(
                        snapshot.realCityIDs or {}
                    );
                end
                if #eligibleParticipants > 0 then
                    local remaining = math.max(
                        0, (GetDistrictMaxPerPlayer(subjectKey) or 1)
                            - CountPlayerDistricts(player, subjectKey)
                    );
                    if remaining <= 0 then
                        table.insert(skippedNotes, Locale.Lookup(
                            "LOC_AMT_MC_M6U_SKIP_PLAYER_LIMIT",
                            display
                        ));
                    else
                        local slotMap = {};
                        local priorityMap = {};
                        local orderMaps = {};
                        for _, participantID in ipairs(
                            eligibleParticipants
                        ) do
                            local participant =
                                snapshot.participants[participantID];
                            slotMap[participantID] = math.max(
                                1, tonumber(participant.normalizedSlots)
                                    or 1
                            );
                            priorityMap[participantID] = 7;
                            orderMaps[participant.cityID] = {
                                [subjectKey] = 99,
                            };
                        end
                        local uniqueRequest = {
                            requestID = "MCU:PLAYERUNIQUE:" .. subjectKey,
                            scope = "PLAYER",
                            eligibleParticipantIDs = eligibleParticipants,
                            eligibleCityIDs = eligibleCities,
                            subjectType = MAP_PIN_TYPE_DISTRICT,
                            subjectOptions = { subjectKey },
                            cardinalityMin = 1,
                            cardinalityMax = 1,
                            optional = false,
                            slotCost = IsPopulationDistrict(subjectKey)
                                and 1 or 0,
                            slotLimitByParticipant = slotMap,
                            priorityByParticipant = priorityMap,
                            satisfactionPredicate = "SELF",
                            coverageTarget = {},
                            supportPolicy = {},
                            mutualExclusionGroup =
                                exclusionGroups[subjectKey] or nil,
                            influenceScope = "CITY",
                            limitGroup = "PL:" .. subjectKey,
                            limitMax = remaining,
                            limitScope = "PLAYER",
                            subjectPriorities = { [subjectKey] = 99 },
                            subjectOrdersByCity = orderMaps,
                            cities = cityList,
                            districtStrategy = subjectKey,
                            uniqueMode = mode,
                            uniqueLockedCityID = lockedCityID or nil,
                        };
                        local contractList = {};
                        for _, participantID in ipairs(
                            eligibleParticipants
                        ) do
                            local participant =
                                snapshot.participants[participantID];
                            local city = cityObjects[participant.cityID];
                            local savedCityHorizon = m_PlanningHorizon;
                            m_PlanningHorizon =
                                participant.savedIntent
                                and participant.savedIntent.horizon
                                or m_PlanningHorizon;
                            local orderIndex = (slotIndexByCity[
                                participant.cityID
                            ] or {})[subjectKey];
                            uniqueRequest.subjectPriorities =
                                { [subjectKey] = orderIndex or 99 };
                            uniqueRequest.subjectOrdersByCity = {
                                [participant.cityID] = {
                                    [subjectKey] = orderIndex or 99,
                                },
                            };
                            uniqueRequest.cities = { city };
                            local rawCandidates = BuildRawCandidates(
                                uniqueRequest, playerID, weights,
                                {}, {}, false, false,
                                fixedSubjects, autoRegistry, runCache
                            );
                            uniqueRequest.cities = cityList;
                            uniqueRequest.subjectPriorities =
                                { [subjectKey] = 99 };
                            uniqueRequest.subjectOrdersByCity = orderMaps;
                            m_PlanningHorizon = savedCityHorizon;
                            for _, raw in ipairs(rawCandidates or {}) do
                                local assignedSlot = nil;
                                if mode == "LOCKED_CITY" then
                                    assignedSlot = orderIndex or 0;
                                else
                                    assignedSlot = (autoSlotIndex[
                                        subjectKey
                                    ] or {})[participantID] or 0;
                                end
                                table.insert(contractList, {
                                    subjectType = raw.subjectType,
                                    subjectKey = raw.subjectKey,
                                    plotIndex = raw.plot
                                        and raw.plot:GetIndex() or -1,
                                    plotKey = Key(raw.x, raw.y),
                                    planningParticipantID = participantID,
                                    planningCityID = participant.cityID,
                                    requestID = uniqueRequest.requestID,
                                    supportBundleSignature = "",
                                    slotIndex = assignedSlot,
                                    priorityTuple = {
                                        tonumber(raw.districtPriority)
                                            or 9,
                                    },
                                    coveredParticipantIDs = {},
                                    resourceVisibilityClass =
                                        raw.resourceClass or "NONE",
                                    influenceScope = "LOCAL",
                                    supportRequestIDs = {},
                                    adjacentPlotKeys =
                                        AMT_MC_M3_GetAdjacentPlotKeys(
                                            raw.x, raw.y
                                        ),
                                    districtStrategy = subjectKey,
                                    strategyLimitByParticipant = 1,
                                    legacy = raw,
                                });
                            end
                        end
                        -- A required unique request stays in the request
                        -- list even with zero legal tiles so the solver
                        -- reports an explicit NO_PLAN instead of silently
                        -- cancelling the player's AUTO/LOCKED intent.
                        table.insert(requests, uniqueRequest);
                        candidatesFor[uniqueRequest.requestID] =
                            contractList;
                        table.insert(uniqueRequests, {
                            subjectKey = subjectKey,
                            mode = mode,
                            lockedCityID = lockedCityID or nil,
                            requestID = uniqueRequest.requestID,
                        });
                        if #contractList == 0 then
                            table.insert(skippedNotes, Locale.Lookup(
                                "LOC_AMT_MC_M6U_SKIP_NO_TILE",
                                display,
                                mode == "LOCKED_CITY"
                                    and AMT_MC_M6U_CityName(lockedCityID)
                                    or Locale.Lookup(
                                        "LOC_AMT_MC_M6U_AUTO_CITIES"
                                    )
                            ));
                        end
                    end
                end
            end
        end
    end

    for _, participantID in ipairs(snapshot.orderedParticipantIDs or {}) do
        local participant = snapshot.participants[participantID];
        local cityID = participant.cityID;
        local city = cityObjects[cityID];
        local intent = participant.savedIntent or {};
        local slots = math.max(
            1, tonumber(participant.normalizedSlots) or 1
        );
        if slots > slotLevels then slotLevels = slots; end
        local locked = {};
        for _, districtType in ipairs(
            participant.foundedSpecialtyTypes or {}
        ) do
            locked[districtType] = true;
        end
        for _, districtType in ipairs(
            participant.manualPinnedSpecialtyTypes or {}
        ) do
            locked[districtType] = true;
        end
        local entries = {};
        local seen = {};
        for index, districtType in ipairs(intent.specialtyOrder or {}) do
            if not seen[districtType] then
                seen[districtType] = true;
                table.insert(entries, {
                    districtType = districtType,
                    required = not locked[districtType]
                        and index <= slots,
                    priority = index,
                });
            end
        end
        local others = {};
        for districtType, selected in pairs(
            (intent.selectedSubjects or {})[MAP_PIN_TYPE_DISTRICT] or {}
        ) do
            if selected == true and not seen[districtType] then
                table.insert(others, districtType);
            end
        end
        table.sort(others);
        for _, districtType in ipairs(others) do
            seen[districtType] = true;
            table.insert(entries, {
                districtType = districtType,
                required = false,
                priority = 99,
            });
        end
        m_PlanningHorizon = intent.horizon or m_PlanningHorizon;
        for _, entry in ipairs(entries) do
            local districtType = entry.districtType;
            local cityDisplay = tostring(participant.name or cityID);
            if AMT_MC_M6U_IsSupported(districtType) then
                -- M6U owns these subjects; never compile a second legacy
                -- per-city CITY request for them.
                table.insert(skippedNotes, Locale.Lookup(
                    "LOC_AMT_MC_M6U_SKIP_HANDLED_BY_UNIQUE",
                    GetSubjectDisplay(MAP_PIN_TYPE_DISTRICT, districtType)
                ));
            elseif locked[districtType] then
                table.insert(skippedNotes, Locale.Lookup(
                    "LOC_AMT_MC_M3_SKIP_LOCKED",
                    GetSubjectDisplay(MAP_PIN_TYPE_DISTRICT, districtType),
                    cityDisplay
                ));
            else
                local maxPerPlayer = GetDistrictMaxPerPlayer(districtType);
                local limitGroup = nil;
                local limitMax = nil;
                local limitReached = false;
                if maxPerPlayer then
                    local existing = CountPlayerDistricts(
                        player, districtType
                    );
                    local remaining = math.max(
                        0, maxPerPlayer - existing
                    );
                    if remaining <= 0 then
                        limitReached = true;
                        table.insert(skippedNotes, Locale.Lookup(
                            "LOC_AMT_MC_M3_SKIP_PLAYER_LIMIT",
                            GetSubjectDisplay(
                                MAP_PIN_TYPE_DISTRICT, districtType
                            ),
                            cityDisplay
                        ));
                    else
                        limitGroup = "PL:" .. districtType;
                        limitMax = remaining;
                    end
                end
                if not limitReached then
                    local exclusionGroup = exclusionGroups[districtType];
                    local strategy = nil;
                    if IsDistrictOnePerCity(districtType)
                        or IsUniqueDistrict(districtType) then
                        strategy = districtType;
                    end
                    local request = {
                        requestID = "MC3:" .. participantID
                            .. ":DISTRICT:" .. districtType,
                        scope = "CITY",
                        eligibleParticipantIDs = { participantID },
                        eligibleCityIDs = { cityID },
                        subjectType = MAP_PIN_TYPE_DISTRICT,
                        subjectOptions = { districtType },
                        cardinalityMin = entry.required and 1 or 0,
                        cardinalityMax = 1,
                        optional = not entry.required,
                        slotCost = IsPopulationDistrict(districtType)
                            and 1 or 0,
                        slotLimitByParticipant = {
                            [participantID] = slots,
                        },
                        priorityByParticipant = {
                            [participantID] = entry.priority,
                        },
                        satisfactionPredicate = "SELF",
                        coverageTarget = {},
                        supportPolicy = {},
                        mutualExclusionGroup = exclusionGroup,
                        influenceScope = "LOCAL",
                        limitGroup = limitGroup,
                        limitMax = limitMax,
                        limitScope = "PLAYER",
                        subjectPriorities = {
                            [districtType] = entry.priority,
                        },
                        subjectOrdersByCity = {
                            [cityID] = {
                                [districtType] = entry.priority,
                            },
                        },
                        cities = { city },
                        districtStrategy = strategy,
                    };
                    local rawCandidates = BuildRawCandidates(
                        request, playerID, weights, {}, {}, false, false,
                        fixedSubjects, autoRegistry, runCache
                    );
                    local contractList = {};
                    for _, raw in ipairs(rawCandidates or {}) do
                        table.insert(contractList, {
                            subjectType = raw.subjectType,
                            subjectKey = raw.subjectKey,
                            plotIndex = raw.plot
                                and raw.plot:GetIndex() or -1,
                            plotKey = Key(raw.x, raw.y),
                            planningParticipantID = participantID,
                            planningCityID = cityID,
                            requestID = request.requestID,
                            supportBundleSignature = "",
                            slotIndex = tonumber(
                                (slotIndexByCity[cityID] or {})[
                                    districtType
                                ]
                            ) or 0,
                            priorityTuple = {
                                tonumber(raw.districtPriority) or 1,
                            },
                            coveredParticipantIDs = {},
                            resourceVisibilityClass =
                                raw.resourceClass or "NONE",
                            influenceScope = "LOCAL",
                            supportRequestIDs = {},
                            adjacentPlotKeys =
                                AMT_MC_M3_GetAdjacentPlotKeys(
                                    raw.x, raw.y
                                ),
                            districtStrategy = strategy or nil,
                            strategyLimitByParticipant =
                                strategy and 1 or nil,
                            legacy = raw,
                        });
                    end
                    if #contractList == 0 then
                        table.insert(skippedNotes, Locale.Lookup(
                            "LOC_AMT_MC_M3_SKIP_NO_TILE",
                            GetSubjectDisplay(
                                MAP_PIN_TYPE_DISTRICT, districtType
                            ),
                            cityDisplay
                        ));
                        if entry.required then
                            table.insert(skippedNotes, Locale.Lookup(
                                "LOC_AMT_MC_M3_SKIP_REQUIRED_DROPPED",
                                GetSubjectDisplay(
                                    MAP_PIN_TYPE_DISTRICT, districtType
                                ),
                                cityDisplay
                            ));
                        end
                    else
                        table.insert(requests, request);
                        candidatesFor[request.requestID] = contractList;
                    end
                end
            end
        end
    end
    m_PlanningHorizon = savedHorizon;

    -- -----------------------------------------------------------------------
    -- M4 coverage requests (plan 8.1): one CLUSTER request per coverage
    -- district type selected by any participant.  Candidates are generated
    -- per city (the legacy dedup key lacks cityID, so a single multi-city
    -- scan would silently drop one city's ownership on shared plots).
    -- -----------------------------------------------------------------------
    local coverageTypes = {};
    for _, participantID in ipairs(snapshot.orderedParticipantIDs or {}) do
        local participant = snapshot.participants[participantID];
        local intent = participant.savedIntent or {};
        local lockedCoverage = {};
        for _, districtType in ipairs(
            participant.foundedSpecialtyTypes or {}
        ) do
            lockedCoverage[districtType] = true;
        end
        for _, districtType in ipairs(
            participant.manualPinnedSpecialtyTypes or {}
        ) do
            lockedCoverage[districtType] = true;
        end
        for _, districtType in ipairs(intent.specialtyOrder or {}) do
            if IsCoverageDistrict(districtType)
                and not lockedCoverage[districtType] then
                coverageTypes[districtType] = true;
            end
        end
        for districtType, selected in pairs(
            (intent.selectedSubjects or {})[MAP_PIN_TYPE_DISTRICT] or {}
        ) do
            if selected == true and IsCoverageDistrict(districtType)
                and not lockedCoverage[districtType] then
                coverageTypes[districtType] = true;
            end
        end
    end
    local coverageTypeList = {};
    for districtType in pairs(coverageTypes) do
        table.insert(coverageTypeList, districtType);
    end
    table.sort(coverageTypeList);
    for _, districtType in ipairs(coverageTypeList) do
        local service = GetDistrictStrategyType(districtType);
        coverageServices[service] = true;
        local slotMap = {};
        local priorityMap = {};
        local orderMaps = {};
        for _, participantID in ipairs(
            snapshot.orderedParticipantIDs or {}
        ) do
            local participant = snapshot.participants[participantID];
            slotMap[participantID] = math.max(
                1, tonumber(participant.normalizedSlots) or 1
            );
            priorityMap[participantID] = 50;
            orderMaps[participant.cityID] = {
                [districtType] = 50,
            };
        end
        local strategy = nil;
        if IsDistrictOnePerCity(districtType)
            or IsUniqueDistrict(districtType) then
            strategy = districtType;
        end
        local coverageRequest = {
            requestID = "MC4:" .. service .. ":COVERAGE",
            scope = "CLUSTER",
            eligibleParticipantIDs = CopyArray(
                snapshot.orderedParticipantIDs or {}
            ),
            eligibleCityIDs = CopyArray(snapshot.realCityIDs or {}),
            subjectType = MAP_PIN_TYPE_DISTRICT,
            subjectOptions = { districtType },
            cardinalityMin = 0,
            cardinalityMax = #snapshot.orderedParticipantIDs,
            optional = true,
            slotCost = IsPopulationDistrict(districtType) and 1 or 0,
            slotLimitByParticipant = slotMap,
            priorityByParticipant = priorityMap,
            satisfactionPredicate = "COVERAGE",
            coverageTarget = { service = service, radius = 6 },
            supportPolicy = {},
            mutualExclusionGroup = exclusionGroups[districtType],
            influenceScope = "LOCAL",
            subjectPriorities = { [districtType] = 50 },
            subjectOrdersByCity = orderMaps,
            cities = cityList,
            districtStrategy = strategy,
        };
        local contractList = {};
        for _, participantID in ipairs(
            snapshot.orderedParticipantIDs or {}
        ) do
            local participant = snapshot.participants[participantID];
            local city = cityObjects[participant.cityID];
            local savedCityHorizon = m_PlanningHorizon;
            m_PlanningHorizon = participant.savedIntent
                and participant.savedIntent.horizon
                or m_PlanningHorizon;
            coverageRequest.cities = { city };
            local rawCandidates = BuildRawCandidates(
                coverageRequest, playerID, weights, {}, {}, false, false,
                fixedSubjects, autoRegistry, runCache
            );
            coverageRequest.cities = cityList;
            m_PlanningHorizon = savedCityHorizon;
            for _, raw in ipairs(rawCandidates or {}) do
                local covered = {};
                local serviceBaseline = baselineCovered[service] or {};
                for _, otherID in ipairs(
                    snapshot.orderedParticipantIDs or {}
                ) do
                    local other = snapshot.participants[otherID];
                    if not serviceBaseline[other.cityID]
                        and Map.GetPlotDistance(
                            raw.x, raw.y, other.centerX, other.centerY
                        ) <= 6 then
                        table.insert(covered, otherID);
                    end
                end
                table.insert(contractList, {
                    subjectType = raw.subjectType,
                    subjectKey = raw.subjectKey,
                    plotIndex = raw.plot and raw.plot:GetIndex() or -1,
                    plotKey = Key(raw.x, raw.y),
                    planningParticipantID = participantID,
                    planningCityID = participant.cityID,
                    requestID = coverageRequest.requestID,
                    supportBundleSignature = "",
                    slotIndex = tonumber(
                        (slotIndexByCity[participant.cityID] or {})[
                            districtType
                        ]
                    ) or 0,
                    priorityTuple = {
                        tonumber(raw.districtPriority) or 50,
                    },
                    coveredParticipantIDs = covered,
                    coverageService = service,
                    resourceVisibilityClass = raw.resourceClass or "NONE",
                    influenceScope = "LOCAL",
                    supportRequestIDs = {},
                    adjacentPlotKeys = AMT_MC_M3_GetAdjacentPlotKeys(
                        raw.x, raw.y
                    ),
                    districtStrategy = strategy or nil,
                    strategyLimitByParticipant = strategy and 1 or nil,
                    legacy = raw,
                });
            end
        end
        if #contractList > 0 then
            table.insert(requests, coverageRequest);
            candidatesFor[coverageRequest.requestID] = contractList;
        else
            table.insert(skippedNotes, Locale.Lookup(
                "LOC_AMT_MC_M3_SKIP_NO_TILE",
                GetSubjectDisplay(MAP_PIN_TYPE_DISTRICT, districtType),
                Locale.Lookup("LOC_AMT_MC_M4_COVERAGE_CITIES")
            ));
        end
    end

    -- -----------------------------------------------------------------------
    -- M6 improvement requests (plan 8.3): per-city budgets derived from each
    -- participant's futurePopulation; solved in stage two, seeded on every
    -- stage-one plan.  Budgets never pool across cities (rule 7).
    -- -----------------------------------------------------------------------
    local improvementRequests = {};
    local improvementBudgets = {};
    local existingImprovementCountByCity = {};
    for _, subject in ipairs(fixedSubjects or {}) do
        if subject.Type == MAP_PIN_TYPE_IMPROVEMENT
            and cityIDToParticipant[subject.CityID] then
            existingImprovementCountByCity[subject.CityID] =
                (existingImprovementCountByCity[subject.CityID] or 0) + 1;
        end
    end
    for _, participantID in ipairs(snapshot.orderedParticipantIDs or {}) do
        local participant = snapshot.participants[participantID];
        local intent = participant.savedIntent or {};
        local targetCount = AMT_GetTargetImprovementPlotCount(
            tonumber(participant.futurePopulation) or 1
        );
        local budget = math.max(
            0, targetCount
                - (existingImprovementCountByCity[participant.cityID] or 0)
        );
        improvementBudgets[participantID] = budget;
        local improvementTypes = {};
        for improvementType, selected in pairs(
            intent.improvementSelections or {}
        ) do
            if selected == true then
                table.insert(improvementTypes, improvementType);
            end
        end
        table.sort(improvementTypes);
        if budget <= 0 then
            if #improvementTypes > 0 then
                table.insert(skippedNotes, Locale.Lookup(
                    "LOC_AMT_MC_M6_SKIP_NO_BUDGET",
                    tostring(tonumber(participant.futurePopulation) or 1),
                    tostring(participant.name)
                ));
            end
        else
            local city = cityObjects[participant.cityID];
            for _, improvementType in ipairs(improvementTypes) do
                local request = {
                    requestID = "MC6:" .. participantID
                        .. ":IMPROVEMENT:" .. improvementType,
                    scope = "CITY",
                    eligibleParticipantIDs = { participantID },
                    eligibleCityIDs = { participant.cityID },
                    subjectType = MAP_PIN_TYPE_IMPROVEMENT,
                    subjectOptions = { improvementType },
                    cardinalityMin = 0,
                    cardinalityMax = budget,
                    optional = true,
                    slotCost = 0,
                    budgetByParticipant = {
                        [participantID] = budget,
                    },
                    priorityByParticipant = {
                        [participantID] = 50,
                    },
                    satisfactionPredicate = "SELF",
                    coverageTarget = {},
                    supportPolicy = {},
                    influenceScope = "LOCAL",
                    subjectPriorities = {
                        [improvementType] = 50,
                    },
                    subjectOrdersByCity = {},
                    cities = { city },
                };
                local savedCityHorizon = m_PlanningHorizon;
                m_PlanningHorizon = intent.horizon or m_PlanningHorizon;
                local rawCandidates = BuildRawCandidates(
                    request, playerID, weights, {}, {}, false, false,
                    fixedSubjects, autoRegistry, runCache
                );
                m_PlanningHorizon = savedCityHorizon;
                local contractList = {};
                for _, raw in ipairs(rawCandidates or {}) do
                    local resourceRank = 1;
                    if raw.resourceClass == "RESOURCECLASS_STRATEGIC" then
                        resourceRank = 3;
                    elseif raw.resourceClass == "RESOURCECLASS_BONUS"
                        or raw.resourceClass == "RESOURCECLASS_LUXURY" then
                        resourceRank = 2;
                    end
                    local strategicType = nil;
                    if raw.resourceClass == "RESOURCECLASS_STRATEGIC" then
                        local okRes, resource = pcall(
                            ImprovementPlacement
                                .GetActualVisibleResource,
                            raw.plot, playerID
                        );
                        if okRes and resource then
                            strategicType = resource.ResourceType;
                        end
                    end
                    table.insert(contractList, {
                        subjectType = raw.subjectType,
                        subjectKey = raw.subjectKey,
                        plotIndex = raw.plot
                            and raw.plot:GetIndex() or -1,
                        plotKey = Key(raw.x, raw.y),
                        planningParticipantID = participantID,
                        planningCityID = participant.cityID,
                        requestID = request.requestID,
                        supportBundleSignature = "",
                        slotIndex = 0,
                        priorityTuple = { resourceRank, 1 },
                        coveredParticipantIDs = {},
                        resourceVisibilityClass =
                            raw.resourceClass or "NONE",
                        influenceScope = "LOCAL",
                        supportRequestIDs = {},
                        adjacentPlotKeys =
                            AMT_MC_M3_GetAdjacentPlotKeys(raw.x, raw.y),
                        strategicResourceType = strategicType or nil,
                        legacy = raw,
                    });
                end
                if #contractList > 0 then
                    table.insert(improvementRequests, request);
                    candidatesFor[request.requestID] = contractList;
                else
                    table.insert(skippedNotes, Locale.Lookup(
                        "LOC_AMT_MC_M3_SKIP_NO_TILE",
                        GetSubjectDisplay(
                            MAP_PIN_TYPE_IMPROVEMENT, improvementType
                        ),
                        tostring(participant.name)
                    ));
                end
            end
        end
    end

    return {
        requests = requests,
        candidatesFor = candidatesFor,
        weights = weights,
        fixedSubjects = fixedSubjects,
        runCache = runCache,
        slotLevels = slotLevels,
        skippedNotes = skippedNotes,
        coverageServices = coverageServices,
        baselineCovered = baselineCovered,
        participantsMap = participantsMap,
        improvementRequests = improvementRequests,
        improvementBudgets = improvementBudgets,
        uniqueRequests = uniqueRequests,
        deferredByParticipant = deferredByParticipant,
        governmentHubPotentials =
            AMT_MultiCity.Solver.BuildGovernmentHubPotentials(
                candidatesFor
            ),
        scoreOptions = {
            scopeCities = cityList,
            baselineCovered = baselineCovered,
        },
    };
end

-- Lenient multi-city layout evaluator used only when the whole-layout
-- EvaluatePlan simulation throws (stage SIMULATION_ERROR, e.g. DMT's
-- GetTileYieldPenalty hitting a projected plot without GetYield).
-- Legality stays strict: every item must pass DMT's per-item CanPlacePin
-- under the full projected overlay (rule 7: DMT final judgement).  Scoring
-- is lenient per item: a bonus-yield computation that throws drops that
-- item's score contribution instead of voiding the whole layout.  This
-- mirrors the workshop GermanyPlanner's EvaluateLayoutLenient strategy.
function AMT_MC_M3_EvaluateLayoutLenient(
    playerID, items, weights, fixedSubjects, runCache, skipLegality
)
    if type(items) ~= "table" or #items == 0 then
        return 0;
    end
    local overlay = {};
    local fixedByKey = {};
    for _, subject in ipairs(fixedSubjects or {}) do
        local key = Key(subject.X, subject.Y);
        overlay[key] = subject;
        fixedByKey[key] = subject;
    end
    local seenKeys = {};
    for _, item in ipairs(items) do
        local key = Key(item.x, item.y);
        if seenKeys[key] then
            return nil;
        end
        seenKeys[key] = true;
        overlay[key] = MakePinSubject(item);
    end

    local ok, result = pcall(function()
        return WithSimulationOverlay(playerID, overlay, nil, function()
            local total = 0;
            for _, item in ipairs(items) do
                local subject = overlay[Key(item.x, item.y)];
                if not skipLegality then
                    local checkOK, canPlace = pcall(
                        CanPlacePin, playerID, subject
                    );
                    if not checkOK or canPlace ~= true then
                        return nil;
                    end
                end
                local yieldOK, yields = pcall(
                    AMT_GetPlannerBonusYields,
                    playerID, subject, runCache
                );
                if yieldOK and type(yields) == "table" then
                    local multiplier = 1;
                    if item.subjectType == MAP_PIN_TYPE_DISTRICT then
                        if item.isSpecialty then
                            local order = tonumber(
                                item.specialtyOrder
                            ) or 99;
                            multiplier = 6
                                + math.max(0, 4 - math.min(order, 4)) * 1.5;
                        end
                    elseif item.subjectType == MAP_PIN_TYPE_IMPROVEMENT then
                        multiplier = 0.30;
                    elseif item.subjectType == MAP_PIN_TYPE_WONDER then
                        multiplier = 1.25;
                    end
                    total = total + AMT_GetWeightedYieldScore(
                        nil, yields, weights, multiplier
                    );
                end
            end
            return total;
        end);
    end);
    if not ok then
        Log("AMT_MC_M3 lenient evaluator error: " .. tostring(result));
        return nil;
    end
    return result;
end

-- Strict one-shot verification of the FINAL best layout only (rule 7: DMT's
-- final judgement).  Candidates were pre-validated during scanning and the
-- search guarantees non-overlapping plots, so the search itself uses the
-- skipLegality scoring path; this function re-runs CanPlacePin under the
-- complete projected overlay before the preview is shown.
function AMT_MC_M3_VerifyFinalLayout(playerID, items, fixedSubjects)
    if type(items) ~= "table" or #items == 0 then
        return true;
    end
    local overlay = {};
    for _, subject in ipairs(fixedSubjects or {}) do
        overlay[Key(subject.X, subject.Y)] = subject;
    end
    local seenKeys = {};
    for _, item in ipairs(items) do
        local key = Key(item.x, item.y);
        if seenKeys[key] then
            return false, { x = item.x, y = item.y, reason = "overlap" };
        end
        seenKeys[key] = true;
        overlay[key] = MakePinSubject(item);
    end
    local ok, failure = pcall(function()
        return WithSimulationOverlay(playerID, overlay, nil, function()
            for _, item in ipairs(items) do
                local subject = overlay[Key(item.x, item.y)];
                local checkOK, canPlace = pcall(
                    CanPlacePin, playerID, subject
                );
                if not checkOK or canPlace ~= true then
                    return {
                        x = item.x,
                        y = item.y,
                        subjectKey = item.subjectKey,
                        reason = tostring(canPlace),
                    };
                end
            end
            return nil;
        end);
    end);
    if not ok then
        return false, { reason = tostring(failure) };
    end
    if failure ~= nil then
        return false, failure;
    end
    return true;
end

-- DMT-backed evaluator: converts a contract state back to legacy items and
-- asks EvaluatePlan (which embeds the full DMT projection verdict) for the
-- joint score.  Only fully legal layouts return legal=true.
function AMT_MC_M3_PrepareLegacyItem(item)
    if not item then
        return item;
    end
    -- Solver state copies can retain a plain Lua snapshot in item.plot.  It
    -- is non-nil, but it is not the Civ VI plot userdata and therefore has
    -- no GetX/GetYield methods.  Always rehydrate such proxies from stable
    -- coordinates before DMT legality, resource, or tile-yield evaluation.
    local plot = item.plot;
    local isEnginePlot = plot ~= nil
        and type(plot.GetX) == "function"
        and type(plot.GetY) == "function"
        and type(plot.GetYield) == "function"
        and type(plot.GetResourceType) == "function";
    if isEnginePlot then return item; end
    if item.x == nil or item.y == nil then
        AMT_MC_M3State.missingPlotCount =
            (AMT_MC_M3State.missingPlotCount or 0) + 1;
        if AMT_MC_M3State.missingPlotCount <= 3 then

        end
        return item;
    end
    item.plot = Map.GetPlot(item.x, item.y);
    AMT_MC_M3State.repairedPlotCount =
        (AMT_MC_M3State.repairedPlotCount or 0) + 1;
    if AMT_MC_M3State.repairedPlotCount <= 3 then

    end
    return item;
end

-- Runtime planner items contain Civ VI plot proxies and are intentionally
-- kept outside the pure solver candidate graph.  This prevents every beam
-- branch from recursively copying the same large adapter object while the
-- stable candidate ID still provides an exact lookup.
function AMT_MC_M3_DetachRuntimeLegacy(inputs)
    if type(inputs) ~= "table" then return 0; end
    inputs.legacyByCandidateID = inputs.legacyByCandidateID or {};
    local seen = {};
    local detached = 0;
    local function DetachCandidate(candidate)
        if type(candidate) ~= "table" or seen[candidate] then return; end
        seen[candidate] = true;
        local candidateID = candidate.candidateID
            or AMT_MultiCity.Solver.CandidateID(candidate);
        candidate.candidateID = candidateID;
        if candidate.legacy ~= nil then
            inputs.legacyByCandidateID[candidateID] = candidate.legacy;
            candidate.legacy = nil;
            detached = detached + 1;
        end
        for _, supportEntry in ipairs(candidate.supportCandidates or {}) do
            DetachCandidate(supportEntry.candidate);
        end
    end
    for _, candidates in pairs(inputs.candidatesFor or {}) do
        for _, candidate in ipairs(candidates or {}) do
            DetachCandidate(candidate);
        end
    end
    inputs.detachedLegacyCount = detached;
    return detached;
end

function AMT_MC_M3_GetLegacyItem(solverItem, inputs)
    local candidate = solverItem and solverItem.candidate or nil;
    local legacy = candidate and candidate.legacy or nil;
    if legacy == nil and candidate and inputs
        and inputs.legacyByCandidateID then
        local candidateID = candidate.candidateID
            or AMT_MultiCity.Solver.CandidateID(candidate);
        legacy = inputs.legacyByCandidateID[candidateID];
    end
    return AMT_MC_M3_PrepareLegacyItem(legacy);
end

function AMT_MC_M3_CollectLegacyItems(state, inputs)
    local items = {};
    for _, solverItem in ipairs(state and state.items or {}) do
        table.insert(items, AMT_MC_M3_GetLegacyItem(solverItem, inputs));
    end
    return items;
end

-- The solver only consumes DMT's numeric verdict.  Re-evaluate each final
-- selectable layout once so the map preview receives the same per-pin bonus
-- yields as the single-city report instead of an empty "no adjacency" table.
function AMT_MC_M3_AttachPreviewYields(playerID, state, inputs)
    if type(state) ~= "table" or type(inputs) ~= "table" then
        return false;
    end
    local score, yieldsByItem, diagnostic = EvaluatePlan(
        playerID, AMT_MC_M3_CollectLegacyItems(state, inputs),
        inputs.weights, {}, inputs.fixedSubjects,
        inputs.runCache, inputs.scoreOptions
    );
    if type(score) ~= "number" or score == -math.huge
        or type(yieldsByItem) ~= "table" then
        state.previewYieldsUnavailable = true;
        state.displayYieldsByItem = nil;

        return false;
    end
    state.previewYieldsUnavailable = nil;
    state.displayYieldsByItem = yieldsByItem;
    return true;
end

function AMT_MC_M3_MakeEvaluator(playerID, inputs)
    local simulationBroken = false;
    return function(state, requestsForState)
        local items = {};
        for _, item in ipairs(state.items or {}) do
            table.insert(items, AMT_MC_M3_GetLegacyItem(item, inputs));
        end
        local score = nil;
        local diagnostic = nil;
        local evaluatorPath = "DMT";
        if not simulationBroken then
            score, _, diagnostic = EvaluatePlan(
                playerID, items, inputs.weights, {},
                inputs.fixedSubjects, inputs.runCache, inputs.scoreOptions
            );
            if type(diagnostic) == "table"
                and diagnostic.stage == "SIMULATION_ERROR" then
                simulationBroken = true;

            else
                AMT_MC_M3State.fullEvaluationCount =
                    (AMT_MC_M3State.fullEvaluationCount or 0) + 1;
            end
        end
        if simulationBroken and (score == nil or score == -math.huge) then
            local fallbackOK, fallbackScore = pcall(
                AMT_MC_M3_EvaluateLayoutLenient,
                playerID, items, inputs.weights,
                inputs.fixedSubjects, inputs.runCache, true
            );
            if fallbackOK and type(fallbackScore) == "number" then
                score = fallbackScore;
                evaluatorPath = "FALLBACK_LENIENT";
                AMT_MC_M3State.fallbackCount =
                    (AMT_MC_M3State.fallbackCount or 0) + 1;
                if AMT_MC_M3State.fallbackCount <= 3 then

                end
            end
        end
        if score == nil then score = -math.huge; end
        local redundant = 0;
        for _, item in ipairs(state.items or {}) do
            if item.request.optional and not item.candidate.isSupport then
                redundant = redundant + 1;
            end
        end
        local gap = 0;
        if AMT_MultiCity.Solver
            and AMT_MultiCity.Solver.CoverageGap then
            gap = AMT_MultiCity.Solver.CoverageGap(
                state, inputs.coverageServices or {},
                inputs.participantsMap or {},
                inputs.baselineCovered or {}
            );
        end
        local strategic = 0;
        for _, counts in pairs(
            state.strategicResourceCountsByParticipant or {}
        ) do
            for resourceType in pairs(counts or {}) do
                strategic = strategic + 1;
            end
        end
        local verdict = {
            legal = score > -math.huge,
            score = score,
            redundantItemCount = redundant,
            coverageGap = gap,
            strategicDeveloped = strategic,
            evaluatorPath = evaluatorPath,
        };
        return verdict;
    end;
end

-- Runs the joint solve synchronously (inside the worker coroutine).
-- Call ONLY with no active simulation overlay / protected C-call stack.
function AMT_MC_M3_YieldBoundary(stage, force)
    if not coroutine or not coroutine.running then return; end
    local thread, isMain = coroutine.running();
    if not thread or isMain then return; end
    local state = AMT_MC_M3State;
    local now = os and os.clock and os.clock() or nil;
    state.boundaryCount = (state.boundaryCount or 0) + 1;
    if force or (now and (state.boundaryClock == nil
        or now - state.boundaryClock >= 0.020))
        or state.boundaryCount >= 16 then
        coroutine.yield({ stage = stage });
        -- Suspended frame time is not work in the resumed Lua slice.
        state.boundaryClock = os and os.clock and os.clock() or nil;
        state.boundaryCount = 0;
    end
end

function AMT_MC_M3_RunJointSolve(snapshot)
    AMT_MC_M3State.boundaryClock = nil;
    AMT_MC_M3State.boundaryCount = 0;
    AMT_MC_M3_YieldBoundary(1, true);
    local playerID = Game.GetLocalPlayer();
    local savedHorizon = m_PlanningHorizon;
    local savedSuppressYield = m_SuppressPlanningYield;
    local startedClock = os and os.clock and os.clock() or 0;
    -- M6U: manual-pin changes after the scope page must invalidate the
    -- frozen snapshot and force the player back to re-confirm.  No preview
    -- may silently restore a stale AUTO/LOCKED intent.
    if AMT_MultiCity.Cluster.SnapshotStillValid(snapshot) ~= true then
        return {
            status = "SNAPSHOT_STALE",
            note = Locale.Lookup("LOC_AMT_MC_M6U_SNAPSHOT_STALE"),
        };
    end
    -- BuildRawCandidates is still synchronous inside pcall. Yield on both
    -- sides, never inside it or while its simulation context is installed.
    local buildStartedClock = os and os.clock and os.clock() or 0;
    m_SuppressPlanningYield = true;
    local buildOK, buildInputs, buildReason = pcall(
        AMT_MC_M3_BuildJointInputs, snapshot
    );
    m_SuppressPlanningYield = savedSuppressYield;
    m_PlanningHorizon = savedHorizon;
    local buildElapsed = (os and os.clock and os.clock() or buildStartedClock)
        - buildStartedClock;
    AMT_MC_M3_YieldBoundary(1, true);
    local inputs = nil;
    local reason = nil;
    if buildOK then
        inputs = buildInputs;
        reason = buildReason;
    else
        reason = buildInputs;
    end
    if not inputs then

        return { status = "INPUT_ERROR", note = reason };
    end
    local detachedLegacyCount = AMT_MC_M3_DetachRuntimeLegacy(inputs);

    AMT_MC_M3State.lastInputs = inputs;
    if #inputs.requests == 0
        and #(inputs.improvementRequests or {}) == 0 then
        return {
            status = "NO_PLAN",
            note = "no placeable district or improvement requests",
            inputs = inputs,
            diagnostics = {
                reasonCounts = {},
                unfulfilledRequired = {},
            },
        };
    end
    local evaluator = AMT_MC_M3_MakeEvaluator(playerID, inputs);
    AMT_MC_M3State.fullEvaluationCount = 0;
    AMT_MC_M3State.fallbackCount = 0;
    AMT_MC_M3State.repairedPlotCount = 0;
    AMT_MC_M3State.missingPlotCount = 0;
    AMT_MC_M3State.penaltySkipCount = 0;
    local evaluationCache = {};
    -- Cost-control adaptive beam (track 2): keep stage-one exploration near
    -- the calibrated 4-city operating point (~20k evaluations, beam 48 on
    -- 404 candidates).  Larger candidate sets lower the beam down to 16;
    -- smaller sets raise it to 64.  AMT_MC_M3State.beamWidth overrides the
    -- heuristic for experiments and corpus validation.
    local totalCandidates = 0;
    for _, candidates in pairs(inputs.candidatesFor or {}) do
        totalCandidates = totalCandidates + #candidates;
    end
    local adaptiveBeam = math.max(
        16, math.min(64, math.floor(20000 / math.max(1, totalCandidates)))
    );
    local beamWidth = tonumber(AMT_MC_M3State.beamWidth) or adaptiveBeam;
    local progressYieldClock = os and os.clock and os.clock() or nil;
    local progressWorkCount = 0;

    local config = {
        beamWidth = beamWidth,
        maxEvaluations = tonumber(AMT_MC_M3State.maxEvaluations)
            or 200000,
        participantOrder = snapshot.orderedParticipantIDs,
        slotLevels = inputs.slotLevels,
        componentPlans = 8,
        maxCombine = 512,
        poolOptions = { maxPlans = 3 },
        evaluationCache = evaluationCache,
        -- Check each new evaluation outside DMT/pcall.  The work cap applies
        -- even when an available clock is coarse or frozen; neither limit
        -- splits a single synchronous DMT evaluation.
        progressInterval = 1,
        -- Solver owns the real district/improvement phase boundaries.
        onStage = function(stage)
            AMT_MC_M3_YieldBoundary(stage, true);
            progressWorkCount = 0;
            progressYieldClock = os and os.clock and os.clock() or nil;
        end,
        onProgress = function(evaluations)
            progressWorkCount = progressWorkCount + 1;
            local now = os and os.clock and os.clock() or nil;
            local shouldYield = progressWorkCount >= 8
                or (now and (progressYieldClock == nil
                    or now - progressYieldClock >= 0.020));
            if coroutine and coroutine.running and coroutine.running() then
                if shouldYield then
                    coroutine.yield({ progress = evaluations });
                    progressWorkCount = 0;
                    progressYieldClock = os and os.clock and os.clock() or nil;
                end
            end
        end,
    };
    -- Log the full request set so player selections are visible in the
    -- game log (install detector / support diagnosis).
    for _, request in ipairs(inputs.requests or {}) do

    end
    for _, request in ipairs(inputs.improvementRequests or {}) do

    end
    for _, note in ipairs(inputs.skippedNotes or {}) do

    end
    local solveStartedClock = os and os.clock and os.clock() or 0;
    local result = nil;
    if AMT_MultiCity.Solver.TwoStageSolve then
        result = AMT_MultiCity.Solver.TwoStageSolve(
            inputs.requests,
            inputs.improvementRequests or {},
            inputs.candidatesFor, config, evaluator
        );
    else
        result = AMT_MultiCity.Solver.Solve(
            inputs.requests, inputs.candidatesFor, config, evaluator
        );
    end;
    local solveElapsed = (os and os.clock and os.clock() or solveStartedClock)
        - solveStartedClock;
    -- Give the final legality pass its own visible phase instead of leaving
    -- players on an indeterminate spinner until the preview appears.
    if coroutine and coroutine.running and coroutine.running() then
        coroutine.yield({ stage = 4 });
    end
    -- Give each existing post-solve boundary a frame before final DMT
    -- verification or preview yield capture; never yield inside its overlay.
    -- Everything below is read-only: cancellation drops the worker before
    -- preview, without batching multiple synchronous tail DMT calls per frame.
    local function TailYield()
        AMT_MC_M3_YieldBoundary(4, true);
    end
    -- Replay protocol V2 (PERFORMANCE_UX_EXECUTION_PLAN P0): record the
    -- post-solve flow so offline replay mirrors it explicitly.  The DMT
    -- verification entries stay game evidence; they are never re-run or
    -- claimed offline.
    local postProcessing = {
        sortStrategy = AMT_MultiCity.Solver.SORT_STRATEGY,
        finalVerification = {
            executed = false,
            before = {},
            removed = {},
            after = {},
        },
        governmentHub = { applied = false },
    };
    if result.status == "OK" and type(result.best) == "table" then
        TailYield();
        local verified, failure = AMT_MC_M3_VerifyFinalLayout(
            playerID, AMT_MC_M3_CollectLegacyItems(result.best, inputs),
            inputs.fixedSubjects
        );
        if not verified then
            result.status = "NO_PLAN";
            result.diagnostics = result.diagnostics or {};
            result.diagnostics.finalRejection = failure or {};

        elseif type(result.pool) == "table"
            and type(result.pool.list) == "table" then
            -- Rule 7: every selectable plan, not only the best one, gets one
            -- strict per-item DMT verification; invalid alternatives are
            -- removed from the pool instead of being shown as legal.
            postProcessing.finalVerification.executed = true;
            for _, entry in ipairs(result.pool.list) do
                postProcessing.finalVerification.before[
                    #postProcessing.finalVerification.before + 1
                ] = AMT_MultiCity.Solver.SignatureOf(entry.state);
            end
            local verifiedList = {};
            for _, entry in ipairs(result.pool.list) do
                TailYield();
                local entryOK, entryFailure = AMT_MC_M3_VerifyFinalLayout(
                    playerID,
                    entry.state
            and AMT_MC_M3_CollectLegacyItems(entry.state, inputs) or {},
                    inputs.fixedSubjects
                );
                if entryOK then
                    table.insert(verifiedList, entry);
                else

                    postProcessing.finalVerification.removed[
                        #postProcessing.finalVerification.removed + 1
                    ] = {
                        signature = AMT_MultiCity.Solver.SignatureOf(
                            entry.state),
                        subject = tostring(
                            entryFailure and entryFailure.subjectKey),
                        reason = tostring(
                            entryFailure and entryFailure.reason),
                    };
                end
            end
            result.pool.list = verifiedList;
            for _, entry in ipairs(result.pool.list) do
                postProcessing.finalVerification.after[
                    #postProcessing.finalVerification.after + 1
                ] = AMT_MultiCity.Solver.SignatureOf(entry.state);
            end
            if type(result.pool.layoutSignatures) == "table" then
                result.pool.layoutSignatures = {};
            end
            AMT_MultiCity.Solver.ApplyGovernmentHubPoolPreference(
                result,
                inputs.governmentHubPotentials,
                nil,
                config.participantOrder,
                config.slotLevels,
                inputs.requests
            );
            postProcessing.governmentHub.applied = true;
            TailYield();
        end
    end
    -- Partial-plan mode: when the strict search cannot satisfy every
    -- required request, show the best legal partial layout as a clearly
    -- marked relaxed preview instead of a bare "no plan" page.
    if result.status == "NO_PLAN"
        and type(result.partialBest) == "table" then
        TailYield();
        local partialOK, partialFailure = AMT_MC_M3_VerifyFinalLayout(
            playerID, AMT_MC_M3_CollectLegacyItems(
                result.partialBest, inputs
            ),
            inputs.fixedSubjects
        );
        if partialOK then
            result.status = "PARTIAL";
            result.partial = true;
            result.best = result.partialBest;
            result.pool = {
                maxPlans = 1,
                closeGap = 0,
                bestScore = result.partialBest.score,
                list = {
                    { state = result.partialBest, relativeGap = 0 },
                },
                layoutSignatures = {},
            };
            local fulfilledCount = 0;
            for _, request in ipairs(inputs.requests or {}) do
                if not request.optional
                    and (result.partialBest.fulfilledRequestIDs[
                        request.requestID
                    ] or 0) >= (tonumber(request.cardinalityMin) or 0) then
                    fulfilledCount = fulfilledCount + 1;
                end
            end

        else

        end
    end
    -- DMT legality and scoring stay authoritative during the search.  This
    -- final pass retains its per-item bonus-yield table for the visible map
    -- flags, matching the single-city preview presentation.
    local previewYieldStates = {};
    for _, entry in ipairs(result.pool and result.pool.list or {}) do
        if entry.state and not previewYieldStates[entry.state] then
            TailYield();
            AMT_MC_M3_AttachPreviewYields(playerID, entry.state, inputs);
            previewYieldStates[entry.state] = true;
        end
    end
    if result.best and not previewYieldStates[result.best] then
        TailYield();
        AMT_MC_M3_AttachPreviewYields(playerID, result.best, inputs);
    end
    result.inputs = inputs;
    result.postProcessing = postProcessing;

    AMT_MC_M3_YieldBoundary(4, true);
    -- Give a queued late cancel priority over opening the preview.
    AMT_MC_M3_YieldBoundary(4, true);
    return result;
end

function AMT_MC_UI_UpdateSolveStage(stage)
    local requested = math.max(1, math.min(4, tonumber(stage) or 1));
    local active = math.max(tonumber(m_MCUISolveStage) or 0, requested);
    -- Reassigning the label restarts its AlphaAnim.  Update only on a real
    -- forward transition so the breathing stays smooth and never regresses.
    if active == m_MCUISolveStage then return; end
    m_MCUISolveStage = active;
    local keys = {
        "LOC_AMT_MC_UI_STAGE_PREPARE",
        "LOC_AMT_MC_UI_STAGE_DISTRICTS",
        "LOC_AMT_MC_UI_STAGE_IMPROVEMENTS",
        "LOC_AMT_MC_UI_STAGE_VERIFY",
    };
    for index, key in ipairs(keys) do
        local control = Controls["MCPlanningStage" .. tostring(index)];
        if control then
            local marker = index < active and "✓ "
                or (index == active and "● " or "");
            control:SetText(marker .. Locale.Lookup(key));
        end
    end
    if Controls.MCPlanningStatus then
        Controls.MCPlanningStatus:SetText(Locale.Lookup(
            "LOC_AMT_MC_UI_SOLVING_STAGE", Locale.Lookup(keys[active])
        ));
    end
end

function AMT_MC_M3_BeginJointSolve(snapshot)
    AMT_MC_M3State.job = { snapshot = snapshot, worker = nil };
    -- Keep the frozen snapshot reachable after the job table is dropped so
    -- the failure page can name the city each unplaced item belongs to.
    AMT_MC_M3State.lastSnapshot = snapshot;
    AMT_MC_M3State.cancelled = nil;
    -- Block re-entry and progression interrupts while solving (the frozen
    -- snapshot must stay authoritative until the preview is shown).
    m_IsPlanning = true;
    AMT_MC_SetPhase(2);
    m_MCUISolveStage = 0;
    AMT_MC_UI_UpdateSolveStage(1);
    if Controls.PreviewConfirmButton then
        Controls.PreviewConfirmButton:SetHide(true);
    end
    Controls.MCScopeFrame:SetSizeY(405);
    Controls.MCScopeTitle:SetText(Locale.Lookup(
        "LOC_AMT_MC_M3_SOLVING_TITLE"
    ));
    Controls.MCScopeNotice:SetText(Locale.Lookup(
        "LOC_AMT_MC_M3_SOLVING_NOTICE"
    ) .. "[NEWLINE]" .. Locale.Lookup("LOC_AMT_MC_M3_SOLVING_CAVEAT"));
    Controls.MCScopeIncludedPanel:SetHide(true);
    Controls.MCScopeExcludedPanel:SetHide(true);
    Controls.MCScopeConfirmButton:SetHide(true);
    Controls.MCScopeBackButton:SetHide(false);
    Controls.MCScopeCloseButton:SetHide(true);
    Controls.MCScopeScroll:SetHide(true);
    -- r29 UX: mirror the single-city planner while the joint solve runs —
    -- pulsing status text, caveat, and one cancel button.  The scope page
    -- is hidden underneath and restored when a result or cancel arrives.
    Controls.MCScopeOverlay:SetHide(true);
    if Controls.MCPlanningOverlay then
        if Controls.MCPlanningStatus then
            Controls.MCPlanningStatus:SetText(Locale.Lookup(
                "LOC_AMT_CALCULATING_LONG"
            ));
        end
        Controls.MCPlanningOverlay:SetHide(false);
    end
    if not coroutine or not coroutine.create
        or not coroutine.resume or not coroutine.status then
        local ok, result = pcall(
            AMT_MC_M3_RunJointSolve, snapshot
        );
        AMT_MC_M3State.job = nil;
        if not ok then

            AMT_MC_M3_ShowJointFailure("INPUT_ERROR",
                { note = tostring(result) });
            return;
        end
        AMT_MC_M3_ShowJointPreview(snapshot, result);
        return;
    end
    AMT_MC_M3State.job.worker = coroutine.create(function()
        return AMT_MC_M3_RunJointSolve(snapshot);
    end);
    ContextPtr:SetUpdate(AMT_MC_M3_UpdateJoint);
end

function AMT_MC_M3_UpdateJoint()
    local job = AMT_MC_M3State.job;
    if not job then
        ContextPtr:ClearUpdate();
        return;
    end
    if AMT_MC_M3State.cancelled then
        -- The cancel button only sets the flag; the coroutine is dropped
        -- here before the next resume, so the solver never runs again.
        AMT_MC_M3State.job = nil;
        AMT_MC_M3State.cancelled = nil;
        ContextPtr:ClearUpdate();
        Log("M3 cancellation completed before resume; stage="
            .. tostring(m_MCUISolveStage));
        AMT_MC_M3_ShowJointFailure("CANCELLED", {});
        return;
    end
    local ok, result = coroutine.resume(job.worker);
    if not ok then
        AMT_MC_M3State.job = nil;
        ContextPtr:ClearUpdate();

        AMT_MC_M3_ShowJointFailure("INPUT_ERROR",
            { note = tostring(result) });
        return;
    end
    if type(result) == "table" and result.stage ~= nil then
        AMT_MC_UI_UpdateSolveStage(result.stage);
        return;
    end
    if type(result) == "table" and result.progress ~= nil then
        -- Evaluation counts restart per stage and cannot identify the stage.
        AMT_MC_M3State.lastProgress = result.progress;
        return;
    end
    if coroutine.status(job.worker) == "dead" then
        AMT_MC_M3State.job = nil;
        ContextPtr:ClearUpdate();
        AMT_MC_M3_ShowJointPreview(job.snapshot, result);
    end
end

function AMT_MC_M3_FormatJointReport(snapshot, result, planIndex)
    local lines = {};
    local list = result.pool and result.pool.list or {};
    local entry = list[planIndex];
    if not entry then
        entry = { state = result.best, relativeGap = 0 };
    end
    local state = entry.state;
    if not state then
        table.insert(lines, Locale.Lookup("LOC_AMT_MC_M3_NO_PLAN"));
        table.insert(lines, "");
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_MC_M3_REPORT_NO_PLACEMENT"
        ));
        return table.concat(lines, "[NEWLINE]");
    end
    table.insert(lines, Locale.Lookup(
        "LOC_AMT_MC_M3_REPORT_SUMMARY",
        tostring(#snapshot.realCityIDs),
        tostring(result.evaluations or 0),
        tostring(result.components or 0)
    ));
    table.insert(lines, "");
    if result.partial then
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_MC_M3_REPORT_PARTIAL_BANNER"
        ));
        local unfulfilled = result.diagnostics
            and result.diagnostics.unfulfilledRequired or {};
        if #unfulfilled > 0 then
            table.insert(lines, Locale.Lookup(
                "LOC_AMT_MC_M3_REPORT_PARTIAL_UNPLACED"
            ));
            for _, request in ipairs(unfulfilled) do
                local subjectName = "?";
                if request.subjectOptions and request.subjectOptions[1] then
                    subjectName = GetSubjectDisplay(
                        request.subjectType, request.subjectOptions[1]
                    );
                end
                local cityName = "?";
                if request.eligibleParticipantIDs
                    and request.eligibleParticipantIDs[1] then
                    local participant = snapshot.participants[
                        request.eligibleParticipantIDs[1]
                    ];
                    cityName = participant and participant.name or "?";
                end
                local reason = Locale.Lookup(
                    "LOC_AMT_MC_M3_REPORT_PARTIAL_UNKNOWN_REASON"
                );
                for _, example in ipairs(
                    result.diagnostics and result.diagnostics
                        .rejectionExamples or {}
                ) do
                    if example.requestID == request.requestID then
                        reason = example.reason;
                        break;
                    end
                end
                table.insert(lines, "  - " .. tostring(cityName)
                    .. " " .. tostring(subjectName) .. "：" .. tostring(reason));
            end
        end
        table.insert(lines, "");
    end
    for _, line in ipairs(
        AMT_MC_M6U_FormatResultUnique(snapshot, result, state)
    ) do
        table.insert(lines, line);
    end
    table.insert(lines, Locale.Lookup("LOC_AMT_MC_M3_REPORT_PER_CITY"));
    local itemsByCity = {};
    for _, item in ipairs(state.items or {}) do
        local cityID = item.candidate.planningCityID;
        itemsByCity[cityID] = itemsByCity[cityID] or {};
        table.insert(itemsByCity[cityID], item);
    end
    for _, participantID in ipairs(snapshot.orderedParticipantIDs or {}) do
        local participant = snapshot.participants[participantID];
        local cityItems = itemsByCity[participant.cityID] or {};
        table.insert(lines, "  [ICON_Capital] "
            .. tostring(participant.name));
        local names = {};
        for _, item in ipairs(cityItems) do
            table.insert(names, GetSubjectDisplay(
                item.candidate.subjectType, item.candidate.subjectKey
            ));
        end
        table.sort(names);
        table.insert(lines, "    " .. Locale.Lookup(
            "LOC_AMT_MC_M3_REPORT_PLANNED",
            #names > 0 and table.concat(names, "、")
                or Locale.Lookup("LOC_AMT_MC_REPORT_NONE")
        ));
        local deferredNames = {};
        local deferredList = result.inputs
            and result.inputs.deferredByParticipant
            and result.inputs.deferredByParticipant[participantID] or {};
        for _, districtType in ipairs(deferredList) do
            table.insert(deferredNames, GetDistrictDisplay(districtType));
        end
        if #deferredNames > 0 then
            table.insert(lines, "    " .. Locale.Lookup(
                "LOC_AMT_MC_M6U_REPORT_DEFERRED",
                table.concat(deferredNames, "、")
            ));
        end
        local wonderLines = {};
        for _, item in ipairs(cityItems) do
            if item.candidate.subjectType == MAP_PIN_TYPE_WONDER then
                local supportNames = {};
                for _, supportEntry in ipairs(
                    item.candidate.supportCandidates or {}
                ) do
                    table.insert(supportNames, GetSubjectDisplay(
                        supportEntry.candidate.subjectType,
                        supportEntry.candidate.subjectKey
                    ));
                end
                table.sort(supportNames);
                table.insert(wonderLines, Locale.Lookup(
                    "LOC_AMT_MC_M5_REPORT_WONDER_ITEM",
                    GetSubjectDisplay(
                        MAP_PIN_TYPE_WONDER, item.candidate.subjectKey
                    ),
                    #supportNames > 0
                        and table.concat(supportNames, "、")
                        or Locale.Lookup("LOC_AMT_MC_REPORT_NONE")
                ));
            end
        end
        if #wonderLines > 0 then
            table.insert(lines, "    " .. Locale.Lookup(
                "LOC_AMT_MC_M5_REPORT_WONDERS"
            ));
            for _, line in ipairs(wonderLines) do
                table.insert(lines, "      " .. line);
            end
        end
        local fulfilled = 0;
        local slotsMap = state.perParticipantSlotFulfillment[
            participantID
        ] or {};
        for slotIndex in pairs(slotsMap) do
            fulfilled = fulfilled + 1;
        end
        table.insert(lines, "    " .. Locale.Lookup(
            "LOC_AMT_MC_M3_REPORT_SLOTS",
            tostring(fulfilled),
            tostring(tonumber(participant.normalizedSlots) or 0)
        ));
        local improvementUsed = tonumber(
            state.improvementUsedByParticipant[participantID]
        ) or 0;
        local improvementBudget = tonumber(
            result.inputs and result.inputs.improvementBudgets
            and result.inputs.improvementBudgets[participantID]
        ) or 0;
        if improvementBudget > 0 or improvementUsed > 0 then
            table.insert(lines, "    " .. Locale.Lookup(
                "LOC_AMT_MC_M6_REPORT_BUDGET",
                tostring(improvementUsed),
                tostring(improvementBudget)
            ));
        end
        local strategicCount = 0;
        local strategicCounts =
            state.strategicResourceCountsByParticipant[participantID]
            or {};
        for resourceType in pairs(strategicCounts) do
            strategicCount = strategicCount + 1;
        end
        if strategicCount > 0 then
            table.insert(lines, "    " .. Locale.Lookup(
                "LOC_AMT_MC_M6_REPORT_STRATEGIC",
                tostring(strategicCount)
            ));
        end
        local savedIntent = participant.savedIntent or {};
        if #(savedIntent.improvementRecommendationEvidence or {}) > 0 then
            table.insert(lines, "    " .. Locale.Lookup(
                "LOC_AMT_MC_REPORT_RECOMMENDATIONS"
            ));
            for _, line in ipairs(
                AMT_MC_FormatRecommendationEvidence(savedIntent)
            ) do
                table.insert(lines, "    " .. line);
            end
        end
        local unplaced = {};
        for _, request in ipairs(
            result.inputs and result.inputs.requests or {}
        ) do
            if not request.optional
                and (state.fulfilledRequestIDs[request.requestID] or 0)
                    < 1
                and request.eligibleCityIDs
                and request.eligibleCityIDs[1] == participant.cityID then
                table.insert(unplaced, GetSubjectDisplay(
                    request.subjectType,
                    (request.subjectOptions or {})[1] or "?"
                ));
            end
        end
        table.sort(unplaced);
        table.insert(lines, "    " .. Locale.Lookup(
            "LOC_AMT_MC_M3_REPORT_UNPLACED",
            #unplaced > 0 and table.concat(unplaced, "、")
                or Locale.Lookup("LOC_AMT_MC_REPORT_NONE")
        ));
        local unplacedLimited = {};
        for _, request in ipairs(
            result.inputs and result.inputs.requests or {}
        ) do
            if request.limitGroup and request.optional
                and (state.fulfilledRequestIDs[request.requestID] or 0)
                    < 1
                and request.eligibleCityIDs
                and request.eligibleCityIDs[1] == participant.cityID then
                table.insert(unplacedLimited, GetSubjectDisplay(
                    request.subjectType,
                    (request.subjectOptions or {})[1] or "?"
                ));
            end
        end
        table.sort(unplacedLimited);
        if #unplacedLimited > 0 then
            table.insert(lines, "    " .. Locale.Lookup(
                "LOC_AMT_MC_M6_REPORT_UNPLACED_LIMIT",
                table.concat(unplacedLimited, "、")
            ));
        end
        table.insert(lines, "");
    end
    local crossPairs = 0;
    for firstIndex = 1, #(state.items or {}) do
        for secondIndex = firstIndex + 1, #(state.items or {}) do
            local firstItem = state.items[firstIndex];
            local secondItem = state.items[secondIndex];
            local first = firstItem.candidate;
            local second = secondItem.candidate;
            local firstLegacy = AMT_MC_M3_GetLegacyItem(
                firstItem, result.inputs
            );
            local secondLegacy = AMT_MC_M3_GetLegacyItem(
                secondItem, result.inputs
            );
            if firstLegacy and secondLegacy
                and first.planningCityID ~= second.planningCityID
                and Map.GetPlotDistance(
                    firstLegacy.x, firstLegacy.y,
                    secondLegacy.x, secondLegacy.y
                ) == 1 then
                crossPairs = crossPairs + 1;
            end
        end
    end
    table.insert(lines, Locale.Lookup(
        "LOC_AMT_MC_M3_REPORT_CROSS", tostring(crossPairs)
    ));
    local services = result.inputs
        and result.inputs.coverageServices or {};
    local serviceList = {};
    for service in pairs(services) do
        table.insert(serviceList, service);
    end
    table.sort(serviceList);
    if #serviceList > 0 then
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_MC_M4_REPORT_COVERAGE"
        ));
        local baseline = result.inputs.baselineCovered or {};
        for _, service in ipairs(serviceList) do
            local covered = 0;
            local overlap = 0;
            for _, participantID in ipairs(
                snapshot.orderedParticipantIDs or {}
            ) do
                local participant = snapshot.participants[participantID];
                local base = (baseline[service] or {})[
                    participant.cityID
                ] == true;
                local byParticipant =
                    (state.coverageByServiceAndParticipant or {})[service]
                    or {};
                local count = tonumber(
                    byParticipant[participantID]
                ) or 0;
                if base or count > 0 then covered = covered + 1; end
                overlap = overlap + math.max(0, count - 1);
            end
            table.insert(lines, "    " .. Locale.Lookup(
                "LOC_AMT_MC_M4_REPORT_COVERAGE_SERVICE",
                GetSubjectDisplay(
                    MAP_PIN_TYPE_DISTRICT,
                    service == "DISTRICT_INDUSTRIAL_ZONE"
                        and "DISTRICT_INDUSTRIAL_ZONE"
                        or "DISTRICT_ENTERTAINMENT_COMPLEX"
                ),
                tostring(covered),
                tostring(#snapshot.orderedParticipantIDs),
                tostring(overlap)
            ));
        end
        table.insert(lines, "");
    end
    local notes = result.inputs and result.inputs.skippedNotes or {};
    if #notes > 0 then
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_MC_M3_REPORT_SKIPPED"
        ));
        for _, note in ipairs(notes) do
            table.insert(lines, "    " .. tostring(note));
        end
        table.insert(lines, "");
    end
    table.insert(lines, Locale.Lookup(
        "LOC_AMT_MC_M3_REPORT_DISTRICT_ONLY"
    ));
    table.insert(lines, Locale.Lookup(
        "LOC_AMT_MC_M3_REPORT_NO_PLACEMENT"
    ));
    return table.concat(lines, "[NEWLINE]");
end

function AMT_MC_M3_RequestOwner(snapshot, request)
    local ids = request.eligibleParticipantIDs or {};
    local participant = snapshot and snapshot.participants
        and snapshot.participants[ids[1]];
    if request.scope ~= "CITY" or #ids ~= 1 or not participant then
        return "SHARED", Locale.Lookup("LOC_AMT_MC_UI_SHARED");
    end
    local cityID = participant.cityID;
    local label = tostring(participant.name or cityID or ids[1]);
    for otherID, other in pairs(snapshot.participants) do
        if otherID ~= ids[1] and other.name == participant.name then
            label = label .. " (#" .. tostring(cityID or ids[1]) .. ")";
            break;
        end
    end
    return "CITY:" .. tostring(cityID or ids[1]), label;
end

function AMT_MC_M3_FormatUnfulfilled(snapshot, unfulfilled)
    local groups, order, lines = {}, {}, {};
    for _, request in ipairs(unfulfilled or {}) do
        local key, label = AMT_MC_M3_RequestOwner(snapshot, request);
        if not groups[key] then
            groups[key] = { label = label, names = {} };
            order[#order + 1] = key;
        end
        local subject = (request.subjectOptions or {})[1] or request.subjectKey or "?";
        table.insert(groups[key].names,
            GetSubjectDisplay(request.subjectType, subject) or tostring(subject));
    end
    for _, key in ipairs(order) do
        local group = groups[key];
        table.sort(group.names);
        local names = table.concat(group.names, "、");
        lines[#lines + 1] = key == "SHARED"
            and Locale.Lookup("LOC_AMT_MC_M6_UNFULFILLED_GLOBAL", names)
            or Locale.Lookup("LOC_AMT_MC_M6_UNFULFILLED_CITY", group.label, names);
    end
    return table.concat(lines, "[NEWLINE]");
end

function AMT_MC_M3_FormatCompactIssues(snapshot, result)
    local lines = {};
    local seen = {};
    local omitted = 0;
    local function AddLine(value)
        value = tostring(value or "");
        if value ~= "" and not seen[value] then
            seen[value] = true;
            if #lines < 6 then
                table.insert(lines, "• " .. value);
            else
                omitted = omitted + 1;
            end
        end
    end
    local unfulfilled = result and result.diagnostics
        and result.diagnostics.unfulfilledRequired or {};
    for _, request in ipairs(unfulfilled) do
        local _, ownerLabel = AMT_MC_M3_RequestOwner(snapshot, request);
        local subjectKey = request.subjectOptions
            and request.subjectOptions[1] or request.subjectKey;
        local subjectName = GetSubjectDisplay(
            request.subjectType, subjectKey
        ) or tostring(subjectKey or "?");
        local reason = Locale.Lookup(
            "LOC_AMT_MC_M3_REPORT_PARTIAL_UNKNOWN_REASON"
        );
        for _, example in ipairs(result.diagnostics
            and result.diagnostics.rejectionExamples or {}) do
            if example.requestID == request.requestID then
                reason = AMT_MC_M6_DiagLabel(example.reason);
                break;
            end
        end
        AddLine(Locale.Lookup(
            "LOC_AMT_MC_UI_ISSUE_UNPLACED",
            ownerLabel, subjectName, reason
        ));
    end
    local notes = result and result.inputs and result.inputs.skippedNotes or {};
    for _, note in ipairs(notes) do AddLine(note); end
    if omitted > 0 then
        table.insert(lines, Locale.Lookup("LOC_AMT_MC_UI_MORE_ISSUES", omitted));
    end
    if #lines == 0 then
        return Locale.Lookup("LOC_AMT_MC_UI_NO_ISSUES");
    end
    return table.concat(lines, "[NEWLINE]");
end

function AMT_MC_M3_SelectPlan(planIndex)
    local pending = AMT_MC_M3State.pending;
    if not pending then return; end
    pending.planIndex = planIndex;
    local list = pending.result.pool and pending.result.pool.list or {};
    local entry = list[planIndex];
    if not entry and planIndex == 1 then
        entry = { state = pending.result.best, relativeGap = 0 };
    end
    if not entry or not entry.state then return; end
    local items = AMT_MC_M3_CollectLegacyItems(
        entry.state, pending.result.inputs
    );
    ShowPreviewHighlights({
        playerID = Game.GetLocalPlayer(),
        bestState = { items = items },
    });
    -- Use the same non-persistent preview flags as the single-city report.
    -- These make each proposed district/improvement visible on the map while
    -- keeping cancellation side-effect free.
    m_PreviewMapIconIM:ResetInstances();
    for index, item in ipairs(items) do
        local yields = entry.state.displayYieldsByItem
            and entry.state.displayYieldsByItem[index]
            or (entry.state.yieldsByItem
                and entry.state.yieldsByItem[index])
            or {};
        local mapInstance = m_PreviewMapIconIM:GetInstance();
        mapInstance.SubjectIcon:SetIcon(item.iconName or GetSubjectIcon(
            item.subjectType, item.subjectKey
        ));
        mapInstance.YieldText:SetText(entry.state.previewYieldsUnavailable
            and Locale.Lookup("LOC_AMT_MC_UI_YIELDS_UNAVAILABLE")
            or FormatYieldSummary(yields));
        local worldX, worldY, worldZ = UI.GridToWorld(item.x, item.y);
        mapInstance.Anchor:SetWorldPositionVal(
            worldX, worldY, (worldZ or 0) + 12
        );
    end
    AMT_MC_M3State.pendingDiff = nil;
    if Controls.MCPlanManualRiskPanel then
        Controls.MCPlanManualRiskPanel:SetHide(true);
    end
    if Controls.MCPlanManualConfirmCheck then
        Controls.MCPlanManualConfirmCheck:SetCheck(false);
    end
    if Controls.MCPlanIssueTitle then
        Controls.MCPlanIssueTitle:SetHide(false);
    end
    if Controls.MCPlanIssueScroll then
        Controls.MCPlanIssueScroll:SetHide(false);
    end
    if Controls.MCPlanPreviewApplyButton then
        Controls.MCPlanPreviewApplyButton:SetDisabled(false);
    end
    Controls.MCScopeText:SetText(AMT_MC_M3_FormatJointReport(
        pending.snapshot, pending.result, planIndex
    ));
    -- The wrapped label owns its height; the scroll panel remains bounded.
    Controls.MCScopeScroll:CalculateInternalSize();
    Controls.MCScopeScroll:SetScrollValue(0);
    for index = 1, 3 do
        local button = Controls["MCPlanButton" .. tostring(index)];
        if button then button:SetDisabled(index == planIndex); end
        local card = Controls["MCPlanCard" .. tostring(index)];
        if card then card:SetDisabled(index == planIndex); end
    end
    if Controls.MCPlanIssueText then
        Controls.MCPlanIssueText:SetText(AMT_MC_M3_FormatCompactIssues(
            pending.snapshot, pending.result
        ));
        -- Height follows wrapped text; do not clip the seventh (remaining) line.
        Controls.MCPlanIssueScroll:CalculateInternalSize();
        Controls.MCPlanIssueScroll:SetScrollValue(0);
    end
    -- Reuse the existing PlanDiff report as an optional hover detail. No
    -- second confirmation page; clicking Apply still rebuilds/revalidates it.
    if Controls.MCPlanPreviewApplyButton then
        local diff, reason = AMT_MC_M7_BuildPendingDiff(
            pending.snapshot, pending.result, planIndex);
        Controls.MCPlanPreviewApplyButton:SetToolTipString(diff
            and AMT_MC_M7_FormatApplyBody(diff, pending.snapshot)
            or tostring(reason or ""));
    end
end

-- Localized label for solver rejection reasons (shown on the no-plan page).
function AMT_MC_M6_DiagLabel(reason)
    local key = nil;
    if reason == "plot occupied" then
        key = "LOC_AMT_MC_M6_DIAG_PLOT_OCCUPIED";
    elseif reason == "specialty slots exhausted" then
        key = "LOC_AMT_MC_M6_DIAG_SLOTS_EXHAUSTED";
    elseif reason == "slot index already fulfilled" then
        key = "LOC_AMT_MC_M6_DIAG_SLOT_INDEX";
    elseif reason == "one-per-city strategy limit" then
        key = "LOC_AMT_MC_M6_DIAG_STRATEGY_LIMIT";
    elseif reason == "request already fulfilled to max" then
        key = "LOC_AMT_MC_M6_DIAG_REQUEST_MAX";
    elseif reason == "player/world limit reached" then
        key = "LOC_AMT_MC_M6_DIAG_LIMIT_REACHED";
    elseif reason == "improvement budget exhausted" then
        key = "LOC_AMT_MC_M6_DIAG_BUDGET";
    elseif string.find(reason, "exclusion", 1, true) then
        key = "LOC_AMT_MC_M6_DIAG_EXCLUSION";
    elseif string.find(reason, "support", 1, true) then
        key = "LOC_AMT_MC_M6_DIAG_SUPPORT";
    end
    if key then return Locale.Lookup(key); end
    return Locale.Lookup("LOC_AMT_MC_M6_DIAG_OTHER", tostring(reason));
end

function AMT_MC_M3_ShowJointFailure(status, result)
    m_IsPlanning = false;
    AMT_MC_SetPhase(3);
    if Controls.SettingsBlocker then
        Controls.SettingsBlocker:SetHide(false);
    end
    if Controls.MCPlanPreviewOverlay then
        Controls.MCPlanPreviewOverlay:SetHide(true);
    end
    if Controls.MCPlanningOverlay then
        Controls.MCPlanningOverlay:SetHide(true);
    end
    if Controls.MCScopeOverlay then
        Controls.MCScopeOverlay:SetHide(false);
    end
    Controls.MCScopeFrame:SetSizeY(650);
    Controls.MCScopeIncludedPanel:SetHide(true);
    Controls.MCScopeExcludedPanel:SetHide(true);
    Controls.MCScopeConfirmButton:SetHide(true);
    Controls.MCScopeBackButton:SetHide(false);
    Controls.MCScopeCloseButton:SetHide(false);
    Controls.MCScopeScroll:SetHide(false);
    Controls.MCScopeScroll:SetOffsetY(105);
    Controls.MCScopeScroll:SetSizeY(470);
    if Controls.MCPlanTitle then
        Controls.MCPlanTitle:SetHide(true);
    end
    for planIndex = 1, 3 do
        local button = Controls["MCPlanButton" .. tostring(planIndex)];
        if button then button:SetHide(true); end
    end
    Controls.MCScopeTitle:SetText(Locale.Lookup(
        "LOC_AMT_MC_M3_PREVIEW_TITLE"
    ));
    local lines = {};
    if status == "CANCELLED" then
        Controls.MCScopeNotice:SetText(Locale.Lookup(
            "LOC_AMT_CALCULATION_CANCELLED"
        ));
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_CALCULATION_CANCELLED"
        ));
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_MC_M3_REPORT_NO_PLACEMENT"
        ));
    elseif status == "BUDGET_EXCEEDED" then
        Controls.MCScopeNotice:SetText(Locale.Lookup(
            "LOC_AMT_MC_M3_BUDGET_EXCEEDED"
        ));
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_MC_M3_REPORT_NO_PLACEMENT"
        ));
    elseif status == "SNAPSHOT_STALE" then
        Controls.MCScopeNotice:SetText(Locale.Lookup(
            "LOC_AMT_MC_M6U_SNAPSHOT_STALE"
        ));
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_MC_M6U_SNAPSHOT_STALE_RETURN"
        ));
    elseif status == "INPUT_ERROR" then
        Controls.MCScopeNotice:SetText(Locale.Lookup(
            "LOC_AMT_MC_M6_INPUT_ERROR",
            tostring(result and result.note or "?")
        ));
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_MC_M3_REPORT_NO_PLACEMENT"
        ));
    else
        Controls.MCScopeNotice:SetText(Locale.Lookup(
            "LOC_AMT_MC_M3_NO_PLAN"
        ));
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_MC_M6_NO_PLAN_DETAIL"
        ));
        local diagnostics = result and result.diagnostics or nil;
        local unfulfilled = diagnostics
            and diagnostics.unfulfilledRequired or {};
        -- Name the city each unplaced item belongs to so the player knows
        -- which planner page to edit (PERFORMANCE_UX_EXECUTION_PLAN 体验批).
        -- CITY-scoped requests map to one participant; coverage, PLAYER and
        -- WORLD requests have no single city and fall into a shared bucket.
        table.insert(lines, AMT_MC_M3_FormatUnfulfilled(
            AMT_MC_M3State.lastSnapshot, unfulfilled));
        local inputs = result and result.inputs
            or AMT_MC_M3State.lastInputs;
        local notes = inputs and inputs.skippedNotes or {};
        if #notes > 0 then
            table.insert(lines, "  " .. Locale.Lookup(
                "LOC_AMT_MC_M3_REPORT_SKIPPED"
            ));
            for _, note in ipairs(notes) do
                table.insert(lines, "    " .. tostring(note));
            end
            table.insert(lines, "");
        end
        local reasonCounts = diagnostics
            and diagnostics.reasonCounts or {};
        if #reasonCounts > 0 then
            table.insert(lines, "  " .. Locale.Lookup(
                "LOC_AMT_MC_M6_DIAG_HEADER"
            ));
            for _, entry in ipairs(reasonCounts) do
                table.insert(lines, "    " .. Locale.Lookup(
                    "LOC_AMT_MC_M6_DIAG_ITEM",
                    AMT_MC_M6_DiagLabel(entry.reason),
                    tostring(entry.count)
                ));
            end
            table.insert(lines, "");
        end
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_MC_M3_REPORT_NO_PLACEMENT"
        ));
    end
    Controls.MCScopeText:SetText(table.concat(lines, "[NEWLINE]"));
    -- The wrapped label owns its height; the scroll panel remains bounded.
    Controls.MCScopeScroll:CalculateInternalSize();
    Controls.MCScopeScroll:SetScrollValue(0);
    ClearPreviewHighlights();
end

-- ---------------------------------------------------------------------------
-- M7 atomic apply.  PlanDiff is computed from the FROZEN snapshot plus the
-- currently selected pool entry.  Nothing touches the map until the player
-- confirms the diff; the apply itself rolls back on any failure.
-- ---------------------------------------------------------------------------
function AMT_MC_M7_FindParticipantByCityID(snapshot, cityID)
    for _, participantID in ipairs(
        snapshot and snapshot.orderedParticipantIDs or {}
    ) do
        local participant = snapshot.participants
            and snapshot.participants[participantID] or nil;
        if participant and tonumber(participant.cityID) == tonumber(cityID) then
            return participantID;
        end
    end
    return nil;
end

function AMT_MC_M7_BuildPendingDiff(snapshot, result, planIndex)
    local playerID = Game.GetLocalPlayer();
    local cfg = PlayerConfigurations[playerID];
    if not cfg then return nil, "player configuration unavailable"; end
    local list = result.pool and result.pool.list or {};
    local entry = list[planIndex] or list[1];
    if not entry or not entry.state then return nil, "plan unavailable"; end
    if AMT_MultiCity.Cluster.SnapshotStillValid(snapshot) ~= true then
        return nil, "SNAPSHOT_STALE";
    end

    local participants = {};
    local participantList = {};
    for _, participantID in ipairs(snapshot.orderedParticipantIDs or {}) do
        local participant = snapshot.participants[participantID];
        if participant then
            participants[participantID] = true;
            table.insert(participantList, {
                participantID = participantID,
                cityID = participant.cityID,
            });
        end
    end

    local autoRegistry = LoadAutoPinRegistry(playerID);
    local existingPins = {};
    for _, pin in pairs(cfg:GetMapPins() or {}) do
        if pin then
            local x, y = pin:GetHexX(), pin:GetHexY();
            local key = Key(x, y);
            local registryRecord = autoRegistry[key] or {};
            local cityID = GetPinPlanningCityID(
                playerID, pin, registryRecord
            );
            local participantID = AMT_MC_M7_FindParticipantByCityID(
                snapshot, cityID
            );
            if participantID then
                local subject = CreateMapPinSubject(pin);
                table.insert(existingPins, {
                    x = x,
                    y = y,
                    participantID = participantID,
                    isAuto = IsAutoMapPin(pin, autoRegistry),
                    subjectType = registryRecord.subjectType
                        or (subject and subject.Type)
                        or (registryRecord.district
                            and MAP_PIN_TYPE_DISTRICT)
                        or nil,
                    subjectKey = registryRecord.subjectKey
                        or registryRecord.district
                        or (subject and subject.Key)
                        or nil,
                    iconName = pin:GetIconName(),
                    name = pin:GetName() or "",
                    cityID = cityID,
                });
            end
        end
    end

    local desiredItems = {};
    for _, item in ipairs(entry.state.items or {}) do
        local candidate = item.candidate;
        local legacy = AMT_MC_M3_GetLegacyItem(item, result.inputs);
        if legacy then
            table.insert(desiredItems, {
                x = legacy.x,
                y = legacy.y,
                subjectType = candidate.subjectType,
                subjectKey = candidate.subjectKey,
                iconName = legacy.iconName
                    or GetSubjectIcon(
                        candidate.subjectType, candidate.subjectKey
                    ),
                cityID = candidate.planningCityID,
                participantID = candidate.planningParticipantID,
            });
        end
    end

    local clearPolicy = snapshot.clearPolicy or {};
    local diff, reason = AMT_MultiCity.Transaction.BuildDiff({
        snapshotSignature = snapshot.signature
            or snapshot.signatures and snapshot.signatures.settings or "",
        participants = participants,
        participantList = participantList,
        existingPins = existingPins,
        desiredItems = desiredItems,
        -- M7 first version: applying a fresh plan always cleans the
        -- participant auto pins it does not keep (the lazy-planner default);
        -- manual pins still require snapshot clearManualPins.
        clearAutoPins = true,
        clearManualPins = clearPolicy.clearManualPins == true,
        staleResourceKeys = {},
    });
    if not diff then return nil, reason; end
    AMT_MC_M3State.pendingDiff = {
        snapshot = snapshot,
        result = result,
        planIndex = planIndex,
        diff = diff,
    };
    return diff;
end

function AMT_MC_M7_LoadRecovery()
    local cfg = PlayerConfigurations[Game.GetLocalPlayer()];
    local raw = cfg and cfg:GetValue("AMT_LINKED_RECOVERY_V1");
    if raw == nil then return AMT_MC_M3State.recovery; end
    -- A corrupt journal is a stop condition, never permission to overwrite it.
    return LoadConfigTable(cfg, "AMT_LINKED_RECOVERY_V1") or { corrupt = true };
end

-- MC-only restoration: do not change the inherited single-city helper.
-- Native creation and each setter have a durable identity/field checkpoint.
function AMT_MC_M7_FinishRestore(playerID, plot, journal, adapter, registry)
    local tx = AMT_MultiCity.Transaction;
    local target = plot.before;
    local recovery = plot.recovery;
    local function Capture()
        local pin = FindMapPinAt(playerID, plot.x, plot.y);
        if not pin then return false; end
        -- A newly allocated pin may not have a subject/icon yet. Capture raw
        -- identity/fields here; use the full adapter again only at completion.
        local icon = pin:GetIconName();
        local current = { id = pin:GetID(), x = pin:GetHexX(), y = pin:GetHexY(),
            ownerID = playerID, iconName = icon, iconNameWasNil = icon == nil,
            name = pin:GetName() or "" };
        if icon == target.iconName then
            current.subjectType, current.subjectKey = target.subjectType, target.subjectKey;
        end
        if type(pin.GetVisibility) == "function" then
            local value = pin:GetVisibility();
            if type(value) == "number" or type(value) == "boolean" then current.visibility = value; end
        end
        return current;
    end
    local build = recovery.build;
    local current = Capture();
    if not build or (build.step == "CREATE" and build.pinID == nil and not current) then
        assert(not current, "restore creation target occupied");
        build = { step = "CREATE", from = false, after = false };
        recovery.build = build;
        adapter.saveRecovery(journal);
        local created, pin = pcall(function()
            return PlayerConfigurations[playerID]:GetMapPin(plot.x, plot.y);
        end);
        -- If creation changed the map then threw, capture that new identity
        -- synchronously, before any user callback can edit it (no yields).
        current = Capture();
        if current then
            build.pinID = current.id;
            build.step = "CREATED";
            build.from, build.after, build.checkpoint = current, current, current;
            adapter.saveRecovery(journal);
        end
        assert(created and pin and current, "restore pin creation failed");
    else
        local known = build.checkpoint;
        local matches = known and tx.SameRestorePin(current, known)
            or (not known and (tx.SameRestorePin(current, build.from)
                or tx.SameRestorePin(current, build.after)));
        assert(current and current.id == build.pinID and matches,
            "partial restore pin changed");
    end
    local pin = assert(FindMapPinAt(playerID, plot.x, plot.y), "restore pin disappeared");
    local function Field(step, project, action)
        local before = Capture();
        assert(tx.SameRestorePin(before, build.checkpoint or build.from)
            or (not build.checkpoint and tx.SameRestorePin(before, build.after)),
            "partial restore pin changed before field");
        build.step = step;
        build.from = before;
        build.after = tx.Copy(before);
        if project then project(build.after); end
        build.checkpoint = nil;
        adapter.saveRecovery(journal);
        local ok, value = pcall(action);
        local readOK, observed = pcall(Capture);
        local known = readOK and (tx.SameRestorePin(observed, build.from)
            or tx.SameRestorePin(observed, build.after)
            or (step == "VISIBILITY" and observed and observed.id == build.pinID
                and tx.SamePin(observed, build.from)));
        if known then
            build.checkpoint = observed;
            adapter.saveRecovery(journal);
        end
        assert(ok and value ~= false and known, "restore field failed: " .. step
            .. ":" .. tostring(value));
    end
    Field("ICON", function(after)
        after.iconName = target.iconName;
        after.iconNameWasNil = false;
        after.subjectType, after.subjectKey = target.subjectType, target.subjectKey;
    end, function() return pin:SetIconName(target.iconName); end);
    Field("NAME", function(after) after.name = target.name; end,
        function() return pin:SetName(target.name); end);
    -- Preserve the inherited setter contract; optional getter values may use
    -- a different representation. Only this declared field may change here.
    Field("VISIBILITY", nil, function() return pin:SetVisibility(playerID); end);
    Field("NOTIFY", nil, function() LuaEvents.DMT_MapPinAdded(pin); end);
    Field("REGISTER", nil, function()
        if target.wasAuto and target.subjectType and target.subjectKey then
            RegisterAutoMapPin(pin, target.subjectType, target.subjectKey,
                target.iconName, registry, target.cityID);
        end
    end);
    return tx.SamePin(adapter.capture(plot.x, plot.y), target);
end

function AMT_MC_M7_MakeAdapter(playerID)
    local tx = AMT_MultiCity.Transaction;
    local cfg = assert(PlayerConfigurations[playerID], "player unavailable");
    local registry = tx.Copy(LoadAutoPinRegistry(playerID));
    local added, removed = {}, {};
    local adapter = {};
    adapter.capture = function(x, y)
        local pin = FindMapPinAt(playerID, x, y);
        if not pin then return false; end
        -- Do not let a stale registry disguise a partially changed pin icon.
        local record = CapturePinRecord(pin, {});
        record.ownerID = playerID;
        return record;
    end;
    adapter.saveRecovery = function(journal)
        SaveConfigTable(cfg, "AMT_LINKED_RECOVERY_V1", journal);
        if journal == nil then
            assert(cfg:GetValue("AMT_LINKED_RECOVERY_V1") == nil,
                "recovery journal clear readback failed");
        else
            assert(tx.Equal(LoadConfigTable(cfg, "AMT_LINKED_RECOVERY_V1"), journal),
                "recovery journal readback failed");
        end
        AMT_MC_M3State.recovery = journal;
        return true;
    end;
    adapter.apply = function(operation)
        local record = operation.record;
        if operation.kind == "remove" then
            local pin = FindMapPinAt(playerID, record.x, record.y);
            local actual = adapter.capture(record.x, record.y);
            assert(pin and actual, "delete target disappeared");
            -- Registry ID alone is insufficient: a user can edit the same pin.
            for _, field in ipairs({ "subjectType", "subjectKey", "iconName", "name" }) do
                assert(record[field] == nil or actual[field] == record[field],
                    "delete target changed:" .. field);
            end
            local allowManual = record.isAuto == false;
            assert(allowManual or IsAutoMapPin(pin, registry), "auto pin replaced by manual pin");
            local captured = DeletePinAt(playerID, record.x, record.y,
                registry, allowManual);
            assert(captured and not adapter.capture(record.x, record.y),
                "delete failed:" .. Key(record.x, record.y));
            removed[#removed + 1] = captured;
        else
            local pin;
            if operation.kind == "restore" then
                assert(not adapter.capture(record.x, record.y), "restore target occupied");
                -- A disappeared added pin can leave a stale registry entry.
                -- RestorePinRecord registers auto pins, but deliberately does
                -- not register manual pins: do not let them inherit that entry.
                registry[Key(record.x, record.y)] = nil;
                pin = RestorePinRecord(playerID, record, registry);
            else
                pin = PlacePin(playerID, record.x, record.y,
                    record.subjectType, record.subjectKey, record.iconName);
                assert(pin, "place failed:" .. Key(record.x, record.y));
                RegisterAutoMapPin(pin, record.subjectType, record.subjectKey,
                    record.iconName, registry, record.cityID);
            end
            assert(pin, "restore failed:" .. Key(record.x, record.y));
            local actual = adapter.capture(record.x, record.y);
            assert(tx.SamePin(actual, operation.after),
                "place/restore readback failed:" .. Key(record.x, record.y));
            local addedRecord = tx.Copy(record);
            addedRecord.id = pin:GetID();
            added[#added + 1] = addedRecord;
        end
    end;
    adapter.commit = function(journal)
        local undo;
        if journal.mode ~= "UNDO" then
            undo = { schemaVersion = tx.SCHEMA_VERSION, kind = tx.KIND,
                participantIDs = journal.participantIDs,
                snapshotSignature = journal.snapshotSignature,
                added = added, removed = removed };
        end
        SaveAutoPinRegistry(playerID, registry);
        assert(tx.Equal(LoadAutoPinRegistry(playerID), registry), "registry readback failed");
        SaveLastPlan(playerID, undo);
        if undo == nil then
            assert(cfg:GetValue(CONFIG_KEY_LAST_PLAN) == nil, "undo clear readback failed");
        else
            assert(tx.Equal(LoadLastPlan(playerID), undo), "undo readback failed");
        end
    end;
    adapter.restore = function(plot, journal)
        if plot.recovery and plot.recovery.build then
            -- Even when icon/name already match, pending visibility/events/
            -- registration must complete before the journal may be cleared.
            if not AMT_MC_M7_FinishRestore(playerID, plot, journal, adapter, registry) then return false; end
            plot.recovery = { phase = "DONE", from = adapter.capture(plot.x, plot.y), after = plot.before };
            adapter.saveRecovery(journal);
            return true;
        end
        local current = adapter.capture(plot.x, plot.y);
        if tx.SamePin(current, plot.before) then return true; end
        -- Compensation has its OWN durable intent. A delete may succeed even
        -- when the following restore throws; retry may then see the empty hex.
        -- Only these recorded intermediate states are allowed, never a new edit.
        local allowed = false;
        if plot.recovery then
            allowed = tx.SamePin(current, plot.recovery.from)
                or tx.SamePin(current, plot.recovery.after);
        else
            local expected = plot.observed;
            if expected == nil then expected = plot.expected; end
            allowed = expected ~= nil and tx.SamePin(current, expected);
        end
        if not allowed then return false; end
        if current then
            plot.recovery = { phase = "DELETE", from = current, after = false };
            adapter.saveRecovery(journal);
            local result = DeletePinAt(playerID, plot.x, plot.y, registry, true);
            if not result or adapter.capture(plot.x, plot.y) then return false; end
        end
        if plot.before then
            plot.recovery = { phase = "RESTORE", from = false, after = plot.before };
            adapter.saveRecovery(journal);
            local restored = AMT_MC_M7_FinishRestore(playerID, plot, journal, adapter, registry);
            if not restored then return false; end
        end
        local actual = adapter.capture(plot.x, plot.y);
        if not tx.SamePin(actual, plot.before) then return false; end
        plot.recovery = { phase = "DONE", from = actual, after = plot.before };
        adapter.saveRecovery(journal);
        return true;
    end;
    adapter.restoreStorage = function(journal)
        -- Attempt BOTH keys even when one write throws. Check raw values so
        -- the previous undo and registry are restored exactly (including nil).
        local okRegistry = pcall(function()
            cfg:SetValue(CONFIG_KEY_AUTO_PINS, journal.rawRegistry);
        end);
        local okUndo = pcall(function()
            cfg:SetValue(CONFIG_KEY_LAST_PLAN, journal.rawUndo);
        end);
        return okRegistry and okUndo
            and tx.Equal(cfg:GetValue(CONFIG_KEY_AUTO_PINS), journal.rawRegistry)
            and tx.Equal(cfg:GetValue(CONFIG_KEY_LAST_PLAN), journal.rawUndo);
    end;
    adapter.broadcast = function() Network.BroadcastPlayerInfo(); return true; end;
    return adapter;
end

function AMT_MC_M7_RetryRecovery()
    local ok, restored, status = pcall(function()
        local journal = AMT_MC_M7_LoadRecovery();
        if not journal then return true, "NO_RECOVERY"; end
        if not AMT_MultiCity.Transaction.ValidateJournal(journal, Game.GetLocalPlayer()) then
            return false, "RECOVERY_REQUIRED";
        end
        return AMT_MultiCity.Transaction.Recover(journal,
            AMT_MC_M7_MakeAdapter(journal.playerID));
    end);
    if not ok then return false, "RECOVERY_REQUIRED"; end
    return restored, status;
end

function AMT_MC_M7_CreateJournal(playerID, mode, participantIDs, signature, operations, adapter)
    local tx = AMT_MultiCity.Transaction;
    local cfg = PlayerConfigurations[playerID];
    local rawRegistry = cfg:GetValue(CONFIG_KEY_AUTO_PINS);
    local rawUndo = cfg:GetValue(CONFIG_KEY_LAST_PLAN);
    local journal = { playerID = playerID, schemaVersion = tx.RECOVERY_SCHEMA_VERSION,
        mode = mode, participantIDs = tx.Copy(participantIDs or {}),
        snapshotSignature = tostring(signature or ""),
        rawRegistryWasNil = rawRegistry == nil, rawUndoWasNil = rawUndo == nil,
        rawRegistry = tx.Copy(rawRegistry), rawUndo = tx.Copy(rawUndo),
        plots = {}, operations = operations };
    local seen = {};
    for _, operation in ipairs(operations) do
        local record = operation.record;
        local key = Key(record.x, record.y);
        if not seen[key] then
            local before = adapter.capture(record.x, record.y);
            if before then
                local original = CapturePinRecord(FindMapPinAt(playerID,
                    record.x, record.y), LoadAutoPinRegistry(playerID));
                before.wasAuto = original.wasAuto;
                before.cityID = original.cityID;
            end
            journal.plots[#journal.plots + 1] = {
                x = record.x, y = record.y, before = before };
            seen[key] = true;
        end
    end
    return journal;
end

function AMT_MC_M7_UndoTransaction(transaction)
    local protected, undone, status, evidence, removedCount, restoredCount = pcall(function()
        if AMT_MC_M7_LoadRecovery() then return false, "RECOVERY_REQUIRED"; end
        local playerID = Game.GetLocalPlayer();
        local tx = AMT_MultiCity.Transaction;
        if transaction.kind ~= tx.KIND or not tx.Equal(LoadLastPlan(playerID), transaction) then
            return false, "UNDO_BLOCKED";
        end
        local adapter = AMT_MC_M7_MakeAdapter(playerID);
        local registry = LoadAutoPinRegistry(playerID);
        local operations, removing, restoring = {}, {}, {};
        local removeCount, restoreCount = 0, 0;
        -- Preflight the ENTIRE undo before touching any pin. Conflicts keep
        -- the whole undo record rather than consuming a partial transaction.
        for _, source in ipairs(transaction.added or {}) do
            local record = tx.Copy(source);
            record.name = record.name or "";
            record.isAuto = true;
            local key = Key(record.x, record.y);
            if removing[key] then return false, "UNDO_BLOCKED"; end
            local current = adapter.capture(record.x, record.y);
            if current then
                local pin = FindMapPinAt(playerID, record.x, record.y);
                if not IsAutoMapPin(pin, registry) then return false, "UNDO_BLOCKED"; end
                for _, field in ipairs({ "subjectType", "subjectKey", "iconName", "name" }) do
                    if record[field] ~= nil and record[field] ~= current[field] then
                        return false, "UNDO_BLOCKED";
                    end
                end
                operations[#operations + 1] = { kind = "remove", record = record, after = false };
                removing[key] = true;
                removeCount = removeCount + 1;
            end
        end
        for _, source in ipairs(transaction.removed or {}) do
            local record = tx.Copy(source);
            local key = Key(record.x, record.y);
            if restoring[key] or (adapter.capture(record.x, record.y) and not removing[key]) then
                return false, "UNDO_BLOCKED";
            end
            record.subjectType = record.subjectType
                or (record.district and MAP_PIN_TYPE_DISTRICT);
            record.subjectKey = record.subjectKey or record.district;
            record.iconName = record.iconName or GetSubjectIcon(record.subjectType, record.subjectKey);
            record.name = record.name or "";
            local expected = tx.Copy(record);
            expected.ownerID = playerID;
            operations[#operations + 1] = { kind = "restore", record = record, after = expected };
            restoring[key] = true;
            restoreCount = restoreCount + 1;
        end
        local journal = AMT_MC_M7_CreateJournal(playerID, "UNDO", transaction.participantIDs,
            transaction.snapshotSignature, operations, adapter);
        local success, result, recovery = tx.ApplyAtomic(journal, adapter);
        return success, success and "UNDONE" or result, recovery, removeCount, restoreCount;
    end);
    if not protected then
        Log("M7 undo preflight error: " .. tostring(undone));
        return false, "UNDO_BLOCKED", 0, 0;
    end
    if evidence then AMT_MC_M3State.recovery = evidence; end
    return undone, status, removedCount or 0, restoredCount or 0;
end

function AMT_MC_M7_ApplyPendingDiff()
    -- No yield occurs while applying or restoring a transaction.
    local ok, applied, status, evidence = pcall(function()
        if AMT_MC_M7_LoadRecovery() then return false, "RECOVERY_REQUIRED"; end
        local pending = AMT_MC_M3State.pendingDiff;
        if not pending then return false, "NO_DIFF"; end
        if AMT_MultiCity.Cluster.SnapshotStillValid(pending.snapshot) ~= true then
            return false, "STALE";
        end
        local tx = AMT_MultiCity.Transaction;
        local playerID = Game.GetLocalPlayer();
        local adapter = AMT_MC_M7_MakeAdapter(playerID);
        local operations = {};
        for _, kind in ipairs({ "remove", "add" }) do
            local byCity = kind == "remove" and pending.diff.removeByParticipant
                or pending.diff.addByParticipant;
            for _, participantID in ipairs(pending.snapshot.orderedParticipantIDs) do
                for _, record in ipairs(byCity[participantID] or {}) do
                    local expected = false;
                    if kind == "add" then
                        expected = { x = record.x, y = record.y, ownerID = playerID,
                            subjectType = record.subjectType, subjectKey = record.subjectKey,
                            iconName = record.iconName or GetSubjectIcon(record.subjectType,
                                record.subjectKey), name = "" };
                    end
                    operations[#operations + 1] = {
                        kind = kind, record = tx.Copy(record), after = expected };
                end
            end
        end
        local journal = AMT_MC_M7_CreateJournal(playerID, "APPLY",
            pending.snapshot.orderedParticipantIDs, pending.diff.snapshotSignature, operations, adapter);
        return tx.ApplyAtomic(journal, adapter);
    end);
    if not ok then
        Log("M7 apply preflight failed: " .. tostring(applied));
        return false, "RECOVERY_REQUIRED";
    end
    AMT_MC_M3State.pendingDiff = nil;
    if evidence then
        AMT_MC_M3State.recovery = evidence;
        Log("M7 recovery required: " .. tostring(evidence.failure)
            .. " errors=" .. table.concat(evidence.recoveryErrors or {}, ";"));
    end
    return applied, status;
end

function AMT_MC_M7_FormatApplyBody(diff, snapshot)
    local lines = {};
    for _, participantID in ipairs(snapshot.orderedParticipantIDs or {}) do
        local participant = snapshot.participants[participantID];
        local added = diff.addByParticipant[participantID] or {};
        local removed = diff.removeByParticipant[participantID] or {};
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_MC_M7_APPLY_CITY_LINE",
            tostring(participant and participant.name or participantID),
            #added, #removed
        ));
        for _, record in ipairs(removed) do
            table.insert(lines, "    - " .. Locale.Lookup(
                "LOC_AMT_MC_M7_APPLY_REMOVE_LINE",
                GetSubjectDisplay(record.subjectType, record.subjectKey)
                    or record.subjectKey or "?",
                tostring(record.x), tostring(record.y)
            ));
        end
        for _, record in ipairs(added) do
            table.insert(lines, "    + " .. Locale.Lookup(
                "LOC_AMT_MC_M7_APPLY_ADD_LINE",
                GetSubjectDisplay(record.subjectType, record.subjectKey)
                    or record.subjectKey or "?",
                tostring(record.x), tostring(record.y)
            ));
        end
    end
    local manual = diff.manualRemovalConfirmation or {};
    if #manual > 0 then
        table.insert(lines, "");
        table.insert(lines, Locale.Lookup(
            "LOC_AMT_MC_M7_APPLY_MANUAL_HEADER", #manual
        ));
        for _, record in ipairs(manual) do
            table.insert(lines, "    ! " .. Locale.Lookup(
                "LOC_AMT_MC_M7_APPLY_REMOVE_LINE",
                GetSubjectDisplay(record.subjectType, record.subjectKey)
                    or record.subjectKey or "?",
                tostring(record.x), tostring(record.y)
            ));
        end
    end
    return table.concat(lines, "[NEWLINE]");
end

-- Apply from the comparison drawer.  The former second "Apply plan" page is
-- intentionally bypassed; only manual-pin deletion adds a compact in-place
-- confirmation to the comparison drawer.
function AMT_MC_M7_ApplySelectedPlan()
    local pending = AMT_MC_M3State.pending;
    if not pending then return; end
    local diff, reason = AMT_MC_M7_BuildPendingDiff(
        pending.snapshot, pending.result, pending.planIndex or 1
    );
    if not diff then
        local message = reason == "SNAPSHOT_STALE"
            and Locale.Lookup("LOC_AMT_MC_M7_APPLY_STALE")
            or tostring(reason);
        if Controls.MCPlanIssueText then
            Controls.MCPlanIssueText:SetText("• " .. message);
        end
        return;
    end

    local manualCount = #(diff.manualRemovalConfirmation or {});
    if manualCount > 0 and (not Controls.MCPlanManualConfirmCheck
        or not Controls.MCPlanManualConfirmCheck:IsChecked()) then
        if Controls.MCPlanIssueTitle then
            Controls.MCPlanIssueTitle:SetHide(true);
        end
        if Controls.MCPlanIssueScroll then
            Controls.MCPlanIssueScroll:SetHide(true);
        end
        if Controls.MCPlanManualRiskText then
            Controls.MCPlanManualRiskText:SetText(Locale.Lookup(
                "LOC_AMT_MC_UI_MANUAL_RISK_COMPACT", manualCount
            ));
        end
        if Controls.MCPlanManualRiskPanel then
            Controls.MCPlanManualRiskPanel:SetHide(false);
        end
        if Controls.MCPlanPreviewApplyButton then
            Controls.MCPlanPreviewApplyButton:SetDisabled(true);
        end
        return;
    end

    local applied, status = AMT_MC_M7_ApplyPendingDiff();
    if applied then
        RefreshUndoButton(Game.GetLocalPlayer());
        UI.PlaySound("Map_Pin_Add");
        Log("M7 multi-city plan applied; closing planner.");
        HidePopup();
        return;
    end
    local message = Locale.Lookup(status == "STALE"
        and "LOC_AMT_MC_M7_APPLY_STALE"
        or (status == "ROLLED_BACK" and "LOC_AMT_MC_M7_APPLY_ROLLED_BACK"
            or "LOC_AMT_MC_M7_RECOVERY_REQUIRED"));
    if Controls.MCPlanIssueText then
        Controls.MCPlanIssueText:SetText(message);
    end
    RefreshUndoButton(Game.GetLocalPlayer());
    Log("M7 multi-city apply failed: " .. tostring(status));
end

function AMT_MC_M3_ShowJointPreview(snapshot, result)
    m_IsPlanning = false;
    if Controls.MCPlanningOverlay then
        Controls.MCPlanningOverlay:SetHide(true);
    end
    if Controls.MCScopeOverlay then Controls.MCScopeOverlay:SetHide(true); end
    if not result
        or (result.status ~= "OK" and result.status ~= "PARTIAL")
        or not result.best then
        AMT_MC_M3_ShowJointFailure(
            result and result.status or "NO_PLAN", result
        );
        return;
    end
    AMT_MC_M3State.pending = {
        snapshot = snapshot,
        result = result,
        planIndex = 1,
    };
    AMT_MC_SetPhase(3);
    if Controls.SettingsBlocker then
        Controls.SettingsBlocker:SetHide(true);
    end
    if Controls.MCPlanPreviewOverlay then
        Controls.MCPlanPreviewOverlay:SetHide(false);
    end
    if Controls.PreviewConfirmButton then
        Controls.PreviewConfirmButton:SetHide(true);
    end
    Controls.MCScopeFrame:SetSizeY(650);
    Controls.MCScopeTitle:SetText(Locale.Lookup(
        result.partial and "LOC_AMT_MC_M3_PARTIAL_PREVIEW_TITLE"
            or "LOC_AMT_MC_M3_PREVIEW_TITLE"
    ));
    Controls.MCScopeNotice:SetText(Locale.Lookup(
        result.partial and "LOC_AMT_MC_M3_PARTIAL_PREVIEW_NOTICE"
            or "LOC_AMT_MC_M3_PREVIEW_NOTICE"
    ));
    Controls.MCScopeIncludedPanel:SetHide(true);
    Controls.MCScopeExcludedPanel:SetHide(true);
    if not result.partial
        and AMT_MultiCity.GetCapabilities().applyEnabled then
        Controls.MCScopeConfirmButton:SetHide(false);
        Controls.MCScopeConfirmButton:SetText(Locale.Lookup(
            "LOC_AMT_MC_M7_CONFIRM_APPLY"
        ));
    else
        Controls.MCScopeConfirmButton:SetHide(true);
    end
    Controls.MCScopeBackButton:SetHide(false);
    Controls.MCScopeCloseButton:SetHide(false);
    Controls.MCScopeScroll:SetHide(false);
    Controls.MCScopeScroll:SetOffsetY(150);
    Controls.MCScopeScroll:SetSizeY(460);
    local planCount = #(result.pool and result.pool.list or {});
    if planCount == 0 then planCount = 1; end
    if Controls.MCPlanTitle then
        Controls.MCPlanTitle:SetHide(false);
        Controls.MCPlanTitle:SetText(Locale.Lookup(
            "LOC_AMT_MC_M3_PLANS_LABEL", planCount
        ));
    end
    for planIndex = 1, 3 do
        local button = Controls["MCPlanButton" .. tostring(planIndex)];
        if button then
            if planIndex <= planCount then
                button:SetHide(false);
                button:SetText(Locale.Lookup(
                    "LOC_AMT_MC_M3_PLAN_TAB", planIndex
                ) .. (planIndex == 1
                    and " " .. Locale.Lookup(
                        "LOC_AMT_MC_M3_RECOMMENDED"
                    ) or ""));
                button:SetDisabled(planIndex == 1);
            else
                button:SetHide(true);
            end
        end
        local card = Controls["MCPlanCard" .. tostring(planIndex)];
        if card then
            if planIndex <= planCount then
                card:SetHide(false);
                card:SetText(Locale.Lookup(
                    "LOC_AMT_MC_M3_PLAN_TAB", planIndex
                ) .. (planIndex == 1 and "  ·  " .. Locale.Lookup(
                    "LOC_AMT_MC_M3_RECOMMENDED") or ""));
                card:SetDisabled(planIndex == 1);
            else
                card:SetHide(true);
            end
        end
    end
    if Controls.MCPlanPreviewTitle then
        Controls.MCPlanPreviewTitle:SetText(Locale.Lookup(
            result.partial and "LOC_AMT_MC_M3_PARTIAL_PREVIEW_TITLE"
                or "LOC_AMT_MC_UI_COMPARE_TITLE"
        ));
    end
    if Controls.MCPlanPreviewApplyButton then
        Controls.MCPlanPreviewApplyButton:SetHide(result.partial
            or not AMT_MultiCity.GetCapabilities().applyEnabled);
    end
    AMT_MC_M3_SelectPlan(1);

end

function AMT_MC_M3_ClearJointPreview()
    m_IsPlanning = false;
    ContextPtr:ClearUpdate();
    ClearPreviewHighlights();
    m_PreviewMapIconIM:ResetInstances();
    AMT_MC_M3State.pending = nil;
    AMT_MC_M3State.job = nil;
    AMT_MC_M3State.lastInputs = nil;
    AMT_MC_M3State.pendingDiff = nil;
    if Controls.MCApplyOverlay then
        Controls.MCApplyOverlay:SetHide(true);
    end
    if Controls.MCPlanPreviewOverlay then
        Controls.MCPlanPreviewOverlay:SetHide(true);
    end
    if Controls.SettingsBlocker then
        Controls.SettingsBlocker:SetHide(false);
    end
    if Controls.MCPlanTitle then
        Controls.MCPlanTitle:SetHide(true);
    end
    for planIndex = 1, 3 do
        local button = Controls["MCPlanButton" .. tostring(planIndex)];
        if button then button:SetHide(true); end
        local card = Controls["MCPlanCard" .. tostring(planIndex)];
        if card then card:SetHide(true); end
    end
    Controls.MCScopeScroll:SetOffsetY(105);
    Controls.MCScopeScroll:SetSizeY(470);
    if Controls.PreviewConfirmButton then
        -- Restore the legacy single-city confirm button so the original
        -- path stays fully usable after a joint preview closes.
        Controls.PreviewConfirmButton:SetHide(false);
    end
    AMT_MC_SetPhase(1);
end

function AMT_MC_RequestClose()
    if m_MCSession
        and AMT_MultiCity.UIState.HasUnsavedDrafts(m_MCSession) then
        Controls.MCUnsavedOverlay:SetHide(false);
        return;
    end
    HidePopup();
end

function AMT_MC_SaveAllAndClose()
    local locksOK, lockSubjects = AMT_MC_M6U_ValidateDraftLocks();
    if not locksOK then
        Controls.MCUnsavedOverlay:SetHide(true);
        m_ResultText:SetText(Locale.Lookup(
            "LOC_AMT_MC_UNIQUE_LOCK_INVALID_SAVE",
            AMT_MC_M6U_SubjectNames(lockSubjects)
        ));
        return;
    end
    for _, participantID in ipairs(m_MCSession.orderedParticipantIDs) do
        local profile = m_MCSession.profiles[participantID];
        if AMT_MultiCity.UIState.GetStatus(profile)
            == AMT_MultiCity.UIState.STATUS_DIRTY then
            local ok, reason = AMT_MC_SaveParticipant(participantID);
            if not ok then
                Controls.MCUnsavedOverlay:SetHide(true);
                m_ResultText:SetText(tostring(reason));
                return;
            end
        end
    end
    -- Shared unique drafts commit and persist together with the city
    -- revisions above (UNIQUE_DISTRICT_UI_PLAN section 7).
    AMT_MC_M6U_SaveSharedDrafts();
    AMT_MC_PersistSettings();
    HidePopup();
end

function AMT_MC_DiscardAllAndClose()
    for _, participantID in ipairs(m_MCSession.orderedParticipantIDs) do
        local profile = m_MCSession.profiles[participantID];
        if AMT_MultiCity.UIState.GetStatus(profile)
            == AMT_MultiCity.UIState.STATUS_DIRTY then
            local participant = m_MCSession.participants[participantID];
            local city = Players[Game.GetLocalPlayer()]:GetCities()
                :FindID(participant.cityID);
            local key = GetCityPlanKey(city);
            if key then m_CitySpecialtyPlans[key] = nil; end
            local plan = GetCitySpecialtyPlan(city);
            if profile.savedIntent then
                AMT_MC_ApplyIntentToPlan(plan, profile.savedIntent);
            end
        end
    end
    -- Discarding also reverts shared unique drafts; no settings write is
    -- performed, so saved city and shared revisions stay untouched.
    AMT_MC_M6U_DiscardSharedDrafts();
    HidePopup();
end

function ShowPopup()
    if m_MCMode then AMT_MC_BeginSession(); else AMT_MC_SetChromeVisible(false); end
    RepopulatePopup();
    if UIManager:IsInPopupQueue(ContextPtr) then return; end
    UIManager:QueuePopup(ContextPtr, PopupPriority.Low);
    m_IsOpen = true;
    AMT_MC_SetSettingsPanelHidden(false);
    Log("Popup shown.");
end

function HidePopup()
    if m_QueuedPlan then
        ContextPtr:ClearUpdate();
        m_QueuedPlan = nil;
    end
    -- Abandon any live joint solve worker: closing the popup must never
    -- leave the per-frame update resuming a solver later.
    AMT_MC_M3State.job = nil;
    AMT_MC_M3State.cancelled = nil;
    FinishPlanningUi();
    ClearPendingPreview(true);
    AMT_MC_M3_ClearJointPreview();
    AMT_MC_ClearNavHighlight();
    ContextPtr:ClearUpdate();
    if Controls.MCScopeOverlay then Controls.MCScopeOverlay:SetHide(true); end
    if Controls.MCPlanningOverlay then
        Controls.MCPlanningOverlay:SetHide(true);
    end
    if Controls.MCApplyOverlay then
        Controls.MCApplyOverlay:SetHide(true);
    end
    if Controls.MCUnsavedOverlay then Controls.MCUnsavedOverlay:SetHide(true); end
    if Controls.MCUniqueClearOverlay then
        Controls.MCUniqueClearOverlay:SetHide(true);
    end
    if Controls.MCAdvancedPanel then
        Controls.MCAdvancedPanel:SetHide(true);
    end
    AMT_MC_M6U.PendingClear = nil;
    m_MCSettingsPanelHidden = false;
    if Controls.MCSettingsRestoreButton then
        Controls.MCSettingsRestoreButton:SetHide(true);
    end
    if UIManager:IsInPopupQueue(ContextPtr) then
        UIManager:DequeuePopup(ContextPtr);
    end
    m_IsOpen = false;
    m_MCSession = nil;
    m_MCPendingScope = nil;
    m_MCMode = false;
    Log("Popup hidden.");
end

function AMT_OnProgressionChanged(playerID)
    if playerID ~= Game.GetLocalPlayer() or not m_IsOpen or m_IsPlanning then
        return;
    end
    OnBackToSettings();
    if m_MCMode and m_MCSession then
        for _, profile in pairs(m_MCSession.profiles) do
            if profile.savedIntent ~= nil then
                profile.reviewState =
                    AMT_MultiCity.UIState.STATUS_REOPTIMIZE;
            end
        end
        AMT_MC_PersistSettings();
    end
    RepopulatePopup();
    if m_ResultText then
        m_ResultText:SetText(Locale.Lookup("LOC_AMT_RULES_REFRESHED"));
    end
end

-- r39 replaces r33's direct multi-city entry with a native chooser.  A mode
-- can only be chosen from a closed planner: no deferred switches or draft loss.
function AMT_MC_ModeSelector.HasLiveState()
    return m_IsPlanning or m_QueuedPlan ~= nil or m_PendingPreview ~= nil
        or m_MCSession ~= nil or m_MCPendingScope ~= nil
        or AMT_MC_M3State.job ~= nil or AMT_MC_M3State.pending ~= nil
        or AMT_MC_M3State.pendingDiff ~= nil;
end

function AMT_MC_ModeSelector.CheckMulti()
    if not AMT_MC_ModulesReady or not AMT_MultiCity
        or type(AMT_MultiCity.Initialize) ~= "function"
        or type(AMT_MultiCity.GetCapabilities) ~= "function"
        or not AMT_MultiCity.Contract or not AMT_MultiCity.Cluster
        or not AMT_MultiCity.UIState or not AMT_MultiCity.Requests
        or not AMT_MultiCity.Solver or not AMT_MultiCity.UniqueDistrict
        or not AMT_MultiCity.Transaction then return false; end
    if AMT_MultiCity.Initialize() ~= true then return false; end
    local cap = AMT_MultiCity.GetCapabilities();
    return type(cap) == "table" and cap.entryEnabled == true
        and cap.selectionEnabled == true and cap.perCitySettingsEnabled == true
        and cap.scopeConfirmationEnabled == true and cap.jointPreviewEnabled == true;
end

function AMT_MC_ModeSelector.RefreshMulti()
    local ok, available = pcall(AMT_MC_ModeSelector.CheckMulti);
    available = ok and available == true;
    Controls.ModeMultiButton:SetDisabled(not available);
    Controls.ModeUnavailableLabel:SetHide(available);
    return available;
end

function AMT_MC_ModeSelector.Close()
    if not AMT_MC_ModeSelector.open then return; end
    AMT_MC_ModeSelector.open = false;
    Controls.ModeChooserBlocker:SetHide(true);
    if UIManager:IsInPopupQueue(ContextPtr) then
        UIManager:DequeuePopup(ContextPtr);
    end
end

function AMT_MC_ModeSelector.Choose(multi)
    if AMT_MC_ModeSelector.shutdown or not AMT_MC_ModeSelector.ready
        or not AMT_MC_ModeSelector.open or m_IsOpen
        or ContextPtr:IsHidden() or AMT_MC_ModeSelector.HasLiveState() then return; end
    if multi and not AMT_MC_ModeSelector.RefreshMulti() then return; end
    -- Leave the chooser queue before ShowPopup: its legacy queue guard must not
    -- skip setting m_IsOpen.  Closing first also rejects duplicate callbacks.
    AMT_MC_ModeSelector.Close();
    m_MCMode = multi == true;
    local ok, err = pcall(ShowPopup);
    if not ok then
        -- UI initialization only (never a solve/apply): discard partial UI
        -- state without saving drafts or touching the existing undo record.
        HidePopup();
        Log("Mode editor open failed: " .. tostring(err));
    end
end

function AMT_OpenPlannerFromEntry()
    if AMT_MC_ModeSelector.shutdown or not AMT_MC_ModeSelector.ready then return; end
    if m_IsOpen then
        -- Both the icon and hotkey restore, never toggle or switch modes.
        if m_MCSettingsPanelHidden then AMT_MC_SetSettingsPanelHidden(false); end
        return;
    end
    if AMT_MC_ModeSelector.open or AMT_MC_ModeSelector.HasLiveState() then return; end
    AMT_MC_ModeSelector.RefreshMulti();
    Controls.SettingsBlocker:SetHide(true);
    Controls.ModeChooserBlocker:SetHide(false);
    AMT_MC_ModeSelector.open = true;
    UIManager:QueuePopup(ContextPtr, PopupPriority.Low);
end

function AMT_MC_ModeSelector.AnnounceReady()
    LuaEvents.AMT_PlannerReady(
        AMT_MC_ModeSelector.ready and not AMT_MC_ModeSelector.shutdown
    );
end

function AMT_MC_ModeSelector.Shutdown()
    if AMT_MC_ModeSelector.shutdown then return; end
    AMT_MC_ModeSelector.shutdown = true;
    AMT_MC_ModeSelector.ready = false;
    AMT_MC_ModeSelector.AnnounceReady();
    AMT_MC_ModeSelector.Close();
    if m_IsOpen then HidePopup(); end
    Events.InputActionTriggered.Remove(OnInputActionTriggered);
    Events.ResearchCompleted.Remove(AMT_OnProgressionChanged);
    Events.CivicCompleted.Remove(AMT_OnProgressionChanged);
    LuaEvents.AMT_OpenPlanner.Remove(AMT_OpenPlannerFromEntry);
    LuaEvents.AMT_RequestPlannerReady.Remove(AMT_MC_ModeSelector.AnnounceReady);
end

function OnInputHandler(pInputStruct)
    local msg = pInputStruct:GetMessageType();
    local key = pInputStruct:GetKey();
    if msg == KeyEvents.KeyDown then
        if key == Keys.VK_ESCAPE and AMT_MC_ModeSelector.open then
            AMT_MC_ModeSelector.Close();
            return true;
        end
        if key == Keys.VK_ESCAPE and m_IsOpen then
            if m_MCSettingsPanelHidden then
                AMT_MC_SetSettingsPanelHidden(false);
            elseif AMT_MC_M3State.job ~= nil then
                -- During the joint solve ESC must cancel the solve, not
                -- fall through to closing the popup (the scope overlay is
                -- hidden behind the planning overlay while solving).
                AMT_MC_M3State.cancelled = true;
            elseif Controls.MCUnsavedOverlay
                and not Controls.MCUnsavedOverlay:IsHidden() then
                Controls.MCUnsavedOverlay:SetHide(true);
            elseif Controls.MCApplyOverlay
                and not Controls.MCApplyOverlay:IsHidden() then
                Controls.MCApplyOverlay:SetHide(true);
                AMT_MC_M3State.pendingDiff = nil;
                AMT_MC_SetPhase(3);
            elseif Controls.MCPlanPreviewOverlay
                and not Controls.MCPlanPreviewOverlay:IsHidden() then
                AMT_MC_M3_ClearJointPreview();
                m_MCPendingScope = nil;
            elseif Controls.MCScopeOverlay
                and not Controls.MCScopeOverlay:IsHidden() then
                AMT_MC_M3_ClearJointPreview();
                Controls.MCScopeOverlay:SetHide(true);
                m_MCPendingScope = nil;
            elseif Controls.MCAdvancedPanel
                and not Controls.MCAdvancedPanel:IsHidden() then
                AMT_MC_SetAdvancedVisible(false);
            elseif m_MCMode then
                AMT_MC_RequestClose();
            else
                HidePopup();
            end
            return true;
        end
    end
    return false;
end

function OnInputActionTriggered(actionId)
    if actionId == m_AutoPlanActionId then
        AMT_OpenPlannerFromEntry();
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

    if Controls.DistrictTabButton then
        Controls.DistrictTabButton:RegisterCallback(Mouse.eLClick, function()
            SwitchPlannerCategory(MAP_PIN_TYPE_DISTRICT);
        end);
    end
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
            AMT_MC_MarkCurrentDraftChanged();
        end);
    end
    if m_ClearManualCheck then
        m_ClearManualCheck:RegisterCheckHandler(function()
            local plan = GetCitySpecialtyPlan(GetSelectedCity());
            if plan then
                plan.clearManualPins = m_ClearManualCheck:IsChecked();
            end
            ClearPendingPreview(true);
            AMT_MC_MarkCurrentDraftChanged();
        end);
    end
    if m_OverwriteCheck then
        m_OverwriteCheck:RegisterCheckHandler(function()
            local plan = GetCitySpecialtyPlan(GetSelectedCity());
            if plan then
                plan.overwriteAutoPins = m_OverwriteCheck:IsChecked();
            end
            ClearPendingPreview(true);
            AMT_MC_MarkCurrentDraftChanged();
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
    if Controls.MCPlanningCancelButton then
        Controls.MCPlanningCancelButton:RegisterCallback(
            Mouse.eLClick,
            function()
                if AMT_MC_M3State.job ~= nil then
                    -- Joint solve: stop resuming the worker on the next
                    -- frame and restore the scope page with a cancelled
                    -- notice.  No pins or settings are touched.
                    AMT_MC_M3State.cancelled = true;
                    Log("Joint planning cancelled by player.");
                end
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
            if m_MCMode then AMT_MC_RequestClose(); else HidePopup(); end
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

    if Controls.MCPreviousCityButton then
        Controls.MCPreviousCityButton:SetToolTipString(Locale.Lookup(
            "LOC_AMT_MC_PREVIOUS_CITY_TOOLTIP"
        ));
        Controls.MCPreviousCityButton:RegisterCallback(
            Mouse.eLClick, function() AMT_MC_CycleCity(-1); end
        );
    end
    if Controls.MCNextCityButton then
        Controls.MCNextCityButton:SetToolTipString(Locale.Lookup(
            "LOC_AMT_MC_NEXT_CITY_TOOLTIP"
        ));
        Controls.MCNextCityButton:RegisterCallback(
            Mouse.eLClick, function() AMT_MC_CycleCity(1); end
        );
    end
    if Controls.MCSettingsHideButton then
        Controls.MCSettingsHideButton:RegisterCallback(
            Mouse.eLClick,
            function() AMT_MC_SetSettingsPanelHidden(true); end
        );
    end
    if Controls.MCSettingsRestoreButton then
        Controls.MCSettingsRestoreButton:RegisterCallback(
            Mouse.eLClick,
            function() AMT_MC_SetSettingsPanelHidden(false); end
        );
    end
    if Controls.MCClearSettingsButton then
        Controls.MCClearSettingsButton:RegisterCallback(
            Mouse.eLClick, AMT_MC_ClearCurrent
        );
    end
    if Controls.MCSaveSettingsButton then
        Controls.MCSaveSettingsButton:RegisterCallback(
            Mouse.eLClick, AMT_MC_SaveCurrent
        );
    end
    if Controls.MCSolveButton then
        Controls.MCSolveButton:RegisterCallback(
            Mouse.eLClick, AMT_MC_OpenScope
        );
    end
    if Controls.MCPrimaryActionButton then
        Controls.MCPrimaryActionButton:RegisterCallback(
            Mouse.eLClick, AMT_MC_HandlePrimaryAction
        );
    end
    if Controls.MCCloseButton then
        Controls.MCCloseButton:RegisterCallback(
            Mouse.eLClick, AMT_MC_RequestClose
        );
    end
    if Controls.MCAutoSelectImprovementsButton then
        Controls.MCAutoSelectImprovementsButton:RegisterCallback(
            Mouse.eLClick, AMT_MC_AutoSelectImprovements
        );
    end
    if Controls.MCUndoAutoSelectButton then
        Controls.MCUndoAutoSelectButton:RegisterCallback(
            Mouse.eLClick, AMT_MC_UndoAutoSelect
        );
    end
    if Controls.MCUniqueClearConfirmButton then
        Controls.MCUniqueClearConfirmButton:RegisterCallback(
            Mouse.eLClick, function()
                Controls.MCUniqueClearOverlay:SetHide(true);
                local participantID = AMT_MC_M6U.PendingClear;
                AMT_MC_M6U.PendingClear = nil;
                if participantID then
                    AMT_MC_M6U_DoClearCurrent(participantID);
                end
            end
        );
    end
    if Controls.MCUniqueClearCancelButton then
        Controls.MCUniqueClearCancelButton:RegisterCallback(
            Mouse.eLClick, function()
                AMT_MC_M6U.PendingClear = nil;
                Controls.MCUniqueClearOverlay:SetHide(true);
            end
        );
    end
    if Controls.MCScopeBackButton then
        Controls.MCScopeBackButton:RegisterCallback(Mouse.eLClick, function()
            AMT_MC_M3_ClearJointPreview();
            Controls.MCScopeOverlay:SetHide(true);
            m_MCPendingScope = nil;
        end);
    end
    if Controls.MCScopeConfirmButton then
        Controls.MCScopeConfirmButton:RegisterCallback(
            Mouse.eLClick,
            function()
                if AMT_MC_M3State.pending ~= nil then
                    AMT_MC_M7_ApplySelectedPlan();
                else
                    AMT_MC_ConfirmScope();
                end
            end
        );
    end
    if Controls.MCScopeCloseButton then
        Controls.MCScopeCloseButton:RegisterCallback(Mouse.eLClick, function()
            AMT_MC_M3_ClearJointPreview();
            Controls.MCScopeOverlay:SetHide(true);
            m_MCPendingScope = nil;
        end);
    end
    for planIndex = 1, 3 do
        local planButton = Controls[
            "MCPlanButton" .. tostring(planIndex)
        ];
        if planButton then
            local selectedPlan = planIndex;
            planButton:RegisterCallback(Mouse.eLClick, function()
                AMT_MC_M3_SelectPlan(selectedPlan);
            end);
        end
        local planCard = Controls[
            "MCPlanCard" .. tostring(planIndex)
        ];
        if planCard then
            local selectedPlan = planIndex;
            planCard:RegisterCallback(Mouse.eLClick, function()
                AMT_MC_M3_SelectPlan(selectedPlan);
            end);
        end
    end
    if Controls.MCPlanPreviewBackButton then
        Controls.MCPlanPreviewBackButton:RegisterCallback(
            Mouse.eLClick, function()
                AMT_MC_M3_ClearJointPreview();
                m_MCPendingScope = nil;
            end
        );
    end
    if Controls.MCPlanPreviewCloseButton then
        Controls.MCPlanPreviewCloseButton:RegisterCallback(
            Mouse.eLClick, function()
                AMT_MC_M3_ClearJointPreview();
                m_MCPendingScope = nil;
                AMT_MC_RequestClose();
            end
        );
    end
    if Controls.MCPlanPreviewApplyButton then
        Controls.MCPlanPreviewApplyButton:RegisterCallback(
            Mouse.eLClick, AMT_MC_M7_ApplySelectedPlan
        );
    end
    if Controls.MCPlanManualConfirmCheck then
        Controls.MCPlanManualConfirmCheck:RegisterCheckHandler(function()
            if Controls.MCPlanPreviewApplyButton then
                Controls.MCPlanPreviewApplyButton:SetDisabled(
                    not Controls.MCPlanManualConfirmCheck:IsChecked()
                );
            end
        end);
    end
    if Controls.MCUnsavedSaveButton then
        Controls.MCUnsavedSaveButton:RegisterCallback(
            Mouse.eLClick, AMT_MC_SaveAllAndClose
        );
    end
    if Controls.MCUnsavedDiscardButton then
        Controls.MCUnsavedDiscardButton:RegisterCallback(
            Mouse.eLClick, AMT_MC_DiscardAllAndClose
        );
    end
    if Controls.MCUnsavedCancelButton then
        Controls.MCUnsavedCancelButton:RegisterCallback(
            Mouse.eLClick,
            function() Controls.MCUnsavedOverlay:SetHide(true); end
        );
    end

    Controls.ModeSingleButton:RegisterCallback(Mouse.eLClick, function()
        AMT_MC_ModeSelector.Choose(false);
    end);
    Controls.ModeMultiButton:RegisterCallback(Mouse.eLClick, function()
        AMT_MC_ModeSelector.Choose(true);
    end);
    Controls.ModeBackButton:RegisterCallback(Mouse.eLClick, AMT_MC_ModeSelector.Close);
    ContextPtr:SetShutdown(AMT_MC_ModeSelector.Shutdown);
    Events.InputActionTriggered.Add(OnInputActionTriggered);
    Events.ResearchCompleted.Add(AMT_OnProgressionChanged);
    Events.CivicCompleted.Add(AMT_OnProgressionChanged);
    LuaEvents.AMT_OpenPlanner.Add(AMT_OpenPlannerFromEntry);
    LuaEvents.AMT_RequestPlannerReady.Add(AMT_MC_ModeSelector.AnnounceReady);
    -- Base planner readiness is independent of optional multi-city modules.
    AMT_MC_ModeSelector.ready = true;
    AMT_MC_ModeSelector.AnnounceReady();

    Log("AMT_Initialize DONE.");
end


AMT_Initialize();
Log("Post-init sanity check complete.");
