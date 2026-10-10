.pragma library

// The model picker's list logic: search ranking, rows and views, and display
// names.
// The catalogue arrives already filtered and ordered (Shell.state.modelPicker).

var FAVORITES = "favorites";
var FAVORITE_SCORE_BOOST = 24;
var JUMP_COUNT = 9;

function normalize(value) {
    return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function scoreSubsequenceMatch(value, query) {
    if (!query)
        return 0;
    var queryIndex = 0;
    var firstMatchIndex = -1;
    var previousMatchIndex = -1;
    var gapPenalty = 0;
    for (var valueIndex = 0; valueIndex < value.length; valueIndex += 1) {
        if (value[valueIndex] !== query[queryIndex])
            continue;
        if (firstMatchIndex === -1)
            firstMatchIndex = valueIndex;
        if (previousMatchIndex !== -1)
            gapPenalty += valueIndex - previousMatchIndex - 1;
        previousMatchIndex = valueIndex;
        queryIndex += 1;
        if (queryIndex === query.length) {
            var spanPenalty = valueIndex - firstMatchIndex + 1 - query.length;
            var lengthPenaltyValue = Math.min(64, value.length - query.length);
            return firstMatchIndex * 2 + gapPenalty * 3 + spanPenalty + lengthPenaltyValue;
        }
    }
    return null;
}

function lengthPenalty(value, query) {
    return Math.min(64, Math.max(0, value.length - query.length));
}

function findBoundaryMatchIndex(value, query) {
    var markers = [" ", "-", "_", "/"];
    var bestIndex = null;
    for (var i = 0; i < markers.length; i += 1) {
        var index = value.indexOf(markers[i] + query);
        if (index === -1)
            continue;
        var matchIndex = index + markers[i].length;
        if (bestIndex === null || matchIndex < bestIndex)
            bestIndex = matchIndex;
    }
    return bestIndex;
}

// scoreQueryMatch with the model picker's tiers: exact, prefix, word
// boundary, substring, then (for 3+ characters) a subsequence.
function scoreToken(value, token, base) {
    if (!value || !token)
        return null;
    if (value === token)
        return base;
    if (value.indexOf(token) === 0)
        return base + 2 + lengthPenalty(value, token);
    var boundaryIndex = findBoundaryMatchIndex(value, token);
    if (boundaryIndex !== null)
        return base + 4 + boundaryIndex * 2 + lengthPenalty(value, token);
    var includesIndex = value.indexOf(token);
    if (includesIndex !== -1)
        return base + 6 + includesIndex * 2 + lengthPenalty(value, token);
    if (token.length >= 3) {
        var fuzzy = scoreSubsequenceMatch(value, token);
        if (fuzzy !== null)
            return base + 100 + fuzzy;
    }
    return null;
}

function searchText(model, instance) {
    return normalize([model.name, model.shortName, model.subProvider, instance.driverKind, instance.displayName].filter(function (value) {
        return typeof value === "string" && value.length > 0;
    }).join(" "));
}

function scoreSearch(model, instance, query) {
    var tokens = normalize(query).split(/\s+/).filter(function (token) {
        return token.length > 0;
    });
    if (tokens.length === 0)
        return 0;
    var fields = [normalize(model.name)];
    if (model.shortName)
        fields.push(normalize(model.shortName));
    if (model.subProvider)
        fields.push(normalize(model.subProvider));
    fields.push(normalize(instance.driverKind), normalize(instance.displayName), searchText(model, instance));
    var score = 0;
    for (var t = 0; t < tokens.length; t += 1) {
        var best = null;
        for (var f = 0; f < fields.length; f += 1) {
            var fieldScore = scoreToken(fields[f], tokens[t], f * 10);
            if (fieldScore !== null && (best === null || fieldScore < best))
                best = fieldScore;
        }
        if (best === null)
            return null;
        score += best;
    }
    return model.isFavorite ? score - FAVORITE_SCORE_BOOST : score;
}

function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function stripLeadingQualifier(value, qualifier) {
    var trimmed = typeof qualifier === "string" ? qualifier.trim() : "";
    if (!trimmed)
        return value;
    var pattern = new RegExp("^" + escapeRegExp(trimmed) + "(?:\\s*[.:/-]\\s*|\\s+)", "i");
    return value.replace(pattern, "").trim() || value;
}

function displayName(model, preferShortName) {
    var name = preferShortName && model.shortName ? model.shortName : model.name;
    return stripLeadingQualifier(name, model.subProvider);
}

function providerLabel(model, instance) {
    return model.subProvider ? instance.displayName + " · " + model.subProvider : instance.displayName;
}

function findInstance(instances, instanceId) {
    for (var i = 0; i < instances.length; i += 1) {
        if (instances[i].instanceId === instanceId)
            return instances[i];
    }
    return null;
}

function findModel(instance, slug) {
    if (!instance)
        return null;
    for (var i = 0; i < instance.models.length; i += 1) {
        if (instance.models[i].slug === slug)
            return instance.models[i];
    }
    return null;
}

function hasFavorites(instances) {
    return instances.some(function (instance) {
        return instance.models.some(function (model) {
            return model.isFavorite;
        });
    });
}

// The rail entry the picker opens on: favourites when there are any, unless
// the thread is locked or its instance is only reachable through its
// current model; otherwise the thread's instance.
function initialView(instances, selectedInstanceId, locked) {
    var active = findInstance(instances, selectedInstanceId);
    var activeNeedsFocus = active !== null && active.isAvailable && active.unavailableReason !== null;
    if (!locked && !activeNeedsFocus && hasFavorites(instances))
        return FAVORITES;
    if (active !== null)
        return active.instanceId;
    for (var i = 0; i < instances.length; i += 1) {
        if (instances[i].isAvailable)
            return instances[i].instanceId;
    }
    return FAVORITES;
}

// The next rail entry for the provider chords: favourites, then every
// instance that can be chosen, wrapping around.
function adjacentView(instances, view, direction) {
    var views = [FAVORITES];
    instances.forEach(function (instance) {
        if (instance.isAvailable)
            views.push(instance.instanceId);
    });
    var index = views.indexOf(view);
    if (index < 0)
        return direction > 0 ? views[0] : views[views.length - 1];
    return views[(index + direction + views.length) % views.length];
}

function modelRow(instance, model) {
    return {
        kind: "model",
        key: instance.instanceId + "\u0000" + model.slug,
        instance: instance,
        model: model,
        jumpIndex: -1
    };
}

// The list's rows for a rail entry and search: model rows, plus the
// collapsible "Legacy models" row inside a provider. The first nine models
// that can be chosen carry their jump index.
function rows(instances, view, query, expandedLegacy) {
    var result = [];
    if (normalize(query).length > 0) {
        var ranked = [];
        instances.forEach(function (instance) {
            instance.models.forEach(function (model) {
                var score = scoreSearch(model, instance, query);
                if (score !== null) {
                    ranked.push({
                        row: modelRow(instance, model),
                        score: score,
                        isFavorite: model.isFavorite,
                        tieBreaker: searchText(model, instance)
                    });
                }
            });
        });
        ranked.sort(function (a, b) {
            if (a.score !== b.score)
                return a.score - b.score;
            if (a.isFavorite !== b.isFavorite)
                return a.isFavorite ? -1 : 1;
            return a.tieBreaker.localeCompare(b.tieBreaker);
        });
        result = ranked.map(function (entry) {
            return entry.row;
        });
    } else if (view === FAVORITES) {
        instances.forEach(function (instance) {
            instance.models.forEach(function (model) {
                if (model.isFavorite)
                    result.push(modelRow(instance, model));
            });
        });
    } else {
        var instance = findInstance(instances, view);
        if (instance !== null) {
            var current = [];
            var legacy = [];
            instance.models.forEach(function (model) {
                (model.isLegacy ? legacy : current).push(modelRow(instance, model));
            });
            result = current;
            if (legacy.length > 0) {
                var expanded = expandedLegacy[instance.instanceId] === true;
                result.push({
                    kind: "legacy",
                    key: "legacy\u0000" + instance.instanceId,
                    instanceId: instance.instanceId,
                    count: legacy.length,
                    expanded: expanded
                });
                if (expanded)
                    result = result.concat(legacy);
            }
        }
    }
    var jumpIndex = 0;
    for (var i = 0; i < result.length && jumpIndex < JUMP_COUNT; i += 1) {
        if (result[i].kind === "model" && result[i].model.disabledReason === null)
            result[i].jumpIndex = jumpIndex++;
    }
    return result;
}

// The web `event.key` (lowercased) for a Qt key, enough for the chords the
// page can bind.
function webKey(key, text) {
    var named = {};
    named[0x01000013] = "arrowup";      // Qt.Key_Up
    named[0x01000015] = "arrowdown";    // Qt.Key_Down
    named[0x01000012] = "arrowleft";    // Qt.Key_Left
    named[0x01000014] = "arrowright";   // Qt.Key_Right
    named[0x01000000] = "escape";
    named[0x01000004] = "enter";
    named[0x01000005] = "enter";
    named[0x01000001] = "tab";
    named[0x20] = " ";
    if (named[key] !== undefined)
        return named[key];
    if (key >= 0x21 && key <= 0x7e)
        return String.fromCharCode(key).toLowerCase();
    return normalize(text);
}

// Whether a Qt key event is the binding's chord. The binding's `metaKey` is
// Command on macOS, which Qt reports as ControlModifier (and Control as
// MetaModifier).
function matches(binding, event, mac) {
    if (!binding)
        return false;
    var ctrl = (event.modifiers & (mac ? Qt.MetaModifier : Qt.ControlModifier)) !== 0;
    var meta = (event.modifiers & (mac ? Qt.ControlModifier : Qt.MetaModifier)) !== 0;
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0;
    var alt = (event.modifiers & Qt.AltModifier) !== 0;
    return binding.ctrlKey === ctrl && binding.metaKey === meta && binding.shiftKey === shift && binding.altKey === alt && binding.key === webKey(event.key, event.text);
}
