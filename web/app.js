// TarkovMetora v1.0.0 - Frontend
// Receives real-time position via SSE. Renders on Leaflet Simple CRS map.

(function () {
'use strict';

// ---------------------------------------------------------------------------
// Map display names and world-space bounds (mirrors backend MAP_BOUNDS)
// ---------------------------------------------------------------------------
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
    PMC:            '#4a9eff',
    Pmc:            '#4a9eff',
    SCAV:           '#5ecf5e',
    Scav:           '#5ecf5e',
    SHARED:         '#e2b96a',
    All:            '#e2b96a',
    SharedWithScav: '#e2b96a',
    CoopExtraction: '#c76be2'
};

var SQUAD_COLORS = ['#4a9eff', '#ef6bca', '#6befb8', '#ef9d6b', '#b86bef', '#efef6b'];

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
var myPlayerName  = '';
var currentMap    = null;
var mapData       = null;
var myMarker      = null;
var squadMarkers  = {};
var squadColorIdx = {};

var layerState = { extracts: true, bosses: true, spawns: true, quests: false };
try {
    var saved = JSON.parse(localStorage.getItem('tm_layers') || '{}');
    Object.keys(saved).forEach(function (k) { if (k in layerState) layerState[k] = saved[k]; });
} catch (e) {}

function saveLayerPrefs() {
    try { localStorage.setItem('tm_layers', JSON.stringify(layerState)); } catch (e) {}
}

// ---------------------------------------------------------------------------
// Leaflet map (Simple CRS - no tiles, pure coordinate plane)
// ---------------------------------------------------------------------------
var map = L.map('map', {
    crs:              L.CRS.Simple,
    minZoom:          -4,
    maxZoom:          4,
    zoomControl:      true,
    attributionControl: false
});

var lg = {
    base:    L.layerGroup().addTo(map),
    extracts:L.layerGroup().addTo(map),
    bosses:  L.layerGroup().addTo(map),
    spawns:  L.layerGroup().addTo(map),
    quests:  L.layerGroup(),
    players: L.layerGroup().addTo(map)
};

map.setView([0, 0], 0);

// ---------------------------------------------------------------------------
// Coordinate helpers
// Unity world X -> Leaflet lng, Unity world Z -> Leaflet lat
// ---------------------------------------------------------------------------
function w2ll(wx, wz) { return L.latLng(wz, wx); }

function quatYawDeg(qw, qx, qy, qz) {
    var yaw = Math.atan2(2 * (qw * qy + qx * qz), 1 - 2 * (qy * qy + qz * qz));
    return yaw * (180 / Math.PI);
}

function arrowIcon(color, rotDeg, sz) {
    sz = sz || 32;
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="' + sz + '" height="' + sz + '" viewBox="0 0 32 32">' +
        '<g transform="rotate(' + rotDeg + ' 16 16)">' +
        '<polygon points="16,3 23,26 16,21 9,26" fill="' + color + '" stroke="#000" stroke-width="1.5" stroke-linejoin="round"/>' +
        '</g></svg>';
    return L.divIcon({
        html:      svg,
        iconSize:  [sz, sz],
        iconAnchor:[sz / 2, sz / 2],
        className: ''
    });
}

// ---------------------------------------------------------------------------
// Player markers
// ---------------------------------------------------------------------------
function updateMyMarker(pos) {
    var ll  = w2ll(pos.x, pos.z);
    var yaw = quatYawDeg(pos.qw, pos.qx, pos.qy, pos.qz);
    var ico = arrowIcon('#f5c842', yaw, 34);

    if (!myMarker) {
        myMarker = L.marker(ll, { icon: ico, zIndexOffset: 1000 })
            .bindTooltip(myPlayerName || 'You', { permanent: true, direction: 'right', offset: [14, 0] })
            .addTo(lg.players);
    } else {
        myMarker.setLatLng(ll).setIcon(ico);
    }

    document.getElementById('coord-display').textContent =
        'X: ' + pos.x.toFixed(2) + '   Y: ' + pos.y.toFixed(2) + '   Z: ' + pos.z.toFixed(2);
}

function updateSquadMarker(player, pos) {
    if (!(player in squadColorIdx)) {
        squadColorIdx[player] = Object.keys(squadColorIdx).length % SQUAD_COLORS.length;
    }
    var color = SQUAD_COLORS[squadColorIdx[player]];
    var ll    = w2ll(pos.x, pos.z);
    var yaw   = quatYawDeg(pos.qw, pos.qx, pos.qy, pos.qz);
    var ico   = arrowIcon(color, yaw, 28);

    if (!squadMarkers[player]) {
        squadMarkers[player] = L.marker(ll, { icon: ico, zIndexOffset: 900 })
            .bindTooltip(player, { permanent: true, direction: 'right', offset: [12, 0] })
            .addTo(lg.players);
    } else {
        squadMarkers[player].setLatLng(ll).setIcon(ico);
    }
}

// ---------------------------------------------------------------------------
// Map switching - called when a new mapId is detected from position data
// ---------------------------------------------------------------------------
function switchMap(mapId) {
    if (mapId === currentMap) return;
    currentMap = mapId;

    lg.base.clearLayers();
    lg.extracts.clearLayers();
    lg.bosses.clearLayers();
    lg.spawns.clearLayers();
    lg.quests.clearLayers();

    var noMsg = document.getElementById('no-map-msg');
    if (noMsg) noMsg.style.display = 'none';

    var b = MAP_BOUNDS[mapId] || { xMin: -500, xMax: 500, zMin: -500, zMax: 500 };
    var sw = w2ll(b.xMin, b.zMin);
    var ne = w2ll(b.xMax, b.zMax);
    var lb = L.latLngBounds(sw, ne);

    // Dark background
    L.rectangle(lb, {
        color: '#252525', fillColor: '#151515', fillOpacity: 1, weight: 1
    }).addTo(lg.base);

    // Subtle grid
    var step = Math.round((b.xMax - b.xMin) / 8);
    if (step < 1) step = 50;
    for (var gx = Math.ceil(b.xMin / step) * step; gx <= b.xMax; gx += step) {
        L.polyline([w2ll(gx, b.zMin), w2ll(gx, b.zMax)], { color: '#222', weight: 1 }).addTo(lg.base);
    }
    for (var gz = Math.ceil(b.zMin / step) * step; gz <= b.zMax; gz += step) {
        L.polyline([w2ll(b.xMin, gz), w2ll(b.xMax, gz)], { color: '#222', weight: 1 }).addTo(lg.base);
    }

    map.fitBounds(lb, { padding: [30, 30] });

    document.getElementById('sb-map').textContent = 'Map: ' + (MAP_NAMES[mapId] || mapId);

    if (mapData) loadOverlays(mapId);
}

// ---------------------------------------------------------------------------
// tarkov.dev overlay rendering
// ---------------------------------------------------------------------------
function loadOverlays(mapId) {
    if (!mapData || !mapData.data || !mapData.data.maps) return;

    var info = null;
    mapData.data.maps.forEach(function (m) {
        if (m.normalizedName === mapId || (m.name && m.name.toLowerCase() === mapId)) info = m;
    });
    if (!info) return;

    // Extractions
    if (layerState.extracts && info.extracts) {
        info.extracts.forEach(function (ext) {
            if (!ext.position) return;
            var color = FACTION_COLOR[ext.faction] || '#888';
            L.circleMarker(w2ll(ext.position.x, ext.position.z), {
                radius: 7, color: color, fillColor: color, fillOpacity: 0.75, weight: 2
            }).bindTooltip(ext.name + ' [' + (ext.faction || '?') + ']', { direction: 'top' })
              .addTo(lg.extracts);
        });
    }

    // Boss spawns
    if (layerState.bosses && info.bosses) {
        info.bosses.forEach(function (bi) {
            if (!bi.boss) return;
            var pct = Math.round((bi.spawnChance || 0) * 100);
            var bnd = MAP_BOUNDS[mapId] || { xMin: -200, xMax: 200, zMin: -200, zMax: 200 };
            // Distribute boss labels across map area so they don't all overlap
            var seed = 0;
            for (var ci = 0; ci < bi.boss.name.length; ci++) seed += bi.boss.name.charCodeAt(ci);
            var cx = bnd.xMin + ((seed * 37) % (bnd.xMax - bnd.xMin));
            var cz = bnd.zMin + ((seed * 53) % (bnd.zMax - bnd.zMin));
            var ico = L.divIcon({
                html: '<div class="boss-label">' + bi.boss.name + ' ' + pct + '%</div>',
                className: '', iconAnchor: [0, 0]
            });
            L.marker(w2ll(cx, cz), { icon: ico })
             .bindTooltip(bi.boss.name + ' - spawn chance: ' + pct + '%', { direction: 'top' })
             .addTo(lg.bosses);
        });
    }

    // Player spawns
    if (layerState.spawns && info.spawns) {
        info.spawns.forEach(function (sp) {
            if (!sp.position) return;
            var sides = (sp.sides || []).join('/');
            var color = (sides.indexOf('Pmc') >= 0) ? '#4a9eff'
                      : (sides.indexOf('Scav') >= 0) ? '#5ecf5e'
                      : '#444';
            L.circleMarker(w2ll(sp.position.x, sp.position.z), {
                radius: 3, color: color, fillColor: color, fillOpacity: 0.5, weight: 1
            }).bindTooltip(sides || 'spawn', { direction: 'top' })
              .addTo(lg.spawns);
        });
    }
}

// ---------------------------------------------------------------------------
// Layer visibility toggles
// ---------------------------------------------------------------------------
function applyLayers() {
    if (layerState.extracts) { if (!map.hasLayer(lg.extracts)) map.addLayer(lg.extracts); }
    else map.removeLayer(lg.extracts);
    if (layerState.bosses)   { if (!map.hasLayer(lg.bosses))   map.addLayer(lg.bosses);   }
    else map.removeLayer(lg.bosses);
    if (layerState.spawns)   { if (!map.hasLayer(lg.spawns))   map.addLayer(lg.spawns);   }
    else map.removeLayer(lg.spawns);
    if (layerState.quests)   { if (!map.hasLayer(lg.quests))   map.addLayer(lg.quests);   }
    else map.removeLayer(lg.quests);
}

['extracts', 'bosses', 'spawns', 'quests'].forEach(function (layer) {
    var cb = document.getElementById('layer-' + layer);
    if (!cb) return;
    cb.checked = layerState[layer];
    cb.addEventListener('change', function () {
        layerState[layer] = cb.checked;
        saveLayerPrefs();
        applyLayers();
        if (currentMap && mapData) {
            lg.extracts.clearLayers();
            lg.bosses.clearLayers();
            lg.spawns.clearLayers();
            loadOverlays(currentMap);
        }
    });
});

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------
function updateStatusBar(eftRunning, inRaid, sessionCount) {
    var eftEl = document.getElementById('sb-eft');
    if (eftRunning === undefined) return;
    if (eftRunning) {
        eftEl.textContent = 'EFT: ' + (inRaid ? 'In Raid' : 'In Menu');
        eftEl.className = 'ok';
    } else {
        eftEl.textContent = 'EFT: Not Running';
        eftEl.className = 'error';
    }
    if (sessionCount !== undefined) {
        document.getElementById('sb-shots').textContent = 'Shots: ' + sessionCount;
    }
}

// ---------------------------------------------------------------------------
// SSE message handler
// ---------------------------------------------------------------------------
function handleMsg(msg) {
    if (!msg || !msg.type) return;

    switch (msg.type) {
        case 'connected':
            break;

        case 'status':
            if (!myPlayerName && msg.playerName) {
                myPlayerName = msg.playerName;
                // Update tooltip on existing marker
                if (myMarker) myMarker.setTooltipContent(myPlayerName);
            }
            updateStatusBar(msg.eftRunning, msg.inRaid, msg.sessionCount);
            if (msg.map && msg.map !== 'unknown' && msg.map !== currentMap) {
                switchMap(msg.map);
            }
            break;

        case 'position':
            var isMe = !msg.player || msg.player === myPlayerName || myPlayerName === '';
            if (isMe) {
                if (msg.map && msg.map !== 'unknown') {
                    if (msg.map !== currentMap) switchMap(msg.map);
                    updateMyMarker(msg);
                }
                updateStatusBar(true, true);
            } else {
                if (msg.map && msg.map !== 'unknown' && msg.map !== currentMap) {
                    switchMap(msg.map);
                }
                updateSquadMarker(msg.player, msg);
            }
            break;
    }
}

// ---------------------------------------------------------------------------
// SSE connection with exponential backoff
// ---------------------------------------------------------------------------
var sseSource    = null;
var sseDelay     = 1000;
var sseMaxDelay  = 30000;

function connectSSE() {
    var el = document.getElementById('sb-sse');
    el.textContent = 'SSE: Connecting';
    el.className = '';

    if (sseSource) { sseSource.close(); sseSource = null; }

    sseSource = new EventSource('/events');

    sseSource.onopen = function () {
        el.textContent = 'SSE: Live';
        el.className = 'ok';
        sseDelay = 1000;
    };

    sseSource.onmessage = function (e) {
        try { handleMsg(JSON.parse(e.data)); } catch (err) {}
    };

    sseSource.onerror = function () {
        el.textContent = 'SSE: Reconnecting...';
        el.className = 'error';
        sseSource.close();
        sseSource = null;
        setTimeout(connectSSE, sseDelay);
        sseDelay = Math.min(sseDelay * 2, sseMaxDelay);
    };
}

// ---------------------------------------------------------------------------
// Fetch map data from backend cache
// ---------------------------------------------------------------------------
function fetchMapData() {
    fetch('/api/mapdata')
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(function (d) {
            if (!d || d.error) return;
            mapData = d;
            if (currentMap) {
                lg.extracts.clearLayers();
                lg.bosses.clearLayers();
                lg.spawns.clearLayers();
                loadOverlays(currentMap);
            }
        })
        .catch(function () {});
}

// ---------------------------------------------------------------------------
// Startup: fetch player name first, then connect SSE
// ---------------------------------------------------------------------------
fetch('/api/status')
    .then(function (r) { return r.json(); })
    .then(function (d) {
        if (d && d.playerName) myPlayerName = d.playerName;
        updateStatusBar(d.eftRunning, d.inRaid, d.sessionCount);
        if (d.version) document.getElementById('sb-version').textContent = 'TarkovMetora v' + d.version;
    })
    .catch(function () {})
    .then(function () { connectSSE(); });

fetchMapData();
setInterval(fetchMapData, 6 * 3600 * 1000);

})();
