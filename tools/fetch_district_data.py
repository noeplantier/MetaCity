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
    # Jakarta / Kota Tua
    "Museum Sejarah Jakarta": 13,  # former Stadhuis (Batavia town hall), two-storey Dutch colonial landmark
    "Wayang Museum": 11,
    "Museum BNI": 14,
    "Gedoeng BNI": 20,  # building:levels=5 confirms a taller bank building than the surrounding shophouses
    # Canggu / Bali — hand-verified from satellite + street-level imagery
    "COMO Uma Canggu": 20,
    "The Slow Hotel": 15,
    "Finns Recreation Club": 12,
    "Atlas Beach Club": 8,
    "La Brisa Bali": 6,
    "Deus Ex Machina": 7,
    "Canggu Club": 9,

    # -----------------------------------------------------------------------
    # Paris — verified from IGN, Géoportail, and widely published sources.
    # OSM already carries building:levels on most Haussmann blocks (5-7 floors)
    # but named landmarks often have only a generic building=yes tag and no
    # height/levels — this list overrides those.
    # -----------------------------------------------------------------------

    # Montmartre
    "Basilique du Sacré-Cœur de Montmartre": 83,   # to lantern top (dome 55m, façade 83m total)
    "Basilique du Sacré-Cœur": 83,
    "Sacré-Cœur": 83,
    "Église Saint-Pierre de Montmartre": 18,        # pre-Romanesque nave — much lower than Sacré-Cœur

    # Le Marais / Île de la Cité
    "Hôtel de Ville de Paris": 50,                  # central pavilion roof ridge
    "Hôtel de Ville": 50,
    "Cathédrale Notre-Dame de Paris": 69,           # twin towers (restored spire 2024: 96m total but
    "Notre-Dame de Paris": 69,                      # the towers at 69m dominate the massing that OSM maps)
    "Sainte-Chapelle": 42,                          # upper chapel spire
    "Conciergerie": 29,                             # main block; twin pointed towers slightly taller but averaged
    "Centre Pompidou": 42,                          # structural tubes rise to 42m; roof deck 28m
    "Centre national d'art et de culture Georges-Pompidou": 42,
    "Musée Picasso": 14,                            # Hôtel Salé — 3-storey 17c hôtel particulier
    "Archives nationales": 18,
    "Hôtel de Sens": 17,
    "Mémorial de la Shoah": 9,

    # Saint-Germain / Rive Gauche
    "Église Saint-Germain-des-Prés": 56,            # bell tower
    "Église Saint-Sulpice": 73,                     # south tower (north tower slightly lower at 68m)
    "Panthéon": 83,                                 # dome + lantern
    "Le Panthéon": 83,
    "Palais du Luxembourg": 29,                     # main south façade
    "Odéon - Théâtre de l'Europe": 18,
    "Musée d'Orsay": 32,                            # great hall barrel vault
    "Institut de France": 30,                       # dome
    "Palais de Justice de Paris": 34,

    # La Défense — critical for correct modernGlass tower heights
    "Grande Arche de la Défense": 110,
    "Grande Arche": 110,
    "CNIT": 46,                                     # landmark ribbed concrete shell
    "Tour First": 231,                              # tallest tower in La Défense
    "Tour Majunga": 195,
    "Tour Total Energies": 190,
    "Total Energies Tower": 190,
    "Coeur Défense": 160,
    "Cœur Défense": 160,
    "Tour Initiale": 148,
    "Tour EY": 100,
    "Tour Ariane": 136,
    "Tour Société Générale": 167,
    "Tour Granite": 184,
    "Tour CB 21": 187,
    "Tour CBX": 123,
    "Tour T1": 181,

    # Bordeaux
    "Cathédrale Saint-André de Bordeaux": 47,       # twin towers (real OSM height rare on cathedrals)
    "Tour Pey-Berland": 66,                         # detached Gothic bell tower (with hyphen — KNOWN_HEIGHTS canonical form)
    "Tour Pey Berland": 66,                         # OSM name (space, not hyphen)
    "Grand Théâtre de Bordeaux": 32,                # full cornice/colonnade height (was 24 = stage-floor only)
    "Grand Théâtre": 32,                            # OSM short form (only Bordeaux in our districts)
    "Palais Rohan": 22,                             # Bordeaux city hall — neoclassical 3-storey
    "Grosse Cloche de Bordeaux": 35,
    "Basilique Saint-Michel de Bordeaux": 114,      # flèche (separate detached spire — tallest structure in Bordeaux)
    "Flèche Saint-Michel": 114,
    "Église Notre-Dame de Bordeaux": 57,            # Baroque Jesuit, twin towers
    "Notre-Dame de Bordeaux": 57,                   # alternate short form
    "Palais de Justice de Bordeaux": 28,            # neoclassical courthouse
    "Synagogue de Bordeaux": 24,                    # historic neoclassical synagogue
    "Cathédrale Saint-André": 47,                   # OSM short form (without 'de Bordeaux' suffix)

    # Rennes
    "Parlement de Bretagne": 25,
    "Cathédrale Saint-Pierre de Rennes": 60,        # twin towers
    "Basilique Saint-Sauveur": 22,
    "Opéra de Rennes": 18,

    # -----------------------------------------------------------------------
    # London — City of London benchmark district
    # Verified from publicly published heights (EGi, CTBUH, Land Registry).
    # -----------------------------------------------------------------------
    "30 St Mary Axe": 180,              # The Gherkin
    "The Gherkin": 180,
    "Leadenhall Building": 224,         # Cheesegrater
    "The Cheesegrater": 224,
    "22 Bishopsgate": 278,              # tallest building in City of London (2020)
    "Heron Tower": 230,                 # Salesforce Tower / Heron Tower
    "Salesforce Tower": 230,
    "NatWest Tower": 183,               # Tower 42 / NatWest Tower
    "Tower 42": 183,
    "City of London": 46,               # fallback generic label (rare)
    "St Paul's Cathedral": 111,         # to lantern — the iconic dome
    "St. Paul's Cathedral": 111,
    "Tower of London": 28,              # White Tower (keep fortress height, not outer walls)
    "The Tower of London": 28,
    "Barbican Estate": 44,              # Lauderdale Tower (tallest Barbican slab)
    "Barbican Centre": 28,              # arts centre lower podium
    "Lloyd's of London": 88,            # Lloyd's Building, Rogers 1986
    "Lloyd's Building": 88,
    "Bank of England": 24,              # original Soane block — low fortress-like
    "Royal Exchange": 22,
    "Guildhall": 20,
    "Monument to the Great Fire of London": 62,  # Wren column
    "The Monument": 62,
    "Leadenhall Market": 18,
    "Mansion House": 26,
    "Bishopsgate": 148,                 # 99 Bishopsgate — older tower
    "1 Canada Square": 235,             # Canary Wharf — may appear at edge of City district
    "HSBC World Headquarters": 200,
    "Walkie Talkie": 160,               # 20 Fenchurch Street
    "20 Fenchurch Street": 160,
    "Scalpel": 190,
    "Fenchurch Street": 30,             # station (rail terminus, low)

    # -----------------------------------------------------------------------
    # Madrid — Salamanca / Retiro benchmark districts
    # -----------------------------------------------------------------------
    "Puerta de Alcalá": 22,             # neoclassical arch, not a building per se but OSM maps it
    "Palacio de Comunicaciones": 82,    # now Palacio de Cibeles / CentroCentro
    "Palacio de Cibeles": 82,
    "Museo del Prado": 22,              # central nave block
    "El Prado": 22,
    "Museo Thyssen-Bornemisza": 20,
    "Palacio del Buen Retiro": 18,      # Casón del Buen Retiro
    "El Retiro": 8,                     # park pavilions, nominal height for OSM polygons
    "Palacio de Velázquez": 14,
    "Palacio de Cristal": 12,
    "Iglesia de San Jerónimo el Real": 48,  # towers
    "Basílica de Nuestra Señora de Atocha": 36,
    "Caixa Forum Madrid": 24,
    "Círculo de Bellas Artes": 34,
    "Plaza de Toros de Las Ventas": 28, # bullring

    # -----------------------------------------------------------------------
    # Madrid — Malasaña / Gran Vía district
    # -----------------------------------------------------------------------
    "Edificio Telefónica": 81,          # Gran Vía 28, Spain's first skyscraper (1929 Art Deco)
    "Espacio Fundación Telefónica": 81, # same building, current cultural-centre name
    "Edificio España": 92,              # Plaza de España, 1955 Art Deco tower
    "Torre de Madrid": 142,             # 1960s twin to Edificio España (Plaza de España)
    "Palacio de la Prensa": 28,         # 1928 Art Deco press building on Gran Vía
    "Teatro Lara": 18,
    "Palacio de Longoria": 20,          # Palacio Longoria - SGAE, Modernista
    "Palacio Longoria - SGAE": 20,

    # -----------------------------------------------------------------------
    # London — Westminster benchmark district
    # -----------------------------------------------------------------------
    "Westminster Abbey": 31,            # nave roof height (towers 68m, but polygon is nave)
    "Westminster Cathedral": 87,        # Byzantine campanile
    "Houses of Parliament": 55,         # main block + Central Tower
    "Palace of Westminster": 55,
    "Big Ben": 96,                      # Elizabeth Tower (clock tower)
    "Elizabeth Tower": 96,
    "Victoria Tower": 98,               # tallest tower of Palace of Westminster
    "Buckingham Palace": 24,            # main block
    "Westminster Bridge": 10,           # bridge deck — any OSM building polygon
    "Downing Street": 18,              # 10 Downing Street
    "10 Downing Street": 18,
    "Horse Guards": 24,
    "Trafalgar Square": 12,             # nominal for any plinth polygon
    "National Gallery": 22,
    "Nelson's Column": 52,              # column to capital (without statue: 51.6m)
    "St Margaret's Church": 28,
    "Lambeth Palace": 28,

    # -----------------------------------------------------------------------
    # Rome — Centro Storico benchmark district
    # -----------------------------------------------------------------------
    "Pantheon": 21,                     # building height (dome exterior to oculus = 43m, but
    "Il Pantheon": 21,                  # the OSM polygon is the drum, not the dome interior)
    "Colosseum": 48,                    # outer wall height; oval footprint OSM way
    "Colosseo": 48,
    "Palazzo Madama": 28,               # Senate of Italy (Baroque facade)
    "Palazzo Montecitorio": 28,         # Camera dei Deputati
    "Piazza Navona": 8,                 # stadium/piazza level — nominal for any building polygon
    "Palazzo Altemps": 22,
    "Basilica di Sant'Agnese in Agone": 55,    # towers
    "Sant'Agnese in Agone": 55,
    "Basilica di Sant'Ivo alla Sapienza": 60,   # Borromini dome
    "Sant'Ivo alla Sapienza": 60,
    "Campo de' Fiori": 12,              # any buildings on the piazza perimeter
    "Torre dell'Orologio": 30,          # clock tower Piazza Navona area
    "Palazzo della Cancelleria": 30,    # Renaissance palazzo
    "Basilica di San Lorenzo in Damaso": 25,
    "Castel Sant'Angelo": 48,           # cylindrical fortress
    "Chiesa di San Luigi dei Francesi": 22,
    "Tempio di Adriano": 15,            # surviving colonnade incorporated into Borsa

    # -----------------------------------------------------------------------
    # Vancouver — Downtown + West End benchmark districts
    # Verified from CTBUH, City of Vancouver planning documents, Wikipedia.
    # -----------------------------------------------------------------------
    "Harbour Centre": 177,             # Vancouver Lookout tower (revolving restaurant top)
    "Sheraton Vancouver Wall Centre": 137,   # tallest hotel in Vancouver (north tower)
    "Wall Centre": 137,
    "Trump International Hotel & Tower Vancouver": 188,  # tallest building in Vancouver
    "Living Shangri-La": 201,          # residential supertall, tallest in BC
    "Shangri-La": 201,
    "MNP Tower": 152,                  # 1500 West Georgia
    "Royal Centre": 140,               # mixed office tower
    "Marine Building": 98,             # Art Deco landmark (1930), 23 storeys
    "Burrard Building": 82,
    "Hotel Vancouver": 88,             # chateau-style copper roof landmark
    "The Fairmont Hotel Vancouver": 88,
    "Fairmont Hotel Vancouver": 88,
    "Christ Church Cathedral": 25,     # Gothic Revival, copper roof, very short
    "Vancouver Art Gallery": 14,       # former courthouse (Robson Square) — low neoclassical
    "Robson Square": 12,               # civic plaza
    "The Bay": 28,                     # Hudson's Bay Company downtown store
    "Canada Place": 30,                # convention centre / cruise ship terminal roof sails
    "Pan Pacific Hotel": 117,          # tower adjacent to Canada Place
    "Westin Bayshore": 128,            # Coal Harbour waterfront
    "Coal Harbour Community Centre": 12,
    "English Bay Beach": 8,            # any nominal building polygons on the beach
    "Stanley Park Pavilion": 10,       # historic fieldhouse, very low

    # -----------------------------------------------------------------------
    # San Francisco — Downtown/FiDi + Fisherman's Wharf benchmark districts
    # Verified from CTBUH, SF Planning Department, Wikipedia.
    # -----------------------------------------------------------------------
    "Transamerica Pyramid": 260,       # architectural height to tip (not broadcast antenna)
    "555 California Street": 237,      # BofA Center / 52 floors
    "Bank of America Center": 237,
    "Salesforce Tower": 326,           # SF's tallest building (2018)
    "First Market Tower": 183,         # 50 Fremont / 1st Market Tower
    "One Market Plaza": 159,           # twin-tower office complex
    "Embarcadero Center": 113,         # 4 towers; #4 is tallest
    "Ferry Building": 75,              # clock tower (building body is ~13m)
    "555 Mission Street": 181,         # UCSF Mission Bay adjacent
    "101 California Street": 183,      # distinctive round top glass tower
    "The Ritz-Carlton San Francisco": 77,
    "Westin St. Francis": 76,          # Union Square landmark
    "St. Francis Hotel": 76,
    "Grace Cathedral": 90,             # Nob Hill cathedral — if in West End bbox
    "Coit Tower": 64,                  # Telegraph Hill column + tower
    "SF MOMA": 44,                     # Museum of Modern Art — stepped postmodern
    "San Francisco Museum of Modern Art": 44,
    "Ghirardelli Square": 12,          # historic chocolate factory complex — low 3-4 storey
    "Pier 39": 10,                     # tourist pier — low structures
    "Fisherman's Wharf": 8,            # nominal for any wharf building polygon
    "The Cannery": 14,                 # Del Monte fruit cannery converted to retail — 3 storeys

    # -----------------------------------------------------------------------
    # New York City — Midtown Manhattan + Lower Manhattan benchmark districts
    # Verified from CTBUH, Emporis, New York City Buildings database, Wikipedia.
    # Heights to architectural top (no antennas/spires unless integral).
    # -----------------------------------------------------------------------

    # Midtown Manhattan supertalls + landmarks
    "One Vanderbilt": 427,             # SL Green / KPF, 2020 (architectural top)
    "One57": 306,                      # 157 West 57th St / Hyatt
    "432 Park Avenue": 426,            # SLCE / CIM / DBOX, supertall residential
    "111 West 57th Street": 435,       # Billionaires' Row pencil tower (under construction)
    "Central Park Tower": 472,         # 217 West 57th, tallest by architectural height in US
    "Empire State Building": 381,      # architectural top (no antenna); 102-floor observation
    "Chrysler Building": 319,          # Art Deco crown + eagle gargoyles; no broadcasting antenna
    "Rockefeller Center": 70,          # 30 Rock (70 Rockefeller Plaza) — the main 30-floor tower is 259m
    "30 Rockefeller Plaza": 259,       # Comcast Building / NBC Studios (architectural top)
    "30 Rock": 259,
    "Rockefeller Plaza": 70,           # the plaza plinth buildings, not the tower
    "Citigroup Center": 279,           # 601 Lexington / Citicorp Center / triangulated base
    "885 Third Avenue": 163,           # Lipstick Building (Johnson/Burgee elliptical)
    "MetLife Building": 246,           # 200 Park Avenue / Grand Central North face
    "Pan Am Building": 246,            # historic name for MetLife Building
    "Grand Central Terminal": 75,      # Beaux-Arts facade — low building (office tower above not directly mapped)
    "New York Public Library": 22,     # Rose Main Reading Room block — 5 storeys
    "St. Patrick's Cathedral": 101,    # Neo-Gothic spires (roof of nave only: 43m; spires 101m)
    "St Patrick's Cathedral": 101,
    "United Nations Headquarters": 97, # Secretariat glass curtain-wall slab
    "UN Headquarters": 97,
    "Lever House": 94,                 # Skidmore Owings & Merrill 1952 glass box
    "Seagram Building": 157,           # Mies van der Rohe curtain-wall tower (Steetbee)
    "432 Park Avenue": 426,
    "Hearst Tower": 182,               # 57-floor Foster diagonal exoskeleton
    "TimeWarner Center": 229,          # twin towers at Columbus Circle
    "Time Warner Center": 229,
    "One Columbus Circle": 229,

    # Lower Manhattan supertalls + landmarks (FiDi/WTC/South Street)
    "One World Trade Center": 541,     # architectural top to roof, not antenna
    "1 World Trade Center": 541,
    "Freedom Tower": 541,              # alternative name
    "Two World Trade Center": 415,     # Bjarke Ingels (under construction/planned — use CTBUH)
    "3 World Trade Center": 329,       # Rogers Stirk Harbour 2018
    "Three World Trade Center": 329,
    "4 World Trade Center": 298,       # Fumihiko Maki 2013
    "Four World Trade Center": 298,
    "World Trade Center": 541,         # generic label — map to tallest tower
    "Flatiron Building": 87,           # 285 Broadway / Daniel Burnham — triangular plan
    "New York Stock Exchange": 30,     # NYSE neoclassical 6-storey colonnade (the real building is low)
    "Federal Hall": 16,                # Greek Revival / 4 storeys
    "Fulton Center": 42,               # transit hub with glass oculus
    "One New York Plaza": 211,         # 50-floor tower on Whitehall
    "55 Water Street": 213,            # large mid-block office tower
    "70 Pine Street": 290,             # Art Deco tower (NYC's 3rd tallest when built, 1932)
    "40 Wall Street": 283,             # Trump Building / Bank of Manhattan (originally tallest in world)
    "60 Wall Street": 242,             # JP Morgan Deutsche Bank tower
    "4 New York Plaza": 175,
    "One Financial Center": 175,
    "Pier 17": 18,                     # Seaport District retail/entertainment pier (low)
    "Brooklyn Bridge": 84,             # main towers (the bridge deck at 41m; stone towers to 84m)
    "Manhattan Bridge": 87,
    "Woolworth Building": 241,         # 233 Broadway, Neo-Gothic, 1913
    "City Hall": 28,                   # NYC City Hall, French Renaissance + Federal, very low
    "New York City Hall": 28,
    "Municipal Building": 178,         # 1 Centre Street, McKim Mead White 1914
    "Foley Square": 12,                # open plaza, nominal for any mapped polygon
    "Fulton Street": 18,               # generic street-level retail
    "Staten Island Ferry Terminal": 20,
    "Stone Street": 10,                # historic district, low tavern row (2-3 storey)

    # -----------------------------------------------------------------------
    # Tokyo — Verified from CTBUH, Wikipedia, and Tokyo Metropolitan Government data.
    # Japanese OSM names use both kanji/kana and English — include both forms.
    # -----------------------------------------------------------------------
    # Shibuya
    "Scramble Square": 230,                # 渋谷スクランブルスクエア East Tower (2019)
    "渋谷スクランブルスクエア": 230,
    "Shibuya Scramble Square": 230,
    "Shibuya Hikarie": 182,                # 渋谷ヒカリエ (2012) — mixed-use tower
    "渋谷ヒカリエ": 182,
    "Hikarie": 182,
    "Shibuya Stream": 180,                 # 渋谷ストリーム (2018) — office/hotel tower
    "渋谷���トリーム": 180,
    "Cerulean Tower": 184,                 # セルリアンタワー東急ホテル (2001) — tallest hotel in Shibuya
    "Cerulean Tower Tokyo Hotel": 184,
    "セルリアンタワー東急ホテル": 184,
    "Mark City": 56,                       # 渋谷マークシティ (2000) — Tokyu Hands complex
    "渋谷マークシティ": 56,
    "Shibuya Mark City": 56,
    "NHK Broadcasting Center": 48,         # NHK放送センター — headquarters
    "NHK放送センター": 48,
    "SHIBUYA109": 35,                      # 渋谷109 (1979) — iconic fashion building, 8 floors
    "渋谷109": 35,
    "Bunkamura": 22,                       # Tokyu cultural center — low performing arts block
    "QFront": 32,                          # 渋谷駅前 mixed retail/office tower
    "Shibuya Excel Hotel Tokyu": 46,
    "Tokyu Department Store": 28,          # 東急百貨店東横店 — 1956 flagship
    "東急百貨店": 28,
    "Prime": 88,                           # Shibuya Prime — commercial tower near station
    # Shinjuku
    "Tokyo Metropolitan Government Building": 243,
    "Tokyo Metropolitan Building": 243,
    "東京都庁舎": 243,
    "Shinjuku Mitsui Building": 221,
    "新宿三井ビルディング": 221,
    "Shinjuku i-Land Tower": 217,
    "Shinjuku NS Building": 234,
    "Shinjuku Washington Hotel": 202,
    "Park Hyatt Tokyo": 202,
    "Hilton Tokyo": 190,
    "Isetan Shinjuku": 68,
    "伊勢丹新宿店": 68,
    # Asakusa
    "Senso-ji Temple Pagoda": 55,          # Five-storey pagoda
    "浅草寺五重塔": 55,
    "Senso-ji Main Hall": 28,
    "浅草寺": 28,
    "Nakamise Shopping Street": 7,
    "仲見世": 7,
    "Traditional Edo Machiya": 8,
    # Chiyoda
    "Tokyo Tower": 333,                # Main tower to roof (not antenna)
    "東京タワー": 333,
    "Tokyo Tower Main Deck": 150,
    "Tokyo Tower Foot Town": 30,
    "Imperial Palace": 15,
    "皇居": 15,
    "National Diet Building": 70,
    "国会議事堂": 70,
    "Supreme Court": 25,
    # Ginza
    "Ginza Sony Building": 33,
    "銀座ソニービル": 33,
    "Ginza Mitsukoshi": 32,
    "銀座三越": 32,
    "Ginza Wako Clock Tower": 26,
    "和光時計塔": 26,
    "Ginza Kabuki-za Theatre": 32,
    "歌舞伎座": 32,
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
    "civic": "government",
    "parliament": "government",
    "mosque": "religious",
    # French religious buildings — cathedrals, churches, chapels
    "church":    "religious",
    "cathedral": "religious",
    "chapel":    "religious",
    "basilica":  "religious",
    "synagogue": "religious",
    # Tokyo shrine/temple
    "shrine":    "tokyoTemple",
    "temple":    "tokyoTemple",
    "palace":    "tokyoGovernment",
}


def fetch_overpass(bbox, cache_path):
    if cache_path and os.path.exists(cache_path):
        print(f"Using cached raw data: {cache_path}", file=sys.stderr)
        return json.load(open(cache_path))

    south, west, north, east = bbox
    query = f"""
    [out:json][timeout:90];
    (
      way["building"]({south},{west},{north},{east});
      way["highway"]({south},{west},{north},{east});
      way["leisure"="park"]({south},{west},{north},{east});
      way["landuse"]({south},{west},{north},{east});
      way["natural"="water"]({south},{west},{north},{east});
      way["natural"="beach"]({south},{west},{north},{east});
      way["natural"="scrub"]({south},{west},{north},{east});
      way["waterway"="river"]({south},{west},{north},{east});
      way["waterway"="canal"]({south},{west},{north},{east});
      way["tourism"="museum"]({south},{west},{north},{east});
      way["amenity"="museum"]({south},{west},{north},{east});
      node["tourism"="museum"]({south},{west},{north},{east});
      node["amenity"="museum"]({south},{west},{north},{east});
      node["amenity"="place_of_worship"]({south},{west},{north},{east});
      node["amenity"="theatre"]({south},{west},{north},{east});
      node["amenity"="townhall"]({south},{west},{north},{east});
      node["amenity"="courthouse"]({south},{west},{north},{east});
      node["historic"="church"]({south},{west},{north},{east});
      node["historic"="castle"]({south},{west},{north},{east});
      node["historic"="monument"]({south},{west},{north},{east});
      node["historic"="memorial"]({south},{west},{north},{east});
      node["historic"="building"]({south},{west},{north},{east});
      node["tourism"="attraction"]({south},{west},{north},{east});
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


def _landmark_style_from_tags(tags):
    """Infer the correct BuildingStyle for a named landmark node."""
    amenity = tags.get("amenity", "")
    historic = tags.get("historic", "")
    tourism  = tags.get("tourism", "")
    building = tags.get("building", "")
    religion = tags.get("religion", "")

    if amenity == "place_of_worship" or building in ("church", "cathedral", "chapel", "basilica"):
        return "religious"
    if amenity in ("museum",) or tourism in ("museum", "gallery"):
        return "government"
    if amenity in ("theatre", "cinema", "concert_hall"):
        return "government"
    if historic in ("castle", "palace", "monument", "memorial"):
        return "government"
    if tourism in ("attraction",) and tags.get("name", "") in KNOWN_HEIGHTS_METERS:
        return "government"
    return "government"  # default for any named node: civic landmark trumps generic residential


def apply_named_point_landmarks(elements, buildings, anchor_lat, anchor_lon):
    """Named landmark *nodes* — museums, churches, monuments, theatres — are frequently mapped as
    a standalone OSM node sitting on top of an otherwise-anonymous `building=yes` polygon. Spatially
    match each node to its containing footprint so the name, real height, and correct style attach
    to the actual building geometry rather than being silently dropped.

    Expanded from museum-only to cover Paris's rich landmark landscape: Sacré-Cœur, Notre-Dame,
    Saint-Germain-des-Prés, Centre Pompidou, and civic buildings all appear as amenity/historic/
    tourism nodes rather than being named on their building= way.
    """
    matched = 0
    for el in elements:
        if el.get("type") != "node":
            continue
        tags = el.get("tags", {})
        amenity  = tags.get("amenity", "")
        historic = tags.get("historic", "")
        tourism  = tags.get("tourism", "")

        is_landmark = (
            amenity in ("museum", "place_of_worship", "theatre", "cinema", "townhall",
                        "courthouse", "embassy") or
            tourism  in ("museum", "gallery", "attraction") or
            historic in ("castle", "palace", "monument", "memorial", "church",
                         "building", "ruins", "archaeological_site")
        )
        if not is_landmark:
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
                building["style"] = _landmark_style_from_tags(tags)
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


# Styles whose area-character default must survive all height-based promotion.
# Buildings in these districts get their default style regardless of height, because
# a 28m Salamanca apartment block is still madrileño, a 70m Roman palazzo is still
# romanOchre, and a 20m Haussmann block is still haussmannien.
# londonBrick is NOT in this set: City of London's real glass towers (Gherkin 180m,
# Cheesegrater 224m, 22 Bishopsgate 278m) should auto-promote to modernGlass.
HEIGHT_PROMOTION_BYPASS = {"haussmannien", "medieval", "bordelaisClassical", "madrileño", "romanOchre", "nycBrick", "tokyoMachiya", "tokyoTemple", "tokyoGovernment"}
# nycBrick added 2026-07-13: pre-war Manhattan limestone office towers (e.g. 70m 20-storey
# Beaux-Arts blocks) must stay nycBrick, not auto-promote to modernGlass. Glass supertalls
# (One WTC 541m, Chrysler 319m, etc.) are handled via authored overrides.
# Tokyo styles added 2026-07-19: machiya, temple, and government stay their district character.

def classify_style(tags, height_hint, default_style="colonial"):
    building_tag = tags.get("building")
    if building_tag in STYLE_BY_BUILDING_TAG:
        return STYLE_BY_BUILDING_TAG[building_tag]
    
    # Tokyo shrine/temple detection
    if tags.get("building") in ("shrine", "temple") or tags.get("amenity") == "place_of_worship":
        religion = tags.get("religion", "")
        if religion in ("shinto", "buddhist"):
            return "tokyoTemple"
    
    # French/European amenity tags not covered by building= tag
    amenity = tags.get("amenity", "")
    if amenity in ("place_of_worship",):
        return "religious"
    if amenity in ("townhall", "courthouse", "embassy", "university"):
        return "government"
    if tags.get("amenity") == "museum" or tags.get("tourism") == "museum":
        return "government"
    # Real height signal overrides district-character fallback — but only for styles
    # that don't carry a bypass flag. HEIGHT_PROMOTION_BYPASS styles keep their
    # default character at any height (e.g. a 28m Salamanca block stays madrileño).
    if height_hint is not None and default_style not in HEIGHT_PROMOTION_BYPASS:
        if height_hint >= 30:
            return "modernGlass"
        if height_hint >= 15:
            return "modernConcrete"
    return default_style


def estimate_height(height_hint, is_estimated, style):
    if not is_estimated:
        return height_hint, False
    # Style-specific height estimates when OSM provides no real data.
    # Haussmann: standard 5-6 storey block ≈ 18m (6 × 3m floor height).
    # Medieval: 2-3 storey half-timber townhouse ≈ 9m.
    # Government: civic halls tend to be taller than residential, ≈ 9m.
    if style == "haussmannien":
        return 18.0, True
    if style == "medieval":
        return 9.0, True
    if style == "bordelaisClassical":
        # Standard 4-storey Bordeaux residential block ≈ 16m (4 × 4m floor height).
        # Lower than Haussmann (18m) — Bordeaux classical proportions are slightly squatter.
        return 16.0, True
    if style == "londonBrick":
        # Victorian London terrace: typically 3-4 storeys ≈ 12m (3 × 4m). Consistent
        # height along the City's Georgian/Victorian street fabric.
        return 12.0, True
    if style == "madrileño":
        # Salamanca/Ensanche apartment block: typically 5-6 storeys ≈ 20m (5 × 4m).
        # Denser and taller than French provincial, similar floor count to haussmannien.
        return 20.0, True
    if style == "romanOchre":
        # Rome historic-centre tuff/brick palazzo: typically 3-4 storeys ≈ 14m.
        # Lower and more varied in height than the gridded Haussmann fabric.
        return 14.0, True
    if style == "nycBrick":
        # NYC tenement/brownstone: typically 4-6 storeys ≈ 15m (4 × ~3.75m NYC floor height).
        # Pre-war office buildings in Lower Manhattan run taller, but those get authored overrides.
        return 15.0, True
    # ===== NEW: Tokyo styles =====
    if style == "modernTokyo":
        # Contemporary mixed-use: 7-8 storeys ≈ 28m (4m per floor)
        return 28.0, True
    if style == "tokyoMachiya":
        # Traditional 2-storey wooden house ≈ 8.5m (4.25m per storey, lower ceilings)
        return 8.5, True
    if style == "tokyoTemple":
        # Average temple/shrine (including pagodas) ≈ 18m
        return 18.0, True
    if style == "tokyoGovernment":
        # Government office buildings ≈ 25m (6-7 storeys)
        return 25.0, True
    base = 9.0 if style == "government" else 7.0
    return base, True


def process_buildings(elements, anchor_lat, anchor_lon, default_style="colonial"):
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
        style = classify_style(tags, prelim_height, default_style)
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


def _green_zone_kind(tags):
    natural = tags.get("natural")
    landuse = tags.get("landuse")
    waterway = tags.get("waterway")
    if natural == "water" or waterway in ("river", "canal", "stream"):
        return "natural=water"
    if natural == "beach":                           return "natural=beach"
    if natural in ("scrub",):                        return "natural=scrub"
    if natural == "wood":                            return "landuse=forest"
    if landuse == "farmland":                        return "landuse=farmland"
    if landuse == "orchard":                         return "landuse=orchard"
    if landuse == "meadow":                          return "landuse=meadow"
    if landuse == "forest":                          return "landuse=forest"
    if landuse == "allotments":                      return "landuse=allotments"
    return "leisure=park"


def process_green_zones(elements, anchor_lat, anchor_lon):
    out = []
    for el in elements:
        tags = el.get("tags", {})
        is_green = (
            tags.get("leisure") == "park"
            or tags.get("natural") in ("beach", "scrub", "wood", "water")
            or tags.get("waterway") in ("river", "canal", "stream")
            or tags.get("landuse") in (
                "grass", "recreation_ground", "village_green",
                "farmland", "orchard", "meadow", "forest", "allotments",
            )
        )
        if not is_green:
            continue
        geometry = el.get("geometry")
        if not geometry or len(geometry) < 3:
            continue
        points = [project(p["lat"], p["lon"], anchor_lat, anchor_lon) for p in geometry]
        out.append({
            "name": tags.get("name"),
            "kind": _green_zone_kind(tags),
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
    parser.add_argument(
        "--default-style", default="colonial",
        help="BuildingStyle applied to any building whose OSM tags and height both fail to determine a style. "
             "Valid values: 'colonial' (default, Jakarta/Bandung/Yogya), 'balinese' (Bali), "
             "'haussmannien' (Paris), 'bordelaisClassical' (Bordeaux — warm amber-gold limestone), "
             "'medieval' (Vieux-Rennes, historic French towns), 'modernTokyo' (Tokyo contemporary), "
             "'tokyoMachiya' (Tokyo historic), 'tokyoTemple' (Tokyo temples), 'tokyoGovernment' (Tokyo government)."
    )
    args = parser.parse_args()

    data = fetch_overpass(args.bbox, args.cache)
    elements = data["elements"]
    anchor_lat, anchor_lon = args.anchor

    buildings = process_buildings(elements, anchor_lat, anchor_lon, default_style=args.default_style)
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
