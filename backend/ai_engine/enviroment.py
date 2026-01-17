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

    # Carica la mappa locale se esiste, altrimenti la scarica
    def load_salerno_map(self):
        file_path = "salerno_map.graphml"
        if os.path.exists(file_path):
            print("Mappa trovata localmente. Caricamento in corso...")
            self.graph = ox.load_graphml(file_path)
            print("Mappa caricata con successo dal file!")
        else:
            print("Scaricamento mappa (Provincia di Salerno) in corso...")
            self.graph = ox.graph_from_place("Provincia di Salerno, Italy", network_type='drive')
            ox.save_graphml(self.graph, file_path)
            print("Mappa scaricata e salvata localmente!")

    def get_points_from_firestore(self):
        punti_mappati = []
        collezioni = ['hospitals', 'safe_points']

        if self.graph is None:
            return []

        for col in collezioni:
            docs = self.db.collection(col).stream()
            for doc in docs:
                d = doc.to_dict()
                lat, lng, nome = d.get('lat'), d.get('lng'), d.get('name')

                if lat is not None and lng is not None:
                    try:
                        node = ox.nearest_nodes(self.graph, X=float(lng), Y=float(lat))
                        punti_mappati.append({
                            'id': doc.id,
                            'name': nome or "Senza nome",
                            'type': col,
                            'node_id': node,
                            'lat': float(lat),  # Chiavi piatte per compatibilità main.py
                            'lng': float(lng)
                        })
                    except Exception as err:
                        print(f"Errore mapping per {nome}: {err}")
        return punti_mappati

    def apply_disaster_manager(self):
        if self.graph is None:
            return []

        # 1. Reset pesi: riportiamo tutto alla lunghezza reale (metri)
        for u, v, k, attr in self.graph.edges(data=True, keys=True):
            attr['final_weight'] = attr['length']

        # 2. Unica lettura da Firebase
        emergenze_snapshot = list(self.db.collection('active_emergencies').where('status', '==', 'active').stream())

        if not emergenze_snapshot:
            print("Nessuna emergenza attiva. Grafo pulito.")
            return []

        print(f"Disaster Manager: Analisi di {len(emergenze_snapshot)} emergenze...")

        cause_bloccanti = ['terremoto', 'incendio', 'tsunami', 'alluvione', 'bomba']
        hotspots = []

        for doc in emergenze_snapshot:
            em = doc.to_dict()
            tipo = str(em.get('type', '')).lower()
            e_lat, e_lng = em.get('lat'), em.get('lng')

            hotspots.append({'lat': e_lat, 'lng': e_lng, 'type': tipo})

            if tipo in cause_bloccanti and e_lat and e_lng:
                try:
                    # 1. Trova il nodo centrale
                    danger_node = ox.nearest_nodes(self.graph, X=e_lng, Y=e_lat)

                    # Usiamo un set per raccogliere tutti i nodi da bloccare
                    nodes_to_block = {danger_node}

                    # Prendiamo i vicini di 1° grado
                    vicini_1 = list(self.graph.neighbors(danger_node))
                    nodes_to_block.update(vicini_1)

                    for v in vicini_1:
                        nodes_to_block.update(self.graph.neighbors(v))

                    # Applica il blocco a tutti i nodi della "zona rossa"
                    for n in nodes_to_block:
                        for u, v, k, attr in self.graph.edges(n, keys=True, data=True):
                            # Usa un peso altissimo per simulare strada chiusa
                            attr['final_weight'] = attr['length'] * 100000

                    print(f"⚠️ ZONA ROSSA ESTESA: {len(nodes_to_block)} nodi bloccati intorno a {tipo.upper()}.")
                except Exception as e:
                    print(f"Errore: {e}")

        print("Grafo aggiornato con successo.")
        return hotspots