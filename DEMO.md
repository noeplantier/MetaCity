# MetaCity — Script de démo

## Pitch (10 secondes)

Une app iOS de "ville jumelle numérique" : carte 3D, réalité augmentée et appels vidéo — construite
sur de vraies données géographiques de Jakarta (OpenStreetMap), pas des mockups. Authentification
Firebase réelle, pas de placeholder.

## Pourquoi ce projet

Conçu pour démontrer une gamme précise de compétences mobiles : apps robustes avec design 3D,
cartes, cartes 3D, appels audio/vidéo — les points clés d'une offre d'emploi ciblée.

## Parcours de démo (~5 min)

### 1. Auth (30s)
- Inscription email/mot de passe réelle (Firebase Auth) ou Continue with Google.
- Pas de mock : un vrai compte est créé.

### 2. Explore (30s)
- Liste des 5 vrais quartiers de Jakarta : Bundaran HI, Kota Tua, Jalan Kemang Raya, Taman
  Suropati, Taman Impian Jaya Ancol.
- Taper un quartier → aperçu 3D (RealityKit).

### 3. Map (45s)
- Carte 2D/3D réelle (MapKit), bascule 3D animée.
- Taper un pin → recentrage précis + pin mis en valeur + callout "Voir en AR".

### 4. AR — le clou du show (90s)
- 5 quartiers, données réelles OpenStreetMap : vrais polygones de bâtiments, vraies routes, vraies
  zones vertes — pas des boîtes génériques.
- Chaque quartier a un bâtiment réel identifié comme point focal (ex. Menara BCA pour Bundaran HI,
  Museum Sejarah Jakarta pour Kota Tua).
- Sur Simulator : exploration à hauteur de piéton.
- Sur device réel : pose d'une maquette 3D ancrée sur une surface détectée (vraie AR ARKit, avec
  éclairage d'environnement automatique).

### 5. Calls (60s)
- Contact bot de test ("MetaCity Assistant") joignable en audio et vidéo, auto-répond.
- États d'appel complets : sonnerie sortante/entrante, minuteur en direct, mute, haut-parleur,
  caméra, bascule caméra avant/arrière.
- Bouton "Simulate incoming call" pour démontrer la réception d'un appel.

### 6. Profile (30s)
- Verrouillage biométrique réel (Face ID/Touch ID).
- Cartes de stats réelles dérivées du contenu de l'app (quartiers, bâtiments, routes réels) — pas
  de fausses statistiques personnelles.

## Stack en une ligne

SwiftUI + Firebase Auth + MapKit + SceneKit (données) → RealityKit (rendu) + ARKit + pipeline
Python/OpenStreetMap.

## Points forts à marteler

- Aucune donnée fictive : tout vient d'OpenStreetMap via un vrai pipeline de curation.
- Architecture Clean (Repositories/Services/Features) : mock ↔ réel interchangeable sans toucher
  une seule ligne d'UI.
- Authentification réelle, pas une démo factice.

## Si on te pose une question piège

- **"Pourquoi pas tout en RealityKit dès le départ ?"** → La génération procédurale RealityKit
  nécessite iOS 18 ; le pipeline SceneKit (données) → USDZ → RealityKit (rendu) contourne cette
  contrainte tout en restant sur iOS 17.
- **"L'AR marche sur le simulateur ?"** → Oui, en mode dégradé (vue piéton sans tracking réel) ; le
  vrai tracking ARKit + pose d'objet nécessite un device physique.
