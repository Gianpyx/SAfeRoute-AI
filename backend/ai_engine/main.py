import time
from contextlib import asynccontextmanager

import networkx as nx
import osmnx as ox
import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from algorithms import bidirectional_dijkstra
from enviroment import SafeGuardEnv


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

        G_undirected = env.graph.to_undirected()

        for p in punti_top:
            target_node = ox.nearest_nodes(env.graph, X=p['lng'], Y=p['lat'])

            try:
                # 1. Funzione PESO UNIFICATA
                def weight_ia(u, v):
                    edge_data = G_undirected.get_edge_data(u, v)
                    if edge_data:
                        return min(d.get('final_weight', d['length']) for d in edge_data.values())
                    return 1e9

                # 2. Pipeline Baseline (Distanza Reale) - Ora chiediamo anche il PATH
                start_t1 = time.perf_counter()
                # Usiamo nx.shortest_path per avere i nodi
                path_nodes_r = nx.shortest_path(G_undirected, user_node, target_node, weight='length')
                dist_r = nx.path_weight(G_undirected, path_nodes_r, weight='length')
                exec_time_1 = time.perf_counter() - start_t1

                # 3. Pipeline Ricerca (Tua Bidirezionale) - Deve restituire (distanza, path)
                start_t2 = time.perf_counter()
                dist_w, path_nodes_w = bidirectional_dijkstra(G_undirected, user_node, target_node, weight_ia)
                exec_time_2 = time.perf_counter() - start_t2

                # Trasforma gli ID dei nodi in [[lat, lng], [lat, lng], ...]
                def nodes_to_coords(nodes):
                    return [[env.graph.nodes[n]['y'], env.graph.nodes[n]['x']] for n in nodes]

                # Logica di confronto
                is_blocked = dist_w > 50000
                is_dangerous = dist_w > (dist_r + 10.0)

                # Prepariamo le polilinee da mandare a Flutter
                polyline_to_send = nodes_to_coords(path_nodes_w) if not is_blocked else []

                results.append({
                    "title": str(p.get('name', 'N/A')),
                    "type": str(p.get('type', 'generic')),
                    "lat": float(p['lat']),
                    "lng": float(p['lng']),
                    "distance": float(dist_w) if is_dangerous else float(dist_r),
                    "dist_real": float(dist_r),
                    "isDangerous": bool(is_dangerous),
                    "isBlocked": bool(is_blocked),
                    "polyline": polyline_to_send,
                    "exec_time_baseline": exec_time_1,
                    "exec_time_research": exec_time_2
                })
            except Exception as e:
                print(f"❗ Errore su {p['name']}: {e}")
                continue

        results.sort(key=lambda x: x['distance'])

        # --- FORMATTAZIONE OUTPUT RICHIESTA UTENTE ---
        print(f"\n{'='*60}")
        print(f"📍  RAPPORTO ANALISI SICUREZZA - SAFEGUARD")
        print(f"{'='*60}\n")

        # RECAP GENERALE
        print(f"📊  RECAP GENERALE")
        print(f"   • Punti Totali Rilevati:    {len(punti)}")
        top_area = results[0]['title'] if results else 'N/A'
        print(f"   • Zona Densità Maggiore:    {top_area}") 
        
        status_val = "OTTIMALE 🟢"
        if any(r['isDangerous'] for r in results): status_val = "ATTENZIONE 🟡"
        if any(r['isBlocked'] for r in results): status_val = "CRITICO 🔴"
        
        print(f"   • Valutazione Area:         {status_val}\n")

        print(f"{'-'*60}\n")

        # DETTAGLIO PUNTI SICURI
        print(f"📋  DETTAGLIO PUNTI SICURI\n")
        for i, res in enumerate(results, 1):
            icon = "✅"
            state_text = "SICURO"
            if res['isDangerous']: 
                icon = "⚠️"
                state_text = "PERICOLOSO"
            if res['isBlocked']: 
                icon = "⛔"
                state_text = "NON RAGGIUNGIBILE"

            print(f"   {i}. {res['title'].upper()} ({res['type']})")
            print(f"      📍 {res['lat']:.5f}, {res['lng']:.5f}")
            print(f"      📏 {res['distance']:.0f}m (Reale: {res['dist_real']:.0f}m)")
            print(f"      🛡️  {state_text} {icon}")
            print(f"      ⏱️  IA: {res['exec_time_research']:.4f}s | Base: {res['exec_time_baseline']:.4f}s")
            print("")

        print(f"{'='*60}\n")

        return results

    except Exception as e:
        print(f"❌ Errore API: {e}")
        return []

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
