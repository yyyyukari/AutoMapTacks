from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "AutoMapTacks"


def validate_inline_metadata(
    modinfo_root: ET.Element,
    expected_tags: set[str],
    expected_languages: set[str],
    label: str,
) -> list[str]:
    errors: list[str] = []
    container = modinfo_root.find("./LocalizedText")
    if container is None:
        return [f"{label} modinfo is missing top-level LocalizedText"]
    if container.findall("./File"):
        errors.append(
            f"{label} modinfo must inline browser metadata instead of "
            "referencing a file under LocalizedText"
        )
    nodes = {
        element.attrib.get("id"): element
        for element in container.findall("./Text")
        if element.attrib.get("id")
    }
    missing_tags = sorted(expected_tags - set(nodes))
    if missing_tags:
        errors.append(
            f"{label} modinfo is missing inline metadata: "
            + ", ".join(missing_tags)
        )
    for tag in sorted(expected_tags & set(nodes)):
        values = {
            child.tag: (child.text or "").strip()
            for child in list(nodes[tag])
        }
        missing_languages = sorted(expected_languages - set(values))
        if missing_languages:
            errors.append(
                f"{label} inline metadata {tag} is missing languages: "
                + ", ".join(missing_languages)
            )
        empty_languages = sorted(
            language
            for language in expected_languages & set(values)
            if not values[language] or values[language] == tag
        )
        if empty_languages:
            errors.append(
                f"{label} inline metadata {tag} has empty/raw-key values: "
                + ", ".join(empty_languages)
            )
    return errors


def strip_lua(source: str) -> str:
    out: list[str] = []
    i = 0
    while i < len(source):
        if source.startswith("--[[", i):
            end = source.find("]]", i + 4)
            text = source[i : len(source) if end < 0 else end + 2]
            out.append("\n" * text.count("\n"))
            i += len(text)
        elif source.startswith("--", i):
            end = source.find("\n", i + 2)
            if end < 0:
                break
            out.append("\n")
            i = end + 1
        elif source.startswith("[[", i):
            end = source.find("]]", i + 2)
            text = source[i : len(source) if end < 0 else end + 2]
            out.append("\n" * text.count("\n"))
            i += len(text)
        elif source[i] in {'"', "'"}:
            quote = source[i]
            start = i
            i += 1
            while i < len(source):
                if source[i] == "\\":
                    i += 2
                elif source[i] == quote:
                    i += 1
                    break
                else:
                    i += 1
            out.append("\n" * source[start:i].count("\n"))
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def validate_lua(path: Path) -> list[str]:
    errors: list[str] = []
    source = path.read_text(encoding="utf-8")
    clean = strip_lua(source)
    pairs = {")": "(", "]": "[", "}": "{"}
    stack: list[tuple[str, int]] = []
    for line_no, line in enumerate(clean.splitlines(), 1):
        for char in line:
            if char in "([{":
                stack.append((char, line_no))
            elif char in ")]}":
                if not stack or stack[-1][0] != pairs[char]:
                    errors.append(f"{path.name}:{line_no}: unmatched {char}")
                else:
                    stack.pop()
    for char, line_no in stack[-10:]:
        errors.append(f"{path.name}:{line_no}: unclosed {char}")

    tokens = [
        (match.group(0), clean.count("\n", 0, match.start()) + 1)
        for match in re.finditer(r"\b(function|if|for|while|do|repeat|until|end)\b", clean)
    ]
    blocks: list[tuple[str, int]] = []
    pending_do = 0
    for token, line_no in tokens:
        if token in {"function", "if"}:
            blocks.append((token, line_no))
        elif token in {"for", "while"}:
            blocks.append((token, line_no))
            pending_do += 1
        elif token == "do":
            if pending_do:
                pending_do -= 1
            else:
                blocks.append((token, line_no))
        elif token == "repeat":
            blocks.append((token, line_no))
        elif token == "until":
            if not blocks or blocks[-1][0] != "repeat":
                errors.append(f"{path.name}:{line_no}: until without repeat")
            else:
                blocks.pop()
        elif token == "end":
            if not blocks or blocks[-1][0] == "repeat":
                errors.append(f"{path.name}:{line_no}: unexpected end")
            else:
                blocks.pop()
    for token, line_no in blocks[-10:]:
        errors.append(f"{path.name}:{line_no}: unclosed {token}")

    top_locals = len(re.findall(r"(?m)^local\s+", clean))
    if top_locals > 200:
        errors.append(f"{path.name}: top-level local count {top_locals} exceeds 200")
    else:
        print(f"Lua lexical check: {len(source.splitlines())} lines, {top_locals} top-level locals")
    return errors


def main() -> int:
    global MOD
    release_mode = "--release" in sys.argv[1:]
    test_mode = "--test" in sys.argv[1:]
    unknown_args = [
        arg for arg in sys.argv[1:] if arg not in {"--release", "--test"}
    ]
    if unknown_args:
        print("Unknown arguments: " + ", ".join(unknown_args))
        return 2
    if release_mode and test_mode:
        print("--release and --test cannot be used together")
        return 2
    if test_mode:
        MOD = ROOT / "AutoMapTacksTest"

    errors: list[str] = []
    xml_roots: list[ET.Element] = []
    for path in MOD.glob("*.xml"):
        try:
            xml_roots.append(ET.parse(path).getroot())
            print(f"XML OK: {path.name}")
        except ET.ParseError as exc:
            errors.append(f"{path.name}: {exc}")

    text_root = ET.parse(MOD / "amt_text.xml").getroot()
    tags = {
        element.attrib["Tag"]
        for element in text_root.iter()
        if "Tag" in element.attrib
    }
    refs: set[str] = set()
    for root in xml_roots:
        for element in root.iter():
            for value in element.attrib.values():
                if value.startswith("LOC_AMT_"):
                    refs.add(value)
    lua_sources = {
        path.name: path.read_text(encoding="utf-8")
        for path in MOD.glob("*.lua")
    }
    lua = lua_sources["amt_autoplanner.lua"]
    wonder_lua = lua_sources.get("amt_wonderplanner.lua", "")
    for source in lua_sources.values():
        refs.update(re.findall(r'"(LOC_AMT_[A-Z0-9_]+)"', source))
    missing = sorted(ref for ref in refs if ref not in tags)
    if missing:
        errors.append("Missing localization: " + ", ".join(missing))
    else:
        print(f"Localization OK: {len(refs)} referenced tags")

    base_tags = {
        element.attrib["Tag"]
        for element in text_root.iter("Row")
        if "Tag" in element.attrib
    }
    zh_tags = {
        element.attrib["Tag"]
        for element in text_root.iter("Replace")
        if element.attrib.get("Language") == "zh_Hans_CN"
        and "Tag" in element.attrib
    }
    missing_zh = sorted(base_tags - zh_tags)
    if missing_zh:
        errors.append(
            "Missing zh_Hans_CN localization: " + ", ".join(missing_zh)
        )
    else:
        print(f"Chinese localization OK: {len(zh_tags)} tags")

    zh_hant_tags = {
        element.attrib["Tag"]
        for element in text_root.iter("Replace")
        if element.attrib.get("Language") == "zh_Hant_HK"
        and "Tag" in element.attrib
    }
    missing_zh_hant = sorted(base_tags - zh_hant_tags)
    if missing_zh_hant:
        errors.append(
            "Missing zh_Hant_HK localization: "
            + ", ".join(missing_zh_hant)
        )
    else:
        print(
            "Traditional Chinese localization OK: "
            f"{len(zh_hant_tags)} tags"
        )

    metadata_tags = (
        {
            "LOC_AMT_RC_MOD_NAME",
            "LOC_AMT_RC_MOD_TEASER",
            "LOC_AMT_RC_MOD_DESCRIPTION",
        }
        if test_mode
        else {
            "LOC_AMT_V60_MOD_NAME",
            "LOC_AMT_V60_MOD_TEASER",
            "LOC_AMT_V60_MOD_DESCRIPTION",
        }
    )
    supported_languages = {
        "de_DE",
        "es_ES",
        "fr_FR",
        "it_IT",
        "ja_JP",
        "ko_KR",
        "pl_PL",
        "pt_BR",
        "ru_RU",
        "zh_Hans_CN",
        "zh_Hant_HK",
    }
    metadata_by_language: dict[str, set[str]] = {}
    for element in text_root.iter("Replace"):
        language = element.attrib.get("Language")
        tag = element.attrib.get("Tag")
        if language and tag in metadata_tags:
            metadata_by_language.setdefault(language, set()).add(tag)
    incomplete_metadata = []
    for language in sorted(supported_languages):
        missing_tags = sorted(
            metadata_tags - metadata_by_language.get(language, set())
        )
        if missing_tags:
            incomplete_metadata.append(
                f"{language}: {', '.join(missing_tags)}"
            )
    if incomplete_metadata:
        errors.append(
            "Missing supported-language mod metadata: "
            + "; ".join(incomplete_metadata)
        )
    else:
        print(
            "Supported-language mod metadata OK: English plus "
            f"{len(supported_languages)} explicit language entries"
        )

    ui_root = ET.parse(MOD / "amt_autoplanner.xml").getroot()
    ids = {
        element.attrib["ID"]
        for element in ui_root.iter()
        if "ID" in element.attrib
    }
    control_refs = set(re.findall(r"\bControls\.([A-Za-z_][A-Za-z0-9_]*)", lua))
    missing_controls = sorted(control_refs - ids)
    if missing_controls:
        errors.append("Missing controls: " + ", ".join(missing_controls))
    else:
        print(f"Controls OK: {len(control_refs)} Lua references")

    entry_root = ET.parse(MOD / "amt_entry.xml").getroot()
    entry_ids = {
        element.attrib["ID"]
        for element in entry_root.iter()
        if "ID" in element.attrib
    }
    entry_refs = set(re.findall(
        r"\bControls\.([A-Za-z_][A-Za-z0-9_]*)",
        lua_sources["amt_entry.lua"],
    ))
    missing_entry_controls = sorted(entry_refs - entry_ids)
    if missing_entry_controls:
        errors.append(
            "Missing entry controls: " + ", ".join(missing_entry_controls)
        )
    else:
        print(f"Entry controls OK: {len(entry_refs)} Lua references")

    semantic_requirements = {
        "hidden-resource visibility gate":
            "ImprovementPlacement.GetVisibleResource" in lua
            and "IsResourceVisible" in lua,
        "revealed-resource improvement exclusivity":
            "if resource then return matchesResource; end" in lua,
        "enforced resource-and-terrain placement":
            "IsTrue(row.EnforceTerrain)" in lua,
        "protected-resource district exclusion":
            "ImprovementPlacement.GetActualVisibleResource" in lua
            and 'resourceClass ~= "RESOURCECLASS_LUXURY"' in lua
            and 'resourceClass ~= "RESOURCECLASS_STRATEGIC"' in lua,
        "revealed strategic-resource priority":
            "strategicResourceCount" in lua
            and "RESOURCECLASS_STRATEGIC" in lua,
        "newly revealed resource refresh":
            "GetStaleAutoResourcePinKeys" in lua
            and "staleResourcePinKeys" in lua,
        "current-city ownership gate":
            'm_PlanningHorizon == "CURRENT"' in lua
            and "unavailableInCurrentMode" in lua,
        "population-based improvement budget":
            "GetImprovementPopulationBudget" in lua
            and "targetImprovedPlots" in lua,
        "population-budget skipped reason":
            "LOC_AMT_REASON_IMPROVEMENT_BUDGET" in lua,
        "adjustable planning-population budget":
            "populationBudgetByCity" in lua
            and "PopulationBudgetLabel" in control_refs
            and "PopulationWarning" in control_refs,
        "population-limited specialty slots":
            "plannedAllowed" in lua
            and "LOC_AMT_POPULATION_BUDGET_WARNING" in lua,
        "separated planning report":
            "SkippedScroll" in control_refs
            and "SkippedStack" in control_refs
            and "LOC_AMT_REPORT_SUMMARY" in lua,
        "cancellable staged calculation":
            "AMT_YieldPlanning" in lua
            and "PlanningCancelButton" in control_refs,
        "single-city public planning":
            "local linked = false" in lua,
        "per-city planner state":
            "ActivateCityPlannerState" in lua
            and "selectedSubjects = {" in lua
            and "plan.planningHorizon" in lua,
        "completed and founded districts locked per city":
            "GetCityPurchasedPlots" in lua
            and "GetLockedSpecialtyDistricts" in lua
            and "LOC_AMT_SLOT_LOCKED" in lua
            and "IsDistrictAlreadyInCity(city, option.subjectKey)" in lua,
        "current-city generated tack clearing":
            "BuildClearPinKeysForCity" in lua
            and "GetPinPlanningCityID" in lua
            and "preview.clearPinKeys" in lua,
        "global last-plan undo remains independent":
            "LoadLastPlan(playerID)" in lua
            and "function OnUndoLastPlan()" in lua,
        "technology and civic refresh":
            "Events.ResearchCompleted.Add(AMT_OnProgressionChanged)" in lua
            and "Events.CivicCompleted.Add(AMT_OnProgressionChanged)" in lua,
        "independent entry button":
            "LuaEvents.AMT_OpenPlanner" in lua
            and "LuaEvents.AMT_OpenPlanner" in lua_sources["amt_entry.lua"],
        "deferred wonder placement validation":
            "GetMissingWonderSupports" in lua
            and "GameInfo.Buildings" in lua
            and "AdjacentDistrict" in lua
            and "AdjacentImprovement" in lua
            and "AdjacentDistrict" in wonder_lua
            and "AMT_WonderPlanner.CanUseRawCandidate" in lua
            and "WithSimulationOverlay" in lua
            and "pcall(CanPlacePin, playerID, subject)" in lua
            and "pcall(UpdatePinYields, playerID, {})" in lua
            and "AdjacentImprovement" in wonder_lua,
        "automatic wonder support bundles":
            "BuildWonderSupportBundles" in lua
            and "candidate.supportItems" in lua
            and "GetCandidateAdditions" in lua,
        "disabled wonder diagnostics are optional":
            lua.count("if wonderDiagnostic then") >= 6,
        "shared wonder support reuse":
            "CanReuseWonderSupport" in lua
            and "proposedAdditions" in lua,
        "selected wonder spatial effects":
            "AMT_WonderPlanner.ScoreSelectedSpatialEffects" in lua
            and "EFFECT_ADJUST_PLOT_YIELD" in wonder_lua
            and "EFFECT_ADJUST_CITY_YIELD_MODIFIER" in wonder_lua,
        "selected wonder appeal projection":
            "AMT_WonderPlanner.GetSelectedAppealDelta" in lua
            and "EFFECT_ADJUST_CITY_APPEAL" in wonder_lua,
    }
    for requirement, satisfied in semantic_requirements.items():
        if not satisfied:
            errors.append("Missing semantic requirement: " + requirement)
    multi_city = ui_root.find(".//*[@ID='MultiCityCheck']")
    if multi_city is None or multi_city.attrib.get("Hidden") != "1":
        errors.append("MultiCityCheck must stay hidden in the public UI")
    else:
        print(
            "Release semantics OK: "
            + ", ".join(semantic_requirements)
        )

    for lua_path in MOD.glob("*.lua"):
        errors.extend(validate_lua(lua_path))

    modinfo_root = ET.parse(MOD / "AutoMapTacks.modinfo").getroot()
    modinfo_loc_refs = {
        (element.text or "").strip()
        for element in modinfo_root.findall("./Properties/*")
        if (element.text or "").strip().startswith("LOC_AMT_")
    }
    missing_modinfo_loc = sorted(modinfo_loc_refs - tags)
    if missing_modinfo_loc:
        errors.append(
            "Missing modinfo localization: " + ", ".join(missing_modinfo_loc)
        )
    else:
        print(
            "Modinfo localization OK: "
            f"{len(modinfo_loc_refs)} referenced tags"
        )
    if test_mode:
        profiler_markers = {
            "test profiler load marker": "TEST PERF v68",
            "profiler session start": 'AMT_Perf.Begin("PLAN_PREVIEW"',
            "phase timing": '"phase.beam_search"',
            "exact evaluation timing": '"component.evaluate_total"',
            "per-subject candidate counts": "[AMTPERF] SUBJECT",
            "search expansion counts": "[AMTPERF] SEARCH",
            "enforced resource-and-terrain placement":
                "IsTrue(row.EnforceTerrain)",
            "whole-plan cache disabled": "evaluate.cacheDisabled",
            "local yield cache": "AMT_GetLocalYieldCacheKey",
            "bounded local yield cache": "yieldEvaluationLimit = 4096",
            "weighted yield score cache": "AMT_GetWeightedYieldScore",
            "scope-aware fixed-yield fast path":
                "AMT_InfluenceScope.FixedNeedsDynamic",
            "conservative scope fallback": "yield.fixedScopeFallback",
            "per-subject scope diagnostics": "[AMTPERF] SCOPE",
            "inactive owner requirement filter":
                "scope.modifierInactiveForPlayer",
            "non-yield modifier filter": "scope.nonYieldModifierIgnored",
            "state-yield dependency sentinel":
                "AMT_InfluenceScope.BuildStateYieldDependencies",
            "state dependency diagnostics": "[AMTPERF] STATE_DEPENDENCY",
            "runtime modifier relevance scan":
                "AMT_InfluenceScope.BuildRuntimeModifierRelevance",
            "inactive dependency diagnostics":
                "[AMTPERF] STATE_DEPENDENCY_SKIPPED",
            "dependent-state scope promotion":
                "scope.stateDependencyPromoted",
            "cache-neutral effect classifier":
                "AMT_InfluenceScope.IsCacheNeutralEffect",
            "cache-neutral effect diagnostics":
                "scope.cacheNeutralModifierIgnored",
            "unsafe dynamic cache bypass":
                "yield.fixedDynamicCacheBypassed",
            "unsafe new-item cache bypass":
                "yield.newDynamicCacheBypassed",
            "final plan signature": "AMT_Perf.RecordFinalPlan",
            "post-run garbage collection": "AMT_Perf.CollectAfterRun",
            "delayed garbage collection": "[AMTPERF] DELAYED_GC",
            "memory counter normalization": "AMT_Perf.NormalizeMemoryKB",
            "complete report marker": "[AMTPERF] REPORT_COMPLETE",
            "shared wonder support reuse": "CanReuseWonderSupport",
            "shared wonder support diagnostics":
                "search.wonderSupportReused",
        }
        for label, marker in profiler_markers.items():
            if marker not in lua:
                errors.append(
                    f"Test package is missing {label}: {marker!r}"
                )
        expected_test_metadata = {
            "Name": "LOC_AMT_RC_MOD_NAME",
            "Teaser": "LOC_AMT_RC_MOD_TEASER",
            "Description": "LOC_AMT_RC_MOD_DESCRIPTION",
            "Authors": "yyyyukari",
        }
        if modinfo_root.attrib.get("id") != (
            "2d7cc51a-3d0f-4d98-83f6-0dc24b9c7a45"
        ):
            errors.append("Test modinfo does not use the isolated RC UUID")
        if modinfo_root.attrib.get("version") != "60":
            errors.append("Test modinfo version must be 60")
        for field, expected in expected_test_metadata.items():
            actual = modinfo_root.findtext(f"./Properties/{field}")
            if actual != expected:
                errors.append(
                    f"Test modinfo {field} must be {expected!r}, got {actual!r}"
                )
        errors.extend(validate_inline_metadata(
            modinfo_root,
            metadata_tags,
            supported_languages | {"en_US"},
            "Test",
        ))
        forbidden_public_metadata = {
            "LOC_AMT_MOD_NAME",
            "LOC_AMT_MOD_TEASER",
            "LOC_AMT_MOD_DESCRIPTION",
            "LOC_AMT_V59_MOD_NAME",
            "LOC_AMT_V59_MOD_TEASER",
            "LOC_AMT_V59_MOD_DESCRIPTION",
            "LOC_AMT_V60_MOD_NAME",
            "LOC_AMT_V60_MOD_TEASER",
            "LOC_AMT_V60_MOD_DESCRIPTION",
        }
        leaked_metadata = sorted(forbidden_public_metadata & tags)
        if leaked_metadata:
            errors.append(
                "Test package must not redefine public mod metadata: "
                + ", ".join(leaked_metadata)
            )
        if not any(error.startswith("Test ") for error in errors):
            print("Isolated test identity and metadata namespace OK")
    if release_mode:
        if "AMT_Perf" in lua or "[AMTPERF]" in lua:
            errors.append(
                "Release package must not contain test performance instrumentation"
            )
        expected_metadata = {
            "Name": "LOC_AMT_V60_MOD_NAME",
            "Teaser": "LOC_AMT_V60_MOD_TEASER",
            "Description": "LOC_AMT_V60_MOD_DESCRIPTION",
            "Authors": "yyyyukari",
        }
        if modinfo_root.attrib.get("id") != (
            "a3f7d2e1-9c4b-4e8a-bb13-7d11f9c2a04e"
        ):
            errors.append("Release modinfo does not use the canonical UUID")
        if modinfo_root.attrib.get("version") != "60":
            errors.append("Release modinfo version must be 60")
        for field, expected in expected_metadata.items():
            actual = modinfo_root.findtext(f"./Properties/{field}")
            if actual != expected:
                errors.append(
                    f"Release modinfo {field} must be {expected!r}, got {actual!r}"
                )
        errors.extend(validate_inline_metadata(
            modinfo_root,
            metadata_tags,
            supported_languages | {"en_US"},
            "Release",
        ))

        forbidden_patterns = {
            "test marker": re.compile(r"TEST\s+v\d+"),
            "diagnostic marker": re.compile(r"DIAGNOSTIC|诊断版|診斷版"),
            "stale v44 marker": re.compile(r"v44"),
            "legacy browser metadata key": re.compile(
                r"LOC_AMT_MOD_(?:NAME|TEASER|DESCRIPTION)"
            ),
        }
        for path in MOD.iterdir():
            if not path.is_file():
                continue
            source = path.read_text(encoding="utf-8")
            for label, pattern in forbidden_patterns.items():
                if pattern.search(source):
                    errors.append(f"Release package contains {label}: {path.name}")

        metadata_descriptions = [
            element
            for element in text_root.iter()
            if element.attrib.get("Tag") == "LOC_AMT_V60_MOD_DESCRIPTION"
        ]
        for element in metadata_descriptions:
            text = "".join(element.itertext()).strip()
            language = element.attrib.get("Language", "en_US")
            if not text.endswith("[v60]"):
                errors.append(
                    "Release description must end with [v60]: " + language
                )
        inline_description = modinfo_root.find(
            "./LocalizedText/Text[@id='LOC_AMT_V60_MOD_DESCRIPTION']"
        )
        if inline_description is not None:
            for element in list(inline_description):
                if not (element.text or "").strip().endswith("[v60]"):
                    errors.append(
                        "Inline release description must end with [v60]: "
                        + element.tag
                    )
        if not errors:
            print("Release identity and public metadata OK")

    declared_files = {
        (element.text or "").strip()
        for element in modinfo_root.findall(".//File")
        if (element.text or "").strip()
    }
    actual_files = {
        path.name
        for path in MOD.iterdir()
        if path.is_file() and path.name != "AutoMapTacks.modinfo"
    }
    undeclared = sorted(actual_files - declared_files)
    missing_declared = sorted(
        name for name in declared_files if not (MOD / name).is_file()
    )
    if undeclared:
        errors.append("Files missing from modinfo: " + ", ".join(undeclared))
    if missing_declared:
        errors.append(
            "Declared files missing on disk: " + ", ".join(missing_declared)
        )
    if not undeclared and not missing_declared:
        print(f"Modinfo files OK: {len(declared_files)} declared files")
    publish_script = (
        ROOT / "release" / "publish_workshop_update.ps1"
    ).read_text(encoding="utf-8")
    unstaged = sorted(
        name for name in actual_files | {"AutoMapTacks.modinfo"}
        if f'"{name}"' not in publish_script
    )
    if unstaged:
        errors.append(
            "Workshop publishing script does not stage: "
            + ", ".join(unstaged)
        )
    else:
        print(
            "Workshop staging OK: "
            f"{len(actual_files) + 1} current files"
        )
    if errors:
        print("\nVALIDATION FAILED")
        for error in errors:
            print("- " + error)
        return 1
    print("\nVALIDATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
