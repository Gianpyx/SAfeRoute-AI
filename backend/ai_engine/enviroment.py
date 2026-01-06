import os
import osmnx as ox
import firebase_admin
from firebase_admin import credentials, firestore

class SafeGuardEnv:
    def __init__(self):
        current_dir = os.path.dirname(os.path.abspath(__file__))
        key_path = os.path.join(current_dir, "safeguard-c08-firebase-adminsdk-fbsvc-54e53643c3.json")

        try:
            firebase_admin.get_app()
        except ValueError:
            cred = credentials.Certificate(key_path)
            firebase_admin.initialize_app(cred)
            print("Connessione a Firebase stabilita!")

        self.db = firestore.client()
        self.graph = None

    def download_salerno_map(self):
        print("Scaricamento mappa dell'intera Provincia di Salerno in corso...")
        print("Nota: l'operazione potrebbe richiedere alcuni minuti...")

        # Ambito del sistema: Provincia di Salerno [RF-O2.1]
        # Usiamo graph_from_place per coprire l'intera area amministrativa
        self.graph = ox.graph_from_place("Provincia di Salerno, Italy", network_type='drive')

        # Salviamo il file: questo è il file fondamentale per tutto il team
        ox.save_graphml(self.graph, "salerno_map.graphml")
        print("Mappa della provincia salvata con successo: 'salerno_map.graphml'")

    def get_points_from_firestore(self):
        punti_mappati = []
        # RF-C2.2: Integrazione punti di raccolta
        collezioni = ['hospitals', 'safe_points']

        for col in collezioni:
            docs = self.db.collection(col).stream()
            for doc in docs:
                d = doc.to_dict()
                # Usiamo i nomi dei campi che hai indicato
                lat = d.get('lat')
                lng = d.get('lng')
                nome = d.get('name')

                if lat and lng:
                    try:
                        # Trova il nodo stradale più vicino (punto di ingresso per l'IA)
                        node = ox.nearest_nodes(self.graph, X=lng, Y=lat)
                        punti_mappati.append({
                            'id': doc.id,
                            'name': nome,
                            'type': col,
                            'node_id': node,
                            'coords': (lat, lng)
                        })
                    except Exception as err:
                        print(f"Errore mapping per {nome}: {err}")
        return punti_mappati

if __name__ == "__main__":
    try:
        env = SafeGuardEnv()
        env.download_salerno_map()
        punti = env.get_points_from_firestore()

        print(f"\nSincronizzazione completata! Trovati {len(punti)} punti totali:")
        for p in punti:
            print(f"[{p['type'].upper()}] {p['name']} -> Nodo Stradale: {p['node_id']}")

    except Exception as e:
        print(f"ERRORE CRITICO: {e}")