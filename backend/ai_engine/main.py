import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
import osmnx as ox
import time # MODIFICA: Necessario per misurare i tempi di esecuzione
from enviroment import SafeGuardEnv
from algorithms import standard_dijkstra, bidirectional_dijkstra # MODIFICA: Importiamo le tue pipeline

# Inizializzazione dell'ambiente SafeGuard
env = SafeGuardEnv()

@asynccontextmanager
async def lifespan(_: FastAPI):
    env.load_salerno_map()
    yield

app = FastAPI(lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"]
)

class UserLocation(BaseModel):
    lat: float
    lng: float

@app.post("/api/safe-points/sorted")
async def get_sorted_points(req: UserLocation):
    try:
        env.apply_disaster_manager()
        punti = env.get_points_from_firestore()
        user_node = ox.nearest_nodes(env.graph, X=req.lng, Y=req.lat)

        for p in punti:
            p['bird_distance'] = ((p['lat'] - req.lat)**2 + (p['lng'] - req.lng)**2)**0.5

        punti_top = sorted(punti, key=lambda x: x['bird_distance'])[:5]
        results = []

        # MODIFICA: Prepariamo il grafo non orientato per il bidirezionale (una sola volta)
        # MODIFICA: Prepariamo il grafo non orientato
        G_undirected = env.graph.to_undirected()

        # ... (restante codice invariato fino al ciclo for) ...

        for p in punti_top:
            target_node = ox.nearest_nodes(env.graph, X=p['lng'], Y=p['lat'])

            try:
                # 1. Funzione PESO UNIFICATA
                def weight_ia(u, v):
                    edge_data = G_undirected.get_edge_data(u, v)
                    if edge_data:
                        return min(d.get('final_weight', d['length']) for d in edge_data.values())
                    return 1e9

                # 2. Pipeline Baseline (Distanza Reale)
                start_t1 = time.perf_counter()
                dist_r = standard_dijkstra(G_undirected, user_node, target_node, 'length')
                exec_time_1 = time.perf_counter() - start_t1

                # 3. Pipeline Ricerca (Tua Bidirezionale)
                start_t2 = time.perf_counter()
                dist_w = bidirectional_dijkstra(G_undirected, user_node, target_node, weight_ia)
                exec_time_2 = time.perf_counter() - start_t2

                # --- LOGICA DI CONFRONTO ---
                is_blocked = dist_w > 50000
                is_dangerous = dist_w > (dist_r + 10.0)

                status_icon = "⚠️" if is_dangerous else "✅"

                # MODIFICA: Stampa potenziata con Distanze e Tempi
                print(f"📍 {p['name'][:15]} | "
                      f"Dist.Reale: {dist_r:7.1f}m | Dist.IA: {dist_w:7.1f}m | "
                      f"T.Std: {exec_time_1:.5f}s | T.Bidir: {exec_time_2:.5f}s | {status_icon}")

                # Determine text status
                status_text = "⚠️ PERICOLO" if is_dangerous else "✅ SICURO"

                print(f"\n📊 RISULTATO ANALISI:")
                print(f"   - Reale (senza ostacoli): {dist_r:.0f} m")
                print(f"   - IA (con ostacoli):      {dist_w:.0f} m")
                print(f"   - Differenza:             {dist_w - dist_r:.0f} m")
                print(f"   - Tempo Standard:         {exec_time_1:.5f} s")
                print(f"   - Tempo Bidirezionale:    {exec_time_2:.5f} s")
                print(f"   - Status:                 {status_text}")
                if is_blocked:
                    print(f"   - Note:                   🚫 BLOCCATO (> 50km)")
                elif is_dangerous:
                    print(f"   - Note:                   ⚠️ DEVIAZIONE RILEVATA")

                results.append({
                    "title": str(p.get('name', 'N/A')),
                    "type": str(p.get('type', 'generic')),
                    "lat": float(p['lat']),
                    "lng": float(p['lng']),
                    "distance": float(dist_w) if is_dangerous else float(dist_r),
                    "dist_real": float(dist_r),
                    "isDangerous": bool(is_dangerous),
                    "isBlocked": bool(is_blocked),
                    "exec_time_baseline": exec_time_1,
                    "exec_time_research": exec_time_2
                })

            except Exception as e:
                print(f"❗ Errore su {p['name']}: {e}")
                continue

        # ... (restante codice invariato) ...

        print("--- 🏁 FINE DEBUG ---\n")
        results.sort(key=lambda x: x['distance'])
        return results

    except Exception as e:
        print(f"❌ Errore API: {e}")
        return []

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)