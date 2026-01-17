import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
import networkx as nx
import osmnx as ox
from enviroment import SafeGuardEnv

env = SafeGuardEnv()

@asynccontextmanager
async def lifespan(_: FastAPI):
    env.load_salerno_map() # Usa la nuova funzione con cache locale
    yield

app = FastAPI(lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

class UserLocation(BaseModel):
    lat: float
    lng: float

@app.post("/api/safe-points/sorted")
async def get_sorted_points(req: UserLocation):
    try:
        # 1. IA: Applica i blocchi stradali
        env.apply_disaster_manager()

        # 2. Prendi i punti da Firebase
        punti = env.get_points_from_firestore()

        # 3. Trova il nodo dell'utente
        user_node = ox.nearest_nodes(env.graph, X=req.lng, Y=req.lat)

        # --- OTTIMIZZAZIONE SALVA-TIMEOUT ---
        # Calcoliamo la distanza matematica "volo d'uccello" per trovare i 3 candidati migliori
        for p in punti:
            p['bird_distance'] = ((p['lat'] - req.lat)**2 + (p['lng'] - req.lng)**2)**0.5

        # Filtriamo: prendiamo solo i 3 più vicini geograficamente
        punti_top = sorted(punti, key=lambda x: x['bird_distance'])[:3]
        # ------------------------------------

        results = []
        print("\n--- 🔍 DEBUG IA PERCORSI ---")

        for p in punti_top:
            target_node = ox.nearest_nodes(env.graph, X=p['lng'], Y=p['lat'])

            # Inizializziamo le variabili per evitare l'errore "unresolved reference"
            dist_w = 0.0
            dist_r = 0.0
            diff = 0.0
            is_dangerous = False

            try:
                # 1. Distanza Pesata (IA)
                dist_w = nx.shortest_path_length(env.graph, user_node, target_node, weight='final_weight')

                # 2. Distanza Reale (Metri)
                dist_r = nx.shortest_path_length(env.graph, user_node, target_node, weight='length')

                # 3. Calcolo differenza
                diff = dist_w - dist_r

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
                "title": p['name'],
                "type": p['type'],
                "lat": p['lat'],
                "lng": p['lng'],
                "distance": dist_r,
                "isDangerous": is_dangerous
            })

        print("--- 🏁 FINE DEBUG ---\n")
        # 6. Ordina: prima i sicuri, poi i pericolosi
        results.sort(key=lambda x: (x['isDangerous'], x['distance']))

        return results

    except Exception as e:
        print(f"❌ Errore API: {e}")
        return []

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)