#!/usr/bin/env python3
"""
Fetches real OpenStreetMap data (Overpass API) for a MetaCity district and curates it into the
compact JSON format consumed by DistrictFootprint.swift at runtime — building footprints, roads,
and green zones, projected to local meters from a district anchor point.

This is a one-shot tooling script, not part of the iOS app target. Re-run it whenever a district's
bundled JSON needs refreshing (OSM data changes) or a new district is added.

Usage:
    python3 fetch_district_data.py \
        --name KotaTua \
        --bbox -6.1375 106.8125 -6.1320 106.8170 \
        --anchor -6.1352 106.8133 \
        --out ../MetaCity/Resources/Districts/KotaTua.json \
        --cache /tmp/kotatua_raw.json

--bbox is SOUTH WEST NORTH EAST (lat/lon). --anchor is the local-origin point (typically the
district's main square/landmark) that all building/road coordinates are projected relative to,
in meters, via a flat equirectangular approximation (fine at this scale, a few hundred meters).
"""
import argparse
import json
import math
import os
import sys
import urllib.parse
import urllib.request

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
USER_AGENT = "MetaCityResearch/1.0 (educational iOS app prototype)"

# Hand-verified real heights for named landmarks the generic OSM tags don't capture (no `height`
# tag exists anywhere in this dataset — see the audit). Keep this list small and sourced; anything
# not in it falls back to the building:levels-based or style-based estimate below, both flagged
# isHeightEstimated=true so the app never claims false precision.
KNOWN_HEIGHTS_METERS = {
    "Museum Sejarah Jakarta": 13,  # former Stadhuis (Batavia town hall), two-storey Dutch colonial landmark
    "Wayang Museum": 11,
    "Museum BNI": 14,
    "Gedoeng BNI": 20,  # building:levels=5 confirms a taller bank building than the surrounding shophouses
}

STYLE_BY_BUILDING_TAG = {
    "government_office": "government",
    "subdistrict_office": "government",
    "police": "government",
    "fire_station": "government",
    "post_office": "government",
    "bank": "government",
    "school": "government",
    "kindergarten": "government",
    "train_station": "government",
    "public": "government",
    "mosque": "religious",
}


def fetch_overpass(bbox, cache_path):
    if cache_path and os.path.exists(cache_path):
        print(f"Using cached raw data: {cache_path}", file=sys.stderr)
        return json.load(open(cache_path))

    south, west, north, east = bbox
    query = f"""
    [out:json][timeout:60];
    (
      way["building"]({south},{west},{north},{east});
      way["highway"]({south},{west},{north},{east});
      way["leisure"="park"]({south},{west},{north},{east});
      way["landuse"]({south},{west},{north},{east});
      way["natural"="water"]({south},{west},{north},{east});
      way["tourism"="museum"]({south},{west},{north},{east});
      way["amenity"="museum"]({south},{west},{north},{east});
      node["tourism"="museum"]({south},{west},{north},{east});
      node["amenity"="museum"]({south},{west},{north},{east});
    );
    out geom;
    """
    body = urllib.parse.urlencode({"data": query}).encode()
    req = urllib.request.Request(OVERPASS_URL, data=body, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=90) as resp:
        data = json.load(resp)
    if cache_path:
        json.dump(data, open(cache_path, "w"))
    return data


def project(lat, lon, anchor_lat, anchor_lon):
    """Flat equirectangular approximation — accurate to well under a meter at district scale."""
    meters_per_deg_lat = 111_320.0
    meters_per_deg_lon = 111_320.0 * math.cos(math.radians(anchor_lat))
    x = (lon - anchor_lon) * meters_per_deg_lon
    z = -(lat - anchor_lat) * meters_per_deg_lat  # north = -z
    return x, z


def perpendicular_distance(pt, start, end):
    if start == end:
        return math.hypot(pt[0] - start[0], pt[1] - start[1])
    x1, y1 = start
    x2, y2 = end
    x0, y0 = pt
    num = abs((x2 - x1) * (y0 - y1) - (x0 - x1) * (y2 - y1))
    den = math.hypot(x2 - x1, y2 - y1)
    return num / den if den else 0.0


def rdp(points, epsilon):
    if len(points) < 3:
        return points
    start, end = points[0], points[-1]
    max_dist, index = 0.0, 0
    for i in range(1, len(points) - 1):
        d = perpendicular_distance(points[i], start, end)
        if d > max_dist:
            max_dist, index = d, i
    if max_dist > epsilon:
        left = rdp(points[: index + 1], epsilon)
        right = rdp(points[index:], epsilon)
        return left[:-1] + right
    return [start, end]


def simplify(points, epsilon_meters=0.6, max_vertices=14):
    """Douglas-Peucker on a closed footprint polygon, capped for mobile-friendly vertex counts."""
    if len(points) <= 4:
        return points
    closed = points[0] == points[-1]
    body = points[:-1] if closed else points
    epsilon = epsilon_meters
    simplified = rdp(body, epsilon)
    # If still too detailed (a few very large/complex footprints), simplify more aggressively
    # rather than hand-tune epsilon per building.
    while len(simplified) > max_vertices and epsilon < 5.0:
        epsilon *= 1.6
        simplified = rdp(body, epsilon)
    if closed:
        simplified.append(simplified[0])
    return simplified


def point_in_polygon(point, polygon):
    """Standard ray-casting test. `polygon` is a list of (x, z) tuples, closed or not."""
    x, z = point
    inside = False
    pts = polygon if polygon[0] != polygon[-1] else polygon[:-1]
    n = len(pts)
    j = n - 1
    for i in range(n):
        xi, zi = pts[i]
        xj, zj = pts[j]
        if ((zi > z) != (zj > z)) and (x < (xj - xi) * (z - zi) / (zj - zi) + xi):
            inside = not inside
        j = i
    return inside


def apply_named_point_landmarks(elements, buildings, anchor_lat, anchor_lon):
    """Museums (and similar POIs) are frequently mapped as a standalone OSM *node*, not as part of
    the building *way*'s tags — see the audit: Wayang Museum, Museum Sejarah Jakarta, and Museum
    BNI are all nodes sitting on top of otherwise-anonymous `building=yes` polygons. Spatially
    match each node to its containing footprint so the name (and any known real height) attaches
    to the actual building, instead of being silently dropped.
    """
    matched = 0
    for el in elements:
        if el.get("type") != "node":
            continue
        tags = el.get("tags", {})
        if tags.get("tourism") != "museum" and tags.get("amenity") != "museum":
            continue
        name = tags.get("name")
        if not name:
            continue
        point = project(el["lat"], el["lon"], anchor_lat, anchor_lon)
        for building in buildings:
            poly = [(p["x"], p["z"]) for p in building["polygon"]]
            if point_in_polygon(point, poly):
                building["name"] = name
                if name in KNOWN_HEIGHTS_METERS:
                    building["heightMeters"] = KNOWN_HEIGHTS_METERS[name]
                    building["isHeightEstimated"] = False
                building["style"] = "government"  # civic/cultural landmark, not anonymous colonial infill
                matched += 1
                break
    if matched:
        print(f"Matched {matched} point-mapped landmark(s) to their building footprint", file=sys.stderr)


def preliminary_height(tags, name):
    """Real height signal, if any exists, computed *before* style classification — so a tall
    building with a `building:levels` tag can correct its own style instead of being forced into
    whatever the area's generic low-rise fallback is (see classify_style)."""
    if name in KNOWN_HEIGHTS_METERS:
        return KNOWN_HEIGHTS_METERS[name], False
    levels = tags.get("building:levels")
    if levels:
        try:
            return float(levels) * 4.0, False
        except ValueError:
            pass
    return None, True


def classify_style(tags, height_hint):
    building_tag = tags.get("building")
    if building_tag in STYLE_BY_BUILDING_TAG:
        return STYLE_BY_BUILDING_TAG[building_tag]
    if tags.get("amenity") == "museum" or tags.get("tourism") == "museum":
        return "government"
    # No definitive tag. A real height signal overrides the area's generic low-rise default —
    # colonial-era Jakarta buildings essentially never exceed ~3 storeys, so anything genuinely
    # tall (real `building:levels`, not an estimate) is modern construction regardless of district
    # character. This is what stopped Sudirman-Thamrin's actual towers (Hotel Indonesia Kempinski,
    # Keraton at The Plaza, ...) from being misclassified as colonial stucco.
    if height_hint is not None and height_hint > 20:
        return "modernGlass"
    # Otherwise fall back to the district's predominant unlabeled-building character — colonial
    # for Kota Tua/Menteng's low-rise infill, which is the common case across most named buildings
    # actually checked so far. Districts with a different generic infill character should pass
    # `--default-style` (not yet needed in practice — revisit if a future district's anonymous
    # buildings read wrong).
    return "colonial"


def estimate_height(height_hint, is_estimated, style):
    if not is_estimated:
        return height_hint, False
    base = 9.0 if style == "government" else 7.0
    return base, True


def process_buildings(elements, anchor_lat, anchor_lon):
    out = []
    seen_ids = set()
    for el in elements:
        tags = el.get("tags", {})
        is_building = "building" in tags
        is_museum = tags.get("amenity") == "museum" or tags.get("tourism") == "museum"
        if not (is_building or is_museum):
            continue
        geometry = el.get("geometry")
        if not geometry or len(geometry) < 3:
            continue
        osm_id = str(el["id"])
        if osm_id in seen_ids:
            continue
        seen_ids.add(osm_id)

        points = simplify([project(p["lat"], p["lon"], anchor_lat, anchor_lon) for p in geometry])
        name = tags.get("name")
        prelim_height, is_estimated = preliminary_height(tags, name)
        style = classify_style(tags, prelim_height)
        height, estimated = estimate_height(prelim_height, is_estimated, style)
        out.append({
            "name": name,
            "polygon": [{"x": round(x, 2), "z": round(z, 2)} for x, z in points],
            "heightMeters": round(height, 1),
            "isHeightEstimated": estimated,
            "style": style,
            "osmID": osm_id,
        })
    return out


def process_roads(elements, anchor_lat, anchor_lon):
    out = []
    for el in elements:
        tags = el.get("tags", {})
        if "highway" not in tags:
            continue
        geometry = el.get("geometry")
        if not geometry or len(geometry) < 2:
            continue
        points = [project(p["lat"], p["lon"], anchor_lat, anchor_lon) for p in geometry]
        out.append({
            "name": tags.get("name"),
            "points": [{"x": round(x, 2), "z": round(z, 2)} for x, z in points],
            "kind": tags.get("highway"),
            "osmID": str(el["id"]),
        })
    return out


def process_green_zones(elements, anchor_lat, anchor_lon):
    out = []
    for el in elements:
        tags = el.get("tags", {})
        is_green = tags.get("leisure") == "park" or tags.get("landuse") in ("grass", "recreation_ground", "village_green")
        if not is_green:
            continue
        geometry = el.get("geometry")
        if not geometry or len(geometry) < 3:
            continue
        points = [project(p["lat"], p["lon"], anchor_lat, anchor_lon) for p in geometry]
        out.append({
            "name": tags.get("name"),
            "polygon": [{"x": round(x, 2), "z": round(z, 2)} for x, z in points],
            "osmID": str(el["id"]),
        })
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", required=True)
    parser.add_argument("--bbox", nargs=4, type=float, required=True, metavar=("SOUTH", "WEST", "NORTH", "EAST"))
    parser.add_argument("--anchor", nargs=2, type=float, required=True, metavar=("LAT", "LON"))
    parser.add_argument("--out", required=True)
    parser.add_argument("--cache", default=None, help="Raw Overpass response cache path (skips network if present)")
    args = parser.parse_args()

    data = fetch_overpass(args.bbox, args.cache)
    elements = data["elements"]
    anchor_lat, anchor_lon = args.anchor

    buildings = process_buildings(elements, anchor_lat, anchor_lon)
    apply_named_point_landmarks(elements, buildings, anchor_lat, anchor_lon)
    roads = process_roads(elements, anchor_lat, anchor_lon)
    green_zones = process_green_zones(elements, anchor_lat, anchor_lon)

    estimated_count = sum(1 for b in buildings if b["isHeightEstimated"])
    district = {
        "name": args.name,
        "anchorLatitude": anchor_lat,
        "anchorLongitude": anchor_lon,
        "buildings": buildings,
        "roads": roads,
        "greenZones": green_zones,
        "sourceAttribution": "© OpenStreetMap contributors, ODbL",
    }

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(district, f, indent=1)

    print(
        f"{args.name}: {len(buildings)} buildings ({estimated_count} with estimated height), "
        f"{len(roads)} roads, {len(green_zones)} green zones -> {args.out}"
    )


if __name__ == "__main__":
    main()
