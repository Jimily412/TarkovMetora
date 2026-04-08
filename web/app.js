// TarkovMetora - Frontend App
// All communication via SSE from backend. Leaflet for map rendering.

(function() {
'use strict';

// ── Constants ─────────────────────────────────────────────────────────────────

var MAP_NAMES = {
    customs:     'Customs',
    woods:       'Woods',
    factory:     'Factory',
    shoreline:   'Shoreline',
    reserve:     'Reserve',
    interchange: 'Interchange',
    lighthouse:  'Lighthouse',
    streets:     'Streets of Tarkov',
    labs:        'The Lab',
    groundzero:  'Ground Zero',
    unknown:     'Unknown'
};

// Approximate Unity world coordinate bounds per map (mirrors backend)
// Used to set the Leaflet CRS bounds for coordinate->pixel conversion
var MAP_BOUNDS = {
    customs:     { xMin:-500,  xMax:500,  zMin:-500, zMax:500  },
    woods:       { xMin:-900,  xMax:900,  zMin:-900, zMax:900  },
    factory:     { xMin:-200,  xMax:200,  zMin:-200, zMax:200  },
    shoreline:   { xMin:-600,  xMax:800,  zMin:-600, zMax:800  },
    reserve:     { xMin:-600,  xMax:600,  zMin:-600, zMax:600  },
    interchange: { xMin:-600,  xMax:600,  zMin:-600, zMax:600  },
    lighthouse:  { xMin:-600,  xMax:800,  zMin:-800, zMax:800  },
    streets:     { xMin:-600,  xMax:600,  zMin:-600, zMax:600  },
    labs:        { xMin:-300,  xMax:300,  zMin:-300, zMax:300  },
    groundzero:  { xMin:-400,  xMax:400,  zMin:-400, zMax:400  }
};

var FACTION_COLOR = {
    PMC:    '#4a9eff',
    SCAV:   '#5ecf5e',
    SHARED: '#e2b96a',
    All:    '#e2b96a',
    CoopExtraction: '#c76be2'
};

var SQUAD_COLORS = ['#4a9eff','#ef6bca','#6befb8','#ef9d6b','#b86bef','#efef6b'];

// ── State ─────────────────────────────────────────────────────────────────────

var state = {
    currentMap:    null,
    mapData:       null,
    myPosition:    null,
    squadPositions:{},
    eftRunning:    false,
    inRaid:        false,
    sessionCount:  0,
    layers: {
        extracts: true,
        bosses:   true,
        spawns:   true,
        quests:   false
    }
};

// Persist layer prefs
(function loadPrefs() {
    try {
        var saved = JSON.parse(localStorage.getItem('tm_layers') || '{}');
        Object.keys(saved).forEach(function(k) {
            if (k in state.layers) state.layers[k] = saved[k];
        });
    } catch(e) {}
})();

function savePrefs() {
    try { localStorage.setItem('tm_layers', JSON.stringify(state.layers)); } catch(e) {}
}

// ── Map setup ─────────────────────────────────────────────────────────────────

var map = L.map('map', {
    crs:           L.CRS.Simple,
    minZoom:       -3,
    maxZoom:       4,
    zoomControl:   true,
    attributionControl: false
});

// Layer groups
var lg = {
    base:     L.layerGroup().addTo(map),
    extracts: L.layerGroup().addTo(map),
    bosses:   L.layerGroup().addTo(map),
    spawns:   L.layerGroup().addTo(map),
    quests:   L.layerGroup(),   // not added by default
    players:  L.layerGroup().addTo(map)
};

var noMapMsg = document.createElement('div');
noMapMsg.id = 'no-map-msg';
noMapMsg.innerHTML = 'Waiting for position data...<br>Load into a raid in EFT.';
document.body.appendChild(noMapMsg);

// ── Coordinate conversion ─────────────────────────────────────────────────────
// Convert Unity world coords (x, z) to Leaflet LatLng.
// Leaflet Simple CRS: y = lat (vertical), x = lng (horizontal)
// Unity X -> Leaflet lng, Unity Z -> Leaflet lat
function worldToLatLng(wx, wz) {
    return L.latLng(wz, wx);
}

// ── Quaternion -> yaw (radians) ───────────────────────────────────────────────
function quatToYawDeg(qw, qx, qy, qz) {
    // Yaw around Unity Y-axis
    var yaw = Math.atan2(2*(qw*qy + qx*qz), 1 - 2*(qy*qy + qz*qz));
    return yaw * (180 / Math.PI);
}

// ── Arrow SVG icon ─────────────────────────────────────────────────────────────
function makeArrowIcon(color, rotDeg, size) {
    size = size || 32;
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="' + size + '" height="' + size + '" viewBox="0 0 32 32">' +
        '<g transform="rotate(' + rotDeg + ' 16 16)">' +
        '<polygon points="16,4 22,24 16,20 10,24" fill="' + color + '" stroke="#000" stroke-width="1.5"/>' +
        '</g></svg>';
    return L.divIcon({
        html: '<div style="transform:none">' + svg + '</div>',
        iconSize:   [size, size],
        iconAnchor: [size/2, size/2],
        className:  ''
    });
}

// ── Player markers ─────────────────────────────────────────────────────────────

var myMarker    = null;
var squadMarkers= {};

function updateMyMarker(pos) {
    var latlng = worldToLatLng(pos.x, pos.z);
    var yaw    = quatToYawDeg(pos.qw, pos.qx, pos.qy, pos.qz);
    var icon   = makeArrowIcon('#f5c842', yaw, 32);

    if (!myMarker) {
        myMarker = L.marker(latlng, { icon: icon, zIndexOffset: 1000 })
            .bindTooltip('You', { permanent: true, direction: 'right', offset: [10, 0] })
            .addTo(lg.players);
    } else {
        myMarker.setLatLng(latlng);
        myMarker.setIcon(icon);
    }

    // Update coord display
    document.getElementById('coord-display').textContent =
        'X: ' + pos.x.toFixed(2) + '  Y: ' + pos.y.toFixed(2) + '  Z: ' + pos.z.toFixed(2);
}

function updateSquadMarker(player, pos, colorIndex) {
    var latlng = worldToLatLng(pos.x, pos.z);
    var yaw    = quatToYawDeg(pos.qw, pos.qx, pos.qy, pos.qz);
    var color  = SQUAD_COLORS[colorIndex % SQUAD_COLORS.length];
    var icon   = makeArrowIcon(color, yaw, 28);

    if (!squadMarkers[player]) {
        squadMarkers[player] = L.marker(latlng, { icon: icon, zIndexOffset: 900 })
            .bindTooltip(player, { permanent: true, direction: 'right', offset: [10, 0] })
            .addTo(lg.players);
    } else {
        squadMarkers[player].setLatLng(latlng);
        squadMarkers[player].setIcon(icon);
    }
}

// ── Map switching ─────────────────────────────────────────────────────────────

var currentMapLoaded = null;

function switchMap(mapId) {
    if (mapId === currentMapLoaded) return;
    currentMapLoaded = mapId;

    // Clear overlay layers
    lg.extracts.clearLayers();
    lg.bosses.clearLayers();
    lg.spawns.clearLayers();
    lg.quests.clearLayers();
    lg.base.clearLayers();
    // Keep player markers

    noMapMsg.style.display = 'none';

    var bounds = MAP_BOUNDS[mapId];
    if (!bounds) {
        bounds = { xMin:-500, xMax:500, zMin:-500, zMax:500 };
    }

    var sw = worldToLatLng(bounds.xMin, bounds.zMin);
    var ne = worldToLatLng(bounds.xMax, bounds.zMax);
    var leafletBounds = L.latLngBounds(sw, ne);

    // Add background tile (dark gray placeholder)
    L.rectangle(leafletBounds, {
        color: '#1a1a1a',
        fillColor: '#111',
        fillOpacity: 1,
        weight: 1,
        opacity: 0.5
    }).addTo(lg.base);

    // Add grid lines for orientation
    var step = Math.round((bounds.xMax - bounds.xMin) / 10);
    for (var gx = bounds.xMin; gx <= bounds.xMax; gx += step) {
        L.polyline([worldToLatLng(gx, bounds.zMin), worldToLatLng(gx, bounds.zMax)], {
            color: '#1e1e1e', weight: 1, opacity: 0.6
        }).addTo(lg.base);
        L.marker(worldToLatLng(gx, bounds.zMin), {
            icon: L.divIcon({ html: '<span style="color:#333;font-size:10px">' + gx + '</span>', className: '', iconAnchor:[0,0] })
        }).addTo(lg.base);
    }
    for (var gz = bounds.zMin; gz <= bounds.zMax; gz += step) {
        L.polyline([worldToLatLng(bounds.xMin, gz), worldToLatLng(bounds.xMax, gz)], {
            color: '#1e1e1e', weight: 1, opacity: 0.6
        }).addTo(lg.base);
        L.marker(worldToLatLng(bounds.xMin, gz), {
            icon: L.divIcon({ html: '<span style="color:#333;font-size:10px">' + gz + '</span>', className: '', iconAnchor:[0,0] })
        }).addTo(lg.base);
    }

    // Fit map to bounds
    map.fitBounds(leafletBounds, { padding: [20, 20] });

    // Load overlays from cached map data
    if (state.mapData) {
        loadMapOverlays(mapId);
    }

    // Update status bar
    document.getElementById('sb-map').textContent = 'Map: ' + (MAP_NAMES[mapId] || mapId);
}

// ── Map overlays from tarkov.dev data ─────────────────────────────────────────

function loadMapOverlays(mapId) {
    if (!state.mapData || !state.mapData.data || !state.mapData.data.maps) return;

    var mapInfo = null;
    state.mapData.data.maps.forEach(function(m) {
        if (m.normalizedName === mapId || m.name.toLowerCase() === mapId) {
            mapInfo = m;
        }
    });
    if (!mapInfo) return;

    // Extraction points
    if (mapInfo.extracts && state.layers.extracts) {
        mapInfo.extracts.forEach(function(ext) {
            if (!ext.position) return;
            var latlng = worldToLatLng(ext.position.x, ext.position.z);
            var color  = FACTION_COLOR[ext.faction] || '#888';
            var marker = L.circleMarker(latlng, {
                radius: 7, color: color, fillColor: color, fillOpacity: 0.7, weight: 2
            });
            marker.bindTooltip(ext.name + ' [' + (ext.faction || '?') + ']', {
                direction: 'top', offset: [0, -8]
            });
            if (state.layers.extracts) marker.addTo(lg.extracts);
        });
    }

    // Boss spawns
    if (mapInfo.bosses && state.layers.bosses) {
        mapInfo.bosses.forEach(function(bossInfo) {
            if (!bossInfo.boss) return;
            var pct = Math.round((bossInfo.spawnChance || 0) * 100);
            if (bossInfo.spawnLocations && bossInfo.spawnLocations.length > 0) {
                bossInfo.spawnLocations.forEach(function(loc) {
                    // spawnLocations have names, not positions in this API version
                    // Place a text marker at approximate center
                });
            }
            // Boss zone marker at map center as fallback (no position in this query)
            var bounds = MAP_BOUNDS[mapId] || { xMin:-200, xMax:200, zMin:-200, zMax:200 };
            var cx = (bounds.xMin + bounds.xMax) / 2 + (Math.random() - 0.5) * 50;
            var cz = (bounds.zMin + bounds.zMax) / 2 + (Math.random() - 0.5) * 50;
            var latlng = worldToLatLng(cx, cz);
            var icon = L.divIcon({
                html: '<div style="background:#cf4444;color:#fff;font-size:10px;padding:2px 5px;border-radius:3px;border:1px solid #ff6666;white-space:nowrap">' +
                      bossInfo.boss.name + ' ' + pct + '%</div>',
                className: '',
                iconAnchor: [0, 0]
            });
            var m = L.marker(latlng, { icon: icon });
            m.bindTooltip(bossInfo.boss.name + ' - spawn chance: ' + pct + '%', { direction: 'top' });
            if (state.layers.bosses) m.addTo(lg.bosses);
        });
    }

    // Player spawn zones
    if (mapInfo.spawns && state.layers.spawns) {
        mapInfo.spawns.forEach(function(spawn) {
            if (!spawn.position) return;
            var latlng = worldToLatLng(spawn.position.x, spawn.position.z);
            var sides  = (spawn.sides || []).join('/');
            var color  = sides.includes('Pmc') ? '#4a9eff' : (sides.includes('Scav') ? '#5ecf5e' : '#555');
            var marker = L.circleMarker(latlng, {
                radius: 4, color: color, fillColor: color, fillOpacity: 0.5, weight: 1
            });
            marker.bindTooltip(sides || 'spawn', { direction: 'top', offset: [0, -5] });
            if (state.layers.spawns) marker.addTo(lg.spawns);
        });
    }
}

// ── Layer toggles ─────────────────────────────────────────────────────────────

function applyLayerVisibility() {
    if (state.layers.extracts) {
        if (!map.hasLayer(lg.extracts)) map.addLayer(lg.extracts);
    } else {
        map.removeLayer(lg.extracts);
    }
    if (state.layers.bosses) {
        if (!map.hasLayer(lg.bosses)) map.addLayer(lg.bosses);
    } else {
        map.removeLayer(lg.bosses);
    }
    if (state.layers.spawns) {
        if (!map.hasLayer(lg.spawns)) map.addLayer(lg.spawns);
    } else {
        map.removeLayer(lg.spawns);
    }
    if (state.layers.quests) {
        if (!map.hasLayer(lg.quests)) map.addLayer(lg.quests);
    } else {
        map.removeLayer(lg.quests);
    }
}

['extracts','bosses','spawns','quests'].forEach(function(layer) {
    var cb = document.getElementById('layer-' + layer);
    if (!cb) return;
    cb.checked = state.layers[layer];
    cb.addEventListener('change', function() {
        state.layers[layer] = cb.checked;
        savePrefs();
        applyLayerVisibility();
        // Re-render overlays if map is loaded
        if (currentMapLoaded && state.mapData) {
            lg.extracts.clearLayers();
            lg.bosses.clearLayers();
            lg.spawns.clearLayers();
            loadMapOverlays(currentMapLoaded);
        }
    });
});

// ── Status bar updates ────────────────────────────────────────────────────────

function updateStatusBar() {
    var eftEl = document.getElementById('sb-eft');
    eftEl.textContent = 'EFT: ' + (state.eftRunning ? (state.inRaid ? 'In Raid' : 'In Menu') : 'Not Running');
    eftEl.className   = state.eftRunning ? 'ok' : 'error';

    document.getElementById('sb-shots').textContent = 'Shots: ' + state.sessionCount;
}

// ── SSE connection ─────────────────────────────────────────────────────────────

var sseRetryDelay = 1000;
var sseRetryMax   = 30000;
var sseSource     = null;

function connectSSE() {
    var sseEl = document.getElementById('sb-sse');
    sseEl.textContent = 'SSE: Connecting';
    sseEl.className   = '';

    if (sseSource) {
        sseSource.close();
        sseSource = null;
    }

    sseSource = new EventSource('/events');

    sseSource.onopen = function() {
        sseEl.textContent = 'SSE: Connected';
        sseEl.className   = 'ok';
        sseRetryDelay     = 1000;
    };

    sseSource.onmessage = function(e) {
        var msg;
        try { msg = JSON.parse(e.data); } catch(err) { return; }
        handleSSEMessage(msg);
    };

    sseSource.onerror = function() {
        sseEl.textContent = 'SSE: Reconnecting...';
        sseEl.className   = 'error';
        sseSource.close();
        sseSource = null;
        setTimeout(connectSSE, sseRetryDelay);
        sseRetryDelay = Math.min(sseRetryDelay * 2, sseRetryMax);
    };
}

function handleSSEMessage(msg) {
    if (!msg || !msg.type) return;

    switch (msg.type) {
        case 'connected':
            break;

        case 'status':
            state.eftRunning   = msg.eftRunning;
            state.inRaid       = msg.inRaid;
            state.sessionCount = msg.sessionCount || state.sessionCount;
            if (msg.map && msg.map !== 'unknown') {
                state.currentMap = msg.map;
            }
            updateStatusBar();
            break;

        case 'position':
            var isMe = (msg.player === myPlayerName || !msg.player);
            if (isMe) {
                state.myPosition = msg;
                if (msg.map && msg.map !== 'unknown') {
                    if (msg.map !== currentMapLoaded) {
                        switchMap(msg.map);
                    }
                    updateMyMarker(msg);
                }
                state.inRaid = true;
                state.sessionCount++;
                updateStatusBar();
            } else {
                // Squad member
                var idx = Object.keys(state.squadPositions).indexOf(msg.player);
                if (idx === -1) { idx = Object.keys(state.squadPositions).length; }
                state.squadPositions[msg.player] = msg;
                updateSquadMarker(msg.player, msg, idx);
            }
            break;
    }
}

// ── Fetch map data ────────────────────────────────────────────────────────────

function fetchMapData() {
    fetch('/api/mapdata')
        .then(function(r) { return r.ok ? r.json() : null; })
        .then(function(data) {
            if (data && !data.error) {
                state.mapData = data;
                if (currentMapLoaded) {
                    loadMapOverlays(currentMapLoaded);
                }
            }
        })
        .catch(function() {});
}

// ── Player name from DOM or default ──────────────────────────────────────────
var myPlayerName = '';
fetch('/api/status')
    .then(function(r) { return r.json(); })
    .catch(function() { return {}; });

// ── Init ──────────────────────────────────────────────────────────────────────

// Set initial layer checkbox states from saved prefs
['extracts','bosses','spawns','quests'].forEach(function(layer) {
    var cb = document.getElementById('layer-' + layer);
    if (cb) cb.checked = state.layers[layer];
});

// Start with no-map state
map.setView([0, 0], 0);

fetchMapData();
// Refresh map data every 6 hours
setInterval(fetchMapData, 6 * 3600 * 1000);

connectSSE();
updateStatusBar();

// Refresh status every 30 seconds as fallback
setInterval(function() {
    fetch('/api/status')
        .then(function(r) { return r.json(); })
        .then(function(d) {
            if (!d) return;
            // Handled via SSE primarily; this is just a fallback
        })
        .catch(function() {});
}, 30000);

})();
