import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
import networkx as nx
import osmnx as ox
from enviroment import SafeGuardEnv

# Inizializzazione dell'ambiente SafeGuard (Firebase e Grafo Stradale)
env = SafeGuardEnv()

# Gestisce la mappa caricandola all'avvio del server
@asynccontextmanager
async def lifespan(_: FastAPI):
    env.load_salerno_map() # Usa la nuova funzione con cache locale
    yield

app = FastAPI(lifespan=lifespan)

# Configurazione CORS: permette all'app Flutter di comunicare con il server
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"]
)

# Coordinate GPS dell'utente
class UserLocation(BaseModel):
    lat: float
    lng: float


# Endpoint principale: riceve la posizione utente, analizza i pericoli tramite IA,
# calcola i percorsi sul grafo stradale e restituisce i punti sicuri ordinati
@app.post("/api/safe-points/sorted")
async def get_sorted_points(req: UserLocation):
    try:
        # Applica i blocchi stradali
        env.apply_disaster_manager()

        # Prende i punti sicuri/ospedali dal database
        punti = env.get_points_from_firestore()

        # Trova il nodo stradale più vicino all'utente
        user_node = ox.nearest_nodes(env.graph, X=req.lng, Y=req.lat)

        # Calcoliamo la distanza matematica "volo d'uccello" per trovare i 3 candidati migliori
        for p in punti:
            p['bird_distance'] = ((p['lat'] - req.lat)**2 + (p['lng'] - req.lng)**2)**0.5

        # Seleziona i 3 punti geograficamente più vicini
        punti_top = sorted(punti, key=lambda x: x['bird_distance'])[:5]

        results = []
        print("\n--- 🔍 DEBUG IA PERCORSI ---")

        for p in punti_top:
            # Trova il nodo stradale del punto di destinazione
            target_node = ox.nearest_nodes(env.graph, X=p['lng'], Y=p['lat'])

            # Valori di default per la gestione errori
            dist_w = 0.0
            #dist_r = 0.0
            #diff = 0.0
            #is_dangerous = False
            is_blocked = False

            try:
                # Distanza Pesata
                dist_w = nx.shortest_path_length(env.graph, user_node, target_node, weight='final_weight')

                # Distanza Reale
                dist_r = nx.shortest_path_length(env.graph, user_node, target_node, weight='length')

                # 3. Calcolo differenza
                diff = dist_w - dist_r

                is_blocked = dist_w > 50000

                # Se la differenza è > 5 metri, il percorso è deviato/ostruito
                is_dangerous = dist_w > (dist_r + 5)

                status_icon = "⚠️" if is_dangerous else "✅"
                print(f"📍 {p['name'][:20]} | Reale: {dist_r:.0f}m | IA: {dist_w:.0f}m | Diff: {diff:.0f}m | {status_icon}")

            except nx.NetworkXNoPath:
                print(f"❌ {p['name'][:20]} | NESSUN PERCORSO (Completamente isolato)")
                dist_r = 999999
                is_dangerous = True
            except Exception as e:
                print(f"❗ Errore su {p['name']}: {e}")
                dist_r = 999999
                is_dangerous = True

            results.append({
                "title": str(p.get('name', 'N/A')),
                "type": str(p.get('type', 'generic')),
                "lat": float(p['lat']),
                "lng": float(p['lng']),
                # Se is_dangerous è True, inviamo la distanza con la deviazione (dist_w)
                "distance": float(dist_w) if is_dangerous else float(dist_r),
                # Inviato per calcolare il "+ ritardo" in Flutter
                "dist_real": float(dist_r),
                "isDangerous": bool(is_dangerous),
                "isBlocked": bool(is_blocked)
            })

        print("--- 🏁 FINE DEBUG ---\n")

        # Ordina: prima i sicuri, poi i pericolosi
        results.sort(key=lambda x: x['distance'])

        return results

    except Exception as e:
        print(f"❌ Errore API: {e}")
        return []

if __name__ == "__main__":
    # Avvio del server
    uvicorn.run(app, host="0.0.0.0", port=8000)